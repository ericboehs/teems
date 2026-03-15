# frozen_string_literal: true

module Teems
  module Models
    # Represents a message in Teams
    # Handles both Graph API and Teams internal API response formats
    Message = Data.define(
      :id, :sender_id, :sender_name, :content, :created_at,
      :message_type, :reply_to_id, :reactions, :attachments, :importance
    ) do
      extend Parsing

      def self.from_api(data)
        if data['message'] then from_teams_internal_api(data)
        elsif data['imdisplayname'] || data['messagetype'] then from_ng_msg_api(data)
        else from_graph_api(data)
        end
      end

      def self.from_ng_msg_api(data)
        new(**ng_msg_attrs(data))
      end

      def self.ng_msg_attrs(data)
        props = data['properties'] || {}
        {
          id: data['id'], sender_id: data['from'],
          sender_name: data['imdisplayname'] || data['fromDisplayNameInToken'] || 'Unknown',
          content: strip_html(data['content'] || ''),
          created_at: parse_time(data['composetime'] || data['originalarrivaltime']),
          message_type: data['messagetype'],
          **ng_msg_extras(data, props)
        }
      end

      def self.ng_msg_extras(data, props)
        {
          reply_to_id: data['rootMessageId'] == data['id'] ? nil : data['rootMessageId'],
          reactions: parse_ng_msg_reactions(props['emotions']),
          attachments: parse_files_json(props['files']),
          importance: nil
        }
      end

      def self.parse_ng_msg_reactions(emotions)
        return [] unless emotions.is_a?(Array)

        emotions.map { |emotion| { type: emotion['key'], count: emotion['users']&.length || 1 } }
      end

      def self.from_teams_internal_api(data)
        msg = data['message']
        new(
          id: data['id'], sender_id: msg['from'],
          sender_name: msg['imDisplayName'] || msg['fromDisplayNameInToken'] || 'Unknown',
          content: strip_html(msg['content'] || ''),
          created_at: parse_time(msg['composeTime'] || data['latestMessageTime']),
          message_type: msg['type'], reply_to_id: nil, reactions: [],
          attachments: parse_files_json(msg.dig('properties', 'files')),
          importance: nil
        )
      end

      def self.from_graph_api(data)
        new(**graph_attrs(data))
      end

      def self.graph_attrs(data)
        {
          id: data['id'],
          sender_id: data.dig('from', 'user', 'id') || data.dig('from', 'application', 'id'),
          sender_name: extract_sender_name(data),
          content: strip_html(data.dig('body', 'content') || ''),
          created_at: parse_time(data['createdDateTime']),
          **graph_extras(data)
        }
      end

      def self.graph_extras(data)
        {
          message_type: data['messageType'], reply_to_id: data['replyToId'],
          reactions: parse_reactions(data['reactions']),
          attachments: data['attachments'] || [],
          importance: data['importance']
        }
      end

      def self.extract_sender_name(data)
        data.dig('from', 'user', 'displayName') ||
          data.dig('from', 'application', 'displayName') || 'Unknown'
      end

      def self.parse_reactions(reactions_data)
        return [] unless reactions_data.is_a?(Array)

        reactions_data.map { |reaction| { type: reaction['reactionType'], count: reaction['user']&.length || 1 } }
      end

      def timestamp = created_at
      def reply? = !reply_to_id.nil?
      def important? = %w[urgent high].include?(importance)

      def system_message?
        return false if message_type.nil?
        return false if %w[Message message Text].include?(message_type)
        return false if message_type.start_with?('RichText')

        true
      end

      def to_s
        "[#{created_at&.strftime('%H:%M')}] #{sender_name}: #{content}"
      end
    end
  end
end
