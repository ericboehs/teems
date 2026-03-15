# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'
require 'openssl'

module Teems
  module Services
    # Refreshes the skypeToken by exchanging the skype_spaces_token via authsvc
    class TokenRefresher
      AUTHSVC_URL = 'https://teams.microsoft.com/api/authsvc/v1.0/authz'

      RECOVERABLE_ERRORS = [
        SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::ETIMEDOUT,
        Errno::EHOSTUNREACH, Net::OpenTimeout, Net::ReadTimeout,
        OpenSSL::SSL::SSLError, JSON::ParserError
      ].freeze

      def initialize(token_store:, output: nil)
        @token_store = token_store
        @output = output
      end

      def refresh
        skype_spaces_token = @token_store.skype_spaces_token
        return log_and_fail('No skype_spaces_token available for refresh') unless skype_spaces_token

        attempt_refresh(skype_spaces_token)
      rescue *RECOVERABLE_ERRORS => refresh_error
        log("Token exchange error: #{refresh_error.class}: #{refresh_error.message}")
        false
      end

      private

      def attempt_refresh(token)
        log('Attempting to refresh skype_token...')
        new_token = exchange_token(token)
        return log_and_fail('Token refresh failed - skype_spaces_token may be expired') unless new_token

        @token_store.update_skype_token(new_token)
        log('Token refresh successful')
        true
      end

      def log_and_fail(message)
        log(message)
        false
      end

      def exchange_token(skype_spaces_token)
        http = build_exchange_http
        request = build_exchange_request(skype_spaces_token)
        parse_exchange_response(http.request(request))
      end

      def build_exchange_http
        Net::HTTP.new(authsvc_uri.host, authsvc_uri.port).tap { |http| configure_exchange_http(http) }
      end

      def configure_exchange_http(http)
        http.use_ssl = true
        http.open_timeout = 10
        http.read_timeout = 30
      end

      def build_exchange_request(token)
        Net::HTTP::Post.new(authsvc_uri).tap { |req| apply_exchange_headers(req, token) }
      end

      def apply_exchange_headers(request, token)
        request['Authorization'] = "Bearer #{token}"
        request['Content-Type'] = 'application/json'
        request.body = '{}'
      end

      def parse_exchange_response(response)
        return log_exchange_failure(response) unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body).dig('tokens', 'skypeToken')
      end

      def log_exchange_failure(response)
        log("Token exchange failed: HTTP #{response.code}")
        nil
      end

      def authsvc_uri = @authsvc_uri ||= URI(AUTHSVC_URL)

      def log(message) = @output&.debug(message)
    end
  end
end
