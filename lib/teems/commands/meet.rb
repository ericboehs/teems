# frozen_string_literal: true

require 'securerandom'

module Teems
  module Commands
    MEET_HELP = <<~HELP
      teems meet - Start a Teams meeting and print its join link

      USAGE:
        teems meet [minutes] [options]

      Puts a Teams meeting on your calendar, starting now for 30 minutes unless told
      otherwise, and prints its join link (alone on stdout, so it pipes). With nobody
      invited, nothing is sent. People from outside your organization usually wait in
      the lobby until someone inside lets them in: --open joins here so you can.

      OPTIONS:
        --at TIME            Start: now (default), HH:MM, "today HH:MM",
                             "tomorrow HH:MM", or "YYYY-MM-DD HH:MM"
        --title TEXT         Event title (default: Meet now)
        --with EMAILS        Comma-separated people to invite. Exchange emails
                             each an invitation, so this asks first
        -y, --yes            Invite without asking (needed without a terminal)
        --copy               Also copy the link to the clipboard
        --open               Also open the link here, to join and admit guests
        -q, --quiet          Just the link
        --json               Event ID, title, start, end and link as JSON

      EXAMPLES:
        teems meet                         # Now, 30 minutes
        teems meet 60 --title "Pairing"    # Now, an hour
        teems meet --copy --open           # Copy the link and join here
        teems meet --at 14:30 --with alice@example.com
    HELP

    # `teems meet`: a calendar event with a Teams meeting, starting now by default, and
    # its join link. Calendars.ReadWrite is enough for that, where creating a bare online
    # meeting would need OnlineMeetings.ReadWrite.
    class Meet < Base
      include Support::Timezone
      include Support::TimeParsing
      include Confirmation

      DEFAULT_MINUTES = 30
      MAX_MINUTES = 24 * 60
      VALUE_OPTIONS = { '--at' => :at, '--title' => :title, '--with' => :with }.freeze
      FLAGS = { '--copy' => :copy, '--open' => :open, '--yes' => :yes, '-y' => :yes }.freeze

      def initialize(args, runner:)
        @options = {}
        super
      end

      def execute
        validation = validate_options
        return validation if validation

        auth = require_auth
        return auth if auth

        with_token_refresh { create_meeting }
      rescue ApiError => e
        api_error_result('Could not create the meeting', e)
      rescue Teems::Error => e
        error(e.message)
      end

      protected

      def handle_option(arg, pending)
        return @options[FLAGS[arg]] = true if FLAGS.key?(arg)
        return super unless VALUE_OPTIONS.key?(arg)

        @options[VALUE_OPTIONS[arg]] = pending.shift
      end

      def help_text = MEET_HELP

      private

      def create_meeting
        start = start_time
        finish = start + (minutes * 60)
        return error('Cancelled; no meeting created') unless invite_confirmed?

        event = runner.calendar_api.create_event(event_body(start, finish))
        link = event.online_meeting_url or raise Error, 'Graph created the event but gave no Teams link'
        report(event, link, start..finish)
      end

      def minutes
        given = positional_args.first
        return DEFAULT_MINUTES unless given

        count = Integer(given, 10, exception: false)
        raise Error, "Minutes must be a whole number from 1 to #{MAX_MINUTES}" unless count&.between?(1, MAX_MINUTES)

        count
      end

      def start_time
        given = @options[:at] || 'now'
        parse_time_input(given) or raise Error, "Unknown time: #{given} (use now, HH:MM, \"tomorrow HH:MM\", ...)"
      end

      def invitees = @options[:with].to_s.split(',').map(&:strip).reject(&:empty?)

      # Inviting people sends them mail, so it needs a yes (at the prompt, or --yes)
      def invite_confirmed?
        people = invitees
        return true if people.empty? || @options[:yes]

        confirm?("Invite #{people.join(', ')} (Exchange emails each an invitation)",
                 refusal: 'Inviting people sends them email; pass --yes to go ahead')
      end

      def event_body(start, finish)
        zone = detect_timezone
        { subject: @options[:title] || 'Meet now', isOnlineMeeting: true, onlineMeetingProvider: 'teamsForBusiness',
          start: { dateTime: graph_time(start), timeZone: zone }, end: { dateTime: graph_time(finish), timeZone: zone },
          attendees: invitees.map { |address| { emailAddress: { address: address }, type: 'required' } },
          transactionId: SecureRandom.uuid }
      end

      # On stderr, beside the link on stdout; -q leaves just the link
      def note(message) = @options[:quiet] || output.note(message)

      def graph_time(time) = time.strftime('%Y-%m-%dT%H:%M:%S')

      def report(event, link, times)
        return json_report(event, link, times) if @options[:json]

        output.puts(link)
        note("#{event.subject}, #{times.begin.strftime('%-I:%M')}-#{times.end.strftime('%-I:%M %p')}")
        hand_off(link)
        0
      end

      def json_report(event, link, times)
        hand_off(link)
        output_json(id: event.id, title: event.subject, start: times.begin.iso8601, end: times.end.iso8601,
                    join_url: link)
        0
      end

      def hand_off(link)
        runner.clipboard.copy(link) && note('Copied the link') if @options[:copy]
        runner.browser.open(link) && note('Opened it to join') if @options[:open]
      end
    end
  end
end
