# shellcheck shell=ash
# LAN-forward TLS probe path via veth + network namespace (router-only).

auto_learn_lan_path_veth_supported() {
    local cached t0 t1

    if [ -f "$AUTO_LEARN_VETH_CACHE_FILE" ]; then
        cached="$(cat "$AUTO_LEARN_VETH_CACHE_FILE" 2>/dev/null)"
        [ "$cached" = "1" ]
        return $?
    fi

    if [ -d /sys/module/veth ]; then
        echo 1 > "$AUTO_LEARN_VETH_CACHE_FILE"
        return 0
    fi

    t0="${AUTO_LEARN_PROBE_VETH_HOST}.test"
    t1="${AUTO_LEARN_PROBE_VETH_LAN}.test"
    if ip link add "$t0" type veth peer name "$t1" 2>/dev/null; then
        ip link del "$t0" 2>/dev/null
        echo 1 > "$AUTO_LEARN_VETH_CACHE_FILE"
        return 0
    fi
    echo 0 > "$AUTO_LEARN_VETH_CACHE_FILE"
    return 1
}

auto_learn_get_probe_lan_gateway() {
    local gw

    config_load network
    config_get gw lan ipaddr "192.168.1.1"
    echo "$gw"
}

auto_learn_get_probe_lan_bridge() {
    local br

    config_load network
    config_get br lan device "br-lan"
    echo "$br"
}

auto_learn_get_probe_lan_ip() {
    local ip

    config_get ip "auto_learn" "probe_lan_ip" ""
    [ -n "$ip" ] || ip="$AUTO_LEARN_PROBE_LAN_IP_DEFAULT"
    echo "$ip"
}

auto_learn_get_probe_dns_mode() {
    local mode

    config_get mode "auto_learn" "probe_dns_mode" "dhcp"
    case "$mode" in
    dhcp | gateway | custom) echo "$mode" ;;
    *) echo "dhcp" ;;
    esac
}

auto_learn_get_probe_dns_custom() {
    local servers

    config_get servers "auto_learn" "probe_dns_servers" ""
    echo "$servers"
}

auto_learn_lan_path_write_resolv() {
    local ns="$1" gw="$2" mode="$3" custom="$4" s

    case "$mode" in
    custom)
        ip netns exec "$ns" sh -c ': > /etc/resolv.conf'
        for s in $custom; do
            [ -n "$s" ] || continue
            ip netns exec "$ns" sh -c "echo 'nameserver $s' >> /etc/resolv.conf"
        done
        ip netns exec "$ns" test -s /etc/resolv.conf
        return $?
        ;;
    gateway)
        ip netns exec "$ns" sh -c "printf 'nameserver %s\n' '$gw' > /etc/resolv.conf"
        return 0
        ;;
    esac
    return 1
}

auto_learn_lan_path_dhcp_in_netns() {
    local ns="$1" host="$2" req_ip="$3"
    local script="$AUTO_LEARN_UDHCPC_SCRIPT"

    [ -r "$script" ] || return 1

    ip netns exec "$ns" ip link set "$host" up 2>/dev/null || return 1

    if command -v udhcpc >/dev/null 2>&1; then
        ip netns exec "$ns" udhcpc -i "$host" -n -q -t 5 -T 2 -r "$req_ip" -s "$script" 2>/dev/null
        ip netns exec "$ns" test -s /etc/resolv.conf
        return $?
    fi

    return 1
}

auto_learn_lan_path_fw_allow() {
    if ! nft list table inet fw4 >/dev/null 2>&1; then
        return 0
    fi
    if nft list chain inet fw4 forward_lan 2>/dev/null | grep -q 'netshift-probe'; then
        return 0
    fi
    nft insert rule inet fw4 forward_lan \
        iifname "$AUTO_LEARN_PROBE_VETH_LAN" accept comment \"netshift-probe\" 2>/dev/null || true
}

auto_learn_lan_path_fw_remove() {
    local line handle

    if ! nft list table inet fw4 >/dev/null 2>&1; then
        return 0
    fi
    line="$(nft -a list chain inet fw4 forward_lan 2>/dev/null | grep 'netshift-probe' | head -1)" || return 0
    handle="${line##*handle }"
    [ -n "$handle" ] || return 0
    nft delete rule inet fw4 forward_lan handle "$handle" 2>/dev/null || true
}

auto_learn_lan_path_teardown() {
    local ns="$AUTO_LEARN_PROBE_NETNS"

    if ip netns list 2>/dev/null | grep -q "^${ns} "; then
        ip netns exec "$ns" killall udhcpc 2>/dev/null || true
    fi
    ip netns del "$ns" 2>/dev/null
    ip link del "$AUTO_LEARN_PROBE_VETH_LAN" 2>/dev/null
    auto_learn_lan_path_fw_remove
    rm -f "$AUTO_LEARN_LAN_PATH_READY_FILE"
}

auto_learn_lan_path_setup() {
    local br gw ip host="$AUTO_LEARN_PROBE_VETH_HOST" lan="$AUTO_LEARN_PROBE_VETH_LAN"
    local ns="$AUTO_LEARN_PROBE_NETNS" dns_mode dns_custom

    if ! auto_learn_lan_path_veth_supported; then
        log "Auto-learn: kmod-veth missing; install kmod-veth for LAN-forward TLS probes" "warn"
        return 1
    fi

    auto_learn_lan_path_teardown

    br="$(auto_learn_get_probe_lan_bridge)"
    gw="$(auto_learn_get_probe_lan_gateway)"
    ip="$(auto_learn_get_probe_lan_ip)"
    dns_mode="$(auto_learn_get_probe_dns_mode)"
    dns_custom="$(auto_learn_get_probe_dns_custom)"

    if ! ip link add "$host" type veth peer name "$lan"; then
        log "Auto-learn: failed to create veth pair for LAN probe" "error"
        return 1
    fi

    if ! ip link set "$lan" master "$br" 2>/dev/null; then
        ip link del "$host" 2>/dev/null
        log "Auto-learn: failed to attach $lan to $br" "error"
        return 1
    fi
    ip link set "$lan" up

    if ! ip netns add "$ns"; then
        ip link del "$host" 2>/dev/null
        log "Auto-learn: failed to create network namespace $ns" "error"
        return 1
    fi

    if ! ip link set "$host" netns "$ns"; then
        auto_learn_lan_path_teardown
        return 1
    fi

    if [ "$dns_mode" = "dhcp" ]; then
        if auto_learn_lan_path_dhcp_in_netns "$ns" "$host" "$ip"; then
            auto_learn_lan_path_fw_allow
            : > "$AUTO_LEARN_LAN_PATH_READY_FILE"
            log "Auto-learn: LAN probe ready (DHCP DNS, requested $ip on $br)" "debug"
            return 0
        fi
        log "Auto-learn: DHCP on probe veth failed; falling back to static IP + router DNS" "warn"
        dns_mode="gateway"
    fi

    if ! ip netns exec "$ns" ip link set "$host" up \
        || ! ip netns exec "$ns" ip addr add "${ip}/24" dev "$host" \
        || ! ip netns exec "$ns" ip route add default via "$gw"; then
        auto_learn_lan_path_teardown
        log "Auto-learn: failed to configure LAN probe namespace" "error"
        return 1
    fi

    if ! auto_learn_lan_path_write_resolv "$ns" "$gw" "$dns_mode" "$dns_custom"; then
        auto_learn_lan_path_teardown
        log "Auto-learn: failed to set probe DNS (mode=$dns_mode)" "error"
        return 1
    fi

    auto_learn_lan_path_fw_allow
    : > "$AUTO_LEARN_LAN_PATH_READY_FILE"
    log "Auto-learn: LAN-forward probe path ready ($ip via $gw on $br, dns=$dns_mode)" "debug"
    return 0
}

auto_learn_lan_path_ensure() {
    if [ -f "$AUTO_LEARN_LAN_PATH_READY_FILE" ] \
        && ip netns list 2>/dev/null | grep -q "^${AUTO_LEARN_PROBE_NETNS} "; then
        return 0
    fi
    auto_learn_lan_path_setup
}

auto_learn_lan_path_available() {
    auto_learn_lan_path_veth_supported
}

# TLS probe from a synthetic LAN client (FORWARD + dnsmasq + Zapret path).
auto_learn_probe_tls_lan_forward() {
    local domain="$1" rc ns="$AUTO_LEARN_PROBE_NETNS" host="$AUTO_LEARN_PROBE_VETH_HOST"

    domain="$(auto_learn_normalize_domain "$domain")"
    auto_learn_lan_path_ensure || return 1

    ip netns exec "$ns" curl -4 -m "$AUTO_LEARN_LAN_PROBE_TIMEOUT" --connect-timeout 4 \
        --max-redirs 0 -sS --head \
        --interface "$host" \
        -o /dev/null "https://${domain}/" 2>/dev/null
    rc=$?
    auto_learn_curl_tls_handshake_ok "$rc"
}
