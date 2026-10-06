# Changelog

## [Unreleased]

### Fixed
- `teems sync` no longer merges different chats into one folder. Folder names used to identify generic chats ("Group Chat", "1:1 Chat") by the first 20 characters of the chat ID, which every 1:1 chat with the same person starts with, and named chats by their title alone. New chats, and chats whose title or type changes, now get a folder name ending with the chat's full ID. A name already used by another chat is never handed out, and a name that would still clash (IDs differing only in letter case on a case-insensitive filesystem) falls back to the ID plus a hash.
- 1:1 chats are classified as 1:1 chats (`dms/`, "1:1 Chat") instead of group chats.

### Changed
- Existing chat folders keep their names when only one chat uses them, so links into the sync folder keep working. 1:1 chats an older version filed under `groups/` move to `dms/`. `teems sync --migrate-dirs` renames every folder to the full-ID naming and writes an old to new map to `sync/dir-maps/`.
- `teems sync` detaches folders that an older version gave to more than one chat that has synced into them. The folders and their files are left untouched (the path is recorded as `legacy_shared_dir` in `sync_state.json`). Each affected chat gets its own folder and re-fetches history back to the oldest message in the old folder, or `--since` days if that is earlier. `teems sync --chat ID` only detaches that chat. Chats that never synced don't count toward a folder being shared.
- `teems sync` lists each folder move as old → new, warns when the new folder already exists and the old one is left in place, and keeps listing old shared folders while they are still on disk. `teems sync --dry-run` previews every folder move and detach without changing anything.

## [0.3.4] - 2026-10-05

### Added
- `teems cal create --all-day --end YYYY-MM-DD` creates one multi-day all-day event. `--end` is the last day, inclusive (like `teems ooo --end`), so `--date 2026-11-12 --end 2026-11-13` covers both days. Leaving out `--end` still creates a single-day event.
- `teems cal create --all-day --start YYYY-MM-DD` works as an alias for `--date`.

### Changed
- `teems cal create --all-day` now rejects options it used to silently ignore: `--duration`, an `--end` before the first day, a time of day in `--start` or `--end`, and `--date` combined with `--start`.
- The created-event summary shows the date range of a multi-day all-day event (`2026-11-12 to 2026-11-13 (all day)`).

### Fixed
- `teems cal --help` examples that continue onto a second line render as two lines instead of being run together.

## [0.3.3] - 2026-10-02

### Added
- Inline images (screenshots pasted into a message) are no longer dropped when message HTML is stripped. `teems messages` lists them under the message, and `--json` includes an `images` array with the AMS URL, full-size URL, alt text, and dimensions.
- `teems messages --download` saves inline images alongside file attachments, fetching the original-resolution AMS view (falling back to the message's preview URL) with the skype token. The token is only sent to Teams/AMS hosts over HTTPS and is dropped on redirects elsewhere.
- `teems sync` records inline images in `messages.json` and renders `[image: alt (WxH)]` placeholders in `messages.md`. `teems sync --images` downloads them into each chat's `images/` directory, links them from `messages.md`, and backfills already-synced chats.

### Fixed
- `teems messages <teams-url>` for a message in a group or 1:1 chat no longer fails with "Failed to fetch message"; those chats have no reply threads, so the replies endpoint's 404 now means no replies.
- `teems messages --json <teams-url>` no longer crashes with "no implicit conversion from nil to integer" after printing the thread.

## [0.3.2] - 2026-09-29

### Added
- `teems transcripts sync` discovers calendar Teams meetings and downloads available WebVTT transcripts into a private XDG data directory. The first run scans 30 days; subsequent runs scan seven, with an idempotent manifest and catch-up after time away. `--date`, `--since`, and `--dry-run` are supported. Recordings and audio are not downloaded.
- Transcript sync writes speaker-turn Markdown copies to `~/.local/share/teems/transcripts-md/` for local search indexes such as qmd.
- Transcript sync can run a `transcripts.post_sync_command` from `config.json` (for example, a qmd index refresh) after a sync that changed Markdown. The command gets the changed paths in `TEEMS_TRANSCRIPTS_*` environment variables, is bounded by `post_sync_timeout` (default 300 seconds), and warns rather than failing the sync. `--no-post-sync` skips it for one run.
- Transcript sync keeps one transcript per recording, so meetings that were restarted mid-session no longer lose the later recording's transcript. Existing per-meeting downloads are reused when identical rather than duplicated.
- `teems meeting --json` prints call events, recording links, and transcript markers as JSON (the option was documented but ignored).
- `teems meeting --transcript --recording-url URL` downloads the transcript for a specific recording in the meeting instead of the first one.

## [0.3.1] - 2026-09-02

### Added
- `teems meeting --date YYYY-MM-DD` - Pick a single occurrence of a recurring meeting series by date. Filters call events, recordings, transcripts, and chat messages to that day in the user's local timezone, so iterating multiple days from the same series is a one-liner shell loop. Errors when nothing matches.
- `teems meeting --date` automatically paginates the chat thread via `_metadata.backwardLink` until the page covers the requested date — using `lastCompleteSegmentStartTime` as the boundary cursor so pages with interleaved old replies/system messages don't terminate pagination prematurely. Capped at 50 pages of 200 messages as a safety net; cap-hit surfaces a user-visible error. API errors mid-pagination now exit non-zero instead of rendering partial data as success.
- `teems messages <teams-url>` now treats a message permalink as a thread root: it fetches the linked message and its replies and renders them with a `--- N replies ---` separator (modelled after `slk view`). Falls back to listing recent messages when the URL has no message ID.

### Fixed
- `teems auth login` no longer hangs and then fails on a first login. The Safari OAuth flow read its tenant from `tokens.json` and bailed when it was absent, so the flow that obtains tokens required tokens to already exist; it now falls back to the `common` tenant. The redirect poll also assumed silent SSO with a 12-second budget, which never survived an account picker, MFA, or a PIV/CAC certificate prompt — it now polls every tab for three minutes and prints a visible "waiting for sign-in" notice instead of sitting silent
- `teems auth login` records the tenant the token was actually issued for instead of the placeholder used to start the flow, so refreshes and the headless helper use the tenant-specific endpoint
- Interrupting a command that is waiting on a child process (Safari sign-in, the headless helper, or the Swift compile) no longer prints `Open3` reader-thread `IOError` backtraces before exiting
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
