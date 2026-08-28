#!/bin/bash
# WireGuard + iptables + udp2raw 多落地隧道中转架构 (傻瓜式自动化版)
# 支持: IPv4 / IPv6 / 域名 / Debian 11/12/13, Ubuntu 20.04/22.04/24.04

set -uo pipefail

WG_DIR="/etc/wireguard"
WG_CONF="${WG_DIR}/wg0.conf"
PEERS_DIR="${WG_DIR}/peers"
UDP2RAW_DIR="/etc/udp2raw"
SYSCTL_CONF="/etc/sysctl.d/99-wireguard-tuning.conf"
BBR_CONF="/etc/sysctl.d/99-bbr.conf"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

[[ $EUID -ne 0 ]] && { echo -e "${RED}请使用 root 或 sudo 运行${NC}" >&2; exit 1; }

WAN_IFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}' || true)

# ==================== 全局核心机制 ====================
sync_wg() {
    wg syncconf wg0 <(wg-quick strip wg0) 2>/dev/null || {
        wg-quick down wg0 2>/dev/null || true
        wg-quick up wg0 2>/dev/null || true
    }
}

validate_ip() {
    local ip=$1
    if [[ "$ip" =~ ^10\.0\.0\.([0-9]+)$ ]]; then
        local last=${BASH_REMATCH[1]}
        if [[ "$last" -ge 2 && "$last" -le 254 ]]; then return 0; fi
    fi
    return 1
}

format_addr() {
    local addr=$1
    if [[ "$addr" == *:* && "$addr" != \[*\] ]]; then echo "[${addr}]"; else echo "$addr"; fi
}

setup_base() {
    apt-get update -y
    apt-get install -y wireguard iptables iptables-persistent iproute2 curl wget
    
    cat > "$SYSCTL_CONF" <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
    sysctl --system > /dev/null 2>&1 || true
    mkdir -p "$WG_DIR" "$PEERS_DIR" "$UDP2RAW_DIR"
    
    if ! command -v udp2raw &>/dev/null; then
        echo -e "${CYAN}下载 udp2raw...${NC}"
        local arch=$(dpkg --print-architecture)
        [[ "$arch" != "amd64" ]] && { echo -e "${RED}udp2raw 预编译包仅支持 amd64${NC}"; exit 1; }
        cd /tmp
        wget -qO u2r.tar.gz "https://github.com/wangyu-/udp2raw/releases/download/20200818.0/udp2raw_binaries.tar.gz"
        tar xzf u2r.tar.gz && cp udp2raw_amd64 /usr/local/bin/udp2raw && chmod +x /usr/local/bin/udp2raw
        rm -f u2r.tar.gz udp2raw_*
        cd - > /dev/null
    fi
}

# ==================== 落地机专属模块 ====================
landing_menu() {
    while true; do
        clear
        echo -e "${GREEN}===== 落地机专属配置 =====${NC}"
        echo "1. 初始化/重置落地机环境"
        echo "2. 添加中转机 Peer"
        echo "3. 删除中转机 Peer"
        echo "4. 查看已连接的中转机"
        echo "0. 返回主菜单"
        read -rp "选择 [0-4]: " c
        case $c in
            1) landing_init; echo; read -n 1 -s -r -p "按任意键返回菜单..." ;;
            2) landing_add_peer; echo; read -n 1 -s -r -p "按任意键返回菜单..." ;;
            3) landing_del_peer; echo; read -n 1 -s -r -p "按任意键返回菜单..." ;;
            4) landing_list_peers; echo; read -n 1 -s -r -p "按任意键返回菜单..." ;;
            0) return ;;
            *) echo -e "${RED}无效输入${NC}"; sleep 1 ;;
        esac
    done
}

landing_init() {
    echo -e "${CYAN}===== 初始化落地机 (WG服务端 + udp2raw服务端) =====${NC}"
    setup_base
    
    systemctl stop wg-quick@wg0 2>/dev/null || true
    ip link delete wg0 2>/dev/null || true
    
    while true; do
        read -rp "udp2raw 伪装 TCP 端口 [20022]: " FAKE_PORT; FAKE_PORT=${FAKE_PORT:-20022}
        [[ "$FAKE_PORT" =~ ^[0-9]+$ && "$FAKE_PORT" -ge 1 && "$FAKE_PORT" -le 65535 ]] && break
        echo -e "${RED}无效端口${NC}"
    done
    
    while true; do
        read -rp "WG 内部监听端口 [51820]: " WG_PORT; WG_PORT=${WG_PORT:-51820}
        [[ "$WG_PORT" =~ ^[0-9]+$ && "$WG_PORT" -ge 1 && "$WG_PORT" -le 65535 ]] && break
        echo -e "${RED}无效端口${NC}"
    done

    echo "请选择 udp2raw 监听的网络类型:"
    echo "  1. 仅 IPv4 (0.0.0.0) [默认]"
    echo "  2. IPv6 + IPv4 双栈 ([::])"
    read -rp "选择 [1/2]: " listen_choice
    local LISTEN_ADDR="0.0.0.0"
    if [[ "$listen_choice" == "2" ]]; then LISTEN_ADDR="[::]"; fi
    
    local u2r_pass=$(head -c 16 /dev/urandom | base64)
    echo "$u2r_pass" > "${UDP2RAW_DIR}/password"
    
    local srv_priv=$(wg genkey)
    local srv_pub=$(echo "$srv_priv" | wg pubkey)
    echo "$srv_priv" > "${WG_DIR}/server_private"
    echo "$srv_pub" > "${WG_DIR}/server_public"
    chmod 600 "${WG_DIR}/server_private"
    
    cat > "${WG_DIR}/load-peers.sh" <<'EOF'
#!/bin/bash
IFACE="$1"
for f in /etc/wireguard/peers/*.conf; do
    [ -f "$f" ] || continue
    PUB=$(grep "^PublicKey" "$f" | awk '{print $3}')
    IPS=$(grep "^AllowedIPs" "$f" | sed 's/.*= *//')
    if [ -n "$PUB" ] && [ -n "$IPS" ]; then
        wg set "$IFACE" peer "$PUB" allowed-ips "$IPS" 2>/dev/null
    fi
done
EOF
    chmod +x "${WG_DIR}/load-peers.sh"
    
    cat > "$WG_CONF" <<EOF
[Interface]
Address = 10.0.0.1/24
ListenPort = ${WG_PORT}
PrivateKey = ${srv_priv}
MTU = 1280

PostUp = iptables -I INPUT -p tcp --dport ${FAKE_PORT} -j ACCEPT
PostUp = iptables -I INPUT -p udp --dport ${WG_PORT} ! -i lo -j DROP
PostUp = iptables -I FORWARD -i %i -j ACCEPT
PostUp = iptables -I FORWARD -o %i -j ACCEPT
PostUp = iptables -t nat -I POSTROUTING -s 10.0.0.0/24 -o ${WAN_IFACE} -j MASQUERADE
PostUp = ${WG_DIR}/load-peers.sh %i

PostDown = iptables -D INPUT -p tcp --dport ${FAKE_PORT} -j ACCEPT
PostDown = iptables -D INPUT -p udp --dport ${WG_PORT} ! -i lo -j DROP
PostDown = iptables -D FORWARD -i %i -j ACCEPT
PostDown = iptables -D FORWARD -o %i -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s 10.0.0.0/24 -o ${WAN_IFACE} -j MASQUERADE
EOF
    
    cat > /etc/systemd/system/udp2raw.service <<EOF
[Unit]
Description=udp2raw Server (Landing)
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/udp2raw -s -l ${LISTEN_ADDR}:${FAKE_PORT} -r 127.0.0.1:${WG_PORT} --raw-mode faketcp -a -k "${u2r_pass}"
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now udp2raw
    systemctl enable wg-quick@wg0 2>/dev/null || true
    systemctl restart wg-quick@wg0 2>/dev/null || true
    
    if ! systemctl is-active --quiet wg-quick@wg0; then
        echo -e "${RED}WireGuard 启动失败！请手动执行 wg-quick up wg0 检查报错。${NC}"
        return 1
    fi
    netfilter-persistent save 2>/dev/null || true
    
    echo -e "${GREEN}======================================${NC}"
    echo -e "${GREEN} 落地机初始化完成!${NC}"
    echo -e "${YELLOW} >>> 落地机 WG 公钥: ${srv_pub}${NC}"
    echo -e "${YELLOW} >>> udp2raw 密码: ${u2r_pass}${NC}"
    echo -e "${YELLOW} >>> udp2raw 伪装端口: ${FAKE_PORT} (TCP)${NC}"
    echo -e "${YELLOW} >>> 监听地址: ${LISTEN_ADDR}${NC}"
    echo -e "${GREEN}======================================${NC}"
}

landing_add_peer() {
    if ! ip link show wg0 &>/dev/null; then
        echo -e "${RED}WG 接口未运行，请先执行选项 1 进行初始化！${NC}"; return 1
    fi
    read -rp "请输入中转机名称 (如 relay-jp): " name; name=$(echo "$name" | tr -dc '[:alnum:]-_')
    [[ -z "$name" ]] && return
    
    local peer_file="${PEERS_DIR}/${name}.conf"
    [[ -f "$peer_file" ]] && { echo -e "${RED}已存在${NC}"; return; }
    
    read -rp "请输入中转机 WG 公钥: " pub
    [[ -z "$pub" ]] && return
    
    local RELAY_IP
    while true; do
        read -rp "为此中转机分配内网 IP [10.0.0.254]: " RELAY_IP
        RELAY_IP=${RELAY_IP:-10.0.0.254}
        if ! validate_ip "$RELAY_IP"; then
            echo -e "${RED}格式错误，请输入 10.0.0.2 ~ 10.0.0.254 之间的 IP${NC}"
            continue
        fi
        local is_used=0
        for f in "$PEERS_DIR"/*.conf; do
            [[ -e "$f" ]] || continue
            if grep -qF "${RELAY_IP}/32" "$f"; then is_used=1; break; fi
        done
        if [[ "$is_used" -eq 1 ]]; then echo -e "${RED}该 IP 已被占用，请重新输入${NC}"; else break; fi
    done
    
    local cip4="${RELAY_IP}/32"
    { echo "[Peer]"; echo "PublicKey = ${pub}"; echo "AllowedIPs = ${cip4}"; } > "$peer_file"
    wg set wg0 peer "$pub" allowed-ips "$cip4" 2>/dev/null || true
    echo -e "${GREEN}中转机 Peer ${name} 添加成功 (IP: ${RELAY_IP})${NC}"
}

landing_del_peer() {
    local i=1 arr=()
    for f in "$PEERS_DIR"/*.conf; do
        [[ -e "$f" ]] || continue
        local name=$(basename "$f" .conf)
        echo "  [$i] $name"; arr[$i]="$name"; ((i++))
    done
    [[ ${#arr[@]} -eq 0 ]] && { echo -e "${YELLOW}无中转机节点${NC}"; return; }
    read -rp "删除编号: " c
    [[ ! "$c" =~ ^[0-9]+$ || "$c" -lt 1 || "$c" -gt ${#arr[@]} ]] && return
    local name=${arr[$c]}; local peer_file="${PEERS_DIR}/${name}.conf"
    local pub=$(grep "^PublicKey" "$peer_file" | awk '{print $3}')
    wg set wg0 peer "$pub" remove 2>/dev/null || true
    rm -f "$peer_file"
    echo -e "${GREEN}节点 ${name} 已删除${NC}"
}

landing_list_peers() {
    echo -e "\n${CYAN}===== 已连接的中转机列表 =====${NC}"
    if ! ip link show wg0 &>/dev/null; then echo -e "${RED}WG 接口未运行，请先初始化！${NC}"; return 1; fi
    [[ ! -d "$PEERS_DIR" || -z "$(ls -A "$PEERS_DIR" 2>/dev/null)" ]] && { echo -e "${YELLOW}当前没有配置中转机${NC}"; return; }
    local has_peer=0
    for f in "$PEERS_DIR"/*.conf; do
        [[ -e "$f" ]] || continue; has_peer=1
        local name=$(basename "$f" .conf); local pub=$(grep "^PublicKey" "$f" | awk '{print $3}')
        local ip=$(grep "^AllowedIPs" "$f" | awk '{print $3}')
        local handshake=$(wg show wg0 latest-handshakes 2>/dev/null | grep "$pub" | awk '{print $2}')
        local status="${RED}离线${NC}"
        if [[ -n "$handshake" && "$handshake" -ne 0 ]]; then
            local now=$(date +%s); local diff=$((now - handshake))
            if [[ "$diff" -lt 180 ]]; then status="${GREEN}在线 (${diff}秒前握手)${NC}"; fi
        fi
        echo -e " - 名称: ${GREEN}${name}${NC} | IP: ${ip} | 状态: ${status}"
        echo -e "   公钥: ${pub:0:20}..."
    done
    [[ "$has_peer" -eq 0 ]] && echo -e "${YELLOW}当前没有配置中转机${NC}"
}

# ==================== 中转机专属模块 ====================
relay_menu() {
    while true; do
        clear
        echo -e "${GREEN}===== 中转机专属配置 (支持多落地) =====${NC}"
        echo "1. 初始化/重置中转机基础环境"
        echo "2. 添加落地机隧道"
        echo "3. 添加/修改端口转发规则 (TCP+UDP)"
        echo "4. 查看当前隧道与转发状态"
        echo "5. 删除落地机隧道"
        echo "0. 返回主菜单"
        read -rp "选择 [0-5]: " c
        case $c in
            1) relay_init_base; echo; read -n 1 -s -r -p "按任意键返回菜单..." ;;
            2) relay_add_landing; echo; read -n 1 -s -r -p "按任意键返回菜单..." ;;
            3) relay_add_forward; echo; read -n 1 -s -r -p "按任意键返回菜单..." ;;
            4) relay_view_config; echo; read -n 1 -s -r -p "按任意键返回菜单..." ;;
            5) relay_del_landing; echo; read -n 1 -s -r -p "按任意键返回菜单..." ;;
            0) return ;;
            *) echo -e "${RED}无效输入${NC}"; sleep 1 ;;
        esac
    done
}

relay_init_base() {
    echo -e "${CYAN}===== 初始化中转机基础环境 =====${NC}"
    setup_base
    systemctl stop wg-quick@wg0 2>/dev/null || true
    ip link delete wg0 2>/dev/null || true
    
    local RELAY_IP
    while true; do
        read -rp "设置中转机的内网 IP (需与落地机配置一致) [10.0.0.254]: " RELAY_IP
        RELAY_IP=${RELAY_IP:-10.0.0.254}
        if validate_ip "$RELAY_IP"; then break; fi
        echo -e "${RED}格式错误，请输入 10.0.0.2 ~ 10.0.0.254 之间的 IP${NC}"
    done
    
    local cli_priv=$(wg genkey); local cli_pub=$(echo "$cli_priv" | wg pubkey)
    echo "$cli_priv" > "${WG_DIR}/privatekey"; echo "$cli_pub" > "${WG_DIR}/client_public"
    
    cat > "$WG_CONF" <<EOF
[Interface]
Address = ${RELAY_IP}/24
PrivateKey = ${cli_priv}
MTU = 1280
EOF
    
    systemctl enable wg-quick@wg0 2>/dev/null || true
    systemctl restart wg-quick@wg0 2>/dev/null || true
    if ! systemctl is-active --quiet wg-quick@wg0; then
        echo -e "${RED}WireGuard 启动失败！请手动执行 wg-quick up wg0 检查报错。${NC}"; return 1
    fi
    netfilter-persistent save 2>/dev/null || true
    
    echo -e "${GREEN}======================================${NC}"
    echo -e "${GREEN} 中转机基础环境初始化完成!${NC}"
    echo -e "${YELLOW} >>> 中转机 WG 公钥: ${cli_pub}${NC}"
    echo -e "${CYAN}请接下来使用 '添加落地机隧道' 来连接落地机${NC}"
    echo -e "${GREEN}======================================${NC}"
}

relay_add_landing() {
    if [[ ! -f "$WG_CONF" ]]; then echo -e "${RED}请先初始化中转机基础环境${NC}"; return 1; fi
    read -rp "请为此落地机命名 (如 land-us): " name; name=$(echo "$name" | tr -dc '[:alnum:]-_')
    [[ -z "$name" ]] && return
    
    read -rp "落地机公网 IP 或 域名: " LAND_ADDR_RAW; [[ -z "$LAND_ADDR_RAW" ]] && return
    local LAND_ADDR=$(format_addr "$LAND_ADDR_RAW")
    read -rp "落地机 udp2raw 伪装端口 [20022]: " LAND_FAKE_PORT; LAND_FAKE_PORT=${LAND_FAKE_PORT:-20022}
    read -rp "落地机 udp2raw 密码: " U2R_PASS
    read -rp "落地机 WG 公钥: " LAND_PUBKEY
    
    local self_ip=$(grep "^Address" "$WG_CONF" | awk '{print $3}' | cut -d'/' -f1 | cut -d'.' -f4); self_ip=${self_ip:-0}
    local used_ips=$(grep "AllowedIPs" "$WG_CONF" | grep -oE "10\.0\.0\.[0-9]+" | cut -d'.' -f4 | sort -n)
    local num=1
    while true; do
        if [[ "$num" -gt 255 ]]; then echo -e "${RED}IP 池耗尽${NC}"; return 1; fi
        if [[ "$num" -eq 1 || "$num" -eq "$self_ip" ]]; then ((num++)); continue; fi
        if echo "$used_ips" | grep -qw "$num"; then ((num++)); else break; fi
    done
    local land_ip="10.0.0.${num}"
    
    local used_ports=$(grep "Endpoint" "$WG_CONF" | grep -oE "127.0.0.1:[0-9]+" | cut -d':' -f2 | sort -n)
    local local_port=51821
    while echo "$used_ports" | grep -qw "$local_port"; do ((local_port++)); done
    
    cat > "/etc/systemd/system/udp2raw-${name}.service" <<EOF
[Unit]
Description=udp2raw Client for ${name}
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/udp2raw -c -l 127.0.0.1:${local_port} -r ${LAND_ADDR}:${LAND_FAKE_PORT} --raw-mode faketcp -a -k "${U2R_PASS}"
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable --now "udp2raw-${name}"
    
    {
        echo ""; echo "# ${name}"; echo "[Peer]"; echo "PublicKey = ${LAND_PUBKEY}"
        echo "Endpoint = 127.0.0.1:${local_port}"; echo "AllowedIPs = ${land_ip}/32"
        echo "PersistentKeepalive = 25"
    } >> "$WG_CONF"
    sync_wg
    
    echo -e "${GREEN}======================================${NC}"
    echo -e "${GREEN} 落地机 ${name} 隧道添加成功!${NC}"
    echo -e " - 分配落地机内网 IP: ${land_ip}"
    echo -e " - 本地监听端口: ${local_port}"
    echo -e " - 目标地址: ${LAND_ADDR}:${LAND_FAKE_PORT}"
    echo -e "${CYAN}请使用 '添加端口转发规则' 将外部端口映射到 ${land_ip}${NC}"
    echo -e "${GREEN}======================================${NC}"
}

relay_add_forward() {
    if ! ip link show wg0 &>/dev/null; then echo -e "${RED}WG 接口未运行，请先初始化！${NC}"; return 1; fi
    
    local land_ips=()
    while read -r ip; do land_ips+=("$ip"); done < <(grep "AllowedIPs" "$WG_CONF" | grep -oE "10\.0\.0\.[0-9]+")
    
    if [[ ${#land_ips[@]} -eq 0 ]]; then echo -e "${RED}无可用落地机，请先添加落地机隧道${NC}"; return 1; fi
    
    local LAND_IP
    if [[ ${#land_ips[@]} -eq 1 ]]; then
        LAND_IP="${land_ips[0]}"
        echo -e "${CYAN}检测到唯一落地机，自动选中: ${GREEN}${LAND_IP}${NC}"
    else
        echo -e "${CYAN}当前可用落地机内网 IP:${NC}"
        for ip in "${land_ips[@]}"; do echo " - $ip"; done
        read -rp "请输入转发到哪个落地机内网 IP: " LAND_IP
    fi
    
    local C_PORT
    read -rp "客户端连接本机的哪个端口 (如 443): " C_PORT
    [[ -z "$C_PORT" ]] && C_PORT=443
    
    local LAND_PORT
    read -rp "转发到落地机的哪个端口 (回车默认同上: ${C_PORT}): " LAND_PORT
    [[ -z "$LAND_PORT" ]] && LAND_PORT=$C_PORT
    
    local proto_choice
    read -rp "选择协议 (1.TCP / 2.UDP / 3.TCP+UDP) [回车默认3]: " proto_choice
    proto_choice=${proto_choice:-3}
    local protos=""
    case $proto_choice in
        1) protos="tcp" ;; 2) protos="udp" ;; 3) protos="tcp udp" ;; *) echo -e "${RED}无效选择${NC}"; return ;;
    esac

    for proto in $protos; do
        while read -r num; do iptables -t nat -D PREROUTING $num 2>/dev/null; done < <(iptables -t nat -L PREROUTING -n --line-numbers | grep -E "dpt:${C_PORT}( |$)" | grep -w "${proto}" | awk '{print $1}' | sort -rn)
        iptables -t nat -A PREROUTING -p ${proto} --dport ${C_PORT} -j DNAT --to-destination ${LAND_IP}:${LAND_PORT}
        while read -r num; do iptables -D FORWARD $num 2>/dev/null; done < <(iptables -L FORWARD -n --line-numbers | grep -E " ${LAND_IP}( |$)" | grep -E "dpt:${LAND_PORT}( |$)" | grep -w "${proto}" | awk '{print $1}' | sort -rn)
        iptables -A FORWARD -p ${proto} -d ${LAND_IP} --dport ${LAND_PORT} -j ACCEPT
    done

    iptables -t nat -C POSTROUTING -o wg0 -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o wg0 -j MASQUERADE
    iptables -C FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
    
    netfilter-persistent save 2>/dev/null || true
    echo -e "${GREEN}规则添加成功: 本机端口 ${C_PORT} (${protos}) -> 落地机 ${LAND_IP} 端口 ${LAND_PORT}${NC}"
}

relay_view_config() {
    echo -e "\n${CYAN}===== 中转机隧道与转发状态 =====${NC}"
    if ! ip link show wg0 &>/dev/null; then echo -e "${RED}WG 接口未运行，请先初始化！${NC}"; return 1; fi
    
    echo -e "${GREEN}1. 落地机隧道列表:${NC}"
    wg show wg0 | grep -E "peer|endpoint|allowed" || echo "无隧道"
    
    echo -e "\n${GREEN}2. udp2raw 客户端服务:${NC}"
    systemctl list-units --type=service --state=running | grep "udp2raw" || echo "无运行中的 udp2raw 服务"
    
    echo -e "\n${GREEN}3. 端口转发规则 (DNAT):${NC}"
    local nat_rules=$(iptables -t nat -L PREROUTING -n | grep "DNAT")
    [[ -z "$nat_rules" ]] && echo -e " - ${YELLOW}无转发规则${NC}" || echo "$nat_rules" | awk '{for(i=1;i<=NF;i++) if($i ~ /dpt:/ || $i ~ /to:/) printf $i" "; print ""}' | sed 's/^/ - /'
}

relay_del_landing() {
    if [[ ! -f "$WG_CONF" ]]; then return 1; fi
    echo -e "\n${CYAN}当前落地机隧道:${NC}"
    local i=1 arr=()
    while IFS= read -r line; do
        if [[ "$line" == "# "* ]]; then
            local name=$(echo "$line" | awk '{print $2}'); echo "  [$i] $name"; arr[$i]="$name"; ((i++))
        fi
    done < "$WG_CONF"
    
    [[ ${#arr[@]} -eq 0 ]] && { echo -e "${YELLOW}无落地机隧道${NC}"; return; }
    read -rp "删除编号: " c
    [[ ! "$c" =~ ^[0-9]+$ || "$c" -lt 1 || "$c" -gt ${#arr[@]} ]] && return
    
    local name=${arr[$c]}
    local land_ip=$(awk -v key="# ${name}" '$0 == key {f=1} f && /^AllowedIPs/ {split($3,a,"/"); print a[1]; exit}' "$WG_CONF")
    if [[ -n "$land_ip" ]]; then
        while read -r num; do iptables -t nat -D PREROUTING $num 2>/dev/null; done < <(iptables -t nat -L PREROUTING -n --line-numbers | grep -E "to:${land_ip}:" | awk '{print $1}' | sort -rn)
        while read -r num; do iptables -D FORWARD $num 2>/dev/null; done < <(iptables -L FORWARD -n --line-numbers | grep -E " ${land_ip}( |$)" | awk '{print $1}' | sort -rn)
        netfilter-persistent save 2>/dev/null || true
        echo -e "${CYAN}已自动清理指向 ${land_ip} 的 iptables 转发规则${NC}"
    fi
    
    systemctl stop "udp2raw-${name}" 2>/dev/null || true
    systemctl disable "udp2raw-${name}" 2>/dev/null || true
    rm -f "/etc/systemd/system/udp2raw-${name}.service"
    systemctl daemon-reload
    
    awk -v key="# ${name}" 'BEGIN { skip=0 } /^# / && $0 != key { skip=0 } $0 == key { skip=1 } skip==1 { next } { print }' "$WG_CONF" > "${WG_CONF}.tmp" && mv "${WG_CONF}.tmp" "$WG_CONF"
    sync_wg
    echo -e "${GREEN}隧道 ${name} 已删除${NC}"
}

# ==================== 通用全局模块 ====================
show_status() {
    echo -e "\n${CYAN}===== 系统全局状态 =====${NC}"
    echo -e "${GREEN}1. 内核与网络:${NC}"
    echo "内核版本 : $(uname -r)"; echo "拥塞算法 : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '未知')"
    echo "IPv4转发 : $(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo '未知')"
    
    echo -e "\n${GREEN}2. WireGuard 接口:${NC}"
    ip link show wg0 &>/dev/null && wg show wg0 || echo "wg0 接口未运行"
    
    echo -e "\n${GREEN}3. udp2raw 服务状态:${NC}"
    systemctl list-units --type=service --state=running | grep "udp2raw" || echo "无运行中的 udp2raw 服务"
    
    if [[ -f "${WG_CONF}" ]] && grep -q "AllowedIPs" "$WG_CONF"; then
        echo -e "\n${GREEN}4. 端口转发规则 (DNAT):${NC}"
        local nat_rules=$(iptables -t nat -L PREROUTING -n | grep "DNAT")
        [[ -z "$nat_rules" ]] && echo -e " - ${YELLOW}无转发规则${NC}" || echo "$nat_rules" | awk '{for(i=1;i<=NF;i++) if($i ~ /dpt:/ || $i ~ /to:/) printf $i" "; print ""}' | sed 's/^/ - /'
    fi
}

optimize_kernel() {
    while true; do
        clear
        local cur_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
        local cur_kr=$(uname -r); local xm="否"; [[ "$cur_kr" == *xanmod* ]] && xm="是"
        echo -e "${CYAN}===== 内核与 BBR 优化 =====${NC}"
        echo -e "内核: ${cur_kr} | XanMod: ${xm} | 算法: ${cur_cc}"
        echo "1. 标准 BBR (v1，免重启)"; echo "2. BBRv3 (安装 XanMod，需重启)"; echo "3. 深度网络栈调优 (高并发推荐)"; echo "0. 返回主菜单"
        read -rp "选择 [0-3]: " c
        case $c in
            1) _enable_bbr; echo; read -n 1 -s -r -p "按任意键返回菜单..." ;;
            2) _enable_bbrv3; echo; read -n 1 -s -r -p "按任意键返回菜单..." ;;
            3) _deep_tune; echo; read -n 1 -s -r -p "按任意键返回菜单..." ;;
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
    
    # 修复支持的发行版代号白名单
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

uninstall_all() {
    read -rp "确认卸载 WG + udp2raw 及所有规则, [y/N]: " c
    [[ ! "$c" =~ ^[Yy]$ ]] && return
    systemctl stop wg-quick@wg0 2>/dev/null || true; systemctl disable wg-quick@wg0 2>/dev/null || true
    for svc in /etc/systemd/system/udp2raw*.service; do
        [[ -f "$svc" ]] && systemctl stop "$(basename "$svc" .service)" 2>/dev/null
        [[ -f "$svc" ]] && systemctl disable "$(basename "$svc" .service)" 2>/dev/null
        rm -f "$svc"
    done
    systemctl daemon-reload
    rm -rf "$WG_DIR" "$UDP2RAW_DIR" /etc/sysctl.d/99-wireguard*.conf /etc/sysctl.d/99-bbr.conf
    rm -f /usr/local/bin/udp2raw
    iptables -F; iptables -t nat -F; iptables -t mangle -F
    netfilter-persistent save 2>/dev/null || true
    apt-get remove -y wireguard iptables-persistent; echo -e "${GREEN}卸载完成${NC}"
}

# ==================== 主菜单 ====================
main() {
    while true; do
        clear
        echo -e "${GREEN}===== WG + udp2raw 隧道中转架构 (多落地支持) =====${NC}"
        echo "1. 落地机配置"; echo "2. 中转机配置 (多落地)"; echo "3. 查看全局系统状态"
        echo "4. 内核与 BBR 优化"; echo "5. 卸载组件"; echo "0. 退出"
        read -rp "选择 [0-5]: " c
        case $c in
            1) landing_menu ;;
            2) relay_menu ;;
            3) show_status; echo; read -n 1 -s -r -p "按任意键返回菜单..." ;;
            4) optimize_kernel ;;
            5) uninstall_all; echo; read -n 1 -s -r -p "按任意键返回菜单..." ;;
            0) clear; exit 0 ;;
            *) echo -e "${RED}无效输入${NC}"; sleep 1 ;;
        esac
    done
}

main
