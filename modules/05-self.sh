#!/usr/bin/env bash
# modules/05-self.sh — manage LapN itself: update, version.

MODULE_NAME="LapN itself"
MODULE_ORDER=5
MODULE_COMMANDS=("update" "version")

# update — pull latest code into $LAPN_HOME, re-sync safe assets, run migrations.
cmd_update() {
  core_require_root
  log_step "Updating LapN ($LAPN_HOME)"

  if [[ -d "$LAPN_HOME/.git" ]]; then
    git -C "$LAPN_HOME" fetch --all --quiet || die "git fetch failed."
    local before after
    before="$(git -C "$LAPN_HOME" rev-parse --short HEAD 2>/dev/null || echo '?')"
    if ! git -C "$LAPN_HOME" pull --ff-only; then
      die "git pull failed (uncommitted local changes? run 'git -C $LAPN_HOME status')."
    fi
    after="$(git -C "$LAPN_HOME" rev-parse --short HEAD 2>/dev/null || echo '?')"
    if [[ "$before" == "$after" ]]; then
      log_ok "Already up to date ($after)."
    else
      log_ok "Updated: $before -> $after"
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
