# frozen_string_literal: true

module Teems
  module Commands
    # `teems cal ics`: events from days-back days ago to days ahead as an ICS calendar,
    # for a subscription server (outlook-cli's outlook-calendar-server) to serve
    module CalIcsExport
      ICS_DEFAULTS = { days: 60, days_back: 7, name: 'Outlook (teems)' }.freeze
      DAY_SECONDS = 86_400

      protected

      # Under --no-login only the silent headless login is tried, never Safari, so servers
      # and launchd jobs never open a window
      def auto_login = @options[:no_login] ? silent_login : super

      private

      def export_ics
        now = Time.now
        events = with_token_refresh { fetch_feed_events(now) }
        excluded = excluded_addresses
        kept = events.reject { |event| event.involves?(excluded) }
        # The calendar is the command's result, so -q does not silence it
        output.print(Formatters::IcsFormat.calendar(kept, name: ics_option(:name), stamp: now))
        0
      rescue ApiError => e
        api_error_result('Failed to fetch calendar', e)
      end

      # With --all-calendars, a shared calendar that cannot be read is warned about and left
      # out, so one calendar does not take down the feed
      def fetch_feed_events(now)
        api = runner.calendar_api
        range = { from: ics_start(now), to: ics_end(now) }
        return api.feed_events(**range) unless @options[:all_calendars]

        api.feed_events(**range, views: api.calendar_views) do |name, error|
          warn("Skipped calendar #{name.inspect}: #{error.message}")
        end
      end

      def ics_option(key) = @options[key] || ICS_DEFAULTS.fetch(key)

      def ics_start(now) = now - (ics_option(:days_back) * DAY_SECONDS)

      def ics_end(now) = now + (ics_option(:days) * DAY_SECONDS)

      # Comma, semicolon or space separated, compared without case
      def excluded_addresses = @options[:exclude_attendee].to_s.downcase.split(/[\s,;]+/).reject(&:empty?)
    end
  end
end
