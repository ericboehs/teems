# frozen_string_literal: true

require 'uri'
require 'json'

module Teems
  module Services
    # Parses Microsoft Teams URLs to extract conversation and message identifiers
    class TeamsUrlParser
      # Parsed components from a Teams message URL
      Result = Struct.new(:conversation_id, :message_id, :context_type, :team_id)

      TEAMS_HOST = 'teams.microsoft.com'
      MESSAGE_PATH_PATTERN = %r{^/l/message/([^/]+)/(\d+)$}

      class << self
        def parse(url)
          uri = URI.parse(url)
          return nil unless teams_url?(uri)

          match_and_build(uri)
        rescue URI::InvalidURIError
          nil
        end

        def match_and_build(uri)
          match = uri.path.match(MESSAGE_PATH_PATTERN)
          match ? build_result(match, uri.query) : nil
        end

        def teams_url?(uri_or_string)
          uri = uri_or_string.is_a?(URI) ? uri_or_string : URI.parse(uri_or_string.to_s)
          uri.host == TEAMS_HOST
        rescue URI::InvalidURIError
          false
        end

        private

        def build_result(match, query_string)
          context = parse_context(query_string)
          Result.new(
            conversation_id: URI.decode_www_form_component(match[1]),
            message_id: match[2],
            context_type: context[:context_type],
            team_id: context[:team_id]
          )
        end

        def parse_context(query_string)
          return {} unless query_string

          parse_context_param(extract_context_param(query_string))
        rescue JSON::ParserError => err
          log_context_parse_error(err)
        end

        def parse_context_param(context_json)
          context_json ? parse_context_json(context_json) : {}
        end

        def log_context_parse_error(err)
          warn "teems: Could not parse Teams URL context: #{err.message}"
          {}
        end

        def extract_context_param(query_string)
          URI.decode_www_form(query_string).to_h['context']
        end

        def parse_context_json(json)
          context = JSON.parse(json)
          { context_type: context['contextType'], team_id: context['teamId'] }
        end
      end
    end
  end
end
