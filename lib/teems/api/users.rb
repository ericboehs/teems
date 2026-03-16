# frozen_string_literal: true

module Teems
  module Api
    # API wrapper for Microsoft Graph user endpoints
    class Users < Client
      USER_SELECT = %w[
        id displayName mail userPrincipalName jobTitle
        department officeLocation businessPhones mobilePhone
      ].join(',').freeze

      def me
        response = get(:graph, '/v1.0/me', params: { '$select' => USER_SELECT })
        Models::UserProfile.from_api(response)
      end

      def get_user(user_id)
        encoded_id = URI.encode_www_form_component(user_id)
        response = get(:graph, "/v1.0/users/#{encoded_id}", params: { '$select' => USER_SELECT })
        Models::UserProfile.from_api(response)
      end

      def search(query)
        sanitized = query.gsub(/["\\]/, '')
        params = { '$search' => "\"displayName:#{sanitized}\" OR \"mail:#{sanitized}\"",
                   '$select' => USER_SELECT, '$count' => 'true', '$top' => 10 }
        headers = { 'ConsistencyLevel' => 'eventual' }
        response = get(:graph, '/v1.0/users', params: params, headers: headers)
        (response['value'] || []).map { |data| Models::UserProfile.from_api(data) }
      end

      def manager(user_id)
        encoded_id = URI.encode_www_form_component(user_id)
        response = get(:graph, "/v1.0/users/#{encoded_id}/manager", params: { '$select' => USER_SELECT })
        Models::UserProfile.from_api(response)
      end

      def manager_me
        response = get(:graph, '/v1.0/me/manager', params: { '$select' => USER_SELECT })
        Models::UserProfile.from_api(response)
      end

      def direct_reports(user_id)
        encoded_id = URI.encode_www_form_component(user_id)
        response = get(:graph, "/v1.0/users/#{encoded_id}/directReports", params: { '$select' => USER_SELECT })
        (response['value'] || []).map { |data| Models::UserProfile.from_api(data) }
      end

      def direct_reports_me
        response = get(:graph, '/v1.0/me/directReports', params: { '$select' => USER_SELECT })
        (response['value'] || []).map { |data| Models::UserProfile.from_api(data) }
      end

      def presence(user_id)
        encoded_id = URI.encode_www_form_component(user_id)
        get(:graph, "/v1.0/users/#{encoded_id}/presence")
      end

      def teams_presence(mri)
        post(:presence, '/v1/presence/getpresence/', body: [{ mri: mri }])
      end

      def schedule(email, start_time:, end_time:, timezone:)
        body = { schedules: [email],
                 startTime: { dateTime: start_time, timeZone: timezone },
                 endTime: { dateTime: end_time, timeZone: timezone },
                 availabilityViewInterval: 15 }
        response = post(:graph, '/v1.0/me/calendar/getSchedule', body: body)
        response.dig('value', 0)
      end
    end
  end
end
