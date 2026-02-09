# Claude Code Hooks — 任务完成自动回调

Claude Code 完成任务后通过 Hook 自动通知 OpenClaw AGI，无需轮询，节省 token。

## 原理

```
AGI 下达任务 → Claude Code 自主工作 → Stop Hook 触发 → 写结果 + 通知 AGI
   (1次调用)      (0 token 消耗)        (自动)          (AGI 读结果 1次)
```

## 文件结构

```
├── hooks/
│   └── notify-agi.sh          # Hook 回调脚本
├── scripts/
│   └── run-claude-code.sh     # 启动脚本（注入环境变量）
├── claude-settings.json       # Claude Code Hook 配置
└── README.md
```

## 安装

### 1. 复制 Hook 脚本
```bash
mkdir -p ~/.claude/hooks
cp hooks/notify-agi.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/notify-agi.sh
```

### 2. 配置 Claude Code
将 `claude-settings.json` 的 hooks 部分合并到你的 `~/.claude/settings.json`：
```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/home/ubuntu/.claude/hooks/notify-agi.sh",
            "timeout": 10
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/home/ubuntu/.claude/hooks/notify-agi.sh",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

### 3. 设置环境变量
```bash
export OPENCLAW_GATEWAY_TOKEN="your-gateway-token"
```

### 4. 安装依赖
```bash
# 需要 jq 和 curl
sudo apt install jq curl  # Debian/Ubuntu
brew install jq curl       # macOS
```

## 使用

### 派发任务（AGI 端）
```bash
cd /path/to/workdir && nohup bash -c '
OPENCLAW_GATEWAY_TOKEN="<token>" \
python3 /path/to/claude_code_run.py \
  -p "你的任务描述" \
  --permission-mode plan \
  --allowedTools "Read,Bash" \
  2>&1 | tee /tmp/claude-code-output.txt
' > /dev/null 2>&1 &
```

### 读取结果
任务完成后，结果自动写入：
```bash
cat /home/ubuntu/clawd/data/claude-code-results/latest.json
```

结果 JSON 格式：
```json
{
  "session_id": "abc123",
  "timestamp": "2026-02-09T14:54:27+00:00",
  "cwd": "/home/ubuntu/projects/my-project",
  "event": "SessionEnd",
  "output": "Claude Code 的输出内容...",
  "status": "done"
}
```

## 通知方式

Hook 触发后会：
1. **写结果文件**: `data/claude-code-results/latest.json`
2. **发送 wake event**: 通过 OpenClaw Gateway API（`POST /api/cron/wake`）唤醒 AGI 主 session

## 注意事项

- ✅ 兼容 PTY 和非 PTY 环境
- ✅ Stop + SessionEnd 双重 Hook 保障
- ⚠️ 需要 `OPENCLAW_GATEWAY_TOKEN` 才能发 wake event
- ⚠️ 建议用 `claude_code_run.py` wrapper 启动（带 PTY 支持）
- ⚠️ 直接 `claude -p` 在某些 exec 环境可能卡住

## Token 节省

| 方式 | AGI 调用次数 | 等待期间消耗 |
|------|-------------|-------------|
| 轮询 | 3-5 次 | 每次都消耗 token |
| Hook | 2 次 | 0 |

## 自定义

修改 `notify-agi.sh` 中的结果目录：
```bash
RESULT_DIR="/your/custom/path"
```

修改通知方式（如发 Telegram、Slack 等）：在脚本末尾添加对应的 API 调用。

## License

MIT
