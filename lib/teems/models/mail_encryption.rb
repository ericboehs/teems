# frozen_string_literal: true

module Teems
  module Models
    # How protected mail was shown, as { type: 'smime' | 'purview', decrypted:, signed: } (signed
    # only once decrypted), and the header lines `read` and `thread --full` print for it
    module MailEncryption
      LOCKED_HINT = 'S/MIME encrypted; read it with --decrypt (macOS asks for your PIV PIN)'

      def self.notes(encryption)
        return {} unless encryption

        type = encryption[:type]
        return { 'Encryption' => MailMessage::PROTECTION_NOTES[type] } if type == 'purview'
        return { 'Encryption' => LOCKED_HINT } unless encryption[:decrypted]

        { 'Encryption' => 'S/MIME, decrypted', 'Signature' => encryption[:signed] ? 'Signed (not checked)' : '' }
          .reject { |_name, value| value.empty? }
      end

      def self.decrypted(content) = { type: 'smime', decrypted: true, signed: content.signed }
    end
  end
end
