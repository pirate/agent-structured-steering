#!/usr/bin/env bash
set -euo pipefail

POC_ROOT=$(cd "$(dirname "$0")" && pwd)
POC_THREAD_ID=
POC_MODEL=gpt-5.6-luna
POC_DEMO=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --thread)
      POC_THREAD_ID=$2
      shift 2
      ;;
    --model)
      POC_MODEL=$2
      shift 2
      ;;
    --demo)
      POC_DEMO=1
      shift
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

POC_RUNTIME_DIR="$POC_ROOT/.build/steering-overlay"
POC_ACTIVE="$POC_RUNTIME_DIR/active.json"
POC_RUNNER_PID_FILE="$POC_RUNTIME_DIR/runner.pid"
mkdir -p "$POC_RUNTIME_DIR"

# One runner owns both processes; replacing it prevents competing observers from rewriting a tab.
if read -r POC_OLD_RUNNER <"$POC_RUNNER_PID_FILE" 2>/dev/null \
  && [[ "$POC_OLD_RUNNER" =~ ^[0-9]+$ ]] \
  && kill -0 "$POC_OLD_RUNNER" 2>/dev/null; then
  kill "$POC_OLD_RUNNER" 2>/dev/null || true
fi
echo $$ >"$POC_RUNNER_PID_FILE"

POC_OBSERVER_PID=
POC_OVERLAY_PID=
if [[ "$POC_DEMO" -eq 1 ]]; then
  POC_DEMO_DIR="$POC_RUNTIME_DIR/threads/demo"
  mkdir -p "$POC_DEMO_DIR"
  cp "$POC_ROOT/demo-state.json" "$POC_DEMO_DIR/state.json"
  printf '{"threadId":"demo"}\n' >"$POC_ACTIVE"
else
  POC_THREAD_ARGS=()
  if [[ -n "$POC_THREAD_ID" ]]; then
    POC_THREAD_ARGS=(--thread "$POC_THREAD_ID")
  fi
  python3 -u "$POC_ROOT/observer.py" \
    --runtime-dir "$POC_RUNTIME_DIR" \
    --active "$POC_ACTIVE" \
    --schema "$POC_ROOT/status-surface.schema.json" \
    --model "$POC_MODEL" \
    "${POC_THREAD_ARGS[@]}" \
    >"$POC_RUNTIME_DIR/observer.log" 2>&1 &
  POC_OBSERVER_PID=$!
fi

cleanup() {
  if [[ -n "$POC_OBSERVER_PID" ]]; then
    kill "$POC_OBSERVER_PID" 2>/dev/null || true
  fi
  if [[ -n "$POC_OVERLAY_PID" ]]; then
    kill "$POC_OVERLAY_PID" 2>/dev/null || true
  fi
  if [[ "$(cat "$POC_RUNNER_PID_FILE" 2>/dev/null || true)" == "$$" ]]; then
    rm -f "$POC_RUNNER_PID_FILE"
  fi
}
trap cleanup EXIT INT TERM

cd "$POC_ROOT"
swift run -c release SteeringOverlay --active "$POC_ACTIVE" &
POC_OVERLAY_PID=$!
wait "$POC_OVERLAY_PID"
