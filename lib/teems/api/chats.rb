# frozen_string_literal: true

module Teems
  module Api
    # API wrapper for chat endpoints
    class Chats < Client
      # Get list of chats (1:1, group, meeting)
      def list(limit: 50)
        get(:graph, '/v1.0/me/chats', params: { '$top' => limit })
      end

      # Get a specific chat
      def get_chat(chat_id:)
        get(:graph, "/v1.0/me/chats/#{chat_id}")
      end

      # Get members of a chat
      def members(chat_id:)
        get(:graph, "/v1.0/me/chats/#{chat_id}/members")
      end
    end
  end
end
