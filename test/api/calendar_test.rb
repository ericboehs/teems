# frozen_string_literal: true

require 'test_helper'

class CalendarApiTest < Minitest::Test
  def setup
    @api_client = Teems::TestHelpers::MockApiClient.new
    @account = mock_account
    @calendar_api = Teems::Api::Calendar.new(@api_client, @account)
  end

  def test_list_events_calls_correct_endpoint
    @api_client.stub('calendarView', { 'value' => [] })

    @calendar_api.list_events(
      start_dt: '2026-01-20T00:00:00',
      end_dt: '2026-01-20T23:59:59',
      timezone: 'America/Chicago'
    )

    call = @api_client.calls.first
    assert_equal :get, call[:method]
    assert_includes call[:path], '/v1.0/me/calendarView'
  end

  def test_list_events_passes_date_params
    @api_client.stub('calendarView', { 'value' => [] })

    @calendar_api.list_events(
      start_dt: '2026-01-20T00:00:00',
      end_dt: '2026-01-20T23:59:59',
      timezone: 'America/Chicago'
    )

    call = @api_client.calls.first
    assert_equal '2026-01-20T00:00:00', call[:params]['startDateTime']
    assert_equal '2026-01-20T23:59:59', call[:params]['endDateTime']
  end

  def test_list_events_passes_timezone_header
    @api_client.stub('calendarView', { 'value' => [] })

    @calendar_api.list_events(
      start_dt: '2026-01-20T00:00:00',
      end_dt: '2026-01-20T23:59:59',
      timezone: 'America/Chicago'
    )

    call = @api_client.calls.first
    assert_equal 'outlook.timezone="America/Chicago"', call[:headers]['Prefer']
  end

  def test_list_events_passes_select_and_orderby
    @api_client.stub('calendarView', { 'value' => [] })

    @calendar_api.list_events(
      start_dt: '2026-01-20T00:00:00',
      end_dt: '2026-01-20T23:59:59',
      timezone: 'America/Chicago'
    )

    call = @api_client.calls.first
    assert_includes call[:params]['$select'], 'subject'
    assert_includes call[:params]['$select'], 'attendees'
    assert_equal 'start/dateTime', call[:params]['$orderby']
  end

  def test_list_events_passes_top_param
    @api_client.stub('calendarView', { 'value' => [] })

    @calendar_api.list_events(
      start_dt: '2026-01-20T00:00:00',
      end_dt: '2026-01-20T23:59:59',
      timezone: 'UTC',
      top: 25
    )

    call = @api_client.calls.first
    assert_equal 25, call[:params]['$top']
  end

  def test_list_events_returns_event_models
    @api_client.stub('calendarView', { 'value' => [sample_event_data] })

    events = @calendar_api.list_events(
      start_dt: '2026-01-20T00:00:00',
      end_dt: '2026-01-20T23:59:59',
      timezone: 'America/Chicago'
    )

    assert_equal 1, events.length
    assert_instance_of Teems::Models::Event, events.first
    assert_equal 'Weekly Standup', events.first.subject
  end

  def test_list_events_handles_pagination
    next_link = 'https://graph.microsoft.com/v1.0/me/calendarView?$skiptoken=abc'
    page1 = {
      'value' => [sample_event_data],
      '@odata.nextLink' => next_link
    }
    page2 = {
      'value' => [sample_event_data.merge('id' => 'event-2', 'subject' => 'Lunch')]
    }

    # Stub with exact paths. The initial call uses '/v1.0/me/calendarView',
    # the pagination call uses the full next_link URL.
    @api_client.stub('/v1.0/me/calendarView', page1)
    @api_client.stub(next_link, page2)

    events = @calendar_api.list_events(
      start_dt: '2026-01-20T00:00:00',
      end_dt: '2026-01-20T23:59:59',
      timezone: 'America/Chicago'
    )

    assert_equal 2, events.length
    assert_equal 'Weekly Standup', events[0].subject
    assert_equal 'Lunch', events[1].subject
  end

  def test_get_event_calls_correct_endpoint
    @api_client.stub('events', sample_event_data)

    @calendar_api.get_event(
      event_id: 'AAMkAGVmMDEzMTM4LTZmYWUtNDdkNC1hMDZe',
      timezone: 'America/Chicago'
    )

    call = @api_client.calls.first
    assert_equal :get, call[:method]
    assert_includes call[:path], '/v1.0/me/events/'
    assert_includes call[:path], 'AAMkAGVmMDEzMTM4LTZmYWUtNDdkNC1hMDZe'
  end

  def test_get_event_passes_timezone_header
    @api_client.stub('events', sample_event_data)

    @calendar_api.get_event(
      event_id: 'event-123',
      timezone: 'America/New_York'
    )

    call = @api_client.calls.first
    assert_equal 'outlook.timezone="America/New_York"', call[:headers]['Prefer']
  end

  def test_get_event_returns_event_model
    @api_client.stub('events', sample_event_data)

    event = @calendar_api.get_event(
      event_id: 'event-123',
      timezone: 'America/Chicago'
    )

    assert_instance_of Teems::Models::Event, event
    assert_equal 'Weekly Standup', event.subject
  end

  def test_get_event_passes_select_param
    @api_client.stub('events', sample_event_data)

    @calendar_api.get_event(
      event_id: 'event-123',
      timezone: 'UTC'
    )

    call = @api_client.calls.first
    assert_includes call[:params]['$select'], 'subject'
    assert_includes call[:params]['$select'], 'body'
  end
end
