# frozen_string_literal: true

require 'openssl'

module Teems
  module Support
    # The content inside an opaque S/MIME signature (PKCS #7 signed-data). The signature is not
    # checked: this only unwraps it so the message can be read.
    module SignedData
      module_function

      def content(der)
        envelope = OpenSSL::PKCS7.new(der)
        raise Error, 'This message is encrypted again inside; teems opens one layer' unless envelope.type == :signed

        envelope.verify([], OpenSSL::X509::Store.new, nil, OpenSSL::PKCS7::NOVERIFY | OpenSSL::PKCS7::NOSIGS)
        envelope.data.to_s
      rescue OpenSSL::PKCS7::PKCS7Error, ArgumentError => e
        raise Error, "Could not read the signed content: #{e.message}"
      end
    end
  end
end
