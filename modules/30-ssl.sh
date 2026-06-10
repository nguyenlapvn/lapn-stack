#!/usr/bin/env bash
# modules/30-ssl.sh — SSL qua certbot: HTTP-01, DNS-01 (Cloudflare), Origin CA.
# Một cơ chế gia hạn duy nhất: certbot.timer + deploy-hook reload nginx.

MODULE_NAME="SSL / Cloudflare"
MODULE_ORDER=30
MODULE_COMMANDS=("ssl:issue" "ssl:renew" "ssl:status" "ssl:cf-ips-update")

_ssl_parse() {
  SSL_DOMAIN=""; SSL_METHOD=""; SSL_CF_TOKEN=""; SSL_DRYRUN=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain)   SSL_DOMAIN="$2"; shift 2 ;;
      --method)   SSL_METHOD="$2"; shift 2 ;;
      --cf-token) SSL_CF_TOKEN="$2"; shift 2 ;;
      --dry-run)  SSL_DRYRUN=1; shift ;;
      *) shift ;;
    esac
  done
}

# Đảm bảo certbot + timer + deploy hook reload nginx.
_ssl_ensure_certbot() {
  if ! command -v certbot >/dev/null 2>&1; then
    log_step "Cài certbot"
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y certbot python3-certbot-nginx python3-certbot-dns-cloudflare
  fi
  # Deploy hook: reload nginx sau mỗi lần gia hạn (áp cho mọi cert).
  local hookdir="/etc/letsencrypt/renewal-hooks/deploy"
  mkdir -p "$hookdir"
  local hook="$hookdir/lapn-reload-nginx.sh"
  if [[ ! -f "$hook" ]]; then
    printf '#!/usr/bin/env bash\nnginx -t && systemctl reload nginx\n' >"$hook"
    chmod 755 "$hook"
  fi
  systemctl enable --now certbot.timer 2>/dev/null || true
}

cmd_ssl_issue() {
  core_require_root
  _ssl_parse "$@"
  state_init

  local domain; domain="$(resolve_input "domain" "$SSL_DOMAIN" \
    --prompt "Domain cấp SSL" --validate validate_domain)"
  state_site_exists "$domain" || die "Không có site '$domain' (tạo site trước)."

  local method; method="$(resolve_input "method" "$SSL_METHOD" \
    --prompt "Phương thức SSL" --select "certbot-nginx dns-cloudflare cf-origin" \
    --default "certbot-nginx" --validate validate_ssl_method)"

  _ssl_ensure_certbot
  local email; email="$(_ssl_account_email)"

  case "$method" in
    certbot-nginx)   _ssl_issue_http01 "$domain" "$email" ;;
    dns-cloudflare)  _ssl_issue_dns_cf "$domain" "$email" ;;
    cf-origin)       _ssl_issue_cf_origin "$domain" ;;
  esac

  # Bật HSTS + cập nhật state.
  _ssl_enable_hsts
  state_site_set_field "$domain" ssl true
  state_site_set_field "$domain" ssl_method "\"$method\""
  nginx -t && systemctl reload nginx
  audit "OK" "ssl:issue $domain method=$method"
  log_ok "SSL ($method) đã cấp cho $domain."
}

_ssl_account_email() {
  local f="${LAPN_ETC}/ssl_email"
  if [[ -f "$f" ]]; then cat "$f"; return 0; fi
  local email=""
  if [[ "${LAPN_INTERACTIVE:-0}" == "1" ]]; then
    email="$(ui_ask "Email cho Let's Encrypt (thông báo hết hạn)")"
  fi
  if [[ -n "$email" ]]; then
    printf '%s' "$email" >"$f"; printf '%s' "$email"
  else
    printf '--register-unsafely-without-email'
  fi
}

_ssl_email_flag() {
  local e="$1"
  if [[ "$e" == "--register-unsafely-without-email" ]]; then
    printf -- '--register-unsafely-without-email'
  else
    printf -- '-m %s' "$e"
  fi
}

_ssl_issue_http01() {
  local domain="$1" email="$2"
  log_step "Cấp cert HTTP-01 (certbot --nginx) cho $domain"
  local behind_cf; behind_cf="$(state_site_get "$domain" behind_cloudflare)"
  if [[ "$behind_cf" == "true" ]]; then
    log_warn "Site đang sau Cloudflare proxy — HTTP-01 dễ gãy. Cân nhắc --method dns-cloudflare."
  fi
  # shellcheck disable=SC2046
  certbot --nginx -d "$domain" --redirect --agree-tos --non-interactive \
    $(_ssl_email_flag "$email") ${SSL_DRYRUN:+--dry-run} \
    || die "certbot HTTP-01 thất bại."
}

_ssl_issue_dns_cf() {
  local domain="$1" email="$2"
  log_step "Cấp cert DNS-01 qua Cloudflare cho $domain"
  local tokfile="${LAPN_SECRETS}/cloudflare.token"
  if [[ -n "$SSL_CF_TOKEN" ]]; then
    mkdir -p "$LAPN_SECRETS"
    printf 'dns_cloudflare_api_token = %s\n' "$SSL_CF_TOKEN" >"$tokfile"
    chmod 600 "$tokfile"
  fi
  [[ -f "$tokfile" ]] || die "Thiếu CF API token. Truyền --cf-token hoặc tạo $tokfile (Zone.DNS:Edit)."
  chmod 600 "$tokfile"
  # shellcheck disable=SC2046
  certbot certonly --dns-cloudflare --dns-cloudflare-credentials "$tokfile" \
    -d "$domain" -d "*.$domain" --agree-tos --non-interactive \
    $(_ssl_email_flag "$email") ${SSL_DRYRUN:+--dry-run} \
    || certbot certonly --dns-cloudflare --dns-cloudflare-credentials "$tokfile" \
        -d "$domain" --agree-tos --non-interactive \
        $(_ssl_email_flag "$email") ${SSL_DRYRUN:+--dry-run} \
    || die "certbot DNS-01 thất bại."
  _ssl_wire_cert_into_nginx "$domain" "/etc/letsencrypt/live/$domain"
  # Site sau Cloudflare → bật real-IP snippet.
  state_site_set_field "$domain" behind_cloudflare true
  _ssl_enable_cf_realip "$domain"
}

_ssl_issue_cf_origin() {
  local domain="$1"
  log_step "Cài Cloudflare Origin Certificate cho $domain"
  local dir="${LAPN_ETC}/ssl/${domain}"
  mkdir -p "$dir"; chmod 700 "$dir"
  log_info "Tạo Origin Certificate trên dashboard Cloudflare (SSL/TLS → Origin Server)."
  if [[ "${LAPN_INTERACTIVE:-0}" != "1" ]]; then
    die "cf-origin cần dán cert/key — chạy ở chế độ tương tác."
  fi
  log_info "Dán nội dung CERTIFICATE (kết thúc bằng dòng END, rồi Ctrl-D):"
  cat >"$dir/origin.pem"
  log_info "Dán PRIVATE KEY (Ctrl-D để kết thúc):"
  cat >"$dir/origin.key"
  chmod 600 "$dir/origin.key"
  [[ -s "$dir/origin.pem" && -s "$dir/origin.key" ]] || die "Cert/key rỗng."
  _ssl_wire_cert_into_nginx "$domain" "$dir" "origin.pem" "origin.key"
  state_site_set_field "$domain" behind_cloudflare true
  _ssl_enable_cf_realip "$domain"
  log_info "Đặt SSL mode = Full (strict) trên Cloudflare cho $domain."
}

# Chèn listen 443 + đường dẫn cert vào nginx conf của site (cho dns-cf / cf-origin).
_ssl_wire_cert_into_nginx() {
  local domain="$1" certdir="$2" cert="${3:-fullchain.pem}" key="${4:-privkey.pem}"
  local name; name="$(state_site_get "$domain" name)"
  local conf="/etc/nginx/sites-available/lapn-${name}.conf"
  [[ -f "$conf" ]] || die "Không thấy nginx conf của $domain."
  if grep -q "listen 443" "$conf"; then
    log_info "nginx conf đã có block 443 — bỏ qua."
    return 0
  fi
  cat >>"$conf" <<EOF

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${domain};

    ssl_certificate     ${certdir}/${cert};
    ssl_certificate_key ${certdir}/${key};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

    include /etc/nginx/snippets/lapn-https-locations-${name}.conf;
}
EOF
  # Tách phần location của block 80 ra include dùng chung — đơn giản: copy proxy_pass.
  _ssl_extract_locations "$conf" "$name"
}

# Trích các location từ server block 80 thành snippet để block 443 include lại.
_ssl_extract_locations() {
  local conf="$1" name="$2"
  local snip="/etc/nginx/snippets/lapn-https-locations-${name}.conf"
  # Lấy mọi block location { ... } trong file conf gốc.
  awk '/location[ ]/{f=1} f{print} f&&/^\}/{ }' "$conf" | sed -n '/location/,/^}/p' >"$snip" 2>/dev/null || true
  if [[ ! -s "$snip" ]]; then
    # Fallback: proxy chung tới port.
    local port; port="$(jq -r --arg n "$name" '.sites | to_entries[] | select(.value.name==$n) | .value.port' "$LAPN_STATE")"
    cat >"$snip" <<EOF
location / {
    proxy_pass http://127.0.0.1:${port};
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
}
EOF
  fi
}

_ssl_enable_hsts() {
  local snip="/etc/nginx/snippets/lapn-security-headers.conf"
  [[ -f "$snip" ]] || return 0
  sed -i 's|^#add_header Strict-Transport-Security|add_header Strict-Transport-Security|' "$snip"
}

_ssl_enable_cf_realip() {
  local domain="$1" name; name="$(state_site_get "$domain" name)"
  local conf="/etc/nginx/sites-available/lapn-${name}.conf"
  local inc="include /etc/nginx/snippets/lapn-cloudflare-realip.conf;"
  # Đảm bảo snippet đã cài (install.sh cài sẵn); chèn include vào conf nếu chưa có.
  if [[ -f "$conf" ]] && ! grep -q "cloudflare-realip" "$conf"; then
    sed -i "s|server_name ${domain};|server_name ${domain};\n    ${inc}|" "$conf"
  fi
}

cmd_ssl_renew() {
  core_require_root
  _ssl_parse "$@"
  _ssl_ensure_certbot
  log_step "Gia hạn cert"
  certbot renew ${SSL_DRYRUN:+--dry-run}
  nginx -t && systemctl reload nginx
  log_ok "Đã chạy gia hạn."
}

cmd_ssl_status() {
  if command -v certbot >/dev/null 2>&1; then
    certbot certificates 2>/dev/null || true
  else
    log_info "certbot chưa cài."
  fi
  printf '\ncertbot.timer: %s\n' "$(systemctl is-active certbot.timer 2>/dev/null || echo 'inactive')"
}

# ssl:cf-ips-update — refresh dải IP Cloudflare trong snippet realip.
cmd_ssl_cf_ips_update() {
  core_require_root
  local snip="/etc/nginx/snippets/lapn-cloudflare-realip.conf"
  log_step "Cập nhật dải IP Cloudflare"
  local v4 v6
  v4="$(curl -fsS --max-time 10 https://www.cloudflare.com/ips-v4 2>/dev/null || true)"
  v6="$(curl -fsS --max-time 10 https://www.cloudflare.com/ips-v6 2>/dev/null || true)"
  [[ -n "$v4" ]] || die "Không tải được ips-v4 từ Cloudflare."
  {
    printf '# LapN — auto-generated %s\n' "$(date -Iseconds)"
    printf '# --- BEGIN CLOUDFLARE IPS ---\n'
    printf '%s\n' "$v4" | sed 's/^/set_real_ip_from /; s/$/;/'
    printf '%s\n' "$v6" | sed 's/^/set_real_ip_from /; s/$/;/'
    printf '# --- END CLOUDFLARE IPS ---\n'
    printf 'real_ip_header CF-Connecting-IP;\n'
  } >"$snip"
  nginx -t && systemctl reload nginx
  log_ok "Đã cập nhật $snip"
}
