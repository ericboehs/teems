# frozen_string_literal: true

require 'test_helper'

class HtmlEntitiesTest < Minitest::Test
  Entities = Teems::Formatters::HtmlEntities

  def test_decodes_named_decimal_and_hex
    assert_equal "a & b \u00a0 \u2014 \u00e9 \u00e9", Entities.decode('a &amp; b &nbsp; &mdash; &#233; &#xE9;')
  end

  def test_unknown_named_and_invalid_codepoints
    assert_equal '&bogus; x', Entities.decode('&bogus; &#0;x')
    assert_equal '', Entities.decode('&#xD800;&#1114112;')
  end

  def test_text_without_ampersand_is_returned
    text = 'plain'

    assert_same text, Entities.decode(text)
  end
end
