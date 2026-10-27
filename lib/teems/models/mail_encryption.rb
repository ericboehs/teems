# frozen_string_literal: true

module Teems
  module Models
    # How protected mail was shown, as { type: 'smime' | 'purview', decrypted:, signed: } (signed
    # only once decrypted), and the header lines `read` and `thread --full` print for it. Purview
    # mail gets its Outlook on the web link, where Exchange decrypts it for you.
    module MailEncryption
      LOCKED_HINT = 'S/MIME encrypted; read it with --decrypt (macOS asks for your PIV PIN)'

      def self.notes(encryption, web_link: nil)
        return {} unless encryption

        type = encryption[:type]
        return { 'Encryption' => MailMessage::PROTECTION_NOTES[type], 'Open' => web_link }.compact if type == 'purview'
        return { 'Encryption' => LOCKED_HINT } unless encryption[:decrypted]

        { 'Encryption' => 'S/MIME, decrypted', 'Signature' => encryption[:signed] ? 'Signed (not checked)' : '' }
          .reject { |_name, value| value.empty? }
      end

      def self.decrypted(content) = { type: 'smime', decrypted: true, signed: content.signed }
    end
  end
end
