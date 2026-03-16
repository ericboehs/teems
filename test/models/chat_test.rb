# frozen_string_literal: true

require 'test_helper'

module ChatTests
  class GraphApiTest < Minitest::Test
    def test_from_api_extracts_fields
      chat = Teems::Models::Chat.from_api(sample_chat)

      assert_equal '19:chat123@thread.v2', chat.id
      assert_equal 'Project Discussion', chat.topic
      assert_equal 'group', chat.chat_type
    end

    def test_from_api_parses_created_at
      chat = Teems::Models::Chat.from_api(sample_chat)

      assert_instance_of Time, chat.created_at
      assert_equal 2026, chat.created_at.year
      assert_equal 1, chat.created_at.month
      assert_equal 15, chat.created_at.day
    end

    def test_from_api_parses_last_updated
      chat = Teems::Models::Chat.from_api(sample_chat)

      assert_instance_of Time, chat.last_updated
      assert_equal 20, chat.last_updated.day
    end

    def test_one_on_one_returns_true
      data = sample_chat.merge('chatType' => 'oneOnOne')
      chat = Teems::Models::Chat.from_api(data)

      assert chat.one_on_one?
      refute chat.group?
      refute chat.meeting?
    end

    def test_group_returns_true
      chat = Teems::Models::Chat.from_api(sample_chat)

      assert chat.group?
      refute chat.one_on_one?
      refute chat.meeting?
    end

    def test_meeting_returns_true
      data = sample_chat.merge('chatType' => 'meeting')
      chat = Teems::Models::Chat.from_api(data)

      assert chat.meeting?
      refute chat.one_on_one?
      refute chat.group?
    end

    def test_display_name_uses_topic_when_present
      chat = Teems::Models::Chat.from_api(sample_chat)

      assert_equal 'Project Discussion', chat.display_name
    end

    def test_display_name_falls_back_to_chat_type_label
      data = sample_chat.dup
      data.delete('topic')
      chat = Teems::Models::Chat.from_api(data)

      assert_equal 'Group Chat', chat.display_name
    end

    def test_display_name_falls_back_on_empty_topic
      data = sample_chat.merge('topic' => '')
      chat = Teems::Models::Chat.from_api(data)

      assert_equal 'Group Chat', chat.display_name
    end

    def test_chat_type_label_for_one_on_one
      data = sample_chat.merge('chatType' => 'oneOnOne')
      chat = Teems::Models::Chat.from_api(data)

      assert_equal '1:1 Chat', chat.chat_type_label
    end

    def test_chat_type_label_for_group
      chat = Teems::Models::Chat.from_api(sample_chat)

      assert_equal 'Group Chat', chat.chat_type_label
    end

    def test_chat_type_label_for_meeting
      data = sample_chat.merge('chatType' => 'meeting')
      chat = Teems::Models::Chat.from_api(data)

      assert_equal 'Meeting Chat', chat.chat_type_label
    end

    def test_chat_type_label_for_unknown
      data = sample_chat.merge('chatType' => 'somethingNew')
      chat = Teems::Models::Chat.from_api(data)

      assert_equal 'somethingNew', chat.chat_type_label
    end

    def test_graph_chats_default_to_not_unread
      chat = Teems::Models::Chat.from_api(sample_chat)

      refute chat.unread?
      refute chat.favorite?
      refute chat.pinned?
    end

    def test_handles_nil_times_gracefully
      data = sample_chat.dup
      data.delete('createdDateTime')
      data.delete('lastUpdatedDateTime')
      chat = Teems::Models::Chat.from_api(data)

      assert_nil chat.created_at
      assert_nil chat.last_updated
    end

    def test_handles_invalid_times_gracefully
      data = sample_chat.merge(
        'createdDateTime' => 'not-a-date',
        'lastUpdatedDateTime' => 'also-not-a-date'
      )
      chat = Teems::Models::Chat.from_api(data)

      assert_nil chat.created_at
      assert_nil chat.last_updated
    end

    def test_to_s_returns_display_name
      chat = Teems::Models::Chat.from_api(sample_chat)

      assert_equal 'Project Discussion', chat.to_s
    end
  end

  class NgMsgApiTest < Minitest::Test
    def test_from_api_detects_ngmsg_format
      ngmsg_data = {
        'id' => '19:abc@thread.v2',
        'threadProperties' => { 'topic' => 'Ng Test', 'threadType' => 'chat' }
      }
      chat = Teems::Models::Chat.from_api(ngmsg_data)

      assert_equal '19:abc@thread.v2', chat.id
      assert_equal 'Ng Test', chat.topic
      assert_equal 'group', chat.chat_type
    end

    def test_from_ngmsg_extracts_topic_from_thread_properties
      chat = Teems::Models::Chat.from_api(sample_ngmsg_chat_data)
      assert_equal 'Ng.msg Topic', chat.topic
      assert_instance_of Time, chat.created_at
      assert_instance_of Time, chat.last_updated
    end

    def test_normalize_chat_type_chat_to_group
      assert_equal 'group', Teems::Models::Chat.normalize_chat_type('chat')
      assert_equal 'group', Teems::Models::Chat.normalize_chat_type('Chat')
      assert_equal 'group', Teems::Models::Chat.normalize_chat_type('CHAT')
    end

    def test_normalize_chat_type_meeting_unchanged
      assert_equal 'meeting', Teems::Models::Chat.normalize_chat_type('meeting')
      assert_equal 'meeting', Teems::Models::Chat.normalize_chat_type('Meeting')
    end

    def test_normalize_chat_type_topic_to_channel
      assert_equal 'channel', Teems::Models::Chat.normalize_chat_type('topic')
      assert_equal 'channel', Teems::Models::Chat.normalize_chat_type('Topic')
    end

    def test_normalize_chat_type_space
      assert_equal 'space', Teems::Models::Chat.normalize_chat_type('space')
      assert_equal 'space', Teems::Models::Chat.normalize_chat_type('Space')
    end

    def test_normalize_chat_type_passes_through_unknown
      assert_equal 'somethingNew', Teems::Models::Chat.normalize_chat_type('somethingNew')
    end

    def test_normalize_chat_type_handles_nil
      assert_nil Teems::Models::Chat.normalize_chat_type(nil)
    end

    def test_from_ngmsg_channel
      ngmsg_data = {
        'id' => '19:channel123@thread.tacv2',
        'threadProperties' => { 'threadType' => 'topic', 'topic' => 'General' }
      }
      chat = Teems::Models::Chat.from_api(ngmsg_data)

      assert chat.channel?
      refute chat.group?
      assert_equal 'General', chat.topic
    end

    def test_from_ngmsg_meeting_chat
      ngmsg_data = {
        'id' => '19:meeting@thread.v2',
        'threadProperties' => { 'threadType' => 'meeting' }
      }
      chat = Teems::Models::Chat.from_api(ngmsg_data)

      assert chat.meeting?
      refute chat.group?
    end

    def test_from_ngmsg_handles_missing_thread_properties_fields
      ngmsg_data = { 'id' => '19:minimal@thread.v2', 'threadProperties' => {} }
      chat = Teems::Models::Chat.from_api(ngmsg_data)

      assert_equal '19:minimal@thread.v2', chat.id
      assert_nil chat.topic
      assert_nil chat.chat_type
    end

    def test_space_predicate
      ngmsg_data = {
        'id' => '19:space@thread.v2',
        'threadProperties' => { 'threadType' => 'space', 'topic' => 'My Space' }
      }
      chat = Teems::Models::Chat.from_api(ngmsg_data)

      assert chat.space?
      refute chat.group?
    end

    def test_chat_type_label_channel
      ngmsg_data = { 'id' => '19:ch@thread.tacv2', 'threadProperties' => { 'threadType' => 'topic' } }
      chat = Teems::Models::Chat.from_api(ngmsg_data)

      assert_equal 'Channel', chat.chat_type_label
    end

    def test_chat_type_label_space
      ngmsg_data = { 'id' => '19:sp@thread.v2', 'threadProperties' => { 'threadType' => 'space' } }
      chat = Teems::Models::Chat.from_api(ngmsg_data)

      assert_equal 'Space', chat.chat_type_label
    end

    private

    def sample_ngmsg_chat_data
      {
        'id' => '19:ngmsg123@thread.v2',
        'threadProperties' => {
          'topic' => 'Ng.msg Topic', 'threadType' => 'chat',
          'createdat' => '2026-01-15T10:00:00Z'
        },
        'properties' => { 'lastimreceivedtime' => '2026-01-20T12:00:00Z' }
      }
    end
  end

  class NgMsgStatusTest < Minitest::Test
    def test_detects_unread
      chat = parse(props: { 'consumptionhorizon' => '1000;1000;user1' }, last_msg: '2000')
      assert chat.unread?
    end

    def test_detects_read
      chat = parse(props: { 'consumptionhorizon' => '2000;2000;user1' }, last_msg: '2000')
      refute chat.unread?
    end

    def test_unread_false_without_horizon
      refute parse(last_msg: '2000').unread?
    end

    def test_unread_false_without_last_message
      refute parse(props: { 'consumptionhorizon' => '1000;1000;user1' }).unread?
    end

    def test_detects_favorite
      assert parse(props: { 'favorite' => 'true' }).favorite?
    end

    def test_not_favorite_by_default
      refute parse.favorite?
    end

    def test_detects_pinned
      assert parse(props: { 'ispinned' => 'true' }).pinned?
    end

    def test_not_pinned_by_default
      refute parse.pinned?
    end

    def test_space_uses_space_thread_topic
      data = { 'id' => '19:space@thread.v2',
               'threadProperties' => { 'threadType' => 'space', 'spaceThreadTopic' => 'My Team' },
               'properties' => {} }
      assert_equal 'My Team', Teems::Models::Chat.from_api(data).topic
    end

    private

    def parse(props: {}, last_msg: nil)
      data = { 'id' => '19:test@thread.v2',
               'threadProperties' => { 'threadType' => 'chat' },
               'properties' => props }
      data['lastMessage'] = { 'id' => last_msg } if last_msg
      Teems::Models::Chat.from_api(data)
    end
  end
end
