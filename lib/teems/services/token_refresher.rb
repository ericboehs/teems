# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'
require 'openssl'

module Teems
  module Services
    # Refreshes tokens via OIDC refresh_token flow or authsvc exchange fallback
    class TokenRefresher
      AUTHSVC_URL = 'https://teams.microsoft.com/api/authsvc/v1.0/authz'
      OIDC_TOKEN_ENDPOINT = 'https://login.microsoftonline.com/%s/oauth2/v2.0/token'
      GRAPH_SCOPE = 'https://graph.microsoft.com/.default'
      SKYPE_SCOPE = 'https://api.spaces.skype.com/.default'

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
        result = try_oidc_refresh if oidc_capable?
        return result if result

        attempt_authsvc_refresh
      rescue *RECOVERABLE_ERRORS => e
        log("Token exchange error: #{e.class}: #{e.message}")
        false
      end

      private

      def oidc_capable?
        @token_store.refresh_token && @token_store.client_id && @token_store.tenant_id
      end

      # --- OIDC refresh flow (refreshes ALL tokens) ---

      def try_oidc_refresh
        oidc_refresh
      rescue *RECOVERABLE_ERRORS => e
        log("OIDC refresh error: #{e.class}: #{e.message}, falling back to authsvc...")
        nil
      end

      def oidc_refresh
        log('Attempting OIDC token refresh...')
        tokens = fetch_oidc_tokens
        return nil unless tokens

        @token_store.update_all_tokens(**tokens)
        log('OIDC token refresh successful')
        true
      end

      def fetch_oidc_tokens
        graph = oidc_token_request(GRAPH_SCOPE)
        return nil unless graph

        skype = oidc_token_request(SKYPE_SCOPE, refresh_token: graph['refresh_token'])
        return nil unless skype

        skype_token = exchange_token(skype['access_token'])
        return nil unless skype_token

        { auth_token: graph['access_token'], skype_spaces_token: skype['access_token'],
          skype_token: skype_token, refresh_token: skype['refresh_token'] }
      end

      def oidc_token_request(scope, refresh_token: nil)
        uri = oidc_token_uri
        http = build_oidc_http(uri)
        request = build_oidc_request(uri, scope, refresh_token || @token_store.refresh_token)
        parse_oidc_response(http.request(request))
      end

      def parse_oidc_response(response)
        return log_oidc_failure(response) unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body)
      end

      def log_oidc_failure(response)
        log("OIDC token request failed: HTTP #{response.code}")
        nil
      end

      def oidc_token_uri
        @oidc_token_uri ||= URI(format(OIDC_TOKEN_ENDPOINT, @token_store.tenant_id))
      end

      def build_oidc_http(uri)
        Net::HTTP.new(uri.host, uri.port).tap { |http| configure_http(http) }
      end

      def build_oidc_request(uri, scope, refresh_token)
        Net::HTTP::Post.new(uri).tap do |req|
          req['Content-Type'] = 'application/x-www-form-urlencoded'
          req.body = URI.encode_www_form(
            'client_id' => @token_store.client_id, 'grant_type' => 'refresh_token',
            'refresh_token' => refresh_token, 'scope' => scope
          )
        end
      end

      # --- Authsvc refresh flow (only refreshes skype_token) ---

      def attempt_authsvc_refresh
        skype_spaces_token = @token_store.skype_spaces_token
        return log_and_abandon('No skype_spaces_token available for refresh') unless skype_spaces_token

        attempt_refresh(skype_spaces_token)
      end

      def attempt_refresh(token)
        log('Attempting to refresh skype_token...')
        new_token = exchange_token(token)
        return log_and_abandon('Token refresh failed - skype_spaces_token may be expired') unless new_token

        @token_store.update_skype_token(new_token)
        log('Token refresh successful')
        true
      end

      # --- Shared methods ---

      def exchange_token(skype_spaces_token)
        http = build_exchange_http
        request = build_exchange_request(skype_spaces_token)
        parse_exchange_response(http.request(request))
      end

      def build_exchange_http
        Net::HTTP.new(authsvc_uri.host, authsvc_uri.port).tap { |http| configure_http(http) }
      end

      def configure_http(http)
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

        extract_skype_token(response.body)
      end

      def extract_skype_token(body)
        JSON.parse(body).dig('tokens', 'skypeToken')
      end

      def log_exchange_failure(response)
        log("Token exchange failed: HTTP #{response.code}")
        nil
      end

      def authsvc_uri = @authsvc_uri ||= URI(AUTHSVC_URL)

      def log_and_abandon(message)
        log(message)
        nil
      end

      def log(message) = @output&.debug(message)
    end
  end
end
