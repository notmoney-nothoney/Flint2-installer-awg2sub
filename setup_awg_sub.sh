#!/bin/sh
# =============================================================================
# setup_mihomo_clean.sh v3.2
# Fixes vs v3.1:
#   - wait_ubus at start (no hang if ubus dead)
#   - timeout 20 around ifup / wireguard_server start
#   - awg showconf once with timeout, not in loop
#   - obfuscation params only if wgserver UP
#   - skip ifup if wgserver already UP
# =============================================================================

SUB_URL="$1"
AUTO_MODE="$2"
MIHOMO_DIR="/etc/mihomo"

[ -z "$SUB_URL" ] && { echo "Usage: sh $0 \"<SUB_URL>\" [--auto]"; exit 1; }

pause_step() {
    [ "$AUTO_MODE" = "--auto" ] && return 0
    printf "\n>>> [PAUSE] %s (Enter=continue, q=abort): " "$1"
    read -r a; case "$a" in q|Q) echo "Aborted."; exit 0 ;; esac
}

# =============================================================================
echo "[1/9] Checking environment (ubus, tools)..."
# =============================================================================

# Ждём ubus (netifd/procd могут быть в переходном состоянии)
UBUS_OK=0
i=0
while [ $i -lt 20 ]; do
    ubus list >/dev/null 2>&1 && { UBUS_OK=1; break; }
    sleep 1; i=$((i+1))
done
if [ "$UBUS_OK" != "1" ]; then
    echo ""
    echo "ERROR: ubus is not responding (netifd/procd dead)."
    echo "       After uninstall, REBOOT the router, then re-run this script."
    echo "       Continuing will hang on ifup/uci commit."
    exit 1
fi
echo "  ubus:      OK"

AWG_BIN=$(command -v awg || command -v wg)
[ -z "$AWG_BIN" ] && { echo "ERROR: awg/wg not found"; exit 1; }

LAN_IP=$(uci -q get network.lan.ipaddr || echo "192.168.0.1")
WAN_IFACE=$(ip route show default | awk '/default/ {print $5; exit}')
[ -z "$WAN_IFACE" ] && WAN_IFACE=$(uci -q get network.wan.device || echo "pppoe-wan")

echo "  LAN IP:    $LAN_IP"
echo "  WAN iface: $WAN_IFACE"
echo "  awg bin:   $AWG_BIN"

# =============================================================================
echo "[2/9] Downloading Mihomo if absent..."
# =============================================================================
if [ ! -x /usr/bin/mihomo ]; then
    URL=$(curl -s --max-time 15 https://api.github.com/repos/MetaCubeX/mihomo/releases/latest 2>/dev/null | \
          grep -o '"browser_download_url": *"[^"]*mihomo-linux-arm64-v1\.[0-9.]*\.gz"' | \
          head -n 1 | cut -d '"' -f 4)
    [ -z "$URL" ] && { echo "ERROR: cannot fetch Mihomo URL"; exit 1; }
    echo "  downloading: $URL"
    curl -fL --max-time 120 "$URL" -o /tmp/mihomo.gz
    gunzip -f /tmp/mihomo.gz
    mv /tmp/mihomo /usr/bin/mihomo
    chmod +x /usr/bin/mihomo
fi
echo "  mihomo: $(timeout 5 /usr/bin/mihomo -v 2>&1 | head -1)"

# =============================================================================
echo "[3/9] Configuring wgserver + peer_router (loopback)…"
# =============================================================================
touch /etc/config/wireguard_server

if ! uci -q get wireguard_server.main_server >/dev/null 2>&1; then
    echo "  creating main_server…"
    SRV_PRIV=$(timeout 10 $AWG_BIN genkey)
    SRV_PUB=$(echo "$SRV_PRIV" | timeout 10 $AWG_BIN pubkey)
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
fi

# peer_router: пересоздать (uninstall мог удалить)
CLI_PRIV=$(uci -q get wireguard_server.peer_router.private_key)
CLI_PUB=$(uci -q get wireguard_server.peer_router.public_key)
if [ -z "$CLI_PRIV" ] || [ -z "$CLI_PUB" ]; then
    CLI_PRIV=$(timeout 10 $AWG_BIN genkey)
    CLI_PUB=$(echo "$CLI_PRIV" | timeout 10 $AWG_BIN pubkey)
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

WGS_PORT=$(uci -q get wireguard_server.main_server.port || echo 51820)
SRV_PUB=$(uci -q get wireguard_server.main_server.public_key)

# peer_9901 (loopback-клиент для mihomo)
touch /etc/config/wireguard
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
uci commit wireguard

# firewall зона wgserver + порт
if ! uci -q get firewall.wgserver >/dev/null 2>&1; then
    uci set firewall.wgserver='zone'
    uci set firewall.wgserver.name='wgserver'
    uci set firewall.wgserver.input='ACCEPT'
    uci set firewall.wgserver.output='ACCEPT'
    uci set firewall.wgserver.network='wgserver'
    uci set firewall.wgserver.masq='1'
    uci set firewall.wgserver.mtu_fix='1'
    uci set firewall.wgserver.enabled='1'
fi
uci -q delete firewall.wgserver_allow
uci set firewall.wgserver_allow='rule'
uci set firewall.wgserver_allow.name='wgserver_allow'
uci set firewall.wgserver_allow.src='wan'
uci set firewall.wgserver_allow.proto='udp'
uci set firewall.wgserver_allow.dest_port="$WGS_PORT"
uci set firewall.wgserver_allow.target='ACCEPT'
uci set firewall.wgserver_allow.enabled='1'
uci -q delete firewall.wgserver2lan
uci set firewall.wgserver2lan='rule'
uci set firewall.wgserver2lan.name='wgserver2lan'
uci set firewall.wgserver2lan.src='wgserver'
uci set firewall.wgserver2lan.dest='lan'
uci set firewall.wgserver2lan.proto='all'
uci set firewall.wgserver2lan.target='ACCEPT'
uci set firewall.wgserver2lan.enabled='1'
uci commit firewall

# === КРИТИЧНО: bring-up wgserver с таймаутом ===
if ip link show wgserver >/dev/null 2>&1; then
    echo "  wgserver:   already UP"
else
    echo "  wgserver:   starting (timeout 20s)…"
    if [ -x /etc/init.d/wireguard_server ]; then
        timeout 20 /etc/init.d/wireguard_server start 2>/dev/null || true
    fi
    if ! ip link show wgserver >/dev/null 2>&1; then
        timeout 20 ifup wgserver 2>/dev/null || true
    fi
    # Ждём до 15 сек
    i=0; while [ $i -lt 15 ]; do
        ip link show wgserver >/dev/null 2>&1 && break
        sleep 1; i=$((i+1))
    done
    if ! ip link show wgserver >/dev/null 2>&1; then
        echo "  WARN: wgserver not UP after 15s. Continuing anyway."
        echo "        (peer_router will be added when wgserver comes up)"
    fi
fi

# IP на wgserver
SRV_CIDR=$(uci -q get wireguard_server.main_server.address_v4)
if [ -n "$SRV_CIDR" ] && ip link show wgserver >/dev/null 2>&1; then
    SRV_IP=$(echo "$SRV_CIDR" | cut -d/ -f1)
    ip -4 addr show wgserver 2>/dev/null | grep -q "$SRV_IP" || \
        ip addr add "$SRV_CIDR" dev wgserver 2>/dev/null || true
fi

# Obfuscation params — только если wgserver UP, с таймаутом
if ip link show wgserver >/dev/null 2>&1; then
    SHOWCONF=$(timeout 10 $AWG_BIN showconf wgserver 2>/dev/null || echo "")
    if [ -n "$SHOWCONF" ]; then
        for p in jc jmin jmax s1 s2 s3 s4 h1 h2 h3 h4 i1 i2 i3 i4 i5; do
            v=$(echo "$SHOWCONF" | grep -i "^${p}[[:space:]]*=" | head -1 | cut -d= -f2 | tr -d ' ')
            [ -n "$v" ] && uci set "wireguard.peer_9901.${p}=$v" || uci -q delete "wireguard.peer_9901.${p}"
        done
        uci commit wireguard
        echo "  obfuscation params: copied from wgserver"
    else
        echo "  obfuscation params: SKIPPED (awg showconf failed/timed out)"
    fi
fi

# Hot-add peer_router
if ip link show wgserver >/dev/null 2>&1; then
    timeout 10 $AWG_BIN set wgserver peer "$CLI_PUB" allowed-ips 10.1.1.2/32 2>/dev/null || true
fi

echo "  wgserver: $(ip -4 addr show wgserver 2>/dev/null | awk '/inet / {print $2}' | head -1)"
echo "  peer_9901 endpoint: 127.0.0.1:${WGS_PORT}"

pause_step "wgserver configured"

# =============================================================================
echo "[4/9] Writing config.yaml (no .dat, 2 rules with IP-CIDR)..."
# =============================================================================
mkdir -p "$MIHOMO_DIR"

# Удаляем все geo-базы — с IP-CIDR они не нужны
rm -f "$MIHOMO_DIR/GeoIP.dat" "$MIHOMO_DIR/GeoSite.dat" \
      "$MIHOMO_DIR/geoip.dat" "$MIHOMO_DIR/geosite.dat" \
      "$MIHOMO_DIR/country.mmdb" 2>/dev/null || true

cat << YAML > "$MIHOMO_DIR/config.yaml"
mixed-port: 7890
allow-lan: true
bind-address: '*'
mode: rule
log-level: info
external-controller: 0.0.0.0:9090
external-ui: ui
interface-name: $WAN_IFACE

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
    - https://1.1.1.1/dns-query#PROXY
    - https://8.8.8.8/dns-query#PROXY

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
    interval: 60
    lazy: false
    tolerance: 50
    use:
      - sub

rules:
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,169.254.0.0/16,DIRECT,no-resolve
  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  - IP-CIDR,100.64.0.0/10,DIRECT,no-resolve
  - IP-CIDR6,fc00::/7,DIRECT,no-resolve
  - IP-CIDR6,fe80::/10,DIRECT,no-resolve
  - IP-CIDR6,::1/128,DIRECT,no-resolve
  - MATCH,PROXY
YAML

echo "  config.yaml: 9x IP-CIDR + MATCH,PROXY"
echo "  dns: DoH 1.1.1.1#PROXY + 8.8.8.8#PROXY"
echo "  group: url-test lazy:false interval:60"
echo "  NOTE: no GeoIP.dat/GeoSite.dat used"

pause_step "Config written"

# =============================================================================
echo "[5/9] Installing init.d/mihomo..."
# =============================================================================
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
                ip link set up dev utun 2>/dev/null
                sysctl -w net.ipv4.conf.utun.accept_local=1 >/dev/null 2>&1
                sysctl -w net.ipv4.conf.utun.rp_filter=0 >/dev/null 2>&1
                ifup utun 2>/dev/null
                sleep 2
                ip route show table 200 2>/dev/null | grep -q "^default" || \
                    ip route replace default dev utun table 200 2>/dev/null
                ip route show table 205 2>/dev/null | grep -q "^default" || \
                    ip route replace default dev utun table 205 2>/dev/null
                ip route show table 205 2>/dev/null | grep -q "10.1.1.2" || \
                    ip route replace 10.1.1.2/32 dev wgserver table 205 2>/dev/null
                logger -t mihomo-init "utun up, routing configured (${i}s)"
                break
            fi
            sleep 1
            i=$((i + 1))
        done
        [ $i -ge 60 ] && logger -t mihomo-init "ERROR: utun did not come up in 60s"
    ) &
}

stop_service() {
    ifdown utun 2>/dev/null
}
INIT_MIHOMO
chmod +x /etc/init.d/mihomo
/etc/init.d/mihomo enable

# =============================================================================
echo "[6/9] UCI network…"
# =============================================================================

# Чистим legacy от v3.1 и старых версий
for s in awg_sub_rt_peer awg_sub_rt_peer_9910 awg_sub_rt_peer_200 awg_sub_rt_peer_205 \
         awg_sub_rt_utun awg_sub_rule_iif awg_sub_rule_mark \
         mihomo_rt_peer_main mihomo_rt_peer_9910 mihomo_rt_peer_200 mihomo_rt_peer_205 \
         mihomo_rt_utun mihomo_rule_iif utun; do
    uci -q delete "network.$s"
done

# utun
uci set network.utun='interface'
uci set network.utun.proto='none'
uci set network.utun.device='utun'
uci set network.utun.auto='0'

# 10.1.1.2/32 в 3 таблицах + main
uci set network.mihomo_rt_peer_main='route'
uci set network.mihomo_rt_peer_main.interface='wgserver'
uci set network.mihomo_rt_peer_main.target='10.1.1.2/32'

uci set network.mihomo_rt_peer_9910='route'
uci set network.mihomo_rt_peer_9910.interface='wgserver'
uci set network.mihomo_rt_peer_9910.target='10.1.1.2/32'
uci set network.mihomo_rt_peer_9910.table='9910'

uci set network.mihomo_rt_peer_200='route'
uci set network.mihomo_rt_peer_200.interface='wgserver'
uci set network.mihomo_rt_peer_200.target='10.1.1.2/32'
uci set network.mihomo_rt_peer_200.table='200'

uci set network.mihomo_rt_peer_205='route'
uci set network.mihomo_rt_peer_205.interface='wgserver'
uci set network.mihomo_rt_peer_205.target='10.1.1.2/32'
uci set network.mihomo_rt_peer_205.table='205'

# default via utun в 200
uci set network.mihomo_rt_utun='route'
uci set network.mihomo_rt_utun.interface='utun'
uci set network.mihomo_rt_utun.target='0.0.0.0/0'
uci set network.mihomo_rt_utun.table='200'

# rule 50
uci set network.mihomo_rule_iif='rule'
uci set network.mihomo_rule_iif.in='wgserver'
uci set network.mihomo_rule_iif.lookup='200'
uci set network.mihomo_rule_iif.priority='50'

uci commit network

# =============================================================================
echo "[7/9] UCI firewall…"
# =============================================================================

for s in awg_sub_fwd_wan awg_sub_fwd_utun awg_sub_fwd_ret \
         awg_sub_mangle_pre awg_sub_mangle_out awg_sub_mss \
         awg_sub_dns_udp awg_sub_dns_tcp \
         mihomo_fwd_wan mihomo_fwd_utun mihomo_fwd_ret \
         mihomo_dns_udp mihomo_dns_tcp mihomo_lan_access; do
    uci -q delete "firewall.$s"
done

if ! uci -q get firewall.utun >/dev/null 2>&1; then
    uci set firewall.utun='zone'
    uci set firewall.utun.name='utun'
    uci set firewall.utun.network='utun'
    uci set firewall.utun.input='ACCEPT'
    uci set firewall.utun.output='ACCEPT'
    uci set firewall.utun.forward='ACCEPT'
    uci set firewall.utun.masq='1'
    uci set firewall.utun.mtu_fix='1'
    uci set firewall.utun.enabled='1'
fi

uci set firewall.mihomo_fwd_wan='forwarding'
uci set firewall.mihomo_fwd_wan.src='wgserver'
uci set firewall.mihomo_fwd_wan.dest='wan'
uci set firewall.mihomo_fwd_wan.enabled='1'

uci set firewall.mihomo_fwd_utun='forwarding'
uci set firewall.mihomo_fwd_utun.src='wgserver'
uci set firewall.mihomo_fwd_utun.dest='utun'
uci set firewall.mihomo_fwd_utun.enabled='1'

uci set firewall.mihomo_fwd_ret='forwarding'
uci set firewall.mihomo_fwd_ret.src='utun'
uci set firewall.mihomo_fwd_ret.dest='wgserver'
uci set firewall.mihomo_fwd_ret.enabled='1'

uci set firewall.mihomo_dns_udp='redirect'
uci set firewall.mihomo_dns_udp.name='mihomo_dns_udp'
uci set firewall.mihomo_dns_udp.src='wgserver'
uci set firewall.mihomo_dns_udp.proto='udp'
uci set firewall.mihomo_dns_udp.src_dport='53'
uci set firewall.mihomo_dns_udp.dest_ip='127.0.0.1'
uci set firewall.mihomo_dns_udp.dest_port='1053'
uci set firewall.mihomo_dns_udp.target='DNAT'
uci set firewall.mihomo_dns_udp.family='ipv4'
uci set firewall.mihomo_dns_udp.enabled='1'

uci set firewall.mihomo_dns_tcp='redirect'
uci set firewall.mihomo_dns_tcp.name='mihomo_dns_tcp'
uci set firewall.mihomo_dns_tcp.src='wgserver'
uci set firewall.mihomo_dns_tcp.proto='tcp'
uci set firewall.mihomo_dns_tcp.src_dport='53'
uci set firewall.mihomo_dns_tcp.dest_ip='127.0.0.1'
uci set firewall.mihomo_dns_tcp.dest_port='1053'
uci set firewall.mihomo_dns_tcp.target='DNAT'
uci set firewall.mihomo_dns_tcp.family='ipv4'
uci set firewall.mihomo_dns_tcp.enabled='1'

uci set firewall.mihomo_lan_access='rule'
uci set firewall.mihomo_lan_access.name='Allow-Mihomo-LAN'
uci set firewall.mihomo_lan_access.src='lan'
uci set firewall.mihomo_lan_access.proto='tcp udp'
uci set firewall.mihomo_lan_access.dest_port='7890 9090 1053'
uci set firewall.mihomo_lan_access.target='ACCEPT'
uci set firewall.mihomo_lan_access.enabled='1'

uci commit firewall

# =============================================================================
echo "[8/9] sysctl + cleanup + apply…"
# =============================================================================

for iface in all default lo wgserver utun; do
    sysctl -w net.ipv4.conf.$iface.accept_local=1 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.conf.$iface.rp_filter=0 >/dev/null 2>&1 || true
done

touch /etc/sysctl.conf
sed -i '/# BEGIN MIHOMO_SYSCTL/,/# END MIHOMO_SYSCTL/d' /etc/sysctl.conf
cat << 'SYSCTL' >> /etc/sysctl.conf
# BEGIN MIHOMO_SYSCTL
net.ipv4.conf.all.accept_local=1
net.ipv4.conf.default.accept_local=1
net.ipv4.conf.lo.accept_local=1
net.ipv4.conf.wgserver.accept_local=1
net.ipv4.conf.utun.accept_local=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
net.ipv4.conf.lo.rp_filter=0
net.ipv4.conf.wgserver.rp_filter=0
net.ipv4.conf.utun.rp_filter=0
# END MIHOMO_SYSCTL
SYSCTL

sed -i '/# BEGIN AWG_SUB_RULES/,/# END AWG_SUB_RULES/d' /etc/firewall.user 2>/dev/null || true
rm -f /etc/hotplug.d/iface/99-awg-sub-restore 2>/dev/null || true

echo "  network reload..."
timeout 30 /etc/init.d/network reload || true
sleep 3

echo "  firewall reload..."
timeout 40 /etc/init.d/firewall reload || true
sleep 2

echo "  mihomo start..."
rm -f "$MIHOMO_DIR/sub.yaml" "$MIHOMO_DIR/happ_sub.yaml" 2>/dev/null || true
timeout 20 /etc/init.d/mihomo restart || true

echo "  waiting for utun (60s max — no geo download)…"
i=0
while [ $i -lt 60 ]; do
    ip link show utun >/dev/null 2>&1 && break
    sleep 1; i=$((i + 1))
    [ $((i % 10)) -eq 0 ] && echo "    ...${i}s"
done
[ -d /sys/class/net/utun ] && timeout 10 ifup utun 2>/dev/null || true
sleep 3

echo ""
echo "=== Self-check ==="
echo "  utun:       $(ip link show utun 2>/dev/null | grep -q UP && echo UP || echo DOWN)"
echo "  table 200:  $(ip route show table 200 | head -2 | tr '\n' ' ')"
echo "  table 205:  $(ip route show table 205 | head -2 | tr '\n' ' ')"
echo "  rule 50:    $(ip rule show | grep '50:' | head -1)"
echo "  .dat files: $(ls /etc/mihomo/*.dat 2>/dev/null | wc -l) (должно быть 0)"
PROXY_IP=$(timeout 15 curl -x http://127.0.0.1:7890 -4 -s https://api.ipify.org 2>/dev/null || echo "TIMEOUT")
echo "  proxy IP:   $PROXY_IP"

# =============================================================================
echo "[9/9] WebUI + persistence…"
# =============================================================================

if [ "$AUTO_MODE" = "--auto" ]; then UI_ANS="y"
else printf "\n>>> Download Metacubexd Web UI? (y/n): "; read -r UI_ANS; fi

case "$UI_ANS" in
    y|Y|yes|YES|д|Д)
        rm -rf "$MIHOMO_DIR/ui" && mkdir -p "$MIHOMO_DIR/ui"
        UI_URL="https://github.com/MetaCubeX/metacubexd/releases/latest/download/compressed-dist.tgz"
        if curl -fL --max-time 40 "$UI_URL" -o /tmp/ui.tgz 2>/dev/null || \
           curl -fL -x http://127.0.0.1:7890 --max-time 40 "$UI_URL" -o /tmp/ui.tgz 2>/dev/null; then
            tar -xzf /tmp/ui.tgz -C "$MIHOMO_DIR/ui" && rm -f /tmp/ui.tgz
            find "$MIHOMO_DIR/ui" -type f -name "*.js" -exec sed -i "s|127\.0\.0\.1|${LAN_IP}|g" {} + 2>/dev/null
            timeout 15 /etc/init.d/mihomo restart || true
            sleep 4
            echo "  WebUI: http://${LAN_IP}:9090/ui/"
        else
            rm -f /tmp/ui.tgz; echo "  WebUI: FAILED"
        fi ;;
    *) echo "  WebUI skipped" ;;
esac

if [ "$AUTO_MODE" = "--auto" ]; then KEEP_ANS="y"
else printf "\n>>> Preserve configs across upgrades? (y/n): "; read -r KEEP_ANS; fi

case "$KEEP_ANS" in
    y|Y|yes|YES|д|Д)
        touch /etc/sysupgrade.conf
        for item in /etc/mihomo /etc/init.d/mihomo /etc/sysctl.conf /usr/bin/mihomo /root/router-local.conf; do
            grep -qxF "$item" /etc/sysupgrade.conf 2>/dev/null || echo "$item" >> /etc/sysupgrade.conf
        done
        echo "  added to /etc/sysupgrade.conf" ;;
    *) echo "  skipped" ;;
esac



echo ""
echo "============================================================"
echo "  DONE"
echo "============================================================"
echo "  rules:  9x IP-CIDR DIRECT + MATCH,PROXY"
echo "  dns:    DoH 1.1.1.1#PROXY"
echo "  group:  url-test lazy:false interval:60"
echo "  no GeoIP.dat/GeoSite.dat"
echo ""
echo "  LAN-PC test (PowerShell):"
echo "    curl.exe --ssl-no-revoke -4 -s -x http://${LAN_IP}:7890 https://api.ipify.org"
echo "  WG-client test (phone):"
echo "    https://api.ipify.org"
echo "  WebUI:"
echo "    http://${LAN_IP}:9090/ui/"