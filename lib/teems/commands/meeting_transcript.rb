# frozen_string_literal: true

module Teems
  module Commands
    # Resolves SharePoint embed page and extracts file metadata via Safari
    module TranscriptEmbed
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

        json = safari.execute_js('JSON.stringify(typeof g_fileInfo !== "undefined" ? g_fileInfo : null)')
        parse_file_info(json.to_s)
      rescue Teems::Error => e
        debug("File info extraction failed: #{e.message}")
        nil
      end

      def parse_file_info(raw)
        return nil if raw.empty?

        data = JSON.parse(raw)
        data.is_a?(Hash) ? build_file_info(data) : nil
      rescue JSON::ParserError
        nil
      end

      def build_file_info(data)
        drive_id = data.dig('libraryId', 'siteId') || data['driveId']
        item_id = data['itemId'] || data['id']
        site_url = data['siteUrl'] || data.dig('libraryId', 'siteUrl')
        [drive_id, item_id, site_url].all? ? { drive_id: drive_id, item_id: item_id, site_url: site_url } : nil
      end
    end

    # Downloads meeting transcripts via SharePoint API using Safari for auth
    module MeetingTranscript
      include TranscriptEmbed

      FETCH_TEMPLATE = "fetch('%s', {credentials: 'include', headers: {Accept: 'application/json'}})" \
                       '.then(r => r.json()).then(d => document.title = JSON.stringify(d))' \
                       '.catch(e => document.title = JSON.stringify({error: e.message}))'

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

        file_info = extract_file_info(safari, embed_url)
        return error('Could not extract file info from embed page') unless file_info

        fetch_and_save_transcript(safari, file_info)
      end

      def fetch_and_save_transcript(safari, file_info)
        url = build_transcripts_url(file_info)
        debug("Fetching transcripts from: #{url}")

        transcript = fetch_transcript_list(safari, url)
        return error('No transcripts found for this recording') unless transcript

        save_transcript(transcript)
      end

      def build_transcripts_url(file_info)
        "#{file_info[:site_url]}/_api/v2.1/drives/#{file_info[:drive_id]}" \
          "/items/#{file_info[:item_id]}/media/transcripts"
      end

      def fetch_transcript_list(safari, url)
        result = safari.execute_js(build_fetch_js(url)).to_s
        return nil if result.empty? || result == 'null'

        parse_transcript_response(result)
      rescue JSON::ParserError => e
        debug("Transcript JSON parse error: #{e.message}")
        nil
      end

      def build_fetch_js(url) = format(FETCH_TEMPLATE, url)

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
        content = fetch_transcript_content(transcript[:url])
        return error('Failed to download transcript content') unless content

        File.write(path, content)
        success("Transcript saved to #{path}")
      end

      def fetch_transcript_content(url)
        response = Net::HTTP.get_response(URI(url))
        response.is_a?(Net::HTTPSuccess) ? response.body : nil
      rescue StandardError => e
        debug("Transcript download error: #{e.message}")
        nil
      end
    end
  end
end
