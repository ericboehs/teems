# frozen_string_literal: true

require 'test_helper'

# Tests for the Channels API wrapper (teams and channel listing)
class ApiChannelsTest < Minitest::Test
  def test_list_teams_calls_correct_endpoint
    api_client = Teems::TestHelpers::MockApiClient.new
    api_client.stub('joinedTeams', { 'value' => [] })
    account = mock_account
    channels = Teems::Api::Channels.new(api_client, account)

    channels.list_teams

    call = api_client.calls.last
    assert_equal :get, call[:method]
    assert_includes call[:path], '/v1.0/me/joinedTeams'
  end

  def test_list_channels_calls_correct_endpoint
    api_client = Teems::TestHelpers::MockApiClient.new
    api_client.stub('channels', { 'value' => [] })
    account = mock_account
    channels = Teems::Api::Channels.new(api_client, account)

    channels.list_channels(team_id: 'team-uuid-123')

    call = api_client.calls.last
    assert_equal :get, call[:method]
    assert_includes call[:path], '/v1.0/teams/team-uuid-123/channels'
  end

  def test_list_channels_url_encodes_team_id
    api_client = Teems::TestHelpers::MockApiClient.new
    api_client.stub('channels', { 'value' => [] })
    account = mock_account
    channels = Teems::Api::Channels.new(api_client, account)

    channels.list_channels(team_id: 'team with spaces')

    call = api_client.calls.last
    assert_includes call[:path], 'team+with+spaces'
  end

  def test_get_channel_calls_correct_endpoint
    api_client = Teems::TestHelpers::MockApiClient.new
    api_client.stub('channels', { 'id' => 'ch1' })
    account = mock_account
    channels = Teems::Api::Channels.new(api_client, account)

    channels.get_channel(team_id: 'team-1', channel_id: '19:ch@thread.tacv2')

    call = api_client.calls.last
    assert_equal :get, call[:method]
    assert_includes call[:path], '/v1.0/teams/team-1/channels/'
  end

  def test_get_channel_url_encodes_ids
    api_client = Teems::TestHelpers::MockApiClient.new
    api_client.stub('channels', {})
    account = mock_account
    channels = Teems::Api::Channels.new(api_client, account)

    channels.get_channel(team_id: 'team@123', channel_id: '19:ch@thread')

    call = api_client.calls.last
    call_path = call[:path]
    assert_includes call_path, 'team%40123'
    assert_includes call_path, '19%3Ach%40thread'
  end
end
