# frozen_string_literal: true

module Teems
  module Models
    # Represents a Teams channel within a team
    Channel = Data.define(:id, :name, :team_id, :team_name, :description, :membership_type) do
      def self.from_api(data, team_id: nil, team_name: nil)
        new(
          id: data['id'],
          name: data['displayName'],
          team_id: team_id,
          team_name: team_name,
          description: data['description'],
          membership_type: data['membershipType']
        )
      end

      def display_name
        team_name ? "#{team_name} / #{name}" : name
      end

      def private?
        membership_type == 'private'
      end

      def to_s
        "##{name}"
      end
    end
  end
end
