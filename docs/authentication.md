# Authentication

teems uses Microsoft Teams authentication tokens to access the Graph API and Skype/messaging APIs. There are three layers to the auth system: initial login, token refresh, and headless extraction.

## Token Types

| Token | Purpose | Lifetime | Header Format |
|-------|---------|----------|---------------|
| `auth_token` | Graph API (chats, channels, calendar) | ~1 hour | `Authorization: Bearer <token>` |
| `skype_token` | Skype messaging API (messages, presence) | ~24 hours | `Authentication: skypetoken=<token>` |
| `skype_spaces_token` | Intermediate token exchanged for `skype_token` | ~1 hour | N/A |
| `refresh_token` | OIDC refresh (renews all tokens silently) | ~24 hours (rolling) | N/A |

## Login Flow

```
teems auth login
```

### Headless (primary, macOS only)

A Swift helper (`support/token_helper.swift`) uses a headless WKWebView to perform the OAuth2 implicit flow:

1. Navigates to Entra ID `/authorize` with `login_hint` and `domain_hint` (extracted from stored tokens)
2. Entra ID redirects to `certauth.login.microsoftonline.com` for PIV/smart card certificate auth
3. macOS presents the PIV PIN prompt (cached after first entry)
4. Auto-clicks "Stay signed in?" (KMSI page)
5. Intercepts the redirect to `teams.microsoft.com/go#id_token=...`
6. Makes a second `/authorize` request for the Skype API scope
7. Exchanges the Skype spaces token for a Skype token via the authsvc endpoint

The Swift binary is compiled automatically on first use (`swiftc` required). Subsequent runs reuse the WKWebView's cached session cookies (~1 second, no PIN prompt).

### Safari fallback

If the headless helper fails (no cached session, `swiftc` not available, or non-macOS), teems falls back to Safari automation via AppleScript:

1. Opens a new Safari tab to `teams.microsoft.com`
2. Waits for login to complete (PIV/Entra ID)
3. Extracts tokens from `localStorage` via JavaScript injection
4. Supports both V1 (plain text) and V2 (AES-CBC encrypted) token formats

### Manual entry

```
teems auth set-tokens        # Interactive prompt
teems auth set-tokens <file> # Import from JSON file
teems auth manual            # Show browser console extraction instructions
```

## Token Refresh

When an API call returns 401, teems automatically refreshes tokens:

### OIDC refresh (primary)

If `refresh_token`, `client_id`, and `tenant_id` are stored:

1. POST to `login.microsoftonline.com/{tenant}/oauth2/v2.0/token` with `grant_type=refresh_token`
2. Requests new Graph API token, then Skype API token
3. Exchanges for Skype token via authsvc
4. Saves all new tokens including a **new refresh token** (rolling 24-hour window)

Requires the `Origin: https://teams.microsoft.com` header (Entra ID SPA client requirement).

### authsvc fallback

If no OIDC credentials are available, exchanges the stored `skype_spaces_token` for a new `skype_token` via `teams.microsoft.com/api/authsvc/v1.0/authz`. Only refreshes the Skype token.

## Token Storage

Tokens are stored at `$XDG_CONFIG_HOME/teems/tokens.json` (default: `~/.config/teems/tokens.json`) with `0600` permissions.

```json
{
  "name": "default",
  "auth_token": "eyJ...",
  "skype_token": "eyJ...",
  "skype_spaces_token": "eyJ...",
  "refresh_token": "1.ARMA...",
  "client_id": "5e3ce6c0-...",
  "tenant_id": "e95f1b23-...",
  "saved_at": "2026-03-15T15:00:00-05:00",
  "tokens_refreshed_at": "2026-03-15T21:00:00-05:00"
}
```

## Keeping Tokens Alive

The OIDC refresh token has a ~24-hour rolling expiry. Each successful refresh returns a new refresh token, resetting the clock. As long as you run any `teems` command (or `teems auth login`) at least once a day, you'll never need to re-authenticate through a browser.

If the refresh token expires, run `teems auth login` to start a fresh session.
