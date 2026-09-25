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

    it "keeps the stored verdict regardless of age, since there is no TTL" do
      build_claim(checked_at: 5.years.ago).save!

      found = described_class.cached_verdict_for("Ruby 3.3 shipped YJIT")

      # Documents the current decision: add a checked_at filter here if
      # time-sensitive claims start mattering.
      expect(found).to be_present
      expect(found.verdict).to eq("verified")
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
        cached: true,
        checked_at: stored.checked_at
      )
    end
  end
end
