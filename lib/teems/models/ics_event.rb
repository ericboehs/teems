# frozen_string_literal: true

module Teems
  module Models
    # A calendarView event as `teems cal ics` exports it. Built from Graph data requested
    # with Prefer: outlook.timezone="UTC", so timed events carry UTC times and all-day
    # events carry their (floating) dates.
    IcsEvent = Data.define(:uid, :subject, :starts, :ends, :all_day, :location, :organizer, :attendees,
                           :body, :join_url, :status) do
      def self.from_api(data)
        new(uid: data['iCalUId'] || data['id'], subject: data['subject'].to_s, **time_attrs(data),
            location: data.dig('location', 'displayName').to_s, organizer: Event.parse_organizer(data['organizer']),
            attendees: Event.parse_attendees(data['attendees']), body: data['body'] || {},
            join_url: data.dig('onlineMeeting', 'joinUrl').to_s, status: status_attrs(data))
      end

      # Dates for all-day events (Graph sends their midnights without a zone), UTC Times otherwise
      def self.time_attrs(data)
        all_day = data['isAllDay'] || false
        parser = all_day ? :graph_date : :graph_utc
        { starts: send(parser, data['start']), ends: send(parser, data['end']), all_day: all_day }
      end

      def self.graph_date(value) = graph_stamp(value) { |stamp| Date.parse(stamp) }

      def self.graph_utc(value) = graph_stamp(value) { |stamp| Time.parse("#{stamp.delete_suffix('Z')}Z").utc }

      def self.graph_stamp(value)
        stamp = Hash(value)['dateTime']
        stamp && yield(stamp)
      rescue ArgumentError
        nil
      end

      def self.status_attrs(data) = { cancelled: data['isCancelled'] || false, show_as: data['showAs'].to_s }

      def dated? = [starts, ends].all?

      def cancelled? = status[:cancelled]

      def free? = status[:show_as] == 'free'

      # Plain-text body, links listed at the end
      def description
        content = body['content'].to_s
        body['contentType'] == 'html' ? Formatters::HtmlText.convert(content).to_s : content.strip
      end

      # True when one of addresses organizes the event or has accepted it, so it is already
      # on that address's own calendar. An invitation alone does not count.
      def involves?(addresses)
        return false if addresses.empty?

        accepted = attendees.select { |attendee| attendee[:response] == 'accepted' }
        [Hash(organizer)[:email], *accepted.map { |attendee| attendee[:email] }]
          .any? { |email| addresses.include?(email.to_s.downcase) }
      end
    end
  end
end
