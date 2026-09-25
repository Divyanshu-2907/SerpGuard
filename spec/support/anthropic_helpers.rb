# frozen_string_literal: true

# Builds realistic Anthropic Messages API responses and stubs them with
# WebMock, so specs exercise SerpGuard::ClaudeClient's real HTTParty call
# rather than a double standing in for it.
module AnthropicHelpers
  CLAUDE_MESSAGES_URL = "https://api.anthropic.com/v1/messages"
  TEST_ANTHROPIC_API_KEY = "sk-ant-test-0123456789"

  JSON_HEADERS = { "content-type" => "application/json" }.freeze

  # The shape the real API returns. The leading thinking block is not padding:
  # this model thinks by default, so every response has one, and the client has
  # to skip past it to find the text.
  def claude_message_body(text, stop_reason: "end_turn", **overrides)
    {
      id: "msg_01SpecFixture",
      type: "message",
      role: "assistant",
      model: "claude-opus-5",
      content: [
        { type: "thinking", thinking: "" },
        { type: "text", text: text }
      ],
      stop_reason: stop_reason,
      stop_sequence: nil,
      usage: { input_tokens: 412, output_tokens: 88 }
    }.merge(overrides).to_json
  end

  def claude_error_body(error_type, message)
    { type: "error", error: { type: error_type, message: message } }.to_json
  end

  # Stubs one successful call whose assistant text is exactly `text`.
  def stub_claude_text(text, stop_reason: "end_turn")
    stub_request(:post, CLAUDE_MESSAGES_URL).to_return(
      status: 200,
      body: claude_message_body(text, stop_reason: stop_reason),
      headers: JSON_HEADERS
    )
  end

  # Stubs a call that returns the given claims as a JSON array, the way the
  # prompt asks Claude to answer.
  def stub_claude_claims(claims, stop_reason: "end_turn")
    stub_claude_text(claims.to_json, stop_reason: stop_reason)
  end

  # Stubs consecutive calls to the same endpoint, one response per argument.
  # ClaimVerifierService talks to Claude twice - once for the search query, once
  # for the verdict - so order matters here.
  def stub_claude_sequence(*texts)
    responses = texts.flatten.map do |text|
      { status: 200, body: claude_message_body(text), headers: JSON_HEADERS }
    end

    stub_request(:post, CLAUDE_MESSAGES_URL).to_return(*responses)
  end

  # Routes each Claude call by the system prompt it carries rather than by
  # arrival order. The full pipeline makes three calls of different kinds
  # (extraction, search query, verdict) and a cached run makes only one, so
  # order-based stubbing would silently mis-answer the run it is meant to prove.
  def stub_claude_routing(claims:, query:, verdict:)
    stub_request(:post, CLAUDE_MESSAGES_URL).to_return do |request|
      system_prompt = JSON.parse(request.body)["system"].to_s

      text =
        if system_prompt.include?("extract independently checkable claims")
          claims.is_a?(String) ? claims : claims.to_json
        elsif system_prompt.include?("one Google search query")
          query
        else
          verdict.is_a?(String) ? verdict : verdict.to_json
        end

      { status: 200, body: claude_message_body(text), headers: JSON_HEADERS }
    end
  end

  def claude_requests_made
    a_request(:post, CLAUDE_MESSAGES_URL)
  end

  def an_extraction_request
    a_claude_request_where { |body| body["system"].include?("extract independently checkable claims") }
  end

  def a_search_query_request
    a_claude_request_where { |body| body["system"].include?("one Google search query") }
  end

  def a_verdict_request
    a_claude_request_where { |body| body["system"].include?("rule on whether search results") }
  end

  # Matches a Claude call whose parsed body satisfies the block. The two calls
  # ClaimVerifierService makes carry different system prompts, so this is enough
  # to assert on either one individually.
  def a_claude_request_where(&predicate)
    a_request(:post, CLAUDE_MESSAGES_URL).with { |request| predicate.call(JSON.parse(request.body)) }
  end

  def stub_claude_status(status, error_type: "api_error", message: "upstream exploded", headers: {})
    stub_request(:post, CLAUDE_MESSAGES_URL).to_return(
      status: status,
      body: claude_error_body(error_type, message),
      headers: JSON_HEADERS.merge(headers)
    )
  end
end

RSpec.configure do |config|
  config.include AnthropicHelpers

  # Specs never read the developer's real key, and never depend on one being
  # absent either.
  config.around(:each) do |example|
    previous = ENV["ANTHROPIC_API_KEY"]
    ENV["ANTHROPIC_API_KEY"] = AnthropicHelpers::TEST_ANTHROPIC_API_KEY
    begin
      example.run
    ensure
      ENV["ANTHROPIC_API_KEY"] = previous
    end
  end
end
