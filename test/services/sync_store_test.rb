# frozen_string_literal: true

require 'test_helper'

class SyncStoreTest < Minitest::Test
  def test_sync_dir_uses_xdg_data_home
    with_temp_config do |dir|
      store = Teems::Services::SyncStore.new
      assert_equal "#{dir}/data/teems/sync", store.sync_dir
    end
  end

  def test_load_state_returns_empty_hash_when_no_file
    with_temp_config do
      store = Teems::Services::SyncStore.new
      assert_equal({}, store.load_state)
    end
  end

  def test_save_and_load_state
    with_temp_config do
      store = Teems::Services::SyncStore.new
      state = { 'chats' => { 'chat1' => { 'last_synced_at' => '2026-01-20T12:00:00+00:00' } } }

      store.save_state(state)
      loaded = store.load_state

      assert_equal state, loaded
    end
  end

  def test_load_state_handles_corrupt_json
    with_temp_config do
      store = Teems::Services::SyncStore.new
      FileUtils.mkdir_p(store.sync_dir)
      File.write(File.join(store.sync_dir, 'sync_state.json'), 'not json{{{')

      assert_equal({}, store.load_state)
    end
  end

  def test_last_synced_time_returns_nil_for_unknown_chat
    with_temp_config do
      store = Teems::Services::SyncStore.new
      state = {}

      assert_nil store.last_synced_time(state, 'unknown_chat')
    end
  end

  def test_last_synced_time_returns_time_object
    with_temp_config do
      store = Teems::Services::SyncStore.new
      state = { 'chats' => { 'chat1' => { 'last_synced_at' => '2026-01-20T12:00:00+00:00' } } }

      result = store.last_synced_time(state, 'chat1')

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
                              attrs: { last_synced_at: now, message_count: 42,
                                       display_name: 'Test Chat' })

      assert_equal now.iso8601, state['chats']['chat1']['last_synced_at']
      assert_equal 42, state['chats']['chat1']['message_count']
      assert_equal 'Test Chat', state['chats']['chat1']['display_name']
    end
  end

  def test_chat_dir_sanitizes_colons_and_at_signs
    with_temp_config do
      store = Teems::Services::SyncStore.new
      dir = store.chat_dir('19:abc123@thread.v2')

      assert_includes dir, 'other/19_abc123_thread.v2'
      refute_includes dir, ':'
      refute_includes dir, '@'
    end
  end

  def test_write_messages_creates_files
    with_temp_config do
      store = Teems::Services::SyncStore.new
      chat_id = '19:test@thread.v2'

      store.write_messages(chat_id,
                           messages_md: '# Test\n\nHello world',
                           messages_json: '[{"id":"1","content":"hello"}]')

      dir = store.chat_dir(chat_id)
      assert File.exist?(File.join(dir, 'messages.md'))
      assert File.exist?(File.join(dir, 'messages.json'))
      assert_equal '# Test\n\nHello world', File.read(File.join(dir, 'messages.md'))
    end
  end

  def test_write_chat_metadata_creates_file
    with_temp_config do
      store = Teems::Services::SyncStore.new
      chat_id = '19:test@thread.v2'
      metadata = { 'id' => chat_id, 'display_name' => 'Test Chat', 'type' => 'group' }

      store.write_chat_metadata(chat_id, metadata)

      dir = store.chat_dir(chat_id)
      path = File.join(dir, 'chat_metadata.json')
      assert File.exist?(path)

      loaded = JSON.parse(File.read(path))
      assert_equal chat_id, loaded['id']
      assert_equal 'Test Chat', loaded['display_name']
    end
  end

  def test_read_messages_json_returns_empty_array_when_no_file
    with_temp_config do
      store = Teems::Services::SyncStore.new

      assert_equal [], store.read_messages_json('nonexistent')
    end
  end

  def test_read_messages_json_returns_parsed_data
    with_temp_config do
      store = Teems::Services::SyncStore.new
      chat_id = '19:test@thread.v2'
      messages = [{ 'id' => '1', 'content' => 'hello' }]

      store.write_messages(chat_id,
                           messages_md: '# Test',
                           messages_json: JSON.generate(messages))

      loaded = store.read_messages_json(chat_id)
      assert_equal messages, loaded
    end
  end

  def test_read_messages_json_handles_corrupt_json
    with_temp_config do
      store = Teems::Services::SyncStore.new
      chat_id = '19:test@thread.v2'

      store.write_messages(chat_id,
                           messages_md: '# Test',
                           messages_json: 'not json{{{')

      # Returns empty array and backs up the corrupt file
      assert_equal [], store.read_messages_json(chat_id)
    end
  end

  def test_atomic_write_does_not_leave_tmp_files
    with_temp_config do
      store = Teems::Services::SyncStore.new
      state = { 'test' => true }

      store.save_state(state)

      refute File.exist?(File.join(store.sync_dir, 'sync_state.json.tmp'))
    end
  end

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
      store = Teems::Services::SyncStore.new
      state = { 'chats' => { 'chat1' => { 'unavailable' => true } } }

      assert store.chat_unavailable?(state, 'chat1')
    end
  end

  def test_chat_unavailable_returns_false_for_normal_chats
    with_temp_config do
      store = Teems::Services::SyncStore.new
      state = { 'chats' => { 'chat1' => { 'last_synced_at' => '2026-01-20T12:00:00+00:00' } } }

      refute store.chat_unavailable?(state, 'chat1')
    end
  end

  def test_chat_unavailable_returns_false_for_unknown_chats
    with_temp_config do
      store = Teems::Services::SyncStore.new
      state = {}

      refute store.chat_unavailable?(state, 'unknown')
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

  # --- Human-readable directory naming tests ---

  def test_build_dir_name_sanitizes_unsafe_chars
    with_temp_config do
      store = Teems::Services::SyncStore.new
      chat_id = '19:abc@thread.v2'

      # Use ensure_dir_name to exercise build_dir_name (which is private)
      state = { 'chats' => {} }
      dir_name = store.ensure_dir_name(state, chat_id, 'Project: Design/Review <Q1>')

      assert_equal 'Project- Design-Review -Q1-', dir_name
      refute_includes dir_name, ':'
      refute_includes dir_name, '/'
      refute_includes dir_name, '<'
      refute_includes dir_name, '>'
    end
  end

  def test_generic_labels_get_id_suffix
    with_temp_config do
      store = Teems::Services::SyncStore.new
      chat_id = '19:abc123def456@thread.v2'
      state = { 'chats' => {} }

      ['Group Chat', '1:1 Chat', 'Meeting Chat'].each do |label|
        dir_name = store.ensure_dir_name(state, chat_id, label)

        assert_match(/\(19_abc123def456_thre\)\z/, dir_name, "#{label} should have ID suffix")
      end
    end
  end

  def test_named_topics_no_suffix
    with_temp_config do
      store = Teems::Services::SyncStore.new
      chat_id = '19:abc@thread.v2'
      state = { 'chats' => {} }

      dir_name = store.ensure_dir_name(state, chat_id, 'EERT Sprint Planning')

      assert_equal 'EERT Sprint Planning', dir_name
      refute_includes dir_name, '('
    end
  end

  def test_null_display_name_falls_back_to_sanitized_id
    with_temp_config do
      store = Teems::Services::SyncStore.new
      chat_id = '19:abc@thread.v2'
      state = { 'chats' => {} }

      dir_name = store.ensure_dir_name(state, chat_id, nil)

      assert_equal '19_abc_thread.v2', dir_name
    end
  end

  def test_chat_dir_uses_state_dir_name
    with_temp_config do
      store = Teems::Services::SyncStore.new
      chat_id = '19:abc@thread.v2'
      state = { 'chats' => { chat_id => { 'dir_name' => 'My Cool Chat', 'chat_type' => 'group' } } }

      dir = store.chat_dir(chat_id, state: state)

      assert dir.end_with?('chats/groups/My Cool Chat')
    end
  end

  def test_chat_dir_falls_back_without_state
    with_temp_config do
      store = Teems::Services::SyncStore.new
      chat_id = '19:abc@thread.v2'

      dir = store.chat_dir(chat_id)

      assert dir.end_with?('chats/other/19_abc_thread.v2')
    end
  end

  def test_ensure_dir_name_renames_on_topic_change
    with_temp_config do
      store = Teems::Services::SyncStore.new
      chat_id = '19:abc@thread.v2'
      state = { 'chats' => { chat_id => { 'dir_name' => 'Old Topic', 'chat_type' => 'group' } } }

      # Create old directory in type subdir
      old_dir = File.join(store.sync_dir, 'chats', 'groups', 'Old Topic')
      FileUtils.mkdir_p(old_dir)
      File.write(File.join(old_dir, 'messages.md'), '# Test')

      # ensure_dir_name should rename it within the type subdir
      dir_name = store.ensure_dir_name(state, chat_id, 'New Topic', chat_type: 'group')

      assert_equal 'New Topic', dir_name
      new_dir = File.join(store.sync_dir, 'chats', 'groups', 'New Topic')
      assert File.directory?(new_dir), 'New directory should exist'
      refute File.directory?(old_dir), 'Old directory should not exist'
    end
  end

  def test_ensure_dir_name_moves_dir_on_type_change
    with_temp_config do
      store = Teems::Services::SyncStore.new
      chat_id = '19:abc@thread.v2'
      state = { 'chats' => { chat_id => { 'dir_name' => 'Sprint Planning', 'chat_type' => 'group' } } }

      # Create directory in groups/
      old_dir = File.join(store.sync_dir, 'chats', 'groups', 'Sprint Planning')
      FileUtils.mkdir_p(old_dir)
      File.write(File.join(old_dir, 'messages.md'), '# Test')

      # Change type to meeting
      store.ensure_dir_name(state, chat_id, 'Sprint Planning', chat_type: 'meeting')

      new_dir = File.join(store.sync_dir, 'chats', 'meetings', 'Sprint Planning')
      assert File.directory?(new_dir), 'Directory should be in meetings/ subdir'
      refute File.directory?(old_dir), 'Old groups/ directory should not exist'
      assert_equal 'meeting', state.dig('chats', chat_id, 'chat_type')
    end
  end

  def test_update_chat_state_stores_dir_name
    with_temp_config do
      store = Teems::Services::SyncStore.new
      state = {}
      now = Time.now

      store.update_chat_state(state, 'chat1',
                              attrs: { last_synced_at: now, message_count: 42,
                                       display_name: 'My Project Chat', chat_type: 'group' })

      assert_equal 'My Project Chat', state['chats']['chat1']['dir_name']
      assert_equal 'group', state['chats']['chat1']['chat_type']
    end
  end

  def test_write_and_read_messages_with_state
    with_temp_config do
      store = Teems::Services::SyncStore.new
      chat_id = '19:test@thread.v2'
      state = { 'chats' => { chat_id => { 'dir_name' => 'Human Readable Name', 'chat_type' => 'group' } } }
      messages = [{ 'id' => '1', 'content' => 'hello' }]

      store.write_messages(chat_id,
                           messages_md: '# Test',
                           messages_json: JSON.generate(messages),
                           state: state)

      # Verify file was written to human-readable dir in type subdir
      dir = store.chat_dir(chat_id, state: state)
      assert_includes dir, 'chats/groups/Human Readable Name'
      assert File.exist?(File.join(dir, 'messages.json'))

      # Verify read_messages_json also uses state
      loaded = store.read_messages_json(chat_id, state: state)
      assert_equal messages, loaded
    end
  end

  def test_long_display_name_is_truncated
    with_temp_config do
      store = Teems::Services::SyncStore.new
      chat_id = '19:abc@thread.v2'
      state = { 'chats' => {} }
      long_name = 'A' * 200

      dir_name = store.ensure_dir_name(state, chat_id, long_name)

      assert_operator dir_name.length, :<=, Teems::Services::SyncStore::MAX_DIR_NAME_LENGTH
    end
  end

  def test_rename_collision_does_not_overwrite_existing_dir
    with_temp_config do
      store = Teems::Services::SyncStore.new
      chat_id = '19:abc@thread.v2'
      state = { 'chats' => { chat_id => { 'dir_name' => 'Old Name', 'chat_type' => 'group' } } }

      # Create both old and new directories with different content in type subdir
      old_dir = File.join(store.sync_dir, 'chats', 'groups', 'Old Name')
      new_dir = File.join(store.sync_dir, 'chats', 'groups', 'New Name')
      FileUtils.mkdir_p(old_dir)
      FileUtils.mkdir_p(new_dir)
      File.write(File.join(old_dir, 'messages.md'), '# Old content')
      File.write(File.join(new_dir, 'messages.md'), '# Existing content')

      # ensure_dir_name should NOT overwrite the existing "New Name" dir
      store.ensure_dir_name(state, chat_id, 'New Name', chat_type: 'group')

      # Both directories should still exist with original content
      assert File.directory?(old_dir), 'Old dir should still exist since rename was skipped'
      assert_equal '# Existing content', File.read(File.join(new_dir, 'messages.md'))
    end
  end

  def test_corrupt_state_backs_up_file
    with_temp_config do
      store = Teems::Services::SyncStore.new
      FileUtils.mkdir_p(store.sync_dir)
      state_path = File.join(store.sync_dir, 'sync_state.json')
      File.write(state_path, 'not json{{{')

      result = store.load_state

      assert_equal({}, result)
      # Original file should be renamed to a backup
      refute File.exist?(state_path), 'Corrupt file should be moved to backup'
      backups = Dir.glob(File.join(store.sync_dir, 'sync_state.json.corrupt.*'))
      assert_equal 1, backups.length, 'Should have one backup file'
    end
  end

  def test_corrupt_messages_json_backs_up_file
    with_temp_config do
      store = Teems::Services::SyncStore.new
      chat_id = '19:test@thread.v2'

      store.write_messages(chat_id,
                           messages_md: '# Test',
                           messages_json: 'not json{{{')

      result = store.read_messages_json(chat_id)

      assert_equal [], result
      # Original file should be renamed to a backup
      dir = store.chat_dir(chat_id)
      refute File.exist?(File.join(dir, 'messages.json')), 'Corrupt file should be moved to backup'
      backups = Dir.glob(File.join(dir, 'messages.json.corrupt.*'))
      assert_equal 1, backups.length, 'Should have one backup file'
    end
  end

  def test_trailing_dots_and_spaces_stripped_from_dir_name
    with_temp_config do
      store = Teems::Services::SyncStore.new
      chat_id = '19:abc@thread.v2'
      state = { 'chats' => {} }

      dir_name = store.ensure_dir_name(state, chat_id, 'My Chat...')

      refute dir_name.end_with?('.'), 'Dir name should not end with dots'
      refute dir_name.end_with?(' '), 'Dir name should not end with spaces'
      assert_equal 'My Chat', dir_name
    end
  end

  # --- Type subdirectory tests ---

  def test_chat_dir_includes_type_subdirectory
    with_temp_config do
      store = Teems::Services::SyncStore.new
      chat_id = '19:abc@thread.v2'

      { 'group' => 'groups', 'oneOnOne' => 'dms', 'meeting' => 'meetings',
        'channel' => 'channels', 'space' => 'spaces' }.each do |chat_type, subdir|
        state = { 'chats' => { chat_id => { 'dir_name' => 'Some Chat', 'chat_type' => chat_type } } }
        dir = store.chat_dir(chat_id, state: state)

        assert_includes dir, "chats/#{subdir}/Some Chat",
                        "chat_type '#{chat_type}' should use '#{subdir}/' subdirectory"
      end
    end
  end

  def test_unknown_chat_type_uses_other_dir
    with_temp_config do
      store = Teems::Services::SyncStore.new
      chat_id = '19:abc@thread.v2'

      [nil, 'unknown', 'something_else'].each do |chat_type|
        state = { 'chats' => { chat_id => { 'dir_name' => 'Some Chat', 'chat_type' => chat_type } } }
        dir = store.chat_dir(chat_id, state: state)

        assert_includes dir, 'chats/other/Some Chat', "chat_type #{chat_type.inspect} should use 'other/' subdirectory"
      end
    end
  end

  def test_type_dir_mapping
    with_temp_config do
      store = Teems::Services::SyncStore.new

      assert_equal 'dms', store.type_dir('oneOnOne')
      assert_equal 'groups', store.type_dir('group')
      assert_equal 'meetings', store.type_dir('meeting')
      assert_equal 'channels', store.type_dir('channel')
      assert_equal 'spaces', store.type_dir('space')
      assert_equal 'other', store.type_dir(nil)
      assert_equal 'other', store.type_dir('unknown')
    end
  end

  def test_update_chat_state_stores_chat_type
    with_temp_config do
      store = Teems::Services::SyncStore.new
      state = {}
      now = Time.now

      store.update_chat_state(state, 'chat1',
                              attrs: { last_synced_at: now, message_count: 10,
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
      store = Teems::Services::SyncStore.new
      chat_id = '19:abc@thread.v2'
      state = { 'chats' => {} }

      store.ensure_dir_name(state, chat_id, 'My Chat', chat_type: 'group')

      assert_equal 'group', state.dig('chats', chat_id, 'chat_type')
    end
  end

  def test_mark_unavailable_without_display_name
    with_temp_config do
      store = Teems::Services::SyncStore.new
      state = {}

      store.mark_unavailable(state, 'chat1')

      assert state.dig('chats', 'chat1', 'unavailable')
    end
  end

  def test_mark_unavailable_without_chat_type
    with_temp_config do
      store = Teems::Services::SyncStore.new
      state = {}

      store.mark_unavailable(state, 'chat1', display_name: 'Test')

      assert state.dig('chats', 'chat1', 'unavailable')
      assert_nil state.dig('chats', 'chat1', 'chat_type')
    end
  end
end

class SyncDirNamingTest < Minitest::Test
  include Teems::Services::SyncDirNaming

  def test_sanitize_display_name_empty_after_cleanup
    result = sanitize_display_name('...')

    assert_nil result
  end

  def test_build_dir_name_generic_label_appends_id
    result = build_dir_name('19:abc@thread.v2', 'Group Chat')

    assert_includes result, 'Group Chat'
    assert_includes result, '19_abc_thread.v2'
  end

  def test_build_dir_name_nil_display_name
    result = build_dir_name('19:abc@thread.v2', nil)

    assert_equal '19_abc_thread.v2', result
  end

  def test_build_dir_name_non_generic_label
    result = build_dir_name('19:abc@thread.v2', 'My Project Chat')

    assert_equal 'My Project Chat', result
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
