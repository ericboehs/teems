# frozen_string_literal: true

require 'test_helper'

module MarkdownFormatterTests
  module Helpers
    private

    def build_formatter(chat_name: 'Test Chat', chat_type: nil, synced_at: nil)
      Teems::Formatters::MarkdownFormatter.new(chat_name: chat_name, chat_type: chat_type, synced_at: synced_at)
    end

    def build_message(**overrides)
      attrs = {
        id: 'msg-1', sender_id: 'user-1', sender_name: 'Test User',
        content: 'Test message', created_at: Time.new(2026, 1, 20, 10, 0, 0),
        message_type: 'RichText/Html', reply_to_id: nil,
        reactions: [], attachments: [], importance: nil
      }.merge(overrides)
      Teems::Models::Message.new(**attrs)
    end
  end

  class HeaderAndBasicTest < Minitest::Test
    include Helpers

    def test_format_empty_messages
      result = build_formatter.format([])
      assert_includes result, '# Test Chat'
      assert_includes result, '_No messages_'
    end

    def test_format_header_includes_chat_name
      result = build_formatter(chat_name: 'Engineering Team').format([])
      assert_includes result, '# Engineering Team'
    end

    def test_format_header_includes_chat_type
      result = build_formatter(chat_type: 'group').format([])
      assert_includes result, '**Type:** group'
    end

    def test_format_header_includes_synced_at
      result = build_formatter(synced_at: Time.new(2026, 1, 20, 14, 30, 0)).format([])
      assert_includes result, '_Synced: 2026-01-20 14:30_'
    end

    def test_format_single_message
      msg = build_message(sender_name: 'Jane Smith', content: 'Hello world',
                          created_at: Time.new(2026, 1, 20, 10, 32, 0))
      result = build_formatter.format([msg])
      assert_includes result, '## 2026-01-20'
      assert_includes result, '### 10:32 — Jane Smith'
      assert_includes result, 'Hello world'
    end

    def test_format_groups_by_date
      morning_msg = build_message(sender_name: 'Alice', content: 'Morning',
                                  created_at: Time.new(2026, 1, 19, 9, 0, 0))
      afternoon_msg = build_message(sender_name: 'Bob', content: 'Afternoon',
                                    created_at: Time.new(2026, 1, 20, 14, 0, 0))
      result = build_formatter.format([morning_msg, afternoon_msg])
      assert_includes result, '## 2026-01-19'
      assert_includes result, '## 2026-01-20'
    end

    def test_format_skips_system_messages
      msg = build_message(sender_name: 'System', content: 'User joined',
                          message_type: 'ThreadActivity/AddMember')
      refute_includes build_formatter.format([msg]), 'User joined'
    end

    def test_format_reply_marker
      msg = build_message(sender_name: 'Jane', content: 'I agree', reply_to_id: 'parent-msg-id')
      assert_includes build_formatter.format([msg]), '> _Reply to message_'
    end

    def test_format_important_marker
      msg = build_message(sender_name: 'Boss', content: 'Urgent update', importance: 'urgent')
      assert_includes build_formatter.format([msg]), '**[!]**'
    end

    def test_format_message_nil_content
      result = build_formatter.format([build_message(content: nil)])
      assert_includes result, 'Test User'
    end

    def test_format_message_empty_content
      result = build_formatter.format([build_message(content: '')])
      assert_includes result, 'Test User'
    end

    def test_format_message_nil_created_at
      assert_includes build_formatter.format([build_message(created_at: nil)]), '??:??'
    end

    def test_format_message_nil_created_at_after_real_date
      dated_msg = build_message(sender_name: 'Alice', created_at: Time.new(2026, 1, 20, 10, 0, 0))
      undated_msg = build_message(sender_name: 'Bob', created_at: nil)
      result = build_formatter.format([dated_msg, undated_msg])
      assert_includes result, '## 2026-01-20'
      assert_includes result, '## Unknown Date'
    end

    def test_format_message_nil_sender_name
      assert_includes build_formatter.format([build_message(sender_name: nil)]), 'Unknown'
    end
  end

  class ReactionsAndAttachmentsTest < Minitest::Test
    include Helpers

    def test_format_reactions_with_emoji_mapping
      msg = build_message(sender_name: 'Jane', content: 'Great idea',
                          reactions: [{ type: 'like', count: 3 }, { type: 'heart', count: 1 }])
      result = build_formatter.format([msg])
      assert_includes result, "\u{1F44D}"
      assert_includes result, "\u{2764}"
      assert_includes result, "\u{D7}3"
    end

    def test_format_unknown_reaction_uses_name
      msg = build_message(sender_name: 'Jane', content: 'Custom reaction',
                          reactions: [{ type: 'custom_emoji', count: 1 }])
      assert_includes build_formatter.format([msg]), 'custom_emoji'
    end

    def test_format_attachments
      msg = build_message(sender_name: 'Jane', content: 'See attached',
                          attachments: [{ 'fileName' => 'report.pdf' }, { 'fileName' => 'data.xlsx' }])
      result = build_formatter.format([msg])
      assert_includes result, "\u{1F4CE} report.pdf"
      assert_includes result, "\u{1F4CE} data.xlsx"
    end

    def test_format_attachment_with_name_key
      msg = build_message(sender_name: 'Jane', content: 'Here',
                          attachments: [{ 'name' => 'photo.jpg' }])
      assert_includes build_formatter.format([msg]), "\u{1F4CE} photo.jpg"
    end

    def test_format_attachment_non_hash
      msg = build_message(attachments: ['simple-string-attachment'])
      assert_includes build_formatter.format([msg]), "\u{1F4CE} simple-string-attachment"
    end

    def test_format_attachment_hash_without_keys
      msg = build_message(attachments: [{ 'other' => 'data' }])
      assert_includes build_formatter.format([msg]), "\u{1F4CE} file"
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
  end
end
