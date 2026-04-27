# frozen_string_literal: true

module Teems
  module Commands
    # Walks manager chain and direct reports tree
    module OrgTreeWalker
      private

      def walk_manager_chain(target_id)
        fetch = method(target_is_me? ? :fetch_my_manager : :fetch_user_manager)
        collect_managers(target_id, fetch, Set[target_id])
      end

      def collect_managers(current_id, fetch, visited)
        managers = []
        while (mgr = fetch.call(current_id))
          mgr_id = mgr.id
          break unless visited.add?(mgr_id)

          managers.unshift(mgr)
          current_id = mgr_id
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
        handle_reports_error(e, 'direct reports')
      end

      def fetch_user_reports(user_id)
        with_token_refresh { runner.users_api.direct_reports(user_id) }
      rescue ApiError => e
        handle_reports_error(e, "direct reports for #{user_id}")
      end

      def handle_reports_error(err, context)
        debug("Could not fetch #{context}: #{err.message}")
        raise unless recoverable_reports_error?(err)

        []
      end

      def recoverable_reports_error?(err) = err.not_found? || err.forbidden?

      def target_is_me?
        positional_args.empty?
      end
    end

    # Renders org chart as text tree or JSON
    module OrgRenderer
      # Groups org chart data: managers chain, target user, and reports tree
      OrgData = Struct.new(:managers, :target, :reports) do
        def to_json_hash
          { managers: managers.map(&:to_h), target: target.to_h,
            direct_reports: self.class.json_reports(reports[:reports]) }
        end

        def self.json_reports(reports)
          reports.map { |report| json_report(*report.values_at(:user, :reports)) }
        end

        def self.json_report(user, sub_reports)
          user.to_h.merge(direct_reports: json_reports(sub_reports))
        end
      end

      private

      def render_org(org_data)
        if @options[:json]
          output_json(org_data.to_json_hash)
        else
          render_tree(org_data)
        end
      end

      def render_tree(org_data)
        managers = org_data.managers
        depth = managers.length
        managers.each_with_index { |mgr, index| puts "#{'  ' * index}#{format_person(mgr)}" }
        puts "#{'  ' * depth}--> #{format_person(org_data.target)}"
        render_reports(org_data.reports[:reports], depth + 1)
      end

      def render_reports(reports, level)
        reports.each do |node|
          puts "#{'  ' * level}#{format_person(node[:user])}"
          render_reports(node[:reports], level + 1)
        end
      end

      def format_person(profile)
        title = profile.job_title
        name = profile.best_name
        title && !title.empty? ? "#{name} (#{title})" : name.to_s
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
        target ? display_org(target) : 1
      rescue ApiError => e
        org_fetch_error(e)
      end

      def org_fetch_error(err)
        error("Failed to fetch org chart: #{err.message}")
        1
      end

      def display_org(target)
        render_org(fetch_org_data(target))
        0
      end

      def fetch_org_data(target)
        managers = walk_manager_chain(target.id)
        report_fetch = method(target_is_me? ? :fetch_my_reports : :fetch_user_reports)
        reports = walk_reports_tree(target, depth, report_fetch)
        OrgRenderer::OrgData.new(managers: managers, target: target, reports: reports)
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
