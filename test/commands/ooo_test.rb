# frozen_string_literal: true

require 'test_helper'

module OooCommandTests
  AUTO_REPLY_ENABLED = {
    'status' => 'alwaysEnabled',
    'internalReplyMessage' => '<p>I am out of office.</p>',
    'externalReplyMessage' => 'Thank you for your message.',
    'externalAudience' => 'all'
  }.freeze

  AUTO_REPLY_SCHEDULED = {
    'status' => 'scheduled',
    'internalReplyMessage' => 'OOO until Monday.',
    'scheduledStartDateTime' => { 'dateTime' => '2026-04-14T00:00:00', 'timeZone' => 'UTC' },
    'scheduledEndDateTime' => { 'dateTime' => '2026-04-18T23:59:59', 'timeZone' => 'UTC' }
  }.freeze

  AUTO_REPLY_DISABLED = { 'status' => 'disabled' }.freeze

  PRESENCE_DATA = {
    'availability' => 'Offline', 'activity' => 'OffWork',
    'statusMessage' => { 'message' => { 'content' => 'Out of Office' } }
  }.freeze

  module Helpers
    include Teems::TestHelpers

    private

    def run_ooo(args, config_ooo: nil)
      with_temp_config do |dir|
        write_ooo_config(dir, config_ooo) if config_ooo
        capture_output do |output|
          runner = configured_runner(output: output)
          stub_ooo_apis(runner)
          Teems::Commands::Ooo.new(args, runner: runner).execute
        end
      end
    end

    def run_ooo_runner(args, config_ooo: nil)
      with_temp_config do |dir|
        write_ooo_config(dir, config_ooo) if config_ooo
        runner = configured_runner
        stub_ooo_apis(runner)
        Teems::Commands::Ooo.new(args, runner: runner).execute
        return runner
      end
    end

    def run_ooo_status(reply_data, presence_error: false, presence_data: PRESENCE_DATA)
      with_temp_config do
        capture_output do |output|
          runner = configured_runner(output: output)
          stub_status_apis(runner, reply_data, presence_error, presence_data)
          Teems::Commands::Ooo.new([], runner: runner).execute
        end
      end
    end

    def with_tz(zone)
      original_tz = ENV.fetch('TZ', nil)
      zone ? ENV['TZ'] = zone : ENV.delete('TZ')
      yield
    ensure
      original_tz ? ENV['TZ'] = original_tz : ENV.delete('TZ')
    end

    def stub_status_apis(runner, reply_data, presence_error, presence_data)
      runner.api_client.stub('/v1.0/me/mailboxSettings/automaticRepliesSetting', reply_data)
      if presence_error
        runner.api_client.stub_error('/v1.0/me/presence',
                                     Teems::ApiError.new('Forbidden', status_code: 403))
      else
        runner.api_client.stub('/v1.0/me/presence', presence_data)
      end
    end

    def stub_ooo_apis(runner)
      api = runner.api_client
      api.stub('/v1.0/me/mailboxSettings/automaticRepliesSetting', AUTO_REPLY_DISABLED)
      api.stub('/v1.0/me/mailboxSettings', {})
      api.stub('/v1.0/me/presence', PRESENCE_DATA)
      api.stub('/v1.0/me/presence/setStatusMessage', {})
      api.stub('/v1.0/me/presence/setPresence', {})
      api.stub('/v1.0/me/presence/clearPresence', {})
      api.stub('/v1.0/me/events', sample_event_data)
    end

    def write_ooo_config(dir, ooo_data)
      teems_dir = File.join(dir, 'teems')
      FileUtils.mkdir_p(teems_dir)
      config_path = File.join(teems_dir, 'config.json')
      data = File.exist?(config_path) ? JSON.parse(File.read(config_path)) : {}
      data['ooo'] = ooo_data
      File.write(config_path, JSON.generate(data))
    end

    def sample_event_data
      { 'id' => 'event-1', 'subject' => 'OOO', 'start' => { 'dateTime' => '2026-04-10T00:00:00' },
        'end' => { 'dateTime' => '2026-04-11T00:00:00' }, 'isAllDay' => true,
        'organizer' => { 'emailAddress' => { 'name' => 'Test', 'address' => 'test@test.com' } },
        'attendees' => [], 'location' => { 'displayName' => '' } }
    end

    def run_ooo_with_error(args, error_path, config_ooo: nil)
      with_temp_config do |dir|
        write_ooo_config(dir, config_ooo) if config_ooo
        capture_output do |output|
          runner = configured_runner(output: output)
          stub_ooo_apis(runner)
          runner.api_client.stub_error(error_path, Teems::ApiError.new('Error', status_code: 403))
          Teems::Commands::Ooo.new(args, runner: runner).execute
        end
      end
    end

    def run_ooo_with_dual_errors
      with_temp_config do
        capture_output do |output|
          runner = configured_runner(output: output)
          err = Teems::ApiError.new('Forbidden', status_code: 403)
          runner.api_client.stub_error('/v1.0/me/mailboxSettings/automaticRepliesSetting', err)
          runner.api_client.stub_error('/v1.0/me/presence', err)
          Teems::Commands::Ooo.new([], runner: runner).execute
        end
      end
    end
  end

  # Tests for OOO status display
  class ShowStatusTest < Minitest::Test
    include Helpers

    def test_show_status_displays_auto_reply_status
      result = run_ooo([])
      assert_match(/Auto-replies: disabled/, result[:stdout])
    end

    def test_show_status_displays_presence
      result = run_ooo([])
      assert_match(/Presence: Offline/, result[:stdout])
    end

    def test_show_status_json
      result = run_ooo(['--json'])
      parsed = JSON.parse(result[:stdout])
      assert parsed.key?('auto_replies')
      assert parsed.key?('presence')
    end

    def test_show_status_with_scheduled_replies
      result = with_tz('UTC') { run_ooo_status(AUTO_REPLY_SCHEDULED) }
      assert_match(/scheduled/, result[:stdout])
      assert_match(/2026-04-14 00:00 to 2026-04-18 23:59 UTC/, result[:stdout])
    end

    def test_show_status_converts_utc_schedule_to_local
      result = with_tz('America/Chicago') { run_ooo_status(AUTO_REPLY_SCHEDULED) }
      assert_match(/2026-04-13 19:00 to 2026-04-18 18:59 CT/, result[:stdout])
    end

    def test_show_status_with_reply_message
      result = with_temp_config do
        capture_output do |output|
          runner = configured_runner(output: output)
          runner.api_client.stub('/v1.0/me/mailboxSettings/automaticRepliesSetting', AUTO_REPLY_ENABLED)
          runner.api_client.stub('/v1.0/me/presence', PRESENCE_DATA)
          Teems::Commands::Ooo.new([], runner: runner).execute
        end
      end
      assert_match(/Message: I am out of office/, result[:stdout])
    end

    def test_show_status_with_nil_presence
      result = run_ooo_status(AUTO_REPLY_DISABLED, presence_error: true)
      assert_match(/Auto-replies: disabled/, result[:stdout])
      refute_match(/Presence/, result[:stdout])
    end

    def test_show_status_without_schedule_data
      no_schedule = AUTO_REPLY_ENABLED.reject { |k, _| k.start_with?('scheduled') }
      result = run_ooo_status(no_schedule)
      assert_match(/alwaysEnabled/, result[:stdout])
      refute_match(/Schedule/, result[:stdout])
    end

    def test_show_status_presence_without_status_message
      presence_no_msg = { 'availability' => 'Available', 'activity' => 'Available' }
      result = run_ooo_status(AUTO_REPLY_DISABLED, presence_data: presence_no_msg)
      assert_match(/Presence: Available/, result[:stdout])
      refute_match(/Status:/, result[:stdout])
    end

    def test_show_status_handles_auto_reply_forbidden
      result = with_temp_config do
        capture_output do |output|
          runner = configured_runner(output: output)
          runner.api_client.stub_error('/v1.0/me/mailboxSettings/automaticRepliesSetting',
                                       Teems::ApiError.new('Forbidden', status_code: 403))
          runner.api_client.stub('/v1.0/me/presence', PRESENCE_DATA)
          Teems::Commands::Ooo.new([], runner: runner).execute
        end
      end
      assert_match(/permission denied/, result[:stdout])
    end
  end

  # Tests for enabling OOO
  class EnableTest < Minitest::Test
    include Helpers

    def test_enable_ooo_sets_auto_reply
      runner = run_ooo_runner(['on'])
      calls = runner.api_client.calls
      patch_call = calls.find { |c| c[:path] == '/v1.0/me/mailboxSettings' }
      assert patch_call
      assert_equal :patch, patch_call[:method]
      settings = patch_call[:body][:automaticRepliesSetting]
      assert_equal 'alwaysEnabled', settings[:status]
    end

    def test_enable_ooo_sets_status_message
      runner = run_ooo_runner(['on'])
      calls = runner.api_client.calls
      status_call = calls.find { |c| c[:path].include?('setStatusMessage') }
      assert status_call
      assert_equal 'Out of Office', status_call[:body][:statusMessage][:message][:content]
    end

    def test_enable_ooo_sets_presence_offline
      runner = run_ooo_runner(['on'])
      calls = runner.api_client.calls
      presence_call = calls.find { |c| c[:path].include?('setPresence') }
      assert presence_call
      assert_equal 'Offline', presence_call[:body][:availability]
    end

    def test_enable_with_custom_message
      runner = run_ooo_runner(['on', '--message', 'On vacation'])
      calls = runner.api_client.calls
      patch_call = calls.find { |c| c[:path] == '/v1.0/me/mailboxSettings' }
      assert_equal 'On vacation', patch_call[:body][:automaticRepliesSetting][:internalReplyMessage]
    end

    def test_enable_with_schedule
      runner = run_ooo_runner(['on', '--start', '2026-04-14', '--end', '2026-04-18'])
      calls = runner.api_client.calls
      patch_call = calls.find { |c| c[:path] == '/v1.0/me/mailboxSettings' }
      settings = patch_call[:body][:automaticRepliesSetting]
      assert_equal 'scheduled', settings[:status]
      assert_includes settings[:scheduledStartDateTime][:dateTime], '2026-04-14T00:00:00'
      assert_includes settings[:scheduledEndDateTime][:dateTime], '2026-04-18T23:59:59'
    end

    def test_enable_with_config_message
      ooo_config = { 'internal_message' => 'Config OOO', 'status_message' => 'Config Status' }
      runner = run_ooo_runner(['on'], config_ooo: ooo_config)
      calls = runner.api_client.calls
      patch_call = calls.find { |c| c[:path] == '/v1.0/me/mailboxSettings' }
      assert_equal 'Config OOO', patch_call[:body][:automaticRepliesSetting][:internalReplyMessage]
    end

    def test_enable_creates_event_with_event_flag
      ooo_config = { 'notify' => ['mgr@test.com'] }
      runner = run_ooo_runner(['on', '--event'], config_ooo: ooo_config)
      calls = runner.api_client.calls
      event_call = calls.find { |c| c[:path] == '/v1.0/me/events' }
      assert event_call
      assert_equal 'free', event_call[:body][:showAs]
      assert_equal 'mgr@test.com', event_call[:body][:attendees].first[:emailAddress][:address]
    end

    def test_enable_skips_event_by_default
      ooo_config = { 'notify' => ['mgr@test.com'] }
      runner = run_ooo_runner(['on'], config_ooo: ooo_config)
      calls = runner.api_client.calls
      event_call = calls.find { |c| c[:path] == '/v1.0/me/events' }
      assert_nil event_call
    end

    def test_enable_skips_event_without_notify_even_with_flag
      runner = run_ooo_runner(['on', '--event'])
      calls = runner.api_client.calls
      event_call = calls.find { |c| c[:path] == '/v1.0/me/events' }
      assert_nil event_call
    end

    def test_invite_option_overrides_config_notify_list
      ooo_config = { 'notify' => ['mgr@test.com'] }
      runner = run_ooo_runner(['on', '--event', '--invite', 'a@test.com,b@test.com'], config_ooo: ooo_config)
      event_call = runner.api_client.calls.find { |c| c[:path] == '/v1.0/me/events' }
      attendee_emails = event_call[:body][:attendees].map { |a| a[:emailAddress][:address] }
      assert_equal %w[a@test.com b@test.com], attendee_emails
    end

    def test_invite_option_without_config_creates_event
      runner = run_ooo_runner(['on', '--event', '--invite', 'alex@example.com'])
      event_call = runner.api_client.calls.find { |c| c[:path] == '/v1.0/me/events' }
      assert event_call
      assert_equal 'alex@example.com', event_call[:body][:attendees].first[:emailAddress][:address]
    end

    def test_enable_skips_status_with_no_status_flag
      runner = run_ooo_runner(['on', '--no-status'])
      calls = runner.api_client.calls
      status_call = calls.find { |c| c[:path].include?('setStatusMessage') }
      assert_nil status_call
    end

    def test_enable_reports_success
      result = run_ooo(['on'])
      assert_match(/Auto-reply enabled/, result[:stdout])
    end
  end

  # Tests for timed (non-all-day) OOO schedules
  class TimedScheduleTest < Minitest::Test
    include Helpers

    def test_timed_schedule_sets_exact_auto_reply_times
      runner = run_ooo_runner(['on', '--start', '2026-04-20 14:00', '--end', '2026-04-20 17:00'])
      patch_call = runner.api_client.calls.find { |c| c[:path] == '/v1.0/me/mailboxSettings' }
      settings = patch_call[:body][:automaticRepliesSetting]
      assert_equal 'scheduled', settings[:status]
      assert_equal '2026-04-20T14:00:00', settings[:scheduledStartDateTime][:dateTime]
      assert_equal '2026-04-20T17:00:00', settings[:scheduledEndDateTime][:dateTime]
    end

    def test_today_time_schedule_resolves_to_today
      runner = run_ooo_runner(['on', '--start', 'today 14:00', '--end', 'today 17:00'])
      patch_call = runner.api_client.calls.find { |c| c[:path] == '/v1.0/me/mailboxSettings' }
      settings = patch_call[:body][:automaticRepliesSetting]
      today = Date.today.strftime('%Y-%m-%d')
      assert_equal "#{today}T14:00:00", settings[:scheduledStartDateTime][:dateTime]
      assert_equal "#{today}T17:00:00", settings[:scheduledEndDateTime][:dateTime]
    end

    def test_timed_schedule_creates_timed_event
      ooo_config = { 'notify' => ['mgr@test.com'] }
      runner = run_ooo_runner(
        ['on', '--event', '--start', '2026-04-20 14:00', '--end', '2026-04-20 17:00'],
        config_ooo: ooo_config
      )
      event_call = runner.api_client.calls.find { |c| c[:path] == '/v1.0/me/events' }
      assert_equal false, event_call[:body][:isAllDay]
      assert_equal '2026-04-20T14:00:00', event_call[:body][:start][:dateTime]
      assert_equal '2026-04-20T17:00:00', event_call[:body][:end][:dateTime]
    end

    def test_date_schedule_still_creates_all_day_event
      ooo_config = { 'notify' => ['mgr@test.com'] }
      runner = run_ooo_runner(
        ['on', '--event', '--start', '2026-04-14', '--end', '2026-04-14'],
        config_ooo: ooo_config
      )
      event_call = runner.api_client.calls.find { |c| c[:path] == '/v1.0/me/events' }
      assert_equal true, event_call[:body][:isAllDay]
      assert_equal '2026-04-14T00:00:00', event_call[:body][:start][:dateTime]
      assert_equal '2026-04-15T00:00:00', event_call[:body][:end][:dateTime]
    end
  end

  # Tests for disabling OOO
  class DisableTest < Minitest::Test
    include Helpers

    def test_disable_sets_auto_reply_disabled
      runner = run_ooo_runner(['off'])
      calls = runner.api_client.calls
      patch_call = calls.find { |c| c[:path] == '/v1.0/me/mailboxSettings' }
      assert_equal 'disabled', patch_call[:body][:automaticRepliesSetting][:status]
    end

    def test_disable_clears_status_and_presence
      runner = run_ooo_runner(['off'])
      calls = runner.api_client.calls
      assert(calls.any? { |c| c[:path].include?('setStatusMessage') })
      assert(calls.any? { |c| c[:path].include?('clearPresence') })
    end

    def test_disable_with_no_status_skips_presence
      runner = run_ooo_runner(['off', '--no-status'])
      calls = runner.api_client.calls
      refute(calls.any? { |c| c[:path].include?('clearPresence') })
    end

    def test_disable_reports_success
      result = run_ooo(['off'])
      assert_match(/Auto-reply disabled/, result[:stdout])
      assert_match(/Status and presence cleared/, result[:stdout])
    end
  end

  # Tests for config display
  class ConfigTest < Minitest::Test
    include Helpers

    def test_config_shows_empty_message_when_no_config
      result = run_ooo(['config'])
      assert_match(/No OOO config set/, result[:stdout])
    end

    def test_config_shows_json_when_configured
      ooo_config = { 'internal_message' => 'OOO', 'notify' => ['a@b.com'] }
      result = run_ooo(['config'], config_ooo: ooo_config)
      assert_match(/internal_message/, result[:stdout])
      assert_match(/a@b.com/, result[:stdout])
    end

    def test_config_json_output
      ooo_config = { 'internal_message' => 'OOO' }
      result = run_ooo(['config', '--json'], config_ooo: ooo_config)
      parsed = JSON.parse(result[:stdout])
      assert_equal 'OOO', parsed['internal_message']
    end
  end

  # Tests for error handling and edge cases
  class ErrorHandlingTest < Minitest::Test
    include Helpers

    def test_enable_handles_auto_reply_api_failure
      result = with_temp_config do
        capture_output do |output|
          runner = configured_runner(output: output)
          stub_ooo_apis(runner)
          runner.api_client.stub_error('/v1.0/me/mailboxSettings',
                                       Teems::ApiError.new('Forbidden', status_code: 403))
          Teems::Commands::Ooo.new(['on'], runner: runner).execute
        end
      end
      assert_match(/auto-reply/, result[:stderr])
    end

    def test_enable_handles_status_api_failure
      result = with_temp_config do
        capture_output do |output|
          runner = configured_runner(output: output)
          stub_ooo_apis(runner)
          runner.api_client.stub_error('/v1.0/me/presence/setStatusMessage',
                                       Teems::ApiError.new('Forbidden', status_code: 403))
          Teems::Commands::Ooo.new(['on'], runner: runner).execute
        end
      end
      assert_match(%r{status/presence}, result[:stderr])
    end

    def test_disable_handles_auto_reply_failure
      result = with_temp_config do
        capture_output do |output|
          runner = configured_runner(output: output)
          stub_ooo_apis(runner)
          runner.api_client.stub_error('/v1.0/me/mailboxSettings',
                                       Teems::ApiError.new('Forbidden', status_code: 403))
          Teems::Commands::Ooo.new(['off'], runner: runner).execute
        end
      end
      assert_match(/auto-reply/, result[:stderr])
    end

    def test_disable_handles_presence_clear_failure
      result = with_temp_config do
        capture_output do |output|
          runner = configured_runner(output: output)
          stub_ooo_apis(runner)
          runner.api_client.stub_error('/v1.0/me/presence/clearPresence',
                                       Teems::ApiError.new('Forbidden', status_code: 403))
          Teems::Commands::Ooo.new(['off'], runner: runner).execute
        end
      end
      assert_match(%r{status/presence}, result[:stderr])
    end

    def test_enable_handles_event_creation_failure
      result = run_ooo_with_error(['on', '--event'], '/v1.0/me/events', config_ooo: { 'notify' => ['mgr@test.com'] })
      assert_match(/calendar event/, result[:stderr])
    end

    def test_show_status_api_error
      result = run_ooo_with_dual_errors
      assert_match(/permission denied/, result[:stdout])
    end
  end

  # Tests for input validation: dates, schedule conflicts
  class ValidationTest < Minitest::Test
    include Helpers

    def test_start_without_end_halts_execution
      runner = run_ooo_runner(['on', '--start', '2026-04-14'])
      assert_empty runner.api_client.calls, 'No API calls should be made after validation error'
    end

    def test_start_without_end_shows_error
      result = run_ooo(['on', '--start', '2026-04-14'])
      assert_match(/--end is required/, result[:stderr])
    end

    def test_invalid_start_date_shows_error
      result = run_ooo(['on', '--start', 'not-a-date', '--end', '2026-04-18'])
      assert_match(/Invalid value for --start/, result[:stderr])
    end

    def test_invalid_end_date_shows_error
      result = run_ooo(['on', '--start', '2026-04-14', '--end', 'bogus'])
      assert_match(/Invalid value for --end/, result[:stderr])
    end

    def test_mixed_schedule_kinds_shows_error
      result = run_ooo(['on', '--start', '2026-04-14', '--end', 'today 17:00'])
      assert_match(/both be dates or both include a time/, result[:stderr])
    end

    def test_mixed_schedule_kinds_halts_execution
      runner = run_ooo_runner(['on', '--start', 'today 14:00', '--end', '2026-04-14'])
      assert_empty runner.api_client.calls
    end
  end

  # Tests for dispatch and help
  # Tests for dispatch, help, and misc flags
  class DispatchTest < Minitest::Test
    include Helpers

    def test_disable_with_no_status_flag
      runner = run_ooo_runner(['off', '--no-status'])
      calls = runner.api_client.calls
      refute(calls.any? { |c| c[:path].include?('setStatusMessage') })
      refute(calls.any? { |c| c[:path].include?('clearPresence') })
    end

    def test_unknown_action_returns_error
      result = run_ooo(['bogus'])
      assert_match(/Unknown action/, result[:stderr])
    end

    def test_help_flag
      result = run_ooo(['--help'])
      assert_match(/teems ooo/, result[:stdout])
      assert_match(/--message/, result[:stdout])
    end
  end
end
