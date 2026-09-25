# frozen_string_literal: true

# Turns every exception into the one JSON error shape SerpGuard returns:
#
#   { "error": { "code": "...", "message": "...", "request_id": "..." } }
module ErrorHandling
  extend ActiveSupport::Concern

  included do
    # ORDER MATTERS, AND IT IS NOT THE OBVIOUS ONE.
    #
    # ActiveSupport::Rescuable#rescue_with_handler walks the registered handlers
    # in REVERSE registration order and takes the first class match. So the
    # BROADEST handler is registered FIRST and each narrower one after it.
    # Registering StandardError last would make it win every time and swallow
    # every specific handler below it.
    rescue_from StandardError, with: :handle_unexpected_error
    rescue_from SerpGuard::Errors::Error, with: :handle_known_error
    rescue_from ActionDispatch::Http::Parameters::ParseError, with: :handle_unparsable_body
    rescue_from ActionController::ParameterMissing, with: :handle_parameter_missing
    rescue_from Mongoid::Errors::DocumentNotFound, with: :handle_document_not_found
  end

  private

  # Anything under SerpGuard::Errors already knows its own code and status.
  def handle_known_error(error)
    render_error(code: error.code, message: error.message, status: error.http_status)
  end

  def handle_unparsable_body(_error)
    render_error(
      code: "malformed_json",
      message: "Request body could not be parsed as JSON.",
      status: :bad_request
    )
  end

  def handle_parameter_missing(error)
    render_error(code: "parameter_missing", message: error.message, status: :bad_request)
  end

  def handle_document_not_found(_error)
    render_error(code: "not_found", message: "Resource not found.", status: :not_found)
  end

  # The catch-all. An unknown exception is a bug, so development and test
  # re-raise instead of rendering: a real backtrace and a failing spec are worth
  # far more than a tidy 500 body.
  def handle_unexpected_error(error)
    raise error if Rails.env.local?

    Rails.logger.error("[serpguard] unhandled #{error.class} (#{request.request_id}): #{error.message}")
    Rails.logger.error(error.backtrace.take(20).join("\n")) if error.backtrace

    render_error(
      code: "internal_error",
      message: "Something went wrong on our side. Quote the request_id if you report this.",
      status: :internal_server_error
    )
  end

  def render_error(code:, message:, status:, **extra)
    render json: {
      error: { code: code, message: message, request_id: request.request_id }.merge(extra)
    }, status: status
  end
end
