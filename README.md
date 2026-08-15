# context-guard

*English | [日本語](README_JP.md)*

Claude Code bills you for **context size**, not for how much work you ask for. Keep a long
session going without folding it and even a two-word tweak is re-billed for the entire
conversation, every turn.

This plugin steps in **before** that charge happens.

> **日本語**
> Claude Code のトークン消費は、作業量ではなく **コンテキストサイズ** にほぼ比例します。
> 長いセッションを畳まずに続けると、ほんの数語の微調整でも毎ターン全文脈ぶんが再課金されます。
> このプラグインは、その課金が発生する **前** に割り込んで止めます。
> 詳しい説明は [日本語版 README](README_JP.md) にあります。

## What actually happens (measured)

One real session, worked for three hours without folding, context grown to 275k tokens:

| Phase | API calls | Cache reads | Share of the 5h budget |
|---|---|---|---|
| Implementation | 104 | 14.1M | 28% |
| **Tweaking (32 min)** | **47** | **10.3M** | **20-32%** |

Forty-seven instructions along the lines of "make it a bit softer" and "use ease-out" burned
a fifth to a third of a five-hour window. Cache reads were 68% of that, cache writes 23%.
The writes ballooned because a two-hour break expired the prompt cache (1h TTL), and the first
message after coming back rewrote 207k tokens from scratch.

**The model cannot warn you about this itself.** By the time it reads your prompt, that
expensive read has already been billed. A `UserPromptSubmit` hook runs before the API call,
which is the only place this can be stopped.

## Behavior

**Before sending (`UserPromptSubmit`)** — the send is blocked when either condition holds.
Blocking costs nothing, because no API call is made.

- Context is above **80k tokens and 55+ minutes have passed** since the last exchange (cache expired)
- Context is above **250k tokens**

```
⚠ Context 243,000 tokens / 134 min since last activity
  The prompt cache (1h TTL) has expired, so sending this will rewrite about 243,000 tokens.

  [1] /compact      Continuing this work (keeps the thread; pays off in 2-3 turns)
  [2] /clear        Switching topics (free)
  [3] Continue      Send the same text again (no warning for the next 30 min)
```

The third choice is the important one. **Re-sending the same text is how you say "continue"**,
and it snoozes the warning for 30 minutes. Press ↑ to recover what you typed; if that fails,
type a slash command first — slash commands always pass through untouched.

**End of turn (`Stop`)** — never blocks. Prints a single line once the context passes 200k,
and only once per 50k bucket, so it does not nag.

### /compact vs /clear

| | Cost |
|---|---|
| Keep going | The full context (about 28k-equivalent at 275k) every single turn, forever |
| `/compact` | Roughly two turns, once; about 3k per turn afterwards |
| `/clear` | Zero, and about 3k per turn afterwards - but the context is gone |

- **`/compact`** — the work continues and you want the recent design decisions carried forward. Pays for itself within two or three turns.
- **`/clear`** — you are switching topics, or the next task is self-contained ("fix this line in this file").

**Folding before you step away is what helps most.** Fold after you come back and you have
already paid the rewrite.

## Install

```
/plugin marketplace add cji3bp62000/claude-context-guard
/plugin install context-guard
```

If nothing seems to happen, open `/hooks` once (this reloads the config) or restart Claude Code.

## Configuration

```
/context-guard:config                       show the current thresholds
/context-guard:config block at 180k         change one (rewrites settings.json)
```

Underneath it is just environment variables, so you can edit them by hand.
**Changes require a Claude Code restart**, because environment variables are read at process start.

```json
{
  "env": {
    "CONTEXT_GUARD_BLOCK_TOKENS": "200000",
    "CONTEXT_GUARD_STALE_MINUTES": "50"
  }
}
```

| Variable | Default | Meaning |
|---|---|---|
| `CONTEXT_GUARD_BLOCK_TOKENS` | 250000 | Block unconditionally above this |
| `CONTEXT_GUARD_STALE_TOKENS` | 80000 | Floor for "cache expired and non-trivial" |
| `CONTEXT_GUARD_STALE_MINUTES` | 55 | A gap this long is treated as cache expiry |
| `CONTEXT_GUARD_SNOOZE_MINUTES` | 30 | Stay quiet this long after a warning |
| `CONTEXT_GUARD_NOTIFY_TOKENS` | 200000 | Floor for the Stop notice |
| `CONTEXT_GUARD_NOTIFY_BUCKET` | 50000 | Notify once per bucket of this size |
| `CONTEXT_GUARD_TEST` | — | Set to `1` to drop every threshold to 1 so the hook always fires. For verification |

### Choosing `CONTEXT_GUARD_BLOCK_TOKENS`

**Of the two conditions, the cache-expiry one** (`STALE_TOKENS` + `STALE_MINUTES`) **is the one
that maps directly onto the measured damage.** The size condition is a backstop for context
that grew without you noticing, so its default is deliberately high.

Drop it to 150000 if you would rather fold often. Blocking itself is free, so the only question
is how much interruption you tolerate.

State lives in `~/.claude/context-guard-state.json` (Windows) or `context-guard-state.tsv`
(macOS / Linux) and is pruned after 7 days.

## Verifying it works

Force the hook to fire regardless of thresholds:

```
CONTEXT_GUARD_TEST=1 claude          # macOS / Linux
$env:CONTEXT_GUARD_TEST='1'; claude  # Windows
```

Send anything and it should be blocked. Unset the variable once you have confirmed it.

## Platform support

| OS | Script | Status |
|---|---|---|
| Windows | `scripts/context-guard.ps1` | Verified |
| macOS / Linux | `scripts/context-guard.sh` | Logic verified under Git Bash (block / snooze / slash pass-through / Stop notice all match the PowerShell version). **Not yet verified on real macOS or Linux** |

macOS has no GNU `date`, so it takes the BSD `date` fallback path. That path is the one branch
that has not run on real hardware.

Both scripts are registered for both events; each exits immediately and silently on the
platform it does not own.

- **On macOS / Linux without PowerShell (`pwsh`)**, the powershell hook entry fails to launch every turn. Nothing breaks, but if it bothers you, fork and delete the powershell entries from `hooks/hooks.json`.
- **On Windows without Git Bash**, the bash entry fails the same way. The PowerShell script is doing the real work, so you are still protected.
- The macOS / Linux script uses `jq` when available and falls back to crude string extraction otherwise.

## How it works

It reads the tail of the JSONL passed as `transcript_path`, takes the most recent `usage`
(`cache_read_input_tokens` + `cache_creation_input_tokens` + `input_tokens`) and its `timestamp`,
and derives the current context size and the time since the last activity.

If anything unexpected happens it always exits 0 and passes through, so a failure in the hook
can never stop your session.

## License

[Unlicense](LICENSE) — public domain. Use it, change it, redistribute it freely.
