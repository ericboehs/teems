# frozen_string_literal: true

module Teems
  module Commands
    CAL_HELP = <<~HELP
      teems cal - List calendar events and view details

      USAGE:
        teems cal [options]              List today's events (interactive when TTY)
        teems cal today                  List today's events (alias)
        teems cal tomorrow               List tomorrow's events
        teems cal show <N|hash>          Show details for event by # or hash
        teems cal accept <N|hash>        Accept event by # or hash
        teems cal decline <N|hash>       Decline event by # or hash
        teems cal tentative <N|hash>     Tentatively accept event by # or hash
        teems cal create "Title" [opts]  Create a new event
        teems cal delete <N|hash>        Delete event by # or hash

      OPTIONS:
        --days N             Show events for the next N days (default: 1)
        --week               Show events for the current week (Mon-Fri)
        --date YYYY-MM-DD    Show events for a specific date
        --no-interactive     Disable interactive mode (list and exit)
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
        teems cal                        # Interactive agenda (TTY)
        teems cal --no-interactive       # List and exit
        teems cal today                  # Same as above
        teems cal tomorrow               # Tomorrow's events
        teems cal --days 3               # Next 3 days
        teems cal --week                 # This work week
        teems cal --date 2026-01-20      # Specific date
        teems cal show 3                 # Details for event #3
        teems cal show a3f2b1            # Details by short hash
        teems cal accept 3               # Accept event #3
        teems cal accept a3f2            # Accept by hash prefix
        teems cal decline 3 --comment "Out of office"
        teems cal create "Standup" --start "tomorrow 09:00" --duration 15
        teems cal create "Review" --start "2026-03-20 14:00" --teams \
          --attendees alice@example.com,bob@example.com
        teems cal delete 3               # Delete event #3
        teems cal --json | jq ...        # JSON output, no prompt
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
        tz_from_env = resolve_tz_env
        tz_from_env || timezone_from_system
      end

      def resolve_tz_env
        tz_env = ENV.fetch('TZ', '')
        return if tz_env.empty?

        TIMEZONE_MAP.fetch(tz_env) { tz_env }
      end

      def timezone_from_system
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
        @week_monday ||= compute_week_monday(@options[:days] || 5)
      end

      def compute_week_monday(_week_length)
        today = Date.today
        offset = today.wday
        today - (offset.zero? ? 6 : offset - 1)
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

      def format_datetime(time) = time.strftime('%Y-%m-%dT%H:%M:%S%:z')
    end

    # Subcommand parsing for cal command
    module CalSubcommandParser
      RSVP_ACTIONS = %w[accept decline tentative].freeze

      SUBCOMMAND_PARSERS = {
        'show' => :parse_show_subcommand, 'today' => :parse_today_subcommand,
        'tomorrow' => :parse_tomorrow_subcommand, 'create' => :parse_create_subcommand,
        'delete' => :parse_delete_subcommand
      }.freeze

      private

      def parse_options(args)
        remaining = super
        parse_subcommand(remaining)
      end

      def parse_subcommand(remaining)
        dispatch_subcommand_parse(remaining)
        remaining
      end

      def dispatch_subcommand_parse(remaining)
        subcommand = remaining.first
        parser = SUBCOMMAND_PARSERS[subcommand]
        if parser then send(parser, remaining)
        elsif RSVP_ACTIONS.include?(subcommand) then parse_rsvp_subcommand(remaining)
        else @subcommand = 'list'
        end
      end

      def parse_show_subcommand(remaining)
        @subcommand = 'show'
        _subcommand, event_arg = remaining.shift(2)
        @event_ref = event_arg
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
        action, event_arg = remaining.shift(2)
        @subcommand = action
        @event_ref = event_arg
      end

      def parse_create_subcommand(remaining)
        @subcommand = 'create'
        _subcommand, subject = remaining.shift(2)
        @create_subject = subject
      end

      def parse_delete_subcommand(remaining)
        @subcommand = 'delete'
        _subcommand, event_arg = remaining.shift(2)
        @event_ref = event_arg
      end
    end

    # Event resolution by number or short hash
    module CalEventResolver
      private

      def resolve_event_id
        @resolve_events = fetch_current_events
        event = resolve_by_ref(@event_ref)
        return event.id if event

        error("Event '#{@event_ref}' not found")
        nil
      end

      def resolve_by_ref(ref)
        ref.match?(/\A\d+\z/) ? event_by_number(ref) : event_by_hash_prefix(ref)
      end

      def event_by_number(ref)
        index = ref.to_i - 1
        index >= 0 ? @resolve_events[index] : nil
      end

      def event_by_hash_prefix(ref)
        @hash_matches = @resolve_events.select { |evt| evt.short_hash.start_with?(ref.downcase) }
        @hash_matches.first if @hash_matches.one?
      end

      def fetch_current_events
        range = compute_date_range
        return [] unless range

        fetch_events(range)
      end
    end

    # Event display, RSVP, and detail subcommands
    module CalEventActions
      RSVP_ACTION_LABELS = {
        'accept' => 'accepted', 'decline' => 'declined', 'tentative' => 'tentatively accepted'
      }.freeze

      private

      def show_event
        event_id = validated_event_id
        return event_id if event_id.is_a?(Integer)

        render_single_event(event_id)
      rescue ApiError => e
        api_error_result('Failed to fetch event', e)
      end

      def validated_event_id
        return missing_event_ref unless @event_ref && !@event_ref.empty?

        resolve_event_id || 1
      end

      def api_error_result(prefix, err)
        error("#{prefix}: #{err.message}")
        1
      end

      def render_single_event(event_id)
        event = fetch_event_for_display(event_id)
        render_event_output(event)
        0
      end

      def render_event_output(event)
        if @options[:json]
          output_json(event_to_hash(event))
        else
          formatter = Formatters::CalendarFormatter.new(output: output)
          puts formatter.format_event_detail(event)
        end
      end

      def rsvp_event
        event_id = validated_event_id
        return event_id if event_id.is_a?(Integer)

        send_rsvp(event_id)
      rescue ApiError => e
        api_error_result('Failed to respond to event', e)
      end

      def send_rsvp(event_id)
        with_token_refresh do
          runner.calendar_api.rsvp_event(
            event_id: event_id, action: @subcommand,
            comment: @options[:comment],
            notify: @options[:no_send] ? :silent : :send
          )
        end

        success("Event #{@event_ref} #{RSVP_ACTION_LABELS[@subcommand]}")
        0
      end

      def missing_event_ref
        action = @subcommand == 'show' ? 'show' : @subcommand
        error("Event reference required. Usage: teems cal #{action} <N|hash>")
        1
      end

      def delete_event
        event_id = validated_event_id
        return event_id if event_id.is_a?(Integer)

        send_delete(event_id)
      end

      def send_delete(event_id)
        event = fetch_and_delete(event_id)
        display_delete_result(event)
        0
      rescue ApiError => e
        api_error_result('Failed to delete event', e)
      end

      def fetch_and_delete(event_id)
        event = fetch_event_for_display(event_id)
        with_token_refresh { runner.calendar_api.delete_event(event_id: event_id) }
        event
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

    # Interactive event selection and action loop for TTY mode
    module CalInteractiveMode
      RSVP_KEYS = { 'a' => 'accept', 'd' => 'decline', 't' => 'tentative' }.freeze

      private

      def interactive?
        !@options[:json] && !@options[:no_interactive] && !@options[:quiet] && output.tty?
      end

      def interactive_event_loop(events)
        setup_interactive_state(events)
        run_selection_loop
      end

      def setup_interactive_state(events)
        @interactive_events = events
        @resolve_events = events
      end

      def run_selection_loop
        loop do
          input = read_selection_input
          return unless input

          handle_selection(input)
        end
      end

      def read_selection_input
        output.print "\nEnter # or hash for details (1-#{@interactive_events.length}) or q to quit: "
        output.flush
        @last_input = $stdin.gets&.strip.to_s
        @last_input unless @last_input.empty? || @last_input == 'q'
      end

      def handle_selection(input)
        event = resolve_by_ref(input)
        event ? show_detail_and_act(event) : output.puts("Invalid selection: #{input}")
      end

      def show_detail_and_act(event)
        render_event_detail_text(event)
        action_loop(event)
      end

      def render_event_detail_text(event)
        formatter = Formatters::CalendarFormatter.new(output: output)
        output.puts ''
        output.puts formatter.format_event_detail(event)
      end

      def action_loop(event)
        loop do
          input = read_action_input
          result = dispatch_action(input, event)
          return result unless result == :continue
        end
      end

      def read_action_input
        output.print "\n[a]ccept  [d]ecline  [t]entative  [D]elete  [b]ack  [q]uit: "
        output.flush
        $stdin.gets&.strip
      end

      def dispatch_action(input, event)
        return send_interactive_rsvp(RSVP_KEYS[input], event) if RSVP_KEYS.key?(input)

        dispatch_non_rsvp_action(input, event)
      end

      def dispatch_non_rsvp_action(input, event)
        case input.to_s
        when 'D' then send_interactive_delete(event)
        when 'b' then redisplay_list
        when 'q', '' then throw(:interactive_quit)
        else output.puts("Unknown action: #{input}") || :continue
        end
      end

      def send_interactive_rsvp(action, event)
        with_token_refresh { runner.calendar_api.rsvp_event(event_id: event.id, action: action, notify: :send) }
        display_rsvp_result(action, event)
      rescue ApiError => e
        error("Failed to respond: #{e.message}") && :continue
      end

      def display_rsvp_result(action, event)
        success("Event #{CalEventActions::RSVP_ACTION_LABELS[action]}: \"#{event.subject}\"")
        :continue
      end

      def send_interactive_delete(event)
        perform_delete(event)
        throw(:interactive_quit)
      rescue ApiError => e
        error("Failed to delete: #{e.message}") && :continue
      end

      def perform_delete(event)
        with_token_refresh { runner.calendar_api.delete_event(event_id: event.id) }
        success("Deleted: \"#{event.subject}\"")
      end

      def redisplay_list
        output.puts ''
        render_events_text(@interactive_events)
        nil
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
        debug("Parsing time #{hour}:#{min} for #{@options[:date]}") if @options[:verbose]
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
        return missing_subject_error unless @create_subject

        validated_create_event
      rescue ApiError => e
        api_error_result('Failed to create event', e)
      end

      def validated_create_event
        times = resolve_create_times
        return times if times.is_a?(Integer)

        send_create_request(*times)
      end

      def missing_subject_error
        error('Event title required. Usage: teems cal create "Title" --start TIME')
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
        start_time = validated_start_time
        return start_time if start_time.is_a?(Integer)

        end_time = compute_end_time(start_time)
        return end_time if end_time.is_a?(Integer)

        [format_time(start_time), format_time(end_time)]
      end

      def validated_start_time
        start_input = @options[:start]
        return missing_start_time_error unless start_input

        parse_time_input(start_input) || (error("Invalid start time: #{start_input}") || 1)
      end

      def missing_start_time_error
        error('Start time required. Use --start "YYYY-MM-DD HH:MM" or --start "today HH:MM"')
        1
      end

      def compute_end_time(start_time)
        @options[:end] ? parse_explicit_end_time : compute_end_from_duration(start_time)
      end

      def parse_explicit_end_time
        end_input = @options[:end]
        parse_time_input(end_input) || (error("Invalid end time: #{end_input}") || 1)
      end

      def compute_end_from_duration(start_time)
        duration = @options[:duration] || 30
        return error('Duration must be a positive number of minutes') || 1 unless duration.positive?

        start_time + (duration * 60)
      end

      def format_time(time) = time.strftime('%Y-%m-%dT%H:%M:%S')

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
        add_location_field(body)
        add_body_field(body)
        add_attendees_field(body)
        add_teams_meeting(body) if @options[:teams]
        body
      end

      def add_location_field(body)
        location = @options[:location]
        body[:location] = { displayName: location } if location
      end

      def add_body_field(body)
        content = @options[:body]
        body[:body] = { contentType: 'text', content: content } if content
      end

      def add_attendees_field(body)
        emails = @options[:attendees]
        body[:attendees] = emails.map { |email| attendee_entry(email) } if emails
      end

      def add_teams_meeting(body)
        debug('Adding Teams meeting link') if @options[:verbose]
        body[:isOnlineMeeting] = true
        body[:onlineMeetingProvider] = 'teamsForBusiness'
      end

      def attendee_entry(email) = { emailAddress: { address: email }, type: 'required' }

      def display_create_result(event)
        success("Created: \"#{event.subject}\"")
        event.create_summary_lines.each { |line| puts "  #{line}" }
      end
    end

    # List calendar events and view event details
    class Cal < Base
      include CalDateRange
      include CalSubcommandParser
      include CalEventResolver
      include CalEventActions
      include CalCreateActions
      include CalInteractiveMode

      def initialize(args, runner:)
        @options = {}
        @subcommand = nil
        @event_ref = nil
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
        '--no-interactive' => ->(opts, _args) { opts[:no_interactive] = true },
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
        api_error_result('Failed to fetch calendar', e)
      end

      def fetch_and_display_events(range)
        events = fetch_events(range)
        return 0 if events.empty? && (puts('No events found') || true)

        render_events(events)
        run_interactive_loop(events) if interactive?
        0
      end

      def run_interactive_loop(events)
        catch(:interactive_quit) { interactive_event_loop(events) }
      end

      def fetch_events(range)
        start_dt, end_dt = range
        with_token_refresh do
          runner.calendar_api.list_events(
            time_range: { start_dt: start_dt, end_dt: end_dt, timezone: detect_timezone },
            top: @options[:limit]
          )
        end
      end

      def render_events(events)
        if @options[:json]
          output_json(events.map { |event| event_to_hash(event) })
        else
          render_events_text(events)
        end
      end

      def render_events_text(events)
        formatter = Formatters::CalendarFormatter.new(output: output)
        method = @options[:verbose] ? :format_event_list_verbose : :format_event_list_compact
        puts formatter.public_send(method, events)
      end
    end
  end
end
