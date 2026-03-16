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
      def create_event(subject:, start_dt:, end_dt:, timezone:, **opts)
        core = { subject: subject,
                 start: { dateTime: start_dt, timeZone: timezone },
                 end: { dateTime: end_dt, timeZone: timezone },
                 isAllDay: opts[:all_day] || false }
        response = post(:graph, '/v1.0/me/events', body: apply_event_options(core, opts))
        Models::Event.from_api(response)
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

      def apply_event_options(body, opts)
        body[:location] = { displayName: opts[:location] } if opts[:location]
        body[:body] = { contentType: 'text', content: opts[:body_text] } if opts[:body_text]
        body[:attendees] = build_attendees(opts[:attendees]) if opts[:attendees]
        add_online_meeting(body) if opts[:online_meeting]
        body
      end

      def add_online_meeting(body)
        body[:isOnlineMeeting] = true
        body[:onlineMeetingProvider] = 'teamsForBusiness'
      end

      def build_attendees(emails)
        emails.map do |email|
          { emailAddress: { address: email }, type: 'required' }
        end
      end

      def calendar_view_params(start_dt, end_dt, top)
        { 'startDateTime' => start_dt, 'endDateTime' => end_dt,
          '$select' => CALENDAR_VIEW_SELECT, '$orderby' => 'start/dateTime', '$top' => top }
      end

      def paginate_events(path, params:, headers:)
        events = []
        response = get(:graph, path, params: params, headers: headers)
        events.concat(parse_events(response))
        while (next_link = response['@odata.nextLink'])
          response = get(:graph, next_link, headers: headers)
          events.concat(parse_events(response))
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
