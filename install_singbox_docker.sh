#!/bin/bash
set -uo pipefail  # 移除 set -e，避免小错误导致退出

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

# 检查 Docker 服务
check_docker_service() {
    log "检查 Docker 服务状态..."
    if ! systemctl is-active --quiet docker; then
        echo -e "${RED}Docker 服务未运行，尝试启动...${NC}"
        systemctl start docker || {
            echo -e "${RED}无法启动 Docker 服务，请检查环境${NC}"
            exit 1
        }
    fi
    log "Docker 服务正常运行"
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
    check_docker_service
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
    if ping -c 1 -W 1 "$ip" >/dev/null 2>&1; then
        echo -e "${RED}IP $ip 已被占用，请选择其他 IP${NC}"
        return 1
    else
        log "IP $ip 未被占用"
        return 0
    fi
}

# 定义临时目录
TEMP_DIR="/tmp/singbox_mihomo_install"

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
        log "iptables NAT 规则未生效，重新配置..."
        iptables -t nat -A POSTROUTING -s 192.168.0.0/16 -j MASQUERADE || {
            echo -e "${RED}配置 iptables NAT 规则失败${NC}"
            exit 1
        }
    fi
    log "检查 iptables 入站规则..."
    if ! iptables -L INPUT | grep -q "192.168.3.181"; then
        log "添加 Sing-box 入站规则，允许访问代理端口..."
        iptables -A INPUT -d 192.168.3.181 -p tcp -m multiport --dports 10808,10809,9090 -j ACCEPT || {
            echo -e "${RED}添加 Sing-box iptables 规则失败${NC}"
            exit 1
        }
    fi
    if ! iptables -L INPUT | grep -q "192.168.3.182"; then
        log "添加 Mihomo 入站规则，允许访问代理端口..."
        iptables -A INPUT -d 192.168.3.182 -p tcp -m multiport --dports 7890,7891,7892,7893,7894,9095,1053 -j ACCEPT || {
            echo -e "${RED}添加 Mihomo TCP iptables 规则失败${NC}"
            exit 1
        }
        iptables -A INPUT -d 192.168.3.182 -p udp -m multiport --dports 7890,7891,7892,7893,7894,1053 -j ACCEPT || {
            echo -e "${RED}添加 Mihomo UDP iptables 规则失败${NC}"
            exit 1
        }
    fi
    save_iptables_rules
}

# 保存iptables规则
save_iptables_rules() {
    mkdir -p /etc/iptables
    iptables-save | tee /etc/iptables/rules.v4 >/dev/null || {
        echo -e "${RED}保存 iptables 规则失败${NC}"
        exit 1
    }
}

# 检查网络通畅性
check_network() {
    log "检查网络通畅性..."
    if ! ping -c 1 8.8.8.8 >/dev/null 2>&1; then
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
    sysctl -w net.ipv4.ip_forward=1 || {
        echo -e "${RED}启用网络转发失败${NC}"
        exit 1
    }
    echo 'net.ipv4.ip_forward=1' | tee -a /etc/sysctl.conf >/dev/null
    log "网络转发已启用"
}

# 卸载清理
uninstall_docker() {
    local project=$1
    if [[ "$project" == "sing-box" ]]; then
        log "开始卸载 Docker sing-box..."
        docker stop "$CONTAINER_NAME" || true
        docker rm "$CONTAINER_NAME" || true
        if ! docker ps -a --format '{{.Names}}' | grep -q "$MIHOMO_CONTAINER_NAME"; then
            docker network rm "$MACVLAN_NET_NAME" || true
        fi
    elif [[ "$project" == "mihomo" ]]; then
        log "开始卸载 Docker mihomo..."
        docker stop "$MIHOMO_CONTAINER_NAME" || true
        docker rm "$MIHOMO_CONTAINER_NAME" || true
        if ! docker ps -a --format '{{.Names}}' | grep -q "$CONTAINER_NAME"; then
            docker network rm "$MACVLAN_NET_NAME" || true
        fi
    fi
    iptables -t nat -D POSTROUTING -s 192.168.0.0/16 -j MASQUERADE || true
    iptables -D INPUT -d 192.168.3.181 -p tcp -m multiport --dports 10808,10809,9090 -j ACCEPT || true
    iptables -D INPUT -d 192.168.3.182 -p tcp -m multiport --dports 7890,7891,7892,7893,7894,9095,1053 -j ACCEPT || true
    iptables -D INPUT -d 192.168.3.182 -p udp -m multiport --dports 7890,7891,7892,7893,7894,1053 -j ACCEPT || true
    save_iptables_rules
    log "Docker $project 已卸载，网络配置已恢复"
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
    log "检查端口 $port 是否被占用..."
    if command -v ss >/dev/null 2>&1; then
        if ss -tuln | grep -q ":$port"; then
            echo -e "${RED}端口 $port 已经被占用，请修改配置或停止占用端口的程序${NC}"
            return 1
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if netstat -tuln | grep -q ":$port"; then
            echo -e "${RED}端口 $port 已经被占用，请修改配置或停止占用端口的程序${NC}"
            return 1
        fi
    else
        echo -e "${YELLOW}缺少 ss 或 netstat 命令，无法检查端口占用情况${NC}"
        return 0
    fi
    log "端口 $port 未被占用"
    return 0
}

# 检查配置文件目录和权限
check_config_dir() {
    local config_dir=$1
    local config_file=$2
    local format=$3
    if [ ! -d "$config_dir" ]; then
        echo -e "${RED}$config_dir 目录不存在，请创建${NC}"
        return 1
    fi
    if [ ! -r "$config_dir/$config_file" ]; then
        echo -e "${RED}$config_dir/$config_file 文件不可读，请检查权限${NC}"
        return 1
    fi
    if [[ "$format" == "json" ]]; then
        if command -v jq >/dev/null 2>&1; then
            if ! jq . "$config_dir/$config_file" >/dev/null 2>&1; then
                echo -e "${RED}$config_dir/$config_file 不是有效的 JSON 文件${NC}"
                return 1
            fi
        else
            echo -e "${YELLOW}未安装 jq，无法验证 JSON 格式，请确保 $config_file 有效${NC}"
        fi
    elif [[ "$format" == "yaml" ]]; then
        if command -v yq >/dev/null 2>&1; then
            if ! yq e . "$config_dir/$config_file" >/dev/null 2>&1; then
                echo -e "${RED}$config_dir/$config_file 不是有效的 YAML 文件${NC}"
                return 1
            fi
        else
            echo -e "${YELLOW}未安装 yq，无法验证 YAML 格式，请确保 $config_file 有效${NC}"
        fi
    fi
    chmod 644 "$config_dir/$config_file"
    chown root:root "$config_dir/$config_file"
    log "配置文件 $config_dir/$config_file 已验证，权限已设置为 644"
    return 0
}

# 检查Docker版本
check_docker_version() {
    local docker_version=$(docker version --format '{{.Client.Version}}' 2>/dev/null || true)
    if [[ -z "$docker_version" ]]; then
        echo -e "${RED}无法获取 Docker 版本，请检查 Docker 安装${NC}"
        exit 1
    fi
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

# 清理旧容器
clean_old_container() {
    local container_name=$1
    if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
        log "检测到旧容器 $container_name，正在清理..."
        docker stop "$container_name" >/dev/null 2>&1 || true
        docker rm "$container_name" >/dev/null 2>&1 || true
        log "旧容器 $container_name 已清理"
    else
        log "未检测到旧容器 $container_name"
    fi
}

# 部署 Sing-box
install_singbox() {
    check_root
    trap 'echo -e "${RED}安装中断，正在清理...${NC}"; cleanup; exit 1' INT

    # 1. 架构检测
    ARCH=$(get_arch)
    log "检测到系统架构: ${ARCH}"

    # 2. 用户自定义容器名称
    read -p "请输入 Sing-box 容器名称 (默认: sing-box-container): " CONTAINER_NAME
    CONTAINER_NAME=${CONTAINER_NAME:-sing-box-container}
    log "Sing-box 容器名称: ${YELLOW}$CONTAINER_NAME${NC}"

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
    read -p "请输入 Sing-box 配置文件订阅URL: " CONFIG_URL
    validate_url "$CONFIG_URL"
    read -p "请输入 Sing-box 配置文件存储路径 (默认: /etc/sing-box): " CONFIG_DIR
    CONFIG_DIR=${CONFIG_DIR:-/etc/sing-box}
    mkdir -p "$CONFIG_DIR"
    if ! curl -sSL "$CONFIG_URL" -o "$CONFIG_DIR/config.json"; then
        echo -e "${RED}Sing-box 配置文件下载失败${NC}"
        cleanup
        exit 1
    fi
    if ! check_config_dir "$CONFIG_DIR" "config.json" "json"; then
        echo -e "${RED}Sing-box 配置文件目录或权限不正确，请检查后重试${NC}"
        cleanup
        exit 1
    fi

    # 6. 检查 Macvlan 网络
    MACVLAN_NET_NAME="${SHARED_MACVLAN_NET_NAME:-macvlan-net}"
    log "Sing-box 将使用 Macvlan 网络: ${YELLOW}$MACVLAN_NET_NAME${NC}"

    if ! docker network inspect "$MACVLAN_NET_NAME" >/dev/null 2>&1; then
        log "Macvlan 网络 $MACVLAN_NET_NAME 不存在，正在创建..."
        if ! detect_lan_subnet_gateway; then
            echo -e "${RED}自动检测局域网信息失败，请手动配置 macvlan 网络参数${NC}"
            read -p "请输入局域网段 (例如: 192.168.3.0/24): " SUBNET
            read -p "请输入网关地址 (例如: 192.168.3.18): " GATEWAY
            read -p "请输入父接口 (例如: enx000a4300999a): " PARENT_INTERFACE
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

        log "创建 Sing-box macvlan 网络: $MACVLAN_NET_NAME"
        if ! docker network create -d macvlan --subnet="${SUBNET}" --gateway="${GATEWAY}" -o parent="${PARENT_INTERFACE}" "$MACVLAN_NET_NAME"; then
            echo -e "${RED}创建 Sing-box macvlan 网络失败，请检查参数或手动创建${NC}"
            echo -e "${YELLOW}建议：运行 'docker network ls' 和 'docker network inspect <网络名>' 检查冲突${NC}"
            exit 1
        fi
        log "Sing-box macvlan 网络创建成功"

        # 保存网络参数
        export SHARED_MACVLAN_NET_NAME="$MACVLAN_NET_NAME"
        export SHARED_SUBNET="$SUBNET"
        export SHARED_GATEWAY="$GATEWAY"
        export SHARED_PARENT_INTERFACE="$PARENT_INTERFACE"
    else
        log "Macvlan 网络 $MACVLAN_NET_NAME 已存在，Sing-box 将复用"
        SUBNET=$(docker network inspect "$MACVLAN_NET_NAME" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}')
        GATEWAY=$(docker network inspect "$MACVLAN_NET_NAME" --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}')
        PARENT_INTERFACE=$(docker network inspect "$MACVLAN_NET_NAME" --format '{{.Options.parent}}')
        export SHARED_SUBNET="$SUBNET"
        export SHARED_GATEWAY="$GATEWAY"
        export SHARED_PARENT_INTERFACE="$PARENT_INTERFACE"
    fi

    # 7. 输入静态 IP
    read -p "请输入 Sing-box 容器静态IP地址 (例如: 192.168.3.181, 确保在 ${SUBNET} 网段内且未被占用): " MACVLAN_IP
    if ! validate_ip_in_subnet "$MACVLAN_IP" "$SUBNET"; then
        exit 1
    fi
    if ! check_ip_occupied "$MACVLAN_IP"; then
        exit 1
    fi

    # 8. 检查端口占用
    for port in 10808 10809 9090; do
        if ! check_port_usage "$port"; then
            exit 1
        fi
    done

    # 9. 清理旧容器
    clean_old_container "$CONTAINER_NAME"

    # 10. 运行 Sing-box 容器
    DOWNLOAD_URL="ghcr.io/sagernet/sing-box:$VERSION"
    log "Sing-box Docker 镜像: ${YELLOW}$DOWNLOAD_URL${NC}"

    DOCKER_RUN_CMD="docker run -d --privileged --name \"$CONTAINER_NAME\" --restart always --memory=128m --cpus=0.5 --network \"$MACVLAN_NET_NAME\" --ip \"$MACVLAN_IP\" -v \"$CONFIG_DIR\":/etc/sing-box $DOWNLOAD_URL run -c /etc/sing-box/config.json"

    log "执行 Sing-box Docker 命令: ${YELLOW}${DOCKER_RUN_CMD}${NC}"
    if ! eval "$DOCKER_RUN_CMD"; then
        echo -e "${RED}Sing-box Docker 容器启动失败，请检查 Docker 日志${NC}"
        docker logs "$CONTAINER_NAME" 2>/dev/null || true
        echo -e "${YELLOW}建议：验证配置文件路径和内容：${NC}"
        echo -e "  cat $CONFIG_DIR/config.json"
        echo -e "  docker run --rm -v $CONFIG_DIR:/etc/sing-box $DOWNLOAD_URL check -c /etc/sing-box/config.json"
        cleanup
        exit 1
    fi

    # 11. 网络配置
    GATEWAY_IP=$(get_gateway_ip)
    log "配置网关地址: ${GATEWAY_IP}"
    enable_ip_forwarding
    check_default_route
    check_iptables
    check_network

    # 12. 显示使用信息
    echo -e "${GREEN}Sing-box Docker 安装完成！${NC}"
    echo -e "请将客户端网关设置为: ${MACVLAN_IP}"
    echo -e "代理端口根据配置文件确定（默认 HTTP: 10809, SOCKS: 10808, 管理界面: 9090）"
    echo -e "容器状态检查: ${YELLOW}docker ps -a${NC}"
    echo -e "容器日志查看: ${YELLOW}docker logs $CONTAINER_NAME${NC}"
}

# 部署 Mihomo
install_mihomo() {
    check_root
    trap 'echo -e "${RED}安装中断，正在清理...${NC}"; cleanup; exit 1' INT

    # 1. 架构检测
    ARCH=$(get_arch)
    log "检测到系统架构: ${ARCH}"

    # 2. 用户自定义容器名称
    read -p "请输入 Mihomo 容器名称 (默认: mihomo10): " MIHOMO_CONTAINER_NAME
    MIHOMO_CONTAINER_NAME=${MIHOMO_CONTAINER_NAME:-mihomo10}
    log "Mihomo 容器名称: ${YELLOW}$MIHOMO_CONTAINER_NAME${NC}"

    # 3. 用户选择镜像版本
    read -p "请输入 Mihomo 镜像版本 (例如: 1.18.7 或 latest, 默认: latest): " MIHOMO_VERSION
    MIHOMO_VERSION=${MIHOMO_VERSION:-latest}
    validate_version "$MIHOMO_VERSION"
    log "Mihomo 镜像版本: ${YELLOW}$MIHOMO_VERSION${NC}"

    # 4. 安装 Docker 依赖
    install_docker_deps
    if ! check_docker_version; then
        echo -e "${RED}Docker 版本不符合要求，请升级 Docker 后重试${NC}"
        exit 1
    fi

    # 5. 下载配置文件
    read -p "请输入 Mihomo 配置文件订阅URL: " MIHOMO_CONFIG_URL
    validate_url "$MIHOMO_CONFIG_URL"
    read -p "请输入 Mihomo 配置文件存储路径 (默认: /etc/mihomo): " MIHOMO_CONFIG_DIR
    MIHOMO_CONFIG_DIR=${MIHOMO_CONFIG_DIR:-/etc/mihomo}
    mkdir -p "$MIHOMO_CONFIG_DIR"
    if ! curl -sSL "$MIHOMO_CONFIG_URL" -o "$MIHOMO_CONFIG_DIR/config.yaml"; then
        echo -e "${RED}Mihomo 配置文件下载失败${NC}"
        cleanup
        exit 1
    fi
    if ! check_config_dir "$MIHOMO_CONFIG_DIR" "config.yaml" "yaml"; then
        echo -e "${RED}Mihomo 配置文件目录或权限不正确，请检查后重试${NC}"
        cleanup
        exit 1
    fi

    # 6. 检查 Macvlan 网络
    MIHOMO_NET_NAME="${SHARED_MACVLAN_NET_NAME:-macvlan-net}"
    log "Mihomo 将使用 Macvlan 网络: ${YELLOW}$MIHOMO_NET_NAME${NC}"

    if ! docker network inspect "$MIHOMO_NET_NAME" >/dev/null 2>&1; then
        log "Macvlan 网络 $MIHOMO_NET_NAME 不存在，正在创建..."
        if ! detect_lan_subnet_gateway; then
            echo -e "${RED}自动检测局域网信息失败，请手动配置 macvlan 网络参数${NC}"
            read -p "请输入局域网段 (例如: 192.168.3.0/24): " MIHOMO_SUBNET
            read -p "请输入网关地址 (例如: 192.168.3.18): " MIHOMO_GATEWAY
            read -p "请输入父接口 (例如: enx000a4300999a): " MIHOMO_PARENT_INTERFACE
        else
            MIHOMO_SUBNET="$DETECTED_SUBNET"
            MIHOMO_GATEWAY="$DETECTED_GATEWAY"
            MIHOMO_PARENT_INTERFACE="$DETECTED_INTERFACE"
        fi

        # 检查子网冲突
        if ! check_network_conflict "$MIHOMO_SUBNET"; then
            echo -e "${YELLOW}建议：运行 'docker network ls' 查看现有网络，删除冲突网络后重试${NC}"
            read -p "是否尝试自动删除同名网络 $MIHOMO_NET_NAME？(y/N): " DELETE_NET
            if [[ "$DELETE_NET" =~ ^[Yy]$ ]]; then
                docker network rm "$MIHOMO_NET_NAME" || true
            else
                echo -e "${RED}请手动删除冲突网络或选择其他子网后重试${NC}"
                exit 1
            fi
        fi

        log "创建 Mihomo macvlan 网络: $MIHOMO_NET_NAME"
        if ! docker network create -d macvlan --subnet="${MIHOMO_SUBNET}" --gateway="${MIHOMO_GATEWAY}" -o parent="${MIHOMO_PARENT_INTERFACE}" "$MIHOMO_NET_NAME"; then
            echo -e "${RED}创建 Mihomo macvlan 网络失败，请检查参数或手动创建${NC}"
            echo -e "${YELLOW}建议：运行 'docker network ls' 和 'docker network inspect <网络名>' 检查冲突${NC}"
            exit 1
        fi
        log "Mihomo macvlan 网络创建成功"

        # 保存网络参数
        export SHARED_MACVLAN_NET_NAME="$MIHOMO_NET_NAME"
        export SHARED_SUBNET="$MIHOMO_SUBNET"
        export SHARED_GATEWAY="$MIHOMO_GATEWAY"
        export SHARED_PARENT_INTERFACE="$MIHOMO_PARENT_INTERFACE"
    else
        log "Macvlan 网络 $MIHOMO_NET_NAME 已存在，Mihomo 将复用"
        MIHOMO_SUBNET=$(docker network inspect "$MIHOMO_NET_NAME" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}')
        MIHOMO_GATEWAY=$(docker network inspect "$MIHOMO_NET_NAME" --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}')
        MIHOMO_PARENT_INTERFACE=$(docker network inspect "$MIHOMO_NET_NAME" --format '{{.Options.parent}}')
        export SHARED_SUBNET="$MIHOMO_SUBNET"
        export SHARED_GATEWAY="$MIHOMO_GATEWAY"
        export SHARED_PARENT_INTERFACE="$MIHOMO_PARENT_INTERFACE"
    fi

    # 7. 输入静态 IP
    read -p "请输入 Mihomo 容器静态IP地址 (例如: 192.168.3.182, 确保在 ${MIHOMO_SUBNET} 网段内且未被占用): " MIHOMO_IP
    MIHOMO_IP=${MIHOMO_IP:-192.168.3.182}
    if ! validate_ip_in_subnet "$MIHOMO_IP" "$MIHOMO_SUBNET"; then
        exit 1
    fi
    if ! check_ip_occupied "$MIHOMO_IP"; then
        exit 1
    fi

    # 8. 检查端口占用
    for port in 7890 7891 7892 7893 7894 9095 1053; do
        if ! check_port_usage "$port"; then
            exit 1
        fi
    done

    # 9. 清理旧容器
    clean_old_container "$MIHOMO_CONTAINER_NAME"

    # 10. 运行 Mihomo 容器
    MIHOMO_DOWNLOAD_URL="metacubex/mihomo:$MIHOMO_VERSION"
    log "Mihomo Docker 镜像: ${YELLOW}$MIHOMO_DOWNLOAD_URL${NC}"

    MIHOMO_DOCKER_RUN_CMD="docker run -d --privileged --name \"$MIHOMO_CONTAINER_NAME\" --restart always --network \"$MIHOMO_NET_NAME\" --ip \"$MIHOMO_IP\" -v \"$MIHOMO_CONFIG_DIR\":/root/.config/mihomo $MIHOMO_DOWNLOAD_URL"

    log "执行 Mihomo Docker 命令: ${YELLOW}${MIHOMO_DOCKER_RUN_CMD}${NC}"
    if ! eval "$MIHOMO_DOCKER_RUN_CMD"; then
        echo -e "${RED}Mihomo Docker 容器启动失败，请检查 Docker 日志${NC}"
        docker logs "$MIHOMO_CONTAINER_NAME" 2>/dev/null || true
        echo -e "${YELLOW}建议：验证配置文件路径和内容：${NC}"
        echo -e "  cat $MIHOMO_CONFIG_DIR/config.yaml"
        cleanup
        exit 1
    fi

    # 11. 网络配置
    GATEWAY_IP=$(get_gateway_ip)
    log "配置网关地址: ${GATEWAY_IP}"
    enable_ip_forwarding
    check_default_route
    check_iptables
    check_network

    # 12. 显示使用信息
    echo -e "${GREEN}Mihomo Docker 安装完成！${NC}"
    echo -e "请将客户端网关设置为: ${MIHOMO_IP}"
    echo -e "代理端口："
    echo -e "  - HTTP/SOCKS: ${MIHOMO_IP}:7893 (mixed-port)"
    echo -e "  - 管理界面: ${MIHOMO_IP}:9095"
    echo -e "  - DNS: ${MIHOMO_IP}:1053"
    echo -e "容器状态检查: ${YELLOW}docker ps -a${NC}"
    echo -e "容器日志查看: ${YELLOW}docker logs $MIHOMO_CONTAINER_NAME${NC}"
}

# 主菜单
main_menu() {
    while true; do
        echo -e "${GREEN}请选择操作：${NC}"
        echo "1. 安装 Docker Sing-box"
        echo "2. 安装 Docker Mihomo"
        echo "3. 卸载 Docker Sing-box"
        echo "4. 卸载 Docker Mihomo"
        echo "5. 退出"
        read -p "请输入选项 (1, 2, 3, 4 或 5): " choice
        case $choice in
            1)
                install_singbox
                ;;
            2)
                install_mihomo
                ;;
            3)
                read -p "请输入要卸载的 Sing-box 容器名称 (默认: sing-box-container): " CONTAINER_NAME
                CONTAINER_NAME=${CONTAINER_NAME:-sing-box-container}
                read -p "请输入要卸载的 Sing-box Macvlan 网络名称 (默认: macvlan-net): " MACVLAN_NET_NAME
                MACVLAN_NET_NAME=${MACVLAN_NET_NAME:-macvlan-net}
                uninstall_docker "sing-box"
                ;;
            4)
                read -p "请输入要卸载的 Mihomo 容器名称 (默认: mihomo10): " MIHOMO_CONTAINER_NAME
                MIHOMO_CONTAINER_NAME=${MIHOMO_CONTAINER_NAME:-mihomo10}
                read -p "请输入要卸载的 Mihomo Macvlan 网络名称 (默认: macvlan-net): " MACVLAN_NET_NAME
                MACVLAN_NET_NAME=${MACVLAN_NET_NAME:-macvlan-net}
                uninstall_docker "mihomo"
                ;;
            5)
                echo -e "${GREEN}退出脚本${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选项，请选择 1, 2, 3, 4 或 5${NC}"
                ;;
        esac
        echo -e "\n${YELLOW}操作完成，按 Enter 返回主菜单...${NC}"
        read -r
    done
}

# 主入口
main_menu
