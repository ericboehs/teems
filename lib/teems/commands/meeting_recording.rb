# frozen_string_literal: true

module Teems
  module Commands
    # Parses DASH MPD manifest XML to extract video/audio segment info
    class DashManifestParser
      # Describes a media track (video or audio) with its segment template info
      Track = Data.define(:type, :init_url, :media_template, :segment_count, :timescale, :segments)

      # A single media segment with start time and duration in timescale units
      Segment = Data.define(:start, :duration)

      ADAPTATION_RE = %r{<AdaptationSet[^>]*contentType="(video|audio)"(.*?)</AdaptationSet>}m
      TEMPLATE_RE = /<SegmentTemplate[^>]*/
      TIMELINE_RE = %r{<SegmentTimeline>(.*?)</SegmentTimeline>}m
      SEGMENT_RE = /<S\s[^>]*>/
      REP_RE = /<Representation[^>]*id="([^"]+)"/

      def initialize(mpd_xml)
        @xml = mpd_xml
        @attrs = nil
        @rep_id = nil
      end

      def parse
        tracks = []
        @xml.scan(ADAPTATION_RE) do |type, body|
          track = parse_adaptation(type, body)
          tracks << track if track
        end
        tracks
      end

      private

      def parse_adaptation(type, body)
        template_match = body.match(TEMPLATE_RE)
        return nil unless template_match

        @attrs = template_match[0]
        @rep_id = body.match(REP_RE)&.then { _1[1] } || ''
        segments = parse_timeline(body)
        return nil if segments.empty?

        build_track(type, segments)
      end

      def build_track(type, segments)
        timescale_val = extract_attr(@attrs, 'timescale').to_i
        Track.new(type: type,
                  init_url: decode_template(extract_attr(@attrs, 'initialization')),
                  media_template: decode_template(extract_attr(@attrs, 'media')),
                  segment_count: segments.length,
                  timescale: timescale_val.positive? ? timescale_val : 1,
                  segments: segments)
      end

      def decode_template(url)
        return '' unless url

        url.gsub('&amp;', '&').gsub('$RepresentationID$', @rep_id.to_s)
      end

      def parse_timeline(body)
        timeline_match = body.match(TIMELINE_RE)
        return [] unless timeline_match

        segments = []
        time = 0
        timeline_match[1].scan(SEGMENT_RE) do |seg_tag|
          time = parse_segment_tag(seg_tag, time, segments)
        end
        segments
      end

      def parse_segment_tag(seg_tag, time, segments)
        start_time = extract_attr(seg_tag, 't').to_i
        duration = extract_attr(seg_tag, 'd').to_i
        repeat_count = extract_attr(seg_tag, 'r').to_i

        time = start_time if start_time.positive?
        (repeat_count + 1).times do
          segments << Segment.new(start: time, duration: duration)
          time += duration
        end
        time
      end

      def extract_attr(tag, name)
        match = tag.match(/#{name}="([^"]*)"/)
        match ? match[1] : nil
      end
    end

    # Downloads DASH segments and assembles track data
    module SegmentDownloader
      private

      def download_track_segments(track, base_url)
        data = String.new(fetch_segment(resolve_url(base_url, track.init_url)))
        track.segments.each_with_index do |seg, idx|
          path = track.media_template.gsub('$Time$', seg.start.to_s)
          data << fetch_segment(resolve_url(base_url, path))
          print "\r  Downloading: #{idx + 1}/#{track.segment_count} segments"
        end
        data
      end

      def resolve_url(base_url, path)
        return path if path.start_with?('http')

        "#{base_url.sub(%r{/[^/]*$}, '/')}#{path}"
      end

      def fetch_segment(url)
        Net::HTTP.get_response(URI(url)).tap do |resp|
          raise Teems::Error, "Segment download failed (#{resp.code})" unless resp.is_a?(Net::HTTPSuccess)
        end.body
      end
    end

    # Resolves recording file info from SharePoint embed page
    module RecordingResolver
      include TranscriptEmbed

      private

      def resolve_recording_file_info(sharing_url)
        embed_url = fetch_embed_url(sharing_url)
        return error('Could not get embed URL for recording') && nil unless embed_url

        safari = runner.safari_js_runner
        return error('Safari is required for recording download (macOS only)') && nil unless safari.available?

        extract_recording_from_embed(safari, embed_url)
      end

      def extract_recording_from_embed(safari, embed_url)
        debug("Navigating to recording embed page: #{embed_url}")
        safari.navigate(embed_url)
        safari.wait_for_load(timeout: 20)
        poll_recording_file_info(safari)
      rescue Teems::Error => e
        debug("Recording file info extraction failed: #{e.message}")
        error('Could not extract recording file info from embed page') && nil
      end

      def poll_recording_file_info(safari)
        15.times do |attempt|
          result = try_extract_recording_info(safari)
          return result if result

          poll_sleep if attempt.positive?
        end
        error('Could not extract recording file info from embed page') && nil
      end

      def try_extract_recording_info(safari)
        raw = safari.execute_js(TranscriptEmbed::FILE_INFO_JS).to_s
        return nil if raw.empty?

        data = JSON.parse(raw)
        data.is_a?(Hash) ? extract_transform_url(data) : nil
      rescue JSON::ParserError
        nil
      end

      def extract_transform_url(data)
        transform_url = data['.transformUrl'] || data['transformUrl']
        return nil unless transform_url

        { transform_url: transform_url, name: data['name'] || 'recording.mp4' }
      end
    end

    # Downloads meeting recordings via DASH streaming from SharePoint
    module MeetingRecording
      include RecordingResolver
      include SegmentDownloader

      MANIFEST_PARAMS = 'format=dash&part=index'

      private

      def download_recording(target, classified)
        recordings = classified[:recordings]
        return error('No recordings found for this meeting') if recordings.empty?
        return error('ffmpeg is required. Install with: brew install ffmpeg') unless ffmpeg?

        sharing_url = target[:fileUrl] || recordings.first[:url]
        return error('No recording sharing link found') unless sharing_url

        execute_recording_pipeline(sharing_url)
      end

      def execute_recording_pipeline(sharing_url)
        info('Fetching recording via SharePoint...')
        file_info = resolve_recording_file_info(sharing_url)
        return 1 unless file_info

        manifest = fetch_dash_manifest(file_info[:transform_url])
        return error('Could not fetch DASH manifest') unless manifest

        download_and_assemble(manifest)
      end

      def fetch_dash_manifest(transform_url)
        url = build_manifest_url(transform_url)
        debug("Fetching DASH manifest: #{url}")
        fetch_manifest_content(url)
      end

      def build_manifest_url(transform_url)
        url = transform_url.sub('/thumbnail', '/videomanifest')
        separator = url.include?('?') ? '&' : '?'
        "#{url}#{separator}#{MANIFEST_PARAMS}"
      end

      def fetch_manifest_content(url)
        result = Net::HTTP.get_response(URI(url))
        return result.body if result.is_a?(Net::HTTPSuccess)

        debug("Manifest download failed: HTTP #{result.code}")
        nil
      rescue IOError, SystemCallError, SocketError => e
        debug("Manifest download error: #{e.message}")
        nil
      end

      def download_and_assemble(manifest_xml)
        tracks = DashManifestParser.new(manifest_xml).parse
        selected = select_tracks(tracks)
        return error('No video/audio tracks found in manifest') unless selected

        assemble_recording(selected, manifest_xml)
      end

      def select_tracks(tracks)
        grouped = tracks.group_by(&:type)
        video = grouped['video']&.first
        audio = grouped['audio']&.first
        video && audio ? { video: video, audio: audio } : nil
      end

      def assemble_recording(selected, manifest_xml)
        @rec_dir = @options[:output_dir] || '.'
        FileUtils.mkdir_p(@rec_dir)
        @rec_base_url = manifest_xml.match(%r{<BaseURL>([^<]+)</BaseURL>})&.then { _1[1] } || ''

        video_path = write_track(selected[:video], 'video')
        audio_path = write_track(selected[:audio], 'audio')
        merge_and_finalize(video_path, audio_path, @rec_dir)
      end

      def write_track(track, label)
        info("Downloading #{label} track (#{track.segment_count} segments)...")
        data = download_track_segments(track, @rec_base_url)
        path = File.join(@rec_dir, ".teems_#{label}.mp4")
        File.binwrite(path, data)
        puts
        path
      end

      def merge_and_finalize(video_path, audio_path, dir)
        output_path = File.join(dir, 'recording.mp4')
        info('Merging video and audio tracks...')
        merged = run_ffmpeg('-i', video_path, '-i', audio_path, '-c', 'copy', output_path)
        FileUtils.rm_f([video_path, audio_path])

        return error('ffmpeg merge failed') unless merged

        embed_subtitle_if_available(output_path)
        success("Recording saved to #{output_path}")
      end

      def embed_subtitle_if_available(video_path)
        vtt_path = Dir.glob(File.join(File.dirname(video_path), '*.vtt')).first
        return unless vtt_path

        info('Embedding transcript as subtitle track...')
        final_path = video_path.sub('.mp4', '_subs.mp4')
        return unless run_ffmpeg('-i', video_path, '-i', vtt_path, '-c', 'copy', '-c:s', 'mov_text', final_path)

        FileUtils.mv(final_path, video_path)
      end

      def run_ffmpeg(*)
        system('ffmpeg', '-y', *, out: File::NULL, err: File::NULL)
      end

      def ffmpeg?
        system('which', 'ffmpeg', out: File::NULL, err: File::NULL)
      end
    end
  end
end
