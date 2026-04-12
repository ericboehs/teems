# frozen_string_literal: true

module Teems
  module Commands
    # Parses SharePoint embed page HTML to extract file metadata
    module EmbedPageParser
      SP_ITEM_RE = %r{(https://[^/]+(?::\d+)?/.+?)/_api/v2\.\d+/drives/([^/]+)/items/([^/?]+)}
      FILE_INFO_RE = /g_fileInfo\s*=\s*(\{.*?\});/m

      private

      def fetch_embed_url(sharing_url)
        debug("Resolving sharing link: #{sharing_url}")
        result = with_token_refresh { runner.meetings_api.share_preview(sharing_url) }
        result['getUrl']
      rescue ApiError => e
        debug("Share preview failed: #{e.message}")
        nil
      end

      def fetch_and_parse_embed(embed_url)
        debug("Fetching embed page: #{embed_url}")
        html = fetch_embed_page(embed_url)
        return nil unless html

        parse_embed_file_info(html)
      end

      def fetch_embed_page(url)
        response = Net::HTTP.get_response(URI(url))
        response.is_a?(Net::HTTPSuccess) ? response.body : nil
      rescue IOError, SystemCallError, SocketError, Timeout::Error => e
        debug("Embed page fetch error: #{e.message}")
        nil
      end

      def parse_embed_file_info(html)
        match = html.match(FILE_INFO_RE)
        return nil unless match

        data = JSON.parse(match[1])
        build_file_info(data)
      rescue JSON::ParserError => e
        debug("Embed page JSON parse error: #{e.message}")
        nil
      end

      def build_file_info(data)
        extras = extract_extras(data)
        extract_ids(data)&.merge(extras)
      end

      def extract_extras(data)
        { drive_token: data['.driveAccessTokenV21'],
          transform_url: data['.transformUrl'] || data['transformUrl'],
          name: data['name'] }
      end

      def extract_ids(data)
        build_from_sp_item_url(data['.spItemUrl']) || build_from_fields(data)
      end

      def build_from_sp_item_url(sp_url)
        return nil unless sp_url

        match = sp_url.match(SP_ITEM_RE)
        match ? { site_url: match[1], drive_id: match[2], item_id: match[3] } : nil
      end

      def build_from_fields(data)
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

    # Downloads meeting transcripts via SharePoint API (no Safari required)
    module MeetingTranscript
      include EmbedPageParser

      private

      def download_transcript(target, classified)
        sharing_url = target[:fileUrl] || first_recording_url(classified)
        return error('No recording sharing link found for transcript download') unless sharing_url

        execute_transcript_pipeline(sharing_url)
      end

      def first_recording_url(classified)
        classified[:recordings].filter_map { |rec| rec[:url] }.first
      end

      def execute_transcript_pipeline(sharing_url)
        info('Fetching transcript via SharePoint...')
        embed_url = fetch_embed_url(sharing_url)
        return error('Could not get embed URL from sharing link') unless embed_url

        @transcript_info = fetch_and_parse_embed(embed_url)
        return error('Could not extract file info from embed page') unless @transcript_info

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
        fetch_transcript_list(url)
      end

      def build_transcripts_url
        "#{@transcript_info[:site_url]}/_api/v2.1" \
          "/drives/#{@transcript_info[:drive_id]}" \
          "/items/#{@transcript_info[:item_id]}/media/transcripts"
      end

      def fetch_transcript_list(url)
        response = fetch_with_drive_token(url)
        return nil unless response

        parse_transcript_response(response)
      rescue JSON::ParserError => e
        debug("Transcript list JSON parse error: #{e.message}")
        nil
      end

      def fetch_with_drive_token(url)
        uri = URI(url)
        headers = { 'Accept' => 'application/json' }
        token = @transcript_info[:drive_token]
        headers['Authorization'] = "Bearer #{token}" if token
        result = Net::HTTP.get_response(uri, headers)
        result.is_a?(Net::HTTPSuccess) ? result.body : nil
      rescue IOError, SystemCallError, SocketError, Timeout::Error, OpenSSL::SSL::SSLError => e
        debug("Transcript list fetch error: #{e.message}")
        nil
      end

      def parse_transcript_response(body)
        data = JSON.parse(body)
        return nil if data['error']

        entry = (data['value'] || [data]).first
        download_url = entry&.dig('temporaryDownloadUrl') || entry&.dig('downloadUrl')
        download_url ? { url: download_url, name: File.basename(entry['name'] || 'transcript.vtt') } : nil
      end

      def save_transcript(transcript)
        dir = @options[:output_dir] || '.'
        FileUtils.mkdir_p(dir)
        path = File.join(dir, File.basename(transcript[:name]))

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
