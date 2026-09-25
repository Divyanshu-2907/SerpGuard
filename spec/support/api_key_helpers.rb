# frozen_string_literal: true

# Request specs run against a configured set of API keys, since an app with no
# keys at all is a distinct (500) case that only a couple of specs care about.
module ApiKeyHelpers
  VALID_API_KEY = "spec-key-0123456789abcdef0123456789abcdef"
  OTHER_VALID_API_KEY = "spec-key-fedcba9876543210fedcba9876543210"

  def api_key_headers(key = VALID_API_KEY)
    { ApiKeyAuthentication::HEADER => key }
  end
end

RSpec.configure do |config|
  config.include ApiKeyHelpers

  config.around(:each) do |example|
    previous = ENV["SERPGUARD_API_KEYS"]
    ENV["SERPGUARD_API_KEYS"] =
      [ ApiKeyHelpers::VALID_API_KEY, ApiKeyHelpers::OTHER_VALID_API_KEY ].join(",")
    begin
      example.run
    ensure
      ENV["SERPGUARD_API_KEYS"] = previous
    end
  end
end
