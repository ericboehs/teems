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

      FEED_SELECT = %w[
        id iCalUId subject start end location isAllDay organizer attendees
        body onlineMeeting showAs isCancelled
      ].join(',').freeze

      # List events in a date range using CalendarView
      def list_events(time_range:, top: 50)
        params = calendar_view_params(time_range[:start_dt], time_range[:end_dt], top)
        headers = timezone_header(time_range[:timezone])
        paginate_events('/v1.0/me/calendarView', params: params, headers: headers)
      end

      # Every event (each occurrence of a series on its own) between two Times, for `teems cal ics`.
      # Times come back in UTC and IDs are immutable, so UIDs stay stable between exports.
      def feed_events(from:, to:)
        params = { 'startDateTime' => from.utc.iso8601, 'endDateTime' => to.utc.iso8601,
                   '$select' => FEED_SELECT, '$orderby' => 'start/dateTime', '$top' => 250 }
        headers = { 'Prefer' => 'outlook.timezone="UTC", IdType="ImmutableId"' }
        collect_pages(get('/v1.0/me/calendarView', params: params, headers: headers), headers)
          .map { |data| Models::IcsEvent.from_api(data) }
      end

      # Get a single event by ID with full details
      def get_event(event_id:, timezone:)
        encoded_id = URI.encode_www_form_component(event_id)
        params = { '$select' => EVENT_DETAIL_SELECT }
        headers = timezone_header(timezone)

        response = get("/v1.0/me/events/#{encoded_id}", params: params, headers: headers)
        Models::Event.from_api(response)
      end

      # Create a new calendar event
      def create_event(body)
        response = post('/v1.0/me/events', body: body)
        Models::Event.from_api(response)
      end

      # Delete an event
      def delete_event(event_id:)
        encoded_id = URI.encode_www_form_component(event_id)
        delete("/v1.0/me/events/#{encoded_id}")
      end

      # RSVP to an event (accept, decline, or tentatively accept)
      def rsvp_event(event_id:, action:, **opts)
        encoded_id = URI.encode_www_form_component(event_id)
        api_action = action == 'tentative' ? 'tentativelyAccept' : action
        post("/v1.0/me/events/#{encoded_id}/#{api_action}", body: rsvp_body(opts))
      end

      private

      def rsvp_body(opts)
        comment = opts[:comment]
        body = { sendResponse: opts.fetch(:notify, :send) == :send }
        body[:comment] = comment if comment
        body
      end

      def calendar_view_params(start_dt, end_dt, top)
        { 'startDateTime' => start_dt, 'endDateTime' => end_dt,
          '$select' => CALENDAR_VIEW_SELECT, '$orderby' => 'start/dateTime', '$top' => top }
      end

      def paginate_events(path, params:, headers:)
        collect_pages(get(path, params: params, headers: headers), headers).map { |data| Models::Event.from_api(data) }
      end

      def collect_pages(response, headers)
        items = []
        loop do
          items.concat(response['value'] || [])
          next_link = response['@odata.nextLink']
          break items unless next_link

          response = get(next_link, headers: headers)
        end
      end

      def timezone_header(timezone)
        { 'Prefer' => "outlook.timezone=\"#{timezone}\"" }
      end
    end
  end
end
