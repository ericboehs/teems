# Teems - Microsoft Teams CLI

## Summary

A Ruby CLI for Microsoft Teams, modeled after the `slk` Slack CLI. Pure Ruby, zero dependencies, Ruby 3.2+.

## Current Status

### Working
- `teems channels` - Lists teams and channels via Graph API
- `teems auth set-tokens <file>` - Stores tokens from JSON file
- Token extraction from Safari localStorage via AppleScript

### Not Working
- `teems messages` - Returns 403 Forbidden (Graph API) or 401 Unauthorized (chatsvc API)

## Architecture

```
lib/teems/
├── api/
│   ├── client.rb      # Base API client
│   ├── channels.rb    # Graph API for teams/channels
│   ├── chats.rb       # Graph API for chats
│   └── messages.rb    # chatsvc API for messages
├── commands/
│   ├── auth.rb        # Token management
│   ├── channels.rb    # List channels
│   ├── chats.rb       # List chats
│   ├── messages.rb    # Read messages
│   └── help.rb
├── services/
│   ├── api_client.rb  # HTTP client with multi-endpoint support
│   └── token_store.rb # XDG-compliant token storage
└── models/
    └── account.rb     # Token container
```

## API Endpoints

Teams uses multiple APIs:

1. **Graph API** (`graph.microsoft.com`) - Works for listing teams/channels
   - Token audience: `https://graph.microsoft.com`
   - Stored as `auth_token`

2. **Chatsvc API** (`chatsvcagg.gcc.teams.microsoft.com`) - For messages (GCC environment)
   - Token audience: `https://chatsvcagg.gcc.teams.microsoft.com`
   - Stored as `skype_token`
   - **Problem**: 401 Unauthorized on all message endpoints

## The Messages Problem

The Graph API returns 403 because the token lacks `ChannelMessage.Read.All` scope (requires admin consent).

The chatsvc API returns 401 even with correct token audience. Tried:
- `Authorization: Bearer <token>`
- `Authentication: skypetoken=<token>`
- `X-Skypetoken: <token>`

Teams v2 web client seems to use a different auth mechanism or additional headers we haven't identified.

## Token Extraction

Tokens are in Safari localStorage at `teams.microsoft.com`:
```javascript
// Graph token
localStorage key containing "accesstoken" and "graph.microsoft.com"

// Chatsvc token
localStorage key containing "accesstoken" and "chatsvcagg.gcc.teams.microsoft.com"
```

Save to `~/.config/teems/tokens.json`:
```json
{
  "auth_token": "<graph token>",
  "skype_token": "<chatsvc token>"
}
```

## Next Steps

1. **Find correct auth for messages** - Options:
   - Use Microsoft Teams MCP server as reference
   - Capture actual network requests from Teams web client
   - Try the `teams.microsoft.com/api/csa-gcc/` endpoint with cookies

2. **Consider alternative approaches**:
   - Use Selenium/Playwright to automate Teams web
   - Use Microsoft Graph with application permissions (requires admin)

## Commands

```bash
# Set tokens from file
teems auth set-tokens tokens.json

# List channels
teems channels

# Read messages (not working yet)
teems messages <channel_id> -t <team_id>
```

## Token File Format

```json
{
  "auth_token": "eyJ...",
  "skype_token": "eyJ..."
}
```
