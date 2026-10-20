# frozen_string_literal: true

require 'test_helper'

class CalendarFeedApiTest < Minitest::Test
  FROM = Time.utc(2026, 10, 13, 12)
  TO = Time.utc(2026, 12, 19, 12)

  def setup
    @api_client = Teems::TestHelpers::MockApiClient.new
    @calendar_api = Teems::Api::Calendar.new(@api_client, mock_account)
  end

  def graph_event(uid)
    { 'iCalUId' => uid, 'subject' => uid, 'isAllDay' => false,
      'start' => { 'dateTime' => '2026-10-21T14:00:00.0000000' },
      'end' => { 'dateTime' => '2026-10-21T15:00:00.0000000' } }
  end

  def fetch_one
    @api_client.stub('calendarView', { 'value' => [graph_event('a')] })
    @events = @calendar_api.feed_events(from: FROM, to: TO)
    @api_client.calls.first
  end

  def test_returns_ics_events_with_utc_times_and_immutable_ids
    call = fetch_one

    assert_equal ['a'], @events.map(&:uid)
    assert_instance_of Teems::Models::IcsEvent, @events.first
    assert_equal '/v1.0/me/calendarView', call[:path]
    assert_equal 'outlook.timezone="UTC", IdType="ImmutableId"', call[:headers]['Prefer']
  end

  def test_requests_window_and_feed_fields
    params = fetch_one[:params]

    assert_equal '2026-10-13T12:00:00Z', params['startDateTime']
    assert_equal '2026-12-19T12:00:00Z', params['endDateTime']
    assert_includes params['$select'], 'iCalUId'
    assert_includes params['$select'], 'body'
  end

  def test_follows_next_links_with_the_same_headers
    next_link = 'https://graph.microsoft.com/v1.0/me/calendarView?$skip=250'
    @api_client.stub('/v1.0/me/calendarView', { 'value' => [graph_event('a')], '@odata.nextLink' => next_link })
    @api_client.stub(next_link, { 'value' => [graph_event('b')] })

    events = @calendar_api.feed_events(from: FROM, to: TO)

    assert_equal %w[a b], events.map(&:uid)
    assert_equal 'outlook.timezone="UTC", IdType="ImmutableId"', @api_client.calls.last[:headers]['Prefer']
  end

  def test_empty_page
    @api_client.stub('calendarView', {})

    assert_empty @calendar_api.feed_events(from: FROM, to: TO)
  end
end
