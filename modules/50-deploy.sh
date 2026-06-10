#!/usr/bin/env bash
# modules/50-deploy.sh — deploy git pull + rebuild + restart, run as the site user.

MODULE_NAME="Deploy"
MODULE_ORDER=50
MODULE_COMMANDS=("deploy:git" "deploy:rebuild" "deploy:restart" "deploy:logs")

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
