# frozen_string_literal: true

module Teems
  module Commands
    # Protected mail for `teems mail read`. Graph hands S/MIME encrypted mail over with an empty
    # body and its envelope as an smime.p7m attachment; --decrypt opens it with the PIV card
    # (macOS asks for the PIN) and shows it like any other message. Purview (rights-managed)
    # mail needs Microsoft's service, so it is only labelled.
    module MailDecrypting
      ENVELOPE_TYPES = Support::MimePart::PKCS7_TYPES
      LOCKED_HINT = 'S/MIME encrypted; read it with --decrypt (macOS asks for your PIV PIN)'

      private

      def envelope_attachment(message_id)
        mail_api.attachments(message_id).find do |item|
          ENVELOPE_TYPES.include?(Support::MimeHeader.field(item['contentType']).first)
        end
      end

      def show_purview(message)
        warn('--decrypt opens S/MIME mail only; Purview protected mail needs Outlook') if @options[:decrypt]
        warn(message.protection_note) if @options[:html]
        render_message(message, message.attachment_names_from(mail_api), { type: 'purview', decrypted: false })
      end

      def show_encrypted(message, envelope)
        return show_locked(message) unless @options[:decrypt]

        content = Services::SmimeContent.parse(runner.smime_decryptor.decrypt(envelope_bytes(message, envelope)))
        decrypted = message.with(body: Models::MailMessage.clean(content.body), body_type: content.body_type)
        names = content.attachments.map { |name| Models::MailMessage.clean(name) }
        render_message(decrypted, names, { type: 'smime', decrypted: true, signed: content.signed })
      end

      def show_locked(message)
        warn(LOCKED_HINT) if @options[:html] # no header block to carry the hint
        render_message(message, [], { type: 'smime', decrypted: false })
      end

      def envelope_bytes(message, envelope)
        mail_api.attachment(message.id, envelope['id'])['contentBytes'].to_s.unpack1('m')
      end

      # Header lines describing how an encrypted message was shown
      def encryption_notes(encryption)
        return {} unless encryption

        type = encryption[:type]
        return { 'Encryption' => Models::MailMessage::PROTECTION_NOTES[type] } if type == 'purview'
        return { 'Encryption' => LOCKED_HINT } unless encryption[:decrypted]

        { 'Encryption' => 'S/MIME, decrypted', 'Signature' => encryption[:signed] ? 'Signed (not checked)' : '' }
          .reject { |_name, value| value.empty? }
      end
    end
  end
end
