# frozen_string_literal: true

module Api
  module V1
    # POST /api/v1/checks - submit text or code, get a per-claim verdict.
    #
    # Thin on purpose: parse and bound the input, hand it to SerpGuardService,
    # render. Every failure path below raises a SerpGuard::Errors class that
    # ErrorHandling already knows how to render, so there is no rescue here.
    class ChecksController < ApplicationController
      def create
        result = SerpGuardService.call(claim_text, max_claims: max_claims)

        render json: SerpGuardResponseSerializer.new(result).as_json
      end

      private

      # Raises ActionController::ParameterMissing when absent OR blank - Rails
      # treats a blank value as missing and says so - which ErrorHandling renders
      # as 400 parameter_missing. ClaimExtractorService independently rejects
      # blank text as a 422 for callers that reach it directly.
      def claim_text
        params.require(:text)
      end

      # Each claim costs two Claude calls and one SerpApi search, so the cap is a
      # spend limit as much as a response-size one. Clamped rather than rejected:
      # a caller asking for 500 claims gets the maximum, not an error.
      def max_claims
        raw = params[:max_claims]
        return nil if raw.blank?

        Integer(raw).clamp(1, ClaimExtractorService::DEFAULT_MAX_CLAIMS)
      rescue ArgumentError, TypeError
        raise SerpGuard::Errors::ValidationError,
              "max_claims must be an integer, got #{raw.inspect}."
      end
    end
  end
end
