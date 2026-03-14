# frozen_string_literal: true

module Teems
  module Commands
    # List calendar events and view event details
    class Cal < Base
      # Map common timezone abbreviations to IANA names
      TIMEZONE_MAP = {
        'EST' => 'America/New_York',
        'EDT' => 'America/New_York',
        'CST' => 'America/Chicago',
        'CDT' => 'America/Chicago',
        'MST' => 'America/Denver',
        'MDT' => 'America/Denver',
        'PST' => 'America/Los_Angeles',
        'PDT' => 'America/Los_Angeles',
        'AKST' => 'America/Anchorage',
        'AKDT' => 'America/Anchorage',
        'HST' => 'Pacific/Honolulu',
        'UTC' => 'UTC',
        'GMT' => 'UTC'
      }.freeze

      RSVP_ACTIONS = %w[accept decline tentative].freeze

      RSVP_ACTION_LABELS = {
        'accept' => 'accepted',
        'decline' => 'declined',
        'tentative' => 'tentatively accepted'
      }.freeze

      def execute
        result = validate_options
        return result if result

        auth_result = require_auth
        return auth_result if auth_result

        dispatch_subcommand
      end

      protected

      def handle_option(arg, args, remaining)
        case arg
        when '--days'    then @options[:days] = args.shift.to_i
        when '--week'    then @options[:week] = true
        when '--date'    then @options[:date] = args.shift
        when '--comment' then @options[:comment] = args.shift
        when '--no-send' then @options[:send_response] = false
        else super
        end
      end

      def help_text
        <<~HELP
          #{output.bold('teems cal')} - List calendar events and view details

          #{output.bold('USAGE:')}
            teems cal [options]              List today's events
            teems cal today                  List today's events (alias)
            teems cal tomorrow               List tomorrow's events
            teems cal show <N>               Show details for event #N
            teems cal accept <N>             Accept event #N
            teems cal decline <N>            Decline event #N
            teems cal tentative <N>          Tentatively accept event #N

          #{output.bold('OPTIONS:')}
            --days N             Show events for the next N days (default: 1)
            --week               Show events for the current week (Mon-Fri)
            --date YYYY-MM-DD    Show events for a specific date
            --comment TEXT       Add a comment to RSVP response
            --no-send            Don't send response to organizer
            -n, --limit N        Maximum number of events to show
            -v, --verbose        Show attendee summaries
            -q, --quiet          Suppress output
            --json               Output as JSON
            -h, --help           Show this help

          #{output.bold('EXAMPLES:')}
            teems cal                # Today's agenda
            teems cal today          # Same as above
            teems cal tomorrow       # Tomorrow's events
            teems cal --days 3       # Next 3 days
            teems cal --week         # This work week
            teems cal --date 2026-01-20   # Specific date
            teems cal show 3         # Details for event #3
            teems cal accept 3       # Accept event #3
            teems cal decline 3 --comment "Out of office"
        HELP
      end

      private

      def dispatch_subcommand
        case @subcommand
        when 'show'                 then show_event
        when 'accept', 'decline', 'tentative' then rsvp_event
        else list_events
        end
      end

      def parse_options(args)
        remaining = super
        parse_subcommand(remaining)
      end

      def parse_subcommand(remaining)
        case remaining.first
        when 'show'      then parse_show_subcommand(remaining)
        when 'today'     then parse_today_subcommand(remaining)
        when 'tomorrow'  then parse_tomorrow_subcommand(remaining)
        when *RSVP_ACTIONS then parse_rsvp_subcommand(remaining)
        else @subcommand = 'list'
        end
        remaining
      end

      def parse_show_subcommand(remaining)
        @subcommand = 'show'
        remaining.shift
        @event_number = remaining.shift&.to_i
      end

      def parse_today_subcommand(remaining)
        @subcommand = 'list'
        remaining.shift
      end

      def parse_tomorrow_subcommand(remaining)
        @subcommand = 'list'
        remaining.shift
        @options[:date] = (Date.today + 1).to_s
      end

      def parse_rsvp_subcommand(remaining)
        @subcommand = remaining.shift
        @event_number = remaining.shift&.to_i
      end

      def detect_timezone
        if (tz_env = ENV.fetch('TZ', nil)) && !tz_env.empty?
          return tz_env if tz_env.include?('/')

          return TIMEZONE_MAP[tz_env] || tz_env
        end

        zone_abbrev = Time.now.strftime('%Z')
        TIMEZONE_MAP[zone_abbrev] || 'UTC'
      end

      def compute_date_range
        start_dt, end_dt = date_range_boundaries
        [format_datetime(start_dt), format_datetime(end_dt)]
      rescue Date::Error
        nil
      end

      def date_range_boundaries
        if @options[:date]
          date_range_for_date
        elsif @options[:week]
          date_range_for_week
        else
          date_range_for_days
        end
      end

      def date_range_for_date
        date = Date.parse(@options[:date])
        [day_start(date), day_end(date)]
      end

      def date_range_for_week
        today = Date.today
        monday = today - (today.wday.zero? ? 6 : today.wday - 1)
        [day_start(monday), day_end(monday + 4)]
      end

      def date_range_for_days
        today = Date.today
        end_date = today + (@options[:days] || 1) - 1
        [day_start(today), day_end(end_date)]
      end

      def day_start(date)
        Time.new(date.year, date.month, date.day, 0, 0, 0)
      end

      def day_end(date)
        Time.new(date.year, date.month, date.day, 23, 59, 59)
      end

      def format_datetime(time)
        time.strftime('%Y-%m-%dT%H:%M:%S')
      end

      def list_events
        range = compute_date_range
        return (error("Invalid date: #{@options[:date]}") && 1) unless range

        events = fetch_events(range)
        return 0 if events.empty? && (puts('No events found') || true)

        cache_event_ids(events)
        render_events(events)
        0
      rescue ApiError => e
        error("Failed to fetch calendar: #{e.message}")
        1
      end

      def fetch_events(range)
        start_dt, end_dt = range
        with_token_refresh do
          runner.calendar_api.list_events(
            start_dt: start_dt, end_dt: end_dt,
            timezone: detect_timezone, top: @options[:limit]
          )
        end
      end

      def cache_event_ids(events)
        ids_hash = {}
        events.each_with_index { |event, i| ids_hash[(i + 1).to_s] = event.id }
        cache_store.save_calendar_ids(ids_hash)
      end

      def render_events(events)
        if @options[:json]
          output_json(events.map { |e| event_to_hash(e) })
        else
          formatter = Formatters::CalendarFormatter.new(output: output)
          puts formatter.format_event_list(events, verbose: @options[:verbose])
        end
      end

      def show_event
        return missing_event_number unless @event_number&.positive?

        event_id = lookup_event_id
        return 1 unless event_id

        render_single_event(event_id)
      rescue ApiError => e
        error("Failed to fetch event: #{e.message}")
        1
      end

      def render_single_event(event_id)
        event = with_token_refresh do
          runner.calendar_api.get_event(event_id: event_id, timezone: detect_timezone)
        end

        if @options[:json]
          output_json(event_to_hash(event))
        else
          formatter = Formatters::CalendarFormatter.new(output: output)
          puts formatter.format_event_detail(event)
        end
        0
      end

      def rsvp_event
        return missing_event_number unless @event_number&.positive?

        event_id = lookup_event_id
        return 1 unless event_id

        send_rsvp(event_id)
      rescue ApiError => e
        error("Failed to respond to event: #{e.message}")
        1
      end

      def send_rsvp(event_id)
        with_token_refresh do
          runner.calendar_api.rsvp_event(
            event_id: event_id, action: @subcommand,
            comment: @options[:comment],
            send_response: @options.fetch(:send_response, true)
          )
        end

        success("Event ##{@event_number} #{RSVP_ACTION_LABELS[@subcommand]}")
        0
      end

      def missing_event_number
        action = @subcommand == 'show' ? 'show' : @subcommand
        error("Event number required. Usage: teems cal #{action} <N>")
        1
      end

      def lookup_event_id
        event_id = cache_store.get_calendar_id(@event_number)
        return event_id if event_id

        error("Event ##{@event_number} not found. Run 'teems cal' first to list events.")
        nil
      end

      def event_to_hash(event)
        event.to_h.merge(
          start_time: event.start_time&.iso8601,
          end_time: event.end_time&.iso8601
        )
      end
    end
  end
end
