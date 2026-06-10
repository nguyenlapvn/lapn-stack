#!/usr/bin/env bash
# modules/90-doctor.sh — audit toàn server. Output ✅/⚠️/❌.

MODULE_NAME="Chẩn đoán (doctor)"
MODULE_ORDER=90
MODULE_COMMANDS=("doctor")

_DR_OK=0; _DR_WARN=0; _DR_ERR=0
_dr_ok()   { printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; _DR_OK=$((_DR_OK+1)); }
_dr_warn() { printf '  %s⚠%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; _DR_WARN=$((_DR_WARN+1)); }
_dr_err()  { printf '  %s✗%s %s\n' "$C_RED" "$C_RESET" "$*"; _DR_ERR=$((_DR_ERR+1)); }

cmd_doctor() {
  state_init
  printf '%s%sLapN doctor%s — %s\n' "$C_BOLD" "$C_BLUE" "$C_RESET" "$(date -Iseconds)"

  _dr_section "Hệ thống"
  _dr_check_disk_ram

  _dr_section "Cấu hình nền"
  _dr_check_logrotate
  _dr_check_journald
  _dr_check_firewall
  _dr_check_certbot_timer

  _dr_section "Database (bind localhost)"
  _dr_check_db_binds

  _dr_section "Sites"
  _dr_check_sites

  printf '\n%sKết quả:%s %s✓ %d%s  %s⚠ %d%s  %s✗ %d%s\n' \
    "$C_BOLD" "$C_RESET" "$C_GREEN" "$_DR_OK" "$C_RESET" \
    "$C_YELLOW" "$_DR_WARN" "$C_RESET" "$C_RED" "$_DR_ERR" "$C_RESET"
  (( _DR_ERR == 0 ))
}

_dr_section() { printf '\n%s%s%s\n' "$C_BOLD" "$1" "$C_RESET"; }

_dr_check_disk_ram() {
  local diskpct rammb
  diskpct="$(df -P / | awk 'NR==2{gsub("%","",$5); print $5}')"
  if (( diskpct >= 90 )); then _dr_err "Disk / đầy ${diskpct}%"; else _dr_ok "Disk / dùng ${diskpct}%"; fi
  rammb="$(free -m | awk '/^Mem:/{print $2}')"
  if (( rammb < 1900 )); then _dr_warn "RAM ${rammb}MB (<2GB — build dễ OOM)"; else _dr_ok "RAM ${rammb}MB"; fi
}

_dr_check_logrotate() {
  if [[ -f /etc/logrotate.d/lapn ]]; then _dr_ok "logrotate đã cài"; else _dr_err "Thiếu /etc/logrotate.d/lapn"; fi
}

_dr_check_journald() {
  if grep -qE '^\s*SystemMaxUse=' /etc/systemd/journald.conf 2>/dev/null; then
    _dr_ok "journald có trần dung lượng"
  else
    _dr_warn "journald chưa đặt SystemMaxUse (log có thể phình)"
  fi
}

_dr_check_firewall() {
  if ! command -v ufw >/dev/null 2>&1; then _dr_warn "ufw chưa cài"; return; fi
  if ufw status 2>/dev/null | grep -q "Status: active"; then
    _dr_ok "UFW active"
  else
    _dr_warn "UFW chưa bật"
  fi
  # Cảnh báo nếu mở port DB ra ngoài.
  local p
  for p in 3306 5432 27017 6379; do
    if ufw status 2>/dev/null | grep -qE "^${p}[/ ].*ALLOW"; then
      _dr_err "UFW đang MỞ port DB $p ra ngoài — đóng ngay (DB chỉ nên qua SSH tunnel)!"
    fi
  done
}

_dr_check_certbot_timer() {
  if command -v certbot >/dev/null 2>&1; then
    if systemctl is-active --quiet certbot.timer; then _dr_ok "certbot.timer active (auto-renew)"; else _dr_warn "certbot.timer không chạy"; fi
  fi
}

_dr_check_db_binds() {
  local e svc conf bind
  for e in mariadb mysql postgres mongo redis; do
    state_service_installed "$e" || continue
    case "$e" in
      mariadb|mysql)
        if ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE '^(0\.0\.0\.0|\*|::):3306$'; then
          _dr_err "$e bind 0.0.0.0:3306 — phải là 127.0.0.1!"
        else _dr_ok "$e bind localhost"; fi ;;
      postgres)
        if ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE '^(0\.0\.0\.0|\*|::):5432$'; then
          _dr_err "postgres bind 0.0.0.0:5432 — phải localhost!"
        else _dr_ok "postgres bind localhost"; fi ;;
      mongo)
        if ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE '^(0\.0\.0\.0|\*|::):27017$'; then
          _dr_err "mongo bind 0.0.0.0:27017 — phải localhost!"
        else _dr_ok "mongo bind localhost"; fi ;;
      redis)
        if ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE '^(0\.0\.0\.0|\*):6379$'; then
          _dr_err "redis bind 0.0.0.0:6379 — phải localhost!"
        else _dr_ok "redis bind localhost"; fi ;;
    esac
  done
}

_dr_check_sites() {
  local count; count="$(state_jq -r '.sites | length')"
  if [[ "$count" == "0" ]]; then printf '  (chưa có site)\n'; return; fi
  local domain
  while IFS= read -r domain; do
    local name type port user ssl method behind envfile
    name="$(state_site_get "$domain" name)"
    type="$(state_site_get "$domain" type)"
    port="$(state_site_get "$domain" port)"
    user="$(state_site_get "$domain" user)"
    ssl="$(state_site_get "$domain" ssl)"
    method="$(state_site_get "$domain" ssl_method)"
    behind="$(state_site_get "$domain" behind_cloudflare)"
    envfile="${LAPN_SECRETS}/${name}/.env"

    printf '  %s%s%s\n' "$C_BOLD" "$domain" "$C_RESET"

    # .env quyền 600
    if [[ -f "$envfile" ]]; then
      local perm; perm="$(stat -c '%a' "$envfile" 2>/dev/null)"
      [[ "$perm" == "600" ]] && _dr_ok ".env quyền 600" || _dr_err ".env quyền $perm (phải 600)"
    else
      _dr_warn ".env không tồn tại"
    fi

    # app bind localhost
    if [[ "$type" != "static" ]]; then
      if ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE "^(0\.0\.0\.0|\*):${port}$"; then
        _dr_err "app bind 0.0.0.0:${port} — phải 127.0.0.1"
      else
        _dr_ok "app bind localhost:${port}"
      fi
      systemctl is-active --quiet "lapn-${name}.service" && _dr_ok "unit active" || _dr_err "unit không chạy"
    fi

    # SSL method vs Cloudflare
    if [[ "$ssl" == "true" && "$method" == "certbot-nginx" && "$behind" == "true" ]]; then
      _dr_warn "dùng HTTP-01 nhưng sau Cloudflare — gia hạn sẽ gãy, chuyển dns-cloudflare"
    fi

    # cert hết hạn
    if [[ "$ssl" == "true" ]] && command -v openssl >/dev/null; then
      _dr_check_cert_expiry "$domain"
    fi
  done < <(state_sites_list)
}

_dr_check_cert_expiry() {
  local domain="$1" certfile=""
  for certfile in "/etc/letsencrypt/live/$domain/cert.pem" "${LAPN_ETC}/ssl/$domain/origin.pem"; do
    [[ -f "$certfile" ]] || continue
    local end days
    end="$(openssl x509 -enddate -noout -in "$certfile" 2>/dev/null | cut -d= -f2)"
    [[ -z "$end" ]] && return
    days=$(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
    if (( days < 14 )); then _dr_err "cert hết hạn trong ${days} ngày"; \
    elif (( days < 30 )); then _dr_warn "cert còn ${days} ngày"; \
    else _dr_ok "cert còn ${days} ngày"; fi
    return
  done
}
