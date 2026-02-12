#!/usr/bin/env bash
# One-click deploy / rollback for Code-node.
# Usage:
#   scripts/deploy_code_node.sh deploy
#   scripts/deploy_code_node.sh rollback [--backup <dir>]
#   scripts/deploy_code_node.sh status

set -euo pipefail

ACTION="${1:-}"
shift || true

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLAUDE_DIR="${HOME}/.claude"
CLAUDE_SETTINGS="${CLAUDE_DIR}/settings.json"
BACKUP_ROOT="${HOME}/.openclaw/claude-hook-deploy-backups"
RESULT_ROOT_DEFAULT="${HOME}/.openclaw/claude-code-results"
HOOK_CMD="${REPO_DIR}/hooks/notify-agi.sh"
BACKUP_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup)
      BACKUP_DIR="$2"; shift 2;;
    *)
      echo "Unknown arg: $1" >&2; exit 1;;
  esac
done

need_bin(){
  command -v "$1" >/dev/null 2>&1 || {
    echo "[ERROR] missing required command: $1" >&2
    exit 1
  }
}

check_prereqs(){
  need_bin jq
  need_bin python3
  need_bin openclaw
  need_bin claude
}

ensure_dirs(){
  mkdir -p "$CLAUDE_DIR" "$BACKUP_ROOT"
}

mk_backup(){
  local ts
  ts="$(date +%Y%m%d_%H%M%S)"
  BACKUP_DIR="${BACKUP_ROOT}/${ts}"
  mkdir -p "$BACKUP_DIR"

  if [ -f "$CLAUDE_SETTINGS" ]; then
    cp -a "$CLAUDE_SETTINGS" "$BACKUP_DIR/settings.json.bak"
  fi
  if [ -f "${CLAUDE_DIR}/env" ]; then
    cp -a "${CLAUDE_DIR}/env" "$BACKUP_DIR/env.bak"
  fi
  if [ -f "${HOME}/.bashrc" ]; then
    cp -a "${HOME}/.bashrc" "$BACKUP_DIR/bashrc.bak"
  fi

  cat >"$BACKUP_DIR/manifest.txt" <<EOF
backup_time=$(date -Iseconds)
repo_dir=$REPO_DIR
hook_cmd=$HOOK_CMD
claude_settings=$CLAUDE_SETTINGS
EOF

  ln -sfn "$BACKUP_DIR" "${BACKUP_ROOT}/latest"
  echo "[INFO] backup created: $BACKUP_DIR"
}

merge_settings(){
  local src tmp
  src="$CLAUDE_SETTINGS"
  tmp="${CLAUDE_SETTINGS}.tmp"

  if [ ! -f "$src" ]; then
    echo '{}' > "$src"
  fi

  jq --arg cmd "$HOOK_CMD" '
    .hooks = (.hooks // {})
    | .hooks.Stop = ((.hooks.Stop // [])
        | map(select((.hooks // [])[0].command? != $cmd))
        + [{"hooks":[{"type":"command","command":$cmd,"timeout":10}]}])
    | .hooks.SessionEnd = ((.hooks.SessionEnd // [])
        | map(select((.hooks // [])[0].command? != $cmd))
        + [{"hooks":[{"type":"command","command":$cmd,"timeout":10}]}])
  ' "$src" > "$tmp"

  mv "$tmp" "$src"
  echo "[INFO] merged hook into $CLAUDE_SETTINGS"
}

ensure_bashrc_lines(){
  # Optional defaults; do not inject secrets.
  if ! grep -q 'OPENCLAW_HOOK_RESULT_ROOT' "${HOME}/.bashrc" 2>/dev/null; then
    {
      echo ""
      echo "# OpenClaw Claude hooks defaults"
      echo "export OPENCLAW_HOOK_RESULT_ROOT=\"${RESULT_ROOT_DEFAULT}\""
      echo "export OPENCLAW_NOTIFY_CHANNEL=\"feishu\""
    } >> "${HOME}/.bashrc"
    echo "[INFO] appended hook defaults to ~/.bashrc"
  fi
}

run_smoke_test(){
  local tid="deploy-smoke-$(date +%s)"
  local tdir="${RESULT_ROOT_DEFAULT}/tasks/${tid}"
  mkdir -p "$tdir"
  cat >"$tdir/meta.json" <<EOF
{"task_id":"$tid","task_name":"deploy-smoke","notify":{"channel":"feishu","target":""},"workdir":"$HOME"}
EOF
  echo 'smoke output' >"$tdir/output.log"

  OPENCLAW_HOOK_RESULT_ROOT="$RESULT_ROOT_DEFAULT" \
  OPENCLAW_HOOK_TASK_ID="$tid" \
  "$HOOK_CMD" <<<'{"hook_event_name":"Stop","session_id":"deploy-smoke","cwd":"'$HOME'"}' >/dev/null

  test -s "$tdir/result.json"
  echo "[INFO] smoke test ok: $tdir/result.json"
}

do_deploy(){
  check_prereqs
  ensure_dirs
  mk_backup

  chmod +x "$REPO_DIR/hooks/notify-agi.sh" "$REPO_DIR/scripts/dispatch-claude-code.sh" "$REPO_DIR/scripts/run-claude-code.sh"
  merge_settings
  ensure_bashrc_lines
  run_smoke_test

  echo "[OK] deploy complete"
  echo "[NEXT] open a new shell, then run:"
  echo "       cd $REPO_DIR && scripts/dispatch-claude-code.sh -p '测试任务' -n 'deploy-check'"
}

pick_backup(){
  if [ -n "$BACKUP_DIR" ]; then
    [ -d "$BACKUP_DIR" ] || { echo "[ERROR] backup dir not found: $BACKUP_DIR" >&2; exit 1; }
    return
  fi

  if [ -L "${BACKUP_ROOT}/latest" ]; then
    BACKUP_DIR="$(readlink -f "${BACKUP_ROOT}/latest")"
  else
    BACKUP_DIR="$(ls -1dt "${BACKUP_ROOT}"/* 2>/dev/null | head -n1 || true)"
  fi

  [ -n "${BACKUP_DIR:-}" ] || { echo "[ERROR] no backup found" >&2; exit 1; }
}

do_rollback(){
  pick_backup
  echo "[INFO] rollback from: $BACKUP_DIR"

  if [ -f "$BACKUP_DIR/settings.json.bak" ]; then
    cp -a "$BACKUP_DIR/settings.json.bak" "$CLAUDE_SETTINGS"
    echo "[INFO] restored settings.json"
  else
    rm -f "$CLAUDE_SETTINGS"
    echo "[INFO] removed settings.json (no backup file)"
  fi

  if [ -f "$BACKUP_DIR/env.bak" ]; then
    cp -a "$BACKUP_DIR/env.bak" "${CLAUDE_DIR}/env"
    echo "[INFO] restored ~/.claude/env"
  fi

  if [ -f "$BACKUP_DIR/bashrc.bak" ]; then
    cp -a "$BACKUP_DIR/bashrc.bak" "${HOME}/.bashrc"
    echo "[INFO] restored ~/.bashrc"
  fi

  echo "[OK] rollback complete"
}

show_status(){
  echo "=== deploy status ==="
  echo "repo_dir: $REPO_DIR"
  echo "hook_cmd: $HOOK_CMD"
  echo "settings: $CLAUDE_SETTINGS"
  echo ""
  if [ -f "$CLAUDE_SETTINGS" ]; then
    jq -r --arg cmd "$HOOK_CMD" '
      {
        has_stop: ((.hooks.Stop // []) | map((.hooks // [])[0].command? == $cmd) | any),
        has_session_end: ((.hooks.SessionEnd // []) | map((.hooks // [])[0].command? == $cmd) | any)
      }
    ' "$CLAUDE_SETTINGS"
  else
    echo "settings missing"
  fi

  echo ""
  echo "backups:"
  ls -1dt "$BACKUP_ROOT"/* 2>/dev/null | head -n 5 || true
}

case "$ACTION" in
  deploy) do_deploy ;;
  rollback) do_rollback ;;
  status) show_status ;;
  *)
    cat <<EOF
Usage:
  $(basename "$0") deploy
  $(basename "$0") rollback [--backup <dir>]
  $(basename "$0") status
EOF
    exit 1
    ;;
esac
