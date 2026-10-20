# frozen_string_literal: true

require 'test_helper'

class HtmlTextTest < Minitest::Test
  def convert(html) = Teems::Formatters::HtmlText.convert(html)

  def test_outlook_paragraphs_are_single_lines_and_nbsp_paragraphs_blank
    html = '<html><head><style>p{}</style><title>x</title></head><body><!--[if mso]>junk<![endif]-->' \
           '<p class=MsoNormal>Hi Eric,<o:p></o:p></p><p class=MsoNormal>&nbsp;</p>' \
           '<p class="MsoNormal">Thanks</p></body></html>'

    assert_equal "Hi Eric,\n\nThanks", convert(html).text
  end

  def test_plain_paragraphs_get_blank_lines_and_whitespace_collapses
    assert_equal "One two\n\nThree", convert("<p>One\n   two</p><p>  Three  </p>").text
  end

  def test_links_get_markers_and_a_deduplicated_footer
    html = '<p>See <a href="https://example.com/doc?id=5&amp;utm_source=mail">the doc</a> and ' \
           '<a href="https://example.com/doc?id=5">again</a> or <a href="mailto:a@b.c">mail</a>.</p>'
    result = convert(html)

    assert_equal 'See the doc [1] and again [1] or mail.', result.text
    assert_equal "Links:\n[1] the doc <https://example.com/doc?id=5>", result.footer
    assert_equal "#{result.text}\n\n#{result.footer}", result.to_s
  end

  def test_result_without_links_is_just_text
    result = convert('<div>plain</div>')

    assert_equal '', result.footer
    assert_equal 'plain', result.to_s
  end

  def test_image_link_uses_alt_text_and_unlabeled_url_text
    html = '<a href="https://example.org/"><img src="cid:1" alt="Org logo"></a>' \
           '<a href="https://www.example.org/x">example.org/x</a><a href="https://e.com/y">https://e.com/y</a>'
    footer = convert(html).footer

    assert_includes footer, '[1] Org logo <https://example.org/>'
    assert_includes footer, '[2] https://www.example.org/x'
    assert_includes footer, '[3] https://e.com/y'
  end

  def test_images_outside_links_and_without_alt_add_nothing
    result = convert('<img src="cid:1" alt="Banner"><a href="https://e.com/a"><img src="cid:2">Go</a>')

    assert_equal 'Go [1]', result.text
    assert_equal "Links:\n[1] Go <https://e.com/a>", result.footer
  end

  def test_later_anchor_supplies_missing_label
    html = '<a href="https://e.com/a">https://e.com/a</a> <a href="https://e.com/a">Report</a>'

    assert_equal "Links:\n[1] Report <https://e.com/a>", convert(html).footer
  end

  def test_long_labels_are_truncated
    label = 'word ' * 30
    footer = convert(%(<a href="https://e.com/a">#{label}</a>)).footer

    assert_includes footer, "[1] #{'word ' * 15}wo... <https"
  end

  def test_lists_rules_tables_and_breaks
    html = '<ul><li>One</li><li>Two</li></ul><hr><table><tr><td>a</td><td>b</td></tr></table>x<br>y<br><br>z'

    assert_equal "- One\n- Two\n#{'_' * 32}\na b\nx\ny\n\nz", convert(html).text
  end

  def test_pre_keeps_whitespace
    assert_equal "before\n  code\n    more\nafter", convert("before<pre>  code\n    more</pre>after").text
  end

  def test_anchor_without_href_ends_previous_anchor_and_unclosed_anchor_is_kept
    html = '<a href="https://e.com/1">one<a name="x">two</a> <a href="https://e.com/2">three'
    result = convert(html)

    assert_equal 'one [1]two three [2]', result.text
    assert_includes result.footer, '[2] three <https://e.com/2>'
  end

  def test_stray_angle_brackets_and_entities
    assert_equal 'a < b & c > d © é', convert('a < b &amp; c &gt; d &copy; &#233;').text
  end

  def test_zero_width_characters_are_removed
    assert_equal 'ab', convert("a\u200b\u00adb").text
  end

  def test_invalid_bytes_are_dropped
    assert_equal 'ab', convert("a\xFFb".dup.force_encoding('UTF-8')).text
  end

  def test_nil_html
    assert_equal '', convert(nil).text
  end

  def test_trailing_whitespace_is_trimmed_after_multibyte_text
    assert_equal "naïve café\n\nnext", convert("<p>naïve café \t </p><p>next</p>").text
    assert_equal "über\nzwei", convert("über \t<br>zwei").text
  end

  # Block boundaries used to rescan the whole buffer with end-anchored regexes, so a 365KB
  # Outlook message took 10s. Linear now: about 0.1s. The limit leaves room for slow CI.
  def test_long_outlook_message_converts_in_linear_time
    para = "<p class=MsoNormal><span>Paragraph – with <a href='https://example.com/x'>a link</a></span></p>\n"
    html = "<div class=WordSection1>#{para * 2000}</div>"
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = convert(html)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2.0
    assert_equal 2000, result.text.lines.count
  end

  # Numbering a link used to search every URL collected so far, so a body with thousands of
  # distinct links took quadratic time (about 5s for these 30,000). Now under 1s; the limit
  # leaves room for slow CI.
  def test_many_distinct_links_number_in_linear_time
    html = (1..30_000).map { |number| "<a href='https://example.com/#{number}'>link #{number}</a> " }.join
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = convert(html)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2.5
    assert_includes result.text, 'link 30000 [30000]'
  end
end
