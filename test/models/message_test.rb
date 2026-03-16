# frozen_string_literal: true

require 'test_helper'

module MessageTests
  class GraphApiParsingTest < Minitest::Test
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
      assert_equal 'Bold and italic', Teems::Models::Message.from_api(data).content
    end

    def test_from_api_decodes_html_entities
      data = sample_graph_message.merge(
        'body' => { 'content' => '<p>Hello&nbsp;world &amp; goodbye</p>' }
      )
      assert_equal 'Hello world & goodbye', Teems::Models::Message.from_api(data).content
    end

    def test_system_message_returns_false_for_message_type
      refute Teems::Models::Message.from_api(sample_graph_message).system_message?
    end

    def test_system_message_returns_false_for_nil_type
      data = sample_graph_message.dup
      data.delete('messageType')
      refute Teems::Models::Message.from_api(data).system_message?
    end

    def test_system_message_returns_true_for_message_type_message
      data = sample_graph_message.merge('messageType' => 'Message')
      refute Teems::Models::Message.from_api(data).system_message?
    end

    def test_important_returns_true_for_urgent
      data = sample_graph_message.merge('importance' => 'urgent')
      assert Teems::Models::Message.from_api(data).important?
    end

    def test_important_returns_true_for_high
      data = sample_graph_message.merge('importance' => 'high')
      assert Teems::Models::Message.from_api(data).important?
    end

    def test_important_returns_false_for_normal
      refute Teems::Models::Message.from_api(sample_graph_message).important?
    end
  end

  class GraphApiTimeAndFormatTest < Minitest::Test
    def test_parses_created_at_time
      message = Teems::Models::Message.from_api(sample_graph_message)
      assert_instance_of Time, message.created_at
      assert_equal 2026, message.created_at.year
    end

    def test_handles_invalid_time_gracefully
      data = sample_graph_message.merge('createdDateTime' => 'not-a-time')
      assert_nil Teems::Models::Message.from_api(data).created_at
    end

    def test_handles_nil_time
      data = sample_graph_message.dup
      data.delete('createdDateTime')
      assert_nil Teems::Models::Message.from_api(data).created_at
    end

    def test_to_s_format
      message = Teems::Models::Message.from_api(sample_graph_message)
      assert_includes message.to_s, 'John Doe'
      assert_includes message.to_s, 'Hello world'
    end

    def test_to_s_with_nil_created_at
      data = sample_graph_message.dup
      data.delete('createdDateTime')
      result = Teems::Models::Message.from_api(data).to_s
      assert_includes result, 'John Doe'
      assert_includes result, 'Hello world'
      refute_includes result, 'nil'
    end

    def test_timestamp_alias
      message = Teems::Models::Message.from_api(sample_graph_message)
      assert_equal message.created_at, message.timestamp
    end

    def test_graph_reactions_with_nil_user
      data = sample_graph_message.merge('reactions' => [{ 'reactionType' => 'like', 'user' => nil }])
      assert_equal 1, Teems::Models::Message.from_api(data).reactions.first[:count]
    end

    def test_graph_reactions_with_user_array
      data = sample_graph_message.merge(
        'reactions' => [{ 'reactionType' => 'like', 'user' => %w[user1 user2 user3] }]
      )
      assert_equal 3, Teems::Models::Message.from_api(data).reactions.first[:count]
    end

    def test_extracts_application_sender_name
      data = { 'id' => 'msg123', 'body' => { 'content' => 'Bot message' },
               'from' => { 'application' => { 'id' => 'app123', 'displayName' => 'My Bot' } },
               'createdDateTime' => '2026-01-20T12:00:00Z', 'messageType' => 'message' }
      message = Teems::Models::Message.from_api(data)
      assert_equal 'app123', message.sender_id
      assert_equal 'My Bot', message.sender_name
    end
  end

  class NgMsgAndOtherTest < Minitest::Test
    def test_from_api_with_ng_msg_format
      message = Teems::Models::Message.from_api(sample_ng_msg_message)
      assert_equal '1768935087318', message.id
      assert_equal 'Jane Smith', message.sender_name
      assert_equal 'Hello from ng.msg', message.content
      assert_equal 'RichText/Html', message.message_type
    end

    def test_from_api_with_ng_msg_parses_reactions
      message = Teems::Models::Message.from_api(sample_ng_msg_message)
      reactions = message.reactions
      assert_equal 1, reactions.size
      assert_equal 'like', reactions[0][:type]
      assert_equal 1, reactions[0][:count]
    end

    def test_from_api_with_ng_msg_uses_display_name_fallback
      data = sample_ng_msg_message.dup
      data.delete('imdisplayname')
      data['fromDisplayNameInToken'] = 'Fallback Name'
      assert_equal 'Fallback Name', Teems::Models::Message.from_api(data).sender_name
    end

    def test_from_api_with_ng_msg_defaults_to_unknown
      data = sample_ng_msg_message.dup
      data.delete('imdisplayname')
      assert_equal 'Unknown', Teems::Models::Message.from_api(data).sender_name
    end

    def test_reactions_with_nil_users
      data = sample_ng_msg_message.merge(
        'properties' => { 'emotions' => [{ 'key' => 'heart', 'users' => nil }] }
      )
      assert_equal 1, Teems::Models::Message.from_api(data).reactions.first[:count]
    end

    def test_system_message_returns_true_for_add_member
      assert Teems::Models::Message.from_api(sample_system_message).system_message?
    end

    def test_system_message_returns_false_for_rich_text
      refute Teems::Models::Message.from_api(sample_ng_msg_message).system_message?
    end

    def test_system_message_returns_false_for_text_type
      data = sample_ng_msg_message.merge('messagetype' => 'Text')
      refute Teems::Models::Message.from_api(data).system_message?
    end

    def test_reply_returns_true_when_root_message_differs
      data = sample_ng_msg_message.merge('rootMessageId' => 'different-id')
      assert Teems::Models::Message.from_api(data).reply?
    end

    def test_reply_returns_false_when_root_message_same
      data = sample_ng_msg_message.merge('rootMessageId' => sample_ng_msg_message['id'])
      refute Teems::Models::Message.from_api(data).reply?
    end

    def test_reply_returns_false_when_no_root_message
      refute Teems::Models::Message.from_api(sample_ng_msg_message).reply?
    end

    def test_from_api_with_teams_internal_format
      data = { 'id' => 'msg123',
               'message' => { 'from' => 'user456', 'imDisplayName' => 'Internal User',
                              'content' => '<p>Internal message</p>',
                              'composeTime' => '2026-01-20T12:00:00Z', 'type' => 'message' } }
      message = Teems::Models::Message.from_api(data)
      assert_equal 'msg123', message.id
      assert_equal 'user456', message.sender_id
      assert_equal 'Internal User', message.sender_name
      assert_equal 'Internal message', message.content
    end
  end
end
