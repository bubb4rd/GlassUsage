# How GlassUsage works

GlassUsage has no account or server of its own. It reads what Claude Code, Codex, Antigravity and Muse Code already keep on your Mac, and it asks each provider (directly or through its own CLI) for your current plan limits.

## Plan limits

| Provider | Endpoint | Credentials |
| --- | --- | --- |
| Claude | `GET api.anthropic.com/api/oauth/usage` | Claude Code's Keychain item `Claude Code-credentials` (read through `/usr/bin/security`), falling back to `~/.claude/.credentials.json` |
| Codex | `GET chatgpt.com/backend-api/wham/usage` | `~/.codex/auth.json` (`$CODEX_HOME` and `chatgpt_base_url` are honored) |
| Antigravity | `agy -p /usage --output-format json` | The Antigravity CLI's own sign-in; GlassUsage never sees it |
| Muse Code | `muse usage --json` (with `MUSE_NO_AUTO_UPDATE=1`) | The Muse Code CLI's own sign-in; GlassUsage never sees it |

- GlassUsage only reads these credentials. It never stores, refreshes or rewrites them.
- When the Claude access token has expired, GlassUsage runs `claude -p /usage` (at most once every 5 minutes) so that Claude Code renews its own token. That is a local command and makes no model request.
- Antigravity and Muse Code keep their logins in the Keychain under their own access lists, so GlassUsage asks their CLIs instead. Both commands report the allowance without running a model turn or spending quota.
- Antigravity meters model groups separately (Gemini, Claude and GPT, Gemini 4 Argon), each with its own 5-hour and weekly window, so the panel shows one group's rings at a time with arrows to step between them, and the panel and menu bar start on the group closest to its limit.
- None of these endpoints or commands is a documented API, and they may change. GlassUsage shows exactly the windows the provider reports and never estimates a limit.
- Limits refresh on the interval set in Settings, just after a window's reset time, and a few seconds after the Mac wakes. Once a window's reset time has passed, it reads 0% until the next reading arrives.
- When a usage service rate-limits GlassUsage, it waits as long as the service asks (`Retry-After`, at most an hour), or otherwise 5 minutes, doubling up to an hour, before asking that service again.
- With *Alerts* on, each window notifies once when it reaches the chosen level and once when that window resets. Windows waiting for their reset alert are saved with the settings, so a relaunch doesn't repeat an alert. Notifications are local; nothing is sent anywhere.

## Token spend

Spend is read from local session logs in the same way as [ccusage](https://github.com/ryoppippi/ccusage):

| Tool | Logs | Notes |
| --- | --- | --- |
| Claude Code | `~/.claude/projects/**/*.jsonl`, `~/.config/claude/projects` (or `$CLAUDE_CONFIG_DIR`) | Deduplicated by message id + request id |
| Codex CLI | `$CODEX_HOME/sessions/**/rollout-*.jsonl`, `archived_sessions` | Cumulative `token_count` deltas; replayed history in forked sessions is skipped |
| Muse Code | `$XDG_DATA_HOME/muse/sessions/**/session.jsonl` (default `~/.local/share`, or `$MUSE_SESSIONS_DIR`) | `model_completed` events only, deduplicated by stream id + sequence; subagent transcripts are read on their own |
| Antigravity (CLI, desktop app, IDE and T3 Code) | `~/.gemini/antigravity-cli/conversations/*.db`, the desktop app's `~/.gemini/antigravity/conversations/*.db` and the IDE's `~/.gemini/antigravity-ide/conversations/*.db`; T3 Code's per-account `~/.t3/userdata/providers/antigravity/*/antigravity-acp/conversations/*.db` (or `$T3CODE_HOME`) | One SQLite database per conversation, opened read-only; usage from `gen_metadata` and `steps`, retries included, deduplicated by response id. The desktop app names models only by placeholder, mapped to its catalog as of app 2.19.1. Older encrypted `.pb` conversations are skipped |
| omp | `~/.omp/agent/sessions/**/*.jsonl` | Uses the cost omp recorded; `anthropic` counts toward Claude, `openai`/`openai-codex` toward Codex |
| Cline, Roo Code and Kilo Code | Each extension's `User/globalStorage/<extension id>/tasks/*/ui_messages.json` in any VS Code-based editor (VS Code, Cursor, Windsurf, Antigravity, Kiro, VSCodium and others); Cline's `~/.cline/data/{tasks,sessions}` (or `$CLINE_DATA_DIR`); Kilo Code 7's `~/.local/share/kilo/kilo.db` | One `api_req_started` message per call in task logs, `metrics` per assistant message in Cline sessions, OpenCode-style `tokens` in Kilo's database. Claude models count toward Claude and GPT models toward Codex; other models aren't counted, nor calls through Cline's Claude Code provider, which Claude Code logs itself |

- Only logs changed in the last 30 days are read, and each log is parsed incrementally from where the previous scan stopped. Databases, and the JSON files Cline and its forks rewrite in place, are reread whole when they change.
- Parsed entries are cached in `~/Library/Application Support/GlassUsage/local-usage-cache/`, one file per log, so a scan rewrites only the logs that changed.
- Projects are the folder a session ran in: `cwd` on Claude Code lines, the session header in omp, `session_meta`/`turn_context` in Codex, the `runtime.session.metadata` record's `workspace_root` in Muse Code, the workspace in each Antigravity conversation's `trajectory_metadata_blob`, the task's `workspace` (Roo, Kilo) or `cwdOnTaskInitialization` (Cline), and the session folder in Cline's and Kilo's newer stores. The list shows up to five rows that add up to the range: projects with at least 1% of its tokens, then *Other* for the rest (smaller projects, temporary folders such as `$TMPDIR` and `/tmp`, and sessions with no folder).
- Costs are API-equivalent list prices from [LiteLLM's catalog](https://github.com/BerriAI/litellm/blob/main/model_prices_and_context_window.json). This is what the tokens would cost on the API, not what a subscription bills you. The catalog is refreshed daily, and a built-in table covers offline use.

## Network access

GlassUsage connects to:

- `api.anthropic.com`, for Claude limits
- `chatgpt.com`, for Codex limits
- `raw.githubusercontent.com`, for the LiteLLM price list
- `github.com`, for update checks (Sparkle appcast and downloads)

Antigravity and Muse Code limits are fetched by their own CLIs, which talk to Google and Meta. GlassUsage has no analytics or telemetry.

## Files on disk

| Path | Contents |
| --- | --- |
| `~/Library/Application Support/GlassUsage/` | Parsed log cache and price list |
| `~/Library/Preferences/io.github.bubb4rd.GlassUsage.plist` | Settings and the last limit readings |
