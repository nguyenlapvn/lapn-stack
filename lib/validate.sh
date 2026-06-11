#!/usr/bin/env bash
# lib/validate.sh — validate domain / port / site name / engine.
# Each function returns 0 if valid, otherwise prints a warning + returns 1.

# Domain: a-z0-9- labels, at least one dot, does not start/end with '-'.
validate_domain() {
  local d="$1"
  if [[ "$d" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
    return 0
  fi
  log_warn "Invalid domain: '$d' (valid example: app.example.vn)"
  return 1
}

# Port: number 1-65535. Separate warnings for privileged + service ports.
validate_port() {
  local p="$1"
  if ! [[ "$p" =~ ^[0-9]+$ ]] || (( p < 1 || p > 65535 )); then
    log_warn "Port must be a number 1-65535: '$p'"
    return 1
  fi
  return 0
}

# Internal port for an app: not privileged, does not clash with common service ports.
validate_app_port() {
  local p="$1"
  validate_port "$p" || return 1
  if (( p < 1024 )); then
    log_warn "Do not use a privileged port (<1024) for an app: '$p'"
    return 1
  fi
  local reserved=(22 80 443 3306 5432 6379 27017)
  local r
  for r in "${reserved[@]}"; do
    if (( p == r )); then
      log_warn "Port '$p' clashes with a system service port (SSH/HTTP/DB)."
      return 1
    fi
  done
  return 0
}

# Site name (slug): a-z0-9 and '-', 2-40 characters.
validate_site_name() {
  local n="$1"
  if [[ "$n" =~ ^[a-z0-9][a-z0-9-]{1,39}$ ]]; then return 0; fi
  log_warn "Invalid site name: '$n' (only a-z, 0-9, '-')"
  return 1
}

# Valid DB engine.
validate_db_engine() {
  local e="$1"
  case "$e" in
    mariadb|postgres|mongo|redis) return 0 ;;
    *) log_warn "Unsupported engine: '$e' (mariadb|postgres|mongo|redis)"; return 1 ;;
  esac
}

# Valid app type.
validate_app_type() {
  local t="$1"
  case "$t" in
    nextjs|express|static) return 0 ;;
    *) log_warn "Unsupported app type: '$t' (nextjs|express|static)"; return 1 ;;
  esac
}

# Valid SSL method.
validate_ssl_method() {
  local m="$1"
  case "$m" in
    certbot-nginx|dns-cloudflare|cf-origin) return 0 ;;
    *) log_warn "Invalid SSL method: '$m'"; return 1 ;;
  esac
}

# slugify a domain -> site name (checkin.example.vn -> checkin-example-vn).
slugify_domain() {
  local d="$1"
  printf '%s' "$d" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' \
    | sed -E 's/-+/-/g; s/^-//; s/-$//'
}
