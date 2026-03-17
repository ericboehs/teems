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

      def parse_mentions(mentions_json)
        raw = normalize_mentions(mentions_json)
        return [] unless raw

        raw.select { |mention| mention['mri'] }
           .group_by { |mention| mention['mri'] }
           .each_value.filter_map { |entries| mention_display_name(entries) }
      end

      def normalize_mentions(data)
        return nil unless data

        result = data.is_a?(String) ? JSON.parse(data) : data
        result.is_a?(Array) ? result : nil
      rescue JSON::ParserError
        nil
      end

      def mention_display_name(entries)
        name = entries.filter_map { |entry| entry['displayName'] }.join(' ')
        name unless name.empty?
      end
    end
  end
end
