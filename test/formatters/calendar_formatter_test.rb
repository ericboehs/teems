# frozen_string_literal: true

require 'test_helper'

class CalendarFormatterTest < Minitest::Test
  def setup
    @output = test_output(color: false)
    @formatter = Teems::Formatters::CalendarFormatter.new(output: @output)
  end

  def test_format_event_list_compact
    events = [build_event]

    result = @formatter.format_event_list(events)

    assert_includes result, '[1]'
    assert_includes result, '09:00-10:00'
    assert_includes result, 'Weekly Standup'
  end

  def test_format_event_list_with_location
    events = [build_event(location: 'Conference Room A')]

    result = @formatter.format_event_list(events)

    assert_includes result, 'Conference Room A'
  end

  def test_format_event_list_all_day
    events = [build_event(is_all_day: true)]

    result = @formatter.format_event_list(events)

    assert_includes result, 'ALL DAY'
  end

  def test_format_event_list_cancelled
    events = [build_event(is_cancelled: true)]

    result = @formatter.format_event_list(events)

    assert_includes result, 'cancelled'
  end

  def test_format_event_list_verbose_shows_organizer
    events = [build_event]

    result = @formatter.format_event_list(events, verbose: true)

    assert_includes result, 'Alice Manager'
  end

  def test_format_event_list_verbose_shows_rsvp_summary
    attendees = [
      { name: 'Bob', email: 'bob@test.com', type: 'required', response: 'accepted' },
      { name: 'Carol', email: 'carol@test.com', type: 'required', response: 'declined' },
      { name: 'Dave', email: 'dave@test.com', type: 'optional', response: 'tentativelyAccepted' }
    ]
    events = [build_event(attendees: attendees)]

    result = @formatter.format_event_list(events, verbose: true)

    assert_includes result, '1 accepted'
    assert_includes result, '1 declined'
    assert_includes result, '1 tentative'
  end

  def test_format_event_list_multiple_events
    events = [
      build_event(subject: 'Meeting 1'),
      build_event(subject: 'Meeting 2')
    ]

    result = @formatter.format_event_list(events)

    assert_includes result, '[1]'
    assert_includes result, '[2]'
    assert_includes result, 'Meeting 1'
    assert_includes result, 'Meeting 2'
  end

  def test_format_event_detail_subject
    event = build_event

    result = @formatter.format_event_detail(event)

    assert_includes result, 'Weekly Standup'
  end

  def test_format_event_detail_time
    event = build_event

    result = @formatter.format_event_detail(event)

    assert_includes result, '09:00-10:00'
  end

  def test_format_event_detail_location
    event = build_event(location: 'Room 101')

    result = @formatter.format_event_detail(event)

    assert_includes result, 'Room 101'
  end

  def test_format_event_detail_organizer
    event = build_event

    result = @formatter.format_event_detail(event)

    assert_includes result, 'Alice Manager'
    assert_includes result, 'alice@example.com'
  end

  def test_format_event_detail_online_meeting_url
    event = build_event(online_meeting_url: 'https://teams.microsoft.com/meeting/123')

    result = @formatter.format_event_detail(event)

    assert_includes result, 'https://teams.microsoft.com/meeting/123'
  end

  def test_format_event_detail_cancelled
    event = build_event(is_cancelled: true)

    result = @formatter.format_event_detail(event)

    assert_includes result, 'CANCELLED'
  end

  def test_format_event_detail_body_preview
    event = build_event(body_preview: 'Discuss sprint progress.')

    result = @formatter.format_event_detail(event)

    assert_includes result, 'Discuss sprint progress.'
    assert_includes result, 'Description:'
  end

  def test_format_event_detail_no_body_preview
    event = build_event(body_preview: nil)

    result = @formatter.format_event_detail(event)

    refute_includes result, 'Description:'
  end

  def test_format_event_detail_required_attendees
    attendees = [
      { name: 'Bob', email: 'bob@test.com', type: 'required', response: 'accepted' }
    ]
    event = build_event(attendees: attendees)

    result = @formatter.format_event_detail(event)

    assert_includes result, 'Required Attendees:'
    assert_includes result, 'Bob'
    assert_includes result, 'Accepted'
  end

  def test_format_event_detail_optional_attendees
    attendees = [
      { name: 'Carol', email: 'carol@test.com', type: 'optional', response: 'declined' }
    ]
    event = build_event(attendees: attendees)

    result = @formatter.format_event_detail(event)

    assert_includes result, 'Optional Attendees:'
    assert_includes result, 'Carol'
    assert_includes result, 'Declined'
  end

  def test_format_event_detail_attendee_response_symbols
    attendees = [
      { name: 'Accepted', email: 'a@test.com', type: 'required', response: 'accepted' },
      { name: 'Declined', email: 'd@test.com', type: 'required', response: 'declined' },
      { name: 'Tentative', email: 't@test.com', type: 'required', response: 'tentativelyAccepted' },
      { name: 'Pending', email: 'p@test.com', type: 'required', response: 'none' }
    ]
    event = build_event(attendees: attendees)

    result = @formatter.format_event_detail(event)

    assert_includes result, '✓'
    assert_includes result, '✗'
    assert_includes result, '?'
    assert_includes result, '·'
  end

  def test_format_event_detail_organizer_symbol
    attendees = [
      { name: 'Alice Manager', email: 'alice@example.com', type: 'required', response: 'accepted' }
    ]
    event = build_event(attendees: attendees)

    result = @formatter.format_event_detail(event)

    assert_includes result, '★'
  end

  def test_format_event_detail_all_day
    event = build_event(is_all_day: true)

    result = @formatter.format_event_detail(event)

    assert_includes result, 'ALL DAY'
  end

  def test_format_event_list_no_location
    events = [build_event(location: nil)]

    result = @formatter.format_event_list(events)

    refute_includes result, '()'
  end

  def test_format_event_list_empty_location
    events = [build_event(location: '')]

    result = @formatter.format_event_list(events)

    refute_includes result, '()'
  end

  private

  def build_event(overrides = {})
    defaults = {
      id: 'event-123',
      subject: 'Weekly Standup',
      start_time: Time.new(2026, 1, 20, 9, 0, 0),
      end_time: Time.new(2026, 1, 20, 10, 0, 0),
      location: nil,
      is_all_day: false,
      organizer: { name: 'Alice Manager', email: 'alice@example.com' },
      attendees: [],
      body_preview: nil,
      online_meeting_url: nil,
      show_as: 'busy',
      importance: 'normal',
      is_cancelled: false,
      response_status: 'accepted',
      sensitivity: 'normal'
    }
    Teems::Models::Event.new(**defaults, **overrides)
  end
end
