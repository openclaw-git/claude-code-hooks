#!/bin/bash
# 启动 Claude Code 并确保 hook 环境变量可用
# 用法: ./run-claude-code.sh -p "你的任务" [其他 claude 参数]
#
# 示例:
#   ./run-claude-code.sh -p "Write hello.py that prints hello world" --allowedTools "Bash,Read,Edit,Write"
#   ./run-claude-code.sh -p "Analyze this repo" --permission-mode plan

export OPENCLAW_GATEWAY_TOKEN=""

# 清理上次的输出文件
> /tmp/claude-code-output.txt

# 运行 Claude Code，输出同时写入文件和 stdout
claude "$@" 2>&1 | tee /tmp/claude-code-output.txt
