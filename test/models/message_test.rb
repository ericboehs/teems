# frozen_string_literal: true

require 'test_helper'

class MessageTest < Minitest::Test
  # Graph API format tests
  def test_from_api_with_graph_format
    message = Teems::Models::Message.from_api(sample_graph_message)

    assert_equal '1234567890', message.id
    assert_equal 'user123', message.sender_id
    assert_equal 'John Doe', message.sender_name
    assert_equal 'Hello world', message.content
    assert_equal 'message', message.message_type
    assert_equal 'normal', message.importance
  end

  def test_from_api_strips_html_tags
    data = sample_graph_message.merge(
      'body' => { 'content' => '<p><strong>Bold</strong> and <em>italic</em></p>' }
    )
    message = Teems::Models::Message.from_api(data)

    assert_equal 'Bold and italic', message.content
  end

  def test_from_api_decodes_html_entities
    data = sample_graph_message.merge(
      'body' => { 'content' => '<p>Hello&nbsp;world &amp; goodbye</p>' }
    )
    message = Teems::Models::Message.from_api(data)

    assert_equal 'Hello world & goodbye', message.content
  end

  # ng.msg API format tests
  def test_from_api_with_ng_msg_format
    message = Teems::Models::Message.from_api(sample_ng_msg_message)

    assert_equal '1768935087318', message.id
    assert_equal 'Jane Smith', message.sender_name
    assert_equal 'Hello from ng.msg', message.content
    assert_equal 'RichText/Html', message.message_type
  end

  def test_from_api_with_ng_msg_parses_reactions
    message = Teems::Models::Message.from_api(sample_ng_msg_message)

    assert_equal 1, message.reactions.size
    assert_equal 'like', message.reactions[0][:type]
    assert_equal 1, message.reactions[0][:count]
  end

  def test_from_api_with_ng_msg_uses_display_name_fallback
    data = sample_ng_msg_message.dup
    data.delete('imdisplayname')
    data['fromDisplayNameInToken'] = 'Fallback Name'

    message = Teems::Models::Message.from_api(data)

    assert_equal 'Fallback Name', message.sender_name
  end

  def test_from_api_with_ng_msg_defaults_to_unknown
    data = sample_ng_msg_message.dup
    data.delete('imdisplayname')

    message = Teems::Models::Message.from_api(data)

    assert_equal 'Unknown', message.sender_name
  end

  # Teams internal API format tests
  def test_from_api_with_teams_internal_format
    data = {
      'id' => 'msg123',
      'message' => {
        'from' => 'user456',
        'imDisplayName' => 'Internal User',
        'content' => '<p>Internal message</p>',
        'composeTime' => '2026-01-20T12:00:00Z',
        'type' => 'message'
      }
    }

    message = Teems::Models::Message.from_api(data)

    assert_equal 'msg123', message.id
    assert_equal 'user456', message.sender_id
    assert_equal 'Internal User', message.sender_name
    assert_equal 'Internal message', message.content
  end

  # System message detection
  def test_system_message_returns_true_for_add_member
    message = Teems::Models::Message.from_api(sample_system_message)

    assert message.system_message?
  end

  def test_system_message_returns_false_for_rich_text
    message = Teems::Models::Message.from_api(sample_ng_msg_message)

    refute message.system_message?
  end

  def test_system_message_returns_false_for_message_type
    message = Teems::Models::Message.from_api(sample_graph_message)

    refute message.system_message?
  end

  def test_system_message_returns_false_for_text_type
    data = sample_ng_msg_message.merge('messagetype' => 'Text')
    message = Teems::Models::Message.from_api(data)

    refute message.system_message?
  end

  # Reply detection
  def test_reply_returns_true_when_root_message_differs
    data = sample_ng_msg_message.merge('rootMessageId' => 'different-id')
    message = Teems::Models::Message.from_api(data)

    assert message.reply?
  end

  def test_reply_returns_false_when_root_message_same
    data = sample_ng_msg_message.merge('rootMessageId' => sample_ng_msg_message['id'])
    message = Teems::Models::Message.from_api(data)

    refute message.reply?
  end

  def test_reply_returns_false_when_no_root_message
    message = Teems::Models::Message.from_api(sample_ng_msg_message)

    refute message.reply?
  end

  # Importance detection
  def test_important_returns_true_for_urgent
    data = sample_graph_message.merge('importance' => 'urgent')
    message = Teems::Models::Message.from_api(data)

    assert message.important?
  end

  def test_important_returns_true_for_high
    data = sample_graph_message.merge('importance' => 'high')
    message = Teems::Models::Message.from_api(data)

    assert message.important?
  end

  def test_important_returns_false_for_normal
    message = Teems::Models::Message.from_api(sample_graph_message)

    refute message.important?
  end

  # Time parsing
  def test_parses_created_at_time
    message = Teems::Models::Message.from_api(sample_graph_message)

    assert_instance_of Time, message.created_at
    assert_equal 2026, message.created_at.year
  end

  def test_handles_invalid_time_gracefully
    data = sample_graph_message.merge('createdDateTime' => 'not-a-time')
    message = Teems::Models::Message.from_api(data)

    assert_nil message.created_at
  end

  def test_handles_nil_time
    data = sample_graph_message.dup
    data.delete('createdDateTime')
    message = Teems::Models::Message.from_api(data)

    assert_nil message.created_at
  end

  # to_s
  def test_to_s_format
    message = Teems::Models::Message.from_api(sample_graph_message)

    assert_includes message.to_s, 'John Doe'
    assert_includes message.to_s, 'Hello world'
  end

  # Application user detection (Graph API)
  def test_system_message_returns_false_for_nil_type
    data = sample_graph_message.dup
    data.delete('messageType')
    message = Teems::Models::Message.from_api(data)

    refute message.system_message?
  end

  def test_reactions_with_nil_users
    data = sample_ng_msg_message.merge(
      'properties' => {
        'emotions' => [
          { 'key' => 'heart', 'users' => nil }
        ]
      }
    )
    message = Teems::Models::Message.from_api(data)

    assert_equal 1, message.reactions.first[:count]
  end

  def test_graph_reactions_with_nil_user
    data = sample_graph_message.merge(
      'reactions' => [{ 'reactionType' => 'like', 'user' => nil }]
    )
    message = Teems::Models::Message.from_api(data)

    assert_equal 1, message.reactions.first[:count]
  end

  def test_timestamp_alias
    message = Teems::Models::Message.from_api(sample_graph_message)

    assert_equal message.created_at, message.timestamp
  end

  def test_graph_reactions_with_user_array
    data = sample_graph_message.merge(
      'reactions' => [{ 'reactionType' => 'like', 'user' => %w[user1 user2 user3] }]
    )
    message = Teems::Models::Message.from_api(data)

    assert_equal 3, message.reactions.first[:count]
  end

  def test_to_s_with_nil_created_at
    data = sample_graph_message.dup
    data.delete('createdDateTime')
    message = Teems::Models::Message.from_api(data)

    result = message.to_s
    assert_includes result, 'John Doe'
    assert_includes result, 'Hello world'
    refute_includes result, 'nil'
  end

  def test_system_message_returns_true_for_message_type_Message
    data = sample_graph_message.merge('messageType' => 'Message')
    message = Teems::Models::Message.from_api(data)

    refute message.system_message?
  end

  def test_extracts_application_sender_name
    data = {
      'id' => 'msg123',
      'body' => { 'content' => 'Bot message' },
      'from' => {
        'application' => {
          'id' => 'app123',
          'displayName' => 'My Bot'
        }
      },
      'createdDateTime' => '2026-01-20T12:00:00Z',
      'messageType' => 'message'
    }

    message = Teems::Models::Message.from_api(data)

    assert_equal 'app123', message.sender_id
    assert_equal 'My Bot', message.sender_name
  end
end
