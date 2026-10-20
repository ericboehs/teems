# frozen_string_literal: true

require 'test_helper'

class IcsEventTest < Minitest::Test
  ATTENDEES = [
    { 'type' => 'required', 'status' => { 'response' => 'accepted' },
      'emailAddress' => { 'name' => 'Ann', 'address' => 'Ann@Example.com' } },
    { 'type' => 'optional', 'status' => { 'response' => 'none' },
      'emailAddress' => { 'name' => 'Bob', 'address' => 'bob@example.com' } }
  ].freeze
  GRAPH_EVENT = {
    'id' => 'evt-1', 'iCalUId' => 'uid-1', 'subject' => 'Standup',
    'start' => { 'dateTime' => '2026-10-21T14:00:00.0000000', 'timeZone' => 'UTC' },
    'end' => { 'dateTime' => '2026-10-21T14:15:00.0000000', 'timeZone' => 'UTC' },
    'isAllDay' => false, 'location' => { 'displayName' => 'Room 1' },
    'organizer' => { 'emailAddress' => { 'name' => 'Olive Org', 'address' => 'olive@example.com' } },
    'attendees' => ATTENDEES,
    'body' => { 'contentType' => 'html', 'content' => '<p>Join <a href="https://teams.example/j">here</a></p>' },
    'onlineMeeting' => { 'joinUrl' => 'https://teams.example/j' }, 'showAs' => 'busy', 'isCancelled' => false
  }.freeze

  def graph_event(overrides = {}) = GRAPH_EVENT.merge(overrides)

  def event(overrides = {}) = Teems::Models::IcsEvent.from_api(graph_event(overrides))

  def test_timed_events_are_utc
    evt = event

    assert_equal Time.utc(2026, 10, 21, 14), evt.starts
    assert_predicate evt.starts, :utc?
    assert_equal Time.utc(2026, 10, 21, 14, 15), evt.ends
    assert_equal 'uid-1', evt.uid
    assert_predicate evt, :dated?
  end

  def test_all_day_events_are_dates
    evt = event('isAllDay' => true, 'start' => { 'dateTime' => '2026-10-21T00:00:00.0000000' },
                'end' => { 'dateTime' => '2026-10-23T00:00:00.0000000' })

    assert_equal Date.new(2026, 10, 21), evt.starts
    assert_equal Date.new(2026, 10, 23), evt.ends
    assert evt.all_day
  end

  def test_missing_or_bad_times_and_fields
    evt = Teems::Models::IcsEvent.from_api('id' => 'x', 'start' => { 'dateTime' => 'garbage' })

    assert_nil evt.starts
    assert_nil evt.ends
    refute_predicate evt, :dated?
    assert_equal 'x', evt.uid
    assert_equal '', evt.location
    assert_equal '', evt.description
    refute_predicate evt, :cancelled?
  end

  def test_description_converts_html_and_keeps_text
    assert_equal "Join here [1]\n\nLinks:\n[1] here <https://teams.example/j>", event.description
    text = event('body' => { 'contentType' => 'text', 'content' => "  Agenda\n- one\n" })

    assert_equal "Agenda\n- one", text.description
  end

  def test_status
    assert_predicate event('isCancelled' => true), :cancelled?
    assert_predicate event('showAs' => 'free'), :free?
    refute_predicate event, :free?
  end

  def test_involves_organizer_or_accepted_attendee
    evt = event

    assert evt.involves?(['olive@example.com'])
    assert evt.involves?(['ann@example.com']), 'accepted, compared without case'
    refute evt.involves?(['bob@example.com']), 'invited but not accepted'
    refute evt.involves?([])
    refute event('organizer' => nil, 'attendees' => nil).involves?(['olive@example.com'])
  end
end
