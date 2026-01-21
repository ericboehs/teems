# frozen_string_literal: true

module Teems
  module Models
    # Represents a Teams account with authentication tokens
    Account = Data.define(:name, :auth_token, :skype_token, :chatsvc_token) do
      def initialize(name:, auth_token:, skype_token:, chatsvc_token: nil)
        validate_tokens!(auth_token, skype_token)
        super(
          name: name.to_s.freeze,
          auth_token: auth_token.to_s.freeze,
          skype_token: skype_token.to_s.freeze,
          chatsvc_token: chatsvc_token&.to_s&.freeze
        )
      end

      # Authorization header for Teams API endpoints
      def teams_auth_header
        "Bearer #{auth_token}"
      end

      # Authorization header for Skype/chat API endpoints
      def skype_auth_header
        "skypetoken=#{skype_token}"
      end

      # Authorization header for chatsvcagg endpoints
      def chatsvc_auth_header
        return nil unless chatsvc_token

        "Bearer #{chatsvc_token}"
      end

      # Headers for Teams API requests
      def teams_headers
        {
          'Authorization' => teams_auth_header,
          'Content-Type' => 'application/json'
        }
      end

      # Headers for Skype API requests
      def skype_headers
        {
          'Authentication' => skype_auth_header,
          'Content-Type' => 'application/json'
        }
      end

      private

      def validate_tokens!(auth_token, skype_token)
        raise ArgumentError, 'auth_token is required' if auth_token.to_s.empty?
        raise ArgumentError, 'skype_token is required' if skype_token.to_s.empty?
      end
    end
  end
end
