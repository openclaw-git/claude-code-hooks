#!/usr/bin/env bash
# OpenClaw Claude Code hook (Stop / SessionEnd)
# - No hardcoded token
# - Per-task isolation for concurrency
# - Channel-agnostic notifications (feishu/telegram/...)

set -euo pipefail

log(){
  local ts; ts="$(date -Iseconds)"
  echo "[$ts] $*" >>"$HOOK_LOG"
}

safe_jq(){ jq -r "$1" "$2" 2>/dev/null || true; }

# -------- config (all override-able via env) --------
RESULT_ROOT="${OPENCLAW_HOOK_RESULT_ROOT:-$HOME/.openclaw/claude-code-results}"
OPENCLAW_BIN="${OPENCLAW_BIN:-$(command -v openclaw || true)}"
DEFAULT_CHANNEL="${OPENCLAW_NOTIFY_CHANNEL:-feishu}"
HOOK_LOG="${OPENCLAW_HOOK_LOG:-$RESULT_ROOT/hook.log}"
LOCK_WINDOW_SECONDS="${OPENCLAW_HOOK_LOCK_WINDOW_SECONDS:-30}"
MAX_SUMMARY_CHARS="${OPENCLAW_HOOK_MAX_SUMMARY_CHARS:-1200}"

mkdir -p "$RESULT_ROOT"

# stdin from Claude hook event payload
INPUT=""
if [ ! -t 0 ]; then
  INPUT="$(timeout 2 cat /dev/stdin 2>/dev/null || true)"
fi

EVENT_NAME="$(echo "$INPUT" | jq -r '.hook_event_name // "unknown"' 2>/dev/null || echo "unknown")"
SESSION_ID="$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null || echo "unknown")"
EVENT_CWD="$(echo "$INPUT" | jq -r '.cwd // ""' 2>/dev/null || echo "")"

TASK_ID="${OPENCLAW_HOOK_TASK_ID:-}"
if [ -z "$TASK_ID" ]; then
  # fallback from stdin payload if caller injected it
  TASK_ID="$(echo "$INPUT" | jq -r '.task_id // empty' 2>/dev/null || true)"
fi
if [ -z "$TASK_ID" ]; then
  TASK_ID="unknown-$(date +%s)"
fi

TASK_DIR="$RESULT_ROOT/tasks/$TASK_ID"
mkdir -p "$TASK_DIR"
META_FILE="$TASK_DIR/meta.json"
OUTPUT_FILE="$TASK_DIR/output.log"
RESULT_FILE="$TASK_DIR/result.json"
WAKE_FILE="$TASK_DIR/pending-wake.json"
LOCK_FILE="$TASK_DIR/.hook-lock"

log "hook fired event=$EVENT_NAME session=$SESSION_ID task_id=$TASK_ID"

# per-task de-dup lock (Stop + SessionEnd double fire)
if [ -f "$LOCK_FILE" ]; then
  now="$(date +%s)"
  last="$(stat -c %Y "$LOCK_FILE" 2>/dev/null || echo 0)"
  age=$(( now - last ))
  if [ "$age" -lt "$LOCK_WINDOW_SECONDS" ]; then
    log "skip duplicate event within ${age}s task_id=$TASK_ID"
    exit 0
  fi
fi
touch "$LOCK_FILE"

TASK_NAME="unknown-task"
CHANNEL="$DEFAULT_CHANNEL"
TARGET=""
CALLBACK_SESSION=""
WORKDIR="$EVENT_CWD"
if [ -f "$META_FILE" ]; then
  TASK_NAME="$(safe_jq '.task_name // "unknown-task"' "$META_FILE")"
  CHANNEL="$(safe_jq '.notify.channel // empty' "$META_FILE")"
  TARGET="$(safe_jq '.notify.target // empty' "$META_FILE")"
  CALLBACK_SESSION="$(safe_jq '.callback_session // empty' "$META_FILE")"
  META_WORKDIR="$(safe_jq '.workdir // empty' "$META_FILE")"
  [ -n "$META_WORKDIR" ] && WORKDIR="$META_WORKDIR"
fi
[ -z "$CHANNEL" ] && CHANNEL="$DEFAULT_CHANNEL"

# collect output summary
OUTPUT=""
if [ -s "$OUTPUT_FILE" ]; then
  OUTPUT="$(tail -c 8000 "$OUTPUT_FILE")"
fi
if [ -z "$OUTPUT" ] && [ -f /tmp/claude-code-output.txt ] && [ -s /tmp/claude-code-output.txt ]; then
  OUTPUT="$(tail -c 4000 /tmp/claude-code-output.txt)"
fi
if [ -z "$OUTPUT" ] && [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ]; then
  files="$(ls -1t "$WORKDIR" 2>/dev/null | head -20 | tr '\n' ',' || true)"
  OUTPUT="Working dir: $WORKDIR | files: $files"
fi

SUMMARY="$(echo "$OUTPUT" | tr '\n' ' ' | cut -c1-"$MAX_SUMMARY_CHARS")"

jq -n \
  --arg task_id "$TASK_ID" \
  --arg session_id "$SESSION_ID" \
  --arg event "$EVENT_NAME" \
  --arg task_name "$TASK_NAME" \
  --arg channel "$CHANNEL" \
  --arg target "$TARGET" \
  --arg callback_session "$CALLBACK_SESSION" \
  --arg cwd "$WORKDIR" \
  --arg output "$OUTPUT" \
  --arg summary "$SUMMARY" \
  --arg timestamp "$(date -Iseconds)" \
  '{task_id:$task_id,timestamp:$timestamp,session_id:$session_id,event:$event,task_name:$task_name,cwd:$cwd,notify:{channel:$channel,target:$target},callback_session:$callback_session,summary:$summary,output:$output,status:"done"}' \
  > "$RESULT_FILE"

jq -n \
  --arg task_id "$TASK_ID" \
  --arg task_name "$TASK_NAME" \
  --arg summary "$SUMMARY" \
  --arg timestamp "$(date -Iseconds)" \
  '{task_id:$task_id,task_name:$task_name,summary:$summary,timestamp:$timestamp,processed:false}' \
  > "$WAKE_FILE"

# proactive message via OpenClaw if target configured
if [ -n "$OPENCLAW_BIN" ] && [ -x "$OPENCLAW_BIN" ] && [ -n "$TARGET" ]; then
  MSG="🤖 Claude Code任务完成\n任务: $TASK_NAME\nTaskID: $TASK_ID\n摘要: $SUMMARY"
  if "$OPENCLAW_BIN" message send --channel "$CHANNEL" --target "$TARGET" --message "$MSG" >/dev/null 2>&1; then
    log "message sent channel=$CHANNEL target=$TARGET task_id=$TASK_ID"
  else
    log "message send failed channel=$CHANNEL target=$TARGET task_id=$TASK_ID"
  fi
else
  log "skip proactive message (no target or openclaw bin) task_id=$TASK_ID"
fi

log "hook done task_id=$TASK_ID result=$RESULT_FILE"
exit 0
