# frozen_string_literal: true

require 'test_helper'

module CalendarApiTests
  module Helpers
    def setup
      @api_client = Teems::TestHelpers::MockApiClient.new
      @account = mock_account
      @calendar_api = Teems::Api::Calendar.new(@api_client, @account)
    end

    private

    def list_events_chicago
      @calendar_api.list_events(
        start_dt: '2026-01-20T00:00:00', end_dt: '2026-01-20T23:59:59',
        timezone: 'America/Chicago'
      )
    end
  end

  class ListEventsTest < Minitest::Test
    include Helpers

    def test_list_events_calls_correct_endpoint
      @api_client.stub('calendarView', { 'value' => [] })
      @calendar_api.list_events(
        start_dt: '2026-01-20T00:00:00', end_dt: '2026-01-20T23:59:59', timezone: 'America/Chicago'
      )
      call = @api_client.calls.first
      assert_equal :get, call[:method]
      assert_includes call[:path], '/v1.0/me/calendarView'
    end

    def test_list_events_passes_date_params
      @api_client.stub('calendarView', { 'value' => [] })
      @calendar_api.list_events(
        start_dt: '2026-01-20T00:00:00', end_dt: '2026-01-20T23:59:59', timezone: 'America/Chicago'
      )
      call = @api_client.calls.first
      assert_equal '2026-01-20T00:00:00', call[:params]['startDateTime']
      assert_equal '2026-01-20T23:59:59', call[:params]['endDateTime']
    end

    def test_list_events_passes_timezone_header
      @api_client.stub('calendarView', { 'value' => [] })
      @calendar_api.list_events(
        start_dt: '2026-01-20T00:00:00', end_dt: '2026-01-20T23:59:59', timezone: 'America/Chicago'
      )
      assert_equal 'outlook.timezone="America/Chicago"', @api_client.calls.first[:headers]['Prefer']
    end

    def test_list_events_passes_select_and_orderby
      @api_client.stub('calendarView', { 'value' => [] })
      @calendar_api.list_events(
        start_dt: '2026-01-20T00:00:00', end_dt: '2026-01-20T23:59:59', timezone: 'America/Chicago'
      )
      call = @api_client.calls.first
      assert_includes call[:params]['$select'], 'subject'
      assert_includes call[:params]['$select'], 'attendees'
      assert_equal 'start/dateTime', call[:params]['$orderby']
    end

    def test_list_events_passes_top_param
      @api_client.stub('calendarView', { 'value' => [] })
      @calendar_api.list_events(
        start_dt: '2026-01-20T00:00:00', end_dt: '2026-01-20T23:59:59', timezone: 'UTC', top: 25
      )
      assert_equal 25, @api_client.calls.first[:params]['$top']
    end

    def test_list_events_returns_event_models
      @api_client.stub('calendarView', { 'value' => [sample_event_data] })
      events = list_events_chicago
      assert_equal 1, events.length
      assert_instance_of Teems::Models::Event, events.first
      assert_equal 'Weekly Standup', events.first.subject
    end

    def test_list_events_handles_pagination
      next_link = 'https://graph.microsoft.com/v1.0/me/calendarView?$skiptoken=abc'
      page1 = { 'value' => [sample_event_data], '@odata.nextLink' => next_link }
      page2 = { 'value' => [sample_event_data.merge('id' => 'event-2', 'subject' => 'Lunch')] }
      @api_client.stub('/v1.0/me/calendarView', page1)
      @api_client.stub(next_link, page2)
      events = list_events_chicago
      assert_equal 2, events.length
      assert_equal 'Weekly Standup', events[0].subject
      assert_equal 'Lunch', events[1].subject
    end
  end

  class GetEventAndRsvpTest < Minitest::Test
    include Helpers

    def test_get_event_calls_correct_endpoint
      @api_client.stub('events', sample_event_data)
      @calendar_api.get_event(event_id: 'AAMkAGVmMDEzMTM4LTZmYWUtNDdkNC1hMDZe', timezone: 'America/Chicago')
      call = @api_client.calls.first
      assert_equal :get, call[:method]
      assert_includes call[:path], '/v1.0/me/events/'
      assert_includes call[:path], 'AAMkAGVmMDEzMTM4LTZmYWUtNDdkNC1hMDZe'
    end

    def test_get_event_passes_timezone_header
      @api_client.stub('events', sample_event_data)
      @calendar_api.get_event(event_id: 'event-123', timezone: 'America/New_York')
      assert_equal 'outlook.timezone="America/New_York"', @api_client.calls.first[:headers]['Prefer']
    end

    def test_get_event_returns_event_model
      @api_client.stub('events', sample_event_data)
      event = @calendar_api.get_event(event_id: 'event-123', timezone: 'America/Chicago')
      assert_instance_of Teems::Models::Event, event
      assert_equal 'Weekly Standup', event.subject
    end

    def test_get_event_passes_select_param
      @api_client.stub('events', sample_event_data)
      @calendar_api.get_event(event_id: 'event-123', timezone: 'UTC')
      call = @api_client.calls.first
      assert_includes call[:params]['$select'], 'subject'
      assert_includes call[:params]['$select'], 'body'
    end

    def test_rsvp_accept_calls_correct_endpoint
      @api_client.stub('accept', {})
      @calendar_api.rsvp_event(event_id: 'event-123', action: 'accept')
      call = @api_client.calls.first
      assert_equal :post, call[:method]
      assert_includes call[:path], '/v1.0/me/events/event-123/accept'
    end

    def test_rsvp_decline_calls_correct_endpoint
      @api_client.stub('decline', {})
      @calendar_api.rsvp_event(event_id: 'event-456', action: 'decline')
      assert_includes @api_client.calls.first[:path], '/v1.0/me/events/event-456/decline'
    end

    def test_rsvp_tentative_maps_to_tentatively_accept
      @api_client.stub('tentativelyAccept', {})
      @calendar_api.rsvp_event(event_id: 'event-789', action: 'tentative')
      assert_includes @api_client.calls.first[:path], '/tentativelyAccept'
    end

    def test_rsvp_sends_response_by_default
      @api_client.stub('accept', {})
      @calendar_api.rsvp_event(event_id: 'event-123', action: 'accept')
      assert_equal true, @api_client.calls.first[:body][:sendResponse]
    end

    def test_rsvp_with_notify_silent
      @api_client.stub('accept', {})
      @calendar_api.rsvp_event(event_id: 'event-123', action: 'accept', notify: :silent)
      assert_equal false, @api_client.calls.first[:body][:sendResponse]
    end

    def test_rsvp_with_comment
      @api_client.stub('accept', {})
      @calendar_api.rsvp_event(event_id: 'event-123', action: 'accept', comment: 'Will be there!')
      assert_equal 'Will be there!', @api_client.calls.first[:body][:comment]
    end

    def test_rsvp_without_comment_omits_key
      @api_client.stub('accept', {})
      @calendar_api.rsvp_event(event_id: 'event-123', action: 'accept')
      refute @api_client.calls.first[:body].key?(:comment)
    end

    def test_rsvp_encodes_event_id
      @api_client.stub('accept', {})
      @calendar_api.rsvp_event(event_id: 'AAMkAGVm+special/chars=', action: 'accept')
      assert_includes @api_client.calls.first[:path], URI.encode_www_form_component('AAMkAGVm+special/chars=')
    end
  end

  class CreateEventTest < Minitest::Test
    include Helpers

    def test_create_event_posts_to_correct_endpoint
      @api_client.stub('/v1.0/me/events', sample_event_data)
      @calendar_api.create_event(
        subject: 'Test Meeting', start_dt: '2026-03-20T14:00:00',
        end_dt: '2026-03-20T14:30:00', timezone: 'America/Chicago'
      )
      call = @api_client.calls.first
      assert_equal :post, call[:method]
      assert_equal '/v1.0/me/events', call[:path]
    end

    def test_create_event_sends_subject_and_times
      @api_client.stub('/v1.0/me/events', sample_event_data)
      @calendar_api.create_event(
        subject: 'Standup', start_dt: '2026-03-20T09:00:00',
        end_dt: '2026-03-20T09:15:00', timezone: 'America/Chicago'
      )
      body = @api_client.calls.first[:body]
      assert_equal 'Standup', body[:subject]
      assert_equal({ dateTime: '2026-03-20T09:00:00', timeZone: 'America/Chicago' }, body[:start])
      assert_equal({ dateTime: '2026-03-20T09:15:00', timeZone: 'America/Chicago' }, body[:end])
    end

    def test_create_event_with_location
      @api_client.stub('/v1.0/me/events', sample_event_data)
      @calendar_api.create_event(
        subject: 'Meeting', start_dt: '2026-03-20T14:00:00',
        end_dt: '2026-03-20T15:00:00', timezone: 'UTC', location: 'Room A'
      )
      assert_equal({ displayName: 'Room A' }, @api_client.calls.first[:body][:location])
    end

    def test_create_event_with_body_text
      @api_client.stub('/v1.0/me/events', sample_event_data)
      @calendar_api.create_event(
        subject: 'Meeting', start_dt: '2026-03-20T14:00:00',
        end_dt: '2026-03-20T15:00:00', timezone: 'UTC', body_text: 'Agenda items'
      )
      assert_equal({ contentType: 'text', content: 'Agenda items' }, @api_client.calls.first[:body][:body])
    end

    def test_create_event_with_attendees
      @api_client.stub('/v1.0/me/events', sample_event_data)
      @calendar_api.create_event(
        subject: 'Meeting', start_dt: '2026-03-20T14:00:00',
        end_dt: '2026-03-20T15:00:00', timezone: 'UTC',
        attendees: %w[alice@example.com bob@example.com]
      )
      attendees = @api_client.calls.first[:body][:attendees]
      assert_equal 2, attendees.length
      assert_equal 'alice@example.com', attendees[0][:emailAddress][:address]
      assert_equal 'required', attendees[0][:type]
    end

    def test_create_event_with_online_meeting
      @api_client.stub('/v1.0/me/events', sample_event_data)
      @calendar_api.create_event(
        subject: 'Meeting', start_dt: '2026-03-20T14:00:00',
        end_dt: '2026-03-20T15:00:00', timezone: 'UTC', online_meeting: true
      )
      body = @api_client.calls.first[:body]
      assert_equal true, body[:isOnlineMeeting]
      assert_equal 'teamsForBusiness', body[:onlineMeetingProvider]
    end

    def test_create_event_without_online_meeting
      @api_client.stub('/v1.0/me/events', sample_event_data)
      @calendar_api.create_event(
        subject: 'Meeting', start_dt: '2026-03-20T14:00:00',
        end_dt: '2026-03-20T15:00:00', timezone: 'UTC'
      )
      body = @api_client.calls.first[:body]
      refute body.key?(:isOnlineMeeting)
    end

    def test_create_event_all_day
      @api_client.stub('/v1.0/me/events', sample_event_data)
      @calendar_api.create_event(
        subject: 'Day Off', start_dt: '2026-03-20T00:00:00',
        end_dt: '2026-03-20T00:00:00', timezone: 'UTC', all_day: true
      )
      assert_equal true, @api_client.calls.first[:body][:isAllDay]
    end

    def test_create_event_returns_event_model
      @api_client.stub('/v1.0/me/events', sample_event_data)
      event = @calendar_api.create_event(
        subject: 'Meeting', start_dt: '2026-03-20T14:00:00',
        end_dt: '2026-03-20T15:00:00', timezone: 'UTC'
      )
      assert_instance_of Teems::Models::Event, event
    end

    def test_create_event_omits_optional_fields_when_nil
      @api_client.stub('/v1.0/me/events', sample_event_data)
      @calendar_api.create_event(
        subject: 'Meeting', start_dt: '2026-03-20T14:00:00',
        end_dt: '2026-03-20T15:00:00', timezone: 'UTC'
      )
      body = @api_client.calls.first[:body]
      refute body.key?(:location)
      refute body.key?(:body)
      refute body.key?(:attendees)
    end
  end
end
