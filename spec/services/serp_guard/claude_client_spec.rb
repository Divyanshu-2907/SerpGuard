# frozen_string_literal: true

require "rails_helper"

RSpec.describe SerpGuard::ClaudeClient do
  # retry_delay: 0 keeps the retry specs instant; the production default is 0.5s.
  subject(:client) { described_class.new(retry_delay: 0) }

  let(:url) { AnthropicHelpers::CLAUDE_MESSAGES_URL }

  def create_message
    client.create_message(system: "You extract claims.", user: "some text")
  end

  describe "a successful call" do
    before { stub_claude_text("hello") }

    it "returns the assistant text with the response metadata" do
      response = create_message

      expect(response.text).to eq("hello")
      expect(response.stop_reason).to eq("end_turn")
      expect(response.model).to eq("claude-opus-5")
      expect(response.usage).to include("input_tokens" => 412)
      expect(response).not_to be_truncated
    end

    it "posts the documented request shape" do
      create_message

      expect(
        a_request(:post, url).with { |request|
          body = JSON.parse(request.body)

          body["model"] == "claude-opus-5" &&
            body["max_tokens"] == 16_000 &&
            body.dig("output_config", "effort") == "low" &&
            body["system"] == "You extract claims." &&
            body["messages"] == [ { "role" => "user", "content" => "some text" } ]
        }
      ).to have_been_made.once
    end

    it "joins multiple text blocks and ignores thinking blocks" do
      stub_request(:post, url).to_return(
        status: 200,
        body: {
          content: [
            { type: "thinking", thinking: "" },
            { type: "text", text: "first " },
            { type: "text", text: "second" }
          ],
          stop_reason: "end_turn",
          model: "claude-opus-5",
          usage: {}
        }.to_json,
        headers: AnthropicHelpers::JSON_HEADERS
      )

      expect(create_message.text).to eq("first second")
    end

    it "flags a response that hit the token ceiling" do
      stub_claude_text("[{", stop_reason: "max_tokens")

      expect(create_message).to be_truncated
    end
  end

  describe "credentials" do
    it "refuses to build without ANTHROPIC_API_KEY" do
      ENV["ANTHROPIC_API_KEY"] = nil

      expect { described_class.new }
        .to raise_error(SerpGuard::Errors::MissingCredential, /ANTHROPIC_API_KEY is not configured/)
    end

    it "maps a rejected key to a configuration error, not an upstream error" do
      stub_claude_status(401, error_type: "authentication_error", message: "invalid x-api-key")

      expect { create_message }
        .to raise_error(SerpGuard::Errors::ConfigurationError, /rejected our credentials/)
    end
  end

  describe "retrying transient failures" do
    it "retries once after a 500 and returns the second response" do
      stub_request(:post, url)
        .to_return(status: 500, body: '{"type":"error","error":{"message":"overloaded"}}',
                   headers: AnthropicHelpers::JSON_HEADERS)
        .then
        .to_return(status: 200, body: claude_message_body("recovered"),
                   headers: AnthropicHelpers::JSON_HEADERS)

      expect(create_message.text).to eq("recovered")
      expect(a_request(:post, url)).to have_been_made.twice
    end

    it "gives up after the second 5xx and raises AnthropicError" do
      stub_claude_status(503, message: "service unavailable")

      expect { create_message }
        .to raise_error(SerpGuard::Errors::AnthropicError, /HTTP 503/)
      expect(a_request(:post, url)).to have_been_made.twice
    end

    it "retries a 529 overload" do
      stub_claude_status(529, error_type: "overloaded_error")

      expect { create_message }.to raise_error(SerpGuard::Errors::AnthropicError)
      expect(a_request(:post, url)).to have_been_made.twice
    end

    it "retries a read timeout and maps it to UpstreamTimeout" do
      stub_request(:post, url).to_timeout

      expect { create_message }
        .to raise_error(SerpGuard::Errors::UpstreamTimeout, /did not respond/)
      expect(a_request(:post, url)).to have_been_made.twice
    end

    it "retries a connection reset" do
      stub_request(:post, url).to_raise(Errno::ECONNRESET)

      expect { create_message }
        .to raise_error(SerpGuard::Errors::AnthropicError, /Could not reach Claude/)
      expect(a_request(:post, url)).to have_been_made.twice
    end

    it "recovers when the reset is followed by a good response" do
      stub_request(:post, url)
        .to_raise(Errno::ECONNRESET)
        .then
        .to_return(status: 200, body: claude_message_body("recovered"),
                   headers: AnthropicHelpers::JSON_HEADERS)

      expect(create_message.text).to eq("recovered")
    end

    it "retries a 429 and maps it to UpstreamRateLimited" do
      stub_claude_status(429, error_type: "rate_limit_error", headers: { "retry-after" => "0" })

      expect { create_message }
        .to raise_error(SerpGuard::Errors::UpstreamRateLimited, /rate-limited/)
      expect(a_request(:post, url)).to have_been_made.twice
    end

    it "caps how long Retry-After can park the request" do
      stub_claude_status(429, headers: { "retry-after" => "3600" })
      allow(client).to receive(:sleep)

      expect { create_message }.to raise_error(SerpGuard::Errors::UpstreamRateLimited)
      expect(client).to have_received(:sleep).with(described_class::MAX_RETRY_DELAY)
    end
  end

  describe "failures that must not be retried" do
    it "does not retry a 400" do
      stub_claude_status(400, error_type: "invalid_request_error", message: "max_tokens: must be positive")

      expect { create_message }
        .to raise_error(SerpGuard::Errors::AnthropicError, /HTTP 400/)
      expect(a_request(:post, url)).to have_been_made.once
    end

    it "does not retry a 401" do
      stub_claude_status(401, error_type: "authentication_error")

      expect { create_message }.to raise_error(SerpGuard::Errors::ConfigurationError)
      expect(a_request(:post, url)).to have_been_made.once
    end

    it "does not retry a 404" do
      stub_claude_status(404, error_type: "not_found_error", message: "model not found")

      expect { create_message }.to raise_error(SerpGuard::Errors::AnthropicError)
      expect(a_request(:post, url)).to have_been_made.once
    end

    it "does not retry a 413" do
      stub_claude_status(413, error_type: "request_too_large")

      expect { create_message }.to raise_error(SerpGuard::Errors::AnthropicError)
      expect(a_request(:post, url)).to have_been_made.once
    end
  end

  describe "a refusal" do
    it "raises instead of handing back the refusal text as an answer" do
      stub_request(:post, url).to_return(
        status: 200,
        body: claude_message_body(
          "",
          stop_reason: "refusal",
          stop_details: { type: "refusal", category: "cyber", explanation: "declined" }
        ),
        headers: AnthropicHelpers::JSON_HEADERS
      )

      expect { create_message }
        .to raise_error(SerpGuard::Errors::AnthropicError, /declined this request.*cyber/)
    end
  end

  describe "an unparsable error body" do
    it "still maps the status rather than blowing up on the body" do
      stub_request(:post, url).to_return(
        status: 502,
        body: "<html><body>Bad Gateway</body></html>",
        headers: { "content-type" => "text/html" }
      )

      expect { create_message }
        .to raise_error(SerpGuard::Errors::AnthropicError, /HTTP 502/)
    end
  end
end
