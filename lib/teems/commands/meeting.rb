# frozen_string_literal: true

module Teems
  module Commands
    MEETING_HELP = <<~HELP
      teems meeting - View meeting details, chat, transcripts, and recordings

      USAGE:
        teems meeting <target> [options]

      ARGUMENTS:
        target           Thread ID (19:meeting_...@thread.v2), calendar event ID,
                         or Teams meeting URL

      OPTIONS:
        --transcript     Download meeting transcript (WebVTT)
        --recording      Download meeting recording (MP4, requires ffmpeg)
        --chat           Show meeting chat messages
        -o, --output-dir Directory for downloads (default: current directory)
        -v, --verbose    Show debug output
        -q, --quiet      Suppress output
        --json           Output as JSON
        -h, --help       Show this help

      EXAMPLES:
        teems meeting 19:meeting_abc123@thread.v2
        teems meeting 19:meeting_abc123@thread.v2 --chat
        teems meeting 19:meeting_abc123@thread.v2 --transcript
        teems meeting 19:meeting_abc123@thread.v2 --recording -o ~/Downloads
        teems meeting AAMkAGVmMDEz...        # By calendar event ID
    HELP

    # Option definitions for the meeting command
    module MeetingOptionDefs
      ALL = {
        '--transcript' => ->(opts, _args) { opts[:transcript] = true },
        '--recording' => ->(opts, _args) { opts[:recording] = true },
        '--chat' => ->(opts, _args) { opts[:chat] = true },
        '-o' => ->(opts, args) { opts[:output_dir] = args.shift },
        '--output-dir' => ->(opts, args) { opts[:output_dir] = args.shift }
      }.freeze
    end

    # Resolves meeting targets: thread ID, event ID, or Teams URL
    module MeetingTargetResolver
      MEETING_THREAD_PREFIX = '19:meeting_'
      EVENT_ID_PREFIX = 'AAMk'
      JOIN_URL_PATTERN = %r{/l/meetup-join/([^/?]+)}
      CHAT_URL_PATTERN = %r{/l/chat/([^/?]+)}
      RECAP_PARAMS = %w[callId organizerId tenantId iCalUid driveId driveItemId fileUrl].freeze

      private

      def resolve_meeting_target
        raw = positional_args.first
        return missing_target_error unless raw

        resolve_raw_target(raw)
      end

      def resolve_raw_target(raw)
        if raw.start_with?('https://')
          resolve_url_target(raw)
        elsif raw.start_with?(EVENT_ID_PREFIX)
          resolve_event_target(raw)
        else
          { thread_id: raw }
        end
      end

      def resolve_url_target(url)
        thread_id = extract_meeting_thread(url)
        return build_url_target(url, thread_id) if thread_id

        parsed = Services::TeamsUrlParser.parse(url)
        return { thread_id: parsed.conversation_id } if parsed

        error('Could not parse meeting URL')
        nil
      end

      def build_url_target(url, thread_id)
        target = { thread_id: thread_id }
        query = URI.parse(url).query
        return target unless query

        params = URI.decode_www_form(query).to_h
        RECAP_PARAMS.each { |key| (val = params[key]) && target[key.to_sym] = val }
        target
      rescue URI::InvalidURIError
        target
      end

      def extract_meeting_thread(url)
        extract_thread_from_path(url) || extract_thread_from_query(url)
      end

      def extract_thread_from_path(url)
        [JOIN_URL_PATTERN, CHAT_URL_PATTERN].each do |pattern|
          match = url.match(pattern)
          next unless match

          decoded = URI.decode_www_form_component(match[1])
          return decoded if decoded.start_with?(MEETING_THREAD_PREFIX)
        end
        nil
      end

      def extract_thread_from_query(url)
        query = URI.parse(url).query
        return unless query

        thread_param = URI.decode_www_form(query).to_h['threadId']
        return unless thread_param

        decoded = URI.decode_www_form_component(thread_param)
        decoded if decoded.start_with?(MEETING_THREAD_PREFIX)
      rescue URI::InvalidURIError
        nil
      end

      def resolve_event_target(event_id)
        debug("Resolving event ID: #{event_id}")
        join_url = fetch_event_join_url(event_id)
        return nil unless join_url

        thread_id = extract_meeting_thread(join_url)
        return error('Could not extract thread ID from meeting link') && nil unless thread_id

        { thread_id: thread_id, event_id: event_id }
      end

      def fetch_event_join_url(event_id)
        event = with_token_refresh { runner.calendar_api.get_event(event_id: event_id, timezone: 'UTC') }
        event.online_meeting_url || (error('Event has no Teams meeting link') && nil)
      rescue ApiError => e
        error("Failed to fetch event: #{e.message}")
        nil
      end

      def missing_target_error
        error('Target required. Specify a thread ID, event ID, or Teams meeting URL.')
        puts
        puts 'Usage: teems meeting <target> [options]'
        nil
      end
    end

    # Parses meeting chat messages to extract call events, recordings, transcripts
    module MeetingMessageParser
      CALL_EVENT_TYPE = 'Event/Call'
      RECORDING_TYPE = 'RichText/Media_CallRecording'
      TRANSCRIPT_TYPE = 'RichText/Media_CallTranscript'

      PARTLIST_RE = %r{<part identity="([^"]+)"[^>]*>.*?<name>([^<]*)</name>.*?<duration>([^<]*)</duration>}m

      private

      def classify_meeting_messages(messages_data)
        result = empty_classification
        messages_data.each { |msg| classify_single_message(msg, result) }
        result
      end

      def empty_classification
        { call_events: [], recordings: [], transcripts: [], chat_messages: [] }
      end

      def classify_single_message(msg, result)
        case msg['messagetype']
        when CALL_EVENT_TYPE then result[:call_events] << parse_call_event(msg)
        when RECORDING_TYPE then result[:recordings] << parse_recording(msg)
        when TRANSCRIPT_TYPE then result[:transcripts] << parse_transcript(msg)
        else result[:chat_messages] << msg unless system_activity?(msg)
        end
      end

      def system_activity?(msg)
        type = msg['messagetype'].to_s
        type.start_with?('ThreadActivity/') || type == 'Control/Typing'
      end

      def parse_call_event(msg)
        build_msg_hash(msg).merge(participants: extract_partlist(msg['content'].to_s))
      end

      def extract_partlist(content)
        content.scan(PARTLIST_RE).map do |identity, name, duration|
          { identity: identity, name: name, duration: duration }
        end
      end

      def parse_recording(msg)
        content = msg['content'].to_s
        build_msg_hash(msg).merge(url: extract_href(content), call_id: extract_call_id(content))
      end

      def parse_transcript(msg)
        props_raw = msg.dig('properties', 'cards') || msg.dig('properties', 'callTranscript')
        build_msg_hash(msg).merge(properties: safe_parse_json(props_raw))
      end

      def build_msg_hash(msg)
        { id: msg['id'], time: msg['composetime'], content: msg['content'].to_s }
      end

      def extract_href(html)
        match = html.match(/href="([^"]+)"/)
        match ? match[1] : nil
      end

      def extract_call_id(content)
        match = content.match(/callId=([a-f0-9-]+)/i)
        match ? match[1] : nil
      end

      def safe_parse_json(raw)
        return nil unless raw.is_a?(String) && !raw.empty?

        JSON.parse(raw)
      rescue JSON::ParserError
        nil
      end
    end

    # Displays meeting summary information
    module MeetingDisplay
      private

      def display_meeting_summary(target, classified)
        puts output.bold('Meeting Details')
        puts "  Thread: #{target[:thread_id]}"
        display_organizer(target[:organizerId])
        display_call_events(classified[:call_events])
        display_assets_summary(classified)
      end

      def display_organizer(organizer_id)
        return unless organizer_id

        profile = with_token_refresh { runner.users_api.get_user(organizer_id) }
        puts "  Organizer: #{profile.display_name}"
      rescue ApiError
        nil
      end

      def display_call_events(call_events)
        return puts('  No call events found') if call_events.empty?

        call_events.each { |event| display_single_call_event(event) }
      end

      def display_single_call_event(event)
        puts
        puts "  #{output.bold('Call Event')} #{format_time_str(event[:time])}"
        display_participants(event[:participants])
      end

      def display_participants(parts)
        return if parts.empty?

        puts "  Participants (#{parts.length}):"
        parts.each { |entry| puts format_participant_line(entry[:name], entry[:identity], entry[:duration]) }
      end

      def format_participant_line(name, identity, duration)
        resolved = needs_resolution?(name) ? resolve_participant_name(identity) : name
        "    #{resolved} (#{format_call_duration(duration)})"
      end

      def needs_resolution?(name)
        name.empty? || name.start_with?('8:')
      end

      def resolve_participant_name(identity)
        uuid = extract_uuid(identity)
        return identity unless uuid

        @name_cache ||= {}
        @name_cache[uuid] ||= fetch_user_name(uuid, identity)
      end

      def extract_uuid(identity)
        identity.match(/8:orgid:(.+)/)&.captures&.first
      end

      def fetch_user_name(uuid, identity)
        profile = with_token_refresh { runner.users_api.get_user(uuid) }
        profile.display_name
      rescue ApiError
        identity
      end

      def format_call_duration(seconds_str)
        total = seconds_str.to_i
        return '< 1 min' if total < 60

        mins = total / 60
        "#{mins} min"
      end

      def display_assets_summary(classified)
        lines = asset_lines(classified[:recordings], 'Recordings') +
                asset_lines(classified[:transcripts], 'Transcripts')
        return if lines.empty?

        puts
        puts "  #{output.bold('Assets')}:"
        lines.each { |line| puts line }
      end

      def asset_lines(items, label)
        items.empty? ? [] : ["    #{label}: #{items.length}"]
      end

      def format_time_str(time_str)
        return '' unless time_str

        parsed = Time.parse(time_str)
        output.blue("[#{parsed.strftime('%Y-%m-%d %H:%M')}]")
      rescue ArgumentError
        ''
      end
    end

    # Displays meeting chat messages (non-system messages)
    module MeetingChatDisplay
      private

      def display_meeting_chat(chat_messages)
        messages = chat_messages.map { |msg_data| Models::Message.from_api(msg_data) }
                                .reject(&:system_message?)
                                .reverse
        return puts('No chat messages found') if messages.empty?

        formatter = runner.message_formatter
        messages.each { |msg| puts formatter.format(msg) }
      end
    end

    # Filters classified messages to a specific call instance by callId
    module MeetingCallFilter
      private

      def classify_and_filter(messages_data, target)
        @classified = classify_meeting_messages(messages_data)
        call_id = target[:callId]
        call_id ? apply_call_id_filter(call_id) : @classified
      end

      def apply_call_id_filter(call_id)
        matched = @classified[:recordings].select { |rec| rec[:call_id] == call_id }
        return @classified if matched.empty?

        boundary = compute_time_boundary(matched)
        @classified.merge(recordings: matched, call_events: select_events_near(boundary))
      end

      def compute_time_boundary(recordings)
        earliest = recordings.filter_map { |rec| parse_iso_time(rec[:time]) }.min
        earliest ? earliest - 7200 : nil
      end

      def select_events_near(boundary)
        events = @classified[:call_events]
        boundary ? events.select { |evt| event_after_boundary?(evt, boundary) } : events
      end

      def event_after_boundary?(evt, boundary)
        time = parse_iso_time(evt[:time])
        time && time >= boundary
      end

      def parse_iso_time(str)
        Time.parse(str)
      rescue ArgumentError, TypeError
        nil
      end
    end

    # View meeting details, chat, transcripts, and recordings
    class Meeting < Base
      include MeetingTargetResolver
      include MeetingMessageParser
      include MeetingDisplay
      include MeetingChatDisplay
      include MeetingCallFilter

      def initialize(args, runner:)
        @options = {}
        super
      end

      def execute
        result = validate_options
        return result if result

        auth_result = require_auth
        return auth_result if auth_result

        target = resolve_meeting_target
        target ? process_meeting(target) : 1
      end

      protected

      MEETING_OPTIONS = MeetingOptionDefs::ALL

      def handle_option(arg, pending)
        handler = MEETING_OPTIONS[arg]
        return super unless handler

        handler.call(@options, pending)
      end

      def help_text = MEETING_HELP

      private

      def process_meeting(target)
        messages_data = fetch_meeting_messages(target[:thread_id])
        return 1 unless messages_data

        classified = classify_and_filter(messages_data, target)
        dispatch_mode(target, classified)
      end

      def fetch_meeting_messages(thread_id)
        debug("Fetching messages for thread: #{thread_id}")
        response = with_token_refresh do
          runner.messages_api.chat_messages(chat_id: thread_id, limit: @options[:limit])
        end
        response['messages'] || response['posts'] || response['value'] || []
      rescue ApiError => e
        error("Failed to fetch meeting messages: #{e.message}")
        nil
      end

      def dispatch_mode(target, classified)
        if @options[:chat]
          display_meeting_chat(classified[:chat_messages])
        elsif @options[:transcript]
          download_transcript(classified)
        elsif @options[:recording]
          download_recording(classified)
        else
          display_meeting_summary(target, classified)
        end
        0
      end

      def download_transcript(classified)
        recordings = classified[:recordings]
        if recordings.empty?
          error('No recordings found — transcript requires a recording with sharing link')
          return
        end

        info('Transcript download requires Safari automation (Phase 2)')
        info("Found #{recordings.length} recording(s) with sharing links")
      end

      def download_recording(classified)
        recordings = classified[:recordings]
        if recordings.empty?
          error('No recordings found for this meeting')
          return
        end

        info('Recording download requires DASH manifest parsing (Phase 3)')
        info("Found #{recordings.length} recording(s)")
      end
    end
  end
end
