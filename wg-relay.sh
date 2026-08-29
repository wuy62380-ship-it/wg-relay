#!/bin/bash
# ==========================================================
# WireGuard + udp2raw + Sing-box 终极融合版 (反转架构 + 完整BBRv3 + 链式代理)
# 解决: 家宽无端口映射, UDP QoS封锁, 小白难部署, 流量二次中转
# ==========================================================

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
BBR_CONF="/etc/sysctl.d/99-bbr.conf"

check_root() { [ "$EUID" -ne 0 ] && echo -e "${RED}请使用root运行${NC}" && exit 1; }
pause_return() { echo -e "${YELLOW}按 Enter 键返回...${NC}"; read -r < /dev/tty; }
url_encode() { jq -rn --arg v "$1" '$v|@uri'; }

kill_apt_locks() {
    rm -f /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock /var/lib/apt/lists/lock 2>/dev/null
    dpkg --configure -a 2>/dev/null
}

# ==================== 环境与工具准备 ====================
prepare_env() {
    echo -e "${YELLOW}[*] 准备基础环境...${NC}"
    kill_apt_locks
    apt-get update -y > /dev/null 2>&1
    apt-get install -y curl wget gnupg ca-certificates iptables iptables-persistent tar jq openssl coreutils iproute2 iputils-ping util-linux > /dev/null 2>&1
    
    if update-alternatives --list iptables &>/dev/null; then
        update-alternatives --set iptables /usr/sbin/iptables-legacy 2>/dev/null || true
        update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy 2>/dev/null || true
    fi

    modprobe nf_conntrack 2>/dev/null
    mkdir -p "$WG_DIR" "$UDP2RAW_DIR"
    
    if ! command -v udp2raw &>/dev/null; then
        echo -e "${CYAN}[*] 下载 udp2raw...${NC}"
        local arch=$(dpkg --print-architecture)
        [[ "$arch" != "amd64" ]] && { echo -e "${RED}仅支持 amd64${NC}"; exit 1; }
        cd /tmp
        wget -qO u2r.tar.gz "https://github.com/wangyu-/udp2raw/releases/download/20200818.0/udp2raw_binaries.tar.gz"
        tar xzf u2r.tar.gz && cp udp2raw_amd64 /usr/local/bin/udp2raw && chmod +x /usr/local/bin/udp2raw
        rm -f u2r.tar.gz udp2raw_*
        cd - > /dev/null
    fi
    echo -e "${GREEN}✓ 环境就绪${NC}"
}

get_pub_ip() {
    local ip=$(curl -s --connect-timeout 3 --max-time 5 -4 ifconfig.me 2>/dev/null | tr -d '[:space:]')
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "$ip" && return 0
    return 1
}

# ==================== Sing-box 与 SNI 测速 ====================
install_singbox() {
    if command -v sing-box &> /dev/null && [ -x "/usr/local/bin/sing-box" ]; then return 0; fi
    echo -e "${YELLOW}[*] 下载 Sing-box...${NC}"
    SB_VER="1.8.7"
    URL="https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/sing-box-${SB_VER}-linux-amd64.tar.gz"
    timeout 30 wget -q -T 15 -t 2 -O /tmp/sb.tar.gz "$URL" 2>/dev/null || timeout 30 wget -q -T 15 -t 2 -O /tmp/sb.tar.gz "https://ghproxy.net/$URL" 2>/dev/null
    [ ! -s /tmp/sb.tar.gz ] && echo -e "${RED}下载失败${NC}" && return 1
    tar -xzf /tmp/sb.tar.gz -C /tmp && mv /tmp/sing-box-${SB_VER}-linux-amd64/sing-box /usr/local/bin/ && chmod +x /usr/local/bin/sing-box
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
    echo -e "${YELLOW}[*] 正在测速优选 SNI...${NC}" >&2
    local domains=("www.bing.com" "www.apple.com" "www.cloudflare.com" "www.microsoft.com" "www.amazon.com")
    local best_domain="www.bing.com"
    for domain in "${domains[@]}"; do
        if timeout 2 openssl s_client -connect "${domain}:443" -servername "${domain}" </dev/null &>/dev/null; then
            best_domain="$domain"; break
        fi
    done
    echo "$best_domain"
}

# ==================== VPS 中转机 (服务端) 模块 ====================
init_vps_server() {
    clear; echo -e "${YELLOW}━━━ 1. 初始化 VPS 服务端 ━━━${NC}"
    [ -f "$WG_CONF" ] && { read -p "${RED}已有配置将被覆盖！确定？[y/N]: ${NC}" c < /dev/tty; [[ ! "$c" =~ ^[Yy]$ ]] && return; }
    
    prepare_env
    apt-get install -y wireguard > /dev/null 2>&1
    
    WG_PRIV=$(wg genkey); WG_PUB=$(echo "$WG_PRIV" | wg pubkey)
    U2R_PASS=$(head -c 16 /dev/urandom | base64)
    VPS_IP=$(get_pub_ip); [ -z "$VPS_IP" ] && { echo -e "${RED}无法获取公网IP${NC}"; return; }
    
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-ip-forward.conf
    sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1
    
    cat > "$WG_CONF" << EOF
[Interface]
PrivateKey = $WG_PRIV
Address = 10.0.0.1/24
ListenPort = $WG_PORT
MTU = 1280
EOF
    systemctl enable wg-quick@wg0 > /dev/null 2>&1
    wg-quick down wg0 >/dev/null 2>&1; wg-quick up wg0 >/dev/null 2>&1
    
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
    iptables -I INPUT 1 -p tcp --dport $FAKE_PORT -j ACCEPT 2>/dev/null
    netfilter-persistent save > /dev/null 2>&1
    
    DEPLOY_CODE=$(echo -n "${VPS_IP}|${WG_PUB}|${U2R_PASS}|${FAKE_PORT}" | base64 -w 0 | tr -d '\n')
    echo -e "${GREEN}=========================================="
    echo -e " VPS 服务端初始化成功！"
    echo -e " ${YELLOW}请复制下方部署码，去家里的落地机执行脚本并粘贴：${NC}"
    echo -e " ${CYAN}${DEPLOY_CODE}${NC}"
    echo -e "=========================================="
    pause_return
}

bind_landing() {
    clear; echo -e "${YELLOW}━━━ 3. 绑定落地机 (粘贴回传码) ━━━${NC}"
    read -p "请粘贴回传码: " BIND_CODE < /dev/tty
    CODE_RAW=$(echo -n "$BIND_CODE" | tr -d '[:space:]' | base64 -d 2>/dev/null)
    [ -z "$CODE_RAW" ] || ! echo "$CODE_RAW" | grep -q "|" && { echo -e "${RED}绑定码无效${NC}"; pause_return; return; }

    LANDING_PUB=$(echo $CODE_RAW | cut -d'|' -f1); LAND_IP=$(echo $CODE_RAW | cut -d'|' -f2)
    MAP_PORT=$(echo $CODE_RAW | cut -d'|' -f3); LAND_PORT=$(echo $CODE_RAW | cut -d'|' -f4)
    
    echo -e "\n# Landing\n[Peer]\nPublicKey = ${LANDING_PUB}\nAllowedIPs = ${LAND_IP}/32" >> "$WG_CONF"
    wg syncconf wg0 <(wg-quick strip wg0) 2>/dev/null
    
    # 清理旧规则防累积
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
    
    echo -e "${GREEN}✓ 节点绑定成功！请确保云后台已放行端口 ${MAP_PORT} (TCP/UDP)${NC}"
    pause_return
}

# ==================== 家里落地机 (客户端) 模块 ====================
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
        # SS 格式通常为: shadowsocks://method:password@server:port
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
    clear; echo -e "${YELLOW}━━━ 2. 落地机部署 (粘贴部署码) ━━━${NC}"
    read -p "请粘贴部署码: " DEPLOY_CODE < /dev/tty
    CODE_RAW=$(echo -n "$DEPLOY_CODE" | tr -d '[:space:]' | base64 -d 2>/dev/null)
    [ -z "$CODE_RAW" ] && { echo -e "${RED}部署码无效${NC}"; pause_return; return; }

    VPS_IP=$(echo $CODE_RAW | cut -d'|' -f1); VPS_PUB=$(echo $CODE_RAW | cut -d'|' -f2)
    U2R_PASS=$(echo $CODE_RAW | cut -d'|' -f3); FAKE_PORT=$(echo $CODE_RAW | cut -d'|' -f4)

    read -p "请输入节点备注名称 (如 TW-Home): " NODE_NAME < /dev/tty
    [ -z "$NODE_NAME" ] && NODE_NAME="Home"
    read -p "请输入客户端连接端口 (VPS对外开放的端口, 如 443): " MAP_PORT < /dev/tty
    [ -z "$MAP_PORT" ] && MAP_PORT=443
    read -p "请输入落地机本地监听端口 (Sing-box端口, 默认 443): " LAND_PORT < /dev/tty
    [ -z "$LAND_PORT" ] && LAND_PORT=443

    echo -e "${YELLOW}[*] 安装 WG 与 Sing-box...${NC}"
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
    systemctl enable wg-quick@wg0 > /dev/null 2>&1
    wg-quick down wg0 >/dev/null 2>&1; wg-quick up wg0 >/dev/null 2>&1
    
    REALITY_KEYS=$(/usr/local/bin/sing-box generate reality-keypair 2>/dev/null)
    SB_PRIV=$(echo "$REALITY_KEYS" | awk '/PrivateKey/{print $2}')
    SB_PUB=$(echo "$REALITY_KEYS" | awk '/PublicKey/{print $2}')
    UUID=$(/usr/local/bin/sing-box generate uuid 2>/dev/null)
    SHORT_ID=$(/usr/local/bin/sing-box generate rand --hex 8 2>/dev/null)

    OUTBOUND_JSON='{ "type": "direct" }'
    echo -e "${YELLOW}[*] 配置出站模式:${NC}"
    read -p "是否配置链式代理 (支持 Shadowsocks / SOCKS5 / HTTP)? [y/N]: " is_chain < /dev/tty
    if [[ "$is_chain" =~ ^[Yy]$ ]]; then
        echo -e "${CYAN}支持格式举例:${NC}"
        echo -e " - socks5://127.0.0.1:7890 或 socks5://user:pass@1.2.3.4:1080"
        echo -e " - http://127.0.0.1:8118"
        echo -e " - shadowsocks://aes-256-gcm:password@1.2.3.4:8388"
        read -p "请输入前置代理链接: " chain_url < /dev/tty
        OUTBOUND_JSON=$(parse_chain_proxy "$chain_url")
        echo -e "${GREEN}✓ 链式代理配置转换完成${NC}"
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
    
    SAFE_NAME=$(url_encode "$NODE_NAME")
    VLESS_LINK="vless://${UUID}@${VPS_IP}:${MAP_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${SB_PUB}&sid=${SHORT_ID}&type=tcp#WG-${SAFE_NAME}"
    BIND_CODE=$(echo -n "${WG_PUB}|${LAND_IP}|${MAP_PORT}|${LAND_PORT}|${NODE_NAME}" | base64 -w 0 | tr -d '\n')
    
    touch "$LAND_INFO"
    cat > "$LAND_INFO" << EOF
节点名称: $NODE_NAME
VLESS链接: $VLESS_LINK
EOF
    
    echo -e "${GREEN}=========================================="
    echo -e " 落地机部署成功！"
    echo -e " ${YELLOW}请复制下方回传码，回到 VPS 执行脚本并粘贴：${NC}"
    echo -e " ${CYAN}${BIND_CODE}${NC}\n"
    echo -e " ${YELLOW}你的 VLESS 节点链接：${NC}"
    echo -e " ${GREEN}${VLESS_LINK}${NC}"
    echo -e "=========================================="
    pause_return
}

# ==================== 链式代理管理模块 ====================
manage_chain_proxy() {
    clear; echo -e "${YELLOW}━━━ 6. 落地机-链式代理管理 ━━━${NC}"
    if [ ! -f /etc/sing-box/config.json ]; then
        echo -e "${RED}未找到 Sing-box 配置，请先部署落地机。${NC}"
        pause_return; return
    fi
    
    local cur_out=$(jq -r '.outbounds[0].type' /etc/sing-box/config.json 2>/dev/null)
    if [ "$cur_out" == "direct" ]; then
        echo -e "当前状态: ${GREEN}直连 (无链式代理)${NC}"
    else
        echo -e "当前状态: ${GREEN}链式代理已启用 (${cur_out})${NC}"
    fi
    
    echo "1. 设置/修改链式代理 (支持 Shadowsocks / SOCKS5 / HTTP)"
    echo "2. 恢复为直连"
    echo "0. 返回主菜单"
    read -p "选择 [0-2]: " c < /dev/tty
    case $c in
        1) 
            echo -e "${CYAN}支持格式举例: socks5://... , http://... , shadowsocks://...${NC}"
            read -p "请输入前置代理链接: " chain_url < /dev/tty
            NEW_OUT=$(parse_chain_proxy "$chain_url")
            jq --argjson out "$NEW_OUT" '.outbounds = [$out]' /etc/sing-box/config.json > /tmp/sb_tmp.json && mv /tmp/sb_tmp.json /etc/sing-box/config.json
            systemctl restart sing-box
            echo -e "${GREEN}✓ 链式代理已更新并重启 Sing-box${NC}"
            ;;
        2)
            jq '.outbounds = [{"type":"direct"}]' /etc/sing-box/config.json > /tmp/sb_tmp.json && mv /tmp/sb_tmp.json /etc/sing-box/config.json
            systemctl restart sing-box
            echo -e "${GREEN}✓ 已恢复直连并重启 Sing-box${NC}"
            ;;
        0) return ;;
    esac
    pause_return
}

# ==================== BBRv3 与系统优化模块 ====================
optimize_kernel() {
    while true; do
        clear
        local cur_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
        local cur_kr=$(uname -r); local xm="否"; [[ "$cur_kr" == *xanmod* ]] && xm="是"
        echo -e "${CYAN}===== 内核与 BBR 优化 =====${NC}"
        echo -e "内核: ${cur_kr} | XanMod: ${xm} | 算法: ${cur_cc}"
        echo "1. 标准 BBR (v1，免重启)"
        echo "2. BBRv3 (安装 XanMod，需重启)"
        echo "3. 深度网络栈调优 (高并发推荐)"
        echo "0. 返回主菜单"
        read -rp "选择 [0-3]: " c
        case $c in
            1) _enable_bbr; echo; read -n 1 -s -r -p "按任意键返回菜单..." < /dev/tty ;;
            2) _enable_bbrv3; echo; read -n 1 -s -r -p "按任意键返回菜单..." < /dev/tty ;;
            3) _deep_tune; echo; read -n 1 -s -r -p "按任意键返回菜单..." < /dev/tty ;;
            0) return ;;
            *) echo -e "${RED}无效输入${NC}"; sleep 1 ;;
        esac
    done
}

_enable_bbr() {
    modprobe tcp_bbr 2>/dev/null || true
    if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then echo -e "${RED}内核不支持 BBR${NC}"; return 1; fi
    cat > "$BBR_CONF" <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    sysctl --system > /dev/null 2>&1 || true; echo -e "${GREEN}标准 BBR 已启用${NC}"
}

_enable_bbrv3() {
    if [[ "$(uname -r)" == *xanmod* ]]; then _enable_bbr; return; fi
    local arch=$(dpkg --print-architecture 2>/dev/null || true)
    [[ "$arch" != "amd64" ]] && { echo -e "${RED}XanMod 仅支持 amd64${NC}"; return; }
    . /etc/os-release; local codename="${VERSION_CODENAME:-}"
    
    case "$codename" in
        focal|jammy|noble|resolute|bullseye|bookworm|trixie) ;;
        *) echo -e "${RED}XanMod 不支持当前系统版本 (${codename})${NC}"; return 1 ;;
    esac

    if command -v mokutil &>/dev/null && mokutil --sb-state 2>/dev/null | grep -qi enabled; then echo -e "${RED}请先关闭 Secure Boot${NC}"; return; fi
    cd /tmp || return
    curl -fsSLO https://dl.xanmod.org/check_x86-64_psabi.sh 2>/dev/null || wget -qO check_x86-64_psabi.sh https://dl.xanmod.org/check_x86-64_psabi.sh || true
    local cpu
    if [[ -f ./check_x86-64_psabi.sh ]]; then
        chmod +x check_x86-64_psabi.sh; cpu=$(./check_x86-64_psabi.sh 2>/dev/null | grep -oE 'x86-64-v[0-9]' | tail -n1 || true); rm -f check_x86-64_psabi.sh
    fi
    local suffix="x64v2"; [[ "$cpu" == "x86-64-v3" ]] && suffix="x64v3"
    echo "选择分支: 1) LTS 2) MAIN"; read -rp "[1]: " br; br=${br:-1}
    local pkg="linux-xanmod-lts-${suffix}"; [[ "$br" == "2" ]] && pkg="linux-xanmod-${suffix}"
    apt-get install -y ca-certificates curl gpg; install -m 0755 -d /etc/apt/keyrings
    if ! curl -fsSL https://dl.xanmod.org/archive.key | gpg --dearmor --yes -o /etc/apt/keyrings/xanmod-archive-keyring.gpg 2>/dev/null; then echo -e "${RED}密钥下载失败${NC}"; return 1; fi
    cat > /etc/apt/sources.list.d/xanmod.sources <<EOF
Types: deb
URIs: https://deb.xanmod.org
Suites: ${codename}
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/xanmod-archive-keyring.gpg
EOF
    apt-get update -y; apt-get install -y "$pkg" || { echo -e "${RED}安装失败${NC}"; return; }
    echo -e "${YELLOW}需重启。重启后再次运行此项启用 BBRv3${NC}"; read -rp "立即重启, [y/N]: " rb; [[ "$rb" =~ ^[Yy]$ ]] && reboot
}

_deep_tune() {
    echo -e "${CYAN}应用深度网络栈调优...${NC}"
    modprobe nf_conntrack 2>/dev/null || true
    cat > "$SYSCTL_CONF" <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.netdev_max_backlog = 250000
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65535
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
EOF
    sysctl --system > /dev/null 2>&1 || true; echo -e "${GREEN}深度调优完成${NC}"
}

# ==================== 卸载模块 ====================
uninstall_all() {
    read -p "${RED}确定卸载所有组件？[y/N]: ${NC}" c < /dev/tty
    [[ ! "$c" =~ ^[Yy]$ ]] && return
    systemctl stop wg-quick@wg0 2>/dev/null; systemctl disable wg-quick@wg0 2>/dev/null
    systemctl stop udp2raw 2>/dev/null; systemctl disable udp2raw 2>/dev/null
    systemctl stop sing-box 2>/dev/null; systemctl disable sing-box 2>/dev/null
    rm -rf /etc/wireguard /etc/udp2raw /etc/sing-box /usr/local/bin/sing-box /usr/local/bin/udp2raw
    rm -f /etc/systemd/system/udp2raw.service /etc/systemd/system/sing-box.service
    iptables -F; iptables -t nat -F
    netfilter-persistent save > /dev/null 2>&1
    systemctl daemon-reload
    echo -e "${GREEN}✓ 卸载完成${NC}"
    pause_return
}

# ==================== 主菜单 ====================
check_root
while true; do
    clear
    echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  WG+udp2raw+Sing-box 终极反转融合版    ║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC} ${GREEN}1${NC} VPS-初始化服务端(生成部署码)     ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC} ${GREEN}2${NC} 家里-部署落地机(生成节点链接)   ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC} ${GREEN}3${NC} VPS-绑定落地机(粘贴回传码)     ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC} ${GREEN}4${NC} 查看落地机节点链接           ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC} ${GREEN}5${NC} 内核与 BBRv3 优化             ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC} ${GREEN}6${NC} 落地机-链式代理管理           ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC} ${GREEN}7${NC} 一键卸载全部组件             ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC} ${GREEN}0${NC} 退出                        ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
    
    read -p "选: " c < /dev/tty
    case $c in
        1) init_vps_server;;
        2) deploy_landing;;
        3) bind_landing;;
        4) clear; [ -f "$LAND_INFO" ] && cat "$LAND_INFO" || echo "无节点信息"; pause_return;;
        5) optimize_kernel;;
        6) manage_chain_proxy;;
        7) uninstall_all;;
        0) exit 0;;
        *) echo "错误"; sleep 1;;
    esac
done
