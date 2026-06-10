#!/usr/bin/env bash
# modules/50-deploy.sh — deploy git pull + rebuild + restart, chạy dưới user site.

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

# Lấy thông tin site, set biến SITE_* + kiểm tra tồn tại.
_dep_load_site() {
  local domain="$1"
  state_site_exists "$domain" || die "Không có site '$domain'."
  SITE_DOMAIN="$domain"
  SITE_NAME="$(state_site_get "$domain" name)"
  SITE_USER="$(state_site_get "$domain" user)"
  SITE_ROOT="$(state_site_get "$domain" root)"
  SITE_PORT="$(state_site_get "$domain" port)"
  SITE_NODE="$(state_site_get "$domain" node_version)"
  SITE_TYPE="$(state_site_get "$domain" type)"
}

# Chạy lệnh dưới user site với fnm env nạp sẵn.
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
  # Cảnh báo nếu .env bị commit vào repo.
  if _dep_run_as_user "git ls-files --error-unmatch .env >/dev/null 2>&1"; then
    log_warn "⚠ .env bị commit trong repo! Xóa khỏi git và thêm vào .gitignore ngay."
  fi
  local branch_cmd="git fetch --all"
  [[ -n "$DEP_BRANCH" ]] && branch_cmd+=" && git checkout '$DEP_BRANCH'"
  _dep_run_as_user "$branch_cmd && git pull --ff-only" || die "git pull thất bại."

  cmd_deploy_rebuild --domain "$domain"
}

cmd_deploy_rebuild() {
  core_require_root
  _dep_parse "$@"
  state_init
  local domain; domain="$(resolve_input "domain" "$DEP_DOMAIN" --prompt "Domain" --validate validate_domain)"
  _dep_load_site "$domain"

  log_step "Rebuild $domain"
  # npm ci theo lockfile + ignore-scripts (chống postinstall độc).
  _dep_run_as_user "npm ci --ignore-scripts || npm ci" || die "npm ci thất bại."
  # build nếu có script build
  _dep_run_as_user "jq -e '.scripts.build' package.json >/dev/null 2>&1 && npm run build || true" || true
  # npm audit (cảnh báo, không chặn)
  _dep_run_as_user "npm audit --omit=dev 2>&1 | tail -n 5" | while IFS= read -r l; do log_dim "$l"; done || true

  if [[ "$SITE_TYPE" != "static" ]]; then
    cmd_deploy_restart --domain "$domain"
  else
    systemctl reload nginx 2>/dev/null || true
    log_ok "Static build cập nhật xong."
  fi
}

cmd_deploy_restart() {
  core_require_root
  _dep_parse "$@"
  state_init
  local domain; domain="$(resolve_input "domain" "$DEP_DOMAIN" --prompt "Domain" --validate validate_domain)"
  _dep_load_site "$domain"
  if [[ "$SITE_TYPE" == "static" ]]; then
    log_info "Site static không có unit để restart."
    return 0
  fi
  log_step "Restart lapn-${SITE_NAME}"
  systemctl restart "lapn-${SITE_NAME}.service" || die "Restart thất bại."
  sleep 1
  if systemctl is-active --quiet "lapn-${SITE_NAME}.service"; then
    log_ok "Đang chạy."
  else
    log_error "Unit không active — xem: journalctl -u lapn-${SITE_NAME} -n 50"
  fi
}

cmd_deploy_logs() {
  _dep_parse "$@"
  state_init
  local domain; domain="$(resolve_input "domain" "$DEP_DOMAIN" --prompt "Domain" --validate validate_domain)"
  _dep_load_site "$domain"
  [[ "$SITE_TYPE" == "static" ]] && { log_info "Static — xem /var/log/nginx."; return 0; }
  journalctl -u "lapn-${SITE_NAME}.service" -n 100 -f
}
