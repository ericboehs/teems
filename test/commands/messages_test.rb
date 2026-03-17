# frozen_string_literal: true

require 'test_helper'

# Tests for the messages command
module MessagesCommandTests
  # Shared helpers for running message commands
  module Helpers
    def run_messages(args, stubs: {})
      out = StringIO.new
      err = StringIO.new
      with_temp_config do
        output = Teems::Formatters::Output.new(io: out, err: err, color: false)
        runner = configured_runner(output: output)
        stubs.each { |path, resp| runner.api_client.stub(path, resp) }
        Teems::Commands::Messages.new(args, runner: runner).execute
      end
      { stdout: out.string, stderr: err.string }
    end

    def run_messages_with_url(url)
      with_temp_config do
        runner = configured_runner
        runner.api_client.stub('messages', { 'messages' => [] })
        Teems::Commands::Messages.new([url], runner: runner).execute
        runner
      end
    end
  end

  # Tests for auth, target requirement, and help display
  class BasicTest < Minitest::Test
    def test_requires_auth
      with_temp_config do
        result = capture_output do |output|
          store = mock_unconfigured_store
          runner = Teems::Runner.new(output: output, token_store: store)
          Teems::Commands::Messages.new(['19:abc@thread.v2'], runner: runner).execute
        end
        assert_match(/Not authenticated/, result[:stderr])
      end
    end

    def test_requires_target
      with_temp_config do
        result = capture_output do |output|
          runner = configured_runner(output: output)
          Teems::Commands::Messages.new([], runner: runner).execute
        end
        assert_match(/Target required/, result[:stderr])
      end
    end

    def test_shows_help_with_help_flag
      with_temp_config do
        result = capture_output do |output|
          runner = configured_runner(output: output)
          Teems::Commands::Messages.new(['--help'], runner: runner).execute
        end
        stdout = result[:stdout]
        assert_match(/teems messages/, stdout)
        assert_match(/USAGE:/, stdout)
      end
    end

    def test_help_includes_url_example
      with_temp_config do
        result = capture_output do |output|
          runner = configured_runner(output: output)
          Teems::Commands::Messages.new(['--help'], runner: runner).execute
        end
        assert_match(%r{https://teams.microsoft.com}, result[:stdout])
      end
    end

    def test_help_includes_team_option
      with_temp_config do
        result = capture_output do |output|
          runner = configured_runner(output: output)
          Teems::Commands::Messages.new(['--help'], runner: runner).execute
        end
        assert_match(/--team/, result[:stdout])
      end
    end

    def test_parses_team_option_short
      with_temp_config do
        runner = configured_runner
        cmd = Teems::Commands::Messages.new(['-t', 'team-123', '19:abc@thread.v2'], runner: runner)
        assert_equal 'team-123', cmd.options[:team_id]
      end
    end

    def test_parses_team_option_long
      with_temp_config do
        runner = configured_runner
        cmd = Teems::Commands::Messages.new(['--team', 'team-456', '19:abc@thread.v2'], runner: runner)
        assert_equal 'team-456', cmd.options[:team_id]
      end
    end
  end

  # Tests for parsing Teams URLs and extracting conversation IDs
  class UrlParsingTest < Minitest::Test
    include Helpers

    def test_accepts_teams_url
      with_temp_config do
        runner = configured_runner
        runner.api_client.stub('messages', { 'messages' => [] })
        cmd = Teems::Commands::Messages.new(
          ['https://teams.microsoft.com/l/message/19:abc@thread.v2/123?context=%7B%22contextType%22%3A%22chat%22%7D'],
          runner: runner
        )
        assert_equal 0, cmd.execute
      end
    end

    def test_extracts_conversation_id_from_url
      url = 'https://teams.microsoft.com/l/message/19:abc@thread.v2/123?context=%7B%22contextType%22%3A%22chat%22%7D'
      runner = run_messages_with_url(url)
      call = runner.api_client.calls.find { |call_entry| call_entry[:path].include?('messages') }
      assert call, 'Expected messages API to be called'
      call_path = call[:path]
      conv_id_present = call_path.include?('19:abc@thread.v2') || call_path.include?('19%3Aabc%40thread.v2')
      assert conv_id_present, "Expected path to contain conversation ID, got: #{call_path}"
    end

    def test_extracts_team_id_from_channel_url
      with_temp_config do
        runner = configured_runner
        runner.api_client.stub('messages', { 'messages' => [] })
        url = 'https://teams.microsoft.com/l/message/19:abc@thread.tacv2/123?context=%7B%22contextType%22%3A%22channel%22%2C%22teamId%22%3A%22team-uuid%22%7D'
        cmd = Teems::Commands::Messages.new([url], runner: runner)
        cmd.execute
        assert_equal 'team-uuid', cmd.options[:team_id]
      end
    end

    def test_rejects_invalid_teams_url
      result = run_messages(['https://teams.microsoft.com/l/invalid/path'])
      assert_match(/Invalid Teams URL format/, result[:stderr])
    end

    def test_rejects_non_teams_https_url
      result = run_messages(['https://example.com/l/message/19:abc@thread.v2/123'])
      assert_match(/Invalid Teams URL format/, result[:stderr])
    end

    def test_regular_conversation_id_still_works
      with_temp_config do
        runner = configured_runner
        runner.api_client.stub('messages', { 'messages' => [] })
        cmd = Teems::Commands::Messages.new(['19:abc123@thread.v2'], runner: runner)
        assert_equal 0, cmd.execute
      end
    end

    def test_url_with_verbose_shows_debug
      with_temp_config do
        err = StringIO.new
        output = Teems::Formatters::Output.new(err: err, color: false, mode: :verbose)
        runner = configured_runner(output: output)
        runner.api_client.stub('messages', { 'messages' => [] })
        url = 'https://teams.microsoft.com/l/message/19:abc@thread.v2/123?context=%7B%22contextType%22%3A%22chat%22%7D'
        Teems::Commands::Messages.new(['-v', url], runner: runner).execute
        assert_match(/Parsed URL/, err.string)
      end
    end
  end

  # Tests for message display formatting and JSON output
  class DisplayTest < Minitest::Test
    include Helpers

    def test_json_output
      result = run_messages(['--json', '19:abc@thread.v2'],
                            stubs: { 'messages' => { 'messages' => [sample_ng_msg_message] } })
      json = JSON.parse(result[:stdout])
      assert_instance_of Array, json
      assert_equal 'Jane Smith', json.first['sender_name']
    end

    def test_displays_reactions
      with_temp_config do
        result = capture_output do |output|
          runner = configured_runner(output: output)
          runner.api_client.stub('messages', { 'messages' => [sample_ng_msg_message] })
          Teems::Commands::Messages.new(['19:abc@thread.v2'], runner: runner).execute
        end
        assert_match(/like/, result[:stdout])
      end
    end

    def test_displays_important_marker
      with_temp_config do
        msg = sample_graph_message.merge('importance' => 'urgent')
        result = capture_output do |output|
          runner = configured_runner(output: output)
          runner.api_client.stub('messages', { 'messages' => [msg] })
          Teems::Commands::Messages.new(['19:abc@thread.v2'], runner: runner).execute
        end
        assert_match(/!/, result[:stdout])
      end
    end

    def test_no_messages_found
      with_temp_config do
        result = capture_output do |output|
          runner = configured_runner(output: output)
          runner.api_client.stub('messages', { 'messages' => [] })
          cmd = Teems::Commands::Messages.new(['19:abc@thread.v2'], runner: runner)
          assert_equal 0, cmd.execute
        end
        assert_match(/No messages found/, result[:stdout])
      end
    end

    def test_response_key_posts
      with_temp_config do
        result = capture_output do |output|
          runner = configured_runner(output: output)
          runner.api_client.stub('messages', { 'posts' => [sample_ng_msg_message] })
          cmd = Teems::Commands::Messages.new(['19:abc@thread.v2'], runner: runner)
          assert_equal 0, cmd.execute
        end
        assert_match(/Jane Smith/, result[:stdout])
      end
    end

    def test_response_key_value
      with_temp_config do
        result = capture_output do |output|
          runner = configured_runner(output: output)
          runner.api_client.stub('messages', { 'value' => [sample_ng_msg_message] })
          cmd = Teems::Commands::Messages.new(['19:abc@thread.v2'], runner: runner)
          assert_equal 0, cmd.execute
        end
        assert_match(/Jane Smith/, result[:stdout])
      end
    end

    def test_unknown_option_shows_error
      with_temp_config do
        result = capture_output do |output|
          runner = configured_runner(output: output)
          cmd = Teems::Commands::Messages.new(['--bogus', '19:abc@thread.v2'], runner: runner)
          assert_equal 1, cmd.execute
        end
        assert_match(/Unknown option/, result[:stderr])
      end
    end
  end

  # Tests for channel messages, API errors, system message filtering, and edge cases
  class DisplayExtendedTest < Minitest::Test
    include Helpers

    def test_fetch_channel_messages_with_team_id
      with_temp_config do
        result = capture_output do |output|
          runner = configured_runner(output: output)
          runner.api_client.stub('messages', { 'messages' => [sample_ng_msg_message] })
          cmd = Teems::Commands::Messages.new(['-t', 'team-123', '19:ch@thread.tacv2'], runner: runner)
          assert_equal 0, cmd.execute
        end
        assert_match(/Jane Smith/, result[:stdout])
      end
    end

    def test_api_error_returns_error_code
      with_temp_config do
        result = capture_output do |output|
          runner = configured_runner(output: output)
          runner.api_client.stub_error('messages', Teems::ApiError.new('Network error'))
          cmd = Teems::Commands::Messages.new(['19:abc@thread.v2'], runner: runner)
          assert_equal 1, cmd.execute
        end
        assert_match(/Failed to fetch/, result[:stderr])
      end
    end

    def test_channel_api_error_returns_error_code
      with_temp_config do
        result = capture_output do |output|
          runner = configured_runner(output: output)
          runner.api_client.stub_error('messages', Teems::ApiError.new('Network error'))
          cmd = Teems::Commands::Messages.new(['-t', 'team-1', '19:ch@thread.tacv2'], runner: runner)
          assert_equal 1, cmd.execute
        end
        assert_match(/Failed to fetch channel messages/, result[:stderr])
      end
    end

    def test_filters_system_messages
      with_temp_config do
        result = capture_output do |output|
          runner = configured_runner(output: output)
          runner.api_client.stub('messages', { 'messages' => [sample_system_message, sample_ng_msg_message] })
          Teems::Commands::Messages.new(['19:abc@thread.v2'], runner: runner).execute
        end
        stdout = result[:stdout]
        refute_match(/AddMember/, stdout)
        assert_match(/Jane Smith/, stdout)
      end
    end

    def test_message_without_reactions
      with_temp_config do
        result = capture_output do |output|
          runner = configured_runner(output: output)
          runner.api_client.stub('messages', { 'messages' => [sample_graph_message] })
          Teems::Commands::Messages.new(['19:abc@thread.v2'], runner: runner).execute
        end
        assert_match(/John Doe/, result[:stdout])
      end
    end

    def test_message_nil_created_at_display
      msg = sample_graph_message.dup.tap { |msg_data| msg_data.delete('createdDateTime') }
      result = run_messages(['19:abc@thread.v2'], stubs: { 'messages' => { 'messages' => [msg] } })
      assert_match(/John Doe/, result[:stdout])
    end

    def test_json_output_with_nil_created_at
      msg = sample_graph_message.dup.tap { |msg_data| msg_data.delete('createdDateTime') }
      result = run_messages(['--json', '19:abc@thread.v2'], stubs: { 'messages' => { 'messages' => [msg] } })
      json = JSON.parse(result[:stdout])
      assert_nil json.first['created_at']
    end
  end
end
