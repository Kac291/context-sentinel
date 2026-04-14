#!/usr/bin/env bash
# context-sentinel: budget-monitor.sh
# Hooks: UserPromptSubmit (full) and PreToolUse (75%+ only, deduped)
#
# Features:
#   - Exact token counts from transcript
#   - Sliding-window burn rate (last 5 data points)
#   - Compact detection: token drop resets burn rate baseline
#   - 5h reset prediction
#   - Language detection: Chinese input → Chinese output, else English
#   - PreToolUse: warns only on level escalation (deduped via state file)

PYTHON=$(py -3 -c "import sys; print(sys.executable)" 2>/dev/null \
  || python3 -c "import sys; print(sys.executable)" 2>/dev/null \
  || python -c "import sys; print(sys.executable)" 2>/dev/null \
  || echo "")
[ -z "$PYTHON" ] && exit 0

INPUT=$(cat)
export SENTINEL_INPUT="$INPUT"
export SENTINEL_MODE="${SENTINEL_MODE:-userprompt}"

# Extract transcript_path
TRANSCRIPT=$("$PYTHON" - << 'PYEOF'
import json, os
raw = os.environ.get('SENTINEL_INPUT', '')
try:
    d = json.loads(raw)
    print(d.get('transcript_path', ''))
except Exception:
    print('')
PYEOF
)

# Extract session_id
SESSION_ID=$("$PYTHON" - << 'PYEOF'
import json, os
raw = os.environ.get('SENTINEL_INPUT', '')
try:
    d = json.loads(raw)
    print(d.get('session_id', ''))
except Exception:
    print('')
PYEOF
)

[ -z "$TRANSCRIPT" ] && exit 0
[ ! -f "$TRANSCRIPT" ] && exit 0

export SENTINEL_TRANSCRIPT="$TRANSCRIPT"
export SENTINEL_SESSION="$SESSION_ID"

PYTHONUTF8=1 "$PYTHON" - << 'PYEOF'
import json, os, sys, datetime, re, pathlib

if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8')

transcript_path = os.environ['SENTINEL_TRANSCRIPT']
session_id      = os.environ.get('SENTINEL_SESSION', '')
mode            = os.environ.get('SENTINEL_MODE', 'userprompt')  # userprompt | pretool

# ── State file for PreToolUse dedup ─────────────────────────────────────────
_state_path = pathlib.Path.home() / '.claude' / '.sentinel_warned.json'
LEVEL_ORDER = {'': 0, 'yellow': 1, 'orange': 2, 'red': 3}

def read_warned_level(sid):
    try:
        data = json.loads(_state_path.read_text(encoding='utf-8'))
        return data.get(sid, '')
    except Exception:
        return ''

def write_warned_level(sid, level):
    if not sid:
        return
    try:
        try:
            data = json.loads(_state_path.read_text(encoding='utf-8'))
        except Exception:
            data = {}
        if len(data) > 20:
            for k in sorted(data.keys())[:-20]:
                del data[k]
        data[sid] = level
        _state_path.write_text(json.dumps(data), encoding='utf-8')
    except Exception:
        pass

# ── Helpers ──────────────────────────────────────────────────────────────────
def get_context_window(model_name):
    if not model_name:
        return 200_000
    m = model_name.lower()
    known = {
        'claude-opus-4':     200_000,
        'claude-sonnet-4':   200_000,
        'claude-haiku-4':    200_000,
        'claude-3-5-sonnet': 200_000,
        'claude-3-5-haiku':  200_000,
        'claude-3-opus':     200_000,
        'claude-3-sonnet':   200_000,
        'claude-3-haiku':    200_000,
    }
    for prefix, window in known.items():
        if prefix in m:
            return window
    return 200_000

def parse_ts(entry):
    for field in ('timestamp', 'createdAt', 'created_at', 'ts'):
        val = entry.get(field)
        if val:
            try:
                dt = datetime.datetime.fromisoformat(str(val).replace('Z', '+00:00'))
                if dt.tzinfo is None:
                    dt = dt.replace(tzinfo=datetime.timezone.utc)
                return dt
            except Exception:
                pass
    return None

def fmt_duration(hours):
    total_m = int(hours * 60)
    h, m = divmod(total_m, 60)
    if h > 0 and m > 0:
        return f'{h}h{m}m'
    elif h > 0:
        return f'{h}h'
    return f'{m}m'

def is_chinese(text):
    return bool(re.search(r'[\u4e00-\u9fff\u3400-\u4dbf]', text or ''))

# ── Parse transcript JSONL ───────────────────────────────────────────────────
last_usage     = None
last_model     = None
session_start  = None
token_history  = []   # [(datetime, total_tokens)]
last_user_text = ''

try:
    with open(transcript_path, 'r', encoding='utf-8', errors='replace') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue

            # First parseable timestamp → session start
            if session_start is None:
                ts = parse_ts(entry)
                if ts:
                    session_start = ts

            msg = entry.get('message', {})

            # Track last user message text for language detection
            if entry.get('type') == 'user' or msg.get('role') == 'user':
                content = msg.get('content', '')
                if isinstance(content, str) and content.strip():
                    last_user_text = content
                elif isinstance(content, list):
                    for block in content:
                        if isinstance(block, dict) and block.get('type') == 'text':
                            txt = block.get('text', '').strip()
                            if txt:
                                last_user_text = txt

            # Track assistant messages with usage data
            if entry.get('type') == 'assistant' or msg.get('role') == 'assistant':
                usage = msg.get('usage', {})
                if usage and 'input_tokens' in usage:
                    last_usage = usage
                    last_model = msg.get('model', last_model)
                    ts = parse_ts(entry)
                    if ts:
                        toks = (usage.get('input_tokens', 0)
                                + usage.get('cache_read_input_tokens', 0)
                                + usage.get('cache_creation_input_tokens', 0))
                        token_history.append((ts, toks))
except OSError:
    sys.exit(0)

if last_usage is None:
    sys.exit(0)

# ── Compact detection ────────────────────────────────────────────────────────
# A >50% token drop between consecutive messages signals a /compact event.
# Trim to post-compact window and reset session_start to the compact point.
for i in range(len(token_history) - 1, 0, -1):
    prev, curr = token_history[i-1][1], token_history[i][1]
    if curr < prev * 0.5:
        token_history = token_history[i:]
        if token_history:
            session_start = token_history[0][0]
        break

# ── Token counts ─────────────────────────────────────────────────────────────
total_context_tokens = (last_usage.get('input_tokens', 0)
                        + last_usage.get('cache_read_input_tokens', 0)
                        + last_usage.get('cache_creation_input_tokens', 0))

ctx_window       = get_context_window(last_model)
pct              = total_context_tokens / ctx_window * 100
remaining_tokens = max(0, ctx_window - total_context_tokens)
msgs_remaining   = max(0, int(remaining_tokens / 2000))

WARN_60 = int(ctx_window * 0.60)
WARN_75 = int(ctx_window * 0.75)
WARN_90 = int(ctx_window * 0.90)

# ── Warning level ─────────────────────────────────────────────────────────────
if total_context_tokens >= WARN_90:
    level = 'red'
elif total_context_tokens >= WARN_75:
    level = 'orange'
elif total_context_tokens >= WARN_60:
    level = 'yellow'
else:
    sys.exit(0)

# ── PreToolUse gate: only emit if level escalated ────────────────────────────
if mode == 'pretool':
    if level == 'yellow':
        sys.exit(0)  # not urgent enough to interrupt tool calls
    last_warned = read_warned_level(session_id)
    if LEVEL_ORDER.get(level, 0) <= LEVEL_ORDER.get(last_warned, 0):
        sys.exit(0)  # same or lower level already warned — no spam

# ── Language detection ───────────────────────────────────────────────────────
lang = 'zh' if is_chinese(last_user_text) else 'en'

# ── Time calculations ─────────────────────────────────────────────────────────
RESET_WINDOW_HOURS = 5.0
now = datetime.datetime.now(datetime.timezone.utc)

session_age_hours   = 0.0
time_to_reset_hours = RESET_WINDOW_HOURS
if session_start:
    session_age_hours   = max(0.0, (now - session_start).total_seconds() / 3600)
    time_to_reset_hours = max(0.0, RESET_WINDOW_HOURS - session_age_hours)

# ── Sliding-window burn rate (last 5 data points) ────────────────────────────
BURN_WINDOW = 5
burn_rate_per_hour = None
if len(token_history) >= 2:
    window = token_history[-min(BURN_WINDOW, len(token_history)):]
    t0, toks0 = window[0]
    t1, toks1 = window[-1]
    elapsed_h = (t1 - t0).total_seconds() / 3600
    if elapsed_h >= 1 / 60 and toks1 > toks0:
        burn_rate_per_hour = (toks1 - toks0) / elapsed_h

# ── Prediction ────────────────────────────────────────────────────────────────
will_exhaust    = None
hours_until_cap = None
if burn_rate_per_hour and burn_rate_per_hour > 0:
    predicted_at_reset = total_context_tokens + burn_rate_per_hour * time_to_reset_hours
    will_exhaust    = predicted_at_reset >= ctx_window
    hours_until_cap = remaining_tokens / burn_rate_per_hour

# ── Build message ─────────────────────────────────────────────────────────────
model_str = f' [{last_model}]' if last_model else ''

EMOJI = {'yellow': '🟡', 'orange': '🟠', 'red': '🔴'}

if lang == 'zh':
    ADVICE = {
        'yellow': '可继续使用，注意预算',
        'orange': '建议当前任务完成后 /compact',
        'red':    '处于低智能区！建议立即 /compact',
    }
    if mode == 'pretool':
        msg = (f'[CONTEXT-SENTINEL] {EMOJI[level]} 工具执行前警告：'
               f'上下文已用 {pct:.0f}%（{total_context_tokens:,} / {ctx_window:,}）{model_str}。'
               f'{ADVICE[level]}。')
    else:
        session_line = ''
        if session_start:
            session_line = (f' 会话运行 {fmt_duration(session_age_hours)}，'
                            f'距5h重置还剩 {fmt_duration(time_to_reset_hours)}。')
        prediction_line = ''
        if will_exhaust is not None:
            if level == 'yellow' and not will_exhaust:
                prediction_line = ' 按当前速率，重置前不会触发封顶暂停。'
            elif will_exhaust and hours_until_cap is not None:
                prediction_line = f' ⚠️ 按当前速率约 {fmt_duration(hours_until_cap)} 后上下文耗尽，早于5h重置。'
        msg = (f'[CONTEXT-SENTINEL] {EMOJI[level]} '
               f'上下文已用 {pct:.0f}%（{total_context_tokens:,} / {ctx_window:,} tokens）{model_str}。'
               f'{ADVICE[level]}。剩余约 {msgs_remaining} 轮对话。'
               f'{session_line}{prediction_line}')
else:
    ADVICE = {
        'yellow': 'continue — stay aware',
        'orange': 'plan /compact after current task',
        'red':    'compact now — model quality degrading',
    }
    if mode == 'pretool':
        msg = (f'[CONTEXT-SENTINEL] {EMOJI[level]} pre-tool warning: '
               f'context at {pct:.0f}% ({total_context_tokens:,} / {ctx_window:,}){model_str}. '
               f'{ADVICE[level]}.')
    else:
        session_line = ''
        if session_start:
            session_line = (f' Session {fmt_duration(session_age_hours)} old, '
                            f'reset in {fmt_duration(time_to_reset_hours)}.')
        prediction_line = ''
        if will_exhaust is not None:
            if level == 'yellow' and not will_exhaust:
                prediction_line = ' At current burn rate, context will not exhaust before reset.'
            elif will_exhaust and hours_until_cap is not None:
                prediction_line = (f' ⚠️ Context exhausts in ~{fmt_duration(hours_until_cap)}'
                                   f' at current rate — before reset.')
        msg = (f'[CONTEXT-SENTINEL] {EMOJI[level]} '
               f'context {pct:.0f}% used ({total_context_tokens:,} / {ctx_window:,} tokens){model_str}. '
               f'{ADVICE[level]}. ~{msgs_remaining} turns remaining.'
               f'{session_line}{prediction_line}')

# Update state file (UserPromptSubmit always; PreToolUse on escalation)
write_warned_level(session_id, level)

output = {
    'hookSpecificOutput': {
        'hookEventName': 'UserPromptSubmit' if mode == 'userprompt' else 'PreToolUse',
        'additionalContext': msg
    }
}
print(json.dumps(output, ensure_ascii=False))
PYEOF

exit 0
