#!/usr/bin/env bash
# modules/10-stack.sh — cài/cập nhật stack nền: Node (fnm), Nginx, công cụ.

MODULE_NAME="Stack & công cụ"
MODULE_ORDER=10
MODULE_COMMANDS=("stack:install" "stack:node" "stack:status")

# stack:install — cài gói nền (idempotent). Thường gọi bởi install.sh.
cmd_stack_install() {
  core_require_root
  log_step "Cài gói nền"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl git jq nginx ufw fail2ban unzip openssl ca-certificates logrotate
  log_ok "Đã cài gói nền."

  _stack_install_fnm
  log_ok "Stack sẵn sàng."
}

# Cài fnm ở mức hệ thống (vào /usr/local/bin) để mọi user site pin được Node version.
_stack_install_fnm() {
  if command -v fnm >/dev/null 2>&1; then
    log_info "fnm đã có: $(fnm --version 2>/dev/null || true)"
    return 0
  fi
  log_step "Cài fnm (Node version manager)"
  curl -fsSL https://fnm.vercel.app/install | bash -s -- --install-dir /usr/local/bin --skip-shell
  if ! command -v fnm >/dev/null 2>&1; then
    # Một số phiên bản cài vào ~/.local/share/fnm; symlink ra.
    local f; f="$(find /root /usr/local -maxdepth 4 -name fnm -type f 2>/dev/null | head -n1 || true)"
    [[ -n "$f" ]] && ln -sf "$f" /usr/local/bin/fnm
  fi
  command -v fnm >/dev/null 2>&1 || die "Cài fnm thất bại."
  log_ok "fnm: $(fnm --version)"
}

# stack:node [version] — cài một Node version (mặc định LTS trong defaults).
# Cài cho user gọi; site sẽ cài per-user khi tạo.
cmd_stack_node() {
  core_require_root
  local ver="${1:-${LAPN_NODE_DEFAULT:-20}}"
  log_step "Cài Node v$ver (qua fnm)"
  command -v fnm >/dev/null 2>&1 || _stack_install_fnm
  # fnm cần env; gọi trong subshell có eval env.
  bash -lc "eval \"\$(fnm env --shell bash)\"; fnm install $ver && fnm default $ver"
  log_ok "Đã cài Node v$ver."
}

# stack:status — in trạng thái stack.
cmd_stack_status() {
  printf '%sStack LapN%s\n' "$C_BOLD" "$C_RESET"
  printf '  Nginx   : %s\n' "$(command -v nginx >/dev/null && nginx -v 2>&1 | sed 's#nginx version: ##' || echo 'chưa cài')"
  printf '  fnm     : %s\n' "$(command -v fnm >/dev/null && fnm --version || echo 'chưa cài')"
  printf '  jq      : %s\n' "$(command -v jq >/dev/null && jq --version || echo 'chưa cài')"
  printf '  certbot : %s\n' "$(command -v certbot >/dev/null && certbot --version 2>&1 || echo 'chưa cài')"
  printf '  ufw     : %s\n' "$(command -v ufw >/dev/null && ufw status | head -n1 || echo 'chưa cài')"
  printf '  fail2ban: %s\n' "$(systemctl is-active fail2ban 2>/dev/null || echo 'chưa chạy')"
}

# Hàm tiện cho module khác: cài Node version cho một user site cụ thể.
stack_install_node_for_user() {
  local user="$1" ver="$2"
  log_info "Cài Node v$ver cho user $user"
  sudo -u "$user" bash -lc "
    export FNM_DIR=\"\$HOME/.local/share/fnm\"
    eval \"\$(fnm env --shell bash 2>/dev/null)\" || true
    fnm install $ver && fnm default $ver
  " || die "Cài Node v$ver cho $user thất bại."
}
