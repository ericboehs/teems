# Teems - Claude Code Instructions

## Project Overview

Ruby CLI for Microsoft Teams (`teems` command). Pure Ruby, zero runtime dependencies, Ruby 3.2+. macOS-only (Safari/WKWebView token extraction via AppleScript).

## Quick Reference

```bash
rake test             # Run all tests
rake test:models      # Run model tests only
rake test:services    # Run service tests only
rake test:commands    # Run command tests only
bundle exec rubocop   # Lint
bundle exec reek      # Code smell detection
rake console          # IRB with teems loaded
```

## Architecture

```
lib/teems.rb              # Entry point, autoloads all modules
lib/teems/cli.rb           # CLI entry: argv parsing, command dispatch, error handling
lib/teems/runner.rb        # DI container: wires services together for commands
lib/teems/commands/base.rb # Base command: option parsing, output helpers, token refresh
lib/teems/commands/       # Commands: auth, cal, channels, chats, messages, sync, help
lib/teems/api/            # Thin API wrappers (Graph, chatsvc, calendar)
lib/teems/services/       # Core services: ApiClient, TokenStore, TokenExtractor, SyncStore/Engine
lib/teems/models/         # Data models: Account (Data.define), Channel, Chat, Message, Event, User
lib/teems/formatters/     # Output formatting: Output (ANSI colors), MessageFormatter, MarkdownFormatter
lib/teems/support/        # Utilities: XdgPaths, HelpFormatter, ErrorLogger
```

### Key Patterns

- **Autoloading**: All modules use `autoload` (no Zeitwerk), defined in `lib/teems.rb`
- **DI via Runner**: `Runner` is the dependency injection container; commands receive it in their constructor. It holds `output`, `config`, `token_store`, `api_client`, `cache_store` and creates API instances on demand
- **Command structure**: Commands inherit `Commands::Base`, implement `#execute` returning an integer exit code (0=success, 1=error). Options are parsed manually (no optparse gem for commands)
- **Data models**: `Account` uses `Data.define`. Other models use plain classes with `from_api` class methods for API response parsing
- **Error hierarchy**: `Teems::Error` < `StandardError`, with `ApiError` (has `status_code`), `ConfigError`, `AuthError`, `TokenStoreError`
- **Token refresh**: `Commands::Base#with_token_refresh` catches 401/expired errors, calls `runner.refresh_tokens`, and retries the block once
- **XDG paths**: Config in `~/.config/teems/`, cache in `~/.cache/teems/`, data in `~/.local/share/teems/`

## Testing

- **Framework**: Minitest + SimpleCov (line + branch coverage)
- **Test helper**: `test/test_helper.rb` — includes `Teems::TestHelpers` into all tests
- **Key test helpers**:
  - `test_output` / `test_runner` — create test doubles for Output/Runner
  - `configured_runner(output:, account:)` — Runner with MockTokenStore + MockApiClient
  - `with_temp_config { |dir| ... }` — sets XDG env vars to a temp dir, restores after
  - `capture_output { |output| ... }` — returns `{ stdout:, stderr: }` hash
  - `mock_account(name:, auth_token:, skype_token:)` — creates a test Account
  - `MockApiClient` — supports `stub(path, response)`, `stub_error(path, error)`, `stub_transient_error(path, error, times:)`
  - `MockTokenStore` — minimal token store for tests
- **Sample data**: `SampleData` module in test_helper provides `sample_graph_message`, `sample_ng_msg_message`, `sample_chat`, `sample_event_data`, etc.
- **HTTP response mocks**: Use `Net::HTTPResponse::CODE_TO_OBJ[code].new(...)` for realistic responses in case/when matching
- **TokenExtractor tests**: `TestableTokenExtractor` subclass overrides `run_applescript`, `system`, `sleep`

## Code Style

- `frozen_string_literal: true` on every Ruby file
- RuboCop with `TargetRubyVersion: 3.2`, `NewCops: enable`
- Reek configured in `.reek.yml` (excludes test dir, has specific detector thresholds)
- Ruby 3.1+ endless methods used for simple accessors (e.g., `def verbose? = @mode == :verbose`)
- Post-edit hook runs RuboCop + Reek automatically on changed `.rb` files

## Git Commits

- Do not add "Co-Authored-By" lines to commit messages

## PR Workflow

After creating a PR:
1. Run `/review` to review the PR
2. Address any issues found, commit, and push
3. Check CI status with `gh pr checks` and monitor until all checks pass

## CI

GitHub Actions runs on push/PR to main:
- Tests on Ruby 3.2, 3.3, 3.4, 4.0 (ubuntu-latest)
- RuboCop + Reek lint on Ruby 3.4
