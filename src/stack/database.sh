# shellcheck shell=bash
# MariaDB / MySQL: server detection and installation, database and user,
# tuning, and the dump/restore used by backups.
#
# Passwords never appear on a command line (visible in `ps`) or in the log:
# the client reads them from a mode-600 option file inside this run's private
# directory, and SQL is sent on stdin.

db_is_local() {
    [[ "${DB_HOST:-127.0.0.1}" == 127.0.0.1 || "${DB_HOST:-}" == localhost || "${DB_HOST:-}" == ::1 ]]
}

db_client() { if have mariadb; then echo mariadb; else echo mysql; fi; }
db_dump_bin() { if have mariadb-dump; then echo mariadb-dump; else echo mysqldump; fi; }

# Escapes a value for a my.cnf option file (double-quoted).
_cnf_escape() {
    local v="$1"
    v="${v//\\/\\\\}"
    v="${v//\"/\\\"}"
    printf '%s' "$v"
}

# db_app_cnf - option file with the application's credentials; path in REPLY.
db_app_cnf() {
    local f="${RUN_DIR}/db-app.cnf"
    (
        umask 077
        {
            echo "[client]"
            echo "host=\"$(_cnf_escape "$DB_HOST")\""
            echo "port=${DB_PORT}"
            echo "user=\"$(_cnf_escape "$DB_USER")\""
            echo "password=\"$(_cnf_escape "$DB_PASS")\""
            echo "connect-timeout=10"
        } >"$f"
    )
    REPLY="$f"
}

db_root_cnf() {
    local f="${RUN_DIR}/db-root.cnf"
    (
        umask 077
        {
            echo "[client]"
            echo "user=root"
            [[ -n "$DB_ROOT_PASS" ]] && echo "password=\"$(_cnf_escape "$DB_ROOT_PASS")\""
            echo "connect-timeout=10"
        } >"$f"
    )
    REPLY="$f"
}

# db_app_sql <sql> - runs SQL as the application user (SQL on stdin).
db_app_sql() {
    db_app_cnf
    printf '%s\n' "$1" | "$(db_client)" --defaults-extra-file="$REPLY" "${@:2}"
}

db_check_connection() {
    db_app_cnf
    "$(db_client)" --defaults-extra-file="$REPLY" -e "SELECT 1;" "$DB_NAME" >/dev/null
}

# ---------------------------------------------------------------------------
# Server
# ---------------------------------------------------------------------------

# Sets EXISTING_DB_SERVER (mariadb | mysql | empty) and EXISTING_DB_VERSION.
db_server_detect() {
    EXISTING_DB_SERVER=""
    EXISTING_DB_VERSION=""
    local bin out
    for bin in /usr/sbin/mariadbd /usr/sbin/mysqld /usr/libexec/mysqld /usr/libexec/mariadbd; do
        [[ -x "$bin" ]] || continue
        out="$("$bin" --version 2>/dev/null)"
        [[ -n "$out" ]] || continue
        if [[ "$out" == *MariaDB* ]]; then
            EXISTING_DB_SERVER="mariadb"
            EXISTING_DB_VERSION="$(sed -nE 's/.*(Distrib |Ver )([0-9]+\.[0-9]+\.[0-9]+)-MariaDB.*/\2/p' <<<"$out")"
        else
            EXISTING_DB_SERVER="mysql"
            EXISTING_DB_VERSION="$(sed -nE 's/.*Ver ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' <<<"$out")"
        fi
        return 0
    done
    return 1
}

db_server_label() {
    local e="${1:-$EXISTING_DB_SERVER}" v="${2:-$EXISTING_DB_VERSION}"
    case "$e" in
        mariadb) printf 'MariaDB%s' "${v:+ $v}" ;;
        mysql) printf 'MySQL%s' "${v:+ $v}" ;;
        *) printf 'database server' ;;
    esac
}

# MySQL is not packaged on Debian (only MariaDB is); offer it only when it is.
db_mysql_available() {
    case "$OS_BASE" in
        ubuntu | debian) [[ -n "$(apt_candidate mysql-server)" ]] ;;
        el) dnf_cmd -q list mysql-server >/dev/null 2>&1 || dnf_cmd -q list mysql8.4-server >/dev/null 2>&1 ;;
        fedora) dnf_cmd -q list community-mysql-server >/dev/null 2>&1 || dnf_cmd -q list mysql8.4-server >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

db_service_name() {
    local s
    for s in mariadb mysql mysqld; do
        svc_exists "$s" && { echo "$s"; return 0; }
    done
    echo mariadb
}

install_db_engine() {
    if db_server_detect; then
        echo "Using the installed $(db_server_label)."
    elif [[ "${DB_ENGINE:-mariadb}" == mysql ]]; then
        case "$OS_BASE" in
            ubuntu | debian) pkg_install mysql-server mysql-client || return 1 ;;
            el) pkg_install mysql-server || pkg_install mysql8.4-server || return 1 ;;
            fedora) pkg_install community-mysql-server || pkg_install mysql8.4-server || pkg_install mysql-server || return 1 ;;
        esac
    else
        case "$OS_BASE" in
            ubuntu | debian) pkg_install mariadb-server mariadb-client || pkg_install mariadb-server || return 1 ;;
            *) pkg_install mariadb-server mariadb || pkg_install mariadb-server || return 1 ;;
        esac
    fi
    systemctl enable --now "$(db_service_name)" || return 1
    have mysql || have mariadb || pkg_install mariadb-client || pkg_install mysql-client || pkg_install mariadb || true
    db_server_detect
    echo "Database server: $(db_server_label)"
}

# db_root_sql <sql> - runs SQL with administrative rights. Tries root through
# the unix socket (the default on fresh MariaDB/MySQL installs), then root's
# ~/.my.cnf, then the root password given in the wizard or --db-root-pass.
db_root_sql() {
    local sql="$1" client
    client="$(db_client)"
    if printf 'SELECT 1;\n' | HOME=/root "$client" --protocol=socket -uroot >/dev/null 2>&1; then
        DB_ROOT_METHOD="socket"
        printf '%s\n' "$sql" | HOME=/root "$client" --protocol=socket -uroot
        return
    fi
    if [[ -n "$DB_ROOT_PASS" ]]; then
        db_root_cnf
        DB_ROOT_METHOD="password"
        printf '%s\n' "$sql" | "$client" --defaults-extra-file="$REPLY" --protocol=tcp -h 127.0.0.1 -P "$DB_PORT"
        return
    fi
    echo "Cannot log in to the database server as root (socket login failed and no root password was given)."
    return 1
}

db_root_access_ok() {
    have mysql || have mariadb || return 0
    db_server_detect || return 0
    db_root_sql "SELECT 1;" >/dev/null 2>&1
}

_sql_str() {
    local v="$1"
    v="${v//\\/\\\\}"
    v="${v//\'/\\\'}"
    printf '%s' "$v"
}

db_create() {
    local user host pass
    user="$(_sql_str "$DB_USER")"
    host="$(_sql_str "$DB_HOST")"
    pass="$(_sql_str "$DB_PASS")"
    db_root_sql "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${user}'@'${host}' IDENTIFIED BY '${pass}';
ALTER USER '${user}'@'${host}' IDENTIFIED BY '${pass}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${user}'@'${host}';
FLUSH PRIVILEGES;"
}

# InnoDB buffer pool sized from RAM, slow query log over 250 ms (1.x tuning).
# Written once; an existing file is never overwritten.
config_db_tuning() {
    db_is_local || { echo "Remote database, not tuning."; return 0; }
    local dir="" c
    for c in /etc/mysql/mariadb.conf.d /etc/my.cnf.d /etc/mysql/mysql.conf.d /etc/mysql/conf.d; do
        [[ -d "$c" ]] && { dir="$c"; break; }
    done
    [[ -n "$dir" ]] || { echo "No database config directory found."; return 0; }
    local cnf="${dir}/90-dezerx-spartan.cnf"
    [[ -f "$cnf" ]] && { echo "Tuning already in place (${cnf})."; return 0; }
    [[ -n "$MEM_TOTAL_MB" ]] || detect_resources
    local pool=$((MEM_TOTAL_MB * 40 / 100))
    ((MEM_TOTAL_MB <= 2048)) && pool=$((MEM_TOTAL_MB * 25 / 100))
    ((pool < 128)) && pool=128
    ((pool > 16384)) && pool=16384
    printf '%s\n' "[mysqld]" "innodb_buffer_pool_size = ${pool}M" "slow_query_log = 1" "long_query_time = 0.25" >"$cnf"
    echo "Buffer pool ${pool} MB written to ${cnf}; restarting the database."
    if ! systemctl restart "$(db_service_name)"; then
        echo "The database did not restart with the tuning; removing it."
        rm -f "$cnf"
        systemctl restart "$(db_service_name)"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Dump and restore (used by backups and rollback)
# ---------------------------------------------------------------------------

# db_dump <file.sql.gz> - consistent dump; fails if the dump is incomplete.
db_dump() {
    local out="$1"
    db_app_cnf
    (
        set -o pipefail
        "$(db_dump_bin)" --defaults-extra-file="$REPLY" --single-transaction --quick --no-tablespaces \
            --default-character-set=utf8mb4 "$DB_NAME" | gzip -c >"$out"
    ) || return 1
    # mysqldump writes this trailer only when it finished.
    gzip -dc "$out" | tail -n 3 | grep -q -- "-- Dump completed" || {
        echo "The database dump is incomplete."
        return 1
    }
    chmod 600 "$out"
}

# db_restore <file.sql.gz> - empties the database first, so tables created by a
# failed update are not left behind next to the restored ones.
db_restore() {
    local file="$1" client drops
    client="$(db_client)"
    db_app_cnf
    drops="$("$client" --defaults-extra-file="$REPLY" -N -B -e \
        "SELECT CONCAT(IF(table_type = 'VIEW', 'DROP VIEW IF EXISTS ', 'DROP TABLE IF EXISTS '), '\`', table_name, '\`;') FROM information_schema.tables WHERE table_schema = DATABASE();" \
        "$DB_NAME")" || return 1
    if [[ -n "$drops" ]]; then
        printf 'SET FOREIGN_KEY_CHECKS=0;\n%s\nSET FOREIGN_KEY_CHECKS=1;\n' "$drops" |
            "$client" --defaults-extra-file="$REPLY" "$DB_NAME" || return 1
    fi
    (
        set -o pipefail
        gzip -dc "$file" | "$client" --defaults-extra-file="$REPLY" "$DB_NAME"
    )
}

db_size_mb() {
    db_app_cnf
    "$(db_client)" --defaults-extra-file="$REPLY" -N -B -e \
        "SELECT CEIL(COALESCE(SUM(data_length + index_length), 0) / 1048576) FROM information_schema.tables WHERE table_schema = DATABASE();" \
        "$DB_NAME" 2>/dev/null
}
