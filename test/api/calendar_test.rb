# frozen_string_literal: true

require 'test_helper'

# Tests for the Calendar API wrapper
module CalendarApiTests
  # Shared setup and helpers for calendar API tests
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

  # Tests for listing calendar events with filtering and pagination
  class ListEventsTest < Minitest::Test
    include Helpers

    def initialize(*)
      @api_client = nil
      @calendar_api = nil
      super
    end

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
      params = @api_client.calls.first[:params]
      assert_equal '2026-01-20T00:00:00', params['startDateTime']
      assert_equal '2026-01-20T23:59:59', params['endDateTime']
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
      params = @api_client.calls.first[:params]
      select_fields = params['$select']
      assert_includes select_fields, 'subject'
      assert_includes select_fields, 'attendees'
      assert_equal 'start/dateTime', params['$orderby']
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
      first_event = events.first
      assert_instance_of Teems::Models::Event, first_event
      assert_equal 'Weekly Standup', first_event.subject
    end

    def test_list_events_handles_pagination
      next_link = 'https://graph.microsoft.com/v1.0/me/calendarView?$skiptoken=abc'
      first_page = { 'value' => [sample_event_data], '@odata.nextLink' => next_link }
      second_page = { 'value' => [sample_event_data.merge('id' => 'event-2', 'subject' => 'Lunch')] }
      @api_client.stub('/v1.0/me/calendarView', first_page)
      @api_client.stub(next_link, second_page)
      events = list_events_chicago
      assert_equal 2, events.length
      assert_equal 'Weekly Standup', events[0].subject
      assert_equal 'Lunch', events[1].subject
    end
  end

  # Tests for fetching a single event and sending RSVP responses
  class GetEventAndRsvpTest < Minitest::Test
    include Helpers

    def initialize(*)
      @api_client = nil
      @calendar_api = nil
      super
    end

    def test_get_event_calls_correct_endpoint
      @api_client.stub('events', sample_event_data)
      @calendar_api.get_event(event_id: 'AAMkAGVmMDEzMTM4LTZmYWUtNDdkNC1hMDZe', timezone: 'America/Chicago')
      call = @api_client.calls.first
      assert_equal :get, call[:method]
      call_path = call[:path]
      assert_includes call_path, '/v1.0/me/events/'
      assert_includes call_path, 'AAMkAGVmMDEzMTM4LTZmYWUtNDdkNC1hMDZe'
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
      select_param = @api_client.calls.first[:params]['$select']
      assert_includes select_param, 'subject'
      assert_includes select_param, 'body'
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

  # Tests for creating new calendar events
  class CreateEventTest < Minitest::Test
    include Helpers

    def initialize(*)
      @api_client = nil
      @calendar_api = nil
      super
    end

    def test_create_event_posts_to_correct_endpoint
      @api_client.stub('/v1.0/me/events', sample_event_data)
      @calendar_api.create_event({ subject: 'Test' })
      call = @api_client.calls.first
      assert_equal :post, call[:method]
      assert_equal '/v1.0/me/events', call[:path]
    end

    def test_create_event_passes_body_through
      @api_client.stub('/v1.0/me/events', sample_event_data)
      body = { subject: 'Standup', start: { dateTime: '2026-03-20T09:00:00' } }
      @calendar_api.create_event(body)
      assert_equal body, @api_client.calls.first[:body]
    end

    def test_create_event_returns_event_model
      @api_client.stub('/v1.0/me/events', sample_event_data)
      event = @calendar_api.create_event({ subject: 'Meeting' })
      assert_instance_of Teems::Models::Event, event
    end
  end

  # Tests for deleting calendar events
  class DeleteEventTest < Minitest::Test
    include Helpers

    def initialize(*)
      @api_client = nil
      @calendar_api = nil
      super
    end

    def test_delete_event_calls_correct_endpoint
      @calendar_api.delete_event(event_id: 'event-123')
      call = @api_client.calls.first
      assert_equal :delete, call[:method]
      assert_includes call[:path], '/v1.0/me/events/event-123'
    end

    def test_delete_event_encodes_event_id
      @calendar_api.delete_event(event_id: 'AAMkAGVm+special/chars=')
      assert_includes @api_client.calls.first[:path],
                      URI.encode_www_form_component('AAMkAGVm+special/chars=')
    end
  end
end
