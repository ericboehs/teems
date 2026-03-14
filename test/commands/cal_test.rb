# frozen_string_literal: true

require 'test_helper'

class CalCommandTest < Minitest::Test
  def test_requires_auth
    with_temp_config do
      result = capture_output do |output|
        store = mock_token_store(configured: false)
        runner = Teems::Runner.new(output: output, token_store: store)
        cmd = Teems::Commands::Cal.new([], runner: runner)
        cmd.execute
      end

      assert_match(/Not authenticated/, result[:stderr])
    end
  end

  def test_shows_help_with_help_flag
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        cmd = Teems::Commands::Cal.new(['--help'], runner: runner)
        cmd.execute
      end

      assert_match(/teems cal/, result[:stdout])
      assert_match(/USAGE:/, result[:stdout])
      assert_match(/--days/, result[:stdout])
      assert_match(/--week/, result[:stdout])
      assert_match(/--date/, result[:stdout])
    end
  end

  def test_help_includes_show_subcommand
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        cmd = Teems::Commands::Cal.new(['--help'], runner: runner)
        cmd.execute
      end

      assert_match(/show <N>/, result[:stdout])
    end
  end

  def test_unknown_option
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        cmd = Teems::Commands::Cal.new(['--unknown'], runner: runner)
        cmd.execute
      end

      assert_match(/Unknown option/, result[:stderr])
    end
  end

  def test_default_listing_today_events
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        runner.api_client.stub('calendarView', { 'value' => [sample_event_data] })
        cmd = Teems::Commands::Cal.new([], runner: runner)
        cmd.execute
      end

      assert_match(/Weekly Standup/, result[:stdout])
    end
  end

  def test_listing_with_no_events
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        runner.api_client.stub('calendarView', { 'value' => [] })
        cmd = Teems::Commands::Cal.new([], runner: runner)
        cmd.execute
      end

      assert_match(/No events found/, result[:stdout])
    end
  end

  def test_days_option
    with_temp_config do
      runner = configured_runner
      runner.api_client.stub('calendarView', { 'value' => [] })
      cmd = Teems::Commands::Cal.new(['--days', '3'], runner: runner)

      assert_equal 3, cmd.options[:days]
      cmd.execute
    end
  end

  def test_week_option
    with_temp_config do
      runner = configured_runner
      runner.api_client.stub('calendarView', { 'value' => [] })
      cmd = Teems::Commands::Cal.new(['--week'], runner: runner)

      assert cmd.options[:week]
      cmd.execute
    end
  end

  def test_date_option
    with_temp_config do
      runner = configured_runner
      runner.api_client.stub('calendarView', { 'value' => [] })
      cmd = Teems::Commands::Cal.new(['--date', '2026-01-20'], runner: runner)

      assert_equal '2026-01-20', cmd.options[:date]
      cmd.execute
    end
  end

  def test_invalid_date_option
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        cmd = Teems::Commands::Cal.new(['--date', 'not-a-date'], runner: runner)
        cmd.execute
      end

      assert_match(/Invalid date/, result[:stderr])
    end
  end

  def test_json_output
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        runner.api_client.stub('calendarView', { 'value' => [sample_event_data] })
        cmd = Teems::Commands::Cal.new(['--json'], runner: runner)
        cmd.execute
      end

      json = JSON.parse(result[:stdout])
      assert_instance_of Array, json
      assert_equal 'Weekly Standup', json[0]['subject']
    end
  end

  def test_verbose_mode
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        runner.api_client.stub('calendarView', { 'value' => [sample_event_data] })
        cmd = Teems::Commands::Cal.new(['-v'], runner: runner)
        cmd.execute
      end

      assert_match(/Weekly Standup/, result[:stdout])
      assert_match(/Alice Manager/, result[:stdout])
    end
  end

  def test_show_subcommand_without_number
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        cmd = Teems::Commands::Cal.new(['show'], runner: runner)
        cmd.execute
      end

      assert_match(/Event number required/, result[:stderr])
    end
  end

  def test_show_subcommand_with_uncached_number
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        cmd = Teems::Commands::Cal.new(['show', '1'], runner: runner)
        cmd.execute
      end

      assert_match(/not found/, result[:stderr])
    end
  end

  def test_show_subcommand_with_cached_event
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        runner.cache_store.set_calendar_ids({ '1' => 'AAMkAGVmMDEzMTM4LTZmYWUtNDdkNC1hMDZe' })
        runner.api_client.stub('events', sample_event_data)
        cmd = Teems::Commands::Cal.new(['show', '1'], runner: runner)
        cmd.execute
      end

      assert_match(/Weekly Standup/, result[:stdout])
      assert_match(/Conference Room A/, result[:stdout])
    end
  end

  def test_show_subcommand_with_json
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        runner.cache_store.set_calendar_ids({ '1' => 'event-123' })
        runner.api_client.stub('events', sample_event_data)
        cmd = Teems::Commands::Cal.new(['show', '1', '--json'], runner: runner)
        cmd.execute
      end

      json = JSON.parse(result[:stdout])
      assert_equal 'Weekly Standup', json['subject']
    end
  end

  def test_api_error_handling_list
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        runner.api_client.stub_error('calendarView', Teems::ApiError.new('Forbidden', status_code: 403))
        cmd = Teems::Commands::Cal.new([], runner: runner)
        cmd.execute
      end

      assert_match(/Failed to fetch calendar/, result[:stderr])
    end
  end

  def test_api_error_handling_show
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        runner.cache_store.set_calendar_ids({ '1' => 'event-123' })
        runner.api_client.stub_error('events', Teems::ApiError.new('Not found', status_code: 404))
        cmd = Teems::Commands::Cal.new(['show', '1'], runner: runner)
        cmd.execute
      end

      assert_match(/Failed to fetch event/, result[:stderr])
    end
  end

  def test_events_are_numbered_in_output
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        events = [
          sample_event_data,
          sample_event_data.merge('id' => 'event-2', 'subject' => 'Lunch Break')
        ]
        runner.api_client.stub('calendarView', { 'value' => events })
        cmd = Teems::Commands::Cal.new([], runner: runner)
        cmd.execute
      end

      assert_match(/\[1\]/, result[:stdout])
      assert_match(/\[2\]/, result[:stdout])
      assert_match(/Weekly Standup/, result[:stdout])
      assert_match(/Lunch Break/, result[:stdout])
    end
  end

  def test_limit_option_passed_to_api
    with_temp_config do
      runner = configured_runner
      runner.api_client.stub('calendarView', { 'value' => [] })
      cmd = Teems::Commands::Cal.new(['-n', '10'], runner: runner)
      cmd.execute

      call = runner.api_client.calls.first
      assert_equal 10, call[:params]['$top']
    end
  end
end
