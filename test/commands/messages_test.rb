# frozen_string_literal: true

require 'test_helper'

class MessagesCommandTest < Minitest::Test
  def test_requires_auth
    with_temp_config do
      result = capture_output do |output|
        store = mock_token_store(configured: false)
        runner = Teems::Runner.new(output: output, token_store: store)
        cmd = Teems::Commands::Messages.new(['19:abc@thread.v2'], runner: runner)
        cmd.execute
      end

      assert_match(/Not authenticated/, result[:stderr])
    end
  end

  def test_requires_target
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        cmd = Teems::Commands::Messages.new([], runner: runner)
        cmd.execute
      end

      assert_match(/Target required/, result[:stderr])
    end
  end

  def test_shows_help_with_help_flag
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        cmd = Teems::Commands::Messages.new(['--help'], runner: runner)
        cmd.execute
      end

      assert_match(/teems messages/, result[:stdout])
      assert_match(/USAGE:/, result[:stdout])
    end
  end

  def test_help_includes_url_example
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        cmd = Teems::Commands::Messages.new(['--help'], runner: runner)
        cmd.execute
      end

      assert_match(%r{https://teams.microsoft.com}, result[:stdout])
    end
  end

  def test_help_includes_team_option
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        cmd = Teems::Commands::Messages.new(['--help'], runner: runner)
        cmd.execute
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

class MessagesCommandUrlParsingTest < Minitest::Test
  def test_accepts_teams_url
    with_temp_config do
      runner = configured_runner
      runner.api_client.stub('messages', { 'messages' => [] })
      cmd = Teems::Commands::Messages.new(
        ['https://teams.microsoft.com/l/message/19:abc@thread.v2/123?context=%7B%22contextType%22%3A%22chat%22%7D'],
        runner: runner
      )

      result = cmd.execute

      assert_equal 0, result
    end
  end

  def test_extracts_conversation_id_from_url
    with_temp_config do
      runner = configured_runner
      runner.api_client.stub('messages', { 'messages' => [] })
      Teems::Commands::Messages.new(
        ['https://teams.microsoft.com/l/message/19:abc@thread.v2/123?context=%7B%22contextType%22%3A%22chat%22%7D'],
        runner: runner
      ).execute

      # Verify the API was called with the extracted conversation ID
      # Note: The conversation ID may be URL-encoded in the API path
      call = runner.api_client.calls.find { |c| c[:path].include?('messages') }
      assert call, 'Expected messages API to be called'
      # Check for either encoded or decoded form
      assert(call[:path].include?('19:abc@thread.v2') || call[:path].include?('19%3Aabc%40thread.v2'),
             "Expected path to contain conversation ID, got: #{call[:path]}")
    end
  end

  def test_extracts_team_id_from_channel_url
    with_temp_config do
      runner = configured_runner
      runner.api_client.stub('messages', { 'messages' => [] })
      url = 'https://teams.microsoft.com/l/message/19:abc@thread.tacv2/123?context=%7B%22contextType%22%3A%22channel%22%2C%22teamId%22%3A%22team-uuid%22%7D'
      cmd = Teems::Commands::Messages.new([url], runner: runner)
      cmd.execute

      # Team ID should have been set from URL
      assert_equal 'team-uuid', cmd.options[:team_id]
    end
  end

  def test_rejects_invalid_teams_url
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        cmd = Teems::Commands::Messages.new(
          ['https://teams.microsoft.com/l/invalid/path'],
          runner: runner
        )
        cmd.execute
      end

      assert_match(/Invalid Teams URL format/, result[:stderr])
    end
  end

  def test_rejects_non_teams_https_url
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        cmd = Teems::Commands::Messages.new(
          ['https://example.com/l/message/19:abc@thread.v2/123'],
          runner: runner
        )
        cmd.execute
      end

      assert_match(/Invalid Teams URL format/, result[:stderr])
    end
  end

  def test_regular_conversation_id_still_works
    with_temp_config do
      runner = configured_runner
      runner.api_client.stub('messages', { 'messages' => [] })
      cmd = Teems::Commands::Messages.new(['19:abc123@thread.v2'], runner: runner)

      result = cmd.execute

      assert_equal 0, result
    end
  end

  def test_url_with_verbose_shows_debug
    with_temp_config do
      err = StringIO.new
      output = Teems::Formatters::Output.new(err: err, color: false, verbose: true)
      runner = configured_runner(output: output)
      runner.api_client.stub('messages', { 'messages' => [] })
      cmd = Teems::Commands::Messages.new(
        ['-v', 'https://teams.microsoft.com/l/message/19:abc@thread.v2/123?context=%7B%22contextType%22%3A%22chat%22%7D'],
        runner: runner
      )
      cmd.execute

      assert_match(/Parsed URL/, err.string)
    end
  end
end
