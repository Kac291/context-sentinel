# 🛰️ context-sentinel

**监控上下文，提前预警，永远不要盲目撞墙。**

[![License](https://img.shields.io/github/license/Kac291/context-sentinel?style=flat)](LICENSE)
[![Stars](https://img.shields.io/github/stars/Kac291/context-sentinel?style=flat)](https://github.com/Kac291/context-sentinel/stargazers)

[English](README.md)

一个 [Claude Code](https://docs.anthropic.com/en/docs/claude-code) 插件，在每条消息和每次工具调用时监控你的上下文窗口。从会话记录中读取精确的 token 数——无估算，无轮询。输出语言跟随你的输入自动切换（中文 ↔ 英文）。

---

## 功能

| | |
|---|---|
| **精确 token 统计** | 从记录中读取 `input_tokens + cache_read_input_tokens + cache_creation_input_tokens` |
| **三级预警** | 🟡 60% 提示 · 🟠 75% 警告 · 🔴 90% 危险——60% 以下保持静默 |
| **燃耗速率 + 重置预测** | 基于最近 5 条消息的滑动窗口。🟡 时告诉你上下文是否会在 5 小时重置前耗尽 |
| **会话计时** | 显示会话已运行时长和距 5 小时用量重置的剩余时间 |
| **Compact 检测** | 检测 `/compact` 事件（token 下降 >50%）并自动重置燃耗基准 |
| **工具调用前预警** | 若上下文在工具调用期间升级到橙/红，提前发出警告——去重处理，仅在等级升级时触发 |

---

## 输出示例

60% 以下保持静默，需要时才显示一条提示。

**🟡 中文——安全预测**
```
[CONTEXT-SENTINEL] 🟡 上下文已用 62%（124,000 / 200,000 tokens）[claude-sonnet-4-6]。
可继续使用，注意预算。剩余约 38 轮对话。
会话运行 1h23m，距5h重置还剩 3h37m。按当前速率，重置前不会触发封顶暂停。
```

**🟠 英文——危险预测**
```
[CONTEXT-SENTINEL] 🟠 context 78% used (156,000 / 200,000 tokens) [claude-sonnet-4-6].
plan /compact after current task. ~22 turns remaining.
Session 2h10m old, reset in 2h50m. ⚠️ Context exhausts in ~45m at current rate — before reset.
```

**🔴 红色警戒**
```
[CONTEXT-SENTINEL] 🔴 上下文已用 93%（186,000 / 200,000 tokens）[claude-sonnet-4-6]。
处于低智能区！建议立即 /compact。剩余约 7 轮对话。
```

---

## 安装

### 第一步 — 克隆仓库

```bash
git clone https://github.com/Kac291/context-sentinel ~/.claude/skills/context-sentinel
```

### 第二步 — 添加 Hook 到 `~/.claude/settings.json`

打开 `~/.claude/settings.json`，添加以下内容。如果已有 `hooks` 字段，将新条目追加到数组中，不要替换原有内容。

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "PYTHONUTF8=1 bash \"$HOME/.claude/skills/context-sentinel/scripts/budget-monitor.sh\""
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "SENTINEL_MODE=pretool PYTHONUTF8=1 bash \"$HOME/.claude/skills/context-sentinel/scripts/budget-monitor.sh\""
          }
        ]
      }
    ]
  }
}
```

### 第三步 — 重启 Claude Code

完成，无需额外配置。

---

### 平台说明

**macOS / Linux** — 开箱即用，Bash 和 Python 3 已预装，无需额外步骤。

**Windows** — 插件脚本需要 Git Bash（不支持 PowerShell 或 CMD）。Python 须在 PATH 中，可识别 `py`、`python3` 或 `python`。Git 操作（`git add`、`commit`、`push`）可在包括 CMD 在内的任意终端中执行。

---

## 环境要求

| | |
|---|---|
| Claude Code | ≥ 2.x（需要 Hook 支持） |
| Python 3 | 仅使用标准库，无需安装任何包 |
| Bash | macOS/Linux 预装 · Windows 使用 Git Bash |

---

## 配置

所有可调参数位于 `scripts/budget-monitor.sh` Python 代码块顶部：

```python
WARN_60 = int(ctx_window * 0.60)   # 🟡 黄色
WARN_75 = int(ctx_window * 0.75)   # 🟠 橙色
WARN_90 = int(ctx_window * 0.90)   # 🔴 红色
RESET_WINDOW_HOURS = 5.0           # 用量重置周期（Claude Pro/Max 默认值）
BURN_WINDOW = 5                    # 滑动窗口消息数
```

---

## 运行测试

```bash
bash scripts/test-monitor.sh
```

预期结果：**24 passed, 0 failed**

---

## 许可证

MIT
