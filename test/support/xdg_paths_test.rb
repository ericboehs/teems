# frozen_string_literal: true

require 'test_helper'

class XdgPathsTest < Minitest::Test
  def test_config_dir_uses_xdg_config_home
    with_temp_config do |dir|
      paths = Teems::Support::XdgPaths.new

      assert_equal "#{dir}/teems", paths.config_dir
    end
  end

  def test_cache_dir_uses_xdg_cache_home
    with_temp_config do |dir|
      paths = Teems::Support::XdgPaths.new

      assert_equal "#{dir}/cache/teems", paths.cache_dir
    end
  end

  def test_config_file_joins_with_config_dir
    with_temp_config do |dir|
      paths = Teems::Support::XdgPaths.new

      assert_equal "#{dir}/teems/tokens.json", paths.config_file('tokens.json')
    end
  end

  def test_cache_file_joins_with_cache_dir
    with_temp_config do |dir|
      paths = Teems::Support::XdgPaths.new

      assert_equal "#{dir}/cache/teems/users.json", paths.cache_file('users.json')
    end
  end

  def test_ensure_config_dir_creates_directory
    with_temp_config do |dir|
      paths = Teems::Support::XdgPaths.new
      config_dir = "#{dir}/teems"

      refute File.exist?(config_dir)

      paths.ensure_config_dir

      assert File.directory?(config_dir)
    end
  end

  def test_ensure_cache_dir_creates_directory
    with_temp_config do |dir|
      paths = Teems::Support::XdgPaths.new
      cache_dir = "#{dir}/cache/teems"

      refute File.exist?(cache_dir)

      paths.ensure_cache_dir

      assert File.directory?(cache_dir)
    end
  end

  def test_data_dir_uses_xdg_data_home
    with_temp_config do |dir|
      paths = Teems::Support::XdgPaths.new

      assert_equal "#{dir}/data/teems", paths.data_dir
    end
  end

  def test_data_file_joins_with_data_dir
    with_temp_config do |dir|
      paths = Teems::Support::XdgPaths.new

      assert_equal "#{dir}/data/teems/sync_state.json", paths.data_file('sync_state.json')
    end
  end

  def test_ensure_data_dir_creates_directory
    with_temp_config do |dir|
      paths = Teems::Support::XdgPaths.new
      data_dir = "#{dir}/data/teems"

      refute File.exist?(data_dir)

      paths.ensure_data_dir

      assert File.directory?(data_dir)
    end
  end
end
