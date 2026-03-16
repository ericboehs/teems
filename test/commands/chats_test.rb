# frozen_string_literal: true

require 'test_helper'

module ChatsCommandTests
  module Helpers
    private

    def run_chats(args = [])
      with_temp_config do
        capture_output do |output|
          runner = configured_runner(output: output)
          Teems::Commands::Chats.new(args, runner: runner).execute
        end
      end
    end

    def run_chats_with_stub(args, path, response)
      with_temp_config do
        exit_code = nil
        result = capture_output do |output|
          runner = configured_runner(output: output)
          runner.api_client.stub(path, response)
          exit_code = Teems::Commands::Chats.new(args, runner: runner).execute
        end
        result.merge(exit_code: exit_code)
      end
    end

    def run_chats_with_data(data)
      exit_code = nil
      result = with_temp_config do
        capture_output do |output|
          runner = configured_runner(output: output)
          runner.api_client.stub('conversations', data)
          exit_code = Teems::Commands::Chats.new([], runner: runner).execute
        end
      end
      result.merge(exit_code: exit_code)
    end

    def run_chats_with_error(path, message)
      exit_code = nil
      result = capture_output do |output|
        runner = configured_runner(output: output)
        runner.api_client.stub_error(path, Teems::ApiError.new(message))
        exit_code = Teems::Commands::Chats.new([], runner: runner).execute
      end
      result.merge(exit_code: exit_code)
    end

    def ngmsg_chat_data(overrides = {})
      base = { 'id' => '19:chat123@thread.v2',
               'threadProperties' => { 'topic' => 'Test Group', 'threadType' => 'chat',
                                       'createdat' => '2026-01-15T10:00:00Z' },
               'properties' => { 'lastimreceivedtime' => '2026-01-20T12:00:00Z' } }
      base.merge(overrides)
    end

    def unread_chat_data
      ngmsg_chat_data(
        'id' => '19:unread@thread.v2',
        'threadProperties' => { 'topic' => 'Unread Chat', 'threadType' => 'chat' },
        'properties' => { 'consumptionhorizon' => '1000;1000;user1' },
        'lastMessage' => { 'id' => '2000' }
      )
    end

    def read_chat_data
      ngmsg_chat_data(
        'id' => '19:read@thread.v2',
        'threadProperties' => { 'topic' => 'Read Chat', 'threadType' => 'chat' },
        'properties' => { 'consumptionhorizon' => '2000;2000;user1' },
        'lastMessage' => { 'id' => '2000' }
      )
    end

    def favorite_chat_data
      ngmsg_chat_data(
        'id' => '19:fav@thread.v2',
        'threadProperties' => { 'topic' => 'Fav Chat', 'threadType' => 'chat' },
        'properties' => { 'favorite' => 'true' }
      )
    end

    def pinned_chat_data
      ngmsg_chat_data(
        'id' => '19:pin@thread.v2',
        'threadProperties' => { 'topic' => 'Pinned Chat', 'threadType' => 'chat' },
        'properties' => { 'ispinned' => 'true' }
      )
    end
  end

  class BasicTest < Minitest::Test
    include Helpers

    def test_shows_help_with_help_flag
      result = run_chats(['--help'])
      assert_match(/teems chats/, result[:stdout])
      assert_match(/USAGE:/, result[:stdout])
      assert_match(/--json/, result[:stdout])
    end

    def test_requires_auth
      with_temp_config do
        result = capture_output do |output|
          store = mock_token_store(configured: false)
          runner = Teems::Runner.new(output: output, token_store: store)
          assert_equal 1, Teems::Commands::Chats.new([], runner: runner).execute
        end
        assert_match(/Not authenticated/, result[:stderr])
      end
    end

    def test_list_chats_success
      with_temp_config do
        result = run_chats_with_data('conversations' => [ngmsg_chat_data])
        assert_equal 0, result[:exit_code]
        assert_match(/Test Group/, result[:stdout])
        assert_match(/19:chat123@thread.v2/, result[:stdout])
      end
    end

    def test_empty_chats_list
      result = run_chats_with_data('conversations' => [])
      assert_equal 0, result[:exit_code]
      assert_match(/No chats found/, result[:stdout])
    end

    def test_api_error_returns_exit_code_one
      with_temp_config do
        result = run_chats_with_error('conversations', 'Network error')
        assert_equal 1, result[:exit_code]
        assert_match(/Failed to fetch chats/, result[:stderr])
      end
    end

    def test_json_output
      with_temp_config do
        result = run_chats_with_stub(['--json'], 'conversations', { 'value' => [sample_chat] })
        assert_equal 0, result[:exit_code]
        json = JSON.parse(result[:stdout])
        assert_instance_of Array, json
        assert_equal '19:chat123@thread.v2', json.first['id']
      end
    end
  end

  class DisplayTest < Minitest::Test
    include Helpers

    def test_type_icon_one_on_one
      data = sample_chat.merge('chatType' => 'oneOnOne')
      result = run_chats_with_stub([], 'conversations', { 'value' => [data] })
      assert_includes result[:stdout], "\u{1F464}"
    end

    def test_type_icon_group
      result = run_chats_with_stub([], 'conversations', { 'value' => [sample_chat] })
      assert_includes result[:stdout], "\u{1F465}"
    end

    def test_type_icon_meeting
      data = sample_chat.merge('chatType' => 'meeting')
      result = run_chats_with_stub([], 'conversations', { 'value' => [data] })
      assert_includes result[:stdout], "\u{1F4C5}"
    end

    def test_type_icon_unknown
      data = sample_chat.merge('chatType' => 'somethingNew')
      result = run_chats_with_stub([], 'conversations', { 'value' => [data] })
      assert_includes result[:stdout], "\u{1F4AC}"
    end

    def test_fetches_from_value_key
      result = run_chats_with_stub([], 'conversations', { 'value' => [sample_chat] })
      assert_equal 0, result[:exit_code]
      assert_match(/Project Discussion/, result[:stdout])
    end

    def test_last_updated_display
      result = run_chats_with_stub([], 'conversations', { 'value' => [sample_chat] })
      assert_match(/Last updated:/, result[:stdout])
    end

    def test_chat_without_last_updated
      data = sample_chat.dup
      data.delete('lastUpdatedDateTime')
      result = run_chats_with_stub([], 'conversations', { 'value' => [data] })
      refute_match(/Last updated:/, result[:stdout])
    end

    def test_json_output_with_nil_last_updated
      data = sample_chat.dup
      data.delete('lastUpdatedDateTime')
      result = run_chats_with_stub(['--json'], 'conversations', { 'value' => [data] })
      json = JSON.parse(result[:stdout])
      assert_nil json.first['last_updated']
    end

    def test_unread_chat_shows_asterisk
      with_temp_config do
        result = run_chats_with_data('conversations' => [unread_chat_data])
        assert_match(/\* .*Unread Chat/, result[:stdout])
      end
    end

    def test_read_chat_has_no_asterisk
      with_temp_config do
        result = run_chats_with_data('conversations' => [read_chat_data])
        refute_match(/\* .*Read Chat/, result[:stdout])
        assert_match(/Read Chat/, result[:stdout])
      end
    end
  end

  class FilterTest < Minitest::Test
    include Helpers

    def test_unread_filter_shows_only_unread
      with_temp_config do
        result = run_chats_with_filter(['--unread'], [unread_chat_data, read_chat_data])
        assert_match(/Unread Chat/, result[:stdout])
        refute_match(/Read Chat/, result[:stdout])
      end
    end

    def test_unread_filter_shows_no_chats_when_all_read
      with_temp_config do
        result = run_chats_with_filter(['--unread'], [read_chat_data])
        assert_match(/No chats found/, result[:stdout])
      end
    end

    def test_favorites_filter_shows_only_favorites
      with_temp_config do
        result = run_chats_with_filter(['--favorites'], [favorite_chat_data, ngmsg_chat_data])
        assert_match(/Fav Chat/, result[:stdout])
        refute_match(/Test Group/, result[:stdout])
      end
    end

    def test_pinned_filter_shows_only_pinned
      with_temp_config do
        result = run_chats_with_filter(['--pinned'], [pinned_chat_data, ngmsg_chat_data])
        assert_match(/Pinned Chat/, result[:stdout])
        refute_match(/Test Group/, result[:stdout])
      end
    end

    def test_json_includes_unread_favorite_pinned
      with_temp_config do
        result = run_chats_with_filter(['--json'], [unread_chat_data, favorite_chat_data])
        json = JSON.parse(result[:stdout])
        unread_item = json.find { |c| c['id'] == '19:unread@thread.v2' }
        fav_item = json.find { |c| c['id'] == '19:fav@thread.v2' }
        assert unread_item['unread']
        assert fav_item['favorite']
      end
    end

    def test_help_shows_filter_options
      result = run_chats(['--help'])
      assert_match(/--unread/, result[:stdout])
      assert_match(/--favorites/, result[:stdout])
      assert_match(/--pinned/, result[:stdout])
    end

    def test_filters_out_48_notifications_stream
      with_temp_config do
        notifications = { 'id' => '48:notifications', 'threadProperties' => { 'threadType' => 'chat' } }
        result = run_chats_with_filter([], [notifications, ngmsg_chat_data])
        refute_match(/48:notifications/, result[:stdout])
        assert_match(/Test Group/, result[:stdout])
      end
    end

    def test_channel_shows_team_prefix
      with_temp_config do
        space = { 'id' => '19:space1@thread.tacv2',
                  'threadProperties' => { 'threadType' => 'space', 'spaceThreadTopic' => 'My Team' } }
        channel = { 'id' => '19:chan1@thread.tacv2',
                    'threadProperties' => { 'threadType' => 'topic', 'topic' => 'General',
                                            'spaceId' => '19:space1@thread.tacv2' },
                    'properties' => {} }
        result = run_chats_with_filter([], [space, channel])
        assert_match(/My Team -> General/, result[:stdout])
      end
    end

    def test_space_shows_team_name
      with_temp_config do
        space = { 'id' => '19:space1@thread.tacv2',
                  'threadProperties' => { 'threadType' => 'space', 'spaceThreadTopic' => 'My Team' } }
        result = run_chats_with_filter([], [space])
        assert_match(/My Team/, result[:stdout])
        refute_match(/\bSpace\b/, result[:stdout])
      end
    end

    private

    def run_chats_with_filter(args, conversations)
      exit_code = nil
      result = with_temp_config do
        capture_output do |out|
          runner = configured_runner(output: out)
          runner.api_client.stub('conversations', { 'conversations' => conversations })
          exit_code = Teems::Commands::Chats.new(args, runner: runner).execute
        end
      end
      result.merge(exit_code: exit_code)
    end
  end
end
