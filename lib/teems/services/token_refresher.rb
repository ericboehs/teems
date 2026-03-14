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
      rescue *RECOVERABLE_ERRORS => e
        log("Token exchange error: #{e.class}: #{e.message}")
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
        response = http.request(request)
        parse_exchange_response(response)
      end

      def build_exchange_http
        uri = URI(AUTHSVC_URL)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.open_timeout = 10
        http.read_timeout = 30
        http
      end

      def build_exchange_request(token)
        request = Net::HTTP::Post.new(URI(AUTHSVC_URL))
        request['Authorization'] = "Bearer #{token}"
        request['Content-Type'] = 'application/json'
        request.body = '{}'
        request
      end

      def parse_exchange_response(response)
        unless response.is_a?(Net::HTTPSuccess)
          log("Token exchange failed: HTTP #{response.code}")
          return nil
        end

        JSON.parse(response.body).dig('tokens', 'skypeToken')
      end

      def log(message) = @output&.debug(message)
    end
  end
end
