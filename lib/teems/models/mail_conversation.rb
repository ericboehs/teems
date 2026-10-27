# frozen_string_literal: true

module Teems
  module Models
    # A conversation's messages (oldest first), Graph folder ID => path for naming the folder
    # each one sits in (a thread spans the Inbox, Sent Items, Archive and so on), and message
    # ID => attachment names once with_attachment_names has fetched them
    MailConversation = Data.define(:messages, :folders, :attachments) do
      def initialize(messages:, folders:, attachments: {}) = super

      def folder(message) = folders[message.folder_id]

      def with_attachment_names(api)
        with(attachments: messages.to_h { |message| [message.id, message.attachment_names_from(api)] })
      end

      # Each message's JSON (from the block) with its folder path
      def json = messages.map { |message| yield(message).merge(folder: folder(message)) }

      # As `read --json` gives each message, plus its folder
      def full_json
        json { |message| message.full_json_hash(attachments: names(message)).merge(message.encryption_field) }
      end

      # As `read` prints each message, with its folder (and how to open protected mail) before the ID
      def texts = messages.map { |message| message.to_text(attachments: names(message), notes: notes(message)) }

      # list's tab-separated columns plus the folder path
      def tsv_rows = messages.map { |message| "#{message.tsv_row}\t#{folder(message).to_s.tr("\t", ' ')}" }

      private

      def names(message) = attachments.fetch(message.id, [])

      def notes(message) = { 'Folder' => folder(message), 'Encryption' => message.protection_note }.compact
    end
  end
end
