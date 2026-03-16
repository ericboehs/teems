# frozen_string_literal: true

module Teems
  module Commands
    # Schedule bitmap rendering for who command
    module WhoSchedule
      SLOT_CHARS = { '0' => "\u2591", '1' => "\u2592", '2' => "\u2588", '3' => "\u2593", '4' => "\u2592" }.freeze
      SLOTS_PER_HOUR = 4
      DEFAULT_WORK_HOURS = [9, 17].freeze
      STATUS_LABELS = { 'Available' => 'Available', 'Busy' => 'Busy', 'DoNotDisturb' => 'Do Not Disturb',
                        'BeRightBack' => 'Be Right Back', 'Away' => 'Away', 'Offline' => 'Offline' }.freeze

      # Bundles schedule display parameters
      ScheduleContext = Data.define(:work_start, :tz_abbrev)

      private

      def fetch_schedule(email, timezone, work_start, work_end)
        date_str = Time.now.strftime('%Y-%m-%d')
        start_time = "#{date_str}T#{format('%02d', work_start)}:00:00"
        end_time = "#{date_str}T#{format('%02d', work_end)}:00:00"
        with_token_refresh do
          runner.users_api.schedule(email, start_time: start_time, end_time: end_time, timezone: timezone)
        end
      rescue ApiError => e
        debug("Could not fetch schedule for #{email}: #{e.message}")
        nil
      end

      def render_schedule(schedule, ctx)
        view = schedule['availabilityView']
        return unless view && !view.empty?

        puts "  Today       #{render_bitmap(view)}"
        puts "              #{render_hour_labels(view, ctx.work_start)}"
        render_now_marker(view, ctx)
      end

      def render_bitmap(view)
        view.chars.map { |ch| SLOT_CHARS[ch] || ch }.join
      end

      def render_hour_labels(view, work_start)
        total_hours = view.length / SLOTS_PER_HOUR
        (0...total_hours).map { |idx| format_hour_label(work_start + idx) }.join
      end

      def format_hour_label(hour)
        display = hour > 12 ? hour - 12 : hour
        display.to_s.ljust(SLOTS_PER_HOUR)
      end

      def render_now_marker(view, ctx)
        slot_index = slot_for_now(ctx.work_start)
        return unless slot_index >= 0 && slot_index < view.length

        pointer = "#{' ' * slot_index}^ now"
        local_time = Time.now.strftime('%-I:%M %p')
        puts "              #{pointer} #{local_time} #{ctx.tz_abbrev}"
      end

      def render_calendar_line(schedule, ctx)
        view = schedule['availabilityView']
        return unless view && !view.empty?

        status_text = compute_cal_status(view, ctx)
        puts "  Calendar    #{status_text}" if status_text
      end

      def compute_cal_status(view, ctx)
        slot = slot_for_now(ctx.work_start)
        return nil unless slot >= 0 && slot < view.length

        label = view[slot] == '0' ? 'Free' : 'Busy'
        suffix = next_change_label(view, slot, ctx)
        "#{label}#{suffix}"
      end

      def next_change_label(view, slot, ctx)
        next_slot = find_next_change(view, slot)
        return '' unless next_slot

        change_time = slot_to_time(ctx.work_start, next_slot)
        " until #{change_time.strftime('%-I:%M %p')} #{ctx.tz_abbrev}"
      end

      def slot_to_time(work_start, slot_index)
        minutes = (work_start * 60) + (slot_index * 15)
        today = Date.today
        Time.new(today.year, today.month, today.day, minutes / 60, minutes % 60)
      end

      def slot_for_now(work_start)
        now = Time.now
        (((now.hour - work_start) * 60) + now.min) / 15
      end

      def find_next_change(view, start_slot)
        free = view[start_slot] == '0'
        ((start_slot + 1)...view.length).each do |idx|
          return idx if free != (view[idx] == '0')
        end
        nil
      end

      def parse_work_hours(schedule)
        start_str = schedule.dig('workingHours', 'startTime')
        end_str = schedule.dig('workingHours', 'endTime')
        work_start = start_str ? start_str.split(':').first.to_i : 9
        work_end = end_str ? end_str.split(':').first.to_i : 17
        [work_start, work_end]
      end

      def fetch_schedule_for(email, timezone)
        return nil unless email

        schedule = fetch_schedule(email, timezone, *DEFAULT_WORK_HOURS)
        return nil unless schedule

        actual_hours = parse_work_hours(schedule)
        return schedule if actual_hours == DEFAULT_WORK_HOURS

        fetch_schedule(email, timezone, *actual_hours) || schedule
      end
    end

    # Presence display helpers for who command
    module WhoPresence
      private

      def render_presence_info(presence_data)
        return unless presence_data

        if presence_data.dig('presence', 'calendarData', 'isOutOfOffice')
          render_oof_status(presence_data)
        else
          render_normal_status(presence_data)
        end
      end

      def render_oof_status(presence_data)
        render_normal_status(presence_data)
        expiry = format_presence_expiry(presence_data)
        text = expiry ? "Out of office (#{expiry})" : 'Out of office'
        puts "  OOF         #{text}"
      end

      def render_normal_status(presence_data)
        availability = presence_data.dig('presence', 'availability')
        label = WhoSchedule::STATUS_LABELS[availability] || availability
        expiry = format_presence_expiry(presence_data)
        text = expiry ? "#{label} (#{expiry})" : label
        puts "  Status      #{text}" if label
      end

      def format_presence_expiry(presence_data)
        expiry_str = presence_data.dig('presence', 'forcedAvailability', 'expiry')
        return nil unless expiry_str

        expiry = Time.parse(expiry_str).localtime
        "until #{expiry.strftime('%b %-d')}"
      rescue ArgumentError
        debug("Could not parse presence expiry: #{expiry_str.inspect}")
        nil
      end
    end

    # Profile display helpers for who command
    module WhoDisplay
      private

      def render_profile(profile)
        puts output.bold(profile.best_name)
        render_profile_fields(profile)
        render_phones(profile)
        render_availability(profile)
      end

      def render_profile_fields(profile)
        render_field('Email', profile.email)
        render_field('Title', profile.job_title)
        render_field('Department', profile.department)
        render_field('Office', profile.office_location)
      end

      def render_field(label, value)
        puts "  #{label.ljust(11)} #{value}" if present?(value)
      end

      def render_phones(profile)
        render_field('Phone', profile.business_phones&.first)
        render_field('Mobile', profile.mobile_phone)
      end

      def render_availability(profile)
        presence_data = fetch_presence_data(profile.id)
        render_presence_info(presence_data)
        render_schedule_info(profile.email)
      end

      def render_schedule_info(email)
        schedule = fetch_schedule_for(email, detect_timezone)
        return unless schedule

        ctx = build_schedule_context(schedule)
        render_calendar_line(schedule, ctx)
        render_schedule(schedule, ctx)
      end

      def build_schedule_context(schedule)
        work_start, = parse_work_hours(schedule)
        WhoSchedule::ScheduleContext.new(work_start: work_start, tz_abbrev: short_tz_label)
      end

      def render_search_result(name, title, email, index)
        title_suffix = present?(title) ? " (#{title})" : ''
        puts "  #{index + 1}. #{name}#{title_suffix}"
        puts "     #{email}" if present?(email)
      end

      def render_search_list(results)
        results.each_with_index do |profile, index|
          render_search_result(*profile.search_display, index)
        end
      end

      def search_results_json(results)
        results.map(&:to_h)
      end

      def present?(value)
        value && !value.empty?
      end
    end

    # Look up a user's profile
    class Who < Base
      include Support::Timezone
      include WhoSchedule
      include WhoPresence
      include WhoDisplay

      def initialize(args, runner:)
        @options = {}
        super
      end

      def execute
        result = validate_options
        return result if result

        auth_result = require_auth
        return auth_result if auth_result

        lookup_user
      end

      protected

      def help_text
        <<~HELP
          #{output.bold('teems who')} - Look up a user's profile

          #{output.bold('USAGE:')}
            teems who [options]              Show your profile
            teems who <query> [options]      Search for a user

          #{output.bold('OPTIONS:')}
            -v, --verbose    Show debug output
            -q, --quiet      Suppress output
            --json           Output as JSON
            -h, --help       Show this help

          #{output.bold('EXAMPLES:')}
            teems who                # Show your own profile
            teems who john           # Search for "john"
            teems who john@co.com    # Look up by email
            teems who --json         # Your profile as JSON
        HELP
      end

      private

      def lookup_user
        query = positional_args.join(' ')
        if query.empty?
          show_current_user
        else
          search_users(query)
        end
      rescue ApiError => e
        error("Failed to look up user: #{e.message}")
        1
      end

      def show_current_user
        profile = with_token_refresh { runner.users_api.me }
        display_profile(profile)
        0
      end

      def search_users(query)
        results = with_token_refresh { runner.users_api.search(query) }
        handle_search_results(results, query)
        0
      end

      def handle_search_results(results, query)
        if results.empty?
          puts "No users found matching '#{query}'"
        elsif results.length == 1
          display_profile(results.first)
        else
          display_search_results(results)
        end
      end

      def display_profile(profile)
        @options[:json] ? output_json(json_profile(*profile.json_attrs)) : render_profile(profile)
      end

      def display_search_results(results)
        @options[:json] ? output_json(search_results_json(results)) : render_search_list(results)
      end

      def fetch_presence_data(user_id)
        return nil unless user_id

        mri = "8:orgid:#{user_id}"
        result = with_token_refresh { runner.users_api.teams_presence(mri) }
        result&.first
      rescue ApiError => e
        debug("Could not fetch presence for #{user_id}: #{e.message}")
        nil
      end

      def json_profile(attrs, user_id)
        presence_data = fetch_presence_data(user_id)
        schedule = fetch_schedule_for(attrs[:email], detect_timezone)
        build_json_profile(attrs, presence_data, schedule)
      end

      def build_json_profile(attrs, presence_data, schedule)
        result = attrs.merge(presence: presence_data&.dig('presence', 'availability'))
        result[:out_of_office] = presence_data&.dig('presence', 'calendarData', 'isOutOfOffice')
        result[:availability_view] = schedule['availabilityView'] if schedule
        result[:working_hours] = schedule['workingHours'] if schedule
        result
      end
    end
  end
end
