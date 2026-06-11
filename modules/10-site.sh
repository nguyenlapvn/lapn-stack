#!/usr/bin/env bash
# modules/10-site.sh — site lifecycle + deploy: create / list / info / delete / deploy.

MODULE_NAME="Site management"
MODULE_ORDER=10
MODULE_COMMANDS=("site:create" "site:list" "site:info" "site:delete" \
                 "deploy:git" "deploy:rebuild" "deploy:restart" "deploy:logs")

# --- Rollback stack: push undo commands, run them in reverse on failure ---
declare -a _SITE_UNDO=()
_undo_push() { _SITE_UNDO+=("$1"); }
_undo_run() {
  local i
  for (( i=${#_SITE_UNDO[@]}-1; i>=0; i-- )); do
    log_dim "rollback: ${_SITE_UNDO[$i]}"
    eval "${_SITE_UNDO[$i]}" || true
  done
  _SITE_UNDO=()
}
_undo_clear() { _SITE_UNDO=(); }

# Parse --key value into ARG_<KEY> variables.
_parse_args() {
  ARG_DOMAIN=""; ARG_TYPE=""; ARG_NODE=""; ARG_PORT=""; ARG_GIT=""; ARG_DB=""; ARG_FORCE=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain) ARG_DOMAIN="$2"; shift 2 ;;
      --type)   ARG_TYPE="$2"; shift 2 ;;
      --node)   ARG_NODE="$2"; shift 2 ;;
      --port)   ARG_PORT="$2"; shift 2 ;;
      --git)    ARG_GIT="$2"; shift 2 ;;
      --db)     ARG_DB="$2"; shift 2 ;;
      --force)  ARG_FORCE=1; shift ;;
      *) shift ;;
    esac
  done
}

cmd_site_create() {
  core_require_root
  _parse_args "$@"
  load_adapter_interface

  # 1) domain
  local domain; domain="$(resolve_input "domain" "$ARG_DOMAIN" \
    --prompt "Domain (e.g.: app.example.vn)" --validate validate_domain)"
  state_site_exists "$domain" && die "Site '$domain' already exists."

  # 2) type
  local type; type="$(resolve_input "type" "$ARG_TYPE" \
    --prompt "App type" --select "nextjs express static" --validate validate_app_type)"

  # 3) node version (not required for static but still asked for consistency)
  local node; node="$(resolve_input "node" "$ARG_NODE" \
    --prompt "Node version" --default "${LAPN_NODE_DEFAULT:-20}")"

  # 4) name, port, user
  local name; name="$(slugify_domain "$domain")"
  local user="site_${name}"
  user="${user:0:32}"   # limit Linux user name length
  local port
  if [[ -n "$ARG_PORT" ]]; then
    # Explicit --port: validate, never silently fall back to another port.
    net_check_user_port "$ARG_PORT" || die "Port --port=$ARG_PORT cannot be used."
    port="$ARG_PORT"
  else
    # Auto-pick the lowest free internal port as the suggested default.
    local auto; auto="$(net_alloc_port)" \
      || die "No free port available in range ${LAPN_PORT_MIN}-${LAPN_PORT_MAX}."
    if [[ "${LAPN_INTERACTIVE:-0}" == "1" ]]; then
      # Ask, defaulting to auto. Press Enter to accept auto, or type a custom port.
      while true; do
        local input; input="$(ui_ask "Internal app port (Enter = auto $auto)" "$auto")"
        if [[ "$input" == "$auto" ]]; then port="$auto"; break; fi
        if net_check_user_port "$input"; then port="$input"; break; fi
        # invalid -> ask again
      done
    else
      port="$auto"
    fi
  fi

  # Warn about DNS if it does not point to the server yet.
  _site_warn_dns "$domain"

  log_step "Creating site $domain (type=$type, port=$port, user=$user)"

  # 5) user + directories + secrets + .env
  local home="${LAPN_SITES_HOME}/${name}"
  local secrets="${LAPN_SECRETS}/${name}"
  local appdir="${home}/app"

  if ! id "$user" >/dev/null 2>&1; then
    useradd --system -m -d "$home" -s /usr/sbin/nologin "$user" \
      || die "Creating user $user failed."
    _undo_push "userdel -r '$user' 2>/dev/null"
  fi
  mkdir -p "$appdir" "${home}/logs" "$secrets"
  chmod 750 "$home"
  chmod 700 "$secrets"
  _undo_push "rm -rf '$home' '$secrets'"

  # .env from template
  local envfile="${secrets}/.env"
  sed -e "s#{{DOMAIN}}#${domain}#g" \
      -e "s#{{NAME}}#${name}#g" \
      -e "s#{{PORT}}#${port}#g" \
      "$LAPN_HOME/templates/env/site.env.tpl" >"$envfile"
  # adapter env defaults
  SITE_DOMAIN="$domain" SITE_NAME="$name" SITE_USER="$user" SITE_ROOT="$appdir" \
    SITE_PORT="$port" SITE_NODE="$node"
  export SITE_DOMAIN SITE_NAME SITE_USER SITE_ROOT SITE_PORT SITE_NODE
  load_adapter "$type"
  adapter_env_defaults >>"$envfile"
  chown -R "$user:$user" "$home"
  chown root:root "$secrets"; chmod 600 "$envfile"
  # symlink .env into app dir
  ln -sf "$envfile" "${appdir}/.env"

  # 5b) DB (optional)
  if [[ -n "$ARG_DB" ]] || { [[ "${LAPN_INTERACTIVE:-0}" == "1" ]] && ui_confirm "Attach database to site?"; }; then
    _site_attach_db "$domain" "$name" "$user" "$envfile" "$ARG_DB"
  fi

  # 6) git clone + build (optional)
  local git_url="$ARG_GIT"
  if [[ -z "$git_url" && "${LAPN_INTERACTIVE:-0}" == "1" ]]; then
    git_url="$(ui_ask "Git repo (leave empty to deploy manually later)")"
  fi
  if [[ -n "$git_url" ]]; then
    log_step "Clone $git_url"
    sudo -u "$user" git clone "$git_url" "$appdir" 2>/dev/null \
      || sudo -u "$user" bash -c "cd '$appdir' && git clone '$git_url' ." \
      || { _undo_run; die "git clone failed."; }
    # Install Node for the user then build (npm ci + build if a build script exists).
    stack_install_node_for_user "$user" "$node"
    log_step "Build app"
    sudo -u "$user" bash -lc "
      export FNM_DIR=\"\$HOME/.local/share/fnm\"; eval \"\$(fnm env --shell bash 2>/dev/null)\" || true
      cd '$appdir' || exit 1
      npm ci || exit 1
      if jq -e '.scripts.build' package.json >/dev/null 2>&1; then npm run build || exit 1; fi
    " || { _undo_run; die "Build failed."; }
  fi

  # 7) systemd unit (except static) + 8) health check
  if adapter_needs_unit; then
    _site_render_unit "$domain" "$name" "$user" "$appdir" "$envfile" "$port"
    systemctl daemon-reload
    systemctl enable --now "lapn-${name}.service" \
      || { _undo_run; die "Starting unit failed — see: journalctl -u lapn-${name}"; }
    _undo_push "systemctl disable --now lapn-${name}.service 2>/dev/null; rm -f /etc/systemd/system/lapn-${name}.service; systemctl daemon-reload"
    _site_health_check "$port" "$(adapter_health_url)" \
      || log_warn "Health check did not pass — the app may need more configuration. Check journalctl -u lapn-${name}"
  fi

  # 9) nginx conf
  _site_render_nginx "$domain" "$name" "$type" "$port" "$appdir"
  nginx -t || { _undo_run; die "nginx -t error."; }
  systemctl reload nginx
  _undo_push "rm -f /etc/nginx/sites-enabled/lapn-${name}.conf /etc/nginx/sites-available/lapn-${name}.conf; systemctl reload nginx 2>/dev/null"

  # 11) write state
  local obj
  obj="$(jq -n \
    --arg name "$name" --arg type "$type" --argjson port "$port" \
    --arg node "$node" --arg user "$user" --arg root "$appdir" \
    --arg created "$(date -Iseconds)" \
    '{name:$name, type:$type, port:$port, node_version:$node, user:$user,
      root:$root, ssl:false, ssl_method:null, behind_cloudflare:false,
      db:[], created_at:$created}')"
  state_site_put "$domain" "$obj"

  _undo_clear
  audit "OK" "site:create $domain"

  # 10) SSL (optional, after writing state so the ssl module can read it)
  if [[ "${LAPN_INTERACTIVE:-0}" == "1" ]] && ui_confirm "Install SSL now for $domain?" Y; then
    core_dispatch "ssl:issue" --domain "$domain"
  fi

  # 12) summary
  _site_summary "$domain"
}

# --- Helpers ---

load_adapter_interface() {
  # shellcheck source=/dev/null
  source "$LAPN_HOME/adapters/_interface.sh"
}

_site_warn_dns() {
  local domain="$1" server_ip resolved
  server_ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  resolved="$(getent hosts "$domain" 2>/dev/null | awk '{print $1}' | head -n1 || true)"
  if [[ -n "$server_ip" && -n "$resolved" && "$server_ip" != "$resolved" ]]; then
    log_warn "DNS for $domain ($resolved) does not point to the server IP ($server_ip) yet. SSL HTTP-01 will fail until it points correctly."
  fi
}

_site_render_unit() {
  local domain="$1" name="$2" user="$3" appdir="$4" envfile="$5" port="$6"
  local exec_start; exec_start="$(adapter_start_cmd)"
  [[ -z "$exec_start" ]] && die "adapter did not return ExecStart for $domain."
  local unit="/etc/systemd/system/lapn-${name}.service"
  sed -e "s#{{DOMAIN}}#${domain}#g" \
      -e "s#{{NAME}}#${name}#g" \
      -e "s#{{USER}}#${user}#g" \
      -e "s#{{WORKDIR}}#${appdir}#g" \
      -e "s#{{ENVFILE}}#${envfile}#g" \
      -e "s#{{PORT}}#${port}#g" \
      -e "s#{{EXEC_START}}#${exec_start}#g" \
      -e "s#{{MEMORY_MAX}}#${LAPN_MEMORY_MAX:-512M}#g" \
      -e "s#{{CPU_QUOTA}}#${LAPN_CPU_QUOTA:-80%}#g" \
      "$LAPN_HOME/templates/systemd/lapn-site@.service.tpl" >"$unit"
}

_site_health_check() {
  local port="$1" path="$2" i
  for i in $(seq 1 10); do
    if curl -fsS --max-time 3 "http://127.0.0.1:${port}${path}" >/dev/null 2>&1; then
      log_ok "Health check OK (127.0.0.1:${port})"
      return 0
    fi
    sleep 1
  done
  return 1
}

_site_render_nginx() {
  local domain="$1" name="$2" type="$3" port="$4" appdir="$5"
  local avail="/etc/nginx/sites-available/lapn-${name}.conf"
  local enabled="/etc/nginx/sites-enabled/lapn-${name}.conf"
  local cf_include=""   # default no CF (site:create does not enable CF yet)

  if [[ "$type" == "static" ]]; then
    local root; root="$(adapter_static_root)"
    sed -e "s#{{DOMAIN}}#${domain}#g" \
        -e "s#{{ROOT}}#${root}#g" \
        -e "s#{{CLIENT_MAX_BODY}}#${LAPN_CLIENT_MAX_BODY:-10m}#g" \
        -e "s#{{CF_REALIP_INCLUDE}}#${cf_include}#g" \
        "$LAPN_HOME/templates/nginx/static.conf.tpl" >"$avail"
  else
    sed -e "s#{{DOMAIN}}#${domain}#g" \
        -e "s#{{PORT}}#${port}#g" \
        -e "s#{{CLIENT_MAX_BODY}}#${LAPN_CLIENT_MAX_BODY:-10m}#g" \
        -e "s#{{CF_REALIP_INCLUDE}}#${cf_include}#g" \
        "$LAPN_HOME/templates/nginx/proxy.conf.tpl" >"$avail"
  fi
  ln -sf "$avail" "$enabled"
}

_site_attach_db() {
  local domain="$1" name="$2" user="$3" envfile="$4" engine="$5"
  if [[ -z "$engine" ]]; then
    engine="$(resolve_input "engine" "" --prompt "DB engine" \
      --select "mariadb postgres mongo redis" --validate validate_db_engine)"
  fi
  if ! declare -F cmd_db_create >/dev/null; then
    log_warn "DB module not available — skipping the attach DB step."
    return 0
  fi
  if ! state_service_installed "$engine"; then
    if ui_confirm "Engine '$engine' is not installed. Install now?" Y; then
      core_dispatch "db:install" "$engine"
    else
      log_warn "Skipping attach DB (engine not installed)."
      return 0
    fi
  fi
  core_dispatch "db:create" --site "$domain" --engine "$engine"
}

_site_summary() {
  local domain="$1"
  local name port user root ssl
  name="$(state_site_get "$domain" name)"
  port="$(state_site_get "$domain" port)"
  user="$(state_site_get "$domain" user)"
  root="$(state_site_get "$domain" root)"
  ssl="$(state_site_get "$domain" ssl)"
  local scheme="http"; [[ "$ssl" == "true" ]] && scheme="https"
  printf '\n%s%s✓ Site %s is ready%s\n' "$C_GREEN" "$C_BOLD" "$domain" "$C_RESET"
  printf '  URL      : %s://%s\n' "$scheme" "$domain"
  printf '  Internal port : 127.0.0.1:%s\n' "$port"
  printf '  User     : %s\n' "$user"
  printf '  App dir  : %s\n' "$root"
  printf '  .env     : %s/secrets/%s/.env\n' "${LAPN_ETC}" "$name"
  printf '  Log      : journalctl -u lapn-%s -f\n' "$name"
}

# --- list ---
cmd_site_list() {
  state_init
  local count; count="$(state_jq -r '.sites | length')"
  if [[ "$count" == "0" ]]; then log_info "No site yet."; return 0; fi
  printf '%s%-32s %-9s %-6s %-5s %s%s\n' "$C_BOLD" "DOMAIN" "TYPE" "PORT" "SSL" "STATUS" "$C_RESET"
  local domain
  while IFS= read -r domain; do
    local type port ssl name status
    type="$(state_site_get "$domain" type)"
    port="$(state_site_get "$domain" port)"
    ssl="$(state_site_get "$domain" ssl)"
    name="$(state_site_get "$domain" name)"
    if [[ "$type" == "static" ]]; then
      status="static"
    else
      status="$(systemctl is-active "lapn-${name}.service" 2>/dev/null || echo '?')"
    fi
    local sslmark="no"; [[ "$ssl" == "true" ]] && sslmark="yes"
    printf '%-32s %-9s %-6s %-5s %s\n' "$domain" "$type" "$port" "$sslmark" "$status"
  done < <(state_sites_list)
}

# --- info ---
cmd_site_info() {
  _parse_args "$@"
  state_init
  local domain; domain="$(resolve_input "domain" "$ARG_DOMAIN" \
    --prompt "Domain" --validate validate_domain)"
  state_site_exists "$domain" || die "No site '$domain'."
  printf '%s%s%s\n' "$C_BOLD" "$domain" "$C_RESET"
  state_site_get "$domain" | jq .
  local name; name="$(state_site_get "$domain" name)"
  printf '\nsystemd: %s\n' "$(systemctl is-active "lapn-${name}.service" 2>/dev/null || echo 'n/a')"
}

# --- delete ---
cmd_site_delete() {
  core_require_root
  _parse_args "$@"
  state_init
  local domain; domain="$(resolve_input "domain" "$ARG_DOMAIN" \
    --prompt "Domain to delete" --validate validate_domain)"
  state_site_exists "$domain" || die "No site '$domain'."

  local name; name="$(state_site_get "$domain" name)"
  local user; user="$(state_site_get "$domain" user)"
  local home="${LAPN_SITES_HOME}/${name}"

  if [[ -z "$ARG_FORCE" ]]; then
    local confirm
    confirm="$(ui_ask "Type the domain again to confirm DELETE")"
    [[ "$confirm" == "$domain" ]] || die "Confirmation does not match — aborting."
  fi

  log_step "Deleting site $domain"

  # Drop databases attached to this site (from top-level .databases).
  if declare -F cmd_db_drop >/dev/null; then
    while IFS=$'\t' read -r e n; do
      [[ -z "$e" || "$e" == "redis" ]] && continue
      cmd_db_drop --engine "$e" --dbname "$n" --force || log_warn "Drop DB $n ($e) error (skipped)."
    done < <(state_jq -r --arg d "$domain" '(.databases // [])[] | select(.site==$d) | "\(.engine)\t\(.name)"' 2>/dev/null || true)
  fi

  # stop unit
  systemctl disable --now "lapn-${name}.service" 2>/dev/null || true
  rm -f "/etc/systemd/system/lapn-${name}.service"
  systemctl daemon-reload

  # nginx
  rm -f "/etc/nginx/sites-enabled/lapn-${name}.conf" "/etc/nginx/sites-available/lapn-${name}.conf"
  systemctl reload nginx 2>/dev/null || true

  # revoke cert (ask)
  if command -v certbot >/dev/null 2>&1; then
    if [[ -n "$ARG_FORCE" ]] || ui_confirm "Revoke SSL cert for $domain?"; then
      certbot delete --cert-name "$domain" --non-interactive 2>/dev/null || true
    fi
  fi

  # quick backup to trash
  mkdir -p "$LAPN_TRASH"
  local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
  if [[ -d "$home" ]]; then
    tar -czf "${LAPN_TRASH}/${name}-${stamp}.tar.gz" -C "$LAPN_SITES_HOME" "$name" 2>/dev/null || true
    log_info "Quick backup: ${LAPN_TRASH}/${name}-${stamp}.tar.gz (kept 7 days)"
  fi
  # Clean up trash > 7 days.
  find "$LAPN_TRASH" -name '*.tar.gz' -mtime +7 -delete 2>/dev/null || true

  # delete user + home + secrets
  if id "$user" >/dev/null 2>&1; then
    userdel -r "$user" 2>/dev/null || { userdel "$user" 2>/dev/null; rm -rf "$home"; }
  fi
  rm -rf "${LAPN_SECRETS}/${name}"

  # update state
  state_site_del "$domain"
  audit "OK" "site:delete $domain"
  log_ok "Site $domain deleted."
}

# =====================================================================
# Deploy (git pull + rebuild + restart), run as the site user.
# Lives under Site management — a deploy always targets a specific site.
# =====================================================================

_dep_parse() {
  DEP_DOMAIN=""; DEP_BRANCH=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain) DEP_DOMAIN="$2"; shift 2 ;;
      --branch) DEP_BRANCH="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
}

# Get site info, set SITE_* variables + check existence.
_dep_load_site() {
  local domain="$1"
  state_site_exists "$domain" || die "No site '$domain'."
  SITE_DOMAIN="$domain"
  SITE_NAME="$(state_site_get "$domain" name)"
  SITE_USER="$(state_site_get "$domain" user)"
  SITE_ROOT="$(state_site_get "$domain" root)"
  SITE_PORT="$(state_site_get "$domain" port)"
  SITE_NODE="$(state_site_get "$domain" node_version)"
  SITE_TYPE="$(state_site_get "$domain" type)"
}

# Run a command as the site user with the fnm env preloaded.
_dep_run_as_user() {
  sudo -u "$SITE_USER" bash -lc "
    export FNM_DIR=\"\$HOME/.local/share/fnm\"; eval \"\$(fnm env --shell bash 2>/dev/null)\" || true
    cd '$SITE_ROOT' || exit 1
    $1
  "
}

cmd_deploy_git() {
  core_require_root
  _dep_parse "$@"
  state_init
  local domain; domain="$(resolve_input "domain" "$DEP_DOMAIN" --prompt "Domain" --validate validate_domain)"
  _dep_load_site "$domain"

  log_step "Deploy (git pull) $domain"
  # Warning if .env is committed to the repo.
  if _dep_run_as_user "git ls-files --error-unmatch .env >/dev/null 2>&1"; then
    log_warn "⚠ .env is committed in the repo! Remove it from git and add it to .gitignore now."
  fi
  local branch_cmd="git fetch --all"
  [[ -n "$DEP_BRANCH" ]] && branch_cmd+=" && git checkout '$DEP_BRANCH'"
  _dep_run_as_user "$branch_cmd && git pull --ff-only" || die "git pull failed."

  cmd_deploy_rebuild --domain "$domain"
}

cmd_deploy_rebuild() {
  core_require_root
  _dep_parse "$@"
  state_init
  local domain; domain="$(resolve_input "domain" "$DEP_DOMAIN" --prompt "Domain" --validate validate_domain)"
  _dep_load_site "$domain"

  log_step "Rebuild $domain"
  # npm ci from lockfile + ignore-scripts (guard against malicious postinstall).
  _dep_run_as_user "npm ci --ignore-scripts || npm ci" || die "npm ci failed."
  # build if there is a build script
  _dep_run_as_user "jq -e '.scripts.build' package.json >/dev/null 2>&1 && npm run build || true" || true
  # npm audit (warning, non-blocking)
  _dep_run_as_user "npm audit --omit=dev 2>&1 | tail -n 5" | while IFS= read -r l; do log_dim "$l"; done || true

  if [[ "$SITE_TYPE" != "static" ]]; then
    cmd_deploy_restart --domain "$domain"
  else
    systemctl reload nginx 2>/dev/null || true
    log_ok "Static build updated."
  fi
}

cmd_deploy_restart() {
  core_require_root
  _dep_parse "$@"
  state_init
  local domain; domain="$(resolve_input "domain" "$DEP_DOMAIN" --prompt "Domain" --validate validate_domain)"
  _dep_load_site "$domain"
  if [[ "$SITE_TYPE" == "static" ]]; then
    log_info "Static site has no unit to restart."
    return 0
  fi
  log_step "Restart lapn-${SITE_NAME}"
  systemctl restart "lapn-${SITE_NAME}.service" || die "Restart failed."
  sleep 1
  if systemctl is-active --quiet "lapn-${SITE_NAME}.service"; then
    log_ok "Running."
  else
    log_error "Unit not active — see: journalctl -u lapn-${SITE_NAME} -n 50"
  fi
}

cmd_deploy_logs() {
  _dep_parse "$@"
  state_init
  local domain; domain="$(resolve_input "domain" "$DEP_DOMAIN" --prompt "Domain" --validate validate_domain)"
  _dep_load_site "$domain"
  [[ "$SITE_TYPE" == "static" ]] && { log_info "Static — see /var/log/nginx."; return 0; }
  journalctl -u "lapn-${SITE_NAME}.service" -n 100 -f
}
