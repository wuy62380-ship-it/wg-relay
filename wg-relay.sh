#!/bin/bash
# ==========================================
# WireGuard 智能中转部署脚本 v10.0 (终极一体化版)
# ==========================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'
WG_CONF="/etc/wireguard/wg0.conf"
WG_PORT="51820"
SYSCTL_FILE="/etc/sysctl.d/99-wg-tune.conf"

# ================= 基础检查 =================
check_root() { [ "$EUID" -ne 0 ] && echo -e "${RED}请使用root运行${NC}" && exit 1; }

check_system() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [ "$ID" != "debian" ] && [ "$ID" != "ubuntu" ]; then
            echo -e "${RED}⚠️ 本脚本仅支持 Debian/Ubuntu 系统！${NC}"; exit 1
        fi
    else
        echo -e "${RED}⚠️ 无法识别操作系统${NC}"; exit 1
    fi
}

prepare_env() {
    echo -e "${YELLOW}正在准备基础环境 (1分钟)...${NC}"
    apt update -y > /dev/null 2>&1
    apt install -y curl wget gnupg ca-certificates iptables iptables-persistent tar > /dev/null 2>&1
    modprobe nf_conntrack 2>/dev/null
}

get_pub_ip() {
    local ip=$(curl -s -m 3 -4 ifconfig.me || curl -s -m 3 -4 ip.sb || curl -s -m 3 -4 api.ipify.org)
    if [ -z "$ip" ]; then echo -e "${RED}无法获取公网IP${NC}"; exit 1; fi
    echo "$ip"
}

# ================= 内置 Sing-box 安装 =================
install_singbox() {
    if command -v sing-box &> /dev/null; then return 0; fi
    echo -e "${YELLOW}正在内置下载 Sing-box...${NC}"
    ARCH=$(uname -m)
    if [ "$ARCH" == "x86_64" ]; then SB_ARCH="amd64";
    elif [ "$ARCH" == "aarch64" ]; then SB_ARCH="arm64";
    else echo -e "${RED}不支持的架构: $ARCH${NC}"; return 1; fi
    
    SB_VER="1.8.5"
    URL="https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/sing-box-${SB_VER}-linux-${SB_ARCH}.tar.gz"
    
    # 优先直连，失败走加速
    wget -qO /tmp/sb.tar.gz "$URL" || wget -qO /tmp/sb.tar.gz "https://ghproxy.net/$URL"
    if [ ! -s /tmp/sb.tar.gz ]; then
        echo -e "${RED}Sing-box 下载失败！请检查网络。${NC}"
        return 1
    fi
    
    tar -xzf /tmp/sb.tar.gz -C /tmp
    mv /tmp/sing-box-${SB_VER}-linux-${SB_ARCH}/sing-box /usr/local/bin/
    chmod +x /usr/local/bin/sing-box
    rm -rf /tmp/sb.tar.gz /tmp/sing-box-*
    
    cat > /etc/systemd/system/sing-box.service << EOF
[Unit]
Description=sing-box service
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
    mkdir -p /etc/sing-box
    systemctl daemon-reload
    echo -e "${GREEN}✓ Sing-box 安装成功${NC}"
}

# ================= BBRv3 内核与极限调优 =================
apply_gateway_tune() {
    local CONF="${SYSCTL_FILE}"
    local MEM_MB_VAL=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    local RMEM_MAX=8388608; local TCP_RMEM="4096 16384 8388608"
    if [ "$MEM_MB_VAL" -lt 1024 ]; then RMEM_MAX=4194304; TCP_RMEM="4096 32768 4194304"; fi
    cat > "$CONF" << EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = $RMEM_MAX
net.ipv4.tcp_rmem = $TCP_RMEM
net.core.somaxconn = 65535
net.ipv4.tcp_fastopen = 3
net.netfilter.nf_conntrack_max = 1048576
net.ipv4.ip_forward = 1
vm.swappiness = 10
EOF
    sysctl -p "$CONF" > /dev/null 2>&1
}

tune_system() {
    clear
    echo -e "${YELLOW}━━━ 系统极限优化 ━━━${NC}"
    if uname -r | grep -qi "xanmod"; then
        echo -e "${GREEN}✓ 已是 XanMod 内核，应用网关调优...${NC}"
        apply_gateway_tune
    else
        echo -e "${YELLOW}未检测到 XanMod 内核。${NC}"
        echo -e "  ${GRAY}1${NC} 安装 XanMod BBRv3 内核 (需重启)"
        echo -e "  ${GRAY}2${NC} 跳过安装，直接应用普通 BBR 调优"
        read -p "请选择 [1/2]: " c
        case $c in
            1) 
                apt install -y wget gnupg ca-certificates > /dev/null 2>&1
                mkdir -p /usr/share/keyrings /etc/apt/sources.list.d
                wget -qO - "https://dl.xanmod.org/archive.key" | gpg --dearmor -o /usr/share/keyrings/xanmod-archive-keyring.gpg --yes 2>/dev/null
                echo "deb [signed-by=/usr/share/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org releases main" > /etc/apt/sources.list.d/xanmod-release.list
                apt update > /dev/null 2>&1
                echo -e "${YELLOW}正在安装 XanMod 内核 (可能需要几分钟)...${NC}"
                apt install -y linux-xanmod-x64v3 > /dev/null 2>&1
                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}✓ 内核安装成功！请重启服务器后再次运行本脚本，选择选项1应用调优。${NC}"
                    read -p "按回车键重启..." && reboot
                else
                    echo -e "${RED}内核安装失败，改用普通调优。${NC}"
                    apply_gateway_tune
                fi
                ;;
            2) apply_gateway_tune ;;
        esac
    fi
    echo -e "${GREEN}✓ 优化完成！${NC}"
}

# ================= 1. 中转机初始化 =================
init_relay() {
    clear
    echo -e "${YELLOW}━━━ 初始化中转机 ━━━${NC}"
    if [ -f "$WG_CONF" ]; then
        read -p "${RED}⚠️ 已有配置将被覆盖！确定？${NC} [y/N]: " confirm
        [[ ! "$confirm" =~ ^[Yy]$ ]] && return
    fi
    apt install -y wireguard > /dev/null 2>&1
    WG_PRIV=$(wg genkey); WG_PUB=$(echo "$WG_PRIV" | wg pubkey); RELAY_IP=$(get_pub_ip)
    cat > $WG_CONF << EOF
[Interface]
PrivateKey = $WG_PRIV
Address = 10.0.0.1/24
ListenPort = $WG_PORT
MTU = 1380
EOF
    systemctl enable wg-quick@wg0 > /dev/null 2>&1
    wg-quick down wg0 > /dev/null 2>&1; wg-quick up wg0 > /dev/null 2>&1
    echo -e "${GREEN}=========================================="
    echo -e " 中转机初始化成功！IP: ${CYAN}${RELAY_IP}${NC}"
    echo -e " 中转机公钥: ${CYAN}${WG_PUB}${NC}"
    echo -e "=========================================="
}

# ================= 2. 生成落地部署码 =================
gen_landing_code() {
    clear
    echo -e "${YELLOW}━━━ 生成落地部署码 ━━━${NC}"
    if [ ! -f "$WG_CONF" ]; then echo -e "${RED}请先初始化中转机${NC}"; return; fi
    while true; do
        read -p "请输入节点名称 (支持中文): " NODE_NAME
        if [ -z "$NODE_NAME" ] || [[ "$NODE_NAME" =~ [\/\\\|\&] ]]; then echo -e "${RED}名称为空或含非法字符${NC}"; else break; fi
    done
    MAX_IP=1
    for ip in $(grep "^AllowedIPs = 10.0.0." $WG_CONF | awk '{print $3}' | cut -d'.' -f4 | cut -d'/' -f1); do [ "$ip" -gt "$MAX_IP" ] && MAX_IP=$ip; done
    LAND_IP="10.0.0.$((MAX_IP + 1))"
    while true; do
        read -p "客户端连接端口 (1-65535): " MAP_PORT
        if [ "$MAP_PORT" != "$WG_PORT" ] && [[ "$MAP_PORT" =~ ^[0-9]+$ ]] && [ "$MAP_PORT" -ge 1 ] && [ "$MAP_PORT" -le 65535 ]; then break; fi
        echo -e "${RED}端口无效或与隧道冲突${NC}"
    done
    RELAY_IP=$(get_pub_ip); RELAY_PUB=$(grep "^PrivateKey" $WG_CONF | awk '{print $3}' | wg pubkey)
    DEPLOY_CODE=$(echo -n "${RELAY_IP}|${RELAY_PUB}|${LAND_IP}|${MAP_PORT}|${NODE_NAME}" | base64)
    echo -e "${GREEN}=========================================="
    echo -e " 部署码 (内网IP: ${LAND_IP}, 端口: ${MAP_PORT})"
    echo -e " ${CYAN}${DEPLOY_CODE}${NC}"
    echo -e "==========================================${NC}"
}

# ================= 3. 落地机一键部署 =================
deploy_landing() {
    clear
    echo -e "${YELLOW}━━━ 落地机一键部署 ━━━${NC}"
    read -p "请粘贴部署码: " DEPLOY_CODE
    CODE_RAW=$(echo -n "$DEPLOY_CODE" | base64 -d 2>/dev/null)
    if [ -z "$CODE_RAW" ] || ! echo "$CODE_RAW" | grep -q "|"; then echo -e "${RED}部署码无效！${NC}"; return; fi
    RELAY_IP=$(echo $CODE_RAW | cut -d'|' -f1); RELAY_PUB=$(echo $CODE_RAW | cut -d'|' -f2)
    LAND_IP=$(echo $CODE_RAW | cut -d'|' -f3); MAP_PORT=$(echo $CODE_RAW | cut -d'|' -f4); NODE_NAME=$(echo $CODE_RAW | cut -d'|' -f5)
    
    apt install -y wireguard > /dev/null 2>&1
    if ! install_singbox; then return; fi

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
Endpoint = $RELAY_IP:$WG_PORT
PersistentKeepalive = 25
EOF
    grep -q "^net.ipv4.ip_forward = 1" /etc/sysctl.conf || echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
    sysctl -p > /dev/null 2>&1
    iptables -t nat -D POSTROUTING -o $(ip route show default | awk '/default/ {print $5}') -j MASQUERADE 2>/dev/null
    iptables -t nat -A POSTROUTING -o $(ip route show default | awk '/default/ {print $5}') -j MASQUERADE
    netfilter-persistent save > /dev/null 2>&1

    REALITY_KEYS=$(/usr/local/bin/sing-box generate reality-keypair)
    SB_PRIV=$(echo "$REALITY_KEYS" | grep PrivateKey | awk '{print $2}'); SB_PUB=$(echo "$REALITY_KEYS" | grep PublicKey | awk '{print $2}')
    UUID=$(/usr/local/bin/sing-box generate uuid); SHORT_ID=$(/usr/local/bin/sing-box generate rand --hex 8)
    cat > /etc/sing-box/config.json << EOF
{
  "inbounds": [{
    "type": "vless", "listen": "::", "listen_port": 443,
    "users": [{ "name": "u1", "uuid": "$UUID", "flow": "xtls-rprx-vision" }],
    "tls": {
      "enabled": true, "server_name": "www.microsoft.com",
      "reality": {
        "enabled": true,
        "handshake": { "server": "www.microsoft.com", "server_port": 443 },
        "private_key": "$SB_PRIV", "short_id": ["$SHORT_ID"]
      }
    }
  }],
  "outbounds": [{ "type": "direct" }]
}
EOF
    systemctl enable wg-quick@wg0 > /dev/null 2>&1; wg-quick down wg0 > /dev/null 2>&1; wg-quick up wg0 > /dev/null 2>&1
    systemctl enable sing-box > /dev/null 2>&1; systemctl restart sing-box
    
    SAFE_NAME=$(echo $NODE_NAME | tr ' ' '_')
    VLESS_LINK="vless://${UUID}@${RELAY_IP}:${MAP_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=${SB_PUB}&sid=${SHORT_ID}&type=tcp#WG-${SAFE_NAME}"
    BIND_CODE=$(echo -n "${WG_PUB}|${LAND_IP}|${MAP_PORT}|${NODE_NAME}" | base64)
    echo -e "${GREEN}=========================================="
    echo -e " 落地机 [${NODE_NAME}] 部署成功！"
    echo -e " ${YELLOW}回传绑定码：${NC}\n ${CYAN}${BIND_CODE}${NC}"
    echo -e " ${YELLOW}客户端链接：${NC}\n ${GREEN}${VLESS_LINK}${NC}"
    echo -e "==========================================${NC}"
}

# ================= 4. 绑定落地机 =================
bind_landing() {
    clear
    echo -e "${YELLOW}━━━ 绑定落地机 ━━━${NC}"
    read -p "请粘贴回传绑定码: " BIND_CODE
    CODE_RAW=$(echo -n "$BIND_CODE" | base64 -d 2>/dev/null)
    if [ -z "$CODE_RAW" ] || ! echo "$CODE_RAW" | grep -q "|"; then echo -e "${RED}绑定码无效！${NC}"; return; fi
    LANDING_PUB=$(echo $CODE_RAW | cut -d'|' -f1); LAND_IP=$(echo $CODE_RAW | cut -d'|' -f2)
    MAP_PORT=$(echo $CODE_RAW | cut -d'|' -f3); NODE_NAME=$(echo $CODE_RAW | cut -d'|' -f4)
    
    sed -i "/# ${NODE_NAME}/,/AllowedIPs = ${LAND_IP}\/32/d" $WG_CONF
    echo -e "\n# ${NODE_NAME}\n[Peer]\nPublicKey = $LANDING_PUB\nAllowedIPs = ${LAND_IP}/32" >> $WG_CONF
    wg-quick down wg0 > /dev/null 2>&1; wg-quick up wg0 > /dev/null 2>&1
    
    iptables -t nat -D PREROUTING -p tcp --dport $MAP_PORT -j DNAT --to-destination ${LAND_IP}:443 2>/dev/null
    iptables -t nat -D PREROUTING -p udp --dport $MAP_PORT -j DNAT --to-destination ${LAND_IP}:443 2>/dev/null
    iptables -t nat -D POSTROUTING -d ${LAND_IP} -j MASQUERADE 2>/dev/null
    iptables -D FORWARD -d ${LAND_IP} -j ACCEPT 2>/dev/null; iptables -D FORWARD -s ${LAND_IP} -j ACCEPT 2>/dev/null
    iptables -D INPUT -p tcp --dport $MAP_PORT -j ACCEPT 2>/dev/null; iptables -D INPUT -p udp --dport $MAP_PORT -j ACCEPT 2>/dev/null
    
    iptables -t nat -A PREROUTING -p tcp --dport $MAP_PORT -j DNAT --to-destination ${LAND_IP}:443
    iptables -t nat -A PREROUTING -p udp --dport $MAP_PORT -j DNAT --to-destination ${LAND_IP}:443
    iptables -t nat -A POSTROUTING -d ${LAND_IP} -j MASQUERADE
    iptables -A FORWARD -d ${LAND_IP} -j ACCEPT; iptables -A FORWARD -s ${LAND_IP} -j ACCEPT
    iptables -A INPUT -p tcp --dport $MAP_PORT -j ACCEPT; iptables -A INPUT -p udp --dport $MAP_PORT -j ACCEPT
    netfilter-persistent save > /dev/null 2>&1
    echo -e "${GREEN}✓ 节点 [${NODE_NAME}] 绑定成功！隧道已打通。${NC}"
}

# ================= 主循环 =================
check_root; check_system; prepare_env
while true; do
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║    WireGuard 智能中转部署工具 v10.0 (终极一体化版)    ║${NC}"
    echo -e "${CYAN}╠═══════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC}  ${GREEN}1${NC}  ⚡ 系统极限优化 (内置BBRv3内核安装+网关调优)        ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  ${GREEN}2${NC}  [中转机] 初始化网关                               ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  ${GREEN}3${NC}  [中转机] 生成落地部署码 (可自定义端口)            ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  ${GREEN}4${NC}  [落地机] 粘贴部署码一键部署 (内置Sing-box下载)    ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  ${GREEN}5${NC}  [中转机] 粘贴回传码完成绑定                       ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  ${GREEN}0${NC}  退出                                             ${CYAN}║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════╝${NC}"
    read -p "请输入选项: " choice
    case $choice in
        1) tune_system ;;
        2) init_relay ;;
        3) gen_landing_code ;;
        4) deploy_landing ;;
        5) bind_landing ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${NC}"; sleep 1 ;;
    esac
    read -p "按 Enter 键继续..."
done
