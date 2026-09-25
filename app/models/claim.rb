# frozen_string_literal: true

# A claim SerpGuard has already checked, stored so an identical claim never gets
# verified twice. One verification costs three upstream calls (two Claude, one
# SerpApi), so the cache is the difference between a demo that is affordable and
# one that is not.
#
# Lookup is by SHA256 of the *normalized* claim text rather than the text
# itself, so trivial differences in whitespace, case or a trailing full stop
# still hit the same row, and the unique index stays cheap and fixed-width.
class Claim
  include Mongoid::Document
  include Mongoid::Timestamps

  field :claim_text, type: String
  field :claim_hash, type: String
  field :claim_type, type: String
  field :verdict, type: String
  field :reason, type: String
  field :source_url, type: String
  field :checked_at, type: Time

  # Unique, because the whole point is one row per distinct claim. Create it with
  # `bin/rails db:mongoid:create_indexes` - declaring it here does not build it.
  index({ claim_hash: 1 }, { unique: true })

  validates :claim_text, presence: true
  validates :claim_hash, presence: true, uniqueness: true
  validates :verdict, presence: true, inclusion: { in: ClaimVerifierService::VERDICTS }
  validates :claim_type, inclusion: { in: ClaimExtractorService::CLAIM_TYPES }, allow_nil: true

  before_validation :assign_claim_hash

  class << self
    # Returns a previously stored verdict for this claim, or nil.
    #
    # NO TTL, BY DESIGN - and the assumption behind that is worth stating,
    # because it is the kind that quietly stops being true:
    #
    # Search *results* go stale within days; the facts they establish mostly do
    # not. "Ruby 3.3 shipped YJIT" will not become false, so re-verifying it next
    # month would spend three API calls to reach the same answer.
    #
    # Where the assumption breaks:
    #   - Claims that are only true *now* - "the latest version is X", "Y is the
    #     CEO of Z", any current-record or leaderboard claim.
    #   - An `unconfirmed` verdict, which often says more about what Google
    #     surfaced that minute than about the claim. Caching it means a claim
    #     that was merely hard to source stays unconfirmed forever.
    #
    # If either starts to matter, the fix is small and belongs here rather than
    # in the caller: filter this query on `checked_at` (e.g. verdicts older than
    # 30 days, or any `unconfirmed`, count as a miss), or add
    # `expire_after_seconds` to a `checked_at` index. Do not scatter freshness
    # rules through the orchestrator.
    def cached_verdict_for(claim_text)
      return nil if claim_text.blank?

      where(claim_hash: hash_for(claim_text)).first
    end

    def hash_for(claim_text)
      Digest::SHA256.hexdigest(normalize(claim_text))
    end

    # Deliberately conservative: it collapses formatting noise, not meaning.
    # Anything more aggressive (stemming, stop-word removal) risks treating two
    # genuinely different claims as one, and a false cache hit is a wrong answer.
    def normalize(claim_text)
      claim_text.to_s
                .unicode_normalize(:nfkc)
                .squish
                .downcase
                .sub(/[.!?]+\z/, "")
    end
  end

  def cached_entry_for(extracted_claim)
    {
      claim: extracted_claim.claim,
      type: extracted_claim.type,
      verdict: verdict,
      reason: reason,
      source_url: source_url,
      cached: true,
      checked_at: checked_at
    }
  end

  private

  def assign_claim_hash
    self.claim_hash = self.class.hash_for(claim_text) if claim_text.present?
  end
end
