#!/usr/bin/env bash
# tests/smoke.sh — test on a clean Ubuntu container/VM.
# Clean install -> create demo site (express) -> curl 200 -> delete site.
# Note: real systemd is required (image jrei/systemd-ubuntu:24.04 --privileged) for the unit part.
set -euo pipefail

LAPN_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()   { printf '  [✓] %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  [✗] %s\n' "$*"; FAIL=$((FAIL+1)); }
sect() { printf '\n== %s ==\n' "$*"; }

# --- 0) Lint syntax of all scripts (runs anywhere, even without systemd) ---
sect "bash -n (syntax) for all scripts"
syntax_ok=1
while IFS= read -r f; do
  if bash -n "$f" 2>/tmp/lapn-syn.err; then
    ok "syntax: ${f#"$LAPN_HOME"/}"
  else
    bad "syntax: ${f#"$LAPN_HOME"/} -> $(cat /tmp/lapn-syn.err)"; syntax_ok=0
  fi
done < <(find "$LAPN_HOME" -name '*.sh' -o -path '*/bin/lapn' | sort)

# --- 1) shellcheck if available ---
if command -v shellcheck >/dev/null 2>&1; then
  sect "shellcheck"
  if shellcheck -S error -x "$LAPN_HOME"/lib/*.sh "$LAPN_HOME"/modules/*.sh "$LAPN_HOME"/bin/lapn 2>/tmp/lapn-sc.err; then
    ok "shellcheck (error level) clean"
  else
    bad "shellcheck: see /tmp/lapn-sc.err"
  fi
else
  printf '  (skipping shellcheck — not installed)\n'
fi

# --- 2) Router loads, builds registry, help runs ---
sect "router & module discovery"
if LAPN_HOME="$LAPN_HOME" bash "$LAPN_HOME/bin/lapn" help >/tmp/lapn-help.txt 2>&1; then
  ok "lapn help runs"
  grep -q "site:create" /tmp/lapn-help.txt && ok "site module discovered" || bad "site:create not found in help"
  grep -q "deploy:git"  /tmp/lapn-help.txt && ok "deploy merged into site" || bad "deploy:git not found in help"
  grep -q "db:create"   /tmp/lapn-help.txt && ok "db module discovered"   || bad "db:create not found"
  grep -q "stack:mariadb" /tmp/lapn-help.txt && ok "db-engine install under stack" || bad "stack:mariadb not found"
  grep -q "update"      /tmp/lapn-help.txt && ok "update command present" || bad "update command not found"
else
  bad "lapn help failed: $(cat /tmp/lapn-help.txt)"
fi

# --- 3) Validate helpers ---
sect "validate.sh"
# shellcheck source=/dev/null
source "$LAPN_HOME/lib/log.sh"
# shellcheck source=/dev/null
source "$LAPN_HOME/lib/validate.sh"
validate_domain "app.example.vn" && ok "valid domain passes" || bad "valid domain fails"
validate_domain "no-dot-here" 2>/dev/null && bad "invalid domain passes" || ok "invalid domain rejected"
validate_app_port "3005" && ok "valid app port" || bad "app port fails"
validate_app_port "80" 2>/dev/null && bad "port 80 passes" || ok "service port rejected"
[[ "$(slugify_domain 'Checkin.Example.VN')" == "checkin-example-vn" ]] && ok "slugify" || bad "slugify wrong"
validate_node_version "24"     && ok "node version 24"      || bad "node 24 rejected"
validate_node_version "24.9.0" && ok "node version 24.9.0"  || bad "node 24.9.0 rejected"
validate_node_version "lts/jod" && ok "node alias lts/jod"  || bad "lts/jod rejected"
validate_node_version "2 4" 2>/dev/null && bad "typo '2 4' accepted" || ok "node typo rejected"

# --- 3b) adapter_node_bin resolves the real fnm layout ---
# Regression: the old find used -maxdepth 3, one level too shallow for
# node-versions/vX.Y.Z/installation/bin/node, so ExecStart fell back to a
# /usr/bin/node that install.sh never puts there -> every unit died 203/EXEC.
sect "adapter_node_bin (fnm layout)"
fake_home="$(mktemp -d)"
fnm_dir="$fake_home/.local/share/fnm"
mkdir -p "$fnm_dir/node-versions/v24.9.0/installation/bin" "$fnm_dir/aliases/default/bin"
: >"$fnm_dir/node-versions/v24.9.0/installation/bin/node"
: >"$fnm_dir/aliases/default/bin/node"   # a plain dir here: ln -s is unreliable on Windows
# Stub getent so the adapter resolves our fake home without touching real users.
getent() { printf 'x:x:0:0::%s:/usr/sbin/nologin\n' "$fake_home"; }
# shellcheck source=/dev/null
source "$LAPN_HOME/adapters/_interface.sh"
got="$(adapter_node_bin fakeuser 24)"
[[ "$got" == "$fnm_dir/node-versions/v24.9.0/installation/bin/node" ]] \
  && ok "resolves pinned major (24 -> v24.9.0)" || bad "pinned major returned: $got"
got="$(adapter_node_bin fakeuser 24.9.0)"
[[ "$got" == "$fnm_dir/node-versions/v24.9.0/installation/bin/node" ]] \
  && ok "resolves exact version (24.9.0)" || bad "exact version returned: $got"
got="$(adapter_node_bin fakeuser 18)"   # not installed -> fnm default alias
[[ "$got" == "$fnm_dir/aliases/default/bin/node" ]] \
  && ok "falls back to the fnm default alias" || bad "fallback returned: $got"
unset -f getent
rm -rf "$fake_home"

# --- 3c) core_config_set writes overrides into /etc/lapn/config ---
sect "core_config_set"
cfg_dir="$(mktemp -d)"
(
  LAPN_HOME="$LAPN_HOME"; export LAPN_HOME
  # shellcheck source=/dev/null
  source "$LAPN_HOME/lib/core.sh"
  export LAPN_CONFIG="$cfg_dir/config"
  printf '# LapN config (override defaults)\nLAPN_SSH_PORT=22\n' >"$LAPN_CONFIG"
  core_config_set LAPN_NODE_DEFAULT 24
  core_config_set LAPN_SSH_PORT 2222
  core_config_set LAPN_NODE_DEFAULT 26          # replace, must not duplicate
  [[ "$(grep -c '^LAPN_NODE_DEFAULT=' "$LAPN_CONFIG")" == "1" ]] || exit 1
  [[ "$LAPN_NODE_DEFAULT" == "26" ]] || exit 2  # applied in-process too
  ( . "$LAPN_CONFIG" && [[ "$LAPN_SSH_PORT" == "2222" ]] ) || exit 3
  core_config_set NOT_A_LAPN_KEY 1 2>/dev/null && exit 4
  exit 0
) && ok "core_config_set: replace, in-process, sourceable, key guard" \
  || bad "core_config_set failed (exit $?)"
rm -rf "$cfg_dir"

# --- 4) End-to-end flow (only when root + systemd) ---
if (( EUID == 0 )) && pidof systemd >/dev/null 2>&1; then
  sect "end-to-end (root + systemd)"
  bash "$LAPN_HOME/install.sh" </dev/null || bad "install.sh failed"
  # Create a local demo express app. It deliberately has no dependencies: the build
  # runs `npm ci`, which needs a lockfile that matches package.json and no network.
  demo=/tmp/lapn-demo
  mkdir -p "$demo"
  cat >"$demo/server.js" <<'JS'
const http=require('http');const p=process.env.PORT||3000;
http.createServer((_,res)=>{res.end('ok')}).listen(p,'127.0.0.1');
JS
  cat >"$demo/package.json" <<'JSON'
{"name":"demo","version":"1.0.0","main":"server.js"}
JSON
  cat >"$demo/package-lock.json" <<'JSON'
{"name":"demo","version":"1.0.0","lockfileVersion":3,"requires":true,
 "packages":{"":{"name":"demo","version":"1.0.0"}}}
JSON
  ( cd "$demo" && git init -q && git add -A && git commit -qm init )
  # The site user clones this root-owned repo over file://, so upload-pack would refuse
  # it as "dubious ownership" without an explicit allow.
  git config --system --add safe.directory "$demo"
  if lapn site:create --domain demo.local --type express --node 20 --git "file://$demo" </dev/null; then
    ok "site:create demo.local"
    port="$(jq -r '.sites["demo.local"].port' /etc/lapn/sites.json)"
    # The unit must really be running: a sandbox that hides the site home (e.g.
    # ProtectHome=true over /home/sites) fails here and nowhere else.
    systemctl is-active --quiet lapn-demo-local.service \
      && ok "unit lapn-demo-local active" \
      || bad "unit lapn-demo-local not active: $(systemctl show -p Result --value lapn-demo-local.service 2>/dev/null)"
    sleep 2
    curl -fsS "http://127.0.0.1:${port}/" >/dev/null && ok "curl 200 (port $port)" || bad "curl fail"

    # A site created with no repo must survive (no unit yet) and the first deploy
    # must be what creates and starts the unit.
    if lapn site:create --domain demo2.local --type express --node 20 </dev/null; then
      ok "site:create without --git"
      nginx -t 2>/dev/null && ok "nginx -t with two sites" || bad "nginx -t failed with two sites"
      if lapn deploy:git --domain demo2.local --git "file://$demo" </dev/null; then
        systemctl is-active --quiet lapn-demo2-local.service \
          && ok "deploy:git created + started the unit" \
          || bad "unit lapn-demo2-local not active after deploy:git"
      else
        bad "deploy:git failed"
      fi
      lapn site:delete --domain demo2.local --force </dev/null >/dev/null \
        && ok "site:delete demo2.local" || bad "site:delete demo2.local failed"
    else
      bad "site:create without --git failed"
    fi

    lapn site:delete --domain demo.local --force </dev/null && ok "site:delete" || bad "site:delete failed"
  else
    bad "site:create failed"
  fi
else
  printf '\n  (skipping end-to-end — needs root + systemd; run inside jrei/systemd-ubuntu)\n'
fi

# --- Result ---
printf '\n== RESULT: %d pass, %d fail ==\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
