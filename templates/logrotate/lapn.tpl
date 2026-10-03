# LapN — log rotation. Rendered to /etc/logrotate.d/lapn by install.sh / lapn update.
# Placeholders: SITES_HOME

/var/log/lapn/actions.log {
    weekly
    rotate 12
    compress
    delaycompress
    missingok
    notifempty
    create 0600 root root
}

# App-written log files (if the app writes directly to a file). stdout/stderr already go to journald.
{{SITES_HOME}}/*/logs/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
