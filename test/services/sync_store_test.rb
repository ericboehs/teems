# frozen_string_literal: true

require 'test_helper'

# Tests for SyncStore state persistence, directory naming, message storage, and corruption handling
module SyncStoreTests
  # The directory name a chat syncs into after SyncStore#ensure_chat_dir
  module DirNameHelper
    def ensure_dir_name(store, state, chat_info:)
      store.ensure_chat_dir(state, chat_info: chat_info)
      state.dig('chats', chat_info[:chat_id], 'dir_name')
    end
  end

  # Tests sync directory paths, state save/load, chat state updates, and atomic writes
  class BasicTest < Minitest::Test
    def test_sync_dir_uses_xdg_data_home
      with_temp_config do |dir|
        store = Teems::Services::SyncStore.new
        assert_equal "#{dir}/data/teems/sync", store.sync_dir
      end
    end

    def test_load_state_returns_empty_hash_when_no_file
      with_temp_config do
        assert_equal({}, Teems::Services::SyncStore.new.load_state)
      end
    end

    def test_save_and_load_state
      with_temp_config do
        store = Teems::Services::SyncStore.new
        state = { 'chats' => { 'chat1' => { 'last_synced_at' => '2026-01-20T12:00:00+00:00' } } }
        store.save_state(state)
        assert_equal state, store.load_state
      end
    end

    def test_load_state_handles_corrupt_json
      with_temp_config do
        store = Teems::Services::SyncStore.new
        sync_dir = store.sync_dir
        FileUtils.mkdir_p(sync_dir)
        File.write(File.join(sync_dir, 'sync_state.json'), 'not json{{{')
        assert_equal({}, store.load_state)
      end
    end

    def test_last_synced_time_returns_nil_for_unknown_chat
      with_temp_config do
        assert_nil Teems::Services::SyncStore.new.last_synced_time({}, 'unknown_chat')
      end
    end

    def test_last_synced_time_returns_time_object
      with_temp_config do
        state = { 'chats' => { 'chat1' => { 'last_synced_at' => '2026-01-20T12:00:00+00:00' } } }
        result = Teems::Services::SyncStore.new.last_synced_time(state, 'chat1')
        assert_instance_of Time, result
        assert_equal 2026, result.year
        assert_equal 1, result.month
        assert_equal 20, result.day
      end
    end

    def test_update_chat_state
      with_temp_config do
        store = Teems::Services::SyncStore.new
        state = {}
        now = Time.now
        store.update_chat_state(state, 'chat1',
                                attrs: { last_synced_at: now, message_count: 42, display_name: 'Test Chat' })
        chat = state.dig('chats', 'chat1')
        assert_equal now.iso8601, chat['last_synced_at']
        assert_equal 42, chat['message_count']
      end
    end

    def test_chat_dir_sanitizes_colons_and_at_signs
      with_temp_config do
        dir = Teems::Services::SyncStore.new.chat_dir('19:abc123@thread.v2')
        assert_includes dir, 'other/19_abc123_thread.v2'
        refute_includes dir, ':'
        refute_includes dir, '@'
      end
    end

    def test_atomic_write_does_not_leave_tmp_files
      with_temp_config do
        store = Teems::Services::SyncStore.new
        store.save_state({ 'test' => true })
        refute File.exist?(File.join(store.sync_dir, 'sync_state.json.tmp'))
      end
    end
  end

  # Tests message file writing, reading, metadata persistence, and corrupt JSON recovery
  class MessagesTest < Minitest::Test
    def test_write_messages_creates_files
      with_temp_config do
        store = Teems::Services::SyncStore.new
        chat_id = '19:test@thread.v2'
        store.write_messages(chat_id, messages_md: '# Test\n\nHello world',
                                      messages_json: '[{"id":"1","content":"hello"}]')
        assert_messages_files_exist(store, chat_id)
      end
    end

    def test_write_chat_metadata_creates_file
      with_temp_config do
        store = Teems::Services::SyncStore.new
        chat_id = '19:test@thread.v2'
        store.write_chat_metadata(chat_id, { 'id' => chat_id, 'display_name' => 'Test Chat', 'type' => 'group' })
        loaded = JSON.parse(File.read(File.join(store.chat_dir(chat_id), 'chat_metadata.json')))
        assert_equal chat_id, loaded['id']
        assert_equal 'Test Chat', loaded['display_name']
      end
    end

    def test_read_messages_json_returns_empty_array_when_no_file
      with_temp_config do
        assert_equal [], Teems::Services::SyncStore.new.read_messages_json('nonexistent')
      end
    end

    def test_read_messages_json_returns_parsed_data
      with_temp_config do
        store = Teems::Services::SyncStore.new
        chat_id = '19:test@thread.v2'
        messages = [{ 'id' => '1', 'content' => 'hello' }]
        store.write_messages(chat_id, messages_md: '# Test', messages_json: JSON.generate(messages))
        assert_equal messages, store.read_messages_json(chat_id)
      end
    end

    def test_read_messages_json_handles_corrupt_json
      with_temp_config do
        store = Teems::Services::SyncStore.new
        chat_id = '19:test@thread.v2'
        store.write_messages(chat_id, messages_md: '# Test', messages_json: 'not json{{{')
        assert_equal [], store.read_messages_json(chat_id)
      end
    end

    private

    def assert_messages_files_exist(store, chat_id)
      dir = store.chat_dir(chat_id)
      messages_md_path = File.join(dir, 'messages.md')
      assert File.exist?(messages_md_path)
      assert File.exist?(File.join(dir, 'messages.json'))
      assert_equal '# Test\n\nHello world', File.read(messages_md_path)
    end
  end

  # Tests marking chats as unavailable and checking unavailability status
  class UnavailableTest < Minitest::Test
    def test_mark_unavailable_sets_flag
      with_temp_config do
        store = Teems::Services::SyncStore.new
        state = {}
        store.mark_unavailable(state, 'chat1', display_name: 'Dead Chat')
        assert state.dig('chats', 'chat1', 'unavailable')
        assert state.dig('chats', 'chat1', 'unavailable_at')
        assert_equal 'Dead Chat', state.dig('chats', 'chat1', 'display_name')
      end
    end

    def test_chat_unavailable_returns_true_for_marked_chats
      with_temp_config do
        state = { 'chats' => { 'chat1' => { 'unavailable' => true } } }
        assert Teems::Services::SyncStore.new.chat_unavailable?(state, 'chat1')
      end
    end

    def test_chat_unavailable_returns_false_for_normal_chats
      with_temp_config do
        state = { 'chats' => { 'chat1' => { 'last_synced_at' => '2026-01-20T12:00:00+00:00' } } }
        refute Teems::Services::SyncStore.new.chat_unavailable?(state, 'chat1')
      end
    end

    def test_chat_unavailable_returns_false_for_unknown_chats
      with_temp_config do
        refute Teems::Services::SyncStore.new.chat_unavailable?({}, 'unknown')
      end
    end

    def test_mark_unavailable_preserves_existing_state
      with_temp_config do
        store = Teems::Services::SyncStore.new
        state = { 'chats' => { 'chat1' => { 'last_synced_at' => '2026-01-20T12:00:00+00:00', 'message_count' => 5 } } }
        store.mark_unavailable(state, 'chat1', display_name: 'Dead Chat')
        assert state.dig('chats', 'chat1', 'unavailable')
        assert_equal '2026-01-20T12:00:00+00:00', state.dig('chats', 'chat1', 'last_synced_at')
        assert_equal 5, state.dig('chats', 'chat1', 'message_count')
      end
    end
  end

  # Tests directory name sanitization, generic label suffixes, truncation, and fallback naming
  class DirNamingTest < Minitest::Test
    include DirNameHelper

    def test_build_dir_name_sanitizes_unsafe_chars
      with_temp_config do
        store = Teems::Services::SyncStore.new
        state = { 'chats' => {} }
        dir_name = ensure_dir_name(store, state,
                                   chat_info: { chat_id: '19:abc@thread.v2',
                                                display_name: 'Project: Design/Review <Q1>' })
        assert_equal 'Project- Design-Review -Q1- (19_abc_thread.v2)', dir_name
        %w[: / < >].each { |ch| refute_includes dir_name, ch }
      end
    end

    def test_generic_labels_get_id_suffix
      with_temp_config do
        store = Teems::Services::SyncStore.new
        state = { 'chats' => {} }
        ['Group Chat', '1:1 Chat', 'Meeting Chat'].each do |label|
          dir_name = ensure_dir_name(store, state,
                                     chat_info: { chat_id: '19:abc123def456@thread.v2',
                                                  display_name: label })
          assert_match(/\(19_abc123def456_thread\.v2\)\z/, dir_name, "#{label} should end with the full ID")
        end
      end
    end

    def test_named_topics_end_with_full_id
      with_temp_config do
        state = { 'chats' => {} }
        dir_name = ensure_dir_name(
          Teems::Services::SyncStore.new, state, chat_info: { chat_id: '19:abc@thread.v2', display_name: 'EERT Sprint Planning' }
        )
        assert_equal 'EERT Sprint Planning (19_abc_thread.v2)', dir_name
      end
    end

    def test_null_display_name_falls_back_to_sanitized_id
      with_temp_config do
        state = { 'chats' => {} }
        dir_name = ensure_dir_name(
          Teems::Services::SyncStore.new, state, chat_info: { chat_id: '19:abc@thread.v2', display_name: nil }
        )
        assert_equal '19_abc_thread.v2', dir_name
      end
    end

    def test_chat_dir_uses_state_dir_name
      with_temp_config do
        state = { 'chats' => { '19:abc@thread.v2' => { 'dir_name' => 'My Cool Chat', 'chat_type' => 'group' } } }
        dir = Teems::Services::SyncStore.new.chat_dir('19:abc@thread.v2', state: state)
        assert dir.end_with?('chats/groups/My Cool Chat')
      end
    end

    def test_chat_dir_falls_back_without_state
      with_temp_config do
        dir = Teems::Services::SyncStore.new.chat_dir('19:abc@thread.v2')
        assert dir.end_with?('chats/other/19_abc_thread.v2')
      end
    end

    def test_long_display_name_is_truncated
      with_temp_config do
        state = { 'chats' => {} }
        dir_name = ensure_dir_name(
          Teems::Services::SyncStore.new, state, chat_info: { chat_id: '19:abc@thread.v2', display_name: 'A' * 200 }
        )
        assert_equal "#{'A' * Teems::Services::SyncStore::MAX_DIR_NAME_LENGTH} (19_abc_thread.v2)", dir_name
      end
    end

    def test_trailing_dots_and_spaces_stripped_from_dir_name
      with_temp_config do
        state = { 'chats' => {} }
        dir_name = ensure_dir_name(
          Teems::Services::SyncStore.new, state, chat_info: { chat_id: '19:abc@thread.v2', display_name: 'My Chat...' }
        )
        assert_equal 'My Chat (19_abc_thread.v2)', dir_name
      end
    end
  end

  # Tests directory renaming on topic or type change and collision avoidance
  class DirRenamingTest < Minitest::Test
    include DirNameHelper

    def test_ensure_dir_name_renames_on_topic_change
      with_temp_config do
        chat_id = '19:abc@thread.v2'
        store, state = build_store_with_state(chat_id, dir_name: 'Old Topic', chat_type: 'group')
        make_chat_dir(store, 'groups', 'Old Topic')
        sync_dir = store.sync_dir
        info = { chat_id: chat_id, display_name: 'New Topic', chat_type: 'group' }
        assert_equal 'New Topic (19_abc_thread.v2)', ensure_dir(store, state, info)
        assert File.directory?(File.join(sync_dir, 'chats', 'groups', 'New Topic (19_abc_thread.v2)'))
        refute File.directory?(File.join(sync_dir, 'chats', 'groups', 'Old Topic'))
      end
    end

    def test_ensure_dir_name_moves_dir_on_type_change
      with_temp_config do
        chat_id = '19:abc@thread.v2'
        store, state = build_store_with_state(chat_id, dir_name: 'Sprint Planning', chat_type: 'group')
        old_dir = make_chat_dir(store, 'groups', 'Sprint Planning')
        ensure_dir(store, state, { chat_id: chat_id, display_name: 'Sprint Planning', chat_type: 'meeting' })
        assert File.directory?(File.join(store.sync_dir, 'chats', 'meetings', 'Sprint Planning (19_abc_thread.v2)'))
        refute File.directory?(old_dir), 'Old groups/ directory should not exist'
        assert_equal 'meeting', state.dig('chats', chat_id, 'chat_type')
      end
    end

    def test_update_chat_state_stores_dir_name
      with_temp_config do
        chat_state = update_and_load_chat_state('chat1',
                                                display_name: 'My Project Chat', chat_type: 'group')
        assert_equal 'My Project Chat (chat1)', chat_state['dir_name']
        assert_equal 'group', chat_state['chat_type']
      end
    end

    def test_write_and_read_messages_with_state
      with_temp_config do
        chat_id = '19:test@thread.v2'
        store, state = build_store_with_state(chat_id, dir_name: 'Human Readable Name', chat_type: 'group')
        messages = [{ 'id' => '1', 'content' => 'hello' }]
        store.write_messages(chat_id, messages_md: '# Test', messages_json: JSON.generate(messages), state: state)
        dir = store.chat_dir(chat_id, state: state)
        assert_includes dir, 'chats/groups/Human Readable Name'
        assert File.exist?(File.join(dir, 'messages.json'))
        assert_equal messages, store.read_messages_json(chat_id, state: state)
      end
    end

    def test_rename_collision_does_not_overwrite_existing_dir
      with_temp_config do
        store, state = build_store_with_state('19:abc@thread.v2', dir_name: 'Old Name', chat_type: 'group')
        old_dir, new_dir = setup_collision_dirs(store)
        ensure_dir_name(
          store, state, chat_info: { chat_id: '19:abc@thread.v2', display_name: 'New Name', chat_type: 'group' }
        )
        assert File.directory?(old_dir), 'Old dir should still exist since rename was skipped'
        assert_equal '# Existing content', File.read(File.join(new_dir, 'messages.md'))
      end
    end

    private

    def ensure_dir(store, state, chat_info)
      ensure_dir_name(store, state, chat_info: chat_info)
    end

    def update_and_load_chat_state(chat_id, display_name:, chat_type:)
      store = Teems::Services::SyncStore.new
      state = {}
      store.update_chat_state(state, chat_id,
                              attrs: { last_synced_at: Time.now, message_count: 42,
                                       display_name: display_name, chat_type: chat_type })
      state['chats'][chat_id]
    end

    def build_store_with_state(chat_id, dir_name:, chat_type:)
      store = Teems::Services::SyncStore.new
      state = { 'chats' => { chat_id => { 'dir_name' => dir_name, 'chat_type' => chat_type } } }
      [store, state]
    end

    def make_chat_dir(store, type_subdir, name)
      dir = File.join(store.sync_dir, 'chats', type_subdir, name)
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, 'messages.md'), '# Test')
      dir
    end

    def setup_collision_dirs(store)
      sync_dir = store.sync_dir
      old_dir = File.join(sync_dir, 'chats', 'groups', 'Old Name')
      new_dir = File.join(sync_dir, 'chats', 'groups', 'New Name (19_abc_thread.v2)')
      FileUtils.mkdir_p(old_dir)
      FileUtils.mkdir_p(new_dir)
      File.write(File.join(old_dir, 'messages.md'), '# Old content')
      File.write(File.join(new_dir, 'messages.md'), '# Existing content')
      [old_dir, new_dir]
    end
  end

  # Tests corrupt JSON backup and recovery for state and message files
  class CorruptDataTest < Minitest::Test
    def test_corrupt_state_backs_up_file
      with_temp_config do
        store = Teems::Services::SyncStore.new
        state_path = write_corrupt_state_file(store)
        assert_equal({}, store.load_state)
        refute File.exist?(state_path), 'Corrupt file should be moved to backup'
        assert_equal 1, corrupt_backups(store).length, 'Should have one backup file'
      end
    end

    def test_corrupt_messages_json_backs_up_file
      with_temp_config do
        store = Teems::Services::SyncStore.new
        chat_id = '19:test@thread.v2'
        store.write_messages(chat_id, messages_md: '# Test', messages_json: 'not json{{{')
        assert_equal [], store.read_messages_json(chat_id)
        dir = store.chat_dir(chat_id)
        refute File.exist?(File.join(dir, 'messages.json')), 'Corrupt file should be moved to backup'
        backups = Dir.glob(File.join(dir, 'messages.json.corrupt.*'))
        assert_equal 1, backups.length, 'Should have one backup file'
      end
    end

    private

    def write_corrupt_state_file(store)
      sync_dir = store.sync_dir
      FileUtils.mkdir_p(sync_dir)
      state_path = File.join(sync_dir, 'sync_state.json')
      File.write(state_path, 'not valid json{{{')
      state_path
    end

    def corrupt_backups(store)
      Dir.glob(File.join(store.sync_dir, 'sync_state.json.corrupt.*'))
    end
  end

  # Tests chat type to subdirectory mapping and type storage in state
  class TypeSubdirectoryTest < Minitest::Test
    include DirNameHelper

    TYPE_TO_SUBDIR = {
      'group' => 'groups', 'oneOnOne' => 'dms', 'meeting' => 'meetings',
      'channel' => 'channels', 'space' => 'spaces'
    }.freeze

    def test_chat_dir_includes_type_subdirectory
      with_temp_config do
        store = Teems::Services::SyncStore.new
        TYPE_TO_SUBDIR.each do |chat_type, subdir|
          state = { 'chats' => { '19:abc@thread.v2' => { 'dir_name' => 'Some Chat', 'chat_type' => chat_type } } }
          dir = store.chat_dir('19:abc@thread.v2', state: state)
          assert_includes dir, "chats/#{subdir}/Some Chat",
                          "chat_type '#{chat_type}' should use '#{subdir}/' subdirectory"
        end
      end
    end

    def test_unknown_chat_type_uses_other_dir
      with_temp_config do
        store = Teems::Services::SyncStore.new
        [nil, 'unknown', 'something_else'].each do |chat_type|
          state = { 'chats' => { '19:abc@thread.v2' => { 'dir_name' => 'Some Chat', 'chat_type' => chat_type } } }
          dir = store.chat_dir('19:abc@thread.v2', state: state)
          assert_includes dir, 'chats/other/Some Chat',
                          "chat_type #{chat_type.inspect} should use 'other/' subdirectory"
        end
      end
    end

    def test_type_dir_mapping
      assert_equal 'dms', Teems::Services::SyncDirNaming.type_dir('oneOnOne')
      assert_equal 'groups', Teems::Services::SyncDirNaming.type_dir('group')
      assert_equal 'meetings', Teems::Services::SyncDirNaming.type_dir('meeting')
      assert_equal 'channels', Teems::Services::SyncDirNaming.type_dir('channel')
      assert_equal 'spaces', Teems::Services::SyncDirNaming.type_dir('space')
      assert_equal 'other', Teems::Services::SyncDirNaming.type_dir(nil)
      assert_equal 'other', Teems::Services::SyncDirNaming.type_dir('unknown')
    end

    def test_update_chat_state_stores_chat_type
      with_temp_config do
        store = Teems::Services::SyncStore.new
        state = {}
        store.update_chat_state(state, 'chat1',
                                attrs: { last_synced_at: Time.now, message_count: 10,
                                         display_name: 'DM Chat', chat_type: 'oneOnOne' })
        assert_equal 'oneOnOne', state['chats']['chat1']['chat_type']
      end
    end

    def test_mark_unavailable_stores_chat_type
      with_temp_config do
        store = Teems::Services::SyncStore.new
        state = {}
        store.mark_unavailable(state, 'chat1', display_name: 'Dead Chat', chat_type: 'meeting')
        assert_equal 'meeting', state.dig('chats', 'chat1', 'chat_type')
      end
    end

    def test_ensure_dir_name_stores_chat_type_in_state
      with_temp_config do
        state = { 'chats' => {} }
        ensure_dir_name(
          Teems::Services::SyncStore.new, state, chat_info: { chat_id: '19:abc@thread.v2', display_name: 'My Chat', chat_type: 'group' }
        )
        assert_equal 'group', state.dig('chats', '19:abc@thread.v2', 'chat_type')
      end
    end

    def test_mark_unavailable_without_display_name
      with_temp_config do
        state = {}
        Teems::Services::SyncStore.new.mark_unavailable(state, 'chat1')
        assert state.dig('chats', 'chat1', 'unavailable')
      end
    end

    def test_mark_unavailable_without_chat_type
      with_temp_config do
        state = {}
        Teems::Services::SyncStore.new.mark_unavailable(state, 'chat1', display_name: 'Test')
        assert state.dig('chats', 'chat1', 'unavailable')
        assert_nil state.dig('chats', 'chat1', 'chat_type')
      end
    end
  end

  # Tests SyncDirNaming module methods for sanitization, generic labels, and type mapping
  class SyncDirNamingModuleTest < Minitest::Test
    include Teems::Services::SyncDirNaming

    def test_sanitize_display_name_empty_after_cleanup
      assert_nil sanitize_display_name('...')
    end

    def test_build_dir_name_generic_label_appends_id
      result = build_dir_name('19:abc@thread.v2', 'Group Chat')
      assert_includes result, 'Group Chat'
      assert_includes result, '19_abc_thread.v2'
    end

    def test_build_dir_name_nil_display_name
      assert_equal '19_abc_thread.v2', build_dir_name('19:abc@thread.v2', nil)
    end

    def test_build_dir_name_non_generic_label
      assert_equal 'My Project Chat (19_abc_thread.v2)', build_dir_name('19:abc@thread.v2', 'My Project Chat')
    end

    def test_type_dir_unknown
      assert_equal 'other', type_dir('unknown_type')
    end

    def test_type_dir_known
      assert_equal 'groups', type_dir('group')
      assert_equal 'meetings', type_dir('meeting')
      assert_equal 'dms', type_dir('oneOnOne')
    end
  end

  # Tests bad timestamp handling and corrupt state file backup with rename errors
  class TimestampAndBackupTest < Minitest::Test
    def test_last_synced_time_returns_nil_on_bad_timestamp
      with_temp_config do
        store = Teems::Services::SyncStore.new
        state = { 'chats' => { 'chat1' => { 'last_synced_at' => 'not-a-timestamp' } } }

        assert_nil store.last_synced_time(state, 'chat1')
      end
    end

    def test_backup_corrupt_state_file
      with_temp_config do
        store = Teems::Services::SyncStore.new
        write_corrupt_state(store)

        assert_equal({}, store.load_state)
        corrupt_files = Dir.glob(File.join(store.sync_dir, 'sync_state.json.corrupt.*'))
        assert_equal 1, corrupt_files.length
      end
    end

    def test_backup_corrupt_file_handles_rename_error
      with_temp_config do
        store = Teems::Services::SyncStore.new
        write_corrupt_state_readonly(store)
        assert_equal({}, store.load_state)
      ensure
        File.chmod(0o755, store.sync_dir) if store
      end
    end

    private

    def write_corrupt_state(store)
      sync_dir = store.sync_dir
      FileUtils.mkdir_p(sync_dir)
      File.write(File.join(sync_dir, 'sync_state.json'), 'bad json')
    end

    def write_corrupt_state_readonly(store)
      write_corrupt_state(store)
      File.chmod(0o000, store.sync_dir)
    end
  end

  # Every chat gets its own directory, keyed by its full ID
  class DirUniquenessTest < Minitest::Test
    include DirNameHelper

    # 1:1 chat IDs embed both users' IDs, so every DM with the same person first shares a long prefix
    ME = '11111111-2222-3333-4444-555555555555'
    DM_A = "19:#{ME}_aaaaaaaa-0000-0000-0000-000000000001@unq.gbl.spaces".freeze
    DM_B = "19:#{ME}_bbbbbbbb-0000-0000-0000-000000000002@unq.gbl.spaces".freeze

    def test_chats_sharing_a_long_id_prefix_get_distinct_dirs
      with_temp_config do
        store = Teems::Services::SyncStore.new
        state = {}
        dirs = [DM_A, DM_B].map { |id| dir_for(store, state, id, 'Group Chat', 'group') }
        refute_equal dirs.first, dirs.last
        assert dirs.first.end_with?("Group Chat (19_#{ME}_aaaaaaaa-0000-0000-0000-000000000001_unq.gbl.spaces)")
      end
    end

    def test_chats_with_the_same_title_get_distinct_dirs
      with_temp_config do
        store = Teems::Services::SyncStore.new
        state = {}
        dirs = %w[19:meeting_one@thread.v2 19:meeting_two@thread.v2].map do |id|
          dir_for(store, state, id, 'Team Standup', 'meeting')
        end
        refute_equal dirs.first, dirs.last
      end
    end

    def test_multibyte_title_is_trimmed_to_the_filesystem_limit
      with_temp_config do
        dir_name = File.basename(dir_for(Teems::Services::SyncStore.new, {}, DM_A, "\u{1F600}" * 100, 'oneOnOne'))
        assert_operator dir_name.bytesize, :<=, Teems::Services::SyncStore::MAX_DIR_NAME_BYTES
        assert dir_name.valid_encoding?
        assert dir_name.end_with?('_unq.gbl.spaces)')
      end
    end

    def test_ids_differing_only_in_case_get_distinct_dirs
      with_temp_config do
        store = Teems::Services::SyncStore.new
        state = {}
        upper, lower = %w[19:meeting_AbC@thread.v2 19:meeting_abc@thread.v2].map do |id|
          File.basename(dir_for(store, state, id, 'Team Standup', 'meeting'))
        end
        assert_equal 'Team Standup (19_meeting_AbC_thread.v2)', upper
        assert_match(/\A19_meeting_abc_thread\.v2-\h{8}\z/, lower)
      end
    end

    def test_state_updates_keep_the_dir_name_from_ensure_dir_name
      with_temp_config do
        store = Teems::Services::SyncStore.new
        state = { 'chats' => { DM_A => { 'dir_name' => 'Chosen Name', 'chat_type' => 'oneOnOne' } } }
        store.update_chat_state(state, DM_A, attrs: { last_synced_at: Time.now, message_count: 1,
                                                      display_name: 'Other', chat_type: 'oneOnOne' })
        store.mark_unavailable(state, DM_A, display_name: 'Other')
        assert_equal 'Chosen Name', state.dig('chats', DM_A, 'dir_name')
      end
    end

    private

    def dir_for(store, state, chat_id, display_name, chat_type)
      ensure_dir_name(store, state, chat_info: { chat_id: chat_id, display_name: display_name, chat_type: chat_type })
      store.chat_dir(chat_id, state: state)
    end
  end

  # Two 1:1 chats an older version put in one folder, plus a chat with a folder of its own
  module SharedDirFixtures
    SHARED = 'Group Chat (19_11111111-2222-333)'
    DM_A = DirUniquenessTest::DM_A
    DM_B = DirUniquenessTest::DM_B

    private

    def legacy_state
      synced = { 'chat_type' => 'group', 'last_synced_at' => '2026-01-20T12:00:00Z' }
      { 'chats' => { DM_A => synced.merge('dir_name' => SHARED), DM_B => synced.merge('dir_name' => SHARED),
                     '19:unique@thread.v2' => synced.merge('dir_name' => 'Unique Chat (19_unique_thread.v2)') } }
    end

    def seed_shared_dir(store)
      dir = File.join(store.sync_dir, 'chats', 'groups', SHARED)
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, 'messages.json'),
                 JSON.generate([{ 'id' => 'legacy-2', 'created_at' => '2025-06-01T08:00:00Z' },
                                { 'id' => 'legacy-1', 'created_at' => '2025-02-01T08:00:00Z' }, 'junk']))
      File.write(File.join(dir, 'messages.md'), '# legacy')
      [dir, dir_snapshot(dir)]
    end

    def dir_snapshot(dir)
      Dir.children(dir).sort.to_h { |name| [name, File.binread(File.join(dir, name))] }
    end

    def with_detached_state
      with_temp_config do
        store = Teems::Services::SyncStore.new
        state = legacy_state
        shared_dir, = seed_shared_dir(store)
        store.detach_shared_dirs(state)
        yield store, state, shared_dir
      end
    end
  end

  # Directories that older versions gave to more than one chat are detected and detached
  class SharedDirsTest < Minitest::Test
    include DirNameHelper
    include SharedDirFixtures

    def test_shared_dirs_lists_dirs_used_by_more_than_one_chat
      store = Teems::Services::SyncStore.new
      assert_equal({ "groups/#{SHARED}" => [DM_A, DM_B] }, store.shared_dirs(legacy_state))
    end

    def test_shared_dirs_ignores_letter_case
      synced = { 'chat_type' => 'meeting', 'message_count' => 1 }
      state = { 'chats' => { 'a' => synced.merge('dir_name' => 'Standup'),
                             'b' => synced.merge('dir_name' => 'standup') } }
      assert_equal({ 'meetings/Standup' => %w[a b] }, Teems::Services::SyncStore.new.shared_dirs(state))
    end

    def test_never_synced_chats_do_not_count_as_owners
      state = legacy_state
      state['chats'][DM_B] = { 'dir_name' => SHARED, 'chat_type' => 'group', 'unavailable' => true }
      assert_empty Teems::Services::SyncStore.new.shared_dirs(state)
    end

    def test_chats_with_a_cleared_cursor_still_count_as_owners
      state = legacy_state
      state['chats'][DM_B] = state['chats'][DM_B].except('last_synced_at').merge('message_count' => 3)
      assert_equal({ "groups/#{SHARED}" => [DM_A, DM_B] }, Teems::Services::SyncStore.new.shared_dirs(state))
    end

    def test_detach_leaves_files_untouched_and_resets_cursors
      with_temp_config do
        store = Teems::Services::SyncStore.new
        state = legacy_state
        shared_dir, snapshot = seed_shared_dir(store)
        store.detach_shared_dirs(state)
        assert_equal snapshot, dir_snapshot(shared_dir)
        assert_detached state.dig('chats', DM_A)
        assert_equal 'Unique Chat (19_unique_thread.v2)', state.dig('chats', '19:unique@thread.v2', 'dir_name')
        assert_empty store.detach_shared_dirs(state)
      end
    end

    def test_detached_chats_never_move_the_shared_dir
      with_temp_config do
        store = Teems::Services::SyncStore.new
        state = legacy_state
        shared_dir, snapshot = seed_shared_dir(store)
        store.detach_shared_dirs(state)
        dirs = [DM_A, DM_B].map { |id| ensure_dm(store, state, id) }
        assert_equal snapshot, dir_snapshot(shared_dir)
        assert_equal 3, (dirs + [shared_dir]).uniq.length, 'each chat needs its own new folder'
      end
    end

    private

    def ensure_dm(store, state, chat_id)
      ensure_dir_name(store, state, chat_info: { chat_id: chat_id, display_name: '1:1 Chat', chat_type: 'oneOnOne' })
      store.chat_dir(chat_id, state: state)
    end

    def assert_detached(entry)
      assert_nil entry['dir_name']
      assert_nil entry['last_synced_at']
      assert_equal "groups/#{SHARED}", entry['legacy_shared_dir']
    end
  end

  # Detached chats keep enough history to re-sync fully, and their old folders stay on record
  class SharedDirHistoryTest < Minitest::Test
    include SharedDirFixtures

    def test_detach_only_one_chat_still_detaches_the_others_later
      with_temp_config do
        store = Teems::Services::SyncStore.new
        state = legacy_state
        assert_equal({ "groups/#{SHARED}" => [DM_A] }, store.detach_shared_dirs(state, only: DM_A))
        assert_equal SHARED, state.dig('chats', DM_B, 'dir_name')
        assert_empty store.detach_shared_dirs(state, only: '19:unique@thread.v2')
        assert_equal({ "groups/#{SHARED}" => [DM_B] }, store.detach_shared_dirs(state))
      end
    end

    def test_resync_starts_at_the_oldest_message_in_the_shared_dir
      with_detached_state do |store, state|
        assert_equal Time.parse('2025-02-01T08:00:00Z'), store.resync_from(state, DM_A)
        store.update_chat_state(state, DM_A, attrs: { last_synced_at: Time.now, message_count: 1 })
        refute state.dig('chats', DM_A).key?('resync_from')
      end
    end

    def test_unreadable_shared_dir_messages_are_left_alone
      with_temp_config do
        store = Teems::Services::SyncStore.new
        state = legacy_state
        shared_dir, = seed_shared_dir(store)
        File.write(File.join(shared_dir, 'messages.json'), '{not json')
        store.detach_shared_dirs(state)
        assert_nil store.resync_from(state, DM_A)
        assert_equal '{not json', File.read(File.join(shared_dir, 'messages.json')), 'never renamed as corrupt'
      end
    end

    def test_legacy_shared_dirs_lists_detached_dirs_while_they_exist
      with_detached_state do |store, state, shared_dir|
        assert_equal({ "groups/#{SHARED}" => [DM_A, DM_B] }, store.legacy_shared_dirs(state))
        FileUtils.rm_rf(shared_dir)
        assert_empty store.legacy_shared_dirs(state)
      end
    end
  end

  # A chat that owns "groups/<title>" and has one synthetic stored message
  module DirPlanningFixtures
    CHAT = '19:planning@thread.v2'
    OTHER = '19:other@thread.v2'
    FULL_NAME = 'Planning (19_planning_thread.v2)'

    private

    def owner(display_name)
      { 'dir_name' => display_name, 'chat_type' => 'group', 'display_name' => display_name,
        'last_synced_at' => '2026-01-20T12:00:00Z', 'message_count' => 1 }
    end

    def info(display_name) = { chat_id: CHAT, display_name: display_name, chat_type: 'group' }

    def with_store(entry:, others: {})
      with_temp_config do
        store = Teems::Services::SyncStore.new
        dir_name = entry['dir_name']
        seed_dir(store, "groups/#{dir_name}") if dir_name
        yield store, { 'chats' => { CHAT => entry }.merge(others) }
      end
    end

    def seed_dir(store, relative)
      FileUtils.mkdir_p(path(store, relative))
      File.write(path(store, "#{relative}/messages.json"), JSON.generate([{ 'id' => 'm1' }]))
    end

    def path(store, relative) = File.join(store.sync_dir, 'chats', relative)

    def stored_ids(store, relative)
      JSON.parse(File.read(path(store, "#{relative}/messages.json"))).map { |message| message['id'] }
    end
  end

  # Existing folders keep their names; only new, detached and changed chats get full-ID names
  class DirPlanningTest < Minitest::Test
    include DirPlanningFixtures

    def test_unchanged_chats_keep_their_folder
      with_store(entry: owner('Planning')) do |store, state|
        move = store.ensure_chat_dir(state, chat_info: info('Planning'))
        assert_equal [:kept, 'groups/Planning', 'groups/Planning'], [move.kind, move.from, move.to]
        assert File.directory?(path(store, 'groups/Planning'))
      end
    end

    def test_a_renamed_chat_moves_to_a_full_id_folder
      with_store(entry: owner('Old Title')) do |store, state|
        move = store.ensure_chat_dir(state, chat_info: info('Planning'))
        assert_equal [:move, "groups/#{FULL_NAME}"], [move.kind, move.to]
        assert_equal "groups/Old Title → groups/#{FULL_NAME}", move.to_s
        assert_equal ['m1'], stored_ids(store, move.to)
        refute File.exist?(path(store, 'groups/Old Title'))
      end
    end

    def test_migrate_gives_unchanged_chats_a_full_id_folder
      with_store(entry: owner('Planning')) do |store, state|
        migrate = info('Planning').merge(migrate: true)
        assert_equal [:move, "groups/#{FULL_NAME}"],
                     store.ensure_chat_dir(state, chat_info: migrate).to_h.values_at(:kind, :to)
        assert_equal :kept, store.ensure_chat_dir(state, chat_info: migrate).kind
      end
    end

    def test_unknown_name_and_type_keep_the_stored_ones
      with_store(entry: owner('Planning')) do |store, state|
        assert_equal :kept, store.ensure_chat_dir(state, chat_info: { chat_id: CHAT }).kind
        store.update_chat_state(state, CHAT, attrs: { last_synced_at: Time.now, message_count: 2 })
        assert_equal %w[Planning group Planning],
                     state.dig('chats', CHAT).values_at('display_name', 'chat_type', 'dir_name')
      end
    end

    def test_new_and_detached_chats
      with_store(entry: { 'legacy_shared_dir' => 'groups/Shared', 'chat_type' => 'group' }) do |store, state|
        assert_equal [:split, 'groups/Shared'],
                     store.plan_chat_dir(state, info('Planning')).to_h.values_at(:kind, :from)
        assert_equal [:new, nil],
                     store.plan_chat_dir(state, info('Other').merge(chat_id: OTHER)).to_h.values_at(:kind, :from)
      end
    end
  end

  # Moves never overwrite a folder or take one that holds another chat's messages
  class DirMoveSafetyTest < Minitest::Test
    include DirPlanningFixtures

    def test_an_existing_target_is_used_and_the_old_folder_left_alone
      with_store(entry: owner('Old Title')) do |store, state|
        seed_dir(store, "groups/#{FULL_NAME}")
        assert_equal :repoint, store.ensure_chat_dir(state, chat_info: info('Planning')).kind
        assert_equal ['m1'], stored_ids(store, 'groups/Old Title')
      end
    end

    def test_a_missing_old_folder_is_just_retargeted
      with_store(entry: owner('Old Title')) do |store, state|
        FileUtils.rm_rf(path(store, 'groups/Old Title'))
        assert_equal :retarget, store.ensure_chat_dir(state, chat_info: info('Planning')).kind
        assert_equal FULL_NAME, state.dig('chats', CHAT, 'dir_name')
      end
    end

    def test_a_never_synced_chat_leaves_the_owners_folder_alone
      dead = { 'dir_name' => 'Old Title', 'chat_type' => 'group', 'display_name' => 'Old Title' }
      with_store(entry: owner('Old Title'), others: { OTHER => dead }) do |store, state|
        assert_equal :kept, store.ensure_chat_dir(state, chat_info: info('Old Title')).kind
        move = store.ensure_chat_dir(state, chat_info: info('Old Title').merge(chat_id: OTHER))
        assert_equal [:release, 'groups/Old Title', 'groups/Old Title (19_other_thread.v2)'],
                     move.to_h.values_at(:kind, :from, :to)
        assert_equal ['m1'], stored_ids(store, 'groups/Old Title')
      end
    end

    def test_a_failed_rename_keeps_the_old_folder_in_state
      with_store(entry: owner('Old Title')) do |store, state|
        before = state.dig('chats', CHAT).dup
        File.stub(:rename, ->(*) { raise Errno::EACCES, 'synthetic' }) do
          assert_raises(Errno::EACCES) { store.ensure_chat_dir(state, chat_info: info('Planning')) }
        end
        assert_equal before, state.dig('chats', CHAT)
        assert_equal :move, store.ensure_chat_dir(state, chat_info: info('Planning')).kind, 'retried next run'
      end
    end

    def test_a_case_only_title_change_renames_the_folder
      old_name = 'planning (19_planning_thread.v2)'
      with_store(entry: owner('planning').merge('dir_name' => old_name)) do |store, state|
        move = store.ensure_chat_dir(state, chat_info: info('Planning'))
        assert_equal [:move, "groups/#{old_name}", "groups/#{FULL_NAME}"], move.to_h.values_at(:kind, :from, :to)
        assert_equal [FULL_NAME], Dir.children(path(store, 'groups'))
        assert_equal ['m1'], stored_ids(store, move.to)
      end
    end

    def test_write_dir_map_records_moves
      with_temp_config do
        store = Teems::Services::SyncStore.new
        move = Teems::Services::SyncDirPlanning::DirMove.new(CHAT, 'groups/Planning', "groups/#{FULL_NAME}", :move)
        map_path = store.write_dir_map([move], time: Time.new(2026, 10, 6, 18, 0, 0))
        assert map_path.end_with?('/sync/dir-maps/20261006-180000.json')
        map = JSON.parse(File.read(map_path))
        assert_equal [File.join(store.sync_dir, 'chats'), [move.to_h.transform_keys(&:to_s).merge('kind' => 'move')]],
                     map.values_at('root', 'moves')
      end
    end
  end
end
