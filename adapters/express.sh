#!/usr/bin/env bash
# adapters/express.sh — Express / NestJS / plain Node API.

adapter_detect() {
  [[ -f "$SITE_ROOT/package.json" ]] || return 1
  grep -qE '"(express|@nestjs/core|fastify|koa)"' "$SITE_ROOT/package.json"
}

adapter_needs_unit() { return 0; }

adapter_build() {
  npm ci || return 1
  # Build if a build script exists (NestJS/TS); skip if absent.
  if jq -e '.scripts.build // empty' package.json >/dev/null 2>&1; then
    npm run build || return 1
  fi
}

adapter_start_cmd() {
  local node; node="$(adapter_node_bin "$SITE_USER" "$SITE_NODE")"
  # Priority: npm start if a start script exists; otherwise guess the entrypoint.
  if jq -e '.scripts.start // empty' "$SITE_ROOT/package.json" >/dev/null 2>&1; then
    # Use node to run the main file directly so systemd tracks the correct PID (not via npm).
    local main
    main="$(jq -r '.main // empty' "$SITE_ROOT/package.json")"
    if [[ -n "$main" && -f "$SITE_ROOT/$main" ]]; then
      printf '%s %s/%s' "$node" "$SITE_ROOT" "$main"
      return 0
    fi
  fi
  local guess
  for guess in dist/main.js dist/index.js dist/server.js server.js index.js app.js src/main.js; do
    if [[ -f "$SITE_ROOT/$guess" ]]; then
      printf '%s %s/%s' "$node" "$SITE_ROOT" "$guess"; return 0
    fi
  done
  log_warn "Could not guess the entrypoint — defaulting to server.js. Edit it in the unit if needed."
  printf '%s %s/server.js' "$node" "$SITE_ROOT"
}

adapter_env_defaults() { printf ''; }
adapter_health_url()   { printf '/'; }
