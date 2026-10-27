# frozen_string_literal: true

require 'test_helper'

# MIME fixtures are heredocs, which make the scenarios long
# rubocop:disable Metrics/MethodLength, Metrics/AbcSize
class MimePartTest < Minitest::Test
  Part = Teems::Support::MimePart
  Header = Teems::Support::MimeHeader

  def parse(text) = Part.parse(text.gsub("\n", "\r\n"))

  def test_headers_are_unfolded_lowercased_and_first_wins
    part = parse("Subject: one\n two\nX-A: 1\nX-A: 2\nno colon line\n\nbody")

    assert_equal 'one two', part.headers['subject']
    assert_equal '1', part.headers['x-a']
    assert_equal 'body', part.body
    assert_equal 'text/plain', part.content_type
  end

  def test_entity_without_headers
    part = Part.parse("\r\nhello")

    assert_empty part.headers
    assert_equal 'hello', part.body
    assert_equal '', Part.parse('X-Only: yes').body
  end

  def test_field_parameters
    value, params = Header.field('Text/HTML; Charset="utf-8"; name="a \\"b\\"; c"; bare=x')

    assert_equal 'text/html', value
    assert_equal({ 'charset' => 'utf-8', 'name' => 'a "b"; c', 'bare' => 'x' }, params)
    assert_equal ['', {}], Header.field(nil)
  end

  def test_decoded_parameters
    assert_equal 'résumé.pdf', Header.decoded({ 'filename*' => "utf-8''r%C3%A9sum%C3%A9.pdf" }, 'filename')
    assert_equal 'plain%20name', Header.decoded({ 'filename*' => 'plain%20name' }, 'filename')
    assert_equal 'Grüße.txt', Header.decoded({ 'name' => '=?UTF-8?B?R3LDvMOfZS50eHQ=?=' }, 'name')
    assert_equal 'a b=c.txt', Header.decoded({ 'name' => '=?iso-8859-1?q?a_b=3Dc.txt?=' }, 'name')
    assert_nil Header.decoded({}, 'name')
  end

  def test_transcode_charsets
    assert_equal 'café', Header.transcode("caf\xE9".b, 'ISO-8859-1')
    assert_equal 'ok?', Header.transcode("ok\xFF".b, nil)
    assert_equal 'x?', Header.transcode("x\xFF".b, 'no-such-charset')
  end

  def test_transfer_encodings
    base64 = parse("Content-Transfer-Encoding: base64\nContent-Type: text/plain; charset=utf-8\n\nw6ljbGFpcg==\n")
    qp = parse("Content-Transfer-Encoding: Quoted-Printable\n\nsoft=\nbreak =C3=A9\n")

    assert_equal 'éclair', base64.text
    assert_equal "softbreak é\n", qp.text
    assert_equal 'raw', parse("Content-Transfer-Encoding: 7bit\n\nraw").decoded
  end

  def test_multipart_parts_and_leaves
    part = parse(<<~MIME)
      Content-Type: multipart/mixed; boundary=outer

      preamble
      --outer
      Content-Type: multipart/alternative; boundary="inner"

      --inner
      Content-Type: text/plain

      plain
      --inner--
      --outer
      Content-Type: application/pdf; name="r.pdf"
      Content-Disposition: attachment; filename="report.pdf"

      PDF
      --outer--
      epilogue
    MIME

    assert part.multipart?
    assert_equal %w[multipart/alternative application/pdf], part.parts.map(&:content_type)
    assert_equal %w[text/plain application/pdf], part.leaves.map(&:content_type)
    assert_equal 'plain', part.leaves.first.body
    assert_equal 'report.pdf', part.leaves.last.filename
  end

  def test_multipart_without_boundary_has_no_parts
    assert_empty parse("Content-Type: multipart/mixed\n\nbody").parts
    assert_empty parse("Content-Type: text/plain; boundary=x\n\n--x\n\nhi").parts
  end

  def test_attachment_rules
    assert_predicate parse("Content-Disposition: attachment\n\nx"), :attachment?
    assert_predicate parse("Content-Type: image/png; name=a.png\n\nx"), :attachment?
    refute_predicate parse("Content-Type: image/png; name=a.png\nContent-ID: <a>\n\nx"), :attachment?
    refute_predicate parse("Content-Type: image/png; name=a.png\nContent-Disposition: inline\n\nx"), :attachment?
    refute_predicate parse("Content-Type: text/plain; name=a.txt\n\nx"), :attachment?
    refute_predicate parse("Content-Type: image/png\n\nx"), :attachment?
  end

  def test_unsigned_plain_part
    part = parse("Content-Type: text/plain\n\nhi")

    assert_equal [part, false], part.unsigned
    assert_nil parse("Content-Type: multipart/signed; boundary=s\n\nnone").signed_content
  end
end
# rubocop:enable Metrics/MethodLength, Metrics/AbcSize
