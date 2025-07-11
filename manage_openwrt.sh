#!/bin/bash

# 日志输出函数
log() {
    echo -e "\033[33m[$(date +'%Y-%m-%d %H:%M:%S')] $1\033[0m"
}

# 错误输出函数
error() {
    echo -e "\033[31m[$(date +'%Y-%m-%d %H:%M:%S')] 错误: $1\033[0m" >&2
}

# 成功输出函数
success() {
    echo -e "\033[32m[$(date +'%Y-%m-%d %H:%M:%S')] $1\033[0m"
}

# 权限检查
check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "请使用 root 用户运行本脚本！"
        exit 1
    fi
}

# Docker 存在性检查
check_docker_installed() {
    if ! command -v docker &> /dev/null; then
        error "检测到 Docker 未安装，请先执行以下命令安装："
        echo "curl -fsSL https://get.docker.com | bash -s docker --mirror Aliyun"
        exit 1
    fi
}

# 环境检查（Bash和Grep版本）
check_environment() {
    log "检查 shell 环境..."
    if [ -z "$BASH_VERSION" ]; then
        error "脚本需要 bash 运行，请确保使用 /bin/bash 执行！"
        echo "尝试：bash $0"
        exit 1
    fi
    log "Bash 版本：$BASH_VERSION"
    log "Grep 版本：$(grep --version | head -n1)"
    # 检查jq，如果未安装则提示
    if ! command -v jq &> /dev/null; then
        log "提示：未安装 'jq'，部分功能（如获取登录地址）可能不够精确。建议安装 'jq' (例如: apt install jq)。"
    fi
}

# 架构识别与镜像配置
set_architecture_and_images() {
    ARCH=$(uname -m)
    log "检测到系统架构: $ARCH"

    case "$ARCH" in
        x86_64 | amd64) # 兼容 amd64
            DOCKER_IMAGE="sulinggg/openwrt:x86_64"
            ALIYUN_IMAGE="registry.cn-shanghai.aliyuncs.com/suling/openwrt:x86_64"
            FALLBACK_IMAGE="sulinggg/openwrt:openwrt-18.06-k5.4" # 备用旧内核版本
            ARCH_DESC="Intel/AMD 64位设备"
            ;;
        aarch64 | arm64) # aarch64 是 ARM 64位架构的正式名称，arm64 是常见别名
            # 尝试更细致的 ARM 平台识别，例如树莓派4B
            # 注意：uname -m 对于不同树莓派可能都是 aarch64 或 armv7l
            # 这里默认指向 armv8，因为它包含了大多数 aarch64 设备
            # 如果需要更精确的 rpi4/rpi3 识别，需要更复杂的逻辑，例如检查 /proc/cpuinfo
            # 当前的镜像标签armv8通常代表aarch64
            DOCKER_IMAGE="sulinggg/openwrt:armv8"
            ALIYUN_IMAGE="registry.cn-shanghai.aliyuncs.com/suling/openwrt:armv8"
            # 对于 aarch64，rpi4 是一个常见的备用选择，因为它也是 aarch64
            FALLBACK_IMAGE="sulinggg/openwrt:rpi4" 
            ARCH_DESC="ARM64 (aarch64) 设备（如树莓派4B、N1等）"
            ;;
        armv7l | armv7) # armv7l 是 armv7 的一个常见变体
            DOCKER_IMAGE="sulinggg/openwrt:armv7"
            ALIYUN_IMAGE="registry.cn-shanghai.aliyuncs.com/suling/openwrt:armv7"
            FALLBACK_IMAGE="" # ARMv7目前没有特定备选
            ARCH_DESC="ARMv7 设备（如NanoPi R2S/R4S、树莓派2B/3B/3B+等）"
            
            # 进一步细分树莓派
            # 警告：以下识别逻辑基于 /proc/cpuinfo，在某些非 Raspbian 系统上可能不准确
            # 更精确的识别可能需要检查 /sys/firmware/devicetree/base/model
            if [ -f "/proc/cpuinfo" ]; then
                CPU_MODEL=$(grep -m 1 'Hardware' /proc/cpuinfo | awk '{print $NF}')
                case "$CPU_MODEL" in
                    BCM2835) # Raspberry Pi 1B / Zero
                        log "检测到为树莓派 1B / Zero 架构 (BCM2835)."
                        DOCKER_IMAGE="sulinggg/openwrt:rpi1"
                        ALIYUN_IMAGE="registry.cn-shanghai.aliyuncs.com/suling/openwrt:rpi1"
                        ARCH_DESC="树莓派 1B / Zero (ARMv6)" # rpi1镜像通常为armv6，但此处为了简化归类到armv7段
                        FALLBACK_IMAGE="sulinggg/openwrt:armv7" # rpi1如果不存在，可以尝试armv7
                        ;;
                    BCM2836) # Raspberry Pi 2B
                        log "检测到为树莓派 2B 架构 (BCM2836)."
                        DOCKER_IMAGE="sulinggg/openwrt:rpi2"
                        ALIYUN_IMAGE="registry.cn-shanghai.aliyuncs.com/suling/openwrt:rpi2"
                        ARCH_DESC="树莓派 2B (ARMv7)"
                        FALLBACK_IMAGE="sulinggg/openwrt:armv7"
                        ;;
                    BCM2837 | BCM2837A0 | BCM2837B0) # Raspberry Pi 3B / 3B+ (CPU是64位，但系统可能运行在32位模式，即armv7l)
                        # 如果 uname -m 是 aarch64，则会走 aarch64 分支，这里处理的是 armv7l 的情况
                        log "检测到为树莓派 3B / 3B+ 架构 (BCM2837/BCM2837A0/BCM2837B0)."
                        DOCKER_IMAGE="sulinggg/openwrt:rpi3"
                        ALIYUN_IMAGE="registry.cn-shanghai.aliyuncs.com/suling/openwrt:rpi3"
                        ARCH_DESC="树莓派 3B / 3B+ (ARMv7，宿主机可能运行在32位模式)"
                        FALLBACK_IMAGE="sulinggg/openwrt:armv7"
                        ;;
                    BCM2711) # Raspberry Pi 4B (CPU是64位，但在某些32位系统下也可能是armv7l)
                        # 这种情况通常会通过 aarch64 识别，这里是备用处理
                        log "检测到为树莓派 4B 架构 (BCM2711)，但系统运行在32位模式。"
                        DOCKER_IMAGE="sulinggg/openwrt:rpi4"
                        ALIYUN_IMAGE="registry.cn-shanghai.aliyuncs.com/suling/openwrt:rpi4"
                        ARCH_DESC="树莓派 4B (ARMv7，宿主机运行在32位模式)"
                        FALLBACK_IMAGE="sulinggg/openwrt:armv8" # 尝试aarch64备用，因为rpi4镜像本身就是aarch64
                        ;;
                esac
            fi
            ;;
        armv6l) # 树莓派 1B/Zero 专属，通常包含在 rpi1 镜像中
            log "检测到为 ARMv6 设备 (如树莓派 1B/Zero)."
            DOCKER_IMAGE="sulinggg/openwrt:rpi1"
            ALIYUN_IMAGE="registry.cn-shanghai.aliyuncs.com/suling/openwrt:rpi1"
            ARCH_DESC="树莓派 1B / Zero (ARMv6)"
            FALLBACK_IMAGE="sulinggg/openwrt:armv7" # 作为一个不太理想的备选
            ;;
        *)
            error "不支持的架构：$ARCH"
            exit 1
            ;;
    esac
    log "已配置镜像信息 - 默认: $DOCKER_IMAGE, 阿里云: ${ALIYUN_IMAGE:-无}, 备选: ${FALLBACK_IMAGE:-无}"
}

# 获取默认网络接口
get_default_interface() {
    ip route show default | awk '/default/ {print $5}'
}

# 计算网络地址 (从 IP/CIDR 获取网络地址)
calculate_network_address() {
    local ip_cidr=$1
    local ip_addr=$(echo "$ip_cidr" | cut -d'/' -f1)
    local cidr_mask=$(echo "$ip_cidr" | cut -d'/' -f2)

    # 简单验证 CIDR 掩码
    if ! [[ "$cidr_mask" =~ ^[0-9]+$ ]] || [ "$cidr_mask" -lt 0 ] || [ "$cidr_mask" -gt 32 ]; then
        error "无效的 CIDR 掩码: $cidr_mask"
        return 1
    fi

    # 使用 ipcalc 或手动计算（如果ipcalc不存在）
    if command -v ipcalc &> /dev/null; then
        echo $(ipcalc -n "$ip_cidr" | awk '/Network:/ {print $2}')
    else
        IFS='.' read -r octet1 octet2 octet3 octet4 <<< "$ip_addr"
        local mask=$(( 0xffffffff << (32 - cidr_mask) ))
        local ip_int=$(( (octet1 << 24) + (octet2 << 16) + (octet3 << 8) + octet4 ))
        local network_int=$(( ip_int & mask ))
        local network_octet1=$(( (network_int >> 24) & 255 ))
        local network_octet2=$(( (network_int >> 16) & 255 ))
        local network_octet3=$(( (network_int >> 8) & 255 ))
        local network_octet4=$(( network_int & 255 ))
        echo "${network_octet1}.${network_octet2}.${network_octet3}.${network_octet4}/${cidr_mask}"
    fi
}

# 检测局域网段和网关
detect_lan_subnet_gateway() {
    log "尝试自动检测局域网参数..."
    local default_iface=$(get_default_interface)
    if [[ -z "$default_iface" ]]; then
        error "无法自动检测默认网络接口，请手动指定。"
        return 1
    fi

    # 检查网卡是否支持混杂模式并开启
    if ! ip link show "$default_iface" | grep -q "PROMISC"; then
        log "检测到网卡 $default_iface 未开启混杂模式，正在尝试开启..."
        ip link set "$default_iface" promisc on
        if [ $? -ne 0 ]; then
            error "无法开启网卡 $default_iface 的混杂模式，请手动检查权限或网卡状态。"
            return 1
        fi
        success "网卡 $default_iface 混杂模式已开启。"
    else
        log "网卡 $default_iface 混杂模式已开启。"
    fi

    local ip_cidr=$(ip addr show dev "$default_iface" | awk '/inet / {print $2}' | head -n 1)
    if [[ -z "$ip_cidr" ]]; then
        error "无法获取接口 $default_iface 的 IP 信息。请确认网卡配置。"
        return 1
    fi
    log "检测到 IP CIDR: $ip_cidr"

    if ! SUBNET=$(calculate_network_address "$ip_cidr"); then
        error "计算子网失败。"
        return 1
    fi
    GATEWAY=$(ip route show default | awk '/default/ {print $3}')

    if [[ -z "$SUBNET" || -z "$GATEWAY" ]]; then
        error "自动检测局域网信息失败。请手动输入参数。"
        return 1
    fi

    success "自动检测成功！"
    echo "  子网: \033[32m$SUBNET\033[0m"
    echo "  网关: \033[32m$GATEWAY\033[0m"
    echo "  默认网络接口: \033[32m$default_iface\033[0m"
    DETECTED_SUBNET="$SUBNET"
    DETECTED_GATEWAY="$GATEWAY"
    DETECTED_INTERFACE="$default_iface"
    return 0
}

# 检查子网是否与现有 Docker 网络冲突
check_network_conflict() {
    local subnet=$1
    log "检查子网 $subnet 是否与现有 Docker 网络冲突..."
    local conflict_networks
    conflict_networks=$(docker network ls --format '{{.Name}}' | while read -r net; do
        docker network inspect "$net" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null | grep -q "$subnet" && echo "$net"
    done)
    if [[ -n "$conflict_networks" ]]; then
        error "子网 $subnet 与以下 Docker 网络冲突："
        echo "$conflict_networks"
        return 1
    fi
    log "子网 $subnet 未发现冲突。"
    return 0
}

# 验证 IP 是否在子网内
validate_ip_in_subnet() {
    local ip=$1
    local subnet=$2
    local network=$(echo "$subnet" | cut -d'/' -f1)
    local cidr=$(echo "$subnet" | cut -d'/' -f2)

    # 验证 IP 格式 (简单的正则匹配)
    if ! [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        error "无效的 IP 地址格式: $ip (必须为 x.x.x.x)"
        return 1
    fi

    # 使用 awk 来进行IP范围检查，更健壮
    local ip_parts=( $(echo "$ip" | tr '.' ' ') )
    local net_parts=( $(echo "$network" | tr '.' ' ') )

    for i in {0..3}; do
        if (( ${ip_parts[i]} < 0 || ${ip_parts[i]} > 255 )); then
            error "IP 地址 $ip 包含无效的字节。"
            return 1
        fi
        if (( ${net_parts[i]} < 0 || ${net_parts[i]} > 255 )); then
            error "子网 $network 包含无效的字节。"
            return 1
        fi
    done

    # 再次尝试用 ipcalc 验证，如果不存在则进行位运算
    if command -v ipcalc &> /dev/null; then
        if ! ipcalc -c "$ip" "$subnet" &> /dev/null; then
            error "IP $ip 不在子网 $subnet 内。"
            return 1
        fi
    else
        # 手动位运算检查
        local ip_int=$(( (${ip_parts[0]} << 24) + (${ip_parts[1]} << 16) + (${ip_parts[2]} << 8) + ${ip_parts[3]} ))
        local network_int=$(( (${net_parts[0]} << 24) + (${net_parts[1]} << 16) + (${net_parts[2]} << 8) + ${net_parts[3]} ))
        local mask=$(( 0xFFFFFFFF << (32 - cidr) )) # 32位掩码

        if (( (ip_int & mask) != (network_int & mask) )); then
            error "IP $ip 不在子网 $subnet 内。"
            return 1
        fi
    fi

    return 0
}

# 检查 IP 是否被占用
check_ip_occupied() {
    local ip=$1
    log "检查 IP $ip 是否被占用 (ping 测试)..."
    if ping -c 1 -W 1 "$ip" >/dev/null 2>&1; then
        error "IP $ip 已被占用，请选择其他 IP。"
        return 1
    fi
    log "IP $ip 未被占用。"
    return 0
}

# 检查端口是否被占用
check_port_usage() {
    local port=$1
    log "检查端口 $port 是否被占用..."
    if command -v ss &> /dev/null; then
        if ss -tuln | grep -q ":$port"; then
            error "端口 $port 已经被占用，请选择其他端口。"
            return 1
        fi
    elif command -v netstat &> /dev/null; then
        if netstat -tuln | grep -q ":$port"; then
            error "端口 $port 已经被占用，请选择其他端口。"
            return 1
        fi
    else
        log "缺少 ss 或 netstat 命令，无法精确检查端口占用情况，请手动确认。"
        return 0
    fi
    log "端口 $port 未被占用。"
    return 0
}

# 获取宿主机 IP
get_host_ip() {
    local ip_addr
    # 优先获取非 Docker 桥接网卡 IP
    ip_addr=$(ip -o -4 addr show | awk '!/^[0-9]*: ?lo|link\/ether|docker0/ {gsub("/", " "); print $4}' | grep -v '172.*' | head -n1)
    if [[ -z "$ip_addr" ]]; then
        ip_addr=$(hostname -I | awk '{print $1}')
    fi
    if [[ -z "$ip_addr" ]]; then
        echo "<无法自动获取宿主机IP>"
    else
        echo "$ip_addr"
    fi
}

# 检查 LuCI 和 uhttpd 状态并在容器内安装/启动
check_luci_status() {
    log "检查 OpenWrt 容器内 LuCI 和 uhttpd 状态..."
    # 检查 LuCI 是否安装
    if ! docker exec openwrt /bin/sh -c "opkg list-installed | grep -q luci"; then
        log "OpenWrt 容器内 LuCI 未安装，正在尝试安装..."
        if ! docker exec openwrt /bin/sh -c "opkg update && opkg install luci-ssl luci-app-opkg luci-base"; then
            error "LuCI 安装失败！请手动进入容器检查网络或镜像源。"
            return 1
        fi
        success "LuCI 已成功安装。"
    else
        log "LuCI 已安装。"
    fi

    # 检查 uhttpd 服务是否运行
    if ! docker exec openwrt /bin/sh -c "ps | grep -q '[u]httpd'"; then # 使用 [] 避免 grep 自身
        log "uhttpd 服务未运行，正在尝试启动..."
        if ! docker exec openwrt /bin/sh -c "/etc/init.d/uhttpd start && /etc/init.d/uhttpd enable"; then
            error "uhttpd 启动失败！请检查容器状态。"
            return 1
        fi
        success "uhttpd 服务已启动。"
    else
        log "uhttpd 服务正在运行。"
    fi
    return 0
}

# 验证 Web 界面可访问性
verify_web_access() {
    local ip=$1
    local port=$2
    log "验证 Web 界面可访问性: http://$ip:$port..."
    if curl -s -m 5 "http://$ip:$port" >/dev/null; then
        success "Web 界面可访问！"
        return 0
    else
        error "无法访问 Web 界面 http://$ip:$port。"
        echo -e "\033[33m可能原因：防火墙阻止、LuCI 未启动、或网络配置错误。\033[0m"
        return 1
    fi
}

# 清理残留 Docker 资源
cleanup_residual() {
    log "清理可能残留的 Docker 资源 (容器 'openwrt' 及网络)..."
    docker stop openwrt >/dev/null 2>&1
    docker rm openwrt >/dev/null 2>&1
    docker network rm openwrt_net >/dev/null 2>&1
    docker network rm openwrt_bridge >/dev/null 2>&1
    # 谨慎使用 docker system prune -f，它会删除所有停止的容器、未使用的网络、悬空镜像等
    # read -rp "是否执行 'docker system prune -f' 清理所有 Docker 冗余数据？(谨慎操作，会删除所有未使用的容器/镜像/网络) [y/N]: " PRUNE_CONFIRM
    # if [[ "$PRUNE_CONFIRM" =~ [Yy] ]]; then
    #     log "正在清理 Docker 冗余数据..."
    #     docker system prune -f
    # fi
    success "Docker 容器 'openwrt' 及相关网络已清理完毕。"
}

# 尝试拉取镜像
pull_image() {
    local image=$1
    log "正在拉取镜像 '$image'..."
    if docker pull "$image" 2>&1 | tee /tmp/docker-pull.log; then
        return 0
    else
        error "镜像拉取失败：$image"
        cat /tmp/docker-pull.log
        return 1
    fi
}

# 显示系统及Docker信息
show_system_info() {
    clear
    echo -e "\033[34m====================================\033[0m"
    echo -e "          \033[36mOpenWrt Docker 部署工具\033[0m"
    echo -e "\033[34m====================================\033[0m"
    echo -e "系统架构：\033[32m$ARCH_DESC ($ARCH)\033[0m"
    echo -e "默认镜像：\033[33m$DOCKER_IMAGE\033[0m"
    if [ -n "$ALIYUN_IMAGE" ]; then
        echo -e "阿里云镜像：\033[33m$ALIYUN_IMAGE\033[0m"
    fi
    if [ -n "$FALLBACK_IMAGE" ]; then
        echo -e "备选镜像：\033[33m$FALLBACK_IMAGE\033[0m"
    fi
    echo -e "宿主机内核版本：\033[32m$(uname -r)\033[0m"
    echo -e "Docker 版本：\033[32m$(docker --version | head -n1)\033[0m"
    local kernel_major=$(uname -r | cut -d'.' -f1)
    local kernel_minor=$(uname -r | cut -d'.' -f2)
    if (( kernel_major < 5 || (kernel_major == 5 && kernel_minor < 4) )); then
        echo -e "\033[33m警告：您的宿主机内核版本 $(uname -r) 较旧。建议升级到 5.4 或更高版本，以确保 OpenWrt 容器的兼容性和稳定性。\033[0m"
    fi
    echo -e "\033[34m====================================\033[0m"
}

# --- 脚本主执行流程 ---

check_root
check_docker_installed
check_environment
set_architecture_and_images
show_system_info

# 主控制菜单
while true; do
    echo ""
    echo -e "\033[36m[ 主菜单 ]\033[0m"
    echo "1) 安装 OpenWrt 容器"
    echo "2) 完全卸载 OpenWrt 容器及相关网络"
    echo "3) 查看 OpenWrt 容器状态"
    echo "4) 查看 OpenWrt 容器实时日志"
    echo "5) 显示 OpenWrt Web/SSH 登录地址"
    echo "6) 退出脚本"
    read -rp "请输入操作编号 (1-6): " ACTION

    case "$ACTION" in
        1)
            # --- 安装逻辑 ---
            echo -e "\n\033[33m» 镜像源选择 «\033[0m"
            echo "1) Docker Hub（默认）"
            if [ -n "$ALIYUN_IMAGE" ]; then
                echo "2) 阿里云镜像仓库（国内推荐）"
            fi
            read -rp "请选择镜像源 [1/2, 默认2]: " IMAGE_SOURCE
            IMAGE_SOURCE=${IMAGE_SOURCE:-2}
            if [ "$IMAGE_SOURCE" -eq 2 ] && [ -n "$ALIYUN_IMAGE" ]; then
                SELECTED_IMAGE="$ALIYUN_IMAGE"
            else
                SELECTED_IMAGE="$DOCKER_IMAGE"
            fi
            log "已选择镜像: $SELECTED_IMAGE"

            echo -e "\n\033[33m» 网络模式选择 «\033[0m"
            echo "1) Bridge 模式（默认Docker网络，适合测试，宿主机端口映射）"
            echo "2) Macvlan 模式（推荐：容器获取独立IP，旁路由首选）"
            read -rp "请选择网络类型 [1/2, 默认2]: " NET_MODE
            NET_MODE=${NET_MODE:-2}

            # 默认网卡和网络参数初始化
            DEFAULT_NIC=$(get_default_interface)
            if [ -z "$DEFAULT_NIC" ]; then
                error "无法自动检测默认网卡，请手动输入。"
                ip link show
                read -rp "请输入网卡名称（例如 eth0）： " DEFAULT_NIC
                if [ -z "$DEFAULT_NIC" ] || ! ip link show "$DEFAULT_NIC" >/dev/null 2>&1; then
                    error "无效的网卡名称，安装中止。"
                    continue
                fi
            fi
            
            MACVLAN_IP=""
            WEB_PORT="8080"
            SSH_PORT="2222"
            DEFAULT_SUBNET="192.168.3.0/24" # 示例默认值
            DEFAULT_GATEWAY="192.168.3.1" # 示例默认值

            if [ "$NET_MODE" -eq 2 ]; then
                echo -e "\n\033[33m» Macvlan 参数配置 «\033[0m"
                if detect_lan_subnet_gateway; then
                    read -rp "是否使用自动检测的参数？[Y/n]: " USE_DETECTED
                    if [[ ! "$USE_DETECTED" =~ [Nn] ]]; then
                        SUBNET="$DETECTED_SUBNET"
                        GATEWAY="$DETECTED_GATEWAY"
                        TARGET_NIC="$DETECTED_INTERFACE"
                    else
                        read -rp "请输入子网地址 (例如: 192.168.1.0/24) [默认: $DEFAULT_SUBNET]: " SUBNET
                        SUBNET=${SUBNET:-$DEFAULT_SUBNET}
                        read -rp "请输入网关地址 (例如: 192.168.1.1) [默认: $DEFAULT_GATEWAY]: " GATEWAY
                        GATEWAY=${GATEWAY:-$DEFAULT_GATEWAY}
                        read -rp "请输入要绑定到的物理网卡名称 (例如: eth0) [默认: $DEFAULT_NIC]: " TARGET_NIC
                        TARGET_NIC=${TARGET_NIC:-$DEFAULT_NIC}
                    fi
                else
                    error "自动检测失败，请手动输入参数。"
                    read -rp "请输入子网地址 (例如: 192.168.1.0/24) [默认: $DEFAULT_SUBNET]: " SUBNET
                    SUBNET=${SUBNET:-$DEFAULT_SUBNET}
                    read -rp "请输入网关地址 (例如: 192.168.1.1) [默认: $DEFAULT_GATEWAY]: " GATEWAY
                    GATEWAY=${GATEWAY:-$DEFAULT_GATEWAY}
                    read -rp "请输入要绑定到的物理网卡名称 (例如: eth0) [默认: $DEFAULT_NIC]: " TARGET_NIC
                    TARGET_NIC=${TARGET_NIC:-$DEFAULT_NIC}
                fi

                if ! ip link show "$TARGET_NIC" >/dev/null 2>&1; then
                    error "网卡 $TARGET_NIC 不存在！请确认网卡名称并重试。"
                    ip link show
                    continue
                fi
                # 再次尝试开启混杂模式，确保万无一失
                if ! ip link show "$TARGET_NIC" | grep -q "PROMISC"; then
                    log "正在开启网卡 $TARGET_NIC 的混杂模式..."
                    ip link set "$TARGET_NIC" promisc on
                    if [ $? -ne 0 ]; then
                        error "无法开启网卡 $TARGET_NIC 的混杂模式，请手动检查权限或网卡状态。安装中止。"
                        continue
                    fi
                    success "网卡 $TARGET_NIC 混杂模式已开启。"
                fi

                read -rp "请输入 OpenWrt 容器静态 IP 地址 (例如: 192.168.3.181, 确保在 $SUBNET 网段内且未被占用): " MACVLAN_IP
                if ! validate_ip_in_subnet "$MACVLAN_IP" "$SUBNET"; then
                    error "IP 地址验证失败，安装中止。"
                    continue
                fi
                if ! check_ip_occupied "$MACVLAN_IP"; then
                    error "IP 地址已被占用，安装中止。"
                    continue
                fi

                if ! check_network_conflict "$SUBNET"; then
                    read -rp "子网与现有 Docker 网络冲突，是否尝试删除冲突网络 'openwrt_net' (可能影响其他容器)？[y/N]: " DELETE_NET
                    if [[ "$DELETE_NET" =~ [Yy] ]]; then
                        log "正在尝试删除冲突网络 'openwrt_net'..."
                        docker network rm openwrt_net >/dev/null 2>&1 || {
                            error "删除冲突网络失败，请手动删除后重试。"
                            continue
                        }
                        success "冲突网络 'openwrt_net' 已删除。"
                    else
                        error "请手动删除冲突网络或选择其他子网后重试。安装中止。"
                        continue
                    fi
                fi

                if ! docker network inspect openwrt_net >/dev/null 2>&1; then
                    log "正在创建 Macvlan 网络 'openwrt_net'..."
                    if ! docker network create -d macvlan \
                        --subnet="$SUBNET" \
                        --gateway="$GATEWAY" \
                        -o parent="$TARGET_NIC" \
                        openwrt_net; then
                        error "Macvlan 网络创建失败！请检查参数或网卡名称。"
                        echo -e "\033[33m建议：运行 'docker network ls' 检查现有网络，或验证网卡 '$TARGET_NIC' 是否存在。\033[0m"
                        continue
                    fi
                    success "Macvlan 网络 'openwrt_net' 创建成功。"
                else
                    log "Macvlan 网络 'openwrt_net' 已存在。"
                fi
                NET_NAME="openwrt_net"
            else # Bridge 模式
                if ! docker network inspect openwrt_bridge >/dev/null 2>&1; then
                    log "正在创建 Bridge 网络 'openwrt_bridge'..."
                    if ! docker network create openwrt_bridge; then
                        error "Bridge 网络创建失败！"
                        continue
                    fi
                    success "Bridge 网络 'openwrt_bridge' 创建成功。"
                else
                    log "Bridge 网络 'openwrt_bridge' 已存在。"
                fi
                NET_NAME="openwrt_bridge"
            fi

            echo -e "\n\033[33m» 端口映射配置 «\033[0m"
            read -rp "输入映射到宿主机的 Web 管理端口 (容器内80端口) [默认: $WEB_PORT]: " USER_WEB_PORT
            WEB_PORT=${USER_WEB_PORT:-$WEB_PORT}
            if ! check_port_usage "$WEB_PORT"; then
                error "Web 管理端口 $WEB_PORT 冲突，安装中止。"
                continue
            fi
            read -rp "输入映射到宿主机的 SSH 管理端口 (容器内22端口) [默认: $SSH_PORT]: " USER_SSH_PORT
            SSH_PORT=${USER_SSH_PORT:-$SSH_PORT}
            if ! check_port_usage "$SSH_PORT"; then
                error "SSH 管理端口 $SSH_PORT 冲突，安装中止。"
                continue
            fi
            PORT_MAP="-p $WEB_PORT:80 -p $SSH_PORT:22"

            echo -e "\n\033[33m» 数据持久化配置 «\033[0m"
            read -rp "是否需要挂载配置文件到宿主机，实现数据持久化？[y/N]: " NEED_VOLUME
            if [[ "$NEED_VOLUME" =~ [Yy] ]]; then
                read -rp "请输入宿主机配置存储路径 [默认: /opt/openwrt/config]: " CONFIG_PATH
                CONFIG_PATH=${CONFIG_PATH:-/opt/openwrt/config}
                mkdir -p "$CONFIG_PATH"
                if [ $? -ne 0 ]; then
                    error "无法创建配置存储目录 $CONFIG_PATH，请检查权限。安装中止。"
                    continue
                fi
                chmod 755 "$CONFIG_PATH"
                VOLUME_MAP="-v $CONFIG_PATH:/etc/config"
                log "配置文件将挂载到宿主机路径: $CONFIG_PATH"
            else
                VOLUME_MAP=""
                log "未启用数据持久化，容器删除后配置将丢失。"
            fi

            # 检查同名容器是否已存在
            if docker ps -a --format '{{.Names}}' | grep -q "^openwrt$"; then
                echo -e "\n\033[33m警告：名为 'openwrt' 的容器已存在。\033[0m"
                read -rp "是否要先停止并删除现有容器再继续安装？[y/N]: " REMOVE_EXISTING
                if [[ "$REMOVE_EXISTING" =~ [Yy] ]]; then
                    log "正在停止并删除现有容器 'openwrt'..."
                    docker stop openwrt >/dev/null 2>&1
                    docker rm openwrt >/dev/null 2>&1
                    success "现有容器已删除。"
                else
                    error "安装中止。"
                    continue
                fi
            fi

            # 尝试拉取镜像，如果失败则尝试备用镜像
            if ! pull_image "$SELECTED_IMAGE"; then
                if [ -n "$FALLBACK_IMAGE" ]; then
                    echo -e "\033[33m尝试拉取备选镜像 '$FALLBACK_IMAGE'...\033[0m"
                    if ! pull_image "$FALLBACK_IMAGE"; then
                        error "所有镜像拉取失败！"
                        echo -e "\033[33m请检查您的网络连接、Docker 配置 (如镜像加速器) 或手动访问 Docker Hub 确认镜像标签是否存在。\033[0m"
                        echo -e "\033[33m建议：手动配置 Docker 镜像加速器 (编辑 /etc/docker/daemon.json) 后重启 Docker。\033[0m"
                        cleanup_residual
                        read -rp "是否重试拉取镜像？[y/N]: " RETRY_PULL
                        if [[ "$RETRY_PULL" =~ [Yy] ]]; then
                            continue
                        else
                            error "安装中止。"
                            continue
                        fi
                    else
                        SELECTED_IMAGE="$FALLBACK_IMAGE"
                    fi
                else
                    error "当前架构没有可用的备选镜像，安装中止。"
                    cleanup_residual
                    continue
                fi
            fi

            log "正在启动 OpenWrt 容器..."
            DOCKER_RUN_CMD="docker run -d --name openwrt --restart unless-stopped --privileged $PORT_MAP $VOLUME_MAP"
            if [ "$NET_MODE" -eq 2 ]; then
                DOCKER_RUN_CMD+=" --network $NET_NAME --ip $MACVLAN_IP"
            else
                DOCKER_RUN_CMD+=" --network $NET_NAME"
            fi
            DOCKER_RUN_CMD+=" $SELECTED_IMAGE /sbin/init"

            log "执行 Docker 运行命令: $DOCKER_RUN_CMD"
            if ! eval "$DOCKER_RUN_CMD" 2>&1 | tee /tmp/docker-run.log; then
                error "容器启动失败！"
                cat /tmp/docker-run.log
                echo -e "\033[33m请检查以下可能原因：\033[0m"
                echo -e "  1. \033[31m内核不兼容\033[0m：宿主机内核 $(uname -r) 可能不支持 OpenWrt 容器运行。"
                echo -e "  2. \033[31m权限问题\033[0m：确保 `--privileged` 参数已使用，且 Docker 服务有足够权限。"
                if [ "$NET_MODE" -eq 2 ]; then
                    echo -e "  3. \033[31m网络配置错误\033[0m：验证网卡 '$TARGET_NIC' 和 IP '$MACVLAN_IP' 是否正确，以及 Macvlan 网络是否创建成功。"
                    echo -e "  4. \033[31m网卡混杂模式\033[0m：请确认网卡 $TARGET_NIC 混杂模式已开启。"
                fi
                echo -e "  5. \033[31m镜像问题\033[0m：尝试其他镜像标签或版本，例如备选镜像 `$FALLBACK_IMAGE`。"
                echo -e "\033[33m调试命令：\033[0m"
                echo -e "  - \033[32m查看容器日志：\033[0m docker logs openwrt"
                echo -e "  - \033[32m检查容器状态：\033[0m docker ps -a"
                cleanup_residual
                continue
            fi
            success "OpenWrt 容器已成功启动！"
            if [ "$NET_MODE" -eq 2 ]; then
                echo -e "容器 IP: \033[32m$MACVLAN_IP\033[0m"
            fi
            echo -e "进入容器命令行：\n\033[32mdocker exec -it openwrt /bin/sh\033[0m"

            log "等待容器初始化 (约10秒)..."
            sleep 10

            log "检查容器状态..."
            if ! docker ps -q --filter name=openwrt >/dev/null; then
                error "容器启动后未保持运行状态！"
                docker ps -a
                echo -e "\033[33m请查看容器日志获取详细错误信息：\033[0m"
                docker logs openwrt
                cleanup_residual
                continue
            fi

            log "配置 OpenWrt 环境 (尝试安装 LuCI 和启动 uhttpd)..."
            # 移除可能导致启动问题的 preinit 行
            docker exec openwrt /bin/sh -c "sed -i 's/.*preinit.*//g' /etc/preinit" >/dev/null 2>&1 || log "警告：无法修改 preinit 配置，可能导致首次启动问题。"
            
            if ! check_luci_status; then
                error "LuCI 配置失败，可能需要手动干预。"
                echo -e "\033[33m手动操作指南：\033[0m"
                echo -e "  1. \033[32m进入容器：\033[0m docker exec -it openwrt /bin/sh"
                echo -e "  2. \033[32m更新软件包列表：\033[0m opkg update"
                echo -e "  3. \033[32m安装 LuCI：\033[0m opkg install luci-ssl luci-app-opkg luci-base"
                echo -e "  4. \033[32m启动 Web 服务：\033[0m /etc/init.d/uhttpd start && /etc/init.d/uhttpd enable"
            else
                success "OpenWrt 容器基础环境配置完成。"
            fi

            log "验证容器部署情况..."
            docker ps -a --filter name=openwrt --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}"
            if [ "$NET_MODE" -eq 2 ]; then
                if ping -c 1 -W 2 "$MACVLAN_IP" >/dev/null 2>&1; then
                    success "容器 IP $MACVLAN_IP 可 Ping 通。"
                else
                    error "无法 Ping 通容器 IP $MACVLAN_IP，请检查网络配置。"
                fi
                verify_web_access "$MACVLAN_IP" "$WEB_PORT"
            else
                HOST_IP=$(get_host_ip)
                if [[ "$HOST_IP" == "<无法自动获取宿主机IP>" ]]; then
                    error "无法获取宿主机 IP，请手动检查宿主机网络。"
                else
                    verify_web_access "$HOST_IP" "$WEB_PORT"
                fi
            fi

            echo -e "\n\033[36mOpenWrt 容器已成功部署！\033[0m"
            echo -e "\033[36m正在显示登录地址...请稍候。\033[0m"
            sleep 2
            bash "$0" 5 # 调用显示登录地址的逻辑
            ;;

        2)
            # --- 卸载逻辑 ---
            echo -e "\n\033[33m警告：这将停止并删除名为 'openwrt' 的 Docker 容器及其相关的所有 Macvlan/Bridge 网络 'openwrt_net' 和 'openwrt_bridge'。\033[0m"
            read -rp "确定要完全卸载 OpenWrt 容器吗？此操作不可逆！[y/N]: " CONFIRM_UNINSTALL
            if [[ "$CONFIRM_UNINSTALL" =~ [Yy] ]]; then
                log "正在执行完全卸载操作..."
                cleanup_residual
                
                # 提示用户手动删除持久化目录
                if [[ -n "$CONFIG_PATH" && -d "$CONFIG_PATH" ]]; then
                    echo -e "\033[33m请注意：您之前设置的配置文件挂载目录 \033[36m$CONFIG_PATH\033[33m 未被自动删除。\033[0m"
                    read -rp "是否要手动删除此目录？[y/N]: " DELETE_VOLUME_DIR
                    if [[ "$DELETE_VOLUME_DIR" =~ [Yy] ]]; then
                        log "请手动执行：rm -rf $CONFIG_PATH"
                    fi
                fi
                success "OpenWrt 容器及相关网络已成功清除！"
            else
                log "卸载操作已取消。"
            fi
            ;;

        3)
            # --- 查看容器状态 ---
            echo -e "\n\033[36m--- OpenWrt 容器状态 ---\033[0m"
            if ! docker ps -a --filter name=openwrt --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}"; then
                error "未找到名为 'openwrt' 的容器。"
            fi
            echo -e "\033[34m------------------------\033[0m"
            ;;

        4)
            # --- 查看实时日志 ---
            echo -e "\n\033[36m--- OpenWrt 容器实时日志 (按 Ctrl+C 退出) ---\033[0m"
            if ! docker logs -f openwrt; then
                error "无法获取日志，容器 'openwrt' 可能不存在或未运行。"
            fi
            echo -e "\033[34m------------------------\033[0m"
            echo -e "\033[33m提示：如果日志持续显示 'Press [f] to continue' 或 'Please press Enter to activate this console.' 等字样，\033[0m"
            echo -e "\033[33m这通常表示 OpenWrt 固件镜像未进行优化。您可能需要进入容器手动配置或等待其完成启动。\033[0m"
            echo -e "\033[33m手动检查方法：\033[0m"
            echo -e "  1. \033[32m进入容器：\033[0m docker exec -it openwrt /bin/sh"
            echo -e "  2. \033[32m检查 Web 服务：\033[0m /etc/init.d/uhttpd status"
            echo -e "  3. \033[32m如果未运行，尝试启动：\033[0m /etc/init.d/uhttpd start"
            ;;

        5)
            # --- 查看登录地址 ---
            echo -e "\n\033[36m正在查询 OpenWrt 容器登录信息...\033[0m"
            CONTAINER_ID=$(docker ps -q --filter name=openwrt)
            if [ -z "$CONTAINER_ID" ]; then
                error "未找到正在运行的名为 'openwrt' 的容器。请先安装或启动容器。"
                continue
            fi
            
            INSPECT_JSON=$(docker inspect "$CONTAINER_ID")
            
            # 使用 jq 优先解析，如果未安装则回退到 grep/awk
            NET_INFO=""
            WEB_HOST_PORT=""
            SSH_HOST_PORT=""

            if command -v jq &> /dev/null; then
                NET_INFO=$(echo "$INSPECT_JSON" | jq -r '.[0].NetworkSettings.Networks | keys[] as $k | if .[$k].IPAddress and .[$k].IPAddress != "" then "\($k):\(.[$k].IPAddress)" else empty end' | head -n 1)
                WEB_HOST_PORT=$(echo "$INSPECT_JSON" | jq -r '.[0].HostConfig.PortBindings."80/tcp"[0].HostPort // empty')
                SSH_HOST_PORT=$(echo "$INSPECT_JSON" | jq -r '.[0].HostConfig.PortBindings."22/tcp"[0].HostPort // empty')
            else
                log "提示：未安装 jq，将使用 grep/awk 尝试解析，结果可能不精确。建议安装 jq (例: apt install jq)。"
                # 尝试从 Networks 部分提取网络名称和 IP
                NET_INFO=$(echo "$INSPECT_JSON" | grep -E '"Name": "(openwrt_net|openwrt_bridge)"' -A 4 | grep '"IPAddress":' | head -n 1 | sed -n 's/.*"IPAddress": "\(.*\)".*/\1/p')
                # 还需要获取网络名称来判断是 Macvlan 还是 Bridge
                NETWORK_NAME_RAW=$(echo "$INSPECT_JSON" | grep -E '"Name": "(openwrt_net|openwrt_bridge)"' | head -n 1 | sed -n 's/.*"Name": "\(.*\)".*/\1/p')
                if [[ -n "$NET_INFO" && -n "$NETWORK_NAME_RAW" ]]; then
                    NET_INFO="${NETWORK_NAME_RAW}:${NET_INFO}"
                else
                    NET_INFO="" # 清空以避免不完整信息
                fi

                # 从 PortBindings 部分提取宿主机映射端口
                WEB_HOST_PORT=$(echo "$INSPECT_JSON" | grep -A 2 '"80/tcp"' | grep '"HostPort":' | sed -n 's/.*"HostPort": "\(.*\)".*/\1/p' | head -n 1)
                SSH_HOST_PORT=$(echo "$INSPECT_JSON" | grep -A 2 '"22/tcp"' | grep '"HostPort":' | sed -n 's/.*"HostPort": "\(.*\)".*/\1/p' | head -n 1)
            fi
            
            NETWORK_NAME=$(echo "$NET_INFO" | cut -d':' -f1)
            CONTAINER_IP=$(echo "$NET_INFO" | cut -d':' -f2)
            
            ACCESS_IP=""
            ACCESS_MODE=""
            
            if [ "$NETWORK_NAME" == "openwrt_net" ]; then
                ACCESS_IP="$CONTAINER_IP"
                ACCESS_MODE="Macvlan (独立IP)"
            elif [ "$NETWORK_NAME" == "openwrt_bridge" ]; then
                HOST_IP=$(get_host_ip)
                ACCESS_IP="$HOST_IP"
                ACCESS_MODE="Bridge (通过宿主机IP访问)"
            else
                error "无法确定容器的网络模式或IP地址。请检查容器配置或日志。"
                continue
            fi
            
            echo -e "\n\033[34m--- OpenWrt 登录信息 ---\033[0m"
            echo -e "网络模式 : \033[33m$ACCESS_MODE\033[0m"
            if [ "$NETWORK_NAME" == "openwrt_bridge" ]; then
                echo -e "宿主机 IP : \033[32m$HOST_IP\033[0m"
                echo -e "容器桥接IP: \033[37m$CONTAINER_IP (通常仅用于容器间通信，外部通过宿主机IP+端口访问)\033[0m"
            else
                echo -e "容器 IP  : \033[32m$ACCESS_IP\033[0m"
            fi
            
            if [ -n "$WEB_HOST_PORT" ]; then
                echo -e "Web 访问 : \033[32mhttp://$ACCESS_IP:$WEB_HOST_PORT\033[0m"
            else
                echo -e "Web 访问 : \033[37m未映射 Web 管理端口 (容器80端口)，请检查安装配置。\033[0m"
            fi
            echo -e "Web 用户名: \033[32mroot\033[0m"
            echo -e "Web 密码  : \033[33m(通常为空，首次登录后设置；或尝试 'password'，具体取决于镜像)\033[0m"
            
            if [ -n "$SSH_HOST_PORT" ]; then
                echo -e "SSH 连接 : \033[32mssh root@$ACCESS_IP -p $SSH_HOST_PORT\033[0m"
            else
                echo -e "SSH 连接 : \033[37m未映射 SSH 端口 (容器22端口)，请检查安装配置。\033[0m"
            fi
            echo -e "SSH 密码  : \033[33m(与 Web 密码相同)\033[0m"
            echo -e "\033[34m------------------------\033[0m"
            echo -e "\033[33m提示：如果无法访问 Web 界面，请检查：\033[0m"
            echo -e "  1. 宿主机防火墙是否开放了 $WEB_HOST_PORT 端口。"
            echo -e "  2. 容器内部 LuCI (Web 服务) 是否正常运行。可以进入容器 (docker exec -it openwrt /bin/sh) 后执行：/etc/init.d/uhttpd status 或 /etc/init.d/uhttpd start"
            echo -e "  3. 如果是 Macvlan 模式，请确保宿主机网卡混杂模式已开启 (ip link set <网卡名称> promisc on)。"
            ;;

        6)
            # --- 退出脚本 ---
            echo -e "\n\033[33m感谢使用 OpenWrt Docker 一键管理脚本，再见！\033[0m"
            exit 0
            ;;

        *)
            # --- 无效输入 ---
            error "无效的输入，请重新选择！"
            ;;
    esac
done
