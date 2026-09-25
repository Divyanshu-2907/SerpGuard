# frozen_string_literal: true

# Base for every SerpGuard controller.
#
# Both concerns are deliberately applied here rather than per controller:
# API key auth is default-deny, and anything public has to opt out by calling
# `skip_api_key_authentication!` in its own class body.
class ApplicationController < ActionController::API
  include ErrorHandling
  include ApiKeyAuthentication
end
