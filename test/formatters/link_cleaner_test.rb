# frozen_string_literal: true

require 'test_helper'

class LinkCleanerTest < Minitest::Test
  Cleaner = Teems::Formatters::LinkCleaner

  def test_unwraps_nested_safelinks
    inner = 'https://nam.safelinks.protection.outlook.com/?url=https%3A%2F%2Fexample.com%2Fa%3Fb%3D1&data=x'
    outer = "https://gcc02.safelinks.protection.office365.us/?url=#{URI.encode_www_form_component(inner)}&data=y"

    assert_equal 'https://example.com/a?b=1', Cleaner.clean(outer)
  end

  def test_safelinks_without_url_param_is_kept
    url = 'https://nam.safelinks.protection.outlook.com/?data=x'

    assert_equal url, Cleaner.clean(url)
  end

  def test_drops_utm_everywhere_and_sharepoint_noise_on_sharepoint
    assert_equal 'https://e.com/p?a=1#top', Cleaner.clean('https://e.com/p?utm_source=x&a=1&UTM_medium=y#top')
    assert_equal 'https://user@contoso.sharepoint.com:443/:w:/r/Doc.aspx?file=A.docx',
                 Cleaner.clean('https://user@contoso.sharepoint.com:443/:w:/r/Doc.aspx?file=A.docx&xsdata=1&CT=2')
    assert_equal 'https://e.com/p?ct=1', Cleaner.clean('https://e.com/p?ct=1')
  end

  def test_drops_query_entirely_when_only_tracking_and_empty_pairs_remain
    assert_equal 'https://e.com/p', Cleaner.clean("https://e.com/p?utm_source=x&&\n")
    assert_equal 'https://e.com/a%20b', Cleaner.clean(' https://e.com/a b ')
  end

  def test_non_urls_pass_through
    assert_equal 'not%20a%20url', Cleaner.clean('not a url')
    assert_equal 'relative/path', Cleaner.clean('relative/path')
  end

  def test_skip
    %w[mailto:a@b.c TEL:123 cid:img #top javascript:void(0) data:x].each { |href| assert Cleaner.skip?(href), href }
    assert Cleaner.skip?('')
    refute Cleaner.skip?('https://e.com')
  end

  def test_bad_safelinks_query
    url = 'https://nam.safelinks.protection.outlook.com/?url=%E0%A4%A'

    assert_kind_of String, Cleaner.clean(url)
    raw = "https://nam.safelinks.protection.outlook.com/?url=https://e.com/caf\u00e9"

    assert_equal raw, Cleaner.clean(raw), 'non-ASCII queries are kept as they are'
  end
end
