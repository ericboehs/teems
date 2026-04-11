# frozen_string_literal: true

module Teems
  module Commands
    # Resolves SharePoint embed page and extracts file metadata via Safari
    module TranscriptEmbed
      SP_ITEM_RE = %r{(https://[^/]+(?::\d+)?/.+?)/_api/v2\.\d+/drives/([^/]+)/items/([^/?]+)}
      FILE_INFO_JS = 'try { JSON.stringify(g_fileInfo) } catch(e) { "null" }'

      private

      def fetch_embed_url(sharing_url)
        debug("Resolving sharing link: #{sharing_url}")
        result = with_token_refresh { runner.meetings_api.share_preview(sharing_url) }
        result['getUrl']
      rescue ApiError => e
        debug("Share preview failed: #{e.message}")
        nil
      end

      def extract_file_info(safari, embed_url)
        debug("Navigating to embed page: #{embed_url}")
        safari.navigate(embed_url)
        safari.wait_for_load(timeout: 20)

        poll_file_info(safari)
      rescue Teems::Error => e
        debug("File info extraction failed: #{e.message}")
        nil
      end

      def poll_file_info(safari)
        15.times do |attempt|
          result = try_extract_file_info(safari)
          return result if result

          poll_sleep if attempt.positive?
        end
        nil
      end

      def poll_sleep = Kernel.sleep(1)

      def try_extract_file_info(safari)
        parse_file_info(safari.execute_js(FILE_INFO_JS).to_s)
      end

      def parse_file_info(raw)
        return nil if raw.empty?

        data = JSON.parse(raw)
        data.is_a?(Hash) ? build_file_info(data) : nil
      rescue JSON::ParserError
        nil
      end

      def build_file_info(data)
        build_from_sp_item_url(data['.spItemUrl']) || build_from_ids(data)
      end

      def build_from_sp_item_url(sp_url)
        return nil unless sp_url

        match = sp_url.match(SP_ITEM_RE)
        match ? { site_url: match[1], drive_id: match[2], item_id: match[3] } : nil
      end

      def build_from_ids(data)
        drive_id = data.dig('libraryId', 'siteId') || data['driveId']
        item_id = data['itemId'] || data['id']
        site_url = data['siteUrl'] || data.dig('libraryId', 'siteUrl')
        [drive_id, item_id, site_url].all? ? { drive_id: drive_id, item_id: item_id, site_url: site_url } : nil
      end
    end

    # Converts JSON transcript entries to WebVTT with speaker names
    class TranscriptFormatter
      def initialize(entries)
        @entries = entries
        @cue = nil
      end

      def to_vtt
        cues = @entries.each_with_index.map { |entry, idx| format_cue(entry, idx) }
        "WEBVTT\n\n#{cues.join}"
      end

      private

      def format_cue(entry, idx)
        @cue = entry
        "#{idx + 1}\n#{cue_timestamps}\n<v #{@cue['speakerDisplayName']}>#{@cue['text']}</v>\n\n"
      end

      def cue_timestamps
        "#{truncate_ts(@cue['startOffset'])} --> #{truncate_ts(@cue['endOffset'])}"
      end

      def truncate_ts(offset)
        offset ? offset.to_s[0, 12] : '00:00:00.000'
      end
    end

    # Downloads meeting transcripts via SharePoint API using Safari for auth
    module MeetingTranscript
      include TranscriptEmbed

      FETCH_TEMPLATE = "fetch('%s', {credentials: 'include', headers: {Accept: 'application/json'}})" \
                       '.then(r => r.json()).then(d => document.title = JSON.stringify(d))' \
                       '.catch(e => document.title = JSON.stringify({error: e.message}))'
      POLL_SENTINEL = 'TEEMS_LOADING'

      private

      def download_transcript(target, classified)
        sharing_url = target[:fileUrl] || first_recording_url(classified)
        return error('No recording sharing link found for transcript download') unless sharing_url

        safari = runner.safari_js_runner
        return error('Safari is required for transcript download (macOS only)') unless safari.available?

        execute_transcript_pipeline(safari, sharing_url)
      end

      def first_recording_url(classified)
        classified[:recordings].filter_map { |rec| rec[:url] }.first
      end

      def execute_transcript_pipeline(safari, sharing_url)
        info('Fetching transcript via SharePoint...')
        embed_url = fetch_embed_url(sharing_url)
        return error('Could not get embed URL from sharing link') unless embed_url

        @transcript_safari = safari
        @transcript_file_info = extract_file_info(safari, embed_url)
        return error('Could not extract file info from embed page') unless @transcript_file_info

        fetch_and_save_transcript
      end

      def fetch_and_save_transcript
        transcript = resolve_transcript
        return error('No transcripts found for this recording') unless transcript

        save_transcript(transcript)
      end

      def resolve_transcript
        url = build_transcripts_url
        debug("Fetching transcripts from: #{url}")
        fetch_transcript_list(@transcript_safari, url)
      end

      def build_transcripts_url
        "#{@transcript_file_info[:site_url]}/_api/v2.1" \
          "/drives/#{@transcript_file_info[:drive_id]}" \
          "/items/#{@transcript_file_info[:item_id]}/media/transcripts"
      end

      def fetch_transcript_list(safari, url)
        safari.execute_js("document.title = 'TEEMS_LOADING'")
        safari.execute_js(build_fetch_js(url))
        result = poll_title_result(safari)
        return nil unless result

        parse_transcript_response(result)
      rescue JSON::ParserError => e
        debug("Transcript JSON parse error: #{e.message}")
        nil
      end

      def poll_title_result(safari)
        10.times do |attempt|
          poll_sleep if attempt.positive?
          title = safari.execute_js('document.title').to_s
          return title if title_has_result?(title)
        end
        nil
      end

      def title_has_result?(title) = !title.empty? && title != POLL_SENTINEL

      def build_fetch_js(url) = format(FETCH_TEMPLATE, url.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'"))

      def parse_transcript_response(result)
        data = JSON.parse(result)
        return nil if data['error']

        entry = (data['value'] || [data]).first
        download_url = entry&.dig('temporaryDownloadUrl') || entry&.dig('downloadUrl')
        download_url ? { url: download_url, name: entry['name'] || 'transcript.vtt' } : nil
      end

      def save_transcript(transcript)
        dir = @options[:output_dir] || '.'
        FileUtils.mkdir_p(dir)
        path = File.join(dir, transcript[:name])

        info("Downloading transcript to #{path}...")
        vtt = fetch_and_convert_transcript(transcript[:url])
        return error('Failed to download transcript content') unless vtt

        File.write(path, vtt)
        success("Transcript saved to #{path}")
      rescue SystemCallError => e
        error("Could not save transcript: #{e.message}")
      end

      def fetch_and_convert_transcript(url)
        json_url = url.include?('?') ? "#{url}&format=json" : "#{url}?format=json"
        json_content = parse_transcript_json(fetch_transcript_content(json_url))
        json_content ? TranscriptFormatter.new(json_content['entries']).to_vtt : fetch_transcript_content(url)
      end

      def parse_transcript_json(raw)
        return nil unless raw

        data = JSON.parse(raw)
        data['entries'] ? data : nil
      rescue JSON::ParserError
        nil
      end

      def fetch_transcript_content(url)
        response = Net::HTTP.get_response(URI(url))
        return response.body if response.is_a?(Net::HTTPSuccess)

        debug("Transcript download failed: HTTP #{response.code}")
        nil
      rescue IOError, SystemCallError, SocketError, Timeout::Error, OpenSSL::SSL::SSLError => e
        debug("Transcript download error: #{e.message}")
        nil
      end
    end
  end
end
