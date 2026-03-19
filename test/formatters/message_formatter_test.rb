# frozen_string_literal: true

require 'test_helper'

# Tests console message formatting with timestamps, sender names, reactions, and color output
module MessageFormatterTests
  # Shared builder for formatter tests
  module Helpers
    module_function

    def build_message(**overrides)
      attrs = {
        id: '123', sender_id: 'user-123', sender_name: 'Test User',
        content: 'Test message', created_at: Time.now, message_type: 'message',
        reply_to_id: nil, reactions: [], attachments: [], importance: 'normal',
        edited: false, mentions: []
      }.merge(overrides)
      Teems::Models::Message.new(**attrs)
    end
  end

  # Tests basic formatting: timestamps, sender names, content, importance, and color
  class BasicFormattingTest < Minitest::Test
    include Helpers

    def test_format_includes_timestamp
      formatter = Teems::Formatters::MessageFormatter.new(output: test_output)
      message = build_message(created_at: Time.new(2026, 1, 20, 14, 30, 0))

      assert_match(/2026-01-20 14:30/, formatter.format(message))
    end

    def test_format_includes_sender_name
      formatter = Teems::Formatters::MessageFormatter.new(output: test_output)

      assert_match(/John Doe/, formatter.format(build_message(sender_name: 'John Doe')))
    end

    def test_format_includes_content
      formatter = Teems::Formatters::MessageFormatter.new(output: test_output)

      assert_match(/Hello world/, formatter.format(build_message(content: 'Hello world')))
    end

    def test_format_handles_nil_timestamp
      formatter = Teems::Formatters::MessageFormatter.new(output: test_output)

      assert_match(/\[\]/, formatter.format(build_message(created_at: nil)))
    end

    def test_format_shows_importance_marker_for_important_messages
      formatter = Teems::Formatters::MessageFormatter.new(output: test_output)

      assert_match(/!/, formatter.format(build_message(importance: 'high')))
    end

    def test_format_no_importance_marker_for_normal_messages
      formatter = Teems::Formatters::MessageFormatter.new(output: test_output)

      refute_match(/\].*!.*:/, formatter.format(build_message(importance: 'normal')))
    end

    def test_format_omits_reactions_when_empty
      formatter = Teems::Formatters::MessageFormatter.new(output: test_output)

      assert_equal 2, formatter.format(build_message(reactions: [])).split("\n").length
    end

    def test_format_with_color_output
      formatter = Teems::Formatters::MessageFormatter.new(output: Teems::Formatters::Output.new(color: true))

      assert_match(/\e\[/, formatter.format(build_message))
    end

    def test_format_without_color_output
      formatter = Teems::Formatters::MessageFormatter.new(output: Teems::Formatters::Output.new(color: false))

      refute_match(/\e\[/, formatter.format(build_message))
    end
  end

  # Tests reactions, edited indicator, attachments, and mention highlighting
  class EnhancementsTest < Minitest::Test
    include Helpers

    def test_format_includes_reactions_with_emoji
      formatter = Teems::Formatters::MessageFormatter.new(output: test_output)
      message = build_message(reactions: [{ type: 'like', count: 3 }, { type: 'heart', count: 1 }])

      result = formatter.format(message)

      assert_includes result, "\u{1F44D}(3)"
      assert_includes result, "\u{2764}\u{FE0F}"
    end

    def test_format_unknown_reaction_uses_name
      formatter = Teems::Formatters::MessageFormatter.new(output: test_output)

      assert_includes formatter.format(build_message(reactions: [{ type: 'custom_emoji', count: 2 }])),
                      'custom_emoji(2)'
    end

    def test_format_shows_edited_indicator
      formatter = Teems::Formatters::MessageFormatter.new(output: test_output)

      assert_includes formatter.format(build_message(edited: true)), '(edited)'
    end

    def test_format_omits_edited_when_false
      formatter = Teems::Formatters::MessageFormatter.new(output: test_output)

      refute_includes formatter.format(build_message(edited: false)), '(edited)'
    end

    def test_format_shows_attachments
      formatter = Teems::Formatters::MessageFormatter.new(output: test_output)
      message = build_message(attachments: [{ 'fileName' => 'report.pdf' }, { 'fileName' => 'data.xlsx' }])

      result = formatter.format(message)

      assert_includes result, 'report.pdf'
      assert_includes result, 'data.xlsx'
      assert_includes result, "\u{1F4CE}"
    end

    def test_format_omits_attachments_when_empty
      formatter = Teems::Formatters::MessageFormatter.new(output: test_output)

      refute_includes formatter.format(build_message(attachments: [])), "\u{1F4CE}"
    end

    def test_format_attachments_non_hash
      formatter = Teems::Formatters::MessageFormatter.new(output: test_output)

      assert_includes formatter.format(build_message(attachments: ['simple-string'])), 'simple-string'
    end

    def test_format_highlights_mentions
      formatter = Teems::Formatters::MessageFormatter.new(output: Teems::Formatters::Output.new(color: true))
      message = build_message(content: 'Hello Jane Smith!', mentions: ['Jane Smith'])

      assert_match(/\e\[1mJane Smith\e\[0m/, formatter.format(message))
    end

    def test_format_includes_short_hash
      formatter = Teems::Formatters::MessageFormatter.new(output: test_output)
      message = build_message(id: 'msg-123')
      expected_hash = Digest::SHA256.hexdigest('msg-123')[0, 6]

      assert_includes formatter.format(message), expected_hash
    end
  end
end
