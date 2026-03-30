# frozen_string_literal: true

module Teems
  module Commands
    # Render helpers for presence status display
    module StatusDisplay
      AVAILABILITY_LABELS = {
        'Available' => 'Available', 'Busy' => 'Busy',
        'DoNotDisturb' => 'Do Not Disturb', 'Away' => 'Away',
        'BeRightBack' => 'Be Right Back', 'Offline' => 'Offline',
        'PresenceUnknown' => 'Unknown'
      }.freeze

      private

      def render_presence(data)
        @options[:json] ? output_json(data) : render_presence_text(data)
      end

      def render_presence_text(data)
        render_availability_line(data)
        render_status_message_line(data)
      end

      def render_availability_line(data)
        raw, activity = data.values_at('availability', 'activity')
        line = "Availability: #{AVAILABILITY_LABELS[raw] || raw}"
        line += " (#{activity})" if activity && activity != raw
        puts line
      end

      def render_status_message_line(data)
        msg = data.dig('statusMessage', 'message', 'content')
        return unless msg && !msg.empty?

        expiry_text = format_expiry(data.dig('statusMessage', 'expiryDateTime'))
        line = "Status:       #{msg}"
        line += " (#{expiry_text})" if expiry_text
        puts line
      end

      def format_expiry(expiry_data)
        return nil unless expiry_data

        expiry_str = expiry_data['dateTime']
        return nil unless expiry_str

        remaining = Time.parse(expiry_str) - Time.now.utc
        return 'expired' unless remaining.positive?

        format_remaining(remaining)
      end

      def format_remaining(remaining)
        total_minutes = (remaining / 60).ceil
        hrs = total_minutes / 60
        mins = total_minutes % 60
        parts = []
        parts << "#{hrs}h" if hrs.positive?
        parts << "#{mins}m" if mins.positive?
        "expires in #{parts.join(' ')}"
      end
    end

    # Dispatch and mutation logic for setting/clearing presence
    module StatusActions
      private

      def dispatch_action
        case positional_args
        in ['clear', *] then clear_status
        in [text, *rest] then set_status(text, rest)
        in [] then @options[:presence] ? set_presence_only : show_status
        end
      end

      def show_status
        data = with_token_refresh { runner.users_api.my_presence }
        render_presence(data)
        0
      end

      def set_status(text, rest)
        duration = parse_duration(rest.first)
        expiry = duration&.to_expiration
        with_token_refresh { runner.users_api.set_status_message(message: text, expiry: expiry) }
        send_presence(presence_duration(duration)) if @options[:presence]
        msg = "Status set: #{text}"
        msg += " (#{duration})" if duration
        success(msg)
        0
      end

      def clear_status
        with_token_refresh { runner.users_api.clear_status_message }
        send_presence(self.class::DEFAULT_PRESENCE_DURATION) if @options[:presence]
        success('Status cleared')
        0
      end

      def set_presence_only
        send_presence(self.class::DEFAULT_PRESENCE_DURATION)
        success("Presence set: #{@options[:presence]}")
        0
      end

      def presence_duration(duration)
        duration ? duration.to_iso8601_duration : self.class::DEFAULT_PRESENCE_DURATION
      end

      def send_presence(iso_duration)
        availability, activity = self.class::PRESENCE_MAP[@options[:presence]]
        with_token_refresh do
          runner.users_api.set_presence(availability: availability, activity: activity, duration: iso_duration)
        end
      end

      def parse_duration(value)
        return nil unless value

        Models::Duration.parse(value)
      rescue ArgumentError
        debug("Invalid duration #{value.inspect}, ignoring")
        nil
      end
    end

    # View and manage your presence status
    class Status < Base
      include StatusDisplay
      include StatusActions

      PRESENCE_MAP = {
        'available' => %w[Available Available],
        'busy' => %w[Busy Busy],
        'dnd' => %w[DoNotDisturb DoNotDisturb],
        'away' => %w[Away Away],
        'brb' => %w[BeRightBack BeRightBack],
        'offline' => %w[Offline OffWork]
      }.freeze

      DEFAULT_PRESENCE_DURATION = 'PT4H'

      STATUS_OPTIONS = {
        '-p' => ->(opts, args) { opts[:presence] = args.shift },
        '--presence' => ->(opts, args) { opts[:presence] = args.shift }
      }.freeze

      def initialize(args, runner:)
        @options = {}
        super
      end

      def execute
        result = validate_options
        return result if result

        auth_result = require_auth
        return auth_result if auth_result

        dispatch
      end

      protected

      def handle_option(arg, pending)
        handler = STATUS_OPTIONS[arg]
        return super unless handler

        handler.call(@options, pending)
      end

      def help_text
        <<~HELP
          #{output.bold('teems status')} - View and manage your presence status

          #{output.bold('USAGE:')}
            teems status                             Show current status
            teems status "<message>"                 Set status message
            teems status "<message>" <duration>      Set with expiry (e.g. 2h, 30m, 1h30m)
            teems status clear                       Clear status message
            teems status --presence <value>          Set presence only

          #{output.bold('PRESENCE VALUES:')}
            available, busy, dnd, away, brb, offline

          #{output.bold('OPTIONS:')}
            -p, --presence VALUE   Set presence/availability
            --json                 Output as JSON
            -v, --verbose          Show debug output
            -q, --quiet            Suppress output
            -h, --help             Show this help

          #{output.bold('EXAMPLES:')}
            teems status                             Show current status
            teems status "In a meeting"              Set status message
            teems status "Focus time" 2h             Set with 2h expiry
            teems status clear                       Clear status message
            teems status --presence away             Set presence to away
            teems status "Focus" 2h --presence dnd   Set message + presence
        HELP
      end

      private

      def dispatch
        return invalid_presence if @options[:presence] && !valid_presence?

        dispatch_action
      rescue ApiError => e
        error("Status error: #{e.message}")
        1
      end

      def valid_presence? = PRESENCE_MAP.key?(@options[:presence])

      def invalid_presence
        error("Invalid presence: #{@options[:presence]}")
        error("Valid values: #{PRESENCE_MAP.keys.join(', ')}")
        1
      end
    end
  end
end
