#!/usr/bin/env bash
# modules/55-db.sh — Optional database: install each engine, per-site user, bind localhost.
# Remote via Navicat over SSH tunnel (db:remote). Does NOT install any web tool.

MODULE_NAME="Database"
MODULE_ORDER=55
MODULE_COMMANDS=("db:install" "db:status" "db:create" "db:drop" "db:console" "db:remote")

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
  local engine="${1:-}"
  [[ -z "$engine" ]] && engine="$(resolve_input "engine" "" --prompt "Engine to install" \
    --select "mariadb postgres mongo redis mysql" --validate validate_db_engine)"
  validate_db_engine "$engine" || die "Invalid engine."

  if state_service_installed "$engine"; then
    log_info "Engine '$engine' Installed (idempotent — skipping)."
    return 0
  fi
  mkdir -p "${LAPN_SECRETS}/_db"; chmod 700 "${LAPN_SECRETS}/_db"
  export DEBIAN_FRONTEND=noninteractive

  case "$engine" in
    mariadb) _db_install_mariadb ;;
    mysql)   _db_install_mysql ;;
    postgres) _db_install_postgres ;;
    mongo)   _db_install_mongo ;;
    redis)   _db_install_redis ;;
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
    mariadb|mysql) echo 3306 ;;
    postgres) echo 5432 ;;
    mongo) echo 27017 ;;
    redis) echo 6379 ;;
  esac
}
_db_engine_version() {
  case "$1" in
    mariadb) mariadb --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 ;;
    mysql)   mysql --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 ;;
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

_db_install_mysql() {
  log_step "Install MySQL"
  apt-get install -y mysql-server
  local cfg="/etc/mysql/mysql.conf.d/99-lapn.cnf"
  printf '[mysqld]\nbind-address = 127.0.0.1\n' >"$cfg"
  systemctl enable --now mysql
  systemctl restart mysql
  local rootpass; rootpass="$(_db_gen_pass)"
  printf '%s' "$rootpass" >"$(_db_root_secret mysql)"; chmod 600 "$(_db_root_secret mysql)"
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
  log_step "Install MongoDB (official repo)"
  apt-get install -y gnupg curl
  curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc \
    | gpg -o /usr/share/keyrings/mongodb-server-7.0.gpg --dearmor --yes
  local codename; codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] https://repo.mongodb.org/apt/ubuntu ${codename}/mongodb-org/7.0 multiverse" \
    >/etc/apt/sources.list.d/mongodb-org-7.0.list
  apt-get update -y
  apt-get install -y mongodb-org
  # bind localhost + enable auth.
  sed -i 's/^\( *bindIp:\).*/\1 127.0.0.1/' /etc/mongod.conf 2>/dev/null || true
  if ! grep -q '^security:' /etc/mongod.conf; then
    printf '\nsecurity:\n  authorization: enabled\n' >>/etc/mongod.conf
  fi
  systemctl enable --now mongod
  # Create admin user.
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
  for e in mariadb mysql postgres mongo redis; do
    local inst="no" ver="-" port="-" active="-"
    if state_service_installed "$e"; then
      inst="yes"
      ver="$(state_jq -r --arg e "$e" '.services[$e].version // "-"')"
      port="$(state_jq -r --arg e "$e" '.services[$e].port // "-"')"
      case "$e" in
        mariadb) svc=mariadb ;; mysql) svc=mysql ;; postgres) svc=postgresql ;;
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
    --select "mariadb postgres mongo redis mysql" --validate validate_db_engine)"
  state_service_installed "$engine" || die "Engine '$engine' not installed. Run: lapn db:install $engine"

  local name; name="$(state_site_get "$domain" name)"
  local dbname="${name//-/_}_db"
  local dbuser="${name//-/_}_u"; dbuser="${dbuser:0:31}"
  local dbpass; dbpass="$(_db_gen_pass)"
  local envfile="${LAPN_SECRETS}/${name}/.env"

  log_step "Create DB $engine for $domain"
  local url=""
  case "$engine" in
    mariadb|mysql) url="$(_db_create_mysql "$dbname" "$dbuser" "$dbpass")" ;;
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
    mariadb|mysql)
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
    Port        : 3306 (MariaDB/MySQL) | 5432 (Postgres) | 27017 (Mongo) | 6379 (Redis)
    User / Pass : per-site DB user (see the site's .env)

Note: the DB port is NOT exposed to the Internet; it only travels inside the SSH tunnel.
EOF
}
