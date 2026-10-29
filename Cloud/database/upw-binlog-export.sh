#!/bin/sh
set -eu

recovery_root=/home/administrator/.local/share/upasswords-recovery-material
command=${SSH_ORIGINAL_COMMAND:-}

run_mariadb() {
    docker exec mariadb sh -lc "MYSQL_PWD=\"\$MARIADB_ROOT_PASSWORD\" mariadb -uroot -N -e '$1'"
}

case "$command" in
    binlog-list)
        run_mariadb 'FLUSH BINARY LOGS'
        active=$(run_mariadb 'SHOW MASTER STATUS' | cut -f1)
        case "$active" in
            mysql-bin.[0-9]*) ;;
            *) exit 1 ;;
        esac
        printf 'ACTIVE\t%s\n' "$active"
        run_mariadb 'SHOW BINARY LOGS' | cut -f1 | while IFS= read -r file; do
            case "$file" in
                mysql-bin.[0-9]*) printf 'LOG\t%s\n' "$file" ;;
            esac
        done
        ;;
    get-log\ *)
        file=${command#get-log }
        case "$file" in
            mysql-bin.[0-9]*) ;;
            *) exit 2 ;;
        esac
        case "$file" in
            */*|*..*) exit 2 ;;
        esac
        docker exec mariadb cat "/var/log/mysql/$file"
        ;;
    put-key\ *)
        args=${command#put-key }
        stamp=${args%% *}
        name=${args#* }
        case "$stamp" in
            ????????T??????Z) ;;
            *) exit 2 ;;
        esac
        case "$name" in
            api-env|database-env|database-my-cnf|database-ca|api-db-pin) ;;
            *) exit 2 ;;
        esac
        destination="$recovery_root/$stamp"
        install -d -m 700 "$destination"
        umask 077
        cat > "$destination/$name"
        chmod 600 "$destination/$name"
        ;;
    prune-key-material)
        if [ -d "$recovery_root" ]; then
            find "$recovery_root" -mindepth 1 -maxdepth 1 -type d -mtime +30 -exec rm -rf -- {} +
        fi
        ;;
    *)
        exit 2
        ;;
esac
