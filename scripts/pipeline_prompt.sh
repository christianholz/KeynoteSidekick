#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BIN="${APP_BIN:-$ROOT_DIR/KeynoteSidekick.app/Contents/MacOS/KeynoteSidekick}"

if [[ ! -x "$APP_BIN" ]]; then
  echo "ERROR: app binary not found or not executable at: $APP_BIN" >&2
  exit 1
fi

if [[ $# -eq 0 ]]; then
  cat >&2 <<'USAGE'
Usage:
  scripts/pipeline_prompt.sh "<prompt text>"

Optional:
  APP_BIN=/absolute/path/to/KeynoteSidekick.app/Contents/MacOS/KeynoteSidekick scripts/pipeline_prompt.sh "..."
USAGE
  exit 2
fi

if [[ "$1" == "--help" || "$1" == "-h" ]]; then
  cat <<'USAGE'
Usage:
  scripts/pipeline_prompt.sh "<prompt text>"

Runs one prompt through KeynoteSidekick pipeline mode with debug logs enabled.
USAGE
  exit 0
fi

PROMPT="$*"
printf '%s\n' "$PROMPT" | "$APP_BIN" --pipeline --pipeline-debug
