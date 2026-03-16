# frozen_string_literal: true

module Teems
  module Api
    # API wrapper for Microsoft Graph Calendar endpoints
    class Calendar < Client
      CALENDAR_VIEW_SELECT = %w[
        id subject start end location isAllDay organizer attendees
        bodyPreview onlineMeeting showAs importance isCancelled
        responseStatus sensitivity
      ].join(',').freeze

      EVENT_DETAIL_SELECT = %w[
        id subject start end location isAllDay organizer attendees
        body onlineMeeting showAs importance isCancelled
        responseStatus sensitivity
      ].join(',').freeze

      # List events in a date range using CalendarView
      def list_events(start_dt:, end_dt:, timezone:, top: 50)
        params = calendar_view_params(start_dt, end_dt, top)
        headers = timezone_header(timezone)
        paginate_events('/v1.0/me/calendarView', params: params, headers: headers)
      end

      # Get a single event by ID with full details
      def get_event(event_id:, timezone:)
        encoded_id = URI.encode_www_form_component(event_id)
        params = { '$select' => EVENT_DETAIL_SELECT }
        headers = timezone_header(timezone)

        response = get(:graph, "/v1.0/me/events/#{encoded_id}", params: params, headers: headers)
        Models::Event.from_api(response)
      end

      # Create a new calendar event
      def create_event(body)
        response = post(:graph, '/v1.0/me/events', body: body)
        Models::Event.from_api(response)
      end

      # Delete an event
      def delete_event(event_id:)
        encoded_id = URI.encode_www_form_component(event_id)
        delete(:graph, "/v1.0/me/events/#{encoded_id}")
      end

      # RSVP to an event (accept, decline, or tentatively accept)
      def rsvp_event(event_id:, action:, comment: nil, notify: :send)
        encoded_id = URI.encode_www_form_component(event_id)
        api_action = action == 'tentative' ? 'tentativelyAccept' : action
        body = { sendResponse: notify == :send }
        body[:comment] = comment if comment

        post(:graph, "/v1.0/me/events/#{encoded_id}/#{api_action}", body: body)
      end

      private

      def calendar_view_params(start_dt, end_dt, top)
        { 'startDateTime' => start_dt, 'endDateTime' => end_dt,
          '$select' => CALENDAR_VIEW_SELECT, '$orderby' => 'start/dateTime', '$top' => top }
      end

      def paginate_events(path, params:, headers:)
        events = []
        response = get(:graph, path, params: params, headers: headers)
        loop do
          events.concat(parse_events(response))
          next_link = response['@odata.nextLink']
          break unless next_link

          response = get(:graph, next_link, headers: headers)
        end
        events
      end

      def timezone_header(timezone)
        { 'Prefer' => "outlook.timezone=\"#{timezone}\"" }
      end

      def parse_events(response)
        (response['value'] || []).map { |data| Models::Event.from_api(data) }
      end
    end
  end
end
