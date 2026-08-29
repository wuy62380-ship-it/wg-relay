#!/bin/bash
# ====================================================================================
# 跨境软件定义边缘网络系统 (生产级深度修复版)
# 架构: 动态/静态落地机 -> 主动反向隧道 (udp2raw+WireGuard) -> 香港总控 -> 智能容灾/链式代理
# 场景: TikTok 1080p 60fps 手机/电脑娱播推流、低延迟游戏、家宽/机房混合多跳组网
# ====================================================================================

set -euo pipefail

# 终端颜色定义
RED='\033[31m'
G='\033[32m'
Y='\033[33m'
C='\033[36m'
H='\033[35m'
R='\033[0m'

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[错误] 必须使用 root 权限运行此脚本！${R}"
        exit 1
    fi
}

detect_hardware_and_bandwidth() {
    echo -e "\n${G}[+] 正在扫描服务器硬件与吞吐指标...${R}"
    CPU_CORES=$(nproc)
    TOTAL_MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo "1048576")
    TOTAL_MEM_MB=$((TOTAL_MEM_KB / 1024))
    TOTAL_MEM_GB=$(awk "BEGIN {printf \"%.1f\", $TOTAL_MEM_MB / 1024}")
    
    echo -e "    -> CPU核心: ${C}${CPU_CORES}核 | 物理内存: ${TOTAL_MEM_GB}GB${R}"
}

# ================= XanMod & BBRv3 完整内核管理模块 =================

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

    if [ -z "$os_codename" ]; then
        os_codename="releases"
    fi

    echo -e "${Y}正在安装依赖并配置 XanMod 官方 HTTPS 源...${R}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -yq wget gnupg ca-certificates apt-transport-https >/dev/null 2>&1 || true
    mkdir -p /usr/share/keyrings /etc/apt/sources.list.d
    if ! wget -qO - "$key_url" | gpg --dearmor -o "$keyring" --yes; then
        echo -e "${RED}官方密钥下载失败${R}"
        return 1
    fi
    chmod 644 "$keyring"
    echo "deb [signed-by=$keyring] http://deb.xanmod.org $os_codename main" > "$list_file"
    
    echo -e "${Y}正在刷新软件包索引...${R}"
    apt-get update -y
    echo -e "${G}XanMod 源配置完成 (系统代号: $os_codename)${R}"
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
    local candidate
    candidate=$(apt-cache policy "$package" 2>/dev/null | awk '/Candidate:/ {print $2}')
    [ -n "$candidate" ] && [ "$candidate" != "(none)" ]
}

xanmod_detect_package() {
    local psabi_level=""
    local level=""
    local package=""
    local prefix_list="linux-xanmod linux-xanmod-lts"

    psabi_level=$(xanmod_detect_psabi_level) || psabi_level=3
    [ -n "$psabi_level" ] || psabi_level=3
    
    if [ "$psabi_level" -gt 3 ]; then
        psabi_level=3
    fi

    apt-get update -y >/dev/null 2>&1

    for prefix in $prefix_list; do
        level="$psabi_level"
        while [ "$level" -ge 1 ]; do
            package="${prefix}-x64v${level}"
            if xanmod_package_available "$package"; then
                echo -e "${G}已自动匹配合适安装包: $package${R}" >&2
                printf '%s\n' "$package"
                return 0
            fi
            level=$((level - 1))
        done
    done

    if xanmod_package_available "linux-xanmod-x64v3"; then
        echo -e "${G}已匹配标准保底安装包: linux-xanmod-x64v3${R}" >&2
        printf 'linux-xanmod-x64v3\n'
        return 0
    elif xanmod_package_available "linux-xanmod-x64v1"; then
        echo -e "${G}已匹配兼容保底安装包: linux-xanmod-x64v1${R}" >&2
        printf 'linux-xanmod-x64v1\n'
        return 0
    fi

    echo -e "${RED}软件源中未找到适配此CPU的XanMod内核包${R}" >&2
    return 1
}

xanmod_installed() {
    dpkg-query -W -f='${Package}\n' 'linux-*xanmod*' 2>/dev/null | grep -q '^linux-.*xanmod'
}

ask_reboot() {
    read -e -p "是否立即重启服务器以应用更改？[Y/n]: " choice
    case "$choice" in
        [Yy]|"")
            echo -e "${Y}正在重启服务器...${R}"
            reboot
            ;;
        *)
            echo -e "${Y}请稍后手动重启服务器命令: reboot${R}"
            ;;
    esac
}

xanmod_install_or_update() {
    local action="$1"
    local package=""
    export DEBIAN_FRONTEND=noninteractive

    xanmod_add_repo || {
        echo -e "${RED}XanMod官方仓库配置失败，请稍后重试${R}"
        return 1
    }

    package=$(xanmod_detect_package) || {
        echo -e "${RED}无法识别当前CPU或找不到匹配内核包，已取消安装${R}"
        return 1
    }

    echo -e "${Y}正在更新软件源并安装内核 (包大小约100MB，请耐心等待)...${R}"
    if [ "$action" = "update" ]; then
        apt-get install -yq --only-upgrade "$package" || apt-get install -yq "$package" || {
            echo -e "${RED}XanMod内核更新失败，请检查软件源或稍后重试${R}"
            return 1
        }
    else
        apt-get install -yq "$package" || {
            echo -e "${RED}XanMod内核安装失败，请检查软件源或稍后重试${R}"
            return 1
        }
    fi

    set_bbr_algo "bbr" > /dev/null 2>&1 || true

    echo -e "${G}XanMod BBRv3内核处理完成。重启后生效${R}"
    ask_reboot
}

xanmod_uninstall() {
    echo -e "${Y}正在卸载 XanMod 内核...${R}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get purge -yq 'linux-*xanmod*'
    apt-get autoremove -yq
    if command -v update-grub >/dev/null 2>&1; then
        sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=0/g' /etc/default/grub
        update-grub
    elif command -v grub2-mkconfig >/dev/null 2>&1; then
        grub2-mkconfig -o /boot/grub2/grub.cfg
    fi
    rm -f /etc/apt/sources.list.d/xanmod-release.list
    rm -f /usr/share/keyrings/xanmod-archive-keyring.gpg
    echo -e "${G}XanMod内核已卸载。重启后生效${R}"
    ask_reboot
}

xanmod_manage() {
    if ! command -v apt-get >/dev/null 2>&1; then
        echo -e "${RED}仅支持 Debian/Ubuntu 系统安装 XanMod 内核${R}"
        read -rs -n 1 -p "按任意键继续..."; return
    fi

    if xanmod_installed; then
        while true; do
            clear
            local kernel_version=$(uname -r)
            echo -e "${G}您已安装 xanmod 内核${R}"
            echo -e "当前内核版本: ${C}$kernel_version${R}\n"
            echo -e "${Y}内核管理${R}"
            echo -e "------------------------"
            echo -e "${Y}1. 更新BBRv3内核              2. 卸载BBRv3内核${R}"
            echo -e "------------------------"
            echo -e "${H}0. 返回上一级选单${R}"
            read -e -p "请输入你的选择: " sub_choice
            case $sub_choice in
                1) xanmod_install_or_update update ;;
                2) xanmod_uninstall ;;
                *) break ;;
            esac
        done
    else
        clear
        echo -e "${Y}设置BBR3加速${R}"
        echo -e "------------------------------------------------"
        echo -e "仅支持Debian/Ubuntu"
        echo -e "请备份数据，将为你升级Linux内核开启BBR3"
        echo -e "------------------------------------------------"
        read -e -p "确定继续吗？[Y/n]: " choice
        case "$choice" in
            [Yy]|"") xanmod_install_or_update install ;;
            *) echo -e "${Y}已取消${R}" ;;
        esac
    fi
}

# ================= TCP 网络调优与算法管理 =================

set_bbr_algo() {
    local target_algo="$1"
    local current_kernel=$(uname -r)
    local is_xanmod=0

    if echo "$current_kernel" | grep -qi "xanmod"; then
        is_xanmod=1
    fi

    echo -e "\n${G}[+] 正在配置并切换 TCP 拥塞控制算法为: ${target_algo}...${R}"

    if [ "$target_algo" = "bbr3" ] || [ "$target_algo" = "bbr" ]; then
        modprobe tcp_bbr 2>/dev/null || true

        local avail_algos
        avail_algos=$(sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | awk -F'=' '{print $2}' || echo "")
        
        if ! echo "$avail_algos" | grep -qw "bbr"; then
            echo -e "${RED}[错误] 当前系统内核不支持或未加载 BBR 模块！${R}"
            if [ $is_xanmod -eq 0 ]; then
                echo -e "${Y}[提示] 非 XanMod 内核，请先一键安装 XanMod 内核以获得 BBRv3 支持。${R}"
            fi
            return 1
        fi

        target_algo="bbr"

        if [ $is_xanmod -eq 1 ]; then
            echo -e "${G}[信息] 检测到 XanMod 内核 ($current_kernel)，启用 bbr 算法即生效 BBRv3！${R}"
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
    echo -e "${G}[√] TCP 拥塞控制算法已成功切换为: ${target_algo}${R}"
}

manage_bbr() {
    while true; do
        clear
        CURRENT_ALGO=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}' || echo "unknown")
        CURRENT_QDISC=$(sysctl net.core.default_qdisc 2>/dev/null | awk '{print $3}' || echo "unknown")
        CURRENT_KERNEL=$(uname -r)

        echo "===================================================================="
        echo "               📊 当前系统 BBR / BBRv3 状态与管理                       "
        echo "===================================================================="
        echo -e "当前内核版本        : ${C}${CURRENT_KERNEL}${R}"
        echo -e "当前 TCP 拥塞控制算法 : ${G}${CURRENT_ALGO}${R}"
        echo -e "当前队列调度算法     : ${C}${CURRENT_QDISC}${R}"
        if xanmod_installed; then
            echo -e "XanMod 内核状态      : ${G}已安装 (运行 bbr 算法即为 BBRv3)${R}"
        else
            echo -e "XanMod 内核状态      : ${Y}未安装${R}"
        fi
        echo "--------------------------------------------------------------------"
        if echo "$CURRENT_KERNEL" | grep -qi "xanmod"; then
            echo -e "${G}[说明] 当前为 XanMod 内核，系统自带完整 BBRv3 代码集成${R}"
        fi
        echo "===================================================================="
        echo " 1. 切换/开启 原版标准 BBR (内核自带)"
        echo " 2. 切换/开启 BBRv3 (在 XanMod 内核下激活 BBRv3)"
        echo " 3. XanMod BBRv3 内核管理 (安装 / 更新 / 卸载)"
        echo " 4. 还原为 CUBIC 默认算法"
        echo " 0. 返回主菜单"
        echo "===================================================================="
        read -p "请选择具体操作 [0-4]: " bbr_choice

        case $bbr_choice in
            1) set_bbr_algo "bbr"; read -p "按回车键继续..." ;;
            2) set_bbr_algo "bbr3"; read -p "按回车键继续..." ;;
            3) xanmod_manage ;;
            4) set_bbr_algo "cubic"; read -p "按回车键继续..." ;;
            0) break ;;
            *) echo -e "${RED}[错误] 输入无效，请重新选择。${R}"; sleep 1 ;;
        esac
    done
}

apply_ultimate_kernel() {
    local target_algo="${1:-auto}"
    if [ "$target_algo" = "auto" ]; then
        target_algo="bbr"
    fi
    set_bbr_algo "$target_algo" || true
}

# ================= 边缘网络组网与节点管理 =================

install_dependencies() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) SB_ARCH="amd64"; U2R_ARCH="amd64" ;;
        aarch64) SB_ARCH="arm64"; U2R_ARCH="arm" ;;
        *) echo -e "${RED}[错误] 不支持的架构: $ARCH${R}"; exit 1 ;;
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

    if [ ! -f "/usr/local/bin/sing-box" ] || ! /usr/local/bin/sing-box version >/dev/null 2>&1; then
        rm -f /usr/local/bin/sing-box
        local LATEST_URL=$(curl -w "%{url_effective}" -I -L -s -S https://github.com/SagerNet/sing-box/releases/latest -o /dev/null || true)
        local VER=$(echo "$LATEST_URL" | awk -F'/v' '{print $NF}')
        if [ -z "$VER" ] || [[ ! "$VER" =~ ^[0-9] ]]; then
            VER="1.9.3" # 保底稳定版本
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
    export DEBIAN_FRONTEND=noninteractive
    apt-get update && apt-get install -yq wireguard wireguard-tools curl jq iptables iproute2 uuid-runtime systemd iptables-persistent python3
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
    KEYS=$(/usr/local/bin/sing-box generate reality-keypair 2>/dev/null || echo "")
    PRIVATE_KEY=$(echo "$KEYS" | grep -i Private | awk '{print $NF}')
    PUBLIC_KEY=$(echo "$KEYS" | grep -i Public | awk '{print $NF}')
    
    if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
        echo -e "${RED}[致命错误] Sing-box Reality 证书生成失败！可能是 Sing-box 下载不完整或服务器环境不兼容。${R}"
        exit 1
    fi
    
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
    netfilter-persistent save >/dev/null 2>&1 || iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

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
    echo -e "${G}[√] 香港总控中心初始化完成！${R}"
    echo -e "客户端接入地址: $HK_IP | 端口: $CLIENT_PORT | UUID: $UUID"
    echo -e "===================================================================="
}

export_token() {
    if [ ! -f "/etc/sdn_hk_cluster.env" ]; then
        echo -e "${RED}[错误] 请先初始化香港总控！${R}"
        return
    fi
    source /etc/sdn_hk_cluster.env
    
    # 修复：使用安全的方式统计 Peer 数量，防止 0\n0 错误
    local PEER_COUNT=$(grep -c "\[Peer\]" /etc/wireguard/wg0.conf 2>/dev/null || true)
    PEER_COUNT=${PEER_COUNT:-0}
    
    DEFAULT_FAKE_PORT=$((35001 + PEER_COUNT))

    read -p "为该落地机分配专用的中转隧道端口 [默认 ${DEFAULT_FAKE_PORT}]: " FAKE_PORT
    FAKE_PORT=${FAKE_PORT:-$DEFAULT_FAKE_PORT}
    
    DEPLOY_CODE=$(echo -n "${HK_IP}|${WG_PUB}|${U2R_PASS}|${SUBNET_PREFIX}|${FAKE_PORT}" | base64 -w 0 2>/dev/null || echo -n "${HK_IP}|${WG_PUB}|${U2R_PASS}|${SUBNET_PREFIX}|${FAKE_PORT}" | base64)
    echo -e "\n===================================================================="
    echo -e "请复制以下【对接凭证代码】到你的落地机："
    echo -e "\n${C}$DEPLOY_CODE${R}\n"
    echo -e "===================================================================="
}

setup_landing_node() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update && apt-get install -yq wireguard wireguard-tools curl jq iptables uuid-runtime systemd iptables-persistent python3
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

    while true; do
        read -p "为此落地机起个名字 [例如: 台湾 或 jp1]: " NODE_TAG
        if [ -z "$NODE_TAG" ]; then
            echo -e "${RED}节点名称不能为空，请重新输入！${R}"
        elif [[ "$NODE_TAG" =~ [\"\'/\\|\&\;\$\:\ \\r] ]]; then
            echo -e "${RED}节点名称不能包含引号、空格、斜杠、冒号等特殊符号，请重新输入！${R}"
        else
            break
        fi
    done

    while true; do
        read -p "分配内网编号 [2-254]: " HOST_ID
        if [[ "$HOST_ID" =~ ^[0-9]+$ ]] && [ "$HOST_ID" -ge 2 ] && [ "$HOST_ID" -le 254 ]; then
            break
        else
            echo -e "${RED}内网编号必须是 2-254 的数字，请重新输入！${R}"
        fi
    done
    
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
      "listen": "$LAND_IP",
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
    echo -e "${G}[√] 落地节点 ($NODE_TAG) 配置成功！${R}"
    echo -e "请复制以下【注册密文】，回到【香港总控】选择【选项 4】完成绑定："
    echo -e "\n${C}$REG_PAYLOAD${R}\n"
    echo -e "===================================================================="
}

register_node_to_hk() {
    if [ ! -f "/etc/sdn_hk_cluster.env" ]; then
        echo -e "${RED}[错误] 请先初始化香港总控！${R}"
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
    
    wg set wg0 peer "$LAND_PUB" allowed-ips "$LAND_IP/32" 2>/dev/null || systemctl reload wg-quick@wg0 2>/dev/null || true

    iptables -I INPUT -p tcp --dport $FAKE_PORT -j ACCEPT || true
    netfilter-persistent save >/dev/null 2>&1 || true

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
        sed -i "/^NODE:${NODE_TAG}:/d" /etc/sdn_nodes_registry.list 2>/dev/null || true
        echo "NODE:${NODE_TAG}:${LAND_IP}" >> /etc/sdn_nodes_registry.list
        rebuild_hk_sdn_matrix
    ) 200>/var/lock/sdn_registry.lock

    echo -e "\n===================================================================="
    echo -e "${G}[√] 落地节点 [$NODE_TAG] 成功加入集群！${R}"
    echo -e "===================================================================="
}

# ================= 多协议链接解析器 =================
decode_url() {
    python3 -c "import urllib.parse, sys; print(urllib.parse.unquote(sys.argv[1]))" "$1" 2>/dev/null || echo "$1"
}

parse_proxy_link() {
    local link="$1"
    local tag="$2"
    local protocol="${link%%://*}"
    local body="${link#*://}"
    local auth="${body%%@*}"
    local rest="${body#*@}"
    
    local server_port="${rest%%\?*}"
    local server="${server_port%%:*}"
    local port="${server_port##*:}"
    
    local query_tag="${rest#*\?}"
    local query=""
    local link_tag=""
    if [[ "$query_tag" == *"#"* ]]; then
        query="${query_tag%%#*}"
        link_tag="${query_tag##*#}"
    else
        query="$query_tag"
    fi
    
    [ -z "$tag" ] && tag="$(decode_url "$link_tag")"
    tag=$(echo "$tag" | sed 's/[^a-zA-Z0-9_\-\x80-\xff]//g')
    [ -z "$port" ] && return 1

    local json_str=""
    local flow="" security="" sni="" fp="" pbk="" sid="" type="tcp" path="" host="" alpn="" insecure="" pass="" obfs="" obfs_pwd=""

    local IFS='&'
    for kv in $query; do
        local k="${kv%%=*}"
        local v="${kv#*=}"
        case "$k" in
            flow) flow="$v" ;;
            security) security="$v" ;;
            sni) sni=$(decode_url "$v") ;;
            fp) fp="$v" ;;
            pbk) pbk="$v" ;;
            sid) sid="$v" ;;
            type) type="$v" ;;
            path) path=$(decode_url "$v") ;;
            host) host=$(decode_url "$v") ;;
            alpn) alpn="$v" ;;
            insecure) insecure="$v" ;;
            obfs) obfs="$v" ;;
            obfs-password) obfs_pwd=$(decode_url "$v") ;;
        esac
    done

    case "$protocol" in
        vless)
            json_str="{ \"type\": \"vless\", \"tag\": \"out-ext-$tag\", \"server\": \"$server\", \"server_port\": $port, \"uuid\": \"$auth\""
            if [ -n "$flow" ]; then json_str+=", \"flow\": \"$flow\""; fi
            if [ "$type" = "ws" ]; then
                json_str+=", \"network\": \"ws\", \"transport\": { \"type\": \"ws\", \"path\": \"$path\""
                if [ -n "$host" ]; then json_str+=", \"headers\": { \"Host\": \"$host\" }"; fi
                json_str+=" }"
            elif [ "$type" = "grpc" ]; then
                json_str+=", \"network\": \"grpc\", \"transport\": { \"type\": \"grpc\", \"serviceName\": \"$path\" }"
            fi
            if [ "$security" = "reality" ]; then
                json_str+=", \"tls\": { \"enabled\": true, \"server_name\": \"$sni\", \"reality\": { \"enabled\": true, \"public_key\": \"$pbk\", \"short_id\": \"$sid\" }"
                if [ -n "$fp" ]; then json_str+=", \"utls\": { \"enabled\": true, \"fingerprint\": \"$fp\" }"; fi
                json_str+=" }"
            elif [ "$security" = "tls" ]; then
                json_str+=", \"tls\": { \"enabled\": true, \"server_name\": \"$sni\""
                if [ -n "$fp" ]; then json_str+=", \"utls\": { \"enabled\": true, \"fingerprint\": \"$fp\" }"; fi
                if [ -n "$alpn" ]; then json_str+=", \"alpn\": [\"$alpn\"]"; fi
                json_str+=" }"
            fi
            json_str+=" }"
            ;;
        hysteria2)
            json_str="{ \"type\": \"hysteria2\", \"tag\": \"out-ext-$tag\", \"server\": \"$server\", \"server_port\": $port, \"password\": \"$auth\""
            json_str+=", \"tls\": { \"enabled\": true, \"server_name\": \"$sni\""
            if [ "$insecure" = "1" ]; then json_str+=", \"insecure\": true"; fi
            if [ -n "$alpn" ]; then json_str+=", \"alpn\": [\"$alpn\"]"; fi
            json_str+=" }"
            if [ -n "$obfs" ]; then
                json_str+=", \"obfs\": { \"type\": \"$obfs\", \"password\": \"$obfs_pwd\" }"
            fi
            json_str+=" }"
            ;;
        trojan)
            json_str="{ \"type\": \"trojan\", \"tag\": \"out-ext-$tag\", \"server\": \"$server\", \"server_port\": $port, \"password\": \"$auth\""
            if [ "$security" = "tls" ] || [ -z "$security" ]; then
                json_str+=", \"tls\": { \"enabled\": true, \"server_name\": \"$sni\""
                if [ -n "$alpn" ]; then json_str+=", \"alpn\": [\"$alpn\"]"; fi
                json_str+=" }"
            fi
            json_str+=" }"
            ;;
        *) return 1 ;;
    esac
    echo "$json_str"
}

# ================= 外部节点导入模块 =================
setup_external_proxy() {
    if [ ! -f "/etc/sdn_hk_cluster.env" ]; then
        echo -e "${RED}[错误] 请先初始化香港总控！${R}"
        return
    fi
    source /etc/sdn_hk_cluster.env

    echo -e "\n${G}=== 添加外部现成代理节点 ===${R}"
    echo -e "适用于直接购买的静态代理或现成的节点链接 (无需在目标机安装脚本)。"
    echo -e " 1. HTTP 代理"
    echo -e " 2. SOCKS5 代理"
    echo -e " 3. VLESS 链接导入 (支持 Reality / WS / TLS)"
    echo -e " 4. Hysteria2 链接导入"
    echo -e " 5. Trojan 链接导入"
    read -p "请选择导入类型 [默认 3]: " type_choice
    
    local proxy_type=""
    local node_tag=""
    local payload=""
    
    case "$type_choice" in
        1) proxy_type="http" ;;
        2) proxy_type="socks" ;;
        4) proxy_type="hysteria2" ;;
        5) proxy_type="trojan" ;;
        *) proxy_type="vless" ;;
    esac

    if [ "$proxy_type" == "vless" ] || [ "$proxy_type" == "hysteria2" ] || [ "$proxy_type" == "trojan" ]; then
        read -p "请粘贴 $proxy_type 链接: " proxy_link
        if [[ ! "$proxy_link" =~ ^$proxy_type:// ]]; then
            echo -e "${RED}[错误] 无效的 $proxy_type 链接！${R}"
            return
        fi
        
        local temp_tag="${proxy_link##*#}"
        temp_tag=$(decode_url "$temp_tag" | sed 's/[^a-zA-Z0-9_\-\x80-\xff]//g')
        if [ -z "$temp_tag" ]; then
            read -p "请输入节点名称 [例如: 台湾-VLESS]: " node_tag
        else
            node_tag="$temp_tag"
        fi
        
        payload=$(echo -n "$proxy_link" | base64 -w 0)
    else
        while true; do
            read -p "请输入外部代理节点名称 [例如: 台湾-http]: " node_tag
            if [ -z "$node_tag" ]; then
                echo -e "${RED}节点名称不能为空，请重新输入！${R}"
            elif [[ "$node_tag" =~ [\"\'/\\|\&\;\$\:\ \r] ]]; then
                echo -e "${RED}节点名称不能包含引号、空格、斜杠、冒号等特殊符号，请重新输入！${R}"
            else
                break
            fi
        done
        
        read -p "请输入代理服务器IP或域名: " PROXY_SERVER
        if [ -z "$PROXY_SERVER" ]; then
            echo -e "${RED}[错误] IP不能为空！${R}"
            return
        fi

        while true; do
            read -p "请输入代理端口 [1-65535]: " PROXY_PORT
            if [[ "$PROXY_PORT" =~ ^[0-9]+$ ]] && [ "$PROXY_PORT" -ge 1 ] && [ "$PROXY_PORT" -le 65535 ]; then
                break
            else
                echo -e "${RED}端口必须是 1-65535 的数字，请重新输入！${R}"
            fi
        done

        read -p "请输入用户名 (无认证则回车跳过): " PROXY_USER
        local PROXY_PASS="-"
        if [ -n "$PROXY_USER" ]; then
            read -s -p "请输入密码: " PROXY_PASS
            echo ""
        else
            PROXY_USER="-"
        fi

        NODE_TAG=$(echo "$NODE_TAG" | tr -d '"')
        PROXY_SERVER=$(echo "$PROXY_SERVER" | tr -d '"')
        PROXY_USER=$(echo "$PROXY_USER" | tr -d '"')
        PROXY_PASS=$(echo "$PROXY_PASS" | tr -d '"')
        
        payload=$(echo -n "${PROXY_SERVER}:${PROXY_PORT}:${PROXY_USER}:${PROXY_PASS}" | base64 -w 0)
    fi

    (
        flock -x 200
        sed -i "/^EXT:${proxy_type}:${node_tag}:/d" /etc/sdn_nodes_registry.list 2>/dev/null || true
        echo "EXT:${proxy_type}:${node_tag}:${payload}" >> /etc/sdn_nodes_registry.list
        rebuild_hk_sdn_matrix
    ) 200>/var/lock/sdn_registry.lock

    echo -e "\n===================================================================="
    echo -e "${G}[√] 外部代理节点 [$node_tag] ($proxy_type) 处理完成！${R}"
    echo -e "===================================================================="
}

# ================= 节点管理与链接导出模块 =================
manage_nodes() {
    if [ ! -f "/etc/sdn_hk_cluster.env" ]; then
        echo -e "${RED}[错误] 当前服务器未初始化香港总控，或找不到配置文件！${R}"
        return
    fi
    source /etc/sdn_hk_cluster.env

    while true; do
        clear
        echo -e "${G}====================================================================${R}"
        echo -e "${G}                   🌐 集群节点管理与链接导出                        ${R}"
        echo -e "${G}====================================================================${R}"
        
        local nodes_list=()
        local idx=1
        
        if [ -f /etc/sdn_nodes_registry.list ]; then
            while IFS=: read -r prefix p1 p2 p3 p4 p5 p6; do
                if [ "$prefix" = "NODE" ]; then
                    echo -e "${C}[$idx]${R} 内网落地: ${G}${p1}${R} (隧道IP: ${Y}${p2}${R})"
                    nodes_list+=("NODE:${p1}")
                    ((idx++))
                elif [ "$prefix" = "EXT" ]; then
                    local ext_type="$p1"
                    local ext_tag="$p2"
                    if [[ "$ext_type" == "vless" || "$ext_type" == "hysteria2" || "$ext_type" == "trojan" ]]; then
                        echo -e "${C}[$idx]${R} 外部代理: ${G}${ext_tag}${R} (${Y}${ext_type} 链接${R})"
                    else
                        local decoded=$(echo "$p3" | base64 -d 2>/dev/null)
                        local ext_server=$(echo "$decoded" | cut -d':' -f1)
                        local ext_port=$(echo "$decoded" | cut -d':' -f2)
                        echo -e "${C}[$idx]${R} 外部代理: ${G}${ext_tag}${R} (${Y}${ext_type}://${ext_server}:${ext_port}${R})"
                    fi
                    nodes_list+=("EXT:${ext_type}:${ext_tag}")
                    ((idx++))
                fi
            done < /etc/sdn_nodes_registry.list
        fi

        if [ -f /etc/sdn_chains_registry.list ]; then
            while IFS=: read -r prefix chain_tag node1 node2; do
                if [ "$prefix" = "CHAIN" ]; then
                    echo -e "${C}[$idx]${R} 链式代理: ${G}${chain_tag}${R} (${Y}${node1} -> ${node2}${R})"
                    nodes_list+=("CHAIN:${chain_tag}")
                    ((idx++))
                fi
            done < /etc/sdn_chains_registry.list
        fi
        
        if [ ${#nodes_list[@]} -eq 0 ]; then
            echo -e "${Y}当前没有任何节点。${R}"
            echo -e "===================================================================="
            read -p "按回车键返回主菜单..."
            break
        fi

        echo -e "${G}====================================================================${R}"
        echo -e "输入序号查看对应节点 VLESS 链接"
        echo -e "输入 ${RED}d 序号${G} 删除节点 (例如 d 2)"
        echo -e "输入 0 返回主菜单"
        echo -e "===================================================================="
        read -p "操作: " input

        if [[ "$input" == "0" ]] || [ -z "$input" ]; then
            break
        elif [[ "$input" =~ ^d\ ([0-9]+)$ ]]; then
            local del_idx=${BASH_REMATCH[1]}
            if [ "$del_idx" -ge 1 ] && [ "$del_idx" -le "${#nodes_list[@]}" ]; then
                local target="${nodes_list[$((del_idx-1))]}"
                local type=$(echo "$target" | cut -d':' -f1)
                local tag=$(echo "$target" | cut -d':' -f3)
                [ "$type" != "EXT" ] && tag=$(echo "$target" | cut -d':' -f2)

                echo -e "${Y}正在删除节点: $tag ...${R}"
                
                (
                    flock -x 200
                    if [ "$type" = "NODE" ]; then
                        sed -i "/^NODE:${tag}:/d" /etc/sdn_nodes_registry.list
                        systemctl stop "udp2raw-${tag}.service" 2>/dev/null || true
                        systemctl disable "udp2raw-${tag}.service" 2>/dev/null || true
                        rm -f "/etc/systemd/system/udp2raw-${tag}.service"
                        systemctl daemon-reload
                        
                        awk -v t="$tag" '
                        BEGIN { skip=0 }
                        /^# Node: / {
                            if ($0 == "# Node: " t) { skip=1; next }
                        }
                        /^\[Peer\]/ { skip=0 }
                        !skip { print }
                        ' /etc/wireguard/wg0.conf > /tmp/wg0.conf.tmp && mv /tmp/wg0.conf.tmp /etc/wireguard/wg0.conf
                        
                        wg syncconf wg0 <(wg-quick strip wg0) 2>/dev/null || systemctl reload wg-quick@wg0 2>/dev/null || true

                    elif [ "$type" = "EXT" ]; then
                        sed -i "/^EXT:[^:]*:${tag}:/d" /etc/sdn_nodes_registry.list
                    elif [ "$type" = "CHAIN" ]; then
                        sed -i "/^CHAIN:${tag}:/d" /etc/sdn_chains_registry.list
                    fi
                    
                    rebuild_hk_sdn_matrix
                ) 200>/var/lock/sdn_registry.lock

                echo -e "${G}[√] 节点 $tag 已删除！${R}"
                sleep 1
            else
                echo -e "${RED}无效的序号！${R}"
                sleep 1
            fi
        elif [[ "$input" =~ ^[0-9]+$ ]]; then
            local view_idx=$input
            if [ "$view_idx" -ge 1 ] && [ "$view_idx" -le "${#nodes_list[@]}" ]; then
                local target="${nodes_list[$((view_idx-1))]}"
                local type=$(echo "$target" | cut -d':' -f1)
                local tag=$(echo "$target" | cut -d':' -f3)
                [ "$type" != "EXT" ] && tag=$(echo "$target" | cut -d':' -f2)
                
                echo -e "\n${H}=== VLESS 接入链接 ===${R}"
                if [ "$type" = "CHAIN" ]; then
                    echo -e "${C}vless://${UUID}@${HK_IP}:${CLIENT_PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=www.apple.com&sid=${SHORT_ID}#SDN-Chain-${tag}${R}"
                elif [ "$type" = "EXT" ]; then
                    echo -e "${C}vless://${UUID}@${HK_IP}:${CLIENT_PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=www.apple.com&sid=${SHORT_ID}#SDN-EXT-${tag}${R}"
                elif [ "$type" = "NODE" ]; then
                    echo -e "${C}vless://${UUID}@${HK_IP}:${CLIENT_PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=www.apple.com&sid=${SHORT_ID}#SDN-${tag}${R}"
                fi
                echo ""
                read -p "按回车键继续..."
            else
                echo -e "${RED}无效的序号！${R}"
                sleep 1
            fi
        else
            echo -e "${RED}输入无效！${R}"
            sleep 1
        fi
    done
}

setup_chain_proxy() {
    # 修复：使用安全的方式统计节点数量，防止 0\n0 错误
    local NODE_COUNT=$(grep -c "^NODE:" /etc/sdn_nodes_registry.list 2>/dev/null || true)
    NODE_COUNT=${NODE_COUNT:-0}

    if [ ! -f "/etc/sdn_nodes_registry.list" ] || [ "$NODE_COUNT" -lt 2 ]; then
        echo -e "${RED}[错误] 配置多级链式代理至少需要 2 个以上的内网落地节点！${R}"
        echo -e "${Y}[提示] 如果你只有1台落地机，请直接使用选项 5 导出单节点链接即可。${R}"
        return
    fi

    echo -e "\n${G}=== 可用的内网落地节点 ===${R}"
    grep "^NODE:" /etc/sdn_nodes_registry.list | cut -d':' -f2,3

    read -p "请输入前置跳板节点 Tag [例如 台湾]: " NODE1_TAG
    read -p "请输入最终出口节点 Tag [例如 日本]: " NODE2_TAG

    if [ "$NODE1_TAG" = "$NODE2_TAG" ]; then
        echo -e "${RED}[错误] 跳板节点和出口节点不能相同！${R}"
        return
    fi

    CHAIN_TAG="${NODE1_TAG}-to-${NODE2_TAG}"

    (
        flock -x 200
        sed -i "/^CHAIN:${CHAIN_TAG}:/d" /etc/sdn_chains_registry.list 2>/dev/null || true
        echo "CHAIN:${CHAIN_TAG}:${NODE1_TAG}:${NODE2_TAG}" >> /etc/sdn_chains_registry.list
        rebuild_hk_sdn_matrix
    ) 200>/var/lock/sdn_registry.lock

    echo -e "\n===================================================================="
    echo -e "${G}[√] 多级链式代理 [香港 -> $NODE1_TAG -> $NODE2_TAG] 构建完成！${R}"
    echo -e "===================================================================="
}

rebuild_hk_sdn_matrix() {
    local outbounds_json=""
    local tags_array=""

    if [ -f /etc/sdn_nodes_registry.list ]; then
        while IFS=: read -r prefix p1 p2 p3 p4 p5 p6; do
            if [ "$prefix" = "NODE" ]; then
                outbounds_json+="{ \"type\": \"socks\", \"tag\": \"out-$p1\", \"server\": \"$p2\", \"server_port\": 10808 },"
                tags_array+="\"out-$p1\","
            elif [ "$prefix" = "EXT" ]; then
                local ext_type="$p1"
                local ext_tag="$p2"
                local ext_payload="$p3"
                
                local json_entry=""
                if [[ "$ext_type" == "vless" || "$ext_type" == "hysteria2" || "$ext_type" == "trojan" ]]; then
                    local link=$(echo "$ext_payload" | base64 -d 2>/dev/null)
                    if [ -n "$link" ]; then
                        json_entry=$(parse_proxy_link "$link" "$ext_type" "$ext_tag")
                        if [ -n "$json_entry" ]; then
                            json_entry=$(echo "$json_entry" | jq -c . 2>/dev/null || echo "")
                        fi
                    fi
                else
                    local decoded=$(echo "$ext_payload" | base64 -d 2>/dev/null)
                    local ext_server=$(echo "$decoded" | cut -d':' -f1)
                    local ext_port=$(echo "$decoded" | cut -d':' -f2)
                    local ext_user=$(echo "$decoded" | cut -d':' -f3)
                    local ext_pass=$(echo "$decoded" | cut -d':' -f4-)
                    
                    if [ "$ext_user" = "-" ] || [ -z "$ext_user" ]; then
                        json_entry="{ \"type\": \"$ext_type\", \"tag\": \"out-ext-$ext_tag\", \"server\": \"$ext_server\", \"server_port\": $ext_port }"
                    else
                        json_entry="{ \"type\": \"$ext_type\", \"tag\": \"out-ext-$ext_tag\", \"server\": \"$ext_server\", \"server_port\": $ext_port, \"username\": \"$ext_user\", \"password\": \"$ext_pass\" }"
                    fi
                fi
                
                if [ -n "$json_entry" ]; then
                    outbounds_json+="${json_entry},"
                    tags_array+="\"out-ext-$ext_tag\","
                else
                    echo -e "${RED}[警告] 节点 $ext_tag 解析失败，已忽略。${R}"
                fi
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

    local urltest_tag="🚀 智能测速自动优选"
    local selector_tag="🎯 手动指定切换节点"
    
    local urltest_outbounds="$tags_array"
    if [ -z "$urltest_outbounds" ]; then
        urltest_outbounds="\"direct\""
    fi

    local selector_outbounds="\"${urltest_tag}\""
    if [ -n "$tags_array" ]; then
        selector_outbounds="\"${urltest_tag}\", $tags_array"
    fi

    if [ -z "$outbounds_json" ]; then
        outbounds_json="{ \"type\": \"direct\", \"tag\": \"direct\" }"
    else
        outbounds_json+=", { \"type\": \"direct\", \"tag\": \"direct\" }"
    fi

    local temp_conf="/tmp/sing-box_config.tmp"
    cat > "$temp_conf" <<EOF
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
      "tag": "${urltest_tag}",
      "outbounds": [ ${urltest_outbounds} ],
      "url": "https://www.gstatic.com/generate_204",
      "interval": "1m",
      "tolerance": 15
    },
    {
      "type": "selector",
      "tag": "${selector_tag}",
      "outbounds": [ ${selector_outbounds} ],
      "default": "${urltest_tag}"
    },
    $outbounds_json
  ],
  "route": {
    "rules": [{ "inbound": ["vless-in"], "outbound": "${selector_tag}" }]
  }
}
EOF

    if /usr/local/bin/sing-box check -c "$temp_conf" >/dev/null 2>&1; then
        cp "$temp_conf" /etc/sing-box/config.json
        rm -f "$temp_conf"
        systemctl restart sing-box
        sleep 2
        if ! systemctl is-active --quiet sing-box; then
            echo -e "${RED}[严重警告] Sing-Box 重启失败，可能是环境异常！请检查日志：journalctl -u sing-box -n 10${R}"
        fi
    else
        echo -e "${RED}[错误] 生成的配置文件语法校验失败！为防止断网，已放弃修改。${R}"
        echo -e "${Y}错误详情：${R}"
        /usr/local/bin/sing-box check -c "$temp_conf"
        rm -f "$temp_conf"
    fi
}

# ================= 彻底卸载与清理 =================
uninstall_all() {
    clear
    echo -e "${RED}====================================================================${R}"
    echo -e "${RED}              ⚠️ 危险操作：正在卸载所有网络组件              ⚠️${R}"
    echo -e "${RED}====================================================================${R}"
    echo -e "这将停止并删除以下内容："
    echo -e "  - Sing-box 服务及配置 (/etc/sing-box)"
    echo -e "  - WireGuard 服务及配置 (/etc/wireguard)"
    echo -e "  - 所有 udp2raw 相关服务"
    echo -e "  - 集群注册表与环境变量"
    echo -e "  - 已下载的 sing-box / udp2raw 二进制文件"
    echo -e "  - (可选) 卸载 XanMod 内核"
    echo -e "===================================================================="
    read -p "确定要彻底清理并卸载吗？(输入 y 继续): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${Y}已取消卸载。${R}"
        return
    fi

    echo -e "${Y}正在停止服务...${R}"
    systemctl stop sing-box 2>/dev/null || true
    systemctl stop wg-quick@wg0 2>/dev/null || true
    systemctl stop udp2raw*.service 2>/dev/null || true

    echo -e "${Y}正在移除开机启动项...${R}"
    systemctl disable sing-box 2>/dev/null || true
    systemctl disable wg-quick@wg0 2>/dev/null || true
    systemctl disable udp2raw*.service 2>/dev/null || true

    echo -e "${Y}正在删除 Systemd 服务文件...${R}"
    rm -f /etc/systemd/system/sing-box.service
    rm -f /etc/systemd/system/udp2raw*.service
    rm -rf /etc/systemd/system/wg-quick@wg0.service.d
    systemctl daemon-reload

    echo -e "${Y}正在清理配置与二进制文件...${R}"
    rm -rf /etc/sing-box
    rm -rf /etc/wireguard
    rm -f /etc/sdn_hk_cluster.env
    rm -f /etc/sdn_nodes_registry.list
    rm -f /etc/sdn_chains_registry.list
    rm -f /usr/local/bin/sing-box
    rm -f /usr/local/bin/udp2raw

    echo -e "${Y}正在清理系统内核调优参数...${R}"
    rm -f /etc/sysctl.d/99-sdn-ultimate.conf
    sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true

    echo -e "${G}====================================================================${R}"
    echo -e "${G}卸载完成！系统已恢复初始网络状态。${R}"
    echo -e "${G}====================================================================${R}"
    
    read -p "是否需要同时卸载 XanMod BBRv3 内核？(输入 y 继续): " uninstall_kernel
    if [[ "$uninstall_kernel" == "y" || "$uninstall_kernel" == "Y" ]]; then
        xanmod_uninstall
    fi
}

# 脚本主程序入口
check_root

while true; do
    clear
    CURRENT_BBR=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}' || echo "未检测")
    echo "===================================================================="
    echo "    跨境软件定义边缘网络 (集群管理面板 - 生产修复版)"
    echo -e "    当前内核拥塞控制算法: [ ${G}${CURRENT_BBR}${R} ]"
    echo "===================================================================="
    echo " 1. 【第一步：香港中转机】初始化总控中心"
    echo " 2. 【第二步：香港中转机】生成落地机对接凭证代码"
    echo " 3. 【第三步：落地机(动态/静态均可)】配置并加入集群"
    echo " 4. 【第四步：香港总控】输入落地机注册密文完成组网"
    echo " 5. 【香港总控】节点管理 (查看链接 / 删除节点)"
    echo " 6. 【香港总控】配置多级链式代理 (例如: 香港->台湾->日本)"
    echo " 7. 【系统工具】BBR / BBRv3 算法独立切换与内核管理 (含卸载)"
    echo " 8. 【香港总控】添加外部代理 (支持 HTTP/SOCKS5/VLESS/Hysteria2/Trojan 链接导入)"
    echo " 9. 【系统工具】一键卸载所有组件与配置 (彻底清理)"
    echo " 0. 退出脚本"
    echo "===================================================================="
    read -p "请选择对应操作的数字 [0-9]: " choice

    choice=$(echo "$choice" | tr -d '[:space:]')

    case $choice in
        1) setup_hk_master; read -p "按回车键继续..." ;;
        2) export_token; read -p "按回车键继续..." ;;
        3) setup_landing_node; read -p "按回车键继续..." ;;
        4) register_node_to_hk; read -p "按回车键继续..." ;;
        5) manage_nodes ;;
        6) setup_chain_proxy; read -p "按回车键继续..." ;;
        7) manage_bbr ;;
        8) setup_external_proxy; read -p "按回车键继续..." ;;
        9) uninstall_all; read -p "按回车键继续..." ;;
        0) exit 0 ;;
        *) echo -e "${RED}[错误] 输入无效，请重新选择。${R}"; sleep 2 ;;
    esac
done
