# frozen_string_literal: true

module Teems
  module Formatters
    # `teems mail rules` output: a table, TSV, or JSON, each with MailRuleText's description
    class MailRuleFormatter
      NAME_WIDTH = 30

      # folder_names: Graph folder ID => path, to name where a rule moves mail
      def initialize(output:, folder_names: {})
        @output = output
        @text = MailRuleText.new(folder_names)
      end

      def describe(rule) = @text.describe(rule)

      def rows(rules)
        width = name_width(rules)
        rules.map { |rule| row(rule, width) }
      end

      def tsv_rows(rules) = rules.map { |rule| rule.tsv_row(describe(rule)) }

      def json(rules) = rules.map { |rule| rule.to_json_hash(describe(rule)) }

      private

      def name_width(rules) = rules.map { |rule| rule.name.length }.max.to_i.clamp(..NAME_WIDTH)

      def row(rule, width)
        number, state, name = rule.columns
        "#{number.to_s.rjust(3)}  #{state_text(state)}  #{name[0, width].ljust(width)}  #{describe(rule)}"
      end

      def state_text(state)
        padded = state.ljust(5)
        case state
        when 'on' then @output.green(padded)
        when 'off' then @output.gray(padded)
        else @output.red(padded)
        end
      end
    end
  end
end
