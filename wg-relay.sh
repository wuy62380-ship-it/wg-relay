#!/bin/bash
# ==========================================
# WireGuard 智能中转部署脚本 v137.0 (SNI优选与防假死版)
# 修复：删除不存在的max_time_difference字段，引入大厂SNI自动测速优选
# ==========================================

if [ -t 0 ]; then :; else exec </dev/tty; fi

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'
export RED GREEN YELLOW CYAN NC

WG_CONF="/etc/wireguard/wg0.conf"
NODES_INFO="/etc/wireguard/nodes_info.txt"
LAND_INFO="/etc/wireguard/landing_info.txt"
WG_PORT="51820"
WG_NET="10.0.0.0/24"
SYSCTL_FILE="/etc/sysctl.d/99-yg-tune.conf"
IP_FORWARD_FILE="/etc/sysctl.d/99-ip-forward.conf"

export DEBIAN_FRONTEND=noninteractive

check_root() { [ "$EUID" -ne 0 ] && echo -e "${RED}请使用root运行${NC}" && exit 1; }

pause_return() {
    echo -e "${YELLOW}按 Enter 键返回主菜单...${NC}"
    read -r < /dev/tty
}

kill_apt_locks() {
    rm -f /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock /var/lib/apt/lists/lock 2>/dev/null
    dpkg --configure -a 2>/dev/null
}

flush_wg_rules() {
    iptables -t nat -S | grep '10.0.0.' | sed 's/-A/-D/' | while read -r rule; do iptables -t nat $rule 2>/dev/null; done
    iptables -S | grep '10.0.0.' | sed 's/-A/-D/' | while read -r rule; do iptables $rule 2>/dev/null; done
    netfilter-persistent save >/dev/null 2>&1
}

restart_wg() {
    wg-quick down wg0 >/dev/null 2>&1
    wg-quick up wg0 >/dev/null 2>&1
    [ $? -ne 0 ] && echo -e "${RED}❌ WireGuard 启动失败！${NC}" && return 1
    return 0
}

allow_port() {
    local port=$1
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "active"; then
        ufw allow "$port"/tcp >/dev/null 2>&1
        ufw allow "$port"/udp >/dev/null 2>&1
        ufw allow in on wg0 >/dev/null 2>&1
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-port="$port"/tcp >/dev/null 2>&1
        firewall-cmd --permanent --add-port="$port"/udp >/dev/null 2>&1
        firewall-cmd --permanent --zone=trusted --add-interface=wg0 >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    else
        iptables -I INPUT 1 -p tcp --dport "$port" -j ACCEPT 2>/dev/null
        iptables -I INPUT 1 -p udp --dport "$port" -j ACCEPT 2>/dev/null
        iptables -I INPUT 1 -i wg0 -j ACCEPT 2>/dev/null
    fi
}

prepare_env() {
    echo -e "${YELLOW}正在准备环境...${NC}"
    kill_apt_locks
    apt-get update -y > /dev/null 2>&1
    apt-get install -y curl wget gnupg ca-certificates iptables iptables-persistent tar jq openssl coreutils iproute2 iputils-ping util-linux > /dev/null 2>&1
    modprobe nf_conntrack 2>/dev/null
    command -v jq &> /dev/null || { echo -e "${RED}❌ jq 安装失败${NC}"; exit 1; }
    echo -e "${GREEN}✓ 环境准备完毕${NC}"; sleep 1
}

get_pub_ip() {
    local ip=""
    for url in ifconfig.me ip.sb api.ipify.org; do
        ip=$(curl -s --connect-timeout 3 --max-time 5 -4 $url 2>/dev/null | tr -d '[:space:]')
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "$ip" && return 0
    done
    echo ""
    return 1
}

install_singbox() {
    if command -v sing-box &> /dev/null && [ -x "/usr/local/bin/sing-box" ]; then return 0; fi
    echo -e "${YELLOW}[*] 下载 Sing-box...${NC}"
    ARCH=$(uname -m)
    [ "$ARCH" == "x86_64" ] && SB_ARCH="amd64" || { [ "$ARCH" == "aarch64" ] && SB_ARCH="arm64" || { echo -e "${RED}不支持的架构${NC}"; return 1; }; }
    
    SB_VER="1.8.7"
    URL="https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/sing-box-${SB_VER}-linux-${SB_ARCH}.tar.gz"
    timeout 30 wget -q -T 15 -t 2 -O /tmp/sb.tar.gz "$URL" 2>/dev/null || timeout 30 wget -q -T 15 -t 2 -O /tmp/sb.tar.gz "https://ghproxy.net/$URL" 2>/dev/null
    [ ! -s /tmp/sb.tar.gz ] && echo -e "${RED}下载失败${NC}" && return 1
    
    tar -xzf /tmp/sb.tar.gz -C /tmp && mv /tmp/sing-box-${SB_VER}-linux-${SB_ARCH}/sing-box /usr/local/bin/ && chmod +x /usr/local/bin/sing-box
    rm -rf /tmp/sb.tar.gz /tmp/sing-box-*
    mkdir -p /etc/sing-box
    systemctl stop sing-box 2>/dev/null
    
    cat > /etc/systemd/system/sing-box.service << EOF
[Unit]
Description=sing-box service
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    echo -e "${GREEN}✓ Sing-box 安装成功${NC}"
}

# 终极修复：引入大厂 SNI 自动测速优选，彻底解决伪装域名被拦截问题
select_best_sni() {
    echo -e "${YELLOW}[*] 正在测速优选大厂 SNI 伪装域名...${NC}"
    local domains=("www.bing.com" "www.apple.com" "www.cloudflare.com" "www.amazon.com" "www.google.com")
    local best_domain="" best_time=9999
    
    for domain in "${domains[@]}"; do
        local time_ms=$(curl -sI -o /dev/null -w "%{time_connect}" --connect-timeout 2 "https://$domain" 2>/dev/null)
        if [ -n "$time_ms" ]; then
            local ms=$(echo "$time_ms * 1000" | bc 2>/dev/null | cut -d'.' -f1)
            if [ -n "$ms" ] && [ "$ms" -lt "$best_time" ]; then
                best_time=$ms
                best_domain=$domain
            fi
        fi
    done
    
    if [ -z "$best_domain" ]; then
        best_domain="www.bing.com"
        echo -e "${YELLOW}⚠ 测速失败，使用默认 SNI: $best_domain${NC}"
    else
        echo -e "${GREEN}✓ 优选 SNI: $best_domain (延迟: ${best_time}ms)${NC}"
    fi
    echo "$best_domain"
}

url_encode() { jq -rn --arg v "$1" '$v|@uri'; }

tune_system() {
    clear; echo -e "${YELLOW}━━━ 系统极限优化 ━━━${NC}"
    systemctl stop apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1
    local mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local conntrack_max=$((mem_kb / 16384 * 1024))
    [ "$conntrack_max" -lt 65536 ] && conntrack_max=65536
    
    cat > "$SYSCTL_FILE" << EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.ipv4.tcp_rmem = 4096 32768 16777216
net.ipv4.tcp_wmem = 4096 32768 16777216
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 100000
net.ipv4.tcp_fastopen = 3
net.ipv4.ip_forward = 1
net.netfilter.nf_conntrack_max = $conntrack_max
vm.swappiness = 10
EOF
    sysctl -p "$SYSCTL_FILE" > /dev/null 2>&1
    for dir in /sys/class/net/*/queues/rx-*; do [ -f "$dir/rps_cpus" ] && echo ff > "$dir/rps_cpus" 2>/dev/null; done
    echo -e "${GREEN}✓ 优化完成！${NC}"; pause_return
}

check_node_name() {
    [ ${#1} -gt 20 ] || [[ "$1" =~ [\/\\|\&\;\$\<\>\`\!\?\*\(\)\ ] ]] && echo -e "${RED}❌ 名称无效！${NC}" && return 1
    return 0
}

check_ip_format() {
    [[ ! "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo -e "${RED}❌ IP 格式不正确！${NC}" && return 1
    return 0
}

init_relay() {
    clear; echo -e "${YELLOW}━━━ 初始化中转机 ━━━${NC}"
    if [ -f "$WG_CONF" ]; then
        read -p "${RED}已有配置将被覆盖！确定？[y/N]: ${NC}" c < /dev/tty
        [[ ! "$c" =~ ^[Yy]$ ]] && { pause_return; return; }
    fi
    
    echo -e "${YELLOW}[*] 清理旧规则...${NC}"
    flush_wg_rules
    mkdir -p /etc/wireguard
    echo "" > "$NODES_INFO"
    
    apt-get install -y wireguard > /dev/null 2>&1
    WG_PRIV=$(wg genkey); WG_PUB=$(echo "$WG_PRIV" | wg pubkey)
    RELAY_IP=$(get_pub_ip)
    [ -z "$RELAY_IP" ] && echo -e "${RED}无法获取公网IP${NC}" && pause_return && return
    
    cat > "$WG_CONF" << EOF
[Interface]
PrivateKey = $WG_PRIV
Address = 10.0.0.1/24
ListenPort = $WG_PORT
MTU = 1380
EOF
    systemctl enable wg-quick@wg0 > /dev/null 2>&1
    wg-quick down wg0 >/dev/null 2>&1
    restart_wg || { pause_return; return; }
    
    mkdir -p /etc/sysctl.d
    echo "net.ipv4.ip_forward = 1" > "$IP_FORWARD_FILE"
    sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1
    sysctl -p "$IP_FORWARD_FILE" > /dev/null 2>&1
    allow_port "$WG_PORT"
    
    echo -e "${GREEN}=========================================="
    echo -e " IP: ${CYAN}${RELAY_IP}${NC} | 公钥: ${CYAN}${WG_PUB}${NC}"
    echo -e "=========================================="
    pause_return
}

gen_landing_code() {
    clear; echo -e "${YELLOW}━━━ 生成落地部署码 (新落地机) ━━━${NC}"
    [ ! -f "$WG_CONF" ] && echo -e "${RED}请先初始化中转机${NC}" && pause_return && return
    
    while true; do 
        read -p "节点名称: " NODE_NAME < /dev/tty
        [ -n "$NODE_NAME" ] && check_node_name "$NODE_NAME" && break
    done
    
    MAX_IP=1
    for ip in $(grep "^AllowedIPs = 10.0.0." "$WG_CONF" | awk '{print $3}' | cut -d. -f4 | cut -d/ -f1); do 
        [ "$ip" -gt "$MAX_IP" ] && MAX_IP=$ip
    done
    [ "$MAX_IP" -ge 250 ] && echo -e "${RED}❌ IP池已耗尽${NC}" && pause_return && return
    LAND_IP="10.0.0.$((MAX_IP + 1))"
    RELAY_PUB=$(grep "^PrivateKey" "$WG_CONF" | awk '{print $3}' | wg pubkey)
    
    while true; do
        read -p "客户端端口: " MAP_PORT < /dev/tty
        [[ "$MAP_PORT" =~ ^[0-9]+$ ]] && [ "$MAP_PORT" -ge 1 ] && [ "$MAP_PORT" -le 65535 ] && [ "$MAP_PORT" != "$WG_PORT" ] && break
        echo -e "${RED}端口无效${NC}"
    done
    
    RELAY_IP=$(get_pub_ip)
    [ -z "$RELAY_IP" ] && echo -e "${RED}无法获取公网IP${NC}" && pause_return && return
    
    DEPLOY_CODE=$(echo -n "${RELAY_IP}|${RELAY_PUB}|${LAND_IP}|${MAP_PORT}|${NODE_NAME}" | base64 -w 0 | tr -d '\n')
    echo -e "${GREEN}=========================================="
    echo -e " ${CYAN}${DEPLOY_CODE}${NC}"
    echo -e "=========================================="
    pause_return
}

deploy_landing() {
    clear; echo -e "${YELLOW}━━━ 落地机一键部署 (新落地机) ━━━${NC}"
    read -p "请粘贴部署码: " DEPLOY_CODE < /dev/tty
    DEPLOY_CODE=$(echo "$DEPLOY_CODE" | tr -d '[:space:]')
    CODE_RAW=$(echo -n "$DEPLOY_CODE" | base64 -d 2>/dev/null)
    [ -z "$CODE_RAW" ] || ! echo "$CODE_RAW" | grep -q "|" && echo -e "${RED}❌ 部署码无效！${NC}" && pause_return && return

    RELAY_IP=$(echo $CODE_RAW | cut -d'|' -f1); RELAY_PUB=$(echo $CODE_RAW | cut -d'|' -f2)
    LAND_IP=$(echo $CODE_RAW | cut -d'|' -f3); MAP_PORT=$(echo $CODE_RAW | cut -d'|' -f4); NODE_NAME=$(echo $CODE_RAW | cut -d'|' -f5)
    [ -z "$RELAY_IP" ] || [ -z "$MAP_PORT" ] || [ -z "$LAND_IP" ] && echo -e "${RED}❌ 致命错误：IP或端口为空！${NC}" && pause_return && return

    while true; do
        read -p "落地机监听端口 (默认 443): " LAND_PORT < /dev/tty
        [ -z "$LAND_PORT" ] && LAND_PORT=443
        ss -tulnp | grep -qE ":$LAND_PORT\b" && echo -e "${RED}❌ 端口 $LAND_PORT 已被占用！请换一个：${NC}" || break
    done

    echo -e "${YELLOW}[*] 安装 WG 与 Sing-box...${NC}"
    kill_apt_locks; apt-get install -y wireguard > /dev/null 2>&1
    install_singbox || { echo -e "${RED}Sing-box 安装失败${NC}"; pause_return; return; }
    
    SNI=$(select_best_sni)

    mkdir -p /etc/wireguard
    WG_PRIV=$(wg genkey); WG_PUB=$(echo "$WG_PRIV" | wg pubkey)
    cat > $WG_CONF << EOF
[Interface]
PrivateKey = $WG_PRIV
Address = ${LAND_IP}/24
ListenPort = $WG_PORT
MTU = 1380
[Peer]
PublicKey = $RELAY_PUB
AllowedIPs = 10.0.0.1/32
Endpoint = ${RELAY_IP}:$WG_PORT
PersistentKeepalive = 25
EOF
    
    mkdir -p /etc/sysctl.d
    echo "net.ipv4.ip_forward = 1" > "$IP_FORWARD_FILE"
    sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1
    sysctl -p "$IP_FORWARD_FILE" > /dev/null 2>&1
    
    local default_if=$(ip route show default | awk '/default/ {print $5}')
    [ -z "$default_if" ] && echo -e "${RED}❌ 无法获取默认网卡名称！${NC}" && pause_return && return
    while iptables -t nat -D POSTROUTING -s $WG_NET -o $default_if -j MASQUERADE 2>/dev/null; do :; done
    iptables -t nat -A POSTROUTING -s $WG_NET -o $default_if -j MASQUERADE
    netfilter-persistent save > /dev/null 2>&1
    
    REALITY_KEYS=$(/usr/local/bin/sing-box generate reality-keypair 2>/dev/null)
    SB_PRIV=$(echo "$REALITY_KEYS" | grep PrivateKey | awk '{print $2}'); SB_PUB=$(echo "$REALITY_KEYS" | grep PublicKey | awk '{print $2}')
    UUID=$(/usr/local/bin/sing-box generate uuid 2>/dev/null); SHORT_ID=$(/usr/local/bin/sing-box generate rand --hex 8 2>/dev/null)
    [ -z "$SB_PUB" ] || [ -z "$UUID" ] && echo -e "${RED}❌ 密钥生成失败！${NC}" && pause_return && return

    cat > /etc/sing-box/config.json << EOF
{
  "inbounds": [{
    "type": "vless", "listen": "0.0.0.0", "listen_port": ${LAND_PORT},
    "users": [{ "name": "u1", "uuid": "$UUID", "flow": "xtls-rprx-vision" }],
    "tls": {
      "enabled": true, "server_name": "${SNI}",
      "alpn": ["h2", "http/1.1"],
      "reality": {
        "enabled": true,
        "handshake": { "server": "${SNI}", "server_port": 443 },
        "private_key": "$SB_PRIV", "short_id": ["$SHORT_ID"]
      }
    }
  }],
  "outbounds": [{ "type": "direct" }]
}
EOF

    systemctl enable wg-quick@wg0 > /dev/null 2>&1
    restart_wg || { pause_return; return; }
    systemctl enable sing-box > /dev/null 2>&1; systemctl restart sing-box
    
    allow_port "$LAND_PORT"
    allow_port "$WG_PORT"
    
    SAFE_NAME=$(url_encode "$NODE_NAME")
    VLESS_LINK="vless://${UUID}@${RELAY_IP}:${MAP_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${SB_PUB}&sid=${SHORT_ID}&spx=%2F&type=tcp#WG-${SAFE_NAME}"
    BIND_CODE=$(echo -n "${WG_PUB}|${LAND_IP}|${MAP_PORT}|${LAND_PORT}|${NODE_NAME}" | base64 -w 0 | tr -d '\n')
    
    touch "$LAND_INFO"
    sed -i "/# ${NODE_NAME} START/,/# ${NODE_NAME} END/d" "$LAND_INFO"
    cat >> "$LAND_INFO" << EOF
# ${NODE_NAME} START
节点名称: $NODE_NAME
中转机IP: $RELAY_IP
客户端端口: $MAP_PORT
落地机端口: $LAND_PORT
SNI: $SNI
链接:
 $VLESS_LINK
# ${NODE_NAME} END
EOF
    
    echo -e "${GREEN}=========================================="
    echo -e " 落地机 [${NODE_NAME}] 部署成功！"
    echo -e " ${YELLOW}回传码：${NC}\n ${CYAN}${BIND_CODE}${NC}"
    echo -e " ${YELLOW}链接：${NC}\n ${GREEN}${VLESS_LINK}${NC}"
    echo -e "=========================================="
    pause_return
}

bind_landing() {
    clear; echo -e "${YELLOW}━━━ 绑定落地机 ━━━${NC}"
    read -p "请粘贴回传码: " BIND_CODE < /dev/tty
    BIND_CODE=$(echo "$BIND_CODE" | tr -d '[:space:]')
    CODE_RAW=$(echo -n "$BIND_CODE" | base64 -d 2>/dev/null)
    [ -z "$CODE_RAW" ] || ! echo "$CODE_RAW" | grep -q "|" && echo -e "${RED}绑定码无效${NC}" && pause_return && return
    
    LANDING_PUB=$(echo $CODE_RAW | cut -d'|' -f1); LAND_IP=$(echo $CODE_RAW | cut -d'|' -f2)
    MAP_PORT=$(echo $CODE_RAW | cut -d'|' -f3); LAND_PORT=$(echo $CODE_RAW | cut -d'|' -f4); NODE_NAME=$(echo $CODE_RAW | cut -d'|' -f5)
    
    sed -i "/# ${NODE_NAME}/,/AllowedIPs = ${LAND_IP}\/32/d" "$WG_CONF"
    echo -e "\n# ${NODE_NAME}\n[Peer]\nPublicKey = ${LANDING_PUB}\nAllowedIPs = ${LAND_IP}/32" >> "$WG_CONF"
    wg-quick down wg0 >/dev/null 2>&1
    restart_wg || { pause_return; return; }
    
    while iptables -t nat -D PREROUTING -p tcp --dport "$MAP_PORT" 2>/dev/null; do :; done
    while iptables -t nat -D PREROUTING -p udp --dport "$MAP_PORT" 2>/dev/null; do :; done
    while iptables -t nat -D POSTROUTING -d "$LAND_IP" -j MASQUERADE 2>/dev/null; do :; done
    iptables -D FORWARD -d "$LAND_IP" -j ACCEPT 2>/dev/null; iptables -D FORWARD -s "$LAND_IP" -j ACCEPT 2>/dev/null
    
    iptables -t nat -I PREROUTING 1 -p tcp --dport "$MAP_PORT" -j DNAT --to-destination "${LAND_IP}:${LAND_PORT}"
    iptables -t nat -I PREROUTING 1 -p udp --dport "$MAP_PORT" -j DNAT --to-destination "${LAND_IP}:${LAND_PORT}"
    iptables -t nat -I POSTROUTING 1 -d "$LAND_IP" -j MASQUERADE
    iptables -I FORWARD 1 -d "$LAND_IP" -j ACCEPT
    iptables -I FORWARD 1 -s "$LAND_IP" -j ACCEPT
    
    allow_port "$MAP_PORT"
    netfilter-persistent save > /dev/null 2>&1
    
    touch "$NODES_INFO"; sed -i "/|${NODE_NAME}$/d" "$NODES_INFO"; echo "${MAP_PORT}|${LAND_IP}|${LAND_PORT}|${NODE_NAME}" >> "$NODES_INFO"
    echo -e "${GREEN}✓ 节点 [${NODE_NAME}] 绑定成功${NC}"
    echo -e "${YELLOW}⚠️ 提醒：请确保中转机云后台已放行端口 ${MAP_PORT} (TCP/UDP)！${NC}"
    pause_return
}

check_root
prepare_env
while true; do
    clear
    echo -e "${CYAN}╔════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  WG 智能中转 v137.0 (SNI优选防假死版)     ║${NC}"
    echo -e "${CYAN}╠════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC} ${GREEN}1${NC} 系统优化    ${GREEN}2${NC} 中转-初始化    ${GREEN}3${NC} 中转-生成码    ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC} ${GREEN}4${NC} 落地-部署    ${GREEN}5${NC} 中转-绑定码    ${GREEN}6${NC} 中转-看列表    ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC} ${GREEN}7${NC} 落地-看信息  ${GREEN}8${NC} 中转-加端口    ${GREEN}9${NC} 落地-加端口    ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC} ${GREEN}a${NC} 中转-删端口  ${GREEN}b${NC} 落地-删端口    ${GREEN}c${NC} 查看-转发规则  ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC} ${GREEN}d${NC} 一键卸载    ${GREEN}e${NC} Ping-连通测试                ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC} ${GREEN}0${NC} 退出                                      ${CYAN}║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════╝${NC}"
    
    read -p "选: " c < /dev/tty
    case $c in
        1) tune_system;; 2) init_relay;; 3) gen_landing_code;; 4) deploy_landing;; 5) bind_landing;; 0) exit 0;; *) echo "错误"; sleep 1;;
    esac
done
