# frozen_string_literal: true

require 'test_helper'

class TokenStoreTest < Minitest::Test
  def test_configured_returns_false_when_no_tokens
    with_temp_config do
      store = Teems::Services::TokenStore.new
      refute store.configured?
    end
  end

  def test_configured_returns_true_when_tokens_exist
    with_temp_config do |dir|
      write_tokens_file(dir, {
                          'auth_token' => 'test-auth',
                          'skype_token' => 'test-skype'
                        })
      store = Teems::Services::TokenStore.new
      assert store.configured?
    end
  end

  def test_account_returns_nil_when_no_tokens
    with_temp_config do
      store = Teems::Services::TokenStore.new
      assert_nil store.account
    end
  end

  def test_account_returns_account_model
    with_temp_config do |dir|
      write_tokens_file(dir, {
                          'auth_token' => 'test-auth-token',
                          'skype_token' => 'test-skype-token'
                        })
      store = Teems::Services::TokenStore.new
      account = store.account

      assert_kind_of Teems::Models::Account, account
      assert_equal 'test-auth-token', account.auth_token
      assert_equal 'test-skype-token', account.skype_token
    end
  end

  def test_account_returns_nil_when_missing_required_tokens
    with_temp_config do |dir|
      # Only auth_token, missing skype_token
      write_tokens_file(dir, { 'auth_token' => 'test-auth' })
      store = Teems::Services::TokenStore.new

      assert_nil store.account
    end
  end

  def test_account_uses_default_name_when_not_specified
    with_temp_config do |dir|
      write_tokens_file(dir, {
                          'auth_token' => 'test-auth',
                          'skype_token' => 'test-skype'
                        })
      store = Teems::Services::TokenStore.new
      account = store.account

      assert_equal 'default', account.name
    end
  end

  def test_save_persists_tokens
    with_temp_config do
      store = Teems::Services::TokenStore.new
      store.save(name: 'default', auth_token: 'new-auth', skype_token: 'new-skype')

      # Create new store instance to verify persistence
      new_store = Teems::Services::TokenStore.new
      loaded = new_store.account

      assert_equal 'new-auth', loaded.auth_token
      assert_equal 'new-skype', loaded.skype_token
    end
  end

  def test_save_includes_saved_at_timestamp
    with_temp_config do |dir|
      store = Teems::Services::TokenStore.new
      store.save(name: 'default', auth_token: 'auth', skype_token: 'skype')

      tokens_file = "#{dir}/teems/tokens.json"
      data = JSON.parse(File.read(tokens_file))

      assert data.key?('saved_at')
      assert_instance_of Time, Time.parse(data['saved_at'])
    end
  end

  def test_save_with_optional_chatsvc_token
    with_temp_config do |dir|
      store = Teems::Services::TokenStore.new
      store.save(
        name: 'default',
        auth_token: 'auth',
        skype_token: 'skype',
        chatsvc_token: 'chatsvc'
      )

      tokens_file = "#{dir}/teems/tokens.json"
      data = JSON.parse(File.read(tokens_file))

      assert_equal 'chatsvc', data['chatsvc_token']
    end
  end

  def test_clear_removes_tokens
    with_temp_config do |dir|
      write_tokens_file(dir, {
                          'auth_token' => 'test-auth',
                          'skype_token' => 'test-skype'
                        })
      store = Teems::Services::TokenStore.new
      assert store.configured?

      store.clear

      refute store.configured?
    end
  end

  def test_token_age_returns_nil_when_no_tokens
    with_temp_config do
      store = Teems::Services::TokenStore.new
      assert_nil store.token_age
    end
  end

  def test_token_age_returns_nil_when_no_saved_at
    with_temp_config do |dir|
      write_tokens_file(dir, {
                          'auth_token' => 'test-auth',
                          'skype_token' => 'test-skype'
                        })
      store = Teems::Services::TokenStore.new
      assert_nil store.token_age
    end
  end

  def test_token_age_returns_age_in_seconds
    with_temp_config do |dir|
      saved_at = (Time.now - 3600).iso8601 # 1 hour ago
      write_tokens_file(dir, {
                          'auth_token' => 'test-auth',
                          'skype_token' => 'test-skype',
                          'saved_at' => saved_at
                        })
      store = Teems::Services::TokenStore.new
      age = store.token_age

      assert_in_delta 3600, age, 5 # Allow 5 seconds tolerance
    end
  end

  # Corruption handling
  def test_corrupted_tokens_file_returns_not_configured
    with_temp_config do |dir|
      config_dir = "#{dir}/teems"
      FileUtils.mkdir_p(config_dir)
      File.write("#{config_dir}/tokens.json", 'not valid json{{{')

      store = Teems::Services::TokenStore.new

      # Should not raise, but return not configured
      refute store.configured?
    end
  end

  def test_creates_config_directory_if_needed
    with_temp_config do |dir|
      config_dir = "#{dir}/teems"
      refute File.exist?(config_dir)

      store = Teems::Services::TokenStore.new
      store.save(name: 'default', auth_token: 'auth', skype_token: 'skype')

      assert File.directory?(config_dir)
    end
  end

  def test_save_creates_file_with_restricted_permissions
    with_temp_config do |dir|
      store = Teems::Services::TokenStore.new
      store.save(name: 'default', auth_token: 'auth', skype_token: 'skype')

      tokens_file = "#{dir}/teems/tokens.json"

      assert File.exist?(tokens_file)
      mode = File.stat(tokens_file).mode & 0o777
      assert_equal 0o600, mode, "Expected file mode 0600, got #{format('%o', mode)}"
    end
  end

  def test_save_with_skype_spaces_token
    with_temp_config do |dir|
      store = Teems::Services::TokenStore.new
      store.save(
        name: 'default',
        auth_token: 'auth',
        skype_token: 'skype',
        skype_spaces_token: 'spaces-token'
      )

      tokens_file = "#{dir}/teems/tokens.json"
      data = JSON.parse(File.read(tokens_file))

      assert_equal 'spaces-token', data['skype_spaces_token']
    end
  end

  def test_skype_spaces_token_returns_stored_token
    with_temp_config do |dir|
      write_tokens_file(dir, {
                          'auth_token' => 'auth',
                          'skype_token' => 'skype',
                          'skype_spaces_token' => 'my-spaces-token'
                        })
      store = Teems::Services::TokenStore.new

      assert_equal 'my-spaces-token', store.skype_spaces_token
    end
  end

  def test_skype_spaces_token_returns_nil_when_not_set
    with_temp_config do |dir|
      write_tokens_file(dir, {
                          'auth_token' => 'auth',
                          'skype_token' => 'skype'
                        })
      store = Teems::Services::TokenStore.new

      assert_nil store.skype_spaces_token
    end
  end

  def test_skype_spaces_token_returns_nil_when_no_tokens_file
    with_temp_config do
      store = Teems::Services::TokenStore.new

      assert_nil store.skype_spaces_token
    end
  end

  def test_update_skype_token_updates_token
    with_temp_config do |dir|
      write_tokens_file(dir, {
                          'auth_token' => 'auth',
                          'skype_token' => 'old-skype',
                          'skype_spaces_token' => 'spaces'
                        })
      store = Teems::Services::TokenStore.new

      result = store.update_skype_token('new-skype')

      assert result
      account = store.account
      assert_equal 'new-skype', account.skype_token
    end
  end

  def test_update_skype_token_preserves_other_fields
    with_temp_config do |dir|
      write_tokens_file(dir, {
                          'name' => 'myaccount',
                          'auth_token' => 'auth',
                          'skype_token' => 'old-skype',
                          'skype_spaces_token' => 'spaces'
                        })
      store = Teems::Services::TokenStore.new

      store.update_skype_token('new-skype')

      tokens_file = "#{dir}/teems/tokens.json"
      data = JSON.parse(File.read(tokens_file))

      assert_equal 'myaccount', data['name']
      assert_equal 'auth', data['auth_token']
      assert_equal 'spaces', data['skype_spaces_token']
    end
  end

  def test_update_skype_token_adds_refreshed_at_timestamp
    with_temp_config do |dir|
      write_tokens_file(dir, {
                          'auth_token' => 'auth',
                          'skype_token' => 'old-skype'
                        })
      store = Teems::Services::TokenStore.new

      store.update_skype_token('new-skype')

      tokens_file = "#{dir}/teems/tokens.json"
      data = JSON.parse(File.read(tokens_file))

      assert data['skype_token_refreshed_at']
      # Should be a valid ISO8601 timestamp
      assert_match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/, data['skype_token_refreshed_at'])
    end
  end

  def test_update_skype_token_returns_false_when_no_tokens
    with_temp_config do
      store = Teems::Services::TokenStore.new

      result = store.update_skype_token('new-skype')

      refute result
    end
  end

  def test_update_skype_token_sets_restricted_permissions
    with_temp_config do |dir|
      write_tokens_file(dir, {
                          'auth_token' => 'auth',
                          'skype_token' => 'old-skype'
                        })
      store = Teems::Services::TokenStore.new

      store.update_skype_token('new-skype')

      tokens_file = "#{dir}/teems/tokens.json"
      mode = File.stat(tokens_file).mode & 0o777
      assert_equal 0o600, mode, "Expected file mode 0600, got #{format('%o', mode)}"
    end
  end
end
