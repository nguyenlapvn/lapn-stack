#!/usr/bin/env bash
# lib/net.sh — automatic internal port allocation + free port check.

# port_in_use <port> -> return 0 if a process is currently listening.
port_in_use() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}\$"
  else
    netstat -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}\$"
  fi
}

# port_taken_in_state <port> -> return 0 if the port is already assigned to another site in state.
port_taken_in_state() {
  local p="$1"
  [[ -f "$LAPN_STATE" ]] || return 1
  jq -e --argjson p "$p" \
    '[.sites[]?.port] | index($p) != null' "$LAPN_STATE" >/dev/null 2>&1
}

# net_alloc_port -> print a free internal port in [MIN,MAX].
# Algorithm: max(port in state) + 1, then verify for real, increment further if busy.
net_alloc_port() {
  local min="${LAPN_PORT_MIN:-3001}" max="${LAPN_PORT_MAX:-3999}"
  local start="$min" highest
  if [[ -f "$LAPN_STATE" ]]; then
    highest="$(jq -r '[.sites[]?.port] | max // empty' "$LAPN_STATE" 2>/dev/null || true)"
    if [[ -n "$highest" && "$highest" =~ ^[0-9]+$ ]]; then
      start=$(( highest + 1 ))
    fi
  fi
  (( start < min )) && start="$min"
  local p
  for (( p = start; p <= max; p++ )); do
    if ! port_in_use "$p" && ! port_taken_in_state "$p"; then
      printf '%s' "$p"; return 0
    fi
  done
  # Scan again from the start of the range in case a port was deleted in the middle.
  for (( p = min; p < start; p++ )); do
    if ! port_in_use "$p" && ! port_taken_in_state "$p"; then
      printf '%s' "$p"; return 0
    fi
  done
  return 1
}

# net_check_user_port <port> -> validate a user-specified port (override --port).
# Fail explicitly, do NOT automatically jump to another port.
net_check_user_port() {
  local p="$1"
  validate_app_port "$p" || return 1
  if port_taken_in_state "$p"; then
    log_warn "Port $p is already assigned to another site (sites.json)."
    return 1
  fi
  if port_in_use "$p"; then
    log_warn "Port $p is currently held by another process (ss -tlnp)."
    return 1
  fi
  return 0
}
