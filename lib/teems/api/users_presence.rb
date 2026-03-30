# frozen_string_literal: true

require 'securerandom'

module Teems
  module Api
    # Presence-related API methods for Users class
    module UsersPresence
      def my_presence
        get('/v1.0/me/presence')
      end

      def set_presence(availability:, activity:, duration:)
        post('/v1.0/me/presence/setPresence', body: {
               sessionId: SecureRandom.uuid,
               availability: availability,
               activity: activity,
               expirationDuration: duration
             })
      end

      def set_status_message(message:, expiry: nil)
        post('/v1.0/me/presence/setStatusMessage', body: build_status_message_body(message, expiry))
      end

      def clear_status_message
        set_status_message(message: '')
      end

      def clear_presence
        post('/v1.0/me/presence/clearPresence', body: { sessionId: SecureRandom.uuid })
      end

      private

      def build_status_message_body(message, expiry)
        body = { statusMessage: { message: { content: message, contentType: 'text' } } }
        body[:statusMessage][:expiryDateTime] = { dateTime: expiry, timeZone: 'UTC' } if expiry
        body
      end
    end
  end
end
