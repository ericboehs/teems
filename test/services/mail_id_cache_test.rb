# frozen_string_literal: true

require 'test_helper'

class MailIdCacheTest < Minitest::Test
  def mail_message(id) = Teems::Models::MailMessage.from_api(sample_mail_message('id' => id))

  def test_remember_and_resolve
    with_temp_config do
      cache = Teems::Services::MailIdCache.new
      cache.remember([mail_message('id-one'), mail_message('id-two')])
      short = mail_message('id-one').short_id

      assert_equal 'id-one', cache.resolve(short)
      assert_equal 'id-one', cache.resolve(short[0, 5].upcase)
      assert_nil cache.resolve('0000')
    end
  end

  def test_full_ids_pass_through_and_empty_remember_is_harmless
    with_temp_config do
      cache = Teems::Services::MailIdCache.new
      cache.remember([])

      assert_equal 'AAkALfull', cache.resolve(' AAkALfull ')
    end
  end

  def test_ambiguous_prefix_is_nil
    with_temp_config do
      cache = Teems::Services::MailIdCache.new
      path = Teems::Support::XdgPaths.new.cache_file('mail-ids.json')
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.generate('abcd1111' => 'x', 'abcd2222' => 'y'))

      assert_nil cache.resolve('abcd')
      assert_equal 'x', cache.resolve('abcd1')
    end
  end

  def test_corrupt_or_non_hash_cache
    with_temp_config do
      path = Teems::Support::XdgPaths.new.cache_file('mail-ids.json')
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, '{oops')

      assert_nil Teems::Services::MailIdCache.new.resolve('abcd')
      File.write(path, '[1]')

      assert_nil Teems::Services::MailIdCache.new.resolve('abcd')
    end
  end
end
