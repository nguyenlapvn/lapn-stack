#!/usr/bin/env bash
# modules/60-stack.sh — install all infrastructure software in one place:
# base packages, Nginx, fnm/Node, PM2, and DB engines (mariadb/mysql/postgres/mongo/redis).
# Installing software lives here; managing databases lives in the Database module.

MODULE_NAME="Stack"
MODULE_ORDER=60
MODULE_COMMANDS=("stack:install" "stack:nginx" "stack:node" "stack:pm2" \
                 "stack:mariadb" "stack:mysql" "stack:postgres" "stack:mongo" "stack:redis" \
                 "stack:status")

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

# stack:nginx — install Nginx (idempotent).
cmd_stack_nginx() {
  core_require_root
  log_step "Installing Nginx"
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y nginx
  systemctl enable --now nginx 2>/dev/null || true
  log_ok "Nginx installed."
}

# stack:pm2 — install PM2 globally via the default fnm Node (optional process manager).
# NOTE: systemd is the default per-site process manager; PM2 is opt-in and should be run
#       per site user for real use. This installs the PM2 binary only.
cmd_stack_pm2() {
  core_require_root
  command -v fnm >/dev/null 2>&1 || _stack_install_fnm
  log_step "Installing PM2 (npm -g)"
  bash -lc "eval \"\$(fnm env --shell bash 2>/dev/null)\"; npm install -g pm2" \
    || die "Installing PM2 failed."
  log_ok "PM2 installed: $(bash -lc 'eval "$(fnm env --shell bash 2>/dev/null)"; pm2 --version' 2>/dev/null || echo '?')"
}

# DB engine installers — delegate to the Database module's installer (cmd_db_install),
# so the engine software is installed from the Stack menu while DB management stays separate.
cmd_stack_mariadb()  { cmd_db_install mariadb; }
cmd_stack_mysql()    { cmd_db_install mysql; }
cmd_stack_postgres() { cmd_db_install postgres; }
cmd_stack_mongo()    { cmd_db_install mongo; }
cmd_stack_redis()    { cmd_db_install redis; }

# stack:status — print stack status.
cmd_stack_status() {
  printf '%sLapN stack%s\n' "$C_BOLD" "$C_RESET"
  printf '  Nginx   : %s\n' "$(command -v nginx >/dev/null && nginx -v 2>&1 | sed 's#nginx version: ##' || echo 'not installed')"
  printf '  fnm     : %s\n' "$(command -v fnm >/dev/null && fnm --version || echo 'not installed')"
  printf '  pm2     : %s\n' "$(bash -lc 'eval "$(fnm env --shell bash 2>/dev/null)"; command -v pm2 >/dev/null && pm2 --version' 2>/dev/null || echo 'not installed')"
  printf '  jq      : %s\n' "$(command -v jq >/dev/null && jq --version || echo 'not installed')"
  printf '  certbot : %s\n' "$(command -v certbot >/dev/null && certbot --version 2>&1 || echo 'not installed')"
  printf '  ufw     : %s\n' "$(command -v ufw >/dev/null && ufw status | head -n1 || echo 'not installed')"
  printf '  fail2ban: %s\n' "$(systemctl is-active fail2ban 2>/dev/null || echo 'not running')"
  printf '  -- DB engines --\n'
  local e svc
  for e in mariadb mysql postgres mongo redis; do
    case "$e" in
      mariadb) svc=mariadb ;; mysql) svc=mysql ;; postgres) svc=postgresql ;;
      mongo) svc=mongod ;; redis) svc=redis-server ;;
    esac
    if state_service_installed "$e"; then
      printf '  %-8s: installed (%s)\n' "$e" "$(systemctl is-active "$svc" 2>/dev/null || echo '?')"
    else
      printf '  %-8s: not installed\n' "$e"
    fi
  done
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
