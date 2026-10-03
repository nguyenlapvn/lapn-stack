
# --- LapN :443 — appended by ssl:issue (dns-cloudflare / cf-origin). ---
# certbot-nginx does not use this file: certbot writes its own 443 block.
# Placeholders: DOMAIN NAME CERT KEY
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name {{DOMAIN}};

    ssl_certificate     {{CERT}};
    ssl_certificate_key {{KEY}};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

    include /etc/nginx/snippets/lapn-site-{{NAME}}.conf;
}
