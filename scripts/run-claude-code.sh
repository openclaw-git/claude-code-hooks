#!/usr/bin/env bash
# Minimal runner wrapper without hardcoded secrets.
# Usage:
#   ./run-claude-code.sh -p "你的任务" [其他claude参数]

set -euo pipefail

: > /tmp/claude-code-output.txt

# Keep env-driven auth only; do NOT hardcode OPENCLAW_GATEWAY_TOKEN here.
claude "$@" 2>&1 | tee /tmp/claude-code-output.txt
