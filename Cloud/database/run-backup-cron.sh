#!/usr/bin/env bash
set -euo pipefail
umask 077

mode=${1:-}
case "$mode" in
    full|binlog|r2|keys) ;;
    *) echo "usage: $0 [full|binlog|r2|keys]" >&2; exit 2 ;;
esac

root=${UPW_BACKUP_ROOT:-/home/administrator/.local/share/upasswords-db-backups}
log_directory="$root/logs"
mkdir -p "$log_directory"
chmod 700 "$root" "$log_directory"
log_file="$log_directory/$mode.log"
if [[ -f "$log_file" && $(wc -c < "$log_file") -gt 1048576 ]]; then
    mv -f "$log_file" "$log_file.1"
fi

if ! /home/administrator/.local/bin/upasswords-db-backup "$mode" >> "$log_file" 2>&1; then
    printf 'backup mode failed: %s\n' "$mode" >> "$log_file"
    exit 1
fi
