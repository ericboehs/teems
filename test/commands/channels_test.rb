# frozen_string_literal: true

require 'test_helper'

# Tests for the channels command
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
        runner = unconfigured_runner(output: output)
        assert_equal 1, Teems::Commands::Channels.new([], runner: runner).execute
      end
      assert_match(/Not authenticated/, result[:stderr])
    end
  end

  def test_list_teams_success
    result = run_channels_with_teams([sample_team], [sample_channel])
    stdout = result[:stdout]
    assert_equal 0, result[:exit_code]
    assert_match(/Engineering Team/, stdout)
    assert_match(/General/, stdout)
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
    first_team = json.first
    assert_equal 'Engineering Team', first_team['name']
    assert_equal 1, first_team['channels'].length
  end

  def test_private_channel_icon
    private_channel = sample_channel.merge('membershipType' => 'private')
    result = run_channels_with_teams([sample_team], [private_channel])
    assert_includes result[:stdout], "\u{1F512}"
  end

  def test_channel_api_error_shows_inline_error
    with_temp_config do
      stdout = run_channels_with_error('Forbidden')[:stdout]
      assert_match(/Engineering Team/, stdout)
      assert_match(/Error:.*Forbidden/, stdout)
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
        stub_api(runner.api_client, 'joinedTeams' => teams, 'channels' => channels)
        exit_code = Teems::Commands::Channels.new(args, runner: runner).execute
      end
    end
    result.merge(exit_code: exit_code)
  end

  def stub_api(api, stubs) = stubs.each { |path, data| api.stub(path, { 'value' => data }) }

  def run_channels_with_error(message)
    capture_output do |output|
      runner = configured_runner(output: output)
      api = runner.api_client
      api.stub('joinedTeams', { 'value' => [sample_team] })
      api.stub_error('channels', Teems::ApiError.new(message))
      Teems::Commands::Channels.new([], runner: runner).execute
    end
  end
end
