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
      rescue SystemCallError, IOError => err
        warn "teems: Could not save tokens: #{err.message}"
        false
      end

      # Update just the skype_token (used during refresh)
      def update_skype_token(skype_token)
        data = load_tokens
        return false if data.empty?

        apply_skype_token(data, skype_token)
      rescue SystemCallError, IOError => err
        warn "teems: Could not update token file: #{err.message}"
        false
      end

      # Get the skype_spaces_token for refresh
      def skype_spaces_token
        load_tokens['skype_spaces_token']
      end

      # Get OIDC refresh credentials
      def refresh_token = load_tokens['refresh_token']
      def client_id = load_tokens['client_id']
      def tenant_id = load_tokens['tenant_id']

      # Update all tokens at once (used by OIDC refresh)
      def update_all_tokens(auth_token:, skype_token:, skype_spaces_token: nil, refresh_token: nil)
        data = load_tokens
        return false if data.empty?

        apply_all_tokens(data,
                         { auth_token: auth_token, skype_token: skype_token,
                           skype_spaces_token: skype_spaces_token, refresh_token: refresh_token })
      rescue SystemCallError, IOError => err
        warn "teems: Could not update token file: #{err.message}"
        false
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
        timestamp = data['tokens_refreshed_at'] || data['saved_at']
        return nil unless timestamp

        Time.now - Time.parse(timestamp)
      rescue ArgumentError
        nil
      end

      private

      def tokens_file
        @paths.config_file(TOKENS_FILE)
      end

      def build_account(data)
        auth_token = data['auth_token']
        skype_token = data['skype_token']
        return nil unless auth_token && skype_token

        Models::Account.new(
          name: data['name'] || 'default', auth_token: auth_token,
          skype_token: skype_token, chatsvc_token: data['chatsvc_token'],
          presence_token: data['skype_spaces_token']
        )
      end

      def apply_skype_token(data, skype_token)
        data.merge!('skype_token' => skype_token, 'skype_token_refreshed_at' => Time.now.iso8601)
        write_token_file(data)
      end

      def apply_all_tokens(data, tokens)
        skype_spaces = tokens[:skype_spaces_token]
        refresh = tokens[:refresh_token]
        updates = { 'auth_token' => tokens[:auth_token], 'skype_token' => tokens[:skype_token],
                    'tokens_refreshed_at' => Time.now.iso8601 }
        updates['skype_spaces_token'] = skype_spaces if skype_spaces
        updates['refresh_token'] = refresh if refresh
        data.merge!(updates)
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
      rescue JSON::ParserError => err
        warn "teems: Token file corrupted (#{err.message}), please re-authenticate with: teems auth login"
        {}
      end
    end
  end
end
