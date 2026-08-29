#!/bin/bash
# ====================================================================================
# 跨境软件定义边缘网络系统 (工业级修复版)
# 架构: 动态/静态落地机 -> 主动反向隧道 (udp2raw+WireGuard) -> 香港总控 -> 智能容灾
# 场景: TikTok 1080p 60fps 手机/电脑娱播推流、低延迟游戏、家宽/机房混合组网
# ====================================================================================

set -euo pipefail

check_root() {
    # 修复: 原先 [[ $EUID -ne 0 ]] && ... 在 root 下返回 1，会导致 set -e 直接退出脚本
    if [[ $EUID -ne 0 ]]; then
        echo -e "\033[31m[错误] 必须使用 root 权限运行此脚本！\033[0m"
        exit 1
    fi
}

detect_hardware_and_bandwidth() {
    echo -e "\n\033[32m[+] 正在扫描服务器硬件与吞吐指标...\033[0m"
    CPU_CORES=$(nproc)
    TOTAL_MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    TOTAL_MEM_MB=$((TOTAL_MEM_KB / 1024))
    TOTAL_MEM_GB=$(awk "BEGIN {printf \"%.1f\", $TOTAL_MEM_MB / 1024}")
    
    echo -e "    -> CPU核心: \033[36m${CPU_CORES}核 | 物理内存: ${TOTAL_MEM_GB}GB\033[0m"
}

apply_ultimate_kernel() {
    echo -e "\033[32m[+] 正在注入网络极限内核调优...\033[0m"
    modprobe tcp_bbr 2>/dev/null || true
    echo "tcp_bbr" > /etc/modules-load.d/bbr.conf 2>/dev/null || true
    
    if [ "$TOTAL_MEM_MB" -ge 4096 ]; then
        CONTRACK_MAX=8388608
    else
        CONTRACK_MAX=2097152
    fi

    cat > /etc/sysctl.d/99-sdn-ultimate.conf <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.ip_forward = 1
net.netfilter.nf_conntrack_max = $CONTRACK_MAX
net.netfilter.nf_conntrack_tcp_timeout_established = 43200
net.core.netdev_max_backlog = 200000
net.core.somaxconn = 65535
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_fin_timeout = 15
EOF
    # 修复: 某些系统可能不支持部分参数，防止 sysctl 返回非0导致脚本退出
    sysctl -p /etc/sysctl.d/99-sdn-ultimate.conf >/dev/null 2>&1 || true
}

install_dependencies() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) SB_ARCH="amd64"; U2R_ARCH="amd64" ;;
        aarch64) SB_ARCH="arm64"; U2R_ARCH="arm" ;;
        *) echo -e "\033[31m[错误] 不支持的架构: $ARCH\033[0m"; exit 1 ;;
    esac

    if [ ! -f "/usr/local/bin/udp2raw" ]; then
        wget -qO udp2raw.tar.gz "https://github.com/wangyu-/udp2raw/releases/download/20230206.0/udp2raw_binaries.tar.gz"
        tar -xzf udp2raw.tar.gz && mv udp2raw_${U2R_ARCH} /usr/local/bin/udp2raw && chmod +x /usr/local/bin/udp2raw && rm -rf udp2raw*
    fi

    if [ ! -f "/usr/local/bin/sing-box" ]; then
        # 修复: 网络问题或API限流可能导致 grep 返回非0，加 || true 防止 set -e 退出
        local VER=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/' || true)
        if [ -z "$VER" ]; then
            echo -e "\033[31m[错误] 获取 sing-box 版本失败，请检查网络或稍后重试！\033[0m"
            exit 1
        fi
        wget -qO sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${VER}/sing-box-${VER}-linux-${SB_ARCH}.tar.gz"
        tar -xzf sing-box.tar.gz && mv sing-box-${VER}-linux-${SB_ARCH}/sing-box /usr/local/bin/ && chmod +x /usr/local/bin/sing-box && rm -rf sing-box*
    fi
}

get_pub_ip() {
    local ip=""
    for api in "ifconfig.me" "api.ipify.org" "icanhazip.com"; do
        # 修复: curl 超时会返回非0状态码，加 || true 防止 set -e 退出
        ip=$(curl -s --connect-timeout 2 --max-time 3 -4 "$api" 2>/dev/null | tr -d '[:space:]' || true)
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    echo "127.0.0.1"
}

# ====================================================================================
# 模块一：香港中转总控
# ====================================================================================
setup_hk_master() {
    apt-get update && apt-get install -y wireguard wireguard-tools curl jq iptables iproute2 uuid-runtime systemd
    detect_hardware_and_bandwidth
    apply_ultimate_kernel
    install_dependencies

    read -p "请输入客户端连接香港总控的端口 [默认 443]: " CLIENT_PORT
    CLIENT_PORT=${CLIENT_PORT:-443}
    
    HK_IP=$(get_pub_ip)
    WG_PRIV=$(wg genkey)
    WG_PUB=$(echo "$WG_PRIV" | wg pubkey)
    U2R_PASS=$(uuidgen | sed 's/-//g' | cut -c 1-16)
    SUBNET_PREFIX="10.$((RANDOM % 155 + 100)).$((RANDOM % 254 + 1))"

    mkdir -p /etc/wireguard
    cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
PrivateKey = $WG_PRIV
Address = ${SUBNET_PREFIX}.1/24
ListenPort = 30000
MTU = 1360
EOF

    UUID=$(uuidgen)
    KEYS=$(sing-box generate reality-keypair)
    PRIVATE_KEY=$(echo "$KEYS" | grep Private | awk '{print $3}')
    PUBLIC_KEY=$(echo "$KEYS" | grep Public | awk '{print $3}')
    SHORT_ID=$(openssl rand -hex 8)

    mkdir -p /etc/sing-box
    cat > /etc/sing-box/config.json <<EOF
{
  "inbounds": [{
    "type": "vless", "tag": "vless-in", "listen": "0.0.0.0", "listen_port": $CLIENT_PORT,
    "users": [{ "uuid": "$UUID", "flow": "xtls-rprx-vision" }],
    "tls": {
      "enabled": true, "server_name": "www.apple.com",
      "reality": { "enabled": true, "handshake": { "server": "www.apple.com", "server_port": 443 }, "private_key": "$PRIVATE_KEY", "short_id": ["$SHORT_ID"] }
    }
  }],
  "outbounds": [{ "type": "direct", "tag": "direct" }]
}
EOF

    cat > /etc/systemd/system/sing-box.service << EOF
[Unit]
Description=Sing-box Control Plane
After=network.target
[Service]
Type=simple
LimitNOFILE=1048576
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now wg-quick@wg0 sing-box

    cat > /etc/sdn_hk_cluster.env <<EOF
HK_IP="$HK_IP"
WG_PUB="$WG_PUB"
U2R_PASS="$U2R_PASS"
SUBNET_PREFIX="$SUBNET_PREFIX"
CLIENT_PORT="$CLIENT_PORT"
UUID="$UUID"
PRIVATE_KEY="$PRIVATE_KEY"
PUBLIC_KEY="$PUBLIC_KEY"
SHORT_ID="$SHORT_ID"
EOF
    touch /etc/sdn_nodes_registry.list

    echo -e "\n===================================================================="
    echo -e "\e[32m[√] 香港总控中心初始化完成！\e[0m"
    echo -e "客户端配置参数 -> 地址: $HK_IP | 端口: $CLIENT_PORT | UUID: $UUID"
    echo -e "===================================================================="
}

# ====================================================================================
# 模块二：生成香港对接凭证
# ====================================================================================
export_token() {
    # 修复: 使用 if 替代 && 防止 set -e 退出
    if [ ! -f "/etc/sdn_hk_cluster.env" ]; then
        echo -e "\033[31m[错误] 请先初始化香港总控！\033[0m"
        return
    fi
    source /etc/sdn_hk_cluster.env
    read -p "为该落地机分配专用的中转隧道端口 [例如 25443]: " FAKE_PORT
    FAKE_PORT=${FAKE_PORT:-25443}
    
    DEPLOY_CODE=$(echo -n "${HK_IP}|${WG_PUB}|${U2R_PASS}|${SUBNET_PREFIX}|${FAKE_PORT}" | base64 -w 0)
    echo -e "\n===================================================================="
    echo -e "请复制以下【对接凭证代码】到你的落地机："
    echo -e "\n\e[36m$DEPLOY_CODE\e[0m\n"
    echo -e "===================================================================="
}

# ====================================================================================
# 模块三：配置落地机
# ====================================================================================
setup_landing_node() {
    apt-get update && apt-get install -y wireguard wireguard-tools curl jq iptables uuid-runtime systemd
    detect_hardware_and_bandwidth
    apply_ultimate_kernel
    install_dependencies

    read -p "请粘贴从香港总控复制的【对接凭证代码】: " DEPLOY_CODE
    DECODED=$(echo -n "$DEPLOY_CODE" | base64 -d)
    
    HK_IP=$(echo "$DECODED" | cut -d'|' -f1)
    HK_PUB=$(echo "$DECODED" | cut -d'|' -f2)
    U2R_PASS=$(echo "$DECODED" | cut -d'|' -f3)
    SUBNET_PREFIX=$(echo "$DECODED" | cut -d'|' -f4)
    FAKE_PORT=$(echo "$DECODED" | cut -d'|' -f5)

    read -p "为此落地机起个名字 [例如: dynamic-home 或 static-node1]: " NODE_TAG
    read -p "分配内网编号 [例如 2 或 3]: " HOST_ID
    
    LAND_IP="${SUBNET_PREFIX}.${HOST_ID}"
    WG_PRIV=$(wg genkey)
    WG_PUB=$(echo "$WG_PRIV" | wg pubkey)
    LOCAL_WG_PORT=$((RANDOM % 10000 + 40000))

    mkdir -p /etc/wireguard
    cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
PrivateKey = $WG_PRIV
Address = $LAND_IP/24
MTU = 1360
PersistentKeepalive = 10

[Peer]
PublicKey = $HK_PUB
Endpoint = $HK_IP:$FAKE_PORT
AllowedIPs = ${SUBNET_PREFIX}.1/32
EOF

    cat > /etc/systemd/system/udp2raw.service <<EOF
[Unit]
Description=udp2raw Agent Client (Ultimate)
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/udp2raw -c -l 127.0.0.1:$LOCAL_WG_PORT -r $HK_IP:$FAKE_PORT -k "$U2R_PASS" --raw-mode faketcp -a --cipher-mode xor --auth-mode simple
Restart=on-failure
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF

    mkdir -p /etc/systemd/system/wg-quick@wg0.service.d
    cat > /etc/systemd/system/wg-quick@wg0.service.d/override.conf <<EOF
[Unit]
After=udp2raw.service
Wants=udp2raw.service
EOF

    mkdir -p /etc/sing-box
    cat > /etc/sing-box/config.json <<EOF
{
  "outbounds": [{ "type": "direct", "direct" }]
}
EOF
    # 修复 json 笔误
    sed -i 's/"type":direct/"type": "direct"/g' /etc/sing-box/config.json

    cat > /etc/systemd/system/sing-box.service << EOF
[Unit]
Description=Sing-box Landing Agent
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now udp2raw wg-quick@wg0 sing-box

    REG_PAYLOAD=$(echo -n "${WG_PUB}|${LAND_IP}|${NODE_TAG}" | base64 -w 0)
    echo -e "\n===================================================================="
    echo -e "\e[32m[√] 落地节点 ($NODE_TAG) 配置成功！\e[0m"
    echo -e "请复制以下【注册密文】，回到【香港总控】选择【选项 4】完成绑定："
    echo -e "\n\e[36m$REG_PAYLOAD\e[0m\n"
    echo -e "===================================================================="
}

# ====================================================================================
# 模块四：香港总控端纳管注册
# ====================================================================================
register_node_to_hk() {
    # 修复: 使用 if 替代 && 防止 set -e 退出
    if [ ! -f "/etc/sdn_hk_cluster.env" ]; then
        echo -e "\033[31m[错误] 请先初始化香港总控！\033[0m"
        return
    fi
    source /etc/sdn_hk_cluster.env

    read -p "请粘贴落地机生成的【注册密文】: " REG_CODE
    DECODED_REG=$(echo -n "$REG_CODE" | base64 -d)
    LAND_PUB=$(echo "$DECODED_REG" | cut -d'|' -f1)
    LAND_IP=$(echo "$DECODED_REG" | cut -d'|' -f2)
    NODE_TAG=$(echo "$DECODED_REG" | cut -d'|' -f3)

    cat >> /etc/wireguard/wg0.conf <<EOF

[Peer]
PublicKey = $LAND_PUB
AllowedIPs = $LAND_IP/32
EOF
    systemctl restart wg-quick@wg0

    PEER_COUNT=$(grep -c "\[Peer\]" /etc/wireguard/wg0.conf)
    FAKE_PORT=$((35000 + PEER_COUNT))
    WG_PEER_PORT=$((30000 + PEER_COUNT))

    sed -i "s/ListenPort = .*/ListenPort = $WG_PEER_PORT/" /etc/wireguard/wg0.conf
    systemctl restart wg-quick@wg0

    cat > /etc/systemd/system/udp2raw-${NODE_TAG}.service <<EOF
[Unit]
Description=udp2raw server for $NODE_TAG
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/udp2raw -s -l 0.0.0.0:$FAKE_PORT -r 127.0.0.1:$WG_PEER_PORT -k "$U2R_PASS" --raw-mode faketcp -a --cipher-mode xor --auth-mode simple
Restart=on-failure
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now udp2raw-${NODE_TAG}.service

    echo "NODE:${NODE_TAG}:${LAND_IP}" >> /etc/sdn_nodes_registry.list
    rebuild_hk_sdn_matrix
    systemctl restart sing-box

    echo -e "\n===================================================================="
    echo -e "\e[32m[√] 落地节点 [$NODE_TAG] 成功加入集群！\e[0m"
    echo -e "===================================================================="
}

rebuild_hk_sdn_matrix() {
    local outbounds_json=""
    local tags_array=""

    if [ -f /etc/sdn_nodes_registry.list ]; then
        while IFS=: read -r prefix tag ip; do
            if [ "$prefix" = "NODE" ]; then
                outbounds_json+="{ \"type\": \"direct\", \"tag\": \"out-$tag\", \"server\": \"$ip\", \"server_port\": 443 },"
                tags_array+="\"out-$tag\","
            fi
        done < /etc/sdn_nodes_registry.list
    fi

    outbounds_json=${outbounds_json%,}
    tags_array=${tags_array%,}

    if [ -z "$outbounds_json" ]; then
        outbounds_json="{ \"type\": \"direct\", \"tag\": \"direct\" }"
        tags_array="\"direct\""
    else
        outbounds_json+=", { \"type\": \"direct\", \"tag\": \"direct\" }"
    fi

    cat > /etc/sing-box/config.json <<EOF
{
  "inbounds": [{
    "type": "vless", "tag": "vless-in", "listen": "0.0.0.0", "listen_port": $CLIENT_PORT,
    "users": [{ "uuid": "$UUID", "flow": "xtls-rprx-vision" }],
    "tls": {
      "enabled": true, "server_name": "www.apple.com",
      "reality": { "enabled": true, "handshake": { "server": "www.apple.com", "server_port": 443 }, "private_key": "$PRIVATE_KEY", "short_id": ["$SHORT_ID"] }
    }
  }],
  "outbounds": [
    {
      "type": "urltest",
      "tag": "🚀 智能测速自动优选 (TikTok/直播/游戏推荐)",
      "outbounds": [ $tags_array ],
      "url": "https://www.gstatic.com/generate_204",
      "interval": "1m",
      "tolerance": 15
    },
    {
      "type": "selector",
      "tag": "🎯 手动指定切换节点",
      "outbounds": [ $tags_array ],
      "default": "🚀 智能测速自动优选 (TikTok/直播/游戏推荐)"
    },
    $outbounds_json
  ],
  "route": {
    "rules": [{ "inbound": ["vless-in"], "outbound": "🎯 手动指定切换节点" }]
  }
}
EOF
}

# 脚本入口
check_root

while true; do
    clear
    echo "===================================================================="
    echo "    跨境软件定义边缘网络 (集群管理面板)"
    echo "===================================================================="
    echo " 1. 【第一步：香港中转机】初始化总控中心"
    echo " 2. 【第二步：香港中转机】生成落地机对接凭证代码"
    echo " 3. 【第三步：落地机(动态/静态均可)】配置并加入集群"
    echo " 4. 【第四步：香港总控】输入落地机注册密文完成组网"
    echo " 0. 退出脚本"
    echo "===================================================================="
    read -p "请选择对应操作的数字 [0-4]: " choice

    case $choice in
        1) setup_hk_master; read -p "按回车键继续..." ;;
        2) export_token; read -p "按回车键继续..." ;;
        3) setup_landing_node; read -p "按回车键继续..." ;;
        4) register_node_to_hk; read -p "按回车键继续..." ;;
        0) exit 0 ;;
        *) echo -e "\033[31m[错误] 输入无效，请重新选择。\033[0m"; sleep 2 ;;
    esac
done
