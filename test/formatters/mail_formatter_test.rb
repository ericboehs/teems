# frozen_string_literal: true

require 'test_helper'

class MailFormatterTest < Minitest::Test
  def setup
    @saved_tz = ENV.fetch('TZ', nil)
    ENV['TZ'] = 'America/Chicago'
    @formatter = Teems::Formatters::MailFormatter.new(output: test_output)
  end

  def teardown
    ENV['TZ'] = @saved_tz
  end

  def mail_message(**overrides) = Teems::Models::MailMessage.from_api(sample_mail_message(**overrides))

  def test_message_rows
    rows = @formatter.message_rows([mail_message, mail_message('isRead' => true, 'subject' => "Multi\r\nline")])

    assert_match(/\A\h{8}  2026-10-20 09:05  Alice Smith\s+Quarterly report: Q3  unread\z/, rows[0])
    assert_match(/Multi line  read\z/, rows[1])
  end

  def test_message_rows_truncate_long_senders
    row = @formatter.message_rows([mail_message('from' => { 'emailAddress' => { 'name' => 'N' * 40,
                                                                                'address' => '' } })])

    assert_includes row.first, "#{'N' * 21}...  Quarterly"
  end

  def test_message_tsv
    line = mail_message('subject' => "Tab\there").tsv_row

    assert_equal [sample_mail_message['id'], '2026-10-20T09:05:09-05:00', 'alice@example.com', 'Tab here', 'Unread'],
                 line.split("\t")
  end

  def test_folder_rows_and_tsv
    folders = [Teems::Models::MailFolder.from_api(sample_mail_folder),
               Teems::Models::MailFolder.from_api(sample_mail_folder('Sent Items', 'unreadItemCount' => 0))]
    rows = @formatter.folder_rows(folders)

    assert_match(/\AFOLDER\s+UNREAD\s+TOTAL\z/, rows[0])
    assert_match(/\AInbox\s+2\s+10\z/, rows[1])
    assert_equal ["Inbox\t2\t10", "Sent Items\t0\t10"], folders.map(&:tsv_row)
    assert_equal 1, @formatter.folder_rows([]).length
  end

  def test_message_detail
    text = mail_message.to_text(attachments: ['a.pdf'])

    assert_includes text, "Subject: Quarterly report: Q3\nFrom: Alice Smith <alice@example.com>\n"
    assert_includes text, "Date: Tuesday, October 20, 2026 at 9:05:09 AM\n"
    assert_includes text, "Categories: Work\nStatus: Unread\nAttachments: a.pdf\nID: #{sample_mail_message['id']}"
    refute_includes text, 'Cc:'
    assert text.end_with?("Hello the report [1]\n\nLinks:\n[1] the report <https://example.com/r>")
  end

  def test_message_detail_with_cc_and_no_attachments
    text = mail_message('ccRecipients' => [{ 'emailAddress' => { 'address' => 'c@e.com' } }]).to_text

    assert_includes text, "Cc: c@e.com\n"
    refute_includes text, 'Attachments:'
  end

  def test_dates_handle_nil
    assert_equal '', Teems::Formatters::MailDates.long(nil)
    assert_equal '', Teems::Formatters::MailDates.short(nil)
    assert_equal '', Teems::Formatters::MailDates.iso(nil)
  end
end
