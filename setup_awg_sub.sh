#!/bin/sh
# =============================================================================
# setup_awg_sub.sh — AmneziaWG + Mihomo (Clash Meta) + штатный WG сервер GL.iNet
# Схема: ПК/ТВ → штатный WG сервер → peer_router (10.1.1.2) → utun (Mihomo) → подписка
# GL.iNet морда НЕ трогается. Все правила через UCI + hotplug.
# =============================================================================

SUB_URL="$1"
AUTO_MODE="$2"

if [ -z "$SUB_URL" ]; then
    echo "Usage: sh $0 \"<SUBSCRIPTION_URL>\" [--auto]"
    exit 1
fi

MIHOMO_DIR="/etc/mihomo"

pause_step() {
    if [ "$AUTO_MODE" != "--auto" ]; then
        printf "\n>>> [PAUSE] %s (Enter - continue, q - abort): " "$1"
        read -r ans
        if [ "$ans" = "q" ] || [ "$ans" = "Q" ]; then
            echo "Aborted."
            exit 0
        fi
    fi
}

# =============================================================================
echo "[1/6] Checking tools and Mihomo binary..."
# =============================================================================
AWG_BIN=$(command -v awg || command -v wg)
if [ -z "$AWG_BIN" ]; then
    echo "ERROR: 'awg' or 'wg' tool not found."
    exit 1
fi

if [ ! -x /usr/bin/mihomo ]; then
    echo "Downloading Mihomo for arm64..."
    URL=$(curl -s https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | grep -o '"browser_download_url": *"[^"]*mihomo-linux-arm64-v1\.[0-9.]*\.gz"' | head -n 1 | cut -d '"' -f 4)
    if [ -z "$URL" ]; then
        echo "ERROR: Could not fetch Mihomo release URL."
        exit 1
    fi
    curl -fL "$URL" -o /tmp/mihomo.gz && gunzip -f /tmp/mihomo.gz && mv /tmp/mihomo /usr/bin/mihomo && chmod +x /usr/bin/mihomo
fi

# =============================================================================
echo "[2/6] Configuring built-in GL.iNet wgserver, peer_router and VPN Client profile..."
# =============================================================================
touch /etc/config/wireguard_server

if ! uci -q get wireguard_server.main_server >/dev/null 2>&1; then
    echo "Fresh router detected: creating wireguard_server.main_server..."
    SRV_PRIV=$($AWG_BIN genkey)
    SRV_PUB=$(echo "$SRV_PRIV" | $AWG_BIN pubkey)
    uci set wireguard_server.main_server='servers'
    uci set wireguard_server.main_server.address_v4='10.1.0.1/24'
    uci set wireguard_server.main_server.port='51820'
    uci set wireguard_server.main_server.client_to_client='0'
    uci set wireguard_server.main_server.masq='1'
    uci set wireguard_server.main_server.private_key="$SRV_PRIV"
    uci set wireguard_server.main_server.public_key="$SRV_PUB"
    uci set wireguard_server.main_server.obfuscation='1'
    uci set wireguard_server.main_server.type='1'
    uci set wireguard_server.main_server.access='ACCEPT'
else
    CUR_PRIV=$(uci -q get wireguard_server.main_server.private_key)
    if [ -z "$CUR_PRIV" ]; then
        SRV_PRIV=$($AWG_BIN genkey)
        SRV_PUB=$(echo "$SRV_PRIV" | $AWG_BIN pubkey)
        uci set wireguard_server.main_server.private_key="$SRV_PRIV"
        uci set wireguard_server.main_server.public_key="$SRV_PUB"
        uci set wireguard_server.main_server.obfuscation='1'
        uci set wireguard_server.main_server.type='1'
    fi
fi

# Create or reuse dedicated local router peer (peer_router)
CLI_PRIV=$(uci -q get wireguard_server.peer_router.private_key)
CLI_PUB=$(uci -q get wireguard_server.peer_router.public_key)
if [ -z "$CLI_PRIV" ] || [ -z "$CLI_PUB" ]; then
    CLI_PRIV=$($AWG_BIN genkey)
    CLI_PUB=$(echo "$CLI_PRIV" | $AWG_BIN pubkey)
fi

uci set wireguard_server.peer_router='peers'
uci set wireguard_server.peer_router.name='router-local'
uci set wireguard_server.peer_router.peer_id='router'
uci set wireguard_server.peer_router.presharedkey_enable='0'
uci set wireguard_server.peer_router.dns='1.1.1.1'
uci set wireguard_server.peer_router.allowed_ips='0.0.0.0/0'
uci set wireguard_server.peer_router.mtu='1340'
uci set wireguard_server.peer_router.persistent_keepalive='25'
uci set wireguard_server.peer_router.public_key="$CLI_PUB"
uci set wireguard_server.peer_router.private_key="$CLI_PRIV"
uci set wireguard_server.peer_router.client_ip='10.1.1.2/32'
uci set wireguard_server.peer_router.deprecated='0'
uci commit wireguard_server

if ! uci -q get network.wgserver >/dev/null 2>&1; then
    uci set network.wgserver='interface'
    uci set network.wgserver.proto='wgserver'
    uci set network.wgserver.config='main_server'
    uci set network.wgserver.gl_vpn_server='1'
fi
uci set network.wgserver.disabled='0'
uci commit network

WGS_PORT=$(uci -q get wireguard_server.main_server.port || echo "51820")

FW_CHANGED=0
if ! uci -q get firewall.wgserver >/dev/null 2>&1; then
    uci set firewall.wgserver='zone'
    uci set firewall.wgserver.name='wgserver'
    uci set firewall.wgserver.input='ACCEPT'
    uci set firewall.wgserver.output='ACCEPT'
    uci set firewall.wgserver.network='wgserver'
    uci set firewall.wgserver.masq='1'
    uci set firewall.wgserver.mtu_fix='1'
    uci set firewall.wgserver.enabled='1'
    FW_CHANGED=1
fi
if ! uci -q get firewall.wgserver_allow >/dev/null 2>&1; then
    uci set firewall.wgserver_allow='rule'
    uci set firewall.wgserver_allow.name='wgserver_allow'
    uci set firewall.wgserver_allow.src='wan'
    uci set firewall.wgserver_allow.proto='udp'
    uci set firewall.wgserver_allow.dest_port="$WGS_PORT"
    uci set firewall.wgserver_allow.target='ACCEPT'
    uci set firewall.wgserver_allow.enabled='1'
    FW_CHANGED=1
fi
if ! uci -q get firewall.wgserver2wan >/dev/null 2>&1; then
    uci set firewall.wgserver2wan='forwarding'
    uci set firewall.wgserver2wan.name='wgserver2wan'
    uci set firewall.wgserver2wan.src='wgserver'
    uci set firewall.wgserver2wan.dest='wan'
    uci set firewall.wgserver2wan.enabled='1'
    FW_CHANGED=1
fi
if ! uci -q get firewall.wgserver2lan >/dev/null 2>&1; then
    uci set firewall.wgserver2lan='rule'
    uci set firewall.wgserver2lan.name='wgserver2lan'
    uci set firewall.wgserver2lan.src='wgserver'
    uci set firewall.wgserver2lan.dest='lan'
    uci set firewall.wgserver2lan.proto='all'
    uci set firewall.wgserver2lan.target='ACCEPT'
    uci set firewall.wgserver2lan.enabled='1'
    FW_CHANGED=1
fi

if [ "$FW_CHANGED" -eq 1 ]; then
    uci commit firewall
    /etc/init.d/firewall reload 2>/dev/null
fi

# Start wgserver only if currently DOWN
if ! ip link show wgserver >/dev/null 2>&1; then
    if [ -x /etc/init.d/wireguard_server ]; then
        /etc/init.d/wireguard_server start 2>/dev/null
    else
        ifup wgserver 2>/dev/null
    fi
    i=0
    while [ $i -lt 10 ]; do
        ip link show wgserver >/dev/null 2>&1 && break
        sleep 1
        i=$((i + 1))
    done
fi

SRV_CIDR=$(uci -q get wireguard_server.main_server.address_v4)
if [ -n "$SRV_CIDR" ] && ip link show wgserver >/dev/null 2>&1; then
    SRV_IP_ONLY=$(echo "$SRV_CIDR" | cut -d '/' -f 1)
    ip -4 addr show wgserver 2>/dev/null | grep -q "$SRV_IP_ONLY" || ip addr add "$SRV_CIDR" dev wgserver 2>/dev/null
fi

# Hot-add peer_router into live kernel interface
$AWG_BIN set wgserver peer "$CLI_PUB" allowed-ips 10.1.1.2/32 2>/dev/null

# Generate backup client config file and auto-register profile in GL.iNet VPN Client UI
SRV_PUB=$(uci -q get wireguard_server.main_server.public_key)
OBFUSCATION_LINES=$($AWG_BIN showconf wgserver 2>/dev/null | grep -iE '^(Jc|Jmin|Jmax|S1|S2|S3|S4|H1|H2|H3|H4|I1|I2|I3|I4|I5)\b')

cat << CLI > /root/router-local.conf
[Interface]
PrivateKey = $CLI_PRIV
Address = 10.1.1.2/32
DNS = 1.1.1.1
MTU = 1340
$OBFUSCATION_LINES
[Peer]
PublicKey = $SRV_PUB
Endpoint = 127.0.0.1:${WGS_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
CLI

# Add ready-to-use profile directly into /etc/config/wireguard using native GL.iNet schema
touch /etc/config/wireguard
uci -q delete wireguard.awg2sub
uci -q delete wireguard.awg2sub_peer

uci set wireguard.group_9901='groups'
uci set wireguard.group_9901.group_type='2'
uci set wireguard.group_9901.auth_type='0'
uci set wireguard.group_9901.group_name='Mihomo-Sub'

uci set wireguard.peer_9901='peers'
uci set wireguard.peer_9901.group_id='9901'
uci set wireguard.peer_9901.name='router-local'
uci set wireguard.peer_9901.address_v4='10.1.1.2/32'
uci set wireguard.peer_9901.private_key="$CLI_PRIV"
uci set wireguard.peer_9901.public_key="$SRV_PUB"
uci set wireguard.peer_9901.end_point="127.0.0.1:${WGS_PORT}"
uci set wireguard.peer_9901.allowed_ips='0.0.0.0/0'
uci set wireguard.peer_9901.dns='1.1.1.1'
uci set wireguard.peer_9901.mtu='1340'
uci set wireguard.peer_9901.persistent_keepalive='25'
uci set wireguard.peer_9901.presharedkey_enable='0'
uci set wireguard.peer_9901.local_access='0'
uci set wireguard.peer_9901.masq='1'
uci set wireguard.peer_9901.type='1'

# Copy AWG obfuscation parameters from live wgserver into the client profile
for param in jc jmin jmax s1 s2 s3 s4 h1 h2 h3 h4 i1 i2 i3 i4 i5; do
    val=$($AWG_BIN showconf wgserver 2>/dev/null | grep -i "^${param}[[:space:]]*=" | head -n 1 | cut -d '=' -f 2 | tr -d ' ')
    if [ -n "$val" ]; then
        uci set "wireguard.peer_9901.${param}=$val"
    else
        uci -q delete "wireguard.peer_9901.${param}"
    fi
done
uci commit wireguard

if ip link show wgserver >/dev/null 2>&1; then
    WGSERVER_STATUS="UP ($(ip -4 addr show wgserver 2>/dev/null | awk '/inet / {print $2}' | head -n 1), port $WGS_PORT)"
else
    WGSERVER_STATUS="DOWN (check GL.iNet VPN Server tab)"
fi

LAN_IP=$(uci -q get network.lan.ipaddr || echo "192.168.0.1")
WAN_IFACE=$(ip route show default | awk '/default/ {print $5; exit}')
[ -z "$WAN_IFACE" ] && WAN_IFACE=$(uci -q get network.wan.ifname || uci -q get network.wan.device || echo "pppoe-wan")

echo "------------------------------------------"
echo "  LAN IP:       $LAN_IP"
echo "  WAN Iface:    $WAN_IFACE"
echo "  wgserver:     $WGSERVER_STATUS"
echo "  Local Peer:   peer_router (10.1.1.2/32)"
echo "  Client UI:    Mihomo-Sub / router-local (added)"
echo "  Backup Conf:  /root/router-local.conf"
echo "  Split Rules:  RU & Private -> DIRECT"
echo "------------------------------------------"
pause_step "Check summary above"

# =============================================================================
echo "[3/6] Writing $MIHOMO_DIR/config.yaml..."
# =============================================================================
mkdir -p "$MIHOMO_DIR"
rm -f "$MIHOMO_DIR/GeoIP.dat" "$MIHOMO_DIR/GeoSite.dat"

cat << YAML > "$MIHOMO_DIR/config.yaml"
mixed-port: 7890
allow-lan: true
mode: rule
log-level: info
external-controller: 0.0.0.0:9090
external-ui: ui
interface-name: $WAN_IFACE
routing-mark: 32768
geodata-mode: true
geo-auto-update: true
geo-update-interval: 168
geox-url:
  geoip: "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.dat"
  geosite: "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat"
tun:
  enable: true
  stack: gvisor
  device: utun
  auto-route: false
  auto-detect-interface: false
dns:
  enable: true
  listen: 0.0.0.0:1053
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  nameserver:
    - 1.1.1.1
    - 8.8.8.8
  nameserver-policy:
    "geosite:category-ru":
      - 77.88.8.8
      - 1.1.1.1
proxy-providers:
  sub:
    type: http
    url: "$SUB_URL"
    interval: 3600
    path: ./sub.yaml
    header:
      User-Agent:
        - "clash.meta"
    health-check:
      enable: true
      url: http://www.gstatic.com/generate_204
      interval: 300
proxy-groups:
  - name: PROXY
    type: url-test
    url: http://www.gstatic.com/generate_204
    interval: 300
    tolerance: 50
    exclude-filter: "(?i)(трафик|остаток|сброс|подписк|expire|traffic|reset|GB|ГБ)"
    use:
      - sub
rules:
  - GEOIP,PRIVATE,DIRECT,no-resolve
  - GEOSITE,category-ru,DIRECT
  - DOMAIN-SUFFIX,ru,DIRECT
  - DOMAIN-SUFFIX,su,DIRECT
  - DOMAIN-SUFFIX,xn--p1ai,DIRECT
  - GEOIP,RU,DIRECT
  - MATCH,PROXY
YAML

# =============================================================================
echo "[4/6] Configuring Mihomo service, sysctl, firewall (UCI + hotplug)..."
# =============================================================================

# --- SYSCTL ---
sysctl -w net.ipv4.conf.all.accept_local=1 >/dev/null 2>&1
sysctl -w net.ipv4.conf.default.accept_local=1 >/dev/null 2>&1
sysctl -w net.ipv4.conf.lo.accept_local=1 >/dev/null 2>&1
sysctl -w net.ipv4.conf.wgserver.accept_local=1 >/dev/null 2>&1
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1
sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1
sysctl -w net.ipv4.conf.lo.rp_filter=0 >/dev/null 2>&1
sysctl -w net.ipv4.conf.wgserver.rp_filter=0 >/dev/null 2>&1

touch /etc/sysctl.conf
sed -i '/# BEGIN AWG_SUB_SYSCTL/,/# END AWG_SUB_SYSCTL/d' /etc/sysctl.conf
cat << SYSCTL >> /etc/sysctl.conf
# BEGIN AWG_SUB_SYSCTL
net.ipv4.conf.all.accept_local=1
net.ipv4.conf.default.accept_local=1
net.ipv4.conf.lo.accept_local=1
net.ipv4.conf.wgserver.accept_local=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
net.ipv4.conf.lo.rp_filter=0
net.ipv4.conf.wgserver.rp_filter=0
# END AWG_SUB_SYSCTL
SYSCTL

# --- INIT.D MIHOMO (с fwmark для исключения петли) ---
cat << 'INIT_MIHOMO' > /etc/init.d/mihomo
#!/bin/sh /etc/rc.common
START=95
STOP=10
USE_PROCD=1

start_service() {
    procd_open_instance
    procd_set_param command /usr/bin/mihomo -d /etc/mihomo
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
    (
        i=0
        while [ $i -lt 60 ]; do
            if ip link show utun >/dev/null 2>&1; then
                ip link set up dev utun
                # fwmark 32768 — трафик от Mihomo идёт в main, а не в таблицу 200 (петли нет)
                ip rule del fwmark 32768 2>/dev/null
                ip rule add fwmark 32768 lookup main priority 40
                # Основной маршрут через utun
                ip route replace default dev utun table 200
                # Маршрут для peer_router (чтобы пакеты возвращались)
                ip route replace 10.1.1.2/32 dev wgserver 2>/dev/null
                ip route replace 10.1.1.2/32 dev wgserver table 9910 2>/dev/null
                # Правило: iif wgserver → таблица 200 (приоритет 50 — НИЖЕ, чем fwmark 40)
                ip rule del iif wgserver lookup 200 2>/dev/null
                ip rule add iif wgserver lookup 200 priority 50
                sysctl -w net.ipv4.conf.wgserver.accept_local=1 >/dev/null 2>&1
                sysctl -w net.ipv4.conf.wgserver.rp_filter=0 >/dev/null 2>&1
                break
            fi
            sleep 1
            i=$((i + 1))
        done
    ) &
}

stop_service() {
    ip rule del fwmark 32768 2>/dev/null
    ip rule del iif wgserver lookup 200 2>/dev/null
    ip route del 10.1.1.2/32 dev wgserver 2>/dev/null
    ip route del 10.1.1.2/32 dev wgserver table 9910 2>/dev/null
    ip route flush table 200 2>/dev/null
}
INIT_MIHOMO
chmod +x /etc/init.d/mihomo
/etc/init.d/mihomo enable

# --- UCI FIREWALL: собственные именованные секции (GL.iNet НЕ трогает) ---

# 1. Исключаем wgserver из mangle OUTPUT (предотвращаем конфликт с vpn_policy GL.iNet)
if ! uci -q get firewall.awg_sub_mangle_out >/dev/null 2>&1; then
    uci add firewall rule
    uci set firewall.@rule[-1].name='awg_sub_mangle_out'
    uci set firewall.@rule[-1].src='*'
    uci set firewall.@rule[-1].proto='all'
    uci set firewall.@rule[-1].outbound='wgserver'
    uci set firewall.@rule[-1].target='RETURN'
    uci set firewall.@rule[-1].extra='-t mangle -A OUTPUT'
    uci set firewall.@rule[-1].enabled='1'
    uci rename firewall.@rule[-1]='awg_sub_mangle_out'
fi

# 2. Исключаем wgserver из mangle PREROUTING
if ! uci -q get firewall.awg_sub_mangle_pre >/dev/null 2>&1; then
    uci add firewall rule
    uci set firewall.@rule[-1].name='awg_sub_mangle_pre'
    uci set firewall.@rule[-1].src='*'
    uci set firewall.@rule[-1].proto='all'
    uci set firewall.@rule[-1].inbound='wgserver'
    uci set firewall.@rule[-1].target='RETURN'
    uci set firewall.@rule[-1].extra='-t mangle -A PREROUTING'
    uci set firewall.@rule[-1].enabled='1'
    uci rename firewall.@rule[-1]='awg_sub_mangle_pre'
fi

# 3. FORWARD: wgserver → wan (чтобы пакеты вообще ходили)
if ! uci -q get firewall.awg_sub_fwd >/dev/null 2>&1; then
    uci add firewall forwarding
    uci set firewall.@forwarding[-1].name='awg_sub_fwd'
    uci set firewall.@forwarding[-1].src='wgserver'
    uci set firewall.@forwarding[-1].dest='wan'
    uci set firewall.@forwarding[-1].enabled='1'
    uci rename firewall.@forwarding[-1]='awg_sub_fwd'
fi

# 4. MSS Fix
if ! uci -q get firewall.awg_sub_mss >/dev/null 2>&1; then
    uci add firewall rule
    uci set firewall.@rule[-1].name='awg_sub_mss'
    uci set firewall.@rule[-1].proto='tcp'
    uci set firewall.@rule[-1].tcp_flags='SYN,RST/SYN'
    uci set firewall.@rule[-1].target='MSSFIX'
    uci set firewall.@rule[-1].enabled='1'
    uci rename firewall.@rule[-1]='awg_sub_mss'
fi

# 5. DNS перехват wgserver → Mihomo (UDP)
if ! uci -q get firewall.awg_sub_dns_udp >/dev/null 2>&1; then
    uci add firewall redirect
    uci set firewall.@redirect[-1].name='awg_sub_dns_udp'
    uci set firewall.@redirect[-1].src='wgserver'
    uci set firewall.@redirect[-1].proto='udp'
    uci set firewall.@redirect[-1].src_dport='53'
    uci set firewall.@redirect[-1].dest_port='1053'
    uci set firewall.@redirect[-1].target='DNAT'
    uci set firewall.@redirect[-1].enabled='1'
    uci rename firewall.@redirect[-1]='awg_sub_dns_udp'
fi

# 6. DNS перехват wgserver → Mihomo (TCP)
if ! uci -q get firewall.awg_sub_dns_tcp >/dev/null 2>&1; then
    uci add firewall redirect
    uci set firewall.@redirect[-1].name='awg_sub_dns_tcp'
    uci set firewall.@redirect[-1].src='wgserver'
    uci set firewall.@redirect[-1].proto='tcp'
    uci set firewall.@redirect[-1].src_dport='53'
    uci set firewall.@redirect[-1].dest_port='1053'
    uci set firewall.@redirect[-1].target='DNAT'
    uci set firewall.@redirect[-1].enabled='1'
    uci rename firewall.@redirect[-1]='awg_sub_dns_tcp'
fi

uci commit firewall

# --- UCI NETWORK: маршруты и правила (GL.iNet НЕ трогает) ---
if ! uci -q get network.awg_sub_rt >/dev/null 2>&1; then
    uci add network route
    uci set network.@route[-1].interface='wgserver'
    uci set network.@route[-1].target='0.0.0.0/0'
    uci set network.@route[-1].table='200'
    uci rename network.@route[-1]='awg_sub_rt'
fi

if ! uci -q get network.awg_sub_rule >/dev/null 2>&1; then
    uci add network rule
    uci set network.@rule[-1].in='wgserver'
    uci set network.@rule[-1].lookup='200'
    uci set network.@rule[-1].priority='50'
    uci rename network.@rule[-1]='awg_sub_rule'
fi

uci commit network

# --- /etc/firewall.user (применяется при старте firewall) ---
touch /etc/firewall.user
sed -i '/# BEGIN AWG_SUB_RULES/,/# END AWG_SUB_RULES/d' /etc/firewall.user
cat << FW >> /etc/firewall.user
# BEGIN AWG_SUB_RULES
ip route replace 10.1.1.2/32 dev wgserver 2>/dev/null
ip route replace 10.1.1.2/32 dev wgserver table 9910 2>/dev/null
iptables -C FORWARD -i wgserver -o utun -j ACCEPT 2>/dev/null || iptables -I FORWARD -i wgserver -o utun -j ACCEPT
iptables -C FORWARD -i utun -o wgserver -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -I FORWARD -i utun -o wgserver -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -t nat -C PREROUTING -i wgserver -p udp --dport 53 -j REDIRECT --to-ports 1053 2>/dev/null || iptables -t nat -I PREROUTING -i wgserver -p udp --dport 53 -j REDIRECT --to-ports 1053
iptables -t nat -C PREROUTING -i wgserver -p tcp --dport 53 -j REDIRECT --to-ports 1053 2>/dev/null || iptables -t nat -I PREROUTING -i wgserver -p tcp --dport 53 -j REDIRECT --to-ports 1053
iptables -t nat -C POSTROUTING -o utun -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING -o utun -j MASQUERADE
iptables -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -I FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
# END AWG_SUB_RULES
FW

# --- HOTPLUG ХУК: восстанавливает порядок правил ПОСЛЕ любого reload firewall ---
# GL.iNet НЕ трогает /etc/hotplug.d/iface/ — это перманентное решение
mkdir -p /etc/hotplug.d/iface
cat << 'HOTPLUG' > /etc/hotplug.d/iface/99-awg-sub-restore
#!/bin/sh
# Срабатывает ПОСЛЕ любого reload firewall (включая переключение фильтрации в морде GL.iNet)
[ "$ACTION" = "ifup" ] || exit 0

# Ждём, пока fw3 полностью отработает
sleep 2

# === Восстанавливаем порядок правил в mangle (GL.iNet вставляет свои в начало) ===
# Исключаем wgserver из mangle OUTPUT — ВСТАВЛЯЕМ В САМОЕ НАЧАЛО (позиция 1)
iptables -t mangle -D OUTPUT -o wgserver -j RETURN 2>/dev/null
iptables -t mangle -I OUTPUT 1 -o wgserver -j RETURN 2>/dev/null

# Исключаем wgserver из mangle PREROUTING
iptables -t mangle -D PREROUTING -i wgserver -j RETURN 2>/dev/null
iptables -t mangle -I PREROUTING 1 -i wgserver -j RETURN 2>/dev/null

# === Маршруты для peer_router ===
ip route replace 10.1.1.2/32 dev wgserver 2>/dev/null
ip route replace 10.1.1.2/32 dev wgserver table 9910 2>/dev/null

# === fwmark для Mihomo (исключаем из петли) ===
ip rule del fwmark 32768 2>/dev/null
ip rule add fwmark 32768 lookup main priority 40 2>/dev/null

# === FORWARD правила ===
iptables -C FORWARD -i wgserver -o utun -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD -i wgserver -o utun -j ACCEPT 2>/dev/null
iptables -C FORWARD -i utun -o wgserver -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD -i utun -o wgserver -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null

# === NAT ===
iptables -t nat -C POSTROUTING -o utun -j MASQUERADE 2>/dev/null || \
    iptables -t nat -I POSTROUTING -o utun -j MASQUERADE 2>/dev/null
HOTPLUG
chmod +x /etc/hotplug.d/iface/99-awg-sub-restore

# --- Применяем всё ---
/etc/init.d/network restart
/etc/init.d/firewall reload

# Запускаем Mihomo
rm -f "$MIHOMO_DIR/sub.yaml" "$MIHOMO_DIR/happ_sub.yaml"
/etc/init.d/mihomo restart 2>/dev/null

echo "Waiting for Mihomo to download GeoIP/GeoSite databases and bring up utun..."
i=0
while [ $i -lt 30 ]; do
    ip link show utun >/dev/null 2>&1 && break
    sleep 1
    i=$((i + 1))
done

# Принудительно вызываем hotplug для применения правил прямо сейчас
sh /etc/hotplug.d/iface/99-awg-sub-restore ACTION=ifup INTERFACE=wgserver 2>/dev/null

UTUN_STATE=$(ip link show utun 2>/dev/null | grep -q "UP" && echo "UP" || echo "DOWN")
TBL200=$(ip route show table 200 | head -n 1)
PROXY_IP=$(curl -x http://127.0.0.1:7890 -4 -s --max-time 8 https://api.ipify.org)

echo "------------------------------------------"
echo "  utun:       $UTUN_STATE"
echo "  Table 200:  ${TBL200:-EMPTY}"
echo "  Proxy IP:   ${PROXY_IP:-CHECKING...}"
echo "------------------------------------------"

# =============================================================================
echo "[5/6] Web UI setup..."
# =============================================================================
if [ "$AUTO_MODE" = "--auto" ]; then
    UI_ANS="y"
else
    printf "\n>>> Download and install Metacubexd Web UI? (y/n): "
    read -r UI_ANS
fi

case "$UI_ANS" in
    y|Y|yes|YES|д|Д)
        echo "Downloading Metacubexd Web UI..."
        rm -rf "$MIHOMO_DIR/ui" && mkdir -p "$MIHOMO_DIR/ui"
        UI_URL="https://github.com/MetaCubeX/metacubexd/releases/latest/download/compressed-dist.tgz"
        if curl -fL --max-time 25 "$UI_URL" -o /tmp/ui.tgz || curl -fL -x http://127.0.0.1:7890 --max-time 25 "$UI_URL" -o /tmp/ui.tgz; then
            tar -xzf /tmp/ui.tgz -C "$MIHOMO_DIR/ui" && rm -f /tmp/ui.tgz
            find "$MIHOMO_DIR/ui" -type f -name "*.js" -exec sed -i "s|127\.0\.0\.1|${LAN_IP}|g" {} +
            /etc/init.d/mihomo restart 2>/dev/null
            echo "Web UI installed: http://${LAN_IP}:9090/ui/"
        else
            rm -f /tmp/ui.tgz
            echo "ERROR: Failed to download Web UI."
        fi
        ;;
    *)
        echo "Web UI skipped."
        ;;
esac

# =============================================================================
echo "[6/6] Firmware upgrade persistence (/etc/sysupgrade.conf)..."
# =============================================================================
if [ "$AUTO_MODE" = "--auto" ]; then
    KEEP_ANS="y"
else
    printf "\n>>> Preserve configs and Mihomo across firmware upgrades? (y/n): "
    read -r KEEP_ANS
fi

case "$KEEP_ANS" in
    y|Y|yes|YES|д|Д)
        touch /etc/sysupgrade.conf
        for item in \
            "/root/router-local.conf" \
            "/etc/mihomo" \
            "/etc/init.d/mihomo" \
            "/etc/firewall.user" \
            "/etc/sysctl.conf" \
            "/etc/hotplug.d/iface/99-awg-sub-restore" \
            "/usr/bin/mihomo"
        do
            grep -qxF "$item" /etc/sysupgrade.conf 2>/dev/null || echo "$item" >> /etc/sysupgrade.conf
        done
        echo "Added to /etc/sysupgrade.conf."
        ;;
    *)
        echo "Sysupgrade persistence skipped."
        ;;
esac

# Self-cleanup installer script after successful setup
rm -f "$0" /root/setup_awg_sub.sh

echo ""
echo "DONE! Installer cleaned up."
echo ""
echo "Next steps:"
echo "  1. Open GL.iNet Admin Panel -> VPN -> WireGuard / AmneziaWG Client"
echo "  2. Start the 'Mihomo-Sub / router-local' profile"
echo "  3. Check Web UI: http://${LAN_IP}:9090/ui/"
echo ""
echo "Verification commands:"
echo "  ip rule show                          # 40: fwmark 32768 lookup main, 50: iif wgserver lookup 200"
echo "  iptables -t mangle -L OUTPUT -n -v    # Первое правило: RETURN all -- * wgserver"
echo "  curl -x http://127.0.0.1:7890 https://api.ipify.org  # IP сервера из подписки"