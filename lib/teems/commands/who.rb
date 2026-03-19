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

      # Bundles email + timezone for schedule lookups
      ScheduleTarget = Data.define(:email, :timezone)
      # Bundles schedule display parameters including availability view
      ScheduleContext = Data.define(:view, :work_start, :tz_abbrev)

      private

      def fetch_schedule(target, work_start, work_end)
        request_schedule(target, schedule_time_range(work_start, work_end))
      rescue ApiError => e
        debug("Could not fetch schedule for #{target.email}: #{e.message}")
        nil
      end

      def request_schedule(target, time_range)
        tr = { start_time: time_range.first, end_time: time_range.last, timezone: target.timezone }
        with_token_refresh { runner.users_api.schedule(target.email, time_range: tr) }
      end

      def schedule_time_range(work_start, work_end)
        [work_start, work_end].map { |hour| "#{Time.now.strftime('%Y-%m-%d')}T#{format('%02d', hour)}:00:00" }
      end

      def render_schedule(schedule, ctx)
        view = schedule['availabilityView']
        return unless view && !view.empty?

        puts "  Today       #{render_bitmap(view)}"
        puts "              #{render_hour_labels(view, ctx.work_start)}"
        render_now_marker(ctx.with(view: view))
      end

      def render_bitmap(view)
        view.chars.map { |ch| SLOT_CHARS[ch] || ch }.join
      end

      def render_hour_labels(view, work_start)
        total_hours = view.length / SLOTS_PER_HOUR
        (0...total_hours).map { |idx| format_hour_label(work_start + idx) }.join
      end

      def format_hour_label(hour) = (((hour - 1) % 12) + 1).to_s.ljust(SLOTS_PER_HOUR)

      def render_now_marker(ctx)
        slot_index = slot_for_now(ctx.work_start)
        return unless slot_index >= 0 && slot_index < ctx.view.length

        debug("Now marker at slot #{slot_index}")
        local_time = Time.now.strftime('%-I:%M %p')
        puts "              #{' ' * slot_index}^ now #{local_time} #{ctx.tz_abbrev}"
      end

      def render_calendar_line(schedule, ctx)
        view = schedule['availabilityView']
        return unless view && !view.empty?

        status_text = compute_cal_status(ctx.with(view: view))
        puts "  Calendar    #{status_text}" if status_text
      end

      def compute_cal_status(ctx)
        view = ctx.view
        slot = slot_for_now(ctx.work_start)
        return nil unless slot >= 0 && slot < view.length

        format_cal_label(view, slot, ctx)
      end

      def format_cal_label(view, slot, ctx)
        label = view[slot] == '0' ? 'Free' : 'Busy'
        "#{label}#{next_change_label(view, slot, ctx)}"
      end

      def next_change_label(view, slot, ctx)
        next_slot = find_next_change(view, slot)
        return '' unless next_slot

        change_time = slot_to_time(ctx.work_start, next_slot)
        " until #{change_time.strftime('%-I:%M %p')} #{ctx.tz_abbrev}"
      end

      def slot_to_time(work_start, slot_index)
        offset = (work_start * 60) + (slot_index * 15)
        Date.today.to_time + (offset * 60)
      end

      def slot_for_now(work_start)
        now = Time.now
        (((now.hour - work_start) * 60) + now.min) / 15
      end

      def find_next_change(view, start_slot)
        offset = start_slot + 1
        match = search_view(view, offset, change_pattern(view[start_slot]))
        match && (offset + match)
      end

      def search_view(view, offset, pattern) = view[offset..]&.index(pattern)
      def change_pattern(slot_char) = free_slot?(slot_char) ? /[^0]/ : /0/
      def free_slot?(char) = char == '0'
      def parse_work_hours(schedule) = [parse_hour(schedule, 'startTime', 9), parse_hour(schedule, 'endTime', 17)]

      def parse_hour(schedule, key, default)
        value = schedule.dig('workingHours', key)
        value ? value.split(':').first.to_i : default
      end

      def fetch_schedule_for(target)
        return nil unless target.email

        schedule = fetch_schedule(target, *DEFAULT_WORK_HOURS)
        schedule && refetch_if_custom_hours(schedule, target)
      end

      def refetch_if_custom_hours(schedule, target)
        actual_hours = parse_work_hours(schedule)
        return schedule if actual_hours == DEFAULT_WORK_HOURS

        fetch_schedule(target, *actual_hours) || schedule
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
        label = presence_label(presence_data)
        text = label_with_expiry(label, format_presence_expiry(presence_data))
        puts "  Status      #{text}" if label
      end

      def presence_label(presence_data)
        availability = presence_data.dig('presence', 'availability')
        debug("Presence availability: #{availability}")
        WhoSchedule::STATUS_LABELS[availability] || availability
      end

      def label_with_expiry(label, expiry)
        expiry ? "#{label} (#{expiry})" : label
      end

      def format_presence_expiry(presence_data)
        expiry_str = presence_data.dig('presence', 'forcedAvailability', 'expiry')
        return nil unless expiry_str

        parse_expiry_time(expiry_str)
      end

      def parse_expiry_time(expiry_str)
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
        schedule = fetch_schedule_for(WhoSchedule::ScheduleTarget.new(email: email, timezone: detect_timezone))
        return unless schedule

        ctx = build_schedule_context(schedule)
        render_calendar_line(schedule, ctx)
        render_schedule(schedule, ctx)
      end

      def build_schedule_context(schedule)
        work_start, = parse_work_hours(schedule)
        WhoSchedule::ScheduleContext.new(view: schedule['availabilityView'],
                                         work_start: work_start, tz_abbrev: short_tz_label)
      end

      def render_search_result(profile, index)
        name, title, email = profile.search_display
        title_suffix = present?(title) ? " (#{title})" : ''
        puts "  #{index + 1}. #{name}#{title_suffix}"
        puts "     #{email}" if present?(email)
      end

      def render_search_list(results)
        results.each_with_index do |profile, index|
          render_search_result(profile, index)
        end
      end

      def search_results_json(results)
        debug("Converting #{results.length} results to JSON")
        debug('Serializing search results')
        results.map(&:to_h)
      end

      def present?(value)
        debug('Checking field presence')
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
        dispatch_lookup(positional_args.join(' '))
      rescue ApiError => e
        error("Failed to look up user: #{e.message}")
        1
      end

      def dispatch_lookup(query)
        query.empty? ? show_current_user : search_users(query)
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

        fetch_teams_presence("8:orgid:#{user_id}")
      rescue ApiError => e
        debug("Could not fetch presence for #{user_id}: #{e.message}")
        nil
      end

      def fetch_teams_presence(mri)
        result = with_token_refresh { runner.users_api.teams_presence(mri) }
        result&.first
      end

      def schedule_target(email) = WhoSchedule::ScheduleTarget.new(email: email, timezone: detect_timezone)

      def json_profile(attrs, user_id)
        presence_data = fetch_presence_data(user_id)
        schedule = fetch_schedule_for(schedule_target(attrs[:email]))
        build_json_profile(attrs, presence_data, schedule)
      end

      def build_json_profile(attrs, presence_data, schedule)
        debug('Building JSON profile')
        result = attrs.merge(presence: presence_data&.dig('presence', 'availability'),
                             out_of_office: presence_data&.dig('presence', 'calendarData', 'isOutOfOffice'))
        return result unless schedule

        debug('Including schedule data in JSON profile')
        result.merge(availability_view: schedule['availabilityView'], working_hours: schedule['workingHours'])
      end
    end
  end
end
