#!/usr/bin/env bash
# modules/30-ssl.sh — SSL via certbot: HTTP-01, DNS-01 (Cloudflare), Origin CA.
# A single renewal mechanism: certbot.timer + deploy-hook to reload nginx.

MODULE_NAME="SSL"
MODULE_ORDER=30
MODULE_COMMANDS=("ssl:issue" "ssl:renew" "ssl:status" "ssl:cf-ips-update")

_ssl_parse() {
  SSL_DOMAIN=""; SSL_METHOD=""; SSL_CF_TOKEN=""; SSL_DRYRUN=""; SSL_WILDCARD=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain)   SSL_DOMAIN="$2"; shift 2 ;;
      --method)   SSL_METHOD="$2"; shift 2 ;;
      --cf-token) SSL_CF_TOKEN="$2"; shift 2 ;;
      --wildcard) SSL_WILDCARD=1; shift ;;
      --dry-run)  SSL_DRYRUN=1; shift ;;
      *) shift ;;
    esac
  done
}

# Ensure certbot + timer + deploy hook to reload nginx.
_ssl_ensure_certbot() {
  if ! command -v certbot >/dev/null 2>&1; then
    log_step "Install certbot"
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y certbot python3-certbot-nginx python3-certbot-dns-cloudflare
  fi
  # Deploy hook: reload nginx after every renewal (applies to all certs).
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
    --prompt "Domain to issue SSL for" --validate validate_domain)"
  state_site_exists "$domain" || die "No site '$domain' (create the site first)."

  local method; method="$(resolve_input "method" "$SSL_METHOD" \
    --prompt "SSL method" --select "certbot-nginx dns-cloudflare cf-origin" \
    --default "certbot-nginx" --validate validate_ssl_method)"

  # certbot and a Let's Encrypt account email only matter for the two LE methods.
  # cf-origin is a Cloudflare-issued certificate: no ACME, no account, no renewals.
  local email=""
  if [[ "$method" != "cf-origin" ]]; then
    _ssl_ensure_certbot
    email="$(_ssl_account_email)"
  fi

  case "$method" in
    certbot-nginx)   _ssl_issue_http01 "$domain" "$email" ;;
    dns-cloudflare)  _ssl_issue_dns_cf "$domain" "$email" ;;
    cf-origin)       _ssl_issue_cf_origin "$domain" ;;
  esac

  # Enable HSTS + update state.
  _ssl_enable_hsts
  state_site_set_field "$domain" ssl true
  state_site_set_field "$domain" ssl_method "\"$method\""
  nginx -t || die "nginx -t failed after issuing the cert — check /etc/nginx/sites-available/lapn-*.conf."
  systemctl reload nginx
  audit "OK" "ssl:issue $domain method=$method"
  log_ok "SSL ($method) issued for $domain."
}

_ssl_account_email() {
  local f="${LAPN_ETC}/ssl_email"
  if [[ -f "$f" ]]; then cat "$f"; return 0; fi
  local email=""
  if [[ "${LAPN_INTERACTIVE:-0}" == "1" ]]; then
    email="$(ui_ask "Email for Let's Encrypt (expiry notifications)")"
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
  log_step "Issue HTTP-01 cert (certbot --nginx) for $domain"
  local behind_cf; behind_cf="$(state_site_get "$domain" behind_cloudflare)"
  if [[ "$behind_cf" == "true" ]]; then
    log_warn "Site is behind Cloudflare proxy — HTTP-01 is fragile. Consider --method dns-cloudflare."
  fi
  # shellcheck disable=SC2046
  certbot --nginx -d "$domain" --redirect --agree-tos --non-interactive \
    $(_ssl_email_flag "$email") ${SSL_DRYRUN:+--dry-run} \
    || die "certbot HTTP-01 failed."
}

_ssl_issue_dns_cf() {
  local domain="$1" email="$2"
  log_step "Issue DNS-01 cert via Cloudflare for $domain"
  local tokfile="${LAPN_SECRETS}/cloudflare.token"
  if [[ -n "$SSL_CF_TOKEN" ]]; then
    mkdir -p "$LAPN_SECRETS"
    printf 'dns_cloudflare_api_token = %s\n' "$SSL_CF_TOKEN" >"$tokfile"
    chmod 600 "$tokfile"
  fi
  [[ -f "$tokfile" ]] || die "Missing CF API token. Pass --cf-token or create $tokfile (Zone.DNS:Edit)."
  chmod 600 "$tokfile"
  # Opt-in only. Asking for *.$domain unprompted puts names in the certificate that
  # nobody requested, and on a token scoped to one record it fails the whole order.
  local -a names=(-d "$domain")
  [[ -n "$SSL_WILDCARD" ]] && { names+=(-d "*.$domain"); log_info "Also requesting the wildcard *.$domain"; }
  # shellcheck disable=SC2046
  certbot certonly --dns-cloudflare --dns-cloudflare-credentials "$tokfile" \
    "${names[@]}" --agree-tos --non-interactive \
    $(_ssl_email_flag "$email") ${SSL_DRYRUN:+--dry-run} \
    || die "certbot DNS-01 failed."
  # Set behind_cloudflare BEFORE wiring: the re-render picks the real-IP snippet up.
  state_site_set_field "$domain" behind_cloudflare true
  _ssl_wire_cert_into_nginx "$domain" "/etc/letsencrypt/live/$domain"
}

_ssl_issue_cf_origin() {
  local domain="$1"
  log_step "Install Cloudflare Origin Certificate for $domain"
  local dir="${LAPN_ETC}/ssl/${domain}"
  mkdir -p "$dir"; chmod 700 "$dir"
  log_info "Create the Origin Certificate in the Cloudflare dashboard (SSL/TLS → Origin Server)."
  if [[ "${LAPN_INTERACTIVE:-0}" != "1" ]]; then
    die "cf-origin requires pasting cert/key — run in interactive mode."
  fi
  log_info "Paste the CERTIFICATE content (end with the END line, then Ctrl-D):"
  cat >"$dir/origin.pem"
  log_info "Paste the PRIVATE KEY (Ctrl-D to finish):"
  cat >"$dir/origin.key"
  chmod 600 "$dir/origin.key"
  [[ -s "$dir/origin.pem" && -s "$dir/origin.key" ]] || die "Cert/key is empty."
  # Set behind_cloudflare BEFORE wiring: the re-render picks the real-IP snippet up.
  state_site_set_field "$domain" behind_cloudflare true
  _ssl_wire_cert_into_nginx "$domain" "$dir" "origin.pem" "origin.key"
  log_info "Set SSL mode = Full (strict) on Cloudflare for $domain."
}

# Add the :443 server block for dns-cloudflare / cf-origin (certbot-nginx writes its own).
# The :80 block is re-rendered from the templates first, which (a) recreates the shared
# body snippet both blocks include — so security headers, rate limits, the Cloudflare
# real-IP include and, for static sites, `root` are identical on HTTP and HTTPS — and
# (b) drops any previous :443 block, making a re-issue idempotent.
_ssl_wire_cert_into_nginx() {
  local domain="$1" certdir="$2" cert="${3:-fullchain.pem}" key="${4:-privkey.pem}"
  local name; name="$(state_site_get "$domain" name)"
  local conf="/etc/nginx/sites-available/lapn-${name}.conf"
  site_render_nginx "$domain" || die "Rendering the nginx config for $domain failed."
  # Left over from LapN < 0.3, when the locations were copied instead of shared.
  rm -f "/etc/nginx/snippets/lapn-https-locations-${name}.conf"
  sed -e "s#{{DOMAIN}}#${domain}#g" \
      -e "s#{{NAME}}#${name}#g" \
      -e "s#{{CERT}}#${certdir}/${cert}#g" \
      -e "s#{{KEY}}#${certdir}/${key}#g" \
      "$LAPN_HOME/templates/nginx/https.conf.tpl" >>"$conf"
}

_ssl_enable_hsts() {
  local snip="/etc/nginx/snippets/lapn-security-headers.conf"
  [[ -f "$snip" ]] || return 0
  sed -i 's|^#add_header Strict-Transport-Security|add_header Strict-Transport-Security|' "$snip"
}

cmd_ssl_renew() {
  core_require_root
  _ssl_parse "$@"
  _ssl_ensure_certbot
  log_step "Renew cert"
  certbot renew ${SSL_DRYRUN:+--dry-run}
  nginx -t && systemctl reload nginx
  log_ok "Renewal run complete."
}

cmd_ssl_status() {
  if command -v certbot >/dev/null 2>&1; then
    certbot certificates 2>/dev/null || true
  else
    log_info "certbot is not installed."
  fi
  printf '\ncertbot.timer: %s\n' "$(systemctl is-active certbot.timer 2>/dev/null || echo 'inactive')"
}

# ssl:cf-ips-update — refresh Cloudflare IP ranges in the realip snippet.
cmd_ssl_cf_ips_update() {
  core_require_root
  local snip="/etc/nginx/snippets/lapn-cloudflare-realip.conf"
  log_step "Update Cloudflare IP ranges"
  local v4 v6
  v4="$(curl -fsS --max-time 10 https://www.cloudflare.com/ips-v4 2>/dev/null || true)"
  v6="$(curl -fsS --max-time 10 https://www.cloudflare.com/ips-v6 2>/dev/null || true)"
  [[ -n "$v4" ]] || die "Failed to download ips-v4 from Cloudflare."
  {
    printf '# LapN — auto-generated %s\n' "$(date -Iseconds)"
    printf '# --- BEGIN CLOUDFLARE IPS ---\n'
    printf '%s\n' "$v4" | sed 's/^/set_real_ip_from /; s/$/;/'
    printf '%s\n' "$v6" | sed 's/^/set_real_ip_from /; s/$/;/'
    printf '# --- END CLOUDFLARE IPS ---\n'
    printf 'real_ip_header CF-Connecting-IP;\n'
  } >"$snip"
  nginx -t && systemctl reload nginx
  log_ok "Updated $snip"
}
