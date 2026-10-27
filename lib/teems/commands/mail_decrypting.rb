# frozen_string_literal: true

module Teems
  module Commands
    # S/MIME encrypted mail for `teems mail read`. Graph hands such a message over with an empty
    # body and its envelope as an smime.p7m attachment; --decrypt opens it with the PIV card
    # (macOS asks for the PIN) and shows it like any other message.
    module MailDecrypting
      ENVELOPE_TYPES = Support::MimePart::PKCS7_TYPES
      LOCKED_HINT = 'S/MIME encrypted; read it with --decrypt (macOS asks for your PIV PIN)'

      private

      def envelope_attachment(message_id)
        mail_api.attachments(message_id).find { |item| ENVELOPE_TYPES.include?(item['contentType'].to_s.downcase) }
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
        return { 'Encryption' => LOCKED_HINT } unless encryption[:decrypted]

        { 'Encryption' => 'S/MIME, decrypted', 'Signature' => encryption[:signed] ? 'Signed (not checked)' : '' }
          .reject { |_name, value| value.empty? }
      end
    end
  end
end
