# frozen_string_literal: true

require "rails_helper"

# ActionDispatch::Static serves public/index.html for "/" before the router in
# every environment where static file serving is on, so the GET / request specs
# pass regardless of what this controller does. These examples drive the action
# directly, with no middleware in front of it, which is what covers deployments
# that serve static files elsewhere (or not at all).
RSpec.describe MetaController, type: :controller do
  describe "#show" do
    it "sends the demo page itself" do
      get :show

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("<title>SerpGuard")
      expect(response.body).to include('data-preset="mixed-facts"')
    end

    it "sends it as HTML" do
      get :show

      expect(response.media_type).to eq("text/html")
    end

    it "needs no API key" do
      get :show

      expect(response).to have_http_status(:ok)
    end
  end

  describe "#describe" do
    it "renders the service description as JSON" do
      get :describe

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["name"]).to eq("SerpGuard")
    end
  end
end
