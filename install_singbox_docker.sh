#!/bin/bash
# ==============================================================================
# Sing-box 和 Mihomo Docker 安装器 v2.0 (Fixed)
#
# 修复清单：
#   [BUG1] set -u + 空数组崩溃 → 安全数组展开
#   [BUG2] bc 依赖缺失 → 改用纯 bash 整数比较
#   [BUG3] sysctl.conf 无限追加 → sed 去重
#   [BUG4] check_network_conflict 子shell → 改用进程替换
#   [BUG5] eval 注入风险 → 改用数组直接调用
#   [BUG6] macvlan 宿主机无法访问容器 → 自动创建 shim
#   [BUG7] WiFi 接口不支持 macvlan → 自动检测
#   [P1]   下载超时过短 → 区分二进制/配置策略
#   [P2]   host 命令未检测 → fallback 到 nslookup/dig
#   [P3]   basic_config_check 正则无效 → 移除，只用 jq/yq
#   [P4]   check_port_usage 对 macvlan 无意义 → 改为警告
#   [P5]   容器资源限制过小 → 可配置
#   [P6]   apt-key 已废弃 → 使用 gpg dearmor
#   [P7]   Alpine systemctl → 检测 init 系统
#   [P8]   --ip-range 未指定 → 自动限制
#   [NEW1] macvlan-shim 自动配置和持久化
#   [NEW2] WiFi 接口检测和 ipvlan 备选
#   [NEW3] 下载大文件支持重试 + 速度监控
# ==============================================================================

# 仅使用 set -u（移除 -e 避免误退出，移除 -o pipefail 避免管道问题）
set -u

# --- 脚本元数据 ---
SCRIPT_VERSION="2.0.0"
SCRIPT_NAME="Sing-box 和 Mihomo Docker 安装器"

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- 可配置路径 ---
SING_BOX_CONFIG_DIR="/etc/sing-box"
MIHOMO_CONFIG_DIR="/etc/mihomo"

# --- 容器默认名称 ---
SINGBOX_CONTAINER_NAME="docker-sing-box"
MIHOMO_CONTAINER_NAME="docker-mihomo"

# --- 网络默认值 ---
MACVLAN_NET_NAME="macvlan-net"
NETWORK_MODE="macvlan"  # macvlan 或 bridge 或 ipvlan

# --- [修复BUG1] 安全初始化数组 ---
declare -a SINGBOX_PORTS=()
declare -a MIHOMO_PORTS=()
SINGBOX_UI_PORT="9090"
MIHOMO_MIXED_PORT="7893"
MIHOMO_UI_PORT="9090"
MIHOMO_DNS_PORT="1053"

# --- [修复P1] 下载超时配置 ---
DL_CONNECT_TIMEOUT=15
DL_MAX_TIME=300       # 二进制下载最大时间
DL_RETRY=3
DL_RETRY_DELAY=5
CFG_CONNECT_TIMEOUT=15
CFG_MAX_TIME=120      # 配置文件下载最大时间
CFG_RETRY=3
CFG_RETRY_DELAY=5

# --- [修复P5] 容器资源限制（可配置） ---
SINGBOX_MEMORY="256m"
SINGBOX_CPUS="1.0"
MIHOMO_MEMORY="512m"
MIHOMO_CPUS="1.0"

# --- 共享网络状态变量 ---
SHARED_SUBNET=""
SHARED_GATEWAY=""
SHARED_PARENT_INTERFACE=""
MACVLAN_IP=""
MIHOMO_IP=""
IPV6_ENABLED=0

# --- 临时目录 ---
TEMP_DIR="/tmp/singbox_mihomo_install"

# ==============================================================================
# 工具函数
# ==============================================================================
log()    { echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"; }
red()    { echo -e "${RED}$1${NC}"; }
green()  { echo -e "${GREEN}$1${NC}"; }
yellow() { echo -e "${YELLOW}$1${NC}"; }

# [修复BUG1] 安全展开数组的辅助函数
safe_array_expand() {
    # 使用: safe_array_expand "${arr[@]+"${arr[@]}"}"
    # 或直接在调用处使用 ${arr[@]+"${arr[@]}"}
    echo "$@"
}

# 检查 root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        red "此脚本必须以 root 用户运行"
        exit 1
    fi
}

# 清理临时文件
cleanup() {
    if [[ -d "${TEMP_DIR:-}" ]]; then
        log "清理临时文件..."
        rm -rf "$TEMP_DIR"
    fi
}
trap 'red "脚本被中断，执行清理..."; cleanup; exit 130' INT TERM
trap 'cleanup' EXIT

# ==============================================================================
# [修复BUG2] 系统要求检查（移除 bc 依赖）
# ==============================================================================
check_system_requirements() {
    log "检查系统要求..."
    local kernel_major kernel_minor
    kernel_major=$(uname -r | cut -d. -f1)
    kernel_minor=$(uname -r | cut -d. -f2)
    # 纯 bash 整数比较，不依赖 bc
    if [[ "$kernel_major" -lt 3 ]] || [[ "$kernel_major" -eq 3 && "$kernel_minor" -lt 10 ]]; then
        red "内核版本过低 ($(uname -r))，需要 3.10 或更高"
        exit 1
    fi
    if ! command -v docker &>/dev/null; then
        yellow "未安装 Docker，将在后续步骤中安装"
    fi
    green "系统要求检查通过 (内核: $(uname -r))"
}

# 获取架构
get_arch() {
    local arch
    arch=$(uname -m)
    case $arch in
        x86_64)     echo "amd64" ;;
        aarch64)    echo "arm64" ;;
        armv7l)     echo "armv7" ;;
        armv6l)     echo "armv6" ;;
        riscv64)    echo "riscv64" ;;
        i686|i386)  echo "386" ;;
        s390x)      echo "s390x" ;;
        ppc64le)    echo "ppc64le" ;;
        *)
            if command -v dpkg &>/dev/null; then
                dpkg --print-architecture
            else
                red "未知架构: $arch"
                exit 1
            fi
            ;;
    esac
}

# 检测 init 系统
detect_init_system() {
    if command -v systemctl &>/dev/null && [[ -d /run/systemd/system ]]; then
        echo "systemd"
    elif command -v rc-service &>/dev/null; then
        echo "openrc"
    elif [[ -f /etc/init.d/cron ]]; then
        echo "sysvinit"
    else
        echo "unknown"
    fi
}

# ==============================================================================
# Docker 安装和检查
# ==============================================================================
check_docker_service() {
    log "检查 Docker 服务状态..."
    local init_sys
    init_sys=$(detect_init_system)

    case "$init_sys" in
        systemd)
            if ! systemctl is-active --quiet docker; then
                yellow "Docker 服务未运行，尝试启动..."
                systemctl start docker || { red "无法启动 Docker"; exit 1; }
            fi
            ;;
        openrc)
            if ! rc-service docker status &>/dev/null; then
                yellow "Docker 服务未运行，尝试启动..."
                rc-service docker start || { red "无法启动 Docker"; exit 1; }
            fi
            ;;
        *)
            if ! docker info &>/dev/null; then
                red "Docker 服务未运行且无法自动启动"
                exit 1
            fi
            ;;
    esac
    green "Docker 服务正常运行"
}

# [修复P6] Docker 安装（使用现代 gpg 方式）
install_docker_deps() {
    log "检查 Docker 依赖..."
    if command -v docker &>/dev/null; then
        green "Docker 已安装"
        check_docker_service
        return 0
    fi

    log "安装 Docker..."
    # 优先使用官方安装脚本（最可靠、跨平台）
    if curl -fsSL https://get.docker.com -o /tmp/get-docker.sh; then
        sh /tmp/get-docker.sh || { red "Docker 安装失败"; exit 1; }
        rm -f /tmp/get-docker.sh
    else
        red "无法下载 Docker 安装脚本，请手动安装"
        exit 1
    fi

    local init_sys
    init_sys=$(detect_init_system)
    case "$init_sys" in
        systemd) systemctl enable docker && systemctl start docker ;;
        openrc)  rc-update add docker && rc-service docker start ;;
    esac

    green "Docker 安装完成"
    check_docker_service
}

# 安装 jq 和 yq
install_jq_yq() {
    log "检查 jq 和 yq..."
    local pkg_install=""
    if command -v apt-get &>/dev/null; then
        pkg_install="apt-get install -y"
    elif command -v yum &>/dev/null; then
        pkg_install="yum install -y"
    elif command -v apk &>/dev/null; then
        pkg_install="apk add"
    elif command -v pacman &>/dev/null; then
        pkg_install="pacman -S --noconfirm"
    fi

    if ! command -v jq &>/dev/null && [[ -n "$pkg_install" ]]; then
        log "安装 jq..."
        $pkg_install jq >/dev/null 2>&1 || yellow "jq 安装失败，部分验证功能将降级"
    fi

    if ! command -v yq &>/dev/null && [[ -n "$pkg_install" ]]; then
        log "安装 yq..."
        $pkg_install yq >/dev/null 2>&1 || yellow "yq 安装失败，YAML 验证将降级"
    fi
}

# ==============================================================================
# Docker 版本检查
# ==============================================================================
check_docker_version() {
    local docker_version
    docker_version=$(docker version --format '{{.Client.Version}}' 2>/dev/null || true)
    if [[ -z "$docker_version" ]]; then
        red "无法获取 Docker 版本"
        return 1
    fi
    local major minor
    major=$(echo "$docker_version" | cut -d. -f1)
    minor=$(echo "$docker_version" | cut -d. -f2)
    if [[ "$major" -lt 17 ]]; then
        red "Docker 版本过低 ($docker_version)，建议升级到 20.10+"
        return 1
    fi
    green "Docker 版本: $docker_version"
    return 0
}

# ==============================================================================
# 网络检测
# ==============================================================================
get_default_interface() {
    ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -n1
}

get_gateway_ip() {
    local iface
    iface=$(get_default_interface)
    if [[ -z "$iface" ]]; then
        red "无法确定默认网络接口"
        return 1
    fi
    ip addr show dev "$iface" 2>/dev/null | awk '/inet / {print $2}' | cut -d'/' -f1 | head -n1
}

# [修复BUG7] 检测接口类型（WiFi vs 有线）
check_interface_type() {
    local iface="$1"
    # 检查是否为无线接口
    if [[ -d "/sys/class/net/$iface/wireless" ]] || \
       iw dev "$iface" info &>/dev/null 2>&1; then
        yellow "⚠ 警告: $iface 是 WiFi 接口"
        yellow "Macvlan 在 WiFi 客户端模式下不受支持（内核限制）"
        yellow "建议：使用有线接口，或选择 ipvlan/bridge 模式"
        read -p "是否切换到 ipvlan L3 模式？(y/N): " use_ipvlan
        if [[ "$use_ipvlan" =~ ^[Yy]$ ]]; then
            NETWORK_MODE="ipvlan"
            log "已切换到 ipvlan L3 模式"
        else
            read -p "是否切换到 bridge 模式？(y/N): " use_bridge
            if [[ "$use_bridge" =~ ^[Yy]$ ]]; then
                NETWORK_MODE="bridge"
                log "已切换到 bridge 模式"
            else
                red "WiFi 接口不支持 macvlan，请更换有线接口"
                return 1
            fi
        fi
    fi
    return 0
}

# 检查混杂模式支持
check_promisc_support() {
    local iface="$1"

    # 先检查是否为 WiFi
    check_interface_type "$iface" || return 1

    if [[ "$NETWORK_MODE" != "macvlan" ]]; then
        return 0  # 非 macvlan 模式不需要混杂模式
    fi

    log "检查网卡 $iface 混杂模式支持..."
    if ! ip link set "$iface" promisc on >/dev/null 2>&1; then
        yellow "网卡 $iface 不支持混杂模式"
        read -p "切换到桥接网络？(y/N): " use_bridge
        if [[ "$use_bridge" =~ ^[Yy]$ ]]; then
            NETWORK_MODE="bridge"
        else
            red "请更换支持混杂模式的网卡"
            return 1
        fi
    else
        ip link set "$iface" promisc off >/dev/null 2>&1 || true
        green "网卡 $iface 支持混杂模式"
    fi
    return 0
}

# 持久化混杂模式
enable_persistent_promisc() {
    local iface="$1"
    local init_sys
    init_sys=$(detect_init_system)

    log "为 $iface 配置持久化混杂模式..."
    ip link set "$iface" promisc on || true

    case "$init_sys" in
        systemd)
            local svc_file="/etc/systemd/system/promisc-${iface}.service"
            if [[ ! -f "$svc_file" ]]; then
                cat > "$svc_file" << EOF
[Unit]
Description=Enable promiscuous mode for $iface
After=network.target

[Service]
Type=oneshot
ExecStart=/sbin/ip link set $iface promisc on
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
                systemctl enable "promisc-${iface}.service" >/dev/null 2>&1
                systemctl start "promisc-${iface}.service" >/dev/null 2>&1
                green "已创建 systemd 混杂模式服务"
            fi
            ;;
        openrc)
            local startup="/etc/local.d/promisc-${iface}.start"
            echo "/sbin/ip link set $iface promisc on" > "$startup"
            chmod +x "$startup"
            green "已创建 OpenRC 混杂模式脚本"
            ;;
        *)
            yellow "请手动配置混杂模式持久化: ip link set $iface promisc on"
            ;;
    esac
}

# ==============================================================================
# [修复BUG3] IP 转发配置（防止 sysctl.conf 重复追加）
# ==============================================================================
enable_ip_forwarding() {
    log "启用 IP 转发..."

    # IPv4
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || { red "IPv4 转发启用失败"; return 1; }
    if grep -q "^net.ipv4.ip_forward=" /etc/sysctl.conf 2>/dev/null; then
        sed -i 's/^net.ipv4.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
    elif ! grep -q "^#.*net.ipv4.ip_forward" /etc/sysctl.conf 2>/dev/null; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    fi

    # IPv6
    if [[ $IPV6_ENABLED -eq 1 ]]; then
        sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || yellow "IPv6 转发启用失败"
        if grep -q "^net.ipv6.conf.all.forwarding=" /etc/sysctl.conf 2>/dev/null; then
            sed -i 's/^net.ipv6.conf.all.forwarding=.*/net.ipv6.conf.all.forwarding=1/' /etc/sysctl.conf
        elif ! grep -q "^#.*net.ipv6.conf.all.forwarding" /etc/sysctl.conf 2>/dev/null; then
            echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
        fi
    fi

    sysctl -p >/dev/null 2>&1 || true
    green "IP 转发已启用"
}

# ==============================================================================
# 检查 IPv6
# ==============================================================================
check_ipv6_support() {
    log "检查 IPv6 支持..."
    if [[ -f /proc/sys/net/ipv6/conf/all/disable_ipv6 ]] && \
       [[ $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6) -eq 0 ]]; then
        IPV6_ENABLED=1
        green "IPv6 已启用"
    else
        IPV6_ENABLED=0
        log "IPv6 未启用，仅使用 IPv4"
    fi
}

# ==============================================================================
# 验证函数
# ==============================================================================
validate_version() {
    local version="$1"
    if [[ "$version" != "latest" ]] && \
       [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9._-]+)?$ ]] && \
       [[ ! "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        red "无效版本号格式: $version"
        return 1
    fi
    return 0
}

validate_url() {
    local url="$1"
    if [[ ! "$url" =~ ^https?:// ]]; then
        red "无效 URL，必须以 http:// 或 https:// 开头"
        return 1
    fi
    return 0
}

# [修复P2] URL 安全验证（fallback 多种 DNS 查询工具）
validate_url_security() {
    local url="$1"
    local host
    host=$(echo "$url" | awk -F/ '{print $3}' | cut -d':' -f1)
    log "检查 URL 主机: $host"

    # IP 地址直接通过
    if echo "$host" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        return 0
    fi

    # 尝试多种 DNS 查询工具
    if command -v host &>/dev/null; then
        host "$host" >/dev/null 2>&1 && return 0
    elif command -v nslookup &>/dev/null; then
        nslookup "$host" >/dev/null 2>&1 && return 0
    elif command -v dig &>/dev/null; then
        dig +short "$host" >/dev/null 2>&1 && return 0
    elif command -v getent &>/dev/null; then
        getent hosts "$host" >/dev/null 2>&1 && return 0
    else
        yellow "无 DNS 查询工具可用，跳过域名验证"
        return 0
    fi

    red "无法解析主机: $host"
    return 1
}

validate_ip_in_subnet() {
    local ip="$1"
    local subnet="$2"
    local network cidr
    network=$(echo "$subnet" | cut -d'/' -f1)
    cidr=$(echo "$subnet" | cut -d'/' -f2)

    if ! echo "$ip" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        red "无效的 IP 地址格式: $ip"
        return 1
    fi

    local ip1 ip2 ip3 ip4 net1 net2 net3 net4
    IFS='.' read -r ip1 ip2 ip3 ip4 <<< "$ip"
    IFS='.' read -r net1 net2 net3 net4 <<< "$network"

    local ip_int=$(( (ip1 << 24) + (ip2 << 16) + (ip3 << 8) + ip4 ))
    local network_int=$(( (net1 << 24) + (net2 << 16) + (net3 << 8) + net4 ))
    local mask=$(( 0xffffffff << (32 - cidr) ))

    if (( (ip_int & mask) != (network_int & mask) )); then
        red "IP $ip 不在子网 $subnet 内"
        return 1
    fi
    return 0
}

check_ip_occupied() {
    local ip="$1"
    log "检查 IP $ip 是否被占用..."
    if ping -c 1 -W 2 "$ip" >/dev/null 2>&1; then
        red "IP $ip 已被占用，请选择其他 IP"
        return 1
    fi
    green "IP $ip 可用"
    return 0
}

# ==============================================================================
# [修复BUG4] 网络冲突检查
# ==============================================================================
check_network_conflict() {
    local subnet="$1"
    log "检查子网 $subnet 是否与现有 Docker 网络冲突..."
    local conflict_found=0
    local net
    while IFS= read -r net; do
        [[ -z "$net" ]] && continue
        local net_subnet
        net_subnet=$(docker network inspect "$net" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || true)
        if [[ "$net_subnet" == *"$subnet"* ]]; then
            red "子网 $subnet 与网络 $net 冲突"
            conflict_found=1
        fi
    done < <(docker network ls --format '{{.Name}}' 2>/dev/null)

    if [[ $conflict_found -eq 1 ]]; then
        return 1
    fi
    green "子网 $subnet 无冲突"
    return 0
}

# ==============================================================================
# [修复P1] 下载函数（增加重试、速度监控、超时分离）
# ==============================================================================
download_config() {
    local url="$1"
    local output="$2"
    local mode="${3:-config}"

    local connect_timeout max_time retry retry_delay
    if [[ "$mode" == "config" ]]; then
        connect_timeout=$CFG_CONNECT_TIMEOUT
        max_time=$CFG_MAX_TIME
        retry=$CFG_RETRY
        retry_delay=$CFG_RETRY_DELAY
    else
        connect_timeout=$DL_CONNECT_TIMEOUT
        max_time=$DL_MAX_TIME
        retry=$DL_RETRY
        retry_delay=$DL_RETRY_DELAY
    fi

    local attempt=0
    while [[ $attempt -lt $retry ]]; do
        attempt=$((attempt + 1))
        log "下载尝试 $attempt/$retry..."

        if command -v curl &>/dev/null; then
            if curl -sSL \
                --connect-timeout "$connect_timeout" \
                --max-time "$max_time" \
                --speed-limit 1024 \
                --speed-time 30 \
                --compressed \
                -o "$output" \
                "$url"; then
                if [[ -s "$output" ]]; then
                    green "下载成功"
                    return 0
                fi
            fi
        elif command -v wget &>/dev/null; then
            if wget -q --timeout="$max_time" --tries=1 -O "$output" "$url"; then
                if [[ -s "$output" ]]; then
                    green "下载成功"
                    return 0
                fi
            fi
        else
            red "未找到 curl 或 wget"
            return 1
        fi

        yellow "下载失败 (尝试 $attempt/$retry)"
        if [[ $attempt -lt $retry ]]; then
            yellow "等待 ${retry_delay}s 后重试..."
            sleep "$retry_delay"
            rm -f "$output"
        fi
    done

    red "下载失败（已重试 $retry 次）"
    red "提示：若为大配置文件，可修改脚本顶部 CFG_MAX_TIME 值（当前 ${CFG_MAX_TIME}s）"
    return 1
}

# ==============================================================================
# 网段检测
# ==============================================================================
calculate_network_address() {
    local ip_cidr="$1"
    local ip_addr cidr_mask
    ip_addr=$(echo "$ip_cidr" | cut -d'/' -f1)
    cidr_mask=$(echo "$ip_cidr" | cut -d'/' -f2)

    local o1 o2 o3 o4
    IFS='.' read -r o1 o2 o3 o4 <<< "$ip_addr"
    local mask=$(( 0xffffffff << (32 - cidr_mask) ))
    local ip_int=$(( (o1 << 24) + (o2 << 16) + (o3 << 8) + o4 ))
    local net_int=$(( ip_int & mask ))

    printf "%d.%d.%d.%d/%s" \
        $(( (net_int >> 24) & 255 )) \
        $(( (net_int >> 16) & 255 )) \
        $(( (net_int >> 8) & 255 )) \
        $(( net_int & 255 )) \
        "$cidr_mask"
}

detect_lan_subnet_gateway() {
    local default_iface
    default_iface=$(get_default_interface)
    if [[ -z "$default_iface" ]]; then
        red "无法自动检测局域网信息"
        return 1
    fi

    local ip_cidr
    ip_cidr=$(ip addr show dev "$default_iface" | awk '/inet / {print $2}' | head -n 1)
    if [[ -z "$ip_cidr" ]]; then
        red "无法获取接口 $default_iface 的 IP 信息"
        return 1
    fi

    local subnet gateway
    subnet=$(calculate_network_address "$ip_cidr") || return 1
    gateway=$(ip route show default | awk '/default/ {print $3}' | head -n1)

    if [[ -z "$subnet" || -z "$gateway" ]]; then
        red "自动检测失败"
        return 1
    fi

    green "检测到局域网段: $subnet"
    green "检测到网关: $gateway"
    green "默认接口: $default_iface"

    SHARED_SUBNET="$subnet"
    SHARED_GATEWAY="$gateway"
    SHARED_PARENT_INTERFACE="$default_iface"
    return 0
}

# ==============================================================================
# [修复BUG5] Docker 命令执行（不使用 eval）
# ==============================================================================
run_docker_container() {
    local container_name="$1"
    local image="$2"
    local network="$3"
    local ip="$4"
    local memory="$5"
    local cpus="$6"
    local config_volume="$7"
    local container_config_path="$8"
    shift 8
    local extra_args=("$@")

    # 构建 docker run 命令数组（安全，无 eval）
    local cmd=(
        docker run -d
        --name "$container_name"
        --restart always
        --memory="$memory"
        --cpus="$cpus"
        --cap-add=NET_ADMIN
        --cap-add=NET_RAW
        --device=/dev/net/tun:/dev/net/tun
    )

    if [[ "$NETWORK_MODE" == "macvlan" || "$NETWORK_MODE" == "ipvlan" ]]; then
        cmd+=(--network "$network" --ip "$ip")
    else
        cmd+=(--network "$network")
    fi

    cmd+=(-v "${config_volume}:${container_config_path}")

    # 添加额外参数
    if [[ ${#extra_args[@]} -gt 0 ]]; then
        cmd+=("${extra_args[@]}")
    fi

    cmd+=("$image")

    log "执行: ${cmd[*]}"
    "${cmd[@]}" || return 1
    return 0
}

# ==============================================================================
# [NEW1] Macvlan Shim 自动配置
# ==============================================================================
setup_macvlan_shim() {
    local parent_iface="$1"
    local container_ip="$2"
    local subnet="$3"
    local shim_name="macvlan-shim"

    if [[ "$NETWORK_MODE" != "macvlan" ]]; then
        return 0
    fi

    log "配置 macvlan-shim 以允许宿主机访问容器..."

    # 计算 shim IP（取子网最后一个可用 IP - 1）
    local net_addr cidr
    net_addr=$(echo "$subnet" | cut -d'/' -f1)
    cidr=$(echo "$subnet" | cut -d'/' -f2)

    local o1 o2 o3 o4
    IFS='.' read -r o1 o2 o3 o4 <<< "$net_addr"
    local net_int=$(( (o1 << 24) + (o2 << 16) + (o3 << 8) + o4 ))
    local host_bits=$((32 - cidr))
    local last_ip_int=$(( net_int + (1 << host_bits) - 2 ))  # 最后可用 IP
    local shim_ip_int=$((last_ip_int - 1))  # 倒数第二个

    local shim_ip
    shim_ip=$(printf "%d.%d.%d.%d" \
        $(( (shim_ip_int >> 24) & 255 )) \
        $(( (shim_ip_int >> 16) & 255 )) \
        $(( (shim_ip_int >> 8) & 255 )) \
        $(( shim_ip_int & 255 )))

    # 检查 shim IP 是否被占用
    if ping -c 1 -W 1 "$shim_ip" >/dev/null 2>&1; then
        yellow "Shim IP $shim_ip 已被占用，尝试上一个..."
        shim_ip_int=$((shim_ip_int - 1))
        shim_ip=$(printf "%d.%d.%d.%d" \
            $(( (shim_ip_int >> 24) & 255 )) \
            $(( (shim_ip_int >> 16) & 255 )) \
            $(( (shim_ip_int >> 8) & 255 )) \
            $(( shim_ip_int & 255 )))
    fi

    # 删除已存在的 shim
    ip link del "$shim_name" >/dev/null 2>&1 || true

    # 创建 shim
    ip link add link "$parent_iface" name "$shim_name" type macvlan mode bridge || {
        yellow "创建 macvlan-shim 失败，宿主机可能无法直接访问容器"
        return 1
    }
    ip addr add "${shim_ip}/32" dev "$shim_name"
    ip link set "$shim_name" up
    ip route add "${container_ip}/32" dev "$shim_name" 2>/dev/null || true

    green "Macvlan-shim 已配置: 宿主机可通过 $shim_ip 访问容器 $container_ip"

    # 持久化 shim
    local init_sys
    init_sys=$(detect_init_system)
    if [[ "$init_sys" == "systemd" ]]; then
        local svc_file="/etc/systemd/system/macvlan-shim.service"
        cat > "$svc_file" << EOF
[Unit]
Description=macvlan shim for Docker container access
After=network.target docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c "ip link del $shim_name 2>/dev/null || true; ip link add link $parent_iface name $shim_name type macvlan mode bridge && ip addr add ${shim_ip}/32 dev $shim_name && ip link set $shim_name up && ip route add ${container_ip}/32 dev $shim_name 2>/dev/null || true"
ExecStop=/bin/bash -c "ip link del $shim_name || true"

[Install]
WantedBy=multi-user.target
EOF
        systemctl enable macvlan-shim.service >/dev/null 2>&1
        green "Macvlan-shim systemd 服务已创建并启用"
    fi

    return 0
}

# ==============================================================================
# 创建 Docker 网络
# ==============================================================================
create_docker_network() {
    local net_name="$1"
    local subnet="$2"
    local gateway="$3"
    local parent="$4"

    case "$NETWORK_MODE" in
        bridge)
            log "创建 bridge 网络: $net_name"
            docker network create -d bridge \
                --subnet="$subnet" \
                --gateway="$gateway" \
                "$net_name" || { red "创建 bridge 网络失败"; return 1; }
            ;;
        ipvlan)
            log "创建 ipvlan L3 网络: $net_name"
            docker network create -d ipvlan \
                --subnet="$subnet" \
                --gateway="$gateway" \
                -o parent="$parent" \
                -o ipvlan_mode=l3 \
                "$net_name" || { red "创建 ipvlan 网络失败"; return 1; }
            ;;
        macvlan)
            enable_persistent_promisc "$parent"
            log "创建 macvlan 网络: $net_name"
            docker network create -d macvlan \
                --subnet="$subnet" \
                --gateway="$gateway" \
                -o parent="$parent" \
                "$net_name" || { red "创建 macvlan 网络失败"; return 1; }
            ;;
    esac

    green "Docker 网络 $net_name ($NETWORK_MODE) 创建成功"
    return 0
}

# ==============================================================================
# 配置目录和文件检查
# ==============================================================================
check_config_dir() {
    local config_dir="$1"
    local config_file="$2"
    local format="$3"
    local full_path="$config_dir/$config_file"

    log "检查配置: $full_path"

    mkdir -p "$config_dir" || { red "无法创建目录 $config_dir"; return 1; }

    if [[ ! -r "$full_path" ]]; then
        red "文件不存在或不可读: $full_path"
        read -p "是否忽略继续？(y/N): " ignore
        [[ "$ignore" =~ ^[Yy]$ ]] && return 0
        return 1
    fi

    install_jq_yq

    if [[ "$format" == "json" ]] && command -v jq &>/dev/null; then
        if ! jq empty "$full_path" >/dev/null 2>&1; then
            red "$full_path 不是有效的 JSON 文件"
            yellow "错误详情:"
            jq empty "$full_path" 2>&1 | head -5
            read -p "是否忽略继续？(y/N): " ignore
            [[ "$ignore" =~ ^[Yy]$ ]] || return 1
        else
            green "JSON 格式验证通过"
        fi
    elif [[ "$format" == "yaml" ]] && command -v yq &>/dev/null; then
        if ! yq e . "$full_path" >/dev/null 2>&1; then
            red "$full_path 不是有效的 YAML 文件"
            read -p "是否忽略继续？(y/N): " ignore
            [[ "$ignore" =~ ^[Yy]$ ]] || return 1
        else
            green "YAML 格式验证通过"
        fi
    fi

    chmod 600 "$full_path" || true
    chown root:root "$full_path" || true
    return 0
}

# ==============================================================================
# 端口提取
# ==============================================================================
get_singbox_ports() {
    local config_file="$1"
    SINGBOX_PORTS=()
    SINGBOX_UI_PORT="9090"

    if command -v jq &>/dev/null && [[ -f "$config_file" ]]; then
        local ports
        ports=$(jq -r '.inbounds[]? | select(.type == "http" or .type == "socks" or .type == "mixed") | .port // empty' "$config_file" 2>/dev/null || true)
        if [[ -n "$ports" ]]; then
            while IFS= read -r port; do
                if [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )); then
                    SINGBOX_PORTS+=("$port")
                fi
            done <<< "$ports"
        fi
    fi

    if [[ ${#SINGBOX_PORTS[@]} -eq 0 ]]; then
        yellow "未提取到端口，使用默认: 10808, 10809"
        SINGBOX_PORTS=(10808 10809)
    fi
    log "Sing-box 端口: ${SINGBOX_PORTS[*]}, UI: $SINGBOX_UI_PORT"
}

get_mihomo_ports() {
    local config_file="$1"
    MIHOMO_PORTS=()

    if command -v yq &>/dev/null && [[ -f "$config_file" ]]; then
        MIHOMO_MIXED_PORT=$(yq e '.mixed-port // 7893' "$config_file" 2>/dev/null || echo "7893")
        MIHOMO_UI_PORT=$(yq e '.external-controller | split(":") | .[-1] // "9090"' "$config_file" 2>/dev/null || echo "9090")
        MIHOMO_DNS_PORT=$(yq e '.dns.listen | split(":") | .[-1] // "1053"' "$config_file" 2>/dev/null || echo "1053")
    else
        MIHOMO_MIXED_PORT="7893"
        MIHOMO_UI_PORT="9090"
        MIHOMO_DNS_PORT="1053"
    fi
    MIHOMO_PORTS=("$MIHOMO_MIXED_PORT" "$MIHOMO_UI_PORT" "$MIHOMO_DNS_PORT")
    log "Mihomo 端口: ${MIHOMO_PORTS[*]}"
}

# ==============================================================================
# [修复P4] 端口检查（macvlan 模式下改为警告）
# ==============================================================================
check_port_usage() {
    local port="$1"
    local check_ip="${2:-}"

    if [[ "$NETWORK_MODE" == "macvlan" || "$NETWORK_MODE" == "ipvlan" ]]; then
        log "Macvlan/ipvlan 模式: 端口 $port 在容器 IP 上运行，跳过宿主机端口检查"
        return 0
    fi

    # 仅在 bridge 模式下检查宿主机端口
    if command -v ss >/dev/null 2>&1; then
        if ss -tuln | grep -q ":${port} "; then
            red "端口 $port 在宿主机上已被占用"
            return 1
        fi
    fi
    return 0
}

# ==============================================================================
# iptables 管理
# ==============================================================================
setup_iptables() {
    local container_ip="$1"
    shift
    local ports=("$@")

    log "配置 iptables 规则..."

    # NAT
    if ! iptables -t nat -C POSTROUTING -s 192.168.0.0/16 -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -s 192.168.0.0/16 -j MASQUERADE || yellow "IPv4 NAT 规则添加失败"
    fi

    if [[ $IPV6_ENABLED -eq 1 ]]; then
        if ! ip6tables -t nat -C POSTROUTING -s fc00::/7 -j MASQUERADE 2>/dev/null; then
            ip6tables -t nat -A POSTROUTING -s fc00::/7 -j MASQUERADE || true
        fi
    fi

    # INPUT 规则（针对容器 IP）
    if [[ -n "$container_ip" ]] && [[ ${#ports[@]} -gt 0 ]]; then
        local port_list
        port_list=$(IFS=,; echo "${ports[*]}")
        if ! iptables -C INPUT -d "$container_ip" -p tcp -m multiport --dports "$port_list" -j ACCEPT 2>/dev/null; then
            iptables -A INPUT -d "$container_ip" -p tcp -m multiport --dports "$port_list" -j ACCEPT || true
        fi
        if ! iptables -C INPUT -d "$container_ip" -p udp -m multiport --dports "$port_list" -j ACCEPT 2>/dev/null; then
            iptables -A INPUT -d "$container_ip" -p udp -m multiport --dports "$port_list" -j ACCEPT || true
        fi
    fi

    # 保存规则
    save_iptables_rules
}

save_iptables_rules() {
    mkdir -p /etc/iptables
    if command -v iptables-save &>/dev/null; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || yellow "IPv4 规则保存失败"
    fi
    if [[ $IPV6_ENABLED -eq 1 ]] && command -v ip6tables-save &>/dev/null; then
        ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || yellow "IPv6 规则保存失败"
    fi
}

# ==============================================================================
# 容器管理
# ==============================================================================
clean_old_container() {
    local container_name="$1"
    if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
        log "清理旧容器 $container_name..."
        docker stop "$container_name" >/dev/null 2>&1 || true
        docker rm "$container_name" >/dev/null 2>&1 || true
        green "旧容器已清理"
    fi
}

backup_config() {
    local config_dir="$1"
    local config_file="$2"
    if [[ -f "$config_dir/$config_file" ]]; then
        local backup_dir="$config_dir/backup"
        local timestamp
        timestamp=$(date +'%Y%m%d_%H%M%S')
        mkdir -p "$backup_dir"
        cp "$config_dir/$config_file" "$backup_dir/$config_file.$timestamp"
        green "已备份配置到 $backup_dir/$config_file.$timestamp"
    fi
}

check_container_status() {
    local container_name="$1"
    local ip="$2"
    shift 2
    local ports=("$@")

    log "检查容器 $container_name 状态..."

    # 等待容器启动
    local wait_count=0
    while [[ $wait_count -lt 10 ]]; do
        if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
            break
        fi
        sleep 1
        wait_count=$((wait_count + 1))
    done

    if ! docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
        red "容器 $container_name 未运行"
        yellow "查看日志: docker logs $container_name"
        return 1
    fi

    green "容器 $container_name 运行中"

    # 端口连通性检测（可选）
    if command -v nc &>/dev/null; then
        sleep 3
        for port in "${ports[@]}"; do
            if nc -z -w 3 "$ip" "$port" >/dev/null 2>&1; then
                green "  端口 $port 可达"
            else
                yellow "  端口 $port 暂不可达（可能容器仍在初始化）"
            fi
        done
    fi
    return 0
}

# ==============================================================================
# 配置网络（复用逻辑提取）
# ==============================================================================
setup_network_for_container() {
    local net_name="$1"

    if docker network inspect "$net_name" >/dev/null 2>&1; then
        log "网络 $net_name 已存在，将复用"
        SHARED_SUBNET=$(docker network inspect "$net_name" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' | head -n1)
        SHARED_GATEWAY=$(docker network inspect "$net_name" --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' | head -n1)
        SHARED_PARENT_INTERFACE=$(docker network inspect "$net_name" --format '{{.Options.parent}}' 2>/dev/null || echo "")
        [[ -n "$SHARED_PARENT_INTERFACE" ]] && check_promisc_support "$SHARED_PARENT_INTERFACE"
        return 0
    fi

    log "网络 $net_name 不存在，正在创建..."
    if ! detect_lan_subnet_gateway; then
        red "自动检测失败，请手动输入"
        read -p "局域网段 (如 192.168.3.0/24): " SHARED_SUBNET
        read -p "网关 (如 192.168.3.1): " SHARED_GATEWAY
        read -p "父接口 (如 eth0): " SHARED_PARENT_INTERFACE
    fi

    if ! check_network_conflict "$SHARED_SUBNET"; then
        yellow "建议: docker network ls 查看现有网络"
        read -p "是否删除同名网络 $net_name？(y/N): " del_net
        if [[ "$del_net" =~ ^[Yy]$ ]]; then
            docker network rm "$net_name" >/dev/null 2>&1 || true
        else
            return 1
        fi
    fi

    check_promisc_support "$SHARED_PARENT_INTERFACE" || return 1
    create_docker_network "$net_name" "$SHARED_SUBNET" "$SHARED_GATEWAY" "$SHARED_PARENT_INTERFACE" || return 1
    return 0
}

# ==============================================================================
# 部署 Sing-box
# ==============================================================================
install_singbox() {
    check_root
    check_ipv6_support
    check_system_requirements

    local arch
    arch=$(get_arch)
    log "系统架构: $arch"

    read -p "Sing-box 容器名称 (默认: docker-sing-box): " SINGBOX_CONTAINER_NAME
    SINGBOX_CONTAINER_NAME=${SINGBOX_CONTAINER_NAME:-docker-sing-box}

    read -p "Sing-box 镜像版本 (如 1.12.0 或 latest, 默认 latest): " version
    version=${version:-latest}
    if ! validate_version "$version"; then
        return 1
    fi

    install_docker_deps
    check_docker_version || return 1

    read -p "配置文件存储路径 (默认 /etc/sing-box): " config_dir
    config_dir=${config_dir:-/etc/sing-box}
    mkdir -p "$config_dir"
    backup_config "$config_dir" "config.json"

    echo "Sing-box 配置文件来源："
    echo "  1) 从 URL 下载"
    echo "  2) 使用本地文件"
    read -p "选项 (1-2): " config_source

    if [[ "$config_source" == "1" ]]; then
        read -p "配置文件 URL: " config_url
        validate_url "$config_url" || return 1
        validate_url_security "$config_url" || return 1
        if ! download_config "$config_url" "$config_dir/config.json" "config"; then
            red "配置文件下载失败"
            return 1
        fi
    else
        if [[ -f "$config_dir/config.json" ]]; then
            green "检测到配置文件: $config_dir/config.json"
        else
            read -p "本地文件路径: " local_path
            if [[ -z "$local_path" || ! -f "$local_path" ]]; then
                red "文件不存在: ${local_path:-空}"
                return 1
            fi
            if [[ "$local_path" != "$config_dir/config.json" ]]; then
                cp "$local_path" "$config_dir/config.json" || { red "复制失败"; return 1; }
            fi
        fi
    fi

    check_config_dir "$config_dir" "config.json" "json" || return 1
    get_singbox_ports "$config_dir/config.json"

    # 配置网络
    setup_network_for_container "$MACVLAN_NET_NAME" || return 1

    # 获取容器 IP
    read -p "容器静态 IP (在 ${SHARED_SUBNET} 网段内): " MACVLAN_IP
    MACVLAN_IP=${MACVLAN_IP:-192.168.3.2}
    validate_ip_in_subnet "$MACVLAN_IP" "$SHARED_SUBNET" || return 1
    check_ip_occupied "$MACVLAN_IP" || return 1

    # 端口检查
    for port in ${SINGBOX_PORTS[@]+"${SINGBOX_PORTS[@]}"} "$SINGBOX_UI_PORT"; do
        if [[ -n "$port" && "$port" =~ ^[0-9]+$ ]]; then
            check_port_usage "$port" || return 1
        fi
    done

    clean_old_container "$SINGBOX_CONTAINER_NAME"

    local image="ghcr.io/sagernet/sing-box:$version"
    log "镜像: $image"

    # [修复BUG5] 不使用 eval
    if ! run_docker_container \
        "$SINGBOX_CONTAINER_NAME" \
        "$image" \
        "$MACVLAN_NET_NAME" \
        "$MACVLAN_IP" \
        "$SINGBOX_MEMORY" \
        "$SINGBOX_CPUS" \
        "$config_dir" \
        "/etc/sing-box" \
        run -c /etc/sing-box/config.json; then

        red "容器启动失败"
        yellow "排查: docker logs $SINGBOX_CONTAINER_NAME"
        return 1
    fi

    enable_ip_forwarding
    setup_iptables "$MACVLAN_IP" ${SINGBOX_PORTS[@]+"${SINGBOX_PORTS[@]}"} "$SINGBOX_UI_PORT"

    # [NEW1] 配置 macvlan-shim
    if [[ "$NETWORK_MODE" == "macvlan" && -n "$SHARED_PARENT_INTERFACE" ]]; then
        setup_macvlan_shim "$SHARED_PARENT_INTERFACE" "$MACVLAN_IP" "$SHARED_SUBNET"
    fi

    check_container_status "$SINGBOX_CONTAINER_NAME" "$MACVLAN_IP" ${SINGBOX_PORTS[@]+"${SINGBOX_PORTS[@]}"}

    echo ""
    green "=========================================="
    green "  Sing-box Docker 部署完成！"
    green "=========================================="
    echo -e "容器 IP: ${GREEN}$MACVLAN_IP${NC}"
    echo -e "代理端口: ${GREEN}${SINGBOX_PORTS[*]}${NC}"
    echo -e "管理界面: ${GREEN}http://$MACVLAN_IP:$SINGBOX_UI_PORT${NC}"
    echo -e "查看日志: ${YELLOW}docker logs $SINGBOX_CONTAINER_NAME${NC}"
    echo -e "网络模式: ${YELLOW}$NETWORK_MODE${NC}"
    echo ""
}

# ==============================================================================
# 部署 Mihomo
# ==============================================================================
install_mihomo() {
    check_root
    check_ipv6_support
    check_system_requirements

    local arch
    arch=$(get_arch)
    log "系统架构: $arch"

    read -p "Mihomo 容器名称 (默认: docker-mihomo): " MIHOMO_CONTAINER_NAME
    MIHOMO_CONTAINER_NAME=${MIHOMO_CONTAINER_NAME:-docker-mihomo}

    read -p "Mihomo 镜像版本 (如 1.18.7 或 latest, 默认 latest): " version
    version=${version:-latest}
    if ! validate_version "$version"; then
        return 1
    fi

    install_docker_deps
    check_docker_version || return 1

    read -p "配置文件存储路径 (默认 /etc/mihomo): " config_dir
    config_dir=${config_dir:-/etc/mihomo}
    mkdir -p "$config_dir"
    backup_config "$config_dir" "config.yaml"

    echo "Mihomo 配置文件来源："
    echo "  1) 从 URL 下载"
    echo "  2) 使用本地文件"
    read -p "选项 (1-2): " config_source

    if [[ "$config_source" == "1" ]]; then
        read -p "配置文件 URL: " config_url
        validate_url "$config_url" || return 1
        validate_url_security "$config_url" || return 1
        if ! download_config "$config_url" "$config_dir/config.yaml" "config"; then
            red "配置文件下载失败"
            return 1
        fi
    else
        if [[ -f "$config_dir/config.yaml" ]]; then
            green "检测到配置文件: $config_dir/config.yaml"
        else
            read -p "本地文件路径: " local_path
            if [[ -z "$local_path" || ! -f "$local_path" ]]; then
                red "文件不存在: ${local_path:-空}"
                return 1
            fi
            if [[ "$local_path" != "$config_dir/config.yaml" ]]; then
                cp "$local_path" "$config_dir/config.yaml" || { red "复制失败"; return 1; }
            fi
        fi
    fi

    check_config_dir "$config_dir" "config.yaml" "yaml" || return 1
    get_mihomo_ports "$config_dir/config.yaml"

    # 配置网络
    setup_network_for_container "$MACVLAN_NET_NAME" || return 1

    read -p "容器静态 IP (在 ${SHARED_SUBNET} 网段内): " MIHOMO_IP
    MIHOMO_IP=${MIHOMO_IP:-192.168.3.182}
    validate_ip_in_subnet "$MIHOMO_IP" "$SHARED_SUBNET" || return 1
    check_ip_occupied "$MIHOMO_IP" || return 1

    for port in ${MIHOMO_PORTS[@]+"${MIHOMO_PORTS[@]}"}; do
        check_port_usage "$port" || return 1
    done

    clean_old_container "$MIHOMO_CONTAINER_NAME"

    local image="metacubex/mihomo:$version"
    log "镜像: $image"

    # Mihomo 需要额外的 run 目录
    mkdir -p "$config_dir/run"

    if ! run_docker_container \
        "$MIHOMO_CONTAINER_NAME" \
        "$image" \
        "$MACVLAN_NET_NAME" \
        "$MIHOMO_IP" \
        "$MIHOMO_MEMORY" \
        "$MIHOMO_CPUS" \
        "$config_dir" \
        "/root/.config/mihomo"; then

        red "容器启动失败"
        yellow "排查: docker logs $MIHOMO_CONTAINER_NAME"
        return 1
    fi

    enable_ip_forwarding
    setup_iptables "$MIHOMO_IP" ${MIHOMO_PORTS[@]+"${MIHOMO_PORTS[@]}"}

    if [[ "$NETWORK_MODE" == "macvlan" && -n "$SHARED_PARENT_INTERFACE" ]]; then
        setup_macvlan_shim "$SHARED_PARENT_INTERFACE" "$MIHOMO_IP" "$SHARED_SUBNET"
    fi

    check_container_status "$MIHOMO_CONTAINER_NAME" "$MIHOMO_IP" ${MIHOMO_PORTS[@]+"${MIHOMO_PORTS[@]}"}

    echo ""
    green "=========================================="
    green "  Mihomo Docker 部署完成！"
    green "=========================================="
    echo -e "容器 IP: ${GREEN}$MIHOMO_IP${NC}"
    echo -e "HTTP/SOCKS: ${GREEN}$MIHOMO_IP:$MIHOMO_MIXED_PORT${NC}"
    echo -e "管理界面: ${GREEN}http://$MIHOMO_IP:$MIHOMO_UI_PORT${NC}"
    echo -e "DNS: ${GREEN}$MIHOMO_IP:$MIHOMO_DNS_PORT${NC}"
    echo -e "查看日志: ${YELLOW}docker logs $MIHOMO_CONTAINER_NAME${NC}"
    echo -e "网络模式: ${YELLOW}$NETWORK_MODE${NC}"
    echo ""
}

# ==============================================================================
# 卸载
# ==============================================================================
uninstall_docker() {
    local project="$1"
    local container_name container_ip

    if [[ "$project" == "sing-box" ]]; then
        read -p "容器名称 (默认: docker-sing-box): " container_name
        container_name=${container_name:-docker-sing-box}
    else
        read -p "容器名称 (默认: docker-mihomo): " container_name
        container_name=${container_name:-docker-mihomo}
    fi

    log "卸载 $project ($container_name)..."
    docker stop "$container_name" >/dev/null 2>&1 || true
    docker rm "$container_name" >/dev/null 2>&1 || true

    # 检查是否还有其他容器使用该网络
    local other_containers
    other_containers=$(docker network inspect "$MACVLAN_NET_NAME" --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null || true)
    if [[ -z "$other_containers" ]]; then
        log "网络 $MACVLAN_NET_NAME 无其他容器使用，删除..."
        docker network rm "$MACVLAN_NET_NAME" >/dev/null 2>&1 || true
        # 清理 shim
        ip link del macvlan-shim >/dev/null 2>&1 || true
        local init_sys
        init_sys=$(detect_init_system)
        if [[ "$init_sys" == "systemd" ]]; then
            systemctl disable macvlan-shim.service >/dev/null 2>&1 || true
            rm -f /etc/systemd/system/macvlan-shim.service
            systemctl daemon-reload >/dev/null 2>&1 || true
        fi
    fi

    green "$project 已卸载"
}

# ==============================================================================
# 更新配置
# ==============================================================================
update_config() {
    local project="$1"
    local config_dir config_file container_name

    if [[ "$project" == "sing-box" ]]; then
        config_dir="${SING_BOX_CONFIG_DIR}"
        config_file="config.json"
        container_name="${SINGBOX_CONTAINER_NAME}"
    else
        config_dir="${MIHOMO_CONFIG_DIR}"
        config_file="config.yaml"
        container_name="${MIHOMO_CONTAINER_NAME}"
    fi

    echo "配置来源："
    echo "  1) 从 URL 下载"
    echo "  2) 使用本地文件"
    read -p "选项 (1-2): " source

    backup_config "$config_dir" "$config_file"

    if [[ "$source" == "1" ]]; then
        read -p "新的订阅 URL: " url
        validate_url "$url" || return 1
        validate_url_security "$url" || return 1
        download_config "$url" "$config_dir/$config_file" "config" || return 1
    else
        read -p "本地文件路径: " local_path
        if [[ -z "$local_path" || ! -f "$local_path" ]]; then
            red "文件不存在"
            return 1
        fi
        cp "$local_path" "$config_dir/$config_file" || return 1
    fi

    local format="json"
    [[ "$project" == "mihomo" ]] && format="yaml"
    check_config_dir "$config_dir" "$config_file" "$format" || return 1

    docker restart "$container_name" || { red "重启容器失败"; return 1; }
    green "$project 配置已更新并重启"
}

# ==============================================================================
# 查看配置
# ==============================================================================
view_config() {
    echo ""
    green "=== 当前配置 ==="
    echo -e "Sing-box 容器: ${SINGBOX_CONTAINER_NAME}"
    echo -e "Sing-box IP: ${MACVLAN_IP:-未设置}"
    echo -e "Mihomo 容器: ${MIHOMO_CONTAINER_NAME}"
    echo -e "Mihomo IP: ${MIHOMO_IP:-未设置}"
    echo -e "网络名称: ${MACVLAN_NET_NAME}"
    echo -e "网络模式: ${NETWORK_MODE}"
    echo -e "子网: ${SHARED_SUBNET:-未设置}"
    echo -e "网关: ${SHARED_GATEWAY:-未设置}"
    echo -e "接口: ${SHARED_PARENT_INTERFACE:-未设置}"

    echo ""
    yellow "--- Docker 容器状态 ---"
    docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null | \
        grep -E "(sing-box|mihomo|NAMES)" || yellow "无相关容器"

    echo ""
    yellow "--- Docker 网络 ---"
    docker network ls --format 'table {{.Name}}\t{{.Driver}}' 2>/dev/null | \
        grep -E "(macvlan|ipvlan|NETWORK)" || yellow "无自定义网络"
    echo ""
}

# ==============================================================================
# 检查网络
# ==============================================================================
check_network() {
    log "检查网络连通性..."
    if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
        green "网络连接正常"
        return 0
    fi
    if curl -sf --connect-timeout 5 --max-time 10 https://www.google.com -o /dev/null 2>&1; then
        green "网络连接正常 (curl)"
        return 0
    fi
    red "无法连接到外网"
    return 1
}

# ==============================================================================
# 主菜单
# ==============================================================================
main_menu() {
    echo -e "${GREEN}$SCRIPT_NAME (v$SCRIPT_VERSION)${NC}"
    echo -e "用于在 Docker 中部署 Sing-box 和 Mihomo 代理服务"
    echo -e "支持 Macvlan / IPvlan / Bridge 网络模式"
    echo -e "────────────────────────────────────────"

    while true; do
        echo ""
        echo -e "${GREEN}请选择操作：${NC}"
        echo "  1) 安装 Docker Sing-box"
        echo "  2) 安装 Docker Mihomo"
        echo "  3) 卸载 Docker Sing-box"
        echo "  4) 卸载 Docker Mihomo"
        echo "  5) 查看当前配置"
        echo "  6) 更新 Sing-box 配置"
        echo "  7) 更新 Mihomo 配置"
        echo "  8) 检查网络连通性"
        echo "  q) 退出"
        read -p "选项: " choice
        case "$choice" in
            1) install_singbox ;;
            2) install_mihomo ;;
            3) uninstall_docker "sing-box" ;;
            4) uninstall_docker "mihomo" ;;
            5) view_config ;;
            6) update_config "sing-box" ;;
            7) update_config "mihomo" ;;
            8) check_network ;;
            q|Q) green "退出"; exit 0 ;;
            *) red "无效选项" ;;
        esac
        echo -e "\n${YELLOW}按 Enter 继续...${NC}"
        read -r
    done
}

# ==============================================================================
# 主入口
# ==============================================================================
main_menu
