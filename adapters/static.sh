#!/usr/bin/env bash
# adapters/static.sh — static build (SPA/site tĩnh). Nginx serve thẳng, không systemd unit.

adapter_detect() {
  [[ -f "$SITE_ROOT/index.html" ]] && return 0
  [[ -d "$SITE_ROOT/dist" || -d "$SITE_ROOT/build" || -d "$SITE_ROOT/out" ]]
}

adapter_needs_unit() { return 1; }

adapter_build() {
  # Nếu là project có build step (Vite/CRA), build ra thư mục tĩnh.
  if [[ -f "$SITE_ROOT/package.json" ]] && jq -e '.scripts.build // empty' "$SITE_ROOT/package.json" >/dev/null 2>&1; then
    npm ci || return 1
    npm run build || return 1
  fi
  return 0
}

# Static không cần ExecStart.
adapter_start_cmd()    { printf ''; }
adapter_env_defaults() { printf ''; }
adapter_health_url()   { printf '/'; }

# adapter_static_root -> in thư mục web root thực tế (dist/build/out/.).
adapter_static_root() {
  local d
  for d in dist build out public; do
    [[ -d "$SITE_ROOT/$d" ]] && { printf '%s/%s' "$SITE_ROOT" "$d"; return 0; }
  done
  printf '%s' "$SITE_ROOT"
}
