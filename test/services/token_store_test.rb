# frozen_string_literal: true

require 'test_helper'

# Tests for TokenStore persistence, token updates, OIDC fields, and error handling
module TokenStoreTests
  # Tests token configuration detection, account loading, and corrupt file handling
  class BasicTest < Minitest::Test
    def test_configured_returns_false_when_no_tokens
      with_temp_config do
        refute Teems::Services::TokenStore.new.configured?
      end
    end

    def test_configured_returns_true_when_tokens_exist
      with_temp_config do |dir|
        write_tokens_file(dir, { 'auth_token' => 'test-auth', 'skype_token' => 'test-skype' })
        assert Teems::Services::TokenStore.new.configured?
      end
    end

    def test_account_returns_nil_when_no_tokens
      with_temp_config do
        assert_nil Teems::Services::TokenStore.new.account
      end
    end

    def test_account_returns_account_model
      with_temp_config do |dir|
        write_tokens_file(dir, { 'auth_token' => 'test-auth-token', 'skype_token' => 'test-skype-token' })
        account = Teems::Services::TokenStore.new.account
        assert_kind_of Teems::Models::Account, account
        assert_equal 'test-auth-token', account.auth_token
        assert_equal 'test-skype-token', account.skype_token
      end
    end

    def test_account_returns_nil_when_missing_required_tokens
      with_temp_config do |dir|
        write_tokens_file(dir, { 'auth_token' => 'test-auth' })
        assert_nil Teems::Services::TokenStore.new.account
      end
    end

    def test_account_uses_default_name_when_not_specified
      with_temp_config do |dir|
        write_tokens_file(dir, { 'auth_token' => 'test-auth', 'skype_token' => 'test-skype' })
        assert_equal 'default', Teems::Services::TokenStore.new.account.name
      end
    end

    def test_corrupted_tokens_file_returns_not_configured
      with_temp_config do |dir|
        config_dir = "#{dir}/teems"
        FileUtils.mkdir_p(config_dir)
        File.write("#{config_dir}/tokens.json", 'not valid json{{{')
        refute Teems::Services::TokenStore.new.configured?
      end
    end
  end

  # Tests token saving, clearing, age calculation, and directory creation
  class SaveTest < Minitest::Test
    def test_save_persists_tokens
      with_temp_config do
        Teems::Services::TokenStore.new.save(name: 'default', auth_token: 'new-auth', skype_token: 'new-skype')
        loaded = Teems::Services::TokenStore.new.account
        assert_equal 'new-auth', loaded.auth_token
        assert_equal 'new-skype', loaded.skype_token
      end
    end

    def test_save_includes_saved_at_timestamp
      with_temp_config do |dir|
        Teems::Services::TokenStore.new.save(name: 'default', auth_token: 'auth', skype_token: 'skype')
        data = JSON.parse(File.read("#{dir}/teems/tokens.json"))
        assert data.key?('saved_at')
        assert_instance_of Time, Time.parse(data['saved_at'])
      end
    end

    def test_save_with_optional_chatsvc_token
      with_temp_config do |dir|
        Teems::Services::TokenStore.new.save(name: 'default', auth_token: 'auth', skype_token: 'skype',
                                             chatsvc_token: 'chatsvc')
        assert_equal 'chatsvc', JSON.parse(File.read("#{dir}/teems/tokens.json"))['chatsvc_token']
      end
    end

    def test_clear_removes_tokens
      with_temp_config do |dir|
        write_tokens_file(dir, { 'auth_token' => 'test-auth', 'skype_token' => 'test-skype' })
        store = Teems::Services::TokenStore.new
        assert store.configured?
        store.clear
        refute_predicate store, :configured?
      end
    end

    def test_token_age_returns_nil_when_no_tokens
      with_temp_config do
        assert_nil Teems::Services::TokenStore.new.token_age
      end
    end

    def test_token_age_returns_nil_when_no_saved_at
      with_temp_config do |dir|
        write_tokens_file(dir, { 'auth_token' => 'test-auth', 'skype_token' => 'test-skype' })
        assert_nil Teems::Services::TokenStore.new.token_age
      end
    end

    def test_token_age_returns_age_in_seconds
      with_temp_config do |dir|
        saved_at = (Time.now - 3600).iso8601
        write_tokens_file(dir, { 'auth_token' => 'auth', 'skype_token' => 'skype', 'saved_at' => saved_at })
        assert_in_delta 3600, Teems::Services::TokenStore.new.token_age, 5
      end
    end

    def test_token_age_prefers_tokens_refreshed_at_over_saved_at
      with_temp_config do |dir|
        now = Time.now
        saved_at = (now - 7200).iso8601
        refreshed_at = (now - 600).iso8601
        write_tokens_file(dir, { 'auth_token' => 'auth', 'skype_token' => 'skype',
                                 'saved_at' => saved_at, 'tokens_refreshed_at' => refreshed_at })
        assert_in_delta 600, Teems::Services::TokenStore.new.token_age, 5
      end
    end

    def test_creates_config_directory_if_needed
      with_temp_config do |dir|
        config_dir = "#{dir}/teems"
        refute File.exist?(config_dir)
        Teems::Services::TokenStore.new.save(name: 'default', auth_token: 'auth', skype_token: 'skype')
        assert File.directory?(config_dir)
      end
    end
  end

  # Tests file permissions, skype token updates, spaces token access, and refresh timestamps
  class SaveAndUpdateTest < Minitest::Test
    def test_save_creates_file_with_restricted_permissions
      with_temp_config do |dir|
        Teems::Services::TokenStore.new.save(name: 'default', auth_token: 'auth', skype_token: 'skype')
        tokens_file = "#{dir}/teems/tokens.json"
        assert File.exist?(tokens_file)
        mode = File.stat(tokens_file).mode & 0o777
        assert_equal 0o600, mode, "Expected file mode 0600, got #{format('%o', mode)}"
      end
    end

    def test_save_with_skype_spaces_token
      with_temp_config do |dir|
        Teems::Services::TokenStore.new.save(name: 'default', auth_token: 'auth', skype_token: 'skype',
                                             skype_spaces_token: 'spaces-token')
        assert_equal 'spaces-token', JSON.parse(File.read("#{dir}/teems/tokens.json"))['skype_spaces_token']
      end
    end

    def test_skype_spaces_token_returns_stored_token
      with_temp_config do |dir|
        write_tokens_file(dir, { 'auth_token' => 'auth', 'skype_token' => 'skype',
                                 'skype_spaces_token' => 'my-spaces-token' })
        assert_equal 'my-spaces-token', Teems::Services::TokenStore.new.skype_spaces_token
      end
    end

    def test_skype_spaces_token_returns_nil_when_not_set
      with_temp_config do |dir|
        write_tokens_file(dir, { 'auth_token' => 'auth', 'skype_token' => 'skype' })
        assert_nil Teems::Services::TokenStore.new.skype_spaces_token
      end
    end

    def test_skype_spaces_token_returns_nil_when_no_tokens_file
      with_temp_config do
        assert_nil Teems::Services::TokenStore.new.skype_spaces_token
      end
    end

    def test_update_skype_token_updates_token
      with_temp_config do |dir|
        write_tokens_file(dir, { 'auth_token' => 'auth', 'skype_token' => 'old-skype',
                                 'skype_spaces_token' => 'spaces' })
        store = Teems::Services::TokenStore.new
        assert store.update_skype_token('new-skype')
        assert_equal 'new-skype', store.account.skype_token
      end
    end

    def test_update_skype_token_preserves_other_fields
      with_temp_config do |dir|
        write_tokens_file(dir, { 'auth_token' => 'auth', 'skype_token' => 'old-skype',
                                 'skype_spaces_token' => 'spaces', 'name' => 'myaccount' })
        Teems::Services::TokenStore.new.update_skype_token('new-skype')
        data = JSON.parse(File.read("#{dir}/teems/tokens.json"))
        assert_equal 'myaccount', data['name']
        assert_equal 'auth', data['auth_token']
        assert_equal 'spaces', data['skype_spaces_token']
      end
    end

    def test_update_skype_token_adds_refreshed_at_timestamp
      with_temp_config do |dir|
        write_tokens_file(dir, { 'auth_token' => 'auth', 'skype_token' => 'old-skype' })
        Teems::Services::TokenStore.new.update_skype_token('new-skype')
        data = JSON.parse(File.read("#{dir}/teems/tokens.json"))
        refreshed_at = data['skype_token_refreshed_at']
        assert refreshed_at
        assert_match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/, refreshed_at)
      end
    end

    def test_update_skype_token_returns_false_when_no_tokens
      with_temp_config do
        refute Teems::Services::TokenStore.new.update_skype_token('new-skype')
      end
    end

    def test_update_skype_token_sets_restricted_permissions
      with_temp_config do |dir|
        write_tokens_file(dir, { 'auth_token' => 'auth', 'skype_token' => 'old-skype' })
        Teems::Services::TokenStore.new.update_skype_token('new-skype')
        tokens_file = "#{dir}/teems/tokens.json"
        mode = File.stat(tokens_file).mode & 0o777
        assert_equal 0o600, mode, "Expected file mode 0600, got #{format('%o', mode)}"
      end
    end
  end

  # Tests OIDC field accessors for refresh_token, client_id, and tenant_id
  class OidcFieldsTest < Minitest::Test
    def test_refresh_token_returns_stored_value
      with_temp_config do |dir|
        write_tokens_file(dir, base_tokens.merge('refresh_token' => 'my-rt'))
        assert_equal 'my-rt', Teems::Services::TokenStore.new.refresh_token
      end
    end

    def test_client_id_returns_stored_value
      with_temp_config do |dir|
        write_tokens_file(dir, base_tokens.merge('client_id' => 'my-cid'))
        assert_equal 'my-cid', Teems::Services::TokenStore.new.client_id
      end
    end

    def test_tenant_id_returns_stored_value
      with_temp_config do |dir|
        write_tokens_file(dir, base_tokens.merge('tenant_id' => 'my-tid'))
        assert_equal 'my-tid', Teems::Services::TokenStore.new.tenant_id
      end
    end

    def test_refresh_token_returns_nil_when_not_set
      with_temp_config do |dir|
        write_tokens_file(dir, base_tokens)
        assert_nil Teems::Services::TokenStore.new.refresh_token
      end
    end

    def test_oidc_fields_return_nil_when_no_file
      with_temp_config do
        store = Teems::Services::TokenStore.new
        assert_nil store.refresh_token
        assert_nil store.client_id
        assert_nil store.tenant_id
      end
    end

    private

    def base_tokens
      { 'auth_token' => 'auth', 'skype_token' => 'skype' }
    end
  end

  # Tests bulk token update with field preservation and nil optional field handling
  class UpdateAllTokensTest < Minitest::Test
    def test_updates_auth_and_skype_tokens
      with_temp_config do |dir|
        store = build_store_with_all_fields(dir)
        store.update_all_tokens(auth_token: 'new-auth', skype_token: 'new-skype',
                                skype_spaces_token: 'new-spaces', refresh_token: 'new-rt')
        account = store.account
        assert_equal 'new-auth', account.auth_token
        assert_equal 'new-skype', account.skype_token
      end
    end

    def test_updates_oidc_fields
      with_temp_config do |dir|
        store = build_store_with_all_fields(dir)
        store.update_all_tokens(auth_token: 'new-auth', skype_token: 'new-skype',
                                skype_spaces_token: 'new-spaces', refresh_token: 'new-rt')
        assert_equal 'new-spaces', store.skype_spaces_token
        assert_equal 'new-rt', store.refresh_token
      end
    end

    def test_preserves_existing_fields
      with_temp_config do |dir|
        write_tokens_file(dir, { 'auth_token' => 'old', 'skype_token' => 'old',
                                 'name' => 'myaccount', 'client_id' => 'cid', 'tenant_id' => 'tid' })
        Teems::Services::TokenStore.new.update_all_tokens(auth_token: 'new', skype_token: 'new')
        data = read_tokens(dir)
        assert_equal 'myaccount', data['name']
        assert_equal 'cid', data['client_id']
      end
    end

    def test_adds_refreshed_at_timestamp
      with_temp_config do |dir|
        write_tokens_file(dir, { 'auth_token' => 'auth', 'skype_token' => 'skype' })
        Teems::Services::TokenStore.new.update_all_tokens(auth_token: 'new', skype_token: 'new')
        assert read_tokens(dir)['tokens_refreshed_at']
      end
    end

    def test_returns_false_when_no_tokens_file
      with_temp_config do
        refute Teems::Services::TokenStore.new.update_all_tokens(auth_token: 'new', skype_token: 'new')
      end
    end

    def test_skips_nil_optional_fields
      with_temp_config do |dir|
        write_tokens_file(dir, { 'auth_token' => 'old', 'skype_token' => 'old',
                                 'skype_spaces_token' => 'keep', 'refresh_token' => 'keep-rt' })
        Teems::Services::TokenStore.new.update_all_tokens(auth_token: 'new', skype_token: 'new')
        data = read_tokens(dir)
        assert_equal 'keep', data['skype_spaces_token']
        assert_equal 'keep-rt', data['refresh_token']
      end
    end

    private

    def build_store_with_all_fields(dir)
      write_tokens_file(dir, { 'auth_token' => 'old-auth', 'skype_token' => 'old-skype',
                               'skype_spaces_token' => 'old-spaces', 'refresh_token' => 'old-rt',
                               'name' => 'default' })
      Teems::Services::TokenStore.new
    end

    def read_tokens(dir) = JSON.parse(File.read("#{dir}/teems/tokens.json"))
  end

  # Tests IO error recovery for save, update, and bad timestamp handling
  class ErrorHandlingTest < Minitest::Test
    def test_save_returns_false_on_io_error
      with_temp_config do |dir|
        config_dir = "#{dir}/teems"
        FileUtils.mkdir_p(config_dir)
        File.chmod(0o000, config_dir)
        result = Teems::Services::TokenStore.new.save(name: 'default', auth_token: 'auth', skype_token: 'skype')
        assert_equal false, result
      ensure
        File.chmod(0o755, config_dir)
      end
    end

    def test_update_skype_token_returns_false_on_io_error
      with_temp_config do |dir|
        write_tokens_file(dir, { 'auth_token' => 'auth', 'skype_token' => 'old' })
        tokens_file = "#{dir}/teems/tokens.json"
        File.chmod(0o444, tokens_file)
        result = Teems::Services::TokenStore.new.update_skype_token('new-skype')
        assert_equal false, result
      ensure
        File.chmod(0o644, tokens_file)
      end
    end

    def test_update_all_tokens_returns_false_on_io_error
      with_temp_config do |dir|
        write_tokens_file(dir, { 'auth_token' => 'auth', 'skype_token' => 'old' })
        tokens_file = "#{dir}/teems/tokens.json"
        File.chmod(0o444, tokens_file)
        result = Teems::Services::TokenStore.new.update_all_tokens(auth_token: 'new', skype_token: 'new')
        assert_equal false, result
      ensure
        File.chmod(0o644, tokens_file)
      end
    end

    def test_token_age_returns_nil_on_bad_timestamp
      with_temp_config do |dir|
        write_tokens_file(dir, { 'auth_token' => 'auth', 'skype_token' => 'skype',
                                 'saved_at' => 'not-a-timestamp' })
        assert_nil Teems::Services::TokenStore.new.token_age
      end
    end
  end
end
