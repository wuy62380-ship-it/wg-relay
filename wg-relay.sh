#!/bin/bash
# ====================================================================================
# 跨境软件定义边缘网络系统 (集成 XanMod BBRv3 架构级适配版)
# 架构: 动态/静态落地机 -> 主动反向隧道 (udp2raw+WireGuard) -> 香港总控 -> 智能容灾/链式代理
# 场景: TikTok 1080p 60fps 手机/电脑娱播推流、低延迟游戏、家宽/机房混合多跳组网
# ====================================================================================

set -euo pipefail

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "\033[31m[错误] 必须使用 root 权限运行此脚本！\033[0m"
        exit 1
    fi
}

detect_hardware_and_bandwidth() {
    echo -e "\n\033[32m[+] 正在扫描服务器硬件与吞吐指标...\033[0m"
    CPU_CORES=$(nproc)
    TOTAL_MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo "1048576")
    TOTAL_MEM_MB=$((TOTAL_MEM_KB / 1024))
    TOTAL_MEM_GB=$(awk "BEGIN {printf \"%.1f\", $TOTAL_MEM_MB / 1024}")
    
    echo -e "    -> CPU核心: \033[36m${CPU_CORES}核 | 物理内存: ${TOTAL_MEM_GB}GB\033[0m"
}

# ================= XanMod & BBRv3 核心检测与安装逻辑 =================

xanmod_add_repo() {
    local keyring="/usr/share/keyrings/xanmod-archive-keyring.gpg"
    local list_file="/etc/apt/sources.list.d/xanmod-release.list"
    local key_url="https://dl.xanmod.org/archive.key"
    local os_codename=""

    if command -v lsb_release >/dev/null 2>&1; then
        os_codename=$(lsb_release -sc)
    elif [ -r /etc/os-release ]; then
        os_codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
    fi

    if ! echo "bookworm trixie forky sid noble plucky questing resolute faye gigi wilma xia zara zena" | grep -qw "$os_codename"; then
        os_codename="releases"
    fi

    if echo "jammy focal bullseye buster" | grep -qw "$os_codename"; then
        echo -e "\033[31m[错误] XanMod 官方已停止对当前系统 ($os_codename) 的 APT 源支持，请升级至 Debian 12 / Ubuntu 24.04 或更高版本。\033[0m"
        return 1
    fi

    if [ -z "$os_codename" ]; then
        echo -e "\033[31m[错误] 无法获取系统版本代号，无法配置 XanMod 源。\033[0m"
        return 1
    fi

    echo -e "\033[32m[+] 正在安装系统基础依赖并导入 XanMod GPG 密钥...\033[0m"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1
    apt-get install -y wget gnupg ca-certificates >/dev/null 2>&1
    
    mkdir -p /usr/share/keyrings /etc/apt/sources.list.d
    if ! wget -qO - "$key_url" | gpg --dearmor -o "$keyring" --yes; then
        echo -e "\033[31m[错误] XanMod 官方密钥下载失败，请检查网络连接！\033[0m"
        return 1
    fi
    chmod 644 "$keyring"
    echo "deb [signed-by=$keyring] http://deb.xanmod.org $os_codename main" > "$list_file"
    echo -e "\033[32m[√] XanMod APT 软件源配置完成 (系统代号: $os_codename)\033[0m"
}

xanmod_detect_psabi_level() {
    local psabi_output=""
    psabi_output=$(awk 'BEGIN {
        while (!/flags/) if (getline < "/proc/cpuinfo" != 1) exit 1
        if (/lm/&&/cmov/&&/cx8/&&/fpu/&&/fxsr/&&/mmx/&&/syscall/&&/sse2/) level = 1
        if (level == 1 && /cx16/&&/lahf/&&/popcnt/&&/sse4_1/&&/sse4_2/&&/ssse3/) level = 2
        if (level == 2 && /avx/&&/avx2/&&/bmi1/&&/bmi2/&&/f16c/&&/fma/&&/abm/&&/movbe/&&/xsave/) level = 3
        if (level == 3 && /avx512f/&&/avx512bw/&&/avx512cd/&&/avx512dq/&&/avx512vl/) level = 4
        if (level > 0) { print level; exit }
        exit 1
    }' /proc/cpuinfo 2>/dev/null) || return 1
    printf '%s' "$psabi_output" | tr -dc '0-9' | head -c 1
}

xanmod_package_available() {
    local package="$1"
    apt-cache policy "$package" 2>/dev/null | grep -q 'Candidate: [^ ]'
}

xanmod_detect_package() {
    local psabi_level=""
    local level=""
    local package=""
    local prefix_list="linux-xanmod linux-xanmod-lts"

    psabi_level=$(xanmod_detect_psabi_level) || return 1
    [ -n "$psabi_level" ] || return 1
    [ "$psabi_level" -gt 3 ] && psabi_level=3

    apt-get update -y >/dev/null 2>&1

    for prefix in $prefix_list; do
        level="$psabi_level"
        while [ "$level" -ge 1 ]; do
            package="${prefix}-x64v${level}"
            if xanmod_package_available "$package"; then
                echo -e "\033[32m[√] 自动匹配 CPU 微架构级别 (x64v${level})，最佳内核包: $package\033[0m" >&2
                printf '%s\n' "$package"
                return 0
            fi
            level=$((level - 1))
        done
    done

    echo -e "\033[31m[错误] 软件源中未找到适配此 CPU 的 XanMod 内核包！\033[0m" >&2
    return 1
}

xanmod_installed() {
    dpkg-query -W -f='${Package}\n' 'linux-*xanmod*' 2>/dev/null | grep -q '^linux-.*xanmod'
}

install_xanmod_bbr3() {
    echo -e "\n===================================================================="
    echo -e "           🚀 一键升级 Linux 内核至 XanMod (支持 BBRv3)              "
    echo -e "===================================================================="
    if ! command -v apt-get >/dev/null 2>&1; then
        echo -e "\033[31m[错误] 目前一键内核升级仅支持 Debian / Ubuntu 系统 (apt)！\033[0m"
        return 1
    fi

    read -p "确认要开始安装/升级 XanMod BBRv3 内核吗？安装后需要重启服务器 [y/N]: " confirm_install
    if [[ ! "$confirm_install" =~ ^[Yy]$ ]]; then
        return 0
    fi

    xanmod_add_repo || return 1

    local package=""
    package=$(xanmod_detect_package) || {
        echo -e "\033[31m[错误] 无法识别当前 CPU 或未找到适配包，升级取消。\033[0m"
        return 1
    }

    echo -e "\033[32m[+] 正在下载并安装最佳架构内核包 ($package)... \033[0m"
    apt-get update -y
    if apt-get install -y "$package"; then
        echo -e "\n\033[32m[√] XanMod 内核安装完成！\033[0m"
        read -p "系统需要重启以加载新内核，是否立即重启？[y/N]: " reboot_now
        if [[ "$reboot_now" =~ ^[Yy]$ ]]; then
            echo -e "\033[33m正在重启系统，请稍后重新连接 SSH...\033[0m"
            reboot
        else
            echo -e "\033[33m请稍后手动重启服务器 (\`reboot\`) 以激活新内核与 BBRv3。\033[0m"
        fi
    else
        echo -e "\033[31m[错误] XanMod 内核安装失败，请检查网络连接或兼容性。\033[0m"
    fi
}

apply_ultimate_kernel() {
    local target_algo="${1:-auto}"
    
    if [ "$target_algo" = "auto" ]; then
        if modprobe tcp_bbr3 2>/dev/null; then
            target_algo="bbr3"
        elif modprobe tcp_bbr 2>/dev/null; then
            target_algo="bbr"
        else
            target_algo="cubic"
        fi
    fi

    set_bbr_algo "$target_algo"
}

set_bbr_algo() {
    local target_algo="$1"
    echo -e "\n\033[32m[+] 正在配置并切换 TCP 拥塞控制算法为: ${target_algo}...\033[0m"
    
    if [ "$target_algo" = "bbr3" ]; then
        if ! modprobe tcp_bbr3 2>/dev/null; then
            echo -e "\033[31m[错误] 当前系统内核不支持 BBRv3 模块 (tcp_bbr3)！\033[0m"
            echo -e "\033[33m[提示] 请先选择【选项 3】一键安装 XanMod 内核后重试。\033[0m"
            return 1
        fi
        echo "tcp_bbr3" > /etc/modules-load.d/bbr.conf 2>/dev/null || true
    elif [ "$target_algo" = "bbr" ]; then
        if ! modprobe tcp_bbr 2>/dev/null; then
            echo -e "\033[31m[错误] 当前系统内核无法加载 tcp_bbr 模块！\033[0m"
            return 1
        fi
        echo "tcp_bbr" > /etc/modules-load.d/bbr.conf 2>/dev/null || true
    fi

    TOTAL_MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo "1048576")
    TOTAL_MEM_MB=$((TOTAL_MEM_KB / 1024))

    if [ "$TOTAL_MEM_MB" -ge 4096 ]; then
        CONTRACK_MAX=8388608
    else
        CONTRACK_MAX=2097152
    fi

    cat > /etc/sysctl.d/99-sdn-ultimate.conf <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = $target_algo
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
    sysctl -p /etc/sysctl.d/99-sdn-ultimate.conf >/dev/null 2>&1 || true
    echo -e "\033[32m[√] TCP 拥塞控制算法已成功切换为: ${target_algo}\033[0m"
}

manage_bbr() {
    while true; do
        clear
        CURRENT_ALGO=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}' || echo "unknown")
        CURRENT_QDISC=$(sysctl net.core.default_qdisc 2>/dev/null | awk '{print $3}' || echo "unknown")

        echo "===================================================================="
        echo "               📊 当前系统 BBR / BBRv3 状态与管理                       "
        echo "===================================================================="
        echo -e "当前 TCP 拥塞控制算法 : \033[32m${CURRENT_ALGO}\033[0m"
        echo -e "当前队列调度算法     : \033[36m${CURRENT_QDISC}\033[0m"
        if xanmod_installed; then
            echo -e "XanMod 内核状态      : \033[32m已安装 (已支持 BBRv3)\033[0m"
        else
            echo -e "XanMod 内核状态      : \033[33m未安装\033[0m"
        fi
        echo "--------------------------------------------------------------------"
        lsmod | grep bbr || echo -e "\033[33m[提示] 当前未在 lsmod 中发现已加载的 bbr 模块\033[0m"
        echo "===================================================================="
        echo " 1. 切换/开启 原版标准 BBR (内核自带)"
        echo " 2. 切换/开启 BBRv3 (需系统内核支持 tcp_bbr3)"
        echo " 3. 一键安装/更新 XanMod 内核 (智能匹配 CPU x64v1~v4)"
        echo " 4. 还原为 CUBIC 默认算法"
        echo " 0. 返回主菜单"
        echo "===================================================================="
        read -p "请选择具体操作 [0-4]: " bbr_choice

        case $bbr_choice in
            1)
                set_bbr_algo "bbr"
                read -p "按回车键继续..." ;;
            2)
                set_bbr_algo "bbr3"
                read -p "按回车键继续..." ;;
            3)
                install_xanmod_bbr3
                read -p "按回车键继续..." ;;
            4)
                set_bbr_algo "cubic"
                read -p "按回车键继续..." ;;
            0)
                break ;;
            *)
                echo -e "\033[31m[错误] 输入无效，请重新选择。\033[0m"; sleep 1 ;;
        esac
    done
}

install_dependencies() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) SB_ARCH="amd64"; U2R_ARCH="amd64" ;;
        aarch64) SB_ARCH="arm64"; U2R_ARCH="arm" ;;
        *) echo -e "\033[31m[错误] 不支持的架构: $ARCH\033[0m"; exit 1 ;;
    esac

    if [ ! -f "/usr/local/bin/udp2raw" ]; then
        wget -qO udp2raw.tar.gz "https://github.com/wangyu-/udp2raw/releases/download/20230206.0/udp2raw_binaries.tar.gz" || true
        if [ -f "udp2raw.tar.gz" ]; then
            tar -xzf udp2raw.tar.gz 2>/dev/null || true
            if [ -f "udp2raw_${U2R_ARCH}" ]; then
                mv udp2raw_${U2R_ARCH} /usr/local/bin/udp2raw
                chmod +x /usr/local/bin/udp2raw
            fi
            rm -rf udp2raw*
        fi
    fi

    if [ ! -f "/usr/local/bin/sing-box" ]; then
        local VER=""
        VER=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/' || true)
        if [ -z "$VER" ]; then
            VER="1.8.8"
        fi
        wget -qO sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${VER}/sing-box-${VER}-linux-${SB_ARCH}.tar.gz" || true
        if [ -f "sing-box.tar.gz" ]; then
            tar -xzf sing-box.tar.gz 2>/dev/null || true
            if [ -f "sing-box-${VER}-linux-${SB_ARCH}/sing-box" ]; then
                mv sing-box-${VER}-linux-${SB_ARCH}/sing-box /usr/local/bin/
                chmod +x /usr/local/bin/sing-box
            fi
            rm -rf sing-box*
        fi
    fi
}

get_pub_ip() {
    local ip=""
    for api in "ifconfig.me" "api.ipify.org" "icanhazip.com"; do
        ip=$(curl -s --connect-timeout 2 --max-time 3 -4 "$api" 2>/dev/null || true)
        ip=$(echo "$ip" | tr -d '[:space:]')
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    echo "127.0.0.1"
}

setup_hk_master() {
    apt-get update && apt-get install -y wireguard wireguard-tools curl jq iptables iproute2 uuid-runtime systemd
    detect_hardware_and_bandwidth
    apply_ultimate_kernel "auto"
    install_dependencies

    read -p "请输入客户端连接香港总控的端口 [默认 8443]: " CLIENT_PORT
    CLIENT_PORT=${CLIENT_PORT:-8443}
    
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
    KEYS=$(sing-box generate reality-keypair 2>/dev/null || echo "")
    PRIVATE_KEY=$(echo "$KEYS" | grep Private | awk '{print $3}' || echo "")
    PUBLIC_KEY=$(echo "$KEYS" | grep Public | awk '{print $3}' || echo "")
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

    iptables -I INPUT -p tcp --dport $CLIENT_PORT -j ACCEPT || true

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
    touch /etc/sdn_chains_registry.list

    echo -e "\n===================================================================="
    echo -e "\e[32m[√] 香港总控中心初始化完成！\e[0m"
    echo -e "客户端接入地址: $HK_IP | 端口: $CLIENT_PORT | UUID: $UUID"
    echo -e "===================================================================="
}

export_token() {
    if [ ! -f "/etc/sdn_hk_cluster.env" ]; then
        echo -e "\033[31m[错误] 请先初始化香港总控！\033[0m"
        return
    fi
    source /etc/sdn_hk_cluster.env
    
    PEER_COUNT=$(grep -c "\[Peer\]" /etc/wireguard/wg0.conf 2>/dev/null || echo "0")
    DEFAULT_FAKE_PORT=$((35001 + PEER_COUNT))

    read -p "为该落地机分配专用的中转隧道端口 [默认 ${DEFAULT_FAKE_PORT}]: " FAKE_PORT
    FAKE_PORT=${FAKE_PORT:-$DEFAULT_FAKE_PORT}
    
    DEPLOY_CODE=$(echo -n "${HK_IP}|${WG_PUB}|${U2R_PASS}|${SUBNET_PREFIX}|${FAKE_PORT}" | base64 -w 0 2>/dev/null || echo -n "${HK_IP}|${WG_PUB}|${U2R_PASS}|${SUBNET_PREFIX}|${FAKE_PORT}" | base64)
    echo -e "\n===================================================================="
    echo -e "请复制以下【对接凭证代码】到你的落地机："
    echo -e "\n\e[36m$DEPLOY_CODE\e[0m\n"
    echo -e "===================================================================="
}

setup_landing_node() {
    apt-get update && apt-get install -y wireguard wireguard-tools curl jq iptables uuid-runtime systemd
    detect_hardware_and_bandwidth
    apply_ultimate_kernel "auto"
    install_dependencies

    read -p "请粘贴从香港总控复制的【对接凭证代码】: " DEPLOY_CODE
    DECODED=$(echo -n "$DEPLOY_CODE" | base64 -d 2>/dev/null || echo "")
    
    HK_IP=$(echo "$DECODED" | cut -d'|' -f1)
    HK_PUB=$(echo "$DECODED" | cut -d'|' -f2)
    U2R_PASS=$(echo "$DECODED" | cut -d'|' -f3)
    SUBNET_PREFIX=$(echo "$DECODED" | cut -d'|' -f4)
    FAKE_PORT=$(echo "$DECODED" | cut -d'|' -f5)

    read -p "为此落地机起个名字 [例如: tw3 或 jp1]: " NODE_TAG
    read -p "分配内网编号 [例如 2 或 3]: " HOST_ID
    
    LAND_IP="${SUBNET_PREFIX}.${HOST_ID}"
    WG_PRIV=$(wg genkey)
    WG_PUB=$(echo "$WG_PRIV" | wg pubkey)
    LOCAL_WG_PORT=$((RANDOM % 10000 + 40000))

    mkdir -p /etc/wireguard
    cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
PrivateKey = $WG_PRIV
Address = $LAND_IP/32
MTU = 1360

[Peer]
PublicKey = $HK_PUB
Endpoint = 127.0.0.1:$LOCAL_WG_PORT
AllowedIPs = ${SUBNET_PREFIX}.1/32
PersistentKeepalive = 10
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
  "inbounds": [
    {
      "type": "socks",
      "tag": "socks-in",
      "listen": "0.0.0.0",
      "listen_port": 10808
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

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

    REG_PAYLOAD=$(echo -n "${WG_PUB}|${LAND_IP}|${NODE_TAG}|${FAKE_PORT}" | base64 -w 0 2>/dev/null || echo -n "${WG_PUB}|${LAND_IP}|${NODE_TAG}|${FAKE_PORT}" | base64)
    echo -e "\n===================================================================="
    echo -e "\e[32m[√] 落地节点 ($NODE_TAG) 配置成功！\e[0m"
    echo -e "请复制以下【注册密文】，回到【香港总控】选择【选项 4】完成绑定："
    echo -e "\n\e[36m$REG_PAYLOAD\e[0m\n"
    echo -e "===================================================================="
}

register_node_to_hk() {
    if [ ! -f "/etc/sdn_hk_cluster.env" ]; then
        echo -e "\033[31m[错误] 请先初始化香港总控！\033[0m"
        return
    fi
    source /etc/sdn_hk_cluster.env

    read -p "请粘贴落地机生成的【注册密文】: " REG_CODE
    DECODED_REG=$(echo -n "$REG_CODE" | base64 -d 2>/dev/null || echo "")
    LAND_PUB=$(echo "$DECODED_REG" | cut -d'|' -f1)
    LAND_IP=$(echo "$DECODED_REG" | cut -d'|' -f2)
    NODE_TAG=$(echo "$DECODED_REG" | cut -d'|' -f3)
    FAKE_PORT=$(echo "$DECODED_REG" | cut -d'|' -f4)

    cat >> /etc/wireguard/wg0.conf <<EOF

[Peer]
# Node: $NODE_TAG
PublicKey = $LAND_PUB
AllowedIPs = $LAND_IP/32
EOF
    systemctl restart wg-quick@wg0

    iptables -I INPUT -p tcp --dport $FAKE_PORT -j ACCEPT || true

    cat > /etc/systemd/system/udp2raw-${NODE_TAG}.service <<EOF
[Unit]
Description=udp2raw server for $NODE_TAG
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/udp2raw -s -l 0.0.0.0:$FAKE_PORT -r 127.0.0.1:30000 -k "$U2R_PASS" --raw-mode faketcp -a --cipher-mode xor --auth-mode simple
Restart=on-failure
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now udp2raw-${NODE_TAG}.service

    (
        flock -x 200
        echo "NODE:${NODE_TAG}:${LAND_IP}" >> /etc/sdn_nodes_registry.list
        rebuild_hk_sdn_matrix
        systemctl restart sing-box
    ) 200>/var/lock/sdn_registry.lock

    echo -e "\n===================================================================="
    echo -e "\e[32m[√] 落地节点 [$NODE_TAG] 成功加入集群！\e[0m"
    echo -e "===================================================================="
}

show_node_links() {
    if [ ! -f "/etc/sdn_hk_cluster.env" ]; then
        echo -e "\033[31m[错误] 当前服务器未初始化香港总控，或找不到配置文件！\033[0m"
        return
    fi
    source /etc/sdn_hk_cluster.env

    echo -e "\n===================================================================="
    echo -e "                   🌐 集群节点 VLESS 接入链接                        "
    echo -e "===================================================================="

    if [ ! -f "/etc/sdn_nodes_registry.list" ] || [ ! -s "/etc/sdn_nodes_registry.list" ]; then
        echo -e "\033[33m[提示] 暂未注册任何落地节点。\033[0m"
    else
        echo -e "\n\033[35m=== 直连落地节点 ===\033[0m"
        while IFS=: read -r prefix tag ip; do
            if [ "$prefix" = "NODE" ]; then
                echo -e "\n📌 节点标识: \033[32m${tag}\033[0m  |  隧道 IP: \033[33m${ip}\033[0m"
                echo -e "\033[36mvless://${UUID}@${HK_IP}:${CLIENT_PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=www.apple.com&sid=${SHORT_ID}#SDN-${tag}\033[0m"
            fi
        done < /etc/sdn_nodes_registry.list

        if [ -f "/etc/sdn_chains_registry.list" ] && [ -s "/etc/sdn_chains_registry.list" ]; then
            echo -e "\n\033[35m=== 多级链式级联节点 ===\033[0m"
            while IFS=: read -r prefix chain_tag node1 node2; do
                if [ "$prefix" = "CHAIN" ]; then
                    echo -e "\n🔗 链式组合: \033[32m${chain_tag}\033[0m  |  链路: 香港 -> \033[33m${node1}\033[0m -> \033[33m${node2}\033[0m -> 目标"
                    echo -e "\033[36mvless://${UUID}@${HK_IP}:${CLIENT_PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=www.apple.com&sid=${SHORT_ID}#SDN-Chain-${chain_tag}\033[0m"
                fi
            done < /etc/sdn_chains_registry.list
        fi
    fi
    echo -e "\n===================================================================="
}

setup_chain_proxy() {
    if [ ! -f "/etc/sdn_nodes_registry.list" ] || [ $(grep -c "^NODE:" /etc/sdn_nodes_registry.list 2>/dev/null || echo 0) -lt 2 ]; then
        echo -e "\033[31m[错误] 配置多级链式代理至少需要注册 2 个以上的落地节点！\033[0m"
        return
    fi

    echo -e "\n\033[32m=== 可用的落地节点 ===\033[0m"
    grep "^NODE:" /etc/sdn_nodes_registry.list | cut -d':' -f2,3

    read -p "请输入前置跳板节点 Tag [例如 tw3]: " NODE1_TAG
    read -p "请输入最终出口节点 Tag [例如 jp1]: " NODE2_TAG

    if [ "$NODE1_TAG" = "$NODE2_TAG" ]; then
        echo -e "\033[31m[错误] 跳板节点和出口节点不能相同！\033[0m"
        return
    fi

    CHAIN_TAG="${NODE1_TAG}-to-${NODE2_TAG}"

    (
        flock -x 200
        sed -i "/^CHAIN:${CHAIN_TAG}:/d" /etc/sdn_chains_registry.list 2>/dev/null || true
        echo "CHAIN:${CHAIN_TAG}:${NODE1_TAG}:${NODE2_TAG}" >> /etc/sdn_chains_registry.list
        rebuild_hk_sdn_matrix
        systemctl restart sing-box
    ) 200>/var/lock/sdn_registry.lock

    echo -e "\n===================================================================="
    echo -e "\e[32m[√] 多级链式代理 [香港 -> $NODE1_TAG -> $NODE2_TAG] 构建完成！\e[0m"
    echo -e "===================================================================="
}

rebuild_hk_sdn_matrix() {
    local outbounds_json=""
    local tags_array=""

    if [ -f /etc/sdn_nodes_registry.list ]; then
        while IFS=: read -r prefix tag ip; do
            if [ "$prefix" = "NODE" ]; then
                outbounds_json+="{ \"type\": \"socks\", \"tag\": \"out-$tag\", \"server\": \"$ip\", \"server_port\": 10808 },"
                tags_array+="\"out-$tag\","
            fi
        done < /etc/sdn_nodes_registry.list
    fi

    if [ -f /etc/sdn_chains_registry.list ]; then
        while IFS=: read -r prefix chain_tag node1 node2; do
            if [ "$prefix" = "CHAIN" ]; then
                node2_ip=$(grep "^NODE:${node2}:" /etc/sdn_nodes_registry.list | cut -d':' -f3)
                if [ -n "$node2_ip" ]; then
                    outbounds_json+="{ \"type\": \"socks\", \"tag\": \"out-chain-$chain_tag\", \"server\": \"$node2_ip\", \"server_port\": 10808, \"detour\": \"out-$node1\" },"
                    tags_array+="\"out-chain-$chain_tag\","
                fi
            fi
        done < /etc/sdn_chains_registry.list
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

# 脚本主程序入口
check_root

while true; do
    clear
    CURRENT_BBR=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}' || echo "未检测")
    echo "===================================================================="
    echo "    跨境软件定义边缘网络 (集群管理面板)"
    echo -e "    当前内核拥塞控制算法: [ \033[32m${CURRENT_BBR}\033[0m ]"
    echo "===================================================================="
    echo " 1. 【第一步：香港中转机】初始化总控中心"
    echo " 2. 【第二步：香港中转机】生成落地机对接凭证代码"
    echo " 3. 【第三步：落地机(动态/静态均可)】配置并加入集群"
    echo " 4. 【第四步：香港总控】输入落地机注册密文完成组网"
    echo " 5. 【香港总控】查看/导出所有节点的 VLESS 接入链接"
    echo " 6. 【香港总控】配置多级链式代理 (例如: 香港->tw3->jp1)"
    echo " 7. 【系统工具】BBR / BBRv3 算法独立切换与内核管理"
    echo " 0. 退出脚本"
    echo "===================================================================="
    read -p "请选择对应操作的数字 [0-7]: " choice

    choice=$(echo "$choice" | tr -d '[:space:]')

    case $choice in
        1) setup_hk_master; read -p "按回车键继续..." ;;
        2) export_token; read -p "按回车键继续..." ;;
        3) setup_landing_node; read -p "按回车键继续..." ;;
        4) register_node_to_hk; read -p "按回车键继续..." ;;
        5) show_node_links; read -p "按回车键继续..." ;;
        6) setup_chain_proxy; read -p "按回车键继续..." ;;
        7) manage_bbr ;;
        0) exit 0 ;;
        *) echo -e "\033[31m[错误] 输入无效，请重新选择。\033[0m"; sleep 2 ;;
    esac
done
