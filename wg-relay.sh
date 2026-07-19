#!/bin/bash
# ==========================================
# WireGuard 智能中转部署脚本 v11.0 (融合军工级BBRv3与极限调优)
# ==========================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'
WG_CONF="/etc/wireguard/wg0.conf"
WG_PORT="51820"
SYSCTL_FILE="/etc/sysctl.d/99-yw-optimize.conf"

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
    # 安装必要的依赖 (增加了 jq, ethtool, iproute2 等，用于极限优化)
    apt install -y curl wget gnupg ca-certificates iptables iptables-persistent tar jq ethtool iproute2 procps kmod > /dev/null 2>&1
    modprobe nf_conntrack 2>/dev/null
    echo -e "${GREEN}✓ 环境准备完毕！${NC}"
    sleep 1
}

get_pub_ip() {
    local ip=$(curl -s -m 3 -4 ifconfig.me || curl -s -m 3 -4 ip.sb || curl -s -m 3 -4 api.ipify.org || curl -s -m 3 -4 ipv4.icanhazip.com)
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
    
    wget -qO /tmp/sb.tar.gz "$URL" || wget -qO /tmp/sb.tar.gz "https://ghproxy.net/$URL"
    if [ ! -s /tmp/sb.tar.gz ]; then echo -e "${RED}Sing-box 下载失败！${NC}"; return 1; fi
    
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
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
    mkdir -p /etc/sing-box
    systemctl daemon-reload
    echo -e "${GREEN}✓ Sing-box 安装成功${NC}"
}

# ================= 军工级 BBRv3 与极限调优模块 =================
xanmod_add_repo() {
    local keyring="/usr/share/keyrings/xanmod-archive-keyring.gpg" list_file="/etc/apt/sources.list.d/xanmod-release.list" os_codename=""
    if command -v lsb_release >/dev/null 2>&1; then os_codename=$(lsb_release -sc); elif [ -r /etc/os-release ]; then os_codename=$(. /etc/os-release && echo "$VERSION_CODENAME"); fi
    if ! echo "bookworm trixie forky sid noble plucky" | grep -qw "$os_codename"; then os_codename="releases"; fi
    if echo "jammy focal buster releases" | grep -qw "$os_codename"; then echo -e "${RED}XanMod 已停止对当前系统支持${NC}"; return 1; fi
    [ -z "$os_codename" ] && { echo "无法获取代号"; return 1; }
    apt-get install -y wget gnupg ca-certificates >/dev/null 2>&1; mkdir -p /usr/share/keyrings /etc/apt/sources.list.d
    wget -qO - "https://dl.xanmod.org/archive.key" | gpg --dearmor -o "$keyring" --yes 2>/dev/null
    if [ ! -s "$keyring" ]; then echo -e "${RED}❌ XanMod 密钥下载失败！${NC}"; return 1; fi
    chmod 644 "$keyring"
    echo "deb [signed-by=$keyring] http://deb.xanmod.org $os_codename main" > "$list_file"
}

xanmod_detect_package() {
    local arch=$(uname -m)
    if [ "$arch" = "aarch64" ]; then
        apt update -y >/dev/null 2>&1
        if apt-cache policy "linux-xanmod-arm64" 2>/dev/null | grep -q 'Candidate: [0-9]'; then printf '%s\n' "linux-xanmod-arm64"; return 0; fi
        return 1
    fi
    # 智能检测 CPU 支持的内核版本 (v3 > v2 > v1)
    local psabi_level=$(awk -F: '/^flags/{ if(/lm/&&/cmov/&&/cx8/&&/fpu/&&/fxsr/&&/mmx/&&/syscall/&&/sse2/) level=1; if(level==1&&/cx16/&&/lahf/&&/popcnt/&&/sse4_1/&&/sse4_2/&&/ssse3/) level=2; if(level==2&&/avx/&&/avx2/&&/bmi1/&&/bmi2/&&/f16c/&&/fma/&&/abm/&&/movbe/&&/xsave/) level=3; if(level>0){print level;exit} }' /proc/cpuinfo 2>/dev/null)
    if [ -z "$psabi_level" ]; then return 1; fi
    [ "$psabi_level" -gt 3 ] && psabi_level=3
    apt update -y >/dev/null 2>&1
    for prefix in linux-xanmod linux-xanmod-lts; do 
        local l="$psabi_level"
        while [ "$l" -ge 1 ]; do 
            local p="${prefix}-x64v${l}"
            if apt-cache policy "$p" 2>/dev/null | grep -q 'Candidate: [0-9]'; then printf '%s\n' "$p"; return 0; fi
            l=$((l-1))
        done
    done
    return 1
}

_kernel_optimize_core() {
    local CONF="${SYSCTL_FILE}"
    local MEM_MB_VAL=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    
    # 动态参数计算
    local RMEM_MAX=8388608 WMEM_MAX=8388608 TCP_RMEM="4096 16384 8388608" TCP_WMEM="4096 16384 8388608"
    local SOMAXCONN=65535 BACKLOG=100000 SYN_BACKLOG=8192 PORT_RANGE="1024 65535"
    local SWAPPINESS=10 DIRTY_RATIO=20 DIRTY_BG_RATIO=10 OVERCOMMIT=1 VFS_PRESSURE=50 MIN_FREE_KB=32768
    local FIN_TIMEOUT=30 KEEPALIVE_TIME=300 KEEPALIVE_INTVL=30 KEEPALIVE_PROBES=5
    local TCP_FASTOPEN=3 TCP_TW_REUSE=1 TCP_MTU_PROBING=1 TCP_NOTSENT_LOWAT=16384 TCP_SLOW_START_AFTER_IDLE=0 TCP_ECN=0
    local CC="bbr" QDISC="fq"

    # 内存自适应
    if [ "$MEM_MB_VAL" -ge 16384 ]; then MIN_FREE_KB=131072; SWAPPINESS=5
    elif [ "$MEM_MB_VAL" -ge 4096 ]; then MIN_FREE_KB=65536
    elif [ "$MEM_MB_VAL" -ge 1024 ]; then RMEM_MAX=16777216; WMEM_MAX=16777216; TCP_RMEM="4096 32768 16777216"; TCP_WMEM="4096 32768 16777216"
    else MIN_FREE_KB=16384; OVERCOMMIT=0; SWAPPINESS=10; RMEM_MAX=4194304; WMEM_MAX=4194304; SOMAXCONN=1024; BACKLOG=1000; TCP_RMEM="4096 32768 4194304"; TCP_WMEM="4096 32768 4194304"; fi

    # XanMod 强制 fq_pie
    if uname -r | grep -qi "xanmod"; then QDISC="fq_pie"; fi

    local TCP_MEM_MIN=$((MEM_MB_VAL * 256)) TCP_MEM_DEF=$((MEM_MB_VAL * 512)) TCP_MEM_MAX=$((MEM_MB_VAL * 1024))
    [ "$TCP_MEM_MIN" -lt 8192 ] && TCP_MEM_MIN=8192; [ "$TCP_MEM_DEF" -lt 16384 ] && TCP_MEM_DEF=16384; [ "$TCP_MEM_MAX" -lt 32768 ] && TCP_MEM_MAX=32768
    local TW_BUCKETS=$((SOMAXCONN * 4)) MAX_ORPHANS=$((SOMAXCONN * 2))
    [ "$TW_BUCKETS" -gt 524288 ] && TW_BUCKETS=524288; [ "$MAX_ORPHANS" -gt 131072 ] && MAX_ORPHANS=131072

    cat > "$CONF" << EOF
# YW 极限网关调优 (内存: ${MEM_MB_VAL}MB)
net.core.default_qdisc = $QDISC
net.ipv4.tcp_congestion_control = $CC
net.core.rmem_max = $RMEM_MAX
net.core.wmem_max = $WMEM_MAX
net.ipv4.tcp_rmem = $TCP_RMEM
net.ipv4.tcp_wmem = $TCP_WMEM
net.core.somaxconn = $SOMAXCONN
net.core.netdev_max_backlog = $BACKLOG
net.ipv4.tcp_max_syn_backlog = $SYN_BACKLOG
net.ipv4.tcp_fastopen = $TCP_FASTOPEN
net.ipv4.tcp_tw_reuse = $TCP_TW_REUSE
net.ipv4.tcp_fin_timeout = $FIN_TIMEOUT
net.ipv4.tcp_keepalive_time = $KEEPALIVE_TIME
net.ipv4.tcp_keepalive_intvl = $KEEPALIVE_INTVL
net.ipv4.tcp_keepalive_probes = $KEEPALIVE_PROBES
net.ipv4.tcp_max_tw_buckets = $TW_BUCKETS
net.ipv4.tcp_max_orphans = $MAX_ORPHANS
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_mtu_probing = $TCP_MTU_PROBING
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_notsent_lowat = $TCP_NOTSENT_LOWAT
net.ipv4.tcp_slow_start_after_idle = $TCP_SLOW_START_AFTER_IDLE
net.ipv4.tcp_ecn = $TCP_ECN
net.ipv4.ip_local_port_range = $PORT_RANGE
net.ipv4.tcp_mem = $TCP_MEM_MIN $TCP_MEM_DEF $TCP_MEM_MAX
vm.swappiness = $SWAPPINESS
vm.dirty_ratio = $DIRTY_RATIO
vm.dirty_background_ratio = $DIRTY_BG_RATIO
vm.overcommit_memory = $OVERCOMMIT
vm.min_free_kbytes = $MIN_FREE_KB
vm.vfs_cache_pressure = $VFS_PRESSURE
net.ipv4.ip_forward = 1
fs.file-max = 1048576
fs.nr_open = 1048576
net.netfilter.nf_conntrack_max = $((SOMAXCONN * 32))
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.core.optmem_max = 20480
EOF
    sysctl -p "$CONF" > /dev/null 2>&1
    # RPS 软中断多核优化
    for dir in /sys/class/net/*/queues/rx-*; do [ -f "$dir/rps_cpus" ] && echo ff > "$dir/rps_cpus" 2>/dev/null; done
}

tune_system() {
    clear
    echo -e "${YELLOW}━━━ 系统极限优化 ━━━${NC}"
    if uname -r | grep -qi "xanmod"; then
        echo -e "${GREEN}✓ 已是 XanMod 内核，直接应用极限调优...${NC}"
        _kernel_optimize_core
        echo -e "${GREEN}✓ 极限调优完成！${NC}"
    else
        echo -e "${YELLOW}未检测到 XanMod 内核。${NC}"
        echo -e "  ${GRAY}1${NC} 安装 XanMod BBRv3 内核 (智能CPU检测，需重启)"
        echo -e "  ${GRAY}2${NC} 跳过安装，直接应用普通 BBR 极限调优"
        read -p "请选择 [1/2]: " c
        case $c in
            1) 
                if xanmod_add_repo; then
                    echo -e "${YELLOW}正在检测 CPU 支持的内核版本...${NC}"
                    local pkg_name=$(xanmod_detect_package)
                    if [ -n "$pkg_name" ]; then
                        echo -e "${GREEN}✓ 检测到适合: ${pkg_name}${NC}"
                        echo -e "${YELLOW}开始安装 (过程可能较慢)...${NC}"
                        if apt install -y ${pkg_name}; then
                            _kernel_optimize_core
                            echo -e "${GREEN}✓ 内核安装并调优成功！请重启服务器以加载新内核。${NC}"
                            read -p "按回车键重启..." && reboot
                        else
                            echo -e "${RED}✘ XanMod 内核安装失败。${NC}"
                            echo -e "${YELLOW}自动回退到普通 BBR 调优模式...${NC}"
                            _kernel_optimize_core
                        fi
                    else
                        echo -e "${RED}✘ 无法找到适合的 XanMod 内核包！${NC}"
                        echo -e "${YELLOW}自动回退到普通 BBR 调优模式...${NC}"
                        _kernel_optimize_core
                    fi
                else
                    echo -e "${YELLOW}自动回退到普通 BBR 调优模式...${NC}"
                    _kernel_optimize_core
                fi
                ;;
            2) _kernel_optimize_core; echo -e "${GREEN}✓ 极限调优完成！${NC}" ;;
        esac
    fi
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
    echo -e "${CYAN}║    WireGuard 智能中转部署工具 v11.0 (军工级融合版)    ║${NC}"
    echo -e "${CYAN}╠═══════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC}  ${GREEN}1${NC}  ⚡ 系统极限优化 (智能CPU检测安装BBRv3+极限调优)     ${CYAN}║${NC}"
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
