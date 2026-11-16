#!/bin/sh

FORCE_MODE="$1"

if [ "$FORCE_MODE" != "--force" ]; then
    printf "Remove Mihomo, routing rules, peer_router, VPN client profile and all installer files? (y/n): "
    read -r ans
    case "$ans" in
        y|Y|yes|YES|д|Д) ;;
        *)
            echo "Aborted."
            exit 0
            ;;
    esac
fi

echo "[1/5] Stopping and disabling Mihomo service..."
if [ -f /etc/init.d/mihomo ]; then
    /etc/init.d/mihomo stop 2>/dev/null
    /etc/init.d/mihomo disable 2>/dev/null
    rm -f /etc/init.d/mihomo
fi
killall mihomo 2>/dev/null

echo "[2/5] Cleaning routing rules and tables..."
ip rule del iif wgserver lookup 200 2>/dev/null
ip route del 10.1.1.2/32 dev wgserver 2>/dev/null
ip route del 10.1.1.2/32 dev wgserver table 9910 2>/dev/null
ip route flush table 200 2>/dev/null

echo "[3/5] Cleaning firewall rules and sysctl..."
if [ -f /etc/firewall.user ]; then
    sed -i '/# BEGIN AWG_SUB_RULES/,/# END AWG_SUB_RULES/d' /etc/firewall.user
fi

iptables -D FORWARD -i wgserver -o utun -j ACCEPT 2>/dev/null
iptables -D FORWARD -i utun -o wgserver -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
iptables -D FORWARD -i utun -o wgserver -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
iptables -t nat -D PREROUTING -i wgserver -p udp --dport 53 -j REDIRECT --to-ports 1053 2>/dev/null
iptables -t nat -D PREROUTING -i wgserver -p tcp --dport 53 -j REDIRECT --to-ports 1053 2>/dev/null
iptables -t nat -D POSTROUTING -o utun -j MASQUERADE 2>/dev/null
iptables -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null

if [ -f /etc/sysctl.conf ]; then
    sed -i '/# BEGIN AWG_SUB_SYSCTL/,/# END AWG_SUB_SYSCTL/d' /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
fi

echo "[4/5] Removing peer_router and VPN Client profile..."
AWG_BIN=$(command -v awg || command -v wg)
PEER_PUB=$(uci -q get wireguard_server.peer_router.public_key)
if [ -n "$AWG_BIN" ] && [ -n "$PEER_PUB" ]; then
    $AWG_BIN set wgserver peer "$PEER_PUB" remove 2>/dev/null
fi
if uci -q get wireguard_server.peer_router >/dev/null 2>&1; then
    uci delete wireguard_server.peer_router
    uci commit wireguard_server
fi

uci -q delete wireguard.peer_9901
uci -q delete wireguard.group_9901
uci -q delete wireguard.awg2sub_peer
uci -q delete wireguard.awg2sub
uci commit wireguard 2>/dev/null

echo "[5/5] Removing files and /etc/sysupgrade.conf entries..."
rm -rf /etc/mihomo /usr/bin/mihomo /root/router-local.conf

if [ -f /etc/sysupgrade.conf ]; then
    for item in \
        "/root/setup_awg_sub.sh" \
        "/root/uninstall_awg_sub.sh" \
        "/root/router-local.conf" \
        "/etc/mihomo" \
        "/etc/init.d/mihomo" \
        "/etc/firewall.user" \
        "/etc/sysctl.conf" \
        "/usr/bin/mihomo"
    do
        sed -i "\|^${item}$|d" /etc/sysupgrade.conf
    done
fi

rm -f /root/setup_awg_sub.sh /root/uninstall_awg_sub.sh

echo "DONE! All awg2sub components have been cleanly removed."