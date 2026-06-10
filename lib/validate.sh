#!/usr/bin/env bash
# lib/validate.sh — validate domain / port / tên site / engine.
# Mỗi hàm return 0 nếu hợp lệ, ngược lại in cảnh báo + return 1.

# Domain: nhãn a-z0-9-, có ít nhất một dấu chấm, không bắt đầu/kết thúc bằng '-'.
validate_domain() {
  local d="$1"
  if [[ "$d" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
    return 0
  fi
  log_warn "Domain không hợp lệ: '$d' (vd hợp lệ: app.example.vn)"
  return 1
}

# Port: số 1-65535. Cảnh báo riêng cho privileged + port dịch vụ.
validate_port() {
  local p="$1"
  if ! [[ "$p" =~ ^[0-9]+$ ]] || (( p < 1 || p > 65535 )); then
    log_warn "Port phải là số 1-65535: '$p'"
    return 1
  fi
  return 0
}

# Port nội bộ cho app: không privileged, không đụng port dịch vụ thường gặp.
validate_app_port() {
  local p="$1"
  validate_port "$p" || return 1
  if (( p < 1024 )); then
    log_warn "Không dùng privileged port (<1024) cho app: '$p'"
    return 1
  fi
  local reserved=(22 80 443 3306 5432 6379 27017)
  local r
  for r in "${reserved[@]}"; do
    if (( p == r )); then
      log_warn "Port '$p' trùng port dịch vụ hệ thống (SSH/HTTP/DB)."
      return 1
    fi
  done
  return 0
}

# Tên site (slug): a-z0-9 và dấu '-', 2-40 ký tự.
validate_site_name() {
  local n="$1"
  if [[ "$n" =~ ^[a-z0-9][a-z0-9-]{1,39}$ ]]; then return 0; fi
  log_warn "Tên site không hợp lệ: '$n' (chỉ a-z, 0-9, '-')"
  return 1
}

# Engine DB hợp lệ.
validate_db_engine() {
  local e="$1"
  case "$e" in
    mariadb|mysql|postgres|mongo|redis) return 0 ;;
    *) log_warn "Engine không hỗ trợ: '$e' (mariadb|mysql|postgres|mongo|redis)"; return 1 ;;
  esac
}

# App type hợp lệ.
validate_app_type() {
  local t="$1"
  case "$t" in
    nextjs|express|static) return 0 ;;
    *) log_warn "Loại app không hỗ trợ: '$t' (nextjs|express|static)"; return 1 ;;
  esac
}

# SSL method hợp lệ.
validate_ssl_method() {
  local m="$1"
  case "$m" in
    certbot-nginx|dns-cloudflare|cf-origin) return 0 ;;
    *) log_warn "SSL method không hợp lệ: '$m'"; return 1 ;;
  esac
}

# slug hóa domain -> tên site (checkin.example.vn -> checkin-example-vn).
slugify_domain() {
  local d="$1"
  printf '%s' "$d" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' \
    | sed -E 's/-+/-/g; s/^-//; s/-$//'
}
