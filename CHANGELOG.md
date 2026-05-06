# Changelog

## [Unreleased]

### Added
- `teems meeting --date YYYY-MM-DD` - Pick a single occurrence of a recurring meeting series by date. Filters call events, recordings, and transcripts to that day in the user's local timezone, so iterating multiple days from the same series is a one-liner shell loop. Errors when nothing matches.
- `teems meeting --date` automatically paginates the chat thread via `_metadata.backwardLink` until the page covers the requested date, so picking older occurrences of a recurring meeting works without bumping `--limit` (capped at 50 pages of 200 messages each as a safety net).
- `teems messages <teams-url>` now treats a message permalink as a thread root: it fetches the linked message and its replies and renders them with a `--- N replies ---` separator (modelled after `slk view`). Falls back to listing recent messages when the URL has no message ID.

### Fixed
- `teems org` no longer hangs when the manager chain contains a cycle; cycle detection breaks the walk on the first repeated manager

## [0.3.0] - 2026-04-23

### Added
- `teems meeting --audio` - Download audio-only M4A alongside or instead of video (ideal for transcription)
- `teems meeting --no-video` - Skip the video download for audio-only output
- `teems ooo` now supports timed schedules via `--start`/`--end` (e.g., "today 14:00") in addition to all-day dates
- `teems ooo --invite` - Override the configured notify list for a single invocation

### Changed
- Recording, audio, and transcript files share a common base name derived from the SharePoint file (e.g., `2026-01-20 - Team Sync.mp4`/`.m4a`/`.vtt`)

### Fixed
- `teems meeting` shows call duration once on the event header instead of repeating it per participant

## [0.2.0] - 2026-04-14

### Added
- `teems meeting` - View meeting details, download transcripts, and download recordings
- Auto-authentication when tokens are missing or expired (no manual `auth login` needed)

### Fixed
- `teems cal delete` now uses configured endpoints instead of hardcoded defaults

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
