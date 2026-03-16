# frozen_string_literal: true

require 'test_helper'

module EventTests
  class BasicParsingTest < Minitest::Test
    def test_from_api_parses_basic_fields
      event = Teems::Models::Event.from_api(sample_event_data)

      assert_equal 'AAMkAGVmMDEzMTM4LTZmYWUtNDdkNC1hMDZe', event.id
      assert_equal 'Weekly Standup', event.subject
      assert_instance_of Time, event.start_time
      assert_instance_of Time, event.end_time
      assert_equal 'Conference Room A', event.location
      refute event.is_all_day
    end

    def test_from_api_parses_organizer_and_attendees
      event = Teems::Models::Event.from_api(sample_event_data)

      assert_equal({ name: 'Alice Manager', email: 'alice@example.com' }, event.organizer)
      assert_equal 4, event.attendees.length
      assert_equal 'Discuss sprint progress and blockers.', event.body_preview
      assert_equal 'https://teams.microsoft.com/l/meetup-join/123', event.online_meeting_url
    end

    def test_from_api_parses_status_fields
      event = Teems::Models::Event.from_api(sample_event_data)

      assert_equal 'busy', event.show_as
      assert_equal 'normal', event.importance
      refute event.is_cancelled
      assert_equal 'accepted', event.response_status
      assert_equal 'normal', event.sensitivity
    end

    def test_from_api_missing_fields_basic
      event = Teems::Models::Event.from_api({ 'id' => 'evt-1' })

      assert_equal 'evt-1', event.id
      assert_equal '(No subject)', event.subject
      assert_nil event.start_time
      assert_nil event.end_time
      assert_nil event.location
      refute event.is_all_day
    end

    def test_from_api_missing_fields_detail
      event = Teems::Models::Event.from_api({ 'id' => 'evt-1' })

      assert_nil event.organizer
      assert_equal [], event.attendees
      assert_nil event.body_preview
      assert_nil event.online_meeting_url
      assert_nil event.show_as
      refute event.is_cancelled
    end

    def test_from_api_with_all_day_event
      data = sample_event_data.merge('isAllDay' => true)
      event = Teems::Models::Event.from_api(data)

      assert event.all_day?
    end

    def test_from_api_with_cancelled_event
      data = sample_event_data.merge('isCancelled' => true)
      event = Teems::Models::Event.from_api(data)

      assert event.cancelled?
    end

    def test_all_day_predicate
      data = sample_event_data.merge('isAllDay' => true)
      event = Teems::Models::Event.from_api(data)

      assert event.all_day?
    end

    def test_cancelled_predicate
      data = sample_event_data.merge('isCancelled' => true)
      event = Teems::Models::Event.from_api(data)

      assert event.cancelled?
    end

    def test_time_range_display_for_regular_event
      event = Teems::Models::Event.from_api(sample_event_data)

      assert_equal '09:00-10:00', event.time_range_display
    end

    def test_time_range_display_for_all_day_event
      data = sample_event_data.merge('isAllDay' => true)
      event = Teems::Models::Event.from_api(data)

      assert_equal 'ALL DAY', event.time_range_display
    end

    def test_time_range_display_with_missing_times
      data = { 'id' => 'evt-1' }
      event = Teems::Models::Event.from_api(data)

      assert_equal '', event.time_range_display
    end

    def test_handles_invalid_time_gracefully
      data = sample_event_data.merge(
        'start' => { 'dateTime' => 'not-a-time' },
        'end' => { 'dateTime' => 'also-not-a-time' }
      )
      event = Teems::Models::Event.from_api(data)

      assert_nil event.start_time
      assert_nil event.end_time
    end

    def test_organizer_parsing
      event = Teems::Models::Event.from_api(sample_event_data)

      assert_equal 'Alice Manager', event.organizer[:name]
      assert_equal 'alice@example.com', event.organizer[:email]
    end

    def test_nil_organizer
      data = sample_event_data.dup
      data.delete('organizer')
      event = Teems::Models::Event.from_api(data)

      assert_nil event.organizer
    end
  end

  class AttendeesAndBodyTest < Minitest::Test
    def test_required_attendees
      event = Teems::Models::Event.from_api(sample_event_data)
      required = event.required_attendees

      assert_equal 2, required.length
      assert_equal 'Bob Dev', required[0][:name]
      assert_equal 'Carol QA', required[1][:name]
    end

    def test_optional_attendees
      event = Teems::Models::Event.from_api(sample_event_data)
      optional = event.optional_attendees

      assert_equal 2, optional.length
      assert_equal 'Dave PM', optional[0][:name]
      assert_equal 'Eve Intern', optional[1][:name]
    end

    def test_accepted_attendees
      event = Teems::Models::Event.from_api(sample_event_data)
      accepted = event.accepted_attendees

      assert_equal 1, accepted.length
      assert_equal 'Bob Dev', accepted[0][:name]
    end

    def test_declined_attendees
      event = Teems::Models::Event.from_api(sample_event_data)
      declined = event.declined_attendees

      assert_equal 1, declined.length
      assert_equal 'Carol QA', declined[0][:name]
    end

    def test_tentative_attendees
      event = Teems::Models::Event.from_api(sample_event_data)
      tentative = event.tentative_attendees

      assert_equal 1, tentative.length
      assert_equal 'Dave PM', tentative[0][:name]
    end

    def test_pending_attendees
      event = Teems::Models::Event.from_api(sample_event_data)
      pending = event.pending_attendees

      assert_equal 1, pending.length
      assert_equal 'Eve Intern', pending[0][:name]
    end

    def test_attendee_parsing
      event = Teems::Models::Event.from_api(sample_event_data)
      first = event.attendees[0]

      assert_equal 'Bob Dev', first[:name]
      assert_equal 'bob@example.com', first[:email]
      assert_equal 'required', first[:type]
      assert_equal 'accepted', first[:response]
    end

    def test_no_attendees
      event = Teems::Models::Event.from_api(sample_event_data.merge('attendees' => nil))

      assert_equal [], event.attendees
      assert_equal [], event.required_attendees
      assert_equal [], event.optional_attendees
      assert_equal [], event.accepted_attendees
    end

    def test_no_attendees_response_filters
      event = Teems::Models::Event.from_api(sample_event_data.merge('attendees' => nil))

      assert_equal [], event.declined_attendees
      assert_equal [], event.tentative_attendees
      assert_equal [], event.pending_attendees
    end

    def test_empty_attendees_array
      data = sample_event_data.merge('attendees' => [])
      event = Teems::Models::Event.from_api(data)

      assert_equal [], event.attendees
    end

    def test_body_preview_from_body_content
      data = sample_event_data.dup
      data.delete('bodyPreview')
      data['body'] = { 'content' => 'Full body content here' }
      event = Teems::Models::Event.from_api(data)

      assert_equal 'Full body content here', event.body_preview
    end

    def test_body_preview_strips_html_from_body_content
      data = sample_event_data.dup
      data.delete('bodyPreview')
      data['body'] = { 'content' => '<html><body><p>Hello <b>world</b></p><br><p>Second paragraph</p></body></html>' }
      event = Teems::Models::Event.from_api(data)

      assert_equal 'Hello world Second paragraph', event.body_preview
    end

    def test_body_preview_decodes_html_entities
      data = sample_event_data.dup
      data.delete('bodyPreview')
      data['body'] = { 'content' => '<p>Tom &amp; Jerry&nbsp;show</p>' }
      event = Teems::Models::Event.from_api(data)

      assert_equal 'Tom & Jerry show', event.body_preview
    end

    def test_body_preview_nil_when_no_body
      data = sample_event_data.dup
      data.delete('bodyPreview')
      data.delete('body')
      event = Teems::Models::Event.from_api(data)

      assert_nil event.body_preview
    end
  end

  class DateDisplayTest < Minitest::Test
    def test_date_display_all_day
      event = Teems::Models::Event.from_api(sample_event_data.merge('isAllDay' => true))
      assert_match(/\d{4}-\d{2}-\d{2} \(all day\)/, event.date_display)
    end

    def test_date_display_timed_event
      event = Teems::Models::Event.from_api(sample_event_data)
      assert_match(/\d{4}-\d{2}-\d{2} \d{2}:\d{2}-\d{2}:\d{2}/, event.date_display)
    end

    def test_date_display_nil_times
      event = Teems::Models::Event.new(
        id: 'e1', subject: 'Test', start_time: nil, end_time: nil,
        location: nil, is_all_day: false, organizer: nil, attendees: [],
        body_preview: nil, online_meeting_url: nil, show_as: nil,
        importance: nil, is_cancelled: false, response_status: nil, sensitivity: nil
      )
      assert_nil event.date_display
    end
  end

  class CreateSummaryLinesTest < Minitest::Test
    def test_summary_lines_with_all_fields
      data = sample_event_data.merge('onlineMeeting' => { 'joinUrl' => 'https://teams.example.com/join' })
      lines = Teems::Models::Event.from_api(data).create_summary_lines
      assert(lines.any? { |l| l.include?('09:00') })
      assert(lines.any? { |l| l.include?('Location:') })
      assert(lines.any? { |l| l.include?('Teams link:') })
    end

    def test_summary_lines_empty_location_omitted
      data = sample_event_data.merge('location' => { 'displayName' => '' })
      lines = Teems::Models::Event.from_api(data).create_summary_lines
      refute(lines.any? { |l| l.include?('Location:') })
    end

    def test_summary_lines_nil_location_omitted
      data = sample_event_data.merge('location' => { 'displayName' => nil })
      lines = Teems::Models::Event.from_api(data).create_summary_lines
      refute(lines.any? { |l| l.include?('Location:') })
    end

    def test_summary_lines_no_meeting_url
      data = sample_event_data.merge('onlineMeeting' => nil)
      lines = Teems::Models::Event.from_api(data).create_summary_lines
      refute(lines.any? { |l| l.include?('Teams link:') })
    end
  end
end
