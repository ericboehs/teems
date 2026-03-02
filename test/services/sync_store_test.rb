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
                              last_synced_at: now,
                              message_count: 42,
                              display_name: 'Test Chat')

      assert_equal now.iso8601, state['chats']['chat1']['last_synced_at']
      assert_equal 42, state['chats']['chat1']['message_count']
      assert_equal 'Test Chat', state['chats']['chat1']['display_name']
    end
  end

  def test_chat_dir_sanitizes_colons_and_at_signs
    with_temp_config do
      store = Teems::Services::SyncStore.new
      dir = store.chat_dir('19:abc123@thread.v2')

      assert_includes dir, '19_abc123_thread.v2'
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

      %w[Group\ Chat 1:1\ Chat Meeting\ Chat].each do |label|
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
      state = { 'chats' => { chat_id => { 'dir_name' => 'My Cool Chat' } } }

      dir = store.chat_dir(chat_id, state: state)

      assert dir.end_with?('chats/My Cool Chat')
    end
  end

  def test_chat_dir_falls_back_without_state
    with_temp_config do
      store = Teems::Services::SyncStore.new
      chat_id = '19:abc@thread.v2'

      dir = store.chat_dir(chat_id)

      assert dir.end_with?('chats/19_abc_thread.v2')
    end
  end

  def test_ensure_dir_name_renames_legacy_dir
    with_temp_config do
      store = Teems::Services::SyncStore.new
      chat_id = '19:abc@thread.v2'
      state = { 'chats' => {} }

      # Create a legacy directory using the old sanitized-ID naming
      legacy_dir = File.join(store.sync_dir, 'chats', '19_abc_thread.v2')
      FileUtils.mkdir_p(legacy_dir)
      File.write(File.join(legacy_dir, 'messages.md'), '# Test')

      # ensure_dir_name should rename it
      dir_name = store.ensure_dir_name(state, chat_id, 'Engineering Win Prep')

      assert_equal 'Engineering Win Prep', dir_name
      new_dir = File.join(store.sync_dir, 'chats', 'Engineering Win Prep')
      assert File.directory?(new_dir), 'New directory should exist'
      assert File.exist?(File.join(new_dir, 'messages.md')), 'Files should have been moved'
      refute File.directory?(legacy_dir), 'Old directory should not exist'
    end
  end

  def test_ensure_dir_name_renames_on_topic_change
    with_temp_config do
      store = Teems::Services::SyncStore.new
      chat_id = '19:abc@thread.v2'
      state = { 'chats' => { chat_id => { 'dir_name' => 'Old Topic' } } }

      # Create old directory
      old_dir = File.join(store.sync_dir, 'chats', 'Old Topic')
      FileUtils.mkdir_p(old_dir)
      File.write(File.join(old_dir, 'messages.md'), '# Test')

      # ensure_dir_name should rename it
      dir_name = store.ensure_dir_name(state, chat_id, 'New Topic')

      assert_equal 'New Topic', dir_name
      new_dir = File.join(store.sync_dir, 'chats', 'New Topic')
      assert File.directory?(new_dir), 'New directory should exist'
      refute File.directory?(old_dir), 'Old directory should not exist'
    end
  end

  def test_migrate_directories_renames_all
    with_temp_config do
      store = Teems::Services::SyncStore.new
      chat1 = '19:aaa@thread.v2'
      chat2 = '19:bbb@thread.v2'

      state = {
        'chats' => {
          chat1 => { 'display_name' => 'Alpha Chat' },
          chat2 => { 'display_name' => 'Beta Chat' }
        }
      }

      # Create legacy directories
      [chat1, chat2].each do |cid|
        sanitized = cid.gsub(/[:@]/, '_')
        dir = File.join(store.sync_dir, 'chats', sanitized)
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, 'messages.md'), '# Test')
      end

      store.migrate_directories!(state)

      # Verify directories were renamed
      assert File.directory?(File.join(store.sync_dir, 'chats', 'Alpha Chat'))
      assert File.directory?(File.join(store.sync_dir, 'chats', 'Beta Chat'))
      refute File.directory?(File.join(store.sync_dir, 'chats', '19_aaa_thread.v2'))
      refute File.directory?(File.join(store.sync_dir, 'chats', '19_bbb_thread.v2'))

      # Verify state was updated
      assert_equal 'Alpha Chat', state.dig('chats', chat1, 'dir_name')
      assert_equal 'Beta Chat', state.dig('chats', chat2, 'dir_name')
    end
  end

  def test_update_chat_state_stores_dir_name
    with_temp_config do
      store = Teems::Services::SyncStore.new
      state = {}
      now = Time.now

      store.update_chat_state(state, 'chat1',
                              last_synced_at: now,
                              message_count: 42,
                              display_name: 'My Project Chat')

      assert_equal 'My Project Chat', state['chats']['chat1']['dir_name']
    end
  end

  def test_write_and_read_messages_with_state
    with_temp_config do
      store = Teems::Services::SyncStore.new
      chat_id = '19:test@thread.v2'
      state = { 'chats' => { chat_id => { 'dir_name' => 'Human Readable Name' } } }
      messages = [{ 'id' => '1', 'content' => 'hello' }]

      store.write_messages(chat_id,
                           messages_md: '# Test',
                           messages_json: JSON.generate(messages),
                           state: state)

      # Verify file was written to human-readable dir
      dir = store.chat_dir(chat_id, state: state)
      assert File.exist?(File.join(dir, 'messages.json'))

      # Verify read_messages_json also uses state
      loaded = store.read_messages_json(chat_id, state: state)
      assert_equal messages, loaded
    end
  end
end
