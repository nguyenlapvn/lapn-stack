#!/usr/bin/env bash
# modules/60-stack.sh — install all infrastructure software in one place:
# base packages, Nginx, fnm/Node, PM2, and DB engines (mariadb/postgres/mongo/redis).
# Installing software lives here; managing databases lives in the Database module.

MODULE_NAME="Stack"
MODULE_ORDER=60
MODULE_COMMANDS=("stack:install" "stack:nginx" "stack:node" "stack:pm2" \
                 "stack:mariadb" "stack:postgres" "stack:mongo" "stack:redis" \
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
  # (install.sh does install nginx, because it configures the base vhosts right away.)
  apt-get install -y curl git jq ufw fail2ban unzip openssl ca-certificates logrotate ssl-cert
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

# stack:node [version] [--default]
# Install a Node version via fnm for the invoking user (root) — this is the Node that
# `stack:pm2` and manual work use. Sites install their own pinned version per site user.
# --default also writes LAPN_NODE_DEFAULT to /etc/lapn/config, i.e. the version NEW
# sites get. Existing sites keep their pin; use `site:node` to move one of those.
cmd_stack_node() {
  core_require_root
  local ver="" set_default=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --default) set_default=1; shift ;;
      *) [[ -z "$ver" ]] && ver="$1"; shift ;;
    esac
  done
  ver="$(resolve_input "node" "$ver" --prompt "Node version to install" \
    --default "${LAPN_NODE_DEFAULT:-24}" --validate validate_node_version)"

  log_step "Installing Node v$ver (via fnm)"
  command -v fnm >/dev/null 2>&1 || _stack_install_fnm
  # fnm needs env; call within a subshell that evals env. Checked explicitly rather
  # than relying on set -e, which is suppressed when a caller uses `cmd_stack_node ||`.
  bash -lc "eval \"\$(fnm env --shell bash)\"; fnm install $ver && fnm default $ver" \
    || { log_error "Installing Node v$ver failed."; return 1; }
  log_ok "Node v$ver installed and set as the fnm default for this user."

  # Offer it as the server-wide default for new sites.
  if [[ -z "$set_default" && "$ver" != "${LAPN_NODE_DEFAULT:-}" && "${LAPN_INTERACTIVE:-0}" == "1" ]]; then
    ui_confirm "Make Node v$ver the default for NEW sites (currently v${LAPN_NODE_DEFAULT:-24})?" Y \
      && set_default=1
  fi
  if [[ -n "$set_default" ]]; then
    core_config_set LAPN_NODE_DEFAULT "$ver" || return 1
    audit "OK" "stack:node default=$ver"
    log_ok "New sites will be created with Node v$ver (LAPN_NODE_DEFAULT in /etc/lapn/config)."
    log_dim "Existing sites keep their pinned version — move one with: lapn site:node --domain <d> --node $ver"
  fi
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
  # fnm on its own ships no npm: a Node version has to be installed AND set as the
  # default before `fnm env` puts node/npm on PATH. Install it instead of failing with
  # a bare "npm: command not found".
  if ! _stack_node_ready; then
    log_info "No Node version is active for this user — installing the default first."
    cmd_stack_node || die "Installing PM2 failed: could not install Node."
  fi
  log_step "Installing PM2 (npm -g)"
  bash -lc "eval \"\$(fnm env --shell bash 2>/dev/null)\"; npm install -g pm2" \
    || die "Installing PM2 failed."
  log_ok "PM2 installed: $(bash -lc 'eval "$(fnm env --shell bash 2>/dev/null)"; pm2 --version' 2>/dev/null || echo '?')"
}

# True when a Node version is installed AND selected as the fnm default, i.e. a fresh
# login shell really gets node/npm. `command -v fnm` alone proves none of that.
_stack_node_ready() {
  bash -lc 'eval "$(fnm env --shell bash 2>/dev/null)"; command -v node >/dev/null 2>&1' 2>/dev/null
}

# DB engine installers — delegate to the Database module's installer (cmd_db_install),
# so the engine software is installed from the Stack menu while DB management stays separate.
cmd_stack_mariadb()  { cmd_db_install mariadb; }
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
  for e in mariadb postgres mongo redis; do
    case "$e" in
      mariadb) svc=mariadb ;; postgres) svc=postgresql ;;
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
# Returns non-zero instead of calling die() so the caller can roll back first.
stack_install_node_for_user() {
  local user="$1" ver="$2"
  log_info "Installing Node v$ver for user $user"
  sudo -u "$user" bash -lc "
    export FNM_DIR=\"\$HOME/.local/share/fnm\"
    eval \"\$(fnm env --shell bash 2>/dev/null)\" || true
    fnm install $ver && fnm default $ver
  " || { log_error "Installing Node v$ver for $user failed."; return 1; }
}

# =====================================================================
# Friendly interactive menu (invoked by bin/lapn via MODULE_MENU).
#   1) Install software  -> pick a component; if already installed, ask to reinstall
#   2) Status
# =====================================================================

# Installable components: keys + human labels (same index).
_STACK_KEYS=(base nginx node pm2 mariadb postgres mongo redis)
_STACK_LABELS=(
  "Base packages (curl, git, jq, ufw, fail2ban, openssl, logrotate, fnm)"
  "Nginx"
  "Node (fnm)"   # version is asked for; manage versions in Stack > Node
  "PM2 (process manager)"
  "MariaDB"
  "PostgreSQL"
  "MongoDB"
  "Redis"
)

# stack_is_installed <key> -> return 0 if already installed.
stack_is_installed() {
  case "$1" in
    base) return 1 ;;  # no single marker; always allow running the base install
    nginx) command -v nginx >/dev/null 2>&1 ;;
    # NOT `command -v fnm`: the base install ships fnm, which would mark Node as done
    # while no Node version exists — and then PM2 dies on "npm: command not found".
    node)  _stack_node_ready ;;
    pm2)   bash -lc 'eval "$(fnm env --shell bash 2>/dev/null)"; command -v pm2 >/dev/null 2>&1' ;;
    mariadb|postgres|mongo|redis) state_service_installed "$1" ;;
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
    mariadb|postgres|mongo|redis)
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
    printf '  2) Node versions  %s(default for new sites: v%s)%s\n' \
      "$C_DIM" "${LAPN_NODE_DEFAULT:-24}" "$C_RESET"
    printf '  3) Status\n'
    printf '  0) ← Back to main menu\n'
    read -r -p "→ " choice || return 0
    case "$choice" in
      1) stack_install_menu ;;
      2) stack_node_menu ;;
      3) ( cmd_stack_status ) || true; lapn_pause ;;
      0|"") return 0 ;;
      *) log_warn "Invalid choice."; lapn_pause ;;
    esac
  done
}

# Node versions installed for the invoking user (root), as fnm reports them.
_stack_node_list() {
  bash -lc 'eval "$(fnm env --shell bash 2>/dev/null)"; fnm list 2>/dev/null' 2>/dev/null || true
}

# Stack > Node. Two different things live here on purpose: the default applies to sites
# created FROM NOW ON, while every existing site keeps the version it was pinned to.
stack_node_menu() {
  local choice line found
  while true; do
    lapn_clear
    printf '%s%sLapN%s › Stack › Node\n\n' "$C_BOLD" "$C_BLUE" "$C_RESET"
    printf '  Default for NEW sites : %s%s%s\n' \
      "$C_BOLD" "v${LAPN_NODE_DEFAULT:-24}" "$C_RESET"
    printf '  Installed for root    :\n'
    found=""
    while IFS= read -r line; do
      [[ -z "${line//[[:space:]]/}" ]] && continue
      printf '      %s\n' "$line"; found=1
    done < <(_stack_node_list)
    [[ -z "$found" ]] && printf '      %s(none yet — install one below)%s\n' "$C_DIM" "$C_RESET"
    printf '\n'
    printf '  1) Install a Node version\n'
    printf '  2) Set the default for NEW sites\n'
    printf '  3) Switch an EXISTING site to another version\n'
    printf '  0) ← Back\n'
    read -r -p "→ " choice || return 0
    printf '\n'
    case "$choice" in
      1) ( cmd_stack_node ) || log_warn "Finished with an error (see above)."; lapn_pause ;;
      # Not a subshell: core_config_set also updates the value in this process, which is
      # what makes the header above refresh without restarting lapn.
      2) stack_set_default_node || true; lapn_pause ;;
      3) ( cmd_site_list ) || true
         printf '\n'
         ( core_dispatch "site:node" ) || log_warn "Finished with an error (see above)."
         lapn_pause ;;
      0|"") return 0 ;;
      *) log_warn "Invalid choice."; lapn_pause ;;
    esac
  done
}

# Ask for and persist LAPN_NODE_DEFAULT. Existing sites are deliberately untouched.
stack_set_default_node() {
  if (( EUID != 0 )); then
    log_error "Changing the default needs root (sudo)."
    return 1
  fi
  local cur="${LAPN_NODE_DEFAULT:-24}" ver
  ver="$(resolve_input "node" "" --prompt "Default Node version for NEW sites" \
    --default "$cur" --validate validate_node_version)"
  if [[ "$ver" == "$cur" ]]; then
    log_info "Already v$cur — nothing changed."
    return 0
  fi
  core_config_set LAPN_NODE_DEFAULT "$ver" || return 1
  audit "OK" "stack:node default=$ver"
  log_ok "New sites will be created with Node v$ver."
  _stack_node_ready || log_warn "Note: root itself has no Node yet — use '1) Install a Node version' if you want pm2."
  log_dim "Existing sites keep their pin — move one with '3) Switch an EXISTING site'."
}
