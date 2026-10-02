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
        case arg
        when '--since' then @options[:since] = Integer(pending.shift, exception: false)
        when '--date' then parse_date_option(pending.shift)
        when '--dry-run' then @options[:dry_run] = true
        when '--no-post-sync' then @options[:no_post_sync] = true
        else super
        end
      end

      def transcript_settings
        settings = config['transcripts']
        settings.is_a?(Hash) ? settings : {}
      end

      def parse_date_option(value)
        @options[:date] = Date.iso8601(value)
      rescue ArgumentError, TypeError
        @options[:invalid_date] = true
      end

      def help_text = HELP
    end

    # Private on-disk storage, separate from meeting-capture.
    module TranscriptSyncFiles
      private

      def prepare_private_directories
        [@output_dir, @state_dir].each do |dir|
          FileUtils.mkdir_p(dir, mode: 0o700)
          File.chmod(0o700, dir)
        end
      end

      def log_locked
        log 'Another transcript sync is running; skipping.'
        0
      end

      def load_manifest
        File.file?(@manifest_path) ? JSON.parse(File.read(@manifest_path)) : { 'events' => {} }
      end

      def downloaded?(key, manifest)
        prior = manifest.fetch('events', {})[key]
        prior && valid_vtt?(File.join(@output_dir, File.basename(prior.fetch('file'))))
      end

      def persist_download(date, event, key, file, manifest)
        adopted = adopt_legacy_download(date, event, file, manifest)
        target_name = adopted || store_download(file, key)
        manifest['events'][key] = { 'file' => target_name, 'downloaded_at' => Time.now.iso8601,
                                    'date' => date.iso8601, 'subject' => event_name(event) }
        save_manifest(manifest)
        log "#{date}: #{adopted ? 'already had' : 'saved'} #{target_name}"
      end

      def store_download(file, key)
        target_name = "#{File.basename(file, '.vtt')}--#{key[0, 10]}.vtt"
        target = File.join(@output_dir, target_name)
        File.rename(file, target) unless valid_vtt?(target)
        File.chmod(0o600, target)
        target_name
      end

      # Earlier syncs kept one transcript per event. Reuse that file when it is
      # this recording's transcript instead of saving a duplicate.
      def adopt_legacy_download(date, event, file, manifest)
        key = legacy_key(date, event)
        legacy = manifest['events'][key]
        return unless legacy

        existing = File.join(@output_dir, File.basename(legacy.fetch('file')))
        return unless valid_vtt?(existing) && FileUtils.identical?(existing, file)

        manifest['events'].delete(key)
        File.basename(existing)
      end

      def valid_vtt?(file)
        File.file?(file) && File.size(file) > 10 && File.open(file, 'rb') { |io| io.read(6) == 'WEBVTT' }
      end

      def valid_download?(status, files)
        status.success? && files.length == 1 && valid_vtt?(files.first)
      end

      def save_manifest(manifest)
        write_private(@manifest_path, "#{JSON.pretty_generate(manifest)}\n")
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

      def sync_markdown(manifest)
        FileUtils.mkdir_p(@markdown_dir, mode: 0o700)
        File.chmod(0o700, @markdown_dir)
        results = manifest.fetch('events', {}).values.map { |entry| export_markdown(entry) }
        written = results.count(:written)
        log "Markdown: updated #{written} transcript(s)" if written.positive?
        results
      end

      def export_markdown(entry)
        vtt = File.join(@output_dir, File.basename(entry.fetch('file')))
        return :missing unless valid_vtt?(vtt)

        target = File.join(@markdown_dir, "#{File.basename(vtt, '.vtt')}.md")
        return :current if markdown_current?(target, vtt)

        write_private(target, markdown_for(vtt, entry))
        @changed_markdown << target
        :written
      rescue StandardError => e
        markdown_failure(entry, e)
      end

      def markdown_current?(target, vtt) = File.file?(target) && File.mtime(target) >= File.mtime(vtt)

      def markdown_failure(entry, error)
        failure "Markdown export failed for #{File.basename(entry['file'].to_s)} (#{error.class}: #{error.message})"
        :failed
      end

      def markdown_for(vtt, entry)
        stem = File.basename(vtt, '.vtt').sub(/--\h{10}\z/, '')
        Formatters::TranscriptMarkdown.new(
          File.read(vtt, encoding: 'bom|utf-8'),
          title: entry['subject'] || stem.sub(/\A\d{4}-\d{2}-\d{2} - /, '').sub(/-\d{8}_\d{6}UTC\z/, ''),
          date: entry['date'] || transcript_date(stem),
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

      def sync_event(date, event, manifest)
        urls = recording_urls(date, event)
        return unavailable?(date, event) if urls.empty?
        return preview_event?(date, event, urls, manifest) if @options[:dry_run]

        urls.map { |url| sync_recording?(date, event, url, manifest) }.all?
      rescue StandardError => e
        failure "#{date}: failed: #{event_name(event)} (#{e.class}: #{e.message})"
        false
      end

      def recording_urls(date, event)
        stdout, stderr, status = Open3.capture3(teems_executable, 'meeting', event.fetch('id'),
                                                '--date', date.iso8601, '--json')
        return recordings_from(stdout) if status.success?
        return [] if NO_TRANSCRIPT.match?("#{stderr} #{stdout}")

        raise "teems meeting failed (exit #{status.exitstatus}): #{redacted_error("#{stderr} #{stdout}")}"
      end

      def recordings_from(json)
        recordings = JSON.parse(json).fetch('recordings', [])
        recordings.select { |rec| rec['url'] }.sort_by { |rec| rec['time'].to_s }.map { |rec| rec['url'] }.uniq
      end

      def recording_key(date, event, url) = Digest::SHA256.hexdigest("#{date.iso8601}:#{event.fetch('id')}:#{url}")

      def legacy_key(date, event) = Digest::SHA256.hexdigest("#{date.iso8601}:#{event.fetch('id')}")

      def sync_recording?(date, event, url, manifest)
        key = recording_key(date, event, url)
        downloaded?(key, manifest) || download_recording?(date, event, url, key, manifest)
      end

      def preview_event?(date, event, urls, manifest)
        pending = urls.count { |url| !downloaded?(recording_key(date, event, url), manifest) }
        pending -= 1 if pending.positive? && downloaded?(legacy_key(date, event), manifest)
        log "#{date}: candidate: #{event_name(event)} (#{urls.length} recording(s), #{pending} not yet saved)"
        true
      end

      def download_recording?(date, event, url, key, manifest)
        Dir.mktmpdir('teems-transcript-', @output_dir) do |temp_dir|
          stdout, stderr, status = Open3.capture3(teems_executable, 'meeting', event.fetch('id'),
                                                  '--date', date.iso8601, '--transcript',
                                                  '--recording-url', url, '-o', temp_dir)
          files = Dir.glob(File.join(temp_dir, '*.vtt'))
          return download_failure?(date, event, status, "#{stderr} #{stdout}") unless valid_download?(status, files)

          persist_download(date, event, key, files.first, manifest)
        end
        true
      end

      def download_failure?(date, event, status, message)
        return unavailable?(date, event) if NO_TRANSCRIPT.match?(message)

        failure "#{date}: failed: #{event_name(event)} (exit #{status.exitstatus}; #{redacted_error(message)})"
        false
      end

      def unavailable?(date, event)
        log "#{date}: unavailable via teems: #{event_name(event)}"
        true
      end
    end

    # Optional user command run after a sync changes Markdown, e.g. to refresh a qmd index.
    # A failing or slow command is reported but never fails the sync itself.
    module TranscriptSyncHook
      DEFAULT_HOOK_TIMEOUT = 300

      private

      def run_post_sync_hook
        command = @hook['post_sync_command'].to_s.strip
        return if command.empty? || @options[:no_post_sync] || @changed_markdown.empty?

        log "Post-sync: running command for #{@changed_markdown.length} changed transcript(s)"
        report_hook(*execute_hook(command))
      rescue StandardError => e
        @output.warn("Post-sync command could not run (#{e.class}: #{e.message})")
      end

      # Runs in its own process group so a timeout can stop the whole pipeline.
      def execute_hook(command)
        Open3.popen2e(hook_env, 'sh', '-c', command, pgroup: true) do |stdin, stdout, wait|
          stdin.close
          reader = Thread.new { stdout.read }
          finished = wait.join(hook_timeout)
          stop_hook(wait.pid) unless finished
          [finished ? wait.value : nil, reader.value]
        end
      end

      def stop_hook(pid)
        Process.kill('KILL', -pid)
      rescue Errno::ESRCH
        nil
      end

      def hook_env
        { 'TEEMS_TRANSCRIPTS_CHANGED' => @changed_markdown.join("\n"),
          'TEEMS_TRANSCRIPTS_CHANGED_COUNT' => @changed_markdown.length.to_s,
          'TEEMS_TRANSCRIPTS_MARKDOWN_DIR' => @markdown_dir,
          'TEEMS_TRANSCRIPTS_DIR' => @output_dir }
      end

      def hook_timeout = [@hook['post_sync_timeout']].grep(Numeric).find(&:positive?) || DEFAULT_HOOK_TIMEOUT

      def report_hook(status, hook_output)
        return log('Post-sync: done') if status&.success?

        reason = status ? "exit #{status.exitstatus}" : "timed out after #{hook_timeout}s"
        @output.warn("Post-sync command failed (#{reason}): #{hook_tail(hook_output)}")
      end

      def hook_tail(text)
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
      include TranscriptSyncHook

      DEFAULT_LOOKBACK = 7
      INITIAL_LOOKBACK = 30

      def initialize(options, output, hook: {})
        @options = options
        @output = output
        @hook = hook
        @changed_markdown = []
        data_home = ENV.fetch('XDG_DATA_HOME', File.join(Dir.home, '.local', 'share'))
        state_home = ENV.fetch('XDG_STATE_HOME', File.join(Dir.home, '.local', 'state'))
        @output_dir = File.join(data_home, 'teems', 'transcripts')
        @markdown_dir = File.join(data_home, 'teems', 'transcripts-md')
        @state_dir = File.join(state_home, 'teems')
        @manifest_path = File.join(@state_dir, 'transcript-sync.json')
      end

      def run
        File.umask(0o077)
        return scan(load_manifest) if @options[:dry_run]

        prepare_private_directories
        File.open(File.join(@state_dir, 'transcript-sync.lock'), File::RDWR | File::CREAT, 0o600) do |lock|
          return log_locked unless lock.flock(File::LOCK_EX | File::LOCK_NB)

          scan(load_manifest)
        end
      end

      private

      def log(message)
        @output.puts(message) unless @options[:quiet]
      end

      def failure(message)
        @output.error(message)
      end

      def dates_to_scan(manifest)
        return [@options[:date]] if @options[:date]

        days = lookback_days(manifest)
        log "Scanning #{days} day(s) through #{Date.today} on this machine"
        ((Date.today - days + 1)..Date.today).to_a
      end

      def lookback_days(manifest)
        days = @options.fetch(:since, DEFAULT_LOOKBACK)
        return days unless days == DEFAULT_LOOKBACK

        previous = manifest['last_scan_date']
        return INITIAL_LOOKBACK unless previous

        # Catch up after time away, capped at the requested initial window.
        (Date.today - Date.iso8601(previous) + 1).to_i.clamp(days, INITIAL_LOOKBACK)
      end

      def scan(manifest)
        results = dates_to_scan(manifest).map { |date| scan_date(date, manifest) }
        unless @options[:dry_run]
          persist_scan(manifest, results.include?(nil))
          results << !sync_markdown(manifest).include?(:failed)
          run_post_sync_hook
        end
        results.all? ? 0 : 1
      end

      def scan_date(date, manifest)
        results = calendar_events(date).map { |event| sync_event(date, event, manifest) }
        results.all?
      rescue StandardError => e
        failure "#{date}: calendar error (#{e.class}: #{e.message})"
        nil
      end

      def persist_scan(manifest, calendar_failed)
        # Failed artifacts stay in the log and get seven-day retries. A calendar
        # failure leaves the wider scan pending so historical days aren't lost.
        manifest['last_scan_date'] = Date.today.iso8601 unless @options[:date] || calendar_failed
        save_manifest(manifest)
      end

      def event_name(event) = event['subject'].to_s.gsub(/[\r\n]/, ' ')[0, 100]
    end
  end
end
