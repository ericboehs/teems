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
```

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
teems meeting "https://teams.microsoft.com/..."    # By Teams URL or recap link
```

Recording download requires `ffmpeg` (`brew install ffmpeg`) and downloads via DASH streaming with 5 parallel threads. No browser required.

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
```

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
