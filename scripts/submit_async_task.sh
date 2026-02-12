#!/usr/bin/env bash
# Fire-and-forget submitter for Code-node.
# Starts Claude task in background and returns immediately with task_id/log path.
# Completion notification is sent by hooks/notify-agi.sh (via openclaw message send).

set -euo pipefail

usage(){
  cat <<'EOF'
Usage:
  submit_async_task.sh -p "<prompt>" [options]

Options:
  -p, --prompt TEXT        Task prompt (required)
  -n, --name NAME          Task name (default: async-<timestamp>)
  -w, --workdir DIR        Workdir (default: current dir)
  -c, --channel NAME       Notify channel (default: feishu)
  -t, --target ID          Notify target (required for proactive completion message)
      --agent-teams        Enable agent teams
      --teammate-mode MODE auto|in-process|tmux
      --permission-mode M  pass-through to claude
      --allowed-tools TXT  pass-through to claude
      --model MODEL        model override

Example:
  scripts/submit_async_task.sh \
    -p "分析仓库并生成方案" \
    -n "repo-plan" \
    -w /home/lab803/Workspace/BaiduPan \
    -c feishu -t ou_xxx \
    --agent-teams --teammate-mode auto --permission-mode bypassPermissions
EOF
}

PROMPT=""
TASK_NAME=""
WORKDIR="$(pwd)"
CHANNEL="feishu"
TARGET=""
AGENT_TEAMS=""
TEAMMATE_MODE=""
PERMISSION_MODE=""
ALLOWED_TOOLS=""
MODEL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--prompt) PROMPT="$2"; shift 2;;
    -n|--name) TASK_NAME="$2"; shift 2;;
    -w|--workdir) WORKDIR="$2"; shift 2;;
    -c|--channel) CHANNEL="$2"; shift 2;;
    -t|--target) TARGET="$2"; shift 2;;
    --agent-teams) AGENT_TEAMS="--agent-teams"; shift;;
    --teammate-mode) TEAMMATE_MODE="--teammate-mode $2"; shift 2;;
    --permission-mode) PERMISSION_MODE="--permission-mode $2"; shift 2;;
    --allowed-tools) ALLOWED_TOOLS="--allowed-tools $2"; shift 2;;
    --model) MODEL="--model $2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1" >&2; usage; exit 1;;
  esac
done

if [[ -z "$PROMPT" ]]; then
  echo "[ERROR] --prompt is required" >&2
  exit 1
fi

if [[ -z "$TASK_NAME" ]]; then
  TASK_NAME="async-$(date +%Y%m%d_%H%M%S)"
fi

if command -v uuidgen >/dev/null 2>&1; then
  TASK_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
else
  TASK_ID="$(date +%s)-$$"
fi

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="${HOME}/.openclaw/claude-code-results/submit-logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/${TASK_ID}.log"

CLAUDE_BIN="$(command -v claude || true)"
CMD="export CLAUDE_CODE_BIN=\"$CLAUDE_BIN\"; cd \"$REPO_DIR\" && scripts/dispatch-claude-code.sh -p \"$PROMPT\" -n \"$TASK_NAME\" -w \"$WORKDIR\" -c \"$CHANNEL\" -t \"$TARGET\" --task-id \"$TASK_ID\" $AGENT_TEAMS $TEAMMATE_MODE $PERMISSION_MODE $ALLOWED_TOOLS $MODEL"

nohup bash -lc "$CMD" >"$LOG_FILE" 2>&1 &
PID=$!

echo "SUBMITTED"
echo "TASK_ID=$TASK_ID"
echo "PID=$PID"
echo "LOG_FILE=$LOG_FILE"
echo "NOTE=Main agent can return immediately; completion will be pushed by hook if -t target is set."
