# frozen_string_literal: true

require 'test_helper'

class MailMessageTest < Minitest::Test
  def mail_message(**overrides) = Teems::Models::MailMessage.from_api(sample_mail_message(**overrides))

  def test_sender_text_carries_no_terminal_controls
    msg = mail_message('subject' => "Hi\e]0;owned\a",
                       'from' => { 'emailAddress' => { 'name' => "\e[31mEvil", 'address' => "e\e@example.com" } },
                       'categories' => ["Wo\erk"],
                       'body' => { 'contentType' => 'text', 'content' => "one\e[2J\r\ntwo\a" })
    text = msg.to_text(attachments: Teems::Models::MailMessage.attachment_names([{ 'name' => "a\e[8m.pdf" }]))

    assert_equal 'Hi]0;owned', msg.subject
    refute_match(/[\e\a\r]/, text)
    assert_includes text, 'From: [31mEvil <e@example.com>'
    assert_includes text, 'Attachments: a[8m.pdf'
    assert_equal "one[2J\ntwo", msg.body
  end

  def test_html_bodies_lose_raw_and_encoded_controls
    msg = mail_message('body' => { 'contentType' => 'html', 'content' => "<p>a\e[2Jb &#27;]52;c;aGk=&#7;c</p>" })

    assert_equal '<p>a[2Jb &#27;]52;c;aGk=&#7;c</p>', msg.body
    assert_equal 'a[2Jb ]52;c;aGk=c', msg.text_body.to_s
  end

  def test_from_api_parses_headers_and_body
    msg = mail_message

    assert_equal 'Quarterly report: Q3', msg.subject
    assert_equal({ name: 'Alice Smith', address: 'alice@example.com' }, msg.from)
    assert_equal Time.utc(2026, 10, 20, 14, 5, 9), msg.received_at
    refute_predicate msg, :read?
    assert_equal 'Unread', msg.status
    assert_predicate msg, :html?
    assert_equal ['Work'], msg.categories
  end

  def test_short_id_is_stable_hex
    assert_match(/\A\h{8}\z/, mail_message.short_id)
    assert_equal mail_message.short_id, Teems::Models::MailMessage.short_id(sample_mail_message['id'])
  end

  def test_display_helpers
    cc = [{ 'emailAddress' => { 'name' => 'c@example.com', 'address' => 'c@example.com' } },
          { 'emailAddress' => { 'name' => 'Only Name', 'address' => '' } }]
    msg = mail_message('ccRecipients' => cc)

    assert_equal 'Alice Smith <alice@example.com>', msg.from_display
    assert_equal 'Alice Smith', msg.from_label
    assert_equal 'Eric Boehs <eric@example.com>', msg.to_display
    assert_equal 'c@example.com, Only Name', msg.cc_display
  end

  def test_missing_fields
    msg = Teems::Models::MailMessage.from_api('id' => 'x')

    assert_equal '', msg.subject
    assert_equal({ name: '', address: '' }, msg.from)
    assert_equal '', msg.from_label
    assert_nil msg.received_at
    assert_equal [], msg.to
    assert_equal '', msg.text_body.text
  end

  def test_text_body_converts_html
    body = mail_message.text_body

    assert_equal 'Hello the report [1]', body.text
    assert_equal "Links:\n[1] the report <https://example.com/r>", body.footer
  end

  def test_text_body_keeps_plain_text
    msg = mail_message('body' => { 'contentType' => 'text', 'content' => "Line 1\r\n<not html>\r\n\r\n" })

    assert_equal "Line 1\n<not html>", msg.text_body.text
    assert_equal '', msg.text_body.footer
  end

  def test_to_json_hash
    hash = mail_message('isRead' => true).to_json_hash

    assert_equal sample_mail_message['id'], hash[:id]
    assert_equal '2026-10-20T14:05:09Z', hash[:received_at]
    assert hash[:is_read]
    assert_equal '<abc@example.com>', hash[:internet_message_id]
    assert_nil Teems::Models::MailMessage.from_api('id' => 'x').to_json_hash[:received_at]
  end
end
