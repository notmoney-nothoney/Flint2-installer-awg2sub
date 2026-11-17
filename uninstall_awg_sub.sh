#!/bin/sh
# =============================================================================
# uninstall_awg_sub.sh — Полное удаление всех компонентов awg2sub
# Удаляет: Mihomo, UCI firewall/network секции, hotplug, routing, peer_router
# =============================================================================

FORCE_MODE="$1"

if [ "$FORCE_MODE" != "--force" ]; then
    printf "Remove Mihomo, UCI rules, routing, peer_router, VPN client profile and all installer files? (y/n): "
    read -r ans
    case "$ans" in
        y|Y|yes|YES|д|Д) ;;
        *)
            echo "Aborted."
            exit 0
            ;;
    esac
fi

# =============================================================================
echo "[1/7] Stopping and disabling Mihomo service..."
# =============================================================================
if [ -f /etc/init.d/mihomo ]; then
    /etc/init.d/mihomo stop 2>/dev/null
    /etc/init.d/mihomo disable 2>/dev/null
    rm -f /etc/init.d/mihomo
fi
killall mihomo 2>/dev/null

# =============================================================================
echo "[2/7] Cleaning ip rules and routing tables..."
# =============================================================================
# Удаляем fwmark правило для Mihomo (исключение из петли)
ip rule del fwmark 32768 2>/dev/null

# Удаляем правило iif wgserver → таблица 200
ip rule del iif wgserver lookup 200 2>/dev/null

# Удаляем маршруты для peer_router
ip route del 10.1.1.2/32 dev wgserver 2>/dev/null
ip route del 10.1.1.2/32 dev wgserver table 9910 2>/dev/null

# Очищаем таблицу 200
ip route flush table 200 2>/dev/null

# =============================================================================
echo "[3/7] Cleaning UCI firewall rules (awg_sub_*)..."
# =============================================================================
# Удаляем именованные UCI секции firewall (GL.iNet их не трогает, но мы удаляем)
for section in awg_sub_mangle_out awg_sub_mangle_pre awg_sub_fwd awg_sub_mss awg_sub_dns_udp awg_sub_dns_tcp; do
    if uci -q get firewall.${section} >/dev/null 2>&1; then
        uci delete firewall.${section}
    fi
done
uci commit firewall 2>/dev/null

# =============================================================================
echo "[4/7] Cleaning UCI network rules (awg_sub_*)..."
# =============================================================================
for section in awg_sub_rt awg_sub_rule; do
    if uci -q get network.${section} >/dev/null 2>&1; then
        uci delete network.${section}
    fi
done
uci commit network 2>/dev/null

# =============================================================================
echo "[5/7] Cleaning firewall.user, mangle rules and sysctl..."
# =============================================================================
# Удаляем блок из /etc/firewall.user
if [ -f /etc/firewall.user ]; then
    sed -i '/# BEGIN AWG_SUB_RULES/,/# END AWG_SUB_RULES/d' /etc/firewall.user
fi

# Удаляем mangle правила (исключения wgserver из политик GL.iNet)
iptables -t mangle -D OUTPUT -o wgserver -j RETURN 2>/dev/null
iptables -t mangle -D PREROUTING -i wgserver -j RETURN 2>/dev/null

# Удаляем FORWARD правила
iptables -D FORWARD -i wgserver -o utun -j ACCEPT 2>/dev/null
iptables -D FORWARD -i utun -o wgserver -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
iptables -D FORWARD -i utun -o wgserver -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null

# Удаляем NAT правила
iptables -t nat -D PREROUTING -i wgserver -p udp --dport 53 -j REDIRECT --to-ports 1053 2>/dev/null
iptables -t nat -D PREROUTING -i wgserver -p tcp --dport 53 -j REDIRECT --to-ports 1053 2>/dev/null
iptables -t nat -D POSTROUTING -o utun -j MASQUERADE 2>/dev/null

# Удаляем MSS Fix
iptables -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null

# Удаляем блок из /etc/sysctl.conf
if [ -f /etc/sysctl.conf ]; then
    sed -i '/# BEGIN AWG_SUB_SYSCTL/,/# END AWG_SUB_SYSCTL/d' /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
fi

# =============================================================================
echo "[6/7] Removing hotplug hook and peer_router..."
# =============================================================================
# Удаляем hotplug хук (восстанавливающий правила после reload firewall)
rm -f /etc/hotplug.d/iface/99-awg-sub-restore

# Удаляем peer_router из live kernel interface
AWG_BIN=$(command -v awg || command -v wg)
PEER_PUB=$(uci -q get wireguard_server.peer_router.public_key)
if [ -n "$AWG_BIN" ] && [ -n "$PEER_PUB" ]; then
    $AWG_BIN set wgserver peer "$PEER_PUB" remove 2>/dev/null
fi

# Удаляем peer_router из UCI
if uci -q get wireguard_server.peer_router >/dev/null 2>&1; then
    uci delete wireguard_server.peer_router
    uci commit wireguard_server
fi

# Удаляем VPN Client profile из UCI
uci -q delete wireguard.peer_9901
uci -q delete wireguard.group_9901
uci -q delete wireguard.awg2sub_peer
uci -q delete wireguard.awg2sub
uci commit wireguard 2>/dev/null

# =============================================================================
echo "[7/7] Removing files and /etc/sysupgrade.conf entries..."
# =============================================================================
# Удаляем основные файлы
rm -rf /etc/mihomo /usr/bin/mihomo /root/router-local.conf

# Удаляем записи из /etc/sysupgrade.conf
if [ -f /etc/sysupgrade.conf ]; then
    for item in \
        "/root/setup_awg_sub.sh" \
        "/root/uninstall_awg_sub.sh" \
        "/root/router-local.conf" \
        "/etc/mihomo" \
        "/etc/init.d/mihomo" \
        "/etc/firewall.user" \
        "/etc/sysctl.conf" \
        "/etc/hotplug.d/iface/99-awg-sub-restore" \
        "/usr/bin/mihomo"
    do
        sed -i "\|^${item}$|d" /etc/sysupgrade.conf
    done
fi

# Удаляем сами скрипты установки/удаления
rm -f /root/setup_awg_sub.sh /root/uninstall_awg_sub.sh

# Перезапускаем firewall и network для применения изменений
/etc/init.d/firewall reload 2>/dev/null
/etc/init.d/network restart 2>/dev/null

echo ""
echo "DONE! All awg2sub components have been cleanly removed:"
echo "  ✓ Mihomo binary and service"
echo "  ✓ UCI firewall rules (awg_sub_*)"
echo "  ✓ UCI network rules (awg_sub_*)"
echo "  ✓ Hotplug hook (99-awg-sub-restore)"
echo "  ✓ Routing rules and tables"
echo "  ✓ fwmark rule (32768)"
echo "  ✓ Mangle rules (wgserver exclusions)"
echo "  ✓ peer_router and VPN Client profile"
echo "  ✓ /etc/sysupgrade.conf entries"
echo ""
echo "Router firewall and network reloaded."