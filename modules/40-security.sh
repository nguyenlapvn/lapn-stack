#!/usr/bin/env bash
# modules/40-security.sh — UFW, fail2ban, SSH hardening (anti-lockout).

MODULE_NAME="Security"
MODULE_ORDER=40
MODULE_COMMANDS=("security:harden" "security:ssh" "security:firewall")

# Get the current ssh_port from config, fallback 22.
_sec_ssh_port() {
  printf '%s' "${LAPN_SSH_PORT:-${LAPN_SSH_PORT_DEFAULT:-22}}"
}

# Detect the SSH port actually listening (for first-time install).
sec_detect_ssh_port() {
  local p
  p="$(ss -tlnpH 2>/dev/null | awk '/sshd/{print $4}' | sed -E 's/.*[:.]([0-9]+)$/\1/' | head -n1 || true)"
  [[ -z "$p" ]] && p="$(awk '/^Port /{print $2; exit}' /etc/ssh/sshd_config 2>/dev/null || true)"
  [[ -z "$p" ]] && p=22
  printf '%s' "$p"
}

# Write ssh_port to /etc/lapn/config (create/replace key).
_sec_persist_ssh_port() {
  local port="$1" cfg="${LAPN_CONFIG:-/etc/lapn/config}"
  touch "$cfg"
  if grep -q '^LAPN_SSH_PORT=' "$cfg"; then
    sed -i "s/^LAPN_SSH_PORT=.*/LAPN_SSH_PORT=${port}/" "$cfg"
  else
    printf 'LAPN_SSH_PORT=%s\n' "$port" >>"$cfg"
  fi
  export LAPN_SSH_PORT="$port"
}

cmd_security_firewall() {
  core_require_root
  command -v ufw >/dev/null 2>&1 || die "ufw is not installed."
  local ssh_port; ssh_port="$(_sec_ssh_port)"
  log_step "Configure UFW (deny incoming, allow 80/443/${ssh_port})"
  ufw --force default deny incoming
  ufw --force default allow outgoing
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw allow "${ssh_port}/tcp"
  if ui_confirm "Enable UFW now? (make sure you can get in via port ${ssh_port})" Y; then
    ufw --force enable
    log_ok "UFW enabled."
  fi
  ufw status verbose
}

cmd_security_harden() {
  core_require_root
  log_step "Basic hardening"
  cmd_security_firewall
  _sec_fail2ban
  _sec_unattended_upgrades
  _sec_sysctl
  log_ok "Basic hardening complete."
}

_sec_fail2ban() {
  command -v fail2ban-server >/dev/null 2>&1 || { apt-get install -y fail2ban; }
  local ssh_port; ssh_port="$(_sec_ssh_port)"
  local jail="/etc/fail2ban/jail.d/lapn.conf"
  cat >"$jail" <<EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled  = true
port     = ${ssh_port}
backend  = systemd

[nginx-limit-req]
enabled  = true
port     = http,https
filter   = nginx-limit-req
logpath  = /var/log/nginx/error.log
maxretry = 10
EOF
  systemctl enable --now fail2ban 2>/dev/null || true
  systemctl restart fail2ban 2>/dev/null || true
  log_ok "fail2ban: jail sshd (port ${ssh_port}) + nginx-limit-req."
}

_sec_unattended_upgrades() {
  apt-get install -y unattended-upgrades >/dev/null 2>&1 || true
  dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || true
  log_ok "unattended-upgrades enabled."
}

_sec_sysctl() {
  local f="/etc/sysctl.d/99-lapn.conf"
  cat >"$f" <<'EOF'
# LapN — basic sysctl
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
EOF
  sysctl --system >/dev/null 2>&1 || true
}

# security:ssh [--port N] [--no-root] [--no-password]
# Change the port following the ANTI-LOCKOUT flow.
cmd_security_ssh() {
  core_require_root
  local new_port="" no_root=1 no_pw=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port) new_port="$2"; shift 2 ;;
      --no-root) no_root=1; shift ;;
      --allow-root) no_root=0; shift ;;
      --no-password) no_pw=1; shift ;;
      *) shift ;;
    esac
  done

  local cur; cur="$(sec_detect_ssh_port)"
  log_info "Current SSH port: $cur"

  # --- Change port (if requested) ---
  if [[ -z "$new_port" && "${LAPN_INTERACTIVE:-0}" == "1" ]]; then
    if ui_confirm "Change SSH port (currently $cur)?"; then
      new_port="$(ui_ask "New SSH port" "$cur")"
    fi
  fi
  if [[ -n "$new_port" && "$new_port" != "$cur" ]]; then
    _sec_change_ssh_port "$cur" "$new_port" || die "Changing the SSH port failed — rolled back."
    cur="$new_port"
  fi

  # --- Disable root login / password auth ---
  _sec_harden_sshd_config "$no_root" "$no_pw"
  sshd -t || die "sshd_config syntax error — not reloading."
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null
  log_ok "SSH configuration applied (port $cur)."
}

# Anti-lockout flow: open the new port FIRST, keep both ports, prompt the user to confirm.
_sec_change_ssh_port() {
  local old="$1" new="$2"
  validate_port "$new" || return 1
  (( new < 1024 )) && { log_warn "A port >1024 is recommended."; }
  if port_in_use "$new"; then log_warn "Port $new is already in use."; return 1; fi

  log_step "Change SSH port $old → $new (anti-lockout)"

  # 1) Open the new port in UFW FIRST.
  if command -v ufw >/dev/null 2>&1; then ufw allow "${new}/tcp" || true; fi

  # 2) Configure sshd to listen on BOTH ports temporarily.
  local drop="/etc/ssh/sshd_config.d/lapn-port.conf"
  mkdir -p /etc/ssh/sshd_config.d
  printf 'Port %s\nPort %s\n' "$old" "$new" >"$drop"
  if ! sshd -t; then
    rm -f "$drop"; ufw delete allow "${new}/tcp" 2>/dev/null || true
    log_error "sshd -t error — restoring."; return 1
  fi
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null

  # 3) Prompt the user to test the new port in ANOTHER terminal.
  if [[ "${LAPN_INTERACTIVE:-0}" == "1" ]]; then
    log_warn "OPEN A NEW TERMINAL and run:  ssh -p ${new} <user>@<server>"
    log_warn "DO NOT close this session until you confirm you can get in."
    local i ok=""
    for i in $(seq 60 -1 1); do
      printf '\rConfirm login on port %s works? type YES (%ss left): ' "$new" "$i"
      if read -r -t 1 ans 2>/dev/null; then
        [[ "$ans" == "YES" ]] && { ok=1; break; }
      fi
    done
    printf '\n'
    if [[ -z "$ok" ]]; then
      log_error "Not confirmed — ROLLBACK to port $old."
      printf 'Port %s\n' "$old" >"$drop"
      sshd -t && { systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null; }
      ufw delete allow "${new}/tcp" 2>/dev/null || true
      rm -f "$drop"
      return 1
    fi
  fi

  # 4) Finalize: keep only the new port.
  printf 'Port %s\n' "$new" >"$drop"
  sshd -t || { log_error "sshd -t error after finalizing."; return 1; }
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null

  # 5) Close the old port + save state + fail2ban on the new port.
  if command -v ufw >/dev/null 2>&1; then ufw delete allow "${old}/tcp" 2>/dev/null || true; fi
  _sec_persist_ssh_port "$new"
  _sec_fail2ban
  audit "OK" "security:ssh change-port $old->$new"
  log_ok "SSH port changed successfully: $new"
}

_sec_harden_sshd_config() {
  local no_root="$1" no_pw="$2"
  local drop="/etc/ssh/sshd_config.d/lapn-harden.conf"
  mkdir -p /etc/ssh/sshd_config.d
  {
    [[ "$no_root" == "1" ]] && printf 'PermitRootLogin no\n'
    if [[ "$no_pw" == "1" ]]; then
      # Safety: only disable password if the calling user (via SUDO_USER) already has authorized_keys.
      local u="${SUDO_USER:-root}" h
      h="$(getent passwd "$u" | cut -d: -f6)"
      if [[ -s "$h/.ssh/authorized_keys" ]]; then
        printf 'PasswordAuthentication no\n'
        printf 'PubkeyAuthentication yes\n'
      else
        log_warn "User $u does NOT have authorized_keys yet — KEEPING password auth to avoid lockout."
      fi
    fi
    printf 'X11Forwarding no\n'
    printf 'MaxAuthTries 3\n'
  } >"$drop"
}
