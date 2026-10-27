# frozen_string_literal: true

require 'test_helper'
require 'smime_fixtures'

# MIME fixtures are heredocs, which make the scenarios long
# rubocop:disable Metrics/MethodLength
class SmimeContentTest < Minitest::Test
  include SmimeFixtures

  def parse(mime) = Teems::Services::SmimeContent.parse(mime)

  def test_html_preferred_over_plain
    result = parse(alternative_mime)

    assert_equal 'html', result.body_type
    assert_includes result.body, 'Top <a href'
    assert_empty result.attachments
    refute result.signed
  end

  def test_plain_only_with_attachments
    result = parse(crlf(<<~MIME))
      Content-Type: multipart/mixed; boundary=m

      --m
      Content-Type: text/plain

      Just text
      --m
      Content-Type: application/pdf
      Content-Disposition: attachment; filename="a.pdf"

      PDF
      --m--
    MIME

    assert_equal 'text', result.body_type
    assert_equal 'Just text', result.body
    assert_equal ['a.pdf'], result.attachments
  end

  def test_detached_signature_is_unwrapped
    result = parse(crlf(<<~MIME))
      Content-Type: multipart/signed; protocol="application/pkcs7-signature"; boundary=s

      --s
      Content-Type: text/plain

      Signed text
      --s
      Content-Type: application/pkcs7-signature; name=smime.p7s

      SIG
      --s--
    MIME

    assert_equal 'Signed text', result.body
    assert result.signed
    assert_empty result.attachments
  end

  def test_opaque_signature_is_unwrapped
    signed = [smime_signed(alternative_mime)].pack('m')
    result = parse(crlf("Content-Type: application/pkcs7-mime; smime-type=signed-data\n" \
                        "Content-Transfer-Encoding: base64\n\n") + signed)

    assert result.signed
    assert_equal 'html', result.body_type
  end

  def test_no_body
    result = parse(crlf("Content-Type: application/pdf\nContent-Disposition: attachment; filename=x.pdf\n\nPDF"))

    assert_equal '', result.body
    assert_equal 'text', result.body_type
    assert_equal ['x.pdf'], result.attachments
  end
end
# rubocop:enable Metrics/MethodLength
