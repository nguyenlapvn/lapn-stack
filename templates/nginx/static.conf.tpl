# LapN — serve a static build directly (no systemd unit). {{DOMAIN}} -> {{ROOT}}
# The web root + locations live in the per-site body snippet so the :443 block added
# by ssl:issue can include exactly the same configuration.
# Placeholders: DOMAIN SERVER_NAMES NAME ROOT
server {
    listen 80;
    listen [::]:80;
    server_name {{SERVER_NAMES}};

    include /etc/nginx/snippets/lapn-site-{{NAME}}.conf;
}
