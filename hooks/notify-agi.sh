#!/bin/bash
# Claude Code Hook: 任务完成后通知 AGI
# 兼容 PTY 和非 PTY 环境

set -uo pipefail

# 安全读取 stdin（兼容 PTY 环境）
INPUT=""
if [ -e /dev/stdin ] && [ -r /dev/stdin ]; then
    INPUT=$(cat /dev/stdin 2>/dev/null || true)
fi

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null || echo "unknown")
CWD=$(echo "$INPUT" | jq -r '.cwd // ""' 2>/dev/null || echo "")
EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // "unknown"' 2>/dev/null || echo "unknown")

# 读取 Claude Code 的输出
OUTPUT=""
if [ -f "/tmp/claude-code-output.txt" ] && [ -s "/tmp/claude-code-output.txt" ]; then
    OUTPUT=$(head -c 2000 /tmp/claude-code-output.txt)
fi

# 写入结果文件
RESULT_DIR="/home/ubuntu/clawd/data/claude-code-results"
mkdir -p "$RESULT_DIR"

jq -n \
    --arg sid "$SESSION_ID" \
    --arg ts "$(date -Iseconds)" \
    --arg cwd "$CWD" \
    --arg event "$EVENT" \
    --arg output "$OUTPUT" \
    '{session_id: $sid, timestamp: $ts, cwd: $cwd, event: $event, output: $output, status: "done"}' \
    > "${RESULT_DIR}/latest.json" 2>/dev/null

# 通知 AGI（wake event）
TOKEN="${OPENCLAW_GATEWAY_TOKEN:-}"
if [ -n "$TOKEN" ]; then
    SAFE_MSG=$(echo "$OUTPUT" | head -c 300 | tr '\n' ' ' | jq -Rs '.' 2>/dev/null || echo '""')
    curl -sf -X POST "http://127.0.0.1:18789/api/cron/wake" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"text\": \"[Claude Code 完成] 读取 /home/ubuntu/clawd/data/claude-code-results/latest.json 获取详细结果。摘要: $SAFE_MSG\", \"mode\": \"now\"}" \
        > /dev/null 2>&1 || true
fi

exit 0
