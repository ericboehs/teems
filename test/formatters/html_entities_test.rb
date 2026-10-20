# frozen_string_literal: true

require 'test_helper'

class HtmlEntitiesTest < Minitest::Test
  Entities = Teems::Formatters::HtmlEntities

  # An encoded ESC ]52 ... BEL would set the clipboard when printed
  def test_control_characters_decode_to_nothing
    assert_equal 'a]52;c;aGk=b', Entities.decode('a&#27;]52;c;aGk=&#7;b')
    assert_equal "x\ny", Entities.decode('x&#10;&#x1B;&#127;y')
  end

  def test_c1_references_mean_their_windows_characters
    assert_equal "\u2019 \u20ac \u2013", Entities.decode('&#146; &#128; &#x96;')
    assert_equal 'ab', Entities.decode('a&#129;b')
  end

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
