#!/usr/bin/env bash
# lib/core.sh — bootstrap: load config, load libs, load modules, dựng registry.
# Được bin/lapn source. Không tự chạy.

# LAPN_HOME được bin/lapn export trước khi source file này.
: "${LAPN_HOME:?LAPN_HOME chưa được set}"

# --- Load config: defaults trước, override server sau ---
core_load_config() {
  # shellcheck source=/dev/null
  source "$LAPN_HOME/config/defaults.conf"
  if [[ -f "/etc/lapn/config" ]]; then
    # shellcheck source=/dev/null
    source "/etc/lapn/config"
  fi
}

# --- Load thư viện lõi ---
core_load_libs() {
  local lib
  for lib in log ui validate net state; do
    # shellcheck source=/dev/null
    source "$LAPN_HOME/lib/$lib.sh"
  done
}

# Registry: command -> "module_name|order" để dựng menu.
declare -gA LAPN_CMD_MODULE=()      # "site:create" -> "Quản lý Website"
declare -gA LAPN_MODULE_ORDER=()    # "Quản lý Website" -> 20
declare -gA LAPN_MODULE_CMDS=()     # "Quản lý Website" -> "site:create site:list ..."

# --- Load modules (tự khám phá theo prefix số) ---
core_load_modules() {
  local f base
  shopt -s nullglob
  for f in "$LAPN_HOME"/modules/[0-9]*.sh; do
    # Reset metadata trước mỗi module.
    MODULE_NAME=""; MODULE_ORDER=0; MODULE_COMMANDS=()
    # shellcheck source=/dev/null
    source "$f"
    base="$(basename "$f")"
    [[ -z "$MODULE_NAME" ]] && MODULE_NAME="$base"
    LAPN_MODULE_ORDER["$MODULE_NAME"]="${MODULE_ORDER:-99}"
    LAPN_MODULE_CMDS["$MODULE_NAME"]="${MODULE_COMMANDS[*]:-}"
    local c
    for c in "${MODULE_COMMANDS[@]:-}"; do
      [[ -n "$c" ]] && LAPN_CMD_MODULE["$c"]="$MODULE_NAME"
    done
  done
  shopt -u nullglob
}

# cmd_func_name "site:create" -> "cmd_site_create"
# Thay ':' và '-' thành '_'.
cmd_func_name() {
  local cmd="$1"
  printf 'cmd_%s' "${cmd//[:-]/_}"
}

# core_dispatch <command> [args...] — gọi hàm xử lý tương ứng.
core_dispatch() {
  local cmd="$1"; shift || true
  local fn; fn="$(cmd_func_name "$cmd")"
  if ! declare -F "$fn" >/dev/null; then
    die "Lệnh không tồn tại: '$cmd'. Gõ 'lapn help' để xem danh sách."
  fi
  audit_cmd "$cmd $*"
  "$fn" "$@"
}

# core_require_root — nhiều lệnh cần root.
core_require_root() {
  if (( EUID != 0 )); then
    die "Lệnh này cần quyền root (chạy bằng sudo)."
  fi
}

# core_bootstrap — gọi một lần ở đầu bin/lapn.
core_bootstrap() {
  core_load_config
  core_load_libs
  ui_init_interactive
  core_load_modules
}
