# LapN — serve static build directly (no systemd unit).
# Placeholders: {{DOMAIN}} {{ROOT}} {{CLIENT_MAX_BODY}} {{CF_REALIP_INCLUDE}}
server {
    listen 80;
    listen [::]:80;
    server_name {{DOMAIN}};

    root {{ROOT}};
    index index.html;

    {{CF_REALIP_INCLUDE}}

    include /etc/nginx/snippets/lapn-security-headers.conf;
    include /etc/nginx/snippets/lapn-block-sensitive.conf;

    client_max_body_size {{CLIENT_MAX_BODY}};

    location / {
        limit_req zone=lapn_general burst=20 nodelay;
        try_files $uri $uri/ /index.html;
    }

    # Cache hashed assets.
    location ~* \.(?:css|js|woff2?|ttf|otf|eot|svg|png|jpg|jpeg|gif|ico|webp|avif)$ {
        expires 30d;
        add_header Cache-Control "public, max-age=2592000, immutable";
        try_files $uri =404;
    }
}
