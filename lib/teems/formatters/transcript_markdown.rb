# frozen_string_literal: true

require 'json'

module Teems
  module Formatters
    # Converts Teams WebVTT transcripts into speaker-turn Markdown for local search indexes.
    # Consecutive cues from the same speaker are merged so each paragraph carries context.
    class TranscriptMarkdown
      Cue = Data.define(:start, :speaker, :text)

      TIMING = /\A(?<start>(?:\d+:)?\d{2}:\d{2}\.\d{3})\s+-->/
      VOICE = /<v(?:\.[^\s>]+)?\s+([^>]+)>/
      ENTITIES = {
        '&amp;' => '&', '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&#39;' => "'",
        '&apos;' => "'", '&nbsp;' => ' ', '&lrm;' => '', '&rlm;' => ''
      }.freeze
      ENTITY_PATTERN = Regexp.union(ENTITIES.keys)
      MAX_TURN_CHARS = 1500

      def initialize(vtt, title:, date: nil, source: nil)
        @vtt = vtt.to_s
        @title = single_line(title).then { |value| value.empty? ? 'Teams transcript' : value }
        @date = date
        @source = source
      end

      def render
        lines = front_matter + ["# #{@title}", '', ['Teams transcript', @date].compact.join(' · '), '']
        turns.each { |turn| lines.push(format_turn(turn), '') }
        "#{lines.join("\n").rstrip}\n"
      end

      def turns
        cues.each_with_object([]) { |cue, turns| append_cue(turns, cue) }
      end

      private

      def append_cue(turns, cue)
        last = turns.last
        if last && last[:speaker] == cue.speaker && last[:text].length < MAX_TURN_CHARS
          last[:text] << ' ' << cue.text
        else
          turns << { start: cue.start, speaker: cue.speaker, text: +cue.text }
        end
      end

      def cues
        normalized = @vtt.scrub.delete_prefix("\uFEFF").gsub(/\r\n?/, "\n")
        normalized.split(/\n{2,}/).filter_map { |block| parse_cue(block) }
      end

      def parse_cue(block)
        lines = block.lines.map(&:chomp)
        timing_index = lines.index { |line| TIMING.match?(line) }
        return unless timing_index

        build_cue(lines[timing_index][TIMING, :start], lines[(timing_index + 1)..].join(' '))
      end

      def build_cue(start, raw)
        text = clean(raw)
        return if text.empty?

        Cue.new(start: start, speaker: raw[VOICE, 1]&.then { |name| clean(name) }, text: text)
      end

      def clean(text) = single_line(decode(text.gsub(/<[^>]*>/, '')))

      def decode(text) = text.gsub(ENTITY_PATTERN, ENTITIES)

      def single_line(text) = text.to_s.gsub(/\s+/, ' ').strip

      def front_matter
        [
          '---',
          "title: #{@title.to_json}",
          ("date: #{@date}" if @date),
          'source: teams-transcript',
          ("vtt: #{@source.to_json}" if @source),
          '---',
          ''
        ].compact
      end

      def format_turn(turn)
        speaker = turn[:speaker] || 'Unknown speaker'
        "**#{speaker}** (#{turn[:start].sub(/\.\d+\z/, '')}): #{turn[:text]}"
      end
    end
  end
end
