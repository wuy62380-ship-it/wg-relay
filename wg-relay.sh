#!/bin/bash
# ==========================================
# WireGuard 智能中转部署脚本 v99.0 (终极纯粹版)
# 彻底解决：输入流污染、多行粘贴卡死、网络超时
# ==========================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'
WG_CONF="/etc/wireguard/wg0.conf"
NODES_INFO="/etc/wireguard/nodes_info.txt"
LAND_INFO="/etc/wireguard/landing_info.txt"
WG_PORT="51820"
SYSCTL_FILE="/etc/sysctl.d/99-wg-tune.conf"
SNI="www.microsoft.com" # 固定 SNI，不测速，防卡死

export DEBIAN_FRONTEND=noninteractive

check_root() { [ "$EUID" -ne 0 ] && echo -e "${RED}请使用root运行${NC}" && exit 1; }

# 极简暂停函数，强制从真实终端读取，杜绝任何缓冲区污染
pause_return() {
    echo -e "${YELLOW}按 Enter 键返回主菜单...${NC}"
    read -r < /dev/tty
}

kill_apt_locks() {
    rm -f /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock /var/lib/apt/lists/lock 2>/dev/null
    dpkg --configure -a 2>/dev/null
}

prepare_env() {
    echo -e "${YELLOW}正在准备环境...${NC}"
    kill_apt_locks
    apt-get update -y > /dev/null 2>&1
    apt-get install -y curl wget gnupg ca-certificates iptables iptables-persistent tar jq openssl coreutils > /dev/null 2>&1
    modprobe nf_conntrack 2>/dev/null
    echo -e "${GREEN}✓ 环境准备完毕${NC}"; sleep 1
}

get_pub_ip() {
    local ip=$(curl -s --connect-timeout 3 --max-time 5 -4 ifconfig.me || curl -s --connect-timeout 3 --max-time 5 -4 ip.sb)
    ip=$(echo "$ip" | tr -d '[:space:]')
    [ -z "$ip" ] && { echo -e "${RED}无法获取公网IP${NC}"; exit 1; }
    echo "$ip"
}

install_singbox() {
    if command -v sing-box &> /dev/null; then return 0; fi
    echo -e "${YELLOW}[*] 下载 Sing-box...${NC}"
    ARCH=$(uname -m)
    if [ "$ARCH" == "x86_64" ]; then SB_ARCH="amd64"; elif [ "$ARCH" == "aarch64" ]; then SB_ARCH="arm64"; else echo -e "${RED}不支持的架构${NC}"; return 1; fi
    
    SB_VER="1.8.7"
    URL="https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/sing-box-${SB_VER}-linux-${SB_ARCH}.tar.gz"
    
    # 双重保险：原生超时 + timeout 命令强制死刑
    timeout 30 wget -q -T 15 -t 2 -O /tmp/sb.tar.gz "$URL" 2>/dev/null || timeout 30 wget -q -T 15 -t 2 -O /tmp/sb.tar.gz "https://ghproxy.net/$URL" 2>/dev/null
    if [ ! -s /tmp/sb.tar.gz ]; then echo -e "${RED}下载失败${NC}"; return 1; fi
    
    tar -xzf /tmp/sb.tar.gz -C /tmp && mv /tmp/sing-box-${SB_VER}-linux-${SB_ARCH}/sing-box /usr/local/bin/ && chmod +x /usr/local/bin/sing-box
    rm -rf /tmp/sb.tar.gz /tmp/sing-box-*
    mkdir -p /etc/sing-box
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

url_encode() { jq -rn --arg v "$1" '$v|@uri'; }

tune_system() {
    clear; echo -e "${YELLOW}━━━ 系统极限优化 ━━━${NC}"
    echo -e "${YELLOW}[1/2] 停止后台自动更新...${NC}"
    systemctl stop apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1
    
    echo -e "${YELLOW}[2/2] 应用 BBR 与网关参数...${NC}"
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
net.netfilter.nf_conntrack_max = 1048576
vm.swappiness = 10
EOF
    sysctl -p "$SYSCTL_FILE" > /dev/null 2>&1
    for dir in /sys/class/net/*/queues/rx-*; do [ -f "$dir/rps_cpus" ] && echo ff > "$dir/rps_cpus" 2>/dev/null; done
    echo -e "${GREEN}✓ 优化完成！${NC}"; pause_return
}

init_relay() {
    clear; echo -e "${YELLOW}━━━ 初始化中转机 ━━━${NC}"
    if [ -f "$WG_CONF" ]; then
        read -p "${RED}已有配置将被覆盖！确定？[y/N]: ${NC}" c < /dev/tty
        [[ ! "$c" =~ ^[Yy]$ ]] && { pause_return; return; }
    fi
    kill_apt_locks; apt-get install -y wireguard > /dev/null 2>&1
    WG_PRIV=$(wg genkey); WG_PUB=$(echo "$WG_PRIV" | wg pubkey); RELAY_IP=$(get_pub_ip)
    cat > $WG_CONF << EOF
[Interface]
PrivateKey = $WG_PRIV
Address = 10.0.0.1/24
ListenPort = $WG_PORT
MTU = 1380
EOF
    systemctl enable wg-quick@wg0 > /dev/null 2>&1; wg-quick down wg0 > /dev/null 2>&1; wg-quick up wg0 > /dev/null 2>&1
    echo "" > "$NODES_INFO"
    echo -e "${GREEN}=========================================="
    echo -e " IP: ${CYAN}${RELAY_IP}${NC} | 公钥: ${CYAN}${WG_PUB}${NC}"
    echo -e "=========================================="
    pause_return
}

gen_landing_code() {
    clear; echo -e "${YELLOW}━━━ 生成落地部署码 ━━━${NC}"
    if [ ! -f "$WG_CONF" ]; then echo -e "${RED}请先初始化中转机${NC}"; pause_return; return; fi
    
    # 核心：所有 read 强制从 /dev/tty 读取，彻底杜绝管道污染
    while true; do read -p "节点名称: " NODE_NAME < /dev/tty; [ -n "$NODE_NAME" ] && break; echo -e "${RED}不能为空${NC}"; done
    
    MAX_IP=1
    for ip in $(grep "^AllowedIPs = 10.0.0." $WG_CONF | awk '{print $3}' | cut -d'.' -f4 | cut -d'/' -f1); do [ "$ip" -gt "$MAX_IP" ] && MAX_IP=$ip; done
    LAND_IP="10.0.0.$((MAX_IP + 1))"
    
    while true; do
        read -p "客户端端口: " MAP_PORT < /dev/tty
        [[ "$MAP_PORT" =~ ^[0-9]+$ ]] && [ "$MAP_PORT" -ge 1 ] && [ "$MAP_PORT" -le 65535 ] && [ "$MAP_PORT" != "$WG_PORT" ] && break
        echo -e "${RED}端口无效${NC}"
    done
    
    RELAY_IP=$(get_pub_ip); RELAY_PUB=$(grep "^PrivateKey" $WG_CONF | awk '{print $3}' | wg pubkey)
    
    # 强制绝对单行输出
    DEPLOY_CODE=$(echo -n "${RELAY_IP}|${RELAY_PUB}|${LAND_IP}|${MAP_PORT}|${NODE_NAME}" | base64 -w 0 | tr -d '\n')
    
    echo -e "${GREEN}=========================================="
    echo -e " ${CYAN}${DEPLOY_CODE}${NC}"
    echo -e "=========================================="
    pause_return
}

deploy_landing() {
    clear; echo -e "${YELLOW}━━━ 落地机一键部署 ━━━${NC}"
    
    read -p "请粘贴部署码: " DEPLOY_CODE < /dev/tty
    
    # 物理删除所有空白字符，容忍任何乱码粘贴
    DEPLOY_CODE=$(echo "$DEPLOY_CODE" | tr -d '[:space:]')
    CODE_RAW=$(echo -n "$DEPLOY_CODE" | base64 -d 2>/dev/null)
    
    if [ -z "$CODE_RAW" ] || ! echo "$CODE_RAW" | grep -q "|"; then 
        echo -e "${RED}❌ 部署码无效！${NC}"
        pause_return; return
    fi

    RELAY_IP=$(echo $CODE_RAW | cut -d'|' -f1); RELAY_PUB=$(echo $CODE_RAW | cut -d'|' -f2)
    LAND_IP=$(echo $CODE_RAW | cut -d'|' -f3); MAP_PORT=$(echo $CODE_RAW | cut -d'|' -f4); NODE_NAME=$(echo $CODE_RAW | cut -d'|' -f5)
    
    if [ -z "$RELAY_IP" ] || [ -z "$MAP_PORT" ] || [ -z "$LAND_IP" ]; then
        echo -e "${RED}❌ 致命错误：IP或端口为空！${NC}"
        pause_return; return
    fi

    read -p "落地机监听端口 (默认 443): " LAND_PORT < /dev/tty
    [ -z "$LAND_PORT" ] && LAND_PORT=443

    echo -e "${YELLOW}[*] 安装 WG 与 Sing-box...${NC}"
    kill_apt_locks; apt-get install -y wireguard > /dev/null 2>&1
    if ! install_singbox; then echo -e "${RED}Sing-box 安装失败${NC}"; pause_return; return; fi

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
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf; sysctl -p > /dev/null 2>&1
    iptables -t nat -A POSTROUTING -o $(ip route show default | awk '/default/ {print $5}') -j MASQUERADE
    netfilter-persistent save > /dev/null 2>&1
    
    REALITY_KEYS=$(/usr/local/bin/sing-box generate reality-keypair 2>/dev/null)
    SB_PRIV=$(echo "$REALITY_KEYS" | grep PrivateKey | awk '{print $2}'); SB_PUB=$(echo "$REALITY_KEYS" | grep PublicKey | awk '{print $2}')
    UUID=$(/usr/local/bin/sing-box generate uuid 2>/dev/null); SHORT_ID=$(/usr/local/bin/sing-box generate rand --hex 8 2>/dev/null)
    
    if [ -z "$SB_PUB" ] || [ -z "$UUID" ]; then
        echo -e "${RED}❌ 密钥生成失败！${NC}"
        pause_return; return
    fi

    cat > /etc/sing-box/config.json << EOF
{
  "inbounds": [{
    "type": "vless", "listen": "::", "listen_port": ${LAND_PORT},
    "users": [{ "name": "u1", "uuid": "$UUID", "flow": "xtls-rprx-vision" }],
    "tls": {
      "enabled": true, "server_name": "${SNI}",
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
    systemctl enable wg-quick@wg0 > /dev/null 2>&1; wg-quick down wg0 > /dev/null 2>&1; wg-quick up wg0 > /dev/null 2>&1
    systemctl enable sing-box > /dev/null 2>&1; systemctl restart sing-box
    
    SAFE_NAME=$(url_encode "$NODE_NAME")
    VLESS_LINK="vless://${UUID}@${RELAY_IP}:${MAP_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${SB_PUB}&sid=${SHORT_ID}&type=tcp#WG-${SAFE_NAME}"
    
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
    if [ -z "$CODE_RAW" ] || ! echo "$CODE_RAW" | grep -q "|"; then echo -e "${RED}绑定码无效${NC}"; pause_return; return; fi
    
    LANDING_PUB=$(echo $CODE_RAW | cut -d'|' -f1); LAND_IP=$(echo $CODE_RAW | cut -d'|' -f2)
    MAP_PORT=$(echo $CODE_RAW | cut -d'|' -f3); LAND_PORT=$(echo $CODE_RAW | cut -d'|' -f4); NODE_NAME=$(echo $CODE_RAW | cut -d'|' -f5)
    
    sed -i "/# ${NODE_NAME}/,/AllowedIPs = ${LAND_IP}\/32/d" $WG_CONF
    echo -e "\n# ${NODE_NAME}\n[Peer]\nPublicKey = $LANDING_PUB\nAllowedIPs = ${LAND_IP}/32" >> $WG_CONF
    wg-quick down wg0 > /dev/null 2>&1; wg-quick up wg0 > /dev/null 2>&1
    
    iptables -t nat -D PREROUTING -p tcp --dport $MAP_PORT -j DNAT --to-destination ${LAND_IP}:${LAND_PORT} 2>/dev/null
    iptables -t nat -D PREROUTING -p udp --dport $MAP_PORT -j DNAT --to-destination ${LAND_IP}:${LAND_PORT} 2>/dev/null
    iptables -t nat -D POSTROUTING -d ${LAND_IP} -j MASQUERADE 2>/dev/null
    iptables -D FORWARD -d ${LAND_IP} -j ACCEPT 2>/dev/null; iptables -D FORWARD -s ${LAND_IP} -j ACCEPT 2>/dev/null
    iptables -D INPUT -p tcp --dport $MAP_PORT -j ACCEPT 2>/dev/null; iptables -D INPUT -p udp --dport $MAP_PORT -j ACCEPT 2>/dev/null
    
    iptables -t nat -A PREROUTING -p tcp --dport $MAP_PORT -j DNAT --to-destination ${LAND_IP}:${LAND_PORT}
    iptables -t nat -A PREROUTING -p udp --dport $MAP_PORT -j DNAT --to-destination ${LAND_IP}:${LAND_PORT}
    iptables -t nat -A POSTROUTING -d ${LAND_IP} -j MASQUERADE
    iptables -A FORWARD -d ${LAND_IP} -j ACCEPT; iptables -A FORWARD -s ${LAND_IP} -j ACCEPT
    iptables -A INPUT -p tcp --dport $MAP_PORT -j ACCEPT; iptables -A INPUT -p udp --dport $MAP_PORT -j ACCEPT
    netfilter-persistent save > /dev/null 2>&1
    
    touch "$NODES_INFO"; sed -i "/|${NODE_NAME}$/d" "$NODES_INFO"; echo "${MAP_PORT}|${LAND_IP}|${LAND_PORT}|${NODE_NAME}" >> "$NODES_INFO"
    echo -e "${GREEN}✓ 节点 [${NODE_NAME}] 绑定成功${NC}"; pause_return
}

list_relay_nodes() {
    clear; echo -e "${YELLOW}━━━ 中转机节点列表 ━━━${NC}"
    if [ ! -f "$NODES_INFO" ]; then echo -e "${RED}暂无节点${NC}"; pause_return; return; fi
    printf "${GREEN}%-10s | %-15s | %-8s | %-15s\n${NC}" "端口" "落地IP" "落地端口" "名称"
    while IFS='|' read -r p lip lp n; do printf "%-10s | %-15s | %-8s | %-15s\n" "$p" "$lip" "$lp" "$n"; done < "$NODES_INFO"
    pause_return
}

list_landing_nodes() {
    clear; echo -e "${YELLOW}━━━ 落地机节点信息 ━━━${NC}"
    if [ ! -f "$LAND_INFO" ]; then echo -e "${RED}无记录${NC}"; pause_return; return; fi
    cat "$LAND_INFO"; pause_return
}

check_root
prepare_env
while true; do
    clear
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  WG 智能中转 v99.0 (终极纯粹版)     ║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC} ${GREEN}1${NC} 系统优化    ${GREEN}2${NC} 中转-初始化    ${GREEN}3${NC} 中转-生成码 ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC} ${GREEN}4${NC} 落地-部署    ${GREEN}5${NC} 中转-绑定码    ${GREEN}6${NC} 中转-看列表 ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC} ${GREEN}7${NC} 落地-看信息  ${GREEN}0${NC} 退出                      ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    
    read -p "选: " c < /dev/tty
    case $c in
        1) tune_system;; 2) init_relay;; 3) gen_landing_code;; 4) deploy_landing;; 5) bind_landing;; 6) list_relay_nodes;; 7) list_landing_nodes;; 0) exit 0;; *) echo "错误"; sleep 1;;
    esac
done
