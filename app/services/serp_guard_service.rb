# frozen_string_literal: true

# The orchestrator: text in, a checked report out.
#
#   SerpGuardService.call("Ruby 3.3 shipped YJIT. Rails 8 has 400M downloads.")
#   # => { input_summary: {...}, claims: [{...}, {...}], checked_at: <Time> }
#
# Extract the claims once, then for each one prefer a stored verdict over three
# fresh upstream calls. Cache hits are marked `cached: true` so a caller can see
# which verdicts were re-used rather than re-checked.
#
# Cost is the reason this class exists in this shape: every uncached claim is two
# Claude calls plus one SerpApi search, and they are charged per call.
class SerpGuardService
  class << self
    def call(text, **options)
      new(text, **options).call
    end
  end

  # @param extractor [#call] injectable for specs; defaults to the real service
  # @param verifier  [#call] injectable for specs; defaults to the real service
  def initialize(text, max_claims: nil, extractor: ClaimExtractorService, verifier: ClaimVerifierService)
    @text = text.to_s
    @max_claims = max_claims || ClaimExtractorService::DEFAULT_MAX_CLAIMS
    @extractor = extractor
    @verifier = verifier
  end

  # @return [Hash] {input_summary:, claims:, checked_at:}
  def call
    checked_at = Time.current.utc

    # Claims are resolved in order so the report reads in the order the reader
    # met them in the original text.
    claims = extract.map { |extracted| resolve(extracted) }

    {
      input_summary: summarize(claims),
      claims: claims,
      checked_at: checked_at
    }
  end

  private

  attr_reader :text, :max_claims, :extractor, :verifier

  def extract
    extractor.call(text, max_claims: max_claims)
  end

  def resolve(extracted)
    cached = cached_verdict_for(extracted.claim)
    return cached.cached_entry_for(extracted) if cached

    verdict = verifier.call(extracted)
    stored = persist(extracted, verdict)

    entry(extracted, verdict, checked_at: stored&.checked_at || Time.current.utc)
  end

  def entry(extracted, verdict, checked_at:)
    {
      claim: verdict[:claim],
      type: extracted.type,
      verdict: verdict[:verdict],
      reason: verdict[:reason],
      source_url: verdict[:source_url],
      cached: false,
      checked_at: checked_at
    }
  end

  def cached_verdict_for(claim_text)
    Claim.cached_verdict_for(claim_text)
  rescue Mongo::Error => error
    # A cache we cannot read is a cache miss. Verifying again costs money but
    # still returns the right answer, which beats failing the whole request
    # because the datastore is unreachable.
    log_storage_failure("cache lookup", error)
    nil
  end

  def persist(extracted, verdict)
    Claim.create!(
      claim_text: verdict[:claim],
      claim_type: extracted.type,
      verdict: verdict[:verdict],
      reason: verdict[:reason],
      source_url: verdict[:source_url],
      checked_at: Time.current.utc
    )
  rescue Mongoid::Errors::Validations, Mongo::Error::OperationFailure
    # Either the uniqueness validation or the unique index fired, which means a
    # concurrent request verified the same claim first. Their row is as good as
    # ours, so use it. Anything else is a genuine failure and re-raises.
    existing = Claim.cached_verdict_for(verdict[:claim])
    raise unless existing

    existing
  rescue Mongo::Error => error
    # The verdict is sound and already paid for; losing the write should not
    # throw it away. Logged loudly so an outage is visible rather than silent.
    log_storage_failure("verdict write", error)
    nil
  end

  def log_storage_failure(operation, error)
    Rails.logger.error("[serpguard] #{operation} failed (#{error.class}: #{error.message})")
  end

  def summarize(claims)
    {
      characters: text.length,
      claims_extracted: claims.length,
      cached_claims: claims.count { |claim| claim[:cached] },
      verdicts: ClaimVerifierService::VERDICTS.index_with { |verdict|
        claims.count { |claim| claim[:verdict] == verdict }
      }
    }
  end
end
