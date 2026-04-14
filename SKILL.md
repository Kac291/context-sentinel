---
name: context-sentinel
description: >
  Automatic context window monitor for Claude Code. Fires on every message (UserPromptSubmit)
  and on tool calls (PreToolUse). Reads real token counts from the transcript — no heuristics.
  Warns at 60/75/90% with session timer, burn rate prediction, and 5-hour reset awareness.
  Detects /compact events and resets baseline automatically. Output language follows your input
  (Chinese ↔ English auto-detected). Zero config required.
user-invocable: false
hooks:
  UserPromptSubmit:
    - hooks:
        - type: command
          command: "PYTHONUTF8=1 bash \"${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/context-sentinel}/scripts/budget-monitor.sh\""
  PreToolUse:
    - hooks:
        - type: command
          command: "SENTINEL_MODE=pretool PYTHONUTF8=1 bash \"${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/context-sentinel}/scripts/budget-monitor.sh\""
---

# context-sentinel

Automatic context budget monitor for Claude Code.

Fires silently on every message and on tool calls. No output when safe. Warns with burn rate prediction and 5-hour reset awareness when it matters.

## Features

- **Exact token counts** — reads real `usage` data from transcript, not file-size heuristics
- **Three warning levels** — 🟡 60% / 🟠 75% / 🔴 90%, silent below threshold
- **5h reset prediction** — calculates burn rate from last 5 messages; at 🟡 tells you if context will exhaust before your usage window resets
- **Session timer** — shows how long the session has run and how much time until reset
- **Compact detection** — detects `/compact` events (token drop >50%) and resets burn rate baseline
- **PreToolUse hook** — warns mid-turn if context escalates into orange/red between messages; deduped so it only fires on escalation, not every tool call
- **Language auto-detection** — Chinese input → Chinese output; English input → English output

## How It Works

```
UserPromptSubmit / PreToolUse
  → budget-monitor.sh
      → read transcript.jsonl
          ├── usage.input_tokens + cache tokens  →  exact context used
          ├── entry.timestamp (all entries)       →  session age + burn rate
          ├── last user message text              →  language detection
          └── message.model                       →  context window size
      → emit hookSpecificOutput warning if threshold crossed
```

## Thresholds

| Level | Usage | Action |
|-------|-------|--------|
| 🟡 Yellow | 60–74% | Advisory — continue, stay aware |
| 🟠 Orange | 75–89% | Plan `/compact` after current task |
| 🔴 Red | ≥90% | Compact now — model quality degrades here |

## Requirements

- Python 3 (`python3`, `python`, or `py -3` on Windows)
- Bash (Git Bash on Windows)
- Claude Code ≥ 2.x (hook support required)
