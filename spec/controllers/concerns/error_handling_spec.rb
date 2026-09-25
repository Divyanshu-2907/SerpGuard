# frozen_string_literal: true

require "rails_helper"

# The ordering of `rescue_from` registrations in ErrorHandling is easy to get
# backwards and silently wrong (a broad handler registered last swallows every
# specific one). These specs pin the behaviour rather than the registration.
RSpec.describe ErrorHandling, type: :controller do
  controller(ApplicationController) do
    skip_api_key_authentication!

    def index
      raise self.class.exception_to_raise
    end

    class << self
      attr_accessor :exception_to_raise
    end
  end

  def json
    JSON.parse(response.body)
  end

  context "when a SerpGuard error is raised" do
    it "renders that error's own code and status, not the StandardError fallback" do
      controller.class.exception_to_raise = SerpGuard::Errors::SerpApiError.new("SerpApi is down")

      get :index

      expect(response).to have_http_status(:bad_gateway)
      expect(json.dig("error", "code")).to eq("serpapi_error")
      expect(json.dig("error", "message")).to eq("SerpApi is down")
      # request_id is covered by the request specs: controller specs skip the
      # ActionDispatch::RequestId middleware, so it is nil here by design.
      expect(json["error"]).to have_key("request_id")
    end

    it "matches the most specific registered handler for a deep subclass" do
      controller.class.exception_to_raise = SerpGuard::Errors::UpstreamTimeout.new("timed out")

      get :index

      expect(response).to have_http_status(:gateway_timeout)
      expect(json.dig("error", "code")).to eq("upstream_timeout")
    end
  end

  context "when an unexpected error is raised" do
    it "re-raises in development and test so the backtrace survives" do
      controller.class.exception_to_raise = ArgumentError.new("something unforeseen")

      expect(Rails.env.local?).to be(true)
      expect { get :index }.to raise_error(ArgumentError, "something unforeseen")
    end

    it "renders a generic 500 envelope outside development and test" do
      controller.class.exception_to_raise = ArgumentError.new("something unforeseen")
      allow(Rails.env).to receive(:local?).and_return(false)

      get :index

      expect(response).to have_http_status(:internal_server_error)
      expect(json.dig("error", "code")).to eq("internal_error")
      expect(json.dig("error", "message")).not_to include("unforeseen")
    end
  end
end
