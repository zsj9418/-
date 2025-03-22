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
    if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.-]+)?$ ]]; then
        echo -e "${RED}无效的版本号格式${NC}"
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

# 卸载清理 (Docker 版本)
uninstall_docker() {
    log "开始卸载 Docker sing-box..."
    docker stop sing-box-container || true
    docker rm sing-box-container || true
    docker network rm macvlan-net || true # 删除 macvlan 网络
    iptables -t nat -D POSTROUTING -s 192.168.0.0/16 -j MASQUERADE || true
    save_iptables_rules
    log "Docker sing-box 已卸载，网络配置已恢复"
}

# 获取默认网络接口
get_default_interface() {
    ip route show default | awk '/default/ {print $5}'
}

# 计算网络地址 (更通用)
calculate_network_address() {
    local ip_cidr=$1
    local ip_addr=$(echo "$ip_cidr" | cut -d'/' -f1)
    local cidr_mask=$(echo "$ip_cidr" | cut -d'/' -f2)

    # 保存当前的 IFS
    local old_ifs="$IFS"
    # 设置 IFS 为点号
    IFS='.'
    read -r octet1 octet2 octet3 octet4 <<< "$ip_addr"
    # 恢复 IFS
    IFS="$old_ifs"

    # 检查是否成功分割
    if [[ -z "$octet1" || -z "$octet2" || -z "$octet3" || -z "$octet4" ]]; then
        echo -e "${RED}IP 地址分割失败，请检查 IP 格式是否正确${NC}"
        return 1  # Indicate failure
    fi
    # 计算网络地址
    local mask=$(( 0xffffffff << (32 - cidr_mask) ))
    local ip_int=$(( (octet1 << 24) + (octet2 << 16) + (octet3 << 8) + octet4 ))
    local network_int=$(( ip_int & mask ))

    local network_octet1=$(( (network_int >> 24) & 255 ))
    local network_octet2=$(( (network_int >> 16) & 255 ))
    local network_octet3=$(( (network_int >> 8) & 255 ))
    local network_octet4=$(( network_int & 255 ))

    local network_ip="$network_octet1.$network_octet2.$network_octet3.$network_octet4"
    echo "${network_ip}/${cidr_mask}"
    return 0  # Indicate success
}

# 检测局域网段和网关
detect_lan_subnet_gateway() {
    local default_iface=$(get_default_interface)
    if [[ -z "$default_iface" ]]; then
        echo -e "${RED}无法自动检测局域网信息，请手动配置 macvlan 网络参数${NC}"
        return 1
    fi

    local ip_cidr=$(ip addr show dev "$default_iface" | awk '/inet / {print $2}' | head -n 1)  # 取第一个IP
    if [[ -z "$ip_cidr" ]]; then
        echo -e "${RED}无法获取接口 $default_iface 的 IP 信息，请手动配置 macvlan 网络参数${NC}"
        return 1
    fi

    log "Debug: ip_cidr from ip addr show: ${YELLOW}$ip_cidr${NC}" # Debug output

    if ! SUBNET=$(calculate_network_address "$ip_cidr"); then
        echo -e "${RED}计算子网失败，请手动配置 macvlan 网络参数${NC}"
        return 1
    fi

    log "Debug: Calculated SUBNET: ${YELLOW}$SUBNET${NC}" # Debug output

    GATEWAY=$(ip route show default | awk '/default/ {print $3}')

    if [[ -z "$SUBNET" || -z "$GATEWAY" ]]; then
        echo -e "${RED}自动检测局域网信息失败，请手动配置 macvlan 网络参数${NC}"
        return 1
    fi

    echo "检测到局域网段: ${GREEN}$SUBNET${NC}"
    echo "检测到网关: ${GREEN}$GATEWAY${NC}"
    echo "默认网络接口 (Parent Interface): ${GREEN}$default_iface${NC}"

    export DETECTED_SUBNET="$SUBNET"
    export DETECTED_GATEWAY="$GATEWAY"
    export DETECTED_INTERFACE="$default_iface"
    return 0
}

# 选择 Docker 网络模式
select_docker_network_mode() {
    echo -e "${GREEN}请选择 Docker 网络模式：${NC}"
    echo "1. Bridge (默认，需要端口映射)"
    echo "2. Host (高性能，共享宿主机网络)"
    echo "3. Macvlan (推荐，独立IP，直接接入物理网络)"
    read -p "请输入选项 (1, 2 或 3，默认 3: Macvlan): " network_choice

    case $network_choice in
        1)
            echo "选择 Bridge 网络模式"
            echo "请注意，Bridge 模式需要在 Docker 宿主机上进行端口映射才能访问 sing-box 服务。"
            NETWORK_MODE="bridge"
            ;;
        2)
            echo "选择 Host 网络模式"
            echo "Host 模式下 sing-box 容器将直接使用宿主机网络，性能更高，但网络隔离性较差。"
            NETWORK_MODE="host"
            ;;
        3)
            echo "选择 Macvlan 网络模式 (推荐)"
            echo "Macvlan 模式下 sing-box 容器将拥有独立IP，直接接入物理网络，性能最佳。"
            NETWORK_MODE="macvlan"
            ;;
        *)
            echo "无效选项，默认使用 Macvlan 网络模式 (推荐)"
            NETWORK_MODE="macvlan"
            ;;
    esac
    echo "Docker 网络模式选择为: ${YELLOW}${NETWORK_MODE}${NC}"
    export NETWORK_MODE  # 导出变量供 install_docker 函数使用
}

# 检查端口占用情况
check_port_usage() {
    local port=$1
    # 尝试使用 ss 命令，如果不存在则使用 netstat
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
        echo -e "${RED}缺少 ss 或 netstat 命令，无法检查端口占用情况${NC}"
        return 1 # 缺少命令也视为失败
    fi
    return 0
}

# 检查配置文件目录和权限
check_config_dir() {
    if [ ! -d "/etc/sing-box" ]; then
        echo -e "${RED}/etc/sing-box 目录不存在，请创建${NC}"
        return 1
    fi
    if [ ! -r "/etc/sing-box/config.json" ]; then
        echo -e "${RED}/etc/sing-box/config.json 文件不可读，请检查权限${NC}"
        return 1
    fi
    return 0
}

# 检测Docker版本
check_docker_version() {
    local docker_version=$(docker version --format '{{.Client.Version}}')
    # 使用 awk 提取主版本号和次版本号
    local major=$(echo "$docker_version" | awk -F. '{print $1}')
    local minor=$(echo "$docker_version" | awk -F. '{print $2}')
    # 构造最低版本号
    local min_major=1
    local min_minor=13

    # 比较主版本号和次版本号
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

    # 2. 版本选择
    read -p "选择版本类型 (测试版输入a/正式版输入s): " version_type
    case $version_type in
        a*)
            read -p "请输入测试版完整版本号 (例如: 1.12.0-alpha.9): " version
            validate_version "$version"
            repo_tag="v$version"
            file_tag="$version"
            ;;
        s*)
            read -p "请输入正式版完整版本号 (例如: 1.11.3): " version
            validate_version "$version"
            repo_tag="v$version"
            file_tag="$version"
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            exit 1
            ;;
    esac

    # 3. 安装 Docker 依赖
    install_docker_deps

    # 3.1 检查 Docker 版本
    if ! check_docker_version; then
        echo -e "${RED}Docker 版本不符合要求，请升级 Docker 后重试${NC}"
        exit 1
    fi

    # 4. 下载配置文件
    read -p "请输入配置文件订阅URL: " config_url
    validate_url "$config_url"
    mkdir -p /etc/sing-box
    if ! curl -sSL "$config_url" -o /etc/sing-box/config.json; then
        echo -e "${RED}配置文件下载失败${NC}"
        cleanup
        exit 1
    fi

    # 4.1 检查配置文件目录和权限
    if ! check_config_dir; then
        echo -e "${RED}配置文件目录或权限不正确，请检查后重试${NC}"
        cleanup
        exit 1
    fi

    # 4.2 检查端口占用情况
    if check_port_usage 10808 || check_port_usage 10809 || check_port_usage 9090; then
      echo -e "${RED}检测到端口冲突，请修改配置或停止占用端口的程序后重试${NC}"
      cleanup
      exit 1
    fi

    # 5. 选择 Docker 网络模式
    select_docker_network_mode

    # 6. Macvlan 网络模式配置
    if [[ "$NETWORK_MODE" == "macvlan" ]]; then
        log "配置 Macvlan 网络..."
        if ! detect_lan_subnet_gateway; then
            echo -e "${RED}自动检测局域网信息失败，请手动配置 macvlan 网络参数${NC}"
            read -p "请输入局域网段 (例如: 192.168.3.0/24): " MANUAL_SUBNET
            read -p "请输入网关地址 (例如: 192.168.3.18): " MANUAL_GATEWAY
            read -p "请输入父接口 (例如: enx000a4300999a): " MANUAL_INTERFACE
            SUBNET="$MANUAL_SUBNET"
            GATEWAY="$MANUAL_GATEWAY"
            PARENT_INTERFACE="$MANUAL_INTERFACE"
        else
            SUBNET="$DETECTED_SUBNET" # 使用自动检测到的 SUBNET (现在应该是网络地址)
            GATEWAY="$DETECTED_GATEWAY"
            PARENT_INTERFACE="$DETECTED_INTERFACE"
        fi

        read -p "请输入 sing-box 容器静态IP地址 (例如: 192.168.3.10, 确保在 ${SUBNET} 网段内且未被占用): " STATIC_IP
        MACVLAN_IP="$STATIC_IP"

        log "创建 macvlan 网络: macvlan-net"
        MACVLAN_CREATE_CMD="docker network create -d macvlan --subnet=${SUBNET} --gateway=${GATEWAY} -o parent=${PARENT_INTERFACE} macvlan-net"
        log "执行命令: ${YELLOW}${MACVLAN_CREATE_CMD}${NC}"
        if ! eval "$MACVLAN_CREATE_CMD"; then
            echo -e "${RED}创建 macvlan 网络失败，请检查参数或手动创建${NC}"
            exit 1
        fi
        log "macvlan 网络创建成功"
    fi

    # 7. 运行 Docker 容器
    DOWNLOAD_URL="ghcr.io/sagernet/sing-box:latest" # 使用 Docker Hub 官方镜像
    log "Docker 镜像: ${DOWNLOAD_URL}"

    DOCKER_RUN_CMD="docker run -d --name sing-box-container --restart always --memory=128m --cpus=0.5"

    case "$NETWORK_MODE" in
        host)
            DOCKER_RUN_CMD="$DOCKER_RUN_CMD --net host"
            log "使用 Host 网络模式"
            ;;
        macvlan)
            DOCKER_RUN_CMD="$DOCKER_RUN_CMD --network macvlan-net --ip ${MACVLAN_IP}"
            log "使用 Macvlan 网络模式，静态IP: ${MACVLAN_IP}"
            ;;
        bridge|*) # 默认 Bridge
            DOCKER_RUN_CMD="$DOCKER_RUN_CMD -p 10808:10808 -p 10809:10809 -p 9090:9090 -p 1900:1900/udp --net bridge" # 默认 Bridge 模式，添加常用端口映射
            log "使用 Bridge 网络模式，映射端口 10808:10808 (redir), 10809:10809 (http), 9090:9090 (UI), 1900:1900/udp (mDNS)"
            NETWORK_MODE="bridge" # 确保 NETWORK_MODE 变量在默认情况下为 bridge
            ;;
    esac

     DOCKER_RUN_CMD="$DOCKER_RUN_CMD -v /etc/sing-box/config.json:/etc/sing-box/config.json $DOWNLOAD_URL"

    log "执行 Docker 命令: ${YELLOW}${DOCKER_RUN_CMD}${NC}"
        if ! eval "$DOCKER_RUN_CMD"; then # 使用 eval 执行动态构建的命令
        echo -e "${RED}Docker 容器启动失败，请检查 Docker 日志${NC}"
        docker logs sing-box-container
        cleanup
        exit 1
     fi
    # 8. 网络配置 (与非 Docker 版本相同)
    GATEWAY_IP=$(get_gateway_ip) # 仍然获取宿主机网关IP，用于 iptables NAT 规则
    log "配置网关地址: ${GATEWAY_IP}"

    enable_ip_forwarding
    check_default_route
    iptables -t nat -A POSTROUTING -s 192.168.0.0/16 -j MASQUERADE
    save_iptables_rules

    # 9. 检查iptables规则和网络
    check_iptables
    check_network

    # 显示使用信息
    echo -e "${GREEN}Docker sing-box 安装完成！请将其他设备的网关设置为: ${GATEWAY_IP}${NC}"
    if [[ "$NETWORK_MODE" == "bridge" ]]; then
        echo -e "请确保您的设备连接到 ${GATEWAY_IP}:10808 (redir 代理) 或 ${GATEWAY_IP}:10809 (http 代理), UI: ${GATEWAY_IP}:9090"
    elif [[ "$NETWORK_MODE" == "macvlan" ]]; then
        echo -e "请将其他设备的网关设置为: ${MACVLAN_IP} (Macvlan 模式)"
    fi
    echo -e "Docker 容器状态检查: ${YELLOW}docker ps -a${NC}"
    echo -e "Docker 容器日志查看: ${YELLOW}docker logs sing-box-container${NC}"
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
