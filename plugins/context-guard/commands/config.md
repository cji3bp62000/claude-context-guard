---
description: Show or change context-guard thresholds
allowed-tools: Read, Edit, Write
---

Show or change the context-guard thresholds.

What the user asked for: $ARGUMENTS

## Steps

1. Read `~/.claude/settings.json` (on Windows, `%USERPROFILE%\.claude\settings.json`).
   If the `CLAUDE_CONFIG_DIR` environment variable is set, use that directory instead.
2. Read the `CONTEXT_GUARD_*` keys inside the `env` object and show the current values as a table.
   For anything not set, show the default and mark it as `(default)`.
3. If a change was requested, merge it into `env`. **Do not remove existing keys.**
   Values must be written as strings (e.g. `"60000"`).
4. After changing anything, tell the user that Claude Code must be restarted for it to take
   effect, because environment variables are read at process start.

Answer in the language the user wrote in.

## Thresholds

| Variable | Default | Meaning |
|---|---|---|
| `CONTEXT_GUARD_STALE_TOKENS` | 80000 | Floor for "cache expired and non-trivial" |
| `CONTEXT_GUARD_STALE_MINUTES` | 55 | A gap this long is treated as cache expiry |
| `CONTEXT_GUARD_SNOOZE_MINUTES` | 30 | Stay quiet this long after a warning |

Example of what to write:

```json
{
  "env": {
    "CONTEXT_GUARD_STALE_TOKENS": "60000"
  }
}
```
