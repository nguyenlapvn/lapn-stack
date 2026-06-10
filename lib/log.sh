#!/usr/bin/env bash
# lib/log.sh — màu terminal + audit log /var/log/lapn/actions.log
# Không chứa logic nghiệp vụ.

# --- Màu (tắt khi không phải TTY) ---
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
else
  C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_DIM=""; C_BOLD=""
fi

log_info()  { printf '%s[*]%s %s\n' "$C_BLUE"   "$C_RESET" "$*"; }
log_ok()    { printf '%s[✓]%s %s\n' "$C_GREEN"  "$C_RESET" "$*"; }
log_warn()  { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_error() { printf '%s[✗]%s %s\n' "$C_RED"    "$C_RESET" "$*" >&2; }
log_step()  { printf '\n%s==>%s %s%s%s\n' "$C_BOLD" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; }
log_dim()   { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }

# die "thông điệp" [mã thoát] — in lỗi rồi thoát.
die() {
  local msg="$1" code="${2:-1}"
  log_error "$msg"
  audit "ERROR" "$msg"
  exit "$code"
}

# audit <kết quả> <thông điệp> — ghi dòng vào actions.log (nếu ghi được).
# Định dạng: ISO8601 | invoker | uid | result | message
audit() {
  local result="$1"; shift
  local msg="$*"
  local logdir="${LAPN_LOG_DIR:-/var/log/lapn}"
  local logfile="${LAPN_LOG:-$logdir/actions.log}"
  local invoker="${SUDO_USER:-${USER:-unknown}}"
  local ts; ts="$(date -Iseconds 2>/dev/null || date)"
  # Không để lỗi log làm chết lệnh chính.
  { [[ -d "$logdir" ]] || mkdir -p "$logdir" 2>/dev/null; } || return 0
  printf '%s | %s | uid=%s | %s | %s\n' \
    "$ts" "$invoker" "$(id -u 2>/dev/null || echo '?')" "$result" "$msg" \
    >>"$logfile" 2>/dev/null || true
}

# audit_cmd "lệnh đang chạy" — tiện log mở đầu một action.
audit_cmd() { audit "RUN" "$*"; }
