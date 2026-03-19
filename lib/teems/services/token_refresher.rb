# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'
require 'openssl'

module Teems
  module Services
    # OIDC refresh: exchange refresh_token for new access tokens via Entra ID
    module OidcRefresh
      OIDC_TOKEN_ENDPOINT = 'https://login.microsoftonline.com/%s/oauth2/v2.0/token'
      GRAPH_SCOPE = 'https://graph.microsoft.com/.default'
      SKYPE_SCOPE = 'https://api.spaces.skype.com/.default'

      private

      def oidc_capable?
        @token_store.refresh_token && @token_store.client_id && @token_store.tenant_id
      end

      def try_oidc_refresh
        oidc_refresh
      rescue *TokenRefresher::RECOVERABLE_ERRORS => e
        log("OIDC refresh error: #{e.class}: #{e.message}, falling back to authsvc...")
        nil
      end

      def oidc_refresh
        log('Attempting OIDC token refresh...')
        return nil unless (tokens = fetch_oidc_tokens)

        @token_store.update_all_tokens(**tokens)
        log('OIDC token refresh successful')
        true
      end

      def fetch_oidc_tokens
        graph = oidc_token_request(GRAPH_SCOPE, @token_store.refresh_token)
        return nil unless graph

        skype = oidc_token_request(SKYPE_SCOPE, graph['refresh_token'])
        return nil unless skype

        build_oidc_result(graph, skype)
      end

      def build_oidc_result(graph, skype)
        skype_access, skype_refresh = skype.values_at('access_token', 'refresh_token')
        skype_token = exchange_token(skype_access)
        return nil unless skype_token

        { auth_token: graph['access_token'], skype_spaces_token: skype_access,
          skype_token: skype_token, refresh_token: skype_refresh }
      end

      def oidc_token_request(scope, refresh_token)
        response = send_oidc_request(scope, refresh_token)
        return log_oidc_failure(response) unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body)
      end

      def send_oidc_request(scope, refresh_token)
        uri = oidc_token_uri
        post = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/x-www-form-urlencoded',
                                        'Origin' => 'https://teams.microsoft.com')
        post.body = oidc_request_body(scope, refresh_token)
        Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10,
                                            read_timeout: 30) { |http| http.request(post) }
      end

      def oidc_request_body(scope, token)
        URI.encode_www_form(
          'client_id' => @token_store.client_id, 'grant_type' => 'refresh_token',
          'refresh_token' => token, 'scope' => scope
        )
      end

      def log_oidc_failure(response)
        log("OIDC token request failed: HTTP #{response.code}")
        nil
      end

      def oidc_token_uri
        @oidc_token_uri ||= URI(format(OIDC_TOKEN_ENDPOINT, @token_store.tenant_id))
      end
    end

    # Refreshes tokens via OIDC refresh_token flow or authsvc exchange fallback
    class TokenRefresher
      include OidcRefresh

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
        (oidc_capable? && try_oidc_refresh) || attempt_authsvc_refresh
      rescue *RECOVERABLE_ERRORS => e
        log("Token exchange error: #{e.class}: #{e.message}")
        false
      end

      private

      def attempt_authsvc_refresh
        skype_spaces_token = @token_store.skype_spaces_token
        return log_and_abandon('No skype_spaces_token available for refresh') unless skype_spaces_token

        attempt_refresh(skype_spaces_token)
      end

      def attempt_refresh(token)
        new_token = exchange_and_log(token)
        return log_and_abandon('Token refresh failed - skype_spaces_token may be expired') unless new_token

        @token_store.update_skype_token(new_token)
        log('Token refresh successful')
        true
      end

      def exchange_and_log(token)
        log('Attempting to refresh skype_token...')
        exchange_token(token)
      end

      def exchange_token(skype_spaces_token)
        response = post_authsvc_exchange(skype_spaces_token)
        return log_exchange_failure(response) unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body).dig('tokens', 'skypeToken')
      end

      def post_authsvc_exchange(token)
        post = Net::HTTP::Post.new(authsvc_uri,
                                   'Authorization' => "Bearer #{token}",
                                   'Content-Type' => 'application/json')
        post.body = '{}'
        Net::HTTP.start(authsvc_uri.host, authsvc_uri.port,
                        use_ssl: true, open_timeout: 10,
                        read_timeout: 30) { |http| http.request(post) }
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
