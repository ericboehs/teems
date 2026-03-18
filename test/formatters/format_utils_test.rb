# frozen_string_literal: true

require 'test_helper'

# Tests for shared stateless formatting utilities
module FormatUtilsTests
  # Tests for text truncation and byte formatting
  class TextFormattingTest < Minitest::Test
    def test_truncate_short_text
      assert_equal 'hello', Teems::Formatters::FormatUtils.truncate('hello', 120)
    end

    def test_truncate_long_text
      text = 'a' * 130
      result = Teems::Formatters::FormatUtils.truncate(text, 120)
      assert_equal 123, result.length
      assert result.end_with?('...')
    end

    def test_truncate_exact_length
      text = 'a' * 120
      assert_equal text, Teems::Formatters::FormatUtils.truncate(text, 120)
    end

    def test_format_bytes_megabytes
      assert_equal '1.5 MB', Teems::Formatters::FormatUtils.format_bytes(1_572_864)
    end

    def test_format_bytes_kilobytes
      assert_equal '2.5 KB', Teems::Formatters::FormatUtils.format_bytes(2560)
    end

    def test_format_bytes_bytes
      assert_equal '500 B', Teems::Formatters::FormatUtils.format_bytes(500)
    end
  end

  # Tests for file name and attachment utilities
  class FileUtilsTest < Minitest::Test
    def test_safe_filename_strips_path
      assert_equal 'report.pdf', Teems::Formatters::FormatUtils.safe_filename('/path/to/report.pdf')
    end

    def test_safe_filename_empty_returns_file
      assert_equal 'file', Teems::Formatters::FormatUtils.safe_filename('')
    end

    def test_attachment_name_hash_with_filename
      assert_equal 'doc.pdf', Teems::Formatters::FormatUtils.attachment_name({ 'fileName' => 'doc.pdf' })
    end

    def test_attachment_name_hash_with_name
      assert_equal 'doc.pdf', Teems::Formatters::FormatUtils.attachment_name({ 'name' => 'doc.pdf' })
    end

    def test_attachment_name_hash_fallback
      assert_equal 'file', Teems::Formatters::FormatUtils.attachment_name({})
    end

    def test_attachment_name_non_hash
      assert_equal 'simple', Teems::Formatters::FormatUtils.attachment_name('simple')
    end
  end

  # Tests for reaction formatting
  class ReactionFormattingTest < Minitest::Test
    def test_format_single_reaction_known_emoji
      emoji_map = { 'like' => "\u{1F44D}" }
      result = Teems::Formatters::FormatUtils.format_single_reaction({ type: 'like', count: 1 }, emoji_map)
      assert_equal "\u{1F44D}", result
    end

    def test_format_single_reaction_with_count
      emoji_map = { 'like' => "\u{1F44D}" }
      result = Teems::Formatters::FormatUtils.format_single_reaction({ type: 'like', count: 3 }, emoji_map)
      assert_equal "\u{1F44D} \u00d73", result
    end

    def test_format_single_reaction_unknown_emoji
      result = Teems::Formatters::FormatUtils.format_single_reaction({ type: 'custom', count: 1 }, {})
      assert_equal 'custom', result
    end

    def test_format_single_reaction_nil_count
      emoji_map = { 'like' => "\u{1F44D}" }
      result = Teems::Formatters::FormatUtils.format_single_reaction({ type: 'like', count: nil }, emoji_map)
      assert_equal "\u{1F44D}", result
    end
  end

  # Tests for time formatting utilities
  class TimeFormattingTest < Minitest::Test
    def test_format_time_valid
      result = Teems::Formatters::FormatUtils.format_time('2026-01-20T14:30:00Z')
      assert_match(/\[2026-01-20/, result)
    end

    def test_format_time_nil
      assert_equal '', Teems::Formatters::FormatUtils.format_time(nil)
    end

    def test_format_time_invalid
      assert_equal '', Teems::Formatters::FormatUtils.format_time('not-a-date')
    end

    def test_format_end_time_same_day
      start_time = Time.new(2026, 1, 20, 14, 0, 0)
      end_time = Time.new(2026, 1, 20, 15, 0, 0)
      result = Teems::Formatters::FormatUtils.format_end_time(start_time, end_time)
      assert_match(/3:00 PM/, result)
    end

    def test_format_end_time_different_day
      start_time = Time.new(2026, 1, 20, 14, 0, 0)
      end_time = Time.new(2026, 1, 22, 15, 0, 0)
      result = Teems::Formatters::FormatUtils.format_end_time(start_time, end_time)
      assert_match(/Jan 22/, result)
    end

    def test_build_time_range_with_end
      end_match = '<EndDateTime>2026-01-20T15:00:00Z</EndDateTime>'.match(%r{<EndDateTime>(.+?)</EndDateTime>})
      start_time, end_time = Teems::Formatters::FormatUtils.build_time_range('2026-01-20T14:00:00Z', end_match)
      assert_instance_of Time, start_time
      assert_instance_of Time, end_time
    end

    def test_build_time_range_without_end
      start_time, end_time = Teems::Formatters::FormatUtils.build_time_range('2026-01-20T14:00:00Z', nil)
      assert_instance_of Time, start_time
      assert_nil end_time
    end
  end
end
