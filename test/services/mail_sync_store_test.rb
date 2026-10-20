# frozen_string_literal: true

require 'test_helper'
require_relative 'mail_sync_helpers'

class MailSyncStoreTest < Minitest::Test
  include MailSyncTestHelpers

  def test_defaults_follow_xdg
    with_temp_config do |dir|
      assert_equal File.join(dir, 'data', 'teems', 'sync', 'mail'), Teems::Services::MailSyncStore.default_root
      assert_equal File.join(dir, 'state', 'teems'), Teems::Services::MailSyncStore.default_state_dir
      assert_equal Teems::Services::MailSyncStore.default_root, Teems::Services::MailSyncStore.new.root
    end
  end

  def test_missing_index_and_folder_dirs
    with_store do |store|
      refute store.index_exists?('Projects/EERT')
      assert_equal({}, store.load_index('Projects/EERT'))
      assert_equal File.join(store.root, 'Projects-EERT'), store.folder_dir('Projects/EERT')
    end
  end

  def test_a_folder_whose_directory_another_folder_claims_gets_its_own
    with_store do |store|
      store.save_index('Projects/Reports', {})
      suffix = Digest::SHA256.hexdigest('Projects-Reports')[0, 8]

      assert_equal File.join(store.root, "Projects-Reports (#{suffix})"), store.folder_dir('Projects-Reports')
      assert_equal File.join(store.root, 'Projects-Reports'), store.folder_dir('Projects/Reports')
    end
  end

  def test_dot_folder_names_stay_inside_the_root
    with_store do |store|
      %w[. ..].each do |name|
        dir = store.folder_dir(name)

        assert_equal store.root, File.dirname(dir)
        assert_match(/\A\.{1,2} \(\h{8}\)\z/, File.basename(dir))
      end
    end
  end

  def test_index_round_trip
    with_store do |store|
      store.save_index('Projects/EERT', { 'id1' => { 'file' => 'a.md' } })

      assert store.index_exists?('Projects/EERT')
      assert_equal({ 'id1' => { 'file' => 'a.md' } }, store.load_index('Projects/EERT'))
      assert_equal 'Projects/EERT',
                   JSON.parse(File.read(File.join(store.root, 'Projects-EERT', 'index.json')))['folder']
    end
  end

  def test_non_hash_index_and_corrupt_json
    with_store do |store|
      FileUtils.mkdir_p(store.folder_dir('Inbox'))
      path = File.join(store.folder_dir('Inbox'), 'index.json')
      File.write(path, '[]')

      assert_equal({}, store.load_index('Inbox'))
      File.write(path, '{broken')

      assert_equal({}, store.load_index('Inbox'))
      refute_path_exists path
      assert_equal 1, Dir.glob("#{path}.corrupt.*").length
    end
  end

  # A corrupt index that cannot be moved aside is warned about and read as empty
  def test_corrupt_index_that_cannot_be_moved_aside
    with_store do |store|
      dir = FileUtils.mkdir_p(store.folder_dir('Inbox')).first
      File.write(File.join(dir, 'index.json'), '{broken')
      File.chmod(0o500, dir)

      _, stderr = capture_io { assert_equal({}, store.load_index('Inbox')) }
      assert_match(/Could not back up corrupt file .*index.json/, stderr)
    ensure
      File.chmod(0o700, dir)
    end
  end

  def test_write_message_reports_created_updated_unchanged
    with_store do |store|
      assert_equal :created, store.write_message('Inbox', 'a.md', 'one')
      assert_equal :unchanged, store.write_message('Inbox', 'a.md', 'one')
      assert_equal :updated, store.write_message('Inbox', 'a.md', 'two')
      assert_equal 'two', File.read(File.join(store.folder_dir('Inbox'), 'a.md'))
      assert_empty Dir.glob(File.join(store.folder_dir('Inbox'), '*.tmp.*'))
    end
  end

  def test_state_is_kept_per_root
    with_store do |store|
      other = Teems::Services::MailSyncStore.new(root: File.join(@tmp, 'Other'), state_dir: File.join(@tmp, 'state'))
      store.save_state({ 'f1' => { 'delta_link' => 'one' } })
      other.save_state({ 'f1' => { 'delta_link' => 'two' } })

      assert_equal 'one', store.load_state.dig('f1', 'delta_link')
      assert_equal 'two', other.load_state.dig('f1', 'delta_link')
    end
  end

  def test_non_hash_and_empty_state
    with_store do |store|
      FileUtils.mkdir_p(File.join(@tmp, 'state'))
      File.write(File.join(@tmp, 'state', 'mail-sync.json'), '[]')

      assert_equal({}, store.load_state)
      store.save_state({})

      assert_equal({}, store.load_state)
    end
  end

  def test_with_lock
    with_store do |store|
      assert_equal(:ran, store.with_lock { :ran })
      File.open(File.join(@tmp, 'state', 'mail-sync.lock'), File::RDWR) do |held|
        held.flock(File::LOCK_EX)

        assert_equal(:locked, store.with_lock { flunk 'should not run' })
      end
    end
  end
end
