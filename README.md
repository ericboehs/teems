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
teems cal delete 3           # Delete event #3
```

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
