# frozen_string_literal: true

module SerpGuard
  # Thin HTTP wrapper around the Anthropic Messages API.
  #
  # This class owns everything about *talking to* Claude - endpoint, headers,
  # credentials, response envelope - and nothing about what SerpGuard asks for.
  # Callers hand it a system prompt and a user message and get back a Response
  # carrying the assistant's text. Timeouts and the retry policy come from
  # ApiClient, shared with SerpapiClient.
  #
  # HTTParty is called here and in SerpapiClient and nowhere else, which gives
  # specs a single seam: stub the transport with WebMock, or inject a double.
  class ClaudeClient < ApiClient
    include HTTParty

    base_uri "https://api.anthropic.com"

    ENDPOINT = "/v1/messages"
    ANTHROPIC_VERSION = "2023-06-01"
    CREDENTIAL_ENV_VAR = "ANTHROPIC_API_KEY"

    DEFAULT_MODEL = "claude-opus-5"
    DEFAULT_MAX_TOKENS = 16_000

    # Thinking is on by default on this model and disabling it has known failure
    # modes, so effort - not thinking - is the dial we turn down. Claim work is
    # shallow; raise this if extraction or verdict quality slips.
    DEFAULT_EFFORT = "low"

    Response = Data.define(:text, :stop_reason, :model, :usage) do
      # Claude hit max_tokens mid-answer, so `text` is a fragment. Worth
      # checking before parsing: truncated JSON looks exactly like bad JSON.
      def truncated?
        stop_reason == "max_tokens"
      end
    end

    def initialize(
      api_key: ENV[CREDENTIAL_ENV_VAR],
      model: DEFAULT_MODEL,
      max_tokens: DEFAULT_MAX_TOKENS,
      effort: DEFAULT_EFFORT,
      **options
    )
      @model = model
      @max_tokens = max_tokens
      @effort = effort

      super(api_key: api_key, credential_env_var: CREDENTIAL_ENV_VAR, **options)
    end

    # Sends one user message and returns the assistant's reply.
    def create_message(system:, user:)
      payload = build_payload(system: system, user: user)

      with_retries { interpret(execute(payload)) }
    end

    private

    attr_reader :model, :max_tokens, :effort

    def service_name
      "Claude"
    end

    def upstream_error_class
      SerpGuard::Errors::AnthropicError
    end

    def build_payload(system:, user:)
      {
        model: model,
        max_tokens: max_tokens,
        # Effort lives inside output_config, not at the top level.
        output_config: { effort: effort },
        system: system,
        messages: [ { role: "user", content: user } ]
      }
    end

    def execute(payload)
      self.class.post(
        ENDPOINT,
        headers: {
          "content-type" => "application/json",
          "x-api-key" => api_key,
          "anthropic-version" => ANTHROPIC_VERSION
        },
        body: payload.to_json,
        **request_timeouts
      )
    end

    def interpret(response)
      body = parse_body(response)
      check_status!(response, body)

      if body.nil?
        raise SerpGuard::Errors::AnthropicError,
              "Claude returned HTTP #{response.code} with a body that is not valid JSON."
      end

      build_response(body)
    end

    def build_response(body)
      # A refusal is an HTTP 200 whose content must not be read as an answer,
      # so check stop_reason before touching any of it.
      if body["stop_reason"] == "refusal"
        category = body.dig("stop_details", "category") || "unspecified"
        raise SerpGuard::Errors::AnthropicError,
              "Claude declined this request (refusal category: #{category})."
      end

      Response.new(
        text: text_from(body),
        stop_reason: body["stop_reason"],
        model: body["model"],
        usage: body["usage"] || {}
      )
    end

    # Content is a list of blocks. Thinking blocks are interleaved with text
    # blocks, so select rather than reaching for content[0].
    def text_from(body)
      Array(body["content"])
        .select { |block| block["type"] == "text" }
        .map { |block| block["text"] }
        .join
    end
  end
end
