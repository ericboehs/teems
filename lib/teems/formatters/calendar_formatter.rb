# frozen_string_literal: true

module Teems
  module Formatters
    # Formats calendar events for terminal display
    class CalendarFormatter
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
        lines = []

        lines << @output.bold(event.subject)
        lines << format_detail_time(event)
        lines << "  Location:  #{event.location}" if event.location && !event.location.empty?
        lines << "  Organizer: #{event.organizer[:name]} (#{event.organizer[:email]})" if event.organizer
        lines << "  Link:      #{event.online_meeting_url}" if event.online_meeting_url
        lines << "  Status:    #{@output.red('CANCELLED')}" if event.cancelled?
        lines << "  Show as:   #{event.show_as}" if event.show_as
        lines << ''

        if event.body_preview && !event.body_preview.strip.empty?
          lines << @output.bold('Description:')
          lines << "  #{event.body_preview.strip}"
          lines << ''
        end

        lines.concat(format_attendee_sections(event))

        lines.join("\n")
      end

      private

      def format_list_item(event, number, verbose: false)
        time_display = event.all_day? ? 'ALL DAY   ' : event.time_range_display.ljust(11)
        subject = event.cancelled? ? @output.gray("#{event.subject} (cancelled)") : event.subject
        location = event.location && !event.location.empty? ? "  #{@output.gray("(#{event.location})")}" : ''

        line = "  #{@output.cyan("[#{number}]")} #{time_display} #{subject}#{location}"

        if verbose
          parts = []
          parts << "#{@output.gray('Organizer:')} #{event.organizer[:name]}" if event.organizer
          if event.attendees.any?
            summary = attendee_rsvp_summary(event)
            parts << summary unless summary.empty?
          end
          line += "\n      #{parts.join("  #{@output.gray('|')}  ")}" if parts.any?
        end

        line
      end

      def format_detail_time(event)
        if event.all_day?
          "  Time:      ALL DAY"
        elsif event.start_time && event.end_time
          date = event.start_time.strftime('%A, %B %-d, %Y')
          time = event.time_range_display
          "  Time:      #{date}  #{time}"
        else
          "  Time:      (unknown)"
        end
      end

      def attendee_rsvp_summary(event)
        counts = []
        accepted = event.accepted_attendees.length
        declined = event.declined_attendees.length
        tentative = event.tentative_attendees.length
        pending = event.pending_attendees.length

        counts << "#{accepted} accepted" if accepted.positive?
        counts << "#{declined} declined" if declined.positive?
        counts << "#{tentative} tentative" if tentative.positive?
        counts << "#{pending} pending" if pending.positive?

        counts.join(', ')
      end

      def format_attendee_sections(event)
        lines = []

        required = event.required_attendees
        optional = event.optional_attendees

        if required.any?
          lines << @output.bold('Required Attendees:')
          required.each { |a| lines << format_attendee(a, event) }
          lines << ''
        end

        if optional.any?
          lines << @output.bold('Optional Attendees:')
          optional.each { |a| lines << format_attendee(a, event) }
          lines << ''
        end

        # Handle attendees with no type set
        untyped = event.attendees.reject { |a| %w[required optional].include?(a[:type]) }
        if untyped.any?
          lines << @output.bold('Attendees:')
          untyped.each { |a| lines << format_attendee(a, event) }
          lines << ''
        end

        lines
      end

      def format_attendee(attendee, event)
        symbol = response_symbol(attendee, event)
        name = attendee[:name] || attendee[:email]
        email_part = attendee[:email] ? " (#{attendee[:email]})" : ''
        status = response_label(attendee[:response])

        "  #{symbol} #{name}#{email_part} — #{status}"
      end

      def response_symbol(attendee, event)
        if event.organizer &&
           attendee[:email]&.downcase == event.organizer[:email]&.downcase
          return @output.cyan('★')
        end

        case attendee[:response]
        when 'accepted' then @output.green('✓')
        when 'declined' then @output.red('✗')
        when 'tentativelyAccepted' then @output.yellow('?')
        else @output.gray('·')
        end
      end

      def response_label(response)
        case response
        when 'accepted' then 'Accepted'
        when 'declined' then 'Declined'
        when 'tentativelyAccepted' then 'Tentative'
        when 'none', nil then 'Pending'
        else response.capitalize
        end
      end
    end
  end
end
