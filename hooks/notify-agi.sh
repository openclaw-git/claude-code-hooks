#!/usr/bin/env bash
# OpenClaw Claude Code Hook (Stop / SessionEnd) - 适配版
#
# 功能:
# - 任务完成后自动触发
# - 通过 OpenClaw 发送 Feishu/Telegram 通知
# - 写入结果 JSON 和 pending-wake 文件
# - Per-task 隔离，支持并发
#
# 环境变量配置（可选覆盖）:
#   OPENCLAW_HOOK_RESULT_ROOT      - 结果目录（默认: ~/.openclaw/claude-code-results）
#   OPENCLAW_BIN                  - openclaw 二进制路径
#   OPENCLAW_NOTIFY_CHANNEL       - 默认通知渠道（默认: feishu）
#   OPENCLAW_NOTIFY_ACCOUNT_ID    - 账户 ID（默认: main）
#   OPENCLAW_HOOK_TASK_ID        - 任务 ID（由 dispatch 脚本设置）
#   OPENCLAW_HOOK_LOG            - 日志文件路径
#   OPENCLAW_HOOK_LOCK_WINDOW_SECONDS     - 去重锁时间窗口（默认: 30）
#   OPENCLAW_HOOK_MAX_SUMMARY_CHARS      - 摘要最大字符数（默认: 1500）
#   OPENCLAW_CALLBACK_TIMEOUT_SECONDS     - 回调超时秒数（默认: 60）
#   OPENCLAW_HOOK_OUTPUT_LINES   - 输出文件截取行数（默认: 300）
#   OPENCLAW_HOOK_ERROR_LINES    - 错误日志截取行数（默认: 30）
#   OPENCLAW_HOOK_ERROR_CHARS    - 错误日志字符限制（默认: 400）
#   TMPDIR                       - 临时文件目录

set -euo pipefail

# -------- 日志函数 --------
log() {
    local ts; ts="$(date -Iseconds)"
    echo "[$ts] $*" >>"$HOOK_LOG"
}

safe_jq() {
    jq -r "$1" "$2" 2>/dev/null || true
}

# -------- 环境补全 --------
# Hook 进程可能缺少完整 PATH，需要手动补充

# 自动检测并添加 openclaw 到 PATH
detect_and_add_openclaw_path() {
    # 如果 OPENCLAW_BIN 已设置，添加其目录
    if [ -n "${OPENCLAW_BIN:-}" ]; then
        local bin_dir="$(dirname "$OPENCLAW_BIN")"
        export PATH="${bin_dir}:${PATH}"
        return 0
    fi

    # 1. 检查命令路径
    if command -v openclaw >/dev/null 2>&1; then
        local cmd_path="$(command -v openclaw)"
        local bin_dir="$(dirname "$cmd_path")"
        export PATH="${bin_dir}:${PATH}"
        return 0
    fi

    # 2. 检查 nvm 路径（支持多个 Node 版本）
    local nvm_dir="${NVM_DIR:-$HOME/.nvm}"
    if [ -d "$nvm_dir" ]; then
        for version_dir in "$nvm_dir"/versions/node/v*.*.*; do
            if [ -d "$version_dir" ]; then
                local bin_path="$version_dir/bin/openclaw"
                if [ -x "$bin_path" ]; then
                    export PATH="${version_dir}/bin:${PATH}"
                    return 0
                fi
            fi
        done
    fi

    # 3. 检查 npm 全局路径
    if [ -x "$HOME/.npm-global/bin/openclaw" ]; then
        export PATH="$HOME/.npm-global/bin:${PATH}"
        return 0
    fi

    return 1
}

detect_and_add_openclaw_path || true

# Source 用户环境（可选）
[ -f "$HOME/.claude/env" ] && source "$HOME/.claude/env" 2>/dev/null || true
[ -f "$HOME/.bashrc" ] && source "$HOME/.bashrc" 2>/dev/null || true

# -------- 配置（支持环境变量覆盖）--------
RESULT_ROOT="${OPENCLAW_HOOK_RESULT_ROOT:-$HOME/.openclaw/claude-code-results}"
TMP_DIR="${TMPDIR:-/tmp}"

# 重新检测 openclaw（在 PATH 补充后）
if [ -z "${OPENCLAW_BIN:-}" ]; then
    OPENCLAW_BIN="$(command -v openclaw || true)"
fi

DEFAULT_CHANNEL="${OPENCLAW_NOTIFY_CHANNEL:-feishu}"
NOTIFY_ACCOUNT_ID="${OPENCLAW_NOTIFY_ACCOUNT_ID:-main}"
HOOK_LOG="${OPENCLAW_HOOK_LOG:-$RESULT_ROOT/hook.log}"
LOCK_WINDOW_SECONDS="${OPENCLAW_HOOK_LOCK_WINDOW_SECONDS:-30}"
MAX_SUMMARY_CHARS="${OPENCLAW_HOOK_MAX_SUMMARY_CHARS:-1500}"
CALLBACK_TIMEOUT_SECONDS="${OPENCLAW_CALLBACK_TIMEOUT_SECONDS:-60}"
OUTPUT_LINES="${OPENCLAW_HOOK_OUTPUT_LINES:-300}"
ERROR_LOG_LINES="${OPENCLAW_HOOK_ERROR_LINES:-30}"
ERROR_LOG_CHARS="${OPENCLAW_HOOK_ERROR_CHARS:-400}"
STDIN_READ_TIMEOUT="${OPENCLAW_HOOK_STDIN_TIMEOUT:-2}"

mkdir -p "$RESULT_ROOT"

# -------- 读取 Hook 事件输入 --------
INPUT=""
if [ ! -t 0 ]; then
    INPUT="$(timeout "$STDIN_READ_TIMEOUT" cat /dev/stdin 2>/dev/null || true)"
fi

EVENT_NAME="$(echo "$INPUT" | jq -r '.hook_event_name // "unknown"' 2>/dev/null || echo "unknown")"
SESSION_ID="$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null || echo "unknown")"
EVENT_CWD="$(echo "$INPUT" | jq -r '.cwd // ""' 2>/dev/null || echo "")"

# -------- 确定 Task ID --------
TASK_ID="${OPENCLAW_HOOK_TASK_ID:-}"
if [ -z "$TASK_ID" ]; then
    # 尝试从 stdin payload 读取
    TASK_ID="$(echo "$INPUT" | jq -r '.task_id // empty' 2>/dev/null || true)"
fi
if [ -z "$TASK_ID" ]; then
    TASK_ID="unknown-$(date +%s)-$$"
fi

# -------- 任务目录结构 --------
TASK_DIR="$RESULT_ROOT/tasks/$TASK_ID"
mkdir -p "$TASK_DIR"

META_FILE="$TASK_DIR/meta.json"
OUTPUT_FILE="$TASK_DIR/output.log"
RESULT_FILE="$TASK_DIR/result.json"
WAKE_FILE="$TASK_DIR/pending-wake.json"
LOCK_FILE="$TASK_DIR/.hook-lock"
RUN_LOCK_FILE="$TASK_DIR/.hook-run.lock"

log "hook fired event=$EVENT_NAME session=$SESSION_ID task_id=$TASK_ID"

# -------- 原子运行锁（防止并发 hook 写同一文件）--------
exec 9>"$RUN_LOCK_FILE"
if ! flock -n 9; then
    log "skip concurrent hook run task_id=$TASK_ID"
    exit 0
fi

# -------- 去重锁（Stop + SessionEnd 双触发）--------
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

# -------- 读取任务元数据 --------
TASK_NAME="${OPENCLAW_HOOK_DEFAULT_TASK_NAME:-unknown-task}"
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

# -------- 收集输出摘要 --------
OUTPUT=""
if [ -s "$OUTPUT_FILE" ]; then
    OUTPUT="$(tail -n "$OUTPUT_LINES" "$OUTPUT_FILE")"
fi

# Fallback 1: prefer project log when Claude stdout is empty
if [ -z "$OUTPUT" ] && [ -n "$WORKDIR" ] && [ -f "$WORKDIR/PROJECT_LOG.md" ]; then
    OUTPUT="$(tail -n 120 "$WORKDIR/PROJECT_LOG.md")"
    log "fallback output from PROJECT_LOG.md task_id=$TASK_ID"
fi

# Fallback 2: latest markdown files in project root
if [ -z "$OUTPUT" ] && [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ]; then
    LAST_MD="$(find "$WORKDIR" -maxdepth 1 -type f -name '*.md' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2- || true)"
    if [ -n "$LAST_MD" ] && [ -f "$LAST_MD" ]; then
        OUTPUT="$(tail -n 80 "$LAST_MD")"
        log "fallback output from latest md file: $LAST_MD task_id=$TASK_ID"
    fi
fi

# Fallback 3: directory listing summary
if [ -z "$OUTPUT" ] && [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ]; then
    files="$(ls -1t "$WORKDIR" 2>/dev/null | head -20 | tr '\n' ',' || true)"
    OUTPUT="Working dir: $WORKDIR | files: $files"
fi

SUMMARY="$(echo "$OUTPUT" | tr '\n' ' ' | cut -c1-"$MAX_SUMMARY_CHARS")"

# -------- 构建结果 JSON --------
# Build callback requested flag separately
CB_REQUESTED="false"
if [ -n "$CALLBACK_SESSION" ]; then
    CB_REQUESTED="true"
fi

META_STATUS="running"
META_EXIT_CODE=""
META_MISSING_FILES="[]"
if [ -f "$META_FILE" ]; then
    META_STATUS="$(safe_jq '.status // "running"' "$META_FILE")"
    META_EXIT_CODE="$(safe_jq '.exit_code // empty' "$META_FILE")"
    META_MISSING_FILES="$(jq -c '.missing_files // []' "$META_FILE" 2>/dev/null || echo '[]')"
fi

FINAL_STATUS="$META_STATUS"
if [ -z "$FINAL_STATUS" ] || [ "$FINAL_STATUS" = "running" ]; then
    FINAL_STATUS="done"
fi

ARTIFACTS_VERIFIED="true"
if [ "$META_MISSING_FILES" != "[]" ]; then
    ARTIFACTS_VERIFIED="false"
fi

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
    --arg cb_requested "$CB_REQUESTED" \
    --arg status "$FINAL_STATUS" \
    --arg exit_code "$META_EXIT_CODE" \
    --argjson missing_files "$META_MISSING_FILES" \
    --arg artifacts_verified "$ARTIFACTS_VERIFIED" \
    '{task_id:$task_id,timestamp:$timestamp,session_id:$session_id,event:$event,task_name:$task_name,cwd:$cwd,notify:{channel:$channel,target:$target},callback_session:$callback_session,summary:$summary,output:$output,status:$status,exit_code:(if $exit_code=="" then null else ($exit_code|tonumber) end),artifacts_verified:($artifacts_verified=="true"),missing_files:$missing_files,callback:{requested:$cb_requested},notification:{sent:false}}' \
    > "$RESULT_FILE"

# -------- 写入 pending-wake.json（供外部系统读取）--------
jq -n \
    --arg task_id "$TASK_ID" \
    --arg task_name "$TASK_NAME" \
    --arg summary "$SUMMARY" \
    --arg timestamp "$(date -Iseconds)" \
    '{task_id:$task_id,task_name:$task_name,summary:$summary,timestamp:$timestamp,processed:false}' \
    > "$WAKE_FILE"

# -------- 通知回调（内部 session）--------
if [ -n "$CALLBACK_SESSION" ] && [ -n "$OPENCLAW_BIN" ] && [ -x "$OPENCLAW_BIN" ]; then
    CB_MSG="[Claude异步任务完成]\n任务: $TASK_NAME\nTaskID: $TASK_ID\n摘要: $SUMMARY"

    # 如果配置了外部通知目标，跳过内部 callback（避免重复）
    if [ -n "$TARGET" ]; then
        log "skip callback (target notification mode) task_id=$TASK_ID"
        jq '.callback.skipped=true | .callback.reason="external_target_configured"' "$RESULT_FILE" >"${RESULT_FILE}.tmp" && mv "${RESULT_FILE}.tmp" "$RESULT_FILE"
    else
        CB_LOG_FILE="${TMP_DIR}/openclaw-callback-${TASK_ID}.log"
        if timeout "$CALLBACK_TIMEOUT_SECONDS" "$OPENCLAW_BIN" system event --mode now --text "$CB_MSG" >"$CB_LOG_FILE" 2>&1; then
            log "callback sent via system-event session=$CALLBACK_SESSION task_id=$TASK_ID"
            jq '.callback.sent=true | .callback.method="system_event"' "$RESULT_FILE" >"${RESULT_FILE}.tmp" && mv "${RESULT_FILE}.tmp" "$RESULT_FILE"
        else
            CB_RC=$?
            CB_ERR="callback failed (rc=$CB_RC)"
            [ "$CB_RC" = "124" ] && CB_ERR="callback timeout after ${CALLBACK_TIMEOUT_SECONDS}s"
            log "callback failed session=$CALLBACK_SESSION task_id=$TASK_ID err=$CB_ERR"
            jq --arg err "$CB_ERR" '.callback.sent=false | .callback.error=$err' "$RESULT_FILE" >"${RESULT_FILE}.tmp" && mv "${RESULT_FILE}.tmp" "$RESULT_FILE"
        fi
    fi
else
    log "skip callback (missing session or openclaw) task_id=$TASK_ID"
fi

# -------- OpenClaw 主动通知（Feishu/Telegram）--------
if [ -n "$OPENCLAW_BIN" ] && [ -x "$OPENCLAW_BIN" ] && [ -n "$TARGET" ]; then
    # 根据渠道格式化消息
    case "$CHANNEL" in
        feishu)
            # Feishu 使用纯文本格式（支持 Markdown）
            MSG="**Claude Code 任务完成**\n\n任务: ${TASK_NAME}\nTaskID: ${TASK_ID}\n\n摘要:\n${SUMMARY}"
            ;;
        telegram)
            # Telegram 支持 Markdown V2
            MSG="*Claude Code 任务完成*\n\n任务: ${TASK_NAME}\nTaskID: ${TASK_ID}\n\n摘要:\n\`\`\`\n${SUMMARY}\n\`\`\`"
            ;;
        *)
            # 通用格式
            MSG="Claude Code 任务完成\n任务: ${TASK_NAME}\nTaskID: ${TASK_ID}\n摘要: ${SUMMARY}"
            ;;
    esac

    NOTIFY_LOG_FILE="${TMP_DIR}/openclaw-notify-${TASK_ID}.log"
    if "$OPENCLAW_BIN" message send --channel "$CHANNEL" --account "$NOTIFY_ACCOUNT_ID" --target "$TARGET" --message "$MSG" >"$NOTIFY_LOG_FILE" 2>&1; then
        log "message sent channel=$CHANNEL target=$TARGET task_id=$TASK_ID"
        jq '.notification.sent=true | .notification.channel=$CHANNEL | .notification.target=$TARGET' "$RESULT_FILE" >"${RESULT_FILE}.tmp" && mv "${RESULT_FILE}.tmp" "$RESULT_FILE"
    else
        NOTIFY_ERR="$(tail -n "$ERROR_LOG_LINES" "$NOTIFY_LOG_FILE" 2>/dev/null | tr '\n' ' ' | cut -c1-"$ERROR_LOG_CHARS")"
        [ -z "$NOTIFY_ERR" ] && NOTIFY_ERR="message send failed (no stderr captured)"
        log "message send failed channel=$CHANNEL target=$TARGET task_id=$TASK_ID err=$NOTIFY_ERR"
        jq --arg err "$NOTIFY_ERR" '.notification.sent=false | .notification.error=$err' "$RESULT_FILE" >"${RESULT_FILE}.tmp" && mv "${RESULT_FILE}.tmp" "$RESULT_FILE"

        # 兜底：尝试系统事件通知
        FALLBACK_MSG="🤖 Claude Code任务完成\n任务: ${TASK_NAME}\nTaskID: ${TASK_ID}\n摘要: ${SUMMARY}"
        FALLBACK_LOG_FILE="${TMP_DIR}/openclaw-notify-fallback-${TASK_ID}.log"
        if timeout "$CALLBACK_TIMEOUT_SECONDS" "$OPENCLAW_BIN" system event --mode now --text "$FALLBACK_MSG" >"$FALLBACK_LOG_FILE" 2>&1; then
            log "message fallback via system-event task_id=$TASK_ID"
            jq '.notification.fallback=true | .notification.method="system_event"' "$RESULT_FILE" >"${RESULT_FILE}.tmp" && mv "${RESULT_FILE}.tmp" "$RESULT_FILE"
        fi
    fi
else
    log "skip proactive message (no target or openclaw) task_id=$TASK_ID"

    if [ -z "$OPENCLAW_BIN" ] || [ ! -x "$OPENCLAW_BIN" ]; then
        jq '.notification.skipped=true | .notification.reason="openclaw_not_found"' "$RESULT_FILE" >"${RESULT_FILE}.tmp" && mv "${RESULT_FILE}.tmp" "$RESULT_FILE"
    elif [ -z "$TARGET" ]; then
        # 无显式 target 时，兜底发送 system event，避免“任务已完成但看起来没结束”
        FALLBACK_MSG="🤖 Claude Code任务完成（默认回调）\n任务: ${TASK_NAME}\nTaskID: ${TASK_ID}\n摘要: ${SUMMARY}"
        FALLBACK_LOG_FILE="${TMP_DIR}/openclaw-notify-no-target-${TASK_ID}.log"
        if timeout "$CALLBACK_TIMEOUT_SECONDS" "$OPENCLAW_BIN" system event --mode now --text "$FALLBACK_MSG" >"$FALLBACK_LOG_FILE" 2>&1; then
            log "message fallback via system-event (no target) task_id=$TASK_ID"
            jq '.notification.sent=true | .notification.fallback=true | .notification.method="system_event_default" | .notification.reason="no_target_configured"' "$RESULT_FILE" >"${RESULT_FILE}.tmp" && mv "${RESULT_FILE}.tmp" "$RESULT_FILE"
        else
            FALLBACK_ERR="$(tail -n "$ERROR_LOG_LINES" "$FALLBACK_LOG_FILE" 2>/dev/null | tr '\n' ' ' | cut -c1-"$ERROR_LOG_CHARS")"
            [ -z "$FALLBACK_ERR" ] && FALLBACK_ERR="system-event fallback failed (no stderr captured)"
            log "message fallback failed (no target) task_id=$TASK_ID err=$FALLBACK_ERR"
            jq --arg err "$FALLBACK_ERR" '.notification.sent=false | .notification.skipped=true | .notification.reason="no_target_configured" | .notification.error=$err' "$RESULT_FILE" >"${RESULT_FILE}.tmp" && mv "${RESULT_FILE}.tmp" "$RESULT_FILE"
        fi
    fi
fi

log "hook done task_id=$TASK_ID result=$RESULT_FILE"
exit 0
