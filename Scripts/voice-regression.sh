#!/bin/sh
# Voice-pipeline regression gate. Runs the headless `--voice-sim` harness
# against transcripts drawn from real failures — garbled ASR ("purch"),
# alias hits ("派", "P I"), continuation verbs, wrong-project defaults —
# and asserts the assembled card and dry-run dispatch. GROWTH_PLAN makes a
# green run here a precondition for demoing voice on camera.
#
# This is a machine-local acceptance gate, not CI: it reads the real user
# configuration, so it needs the voice dispatch workspace configured and
# the agents installed. It never executes a dispatch — the harness only
# prints the invocation it would run.
set -u

cd "$(dirname "$0")/.."
swift build >/dev/null 2>&1 || { echo "build failed"; exit 1; }
binary=.build/debug/Perch
[ -x "$binary" ] || { echo "missing $binary"; exit 1; }

pass=0
fail=0

# check <label> <transcript> <required-pattern>...
check() {
  label=$1; transcript=$2; shift 2
  output=$("$binary" --voice-sim "$transcript" 2>/dev/null)
  missing=""
  for pattern in "$@"; do
    printf '%s' "$output" | grep -qE "$pattern" || missing="$missing
    missing: $pattern"
  done
  if [ -z "$missing" ]; then
    pass=$((pass + 1))
    echo "PASS $label"
  else
    fail=$((fail + 1))
    echo "FAIL $label$missing"
    printf '%s\n' "$output" | sed 's/^/    | /'
  fi
}

# Dispatch verb routes to dispatch mode with the named agent.
check "dispatch-to-codex" "派给codex跑一遍测试" \
  "mode=dispatch" "agent=ChatGPT" "codex exec --full-auto"

# Real-world garble: "purch" must still land in the Perch project,
# and the continuation verb must resume rather than start fresh.
check "garbled-project-continues" "继续把purch的测试跑一遍" \
  "mode=dispatch" "dir=Perch" "continues=true" "\-\-continue"

# No verb defaults to chat, one tap away from dispatch.
check "no-verb-chat" "帮我写首小诗" "mode=chat"

# Status questions answer immediately, no card.
check "status-question" "现在什么状态" "voice-sim chat:"

# Transcription aliases resolve to the right agent.
check "alias-pai" "告诉派修复构建" "agent=Pi"
check "alias-spelled-out" "P I 修复构建" "agent=Pi"

# English grammar without a separator.
check "english-dispatch" "tell codex run the tests" \
  "mode=dispatch" "agent=ChatGPT"

# Continuation phrasing keeps the resumable handle.
check "continue-last-session" "让pi接着上次继续修登录" \
  "continues=true" "pi -p --continue"

# A fresh pi dispatch mints a session handle the receipt can reopen.
check "fresh-session-handle" "派给pi清理缓存" \
  "mode=dispatch" "agent=Pi" "voice-sim resume: .*--session-id"

echo
echo "voice regression: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
