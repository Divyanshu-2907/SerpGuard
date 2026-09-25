# frozen_string_literal: true

# Shared-secret auth for the public API.
#
# Callers present one of the keys listed in SERPGUARD_API_KEYS (comma separated)
# in the X-API-Key header. Every controller inheriting from ApplicationController
# is authenticated by default; endpoints that must stay public opt out
# explicitly with `skip_api_key_authentication!`.
module ApiKeyAuthentication
  extend ActiveSupport::Concern

  HEADER = "X-API-Key"
  KEYS_ENV_VAR = "SERPGUARD_API_KEYS"

  included do
    before_action :authenticate_api_key!
  end

  class_methods do
    # Marks a controller as public: the service description and the health check.
    def skip_api_key_authentication!(**options)
      skip_before_action :authenticate_api_key!, **options
    end
  end

  private

  attr_reader :current_api_key

  def authenticate_api_key!
    # No configured keys means no request could ever be authorised. That is a
    # deployment mistake rather than a caller mistake, so say so instead of
    # handing out a misleading 401 forever.
    if configured_api_keys.empty?
      raise SerpGuard::Errors::MissingCredential,
            "#{KEYS_ENV_VAR} is not configured, so no request can be authenticated."
    end

    presented_key = request.headers[HEADER].to_s
    if presented_key.blank?
      raise SerpGuard::Errors::MissingApiKey, "Provide your API key in the #{HEADER} header."
    end

    unless configured_api_keys.any? { |known_key| secure_equal?(presented_key, known_key) }
      raise SerpGuard::Errors::InvalidApiKey, "The #{HEADER} header did not match a known API key."
    end

    @current_api_key = presented_key
  end

  # Constant-time, so a caller cannot recover a valid key byte by byte from
  # response timings. secure_compare digests both sides first, so strings of
  # differing length are safe to pass in.
  def secure_equal?(presented_key, known_key)
    ActiveSupport::SecurityUtils.secure_compare(presented_key, known_key)
  end

  # Memoised per request rather than per process, so rotating the env var needs
  # only a restart and specs can set it freely.
  def configured_api_keys
    @configured_api_keys ||= ENV.fetch(KEYS_ENV_VAR, "").split(",").filter_map do |key|
      key.strip.presence
    end
  end
end
