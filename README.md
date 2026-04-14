# 🛰️ context-sentinel

**watch context. warn early. never hit the wall blind.**

[![License](https://img.shields.io/github/license/Kac291/context-sentinel?style=flat)](LICENSE)
[![Stars](https://img.shields.io/github/stars/Kac291/context-sentinel?style=flat)](https://github.com/Kac291/context-sentinel/stargazers)

[中文文档](README_CN.md)

A [Claude Code](https://docs.anthropic.com/en/docs/claude-code) plugin that monitors your context window on every message and every tool call. Reads exact token counts from the session transcript — no heuristics, no polling. Output language follows your input (Chinese ↔ English auto-detected).

---

## Features

| | |
|---|---|
| **Exact token tracking** | Reads `input_tokens + cache_read_input_tokens + cache_creation_input_tokens` from the transcript |
| **Three warning levels** | 🟡 60% advisory · 🟠 75% caution · 🔴 90% danger — silent below 60% |
| **Burn rate + reset prediction** | Sliding window over last 5 messages. At 🟡, tells you if context exhausts before your 5-hour reset |
| **Session timer** | Shows session age and time remaining until the 5-hour usage reset |
| **Compact detection** | Detects `/compact` events (>50% token drop) and resets burn rate baseline automatically |
| **PreToolUse mid-turn alerts** | Warns if context escalates into orange/red during tool use — deduped, only fires on escalation |

---

## Sample Output

Silent below 60%. One line when it matters.

**🟡 Yellow — safe prediction**
```
[CONTEXT-SENTINEL] 🟡 context 62% used (124,000 / 200,000 tokens) [claude-sonnet-4-6].
continue — stay aware. ~38 turns remaining.
Session 1h23m old, reset in 3h37m. At current burn rate, context will not exhaust before reset.
```

**🟠 Orange — danger prediction**
```
[CONTEXT-SENTINEL] 🟠 context 78% used (156,000 / 200,000 tokens) [claude-sonnet-4-6].
plan /compact after current task. ~22 turns remaining.
Session 2h10m old, reset in 2h50m. ⚠️ Context exhausts in ~45m at current rate — before reset.
```

**🔴 Red zone**
```
[CONTEXT-SENTINEL] 🔴 context 93% used (186,000 / 200,000 tokens) [claude-sonnet-4-6].
compact now — model quality degrading. ~7 turns remaining.
```

---

## Installation

### Step 1 — Clone the repo

```bash
git clone https://github.com/Kac291/context-sentinel ~/.claude/skills/context-sentinel
```

### Step 2 — Add hooks to `~/.claude/settings.json`

Open `~/.claude/settings.json` and add the following. If a `hooks` key already exists, append to the arrays — don't replace them.

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

### Step 3 — Restart Claude Code

Done. No further configuration needed.

---

### Platform notes

**macOS / Linux** — works out of the box. Bash and Python 3 are pre-installed; no extra steps.

**Windows** — the plugin script requires Git Bash (not PowerShell or CMD). Python must be on PATH as `py`, `python3`, or `python`. Git operations (`git add`, `commit`, `push`) can be run from any terminal including CMD.

---

## Requirements

| | |
|---|---|
| Claude Code | ≥ 2.x (hook support required) |
| Python 3 | stdlib only — no packages needed |
| Bash | pre-installed on macOS/Linux · Git Bash on Windows |

---

## Configuration

All tuneable constants are at the top of the Python block in `scripts/budget-monitor.sh`:

```python
WARN_60 = int(ctx_window * 0.60)   # 🟡 yellow
WARN_75 = int(ctx_window * 0.75)   # 🟠 orange
WARN_90 = int(ctx_window * 0.90)   # 🔴 red
RESET_WINDOW_HOURS = 5.0           # usage reset interval (Claude Pro/Max default)
BURN_WINDOW = 5                    # messages in sliding window
```

---

## Running Tests

```bash
bash scripts/test-monitor.sh
```

Expected: **24 passed, 0 failed**

---

## License

MIT
