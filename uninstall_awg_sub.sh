#!/bin/sh
# =============================================================================
# uninstall_awg_sub.sh — полный откат setup_awg_sub.sh
#
# Удаляет всё, что добавил installer:
#   - Mihomo (бинарник, конфиг, init-скрипт, WebUI)
#   - peer_router, peer_9901, group_9901 (WireGuard-профиль в морде)
#   - UCI: network.utun / awg_sub_*, firewall.utun / awg_sub_*
#   - sysctl-блок AWG_SUB_SYSCTL
#   - legacy: /etc/firewall.user AWG_SUB_RULES, hotplug 99-awg-sub-restore
#   - kernel: ip rules/routes/iptables/utun
#
# НЕ трогает: GL.iNet штатное — wgserver, wgclient1, awg1, wgclient2,
#             iptables LOCAL_POLICY / VPN_PREROUTING_HOOK / TUNNEL*,
#             ipset, fwmark-правила 0x8000, таблицы 9910/1001/1002/16800.
#
# Usage: sh uninstall_awg_sub.sh [--yes] [--full] [--help]
#   --yes,  -y   без вопросов (для automation)
#   --full       также удалить wireguard_server.main_server (stock WG-сервер)
#   --help, -h   справка
# =============================================================================

YES=0
FULL=0
for arg in "$@"; do
    case "$arg" in
        --yes|-y)  YES=1 ;;
        --full)    FULL=1 ;;
        --help|-h)
            sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
    esac
done

ask() {
    if [ "$YES" = "1" ]; then return 0; fi
    printf "%s (y/N): " "$1"
    read -r ans
    case "$ans" in
        y|Y|yes|YES|д|Д) return 0 ;;
        *) return 1 ;;
    esac
}

# =============================================================================
echo "=========================================================="
echo "  ROLLBACK: AmneziaWG + Mihomo + peer_router"
echo "=========================================================="
echo ""
echo "WILL REMOVE:"
echo "  files:  /usr/bin/mihomo, /etc/mihomo/, /etc/init.d/mihomo"
echo "          /root/router-local.conf"
echo "  UCI:    network.utun, network.awg_sub_*"
echo "          firewall.utun, firewall.awg_sub_*"
echo "          wireguard_server.peer_router"
echo "          wireguard.peer_9901, wireguard.group_9901"
echo "  legacy: /etc/firewall.user AWG_SUB_RULES block"
echo "          /etc/hotplug.d/iface/99-awg-sub-restore"
echo "  sysctl: block AWG_SUB_SYSCTL"
echo "  kernel: ip rules iif wgserver → 200, routes table 200,"
echo "          utun interface, iptables RETURN/REDIRECT/MASQUERADE for wgserver↔utun"
[ "$FULL" = "1" ] && echo "  FULL:   wireguard_server.main_server + network.wgserver + firewall.wgserver*"
echo ""
echo "WILL KEEP (GL.iNet stock):"
echo "  wgserver, wgclient1, wgclient2, awg1"
echo "  LOCAL_POLICY / VPN_PREROUTING_HOOK / TUNNEL* / ipset / fwmark 0x8000"
echo "  таблицы 9910 / 1001 / 1002 / 16800"
echo "=========================================================="
echo ""

if ! ask "Proceed with rollback?"; then echo "Aborted."; exit 0; fi

# =============================================================================
# 0. Бэкап текущего состояния в /tmp (перед изменениями)
# =============================================================================
echo "[0/8] Backing up current state to /tmp/awg_uninstall_backup/..."
BK="/tmp/awg_uninstall_backup"
mkdir -p "$BK"
ip rule show    > "$BK/ip_rule.txt"   2>/dev/null
ip route show   > "$BK/ip_route.txt"  2>/dev/null
ip route show table 200 > "$BK/rt200.txt" 2>/dev/null
iptables-save   > "$BK/iptables.txt"  2>/dev/null
ip6tables-save  > "$BK/ip6tables.txt" 2>/dev/null
uci export network          > "$BK/uci_network.txt"          2>/dev/null
uci export firewall         > "$BK/uci_firewall.txt"         2>/dev/null
uci export wireguard        > "$BK/uci_wireguard.txt"        2>/dev/null
uci export wireguard_server > "$BK/uci_wireguard_server.txt" 2>/dev/null
[ -f /etc/sysctl.conf ]        && cp /etc/sysctl.conf        "$BK/" 2>/dev/null
[ -f /etc/sysupgrade.conf ]    && cp /etc/sysupgrade.conf    "$BK/" 2>/dev/null
[ -f /etc/firewall.user ]      && cp /etc/firewall.user      "$BK/" 2>/dev/null
echo "  backup dir: $BK"

# =============================================================================
# 1. Останавливаем и убиваем Mihomo
# =============================================================================
echo "[1/8] Stopping Mihomo..."
if [ -x /etc/init.d/mihomo ]; then
    /etc/init.d/mihomo stop 2>/dev/null
    /etc/init.d/mihomo disable 2>/dev/null
fi
pkill -x mihomo 2>/dev/null
sleep 1
pkill -9 -x mihomo 2>/dev/null
# Убедиться что процесс мёртв
if pgrep -x mihomo >/dev/null 2>&1; then
    echo "  WARNING: mihomo still running, sending SIGKILL..."
    kill -9 $(pgrep -x mihomo) 2>/dev/null
    sleep 1
fi
echo "  mihomo stopped"

# =============================================================================
# 2. Удаляем файлы Mihomo
# =============================================================================
echo "[2/8] Removing Mihomo files..."
rm -f /etc/init.d/mihomo
rm -f /usr/bin/mihomo
rm -rf /etc/mihomo
rm -f /root/router-local.conf
# Подчистим возможные временные
rm -f /tmp/mihomo /tmp/mihomo.gz /tmp/ui.tgz
echo "  done"

# =============================================================================
# 3. Удаляем legacy-артефакты (firewall.user + hotplug)
# =============================================================================
echo "[3/8] Removing legacy artifacts..."
if [ -f /etc/firewall.user ]; then
    sed -i '/# BEGIN AWG_SUB_RULES/,/# END AWG_SUB_RULES/d' /etc/firewall.user
    echo "  - firewall.user AWG_SUB_RULES block"
fi
if [ -f /etc/hotplug.d/iface/99-awg-sub-restore ]; then
    rm -f /etc/hotplug.d/iface/99-awg-sub-restore
    echo "  - hotplug 99-awg-sub-restore"
fi

# =============================================================================
# 4. Удаляем sysctl-блок
# =============================================================================
echo "[4/8] Removing sysctl block..."
if [ -f /etc/sysctl.conf ] && grep -q "# BEGIN AWG_SUB_SYSCTL" /etc/sysctl.conf 2>/dev/null; then
    sed -i '/# BEGIN AWG_SUB_SYSCTL/,/# END AWG_SUB_SYSCTL/d' /etc/sysctl.conf
    sysctl -p /etc/sysctl.conf >/dev/null 2>&1
    echo "  - AWG_SUB_SYSCTL block removed"
fi
# Восстанавливаем rp_filter/accept_local на wgserver в default
sysctl -w net.ipv4.conf.wgserver.rp_filter=1 >/dev/null 2>&1
sysctl -w net.ipv4.conf.wgserver.accept_local=0 >/dev/null 2>&1

# =============================================================================
# 5. Удаляем UCI: network
# =============================================================================
echo "[5/8] Removing UCI network sections..."
for s in \
    utun \
    awg_sub_rt_peer \
    awg_sub_rt_peer_9910 \
    awg_sub_rt_peer_200 \
    awg_sub_rt_utun \
    awg_sub_rule_iif \
    awg_sub_rule_mark
do
    if uci -q get "network.$s" >/dev/null 2>&1; then
        uci -q delete "network.$s"
        echo "  - network.$s"
    fi
done

# network.wgserver — НЕ трогаем (stock GL.iNet), кроме --full

# =============================================================================
# 6. Удаляем UCI: firewall
# =============================================================================
echo "[6/8] Removing UCI firewall sections..."
for s in \
    utun \
    awg_sub_fwd_wan \
    awg_sub_fwd_utun \
    awg_sub_fwd_ret \
    awg_sub_mangle_pre \
    awg_sub_mangle_out \
    awg_sub_mss \
    awg_sub_dns_udp \
    awg_sub_dns_tcp
do
    if uci -q get "firewall.$s" >/dev/null 2>&1; then
        uci -q delete "firewall.$s"
        echo "  - firewall.$s"
    fi
done

# =============================================================================
# 7. Удаляем WireGuard-профиль и peer_router
# =============================================================================
echo "[7/8] Removing wireguard client profile & peer_router..."
for s in peer_9901 group_9901; do
    if uci -q get "wireguard.$s" >/dev/null 2>&1; then
        uci -q delete "wireguard.$s"
        echo "  - wireguard.$s"
    fi
done
if uci -q get wireguard_server.peer_router >/dev/null 2>&1; then
    uci -q delete wireguard_server.peer_router
    echo "  - wireguard_server.peer_router"
fi

if [ "$FULL" = "1" ]; then
    echo ""
    echo "  --full: также удаляем stock WG-сервер?"
    if ask "  Remove wireguard_server.main_server + network.wgserver + firewall.wgserver*?"; then
        for s in main_server; do
            if uci -q get "wireguard_server.$s" >/dev/null 2>&1; then
                uci -q delete "wireguard_server.$s"
                echo "  - wireguard_server.$s"
            fi
        done
        for s in wgserver; do
            if uci -q get "network.$s" >/dev/null 2>&1; then
                uci -q delete "network.$s"
                echo "  - network.$s"
            fi
        done
        for s in wgserver wgserver_allow wgserver2wan wgserver2lan; do
            if uci -q get "firewall.$s" >/dev/null 2>&1; then
                uci -q delete "firewall.$s"
                echo "  - firewall.$s"
            fi
        done
    fi
fi

uci commit network
uci commit firewall
uci commit wireguard
uci commit wireguard_server

# =============================================================================
# 8. Чистим /etc/sysupgrade.conf
# =============================================================================
echo "[8/8] Cleaning /etc/sysupgrade.conf..."
if [ -f /etc/sysupgrade.conf ]; then
    for item in \
        "/root/router-local.conf" \
        "/etc/mihomo" \
        "/etc/init.d/mihomo" \
        "/etc/sysctl.conf" \
        "/usr/bin/mihomo" \
        "/etc/firewall.user" \
        "/etc/hotplug.d/iface/99-awg-sub-restore"
    do
        # экранируем '/' в sed-разделителе через '|'
        sed -i "\|^${item}$|d" /etc/sysupgrade.conf 2>/dev/null
    done
    echo "  done"
fi

# =============================================================================
# Kernel cleanup — вычищаем то, что старое (hotplug/firewall.user) могло оставить,
# и что не удалится через перезапуск сервисов
# =============================================================================
echo ""
echo "Cleaning kernel state (ip rules/routes/iptables/utun)..."

# --- ip rules (только наши) ---
# iif wgserver → 200 — наш
while ip rule show | grep -q "from all iif wgserver lookup 200"; do
    ip rule del iif wgserver lookup 200 2>/dev/null || break
done

# fwmark 0x8000 — НЕ трогаем, это GL.iNet-территория (приоритет 10/40/6000)

# --- routes ---
ip route del 10.1.1.2/32 dev wgserver table 200 2>/dev/null
ip route del default dev utun table 200 2>/dev/null
ip route del 10.1.1.2/32 dev wgserver table 9910 2>/dev/null
ip route del 10.1.1.2/32 dev wgserver 2>/dev/null

# --- iptables: legacy leftovers от /etc/firewall.user (while -C защищает от повторов) ---
clean_rule() {
    tbl="$1"; chain="$2"; shift 2
    while iptables -t "$tbl" -C "$chain" "$@" 2>/dev/null; do
        iptables -t "$tbl" -D "$chain" "$@" 2>/dev/null || break
    done
}

clean_rule mangle OUTPUT -o wgserver -j RETURN
clean_rule mangle PREROUTING -i wgserver -j RETURN
clean_rule filter FORWARD -i wgserver -o utun -j ACCEPT
clean_rule filter FORWARD -i utun -o wgserver -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
clean_rule nat PREROUTING -i wgserver -p udp --dport 53 -j REDIRECT --to-ports 1053
clean_rule nat PREROUTING -i wgserver -p tcp --dport 53 -j REDIRECT --to-ports 1053
clean_rule nat POSTROUTING -o utun -j MASQUERADE

# --- utun (мог остаться, если mihomo был убит SIGKILL) ---
if ip link show utun >/dev/null 2>&1; then
    ip link set utun down 2>/dev/null
    ip link del utun 2>/dev/null && echo "  - utun interface removed"
fi

# =============================================================================
# Финальный reload
# =============================================================================
echo ""
echo "Reloading network and firewall..."
/etc/init.d/network restart
sleep 2
/etc/init.d/firewall reload

# =============================================================================
# Финальная проверка — что осталось, что ушло
# =============================================================================
echo ""
echo "=========================================================="
echo "  VERIFY (should all be empty):"
echo "=========================================================="

check_empty() {
    out=$(eval "$1" 2>/dev/null)
    if [ -z "$out" ]; then
        echo "  OK   $2"
    else
        echo "  WARN $2"
        echo "$out" | sed 's/^/       /'
    fi
}
check_empty "ip rule show | grep 'iif wgserver'"        "no 'iif wgserver' ip rule"
check_empty "ip route show table 200 | grep -v '^$'"    "table 200 empty"
check_empty "ip link show utun 2>/dev/null"             "utun interface gone"
check_empty "pgrep -x mihomo"                           "no mihomo process"
check_empty "ls /etc/mihomo 2>/dev/null"                "/etc/mihomo removed"
check_empty "ls /usr/bin/mihomo 2>/dev/null"            "/usr/bin/mihomo removed"
check_empty "uci -q show network | grep awg_sub"        "no network.awg_sub_*"
check_empty "uci -q show firewall | grep awg_sub"       "no firewall.awg_sub_*"
check_empty "uci -q get wireguard.peer_9901"            "no wireguard.peer_9901"
check_empty "uci -q get wireguard_server.peer_router"   "no wireguard_server.peer_router"
check_empty "iptables -t mangle -S | grep 'o wgserver.*RETURN'" "no legacy mangle OUTPUT RETURN"
check_empty "iptables -t mangle -S | grep 'i wgserver.*RETURN'" "no legacy mangle PREROUTING RETURN"
check_empty "iptables -t nat -S | grep 'to-ports 1053'"         "no legacy dns redirect"
check_empty "iptables -t nat -S | grep 'o utun.*MASQUERADE'"    "no legacy utun MASQUERADE"

echo ""
echo "=========================================================="
echo "  Rollback complete."
echo "=========================================================="
echo ""
echo "Stock GL.iNet VPN Dashboard + wgserver still work as before."
echo "Backup of pre-uninstall state: /tmp/awg_uninstall_backup/"
echo ""
echo "If you need to restore the WG server (--full was used):"
echo "  GL.iNet Admin Panel → VPN → WireGuard Server → start it again"