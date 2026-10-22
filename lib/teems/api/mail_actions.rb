# frozen_string_literal: true

module Teems
  module Api
    # Changes to Microsoft Graph mail messages. Nothing here sends mail: a message's read state
    # and flag can change, and it can move between folders (deleting is a move to Deleted Items,
    # where Outlook still shows it).
    class MailActions < Client
      include MailPaths

      # Sets message properties, e.g. { isRead: true } or { flag: { flagStatus: 'flagged' } }
      def update(message_id, changes)
        patch(message_path(message_id), body: changes, headers: prefer_header)
      end

      # Moves a message to a folder ID or well-known name ('archive', 'deleteditems')
      def move(message_id, destination)
        post("#{message_path(message_id)}/move", body: { destinationId: destination }, headers: prefer_header)
      end
    end
  end
end
