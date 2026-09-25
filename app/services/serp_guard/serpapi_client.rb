# frozen_string_literal: true

module SerpGuard
  # Thin HTTP wrapper around SerpApi's Google Search engine.
  #
  # Same shape as ClaudeClient on purpose: credentials, endpoint and response
  # parsing live here, while timeouts, the single retry and the exception
  # mapping come from ApiClient. Callers get back plain Result objects and never
  # see SerpApi's envelope.
  class SerpapiClient < ApiClient
    include HTTParty

    base_uri "https://serpapi.com"

    ENDPOINT = "/search"
    CREDENTIAL_ENV_VAR = "SERPAPI_KEY"

    ENGINE = "google"

    # Results wanted by the caller. One page is one SerpApi search either way,
    # so ask for ten and keep the best few that actually carry a snippet.
    DEFAULT_LIMIT = 5
    RESULTS_PER_PAGE = 10

    # SerpApi answers HTTP 200 with an `error` string when Google simply had
    # nothing to return. That is an empty result set, not a failure - the
    # verifier turns it into an "unconfirmed" verdict.
    NO_RESULTS_PATTERN = /hasn't returned any results|no results (?:found|returned)/i

    # One organic Google result, reduced to the three fields the verifier needs.
    Result = Data.define(:title, :link, :snippet)

    def initialize(api_key: ENV[CREDENTIAL_ENV_VAR], **options)
      super(api_key: api_key, credential_env_var: CREDENTIAL_ENV_VAR, **options)
    end

    # @return [Array<Result>] organic results carrying a snippet, at most `limit`
    def search(query, limit: DEFAULT_LIMIT)
      raise ArgumentError, "query must not be blank" if query.blank?

      with_retries { interpret(execute(query), limit: limit) }
    end

    private

    def service_name
      "SerpApi"
    end

    def upstream_error_class
      SerpGuard::Errors::SerpApiError
    end

    # SerpApi's error bodies are `{"error": "some message"}` - a bare string,
    # not Claude's nested `{"error": {"message": ...}}`.
    def api_error_message(body)
      body&.[]("error").presence || "no error message returned"
    end

    def execute(query)
      self.class.get(
        ENDPOINT,
        query: {
          engine: ENGINE,
          q: query,
          num: RESULTS_PER_PAGE,
          api_key: api_key
        },
        **request_timeouts
      )
    end

    def interpret(response, limit:)
      body = parse_body(response)
      check_status!(response, body)

      if body.nil?
        raise SerpGuard::Errors::SerpApiError,
              "SerpApi returned HTTP #{response.code} with a body that is not valid JSON."
      end

      # A 200 can still carry an error. "No results" is a legitimate empty
      # answer; anything else at this point is SerpApi telling us the search
      # did not happen.
      if body["error"].present?
        return [] if body["error"].to_s.match?(NO_RESULTS_PATTERN)

        raise SerpGuard::Errors::SerpApiError, "SerpApi could not run the search: #{body['error']}"
      end

      build_results(body, limit: limit)
    end

    def build_results(body, limit:)
      Array(body["organic_results"])
        .filter_map { |result| build_result(result) }
        .first(limit)
    end

    # Results without a snippet are useless as evidence - there is nothing for
    # Claude to weigh - so they are dropped rather than passed on empty.
    def build_result(result)
      return nil unless result.is_a?(Hash)

      snippet = result["snippet"]
      link = result["link"]
      return nil if snippet.blank? || link.blank?

      Result.new(
        title: result["title"].to_s,
        link: link,
        snippet: snippet
      )
    end
  end
end
