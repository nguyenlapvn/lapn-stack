#!/usr/bin/env bash
# modules/20-db.sh — Database MANAGEMENT: create / drop / console / status / remote.
# Per-site user, bind localhost. Remote via Navicat over SSH tunnel (db:remote).
# NOTE: installing the engine software (mariadb/postgres/mongo/redis) lives in
#       the Stack module. cmd_db_install stays here as a function the Stack calls and
#       remains usable via the CLI (lapn db:install <engine>), just hidden from the menu.

MODULE_NAME="Database"
MODULE_ORDER=20
MODULE_COMMANDS=("db:status" "db:list" "db:create" "db:drop" "db:backup" "db:console" "db:remote")
# Friendly interactive submenu: pick an engine, then its actions (CLI still uses db:* above).
MODULE_MENU="database_menu"

_db_parse() {
  DB_SITE=""; DB_ENGINE=""; DB_FORCE=""
  DBR_ADD=""; DBR_DEL=""; DBR_INFO=""; DBR_USER=""; DBR_KEY=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --site)   DB_SITE="$2"; shift 2 ;;
      --engine) DB_ENGINE="$2"; shift 2 ;;
      --force)  DB_FORCE=1; shift ;;
      --add)    DBR_ADD=1; shift ;;
      --del)    DBR_DEL=1; shift ;;
      --info)   DBR_INFO=1; shift ;;
      --user)   DBR_USER="$2"; shift 2 ;;
      --key)    DBR_KEY="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
}

_db_root_secret() {
  local engine="$1"
  printf '%s/_db/%s.root' "${LAPN_SECRETS}" "$engine"
}

_db_gen_pass() { openssl rand -base64 24 | tr -d '/+=' | head -c 24; }

# ============ INSTALL ============
cmd_db_install() {
  core_require_root
  local engine="" force=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) force=1; shift ;;
      *) [[ -z "$engine" ]] && engine="$1"; shift ;;
    esac
  done
  [[ -z "$engine" ]] && engine="$(resolve_input "engine" "" --prompt "Engine to install" \
    --select "mariadb postgres mongo redis" --validate validate_db_engine)"
  validate_db_engine "$engine" || die "Invalid engine."

  if [[ -z "$force" ]] && state_service_installed "$engine"; then
    log_info "Engine '$engine' already installed (idempotent — skipping). Use --force to reinstall."
    return 0
  fi
  mkdir -p "${LAPN_SECRETS}/_db"; chmod 700 "${LAPN_SECRETS}/_db"
  export DEBIAN_FRONTEND=noninteractive

  # Each installer must return non-zero on failure. Do NOT mark the engine as
  # installed if the install failed (set -e may be suppressed when called from the
  # menu via `( ... ) || ...`, so check the return explicitly).
  case "$engine" in
    mariadb)  _db_install_mariadb  || die "MariaDB install failed." ;;
    postgres) _db_install_postgres || die "PostgreSQL install failed." ;;
    mongo)    _db_install_mongo    || die "MongoDB install failed (check Ubuntu version support)." ;;
    redis)    _db_install_redis    || die "Redis install failed." ;;
  esac

  local ver port
  port="$(_db_engine_port "$engine")"
  ver="$(_db_engine_version "$engine")"
  state_service_put "$engine" \
    "$(jq -n --arg v "$ver" --arg b "127.0.0.1" --argjson p "$port" \
        '{installed:true, version:$v, bind:$b, port:$p}')"
  audit "OK" "db:install $engine"
  log_ok "Installed $engine (bind 127.0.0.1:$port)."
}

_db_engine_port() {
  case "$1" in
    mariadb) echo 3306 ;;
    postgres) echo 5432 ;;
    mongo) echo 27017 ;;
    redis) echo 6379 ;;
  esac
}
_db_engine_version() {
  case "$1" in
    mariadb) mariadb --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 ;;
    postgres) psql --version 2>/dev/null | grep -oE '[0-9]+' | head -n1 ;;
    mongo)   mongod --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 ;;
    redis)   redis-server --version 2>/dev/null | grep -oE 'v=[0-9.]+' | cut -d= -f2 ;;
  esac
}

_db_install_mariadb() {
  log_step "Install MariaDB"
  apt-get install -y mariadb-server
  # Bind localhost.
  local cfg="/etc/mysql/mariadb.conf.d/99-lapn.cnf"
  printf '[mysqld]\nbind-address = 127.0.0.1\n' >"$cfg"
  systemctl enable --now mariadb
  systemctl restart mariadb
  # Harden: set root password, remove anonymous + test db.
  local rootpass; rootpass="$(_db_gen_pass)"
  printf '%s' "$rootpass" >"$(_db_root_secret mariadb)"; chmod 600 "$(_db_root_secret mariadb)"
  mysql <<SQL || true
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
SQL
  log_ok "MariaDB root password saved at $(_db_root_secret mariadb)"
}

_db_install_postgres() {
  log_step "Install PostgreSQL"
  apt-get install -y postgresql
  # listen localhost (already localhost by default; force it to be safe).
  local conf; conf="$(sudo -u postgres psql -t -c 'SHOW config_file;' 2>/dev/null | xargs || true)"
  if [[ -n "$conf" && -f "$conf" ]]; then
    sed -i "s/^#\?listen_addresses.*/listen_addresses = 'localhost'/" "$conf"
  fi
  systemctl enable --now postgresql
  systemctl restart postgresql
  log_ok "PostgreSQL listening on localhost."
}

_db_install_mongo() {
  # MongoDB 7.0 does NOT have a repo for Ubuntu 24.04 (noble) -> 404.
  # 8.0 supports both 22.04 (jammy) and 24.04 (noble), so use it.
  local mver="8.0"
  local codename; codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  log_step "Install MongoDB ${mver} (official repo, ${codename})"
  case "$codename" in
    jammy|noble) : ;;
    *) log_warn "MongoDB repo may not support '$codename'; trying ${mver} anyway." ;;
  esac

  apt-get install -y gnupg curl || return 1
  curl -fsSL "https://www.mongodb.org/static/pgp/server-${mver}.asc" \
    | gpg -o "/usr/share/keyrings/mongodb-server-${mver}.gpg" --dearmor --yes || return 1
  echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-${mver}.gpg ] https://repo.mongodb.org/apt/ubuntu ${codename}/mongodb-org/${mver} multiverse" \
    >"/etc/apt/sources.list.d/mongodb-org-${mver}.list"
  apt-get update -y || true   # other repos may warn; the install step below confirms mongo repo
  if ! apt-get install -y mongodb-org; then
    log_error "Could not install mongodb-org (repo for '$codename' unavailable). See https://www.mongodb.com/docs/manual/administration/install-on-linux/"
    return 1
  fi

  # bind localhost + enable auth.
  sed -i 's/^\( *bindIp:\).*/\1 127.0.0.1/' /etc/mongod.conf 2>/dev/null || true
  if ! grep -q '^security:' /etc/mongod.conf 2>/dev/null; then
    printf '\nsecurity:\n  authorization: enabled\n' >>/etc/mongod.conf
  fi
  systemctl enable --now mongod || return 1
  # Create admin user (localhost exception applies before the first user exists).
  local rootpass; rootpass="$(_db_gen_pass)"
  printf '%s' "$rootpass" >"$(_db_root_secret mongo)"; chmod 600 "$(_db_root_secret mongo)"
  systemctl restart mongod; sleep 3
  mongosh --quiet --eval "db.getSiblingDB('admin').createUser({user:'lapnadmin',pwd:'${rootpass}',roles:['root']})" 2>/dev/null \
    || log_warn "Mongo admin may already exist."
}

_db_install_redis() {
  log_step "Install Redis"
  apt-get install -y redis-server
  local conf="/etc/redis/redis.conf"
  local pass; pass="$(_db_gen_pass)"
  printf '%s' "$pass" >"$(_db_root_secret redis)"; chmod 600 "$(_db_root_secret redis)"
  if [[ -f "$conf" ]]; then
    sed -i 's/^# *requirepass .*/requirepass '"$pass"'/; s/^requirepass .*/requirepass '"$pass"'/' "$conf"
    grep -q '^requirepass' "$conf" || printf 'requirepass %s\n' "$pass" >>"$conf"
    sed -i 's/^bind .*/bind 127.0.0.1 ::1/' "$conf"
    grep -q '^maxmemory ' "$conf" || printf 'maxmemory 256mb\nmaxmemory-policy allkeys-lru\n' >>"$conf"
    # Disable dangerous commands.
    grep -q 'rename-command FLUSHALL' "$conf" || printf 'rename-command FLUSHALL ""\nrename-command FLUSHDB ""\n' >>"$conf"
  fi
  systemctl enable --now redis-server
  systemctl restart redis-server
  log_ok "Redis requirepass saved at $(_db_root_secret redis)"
}

# ============ STATUS ============
cmd_db_status() {
  state_init
  printf '%s%-10s %-9s %-8s %-7s %s%s\n' "$C_BOLD" "ENGINE" "INSTALLED" "VERSION" "PORT" "ACTIVE" "$C_RESET"
  local e svc
  for e in mariadb postgres mongo redis; do
    local inst="no" ver="-" port="-" active="-"
    if state_service_installed "$e"; then
      inst="yes"
      ver="$(state_jq -r --arg e "$e" '.services[$e].version // "-"')"
      port="$(state_jq -r --arg e "$e" '.services[$e].port // "-"')"
      case "$e" in
        mariadb) svc=mariadb ;; postgres) svc=postgresql ;;
        mongo) svc=mongod ;; redis) svc=redis-server ;;
      esac
      active="$(systemctl is-active "$svc" 2>/dev/null || echo '?')"
    fi
    printf '%-10s %-9s %-8s %-7s %s\n' "$e" "$inst" "$ver" "$port" "$active"
  done
}

# ============ CREATE ============
cmd_db_create() {
  core_require_root
  _db_parse "$@"
  state_init
  local domain; domain="$(resolve_input "domain" "$DB_SITE" --prompt "Site (domain)" --validate validate_domain)"
  state_site_exists "$domain" || die "No site '$domain'."
  local engine; engine="$(resolve_input "engine" "$DB_ENGINE" --prompt "Engine" \
    --select "mariadb postgres mongo redis" --validate validate_db_engine)"
  state_service_installed "$engine" || die "Engine '$engine' not installed. Run: lapn db:install $engine"

  local name; name="$(state_site_get "$domain" name)"
  local dbname="${name//-/_}_db"
  local dbuser="${name//-/_}_u"; dbuser="${dbuser:0:31}"
  local dbpass; dbpass="$(_db_gen_pass)"
  local envfile="${LAPN_SECRETS}/${name}/.env"

  log_step "Create DB $engine for $domain"
  local url=""
  case "$engine" in
    mariadb)       url="$(_db_create_mysql "$dbname" "$dbuser" "$dbpass")" ;;
    postgres)      url="$(_db_create_postgres "$dbname" "$dbuser" "$dbpass")" ;;
    mongo)         url="$(_db_create_mongo "$dbname" "$dbuser" "$dbpass")" ;;
    redis)         url="$(_db_create_redis "$domain")" ;;
  esac

  # Insert connection variable into .env (idempotent: remove old line then append).
  if [[ -n "$url" ]]; then
    local key="DATABASE_URL"; [[ "$engine" == "redis" ]] && key="REDIS_URL"
    sed -i "/^${key}=/d" "$envfile" 2>/dev/null || true
    printf '%s=%s\n' "$key" "$url" >>"$envfile"
    chmod 600 "$envfile"
  fi

  # Write state (engine/name/user — NO password).
  local dbinfo
  dbinfo="$(jq -n --arg e "$engine" --arg n "$dbname" --arg u "$dbuser" \
    '{engine:$e, name:$n, user:$u}')"
  state_update '.sites[$d].db = ((.sites[$d].db // []) + [$x] | unique_by(.engine))' \
    --arg d "$domain" --argjson x "$dbinfo"
  audit "OK" "db:create $domain $engine $dbname"
  log_ok "DB '$dbname' (user '$dbuser') created, connection variable written to .env."
}

_db_create_mysql() {
  local dbname="$1" dbuser="$2" dbpass="$3"
  mysql <<SQL || die "Failed to create MySQL/MariaDB DB."
CREATE DATABASE IF NOT EXISTS \`${dbname}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${dbuser}'@'localhost' IDENTIFIED BY '${dbpass}';
GRANT ALL PRIVILEGES ON \`${dbname}\`.* TO '${dbuser}'@'localhost';
FLUSH PRIVILEGES;
SQL
  printf 'mysql://%s:%s@127.0.0.1:3306/%s' "$dbuser" "$dbpass" "$dbname"
}

_db_create_postgres() {
  local dbname="$1" dbuser="$2" dbpass="$3"
  sudo -u postgres psql <<SQL || die "Failed to create PostgreSQL DB."
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='${dbuser}') THEN
    CREATE ROLE ${dbuser} LOGIN PASSWORD '${dbpass}';
  END IF;
END \$\$;
SQL
  sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='${dbname}'" | grep -q 1 \
    || sudo -u postgres createdb -O "$dbuser" "$dbname"
  printf 'postgresql://%s:%s@127.0.0.1:5432/%s' "$dbuser" "$dbpass" "$dbname"
}

_db_create_mongo() {
  local dbname="$1" dbuser="$2" dbpass="$3"
  local admin; admin="$(cat "$(_db_root_secret mongo)" 2>/dev/null || true)"
  mongosh --quiet -u lapnadmin -p "$admin" --authenticationDatabase admin --eval \
    "db.getSiblingDB('${dbname}').createUser({user:'${dbuser}',pwd:'${dbpass}',roles:[{role:'readWrite',db:'${dbname}'}]})" \
    2>/dev/null || log_warn "Mongo user may already exist."
  printf 'mongodb://%s:%s@127.0.0.1:27017/%s' "$dbuser" "$dbpass" "$dbname"
}

_db_create_redis() {
  local domain="$1"
  local pass; pass="$(cat "$(_db_root_secret redis)" 2>/dev/null || true)"
  printf 'redis://default:%s@127.0.0.1:6379' "$pass"
}

# ============ DROP ============
cmd_db_drop() {
  core_require_root
  _db_parse "$@"
  state_init
  local domain; domain="$(resolve_input "domain" "$DB_SITE" --prompt "Site (domain)" --validate validate_domain)"
  local engine; engine="$(resolve_input "engine" "$DB_ENGINE" --prompt "Engine" --validate validate_db_engine)"
  local name; name="$(state_site_get "$domain" name)"
  local dbname="${name//-/_}_db"
  local dbuser="${name//-/_}_u"; dbuser="${dbuser:0:31}"

  if [[ -z "$DB_FORCE" ]]; then
    local c; c="$(ui_ask "Re-type the DB name '$dbname' to confirm DELETE")"
    [[ "$c" == "$dbname" ]] || die "Does not match — cancelled."
  fi

  # Quick dump before deletion.
  mkdir -p "$LAPN_TRASH"
  local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
  case "$engine" in
    mariadb)
      mysqldump "$dbname" >"${LAPN_TRASH}/${dbname}-${stamp}.sql" 2>/dev/null || true
      mysql <<SQL || true
DROP DATABASE IF EXISTS \`${dbname}\`;
DROP USER IF EXISTS '${dbuser}'@'localhost';
FLUSH PRIVILEGES;
SQL
      ;;
    postgres)
      sudo -u postgres pg_dump "$dbname" >"${LAPN_TRASH}/${dbname}-${stamp}.sql" 2>/dev/null || true
      sudo -u postgres dropdb --if-exists "$dbname" || true
      sudo -u postgres psql -c "DROP ROLE IF EXISTS ${dbuser};" || true
      ;;
    mongo)
      local admin; admin="$(cat "$(_db_root_secret mongo)" 2>/dev/null || true)"
      mongosh --quiet -u lapnadmin -p "$admin" --authenticationDatabase admin --eval \
        "db.getSiblingDB('${dbname}').dropDatabase()" 2>/dev/null || true
      ;;
    redis) log_info "Redis shared — not dropping the instance. Skipping." ;;
  esac

  state_update '.sites[$d].db = [(.sites[$d].db // [])[] | select(.engine != $e)]' \
    --arg d "$domain" --arg e "$engine"
  audit "OK" "db:drop $domain $engine"
  log_ok "Deleted DB $engine of $domain (dump in $LAPN_TRASH if any)."
}

# ============ CONSOLE ============
cmd_db_console() {
  _db_parse "$@"
  state_init
  local domain; domain="$(resolve_input "domain" "$DB_SITE" --prompt "Site (domain)" --validate validate_domain)"
  local envfile="${LAPN_SECRETS}/$(state_site_get "$domain" name)/.env"
  local url; url="$(grep -E '^(DATABASE_URL|REDIS_URL)=' "$envfile" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
  [[ -z "$url" ]] && die "Site '$domain' has no DB attached."
  log_info "Connecting: $url"
  case "$url" in
    mysql://*)      mysql "$(_db_url_to_mysql_args "$url")" ;;
    postgresql://*) psql "$url" ;;
    mongodb://*)    mongosh "$url" ;;
    redis://*)      redis-cli -u "$url" ;;
    *) die "Unrecognized URL type." ;;
  esac
}

_db_url_to_mysql_args() {
  # mysql://user:pass@host:port/db -> --user=... --password=... --host=... db
  local u="$1"
  local rest="${u#mysql://}"
  local creds="${rest%%@*}" hostpart="${rest#*@}"
  local user="${creds%%:*}" pass="${creds#*:}"
  local hostport="${hostpart%%/*}" db="${hostpart#*/}"
  local host="${hostport%%:*}" port="${hostport#*:}"
  printf -- '--user=%s --password=%s --host=%s --port=%s %s' "$user" "$pass" "$host" "$port" "$db"
}

# ============ REMOTE (Navicat over SSH tunnel) ============
cmd_db_remote() {
  core_require_root
  _db_parse "$@"
  local user="${DBR_USER:-lapn_navicat}"

  if [[ -n "$DBR_DEL" ]]; then
    rm -f "/etc/ssh/sshd_config.d/lapn-tunnel-${user}.conf"
    sshd -t && { systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null; }
    userdel -r "$user" 2>/dev/null || true
    log_ok "Deleted tunnel user $user."
    return 0
  fi

  if [[ -n "$DBR_INFO" ]]; then
    _db_remote_info "$user"; return 0
  fi

  # default = --add
  local key="$DBR_KEY"
  [[ -z "$key" ]] && key="$(resolve_input "key" "" --prompt "Public key for $user (ssh-ed25519 ...)")"
  [[ "$key" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-) ]] || die "Invalid public key."

  log_step "Create SSH tunnel user $user (forward only, no shell)"
  id "$user" >/dev/null 2>&1 || useradd -m -s /usr/sbin/nologin "$user"
  local home; home="$(getent passwd "$user" | cut -d: -f6)"
  mkdir -p "$home/.ssh"; chmod 700 "$home/.ssh"
  grep -qF "$key" "$home/.ssh/authorized_keys" 2>/dev/null || printf '%s\n' "$key" >>"$home/.ssh/authorized_keys"
  chmod 600 "$home/.ssh/authorized_keys"; chown -R "$user:$user" "$home/.ssh"

  # Match block: only port-forward to localhost DB ports, no shell.
  local conf="/etc/ssh/sshd_config.d/lapn-tunnel-${user}.conf"
  cat >"$conf" <<EOF
Match User ${user}
    PubkeyAuthentication yes
    PasswordAuthentication no
    PermitTTY no
    X11Forwarding no
    AllowAgentForwarding no
    AllowStreamLocalForwarding no
    AllowTcpForwarding local
    PermitOpen 127.0.0.1:3306 127.0.0.1:5432 127.0.0.1:27017 127.0.0.1:6379
    ForceCommand /usr/sbin/nologin
EOF
  sshd -t || { rm -f "$conf"; die "sshd_config error — cancelled."; }
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null
  audit "OK" "db:remote add $user"
  log_ok "Tunnel user $user ready."
  _db_remote_info "$user"
}

_db_remote_info() {
  local user="$1"
  local ip ssh_port
  ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo '<IP_VPS>')"
  ssh_port="${LAPN_SSH_PORT:-${LAPN_SSH_PORT_DEFAULT:-22}}"
  cat <<EOF

${C_BOLD}Navicat configuration (SSH tunnel)${C_RESET}
  SSH tab:
    Host        : ${ip}
    Port        : ${ssh_port}
    User name   : ${user}
    Auth method : Private Key (matching the public key that was added)
  General tab (connect to DB over the tunnel — localhost IS the server):
    Host        : 127.0.0.1
    Port        : 3306 (MariaDB) | 5432 (Postgres) | 27017 (Mongo) | 6379 (Redis)
    User / Pass : per-site DB user (see the site's .env)

Note: the DB port is NOT exposed to the Internet; it only travels inside the SSH tunnel.
EOF
}

# ============ LIST ============
# db:list [--engine X] — list databases LapN manages (from sites.json), optionally per engine.
cmd_db_list() {
  state_init
  _db_parse "$@"
  local engine="$DB_ENGINE"
  local rows
  rows="$(state_jq -r --arg e "$engine" '
    .sites | to_entries[] | .key as $d | (.value.db // [])[]
    | select($e == "" or .engine == $e)
    | "\($d)\t\(.engine)\t\(.name)\t\(.user)"' 2>/dev/null || true)"
  if [[ -z "$rows" ]]; then
    log_info "No database for engine '${engine:-any}' yet."
    return 0
  fi
  printf '%s%-30s %-9s %-20s %s%s\n' "$C_BOLD" "SITE" "ENGINE" "DB NAME" "DB USER" "$C_RESET"
  printf '%s\n' "$rows" | while IFS=$'\t' read -r d e n u; do
    printf '%-30s %-9s %-20s %s\n' "$d" "$e" "$n" "$u"
  done
}

# ============ BACKUP ============
# db:backup [--site D] [--engine X] — dump a site's DB to the backup dir (does NOT drop).
cmd_db_backup() {
  core_require_root
  _db_parse "$@"
  state_init
  local domain; domain="$(resolve_input "domain" "$DB_SITE" --prompt "Site (domain)" --validate validate_domain)"
  state_site_exists "$domain" || die "No site '$domain'."
  local engine; engine="$(resolve_input "engine" "$DB_ENGINE" --prompt "Engine" \
    --select "mariadb postgres mongo redis" --validate validate_db_engine)"

  # Resolve the actual DB name from state (the one attached to this site for this engine).
  local dbname; dbname="$(state_site_get "$domain" | jq -r --arg e "$engine" \
    '(.db // [])[] | select(.engine==$e) | .name' 2>/dev/null | head -n1)"
  [[ -z "$dbname" ]] && die "Site '$domain' has no $engine database."

  local dir="${LAPN_BACKUP_DIR:-/root/lapn-db-backups}"
  mkdir -p "$dir"; chmod 700 "$dir"
  local stamp; stamp="$(date +%Y%m%d-%H%M%S)" out
  log_step "Backup $engine DB '$dbname' of $domain"
  case "$engine" in
    mariadb)
      out="$dir/${dbname}-${stamp}.sql"
      mysqldump "$dbname" >"$out" || die "mysqldump failed." ;;
    postgres)
      out="$dir/${dbname}-${stamp}.sql"
      sudo -u postgres pg_dump "$dbname" >"$out" || die "pg_dump failed." ;;
    mongo)
      out="$dir/${dbname}-${stamp}.archive.gz"
      local admin; admin="$(cat "$(_db_root_secret mongo)" 2>/dev/null || true)"
      mongodump -u lapnadmin -p "$admin" --authenticationDatabase admin \
        --db "$dbname" --archive="$out" --gzip || die "mongodump failed." ;;
    redis)
      log_warn "Redis is a shared cache — per-site dump is not applicable (use an RDB snapshot)."
      return 0 ;;
  esac
  chmod 600 "$out" 2>/dev/null || true
  audit "OK" "db:backup $domain $engine $dbname"
  log_ok "Backup saved: $out"
}

# ============ Interactive menu (engine-first) — invoked by bin/lapn via MODULE_MENU ============

_DB_ENGINES=(mariadb postgres mongo redis)
_DB_ENGINE_LABELS=("MariaDB" "PostgreSQL" "MongoDB" "Redis")

# Per-engine action menu.
database_engine_menu() {
  local engine="$1" label="$2" choice
  while true; do
    lapn_clear
    printf '%s%sLapN%s › Database › %s%s%s\n\n' "$C_BOLD" "$C_BLUE" "$C_RESET" "$C_BOLD" "$label" "$C_RESET"
    printf '  1) List databases\n'
    printf '  2) Create database\n'
    printf '  3) Drop database\n'
    printf '  4) Backup database\n'
    printf '  5) Console (open SQL shell)\n'
    printf '  0) ← Back\n'
    read -r -p "→ " choice || return 0
    printf '\n'
    case "$choice" in
      1) ( cmd_db_list    --engine "$engine" ) || true; lapn_pause ;;
      2) ( cmd_db_create  --engine "$engine" ) || log_warn "Finished with an error (see above)."; lapn_pause ;;
      3) ( cmd_db_drop    --engine "$engine" ) || log_warn "Finished with an error (see above)."; lapn_pause ;;
      4) ( cmd_db_backup  --engine "$engine" ) || log_warn "Finished with an error (see above)."; lapn_pause ;;
      5) ( cmd_db_console ) || log_warn "Finished with an error (see above)."; lapn_pause ;;
      0|"") return 0 ;;
      *) log_warn "Invalid choice."; lapn_pause ;;
    esac
  done
}

# Remote-access submenu (Navicat over SSH tunnel) — server-wide, not per engine.
database_remote_menu() {
  local choice
  while true; do
    lapn_clear
    printf '%s%sLapN%s › Database › Remote access (Navicat SSH tunnel)\n\n' "$C_BOLD" "$C_BLUE" "$C_RESET"
    printf '  1) Add tunnel user (paste a public key)\n'
    printf '  2) Show connection info\n'
    printf '  3) Remove tunnel user\n'
    printf '  0) ← Back\n'
    read -r -p "→ " choice || return 0
    printf '\n'
    case "$choice" in
      1) ( cmd_db_remote --add )  || log_warn "Finished with an error (see above)."; lapn_pause ;;
      2) ( cmd_db_remote --info ) || log_warn "Finished with an error (see above)."; lapn_pause ;;
      3) ( cmd_db_remote --del )  || log_warn "Finished with an error (see above)."; lapn_pause ;;
      0|"") return 0 ;;
      *) log_warn "Invalid choice."; lapn_pause ;;
    esac
  done
}

# Top-level Database menu: list engines (drivers) -> pick one -> its actions.
database_menu() {
  state_init
  local choice i n="${#_DB_ENGINES[@]}"
  while true; do
    lapn_clear
    printf '%s%sLapN%s › Database\n\n' "$C_BOLD" "$C_BLUE" "$C_RESET"
    for i in "${!_DB_ENGINES[@]}"; do
      local mark="[ ]"; state_service_installed "${_DB_ENGINES[$i]}" && mark="[${C_GREEN}x${C_RESET}]"
      printf '  %d) %s %s\n' "$((i + 1))" "$mark" "${_DB_ENGINE_LABELS[$i]}"
    done
    printf '  %d) Remote access (Navicat SSH tunnel)\n' "$((n + 1))"
    printf '  0) ← Back to main menu\n'
    read -r -p "→ " choice || return 0
    [[ "$choice" == "0" || -z "$choice" ]] && return 0
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= n )); then
      local engine="${_DB_ENGINES[$((choice - 1))]}" label="${_DB_ENGINE_LABELS[$((choice - 1))]}"
      if state_service_installed "$engine"; then
        database_engine_menu "$engine" "$label"
      else
        printf '\n'; log_warn "$label is not installed. Install it from: Stack › Install software."
        lapn_pause
      fi
    elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice == n + 1 )); then
      database_remote_menu
    else
      log_warn "Invalid choice."; lapn_pause
    fi
  done
}
