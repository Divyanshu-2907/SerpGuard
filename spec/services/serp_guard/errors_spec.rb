# frozen_string_literal: true

require "rails_helper"

RSpec.describe SerpGuard::Errors do
  def error_classes
    described_class.constants.map { |name| described_class.const_get(name) }
                   .select { |const| const.is_a?(Class) }
  end

  it "roots everything at StandardError so a bare `rescue` still catches it" do
    expect(error_classes).to all(be < StandardError)
    expect(error_classes).to include(SerpGuard::Errors::Error)
  end

  it "gives every error a code and an HTTP status" do
    error_classes.each do |klass|
      expect(klass.code).to be_a(String).and be_present
      expect(klass.http_status).to be_a(Symbol)
    end
  end

  it "exposes code and status on instances, which is what ErrorHandling reads" do
    error = SerpGuard::Errors::SerpApiError.new("SerpApi returned 503")

    expect(error.code).to eq("serpapi_error")
    expect(error.http_status).to eq(:bad_gateway)
    expect(error.message).to eq("SerpApi returned 503")
  end

  it "inherits http_status but lets a subclass override just the code" do
    expect(SerpGuard::Errors::AuthenticationError.http_status).to eq(:unauthorized)
    expect(SerpGuard::Errors::InvalidApiKey.http_status).to eq(:unauthorized)
    expect(SerpGuard::Errors::InvalidApiKey.code).to eq("api_key_invalid")
  end

  it "keeps subclass overrides from leaking back into the parent" do
    expect(SerpGuard::Errors::UpstreamError.code).to eq("upstream_error")
    expect(SerpGuard::Errors::UpstreamTimeout.code).to eq("upstream_timeout")
    expect(SerpGuard::Errors::UpstreamTimeout.http_status).to eq(:gateway_timeout)
    expect(SerpGuard::Errors::UpstreamError.http_status).to eq(:bad_gateway)
  end

  it "uses unique codes, since clients switch on them" do
    codes = error_classes.map(&:code)

    expect(codes).to eq(codes.uniq)
  end
end
