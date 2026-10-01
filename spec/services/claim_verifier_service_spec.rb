# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClaimVerifierService do
  # Both upstreams are stubbed with WebMock, so these specs run through the real
  # HTTParty call in ClaudeClient and SerpapiClient.
  let(:claim) { { claim: "Ruby 3.3 shipped YJIT as its production JIT compiler", type: "fact" } }
  let(:generated_query) { "ruby 3.3 yjit production jit compiler release" }

  let(:search_results) do
    [
      {
        title: "Ruby 3.3.0 Released",
        link: "https://www.ruby-lang.org/en/news/2023/12/25/ruby-3-3-0-released/",
        snippet: "Ruby 3.3 ships YJIT with improved performance and is production ready."
      },
      {
        title: "YJIT: Building a New JIT Compiler",
        link: "https://shopify.engineering/yjit-just-in-time-compiler-ruby",
        snippet: "YJIT is a just-in-time compiler built into CRuby."
      },
      {
        title: "Ruby release notes",
        link: "https://www.ruby-lang.org/en/downloads/releases/",
        snippet: "A list of Ruby releases and their dates."
      }
    ]
  end

  def verdict_json(verdict:, reason:, source_url:)
    { verdict: verdict, reason: reason, source_url: source_url }.to_json
  end

  describe "a verified claim" do
    before do
      stub_serpapi_results(search_results)
      stub_claude_sequence(
        generated_query,
        verdict_json(
          verdict: "verified",
          reason: "The Ruby 3.3.0 release announcement lists YJIT as production ready.",
          source_url: "https://www.ruby-lang.org/en/news/2023/12/25/ruby-3-3-0-released/"
        )
      )
    end

    it "returns the verdict with its reason and source" do
      expect(described_class.call(claim)).to eq(
        claim: "Ruby 3.3 shipped YJIT as its production JIT compiler",
        verdict: "verified",
        reason: "The Ruby 3.3.0 release announcement lists YJIT as production ready.",
        source_url: "https://www.ruby-lang.org/en/news/2023/12/25/ruby-3-3-0-released/",
        source_type: "organic"
      )
    end

    it "searches SerpApi with the query Claude generated" do
      described_class.call(claim)

      expect(a_serpapi_request_for(generated_query)).to have_been_made.once
    end

    it "asks Claude for a query first, then for a verdict" do
      described_class.call(claim)

      expect(claude_requests_made).to have_been_made.twice
      expect(
        a_claude_request_where { |body| body["system"].include?("one Google search query") }
      ).to have_been_made.once
      expect(
        a_claude_request_where { |body| body["system"].include?("rule on whether search results") }
      ).to have_been_made.once
    end

    it "gives Claude the snippets and their URLs to judge against" do
      described_class.call(claim)

      expect(
        a_claude_request_where { |body|
          prompt = body["messages"].first["content"]

          prompt.include?("<search_results>") &&
            prompt.include?("https://www.ruby-lang.org/en/news/2023/12/25/ruby-3-3-0-released/") &&
            prompt.include?("Ruby 3.3 ships YJIT with improved performance") &&
            prompt.include?("Ruby 3.3 shipped YJIT as its production JIT compiler")
        }
      ).to have_been_made.once
    end

    it "accepts a Claim from ClaimExtractorService without conversion" do
      extracted = ClaimExtractorService::Claim.new(
        claim: "Ruby 3.3 shipped YJIT as its production JIT compiler",
        type: "fact"
      )

      expect(described_class.call(extracted)[:verdict]).to eq("verified")
    end

    it "accepts string keys" do
      result = described_class.call(
        "claim" => "Ruby 3.3 shipped YJIT as its production JIT compiler",
        "type" => "fact"
      )

      expect(result[:verdict]).to eq("verified")
    end
  end

  describe "a contradicted claim" do
    let(:claim) { { claim: "Ruby 3.3 removed YJIT entirely", type: "fact" } }

    before do
      stub_serpapi_results(search_results)
      stub_claude_sequence(
        "ruby 3.3 yjit removed",
        verdict_json(
          verdict: "contradicted",
          reason: "The 3.3.0 release notes say YJIT ships and is production ready.",
          source_url: "https://www.ruby-lang.org/en/news/2023/12/25/ruby-3-3-0-released/"
        )
      )
    end

    it "returns the contradicted verdict with the source that refutes it" do
      result = described_class.call(claim)

      expect(result[:verdict]).to eq("contradicted")
      expect(result[:reason]).to eq("The 3.3.0 release notes say YJIT ships and is production ready.")
      expect(result[:source_url]).to eq("https://www.ruby-lang.org/en/news/2023/12/25/ruby-3-3-0-released/")
    end
  end

  describe "an unconfirmed claim" do
    it "short-circuits when Google returned no results at all" do
      stub_serpapi_no_results
      stub_claude_sequence(generated_query)

      result = described_class.call(claim)

      expect(result).to eq(
        claim: "Ruby 3.3 shipped YJIT as its production JIT compiler",
        verdict: "unconfirmed",
        reason: "No search results were found for this claim.",
        source_url: nil,
        source_type: nil
      )
    end

    it "does not pay for a verdict call when there is no evidence to weigh" do
      stub_serpapi_no_results
      stub_claude_sequence(generated_query)

      described_class.call(claim)

      # Only the query call - asking for a verdict on nothing could not answer
      # anything else.
      expect(claude_requests_made).to have_been_made.once
    end

    it "treats results with no snippet as no evidence" do
      stub_serpapi_results([ { title: "Some page", link: "https://example.com", snippet: nil } ])
      stub_claude_sequence(generated_query)

      expect(described_class.call(claim)[:verdict]).to eq("unconfirmed")
      expect(claude_requests_made).to have_been_made.once
    end

    it "returns unconfirmed with no source when the results are off-topic" do
      stub_serpapi_results(
        [ { title: "Cooking with rubies", link: "https://example.com/rubies", snippet: "A gemstone guide." } ]
      )
      stub_claude_sequence(
        generated_query,
        verdict_json(
          verdict: "unconfirmed",
          reason: "The results are about gemstones, not the Ruby language.",
          source_url: nil
        )
      )

      result = described_class.call(claim)

      expect(result[:verdict]).to eq("unconfirmed")
      expect(result[:source_url]).to be_nil
    end
  end

  describe "VerificationFailed" do
    context "when Claude's verdict cannot be parsed" do
      it "raises rather than defaulting to unconfirmed" do
        stub_serpapi_results(search_results)
        stub_claude_sequence(generated_query, "Honestly, it's hard to say either way.")

        expect { described_class.call(claim) }
          .to raise_error(SerpGuard::Errors::VerificationFailed, /did not return valid JSON/)
      end

      it "raises on a verdict value outside the three allowed ones" do
        stub_serpapi_results(search_results)
        stub_claude_sequence(
          generated_query,
          verdict_json(verdict: "probably true", reason: "Looks right.", source_url: nil)
        )

        expect { described_class.call(claim) }
          .to raise_error(
            SerpGuard::Errors::VerificationFailed,
            /unrecognised verdict "probably true"/
          )
      end

      it "never silently downgrades an unreadable verdict to unconfirmed" do
        stub_serpapi_results(search_results)
        stub_claude_sequence(generated_query, verdict_json(verdict: "", reason: "?", source_url: nil))

        # The distinction this whole class is built around: "unconfirmed" is a
        # finding, an unreadable answer is an error.
        expect { described_class.call(claim) }.to raise_error(SerpGuard::Errors::VerificationFailed)
      end

      it "raises when the verdict JSON is an array rather than an object" do
        stub_serpapi_results(search_results)
        stub_claude_sequence(generated_query, [ { verdict: "verified" } ].to_json)

        expect { described_class.call(claim) }
          .to raise_error(SerpGuard::Errors::VerificationFailed, /Expected a JSON object/)
      end

      it "raises when a verdict arrives with no reason" do
        stub_serpapi_results(search_results)
        stub_claude_sequence(
          generated_query,
          verdict_json(verdict: "verified", reason: "  ", source_url: nil)
        )

        expect { described_class.call(claim) }
          .to raise_error(SerpGuard::Errors::VerificationFailed, /no reason/)
      end

      it "raises when the verdict was cut off at the token limit" do
        stub_serpapi_results(search_results)
        stub_request(:post, AnthropicHelpers::CLAUDE_MESSAGES_URL).to_return(
          { status: 200, body: claude_message_body(generated_query), headers: AnthropicHelpers::JSON_HEADERS },
          { status: 200, body: claude_message_body('{"verdict": "veri', stop_reason: "max_tokens"),
            headers: AnthropicHelpers::JSON_HEADERS }
        )

        expect { described_class.call(claim) }
          .to raise_error(SerpGuard::Errors::VerificationFailed, /cut off at the token limit/)
      end

      it "tolerates a code fence around otherwise valid verdict JSON" do
        stub_serpapi_results(search_results)
        stub_claude_sequence(
          generated_query,
          "```json\n#{verdict_json(verdict: 'verified', reason: 'Confirmed by the release notes.', source_url: nil)}\n```"
        )

        expect(described_class.call(claim)[:verdict]).to eq("verified")
      end
    end

    context "when SerpApi fails" do
      it "raises after the client's retry is exhausted" do
        stub_claude_sequence(generated_query)
        stub_serpapi_status(500, message: "internal error")

        expect { described_class.call(claim) }
          .to raise_error(SerpGuard::Errors::VerificationFailed, /Search failed/)
        expect(a_serpapi_request).to have_been_made.twice
      end

      it "raises when SerpApi times out" do
        stub_claude_sequence(generated_query)
        stub_request(:get, SerpapiHelpers::SERPAPI_SEARCH_URL)
          .with(query: hash_including("engine" => "google")).to_timeout

        expect { described_class.call(claim) }
          .to raise_error(SerpGuard::Errors::VerificationFailed, /Search failed/)
      end

      it "keeps the underlying upstream error as the cause for the logs" do
        stub_claude_sequence(generated_query)
        stub_serpapi_status(503)

        error = begin
          described_class.call(claim)
        rescue SerpGuard::Errors::VerificationFailed => e
          e
        end

        expect(error.cause).to be_a(SerpGuard::Errors::SerpApiError)
        expect(error.cause.message).to include("HTTP 503")
      end

      it "raises when SerpApi reports a non-empty search failure on a 200" do
        stub_claude_sequence(generated_query)
        stub_request(:get, SerpapiHelpers::SERPAPI_SEARCH_URL)
          .with(query: hash_including("engine" => "google"))
          .to_return(
            status: 200,
            body: { error: "Unsupported engine parameter" }.to_json,
            headers: SerpapiHelpers::JSON_HEADERS
          )

        expect { described_class.call(claim) }
          .to raise_error(SerpGuard::Errors::VerificationFailed, /Search failed/)
      end
    end

    context "when Claude fails" do
      it "raises when the query call fails after retry" do
        stub_claude_status(500)

        expect { described_class.call(claim) }
          .to raise_error(SerpGuard::Errors::VerificationFailed, /search query generation/)
        expect(claude_requests_made).to have_been_made.twice
        expect(a_serpapi_request).not_to have_been_made
      end

      it "raises when the verdict call fails after retry" do
        stub_serpapi_results(search_results)
        stub_request(:post, AnthropicHelpers::CLAUDE_MESSAGES_URL).to_return(
          { status: 200, body: claude_message_body(generated_query), headers: AnthropicHelpers::JSON_HEADERS },
          { status: 502, body: "{}", headers: AnthropicHelpers::JSON_HEADERS },
          { status: 502, body: "{}", headers: AnthropicHelpers::JSON_HEADERS }
        )

        expect { described_class.call(claim) }
          .to raise_error(SerpGuard::Errors::VerificationFailed, /Claude failed during verdict/)
      end

      it "raises when Claude returns an unusable search query" do
        stub_claude_sequence("   ")

        expect { described_class.call(claim) }
          .to raise_error(SerpGuard::Errors::VerificationFailed, /no usable search query/)
        expect(a_serpapi_request).not_to have_been_made
      end
    end

    it "carries the pipeline error code and status" do
      stub_serpapi_results(search_results)
      stub_claude_sequence(generated_query, "not json")

      error = begin
        described_class.call(claim)
      rescue SerpGuard::Errors::VerificationFailed => e
        e
      end

      expect(error.code).to eq("verification_failed")
      expect(error.http_status).to eq(:internal_server_error)
    end
  end

  describe "guarding against a fabricated source" do
    it "drops a source_url that was not among the results sent to Claude" do
      stub_serpapi_results(search_results)
      stub_claude_sequence(
        generated_query,
        verdict_json(
          verdict: "verified",
          reason: "Confirmed by the release notes.",
          source_url: "https://ruby-lang.invalid/made-up-page"
        )
      )

      result = described_class.call(claim)

      # The verdict still stands on the snippets; the invented citation does not.
      expect(result[:verdict]).to eq("verified")
      expect(result[:source_url]).to be_nil
    end

    it "accepts a URL that differs only by a trailing slash" do
      stub_serpapi_results([ search_results.second ])
      stub_claude_sequence(
        generated_query,
        verdict_json(
          verdict: "verified",
          reason: "Shopify's post describes YJIT.",
          source_url: "#{search_results.second[:link]}/"
        )
      )

      expect(described_class.call(claim)[:source_url]).to eq(search_results.second[:link])
    end
  end

  describe "invalid input" do
    it "rejects a claim with no text before calling anything" do
      expect { described_class.call(claim: "", type: "fact") }
        .to raise_error(SerpGuard::Errors::ValidationError, /must have text/)

      expect(claude_requests_made).not_to have_been_made
      expect(a_serpapi_request).not_to have_been_made
    end
  end

  describe "snippet limit" do
    it "sends at most snippet_limit results to Claude" do
      many = Array.new(8) do |i|
        { title: "Result #{i}", link: "https://example.com/#{i}", snippet: "Snippet #{i}." }
      end
      stub_serpapi_results(many)
      stub_claude_sequence(
        generated_query,
        verdict_json(verdict: "unconfirmed", reason: "Too vague.", source_url: nil)
      )

      described_class.call(claim, snippet_limit: 3)

      expect(
        a_claude_request_where { |body|
          prompt = body["messages"].first["content"]
          prompt.include?("Snippet 2.") && !prompt.include?("Snippet 3.")
        }
      ).to have_been_made.once
    end
  end

  # Reproduces the exact live failure this retry exists for: the query read fine,
  # contained "Ruby on Rails", and Google answered with a civil rights activist,
  # a music video and Ruby-the-language. Every component behaved correctly; the
  # claim was simply unverifiable from those snippets.
  describe "reformulating a query that missed" do
    let(:claim) { { claim: "Ruby on Rails was created in 2004", type: "statistic" } }
    let(:first_query) { "Ruby on Rails initial release year 2004" }
    let(:second_query) { '"Ruby on Rails" release date 2004' }

    let(:off_topic_results) do
      [
        {
          title: "Ruby Bridges (@rubybridgesofficial)",
          link: "https://www.instagram.com/rubybridgesofficial/?hl=en",
          snippet: "Civil Rights Icon, Activist, Author, Speaker."
        },
        {
          title: "Ruby (programming language)",
          link: "https://en.wikipedia.org/wiki/Ruby_(programming_language)",
          snippet: "The first public release of Ruby 0.95 was announced in December 1995."
        }
      ]
    end

    let(:on_topic_results) do
      [
        {
          title: "Ruby on Rails",
          link: "https://en.wikipedia.org/wiki/Ruby_on_Rails",
          snippet: "Hansson first released Rails as open source in July 2004."
        }
      ]
    end

    def stub_reformulation_round(second_verdict:)
      stub_serpapi_results_for(first_query, off_topic_results)
      stub_serpapi_results_for(second_query, on_topic_results)
      stub_claude_sequence(
        first_query,
        verdict_json(verdict: "unconfirmed", reason: "Results cover Ruby the language, not Rails.", source_url: nil),
        second_query,
        second_verdict
      )
    end

    let(:good_second_verdict) do
      verdict_json(
        verdict: "verified",
        reason: "Wikipedia dates the first Rails release to July 2004.",
        source_url: "https://en.wikipedia.org/wiki/Ruby_on_Rails"
      )
    end

    it "searches a second time with the reformulated query" do
      stub_reformulation_round(second_verdict: good_second_verdict)

      described_class.call(claim)

      expect(a_serpapi_request_for(first_query)).to have_been_made.once
      expect(a_serpapi_request_for(second_query)).to have_been_made.once
    end

    it "returns the verdict from the second round, not the first" do
      stub_reformulation_round(second_verdict: good_second_verdict)

      expect(described_class.call(claim)).to eq(
        claim: "Ruby on Rails was created in 2004",
        verdict: "verified",
        reason: "Wikipedia dates the first Rails release to July 2004.",
        source_url: "https://en.wikipedia.org/wiki/Ruby_on_Rails",
        source_type: "organic"
      )
    end

    it "tells Claude which query failed and which term the results missed" do
      stub_reformulation_round(second_verdict: good_second_verdict)

      described_class.call(claim)

      expect(
        a_claude_request_where { |body|
          content = body["messages"].first["content"]
          content.include?("<failed_query>#{first_query}</failed_query>") &&
            content.include?('"Ruby on Rails"') &&
            content.include?("DIFFERENT query")
        }
      ).to have_been_made.once
    end

    it "costs one extra query call, search and verdict call - and no more" do
      stub_reformulation_round(second_verdict: good_second_verdict)

      described_class.call(claim)

      expect(a_search_query_request).to have_been_made.twice
      expect(a_verdict_request).to have_been_made.twice
      expect(a_serpapi_request).to have_been_made.twice
    end

    it "does not retry a second time when the reformulated query also misses" do
      stub_reformulation_round(
        second_verdict: verdict_json(verdict: "unconfirmed", reason: "Still nothing on point.", source_url: nil)
      )

      expect(described_class.call(claim)[:verdict]).to eq("unconfirmed")
      expect(a_search_query_request).to have_been_made.twice
      expect(a_serpapi_request).to have_been_made.twice
    end

    it "keeps the first verdict when Claude returns no usable reformulation" do
      stub_serpapi_results_for(first_query, off_topic_results)
      stub_claude_sequence(
        first_query,
        verdict_json(verdict: "unconfirmed", reason: "Results cover Ruby the language, not Rails.", source_url: nil),
        "   "
      )

      result = described_class.call(claim)

      # A blank reformulation must not turn a usable verdict into a 500.
      expect(result[:verdict]).to eq("unconfirmed")
      expect(result[:reason]).to eq("Results cover Ruby the language, not Rails.")
      expect(a_serpapi_request).to have_been_made.once
    end

    it "keeps the first verdict when the reformulated search finds nothing" do
      stub_serpapi_results_for(first_query, off_topic_results)
      stub_serpapi_no_results_for(second_query)
      stub_claude_sequence(
        first_query,
        verdict_json(verdict: "unconfirmed", reason: "Results cover Ruby the language, not Rails.", source_url: nil),
        second_query
      )

      expect(described_class.call(claim)[:verdict]).to eq("unconfirmed")
      expect(a_verdict_request).to have_been_made.once
    end
  end

  describe "when a retry is not warranted" do
    let(:claim) { { claim: "Ruby on Rails was created in 2004", type: "statistic" } }
    let(:query) { "Ruby on Rails release 2004" }

    let(:on_topic_results) do
      [
        {
          title: "Ruby on Rails",
          link: "https://en.wikipedia.org/wiki/Ruby_on_Rails",
          snippet: "Hansson first released Rails as open source in July 2004."
        }
      ]
    end

    let(:off_topic_results) do
      [
        {
          title: "Ruby Bridges",
          link: "https://www.instagram.com/rubybridgesofficial/?hl=en",
          snippet: "Civil Rights Icon, Activist, Author, Speaker."
        }
      ]
    end

    it "does not retry when the results do mention the claim's subject" do
      stub_serpapi_results_for(query, on_topic_results)
      stub_claude_sequence(
        query,
        verdict_json(verdict: "unconfirmed", reason: "The snippet is too vague about the date.", source_url: nil)
      )

      expect(described_class.call(claim)[:verdict]).to eq("unconfirmed")
      expect(a_search_query_request).to have_been_made.once
      expect(a_serpapi_request).to have_been_made.once
    end

    it "does not retry a verdict that is not unconfirmed, however off-topic the results" do
      stub_serpapi_results_for(query, off_topic_results)
      stub_claude_sequence(
        query,
        verdict_json(verdict: "contradicted", reason: "A result places the release in 1995.", source_url: nil)
      )

      expect(described_class.call(claim)[:verdict]).to eq("contradicted")
      expect(a_serpapi_request).to have_been_made.once
    end

    it "does not retry a claim with no distinctive term to test relevance against" do
      vague = { claim: "The world population is approximately 7.8 billion people", type: "statistic" }
      stub_serpapi_results_for("world population 7.8 billion", off_topic_results)
      stub_claude_sequence(
        "world population 7.8 billion",
        verdict_json(verdict: "unconfirmed", reason: "No figure in the results.", source_url: nil)
      )

      expect(described_class.call(vague)[:verdict]).to eq("unconfirmed")
      expect(a_search_query_request).to have_been_made.once
      expect(a_serpapi_request).to have_been_made.once
    end
  end

  # The live run cited an Instagram reel for "the Eiffel Tower is in London".
  # The verdict was right; the citation was useless. Ranking reorders evidence so
  # the model sees a citable source first - it never removes evidence.
  describe "ranking evidence by source authority" do
    let(:claim) { { claim: "The Eiffel Tower is located in London", type: "fact" } }
    let(:query) { '"Eiffel Tower" location' }

    let(:social_first_results) do
      [
        { title: "Paris reel", link: "https://www.instagram.com/reel/DVdjDY0kYuZ/?hl=en", snippet: "Tour Eiffel vibes" },
        { title: "Tower clip", link: "https://www.youtube.com/watch?v=abc123", snippet: "Eiffel Tower walkthrough" },
        { title: "Travel blog", link: "https://someblog.example.com/eiffel", snippet: "The Eiffel Tower is in Paris." },
        { title: "Eiffel Tower", link: "https://en.wikipedia.org/wiki/Eiffel_Tower", snippet: "The Eiffel Tower is on the Champ de Mars in Paris, France." }
      ]
    end

    def sent_result_order
      order = nil
      expect(
        a_claude_request_where { |body|
          content = body["messages"].first["content"]
          next false unless content.include?("<search_results>")

          order = content.scan(/^url: (.+)$/).flatten
          true
        }
      ).to have_been_made.at_least_once
      order
    end

    before do
      stub_serpapi_results_for(query, social_first_results)
      stub_claude_sequence(
        query,
        verdict_json(
          verdict: "contradicted",
          reason: "Results place the Eiffel Tower in Paris, not London.",
          source_url: "https://en.wikipedia.org/wiki/Eiffel_Tower"
        )
      )
    end

    it "puts the encyclopedic source ahead of social and video results" do
      described_class.call(claim)

      expect(sent_result_order.first).to eq("https://en.wikipedia.org/wiki/Eiffel_Tower")
      expect(sent_result_order.last(2)).to contain_exactly(
        "https://www.instagram.com/reel/DVdjDY0kYuZ/?hl=en",
        "https://www.youtube.com/watch?v=abc123"
      )
    end

    it "keeps every result - ranking reorders, it does not filter" do
      described_class.call(claim)

      expect(sent_result_order).to match_array(social_first_results.map { |result| result[:link] })
    end

    it "keeps Google's own order within a tier" do
      described_class.call(claim)

      social = sent_result_order.select { |url| url.include?("instagram") || url.include?("youtube") }
      expect(social).to eq(
        [ "https://www.instagram.com/reel/DVdjDY0kYuZ/?hl=en", "https://www.youtube.com/watch?v=abc123" ]
      )
    end

    it "still uses a social result when it is the only evidence there is" do
      only_social = [
        { title: "Paris reel", link: "https://www.instagram.com/reel/DVdjDY0kYuZ/?hl=en", snippet: "Eiffel Tower, Paris" }
      ]
      stub_serpapi_results_for(query, only_social)

      expect(described_class.call(claim)[:verdict]).to eq("contradicted")
      expect(sent_result_order).to eq([ "https://www.instagram.com/reel/DVdjDY0kYuZ/?hl=en" ])
    end
  end

  # Catching hallucinated code references is what this project is for, and
  # "unconfirmed" undersells it: a real method name returns something for a
  # search of its own name. Nothing, across every query tried, is evidence of
  # absence rather than absence of evidence.
  describe "a code_api claim whose method appears nowhere" do
    let(:claim) do
      { claim: "Rails provides ActiveRecord::Base.magic_query, which auto-generates optimized queries",
        type: "code_api" }
    end
    let(:first_query) { '"ActiveRecord::Base.magic_query" Rails' }
    let(:second_query) { 'Rails ActiveRecord "magic_query" method' }

    # Plausible ActiveRecord results that never mention magic_query.
    let(:generic_results) do
      [
        {
          title: "Active Record Query Interface",
          link: "https://guides.rubyonrails.org/active_record_querying.html",
          snippet: "This guide covers different ways to retrieve data from the database using Active Record."
        },
        {
          title: "ActiveRecord::QueryMethods",
          link: "https://api.rubyonrails.org/classes/ActiveRecord/QueryMethods.html",
          snippet: "where, select, order, limit and the rest of the relation API."
        }
      ]
    end

    # The retry fires first (the identifier is absent, so the results look
    # off-topic), then the escalation judges both rounds.
    def stub_both_rounds(results: generic_results)
      stub_serpapi_results_for(first_query, results)
      stub_serpapi_results_for(second_query, results)
      stub_claude_sequence(
        first_query,
        verdict_json(verdict: "unconfirmed", reason: "No result mentions magic_query.", source_url: nil),
        second_query,
        verdict_json(verdict: "unconfirmed", reason: "Still no mention of magic_query.", source_url: nil)
      )
    end

    it "returns contradicted rather than unconfirmed" do
      stub_both_rounds

      expect(described_class.call(claim)[:verdict]).to eq("contradicted")
    end

    it "explains the inference in the reason" do
      stub_both_rounds

      reason = described_class.call(claim)[:reason]

      expect(reason).to include("ActiveRecord::Base.magic_query")
      expect(reason).to match(/does not exist/i)
    end

    it "cites no source, because an absence has nothing to cite" do
      stub_both_rounds

      expect(described_class.call(claim)[:source_url]).to be_nil
    end

    it "keeps unconfirmed when a result does mention the method" do
      documented = generic_results + [
        {
          title: "magic_query added in Rails 9",
          link: "https://api.rubyonrails.org/classes/ActiveRecord/Base.html",
          snippet: "ActiveRecord::Base.magic_query builds an optimized relation."
        }
      ]
      stub_both_rounds(results: documented)

      # The name is present, so the weak verdict stands as the honest answer.
      expect(described_class.call(claim)[:verdict]).to eq("unconfirmed")
    end

    it "escalates on the union of both search rounds, not just the last one" do
      stub_serpapi_results_for(first_query, generic_results + [
        {
          title: "ActiveRecord::Base",
          link: "https://api.rubyonrails.org/classes/ActiveRecord/Base.html",
          snippet: "See also magic_query for generated relations."
        }
      ])
      stub_serpapi_results_for(second_query, generic_results)
      stub_claude_sequence(
        first_query,
        verdict_json(verdict: "unconfirmed", reason: "Mention is too vague.", source_url: nil),
        second_query,
        verdict_json(verdict: "unconfirmed", reason: "Nothing on point.", source_url: nil)
      )

      # The first round saw the name, so it is not absent from ANY result.
      expect(described_class.call(claim)[:verdict]).to eq("unconfirmed")
    end

    it "does not escalate when the search returned nothing at all" do
      stub_serpapi_no_results_for(first_query)
      stub_claude_sequence(first_query)

      result = described_class.call(claim)

      # Zero results means the query failed, not that the method is fake. Calling
      # a real method hallucinated is the one mistake this must not make.
      expect(result[:verdict]).to eq("unconfirmed")
      expect(result[:reason]).to match(/No search results were found/)
    end

    it "leaves a verified code_api claim alone" do
      stub_serpapi_results_for(first_query, generic_results)
      stub_claude_sequence(
        first_query,
        verdict_json(
          verdict: "verified",
          reason: "The guide documents the method.",
          source_url: "https://guides.rubyonrails.org/active_record_querying.html"
        )
      )

      expect(described_class.call(claim)[:verdict]).to eq("verified")
    end

    it "does not escalate an ordinary fact with no evidence" do
      fact = { claim: "The Eiffel Tower is located in London", type: "fact" }
      query = '"Eiffel Tower" location'
      stub_serpapi_results_for(query, [
        { title: "Eiffel Tower", link: "https://en.wikipedia.org/wiki/Eiffel_Tower", snippet: "Champ de Mars, Paris." }
      ])
      stub_claude_sequence(
        query,
        verdict_json(verdict: "unconfirmed", reason: "Snippet does not address London.", source_url: nil)
      )

      # For a plain fact, silence is silence - only code APIs get the stronger reading.
      expect(described_class.call(fact)[:verdict]).to eq("unconfirmed")
    end

    it "does not escalate a code_api claim with no identifier to look for" do
      vague = { claim: "Rails can run raw SQL queries", type: "code_api" }
      query = "Rails raw SQL queries"
      stub_serpapi_results_for(query, generic_results)
      stub_claude_sequence(
        query,
        verdict_json(verdict: "unconfirmed", reason: "Too general to confirm.", source_url: nil)
      )

      expect(described_class.call(vague)[:verdict]).to eq("unconfirmed")
    end
  end

  # Google's answer box and knowledge graph ride along on the same search. They
  # are ranked above organic results, labelled for the model, and - when they
  # carry no link - usable as evidence but never as a citation.
  # The live false positive this exists to prevent: `active_support` was judged
  # absent from six results that all discussed Active Support, because prose
  # does not spell identifiers the way code does.
  describe "matching an identifier against prose spellings" do
    let(:claim) do
      { claim: 'Active Support can be fully loaded with require "active_support/all"',
        type: "code_api" }
    end
    let(:query) { '"active_support/all" require Rails' }

    def results_saying(snippet)
      [ { title: "Active Support Core Extensions",
          link: "https://guides.rubyonrails.org/active_support_core_extensions.html",
          snippet: snippet } ]
    end

    # Both rounds answer unconfirmed, which is where the escalation would fire.
    def stub_rounds(results)
      stub_serpapi_results_for(query, results)
      stub_serpapi_results_for("reworded", results)
      stub_claude_sequence(
        query,
        verdict_json(verdict: "unconfirmed", reason: "Nothing specific about the require path.",
                     source_url: nil),
        "reworded",
        verdict_json(verdict: "unconfirmed", reason: "Still nothing specific.", source_url: nil)
      )
    end

    it "does not escalate when the results write it as two words" do
      stub_rounds(results_saying("Active Support extends Ruby's core classes."))

      expect(described_class.call(claim)[:verdict]).to eq("unconfirmed")
    end

    it "does not escalate when the results write it in CamelCase" do
      stub_rounds(results_saying("ActiveSupport extends Ruby's core classes."))

      expect(described_class.call(claim)[:verdict]).to eq("unconfirmed")
    end

    it "matches a path-like identifier on its segments, not the whole path" do
      # No page writes "active_support/all" in prose; plenty write the library.
      stub_rounds(results_saying("Require Active Support and you get every core extension."))

      expect(described_class.call(claim)[:verdict]).to eq("unconfirmed")
    end

    it "still escalates a name that really is absent in every spelling" do
      invented = { claim: "ActiveSupport adds Enumerable#frobnicate_all", type: "code_api" }
      stub_serpapi_results_for(query, results_saying("Active Support extends Ruby's core classes."))
      stub_serpapi_results_for("reworded", results_saying("Core extensions, none of them that."))
      stub_claude_sequence(
        query,
        verdict_json(verdict: "unconfirmed", reason: "No mention.", source_url: nil),
        "reworded",
        verdict_json(verdict: "unconfirmed", reason: "Still no mention.", source_url: nil)
      )

      result = described_class.call(invented)

      expect(result[:verdict]).to eq("contradicted")
      expect(result[:reason]).to include("frobnicate_all")
    end

    it "never escalates on zero results, whatever the identifier" do
      stub_serpapi_no_results
      stub_claude_sequence(query)

      expect(described_class.call(claim)[:verdict]).to eq("unconfirmed")
    end

    it "ignores probes too short to mean anything" do
      # `to_s` squashes to "tos", which would match "customs" or "photos".
      vague = { claim: "Every Ruby object responds to to_s", type: "code_api" }
      stub_serpapi_results_for(query, results_saying("Unrelated page about photos."))
      stub_serpapi_results_for("reworded", results_saying("Still unrelated."))
      stub_claude_sequence(
        query,
        verdict_json(verdict: "unconfirmed", reason: "Off topic.", source_url: nil),
        "reworded",
        verdict_json(verdict: "unconfirmed", reason: "Off topic.", source_url: nil)
      )

      expect(described_class.call(vague)[:verdict]).to eq("unconfirmed")
    end
  end

  describe "direct answers as evidence" do
    let(:claim) { { claim: "The Eiffel Tower is located in London", type: "fact" } }
    let(:query) { '"Eiffel Tower" location' }

    let(:organic) do
      [
        { title: "Travel blog", link: "https://someblog.example.com/eiffel", snippet: "A trip to the tower." },
        { title: "Eiffel Tower", link: "https://en.wikipedia.org/wiki/Eiffel_Tower", snippet: "Champ de Mars, Paris." }
      ]
    end

    def sent_results
      order = nil
      expect(
        a_claude_request_where { |body|
          content = body["messages"].first["content"]
          next false unless content.include?("<search_results>")

          order = content.scan(/<result index="\d+" origin="([^"]+)">\n(.*)\n/).map { |origin, url| [ origin, url ] }
          true
        }
      ).to have_been_made.at_least_once
      order
    end

    it "sends the answer box first, labelled, and lets it be cited" do
      stub_serpapi_payload(results: organic, answer_box: serpapi_answer_box(
        title: "Eiffel Tower location",
        link: "https://www.toureiffel.paris/en",
        snippet: "The Eiffel Tower stands on the Champ de Mars in Paris."
      ))
      stub_claude_sequence(
        query,
        verdict_json(verdict: "contradicted", reason: "Google's answer box places it in Paris.",
                     source_url: "https://www.toureiffel.paris/en")
      )

      result = described_class.call(claim)

      expect(sent_results.first).to eq([ "answer box", "url: https://www.toureiffel.paris/en" ])
      expect(result[:verdict]).to eq("contradicted")
      expect(result[:source_url]).to eq("https://www.toureiffel.paris/en")
    end

    it "sends a link-less knowledge graph panel but refuses to cite it" do
      stub_serpapi_payload(results: organic,
                           knowledge_graph: serpapi_knowledge_graph(source: nil, website: nil))
      stub_claude_sequence(
        query,
        # The model tries to cite the panel anyway; there is nothing to cite.
        verdict_json(verdict: "contradicted", reason: "The panel places it in Paris.", source_url: "")
      )

      result = described_class.call(claim)

      labels = sent_results
      expect(labels.first.first).to eq("knowledge graph")
      expect(labels.first.last).to eq("url: (none - this item cannot be cited)")
      expect(result[:verdict]).to eq("contradicted")
      expect(result[:source_url]).to be_nil
    end

    it "never lets a link-less panel be matched as the source" do
      stub_serpapi_payload(results: [], knowledge_graph: serpapi_knowledge_graph(source: nil, website: nil))
      stub_claude_sequence(
        query,
        # An empty-string url must not match the panel's nil link.
        verdict_json(verdict: "verified", reason: "Panel says so.", source_url: " ")
      )

      expect(described_class.call(claim)[:source_url]).to be_nil
    end

    it "keeps organic results below the direct answer rather than dropping them" do
      stub_serpapi_payload(results: organic, answer_box: serpapi_answer_box,
                           knowledge_graph: serpapi_knowledge_graph)
      stub_claude_sequence(query, verdict_json(verdict: "unconfirmed", reason: "Mixed.", source_url: nil))

      described_class.call(claim)

      expect(sent_results.map(&:first)).to eq([ "answer box", "knowledge graph", "organic", "organic" ])
    end

    it "is unchanged when neither panel is present" do
      stub_serpapi_payload(results: organic)
      stub_claude_sequence(
        query,
        verdict_json(verdict: "contradicted", reason: "Wikipedia places it in Paris.",
                     source_url: "https://en.wikipedia.org/wiki/Eiffel_Tower")
      )

      result = described_class.call(claim)

      expect(sent_results.map(&:first)).to eq([ "organic", "organic" ])
      expect(result[:source_url]).to eq("https://en.wikipedia.org/wiki/Eiffel_Tower")
    end
  end

  # A time-sensitive claim is searched against Google's past-year window first,
  # because for "the current stable release" a three-year-old page is worse
  # than no page. The window can be too thin to judge from, so there is exactly
  # one unfiltered fallback - and it must not stack with the reformulation.
  # A reader cannot tell a knowledge-graph citation from the tenth blue link by
  # looking at the URL, so the verdict says which it was.
  describe "reporting where the citation came from" do
    let(:claim) { { claim: "The Eiffel Tower is located in London", type: "fact" } }
    let(:query) { '"Eiffel Tower" location' }
    let(:organic) do
      [ { title: "Eiffel Tower", link: "https://en.wikipedia.org/wiki/Eiffel_Tower",
          snippet: "A tower on the Champ de Mars in Paris." } ]
    end

    def stub_citing(url, **payload)
      stub_serpapi_payload(results: organic, **payload)
      stub_claude_sequence(
        query,
        verdict_json(verdict: "contradicted", reason: "The sources place it in Paris.", source_url: url)
      )
    end

    it "reports answer_box when the answer box was cited" do
      stub_citing("https://www.toureiffel.paris/en", answer_box: serpapi_answer_box(
        title: "Eiffel Tower", link: "https://www.toureiffel.paris/en",
        snippet: "The Eiffel Tower stands on the Champ de Mars in Paris."
      ))

      expect(described_class.call(claim)[:source_type]).to eq("answer_box")
    end

    it "reports knowledge_graph when the panel was cited" do
      stub_citing("https://en.wikipedia.org/wiki/Eiffel_Tower_panel", knowledge_graph: serpapi_knowledge_graph(
        source: { name: "Wikipedia", link: "https://en.wikipedia.org/wiki/Eiffel_Tower_panel" }
      ))

      expect(described_class.call(claim)[:source_type]).to eq("knowledge_graph")
    end

    it "reports organic for an ordinary result" do
      stub_citing("https://en.wikipedia.org/wiki/Eiffel_Tower")

      result = described_class.call(claim)

      expect(result[:source_type]).to eq("organic")
      expect(result[:source_url]).to eq("https://en.wikipedia.org/wiki/Eiffel_Tower")
    end

    it "reports nothing when the verdict cited nothing" do
      stub_citing(nil)

      expect(described_class.call(claim)).to include(source_url: nil, source_type: nil)
    end

    it "reports nothing when the cited URL was not one of ours" do
      stub_citing("https://invented.example.com/made-up")

      # The URL is dropped as unattributable, so there is no source to describe.
      expect(described_class.call(claim)).to include(source_url: nil, source_type: nil)
    end

    it "reports nothing when Google returned no results at all" do
      stub_serpapi_no_results
      stub_claude_sequence(query)

      expect(described_class.call(claim)[:source_type]).to be_nil
    end

    it "uses the wire spelling, not the prose label sent to Claude" do
      stub_citing("https://www.toureiffel.paris/en", answer_box: serpapi_answer_box(
        title: "Eiffel Tower", link: "https://www.toureiffel.paris/en",
        snippet: "On the Champ de Mars in Paris."
      ))

      # The prompt says origin="answer box"; the API says "answer_box".
      expect(SerpGuard::SerpapiClient::SOURCE_TYPES)
        .to include(described_class.call(claim)[:source_type])
    end
  end

  describe "fresh results for time-sensitive claims" do
    let(:claim) { { claim: "Ruby's current stable release is 3.1.4", type: "fact", time_sensitive: true } }
    let(:stale_claim) { { claim: "Ruby 3.3 was released in December 2023", type: "fact", time_sensitive: false } }
    let(:query) { '"Ruby" current stable release' }

    def results(count)
      Array.new(count) do |i|
        { title: "Ruby release #{i}", link: "https://www.ruby-lang.org/#{i}",
          snippet: "Ruby current stable release note #{i}." }
      end
    end

    let(:verdict) do
      verdict_json(verdict: "contradicted", reason: "Current stable is 3.4.1.",
                   source_url: "https://www.ruby-lang.org/0")
    end

    it "sends the past-year filter for a time-sensitive claim" do
      stub_serpapi_payload(results: results(5), fresh: true)
      stub_claude_sequence(query, verdict)

      described_class.call(claim)

      expect(a_fresh_serpapi_request).to have_been_made.once
      expect(an_unfiltered_serpapi_request).not_to have_been_made
    end

    it "sends no filter for a claim that does not expire" do
      stub_serpapi_payload(results: results(5), fresh: false)
      stub_claude_sequence(query, verdict)

      described_class.call(stale_claim)

      expect(an_unfiltered_serpapi_request).to have_been_made.once
      expect(a_fresh_serpapi_request).not_to have_been_made
    end

    it "falls back to an unfiltered search when the past year is too thin" do
      stub_serpapi_payload(results: results(2), fresh: true)
      stub_serpapi_payload(results: results(5), fresh: false)
      stub_claude_sequence(query, verdict)

      described_class.call(claim)

      expect(a_fresh_serpapi_request).to have_been_made.once
      expect(an_unfiltered_serpapi_request).to have_been_made.once
    end

    it "does not fall back when the past year has enough to judge from" do
      stub_serpapi_payload(results: results(described_class::MIN_FRESH_RESULTS), fresh: true)
      stub_claude_sequence(query, verdict)

      described_class.call(claim)

      expect(an_unfiltered_serpapi_request).not_to have_been_made
    end

    it "keeps the filtered evidence if the fallback comes back empty" do
      stub_serpapi_payload(results: results(1), fresh: true)
      stub_serpapi_payload(results: [], fresh: false)
      stub_claude_sequence(query, verdict)

      expect(described_class.call(claim)[:verdict]).to eq("contradicted")
      # One result still reached the verdict step rather than "no results".
      expect(a_verdict_request).to have_been_made.once
    end

    # The worst case needs a claim with a multi-word entity in it: that is what
    # #results_cover_claim? tests relevance by, and without one an off-topic
    # result cannot be recognised as off-topic, so the rewrite never fires.
    let(:entity_claim) do
      { claim: "Ruby on Rails currently ships version 7.1.0", type: "fact", time_sensitive: true }
    end

    let(:off_topic) do
      [ { title: "Ruby Bridges", link: "https://example.com/ruby-bridges", snippet: "Civil rights icon." } ]
    end

    def stub_thin_then_off_topic_then_reworded
      stub_serpapi_payload(results: off_topic, fresh: true)
      stub_serpapi_payload(results: off_topic, query: query, fresh: false)
      stub_serpapi_payload(results: results(3), query: "reworded")
    end

    it "caps a time-sensitive claim at 3 searches and 4 Claude calls, worst case" do
      # Thin past-year window -> unfiltered fallback -> off-topic -> one rewrite.
      stub_thin_then_off_topic_then_reworded
      stub_claude_sequence(
        query,
        verdict_json(verdict: "unconfirmed", reason: "Off topic.", source_url: nil),
        "reworded",
        verdict_json(verdict: "contradicted", reason: "Current stable is 7.2.2.",
                     source_url: "https://www.ruby-lang.org/0")
      )

      expect(described_class.call(entity_claim)[:verdict]).to eq("contradicted")

      # The documented ceiling, asserted rather than asserted-in-a-comment.
      expect(a_serpapi_request).to have_been_made.times(3)
      expect(claude_requests_made).to have_been_made.times(4)
    end

    it "does not re-apply the filter on the reformulated search after a fallback" do
      stub_thin_then_off_topic_then_reworded
      stub_claude_sequence(
        query,
        verdict_json(verdict: "unconfirmed", reason: "Off topic.", source_url: nil),
        "reworded",
        verdict_json(verdict: "verified", reason: "Confirmed.", source_url: "https://www.ruby-lang.org/0")
      )

      described_class.call(entity_claim)

      # Exactly one filtered search in the whole run: the first one.
      expect(a_fresh_serpapi_request).to have_been_made.once
      expect(an_unfiltered_serpapi_request).to have_been_made.twice
    end
  end
end
