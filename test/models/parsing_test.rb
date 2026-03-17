# frozen_string_literal: true

require 'test_helper'

# Tests shared Parsing module methods for HTML stripping, time parsing, and JSON file parsing
class ParsingTest < Minitest::Test
  include Teems::Models::Parsing

  def test_strip_html_removes_tags
    assert_equal 'Hello world', strip_html('<p>Hello <b>world</b></p>')
  end

  def test_strip_html_decodes_entities
    assert_equal 'A & B', strip_html('A &amp; B')
  end

  def test_strip_html_handles_nbsp
    assert_equal 'Hello world', strip_html('Hello&nbsp;world')
  end

  def test_strip_html_returns_nil_for_nil
    assert_nil strip_html(nil)
  end

  def test_strip_html_collapses_whitespace
    assert_equal 'a b c', strip_html('a   b   c')
  end

  def test_parse_time_returns_time
    result = parse_time('2026-01-20T12:00:00Z')

    assert_instance_of Time, result
    assert_equal 2026, result.year
  end

  def test_parse_time_returns_nil_for_nil
    assert_nil parse_time(nil)
  end

  def test_parse_time_returns_nil_for_invalid
    assert_nil parse_time('not-a-date')
  end

  def test_parse_files_json_returns_parsed_array
    result = parse_files_json('[{"fileName":"doc.pdf"}]')

    assert_equal [{ 'fileName' => 'doc.pdf' }], result
  end

  def test_parse_files_json_returns_empty_for_nil
    assert_equal [], parse_files_json(nil)
  end

  def test_parse_files_json_returns_empty_for_invalid_json
    assert_equal [], parse_files_json('not json')
  end

  def test_parse_mentions_groups_by_mri
    data = [
      { 'mri' => '8:orgid:abc', 'displayName' => 'Jane' },
      { 'mri' => '8:orgid:abc', 'displayName' => 'Smith' }
    ]
    assert_equal ['Jane Smith'], parse_mentions(JSON.generate(data))
  end

  def test_parse_mentions_multiple_mris
    data = [
      { 'mri' => '8:orgid:abc', 'displayName' => 'Jane' },
      { 'mri' => '8:orgid:def', 'displayName' => 'Bob' }
    ]
    result = parse_mentions(JSON.generate(data))
    assert_includes result, 'Jane'
    assert_includes result, 'Bob'
  end

  def test_parse_mentions_returns_empty_for_nil
    assert_equal [], parse_mentions(nil)
  end

  def test_parse_mentions_returns_empty_for_invalid_json
    assert_equal [], parse_mentions('not json')
  end

  def test_parse_mentions_handles_array_input
    data = [{ 'mri' => '8:orgid:abc', 'displayName' => 'Jane' }]
    assert_equal ['Jane'], parse_mentions(data)
  end

  def test_parse_mentions_returns_empty_for_non_array
    assert_equal [], parse_mentions('{"not": "array"}')
  end

  def test_parse_mentions_skips_entries_without_mri
    data = [{ 'displayName' => 'Jane' }]
    assert_equal [], parse_mentions(data)
  end

  def test_parse_mentions_skips_empty_display_names
    data = [{ 'mri' => '8:orgid:abc', 'displayName' => nil }]
    assert_equal [], parse_mentions(data)
  end
end
