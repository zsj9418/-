#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 全局变量（跨函数共享）
ARCH=""
ARCH_DESC=""
DOCKER_IMAGE=""
ALIYUN_IMAGE=""
FALLBACK_IMAGE=""

# ==============================================================================
# 日志函数
# ==============================================================================
log()     { echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"; }
error()   { echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] 错误: $1${NC}" >&2; }
success() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"; }
warn()    { echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] 警告: $1${NC}"; }

# ==============================================================================
# 基础检查
# ==============================================================================
check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "请使用 root 用户运行本脚本！"
        exit 1
    fi
}

check_docker_installed() {
    if ! command -v docker &>/dev/null; then
        error "未检测到 Docker，请先安装："
        echo "  curl -fsSL https://get.docker.com | bash"
        exit 1
    fi
}

check_environment() {
    log "检查运行环境..."
    if [ -z "${BASH_VERSION:-}" ]; then
        error "脚本需要 bash 运行，请使用：bash $0"
        exit 1
    fi

    # [BUG6修复] 检查 bash 版本是否支持 mapfile
    local bash_major
    bash_major=$(echo "$BASH_VERSION" | cut -d. -f1)
    if [[ "$bash_major" -lt 4 ]]; then
        warn "Bash 版本 $BASH_VERSION 较旧，部分升级功能需要 bash 4.0+。当前版本可正常使用安装功能。"
    fi

    if ! command -v jq &>/dev/null; then
        warn "未安装 jq，无损升级功能依赖它。建议：apt install jq / yum install jq"
    fi
    log "Bash 版本：$BASH_VERSION"
}

# ==============================================================================
# [NEW3] 检测 macvlan 内核模块支持
# ==============================================================================
check_macvlan_support() {
    log "检测 macvlan 内核模块支持..."
    if modprobe macvlan 2>/dev/null; then
        success "macvlan 模块已加载"
        return 0
    elif lsmod | grep -q macvlan; then
        success "macvlan 模块已在内核中"
        return 0
    else
        warn "无法加载 macvlan 模块（可能内核不支持，如部分 NAS 设备）"
        warn "在此类设备上 macvlan 模式将失败，建议改用 bridge 模式"
        return 1
    fi
}

# ==============================================================================
# 架构识别
# ==============================================================================
set_architecture_and_images() {
    ARCH=$(uname -m)
    log "检测到系统架构: $ARCH"

    case "$ARCH" in
        x86_64|amd64)
            DOCKER_IMAGE="sulinggg/openwrt:x86_64"
            ALIYUN_IMAGE="registry.cn-shanghai.aliyuncs.com/suling/openwrt:x86_64"
            FALLBACK_IMAGE="sulinggg/openwrt:openwrt-18.06-k5.4"
            ARCH_DESC="Intel/AMD 64位设备"
            ;;
        aarch64|arm64)
            DOCKER_IMAGE="sulinggg/openwrt:armv8"
            ALIYUN_IMAGE="registry.cn-shanghai.aliyuncs.com/suling/openwrt:armv8"
            FALLBACK_IMAGE="sulinggg/openwrt:rpi4"
            ARCH_DESC="ARM64 设备（树莓派4B、N1等）"
            ;;
        armv7l|armv7)
            DOCKER_IMAGE="sulinggg/openwrt:armv7"
            ALIYUN_IMAGE="registry.cn-shanghai.aliyuncs.com/suling/openwrt:armv7"
            FALLBACK_IMAGE=""
            ARCH_DESC="ARMv7 设备"

            if [ -f "/proc/cpuinfo" ]; then
                local cpu_model
                cpu_model=$(grep -m1 'Hardware' /proc/cpuinfo 2>/dev/null | awk '{print $NF}' || true)
                case "$cpu_model" in
                    BCM2835)
                        DOCKER_IMAGE="sulinggg/openwrt:rpi1"
                        ALIYUN_IMAGE="registry.cn-shanghai.aliyuncs.com/suling/openwrt:rpi1"
                        ARCH_DESC="树莓派 1B/Zero (ARMv6)"
                        FALLBACK_IMAGE="sulinggg/openwrt:armv7"
                        ;;
                    BCM2836)
                        DOCKER_IMAGE="sulinggg/openwrt:rpi2"
                        ALIYUN_IMAGE="registry.cn-shanghai.aliyuncs.com/suling/openwrt:rpi2"
                        ARCH_DESC="树莓派 2B (ARMv7)"
                        FALLBACK_IMAGE="sulinggg/openwrt:armv7"
                        ;;
                    BCM2837|BCM2837A0|BCM2837B0)
                        DOCKER_IMAGE="sulinggg/openwrt:rpi3"
                        ALIYUN_IMAGE="registry.cn-shanghai.aliyuncs.com/suling/openwrt:rpi3"
                        ARCH_DESC="树莓派 3B/3B+ (ARMv7)"
                        FALLBACK_IMAGE="sulinggg/openwrt:armv7"
                        ;;
                    BCM2711)
                        DOCKER_IMAGE="sulinggg/openwrt:rpi4"
                        ALIYUN_IMAGE="registry.cn-shanghai.aliyuncs.com/suling/openwrt:rpi4"
                        ARCH_DESC="树莓派 4B (32位模式)"
                        FALLBACK_IMAGE="sulinggg/openwrt:armv8"
                        ;;
                esac
            fi
            ;;
        armv6l)
            DOCKER_IMAGE="sulinggg/openwrt:rpi1"
            ALIYUN_IMAGE="registry.cn-shanghai.aliyuncs.com/suling/openwrt:rpi1"
            FALLBACK_IMAGE="sulinggg/openwrt:armv7"
            ARCH_DESC="树莓派 1B/Zero (ARMv6)"
            ;;
        *)
            error "不支持的架构：$ARCH"
            exit 1
            ;;
    esac
    log "架构配置完成 - 默认: $DOCKER_IMAGE"
}

# ==============================================================================
# 网络工具函数
# ==============================================================================
get_default_interface() {
    ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -n1
}

calculate_network_address() {
    local ip_cidr="$1"
    local ip_addr cidr_mask
    ip_addr=$(echo "$ip_cidr" | cut -d'/' -f1)
    cidr_mask=$(echo "$ip_cidr" | cut -d'/' -f2)

    if ! [[ "$cidr_mask" =~ ^[0-9]+$ ]] || [ "$cidr_mask" -lt 0 ] || [ "$cidr_mask" -gt 32 ]; then
        error "无效的 CIDR 掩码: $cidr_mask"
        return 1
    fi

    # 优先使用 ipcalc
    if command -v ipcalc &>/dev/null; then
        ipcalc -n "$ip_cidr" 2>/dev/null | awk '/Network:/ {print $2}' || {
            # ipcalc 输出格式因版本不同而异，备用纯 bash 计算
            _calc_network_bash "$ip_addr" "$cidr_mask"
        }
    else
        _calc_network_bash "$ip_addr" "$cidr_mask"
    fi
}

_calc_network_bash() {
    local ip_addr="$1" cidr_mask="$2"
    local o1 o2 o3 o4
    IFS='.' read -r o1 o2 o3 o4 <<< "$ip_addr"
    local mask=$(( 0xffffffff << (32 - cidr_mask) ))
    local ip_int=$(( (o1 << 24) + (o2 << 16) + (o3 << 8) + o4 ))
    local net_int=$(( ip_int & mask ))
    printf "%d.%d.%d.%d/%s\n" \
        $(( (net_int >> 24) & 255 )) \
        $(( (net_int >> 16) & 255 )) \
        $(( (net_int >> 8) & 255 )) \
        $(( net_int & 255 )) \
        "$cidr_mask"
}

# [BUG2修复] 子网冲突检查 - 改用进程替换避免子shell
check_network_conflict() {
    local subnet="$1"
    log "检查子网 $subnet 是否与现有 Docker 网络冲突..."
    local conflict_found=0
    local net

    # 使用进程替换代替管道，避免子shell变量丢失
    while IFS= read -r net; do
        [[ -z "$net" ]] && continue
        local net_subnet
        net_subnet=$(docker network inspect "$net" \
            --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || true)
        if [[ "$net_subnet" == *"$subnet"* ]]; then
            warn "子网 $subnet 与 Docker 网络 '$net' 冲突"
            conflict_found=1
        fi
    done < <(docker network ls --format '{{.Name}}' 2>/dev/null)

    if [[ $conflict_found -eq 1 ]]; then
        return 1
    fi
    log "子网 $subnet 未发现冲突"
    return 0
}

# [BUG5修复] IP 格式验证改进 - 先验证格式再解析
validate_ip_in_subnet() {
    local ip="$1"
    local subnet="$2"

    # 严格的 IP 格式验证（4个0-255的十进制数）
    if ! echo "$ip" | grep -Eq \
        '^([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])(\.([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])){3}$'; then
        error "无效的 IP 地址格式: $ip（必须为 0-255 范围内的 4 段数字）"
        return 1
    fi

    local network cidr
    network=$(echo "$subnet" | cut -d'/' -f1)
    cidr=$(echo "$subnet" | cut -d'/' -f2)

    if ! [[ "$cidr" =~ ^[0-9]+$ ]] || [ "$cidr" -lt 0 ] || [ "$cidr" -gt 32 ]; then
        error "无效的子网掩码: $cidr"
        return 1
    fi

    if command -v ipcalc &>/dev/null; then
        if ! ipcalc -c "$ip" "$subnet" &>/dev/null; then
            error "IP $ip 不在子网 $subnet 内"
            return 1
        fi
    else
        # 纯 bash 计算
        local ip1 ip2 ip3 ip4 net1 net2 net3 net4
        IFS='.' read -r ip1 ip2 ip3 ip4 <<< "$ip"
        IFS='.' read -r net1 net2 net3 net4 <<< "$network"
        local ip_int=$(( (ip1 << 24) + (ip2 << 16) + (ip3 << 8) + ip4 ))
        local net_int=$(( (net1 << 24) + (net2 << 16) + (net3 << 8) + net4 ))
        local mask=$(( 0xFFFFFFFF << (32 - cidr) ))
        if (( (ip_int & mask) != (net_int & mask) )); then
            error "IP $ip 不在子网 $subnet 内"
            return 1
        fi
    fi
    return 0
}

check_ip_occupied() {
    local ip="$1"
    log "检查 IP $ip 是否被占用..."
    if ping -c 1 -W 2 "$ip" >/dev/null 2>&1; then
        error "IP $ip 已被占用，请选择其他 IP"
        return 1
    fi
    log "IP $ip 可用"
    return 0
}

check_port_usage() {
    local port="$1"
    log "检查端口 $port..."
    if command -v ss &>/dev/null; then
        if ss -tuln 2>/dev/null | grep -q ":${port} "; then
            error "端口 $port 已被占用"
            return 1
        fi
    elif command -v netstat &>/dev/null; then
        if netstat -tuln 2>/dev/null | grep -q ":${port} "; then
            error "端口 $port 已被占用"
            return 1
        fi
    else
        warn "缺少 ss/netstat，无法检查端口占用，请手动确认"
        return 0
    fi
    log "端口 $port 可用"
    return 0
}

# [P2修复] 宿主机 IP 获取 - 修正 Docker 网段过滤逻辑
get_host_ip() {
    local ip_addr
    # 过滤 loopback 和 Docker 默认 bridge（172.17.0.0/16），保留真实网卡 IP
    ip_addr=$(ip -o -4 addr show 2>/dev/null | \
        awk '!/lo|docker[0-9]+|br-/ {print $4}' | \
        cut -d'/' -f1 | \
        grep -v '^172\.1[6-9]\.' | \
        grep -v '^172\.2[0-9]\.' | \
        grep -v '^172\.3[01]\.' | \
        head -n1)

    if [[ -z "$ip_addr" ]]; then
        # 最后备用：hostname -I
        ip_addr=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "")
    fi

    echo "${ip_addr:-<无法获取>}"
}

# ==============================================================================
# 检测局域网参数
# ==============================================================================
detect_lan_subnet_gateway() {
    log "自动检测局域网参数..."
    local default_iface
    default_iface=$(get_default_interface)

    if [[ -z "$default_iface" ]]; then
        error "无法检测默认网络接口"
        return 1
    fi

    # 检查接口类型（WiFi 不支持 macvlan）
    if [[ -d "/sys/class/net/$default_iface/wireless" ]]; then
        warn "检测到 $default_iface 是 WiFi 接口，macvlan 可能不支持"
        warn "建议使用有线网卡或切换到 bridge 模式"
    fi

    local ip_cidr
    ip_cidr=$(ip addr show dev "$default_iface" 2>/dev/null | awk '/inet / {print $2}' | head -n1)
    if [[ -z "$ip_cidr" ]]; then
        error "无法获取接口 $default_iface 的 IP 信息"
        return 1
    fi

    local subnet gateway
    subnet=$(calculate_network_address "$ip_cidr") || return 1
    gateway=$(ip route show default 2>/dev/null | awk '/default/ {print $3}' | head -n1)

    if [[ -z "$subnet" || -z "$gateway" ]]; then
        error "自动检测失败"
        return 1
    fi

    success "检测到子网: $subnet | 网关: $gateway | 接口: $default_iface"
    DETECTED_SUBNET="$subnet"
    DETECTED_GATEWAY="$gateway"
    DETECTED_INTERFACE="$default_iface"
    return 0
}

# ==============================================================================
# [P4修复] 混杂模式持久化
# ==============================================================================
enable_persistent_promisc() {
    local iface="$1"

    # 立即开启
    ip link set "$iface" promisc on || {
        error "无法开启 $iface 的混杂模式"
        return 1
    }
    success "混杂模式已开启: $iface"

    # 持久化
    if command -v systemctl &>/dev/null && [[ -d /run/systemd/system ]]; then
        local svc_file="/etc/systemd/system/promisc-${iface}.service"
        if [[ ! -f "$svc_file" ]]; then
            cat > "$svc_file" << EOF
[Unit]
Description=Enable promiscuous mode for ${iface}
After=network.target

[Service]
Type=oneshot
ExecStart=/sbin/ip link set ${iface} promisc on
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
            systemctl enable "promisc-${iface}.service" >/dev/null 2>&1
            systemctl start "promisc-${iface}.service" >/dev/null 2>&1
            success "已创建混杂模式持久化服务: promisc-${iface}.service"
        fi
    else
        # fallback: /etc/rc.local
        local rc_local="/etc/rc.local"
        if [[ -f "$rc_local" ]] && ! grep -q "promisc.*$iface" "$rc_local"; then
            sed -i "s/^exit 0/ip link set $iface promisc on\nexit 0/" "$rc_local"
            success "已将混杂模式命令写入 /etc/rc.local"
        else
            warn "请手动配置混杂模式持久化: ip link set $iface promisc on"
        fi
    fi
    return 0
}

# ==============================================================================
# [NEW1] macvlan-shim 配置（允许宿主机访问容器）
# ==============================================================================
setup_macvlan_shim() {
    local parent_iface="$1"
    local container_ip="$2"
    local subnet="$3"
    local shim_name="macvlan-shim"

    log "配置 macvlan-shim 以允许宿主机访问容器..."

    # 计算 shim IP（取子网中倒数第二个可用 IP）
    local net_addr cidr
    net_addr=$(echo "$subnet" | cut -d'/' -f1)
    cidr=$(echo "$subnet" | cut -d'/' -f2)

    local o1 o2 o3 o4
    IFS='.' read -r o1 o2 o3 o4 <<< "$net_addr"
    local net_int=$(( (o1 << 24) + (o2 << 16) + (o3 << 8) + o4 ))
    local host_bits=$((32 - cidr))
    local shim_ip_int=$(( net_int + (1 << host_bits) - 2 ))
    local shim_ip
    shim_ip=$(printf "%d.%d.%d.%d" \
        $(( (shim_ip_int >> 24) & 255 )) \
        $(( (shim_ip_int >> 16) & 255 )) \
        $(( (shim_ip_int >> 8) & 255 )) \
        $(( shim_ip_int & 255 )))

    # 避免与容器 IP 冲突
    if [[ "$shim_ip" == "$container_ip" ]]; then
        shim_ip_int=$((shim_ip_int - 1))
        shim_ip=$(printf "%d.%d.%d.%d" \
            $(( (shim_ip_int >> 24) & 255 )) \
            $(( (shim_ip_int >> 16) & 255 )) \
            $(( (shim_ip_int >> 8) & 255 )) \
            $(( shim_ip_int & 255 )))
    fi

    # 创建 shim
    ip link del "$shim_name" >/dev/null 2>&1 || true
    if ip link add link "$parent_iface" name "$shim_name" type macvlan mode bridge 2>/dev/null; then
        ip addr add "${shim_ip}/32" dev "$shim_name"
        ip link set "$shim_name" up
        ip route add "${container_ip}/32" dev "$shim_name" 2>/dev/null || true
        success "macvlan-shim 已创建: 宿主机 IP $shim_ip → 容器 $container_ip"

        # 持久化 shim
        if command -v systemctl &>/dev/null && [[ -d /run/systemd/system ]]; then
            cat > /etc/systemd/system/macvlan-shim.service << EOF
[Unit]
Description=macvlan shim for OpenWrt Docker container
After=network.target docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c "ip link del $shim_name 2>/dev/null || true; \
    ip link add link $parent_iface name $shim_name type macvlan mode bridge && \
    ip addr add ${shim_ip}/32 dev $shim_name && \
    ip link set $shim_name up && \
    ip route add ${container_ip}/32 dev $shim_name 2>/dev/null || true"
ExecStop=/bin/bash -c "ip link del $shim_name 2>/dev/null || true"

[Install]
WantedBy=multi-user.target
EOF
            systemctl enable macvlan-shim.service >/dev/null 2>&1
            success "macvlan-shim systemd 服务已创建并启用"
        fi
    else
        warn "macvlan-shim 创建失败（某些内核不支持），宿主机可能无法直接访问容器"
        warn "如需从宿主机访问容器，请通过其他局域网设备访问 http://$container_ip:80"
    fi
}

# ==============================================================================
# [P3修复] 镜像拉取 - 加超时控制
# ==============================================================================
pull_image() {
    local image="$1"
    local timeout_sec=300  # 5分钟超时
    log "正在拉取镜像: $image（超时: ${timeout_sec}s）..."

    if timeout "$timeout_sec" docker pull "$image" 2>&1 | tee /tmp/docker-pull.log; then
        success "镜像拉取成功: $image"
        return 0
    else
        local exit_code=$?
        error "镜像拉取失败: $image (退出码: $exit_code)"
        if [[ $exit_code -eq 124 ]]; then
            error "拉取超时（>${timeout_sec}s），请检查网络或使用阿里云镜像源"
        fi
        cat /tmp/docker-pull.log
        return 1
    fi
}

# ==============================================================================
# [BUG3修复] OpenWrt 网络修正 - 精准防火墙配置
# ==============================================================================
fix_openwrt_network() {
    local net_mode="$1"
    local ip="${2:-}"
    local gateway="${3:-}"
    local cidr="${4:-}"

    log "正在修正 OpenWrt 网络配置..."

    if [[ "$net_mode" -eq 2 ]] && [[ -n "$ip" ]] && [[ -n "$gateway" ]]; then
        # Macvlan 模式：静态 IP 配置
        local prefix mask
        prefix=$(echo "$cidr" | cut -d'/' -f2)
        if [[ "$prefix" =~ ^[0-9]+$ ]]; then
            local val=$(( 0xffffffff ^ ((1 << (32 - prefix)) - 1) ))
            mask="$(( (val >> 24) & 0xff )).$(( (val >> 16) & 0xff )).$(( (val >> 8) & 0xff )).$(( val & 0xff ))"
        else
            mask="255.255.255.0"
        fi

        log "配置容器静态 IP: $ip, 网关: $gateway, 掩码: $mask"
        docker exec openwrt /bin/sh -c "
            uci set network.lan.proto='static'
            uci set network.lan.ipaddr='$ip'
            uci set network.lan.netmask='$mask'
            uci set network.lan.gateway='$gateway'
            uci set network.lan.dns='$gateway 8.8.8.8'
            uci commit network
            /etc/init.d/network restart
        " >/dev/null 2>&1
    else
        # Bridge 模式：DHCP
        docker exec openwrt /bin/sh -c "
            uci set network.lan.proto='dhcp'
            uci commit network
            /etc/init.d/network restart
        " >/dev/null 2>&1
    fi

    # [BUG3修复] 精准防火墙配置：只放开 LAN zone（index 不固定，需按名查找）
    log "配置防火墙规则..."
    docker exec openwrt /bin/sh -c "
        # 查找 LAN zone 的实际 index
        local lan_idx=0
        local zone_count=0
        while uci get firewall.@zone[\$zone_count] >/dev/null 2>&1; do
            zone_name=\$(uci get firewall.@zone[\$zone_count].name 2>/dev/null)
            if [ \"\$zone_name\" = 'lan' ]; then
                lan_idx=\$zone_count
                break
            fi
            zone_count=\$((zone_count + 1))
        done

        # 仅对 LAN zone 放开 INPUT（允许访问管理界面），保持 WAN 防火墙不变
        uci set firewall.@zone[\$lan_idx].input='ACCEPT'
        uci set firewall.@zone[\$lan_idx].output='ACCEPT'
        # forward 保持 ACCEPT 以支持旁路由转发
        uci set firewall.@zone[\$lan_idx].forward='ACCEPT'
        uci commit firewall
        /etc/init.d/firewall restart
    " >/dev/null 2>&1

    # 重启 uhttpd
    docker exec openwrt /bin/sh -c "/etc/init.d/uhttpd restart" >/dev/null 2>&1
    sleep 2
    success "OpenWrt 网络配置已修正"
}

# ==============================================================================
# [P1修复] LuCI 状态检查 - 兼容 OpenWrt ps 格式
# ==============================================================================
check_luci_status() {
    log "检查 OpenWrt 容器内 LuCI 和 uhttpd 状态..."

    # 检查 LuCI 是否安装（opkg）
    if ! docker exec openwrt /bin/sh -c "opkg list-installed 2>/dev/null | grep -q '^luci'"; then
        log "LuCI 未安装，正在尝试安装..."
        if docker exec openwrt /bin/sh -c \
            "opkg update && opkg install luci-ssl luci-app-opkg luci-base 2>/dev/null"; then
            success "LuCI 安装成功"
        else
            error "LuCI 安装失败，请手动进入容器安装"
            return 1
        fi
    else
        log "LuCI 已安装"
    fi

    # [P1修复] 检查 uhttpd - 使用多种方式兼容 OpenWrt ps
    local uhttpd_running=false
    # 方式1：ps（OpenWrt busybox ps 格式简化）
    if docker exec openwrt /bin/sh -c "ps 2>/dev/null | grep -q 'uhttpd'"; then
        uhttpd_running=true
    fi
    # 方式2：init.d status
    if ! $uhttpd_running; then
        if docker exec openwrt /bin/sh -c \
            "/etc/init.d/uhttpd status 2>/dev/null | grep -q 'running'"; then
            uhttpd_running=true
        fi
    fi
    # 方式3：检查 PID 文件
    if ! $uhttpd_running; then
        if docker exec openwrt /bin/sh -c \
            "[ -f /var/run/uhttpd.pid ] && kill -0 \$(cat /var/run/uhttpd.pid) 2>/dev/null"; then
            uhttpd_running=true
        fi
    fi

    if ! $uhttpd_running; then
        log "uhttpd 未运行，正在启动..."
        if docker exec openwrt /bin/sh -c \
            "/etc/init.d/uhttpd start && /etc/init.d/uhttpd enable"; then
            success "uhttpd 已启动"
        else
            error "uhttpd 启动失败"
            return 1
        fi
    else
        log "uhttpd 运行正常"
    fi
    return 0
}

# ==============================================================================
# Web 访问验证
# ==============================================================================
verify_web_access() {
    local ip="$1"
    local port="$2"
    log "验证 Web 界面: http://$ip:$port ..."

    local retry=0
    while [[ $retry -lt 3 ]]; do
        if curl -sf -m 5 "http://$ip:$port" >/dev/null 2>&1; then
            success "Web 界面可访问: http://$ip:$port"
            return 0
        fi
        retry=$((retry + 1))
        [[ $retry -lt 3 ]] && sleep 2
    done

    warn "Web 界面暂不可访问: http://$ip:$port（可能容器仍在初始化）"
    return 1
}

# ==============================================================================
# 清理残留资源
# ==============================================================================
cleanup_residual() {
    log "清理残留 Docker 资源..."
    docker stop openwrt >/dev/null 2>&1 || true
    docker rm openwrt >/dev/null 2>&1 || true
    docker network rm openwrt_net >/dev/null 2>&1 || true
    docker network rm openwrt_bridge >/dev/null 2>&1 || true
    success "清理完成"
}

# ==============================================================================
# [BUG1修复] 使用数组构建 Docker run 命令，不使用 eval
# ==============================================================================
build_and_run_container() {
    local container_name="$1"
    local image="$2"
    local net_name="$3"
    local net_mode="$4"
    local macvlan_ip="${5:-}"
    local web_port="${6:-8080}"
    local ssh_port="${7:-2222}"
    local volume_map="${8:-}"

    local cmd=(
        docker run -d
        --name "$container_name"
        --restart unless-stopped
        --privileged
        -p "${web_port}:80"
        -p "${ssh_port}:22"
    )

    if [[ -n "$volume_map" ]]; then
        cmd+=(-v "$volume_map:/etc/config")
    fi

    if [[ "$net_mode" -eq 2 ]] && [[ -n "$macvlan_ip" ]]; then
        cmd+=(--network "$net_name" --ip "$macvlan_ip")
    else
        cmd+=(--network "$net_name")
    fi

    cmd+=("$image" /sbin/init)

    log "执行命令: ${cmd[*]}"
    "${cmd[@]}"
    return $?
}

# ==============================================================================
# 系统信息显示
# ==============================================================================
show_system_info() {
    clear
    echo -e "${BLUE}====================================${NC}"
    echo -e "      ${CYAN}OpenWrt Docker 管理工具 v2.0${NC}"
    echo -e "${BLUE}====================================${NC}"
    echo -e "系统架构：${GREEN}$ARCH_DESC ($ARCH)${NC}"
    echo -e "默认镜像：${YELLOW}$DOCKER_IMAGE${NC}"
    [[ -n "$ALIYUN_IMAGE" ]] && echo -e "阿里云镜像：${YELLOW}$ALIYUN_IMAGE${NC}"
    [[ -n "$FALLBACK_IMAGE" ]] && echo -e "备选镜像：${YELLOW}$FALLBACK_IMAGE${NC}"
    echo -e "宿主机内核：${GREEN}$(uname -r)${NC}"
    echo -e "Docker 版本：${GREEN}$(docker --version 2>/dev/null | head -n1)${NC}"

    # 内核版本警告
    local kmajor kminor
    kmajor=$(uname -r | cut -d. -f1)
    kminor=$(uname -r | cut -d. -f2)
    if (( kmajor < 5 || (kmajor == 5 && kminor < 4) )); then
        warn "内核 $(uname -r) 较旧，建议升级到 5.4+ 以提升兼容性"
    fi
    echo -e "${BLUE}====================================${NC}"
}

# ==============================================================================
# 显示登录信息（提取为独立函数，[BUG4修复]）
# ==============================================================================
show_login_info() {
    echo -e "\n${CYAN}正在查询 OpenWrt 容器登录信息...${NC}"

    local container_id
    container_id=$(docker ps -q --filter name=openwrt 2>/dev/null)
    if [[ -z "$container_id" ]]; then
        error "未找到正在运行的 openwrt 容器，请先安装或启动容器"
        return 1
    fi

    local inspect_json
    inspect_json=$(docker inspect "$container_id" 2>/dev/null)

    local network_name container_ip web_host_port ssh_host_port

    if command -v jq &>/dev/null; then
        network_name=$(echo "$inspect_json" | jq -r \
            '.[0].NetworkSettings.Networks | keys[0]' 2>/dev/null || true)
        container_ip=$(echo "$inspect_json" | jq -r \
            ".[0].NetworkSettings.Networks[\"$network_name\"].IPAddress" 2>/dev/null || true)
        web_host_port=$(echo "$inspect_json" | jq -r \
            '.[0].HostConfig.PortBindings."80/tcp"[0].HostPort // empty' 2>/dev/null || true)
        ssh_host_port=$(echo "$inspect_json" | jq -r \
            '.[0].HostConfig.PortBindings."22/tcp"[0].HostPort // empty' 2>/dev/null || true)
    else
        warn "未安装 jq，使用 grep 解析（结果可能不精确）"
        container_ip=$(echo "$inspect_json" | \
            grep -A5 '"Networks"' | grep '"IPAddress"' | \
            head -n1 | sed 's/.*"IPAddress": "\(.*\)".*/\1/')
        network_name=$(echo "$inspect_json" | \
            grep -E '"openwrt_net|openwrt_bridge"' | \
            head -n1 | sed 's/.*"\(openwrt_[^"]*\)".*/\1/')
        web_host_port=$(echo "$inspect_json" | \
            grep -A2 '"80/tcp"' | grep '"HostPort"' | \
            head -n1 | sed 's/.*"HostPort": "\(.*\)".*/\1/')
        ssh_host_port=$(echo "$inspect_json" | \
            grep -A2 '"22/tcp"' | grep '"HostPort"' | \
            head -n1 | sed 's/.*"HostPort": "\(.*\)".*/\1/')
    fi

    # 根据网络模式确定访问 IP
    local access_ip access_mode
    if [[ "$network_name" == "openwrt_net" ]]; then
        access_ip="$container_ip"
        access_mode="Macvlan（容器独立 IP）"
    else
        access_ip=$(get_host_ip)
        access_mode="Bridge（通过宿主机 IP）"
    fi

    echo -e "\n${BLUE}--- OpenWrt 登录信息 ---${NC}"
    echo -e "网络模式 : ${YELLOW}$access_mode${NC}"
    echo -e "容器 IP  : ${GREEN}$container_ip${NC}"

    if [[ -n "$web_host_port" ]]; then
        echo -e "Web 管理 : ${GREEN}http://$access_ip:$web_host_port${NC}"
    else
        echo -e "Web 管理 : ${YELLOW}未映射端口，Macvlan 模式直接访问 http://$container_ip${NC}"
    fi
    echo -e "Web 账号 : ${GREEN}root${NC} / 密码: ${YELLOW}(通常为空，首次登录后设置)${NC}"

    if [[ -n "$ssh_host_port" ]]; then
        echo -e "SSH 连接 : ${GREEN}ssh root@$access_ip -p $ssh_host_port${NC}"
    else
        echo -e "SSH 连接 : ${YELLOW}未映射端口，Macvlan 模式: ssh root@$container_ip${NC}"
    fi
    echo -e "${BLUE}------------------------${NC}"
    echo -e "${YELLOW}提示：如无法访问 Web，请尝试：${NC}"
    echo -e "  docker exec -it openwrt /bin/sh"
    echo -e "  /etc/init.d/uhttpd start"
}

# ==============================================================================
# 无损升级函数
# [BUG6修复] mapfile 兼容性处理
# ==============================================================================
upgrade_openwrt() {
    echo -e "\n${CYAN}--- 一键无损升级 OpenWrt 容器 ---${NC}"

    if ! command -v jq &>/dev/null; then
        error "无损升级需要 jq，请先安装：apt install jq"
        return 1
    fi

    if ! docker ps -a --format '{{.Names}}' | grep -q "^openwrt$"; then
        error "未找到 openwrt 容器，请先安装"
        return 1
    fi

    log "提取当前容器配置..."
    local container_info
    container_info=$(docker inspect openwrt 2>/dev/null)

    local net_mode_name macvlan_ip
    net_mode_name=$(echo "$container_info" | jq -r '.[0].HostConfig.NetworkMode' 2>/dev/null || true)

    if [[ "$net_mode_name" != "bridge" && "$net_mode_name" != "host" ]]; then
        macvlan_ip=$(echo "$container_info" | \
            jq -r ".[0].NetworkSettings.Networks[\"$net_mode_name\"].IPAddress" 2>/dev/null || true)
    fi

    # [BUG6修复] 兼容 bash < 4 的 mapfile 替代方案
    local run_args=("-d" "--name" "openwrt" "--restart" "unless-stopped" "--privileged")

    # 提取端口映射
    local ports_json
    ports_json=$(echo "$container_info" | jq -r \
        'if .[0].HostConfig.PortBindings then
            .[0].HostConfig.PortBindings | to_entries[] |
            "-p \(.value[0].HostPort):\(.key | split("/")[0])"
        else empty end' 2>/dev/null || true)

    if [[ -n "$ports_json" ]]; then
        while IFS= read -r port_arg; do
            [[ -n "$port_arg" ]] && run_args+=($port_arg)
        done <<< "$ports_json"
    fi

    # 提取挂载卷
    local mounts_json
    mounts_json=$(echo "$container_info" | jq -r \
        '.[0].Mounts[]? | "-v \(.Source):\(.Destination)"' 2>/dev/null || true)

    if [[ -n "$mounts_json" ]]; then
        while IFS= read -r mount_arg; do
            [[ -n "$mount_arg" ]] && run_args+=($mount_arg)
        done <<< "$mounts_json"
    fi

    if [[ -n "$net_mode_name" && "$net_mode_name" != "null" ]]; then
        run_args+=(--network "$net_mode_name")
        if [[ -n "$macvlan_ip" ]]; then
            run_args+=(--ip "$macvlan_ip")
        fi
    fi

    # 选择升级镜像
    echo -e "\n${YELLOW}请选择升级镜像源：${NC}"
    echo "1) 默认镜像 ($DOCKER_IMAGE)"
    [[ -n "$ALIYUN_IMAGE" ]] && echo "2) 阿里云镜像 ($ALIYUN_IMAGE)"
    [[ -n "$FALLBACK_IMAGE" ]] && echo "3) 备选镜像 ($FALLBACK_IMAGE)"
    read -rp "请选择 [默认1]: " img_choice

    local target_image="$DOCKER_IMAGE"
    case "$img_choice" in
        2) [[ -n "$ALIYUN_IMAGE" ]] && target_image="$ALIYUN_IMAGE" ;;
        3) [[ -n "$FALLBACK_IMAGE" ]] && target_image="$FALLBACK_IMAGE" ;;
    esac

    if ! pull_image "$target_image"; then
        error "镜像拉取失败，升级终止"
        return 1
    fi

    log "停止并删除旧容器..."
    docker stop openwrt >/dev/null 2>&1 || true
    docker rm openwrt >/dev/null 2>&1 || true

    run_args+=("$target_image" /sbin/init)

    log "重建容器..."
    if ! docker run "${run_args[@]}" >/dev/null 2>&1; then
        error "容器重建失败"
        return 1
    fi

    success "容器已重建，等待启动（约10秒）..."
    sleep 10

    # 重新应用网络补丁
    if [[ "$net_mode_name" == "openwrt_net" ]] && [[ -n "$macvlan_ip" ]]; then
        local gw subnet_val
        gw=$(docker network inspect "$net_mode_name" 2>/dev/null | \
            jq -r '.[0].IPAM.Config[0].Gateway' 2>/dev/null || true)
        subnet_val=$(docker network inspect "$net_mode_name" 2>/dev/null | \
            jq -r '.[0].IPAM.Config[0].Subnet' 2>/dev/null || true)
        fix_openwrt_network 2 "$macvlan_ip" "$gw" "$subnet_val"
    else
        fix_openwrt_network 1
    fi

    check_luci_status
    success "无损升级完成！"
}

# ==============================================================================
# 主安装流程
# ==============================================================================
do_install() {
    # 镜像源选择
    echo -e "\n${YELLOW}» 镜像源选择 «${NC}"
    echo "1) Docker Hub（默认）"
    [[ -n "$ALIYUN_IMAGE" ]] && echo "2) 阿里云镜像仓库（国内推荐）"
    read -rp "请选择镜像源 [默认2]: " image_source
    image_source=${image_source:-2}

    local selected_image="$DOCKER_IMAGE"
    if [[ "$image_source" -eq 2 && -n "$ALIYUN_IMAGE" ]]; then
        selected_image="$ALIYUN_IMAGE"
    fi
    log "已选择镜像: $selected_image"

    # 网络模式选择
    echo -e "\n${YELLOW}» 网络模式选择 «${NC}"
    echo "1) Bridge 模式（宿主机端口映射，适合测试）"
    echo "2) Macvlan 模式（容器获得独立 IP，推荐旁路由）"
    read -rp "请选择网络类型 [默认2]: " net_mode
    net_mode=${net_mode:-2}

    # 获取默认网卡
    local default_nic
    default_nic=$(get_default_interface)
    if [[ -z "$default_nic" ]]; then
        error "无法自动检测网卡"
        ip link show
        read -rp "请输入网卡名称: " default_nic
        if [[ -z "$default_nic" ]] || ! ip link show "$default_nic" >/dev/null 2>&1; then
            error "无效的网卡名称，安装中止"
            return 1
        fi
    fi

    local macvlan_ip="" subnet="" gateway="" target_nic=""
    local web_port="8080" ssh_port="2222"
    local net_name=""

    if [[ "$net_mode" -eq 2 ]]; then
        # --- Macvlan 配置 ---

        # [NEW3] 检测 macvlan 内核支持
        if ! check_macvlan_support; then
            warn "macvlan 内核支持不确定，是否继续？"
            read -rp "继续尝试 macvlan？(y/N): " try_macvlan
            if [[ ! "$try_macvlan" =~ ^[Yy]$ ]]; then
                error "安装中止，请改用 bridge 模式"
                return 1
            fi
        fi

        echo -e "\n${YELLOW}» Macvlan 参数配置 «${NC}"
        if detect_lan_subnet_gateway; then
            read -rp "使用自动检测的参数？[Y/n]: " use_detected
            if [[ ! "$use_detected" =~ ^[Nn]$ ]]; then
                subnet="$DETECTED_SUBNET"
                gateway="$DETECTED_GATEWAY"
                target_nic="$DETECTED_INTERFACE"
            fi
        fi

        if [[ -z "$subnet" ]]; then
            read -rp "子网 (如 192.168.3.0/24): " subnet
            read -rp "网关 (如 192.168.3.1): " gateway
            read -rp "网卡 (如 eth0) [默认: $default_nic]: " target_nic
            target_nic=${target_nic:-$default_nic}
        fi

        if ! ip link show "$target_nic" >/dev/null 2>&1; then
            error "网卡 $target_nic 不存在"
            ip link show
            return 1
        fi

        # 容器 IP
        read -rp "容器静态 IP（在 $subnet 网段内，未被占用）: " macvlan_ip
        if ! validate_ip_in_subnet "$macvlan_ip" "$subnet"; then
            return 1
        fi
        if ! check_ip_occupied "$macvlan_ip"; then
            return 1
        fi

        # 冲突检查
        if ! check_network_conflict "$subnet"; then
            read -rp "是否删除冲突网络 openwrt_net？(y/N): " del_net
            if [[ "$del_net" =~ ^[Yy]$ ]]; then
                docker network rm openwrt_net >/dev/null 2>&1 || true
            else
                return 1
            fi
        fi

        # 开启混杂模式（持久化）
        enable_persistent_promisc "$target_nic" || return 1

        # 创建 macvlan 网络
        if ! docker network inspect openwrt_net >/dev/null 2>&1; then
            log "创建 macvlan 网络 openwrt_net..."

            # [NEW2] 使用 --ip-range 限制 Docker 可分配 IP
            # 取子网中段作为 Docker 可分配范围，避免与 LAN 设备冲突
            local cidr_bits
            cidr_bits=$(echo "$subnet" | cut -d'/' -f2)
            local ip_range="${subnet%/*}"
            # 将最后一段改为 192-250 范围（简单策略）
            local ip_range_base
            ip_range_base=$(echo "$ip_range" | cut -d. -f1-3)
            local ip_range_str="${ip_range_base}.192/$((cidr_bits < 27 ? 27 : cidr_bits))"

            if ! docker network create -d macvlan \
                --subnet="$subnet" \
                --gateway="$gateway" \
                --ip-range="$ip_range_str" \
                --aux-address="host_shim=$(echo "$ip_range_base").253" \
                -o parent="$target_nic" \
                openwrt_net 2>/dev/null; then
                # 不带 ip-range 重试（某些老版本 Docker 不支持 aux-address）
                docker network create -d macvlan \
                    --subnet="$subnet" \
                    --gateway="$gateway" \
                    -o parent="$target_nic" \
                    openwrt_net || { error "macvlan 网络创建失败"; return 1; }
            fi
            success "macvlan 网络 openwrt_net 创建成功"
        else
            log "macvlan 网络 openwrt_net 已存在，复用"
        fi
        net_name="openwrt_net"

    else
        # --- Bridge 配置 ---
        if ! docker network inspect openwrt_bridge >/dev/null 2>&1; then
            docker network create openwrt_bridge || { error "bridge 网络创建失败"; return 1; }
            success "bridge 网络 openwrt_bridge 创建成功"
        fi
        net_name="openwrt_bridge"
    fi

    # 端口配置
    echo -e "\n${YELLOW}» 端口映射配置 «${NC}"
    read -rp "Web 管理端口映射到宿主机 [默认: $web_port]: " user_web_port
    web_port=${user_web_port:-$web_port}
    check_port_usage "$web_port" || return 1

    read -rp "SSH 端口映射到宿主机 [默认: $ssh_port]: " user_ssh_port
    ssh_port=${user_ssh_port:-$ssh_port}
    check_port_usage "$ssh_port" || return 1

    # 数据持久化
    echo -e "\n${YELLOW}» 数据持久化 «${NC}"
    read -rp "是否挂载配置目录到宿主机？[y/N]: " need_volume
    local volume_map=""
    if [[ "$need_volume" =~ ^[Yy]$ ]]; then
        read -rp "宿主机存储路径 [默认: /opt/openwrt/config]: " config_path
        config_path=${config_path:-/opt/openwrt/config}
        mkdir -p "$config_path" && chmod 755 "$config_path" || {
            error "无法创建目录 $config_path"
            return 1
        }
        volume_map="$config_path"
        log "配置将持久化到: $config_path"
    fi

    # 清理旧容器
    if docker ps -a --format '{{.Names}}' | grep -q "^openwrt$"; then
        warn "已存在名为 openwrt 的容器"
        read -rp "是否停止并删除？[y/N]: " remove_old
        if [[ "$remove_old" =~ ^[Yy]$ ]]; then
            docker stop openwrt >/dev/null 2>&1 || true
            docker rm openwrt >/dev/null 2>&1 || true
            success "旧容器已删除"
        else
            error "安装中止"
            return 1
        fi
    fi

    # 拉取镜像
    if ! pull_image "$selected_image"; then
        if [[ -n "$FALLBACK_IMAGE" ]]; then
            warn "尝试备选镜像: $FALLBACK_IMAGE"
            if pull_image "$FALLBACK_IMAGE"; then
                selected_image="$FALLBACK_IMAGE"
            else
                error "所有镜像拉取失败，请检查网络"
                return 1
            fi
        else
            error "无可用备选镜像，安装中止"
            return 1
        fi
    fi

    # [BUG1修复] 启动容器（不使用 eval）
    log "启动 OpenWrt 容器..."
    if ! build_and_run_container \
        "openwrt" "$selected_image" "$net_name" "$net_mode" \
        "$macvlan_ip" "$web_port" "$ssh_port" "$volume_map"; then

        error "容器启动失败"
        echo -e "${YELLOW}排查建议：${NC}"
        echo "  1. 查看日志：docker logs openwrt"
        echo "  2. 检查内核兼容性：uname -r（建议 5.4+）"
        [[ "$net_mode" -eq 2 ]] && echo "  3. 确认网卡 $target_nic 支持 macvlan"
        cleanup_residual
        return 1
    fi
    success "OpenWrt 容器已启动！"

    log "等待容器初始化（约10秒）..."
    sleep 10

    # 注入网络补丁
    if [[ "$net_mode" -eq 2 ]]; then
        fix_openwrt_network 2 "$macvlan_ip" "$gateway" "$subnet"
        # [NEW1] 配置 macvlan-shim
        setup_macvlan_shim "$target_nic" "$macvlan_ip" "$subnet"
    else
        fix_openwrt_network 1
    fi

    # 检查容器状态
    if ! docker ps -q --filter name=openwrt | grep -q .; then
        error "容器未保持运行"
        docker logs openwrt | tail -20
        cleanup_residual
        return 1
    fi

    # 配置 LuCI
    log "配置 OpenWrt 环境..."
    # [P7修复] 移除危险的 preinit sed 命令
    check_luci_status || warn "LuCI 配置未完成，请手动进入容器安装"

    # 验证部署
    echo ""
    docker ps -a --filter name=openwrt \
        --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}"

    if [[ "$net_mode" -eq 2 ]]; then
        ping -c 1 -W 2 "$macvlan_ip" >/dev/null 2>&1 && \
            success "容器 IP $macvlan_ip 可 ping 通" || \
            warn "无法 ping 通 $macvlan_ip（macvlan 宿主机限制，其他设备可访问）"
        verify_web_access "$macvlan_ip" "80"
    else
        local host_ip
        host_ip=$(get_host_ip)
        verify_web_access "$host_ip" "$web_port"
    fi

    echo ""
    success "=========================================="
    success "  OpenWrt Docker 部署完成！"
    success "=========================================="
    # [BUG4修复] 直接调用函数，不递归调用脚本
    show_login_info
}

# ==============================================================================
# 主菜单
# ==============================================================================
main_menu() {
    show_system_info

    while true; do
        echo ""
        echo -e "${CYAN}[ 主菜单 ]${NC}"
        echo "1) 安装 OpenWrt 容器"
        echo "2) 升级 OpenWrt 容器（无损保留配置）"
        echo "3) 完全卸载 OpenWrt 容器"
        echo "4) 查看容器状态"
        echo "5) 查看容器实时日志"
        echo "6) 显示 Web/SSH 登录地址"
        echo "7) 退出"
        read -rp "请输入操作编号 (1-7): " action

        case "$action" in
            1) do_install ;;
            2) upgrade_openwrt ;;
            3)
                warn "将停止并删除 openwrt 容器及相关网络"
                read -rp "确认卸载？[y/N]: " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    cleanup_residual
                    # 清理 shim 服务
                    systemctl disable macvlan-shim.service >/dev/null 2>&1 || true
                    rm -f /etc/systemd/system/macvlan-shim.service
                    systemctl daemon-reload >/dev/null 2>&1 || true
                    success "卸载完成"
                else
                    log "卸载已取消"
                fi
                ;;
            4)
                echo -e "\n${CYAN}--- 容器状态 ---${NC}"
                docker ps -a --filter name=openwrt \
                    --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}" || \
                    error "未找到 openwrt 容器"
                ;;
            5)
                echo -e "\n${CYAN}--- 实时日志 (Ctrl+C 退出) ---${NC}"
                docker logs -f openwrt 2>/dev/null || error "无法获取日志"
                echo -e "${YELLOW}提示：若日志停滞，请进入容器执行 /etc/init.d/uhttpd start${NC}"
                ;;
            6) show_login_info ;;
            7)
                echo -e "\n${YELLOW}感谢使用，再见！${NC}"
                exit 0
                ;;
            *)
                error "无效选项，请输入 1-7"
                ;;
        esac

        echo -e "\n${YELLOW}按 Enter 返回主菜单...${NC}"
        read -r
    done
}

# ==============================================================================
# 主入口
# ==============================================================================
check_root
check_docker_installed
check_environment
set_architecture_and_images
main_menu
