#!/bin/sh
# Zapret custom.d script: static exclude seed + NetShift auto-learn API.
# Installed copy: /usr/lib/netshift/zapret/90-script.sh
# Deploy to router: /opt/zapret/init.d/openwrt/custom.d/90-script.sh

TARGET="/opt/zapret/ipset/zapret-hosts-user-exclude.txt"
NETSHIFT_AUTO="/opt/zapret/ipset/zapret-hosts-netshift-auto-exclude.txt"

HOSTS="auth.uis.kaspersky.com
i2hard.ru
download.kaspersky.com
paysecurepayment.com
snapit.pro
snapit.ru
runpod.io
raskrasil.com
railway.com
voxin.tech
gorzdrav.org
website-files.com
ks-auto.ru
vk.ru
unity.com
api.unity.com
guru3d.com
penpot.app
gosuslugi.ru"

_seed_static_hosts() {
    [ -f "$TARGET" ] || touch "$TARGET"
    for host in $HOSTS; do
        [ -z "$host" ] && continue
        if ! grep -qxF "$host" "$TARGET" 2>/dev/null; then
            echo "$host" >> "$TARGET"
            logger -t zapret "added $host to exclude list (static seed)"
        fi
    done
}

zapret_netshift_add_exclude() {
    local domain="$1"

    [ -n "$domain" ] || return 1
    [ -f "$TARGET" ] || touch "$TARGET"
    if grep -qxF "$domain" "$TARGET" 2>/dev/null; then
        return 0
    fi
    echo "$domain" >> "$TARGET"
    [ -f "$NETSHIFT_AUTO" ] || touch "$NETSHIFT_AUTO"
    if ! grep -qxF "$domain" "$NETSHIFT_AUTO" 2>/dev/null; then
        echo "$domain" >> "$NETSHIFT_AUTO"
    fi
    logger -t zapret/netshift "excluded $domain from v10 desync"
}

zapret_netshift_remove_exclude() {
    local domain="$1"
    local tmp

    [ -n "$domain" ] || return 1
    tmp="$(mktemp)"
    if [ -f "$TARGET" ]; then
        grep -vxF "$domain" "$TARGET" > "$tmp" 2>/dev/null || true
        mv "$tmp" "$TARGET"
    fi
    tmp="$(mktemp)"
    if [ -f "$NETSHIFT_AUTO" ]; then
        grep -vxF "$domain" "$NETSHIFT_AUTO" > "$tmp" 2>/dev/null || true
        mv "$tmp" "$NETSHIFT_AUTO"
    fi
}

zapret_netshift_is_excluded() {
    local domain="$1"

    [ -n "$domain" ] && grep -qxF "$domain" "$TARGET" 2>/dev/null
}

zapret_netshift_apply() {
    if [ -x /etc/init.d/zapret ]; then
        /etc/init.d/zapret reload > /dev/null 2>&1
    fi
}

case "$1" in
add-exclude)
    zapret_netshift_add_exclude "$2"
    zapret_netshift_apply
    ;;
add-exclude-quiet)
    zapret_netshift_add_exclude "$2"
    ;;
remove-exclude)
    zapret_netshift_remove_exclude "$2"
    zapret_netshift_apply
    ;;
remove-exclude-quiet)
    zapret_netshift_remove_exclude "$2"
    ;;
is-excluded)
    if zapret_netshift_is_excluded "$2"; then
        exit 0
    fi
    exit 1
    ;;
seed)
    _seed_static_hosts
    ;;
'')
    _seed_static_hosts
    ;;
*)
    _seed_static_hosts
    ;;
esac
