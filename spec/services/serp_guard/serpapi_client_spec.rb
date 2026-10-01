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
          { title: "First", link: "https://example.com/1", snippet: "First snippet.", origin: "organic" },
          { title: "Second", link: "https://example.com/2", snippet: "Second snippet.", origin: "organic" }
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

  # Google returns an answer box and a knowledge graph panel on the same
  # request as organic_results. Using them costs nothing extra and is usually
  # the most on-point text on the page.
  describe "direct answers from the same search" do
    let(:organic) do
      [
        { title: "Ruby downloads", link: "https://www.ruby-lang.org/en/downloads/",
          snippet: "Download the latest Ruby." },
        { title: "Ruby on Wikipedia", link: "https://en.wikipedia.org/wiki/Ruby_(programming_language)",
          snippet: "Ruby is an interpreted language." }
      ]
    end

    it "turns an answer box into an evidence item" do
      stub_serpapi_payload(results: organic, answer_box: serpapi_answer_box)

      evidence = described_class.new.search("ruby current stable release")

      box = evidence.first
      expect(box.origin).to eq(described_class::ORIGIN_ANSWER_BOX)
      expect(box.title).to eq("Ruby Releases")
      expect(box.snippet).to eq("The current stable version of Ruby is 3.4.1, released 25 December 2024.")
      expect(box.link).to eq("https://www.ruby-lang.org/en/downloads/releases/")
      expect(box).to be_citable
    end

    it "turns a knowledge graph panel into an evidence item, linked via source" do
      stub_serpapi_payload(results: organic, knowledge_graph: serpapi_knowledge_graph)

      graph = described_class.new.search("eiffel tower location").first

      expect(graph.origin).to eq(described_class::ORIGIN_KNOWLEDGE_GRAPH)
      expect(graph.title).to eq("Eiffel Tower — Tower in Paris, France")
      expect(graph.snippet).to include("Champ de Mars")
      expect(graph.link).to eq("https://en.wikipedia.org/wiki/Eiffel_Tower")
    end

    it "puts direct answers ahead of organic results without dropping them" do
      stub_serpapi_payload(results: organic, answer_box: serpapi_answer_box,
                           knowledge_graph: serpapi_knowledge_graph)

      origins = described_class.new.search("anything").map(&:origin)

      expect(origins).to eq([
        described_class::ORIGIN_ANSWER_BOX,
        described_class::ORIGIN_KNOWLEDGE_GRAPH,
        described_class::ORIGIN_ORGANIC,
        described_class::ORIGIN_ORGANIC
      ])
    end

    it "keeps a knowledge graph panel that has no link, marked uncitable" do
      stub_serpapi_payload(results: organic,
                           knowledge_graph: serpapi_knowledge_graph(source: nil, website: nil))

      graph = described_class.new.search("anything").first

      expect(graph.origin).to eq(described_class::ORIGIN_KNOWLEDGE_GRAPH)
      expect(graph.link).to be_nil
      expect(graph).not_to be_citable
    end

    it "falls back to the knowledge graph's website when there is no source link" do
      stub_serpapi_payload(results: organic,
                           knowledge_graph: serpapi_knowledge_graph(source: nil, website: "https://www.toureiffel.paris/en"))

      expect(described_class.new.search("anything").first.link).to eq("https://www.toureiffel.paris/en")
    end

    it "reads an answer box that carries `answer` rather than `snippet`" do
      stub_serpapi_payload(results: organic,
                           answer_box: { type: "calculator_result", answer: "8.2 billion", link: "https://example.gov/pop" })

      box = described_class.new.search("world population").first

      expect(box.snippet).to eq("8.2 billion")
      expect(box.origin).to eq(described_class::ORIGIN_ANSWER_BOX)
    end

    it "skips a panel with no usable text at all" do
      stub_serpapi_payload(results: organic,
                           answer_box: { type: "map", displayed_link: "maps.google.com" },
                           knowledge_graph: { title: "Thing", type: "Entity" })

      expect(described_class.new.search("anything").map(&:origin)).to all(eq(described_class::ORIGIN_ORGANIC))
    end

    it "behaves exactly as before when neither panel is present" do
      stub_serpapi_payload(results: organic)

      evidence = described_class.new.search("anything")

      expect(evidence.length).to eq(2)
      expect(evidence.map(&:origin)).to all(eq(described_class::ORIGIN_ORGANIC))
      expect(evidence.first.title).to eq("Ruby downloads")
    end

    it "still trims to the limit, tail first" do
      many = Array.new(8) { |i| { title: "R#{i}", link: "https://example.com/#{i}", snippet: "s#{i}" } }
      stub_serpapi_payload(results: many, answer_box: serpapi_answer_box)

      evidence = described_class.new.search("anything", limit: 3)

      expect(evidence.length).to eq(3)
      expect(evidence.first.origin).to eq(described_class::ORIGIN_ANSWER_BOX)
    end
  end
end
