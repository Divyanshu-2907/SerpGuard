# frozen_string_literal: true

module SerpGuard
  # Every error SerpGuard raises on purpose lives under this namespace.
  #
  # Each class carries the two things the HTTP layer needs:
  #
  #   code        - stable machine-readable string for API clients
  #   http_status - Rack status symbol to render it with
  #
  # ErrorHandling (app/controllers/concerns/error_handling.rb) rescues
  # Errors::Error and reads both off the instance, so adding a class here is
  # enough to give it correct API behaviour - no controller changes needed.
  #
  # There is no behaviour in this file on purpose: it is the phase-1 skeleton
  # that the extraction and verification services will raise into.
  module Errors
    class Error < StandardError
      class_attribute :code, instance_writer: false, default: "internal_error"
      class_attribute :http_status, instance_writer: false, default: :internal_server_error
    end

    # --- Caller's fault (4xx) -------------------------------------------------

    class BadRequest < Error
      self.code = "bad_request"
      self.http_status = :bad_request
    end

    class ValidationError < Error
      self.code = "validation_failed"
      # :unprocessable_content / :content_too_large are the current Rack names;
      # :unprocessable_entity and :payload_too_large are deprecated aliases.
      self.http_status = :unprocessable_content
    end

    class NotFound < Error
      self.code = "not_found"
      self.http_status = :not_found
    end

    class PayloadTooLarge < Error
      self.code = "payload_too_large"
      self.http_status = :content_too_large
    end

    class AuthenticationError < Error
      self.code = "unauthorized"
      self.http_status = :unauthorized
    end

    class MissingApiKey < AuthenticationError
      self.code = "api_key_missing"
    end

    class InvalidApiKey < AuthenticationError
      self.code = "api_key_invalid"
    end

    class RateLimited < Error
      self.code = "rate_limited"
      self.http_status = :too_many_requests
    end

    # --- Our fault (5xx) -----------------------------------------------------

    class ConfigurationError < Error
      self.code = "configuration_error"
      self.http_status = :internal_server_error
    end

    class MissingCredential < ConfigurationError
      self.code = "credential_missing"
    end

    # --- Upstream services: SerpApi, Anthropic -------------------------------

    class UpstreamError < Error
      self.code = "upstream_error"
      self.http_status = :bad_gateway
    end

    class UpstreamTimeout < UpstreamError
      self.code = "upstream_timeout"
      self.http_status = :gateway_timeout
    end

    class UpstreamRateLimited < UpstreamError
      self.code = "upstream_rate_limited"
      self.http_status = :too_many_requests
    end

    class SerpApiError < UpstreamError
      self.code = "serpapi_error"
    end

    class AnthropicError < UpstreamError
      self.code = "anthropic_error"
    end

    # --- Verification pipeline (phase 2) -------------------------------------

    class PipelineError < Error
      self.code = "pipeline_error"
      self.http_status = :internal_server_error
    end

    class ExtractionFailed < PipelineError
      self.code = "claim_extraction_failed"
    end

    class VerificationFailed < PipelineError
      self.code = "verification_failed"
    end
  end
end
