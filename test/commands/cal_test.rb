# frozen_string_literal: true

require 'test_helper'

# Tests for the calendar command
module CalCommandTests
  # Shared helpers for running calendar commands and building test data
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

    def calendar_view_with_events(*events)
      { 'calendarView' => { 'value' => events } }
    end

    def run_cal_with_resolved_show(args, events_data)
      with_temp_config do
        return capture_output do |output|
          runner = configured_runner(output: output)
          runner.api_client.stub('calendarView', { 'value' => events_data })
          runner.api_client.stub('events', events_data.first)
          Teems::Commands::Cal.new(args, runner: runner).execute
        end
      end
    end

    def run_cal_with_resolved_rsvp(args, events_data, rsvp_stub_key)
      with_temp_config do
        return capture_output do |output|
          runner = configured_runner(output: output)
          runner.api_client.stub('calendarView', { 'value' => events_data })
          runner.api_client.stub(rsvp_stub_key, {})
          Teems::Commands::Cal.new(args, runner: runner).execute
        end
      end
    end

    def run_cal_rsvp_runner(args, events_data, rsvp_stub_key)
      with_temp_config do
        runner = configured_runner
        runner.api_client.stub('calendarView', { 'value' => events_data })
        runner.api_client.stub(rsvp_stub_key, {})
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
      restore_tz(original_tz)
    end

    def restore_tz(value)
      value ? ENV['TZ'] = value : ENV.delete('TZ')
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

    def second_event_data
      sample_event_data.merge('id' => 'event-second', 'subject' => 'Second Event')
    end

    def event_hash_for(event_id)
      Digest::SHA256.hexdigest(event_id.to_s)[0, 6]
    end
  end

  # Tests for auth, help, listing, and basic calendar options
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
      assert_match(/show <N\|hash>/, result[:stdout])
    end

    def test_help_includes_no_interactive_option
      result = run_cal(['--help'])
      assert_match(/--no-interactive/, result[:stdout])
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
      stdout = result[:stdout]
      assert_match(/Weekly Standup/, stdout)
      assert_match(/Alice Manager/, stdout)
    end

    def test_events_are_numbered_in_output
      events = [sample_event_data, sample_event_data.merge('id' => 'event-2', 'subject' => 'Lunch Break')]
      stdout = run_cal([], stubs: { 'calendarView' => { 'value' => events } })[:stdout]
      assert_match(/\[1\]/, stdout)
      assert_match(/\[2\]/, stdout)
      assert_match(/Weekly Standup/, stdout)
      assert_match(/Lunch Break/, stdout)
    end

    def test_events_show_short_hash_in_output
      result = run_cal([], stubs: { 'calendarView' => { 'value' => [sample_event_data] } })
      expected_hash = event_hash_for(sample_event_data['id'])
      assert_includes result[:stdout], "[#{expected_hash}]"
    end

    def test_limit_option_passed_to_api
      runner = run_cal_runner(['-n', '10'], stubs: { 'calendarView' => { 'value' => [] } })
      assert_equal 10, runner.api_client.calls.first[:params]['$top']
    end

    def test_no_interactive_option_parsed
      with_temp_config do
        runner = configured_runner
        runner.api_client.stub('calendarView', { 'value' => [] })
        cmd = Teems::Commands::Cal.new(['--no-interactive'], runner: runner)
        assert cmd.options[:no_interactive]
      end
    end
  end

  # Tests for show subcommand and today/tomorrow aliases
  class ShowAndAliasTest < Minitest::Test
    include SharedHelpers

    def test_show_subcommand_without_number
      result = run_cal(['show'])
      assert_match(/Event reference required/, result[:stderr])
    end

    def test_show_subcommand_with_unfound_ref
      result = run_cal(%w[show zzz999], stubs: { 'calendarView' => { 'value' => [sample_event_data] } })
      assert_match(/not found/, result[:stderr])
    end

    def test_show_subcommand_by_number
      result = run_cal_with_resolved_show(%w[show 1], [sample_event_data])
      stdout = result[:stdout]
      assert_match(/Weekly Standup/, stdout)
      assert_match(/Conference Room A/, stdout)
    end

    def test_show_subcommand_by_hash
      hash = event_hash_for(sample_event_data['id'])
      result = run_cal_with_resolved_show(['show', hash], [sample_event_data])
      assert_match(/Weekly Standup/, result[:stdout])
    end

    def test_show_subcommand_by_partial_hash
      hash = event_hash_for(sample_event_data['id'])[0, 3]
      result = run_cal_with_resolved_show(['show', hash], [sample_event_data])
      assert_match(/Weekly Standup/, result[:stdout])
    end

    def test_show_subcommand_with_json
      result = run_cal_with_resolved_show(['show', '1', '--json'], [sample_event_data])
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
          runner.api_client.stub('calendarView', { 'value' => [sample_event_data] })
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
      params = runner.api_client.calls.first[:params]
      assert params['startDateTime'].start_with?(today), "Expected start to be today (#{today})"
      assert params['endDateTime'].start_with?(today), "Expected end to be today (#{today})"
    end

    def test_tomorrow_alias_uses_tomorrow_date
      runner = run_cal_runner(['tomorrow'], stubs: { 'calendarView' => { 'value' => [] } })
      tomorrow = (Date.today + 1).strftime('%Y-%m-%d')
      params = runner.api_client.calls.first[:params]
      assert params['startDateTime'].start_with?(tomorrow), "Expected start: #{tomorrow}"
      assert params['endDateTime'].start_with?(tomorrow), "Expected end: #{tomorrow}"
    end

    def test_tomorrow_alias_with_options
      result = run_cal(['tomorrow', '-v'], stubs: { 'calendarView' => { 'value' => [sample_event_data] } })
      assert_match(/Weekly Standup/, result[:stdout])
    end

    def test_help_includes_today_and_tomorrow
      stdout = run_cal(['--help'])[:stdout]
      assert_match(/today/, stdout)
      assert_match(/tomorrow/, stdout)
    end
  end

  # Tests for RSVP actions: accept, decline, and tentative
  class RsvpTest < Minitest::Test
    include SharedHelpers

    def test_accept_event
      result = run_cal_with_resolved_rsvp(%w[accept 1], [sample_event_data], 'accept')
      assert_match(/accepted/, result[:stdout])
    end

    def test_accept_sends_correct_api_call
      runner = run_cal_rsvp_runner(%w[accept 1], [sample_event_data], 'accept')
      calls = runner.api_client.calls
      rsvp_call = calls.find { |c| c[:method] == :post && c[:path].include?('/accept') }
      assert rsvp_call, 'Expected an accept API call'
      assert_includes rsvp_call[:path], sample_event_data['id']
      assert_equal true, rsvp_call[:body][:sendResponse]
    end

    def test_accept_by_hash
      hash = event_hash_for(sample_event_data['id'])
      result = run_cal_with_resolved_rsvp(['accept', hash], [sample_event_data], 'accept')
      assert_match(/accepted/, result[:stdout])
    end

    def test_decline_event
      result = run_cal_with_resolved_rsvp(%w[decline 1], [sample_event_data], 'decline')
      assert_match(/declined/, result[:stdout])
    end

    def test_decline_sends_correct_api_call
      runner = run_cal_rsvp_runner(%w[decline 1], [sample_event_data], 'decline')
      calls = runner.api_client.calls
      rsvp_call = calls.find { |c| c[:method] == :post && c[:path].include?('/decline') }
      assert rsvp_call, 'Expected a decline API call'
    end

    def test_tentative_event
      result = run_cal_with_resolved_rsvp(%w[tentative 1], [sample_event_data], 'tentativelyAccept')
      assert_match(/tentatively accepted/, result[:stdout])
    end

    def test_tentative_sends_tentatively_accept_action
      runner = run_cal_rsvp_runner(%w[tentative 1], [sample_event_data], 'tentativelyAccept')
      calls = runner.api_client.calls
      rsvp_call = calls.find { |c| c[:method] == :post && c[:path].include?('/tentativelyAccept') }
      assert rsvp_call, 'Expected a tentativelyAccept API call'
    end

    def test_rsvp_with_comment
      runner = run_cal_rsvp_runner(['accept', '1', '--comment', 'Looking forward to it'],
                                   [sample_event_data], 'accept')
      calls = runner.api_client.calls
      rsvp_call = calls.find { |c| c[:method] == :post && c[:path].include?('/accept') }
      assert_equal 'Looking forward to it', rsvp_call[:body][:comment]
    end

    def test_rsvp_with_no_send
      runner = run_cal_rsvp_runner(['decline', '1', '--no-send'], [sample_event_data], 'decline')
      calls = runner.api_client.calls
      rsvp_call = calls.find { |c| c[:method] == :post && c[:path].include?('/decline') }
      assert_equal false, rsvp_call[:body][:sendResponse]
    end

    def test_rsvp_without_number
      result = run_cal(['accept'])
      assert_match(/Event reference required/, result[:stderr])
    end

    def test_rsvp_with_unfound_ref
      result = run_cal(%w[decline zzz999], stubs: { 'calendarView' => { 'value' => [sample_event_data] } })
      assert_match(/not found/, result[:stderr])
    end

    def test_rsvp_api_error
      with_temp_config do
        result = capture_output do |output|
          runner = configured_runner(output: output)
          runner.api_client.stub('calendarView', { 'value' => [sample_event_data] })
          runner.api_client.stub_error('accept', Teems::ApiError.new('Forbidden', status_code: 403))
          Teems::Commands::Cal.new(%w[accept 1], runner: runner).execute
        end
        assert_match(/Failed to respond to event/, result[:stderr])
      end
    end

    def test_rsvp_without_comment_omits_comment_key
      runner = run_cal_rsvp_runner(%w[accept 1], [sample_event_data], 'accept')
      calls = runner.api_client.calls
      rsvp_call = calls.find { |c| c[:method] == :post && c[:path].include?('/accept') }
      refute rsvp_call[:body].key?(:comment),
             'Expected no comment key in body when --comment not provided'
    end

    def test_help_includes_rsvp_subcommands
      stdout = run_cal(['--help'])[:stdout]
      assert_match(/accept <N\|hash>/, stdout)
      assert_match(/decline <N\|hash>/, stdout)
      assert_match(/tentative <N\|hash>/, stdout)
      assert_match(/--comment/, stdout)
      assert_match(/--no-send/, stdout)
    end
  end

  # Tests for event creation input validation
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

  # Tests for event creation API request formatting
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
          api = runner.api_client
          api.stub('/v1.0/me/events', sample_event_data)
          Teems::Commands::Cal.new(['create', 'Test', '--start', '2026-03-20 09:00'], runner: runner).execute
          body = api.calls.first[:body]
          assert_equal 'America/Chicago', body[:start][:timeZone]
        end
      end
    end
  end

  # Tests for optional event creation fields like location, body, and attendees
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

  # Tests for event creation output display
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

  # Tests for event deletion subcommand
  class DeleteTest < Minitest::Test
    include SharedHelpers

    def run_delete(ref, events_data, stub_event: sample_event_data)
      with_temp_config do
        return capture_output do |output|
          runner = configured_runner(output: output)
          runner.api_client.stub('calendarView', { 'value' => events_data })
          runner.api_client.stub('events', stub_event)
          Teems::Commands::Cal.new(['delete', ref], runner: runner).execute
        end
      end
    end

    def test_delete_without_number
      result = run_cal(['delete'])
      assert_match(/Event reference required/, result[:stderr])
    end

    def test_delete_with_unfound_ref
      result = run_cal(%w[delete zzz999], stubs: { 'calendarView' => { 'value' => [sample_event_data] } })
      assert_match(/not found/, result[:stderr])
    end

    def test_delete_displays_confirmation
      result = run_delete('1', [sample_event_data])
      assert_match(/Deleted: "Weekly Standup"/, result[:stdout])
    end

    def test_delete_by_hash
      hash = event_hash_for(sample_event_data['id'])
      result = run_delete(hash, [sample_event_data])
      assert_match(/Deleted: "Weekly Standup"/, result[:stdout])
    end

    def test_delete_displays_time
      event_data = sample_event_data.merge(
        'start' => { 'dateTime' => '2026-03-20T14:00:00.0000000', 'timeZone' => 'America/Chicago' },
        'end' => { 'dateTime' => '2026-03-20T14:30:00.0000000', 'timeZone' => 'America/Chicago' }
      )
      result = run_delete('1', [event_data], stub_event: event_data)
      assert_match(/2026-03-20 14:00-14:30/, result[:stdout])
    end

    def test_delete_api_error
      with_temp_config do
        result = capture_output do |output|
          runner = configured_runner(output: output)
          runner.api_client.stub('calendarView', { 'value' => [sample_event_data] })
          runner.api_client.stub_error('events', Teems::ApiError.new('Not found', status_code: 404))
          Teems::Commands::Cal.new(%w[delete 1], runner: runner).execute
        end
        assert_match(/Failed to delete event/, result[:stderr])
      end
    end

    def test_delete_help_included
      result = run_cal(['--help'])
      assert_match(/delete <N\|hash>/, result[:stdout])
    end
  end

  # Tests for hash-based event resolution
  class HashResolutionTest < Minitest::Test
    include SharedHelpers

    def test_full_hash_resolves
      hash = event_hash_for(sample_event_data['id'])
      result = run_cal_with_resolved_show(['show', hash], [sample_event_data])
      assert_match(/Weekly Standup/, result[:stdout])
    end

    def test_partial_hash_resolves_if_unambiguous
      hash = event_hash_for(sample_event_data['id'])[0, 3]
      result = run_cal_with_resolved_show(['show', hash], [sample_event_data])
      assert_match(/Weekly Standup/, result[:stdout])
    end

    def test_invalid_hash_shows_error
      result = run_cal(%w[show zzz999], stubs: { 'calendarView' => { 'value' => [sample_event_data] } })
      assert_match(/not found/, result[:stderr])
    end

    def test_number_resolves_as_positional
      events = [sample_event_data, second_event_data]
      with_temp_config do
        result = capture_output do |output|
          runner = configured_runner(output: output)
          runner.api_client.stub('calendarView', { 'value' => events })
          runner.api_client.stub('events', second_event_data)
          Teems::Commands::Cal.new(%w[show 2], runner: runner).execute
        end
        assert_match(/Second Event/, result[:stdout])
      end
    end

    def test_zero_number_treated_as_invalid
      result = run_cal(%w[show 0], stubs: { 'calendarView' => { 'value' => [sample_event_data] } })
      assert_match(/not found/, result[:stderr])
    end
  end

  # Shared TTY test helpers for interactive mode tests
  module InteractiveHelpers
    include SharedHelpers

    # StringIO subclass that reports as a TTY for interactive mode tests
    class TtyStringIO < StringIO
      def tty? = true
    end

    private

    def run_interactive(stdin_input, stubs: {})
      with_temp_config do
        tty_io = TtyStringIO.new
        runner = build_tty_runner(tty_io, stubs)
        result = with_fake_stdin(stdin_input) { Teems::Commands::Cal.new([], runner: runner).execute }
        { output: tty_io.string, result: result }
      end
    end

    def build_tty_runner(tty_io, stubs)
      output = Teems::Formatters::Output.new(io: tty_io, err: StringIO.new, color: false)
      runner = configured_runner(output: output)
      stubs.each { |path, resp| runner.api_client.stub(path, resp) }
      runner
    end

    def default_stubs
      { 'calendarView' => { 'value' => [sample_event_data] }, 'events' => sample_event_data }
    end
  end

  # Tests for interactive mode suppression (non-TTY, flags)
  class InteractiveSuppressionTest < Minitest::Test
    include SharedHelpers

    def test_no_interactive_suppresses_prompt
      result = run_cal(['--no-interactive'],
                       stubs: { 'calendarView' => { 'value' => [sample_event_data] } })
      assert_match(/Weekly Standup/, result[:stdout])
      refute_match(/Enter #/, result[:stdout])
    end

    def test_json_suppresses_prompt
      result = run_cal(['--json'],
                       stubs: { 'calendarView' => { 'value' => [sample_event_data] } })
      refute_match(/Enter #/, result[:stdout])
    end

    def test_non_tty_suppresses_prompt
      result = run_cal([],
                       stubs: { 'calendarView' => { 'value' => [sample_event_data] } })
      assert_match(/Weekly Standup/, result[:stdout])
      refute_match(/Enter #/, result[:stdout])
    end
  end

  # Tests for interactive mode prompts and navigation
  class InteractiveNavigationTest < Minitest::Test
    include InteractiveHelpers

    def test_interactive_prompt_appears_with_tty
      result = run_interactive("q\n", stubs: default_stubs)
      assert_includes result[:output], 'Enter #'
    end

    def test_interactive_select_event_shows_detail
      result = run_interactive("1\nq\n", stubs: default_stubs)
      assert_includes result[:output], 'Conference Room A'
      assert_includes result[:output], '[a]ccept'
    end

    def test_interactive_back_returns_to_list
      result = run_interactive("1\nb\nq\n", stubs: default_stubs)
      parts = result[:output].split('Enter #')
      assert parts.length >= 3, 'Expected list to re-appear after back'
    end

    def test_interactive_quit_from_detail
      result = run_interactive("1\nq\n", stubs: default_stubs)
      assert_equal 0, result[:result]
    end

    def test_interactive_invalid_selection
      result = run_interactive("99\nq\n", stubs: default_stubs)
      assert_includes result[:output], 'Invalid selection'
    end

    def test_interactive_unknown_action
      result = run_interactive("1\nx\nq\n", stubs: default_stubs)
      assert_includes result[:output], 'Unknown action'
    end

    def test_interactive_eof_quits
      result = run_interactive('', stubs: default_stubs)
      assert_equal 0, result[:result]
    end
  end

  # Tests for interactive mode RSVP and delete actions
  class InteractiveActionsTest < Minitest::Test
    include InteractiveHelpers

    def test_interactive_accept_action
      stubs = default_stubs.merge('accept' => {})
      result = run_interactive("1\na\nq\n", stubs: stubs)
      assert_includes result[:output], 'accepted'
    end

    def test_interactive_decline_action
      stubs = default_stubs.merge('decline' => {})
      result = run_interactive("1\nd\nq\n", stubs: stubs)
      assert_includes result[:output], 'declined'
    end

    def test_interactive_tentative_action
      stubs = default_stubs.merge('tentativelyAccept' => {})
      result = run_interactive("1\nt\nq\n", stubs: stubs)
      assert_includes result[:output], 'tentatively accepted'
    end

    def test_interactive_delete_action
      result = run_interactive("1\nD\n", stubs: default_stubs)
      assert_includes result[:output], 'Deleted'
      assert_equal 0, result[:result]
    end
  end

  # Tests for timezone detection and date range computation
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
