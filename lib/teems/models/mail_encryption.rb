# frozen_string_literal: true

module Teems
  module Models
    # How protected mail was shown, as { type: 'smime' | 'purview', decrypted:, signed: } (signed
    # only once decrypted), and the header lines `read` and `thread --full` print for it. Purview
    # mail gets its Outlook on the web link, where Exchange decrypts it for you.
    module MailEncryption
      LOCKED_HINT = 'S/MIME encrypted; read it with --decrypt (macOS asks for your PIV PIN)'

      # 'purview' (rights-managed, Content-Class rpmsg.message), 'smime' (an S/MIME envelope),
      # or nil, from a message's internet headers. Drafts have none, and Exchange wraps most
      # S/MIME mail as TNEF (see envelope?), so nil is not proof of plain mail.
      def self.from_headers(headers)
        fields = Array(headers).to_h { |header| [header['name'].to_s.downcase, header['value'].to_s.downcase] }
        return 'purview' if fields['content-class'].to_s.start_with?('rpmsg.message')

        type, params = Support::MimeHeader.field(fields['content-type'])
        'smime' if Support::MimePart::PKCS7_TYPES.include?(type) && params['smime-type'] != 'signed-data'
      end

      def self.notes(encryption, web_link: nil)
        return {} unless encryption

        type = encryption[:type]
        return { 'Encryption' => MailMessage::PROTECTION_NOTES[type], 'Open' => web_link }.compact if type == 'purview'
        return { 'Encryption' => LOCKED_HINT } unless encryption[:decrypted]

        { 'Encryption' => 'S/MIME, decrypted', 'Signature' => encryption[:signed] ? 'Signed (not checked)' : '' }
          .reject { |_name, value| value.empty? }
      end

      def self.decrypted(content) = { type: 'smime', decrypted: true, signed: content.signed }

      # An S/MIME envelope (smime.p7m) among a message's Graph attachments
      def self.envelope?(attachment)
        Support::MimePart::PKCS7_TYPES.include?(Support::MimeHeader.field(attachment['contentType']).first)
      end
    end
  end
end
