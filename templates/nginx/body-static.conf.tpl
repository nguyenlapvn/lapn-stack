# LapN — shared body for the static site {{DOMAIN}} (web root {{ROOT}}).
# Rendered to /etc/nginx/snippets/lapn-site-<name>.conf and included by BOTH the :80
# block and the :443 block that ssl:issue adds — that is why `root` lives here and not
# in the server template: the 443 block needs it too.
# Placeholders: DOMAIN ROOT CLIENT_MAX_BODY CF_REALIP_INCLUDE LOGDIR CANONICAL_REDIRECT

# Real IP when behind Cloudflare (empty if the site does not use CF).
{{CF_REALIP_INCLUDE}}

root {{ROOT}};
index index.html;

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
    try_files $uri $uri/ /index.html;
}

# Cache hashed assets. The security headers are re-included on purpose: an add_header
# inside a location replaces every inherited add_header instead of adding to them.
location ~* \.(?:css|js|woff2?|ttf|otf|eot|svg|png|jpg|jpeg|gif|ico|webp|avif)$ {
    include /etc/nginx/snippets/lapn-security-headers.conf;
    expires 30d;
    add_header Cache-Control "public, max-age=2592000, immutable";
    try_files $uri =404;
}
