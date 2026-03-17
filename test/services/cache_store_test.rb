# frozen_string_literal: true

require 'test_helper'

# Tests CacheStore user caching, calendar ID storage, and cache clearing
class CacheStoreTest < Minitest::Test
  def test_get_user_returns_nil_for_unknown_user
    with_temp_config do
      store = Teems::Services::CacheStore.new
      assert_nil store.get_user('unknown-user-id')
    end
  end

  def test_set_user_and_get_user
    with_temp_config do
      store = Teems::Services::CacheStore.new
      store.set_user('user-123', 'John Doe')

      assert_equal 'John Doe', store.get_user('user-123')
    end
  end

  def test_set_user_overwrites_existing
    with_temp_config do
      store = Teems::Services::CacheStore.new
      store.set_user('user-123', 'John Doe')
      store.set_user('user-123', 'Jane Doe')

      assert_equal 'Jane Doe', store.get_user('user-123')
    end
  end

  def test_clear_removes_cached_users
    with_temp_config do
      store = Teems::Services::CacheStore.new
      store.set_user('user-123', 'John Doe')
      store.set_user('user-456', 'Jane Doe')

      store.clear

      assert_nil store.get_user('user-123')
      assert_nil store.get_user('user-456')
    end
  end

  def test_multiple_users_cached_independently
    with_temp_config do
      store = Teems::Services::CacheStore.new
      store.set_user('user-1', 'Alice')
      store.set_user('user-2', 'Bob')
      store.set_user('user-3', 'Charlie')

      assert_equal 'Alice', store.get_user('user-1')
      assert_equal 'Bob', store.get_user('user-2')
      assert_equal 'Charlie', store.get_user('user-3')
    end
  end

  def test_save_and_get_calendar_ids
    with_temp_config do
      store = Teems::Services::CacheStore.new
      store.save_calendar_ids({ '1' => 'event-abc', '2' => 'event-def' })

      assert_equal 'event-abc', store.get_calendar_id(1)
      assert_equal 'event-def', store.get_calendar_id(2)
    end
  end

  def test_get_calendar_id_returns_nil_when_no_file
    with_temp_config do
      store = Teems::Services::CacheStore.new

      assert_nil store.get_calendar_id(1)
    end
  end

  def test_get_calendar_id_returns_nil_on_corrupt_json
    with_temp_config do |dir|
      cache_dir = "#{dir}/cache/teems"
      FileUtils.mkdir_p(cache_dir)
      File.write("#{cache_dir}/calendar_ids.json", 'not valid json{{{')
      store = Teems::Services::CacheStore.new

      assert_nil store.get_calendar_id(1)
    end
  end

  def test_clear_removes_calendar_ids_file
    with_temp_config do
      store = Teems::Services::CacheStore.new
      store.save_calendar_ids({ '1' => 'event-abc' })
      store.clear

      assert_nil store.get_calendar_id(1)
    end
  end
end
