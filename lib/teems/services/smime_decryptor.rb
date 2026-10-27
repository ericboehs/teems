# frozen_string_literal: true

module Teems
  module Services
    # Decrypts an S/MIME envelope with macOS's `security cms -D`, which finds the matching
    # private key among keychain identities, PIV card keys (current and retired key management
    # keys) included, and shows the system PIN dialog when the card needs it. The ciphertext
    # goes in on stdin and the plaintext comes back on stdout, so neither touches the disk.
    class SmimeDecryptor
      # SEC_ERROR_NOT_A_RECIPIENT: no key here matches any recipient of the message
      NOT_A_RECIPIENT = '-8147'
      COMMAND = %w[security cms -D].freeze

      def decrypt(envelope)
        plain, errors, status = Support::Subprocess.capture3(*COMMAND, stdin_data: envelope, binmode: true)
        return plain if status.success?

        raise Error, failure(errors)
      rescue Errno::ENOENT
        raise Error, 'Decrypting needs the macOS security command'
      end

      private

      def failure(errors)
        if errors.include?(NOT_A_RECIPIENT)
          return 'None of your keys can open this message: it was encrypted for other certificates. ' \
                 'Is your PIV card inserted?'
        end

        detail = errors.lines.map(&:strip).reject(&:empty?).first
        "Could not decrypt the message#{": #{detail.delete_prefix('security: ')}" if detail}"
      end
    end
  end
end
