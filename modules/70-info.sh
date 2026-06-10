#!/usr/bin/env bash
# modules/70-info.sh — info & self-management of LapN: update, version.

MODULE_NAME="Info"
MODULE_ORDER=70
MODULE_COMMANDS=("update" "version")

# update — pull latest code into $LAPN_HOME, re-sync safe assets, run migrations.
cmd_update() {
  core_require_root
  log_step "Updating LapN ($LAPN_HOME)"

  if [[ -d "$LAPN_HOME/.git" ]]; then
    git -C "$LAPN_HOME" fetch --all --quiet || die "git fetch failed."
    # Track the upstream branch (fallback to origin/main).
    local branch upstream before after
    branch="$(git -C "$LAPN_HOME" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
    upstream="$(git -C "$LAPN_HOME" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || echo "origin/${branch}")"
    [[ "$upstream" == "@{u}" || -z "$upstream" ]] && upstream="origin/main"
    before="$(git -C "$LAPN_HOME" rev-parse --short HEAD 2>/dev/null || echo '?')"
    # /opt/lapn is a managed deployment (code only, no real data). Reset hard to the
    # remote so the update is robust against local churn (e.g. CRLF/LF line-ending drift)
    # that would otherwise block a plain 'git pull'.
    if ! git -C "$LAPN_HOME" reset --hard "$upstream" >/dev/null 2>&1; then
      die "git reset to $upstream failed (run 'git -C $LAPN_HOME status')."
    fi
    after="$(git -C "$LAPN_HOME" rev-parse --short HEAD 2>/dev/null || echo '?')"
    if [[ "$before" == "$after" ]]; then
      log_ok "Already up to date ($after)."
    else
      log_ok "Updated: $before -> $after (synced to $upstream)"
    fi
  else
    log_warn "$LAPN_HOME is not a git repo — cannot self-update."
    log_info "Re-install with: git clone ${LAPN_REPO:-<repo>} $LAPN_HOME"
    return 1
  fi

  # Make sure the CLI symlink still points here.
  ln -sf "$LAPN_HOME/bin/lapn" /usr/local/bin/lapn
  chmod +x "$LAPN_HOME/bin/lapn"

  _self_sync_assets
  state_migrate

  log_ok "Update complete. Version: $(cat "$LAPN_HOME/VERSION" 2>/dev/null || echo '?')"
}

# Re-copy only assets that are NOT mutated at runtime, so template fixes propagate
# without clobbering runtime state (HSTS toggle in security-headers, generated CF IPs).
_self_sync_assets() {
  command -v nginx >/dev/null 2>&1 || return 0
  mkdir -p /etc/nginx/snippets

  cp -f "$LAPN_HOME/templates/nginx/snippets/block-sensitive.conf" \
        /etc/nginx/snippets/lapn-block-sensitive.conf
  cp -f "$LAPN_HOME/templates/nginx/snippets/ratelimit.conf" \
        /etc/nginx/conf.d/lapn-ratelimit.conf
  cp -f "$LAPN_HOME/templates/nginx/default-444.conf" \
        /etc/nginx/sites-available/lapn-default-444.conf

  # logrotate is safe to overwrite (not mutated).
  cp -f "$LAPN_HOME/templates/logrotate/lapn.tpl" /etc/logrotate.d/lapn

  if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx 2>/dev/null || true
    log_ok "Re-synced base nginx snippets + logrotate."
  else
    log_warn "nginx -t failed after asset sync — check config."
  fi
  log_info "Note: security-headers & cloudflare-realip snippets are left untouched (runtime-managed)."
}

# version — print current version + git revision.
cmd_version() {
  local ver rev
  ver="$(cat "$LAPN_HOME/VERSION" 2>/dev/null || echo '?')"
  rev="$(git -C "$LAPN_HOME" rev-parse --short HEAD 2>/dev/null || echo 'no-git')"
  printf 'lapn %s (%s)\n' "$ver" "$rev"
}
