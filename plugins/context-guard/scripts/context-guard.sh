#!/usr/bin/env bash
# コンテキスト肥大とプロンプトキャッシュ失効による無駄なトークン消費を防ぐフック（macOS / Linux 版）。
#
#   --mode submit (UserPromptSubmit): 送信前に走り、条件を満たすと exit 2 でブロックして3択を出す。
#   --mode stop   (Stop):             ターン終了時に走り、ブロックせず1行だけ通知する。
#
# 入力は stdin の JSON（transcript_path, session_id, prompt など）。
# しきい値は環境変数で上書きできる（README 参照）。
#
# 注意: Windows は同梱の context-guard.ps1 が担当するため、ここでは即座に抜ける。

set -u

MODE="submit"
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="${2:-submit}"; shift 2 ;;
    *) shift ;;
  esac
done

# Git Bash / MSYS / Cygwin 上（＝Windows）では PowerShell 版に任せる
case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*) exit 0 ;;
esac

# --- しきい値（環境変数で上書き可） ------------------------------------------
BLOCK_CTX="${CONTEXT_GUARD_BLOCK_TOKENS:-150000}"
STALE_CTX="${CONTEXT_GUARD_STALE_TOKENS:-80000}"
STALE_MIN="${CONTEXT_GUARD_STALE_MINUTES:-55}"
SNOOZE_MIN="${CONTEXT_GUARD_SNOOZE_MINUTES:-30}"
NOTIFY_CTX="${CONTEXT_GUARD_NOTIFY_TOKENS:-200000}"
NOTIFY_BUCKET="${CONTEXT_GUARD_NOTIFY_BUCKET:-50000}"

# 動作確認用: 必ず発火させる
if [ "${CONTEXT_GUARD_TEST:-}" = "1" ]; then
  BLOCK_CTX=1; STALE_CTX=1; STALE_MIN=0; SNOOZE_MIN=1; NOTIFY_CTX=1; NOTIFY_BUCKET=1
fi

STATE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
STATE_PATH="$STATE_DIR/context-guard-state.tsv"

RAW="$(cat)"
[ -n "$RAW" ] || exit 0

HAS_JQ=0
command -v jq >/dev/null 2>&1 && HAS_JQ=1

json_str() { # $1=key  -> 値（jq があれば正確に、無ければ簡易抽出）
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

# スラッシュコマンド自体（/compact, /clear など）は止めない
case "$MODE:$PROMPT" in
  submit:/*) exit 0 ;;
esac

# --- transcript から最新の文脈サイズと最終活動時刻を拾う ---------------------
LINE="$(tail -n 60 "$TRANSCRIPT" 2>/dev/null | grep '"usage"' | tail -n 1)"
[ -n "$LINE" ] || exit 0

num_of() { # $1=フィールド名
  printf '%s' "$LINE" | grep -o "\"$1\"[[:space:]]*:[[:space:]]*[0-9]\+" | head -n 1 | grep -o '[0-9]\+$'
}
READ_T="$(num_of cache_read_input_tokens)";     : "${READ_T:=0}"
WRITE_T="$(num_of cache_creation_input_tokens)"; : "${WRITE_T:=0}"
IN_T="$(num_of input_tokens)";                   : "${IN_T:=0}"
CTX=$(( READ_T + WRITE_T + IN_T ))
[ "$CTX" -gt 0 ] || exit 0

TS="$(printf '%s' "$LINE" | sed -n 's/.*"timestamp"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
NOW_SEC="$(date -u +%s)"
LAST_SEC=""
if [ -n "$TS" ]; then
  # GNU date → 失敗したら BSD(macOS) date を試す
  LAST_SEC="$(date -u -d "$TS" +%s 2>/dev/null || true)"
  if [ -z "$LAST_SEC" ]; then
    TRIMMED="${TS%%.*}"; TRIMMED="${TRIMMED%Z}"
    LAST_SEC="$(date -u -j -f "%Y-%m-%dT%H:%M:%S" "$TRIMMED" +%s 2>/dev/null || true)"
  fi
fi
GAP_MIN=0
[ -n "$LAST_SEC" ] && GAP_MIN=$(( (NOW_SEC - LAST_SEC) / 60 ))

# --- 状態ファイル（key <TAB> epoch <TAB> bucket） ----------------------------
KEY="$MODE:$SESSION"
PREV_AT=""; PREV_BUCKET=-1
if [ -f "$STATE_PATH" ]; then
  PREV_LINE="$(grep -F "$KEY	" "$STATE_PATH" 2>/dev/null | tail -n 1 || true)"
  if [ -n "$PREV_LINE" ]; then
    PREV_AT="$(printf '%s' "$PREV_LINE" | cut -f2)"
    PREV_BUCKET="$(printf '%s' "$PREV_LINE" | cut -f3)"
  fi
fi

save_state() { # $1=bucket  古い行(7日超)を落として書き戻す
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  CUTOFF=$(( NOW_SEC - 7*24*60*60 ))
  TMP="$STATE_PATH.tmp.$$"
  if [ -f "$STATE_PATH" ]; then
    awk -F'\t' -v c="$CUTOFF" -v k="$KEY" '$1 != k && $2 > c' "$STATE_PATH" > "$TMP" 2>/dev/null || : > "$TMP"
  else
    : > "$TMP"
  fi
  printf '%s\t%s\t%s\n' "$KEY" "$NOW_SEC" "$1" >> "$TMP"
  mv "$TMP" "$STATE_PATH" 2>/dev/null || rm -f "$TMP"
}

CTX_FMT="$(printf '%s' "$CTX" | sed -e :a -e 's/\(.*[0-9]\)\([0-9]\{3\}\)/\1,\2/;ta')"

if [ "$MODE" = "stop" ]; then
  [ "$CTX" -ge "$NOTIFY_CTX" ] || exit 0
  BUCKET=$(( CTX / NOTIFY_BUCKET ))
  [ "$PREV_BUCKET" = "" ] && PREV_BUCKET=-1
  [ "$BUCKET" -gt "$PREV_BUCKET" ] || exit 0
  save_state "$BUCKET"
  printf '{"systemMessage":"コンテキストが %s トークンです。次の話題に移るなら /clear、続きなら /compact を検討してください（1ターンあたりこの全量が再課金されます）"}\n' "$CTX_FMT"
  exit 0
fi

# --- 送信前 ------------------------------------------------------------------
STALE=0
[ "$GAP_MIN" -ge "$STALE_MIN" ] && [ "$CTX" -ge "$STALE_CTX" ] && STALE=1
TOO_BIG=0
[ "$CTX" -ge "$BLOCK_CTX" ] && TOO_BIG=1
[ "$STALE" = "1" ] || [ "$TOO_BIG" = "1" ] || exit 0

# 直近で警告済みなら「そのまま続ける」の意思表示とみなして通す
if [ -n "$PREV_AT" ]; then
  SINCE=$(( (NOW_SEC - PREV_AT) / 60 ))
  [ "$SINCE" -lt "$SNOOZE_MIN" ] && exit 0
fi
save_state 0

if [ "$STALE" = "1" ]; then
  HEAD="コンテキスト $CTX_FMT トークン / 前回のやり取りから ${GAP_MIN}分経過
  プロンプトキャッシュ(TTL 1時間)が失効しているため、このまま送ると約 $CTX_FMT トークンの書き直しが発生します。"
else
  HEAD="コンテキスト $CTX_FMT トークン
  このまま続けると、小さな修正でも毎ターン $CTX_FMT トークンぶんが再課金されます。"
fi

{
  printf '\n⚠ %s\n\n' "$HEAD"
  printf '  [1] /compact          作業の続きなら（経緯を引き継ぐ。2〜3ターンで元が取れる）\n'
  printf '  [2] /clear            話題が変わるなら（コスト0）\n'
  printf '  [3] そのまま続ける     同じ内容をもう一度送信（以後%s分は警告しません）\n' "$SNOOZE_MIN"
  printf '\n  ↑キーで入力内容を復元できます。復元できないとき用に以下に控えます:\n'
  printf '  ---\n'
  printf '%s\n' "$PROMPT" | sed 's/^/  /'
  printf '  ---\n\n'
} >&2
exit 2
