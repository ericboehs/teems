# frozen_string_literal: true

require 'test_helper'

# Tests for calendar event list and detail formatting
module CalendarFormatterTests
  # Shared setup and event builders for calendar formatter tests
  module SharedHelpers
    def setup
      @output = test_output
      @formatter = Teems::Formatters::CalendarFormatter.new(output: @output)
    end

    private

    def build_event(**overrides)
      Teems::Models::Event.new(**event_defaults, **overrides)
    end

    def event_defaults
      { id: 'event-123', subject: 'Weekly Standup',
        start_time: Time.new(2026, 1, 20, 9, 0, 0), end_time: Time.new(2026, 1, 20, 10, 0, 0),
        location: nil, is_all_day: false,
        organizer: { name: 'Alice Manager', email: 'alice@example.com' }, attendees: [],
        body_preview: nil, online_meeting_url: nil, show_as: 'busy', importance: 'normal',
        is_cancelled: false, response_status: 'accepted', sensitivity: 'normal',
        event_type: 'singleInstance' }
    end

    def response_symbol_attendees
      [{ name: 'Accepted', email: 'a@test.com', type: 'required', response: 'accepted' },
       { name: 'Declined', email: 'd@test.com', type: 'required', response: 'declined' },
       { name: 'Tentative', email: 't@test.com', type: 'required', response: 'tentativelyAccepted' },
       { name: 'Pending', email: 'p@test.com', type: 'required', response: 'none' }]
    end
  end

  # Tests compact and verbose event list formatting with location, time, and RSVP
  class EventListTest < Minitest::Test
    include SharedHelpers

    def initialize(*)
      @formatter = nil
      super
    end

    def test_format_event_list_compact
      event = build_event
      result = @formatter.format_event_list_compact([event])
      assert_includes result, '[1]'
      assert_includes result, "[#{event.short_hash}]"
      assert_includes result, '09:00-10:00'
      assert_includes result, 'Weekly Standup'
    end

    def test_format_event_list_with_location
      result = @formatter.format_event_list_compact([build_event(location: 'Conference Room A')])
      assert_includes result, 'Conference Room A'
    end

    def test_format_event_list_all_day
      assert_includes @formatter.format_event_list_compact([build_event(is_all_day: true)]), 'ALL DAY'
    end

    def test_format_event_list_cancelled
      assert_includes @formatter.format_event_list_compact([build_event(is_cancelled: true)]), 'cancelled'
    end

    def test_format_event_list_shows_accepted_rsvp
      result = @formatter.format_event_list_compact([build_event(response_status: 'accepted')])
      assert_includes result, "\u{2713}"
    end

    def test_format_event_list_shows_declined_rsvp
      result = @formatter.format_event_list_compact([build_event(response_status: 'declined')])
      assert_includes result, "\u{2717}"
    end

    def test_format_event_list_shows_tentative_rsvp
      result = @formatter.format_event_list_compact([build_event(response_status: 'tentativelyAccepted')])
      assert_includes result, '?'
    end

    def test_format_event_list_shows_pending_rsvp
      result = @formatter.format_event_list_compact([build_event(response_status: 'none')])
      assert_includes result, "\u{B7}"
    end

    def test_format_event_list_shows_recurring
      result = @formatter.format_event_list_compact([build_event(event_type: 'occurrence')])
      assert_includes result, '(recurring)'
    end

    def test_format_event_list_no_recurring_for_single
      result = @formatter.format_event_list_compact([build_event(event_type: 'singleInstance')])
      refute_includes result, '(recurring)'
    end

    def test_format_event_list_verbose_shows_organizer
      assert_includes @formatter.format_event_list_verbose([build_event]), 'Alice Manager'
    end

    def test_format_event_list_verbose_shows_rsvp_summary
      attendees = [
        { name: 'Bob', email: 'bob@test.com', type: 'required', response: 'accepted' },
        { name: 'Carol', email: 'carol@test.com', type: 'required', response: 'declined' },
        { name: 'Dave', email: 'dave@test.com', type: 'optional', response: 'tentativelyAccepted' }
      ]
      result = @formatter.format_event_list_verbose([build_event(attendees: attendees)])
      assert_includes result, '1 accepted'
      assert_includes result, '1 declined'
      assert_includes result, '1 tentative'
    end

    def test_format_event_list_multiple_events
      events = [build_event(subject: 'Meeting 1'), build_event(subject: 'Meeting 2')]
      result = @formatter.format_event_list_compact(events)
      assert_includes result, '[1]'
      assert_includes result, '[2]'
      assert_includes result, 'Meeting 1'
      assert_includes result, 'Meeting 2'
    end

    def test_format_event_list_no_location
      refute_includes @formatter.format_event_list_compact([build_event(location: nil)]), '()'
    end

    def test_format_event_list_empty_location
      refute_includes @formatter.format_event_list_compact([build_event(location: '')]), '()'
    end

    def test_format_event_list_verbose_no_organizer
      refute_includes @formatter.format_event_list_verbose([build_event(organizer: nil)]), 'Organizer:'
    end

    def test_format_event_list_verbose_no_attendees
      result = @formatter.format_event_list_verbose([build_event(attendees: [], organizer: nil)])
      refute_includes result, '|'
    end

    def test_time_range_display_no_times
      assert_equal '', build_event(start_time: nil, end_time: nil, is_all_day: false).time_range_display
    end
  end

  # Tests event detail formatting for subject, time, location, organizer, and status
  class EventDetailBasicTest < Minitest::Test
    include SharedHelpers

    def initialize(*)
      @formatter = nil
      super
    end

    def test_format_event_detail_subject
      assert_includes @formatter.format_event_detail(build_event), 'Weekly Standup'
    end

    def test_format_event_detail_time
      assert_includes @formatter.format_event_detail(build_event), '09:00-10:00'
    end

    def test_format_event_detail_location
      assert_includes @formatter.format_event_detail(build_event(location: 'Room 101')), 'Room 101'
    end

    def test_format_event_detail_organizer
      result = @formatter.format_event_detail(build_event)
      assert_includes result, 'Alice Manager'
      assert_includes result, 'alice@example.com'
    end

    def test_format_event_detail_online_meeting_url
      result = @formatter.format_event_detail(
        build_event(online_meeting_url: 'https://teams.microsoft.com/meeting/123')
      )
      assert_includes result, 'https://teams.microsoft.com/meeting/123'
    end

    def test_format_event_detail_cancelled
      assert_includes @formatter.format_event_detail(build_event(is_cancelled: true)), 'CANCELLED'
    end

    def test_format_event_detail_body_preview
      result = @formatter.format_event_detail(build_event(body_preview: 'Discuss sprint progress.'))
      assert_includes result, 'Discuss sprint progress.'
      assert_includes result, 'Description:'
    end

    def test_format_event_detail_no_body_preview
      refute_includes @formatter.format_event_detail(build_event(body_preview: nil)), 'Description:'
    end

    def test_format_event_detail_all_day
      assert_includes @formatter.format_event_detail(build_event(is_all_day: true)), 'ALL DAY'
    end

    def test_format_event_detail_rsvp_accepted
      result = @formatter.format_event_detail(build_event(response_status: 'accepted'))
      assert_includes result, 'RSVP:'
      assert_includes result, 'Accepted'
    end

    def test_format_event_detail_rsvp_declined
      result = @formatter.format_event_detail(build_event(response_status: 'declined'))
      assert_includes result, 'Declined'
    end

    def test_format_event_detail_rsvp_tentative
      result = @formatter.format_event_detail(build_event(response_status: 'tentativelyAccepted'))
      assert_includes result, 'Tentative'
    end

    def test_format_event_detail_no_rsvp_when_nil
      refute_includes @formatter.format_event_detail(build_event(response_status: nil)), 'RSVP:'
    end

    def test_format_event_detail_recurring
      result = @formatter.format_event_detail(build_event(event_type: 'occurrence'))
      assert_includes result, 'Recurrence: Yes'
    end

    def test_format_event_detail_not_recurring
      refute_includes @formatter.format_event_detail(build_event(event_type: 'singleInstance')), 'Recurrence'
    end

    def test_format_event_detail_nil_organizer
      refute_includes @formatter.format_event_detail(build_event(organizer: nil)), 'Organizer:'
    end

    def test_format_event_detail_nil_start_end_time
      result = @formatter.format_event_detail(build_event(start_time: nil, end_time: nil, is_all_day: false))
      assert_includes result, '(unknown)'
    end

    def test_format_event_detail_show_as
      assert_includes @formatter.format_event_detail(build_event(show_as: 'tentative')), 'tentative'
    end

    def test_format_event_detail_empty_body_preview
      refute_includes @formatter.format_event_detail(build_event(body_preview: '   ')), 'Description:'
    end

    def test_non_cancelled_event_no_cancelled_status
      refute_includes @formatter.format_event_detail(build_event(is_cancelled: false)), 'CANCELLED'
    end

    def test_format_event_detail_not_cancelled_no_status_line
      result = @formatter.format_event_detail(build_event(is_cancelled: false, show_as: nil))
      refute_includes result, 'CANCELLED'
      refute_includes result, 'Show as:'
    end
  end

  # Tests attendee display formatting with response symbols and organizer markers
  class EventDetailAttendeesTest < Minitest::Test
    include SharedHelpers

    def initialize(*)
      @formatter = nil
      super
    end

    def test_format_event_detail_required_attendees
      attendees = [{ name: 'Bob', email: 'bob@test.com', type: 'required', response: 'accepted' }]
      result = @formatter.format_event_detail(build_event(attendees: attendees))
      assert_includes result, 'Required Attendees:'
      assert_includes result, 'Bob'
      assert_includes result, 'Accepted'
    end

    def test_format_event_detail_optional_attendees
      attendees = [{ name: 'Carol', email: 'carol@test.com', type: 'optional', response: 'declined' }]
      result = @formatter.format_event_detail(build_event(attendees: attendees))
      assert_includes result, 'Optional Attendees:'
      assert_includes result, 'Carol'
      assert_includes result, 'Declined'
    end

    def test_format_event_detail_attendee_response_symbols
      result = @formatter.format_event_detail(build_event(attendees: response_symbol_attendees))
      assert_includes result, "\u{2713}"
      assert_includes result, "\u{2717}"
      assert_includes result, '?'
      assert_includes result, "\u{B7}"
    end

    def test_format_event_detail_organizer_symbol
      attendees = [{ name: 'Alice Manager', email: 'alice@example.com', type: 'required', response: 'accepted' }]
      assert_includes @formatter.format_event_detail(build_event(attendees: attendees)), "\u{2605}"
    end

    def test_response_label_unknown_response
      formatter = Teems::Formatters::CalendarAttendeeFormatter
      label = formatter.instance_method(:response_label).bind_call(@formatter, 'customStatus')
      assert_equal 'Customstatus', label
    end

    def test_response_label_nil_response
      formatter = Teems::Formatters::CalendarAttendeeFormatter
      label = formatter.instance_method(:response_label).bind_call(@formatter, nil)
      assert_equal 'Pending', label
    end

    def test_format_untyped_attendees
      attendees = [{ name: 'Unknown Type', email: 'u@test.com', type: 'resource', response: 'accepted' }]
      result = @formatter.format_event_detail(build_event(attendees: attendees))
      assert_includes result, 'Attendees:'
      assert_includes result, 'Unknown Type'
    end

    def test_attendee_without_name_uses_email
      attendees = [{ name: nil, email: 'noname@test.com', type: 'required', response: 'accepted' }]
      assert_includes @formatter.format_event_detail(build_event(attendees: attendees)), 'noname@test.com'
    end

    def test_attendee_without_email
      attendees = [{ name: 'No Email', email: nil, type: 'required', response: 'accepted' }]
      assert_includes @formatter.format_event_detail(build_event(attendees: attendees)), 'No Email'
    end

    def test_organizer_check_with_nil_email
      attendees = [{ name: 'Null Email', email: nil, type: 'required', response: 'accepted' }]
      assert_includes @formatter.format_event_detail(build_event(attendees: attendees)), 'Null Email'
    end

    def test_organizer_with_nil_email_not_matched
      attendees = [{ name: 'Someone', email: 'someone@test.com', type: 'required', response: 'accepted' }]
      event = build_event(attendees: attendees, organizer: { name: 'Organizer', email: nil })
      result = @formatter.format_event_detail(event)
      assert_includes result, 'Someone'
      refute_includes result, "\u{2605}"
    end
  end
end
