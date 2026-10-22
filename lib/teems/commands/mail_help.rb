# frozen_string_literal: true

module Teems
  module Commands
    # `teems mail --help`
    module MailHelp
      TEXT = <<~HELP
        teems mail - Read and triage Outlook mail via Microsoft Graph (never sends)

        USAGE:
          teems mail list [folder] [count]              Newest messages (alias: recent)
          teems mail read <id> [--html]                 Headers, plain-text body, numbered links
          teems mail folders                            Folders with unread and total counts
          teems mail search <query> [folder]            Graph $search (KQL), e.g. "from:alice subject:report"
          teems mail sync [folder...] [options]         Incremental local copy (Graph delta)

        TRIAGE:
          teems mail mark-read <id>...                  Mark read (mark-unread: unread)
          teems mail flag <id>... [--due DATE]          Flag for follow-up (unflag: clear it)
          teems mail archive <id>...                    Move to Archive
          teems mail move <id>... --to FOLDER           Move to a folder
          teems mail delete <id>...                     Move to Deleted Items (never purges)

          Instead of IDs, select messages with --search QUERY [--folder NAME] or
          --folder NAME [--unread] [--flagged] (up to 1,000; -n for fewer). A selection
          is confirmed first: answer the prompt, or pass --yes. --dry-run lists the
          messages without changing them.

        RULES (Inbox rules, applied by Exchange as mail arrives):
          teems mail rules                              List them in order (alias: rules list)
          teems mail rules add <name> <conditions> <actions>
          teems mail rules enable <rule>                Turn on (disable: turn off)
          teems mail rules delete <rule>                Remove (asks first; --yes skips)

          <rule> is a name, the number rules lists, or an ID (--tsv shows them).
          Conditions (repeatable; a message must match each kind given):
            --from ADDR  --sent-to ADDR  --subject TEXT  --body TEXT
          Actions: --move-to FOLDER  --copy-to FOLDER  --mark-read  --category NAME
            --importance low|normal|high  --delete (to Deleted Items)  --stop (skip later rules)
          --disabled adds the rule turned off, and --dry-run shows it without adding it.
          Rules never forward or redirect mail, and one that does is not turned on.

        OPTIONS:
          --unread          list, triage --folder: only unread messages
          --flagged         list, triage --folder: only flagged messages
          --html            read: print the raw HTML body
          --folder NAME     search: limit to a folder; sync: folder to sync (repeatable)
          --search QUERY    triage: act on the messages a KQL search finds
          --to FOLDER       move: destination folder
          --due DATE        flag: due date (YYYY-MM-DD, today, tomorrow, or a weekday)
          --dry-run         triage: list what would change, change nothing
          -y, --yes         triage: act on a selection without asking
          --tsv             list/search/folders: tab-separated output with full IDs
          -n, --limit N     list: count (default 20); search: max results (default 20)
          --json            JSON output

        SYNC OPTIONS:
          --dir DIR         Store root (default ~/.local/share/teems/sync/mail)
          --since DAYS      First sync of a folder: only mail from the last DAYS days,
                            or "all" (default 90). Later runs fetch only changes.
                            Graph caps a first sync limited by DAYS at 5,000 messages
                            per folder; use "all" for more.
          --attachments     Also download file attachments to <Folder>/attachments/
          --no-login        Never open Safari: renew expired tokens silently from the
                            cached sign-in, or fail (for launchd and cron)

        Folders are names ("Inbox", "Sent Items", "Projects/EERT"), well-known names
        (inbox, archive, sent, drafts, deleted, junk), or Graph folder IDs. IDs from
        list and search are short handles; read and triage accept them or full Graph IDs.

        Sync writes one Markdown file per message plus <Folder>/index.json, and keeps
        delta links in ~/.local/state/teems/mail-sync.json. Syncing into a directory an
        older outlook-cli sync filled (e.g. ~/Mail) adopts its files instead of
        duplicating them. Removed messages keep their file; the index marks them.
      HELP
    end
  end
end
