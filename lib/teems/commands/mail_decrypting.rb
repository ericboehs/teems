# frozen_string_literal: true

module Teems
  module Commands
    # Protected mail for `teems mail read`. Graph hands S/MIME encrypted mail over with an empty
    # body and its envelope as an smime.p7m attachment; --decrypt opens it with the PIV card
    # (macOS asks for the PIN) and shows it like any other message. Purview (rights-managed)
    # mail needs Microsoft's service, so it is only labelled.
    module MailDecrypting
      ENVELOPE_TYPES = Support::MimePart::PKCS7_TYPES
      LOCKED_HINT = Models::MailEncryption::LOCKED_HINT

      private

      def envelope_attachment(message_id)
        mail_api.attachments(message_id).find do |item|
          ENVELOPE_TYPES.include?(Support::MimeHeader.field(item['contentType']).first)
        end
      end

      def show_purview(message)
        warn('--decrypt opens S/MIME mail only; Purview protected mail needs Outlook') if @options[:decrypt]
        warn([message.protection_note, message.web_link].compact.join(': ')) if @options[:html]
        render_message(message, message.attachment_names_from(mail_api), { type: 'purview', decrypted: false })
      end

      def show_encrypted(message, envelope)
        return show_locked(message) unless @options[:decrypt]

        content = decrypt_content(message.id, envelope)
        render_message(content.apply_to(message), content.attachment_names, Models::MailEncryption.decrypted(content))
      end

      # The message inside an envelope (an smime.p7m attachment), opened with the PIV card
      def decrypt_content(message_id, envelope)
        Services::SmimeContent.parse(runner.smime_decryptor.decrypt(envelope_bytes(message_id, envelope['id'])))
      end

      def show_locked(message)
        warn(LOCKED_HINT) if @options[:html] # no header block to carry the hint
        render_message(message, [], { type: 'smime', decrypted: false })
      end

      def envelope_bytes(message_id, attachment_id)
        mail_api.attachment(message_id, attachment_id)['contentBytes'].to_s.unpack1('m')
      end
    end
  end
end
