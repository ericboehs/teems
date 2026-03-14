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

      def execute
        result = validate_options
        return result if result

        auth_result = require_auth
        return auth_result if auth_result

        if @subcommand == 'show'
          show_event
        else
          list_events
        end
      end

      protected

      def handle_option(arg, args, remaining)
        case arg
        when '--days'
          @options[:days] = args.shift.to_i
        when '--week'
          @options[:week] = true
        when '--date'
          @options[:date] = args.shift
        else
          super
        end
      end

      def help_text
        <<~HELP
          #{output.bold('teems cal')} - List calendar events and view details

          #{output.bold('USAGE:')}
            teems cal [options]              List today's events
            teems cal show <N>               Show details for event #N

          #{output.bold('OPTIONS:')}
            --days N             Show events for the next N days (default: 1)
            --week               Show events for the current week (Mon-Fri)
            --date YYYY-MM-DD    Show events for a specific date
            -n, --limit N        Maximum number of events to show
            -v, --verbose        Show attendee summaries
            -q, --quiet          Suppress output
            --json               Output as JSON
            -h, --help           Show this help

          #{output.bold('EXAMPLES:')}
            teems cal                # Today's agenda
            teems cal --days 3       # Next 3 days
            teems cal --week         # This work week
            teems cal --date 2026-01-20   # Specific date
            teems cal show 3         # Details for event #3
        HELP
      end

      private

      def parse_options(args)
        remaining = super(args)

        # Detect "show <N>" subcommand from positional args
        if remaining.first == 'show'
          @subcommand = 'show'
          remaining.shift
          @show_number = remaining.shift&.to_i
        else
          @subcommand = 'list'
        end

        remaining
      end

      def detect_timezone
        # Check ENV['TZ'] first
        if (tz_env = ENV['TZ']) && !tz_env.empty?
          return tz_env if tz_env.include?('/')

          return TIMEZONE_MAP[tz_env] || tz_env
        end

        # Auto-detect from system
        zone_abbrev = Time.now.strftime('%Z')
        TIMEZONE_MAP[zone_abbrev] || 'UTC'
      end

      def compute_date_range
        if @options[:date]
          date = Date.parse(@options[:date])
          start_dt = Time.new(date.year, date.month, date.day, 0, 0, 0)
          end_dt = Time.new(date.year, date.month, date.day, 23, 59, 59)
        elsif @options[:week]
          today = Date.today
          # Monday of current week
          monday = today - (today.wday == 0 ? 6 : today.wday - 1)
          friday = monday + 4
          start_dt = Time.new(monday.year, monday.month, monday.day, 0, 0, 0)
          end_dt = Time.new(friday.year, friday.month, friday.day, 23, 59, 59)
        else
          days = @options[:days] || 1
          today = Date.today
          end_date = today + days - 1
          start_dt = Time.new(today.year, today.month, today.day, 0, 0, 0)
          end_dt = Time.new(end_date.year, end_date.month, end_date.day, 23, 59, 59)
        end

        [format_datetime(start_dt), format_datetime(end_dt)]
      rescue Date::Error
        nil
      end

      def format_datetime(time)
        time.strftime('%Y-%m-%dT%H:%M:%S')
      end

      def list_events
        range = compute_date_range
        unless range
          error("Invalid date: #{@options[:date]}")
          return 1
        end

        start_dt, end_dt = range
        timezone = detect_timezone

        events = with_token_refresh do
          runner.calendar_api.list_events(
            start_dt: start_dt,
            end_dt: end_dt,
            timezone: timezone,
            top: @options[:limit]
          )
        end

        if events.empty?
          puts 'No events found'
          return 0
        end

        # Cache event IDs for "show <N>" lookup
        ids_hash = {}
        events.each_with_index { |event, i| ids_hash[(i + 1).to_s] = event.id }
        cache_store.set_calendar_ids(ids_hash)

        if @options[:json]
          output_json(events.map { |e| event_to_hash(e) })
        else
          formatter = Formatters::CalendarFormatter.new(output: output)
          puts formatter.format_event_list(events, verbose: @options[:verbose])
        end

        0
      rescue ApiError => e
        error("Failed to fetch calendar: #{e.message}")
        1
      end

      def show_event
        unless @show_number && @show_number.positive?
          error('Event number required. Usage: teems cal show <N>')
          return 1
        end

        event_id = cache_store.get_calendar_id(@show_number)
        unless event_id
          error("Event ##{@show_number} not found. Run 'teems cal' first to list events.")
          return 1
        end

        timezone = detect_timezone

        event = with_token_refresh do
          runner.calendar_api.get_event(event_id: event_id, timezone: timezone)
        end

        if @options[:json]
          output_json(event_to_hash(event))
        else
          formatter = Formatters::CalendarFormatter.new(output: output)
          puts formatter.format_event_detail(event)
        end

        0
      rescue ApiError => e
        error("Failed to fetch event: #{e.message}")
        1
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
