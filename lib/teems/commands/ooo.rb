# frozen_string_literal: true

require 'securerandom'

module Teems
  module Commands
    OOO_HELP = <<~HELP
      teems ooo - Manage out-of-office status

      USAGE:
        teems ooo                Show current OOO status
        teems ooo on [options]   Enable out-of-office
        teems ooo off            Disable out-of-office
        teems ooo config         Show OOO configuration

      ON OPTIONS:
        --message TEXT       Auto-reply and status message
        --start TIME         Schedule start; enables scheduled mode. Formats:
                               YYYY-MM-DD              (all-day)
                               YYYY-MM-DD HH:MM        (timed)
                               "today HH:MM", "tomorrow HH:MM", HH:MM
        --end TIME           Schedule end, required with --start.
                             Must match --start style (date or timed).
        --event              Create an OOO calendar event for notify list
        --invite EMAILS      Comma-separated invitees; overrides config notify list
        --no-status          Skip setting Teams status/presence

      CONFIGURATION:
        Edit ~/.config/teems/config.json to set defaults:

        {
          "ooo": {
            "internal_message": "I'm currently out of office.",
            "external_message": "Thank you for your message. I'm out of office.",
            "external_audience": "all",
            "status_message": "Out of Office",
            "notify": ["manager@example.com", "team@example.com"]
          }
        }

      EXAMPLES:
        teems ooo                          # Check OOO status
        teems ooo on                       # Enable OOO (always on)
        teems ooo on --message "Vacation"  # Custom message
        teems ooo on --start 2026-04-14 --end 2026-04-18
        teems ooo on --start "today 14:00" --end "today 17:00" \\
          --message "Dr appt"
        teems ooo off                      # Disable OOO
        teems ooo config                   # Show config
    HELP

    # A parsed --start or --end value. Produces ISO datetime strings for
    # auto-reply schedules and calendar events. Kind is :timed, :date, or
    # :unscheduled; value is a Time, Date, or nil respectively.
    OooScheduleEntry = Data.define(:kind, :value) do
      def timed? = kind == :timed
      def all_day? = kind == :date
      def unscheduled? = kind == :unscheduled

      def reply_start_iso
        timed? ? value.strftime('%Y-%m-%dT%H:%M:%S') : "#{value}T00:00:00"
      end

      def reply_end_iso
        timed? ? value.strftime('%Y-%m-%dT%H:%M:%S') : "#{value}T23:59:59"
      end

      def event_start_iso
        base = value || Date.today
        timed? ? base.strftime('%Y-%m-%dT%H:%M:%S') : "#{base}T00:00:00"
      end

      def event_end_iso
        base = value || Date.today
        return base.strftime('%Y-%m-%dT%H:%M:%S') if timed?

        "#{base + 1}T00:00:00"
      end
    end

    UNSCHEDULED_OOO_SCHEDULE = OooScheduleEntry.new(kind: :unscheduled, value: nil)

    # Displays current OOO status (auto-reply + presence)
    module OooDisplay
      private

      def show_status
        replies = fetch_auto_replies
        presence = fetch_presence
        render_ooo_status(replies, presence)
        0
      end

      def fetch_auto_replies
        with_token_refresh { runner.users_api.auto_replies }
      rescue ApiError => e
        debug("Auto-reply fetch failed: #{e.message}")
        nil
      end

      def fetch_presence
        with_token_refresh { runner.users_api.my_presence }
      rescue ApiError => e
        debug("Presence fetch failed: #{e.message}")
        nil
      end

      def render_ooo_status(replies, presence)
        if @options[:json]
          output_json({ auto_replies: replies, presence: presence })
        else
          render_ooo_text(replies, presence)
        end
      end

      def render_ooo_text(replies, presence)
        render_auto_reply_status(replies)
        render_presence_status(presence)
      end

      def render_auto_reply_status(replies)
        return puts('Auto-replies: unknown (permission denied)') unless replies

        status = replies['status'] || 'disabled'
        puts "Auto-replies: #{status}"
        render_schedule(replies) if status == 'scheduled'
        render_reply_message(replies)
      end

      def render_schedule(replies)
        start_entry = replies['scheduledStartDateTime']
        return unless start_entry

        start_str = format_schedule_dt(start_entry)
        end_str = format_schedule_dt(replies['scheduledEndDateTime'])
        puts "  Schedule: #{start_str} to #{end_str} #{short_tz_label}"
      end

      def format_schedule_dt(entry)
        return '' unless entry

        raw = entry['dateTime']
        time = entry['timeZone'] == 'UTC' ? Time.parse("#{raw} UTC").getlocal : Time.parse(raw)
        time.strftime('%Y-%m-%d %H:%M')
      rescue ArgumentError
        raw.to_s
      end

      def render_reply_message(replies)
        plain = strip_reply_html(replies['internalReplyMessage'])
        puts "  Message: #{plain[0..80]}" unless plain.empty?
      end

      def strip_reply_html(raw) = raw.to_s.gsub(/<[^>]+>/, '').strip

      def render_presence_status(presence)
        return unless presence

        availability = presence['availability'] || 'Unknown'
        puts "Presence: #{availability}"
        msg = presence.dig('statusMessage', 'message', 'content')
        puts "  Status: #{msg}" if msg && !msg.empty?
      end
    end

    # Parses and validates --start/--end into @schedule_start and @schedule_end.
    # Each parsed value is a tuple: [:date, Date] for all-day or [:timed, Time] for timed.
    module OooSchedule
      private

      def validate_create_options
        start_raw = @options[:start]
        end_raw = @options[:end]
        return unless start_raw
        return missing_end_error unless end_raw

        parse_schedule_pair(start_raw, end_raw)
      end

      def missing_end_error
        error('--end is required when using --start')
        1
      end

      def parse_schedule_pair(start_raw, end_raw)
        @schedule_start = parse_schedule_value(start_raw)
        return invalid_schedule_error(:start, start_raw) unless @schedule_start

        @schedule_end = parse_schedule_value(end_raw)
        return invalid_schedule_error(:end, end_raw) unless @schedule_end

        return mixed_schedule_error if schedule_kind(@schedule_start) != schedule_kind(@schedule_end)

        nil
      end

      def parse_schedule_value(raw)
        time = parse_time_input(raw)
        return OooScheduleEntry.new(kind: :timed, value: time) if time

        OooScheduleEntry.new(kind: :date, value: Date.parse(raw))
      rescue Date::Error
        nil
      end

      def invalid_schedule_error(key, raw)
        error("Invalid value for --#{key}: #{raw}. " \
              "Use YYYY-MM-DD, HH:MM, 'today HH:MM', 'tomorrow HH:MM', or 'YYYY-MM-DD HH:MM'")
        1
      end

      def mixed_schedule_error
        error('--start and --end must both be dates or both include a time')
        1
      end

      def schedule_kind(parsed) = parsed.kind
    end

    # Enables/disables OOO: auto-reply, status message, presence, calendar event
    module OooActions
      private

      def enable_ooo
        result = validate_create_options
        return result if result

        results = execute_ooo_steps
        summarize_results(results)
        results.values.all? ? 0 : 1
      end

      def disable_ooo
        results = {}
        results[:auto_reply] = disable_auto_reply
        results[:status] = clear_ooo_status unless @options[:no_status]
        summarize_disable_results(results)
        results.values.all? ? 0 : 1
      end

      def execute_ooo_steps
        results = {}
        results[:auto_reply] = set_auto_reply
        results[:status] = set_ooo_status unless @options[:no_status]
        results[:event] = create_ooo_event if @options[:event] && !notify_list.empty?
        results
      end

      def set_auto_reply
        settings = build_auto_reply_settings
        with_token_refresh { runner.users_api.update_auto_replies(settings) }
        success('Auto-reply enabled')
        true
      rescue ApiError => e
        warn_step('auto-reply', e)
        false
      end

      def disable_auto_reply
        with_token_refresh { runner.users_api.update_auto_replies(status: 'disabled') }
        success('Auto-reply disabled')
        true
      rescue ApiError => e
        warn_step('auto-reply', e)
        false
      end

      def set_ooo_status
        message = status_message_text
        apply_ooo_presence(message)
        success("Status set: #{message}")
        true
      rescue ApiError => e
        warn_step('status/presence', e)
        false
      end

      def apply_ooo_presence(message)
        users = runner.users_api
        with_token_refresh { users.set_status_message(message: message, expiry: nil) }
        with_token_refresh { users.set_presence(availability: 'Offline', activity: 'OffWork', duration: 'PT8H') }
      end

      def clear_ooo_status
        users = runner.users_api
        with_token_refresh { users.clear_status_message }
        with_token_refresh { users.clear_presence }
        success('Status and presence cleared')
        true
      rescue ApiError => e
        warn_step('status/presence', e)
        false
      end

      def create_ooo_event
        body = build_ooo_event
        with_token_refresh { runner.calendar_api.create_event(body) }
        success("Calendar event created for #{notify_list.length} recipient(s)")
        true
      rescue ApiError => e
        warn_step('calendar event', e)
        false
      end

      def warn_step(step, err)
        output.warn("#{step}: #{err.message}")
      end
    end

    # Builds API request bodies for OOO operations
    module OooBuildHelpers
      private

      def build_auto_reply_settings
        msg = auto_reply_message
        settings = { status: auto_reply_status,
                     internalReplyMessage: msg,
                     externalReplyMessage: external_message(msg),
                     externalAudience: ooo_config('external_audience') || 'all' }
        add_schedule(settings) if @options[:start]
        settings
      end

      def auto_reply_status
        @options[:start] ? 'scheduled' : 'alwaysEnabled'
      end

      def auto_reply_message
        @options[:message] || ooo_config('internal_message') || 'I am currently out of office.'
      end

      def external_message(internal_fallback)
        ooo_config('external_message') || internal_fallback
      end

      def status_message_text
        @options[:message] || ooo_config('status_message') || 'Out of Office'
      end

      def add_schedule(settings)
        timezone = detect_timezone
        settings[:scheduledStartDateTime] = { dateTime: @schedule_start.reply_start_iso, timeZone: timezone }
        settings[:scheduledEndDateTime] = { dateTime: @schedule_end.reply_end_iso, timeZone: timezone }
      end

      def build_ooo_event
        timezone = detect_timezone
        { subject: status_message_text,
          start: { dateTime: @schedule_start.event_start_iso, timeZone: timezone },
          end: { dateTime: @schedule_end.event_end_iso, timeZone: timezone },
          isAllDay: !@schedule_start.timed?, showAs: 'free',
          isReminderOn: false, isOnlineMeeting: false,
          transactionId: SecureRandom.uuid,
          attendees: notify_list.map { |email| ooo_attendee(email) },
          responseRequested: false }
      end

      def ooo_attendee(email)
        { emailAddress: { address: email }, type: 'required' }
      end

      def notify_list
        @notify_list ||= @options[:invite] || ooo_config('notify') || []
      end

      def ooo_config(key)
        config['ooo']&.dig(key)
      end
    end

    # Manage out-of-office: auto-reply, status, presence, and calendar event
    class Ooo < Base
      include Support::Timezone
      include Support::TimeParsing
      include OooDisplay
      include OooSchedule
      include OooActions
      include OooBuildHelpers

      def initialize(args, runner:)
        @options = {}
        @schedule_start = UNSCHEDULED_OOO_SCHEDULE
        @schedule_end = UNSCHEDULED_OOO_SCHEDULE
        super
      end

      SPLIT_OOO_EMAILS = ->(raw) { raw ? raw.split(',').map(&:strip).reject(&:empty?) : [] }

      OOO_OPTIONS = {
        '--message' => ->(opts, args) { opts[:message] = args.shift },
        '--start' => ->(opts, args) { opts[:start] = args.shift },
        '--end' => ->(opts, args) { opts[:end] = args.shift },
        '--event' => ->(opts, _args) { opts[:event] = true },
        '--invite' => ->(opts, args) { opts[:invite] = SPLIT_OOO_EMAILS.call(args.shift) },
        '--no-status' => ->(opts, _args) { opts[:no_status] = true }
      }.freeze

      OOO_ACTIONS = {
        'on' => :enable_ooo, 'off' => :disable_ooo,
        'config' => :show_config
      }.freeze

      def execute
        result = validate_options
        return result if result

        auth_result = require_auth
        return auth_result if auth_result

        dispatch_action
      end

      protected

      def handle_option(arg, pending)
        handler = OOO_OPTIONS[arg]
        return super unless handler

        handler.call(@options, pending)
      end

      def help_text = OOO_HELP

      private

      def dispatch_action
        action = positional_args.first
        method_name = OOO_ACTIONS[action]
        return send(method_name) if method_name
        return show_status unless action

        error("Unknown action: #{action}. Use: on, off, config")
        1
      end

      def show_config
        ooo = config['ooo'] || {}
        if @options[:json]
          output_json(ooo)
        else
          puts ooo.empty? ? 'No OOO config set. See: teems ooo --help' : JSON.pretty_generate(ooo)
        end
        0
      end

      def summarize_results(results)
        return if results.values.all?

        output.warn("OOO partially enabled: #{count_successes(results)}/#{results.size} steps succeeded")
      end

      def summarize_disable_results(results)
        return if results.values.all?

        output.warn("OOO partially disabled: #{count_successes(results)}/#{results.size} steps succeeded")
      end

      def count_successes(results) = results.values.count(true)
    end
  end
end
