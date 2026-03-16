# frozen_string_literal: true

module Teems
  module Models
    PENDING_RESPONSES = [nil, 'none'].freeze

    # Represents a calendar event from Microsoft Graph API
    Event = Data.define(
      :id,
      :subject,
      :start_time,
      :end_time,
      :location,
      :is_all_day,
      :organizer,
      :attendees,
      :body_preview,
      :online_meeting_url,
      :show_as,
      :importance,
      :is_cancelled,
      :response_status,
      :sensitivity
    ) do
      extend Parsing

      def self.from_api(data)
        new(**event_attrs(data))
      end

      def self.event_attrs(data)
        core_attrs(data).merge(detail_attrs(data))
      end

      def self.core_attrs(data)
        {
          id: data['id'],
          subject: data['subject'] || '(No subject)',
          start_time: parse_time(data.dig('start', 'dateTime')),
          end_time: parse_time(data.dig('end', 'dateTime')),
          location: data.dig('location', 'displayName'),
          is_all_day: data['isAllDay'] || false,
          organizer: parse_organizer(data['organizer']),
          attendees: parse_attendees(data['attendees'])
        }
      end

      def self.detail_attrs(data)
        {
          body_preview: data['bodyPreview'] || strip_html(data.dig('body', 'content')),
          online_meeting_url: data.dig('onlineMeeting', 'joinUrl'),
          show_as: data['showAs'],
          importance: data['importance'],
          is_cancelled: data['isCancelled'] || false,
          response_status: data.dig('responseStatus', 'response'),
          sensitivity: data['sensitivity']
        }
      end

      def self.parse_organizer(organizer_data)
        return nil unless organizer_data

        email_data = organizer_data['emailAddress'] || {}
        { name: email_data['name'], email: email_data['address'] }
      end

      def self.parse_attendees(attendees_data)
        return [] unless attendees_data.is_a?(Array)

        attendees_data.map do |att_data|
          email_data = att_data['emailAddress'] || {}
          {
            name: email_data['name'],
            email: email_data['address'],
            type: att_data['type'],
            response: att_data.dig('status', 'response')
          }
        end
      end

      def all_day?
        is_all_day
      end

      def cancelled?
        is_cancelled
      end

      def time_range_display
        return 'ALL DAY' if all_day?
        return '' unless start_time && end_time

        "#{start_time.strftime('%H:%M')}-#{end_time.strftime('%H:%M')}"
      end

      def date_display
        if all_day?
          "#{start_time&.strftime('%Y-%m-%d')} (all day)"
        elsif start_time && end_time
          "#{start_time.strftime('%Y-%m-%d %H:%M')}-#{end_time.strftime('%H:%M')}"
        end
      end

      def create_summary_lines
        lines = []
        lines << date_display if date_display
        lines << "Location: #{location}" if location && !location.empty?
        lines << "Teams link: #{online_meeting_url}" if online_meeting_url
        lines
      end

      def required_attendees = attendees.select { |att| att[:type] == 'required' }
      def optional_attendees = attendees.select { |att| att[:type] == 'optional' }
      def accepted_attendees = attendees.select { |att| att[:response] == 'accepted' }
      def declined_attendees = attendees.select { |att| att[:response] == 'declined' }
      def tentative_attendees = attendees.select { |att| att[:response] == 'tentativelyAccepted' }
      def pending_attendees = attendees.select { |att| PENDING_RESPONSES.include?(att[:response]) }
    end
  end
end
