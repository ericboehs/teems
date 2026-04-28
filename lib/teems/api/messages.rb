# frozen_string_literal: true

module Teems
  module Api
    # API wrapper for messages endpoints
    # Uses Teams ng.msg service for reading messages
    # Requires skypeToken from authsvc exchange (not the JWT from localStorage)
    class Messages < Client
      ENDPOINT = :msgservice

      # Get messages from a channel using ng.msg API
      def channel_messages(channel_id:, limit: 50)
        # The ng.msg API uses /v1/users/ME/conversations/{threadId}/messages
        encoded_id = URI.encode_www_form_component(channel_id)
        get("/v1/users/ME/conversations/#{encoded_id}/messages",
            params: { pageSize: limit, view: 'msnp24Equivalent|supportsMessageProperties' })
      end

      # Get messages from a chat using ng.msg API
      def chat_messages(chat_id:, limit: 50)
        encoded_id = URI.encode_www_form_component(chat_id)
        get("/v1/users/ME/conversations/#{encoded_id}/messages",
            params: { pageSize: limit, view: 'msnp24Equivalent|supportsMessageProperties' })
      end

      # Get a page of messages for sync, with pagination support.
      # Returns the full response hash including _metadata for pagination.
      #
      # When backward_link is provided, follows it directly to get older messages.
      # Otherwise builds a request with startTime for time-range filtering.
      #
      # The ng.msg API returns newest-first with _metadata.backwardLink for older pages.
      def chat_messages_page(chat_id:, limit: 200, **pagination)
        backward_link = pagination[:backward_link]
        return get(backward_link, params: {}) if backward_link

        encoded_id = URI.encode_www_form_component(chat_id)
        params = messages_page_params(limit, pagination[:start_time])
        get("/v1/users/ME/conversations/#{encoded_id}/messages", params: params)
      end

      # Get a single message by ID
      def message(thread_id:, message_id:)
        encoded_id = URI.encode_www_form_component(thread_id)
        get("/v1/users/ME/conversations/#{encoded_id}/messages/#{message_id}")
      end

      # Get replies to a message
      def replies(thread_id:, message_id:, limit: 50)
        encoded_id = URI.encode_www_form_component(thread_id)
        get("/v1/users/ME/conversations/#{encoded_id}/messages/#{message_id}/replies",
            params: { pageSize: limit })
      end

      private

      def messages_page_params(limit, start_time)
        { pageSize: limit, view: 'msnp24Equivalent|supportsMessageProperties' }.tap do |params|
          params[:startTime] = (start_time.to_f * 1000).to_i if start_time
        end
      end
    end
  end
end
