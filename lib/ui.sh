#!/usr/bin/env bash
# lib/ui.sh — interactive prompts + the "flag → ask → default" mechanism.
# The input menu is the main interface but only calls back into cmd_* commands; contains no business logic.

# LAPN_INTERACTIVE: 1 if prompting is allowed (TTY), 0 if pipe/CI.
ui_init_interactive() {
  if [[ -t 0 && -t 1 ]]; then LAPN_INTERACTIVE=1; else LAPN_INTERACTIVE=0; fi
  export LAPN_INTERACTIVE
}

# ui_ask "question" [default value] -> print the value to stdout.
ui_ask() {
  local prompt="$1" default="${2:-}" ans
  if [[ -n "$default" ]]; then
    read -r -p "$(printf '%s [%s]: ' "$prompt" "$default")" ans || true
    printf '%s' "${ans:-$default}"
  else
    read -r -p "$(printf '%s: ' "$prompt")" ans || true
    printf '%s' "$ans"
  fi
}

# ui_password "question" -> read without echoing characters.
ui_password() {
  local prompt="$1" ans
  read -r -s -p "$(printf '%s: ' "$prompt")" ans || true
  printf '\n' >&2
  printf '%s' "$ans"
}

# ui_confirm "question" [Y|N default] -> return 0 if yes.
ui_confirm() {
  local prompt="$1" default="${2:-N}" ans hint
  [[ "$default" == "Y" ]] && hint="[Y/n]" || hint="[y/N]"
  read -r -p "$(printf '%s %s ' "$prompt" "$hint")" ans || true
  ans="${ans:-$default}"
  [[ "$ans" =~ ^[Yy] ]]
}

# ui_select "question" opt1 opt2 ... -> print the chosen option to stdout.
ui_select() {
  local prompt="$1"; shift
  local opts=("$@") i ans
  printf '%s\n' "$prompt" >&2
  for i in "${!opts[@]}"; do
    printf '  %s) %s\n' "$((i + 1))" "${opts[$i]}" >&2
  done
  while true; do
    read -r -p "Select [1-${#opts[@]}]: " ans || true
    if [[ "$ans" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= ${#opts[@]} )); then
      printf '%s' "${opts[$((ans - 1))]}"
      return 0
    fi
    log_warn "Invalid selection."
  done
}

# resolve_input <name> <value from flag> [--prompt "..."] [--default "..."]
#               [--validate fn] [--select "a b c"] [--password]
# Order: flag > ask (if TTY) > die. Print the value to stdout.
resolve_input() {
  local name="$1" value="$2"; shift 2
  local prompt="Enter $name" default="" validate="" choices="" is_pw=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --prompt)   prompt="$2"; shift 2 ;;
      --default)  default="$2"; shift 2 ;;
      --validate) validate="$2"; shift 2 ;;
      --select)   choices="$2"; shift 2 ;;
      --password) is_pw=1; shift ;;
      *) shift ;;
    esac
  done

  # 1) Flag present → validate then use.
  if [[ -n "$value" ]]; then
    if [[ -n "$validate" ]]; then
      "$validate" "$value" || die "Value '$value' for --$name is invalid."
    fi
    printf '%s' "$value"; return 0
  fi

  # 3) No TTY and missing → take default or die.
  if [[ "${LAPN_INTERACTIVE:-0}" != "1" ]]; then
    if [[ -n "$default" ]]; then printf '%s' "$default"; return 0; fi
    die "Missing --$name (non-interactive mode)."
  fi

  # 2) TTY → ask, validate, loop until valid.
  local ans
  while true; do
    if [[ -n "$choices" ]]; then
      # shellcheck disable=SC2086
      ans="$(ui_select "$prompt" $choices)"
    elif [[ "$is_pw" == "1" ]]; then
      ans="$(ui_password "$prompt")"
    else
      ans="$(ui_ask "$prompt" "$default")"
    fi
    if [[ -z "$ans" ]]; then log_warn "Must not be empty."; continue; fi
    if [[ -n "$validate" ]] && ! "$validate" "$ans"; then continue; fi
    printf '%s' "$ans"; return 0
  done
}

# Simple spinner that runs around a long-running command.
ui_spin() {
  local msg="$1"; shift
  if [[ "${LAPN_INTERACTIVE:-0}" != "1" ]]; then
    log_info "$msg"; "$@"; return $?
  fi
  "$@" &
  local pid=$! i=0 frames='|/-\'
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r%s %s' "${frames:i++%4:1}" "$msg"
    sleep 0.1
  done
  wait "$pid"; local rc=$?
  printf '\r\033[K'
  return $rc
}
