# frozen_string_literal: true

require "rails_helper"

RSpec.describe "POST /api/v1/checks", type: :request do
  let(:text) { "Ruby 3.3 shipped YJIT as its production JIT compiler." }
  let(:claim_statement) { "Ruby 3.3 shipped YJIT as its production JIT compiler" }

  let(:extracted_claims) { [ { claim: claim_statement, type: "fact" } ] }
  let(:search_query) { "ruby 3.3 yjit production jit compiler" }
  let(:source_url) { "https://www.ruby-lang.org/en/news/2023/12/25/ruby-3-3-0-released/" }

  let(:verdict) do
    {
      verdict: "verified",
      reason: "The Ruby 3.3.0 release announcement lists YJIT as production ready.",
      source_url: source_url
    }
  end

  let(:search_results) do
    [
      {
        title: "Ruby 3.3.0 Released",
        link: source_url,
        snippet: "Ruby 3.3 ships YJIT and is production ready."
      }
    ]
  end

  def json
    JSON.parse(response.body)
  end

  def submit(body = { text: text })
    post "/api/v1/checks", params: body, headers: api_key_headers, as: :json
  end

  def stub_full_pipeline
    stub_claude_routing(claims: extracted_claims, query: search_query, verdict: verdict)
    stub_serpapi_results(search_results)
  end

  describe "authentication" do
    it "rejects a request with no X-API-Key, before any upstream call" do
      stub_full_pipeline

      post "/api/v1/checks", params: { text: text }, as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(json.dig("error", "code")).to eq("api_key_missing")
      expect(claude_requests_made).not_to have_been_made
      expect(a_serpapi_request).not_to have_been_made
    end

    it "rejects an unknown X-API-Key" do
      post "/api/v1/checks", params: { text: text }, headers: api_key_headers("nope"), as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(json.dig("error", "code")).to eq("api_key_invalid")
    end

    it "accepts any of the comma-separated keys" do
      stub_full_pipeline

      post "/api/v1/checks",
           params: { text: text },
           headers: api_key_headers(ApiKeyHelpers::OTHER_VALID_API_KEY),
           as: :json

      expect(response).to have_http_status(:ok)
    end
  end

  describe "a fresh claim" do
    before { stub_full_pipeline }

    it "returns the full report" do
      submit

      expect(response).to have_http_status(:ok)
      expect(json["claims"]).to eq(
        [
          {
            "claim" => claim_statement,
            "type" => "fact",
            "verdict" => "verified",
            "reason" => "The Ruby 3.3.0 release announcement lists YJIT as production ready.",
            "source_url" => source_url,
            "source_type" => "organic",
            "time_sensitive" => false,
            "cached" => false,
            "checked_at" => json["claims"].first["checked_at"]
          }
        ]
      )
      expect(json["claims"].first["checked_at"]).to match(/\A\d{4}-\d{2}-\d{2}T[\d:]+Z\z/)
    end

    it "summarizes the input" do
      submit

      expect(json["input_summary"]).to eq(
        "characters" => text.length,
        "claims_extracted" => 1,
        "cached_claims" => 0,
        "verdicts" => { "verified" => 1, "unconfirmed" => 0, "contradicted" => 0 }
      )
      expect(json["checked_at"]).to be_present
    end

    it "makes the extraction, search-query, search and verdict calls" do
      submit

      expect(an_extraction_request).to have_been_made.once
      expect(a_search_query_request).to have_been_made.once
      expect(a_verdict_request).to have_been_made.once
      expect(a_serpapi_request_for(search_query)).to have_been_made.once
    end

    it "persists the verdict" do
      submit

      stored = Claim.first
      expect(Claim.count).to eq(1)
      expect(stored.claim_text).to eq(claim_statement)
      expect(stored.claim_type).to eq("fact")
      expect(stored.verdict).to eq("verified")
      expect(stored.source_url).to eq(source_url)
      expect(stored.claim_hash).to eq(Claim.hash_for(claim_statement))
      expect(stored.checked_at).to be_present
    end
  end

  describe "a repeated claim" do
    before { stub_full_pipeline }

    it "serves the second request from the cache and skips the verification calls" do
      submit

      expect(json["claims"].first["cached"]).to be(false)
      expect(a_search_query_request).to have_been_made.once
      expect(a_verdict_request).to have_been_made.once
      expect(a_serpapi_request).to have_been_made.once

      submit

      expect(response).to have_http_status(:ok)
      expect(json["claims"].first["cached"]).to be(true)

      # The assertion that matters: still ONCE, not twice. The second request
      # reached a verdict without asking Claude to rule again and without paying
      # SerpApi for another search.
      expect(a_search_query_request).to have_been_made.once
      expect(a_verdict_request).to have_been_made.once
      expect(a_serpapi_request).to have_been_made.once
    end

    it "still extracts, because only verdicts are cached and not the input text" do
      submit
      submit

      # Worth being precise about: a repeat request is one Claude call, not zero.
      expect(an_extraction_request).to have_been_made.twice
    end

    it "returns the same verdict and the original checked_at" do
      submit
      first_checked_at = json["claims"].first["checked_at"]

      submit

      expect(json["claims"].first).to include(
        "verdict" => "verified",
        "source_url" => source_url,
        "checked_at" => first_checked_at
      )
    end

    it "does not write a second row" do
      submit
      submit

      expect(Claim.count).to eq(1)
    end

    it "hits the cache through normalization, not just on an exact match" do
      submit

      post "/api/v1/checks",
           params: { text: "ruby 3.3 shipped yjit as its production jit compiler" },
           headers: api_key_headers,
           as: :json

      expect(json["claims"].first["cached"]).to be(true)
      expect(a_verdict_request).to have_been_made.once
    end

    it "counts cached claims in the summary" do
      submit
      submit

      expect(json["input_summary"]).to include("cached_claims" => 1, "claims_extracted" => 1)
    end
  end

  describe "a mix of cached and fresh claims" do
    let(:second_statement) { "Rails 8 was downloaded 400 million times" }

    it "verifies only the claim it has not seen" do
      stub_claude_routing(claims: extracted_claims, query: search_query, verdict: verdict)
      stub_serpapi_results(search_results)
      submit

      stub_claude_routing(
        claims: [ { claim: claim_statement, type: "fact" }, { claim: second_statement, type: "statistic" } ],
        query: "rails 8 downloads",
        verdict: { verdict: "unconfirmed", reason: "No figure in the results.", source_url: nil }
      )

      post "/api/v1/checks", params: { text: "#{text} #{second_statement}." },
                             headers: api_key_headers, as: :json

      expect(json["claims"].map { |claim| claim["cached"] }).to eq([ true, false ])
      expect(json["input_summary"]).to include(
        "claims_extracted" => 2,
        "cached_claims" => 1,
        "verdicts" => { "verified" => 1, "unconfirmed" => 1, "contradicted" => 0 }
      )
      # One verdict call for the new claim only, not two.
      expect(a_verdict_request).to have_been_made.twice
      expect(Claim.count).to eq(2)
    end
  end

  # "The current stable release is X" stops being true without anyone editing
  # the sentence, so these claims are searched inside Google's past-year window
  # and their verdicts expire.
  describe "a time-sensitive claim" do
    let(:fresh_text) { "Ruby's current stable release is 3.4.1." }
    let(:fresh_statement) { "Ruby's current stable release is 3.4.1" }

    before do
      stub_claude_routing(
        claims: [ { claim: fresh_statement, type: "fact", time_sensitive: true } ],
        query: search_query,
        verdict: verdict
      )
      stub_serpapi_results(search_results)
    end

    def submit_fresh
      post "/api/v1/checks", params: { text: fresh_text }, headers: api_key_headers, as: :json
    end

    it "reports the flag on the claim and restricts the search to the past year" do
      submit_fresh

      expect(json["claims"].first).to include("claim" => fresh_statement, "time_sensitive" => true)
      expect(a_fresh_serpapi_request).to have_been_made.once
    end

    it "stores the verdict with an expiry" do
      submit_fresh

      stored = Claim.first
      expect(stored.time_sensitive).to be(true)
      expect(stored.expires_at).to be_within(1.minute).of(Claim::TIME_SENSITIVE_TTL.from_now)
    end

    it "re-verifies the claim once the stored verdict has expired" do
      submit_fresh
      expect(json["claims"].first["cached"]).to be(false)

      Claim.first.update!(expires_at: 1.minute.ago)

      submit_fresh

      # Not a cache hit, and not a 500 either: the expired row is still in the
      # unique index at this point, so the second check has to overwrite it
      # rather than insert alongside it.
      expect(response).to have_http_status(:ok)
      expect(json["claims"].first["cached"]).to be(false)
      expect(a_verdict_request).to have_been_made.twice
      expect(Claim.count).to eq(1)
      expect(Claim.first.expires_at).to be > Time.current
    end
  end

  describe "source_type on the wire" do
    let(:knowledge_graph_url) { "https://en.wikipedia.org/wiki/Ruby_(programming_language)" }

    it "reports which part of the payload the citation came from, and stores it" do
      stub_claude_routing(
        claims: extracted_claims,
        query: search_query,
        verdict: { verdict: "verified", reason: "The panel says so.", source_url: knowledge_graph_url }
      )
      stub_serpapi_payload(
        results: search_results,
        knowledge_graph: serpapi_knowledge_graph(
          title: "Ruby", description: "Ruby 3.3 ships YJIT.",
          source: { name: "Wikipedia", link: knowledge_graph_url }
        )
      )

      submit

      expect(json["claims"].first).to include(
        "source_url" => knowledge_graph_url,
        "source_type" => "knowledge_graph"
      )
      expect(Claim.first.source_type).to eq("knowledge_graph")
    end

    it "sends null rather than omitting the field when nothing was cited" do
      stub_claude_routing(
        claims: extracted_claims,
        query: search_query,
        verdict: { verdict: "unconfirmed", reason: "Nothing on point.", source_url: nil }
      )
      stub_serpapi_results(search_results)

      submit

      expect(json["claims"].first).to have_key("source_type")
      expect(json["claims"].first["source_type"]).to be_nil
    end
  end

  describe "input handling" do
    it "returns 400 when text is missing entirely" do
      submit({ max_claims: 3 })

      expect(response).to have_http_status(:bad_request)
      expect(json.dig("error", "code")).to eq("parameter_missing")
      expect(claude_requests_made).not_to have_been_made
    end

    it "returns 400 when text is present but blank" do
      submit({ text: "   " })

      # params.require treats a blank value as missing, and its message says so
      # ("param is missing or the value is empty"), so this is one error rather
      # than two. ClaimExtractorService still rejects blank text as a 422 for
      # callers that reach it directly.
      expect(response).to have_http_status(:bad_request)
      expect(json.dig("error", "code")).to eq("parameter_missing")
      expect(json.dig("error", "message")).to match(/text/)
      expect(claude_requests_made).not_to have_been_made
    end

    it "passes max_claims through to extraction" do
      stub_claude_routing(
        claims: [
          { claim: claim_statement, type: "fact" },
          { claim: "Rails 8 was downloaded 400 million times", type: "statistic" }
        ],
        query: search_query,
        verdict: verdict
      )
      stub_serpapi_results(search_results)

      submit({ text: text, max_claims: 1 })

      expect(json["claims"].length).to eq(1)
    end

    it "rejects a non-numeric max_claims" do
      submit({ text: text, max_claims: "lots" })

      expect(response).to have_http_status(:unprocessable_content)
      expect(json.dig("error", "code")).to eq("validation_failed")
    end

    it "returns 413 for text past the length cap" do
      submit({ text: "a" * (ClaimExtractorService::MAX_TEXT_LENGTH + 1) })

      expect(response).to have_http_status(:content_too_large)
      expect(json.dig("error", "code")).to eq("payload_too_large")
    end
  end

  # "Nothing to check" and "could not read the reply" used to collapse into the
  # same 500. They are different answers and now have different status codes.
  describe "text with no checkable claims" do
    let(:opinion) { "Rails is the best framework and everyone should use it." }

    before { stub_claude_routing(claims: [], query: search_query, verdict: verdict) }

    def submit_opinion
      post "/api/v1/checks", params: { text: opinion }, headers: api_key_headers, as: :json
    end

    it "answers 200, not 500" do
      submit_opinion

      expect(response).to have_http_status(:ok)
    end

    it "returns an empty claim list with a message explaining why" do
      submit_opinion

      expect(json["claims"]).to eq([])
      expect(json["message"]).to eq("No checkable factual claims found.")
      expect(json["input_summary"]).to include(
        "claims_extracted" => 0,
        "cached_claims" => 0,
        "verdicts" => { "verified" => 0, "unconfirmed" => 0, "contradicted" => 0 }
      )
      expect(json["checked_at"]).to be_present
    end

    it "carries no error envelope" do
      submit_opinion

      expect(json).not_to have_key("error")
    end

    it "spends nothing on verification - there is nothing to verify" do
      submit_opinion

      expect(an_extraction_request).to have_been_made.once
      expect(a_search_query_request).not_to have_been_made
      expect(a_verdict_request).not_to have_been_made
      expect(a_serpapi_request).not_to have_been_made
      expect(Claim.count).to eq(0)
    end

    it "omits the message entirely when there are claims to report" do
      stub_full_pipeline
      submit

      expect(response).to have_http_status(:ok)
      expect(json).not_to have_key("message")
    end
  end

  describe "a reply that could not be read" do
    def submit_opinion
      post "/api/v1/checks", params: { text: "anything" }, headers: api_key_headers, as: :json
    end

    it "still returns 500 when the extraction reply is not JSON" do
      stub_claude_routing(claims: "I'm afraid I can't help with that.", query: search_query, verdict: verdict)

      submit_opinion

      expect(response).to have_http_status(:internal_server_error)
      expect(json.dig("error", "code")).to eq("claim_extraction_failed")
    end

    it "still returns 500 when the reply is a JSON object rather than a list" do
      stub_claude_routing(claims: { claims: [] }.to_json, query: search_query, verdict: verdict)

      submit_opinion

      expect(response).to have_http_status(:internal_server_error)
      expect(json.dig("error", "code")).to eq("claim_extraction_failed")
    end

    it "still returns 500 on an unknown claim type" do
      stub_claude_routing(
        claims: [ { claim: "Rails is great", type: "opinion" } ],
        query: search_query,
        verdict: verdict
      )

      submit_opinion

      expect(response).to have_http_status(:internal_server_error)
      expect(json.dig("error", "code")).to eq("claim_extraction_failed")
    end
  end

  describe "upstream failure" do
    it "surfaces a verification failure as a 500 with its own code" do
      stub_claude_routing(claims: extracted_claims, query: search_query, verdict: "not json at all")
      stub_serpapi_results(search_results)

      submit

      expect(response).to have_http_status(:internal_server_error)
      expect(json.dig("error", "code")).to eq("verification_failed")
      expect(Claim.count).to eq(0)
    end

    it "surfaces a SerpApi outage as a verification failure" do
      stub_claude_routing(claims: extracted_claims, query: search_query, verdict: verdict)
      stub_serpapi_status(503)

      submit

      expect(response).to have_http_status(:internal_server_error)
      expect(json.dig("error", "code")).to eq("verification_failed")
    end
  end
end
