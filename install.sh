#!/usr/bin/env bash
# install.sh — install LapN on a clean Ubuntu VPS. Idempotent.
# Usage: curl -sL .../install.sh | sudo bash
#   or: sudo bash /opt/lapn/install.sh
set -euo pipefail

LAPN_REPO="${LAPN_REPO:-https://github.com/nguyenlapvn/lapn-stack}"
LAPN_HOME="/opt/lapn"
LAPN_BRANCH="${LAPN_BRANCH:-main}"

c_g=$'\033[32m'; c_y=$'\033[33m'; c_r=$'\033[31m'; c_b=$'\033[1m'; c_0=$'\033[0m'
say()  { printf '%s==>%s %s\n' "$c_b" "$c_0" "$*"; }
ok()   { printf '%s[✓]%s %s\n' "$c_g" "$c_0" "$*"; }
warn() { printf '%s[!]%s %s\n' "$c_y" "$c_0" "$*" >&2; }
err()  { printf '%s[✗]%s %s\n' "$c_r" "$c_0" "$*" >&2; exit 1; }

# --- 1) Check the environment ---
say "Checking the environment"
(( EUID == 0 )) || err "Must run as root (sudo)."
. /etc/os-release 2>/dev/null || err "Could not read /etc/os-release."
[[ "${ID:-}" == "ubuntu" ]] || err "Only Ubuntu is supported (detected: ${ID:-?})."
case "${VERSION_ID:-}" in
  22.04|24.04) ok "Ubuntu $VERSION_ID" ;;
  *) warn "Only tested on Ubuntu 22.04/24.04 (currently $VERSION_ID) — continuing but not guaranteed." ;;
esac
rammb="$(free -m | awk '/^Mem:/{print $2}')"
(( rammb >= 1900 )) || err "RAM ${rammb}MB < 2GB. Next.js builds easily OOM — increase RAM then reinstall (swap is not created automatically)."
ok "RAM ${rammb}MB"

UPDATE_MODE=""
if [[ -f /usr/local/bin/lapn ]]; then
  UPDATE_MODE=1
  say "Detected LapN — update mode."
fi

# --- 2) Base packages ---
say "Installing base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
# nginx IS installed here (unlike 'lapn stack:install') because the steps below
# configure the base vhosts. ssl-cert provides the snakeoil cert used by the :443
# catch-all server that blocks access by IP / unknown SNI.
apt-get install -y curl git jq nginx ufw fail2ban unzip openssl ca-certificates logrotate ssl-cert
ok "Base packages done."

# --- 3) fnm ---
if ! command -v fnm >/dev/null 2>&1; then
  say "Installing fnm"
  curl -fsSL https://fnm.vercel.app/install | bash -s -- --install-dir /usr/local/bin --skip-shell || true
  command -v fnm >/dev/null 2>&1 || {
    f="$(find /root /usr/local -maxdepth 4 -name fnm -type f 2>/dev/null | head -n1 || true)"
    [[ -n "$f" ]] && ln -sf "$f" /usr/local/bin/fnm
  }
  command -v fnm >/dev/null 2>&1 && ok "fnm $(fnm --version)" || warn "fnm not installed yet — reinstall later with 'lapn stack:install'."
fi

# --- 4) Code into /opt/lapn ---
say "Placing code into $LAPN_HOME"
if [[ -d "$LAPN_HOME/.git" ]]; then
  git -C "$LAPN_HOME" pull --ff-only || warn "git pull failed (skipping)."
elif [[ -f "$(dirname "$(readlink -f "$0")")/bin/lapn" ]]; then
  # Running from an existing clone — use it as-is.
  src="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
  if [[ "$src" != "$LAPN_HOME" ]]; then
    mkdir -p "$LAPN_HOME"; cp -a "$src/." "$LAPN_HOME/"
  fi
else
  git clone --branch "$LAPN_BRANCH" "$LAPN_REPO" "$LAPN_HOME" || err "git clone failed."
fi
chmod +x "$LAPN_HOME/bin/lapn"
ln -sf "$LAPN_HOME/bin/lapn" /usr/local/bin/lapn
ok "lapn -> /usr/local/bin/lapn"

# Single source of truth for paths/limits (LAPN_SITES_HOME, LAPN_JOURNALD_MAX_USE, ...).
# shellcheck source=config/defaults.conf
. "$LAPN_HOME/config/defaults.conf"

# --- 5) /etc/lapn + state + config ---
say "Initializing /etc/lapn"
mkdir -p /etc/lapn/secrets /var/log/lapn
chmod 700 /etc/lapn/secrets
if [[ ! -f /etc/lapn/sites.json ]]; then
  jq -n --argjson v "${LAPN_SCHEMA_VERSION:-2}" \
    '{schema_version:$v, services:{}, sites:{}, databases:[]}' >/etc/lapn/sites.json
  chmod 600 /etc/lapn/sites.json
fi
# config: detect the current SSH port.
cur_ssh="$(ss -tlnpH 2>/dev/null | awk '/sshd/{print $4}' | sed -E 's/.*[:.]([0-9]+)$/\1/' | head -n1 || true)"
[[ -z "$cur_ssh" ]] && cur_ssh="$(awk '/^Port /{print $2; exit}' /etc/ssh/sshd_config 2>/dev/null || echo 22)"
[[ -z "$cur_ssh" ]] && cur_ssh=22
if [[ ! -f /etc/lapn/config ]]; then
  printf '# LapN config (override defaults)\nLAPN_SSH_PORT=%s\n' "$cur_ssh" >/etc/lapn/config
fi
ok "State + config (ssh_port=$cur_ssh)."

# --- 6) Base Nginx + logrotate + journald ---
say "Configuring base Nginx"
mkdir -p /etc/nginx/snippets
cp -f "$LAPN_HOME/templates/nginx/snippets/security-headers.conf"  /etc/nginx/snippets/lapn-security-headers.conf
cp -f "$LAPN_HOME/templates/nginx/snippets/block-sensitive.conf"   /etc/nginx/snippets/lapn-block-sensitive.conf
cp -f "$LAPN_HOME/templates/nginx/snippets/cloudflare-realip.conf" /etc/nginx/snippets/lapn-cloudflare-realip.conf
cp -f "$LAPN_HOME/templates/nginx/snippets/ratelimit.conf"         /etc/nginx/conf.d/lapn-ratelimit.conf
cp -f "$LAPN_HOME/templates/nginx/default-444.conf"                /etc/nginx/sites-available/lapn-default-444.conf
ln -sf /etc/nginx/sites-available/lapn-default-444.conf /etc/nginx/sites-enabled/lapn-default-444.conf
# Same for TLS, but only with a cert to present — otherwise nginx -t would fail.
if [[ -f /etc/ssl/certs/ssl-cert-snakeoil.pem && -f /etc/ssl/private/ssl-cert-snakeoil.key ]]; then
  cp -f "$LAPN_HOME/templates/nginx/default-444-ssl.conf" /etc/nginx/sites-available/lapn-default-444-ssl.conf
  ln -sf /etc/nginx/sites-available/lapn-default-444-ssl.conf /etc/nginx/sites-enabled/lapn-default-444-ssl.conf
else
  warn "Snakeoil cert missing — skipping the :443 catch-all (https://<IP> will hit the first site)."
fi
# Remove Ubuntu's default site (avoid duplicate default_server).
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx && ok "Base Nginx OK." || warn "nginx -t failed — check the configuration."

# logrotate
sed -e "s#{{SITES_HOME}}#${LAPN_SITES_HOME:-/home/sites}#g" \
    "$LAPN_HOME/templates/logrotate/lapn.tpl" >/etc/logrotate.d/lapn
ok "logrotate installed."
# journald cap
jmax="${LAPN_JOURNALD_MAX_USE:-500M}"
if ! grep -qE '^\s*SystemMaxUse=' /etc/systemd/journald.conf; then
  sed -i "s/^#\?SystemMaxUse=.*/SystemMaxUse=${jmax}/" /etc/systemd/journald.conf 2>/dev/null \
    || printf '\nSystemMaxUse=%s\n' "$jmax" >>/etc/systemd/journald.conf
  systemctl restart systemd-journald 2>/dev/null || true
fi
ok "journald cap ${jmax}."

# --- 7) Ask to change the SSH port (anti-lockout) ---
if [[ -z "$UPDATE_MODE" && -t 0 ]]; then
  read -r -p "Change SSH port (currently $cur_ssh)? Enter a new port or press Enter to keep: " newp || true
  if [[ -n "${newp:-}" && "$newp" != "$cur_ssh" ]]; then
    /usr/local/bin/lapn security:ssh --port "$newp" || warn "Change SSH port not completed — run 'lapn security:ssh' again later."
    cur_ssh="$(awk -F= '/^LAPN_SSH_PORT=/{print $2}' /etc/lapn/config | tail -n1)"
  fi
fi

# --- 8) Firewall + fail2ban + baseline hardening ---
# One call, not a hand-rolled UFW block plus 'security:harden' (which repeats it):
# the duplicate prompted twice, and with stdout redirected the second prompt read from
# this script's own stdin. security:harden writes the UFW rules and, when there is no
# TTY to confirm on, leaves UFW disabled instead of guessing.
say "Applying baseline hardening (UFW rules, fail2ban, unattended-upgrades, sysctl)"
if ! /usr/local/bin/lapn security:harden; then
  warn "lapn security:harden did not finish — installing a minimal fail2ban jail as a fallback."
  cat >/etc/fail2ban/jail.d/lapn.conf <<EOF
[sshd]
enabled = true
port    = ${cur_ssh}
backend = systemd
EOF
  systemctl enable --now fail2ban 2>/dev/null || true
fi

# --- 9) Summary ---
ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo '<IP>')"
printf '\n%s%s✓ LapN installed successfully%s\n' "$c_g" "$c_b" "$c_0"
printf '  Server IP : %s\n' "$ip"
printf '  SSH port  : %s%s%s  (use: ssh -p %s ...)\n' "$c_b" "$cur_ssh" "$c_0" "$cur_ssh"
printf '  Command   : lapn   (menu)  |  lapn site:create   |  lapn doctor\n'
if ! ufw status 2>/dev/null | grep -q "Status: active"; then
  printf '  %s[!]%s UFW is NOT enabled yet — run: %slapn security:firewall%s\n' "$c_y" "$c_0" "$c_b" "$c_0"
fi
printf '\nGet started: %slapn site:create%s\n' "$c_b" "$c_0"
