# frozen_string_literal: true

# Renders a SerpGuardService result as the POST /api/v1/checks response body.
#
# The wire format lives here and only here: the service returns Ruby values
# (Time objects, symbol keys) and this class decides what a client sees, so the
# two can change independently. Timestamps go out as ISO 8601 UTC.
class SerpGuardResponseSerializer
  def initialize(result)
    @result = result
  end

  def as_json(*)
    {
      checked_at: iso8601(result[:checked_at]),
      input_summary: input_summary,
      claims: Array(result[:claims]).map { |claim| claim_json(claim) }
    }
  end

  private

  attr_reader :result

  def input_summary
    summary = result[:input_summary] || {}

    {
      characters: summary[:characters],
      claims_extracted: summary[:claims_extracted],
      cached_claims: summary[:cached_claims],
      verdicts: summary[:verdicts]
    }
  end

  def claim_json(claim)
    {
      claim: claim[:claim],
      type: claim[:type],
      verdict: claim[:verdict],
      reason: claim[:reason],
      source_url: claim[:source_url],
      # Tells the caller this verdict was re-used from a previous check rather
      # than searched for again just now.
      cached: claim[:cached],
      checked_at: iso8601(claim[:checked_at])
    }
  end

  def iso8601(time)
    time&.utc&.iso8601
  end
end
