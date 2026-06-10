#!/usr/bin/env bash
# lib/core.sh — bootstrap: load config, load libs, load modules, build the registry.
# Sourced by bin/lapn. Does not run on its own.

# LAPN_HOME is exported by bin/lapn before this file is sourced.
: "${LAPN_HOME:?LAPN_HOME is not set}"

# --- Load config: defaults first, server overrides after ---
core_load_config() {
  # shellcheck source=/dev/null
  source "$LAPN_HOME/config/defaults.conf"
  if [[ -f "/etc/lapn/config" ]]; then
    # shellcheck source=/dev/null
    source "/etc/lapn/config"
  fi
}

# --- Load core libraries ---
core_load_libs() {
  local lib
  for lib in log ui validate net state; do
    # shellcheck source=/dev/null
    source "$LAPN_HOME/lib/$lib.sh"
  done
}

# Registry: command -> "module_name|order" to build the menu.
declare -gA LAPN_CMD_MODULE=()      # "site:create" -> "Website Management"
declare -gA LAPN_MODULE_ORDER=()    # "Website Management" -> 20
declare -gA LAPN_MODULE_CMDS=()     # "Website Management" -> "site:create site:list ..."

# --- Load modules (auto-discovered by numeric prefix) ---
core_load_modules() {
  local f base
  shopt -s nullglob
  for f in "$LAPN_HOME"/modules/[0-9]*.sh; do
    # Reset metadata before each module.
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
# Replace ':' and '-' with '_'.
cmd_func_name() {
  local cmd="$1"
  printf 'cmd_%s' "${cmd//[:-]/_}"
}

# core_dispatch <command> [args...] — call the corresponding handler function.
core_dispatch() {
  local cmd="$1"; shift || true
  local fn; fn="$(cmd_func_name "$cmd")"
  if ! declare -F "$fn" >/dev/null; then
    die "Command does not exist: '$cmd'. Type 'lapn help' to see the list."
  fi
  audit_cmd "$cmd $*"
  "$fn" "$@"
}

# core_require_root — many commands need root.
core_require_root() {
  if (( EUID != 0 )); then
    die "This command needs root permission (run with sudo)."
  fi
}

# core_bootstrap — call once at the start of bin/lapn.
core_bootstrap() {
  core_load_config
  core_load_libs
  ui_init_interactive
  core_load_modules
}
