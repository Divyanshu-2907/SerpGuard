# frozen_string_literal: true

# Rack::Attack fronts the whole app - the gem's railtie inserts the middleware
# automatically, so an empty config would simply be a no-op.
#
# Limits are deliberately loose. Every check fans out to paid Anthropic and
# SerpApi calls, so the job here is to stop runaway agent loops and obvious key
# sharing, not to police normal use.
#
# Counters live in Rails.cache. The test environment uses :null_store, so
# throttles never trip in specs - keep it that way unless a spec opts in with
# its own store.

# Monitors hit these constantly and they cost nothing to serve.
Rack::Attack.safelist("public endpoints") do |request|
  request.get? && [ "/", "/api/v1/health", "/up" ].include?(request.path)
end

# Per API key: the expensive endpoint.
Rack::Attack.throttle("checks/api_key", limit: 30, period: 1.minute) do |request|
  request.env["HTTP_X_API_KEY"].presence if request.post? && request.path == "/api/v1/checks"
end

# Per IP: a blunt backstop for everything else, including unauthenticated probes.
Rack::Attack.throttle("requests/ip", limit: 120, period: 1.minute, &:ip)

# Throttled responses use the same error envelope as ErrorHandling so clients
# only ever parse one shape. Rack 3 wants lowercase header names.
Rack::Attack.throttled_responder = lambda do |request|
  match_data = request.env["rack.attack.match_data"] || {}
  retry_after = (match_data[:period] || 60).to_i

  body = {
    error: {
      code: "rate_limited",
      message: "Too many requests. Retry in #{retry_after} seconds.",
      retry_after: retry_after
    }
  }.to_json

  [ 429, { "content-type" => "application/json", "retry-after" => retry_after.to_s }, [ body ] ]
end
