# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClaimExtractorService do
  # Every example stubs the Claude endpoint with WebMock; `webmock/rspec`
  # turns any unstubbed outbound request into a failure.
  let(:text) do
    "Ruby 3.3 shipped YJIT as its production JIT compiler. " \
    "ActiveSupport adds String#squish. Rails 8 was downloaded 400 million times."
  end

  describe "the happy path" do
    let(:claims_payload) do
      [
        { claim: "Ruby 3.3 shipped YJIT as its production JIT compiler", type: "fact" },
        { claim: "ActiveSupport adds a String#squish method", type: "code_api" },
        { claim: "Rails 8 was downloaded 400 million times", type: "statistic" }
      ]
    end

    before { stub_claude_claims(claims_payload) }

    it "returns one Claim per extracted claim" do
      claims = described_class.call(text)

      expect(claims.length).to eq(3)
      expect(claims).to all(be_a(ClaimExtractorService::Claim))
    end

    it "carries the claim text and type through unchanged" do
      claims = described_class.call(text)

      expect(claims.map(&:to_h)).to eq(
        [
          { claim: "Ruby 3.3 shipped YJIT as its production JIT compiler", type: "fact" },
          { claim: "ActiveSupport adds a String#squish method", type: "code_api" },
          { claim: "Rails 8 was downloaded 400 million times", type: "statistic" }
        ]
      )
    end

    it "sends the text to Claude wrapped in delimiters, with the system prompt" do
      described_class.call(text)

      expect(
        a_request(:post, AnthropicHelpers::CLAUDE_MESSAGES_URL).with { |request|
          body = JSON.parse(request.body)

          body["model"] == "claude-opus-5" &&
            body["system"].include?("Return ONLY a JSON array") &&
            body["messages"].length == 1 &&
            body["messages"].first["role"] == "user" &&
            body["messages"].first["content"].include?("<text_to_check>") &&
            body["messages"].first["content"].include?("Ruby 3.3 shipped YJIT")
        }
      ).to have_been_made.once
    end

    it "authenticates with the Anthropic headers" do
      described_class.call(text)

      expect(
        a_request(:post, AnthropicHelpers::CLAUDE_MESSAGES_URL).with(
          headers: {
            "x-api-key" => AnthropicHelpers::TEST_ANTHROPIC_API_KEY,
            "anthropic-version" => "2023-06-01"
          }
        )
      ).to have_been_made.once
    end

    it "skips the thinking block when reading the response" do
      # The fixture always includes an empty thinking block before the text;
      # if the client grabbed content[0] this would parse as nil and blow up.
      expect { described_class.call(text) }.not_to raise_error
    end

    it "tolerates a markdown code fence around the JSON" do
      stub_claude_text(<<~FENCED)
        ```json
        [{"claim": "Ruby 3.3 shipped YJIT", "type": "fact"}]
        ```
      FENCED

      claims = described_class.call(text)

      expect(claims.map(&:claim)).to eq([ "Ruby 3.3 shipped YJIT" ])
    end

    it "caps the list at max_claims" do
      stub_claude_claims(Array.new(10) { |i| { claim: "Claim #{i}", type: "fact" } })

      claims = described_class.call(text, max_claims: 4)

      expect(claims.length).to eq(4)
      expect(claims.first.claim).to eq("Claim 0")
    end
  end

  describe "invalid input" do
    it "rejects an empty string without calling Claude" do
      expect { described_class.call("") }
        .to raise_error(SerpGuard::Errors::ValidationError, /No text was supplied/)

      expect(a_request(:post, AnthropicHelpers::CLAUDE_MESSAGES_URL)).not_to have_been_made
    end

    it "rejects whitespace-only text" do
      expect { described_class.call("   \n\t ") }
        .to raise_error(SerpGuard::Errors::ValidationError)
    end

    it "rejects nil" do
      expect { described_class.call(nil) }
        .to raise_error(SerpGuard::Errors::ValidationError)
    end

    it "rejects text past the length cap, so a runaway caller cannot burn tokens" do
      expect { described_class.call("a" * (ClaimExtractorService::MAX_TEXT_LENGTH + 1)) }
        .to raise_error(SerpGuard::Errors::PayloadTooLarge, /the limit is/)

      expect(a_request(:post, AnthropicHelpers::CLAUDE_MESSAGES_URL)).not_to have_been_made
    end
  end

  describe "a malformed response from Claude" do
    it "raises ExtractionFailed when the reply is not JSON at all" do
      stub_claude_text("I'm afraid I can't help with that request.")

      expect { described_class.call(text) }
        .to raise_error(SerpGuard::Errors::ExtractionFailed, /did not return valid JSON/)
    end

    it "raises ExtractionFailed on truncated JSON" do
      stub_claude_text('[{"claim": "Ruby 3.3 shipped YJIT", "ty')

      expect { described_class.call(text) }
        .to raise_error(SerpGuard::Errors::ExtractionFailed, /did not return valid JSON/)
    end

    it "raises ExtractionFailed when the JSON is not an array" do
      stub_claude_text({ claims: [ { claim: "x", type: "fact" } ] }.to_json)

      expect { described_class.call(text) }
        .to raise_error(SerpGuard::Errors::ExtractionFailed, /Expected a JSON array/)
    end

    it "raises ExtractionFailed on an empty array" do
      stub_claude_claims([])

      expect { described_class.call(text) }
        .to raise_error(SerpGuard::Errors::ExtractionFailed, /did not find any checkable claims/)
    end

    it "raises ExtractionFailed when an entry is missing its claim text" do
      stub_claude_claims([ { type: "fact" } ])

      expect { described_class.call(text) }
        .to raise_error(SerpGuard::Errors::ExtractionFailed, /no text/)
    end

    it "raises ExtractionFailed on a claim type outside the allowed set" do
      stub_claude_claims([ { claim: "Rails is the best framework", type: "opinion" } ])

      expect { described_class.call(text) }
        .to raise_error(SerpGuard::Errors::ExtractionFailed, /Unknown claim type "opinion"/)
    end

    it "raises ExtractionFailed when the array holds bare strings" do
      stub_claude_text([ "Ruby 3.3 shipped YJIT" ].to_json)

      expect { described_class.call(text) }
        .to raise_error(SerpGuard::Errors::ExtractionFailed, /Expected each claim to be a JSON object/)
    end

    it "raises ExtractionFailed when Claude hit the token limit mid-list" do
      stub_claude_claims([ { claim: "Ruby 3.3 shipped YJIT", type: "fact" } ], stop_reason: "max_tokens")

      expect { described_class.call(text) }
        .to raise_error(SerpGuard::Errors::ExtractionFailed, /cut off at the token limit/)
    end
  end

  describe "error codes" do
    it "surfaces ExtractionFailed as a 500 with a stable code" do
      stub_claude_text("not json")

      begin
        described_class.call(text)
      rescue SerpGuard::Errors::ExtractionFailed => error
        expect(error.code).to eq("claim_extraction_failed")
        expect(error.http_status).to eq(:internal_server_error)
      end
    end

    it "surfaces blank input as a 422, not a server error" do
      error = begin
        described_class.call("")
      rescue SerpGuard::Errors::ValidationError => e
        e
      end

      expect(error.http_status).to eq(:unprocessable_content)
    end
  end

  describe "dependency injection" do
    it "accepts an injected client, so callers can stub the transport entirely" do
      fake_response = SerpGuard::ClaudeClient::Response.new(
        text: [ { claim: "Injected claim", type: "fact" } ].to_json,
        stop_reason: "end_turn",
        model: "claude-opus-5",
        usage: {}
      )
      fake_client = instance_double(SerpGuard::ClaudeClient, create_message: fake_response)

      claims = described_class.call(text, client: fake_client)

      expect(claims.map(&:claim)).to eq([ "Injected claim" ])
      expect(fake_client).to have_received(:create_message).with(
        system: ClaimExtractorService::SYSTEM_PROMPT,
        user: a_string_including("Ruby 3.3")
      )
    end
  end
end
