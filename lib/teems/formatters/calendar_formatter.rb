# frozen_string_literal: true

module Teems
  module Formatters
    # Formats calendar events for terminal display
    class CalendarFormatter
      RSVP_COUNTS = %i[accepted declined tentative pending].freeze

      RESPONSE_LABELS = {
        'accepted' => 'Accepted',
        'declined' => 'Declined',
        'tentativelyAccepted' => 'Tentative',
        'none' => 'Pending'
      }.freeze

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

      # --- List item formatting ---

      def format_list_item(event, number, verbose: false)
        line = build_list_item_line(event, number)
        line += list_item_verbose_suffix(event) if verbose
        line
      end

      def build_list_item_line(event, number)
        time_display = event.all_day? ? 'ALL DAY   ' : event.time_range_display.ljust(11)
        subject = list_item_subject(event)
        location = list_item_location(event)
        "  #{@output.cyan("[#{number}]")} #{time_display} #{subject}#{location}"
      end

      def list_item_subject(event)
        event.cancelled? ? @output.gray("#{event.subject} (cancelled)") : event.subject
      end

      def list_item_location(event)
        return '' unless event.location && !event.location.empty?

        "  #{@output.gray("(#{event.location})")}"
      end

      def list_item_verbose_suffix(event)
        parts = []
        parts << "#{@output.gray('Organizer:')} #{event.organizer[:name]}" if event.organizer
        parts << attendee_rsvp_summary(event) if event.attendees.any?
        parts.reject!(&:empty?)
        return '' unless parts.any?

        "\n      #{parts.join("  #{@output.gray('|')}  ")}"
      end

      # --- Detail formatting ---

      def detail_metadata_lines(event)
        lines = [@output.bold(event.subject), format_detail_time(event)]
        lines << "  Location:  #{event.location}" if event.location && !event.location.empty?
        lines << "  Organizer: #{event.organizer[:name]} (#{event.organizer[:email]})" if event.organizer
        lines << "  Link:      #{event.online_meeting_url}" if event.online_meeting_url
        lines << "  Status:    #{@output.red('CANCELLED')}" if event.cancelled?
        lines << "  Show as:   #{event.show_as}" if event.show_as
        lines
      end

      def detail_body_section(event)
        return [] unless event.body_preview && !event.body_preview.strip.empty?

        [@output.bold('Description:'), "  #{event.body_preview.strip}", '']
      end

      def format_detail_time(event)
        return '  Time:      ALL DAY' if event.all_day?
        return '  Time:      (unknown)' unless event.start_time && event.end_time

        date = event.start_time.strftime('%A, %B %-d, %Y')
        "  Time:      #{date}  #{event.time_range_display}"
      end

      # --- Attendee formatting ---

      def attendee_rsvp_summary(event)
        counts = RSVP_COUNTS.filter_map do |status|
          list = event.public_send(:"#{status}_attendees")
          "#{list.length} #{status}" if list.any?
        end
        counts.join(', ')
      end

      def format_attendee_sections(event)
        lines = []
        lines.concat(format_attendee_group('Required Attendees:', event.required_attendees, event))
        lines.concat(format_attendee_group('Optional Attendees:', event.optional_attendees, event))
        lines.concat(format_untyped_attendees(event))
        lines
      end

      def format_attendee_group(title, attendees, event)
        return [] unless attendees.any?

        lines = [@output.bold(title)]
        attendees.each { |a| lines << format_attendee(a, event) }
        lines << ''
        lines
      end

      def format_untyped_attendees(event)
        untyped = event.attendees.reject { |a| %w[required optional].include?(a[:type]) }
        format_attendee_group('Attendees:', untyped, event)
      end

      def format_attendee(attendee, event)
        symbol = response_symbol(attendee, event)
        name = attendee[:name] || attendee[:email]
        email_part = attendee[:email] ? " (#{attendee[:email]})" : ''
        "  #{symbol} #{name}#{email_part} — #{response_label(attendee[:response])}"
      end

      def response_symbol(attendee, event)
        return @output.cyan('★') if organizer?(attendee, event)

        response_to_symbol(attendee[:response])
      end

      def organizer?(attendee, event)
        event.organizer &&
          attendee[:email]&.downcase == event.organizer[:email]&.downcase
      end

      def response_to_symbol(response)
        case response
        when 'accepted'             then @output.green('✓')
        when 'declined'             then @output.red('✗')
        when 'tentativelyAccepted'  then @output.yellow('?')
        else @output.gray('·')
        end
      end

      def response_label(response)
        RESPONSE_LABELS[response] || response&.capitalize || 'Pending'
      end
    end
  end
end
