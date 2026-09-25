# frozen_string_literal: true

module Api
  module V1
    # GET /api/v1/health - unauthenticated liveness check.
    #
    # Deliberately dependency-free: it reports that the process booted and
    # answers, and nothing else. It does not open a MongoDB connection or call
    # SerpApi or Anthropic, so a monitor never sees this endpoint fail because a
    # third party is slow. Add a separate /readiness endpoint if dependency
    # probing is ever needed.
    class HealthController < ApplicationController
      skip_api_key_authentication!

      def show
        payload = {
          status: "ok",
          service: "serpguard",
          version: SerpGuard::VERSION,
          environment: Rails.env,
          time: Time.current.utc.iso8601
        }

        # Which credentials are present is useful while developing and pointless
        # to advertise on a public endpoint in production. Booleans only - never
        # the values.
        if Rails.env.local?
          payload[:configuration] = {
            anthropic_api_key: ENV["ANTHROPIC_API_KEY"].present?,
            serpapi_key: ENV["SERPAPI_KEY"].present?,
            serpguard_api_keys: ENV["SERPGUARD_API_KEYS"].present?,
            mongodb_uri: ENV["MONGODB_URI"].present?
          }
        end

        render json: payload
      end
    end
  end
end
