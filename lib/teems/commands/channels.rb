# frozen_string_literal: true

module Teems
  module Commands
    # List joined teams and their channels
    class Channels < Base
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
        api = runner.channels_api
        teams_response = api.list_teams

        teams = teams_response['value'] || []

        if teams.empty?
          puts 'No teams found'
          return 0
        end

        if @options[:json]
          output_json(build_json_output(api, teams))
        else
          display_teams(api, teams)
        end

        0
      rescue ApiError => e
        error("Failed to fetch teams: #{e.message}")
        1
      end

      def display_teams(api, teams)
        teams.each do |team_data|
          team_name = team_data['displayName']
          team_id = team_data['id']

          puts output.bold(team_name)

          begin
            channels_response = api.list_channels(team_id: team_id)
            channels = channels_response['value'] || []

            channels.each do |channel_data|
              channel = Models::Channel.from_api(channel_data, team_id: team_id, team_name: team_name)
              prefix = channel.private? ? output.yellow('🔒') : '  '
              puts "  #{prefix} #{channel.name} (#{channel.id})"
            end
          rescue ApiError => e
            puts "  #{output.red('Error:')} #{e.message}"
          end

          puts
        end
      end

      def build_json_output(api, teams)
        teams.map do |team_data|
          team_id = team_data['id']
          channels_response = api.list_channels(team_id: team_id)

          {
            id: team_id,
            name: team_data['displayName'],
            channels: (channels_response['value'] || []).map do |c|
              { id: c['id'], name: c['displayName'], membership_type: c['membershipType'] }
            end
          }
        end
      end
    end
  end
end
