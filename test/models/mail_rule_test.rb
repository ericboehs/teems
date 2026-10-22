# frozen_string_literal: true

require 'test_helper'

class MailRuleTest < Minitest::Test
  def rule(**overrides) = Teems::Models::MailRule.from_api(sample_mail_rule(**overrides))

  def test_from_api
    jira = rule('sequence' => 4)

    assert_equal ['rule-Jira=', 'Jira', 4, true, false],
                 [jira.id, jira.name, jira.sequence, jira.enabled, jira.has_error]
    assert_equal [sample_mail_folder('Projects')['id']], jira.folder_ids
    assert_empty jira.exceptions
  end

  def test_missing_parts_are_empty
    bare = Teems::Models::MailRule.from_api({ 'id' => 'x', 'displayName' => "Bell\a" })

    assert_equal ['Bell', 0, false], [bare.name, bare.sequence, bare.enabled]
    assert_empty bare.conditions
    assert_empty bare.folder_ids
  end

  def test_state
    assert_equal 'on', rule.state
    assert_equal 'off', rule('isEnabled' => false).state
    assert_equal 'error', rule('hasError' => true).state
  end

  def test_forwards
    refute_predicate rule, :forwards?
    %w[forwardTo forwardAsAttachmentTo redirectTo].each do |key|
      assert_predicate rule('actions' => { key => [] }), :forwards?, key
    end
  end

  def test_rows_and_json
    assert_equal [1, 'on', 'Jira'], rule.columns
    assert_equal "rule-Jira=\t1\ton\tJira\tdescribed", rule.tsv_row('described')
    assert_equal({ id: 'rule-Jira=', description: 'described' },
                 rule.to_json_hash('described').slice(:id, :description))
  end
end
