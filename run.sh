#!/usr/bin/env bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

ROOT=$(cd "$(dirname "$0")" && pwd)
THREAD_ID=
MODEL=gpt-5.6-luna
DEMO=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --thread)
      THREAD_ID=$2
      shift 2
      ;;
    --model)
      MODEL=$2
      shift 2
      ;;
    --demo)
      DEMO=1
      shift
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

RUNTIME="$ROOT/.build/steering-overlay"
ACTIVE="$RUNTIME/active.json"
RUNNER_PID_FILE="$RUNTIME/runner.pid"
mkdir -p "$RUNTIME"

# One runner owns both processes; replacing it prevents competing observers from rewriting a tab.
if [[ -f "$RUNNER_PID_FILE" ]] \
  && read -r OLD_RUNNER <"$RUNNER_PID_FILE" \
  && [[ "$OLD_RUNNER" =~ ^[0-9]+$ ]] \
  && kill -0 "$OLD_RUNNER" 2>/dev/null; then
  kill "$OLD_RUNNER" 2>/dev/null || true
fi
echo $$ >"$RUNNER_PID_FILE"

OBSERVER_PID=
OVERLAY_PID=
if [[ "$DEMO" -eq 1 ]]; then
  DEMO_DIR="$RUNTIME/threads/demo"
  mkdir -p "$DEMO_DIR"
  cp "$ROOT/demo-state.json" "$DEMO_DIR/state.json"
  printf '{"threadId":"demo"}\n' >"$ACTIVE"
else
  if [[ -n "$THREAD_ID" ]]; then
    set -- --thread "$THREAD_ID"
  else
    set --
  fi
  python3 -u "$ROOT/observer.py" --model "$MODEL" "$@" \
    >"$RUNTIME/observer.log" 2>&1 &
  OBSERVER_PID=$!
fi

cleanup() {
  if [[ -n "$OBSERVER_PID" ]]; then
    kill "$OBSERVER_PID" 2>/dev/null || true
  fi
  if [[ -n "$OVERLAY_PID" ]]; then
    kill "$OVERLAY_PID" 2>/dev/null || true
  fi
  if [[ "$(cat "$RUNNER_PID_FILE" 2>/dev/null || true)" == "$$" ]]; then
    rm -f "$RUNNER_PID_FILE"
  fi
}
trap cleanup EXIT INT TERM

cd "$ROOT"
swift run -c release SteeringOverlay --active "$ACTIVE" &
OVERLAY_PID=$!
wait "$OVERLAY_PID"
