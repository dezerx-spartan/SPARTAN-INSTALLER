# shellcheck shell=bash
# Clock synchronisation. A wrong clock breaks TLS (Let's Encrypt, the license
# API) with confusing certificate errors.

time_sync() {
    if in_container; then
        echo "Container: the clock belongs to the host, skipping."
        return 0
    fi
    if have timedatectl && timedatectl set-ntp true 2>/dev/null; then
        echo "Time synchronisation enabled through systemd-timesyncd/chrony: $(date)"
        return 0
    fi
    if have chronyc; then
        local svc="chronyd"
        is_debian_family && svc="chrony"
        start_service "$svc" || true
        chronyc -a makestep || true
        echo "Clock stepped with chrony: $(date)"
        return 0
    fi
    if have ntpdate; then
        ntpdate -u pool.ntp.org || true
        return 0
    fi
    pkg_install chrony || return 0
    local svc="chronyd"
    is_debian_family && svc="chrony"
    start_service "$svc" || true
    have chronyc && chronyc -a makestep
    return 0
}
