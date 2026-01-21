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

      # Network errors that are expected during token exchange
      NETWORK_ERRORS = [
        SocketError,
        Errno::ECONNREFUSED,
        Errno::ECONNRESET,
        Errno::ETIMEDOUT,
        Errno::EHOSTUNREACH,
        Net::OpenTimeout,
        Net::ReadTimeout,
        OpenSSL::SSL::SSLError,
        JSON::ParserError
      ].freeze

      def initialize(token_store:, output: nil)
        @token_store = token_store
        @output = output
      end

      # Attempt to refresh the skype_token using stored skype_spaces_token
      # Returns true if refresh succeeded, false otherwise
      def refresh
        skype_spaces_token = @token_store.skype_spaces_token
        unless skype_spaces_token
          log('No skype_spaces_token available for refresh')
          return false
        end

        log('Attempting to refresh skype_token...')
        new_skype_token = exchange_token(skype_spaces_token)

        if new_skype_token
          @token_store.update_skype_token(new_skype_token)
          log('Token refresh successful')
          true
        else
          log('Token refresh failed - skype_spaces_token may be expired')
          false
        end
      rescue *NETWORK_ERRORS => e
        log("Token exchange error: #{e.class}: #{e.message}")
        false
      end

      private

      def exchange_token(skype_spaces_token)
        uri = URI(AUTHSVC_URL)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.open_timeout = 10
        http.read_timeout = 30

        request = Net::HTTP::Post.new(uri)
        request['Authorization'] = "Bearer #{skype_spaces_token}"
        request['Content-Type'] = 'application/json'
        request.body = '{}'

        response = http.request(request)

        if response.is_a?(Net::HTTPSuccess)
          data = JSON.parse(response.body)
          data.dig('tokens', 'skypeToken')
        else
          log("Token exchange failed: HTTP #{response.code}")
          nil
        end
      end

      def log(message)
        @output&.debug(message)
      end
    end
  end
end
