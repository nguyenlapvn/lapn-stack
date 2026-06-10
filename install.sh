#!/usr/bin/env bash
# install.sh — cài LapN trên VPS Ubuntu trắng. Idempotent.
# Dùng: curl -sL .../install.sh | sudo bash
#   hoặc: sudo bash /opt/lapn/install.sh
set -euo pipefail

LAPN_REPO="${LAPN_REPO:-https://github.com/nguyenlap/lapn-stack}"
LAPN_HOME="/opt/lapn"
LAPN_BRANCH="${LAPN_BRANCH:-main}"

c_g=$'\033[32m'; c_y=$'\033[33m'; c_r=$'\033[31m'; c_b=$'\033[1m'; c_0=$'\033[0m'
say()  { printf '%s==>%s %s\n' "$c_b" "$c_0" "$*"; }
ok()   { printf '%s[✓]%s %s\n' "$c_g" "$c_0" "$*"; }
warn() { printf '%s[!]%s %s\n' "$c_y" "$c_0" "$*" >&2; }
err()  { printf '%s[✗]%s %s\n' "$c_r" "$c_0" "$*" >&2; exit 1; }

# --- 1) Kiểm tra môi trường ---
say "Kiểm tra môi trường"
(( EUID == 0 )) || err "Cần chạy bằng root (sudo)."
. /etc/os-release 2>/dev/null || err "Không đọc được /etc/os-release."
[[ "${ID:-}" == "ubuntu" ]] || err "Chỉ hỗ trợ Ubuntu (phát hiện: ${ID:-?})."
case "${VERSION_ID:-}" in
  22.04|24.04) ok "Ubuntu $VERSION_ID" ;;
  *) warn "Chỉ test trên Ubuntu 22.04/24.04 (đang $VERSION_ID) — tiếp tục nhưng không đảm bảo." ;;
esac
rammb="$(free -m | awk '/^Mem:/{print $2}')"
(( rammb >= 1900 )) || err "RAM ${rammb}MB < 2GB. Next.js build dễ OOM — nâng RAM rồi cài lại (không tự tạo swap)."
ok "RAM ${rammb}MB"

UPDATE_MODE=""
if [[ -f /usr/local/bin/lapn ]]; then
  UPDATE_MODE=1
  say "Đã phát hiện LapN — chế độ cập nhật."
fi

# --- 2) Gói nền ---
say "Cài gói nền"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl git jq nginx ufw fail2ban unzip openssl ca-certificates logrotate
ok "Gói nền xong."

# --- 3) fnm ---
if ! command -v fnm >/dev/null 2>&1; then
  say "Cài fnm"
  curl -fsSL https://fnm.vercel.app/install | bash -s -- --install-dir /usr/local/bin --skip-shell || true
  command -v fnm >/dev/null 2>&1 || {
    f="$(find /root /usr/local -maxdepth 4 -name fnm -type f 2>/dev/null | head -n1 || true)"
    [[ -n "$f" ]] && ln -sf "$f" /usr/local/bin/fnm
  }
  command -v fnm >/dev/null 2>&1 && ok "fnm $(fnm --version)" || warn "fnm chưa cài được — cài lại sau bằng 'lapn stack:install'."
fi

# --- 4) Code về /opt/lapn ---
say "Đưa code về $LAPN_HOME"
if [[ -d "$LAPN_HOME/.git" ]]; then
  git -C "$LAPN_HOME" pull --ff-only || warn "git pull lỗi (bỏ qua)."
elif [[ -f "$(dirname "$(readlink -f "$0")")/bin/lapn" ]]; then
  # Chạy từ bản clone sẵn — dùng chính nó.
  src="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
  if [[ "$src" != "$LAPN_HOME" ]]; then
    mkdir -p "$LAPN_HOME"; cp -a "$src/." "$LAPN_HOME/"
  fi
else
  git clone --branch "$LAPN_BRANCH" "$LAPN_REPO" "$LAPN_HOME" || err "git clone thất bại."
fi
chmod +x "$LAPN_HOME/bin/lapn"
ln -sf "$LAPN_HOME/bin/lapn" /usr/local/bin/lapn
ok "lapn -> /usr/local/bin/lapn"

# --- 5) /etc/lapn + state + config ---
say "Khởi tạo /etc/lapn"
mkdir -p /etc/lapn/secrets /var/log/lapn
chmod 700 /etc/lapn/secrets
if [[ ! -f /etc/lapn/sites.json ]]; then
  jq -n '{schema_version:1, services:{}, sites:{}}' >/etc/lapn/sites.json
  chmod 600 /etc/lapn/sites.json
fi
# config: phát hiện port SSH hiện tại.
cur_ssh="$(ss -tlnpH 2>/dev/null | awk '/sshd/{print $4}' | sed -E 's/.*[:.]([0-9]+)$/\1/' | head -n1 || true)"
[[ -z "$cur_ssh" ]] && cur_ssh="$(awk '/^Port /{print $2; exit}' /etc/ssh/sshd_config 2>/dev/null || echo 22)"
[[ -z "$cur_ssh" ]] && cur_ssh=22
if [[ ! -f /etc/lapn/config ]]; then
  printf '# LapN config (override defaults)\nLAPN_SSH_PORT=%s\n' "$cur_ssh" >/etc/lapn/config
fi
ok "State + config (ssh_port=$cur_ssh)."

# --- 6) Nginx nền + logrotate + journald ---
say "Cấu hình Nginx nền"
mkdir -p /etc/nginx/snippets
cp -f "$LAPN_HOME/templates/nginx/snippets/security-headers.conf"  /etc/nginx/snippets/lapn-security-headers.conf
cp -f "$LAPN_HOME/templates/nginx/snippets/block-sensitive.conf"   /etc/nginx/snippets/lapn-block-sensitive.conf
cp -f "$LAPN_HOME/templates/nginx/snippets/cloudflare-realip.conf" /etc/nginx/snippets/lapn-cloudflare-realip.conf
cp -f "$LAPN_HOME/templates/nginx/snippets/ratelimit.conf"         /etc/nginx/conf.d/lapn-ratelimit.conf
cp -f "$LAPN_HOME/templates/nginx/default-444.conf"                /etc/nginx/sites-available/lapn-default-444.conf
ln -sf /etc/nginx/sites-available/lapn-default-444.conf /etc/nginx/sites-enabled/lapn-default-444.conf
# Gỡ default site mặc định của Ubuntu (tránh trùng default_server).
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx && ok "Nginx nền OK." || warn "nginx -t lỗi — kiểm tra cấu hình."

# logrotate
cp -f "$LAPN_HOME/templates/logrotate/lapn.tpl" /etc/logrotate.d/lapn
ok "logrotate cài."
# journald cap
if ! grep -qE '^\s*SystemMaxUse=' /etc/systemd/journald.conf; then
  sed -i 's/^#\?SystemMaxUse=.*/SystemMaxUse=500M/' /etc/systemd/journald.conf 2>/dev/null \
    || printf '\nSystemMaxUse=500M\n' >>/etc/systemd/journald.conf
  systemctl restart systemd-journald 2>/dev/null || true
fi
ok "journald cap 500M."

# --- 7) Hỏi đổi port SSH (chống tự khóa) ---
if [[ -z "$UPDATE_MODE" && -t 0 ]]; then
  read -r -p "Đổi port SSH (đang $cur_ssh)? Nhập port mới hoặc Enter để giữ: " newp || true
  if [[ -n "${newp:-}" && "$newp" != "$cur_ssh" ]]; then
    /usr/local/bin/lapn security:ssh --port "$newp" || warn "Đổi port SSH chưa hoàn tất — chạy lại 'lapn security:ssh' sau."
    cur_ssh="$(awk -F= '/^LAPN_SSH_PORT=/{print $2}' /etc/lapn/config | tail -n1)"
  fi
fi

# --- 8) UFW ---
say "Cấu hình firewall (UFW)"
ufw --force default deny incoming
ufw --force default allow outgoing
ufw allow 80/tcp; ufw allow 443/tcp; ufw allow "${cur_ssh}/tcp"
if [[ -t 0 ]]; then
  read -r -p "Bật UFW ngay? (đảm bảo vào được qua port ${cur_ssh}) [Y/n] " ans || true
  [[ "${ans:-Y}" =~ ^[Nn] ]] || { ufw --force enable; ok "UFW bật."; }
else
  warn "Non-interactive — KHÔNG tự bật UFW. Chạy 'lapn security:firewall' khi sẵn sàng."
fi

# --- 9) fail2ban ---
say "fail2ban"
/usr/local/bin/lapn security:harden >/dev/null 2>&1 || {
  # fallback jail tối thiểu
  cat >/etc/fail2ban/jail.d/lapn.conf <<EOF
[sshd]
enabled = true
port    = ${cur_ssh}
backend = systemd
EOF
  systemctl enable --now fail2ban 2>/dev/null || true
}
ok "fail2ban cấu hình."

# --- 10) Summary ---
ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo '<IP>')"
printf '\n%s%s✓ LapN đã cài xong%s\n' "$c_g" "$c_b" "$c_0"
printf '  Server IP : %s\n' "$ip"
printf '  SSH port  : %s%s%s  (dùng: ssh -p %s ...)\n' "$c_b" "$cur_ssh" "$c_0" "$cur_ssh"
printf '  Lệnh      : lapn   (menu)  |  lapn site:create   |  lapn doctor\n'
printf '\nBắt đầu: %slapn site:create%s\n' "$c_b" "$c_0"
