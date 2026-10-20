# frozen_string_literal: true

module Teems
  module Services
    # The index of one synced mail folder: Graph message ID -> file name and summary, plus
    # the matcher for files an older outlook-cli sync left in the same directory
    class MailSyncIndex
      def initialize(messages, legacy:)
        @messages = messages
        @snapshot = JSON.generate(messages)
        @legacy = legacy
      end

      def to_h = @messages

      def entry(message_id) = @messages[message_id]

      def include?(message_id) = @messages.key?(message_id)

      # Legacy file already recorded for this message, or an unclaimed one that matches it
      def legacy_file(message)
        entry = @messages[message.id]
        return entry['legacy'] ? entry['file'] : nil if entry

        @legacy.match(message)
      end

      def self.entry_for(message, file)
        { 'file' => file, 'short_id' => message.short_id, 'subject' => message.subject,
          'from' => message.from[:address], 'received' => message.received_at&.utc&.iso8601,
          'read' => message.read? }
      end

      def record(message, file)
        @messages[message.id] = MailSyncIndex.entry_for(message, file)
      end

      # Records a legacy file (left as it is) as this message's file
      def adopt(message, file)
        record(message, file)['legacy'] = true
      end

      # Marks a known message removed; true unless it was unknown or already marked
      def mark_removed?(message_id)
        return false unless removable?(message_id)

        @messages[message_id]['removed_at'] = Time.now.utc.iso8601
        true
      end

      def changed? = JSON.generate(@messages) != @snapshot

      def mark_saved
        @snapshot = JSON.generate(@messages)
      end

      private

      # Unknown IDs fall back to an entry that already counts as removed
      def removable?(message_id) = !@messages.fetch(message_id, { 'removed_at' => nil }).key?('removed_at')
    end

    # Index, delta state, and counts for the folder a MailSyncEngine is syncing
    class MailSyncFolder
      STAT_KEYS = %i[created updated unchanged adopted removed].freeze

      attr_reader :stats

      def initialize(folder, store)
        @folder = folder
        @store = store
        @index = load_index
        @stats = STAT_KEYS.to_h { |key| [key, 0] }
        # Without an index the files the delta link already covered are gone: start over
        reset_state unless store.index_exists?(path)
      end

      def id = @folder.id
      def path = @folder.path

      def resume_link
        state = @store.load_state[id] || {}
        state['next_link'] || state['delta_link']
      end

      def reset_state
        states = @store.load_state
        states.delete(id) && @store.save_state(states)
      end

      def legacy_file(message) = @index.legacy_file(message)

      def file_for(message) = @index.entry(message.id)&.fetch('file') || Formatters::MailMarkdown.filename(message)

      def count(result) = @stats[result] += 1

      def record(message, file) = @index.record(message, file)

      # Legacy files are never rewritten, so seeing one again leaves it unchanged
      def adopt(message, file)
        count(@index.include?(message.id) ? :unchanged : :adopted)
        @index.adopt(message, file)
      end

      def mark_removed(message_id)
        count(:removed) if @index.mark_removed?(message_id)
      end

      # Saves the index (when anything changed) and the link to continue from
      def checkpoint(page)
        save_index if @index.changed? || !@store.index_exists?(path)
        states = @store.load_state
        states[id] = next_state(states[id] || {}, page)
        @store.save_state(states)
      end

      private

      def load_index
        messages = @store.load_index(path)
        known = messages.values.map { |entry| entry['file'] }
        legacy = MailLegacyFiles.new(@store.folder_dir(path), known_files: known)
        MailSyncIndex.new(messages, legacy: legacy)
      end

      def save_index
        @store.save_index(path, @index.to_h)
        @index.mark_saved
      end

      def next_state(state, page)
        next_link = page['@odata.nextLink']
        update = next_link ? { 'next_link' => next_link } : finished_state(page)
        state.merge('name' => path, **update)
      end

      def finished_state(page)
        { 'next_link' => nil, 'delta_link' => page['@odata.deltaLink'], 'last_synced_at' => Time.now.utc.iso8601 }
      end
    end
  end
end
