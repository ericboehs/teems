# frozen_string_literal: true

module Teems
  module Services
    # On-disk layout for `teems mail sync`:
    #
    #   <root>/<Folder>/<YYYY-MM-DD>-<subject>-<short id>.md   one file per message
    #   <root>/<Folder>/index.json                             message ID -> file and summary
    #   <root>/<Folder>/attachments/<short id>/                with --attachments
    #
    # Delta links and the run lock live in the XDG state dir, outside the root, so a run that
    # changes no mail changes nothing under the root (watchers keyed on mtimes stay quiet).
    class MailSyncStore
      INDEX_FILE = 'index.json'
      STATE_FILE = 'mail-sync.json'

      attr_reader :root

      def self.default_root = File.join(Support::XdgPaths.new.data_dir, SyncStore::SYNC_DIR, 'mail')

      def self.default_state_dir
        File.join(ENV.fetch('XDG_STATE_HOME') { File.join(Dir.home, '.local', 'state') }, 'teems')
      end

      def initialize(root: MailSyncStore.default_root, state_dir: MailSyncStore.default_state_dir)
        @root = File.expand_path(root)
        @state_dir = state_dir
      end

      def folder_dir(folder_path) = File.join(root, folder_path.tr('/', '-'))

      def index_exists?(folder_path) = File.file?(index_path(folder_path))

      def load_index(folder_path)
        data = read_json(index_path(folder_path))
        data.is_a?(Hash) ? data.fetch('messages', {}) : {}
      end

      def save_index(folder_path, messages)
        dir = ensure_dir(folder_dir(folder_path))
        atomic_write(File.join(dir, INDEX_FILE),
                     JSON.pretty_generate('version' => 1, 'folder' => folder_path, 'messages' => messages))
      end

      # :created, :updated, or :unchanged (identical content is never rewritten)
      def write_message(folder_path, filename, content)
        path = File.join(ensure_dir(folder_dir(folder_path)), filename)
        existed = File.exist?(path)
        return :unchanged if existed && File.read(path) == content

        atomic_write(path, content)
        existed ? :updated : :created
      end

      # Delta state for this root, keyed by Graph folder ID
      def load_state
        roots = read_json(state_path)
        folders = roots.is_a?(Hash) ? roots.dig('roots', root, 'folders') : nil
        folders.is_a?(Hash) ? folders : {}
      end

      def save_state(folders)
        data = read_json(state_path)
        data = {} unless data.is_a?(Hash)
        (data['roots'] ||= {})[root] = { 'folders' => folders }
        ensure_dir(@state_dir)
        atomic_write(state_path, JSON.pretty_generate(data))
      end

      # Yields while holding the mail sync lock; returns :locked without yielding if another run holds it
      def with_lock
        ensure_dir(@state_dir)
        File.open(File.join(@state_dir, 'mail-sync.lock'), File::RDWR | File::CREAT, 0o600) do |lock|
          return :locked unless lock.flock(File::LOCK_EX | File::LOCK_NB)

          yield
        end
      end

      private

      def index_path(folder_path) = File.join(folder_dir(folder_path), INDEX_FILE)

      def state_path = File.join(@state_dir, STATE_FILE)

      def ensure_dir(dir)
        FileUtils.mkdir_p(dir, mode: 0o700)
        dir
      end

      def read_json(path)
        File.file?(path) ? JSON.parse(File.read(path)) : {}
      rescue JSON::ParserError
        File.rename(path, "#{path}.corrupt.#{Time.now.strftime('%Y%m%d%H%M%S')}")
        {}
      end

      def atomic_write(path, content)
        tmp = "#{path}.tmp.#{Process.pid}"
        File.write(tmp, content)
        File.rename(tmp, path)
      end
    end
  end
end
