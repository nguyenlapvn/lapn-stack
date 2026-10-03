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

# --- Address helpers (used by the DNS pre-flight check) ---

# net_ip_to_int <a.b.c.d> -> the address as a 32-bit integer.
net_ip_to_int() {
  local o1 o2 o3 o4 IFS=.
  read -r o1 o2 o3 o4 <<<"$1"
  printf '%s' "$(( (o1 << 24) + (o2 << 16) + (o3 << 8) + o4 ))"
}

# net_ip_in_cidr <ipv4> <a.b.c.d/bits> -> 0 when the address falls inside the range.
net_ip_in_cidr() {
  local ip="$1" cidr="$2" base bits a b mask
  base="${cidr%/*}"; bits="${cidr#*/}"
  [[ "$bits" == "$cidr" ]] && bits=32
  [[ "$ip"   =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  [[ "$base" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  [[ "$bits" =~ ^[0-9]+$ ]] && (( bits <= 32 )) || return 1
  (( bits == 0 )) && return 0
  a="$(net_ip_to_int "$ip")"; b="$(net_ip_to_int "$base")"
  mask=$(( (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
  (( (a & mask) == (b & mask) ))
}

# net_is_cloudflare_ip <addr>... -> 0 when any address belongs to Cloudflare.
# Ranges come from the realip snippet LapN already ships/refreshes, so this needs no
# network of its own. IPv4 is an exact CIDR test; IPv6 compares the leading hextet,
# which is only ever used to word a hint, never to block anything.
net_is_cloudflare_ip() {
  local snip="/etc/nginx/snippets/lapn-cloudflare-realip.conf"
  [[ -f "$snip" ]] || snip="${LAPN_HOME:-}/templates/nginx/snippets/cloudflare-realip.conf"
  [[ -f "$snip" ]] || return 1
  local ip cidr
  for ip in "$@"; do
    while read -r cidr; do
      [[ -z "$cidr" ]] && continue
      if [[ "$ip" == *:* ]]; then
        [[ "$cidr" == *:* && "${ip%%:*}" == "${cidr%%:*}" ]] && return 0
      else
        net_ip_in_cidr "$ip" "$cidr" && return 0
      fi
    done < <(awk '/^[[:space:]]*set_real_ip_from/{gsub(/;/,"",$2); print $2}' "$snip")
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
