# frozen_string_literal: true

module Teems
  module Commands
    # Chat folder changes made by sync: detaching shared folders, moving folders, listing old
    # shared folders still on disk, and previewing all of it for --dry-run
    module SyncFolders
      # How each kind of folder change is described; :split is described by split_note, and :new
      # and :kept aren't reported
      MOVE_NOTES = {
        move: '',
        retarget: ' (the old folder is already gone)',
        repoint: ' (the new folder already exists: switching to it, the old folder is left in place)',
        release: " (the old folder also holds another chat's messages and is left in place)"
      }.freeze

      private

      def dir_info(chat) = { **chat.sync_identity, migrate: @options[:migrate_dirs] }

      # sync --chat X only detaches X, so the other chats keep their cursors until they sync
      def detach_shared_dirs
        detached = @sync_store.detach_shared_dirs(@state, only: @options[:chat_id])
        @detached_dirs = detached.keys
        warn_shared_dirs(detached)
      end

      def warn_shared_dirs(shared)
        return if shared.empty?

        warn([shared_dirs_intro(shared), *dir_lines(shared), shared_dirs_plan].join("\n"))
      end

      def shared_dirs_intro(shared)
        "#{shared.length} folder(s) in #{File.join(@sync_store.sync_dir, 'chats')} mix messages from " \
          'several chats (an older teems gave those chats the same folder name):'
      end

      def shared_dirs_plan
        'These folders are left as they are. Each affected chat now syncs to its own folder, re-fetching ' \
          'history back to the oldest message in the old folder. Older history may still exist only in the ' \
          "old folders, so keep them until you've checked the new ones."
      end

      def dir_lines(dirs) = dirs.map { |path, ids| "  #{path} (#{ids.length} chat#{'s' unless ids.one?})" }

      def report_dir_move(move)
        line = dir_move_line(move, @state)
        return unless line

        (@dir_moves ||= []) << move
        move.kind == :repoint ? warn("  Folder: #{line}") : info("  Folder: #{line}")
      end

      def dir_move_line(move, state)
        note = move_note(move.to_h, state)
        "#{move}#{note}" if note
      end

      def move_note(move_attrs, state)
        kind, chat_id = move_attrs.values_at(:kind, :chat_id)
        return MOVE_NOTES[kind] unless kind == :split

        start = resync_start(state, chat_id).strftime('%Y-%m-%d')
        " (split from a shared folder, which is left in place; re-fetching from #{start})"
      end

      # A detached chat re-syncs from the oldest message in its old folder, or --since if earlier
      def resync_start(state, chat_id) = [@sync_store.resync_from(state, chat_id), since_time].compact.min

      def show_folder_summary
        write_dir_map
        show_legacy_dirs(@detached_dirs)
      end

      def write_dir_map
        moves = @dir_moves
        return unless @options[:migrate_dirs] && moves

        info("  Folder map: #{@sync_store.write_dir_map(moves)}")
      end

      def show_legacy_dirs(exclude)
        legacy = @sync_store.legacy_shared_dirs(@state).except(*exclude)
        return if legacy.empty?

        info("Old shared folders still on disk (they may hold history the new folders don't):\n" \
             "#{dir_lines(legacy).join("\n")}")
      end

      # Plans on a copy of the state, so nothing changes on disk or in sync_state.json
      def show_dir_plan(syncable)
        plan = JSON.parse(JSON.generate(@state))
        detached = @sync_store.detach_shared_dirs(plan, only: @options[:chat_id])
        lines = syncable.filter_map do |chat_data|
          dir_move_line(@sync_store.plan_chat_dir(plan, dir_info(Models::Chat.from_api(chat_data))), plan)
        end
        show_planned_moves(lines)
        show_planned_detaches(detached)
        show_legacy_dirs([])
      end

      def show_planned_moves(lines)
        puts
        return info('Folder changes: none') if lines.empty?

        info("Folder changes (#{lines.length}):\n#{lines.map { |line| "  #{line}" }.join("\n")}")
      end

      def show_planned_detaches(detached)
        return if detached.empty?

        info("Shared folders that would be detached (#{detached.length}):\n" \
             "#{dir_lines(detached).join("\n")}\n#{shared_dirs_plan}")
      end
    end
  end
end
