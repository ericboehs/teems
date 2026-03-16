# frozen_string_literal: true

require 'test_helper'

class ChannelsCommandTest < Minitest::Test
  def test_shows_help_with_help_flag
    stdout = run_channels(['--help'])[:stdout]

    assert_match(/teems channels/, stdout)
    assert_match(/USAGE:/, stdout)
    assert_match(/--json/, stdout)
  end

  def test_requires_auth
    with_temp_config do
      result = capture_output do |output|
        store = mock_unconfigured_store
        runner = Teems::Runner.new(output: output, token_store: store)
        assert_equal 1, Teems::Commands::Channels.new([], runner: runner).execute
      end

      assert_match(/Not authenticated/, result[:stderr])
    end
  end

  def test_list_teams_success
    result = run_channels_with_teams([sample_team], [sample_channel])

    assert_equal 0, result[:exit_code]
    assert_match(/Engineering Team/, result[:stdout])
    assert_match(/General/, result[:stdout])
  end

  def test_empty_teams_list
    result = run_channels_with_teams([], [])

    assert_equal 0, result[:exit_code]
    assert_match(/No teams found/, result[:stdout])
  end

  def test_api_error_returns_exit_code_one
    with_temp_config do
      exit_code = nil
      result = capture_output do |output|
        runner = configured_runner(output: output)
        runner.api_client.stub_error('joinedTeams', Teems::ApiError.new('Network error'))
        exit_code = Teems::Commands::Channels.new([], runner: runner).execute
      end

      assert_equal 1, exit_code
      assert_match(/Failed to fetch teams/, result[:stderr])
    end
  end

  def test_json_output
    result = run_channels_with_teams([sample_team], [sample_channel], args: ['--json'])

    assert_equal 0, result[:exit_code]
    json = JSON.parse(result[:stdout])
    assert_instance_of Array, json
    assert_equal 'Engineering Team', json.first['name']
    assert_equal 1, json.first['channels'].length
  end

  def test_private_channel_icon
    private_channel = sample_channel.merge('membershipType' => 'private')
    result = run_channels_with_teams([sample_team], [private_channel])
    assert_includes result[:stdout], "\u{1F512}"
  end

  def test_channel_api_error_shows_inline_error
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        runner.api_client.stub('joinedTeams', { 'value' => [sample_team] })
        runner.api_client.stub_error('channels', Teems::ApiError.new('Forbidden'))
        Teems::Commands::Channels.new([], runner: runner).execute
      end

      assert_match(/Engineering Team/, result[:stdout])
      assert_match(/Error:.*Forbidden/, result[:stdout])
    end
  end

  def test_unknown_option_shows_error
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        assert_equal 1, Teems::Commands::Channels.new(['--bogus'], runner: runner).execute
      end

      assert_match(/Unknown option/, result[:stderr])
    end
  end

  private

  def run_channels(args = [])
    with_temp_config do
      capture_output do |output|
        runner = configured_runner(output: output)
        Teems::Commands::Channels.new(args, runner: runner).execute
      end
    end
  end

  def run_channels_with_teams(teams, channels, args: [])
    exit_code = nil
    result = with_temp_config do
      capture_output do |output|
        runner = configured_runner(output: output)
        runner.api_client.stub('joinedTeams', { 'value' => teams })
        runner.api_client.stub('channels', { 'value' => channels })
        exit_code = Teems::Commands::Channels.new(args, runner: runner).execute
      end
    end
    result.merge(exit_code: exit_code)
  end
end
