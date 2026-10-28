# frozen_string_literal: true

module Teems
  module Commands
    # `teems mail thread <id>`: every message in a message's conversation, from any folder,
    # oldest first. --full prints each one as `read` would, and --decrypt opens the S/MIME
    # ones with the PIV card on the way (see MailDecrypting).
    module MailThread
      DIVIDER = '-' * 72

      private

      def show_thread
        messages = thread_messages(resolve_message_id(thread_token))
        id_cache.remember(messages)
        conversation = Models::MailConversation.new(messages: messages, folders: mail_folders.paths_by_id)
        @options[:full] ? show_full_thread(conversation) : show_thread_list(conversation)
      end

      def thread_token
        token = positional_args[1] or raise Error, 'Usage: teems mail thread <id> [--full [--decrypt]]'
        raise Error, '--decrypt works with --full' if @options[:decrypt] && !@options[:full]

        token
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
        full = full_conversation(conversation)
        return json_result(full.full_json) if @options[:json]

        print_lines([full.texts.join("\n\n#{output.gray(DIVIDER)}\n\n")])
      end

      # With attachment names, and encrypted messages marked (or opened, with --decrypt)
      def full_conversation(conversation)
        envelopes = envelopes_in(conversation.messages)
        full = conversation.with_attachment_names(mail_api).with_locked(envelopes.keys)
        @options[:decrypt] ? full.with_decrypted(open_envelopes(envelopes)) : full
      end

      # Message ID => S/MIME envelope (an smime.p7m attachment) for each encrypted message, found
      # as `read` finds it: Graph hands encrypted mail over with no body
      def envelopes_in(messages)
        messages.select(&:envelope_candidate?).each_with_object({}) do |message, found|
          id = message.id
          envelope = envelope_attachment(id)
          found[id] = envelope if envelope
        end
      end

      # Message ID => decrypted content for each envelope that opens. One that will not (no
      # matching key) stays locked with a warning, and the rest carry on.
      def open_envelopes(envelopes)
        warn('No S/MIME encrypted messages in this thread') if envelopes.empty?
        envelopes.each_with_object({}) do |(id, envelope), opened|
          content = open_envelope(id, envelope)
          opened[id] = content if content
        end
      end

      def open_envelope(message_id, envelope)
        decrypt_content(message_id, envelope)
      rescue ApiError
        raise
      rescue Error => e
        warn("#{Models::MailMessage.short_id(message_id)}: #{e.message}")
        nil
      end
    end
  end
end
