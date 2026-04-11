# Changelog

## [0.1.0] - 2026-04-10

### Added
- `teems auth login` - Headless, Safari OAuth, and Safari-based token extraction
- `teems auth status` - Show authentication status
- `teems auth logout` - Clear stored tokens
- `teems channels` - List joined teams and channels
- `teems chats` - List recent chats
- `teems messages` - Read messages from channels and chats
- `teems cal` - List calendar events, view details, accept/decline/tentative
- `teems cal create` - Create calendar events with attendees, rooms, and all-day support
- `teems cal delete` - Delete calendar events
- `teems activity` - Show activity feed (mentions, reactions, calendar)
- `teems who` - Look up user profiles
- `teems org` - Show org chart
- `teems ooo` - Manage out-of-office (auto-reply, status, presence, calendar event)
- `teems status` - View and manage presence status
- `teems sync` - Sync chat history locally
- Automatic token refresh via OIDC
- Configurable API endpoints for commercial and GCC environments
- JSON output support with `--json` flag
- Pure Ruby implementation with no runtime dependencies
