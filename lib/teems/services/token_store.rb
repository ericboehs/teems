# frozen_string_literal: true

module Teems
  module Services
    # Token lookup accessors for TokenStore
    module TokenLookup
      # Get the skype_spaces_token for refresh
      def skype_spaces_token = load_tokens['skype_spaces_token']

      # Get OIDC refresh credentials
      def refresh_token = load_tokens['refresh_token']
      def client_id = load_tokens['client_id']
      def tenant_id = load_tokens['tenant_id']

      def configured?
        File.exist?(tokens_file) && !load_tokens.empty?
      end

      def token_age
        return nil unless File.exist?(tokens_file)

        timestamp = load_tokens['tokens_refreshed_at'] || load_tokens['saved_at']
        timestamp ? Time.now - Time.parse(timestamp) : nil
      rescue ArgumentError
        nil
      end
    end

    # Manages Teams authentication tokens stored in config directory
    class TokenStore
      include TokenLookup

      TOKENS_FILE = 'tokens.json'

      def initialize(paths: Support::XdgPaths.new)
        @paths = paths
      end

      def account
        auth, skype, name, chatsvc, presence =
          load_tokens.values_at('auth_token', 'skype_token', 'name', 'chatsvc_token', 'skype_spaces_token')
        return nil unless auth && skype

        Models::Account.new(
          name: name || 'default', auth_token: auth,
          skype_token: skype, chatsvc_token: chatsvc, presence_token: presence
        )
      end

      def save(**tokens)
        @paths.ensure_config_dir
        write_token_file(tokens.transform_keys(&:to_s).merge('saved_at' => Time.now.iso8601).compact)
      rescue SystemCallError, IOError => e
        warn "teems: Could not save tokens: #{e.message}"
        false
      end

      # Update just the skype_token (used during refresh)
      def update_skype_token(skype_token)
        with_loaded_tokens { |data| apply_skype_token(data, skype_token) }
      rescue SystemCallError, IOError => e
        warn "teems: Could not update token file: #{e.message}"
        false
      end

      # Update all tokens at once (used by OIDC refresh)
      def update_all_tokens(**tokens)
        with_loaded_tokens { |data| apply_all_tokens(data, tokens) }
      rescue SystemCallError, IOError => e
        warn "teems: Could not update token file: #{e.message}"
        false
      end

      def clear = FileUtils.rm_f(tokens_file)

      private

      def with_loaded_tokens
        data = load_tokens
        return false if data.empty?

        yield data
      end

      def tokens_file
        @paths.config_file(TOKENS_FILE)
      end

      def apply_skype_token(data, skype_token)
        data.merge!('skype_token' => skype_token, 'skype_token_refreshed_at' => Time.now.iso8601)
        write_token_file(data)
      end

      def apply_all_tokens(data, tokens)
        updates = tokens.compact.transform_keys(&:to_s).merge('tokens_refreshed_at' => Time.now.iso8601)
        write_token_file(data.merge!(updates))
      end

      def write_token_file(data)
        File.write(tokens_file, JSON.pretty_generate(data))
        File.chmod(0o600, tokens_file)
      end

      def load_tokens
        return {} unless File.exist?(tokens_file)

        JSON.parse(File.read(tokens_file))
      rescue JSON::ParserError => e
        warn "teems: Token file corrupted (#{e.message}), please re-authenticate with: teems auth login"
        {}
      end
    end
  end
end
