# frozen_string_literal: true

require 'test_helper'

class ChatsCommandTest < Minitest::Test
  def test_shows_help_with_help_flag
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        cmd = Teems::Commands::Chats.new(['--help'], runner: runner)
        cmd.execute
      end

      assert_match(/teems chats/, result[:stdout])
      assert_match(/USAGE:/, result[:stdout])
      assert_match(/--json/, result[:stdout])
    end
  end

  def test_requires_auth
    with_temp_config do
      result = capture_output do |output|
        store = mock_token_store(configured: false)
        runner = Teems::Runner.new(output: output, token_store: store)
        cmd = Teems::Commands::Chats.new([], runner: runner)
        exit_code = cmd.execute

        assert_equal 1, exit_code
      end

      assert_match(/Not authenticated/, result[:stderr])
    end
  end

  def test_list_chats_success
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        runner.api_client.stub('conversations', { 'conversations' => [ngmsg_chat_data] })
        cmd = Teems::Commands::Chats.new([], runner: runner)
        exit_code = cmd.execute

        assert_equal 0, exit_code
      end

      assert_match(/Test Group/, result[:stdout])
      assert_match(/19:chat123@thread.v2/, result[:stdout])
    end
  end

  def test_empty_chats_list
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        runner.api_client.stub('conversations', { 'conversations' => [] })
        cmd = Teems::Commands::Chats.new([], runner: runner)
        exit_code = cmd.execute

        assert_equal 0, exit_code
      end

      assert_match(/No chats found/, result[:stdout])
    end
  end

  def test_api_error_returns_1
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        runner.api_client.stub_error('conversations', Teems::ApiError.new('Network error'))
        cmd = Teems::Commands::Chats.new([], runner: runner)
        exit_code = cmd.execute

        assert_equal 1, exit_code
      end

      assert_match(/Failed to fetch chats/, result[:stderr])
    end
  end

  def test_json_output
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        runner.api_client.stub('conversations', { 'value' => [sample_chat] })
        cmd = Teems::Commands::Chats.new(['--json'], runner: runner)
        exit_code = cmd.execute

        assert_equal 0, exit_code
      end

      json = JSON.parse(result[:stdout])
      assert_instance_of Array, json
      assert_equal '19:chat123@thread.v2', json.first['id']
    end
  end

  def test_type_icon_one_on_one
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        data = sample_chat.merge('chatType' => 'oneOnOne')
        runner.api_client.stub('conversations', { 'value' => [data] })
        cmd = Teems::Commands::Chats.new([], runner: runner)
        cmd.execute
      end

      assert_includes result[:stdout], "\u{1F464}" # person icon
    end
  end

  def test_type_icon_group
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        runner.api_client.stub('conversations', { 'value' => [sample_chat] })
        cmd = Teems::Commands::Chats.new([], runner: runner)
        cmd.execute
      end

      assert_includes result[:stdout], "\u{1F465}" # group icon
    end
  end

  def test_type_icon_meeting
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        data = sample_chat.merge('chatType' => 'meeting')
        runner.api_client.stub('conversations', { 'value' => [data] })
        cmd = Teems::Commands::Chats.new([], runner: runner)
        cmd.execute
      end

      assert_includes result[:stdout], "\u{1F4C5}" # calendar icon
    end
  end

  def test_type_icon_unknown
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        data = sample_chat.merge('chatType' => 'somethingNew')
        runner.api_client.stub('conversations', { 'value' => [data] })
        cmd = Teems::Commands::Chats.new([], runner: runner)
        cmd.execute
      end

      assert_includes result[:stdout], "\u{1F4AC}" # speech bubble icon
    end
  end

  def test_fetches_from_value_key
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        runner.api_client.stub('conversations', { 'value' => [sample_chat] })
        cmd = Teems::Commands::Chats.new([], runner: runner)
        exit_code = cmd.execute

        assert_equal 0, exit_code
      end

      assert_match(/Project Discussion/, result[:stdout])
    end
  end

  def test_last_updated_display
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        runner.api_client.stub('conversations', { 'value' => [sample_chat] })
        cmd = Teems::Commands::Chats.new([], runner: runner)
        cmd.execute
      end

      assert_match(/Last updated:/, result[:stdout])
    end
  end

  def test_chat_without_last_updated
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        data = sample_chat.dup
        data.delete('lastUpdatedDateTime')
        runner.api_client.stub('conversations', { 'value' => [data] })
        cmd = Teems::Commands::Chats.new([], runner: runner)
        cmd.execute
      end

      refute_match(/Last updated:/, result[:stdout])
    end
  end

  def test_json_output_with_nil_last_updated
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        data = sample_chat.dup
        data.delete('lastUpdatedDateTime')
        runner.api_client.stub('conversations', { 'value' => [data] })
        cmd = Teems::Commands::Chats.new(['--json'], runner: runner)
        cmd.execute
      end

      json = JSON.parse(result[:stdout])
      assert_nil json.first['last_updated']
    end
  end

  private

  def ngmsg_chat_data
    {
      'id' => '19:chat123@thread.v2',
      'threadProperties' => {
        'topic' => 'Test Group',
        'threadType' => 'chat',
        'createdat' => '2026-01-15T10:00:00Z'
      },
      'properties' => {
        'lastimreceivedtime' => '2026-01-20T12:00:00Z'
      }
    }
  end
end
