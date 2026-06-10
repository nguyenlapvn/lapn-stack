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
  grep -q "db:install"  /tmp/lapn-help.txt && ok "db module discovered"   || bad "db:install not found"
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

# --- 4) End-to-end flow (only when root + systemd) ---
if (( EUID == 0 )) && pidof systemd >/dev/null 2>&1; then
  sect "end-to-end (root + systemd)"
  bash "$LAPN_HOME/install.sh" </dev/null || bad "install.sh failed"
  # Create a local demo express app.
  demo=/tmp/lapn-demo
  mkdir -p "$demo"
  cat >"$demo/server.js" <<'JS'
const http=require('http');const p=process.env.PORT||3000;
http.createServer((_,res)=>{res.end('ok')}).listen(p,'127.0.0.1');
JS
  cat >"$demo/package.json" <<'JSON'
{"name":"demo","version":"1.0.0","main":"server.js","dependencies":{"express":"^4"}}
JSON
  ( cd "$demo" && git init -q && git add -A && git commit -qm init )
  if lapn site:create --domain demo.local --type express --node 20 --git "file://$demo" </dev/null; then
    ok "site:create demo.local"
    port="$(jq -r '.sites["demo.local"].port' /etc/lapn/sites.json)"
    sleep 2
    curl -fsS "http://127.0.0.1:${port}/" >/dev/null && ok "curl 200 (port $port)" || bad "curl fail"
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
