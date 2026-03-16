# frozen_string_literal: true

module Teems
  module Commands
    CAL_HELP = <<~HELP
      teems cal - List calendar events and view details

      USAGE:
        teems cal [options]              List today's events
        teems cal today                  List today's events (alias)
        teems cal tomorrow               List tomorrow's events
        teems cal show <N>               Show details for event #N
        teems cal accept <N>             Accept event #N
        teems cal decline <N>            Decline event #N
        teems cal tentative <N>          Tentatively accept event #N
        teems cal create "Title" [opts]  Create a new event
        teems cal delete <N>             Delete event #N

      OPTIONS:
        --days N             Show events for the next N days (default: 1)
        --week               Show events for the current week (Mon-Fri)
        --date YYYY-MM-DD    Show events for a specific date
        --comment TEXT        Add a comment to RSVP response
        --no-send            Don't send response to organizer
        -n, --limit N        Maximum number of events to show
        -v, --verbose        Show attendee summaries
        -q, --quiet          Suppress output
        --json               Output as JSON
        -h, --help           Show this help

      CREATE OPTIONS:
        --start TIME         Start time: "YYYY-MM-DD HH:MM", "today HH:MM",
                             "tomorrow HH:MM", or "HH:MM" (assumes today)
        --end TIME           End time (default: start + 30 minutes)
        --duration MIN       Duration in minutes (alternative to --end)
        --all-day            Create an all-day event (use with --date)
        --location TEXT      Event location
        --body TEXT          Event description
        --attendees EMAILS   Comma-separated email addresses
        --teams              Add a Teams online meeting link

      EXAMPLES:
        teems cal                # Today's agenda
        teems cal today          # Same as above
        teems cal tomorrow       # Tomorrow's events
        teems cal --days 3       # Next 3 days
        teems cal --week         # This work week
        teems cal --date 2026-01-20   # Specific date
        teems cal show 3         # Details for event #3
        teems cal accept 3       # Accept event #3
        teems cal decline 3 --comment "Out of office"
        teems cal create "Standup" --start "tomorrow 09:00" --duration 15
        teems cal create "Review" --start "2026-03-20 14:00" --teams \
          --attendees alice@example.com,bob@example.com
        teems cal delete 3       # Delete event #3
    HELP

    # Date range computation for calendar queries
    module CalDateRange
      # Map common timezone abbreviations to IANA names
      TIMEZONE_MAP = {
        'EST' => 'America/New_York', 'EDT' => 'America/New_York',
        'CST' => 'America/Chicago', 'CDT' => 'America/Chicago',
        'MST' => 'America/Denver', 'MDT' => 'America/Denver',
        'PST' => 'America/Los_Angeles', 'PDT' => 'America/Los_Angeles',
        'AKST' => 'America/Anchorage', 'AKDT' => 'America/Anchorage',
        'HST' => 'Pacific/Honolulu', 'UTC' => 'UTC', 'GMT' => 'UTC'
      }.freeze

      private

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
        monday = week_monday
        [day_start(monday), day_end(monday + 4)]
      end

      def week_monday
        today = Date.today
        today - (today.wday.zero? ? 6 : today.wday - 1)
      end

      def date_range_for_days
        today = Date.today
        end_date = today + (@options[:days] || 1) - 1
        [day_start(today), day_end(end_date)]
      end

      def day_start(date) = Time.new(date.year, date.month, date.day, 0, 0, 0)
      def day_end(date) = Time.new(date.year, date.month, date.day, 23, 59, 59)

      def format_datetime(time) = time.strftime('%Y-%m-%dT%H:%M:%S%:z')
    end

    # Subcommand parsing for cal command
    module CalSubcommandParser
      RSVP_ACTIONS = %w[accept decline tentative].freeze

      private

      def parse_options(args)
        remaining = super
        parse_subcommand(remaining)
      end

      def parse_subcommand(remaining)
        case remaining.first
        when 'show'      then parse_show_subcommand(remaining)
        when 'today'     then parse_today_subcommand(remaining)
        when 'tomorrow'  then parse_tomorrow_subcommand(remaining)
        when 'create'    then parse_create_subcommand(remaining)
        when 'delete'    then parse_delete_subcommand(remaining)
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

      def parse_create_subcommand(remaining)
        @subcommand = 'create'
        remaining.shift
        @create_subject = remaining.shift
      end

      def parse_delete_subcommand(remaining)
        @subcommand = 'delete'
        remaining.shift
        @event_number = remaining.shift&.to_i
      end
    end

    # Event display, RSVP, and detail subcommands
    module CalEventActions
      RSVP_ACTION_LABELS = {
        'accept' => 'accepted', 'decline' => 'declined', 'tentative' => 'tentatively accepted'
      }.freeze

      private

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
            notify: @options[:no_send] ? :silent : :send
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

      def delete_event
        return missing_event_number unless @event_number&.positive?

        event_id = lookup_event_id
        return 1 unless event_id

        send_delete(event_id)
      end

      def send_delete(event_id)
        event = fetch_event_for_display(event_id)
        with_token_refresh { runner.calendar_api.delete_event(event_id: event_id) }
        display_delete_result(event)
        0
      rescue ApiError => e
        error("Failed to delete event: #{e.message}")
        1
      end

      def fetch_event_for_display(event_id)
        with_token_refresh { runner.calendar_api.get_event(event_id: event_id, timezone: detect_timezone) }
      end

      def display_delete_result(event)
        success("Deleted: \"#{event.subject}\"")
        event.create_summary_lines.each { |line| puts "  #{line}" }
      end

      def event_to_hash(event)
        event.to_h.merge(start_time: event.start_time&.iso8601, end_time: event.end_time&.iso8601)
      end
    end

    # Time parsing for create subcommand
    module CalTimeParsing
      private

      def parse_time_input(raw)
        date, time_str = split_time_input(raw)
        return unless time_str

        date.is_a?(String) ? parse_absolute_time(date, time_str) : parse_relative_time(date, time_str)
      end

      def split_time_input(raw)
        if raw.start_with?('tomorrow ')
          [Date.today + 1, raw.delete_prefix('tomorrow ')]
        elsif raw.match?(/\A(?:today\s+)?\d{1,2}:\d{2}\z/)
          [Date.today, raw.delete_prefix('today ')]
        elsif raw.match?(/\A\d{4}-\d{2}-\d{2}\s+\d{1,2}:\d{2}\z/)
          raw.split(/\s+/, 2)
        end
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

    # Event creation subcommand
    module CalCreateActions
      include CalTimeParsing

      private

      def create_event
        return error('Event title required. Usage: teems cal create "Title" --start TIME') || 1 unless @create_subject

        times = resolve_create_times
        return times if times.is_a?(Integer)

        start_dt, end_dt = times
        send_create_request(start_dt, end_dt)
      rescue ApiError => e
        error("Failed to create event: #{e.message}")
        1
      end

      def resolve_create_times
        @options[:all_day] ? resolve_all_day_times : resolve_timed_event_times
      end

      def resolve_all_day_times
        date = @options[:date] || Date.today.to_s
        parsed = Date.parse(date)
        [parsed.strftime('%Y-%m-%dT00:00:00'), (parsed + 1).strftime('%Y-%m-%dT00:00:00')]
      rescue Date::Error
        error("Invalid date: #{date}") || 1
      end

      def resolve_timed_event_times
        start_input = @options[:start]
        unless start_input
          error('Start time required. Use --start "YYYY-MM-DD HH:MM" or --start "today HH:MM"')
          return 1
        end

        start_time = parse_time_input(start_input)
        return error("Invalid start time: #{start_input}") || 1 unless start_time

        end_time = compute_end_time(start_time)
        return end_time if end_time.is_a?(Integer)

        [format_time(start_time), format_time(end_time)]
      end

      def compute_end_time(start_time)
        end_input = @options[:end]
        if end_input
          parsed = parse_time_input(end_input)
          return error("Invalid end time: #{end_input}") || 1 unless parsed

          parsed
        else
          duration = @options[:duration] || 30
          return error('Duration must be a positive number of minutes') || 1 unless duration.positive?

          start_time + (duration * 60)
        end
      end

      def format_time(time)
        time.strftime('%Y-%m-%dT%H:%M:%S')
      end

      def send_create_request(start_dt, end_dt)
        event = with_token_refresh do
          runner.calendar_api.create_event(build_create_event(start_dt, end_dt))
        end
        display_create_result(event)
        0
      end

      def build_create_event(start_dt, end_dt)
        tz = detect_timezone
        body = { subject: @create_subject,
                 start: { dateTime: start_dt, timeZone: tz },
                 end: { dateTime: end_dt, timeZone: tz },
                 isAllDay: @options[:all_day] || false }
        add_optional_event_fields(body)
      end

      def add_optional_event_fields(body)
        body[:location] = { displayName: @options[:location] } if @options[:location]
        body[:body] = { contentType: 'text', content: @options[:body] } if @options[:body]
        body[:attendees] = @options[:attendees].map { |e| attendee_entry(e) } if @options[:attendees]
        add_teams_meeting(body) if @options[:teams]
        body
      end

      def add_teams_meeting(body)
        body[:isOnlineMeeting] = true
        body[:onlineMeetingProvider] = 'teamsForBusiness'
      end

      def attendee_entry(email)
        { emailAddress: { address: email }, type: 'required' }
      end

      def display_create_result(event)
        success("Created: \"#{event.subject}\"")
        event.create_summary_lines.each { |line| puts "  #{line}" }
      end
    end

    # List calendar events and view event details
    class Cal < Base
      include CalDateRange
      include CalSubcommandParser
      include CalEventActions
      include CalCreateActions

      def initialize(args, runner:)
        @options = {}
        @subcommand = nil
        @event_number = nil
        @create_subject = nil
        super
      end

      def execute
        result = validate_options
        return result if result

        auth_result = require_auth
        return auth_result if auth_result

        dispatch_subcommand
      end

      protected

      CAL_OPTIONS = {
        '--days' => ->(opts, args) { opts[:days] = args.shift.to_i },
        '--week' => ->(opts, _args) { opts[:week] = true },
        '--date' => ->(opts, args) { opts[:date] = args.shift },
        '--comment' => ->(opts, args) { opts[:comment] = args.shift },
        '--no-send' => ->(opts, _args) { opts[:no_send] = true },
        '--start' => ->(opts, args) { opts[:start] = args.shift },
        '--end' => ->(opts, args) { opts[:end] = args.shift },
        '--duration' => ->(opts, args) { opts[:duration] = args.shift.to_i },
        '--all-day' => ->(opts, _args) { opts[:all_day] = true },
        '--location' => ->(opts, args) { opts[:location] = args.shift },
        '--body' => ->(opts, args) { opts[:body] = args.shift },
        '--attendees' => ->(opts, args) { opts[:attendees] = args.shift&.split(',')&.map(&:strip) || [] },
        '--teams' => ->(opts, _args) { opts[:teams] = true }
      }.freeze

      def handle_option(arg, pending)
        handler = CAL_OPTIONS[arg]
        return super unless handler

        handler.call(@options, pending)
      end

      def help_text = CAL_HELP

      private

      def dispatch_subcommand
        case @subcommand
        when 'show' then show_event
        when 'create' then create_event
        when 'delete' then delete_event
        when 'accept', 'decline', 'tentative' then rsvp_event
        else list_events
        end
      end

      def list_events
        range = compute_date_range
        return error("Invalid date: #{@options[:date]}") && 1 unless range

        fetch_and_display_events(range)
      rescue ApiError => e
        error("Failed to fetch calendar: #{e.message}")
        1
      end

      def fetch_and_display_events(range)
        events = fetch_events(range)
        return 0 if events.empty? && (puts('No events found') || true)

        cache_event_ids(events)
        render_events(events)
        0
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
        events.each_with_index { |event, index| ids_hash[(index + 1).to_s] = event.id }
        cache_store.save_calendar_ids(ids_hash)
      end

      def render_events(events)
        if @options[:json]
          output_json(events.map { |event| event_to_hash(event) })
        else
          formatter = Formatters::CalendarFormatter.new(output: output)
          method = @options[:verbose] ? :format_event_list_verbose : :format_event_list_compact
          puts formatter.public_send(method, events)
        end
      end
    end
  end
end
