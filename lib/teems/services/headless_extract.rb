# frozen_string_literal: true

require 'open3'
require 'json'
require 'net/http'
require 'uri'

module Teems
  module Services
    # Compiles and manages the Swift WKWebView helper binary
    module HelperBinary
      SWIFT_FRAMEWORKS = %w[WebKit Security AppKit].freeze

      private

      def ensure_helper_binary
        source = helper_source_path
        binary = helper_binary_path
        return nil unless File.exist?(source)
        return binary if File.exist?(binary) && File.mtime(binary) >= File.mtime(source)

        compile_helper(source, binary)
      end

      def compile_helper(source, binary)
        log('Compiling headless token helper...')
        _, status = Open3.capture2(*swiftc_command(source, binary))
        status.success? ? binary : log_and_nil('Failed to compile helper')
      rescue Errno::ENOENT
        log_and_nil('swiftc not found')
      end

      # :reek:UtilityFunction
      def swiftc_command(source, binary)
        ['swiftc', *SWIFT_FRAMEWORKS.flat_map { |fw| ['-framework', fw] }, source, '-o', binary]
      end

      def log_and_nil(message)
        log(message)
        nil
      end

      def helper_source_path
        File.expand_path('../../../support/token_helper.swift', __dir__)
      end

      def helper_binary_path
        helper_source_path.sub(/\.swift$/, '')
      end
    end

    # HTTP-based Skype token exchange (no browser needed)
    module HttpSkypeExchange
      AUTHSVC_URL = 'https://teams.microsoft.com/api/authsvc/v1.0/authz'

      private

      # :reek:UtilityFunction :reek:TooManyStatements :reek:UncommunicativeVariableName
      def exchange_skype_via_http(skype_spaces_token)
        return nil unless skype_spaces_token

        response = post_authsvc_exchange(skype_spaces_token)
        return nil unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body).dig('tokens', 'skypeToken')
      rescue StandardError => e
        log("Skype exchange failed: #{e.message}")
        nil
      end

      # :reek:UtilityFunction
      def post_authsvc_exchange(token)
        uri = URI(AUTHSVC_URL)
        http = build_authsvc_http(uri)
        http.request(build_authsvc_request(uri, token))
      end

      # :reek:UtilityFunction
      def build_authsvc_http(uri)
        Net::HTTP.new(uri.host, uri.port).tap do |http|
          http.use_ssl = true
          http.open_timeout = 10
          http.read_timeout = 30
        end
      end

      # :reek:UtilityFunction
      def build_authsvc_request(uri, token)
        Net::HTTP::Post.new(uri).tap do |req|
          req['Authorization'] = "Bearer #{token}"
          req['Content-Type'] = 'application/json'
          req.body = '{}'
        end
      end
    end

    # Headless token extraction via WKWebView Swift helper.
    # Uses OAuth2 implicit flow with redirect interception — no Safari needed.
    # Falls through to Safari when no cached Entra ID session exists.
    module HeadlessExtract
      include HelperBinary
      include HttpSkypeExchange

      HELPER_TIMEOUT = 60
      NEEDS_SAFARI_EXIT = 2

      private

      # :reek:TooManyStatements :reek:UncommunicativeVariableName
      def try_headless_extract
        binary = ensure_helper_binary
        return nil unless binary

        log('Trying headless token extraction...')
        output, status = Open3.capture2(binary, *build_helper_args)
        handle_helper_result(output, status.exitstatus)
      rescue StandardError => e
        log("Headless extraction error: #{e.message}")
        nil
      end

      def handle_helper_result(output, exit_code)
        return parse_headless_result(output) if exit_code.zero?

        message = exit_code == NEEDS_SAFARI_EXIT ? 'No cached session' : "Helper exited #{exit_code}"
        log("#{message}, falling back to Safari...")
        nil
      end

      def build_helper_args
        hint, tenant = stored_login_hint
        ['--timeout', HELPER_TIMEOUT.to_s,
         *(hint ? ['--login-hint', hint] : []),
         *(tenant ? ['--tenant-id', tenant] : [])]
      end

      # :reek:UtilityFunction
      def stored_login_hint
        path = locate_token_store
        return [nil, nil] unless path && File.exist?(path)

        data = JSON.parse(File.read(path))
        [extract_upn(data['auth_token']), data['tenant_id']]
      rescue StandardError
        [nil, nil]
      end

      # :reek:UtilityFunction
      def extract_upn(jwt)
        return nil unless jwt && (payload = jwt.split('.')[1])

        padded = payload.tr('-_', '+/').ljust((payload.length + 3) & ~3, '=')
        JSON.parse(padded.unpack1('m'))['upn']
      rescue StandardError
        nil
      end

      # :reek:UtilityFunction
      def locate_token_store
        config = ENV.fetch('XDG_CONFIG_HOME', File.join(Dir.home, '.config'))
        File.join(config, 'teems', 'tokens.json')
      end

      # :reek:TooManyStatements :reek:UncommunicativeVariableName
      def parse_headless_result(output)
        parsed = JSON.parse(output.strip)
        return nil unless parsed['auth_token']

        build_headless_tokens(parsed)
      rescue JSON::ParserError => e
        log("Failed to parse headless result: #{e.message}")
        nil
      end

      # :reek:FeatureEnvy
      def build_headless_tokens(parsed)
        spaces_token = parsed['skype_spaces_token']

        { auth_token: parsed['auth_token'], skype_token: exchange_skype_via_http(spaces_token),
          skype_spaces_token: spaces_token, chatsvc_token: nil,
          refresh_token: nil, client_id: parsed['client_id'], tenant_id: parsed['tenant_id'] }
      end
    end
  end
end
