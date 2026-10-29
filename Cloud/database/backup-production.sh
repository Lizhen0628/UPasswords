#!/usr/bin/env bash
set -euo pipefail
umask 077

# Production disaster recovery helper. Run on service-admin only.
# Secrets stay in protected host files; backup SSH commands are strictly whitelisted.

mode=${1:-all}
case "$mode" in
    all|full|binlog|r2|keys) ;;
    *) echo "usage: $0 [all|full|binlog|r2|keys]" >&2; exit 2 ;;
esac

root=${UPW_BACKUP_ROOT:-/home/administrator/.local/share/upasswords-db-backups}
stamp=$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$root/full" "$root/binlog" "$root/r2" "$root/key-material"
chmod 700 "$root" "$root/full" "$root/binlog" "$root/r2" "$root/key-material"

exec 9>"$root/.full.lock"
exec 10>"$root/.binlog.lock"
exec 11>"$root/.r2.lock"
exec 12>"$root/.keys.lock"
case "$mode" in
    all) lock_fds=(9 10 11 12) ;;
    full) lock_fds=(9) ;;
    binlog) lock_fds=(10) ;;
    r2) lock_fds=(11) ;;
    keys) lock_fds=(12) ;;
esac
for descriptor in "${lock_fds[@]}"; do
    if ! flock -n "$descriptor"; then
        echo "backup mode already running: $mode" >&2
        exit 0
    fi
done

identity=${UPW_BINLOG_SSH_KEY:-/home/administrator/.ssh/upw-binlog-backup}
backup_config=${UPW_BACKUP_CONFIG_DIR:-/home/administrator/.config/upasswords-backup}
host=${UPW_BINLOG_SSH_HOST:-$(cat "$backup_config/ssh-host" 2>/dev/null || true)}
port=${UPW_BINLOG_SSH_PORT:-$(cat "$backup_config/ssh-port" 2>/dev/null || true)}
[[ -n "$host" && "$port" =~ ^[0-9]+$ ]] || {
    echo "backup SSH target is not configured" >&2
    exit 1
}
ssh_options=(-i "$identity" -p "$port" -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes)

if [[ "$mode" == all || "$mode" == full ]]; then
    dump_tmp="$root/full/.upasswords-$stamp.sql.gz.tmp"
    ssh "${ssh_options[@]}" "$host" get-full-dump | gzip -n > "$dump_tmp"
    gzip -t "$dump_tmp"
    mv "$dump_tmp" "$root/full/upasswords-$stamp.sql.gz"
    chmod 600 "$root/full/upasswords-$stamp.sql.gz"
fi

if [[ "$mode" == all || "$mode" == binlog ]]; then
    listing=$(ssh "${ssh_options[@]}" "$host" binlog-list)
    active=$(awk '$1 == "ACTIVE" { print $2 }' <<< "$listing")
    [[ "$active" =~ ^mysql-bin\.[0-9]+$ ]] || {
        echo "database host returned an invalid active binlog name" >&2
        exit 1
    }
    while IFS= read -r file; do
        [[ "$file" =~ ^mysql-bin\.[0-9]+$ ]] || continue
        [[ "$file" == "$active" ]] && continue
        archive="$root/binlog/$file.gz"
        [[ -f "$archive" ]] && continue
        tmp="$archive.tmp"
        ssh -n "${ssh_options[@]}" "$host" "get-log $file" | gzip -n > "$tmp"
        gzip -t "$tmp"
        mv "$tmp" "$archive"
        chmod 600 "$archive"
    done < <(awk '$1 == "LOG" { print $2 }' <<< "$listing")
fi

if [[ "$mode" == all || "$mode" == r2 ]]; then
    r2="$root/r2/current"
    mkdir -p "$r2"
    chmod 700 "$r2"
    cd /home/administrator/UPasswords/Cloud/api
    docker compose run --rm --no-deps --user "$(id -u):$(id -g)" \
        -v "$r2:/backup" api backup-r2 /backup
fi

if [[ "$mode" == all || "$mode" == keys ]]; then
    key_dir="$root/key-material/$stamp"
    mkdir -m 700 "$key_dir"
    install -m 600 /home/administrator/UPasswords/Cloud/api/.env "$key_dir/api.env"
    install -m 600 /home/administrator/UPasswords/Cloud/database/upasswords-deploy.env "$key_dir/database.env"
    install -m 600 /home/administrator/UPasswords/Cloud/database/upasswords-deploy.my.cnf "$key_dir/database.my.cnf"
    install -m 600 /home/administrator/UPasswords/Cloud/database/mariadb-ca.pem "$key_dir/database-ca.pem"
    install -m 600 /home/administrator/UPasswords/Cloud/api/secrets/mariadb.pem "$key_dir/api-database-pin.pem"

    key_stamp="$stamp"
    tls_key_tmp="$key_dir/.database-server-key.pem.tmp"
    tls_cert_tmp="$key_dir/.database-server-cert.pem.tmp"
    ssh "${ssh_options[@]}" "$host" get-tls-key > "$tls_key_tmp"
    ssh "${ssh_options[@]}" "$host" get-tls-cert > "$tls_cert_tmp"
    [[ -s "$tls_key_tmp" && -s "$tls_cert_tmp" ]] || {
        echo "database server TLS recovery material is empty" >&2
        exit 1
    }
    chmod 600 "$tls_key_tmp" "$tls_cert_tmp"
    mv "$tls_key_tmp" "$key_dir/database-server-key.pem"
    mv "$tls_cert_tmp" "$key_dir/database-server-cert.pem"
    for name in api-env database-env database-my-cnf database-ca api-db-pin; do
        case "$name" in
            api-env) source_file="$key_dir/api.env" ;;
            database-env) source_file="$key_dir/database.env" ;;
            database-my-cnf) source_file="$key_dir/database.my.cnf" ;;
            database-ca) source_file="$key_dir/database-ca.pem" ;;
            api-db-pin) source_file="$key_dir/api-database-pin.pem" ;;
        esac
        ssh "${ssh_options[@]}" "$host" "put-key $key_stamp $name" < "$source_file"
    done
    ssh "${ssh_options[@]}" "$host" prune-key-material
    find "$root/key-material" -mindepth 1 -maxdepth 1 -type d -mtime +30 -exec rm -rf -- {} +
fi

find "$root/full" -type f -name '*.sql.gz' -mtime +30 -delete
find "$root/binlog" -type f -name '*.gz' -mtime +30 -delete
