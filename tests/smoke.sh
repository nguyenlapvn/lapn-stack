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
  for c in site:env site:alias site:start site:stop; do
    grep -q "$c" /tmp/lapn-help.txt && ok "$c present" || bad "$c not found"
  done
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

# --- 3a2) audit redaction + password allowlist ---
# Regression: core_dispatch logs the whole command line, so --dbpass / --cf-token /
# --key used to land in actions.log in plaintext (in a 0644 file).
sect "secrets never reach the audit log"
got="$(audit_redact db:create --site x.vn --dbpass 'S3cret' --dbuser app)"
[[ "$got" != *S3cret* && "$got" == *"--dbpass ***"* ]] && ok "masks --dbpass" || bad "redact: $got"
got="$(audit_redact ssl:issue --domain x.vn --cf-token 'tok123')"
[[ "$got" != *tok123* ]] && ok "masks --cf-token" || bad "redact: $got"
got="$(audit_redact db:remote --add --key 'ssh-ed25519 AAAA')"
[[ "$got" != *AAAA* ]] && ok "masks --key" || bad "redact: $got"
[[ "$(audit_redact site:create --domain x.vn)" == "site:create --domain x.vn" ]] \
  && ok "leaves normal flags alone" || bad "redact mangled a normal command"

# Regression: a Match block left open at the end of a drop-in keeps applying to the
# rest of sshd_config, which puts UsePAM/Subsystem inside a Match context and makes
# `sshd -t` reject the whole configuration.
sect "db:remote sshd drop-in"
grep -A30 'Match User \${user}' "$LAPN_HOME/modules/20-db.sh" | grep -q '^Match all$' \
  && ok "tunnel Match block is closed with 'Match all'" \
  || bad "the sshd drop-in leaves its Match block open"

sect "validate_db_password"
validate_db_password "Abcd1234"        && ok "plain alnum ok"      || bad "alnum rejected"
validate_db_password "short1"  2>/dev/null && bad "too short accepted" || ok "too short rejected"
validate_db_password "a'b;DROP--x" 2>/dev/null && bad "quote accepted" || ok "quote rejected"
validate_db_password 'p@ss:word/x'  2>/dev/null && bad "URL chars accepted" || ok "URL-breaking chars rejected"
# The generated passwords must always satisfy the rule they are checked against.
validate_db_password "$(openssl rand -base64 24 2>/dev/null | tr -d '/+=' | head -c 24)" \
  && ok "generated password passes its own rule" || bad "generated password rejected"

# --- 3b2) IP/CIDR helpers behind the DNS pre-flight ---
# Regression: the check compared ONE resolved address (the AAAA, which getent returns
# first) against the server's IPv4, so every Cloudflare-proxied domain was reported as
# a DNS mistake instead of "use dns-cloudflare".
sect "net.sh address helpers"
# shellcheck source=/dev/null
source "$LAPN_HOME/lib/net.sh"
net_ip_in_cidr 173.245.48.10  173.245.48.0/20  && ok "in-range /20"      || bad "in-range /20 failed"
net_ip_in_cidr 173.245.64.1   173.245.48.0/20  && bad "out-of-range /20 accepted" || ok "out-of-range /20"
net_ip_in_cidr 104.16.0.0     104.16.0.0/13    && ok "network address"   || bad "network address failed"
net_ip_in_cidr 104.23.255.255 104.16.0.0/13    && ok "broadcast edge"    || bad "broadcast edge failed"
net_ip_in_cidr 104.24.0.0     104.16.0.0/13    && bad "off-by-one accepted" || ok "off-by-one rejected"
net_ip_in_cidr 1.2.3.4        1.2.3.4          && ok "bare address = /32" || bad "bare address failed"
net_ip_in_cidr "not-an-ip"    10.0.0.0/8       && bad "garbage accepted" || ok "garbage rejected"
LAPN_HOME="$LAPN_HOME" net_is_cloudflare_ip 2606:4700:3032::6815:13c3 \
  && ok "detects a Cloudflare IPv6" || bad "Cloudflare IPv6 not detected"
LAPN_HOME="$LAPN_HOME" net_is_cloudflare_ip 139.180.128.212 \
  && bad "plain VPS IP called Cloudflare" || ok "plain VPS IP not Cloudflare"
LAPN_HOME="$LAPN_HOME" net_is_cloudflare_ip 104.16.1.1 \
  && ok "detects a Cloudflare IPv4" || bad "Cloudflare IPv4 not detected"

# --- 3b3) dashboard metrics: raw counters in, percentages out ---
sect "metrics series + sparkline"
# shellcheck source=/dev/null
source "$LAPN_HOME/modules/05-dashboard.sh"
m_dir="$(mktemp -d)"; export LAPN_METRICS_DIR="$m_dir"
# 20 samples at a steady 25% CPU, RAM 40%, disk 31%.
: >"$m_dir/system.csv"
ct=0; ci=0; ts=1759500000
for k in $(seq 1 20); do
  ct=$((ct + 1000)); ci=$((ci + 750))          # 25% busy
  printf '%s,%s,%s,2000000,1200000,31,0,0\n' "$((ts + k * 60))" "$ct" "$ci" >>"$m_dir/system.csv"
done
mapfile -t SER < <(_metrics_series 20 10)
[[ "${#SER[@]}" == 3 ]] && ok "series returns cpu/mem/disk" || bad "series returned ${#SER[@]} lines"
read -r _ first _ <<<"${SER[0]}"
[[ "$first" == 25 ]] && ok "cpu derived from counters (25%)" || bad "cpu was '$first', expected 25"
read -r _ mfirst _ <<<"${SER[1]}"
[[ "$mfirst" == 40 ]] && ok "mem derived (40%)" || bad "mem was '$mfirst', expected 40"
read -r _ dfirst _ <<<"${SER[2]}"
[[ "$dfirst" == 31 ]] && ok "disk passed through (31%)" || bad "disk was '$dfirst', expected 31"
# shellcheck disable=SC2086
[[ "$(set -- ${SER[0]#cpu }; echo $#)" == 10 ]] && ok "bucketed into the requested columns" \
  || bad "wrong bucket count"

# A reboot resets the kernel counters; that interval must be dropped, not turned into
# a bogus spike or a division by zero.
printf '%s,10,5,2000000,1200000,31,0,0\n' "$((ts + 21 * 60))" >>"$m_dir/system.csv"
mapfile -t SER2 < <(_metrics_series 20 10)
[[ "${#SER2[@]}" == 3 ]] && ok "survives a counter reset" || bad "counter reset broke the series"

# Too little data must fail cleanly so the dashboard can say "collecting".
printf '1,1,1,1,1,1,0,0\n' >"$m_dir/system.csv"
_metrics_series 20 10 >/dev/null 2>&1 && bad "single sample produced a series" \
  || ok "single sample reports no series"

# Regression: `read` returns 1 at EOF without a trailing newline, and under `set -e`
# that killed the whole process — the dashboard exited at the first site row and the
# sampler died before writing a single row. Every producer feeding a `read` must end
# its output with a newline.
systemctl() { printf 'MemoryCurrent=193142784\nCPUUsageNSec=41000000000\n'; }
[[ "$(_metrics_unit_usage demo | od -c | tail -2 | head -1)" == *'\n'* ]] \
  && ok "_metrics_unit_usage ends with a newline" || bad "_metrics_unit_usage has no trailing newline"
( set -euo pipefail
  read -r _m _c < <(_metrics_unit_usage demo)
  exit 0 ) && ok "read of it survives set -e" || bad "read under set -e still aborts"
unset -f systemctl
# No awk format string may contain a raw newline (awk rejects it at parse time).
awk 'BEGIN{exit}' 2>/dev/null && \
  { grep -qE 'printf "[^"]*$' "$LAPN_HOME/modules/05-dashboard.sh" \
      && bad "an awk printf string is broken across lines" \
      || ok "no awk format string split across lines"; }

_dash_init_blocks
# One glyph per value, no trailing newline — wc -m counts characters, not bytes.
[[ "$(_dash_spark 0 50 100 | wc -m)" -eq 3 ]] && ok "sparkline: one glyph per value" \
  || bad "sparkline length $(_dash_spark 0 50 100 | wc -m), expected 3"
[[ "$(_dash_spark 0 50 100)" != "$(_dash_spark 100 50 0)" ]] && ok "sparkline tracks the values" \
  || bad "sparkline ignores its input"
[[ "$(LC_ALL=C; _dash_init_blocks; _dash_spark 0 50 100)" =~ ^[_.~=+*#-]+$ ]] \
  && ok "ASCII fallback on a non-UTF-8 terminal" || bad "ASCII fallback wrong"
rm -rf "$m_dir"; unset LAPN_METRICS_DIR

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

    # Env vars: set, read back, and confirm the value is masked without --show.
    lapn site:env --domain demo.local --set FOO=bar </dev/null >/dev/null \
      && ok "site:env --set" || bad "site:env --set failed"
    grep -q '^FOO=bar$' /etc/lapn/secrets/demo-local/.env \
      && ok "site:env wrote the variable" || bad "FOO=bar not in .env"
    lapn site:env --domain demo.local </dev/null | grep -q 'FOO' \
      && ok "site:env lists the variable" || bad "site:env did not list FOO"
    lapn site:env --domain demo.local </dev/null | grep -q 'bar' \
      && bad "site:env leaked the value without --show" || ok "site:env masks values"

    # Aliases: www. must end up in server_name of BOTH server blocks.
    if lapn site:alias --domain demo.local --add www.demo.local </dev/null >/dev/null; then
      ok "site:alias --add"
      grep -q 'server_name demo.local www.demo.local;' \
        /etc/nginx/sites-available/lapn-demo-local.conf \
        && ok "alias lands in server_name" || bad "alias missing from server_name"
      nginx -t 2>/dev/null && ok "nginx -t after alias" || bad "nginx -t failed after alias"
    else
      bad "site:alias --add failed"
    fi

    # Per-site nginx logs must actually exist (the logrotate rule depended on them).
    curl -fsS -H 'Host: demo.local' "http://127.0.0.1/" >/dev/null 2>&1 || true
    [[ -f /home/sites/demo-local/logs/access.log ]] \
      && ok "per-site nginx access log" || bad "no /home/sites/demo-local/logs/access.log"

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
