#!/bin/bash
# ==========================================
# WireGuard 智能中转部署脚本 v138.5 (字符串切割终极修复版)
# 修复：使用 sed 替代 cut 防止公钥末尾的 = 被截断，增加私钥自动补 = 逻辑
# ==========================================

if [ -t 0 ]; then :; else exec </dev/tty; fi

find /tmp -maxdepth 1 -name "sb_*_*.json" -delete 2>/dev/null

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

force_sync_time() {
    echo -e "${YELLOW}[*] 正在校准系统时间...${NC}"
    command -v timedatectl >/dev/null 2>&1 && timedatectl set-ntp false >/dev/null 2>&1
    local sys_time=""
    for url in "http://www.cloudflare.com" "http://www.baidu.com" "http://1.1.1.1"; do
        sys_time=$(curl -sI --max-time 3 "$url" 2>/dev/null | grep -i '^date:' | sed 's/^[Dd]ate: //g' | tr -d '\r')
        [ -n "$sys_time" ] && break
    done
    if [ -n "$sys_time" ]; then
        date -s "$sys_time" >/dev/null 2>&1
        hwclock -w >/dev/null 2>&1
    fi
    echo -e "${GREEN}✅ 系统时间: $(date)${NC}"
}

url_encode() { jq -rn --arg v "$1" '$v|@uri'; }

# ================= 高阶 XanMod BBRv3 安装支持函数 =================
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

# ================= 顶级大厂域名优选模块 =================
SNI_DOMAINS=(
    "www.bing.com" "www.apple.com" "www.cloudflare.com" "www.amazon.com" "www.microsoft.com"
    "www.icloud.com" "www.office.com" "aws.amazon.com" "azure.microsoft.com" "dl.google.com"
    "cdn.apple.com" "api.apple.com" "init.push.apple.com" "www.sony.com" "www.oracle.com"
    "www.ibm.com" "www.nvidia.com" "images.nvidia.com" "www.intel.com" "www.amd.com"
    "www.ebay.com" "www.paypal.com" "www.tesla.com" "www.mozilla.org" "www.cisco.com"
    "www.sap.com" "www.samsung.com" "www.huawei.com" "www.dell.com" "www.hp.com"
    "www.canva.com" "www.cdn77.org" "www.fastly.com" "www.akamai.com" "www.digitalocean.com"
)

_test_domain_latency() {
    local host="$1" result_file="$2"
    local t1 t2 ms
    t1=$(date +%s%3N 2>/dev/null)
    [[ ! "$t1" =~ ^[0-9]+$ ]] && t1=$(date +%s)000
    if timeout 2 openssl s_client -connect "${host}:443" -servername "${host}" </dev/null &>/dev/null; then
        t2=$(date +%s%3N 2>/dev/null)
        [[ ! "$t2" =~ ^[0-9]+$ ]] && t2=$(date +%s)000
        ms=$((t2 - t1))
        [ "$ms" -ge 0 ] 2>/dev/null && echo "${ms} ${host}" >> "$result_file" || echo "9999 ${host}" >> "$result_file"
    else
        echo "9999 ${host}" >> "$result_file"
    fi
}

select_best_sni() {
    local tmp_res="/tmp/sb_sni_speed"
    > "$tmp_res"
    echo -e "${YELLOW}[*] 正在测速优选大厂 SNI 伪装域名 (共 ${#SNI_DOMAINS[@]} 个)...${NC}"
    
    for domain in "${SNI_DOMAINS[@]}"; do
        _test_domain_latency "$domain" "$tmp_res"
    done
    
    local sorted_domains=$(grep -v "^9999" "$tmp_res" | sort -n)
    rm -f "$tmp_res"
    
    if [ -z "$sorted_domains" ]; then 
        echo -e "${RED}❌ 所有域名测速失败！将使用默认域名 www.bing.com${NC}"
        echo "www.bing.com"
        return 0
    fi
    
    local best_domain=$(echo "$sorted_domains" | head -n 1 | awk '{print $2}')
    local best_time=$(echo "$sorted_domains" | head -n 1 | awk '{print $1}')
    
    echo -e "${GREEN}=========================================="
    echo -e " SNI 测速排名 Top 5:"
    local i=1
    while IFS= read -r line; do
        local latency=$(echo "$line" | awk '{print $1}')
        local dom=$(echo "$line" | awk '{print $2}')
        printf "  ${GREEN}[%d]${NC} %-30s ${YELLOW}%s ms${NC}\n" "$i" "$dom" "$latency"
        i=$((i+1))
        [ $i -gt 5 ] && break
    done <<< "$sorted_domains"
    echo -e "=========================================="
    echo -e "${GREEN}✓ 已自动选择最快域名: ${CYAN}${best_domain}${NC} (${best_time} ms)"
    echo "$best_domain"
}

# ================= 核心部署逻辑 =================
check_node_name() {
    [ ${#1} -gt 20 ] || [[ "$1" =~ [\/\\|\&\;\$\<\>\`\!\?\*\(\)\ ] ]] && echo -e "${RED}❌ 名称无效！${NC}" && return 1
    return 0
}

check_ip_format() {
    [[ ! "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo -e "${RED}❌ IP 格式不正确！${NC}" && return 1
    return 0
}

check_pub_key() {
    [[ ! "$1" =~ ^[A-Za-z0-9+/]{43}=$ ]] && return 1
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
    force_sync_time

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
Reality公钥: $SB_PUB
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

add_relay_port() {
    clear; echo -e "${YELLOW}━━━ 中转机-为现有落地机加端口 ━━━${NC}"
    [ ! -f "$WG_CONF" ] && echo -e "${RED}请先初始化中转机${NC}" && pause_return && return
    
    echo -e "当前已绑定的落地机内网IP："
    grep "^AllowedIPs = 10.0.0." $WG_CONF | awk '{print $3}' | cut -d'.' -f4 | cut -d'/' -f1 | while read ip; do echo "  10.0.0.$ip"; done
    
    while true; do
        read -p "请输入要加端口的落地机内网IP (如 10.0.0.2): " LAND_IP < /dev/tty
        check_ip_format "$LAND_IP" && grep -q "${LAND_IP}/32" $WG_CONF && break
    done
    
    while true; do 
        read -p "请输入新的客户端端口: " MAP_PORT < /dev/tty
        [[ "$MAP_PORT" =~ ^[0-9]+$ ]] && [ "$MAP_PORT" -ge 1 ] && [ "$MAP_PORT" -le 65535 ] || { echo -e "${RED}端口无效${NC}"; continue; }
        grep -q "^${MAP_PORT}|" "$NODES_INFO" 2>/dev/null && echo -e "${RED}❌ 端口 ${MAP_PORT} 已被占用！请换一个：${NC}" || break
    done
    
    while true; do read -p "请输入落地机对应的监听端口: " LAND_PORT < /dev/tty; [[ "$LAND_PORT" =~ ^[0-9]+$ ]] && [ "$LAND_PORT" -ge 1 ] && [ "$LAND_PORT" -le 65535 ] && break; echo -e "${RED}端口无效${NC}"; done
    
    while true; do 
        read -p "请输入节点备注名称 (如 HK-Port2): " NODE_NAME < /dev/tty
        [ -n "$NODE_NAME" ] && check_node_name "$NODE_NAME" && break
    done
    
    grep -q "^${MAP_PORT}|" "$NODES_INFO" 2>/dev/null && echo -e "${RED}❌ 端口 ${MAP_PORT} 刚刚被占用！操作取消。${NC}" && pause_return && return
    
    while iptables -t nat -D PREROUTING -p tcp --dport "$MAP_PORT" 2>/dev/null; do :; done
    while iptables -t nat -D PREROUTING -p udp --dport "$MAP_PORT" 2>/dev/null; do :; done
    
    iptables -t nat -I PREROUTING 1 -p tcp --dport "$MAP_PORT" -j DNAT --to-destination "${LAND_IP}:${LAND_PORT}"
    iptables -t nat -I PREROUTING 1 -p udp --dport "$MAP_PORT" -j DNAT --to-destination "${LAND_IP}:${LAND_PORT}"
    
    allow_port "$MAP_PORT"
    netfilter-persistent save > /dev/null 2>&1
    
    touch "$NODES_INFO"; sed -i "/|${NODE_NAME}$/d" "$NODES_INFO"; echo "${MAP_PORT}|${LAND_IP}|${LAND_PORT}|${NODE_NAME}" >> "$NODES_INFO"
    echo -e "${GREEN}✓ 中转机端口添加成功！请确保云后台已放行 ${MAP_PORT} 端口${NC}"
    pause_return
}

add_landing_port() {
    clear; echo -e "${YELLOW}━━━ 落地机-新增端口节点 ━━━${NC}"
    [ ! -f "$LAND_INFO" ] || [ ! -f "/etc/sing-box/config.json" ] && echo -e "${RED}请先执行选项4部署基础节点${NC}" && pause_return && return
    ! jq empty /etc/sing-box/config.json 2>/dev/null && echo -e "${RED}❌ config.json 错误！${NC}" && pause_return && return
    
    local relay_ip=$(grep "中转机IP:" "$LAND_INFO" | head -1 | awk '{print $2}')
    [ -z "$relay_ip" ] && echo -e "${RED}无法读取中转机IP${NC}" && pause_return && return
    
    while true; do 
        read -p "监听端口: " LAND_PORT < /dev/tty
        [[ "$LAND_PORT" =~ ^[0-9]+$ ]] && [ "$LAND_PORT" -ge 1 ] && [ "$LAND_PORT" -le 65535 ] || { echo -e "${RED}端口无效${NC}"; continue; }
        ss -tulnp | grep -qE ":$LAND_PORT\b" && echo -e "${RED}❌ 端口占用${NC}" || break
    done
    
    while true; do read -p "客户端连接端口: " MAP_PORT < /dev/tty; [[ "$MAP_PORT" =~ ^[0-9]+$ ]] && break; echo -e "${RED}端口无效${NC}"; done
    while true; do read -p "节点备注名称: " NODE_NAME < /dev/tty; [ -n "$NODE_NAME" ] && check_node_name "$NODE_NAME" && break; done
    
    local exist_priv=$(jq -r '.inbounds[] | select(.tls.reality != null) | .tls.reality.private_key' /etc/sing-box/config.json | head -1)
    local exist_sid=$(jq -r '.inbounds[] | select(.tls.reality != null) | .tls.reality.short_id[0]' /etc/sing-box/config.json | head -1)
    local exist_sni=$(jq -r '.inbounds[] | select(.tls.reality != null) | .tls.server_name' /etc/sing-box/config.json | head -1)
    
    [ -z "$exist_priv" ] || [ -z "$exist_sid" ] || [ -z "$exist_sni" ] && echo -e "${RED}❌ 读取基础配置失败，请检查 Sing-box 配置文件！${NC}" && pause_return && return
    
    local exist_pub=""
    
    # 1. 尝试从记录文件直接读取公钥
    if grep -q "^Reality公钥:" "$LAND_INFO"; then
        exist_pub=$(grep "^Reality公钥:" "$LAND_INFO" | head -1 | awk '{print $2}')
    fi
    
    # 2. 终极修复：使用 sed 替代 cut 提取链接中的 pbk，防止公钥末尾的 = 被截断
    if [ -z "$exist_pub" ] || ! check_pub_key "$exist_pub"; then
        local link_pub=$(grep -oE 'pbk=[^&]+' "$LAND_INFO" | head -1 | sed 's/^pbk=//')
        if [ -n "$link_pub" ]; then
            # 补齐公钥末尾的 =
            [[ "$link_pub" != *= ]] && link_pub="${link_pub}="
            exist_pub="$link_pub"
        fi
    fi
    
    # 3. 尝试用 wg 命令从私钥反算
    if { [ -z "$exist_pub" ] || ! check_pub_key "$exist_pub"; } && command -v wg >/dev/null 2>&1; then
        local tmp_priv="$exist_priv"
        # 补齐私钥末尾的 = (wg 命令要求标准 Base64)
        [[ "$tmp_priv" != *= ]] && tmp_priv="${tmp_priv}="
        exist_pub=$(printf '%s\n' "$tmp_priv" | wg pubkey 2>/dev/null)
    fi
    
    # 4. 极端情况兜底：允许手动输入
    if [ -z "$exist_pub" ] || ! check_pub_key "$exist_pub"; then
        echo -e "${RED}❌ 无法自动提取公钥！${NC}"
        echo -e "${YELLOW}私有钥: ${exist_priv}${NC}"
        echo -e "${YELLOW}请手动输入第一个节点的 PublicKey (pbk)：${NC}"
        read -p "PublicKey (pbk): " exist_pub < /dev/tty
    fi
    
    if ! check_pub_key "$exist_pub"; then
        echo -e "${RED}❌ 公钥格式不正确！操作取消。${NC}"
        pause_return; return
    fi
    
    local UUID=$(/usr/local/bin/sing-box generate uuid 2>/dev/null)
    local tmp_json="/tmp/sb_add_$$.json"
    
    jq --arg p "$LAND_PORT" --arg u "$UUID" --arg s "$exist_sni" --arg pk "$exist_priv" --arg sid "$exist_sid" \
       --arg listen "0.0.0.0" --arg pub "$exist_pub" \
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
       }]' /etc/sing-box/config.json > "$tmp_json" 2>/dev/null
    
    ! jq empty "$tmp_json" 2>/dev/null && echo -e "${RED}❌ JSON 生成失败${NC}" && rm -f "$tmp_json" && pause_return && return
    mv -f "$tmp_json" /etc/sing-box/config.json
    systemctl restart sing-box
    allow_port "$LAND_PORT"
    
    SAFE_NAME=$(url_encode "$NODE_NAME")
    VLESS_LINK="vless://${UUID}@${relay_ip}:${MAP_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${exist_sni}&fp=chrome&pbk=${exist_pub}&sid=${exist_sid}&spx=%2F&type=tcp#WG-${SAFE_NAME}"
    
    sed -i "/# ${NODE_NAME} START/,/# ${NODE_NAME} END/d" "$LAND_INFO"
    cat >> "$LAND_INFO" << EOF
# ${NODE_NAME} START
节点名称: $NODE_NAME
中转机IP: $relay_ip
客户端端口: $MAP_PORT
落地机端口: $LAND_PORT
SNI: $exist_sni
Reality公钥: $exist_pub
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
    [ ! -f "$NODES_INFO" ] || [ ! -s "$NODES_INFO" ] && echo -e "${RED}暂无节点可删除${NC}" && pause_return && return
    
    printf "${GREEN}%-10s | %-15s | %-8s | %-15s\n${NC}" "端口" "落地IP" "落地端口" "名称"
    while IFS='|' read -r p lip lp n; do printf "%-10s | %-15s | %-8s | %-15s\n" "$p" "$lip" "$lp" "$n"; done < "$NODES_INFO"
    
    read -p "请输入要删除的客户端端口: " DEL_PORT < /dev/tty
    [ -z "$DEL_PORT" ] && echo -e "${RED}❌ 端口不能为空！${NC}" && pause_return && return
    
    line=$(grep "^${DEL_PORT}|" "$NODES_INFO")
    [ -z "$line" ] && echo -e "${RED}未找到端口 ${DEL_PORT}${NC}" && pause_return && return
    
    d_ip=$(echo "$line" | cut -d'|' -f2); d_name=$(echo "$line" | cut -d'|' -f4)
    
    while iptables -t nat -D PREROUTING -p tcp --dport "$DEL_PORT" 2>/dev/null; do :; done
    while iptables -t nat -D PREROUTING -p udp --dport "$DEL_PORT" 2>/dev/null; do :; done
    netfilter-persistent save > /dev/null 2>&1
    
    if ! grep -q "|${d_ip}|" "$NODES_INFO"; then
        sed -i "/# ${d_name}/,/AllowedIPs = ${d_ip}\/32/d" "$WG_CONF"
        wg-quick down wg0 >/dev/null 2>&1
        restart_wg || { pause_return; return; }
        while iptables -t nat -D POSTROUTING -d "$d_ip" -j MASQUERADE 2>/dev/null; do :; done
        iptables -D FORWARD -d "$d_ip" -j ACCEPT 2>/dev/null; iptables -D FORWARD -s "$d_ip" -j ACCEPT 2>/dev/null
        netfilter-persistent save > /dev/null 2>&1
    fi
    
    sed -i "/^${DEL_PORT}|/d" "$NODES_INFO"
    echo -e "${GREEN}✓ 端口 ${DEL_PORT} 已彻底删除${NC}"
    pause_return
}

delete_landing_by_port() {
    clear; echo -e "${YELLOW}━━━ 落地机按端口删除 ━━━${NC}"
    [ ! -f "$LAND_INFO" ] || [ ! -s "$LAND_INFO" ] && echo -e "${RED}无节点记录${NC}" && pause_return && return
    
    grep "落地机端口:" "$LAND_INFO" | awk '{print $2}' | sort -u
    read -p "请输入要删除的落地机监听端口: " DEL_PORT < /dev/tty
    [ -z "$DEL_PORT" ] && echo -e "${RED}❌ 端口不能为空！${NC}" && pause_return && return
    
    ! jq empty /etc/sing-box/config.json 2>/dev/null && echo -e "${RED}❌ config.json 错误${NC}" && pause_return && return
    ! jq -e --argjson p "$DEL_PORT" '.inbounds[] | select(.listen_port == $p)' /etc/sing-box/config.json >/dev/null 2>&1 && echo -e "${RED}❌ 端口不存在${NC}" && pause_return && return
    
    local tmp_json="/tmp/sb_del_$$.json"
    jq --argjson p "$DEL_PORT" 'del(.inbounds[] | select(.listen_port == $p))' /etc/sing-box/config.json > "$tmp_json" 2>/dev/null
    ! jq empty "$tmp_json" 2>/dev/null && echo -e "${RED}❌ JSON 删除失败${NC}" && rm -f "$tmp_json" && pause_return && return
    mv -f "$tmp_json" /etc/sing-box/config.json
    
    local in_count=$(jq '.inbounds | length' /etc/sing-box/config.json 2>/dev/null)
    [ "$in_count" -eq 0 ] && systemctl stop sing-box >/dev/null 2>&1 || systemctl restart sing-box >/dev/null 2>&1
    
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
    [ ! -f "$WG_CONF" ] && echo -e "${RED}请先初始化中转机${NC}" && pause_return && return
    
    echo -e "当前已绑定的落地机内网IP："
    grep "^AllowedIPs = 10.0.0." $WG_CONF | awk '{print $3}' | cut -d'.' -f4 | cut -d'/' -f1 | while read ip; do echo "  10.0.0.$ip"; done
    
    read -p "请输入要测试的落地机内网IP (如 10.0.0.2): " TEST_IP < /dev/tty
    ! check_ip_format "$TEST_IP" && pause_return && return
    
    echo -e "${YELLOW}[*] 正在 Ping ${TEST_IP} ...${NC}"
    ping -c 4 $TEST_IP
    pause_return
}

uninstall_all() {
    clear; echo -e "${YELLOW}━━━ 一键卸载环境 ━━━${NC}"
    read -p "${RED}⚠️ 此操作将删除所有 WG 配置、Sing-box 及转发规则！确定？[y/N]: ${NC}" c < /dev/tty
    [[ ! "$c" =~ ^[Yy]$ ]] && { pause_return; return; }
    
    systemctl stop wg-quick@wg0 2>/dev/null; systemctl disable wg-quick@wg0 2>/dev/null
    systemctl stop sing-box 2>/dev/null; systemctl disable sing-box 2>/dev/null
    
    flush_wg_rules
    rm -rf /etc/wireguard /etc/sing-box /usr/local/bin/sing-box /etc/systemd/system/sing-box.service "$NODES_INFO" "$LAND_INFO" "$SYSCTL_FILE" "$IP_FORWARD_FILE"
    systemctl daemon-reload
    
    echo -e "${GREEN}✓ 卸载完成！${NC}"
    pause_return
}

list_relay_nodes() {
    clear; echo -e "${YELLOW}━━━ 中转机节点列表 ━━━${NC}"
    [ ! -f "$NODES_INFO" ] || [ ! -s "$NODES_INFO" ] && echo -e "${RED}暂无节点${NC}" && pause_return && return
    
    printf "${GREEN}%-10s | %-15s | %-8s | %-15s\n${NC}" "端口" "落地IP" "落地端口" "名称"
    while IFS='|' read -r p lip lp n; do printf "%-10s | %-15s | %-8s | %-15s\n" "$p" "$lip" "$lp" "$n"; done < "$NODES_INFO"
    pause_return
}

list_landing_nodes() {
    clear; echo -e "${YELLOW}━━━ 落地机节点信息 ━━━${NC}"
    [ ! -f "$LAND_INFO" ] || [ ! -s "$LAND_INFO" ] && echo -e "${RED}无记录${NC}" && pause_return && return
    cat "$LAND_INFO"; pause_return
}

check_root
prepare_env
while true; do
    clear
    echo -e "${CYAN}╔════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  WG 智能中转 v138.5 (字符串切割终极修复)  ║${NC}"
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
