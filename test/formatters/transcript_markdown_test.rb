# frozen_string_literal: true

require 'test_helper'

class TranscriptMarkdownTest < Minitest::Test
  VTT = <<~VTT
    \uFEFFWEBVTT

    1
    00:01:05.877 --> 00:01:06.277
    <v Eric Boehs>Good afternoon.</v>

    2
    00:01:06.277 --> 00:01:07.557
    <v Eric Boehs>Tom &amp; Jerry &lt;3</v>

    3
    00:01:07.557 --> 00:01:09.000
    <v.loud Jordan, Brooke J.>Thanks, <b>everyone</b>.</v>

    4
    00:01:09.000 --> 00:01:10.000
    <v Eric Boehs>   </v>

    5
    01:02.000 --> 01:03.000
    No voice tag here
  VTT

  def render(vtt = VTT, **)
    Teems::Formatters::TranscriptMarkdown.new(vtt, title: "Weekly\nSync", date: '2026-09-29', **).render
  end

  def test_front_matter_and_heading
    markdown = render(source: 'Weekly "Sync".vtt')

    assert markdown.start_with?("---\ntitle: \"Weekly Sync\"\ndate: 2026-09-29\nsource: teams-transcript\n")
    assert_includes markdown, 'vtt: "Weekly \"Sync\".vtt"'
    assert_includes markdown, "---\n\n# Weekly Sync\n\nTeams transcript · 2026-09-29\n"
  end

  def test_merges_consecutive_speaker_cues_and_cleans_markup
    markdown = render

    assert_includes markdown, '**Eric Boehs** (00:01:05): Good afternoon. Tom & Jerry <3'
    assert_includes markdown, '**Jordan, Brooke J.** (00:01:07): Thanks, everyone.'
    assert_includes markdown, '**Unknown speaker** (01:02): No voice tag here'
    refute_includes markdown, '<v'
  end

  def test_blank_cues_are_skipped_and_crlf_is_supported
    turns = Teems::Formatters::TranscriptMarkdown.new(VTT.gsub("\n", "\r\n"), title: 'T').turns

    assert_equal(['Eric Boehs', 'Jordan, Brooke J.', nil], turns.map { |turn| turn[:speaker] })
  end

  def test_long_turns_are_split_for_search_chunks
    cue = ->(index) { "#{index}\n00:00:#{format('%02d', index)}.000 --> 00:00:59.000\n<v A>#{'x' * 900}</v>\n" }
    vtt = "WEBVTT\n\n#{(1..3).map(&cue).join("\n")}"
    turns = Teems::Formatters::TranscriptMarkdown.new(vtt, title: 'T').turns

    assert_equal(%w[00:00:01.000 00:00:03.000], turns.map { |turn| turn[:start] })
  end

  def test_empty_title_and_missing_date
    markdown = Teems::Formatters::TranscriptMarkdown.new("WEBVTT\n", title: ' ').render

    assert_includes markdown, "# Teams transcript\n\nTeams transcript\n"
    refute_includes markdown, 'date:'
  end
end
