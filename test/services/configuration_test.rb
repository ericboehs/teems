# frozen_string_literal: true

require 'test_helper'

class ConfigurationTest < Minitest::Test
  def test_bracket_returns_nil_for_unknown_key
    with_temp_config do
      config = Teems::Services::Configuration.new
      assert_nil config[:unknown_key]
    end
  end

  def test_bracket_returns_value_for_known_key
    with_temp_config do
      config = Teems::Services::Configuration.new
      config[:my_key] = 'my_value'

      assert_equal 'my_value', config[:my_key]
    end
  end

  def test_bracket_assignment_persists_value
    with_temp_config do
      config = Teems::Services::Configuration.new
      config['persisted_key'] = 'persisted_value'

      # Create new config instance (uses string keys from JSON)
      new_config = Teems::Services::Configuration.new
      assert_equal 'persisted_value', new_config['persisted_key']
    end
  end

  def test_bracket_works_with_string_keys
    with_temp_config do
      config = Teems::Services::Configuration.new
      config['string_key'] = 'value'

      assert_equal 'value', config['string_key']
    end
  end

  def test_to_h_returns_empty_hash_when_no_config
    with_temp_config do
      config = Teems::Services::Configuration.new
      assert_equal({}, config.to_h)
    end
  end

  def test_to_h_returns_all_values
    with_temp_config do
      config = Teems::Services::Configuration.new
      config['key1'] = 'value1'
      config['key2'] = 'value2'

      all = config.to_h
      assert_equal 'value1', all['key1']
      assert_equal 'value2', all['key2']
    end
  end

  def test_to_h_returns_copy
    with_temp_config do
      config = Teems::Services::Configuration.new
      config['key'] = 'value'

      all = config.to_h
      all['key'] = 'modified'

      # Original config should not be affected
      assert_equal 'value', config['key']
    end
  end

  # Corruption handling
  def test_corrupted_config_file_uses_defaults
    with_temp_config do |dir|
      config_dir = "#{dir}/teems"
      FileUtils.mkdir_p(config_dir)
      File.write("#{config_dir}/config.json", 'not valid json{{{')

      config = Teems::Services::Configuration.new

      # Should not raise, but use empty defaults
      assert_equal({}, config.to_h)
    end
  end

  def test_on_warning_callback_called_on_corruption
    with_temp_config do |dir|
      write_invalid_config(dir)
      warnings = []
      config = Teems::Services::Configuration.new
      config.on_warning = warnings.method(:push)
      config.to_h
      assert_equal 1, warnings.size
      assert_match(/corrupted/, warnings.first)
    end
  end

  def write_invalid_config(dir)
    config_dir = "#{dir}/teems"
    FileUtils.mkdir_p(config_dir)
    File.write("#{config_dir}/config.json", 'invalid json')
  end
  private :write_invalid_config

  def test_creates_config_directory_if_needed
    with_temp_config do |dir|
      config_dir = "#{dir}/teems"
      refute File.exist?(config_dir)

      config = Teems::Services::Configuration.new
      config['key'] = 'value'

      assert File.directory?(config_dir)
    end
  end

  def test_save_creates_file_with_restricted_permissions
    with_temp_config do |dir|
      config = Teems::Services::Configuration.new
      config['key'] = 'value'

      config_file = "#{dir}/teems/config.json"

      assert File.exist?(config_file)
      mode = File.stat(config_file).mode & 0o777
      assert_equal 0o600, mode, "Expected file mode 0600, got #{format('%o', mode)}"
    end
  end
end
