# frozen_string_literal: true

module Teems
  module Services
    # Decides which directory each chat syncs into.
    #
    # Existing directory names are kept, so upgrading doesn't rename everything. A chat gets a new
    # "<name> (<full ID>)" directory (see SyncDirNaming) only when it is new, was detached from a
    # shared directory, or its display name or type changed. The name is checked against every
    # other chat's directories when it is assigned, which is what prevents collisions.
    #
    # plan_chat_dir only updates state, so a dry run can preview every move; ensure_chat_dir also
    # carries the move out on disk.
    module SyncDirPlanning
      # A chat's directory change, with paths relative to chats/. Kinds:
      #   :kept     same directory as before
      #   :new      first directory for the chat
      #   :split    new directory for a chat detached from the shared directory in from
      #   :release  new directory; from holds another chat's files too, so it stays put
      #   :move     from will be (or was) renamed to to
      #   :repoint  to already exists, so the chat switches to it and from is left in place
      #   :retarget from no longer exists (e.g. an interrupted run already moved it)
      DirMove = Data.define(:chat_id, :from, :to, :kind) do
        def to_s = "#{from} → #{to}"
      end

      # A chat's state entry plus the display name and type this sync found for it. A nil name or
      # type means unknown (sync --chat has no chat metadata), so the stored one is kept.
      ChatDirRequest = Data.define(:chat_id, :entry, :wanted, :migrate) do
        def self.build(chats, chat_info)
          chat_id = chat_info[:chat_id]
          entry = chats[chat_id] ||= {}
          wanted = { 'display_name' => chat_info[:display_name] || entry['display_name'],
                     'chat_type' => chat_info[:chat_type] || entry['chat_type'] }
          new(chat_id, entry, wanted, chat_info[:migrate])
        end

        def current_dir
          name = entry['dir_name']
          dir_for(name, entry['chat_type']) if name
        end

        # migrate: true treats every chat as changed, giving it a full-ID name
        def unchanged? = !migrate && entry.slice('display_name', 'chat_type') == wanted

        def display_name = wanted['display_name']

        def wanted_dir(name) = dir_for(name, wanted['chat_type'])

        def assign(name)
          entry.merge!('dir_name' => name, 'chat_type' => wanted['chat_type'])
          wanted_dir(name)
        end

        # The move for a chat that had no directory: from is the shared one it was detached from
        def first_move(to)
          legacy = entry['legacy_shared_dir']
          DirMove.new(chat_id, legacy, to, legacy ? :split : :new)
        end

        private

        def dir_for(name, chat_type) = File.join(SyncDirNaming.type_dir(chat_type), name)
      end

      # Picks the chat's directory and records it in state without touching the filesystem
      def plan_chat_dir(state, chat_info)
        chat_id = chat_info[:chat_id]
        chats = state['chats'] ||= {}
        request = ChatDirRequest.build(chats, chat_info)
        others = chats.except(chat_id)
        from = request.current_dir
        to = keep_dir?(request, others, from) ? from : assign_dir(request, others, chat_id)
        from ? DirMove.new(chat_id, from, to, existing_dir_kind(others, from, to)) : request.first_move(to)
      end

      # Like plan_chat_dir, then renames the old directory when that is safe. If the rename fails, the
      # chat's entry is restored so state never points at a directory its files weren't moved to.
      def ensure_chat_dir(state, chat_info:)
        entry = (state['chats'] ||= {})[chat_info[:chat_id]] ||= {}
        saved = entry.dup
        move = plan_chat_dir(state, chat_info)
        rename_chat_dir(move) if move.kind == :move
        move
      rescue SystemCallError
        entry.replace(saved)
        raise
      end

      # Records directory changes (paths relative to root) as dir-maps/<time>.json; returns its path
      def write_dir_map(moves, time: Time.now)
        dir = File.join(sync_dir, 'dir-maps')
        FileUtils.mkdir_p(dir)
        path = File.join(dir, "#{time.strftime('%Y%m%d-%H%M%S')}.json")
        map = { 'root' => File.join(sync_dir, SyncStore::CHATS_DIR), 'moves' => moves.map(&:to_h) }
        atomic_write(path, JSON.pretty_generate(map))
        path
      end

      private

      def keep_dir?(request, others, from) = from && request.unchanged? && !owned?(others, from)

      def assign_dir(request, others, chat_id)
        name = build_dir_name(chat_id, request.display_name)
        name = fallback_dir_name(chat_id) if dir_claimed?(others, request.wanted_dir(name))
        request.assign(name)
      end

      def existing_dir_kind(others, from, to)
        return :kept if from == to
        return :release if owned?(others, from)

        from_path = chats_path(from)
        return :retarget unless File.directory?(from_path)

        target_taken?(from_path, chats_path(to)) ? :repoint : :move
      end

      # On a case-insensitive volume a case-only rename finds the chat's own directory at the new path
      def target_taken?(from_path, to_path) = File.exist?(to_path) && !File.identical?(from_path, to_path)

      def rename_chat_dir(move)
        new_path = chats_path(move.to)
        FileUtils.mkdir_p(File.dirname(new_path))
        File.rename(chats_path(move.from), new_path)
      end
    end
  end
end
