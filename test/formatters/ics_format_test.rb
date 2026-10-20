# frozen_string_literal: true

require 'test_helper'

class IcsFormatTest < Minitest::Test
  Ics = Teems::Formatters::IcsFormat
  STAMP = Time.utc(2026, 10, 20, 12)
  ATTENDEES = [{ name: 'Ann', email: 'ann@example.com', type: 'required', response: 'accepted' },
               { name: nil, email: 'bob@example.com', type: 'optional', response: 'tentativelyAccepted' },
               { name: 'Room', email: 'room@example.com', type: 'resource', response: 'none' },
               { name: 'No address', email: nil, type: 'required', response: 'accepted' }].freeze
  EVENT = {
    uid: 'uid-1', subject: 'Plan; review, then ship', starts: Time.utc(2026, 10, 21, 14),
    ends: Time.utc(2026, 10, 21, 15), all_day: false, location: 'Room 1',
    organizer: { name: 'Olive, Org', email: 'olive@example.com' }, attendees: ATTENDEES,
    body: { 'contentType' => 'text', 'content' => "Line 1\nLine 2" }, join_url: 'https://teams.example/j',
    status: { cancelled: false, show_as: 'busy' }
  }.freeze

  X500 = '/O=EXCHANGELABS/OU=EXCHANGE ADMINISTRATIVE GROUP/CN=RECIPIENTS/CN=LEGACY'

  def event(**overrides) = Teems::Models::IcsEvent.new(**EVENT, **overrides)

  def unfolded(ics) = ics.gsub("\r\n ", '').split("\r\n")

  def test_calendar_wrapper
    ics = Ics.calendar([], name: 'Work, Home', stamp: STAMP)

    assert_equal ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//ericboehs//teems//EN', 'CALSCALE:GREGORIAN',
                  'METHOD:PUBLISH', 'X-WR-CALNAME:Work\\, Home', 'END:VCALENDAR'], ics.split("\r\n")
    assert ics.end_with?("END:VCALENDAR\r\n")
  end

  def test_timed_event
    lines = unfolded(Ics.calendar([event], name: 'Cal', stamp: STAMP))

    assert_includes lines, 'UID:uid-1'
    assert_includes lines, 'DTSTAMP:20261020T120000Z'
    assert_includes lines, 'DTSTART:20261021T140000Z'
    assert_includes lines, 'DTEND:20261021T150000Z'
    assert_includes lines, 'SUMMARY:Plan\\; review\\, then ship'
    assert_includes lines, 'LOCATION:Room 1'
    assert_includes lines, 'DESCRIPTION:Line 1\\nLine 2'
    refute(lines.any? { |line| line.start_with?('STATUS', 'TRANSP') })
  end

  def test_people
    lines = unfolded(Ics.calendar([event], name: 'Cal', stamp: STAMP))

    assert_includes lines, 'ORGANIZER;CN="Olive, Org":mailto:olive@example.com'
    assert_includes lines, 'ATTENDEE;CN=Ann;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED;RSVP=TRUE:mailto:ann@example.com'
    assert_includes lines, 'ATTENDEE;CN=bob@example.com;ROLE=OPT-PARTICIPANT;PARTSTAT=TENTATIVE;RSVP=TRUE:' \
                           'mailto:bob@example.com'
    assert_includes lines, 'ATTENDEE;CN=Room;ROLE=NON-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:' \
                           'mailto:room@example.com'
    assert_equal(3, lines.count { |line| line.start_with?('ATTENDEE') })
  end

  def test_join_links
    lines = unfolded(Ics.calendar([event], name: 'Cal', stamp: STAMP))

    assert_includes lines, 'URL;VALUE=URI:https://teams.example/j'
    assert_includes lines, 'CONFERENCE;VALUE=URI;FEATURE=AUDIO,VIDEO;LABEL="Microsoft Teams":https://teams.example/j'
    assert_includes lines, 'X-MICROSOFT-SKYPETEAMSMEETINGURL:https://teams.example/j'
  end

  # Unescaped values with a line break would start a property of the sender's choosing
  def test_uid_join_url_and_addresses_cannot_break_lines
    hostile = event(uid: "uid-1\r\nATTACH:x", join_url: "https://teams.example/j\nX-EVIL:1",
                    organizer: { name: 'Olive', email: "olive@example.com\r\nX-EVIL:2" }, attendees: [])
    lines = unfolded(Ics.calendar([hostile], name: 'Cal', stamp: STAMP))

    assert_includes lines, 'UID:uid-1ATTACH:x'
    assert_includes lines, 'URL;VALUE=URI:https://teams.example/jX-EVIL:1'
    assert_includes lines, 'ORGANIZER;CN=Olive:mailto:olive@example.comX-EVIL:2'
  end

  def test_all_day_cancelled_free_and_sparse_event
    sparse = event(starts: Date.new(2026, 10, 21), ends: Date.new(2026, 10, 22), all_day: true, location: '',
                   organizer: nil, attendees: [], body: {}, join_url: '', status: { cancelled: true, show_as: 'free' })
    lines = unfolded(Ics.calendar([sparse], name: 'Cal', stamp: STAMP))

    assert_includes lines, 'DTSTART;VALUE=DATE:20261021'
    assert_includes lines, 'DTEND;VALUE=DATE:20261022'
    assert_includes lines, 'STATUS:CANCELLED'
    assert_includes lines, 'TRANSP:TRANSPARENT'
    refute(lines.any? { |line| line.start_with?('LOCATION', 'ORGANIZER', 'DESCRIPTION', 'URL') })
  end

  def test_events_without_times_are_skipped
    ics = Ics.calendar([event(starts: nil)], name: 'Cal', stamp: STAMP)

    refute_includes ics, 'BEGIN:VEVENT'
  end

  def test_fold_keeps_lines_within_75_octets_and_characters_whole
    line = "SUMMARY:#{'é' * 60}#{'a' * 30}"
    folded = Ics.fold(line)
    parts = folded.split("\r\n")

    assert(parts.all? { |part| part.bytesize <= 75 })
    assert(parts.drop(1).all? { |part| part.start_with?(' ') })
    assert_equal line, folded.gsub("\r\n ", '')
    assert_equal 'short', Ics.fold('short')
  end

  def test_people_without_names_or_internet_addresses
    attendees = [{ name: '', email: 'cara@example.com', type: 'required', response: 'none' },
                 { name: 'Legacy', email: X500, type: 'required', response: 'accepted' }]
    lines = unfolded(Ics.calendar([event(organizer: { name: ' ', email: 'olive@example.com' }, attendees: attendees),
                                   event(uid: 'uid-2', organizer: { name: 'Legacy', email: X500 }, attendees: [])],
                                  name: 'Cal', stamp: STAMP))

    assert_equal ['ORGANIZER;CN=olive@example.com:mailto:olive@example.com'],
                 lines.grep(/\AORGANIZER/)
    assert_equal ['ATTENDEE;CN=cara@example.com;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:' \
                  'mailto:cara@example.com'], lines.grep(/\AATTENDEE/)
  end

  def test_control_characters_are_dropped
    assert_equal "ab\\nc\td", Ics.escape("a\u0000b\nc\td\u007F")
    assert_equal 'a b', Ics.param("a\u0007\nb")
  end

  def test_param_quoting
    assert_equal 'Plain', Ics.param('Plain')
    assert_equal '"Doe, Jane"', Ics.param('Doe, "Jane"')
    assert_equal 'a b', Ics.param("a\r\nb")
  end
end
