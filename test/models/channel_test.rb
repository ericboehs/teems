# frozen_string_literal: true

require 'test_helper'

# Tests Channel model parsing from API data, membership types, and display name formatting
class ChannelTest < Minitest::Test
  def test_from_api_extracts_fields
    channel = Teems::Models::Channel.from_api(sample_channel)

    assert_equal '19:channel123@thread.tacv2', channel.id
    assert_equal 'General', channel.name
    assert_equal 'General discussions', channel.description
    assert_equal 'standard', channel.membership_type
  end

  def test_from_api_with_team_context
    channel = Teems::Models::Channel.from_api(
      sample_channel,
      team_id: 'team-123',
      team_name: 'Engineering'
    )

    assert_equal 'team-123', channel.team_id
    assert_equal 'Engineering', channel.team_name
  end

  def test_from_api_without_team_context
    channel = Teems::Models::Channel.from_api(sample_channel)

    assert_nil channel.team_id
    assert_nil channel.team_name
  end

  def test_private_returns_true_for_private_channel
    data = sample_channel.merge('membershipType' => 'private')
    channel = Teems::Models::Channel.from_api(data)

    assert channel.private?
  end

  def test_private_returns_false_for_standard_channel
    channel = Teems::Models::Channel.from_api(sample_channel)

    refute channel.private?
  end

  def test_display_name_with_team_name
    channel = Teems::Models::Channel.from_api(
      sample_channel,
      team_name: 'Engineering'
    )

    assert_equal 'Engineering / General', channel.display_name
  end

  def test_display_name_without_team_name
    channel = Teems::Models::Channel.from_api(sample_channel)

    assert_equal 'General', channel.display_name
  end

  def test_handles_missing_description
    data = sample_channel.dup
    data.delete('description')
    channel = Teems::Models::Channel.from_api(data)

    assert_nil channel.description
  end

  def test_handles_nil_membership_type
    data = sample_channel.dup
    data.delete('membershipType')
    channel = Teems::Models::Channel.from_api(data)

    assert_nil channel.membership_type
    refute channel.private?
  end

  def test_to_s
    channel = Teems::Models::Channel.from_api(sample_channel)

    assert_equal '#General', channel.to_s
  end
end
