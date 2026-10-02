# frozen_string_literal: true

require 'English'
require 'date'
require 'open3'
require 'tmpdir'

module Teems
  module Commands
    # Fetches saved Teams transcripts for calendar meetings. Transcript retrieval still
    # goes through `teems meeting`, keeping its SharePoint/auth implementation in one place.
    class Transcripts < Base
      HELP = <<~HELP
        teems transcripts - Sync saved meeting transcripts onto this machine

        USAGE:
          teems transcripts sync [--since DAYS | --date YYYY-MM-DD] [--dry-run] [--no-post-sync]

        OPTIONS:
          --since DAYS       Calendar lookback (default 7; first run 30)
          --date YYYY-MM-DD  Only scan one calendar date
          --dry-run          List meetings and recording counts without downloading
          --no-post-sync     Skip the configured post-sync command for this run
          -q, --quiet       Suppress progress (not errors)

        WebVTTs: ~/.local/share/teems/transcripts/
        Markdown (for local search, e.g. qmd): ~/.local/share/teems/transcripts-md/
        Sync state: ~/.local/state/teems/transcript-sync.json
        Only meetings on your Teams calendar with a saved, accessible recording
        transcript can be retrieved; each recording's transcript is kept (a meeting
        restarted mid-session has several). Does not alter meeting-capture files.

        POST-SYNC COMMAND:
        Set "transcripts": {"post_sync_command": "..."} in ~/.config/teems/config.json to
        run a shell command (e.g. a qmd index refresh) after a sync that changed Markdown.
        It receives TEEMS_TRANSCRIPTS_CHANGED (newline-separated Markdown paths),
        TEEMS_TRANSCRIPTS_CHANGED_COUNT, TEEMS_TRANSCRIPTS_MARKDOWN_DIR, and
        TEEMS_TRANSCRIPTS_DIR. "post_sync_timeout" (seconds, default 300) bounds it.
        A failing or timed-out command is reported but does not fail the sync.
      HELP

      OPTION_HANDLERS = {
        '--since' => ->(opts, args) { opts[:since] = Integer(args.shift, exception: false) },
        '--date' => ->(opts, args) { opts.merge!(Transcripts.date_option(args.shift)) },
        '--dry-run' => ->(opts, _args) { opts[:dry_run] = true },
        '--no-post-sync' => ->(opts, _args) { opts[:no_post_sync] = true }
      }.freeze

      def self.date_option(value)
        { date: Date.iso8601(value) }
      rescue ArgumentError, TypeError
        { invalid_date: true }
      end

      def initialize(args, runner:)
        @options = {}
        super
      end

      def execute
        validation = validate_options
        return validation if validation
        unless positional_args == ['sync']
          return error('Usage: teems transcripts sync [--since DAYS | --date YYYY-MM-DD]')
        end
        return error('--since must be between 1 and 366') unless (1..366).cover?(@options.fetch(:since, 7))
        return error('Invalid --date (expected YYYY-MM-DD)') if @options[:invalid_date]

        TranscriptSyncEngine.new(@options, output, hook: transcript_settings).run
      end

      protected

      def handle_option(arg, pending)
        handler = OPTION_HANDLERS[arg]
        return super unless handler

        handler.call(@options, pending)
      end

      def transcript_settings
        settings = config['transcripts']
        settings.is_a?(Hash) ? settings : {}
      end

      def help_text = HELP
    end

    # Where transcript sync keeps its files: XDG data for transcripts, XDG state for the manifest
    TranscriptPaths = Data.define(:output_dir, :markdown_dir, :state_dir) do
      def self.from_env
        data_dir = Support::XdgPaths.new.data_dir
        state_home = ENV.fetch('XDG_STATE_HOME') { File.join(Dir.home, '.local', 'state') }
        new(output_dir: File.join(data_dir, 'transcripts'), markdown_dir: File.join(data_dir, 'transcripts-md'),
            state_dir: File.join(state_home, 'teems'))
      end

      def manifest = File.join(state_dir, 'transcript-sync.json')

      def lock = File.join(state_dir, 'transcript-sync.lock')
    end

    # A scheduled Teams meeting on one calendar date (one occurrence of a recurring series)
    TranscriptMeeting = Data.define(:date, :event) do
      def id = event.fetch('id')

      def name = event['subject'].to_s.gsub(/[\r\n]/, ' ')[0, 100]

      def status_line(status) = "#{date}: #{status}: #{name}"

      def command_args = ['meeting', id, '--date', date.iso8601]

      # Manifest key for one recording's transcript
      def recording_key(url) = Digest::SHA256.hexdigest("#{date.iso8601}:#{id}:#{url}")

      # Manifest key used before transcripts were tracked per recording
      def legacy_key = Digest::SHA256.hexdigest("#{date.iso8601}:#{id}")
    end

    # One recording of a meeting; each has its own transcript
    TranscriptRecording = Data.define(:meeting, :url) do
      def key = meeting.recording_key(url)

      def legacy_key = meeting.legacy_key

      def date = meeting.date

      def transcript_args(dir) = [*meeting.command_args, '--transcript', '--recording-url', url, '-o', dir]

      def manifest_entry(file_name)
        { 'file' => file_name, 'downloaded_at' => Time.now.iso8601, 'date' => date.iso8601, 'subject' => meeting.name }
      end
    end

    # Private on-disk storage, separate from meeting-capture.
    module TranscriptSyncFiles
      private

      def prepare_private_directories
        [@paths.output_dir, @paths.state_dir].each { |dir| private_directory(dir) }
      end

      def private_directory(dir)
        FileUtils.mkdir_p(dir, mode: 0o700)
        File.chmod(0o700, dir)
      end

      # Transcripts live flat in the output dir; manifest entries are trusted only for their basename
      def transcript_path(file) = File.join(@paths.output_dir, File.basename(file))

      def log_locked
        log 'Another transcript sync is running; skipping.'
        0
      end

      def load_manifest
        path = @paths.manifest
        File.file?(path) ? JSON.parse(File.read(path)) : { 'events' => {} }
      end

      def downloaded?(key, manifest)
        prior = manifest.fetch('events', {})[key]
        prior && valid_vtt?(transcript_path(prior.fetch('file')))
      end

      def persist_download(recording, file, manifest)
        key = recording.key
        adopted = adopt_legacy_download(recording, file, manifest)
        target_name = adopted || store_download(file, key)
        manifest['events'][key] = recording.manifest_entry(target_name)
        save_manifest(manifest)
        log "#{recording.date}: #{adopted ? 'already had' : 'saved'} #{target_name}"
      end

      def store_download(file, key)
        target_name = "#{File.basename(file, '.vtt')}--#{key[0, 10]}.vtt"
        target = transcript_path(target_name)
        File.rename(file, target) unless valid_vtt?(target)
        File.chmod(0o600, target)
        target_name
      end

      # Earlier syncs kept one transcript per event. Reuse that file when it is
      # this recording's transcript instead of saving a duplicate.
      def adopt_legacy_download(recording, file, manifest)
        events = manifest['events']
        key = recording.legacy_key
        legacy = events[key]
        return unless legacy

        existing = transcript_path(legacy.fetch('file'))
        return unless valid_vtt?(existing) && FileUtils.identical?(existing, file)

        events.delete(key)
        File.basename(existing)
      end

      def valid_vtt?(file)
        File.file?(file) && File.size(file) > 10 && File.open(file, 'rb') { |io| io.read(6) == 'WEBVTT' }
      end

      # The single valid WebVTT `teems meeting --transcript` wrote into dir, if any
      def downloaded_vtt(dir)
        vtt, *extra = Dir.glob(File.join(dir, '*.vtt'))
        vtt if extra.empty? && valid_vtt?(vtt.to_s)
      end

      def save_manifest(manifest)
        write_private(@paths.manifest, "#{JSON.pretty_generate(manifest)}\n")
      end

      def write_private(path, content)
        temp = "#{path}.tmp.#{$PROCESS_ID}"
        File.open(temp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(content) }
        File.rename(temp, path)
        File.chmod(0o600, path)
      ensure
        File.delete(temp) if temp && File.exist?(temp)
      end
    end

    # Speaker-turn Markdown copies of each WebVTT, suitable for a local search index.
    module TranscriptSyncMarkdown
      private

      # Returns [Markdown paths written this run, whether every export succeeded]
      def sync_markdown(manifest)
        private_directory(@paths.markdown_dir)
        results = manifest.fetch('events', {}).values.map { |entry| export_markdown(entry) }
        written = results.grep(String)
        log "Markdown: updated #{written.length} transcript(s)" unless written.empty?
        [written, !results.include?(:failed)]
      end

      # Returns the Markdown path it wrote, or :missing, :current, or :failed
      def export_markdown(entry)
        vtt = transcript_path(entry.fetch('file'))
        return :missing unless valid_vtt?(vtt)

        target = File.join(@paths.markdown_dir, "#{File.basename(vtt, '.vtt')}.md")
        return :current if markdown_current?(target, vtt)

        write_private(target, markdown_for(vtt, entry))
        target
      rescue StandardError => e
        markdown_failure(entry, "#{e.class}: #{e.message}")
      end

      def markdown_current?(target, vtt) = File.file?(target) && File.mtime(target) >= File.mtime(vtt)

      def markdown_failure(entry, reason)
        failure "Markdown export failed for #{File.basename(entry['file'].to_s)} (#{reason})"
        :failed
      end

      def markdown_for(vtt, entry)
        subject, date = entry.values_at('subject', 'date')
        stem = File.basename(vtt, '.vtt').sub(/--\h{10}\z/, '')
        Formatters::TranscriptMarkdown.new(
          File.read(vtt, encoding: 'bom|utf-8'),
          title: subject || stem.sub(/\A\d{4}-\d{2}-\d{2} - /, '').sub(/-\d{8}_\d{6}UTC\z/, ''),
          date: date || transcript_date(stem),
          source: File.basename(vtt)
        ).render
      end

      def transcript_date(stem)
        return stem[0, 10] if stem.match?(/\A\d{4}-\d{2}-\d{2} - /)

        stem.match(/-(\d{4})(\d{2})(\d{2})_\d{6}UTC\z/)&.captures&.join('-')
      end
    end

    # Calendar discovery is intentionally limited to scheduled Teams meetings.
    module TranscriptSyncCalendar
      private

      def calendar_events(date)
        stdout, stderr, status = Open3.capture3(teems_executable, 'cal', '--date', date.iso8601, '--json')
        raise "teems cal failed (exit #{status.exitstatus}): #{redacted_error(stderr)}" unless status.success?

        return [] if stdout.strip == 'No events found'

        events = JSON.parse(stdout)
        raise 'teems cal returned a non-array response' unless events.is_a?(Array)

        events.select { |event| teams_event?(event) }
      end

      def teams_event?(event)
        return false unless event.is_a?(Hash)
        return false if event['is_cancelled'] || event['is_all_day'] || event['response_status'] == 'declined'

        event['id'].to_s.start_with?('AAMk') &&
          event['online_meeting_url'].to_s.start_with?('https://teams.microsoft.com/')
      end

      def teems_executable = ENV.fetch('TEEMS_EXECUTABLE', 'teems')

      def redacted_error(text)
        lines = text.to_s.scrub.lines.map(&:strip).reject { |line| line.empty? || line.include?('warning:') }
        message = lines.find { |line| line.start_with?('Error:') } || lines.first || 'unknown error'
        message.gsub(%r{https?://\S+}, '[URL]').gsub(/Bearer\s+\S+/i, 'Bearer [REDACTED]')[0, 220]
      end
    end

    # One transcript per recording: a meeting restarted mid-session has several.
    module TranscriptSyncRecordings
      NO_TRANSCRIPT = Regexp.union(/No recording sharing link found/i,
                                   /No transcripts found for this recording/i,
                                   /No meeting activity found for/i)

      private

      def sync_event(meeting, manifest)
        urls = recording_urls(meeting)
        return unavailable?(meeting) if urls.empty?
        return preview_event?(meeting, urls, manifest) if @options[:dry_run]

        urls.map { |url| sync_recording?(TranscriptRecording.new(meeting: meeting, url: url), manifest) }.all?
      rescue StandardError => e
        failure "#{meeting.status_line('failed')} (#{e.class}: #{e.message})"
        false
      end

      def recording_urls(meeting)
        stdout, stderr, status = Open3.capture3(teems_executable, *meeting.command_args, '--json')
        return recordings_from(stdout) if status.success?

        message = "#{stderr} #{stdout}"
        return [] if NO_TRANSCRIPT.match?(message)

        raise "teems meeting failed (exit #{status.exitstatus}): #{redacted_error(message)}"
      end

      # Recording URLs in start-time order, skipping recordings without a sharing link
      def recordings_from(json)
        pairs = JSON.parse(json).fetch('recordings', []).map { |rec| rec.values_at('time', 'url') }
        pairs.select(&:last).sort_by { |time, _url| time.to_s }.map(&:last).uniq
      end

      def sync_recording?(recording, manifest)
        downloaded?(recording.key, manifest) || download_recording?(recording, manifest)
      end

      def preview_event?(meeting, urls, manifest)
        pending = urls.count { |url| !downloaded?(meeting.recording_key(url), manifest) }
        pending -= 1 if pending.positive? && downloaded?(meeting.legacy_key, manifest)
        log "#{meeting.status_line('candidate')} (#{urls.length} recording(s), #{pending} not yet saved)"
        true
      end

      def download_recording?(recording, manifest)
        Dir.mktmpdir('teems-transcript-', @paths.output_dir) do |temp_dir|
          stdout, stderr, status = Open3.capture3(teems_executable, *recording.transcript_args(temp_dir))
          vtt = downloaded_vtt(temp_dir)
          return download_failure?(recording.meeting, status, "#{stderr} #{stdout}") unless status.success? && vtt

          persist_download(recording, vtt, manifest)
        end
        true
      end

      def download_failure?(meeting, status, message)
        return unavailable?(meeting) if NO_TRANSCRIPT.match?(message)

        failure "#{meeting.status_line('failed')} (exit #{status.exitstatus}; #{redacted_error(message)})"
        false
      end

      def unavailable?(meeting)
        log meeting.status_line('unavailable via teems')
        true
      end
    end

    # Optional user command run after a sync changes Markdown, e.g. to refresh a qmd index.
    # A failing or slow command is reported but never fails the sync itself.
    class TranscriptPostSyncHook
      DEFAULT_TIMEOUT = 300

      def initialize(settings, paths:, output:, quiet:)
        @settings = settings
        @paths = paths
        @output = output
        @quiet = quiet
      end

      def run(changed)
        command = @settings['post_sync_command'].to_s.strip
        return if command.empty? || changed.empty?

        log "Post-sync: running command for #{changed.length} changed transcript(s)"
        report(*execute(command, changed))
      rescue StandardError => e
        @output.warn("Post-sync command could not run (#{e.class}: #{e.message})")
      end

      private

      def log(message)
        @output.puts(message) unless @quiet
      end

      # Runs in its own process group so a timeout can stop the whole pipeline.
      def execute(command, changed)
        Open3.popen2e(env(changed), 'sh', '-c', command, pgroup: true) do |stdin, stdout, wait|
          stdin.close
          reader = Thread.new { stdout.read }
          finished = wait.join(timeout)
          stop(wait.pid) unless finished
          [finished ? wait.value : nil, reader.value]
        end
      end

      def stop(pid)
        Process.kill('KILL', -pid)
      rescue Errno::ESRCH
        nil
      end

      def env(changed)
        { 'TEEMS_TRANSCRIPTS_CHANGED' => changed.join("\n"),
          'TEEMS_TRANSCRIPTS_CHANGED_COUNT' => changed.length.to_s,
          'TEEMS_TRANSCRIPTS_MARKDOWN_DIR' => @paths.markdown_dir,
          'TEEMS_TRANSCRIPTS_DIR' => @paths.output_dir }
      end

      def timeout = [@settings['post_sync_timeout']].grep(Numeric).find(&:positive?) || DEFAULT_TIMEOUT

      def report(status, hook_output)
        return log('Post-sync: done') if status&.success?

        reason = status ? "exit #{status.exitstatus}" : "timed out after #{timeout}s"
        @output.warn("Post-sync command failed (#{reason}): #{tail(hook_output)}")
      end

      def tail(text)
        lines = text.to_s.scrub.lines.map(&:strip).reject(&:empty?).last(3)
        lines.empty? ? 'no output' : lines.join(' | ')[0, 300]
      end
    end

    # Local manifest and replay engine. Never transfers transcripts to another machine.
    class TranscriptSyncEngine
      include TranscriptSyncFiles
      include TranscriptSyncCalendar
      include TranscriptSyncMarkdown
      include TranscriptSyncRecordings

      DEFAULT_LOOKBACK = 7
      INITIAL_LOOKBACK = 30

      def initialize(options, output, hook: {})
        @options = options
        @output = output
        @paths = TranscriptPaths.from_env
        @hook = TranscriptPostSyncHook.new(hook, paths: @paths, output: output, quiet: options[:quiet])
      end

      def run
        File.umask(0o077)
        @options[:dry_run] ? scan(load_manifest) : locked_scan
      end

      private

      def locked_scan
        prepare_private_directories
        File.open(@paths.lock, File::RDWR | File::CREAT, 0o600) do |lock|
          return log_locked unless lock.flock(File::LOCK_EX | File::LOCK_NB)

          scan(load_manifest)
        end
      end

      def log(message)
        @output.puts(message) unless @options[:quiet]
      end

      def failure(message)
        @output.error(message)
      end

      def dates_to_scan(manifest)
        date = @options[:date]
        return [date] if date

        today = Date.today
        days = lookback_days(manifest, today)
        log "Scanning #{days} day(s) through #{today} on this machine"
        ((today - days + 1)..today).to_a
      end

      def lookback_days(manifest, today)
        days = @options.fetch(:since, DEFAULT_LOOKBACK)
        return days unless days == DEFAULT_LOOKBACK

        previous = manifest['last_scan_date']
        return INITIAL_LOOKBACK unless previous

        # Catch up after time away, capped at the requested initial window.
        (today - Date.iso8601(previous) + 1).to_i.clamp(days, INITIAL_LOOKBACK)
      end

      def scan(manifest)
        results = dates_to_scan(manifest).map { |date| scan_date(date, manifest) }
        results << finish_scan(manifest, results) unless @options[:dry_run]
        results.all? ? 0 : 1
      end

      def scan_date(date, manifest)
        results = calendar_events(date).map do |event|
          sync_event(TranscriptMeeting.new(date: date, event: event), manifest)
        end
        results.all?
      rescue StandardError => e
        failure "#{date}: calendar error (#{e.class}: #{e.message})"
        nil
      end

      # Records the scan, refreshes Markdown, and runs the post-sync hook; returns whether Markdown export succeeded.
      # Failed artifacts stay in the log and get seven-day retries. A calendar failure (nil result)
      # leaves the wider scan pending so historical days aren't lost.
      def finish_scan(manifest, results)
        manifest['last_scan_date'] = Date.today.iso8601 unless @options[:date] || results.include?(nil)
        save_manifest(manifest)
        changed, markdown_ok = sync_markdown(manifest)
        @hook.run(changed) unless @options[:no_post_sync]
        markdown_ok
      end
    end
  end
end
