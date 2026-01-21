# frozen_string_literal: true

module Teems
  module Api
    # API wrapper for messages endpoints
    # Uses Teams ng.msg service for reading messages
    # Requires skypeToken from authsvc exchange (not the JWT from localStorage)
    class Messages < Client
      # Get messages from a channel using ng.msg API
      def channel_messages(team_id:, channel_id:, limit: 50)
        # The ng.msg API uses /v1/users/ME/conversations/{threadId}/messages
        encoded_id = URI.encode_www_form_component(channel_id)
        get(:msgservice, "/v1/users/ME/conversations/#{encoded_id}/messages",
            params: { pageSize: limit, view: 'msnp24Equivalent|supportsMessageProperties' })
      end

      # Get messages from a chat using ng.msg API
      def chat_messages(chat_id:, limit: 50)
        encoded_id = URI.encode_www_form_component(chat_id)
        get(:msgservice, "/v1/users/ME/conversations/#{encoded_id}/messages",
            params: { pageSize: limit, view: 'msnp24Equivalent|supportsMessageProperties' })
      end

      # Get replies to a message
      def replies(thread_id:, message_id:, limit: 50)
        encoded_id = URI.encode_www_form_component(thread_id)
        get(:msgservice, "/v1/users/ME/conversations/#{encoded_id}/messages/#{message_id}/replies",
            params: { pageSize: limit })
      end
    end
  end
end
