# frozen_string_literal: true

require "rails_helper"

RSpec.describe "the service front door", type: :request do
  def json
    JSON.parse(response.body)
  end

  describe "GET /" do
    it "serves the browser demo without requiring authentication" do
      get "/"

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/html")
      expect(response.body).to include("<title>SerpGuard")
    end

    it "serves a page that posts to the real endpoint with an API key header" do
      get "/"

      # Cheap guards against the demo drifting away from the API it calls: these
      # are the three things that would silently break it.
      expect(response.body).to include("/api/v1/checks")
      expect(response.body).to include("X-API-Key")
      expect(response.body).to include('method: "POST"')
    end

    it "offers all three presets" do
      get "/"

      expect(response.body).to include('data-preset="mixed-facts"')
      expect(response.body).to include('data-preset="code-hallucination"')
      expect(response.body).to include('data-preset="outdated-stat"')
    end

    it "renders the pieces the demo promises" do
      get "/"

      expect(response.body).to include("Raw JSON response")
      expect(response.body).to include("Check Claims")
      expect(response.body).to include("free instance")
    end
  end

  describe "GET /api/v1" do
    it "describes the service as JSON without requiring authentication" do
      get "/api/v1"

      expect(response).to have_http_status(:ok)
      expect(json["name"]).to eq("SerpGuard")
      expect(json["version"]).to eq(SerpGuard::VERSION)
      expect(json["status"]).to eq("live")
      expect(json.dig("authentication", "header")).to eq("X-API-Key")
    end

    it "lists every routed endpoint and whether it needs a key" do
      get "/api/v1"

      paths = json["endpoints"].to_h { |endpoint| [ endpoint["path"], endpoint["auth"] ] }

      expect(paths).to eq(
        "/" => false,
        "/api/v1" => false,
        "/api/v1/health" => false,
        "/api/v1/checks" => true
      )
    end

    it "stays public even when a wrong key is sent" do
      get "/api/v1", headers: api_key_headers("obviously-wrong")

      expect(response).to have_http_status(:ok)
    end
  end
end
