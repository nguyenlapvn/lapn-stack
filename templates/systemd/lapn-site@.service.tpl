# LapN — hardened systemd unit cho site.
# Render thành /etc/systemd/system/lapn-{{NAME}}.service
# Placeholder: {{DOMAIN}} {{NAME}} {{USER}} {{WORKDIR}} {{ENVFILE}} {{PORT}}
#              {{EXEC_START}} {{MEMORY_MAX}} {{CPU_QUOTA}}
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
ProtectHome=true
ReadWritePaths={{WORKDIR}}
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
