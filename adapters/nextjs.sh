#!/usr/bin/env bash
# adapters/nextjs.sh — Next.js. Recommended output: 'standalone'.

adapter_detect() {
  [[ -f "$SITE_ROOT/package.json" ]] || return 1
  grep -q '"next"' "$SITE_ROOT/package.json"
}

adapter_needs_unit() { return 0; }

adapter_build_cmd() {
  cat <<'CMD'
{ npm ci --ignore-scripts || npm ci; } || exit 1
npm run build || exit 1
CMD
}

adapter_start_cmd() {
  local node; node="$(adapter_node_bin "$SITE_USER" "$SITE_NODE")"
  # standalone: node .next/standalone/server.js ; if not present, use next start.
  if [[ -f "$SITE_ROOT/.next/standalone/server.js" ]]; then
    printf '%s %s/.next/standalone/server.js' "$node" "$SITE_ROOT"
  else
    log_warn "Not found .next/standalone — recommended to enable output:'standalone'. Using 'next start'."
    printf '%s %s/node_modules/.bin/next start -p %s' "$node" "$SITE_ROOT" "$SITE_PORT"
  fi
}

adapter_env_defaults() {
  printf 'NEXT_TELEMETRY_DISABLED=1\n'
}

adapter_health_url() { printf '/'; }
