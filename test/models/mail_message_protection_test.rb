# frozen_string_literal: true

require 'test_helper'

# Protected mail (Purview, S/MIME) as told by the internet headers, and read's header block
class MailMessageProtectionTest < Minitest::Test
  def mail_message(**overrides) = Teems::Models::MailMessage.from_api(sample_mail_message(**overrides))

  def headers(*pairs) = pairs.map { |name, value| { 'name' => name, 'value' => value } }

  def test_protection_from_internet_headers
    purview = mail_message('internetMessageHeaders' => headers(%w[Content-Type multipart/mixed],
                                                               %w[Content-Class rpmsg.message]))
    smime = mail_message('internetMessageHeaders' => headers(['content-type',
                                                              'Application/PKCS7-MIME; smime-type=enveloped-data']))

    assert_equal 'purview', purview.protection
    assert_equal 'Protected by Purview; open in Outlook', purview.protection_note
    assert_equal 'smime', smime.protection
    assert_includes smime.protection_note, 'teems mail read --decrypt'
  end

  def test_no_protection
    signed = headers(['Content-Type', 'application/pkcs7-mime; smime-type=signed-data'])

    assert_nil mail_message('internetMessageHeaders' => signed).protection
    assert_nil mail_message('internetMessageHeaders' => headers(%w[Content-Class
                                                                   urn:content-classes:message])).protection
    assert_nil mail_message.protection
    assert_nil mail_message.protection_note
  end

  def test_categories_line_only_when_present
    refute_includes mail_message('categories' => []).to_text, 'Categories:'
    assert_includes mail_message.to_text, "Categories: Work\n"
  end
end
