# frozen_string_literal: true

module Teems
  module Formatters
    # Renders Models::IcsEvent objects as an RFC 5545 calendar for subscribing from
    # Calendar.app and friends. The VEVENT layout follows the feed outlook-cli served,
    # so a subscription keeps showing invitees, responses and Teams join buttons.
    module IcsFormat
      PRODID = '-//ericboehs//teems//EN'
      PARTSTAT = { 'accepted' => 'ACCEPTED', 'organizer' => 'ACCEPTED', 'declined' => 'DECLINED',
                   'tentativelyAccepted' => 'TENTATIVE' }.freeze
      ROLE = { 'optional' => 'OPT-PARTICIPANT', 'resource' => 'NON-PARTICIPANT' }.freeze

      module_function

      def calendar(events, name:, stamp: Time.now)
        dtstamp = utc(stamp)
        vevents = events.select(&:dated?).flat_map { |event| vevent(event, dtstamp) }
        lines = ['BEGIN:VCALENDAR', 'VERSION:2.0', "PRODID:#{PRODID}", 'CALSCALE:GREGORIAN', 'METHOD:PUBLISH',
                 "X-WR-CALNAME:#{escape(name)}", *vevents, 'END:VCALENDAR']
        "#{lines.map { |line| fold(line) }.join("\r\n")}\r\n"
      end

      def vevent(event, dtstamp)
        ['BEGIN:VEVENT', "UID:#{event.uid}", "DTSTAMP:#{dtstamp}", *times(event),
         "SUMMARY:#{escape(event.subject)}", *optional_text('LOCATION', event.location),
         *people(event), *optional_text('DESCRIPTION', event.description), *join_lines(event.join_url),
         *status_lines(event), 'END:VEVENT']
      end

      def times(event) = ["DTSTART#{time_value(event.starts)}", "DTEND#{time_value(event.ends)}"]

      # All-day events have Dates, others UTC Times
      def time_value(value) = value.is_a?(Date) ? ";VALUE=DATE:#{value.strftime('%Y%m%d')}" : ":#{utc(value)}"

      def people(event)
        organizer = Hash(event.organizer)
        email = organizer[:email].to_s
        lines = email.empty? ? [] : ["ORGANIZER;CN=#{param(organizer[:name] || email)}:mailto:#{email}"]
        lines + event.attendees.filter_map { |attendee| attendee_line(attendee) }
      end

      def attendee_line(attendee)
        email = attendee[:email].to_s
        return if email.empty?

        role = ROLE.fetch(attendee[:type].to_s, 'REQ-PARTICIPANT')
        partstat = PARTSTAT.fetch(attendee[:response].to_s, 'NEEDS-ACTION')
        "ATTENDEE;CN=#{param(attendee[:name] || email)};ROLE=#{role};PARTSTAT=#{partstat};RSVP=TRUE:mailto:#{email}"
      end

      # URI values are not text-escaped. URL is what most clients show; CONFERENCE and the
      # Microsoft property are what Calendar.app and Outlook look for to offer a Join button.
      def join_lines(url)
        return [] if url.empty?

        ["URL;VALUE=URI:#{url}", %(CONFERENCE;VALUE=URI;FEATURE=AUDIO,VIDEO;LABEL="Microsoft Teams":#{url}),
         "X-MICROSOFT-SKYPETEAMSMEETINGURL:#{url}"]
      end

      def status_lines(event)
        [*('STATUS:CANCELLED' if event.cancelled?), *('TRANSP:TRANSPARENT' if event.free?)]
      end

      def optional_text(name, text) = text.to_s.strip.empty? ? [] : ["#{name}:#{escape(text)}"]

      # RFC 5545 TEXT escaping
      def escape(text) = text.to_s.gsub(/[\\;,]/) { |char| "\\#{char}" }.gsub(/\r\n|\r|\n/, '\\n')

      # Parameter values are quoted when they hold a separator; quotes themselves cannot appear
      def param(value)
        text = value.to_s.delete('"').gsub(/[\r\n]+/, ' ')
        text.match?(/[;:,]/) ? %("#{text}") : text
      end

      def utc(time) = time.utc.strftime('%Y%m%dT%H%M%SZ')

      # Lines longer than 75 octets continue on lines starting with a space, never splitting a character
      def fold(line)
        parts = []
        line.each_char do |char|
          current = parts.last
          fits = current && current.bytesize + char.bytesize <= (parts.one? ? 75 : 74)
          fits ? current << char : parts << char
        end
        parts.join("\r\n ")
      end
    end
  end
end
