# LapN — log rotation. Installed as /etc/logrotate.d/lapn by install.sh.

/var/log/lapn/actions.log {
    weekly
    rotate 12
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root adm
}

# App-written log files (if the app writes directly to a file). stdout/stderr already go to journald.
/home/sites/*/logs/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
