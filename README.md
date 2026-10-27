# teems

A command-line interface for Microsoft Teams. Read messages, manage your calendar, set out-of-office, and more — all from the terminal.

Pure Ruby, no runtime dependencies. macOS only (uses Safari for authentication).

## Installation

```bash
gem install teems
```

Or build from source:

```bash
git clone https://github.com/ericboehs/teems
cd teems
gem build teems.gemspec
gem install teems-*.gem
```

## Requirements

- Ruby 3.2+
- macOS (for Safari/WKWebView token extraction)
- Microsoft Teams account

## Authentication

```bash
teems auth login     # Authenticate (headless or Safari)
teems auth status    # Check if authenticated
teems auth logout    # Clear stored tokens
```

Tokens refresh automatically when you run commands. If they expire (~24 hours of inactivity), just run `teems auth login` again.

## Commands

### Calendar

```bash
teems cal                    # Today's events
teems cal tomorrow           # Tomorrow's events
teems cal --week             # This week's events
teems cal show 3             # View details for event #3
teems cal accept 3           # Accept event #3
teems cal decline 3          # Decline event #3
teems cal create "Standup" --start "tomorrow 09:00" --attendees alice@example.com
teems cal create "PTO" --all-day --date 2026-11-12 --end 2026-11-13 --show-as oof
teems cal delete 3           # Delete event #3
```

All-day events cover `--date` (or `--start YYYY-MM-DD`; default today). Add `--end YYYY-MM-DD` for a multi-day event: like `teems ooo --end`, it is the last day of the event, inclusive. The example above is one event covering November 12 and 13.

#### ICS feed

```bash
teems cal ics > work.ics                       # 7 days back through 60 days ahead
teems cal ics --days 30 --days-back 0          # A different window
teems cal ics --exclude-attendee me@other.example --name "Work" --no-login
```

`teems cal ics` prints your calendar as an iCalendar file, for a local server that Calendar.app subscribes to. Every occurrence of a recurring meeting is its own event. Events keep their invitees, responses and description, and Teams meetings carry their join link (`URL`, `CONFERENCE`) so Calendar.app shows a Join button. Cancelled meetings are marked `STATUS:CANCELLED` and free time is `TRANSP:TRANSPARENT`. It reads your default calendar; `--all-calendars` adds the others (holidays, shared calendars), keeping an event that is on two of them once and skipping, with a warning, a shared calendar you cannot read. `--exclude-attendee` leaves out events those addresses organize or have accepted, such as ones already on another calendar you subscribe to. `--no-login` never opens Safari: expired tokens are renewed silently from the cached sign-in session when possible, and otherwise the command fails, which is what you want from launchd or a server.

### Mail

```bash
teems mail list                     # 20 newest Inbox messages (alias: recent)
teems mail list Archive 50 --unread # Folder and count, unread only
teems mail read 3fa2c1              # Headers, plain-text body, numbered links
teems mail read 3fa2c1 --html       # Raw HTML body
teems mail read 3fa2c1 --decrypt    # S/MIME encrypted mail, opened with your PIV card
teems mail folders                  # Unread and total counts
teems mail search "from:alice subject:report" --folder Inbox
teems mail sync Inbox "Sent Items" --since 30
teems mail list --flagged           # Flagged messages
```

Triage changes a message's read state or flag, or moves it. Name messages by ID, or select them with `--search` (optionally within `--folder`) or `--folder` with `--unread`/`--flagged`:

```bash
teems mail mark-read 3fa2c1 9b0e44            # mark-unread for the reverse
teems mail flag 3fa2c1 --due friday           # unflag clears it
teems mail archive 3fa2c1
teems mail move 3fa2c1 --to Projects/EERT
teems mail delete 3fa2c1                      # To Deleted Items, never purged
teems mail archive --search "from:jira" --dry-run   # List what would move
teems mail mark-read --folder Inbox --unread --yes
```

teems never sends mail, and reading a message does not mark it read. Message IDs in `list` and `search` output are short handles that `read` and the triage commands accept (`--tsv` prints the full Graph IDs). `search` and `--search` use Graph's KQL `$search`. A selection is confirmed before anything changes (or pass `--yes`) and stops at 1,000 messages (`-n` for fewer). `delete` moves messages to Deleted Items, as Outlook does.

Inbox rules, which Exchange applies as mail arrives:

```bash
teems mail rules                                   # In order: number, on/off, name, what it does
teems mail rules add Jira --from jira@example.com --move-to Projects/Jira --mark-read --stop
teems mail rules add Builds --subject "build failed" --category Red --dry-run
teems mail rules disable Jira                      # By name, number, or ID; enable turns it on
teems mail rules delete Jira                       # Asks first; --yes skips
```

A new rule needs at least one condition (`--from`, `--sent-to`, `--subject`, `--body`, each repeatable) and one action (`--move-to`, `--copy-to`, `--mark-read`, `--category`, `--importance`, `--delete` to Deleted Items, `--stop`). It goes last in order, and `--disabled` adds it turned off. teems never creates a rule that forwards or redirects mail, and won't turn on an existing one that does.

S/MIME encrypted mail reaches Graph with an empty body, so `read` labels it (`Encryption:` in the headers, `encryption` in `--json`) instead of showing nothing. `--decrypt` opens it with macOS's `security cms -D`, which finds the matching key in your keychain or on your PIV card (the current key management key or a retired one) and asks for the PIN in the system dialog. The ciphertext and plaintext travel over pipes, never to disk, and `sync` never decrypts. A signed message inside is unwrapped but its signature is not checked. Mail protected by Microsoft Purview (`message.rpmsg`, "Do Not Forward") uses Microsoft's rights management service rather than certificates and can only be read in Outlook.

`teems mail sync` keeps a Markdown copy of each message in `~/.local/share/teems/sync/mail/<Folder>/` (or `--dir`) with an `index.json` per folder. The first run of a folder fetches `--since` days (default 90, or `all`); later runs fetch only what changed, using Graph delta links stored in `~/.local/state/teems/mail-sync.json`. Messages that leave the folder keep their file and are marked `removed_at` in the index. `--attachments` also saves file attachments. A lock file keeps overlapping runs (launchd) from colliding. Syncing into a directory filled by the older AppleScript-based outlook-cli sync adopts its files instead of writing duplicates.

### Messages

```bash
teems messages <chat-id>                    # Read from a chat
teems messages <channel-id> -t <team-id>    # Read from a channel
teems messages <chat-id> -n 50              # Show more messages
teems messages <chat-id> --json             # JSON, including inline image refs
teems messages <chat-id> --download         # Save attachments and pasted images
```

Screenshots pasted into a message are listed under it (`🖼️ image (881x179)`) and included in `--json` as `images` (AMS `url`, `full_size_url`, `alt`, `width`, `height`). `--download` saves the original-resolution image to the downloads directory as `image-<hash>-<n>.<ext>`, using your Teams skype token. The token is only sent to Teams/AMS hosts over HTTPS.

### Channels and Chats

```bash
teems channels       # List joined teams and channels
teems chats          # List recent chats
teems chats -n 50    # Show 50 chats
```

### Out of Office

```bash
teems ooo                          # Check OOO status
teems ooo on                       # Enable OOO (auto-reply + presence)
teems ooo on --message "Vacation"  # Custom message
teems ooo on --start 2025-12-22 --end 2025-12-26  # Scheduled
teems ooo on --event               # Also create a calendar event for your notify list
teems ooo off                      # Disable OOO
teems ooo config                   # Show OOO configuration
```

### Meetings

```bash
teems meeting <thread-id>                          # View meeting summary
teems meeting <thread-id> --chat                   # Show meeting chat
teems meeting <thread-id> --transcript -o ~/Downloads  # Download transcript (VTT)
teems meeting <thread-id> --recording -o ~/Downloads   # Download recording (MP4)
teems meeting <thread-id> --recording --transcript -o ~/Downloads  # Both, with embedded subtitles
teems meeting <event-id>                           # By calendar event ID (AAMk...)
teems meeting <event-id> --date 2026-09-29 --json  # Call events + recording links as JSON
teems meeting <event-id> --date 2026-09-29 --transcript --recording-url <url>  # A specific recording
teems meeting "https://teams.microsoft.com/..."    # By Teams URL or recap link
```

Recording download requires `ffmpeg` (`brew install ffmpeg`) and downloads via DASH streaming with 5 parallel threads. No browser required.

#### Transcript sync

```bash
teems transcripts sync --dry-run          # Preview meetings and recording counts
teems transcripts sync                    # First run: 30 days; later: 7 days
teems transcripts sync --date 2026-09-28  # Retry a specific day
teems transcripts sync --since 30         # Explicit historical backfill
teems transcripts sync --no-post-sync     # Skip the configured post-sync command once
```

This saves **only WebVTT transcripts** in `~/.local/share/teems/transcripts/` on the machine running the command, separate from live-caption `meeting-capture` files. Each sync also writes speaker-turn Markdown copies to `~/.local/share/teems/transcripts-md/` (regenerated when missing or older than the VTT) for local search tools such as [qmd](https://github.com/tobi/qmd). Each recording keeps its own transcript, so a meeting restarted mid-session yields one VTT per recording. A private manifest in `~/.local/state/teems/transcript-sync.json` makes repeats idempotent and catches up after time away (up to 30 days). Data and state directories are mode 0700; transcripts and the manifest are mode 0600. The calendar scan retries unavailable transcripts within the lookback window; errors return a nonzero exit code. To run every evening on a GFE, schedule `teems transcripts sync` there via launchd.

Coverage is **calendar Teams meetings with a saved and accessible recording transcript**, not every meeting attended: ad-hoc calls, meetings with no saved transcript/recording, and inaccessible organizer-owned artifacts cannot be recovered by this route. No audio/video is downloaded, and nothing is copied to another machine.

To search the Markdown locally with qmd, keep it in a dedicated index so refreshes don't re-scan other collections:

```bash
qmd --index teems-transcripts collection add ~/.local/share/teems/transcripts-md --name teems-transcripts --mask '**/*.md'
qmd --index teems-transcripts update && qmd --index teems-transcripts embed
qmd --index teems-transcripts query "what did we decide about monitoring?"
```

To refresh that index automatically, set a post-sync command in `~/.config/teems/config.json`:

```json
{
  "transcripts": {
    "post_sync_command": "qmd --index teems-transcripts update && qmd --index teems-transcripts embed",
    "post_sync_timeout": 900
  }
}
```

The command runs via `sh -c` only after a sync writes or regenerates Markdown; not on `--dry-run`, when nothing changed, or with `--no-post-sync`. It receives `TEEMS_TRANSCRIPTS_CHANGED` (newline-separated Markdown paths), `TEEMS_TRANSCRIPTS_CHANGED_COUNT`, `TEEMS_TRANSCRIPTS_MARKDOWN_DIR`, and `TEEMS_TRANSCRIPTS_DIR`, and is killed after `post_sync_timeout` seconds (default 300). A failure or timeout prints a warning but does not change the sync's exit code.

### People

```bash
teems who              # Show your profile
teems who john         # Search for a user
teems org              # Show your org chart
teems org john         # Org chart for "john"
```

### Status and Activity

```bash
teems status                          # Show your presence
teems status --presence available     # Set presence
teems status --message "In a meeting" # Set status message
teems activity                        # Show activity feed
```

### Sync

```bash
teems sync             # Sync chat history locally
teems sync --images    # Also save pasted images beside each chat
```

Each chat gets `messages.md`, `messages.json`, and `chat_metadata.json` under `~/.local/share/teems/sync/chats/`. Inline images are recorded in `messages.json` and rendered in `messages.md` as `[image: alt (WxH)]`. With `--images`, they are downloaded to the chat's `images/` directory (named by AMS object id, so each is fetched once) and `messages.md` links the saved copy instead. `--images` also rewrites already-synced chats so images in older messages are backfilled.

## Global Options

| Option | Description |
|--------|-------------|
| `-n, --limit N` | Number of items to show (default: 20) |
| `-v, --verbose` | Show debug output |
| `-q, --quiet` | Suppress output |
| `--json` | Output as JSON |
| `-h, --help` | Show help |

## Configuration

Configuration is stored in XDG-compliant directories:

- Config: `~/.config/teems/config.json`
- Tokens: `~/.config/teems/tokens.json`
- Cache: `~/.cache/teems/`

### OOO Defaults

Set default messages and a notify list for the `ooo` command:

```json
{
  "ooo": {
    "internal_message": "I'm currently out of office.",
    "external_message": "Thank you for your message. I'm out of office.",
    "external_audience": "all",
    "status_message": "Out of Office",
    "notify": ["manager@example.com", "team@example.com"]
  }
}
```

### Custom Endpoints

By default, teems connects to commercial Microsoft Teams endpoints. To use a different environment (e.g., GCC, GCC High), add an `endpoints` section to your config:

```json
{
  "endpoints": {
    "msgservice": "https://ng.msg.gcc.teams.microsoft.com",
    "presence": "https://presence.gcc.teams.microsoft.com"
  }
}
```

Available endpoint keys: `graph`, `teams`, `msgservice`, `presence`.

## Development

```bash
git clone https://github.com/ericboehs/teems
cd teems
bundle install
rake test        # Run tests
rake console     # Interactive console
```

## License

MIT License. See [LICENSE](LICENSE).
