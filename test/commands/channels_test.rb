# frozen_string_literal: true

require 'test_helper'

class ChannelsCommandTest < Minitest::Test
  def test_shows_help_with_help_flag
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        cmd = Teems::Commands::Channels.new(['--help'], runner: runner)
        cmd.execute
      end

      assert_match(/teems channels/, result[:stdout])
      assert_match(/USAGE:/, result[:stdout])
      assert_match(/--json/, result[:stdout])
    end
  end

  def test_requires_auth
    with_temp_config do
      result = capture_output do |output|
        store = mock_token_store(configured: false)
        runner = Teems::Runner.new(output: output, token_store: store)
        cmd = Teems::Commands::Channels.new([], runner: runner)
        exit_code = cmd.execute

        assert_equal 1, exit_code
      end

      assert_match(/Not authenticated/, result[:stderr])
    end
  end

  def test_list_teams_success
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        runner.api_client.stub('joinedTeams', { 'value' => [sample_team] })
        runner.api_client.stub('channels', { 'value' => [sample_channel] })
        cmd = Teems::Commands::Channels.new([], runner: runner)
        exit_code = cmd.execute

        assert_equal 0, exit_code
      end

      assert_match(/Engineering Team/, result[:stdout])
      assert_match(/General/, result[:stdout])
    end
  end

  def test_empty_teams_list
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        runner.api_client.stub('joinedTeams', { 'value' => [] })
        cmd = Teems::Commands::Channels.new([], runner: runner)
        exit_code = cmd.execute

        assert_equal 0, exit_code
      end

      assert_match(/No teams found/, result[:stdout])
    end
  end

  def test_api_error_returns_1
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        runner.api_client.stub_error('joinedTeams', Teems::ApiError.new('Network error'))
        cmd = Teems::Commands::Channels.new([], runner: runner)
        exit_code = cmd.execute

        assert_equal 1, exit_code
      end

      assert_match(/Failed to fetch teams/, result[:stderr])
    end
  end

  def test_json_output
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        runner.api_client.stub('joinedTeams', { 'value' => [sample_team] })
        runner.api_client.stub('channels', { 'value' => [sample_channel] })
        cmd = Teems::Commands::Channels.new(['--json'], runner: runner)
        exit_code = cmd.execute

        assert_equal 0, exit_code
      end

      json = JSON.parse(result[:stdout])
      assert_instance_of Array, json
      assert_equal 'Engineering Team', json.first['name']
      assert_equal 1, json.first['channels'].length
    end
  end

  def test_private_channel_icon
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        private_channel = sample_channel.merge('membershipType' => 'private')
        runner.api_client.stub('joinedTeams', { 'value' => [sample_team] })
        runner.api_client.stub('channels', { 'value' => [private_channel] })
        cmd = Teems::Commands::Channels.new([], runner: runner)
        cmd.execute
      end

      assert_includes result[:stdout], "\u{1F512}" # lock icon
    end
  end

  def test_channel_api_error_shows_inline_error
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        runner.api_client.stub('joinedTeams', { 'value' => [sample_team] })
        runner.api_client.stub_error('channels', Teems::ApiError.new('Forbidden'))
        cmd = Teems::Commands::Channels.new([], runner: runner)
        cmd.execute
      end

      assert_match(/Engineering Team/, result[:stdout])
      assert_match(/Error:.*Forbidden/, result[:stdout])
    end
  end

  def test_unknown_option_shows_error
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        cmd = Teems::Commands::Channels.new(['--bogus'], runner: runner)
        exit_code = cmd.execute

        assert_equal 1, exit_code
      end

      assert_match(/Unknown option/, result[:stderr])
    end
  end
end
