# frozen_string_literal: true

require 'test_helper'
require_relative 'cal_ics_helpers'

# cal ics --all-calendars: which calendars are read, and what happens when one cannot be
class CalIcsCalendarsTest < Minitest::Test
  include CalIcsTestHelpers

  # View stubs come first: the calendars list path is a prefix of theirs. The default
  # calendar is read through /me/calendarView.
  def test_all_calendars_merges_every_calendar_default_first
    stdout = run_ics(['--all-calendars'], stubs: {
                       '/me/calendarView' => { 'value' => [graph_event('a'), graph_event('shared')] },
                       'calendars/hol/calendarView' => { 'value' => [graph_event('holiday'), graph_event('shared')] },
                       '/v1.0/me/calendars' => { 'value' => [{ 'id' => 'hol' },
                                                             { 'id' => 'def', 'isDefaultCalendar' => true }] }
                     })

    assert_equal 0, @code
    assert_equal %w[a shared holiday], stdout.scan(/^UID:(\S+)\r$/).flatten
  end

  def calendars_with(shared_error)
    run_ics(['--all-calendars'],
            errors: { 'calendars/shr/calendarView' => shared_error },
            stubs: { '/me/calendarView' => { 'value' => [graph_event('a')] },
                     '/v1.0/me/calendars' => { 'value' => [{ 'id' => 'def', 'isDefaultCalendar' => true },
                                                           { 'id' => 'shr', 'name' => 'Pat' }] } })
  end

  def test_all_calendars_skips_a_calendar_it_cannot_read
    [Teems::ApiError.new('Access forbidden', status_code: 403),
     Teems::ApiError.new('HTTP 404: Not Found', status_code: 404)].each do |error|
      stdout = calendars_with(error)

      assert_equal 0, @code
      assert_equal %w[a], stdout.scan(/^UID:(\S+)\r$/).flatten
      assert_includes @stderr, %(Skipped calendar "Pat": #{error.message})
    end
  end

  def test_all_calendars_still_fails_on_other_errors
    [Teems::ApiError.new('HTTP 500: Server Error', status_code: 500),
     Teems::ApiError.new('Invalid token or session expired', status_code: 401)].each do |error|
      stdout = calendars_with(error)

      assert_equal 1, @code
      assert_empty stdout
    end
  end

  # An empty feed would make subscribed clients delete every event
  def test_all_calendars_never_skips_the_default_calendar
    forbidden = Teems::ApiError.new('Access forbidden', status_code: 403)
    stdout = run_ics(['--all-calendars'],
                     errors: { '/me/calendarView' => forbidden },
                     stubs: { 'calendars/hol/calendarView' => { 'value' => [graph_event('holiday')] },
                              '/v1.0/me/calendars' => { 'value' => [{ 'id' => 'def', 'isDefaultCalendar' => true },
                                                                    { 'id' => 'hol' }] } })

    assert_equal 1, @code
    assert_empty stdout
    refute_includes @stderr, 'Skipped calendar'
  end

  def test_default_calendar_errors_are_not_skipped
    stdout = run_ics([], errors: { 'calendarView' => Teems::ApiError.new('Access forbidden', status_code: 403) })

    assert_equal 1, @code
    assert_empty stdout
    assert_includes @stderr, 'Access forbidden'
  end
end
