# teems

A command-line interface for Microsoft Teams. Read messages, list channels and chats from the terminal.

Pure Ruby, no dependencies.

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
- macOS (for Safari token extraction)
- Microsoft Teams account

## Authentication

teems requires authentication tokens from Teams. The easiest way is Safari automation:

```bash
teems auth login
```

This opens Safari to teams.microsoft.com, waits for you to log in, then extracts the tokens.

Alternatively, extract tokens manually:

```bash
teems auth manual
```

## Usage

### List Teams and Channels

```bash
teems channels
```

### List Chats

```bash
teems chats
teems chats -n 50  # Show 50 chats
```

### Read Messages

```bash
# Read from a chat
teems messages <chat-id>

# Read from a channel (requires team ID)
teems messages <channel-id> -t <team-id>

# Show more messages
teems messages <chat-id> -n 50
```

### Check Authentication Status

```bash
teems auth status
```

### Clear Authentication

```bash
teems auth logout
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

- Config: `~/.config/teems/`
- Cache: `~/.cache/teems/`

### Custom Endpoints

By default, teems connects to commercial Microsoft Teams endpoints. To use a different environment (e.g., GCC, GCC High), add an `endpoints` section to `~/.config/teems/config.json`:

```json
{
  "endpoints": {
    "msgservice": "https://ng.msg.gcc.teams.microsoft.com",
    "presence": "https://presence.gcc.teams.microsoft.com"
  }
}
```

Available endpoint keys: `graph`, `teams`, `msgservice`, `presence`.

## Token Expiration

Teams tokens expire after ~24 hours. When you see authentication errors, run:

```bash
teems auth login
```

## Development

```bash
git clone https://github.com/ericboehs/teems
cd teems
rake check   # Syntax check
rake test    # Run tests
rake console # Interactive console
```

## License

MIT License. See [LICENSE](LICENSE).
