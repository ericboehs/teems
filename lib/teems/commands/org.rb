# frozen_string_literal: true

module Teems
  module Commands
    # Walks manager chain and direct reports tree
    module OrgTreeWalker
      private

      def walk_manager_chain(target_id)
        managers = []
        current_id = target_id
        fetch = method(target_is_me? ? :fetch_my_manager : :fetch_user_manager)

        while (mgr = fetch.call(current_id))
          managers.unshift(mgr)
          current_id = mgr.id
          fetch = method(:fetch_user_manager)
        end
        managers
      end

      def fetch_my_manager(_user_id)
        with_token_refresh { runner.users_api.manager_me }
      rescue ApiError => e
        raise unless e.not_found?

        nil
      end

      def fetch_user_manager(user_id)
        with_token_refresh { runner.users_api.manager(user_id) }
      rescue ApiError => e
        raise unless e.not_found?

        nil
      end

      def walk_reports_tree(user, remaining_depth, fetch)
        return { user: user, reports: [] } if remaining_depth <= 0

        reports = fetch.call(user.id)
        children = reports.map { |report| walk_reports_tree(report, remaining_depth - 1, method(:fetch_user_reports)) }
        { user: user, reports: children }
      end

      def fetch_my_reports(_user_id)
        with_token_refresh { runner.users_api.direct_reports_me }
      rescue ApiError => e
        debug("Could not fetch direct reports: #{e.message}")
        raise unless e.not_found? || e.forbidden?

        []
      end

      def fetch_user_reports(user_id)
        with_token_refresh { runner.users_api.direct_reports(user_id) }
      rescue ApiError => e
        debug("Could not fetch direct reports for #{user_id}: #{e.message}")
        raise unless e.not_found? || e.forbidden?

        []
      end

      def target_is_me?
        positional_args.empty?
      end
    end

    # Renders org chart as text tree or JSON
    module OrgRenderer
      private

      def render_org(managers, target, reports)
        if @options[:json]
          output_json(build_json(managers, target, reports))
        else
          render_tree(managers, target, reports)
        end
      end

      def render_tree(managers, target, reports)
        managers.each_with_index { |mgr, index| puts "#{'  ' * index}#{format_person(mgr)}" }
        puts "#{'  ' * managers.length}--> #{format_person(target)}"
        render_reports(reports[:reports], managers.length + 1)
      end

      def render_reports(reports, level)
        reports.each do |node|
          puts "#{'  ' * level}#{format_person(node[:user])}"
          render_reports(node[:reports], level + 1)
        end
      end

      def format_person(profile)
        title = profile.job_title
        title && !title.empty? ? "#{profile.best_name} (#{title})" : profile.best_name.to_s
      end

      def build_json(managers, target, reports)
        { managers: managers.map(&:to_h), target: target.to_h,
          direct_reports: json_reports(reports[:reports]) }
      end

      def json_reports(reports)
        reports.map { |report| json_report(*report.values_at(:user, :reports)) }
      end

      def json_report(user, sub_reports)
        user.to_h.merge(direct_reports: json_reports(sub_reports))
      end
    end

    # Show org chart for a user
    class Org < Base
      include OrgTreeWalker
      include OrgRenderer

      ORG_OPTIONS = {
        '--depth' => ->(opts, args) { opts[:depth] = parse_depth(args.shift) }
      }.freeze

      def self.parse_depth(value)
        return 1 unless value

        result = value.to_i
        result >= 0 ? result : 1
      end

      def initialize(args, runner:)
        @options = {}
        super
      end

      def execute
        result = validate_options
        return result if result

        auth_result = require_auth
        return auth_result if auth_result

        show_org_chart
      end

      protected

      def handle_option(arg, pending)
        handler = ORG_OPTIONS[arg]
        return super unless handler

        handler.call(@options, pending)
      end

      def help_text
        <<~HELP
          #{output.bold('teems org')} - Show org chart for a user

          #{output.bold('USAGE:')}
            teems org [options]              Org chart for current user
            teems org <query> [options]      Org chart for a searched user

          #{output.bold('OPTIONS:')}
            --depth N        Limit direct report depth (default: 1)
            -v, --verbose    Show debug output
            -q, --quiet      Suppress output
            --json           Output as JSON
            -h, --help       Show this help

          #{output.bold('EXAMPLES:')}
            teems org                # Your org chart
            teems org john           # Org chart for "john"
            teems org --depth 1      # Only immediate reports
            teems org --json         # JSON output
        HELP
      end

      private

      def show_org_chart
        target = resolve_target
        return 1 unless target

        render_org(*fetch_org_data(target))
        0
      rescue ApiError => e
        error("Failed to fetch org chart: #{e.message}")
        1
      end

      def fetch_org_data(target)
        managers = walk_manager_chain(target.id)
        report_fetch = method(target_is_me? ? :fetch_my_reports : :fetch_user_reports)
        reports = walk_reports_tree(target, depth, report_fetch)
        [managers, target, reports]
      end

      def depth
        @options[:depth] || 1
      end

      def resolve_target
        query = positional_args.join(' ')
        query.empty? ? with_token_refresh { runner.users_api.me } : resolve_by_search(query)
      end

      def resolve_by_search(query)
        results = with_token_refresh { runner.users_api.search(query) }
        return results.first unless results.empty?

        error("No users found matching '#{query}'")
        nil
      end
    end
  end
end
