# frozen_string_literal: true

require 'test_helper'

class MailRuleTextTest < Minitest::Test
  def setup
    @projects = sample_mail_folder('Projects')['id']
    @text = Teems::Formatters::MailRuleText.new(@projects => 'Inbox/Projects')
  end

  def describe(**overrides) = @text.describe(Teems::Models::MailRule.from_api(sample_mail_rule(**overrides)))

  def test_moves_to_a_named_folder
    assert_equal 'from jira@example.com -> move to Inbox/Projects, stop', describe
  end

  def test_unknown_folders_and_text_conditions
    assert_equal 'subject has "a", "b", sender has "c" -> copy to another folder, mark read',
                 describe('conditions' => { 'subjectContains' => %w[a b], 'senderContains' => ['c'] },
                          'actions' => { 'copyToFolder' => 'gone', 'markAsRead' => true })
  end

  def test_exceptions_switches_and_skipped_values
    assert_equal 'meeting requests, to Pat, except body has "x" -> categories Red, Blue, delete',
                 describe('conditions' => { 'isMeetingRequest' => true,
                                            'sentToAddresses' => [{ 'emailAddress' => { 'name' => 'Pat' } }],
                                            'hasAttachments' => false, 'headerContains' => [] },
                          'exceptions' => { 'bodyContains' => ['x'] },
                          'actions' => { 'assignCategories' => %w[Red Blue], 'delete' => true,
                                         'markImportance' => nil })
  end

  def test_no_conditions_and_unknown_keys
    assert_equal 'all mail -> FORWARD to a@example.com, is automatic reply, sensitivity private',
                 describe('conditions' => {},
                          'actions' => { 'forwardTo' => [{ 'emailAddress' => { 'address' => 'a@example.com' } }],
                                         'isAutomaticReply' => true, 'sensitivity' => 'private' })
  end
end
