# frozen_string_literal: true

# A claim SerpGuard has already checked, stored so an identical claim never gets
# verified twice. One verification costs three upstream calls (two Claude, one
# SerpApi) on the common path and at most seven - see ClaimVerifierService - so
# the cache is the difference between a demo that is affordable and one that is
# not.
#
# Lookup is by SHA256 of the *normalized* claim text rather than the text
# itself, so trivial differences in whitespace, case or a trailing full stop
# still hit the same row, and the unique index stays cheap and fixed-width.
class Claim
  include Mongoid::Document
  include Mongoid::Timestamps

  # How long a time-sensitive verdict stays usable. Everything else has no
  # expiry at all - see the note on cached_verdict_for.
  TIME_SENSITIVE_TTL = 7.days

  field :claim_text, type: String
  field :claim_hash, type: String
  field :claim_type, type: String
  field :verdict, type: String
  field :reason, type: String
  field :source_url, type: String
  field :checked_at, type: Time

  # A time-sensitive verdict is only true for a while. `expires_at` is nil for
  # everything else, which is what keeps ordinary facts cached forever.
  field :time_sensitive, type: Boolean, default: false
  field :expires_at, type: Time

  # Unique, because the whole point is one row per distinct claim. Create it with
  # `bin/rails db:mongoid:create_indexes` - declaring it here does not build it.
  index({ claim_hash: 1 }, { unique: true })

  # TTL index: Mongo deletes a row once it passes `expires_at`. Rows with a nil
  # expires_at are ignored by the reaper and live forever, which is exactly the
  # behaviour non-time-sensitive claims had before.
  #
  # The reaper only runs about once a minute, so #cached_verdict_for filters on
  # expiry as well - the index is housekeeping, not the correctness guarantee.
  #
  # Adding this means production needs `bin/rails db:mongoid:create_indexes`
  # run again; declaring an index here does not build it.
  index({ expires_at: 1 }, { expire_after_seconds: 0 })

  validates :claim_text, presence: true
  validates :claim_hash, presence: true, uniqueness: true
  validates :verdict, presence: true, inclusion: { in: ClaimVerifierService::VERDICTS }
  validates :claim_type, inclusion: { in: ClaimExtractorService::CLAIM_TYPES }, allow_nil: true

  before_validation :assign_claim_hash

  class << self
    # Returns a usable stored verdict for this claim, or nil.
    #
    # Two lifetimes, because claims have two:
    #
    # Search *results* go stale within days; the facts they establish mostly do
    # not. "Ruby 3.3 shipped YJIT" will not become false, so re-verifying it next
    # month would spend three API calls to reach the same answer. Those rows have
    # a nil `expires_at` and stay cached indefinitely.
    #
    # A claim that is only true *now* - "the latest stable release is X", "Y is
    # the CEO of Z", any current-record or leaderboard claim - is flagged
    # time-sensitive by ClaimExtractorService and stored with an `expires_at` of
    # TIME_SENSITIVE_TTL from the check. Past that, this query treats the row as
    # a miss and the claim is verified again rather than answered from it.
    #
    # One assumption is still live and worth stating, because it is the kind that
    # quietly stops being true: an `unconfirmed` verdict on a claim that is not
    # time-sensitive is cached forever. "Unconfirmed" often says more about what
    # Google surfaced that minute than about the claim, so a claim that was
    # merely hard to source stays unconfirmed. If that starts to matter the fix
    # belongs here rather than in the caller - give those rows an `expires_at`
    # too, in .expiry_for. Do not scatter freshness rules through the
    # orchestrator.
    def cached_verdict_for(claim_text)
      return nil if claim_text.blank?

      where(claim_hash: hash_for(claim_text))
        .any_of({ expires_at: nil }, { :expires_at.gt => Time.current.utc })
        .first
    end

    # Any stored row for this claim, expired or not.
    #
    # The read path above ignores an expired row; the write path cannot afford
    # to. Mongo's TTL reaper only sweeps about once a minute, so an expired row
    # still occupies the unique index, and a re-check that inserted a second row
    # for the same hash would fail. SerpGuardService uses this to update the row
    # it already has instead.
    def row_for(claim_text)
      return nil if claim_text.blank?

      where(claim_hash: hash_for(claim_text)).first
    end

    # Writes a verdict for a claim, over the row that already holds it if there
    # is one. See .row_for for why overwriting rather than inserting matters.
    #
    # @return [Claim] the saved row
    def upsert_verdict!(attributes)
      row = row_for(attributes[:claim_text]) || new
      row.assign_attributes(attributes)
      row.save!
      row
    end

    # 7 days. Long enough that a demo re-run is free, short enough that "the
    # current stable release" is re-checked well within a release cycle.
    def expiry_for(time_sensitive)
      time_sensitive ? TIME_SENSITIVE_TTL.from_now.utc : nil
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
      time_sensitive: time_sensitive?,
      cached: true,
      checked_at: checked_at
    }
  end

  private

  def assign_claim_hash
    self.claim_hash = self.class.hash_for(claim_text) if claim_text.present?
  end
end
