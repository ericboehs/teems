# frozen_string_literal: true

require 'test_helper'

class MarkdownFormatterTest < Minitest::Test
  def test_format_empty_messages
    formatter = build_formatter
    result = formatter.format([])

    assert_includes result, '# Test Chat'
    assert_includes result, '_No messages_'
  end

  def test_format_header_includes_chat_name
    formatter = build_formatter(chat_name: 'Engineering Team')
    result = formatter.format([])

    assert_includes result, '# Engineering Team'
  end

  def test_format_header_includes_chat_type
    formatter = build_formatter(chat_type: 'group')
    result = formatter.format([])

    assert_includes result, '**Type:** group'
  end

  def test_format_header_includes_synced_at
    synced = Time.new(2026, 1, 20, 14, 30, 0)
    formatter = build_formatter(synced_at: synced)
    result = formatter.format([])

    assert_includes result, '_Synced: 2026-01-20 14:30_'
  end

  def test_format_single_message
    msg = build_message(
      sender_name: 'Jane Smith',
      content: 'Hello world',
      created_at: Time.new(2026, 1, 20, 10, 32, 0)
    )
    formatter = build_formatter
    result = formatter.format([msg])

    assert_includes result, '## 2026-01-20'
    assert_includes result, '### 10:32 — Jane Smith'
    assert_includes result, 'Hello world'
  end

  def test_format_groups_by_date
    msg1 = build_message(
      sender_name: 'Alice',
      content: 'Morning',
      created_at: Time.new(2026, 1, 19, 9, 0, 0)
    )
    msg2 = build_message(
      sender_name: 'Bob',
      content: 'Afternoon',
      created_at: Time.new(2026, 1, 20, 14, 0, 0)
    )
    formatter = build_formatter
    result = formatter.format([msg1, msg2])

    assert_includes result, '## 2026-01-19'
    assert_includes result, '## 2026-01-20'
  end

  def test_format_skips_system_messages
    msg = build_message(
      sender_name: 'System',
      content: 'User joined',
      message_type: 'ThreadActivity/AddMember'
    )
    formatter = build_formatter
    result = formatter.format([msg])

    refute_includes result, 'User joined'
  end

  def test_format_reply_marker
    msg = build_message(
      sender_name: 'Jane',
      content: 'I agree',
      reply_to_id: 'parent-msg-id'
    )
    formatter = build_formatter
    result = formatter.format([msg])

    assert_includes result, '> _Reply to message_'
  end

  def test_format_important_marker
    msg = build_message(
      sender_name: 'Boss',
      content: 'Urgent update',
      importance: 'urgent'
    )
    formatter = build_formatter
    result = formatter.format([msg])

    assert_includes result, '**[!]**'
  end

  def test_format_reactions_with_emoji_mapping
    msg = build_message(
      sender_name: 'Jane',
      content: 'Great idea',
      reactions: [{ type: 'like', count: 3 }, { type: 'heart', count: 1 }]
    )
    formatter = build_formatter
    result = formatter.format([msg])

    assert_includes result, "\u{1F44D}" # 👍
    assert_includes result, "\u{2764}" # ❤️ (checking just the heart part)
    assert_includes result, '×3'
  end

  def test_format_unknown_reaction_uses_name
    msg = build_message(
      sender_name: 'Jane',
      content: 'Custom reaction',
      reactions: [{ type: 'custom_emoji', count: 1 }]
    )
    formatter = build_formatter
    result = formatter.format([msg])

    assert_includes result, 'custom_emoji'
  end

  def test_format_attachments
    msg = build_message(
      sender_name: 'Jane',
      content: 'See attached',
      attachments: [{ 'fileName' => 'report.pdf' }, { 'fileName' => 'data.xlsx' }]
    )
    formatter = build_formatter
    result = formatter.format([msg])

    assert_includes result, "\u{1F4CE} report.pdf"
    assert_includes result, "\u{1F4CE} data.xlsx"
  end

  def test_format_attachment_with_name_key
    msg = build_message(
      sender_name: 'Jane',
      content: 'Here',
      attachments: [{ 'name' => 'photo.jpg' }]
    )
    formatter = build_formatter
    result = formatter.format([msg])

    assert_includes result, "\u{1F4CE} photo.jpg"
  end

  def test_reaction_emoji_mapping
    mapping = Teems::Formatters::MarkdownFormatter::REACTION_EMOJI
    assert_equal "\u{1F44D}", mapping['like']
    assert_equal "\u{2764}\u{FE0F}", mapping['heart']
    assert_equal "\u{1F602}", mapping['laugh']
    assert_equal "\u{1F62E}", mapping['surprised']
    assert_equal "\u{1F622}", mapping['sad']
    assert_equal "\u{1F620}", mapping['angry']
  end

  private

  def build_formatter(chat_name: 'Test Chat', chat_type: nil, synced_at: nil)
    Teems::Formatters::MarkdownFormatter.new(
      chat_name: chat_name,
      chat_type: chat_type,
      synced_at: synced_at
    )
  end

  def build_message(
    id: 'msg-1',
    sender_id: 'user-1',
    sender_name: 'Test User',
    content: 'Test message',
    created_at: Time.new(2026, 1, 20, 10, 0, 0),
    message_type: 'RichText/Html',
    reply_to_id: nil,
    reactions: [],
    attachments: [],
    importance: nil
  )
    Teems::Models::Message.new(
      id: id,
      sender_id: sender_id,
      sender_name: sender_name,
      content: content,
      created_at: created_at,
      message_type: message_type,
      reply_to_id: reply_to_id,
      reactions: reactions,
      attachments: attachments,
      importance: importance
    )
  end
end
