# frozen_string_literal: true

require 'test_helper'

class MailRuleFormatterTest < Minitest::Test
  def rule(name, **overrides) = Teems::Models::MailRule.from_api(sample_mail_rule(name, **overrides))

  def formatter(color: false)
    output = Teems::Formatters::Output.new(io: StringIO.new, color: color)
    Teems::Formatters::MailRuleFormatter.new(output: output,
                                             folder_names: { sample_mail_folder('Projects')['id'] => 'Projects' })
  end

  def test_rows_align_and_truncate_names
    rows = formatter.rows([rule('Jira', 'sequence' => 2), rule('N' * 40, 'sequence' => 10, 'isEnabled' => false)])

    assert_equal "  2  on     #{'Jira'.ljust(30)}  from jira@example.com -> move to Projects, stop", rows[0]
    assert_match(/\A 10  off    #{'N' * 30}  from/, rows[1])
  end

  def test_states_are_colored
    rows = formatter(color: true).rows([rule('A'), rule('B', 'isEnabled' => false), rule('C', 'hasError' => true)])

    colors = Teems::Formatters::Output::COLORS

    assert_equal(colors.values_at(:green, :gray, :red), rows.map { |row| row[5, 7] })
  end

  def test_empty_rows_tsv_and_json
    assert_empty formatter.rows([])
    assert_equal "rule-Jira=\t1\ton\tJira\tfrom jira@example.com -> move to Projects, stop",
                 formatter.tsv_rows([rule('Jira')]).first
    assert_equal 'from jira@example.com -> move to Projects, stop', formatter.json([rule('Jira')]).first[:description]
  end
end
