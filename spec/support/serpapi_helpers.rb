# frozen_string_literal: true

# Builds realistic SerpApi Google Search responses and stubs them with WebMock,
# so specs exercise SerpGuard::SerpapiClient's real HTTParty call.
module SerpapiHelpers
  SERPAPI_SEARCH_URL = "https://serpapi.com/search"
  TEST_SERPAPI_KEY = "serpapi-test-key-0123456789"

  JSON_HEADERS = { "content-type" => "application/json" }.freeze

  # @param results [Array<Hash>] :title, :link, :snippet per organic result
  def serpapi_body(results, **overrides)
    {
      search_metadata: { id: "spec", status: "Success" },
      search_parameters: { engine: "google" },
      search_information: { organic_results_state: "Results for exact spelling" },
      organic_results: results.each_with_index.map do |result, index|
        {
          position: index + 1,
          title: result[:title],
          link: result[:link],
          displayed_link: result[:link],
          snippet: result[:snippet]
        }.compact
      end
    }.merge(overrides).to_json
  end

  # Realistic shapes, trimmed to the fields the client reads. Both panels come
  # back on the same search as organic_results - no extra API call.
  def serpapi_answer_box(**overrides)
    {
      type: "organic_result",
      title: "Ruby Releases",
      link: "https://www.ruby-lang.org/en/downloads/releases/",
      snippet: "The current stable version of Ruby is 3.4.1, released 25 December 2024.",
      snippet_highlighted_words: [ "3.4.1" ]
    }.merge(overrides)
  end

  def serpapi_knowledge_graph(**overrides)
    {
      title: "Eiffel Tower",
      type: "Tower in Paris, France",
      description: "The Eiffel Tower is a wrought-iron lattice tower on the Champ de Mars in Paris, France.",
      source: { name: "Wikipedia", link: "https://en.wikipedia.org/wiki/Eiffel_Tower" }
    }.merge(overrides)
  end

  # One stub covering every part of a Google payload the client reads, with
  # optional matching on the query string and on the freshness filter.
  def stub_serpapi_payload(results: [], answer_box: nil, knowledge_graph: nil, query: nil, fresh: nil)
    matcher = { "engine" => "google" }
    matcher["q"] = query if query
    matcher["tbs"] = SerpGuard::SerpapiClient::FRESH_WINDOW if fresh

    extras = {}
    extras[:answer_box] = answer_box if answer_box
    extras[:knowledge_graph] = knowledge_graph if knowledge_graph

    request = stub_request(:get, SERPAPI_SEARCH_URL).with(query: hash_including(matcher))
    request = request.with { |req| !req.uri.query.to_s.include?("tbs=") } if fresh == false

    request.to_return(status: 200, body: serpapi_body(results, **extras), headers: JSON_HEADERS)
  end

  # Matchers that care whether the date filter was sent.
  def a_fresh_serpapi_request
    a_request(:get, SERPAPI_SEARCH_URL)
      .with(query: hash_including("tbs" => SerpGuard::SerpapiClient::FRESH_WINDOW))
  end

  def an_unfiltered_serpapi_request
    a_request(:get, SERPAPI_SEARCH_URL).with { |req| !req.uri.query.to_s.include?("tbs=") }
  end

  def stub_serpapi_results(results)
    stub_request(:get, SERPAPI_SEARCH_URL)
      .with(query: hash_including("engine" => "google"))
      .to_return(status: 200, body: serpapi_body(results), headers: JSON_HEADERS)
  end

  # SerpApi answers 200 with an `error` string when Google returned nothing.
  def stub_serpapi_no_results
    stub_request(:get, SERPAPI_SEARCH_URL)
      .with(query: hash_including("engine" => "google"))
      .to_return(
        status: 200,
        body: { error: "Google hasn't returned any results for this query." }.to_json,
        headers: JSON_HEADERS
      )
  end

  # Per-query stubs, so one example can give a bad query off-topic results and a
  # reformulated query good ones.
  def stub_serpapi_results_for(query, results)
    stub_request(:get, SERPAPI_SEARCH_URL)
      .with(query: hash_including("q" => query))
      .to_return(status: 200, body: serpapi_body(results), headers: JSON_HEADERS)
  end

  def stub_serpapi_no_results_for(query)
    stub_request(:get, SERPAPI_SEARCH_URL)
      .with(query: hash_including("q" => query))
      .to_return(
        status: 200,
        body: { error: "Google hasn't returned any results for this query." }.to_json,
        headers: JSON_HEADERS
      )
  end

  def stub_serpapi_status(status, message: "SerpApi is having a moment", headers: {})
    stub_request(:get, SERPAPI_SEARCH_URL)
      .with(query: hash_including("engine" => "google"))
      .to_return(status: status, body: { error: message }.to_json, headers: JSON_HEADERS.merge(headers))
  end

  def a_serpapi_request
    a_request(:get, SERPAPI_SEARCH_URL).with(query: hash_including("engine" => "google"))
  end

  def a_serpapi_request_for(query)
    a_request(:get, SERPAPI_SEARCH_URL).with(query: hash_including("q" => query))
  end
end

RSpec.configure do |config|
  config.include SerpapiHelpers

  config.around(:each) do |example|
    previous = ENV["SERPAPI_KEY"]
    ENV["SERPAPI_KEY"] = SerpapiHelpers::TEST_SERPAPI_KEY
    begin
      example.run
    ensure
      ENV["SERPAPI_KEY"] = previous
    end
  end
end
