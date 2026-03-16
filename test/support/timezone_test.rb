# frozen_string_literal: true

require 'test_helper'

class TimezoneTest < Minitest::Test
  include Teems::Support::Timezone

  def test_detect_timezone_returns_iana_name
    tz = detect_timezone

    assert_kind_of String, tz
    assert_match(%r{/|UTC}, tz)
  end

  def test_detect_timezone_respects_tz_env
    saved = ENV.fetch('TZ', nil)
    ENV['TZ'] = 'America/Denver'
    assert_equal 'America/Denver', detect_timezone
  ensure
    ENV['TZ'] = saved
  end

  def test_detect_timezone_maps_abbreviated_tz_env
    saved = ENV.fetch('TZ', nil)
    ENV['TZ'] = 'EST'
    assert_equal 'America/New_York', detect_timezone
  ensure
    ENV['TZ'] = saved
  end

  def test_detect_timezone_falls_back_to_system
    saved = ENV.fetch('TZ', nil)
    ENV.delete('TZ')
    tz = detect_timezone

    assert_kind_of String, tz
  ensure
    ENV['TZ'] = saved
  end

  def test_short_tz_label_strips_dst_indicator
    label = short_tz_label

    assert_kind_of String, label
    refute_empty label
    refute_match(/[DS]T$/, label) unless label.length <= 2
  end
end
