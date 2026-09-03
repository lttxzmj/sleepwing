#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
provider=${1:-claude}
event=${2:-PreToolUse}
session=${3:-perch-smoke-test}

case "$provider" in
  claude)
    payload="{\"hook_event_name\":\"$event\",\"session_id\":\"$session\"}"
    ;;
  cursor)
    payload="{\"hook_event_name\":\"$event\",\"conversation_id\":\"$session\"}"
    ;;
  codex)
    payload="{\"type\":\"$event\",\"thread-id\":\"$session\"}"
    ;;
  *)
    echo "provider must be claude, cursor, or codex" >&2
    exit 2
    ;;
esac

/bin/sh "$script_dir/perch-hook" "$provider" "$payload"
echo "Perch smoke event delivered through the privacy sanitizer."
