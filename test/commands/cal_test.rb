# frozen_string_literal: true

require 'test_helper'

module CalCommandTests
  module SharedHelpers
    private

    def run_cal(args = [], stubs: {})
      out = StringIO.new
      err = StringIO.new
      with_temp_config do
        output = Teems::Formatters::Output.new(io: out, err: err, color: false)
        runner = configured_runner(output: output)
        stubs.each { |path, resp| runner.api_client.stub(path, resp) }
        Teems::Commands::Cal.new(args, runner: runner).execute
      end
      { stdout: out.string, stderr: err.string }
    end

    def run_cal_runner(args = [], stubs: {})
      with_temp_config do
        runner = configured_runner
        stubs.each { |path, resp| runner.api_client.stub(path, resp) }
        yield runner if block_given?
        Teems::Commands::Cal.new(args, runner: runner).execute
        return runner
      end
    end

    def run_cal_with_cached_show(args, num, event_id)
      with_temp_config do
        return capture_output do |output|
          runner = configured_runner(output: output)
          runner.cache_store.save_calendar_ids({ num => event_id })
          runner.api_client.stub('events', sample_event_data)
          Teems::Commands::Cal.new(args, runner: runner).execute
        end
      end
    end

    def run_cal_with_rsvp(args, num, event_id, stub_key)
      with_temp_config do
        return capture_output do |output|
          runner = configured_runner(output: output)
          runner.cache_store.save_calendar_ids({ num => event_id })
          runner.api_client.stub(stub_key, {})
          Teems::Commands::Cal.new(args, runner: runner).execute
        end
      end
    end

    def run_cal_rsvp_runner(args, num, event_id, stub_key)
      with_temp_config do
        runner = configured_runner
        runner.cache_store.save_calendar_ids({ num => event_id })
        runner.api_client.stub(stub_key, {})
        Teems::Commands::Cal.new(args, runner: runner).execute
        return runner
      end
    end

    def run_create(args, stub_response: sample_event_data)
      full_args = ['create'] + args
      with_temp_config do
        return capture_output do |output|
          runner = configured_runner(output: output)
          runner.api_client.stub('/v1.0/me/events', stub_response)
          Teems::Commands::Cal.new(full_args, runner: runner).execute
        end
      end
    end

    def run_create_runner(args, stub_response: sample_event_data)
      full_args = ['create'] + args
      with_temp_config do
        runner = configured_runner
        runner.api_client.stub('/v1.0/me/events', stub_response)
        Teems::Commands::Cal.new(full_args, runner: runner).execute
        return runner
      end
    end

    def with_tz(zone)
      original_tz = ENV.fetch('TZ', nil)
      zone ? ENV['TZ'] = zone : ENV.delete('TZ')
      yield
    ensure
      original_tz ? ENV['TZ'] = original_tz : ENV.delete('TZ')
    end

    def build_nil_time_event
      Teems::Models::Event.new(
        id: 'e1', subject: 'Test', start_time: nil, end_time: nil,
        location: nil, is_all_day: false, organizer: nil, attendees: [],
        body_preview: nil, online_meeting_url: nil, show_as: nil,
        importance: nil, is_cancelled: false, response_status: nil,
        sensitivity: nil
      )
    end
  end

  class BasicTest < Minitest::Test
    include SharedHelpers

    def test_requires_auth
      with_temp_config do
        result = capture_output do |output|
          store = mock_unconfigured_store
          runner = Teems::Runner.new(output: output, token_store: store)
          Teems::Commands::Cal.new([], runner: runner).execute
        end
        assert_match(/Not authenticated/, result[:stderr])
      end
    end

    def test_shows_help_with_help_flag
      stdout = run_cal(['--help'])[:stdout]
      assert_match(/teems cal/, stdout)
      assert_match(/USAGE:/, stdout)
      assert_match(/--days/, stdout)
      assert_match(/--week/, stdout)
      assert_match(/--date/, stdout)
    end

    def test_help_includes_show_subcommand
      result = run_cal(['--help'])
      assert_match(/show <N>/, result[:stdout])
    end

    def test_unknown_option
      result = run_cal(['--unknown'])
      assert_match(/Unknown option/, result[:stderr])
    end

    def test_default_listing_today_events
      result = run_cal([], stubs: { 'calendarView' => { 'value' => [sample_event_data] } })
      assert_match(/Weekly Standup/, result[:stdout])
    end

    def test_listing_with_no_events
      result = run_cal([], stubs: { 'calendarView' => { 'value' => [] } })
      assert_match(/No events found/, result[:stdout])
    end

    def test_days_option
      runner = run_cal_runner(['--days', '3'], stubs: { 'calendarView' => { 'value' => [] } }) do |blk_runner|
        assert_equal 3, Teems::Commands::Cal.new(['--days', '3'], runner: blk_runner).options[:days]
      end
      assert runner
    end

    def test_week_option
      runner = run_cal_runner(['--week'], stubs: { 'calendarView' => { 'value' => [] } }) do |blk_runner|
        assert Teems::Commands::Cal.new(['--week'], runner: blk_runner).options[:week]
      end
      assert runner
    end

    def test_date_option
      runner = run_cal_runner(['--date', '2026-01-20'], stubs: { 'calendarView' => { 'value' => [] } }) do |blk_runner|
        assert_equal '2026-01-20', Teems::Commands::Cal.new(['--date', '2026-01-20'], runner: blk_runner).options[:date]
      end
      assert runner
    end

    def test_invalid_date_option
      result = run_cal(['--date', 'not-a-date'])
      assert_match(/Invalid date/, result[:stderr])
    end

    def test_json_output
      result = run_cal(['--json'], stubs: { 'calendarView' => { 'value' => [sample_event_data] } })
      json = JSON.parse(result[:stdout])
      assert_instance_of Array, json
      assert_equal 'Weekly Standup', json[0]['subject']
    end

    def test_verbose_mode
      result = run_cal(['-v'], stubs: { 'calendarView' => { 'value' => [sample_event_data] } })
      assert_match(/Weekly Standup/, result[:stdout])
      assert_match(/Alice Manager/, result[:stdout])
    end

    def test_events_are_numbered_in_output
      events = [sample_event_data, sample_event_data.merge('id' => 'event-2', 'subject' => 'Lunch Break')]
      stdout = run_cal([], stubs: { 'calendarView' => { 'value' => events } })[:stdout]
      assert_match(/\[1\]/, stdout)
      assert_match(/\[2\]/, stdout)
      assert_match(/Weekly Standup/, stdout)
      assert_match(/Lunch Break/, stdout)
    end

    def test_limit_option_passed_to_api
      runner = run_cal_runner(['-n', '10'], stubs: { 'calendarView' => { 'value' => [] } })
      assert_equal 10, runner.api_client.calls.first[:params]['$top']
    end
  end

  class ShowAndAliasTest < Minitest::Test
    include SharedHelpers

    def test_show_subcommand_without_number
      result = run_cal(['show'])
      assert_match(/Event number required/, result[:stderr])
    end

    def test_show_subcommand_with_uncached_number
      result = run_cal(%w[show 1])
      assert_match(/not found/, result[:stderr])
    end

    def test_show_subcommand_with_cached_event
      result = run_cal_with_cached_show(%w[show 1], '1', 'AAMkAGVmMDEzMTM4LTZmYWUtNDdkNC1hMDZe')
      assert_match(/Weekly Standup/, result[:stdout])
      assert_match(/Conference Room A/, result[:stdout])
    end

    def test_show_subcommand_with_json
      result = run_cal_with_cached_show(['show', '1', '--json'], '1', 'event-123')
      json = JSON.parse(result[:stdout])
      assert_equal 'Weekly Standup', json['subject']
    end

    def test_api_error_handling_list
      with_temp_config do
        result = capture_output do |output|
          runner = configured_runner(output: output)
          runner.api_client.stub_error('calendarView', Teems::ApiError.new('Forbidden', status_code: 403))
          Teems::Commands::Cal.new([], runner: runner).execute
        end
        assert_match(/Failed to fetch calendar/, result[:stderr])
      end
    end

    def test_api_error_handling_show
      with_temp_config do
        result = capture_output do |output|
          runner = configured_runner(output: output)
          runner.cache_store.save_calendar_ids({ '1' => 'event-123' })
          runner.api_client.stub_error('events', Teems::ApiError.new('Not found', status_code: 404))
          Teems::Commands::Cal.new(%w[show 1], runner: runner).execute
        end
        assert_match(/Failed to fetch event/, result[:stderr])
      end
    end

    def test_today_alias_lists_events
      result = run_cal(['today'], stubs: { 'calendarView' => { 'value' => [sample_event_data] } })
      assert_match(/Weekly Standup/, result[:stdout])
    end

    def test_today_alias_uses_today_date_range
      runner = run_cal_runner(['today'], stubs: { 'calendarView' => { 'value' => [] } })
      today = Date.today.strftime('%Y-%m-%d')
      call = runner.api_client.calls.first
      assert call[:params]['startDateTime'].start_with?(today), "Expected start to be today (#{today})"
      assert call[:params]['endDateTime'].start_with?(today), "Expected end to be today (#{today})"
    end

    def test_tomorrow_alias_uses_tomorrow_date
      runner = run_cal_runner(['tomorrow'], stubs: { 'calendarView' => { 'value' => [] } })
      tomorrow = (Date.today + 1).strftime('%Y-%m-%d')
      call = runner.api_client.calls.first
      assert call[:params]['startDateTime'].start_with?(tomorrow), "Expected start: #{tomorrow}"
      assert call[:params]['endDateTime'].start_with?(tomorrow), "Expected end: #{tomorrow}"
    end

    def test_tomorrow_alias_with_options
      result = run_cal(['tomorrow', '-v'], stubs: { 'calendarView' => { 'value' => [sample_event_data] } })
      assert_match(/Weekly Standup/, result[:stdout])
    end

    def test_help_includes_today_and_tomorrow
      result = run_cal(['--help'])
      assert_match(/today/, result[:stdout])
      assert_match(/tomorrow/, result[:stdout])
    end
  end

  class RsvpTest < Minitest::Test
    include SharedHelpers

    def test_accept_event
      result = run_cal_with_rsvp(%w[accept 1], '1', 'event-123', 'accept')
      assert_match(/accepted/, result[:stdout])
    end

    def test_accept_sends_correct_api_call
      runner = run_cal_rsvp_runner(%w[accept 3], '3', 'event-xyz', 'accept')
      call = runner.api_client.calls.first
      assert_equal :post, call[:method]
      assert_includes call[:path], '/accept'
      assert_includes call[:path], 'event-xyz'
      assert_equal true, call[:body][:sendResponse]
    end

    def test_decline_event
      result = run_cal_with_rsvp(%w[decline 2], '2', 'event-456', 'decline')
      assert_match(/declined/, result[:stdout])
    end

    def test_decline_sends_correct_api_call
      runner = run_cal_rsvp_runner(%w[decline 1], '1', 'event-abc', 'decline')
      call = runner.api_client.calls.first
      assert_equal :post, call[:method]
      assert_includes call[:path], '/decline'
    end

    def test_tentative_event
      result = run_cal_with_rsvp(%w[tentative 1], '1', 'event-789', 'tentativelyAccept')
      assert_match(/tentatively accepted/, result[:stdout])
    end

    def test_tentative_sends_tentatively_accept_action
      runner = run_cal_rsvp_runner(%w[tentative 1], '1', 'event-abc', 'tentativelyAccept')
      call = runner.api_client.calls.first
      assert_equal :post, call[:method]
      assert_includes call[:path], '/tentativelyAccept'
    end

    def test_rsvp_with_comment
      runner = run_cal_rsvp_runner(['accept', '1', '--comment', 'Looking forward to it'],
                                   '1', 'event-123', 'accept')
      assert_equal 'Looking forward to it', runner.api_client.calls.first[:body][:comment]
    end

    def test_rsvp_with_no_send
      runner = run_cal_rsvp_runner(['decline', '1', '--no-send'], '1', 'event-123', 'decline')
      assert_equal false, runner.api_client.calls.first[:body][:sendResponse]
    end

    def test_rsvp_without_number
      result = run_cal(['accept'])
      assert_match(/Event number required/, result[:stderr])
    end

    def test_rsvp_with_uncached_number
      result = run_cal(%w[decline 99])
      assert_match(/not found/, result[:stderr])
    end

    def test_rsvp_api_error
      with_temp_config do
        result = capture_output do |output|
          runner = configured_runner(output: output)
          runner.cache_store.save_calendar_ids({ '1' => 'event-123' })
          runner.api_client.stub_error('accept', Teems::ApiError.new('Forbidden', status_code: 403))
          Teems::Commands::Cal.new(%w[accept 1], runner: runner).execute
        end
        assert_match(/Failed to respond to event/, result[:stderr])
      end
    end

    def test_rsvp_without_comment_omits_comment_key
      runner = run_cal_rsvp_runner(%w[accept 1], '1', 'event-123', 'accept')
      refute runner.api_client.calls.first[:body].key?(:comment),
             'Expected no comment key in body when --comment not provided'
    end

    def test_help_includes_rsvp_subcommands
      stdout = run_cal(['--help'])[:stdout]
      assert_match(/accept <N>/, stdout)
      assert_match(/decline <N>/, stdout)
      assert_match(/tentative <N>/, stdout)
      assert_match(/--comment/, stdout)
      assert_match(/--no-send/, stdout)
    end
  end

  class CreateValidationTest < Minitest::Test
    include SharedHelpers

    def test_create_without_title
      result = run_create([])
      assert_match(/Event title required/, result[:stderr])
    end

    def test_create_without_start_time
      result = run_create(['Meeting'])
      assert_match(/Start time required/, result[:stderr])
    end

    def test_create_with_invalid_start
      result = run_create(['Meeting', '--start', 'garbage'])
      assert_match(/Invalid start time/, result[:stderr])
    end

    def test_create_with_invalid_end
      result = run_create(['Meeting', '--start', '2026-03-20 09:00', '--end', 'garbage'])
      assert_match(/Invalid end time/, result[:stderr])
    end

    def test_create_all_day_with_invalid_date
      result = run_create(['Day Off', '--all-day', '--date', 'not-a-date'])
      assert_match(/Invalid date/, result[:stderr])
    end

    def test_create_with_zero_duration
      result = run_create(['Meeting', '--start', '2026-03-20 09:00', '--duration', '0'])
      assert_match(/Duration must be a positive number/, result[:stderr])
    end

    def test_create_api_error
      with_temp_config do
        result = capture_output do |output|
          runner = configured_runner(output: output)
          runner.api_client.stub_error('/v1.0/me/events', Teems::ApiError.new('Forbidden', status_code: 403))
          Teems::Commands::Cal.new(['create', 'Meeting', '--start', '2026-03-20 14:00'], runner: runner).execute
        end
        assert_match(/Failed to create event/, result[:stderr])
      end
    end

    def test_create_help_included
      stdout = run_cal(['--help'])[:stdout]
      assert_match(/create "Title"/, stdout)
      assert_match(/--start/, stdout)
      assert_match(/--duration/, stdout)
      assert_match(/--all-day/, stdout)
      assert_match(/--teams/, stdout)
      assert_match(/--attendees/, stdout)
    end
  end

  class CreateApiCallTest < Minitest::Test
    include SharedHelpers

    def test_create_posts_to_events_endpoint
      runner = run_create_runner(['Standup', '--start', '2026-03-20 14:00'])
      call = runner.api_client.calls.first
      assert_equal :post, call[:method]
      assert_includes call[:path], '/v1.0/me/events'
      assert_equal 'Standup', call[:body][:subject]
    end

    def test_create_sends_correct_times
      runner = run_create_runner(['Standup', '--start', '2026-03-20 14:00'])
      body = runner.api_client.calls.first[:body]
      assert_equal '2026-03-20T14:00:00', body[:start][:dateTime]
      assert_equal '2026-03-20T14:30:00', body[:end][:dateTime]
    end

    def test_create_default_duration_30_minutes
      runner = run_create_runner(['Meeting', '--start', '2026-03-20 09:00'])
      body = runner.api_client.calls.first[:body]
      assert_equal '2026-03-20T09:30:00', body[:end][:dateTime]
    end

    def test_create_with_duration
      runner = run_create_runner(['Meeting', '--start', '2026-03-20 09:00', '--duration', '60'])
      assert_equal '2026-03-20T10:00:00', runner.api_client.calls.first[:body][:end][:dateTime]
    end

    def test_create_with_explicit_end
      runner = run_create_runner(['Meeting', '--start', '2026-03-20 09:00', '--end', '2026-03-20 11:00'])
      assert_equal '2026-03-20T11:00:00', runner.api_client.calls.first[:body][:end][:dateTime]
    end

    def test_create_with_today_shorthand
      runner = run_create_runner(['Sync', '--start', 'today 15:00'])
      today = Date.today.strftime('%Y-%m-%d')
      assert_equal "#{today}T15:00:00", runner.api_client.calls.first[:body][:start][:dateTime]
    end

    def test_create_with_tomorrow_shorthand
      runner = run_create_runner(['Sync', '--start', 'tomorrow 10:00'])
      tomorrow = (Date.today + 1).strftime('%Y-%m-%d')
      assert_equal "#{tomorrow}T10:00:00", runner.api_client.calls.first[:body][:start][:dateTime]
    end

    def test_create_with_time_only_assumes_today
      runner = run_create_runner(['Sync', '--start', '16:30'])
      today = Date.today.strftime('%Y-%m-%d')
      assert_equal "#{today}T16:30:00", runner.api_client.calls.first[:body][:start][:dateTime]
    end

    def test_create_all_day_event
      runner = run_create_runner(['Day Off', '--all-day', '--date', '2026-03-20'])
      body = runner.api_client.calls.first[:body]
      assert_equal true, body[:isAllDay]
      assert_equal '2026-03-20T00:00:00', body[:start][:dateTime]
      assert_equal '2026-03-21T00:00:00', body[:end][:dateTime]
    end

    def test_create_all_day_defaults_to_today
      runner = run_create_runner(['Day Off', '--all-day'])
      today = Date.today.strftime('%Y-%m-%d')
      assert_equal "#{today}T00:00:00", runner.api_client.calls.first[:body][:start][:dateTime]
    end

    def test_create_includes_timezone
      with_temp_config do
        with_tz('America/Chicago') do
          runner = configured_runner
          runner.api_client.stub('/v1.0/me/events', sample_event_data)
          Teems::Commands::Cal.new(['create', 'Test', '--start', '2026-03-20 09:00'], runner: runner).execute
          body = runner.api_client.calls.first[:body]
          assert_equal 'America/Chicago', body[:start][:timeZone]
        end
      end
    end
  end

  class CreateOptionsTest < Minitest::Test
    include SharedHelpers

    def test_create_with_location
      runner = run_create_runner(['Meeting', '--start', '2026-03-20 09:00', '--location', 'Room B'])
      assert_equal({ displayName: 'Room B' }, runner.api_client.calls.first[:body][:location])
    end

    def test_create_with_body
      runner = run_create_runner(['Meeting', '--start', '2026-03-20 09:00', '--body', 'Agenda here'])
      assert_equal({ contentType: 'text', content: 'Agenda here' }, runner.api_client.calls.first[:body][:body])
    end

    def test_create_with_attendees
      runner = run_create_runner(['Meeting', '--start', '2026-03-20 09:00',
                                  '--attendees', 'alice@example.com,bob@example.com'])
      attendees = runner.api_client.calls.first[:body][:attendees]
      assert_equal 2, attendees.length
      assert_equal 'alice@example.com', attendees[0][:emailAddress][:address]
    end

    def test_create_attendees_marked_as_required
      runner = run_create_runner(['Meeting', '--start', '2026-03-20 09:00',
                                  '--attendees', 'alice@example.com'])
      assert_equal 'required', runner.api_client.calls.first[:body][:attendees][0][:type]
    end

    def test_create_with_teams_meeting
      runner = run_create_runner(['Meeting', '--start', '2026-03-20 09:00', '--teams'])
      body = runner.api_client.calls.first[:body]
      assert_equal true, body[:isOnlineMeeting]
      assert_equal 'teamsForBusiness', body[:onlineMeetingProvider]
    end

    def test_create_without_teams_omits_online_meeting
      runner = run_create_runner(['Meeting', '--start', '2026-03-20 09:00'])
      refute runner.api_client.calls.first[:body].key?(:isOnlineMeeting)
    end

    def test_create_without_optional_fields_omits_them
      runner = run_create_runner(['Meeting', '--start', '2026-03-20 09:00'])
      body = runner.api_client.calls.first[:body]
      refute body.key?(:location)
      refute body.key?(:body)
      refute body.key?(:attendees)
    end
  end

  class CreateDisplayTest < Minitest::Test
    include SharedHelpers

    def test_create_basic_event
      result = run_create(['Standup', '--start', '2026-03-20 14:00'])
      assert_match(/Created: "Weekly Standup"/, result[:stdout])
    end

    def test_create_displays_time_range
      event_data = sample_event_data.merge(
        'start' => { 'dateTime' => '2026-03-20T14:00:00.0000000', 'timeZone' => 'America/Chicago' },
        'end' => { 'dateTime' => '2026-03-20T14:30:00.0000000', 'timeZone' => 'America/Chicago' }
      )
      result = run_create(['Meeting', '--start', '2026-03-20 14:00'], stub_response: event_data)
      assert_match(/2026-03-20 14:00-14:30/, result[:stdout])
    end

    def test_create_displays_teams_link
      event_data = sample_event_data.merge(
        'onlineMeeting' => { 'joinUrl' => 'https://teams.microsoft.com/l/meetup-join/test123' }
      )
      result = run_create(['Meeting', '--start', '2026-03-20 14:00', '--teams'], stub_response: event_data)
      assert_match(%r{Teams link: https://teams\.microsoft\.com}, result[:stdout])
    end

    def test_create_displays_location
      event_data = sample_event_data.merge('location' => { 'displayName' => 'Room A' })
      result = run_create(['Meeting', '--start', '2026-03-20 14:00', '--location', 'Room A'],
                          stub_response: event_data)
      assert_match(/Location: Room A/, result[:stdout])
    end

    def test_create_all_day_displays_all_day
      event_data = sample_event_data.merge(
        'isAllDay' => true,
        'start' => { 'dateTime' => '2026-03-20T00:00:00.0000000', 'timeZone' => 'America/Chicago' },
        'end' => { 'dateTime' => '2026-03-20T00:00:00.0000000', 'timeZone' => 'America/Chicago' }
      )
      result = run_create(['Day Off', '--all-day', '--date', '2026-03-20'], stub_response: event_data)
      assert_match(/all day/, result[:stdout])
    end
  end

  class DeleteTest < Minitest::Test
    include SharedHelpers

    def run_delete(num, event_id, stub_event: sample_event_data)
      with_temp_config do
        return capture_output do |output|
          runner = configured_runner(output: output)
          runner.cache_store.save_calendar_ids({ num => event_id })
          runner.api_client.stub('events', stub_event)
          Teems::Commands::Cal.new(['delete', num], runner: runner).execute
        end
      end
    end

    def test_delete_without_number
      result = run_cal(['delete'])
      assert_match(/Event number required/, result[:stderr])
    end

    def test_delete_with_uncached_number
      result = run_cal(%w[delete 99])
      assert_match(/not found/, result[:stderr])
    end

    def test_delete_displays_confirmation
      result = run_delete('1', 'event-123')
      assert_match(/Deleted: "Weekly Standup"/, result[:stdout])
    end

    def test_delete_displays_time
      event_data = sample_event_data.merge(
        'start' => { 'dateTime' => '2026-03-20T14:00:00.0000000', 'timeZone' => 'America/Chicago' },
        'end' => { 'dateTime' => '2026-03-20T14:30:00.0000000', 'timeZone' => 'America/Chicago' }
      )
      result = run_delete('1', 'event-123', stub_event: event_data)
      assert_match(/2026-03-20 14:00-14:30/, result[:stdout])
    end

    def test_delete_api_error
      with_temp_config do
        result = capture_output do |output|
          runner = configured_runner(output: output)
          runner.cache_store.save_calendar_ids({ '1' => 'event-123' })
          runner.api_client.stub_error('events', Teems::ApiError.new('Not found', status_code: 404))
          Teems::Commands::Cal.new(%w[delete 1], runner: runner).execute
        end
        assert_match(/Failed to delete event/, result[:stderr])
      end
    end

    def test_delete_help_included
      result = run_cal(['--help'])
      assert_match(/delete <N>/, result[:stdout])
    end
  end

  class TimezoneAndDateRangeTest < Minitest::Test
    include SharedHelpers

    def test_detect_timezone_with_tz_env_iana
      with_temp_config do
        with_tz('America/New_York') do
          cmd = Teems::Commands::Cal.new([], runner: configured_runner)
          assert_equal 'America/New_York', cmd.send(:detect_timezone)
        end
      end
    end

    def test_detect_timezone_with_tz_env_abbreviation
      with_temp_config do
        with_tz('EST') do
          cmd = Teems::Commands::Cal.new([], runner: configured_runner)
          assert_equal 'America/New_York', cmd.send(:detect_timezone)
        end
      end
    end

    def test_detect_timezone_with_tz_env_unknown
      with_temp_config do
        with_tz('CUSTOM') do
          cmd = Teems::Commands::Cal.new([], runner: configured_runner)
          assert_equal 'CUSTOM', cmd.send(:detect_timezone)
        end
      end
    end

    def test_detect_timezone_no_tz_env
      with_temp_config do
        with_tz(nil) do
          cmd = Teems::Commands::Cal.new([], runner: configured_runner)
          assert_kind_of String, cmd.send(:detect_timezone)
        end
      end
    end

    def test_date_range_for_week
      with_temp_config do
        cmd = Teems::Commands::Cal.new(['--week'], runner: configured_runner)
        range = cmd.send(:compute_date_range)
        assert_instance_of Array, range
        assert_equal 2, range.length
      end
    end

    def test_date_range_for_week_on_sunday
      with_temp_config do
        cmd = Teems::Commands::Cal.new(['--week'], runner: configured_runner)
        Date.stub(:today, Date.new(2026, 3, 15)) do
          range = cmd.send(:compute_date_range)
          assert_instance_of Array, range
          assert_includes range.first, '2026-03-09'
        end
      end
    end

    def test_format_datetime_includes_timezone_offset
      with_temp_config do
        with_tz('America/Chicago') do
          cmd = Teems::Commands::Cal.new([], runner: configured_runner)
          range = cmd.send(:compute_date_range)
          assert_match(/[+-]\d{2}:\d{2}\z/, range.first, 'Expected timezone offset in startDateTime')
          assert_match(/[+-]\d{2}:\d{2}\z/, range.last, 'Expected timezone offset in endDateTime')
        end
      end
    end

    def test_event_to_hash_nil_times
      with_temp_config do
        cmd = Teems::Commands::Cal.new([], runner: configured_runner)
        hash = cmd.send(:event_to_hash, build_nil_time_event)
        assert_nil hash[:start_time]
        assert_nil hash[:end_time]
      end
    end
  end
end
