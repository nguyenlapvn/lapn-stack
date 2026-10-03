# LapN — shared body for {{DOMAIN}} -> 127.0.0.1:{{PORT}}.
# Rendered to /etc/nginx/snippets/lapn-site-<name>.conf and included by BOTH the :80
# block and the :443 block that ssl:issue adds, so headers/locations can never drift.
# Placeholders: DOMAIN PORT CLIENT_MAX_BODY CF_REALIP_INCLUDE LOGDIR CANONICAL_REDIRECT

# Real IP when behind Cloudflare (empty if the site does not use CF).
{{CF_REALIP_INCLUDE}}

{{CANONICAL_REDIRECT}}
include /etc/nginx/snippets/lapn-security-headers.conf;
include /etc/nginx/snippets/lapn-block-sensitive.conf;

# Per-site logs. Without these every site shares /var/log/nginx/*.log and
# per-site traffic cannot be told apart. nginx opens these as root, so the
# directory only has to exist; logrotate handles them with copytruncate.
access_log {{LOGDIR}}/access.log;
error_log  {{LOGDIR}}/error.log warn;

client_max_body_size {{CLIENT_MAX_BODY}};

location / {
    limit_req zone=lapn_general burst=20 nodelay;
    proxy_pass http://127.0.0.1:{{PORT}};
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_read_timeout 60s;
    proxy_send_timeout 60s;
}

# Login/auth endpoint: stricter rate limit.
location ~ ^/(api/(login|auth)|login|register) {
    limit_req zone=lapn_auth burst=5 nodelay;
    proxy_pass http://127.0.0.1:{{PORT}};
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
