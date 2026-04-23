# frozen_string_literal: true

module Teems
  module Support
    # Shared time-input parsing for commands that accept schedule inputs
    # like "HH:MM", "today HH:MM", "tomorrow HH:MM", and "YYYY-MM-DD HH:MM".
    module TimeParsing
      private

      def parse_time_input(raw)
        date, time_str = split_time_input(raw)
        return unless time_str

        date.is_a?(String) ? parse_absolute_time(date, time_str) : parse_relative_time(date, time_str)
      end

      def split_time_input(raw)
        base = Date.today
        split_tomorrow_time(raw, base) || split_today_time(raw, base) || split_absolute_time(raw)
      end

      def split_tomorrow_time(raw, base)
        return unless raw.start_with?('tomorrow ')

        [base + 1, raw.delete_prefix('tomorrow ')]
      end

      def split_today_time(raw, base)
        return unless raw.match?(/\A(?:today\s+)?\d{1,2}:\d{2}\z/)

        [base, raw.delete_prefix('today ')]
      end

      def split_absolute_time(raw)
        return unless raw.match?(/\A\d{4}-\d{2}-\d{2}\s+\d{1,2}:\d{2}\z/)

        raw.split(/\s+/, 2)
      end

      def parse_relative_time(date, time_str)
        hour, min = time_str.split(':').map(&:to_i)
        Time.new(date.year, date.month, date.day, hour, min, 0)
      rescue ArgumentError
        nil
      end

      def parse_absolute_time(date_str, time_str)
        date = Date.parse(date_str)
        parse_relative_time(date, time_str)
      rescue Date::Error
        nil
      end
    end
  end
end
