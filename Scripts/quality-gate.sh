#!/bin/sh
# Machine-enforced subset of docs/ENGINEERING_STANDARDS.md. Run before any
# commit touching Sources/; also wired into CI and the release
# orchestrator. Zero tolerance: the baseline is clean, so any hit is a
# regression against a written standard, not a style opinion.
set -u
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
violations=0

check() {
  label=$1; shift
  hits=$("$@" 2>/dev/null)
  if [ -n "$hits" ]; then
    violations=$((violations + 1))
    echo "GATE FAIL [$label]:"
    printf '%s\n' "$hits" | head -10 | sed 's/^/    /'
  else
    echo "gate ok   [$label]"
  fi
}

# Standards §1-3: PerchCore purity.
check "PerchCore imports no UI frameworks" \
  grep -rn "import AppKit\|import SwiftUI\|import Cocoa" Sources/PerchCore --include=*.swift
check "PerchCore has no print()" \
  grep -rn "print(" Sources/PerchCore --include=*.swift
# Standards §4: no forced try/cast anywhere.
check "no try! anywhere" \
  grep -rn "try!" Sources --include=*.swift
check "no as! anywhere" \
  grep -rn "as! " Sources --include=*.swift
# Standards §11: no landed TODO markers.
check "no TODO/FIXME/XXX in Sources" \
  grep -rnE "TODO|FIXME|XXX" Sources --include=*.swift

# Standards §10: warnings are errors; full deterministic suite.
if [ "${QUALITY_GATE_SKIP_BUILD:-0}" != "1" ]; then
  echo "gate run  [swift build -warnings-as-errors]"
  swift build -Xswiftc -warnings-as-errors >/tmp/quality-gate-build.log 2>&1 || {
    violations=$((violations + 1))
    echo "GATE FAIL [build/warnings]:"; tail -8 /tmp/quality-gate-build.log | sed 's/^/    /'
  }
  echo "gate run  [swift test]"
  swift test >/tmp/quality-gate-test.log 2>&1 || {
    violations=$((violations + 1))
    echo "GATE FAIL [tests]:"; grep -E "failed|error" /tmp/quality-gate-test.log | head -6 | sed 's/^/    /'
  }
fi

if [ "$violations" -gt 0 ]; then
  echo "quality-gate: $violations violation(s) — see docs/ENGINEERING_STANDARDS.md"
  exit 1
fi
echo "quality-gate: all green"
