# frozen_string_literal: true

require "rails_helper"

RSpec.describe SerpGuardService do
  let(:text) { "Ruby 3.3 shipped YJIT. Rails 8 was downloaded 400 million times." }

  let(:first_claim) { ClaimExtractorService::Claim.new(claim: "Ruby 3.3 shipped YJIT", type: "fact") }
  let(:second_claim) do
    ClaimExtractorService::Claim.new(claim: "Rails 8 was downloaded 400 million times", type: "statistic")
  end

  # Injected rather than stubbed over HTTP: these specs are about the
  # orchestration and the cache, and the two services have their own specs.
  let(:extractor) { class_double(ClaimExtractorService, call: [ first_claim ]) }
  let(:verifier) { class_double(ClaimVerifierService, call: verdict_for(first_claim)) }

  def verdict_for(claim, verdict: "verified", reason: "Confirmed by the sources.", source_url: "https://example.com/1")
    { claim: claim.claim, verdict: verdict, reason: reason, source_url: source_url }
  end

  def run(**overrides)
    described_class.call(text, **{ extractor: extractor, verifier: verifier }.merge(overrides))
  end

  describe "a fresh claim" do
    it "extracts, verifies and returns the claim entry" do
      result = run

      expect(result[:claims]).to eq(
        [
          {
            claim: "Ruby 3.3 shipped YJIT",
            type: "fact",
            verdict: "verified",
            reason: "Confirmed by the sources.",
            source_url: "https://example.com/1",
            cached: false,
            checked_at: result[:claims].first[:checked_at]
          }
        ]
      )
      expect(verifier).to have_received(:call).with(first_claim).once
    end

    it "persists the verdict for next time" do
      run

      stored = Claim.first
      expect(stored.claim_text).to eq("Ruby 3.3 shipped YJIT")
      expect(stored.claim_type).to eq("fact")
      expect(stored.verdict).to eq("verified")
      expect(stored.claim_hash).to eq(Claim.hash_for("Ruby 3.3 shipped YJIT"))
    end

    it "passes max_claims through to the extractor" do
      run(max_claims: 4)

      expect(extractor).to have_received(:call).with(text, max_claims: 4)
    end

    it "defaults max_claims rather than passing nil" do
      run

      expect(extractor).to have_received(:call)
        .with(text, max_claims: ClaimExtractorService::DEFAULT_MAX_CLAIMS)
    end

    it "reports the summary" do
      result = run

      expect(result[:input_summary]).to eq(
        characters: text.length,
        claims_extracted: 1,
        cached_claims: 0,
        verdicts: { "verified" => 1, "unconfirmed" => 0, "contradicted" => 0 }
      )
      expect(result[:checked_at]).to be_a(Time)
    end
  end

  describe "a cached claim" do
    before do
      Claim.create!(
        claim_text: "Ruby 3.3 shipped YJIT",
        claim_type: "fact",
        verdict: "contradicted",
        reason: "Stored verdict from an earlier check.",
        source_url: "https://example.com/stored",
        checked_at: 2.days.ago
      )
    end

    it "returns the stored verdict without calling the verifier at all" do
      result = run

      expect(result[:claims].first).to include(
        claim: "Ruby 3.3 shipped YJIT",
        verdict: "contradicted",
        reason: "Stored verdict from an earlier check.",
        source_url: "https://example.com/stored",
        cached: true
      )
      expect(verifier).not_to have_received(:call)
    end

    it "reports the stored checked_at, not now" do
      result = run

      expect(result[:claims].first[:checked_at]).to be_within(1.second).of(Claim.first.checked_at)
      expect(result[:claims].first[:checked_at]).to be < 1.day.ago
    end

    it "does not write another row" do
      expect { run }.not_to change(Claim, :count)
    end

    it "counts the cache hit in the summary" do
      expect(run[:input_summary]).to include(cached_claims: 1)
    end

    it "reports the claim as it was written this time, with the stored verdict" do
      allow(extractor).to receive(:call).and_return(
        [ ClaimExtractorService::Claim.new(claim: "  RUBY 3.3 shipped YJIT.  ", type: "code_api") ]
      )

      entry = run[:claims].first

      # The text the caller sent, the verdict we already had.
      expect(entry[:claim]).to eq("  RUBY 3.3 shipped YJIT.  ")
      expect(entry[:type]).to eq("code_api")
      expect(entry[:verdict]).to eq("contradicted")
      expect(entry[:cached]).to be(true)
    end
  end

  describe "a mix of cached and fresh claims" do
    before do
      Claim.create!(
        claim_text: "Ruby 3.3 shipped YJIT",
        claim_type: "fact",
        verdict: "verified",
        reason: "Stored.",
        source_url: "https://example.com/stored",
        checked_at: 1.day.ago
      )
      allow(extractor).to receive(:call).and_return([ first_claim, second_claim ])
      allow(verifier).to receive(:call).with(second_claim)
                                      .and_return(verdict_for(second_claim, verdict: "unconfirmed", source_url: nil))
    end

    it "verifies only the unseen claim, preserving input order" do
      result = run

      expect(result[:claims].map { |claim| claim[:cached] }).to eq([ true, false ])
      expect(result[:claims].map { |claim| claim[:verdict] }).to eq(%w[verified unconfirmed])
      expect(verifier).to have_received(:call).with(second_claim).once
      expect(verifier).not_to have_received(:call).with(first_claim)
    end

    it "stores only the new claim" do
      expect { run }.to change(Claim, :count).from(1).to(2)
    end

    it "tallies both verdicts" do
      expect(run[:input_summary]).to include(
        claims_extracted: 2,
        cached_claims: 1,
        verdicts: { "verified" => 1, "unconfirmed" => 1, "contradicted" => 0 }
      )
    end
  end

  describe "when the datastore misbehaves" do
    it "treats an unreadable cache as a miss and still verifies" do
      allow(Claim).to receive(:cached_verdict_for).and_raise(Mongo::Error.new("connection lost"))

      result = run

      expect(result[:claims].first[:verdict]).to eq("verified")
      expect(result[:claims].first[:cached]).to be(false)
      expect(verifier).to have_received(:call).once
    end

    it "returns the verdict even when the write fails, rather than discarding paid work" do
      allow(Claim).to receive(:create!).and_raise(Mongo::Error.new("no primary available"))
      allow(Rails.logger).to receive(:error)

      result = run

      expect(result[:claims].first).to include(verdict: "verified", cached: false)
      expect(result[:claims].first[:checked_at]).to be_a(Time)
      expect(Rails.logger).to have_received(:error).with(/verdict write failed/)
    end

    it "uses the winner's row when a concurrent request stored the same claim first" do
      # Simulates losing the race: the row appears between our lookup and our
      # write, so create! hits the unique index.
      allow(Claim).to receive(:create!) do |attributes|
        Claim.new(attributes.merge(reason: "Stored by the request that won the race.")).save!
        raise Mongo::Error::OperationFailure, "E11000 duplicate key error"
      end

      result = run

      expect(result[:claims].first[:verdict]).to eq("verified")
      expect(Claim.count).to eq(1)
      expect(Claim.first.reason).to eq("Stored by the request that won the race.")
    end

    it "re-raises a genuine validation failure that is not a duplicate" do
      allow(Claim).to receive(:create!).and_raise(
        Mongoid::Errors::Validations.new(Claim.new(claim_text: "x", verdict: "nonsense"))
      )

      expect { run }.to raise_error(Mongoid::Errors::Validations)
    end
  end

  describe "when extraction fails" do
    it "lets the extraction error through untouched" do
      allow(extractor).to receive(:call)
        .and_raise(SerpGuard::Errors::ExtractionFailed, "Claude did not return valid JSON")

      expect { run }.to raise_error(SerpGuard::Errors::ExtractionFailed)
      expect(verifier).not_to have_received(:call)
      expect(Claim.count).to eq(0)
    end
  end

  describe "when verification fails" do
    it "lets the verification error through and stores nothing" do
      allow(verifier).to receive(:call)
        .and_raise(SerpGuard::Errors::VerificationFailed, "unrecognised verdict")

      expect { run }.to raise_error(SerpGuard::Errors::VerificationFailed)
      expect(Claim.count).to eq(0)
    end
  end
end
