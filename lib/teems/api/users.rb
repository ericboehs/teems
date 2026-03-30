# frozen_string_literal: true

require_relative 'users_presence'

module Teems
  module Api
    # API wrapper for Microsoft Graph user endpoints
    class Users < Client
      include UsersPresence

      USER_SELECT = %w[
        id displayName mail userPrincipalName jobTitle
        department officeLocation businessPhones mobilePhone
      ].join(',').freeze

      def me
        response = get('/v1.0/me', params: { '$select' => USER_SELECT })
        Models::UserProfile.from_api(response)
      end

      def get_user(user_id)
        encoded_id = URI.encode_www_form_component(user_id)
        response = get("/v1.0/users/#{encoded_id}", params: { '$select' => USER_SELECT })
        Models::UserProfile.from_api(response)
      end

      def search(query)
        sanitized = query.gsub(/["\\]/, '')
        headers = { 'ConsistencyLevel' => 'eventual' }
        response = get('/v1.0/users', params: search_params(sanitized), headers: headers)
        (response['value'] || []).map { |data| Models::UserProfile.from_api(data) }
      end

      def search_params(sanitized)
        { '$search' => "\"displayName:#{sanitized}\" OR \"mail:#{sanitized}\"",
          '$select' => USER_SELECT, '$count' => 'true', '$top' => 10 }
      end

      def manager(user_id)
        encoded_id = URI.encode_www_form_component(user_id)
        response = get("/v1.0/users/#{encoded_id}/manager", params: { '$select' => USER_SELECT })
        Models::UserProfile.from_api(response)
      end

      def manager_me
        response = get('/v1.0/me/manager', params: { '$select' => USER_SELECT })
        Models::UserProfile.from_api(response)
      end

      def direct_reports(user_id)
        encoded_id = URI.encode_www_form_component(user_id)
        response = get("/v1.0/users/#{encoded_id}/directReports", params: { '$select' => USER_SELECT })
        (response['value'] || []).map { |data| Models::UserProfile.from_api(data) }
      end

      def direct_reports_me
        response = get('/v1.0/me/directReports', params: { '$select' => USER_SELECT })
        (response['value'] || []).map { |data| Models::UserProfile.from_api(data) }
      end

      def presence(user_id)
        encoded_id = URI.encode_www_form_component(user_id)
        get("/v1.0/users/#{encoded_id}/presence")
      end

      def teams_presence(mri)
        post_to(:presence, '/v1/presence/getpresence/', body: [{ mri: mri }])
      end

      def schedule(email, time_range:)
        response = post('/v1.0/me/calendar/getSchedule', body: schedule_body(email, time_range))
        response.dig('value', 0)
      end

      private

      def schedule_body(email, time_range)
        tz = time_range[:timezone]
        { schedules: [email],
          startTime: { dateTime: time_range[:start_time], timeZone: tz },
          endTime: { dateTime: time_range[:end_time], timeZone: tz },
          availabilityViewInterval: 15 }
      end
    end
  end
end
