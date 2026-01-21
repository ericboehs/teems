# frozen_string_literal: true

module Teems
  module Api
    # API wrapper for chat endpoints
    # Uses Teams ng.msg service for chat operations
    class Chats < Client
      # Get list of conversations (chats, meetings)
      def list(limit: 50)
        get(:msgservice, '/v1/users/ME/conversations',
            params: { pageSize: limit, view: 'msnp24Equivalent' })
      end

      # Get a specific chat
      def get_chat(chat_id:)
        encoded_id = URI.encode_www_form_component(chat_id)
        get(:msgservice, "/v1/users/ME/conversations/#{encoded_id}")
      end

      # Get members of a chat
      def members(chat_id:)
        encoded_id = URI.encode_www_form_component(chat_id)
        get(:msgservice, "/v1/threads/#{encoded_id}/members")
      end
    end
  end
end
