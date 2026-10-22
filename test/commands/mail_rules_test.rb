# frozen_string_literal: true

require 'test_helper'

# `teems mail rules`: listing, adding, turning on and off, and deleting Inbox rules
# rubocop:disable Metrics/MethodLength, Metrics/AbcSize, Metrics/ClassLength
class MailRulesCommandTest < Minitest::Test
  RULES = '/mailFolders/inbox/messageRules'

  # Stands in for a terminal on stdin that answers the confirmation prompt
  FakeTerminal = Struct.new(:answer) do
    def tty? = true
    def gets = answer
  end

  def setup
    @saved_stdin = $stdin
    $stdin = StringIO.new
  end

  def teardown
    $stdin = @saved_stdin
  end

  # The rules stub goes first: MockApiClient matches by substring, and the folder list
  # path is a prefix of the rules path
  def run_mail(args, rules: [sample_mail_rule], stubs: {}, errors: {})
    capture = capture_output do |output|
      runner = configured_runner(output: output)
      @api = runner.api_client
      @api.stub(RULES, { 'value' => rules })
      stubs.each { |path, response| @api.stub(path, response) }
      errors.each { |path, error| @api.stub_error(path, error) }
      @code = Teems::Commands::Mail.new(args, runner: runner).execute
    end
    capture.merge(code: @code)
  end

  def writes = @api.calls.reject { |call| call[:method] == :get }
  def folder_list = { 'value' => [sample_mail_folder('Inbox'), sample_mail_folder('Projects')] }

  def two_rules
    [sample_mail_rule('Jira', 'sequence' => 2),
     sample_mail_rule('Builds', 'sequence' => 1, 'isEnabled' => false,
                                'conditions' => { 'subjectContains' => ['build'] },
                                'actions' => { 'markAsRead' => true })]
  end

  def test_list_in_order_with_folder_names
    with_temp_config do
      result = run_mail(%w[rules], rules: two_rules, stubs: { '/v1.0/me/mailFolders' => folder_list })
      lines = result[:stdout].lines

      assert_equal 0, result[:code]
      assert_match(/\A  1  off    Builds  subject has "build" -> mark read$/, lines[0])
      assert_match(/\A  2  on     Jira    from jira@example.com -> move to Projects, stop$/, lines[1])
      assert_equal result[:stdout], run_mail(%w[rules list], rules: two_rules,
                                                             stubs: { '/v1.0/me/mailFolders' => folder_list })[:stdout]
    end
  end

  def test_list_skips_folders_when_no_rule_moves_mail
    with_temp_config do
      run_mail(%w[rules], rules: [two_rules.last])

      assert_equal 1, @api.calls.length
    end
  end

  def test_list_tsv_json_and_empty
    with_temp_config do
      stubs = { '/v1.0/me/mailFolders' => folder_list }

      assert_equal "rule-Jira=\t1\ton\tJira\tfrom jira@example.com -> move to Projects, stop\n",
                   run_mail(%w[rules --tsv], stubs: stubs)[:stdout]
      assert_equal 'rule-Jira=', JSON.parse(run_mail(%w[rules --json], stubs: stubs)[:stdout]).first['id']
      assert_includes run_mail(%w[rules], rules: [])[:stdout], 'No Inbox rules'
    end
  end

  def test_unknown_verb
    with_temp_config do
      result = run_mail(%w[rules rename])

      assert_equal 1, result[:code]
      assert_includes result[:stderr], 'Usage: teems mail rules <list|add|enable|disable|delete>'
    end
  end

  def test_add_builds_the_rule_last_in_order
    with_temp_config do
      result = run_mail(['rules', 'add', 'Reports', '--from', 'a@example.com', '--from', 'b@example.com',
                         '--subject', 'report', '--body', 'weekly', '--sent-to', 'team@example.com',
                         '--move-to', 'Projects', '--copy-to', 'archive', '--mark-read', '--category', 'Red',
                         '--category', 'Blue', '--importance', 'HIGH', '--stop'],
                        rules: two_rules,
                        stubs: { '/v1.0/me/mailFolders/archive' => sample_mail_folder('Archive'),
                                 '/v1.0/me/mailFolders' => folder_list })
      body = writes.first[:body]

      assert_equal 0, result[:code]
      assert_equal [:post, '/v1.0/me/mailFolders/inbox/messageRules'], writes.first.values_at(:method, :path)
      assert_equal({ 'displayName' => 'Reports', 'sequence' => 3, 'isEnabled' => true },
                   body.except('conditions', 'actions'))
      assert_equal({ 'fromAddresses' => [{ 'emailAddress' => { 'address' => 'a@example.com' } },
                                         { 'emailAddress' => { 'address' => 'b@example.com' } }],
                     'sentToAddresses' => [{ 'emailAddress' => { 'address' => 'team@example.com' } }],
                     'subjectContains' => ['report'], 'bodyContains' => ['weekly'] }, body['conditions'])
      assert_equal({ 'moveToFolder' => sample_mail_folder('Projects')['id'],
                     'copyToFolder' => sample_mail_folder('Archive')['id'], 'markAsRead' => true,
                     'assignCategories' => %w[Red Blue], 'markImportance' => 'high', 'stopProcessingRules' => true },
                   body['actions'])
      refute(body['actions'].keys.any? { |key| key.match?(/forward|redirect/i) })
    end
  end

  def test_add_reports_the_created_rule
    with_temp_config do
      created = sample_mail_rule('Junk', 'conditions' => { 'senderContains' => ['spam'] },
                                         'actions' => { 'delete' => true })
      result = run_mail(%w[rules add Junk --body spam --delete --disabled], rules: [], stubs: { RULES => created })

      assert_equal({ 'displayName' => 'Junk', 'sequence' => 1, 'isEnabled' => false },
                   writes.first[:body].slice('displayName', 'sequence', 'isEnabled'))
      assert_equal({ 'delete' => true }, writes.first[:body]['actions'])
      assert_includes result[:stdout], 'Added rule Junk: sender has "spam" -> delete'

      json = run_mail(%w[rules add Junk --body spam --delete --json], rules: [], stubs: { RULES => created })

      assert_equal 'sender has "spam" -> delete', JSON.parse(json[:stdout])['description']
    end
  end

  def test_add_dry_run_changes_nothing
    with_temp_config do
      result = run_mail(%w[rules add Builds2 --subject build --mark-read --dry-run])

      assert_equal 0, result[:code]
      assert_includes result[:stdout],
                      "Builds2: subject has \"build\" -> mark read\nWould add this rule (dry run, nothing changed)"
      assert_empty writes

      json = JSON.parse(run_mail(%w[rules add Builds2 --subject build --mark-read --dry-run --json])[:stdout])

      assert_equal({ 'markAsRead' => true }, json['actions'])
      assert_empty writes
    end
  end

  def test_add_refuses_incomplete_or_conflicting_rules
    with_temp_config do
      { %w[rules add] => 'Usage: teems mail rules add <name>',
        %w[rules add Jira --from x@example.com --mark-read] => 'A rule named Jira already exists',
        %w[rules add New --mark-read] => 'A rule needs a condition',
        %w[rules add New --from x@example.com] => 'A rule needs an action',
        %w[rules add New --from x@example.com --importance urgent] => '--importance must be low, normal, high',
        %w[rules add New --from x@example.com --move-to Projects --delete] => 'Use --move-to or --delete, not both' }
        .each do |args, message|
          result = run_mail(args)

          assert_equal 1, result[:code], args.join(' ')
          assert_includes result[:stderr], message
          assert_empty writes
        end
    end
  end

  def test_rule_options_outside_rules_add_are_refused
    with_temp_config do
      [%w[archive AAMk-1 --mark-read], %w[rules --from x@example.com], %w[list --move-to Projects]].each do |args|
        result = run_mail(args)

        assert_equal 1, result[:code], args.join(' ')
        assert_includes result[:stderr], 'Rule options (--from, --move-to, ...) go with rules add only'
        assert_empty @api.calls
      end
    end
  end

  def test_enable_and_disable
    with_temp_config do
      assert_includes run_mail(%w[rules disable jira])[:stdout], 'Rule Jira disabled'
      assert_equal [:patch, '/v1.0/me/mailFolders/inbox/messageRules/rule-Jira%3D', { isEnabled: false }],
                   writes.first.values_at(:method, :path, :body)

      assert_includes run_mail(%w[rules enable 1], rules: two_rules)[:stdout], 'Rule Builds enabled'
      assert_equal({ isEnabled: true }, writes.first[:body])

      assert_includes run_mail(%w[rules enable rule-Jira=])[:stdout], 'Rule Jira is already enabled'
      assert_empty writes
    end
  end

  def test_a_forwarding_rule_is_not_enabled
    with_temp_config do
      redirect = { 'redirectTo' => [{ 'emailAddress' => { 'address' => 'x@example.com' } }] }
      forwarder = sample_mail_rule('Fwd', 'isEnabled' => false, 'actions' => redirect)
      result = run_mail(%w[rules enable Fwd], rules: [forwarder])

      assert_equal 1, result[:code]
      assert_includes result[:stderr], 'Rule Fwd forwards or redirects mail; teems will not enable it'
      assert_empty writes
      assert_equal 0, run_mail(%w[rules disable Fwd], rules: [forwarder.merge('isEnabled' => true)])[:code]
    end
  end

  def test_finding_a_rule
    with_temp_config do
      twins = [sample_mail_rule('Same', 'id' => 'a'), sample_mail_rule('same', 'id' => 'b', 'sequence' => 2)]
      { %w[rules disable] => 'Usage: teems mail rules disable <name|number|id>',
        %w[rules disable Nope] => 'No Inbox rule matches Nope',
        %w[rules disable 9] => 'No Inbox rule matches 9' }.each do |args, message|
        assert_includes run_mail(args)[:stderr], message
      end
      assert_includes run_mail(%w[rules disable same], rules: twins)[:stderr], '2 rules are named same; use the ID'
      assert_includes run_mail(%w[rules disable b], rules: twins)[:stdout], 'Rule same disabled'
      assert_includes run_mail(%w[rules disable 2], rules: twins)[:stdout], 'Rule same disabled'
    end
  end

  def test_delete_with_yes_and_dry_run
    with_temp_config do
      assert_includes run_mail(%w[rules delete Jira --dry-run])[:stdout],
                      'Would delete rule Jira (dry run, nothing changed)'
      assert_empty writes

      assert_includes run_mail(%w[rules delete Jira -y])[:stdout], 'Deleted rule Jira'
      assert_equal [:delete, '/v1.0/me/mailFolders/inbox/messageRules/rule-Jira%3D'],
                   writes.first.values_at(:method, :path)
    end
  end

  def test_delete_asks
    with_temp_config do
      result = run_mail(%w[rules delete Jira])

      assert_equal 1, result[:code]
      assert_includes result[:stderr], 'Deleting rule Jira needs --yes without a terminal'

      $stdin = FakeTerminal.new("n\n")
      result = run_mail(%w[rules delete Jira])

      assert_includes result[:stderr], 'Delete rule Jira? [y/N] '
      assert_includes result[:stderr], 'Cancelled; nothing changed'
      assert_empty writes

      $stdin = FakeTerminal.new("yes\n")

      assert_equal 0, run_mail(%w[rules delete Jira])[:code]
      assert_equal 1, writes.length
    end
  end

  def test_errors_are_reported
    with_temp_config do
      denied = Teems::ApiError.new('HTTP 403: Forbidden', status_code: 403)
      result = run_mail(%w[rules disable Jira], errors: { '/messageRules/rule-Jira' => denied })

      assert_equal 1, result[:code]
      assert_includes result[:stderr], 'Mail request failed'
    end
  end

  def test_a_refreshed_token_does_not_ask_twice
    with_temp_config do
      $stdin = FakeTerminal.new("y\n")
      capture = capture_output do |output|
        runner = configured_runner(output: output)
        api = runner.api_client
        api.stub(RULES, { 'value' => [sample_mail_rule] })
        api.stub_transient_error('/messageRules/rule-Jira', Teems::ApiError.new('expired', status_code: 401))
        runner.define_singleton_method(:refresh_tokens) { true }
        @code = Teems::Commands::Mail.new(%w[rules delete Jira], runner: runner).execute
        @deletes = api.calls.count { |call| call[:method] == :delete }
      end

      assert_equal 0, @code
      assert_equal 2, @deletes
      assert_equal 1, capture[:stderr].scan('Delete rule Jira?').length
    end
  end
end
# rubocop:enable Metrics/MethodLength, Metrics/AbcSize, Metrics/ClassLength
