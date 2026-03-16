# frozen_string_literal: true

module Teems
  module Commands
    # List joined teams and their channels
    class Channels < Base
      def initialize(args, runner:)
        @options = {}
        super
      end

      def execute
        result = validate_options
        return result if result

        auth_result = require_auth
        return auth_result if auth_result

        list_teams_and_channels
      end

      protected

      def help_text
        <<~HELP
          #{output.bold('teems channels')} - List teams and channels

          #{output.bold('USAGE:')}
            teems channels [options]

          #{output.bold('OPTIONS:')}
            -v, --verbose    Show debug output
            -q, --quiet      Suppress output
            --json           Output as JSON

          #{output.bold('EXAMPLES:')}
            teems channels           # List all teams and channels
            teems channels --json    # Output as JSON
        HELP
      end

      private

      def list_teams_and_channels
        display_teams_list(fetch_teams)
      rescue ApiError => err
        teams_fetch_error(err)
      end

      def display_teams_list(teams)
        teams.empty? ? puts('No teams found') : render_teams(teams)
        0
      end

      def teams_fetch_error(err)
        error("Failed to fetch teams: #{err.message}")
        1
      end

      def fetch_teams
        response = runner.channels_api.list_teams
        response['value'] || []
      end

      def render_teams(teams)
        if @options[:json]
          output_json(build_json_output(teams))
        else
          display_teams(teams)
        end
      end

      def display_teams(teams)
        api = runner.channels_api
        teams.each do |team_data|
          puts output.bold(team_data['displayName'])
          display_team_channels(api, team_data)
          puts
        end
      end

      def display_team_channels(api, team_data)
        channels = api.list_channels(team_id: team_data['id'])['value'] || []
        channels.each { |channel_data| display_channel(channel_data, team_data) }
      rescue ApiError => err
        puts "  #{output.red('Error:')} #{err.message}"
      end

      def display_channel(channel_data, team_data)
        channel = Models::Channel.from_api(channel_data, team_id: team_data['id'],
                                                         team_name: team_data['displayName'])
        puts "  #{channel_prefix(channel)} #{channel.name} (#{channel.id})"
      end

      def channel_prefix(channel) = channel.private? ? output.yellow('🔒') : '  '

      def build_json_output(teams)
        api = runner.channels_api
        teams.map { |team| team_to_hash(api, team) }
      end

      def team_to_hash(api, team_data)
        team_id = team_data['id']
        channels_response = api.list_channels(team_id: team_id)
        {
          id: team_id,
          name: team_data['displayName'],
          channels: (channels_response['value'] || []).map do |channel|
            { id: channel['id'], name: channel['displayName'], membership_type: channel['membershipType'] }
          end
        }
      end
    end
  end
end
