# frozen_string_literal: true

require "json"
require "net/http"
require "time"
require "uri"
require "yaml"

module SerpGuard
  # Scores SerpGuard against the labelled claims in eval/claims.yml.
  #
  # Deliberately outside spec/: every claim here spends real Claude and SerpApi
  # calls, and the test suite never touches the network. Run it with
  # `rake eval:run`, which checks the database first.
  #
  # Three outcomes per claim, counted separately because they mean different
  # things:
  #
  #   correct    the verdict matched the label
  #   abstained  "unconfirmed" - the search found nothing decisive. Not a wrong
  #              answer: the product is allowed to say it could not tell.
  #   wrong      a confident verdict that disagrees with the label. Split into
  #              false "verified" (called a false thing true - the dangerous
  #              one) and false "contradicted" (called a true thing false).
  class EvalRunner
    DATASET = File.expand_path("claims.yml", __dir__)
    RESULTS_DIR = File.expand_path("results", __dir__)

    SERPAPI_ACCOUNT_URL = "https://serpapi.com/account.json"

    # The run stops rather than taking the SerpApi balance below this.
    SEARCH_FLOOR = 100

    # ClaimVerifierService's documented worst case for one uncached claim.
    SEARCHES_PER_CLAIM = 3

    # Long enough for a cold claim: two Claude calls and a live search.
    REQUEST_TIMEOUT = 180

    PAUSE_SECONDS = 2

    ABSTAINED = "unconfirmed"

    Result = Struct.new(
      :id, :category, :claim, :expected, :got, :reason, :source_url,
      :source_type, :cached, :seconds, :outcome, :error,
      keyword_init: true
    )

    # @param categories [Array<String>, nil] run only these categories
    # @param label [String, nil] suffix for the results filename, so a partial
    #   re-run cannot overwrite the results of a full one
    def initialize(base_url:, api_key:, serpapi_key: nil, limit: nil,
                   categories: nil, label: nil, io: $stdout)
      @base_url = base_url
      @api_key = api_key
      @serpapi_key = serpapi_key
      @limit = limit
      @categories = Array(categories).compact_blank.presence
      @label = label.presence
      @io = io
      @results = []
      @stopped_early = nil
    end

    def call
      claims = load_claims
      @searches_before = searches_left

      say "SerpGuard accuracy benchmark"
      say "  server:   #{base_url}"
      say "  dataset:  #{claims.length} claims from #{relative(DATASET)}"
      say "  filter:   #{categories.join(', ')}" if categories
      say "  searches: #{@searches_before || 'unknown'} left before the run"
      say ""

      claims.each_with_index do |claim, index|
        break unless budget_allows?(claim)

        sleep PAUSE_SECONDS if index.positive?
        results << check(claim)
        say_result(results.last)

        break if results.last.error
      end

      @searches_after = searches_left
      path = write_results
      report
      say ""
      say "Raw results: #{relative(path)}"

      results
    end

    private

    attr_reader :base_url, :api_key, :serpapi_key, :limit, :categories, :label, :io, :results

    def load_claims
      claims = YAML.safe_load_file(DATASET)
      claims = claims.select { |claim| categories.include?(claim["category"]) } if categories
      limit ? claims.first(limit) : claims
    end

    # --- one claim ----------------------------------------------------------

    def check(claim)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = post(claim["text"])
      seconds = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1)

      build_result(claim, response, seconds)
    rescue StandardError => error
      # Reported, never scored. A timeout says nothing about accuracy, and
      # guessing in its place would quietly corrupt the numbers.
      Result.new(
        id: claim["id"], category: claim["category"], claim: claim["text"],
        expected: claim["expected"], seconds: nil, outcome: "error",
        error: "#{error.class}: #{error.message}"
      )
    end

    def post(text)
      uri = URI.join(base_url, "/api/v1/checks")
      request = Net::HTTP::Post.new(uri)
      request["content-type"] = "application/json"
      request["X-API-Key"] = api_key
      request.body = JSON.generate(text: text)

      Net::HTTP.start(
        uri.hostname, uri.port,
        use_ssl: uri.scheme == "https",
        open_timeout: 10, read_timeout: REQUEST_TIMEOUT
      ) { |http| http.request(request) }
    end

    def build_result(claim, response, seconds)
      body = parse(response.body)

      unless response.code == "200"
        error = body.dig("error", "code") || "http_#{response.code}"
        return Result.new(
          id: claim["id"], category: claim["category"], claim: claim["text"],
          expected: claim["expected"], seconds: seconds, outcome: "error",
          error: "#{error}: #{body.dig('error', 'message')}"
        )
      end

      # One sentence in, so one claim out. If extraction found nothing to check,
      # that is its own outcome rather than a wrong answer.
      first = Array(body["claims"]).first

      Result.new(
        id: claim["id"], category: claim["category"], claim: claim["text"],
        expected: claim["expected"], got: first&.dig("verdict"),
        reason: first&.dig("reason"), source_url: first&.dig("source_url"),
        source_type: first&.dig("source_type"), cached: first&.dig("cached"),
        seconds: seconds, outcome: outcome_for(claim["expected"], first)
      )
    end

    def outcome_for(expected, claim_json)
      return "no_claim" if claim_json.nil?

      verdict = claim_json["verdict"]
      return "correct" if verdict == expected
      return "abstained" if verdict == ABSTAINED
      return "false_verified" if verdict == "verified"

      "false_contradicted"
    end

    def parse(body)
      JSON.parse(body.to_s)
    rescue JSON::ParserError
      {}
    end

    # --- budget -------------------------------------------------------------

    # account.json is not a search, so this can be asked before every claim.
    # Returns nil when the balance cannot be read, which never blocks the run -
    # it only means the floor cannot be enforced, and that is said out loud.
    def searches_left
      return nil if serpapi_key.to_s.empty?

      uri = URI(SERPAPI_ACCOUNT_URL)
      uri.query = URI.encode_www_form(api_key: serpapi_key)
      JSON.parse(Net::HTTP.get(uri))["total_searches_left"]
    rescue StandardError
      nil
    end

    def budget_allows?(claim)
      left = searches_left
      return true if left.nil?
      return true if left - SEARCHES_PER_CLAIM >= SEARCH_FLOOR

      @stopped_early = "stopped at #{claim['id']}: #{left} searches left, and one " \
                       "more claim could take it under the floor of #{SEARCH_FLOOR}"
      say ""
      say "! #{@stopped_early}"
      false
    end

    # --- output -------------------------------------------------------------

    def say(line)
      io.puts(line)
    end

    def say_result(result)
      mark = { "correct" => "ok  ", "abstained" => "--  ", "no_claim" => "??  ",
               "error" => "ERR " }.fetch(result.outcome, "WRONG")

      say format(
        "%<mark>-6s %<id>-6s %<got>-13s %<seconds>6s  %<claim>s",
        mark: mark, id: result.id, got: result.got || result.outcome,
        seconds: result.seconds ? "#{result.seconds}s" : "-", claim: result.claim
      )
      say "       #{result.error}" if result.error
    end

    def report
      scored = results.reject { |result| result.outcome == "error" }
      counts = scored.group_by(&:outcome).transform_values(&:length)
      wrong = counts.fetch("false_verified", 0) + counts.fetch("false_contradicted", 0)

      say ""
      say "Scored #{scored.length} of #{results.length} claims attempted"
      say "  correct              #{counts.fetch('correct', 0)}"
      say "  abstained            #{counts.fetch('abstained', 0)}  (unconfirmed)"
      say "  no claim extracted   #{counts.fetch('no_claim', 0)}"
      say "  wrong                #{wrong}"
      say "    false verified     #{counts.fetch('false_verified', 0)}  (called a false claim true)"
      say "    false contradicted #{counts.fetch('false_contradicted', 0)}  (called a true claim false)"
      report_categories(scored)
      report_timing(scored)
      report_errors
      say "  stopped early: #{@stopped_early}" if @stopped_early
    end

    def report_categories(scored)
      say ""
      say format("  %<category>-18s %<n>3s %<correct>8s %<abstained>10s %<wrong>6s", category: "category",
                 n: "n", correct: "correct", abstained: "abstained", wrong: "wrong")

      scored.group_by(&:category).each do |category, rows|
        counts = rows.group_by(&:outcome).transform_values(&:length)
        say format(
          "  %<category>-18s %<n>3d %<correct>8d %<abstained>10d %<wrong>6d",
          category: category, n: rows.length, correct: counts.fetch("correct", 0),
          abstained: counts.fetch("abstained", 0),
          wrong: counts.fetch("false_verified", 0) + counts.fetch("false_contradicted", 0)
        )
      end
    end

    def report_timing(scored)
      times = scored.filter_map(&:seconds)
      return if times.empty?

      say ""
      say "  average time  #{(times.sum / times.length).round(1)}s"
      say "  slowest       #{times.max}s"
      say "  searches used #{searches_used || 'unknown'}"
    end

    def report_errors
      failures = results.select { |result| result.outcome == "error" }
      return if failures.empty?

      say ""
      say "  errors (not scored):"
      failures.each { |result| say "    #{result.id}: #{result.error}" }
    end

    def searches_used
      return nil if @searches_before.nil? || @searches_after.nil?

      @searches_before - @searches_after
    end

    def write_results
      Dir.mkdir(RESULTS_DIR) unless Dir.exist?(RESULTS_DIR)
      name = [ Time.now.utc.strftime("%Y-%m-%d"), label ].compact.join("-")
      path = File.join(RESULTS_DIR, "#{name}.json")

      File.write(path, JSON.pretty_generate(payload))
      path
    end

    def payload
      {
        generated_at: Time.now.utc.iso8601,
        base_url: base_url,
        dataset: relative(DATASET),
        categories: categories,
        attempted: results.length,
        searches_used: searches_used,
        stopped_early: @stopped_early,
        results: results.map(&:to_h)
      }
    end

    def relative(path)
      path.sub("#{File.expand_path('..', __dir__)}/", "").tr("\\", "/")
    end
  end
end
