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
# adapter_build_cmd     -> print the shell snippet that installs deps + builds. The caller
#                          runs it via `sudo -u $SITE_USER bash -lc` with cwd=$SITE_ROOT,
#                          so it must `exit 1` on failure. Both site:create and
#                          deploy:rebuild use this — there is no second build code path.
# adapter_start_cmd     -> print the full ExecStart (node path + entrypoint)
# adapter_env_defaults  -> print the KEY=VALUE lines added to .env
# adapter_health_url    -> print the health check path (default /)

# --- Defaults (adapters may override) ---
adapter_detect()       { return 1; }
adapter_needs_unit()   { return 0; }
adapter_start_cmd()    { printf ''; }
adapter_env_defaults() { printf ''; }
adapter_health_url()   { printf '/'; }
adapter_build_cmd() {
  cat <<'CMD'
{ npm ci --ignore-scripts || npm ci; } || exit 1
CMD
}

# adapter_node_bin <user> <node_version> -> print the absolute node path for ExecStart.
# fnm layout:  $FNM_DIR/node-versions/vX.Y.Z/installation/bin/node
#              $FNM_DIR/aliases/default -> ../node-versions/vX.Y.Z/installation
# The version the site was pinned to wins over anything a login shell or the system
# happens to offer: that pin is what the unit must keep running after any upgrade.
adapter_node_bin() {
  local user="$1" ver="$2" home bin c
  home="$(getent passwd "$user" | cut -d: -f6)"
  local fnm_dir="${home}/.local/share/fnm"

  # Exact pin. Two patterns so both "24" and "24.9.0" resolve.
  # -f, not -x: if the binary is there but somehow not executable, pointing ExecStart
  # at it gets a 203/EXEC naming that exact path, which beats silently falling through
  # to a /usr/bin/node that nothing ever installed.
  for c in "$fnm_dir"/node-versions/"v${ver}"/installation/bin/node \
           "$fnm_dir"/node-versions/"v${ver}".*/installation/bin/node; do
    [[ -f "$c" ]] && { printf '%s' "$c"; return 0; }
  done
  # Whatever `fnm default` points at for this user.
  [[ -f "$fnm_dir/aliases/default/bin/node" ]] && {
    printf '%s' "$fnm_dir/aliases/default/bin/node"; return 0; }
  # A login shell with fnm wired up, or a system-wide node.
  bin="$(sudo -u "$user" bash -lc 'command -v node' 2>/dev/null || true)"
  [[ -n "$bin" ]] && { printf '%s' "$bin"; return 0; }
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
