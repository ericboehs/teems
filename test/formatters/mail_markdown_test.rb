# frozen_string_literal: true

require 'test_helper'

class MailMarkdownTest < Minitest::Test
  Markdown = Teems::Formatters::MailMarkdown

  def setup
    @saved_tz = ENV.fetch('TZ', nil)
    ENV['TZ'] = 'America/Chicago'
  end

  def teardown
    ENV['TZ'] = @saved_tz
  end

  def mail_message(**overrides) = Teems::Models::MailMessage.from_api(sample_mail_message(**overrides))

  def test_filename
    msg = mail_message

    assert_equal "2026-10-20-Quarterly-report-Q3-#{msg.short_id}.md", Markdown.filename(msg)
  end

  def test_filename_fallbacks_and_slug_limit
    assert_match(/\A2026-10-20-no-subject-\h{8}\.md\z/, Markdown.filename(mail_message('subject' => '!!!')))
    assert_match(/\Aunknown-date-/, Markdown.filename(mail_message('receivedDateTime' => nil)))
    assert_equal 80, Markdown.filename(mail_message('subject' => 'a' * 200)).split('-')[3].length
  end

  def test_render_matches_outlook_cli_layout
    content = Markdown.render(mail_message('subject' => 'Say "hi"'), folder: 'Inbox', attachments: ['a.pdf'])
    front, body = content.split("\n\n---\n\n", 2)

    assert_includes front, "id: #{sample_mail_message['id']}\nsubject: \"Say \\\"hi\\\"\"\n"
    assert_includes front, %(from: "Alice Smith <alice@example.com>"\nto: "eric@example.com"\ncc: ""\n)
    assert_includes front, %(date: "Tuesday, October 20, 2026 at 9:05:09 AM"\nreceived: "2026-10-20T09:05:09-05:00")
    assert_includes front, %(folder: "Inbox"\ncategories: "Work"\nstatus: unread\nattachments: "a.pdf")
    assert_includes front, "# Say \"hi\"\n\n**From:** Alice Smith <alice@example.com>\n**To:** eric@example.com\n"
    assert_equal "Hello the report [1]\n\nLinks:\n[1] the report <https://example.com/r>\n", body
  end
end
