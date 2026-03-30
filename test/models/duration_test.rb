# frozen_string_literal: true

require 'test_helper'

# Tests Duration model parsing, ISO 8601 formatting, expiration, and display
module DurationTests
  # Tests for Duration.parse
  class ParseTest < Minitest::Test
    def test_parses_hours
      duration = Teems::Models::Duration.parse('2h')
      assert_equal 7200, duration.seconds
    end

    def test_parses_minutes
      duration = Teems::Models::Duration.parse('30m')
      assert_equal 1800, duration.seconds
    end

    def test_parses_combined
      duration = Teems::Models::Duration.parse('1h30m')
      assert_equal 5400, duration.seconds
    end

    def test_rejects_empty_string
      assert_raises(ArgumentError) { Teems::Models::Duration.parse('') }
    end

    def test_rejects_garbage
      assert_raises(ArgumentError) { Teems::Models::Duration.parse('abc') }
    end

    def test_rejects_zero_duration
      assert_raises(ArgumentError) { Teems::Models::Duration.parse('0h') }
    end

    def test_rejects_no_unit
      assert_raises(ArgumentError) { Teems::Models::Duration.parse('30') }
    end

    def test_strips_whitespace
      duration = Teems::Models::Duration.parse('  2h  ')
      assert_equal 7200, duration.seconds
    end
  end

  # Tests for #to_iso8601_duration
  class ToIso8601DurationTest < Minitest::Test
    def test_hours_only
      assert_equal 'PT2H', Teems::Models::Duration.parse('2h').to_iso8601_duration
    end

    def test_minutes_only
      assert_equal 'PT30M', Teems::Models::Duration.parse('30m').to_iso8601_duration
    end

    def test_combined
      assert_equal 'PT1H30M', Teems::Models::Duration.parse('1h30m').to_iso8601_duration
    end
  end

  # Tests for #to_expiration
  class ToExpirationTest < Minitest::Test
    def test_returns_future_utc_datetime
      frozen_time = Time.utc(2026, 3, 19, 12, 0, 0)
      Time.stub(:now, frozen_time) do
        result = Teems::Models::Duration.parse('2h').to_expiration
        assert_equal '2026-03-19T14:00:00.0000000Z', result
      end
    end

    def test_returns_utc_format
      result = Teems::Models::Duration.parse('1h').to_expiration
      assert_match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.0{7}Z/, result)
    end
  end

  # Tests for #to_s
  class ToStringTest < Minitest::Test
    def test_hours_only
      assert_equal '2h', Teems::Models::Duration.parse('2h').to_s
    end

    def test_minutes_only
      assert_equal '30m', Teems::Models::Duration.parse('30m').to_s
    end

    def test_combined
      assert_equal '1h 30m', Teems::Models::Duration.parse('1h30m').to_s
    end
  end

  # Tests for #empty?
  class PredicatesTest < Minitest::Test
    def test_not_empty
      refute Teems::Models::Duration.parse('1h').empty?
    end

    def test_empty_with_zero_seconds
      duration = Teems::Models::Duration.new(seconds: 0)
      assert duration.empty?
    end
  end
end
