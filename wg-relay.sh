#!/bin/bash
# ==========================================
# WireGuard 智能中转部署脚本 v17.0 (彻底解决APT锁死版)
# ==========================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'
WG_CONF="/etc/wireguard/wg0.conf"
NODES_INFO="/etc/wireguard/nodes_info.txt"
LAND_INFO="/etc/wireguard/landing_info.txt"
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

# 核心：强制清理 APT 锁，防止安装时卡死
kill_apt_locks() {
    rm -f /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock /var/lib/apt/lists/lock 2>/dev/null
    dpkg --configure -a 2>/dev/null
}

prepare_env() {
    echo -e "${YELLOW}正在准备基础环境...${NC}"
    systemctl stop apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1
    kill_apt_locks
    timeout 30 apt-get update -y > /dev/null 2>&1
    timeout 60 apt-get install -y curl wget gnupg ca-certificates iptables iptables-persistent tar jq openssl > /dev/null 2>&1
    modprobe nf_conntrack 2>/dev/null
    echo -e "${GREEN}✓ 环境准备完毕！${NC}"
    sleep 1
}

get_pub_ip() {
    local ip=$(timeout 3 curl -s -4 ifconfig.me || timeout 3 curl -s -4 ip.sb || timeout 3 curl -s -4 api.ipify.org)
    if [ -z "$ip" ]; then echo -e "${RED}无法获取公网IP，请检查网络${NC}"; exit 1; fi
    echo "$ip"
}

# ================= 内置 Sing-box 安装 =================
install_singbox() {
    if command -v sing-box &> /dev/null; then return 0; fi
    echo -e "${YELLOW}[*] 正在内置下载 Sing-box...${NC}"
    ARCH=$(uname -m)
    if [ "$ARCH" == "x86_64" ]; then SB_ARCH="amd64";
    elif [ "$ARCH" == "aarch64" ]; then SB_ARCH="arm64";
    else echo -e "${RED}不支持的架构: $ARCH${NC}"; return 1; fi
    
    SB_VER="1.8.5"
    URL="https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/sing-box-${SB_VER}-linux-${SB_ARCH}.tar.gz"
    
    if ! timeout 30 wget -qO /tmp/sb.tar.gz "$URL"; then
        timeout 30 wget -qO /tmp/sb.tar.gz "https://ghproxy.net/$URL"
    fi
    if [ ! -s /tmp/sb.tar.gz ]; then echo -e "${RED}Sing-box 下载失败！请检查网络。${NC}"; return 1; fi
    
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

# ================= 军工级 Reality 增强模块 =================
force_sync_time() {
    echo -e "${YELLOW}[*] 正在校准系统时间...${NC}"
    command -v timedatectl >/dev/null 2>&1 && timedatectl set-ntp true >/dev/null 2>&1
    local current_year=$(date +%Y)
    if [ "$current_year" -lt 2020 ] || [ "$current_year" -gt 2030 ]; then
        local sys_time=$(timeout 5 curl -sI https://www.cloudflare.com 2>/dev/null | grep -i '^date:' | sed 's/^[Dd]ate: //g' | tr -d '\r')
        if [ -n "$sys_time" ]; then
            date -s "$sys_time" >/dev/null 2>&1
            echo -e "${GREEN}✅ 系统时间已校准${NC}"
        else
            echo -e "${RED}⚠ 时间校准失败，Reality 可能无法连通！${NC}"
        fi
    else
        echo -e "${GREEN}✅ 系统时间正常${NC}"
    fi
}

SNI_DOMAINS=(
    "www.microsoft.com" "www.cloudflare.com" "www.amazon.com" "www.apple.com" "www.bing.com"
    "www.yahoo.com" "www.icloud.com" "www.office.com" "aws.amazon.com" "azure.microsoft.com"
    "dl.google.com" "cdn.apple.com" "api.apple.com" "www.sony.com" "www.oracle.com"
    "www.nvidia.com" "www.amd.com" "www.ebay.com" "www.paypal.com" "www.tesla.com"
)

select_best_domain() {
    echo -e "${YELLOW}[*] 正在测试大厂 SNI 延迟...${NC}"
    local tmp_res="/tmp/sb_domain_speed"
    > "$tmp_res"
    for domain in "${SNI_DOMAINS[@]}"; do
        local t1 t2 ms
        t1=$(date +%s%3N 2>/dev/null)
        [[ ! "$t1" =~ ^[0-9]+$ ]] && t1=$(date +%s)000
        if timeout 2 openssl s_client -connect "${domain}:443" -servername "${domain}" </dev/null &>/dev/null; then
            t2=$(date +%s%3N 2>/dev/null)
            [[ ! "$t2" =~ ^[0-9]+$ ]] && t2=$(date +%s)000
            ms=$((t2 - t1))
            [ "$ms" -ge 0 ] 2>/dev/null && echo "${ms} ${domain}" >> "$tmp_res" || echo "9999 ${domain}" >> "$tmp_res"
        else
            echo "9999 ${domain}" >> "$tmp_res"
        fi
    done
    local best_domain=$(grep -v "^9999" "$tmp_res" | sort -n | head -1 | awk '{print $2}')
    rm -f "$tmp_res"
    if [ -z "$best_domain" ]; then
        echo -e "${RED}测速失败，使用默认域名。${NC}"
        echo "www.microsoft.com"
    else
        echo "$best_domain"
    fi
}

url_encode() { jq -rn --arg v "$1" '$v|@uri' | sed 's/%2F/\//g'; }

# ================= 军工级 BBRv3 与极限调优模块 =================
xanmod_add_repo() {
    local keyring="/usr/share/keyrings/xanmod-archive-keyring.gpg" list_file="/etc/apt/sources.list.d/xanmod-release.list" os_codename=""
    if command -v lsb_release >/dev/null 2>&1; then os_codename=$(lsb_release -sc); elif [ -r /etc/os-release ]; then os_codename=$(. /etc/os-release && echo "$VERSION_CODENAME"); fi
    if ! echo "bookworm trixie forky sid noble plucky" | grep -qw "$os_codename"; then os_codename="releases"; fi
    if echo "jammy focal buster releases" | grep -qw "$os_codename"; then echo -e "${RED}XanMod 已停止支持${NC}"; return 1; fi
    [ -z "$os_codename" ] && { echo "无法获取代号"; return 1; }
    
    kill_apt_locks
    echo -e "${YELLOW}  - 安装基础工具 (最多30秒)...${NC}"
    timeout 30 apt-get install -y wget gnupg ca-certificates >/dev/null 2>&1; mkdir -p /usr/share/keyrings /etc/apt/sources.list.d
    
    echo -e "${YELLOW}  - 下载 XanMod 密钥 (最多15秒)...${NC}"
    if ! timeout 15 wget -qO /tmp/xanmod.key "https://dl.xanmod.org/archive.key"; then
        echo -e "${RED}❌ 密钥下载失败！${NC}"; return 1
    fi
    gpg --dearmor -o "$keyring" --yes /tmp/xanmod.key 2>/dev/null
    if [ ! -s "$keyring" ]; then echo -e "${RED}❌ 密钥解密失败！${NC}"; return 1; fi
    chmod 644 "$keyring"
    echo "deb [signed-by=$keyring] http://deb.xanmod.org $os_codename main" > "$list_file"
    echo -e "${GREEN}  - 仓库添加成功${NC}"
}

xanmod_detect_package() {
    local arch=$(uname -m)
    kill_apt_locks
    echo -e "${YELLOW}  - 更新软件源 (最多30秒)...${NC}"
    timeout 30 apt-get update -y >/dev/null 2>&1
    
    if [ "$arch" = "aarch64" ]; then
        if apt-cache policy "linux-xanmod-arm64" 2>/dev/null | grep -q 'Candidate: [0-9]'; then printf '%s\n' "linux-xanmod-arm64"; return 0; fi
        return 1
    fi
    local psabi_level=$(awk -F: '/^flags/{ if(/lm/&&/cmov/&&/cx8/&&/fpu/&&/fxsr/&&/mmx/&&/syscall/&&/sse2/) level=1; if(level==1&&/cx16/&&/lahf/&&/popcnt/&&/sse4_1/&&/sse4_2/&&/ssse3/) level=2; if(level==2&&/avx/&&/avx2/&&/bmi1/&&/bmi2/&&/f16c/&&/fma/&&/abm/&&/movbe/&&/xsave/) level=3; if(level>0){print level;exit} }' /proc/cpuinfo 2>/dev/null)
    if [ -z "$psabi_level" ]; then return 1; fi
    [ "$psabi_level" -gt 3 ] && psabi_level=3
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
    local RMEM_MAX=8388608 WMEM_MAX=8388608 TCP_RMEM="4096 16384 8388608" TCP_WMEM="4096 16384 8388608"
    local SOMAXCONN=65535 BACKLOG=100000
    if [ "$MEM_MB_VAL" -ge 4096 ]; then MIN_FREE_KB=65536
    elif [ "$MEM_MB_VAL" -ge 1024 ]; then RMEM_MAX=16777216; WMEM_MAX=16777216; TCP_RMEM="4096 32768 16777216"; TCP_WMEM="4096 32768 16777216"
    else MIN_FREE_KB=16384; RMEM_MAX=4194304; WMEM_MAX=4194304; SOMAXCONN=1024; BACKLOG=1000; TCP_RMEM="4096 32768 4194304"; TCP_WMEM="4096 32768 4194304"; fi
    local QDISC="fq"
    if uname -r | grep -qi "xanmod"; then QDISC="fq_pie"; fi
    cat > "$CONF" << EOF
net.core.default_qdisc = $QDISC
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = $RMEM_MAX
net.ipv4.tcp_rmem = $TCP_RMEM
net.ipv4.tcp_wmem = $TCP_WMEM
net.core.somaxconn = $SOMAXCONN
net.core.netdev_max_backlog = $BACKLOG
net.ipv4.tcp_fastopen = 3
net.ipv4.ip_forward = 1
net.netfilter.nf_conntrack_max = 1048576
vm.swappiness = 10
EOF
    sysctl -p "$CONF" > /dev/null 2>&1
    for dir in /sys/class/net/*/queues/rx-*; do [ -f "$dir/rps_cpus" ] && echo ff > "$dir/rps_cpus" 2>/dev/null; done
}

tune_system() {
    clear
    echo -e "${YELLOW}━━━ 系统极限优化 ━━━${NC}"
    
    echo -e "${YELLOW}[1/4] 停止系统后台自动更新...${NC}"
    systemctl stop apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1
    
    if uname -r | grep -qi "xanmod"; then
        echo -e "${GREEN}[2/4] 已是 XanMod 内核，跳过安装${NC}"
        echo -e "${YELLOW}[3/4] 应用网关极限网络参数...${NC}"
        _kernel_optimize_core
        echo -e "${GREEN}[4/4] 优化完成！${NC}"
        read -p "按回车键继续..."
        return
    fi
    
    echo -e "${YELLOW}[2/4] 尝试添加 XanMod BBRv3 仓库...${NC}"
    if xanmod_add_repo; then
        echo -e "${YELLOW}[3/4] 检测 CPU 版本并安装内核...${NC}"
        local pkg_name=$(xanmod_detect_package)
        if [ -n "$pkg_name" ]; then
            echo -e "${GREEN}✓ 检测到适合: ${pkg_name}${NC}"
            echo -e "${YELLOW}开始下载安装内核 (体积较大，请耐心等待)...${NC}"
            kill_apt_locks
            if apt-get install -y ${pkg_name}; then
                _kernel_optimize_core
                echo -e "${GREEN}✓ 内核安装并调优成功！请重启服务器。${NC}"
                read -p "按回车键重启..." && reboot
            else
                echo -e "${RED}✘ 内核下载/安装失败，自动回退普通调优${NC}"
                _kernel_optimize_core
            fi
        else
            echo -e "${RED}✘ 找不到合适的内核包，自动回退普通调优${NC}"
            _kernel_optimize_core
        fi
    else
        echo -e "${YELLOW}✘ XanMod 仓库添加失败，自动回退普通 BBR 调优${NC}"
        _kernel_optimize_core
    fi
    echo -e "${GREEN}[4/4] 优化完成！${NC}"
    read -p "按回车键继续..."
}

# ================= 1. 中转机初始化 =================
init_relay() {
    clear
    echo -e "${YELLOW}━━━ 初始化中转机 ━━━${NC}"
    if [ -f "$WG_CONF" ]; then
        read -p "${RED}⚠️ 已有配置将被覆盖！确定？${NC} [y/N]: " confirm
        [[ ! "$confirm" =~ ^[Yy]$ ]] && return
    fi
    kill_apt_locks
    apt-get install -y wireguard > /dev/null 2>&1
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
    echo "" > "$NODES_INFO"
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
    DEPLOY_CODE=$(echo "$DEPLOY_CODE" | tr -d '[:space:]')
    if [ -z "$DEPLOY_CODE" ]; then echo -e "${RED}部署码为空！${NC}"; read -p "按回车继续..."; return; fi

    CODE_RAW=$(echo -n "$DEPLOY_CODE" | base64 -d 2>/dev/null)
    if [ -z "$CODE_RAW" ] || ! echo "$CODE_RAW" | grep -q "|"; then 
        echo -e "${RED}部署码无效或已损坏！${NC}"; read -p "按回车继续..."; return
    fi

    RELAY_IP=$(echo $CODE_RAW | cut -d'|' -f1); RELAY_PUB=$(echo $CODE_RAW | cut -d'|' -f2)
    LAND_IP=$(echo $CODE_RAW | cut -d'|' -f3); MAP_PORT=$(echo $CODE_RAW | cut -d'|' -f4); NODE_NAME=$(echo $CODE_RAW | cut -d'|' -f5)
    
    local LAND_PORT
    while true; do
        read -p "请输入落地机 Sing-box 监听端口 (默认 443): " LAND_PORT
        if [ -z "$LAND_PORT" ]; then LAND_PORT=443; break; fi
        if [[ "$LAND_PORT" =~ ^[0-9]+$ ]] && [ "$LAND_PORT" -ge 1 ] && [ "$LAND_PORT" -le 65535 ]; then break; fi
        echo -e "${RED}端口必须是1-65535的数字！${NC}"
    done

    echo -e "${YELLOW}[*] 正在安装 WireGuard...${NC}"
    kill_apt_locks
    apt-get install -y wireguard > /dev/null 2>&1
    
    echo -e "${YELLOW}[*] 正在检查 Sing-box 环境...${NC}"
    if ! install_singbox; then 
        echo -e "${RED}Sing-box 安装失败，流程中止。${NC}"; read -p "按回车继续..."; return
    fi
    
    force_sync_time

    echo -e "${YELLOW}[*] 正在配置 WireGuard 隧道...${NC}"
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

    apt-get install -y openssl > /dev/null 2>&1
    SNI=$(select_best_domain)
    echo -e "${GREEN}✓ 选用最优 SNI: ${CYAN}${SNI}${NC}"

    echo -e "${YELLOW}[*] 正在生成 Reality 密钥与配置 (监听 ${LAND_PORT})...${NC}"
    REALITY_KEYS=$(/usr/local/bin/sing-box generate reality-keypair)
    SB_PRIV=$(echo "$REALITY_KEYS" | grep PrivateKey | awk '{print $2}'); SB_PUB=$(echo "$REALITY_KEYS" | grep PublicKey | awk '{print $2}')
    UUID=$(/usr/local/bin/sing-box generate uuid); SHORT_ID=$(/usr/local/bin/sing-box generate rand --hex 8)
    
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
    BIND_CODE=$(echo -n "${WG_PUB}|${LAND_IP}|${MAP_PORT}|${LAND_PORT}|${NODE_NAME}" | base64)
    
    touch "$LAND_INFO"
    sed -i "/# ${NODE_NAME} START/,/# ${NODE_NAME} END/d" "$LAND_INFO"
    cat >> "$LAND_INFO" << EOF
# ${NODE_NAME} START
节点名称: $NODE_NAME
中转机IP: $RELAY_IP
客户端端口: $MAP_PORT
落地机端口: $LAND_PORT
SNI伪装域名: $SNI
客户端导入链接:
 $VLESS_LINK
# ${NODE_NAME} END
EOF
    
    echo -e "${GREEN}=========================================="
    echo -e " 落地机 [${NODE_NAME}] 部署成功！"
    echo -e " ${YELLOW}回传绑定码：${NC}\n ${CYAN}${BIND_CODE}${NC}"
    echo -e " ${YELLOW}客户端链接：${NC}\n ${GREEN}${VLESS_LINK}${NC}"
    echo -e "==========================================${NC}"
    read -p "按回车键继续..."
}

# ================= 4. 绑定落地机 =================
bind_landing() {
    clear
    echo -e "${YELLOW}━━━ 绑定落地机 ━━━${NC}"
    read -p "请粘贴回传绑定码: " BIND_CODE
    CODE_RAW=$(echo -n "$BIND_CODE" | base64 -d 2>/dev/null)
    if [ -z "$CODE_RAW" ] || ! echo "$CODE_RAW" | grep -q "|"; then echo -e "${RED}绑定码无效！${NC}"; return; fi
    
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
    
    touch "$NODES_INFO"
    sed -i "/|${NODE_NAME}$/d" "$NODES_INFO"
    echo "${MAP_PORT}|${LAND_IP}|${LAND_PORT}|${NODE_NAME}" >> "$NODES_INFO"
    
    echo -e "${GREEN}✓ 节点 [${NODE_NAME}] 绑定成功！隧道已打通。${NC}"
}

# ================= 5. 中转机查看节点 =================
list_relay_nodes() {
    clear
    echo -e "${YELLOW}━━━ 中转机节点状态列表 ━━━${NC}"
    if [ ! -f "$NODES_INFO" ] || [ ! -s "$NODES_INFO" ]; then
        echo -e "${RED}暂无绑定的节点${NC}"
        read -p "按回车继续..."
        return
    fi
    printf "${GREEN}%-15s | %-18s | %-12s | %-20s\n${NC}" "客户端端口" "落地内网IP" "落地端口" "节点名称"
    echo "-------------------------------------------------------------------------"
    while IFS='|' read -r c_port l_ip l_port n_name; do
        printf "%-15s | %-18s | %-12s | %-20s\n" "$c_port" "$l_ip" "$l_port" "$n_name"
    done < "$NODES_INFO"
    echo "-------------------------------------------------------------------------"
    read -p "按回车继续..."
}

# ================= 6. 落地机查看节点 =================
list_landing_nodes() {
    clear
    echo -e "${YELLOW}━━━ 落地机本机节点信息 ━━━${NC}"
    if [ ! -f "$LAND_INFO" ] || [ ! -s "$LAND_INFO" ]; then
        echo -e "${RED}未找到本机节点记录，可能尚未部署。${NC}"
        read -p "按回车继续..."
        return
    fi
    cat "$LAND_INFO" | sed -e 's/节点名称: /\x1b[33m节点名称: \x1b[0m/g' \
                           -e 's/客户端导入链接:/\x1b[33m客户端导入链接:\x1b[0m/g' \
                           -e 's/vless:\/\/\([^#]*\)#/\x1b[32mvless:\/\/\1#\x1b[0m/g'
    echo "-------------------------------------------------------------------------"
    read -p "按回车继续..."
}

# ================= 主循环 =================
check_root; check_system; prepare_env
while true; do
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║   WireGuard 智能中转 v17.0 (YW版)       ║${NC}"
    echo -e "${CYAN}╠═══════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC}  ${GREEN}1${NC}  ⚡ 系统极限优化 (智能CPU检测安装BBRv3+极限调优)     ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                                                       ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  ${GREEN}2${NC}  [中转机] 初始化网关                               ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  ${GREEN}3${NC}  [中转机] 生成落地部署码 (可自定义端口)            ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  ${GREEN}4${NC}  [落地机] 粘贴部署码一键部署 (内置Sing-box+测速)   ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  ${GREEN}5${NC}  [中转机] 粘贴回传码完成绑定                       ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                                                       ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  ${GREEN}6${NC}  [中转机] 查看所有节点状态列表                     ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  ${GREEN}7${NC}  [落地机] 查看本机节点与导入链接                   ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                                                       ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  ${GREEN}0${NC}  退出                                             ${CYAN}║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════╝${NC}"
    read -p "请输入选项: " choice
    case $choice in
        1) tune_system ;;
        2) init_relay ;;
        3) gen_landing_code ;;
        4) deploy_landing ;;
        5) bind_landing ;;
        6) list_relay_nodes ;;
        7) list_landing_nodes ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${NC}"; sleep 1 ;;
    esac
done
