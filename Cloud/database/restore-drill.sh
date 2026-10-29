#!/usr/bin/env bash
set -euo pipefail
umask 077

backup_root=${UPW_BACKUP_ROOT:-/home/administrator/.local/share/upasswords-db-backups}
started_at=$(date +%s)
dump=$(find "$backup_root/full" -maxdepth 1 -type f -name 'upasswords-*.sql.gz' -printf '%T@ %p\n' | sort -nr | head -1 | cut -d' ' -f2-)
[[ -n "$dump" ]] || { echo "no full database backup found" >&2; exit 1; }
gzip -t "$dump"

coordinate=$(gzip -dc "$dump" | grep -m1 '^-- CHANGE MASTER TO MASTER_LOG_FILE=' || true)
log_file=$(sed -E "s/.*MASTER_LOG_FILE='([^']+)'.*/\1/" <<< "$coordinate")
log_position=$(sed -E 's/.*MASTER_LOG_POS=([0-9]+).*/\1/' <<< "$coordinate")
[[ "$log_file" =~ ^mysql-bin\.[0-9]{6,}$ && "$log_position" =~ ^[0-9]+$ ]] || {
    echo "full backup has no valid binlog recovery coordinate" >&2
    exit 1
}

mapfile -t archives < <(find "$backup_root/binlog" -maxdepth 1 -type f -name 'mysql-bin.*.gz' -printf '%f\n' | sort -V)
start_number=$((10#${log_file##*.}))
previous_number=0
found_start=false
for archive in "${archives[@]}"; do
    name=${archive%.gz}
    number=$((10#${name##*.}))
    (( number >= start_number )) || continue
    if [[ "$found_start" == false ]]; then
        [[ "$number" -eq "$start_number" ]] || {
            echo "binlog recovery range starts with a gap" >&2
            exit 1
        }
        found_start=true
    elif [[ "$number" -ne $((previous_number + 1)) ]]; then
        echo "binlog recovery range contains a gap" >&2
        exit 1
    fi
    previous_number=$number
done
[[ "$found_start" == true ]] || { echo "binlog at dump coordinate is not archived" >&2; exit 1; }

work=$(mktemp -d /dev/shm/upw-restore-drill.XXXXXX)
container="upw-restore-drill-$(date +%s)"
cleanup() {
    docker rm -f "$container" >/dev/null 2>&1 || true
    rm -rf -- "$work"
}
trap cleanup EXIT INT TERM

docker run --pull=never --detach --rm --name "$container" --network none \
    --tmpfs /var/lib/mysql:rw,size=1g \
    --env MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 mariadb:11.4 >/dev/null
ready=false
for _ in $(seq 1 60); do
    if docker exec "$container" healthcheck.sh --connect --innodb_initialized >/dev/null 2>&1; then
        ready=true
        break
    fi
    sleep 1
done
[[ "$ready" == true ]] || { echo "temporary MariaDB did not become ready" >&2; exit 1; }

if ! gzip -dc "$dump" | docker exec --interactive "$container" mariadb -uroot >/dev/null 2>&1; then
    echo "full database dump restore failed" >&2
    exit 1
fi

for archive in "${archives[@]}"; do
    name=${archive%.gz}
    number=$((10#${name##*.}))
    (( number >= start_number )) || continue
    binlog="$backup_root/binlog/$archive"
    raw="$work/$name"
    gzip -dc "$binlog" > "$raw"
    chmod 600 "$raw"
    if [[ "$name" == "$log_file" ]]; then
        if ! mariadb-binlog --database=upasswords --start-position="$log_position" "$raw" 2>/dev/null \
            | docker exec --interactive "$container" mariadb -uroot >/dev/null 2>&1; then
            echo "binlog replay failed at the full dump coordinate" >&2
            exit 1
        fi
    elif ! mariadb-binlog --database=upasswords "$raw" 2>/dev/null \
        | docker exec --interactive "$container" mariadb -uroot >/dev/null 2>&1; then
        echo "binlog replay failed" >&2
        exit 1
    fi
    rm -f "$raw"
done

table_count=$(docker exec "$container" mariadb -uroot --batch --skip-column-names \
    -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='upasswords'")
[[ "$table_count" =~ ^[0-9]+$ && "$table_count" -gt 0 ]] || {
    echo "restored database schema verification failed" >&2
    exit 1
}
if ! docker exec "$container" mariadb-check -uroot --databases upasswords >/dev/null 2>&1; then
    echo "restored database integrity check failed" >&2
    exit 1
fi

finished_at=$(date +%s)
printf 'restore rehearsal passed: tables=%s binlogs=%s elapsed_seconds=%s\n' \
    "$table_count" "${#archives[@]}" "$((finished_at - started_at))"
