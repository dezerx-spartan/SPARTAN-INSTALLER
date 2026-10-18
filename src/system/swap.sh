# shellcheck shell=bash
# Swap: a permanent /swapfile on small servers (or when --add-swap is given)
# and a temporary one while the frontend is built.

SWAP_FILE="/swapfile"
SWAP_TEMP_FILE="/swapfile_spartan_temp"
SWAP_TEMP_ACTIVE=0

# swap_make <file> <size MB> - allocates and enables a swap file. Handles btrfs
# (needs a no-copy-on-write file) and filesystems where fallocate'd files are
# rejected by swapon (falls back to writing zeros).
swap_make() {
    local file="$1" mb="$2" fstype
    fstype="$(stat -f -c %T "$(dirname "$file")" 2>/dev/null)"
    rm -f "$file"
    if [[ "$fstype" == btrfs ]]; then
        touch "$file" && chattr +C "$file" 2>/dev/null
    fi
    if ! fallocate -l "${mb}M" "$file" 2>/dev/null; then
        dd if=/dev/zero of="$file" bs=1M count="$mb" status=none || return 1
    fi
    chmod 600 "$file"
    mkswap "$file" >/dev/null || return 1
    if ! swapon "$file" 2>/dev/null; then
        # Some filesystems refuse files with unwritten extents; write real zeros.
        rm -f "$file"
        [[ "$fstype" == btrfs ]] && { touch "$file"; chattr +C "$file" 2>/dev/null; }
        dd if=/dev/zero of="$file" bs=1M count="$mb" status=none || return 1
        chmod 600 "$file"
        mkswap "$file" >/dev/null || return 1
        swapon "$file" || return 1
    fi
    return 0
}

# swap_needed_mb - target size for the permanent swap file, 0 when none is needed.
swap_needed_mb() {
    in_container && { echo 0; return; }
    local target=2048 cur
    if ((FORCE_SWAP)); then
        target="$SWAP_SIZE_MB"
    else
        (($(mem_total_mb) > 2048)) && { echo 0; return; }
    fi
    cur="$(swap_total_mb)"
    ((cur >= target - 50)) && { echo 0; return; }
    echo "$target"
}

swap_ensure_permanent() {
    local target
    target="$(swap_needed_mb)"
    ((target > 0)) || { echo "Swap is sufficient."; return 0; }

    local free
    free="$(free_mb /)"
    if ((free < target + 2048)); then
        echo "Not enough free disk space for a ${target} MB swap file (${free} MB free)."
        return 1
    fi
    echo "Creating a ${target} MB swap file at ${SWAP_FILE} (current swap: $(swap_total_mb) MB)."
    if grep -q "^${SWAP_FILE} " /proc/swaps 2>/dev/null; then
        swapoff "$SWAP_FILE" || true
    fi
    swap_make "$SWAP_FILE" "$target" || return 1
    if ! grep -qE "^${SWAP_FILE}[[:space:]]" /etc/fstab; then
        echo "${SWAP_FILE} none swap sw 0 0" >>/etc/fstab
    fi
    if ! grep -qs "vm.swappiness" /etc/sysctl.conf /etc/sysctl.d/*; then
        sysctl -q vm.swappiness=10 && echo 'vm.swappiness=10' >/etc/sysctl.d/99-spartan-swappiness.conf
    fi
    echo "Swap enabled: $(swap_total_mb) MB."
}

# swap_temp_on <needed MB> - temporary swap for the frontend build.
swap_temp_on() {
    local mb="$1"
    SWAP_TEMP_ACTIVE=0
    in_container && { echo "Container: cannot add temporary swap."; return 1; }
    grep -q "^${SWAP_TEMP_FILE} " /proc/swaps 2>/dev/null && { SWAP_TEMP_ACTIVE=1; return 0; }
    local free
    free="$(free_mb /)"
    if ((free < mb + 1024)); then
        echo "Not enough free disk space for ${mb} MB of temporary swap."
        return 1
    fi
    if swap_make "$SWAP_TEMP_FILE" "$mb"; then
        SWAP_TEMP_ACTIVE=1
        echo "Temporary swap of ${mb} MB enabled."
        return 0
    fi
    rm -f "$SWAP_TEMP_FILE"
    return 1
}

swap_temp_off() {
    ((SWAP_TEMP_ACTIVE)) || [[ -f "$SWAP_TEMP_FILE" ]] || return 0
    swapoff "$SWAP_TEMP_FILE" 2>/dev/null
    rm -f "$SWAP_TEMP_FILE"
    SWAP_TEMP_ACTIVE=0
    return 0
}
