# frozen_string_literal: true

require 'securerandom'
require 'digest'
require 'net/http'
require 'json'
require 'uri'

module Teems
  module Services
    # Builds OAuth authorize URLs for the Teams app registration
    module OAuthUrlBuilder
      TEAMS_APP_ID = '5e3ce6c0-2b1f-4285-8d4b-75ee78787346'
      REDIRECT_URI = 'https://teams.microsoft.com/go'
      AUTHORIZE_ENDPOINT = 'https://login.microsoftonline.com/%s/oauth2/authorize'

      private

      def build_authorize_url(context, response_type, **opts)
        params = base_authorize_params(response_type)
        apply_optional_params(params, context[:hint], opts)
        build_authorize_uri(context[:tenant], params)
      end

      def apply_optional_params(params, hint, opts)
        resource = opts[:resource]
        pkce = opts[:pkce]
        params['resource'] = resource if resource
        add_login_hints(params, hint)
        add_pkce_params(params, pkce) if pkce
      end

      def base_authorize_params(response_type)
        nonces = Array.new(2) { SecureRandom.uuid }
        { 'response_type' => response_type, 'client_id' => TEAMS_APP_ID,
          'redirect_uri' => REDIRECT_URI, 'state' => nonces[0], 'nonce' => nonces[1] }
      end

      def add_login_hints(params, hint)
        return unless hint

        params['login_hint'] = hint
        domain = hint.split('@').last
        params['domain_hint'] = domain if domain
      end

      def add_pkce_params(params, pkce)
        params['code_challenge'] = pkce[:challenge]
        params['code_challenge_method'] = 'S256'
      end

      def build_authorize_uri(tenant, params)
        uri = URI(format(AUTHORIZE_ENDPOINT, tenant))
        uri.query = URI.encode_www_form(params)
        uri.to_s
      end
    end

    # PKCE helpers and Graph authorization code exchange
    module OAuthCodeExchange
      TOKEN_ENDPOINT = 'https://login.microsoftonline.com/%s/oauth2/token'
      GRAPH_RESOURCE = 'https://graph.microsoft.com'

      private

      def generate_pkce
        verifier = base64url(SecureRandom.random_bytes(32))
        challenge = base64url(Digest::SHA256.digest(verifier))
        { verifier: verifier, challenge: challenge }
      end

      def base64url(data) = [data].pack('m0').tr('+/', '-_').delete('=')

      def exchange_graph_code(exchange)
        response = post_token_exchange(exchange)
        return nil unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body)
      rescue StandardError => e
        log("Graph code exchange failed: #{e.message}")
        nil
      end

      def post_token_exchange(exchange)
        uri = URI(format(TOKEN_ENDPOINT, exchange[:tenant]))
        post = build_exchange_request(uri, exchange)
        Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                                            open_timeout: 10, read_timeout: 30) { |http| http.request(post) }
      end

      def build_exchange_request(uri, exchange)
        Net::HTTP::Post.new(uri, 'Content-Type' => 'application/x-www-form-urlencoded',
                                 'Origin' => 'https://teams.microsoft.com').tap do |post|
          post.body = token_exchange_body(exchange)
        end
      end

      def token_exchange_body(exchange)
        URI.encode_www_form(
          'grant_type' => 'authorization_code', 'client_id' => OAuthUrlBuilder::TEAMS_APP_ID,
          'code' => exchange[:code], 'redirect_uri' => OAuthUrlBuilder::REDIRECT_URI,
          'resource' => GRAPH_RESOURCE, 'code_verifier' => exchange[:verifier]
        )
      end

      def decode_jwt(token)
        payload = token.split('.')[1]
        return nil unless payload

        padded = payload.tr('-_', '+/').ljust((payload.length + 3) & ~3, '=')
        JSON.parse(padded.unpack1('m'))
      rescue StandardError
        nil
      end
    end

    # Polls Safari's URL bar via AppleScript and manages Safari tab navigation
    module SafariOAuthPolling
      private

      def poll_safari_query_redirect
        raw = run_applescript(poll_query_redirect_script).to_s
        if raw.empty? || raw == 'timeout'
          log('Safari OAuth: fast capture missed, falling back')
          return nil
        end

        log('Safari OAuth: captured authorization code')
        parse_oauth_params(raw)
      end

      # Poll for ?code= in the URL — Safari's URL property includes query strings
      def poll_query_redirect_script
        <<~APPLESCRIPT
          tell application "Safari"
            repeat 600 times
              try
                set pageURL to URL of current tab of front window
                if pageURL contains "teams.microsoft.com/go?" then
                  set codeStart to offset of "?" in pageURL
                  return text (codeStart + 1) thru -1 of pageURL
                end if
              end try
              delay 0.02
            end repeat
            return "timeout"
          end tell
        APPLESCRIPT
      end

      def parse_oauth_params(raw)
        raw.split('&').each_with_object({}) do |pair, hash|
          key, value = pair.split('=', 2)
          hash[key] = URI.decode_www_form_component(value.to_s)
        end
      end

      def open_safari_to(url)
        run_applescript(open_safari_tab_script(url))
      end

      def open_safari_tab_script(url)
        <<~APPLESCRIPT
          tell application "Safari"
            activate
            if (count of windows) = 0 then
              make new document with properties {URL:"#{url}"}
            else
              tell front window
                set current tab to (make new tab with properties {URL:"#{url}"})
              end tell
            end if
          end tell
        APPLESCRIPT
      end

      def navigate_safari_to(url)
        run_applescript(<<~APPLESCRIPT)
          tell application "Safari"
            set URL of current tab of front window to "#{url}"
          end tell
        APPLESCRIPT
      end
    end

    # Single-hop Safari OAuth: one authorization code request via Safari (SSO Extension
    # handles device auth), then HTTP exchanges for remaining tokens. Uses query string
    # (?code=...) which Safari preserves, unlike fragments (#token=...) which get lost.
    module SafariOAuth
      include OAuthUrlBuilder
      include OAuthCodeExchange
      include SafariOAuthPolling

      SKYPE_RESOURCE = 'https://api.spaces.skype.com'

      private

      def try_safari_oauth
        hint, tenant = stored_login_hint
        return nil unless tenant

        log('Trying fast Safari OAuth flow...')
        safari_code_flow({ tenant: tenant, hint: hint })
      rescue StandardError => e
        log("Safari OAuth error: #{e.class}: #{e.message}")
        nil
      ensure
        close_teams_tab if tenant
      end

      def safari_code_flow(context)
        graph = fetch_graph_via_safari(context)
        return nil unless graph

        skype = fetch_skype_via_refresh(graph, context[:tenant])
        return nil unless skype

        log('Safari OAuth: all tokens acquired!')
        assemble_safari_result(context, graph, skype)
      end

      def fetch_graph_via_safari(context)
        pkce = generate_pkce
        url = build_authorize_url(context, 'code', resource: GRAPH_RESOURCE, pkce: pkce)
        log('Safari OAuth: requesting authorization code...')
        open_safari_to(url)
        params = poll_safari_query_redirect
        return nil unless params&.dig('code')

        log('Safari OAuth: exchanging code for Graph tokens...')
        exchange_graph_code(code: params['code'], verifier: pkce[:verifier], tenant: context[:tenant])
      end

      def fetch_skype_via_refresh(graph, tenant)
        graph_rt = graph['refresh_token']
        return nil unless graph_rt

        log('Safari OAuth: refreshing for Skype token...')
        result = refresh_for_resource(token: graph_rt, tenant: tenant, resource: SKYPE_RESOURCE)
        return nil unless result

        { spaces_token: result['access_token'], refresh_token: result['refresh_token'] }
      end

      def refresh_for_resource(grant)
        response = post_refresh_request(grant)
        return log_refresh_error(response) unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body)
      rescue StandardError => e
        log("Token refresh failed: #{e.class}: #{e.message}")
        nil
      end

      def log_refresh_error(response)
        log("Token refresh failed: HTTP #{response.code}")
        nil
      end

      # :reek:FeatureEnvy
      def post_refresh_request(grant)
        uri = URI(format(OAuthCodeExchange::TOKEN_ENDPOINT, grant[:tenant]))
        post = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/x-www-form-urlencoded',
                                        'Origin' => 'https://teams.microsoft.com')
        post.body = URI.encode_www_form('grant_type' => 'refresh_token',
                                        'client_id' => OAuthUrlBuilder::TEAMS_APP_ID,
                                        'refresh_token' => grant[:token],
                                        'resource' => grant[:resource])
        Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                                            open_timeout: 10, read_timeout: 30) { |http| http.request(post) }
      end

      # :reek:FeatureEnvy
      def assemble_safari_result(context, graph, skype)
        spaces_token = skype[:spaces_token]
        { auth_token: graph['access_token'],
          skype_token: exchange_skype_via_http(spaces_token),
          skype_spaces_token: spaces_token, chatsvc_token: nil,
          refresh_token: skype[:refresh_token],
          client_id: OAuthUrlBuilder::TEAMS_APP_ID,
          tenant_id: context[:tenant] }
      end
    end
  end
end
