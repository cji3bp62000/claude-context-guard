#!/usr/bin/env bash
# Hook that prevents wasted tokens from prompt-cache expiry (macOS / Linux).
#
# Runs on UserPromptSubmit, before the prompt is sent; exits 2 to block and offers three choices.
#
# Input is JSON on stdin (transcript_path, session_id, prompt, ...).
# Thresholds can be overridden with environment variables (see README).
#
# Note: on Windows the bundled context-guard.ps1 takes over, so this exits immediately there.

set -u

# On Git Bash / MSYS / Cygwin (i.e. Windows), leave it to the PowerShell version.
case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*) exit 0 ;;
esac

# --- Thresholds (overridable via environment variables) ----------------------
STALE_CTX="${CONTEXT_GUARD_STALE_TOKENS:-80000}"
STALE_MIN="${CONTEXT_GUARD_STALE_MINUTES:-55}"
SNOOZE_MIN="${CONTEXT_GUARD_SNOOZE_MINUTES:-30}"

# For verification: always fire.
if [ "${CONTEXT_GUARD_TEST:-}" = "1" ]; then
  STALE_CTX=1; STALE_MIN=0; SNOOZE_MIN=1
fi

STATE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
STATE_PATH="$STATE_DIR/context-guard-state.tsv"

RAW="$(cat)"
[ -n "$RAW" ] || exit 0

HAS_JQ=0
command -v jq >/dev/null 2>&1 && HAS_JQ=1

json_str() { # $1=key -> value (exact via jq when available, crude extraction otherwise)
  if [ "$HAS_JQ" = "1" ]; then
    printf '%s' "$RAW" | jq -r --arg k "$1" '.[$k] // empty'
  else
    printf '%s' "$RAW" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1
  fi
}

TRANSCRIPT="$(json_str transcript_path)"
[ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || exit 0
SESSION="$(json_str session_id)"; [ -n "$SESSION" ] || SESSION="unknown"
PROMPT="$(json_str prompt)"

# Never block slash commands themselves (/compact, /clear, ...).
case "$PROMPT" in
  /*) exit 0 ;;
esac

# --- Read the current context size and last activity from the transcript -----
LINE="$(tail -n 60 "$TRANSCRIPT" 2>/dev/null | grep '"usage"' | tail -n 1)"
[ -n "$LINE" ] || exit 0

num_of() { # $1=field name
  printf '%s' "$LINE" | grep -o "\"$1\"[[:space:]]*:[[:space:]]*[0-9]\+" | head -n 1 | grep -o '[0-9]\+$'
}
READ_T="$(num_of cache_read_input_tokens)";      : "${READ_T:=0}"
WRITE_T="$(num_of cache_creation_input_tokens)"; : "${WRITE_T:=0}"
IN_T="$(num_of input_tokens)";                   : "${IN_T:=0}"
CTX=$(( READ_T + WRITE_T + IN_T ))
[ "$CTX" -gt 0 ] || exit 0

TS="$(printf '%s' "$LINE" | sed -n 's/.*"timestamp"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
NOW_SEC="$(date -u +%s)"
LAST_SEC=""
if [ -n "$TS" ]; then
  # GNU date first; fall back to BSD (macOS) date.
  LAST_SEC="$(date -u -d "$TS" +%s 2>/dev/null || true)"
  if [ -z "$LAST_SEC" ]; then
    TRIMMED="${TS%%.*}"; TRIMMED="${TRIMMED%Z}"
    LAST_SEC="$(date -u -j -f "%Y-%m-%dT%H:%M:%S" "$TRIMMED" +%s 2>/dev/null || true)"
  fi
fi
GAP_MIN=0
[ -n "$LAST_SEC" ] && GAP_MIN=$(( (NOW_SEC - LAST_SEC) / 60 ))

# --- Pass through unless the cache has expired on a non-trivial context ------
[ "$GAP_MIN" -ge "$STALE_MIN" ] && [ "$CTX" -ge "$STALE_CTX" ] || exit 0

# --- State file (key <TAB> epoch) --------------------------------------------
KEY="submit:$SESSION"
PREV_AT=""
if [ -f "$STATE_PATH" ]; then
  PREV_LINE="$(grep -F "$KEY	" "$STATE_PATH" 2>/dev/null | tail -n 1 || true)"
  [ -n "$PREV_LINE" ] && PREV_AT="$(printf '%s' "$PREV_LINE" | cut -f2)"
fi

# Already warned recently: treat the re-send as "continue anyway" and let it through.
if [ -n "$PREV_AT" ]; then
  SINCE=$(( (NOW_SEC - PREV_AT) / 60 ))
  [ "$SINCE" -lt "$SNOOZE_MIN" ] && exit 0
fi

# Record the warning; drop rows older than 7 days and write back.
mkdir -p "$STATE_DIR" 2>/dev/null || true
CUTOFF=$(( NOW_SEC - 7*24*60*60 ))
TMP="$STATE_PATH.tmp.$$"
if [ -f "$STATE_PATH" ]; then
  awk -F'\t' -v c="$CUTOFF" -v k="$KEY" '$1 != k && $2 > c' "$STATE_PATH" > "$TMP" 2>/dev/null || : > "$TMP"
else
  : > "$TMP"
fi
printf '%s\t%s\n' "$KEY" "$NOW_SEC" >> "$TMP"
mv "$TMP" "$STATE_PATH" 2>/dev/null || rm -f "$TMP"

CTX_FMT="$(printf '%s' "$CTX" | sed -e :a -e 's/\(.*[0-9]\)\([0-9]\{3\}\)/\1,\2/;ta')"

{
  printf '\n⚠ Context %s tokens / %s min since last activity\n' "$CTX_FMT" "$GAP_MIN"
  printf '  The prompt cache (1h TTL) has expired, so sending this will rewrite about %s tokens.\n\n' "$CTX_FMT"
  printf '  [1] /compact      Continuing this work (keeps the thread; pays off in 2-3 turns)\n'
  printf '  [2] /clear        Switching topics (free)\n'
  printf '  [3] Continue      Send the same text again (no warning for the next %s min)\n\n' "$SNOOZE_MIN"
} >&2
exit 2
