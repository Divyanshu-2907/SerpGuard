# frozen_string_literal: true

# The front door, in two formats:
#
#   GET /        - the browser demo (public/index.html)
#   GET /api/v1  - the same service description as JSON, for clients and agents
#
# Neither requires a key. Neither touches MongoDB, SerpApi or Anthropic.
class MetaController < ApplicationController
  skip_api_key_authentication!

  DEMO_PAGE = "index.html"

  # Note: with `config.public_file_server.enabled` (development, test, and
  # Thruster in production), ActionDispatch::Static serves public/index.html for
  # "/" before the router ever sees the request - so this action is the fallback
  # that keeps "/" working when static file serving is turned off, and both paths
  # return the same bytes.
  def show
    send_file Rails.public_path.join(DEMO_PAGE), type: "text/html", disposition: "inline"
  end

  # The machine-readable half, unchanged in shape from when it lived at "/".
  def describe
    render json: {
      name: "SerpGuard",
      version: SerpGuard::VERSION,
      api_version: SerpGuard::API_VERSION,
      status: "live",
      description: "Verifies factual and technical claims in AI-generated text or code " \
                   "against live SerpApi search results.",
      hackathon: {
        event: "SerpApi India Hackathon 2026",
        track: "AI Agents"
      },
      authentication: {
        scheme: "api_key",
        header: ApiKeyAuthentication::HEADER,
        note: "Every endpoint requires a key except GET /, GET /api/v1 and GET /api/v1/health."
      },
      endpoints: [
        {
          method: "GET",
          path: "/",
          auth: false,
          description: "Browser demo page."
        },
        {
          method: "GET",
          path: "/api/v1",
          auth: false,
          description: "This service description."
        },
        {
          method: "GET",
          path: "/api/v1/health",
          auth: false,
          description: "Liveness check. Does not depend on MongoDB or any upstream API."
        },
        {
          method: "POST",
          path: "/api/v1/checks",
          auth: true,
          description: "Submit text or code in `text`; returns a verdict, reason and source per " \
                       "claim. Optional `max_claims` (1-25). Repeated claims are served from cache."
        }
      ]
    }
  end
end
