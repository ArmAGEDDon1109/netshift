#!/bin/sh
# udhcpc script for auto-learn synthetic LAN client (runs inside netns).
# Receives DNS (and default route) from dnsmasq like a real DHCP client.

[ -n "$1" ] || exit 1

case "$1" in
bound | renew)
    [ -n "$ip" ] && ip addr flush dev "$interface" 2>/dev/null
    if [ -n "$ip" ]; then
        if [ -n "$subnet" ]; then
            ip addr add "$ip/$subnet" dev "$interface" 2>/dev/null
        elif [ -n "$mask" ]; then
            ip addr add "$ip/$mask" broadcast "${broadcast:-+}" dev "$interface" 2>/dev/null
        fi
    fi
    ip link set "$interface" up 2>/dev/null

    ip route flush dev "$interface" 2>/dev/null || true
    if [ -n "$router" ]; then
        ip route add default via "$router" dev "$interface" 2>/dev/null || true
    fi

    : > /etc/resolv.conf
    for ns in $dns; do
        [ -n "$ns" ] && echo "nameserver $ns" >> /etc/resolv.conf
    done
    if [ ! -s /etc/resolv.conf ] && [ -n "$router" ]; then
        echo "nameserver $router" >> /etc/resolv.conf
    fi
    ;;
deconfig)
    ip addr flush dev "$interface" 2>/dev/null || true
    ;;
esac

exit 0
