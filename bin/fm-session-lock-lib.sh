#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process descend from that same harness?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake.
# This file is sourced by scripts and has no side effects on source.

# Known harness command names; extend when a new adapter is verified.
# Spell cursor-agent in full so an unrelated process mentioning "cursor" cannot
# match. Cursor IDE primaries use CURSOR_AGENT=1 + CURSOR_CONVERSATION_ID via
# fm_harness_lock_identity instead of a shared Cursor Helper PID.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|cursor-agent|^pi$|^pi-signed$'

# Grace period for Cursor IDE conversation-scoped lock beats (seconds).
FM_CURSOR_LOCK_BEAT_GRACE_SECS="${FM_CURSOR_LOCK_BEAT_GRACE_SECS:-900}"

# Print cursor-conv:<id> when this process is a Cursor IDE agent tool child with
# a usable conversation id. Fail closed when CURSOR_AGENT=1 but the id is absent
# or contains characters outside the verified safe set.
fm_cursor_conv_token() {
  [ "${CURSOR_AGENT:-}" = "1" ] || return 1
  local id=${CURSOR_CONVERSATION_ID:-}
  [ -n "$id" ] || return 1
  case "$id" in
    *[!A-Za-z0-9_-]*) return 1 ;;
  esac
  printf 'cursor-conv:%s\n' "$id"
}

# Refresh the conversation beat used for cross-session liveness of cursor-conv
# lock tokens. $1 = state dir, $2 = conversation id (no prefix).
fm_cursor_lock_touch_beat() {
  local state=$1 id=$2
  [ -n "$state" ] && [ -n "$id" ] || return 1
  mkdir -p "$state" 2>/dev/null || return 1
  printf '%s\n' "$id" > "$state/.lock-cursor-beat"
}

# True when a cursor-conv lock token still looks live.
# Alive if: current env owns that conversation, or a matching beat file is fresh.
fm_cursor_conv_alive() {  # <token> <state-dir-or-empty>
  local token=$1 state=${2:-} id beat_id age now mtime
  case "$token" in
    cursor-conv:*) id=${token#cursor-conv:} ;;
    *) return 1 ;;
  esac
  [ -n "$id" ] || return 1
  if [ "${CURSOR_AGENT:-}" = "1" ] && [ "${CURSOR_CONVERSATION_ID:-}" = "$id" ]; then
    return 0
  fi
  [ -n "$state" ] || return 1
  [ -f "$state/.lock-cursor-beat" ] || return 1
  beat_id=$(tr -d '[:space:]' < "$state/.lock-cursor-beat" 2>/dev/null || true)
  [ "$beat_id" = "$id" ] || return 1
  now=$(date +%s)
  mtime=$(stat -f %m "$state/.lock-cursor-beat" 2>/dev/null || stat -c %Y "$state/.lock-cursor-beat" 2>/dev/null) || return 1
  age=$((now - mtime))
  [ "$age" -ge 0 ] && [ "$age" -le "$FM_CURSOR_LOCK_BEAT_GRACE_SECS" ]
}

# Walk the current process ancestry (up to 8 hops) and print the first pid whose
# command looks like a verified harness. The harness pid lives as long as the
# session, unlike the transient subshell pid of any one tool call.
fm_harness_ancestry_pid() {
  local pid=$$ comm args
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if printf '%s' "$(basename -- "$comm")" | grep -qE "$FM_HARNESS_RE"; then
      echo "$pid"; return 0
    fi
    # Bare interpreter (e.g. node): match the harness name in its script path.
    case "$comm" in
      *node*|*python*) printf '%s' "$args" | grep -qE "$FM_HARNESS_RE" && { echo "$pid"; return 0; } ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

# Lock identity for this session: conversation-scoped Cursor IDE token when
# applicable, otherwise the harness ancestor PID. Cursor IDE with CURSOR_AGENT=1
# but no usable CURSOR_CONVERSATION_ID fails closed (shared Helper PIDs must not
# own the fleet lock).
fm_harness_lock_identity() {
  local tok
  if tok=$(fm_cursor_conv_token); then
    printf '%s\n' "$tok"
    return 0
  fi
  if [ "${CURSOR_AGENT:-}" = "1" ]; then
    return 1
  fi
  fm_harness_ancestry_pid
}

# True if $1 is a live process that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=$1 comm args
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  if printf '%s' "$(basename -- "$comm")" | grep -qE "$FM_HARNESS_RE"; then
    return 0
  fi
  case "$comm" in
    *node*|*python*)
      args=$(ps -o args= -p "$pid" 2>/dev/null)
      printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"
      ;;
    *) return 1 ;;
  esac
}

# True if lock token $1 is still held by a live session.
# Optional $2 is the state dir (required to evaluate cursor-conv beat liveness).
fm_harness_lock_alive() {
  local token=$1 state=${2:-}
  case "$token" in
    cursor-conv:*) fm_cursor_conv_alive "$token" "$state" ;;
    *) fm_harness_pid_alive "$token" ;;
  esac
}

# True when state dir $1 holds a session lock whose identity matches this
# process's lock identity. A missing lock, a lock held by another live harness,
# or an identity that cannot be resolved all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_id my_id
  lock_id=$(tr -d '[:space:]' < "$state/.lock" 2>/dev/null || true)
  [ -n "$lock_id" ] || return 1
  my_id=$(fm_harness_lock_identity) || return 1
  [ "$my_id" = "$lock_id" ]
}
