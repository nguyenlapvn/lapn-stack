# LapN — base .env for site {{DOMAIN}}. Mode 600, owner = site user.
# Source of truth: /etc/lapn/secrets/{{NAME}}/.env
NODE_ENV=production
HOST=127.0.0.1
PORT={{PORT}}

# DB connection variable inserted by db:create (if any).
# DATABASE_URL=...
