# frozen_string_literal: true

module Teems
  module Commands
    # `teems mail thread <id>`: every message in a message's conversation, from any folder,
    # oldest first. --full prints each one as `read` would.
    module MailThread
      DIVIDER = '-' * 72

      private

      def show_thread
        token = positional_args[1]
        return error('Usage: teems mail thread <id> [--full]') unless token

        messages = thread_messages(resolve_message_id(token))
        id_cache.remember(messages)
        conversation = Models::MailConversation.new(messages: messages, folders: mail_folders.paths_by_id)
        @options[:full] ? show_full_thread(conversation) : show_thread_list(conversation)
      end

      def thread_messages(message_id)
        fields = @options[:full] ? Api::Mail::MESSAGE_FIELDS : Api::Mail::LIST_FIELDS
        mail_api.conversation(conversation_of(message_id), fields: fields)
      end

      def conversation_of(message_id)
        mail_api.conversation_id(message_id) or raise Error, 'That message belongs to no conversation'
      end

      def show_thread_list(conversation)
        return json_result(conversation.json(&:to_json_hash)) if @options[:json]
        return print_lines(conversation.tsv_rows) if @options[:tsv]

        print_lines(mail_formatter.thread_rows(conversation))
      end

      def show_full_thread(conversation)
        full = conversation.with_attachment_names(mail_api)
        return json_result(full.full_json) if @options[:json]

        print_lines([full.texts.join("\n\n#{output.gray(DIVIDER)}\n\n")])
      end
    end
  end
end
