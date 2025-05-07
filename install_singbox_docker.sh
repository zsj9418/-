#!/bin/bash
set -euo pipefail

# 定义颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# 日志记录函数
log() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

# 检查是否为root用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}此脚本必须以root用户运行${NC}"
        exit 1
    fi
}

# 获取架构信息
get_arch() {
    case $(uname -m) in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l)  echo "armv7" ;;
        *)       echo -e "${RED}未知架构: $(uname -m)${NC}" >&2; exit 1 ;;
    esac
}

# 安装依赖 (Docker)
install_docker_deps() {
    log "正在检查 Docker 依赖..."
    if ! command -v docker &>/dev/null; then
        log "Docker 未安装，尝试安装 Docker..."
        if command -v apt &>/dev/null; then
            apt update
            apt install -y apt-transport-https ca-certificates curl software-properties-common
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
            add-apt-repository "deb [arch=$(dpkg --print-architecture)] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
            apt update
            apt install -y docker-ce docker-ce-cli containerd.io
        elif command -v yum &>/dev/null; then
            yum install -y yum-utils
            yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            yum install -y docker-ce docker-ce-cli containerd.io
        elif command -v apk &>/dev/null; then
            apk add docker
        else
            echo -e "${RED}不支持的包管理器，请手动安装 Docker${NC}"
            exit 1
        fi
        systemctl enable docker
        systemctl start docker
        log "Docker 安装完成"
    else
        log "Docker 已安装"
    fi
}

# 获取本机IP
get_gateway_ip() {
    local iface=$(ip route show default | awk '/default/ {print $5}')
    if [[ -z $iface ]]; then
        echo -e "${RED}无法获取默认网络接口${NC}"
        exit 1
    fi
    ip addr show dev $iface | awk '/inet / {print $2}' | cut -d'/' -f1
}

# 验证版本号格式
validate_version() {
    local version=$1
    if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.-]+)?$ && $version != "latest" ]]; then
        echo -e "${RED}无效的版本号格式，应为 x.y.z 或 latest${NC}"
        exit 1
    fi
}

# 验证订阅URL
validate_url() {
    local url=$1
    if [[ ! $url =~ ^https?:// ]]; then
        echo -e "${RED}无效的订阅URL${NC}"
        exit 1
    fi
}

# 验证IP是否在子网内
validate_ip_in_subnet() {
    local ip=$1
    local subnet=$2
    local network=$(echo "$subnet" | cut -d'/' -f1)
    local cidr=$(echo "$subnet" | cut -d'/' -f2)
    if ! echo "$ip" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        echo -e "${RED}无效的 IP 地址格式: $ip${NC}"
        return 1
    fi
    IFS='.' read -r ip1 ip2 ip3 ip4 <<< "$ip"
    IFS='.' read -r net1 net2 net3 net4 <<< "$network"
    for octet in $ip1 $ip2 $ip3 $ip4 $net1 $net2 $net3 $net4; do
        if ! [[ $octet =~ ^[0-9]+$ ]] || (( octet < 0 || octet > 255 )); then
            echo -e "${RED}无效的 IP 或网络地址字节: $octet${NC}"
            return 1
        fi
    done
    local ip_int=$(( (ip1 << 24) + (ip2 << 16) + (ip3 << 8) + ip4 ))
    local network_int=$(( (net1 << 24) + (net2 << 16) + (net3 << 8) + net4 ))
    local mask=$(( 0xffffffff << (32 - cidr) ))
    log "Debug: IP=$ip, Network=$network, CIDR=$cidr"
    log "Debug: IP_int=$ip_int, Network_int=$network_int, Mask=$mask"
    if (( (ip_int & mask) != (network_int & mask) )); then
        echo -e "${RED}IP $ip 不在子网 $subnet 内${NC}"
        return 1
    fi
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
        echo -e "${RED}子网 $subnet 与以下网络冲突：${NC}"
        echo "$conflict_networks"
        return 1
    fi
    log "子网 $subnet 无冲突"
    return 0
}

# 检查 IP 是否被占用
check_ip_occupied() {
    local ip=$1
    log "检查 IP $ip 是否被占用..."
    if ping -c 1 -W 1 "$ip" &>/dev/null; then
        echo -e "${RED}IP $ip 已被占用，请选择其他 IP${NC}"
        return 1
    fi
    log "IP $ip 未被占用"
    return 0
}

# 定义临时目录
TEMP_DIR="/tmp/singbox_install"

# 清理临时文件
cleanup() {
    if [[ -d $TEMP_DIR ]]; then
        log "清理临时文件..."
        rm -rf $TEMP_DIR
    fi
}

# 检查iptables规则
check_iptables() {
    log "检查 iptables NAT 规则..."
    if ! iptables -t nat -L | grep -q "MASQUERADE"; then
        log "iptables规则未生效，重新配置..."
        iptables -t nat -A POSTROUTING -s 192.168.0.0/16 -j MASQUERADE
        save_iptables_rules
    fi
}

# 保存iptables规则
save_iptables_rules() {
    mkdir -p /etc/iptables
    iptables-save | tee /etc/iptables/rules.v4 >/dev/null
}

# 检查网络通畅性
check_network() {
    log "检查网络通畅性..."
    if ! ping -c 1 8.8.8.8 &>/dev/null; then
        echo -e "${RED}无法连接到外网，请检查网络配置${NC}"
        exit 1
    fi
    echo -e "${GREEN}网络连接正常${NC}"
}

# 检查默认路由
check_default_route() {
    log "检查默认路由..."
    local default_route=$(ip route show | grep "^default")
    if [[ -z "$default_route" ]]; then
        echo -e "${RED}未找到默认路由，请手动配置${NC}"
        exit 1
    fi
    log "默认路由：$default_route"
}

# 启用网络转发
enable_ip_forwarding() {
    log "启用网络转发..."
    sysctl -w net.ipv4.ip_forward=1
    echo 'net.ipv4.ip_forward=1' | tee -a /etc/sysctl.conf >/dev/null
    log "网络转发已启用"
}

# 卸载清理
uninstall_docker() {
    log "开始卸载 Docker sing-box..."
    docker stop "$CONTAINER_NAME" || true
    docker rm "$CONTAINER_NAME" || true
    docker network rm "$MACVLAN_NET_NAME" || true
    iptables -t nat -D POSTROUTING -s 192.168.0.0/16 -j MASQUERADE || true
    save_iptables_rules
    log "Docker sing-box 已卸载，网络配置已恢复"
}

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
    local default_iface=$(get_default_interface)
    if [[ -z "$default_iface" ]]; then
        echo -e "${RED}无法自动检测局域网信息，请手动配置 macvlan 网络参数${NC}"
        return 1
    fi
    local ip_cidr=$(ip addr show dev "$default_iface" | awk '/inet / {print $2}' | head -n 1)
    if [[ -z "$ip_cidr" ]]; then
        echo -e "${RED}无法获取接口 $default_iface 的 IP 信息，请手动配置 macvlan 网络参数${NC}"
        return 1
    fi
    log "Debug: ip_cidr: ${YELLOW}$ip_cidr${NC}"
    if ! SUBNET=$(calculate_network_address "$ip_cidr"); then
        echo -e "${RED}计算子网失败，请手动配置 macvlan 网络参数${NC}"
        return 1
    fi
    log "Debug: Calculated SUBNET: ${YELLOW}$SUBNET${NC}"
    GATEWAY=$(ip route show default | awk '/default/ {print $3}')
    if [[ -z "$SUBNET" || -z "$GATEWAY" ]]; then
        echo -e "${RED}自动检测局域网信息失败，请手动配置 macvlan 网络参数${NC}"
        return 1
    fi
    echo "检测到局域网段: ${GREEN}$SUBNET${NC}"
    echo "检测到网关: ${GREEN}$GATEWAY${NC}"
    echo "默认网络接口: ${GREEN}$default_iface${NC}"
    export DETECTED_SUBNET="$SUBNET"
    export DETECTED_GATEWAY="$GATEWAY"
    export DETECTED_INTERFACE="$default_iface"
    return 0
}

# 检查端口占用情况
check_port_usage() {
    local port=$1
    if command -v ss >/dev/null 2>&1; then
        if ss -ln | grep ":$port" >/dev/null; then
            echo -e "${RED}端口 $port 已经被占用，请修改配置或停止占用端口的程序${NC}"
            return 1
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if netstat -ln | grep ":$port" >/dev/null; then
            echo -e "${RED}端口 $port 已经被占用，请修改配置或停止占用端口的程序${NC}"
            return 1
        fi
    else
        echo -e "${YELLOW}缺少 ss 或 netstat 命令，无法检查端口占用情况${NC}"
        return 0
    fi
    return 0
}

# 检查配置文件目录和权限
check_config_dir() {
    local config_dir=$1
    if [ ! -d "$config_dir" ]; then
        echo -e "${RED}$config_dir 目录不存在，请创建${NC}"
        return 1
    fi
    if [ ! -r "$config_dir/config.json" ]; then
        echo -e "${RED}$config_dir/config.json 文件不可读，请检查权限${NC}"
        return 1
    fi
    # 验证 JSON 格式
    if command -v jq >/dev/null 2>&1; then
        if ! jq . "$config_dir/config.json" >/dev/null 2>&1; then
            echo -e "${RED}$config_dir/config.json 不是有效的 JSON 文件${NC}"
            return 1
        fi
    else
        echo -e "${YELLOW}未安装 jq，无法验证 JSON 格式，请确保 config.json 有效${NC}"
    fi
    # 设置文件权限
    chmod 644 "$config_dir/config.json"
    chown root:root "$config_dir/config.json"
    log "配置文件 $config_dir/config.json 已验证，权限已设置为 644"
    return 0
}

# 检查Docker版本
check_docker_version() {
    local docker_version=$(docker version --format '{{.Client.Version}}')
    local major=$(echo "$docker_version" | awk -F. '{print $1}')
    local minor=$(echo "$docker_version" | awk -F. '{print $2}')
    local min_major=1
    local min_minor=13
    if ((major < min_major)) || ((major == min_major && minor < min_minor)); then
        echo -e "${RED}Docker 版本过低，请升级到 1.13 或更高版本${NC}"
        return 1
    fi
    return 0
}

# Docker 部署安装流程
install_docker() {
    check_root
    trap 'echo -e "${RED}安装中断，正在清理...${NC}"; cleanup; exit 1' INT

    # 1. 架构检测
    ARCH=$(get_arch)
    log "检测到系统架构: ${ARCH}"

    # 2. 用户自定义容器名称
    read -p "请输入容器名称 (默认: sing-box-container): " CONTAINER_NAME
    CONTAINER_NAME=${CONTAINER_NAME:-sing-box-container}
    log "容器名称: ${YELLOW}$CONTAINER_NAME${NC}"

    # 3. 用户选择镜像版本
    read -p "请输入 Sing-box 镜像版本 (例如: 1.12.0 或 latest, 默认: latest): " VERSION
    VERSION=${VERSION:-latest}
    validate_version "$VERSION"
    log "Sing-box 镜像版本: ${YELLOW}$VERSION${NC}"

    # 4. 安装 Docker 依赖
    install_docker_deps
    if ! check_docker_version; then
        echo -e "${RED}Docker 版本不符合要求，请升级 Docker 后重试${NC}"
        exit 1
    fi

    # 5. 下载配置文件
    read -p "请输入配置文件订阅URL: " CONFIG_URL
    validate_url "$CONFIG_URL"
    read -p "请输入配置文件存储路径 (默认: /etc/sing-box): " CONFIG_DIR
    CONFIG_DIR=${CONFIG_DIR:-/etc/sing-box}
    mkdir -p "$CONFIG_DIR"
    if ! curl -sSL "$CONFIG_URL" -o "$CONFIG_DIR/config.json"; then
        echo -e "${RED}配置文件下载失败${NC}"
        cleanup
        exit 1
    fi
    if ! check_config_dir "$CONFIG_DIR"; then
        echo -e "${RED}配置文件目录或权限不正确，请检查后重试${NC}"
        cleanup
        exit 1
    fi

    # 6. 选择 Docker 网络模式
    echo -e "${GREEN}请选择 Docker 网络模式：${NC}"
    echo "1. Bridge (默认，需要端口映射)"
    echo "2. Host (高性能，共享宿主机网络)"
    echo "3. Macvlan (推荐，独立IP，直接接入物理网络)"
    read -p "请输入选项 (1, 2 或 3, 默认: 3): " NETWORK_CHOICE
    case $NETWORK_CHOICE in
        1) NETWORK_MODE="bridge" ;;
        2) NETWORK_MODE="host" ;;
        3|*) NETWORK_MODE="macvlan" ;;
    esac
    log "Docker 网络模式: ${YELLOW}$NETWORK_MODE${NC}"

    # 7. Macvlan 网络模式配置
    if [[ "$NETWORK_MODE" == "macvlan" ]]; then
        read -p "请输入 Macvlan 网络名称 (默认: macvlan-net): " MACVLAN_NET_NAME
        MACVLAN_NET_NAME=${MACVLAN_NET_NAME:-macvlan-net}
        log "Macvlan 网络名称: ${YELLOW}$MACVLAN_NET_NAME${NC}"

        log "配置 Macvlan 网络..."
        if ! detect_lan_subnet_gateway; then
            echo -e "${RED}自动检测局域网信息失败，请手动配置 macvlan 网络参数${NC}"
            read -p "请输入局域网段 (例如: 192.168.3.0/24): " SUBNET
            read -p "请输入网关地址 (例如: 192.168.3.1): " GATEWAY
            read -p "请输入父接口 (例如: eth0): " PARENT_INTERFACE
        else
            SUBNET="$DETECTED_SUBNET"
            GATEWAY="$DETECTED_GATEWAY"
            PARENT_INTERFACE="$DETECTED_INTERFACE"
        fi

        # 检查子网冲突
        if ! check_network_conflict "$SUBNET"; then
            echo -e "${YELLOW}建议：运行 'docker network ls' 查看现有网络，删除冲突网络后重试${NC}"
            read -p "是否尝试自动删除同名网络 $MACVLAN_NET_NAME？(y/N): " DELETE_NET
            if [[ "$DELETE_NET" =~ ^[Yy]$ ]]; then
                docker network rm "$MACVLAN_NET_NAME" || true
            else
                echo -e "${RED}请手动删除冲突网络或选择其他子网后重试${NC}"
                exit 1
            fi
        fi

        read -p "请输入 sing-box 容器静态IP地址 (例如: 192.168.3.10, 确保在 ${SUBNET} 网段内且未被占用): " MACVLAN_IP
        if ! validate_ip_in_subnet "$MACVLAN_IP" "$SUBNET"; then
            exit 1
        fi
        if ! check_ip_occupied "$MACVLAN_IP"; then
            exit 1
        fi

        log "创建 macvlan 网络: $MACVLAN_NET_NAME"
        if ! docker network create -d macvlan --subnet="${SUBNET}" --gateway="${GATEWAY}" -o parent="${PARENT_INTERFACE}" "$MACVLAN_NET_NAME"; then
            echo -e "${RED}创建 macvlan 网络失败，请检查参数或手动创建${NC}"
            echo -e "${YELLOW}建议：运行 'docker network ls' 和 'docker network inspect <网络名>' 检查冲突${NC}"
            exit 1
        fi
        log "macvlan 网络创建成功"
    fi

    # 8. 检查端口占用（仅 Bridge 模式需要）
    if [[ "$NETWORK_MODE" == "bridge" ]]; then
        if check_port_usage 10808 || check_port_usage 10809 || check_port_usage 9090; then
            echo -e "${RED}检测到端口冲突，请修改配置或停止占用端口的程序后重试${NC}"
            cleanup
            exit 1
        fi
    fi

    # 9. 运行 Docker 容器
    DOWNLOAD_URL="ghcr.io/sagernet/sing-box:$VERSION"
    log "Docker 镜像: ${YELLOW}$DOWNLOAD_URL${NC}"

    DOCKER_RUN_CMD="docker run -d --privileged --name \"$CONTAINER_NAME\" --restart always --memory=128m --cpus=0.5"
    case "$NETWORK_MODE" in
        host)
            DOCKER_RUN_CMD="$DOCKER_RUN_CMD --net host"
            log "使用 Host 网络模式"
            ;;
        macvlan)
            DOCKER_RUN_CMD="$DOCKER_RUN_CMD --network \"$MACVLAN_NET_NAME\" --ip \"$MACVLAN_IP\""
            log "使用 Macvlan 网络模式，静态IP: $MACVLAN_IP"
            ;;
        bridge|*)
            DOCKER_RUN_CMD="$DOCKER_RUN_CMD -p 10808:10808 -p 10809:10809 -p 9090:9090 --net bridge"
            log "使用 Bridge 网络模式，映射端口 10808, 10809, 9090"
            ;;
    esac
    DOCKER_RUN_CMD="$DOCKER_RUN_CMD -v \"$CONFIG_DIR\":/etc/sing-box $DOWNLOAD_URL run -c /etc/sing-box/config.json"

    log "执行 Docker 命令: ${YELLOW}${DOCKER_RUN_CMD}${NC}"
    if ! eval "$DOCKER_RUN_CMD"; then
        echo -e "${RED}Docker 容器启动失败，请检查 Docker 日志${NC}"
        docker logs "$CONTAINER_NAME" 2>/dev/null || true
        echo -e "${YELLOW}建议：验证配置文件路径和内容：${NC}"
        echo -e "  cat $CONFIG_DIR/config.json"
        echo -e "  docker run --rm -v $CONFIG_DIR:/etc/sing-box $DOWNLOAD_URL check -c /etc/sing-box/config.json"
        cleanup
        exit 1
    fi

    # 10. 网络配置
    GATEWAY_IP=$(get_gateway_ip)
    log "配置网关地址: ${GATEWAY_IP}"
    enable_ip_forwarding
    check_default_route
    iptables -t nat -A POSTROUTING -s 192.168.0.0/16 -j MASQUERADE
    save_iptables_rules
    check_iptables
    check_network

    # 11. 显示使用信息
    echo -e "${GREEN}Docker sing-box 安装完成！${NC}"
    if [[ "$NETWORK_MODE" == "bridge" ]]; then
        echo -e "请将客户端配置为："
        echo -e "  - HTTP 代理: ${GATEWAY_IP}:10809"
        echo -e "  - SOCKS 代理: ${GATEWAY_IP}:10808"
        echo -e "  - 管理界面: ${GATEWAY_IP}:9090"
    elif [[ "$NETWORK_MODE" == "macvlan" ]]; then
        echo -e "请将客户端网关设置为: ${MACVLAN_IP}"
        echo -e "代理端口根据配置文件确定（默认 HTTP: 10809, SOCKS: 10808, 管理界面: 9090）"
    else
        echo -e "Host 模式：请根据配置文件设置客户端，常用端口为 10808, 10809, 9090"
    fi
    echo -e "容器状态检查: ${YELLOW}docker ps -a${NC}"
    echo -e "容器日志查看: ${YELLOW}docker logs $CONTAINER_NAME${NC}"
}

# 主菜单
main_menu() {
    echo -e "${GREEN}请选择操作：${NC}"
    echo "1. 安装 Docker sing-box"
    echo "2. 卸载 Docker sing-box"
    read -p "请输入选项 (1 或 2): " choice
    case $choice in
        1)
            install_docker
            ;;
        2)
            read -p "请输入要卸载的容器名称 (默认: sing-box-container): " CONTAINER_NAME
            CONTAINER_NAME=${CONTAINER_NAME:-sing-box-container}
            read -p "请输入要卸载的 Macvlan 网络名称 (默认: macvlan-net): " MACVLAN_NET_NAME
            MACVLAN_NET_NAME=${MACVLAN_NET_NAME:-macvlan-net}
            uninstall_docker
            ;;
        *)
            echo -e "${RED}无效选项${NC}"
            exit 1
            ;;
    esac
}

# 主入口
main_menu
