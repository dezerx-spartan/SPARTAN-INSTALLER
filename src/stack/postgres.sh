PG_MIN_MAJOR=13

db_is_pg() { [[ "${DB_ENGINE:-}" == postgresql ]]; }

db_default_port() { if db_is_pg; then echo 5432; else echo 3306; fi; }

db_port_default_apply() {
    ((DB_PORT_SET)) && return 0
    [[ -z "$DB_PORT" || "$DB_PORT" == 3306 || "$DB_PORT" == 5432 ]] || return 0
    DB_PORT="$(db_default_port)"
}

db_root_name() { if db_is_pg; then echo postgres; else echo root; fi; }

pg_server_detect() {
    EXISTING_PG_VERSION=""
    local bin out v
    for bin in /usr/lib/postgresql/*/bin/postgres /usr/pgsql-*/bin/postgres /usr/bin/postgres; do
        [[ -x "$bin" ]] || continue
        out="$("$bin" --version 2>/dev/null)"
        v="$(sed -nE 's/.*\(PostgreSQL\) ([0-9]+(\.[0-9]+)?).*/\1/p' <<<"$out")"
        [[ -n "$v" ]] || continue
        if [[ -z "$EXISTING_PG_VERSION" ]] || version_gt "$v" "$EXISTING_PG_VERSION"; then
            EXISTING_PG_VERSION="$v"
        fi
    done
    [[ -n "$EXISTING_PG_VERSION" ]]
}

pg_service_name() {
    local s
    for s in postgresql $(systemctl list-unit-files --plain --no-legend 'postgresql-*.service' 2>/dev/null | awk '{ sub(/\.service$/, "", $1); print $1 }'); do
        svc_exists "$s" && { echo "$s"; return 0; }
    done
    echo postgresql
}

_pgpass_escape() {
    local v="$1"
    v="${v//\\/\\\\}"
    v="${v//:/\\:}"
    printf '%s' "$v"
}

_pg_lit() {
    printf "'%s'" "${1//\'/\'\'}"
}

pg_pass_file() {
    local f="${RUN_DIR}/pgpass-$1"
    (
        umask 077
        printf '*:*:*:%s:%s\n' "$(_pgpass_escape "$1")" "$(_pgpass_escape "$2")" >"$f"
    )
    REPLY="$f"
}

pg_app_psql() {
    pg_pass_file "$DB_USER" "$DB_PASS"
    PGPASSFILE="$REPLY" PGCONNECT_TIMEOUT=10 PGOPTIONS='-c client_min_messages=warning' psql -X -q -v ON_ERROR_STOP=1 \
        -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" "$@"
}

pg_super_peer_ok() {
    have psql && (cd / && runuser -u postgres -- psql -X -At -d postgres -c 'SELECT 1;' >/dev/null 2>&1)
}

pg_super_sql() {
    local sql="$1" db="${2:-postgres}"
    shift $(($# < 2 ? $# : 2))
    if pg_super_peer_ok; then
        DB_ROOT_METHOD="peer"
        printf '%s\n' "$sql" | (cd / && runuser -u postgres -- env PGOPTIONS='-c client_min_messages=warning' psql -X -q -v ON_ERROR_STOP=1 -d "$db" "$@")
        return
    fi
    if [[ -n "$DB_ROOT_PASS" ]]; then
        pg_pass_file postgres "$DB_ROOT_PASS"
        DB_ROOT_METHOD="password"
        printf '%s\n' "$sql" | PGPASSFILE="$REPLY" PGCONNECT_TIMEOUT=10 PGOPTIONS='-c client_min_messages=warning' psql -X -q -v ON_ERROR_STOP=1 \
            -h 127.0.0.1 -p "$DB_PORT" -U postgres -d "$db" "$@"
        return
    fi
    echo "Cannot log in to PostgreSQL as postgres (peer login failed and no password was given)."
    return 1
}

pg_root_access_ok() {
    have psql || return 0
    pg_server_detect || return 0
    pg_super_sql "SELECT 1;" >/dev/null 2>&1
}

pg_check_connection() {
    pg_app_psql -At -c 'SELECT 1;' >/dev/null
}

pg_el_enable_stream() {
    have dnf || return 0
    dnf -q module list postgresql >/dev/null 2>&1 || return 0
    local s
    for s in 17 16 15 13; do
        if dnf -q module list postgresql 2>/dev/null | awk '{ print $2 }' | grep -qx "$s"; then
            dnf -y module reset postgresql >/dev/null 2>&1
            dnf -y module enable "postgresql:${s}" && return 0
        fi
    done
    return 0
}

pg_initdb_if_needed() {
    is_rpm_family || return 0
    local data="/var/lib/pgsql/data"
    [[ -f "${data}/PG_VERSION" ]] && return 0
    if have postgresql-setup; then
        postgresql-setup --initdb
    else
        runuser -u postgres -- initdb -D "$data" --encoding=UTF8 --auth-local=peer --auth-host=scram-sha-256
    fi
}

pg_hba_password_auth() {
    local hba
    hba="$(pg_super_sql "SHOW hba_file;" postgres -At)" || return 1
    [[ -f "$hba" ]] || { echo "pg_hba.conf not found."; return 1; }
    if grep -qE '^[[:space:]]*host[[:space:]]+all[[:space:]]+all[[:space:]]+(127\.0\.0\.1/32|::1/128)[[:space:]]+ident' "$hba"; then
        cp -p "$hba" "${hba}.spartan.bak"
        sed -i -E 's#^([[:space:]]*host[[:space:]]+all[[:space:]]+all[[:space:]]+(127\.0\.0\.1/32|::1/128)[[:space:]]+)ident#\1md5#' "$hba"
        echo "Password logins over 127.0.0.1 enabled in ${hba}."
        pg_super_sql "SELECT pg_reload_conf();" >/dev/null || return 1
    fi
    return 0
}

pg_install_engine() {
    if pg_server_detect; then
        echo "Using the installed PostgreSQL ${EXISTING_PG_VERSION}."
    else
        case "$OS_BASE" in
            ubuntu | debian) pkg_install postgresql postgresql-contrib || pkg_install postgresql || return 1 ;;
            el)
                pg_el_enable_stream
                pkg_install postgresql-server postgresql-contrib || return 1
                ;;
            *) pkg_install postgresql-server postgresql-contrib || return 1 ;;
        esac
        pg_server_detect || { echo "PostgreSQL was installed but its server binary was not found."; return 1; }
    fi
    if ((${EXISTING_PG_VERSION%%.*} < PG_MIN_MAJOR)); then
        echo "PostgreSQL ${EXISTING_PG_VERSION} is too old; DezerX Spartan needs ${PG_MIN_MAJOR} or newer."
        return 1
    fi
    pg_initdb_if_needed || return 1
    systemctl enable --now "$(pg_service_name)" || return 1
    svc_wait_active "$(pg_service_name)" 30 >/dev/null 2>&1 || true
    pg_hba_password_auth || return 1
    EXISTING_DB_SERVER="postgresql"
    EXISTING_DB_VERSION="$EXISTING_PG_VERSION"
    echo "Database server: PostgreSQL ${EXISTING_PG_VERSION}"
}

pg_install_client() {
    have psql && return 0
    if is_debian_family; then
        pkg_install postgresql-client
    else
        pkg_install postgresql
    fi
}

pg_create() {
    local name="$DB_NAME" user="$DB_USER" exists
    pg_super_sql "SELECT format('CREATE ROLE %I LOGIN', $(_pg_lit "$user")) WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = $(_pg_lit "$user"))
\\gexec
ALTER ROLE \"${user}\" WITH LOGIN PASSWORD $(_pg_lit "$DB_PASS");" || return 1
    exists="$(pg_super_sql "SELECT 1 FROM pg_database WHERE datname = $(_pg_lit "$name");" postgres -At)" || return 1
    if [[ "$exists" != 1 ]]; then
        pg_super_sql "CREATE DATABASE \"${name}\" OWNER \"${user}\" ENCODING 'UTF8' TEMPLATE template0;" ||
            pg_super_sql "CREATE DATABASE \"${name}\" OWNER \"${user}\" ENCODING 'UTF8' LOCALE 'C.UTF-8' TEMPLATE template0;" ||
            pg_super_sql "CREATE DATABASE \"${name}\" OWNER \"${user}\" ENCODING 'UTF8' LOCALE 'C' TEMPLATE template0;" ||
            return 1
    fi
    pg_super_sql "ALTER DATABASE \"${name}\" OWNER TO \"${user}\";" || return 1
    pg_super_sql "CREATE EXTENSION IF NOT EXISTS citext;
GRANT ALL ON SCHEMA public TO \"${user}\";" "$name"
}

pg_drop() {
    pg_super_sql "DROP DATABASE IF EXISTS \"${DB_NAME}\" WITH (FORCE);" || return 1
    pg_super_sql "DROP ROLE IF EXISTS \"${DB_USER}\";"
}

pg_config_tuning() {
    db_is_local || { echo "Remote database, not tuning."; return 0; }
    local tuned
    tuned="$(pg_super_sql "SELECT count(*) FROM pg_file_settings WHERE name = 'shared_buffers' AND sourcefile LIKE '%postgresql.auto.conf';" postgres -At)" || return 1
    [[ "$tuned" == 0 ]] || { echo "Tuning already in place (postgresql.auto.conf)."; return 0; }
    [[ -n "$MEM_TOTAL_MB" ]] || detect_resources
    local shared=$((MEM_TOTAL_MB * 25 / 100)) cache=$((MEM_TOTAL_MB * 50 / 100))
    ((MEM_TOTAL_MB <= 2048)) && shared=$((MEM_TOTAL_MB * 15 / 100))
    ((shared < 128)) && shared=128
    ((shared > 8192)) && shared=8192
    pg_super_sql "ALTER SYSTEM SET shared_buffers = '${shared}MB';
ALTER SYSTEM SET effective_cache_size = '${cache}MB';
ALTER SYSTEM SET log_min_duration_statement = '250ms';" || return 1
    echo "shared_buffers ${shared} MB written to postgresql.auto.conf; restarting PostgreSQL."
    if ! systemctl restart "$(pg_service_name)"; then
        echo "PostgreSQL did not restart with the tuning; removing it."
        local auto
        for auto in /etc/postgresql/*/main /var/lib/postgresql/*/main /var/lib/pgsql/data /var/lib/pgsql/*/data; do
            [[ -f "${auto}/postgresql.auto.conf" ]] &&
                sed -i -E '/^(shared_buffers|effective_cache_size|log_min_duration_statement) = /d' "${auto}/postgresql.auto.conf"
        done
        systemctl restart "$(pg_service_name)"
        return 1
    fi
}

pg_dump_db() {
    local out="$1"
    pg_pass_file "$DB_USER" "$DB_PASS"
    (
        set -o pipefail
        PGPASSFILE="$REPLY" PGCONNECT_TIMEOUT=10 pg_dump -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" \
            --no-owner --no-privileges --format=plain "$DB_NAME" | gzip -c >"$out"
    ) || return 1
    gzip -dc "$out" | tail -n 5 | grep -q -- "PostgreSQL database dump complete" || {
        echo "The database dump is incomplete."
        return 1
    }
    chmod 600 "$out"
}

pg_restore_db() {
    local file="$1"
    pg_app_psql -c "DO \$\$
DECLARE r record;
BEGIN
    FOR r IN SELECT format('DROP VIEW IF EXISTS %I.%I CASCADE', schemaname, viewname) AS s FROM pg_views WHERE schemaname = 'public' LOOP
        EXECUTE r.s;
    END LOOP;
    FOR r IN SELECT format('DROP TABLE IF EXISTS %I.%I CASCADE', schemaname, tablename) AS s FROM pg_tables WHERE schemaname = 'public' LOOP
        EXECUTE r.s;
    END LOOP;
    FOR r IN SELECT format('DROP SEQUENCE IF EXISTS %I.%I CASCADE', sequence_schema, sequence_name) AS s FROM information_schema.sequences WHERE sequence_schema = 'public' LOOP
        EXECUTE r.s;
    END LOOP;
END \$\$;" || return 1
    (
        set -o pipefail
        gzip -dc "$file" | grep -vE '^(CREATE|COMMENT ON) EXTENSION ' | pg_app_psql -1 -o /dev/null -f -
    )
}

pg_size_mb() {
    pg_app_psql -At -c "SELECT CEIL(pg_database_size(current_database()) / 1048576.0);" 2>/dev/null
}
