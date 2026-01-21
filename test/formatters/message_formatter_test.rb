# frozen_string_literal: true

require 'test_helper'

class MessageFormatterTest < Minitest::Test
  def test_format_includes_timestamp
    output = test_output
    formatter = Teems::Formatters::MessageFormatter.new(output: output)
    message = build_message(created_at: Time.new(2026, 1, 20, 14, 30, 0))

    result = formatter.format(message)

    assert_match(/2026-01-20 14:30/, result)
  end

  def test_format_includes_sender_name
    output = test_output
    formatter = Teems::Formatters::MessageFormatter.new(output: output)
    message = build_message(sender_name: 'John Doe')

    result = formatter.format(message)

    assert_match(/John Doe/, result)
  end

  def test_format_includes_content
    output = test_output
    formatter = Teems::Formatters::MessageFormatter.new(output: output)
    message = build_message(content: 'Hello world')

    result = formatter.format(message)

    assert_match(/Hello world/, result)
  end

  def test_format_handles_nil_timestamp
    output = test_output
    formatter = Teems::Formatters::MessageFormatter.new(output: output)
    message = build_message(created_at: nil)

    result = formatter.format(message)

    # Should not raise and should have empty time portion
    assert_match(/\[\]/, result)
  end

  def test_format_shows_importance_marker_for_important_messages
    output = test_output
    formatter = Teems::Formatters::MessageFormatter.new(output: output)
    message = build_message(importance: 'high')

    result = formatter.format(message)

    # The importance marker is red '!'
    assert_match(/!/, result)
  end

  def test_format_no_importance_marker_for_normal_messages
    output = test_output
    formatter = Teems::Formatters::MessageFormatter.new(output: output)
    message = build_message(importance: 'normal')

    result = formatter.format(message)

    # Should not have the importance marker before the name
    # The '!' could appear elsewhere, so check for pattern
    refute_match(/\].*!.*:/, result)
  end

  def test_format_includes_reactions
    output = test_output
    formatter = Teems::Formatters::MessageFormatter.new(output: output)
    message = build_message(reactions: [{ type: 'like', count: 3 }, { type: 'heart', count: 1 }])

    result = formatter.format(message)

    assert_match(/like\(3\)/, result)
    assert_match(/heart\(1\)/, result)
  end

  def test_format_omits_reactions_when_empty
    output = test_output
    formatter = Teems::Formatters::MessageFormatter.new(output: output)
    message = build_message(reactions: [])

    result = formatter.format(message)

    # Should only have header and content, no reactions line
    lines = result.split("\n")
    assert_equal 2, lines.length
  end

  def test_format_with_color_output
    output = Teems::Formatters::Output.new(color: true)
    formatter = Teems::Formatters::MessageFormatter.new(output: output)
    message = build_message

    result = formatter.format(message)

    # Should contain ANSI color codes
    assert_match(/\e\[/, result)
  end

  def test_format_without_color_output
    output = Teems::Formatters::Output.new(color: false)
    formatter = Teems::Formatters::MessageFormatter.new(output: output)
    message = build_message

    result = formatter.format(message)

    # Should not contain ANSI color codes
    refute_match(/\e\[/, result)
  end

  private

  def build_message(
    id: '123',
    sender_name: 'Test User',
    content: 'Test message',
    created_at: Time.now,
    message_type: 'message',
    importance: 'normal',
    reactions: []
  )
    Teems::Models::Message.new(
      id: id,
      sender_id: 'user-123',
      sender_name: sender_name,
      content: content,
      created_at: created_at,
      message_type: message_type,
      reply_to_id: nil,
      reactions: reactions,
      attachments: [],
      importance: importance
    )
  end
end
