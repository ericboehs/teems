# frozen_string_literal: true

module Teems
  module Services
    # Manages Teams authentication tokens stored in config directory
    class TokenStore
      TOKENS_FILE = 'tokens.json'

      def initialize(paths: Support::XdgPaths.new)
        @paths = paths
      end

      def account
        data = load_tokens
        return nil if data.empty?

        build_account(data)
      end

      def save(name:, auth_token:, skype_token: nil, **extra_tokens)
        @paths.ensure_config_dir
        data = build_save_data(name, auth_token, skype_token, extra_tokens)
        write_token_file(data)
      rescue SystemCallError, IOError => e
        warn "teems: Could not save tokens: #{e.message}"
        false
      end

      # Update just the skype_token (used during refresh)
      def update_skype_token(skype_token)
        data = load_tokens
        return false if data.empty?

        apply_skype_token(data, skype_token)
      rescue SystemCallError, IOError => e
        warn "teems: Could not update token file: #{e.message}"
        false
      end

      # Get the skype_spaces_token for refresh
      def skype_spaces_token
        load_tokens['skype_spaces_token']
      end

      def clear
        FileUtils.rm_f(tokens_file)
      end

      def configured?
        File.exist?(tokens_file) && !load_tokens.empty?
      end

      def token_age
        return nil unless File.exist?(tokens_file)

        data = load_tokens
        return nil unless data['saved_at']

        saved_at = Time.parse(data['saved_at'])
        Time.now - saved_at
      rescue ArgumentError
        nil
      end

      private

      def tokens_file
        @paths.config_file(TOKENS_FILE)
      end

      def build_account(data)
        return nil unless data['auth_token'] && data['skype_token']

        Models::Account.new(
          name: data['name'] || 'default', auth_token: data['auth_token'],
          skype_token: data['skype_token'], chatsvc_token: data['chatsvc_token']
        )
      end

      def apply_skype_token(data, skype_token)
        data.merge!('skype_token' => skype_token, 'skype_token_refreshed_at' => Time.now.iso8601)
        write_token_file(data)
      end

      def build_save_data(name, auth_token, skype_token, extra_tokens)
        { 'name' => name, 'auth_token' => auth_token, 'skype_token' => skype_token,
          'saved_at' => Time.now.iso8601 }.merge(extra_tokens.transform_keys(&:to_s)).compact
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
