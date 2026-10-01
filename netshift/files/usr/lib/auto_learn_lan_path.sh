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
    ip netns del "$AUTO_LEARN_PROBE_NETNS" 2>/dev/null
    ip link del "$AUTO_LEARN_PROBE_VETH_LAN" 2>/dev/null
    auto_learn_lan_path_fw_remove
    rm -f "$AUTO_LEARN_LAN_PATH_READY_FILE"
}

auto_learn_lan_path_setup() {
    local br gw ip host="$AUTO_LEARN_PROBE_VETH_HOST" lan="$AUTO_LEARN_PROBE_VETH_LAN"
    local ns="$AUTO_LEARN_PROBE_NETNS"

    if ! auto_learn_lan_path_veth_supported; then
        log "Auto-learn: kmod-veth missing; install kmod-veth for LAN-forward TLS probes" "warn"
        return 1
    fi

    auto_learn_lan_path_teardown

    br="$(auto_learn_get_probe_lan_bridge)"
    gw="$(auto_learn_get_probe_lan_gateway)"
    ip="$(auto_learn_get_probe_lan_ip)"

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

    if ! ip netns exec "$ns" ip link set "$host" up \
        || ! ip netns exec "$ns" ip addr add "${ip}/24" dev "$host" \
        || ! ip netns exec "$ns" ip route add default via "$gw" \
        || ! ip netns exec "$ns" sh -c "printf 'nameserver %s\n' '$gw' > /etc/resolv.conf"; then
        auto_learn_lan_path_teardown
        log "Auto-learn: failed to configure LAN probe namespace" "error"
        return 1
    fi

    auto_learn_lan_path_fw_allow
    : > "$AUTO_LEARN_LAN_PATH_READY_FILE"
    log "Auto-learn: LAN-forward probe path ready ($ip via $gw on $br)" "debug"
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
