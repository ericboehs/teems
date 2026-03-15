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

        [@output.bold(title), *attendees.map { |attendee| format_attendee(attendee, event) }, '']
      end

      def format_untyped_attendees(event)
        untyped = event.attendees.reject { |attendee| %w[required optional].include?(attendee[:type]) }
        format_attendee_group('Attendees:', untyped, event)
      end

      def format_attendee(attendee, event)
        symbol = response_symbol(attendee, event)
        label = response_label(attendee[:response])
        "  #{symbol} #{attendee_name_email(attendee)} — #{label}"
      end

      def attendee_name_email(attendee)
        email = attendee[:email]
        "#{attendee[:name] || email}#{" (#{email})" if email}"
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
        events.each_with_index.flat_map do |event, index|
          item = format_list_item(event, index + 1, verbose: verbose)
          verbose ? [item, ''] : [item]
        end.join("\n")
      end

      # Detailed view of a single event
      def format_event_detail(event)
        [*detail_metadata_lines(event), '', *detail_body_section(event), *format_attendee_sections(event)].join("\n")
      end

      private

      def format_list_item(event, number, verbose: false)
        build_list_item_line(event, number) + (verbose ? list_item_verbose_suffix(event) : '')
      end

      def build_list_item_line(event, number)
        time = event.all_day? ? 'ALL DAY   ' : event.time_range_display.ljust(11)
        "  #{@output.cyan("[#{number}]")} #{time} #{list_item_subject(event)}#{list_item_location(event)}"
      end

      def list_item_subject(event)
        return gray_text("#{event.subject} (cancelled)") if event.cancelled?

        event.subject
      end

      def gray_text(text) = @output.gray(text)

      def list_item_location(event) = (loc = event.location) && !loc.empty? ? "  #{@output.gray("(#{loc})")}" : ''

      def list_item_verbose_suffix(event)
        items = verbose_suffix_parts(event)
        return '' if items.empty?

        "\n      #{items.join("  #{gray_text('|')}  ")}"
      end

      def verbose_suffix_parts(event)
        [organizer_label(event), attendee_rsvp_summary(event)].compact.reject(&:empty?)
      end

      def organizer_label(event)
        return unless event.organizer

        "#{gray_text('Organizer:')} #{event.organizer[:name]}"
      end

      def detail_metadata_lines(event)
        lines = [@output.bold(event.subject), format_detail_time(event)]
        append_detail_fields(lines, event)
        lines
      end

      def append_detail_fields(lines, event)
        lines.concat(detail_field_lines(event))
      end

      def detail_field_lines(event)
        [detail_location(event), detail_organizer(event), detail_link(event),
         detail_status(event), detail_show_as(event)].compact
      end

      def detail_location(event)
        loc = event.location
        "  Location:  #{loc}" if loc && !loc.empty?
      end

      def detail_organizer(event)
        org = event.organizer
        "  Organizer: #{org[:name]} (#{org[:email]})" if org
      end

      def detail_link(event) = event.online_meeting_url && "  Link:      #{event.online_meeting_url}"
      def detail_status(event) = event.cancelled? ? "  Status:    #{@output.red('CANCELLED')}" : nil
      def detail_show_as(event) = event.show_as && "  Show as:   #{event.show_as}"

      def detail_body_section(event)
        body_text = event.body_preview
        return [] if body_text.to_s.strip.empty?

        [bold_text('Description:'), "  #{body_text.strip}", '']
      end

      def bold_text(text) = @output.bold(text)

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
