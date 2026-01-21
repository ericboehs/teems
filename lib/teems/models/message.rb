# frozen_string_literal: true

module Teems
  module Models
    # Represents a message in Teams
    # Handles both Graph API and Teams internal API response formats
    Message = Data.define(
      :id,
      :sender_id,
      :sender_name,
      :content,
      :created_at,
      :message_type,
      :reply_to_id,
      :reactions,
      :attachments,
      :importance
    ) do
      def self.from_api(data)
        # Handle Teams internal API format (has 'message' nested object)
        if data['message']
          from_teams_internal_api(data)
        elsif data['imdisplayname'] || data['messagetype']
          # ng.msg API format (direct fields, lowercase keys)
          from_ng_msg_api(data)
        else
          from_graph_api(data)
        end
      end

      def self.from_ng_msg_api(data)
        new(
          id: data['id'],
          sender_id: data['from'],
          sender_name: data['imdisplayname'] || data['fromDisplayNameInToken'] || 'Unknown',
          content: strip_html(data['content'] || ''),
          created_at: parse_time(data['composetime'] || data['originalarrivaltime']),
          message_type: data['messagetype'],
          reply_to_id: data['rootMessageId'] != data['id'] ? data['rootMessageId'] : nil,
          reactions: parse_ng_msg_reactions(data.dig('properties', 'emotions')),
          attachments: parse_files(data.dig('properties', 'files')),
          importance: nil
        )
      end

      def self.parse_ng_msg_reactions(emotions)
        return [] unless emotions.is_a?(Array)

        emotions.map do |e|
          { type: e['key'], count: e['users']&.length || 1 }
        end
      end

      def self.from_teams_internal_api(data)
        msg = data['message']
        new(
          id: data['id'],
          sender_id: msg['from'],
          sender_name: msg['imDisplayName'] || msg['fromDisplayNameInToken'] || 'Unknown',
          content: strip_html(msg['content'] || ''),
          created_at: parse_time(msg['composeTime'] || data['latestMessageTime']),
          message_type: msg['type'],
          reply_to_id: nil,
          reactions: [],
          attachments: parse_files(msg.dig('properties', 'files')),
          importance: nil
        )
      end

      def self.from_graph_api(data)
        new(
          id: data['id'],
          sender_id: extract_sender_id(data),
          sender_name: extract_sender_name(data),
          content: strip_html(data.dig('body', 'content') || ''),
          created_at: parse_time(data['createdDateTime']),
          message_type: data['messageType'],
          reply_to_id: data['replyToId'],
          reactions: parse_reactions(data['reactions']),
          attachments: data['attachments'] || [],
          importance: data['importance']
        )
      end

      def self.extract_sender_id(data)
        data.dig('from', 'user', 'id') ||
          data.dig('from', 'application', 'id')
      end

      def self.extract_sender_name(data)
        data.dig('from', 'user', 'displayName') ||
          data.dig('from', 'application', 'displayName') ||
          'Unknown'
      end

      def self.strip_html(html)
        # Simple HTML stripping - remove tags but keep text, decode entities
        require 'cgi'
        text = html.gsub(/<[^>]+>/, ' ')
        text = CGI.unescapeHTML(text)
        text = text.gsub('&nbsp;', ' ') # CGI doesn't handle nbsp
        text.gsub(/\s+/, ' ').strip
      end

      def self.parse_time(time_str)
        return nil unless time_str

        Time.parse(time_str)
      rescue ArgumentError
        nil
      end

      def self.parse_reactions(reactions_data)
        return [] unless reactions_data.is_a?(Array)

        reactions_data.map do |r|
          { type: r['reactionType'], count: r['user']&.length || 1 }
        end
      end

      def self.parse_files(files_json)
        return [] unless files_json

        begin
          JSON.parse(files_json)
        rescue JSON::ParserError
          []
        end
      end

      def timestamp
        created_at
      end

      def reply?
        !reply_to_id.nil?
      end

      def system_message?
        # Regular message types: Message, message, RichText/Html, Text
        return false if message_type.nil?
        return false if %w[Message message Text].include?(message_type)
        return false if message_type.start_with?('RichText')

        # Everything else is a system message (ThreadActivity/*, etc.)
        true
      end

      def important?
        importance == 'urgent' || importance == 'high'
      end

      def to_s
        "[#{created_at&.strftime('%H:%M')}] #{sender_name}: #{content}"
      end
    end
  end
end
