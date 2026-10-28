# frozen_string_literal: true

require 'test_helper'

# The "now", "HH:MM", "today HH:MM", "tomorrow HH:MM" and "YYYY-MM-DD HH:MM" inputs
# that cal create, ooo and meet accept
class TimeParsingTest < Minitest::Test
  # Exposes the private parser
  class Parser
    include Teems::Support::TimeParsing

    def parse(raw) = parse_time_input(raw)
  end

  def parse(raw) = Parser.new.parse(raw)

  def test_now_is_the_current_minute
    Time.stub(:now, Time.new(2026, 3, 20, 14, 7, 42)) do
      assert_equal Time.new(2026, 3, 20, 14, 7, 0), parse('now')
      assert_equal Time.new(2026, 3, 20, 14, 7, 0), parse(' Now ')
    end
  end

  def test_clock_and_dated_times
    assert_equal Time.new(2026, 3, 21, 9, 30, 0), parse('2026-03-21 09:30')
    assert_equal([9, 30], parse('9:30').then { |time| [time.hour, time.min] })
    assert_equal Date.today + 1, parse('tomorrow 08:00').to_date
  end

  # Shaped right but impossible: no 25th hour, no 13th month
  def test_impossible_times_and_dates_are_nil
    assert_nil parse('25:99')
    assert_nil parse('2026-13-45 10:00')
    assert_nil parse('soon')
  end
end
