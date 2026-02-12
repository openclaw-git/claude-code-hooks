# OpenClaw-Feishu 优化版 Claude Code Hooks

这是基于 `win4r/claude-code-hooks` 的优化版本，目标是：

- ✅ 兼容 OpenClaw 当前目录规范
- ✅ 支持多任务并发（每个 task 独立目录）
- ✅ 不含任何硬编码 token
- ✅ 默认可走 Feishu 通知（也支持 telegram/其他 channel）
- ✅ 仍兼容 Claude Code Stop/SessionEnd Hook 机制

---

## 1) 改进点总览

### A. 并发隔离
原版大量使用全局单文件（如 `task-meta.json` / `latest.json`），并发任务会覆盖。

本版改为：

```
~/.openclaw/claude-code-results/
  tasks/
    <task_id>/
      meta.json
      output.log
      result.json
      pending-wake.json
      .hook-lock
```

每个任务一个 `task_id` 目录，避免串线。

### B. 无硬编码密钥
- 移除了脚本中的默认 `OPENCLAW_GATEWAY_TOKEN` 回退值。
- 所有鉴权依赖外部环境变量/系统配置注入。

### C. 通知渠道参数化
- `dispatch-claude-code.sh` 支持 `--channel`、`--target`。
- hook 使用 `openclaw message send --channel <channel> --target <target>`。

### D. 去重锁从“全局”改为“每任务”
- 原版 30 秒锁是全局锁，可能误伤并发任务。
- 本版使用 `<task_id>/.hook-lock`，互不影响。

---

## 2) 目录结构

- `hooks/notify-agi.sh`：Stop / SessionEnd 回调主逻辑（已优化）
- `scripts/dispatch-claude-code.sh`：任务派发入口（支持并发参数）
- `scripts/claude_code_run.py`：Claude CLI PTY/tmux 兼容运行器（保留）
- `scripts/run-claude-code.sh`：轻量 runner（移除硬编码 token）

---

## 3) 使用方式

> 注意：本仓库当前仅交付代码，不做自动部署。

### 基础调用

```bash
scripts/dispatch-claude-code.sh \
  -p "分析当前项目并给出重构建议" \
  -n "repo-audit" \
  -w "/path/to/project" \
  -c feishu \
  -t "ou_xxx"
```

### 并发调用（不同 task_id 自动隔离）

```bash
scripts/dispatch-claude-code.sh -p "任务A" -n "task-a" -c feishu -t "ou_xxx" &
scripts/dispatch-claude-code.sh -p "任务B" -n "task-b" -c feishu -t "ou_xxx" &
wait
```

### Agent Teams

```bash
scripts/dispatch-claude-code.sh \
  -p "重构测试并补齐CI" \
  --agent-teams \
  --teammate-mode auto \
  --permission-mode bypassPermissions \
  -c feishu -t "ou_xxx"
```

---

## 4) Hook 注册示例

将以下内容合并进 `~/.claude/settings.json`（路径按你机器实际调整）：

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/ABS_PATH/hooks/notify-agi.sh",
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
            "command": "/ABS_PATH/hooks/notify-agi.sh",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

---

## 5) 环境变量（可选）

- `OPENCLAW_HOOK_RESULT_ROOT`：结果目录（默认 `~/.openclaw/claude-code-results`）
- `OPENCLAW_BIN`：openclaw 命令路径（默认自动 `command -v openclaw`）
- `OPENCLAW_NOTIFY_CHANNEL`：默认通知渠道（默认 `feishu`）
- `OPENCLAW_HOOK_LOCK_WINDOW_SECONDS`：去重窗口（默认 30）
- `OPENCLAW_HOOK_MAX_SUMMARY_CHARS`：摘要长度（默认 1200）

---

## 6) 结果文件说明

- `meta.json`：任务元信息 + 运行状态
- `output.log`：Claude 标准输出日志
- `result.json`：hook 汇总结果（最终可用于归档/二次处理）
- `pending-wake.json`：供轮询/心跳机制消费

---

## 7) 与原仓库差异（重点）

1. 去除硬编码 token；
2. 全部改为 per-task 目录隔离；
3. 消息推送改为 channel+target 参数化；
4. 锁粒度改为 per-task；
5. 保留原有 Claude runner 能力（PTY/tmux）。

---

## 8) Code-node 一键部署与一键还原

新增脚本：`scripts/deploy_code_node.sh`

### 一键部署

```bash
cd /home/lab803/Workspace/claude-code-hooks
scripts/deploy_code_node.sh deploy
```

部署动作：

- 自动检查依赖（`jq/python3/openclaw/claude`）
- 备份 `~/.claude/settings.json`、`~/.claude/env`、`~/.bashrc`
- **合并** Hook 到 Claude settings（不覆盖已有其他配置）
- 写入默认环境变量（不写密钥）
- 运行 smoke test，确认 `result.json` 能生成

### 查看状态

```bash
scripts/deploy_code_node.sh status
```

### 一键还原

```bash
scripts/deploy_code_node.sh rollback
# 或指定某个备份目录
scripts/deploy_code_node.sh rollback --backup ~/.openclaw/claude-hook-deploy-backups/<timestamp>
```

### 异步提交（主 Agent 不阻塞等待）

新增脚本：`scripts/submit_async_task.sh`

用途：主 Agent 只负责“提交任务”，立即返回；Claude 完成后由 Hook 主动发消息到 Feishu/Telegram。

```bash
cd /home/lab803/Workspace/claude-code-hooks
scripts/submit_async_task.sh \
  -p "分析仓库并输出方案" \
  -n "repo-plan" \
  -w "/home/lab803/Workspace/BaiduPan" \
  -c feishu -t "ou_xxx" \
  --agent-teams --teammate-mode auto --permission-mode bypassPermissions
```

返回字段：
- `TASK_ID`
- `PID`
- `LOG_FILE`

说明：
- 主 Agent 无需轮询等待结果；
- 任务完成通知由 `hooks/notify-agi.sh` 自动推送（需 `-t` 指定目标）。

---

## 9) 本次主要问题修复

1. **Hook 配置覆盖问题** → 改为“合并注入”，保留用户原有 `~/.claude/settings.json` 其他内容。  
2. **缺少可回滚能力** → 新增自动备份与一键回滚。  
3. **部署后不可验证** → 新增 smoke test（自动验证回调产物）。  
4. **环境默认值散乱** → 统一在部署脚本写入可选默认值（无硬编码 token）。

---

## 10) 当前状态

- 代码已改完；
- 提供一键部署与一键回滚脚本；
- 仍建议先在测试机验证，再上线生产。
