# frozen_string_literal: true

require "rails_helper"

RSpec.describe SerpGuard::SerpapiClient do
  subject(:client) { described_class.new(retry_delay: 0) }

  let(:results) do
    [
      { title: "First", link: "https://example.com/1", snippet: "First snippet." },
      { title: "Second", link: "https://example.com/2", snippet: "Second snippet." }
    ]
  end

  describe "#search" do
    it "returns the organic results as Result objects" do
      stub_serpapi_results(results)

      found = client.search("ruby 3.3 yjit")

      expect(found.map(&:to_h)).to eq(
        [
          { title: "First", link: "https://example.com/1", snippet: "First snippet." },
          { title: "Second", link: "https://example.com/2", snippet: "Second snippet." }
        ]
      )
    end

    it "sends the documented query parameters" do
      stub_serpapi_results(results)

      client.search("ruby 3.3 yjit")

      expect(
        a_request(:get, SerpapiHelpers::SERPAPI_SEARCH_URL).with(
          query: {
            "engine" => "google",
            "q" => "ruby 3.3 yjit",
            "num" => "10",
            "api_key" => SerpapiHelpers::TEST_SERPAPI_KEY
          }
        )
      ).to have_been_made.once
    end

    it "caps the results at the requested limit" do
      stub_serpapi_results(Array.new(9) { |i| { title: "T#{i}", link: "https://example.com/#{i}", snippet: "S#{i}" } })

      expect(client.search("anything", limit: 4).length).to eq(4)
    end

    it "drops results with no snippet, since they are not usable evidence" do
      stub_serpapi_results(
        [
          { title: "No snippet", link: "https://example.com/1", snippet: nil },
          { title: "Has snippet", link: "https://example.com/2", snippet: "Useful." }
        ]
      )

      expect(client.search("anything").map(&:title)).to eq([ "Has snippet" ])
    end

    it "drops results with no link" do
      stub_serpapi_results([ { title: "No link", link: nil, snippet: "Useful." } ])

      expect(client.search("anything")).to be_empty
    end

    it "returns an empty array when Google found nothing" do
      stub_serpapi_no_results

      expect(client.search("asdkjhaskdjh")).to eq([])
    end

    it "returns an empty array when organic_results is absent" do
      stub_request(:get, SerpapiHelpers::SERPAPI_SEARCH_URL)
        .with(query: hash_including("engine" => "google"))
        .to_return(status: 200, body: { search_metadata: {} }.to_json, headers: SerpapiHelpers::JSON_HEADERS)

      expect(client.search("anything")).to eq([])
    end

    it "refuses a blank query rather than paying for an empty search" do
      expect { client.search("  ") }.to raise_error(ArgumentError, /must not be blank/)
      expect(a_serpapi_request).not_to have_been_made
    end
  end

  describe "credentials" do
    it "refuses to build without SERPAPI_KEY" do
      ENV["SERPAPI_KEY"] = nil

      expect { described_class.new }
        .to raise_error(SerpGuard::Errors::MissingCredential, /SERPAPI_KEY is not configured/)
    end

    it "maps a rejected key to a configuration error" do
      stub_serpapi_status(401, message: "Invalid API key")

      expect { client.search("anything") }
        .to raise_error(SerpGuard::Errors::ConfigurationError, /SerpApi rejected our credentials/)
      expect(a_serpapi_request).to have_been_made.once
    end
  end

  describe "the shared retry policy" do
    it "retries once after a 500 and returns the second response" do
      stub_request(:get, SerpapiHelpers::SERPAPI_SEARCH_URL)
        .with(query: hash_including("engine" => "google"))
        .to_return(status: 500, body: { error: "boom" }.to_json, headers: SerpapiHelpers::JSON_HEADERS)
        .then
        .to_return(status: 200, body: serpapi_body(results), headers: SerpapiHelpers::JSON_HEADERS)

      expect(client.search("anything").length).to eq(2)
      expect(a_serpapi_request).to have_been_made.twice
    end

    it "maps an exhausted 5xx onto SerpApiError" do
      stub_serpapi_status(503, message: "unavailable")

      expect { client.search("anything") }
        .to raise_error(SerpGuard::Errors::SerpApiError, /SerpApi is unavailable \(HTTP 503\)/)
      expect(a_serpapi_request).to have_been_made.twice
    end

    it "maps a timeout onto UpstreamTimeout" do
      stub_request(:get, SerpapiHelpers::SERPAPI_SEARCH_URL)
        .with(query: hash_including("engine" => "google")).to_timeout

      expect { client.search("anything") }
        .to raise_error(SerpGuard::Errors::UpstreamTimeout, /SerpApi did not respond/)
      expect(a_serpapi_request).to have_been_made.twice
    end

    it "maps a 429 onto UpstreamRateLimited" do
      stub_serpapi_status(429, message: "too many searches", headers: { "retry-after" => "0" })

      expect { client.search("anything") }
        .to raise_error(SerpGuard::Errors::UpstreamRateLimited, /SerpApi rate-limited/)
      expect(a_serpapi_request).to have_been_made.twice
    end

    it "does not retry a 400" do
      stub_serpapi_status(400, message: "Missing query `q` parameter")

      expect { client.search("anything") }
        .to raise_error(SerpGuard::Errors::SerpApiError, /rejected the request \(HTTP 400\)/)
      expect(a_serpapi_request).to have_been_made.once
    end

    it "reports SerpApi's own error message, which is a bare string not a nested object" do
      stub_serpapi_status(400, message: "Unsupported `engine` parameter")

      expect { client.search("anything") }
        .to raise_error(SerpGuard::Errors::SerpApiError, /Unsupported `engine` parameter/)
    end

    it "still maps the status when the error body is not JSON" do
      stub_request(:get, SerpapiHelpers::SERPAPI_SEARCH_URL)
        .with(query: hash_including("engine" => "google"))
        .to_return(status: 502, body: "<html>Bad Gateway</html>", headers: { "content-type" => "text/html" })

      expect { client.search("anything") }
        .to raise_error(SerpGuard::Errors::SerpApiError, /HTTP 502/)
    end
  end
end
