firewall_kind() {
    if have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
        echo "firewalld"
    elif have ufw && ufw status 2>/dev/null | grep -qi '^Status: active'; then
        echo "ufw"
    fi
}

firewall_open_web() {
    case "$(firewall_kind)" in
        firewalld)
            firewall-cmd --permanent --add-service=http --add-service=https &&
                firewall-cmd --reload
            ;;
        ufw)
            ufw allow 80/tcp && ufw allow 443/tcp
            ;;
        *) echo "No active firewall (firewalld/ufw) found, nothing to open." ;;
    esac
}
