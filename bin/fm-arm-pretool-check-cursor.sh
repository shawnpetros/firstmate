#!/usr/bin/env bash
# Cursor IDE transport for the watcher-arm PreToolUse seatbelt.
# Always emits Cursor permission JSON on stdout so failClosed hooks stay valid
# when the shared checker allows with empty output.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
payload=$(cat || true)
tmp=$(mktemp)
err=$(mktemp)
trap 'rm -f "$tmp" "$err"' EXIT
set +e
printf '%s' "$payload" | "$SCRIPT_DIR/fm-arm-pretool-check.sh" >"$tmp" 2>"$err"
rc=$?
set -e
if [ "$rc" -eq 2 ]; then
  reason=$(tr -d '\r' <"$err" | tr '\n' ' ')
  reason=${reason:-[watcher-arm] blocked}
  printf '{"permission":"deny","agent_message":%s}\n' "$(printf '%s' "$reason" | jq -Rs .)"
  exit 0
fi
printf '%s\n' '{"permission":"allow"}'
exit 0
