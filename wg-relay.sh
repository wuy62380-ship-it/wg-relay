#!/bin/bash
# ==========================================
# WireGuard 智能中转部署脚本 v9.4 (彻底修复中文支持)
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
    echo -e "${YELLOW}正在初始化环境...${NC}"
    apt update > /dev/null 2>&1
    apt install -y curl wget gnupg ca-certificates iptables iptables-persistent > /dev/null 2>&1
    modprobe nf_conntrack 2>/dev/null
}

get_pub_ip() {
    local ip=$(curl -s -m 3 -4 ifconfig.me || curl -s -m 3 -4 ip.sb || curl -s -m 3 -4 api.ipify.org)
    if [ -z "$ip" ]; then
        echo -e "${RED}无法自动获取公网IP，请检查网络！${NC}"
        exit 1
    fi
    echo "$ip"
}

# ================= 系统极限调优 =================
tune_system() {
    clear
    echo -e "${YELLOW}━━━ 执行系统极限调优 ━━━${NC}"
    cat > $SYSCTL_FILE << EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 8388608
net.core.wmem_max = 8388608
net.ipv4.tcp_rmem = 4096 16384 8388608
net.ipv4.tcp_wmem = 4096 16384 8388608
net.core.somaxconn = 65535
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.netfilter.nf_conntrack_max = 1048576
net.ipv4.ip_forward = 1
vm.swappiness = 10
vm.min_free_kbytes = 32768
EOF
    sysctl -p $SYSCTL_FILE > /dev/null 2>&1
    for dir in /sys/class/net/*/queues/rx-*; do [ -f "$dir/rps_cpus" ] && echo ff > "$dir/rps_cpus" 2>/dev/null; done
    echo -e "${GREEN}✓ 调优完成！${NC}"
}

# ================= 1. 中转机初始化 =================
init_relay() {
    clear
    echo -e "${YELLOW}━━━ 初始化中转机 ━━━${NC}"
    
    if [ -f "$WG_CONF" ]; then
        read -p "${RED}⚠️ 检测到已有配置，继续将覆盖并清空所有节点！确定？${NC} [y/N]: " confirm
        [[ ! "$confirm" =~ ^[Yy]$ ]] && return
    fi

    echo -e "${YELLOW}正在安装 WireGuard...${NC}"
    apt install -y wireguard > /dev/null 2>&1
    WG_PRIV=$(wg genkey)
    WG_PUB=$(echo "$WG_PRIV" | wg pubkey)
    RELAY_IP=$(get_pub_ip)

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
    echo -e " 中转机初始化成功！"
    echo -e "=========================================="
    echo -e " 中转机IP : ${CYAN}${RELAY_IP}${NC}"
    echo -e " 中转机公钥: ${CYAN}${WG_PUB}${NC}"
    echo -e "=========================================="
}

# ================= 2. 生成落地部署码 =================
gen_landing_code() {
    clear
    echo -e "${YELLOW}━━━ 生成落地部署码 ━━━${NC}"
    if [ ! -f "$WG_CONF" ]; then echo -e "${RED}请先初始化中转机${NC}"; return; fi

    while true; do
        read -p "请输入节点名称 (支持中文，但不能含 / \ | & 等符号): " NODE_NAME
        if [ -z "$NODE_NAME" ]; then
            echo -e "${RED}名称不能为空，请重新输入！${NC}"
            continue
        fi
        # 检查是否包含会导致 sed 崩溃的危险字符
        if [[ "$NODE_NAME" =~ [\/\\\|\&] ]]; then
            echo -e "${RED}名称包含非法字符（不能有 / \ | & 等），请重新输入！${NC}"
        else
            break
        fi
    done

    MAX_IP=1
    for ip in $(grep "^AllowedIPs = 10.0.0." $WG_CONF | awk '{print $3}' | cut -d'.' -f4 | cut -d'/' -f1); do
        [ "$ip" -gt "$MAX_IP" ] && MAX_IP=$ip
    done
    NEXT_IP=$((MAX_IP + 1))
    LAND_IP="10.0.0.${NEXT_IP}"

    while true; do
        read -p "请输入客户端连接端口 (1-65535): " MAP_PORT
        if [ "$MAP_PORT" == "$WG_PORT" ]; then
            echo -e "${RED}错误：不能使用 WireGuard 隧道端口 $WG_PORT！${NC}"
            continue
        fi
        if [[ "$MAP_PORT" =~ ^[0-9]+$ ]] && [ "$MAP_PORT" -ge 1 ] && [ "$MAP_PORT" -le 65535 ]; then
            if iptables -t nat -L PREROUTING -n 2>/dev/null | grep -q "dpt:$MAP_PORT"; then
                 echo -e "${RED}端口 $MAP_PORT 已被占用！${NC}"
            else
                 break
            fi
        else
            echo -e "${RED}端口必须是1-65535的数字！${NC}"
        fi
    done

    RELAY_IP=$(get_pub_ip)
    RELAY_PUB=$(grep "^PrivateKey" $WG_CONF | awk '{print $3}' | wg pubkey)
    
    CODE_RAW="${RELAY_IP}|${RELAY_PUB}|${LAND_IP}|${MAP_PORT}|${NODE_NAME}"
    DEPLOY_CODE=$(echo -n "$CODE_RAW" | base64)

    echo -e "${GREEN}=========================================="
    echo -e " 部署码已生成！(内网IP: ${LAND_IP}, 端口: ${MAP_PORT})"
    echo -e "=========================================="
    echo -e " ${YELLOW}请复制部署码，去落地机执行选项3：${NC}"
    echo -e " ${CYAN}${DEPLOY_CODE}${NC}"
    echo -e "==========================================${NC}"
}

# ================= 3. 落地机一键部署 =================
deploy_landing() {
    clear
    echo -e "${YELLOW}━━━ 落地机一键部署 ━━━${NC}"
    read -p "请粘贴部署码: " DEPLOY_CODE
    [ -z "$DEPLOY_CODE" ] && return

    CODE_RAW=$(echo -n "$DEPLOY_CODE" | base64 -d 2>/dev/null)
    if [ -z "$CODE_RAW" ] || ! echo "$CODE_RAW" | grep -q "|"; then
        echo -e "${RED}部署码无效！${NC}"; return
    fi

    RELAY_IP=$(echo $CODE_RAW | cut -d'|' -f1)
    RELAY_PUB=$(echo $CODE_RAW | cut -d'|' -f2)
    LAND_IP=$(echo $CODE_RAW | cut -d'|' -f3)
    MAP_PORT=$(echo $CODE_RAW | cut -d'|' -f4)
    NODE_NAME=$(echo $CODE_RAW | cut -d'|' -f5)

    echo -e "${YELLOW}正在部署 [${NODE_NAME}]...${NC}"
    apt install -y wireguard > /dev/null 2>&1
    
    if ! command -v sing-box &> /dev/null; then
        echo -e "${YELLOW}正在安装 Sing-box...${NC}"
        bash <(curl -fsSL https://sing-box.app/deb-install.sh) > /dev/null 2>&1
        hash -r
        if ! command -v sing-box &> /dev/null; then echo -e "${RED}Sing-box安装失败${NC}"; return; fi
    fi

    DEFAULT_IF=$(ip route show default | awk '/default/ {print $5}')
    WG_PRIV=$(wg genkey)
    WG_PUB=$(echo "$WG_PRIV" | wg pubkey)

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

    if ! grep -q "^net.ipv4.ip_forward = 1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
    fi
    sysctl -p > /dev/null 2>&1
    
    iptables -t nat -D POSTROUTING -o $DEFAULT_IF -j MASQUERADE 2>/dev/null
    iptables -t nat -A POSTROUTING -o $DEFAULT_IF -j MASQUERADE
    netfilter-persistent save > /dev/null 2>&1

    REALITY_KEYS=$(sing-box generate reality-keypair)
    SB_PRIV=$(echo "$REALITY_KEYS" | grep PrivateKey | awk '{print $2}')
    SB_PUB=$(echo "$REALITY_KEYS" | grep PublicKey | awk '{print $2}')
    UUID=$(sing-box generate uuid)
    SHORT_ID=$(sing-box generate rand --hex 8)

    cat > /etc/sing-box/config.json << EOF
{
  "inbounds": [{
    "type": "vless", "listen": "::", "listen_port": 443,
    "users": [{ "name": "user1", "uuid": "$UUID", "flow": "xtls-rprx-vision" }],
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

    echo -e "\n${GREEN}=========================================="
    echo -e " 落地机 [${NODE_NAME}] 部署成功！"
    echo -e "=========================================="
    echo -e " ${YELLOW}复制【回传绑定码】回中转机执行选项4：${NC}"
    echo -e " ${CYAN}${BIND_CODE}${NC}"
    echo -e "------------------------------------------"
    echo -e " ${YELLOW}客户端导入链接：${NC}"
    echo -e " ${GREEN}${VLESS_LINK}${NC}"
    echo -e "==========================================${NC}"
}

# ================= 4. 绑定落地机 =================
bind_landing() {
    clear
    echo -e "${YELLOW}━━━ 绑定落地机 ━━━${NC}"
    read -p "请粘贴回传绑定码: " BIND_CODE
    [ -z "$BIND_CODE" ] && return

    CODE_RAW=$(echo -n "$BIND_CODE" | base64 -d 2>/dev/null)
    if [ -z "$CODE_RAW" ] || ! echo "$CODE_RAW" | grep -q "|"; then
        echo -e "${RED}绑定码无效！${NC}"; return
    fi

    LANDING_PUB=$(echo $CODE_RAW | cut -d'|' -f1)
    LAND_IP=$(echo $CODE_RAW | cut -d'|' -f2)
    MAP_PORT=$(echo $CODE_RAW | cut -d'|' -f3)
    NODE_NAME=$(echo $CODE_RAW | cut -d'|' -f4)

    # 清理可能存在的同名旧节点
    sed -i "/# ${NODE_NAME}/,/AllowedIPs = ${LAND_IP}\/32/d" $WG_CONF
    echo -e "\n# ${NODE_NAME}\n[Peer]\nPublicKey = $LANDING_PUB\nAllowedIPs = ${LAND_IP}/32" >> $WG_CONF
    
    echo -e "${YELLOW}⚠️ 重启 WG 隧道 (瞬断1秒)...${NC}"
    wg-quick down wg0 > /dev/null 2>&1; wg-quick up wg0 > /dev/null 2>&1

    iptables -t nat -D PREROUTING -p tcp --dport $MAP_PORT -j DNAT --to-destination ${LAND_IP}:443 2>/dev/null
    iptables -t nat -D PREROUTING -p udp --dport $MAP_PORT -j DNAT --to-destination ${LAND_IP}:443 2>/dev/null
    iptables -t nat -D POSTROUTING -d ${LAND_IP} -j MASQUERADE 2>/dev/null
    iptables -D FORWARD -d ${LAND_IP} -j ACCEPT 2>/dev/null
    iptables -D FORWARD -s ${LAND_IP} -j ACCEPT 2>/dev/null
    iptables -D INPUT -p tcp --dport $MAP_PORT -j ACCEPT 2>/dev/null
    iptables -D INPUT -p udp --dport $MAP_PORT -j ACCEPT 2>/dev/null
    
    iptables -t nat -A PREROUTING -p tcp --dport $MAP_PORT -j DNAT --to-destination ${LAND_IP}:443
    iptables -t nat -A PREROUTING -p udp --dport $MAP_PORT -j DNAT --to-destination ${LAND_IP}:443
    iptables -t nat -A POSTROUTING -d ${LAND_IP} -j MASQUERADE
    
    iptables -A FORWARD -d ${LAND_IP} -j ACCEPT
    iptables -A FORWARD -s ${LAND_IP} -j ACCEPT
    
    iptables -A INPUT -p tcp --dport $MAP_PORT -j ACCEPT
    iptables -A INPUT -p udp --dport $MAP_PORT -j ACCEPT
    
    netfilter-persistent save > /dev/null 2>&1

    echo -e "${GREEN}=========================================="
    echo -e "✓ 节点 [${NODE_NAME}] 绑定成功！"
    echo -e "=========================================="
    echo -e " 客户端端口 : ${MAP_PORT}"
    echo -e " 隧道已打通！"
    echo -e "==========================================${NC}"
}

# ================= 主循环 =================
check_root
check_system
prepare_env

while true; do
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║    WireGuard 智能中转部署工具 v9.4 (中文修复版)       ║${NC}"
    echo -e "${CYAN}╠═══════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC}  ${GREEN}A${NC}  ⚡ 系统极限优化 (两台机器都要执行一次)           ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                                                       ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  ${GREEN}1${NC}  [中转机] 初始化网关                               ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  ${GREEN}2${NC}  [中转机] 生成落地部署码 (可自定义端口)            ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  ${GREEN}3${NC}  [落地机] 粘贴部署码一键部署                       ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  ${GREEN}4${NC}  [中转机] 粘贴回传码完成绑定                       ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                                                       ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  ${GREEN}0${NC}  退出                                             ${CYAN}║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════╝${NC}"
    read -p "请输入选项: " choice
    case $choice in
        [Aa]) tune_system ;;
        1) init_relay ;;
        2) gen_landing_code ;;
        3) deploy_landing ;;
        4) bind_landing ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${NC}"; sleep 1 ;;
    esac
    read -p "按 Enter 键继续..."
done
