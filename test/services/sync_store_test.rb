# frozen_string_literal: true

require 'test_helper'

# Tests for SyncStore state persistence, directory naming, message storage, and corruption handling
module SyncStoreTests
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
    def test_build_dir_name_sanitizes_unsafe_chars
      with_temp_config do
        store = Teems::Services::SyncStore.new
        state = { 'chats' => {} }
        dir_name = store.ensure_dir_name(state,
                                         chat_info: { chat_id: '19:abc@thread.v2',
                                                      display_name: 'Project: Design/Review <Q1>' })
        assert_equal 'Project- Design-Review -Q1-', dir_name
        %w[: / < >].each { |ch| refute_includes dir_name, ch }
      end
    end

    def test_generic_labels_get_id_suffix
      with_temp_config do
        store = Teems::Services::SyncStore.new
        state = { 'chats' => {} }
        ['Group Chat', '1:1 Chat', 'Meeting Chat'].each do |label|
          dir_name = store.ensure_dir_name(state,
                                           chat_info: { chat_id: '19:abc123def456@thread.v2',
                                                        display_name: label })
          assert_match(/\(19_abc123def456_thre\)\z/, dir_name, "#{label} should have ID suffix")
        end
      end
    end

    def test_named_topics_no_suffix
      with_temp_config do
        state = { 'chats' => {} }
        dir_name = Teems::Services::SyncStore.new.ensure_dir_name(
          state, chat_info: { chat_id: '19:abc@thread.v2', display_name: 'EERT Sprint Planning' }
        )
        assert_equal 'EERT Sprint Planning', dir_name
        refute_includes dir_name, '('
      end
    end

    def test_null_display_name_falls_back_to_sanitized_id
      with_temp_config do
        state = { 'chats' => {} }
        dir_name = Teems::Services::SyncStore.new.ensure_dir_name(
          state, chat_info: { chat_id: '19:abc@thread.v2', display_name: nil }
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
        dir_name = Teems::Services::SyncStore.new.ensure_dir_name(
          state, chat_info: { chat_id: '19:abc@thread.v2', display_name: 'A' * 200 }
        )
        assert_operator dir_name.length, :<=, Teems::Services::SyncStore::MAX_DIR_NAME_LENGTH
      end
    end

    def test_trailing_dots_and_spaces_stripped_from_dir_name
      with_temp_config do
        state = { 'chats' => {} }
        dir_name = Teems::Services::SyncStore.new.ensure_dir_name(
          state, chat_info: { chat_id: '19:abc@thread.v2', display_name: 'My Chat...' }
        )
        refute dir_name.end_with?('.'), 'Dir name should not end with dots'
        refute dir_name.end_with?(' '), 'Dir name should not end with spaces'
        assert_equal 'My Chat', dir_name
      end
    end
  end

  # Tests directory renaming on topic or type change and collision avoidance
  class DirRenamingTest < Minitest::Test
    def test_ensure_dir_name_renames_on_topic_change
      with_temp_config do
        chat_id = '19:abc@thread.v2'
        store, state = build_store_with_state(chat_id, dir_name: 'Old Topic', chat_type: 'group')
        make_chat_dir(store, 'groups', 'Old Topic')
        sync_dir = store.sync_dir
        info = { chat_id: chat_id, display_name: 'New Topic', chat_type: 'group' }
        assert_equal 'New Topic', ensure_dir(store, state, info)
        assert File.directory?(File.join(sync_dir, 'chats', 'groups', 'New Topic'))
        refute File.directory?(File.join(sync_dir, 'chats', 'groups', 'Old Topic'))
      end
    end

    def test_ensure_dir_name_moves_dir_on_type_change
      with_temp_config do
        chat_id = '19:abc@thread.v2'
        store, state = build_store_with_state(chat_id, dir_name: 'Sprint Planning', chat_type: 'group')
        old_dir = make_chat_dir(store, 'groups', 'Sprint Planning')
        ensure_dir(store, state, { chat_id: chat_id, display_name: 'Sprint Planning', chat_type: 'meeting' })
        assert File.directory?(File.join(store.sync_dir, 'chats', 'meetings', 'Sprint Planning'))
        refute File.directory?(old_dir), 'Old groups/ directory should not exist'
        assert_equal 'meeting', state.dig('chats', chat_id, 'chat_type')
      end
    end

    def test_update_chat_state_stores_dir_name
      with_temp_config do
        chat_state = update_and_load_chat_state('chat1',
                                                display_name: 'My Project Chat', chat_type: 'group')
        assert_equal 'My Project Chat', chat_state['dir_name']
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
        store.ensure_dir_name(
          state, chat_info: { chat_id: '19:abc@thread.v2', display_name: 'New Name', chat_type: 'group' }
        )
        assert File.directory?(old_dir), 'Old dir should still exist since rename was skipped'
        assert_equal '# Existing content', File.read(File.join(new_dir, 'messages.md'))
      end
    end

    private

    def ensure_dir(store, state, chat_info)
      store.ensure_dir_name(state, chat_info: chat_info)
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
      new_dir = File.join(sync_dir, 'chats', 'groups', 'New Name')
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
        Teems::Services::SyncStore.new.ensure_dir_name(
          state, chat_info: { chat_id: '19:abc@thread.v2', display_name: 'My Chat', chat_type: 'group' }
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
      assert_equal 'My Project Chat', build_dir_name('19:abc@thread.v2', 'My Project Chat')
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
end
