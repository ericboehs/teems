# frozen_string_literal: true

require 'test_helper'

class MailDueDateTest < Minitest::Test
  # A Wednesday
  TODAY = Date.new(2026, 10, 21)

  def parse(text) = Teems::Commands::MailDueDate.parse(text, today: TODAY)

  def test_relative_days
    assert_equal TODAY, parse('today')
    assert_equal TODAY + 1, parse(' Tomorrow ')
  end

  def test_weekdays_are_the_next_one_today_included
    assert_equal TODAY, parse('wednesday')
    assert_equal Date.new(2026, 10, 23), parse('fri')
    assert_equal Date.new(2026, 10, 26), parse('Monday')
    assert_nil parse('fr')
  end

  def test_iso_dates_and_nonsense
    assert_equal Date.new(2026, 11, 3), parse('2026-11-03')
    assert_nil parse('someday')
    assert_nil parse('2026-13-40')
    assert_nil parse(nil)
  end
end
