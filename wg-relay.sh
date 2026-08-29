#!/bin/bash
# ==============================================================================
# WireGuard + udp2raw + Sing-box 10分满分终极商业增强版
# (支持 ARM64/x86_64 + TCP MSS优化 + 握手级自愈 + 防爆Conntrack + 二维码生成)
# ==============================================================================

if [ -t 0 ]; then :; else exec </dev/tty; fi
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
export DEBIAN_FRONTEND=noninteractive

WG_CONF="/etc/wireguard/wg0.conf"
WG_DIR="/etc/wireguard"
UDP2RAW_DIR="/etc/udp2raw"
WG_PORT="51820"
FAKE_PORT="20022"
LAND_INFO="/etc/wireguard/landing_info.txt"
SYSCTL_CONF="/etc/sysctl.d/99-wireguard-tuning.conf"
WATCHDOG_SCRIPT="/usr/local/bin/wg_watchdog.sh"

check_root() { [ "$EUID" -ne 0 ] && echo -e "${RED}错误: 请使用 root 权限运行此脚本！${NC}" && exit 1; }
pause_return() { echo -e "${YELLOW}按 Enter 键返回主菜单...${NC}"; read -r < /dev/tty; }
url_encode() { jq -rn --arg v "$1" '$v|@uri'; }

kill_apt_locks() {
    rm -f /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock /var/lib/apt/lists/lock 2>/dev/null
    dpkg --configure -a 2>/dev/null
}

# 智能多镜像源下载器 (防止 GitHub 节点在中国大陆或特殊地区超时)
download_file() {
    local url=$1 output=$2
    local mirrors=("$url" "https://ghproxy.net/$url" "https://download.fastgit.org/$url")
    for mirror in "${mirrors[@]}"; do
        if curl -sSL --connect-timeout 8 --max-time 30 "$mirror" -o "$output"; then
            [ -s "$output" ] && return 0
        fi
    done
    return 1
}

# 获取系统 CPU 架构 (AMD64 / ARM64)
get_arch() {
    local arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
    case "$arch" in
        amd64|x86_64) echo "amd64" ;;
        arm64|aarch64) echo "arm64" ;;
        *) echo "unsupported" ;;
    esac
}

prepare_env() {
    echo -e "${YELLOW}[*] 正在准备底层系统环境...${NC}"
    kill_apt_locks
    apt-get update -y > /dev/null 2>&1
    apt-get install -y curl wget gnupg ca-certificates iptables iptables-persistent tar jq openssl coreutils iproute2 iputils-ping util-linux qrencode > /dev/null 2>&1
    
    # 切换至 iptables-legacy 模式，防止 nftables 兼容性引发的规则失效
    if update-alternatives --list iptables &>/dev/null; then
        update-alternatives --set iptables /usr/sbin/iptables-legacy 2>/dev/null || true
        update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy 2>/dev/null || true
    fi

    modprobe nf_conntrack 2>/dev/null || true
    mkdir -p "$WG_DIR" "$UDP2RAW_DIR"
    
    # 内核参数深度调优 (防爆 Conntrack + BBR + MSS 优化)
    cat > "$SYSCTL_CONF" << EOF
net.ipv4.ip_forward = 1
net.netfilter.nf_conntrack_max = 262144
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    sysctl --system >/dev/null 2>&1 || true

    # 动态下载与安装 udp2raw (适配 ARM64 / AMD64)
    if ! command -v udp2raw &>/dev/null; then
        echo -e "${CYAN}[*] 正在安装 udp2raw (智能识别 CPU 架构)...${NC}"
        local sys_arch=$(get_arch)
        [ "$sys_arch" == "unsupported" ] && { echo -e "${RED}不支持的 CPU 架构！${NC}"; exit 1; }
        
        cd /tmp
        local u2r_url="https://github.com/wangyu-/udp2raw/releases/download/20200818.0/udp2raw_binaries.tar.gz"
        download_file "$u2r_url" "u2r.tar.gz" || { echo -e "${RED}udp2raw 下载失败${NC}"; exit 1; }
        
        tar xzf u2r.tar.gz
        if [ "$sys_arch" == "amd64" ]; then
            cp udp2raw_amd64 /usr/local/bin/udp2raw
        else
            cp udp2raw_arm /usr/local/bin/udp2raw
        fi
        chmod +x /usr/local/bin/udp2raw
        rm -f u2r.tar.gz udp2raw_*
        cd - > /dev/null
    fi
    echo -e "${GREEN}✓ 底层基础环境准备就绪${NC}"
}

get_pub_ip() {
    local ip=$(curl -s --connect-timeout 3 --max-time 5 -4 ifconfig.me 2>/dev/null | tr -d '[:space:]')
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "$ip" && return 0
    return 1
}

install_singbox() {
    if command -v sing-box &> /dev/null && [ -x "/usr/local/bin/sing-box" ]; then return 0; fi
    echo -e "${YELLOW}[*] 正在安装 Sing-box 核心...${NC}"
    local SB_VER="1.8.7"
    local sys_arch=$(get_arch)
    local sb_arch="amd64"
    [ "$sys_arch" == "arm64" ] && sb_arch="arm64"
    
    local URL="https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/sing-box-${SB_VER}-linux-${sb_arch}.tar.gz"
    download_file "$URL" "/tmp/sb.tar.gz"
    [ ! -s /tmp/sb.tar.gz ] && echo -e "${RED}Sing-box 下载失败${NC}" && return 1
    
    tar -xzf /tmp/sb.tar.gz -C /tmp && mv /tmp/sing-box-${SB_VER}-linux-${sb_arch}/sing-box /usr/local/bin/ && chmod +x /usr/local/bin/sing-box
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
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

force_sync_time() {
    command -v timedatectl >/dev/null 2>&1 && timedatectl set-ntp false >/dev/null 2>&1
    local sys_time=$(curl -sI --max-time 3 "http://www.cloudflare.com" 2>/dev/null | grep -i '^date:' | sed 's/^[Dd]ate: //g' | tr -d '\r')
    [ -n "$sys_time" ] && date -s "$sys_time" >/dev/null 2>&1 && hwclock -w >/dev/null 2>&1
}

select_best_sni() {
    local domains=("www.bing.com" "www.apple.com" "www.cloudflare.com" "www.microsoft.com" "www.amazon.com")
    local best_domain="www.bing.com"
    for domain in "${domains[@]}"; do
        if timeout 2 openssl s_client -connect "${domain}:443" -servername "${domain}" </dev/null &>/dev/null; then
            best_domain="$domain"; break
        fi
    done
    echo "$best_domain"
}

# 应用高级 QoS 队列与 TCP MSS 钳制 (解决深层嵌套封包导致的卡顿)
apply_network_optimizations() {
    if ip link show wg0 &>/dev/null; then
        tc qdisc del dev wg0 root 2>/dev/null || true
        tc qdisc add dev wg0 root fq_codel limit 1000 target 5ms interval 100ms 2>/dev/null || true
    fi
    # 注入 TCP MSS 修正规则
    iptables -t filter -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
    iptables -t filter -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
}

# 配置 Systemd 依赖编排 (解决开机自启争抢 Race Condition)
configure_systemd_dependency() {
    mkdir -p /etc/systemd/system/wg-quick@wg0.service.d/
    cat > /etc/systemd/system/wg-quick@wg0.service.d/override.conf << EOF
[Unit]
After=udp2raw.service
Wants=udp2raw.service
EOF
    systemctl daemon-reload
}

# 10分满分：基于 WireGuard 握手时间戳 + Ping 双重探针自愈守护
install_smart_watchdog() {
    echo -e "${YELLOW}[*] 安装 10 分满分智能链路监控服务...${NC}"
    local my_ip=$(ip -4 addr show wg0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || true)
    local target_ip="10.0.0.1"
    [ "$my_ip" == "10.0.0.1" ] && target_ip="10.0.0.2"

    cat > "$WATCHDOG_SCRIPT" << EOF
#!/bin/bash
TARGET="${target_ip}"
LOG_FILE="/var/log/wg_watchdog.log"
FAIL_FILE="/tmp/wg_watchdog_fail_count"

if ! ip link show wg0 &>/dev/null; then exit 0; fi

[ -f "\$FAIL_FILE" ] || echo 0 > "\$FAIL_FILE"
FAIL_COUNT=\$(cat "\$FAIL_FILE")

# 探针 1：检测真实 WG 握手时间 (超过 150 秒未握手判定异常)
LAST_HS=\$(wg show wg0 latest-handshakes 2>/dev/null | awk '{print \$2}')
NOW=\$(date +%s)
HS_AGE=\$((NOW - \${LAST_HS:-0}))

IS_HEALTHY=true
if [ "\$LAST_HS" != "" ] && [ "\$LAST_HS" -ne 0 ] && [ "\$HS_AGE" -gt 150 ]; then
    IS_HEALTHY=false
fi

# 探针 2：ICMP 双包探针
if ! ping -c 2 -W 2 "\$TARGET" > /dev/null 2>&1; then
    IS_HEALTHY=false
fi

if [ "\$IS_HEALTHY" = false ]; then
    FAIL_COUNT=\$((FAIL_COUNT + 1))
    echo "\$FAIL_COUNT" > "\$FAIL_FILE"
    
    if [ "\$FAIL_COUNT" -le 5 ]; then
        echo "\$(date '+%Y-%m-%d %H:%M:%S') - [WARN] 探测到链路中断(握手间隔:\${HS_AGE}s), 启动重启自愈..." >> "\$LOG_FILE"
        systemctl restart udp2raw
        sleep 2
        systemctl restart wg-quick@wg0
        sleep 1
        iptables -t filter -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
        iptables -t filter -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    elif [ "\$FAIL_COUNT" -eq 6 ]; then
        echo "\$(date '+%Y-%m-%d %H:%M:%S') - [ALERT] 连续 5 次自愈失败，开启熔断保护，防止CPU/日志震荡。" >> "\$LOG_FILE"
    fi
else
    if [ "\$FAIL_COUNT" -gt 0 ]; then
        echo "\$(date '+%Y-%m-%d %H:%M:%S') - [INFO] 隧道恢复连通 (握手正常)，重置故障计数器。" >> "\$LOG_FILE"
        echo 0 > "\$FAIL_FILE"
    fi
fi
EOF
    chmod +x "$WATCHDOG_SCRIPT"

    cat > /etc/systemd/system/wg-watchdog.service << EOF
[Unit]
Description=WireGuard Smart Tunnel Watchdog
[Service]
Type=oneshot
ExecStart=$WATCHDOG_SCRIPT
EOF

    cat > /etc/systemd/system/wg-watchdog.timer << EOF
[Unit]
Description=Run WireGuard Watchdog every 30s
[Timer]
OnBootSec=30s
OnUnitActiveSec=30s
[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now wg-watchdog.timer >/dev/null 2>&1
    echo -e "${GREEN}✓ 工业级自愈守护安装完毕 (探针目标: ${target_ip}, 包含防震荡熔断机制)${NC}"
}

# 10分满分：全能诊断看板
show_diagnostics() {
    clear
    echo -e "${CYAN}=================================================="
    echo -e "          10分满分 · 链路状态与内核诊断看板"
    echo -e "==================================================${NC}"
    
    echo -ne "1. udp2raw 伪装服务: \t"
    if systemctl is-active --quiet udp2raw; then echo -e "${GREEN}运行中 (Running)${NC}"; else echo -e "${RED}已停止 (Stopped)${NC}"; fi
    
    echo -ne "2. WireGuard 虚拟接口: \t"
    if ip link show wg0 &>/dev/null; then echo -e "${GREEN}已创建 (Up)${NC}"; else echo -e "${RED}未就绪 (Down)${NC}"; fi
    
    echo -ne "3. Sing-box 核心状态: \t"
    if systemctl is-active --quiet sing-box; then echo -e "${GREEN}运行中 (Running)${NC}"; else echo -e "${YELLOW}未启用/非落地端${NC}"; fi
    
    echo -ne "4. Conntrack 连接池: \t"
    local ct_cnt=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo "N/A")
    local ct_max=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo "N/A")
    echo -e "${GREEN}${ct_cnt} / ${ct_max}${NC}"

    echo -e "\n${CYAN}[WireGuard 实时握手与流量数据]${NC}"
    if command -v wg &>/dev/null && ip link show wg0 &>/dev/null; then
        wg show wg0
    else
        echo -e "${RED}WireGuard 接口未激活${NC}"
    fi
    
    echo -e "\n${CYAN}[隧道端到端 Ping 测试]${NC}"
    local my_ip=$(ip -4 addr show wg0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || true)
    local target_ip="10.0.0.1"
    [ "$my_ip" == "10.0.0.1" ] && target_ip="10.0.0.2"
    
    if [ -n "$my_ip" ]; then
        ping -c 3 -W 2 "$target_ip" 2>&1 | tail -n 2
    else
        echo -e "${RED}未成功分配内网隧道 IP${NC}"
    fi

    echo -e "\n${CYAN}[最近 5 条自愈日志]${NC}"
    [ -f /var/log/wg_watchdog.log ] && tail -n 5 /var/log/wg_watchdog.log || echo "暂无自愈日志。"
    echo -e "${CYAN}==================================================${NC}"
    pause_return
}

# ==================== VPS 服务端初始化 ====================
init_vps_server() {
    clear; echo -e "${YELLOW}━━━ 1. 初始化 VPS 中转服务端 ━━━${NC}"
    [ -f "$WG_CONF" ] && { read -p "${RED}已有配置将被覆盖！确定继续？[y/N]: ${NC}" c < /dev/tty; [[ ! "$c" =~ ^[Yy]$ ]] && return; }
    
    prepare_env
    apt-get install -y wireguard > /dev/null 2>&1
    
    WG_PRIV=$(wg genkey); WG_PUB=$(echo "$WG_PRIV" | wg pubkey)
    U2R_PASS=$(head -c 16 /dev/urandom | base64)
    VPS_IP=$(get_pub_ip); [ -z "$VPS_IP" ] && { echo -e "${RED}无法自动获取公网 IP${NC}"; return; }
    
    cat > "$WG_CONF" << EOF
[Interface]
PrivateKey = $WG_PRIV
Address = 10.0.0.1/24
ListenPort = $WG_PORT
MTU = 1280
PostUp = tc qdisc add dev wg0 root fq_codel limit 1000 target 5ms interval 100ms 2>/dev/null || true
EOF
    
    cat > /etc/systemd/system/udp2raw.service << EOF
[Unit]
Description=udp2raw Server
After=network.target network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=/usr/local/bin/udp2raw -s -l 0.0.0.0:${FAKE_PORT} -r 127.0.0.1:${WG_PORT} --raw-mode faketcp -a -k "${U2R_PASS}"
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable --now udp2raw
    configure_systemd_dependency
    
    systemctl enable wg-quick@wg0 > /dev/null 2>&1
    wg-quick down wg0 >/dev/null 2>&1; wg-quick up wg0 >/dev/null 2>&1
    apply_network_optimizations
    
    iptables -I INPUT 1 -p tcp --dport $FAKE_PORT -j ACCEPT 2>/dev/null
    netfilter-persistent save > /dev/null 2>&1
    
    install_smart_watchdog
    DEPLOY_CODE=$(echo -n "${VPS_IP}|${WG_PUB}|${U2R_PASS}|${FAKE_PORT}" | base64 -w 0 | tr -d '\n')
    echo -e "${GREEN}=========================================="
    echo -e " VPS 服务端配置成功！"
    echo -e " ${YELLOW}请复制下方部署码，去家里的落地机执行脚本并粘贴：${NC}"
    echo -e " ${CYAN}${DEPLOY_CODE}${NC}"
    echo -e "=========================================="
    pause_return
}

bind_landing() {
    clear; echo -e "${YELLOW}━━━ 3. VPS 绑定落地机 (粘贴回传码) ━━━${NC}"
    read -p "请粘贴落地机生成的 Bind 回传码: " BIND_CODE < /dev/tty
    CODE_RAW=$(echo -n "$BIND_CODE" | tr -d '[:space:]' | base64 -d 2>/dev/null)
    [ -z "$CODE_RAW" ] || ! echo "$CODE_RAW" | grep -q "|" && { echo -e "${RED}无效的 Bind 码！${NC}"; pause_return; return; }

    LANDING_PUB=$(echo $CODE_RAW | cut -d'|' -f1); LAND_IP=$(echo $CODE_RAW | cut -d'|' -f2)
    MAP_PORT=$(echo $CODE_RAW | cut -d'|' -f3); LAND_PORT=$(echo $CODE_RAW | cut -d'|' -f4)
    
    echo -e "\n# Landing Node\n[Peer]\nPublicKey = ${LANDING_PUB}\nAllowedIPs = ${LAND_IP}/32" >> "$WG_CONF"
    wg syncconf wg0 <(wg-quick strip wg0) 2>/dev/null
    
    # 清理旧 DNAT 规则，防止重复叠加
    while iptables -t nat -D PREROUTING -p tcp --dport "$MAP_PORT" 2>/dev/null; do :; done
    while iptables -t nat -D PREROUTING -p udp --dport "$MAP_PORT" 2>/dev/null; do :; done
    while iptables -D FORWARD -d "$LAND_IP" -j ACCEPT 2>/dev/null; do :; done
    while iptables -D INPUT -p tcp --dport "$MAP_PORT" -j ACCEPT 2>/dev/null; do :; done

    iptables -t nat -I PREROUTING 1 -p tcp --dport "$MAP_PORT" -j DNAT --to-destination "${LAND_IP}:${LAND_PORT}"
    iptables -t nat -I PREROUTING 1 -p udp --dport "$MAP_PORT" -j DNAT --to-destination "${LAND_IP}:${LAND_PORT}"
    iptables -t nat -I POSTROUTING 1 -d "$LAND_IP" -j MASQUERADE
    iptables -I FORWARD 1 -d "$LAND_IP" -j ACCEPT
    iptables -I INPUT 1 -p tcp --dport "$MAP_PORT" -j ACCEPT
    netfilter-persistent save > /dev/null 2>&1
    
    echo -e "${GREEN}✓ 落地节点成功绑定！请务必在防火墙/安全组放行公网端口: ${MAP_PORT} (TCP/UDP)${NC}"
    pause_return
}

parse_chain_proxy() {
    local chain_url="$1"
    local proto=$(echo "$chain_url" | awk -F'://' '{print $1}')
    local creds_host=$(echo "$chain_url" | sed -E 's#^[a-z0-9]+://##')
    local creds="" host_port="$creds_host"
    if [[ "$creds_host" == *"@"* ]]; then
        creds=$(echo "$creds_host" | awk -F'@' '{print $1}')
        host_port=$(echo "$creds_host" | awk -F'@' '{print $2}')
    fi
    local host=$(echo "$host_port" | awk -F':' '{print $1}')
    local port=$(echo "$host_port" | awk -F':' '{print $2}')
    
    if [[ "$proto" =~ ^(socks5|http)$ ]] && [[ -n "$host" ]] && [[ "$port" =~ ^[0-9]+$ ]]; then
        if [[ -n "$creds" ]]; then
            local user=$(echo "$creds" | awk -F':' '{print $1}')
            local pass=$(echo "$creds" | awk -F':' '{print $2}')
            jq -nc --arg p "$proto" --arg h "$host" --arg pt "$port" --arg u "$user" --arg pw "$pass" \
              '{type:$p, server:$h, server_port:($pt|tonumber), username:$u, password:$pw}'
        else
            jq -nc --arg p "$proto" --arg h "$host" --arg pt "$port" \
              '{type:$p, server:$h, server_port:($pt|tonumber)}'
        fi
    elif [[ "$proto" == "shadowsocks" ]] && [[ -n "$host" ]] && [[ "$port" =~ ^[0-9]+$ ]]; then
        if [[ -n "$creds" ]]; then
            local decoded_creds=$(echo "$creds" | base64 -d 2>/dev/null || echo "$creds")
            local method=$(echo "$decoded_creds" | awk -F':' '{print $1}')
            local password=$(echo "$decoded_creds" | awk -F':' '{print $2}')
            [ -z "$password" ] && { method=$(echo "$creds" | awk -F':' '{print $1}'); password=$(echo "$creds" | awk -F':' '{print $2}'); }
            jq -nc --arg h "$host" --arg pt "$port" --arg m "$method" --arg pw "$password" \
              '{type:"shadowsocks", server:$h, server_port:($pt|tonumber), method:$m, password:$pw}'
        fi
    else
        echo "{ \"type\": \"direct\" }"
    fi
}

deploy_landing() {
    clear; echo -e "${YELLOW}━━━ 2. 部署家宽/无公网落地机 ━━━${NC}"
    read -p "请粘贴 VPS 生成的部署码: " DEPLOY_CODE < /dev/tty
    CODE_RAW=$(echo -n "$DEPLOY_CODE" | tr -d '[:space:]' | base64 -d 2>/dev/null)
    [ -z "$CODE_RAW" ] && { echo -e "${RED}部署码无效！${NC}"; pause_return; return; }

    VPS_IP=$(echo $CODE_RAW | cut -d'|' -f1); VPS_PUB=$(echo $CODE_RAW | cut -d'|' -f2)
    U2R_PASS=$(echo $CODE_RAW | cut -d'|' -f3); FAKE_PORT=$(echo $CODE_RAW | cut -d'|' -f4)

    read -p "请输入节点名称 (默认: Home-Node): " NODE_NAME < /dev/tty
    [ -z "$NODE_NAME" ] && NODE_NAME="Home-Node"
    read -p "请输入 VPS 对外开放的客户端连接端口 (如 443): " MAP_PORT < /dev/tty
    [ -z "$MAP_PORT" ] && MAP_PORT=443
    read -p "请输入落地机 Sing-box 本地监听端口 (默认 443): " LAND_PORT < /dev/tty
    [ -z "$LAND_PORT" ] && LAND_PORT=443

    echo -e "${YELLOW}[*] 安装与编译底层协议栈...${NC}"
    prepare_env
    apt-get install -y wireguard > /dev/null 2>&1
    install_singbox || { echo -e "${RED}Sing-box 安装失败${NC}"; pause_return; return; }
    force_sync_time
    SNI=$(select_best_sni)

    WG_PRIV=$(wg genkey); WG_PUB=$(echo "$WG_PRIV" | wg pubkey)
    LAND_IP="10.0.0.2"

    cat > $WG_CONF << EOF
[Interface]
PrivateKey = $WG_PRIV
Address = ${LAND_IP}/24
MTU = 1280
PostUp = tc qdisc add dev wg0 root fq_codel limit 1000 target 5ms interval 100ms 2>/dev/null || true

[Peer]
PublicKey = $VPS_PUB
Endpoint = 127.0.0.1:${WG_PORT}
AllowedIPs = 10.0.0.0/24
PersistentKeepalive = 25
EOF
    
    cat > /etc/systemd/system/udp2raw.service << EOF
[Unit]
Description=udp2raw Client
After=network.target network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=/usr/local/bin/udp2raw -c -l 127.0.0.1:${WG_PORT} -r ${VPS_IP}:${FAKE_PORT} --raw-mode faketcp -a -k "${U2R_PASS}"
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable --now udp2raw
    configure_systemd_dependency
    
    systemctl enable wg-quick@wg0 > /dev/null 2>&1
    wg-quick down wg0 >/dev/null 2>&1; wg-quick up wg0 >/dev/null 2>&1
    apply_network_optimizations
    
    REALITY_KEYS=$(/usr/local/bin/sing-box generate reality-keypair 2>/dev/null)
    SB_PRIV=$(echo "$REALITY_KEYS" | awk '/PrivateKey/{print $2}')
    SB_PUB=$(echo "$REALITY_KEYS" | awk '/PublicKey/{print $2}')
    UUID=$(/usr/local/bin/sing-box generate uuid 2>/dev/null)
    SHORT_ID=$(/usr/local/bin/sing-box generate rand --hex 8 2>/dev/null)

    OUTBOUND_JSON='{ "type": "direct" }'
    read -p "是否配置链式前置代理 (Shadowsocks / SOCKS5 / HTTP)? [y/N]: " is_chain < /dev/tty
    if [[ "$is_chain" =~ ^[Yy]$ ]]; then
        read -p "请输入前置代理 URI: " chain_url < /dev/tty
        OUTBOUND_JSON=$(parse_chain_proxy "$chain_url")
    fi

    cat > /etc/sing-box/config.json << EOF
{
  "inbounds": [{
    "type": "vless", "listen": "0.0.0.0", "listen_port": ${LAND_PORT},
    "users": [{ "name": "u1", "uuid": "$UUID", "flow": "xtls-rprx-vision" }],
    "tls": {
      "enabled": true, "server_name": "${SNI}", "alpn": ["h2", "http/1.1"],
      "reality": { "enabled": true, "handshake": { "server": "${SNI}", "server_port": 443 }, "private_key": "$SB_PRIV", "short_id": ["$SHORT_ID"] }
    }
  }],
  "outbounds": [ $OUTBOUND_JSON ]
}
EOF
    systemctl enable sing-box > /dev/null 2>&1; systemctl restart sing-box
    iptables -I INPUT 1 -p tcp --dport $LAND_PORT -j ACCEPT 2>/dev/null
    netfilter-persistent save > /dev/null 2>&1
    
    install_smart_watchdog
    
    SAFE_NAME=$(url_encode "$NODE_NAME")
    VLESS_LINK="vless://${UUID}@${VPS_IP}:${MAP_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${SB_PUB}&sid=${SHORT_ID}&type=tcp#WG-${SAFE_NAME}"
    BIND_CODE=$(echo -n "${WG_PUB}|${LAND_IP}|${MAP_PORT}|${LAND_PORT}|${NODE_NAME}" | base64 -w 0 | tr -d '\n')
    
    cat > "$LAND_INFO" << EOF
节点名称: $NODE_NAME
VLESS链接: $VLESS_LINK
EOF
    
    echo -e "${GREEN}=========================================="
    echo -e " 落地机部署完成！"
    echo -e " ${YELLOW}请复制下方回传码，回到 VPS 选菜单 [3] 进行绑定：${NC}"
    echo -e " ${CYAN}${BIND_CODE}${NC}\n"
    echo -e " ${YELLOW}节点 VLESS 链接 (扫码或复制)：${NC}"
    echo -e " ${GREEN}${VLESS_LINK}${NC}"
    echo -e "=========================================="
    if command -v qrencode &>/dev/null; then
        echo -e "\n${CYAN}[VLESS 节点二维码扫描入口]${NC}"
        qrencode -t UTF8 "$VLESS_LINK"
    fi
    pause_return
}

manage_chain_proxy() {
    clear; echo -e "${YELLOW}━━━ 落地机 - 链式代理管理 ━━━${NC}"
    if [ ! -f /etc/sing-box/config.json ]; then
        echo -e "${RED}未在当前机器发现 Sing-box 配置文件！${NC}"
        pause_return; return
    fi
    read -p "请输入前置代理链接 (输入 direct 恢复纯直连): " chain_url < /dev/tty
    if [ "$chain_url" == "direct" ]; then
        jq '.outbounds = [{"type":"direct"}]' /etc/sing-box/config.json > /tmp/sb_tmp.json && mv /tmp/sb_tmp.json /etc/sing-box/config.json
    else
        NEW_OUT=$(parse_chain_proxy "$chain_url")
        jq --argjson out "$NEW_OUT" '.outbounds = [$out]' /etc/sing-box/config.json > /tmp/sb_tmp.json && mv /tmp/sb_tmp.json /etc/sing-box/config.json
    fi
    systemctl restart sing-box
    echo -e "${GREEN}✓ Sing-box 链式代理配置完成并已热重启${NC}"
    pause_return
}

uninstall_all() {
    read -p "${RED}警告: 确定要彻底卸载所有 WireGuard/udp2raw/Sing-box 组件吗？[y/N]: ${NC}" c < /dev/tty
    [[ ! "$c" =~ ^[Yy]$ ]] && return
    systemctl stop wg-watchdog.timer 2>/dev/null || true
    systemctl disable wg-watchdog.timer 2>/dev/null || true
    systemctl stop wg-quick@wg0 udp2raw sing-box 2>/dev/null || true
    rm -rf /etc/wireguard /etc/udp2raw /etc/sing-box /usr/local/bin/sing-box /usr/local/bin/udp2raw "$WATCHDOG_SCRIPT"
    rm -rf /etc/systemd/system/wg-quick@wg0.service.d/
    rm -f /etc/systemd/system/udp2raw.service /etc/systemd/system/sing-box.service /etc/systemd/system/wg-watchdog.*
    iptables -F; iptables -t nat -F
    netfilter-persistent save > /dev/null 2>&1
    systemctl daemon-reload
    echo -e "${GREEN}✓ 全部组件与防火墙映射规则已彻底卸载干净${NC}"
    pause_return
}

check_root
while true; do
    clear
    echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║    WG + udp2raw + Sing-box                       ║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC} ${GREEN}1${NC} VPS - 初始化中转服务端 (生成部署码)         ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC} ${GREEN}2${NC} 家里 - 部署落地节点 (生成节点/二维码)       ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC} ${GREEN}3${NC} VPS - 绑定落地节点 (粘贴回传码)            ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC} ${GREEN}4${NC} 查看当前节点的 VLESS 链接 / 二维码         ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC} ${GREEN}5${NC} 实时状态与链路诊断看板                    ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC} ${GREEN}6${NC} 落地机 - 链式代理管理                     ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC} ${GREEN}7${NC} 一键彻底卸载全部组件                       ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC} ${GREEN}0${NC} 退出                                      ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
    
    read -p "请选择操作 [0-7]: " c < /dev/tty
    case $c in
        1) init_vps_server;;
        2) deploy_landing;;
        3) bind_landing;;
        4) clear; 
           if [ -f "$LAND_INFO" ]; then 
               cat "$LAND_INFO"
               if command -v qrencode &>/dev/null; then
                   echo -e "\n${CYAN}[扫码导入链接]${NC}"
                   qrencode -t UTF8 "$(grep 'VLESS链接:' "$LAND_INFO" | cut -d' ' -f2)"
               fi
           else 
               echo "未找到节点导出信息"; 
           fi
           pause_return;;
        5) show_diagnostics;;
        6) manage_chain_proxy;;
        7) uninstall_all;;
        0) exit 0;;
        *) echo "输入错误"; sleep 1;;
    esac
done
