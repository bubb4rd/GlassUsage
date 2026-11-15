# How GlassUsage works

GlassUsage has no account or server of its own. It reads what Claude Code and Codex already keep on your Mac, and it asks Anthropic and OpenAI for your current plan limits.

## Plan limits

| Provider | Endpoint | Credentials |
| --- | --- | --- |
| Claude | `GET api.anthropic.com/api/oauth/usage` | Claude Code's Keychain item `Claude Code-credentials` (read through `/usr/bin/security`), falling back to `~/.claude/.credentials.json` |
| Codex | `GET chatgpt.com/backend-api/wham/usage` | `~/.codex/auth.json` (`$CODEX_HOME` and `chatgpt_base_url` are honored) |

- GlassUsage only reads these credentials. It never stores, refreshes or rewrites them.
- When the Claude access token has expired, GlassUsage runs `claude -p /usage` (at most once every 5 minutes) so that Claude Code renews its own token. That is a local command and makes no model request.
- Both endpoints are undocumented and may change. GlassUsage shows exactly the windows the provider reports and never estimates a limit.

## Token spend

Spend is read from local session logs in the same way as [ccusage](https://github.com/ryoppippi/ccusage):

| Tool | Logs | Notes |
| --- | --- | --- |
| Claude Code | `~/.claude/projects/**/*.jsonl`, `~/.config/claude/projects` (or `$CLAUDE_CONFIG_DIR`) | Deduplicated by message id + request id |
| Codex CLI | `$CODEX_HOME/sessions/**/rollout-*.jsonl`, `archived_sessions` | Cumulative `token_count` deltas; replayed history in forked sessions is skipped |
| omp | `~/.omp/agent/sessions/**/*.jsonl` | Uses the cost omp recorded; `anthropic` counts toward Claude, `openai`/`openai-codex` toward Codex |

- Only logs changed in the last 30 days are read, and each log is parsed incrementally from where the previous scan stopped.
- Parsed entries are cached in `~/Library/Application Support/GlassUsage/local-usage-cache.plist`.
- Costs are API-equivalent list prices from [LiteLLM's catalog](https://github.com/BerriAI/litellm/blob/main/model_prices_and_context_window.json). This is what the tokens would cost on the API, not what a subscription bills you. The catalog is refreshed daily, and a built-in table covers offline use.

## Network access

GlassUsage connects to:

- `api.anthropic.com`, for Claude limits
- `chatgpt.com`, for Codex limits
- `raw.githubusercontent.com`, for the LiteLLM price list
- `github.com`, for update checks (Sparkle appcast and downloads)

It has no analytics or telemetry.

## Files on disk

| Path | Contents |
| --- | --- |
| `~/Library/Application Support/GlassUsage/` | Parsed log cache and price list |
| `~/Library/Preferences/io.github.bubb4rd.GlassUsage.plist` | Settings and the last limit readings |
