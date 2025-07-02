#!/bin/bash

# ===========================
# OpenWrt Docker 一键管理脚本
# 支持架构：x86_64/ARM64/ARMv7
# ===========================

# 权限检查
if [ "$EUID" -ne 0 ]; then
    echo -e "\033[31m请使用 root 用户运行本脚本！\033[0m"
    exit 1
fi

# Docker 存在性检查
if ! command -v docker &> /dev/null; then
    echo -e "\033[31m检测到 Docker 未安装，请先执行以下命令安装：\033[0m"
    echo "curl -fsSL https://get.docker.com | bash -s docker --mirror Aliyun"
    exit 1
fi

# 环境检查
log() {
    echo -e "\033[33m[$(date +'%Y-%m-%d %H:%M:%S')] $1\033[0m"
}
log "检查 shell 环境..."
if [ -z "$BASH_VERSION" ]; then
    echo -e "\033[31m脚本需要 bash 运行，请确保使用 /bin/bash 执行！\033[0m"
    echo "尝试：bash $0"
    exit 1
fi
log "Bash 版本：$BASH_VERSION"
log "Grep 版本：$(grep --version | head -n1)"

# 架构识别与镜像配置
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)
        DOCKER_IMAGE="sulinggg/openwrt:x86_64"
        ALIYUN_IMAGE="registry.cn-shanghai.aliyuncs.com/suling/openwrt:x86_64"
        FALLBACK_IMAGE="sulinggg/openwrt:openwrt-18.06-k5.4"
        ARCH_DESC="Intel/AMD 64位设备"
        ;;
    aarch64 | arm64)
        DOCKER_IMAGE="sulinggg/openwrt:armv8"
        ALIYUN_IMAGE="registry.cn-shanghai.aliyuncs.com/suling/openwrt:armv8"
        FALLBACK_IMAGE="sulinggg/openwrt:rpi4"
        ARCH_DESC="ARM64 设备（树莓派4B/N1等）"
        ;;
    armv7l)
        DOCKER_IMAGE="sulinggg/openwrt:armv7"
        ALIYUN_IMAGE="registry.cn-shanghai.aliyuncs.com/suling/openwrt:armv7"
        FALLBACK_IMAGE=""
        ARCH_DESC="ARMv7 设备（NanoPi R2S/R4S等）"
        ;;
    *)
        echo -e "\033[31m不支持的架构：$ARCH\033[0m"
        exit 1
        ;;
esac

# 网络配置参数
DEFAULT_SUBNET="192.168.3.0/24"
DEFAULT_GATEWAY="192.168.3.18"

# 获取默认网络接口
get_default_interface() {
    ip route show default | awk '/default/ {print $5}'
}

# 计算网络地址
calculate_network_address() {
    local ip_cidr=$1
    local ip_addr=$(echo "$ip_cidr" | cut -d'/' -f1)
    local cidr_mask=$(echo "$ip_cidr" | cut -d'/' -f2)
    IFS='.' read -r octet1 octet2 octet3 octet4 <<< "$ip_addr"
    local mask=$(( 0xffffffff << (32 - cidr_mask) ))
    local ip_int=$(( (octet1 << 24) + (octet2 << 16) + (octet3 << 8) + octet4 ))
    local network_int=$(( ip_int & mask ))
    local network_octet1=$(( (network_int >> 24) & 255 ))
    local network_octet2=$(( (network_int >> 16) & 255 ))
    local network_octet3=$(( (network_int >> 8) & 255 ))
    local network_octet4=$(( network_int & 255 ))
    echo "${network_octet1}.${network_octet2}.${network_octet3}.${network_octet4}/${cidr_mask}"
}

# 检测局域网段和网关
detect_lan_subnet_gateway() {
    log "检测局域网参数..."
    local default_iface=$(get_default_interface)
    if [[ -z "$default_iface" ]]; then
        echo -e "\033[31m无法自动检测默认网络接口\033[0m"
        return 1
    fi
    local ip_cidr=$(ip addr show dev "$default_iface" | awk '/inet / {print $2}' | head -n 1)
    if [[ -z "$ip_cidr" ]]; then
        echo -e "\033[31m无法获取接口 $default_iface 的 IP 信息\033[0m"
        return 1
    fi
    log "检测到 IP CIDR: $ip_cidr"
    if ! SUBNET=$(calculate_network_address "$ip_cidr"); then
        echo -e "\033[31m计算子网失败\033[0m"
        return 1
    fi
    GATEWAY=$(ip route show default | awk '/default/ {print $3}')
    if [[ -z "$SUBNET" || -z "$GATEWAY" ]]; then
        echo -e "\033[31m自动检测局域网信息失败\033[0m"
        return 1
    fi
    log "检测到子网: $SUBNET"
    log "检测到网关: $GATEWAY"
    log "默认网络接口: $default_iface"
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
        docker network inspect "$net" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' | grep -q "$subnet" && echo "$net"
    done)
    if [[ -n "$conflict_networks" ]]; then
        echo -e "\033[31m子网 $subnet 与以下网络冲突：\033[0m"
        echo "$conflict_networks"
        return 1
    fi
    log "子网 $subnet 无冲突"
    return 0
}

# 验证 IP 是否在子网内
validate_ip_in_subnet() {
    local ip=$1
    local subnet=$2
    local network=$(echo "$subnet" | cut -d'/' -f1)
    local cidr=$(echo "$subnet" | cut -d'/' -f2)

    # 验证 IP 格式
    IFS='.' read -r ip1 ip2 ip3 ip4 <<< "$ip"
    if [ -z "$ip1" ] || [ -z "$ip2" ] || [ -z "$ip3" ] || [ -z "$ip4" ]; then
        echo -e "\033[31m无效的 IP 地址格式: $ip (必须为 x.x.x.x)\033[0m"
        return 1
    fi
    for octet in $ip1 $ip2 $ip3 $ip4; do
        if ! [[ "$octet" =~ ^[0-9]+$ ]] || [ "$octet" -lt 0 ] || [ "$octet" -gt 255 ]; then
            echo -e "\033[31m无效的 IP 字节: $octet (必须为 0-255)\033[0m"
            return 1
        fi
    done

    # 验证子网
    IFS='.' read -r net1 net2 net3 net4 <<< "$network"
    for octet in $net1 $net2 $net3 $net4; do
        if ! [[ "$octet" =~ ^[0-9]+$ ]] || [ "$octet" -lt 0 ] || [ "$octet" -gt 255 ]; then
            echo -e "\033[31m无效的网络地址字节: $octet\033[0m"
            return 1
        fi
    done

    # 检查 IP 是否在子网内
    local ip_int=$(( (ip1 << 24) + (ip2 << 16) + (ip3 << 8) + ip4 ))
    local network_int=$(( (net1 << 24) + (net2 << 16) + (net3 << 8) + net4 ))
    local mask=$(( 0xffffffff << (32 - cidr) ))
    log "Debug: IP=$ip, Network=$network, CIDR=$cidr"
    log "Debug: IP_int=$ip_int, Network_int=$network_int, Mask=$mask"
    if (( (ip_int & mask) != (network_int & mask) )); then
        echo -e "\033[31mIP $ip 不在子网 $subnet 内\033[0m"
        return 1
    fi
    return 0
}

# 检查 IP 是否被占用
check_ip_occupied() {
    local ip=$1
    log "检查 IP $ip 是否被占用..."
    if ping -c 1 -W 1 "$ip" >/dev/null 2>&1; then
        echo -e "\033[31mIP $ip 已被占用，请选择其他 IP\033[0m"
        return 1
    fi
    log "IP $ip 未被占用"
    return 0
}

# 检查端口是否被占用
check_port_usage() {
    local port=$1
    log "检查端口 $port 是否被占用..."
    if command -v ss >/dev/null 2>&1; then
        if ss -tuln | grep -q ":$port"; then
            echo -e "\033[31m端口 $port 已经被占用，请选择其他端口\033[0m"
            return 1
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if netstat -tuln | grep -q ":$port"; then
            echo -e "\033[31m端口 $port 已经被占用，请选择其他端口\033[0m"
            return 1
        fi
    else
        echo -e "\033[33m缺少 ss 或 netstat 命令，无法检查端口占用情况\033[0m"
        return 0
    fi
    log "端口 $port 未被占用"
    return 0
}

# 获取宿主机 IP
get_host_ip() {
    local ip_addr
    ip_addr=$(ip -o -4 addr show | awk '!/^[0-9]*: ?lo|link\/ether/ {gsub("/", " "); print $4}' | grep -v '172.*' | head -n1)
    if [[ -z "$ip_addr" ]]; then
        ip_addr=$(hostname -I | awk '{print $1}')
    fi
    if [[ -z "$ip_addr" ]]; then
        ip_addr="<无法自动获取宿主机IP>"
    fi
    echo "$ip_addr"
}

# 检查 LuCI 和 uhttpd 状态
check_luci_status() {
    log "检查 LuCI 和 uhttpd 状态..."
    if docker exec openwrt /bin/sh -c "opkg list-installed | grep -q luci"; then
        log "LuCI 已安装"
    else
        log "LuCI 未安装，正在尝试安装..."
        docker exec openwrt /bin/sh -c "opkg update && opkg install luci" || {
            echo -e "\033[31mLuCI 安装失败，请检查网络或镜像源\033[0m"
            return 1
        }
    fi
    if docker exec openwrt /bin/sh -c "ps | grep -q uhttpd"; then
        log "uhttpd 服务正在运行"
    else
        log "uhttpd 服务未运行，正在尝试启动..."
        docker exec openwrt /bin/sh -c "/etc/init.d/uhttpd start && /etc/init.d/uhttpd enable" || {
            echo -e "\033[31muhttpd 启动失败，请检查容器状态\033[0m"
            return 1
        }
    fi
    return 0
}

# 验证 Web 界面可访问性
verify_web_access() {
    local ip=$1
    local port=$2
    log "验证 Web 界面可访问性: http://$ip:$port..."
    if curl -s -m 5 "http://$ip:$port" >/dev/null; then
        log "Web 界面可访问"
        return 0
    else
        echo -e "\033[31m无法访问 Web 界面 http://$ip:$port\033[0m"
        echo -e "\033[33m可能原因：防火墙阻止、LuCI 未启动、或网络配置错误\033[0m"
        return 1
    fi
}

# 清理残留资源
cleanup_residual() {
    log "清理可能残留的资源..."
    docker stop openwrt >/dev/null 2>&1
    docker rm openwrt >/dev/null 2>&1
    docker network rm openwrt_net >/dev/null 2>&1
    docker network rm openwrt_bridge >/dev/null 2>&1
    docker system prune -f >/dev/null 2>&1
    log "残留资源已清理"
}

# 尝试拉取镜像
pull_image() {
    local image=$1
    log "正在拉取镜像 '$image'..."
    if docker pull "$image" 2>&1 | tee /tmp/docker-pull.log; then
        return 0
    else
        echo -e "\033[31m镜像拉取失败：$image\033[0m"
        cat /tmp/docker-pull.log
        return 1
    fi
}

# 输出系统信息
clear
echo -e "\033[34m====================================\033[0m"
echo -e "系统架构：\033[32m$ARCH_DESC\033[0m"
echo -e "默认镜像：\033[33m$DOCKER_IMAGE\033[0m"
if [ -n "$ALIYUN_IMAGE" ]; then
    echo -e "阿里云镜像：\033[33m$ALIYUN_IMAGE\033[0m"
fi
if [ -n "$FALLBACK_IMAGE" ]; then
    echo -e "备选镜像：\033[33m$FALLBACK_IMAGE\033[0m"
fi
echo -e "内核版本：\033[32m$(uname -r)\033[0m"
echo -e "Docker 版本：\033[32m$(docker --version)\033[0m"
echo -e "\033[33m警告：内核版本 $(uname -r) 较旧，可能导致 OpenWrt 容器运行失败。建议升级到 5.4 或更高版本。\033[0m"
echo -e "\033[34m====================================\033[0m"

# 主控制菜单
while true; do
    echo ""
    echo -e "\033[36m[ 主菜单 ]\033[0m"
    echo "1) 安装 OpenWrt 容器"
    echo "2) 完全卸载 OpenWrt"
    echo "3) 查看容器状态"
    echo "4) 查看实时日志"
    echo "5) 查看登录地址"
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
            log "使用镜像: $SELECTED_IMAGE"

            echo -e "\n\033[33m» 网络模式选择 «\033[0m"
            echo "1) Bridge 模式（默认Docker网络，适合测试）"
            echo "2) Macvlan 模式（独立IP，适合旁路由）"
            read -rp "请选择网络类型 [1/2, 默认2]: " NET_MODE
            NET_MODE=${NET_MODE:-2}

            DEFAULT_NIC=$(get_default_interface)
            if [ -z "$DEFAULT_NIC" ]; then
                echo -e "\033[31m无法检测默认网卡，请手动输入\033[0m"
                ip link show
                read -rp "请输入网卡名称（例如 eth0）： " DEFAULT_NIC
                if [ -z "$DEFAULT_NIC" ] || ! ip link show "$DEFAULT_NIC" >/dev/null 2>&1; then
                    echo -e "\033[31m无效网卡名称，安装中止\033[0m"
                    continue
                fi
            fi
            MACVLAN_IP=""
            WEB_PORT="8080"
            SSH_PORT="2222"

            if [ "$NET_MODE" -eq 2 ]; then
                echo -e "\n\033[33m» Macvlan 参数配置 «\033[0m"
                if detect_lan_subnet_gateway; then
                    echo -e "\033[32m自动检测到以下参数：\033[0m"
                    echo "子网: $DETECTED_SUBNET"
                    echo "网关: $DETECTED_GATEWAY"
                    echo "父接口: $DETECTED_INTERFACE"
                    read -rp "是否使用自动检测的参数？[Y/n]: " USE_DETECTED
                    if [[ ! "$USE_DETECTED" =~ [Nn] ]]; then
                        SUBNET="$DETECTED_SUBNET"
                        GATEWAY="$DETECTED_GATEWAY"
                        TARGET_NIC="$DETECTED_INTERFACE"
                    else
                        read -rp "输入子网地址 [默认: $DEFAULT_SUBNET]: " SUBNET
                        SUBNET=${SUBNET:-$DEFAULT_SUBNET}
                        read -rp "输入网关地址 [默认: $DEFAULT_GATEWAY]: " GATEWAY
                        GATEWAY=${GATEWAY:-$DEFAULT_GATEWAY}
                        read -rp "绑定物理网卡 [默认: $DEFAULT_NIC]: " TARGET_NIC
                        TARGET_NIC=${TARGET_NIC:-$DEFAULT_NIC}
                    fi
                else
                    echo -e "\033[33m自动检测失败，请手动输入参数\033[0m"
                    read -rp "输入子网地址 [默认: $DEFAULT_SUBNET]: " SUBNET
                    SUBNET=${SUBNET:-$DEFAULT_SUBNET}
                    read -rp "输入网关地址 [默认: $DEFAULT_GATEWAY]: " GATEWAY
                    GATEWAY=${GATEWAY:-$DEFAULT_GATEWAY}
                    read -rp "绑定物理网卡 [默认: $DEFAULT_NIC]: " TARGET_NIC
                    TARGET_NIC=${TARGET_NIC:-$DEFAULT_NIC}
                fi

                if ! ip link show "$TARGET_NIC" >/dev/null 2>&1; then
                    echo -e "\033[31m网卡 $TARGET_NIC 不存在！\033[0m"
                    ip link show
                    echo -e "\033[33m请确认网卡名称并重试\033[0m"
                    continue
                fi

                read -rp "请输入 OpenWrt 容器静态 IP 地址 (例如: 192.168.3.181, 确保在 $SUBNET 网段内且未被占用): " MACVLAN_IP
                if ! validate_ip_in_subnet "$MACVLAN_IP" "$SUBNET"; then
                    echo -e "\033[31m安装中止\033[0m"
                    continue
                fi
                if ! check_ip_occupied "$MACVLAN_IP"; then
                    echo -e "\033[31m安装中止\033[0m"
                    continue
                fi

                if ! check_network_conflict "$SUBNET"; then
                    read -rp "是否尝试删除冲突网络 'openwrt_net'？[y/N]: " DELETE_NET
                    if [[ "$DELETE_NET" =~ [Yy] ]]; then
                        docker network rm openwrt_net >/dev/null 2>&1 || {
                            echo -e "\033[31m删除冲突网络失败，请手动删除后重试\033[0m"
                            continue
                        }
                    else
                        echo -e "\033[31m请手动删除冲突网络或选择其他子网后重试\033[0m"
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
                        echo -e "\033[31mMacvlan网络创建失败！请检查参数或网卡名称。\033[0m"
                        echo -e "\033[33m建议：运行 'docker network ls' 检查现有网络，或验证网卡 '$TARGET_NIC' 是否存在\033[0m"
                        continue
                    fi
                    log "Macvlan 网络 'openwrt_net' 创建成功"
                else
                    log "Macvlan 网络 'openwrt_net' 已存在"
                fi
                NET_NAME="openwrt_net"
            else
                if ! docker network inspect openwrt_bridge >/dev/null 2>&1; then
                    log "正在创建 Bridge 网络 'openwrt_bridge'..."
                    if ! docker network create openwrt_bridge >/dev/null 2>&1; then
                        echo -e "\033[31mBridge网络创建失败！\033[0m"
                        continue
                    fi
                    log "Bridge 网络 'openwrt_bridge' 创建成功"
                else
                    log "Bridge 网络 'openwrt_bridge' 已存在"
                fi
                NET_NAME="openwrt_bridge"
            fi

            echo -e "\n\033[33m» 端口映射配置（默认启用） «\033[0m"
            read -rp "输入映射到宿主机的 Web 管理端口 [默认: 8080 (对应容器80)]: " WEB_PORT
            WEB_PORT=${WEB_PORT:-8080}
            if ! check_port_usage "$WEB_PORT"; then
                echo -e "\033[31m安装中止\033[0m"
                continue
            fi
            read -rp "输入映射到宿主机的 SSH 管理端口 [默认: 2222 (对应容器22)]: " SSH_PORT
            SSH_PORT=${SSH_PORT:-2222}
            if ! check_port_usage "$SSH_PORT"; then
                echo -e "\033[31m安装中止\033[0m"
                continue
            fi
            PORT_MAP="-p $WEB_PORT:80 -p $SSH_PORT:22"

            echo -e "\n\033[33m» 数据持久化配置 «\033[0m"
            read -rp "是否需要挂载配置文件到宿主机？[y/N]: " NEED_VOLUME
            if [[ "$NEED_VOLUME" =~ [Yy] ]]; then
                read -rp "输入宿主机配置存储路径 [默认: /opt/openwrt/config]: " CONFIG_PATH
                CONFIG_PATH=${CONFIG_PATH:-/opt/openwrt/config}
                mkdir -p "$CONFIG_PATH"
                chmod 755 "$CONFIG_PATH"
                VOLUME_MAP="-v $CONFIG_PATH:/etc/config"
            else
                VOLUME_MAP=""
            fi

            if docker ps -a --format '{{.Names}}' | grep -q "^openwrt$"; then
                echo -e "\n\033[33m警告：名为 'openwrt' 的容器已存在。\033[0m"
                read -rp "是否要先删除现有容器再继续？[y/N]: " REMOVE_EXISTING
                if [[ "$REMOVE_EXISTING" =~ [Yy] ]]; then
                    log "正在停止并删除现有容器..."
                    docker stop openwrt >/dev/null 2>&1
                    docker rm openwrt >/dev/null 2>&1
                    log "现有容器已删除"
                else
                    echo -e "\033[31m安装中止\033[0m"
                    continue
                fi
            fi

            if ! pull_image "$SELECTED_IMAGE"; then
                echo -e "\033[33m尝试拉取备选镜像 '$FALLBACK_IMAGE'...\033[0m"
                if [ -n "$FALLBACK_IMAGE" ] && pull_image "$FALLBACK_IMAGE"; then
                    SELECTED_IMAGE="$FALLBACK_IMAGE"
                else
                    echo -e "\033[31m所有镜像拉取失败！\033[0m"
                    echo -e "\033[33m可能原因：\033[0m"
                    echo -e "  1. 网络问题：无法访问 Docker Hub 或阿里云镜像仓库"
                    echo -e "  2. 镜像标签不可用：检查 https://hub.docker.com/r/sulinggg/openwrt/tags"
                    echo -e "  3. Docker 配置错误：确保镜像加速器正确配置"
                    echo -e "\033[33m建议：\033[0m"
                    echo -e "  - 检查网络：ping hub.docker.com 或 ping registry.cn-shanghai.aliyuncs.com"
                    echo -e "  - 配置阿里云加速器：编辑 /etc/docker/daemon.json"
                    echo -e '    { "registry-mirrors": ["https://registry.cn-shanghai.aliyuncs.com"] }'
                    echo -e "    然后重启 Docker：systemctl restart docker"
                    echo -e "  - 尝试手动拉取：docker pull $SELECTED_IMAGE"
                    cleanup_residual
                    read -rp "是否重试拉取镜像？[y/N]: " RETRY_PULL
                    if [[ "$RETRY_PULL" =~ [Yy] ]]; then
                        continue
                    else
                        echo -e "\033[31m安装中止\033[0m"
                        continue
                    fi
                fi
            fi

            log "正在启动 OpenWrt 容器..."
            if [ "$NET_MODE" -eq 2 ]; then
                if ! docker run -d --name openwrt \
                    --network "$NET_NAME" \
                    --ip "$MACVLAN_IP" \
                    --restart unless-stopped \
                    --privileged \
                    $PORT_MAP \
                    $VOLUME_MAP \
                    "$SELECTED_IMAGE" /sbin/init 2>&1 | tee /tmp/docker-run.log; then
                    echo -e "\033[31m容器启动失败！\033[0m"
                    cat /tmp/docker-run.log
                    echo -e "\033[33m请检查以下可能原因：\033[0m"
                    echo -e "  1. 内核不兼容：宿主机内核 $(uname -r) 可能不支持 OpenWrt"
                    echo -e "  2. 权限问题：确保使用 --privileged"
                    echo -e "  3. 网络配置错误：验证网卡 $TARGET_NIC 和 IP $MACVLAN_IP"
                    echo -e "  4. 镜像问题：尝试其他标签，如 $FALLBACK_IMAGE"
                    echo -e "\033[33m调试命令：\033[0m"
                    echo -e "  - 查看日志：docker logs openwrt"
                    echo -e "  - 检查状态：docker ps -a"
                    echo -e "  - 手动运行：docker run -d --name test --privileged $SELECTED_IMAGE /sbin/init"
                    cleanup_residual
                    continue
                fi
            else
                if ! docker run -d --name openwrt \
                    --network "$NET_NAME" \
                    --restart unless-stopped \
                    --privileged \
                    $PORT_MAP \
                    $VOLUME_MAP \
                    "$SELECTED_IMAGE" /sbin/init 2>&1 | tee /tmp/docker-run.log; then
                    echo -e "\033[31m容器启动失败！\033[0m"
                    cat /tmp/docker-run.log
                    echo -e "\033[33m请检查以下可能原因：\033[0m"
                    echo -e "  1. 内核不兼容：宿主机内核 $(uname -r) 可能不支持 OpenWrt"
                    echo -e "  2. 权限问题：确保使用 --privileged"
                    echo -e "  3. 镜像问题：尝试其他标签，如 $FALLBACK_IMAGE"
                    echo -e "\033[33m调试命令：\033[0m"
                    echo -e "  - 查看日志：docker logs openwrt"
                    echo -e "  - 检查状态：docker ps -a"
                    echo -e "  - 手动运行：docker run -d --name test --privileged $SELECTED_IMAGE /sbin/init"
                    cleanup_residual
                    continue
                fi
            fi
            echo -e "\033[32m容器启动成功！\033[0m"
            if [ "$NET_MODE" -eq 2 ]; then
                echo -e "容器 IP: $MACVLAN_IP"
            fi
            echo -e "管理命令：\ndocker exec -it openwrt /bin/sh"

            log "检查容器状态..."
            sleep 5
            if ! docker ps -q --filter name=openwrt >/dev/null; then
                echo -e "\033[31m容器未运行！\033[0m"
                docker ps -a
                echo -e "\033[33m查看日志：\033[0m"
                docker logs openwrt
                cleanup_residual
                continue
            fi

            log "配置 OpenWrt 环境..."
            docker exec openwrt /bin/sh -c "sed -i 's/.*preinit.*//g' /etc/preinit" || log "警告：无法修改 preinit 配置"
            if ! check_luci_status; then
                echo -e "\033[31mLuCI 配置失败，请手动检查\033[0m"
                echo -e "命令："
                echo -e "  docker exec -it openwrt /bin/sh"
                echo -e "  opkg update"
                echo -e "  opkg install luci"
                echo -e "  /etc/init.d/uhttpd start"
            fi

            log "验证容器部署..."
            docker ps -a --filter name=openwrt --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}"
            if [ "$NET_MODE" -eq 2 ]; then
                if ping -c 1 -W 2 "$MACVLAN_IP" >/dev/null 2>&1; then
                    log "容器 IP $MACVLAN_IP 可 ping"
                else
                    echo -e "\033[31m无法 ping 容器 IP $MACVLAN_IP，请检查网络配置\033[0m"
                fi
                verify_web_access "$MACVLAN_IP" "$WEB_PORT"
            else
                HOST_IP=$(get_host_ip)
                verify_web_access "$HOST_IP" "$WEB_PORT"
            fi

            echo -e "\n\033[36m正在尝试获取登录地址...\033[0m"
            bash "$0" 5
            ;;

        2)
            echo -e "\n\033[33m警告：这将停止并删除 OpenWrt 容器及其相关的 Macvlan/Bridge 网络。\033[0m"
            read -rp "确定要完全卸载吗？[y/N]: " CONFIRM_UNINSTALL
            if [[ "$CONFIRM_UNINSTALL" =~ [Yy] ]]; then
                log "正在执行完全卸载..."
                cleanup_residual
                read -rp "是否同时删除挂载的配置目录（如果之前设置过）？[y/N]: " DELETE_VOLUME_DIR
                if [[ "$DELETE_VOLUME_DIR" =~ [Yy] ]]; then
                    echo -e "\033[33m请手动删除您之前指定的配置目录 (例如: /opt/openwrt/config)\033[0m"
                fi
                echo -e "\033[32mOpenWrt 容器及相关网络已清除！\033[0m"
            else
                echo -e "\033[33m卸载操作已取消\033[0m"
            fi
            ;;

        3)
            echo -e "\n\033[36m容器状态：\033[0m"
            docker ps -a --filter name=openwrt --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}"
            ;;

        4)
            echo -e "\n\033[36m实时日志查看（Ctrl+C退出）\033[0m"
            if ! docker logs -f openwrt; then
                echo -e "\033[31m无法获取日志，容器 'openwrt' 可能不存在或未运行。\033[0m"
            fi
            echo -e "\033[33m提示：如果日志显示启动提示（如 'Press [f]'），表示镜像未优化。\033[0m"
            echo -e "请进入容器检查状态："
            echo -e "  docker exec -it openwrt /bin/sh"
            echo -e "检查 LuCI："
            echo -e "  opkg list-installed | grep luci"
            echo -e "  /etc/init.d/uhttpd start"
            ;;

        5)
            echo -e "\n\033[36m正在查询 OpenWrt 容器登录信息...\033[0m"
            CONTAINER_ID=$(docker ps -q --filter name=openwrt)
            if [ -z "$CONTAINER_ID" ]; then
                echo -e "\033[31m错误：未找到正在运行的名为 'openwrt' 的容器。\033[0m"
                continue
            fi
            INSPECT_JSON=$(docker inspect "$CONTAINER_ID")
            if command -v jq &> /dev/null; then
                NET_INFO=$(echo "$INSPECT_JSON" | jq -r '.[0].NetworkSettings.Networks | keys[] as $k | if .[$k].IPAddress and .[$k].IPAddress != "" then "\($k):\(.[$k].IPAddress)" else empty end' | head -n 1)
                WEB_HOST_PORT=$(echo "$INSPECT_JSON" | jq -r '.[0].HostConfig.PortBindings."80/tcp"[0].HostPort // empty')
                SSH_HOST_PORT=$(echo "$INSPECT_JSON" | jq -r '.[0].HostConfig.PortBindings."22/tcp"[0].HostPort // empty')
            else
                echo -e "\033[33m提示：未安装 jq，将使用 grep/awk 尝试解析，结果可能不精确。建议安装 jq (例: apt install jq)。\033[0m"
                NET_INFO=$(echo "$INSPECT_JSON" | grep -E '"IPAddress":\s*"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' -B 5 | grep -Eo '"(openwrt_net|openwrt_bridge)":|"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' | sed 's/"//g' | tr '\n' ':' | sed 's/:$//' | head -n 1)
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
                echo -e "\033[31m错误：无法确定容器的网络模式或IP地址。\033[0m"
                continue
            fi
            echo -e "\n\033[34m--- OpenWrt 登录信息 ---\033[0m"
            echo -e "网络模式 : \033[33m$ACCESS_MODE\033[0m"
            if [ "$NETWORK_NAME" == "openwrt_bridge" ]; then
                echo -e "宿主机 IP : \033[32m$HOST_IP\033[0m"
                echo -e "容器桥接IP: \033[37m$CONTAINER_IP (通常仅用于容器间通信)\033[0m"
            else
                echo -e "容器 IP  : \033[32m$ACCESS_IP\033[0m"
            fi
            if [ -n "$WEB_HOST_PORT" ]; then
                echo -e "Web 访问 : \033[32mhttp://$ACCESS_IP:$WEB_HOST_PORT\033[0m"
            else
                echo -e "Web 访问 : \033[37m未映射端口\033[0m"
            fi
            echo -e "Web 用户名: \033[32mroot\033[0m"
            echo -e "Web 密码  : \033[33m(通常为空，首次登录设置；或尝试 'password')\033[0m"
            if [ -n "$SSH_HOST_PORT" ]; then
                echo -e "SSH 连接 : \033[32mssh root@$ACCESS_IP -p $SSH_HOST_PORT\033[0m"
            else
                echo -e "SSH 连接 : \033[37m未映射端口\033[0m"
            fi
            echo -e "SSH 密码  : \033[33m(与Web密码相同)\033[0m"
            echo -e "\033[34m------------------------\033[0m"
            echo -e "\033[33m提示：如果无法访问 Web 界面，请检查：\033[0m"
            echo -e "  1. 进入容器：docker exec -it openwrt /bin/sh"
            echo -e "  2. 检查 LuCI：opkg list-installed | grep luci"
            echo -e "  3. 启动 uhttpd：/etc/init.d/uhttpd start"
            echo -e "  4. 检查防火墙：iptables -L -n 或 ufw status"
            ;;

        6)
            echo -e "\n\033[33m感谢使用，再见！\033[0m"
            exit 0
            ;;

        *)
            echo -e "\n\033[31m无效的输入，请重新选择！\033[0m"
            ;;
    esac
done
