# frozen_string_literal: true

module Teems
  module Models
    # Represents a user in Teams
    User = Data.define(:id, :display_name, :email, :user_principal_name) do
      def self.from_api(data)
        new(
          id: data['id'],
          display_name: data['displayName'],
          email: data['mail'] || data['email'],
          user_principal_name: data['userPrincipalName']
        )
      end

      def best_name
        [display_name, email, user_principal_name, id].find { |value| value && !value.empty? }
      end

      def to_s
        best_name
      end
    end
  end
end
