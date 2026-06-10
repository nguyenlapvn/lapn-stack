# LapN — log rotation. Cài thành /etc/logrotate.d/lapn bởi install.sh.

/var/log/lapn/actions.log {
    weekly
    rotate 12
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root adm
}

# File log app tự ghi (nếu app ghi thẳng ra file). stdout/stderr đã vào journald.
/home/sites/*/logs/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
