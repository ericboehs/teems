# frozen_string_literal: true

require 'test_helper'

class CalIcsCommandTest < Minitest::Test
  def graph_event(uid, organizer: 'olive@example.com')
    { 'iCalUId' => uid, 'subject' => "Meeting #{uid}", 'isAllDay' => false,
      'start' => { 'dateTime' => '2026-10-21T14:00:00.0000000' },
      'end' => { 'dateTime' => '2026-10-21T15:00:00.0000000' },
      'organizer' => { 'emailAddress' => { 'name' => 'Org', 'address' => organizer } } }
  end

  # Runs `cal ics args` at a fixed time; returns stdout and stores the exit code and request params
  def run_ics(args, events: [graph_event('a')])
    with_temp_config do
      Time.stub(:now, Time.utc(2026, 10, 20, 12)) do
        capture_output do |output|
          runner = configured_runner(output: output)
          runner.api_client.stub('calendarView', { 'value' => events })
          @code = Teems::Commands::Cal.new(['ics', *args], runner: runner).execute
          @params = runner.api_client.calls.first[:params]
        end[:stdout]
      end
    end
  end

  def unconfigured_runner(output)
    Teems::Runner.new(output: output, token_store: mock_token_store(configured: false),
                      api_client: MockApiClient.new)
  end

  def test_prints_calendar
    stdout = run_ics([])

    assert_equal 0, @code
    assert stdout.start_with?("BEGIN:VCALENDAR\r\n")
    assert_includes stdout, "X-WR-CALNAME:Outlook (teems)\r\n"
    assert_includes stdout, "UID:a\r\n"
    assert_includes stdout, "DTSTAMP:20261020T120000Z\r\n"
  end

  def test_default_window_is_a_week_back_and_60_days_ahead
    run_ics([])

    assert_equal '2026-10-13T12:00:00Z', @params['startDateTime']
    assert_equal '2026-12-19T12:00:00Z', @params['endDateTime']
  end

  def test_window_and_name_options
    stdout = run_ics(['--days', '3', '--days-back', '0', '--name', 'Work (outlook-cli)'])

    assert_equal '2026-10-20T12:00:00Z', @params['startDateTime']
    assert_equal '2026-10-23T12:00:00Z', @params['endDateTime']
    assert_includes stdout, 'X-WR-CALNAME:Work (outlook-cli)'
  end

  def test_exclude_attendee
    events = [graph_event('mine'), graph_event('theirs', organizer: 'Me@Other.example')]
    stdout = run_ics(['--exclude-attendee', 'me@other.example, someone@else.example'], events: events)

    assert_includes stdout, 'UID:mine'
    refute_includes stdout, 'UID:theirs'
  end

  def test_api_errors
    with_temp_config do
      capture = capture_output do |output|
        runner = configured_runner(output: output)
        runner.api_client.stub_error('calendarView', Teems::ApiError.new('HTTP 500', status_code: 500))
        @code = Teems::Commands::Cal.new(%w[ics], runner: runner).execute
      end

      assert_equal 1, @code
      assert_includes capture[:stderr], 'Failed to fetch calendar'
      assert_empty capture[:stdout]
    end
  end

  def test_no_login_never_opens_safari
    with_temp_config do
      capture_output do |output|
        runner = unconfigured_runner(output)
        extractor = Teems::TestHelpers::SilentOnlyExtractor.new
        runner.define_singleton_method(:token_extractor) { |**| extractor }

        assert_equal 1, Teems::Commands::Cal.new(%w[ics --no-login], runner: runner).execute
        assert_equal 1, extractor.silent_calls
      end
    end
  end

  def test_without_no_login_tries_auto_login
    with_temp_config do
      capture_output do |output|
        runner = unconfigured_runner(output)
        extracted = []
        runner.define_singleton_method(:token_extractor) { |**| (extracted << true) && Teems::TestHelpers::NullExtractor.new }

        assert_equal 1, Teems::Commands::Cal.new(%w[ics], runner: runner).execute
        assert_equal [true], extracted
      end
    end
  end
end
