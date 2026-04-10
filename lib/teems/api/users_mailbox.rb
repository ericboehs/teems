# frozen_string_literal: true

module Teems
  module Api
    # Mailbox settings API methods for Users class (automatic replies / OOO)
    module UsersMailbox
      def auto_replies
        get('/v1.0/me/mailboxSettings/automaticRepliesSetting')
      end

      def update_auto_replies(settings)
        patch('/v1.0/me/mailboxSettings', body: { automaticRepliesSetting: settings })
      end
    end
  end
end
