source "https://rubygems.org"

gem "rails", "~> 8.1.3", ">= 8.1.3.1"

# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"

# Pinned below 3.0 deliberately. json 3.x moved JSON.parse's options from a
# positional hash to keyword arguments, but activesupport 8.1.3.1 still calls
# `::JSON.parse(json, options)` - so with json 3.x EVERY JSON request body fails
# to parse with "wrong number of arguments", and httparty 0.24.2's
# response.parsed_response raises too. Revisit when Rails ships json 3 support.
gem "json", "~> 2.9"

# --- SerpGuard ---------------------------------------------------------------
# HTTP client for the SerpApi + Anthropic calls.
gem "httparty", "~> 0.22"

# MongoDB ODM. Replaces Active Record (app generated with --skip-active-record).
gem "mongoid"

# Loads .env in every environment. Real ENV vars always win over .env values,
# so this is safe outside development too.
gem "dotenv-rails"

# Throttles the public API surface (see config/initializers/rack_attack.rb).
gem "rack-attack", "~> 6.7"
# ---------------------------------------------------------------------------

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Deploy this application anywhere as a Docker container [https://kamal-deploy.org]
gem "kamal", require: false

# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem "thruster", require: false

# Use Rack CORS for handling Cross-Origin Resource Sharing (CORS), making cross-origin Ajax possible
# gem "rack-cors"

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Test framework (app generated with --skip-test, so there is no minitest suite).
  gem "rspec-rails"

  # Audits gems for known security defects (use config/bundler-audit.yml to ignore issues)
  gem "bundler-audit", require: false

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false
end

group :test do
  # Stubs SerpApi/Anthropic HTTP so specs never hit the network.
  gem "webmock", "~> 3.0"
end
