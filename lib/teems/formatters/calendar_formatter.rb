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

      RESPONSE_SYMBOLS = {
        'accepted' => [:green, "\u{2713}"], 'declined' => [:red, "\u{2717}"],
        'tentativelyAccepted' => [:yellow, '?']
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
        symbol = attendee_symbol(attendee, event)
        label = response_label(attendee[:response])
        display = format_name_email(attendee[:name], attendee[:email])
        "  #{symbol} #{display} \u2014 #{label}"
      end

      def format_name_email(name, email)
        name ? "#{@output.bold(name)} (#{email})" : email.to_s
      end

      def attendee_symbol(att, event)
        organizer = event.organizer
        if organizer && att[:email]&.downcase == organizer[:email]&.downcase
          @output.cyan("\u{2605}")
        else
          response_to_symbol(att[:response])
        end
      end

      def response_to_symbol(response)
        color, symbol = RESPONSE_SYMBOLS.fetch(response, [:gray, "\u{B7}"])
        @output.public_send(color, symbol)
      end

      def response_label(response)
        RESPONSE_LABELS[response] || response&.capitalize || 'Pending'
      end
    end

    # Detail view formatting for calendar events
    module CalendarDetailFormatter
      private

      def detail_metadata_lines(event)
        lines = [@output.bold(event.subject), format_detail_time(event)]
        lines.concat(detail_field_lines(event))
      end

      def detail_field_lines(event)
        [detail_location(event), detail_organizer(event), detail_link(event),
         detail_status(event), detail_response(event), detail_recurrence(event),
         detail_show_as(event)].compact
      end

      def detail_location(event)
        loc = event.location
        return unless loc && !loc.empty?

        "  #{@output.gray('Location:')}  #{loc}"
      end

      def detail_organizer(event)
        org = event.organizer
        return unless org

        "  #{@output.gray('Organizer:')} #{@output.bold(org[:name])} (#{org[:email]})"
      end

      def detail_link(event)
        url = event.online_meeting_url
        return unless url

        "  #{@output.gray('Link:')}      #{url}"
      end

      def detail_status(event) = event.cancelled? ? "  Status:    #{@output.red('CANCELLED')}" : nil

      def detail_response(event)
        response = event.response_status
        return nil unless response

        "  RSVP:      #{response_to_symbol(response)} #{response_label(response)}"
      end

      def detail_recurrence(event)
        return unless event.recurring?

        "  #{@output.gray('Recurring:')} Yes"
      end

      def detail_show_as(event)
        show_as = event.show_as
        return unless show_as

        "  #{@output.gray('Show as:')}   #{show_as}"
      end

      def detail_body_section(event)
        preview = event.body_preview.to_s.strip
        return [] if preview.empty?

        [@output.bold('Description:'), "  #{preview}", '']
      end

      def format_detail_time(event)
        time_label = @output.gray('Time:')
        "  #{time_label}      #{detail_time_value(event)}"
      end

      def detail_time_value(event)
        return @output.bold('ALL DAY') if event.all_day?

        start_time = event.start_time
        range_display = event.time_range_display
        return '(unknown)' unless start_time && range_display != ''

        "#{@output.bold(start_time.strftime('%A, %B %-d, %Y'))}  #{@output.gray(range_display)}"
      end
    end

    # Formats calendar events for terminal display
    class CalendarFormatter
      include CalendarAttendeeFormatter
      include CalendarDetailFormatter

      RSVP_COUNTS = %i[accepted declined tentative pending].freeze

      def initialize(output:)
        @output = output
      end

      # Compact agenda listing
      def format_event_list_compact(events)
        events.each_with_index.map { |event, index| build_list_item_line(event, index + 1) }.join("\n")
      end

      # Verbose agenda listing with organizer and RSVP summaries
      def format_event_list_verbose(events)
        events.each_with_index.flat_map do |event, index|
          [build_list_item_line(event, index + 1) + list_item_verbose_suffix(event), '']
        end.join("\n")
      end

      # Detailed view of a single event
      def format_event_detail(event)
        [*detail_metadata_lines(event), '', *detail_body_section(event), *format_attendee_sections(event)].join("\n")
      end

      private

      def build_list_item_line(event, number)
        time = event.all_day? ? 'ALL DAY   ' : event.time_range_display.ljust(11)
        rsvp = response_to_symbol(event.response_status)
        prefix = "  #{@output.cyan("[#{number}]")} #{@output.gray("[#{event.short_hash}]")} #{time} #{rsvp}"
        "#{prefix} #{format_event_subject(event)}#{list_item_location(event)}"
      end

      def format_event_subject(event)
        title = event.subject
        suffix = subject_suffix(event)
        suffix ? "#{title} #{suffix}" : title
      end

      def subject_suffix(event)
        return @output.gray('(cancelled)') if event.cancelled?

        @output.gray('(recurring)') if event.recurring?
      end

      def list_item_location(event) = (loc = event.location) && !loc.empty? ? "  #{@output.gray("(#{loc})")}" : ''

      def list_item_verbose_suffix(event)
        items = verbose_suffix_parts(event)
        return '' if items.empty?

        "\n      #{items.join("  #{@output.gray('|')}  ")}"
      end

      def verbose_suffix_parts(event)
        [organizer_label(event), attendee_rsvp_summary(event)].compact.reject(&:empty?)
      end

      def organizer_label(event)
        organizer = event.organizer
        return unless organizer

        "#{@output.gray('Organizer:')} #{organizer[:name]}"
      end

      def attendee_rsvp_summary(event)
        counts = RSVP_COUNTS.filter_map do |status|
          count = event.public_send(:"#{status}_attendees").length
          "#{count} #{@output.gray(status.to_s)}" if count.positive?
        end
        counts.join(', ')
      end
    end
  end
end
