# LapN — hardened systemd unit for the site.
# Rendered into /etc/systemd/system/lapn-{{NAME}}.service
# Placeholders: DOMAIN NAME USER WORKDIR HOMEDIR ENVFILE PORT
#              EXEC_START MEMORY_MAX CPU_QUOTA
[Unit]
Description=LapN site: {{DOMAIN}}
After=network.target

[Service]
Type=simple
User={{USER}}
Group={{USER}}
WorkingDirectory={{WORKDIR}}
EnvironmentFile={{ENVFILE}}
Environment=NODE_ENV=production
Environment=HOST=127.0.0.1
Environment=PORT={{PORT}}
ExecStart={{EXEC_START}}
Restart=on-failure
RestartSec=3

# --- Hardening ---
NoNewPrivileges=true
ProtectSystem=strict
# ProtectHome=true would mount /home as INACCESSIBLE, and systemd drops every
# ReadWritePaths= below an inaccessible mount — the unit could then neither chdir into
# WorkingDirectory nor exec the per-user fnm node, both of which live under /home.
# read-only keeps other users' homes (and /root) unreadable while ReadWritePaths=
# below punches the hole this site needs. Cross-site reads stay blocked by the 750
# mode on each site home.
ProtectHome=read-only
ReadWritePaths={{HOMEDIR}}
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictSUIDSGID=true
LockPersonality=true
MemoryMax={{MEMORY_MAX}}
CPUQuota={{CPU_QUOTA}}

[Install]
WantedBy=multi-user.target
