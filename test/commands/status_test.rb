# frozen_string_literal: true

require 'test_helper'

# Tests for the status command
module StatusCommandTests
  PRESENCE_DATA = {
    'availability' => 'Available', 'activity' => 'Available',
    'statusMessage' => nil
  }.freeze

  PRESENCE_WITH_MESSAGE = {
    'availability' => 'DoNotDisturb', 'activity' => 'DoNotDisturb',
    'statusMessage' => {
      'message' => { 'content' => 'Focus time', 'contentType' => 'text' },
      'expiryDateTime' => { 'dateTime' => '2026-03-19T16:00:00.0000000Z', 'timeZone' => 'UTC' }
    }
  }.freeze

  EXPIRED_PRESENCE = {
    'availability' => 'Available', 'activity' => 'Available',
    'statusMessage' => {
      'message' => { 'content' => 'Old status', 'contentType' => 'text' },
      'expiryDateTime' => { 'dateTime' => '2026-03-19T12:00:00.0000000Z', 'timeZone' => 'UTC' }
    }
  }.freeze

  PRESENCE_NO_EXPIRY = {
    'availability' => 'Available', 'activity' => 'Available',
    'statusMessage' => {
      'message' => { 'content' => 'Working remotely', 'contentType' => 'text' }
    }
  }.freeze

  PRESENCE_NIL_DATETIME = {
    'availability' => 'Available', 'activity' => 'Available',
    'statusMessage' => {
      'message' => { 'content' => 'Hello', 'contentType' => 'text' },
      'expiryDateTime' => { 'timeZone' => 'UTC' }
    }
  }.freeze

  PRESENCE_MINUTES_ONLY = {
    'availability' => 'Busy', 'activity' => 'Busy',
    'statusMessage' => {
      'message' => { 'content' => 'BRB', 'contentType' => 'text' },
      'expiryDateTime' => { 'dateTime' => '2026-03-19T15:45:00.0000000Z', 'timeZone' => 'UTC' }
    }
  }.freeze

  FROZEN_TIME = Time.utc(2026, 3, 19, 14, 0, 0).freeze

  # Shared helpers for running status commands
  module Helpers
    private

    def run_status(args = [])
      exit_code = nil
      result = capture_output do |output|
        runner = configured_runner(output: output)
        yield runner if block_given?
        exit_code = Teems::Commands::Status.new(args, runner: runner).execute
      end
      result.merge(exit_code: exit_code)
    end

    def run_status_capturing_runner(args = [])
      runner_ref = nil
      result = run_status(args) do |runner|
        runner_ref = runner
        yield runner if block_given?
      end
      [result, runner_ref]
    end

    def find_post_call(runner, path_fragment)
      runner.api_client.calls.find { |c| c[:method] == :post && c[:path].include?(path_fragment) }
    end
  end

  # Basic command tests
  class BasicTest < Minitest::Test
    include Helpers

    def test_shows_help_with_help_flag
      result = run_status(%w[--help])
      assert_match(/teems status/, result[:stdout])
      assert_match(/USAGE:/, result[:stdout])
      assert_equal 0, result[:exit_code]
    end

    def test_requires_auth
      with_temp_config do
        result = capture_output do |output|
          runner = unconfigured_runner(output: output)
          assert_equal 1, Teems::Commands::Status.new([], runner: runner).execute
        end
        assert_match(/Not authenticated/, result[:stderr])
      end
    end

    def test_unknown_option_shows_error
      with_temp_config do
        result = capture_output do |output|
          runner = configured_runner(output: output)
          assert_equal 1, Teems::Commands::Status.new(%w[--bogus], runner: runner).execute
        end
        assert_match(/Unknown option/, result[:stderr])
      end
    end

    def test_invalid_presence_shows_error
      result = run_status(%w[--presence invalid])
      assert_equal 1, result[:exit_code]
      assert_match(/Invalid presence/, result[:stderr])
      assert_match(/Valid values/, result[:stderr])
    end
  end

  # Tests for getting current status
  class GetStatusTest < Minitest::Test
    include Helpers

    def test_shows_availability
      result = run_status do |runner|
        runner.api_client.stub('/v1.0/me/presence', PRESENCE_DATA)
      end
      assert_equal 0, result[:exit_code]
      assert_match(/Availability: Available/, result[:stdout])
    end

    def test_shows_message_and_expiry
      Time.stub(:now, FROZEN_TIME) do
        result = run_status do |runner|
          runner.api_client.stub('/v1.0/me/presence', PRESENCE_WITH_MESSAGE)
        end
        assert_equal 0, result[:exit_code]
        assert_match(/Do Not Disturb/, result[:stdout])
        assert_match(/Focus time/, result[:stdout])
        assert_match(/expires in 2h/, result[:stdout])
      end
    end

    def test_no_status_message
      result = run_status do |runner|
        runner.api_client.stub('/v1.0/me/presence', PRESENCE_DATA)
      end
      refute_match(/Status:/, result[:stdout])
    end

    def test_json_output
      result = run_status(%w[--json]) do |runner|
        runner.api_client.stub('/v1.0/me/presence', PRESENCE_DATA)
      end
      assert_equal 0, result[:exit_code]
      json = JSON.parse(result[:stdout])
      assert_equal 'Available', json['availability']
    end

    def test_api_error
      result = run_status do |runner|
        runner.api_client.stub_error('/v1.0/me/presence', Teems::ApiError.new('Access forbidden', status_code: 403))
      end
      assert_equal 1, result[:exit_code]
      assert_match(/Status error:.*Access forbidden/, result[:stderr])
    end

    def test_expired_status_message
      Time.stub(:now, FROZEN_TIME) do
        result = run_status do |runner|
          runner.api_client.stub('/v1.0/me/presence', EXPIRED_PRESENCE)
        end
        assert_match(/expired/, result[:stdout])
      end
    end

    def test_dnd_label
      dnd_data = PRESENCE_DATA.merge('availability' => 'DoNotDisturb', 'activity' => 'DoNotDisturb')
      result = run_status do |runner|
        runner.api_client.stub('/v1.0/me/presence', dnd_data)
      end
      assert_match(/Do Not Disturb/, result[:stdout])
    end

    def test_activity_differs_from_availability
      data = PRESENCE_DATA.merge('availability' => 'Busy', 'activity' => 'InACall')
      result = run_status do |runner|
        runner.api_client.stub('/v1.0/me/presence', data)
      end
      assert_match(/Busy \(InACall\)/, result[:stdout])
    end
  end

  # Tests for status display edge cases (expiry formatting, missing fields)
  class DisplayEdgeCaseTest < Minitest::Test
    include Helpers

    def test_status_message_without_expiry
      result = run_status do |runner|
        runner.api_client.stub('/v1.0/me/presence', PRESENCE_NO_EXPIRY)
      end
      assert_match(/Working remotely/, result[:stdout])
      refute_match(/expires/, result[:stdout])
    end

    def test_expiry_without_datetime_field
      result = run_status do |runner|
        runner.api_client.stub('/v1.0/me/presence', PRESENCE_NIL_DATETIME)
      end
      assert_match(/Hello/, result[:stdout])
      refute_match(/expires/, result[:stdout])
    end

    def test_minutes_only_remaining
      frozen = Time.utc(2026, 3, 19, 15, 30, 0)
      Time.stub(:now, frozen) do
        result = run_status do |runner|
          runner.api_client.stub('/v1.0/me/presence', PRESENCE_MINUTES_ONLY)
        end
        assert_match(/expires in 15m/, result[:stdout])
        refute_match(/\dh/, result[:stdout])
      end
    end
  end

  # Tests for setting status message
  class SetStatusTest < Minitest::Test
    include Helpers

    def test_sets_message_only
      result, runner_ref = run_status_capturing_runner(['In a meeting'])
      assert_equal 0, result[:exit_code]
      assert_match(/Status set: In a meeting/, result[:stdout])
      call = find_post_call(runner_ref, 'setStatusMessage')
      assert call, 'Expected setStatusMessage API call'
      assert_equal 'In a meeting', call[:body].dig(:statusMessage, :message, :content)
    end

    def test_sets_message_with_duration
      frozen_time = Time.utc(2026, 3, 19, 12, 0, 0)
      Time.stub(:now, frozen_time) do
        result, runner_ref = run_status_capturing_runner(['Focus time', '2h'])
        assert_equal 0, result[:exit_code]
        assert_match(/Status set: Focus time \(2h\)/, result[:stdout])
        call = find_post_call(runner_ref, 'setStatusMessage')
        assert call[:body].dig(:statusMessage, :expiryDateTime), 'Expected expiryDateTime in body'
      end
    end

    def test_sets_message_with_presence
      result, runner_ref = run_status_capturing_runner(%w[Focus 2h --presence dnd])
      assert_equal 0, result[:exit_code]
      presence_call = find_post_call(runner_ref, 'setPresence')
      assert presence_call, 'Expected setPresence API call'
      assert_equal 'DoNotDisturb', presence_call[:body][:availability]
      assert_equal 'PT2H', presence_call[:body][:expirationDuration]
    end

    def test_sets_message_with_presence_default_duration
      result, runner_ref = run_status_capturing_runner(%w[Focus --presence dnd])
      assert_equal 0, result[:exit_code]
      presence_call = find_post_call(runner_ref, 'setPresence')
      assert presence_call, 'Expected setPresence API call'
      assert_equal 'PT4H', presence_call[:body][:expirationDuration]
    end

    def test_confirmation_output
      result = run_status(['Testing'])
      assert_match(/Status set: Testing/, result[:stdout])
    end

    def test_invalid_duration_ignored
      result = run_status(%w[Hello xyz])
      assert_equal 0, result[:exit_code]
      assert_match(/Status set: Hello/, result[:stdout])
      refute_match(/xyz/, result[:stdout])
    end
  end

  # Tests for clearing status
  class ClearStatusTest < Minitest::Test
    include Helpers

    def test_calls_clear_api
      result, runner_ref = run_status_capturing_runner(%w[clear])
      assert_equal 0, result[:exit_code]
      assert_match(/Status cleared/, result[:stdout])
      call = find_post_call(runner_ref, 'setStatusMessage')
      assert call, 'Expected setStatusMessage API call for clear'
      assert_equal '', call[:body].dig(:statusMessage, :message, :content)
    end

    def test_clear_with_presence
      result, runner_ref = run_status_capturing_runner(%w[clear --presence available])
      assert_equal 0, result[:exit_code]
      presence_call = find_post_call(runner_ref, 'setPresence')
      assert presence_call, 'Expected setPresence API call'
      assert_equal 'Available', presence_call[:body][:availability]
    end

    def test_clear_success_message
      result = run_status(%w[clear])
      assert_match(/Status cleared/, result[:stdout])
    end
  end

  # Tests for presence-only mode
  class PresenceOnlyTest < Minitest::Test
    include Helpers

    def test_sets_presence_without_text
      result, runner_ref = run_status_capturing_runner(%w[--presence away])
      assert_equal 0, result[:exit_code]
      assert_match(/Presence set: away/, result[:stdout])
      call = find_post_call(runner_ref, 'setPresence')
      assert call, 'Expected setPresence API call'
      assert_equal 'Away', call[:body][:availability]
      assert_equal 'PT4H', call[:body][:expirationDuration]
    end

    def test_presence_brb
      _result, runner_ref = run_status_capturing_runner(%w[--presence brb])
      call = find_post_call(runner_ref, 'setPresence')
      assert_equal 'BeRightBack', call[:body][:availability]
    end
  end

  # Tests for token refresh on unauthorized
  class TokenRefreshTest < Minitest::Test
    include Helpers

    def test_surfaces_unauthorized_error
      result = run_status do |runner|
        runner.api_client.stub_error(
          '/v1.0/me/presence',
          Teems::ApiError.new('Unauthorized', status_code: 401)
        )
      end
      assert_equal 1, result[:exit_code]
      assert_match(/Status error:/, result[:stderr])
    end
  end
end
