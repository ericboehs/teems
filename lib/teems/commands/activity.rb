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

      START_DATETIME_PATTERN = %r{<StartDateTime>(.+?)</StartDateTime>}
      END_DATETIME_PATTERN = %r{<EndDateTime>(.+?)</EndDateTime>}
      MAX_PREVIEW = 120

      private

      def format_activity(activity, composetime)
        [format_activity_header(activity, composetime),
         format_preview(activity),
         format_meeting_time(activity),
         format_activity_source(activity)].compact.join("\n")
      end

      def format_activity_header(activity, composetime)
        who = activity['sourceUserImDisplayName'] || 'Unknown'
        behalf = parse_behalf(activity)
        name = behalf ? "#{who} on behalf of #{behalf}" : who
        time_str = Formatters::FormatUtils.format_time(composetime)
        "#{output.blue(time_str)} #{output.bold(name)} #{describe_action(activity)}"
      end

      def format_preview(activity)
        text = activity['messagePreview'].to_s.strip.gsub(/[\r\n]+/, ' ')
        text.empty? ? nil : "  #{Formatters::FormatUtils.truncate(text, MAX_PREVIEW)}"
      end

      def format_activity_source(activity)
        topic = activity['sourceThreadTopic']
        topic ? "  #{output.gray(topic)}" : nil
      end

      def describe_action(activity)
        desc = resolve_activity_description(activity['activityType'], activity['activitySubtype'])
        output.yellow(desc)
      end

      def resolve_activity_description(type, subtype)
        ACTIVITY_DESCRIPTIONS[[type, subtype]] || ACTIVITY_DESCRIPTIONS[[type]] || subtype || type
      end

      def format_meeting_time(activity)
        return nil unless activity['activityType'] == 'msGraph'

        location = activity.dig('activityContext', 'location')
        parsed = location && parse_meeting_range(location)
        "  #{format_time_range(*parsed)}" if parsed
      end

      def parse_meeting_range(location)
        start_match, end_match = extract_datetime_matches(location)
        return nil unless start_match

        Formatters::FormatUtils.build_time_range(start_match[1], end_match)
      rescue ArgumentError
        nil
      end

      def extract_datetime_matches(text)
        [text.match(START_DATETIME_PATTERN),
         text.match(END_DATETIME_PATTERN)]
      end

      def format_time_range(start_time, end_time)
        start_str = start_time.strftime('%b %-d, %-I:%M %p')
        return start_str unless end_time

        "#{start_str} - #{Formatters::FormatUtils.format_end_time(start_time, end_time)}"
      end

      def parse_behalf(activity)
        params = activity.dig('activityContext', 'templateParameters')
        return nil unless params.is_a?(String) && output

        JSON.parse(params)['behalfOf']
      rescue JSON::ParserError
        nil
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
        render_activities(filtered_activities)
        0
      rescue ApiError => e
        activity_fetch_error(e)
      end

      def filtered_activities
        items = sorted_activities
        @options[:unread] ? items.select { |item| item[:unread] } : items
      end

      def sorted_activities = fetch_and_parse.sort_by { |item| item[:time] || '' }.reverse

      def activity_fetch_error(err)
        error("Failed to fetch activity: #{err.message}")
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
        marker = item[:unread] ? output.bold('* ') : '  '
        print_activity_lines(marker, format_activity(item[:raw_activity], item[:time]))
      end

      def print_activity_lines(marker, text)
        text.lines.each_with_index do |line, idx|
          trimmed = line.chomp
          puts idx.zero? ? "#{marker}#{trimmed}" : "  #{trimmed}"
        end
        puts
      end
    end
  end
end
