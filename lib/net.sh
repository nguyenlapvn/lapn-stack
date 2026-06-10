#!/usr/bin/env bash
# lib/net.sh — cấp port nội bộ tự động + kiểm tra port trống.

# port_in_use <port> -> return 0 nếu đang có tiến trình nghe.
port_in_use() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}\$"
  else
    netstat -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}\$"
  fi
}

# port_taken_in_state <port> -> return 0 nếu port đã gán cho site khác trong state.
port_taken_in_state() {
  local p="$1"
  [[ -f "$LAPN_STATE" ]] || return 1
  jq -e --argjson p "$p" \
    '[.sites[]?.port] | index($p) != null' "$LAPN_STATE" >/dev/null 2>&1
}

# net_alloc_port -> in ra một port nội bộ trống trong [MIN,MAX].
# Thuật toán: max(port trong state) + 1, rồi xác minh thực tế, bận thì tăng tiếp.
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
  # Quét lại từ đầu range phòng khi có port bị xóa ở giữa.
  for (( p = min; p < start; p++ )); do
    if ! port_in_use "$p" && ! port_taken_in_state "$p"; then
      printf '%s' "$p"; return 0
    fi
  done
  return 1
}

# net_check_user_port <port> -> validate port do user chỉ định (override --port).
# Fail rõ ràng, KHÔNG tự nhảy sang port khác.
net_check_user_port() {
  local p="$1"
  validate_app_port "$p" || return 1
  if port_taken_in_state "$p"; then
    log_warn "Port $p đã được gán cho site khác (sites.json)."
    return 1
  fi
  if port_in_use "$p"; then
    log_warn "Port $p đang bị tiến trình khác chiếm (ss -tlnp)."
    return 1
  fi
  return 0
}
