# LapN — base .env for site {{DOMAIN}}. Mode 600, owner root.
# Source of truth: /etc/lapn/secrets/{{NAME}}/.env
# systemd injects these into the app via EnvironmentFile= (read as root), which is why
# the site user does not need — and does not get — read access to this file. The
# <app>/.env symlink exists for the admin, not for dotenv.
NODE_ENV=production
HOST=127.0.0.1
PORT={{PORT}}

# DB connection variable inserted by db:create (if any).
# DATABASE_URL=...
