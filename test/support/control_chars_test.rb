# frozen_string_literal: true

require 'test_helper'

class ControlCharsTest < Minitest::Test
  Chars = Teems::Support::ControlChars

  def test_strips_c0_c1_and_delete_but_keeps_tab_newline_and_unicode
    assert_equal "a]52;c;aGk=b\tc\nd\u00e9\u{1f600}",
                 Chars.strip("a\e]52;c;aGk=\ab\tc\r\nd\u00e9\u0000\u007f\u009b\u{1f600}")
  end

  def test_handles_nil_and_returns_clean_text_unchanged
    assert_equal '', Chars.strip(nil)
    text = 'plain'

    assert_same text, Chars.strip(text)
  end
end
