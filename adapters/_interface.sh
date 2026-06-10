#!/usr/bin/env bash
# adapters/_interface.sh — common contract for every adapter.
# Each adapter (nextjs/express/static) overrides the functions below.
#
# Conventions:
#   - The functions receive environment variables: SITE_DOMAIN, SITE_NAME, SITE_USER, SITE_ROOT, SITE_PORT, SITE_NODE.
#   - adapter_build/start run with cwd = $SITE_ROOT (the calling module already did `cd`/`sudo -u`).
#
# adapter_detect       -> return 0 if the app type can be auto-detected from $SITE_ROOT/package.json
# adapter_needs_unit    -> return 0 if a systemd unit is needed (static = 1/false)
# adapter_build         -> build the app (npm ci && npm run build...), run under the site user
# adapter_start_cmd     -> print the full ExecStart (node path + entrypoint)
# adapter_env_defaults  -> print the KEY=VALUE lines added to .env
# adapter_health_url    -> print the health check path (default /)

# --- Defaults (adapters may override) ---
adapter_detect()       { return 1; }
adapter_needs_unit()   { return 0; }
adapter_build()        { return 0; }
adapter_start_cmd()    { printf ''; }
adapter_env_defaults() { printf ''; }
adapter_health_url()   { printf '/'; }

# node_bin_for <user> <node_version> -> print the user's node path via fnm.
# fnm is installed per-user; fall back to the system node if not found.
adapter_node_bin() {
  local user="$1" ver="$2" home bin
  home="$(getent passwd "$user" | cut -d: -f6)"
  # fnm layout: ~/.local/share/fnm/node-versions/vXX.*/installation/bin/node
  bin="$(sudo -u "$user" bash -lc "command -v node" 2>/dev/null || true)"
  if [[ -n "$bin" ]]; then printf '%s' "$bin"; return 0; fi
  # Try to find it in the fnm dir.
  local found
  found="$(find "$home/.local/share/fnm/node-versions" -maxdepth 3 -name node -type f 2>/dev/null \
            | grep "/v${ver}" | head -n1 || true)"
  [[ -n "$found" ]] && { printf '%s' "$found"; return 0; }
  printf '/usr/bin/node'
}

# load_adapter <type> — source the corresponding adapter (after sourcing _interface).
load_adapter() {
  local type="$1"
  local f="$LAPN_HOME/adapters/$type.sh"
  [[ -f "$f" ]] || die "No adapter found for type '$type'."
  # shellcheck source=/dev/null
  source "$f"
}
