# frozen_string_literal: true

module Teems
  module Commands
    # Format activity feed notifications for display
    module ActivityFormatting
      ACTIVITY_DESCRIPTIONS = {
        %w[msGraph privateMeetingCanceled] => 'canceled',
        %w[msGraph privateMeetingCreated] => 'invited you',
        %w[msGraph privateMeetingUpdated] => 'updated',
        %w[msGraph privateMeetingForwarded] => 'forwarded you',
        %w[msGraph delegateMeetingCreated] => 'invited you',
        %w[msGraph delegateMeetingUpdated] => 'updated',
        %w[mentionInChat person] => 'mentioned you',
        %w[mentionInChat everyone] => 'mentioned Everyone',
        %w[mention channel] => 'mentioned channel',
        %w[reactionInChat] => 'reacted'
      }.freeze

      MAX_PREVIEW = 120

      private

      def format_activity(activity, composetime)
        [format_activity_header(activity, composetime),
         format_preview(activity),
         format_meeting_time(activity),
         format_source(activity)].compact.join("\n")
      end

      def format_activity_header(activity, composetime)
        who = activity['sourceUserImDisplayName'] || 'Unknown'
        behalf = parse_behalf(activity)
        name = behalf ? "#{who} on behalf of #{behalf}" : who
        "#{output.blue(format_time(composetime))} #{output.bold(name)} #{describe_action(activity)}"
      end

      def format_preview(activity)
        text = activity['messagePreview'].to_s.strip.gsub(/[\r\n]+/, ' ')
        text.empty? ? nil : "  #{truncate(text)}"
      end

      def format_source(activity)
        topic = activity['sourceThreadTopic']
        return nil unless topic

        "  #{topic}"
      end

      def truncate(text)
        text.length > MAX_PREVIEW ? "#{text[0...MAX_PREVIEW]}..." : text
      end

      def describe_action(activity)
        type = activity['activityType']
        subtype = activity['activitySubtype']
        ACTIVITY_DESCRIPTIONS[[type, subtype]] || ACTIVITY_DESCRIPTIONS[[type]] || subtype || type
      end

      def format_meeting_time(activity)
        return nil unless activity['activityType'] == 'msGraph'

        location = activity.dig('activityContext', 'location')
        return nil unless location

        parsed = parse_meeting_range(location)
        return nil unless parsed

        "  #{format_time_range(*parsed)}"
      end

      def parse_meeting_range(location)
        start_match = location.match(%r{<StartDateTime>(.+?)</StartDateTime>})
        return nil unless start_match

        end_match = location.match(%r{<EndDateTime>(.+?)</EndDateTime>})
        start_time = Time.parse(start_match[1]).getlocal
        end_time = end_match ? Time.parse(end_match[1]).getlocal : nil
        [start_time, end_time]
      rescue ArgumentError
        nil
      end

      def format_time_range(start_time, end_time)
        start_str = start_time.strftime('%b %-d, %-I:%M %p')
        return start_str unless end_time

        end_fmt = (end_time - start_time) >= 86_400 ? '%b %-d, %-I:%M %p' : '%-I:%M %p'
        end_str = end_time.strftime(end_fmt)
        "#{start_str} - #{end_str}"
      end

      def parse_behalf(activity)
        params = activity.dig('activityContext', 'templateParameters')
        return nil unless params.is_a?(String)

        JSON.parse(params)['behalfOf']
      rescue JSON::ParserError
        nil
      end

      def format_time(composetime)
        return '' unless composetime

        Time.parse(composetime).getlocal.strftime('[%Y-%m-%d %H:%M]')
      rescue ArgumentError
        ''
      end
    end

    # Show activity feed (mentions, reactions, calendar notifications)
    class Activity < Base
      include ActivityFormatting

      NOTIFICATION_THREAD = '48:notifications'

      ACTIVITY_OPTIONS = {
        '--unread' => ->(opts, _pending) { opts[:unread] = true }
      }.freeze

      def initialize(args, runner:)
        @options = {}
        super
      end

      def execute
        result = validate_options
        return result if result

        auth_result = require_auth
        return auth_result if auth_result

        show_activity
      end

      protected

      def handle_option(arg, pending)
        handler = ACTIVITY_OPTIONS[arg]
        return super unless handler

        handler.call(@options, pending)
      end

      def help_text
        <<~HELP
          #{output.bold('teems activity')} - Show activity feed

          #{output.bold('USAGE:')}
            teems activity [options]

          #{output.bold('OPTIONS:')}
            -n, --limit N    Number of activities to show (default: 20)
            --unread         Show only unread activities
            -v, --verbose    Show debug output
            -q, --quiet      Suppress output
            --json           Output as JSON

          #{output.bold('EXAMPLES:')}
            teems activity              # Show recent activity
            teems activity --unread     # Show only unread
            teems activity -n 50        # Show 50 activities
        HELP
      end

      private

      def show_activity
        items = fetch_and_parse.sort_by { |item| item[:time] || '' }.reverse
        items = items.select { |item| item[:unread] } if @options[:unread]
        render_activities(items)
        0
      rescue ApiError => e
        error("Failed to fetch activity: #{e.message}")
        1
      end

      def fetch_and_parse
        response = with_token_refresh do
          runner.messages_api.chat_messages(chat_id: NOTIFICATION_THREAD, limit: @options[:limit])
        end
        (response['messages'] || []).filter_map { |msg| parse_activity(msg) }
      end

      def render_activities(items)
        if items.empty?
          puts 'No activity found'
        elsif @options[:json]
          output_json(items.map { |item| item.except(:raw_activity) })
        else
          display_activities(items)
        end
      end

      def parse_activity(msg)
        activity = msg.dig('properties', 'activity')
        return nil unless activity.is_a?(Hash)

        { type: activity['activityType'], subtype: activity['activitySubtype'],
          who: activity['sourceUserImDisplayName'], preview: activity['messagePreview'],
          where: activity['sourceThreadTopic'],
          time: activity['activityTimestamp'] || msg['composetime'],
          unread: msg.dig('properties', 'isread')&.to_s != 'true',
          raw_activity: activity }
      end

      def display_activities(items)
        items.each { |item| display_single_activity(item) }
      end

      def display_single_activity(item)
        unread_marker = item[:unread] ? output.bold('* ') : '  '
        formatted = format_activity(item[:raw_activity], item[:time])
        formatted.lines.each_with_index do |line, idx|
          puts idx.zero? ? "#{unread_marker}#{line.chomp}" : "  #{line.chomp}"
        end
        puts
      end
    end
  end
end
