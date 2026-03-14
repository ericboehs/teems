# frozen_string_literal: true

module Teems
  module Formatters
    # Attendee formatting helpers for calendar events
    module CalendarAttendeeFormatter
      RESPONSE_LABELS = {
        'accepted' => 'Accepted',
        'declined' => 'Declined',
        'tentativelyAccepted' => 'Tentative',
        'none' => 'Pending'
      }.freeze

      private

      def format_attendee_sections(event)
        [].concat(format_attendee_group('Required Attendees:', event.required_attendees, event))
          .concat(format_attendee_group('Optional Attendees:', event.optional_attendees, event))
          .concat(format_untyped_attendees(event))
      end

      def format_attendee_group(title, attendees, event)
        return [] unless attendees.any?

        [@output.bold(title), *attendees.map { |a| format_attendee(a, event) }, '']
      end

      def format_untyped_attendees(event)
        untyped = event.attendees.reject { |a| %w[required optional].include?(a[:type]) }
        format_attendee_group('Attendees:', untyped, event)
      end

      def format_attendee(attendee, event)
        name_email = "#{attendee[:name] || attendee[:email]}#{" (#{attendee[:email]})" if attendee[:email]}"
        "  #{response_symbol(attendee, event)} #{name_email} — #{response_label(attendee[:response])}"
      end

      def response_symbol(att, event)
        organizer?(att, event) ? @output.cyan('★') : response_to_symbol(att[:response])
      end

      def organizer?(att, event)
        event.organizer && att[:email]&.downcase == event.organizer[:email]&.downcase
      end

      def response_to_symbol(response)
        case response
        when 'accepted'             then @output.green('✓')
        when 'declined'             then @output.red('✗')
        when 'tentativelyAccepted'  then @output.yellow('?')
        else @output.gray('·')
        end
      end

      def response_label(response) = RESPONSE_LABELS[response] || response&.capitalize || 'Pending'
    end

    # Formats calendar events for terminal display
    class CalendarFormatter
      include CalendarAttendeeFormatter

      RSVP_COUNTS = %i[accepted declined tentative pending].freeze

      def initialize(output:)
        @output = output
      end

      # Compact agenda view with numbered events
      def format_event_list(events, verbose: false)
        lines = []
        events.each_with_index do |event, index|
          lines << format_list_item(event, index + 1, verbose: verbose)
          lines << '' if verbose
        end
        lines.join("\n")
      end

      # Detailed view of a single event
      def format_event_detail(event)
        lines = detail_metadata_lines(event)
        lines << ''
        lines.concat(detail_body_section(event))
        lines.concat(format_attendee_sections(event))
        lines.join("\n")
      end

      private

      def format_list_item(event, number, verbose: false)
        build_list_item_line(event, number) + (verbose ? list_item_verbose_suffix(event) : '')
      end

      def build_list_item_line(event, number)
        time = event.all_day? ? 'ALL DAY   ' : event.time_range_display.ljust(11)
        "  #{@output.cyan("[#{number}]")} #{time} #{list_item_subject(event)}#{list_item_location(event)}"
      end

      def list_item_subject(event) = event.cancelled? ? @output.gray("#{event.subject} (cancelled)") : event.subject

      def list_item_location(event) = (loc = event.location) && !loc.empty? ? "  #{@output.gray("(#{loc})")}" : ''

      def list_item_verbose_suffix(event)
        parts = []
        parts << "#{@output.gray('Organizer:')} #{event.organizer[:name]}" if event.organizer
        parts << attendee_rsvp_summary(event) if event.attendees.any?
        parts.reject!(&:empty?)
        return '' unless parts.any?

        "\n      #{parts.join("  #{@output.gray('|')}  ")}"
      end

      def detail_metadata_lines(event)
        lines = [@output.bold(event.subject), format_detail_time(event)]
        append_detail_fields(lines, event)
        lines
      end

      def append_detail_fields(lines, event)
        lines << "  Location:  #{event.location}" if event.location && !event.location.empty?
        append_organizer_and_links(lines, event)
        lines << "  Status:    #{@output.red('CANCELLED')}" if event.cancelled?
        lines << "  Show as:   #{event.show_as}" if event.show_as
      end

      def append_organizer_and_links(lines, event)
        lines << "  Organizer: #{event.organizer[:name]} (#{event.organizer[:email]})" if event.organizer
        lines << "  Link:      #{event.online_meeting_url}" if event.online_meeting_url
      end

      def detail_body_section(event)
        (body = event.body_preview) && !body.strip.empty? ? [@output.bold('Description:'), "  #{body.strip}", ''] : []
      end

      def format_detail_time(event)
        return '  Time:      ALL DAY' if event.all_day?
        return '  Time:      (unknown)' unless event.start_time && event.end_time

        "  Time:      #{event.start_time.strftime('%A, %B %-d, %Y')}  #{event.time_range_display}"
      end

      def attendee_rsvp_summary(event)
        counts = RSVP_COUNTS.filter_map do |status|
          list = event.public_send(:"#{status}_attendees")
          "#{list.length} #{status}" if list.any?
        end
        counts.join(', ')
      end
    end
  end
end
