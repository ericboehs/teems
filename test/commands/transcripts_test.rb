# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'date'
require 'digest'
require 'open3'
require 'rbconfig'
require 'teems/commands/transcripts'

# End-to-end CLI fixtures intentionally keep the fake executable and filesystem assertions together.
# rubocop:disable Metrics/MethodLength, Metrics/AbcSize, Metrics/ClassLength
class TeemsTranscriptSyncTest < Minitest::Test
  SCRIPT = File.expand_path('../../bin/teems', __dir__)
  Status = Struct.new(:exitstatus) do
    def success? = exitstatus.zero?
  end
  FIRST_VTT = "WEBVTT\n\n1\n00:00:00.000 --> 00:00:01.000\n<v Eric Boehs>hello &amp; welcome</v>\n"
  SECOND_VTT = "WEBVTT\n\n1\n00:00:00.000 --> 00:00:01.000\n<v Eric Boehs>after the restart</v>\n"

  def setup
    @dir = Dir.mktmpdir('teems-sync-test-')
    @bin = File.join(@dir, 'bin')
    FileUtils.mkdir_p(@bin)
    File.write(File.join(@bin, 'teems'), <<~RUBY)
      #!/usr/bin/env ruby
      require 'json'
      require 'fileutils'
      File.open(ENV.fetch('CALL_LOG'), 'a') { |f| f.puts(ARGV.join(' ')) }
      if ARGV.first == 'cal'
        if ENV['NO_EVENTS'] == '1'
          puts 'No events found'
          exit 0
        end
        if ENV['CAL_FAIL'] == '1'
          warn 'Calendar unavailable'
          exit 1
        end
        if ENV['CAL_OBJECT'] == '1'
          puts '{}'
          exit 0
        end
        puts JSON.generate([
          'not-an-event',
          { 'id' => 'AAMkmeeting', 'subject' => 'EERT Brief Prep',
            'online_meeting_url' => 'https://teams.microsoft.com/l/meetup-join/test' },
          { 'id' => 'AAMknotteams', 'subject' => 'Not Teams',
            'online_meeting_url' => 'https://meet.google.com/test' },
          { 'id' => 'AAMkcancelled', 'subject' => 'Cancelled',
            'online_meeting_url' => 'https://teams.microsoft.com/test', 'is_cancelled' => true }
        ])
      elsif ARGV.first == 'meeting' && ARGV.include?('--json')
        if ENV['LIST_FAIL'] == '1'
          warn 'Error: Network unavailable'
          exit 1
        end
        if ENV['NO_RECORDINGS'] == '1'
          warn 'Error: No meeting activity found for 2026-09-28'
          exit 1
        end
        recordings = [{ 'time' => '2026-09-28T15:00:00Z', 'url' => 'https://example.sharepoint.com/rec-1' },
                      { 'time' => '2026-09-28T15:00:01Z', 'url' => nil }]
        if ENV['TWO_RECORDINGS'] == '1'
          recordings.unshift({ 'time' => '2026-09-28T15:40:00Z', 'url' => 'https://example.sharepoint.com/rec-2' })
        end
        puts JSON.generate({ 'thread_id' => '19:meeting_test@thread.v2', 'recordings' => recordings })
      elsif ARGV.first == 'meeting'
        if ENV['MEETING_FAIL'] == '1'
          warn 'Network unavailable'
          exit 1
        end
        if ENV['NO_TRANSCRIPT'] == '1'
          warn 'Error: No transcripts found for this recording'
          exit 1
        end
        dir = ARGV.fetch(ARGV.index('-o') + 1)
        url = ARGV.fetch(ARGV.index('--recording-url') + 1)
        File.write(File.join(dir, '2026-09-28 - EERT Brief Prep.vtt'),
                   url.end_with?('rec-1') ? #{FIRST_VTT.dump} : #{SECOND_VTT.dump})
        puts 'Transcript saved'
      else
        abort 'unexpected teems invocation'
      end
    RUBY
    File.chmod(0o755, File.join(@bin, 'teems'))
    @env = {
      'PATH' => "#{@bin}:#{ENV.fetch('PATH')}",
      'HOME' => @dir,
      'XDG_DATA_HOME' => File.join(@dir, 'data'),
      'XDG_STATE_HOME' => File.join(@dir, 'state'),
      'XDG_CONFIG_HOME' => File.join(@dir, 'config'),
      'CALL_LOG' => File.join(@dir, 'calls'),
      'TEEMS_EXECUTABLE' => File.join(@bin, 'teems')
    }
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def run_sync(*, env: {})
    run_transcripts('sync', '--date', '2026-09-28', *, env: env)
  end

  # In-process so SimpleCov sees the engine; the fake `teems` is still a subprocess.
  def run_transcripts(*args, env: {})
    code = nil
    result = with_sync_env(@env.merge(env)) do
      capture_output do |out|
        code = Teems::Commands::Transcripts.new(args, runner: configured_runner(output: out)).execute
      end
    end
    [result[:stdout], result[:stderr], Status.new(code)]
  end

  def with_sync_env(vars)
    saved_env = vars.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    saved_umask = File.umask
    vars.each { |key, value| ENV[key] = value }
    yield
  ensure
    saved_env&.each { |key, value| ENV[key] = value }
    File.umask(saved_umask) if saved_umask
  end

  def calls
    File.exist?(@env['CALL_LOG']) ? File.readlines(@env['CALL_LOG']).map(&:strip) : []
  end

  def transcript_calls
    calls.select { |line| line.start_with?('meeting ') && line.include?('--transcript') }
  end

  def manifest_events
    JSON.parse(File.read(File.join(@dir, 'state/teems/transcript-sync.json'))).fetch('events')
  end

  def write_transcript_settings(settings)
    config_dir = File.join(@dir, 'config/teems')
    FileUtils.mkdir_p(config_dir)
    File.write(File.join(config_dir, 'config.json'), JSON.generate('transcripts' => settings))
  end

  def configure_hook(command, timeout: nil)
    write_transcript_settings({ 'post_sync_command' => command, 'post_sync_timeout' => timeout }.compact)
  end

  def hook_log = File.join(@dir, 'hook.log')

  def hook_runs
    File.exist?(hook_log) ? File.read(hook_log).split("---\n") : []
  end

  def record_hook_env
    vars = %w[CHANGED_COUNT MARKDOWN_DIR DIR CHANGED].map { |name| %("$TEEMS_TRANSCRIPTS_#{name}") }.join(' ')
    configure_hook(%(printf '%s\\n' #{vars} --- >> "#{hook_log}"))
  end

  def test_post_sync_command_runs_only_when_markdown_changes
    record_hook_env
    stdout, stderr, status = run_sync
    assert status.success?, stderr
    assert_includes stdout, 'Post-sync: running command for 1 changed transcript(s)'
    assert_includes stdout, 'Post-sync: done'
    markdown = Dir.glob(File.join(@dir, 'data/teems/transcripts-md/*.md'))
    expected = ['1', File.join(@dir, 'data/teems/transcripts-md'), File.join(@dir, 'data/teems/transcripts'),
                markdown.first].map { |line| "#{line}\n" }.join
    assert_equal [expected], hook_runs

    stdout, stderr, status = run_sync
    assert status.success?, stderr
    refute_includes stdout, 'Post-sync'
    assert_equal 1, hook_runs.length

    File.delete(markdown.first)
    stdout, stderr, status = run_sync('--no-post-sync')
    assert status.success?, stderr
    assert_includes stdout, 'Markdown: updated 1 transcript(s)'
    refute_includes stdout, 'Post-sync'
    assert_equal 1, hook_runs.length
  end

  def test_post_sync_command_lists_every_changed_transcript
    record_hook_env
    _, stderr, status = run_sync(env: { 'TWO_RECORDINGS' => '1' })
    assert status.success?, stderr
    lines = hook_runs.first.lines(chomp: true)
    assert_equal '2', lines.first
    assert_equal Dir.glob(File.join(@dir, 'data/teems/transcripts-md/*.md')), lines.drop(3).sort
  end

  def test_post_sync_command_skipped_for_dry_run_blank_and_malformed_settings
    record_hook_env
    stdout, stderr, status = run_sync('--dry-run')
    assert status.success?, stderr
    refute_includes stdout, 'Post-sync'

    configure_hook('   ')
    stdout, stderr, status = run_sync
    assert status.success?, stderr
    refute_includes stdout, 'Post-sync'

    write_transcript_settings('not-a-hash')
    File.delete(*Dir.glob(File.join(@dir, 'data/teems/transcripts-md/*.md')))
    stdout, stderr, status = run_sync
    assert status.success?, stderr
    assert_includes stdout, 'Markdown: updated 1 transcript(s)'
    refute_includes stdout, 'Post-sync'
    assert_empty hook_runs
  end

  def test_post_sync_failure_warns_without_failing_sync
    configure_hook("echo first; echo 'qmd exploded' >&2; exit 3", timeout: 'soon')
    stdout, stderr, status = run_sync
    assert status.success?, stderr
    refute_includes stdout, 'Post-sync: done'
    assert_includes stderr, 'Post-sync command failed (exit 3): first | qmd exploded'
    assert_equal 1, Dir.glob(File.join(@dir, 'data/teems/transcripts/*.vtt')).length
  end

  def test_post_sync_timeout_stops_the_command
    configure_hook('sleep 30', timeout: 0.2)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    _, stderr, status = run_sync('-q')
    assert status.success?, stderr
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 10
    assert_includes stderr, 'Post-sync command failed (timed out after 0.2s): no output'
  end

  def test_post_sync_spawn_error_is_reported
    configure_hook("echo a\u0000b")
    _, stderr, status = run_sync
    assert status.success?, stderr
    assert_includes stderr, 'Post-sync command could not run (ArgumentError'
  end

  def test_stopping_an_already_finished_hook_is_harmless
    pid = Process.spawn('true', pgroup: true)
    Process.wait(pid)
    engine = Teems::Commands::TranscriptSyncEngine.new({}, test_output)
    assert_nil engine.send(:stop_hook, pid)
  end

  def test_download_is_private_and_idempotent
    stdout, stderr, status = run_sync
    assert status.success?, stderr
    assert_match(/saved 2026-09-28 - EERT Brief Prep--[a-f0-9]{10}\.vtt/, stdout)
    files = Dir.glob(File.join(@dir, 'data/teems/transcripts/*.vtt'))
    assert_equal 1, files.length
    assert_equal 0o600, File.stat(files.first).mode & 0o777
    assert_equal 0o700, File.stat(File.dirname(files.first)).mode & 0o777
    manifest_path = File.join(@dir, 'state/teems/transcript-sync.json')
    assert_equal 0o600, File.stat(manifest_path).mode & 0o777
    manifest = JSON.parse(File.read(manifest_path))
    assert_equal 1, manifest.fetch('events').length
    refute manifest.key?('last_scan_date'), 'A single-date scan must not mark the entire lookback complete'

    _, stderr, status = run_sync
    assert status.success?, stderr
    assert_equal 1, transcript_calls.length
    assert_equal 1, Dir.glob(File.join(@dir, 'data/teems/transcripts/*.vtt')).length
  end

  def test_markdown_copy_is_private_idempotent_and_regenerated
    _, stderr, status = run_sync
    assert status.success?, stderr
    markdown = Dir.glob(File.join(@dir, 'data/teems/transcripts-md/*.md'))
    assert_equal 1, markdown.length
    assert_equal 0o600, File.stat(markdown.first).mode & 0o777
    assert_equal 0o700, File.stat(File.dirname(markdown.first)).mode & 0o777
    content = File.read(markdown.first)
    assert_includes content, 'title: "EERT Brief Prep"'
    assert_includes content, 'date: 2026-09-28'
    assert_includes content, '**Eric Boehs** (00:00:00): hello & welcome'

    stdout, stderr, status = run_sync
    assert status.success?, stderr
    refute_includes stdout, 'Markdown: updated'

    File.delete(markdown.first)
    stdout, stderr, status = run_sync
    assert status.success?, stderr
    assert_includes stdout, 'Markdown: updated 1 transcript(s)'
    assert_equal 1, transcript_calls.length
  end

  def test_dry_run_does_not_write
    stdout, stderr, status = run_sync('--dry-run')
    assert status.success?, stderr
    assert_includes stdout, 'candidate: EERT Brief Prep (1 recording(s), 1 not yet saved)'
    refute File.exist?(File.join(@dir, 'state'))
    assert_empty transcript_calls
  end

  def test_missing_transcript_is_not_marked_downloaded
    stdout, stderr, status = run_sync(env: { 'NO_TRANSCRIPT' => '1' })
    assert status.success?, stderr
    assert_includes stdout, 'unavailable via teems'
    assert_empty manifest_events
    _, stderr, status = run_sync
    assert status.success?, stderr
    assert_equal 2, transcript_calls.length
  end

  def test_each_recording_keeps_its_own_transcript
    stdout, stderr, status = run_sync(env: { 'TWO_RECORDINGS' => '1' })
    assert status.success?, stderr
    assert_equal 2, stdout.scan(/saved 2026-09-28 - EERT Brief Prep--[a-f0-9]{10}\.vtt/).length
    assert_includes transcript_calls.first, 'https://example.sharepoint.com/rec-1'
    files = Dir.glob(File.join(@dir, 'data/teems/transcripts/*.vtt'))
    assert_equal [FIRST_VTT, SECOND_VTT].sort, files.map { |file| File.read(file) }.sort
    assert_equal 2, manifest_events.length

    stdout, stderr, status = run_sync('--dry-run', env: { 'TWO_RECORDINGS' => '1' })
    assert status.success?, stderr
    assert_includes stdout, '(2 recording(s), 0 not yet saved)'
    _, stderr, status = run_sync(env: { 'TWO_RECORDINGS' => '1' })
    assert status.success?, stderr
    assert_equal 2, transcript_calls.length
  end

  def test_legacy_event_transcript_is_adopted_not_duplicated
    transcripts = File.join(@dir, 'data/teems/transcripts')
    state = File.join(@dir, 'state/teems')
    FileUtils.mkdir_p([transcripts, state])
    File.write(File.join(transcripts, 'legacy--0123456789.vtt'), FIRST_VTT)
    legacy = Digest::SHA256.hexdigest('2026-09-28:AAMkmeeting')
    File.write(File.join(state, 'transcript-sync.json'),
               JSON.generate('events' => { legacy => { 'file' => 'legacy--0123456789.vtt' } }))

    stdout, stderr, status = run_sync('--dry-run', env: { 'TWO_RECORDINGS' => '1' })
    assert status.success?, stderr
    assert_includes stdout, '(2 recording(s), 1 not yet saved)'

    stdout, stderr, status = run_sync(env: { 'TWO_RECORDINGS' => '1' })
    assert status.success?, stderr
    assert_includes stdout, 'already had legacy--0123456789.vtt'
    assert_equal 2, Dir.glob(File.join(transcripts, '*.vtt')).length
    refute manifest_events.key?(legacy)
    assert_includes manifest_events.values.map { |entry| entry['file'] }, 'legacy--0123456789.vtt'
    assert_equal 2, manifest_events.length
  end

  def test_meeting_without_recordings_is_unavailable
    stdout, stderr, status = run_sync(env: { 'NO_RECORDINGS' => '1' })
    assert status.success?, stderr
    assert_includes stdout, 'unavailable via teems: EERT Brief Prep'
    assert_empty transcript_calls
    assert_empty manifest_events
  end

  def test_initial_run_scans_thirty_days_via_cli
    stdout, stderr, status = Open3.capture3(@env, RbConfig.ruby, SCRIPT, 'transcripts', 'sync', '--dry-run')
    assert status.success?, stderr
    assert_includes stdout, 'Scanning 30 day(s)'
    assert_equal(30, calls.count { |line| line.start_with?('cal ') })
  end

  def test_empty_calendar_is_not_an_error
    _, stderr, status = run_sync(env: { 'NO_EVENTS' => '1' })
    assert status.success?, stderr
    assert_empty manifest_events
  end

  def test_failed_download_advances_the_window_without_hiding_error
    _, stderr, status = run_transcripts('sync', '--since', '1', env: { 'MEETING_FAIL' => '1' })
    assert_equal 1, status.exitstatus
    assert_includes stderr, 'Network unavailable'
    manifest = JSON.parse(File.read(File.join(@dir, 'state/teems/transcript-sync.json')))
    assert_equal Date.today.iso8601, manifest['last_scan_date']
  end

  def test_calendar_error_does_not_mark_full_scan_success
    _, stderr, status = run_transcripts('sync', '--since', '1', env: { 'CAL_FAIL' => '1' })
    assert_equal 1, status.exitstatus
    assert_includes stderr, 'calendar error'
    refute JSON.parse(File.read(File.join(@dir, 'state/teems/transcript-sync.json'))).key?('last_scan_date')
  end

  def test_usage_and_option_errors
    _, stderr, status = run_transcripts('bogus')
    assert_equal 1, status.exitstatus
    assert_includes stderr, 'Usage: teems transcripts sync'
    _, stderr, = run_transcripts('sync', '--since', '0')
    assert_includes stderr, '--since must be between 1 and 366'
    _, stderr, = run_transcripts('sync', '--date', 'not-a-date')
    assert_includes stderr, 'Invalid --date'
    _, _, status = run_transcripts('sync', '--bogus')
    assert_equal 1, status.exitstatus
    assert_empty calls
  end

  def test_lost_manifest_reuses_existing_file
    _, stderr, status = run_sync
    assert status.success?, stderr
    File.delete(File.join(@dir, 'state/teems/transcript-sync.json'))
    stdout, stderr, status = run_sync
    assert status.success?, stderr
    assert_includes stdout, 'saved 2026-09-28 - EERT Brief Prep--'
    assert_equal 1, Dir.glob(File.join(@dir, 'data/teems/transcripts/*.vtt')).length
  end

  def test_legacy_transcript_that_differs_is_kept
    transcripts = File.join(@dir, 'data/teems/transcripts')
    state = File.join(@dir, 'state/teems')
    FileUtils.mkdir_p([transcripts, state])
    File.write(File.join(transcripts, 'legacy--0123456789.vtt'), SECOND_VTT)
    legacy = Digest::SHA256.hexdigest('2026-09-28:AAMkmeeting')
    File.write(File.join(state, 'transcript-sync.json'),
               JSON.generate('events' => { legacy => { 'file' => 'legacy--0123456789.vtt' } }))
    stdout, stderr, status = run_sync
    assert status.success?, stderr
    assert_includes stdout, 'saved 2026-09-28 - EERT Brief Prep--'
    assert manifest_events.key?(legacy)
    assert_equal 2, Dir.glob(File.join(transcripts, '*.vtt')).length
  end

  def test_non_array_calendar_response_is_a_calendar_error
    _, stderr, status = run_sync(env: { 'CAL_OBJECT' => '1' })
    assert_equal 1, status.exitstatus
    assert_includes stderr, 'non-array response'
  end

  def test_quiet_suppresses_progress
    stdout, stderr, status = run_sync('-q')
    assert status.success?, stderr
    assert_empty stdout
  end

  def test_concurrent_sync_is_skipped
    state = File.join(@dir, 'state/teems')
    FileUtils.mkdir_p(state)
    File.open(File.join(state, 'transcript-sync.lock'), File::RDWR | File::CREAT, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      stdout, stderr, status = run_sync
      assert status.success?, stderr
      assert_includes stdout, 'Another transcript sync is running'
    end
    assert_empty calls
  end

  def test_meeting_listing_failure_is_reported
    _, stderr, status = run_sync(env: { 'LIST_FAIL' => '1' })
    assert_equal 1, status.exitstatus
    assert_includes stderr, 'failed: EERT Brief Prep'
    assert_includes stderr, 'Network unavailable'
  end

  def test_markdown_failure_is_reported
    _, stderr, status = run_sync
    assert status.success?, stderr
    markdown = Dir.glob(File.join(@dir, 'data/teems/transcripts-md/*.md')).first
    File.delete(markdown)
    FileUtils.mkdir_p(File.join(markdown, 'blocker'))
    _, stderr, status = run_sync
    assert_equal 1, status.exitstatus
    assert_includes stderr, 'Markdown export failed'
  end

  def test_markdown_titles_and_dates_fall_back_to_filenames
    transcripts = File.join(@dir, 'data/teems/transcripts')
    state = File.join(@dir, 'state/teems')
    FileUtils.mkdir_p([transcripts, state])
    names = ['2026-09-20 - Named Sync--0123456789.vtt', 'Weekly Sync-20260915_140000UTC--abcdef0123.vtt',
             'Adhoc--fedcba9876.vtt']
    names.each { |name| File.write(File.join(transcripts, name), FIRST_VTT) }
    File.write(File.join(state, 'transcript-sync.json'),
               JSON.generate('events' => (names + ['missing--0000000000.vtt']).to_h do |name|
                 [name, { 'file' => name }]
               end))
    _, stderr, status = run_sync(env: { 'NO_EVENTS' => '1' })
    assert status.success?, stderr
    named = File.read(File.join(@dir, 'data/teems/transcripts-md/2026-09-20 - Named Sync--0123456789.md'))
    assert_includes named, 'title: "Named Sync"'
    assert_includes named, 'date: 2026-09-20'
    weekly = File.read(File.join(@dir, 'data/teems/transcripts-md/Weekly Sync-20260915_140000UTC--abcdef0123.md'))
    assert_includes weekly, 'title: "Weekly Sync"'
    assert_includes weekly, 'date: 2026-09-15'
    refute_includes File.read(File.join(@dir, 'data/teems/transcripts-md/Adhoc--fedcba9876.md')), 'date:'
    refute File.exist?(File.join(@dir, 'data/teems/transcripts-md/missing--0000000000.md'))
  end

  def test_lookback_catches_up_after_time_away
    stdout, = run_transcripts('sync', '--dry-run', env: { 'NO_EVENTS' => '1' })
    assert_includes stdout, 'Scanning 30 day(s)'
    state = File.join(@dir, 'state/teems')
    FileUtils.mkdir_p(state)
    manifest = File.join(state, 'transcript-sync.json')
    File.write(manifest, JSON.generate('events' => {}, 'last_scan_date' => (Date.today - 2).iso8601))
    stdout, = run_transcripts('sync', '--dry-run', env: { 'NO_EVENTS' => '1' })
    assert_includes stdout, 'Scanning 7 day(s)'
    File.write(manifest, JSON.generate('events' => {}, 'last_scan_date' => (Date.today - 12).iso8601))
    stdout, = run_transcripts('sync', '--dry-run', env: { 'NO_EVENTS' => '1' })
    assert_includes stdout, 'Scanning 13 day(s)'
  end
end
# rubocop:enable Metrics/MethodLength, Metrics/AbcSize, Metrics/ClassLength
