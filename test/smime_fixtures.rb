# frozen_string_literal: true

require 'openssl'

# A throwaway S/MIME identity (RSA key + self-signed certificate) for building encrypted
# and signed messages in tests. Generated once per test run.
module SmimeFixtures
  Identity = Struct.new(:key, :cert)

  def self.identity
    @identity ||= begin
      key = OpenSSL::PKey::RSA.new(2048)
      Identity.new(key, self_signed(key))
    end
  end

  def self.self_signed(key)
    cert = unsigned_cert(key.public_key)
    cert.sign(key, OpenSSL::Digest.new('SHA256'))
    cert
  end

  def self.unsigned_cert(public_key)
    now = Time.now
    OpenSSL::X509::Certificate.new.tap do |cert|
      cert.version = 2
      cert.serial = 1
      cert.subject = cert.issuer = OpenSSL::X509::Name.parse('/CN=Teems Test')
      cert.public_key = public_key
      cert.not_before = now - 60
      cert.not_after = now + 3600
    end
  end

  # CMS enveloped-data (DER) for mime, encrypted to the test identity
  def smime_envelope(mime)
    cert = SmimeFixtures.identity.cert
    OpenSSL::PKCS7.encrypt([cert], mime, OpenSSL::Cipher.new('aes-256-cbc'), OpenSSL::PKCS7::BINARY).to_der
  end

  # Opaque PKCS #7 signed-data (DER) wrapping content
  def smime_signed(content)
    identity = SmimeFixtures.identity
    OpenSSL::PKCS7.sign(identity.cert, identity.key, content, [], OpenSSL::PKCS7::BINARY).to_der
  end

  # Opens an envelope with the test key, standing in for `security cms -D` and the PIV card
  class FakeDecryptor
    attr_reader :envelopes

    def initialize = @envelopes = []

    def decrypt(envelope)
      @envelopes << envelope
      identity = SmimeFixtures.identity
      OpenSSL::PKCS7.new(envelope).decrypt(identity.key, identity.cert)
    end
  end

  def crlf(text) = text.gsub("\n", "\r\n")

  def alternative_mime
    crlf(<<~MIME)
      Content-Type: multipart/alternative; boundary="alt"

      --alt
      Content-Type: text/plain; charset=utf-8

      Plain secret
      --alt
      Content-Type: text/html; charset=utf-8

      <p>Top <a href="https://example.com/s">secret</a></p>
      --alt--
    MIME
  end
end
