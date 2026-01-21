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
        get(:graph, "/v1.0/teams/#{team_id}/channels")
      end

      # Get details about a specific channel
      def get_channel(team_id:, channel_id:)
        get(:graph, "/v1.0/teams/#{team_id}/channels/#{channel_id}")
      end
    end
  end
end
