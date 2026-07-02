#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 全局变量
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
    local bash_major
    bash_major=$(echo "$BASH_VERSION" | cut -d. -f1)
    if [[ "$bash_major" -lt 4 ]]; then
        warn "Bash $BASH_VERSION 较旧，建议升级到 4.0+"
    fi
    if ! command -v jq &>/dev/null; then
        warn "未安装 jq，无损升级功能依赖它。建议：apt install jq"
    fi
    log "Bash 版本：$BASH_VERSION"
}

# ==============================================================================
# [FIX1] 检测 Cgroup 版本 - 核心修复点
# ==============================================================================
detect_cgroup_version() {
    if mount | grep -q "cgroup2"; then
        echo "v2"
    else
        echo "v1"
    fi
}

# [FIX1] 根据 Cgroup 版本决定是否需要 --cgroupns=host
get_cgroupns_arg() {
    local cgroup_ver
    cgroup_ver=$(detect_cgroup_version)
    if [[ "$cgroup_ver" == "v2" ]]; then
        log "检测到 Cgroup v2，将自动添加 --cgroupns=host 参数以兼容 OpenWrt procd"
        echo "--cgroupns=host"
    else
        echo ""
    fi
}

# ==============================================================================
# [FIX6] 容器真实状态检测
# 区分：正常运行 / 反复崩溃重启 / 未运行
# ==============================================================================
check_container_real_status() {
    local container_name="${1:-openwrt}"

    # 容器不存在
    if ! docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
        echo "not_found"
        return
    fi

    local status
    status=$(docker inspect "$container_name" \
        --format '{{.State.Status}}' 2>/dev/null)

    if [[ "$status" != "running" ]]; then
        echo "stopped"
        return
    fi

    # 检测是否在反复重启（重启次数 > 3 且运行时间 < 10秒）
    local restart_count
    restart_count=$(docker inspect "$container_name" \
        --format '{{.RestartCount}}' 2>/dev/null || echo "0")

    local started_at
    started_at=$(docker inspect "$container_name" \
        --format '{{.State.StartedAt}}' 2>/dev/null)

    # 转换启动时间为秒数差
    local now_ts started_ts uptime_sec
    now_ts=$(date +%s)
    started_ts=$(date -d "$started_at" +%s 2>/dev/null || echo "$now_ts")
    uptime_sec=$(( now_ts - started_ts ))

    if [[ "$restart_count" -gt 3 && "$uptime_sec" -lt 10 ]]; then
        echo "crash_loop"
        return
    fi

    # 验证容器是否真正完成启动（检查 uhttpd 或 procd 进程）
    if docker exec "$container_name" \
        /bin/sh -c "ps 2>/dev/null | grep -q 'uhttpd\|procd'" 2>/dev/null; then
        echo "healthy"
    else
        echo "starting"
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
                cpu_model=$(grep -m1 'Hardware' /proc/cpuinfo 2>/dev/null \
                    | awk '{print $NF}' || true)
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

calculate_network_address() {
    local ip_cidr="$1"
    local ip_addr cidr_mask
    ip_addr=$(echo "$ip_cidr" | cut -d'/' -f1)
    cidr_mask=$(echo "$ip_cidr" | cut -d'/' -f2)

    if ! [[ "$cidr_mask" =~ ^[0-9]+$ ]] || \
       [ "$cidr_mask" -lt 0 ] || [ "$cidr_mask" -gt 32 ]; then
        error "无效的 CIDR 掩码: $cidr_mask"
        return 1
    fi

    if command -v ipcalc &>/dev/null; then
        local result
        result=$(ipcalc -n "$ip_cidr" 2>/dev/null | awk '/Network:/ {print $2}')
        if [[ -n "$result" ]]; then
            echo "$result"
            return 0
        fi
    fi
    _calc_network_bash "$ip_addr" "$cidr_mask"
}

check_network_conflict() {
    local subnet="$1"
    log "检查子网 $subnet 冲突..."
    local conflict_found=0
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
    return $conflict_found
}

validate_ip_in_subnet() {
    local ip="$1"
    local subnet="$2"

    if ! echo "$ip" | grep -Eq \
        '^([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])(\.([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])){3}$'; then
        error "无效 IP 格式: $ip"
        return 1
    fi

    local network cidr
    network=$(echo "$subnet" | cut -d'/' -f1)
    cidr=$(echo "$subnet" | cut -d'/' -f2)

    local ip1 ip2 ip3 ip4 net1 net2 net3 net4
    IFS='.' read -r ip1 ip2 ip3 ip4 <<< "$ip"
    IFS='.' read -r net1 net2 net3 net4 <<< "$network"
    local ip_int=$(( (ip1<<24)+(ip2<<16)+(ip3<<8)+ip4 ))
    local net_int=$(( (net1<<24)+(net2<<16)+(net3<<8)+net4 ))
    local mask=$(( 0xFFFFFFFF << (32 - cidr) ))
    if (( (ip_int & mask) != (net_int & mask) )); then
        error "IP $ip 不在子网 $subnet 内"
        return 1
    fi
    return 0
}

check_ip_occupied() {
    local ip="$1"
    log "检查 IP $ip 是否被占用..."
    if ping -c 1 -W 2 "$ip" >/dev/null 2>&1; then
        error "IP $ip 已被占用"
        return 1
    fi
    log "IP $ip 可用"
    return 0
}

check_port_usage() {
    local port="$1"
    if command -v ss &>/dev/null; then
        if ss -tuln 2>/dev/null | grep -q ":${port} "; then
            error "端口 $port 已被占用"
            return 1
        fi
    fi
    return 0
}

get_host_ip() {
    local ip_addr
    ip_addr=$(ip -o -4 addr show 2>/dev/null | \
        awk '!/lo|docker[0-9]+|br-/' | \
        awk '{print $4}' | cut -d'/' -f1 | \
        grep -v '^172\.1[6-9]\.' | \
        grep -v '^172\.2[0-9]\.' | \
        grep -v '^172\.3[01]\.' | \
        head -n1)
    echo "${ip_addr:-<无法获取>}"
}

detect_lan_subnet_gateway() {
    log "自动检测局域网参数..."
    local default_iface
    default_iface=$(get_default_interface)
    [[ -z "$default_iface" ]] && { error "无法检测默认接口"; return 1; }

    if [[ -d "/sys/class/net/$default_iface/wireless" ]]; then
        warn "$default_iface 是 WiFi 接口，macvlan 可能不支持"
    fi

    local ip_cidr
    ip_cidr=$(ip addr show dev "$default_iface" 2>/dev/null \
        | awk '/inet / {print $2}' | head -n1)
    [[ -z "$ip_cidr" ]] && { error "无法获取接口 IP"; return 1; }

    local subnet gateway
    subnet=$(calculate_network_address "$ip_cidr") || return 1
    gateway=$(ip route show default 2>/dev/null \
        | awk '/default/ {print $3}' | head -n1)
    [[ -z "$subnet" || -z "$gateway" ]] && { error "自动检测失败"; return 1; }

    success "子网: $subnet | 网关: $gateway | 接口: $default_iface"
    DETECTED_SUBNET="$subnet"
    DETECTED_GATEWAY="$gateway"
    DETECTED_INTERFACE="$default_iface"
    return 0
}

# ==============================================================================
# 混杂模式持久化
# ==============================================================================
enable_persistent_promisc() {
    local iface="$1"
    ip link set "$iface" promisc on || { error "无法开启 $iface 混杂模式"; return 1; }
    success "混杂模式已开启: $iface"

    if command -v systemctl &>/dev/null && [[ -d /run/systemd/system ]]; then
        local svc="/etc/systemd/system/promisc-${iface}.service"
        if [[ ! -f "$svc" ]]; then
            cat > "$svc" << EOF
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
            success "混杂模式持久化服务已创建"
        fi
    fi
    return 0
}

# ==============================================================================
# macvlan-shim（解决宿主机无法访问容器）
# ==============================================================================
setup_macvlan_shim() {
    local parent_iface="$1"
    local container_ip="$2"
    local subnet="$3"

    log "配置 macvlan-shim..."

    local net_addr cidr o1 o2 o3 o4
    net_addr=$(echo "$subnet" | cut -d'/' -f1)
    cidr=$(echo "$subnet" | cut -d'/' -f2)
    IFS='.' read -r o1 o2 o3 o4 <<< "$net_addr"

    local net_int=$(( (o1<<24)+(o2<<16)+(o3<<8)+o4 ))
    local host_bits=$((32 - cidr))
    local shim_ip_int=$(( net_int + (1 << host_bits) - 3 ))
    local shim_ip
    shim_ip=$(printf "%d.%d.%d.%d" \
        $(( (shim_ip_int>>24)&255 )) \
        $(( (shim_ip_int>>16)&255 )) \
        $(( (shim_ip_int>>8)&255 )) \
        $(( shim_ip_int&255 )))

    # 避免与容器 IP 冲突
    if [[ "$shim_ip" == "$container_ip" ]]; then
        shim_ip_int=$((shim_ip_int - 1))
        shim_ip=$(printf "%d.%d.%d.%d" \
            $(( (shim_ip_int>>24)&255 )) \
            $(( (shim_ip_int>>16)&255 )) \
            $(( (shim_ip_int>>8)&255 )) \
            $(( shim_ip_int&255 )))
    fi

    ip link del macvlan-shim >/dev/null 2>&1 || true

    if ip link add link "$parent_iface" name macvlan-shim \
        type macvlan mode bridge 2>/dev/null; then
        ip addr add "${shim_ip}/32" dev macvlan-shim
        ip link set macvlan-shim up
        ip route add "${container_ip}/32" dev macvlan-shim 2>/dev/null || true
        success "macvlan-shim 已创建: 宿主机可通过 shim($shim_ip) 访问容器($container_ip)"

        # 持久化
        if command -v systemctl &>/dev/null && [[ -d /run/systemd/system ]]; then
            cat > /etc/systemd/system/macvlan-shim.service << EOF
[Unit]
Description=macvlan shim for OpenWrt Docker
After=network.target docker.service
Wants=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c "\
    ip link del macvlan-shim 2>/dev/null || true; \
    ip link add link ${parent_iface} name macvlan-shim type macvlan mode bridge && \
    ip addr add ${shim_ip}/32 dev macvlan-shim && \
    ip link set macvlan-shim up && \
    ip route add ${container_ip}/32 dev macvlan-shim 2>/dev/null || true"
ExecStop=/bin/bash -c "ip link del macvlan-shim 2>/dev/null || true"

[Install]
WantedBy=multi-user.target
EOF
            systemctl enable macvlan-shim.service >/dev/null 2>&1
            success "macvlan-shim 持久化服务已启用"
        fi
    else
        warn "macvlan-shim 创建失败（内核不支持），宿主机无法直接访问容器"
        warn "请从局域网其他设备访问 http://$container_ip"
    fi
}

# ==============================================================================
# [FIX5] OpenWrt 网络配置对齐（确保内部 IP = macvlan 分配 IP）
# ==============================================================================
fix_openwrt_network() {
    local net_mode="$1"
    local ip="${2:-}"
    local gateway="${3:-}"
    local cidr="${4:-}"

    log "修正 OpenWrt 内部网络配置..."

    if [[ "$net_mode" -eq 2 ]] && [[ -n "$ip" && -n "$gateway" ]]; then
        # 计算子网掩码
        local prefix mask
        prefix=$(echo "$cidr" | cut -d'/' -f2)
        if [[ "$prefix" =~ ^[0-9]+$ ]]; then
            local val=$(( 0xffffffff ^ ((1 << (32 - prefix)) - 1) ))
            mask="$(( (val>>24)&0xff )).$(( (val>>16)&0xff )).\
$(( (val>>8)&0xff )).$(( val&0xff ))"
        else
            mask="255.255.255.0"
        fi

        log "设置静态 IP: $ip 掩码: $mask 网关: $gateway"
        docker exec openwrt /bin/sh -c "
            uci set network.lan.proto='static'
            uci set network.lan.ipaddr='${ip}'
            uci set network.lan.netmask='${mask}'
            uci set network.lan.gateway='${gateway}'
            uci set network.lan.dns='${gateway} 8.8.8.8'
            uci commit network
            /etc/init.d/network restart
        " >/dev/null 2>&1
    else
        docker exec openwrt /bin/sh -c "
            uci set network.lan.proto='dhcp'
            uci commit network
            /etc/init.d/network restart
        " >/dev/null 2>&1
    fi

    sleep 3

    # 精准防火墙（按名查找 LAN zone）
    docker exec openwrt /bin/sh -c '
        i=0
        while uci get firewall.@zone[$i] >/dev/null 2>&1; do
            name=$(uci get firewall.@zone[$i].name 2>/dev/null)
            if [ "$name" = "lan" ]; then
                uci set firewall.@zone[$i].input="ACCEPT"
                uci set firewall.@zone[$i].output="ACCEPT"
                uci set firewall.@zone[$i].forward="ACCEPT"
                uci commit firewall
                /etc/init.d/firewall restart
                break
            fi
            i=$((i+1))
        done
    ' >/dev/null 2>&1

    docker exec openwrt /bin/sh -c \
        "/etc/init.d/uhttpd restart" >/dev/null 2>&1

    success "OpenWrt 网络配置已对齐"
}

# ==============================================================================
# 镜像拉取（带超时）
# ==============================================================================
pull_image() {
    local image="$1"
    local timeout_sec="${2:-300}"
    log "拉取镜像: $image (超时 ${timeout_sec}s)..."
    if timeout "$timeout_sec" docker pull "$image" 2>&1 | tee /tmp/docker-pull.log; then
        success "镜像拉取成功: $image"
        return 0
    else
        local code=$?
        [[ $code -eq 124 ]] && error "拉取超时，请检查网络或使用阿里云镜像源"
        error "拉取失败: $image"
        return 1
    fi
}

# ==============================================================================
# [FIX1][FIX2] 核心：构建并运行容器
# 自动注入 --cgroupns=host，并在崩溃时尝试备用启动方式
# ==============================================================================
build_and_run_container() {
    local container_name="$1"
    local image="$2"
    local net_name="$3"
    local net_mode="$4"         # 1=bridge 2=macvlan
    local macvlan_ip="${5:-}"
    local web_port="${6:-8080}"
    local ssh_port="${7:-2222}"
    local volume_src="${8:-}"   # 宿主机路径，为空则不挂载

    # [FIX1] 自动获取 cgroup 参数
    local cgroupns_arg
    cgroupns_arg=$(get_cgroupns_arg)

    # 构建命令数组（不使用 eval）
    local cmd=(
        docker run -d
        --name "$container_name"
        --restart unless-stopped
        --privileged
    )

    # 注入 cgroupns 参数
    [[ -n "$cgroupns_arg" ]] && cmd+=($cgroupns_arg)

    cmd+=(
        -p "${web_port}:80"
        -p "${ssh_port}:22"
    )

    [[ -n "$volume_src" ]] && cmd+=(-v "${volume_src}:/etc/config")

    if [[ "$net_mode" -eq 2 && -n "$macvlan_ip" ]]; then
        cmd+=(--network "$net_name" --ip "$macvlan_ip")
    else
        cmd+=(--network "$net_name")
    fi

    cmd+=("$image" /sbin/init)

    log "启动命令: ${cmd[*]}"
    "${cmd[@]}" >/dev/null 2>&1 || return 1

    # [FIX2][FIX3] 等待容器真正启动（最多等60秒）
    log "等待容器初始化..."
    local wait=0
    local real_status=""
    while [[ $wait -lt 60 ]]; do
        sleep 3
        wait=$((wait + 3))

        real_status=$(check_container_real_status "$container_name")

        case "$real_status" in
            healthy)
                success "容器启动成功（${wait}s）"
                return 0
                ;;
            crash_loop)
                warn "检测到容器反复崩溃（已等待 ${wait}s）"
                _handle_crash_loop "$container_name" "$image" \
                    "$net_name" "$net_mode" "$macvlan_ip" \
                    "$web_port" "$ssh_port" "$volume_src" "$cgroupns_arg"
                return $?
                ;;
            starting)
                log "容器启动中... (${wait}s)"
                ;;
            stopped|not_found)
                warn "容器已停止，尝试查看日志..."
                docker logs "$container_name" 2>&1 | tail -20
                return 1
                ;;
        esac
    done

    # 60秒后仍在 starting 状态，检查是否是 preinit 卡住
    warn "容器超过60秒未完成初始化，检查是否为 preinit 卡死..."
    local log_content
    log_content=$(docker logs "$container_name" 2>&1 | tail -5)

    if echo "$log_content" | grep -q "Press the \[f\] key"; then
        warn "检测到 preinit failsafe 卡死，尝试绕过方案..."
        _handle_crash_loop "$container_name" "$image" \
            "$net_name" "$net_mode" "$macvlan_ip" \
            "$web_port" "$ssh_port" "$volume_src" "$cgroupns_arg"
        return $?
    fi

    # 虽然超时但容器仍在运行，认为基本成功
    if docker ps -q --filter "name=^${container_name}$" | grep -q .; then
        warn "容器运行中但服务可能未完全就绪，继续后续步骤..."
        return 0
    fi

    return 1
}

# ==============================================================================
# [FIX2] 崩溃循环处理：尝试绕过 preinit 直接启动服务
# ==============================================================================
_handle_crash_loop() {
    local container_name="$1"
    local image="$2"
    local net_name="$3"
    local net_mode="$4"
    local macvlan_ip="$5"
    local web_port="$6"
    local ssh_port="$7"
    local volume_src="$8"
    local cgroupns_arg="$9"

    warn "==================================================="
    warn "检测到启动失败，尝试备用启动方式（绕过 preinit）..."
    warn "==================================================="

    # 停止旧容器
    docker stop "$container_name" >/dev/null 2>&1 || true
    docker rm "$container_name" >/dev/null 2>&1 || true

    # 备用启动命令：绕过 /sbin/init，手动启动关键服务
    local cmd=(
        docker run -d
        --name "$container_name"
        --restart unless-stopped
        --privileged
    )
    [[ -n "$cgroupns_arg" ]] && cmd+=($cgroupns_arg)
    cmd+=(
        -p "${web_port}:80"
        -p "${ssh_port}:22"
    )
    [[ -n "$volume_src" ]] && cmd+=(-v "${volume_src}:/etc/config")

    if [[ "$net_mode" -eq 2 && -n "$macvlan_ip" ]]; then
        cmd+=(--network "$net_name" --ip "$macvlan_ip")
    else
        cmd+=(--network "$net_name")
    fi

    # 绕过 preinit，直接执行必要的初始化步骤
    cmd+=("$image" /bin/sh -c "
        mkdir -p /var/lock /var/run /var/log /tmp/run /tmp/state
        mount -t proc proc /proc 2>/dev/null || true
        mount -t sysfs sysfs /sys 2>/dev/null || true
        mount -t tmpfs tmpfs /tmp 2>/dev/null || true
        mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
        /sbin/ubusd &
        sleep 2
        /etc/init.d/network start 2>/dev/null || true
        sleep 3
        /etc/init.d/firewall start 2>/dev/null || true
        /etc/init.d/uhttpd start 2>/dev/null || true
        /etc/init.d/dropbear start 2>/dev/null || true
        echo 'OpenWrt services started (bypass mode)'
        tail -f /dev/null
    ")

    log "执行备用启动: ${cmd[*]}"
    if "${cmd[@]}" >/dev/null 2>&1; then
        sleep 8
        if docker ps -q --filter "name=^${container_name}$" | grep -q .; then
            success "备用启动成功！（注意：此模式下部分 OpenWrt 功能可能受限）"
            warn "建议：尝试升级宿主机内核或更换 OpenWrt 镜像版本"
            return 0
        fi
    fi

    error "备用启动也失败了"
    error "可能原因："
    error "  1. 宿主机内核 $(uname -r) 与 OpenWrt 镜像不兼容"
    error "  2. 尝试更换镜像版本（当前: $image）"
    error "  3. 尝试升级宿主机内核"
    echo ""
    echo -e "${YELLOW}调试命令：${NC}"
    echo "  docker logs $container_name"
    echo "  docker run --rm --privileged $cgroupns_arg $image /bin/sh"
    return 1
}

# ==============================================================================
# LuCI 状态检查（兼容 OpenWrt busybox ps）
# ==============================================================================
check_luci_status() {
    log "检查 LuCI 和 uhttpd..."

    if ! docker exec openwrt /bin/sh -c \
        "opkg list-installed 2>/dev/null | grep -q '^luci'" 2>/dev/null; then
        log "LuCI 未安装，尝试安装..."
        docker exec openwrt /bin/sh -c \
            "opkg update && opkg install luci-ssl luci-app-opkg luci-base 2>/dev/null" \
            && success "LuCI 安装成功" || {
            error "LuCI 安装失败，请手动安装"
            return 1
        }
    fi

    # 多方式检测 uhttpd
    local uhttpd_ok=false
    docker exec openwrt /bin/sh -c \
        "ps 2>/dev/null | grep -v grep | grep -q uhttpd" 2>/dev/null \
        && uhttpd_ok=true
    if ! $uhttpd_ok; then
        docker exec openwrt /bin/sh -c \
            "[ -f /var/run/uhttpd.pid ] && \
             kill -0 \$(cat /var/run/uhttpd.pid) 2>/dev/null" 2>/dev/null \
            && uhttpd_ok=true
    fi

    if ! $uhttpd_ok; then
        log "uhttpd 未运行，尝试启动..."
        docker exec openwrt /bin/sh -c \
            "/etc/init.d/uhttpd start && /etc/init.d/uhttpd enable" >/dev/null 2>&1 \
            && success "uhttpd 已启动" || { error "uhttpd 启动失败"; return 1; }
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
    while [[ $retry -lt 5 ]]; do
        if curl -sf -m 5 "http://$ip:$port" >/dev/null 2>&1; then
            success "✅ Web 界面可访问: http://$ip:$port"
            return 0
        fi
        retry=$((retry + 1))
        [[ $retry -lt 5 ]] && sleep 3
    done
    warn "⚠ Web 暂不可访问（可能仍在初始化），请稍后手动访问 http://$ip:$port"
    return 1
}

# ==============================================================================
# 清理
# ==============================================================================
cleanup_residual() {
    log "清理残留资源..."
    docker stop openwrt >/dev/null 2>&1 || true
    docker rm openwrt >/dev/null 2>&1 || true
    docker network rm openwrt_net >/dev/null 2>&1 || true
    docker network rm openwrt_bridge >/dev/null 2>&1 || true
    success "清理完成"
}

# ==============================================================================
# 显示登录信息
# ==============================================================================
show_login_info() {
    echo -e "\n${CYAN}查询容器登录信息...${NC}"

    local container_id
    container_id=$(docker ps -q --filter name=openwrt 2>/dev/null)
    if [[ -z "$container_id" ]]; then
        error "未找到运行中的 openwrt 容器"
        return 1
    fi

    local inspect_json
    inspect_json=$(docker inspect "$container_id" 2>/dev/null)

    local network_name container_ip web_port ssh_port

    if command -v jq &>/dev/null; then
        network_name=$(echo "$inspect_json" | \
            jq -r '.[0].NetworkSettings.Networks | keys[0]' 2>/dev/null || true)
        container_ip=$(echo "$inspect_json" | \
            jq -r ".[0].NetworkSettings.Networks[\"$network_name\"].IPAddress" \
            2>/dev/null || true)
        web_port=$(echo "$inspect_json" | \
            jq -r '.[0].HostConfig.PortBindings."80/tcp"[0].HostPort // empty' \
            2>/dev/null || true)
        ssh_port=$(echo "$inspect_json" | \
            jq -r '.[0].HostConfig.PortBindings."22/tcp"[0].HostPort // empty' \
            2>/dev/null || true)
    else
        container_ip=$(docker inspect openwrt 2>/dev/null | \
            grep '"IPAddress"' | grep -v '""' | head -n1 | \
            sed 's/.*"IPAddress": "\(.*\)".*/\1/')
        network_name=$(docker inspect openwrt 2>/dev/null | \
            grep -E '"openwrt_net|openwrt_bridge"' | head -n1 | \
            sed 's/.*"\(openwrt_[^"]*\)".*/\1/')
        web_port=$(docker inspect openwrt 2>/dev/null | \
            grep -A2 '"80/tcp"' | grep '"HostPort"' | head -n1 | \
            sed 's/.*"HostPort": "\(.*\)".*/\1/')
        ssh_port=$(docker inspect openwrt 2>/dev/null | \
            grep -A2 '"22/tcp"' | grep '"HostPort"' | head -n1 | \
            sed 's/.*"HostPort": "\(.*\)".*/\1/')
    fi

    local access_ip access_mode
    if [[ "$network_name" == "openwrt_net" ]]; then
        access_ip="$container_ip"
        access_mode="Macvlan（容器独立 IP）"
    else
        access_ip=$(get_host_ip)
        access_mode="Bridge（通过宿主机 IP）"
    fi

    # 检测容器实际状态
    local real_status
    real_status=$(check_container_real_status "openwrt")

    echo -e "\n${BLUE}─────────────────────────────────${NC}"
    echo -e " ${CYAN}OpenWrt 登录信息${NC}"
    echo -e "${BLUE}─────────────────────────────────${NC}"

    # 状态显示
    case "$real_status" in
        healthy)   echo -e " 容器状态: ${GREEN}✅ 运行正常${NC}" ;;
        starting)  echo -e " 容器状态: ${YELLOW}⏳ 启动中...${NC}" ;;
        crash_loop)echo -e " 容器状态: ${RED}❌ 反复崩溃（建议重装）${NC}" ;;
        stopped)   echo -e " 容器状态: ${RED}⏹ 已停止${NC}" ;;
        *)         echo -e " 容器状态: ${YELLOW}未知${NC}" ;;
    esac

    echo -e " Cgroup 版本: ${YELLOW}$(detect_cgroup_version)${NC}"
    echo -e " 网络模式: ${YELLOW}$access_mode${NC}"
    echo -e " 容器 IP: ${GREEN}$container_ip${NC}"

    if [[ -n "$web_port" ]]; then
        echo -e " Web 管理: ${GREEN}http://$access_ip:$web_port${NC}"
    else
        echo -e " Web 管理: ${GREEN}http://$container_ip${NC} (macvlan 直连)"
    fi
    echo -e " 账号/密码: ${GREEN}root${NC} / ${YELLOW}(空，首次登录后设置)${NC}"

    if [[ -n "$ssh_port" ]]; then
        echo -e " SSH 连接: ${GREEN}ssh root@$access_ip -p $ssh_port${NC}"
    else
        echo -e " SSH 连接: ${GREEN}ssh root@$container_ip${NC}"
    fi

    echo -e "${BLUE}─────────────────────────────────${NC}"

    if [[ "$network_name" == "openwrt_net" ]]; then
        echo -e "${YELLOW}提示：macvlan 模式下宿主机本身无法直接访问容器${NC}"
        echo -e "${YELLOW}请用局域网内其他设备（手机/电脑）访问上述地址${NC}"
    fi

    if [[ "$real_status" == "crash_loop" ]]; then
        echo ""
        echo -e "${RED}容器正在反复崩溃，请执行以下诊断：${NC}"
        echo "  docker logs openwrt | tail -30"
        echo "  建议：选择菜单 [1] 重新安装（已自动添加 cgroup 兼容参数）"
    fi
}

# ==============================================================================
# 无损升级
# ==============================================================================
upgrade_openwrt() {
    echo -e "\n${CYAN}─── 无损升级 OpenWrt 容器 ───${NC}"

    if ! command -v jq &>/dev/null; then
        error "无损升级需要 jq：apt install jq"
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
    net_mode_name=$(echo "$container_info" | \
        jq -r '.[0].HostConfig.NetworkMode' 2>/dev/null || true)
    if [[ "$net_mode_name" != "bridge" && "$net_mode_name" != "host" ]]; then
        macvlan_ip=$(echo "$container_info" | \
            jq -r ".[0].NetworkSettings.Networks[\"$net_mode_name\"].IPAddress" \
            2>/dev/null || true)
    fi

    local run_args=("-d" "--name" "openwrt" "--restart" "unless-stopped" "--privileged")

    # [FIX1] 自动补充 cgroupns 参数
    local cgroupns_arg
    cgroupns_arg=$(get_cgroupns_arg)
    [[ -n "$cgroupns_arg" ]] && run_args+=($cgroupns_arg)

    # 提取端口映射
    local ports_json
    ports_json=$(echo "$container_info" | jq -r \
        'if .[0].HostConfig.PortBindings then
            .[0].HostConfig.PortBindings | to_entries[] |
            "-p \(.value[0].HostPort):\(.key | split("/")[0])"
        else empty end' 2>/dev/null || true)
    while IFS= read -r port_arg; do
        [[ -n "$port_arg" ]] && run_args+=($port_arg)
    done <<< "$ports_json"

    # 提取挂载卷
    local mounts_json
    mounts_json=$(echo "$container_info" | jq -r \
        '.[0].Mounts[]? | "-v \(.Source):\(.Destination)"' 2>/dev/null || true)
    while IFS= read -r mount_arg; do
        [[ -n "$mount_arg" ]] && run_args+=($mount_arg)
    done <<< "$mounts_json"

    if [[ -n "$net_mode_name" && "$net_mode_name" != "null" ]]; then
        run_args+=(--network "$net_mode_name")
        [[ -n "$macvlan_ip" ]] && run_args+=(--ip "$macvlan_ip")
    fi

    # 选择镜像
    echo -e "\n${YELLOW}选择升级镜像源：${NC}"
    echo "1) 默认镜像 ($DOCKER_IMAGE)"
    [[ -n "$ALIYUN_IMAGE" ]] && echo "2) 阿里云镜像 ($ALIYUN_IMAGE)"
    [[ -n "$FALLBACK_IMAGE" ]] && echo "3) 备选镜像 ($FALLBACK_IMAGE)"
    read -rp "请选择 [默认1]: " img_choice

    local target_image="$DOCKER_IMAGE"
    case "${img_choice:-1}" in
        2) [[ -n "$ALIYUN_IMAGE" ]] && target_image="$ALIYUN_IMAGE" ;;
        3) [[ -n "$FALLBACK_IMAGE" ]] && target_image="$FALLBACK_IMAGE" ;;
    esac

    pull_image "$target_image" || { error "镜像拉取失败"; return 1; }

    log "停止并删除旧容器..."
    docker stop openwrt >/dev/null 2>&1 || true
    docker rm openwrt >/dev/null 2>&1 || true

    run_args+=("$target_image" /sbin/init)

    log "重建容器..."
    if ! docker run "${run_args[@]}" >/dev/null 2>&1; then
        error "容器重建失败"
        return 1
    fi

    log "等待启动（约15秒）..."
    sleep 15

    # 检测是否崩溃
    local status
    status=$(check_container_real_status "openwrt")
    if [[ "$status" == "crash_loop" ]]; then
        warn "检测到崩溃循环，尝试备用启动方式..."
        _handle_crash_loop "openwrt" "$target_image" \
            "$net_mode_name" \
            "$([[ "$net_mode_name" == "openwrt_net" ]] && echo 2 || echo 1)" \
            "$macvlan_ip" "8080" "2222" "" "$cgroupns_arg"
    fi

    # 重新注入网络配置
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
    success "升级完成！"
}

# ==============================================================================
# 系统信息显示
# ==============================================================================
show_system_info() {
    clear
    local cgroup_ver
    cgroup_ver=$(detect_cgroup_version)

    echo -e "${BLUE}════════════════════════════════════${NC}"
    echo -e "    ${CYAN}OpenWrt Docker 管理工具 v2.1${NC}"
    echo -e "${BLUE}════════════════════════════════════${NC}"
    echo -e " 架构: ${GREEN}$ARCH_DESC ($ARCH)${NC}"
    echo -e " 内核: ${GREEN}$(uname -r)${NC}"
    echo -e " Cgroup: ${YELLOW}$cgroup_ver${NC}\
$([ "$cgroup_ver" = "v2" ] && echo " ${GREEN}(已自动兼容)${NC}")"
    echo -e " Docker: ${GREEN}$(docker --version 2>/dev/null | head -n1)${NC}"
    echo -e " 默认镜像: ${YELLOW}$DOCKER_IMAGE${NC}"
    [[ -n "$ALIYUN_IMAGE" ]] && \
        echo -e " 阿里云: ${YELLOW}$ALIYUN_IMAGE${NC}"
    [[ -n "$FALLBACK_IMAGE" ]] && \
        echo -e " 备选: ${YELLOW}$FALLBACK_IMAGE${NC}"

    # 内核版本警告
    local kmajor kminor
    kmajor=$(uname -r | cut -d. -f1)
    kminor=$(uname -r | cut -d. -f2)
    if (( kmajor < 5 || (kmajor == 5 && kminor < 4) )); then
        warn "内核 $(uname -r) 较旧，建议升级到 5.4+"
    fi

    # 容器当前状态预览
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^openwrt$"; then
        local status
        status=$(check_container_real_status "openwrt")
        case "$status" in
            healthy)    echo -e " 容器状态: ${GREEN}✅ 运行正常${NC}" ;;
            crash_loop) echo -e " 容器状态: ${RED}❌ 反复崩溃${NC}" ;;
            starting)   echo -e " 容器状态: ${YELLOW}⏳ 启动中${NC}" ;;
            stopped)    echo -e " 容器状态: ${YELLOW}⏹ 已停止${NC}" ;;
        esac
    fi
    echo -e "${BLUE}════════════════════════════════════${NC}"
}

# ==============================================================================
# 主安装流程
# ==============================================================================
do_install() {
    # 预检 Cgroup 版本并提示
    local cgroup_ver
    cgroup_ver=$(detect_cgroup_version)
    if [[ "$cgroup_ver" == "v2" ]]; then
        log "检测到 Cgroup v2，将自动添加 --cgroupns=host 确保 OpenWrt 兼容性"
    fi

    # 镜像源选择
    echo -e "\n${YELLOW}» 镜像源选择 «${NC}"
    echo "1) Docker Hub（默认）"
    [[ -n "$ALIYUN_IMAGE" ]] && echo "2) 阿里云镜像（国内推荐）"
    read -rp "请选择 [默认2]: " image_source
    image_source=${image_source:-2}

    local selected_image="$DOCKER_IMAGE"
    [[ "$image_source" -eq 2 && -n "$ALIYUN_IMAGE" ]] && \
        selected_image="$ALIYUN_IMAGE"

    # 网络模式选择
    echo -e "\n${YELLOW}» 网络模式选择 «${NC}"
    echo "1) Bridge 模式（端口映射，适合测试）"
    echo "2) Macvlan 模式（容器独立 IP，推荐旁路由）"
    read -rp "请选择 [默认2]: " net_mode
    net_mode=${net_mode:-2}

    local default_nic
    default_nic=$(get_default_interface)
    if [[ -z "$default_nic" ]]; then
        error "无法检测默认网卡"
        ip link show
        read -rp "请输入网卡名称: " default_nic
        ip link show "$default_nic" >/dev/null 2>&1 || {
            error "无效网卡名称"; return 1
        }
    fi

    local macvlan_ip="" subnet="" gateway="" target_nic=""
    local web_port="8080" ssh_port="2222"
    local net_name=""

    if [[ "$net_mode" -eq 2 ]]; then
        # Macvlan 配置
        echo -e "\n${YELLOW}» Macvlan 参数配置 «${NC}"

        if detect_lan_subnet_gateway; then
            read -rp "使用自动检测参数？[Y/n]: " use_detected
            if [[ ! "$use_detected" =~ ^[Nn]$ ]]; then
                subnet="$DETECTED_SUBNET"
                gateway="$DETECTED_GATEWAY"
                target_nic="$DETECTED_INTERFACE"
            fi
        fi

        if [[ -z "$subnet" ]]; then
            read -rp "子网 (如 192.168.3.0/24): " subnet
            read -rp "网关 (如 192.168.3.1): " gateway
            read -rp "网卡 [默认: $default_nic]: " target_nic
            target_nic=${target_nic:-$default_nic}
        fi

        ip link show "$target_nic" >/dev/null 2>&1 || {
            error "网卡 $target_nic 不存在"
            return 1
        }

        read -rp "容器静态 IP（在 $subnet 网段内）: " macvlan_ip
        validate_ip_in_subnet "$macvlan_ip" "$subnet" || return 1
        check_ip_occupied "$macvlan_ip" || return 1

        if ! check_network_conflict "$subnet"; then
            read -rp "是否删除冲突网络 openwrt_net？(y/N): " del_net
            if [[ "$del_net" =~ ^[Yy]$ ]]; then
                docker network rm openwrt_net >/dev/null 2>&1 || true
            else
                return 1
            fi
        fi

        enable_persistent_promisc "$target_nic" || return 1

        if ! docker network inspect openwrt_net >/dev/null 2>&1; then
            log "创建 macvlan 网络..."
            docker network create -d macvlan \
                --subnet="$subnet" \
                --gateway="$gateway" \
                -o parent="$target_nic" \
                openwrt_net || { error "macvlan 网络创建失败"; return 1; }
            success "macvlan 网络创建成功"
        else
            log "macvlan 网络已存在，复用"
        fi
        net_name="openwrt_net"

    else
        # Bridge 配置
        if ! docker network inspect openwrt_bridge >/dev/null 2>&1; then
            docker network create openwrt_bridge || {
                error "bridge 网络创建失败"
                return 1
            }
        fi
        net_name="openwrt_bridge"
    fi

    # 端口配置
    echo -e "\n${YELLOW}» 端口映射 «${NC}"
    read -rp "Web 管理端口 [默认: $web_port]: " user_web
    web_port=${user_web:-$web_port}
    check_port_usage "$web_port" || return 1

    read -rp "SSH 端口 [默认: $ssh_port]: " user_ssh
    ssh_port=${user_ssh:-$ssh_port}
    check_port_usage "$ssh_port" || return 1

    # 数据持久化
    echo -e "\n${YELLOW}» 数据持久化 «${NC}"
    read -rp "是否挂载配置目录到宿主机？[y/N]: " need_vol
    local volume_src=""
    if [[ "$need_vol" =~ ^[Yy]$ ]]; then
        read -rp "宿主机路径 [默认: /opt/openwrt/config]: " config_path
        config_path=${config_path:-/opt/openwrt/config}
        mkdir -p "$config_path" && chmod 755 "$config_path" || {
            error "无法创建目录 $config_path"
            return 1
        }
        volume_src="$config_path"
    fi

    # 清理旧容器
    if docker ps -a --format '{{.Names}}' | grep -q "^openwrt$"; then
        warn "已存在 openwrt 容器"
        read -rp "是否停止并删除？[y/N]: " rm_old
        if [[ "$rm_old" =~ ^[Yy]$ ]]; then
            docker stop openwrt >/dev/null 2>&1 || true
            docker rm openwrt >/dev/null 2>&1 || true
        else
            return 1
        fi
    fi

    # 拉取镜像
    if ! pull_image "$selected_image"; then
        if [[ -n "$FALLBACK_IMAGE" ]]; then
            warn "尝试备选镜像: $FALLBACK_IMAGE"
            pull_image "$FALLBACK_IMAGE" && selected_image="$FALLBACK_IMAGE" || {
                error "所有镜像拉取失败"
                return 1
            }
        else
            return 1
        fi
    fi

    # [FIX1][FIX2][FIX3] 启动容器（含 cgroup 兼容 + 崩溃检测 + 备用方案）
    if ! build_and_run_container \
        "openwrt" "$selected_image" "$net_name" "$net_mode" \
        "$macvlan_ip" "$web_port" "$ssh_port" "$volume_src"; then
        error "容器启动失败，请检查上方错误信息"
        cleanup_residual
        return 1
    fi

    # [FIX5] 网络配置对齐
    if [[ "$net_mode" -eq 2 ]]; then
        fix_openwrt_network 2 "$macvlan_ip" "$gateway" "$subnet"
        # [FIX4] macvlan-shim
        setup_macvlan_shim "$target_nic" "$macvlan_ip" "$subnet"
    else
        fix_openwrt_network 1
    fi

    # 配置 LuCI
    log "配置 OpenWrt 环境..."
    check_luci_status || warn "LuCI 未完全配置，可手动进入容器安装"

    # 验证部署
    echo ""
    docker ps -a --filter name=openwrt \
        --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}"

    if [[ "$net_mode" -eq 2 ]]; then
        ping -c 2 "$macvlan_ip" >/dev/null 2>&1 \
            && success "✅ 容器 IP $macvlan_ip 可 ping 通" \
            || warn "宿主机无法 ping 通容器（macvlan 正常限制），请用其他设备测试"
        verify_web_access "$macvlan_ip" "80"
    else
        verify_web_access "$(get_host_ip)" "$web_port"
    fi

    echo ""
    success "══════════════════════════════"
    success "  OpenWrt Docker 部署完成！"
    success "══════════════════════════════"
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
        echo "7) 修复网络配置（容器运行但无法访问时使用）"
        echo "8) 退出"
        read -rp "请输入操作编号 (1-8): " action

        case "$action" in
            1) do_install ;;
            2) upgrade_openwrt ;;
            3)
                warn "将停止并删除 openwrt 容器及相关网络"
                read -rp "确认卸载？[y/N]: " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    cleanup_residual
                    systemctl disable macvlan-shim.service >/dev/null 2>&1 || true
                    rm -f /etc/systemd/system/macvlan-shim.service
                    systemctl daemon-reload >/dev/null 2>&1 || true
                    success "卸载完成"
                fi
                ;;
            4)
                echo -e "\n${CYAN}─── 容器状态 ───${NC}"
                docker ps -a --filter name=openwrt \
                    --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}" \
                    || error "未找到 openwrt 容器"
                local rs
                rs=$(check_container_real_status "openwrt")
                echo -e "实际状态: ${YELLOW}$rs${NC}"
                ;;
            5)
                echo -e "\n${CYAN}─── 实时日志 (Ctrl+C 退出) ───${NC}"
                echo -e "${YELLOW}提示：'Press the [f] key' 是正常 preinit 输出，约3秒后自动跳过${NC}"
                echo -e "${YELLOW}若持续停留超过30秒，说明容器已崩溃，请选择 [1] 重新安装${NC}"
                echo ""
                docker logs -f openwrt 2>/dev/null || error "无法获取日志"
                ;;
            6) show_login_info ;;
            7)
                # 手动触发网络修复
                echo -e "\n${CYAN}─── 修复网络配置 ───${NC}"
                local rs
                rs=$(check_container_real_status "openwrt")
                if [[ "$rs" != "healthy" && "$rs" != "starting" ]]; then
                    error "容器未正常运行（状态: $rs），请先启动容器"
                else
                    # 从容器读取当前配置
                    local cur_ip cur_gw cur_subnet
                    cur_ip=$(docker inspect openwrt 2>/dev/null | \
                        grep '"IPAddress"' | grep -v '""' | head -n1 | \
                        sed 's/.*"IPAddress": "\(.*\)".*/\1/')
                    local net_name
                    net_name=$(docker inspect openwrt 2>/dev/null | \
                        jq -r '.[0].HostConfig.NetworkMode' 2>/dev/null || \
                        echo "openwrt_net")

                    if [[ "$net_name" == "openwrt_net" ]]; then
                        cur_gw=$(docker network inspect openwrt_net 2>/dev/null | \
                            grep '"Gateway"' | head -n1 | \
                            sed 's/.*"Gateway": "\(.*\)".*/\1/')
                        cur_subnet=$(docker network inspect openwrt_net 2>/dev/null | \
                            grep '"Subnet"' | head -n1 | \
                            sed 's/.*"Subnet": "\(.*\)".*/\1/')
                        log "当前配置: IP=$cur_ip 网关=$cur_gw 子网=$cur_subnet"
                        fix_openwrt_network 2 "$cur_ip" "$cur_gw" "$cur_subnet"
                        # 重建 shim
                        local parent_iface
                        parent_iface=$(docker network inspect openwrt_net 2>/dev/null | \
                            grep '"parent"' | head -n1 | \
                            sed 's/.*"parent": "\(.*\)".*/\1/')
                        [[ -n "$parent_iface" && -n "$cur_ip" && -n "$cur_subnet" ]] && \
                            setup_macvlan_shim "$parent_iface" "$cur_ip" "$cur_subnet"
                    else
                        fix_openwrt_network 1
                    fi
                fi
                ;;
            8)
                echo -e "\n${YELLOW}再见！${NC}"
                exit 0
                ;;
            *)
                error "无效选项，请输入 1-8"
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
