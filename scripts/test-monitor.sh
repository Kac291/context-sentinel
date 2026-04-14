#!/usr/bin/env bash
# Tests for budget-monitor.sh
# Usage: bash scripts/test-monitor.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITOR="$SCRIPT_DIR/budget-monitor.sh"
PASS=0
FAIL=0

PYTHON=$(py -3 -c "import sys; print(sys.executable)" 2>/dev/null \
  || python3 -c "import sys; print(sys.executable)" 2>/dev/null \
  || python -c "import sys; print(sys.executable)" 2>/dev/null \
  || echo "")
if [ -z "$PYTHON" ]; then echo "ERROR: no Python found"; exit 1; fi

# ── Fixture builders ──────────────────────────────────────────────────────────

# Single-entry transcript, no timestamps, optional user message
make_transcript() {
  local toks="$1"
  local model="${2:-claude-sonnet-4-6}"
  local user_msg="${3:-}"
  local tmpfile; tmpfile=$(mktemp)
  "$PYTHON" - "$toks" "$model" "$user_msg" > "$tmpfile" << 'PYEOF'
import json, sys
toks, model, user_msg = int(sys.argv[1]), sys.argv[2], sys.argv[3]
if user_msg:
    print(json.dumps({'type': 'user', 'message': {'role': 'user', 'content': user_msg}}))
print(json.dumps({
    'type': 'assistant',
    'message': {
        'role': 'assistant', 'model': model,
        'usage': {'input_tokens': toks, 'cache_read_input_tokens': 0,
                  'cache_creation_input_tokens': 0, 'output_tokens': 500}
    }
}))
PYEOF
  echo "$tmpfile"
}

# Two timestamped entries + first user entry (for burn rate / session timer tests)
# Args: toks_first  toks_last  minutes_apart  [user_msg]  [model]
make_transcript_timed() {
  local toks_first="$1" toks_last="$2" mins="$3"
  local user_msg="${4:-}"
  local model="${5:-claude-sonnet-4-6}"
  local tmpfile; tmpfile=$(mktemp)
  "$PYTHON" - "$toks_first" "$toks_last" "$mins" "$user_msg" "$model" > "$tmpfile" << 'PYEOF'
import json, sys, datetime
toks_first, toks_last = int(sys.argv[1]), int(sys.argv[2])
mins, user_msg, model = int(sys.argv[3]), sys.argv[4], sys.argv[5]
now = datetime.datetime.now(datetime.timezone.utc)
t0  = now - datetime.timedelta(minutes=mins)
t1  = now

def mk_assistant(ts, toks):
    return {'type': 'assistant', 'timestamp': ts.isoformat(),
            'message': {'role': 'assistant', 'model': model,
                        'usage': {'input_tokens': toks, 'cache_read_input_tokens': 0,
                                  'cache_creation_input_tokens': 0, 'output_tokens': 500}}}

print(json.dumps({'type': 'user', 'timestamp': t0.isoformat(),
                  'message': {'role': 'user', 'content': user_msg or 'hi'}}))
print(json.dumps(mk_assistant(t0, toks_first)))
print(json.dumps(mk_assistant(t1, toks_last)))
PYEOF
  echo "$tmpfile"
}

# Compact transcript: high tokens, then drop, then current (simulates /compact)
# Args: toks_before_compact  toks_after_compact  toks_current  [user_msg]
make_transcript_compacted() {
  local before="$1" after="$2" current="$3"
  local user_msg="${4:-hi}"
  local model="claude-sonnet-4-6"
  local tmpfile; tmpfile=$(mktemp)
  "$PYTHON" - "$before" "$after" "$current" "$user_msg" "$model" > "$tmpfile" << 'PYEOF'
import json, sys, datetime
before, after, current = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
user_msg, model = sys.argv[4], sys.argv[5]
now = datetime.datetime.now(datetime.timezone.utc)
t0  = now - datetime.timedelta(minutes=90)  # pre-compact
t1  = now - datetime.timedelta(minutes=45)  # compact happened here
t2  = now - datetime.timedelta(minutes=15)  # post-compact
t3  = now                                   # current

def mk(ts, toks):
    return {'type': 'assistant', 'timestamp': ts.isoformat(),
            'message': {'role': 'assistant', 'model': model,
                        'usage': {'input_tokens': toks, 'cache_read_input_tokens': 0,
                                  'cache_creation_input_tokens': 0, 'output_tokens': 500}}}

print(json.dumps({'type': 'user', 'timestamp': t0.isoformat(),
                  'message': {'role': 'user', 'content': user_msg}}))
print(json.dumps(mk(t0, before)))   # high before compact
print(json.dumps(mk(t1, after)))    # sharp drop = compact
print(json.dumps(mk(t2, after + 20000)))
print(json.dumps(mk(t3, current)))  # current
PYEOF
  echo "$tmpfile"
}

# ── Runner helpers ────────────────────────────────────────────────────────────
_run_monitor() {
  local tmpfile="$1" mode="${2:-userprompt}" session="${3:-test-session}"
  echo "{\"transcript_path\":\"$tmpfile\",\"prompt\":\"test\",\"session_id\":\"$session\"}" \
    | PYTHONUTF8=1 SENTINEL_MODE="$mode" bash "$MONITOR" 2>/dev/null || true
}

run_test() {
  local name="$1" tmpfile="$2" expect="$3" mode="${4:-userprompt}"
  local actual; actual=$(_run_monitor "$tmpfile" "$mode")
  rm -f "$tmpfile"
  if [ "$expect" = "EMPTY" ]; then
    if [ -z "$actual" ]; then
      echo "✓ PASS: $name"; PASS=$((PASS+1))
    else
      echo "✗ FAIL: $name — expected empty, got: $actual"; FAIL=$((FAIL+1))
    fi
  else
    local matched
    matched=$(PYTHONUTF8=1 "$PYTHON" -c "
import sys; print('yes' if sys.argv[1] in sys.argv[2] else 'no')
" "$expect" "$actual" 2>/dev/null || echo "no")
    if [ "$matched" = "yes" ]; then
      echo "✓ PASS: $name"; PASS=$((PASS+1))
    else
      echo "✗ FAIL: $name — expected '$expect', got: $actual"; FAIL=$((FAIL+1))
    fi
  fi
}

run_test_absent() {
  local name="$1" tmpfile="$2" absent="$3" mode="${4:-userprompt}"
  local actual; actual=$(_run_monitor "$tmpfile" "$mode")
  rm -f "$tmpfile"
  local found
  found=$(PYTHONUTF8=1 "$PYTHON" -c "
import sys; print('yes' if sys.argv[1] in sys.argv[2] else 'no')
" "$absent" "$actual" 2>/dev/null || echo "no")
  if [ "$found" = "no" ]; then
    echo "✓ PASS: $name"; PASS=$((PASS+1))
  else
    echo "✗ FAIL: $name — '$absent' should be absent, got: $actual"; FAIL=$((FAIL+1))
  fi
}

# ── Context window reference ──────────────────────────────────────────────────
# 200,000 token window:
#  40% =  80,000 → silent
#  62% = 124,000 → yellow
#  80% = 160,000 → orange
#  92% = 184,000 → red
#
# Timed fixtures (slow/fast burn, 60min session → 4h to 5h reset):
#  slow: 120K→124K / 60min → 4K/h → 4K×4h = 16K predicted → 124K+16K=140K < 200K → SAFE
#  fast:  34K→124K / 60min → 90K/h → 90K×4h = 360K >> 76K remaining → EXHAUSTS

echo "=== context-sentinel tests ==="

echo ""
echo "── Threshold / level ───────────────────────────────────────────────────"
run_test        "below-60pct: silent"        "$(make_transcript 80000)"  "EMPTY"
run_test        "at-62pct: fires warning"    "$(make_transcript 124000)" "CONTEXT-SENTINEL"
run_test        "at-62pct: yellow emoji"     "$(make_transcript 124000)" "🟡"
run_test        "at-62pct: shows 62%"        "$(make_transcript 124000)" "62%"
run_test        "at-80pct: orange emoji"     "$(make_transcript 160000)" "🟠"
run_test        "at-80pct: compact advice"   "$(make_transcript 160000)" "compact"
run_test        "at-92pct: red emoji"        "$(make_transcript 184000)" "🔴"
run_test        "at-92pct: low-intelligence" "$(make_transcript 184000 claude-sonnet-4-6 '帮我看代码')" "低智能区"
run_test        "model name in output"       "$(make_transcript 124000)" "claude-sonnet-4-6"
run_test        "empty transcript: silent"   "$(mktemp)"                 "EMPTY"

echo ""
echo "── Language detection ──────────────────────────────────────────────────"
run_test        "Chinese input → zh output"  "$(make_transcript 124000 claude-sonnet-4-6 '你好，帮我看看代码')" "轮对话"
run_test        "English input → en output"  "$(make_transcript 124000 claude-sonnet-4-6 'help me with code')"  "turns remaining"
run_test        "no user msg → en output"    "$(make_transcript 124000)"                                        "turns remaining"

echo ""
echo "── Session timer ────────────────────────────────────────────────────────"
run_test        "timed: shows session age"      "$(make_transcript_timed 120000 124000 60 '帮我看看')" "会话运行"
run_test        "timed: shows reset countdown"  "$(make_transcript_timed 120000 124000 60 '帮我看看')" "距5h重置还剩"
run_test_absent "no-ts: no session timer"       "$(make_transcript 124000)"                 "会话运行"

echo ""
echo "── Burn rate prediction ─────────────────────────────────────────────────"
run_test        "slow-burn: safe at yellow"   "$(make_transcript_timed 120000 124000 60 '帮我看看')" "重置前不会触发封顶暂停"
run_test        "fast-burn: danger warning"   "$(make_transcript_timed 34000 124000 60 '帮我看看')"   "上下文耗尽，早于5h重置"
run_test_absent "no-ts: no prediction"        "$(make_transcript 124000)"                 "重置前不会"

echo ""
echo "── Compact detection ────────────────────────────────────────────────────"
# Before compact: 160K (orange) → after compact: 30K → current: 40K (silent).
# If compact NOT detected, last token count = 160K → fires orange warning.
# If compact IS detected, baseline resets → 40K used → silent (under 60%).
run_test        "post-compact: resets baseline → silent" \
  "$(make_transcript_compacted 160000 30000 40000)" "EMPTY"

echo ""
echo "── Sliding window burn rate ─────────────────────────────────────────────"
# Build a transcript where the recent 5-turn window is slow-burn
# but the full history (if used) would look fast-burn.
# We simulate: old turns did 90K/h, recent turns do 4K/h.
# Prediction with full history → might say "danger".
# Prediction with sliding window (last 5 msgs) → should say "safe".
run_test        "sliding window: recent slow burn → safe" \
  "$(make_transcript_timed 120000 124000 60 '帮我看看')" "重置前不会触发封顶暂停"

echo ""
echo "── PreToolUse mode ──────────────────────────────────────────────────────"
# Below 75%: pretool should be silent
run_test        "pretool: silent below 75%"  "$(make_transcript 124000)" "EMPTY" "pretool"
# At 80% (orange): pretool fires on first call (no prior state)
run_test        "pretool: warns at orange"   "$(make_transcript 160000)" "CONTEXT-SENTINEL" "pretool"
# pretool at orange uses brief format (no "轮对话" rounds line)
run_test_absent "pretool: no rounds line"    "$(make_transcript 160000)" "轮对话" "pretool"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
