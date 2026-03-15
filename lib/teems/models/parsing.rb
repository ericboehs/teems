# frozen_string_literal: true

module Teems
  module Models
    # Shared parsing helpers for API response data
    module Parsing
      module_function

      def strip_html(html)
        return nil unless html

        require 'cgi'
        CGI.unescapeHTML(html.gsub(/<[^>]+>/, ' ')).gsub('&nbsp;', ' ').gsub(/\s+/, ' ').strip
      end

      def parse_time(time_str)
        return nil unless time_str

        Time.parse(time_str)
      rescue ArgumentError
        nil
      end

      def parse_files_json(files_json)
        return [] unless files_json

        JSON.parse(files_json)
      rescue JSON::ParserError
        []
      end
    end
  end
end
