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

    # Google's "past year" filter. Used for claims the extractor marked
    # time-sensitive, where a three-year-old page is worse than no page.
    FRESH_WINDOW = "qdr:y"

    # SerpApi answers HTTP 200 with an `error` string when Google simply had
    # nothing to return. That is an empty result set, not a failure - the
    # verifier turns it into an "unconfirmed" verdict.
    NO_RESULTS_PATTERN = /hasn't returned any results|no results (?:found|returned)/i

    # Where a piece of evidence came from in the SerpApi payload. Carried
    # through so the verdict prompt can weigh Google's own direct answer
    # differently from the tenth blue link.
    ORIGIN_ANSWER_BOX = "answer box"
    ORIGIN_KNOWLEDGE_GRAPH = "knowledge graph"
    ORIGIN_ORGANIC = "organic"

    # The same three, as the API reports them in `source_type`. The origin
    # strings above read as prose because they go into the verdict prompt; these
    # are identifiers a client can switch on.
    SOURCE_TYPES = %w[answer_box knowledge_graph organic].freeze

    # One piece of evidence. `link` may be nil: an answer box or knowledge graph
    # panel is often rendered from Google's own index with nothing to link to.
    # Such an item is still worth showing the model, but it can never become a
    # source_url - see ClaimVerifierService#attributable_url.
    Result = Data.define(:title, :link, :snippet, :origin) do
      def initialize(title:, link:, snippet:, origin: ORIGIN_ORGANIC)
        super
      end

      def citable?
        link.present?
      end

      def direct_answer?
        origin != ORIGIN_ORGANIC
      end

      # @return [String] one of SOURCE_TYPES
      def source_type
        origin.tr(" ", "_")
      end
    end

    def initialize(api_key: ENV[CREDENTIAL_ENV_VAR], **options)
      super(api_key: api_key, credential_env_var: CREDENTIAL_ENV_VAR, **options)
    end

    # @param fresh [Boolean] restrict to the past year (Google's qdr:y)
    # @return [Array<Result>] answer box and knowledge graph first, then organic
    #   results carrying a snippet, at most `limit` in total
    def search(query, limit: DEFAULT_LIMIT, fresh: false)
      raise ArgumentError, "query must not be blank" if query.blank?

      with_retries { interpret(execute(query, fresh: fresh), limit: limit) }
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

    def execute(query, fresh: false)
      params = {
        engine: ENGINE,
        q: query,
        num: RESULTS_PER_PAGE,
        api_key: api_key
      }
      params[:tbs] = FRESH_WINDOW if fresh

      self.class.get(ENDPOINT, query: params, **request_timeouts)
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

    # Google's direct answers come first - they are the same search, already
    # paid for, and usually the most on-point text on the page. Organic results
    # follow and are never dropped to make room: the limit trims the tail.
    def build_results(body, limit:)
      direct = [ build_answer_box(body["answer_box"]), build_knowledge_graph(body["knowledge_graph"]) ].compact
      organic = Array(body["organic_results"]).filter_map { |result| build_organic(result) }

      (direct + organic).first(limit)
    end

    # The answer box shape varies by question type: a definition has `snippet`,
    # a calculation has `answer`, a how-to has `list`. Take the first field that
    # actually carries prose and skip the box entirely when none do.
    ANSWER_BOX_TEXT_KEYS = %w[answer snippet result description title].freeze

    def build_answer_box(box)
      return nil unless box.is_a?(Hash)

      text = ANSWER_BOX_TEXT_KEYS.filter_map { |key| box[key].presence if box[key].is_a?(String) }.first
      text ||= Array(box["snippet_highlighted_words"]).join(", ").presence
      return nil if text.blank?

      Result.new(
        title: box["title"].presence || "Google answer box",
        link: box["link"].presence,
        snippet: text,
        origin: ORIGIN_ANSWER_BOX
      )
    end

    # The knowledge graph panel describes an entity. Its link, when there is
    # one, hangs off `source`, not the top level.
    def build_knowledge_graph(graph)
      return nil unless graph.is_a?(Hash)

      text = [ graph["description"], graph["snippet"] ].find { |value| value.is_a?(String) && value.present? }
      return nil if text.blank?

      source = graph["source"]
      link = (source.is_a?(Hash) ? source["link"] : nil).presence || graph["website"].presence

      Result.new(
        title: [ graph["title"], graph["type"] ].compact_blank.join(" — ").presence || "Google knowledge graph",
        link: link,
        snippet: text,
        origin: ORIGIN_KNOWLEDGE_GRAPH
      )
    end

    # Organic results without a snippet are useless as evidence - there is
    # nothing for Claude to weigh - and without a link they cannot be cited
    # either, so they are dropped rather than passed on empty.
    def build_organic(result)
      return nil unless result.is_a?(Hash)

      snippet = result["snippet"]
      link = result["link"]
      return nil if snippet.blank? || link.blank?

      Result.new(
        title: result["title"].to_s,
        link: link,
        snippet: snippet,
        origin: ORIGIN_ORGANIC
      )
    end
  end
end
