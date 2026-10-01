# frozen_string_literal: true

require "rails_helper"

RSpec.describe Claim do
  def build_claim(**overrides)
    described_class.new(
      {
        claim_text: "Ruby 3.3 shipped YJIT",
        claim_type: "fact",
        verdict: "verified",
        reason: "The release notes say so.",
        source_url: "https://www.ruby-lang.org/",
        checked_at: Time.current.utc
      }.merge(overrides)
    )
  end

  describe "claim_hash" do
    it "is derived from the claim text on save" do
      claim = build_claim
      claim.save!

      expect(claim.claim_hash).to eq(described_class.hash_for("Ruby 3.3 shipped YJIT"))
      expect(claim.claim_hash.length).to eq(64)
    end

    it "is a SHA256 of the normalized text" do
      expect(described_class.hash_for("Ruby 3.3 shipped YJIT"))
        .to eq(Digest::SHA256.hexdigest("ruby 3.3 shipped yjit"))
    end

    it "ignores case, surrounding space, inner whitespace and a trailing full stop" do
      canonical = described_class.hash_for("Ruby 3.3 shipped YJIT")

      expect(described_class.hash_for("  ruby 3.3 shipped yjit  ")).to eq(canonical)
      expect(described_class.hash_for("Ruby  3.3\nshipped   YJIT")).to eq(canonical)
      expect(described_class.hash_for("Ruby 3.3 shipped YJIT.")).to eq(canonical)
      expect(described_class.hash_for("Ruby 3.3 shipped YJIT?")).to eq(canonical)
    end

    it "does not collapse claims that differ in substance" do
      expect(described_class.hash_for("Ruby 3.3 shipped YJIT"))
        .not_to eq(described_class.hash_for("Ruby 3.2 shipped YJIT"))

      expect(described_class.hash_for("Ruby 3.3 shipped YJIT"))
        .not_to eq(described_class.hash_for("Ruby 3.3 did not ship YJIT"))
    end
  end

  describe "validations" do
    it "requires claim text" do
      expect(build_claim(claim_text: nil)).not_to be_valid
    end

    it "requires a verdict from the allowed set" do
      expect(build_claim(verdict: "probably")).not_to be_valid
      expect(build_claim(verdict: nil)).not_to be_valid

      ClaimVerifierService::VERDICTS.each do |verdict|
        expect(build_claim(verdict: verdict)).to be_valid
      end
    end

    it "rejects a claim type outside the extractor's set" do
      expect(build_claim(claim_type: "opinion")).not_to be_valid
      expect(build_claim(claim_type: nil)).to be_valid
    end

    it "rejects a second claim with the same hash" do
      build_claim.save!

      duplicate = build_claim(claim_text: "  RUBY 3.3 SHIPPED YJIT.  ")

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:claim_hash]).to be_present
    end
  end

  describe "the unique index" do
    it "rejects a duplicate hash at the database level, not just in validation" do
      build_claim.save!

      # Inserted through the driver so Mongoid's validation is out of the
      # picture entirely. This is also what a genuine race looks like: two
      # processes computing the same hash and both trying to write it.
      expect {
        described_class.collection.insert_one(
          claim_hash: described_class.hash_for("ruby 3.3 shipped yjit"),
          claim_text: "ruby 3.3 shipped yjit",
          verdict: "verified"
        )
      }.to raise_error(Mongo::Error::OperationFailure, /duplicate key/i)
    end
  end

  describe "source_type" do
    it "accepts the three origins and nil" do
      SerpGuard::SerpapiClient::SOURCE_TYPES.each do |source_type|
        expect(build_claim(source_type: source_type)).to be_valid
      end
      expect(build_claim(source_type: nil)).to be_valid
    end

    it "rejects anything else, so a wrong label cannot be stored" do
      expect(build_claim(source_type: "answer box")).not_to be_valid
      expect(build_claim(source_type: "wikipedia")).not_to be_valid
    end

    it "comes back on a cache hit" do
      build_claim(source_type: "answer_box").save!

      stored = described_class.cached_verdict_for("Ruby 3.3 shipped YJIT")
      extracted = ClaimExtractorService::Claim.new(claim: "Ruby 3.3 shipped YJIT", type: "fact")

      expect(stored.cached_entry_for(extracted)).to include(source_type: "answer_box")
    end
  end

  describe ".cached_verdict_for" do
    it "returns nil when the claim has never been checked" do
      expect(described_class.cached_verdict_for("Something nobody has checked")).to be_nil
    end

    it "returns nil for blank input without querying" do
      expect(described_class.cached_verdict_for("")).to be_nil
      expect(described_class.cached_verdict_for(nil)).to be_nil
    end

    it "finds a stored claim by its exact text" do
      stored = build_claim
      stored.save!

      expect(described_class.cached_verdict_for("Ruby 3.3 shipped YJIT")).to eq(stored)
    end

    it "finds a stored claim through normalization" do
      stored = build_claim
      stored.save!

      expect(described_class.cached_verdict_for("  ruby 3.3 SHIPPED yjit.  ")).to eq(stored)
    end

    it "does not return a different claim" do
      build_claim.save!

      expect(described_class.cached_verdict_for("Ruby 3.2 shipped YJIT")).to be_nil
    end

    it "keeps a verdict with no expiry regardless of age" do
      build_claim(checked_at: 5.years.ago).save!

      found = described_class.cached_verdict_for("Ruby 3.3 shipped YJIT")

      # A claim that is not time-sensitive has a nil expires_at, and that is
      # what keeps ordinary facts cached indefinitely.
      expect(found).to be_present
      expect(found.verdict).to eq("verified")
    end

    it "serves a time-sensitive verdict that is still inside its window" do
      build_claim(time_sensitive: true, expires_at: 6.days.from_now).save!

      expect(described_class.cached_verdict_for("Ruby 3.3 shipped YJIT")).to be_present
    end

    it "treats a time-sensitive verdict past its expiry as a miss" do
      build_claim(time_sensitive: true, expires_at: 1.minute.ago).save!

      expect(described_class.cached_verdict_for("Ruby 3.3 shipped YJIT")).to be_nil
    end

    it "does not pretend the expired row is gone - only that it is unusable" do
      build_claim(time_sensitive: true, expires_at: 1.minute.ago).save!

      # Mongo's TTL reaper sweeps about once a minute, so between expiry and
      # deletion the row is still there and still holds the unique index. The
      # filter in this query, not the index, is what makes expiry correct.
      expect(described_class.count).to eq(1)
      expect(described_class.row_for("Ruby 3.3 shipped YJIT")).to be_present
    end
  end

  describe ".expiry_for" do
    it "expires a time-sensitive verdict after the TTL" do
      expect(described_class.expiry_for(true))
        .to be_within(5.seconds).of(described_class::TIME_SENSITIVE_TTL.from_now)
    end

    it "gives everything else no expiry at all" do
      expect(described_class.expiry_for(false)).to be_nil
    end
  end

  describe ".row_for" do
    it "finds the row through the same normalization as a cache read" do
      stored = build_claim
      stored.save!

      expect(described_class.row_for("  ruby 3.3 SHIPPED yjit.  ")).to eq(stored)
    end

    it "returns nil for blank input and for a claim never stored" do
      expect(described_class.row_for("")).to be_nil
      expect(described_class.row_for("Ruby 3.2 shipped YJIT")).to be_nil
    end
  end

  describe ".upsert_verdict!" do
    def upsert(**overrides)
      described_class.upsert_verdict!(
        {
          claim_text: "Ruby 3.3 shipped YJIT",
          claim_type: "fact",
          verdict: "verified",
          reason: "The release notes say so.",
          source_url: "https://www.ruby-lang.org/",
          checked_at: Time.current.utc
        }.merge(overrides)
      )
    end

    it "inserts when there is no row yet" do
      expect { upsert }.to change(described_class, :count).from(0).to(1)
    end

    it "overwrites the expired row instead of colliding with the unique index" do
      build_claim(time_sensitive: true, expires_at: 1.minute.ago, verdict: "verified").save!

      # The row is expired but still present, so an insert would hit the unique
      # index. This is the path a re-checked time-sensitive claim takes.
      expect { upsert(verdict: "contradicted", expires_at: described_class::TIME_SENSITIVE_TTL.from_now) }
        .not_to change(described_class, :count)

      stored = described_class.row_for("Ruby 3.3 shipped YJIT")
      expect(stored.verdict).to eq("contradicted")
      expect(stored.expires_at).to be > Time.current
    end
  end

  describe "#cached_entry_for" do
    it "reports the stored verdict against the claim as it was just written" do
      stored = build_claim
      stored.save!

      extracted = ClaimExtractorService::Claim.new(claim: "Ruby 3.3 SHIPPED YJIT.", type: "code_api")

      expect(stored.cached_entry_for(extracted)).to eq(
        claim: "Ruby 3.3 SHIPPED YJIT.",
        type: "code_api",
        verdict: "verified",
        reason: "The release notes say so.",
        source_url: "https://www.ruby-lang.org/",
        source_type: nil,
        time_sensitive: false,
        cached: true,
        checked_at: stored.checked_at
      )
    end
  end
end
