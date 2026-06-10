#!/usr/bin/env bash
# tests/smoke.sh — test trên container/VM Ubuntu trắng.
# Cài trắng → tạo site demo (express) → curl 200 → xóa site.
# Lưu ý: cần systemd thật (image jrei/systemd-ubuntu:24.04 --privileged) cho phần unit.
set -euo pipefail

LAPN_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()   { printf '  [✓] %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  [✗] %s\n' "$*"; FAIL=$((FAIL+1)); }
sect() { printf '\n== %s ==\n' "$*"; }

# --- 0) Lint cú pháp toàn bộ script (chạy được ở mọi nơi, kể cả không systemd) ---
sect "bash -n (syntax) toàn bộ script"
syntax_ok=1
while IFS= read -r f; do
  if bash -n "$f" 2>/tmp/lapn-syn.err; then
    ok "syntax: ${f#"$LAPN_HOME"/}"
  else
    bad "syntax: ${f#"$LAPN_HOME"/} -> $(cat /tmp/lapn-syn.err)"; syntax_ok=0
  fi
done < <(find "$LAPN_HOME" -name '*.sh' -o -path '*/bin/lapn' | sort)

# --- 1) shellcheck nếu có ---
if command -v shellcheck >/dev/null 2>&1; then
  sect "shellcheck"
  if shellcheck -S error -x "$LAPN_HOME"/lib/*.sh "$LAPN_HOME"/modules/*.sh "$LAPN_HOME"/bin/lapn 2>/tmp/lapn-sc.err; then
    ok "shellcheck (mức error) sạch"
  else
    bad "shellcheck: xem /tmp/lapn-sc.err"
  fi
else
  printf '  (bỏ qua shellcheck — chưa cài)\n'
fi

# --- 2) Router load được, dựng registry, help chạy ---
sect "router & module discovery"
if LAPN_HOME="$LAPN_HOME" bash "$LAPN_HOME/bin/lapn" help >/tmp/lapn-help.txt 2>&1; then
  ok "lapn help chạy"
  grep -q "site:create" /tmp/lapn-help.txt && ok "module site khám phá được" || bad "không thấy site:create trong help"
  grep -q "db:install"  /tmp/lapn-help.txt && ok "module db khám phá được"   || bad "không thấy db:install"
else
  bad "lapn help lỗi: $(cat /tmp/lapn-help.txt)"
fi

# --- 3) Validate helpers ---
sect "validate.sh"
# shellcheck source=/dev/null
source "$LAPN_HOME/lib/log.sh"
# shellcheck source=/dev/null
source "$LAPN_HOME/lib/validate.sh"
validate_domain "app.example.vn" && ok "domain hợp lệ pass" || bad "domain hợp lệ fail"
validate_domain "khong-co-cham" 2>/dev/null && bad "domain sai lại pass" || ok "domain sai bị chặn"
validate_app_port "3005" && ok "port app hợp lệ" || bad "port app fail"
validate_app_port "80" 2>/dev/null && bad "port 80 lại pass" || ok "port dịch vụ bị chặn"
[[ "$(slugify_domain 'Checkin.Example.VN')" == "checkin-example-vn" ]] && ok "slugify" || bad "slugify sai"

# --- 4) Luồng end-to-end (chỉ khi là root + có systemd) ---
if (( EUID == 0 )) && pidof systemd >/dev/null 2>&1; then
  sect "end-to-end (root + systemd)"
  bash "$LAPN_HOME/install.sh" </dev/null || bad "install.sh lỗi"
  # Tạo app express demo cục bộ.
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
    lapn site:delete --domain demo.local --force </dev/null && ok "site:delete" || bad "site:delete lỗi"
  else
    bad "site:create lỗi"
  fi
else
  printf '\n  (bỏ qua end-to-end — cần root + systemd; chạy trong jrei/systemd-ubuntu)\n'
fi

# --- Kết quả ---
printf '\n== KẾT QUẢ: %d pass, %d fail ==\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
