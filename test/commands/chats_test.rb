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

    def ngmsg_chat_data
      { 'id' => '19:chat123@thread.v2',
        'threadProperties' => { 'topic' => 'Test Group', 'threadType' => 'chat',
                                'createdat' => '2026-01-15T10:00:00Z' },
        'properties' => { 'lastimreceivedtime' => '2026-01-20T12:00:00Z' } }
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
  end
end
