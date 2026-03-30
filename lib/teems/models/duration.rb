# frozen_string_literal: true

module Teems
  module Models
    DURATION_PATTERN = /\A(?:(\d+)h)?(?:(\d+)m)?\z/

    # Immutable duration value object for human-friendly time input
    Duration = Data.define(:seconds) do
      def self.parse(input)
        label = input.inspect
        match = DURATION_PATTERN.match(input.to_s.strip)
        raise ArgumentError, "Invalid duration: #{label}" unless match

        total = (match[1].to_i * 3600) + (match[2].to_i * 60)
        raise ArgumentError, "Duration must be greater than zero: #{label}" if total.zero?

        new(seconds: total)
      end

      def to_iso8601_duration
        parts = []
        parts << "#{hours}H" if hours.positive?
        parts << "#{minutes}M" if minutes.positive?
        "PT#{parts.join}"
      end

      def to_expiration
        (Time.now.utc + seconds).strftime('%Y-%m-%dT%H:%M:%S.0000000Z')
      end

      def to_s
        parts = []
        parts << "#{hours}h" if hours.positive?
        parts << "#{minutes}m" if minutes.positive?
        parts.join(' ')
      end

      def empty? = seconds.zero?

      private

      def hours = seconds / 3600
      def minutes = (seconds % 3600) / 60
    end
  end
end
