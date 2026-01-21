# frozen_string_literal: true

module Teems
  module Models
    # Represents a chat (1:1, group, or meeting chat)
    Chat = Data.define(:id, :topic, :chat_type, :created_at, :last_updated) do
      def self.from_api(data)
        # Handle both Graph API format and ng.msg format
        if data['threadProperties']
          from_ngmsg(data)
        else
          from_graph(data)
        end
      end

      def self.from_graph(data)
        new(
          id: data['id'],
          topic: data['topic'],
          chat_type: data['chatType'],
          created_at: parse_time(data['createdDateTime']),
          last_updated: parse_time(data['lastUpdatedDateTime'])
        )
      end

      def self.from_ngmsg(data)
        thread_props = data['threadProperties'] || {}
        props = data['properties'] || {}
        new(
          id: data['id'],
          topic: thread_props['topic'],
          chat_type: normalize_chat_type(thread_props['threadType']),
          created_at: parse_time(thread_props['createdat']),
          last_updated: parse_time(props['lastimreceivedtime'])
        )
      end

      def self.normalize_chat_type(type)
        case type&.downcase
        when 'chat' then 'group'
        when 'meeting' then 'meeting'
        when 'topic' then 'oneOnOne'
        else type
        end
      end

      def self.parse_time(time_str)
        return nil unless time_str

        Time.parse(time_str)
      rescue ArgumentError
        nil
      end

      def display_name
        (topic.nil? || topic.empty?) ? chat_type_label : topic
      end

      def chat_type_label
        case chat_type
        when 'oneOnOne' then '1:1 Chat'
        when 'group' then 'Group Chat'
        when 'meeting' then 'Meeting Chat'
        else chat_type
        end
      end

      def one_on_one?
        chat_type == 'oneOnOne'
      end

      def group?
        chat_type == 'group'
      end

      def meeting?
        chat_type == 'meeting'
      end

      def to_s
        display_name
      end
    end
  end
end
