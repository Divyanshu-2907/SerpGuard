# frozen_string_literal: true

module SerpGuard
  # Shared HTTP plumbing for the upstream APIs SerpGuard depends on.
  #
  # Subclasses own their own request (endpoint, params, credentials) and how a
  # successful body becomes a domain object. This class owns the timeout and
  # retry policy and the exception mapping, because the same conservative retry
  # behaviour is required of every upstream call and two hand-maintained copies
  # of it would drift apart.
  #
  # A subclass must: `include HTTParty`, set `base_uri`, and implement
  # #service_name and #upstream_error_class.
  class ApiClient
    DEFAULT_OPEN_TIMEOUT = 5
    DEFAULT_READ_TIMEOUT = 30

    # One retry, deliberately. SerpGuard answers inside an HTTP request, so a
    # long retry ladder just converts an upstream outage into a client timeout.
    MAX_ATTEMPTS = 2
    DEFAULT_RETRY_DELAY = 0.5
    MAX_RETRY_DELAY = 2.0

    # Transport-level failures: the request never produced a status code.
    RETRYABLE_EXCEPTIONS = [
      Net::OpenTimeout,
      Net::ReadTimeout,
      Errno::ECONNRESET,
      Errno::ECONNABORTED,
      Errno::EPIPE,
      Errno::ETIMEDOUT,
      Errno::EHOSTUNREACH,
      SocketError,
      OpenSSL::SSL::SSLError
    ].freeze

    TIMEOUT_EXCEPTIONS = [ Net::OpenTimeout, Net::ReadTimeout, Errno::ETIMEDOUT ].freeze

    # Raised and caught inside #with_retries only: the call completed, but with
    # a status worth one more attempt. Never escapes a client.
    class TransientResponse < StandardError
      attr_reader :status, :retry_after, :api_message

      def initialize(status:, api_message:, retry_after: nil)
        @status = status
        @api_message = api_message
        @retry_after = retry_after
        super("upstream returned #{status}: #{api_message}")
      end
    end

    def initialize(
      api_key:,
      credential_env_var:,
      open_timeout: DEFAULT_OPEN_TIMEOUT,
      read_timeout: DEFAULT_READ_TIMEOUT,
      retry_delay: DEFAULT_RETRY_DELAY
    )
      @api_key = api_key.to_s
      @credential_env_var = credential_env_var
      @open_timeout = open_timeout
      @read_timeout = read_timeout
      @retry_delay = retry_delay

      return if @api_key.present?

      raise SerpGuard::Errors::MissingCredential,
            "#{credential_env_var} is not configured, so SerpGuard cannot call #{service_name}."
    end

    private

    attr_reader :api_key, :credential_env_var, :open_timeout, :read_timeout, :retry_delay

    # Human-readable name of the upstream service, used in error messages.
    def service_name
      raise NotImplementedError, "#{self.class} must implement #service_name"
    end

    # The SerpGuard::Errors class this service's outages map onto.
    def upstream_error_class
      raise NotImplementedError, "#{self.class} must implement #upstream_error_class"
    end

    # Runs the block under the shared retry policy. The block should raise
    # TransientResponse for statuses worth retrying and any SerpGuard error
    # directly for statuses that are not - errors raised straight out of the
    # block are never retried, which is what keeps a non-transient 4xx from
    # being sent twice.
    def with_retries
      attempt = 0

      begin
        attempt += 1
        yield
      rescue *RETRYABLE_EXCEPTIONS, TransientResponse => error
        raise translate(error) if attempt >= MAX_ATTEMPTS

        Rails.logger.warn(
          "[serpguard] #{service_name} call failed (#{error.class}: #{error.message}), retrying once"
        )
        sleep(pause_before_retry(error))
        retry
      end
    end

    def request_timeouts
      { open_timeout: open_timeout, read_timeout: read_timeout }
    end

    # Raises for every non-2xx status and returns nil for a 2xx, so callers read
    # as: `check_status!(response, body)` then handle the body.
    def check_status!(response, body)
      status = response.code
      return if status.between?(200, 299)

      case status
      when 401, 403
        raise SerpGuard::Errors::ConfigurationError,
              "#{service_name} rejected our credentials (HTTP #{status}): #{api_error_message(body)}"
      when 429
        raise TransientResponse.new(
          status: status,
          api_message: api_error_message(body),
          retry_after: response.headers["retry-after"]
        )
      when 500..599
        raise TransientResponse.new(status: status, api_message: api_error_message(body))
      else
        # 400, 404, 413 and friends: our request is wrong, and sending it again
        # unchanged would be wrong in exactly the same way.
        raise upstream_error_class,
              "#{service_name} rejected the request (HTTP #{status}): #{api_error_message(body)}"
      end
    end

    # Parses the body rather than using HTTParty's `parsed_response`: httparty
    # 0.24.2 calls JSON.parse with `quirks_mode:`, which json 3.x removed, so
    # `parsed_response` raises ArgumentError on every JSON body in this project.
    #
    # @return [Hash, nil] nil when the body is absent or not a JSON object
    def parse_body(response)
      parsed = JSON.parse(response.body.to_s)
      parsed.is_a?(Hash) ? parsed : nil
    rescue JSON::ParserError
      # A proxy returning HTML, a truncated body: on an error status the status
      # code still tells us what to do, so do not fail over the envelope.
      nil
    end

    # Overridden per service: error bodies do not share a shape.
    def api_error_message(body)
      body&.dig("error", "message").presence || "no error message returned"
    end

    def pause_before_retry(error)
      return retry_delay unless error.is_a?(TransientResponse) && error.retry_after.present?

      # Honour Retry-After, but never park an in-flight HTTP request on it.
      [ error.retry_after.to_f, MAX_RETRY_DELAY ].min
    end

    def translate(error)
      case error
      when TransientResponse
        translate_status(error)
      when *TIMEOUT_EXCEPTIONS
        SerpGuard::Errors::UpstreamTimeout.new(
          "#{service_name} did not respond within #{read_timeout}s (#{error.class})."
        )
      else
        upstream_error_class.new(
          "Could not reach #{service_name}: #{error.class}: #{error.message}"
        )
      end
    end

    def translate_status(error)
      if error.status == 429
        SerpGuard::Errors::UpstreamRateLimited.new(
          "#{service_name} rate-limited SerpGuard: #{error.api_message}"
        )
      else
        upstream_error_class.new(
          "#{service_name} is unavailable (HTTP #{error.status}): #{error.api_message}"
        )
      end
    end
  end
end
