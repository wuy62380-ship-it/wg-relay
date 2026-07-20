#!/bin/bash
# ==========================================
# WireGuard 智能中转部署脚本 v133.0 (终极打通版)
# 修复：强制 NTP 时间同步、彻底放行 wg0 隧道流量、删除多余的 Reality public_key
# ==========================================

if [ -t 0 ]; then :; else exec </dev/tty; fi

find /tmp -maxdepth 1 -name "sb_*_*.json" -delete 2>/dev/null

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'
export RED GREEN YELLOW CYAN NC

WG_CONF="/etc/wireguard/wg0.conf"
NODES_INFO="/etc/wireguard/nodes_info.txt"
LAND_INFO="/etc/wireguard/landing_info.txt"
LOCK_FILE="/tmp/wg_relay.lock"
WG_PORT="51820"
WG_NET="10.0.0.0/24"
SYSCTL_FILE="/etc/sysctl.d/99-yg-tune.conf"
IP_FORWARD_FILE="/etc/sysctl.d/99-ip-forward.conf"
SNI="www.microsoft.com"

export DEBIAN_FRONTEND=noninteractive

trap 'rm -f /tmp/sb_*_$$.json' EXIT

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
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ WireGuard 启动失败！请检查 /etc/wireguard/wg0.conf 语法。${NC}"
        return 1
    fi
    return 0
}

# 终极防火墙放行函数：不仅放行公网端口，还彻底放行 wg0 隧道接口
allow_port() {
    local port=$1
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "active"; then
        ufw allow "$port"/tcp >/dev/null 2>&1
        ufw allow "$port"/udp >/dev/null 2>&1
        ufw allow in on wg0 >/dev/null 2>&1  # 关键修复：放行 WG 隧道所有流量
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-port="$port"/tcp >/dev/null 2>&1
        firewall-cmd --permanent --add-port="$port"/udp >/dev/null 2>&1
        firewall-cmd --permanent --zone=trusted --add-interface=wg0 >/dev/null 2>&1 # 关键修复：将 wg0 设为信任区
        firewall-cmd --reload >/dev/null 2>&1
    else
        iptables -I INPUT 1 -p tcp --dport "$port" -j ACCEPT 2>/dev/null
        iptables -I INPUT 1 -p udp --dport "$port" -j ACCEPT 2>/dev/null
        iptables -I INPUT 1 -i wg0 -j ACCEPT 2>/dev/null # 关键修复：放行 WG 隧道所有流量
    fi
}

prepare_env() {
    echo -e "${YELLOW}正在准备环境...${NC}"
    kill_apt_locks
    apt-get update -y > /dev/null 2>&1
    apt-get install -y curl wget gnupg ca-certificates iptables iptables-persistent tar jq openssl coreutils iproute2 iputils-ping util-linux > /dev/null 2>&1
    modprobe nf_conntrack 2>/dev/null
    if ! command -v jq &> /dev/null || ! command -v flock &> /dev/null; then
        echo -e "${RED}❌ 致命错误：核心依赖安装失败！${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ 环境准备完毕${NC}"; sleep 1
}

get_pub_ip() {
    local ip=""
    for url in ifconfig.me ip.sb api.ipify.org; do
        ip=$(curl -s --connect-timeout 3 --max-time 5 -4 $url 2>/dev/null | tr -d '[:space:]')
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    echo ""
    return 1
}

install_singbox() {
    if command -v sing-box &> /dev/null && [ -x "/usr/local/bin/sing-box" ]; then return 0; fi
    echo -e "${YELLOW}[*] 下载 Sing-box...${NC}"
    ARCH=$(uname -m)
    if [ "$ARCH" == "x86_64" ]; then SB_ARCH="amd64"; elif [ "$ARCH" == "aarch64" ]; then SB_ARCH="arm64"; else echo -e "${RED}不支持的架构${NC}"; return 1; fi
    
    SB_VER="1.8.7"
    URL="https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/sing-box-${SB_VER}-linux-${SB_ARCH}.tar.gz"
    
    timeout 30 wget -q -T 15 -t 2 -O /tmp/sb.tar.gz "$URL" 2>/dev/null || timeout 30 wget -q -T 15 -t 2 -O /tmp/sb.tar.gz "https://ghproxy.net/$URL" 2>/dev/null
    if [ ! -s /tmp/sb.tar.gz ]; then echo -e "${RED}下载失败${NC}"; return 1; fi
    
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

# 终极时间校准：强制通过 NTP 同步，如果失败则用 HTTP 头兜底
force_sync_time() {
    echo -e "${YELLOW}[*] 正在校准系统时间...${NC}"
    
    apt-get install -y ntpdate >/dev/null 2>&1
    if command -v ntpdate >/dev/null 2>&1; then
        ntpdate -u pool.ntp.org >/dev/null 2>&1
        ntpdate -u time.windows.com >/dev/null 2>&1
    fi
    
    local current_year=$(date +%Y)
    # 只有当年份离谱时才用 HTTP 兜底
    if [ "$current_year" -lt 2023 ] || [ "$current_year" -gt 2025 ]; then
        echo -e "${YELLOW}⚠ 检测到系统时间异常($current_year)，尝试通过 HTTP 兜底校准...${NC}"
        local sys_time=""
        for url in "http://1.1.1.1" "http://www.baidu.com" "http://connect.rom.miui.com"; do
            sys_time=$(curl -sI --max-time 3 "$url" 2>/dev/null | grep -i '^date:' | sed 's/^[Dd]ate: //g' | tr -d '\r')
            if [ -n "$sys_time" ]; then
                date -s "$sys_time" >/dev/null 2>&1
                hwclock -w >/dev/null 2>&1
                break
            fi
        done
    fi
    
    echo -e "${GREEN}✅ 系统时间同步完成: $(date)${NC}"
}

url_encode() { jq -rn --arg v "$1" '$v|@uri'; }

xanmod_add_repo() {
    local keyring="/usr/share/keyrings/xanmod-archive-keyring.gpg" list_file="/etc/apt/sources.list.d/xanmod-release.list" os_codename=""
    if command -v lsb_release >/dev/null 2>&1; then os_codename=$(lsb_release -sc); elif [ -r /etc/os-release ]; then os_codename=$(. /etc/os-release && echo "$VERSION_CODENAME"); fi
    if ! echo "bookworm trixie forky sid noble plucky" | grep -qw "$os_codename"; then os_codename="releases"; fi
    if echo "jammy focal buster releases" | grep -qw "$os_codename"; then echo -e "${RED}❌ XanMod 已停止支持当前系统版本${NC}"; return 1; fi
    [ -z "$os_codename" ] && { echo -e "${RED}无法获取系统代号${NC}"; return 1; }
    
    rm -f "$list_file"
    wget -qO - "https://dl.xanmod.org/archive.key" | gpg --dearmor -o "$keyring" --yes 2>/dev/null
    if [ ! -s "$keyring" ]; then
        echo -e "${RED}❌ XanMod 密钥下载失败！请检查网络或代理设置。${NC}"
        return 1
    fi
    chmod 644 "$keyring"
    echo "deb [signed-by=$keyring] http://deb.xanmod.org $os_codename main" > "$list_file"
}

xanmod_detect_package() {
    local arch=$(uname -m)
    if [ "$arch" = "aarch64" ]; then
        if apt-cache policy "linux-xanmod-arm64" 2>/dev/null | grep -q 'Candidate: [0-9]'; then
            printf '%s\n' "linux-xanmod-arm64"; return 0
        fi
        return 1
    fi

    local psabi_level=$(awk -F: '/^flags/{ if(/lm/&&/cmov/&&/cx8/&&/fpu/&&/fxsr/&&/mmx/&&/syscall/&&/sse2/) level=1; if(level==1&&/cx16/&&/lahf/&&/popcnt/&&/sse4_1/&&/sse4_2/&&/ssse3/) level=2; if(level==2&&/avx/&&/avx2/&&/bmi1/&&/bmi2/&&/f16c/&&/fma/&&/abm/&&/movbe/&&/xsave/) level=3; if(level>0){print level;exit} }' /proc/cpuinfo 2>/dev/null)
    if [ -z "$psabi_level" ]; then return 1; fi
    [ "$psabi_level" -gt 3 ] && psabi_level=3
    for prefix in linux-xanmod linux-xanmod-lts; do 
        local l="$psabi_level"
        while [ "$l" -ge 1 ]; do 
            local p="${prefix}-x64v${l}"
            if apt-cache policy "$p" 2>/dev/null | grep -q 'Candidate: [0-9]'; then
                printf '%s\n' "$p"; return 0
            fi
            l=$((l-1))
        done
    done
    return 1
}

tune_system() {
    clear; echo -e "${YELLOW}━━━ 系统极限优化 ━━━${NC}"
    
    local mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local conntrack_max=$((mem_kb / 16384 * 1024))
    [ "$conntrack_max" -lt 65536 ] && conntrack_max=65536
    
    echo -e "当前检测到内存: $((mem_kb/1024))MB, Conntrack表将设置为: ${GREEN}${conntrack_max}${NC}"
    echo -e "请选择拥塞控制算法方案："
    echo -e "${GREEN}1${NC}. ${CYAN}原版 BBR${NC} (推荐，安全稳定，即时生效不重启)"
    echo -e "${GREEN}2${NC}. ${CYAN}XanMod BBRv3${NC} (极限抗丢包，适合晚高峰线路，${RED}需重启生效${NC})"
    read -p "请输入选项 [1/2] (默认1): " tune_choice < /dev/tty

    case "$tune_choice" in
        2)
            echo -e "${YELLOW}[*] 开始安装 XanMod BBRv3 内核...${NC}"
            
            if ! xanmod_add_repo; then
                echo -e "${RED}❌ XanMod 源添加失败，回退原版 BBR。${NC}"
                tune_choice=1
            else
                kill_apt_locks
                apt-get update -y > /dev/null 2>&1
                local pkg_name=$(xanmod_detect_package)
                
                if [ -z "$pkg_name" ]; then
                    echo -e "${RED}❌ 找不到适合当前架构/CPU指令集的 XanMod 内核包，回退原版 BBR。${NC}"
                    tune_choice=1
                else
                    echo -e "${GREEN}✓ 检测到适合: ${pkg_name}，开始下载安装 (请耐心等待)...${NC}"
                    if apt-get install -y "$pkg_name"; then
                        cat > "$SYSCTL_FILE" << EOF
# XanMod BBRv3 专属优化
net.core.default_qdisc = fq_pie
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
                        echo -e "${GREEN}✓ BBRv3 安装成功！请务必重启服务器后再进行后续操作。${NC}"
                        read -p "按回车键重启服务器..." < /dev/tty
                        reboot
                        exit 0
                    else
                        echo -e "${RED}✘ XanMod 安装失败，回退原版 BBR。${NC}"
                        tune_choice=1
                    fi
                fi
            fi
            ;;
        *)
            tune_choice=1
            ;;
    esac

    if [ "$tune_choice" == "1" ]; then
        echo -e "${YELLOW}[*] 应用原版 BBR 优化...${NC}"
        cat > "$SYSCTL_FILE" << EOF
# 原版 BBR 优化
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
        echo -e "${GREEN}✓ 优化完成 (原版 BBR, Conntrack: $conntrack_max)！${NC}"
    fi
    pause_return
}

check_node_name() {
    local name="$1"
    if [ ${#name} -gt 20 ] || [[ "$name" =~ [\/\\|\&\;\$\<\>\`\!\?\*\(\)\ ] ]]; then
        echo -e "${RED}❌ 名称过长(>20)或包含空格及特殊字符！${NC}"
        return 1
    fi
    return 0
}

check_ip_format() {
    local ip="$1"
    if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${RED}❌ IP 格式不正确！${NC}"
        return 1
    fi
    return 0
}

check_pub_key() {
    local key="$1"
    if [[ ! "$key" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
        return 1
    fi
    return 0
}

init_relay() {
    clear; echo -e "${YELLOW}━━━ 初始化中转机 ━━━${NC}"
    if [ -f "$WG_CONF" ]; then
        read -p "${RED}已有配置将被覆盖！确定？[y/N]: ${NC}" c < /dev/tty
        [[ ! "$c" =~ ^[Yy]$ ]] && { pause_return; return; }
    fi
    
    (
        flock -x 200
        echo -e "${YELLOW}[*] 清理旧规则...${NC}"
        iptables -t nat -S | grep "10.0.0." | sed 's/-A/-D/' | while read -r rule; do iptables -t nat $rule 2>/dev/null; done
        iptables -S | grep "10.0.0." | sed 's/-A/-D/' | while read -r rule; do iptables $rule 2>/dev/null; done
        netfilter-persistent save >/dev/null 2>&1
        
        mkdir -p /etc/wireguard
        echo "" > "$NODES_INFO"
        
        apt-get install -y wireguard > /dev/null 2>&1
        WG_PRIV=$(wg genkey); WG_PUB=$(echo "$WG_PRIV" | wg pubkey)
        RELAY_IP=$(get_pub_ip)
        if [ -z "$RELAY_IP" ]; then echo -e "${RED}无法获取公网IP${NC}"; exit 1; fi
        
        cat > "$WG_CONF" << EOF
[Interface]
PrivateKey = $WG_PRIV
Address = 10.0.0.1/24
ListenPort = $WG_PORT
MTU = 1380
EOF
        systemctl enable wg-quick@wg0 > /dev/null 2>&1
        wg-quick down wg0 >/dev/null 2>&1
        if ! wg-quick up wg0 >/dev/null 2>&1; then
            echo -e "${RED}❌ WireGuard 启动失败！${NC}"
            exit 1
        fi
        
        echo -e "${GREEN}=========================================="
        echo -e " IP: ${CYAN}${RELAY_IP}${NC} | 公钥: ${CYAN}${WG_PUB}${NC}"
        echo -e "=========================================="
    ) 200>"$LOCK_FILE"
    
    mkdir -p /etc/sysctl.d
    cat > "$IP_FORWARD_FILE" << EOF
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
EOF
    sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1
    sysctl -w net.ipv4.conf.all.rp_filter=0 > /dev/null 2>&1
    sysctl -p "$IP_FORWARD_FILE" > /dev/null 2>&1
    
    allow_port "$WG_PORT"
    
    if [ $? -ne 0 ]; then echo -e "${RED}❌ 初始化失败！${NC}"; fi
    pause_return
}

gen_landing_code() {
    clear; echo -e "${YELLOW}━━━ 生成落地部署码 (新落地机) ━━━${NC}"
    if [ ! -f "$WG_CONF" ]; then echo -e "${RED}请先初始化中转机${NC}"; pause_return; return; fi
    
    while true; do 
        read -p "节点名称: " NODE_NAME < /dev/tty
        if [ -n "$NODE_NAME" ] && check_node_name "$NODE_NAME"; then break; fi
    done
    
    LAND_INFO_OUT=$(
        flock -s 200
        MAX_IP=1
        for ip in $(grep "^AllowedIPs = 10.0.0." "$WG_CONF" | awk '{print $3}' | cut -d. -f4 | cut -d/ -f1); do [ "$ip" -gt "$MAX_IP" ] && MAX_IP=$ip; done
        if [ "$MAX_IP" -ge 250 ]; then
            echo "ERROR_IP_POOL_EXHAUSTED" >&2
            exit 1
        fi
        LAND_IP="10.0.0.$((MAX_IP + 1))"
        RELAY_PUB=$(grep "^PrivateKey" "$WG_CONF" | awk '{print $3}' | wg pubkey)
        echo "${LAND_IP}|${RELAY_PUB}"
    ) 200>"$LOCK_FILE"
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ $LAND_INFO_OUT${NC}"
        pause_return; return
    fi
    
    LAND_IP=$(echo "$LAND_INFO_OUT" | cut -d'|' -f1)
    RELAY_PUB=$(echo "$LAND_INFO_OUT" | cut -d'|' -f2)
    
    if [ -z "$LAND_IP" ] || [ -z "$RELAY_PUB" ]; then pause_return; return; fi

    while true; do
        read -p "客户端端口: " MAP_PORT < /dev/tty
        [[ "$MAP_PORT" =~ ^[0-9]+$ ]] && [ "$MAP_PORT" -ge 1 ] && [ "$MAP_PORT" -le 65535 ] && [ "$MAP_PORT" != "$WG_PORT" ] && break
        echo -e "${RED}端口无效${NC}"
    done
    
    RELAY_IP=$(get_pub_ip)
    if [ -z "$RELAY_IP" ]; then echo -e "${RED}无法获取公网IP${NC}"; pause_return; return; fi
    
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
    if [ -z "$CODE_RAW" ] || ! echo "$CODE_RAW" | grep -q "|"; then echo -e "${RED}❌ 部署码无效！${NC}"; pause_return; return; fi

    RELAY_IP=$(echo $CODE_RAW | cut -d'|' -f1); RELAY_PUB=$(echo $CODE_RAW | cut -d'|' -f2)
    LAND_IP=$(echo $CODE_RAW | cut -d'|' -f3); MAP_PORT=$(echo $CODE_RAW | cut -d'|' -f4); NODE_NAME=$(echo $CODE_RAW | cut -d'|' -f5)
    if [ -z "$RELAY_IP" ] || [ -z "$MAP_PORT" ] || [ -z "$LAND_IP" ]; then echo -e "${RED}❌ 致命错误：IP或端口为空！${NC}"; pause_return; return; fi

    while true; do
        read -p "落地机监听端口 (默认 443): " LAND_PORT < /dev/tty
        [ -z "$LAND_PORT" ] && LAND_PORT=443
        if ss -tulnp | grep -qE ":$LAND_PORT\b"; then echo -e "${RED}❌ 端口 $LAND_PORT 已被占用！请换一个：${NC}"
        else break; fi
    done

    echo -e "${YELLOW}[*] 安装 WG 与 Sing-box...${NC}"
    kill_apt_locks; apt-get install -y wireguard > /dev/null 2>&1
    if ! install_singbox; then echo -e "${RED}Sing-box 安装失败${NC}"; pause_return; return; fi
    force_sync_time

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
    cat > "$IP_FORWARD_FILE" << EOF
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
EOF
    sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1
    sysctl -w net.ipv4.conf.all.rp_filter=0 > /dev/null 2>&1
    sysctl -p "$IP_FORWARD_FILE" > /dev/null 2>&1
    
    local default_if=$(ip route show default | awk '/default/ {print $5}')
    if [ -z "$default_if" ]; then
        echo -e "${RED}❌ 无法获取默认网卡名称！网络配置可能异常。${NC}"
        pause_return; return
    fi
    while iptables -t nat -D POSTROUTING -s $WG_NET -o $default_if -j MASQUERADE 2>/dev/null; do :; done
    iptables -t nat -A POSTROUTING -s $WG_NET -o $default_if -j MASQUERADE
    netfilter-persistent save > /dev/null 2>&1
    
    REALITY_KEYS=$(/usr/local/bin/sing-box generate reality-keypair 2>/dev/null)
    SB_PRIV=$(echo "$REALITY_KEYS" | grep PrivateKey | awk '{print $2}'); SB_PUB=$(echo "$REALITY_KEYS" | grep PublicKey | awk '{print $2}')
    UUID=$(/usr/local/bin/sing-box generate uuid 2>/dev/null); SHORT_ID=$(/usr/local/bin/sing-box generate rand --hex 8 2>/dev/null)
    if [ -z "$SB_PUB" ] || [ -z "$UUID" ]; then echo -e "${RED}❌ 密钥生成失败！${NC}"; pause_return; return; fi

    # 终极修复：彻底删除服务端配置中的 public_key
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

    # 终极修复：启动前强制校验，失败直接报错退出
    if ! /usr/local/bin/sing-box check -c /etc/sing-box/config.json >/dev/null 2>&1; then
        echo -e "${RED}❌ Sing-box 配置文件语法错误！请检查 JSON 格式。${NC}"
        /usr/local/bin/sing-box check -c /etc/sing-box/config.json
        pause_return; return
    fi

    systemctl enable wg-quick@wg0 > /dev/null 2>&1
    if ! restart_wg; then pause_return; return; fi
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
    if [ -z "$CODE_RAW" ] || ! echo "$CODE_RAW" | grep -q "|"; then echo -e "${RED}绑定码无效${NC}"; pause_return; return; fi
    
    LANDING_PUB=$(echo $CODE_RAW | cut -d'|' -f1); LAND_IP=$(echo $CODE_RAW | cut -d'|' -f2)
    MAP_PORT=$(echo $CODE_RAW | cut -d'|' -f3); LAND_PORT=$(echo $CODE_RAW | cut -d'|' -f4); NODE_NAME=$(echo $CODE_RAW | cut -d'|' -f5)
    
    (
        flock -x 200
        sed -i "/# ${NODE_NAME}/,/AllowedIPs = ${LAND_IP}\/32/d" "$WG_CONF"
        echo -e "\n# ${NODE_NAME}\n[Peer]\nPublicKey = ${LANDING_PUB}\nAllowedIPs = ${LAND_IP}/32" >> "$WG_CONF"
        wg-quick down wg0 >/dev/null 2>&1
        if ! wg-quick up wg0 >/dev/null 2>&1; then
            echo -e "${RED}❌ WireGuard 启动失败！${NC}"
            exit 1
        fi
        
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
    ) 200>"$LOCK_FILE"
    if [ $? -ne 0 ]; then echo -e "${RED}❌ 绑定节点失败！${NC}"; fi
    pause_return
}

add_relay_port() {
    clear; echo -e "${YELLOW}━━━ 中转机-为现有落地机加端口 ━━━${NC}"
    if [ ! -f "$WG_CONF" ]; then echo -e "${RED}请先初始化中转机${NC}"; pause_return; return; fi
    
    echo -e "当前已绑定的落地机内网IP："
    grep "^AllowedIPs = 10.0.0." $WG_CONF | awk '{print $3}' | cut -d'.' -f4 | cut -d'/' -f1 | while read ip; do echo "  10.0.0.$ip"; done
    
    while true; do
        read -p "请输入要加端口的落地机内网IP (如 10.0.0.2): " LAND_IP < /dev/tty
        if check_ip_format "$LAND_IP" && grep -q "${LAND_IP}/32" $WG_CONF; then break; fi
    done
    
    while true; do 
        read -p "请输入新的客户端端口: " MAP_PORT < /dev/tty
        [[ "$MAP_PORT" =~ ^[0-9]+$ ]] && [ "$MAP_PORT" -ge 1 ] && [ "$MAP_PORT" -le 65535 ] || { echo -e "${RED}端口无效${NC}"; continue; }
        
        if (
            flock -s 200
            grep -q "^${MAP_PORT}|" "$NODES_INFO"
        ) 200>"$LOCK_FILE"; then
            echo -e "${RED}❌ 客户端端口 ${MAP_PORT} 已被其他节点占用！请换一个：${NC}"
        else break; fi
    done
    
    while true; do read -p "请输入落地机对应的监听端口: " LAND_PORT < /dev/tty; [[ "$LAND_PORT" =~ ^[0-9]+$ ]] && [ "$LAND_PORT" -ge 1 ] && [ "$LAND_PORT" -le 65535 ] && break; echo -e "${RED}端口无效${NC}"; done
    
    while true; do 
        read -p "请输入节点备注名称 (如 HK-Port2): " NODE_NAME < /dev/tty
        if [ -n "$NODE_NAME" ] && check_node_name "$NODE_NAME"; then break; fi
    done
    
    (
        flock -x 200
        if grep -q "^${MAP_PORT}|" "$NODES_INFO" 2>/dev/null; then
            echo -e "${RED}❌ 端口 ${MAP_PORT} 刚刚被其他终端占用！操作取消。${NC}"
            exit 1
        fi
        
        while iptables -t nat -D PREROUTING -p tcp --dport "$MAP_PORT" 2>/dev/null; do :; done
        while iptables -t nat -D PREROUTING -p udp --dport "$MAP_PORT" 2>/dev/null; do :; done
        
        iptables -t nat -I PREROUTING 1 -p tcp --dport "$MAP_PORT" -j DNAT --to-destination "${LAND_IP}:${LAND_PORT}"
        iptables -t nat -I PREROUTING 1 -p udp --dport "$MAP_PORT" -j DNAT --to-destination "${LAND_IP}:${LAND_PORT}"
        
        allow_port "$MAP_PORT"
        netfilter-persistent save > /dev/null 2>&1
        
        touch "$NODES_INFO"; sed -i "/|${NODE_NAME}$/d" "$NODES_INFO"; echo "${MAP_PORT}|${LAND_IP}|${LAND_PORT}|${NODE_NAME}" >> "$NODES_INFO"
        echo -e "${GREEN}✓ 中转机端口添加成功！请确保云后台已放行 ${MAP_PORT} 端口${NC}"
    ) 200>"$LOCK_FILE"
    if [ $? -ne 0 ]; then echo -e "${RED}❌ 添加端口失败！${NC}"; fi
    pause_return
}

add_landing_port() {
    clear; echo -e "${YELLOW}━━━ 落地机-新增端口节点 ━━━${NC}"
    if [ ! -f "$LAND_INFO" ] || [ ! -f "/etc/sing-box/config.json" ]; then echo -e "${RED}请先执行选项4部署基础节点${NC}"; pause_return; return; fi
    
    if ! jq empty /etc/sing-box/config.json 2>/dev/null; then
        echo -e "${RED}❌ /etc/sing-box/config.json 不存在或格式错误！${NC}"
        pause_return; return
    fi
    
    local relay_ip=$(grep "中转机IP:" "$LAND_INFO" | head -1 | awk '{print $2}')
    [ -z "$relay_ip" ] && { echo -e "${RED}无法读取中转机IP，请重新部署${NC}"; pause_return; return; }
    
    while true; do 
        read -p "请输入落地机新的监听端口: " LAND_PORT < /dev/tty
        [[ "$LAND_PORT" =~ ^[0-9]+$ ]] && [ "$LAND_PORT" -ge 1 ] && [ "$LAND_PORT" -le 65535 ] || { echo -e "${RED}端口无效${NC}"; continue; }
        if ss -tulnp | grep -qE ":$LAND_PORT\b"; then echo -e "${RED}❌ 端口 $LAND_PORT 已被系统占用！请换一个：${NC}"
        elif jq -e --argjson p "$LAND_PORT" '.inbounds[] | select(.listen_port == $p)' /etc/sing-box/config.json >/dev/null 2>&1; then
            echo -e "${RED}❌ 端口 $LAND_PORT 已在 Sing-box 中配置！请换一个：${NC}"
        else break; fi
    done
    
    while true; do read -p "请输入客户端连接端口 (需与中转机一致): " MAP_PORT < /dev/tty; [[ "$MAP_PORT" =~ ^[0-9]+$ ]] && break; echo -e "${RED}端口无效${NC}"; done
    
    while true; do 
        read -p "请输入节点备注名称: " NODE_NAME < /dev/tty
        if [ -n "$NODE_NAME" ] && check_node_name "$NODE_NAME"; then break; fi
    done
    
    local exist_priv=$(jq -r '.inbounds[0].tls.reality.private_key' /etc/sing-box/config.json 2>/dev/null)
    local exist_sid=$(jq -r '.inbounds[0].tls.reality.short_id[0]' /etc/sing-box/config.json 2>/dev/null)
    local exist_pub=$(jq -r '.inbounds[0].tls.reality.public_key // empty' /etc/sing-box/config.json 2>/dev/null)
    
    if [ -z "$exist_pub" ] || ! check_pub_key "$exist_pub"; then
        exist_pub=$(grep -oE 'pbk=[a-zA-Z0-9+/=]+' "$LAND_INFO" | head -1 | sed 's/^pbk=//')
        if ! check_pub_key "$exist_pub"; then exist_pub=""; fi
    fi
    
    if [ -z "$exist_priv" ] || [ -z "$exist_sid" ]; then
        echo -e "${RED}❌ 无法读取基础节点的 Reality 密钥，请检查配置文件。${NC}"
        pause_return; return
    fi
    
    local SB_PUB=""
    if [ -n "$exist_pub" ]; then
        SB_PUB="$exist_pub"
    else
        echo -e "${YELLOW}⚠ 未找到合法公钥记录。为了不影响旧节点，请输入第一个节点的 PublicKey (pbk)：${NC}"
        read -p "PublicKey (pbk): " SB_PUB < /dev/tty
        if ! check_pub_key "$SB_PUB"; then
            echo -e "${RED}❌ 公钥格式不正确！操作取消。${NC}"
            pause_return; return
        fi
    fi
    
    local UUID=$(/usr/local/bin/sing-box generate uuid 2>/dev/null)
    
    local tmp_json="/tmp/sb_add_$$.json"
    # 终极修复：彻底删除服务端配置中的 public_key
    if ! jq --arg p "$LAND_PORT" --arg u "$UUID" --arg s "$SNI" --arg pk "$exist_priv" --arg sid "$exist_sid" \
       --arg listen "0.0.0.0" --arg pub "$SB_PUB" \
       '.inbounds += [{
           "type": "vless", "listen": $listen, "listen_port": ($p|tonumber),
           "users": [{"name": "ext", "uuid": $u, "flow": "xtls-rprx-vision"}],
           "tls": {
               "enabled": true, "server_name": $s,
               "alpn": ["h2", "http/1.1"],
               "reality": {
                   "enabled": true,
                   "handshake": {"server": $s, "server_port": 443},
                   "private_key": $pk, "short_id": [$sid]
               }
           }
       }]' /etc/sing-box/config.json > "$tmp_json" 2>/dev/null; then
        echo -e "${RED}❌ JSON 配置追加失败！原配置未修改。${NC}"
        rm -f "$tmp_json"
        pause_return; return
    fi
    
    if ! jq empty "$tmp_json" 2>/dev/null; then
        echo -e "${RED}❌ 生成的 JSON 格式非法！原配置未修改。${NC}"
        rm -f "$tmp_json"
        pause_return; return
    fi
    
    mv -f "$tmp_json" /etc/sing-box/config.json
    
    # 终极修复：启动前强制校验，失败直接报错退出
    if ! /usr/local/bin/sing-box check -c /etc/sing-box/config.json >/dev/null 2>&1; then
        echo -e "${RED}❌ Sing-box 配置文件语法错误！原配置已覆盖，请检查。${NC}"
        /usr/local/bin/sing-box check -c /etc/sing-box/config.json
        pause_return; return
    fi

    systemctl restart sing-box
    allow_port "$LAND_PORT"
    
    SAFE_NAME=$(url_encode "$NODE_NAME")
    VLESS_LINK="vless://${UUID}@${relay_ip}:${MAP_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${SB_PUB}&sid=${exist_sid}&spx=%2F&type=tcp#WG-${SAFE_NAME}"
    
    sed -i "/# ${NODE_NAME} START/,/# ${NODE_NAME} END/d" "$LAND_INFO"
    cat >> "$LAND_INFO" << EOF
# ${NODE_NAME} START
节点名称: $NODE_NAME
中转机IP: $relay_ip
客户端端口: $MAP_PORT
落地机端口: $LAND_PORT
SNI: $SNI
链接:
 $VLESS_LINK
# ${NODE_NAME} END
EOF
    
    echo -e "${GREEN}=========================================="
    echo -e " 落地机新端口节点 [${NODE_NAME}] 添加成功！"
    echo -e " ${YELLOW}链接：${NC}\n ${GREEN}${VLESS_LINK}${NC}"
    echo -e "=========================================="
    pause_return
}

delete_relay_by_port() {
    clear; echo -e "${YELLOW}━━━ 中转机按端口删除 ━━━${NC}"
    if [ ! -f "$NODES_INFO" ] || [ ! -s "$NODES_INFO" ]; then echo -e "${RED}暂无节点可删除${NC}"; pause_return; return; fi
    
    (
        flock -s 200
        printf "${GREEN}%-10s | %-15s | %-8s | %-15s\n${NC}" "端口" "落地IP" "落地端口" "名称"
        while IFS='|' read -r p lip lp n; do printf "%-10s | %-15s | %-8s | %-15s\n" "$p" "$lip" "$lp" "$n"; done < "$NODES_INFO"
    ) 200>"$LOCK_FILE"
    
    read -p "请输入要删除的客户端端口: " DEL_PORT < /dev/tty
    if [ -z "$DEL_PORT" ]; then echo -e "${RED}❌ 端口不能为空！${NC}"; pause_return; return; fi
    
    (
        flock -x 200
        line=$(grep "^${DEL_PORT}|" "$NODES_INFO")
        if [ -z "$line" ]; then
            echo -e "${RED}未找到端口 ${DEL_PORT}${NC}"
            exit 1
        fi
        
        d_ip=$(echo "$line" | cut -d'|' -f2); d_name=$(echo "$line" | cut -d'|' -f4)
        
        while iptables -t nat -D PREROUTING -p tcp --dport "$DEL_PORT" 2>/dev/null; do :; done
        while iptables -t nat -D PREROUTING -p udp --dport "$DEL_PORT" 2>/dev/null; do :; done
        iptables -D INPUT -p tcp --dport "$DEL_PORT" -j ACCEPT 2>/dev/null
        iptables -D INPUT -p udp --dport "$DEL_PORT" -j ACCEPT 2>/dev/null
        netfilter-persistent save > /dev/null 2>&1
        
        if ! grep -q "|${d_ip}|" "$NODES_INFO"; then
            sed -i "/# ${d_name}/,/AllowedIPs = ${d_ip}\/32/d" "$WG_CONF"
            wg-quick down wg0 >/dev/null 2>&1
            if ! wg-quick up wg0 >/dev/null 2>&1; then
                echo -e "${RED}❌ WireGuard 启动失败！${NC}"
                exit 1
            fi
            while iptables -t nat -D POSTROUTING -d "$d_ip" -j MASQUERADE 2>/dev/null; do :; done
            iptables -D FORWARD -d "$d_ip" -j ACCEPT 2>/dev/null; iptables -D FORWARD -s "$d_ip" -j ACCEPT 2>/dev/null
            netfilter-persistent save > /dev/null 2>&1
        fi
        
        sed -i "/^${DEL_PORT}|/d" "$NODES_INFO"
        echo -e "${GREEN}✓ 端口 ${DEL_PORT} 已彻底删除${NC}"
    ) 200>"$LOCK_FILE"
    if [ $? -ne 0 ]; then echo -e "${RED}❌ 删除节点失败！${NC}"; fi
    pause_return
}

delete_landing_by_port() {
    clear; echo -e "${YELLOW}━━━ 落地机按端口删除 ━━━${NC}"
    if [ ! -f "$LAND_INFO" ] || [ ! -s "$LAND_INFO" ]; then echo -e "${RED}无节点记录${NC}"; pause_return; return; fi
    
    grep "落地机端口:" "$LAND_INFO" | awk '{print $2}' | sort -u
    read -p "请输入要删除的落地机监听端口: " DEL_PORT < /dev/tty
    if [ -z "$DEL_PORT" ]; then echo -e "${RED}❌ 端口不能为空！${NC}"; pause_return; return; fi
    
    if ! jq empty /etc/sing-box/config.json 2>/dev/null; then
        echo -e "${RED}❌ config.json 格式错误，无法安全删除${NC}"
        pause_return; return
    fi
    
    if ! jq -e --argjson p "$DEL_PORT" '.inbounds[] | select(.listen_port == $p)' /etc/sing-box/config.json >/dev/null 2>&1; then
        echo -e "${RED}❌ 端口 ${DEL_PORT} 不存在于 Sing-box 配置中！${NC}"
        pause_return; return
    fi
    
    local tmp_json="/tmp/sb_del_$$.json"
    if ! jq --argjson p "$DEL_PORT" 'del(.inbounds[] | select(.listen_port == $p))' /etc/sing-box/config.json > "$tmp_json" 2>/dev/null; then
        echo -e "${RED}❌ JSON 删除操作失败！原配置未修改。${NC}"
        rm -f "$tmp_json"
        pause_return; return
    fi
    
    if ! jq empty "$tmp_json" 2>/dev/null; then
        echo -e "${RED}❌ 删除后的 JSON 格式非法！原配置未修改。${NC}"
        rm -f "$tmp_json"
        pause_return; return
    fi
    
    mv -f "$tmp_json" /etc/sing-box/config.json
    
    local in_count=$(jq '.inbounds | length' /etc/sing-box/config.json 2>/dev/null)
    if [ "$in_count" -eq 0 ]; then
        echo -e "${YELLOW}⚠ 已无任何节点，自动停止 Sing-box 服务。${NC}"
        systemctl stop sing-box >/dev/null 2>&1
    else
        systemctl restart sing-box >/dev/null 2>&1
    fi
    
    local node_name=$(grep -B 3 "落地机端口: $DEL_PORT$" "$LAND_INFO" | grep "节点名称:" | awk '{print $2}')
    [ -n "$node_name" ] && sed -i "/# ${node_name} START/,/# ${node_name} END/d" "$LAND_INFO"
    
    echo -e "${GREEN}✓ 落地机端口 ${DEL_PORT} 已删除${NC}"
    pause_return
}

view_iptables() {
    clear; echo -e "${YELLOW}━━━ 当前 NAT PREROUTING 规则 ━━━${NC}"
    iptables -t nat -L PREROUTING -n --line-numbers
    echo ""
    echo -e "${YELLOW}━━━ 当前 NAT POSTROUTING 规则 ━━━${NC}"
    iptables -t nat -L POSTROUTING -n --line-numbers
    echo ""
    echo -e "${YELLOW}━━━ 当前 FILTER FORWARD 规则 ━━━${NC}"
    iptables -L FORWARD -n --line-numbers
    pause_return
}

ping_test() {
    clear; echo -e "${YELLOW}━━━ Ping 连通性测试 ━━━${NC}"
    if [ ! -f "$WG_CONF" ]; then echo -e "${RED}请先初始化中转机${NC}"; pause_return; return; fi
    
    echo -e "当前已绑定的落地机内网IP："
    grep "^AllowedIPs = 10.0.0." $WG_CONF | awk '{print $3}' | cut -d'.' -f4 | cut -d'/' -f1 | while read ip; do echo "  10.0.0.$ip"; done
    
    read -p "请输入要测试的落地机内网IP (如 10.0.0.2): " TEST_IP < /dev/tty
    if ! check_ip_format "$TEST_IP"; then pause_return; return; fi
    
    echo -e "${YELLOW}[*] 正在 Ping ${TEST_IP} ...${NC}"
    ping -c 4 $TEST_IP
    pause_return
}

uninstall_all() {
    clear; echo -e "${YELLOW}━━━ 一键卸载环境 ━━━${NC}"
    read -p "${RED}⚠️ 此操作将删除所有 WG 配置、Sing-box 及转发规则！确定？[y/N]: ${NC}" c < /dev/tty
    [[ ! "$c" =~ ^[Yy]$ ]] && { pause_return; return; }
    
    echo -e "${YELLOW}[*] 停止服务...${NC}"
    systemctl stop wg-quick@wg0 2>/dev/null
    systemctl disable wg-quick@wg0 2>/dev/null
    systemctl stop sing-box 2>/dev/null
    systemctl disable sing-box 2>/dev/null
    
    echo -e "${YELLOW}[*] 清理规则...${NC}"
    flush_wg_rules
    
    echo -e "${YELLOW}[*] 删除文件...${NC}"
    rm -rf /etc/wireguard /etc/sing-box /usr/local/bin/sing-box /etc/systemd/system/sing-box.service "$NODES_INFO" "$LAND_INFO" "$SYSCTL_FILE" "$IP_FORWARD_FILE" "$LOCK_FILE"
    
    echo -e "${YELLOW}[*] 清理 XanMod 内核源...${NC}"
    rm -f /etc/apt/sources.list.d/xanmod-release.list
    rm -f /usr/share/keyrings/xanmod-archive-keyring.gpg
    
    systemctl daemon-reload
    
    echo -e "${GREEN}✓ 卸载完成！${NC}"
    echo -e "${YELLOW}⚠️ 提示：如果之前安装过 BBRv3 内核，需手动执行 'apt purge linux-*xanmod*' 卸载内核并重启。${NC}"
    pause_return
}

list_relay_nodes() {
    clear; echo -e "${YELLOW}━━━ 中转机节点列表 ━━━${NC}"
    if [ ! -f "$NODES_INFO" ] || [ ! -s "$NODES_INFO" ]; then echo -e "${RED}暂无节点${NC}"; pause_return; return; fi
    
    (
        flock -s 200
        printf "${GREEN}%-10s | %-15s | %-8s | %-15s\n${NC}" "端口" "落地IP" "落地端口" "名称"
        while IFS='|' read -r p lip lp n; do printf "%-10s | %-15s | %-8s | %-15s\n" "$p" "$lip" "$lp" "$n"; done < "$NODES_INFO"
    ) 200>"$LOCK_FILE"
    pause_return
}

list_landing_nodes() {
    clear; echo -e "${YELLOW}━━━ 落地机节点信息 ━━━${NC}"
    if [ ! -f "$LAND_INFO" ] || [ ! -s "$LAND_INFO" ]; then echo -e "${RED}无记录${NC}"; pause_return; return; fi
    cat "$LAND_INFO"; pause_return
}

check_root
prepare_env
while true; do
    clear
    echo -e "${CYAN}╔════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  WG 智能中转 v133.0 (终极打通版)          ║${NC}"
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
        1) tune_system;; 2) init_relay;; 3) gen_landing_code;; 4) deploy_landing;; 5) bind_landing;; 6) list_relay_nodes;; 7) list_landing_nodes;; 8) add_relay_port;; 9) add_landing_port;; a|A) delete_relay_by_port;; b|B) delete_landing_by_port;; c|C) view_iptables;; d|D) uninstall_all;; e|E) ping_test;; 0) exit 0;; *) echo "错误"; sleep 1;;
    esac
done
