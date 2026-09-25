# frozen_string_literal: true

require "rails_helper"

# A guard on the suite itself: if someone removes the WebMock lockdown, or adds a
# client that bypasses the stubbed transports, these fail rather than quietly
# starting to bill a real API from CI.
RSpec.describe "network isolation" do
  it "blocks outbound HTTP that no example stubbed" do
    expect { HTTParty.get("https://api.anthropic.com/v1/messages") }
      .to raise_error(WebMock::NetConnectNotAllowedError)
  end

  it "blocks localhost too, so a stray local service cannot be relied on" do
    expect { HTTParty.get("http://127.0.0.1:9/") }
      .to raise_error(WebMock::NetConnectNotAllowedError)
  end

  it "has net connect disabled rather than merely unstubbed" do
    expect(WebMock::Config.instance.allow_net_connect).to be_falsey
    expect(WebMock::Config.instance.allow_localhost).to be_falsey
  end

  it "reaches Claude only through the stubbed transport" do
    stub_claude_text("stubbed")

    expect(SerpGuard::ClaudeClient.new.create_message(system: "s", user: "u").text).to eq("stubbed")
  end

  it "reaches SerpApi only through the stubbed transport" do
    stub_serpapi_results([ { title: "T", link: "https://example.com/1", snippet: "S" } ])

    expect(SerpGuard::SerpapiClient.new.search("anything").length).to eq(1)
  end
end
