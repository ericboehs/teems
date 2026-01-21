# frozen_string_literal: true

module Teems
  module Api
    # API wrapper for Teams and channels endpoints using Microsoft Graph API
    class Channels < Client
      # Get list of teams the user has joined
      def list_teams
        get(:graph, '/v1.0/me/joinedTeams')
      end

      # Get channels for a specific team
      def list_channels(team_id:)
        encoded_team = URI.encode_www_form_component(team_id)
        get(:graph, "/v1.0/teams/#{encoded_team}/channels")
      end

      # Get details about a specific channel
      def get_channel(team_id:, channel_id:)
        encoded_team = URI.encode_www_form_component(team_id)
        encoded_channel = URI.encode_www_form_component(channel_id)
        get(:graph, "/v1.0/teams/#{encoded_team}/channels/#{encoded_channel}")
      end
    end
  end
end
