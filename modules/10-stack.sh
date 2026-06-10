#!/usr/bin/env bash
# modules/10-stack.sh — install/update base stack: Node (fnm), Nginx, tools.

MODULE_NAME="Stack & tools"
MODULE_ORDER=10
MODULE_COMMANDS=("stack:install" "stack:node" "stack:status")

# stack:install — install base packages (idempotent). Usually called by install.sh.
cmd_stack_install() {
  core_require_root
  log_step "Installing base packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl git jq nginx ufw fail2ban unzip openssl ca-certificates logrotate
  log_ok "Base packages installed."

  _stack_install_fnm
  log_ok "Stack is ready."
}

# Install fnm at the system level (into /usr/local/bin) so every site user can pin a Node version.
_stack_install_fnm() {
  if command -v fnm >/dev/null 2>&1; then
    log_info "fnm already present: $(fnm --version 2>/dev/null || true)"
    return 0
  fi
  log_step "Installing fnm (Node version manager)"
  curl -fsSL https://fnm.vercel.app/install | bash -s -- --install-dir /usr/local/bin --skip-shell
  if ! command -v fnm >/dev/null 2>&1; then
    # Some versions install into ~/.local/share/fnm; symlink it out.
    local f; f="$(find /root /usr/local -maxdepth 4 -name fnm -type f 2>/dev/null | head -n1 || true)"
    [[ -n "$f" ]] && ln -sf "$f" /usr/local/bin/fnm
  fi
  command -v fnm >/dev/null 2>&1 || die "Installing fnm failed."
  log_ok "fnm: $(fnm --version)"
}

# stack:node [version] — install a Node version (default LTS from defaults).
# Installs for the calling user; sites install per-user when created.
cmd_stack_node() {
  core_require_root
  local ver="${1:-${LAPN_NODE_DEFAULT:-20}}"
  log_step "Installing Node v$ver (via fnm)"
  command -v fnm >/dev/null 2>&1 || _stack_install_fnm
  # fnm needs env; call within a subshell that evals env.
  bash -lc "eval \"\$(fnm env --shell bash)\"; fnm install $ver && fnm default $ver"
  log_ok "Node v$ver installed."
}

# stack:status — print stack status.
cmd_stack_status() {
  printf '%sStack LapN%s\n' "$C_BOLD" "$C_RESET"
  printf '  Nginx   : %s\n' "$(command -v nginx >/dev/null && nginx -v 2>&1 | sed 's#nginx version: ##' || echo 'not installed')"
  printf '  fnm     : %s\n' "$(command -v fnm >/dev/null && fnm --version || echo 'not installed')"
  printf '  jq      : %s\n' "$(command -v jq >/dev/null && jq --version || echo 'not installed')"
  printf '  certbot : %s\n' "$(command -v certbot >/dev/null && certbot --version 2>&1 || echo 'not installed')"
  printf '  ufw     : %s\n' "$(command -v ufw >/dev/null && ufw status | head -n1 || echo 'not installed')"
  printf '  fail2ban: %s\n' "$(systemctl is-active fail2ban 2>/dev/null || echo 'not running')"
}

# Convenience function for other modules: install a Node version for a specific site user.
stack_install_node_for_user() {
  local user="$1" ver="$2"
  log_info "Installing Node v$ver for user $user"
  sudo -u "$user" bash -lc "
    export FNM_DIR=\"\$HOME/.local/share/fnm\"
    eval \"\$(fnm env --shell bash 2>/dev/null)\" || true
    fnm install $ver && fnm default $ver
  " || die "Installing Node v$ver for $user failed."
}
