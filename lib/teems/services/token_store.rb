# frozen_string_literal: true

module Teems
  module Services
    # Manages Teams authentication tokens stored in config directory
    class TokenStore
      TOKENS_FILE = 'tokens.json'

      def initialize(paths: nil)
        @paths = paths || Support::XdgPaths.new
      end

      def account
        data = load_tokens
        return nil if data.empty?
        return nil unless data['auth_token'] && data['skype_token']

        Models::Account.new(
          name: data['name'] || 'default',
          auth_token: data['auth_token'],
          skype_token: data['skype_token'],
          chatsvc_token: data['chatsvc_token']
        )
      end

      def save(name:, auth_token:, skype_token:, chatsvc_token: nil)
        @paths.ensure_config_dir
        data = {
          'name' => name,
          'auth_token' => auth_token,
          'skype_token' => skype_token,
          'chatsvc_token' => chatsvc_token,
          'saved_at' => Time.now.iso8601
        }.compact
        File.write(tokens_file, JSON.pretty_generate(data))
        File.chmod(0o600, tokens_file)
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
