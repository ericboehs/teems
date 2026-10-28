# frozen_string_literal: true

module Teems
  module Models
    # A conversation's messages (oldest first), Graph folder ID => path for naming the folder
    # each one sits in (a thread spans the Inbox, Sent Items, Archive and so on), message ID =>
    # attachment names once with_attachment_names has fetched them, and message ID => how a
    # decrypted message was opened (see MailEncryption)
    MailConversation = Data.define(:messages, :folders, :attachments, :encryptions) do
      def initialize(messages:, folders:, attachments: {}, encryptions: {}) = super

      def folder(message) = folders[message.folder_id]

      def with_attachment_names(api)
        with(attachments: messages.to_h { |message| [message.id, message.attachment_names_from(api)] })
      end

      # Marks these messages S/MIME encrypted and not opened; the envelope is not listed as a file
      def with_locked(message_ids)
        no_files = message_ids.to_h { |id| [id, []] }
        locked = no_files.transform_values { { type: 'smime', decrypted: false } }
        with(encryptions: encryptions.merge(locked), attachments: attachments.merge(no_files))
      end

      # opened: message ID => Services::SmimeContent::Result for each message decrypted
      def with_decrypted(opened)
        with(messages: messages.map { |message| opened[message.id]&.apply_to(message) || message },
             attachments: attachments.merge(opened.transform_values(&:attachment_names)),
             encryptions: encryptions.merge(opened.transform_values { |content| MailEncryption.decrypted(content) }))
      end

      # Each message's JSON (from the block) with its folder path
      def json = messages.map { |message| yield(message).merge(folder: folder(message)) }

      # As `read --json` gives each message, plus its folder
      def full_json
        json do |message|
          encryption = encryption(message)
          hash = message.full_json_hash(attachments: names(message))
          encryption ? hash.merge(encryption: encryption) : hash
        end
      end

      # As `read` prints each message, with its folder (and how it was protected) before the ID
      def texts = messages.map { |message| message.to_text(attachments: names(message), notes: notes(message)) }

      # list's tab-separated columns plus the folder path
      def tsv_rows = messages.map { |message| "#{message.tsv_row}\t#{folder(message).to_s.tr("\t", ' ')}" }

      private

      def names(message) = attachments.fetch(message.id, [])

      def encryption(message) = message.encryption_in(encryptions)

      def notes(message)
        protection = MailEncryption.notes(encryption(message), web_link: message.web_link)
        { 'Folder' => folder(message) }.compact.merge(protection)
      end
    end
  end
end
