# frozen_string_literal: true

module Teems
  module Support
    # Shared timezone detection logic for calendar and schedule commands
    module Timezone
      TIMEZONE_MAP = {
        'EST' => 'America/New_York', 'EDT' => 'America/New_York',
        'CST' => 'America/Chicago', 'CDT' => 'America/Chicago',
        'MST' => 'America/Denver', 'MDT' => 'America/Denver',
        'PST' => 'America/Los_Angeles', 'PDT' => 'America/Los_Angeles',
        'AKST' => 'America/Anchorage', 'AKDT' => 'America/Anchorage',
        'HST' => 'Pacific/Honolulu', 'UTC' => 'UTC', 'GMT' => 'UTC'
      }.freeze

      def detect_timezone
        tz_from_env || tz_from_system
      end

      def short_tz_label
        abbrev = tz_from_system_abbrev
        abbrev.gsub(/[DS](?=T$)/, '')
      end

      private

      def tz_from_system_abbrev
        Time.now.strftime('%Z')
      end

      def tz_from_env
        tz_env = ENV.fetch('TZ', nil)
        return nil if tz_env.to_s.empty?
        return tz_env if tz_env.include?('/')

        TIMEZONE_MAP[tz_env]
      end

      def tz_from_system
        TIMEZONE_MAP[Time.now.strftime('%Z')] || 'UTC'
      end
    end
  end
end
