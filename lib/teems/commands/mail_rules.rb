# frozen_string_literal: true

module Teems
  module Commands
    # Options for `teems mail rules add`
    module MailRuleOptions
      FLAGS = { '--mark-read' => :mark_read, '--stop' => :stop, '--delete' => :delete_mail,
                '--disabled' => :disabled }.freeze
      VALUES = { '--from' => :from, '--sent-to' => :sent_to, '--subject' => :subject, '--body' => :body,
                 '--category' => :category, '--move-to' => :move_to, '--copy-to' => :copy_to,
                 '--importance' => :importance }.freeze
      # Values that add up when repeated (each one matches, or each category is assigned)
      REPEATABLE = %i[from sent_to subject body category].freeze
      KEYS = (FLAGS.values + VALUES.values).freeze
    end

    # Turns `rules add` options into a Graph messageRule. Only actions that keep mail in the
    # mailbox exist here: a rule teems builds never forwards or redirects.
    class MailRuleBuilder
      CONDITIONS = { from: 'fromAddresses', sent_to: 'sentToAddresses', subject: 'subjectContains',
                     body: 'bodyContains' }.freeze
      ADDRESSES = %i[from sent_to].freeze
      IMPORTANCE = %w[low normal high].freeze

      def initialize(options, folders)
        @options = options
        @folders = folders
      end

      # String keys, as Graph returns rules, so a preview reads like a listed rule
      def rule(name, sequence:)
        conditions = self.conditions
        actions = self.actions
        raise Error, 'A rule needs a condition: --from, --sent-to, --subject or --body' if conditions.empty?
        raise Error, 'A rule needs an action: --move-to, --copy-to, --mark-read, --category, --importance or --delete' \
          if actions.empty?

        { 'displayName' => name, 'sequence' => sequence, 'isEnabled' => !@options[:disabled],
          'conditions' => conditions, 'actions' => actions }
      end

      def conditions
        CONDITIONS.filter_map { |option, key| (values = @options[option]) && [key, condition(option, values)] }.to_h
      end

      def actions
        raise Error, 'Use --move-to or --delete, not both' if @options[:move_to] && @options[:delete_mail]

        { 'moveToFolder' => folder_id(:move_to), 'copyToFolder' => folder_id(:copy_to),
          'markAsRead' => switch(:mark_read), 'assignCategories' => @options[:category],
          'markImportance' => importance, 'delete' => switch(:delete_mail),
          'stopProcessingRules' => switch(:stop) }.compact
      end

      private

      def condition(option, values)
        return values unless ADDRESSES.include?(option)

        values.map { |address| { 'emailAddress' => { 'address' => address } } }
      end

      # Rules need the folder's real ID, not a well-known name
      def folder_id(option)
        name = @options[option]
        name && @folders.resolve(name).id
      end

      def switch(option) = @options[option] || nil

      def importance
        level = @options[:importance] or return
        level = level.downcase
        return level if IMPORTANCE.include?(level)

        raise Error, "--importance must be #{IMPORTANCE.join(', ')}"
      end
    end

    # `teems mail rules`: list, add, enable, disable, and delete Inbox rules
    module MailRules
      RULE_ACTIONS = { 'list' => :list_rules, 'add' => :add_rule, 'enable' => :enable_rule,
                       'disable' => :disable_rule, 'delete' => :delete_rule }.freeze

      private

      def mail_rules
        verb = positional_args[1] || 'list'
        handler = RULE_ACTIONS[verb]
        return error("Usage: teems mail rules <#{RULE_ACTIONS.keys.join('|')}> (teems mail --help)") unless handler

        send(handler)
      end

      def misplaced_rule_options?
        positional_args.first(2) != %w[rules add] && MailRuleOptions::KEYS.any? { |key| @options.key?(key) }
      end

      def list_rules
        rules = fetch_rules
        formatter = rule_formatter(rules)
        return json_result(formatter.json(rules)) if @options[:json]
        return print_lines(formatter.tsv_rows(rules)) if @options[:tsv]

        print_lines(rules.empty? ? [output.gray('No Inbox rules')] : formatter.rows(rules))
      end

      def add_rule
        name = Support::ControlChars.strip(positional_args[2].to_s).strip
        return error('Usage: teems mail rules add <name> <condition>... <action>...') if name.empty?

        body = new_rule(name)
        @options[:dry_run] ? rule_preview(body) : create_rule(body)
      end

      # Last in order, under a name no other rule has (so the name can pick it out later)
      def new_rule(name)
        rules = fetch_rules
        raise Error, "A rule named #{name} already exists" if rules.any? { |rule| rule.name.casecmp?(name) }

        MailRuleBuilder.new(@options, mail_folders).rule(name, sequence: rules.map(&:sequence).max.to_i + 1)
      end

      def rule_preview(body)
        return json_result(body) if @options[:json]

        rule = Models::MailRule.from_api(body)
        print_lines(["#{rule.name}: #{rule_formatter([rule]).describe(rule)}",
                     output.gray('Would add this rule (dry run, nothing changed)')])
      end

      def create_rule(body)
        rule = Models::MailRule.from_api(rules_api.create(body))
        formatter = rule_formatter([rule])
        return json_result(formatter.json([rule]).first) if @options[:json]

        done("Added rule #{rule.name}: #{formatter.describe(rule)}")
      end

      def enable_rule = switch_rule(true)
      def disable_rule = switch_rule(false)

      def switch_rule(enabled)
        rule = find_rule
        name = rule.name
        state = enabled ? 'enabled' : 'disabled'
        return noted("Rule #{name} is already #{state}") if rule.enabled == enabled
        raise Error, "Rule #{name} forwards or redirects mail; teems will not enable it" if enabled && rule.forwards?

        rules_api.update(rule.id, { isEnabled: enabled })
        done("Rule #{name} #{state}")
      end

      def delete_rule
        rule = find_rule
        name = rule.name
        return noted("Would delete rule #{name} (dry run, nothing changed)") if @options[:dry_run]
        return error('Cancelled; nothing changed') unless rule_delete_confirmed?(name)

        rules_api.destroy(rule.id)
        done("Deleted rule #{name}")
      end

      # Kept for the retry after a token refresh, so the question is not asked twice
      def rule_delete_confirmed?(name)
        @rule_delete_confirmed ||= @options[:yes] ||
                                   confirm?("Delete rule #{name}",
                                            refusal: "Deleting rule #{name} needs --yes without a terminal")
      end

      # By ID, then name (ignoring case), then the number `rules` lists
      def find_rule
        ref = positional_args[2].to_s.strip
        raise Error, "Usage: teems mail rules #{positional_args[1]} <name|number|id>" if ref.empty?

        matches = rule_matches(fetch_rules, ref)
        return matches.first if matches.one?
        raise Error, "No Inbox rule matches #{ref} (see teems mail rules)" if matches.empty?

        raise Error, "#{matches.length} rules are named #{ref}; use the ID (teems mail rules --tsv)"
      end

      def rule_matches(rules, ref)
        [->(rule) { rule.id == ref }, ->(rule) { rule.name.casecmp?(ref) }, ->(rule) { rule.sequence.to_s == ref }]
          .lazy.map { |test| rules.select(&test) }.find(&:any?) || []
      end

      def fetch_rules = rules_api.list.map { |data| Models::MailRule.from_api(data) }.sort_by(&:sequence)

      # Folder paths only when a rule moves or copies mail (the folder tree costs requests)
      def rule_formatter(rules)
        names = rules.flat_map(&:folder_ids).empty? ? {} : mail_folders.paths_by_id
        Formatters::MailRuleFormatter.new(output: output, folder_names: names)
      end

      def done(message) = 0.tap { success(message) }
      def noted(message) = 0.tap { info(message) }
      def rules_api = runner.mail_rules_api
    end
  end
end
