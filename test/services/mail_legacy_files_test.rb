# frozen_string_literal: true

require 'test_helper'
require_relative 'mail_sync_helpers'

class MailLegacyFilesTest < Minitest::Test
  include MailSyncTestHelpers

  def legacy_files(store, **) = Teems::Services::MailLegacyFiles.new(store.folder_dir('Inbox'), **)

  def test_matches_on_local_received_time_and_subject
    with_tz do
      with_store do |store|
        write_legacy(store, 'Inbox', 'old.md', id: 4512, subject: 'Quarterly "report" Q3',
                                               date: "Tuesday, October 20, 2026 at 9:05:09\u202fAM")
        legacy = legacy_files(store)

        assert_nil legacy.match(mail('x', 'subject' => 'Different'))
        assert_equal 'old.md', legacy.match(mail('x', 'receivedDateTime' => '2026-10-20T14:05:10Z'))
        assert_nil legacy.match(mail('y')), 'each legacy file is claimed once'
      end
    end
  end

  BURST = 'Tuesday, October 20, 2026 at 9:05:'

  # Two auto-replies a second apart from different people, as a mass email produces
  def write_burst(store)
    write_legacy(store, 'Inbox', 'carol.md', id: 1, subject: 'Automatic reply: OOO', date: "#{BURST}09 AM",
                                             from: 'Carol, C. (Contractor) <Carol@example.com>')
    write_legacy(store, 'Inbox', 'dave.md', id: 2, subject: 'Automatic reply: OOO', date: "#{BURST}10 AM",
                                            from: 'dave@example.com')
  end

  def auto_reply(id, address, second)
    mail(id, 'subject' => 'Automatic reply: OOO', 'receivedDateTime' => "2026-10-20T14:05:#{second}Z",
             'from' => { 'emailAddress' => { 'name' => 'Someone', 'address' => address } })
  end

  def test_sender_must_match_when_both_sides_have_one
    with_tz do
      with_store do |store|
        write_burst(store)
        legacy = legacy_files(store)

        assert_nil legacy.match(auto_reply('w', 'wil@example.com', '09')), 'same second and subject, other sender'
        assert_equal 'dave.md', legacy.match(auto_reply('d', 'Dave@Example.com', '09'))
        assert_equal 'carol.md', legacy.match(auto_reply('c', 'carol@example.com', '10'))
      end
    end
  end

  def test_exact_second_first_and_missing_senders_match_anyone
    with_tz do
      with_store do |store|
        write_legacy(store, 'Inbox', 'early.md', id: 1, subject: 'Hi', date: "#{BURST}09 AM", from: 'Carol')
        write_legacy(store, 'Inbox', 'exact.md', id: 2, subject: 'Hi', date: "#{BURST}10 AM")
        legacy = legacy_files(store)

        at = '2026-10-20T14:05:10Z'

        assert_equal 'exact.md', legacy.match(mail('a', 'subject' => 'Hi', 'receivedDateTime' => at))
        assert_equal 'early.md', legacy.match(mail('b', 'subject' => 'Hi', 'receivedDateTime' => at, 'from' => nil))
      end
    end
  end

  ODD_FRONTMATTER = <<~MD
    ---
    id: 7
    cc:

    subject: Plain subject
    date: "Tuesday, October 20, 2026 at 9:05:09 AM"
    ---
  MD

  def test_frontmatter_with_blank_and_empty_lines
    with_tz do
      with_store do |store|
        dir = FileUtils.mkdir_p(store.folder_dir('Inbox')).first
        File.write(File.join(dir, 'odd.md'), ODD_FRONTMATTER)

        assert_equal 'odd.md', legacy_files(store).match(mail('x', 'subject' => 'Plain subject'))
      end
    end
  end

  def test_files_with_graph_ids_are_not_legacy
    with_store do |store|
      write_legacy(store, 'Inbox', 'graph.md', id: 'AAkALnotlegacy', subject: 'Quarterly report: Q3',
                                               date: 'Tuesday, October 20, 2026 at 9:05:09 AM')

      assert_equal 0, legacy_files(store).count
    end
  end

  def test_other_date_formats
    with_tz do
      with_store do |store|
        write_legacy(store, 'Inbox', 'a.md', id: 1, subject: 'A', date: 'October 20, 2026 at 9:05:09 AM')
        write_legacy(store, 'Inbox', 'b.md', id: 2, subject: 'B', date: '10/20/2026 9:05:09 AM')
        legacy = legacy_files(store)

        assert_equal 'a.md', legacy.match(mail('x', 'subject' => 'a'))
        assert_equal 'b.md', legacy.match(mail('x', 'subject' => 'b'))
        assert_nil legacy.match(mail('x', 'receivedDateTime' => nil))
      end
    end
  end

  def test_skips_known_files_bad_dates_and_files_without_frontmatter
    with_store do |store|
      write_legacy(store, 'Inbox', 'c.md', id: 3, subject: 'C', date: 'not a date')
      write_legacy(store, 'Inbox', 'd.md', id: 4, subject: 'D', date: '10/20/2026 9:05:09 AM')
      File.write(File.join(store.folder_dir('Inbox'), 'e.md'), "no frontmatter\n")

      assert_equal 0, legacy_files(store, known_files: ['d.md']).count
    end
  end
end
