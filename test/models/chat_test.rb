# frozen_string_literal: true

require 'test_helper'

class ChatTest < Minitest::Test
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
    # Empty string should fall back to chat_type_label
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
end
