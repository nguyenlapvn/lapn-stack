#!/usr/bin/env bash
# lib/ui.sh — hỏi đáp tương tác + cơ chế "flag → hỏi → mặc định".
# Menu nhập liệu là mặt chính nhưng chỉ gọi lại các lệnh cmd_*; không chứa logic nghiệp vụ.

# LAPN_INTERACTIVE: 1 nếu được phép hỏi (TTY), 0 nếu pipe/CI.
ui_init_interactive() {
  if [[ -t 0 && -t 1 ]]; then LAPN_INTERACTIVE=1; else LAPN_INTERACTIVE=0; fi
  export LAPN_INTERACTIVE
}

# ui_ask "câu hỏi" [giá trị mặc định] -> in giá trị ra stdout.
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

# ui_password "câu hỏi" -> đọc không hiện ký tự.
ui_password() {
  local prompt="$1" ans
  read -r -s -p "$(printf '%s: ' "$prompt")" ans || true
  printf '\n' >&2
  printf '%s' "$ans"
}

# ui_confirm "câu hỏi" [Y|N mặc định] -> return 0 nếu yes.
ui_confirm() {
  local prompt="$1" default="${2:-N}" ans hint
  [[ "$default" == "Y" ]] && hint="[Y/n]" || hint="[y/N]"
  read -r -p "$(printf '%s %s ' "$prompt" "$hint")" ans || true
  ans="${ans:-$default}"
  [[ "$ans" =~ ^[Yy] ]]
}

# ui_select "câu hỏi" opt1 opt2 ... -> in option được chọn ra stdout.
ui_select() {
  local prompt="$1"; shift
  local opts=("$@") i ans
  printf '%s\n' "$prompt" >&2
  for i in "${!opts[@]}"; do
    printf '  %s) %s\n' "$((i + 1))" "${opts[$i]}" >&2
  done
  while true; do
    read -r -p "Chọn [1-${#opts[@]}]: " ans || true
    if [[ "$ans" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= ${#opts[@]} )); then
      printf '%s' "${opts[$((ans - 1))]}"
      return 0
    fi
    log_warn "Lựa chọn không hợp lệ."
  done
}

# resolve_input <tên> <giá trị từ flag> [--prompt "..."] [--default "..."]
#               [--validate fn] [--select "a b c"] [--password]
# Thứ tự: flag > hỏi (nếu TTY) > die. In giá trị ra stdout.
resolve_input() {
  local name="$1" value="$2"; shift 2
  local prompt="Nhập $name" default="" validate="" choices="" is_pw=0
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

  # 1) Có flag → validate rồi dùng.
  if [[ -n "$value" ]]; then
    if [[ -n "$validate" ]]; then
      "$validate" "$value" || die "Giá trị '$value' cho --$name không hợp lệ."
    fi
    printf '%s' "$value"; return 0
  fi

  # 3) Không TTY mà thiếu → lấy default hoặc die.
  if [[ "${LAPN_INTERACTIVE:-0}" != "1" ]]; then
    if [[ -n "$default" ]]; then printf '%s' "$default"; return 0; fi
    die "Thiếu --$name (chế độ không tương tác)."
  fi

  # 2) TTY → hỏi, validate, lặp tới khi hợp lệ.
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
    if [[ -z "$ans" ]]; then log_warn "Không được để trống."; continue; fi
    if [[ -n "$validate" ]] && ! "$validate" "$ans"; then continue; fi
    printf '%s' "$ans"; return 0
  done
}

# Spinner đơn giản chạy quanh một lệnh dài.
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
