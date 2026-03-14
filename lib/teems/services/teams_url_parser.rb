# frozen_string_literal: true

require 'uri'
require 'json'

module Teems
  module Services
    # Parses Microsoft Teams URLs to extract conversation and message identifiers
    class TeamsUrlParser
      Result = Struct.new(:conversation_id, :message_id, :context_type, :team_id)

      TEAMS_HOST = 'teams.microsoft.com'
      MESSAGE_PATH_PATTERN = %r{^/l/message/([^/]+)/(\d+)$}

      class << self
        def parse(url)
          uri = URI.parse(url)
          return nil unless teams_url?(uri)

          match = uri.path.match(MESSAGE_PATH_PATTERN)
          return nil unless match

          conversation_id = URI.decode_www_form_component(match[1])
          message_id = match[2]
          context = parse_context(uri.query)

          Result.new(
            conversation_id: conversation_id,
            message_id: message_id,
            context_type: context[:context_type],
            team_id: context[:team_id]
          )
        rescue URI::InvalidURIError
          nil
        end

        def teams_url?(uri_or_string)
          uri = uri_or_string.is_a?(URI) ? uri_or_string : URI.parse(uri_or_string.to_s)
          uri.host == TEAMS_HOST
        rescue URI::InvalidURIError
          false
        end

        private

        def parse_context(query_string)
          return {} unless query_string

          params = URI.decode_www_form(query_string).to_h
          context_json = params['context']
          return {} unless context_json

          context = JSON.parse(context_json)
          {
            context_type: context['contextType'],
            team_id: context['teamId']
          }
        rescue JSON::ParserError => e
          warn "teems: Could not parse Teams URL context: #{e.message}"
          {}
        end
      end
    end
  end
end
