# frozen_string_literal: true

require "rails_helper"

RSpec.describe "GET /api/v1/health", type: :request do
  def json
    JSON.parse(response.body)
  end

  it "returns 200 with no X-API-Key header" do
    get "/api/v1/health"

    expect(response).to have_http_status(:ok)
    expect(json["status"]).to eq("ok")
    expect(json["service"]).to eq("serpguard")
    expect(json["version"]).to eq(SerpGuard::VERSION)
  end

  it "stays public even when the server has API keys configured" do
    get "/api/v1/health", headers: api_key_headers("obviously-wrong")

    expect(response).to have_http_status(:ok)
  end

  it "returns 200 even when no API keys are configured at all" do
    ENV["SERPGUARD_API_KEYS"] = ""

    get "/api/v1/health"

    expect(response).to have_http_status(:ok)
  end

  it "does not touch MongoDB or any upstream service" do
    # WebMock is on, so an outbound HTTP call would raise. Mongoid is not
    # referenced by the action at all.
    expect { get "/api/v1/health" }.not_to raise_error
    expect(response).to have_http_status(:ok)
  end
end
