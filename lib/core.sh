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

# core_config_set <LAPN_KEY> <value> — persist an override into /etc/lapn/config and
# apply it to the running process. That file is sourced AFTER config/defaults.conf, so
# whatever lands here wins. The repo's defaults.conf is never edited: it is code.
core_config_set() {
  local key="$1" value="$2" cfg="${LAPN_CONFIG:-/etc/lapn/config}"
  [[ "$key" =~ ^LAPN_[A-Z0-9_]+$ ]] || { log_error "Invalid config key: '$key'"; return 1; }
  mkdir -p "$(dirname "$cfg")"
  [[ -f "$cfg" ]] || printf '# LapN config (override defaults)\n' >"$cfg"
  # Rewrite in place rather than sed-substituting: the value is not escaped for sed,
  # and keeping the original file keeps its mode/owner.
  local tmp; tmp="$(mktemp)"
  grep -vE "^${key}=" "$cfg" >"$tmp" 2>/dev/null || true
  printf '%s="%s"\n' "$key" "$value" >>"$tmp"
  cat "$tmp" >"$cfg"
  rm -f "$tmp"
  printf -v "$key" '%s' "$value"
  export "${key?}"
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
declare -gA LAPN_CMD_MODULE=()      # "site:create" -> "Site management"
declare -gA LAPN_MODULE_ORDER=()    # "Site management" -> 10
declare -gA LAPN_MODULE_CMDS=()     # "Site management" -> "site:create site:list ..."
declare -gA LAPN_MODULE_MENU=()     # "Stack" -> "stack_menu" (optional custom submenu fn)

# --- Load modules (auto-discovered by numeric prefix) ---
core_load_modules() {
  local f base
  shopt -s nullglob
  for f in "$LAPN_HOME"/modules/[0-9]*.sh; do
    # Reset metadata before each module.
    MODULE_NAME=""; MODULE_ORDER=0; MODULE_COMMANDS=(); MODULE_MENU=""
    # shellcheck source=/dev/null
    source "$f"
    base="$(basename "$f")"
    [[ -z "$MODULE_NAME" ]] && MODULE_NAME="$base"
    LAPN_MODULE_ORDER["$MODULE_NAME"]="${MODULE_ORDER:-99}"
    LAPN_MODULE_CMDS["$MODULE_NAME"]="${MODULE_COMMANDS[*]:-}"
    LAPN_MODULE_MENU["$MODULE_NAME"]="${MODULE_MENU:-}"
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
  # Separate args, not one joined string: audit_cmd has to see flag/value pairs to be
  # able to mask the values of --dbpass, --cf-token and friends.
  audit_cmd "$cmd" "$@"
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
