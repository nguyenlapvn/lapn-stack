#!/usr/bin/env bash
# modules/60-stack.sh — install all infrastructure software in one place:
# base packages, Nginx, fnm/Node, PM2, and DB engines (mariadb/mysql/postgres/mongo/redis).
# Installing software lives here; managing databases lives in the Database module.

MODULE_NAME="Stack"
MODULE_ORDER=60
MODULE_COMMANDS=("stack:install" "stack:nginx" "stack:node" "stack:pm2" \
                 "stack:mariadb" "stack:mysql" "stack:postgres" "stack:mongo" "stack:redis" \
                 "stack:status")
# Friendly interactive submenu (CLI still uses the stack:* commands above).
MODULE_MENU="stack_menu"

# stack:install — install base packages (idempotent). Usually called by install.sh.
cmd_stack_install() {
  core_require_root
  log_step "Installing base packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  # Nginx is NOT bundled here — install it via the dedicated 'Nginx' entry (stack:nginx).
  apt-get install -y curl git jq ufw fail2ban unzip openssl ca-certificates logrotate
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

# =====================================================================
# Friendly interactive menu (invoked by bin/lapn via MODULE_MENU).
#   1) Install software  -> pick a component; if already installed, ask to reinstall
#   2) Status
# =====================================================================

# Installable components: keys + human labels (same index).
_STACK_KEYS=(base nginx node pm2 mariadb mysql postgres mongo redis)
_STACK_LABELS=(
  "Base packages (curl, git, jq, ufw, fail2ban, openssl, logrotate)"
  "Nginx"
  "Node (fnm)"
  "PM2 (process manager)"
  "MariaDB"
  "MySQL"
  "PostgreSQL"
  "MongoDB"
  "Redis"
)

# stack_is_installed <key> -> return 0 if already installed.
stack_is_installed() {
  case "$1" in
    base) return 1 ;;  # no single marker; always allow running the base install
    nginx) command -v nginx >/dev/null 2>&1 ;;
    node)  command -v fnm >/dev/null 2>&1 ;;
    pm2)   bash -lc 'eval "$(fnm env --shell bash 2>/dev/null)"; command -v pm2 >/dev/null 2>&1' ;;
    mariadb|mysql|postgres|mongo|redis) state_service_installed "$1" ;;
    *) return 1 ;;
  esac
}

# stack_do_install <key> <force> — run the matching installer (in a subshell so die() won't kill the menu).
stack_do_install() {
  local key="$1" force="$2"
  case "$key" in
    base)  ( cmd_stack_install ) ;;
    nginx) ( cmd_stack_nginx ) ;;
    node)  ( cmd_stack_node ) ;;
    pm2)   ( cmd_stack_pm2 ) ;;
    mariadb|mysql|postgres|mongo|redis)
      if [[ -n "$force" ]]; then ( cmd_db_install "$key" --force ); else ( cmd_db_install "$key" ); fi ;;
  esac || log_warn "Install finished with an error (see the message above)."
}

stack_install_menu() {
  local choice i key label
  while true; do
    lapn_clear
    printf '%s%sLapN%s › Stack › Install software\n\n' "$C_BOLD" "$C_BLUE" "$C_RESET"
    for i in "${!_STACK_KEYS[@]}"; do
      local mark="[ ]"; stack_is_installed "${_STACK_KEYS[$i]}" && mark="[${C_GREEN}x${C_RESET}]"
      printf '  %2d) %s %s\n' "$((i + 1))" "$mark" "${_STACK_LABELS[$i]}"
    done
    printf '   0) ← Back\n'
    read -r -p "→ " choice || return 0
    [[ "$choice" == "0" || -z "$choice" ]] && return 0
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#_STACK_KEYS[@]} )); then
      key="${_STACK_KEYS[$((choice - 1))]}"; label="${_STACK_LABELS[$((choice - 1))]}"
      printf '\n'
      if stack_is_installed "$key"; then
        if ui_confirm "$label is already installed. Reinstall?" N; then
          stack_do_install "$key" 1
        else
          log_info "Skipped — $label kept as is."
        fi
      else
        stack_do_install "$key" ""
      fi
      lapn_pause
    else
      log_warn "Invalid choice."; lapn_pause
    fi
  done
}

stack_menu() {
  local choice
  while true; do
    lapn_clear
    printf '%s%sLapN%s › Stack\n\n' "$C_BOLD" "$C_BLUE" "$C_RESET"
    printf '  1) Install software\n'
    printf '  2) Status\n'
    printf '  0) ← Back to main menu\n'
    read -r -p "→ " choice || return 0
    case "$choice" in
      1) stack_install_menu ;;
      2) ( cmd_stack_status ) || true; lapn_pause ;;
      0|"") return 0 ;;
      *) log_warn "Invalid choice."; lapn_pause ;;
    esac
  done
}
