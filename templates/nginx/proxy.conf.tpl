# LapN — reverse proxy for a Node.js site. {{DOMAIN}} -> 127.0.0.1:{{PORT}}
# Everything except `listen`/`server_name` lives in the per-site body snippet so the
# :443 block added by ssl:issue can include exactly the same configuration.
# Placeholders: DOMAIN NAME PORT
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    listen [::]:80;
    server_name {{DOMAIN}};

    include /etc/nginx/snippets/lapn-site-{{NAME}}.conf;
}
