# frozen_string_literal: true

require_relative 'meeting_transcript'
require_relative 'meeting_recording'

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
                         Combine with --transcript to embed subtitles
        --audio          Also save a separate audio file (M4A) — ideal for transcription
        --no-video       Skip the video file; with --audio produces audio-only output
        --chat           Show meeting chat messages
        --date YYYY-MM-DD  Pick a single occurrence of a recurring meeting by date
                           (filters call events, recordings, and transcripts)
        -o, --output-dir Directory for downloads (default: current directory)
        -v, --verbose    Show debug output
        -q, --quiet      Suppress output
        --json           Output as JSON
        -h, --help       Show this help

      EXAMPLES:
        teems meeting 19:meeting_abc123@thread.v2
        teems meeting 19:meeting_abc123@thread.v2 --chat
        teems meeting 19:meeting_abc123@thread.v2 --transcript
        teems meeting 19:meeting_abc123@thread.v2 --audio -o ~/Downloads          # video + audio
        teems meeting 19:meeting_abc123@thread.v2 --audio --no-video -o ~/Downloads  # audio only
        teems meeting 19:meeting_abc123@thread.v2 --recording -o ~/Downloads
        teems meeting 19:meeting_abc123@thread.v2 --recording --transcript -o ~/Downloads
        teems meeting "<recurring-url>" --date 2026-05-04 --audio --no-video --transcript
        teems meeting AAMkAGVmMDEz...        # By calendar event ID
    HELP

    # Option definitions for the meeting command
    module MeetingOptionDefs
      ALL = {
        '--transcript' => ->(opts, _args) { opts[:transcript] = true },
        '--recording' => ->(opts, _args) { opts[:recording] = true },
        '--audio' => ->(opts, _args) { opts[:audio] = true },
        '--no-video' => ->(opts, _args) { opts[:no_video] = true },
        '--chat' => ->(opts, _args) { opts[:chat] = true },
        '--date' => ->(opts, args) { opts[:date] = args.shift },
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
      PART_RE = %r{<part\s[^>]*identity="([^"]+)"[^>]*>.*?<name>([^<]*)</name>
                   .*?<displayName>([^<]*)</displayName>.*?<duration>([^<]*)</duration>}xm
      CALLID_RE = %r{<callId>([^<]+)</callId>}
      INSTANCE_ICAL_RE = %r{<instanceDetails>.*?<iCalUid>([^<]+)</iCalUid>}m

      private

      def classify_meeting_messages(messages_data)
        result = empty_classification
        messages_data.each { |msg| classify_single_message(msg, result) }
        result[:call_events].reject! { |evt| evt[:participants].empty? }
        result
      end

      def empty_classification
        { call_events: [], recordings: [], transcripts: [], chat_messages: [] }
      end

      def classify_single_message(msg, result)
        case msg['messagetype']
        when 'Event/Call' then result[:call_events] << parse_call_event(msg)
        when 'RichText/Media_CallRecording' then result[:recordings] << parse_recording(msg)
        when 'RichText/Media_CallTranscript' then result[:transcripts] << parse_transcript(msg)
        else result[:chat_messages] << msg unless system_activity?(msg)
        end
      end

      def system_activity?(msg)
        type = msg['messagetype'].to_s
        type.start_with?('ThreadActivity/') || type == 'Control/Typing'
      end

      def parse_call_event(msg)
        content = msg['content'].to_s
        parts = extract_partlist(content)
        build_msg_hash(msg).merge(
          call_id: content.match(CALLID_RE)&.captures&.first,
          ical_uid: content.match(INSTANCE_ICAL_RE)&.captures&.first,
          duration: parts.first&.dig(:duration),
          participants: parts
        )
      end

      def extract_partlist(content)
        content.scan(PART_RE).filter_map do |identity, _name, display, duration|
          build_participant(identity, display, duration) unless identity.start_with?('28:')
        end
      end

      def build_participant(identity, display_name, duration)
        name = decode_xml_entities(display_name)
        { identity: identity, name: name, duration: duration }
      end

      def decode_xml_entities(text)
        text.gsub('&amp;', '&').gsub('&apos;', "'").gsub('&lt;', '<').gsub('&gt;', '>').gsub('&quot;', '"')
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
      rescue ApiError => e
        debug("Could not resolve organizer: #{e.message}")
        nil
      end

      def display_call_events(call_events)
        return puts('  No call events found') if call_events.empty?

        call_events.each { |event| display_single_call_event(event) }
      end

      def display_single_call_event(event)
        puts
        header = "  #{output.bold('Call Event')} #{format_time_str(event[:time])}"
        puts "#{header} (#{format_call_duration(event[:duration])})"
        display_participants(event[:participants])
      end

      def display_participants(parts)
        return if parts.empty?

        puts "  Participants (#{parts.length}):"
        parts.each { |entry| puts format_participant_line(entry[:name], entry[:identity]) }
      end

      def format_participant_line(name, identity)
        resolved = needs_resolution?(name) ? resolve_participant_name(identity) : name
        "    #{resolved}"
      end

      def needs_resolution?(name)
        name.empty? || name.match?(/\A\d*:/)
      end

      def resolve_participant_name(identity)
        uuid = identity.match(/8:orgid:(.+)/)&.captures&.first
        return identity unless uuid

        @name_cache ||= {}
        @name_cache[uuid] ||= fetch_user_name(uuid, identity)
      end

      def fetch_user_name(uuid, identity)
        profile = with_token_refresh { runner.users_api.get_user(uuid) }
        profile.display_name
      rescue ApiError => e
        debug("Could not resolve user #{uuid}: #{e.message}")
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

    # A single page of meeting chat messages with the link to the page before it.
    MeetingPage = Data.define(:messages, :backward_link) do
      def empty? = messages.empty?
      def last? = backward_link.to_s.empty?

      def oldest_local_date
        times = messages.filter_map { |msg| MeetingPage.safe_parse_time(msg['composetime']) }
        times.min&.localtime&.to_date
      end

      def covers_through?(target_date)
        oldest = oldest_local_date
        oldest && oldest < target_date
      end

      def terminal_for?(target_date)
        empty? || last? || covers_through?(target_date)
      end

      def self.safe_parse_time(time_str)
        return nil unless time_str

        Time.parse(time_str)
      rescue ArgumentError, TypeError
        nil
      end
    end

    # Pages backward through chat messages until we've fetched past the target date.
    # The ng.msg endpoint caps pages at 200 messages and exposes no messageType filter,
    # so for recurring meetings we paginate via _metadata.backwardLink.
    module MeetingPagination
      PAGE_SIZE = 200
      MAX_PAGES = 50
      PAGE_DELAY_SECONDS = 0.5

      private

      def paginate_meeting_messages(thread_id, target_date)
        @page_count = 0
        @pagination_link = nil
        @paginated_messages = []
        run_pagination_loop(thread_id, target_date)
        @paginated_messages
      end

      def run_pagination_loop(thread_id, target_date)
        loop do
          page = fetch_meeting_page(thread_id, @pagination_link)
          return unless page

          merge_meeting_page(page)
          break if pagination_done?(page, target_date)

          @pagination_link = page.backward_link
          page_pause
        end
      end

      def page_pause
        sleep(PAGE_DELAY_SECONDS)
      end

      def fetch_meeting_page(thread_id, backward_link)
        response = with_token_refresh do
          runner.messages_api.chat_messages_page(
            chat_id: thread_id, limit: PAGE_SIZE, backward_link: backward_link
          )
        end
        MeetingPage.new(messages: response['messages'] || response['value'] || [],
                        backward_link: response.dig('_metadata', 'backwardLink'))
      rescue ApiError => e
        error("Failed to fetch meeting messages: #{e.message}")
        nil
      end

      def merge_meeting_page(page)
        page_messages = page.messages
        @paginated_messages.concat(page_messages)
        @page_count += 1
        debug("Page #{@page_count}: #{page_messages.length} message(s) " \
              "(oldest #{page.oldest_local_date}); total #{@paginated_messages.length}")
      end

      def pagination_done?(page, target_date)
        reached_pagination_cap? || page.terminal_for?(target_date)
      end

      def reached_pagination_cap?
        return false if @page_count < MAX_PAGES

        debug("Reached max pages (#{MAX_PAGES}); stopping pagination")
        true
      end
    end

    # Filters classified call events, recordings, and transcripts to a single date.
    # Used to select one occurrence of a recurring meeting series.
    module MeetingDateFilter
      DATE_KEYS = %i[call_events recordings transcripts].freeze

      private

      def filter_classified_by_date(classified, date_str)
        target_date = parse_date_option(date_str)
        return nil unless target_date

        DATE_KEYS.each_with_object(classified.dup) do |key, acc|
          acc[key] = items_on_date(acc[key], target_date)
        end
      end

      def items_on_date(items, target_date)
        items.select { |item| item_on_date?(item, target_date) }
      end

      def parse_date_option(date_str)
        Date.parse(date_str)
      rescue ArgumentError, TypeError
        error("Invalid --date value: #{date_str.inspect} (expected YYYY-MM-DD)")
        nil
      end

      def item_on_date?(item, target_date)
        time_str = item[:time]
        return false unless time_str

        Time.parse(time_str).localtime.to_date == target_date
      rescue ArgumentError, TypeError
        false
      end
    end

    # Filters classified messages to a specific call instance by callId
    module MeetingCallFilter
      private

      def classify_and_filter(messages_data, target)
        classified = classify_meeting_messages(messages_data)
        filter_classified(classified, target)
      end

      def filter_classified(classified, target)
        ical = target[:iCalUid]
        return filter_by_ical(classified, ical) if ical

        call_id = target[:callId]
        call_id ? filter_by_call_id(classified, call_id) : classified
      end

      def filter_by_ical(classified, ical_uid)
        events = classified[:call_events].select { |evt| evt[:ical_uid] == ical_uid }
        return classified if events.empty?

        classified.merge(call_events: events)
      end

      def filter_by_call_id(classified, call_id)
        events = classified[:call_events].select { |evt| evt[:call_id] == call_id }
        return classified if events.empty?

        classified.merge(call_events: events)
      end
    end

    # View meeting details, chat, transcripts, and recordings
    class Meeting < Base
      include MeetingTargetResolver
      include MeetingMessageParser
      include MeetingDisplay
      include MeetingChatDisplay
      include MeetingCallFilter
      include MeetingDateFilter
      include MeetingPagination
      include MeetingTranscript
      include MeetingRecording

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
        classified = apply_date_option(classified)
        return 1 unless classified

        dispatch_mode(target, classified)
      end

      def apply_date_option(classified)
        date_str = @options[:date]
        return classified unless date_str

        filtered = filter_classified_by_date(classified, date_str)
        return nil unless filtered
        return filtered unless date_filter_empty?(filtered)

        error("No meeting activity found for #{date_str}")
        nil
      end

      def date_filter_empty?(classified)
        MeetingDateFilter::DATE_KEYS.all? { |key| classified[key].empty? }
      end

      def fetch_meeting_messages(thread_id)
        debug("Fetching messages for thread: #{thread_id}")
        target_date = pagination_target_date
        return paginate_meeting_messages(thread_id, target_date) if target_date

        single_page_meeting_messages(thread_id)
      end

      def pagination_target_date
        date_str = @options[:date]
        return nil unless date_str

        Date.parse(date_str)
      rescue ArgumentError, TypeError
        nil
      end

      def single_page_meeting_messages(thread_id)
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
          return 0
        end
        media = media_output_spec
        return download_media_with_transcript(target, classified, media) if media
        return download_transcript(target, classified) || 0 if @options[:transcript]

        display_meeting_summary(target, classified)
        0
      end

      def media_output_spec
        audio, recording, no_video = @options.values_at(:audio, :recording, :no_video)
        return nil unless audio || recording || no_video

        { video: (recording || audio) && !no_video, audio: audio || no_video }
      end

      def download_media_with_transcript(target, classified, media)
        if @options[:transcript]
          result = download_transcript(target, classified)
          warn("Transcript download failed; proceeding with #{media[:video] ? 'recording' : 'audio'}") if result == 1
        end
        download_recording(target, classified, media: media) || 0
      end
    end
  end
end
