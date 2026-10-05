# frozen_string_literal: true

module Teems
  module Models
    # Date and time labels for an Event (expects start_time, end_time, all_day?, location, online_meeting_url)
    module EventDisplay
      def time_range_display
        return 'ALL DAY' if all_day?
        return '' unless start_time && end_time

        "#{start_time.strftime('%H:%M')}-#{end_time.strftime('%H:%M')}"
      end

      def date_display
        if all_day?
          "#{all_day_span} (all day)"
        elsif start_time && end_time
          "#{start_time.strftime('%Y-%m-%d %H:%M')}-#{end_time.strftime('%H:%M')}"
        end
      end

      # Graph ends all-day events at midnight after the last day, so a span is "first to last"
      def all_day_span
        first_day = start_time&.to_date
        last_day = end_time&.to_date&.prev_day
        return first_day.to_s unless first_day && last_day && last_day > first_day

        "#{first_day} to #{last_day}"
      end

      def create_summary_lines
        lines = []
        lines << date_display if date_display
        lines << "Location: #{location}" if location && !location.empty?
        lines << "Teams link: #{online_meeting_url}" if online_meeting_url
        lines
      end
    end
  end
end
