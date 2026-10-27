# frozen_string_literal: true

require 'test_helper'
require 'smime_fixtures'

# `teems mail read` on S/MIME encrypted mail: Graph returns an empty body plus an smime.p7m
# attachment; --decrypt opens it (here with a test key standing in for the PIV card).
# rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/ClassLength
class MailDecryptTest < Minitest::Test
  include SmimeFixtures

  ENVELOPE_ID = 'ATT-SMIME'

  def setup
    @saved_tz = ENV.fetch('TZ', nil)
    ENV['TZ'] = 'America/Chicago'
    @decryptor = FakeDecryptor.new
  end

  def teardown
    ENV['TZ'] = @saved_tz
  end

  def run_mail(args, stubs:, decryptor: @decryptor)
    capture = capture_output do |output|
      runner = configured_runner(output: output)
      runner.define_singleton_method(:smime_decryptor) { decryptor }
      stubs.each { |path, response| runner.api_client.stub(path, response) }
      @calls = runner.api_client.calls
      @code = Teems::Commands::Mail.new(args, runner: runner).execute
    end
    capture.merge(code: @code, calls: @calls)
  end

  def encrypted_stubs(mime = alternative_mime, content_type: 'application/pkcs7-mime')
    envelope = { 'id' => ENVELOPE_ID, 'name' => 'smime.p7m', 'contentType' => content_type }
    { "/attachments/#{ENVELOPE_ID}" => envelope.merge('contentBytes' => [smime_envelope(mime)].pack('m0')),
      '/attachments' => { 'value' => [envelope] },
      '/v1.0/me/messages/' => sample_mail_message('body' => { 'contentType' => 'text', 'content' => '' }) }
  end

  def test_encrypted_message_without_decrypt_points_at_the_flag
    with_temp_config do
      result = run_mail(['read', MAIL_ID], stubs: encrypted_stubs)

      assert_equal 0, result[:code]
      assert_empty result[:stderr]
      assert_includes result[:stdout],
                      "Encryption: S/MIME encrypted; read it with --decrypt (macOS asks for your PIV PIN)\nID: "
      refute_includes result[:stdout], 'Top secret'
      assert_empty @decryptor.envelopes
      refute(result[:calls].any? { |call| call[:path].end_with?(ENVELOPE_ID) })
    end
  end

  def test_encrypted_message_html_without_decrypt_warns
    with_temp_config do
      result = run_mail(['read', MAIL_ID, '--html'], stubs: encrypted_stubs)

      assert_includes result[:stderr], 'S/MIME encrypted; read it with --decrypt'
      assert_equal "\n", result[:stdout]
    end
  end

  def test_encrypted_message_json_without_decrypt
    with_temp_config do
      result = run_mail(['read', MAIL_ID, '--json'], stubs: encrypted_stubs)
      json = JSON.parse(result[:stdout])

      assert_equal({ 'type' => 'smime', 'decrypted' => false }, json['encryption'])
      assert_empty result[:stderr]
    end
  end

  def test_decrypt_shows_the_html_body_as_text_with_links
    with_temp_config do
      result = run_mail(['read', MAIL_ID, '--decrypt'], stubs: encrypted_stubs)

      assert_equal 0, result[:code]
      assert_includes result[:stdout], "Encryption: S/MIME, decrypted\nID: "
      assert_includes result[:stdout], 'Top secret [1]'
      assert_includes result[:stdout], '[1] secret <https://example.com/s>'
      refute_includes result[:stdout], 'Signature:'
      assert_equal 1, @decryptor.envelopes.size
    end
  end

  def test_decrypt_signed_message_with_attachments_as_json
    signed = [smime_signed(crlf(<<~MIME))].pack('m')
      Content-Type: multipart/mixed; boundary=m

      --m
      Content-Type: text/plain

      Signed secret \e[31mred
      --m
      Content-Type: application/pdf
      Content-Disposition: attachment; filename="plan.pdf"

      PDF
      --m--
    MIME
    mime = crlf("Content-Type: application/pkcs7-mime; smime-type=signed-data\n" \
                "Content-Transfer-Encoding: base64\n\n") + signed

    with_temp_config do
      text = run_mail(['read', MAIL_ID, '--decrypt'], stubs: encrypted_stubs(mime))[:stdout]

      assert_includes text, "Attachments: plan.pdf\n"
      assert_includes text, "Signature: Signed (not checked)\n"
      refute_includes text, "\e[31m"
      json = JSON.parse(run_mail(['read', MAIL_ID, '--decrypt', '--json'], stubs: encrypted_stubs(mime))[:stdout])

      assert_equal({ 'type' => 'smime', 'decrypted' => true, 'signed' => true }, json['encryption'])
      assert_equal 'Signed secret [31mred', json['body'], 'ESC is stripped, as for any sender text'
      assert_equal ['plan.pdf'], json['attachments']
    end
  end

  def test_envelope_type_with_parameters_is_recognized
    with_temp_config do
      stubs = encrypted_stubs(content_type: 'Application/PKCS7-MIME; smime-type=enveloped-data; name=smime.p7m')
      result = run_mail(['read', MAIL_ID, '--decrypt'], stubs: stubs)

      assert_includes result[:stdout], 'Top secret [1]'
    end
  end

  def test_decrypt_html_prints_the_decrypted_html
    with_temp_config do
      result = run_mail(['read', MAIL_ID, '--decrypt', '--html'], stubs: encrypted_stubs)

      assert_includes result[:stdout], '<p>Top <a href="https://example.com/s">secret</a></p>'
    end
  end

  def test_decrypt_on_plain_mail_shows_it_as_usual
    with_temp_config do
      result = run_mail(['read', MAIL_ID, '--decrypt'], stubs: { '/v1.0/me/messages/' => sample_mail_message })

      assert_equal 0, result[:code]
      assert_includes result[:stderr], 'Not S/MIME encrypted; nothing to decrypt'
      assert_includes result[:stdout], 'Hello the report [1]'
      assert_equal 1, result[:calls].size
    end
  end

  def test_empty_message_without_envelope_is_not_treated_as_encrypted
    with_temp_config do
      pdf = { 'id' => 'a', 'name' => 'a.pdf', 'contentType' => 'application/pdf' }
      stubs = { '/attachments' => { 'value' => [pdf] },
                '/v1.0/me/messages/' => sample_mail_message('body' => { 'contentType' => 'text', 'content' => ' ' }) }
      result = run_mail(['read', MAIL_ID], stubs: stubs)

      assert_equal 0, result[:code]
      refute_includes result[:stdout], 'Encryption:'
      assert_empty result[:stderr]
    end
  end

  def purview_stubs(has_attachments: false)
    message = sample_mail_message('hasAttachments' => has_attachments, 'internetMessageHeaders' => purview_headers,
                                  'body' => { 'contentType' => 'text', 'content' => 'Open this in Outlook.' })
    rpmsg = { 'id' => 'r', 'name' => 'message_v2.rpmsg', 'contentType' => 'application/x-microsoft-rpmsg-message' }
    { '/attachments' => { 'value' => [rpmsg] }, '/v1.0/me/messages/' => message }
  end

  def test_purview_mail_is_labelled
    with_temp_config do
      result = run_mail(['read', MAIL_ID], stubs: purview_stubs)

      assert_equal 0, result[:code]
      assert_includes result[:stdout], "Encryption: Protected by Purview; open in Outlook on the web\n" \
                                       "Open: https://outlook.office365.com/owa/?ItemID=1\nID: "
      assert_includes result[:stdout], 'Open this in Outlook.'
      assert_equal 1, result[:calls].size, 'no attachment lookup when Graph says there are none'
      assert_empty result[:stderr]
    end
  end

  def test_purview_mail_json_html_and_decrypt
    with_temp_config do
      json = JSON.parse(run_mail(['read', MAIL_ID, '--json'], stubs: purview_stubs(has_attachments: true))[:stdout])

      assert_equal({ 'type' => 'purview', 'decrypted' => false }, json['encryption'])
      assert_equal ['message_v2.rpmsg'], json['attachments']
      html = run_mail(['read', MAIL_ID, '--html'], stubs: purview_stubs)

      assert_includes html[:stderr], 'Protected by Purview; open in Outlook on the web: https://outlook.office365.com/owa/?ItemID=1'
      assert_equal "Open this in Outlook.\n", html[:stdout]
      decrypt = run_mail(['read', MAIL_ID, '--decrypt'], stubs: purview_stubs)

      assert_includes decrypt[:stderr], '--decrypt opens S/MIME mail only'
      assert_empty @decryptor.envelopes
    end
  end

  def test_decryption_failure_is_an_error
    failing = Object.new
    def failing.decrypt(_envelope) = raise(Teems::Error, 'None of your keys can open this message')

    with_temp_config do
      result = run_mail(['read', MAIL_ID, '--decrypt'], stubs: encrypted_stubs, decryptor: failing)

      assert_equal 1, result[:code]
      assert_includes result[:stderr], 'None of your keys can open this message'
    end
  end

  MAIL_ID = Teems::SampleData::MAIL_ID
end
# rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Metrics/ClassLength
