selinux_enforcing() {
    have getenforce && [[ "$(getenforce 2>/dev/null)" == Enforcing ]]
}

selinux_configure() {
    selinux_enforcing || { echo "SELinux is not enforcing."; return 0; }
    if ! have semanage; then
        pkg_install policycoreutils-python-utils || pkg_install policycoreutils-python || true
    fi
    setsebool -P httpd_can_network_connect 1 || return 1
    if ! db_is_local; then
        setsebool -P httpd_can_network_connect_db 1 || true
    fi
    if have semanage; then
        semanage fcontext -a -t httpd_sys_content_t "${APP_DIR}(/.*)?" 2>/dev/null ||
            semanage fcontext -m -t httpd_sys_content_t "${APP_DIR}(/.*)?" 2>/dev/null
        local d
        for d in storage bootstrap/cache; do
            semanage fcontext -a -t httpd_sys_rw_content_t "${APP_DIR}/${d}(/.*)?" 2>/dev/null ||
                semanage fcontext -m -t httpd_sys_rw_content_t "${APP_DIR}/${d}(/.*)?" 2>/dev/null
        done
        if [[ -d "$SELF_SIGNED_BASE" ]]; then
            semanage fcontext -a -t cert_t "${SELF_SIGNED_BASE}(/.*)?" 2>/dev/null ||
                semanage fcontext -m -t cert_t "${SELF_SIGNED_BASE}(/.*)?" 2>/dev/null
        fi
    else
        echo "semanage is not available; applying labels with chcon only (lost on a full relabel)."
        chcon -R -t httpd_sys_content_t "$APP_DIR" 2>/dev/null
        chcon -R -t httpd_sys_rw_content_t "${APP_DIR}/storage" "${APP_DIR}/bootstrap/cache" 2>/dev/null
    fi
    restorecon -R "$APP_DIR" 2>/dev/null
    [[ -d "$SELF_SIGNED_BASE" ]] && restorecon -R "$SELF_SIGNED_BASE" 2>/dev/null
    echo "SELinux rules applied."
    return 0
}
