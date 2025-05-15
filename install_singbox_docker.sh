#!/bin/bash
set -euo pipefail

# 预定义变量，确保不会未绑定
: "${CONFIG_DIR:=/etc/sing-box}"
: "${SINGBOX_PORTS:=()}"
: "${MIHOMO_CONFIG_DIR:=/etc/mihomo}"
: "${MIHOMO_CONTAINER_NAME:=docker-mihomo}"
: "${CONTAINER_NAME:=docker-mihomo}"
: "${MACVLAN_NET_NAME:=macvlan-net}"
: "${SHARED_MACVLAN_NET_NAME:=macvlan-net}"
: "${SHARED_SUBNET:=}"
: "${SHARED_GATEWAY:=}"
: "${SHARED_PARENT_INTERFACE:=}"

# 脚本版本和元数据
SCRIPT_VERSION="1.2.0"
SCRIPT_NAME="Sing-box 和 Mihomo Docker 安装器"

# 定义颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# 日志函数
log() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

# 检查是否以 root 用户运行
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}此脚本必须以 root 用户运行${NC}"
        exit 1
    fi
}

# 检查系统要求
check_system_requirements() {
    log "检查系统要求..."
    local kernel_version=$(uname -r | cut -d. -f1-2)
    if [[ $(echo "$kernel_version < 3.10" | bc -l) -eq 1 ]]; then
        echo -e "${RED}内核版本过低 ($kernel_version)，需要 3.10 或更高${NC}"
        exit 1
    fi
    if ! command -v docker &>/dev/null; then
        echo -e "${RED}未安装 Docker，将在后续步骤中安装${NC}"
    fi
    log "系统要求检查通过"
}

# 获取架构
get_arch() {
    local arch=$(uname -m)
    case $arch in
        x86_64) echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l) echo "armv7" ;;
        armv6l) echo "armv6" ;;
        riscv64) echo "riscv64" ;;
        i686|i386) echo "386" ;;
        s390x) echo "s390x" ;;
        ppc64le) echo "ppc64le" ;;
        *)
            log "尝试使用 dpkg 获取架构..."
            if command -v dpkg &>/dev/null; then
                arch=$(dpkg --print-architecture)
                case $arch in
                    amd64|arm64|armhf|armel|riscv64|i386|s390x|ppc64el) echo "$arch" ;;
                    *) echo -e "${RED}不支持的架构: $arch${NC}" >&2; exit 1 ;;
                esac
            else
                echo -e "${RED}未知架构: $arch，无法确定兼容性${NC}" >&2
                exit 1
            fi
            ;;
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

# 安装依赖 (Docker, jq, yq)
install_docker_deps() {
    log "检查 Docker 依赖..."
    if ! command -v docker &>/dev/null; then
        log "未安装 Docker，尝试安装 Docker..."
        if command -v apt &>/dev/null; then
            apt update
            apt install -y apt-transport-https ca-certificates curl software-properties-common
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
            add-apt-repository "deb [arch=$(dpkg --print-architecture)] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
            apt update
            apt install -y docker-ce docker-ce-cli containerd.io
            systemctl enable docker
            systemctl start docker
        elif command -v yum &>/dev/null; then
            yum install -y yum-utils
            yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            yum install -y docker-ce docker-ce-cli containerd.io
            systemctl enable docker
            systemctl start docker
        elif command -v zypper &>/dev/null; then
            zypper install -y docker
            systemctl enable docker
            systemctl start docker
        elif command -v pacman &>/dev/null; then
            pacman -Sy --noconfirm docker
            systemctl enable docker
            systemctl start docker
        elif command -v apk &>/dev/null; then
            apk add docker
            systemctl enable docker
            systemctl start docker
        else
            echo -e "${RED}不支持的包管理器，请手动安装 Docker${NC}"
            exit 1
        fi
        log "Docker 安装完成"
    else
        log "Docker 已安装"
    fi
    check_docker_service
}

# 安装 jq 和 yq
install_jq_yq() {
    log "检查是否安装 jq 和 yq..."
    if ! command -v jq &>/dev/null; then
        log "安装 jq..."
        if command -v apt &>/dev/null; then
            apt update && apt install -y jq
        elif command -v yum &>/dev/null; then
            yum install -y jq
        elif command -v zypper &>/dev/null; then
            zypper install -y jq
        elif command -v pacman &>/dev/null; then
            pacman -Sy --noconfirm jq
        elif command -v apk &>/dev/null; then
            apk add jq
        else
            echo -e "${YELLOW}无法自动安装 jq，将尝试基本格式检查${NC}"
        fi
    fi
    if ! command -v yq &>/dev/null; then
        log "安装 yq..."
        if command -v apt &>/dev/null; then
            apt update && apt install -y yq
        elif command -v yum &>/dev/null; then
            yum install -y yq
        elif command -v zypper &>/dev/null; then
            zypper install -y yq
        elif command -v pacman &>/dev/null; then
            pacman -Sy --noconfirm yq
        elif command -v apk &>/dev/null; then
            apk add yq
        else
            echo -e "${YELLOW}无法自动安装 yq，将尝试基本格式检查${NC}"
        fi
    fi
}

# 获取网关 IP
get_gateway_ip() {
    local iface=$(ip route show default | awk '/default/ {print $5}')
    if [[ -z $iface ]]; then
        echo -e "${RED}无法确定默认网络接口${NC}"
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

# 验证 URL
validate_url() {
    local url=$1
    if [[ ! $url =~ ^https?:// ]]; then
        echo -e "${RED}无效的 URL，必须以 http:// 或 https:// 开头${NC}"
        exit 1
    fi
}

# 验证 URL 安全性（支持 IP 地址和域名）
validate_url_security() {
    local url=$1
    local host=$(echo "$url" | awk -F/ '{print $3}' | cut -d':' -f1)
    log "检查 URL 主机: $host"
    if echo "$host" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        log "URL 使用 IP 地址: $host，跳过 DNS 解析"
        return 0
    fi
    if ! host "$host" >/dev/null 2>&1; then
        echo -e "${RED}无法解析主机 $host，请检查 URL 或网络${NC}"
        return 1
    fi
    return 0
}

# 验证 IP 是否在子网内
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
    if (( (ip_int & mask) != (network_int & mask) )); then
        echo -e "${RED}IP $ip 不在子网 $subnet 内${NC}"
        return 1
    fi
    return 0
}

# 验证 IPv6 配置
validate_ipv6_config() {
    local subnet=$1
    local gateway=$2
    if [[ -z "$subnet" || -z "$gateway" ]]; then
        log "IPv6 子网或网关为空，跳过 IPv6 配置"
        return 1
    fi
    if [[ "$gateway" =~ ^fe80:: ]]; then
        log "IPv6 网关 $gateway 是链路本地地址，跳过 IPv6 配置"
        return 1
    fi
    if [[ "$subnet" =~ /128$ ]]; then
        log "IPv6 子网 $subnet 是单地址子网，跳过 IPv6 配置"
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

# 检查 IPv6 支持
check_ipv6_support() {
    log "检查 IPv6 支持..."
    if [[ -f /proc/sys/net/ipv6/conf/all/disable_ipv6 ]] && [[ $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6) -eq 0 ]]; then
        IPV6_ENABLED=1
        log "IPv6 已启用"
    else
        IPV6_ENABLED=0
        log "IPv6 未启用，仅使用 IPv4"
    fi
}

# 检查网卡混杂模式支持
check_promisc_support() {
    local iface=$1
    log "检查网卡 $iface 是否支持混杂模式..."
    if ! ip link set "$iface" promisc on >/dev/null 2>&1; then
        echo -e "${RED}网卡 $iface 不支持混杂模式，Macvlan 可能无法正常工作${NC}"
        read -p "是否切换到桥接网络？(y/N): " USE_BRIDGE
        if [[ "$USE_BRIDGE" =~ ^[Yy]$ ]]; then
            NETWORK_MODE="bridge"
            log "切换到桥接网络模式"
        else
            echo -e "${RED}请更换支持混杂模式的网卡或手动配置网络${NC}"
            exit 1
        fi
    else
        ip link set "$iface" promisc off >/dev/null 2>&1
        NETWORK_MODE="macvlan"
        log "网卡 $iface 支持混杂模式"
    fi
}

# 持久化混杂模式
enable_persistent_promisc() {
    local iface=$1
    log "为网卡 $iface 配置持久化混杂模式..."
    if command -v systemctl &>/dev/null; then
        local promisc_service="/etc/systemd/system/promisc-$iface.service"
        if [[ ! -f "$promisc_service" ]]; then
            cat << EOF > "$promisc_service"
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
            systemctl enable "promisc-$iface.service"
            systemctl start "promisc-$iface.service"
            log "已为 $iface 配置 systemd 服务以持久化混杂模式"
        else
            log "混杂模式服务已存在: $promisc_service"
        fi
    elif command -v rc-update &>/dev/null; then
        echo "/sbin/ip link set $iface promisc on" >> /etc/local.d/promisc.start
        chmod +x /etc/local.d/promisc.start
        log "已为 $iface 配置 OpenRC 脚本以持久化混杂模式"
    else
        echo -e "${YELLOW}未检测到 systemd 或 OpenRC，需手动配置混杂模式持久化${NC}"
        echo -e "手动命令：/sbin/ip link set $iface promisc on"
    fi
}

# 安装 iptables 持久化工具
install_iptables_persistent() {
    log "检查 iptables 持久化支持..."
    if command -v apt &>/dev/null; then
        if ! dpkg -l | grep -q iptables-persistent; then
            log "安装 iptables-persistent..."
            apt update && apt install -y iptables-persistent
        fi
    elif command -v yum &>/dev/null; then
        if ! rpm -q iptables-services &>/dev/null; then
            log "安装 iptables-services..."
            yum install -y iptables-services
        fi
    elif command -v zypper &>/dev/null; then
        zypper install -y iptables
    elif command -v pacman &>/dev/null; then
        pacman -Sy --noconfirm iptables
    elif command -v apk &>/dev/null; then
        apk add iptables
    else
        echo -e "${YELLOW}未检测到支持 iptables 持久化的包管理器，请手动确保规则持久化${NC}"
        echo -e "手动保存：iptables-save > /etc/iptables/rules.v4"
        echo -e "手动加载：iptables-restore < /etc/iptables/rules.v4"
    fi
}

# 检查 iptables 规则
check_iptables() {
    log "检查 iptables NAT 规则..."
    if ! iptables -t nat -L | grep -q "MASQUERADE"; then
        log "配置 iptables NAT 规则..."
        iptables -t nat -A POSTROUTING -s 192.168.0.0/16 -j MASQUERADE || {
            echo -e "${RED}配置 iptables NAT 规则失败${NC}"
            exit 1
        }
    fi
    if [[ $IPV6_ENABLED -eq 1 ]]; then
        log "检查 ip6tables NAT 规则..."
        if ! ip6tables -t nat -L | grep -q "MASQUERADE"; then
            log "配置 ip6tables NAT 规则..."
            ip6tables -t nat -A POSTROUTING -s fc00::/7 -j MASQUERADE || {
                echo -e "${RED}配置 ip6tables NAT 规则失败${NC}"
                exit 1
            }
        fi
    fi
    if [[ -n "${MACVLAN_IP:-}" ]]; then
        log "检查 Sing-box 入站规则..."
        if ! iptables -L INPUT | grep -q "$MACVLAN_IP"; then
            log "添加 Sing-box iptables 规则..."
            iptables -A INPUT -d "$MACVLAN_IP" -p tcp -m multiport --dports "${SINGBOX_PORTS[*]/ /,},$SINGBOX_UI_PORT" -j ACCEPT || {
                echo -e "${RED}添加 Sing-box iptables 规则失败${NC}"
                exit 1
            }
        fi
    fi
    if [[ -n "${MIHOMO_IP:-}" ]]; then
        log "检查 Mihomo 入站规则..."
        if ! iptables -L INPUT | grep -q "$MIHOMO_IP"; then
            log "添加 Mihomo iptables 规则..."
            iptables -A INPUT -d "$MIHOMO_IP" -p tcp -m multiport --dports "${MIHOMO_PORTS[*]/ /,}" -j ACCEPT || {
                echo -e "${RED}添加 Mihomo TCP iptables 规则失败${NC}"
                exit 1
            }
            iptables -A INPUT -d "$MIHOMO_IP" -p udp -m multiport --dports "${MIHOMO_PORTS[*]/ /,}" -j ACCEPT || {
                echo -e "${RED}添加 Mihomo UDP iptables 规则失败${NC}"
                exit 1
            }
        fi
    fi
    if [[ $IPV6_ENABLED -eq 1 ]]; then
        log "添加 Sing-box ip6tables 规则..."
        ip6tables -A INPUT -p tcp -m multiport --dports "${SINGBOX_PORTS[*]/ /,},$SINGBOX_UI_PORT" -j ACCEPT || true
        log "添加 Mihomo ip6tables 规则..."
        ip6tables -A INPUT -p tcp -m multiport --dports "${MIHOMO_PORTS[*]/ /,}" -j ACCEPT || true
        ip6tables -A INPUT -p udp -m multiport --dports "${MIHOMO_PORTS[*]/ /,}" -j ACCEPT || true
    fi
    save_iptables_rules
}

# 保存 iptables 规则
save_iptables_rules() {
    install_iptables_persistent
    mkdir -p /etc/iptables
    iptables-save | tee /etc/iptables/rules.v4 >/dev/null || {
        echo -e "${RED}保存 iptables 规则失败${NC}"
        exit 1
    }
    if [[ $IPV6_ENABLED -eq 1 ]]; then
        ip6tables-save | tee /etc/iptables/rules.v6 >/dev/null || {
            echo -e "${RED}保存 ip6tables 规则失败${NC}"
            exit 1
        }
    fi
    log "iptables 规则已保存到 /etc/iptables/rules.v4"
}

# 检查网络通畅性
check_network() {
    log "检查网络通畅性..."
    if ! ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1; then
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
    if [[ $IPV6_ENABLED -eq 1 ]]; then
        sysctl -w net.ipv6.conf.all.forwarding=1 || {
            echo -e "${RED}启用 IPv6 转发失败${NC}"
            exit 1
        }
        echo 'net.ipv6.conf.all.forwarding=1' | tee -a /etc/sysctl.conf >/dev/null
    fi
    log "网络转发已启用"
}

# 卸载清理
uninstall_docker() {
    local project=$1
    if [[ "$project" == "sing-box" ]]; then
        log "开始卸载 Docker sing-box..."
        docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
        docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
        if ! docker ps -a --format '{{.Names}}' | grep -q "$MIHOMO_CONTAINER_NAME"; then
            docker network rm "$MACVLAN_NET_NAME" >/dev/null 2>&1 || true
        fi
    elif [[ "$project" == "mihomo" ]]; then
        log "开始卸载 Docker mihomo..."
        docker stop "$MIHOMO_CONTAINER_NAME" >/dev/null 2>&1 || true
        docker rm "$MIHOMO_CONTAINER_NAME" >/dev/null 2>&1 || true
        if ! docker ps -a --format '{{.Names}}' | grep -q "$CONTAINER_NAME"; then
            docker network rm "$MACVLAN_NET_NAME" >/dev/null 2>&1 || true
        fi
    fi
    iptables -t nat -D POSTROUTING -s 192.168.0.0/16 -j MASQUERADE >/dev/null 2>&1 || true
    iptables -D INPUT -d "${MACVLAN_IP:-}" -p tcp -m multiport --dports "${SINGBOX_PORTS[*]/ /,},$SINGBOX_UI_PORT" -j ACCEPT >/dev/null 2>&1 || true
    iptables -D INPUT -d "${MIHOMO_IP:-}" -p tcp -m multiport --dports "${MIHOMO_PORTS[*]/ /,}" -j ACCEPT >/dev/null 2>&1 || true
    iptables -D INPUT -d "${MIHOMO_IP:-}" -p udp -m multiport --dports "${MIHOMO_PORTS[*]/ /,}" -j ACCEPT >/dev/null 2>&1 || true
    if [[ $IPV6_ENABLED -eq 1 ]]; then
        ip6tables -t nat -D POSTROUTING -s fc00::/7 -j MASQUERADE >/dev/null 2>&1 || true
        ip6tables -D INPUT -p tcp -m multiport --dports "${SINGBOX_PORTS[*]/ /,},$SINGBOX_UI_PORT" -j ACCEPT >/dev/null 2>&1 || true
        ip6tables -D INPUT -p tcp -m multiport --dports "${MIHOMO_PORTS[*]/ /,}" -j ACCEPT >/dev/null 2>&1 || true
        ip6tables -D INPUT -p udp -m multiport --dports "${MIHOMO_PORTS[*]/ /,}" -j ACCEPT >/dev/null 2>&1 || true
    fi
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
        echo -e "${RED}无法自动检测局域网信息，请手动配置网络参数${NC}"
        return 1
    fi
    local ip_cidr=$(ip addr show dev "$default_iface" | awk '/inet / {print $2}' | head -n 1)
    if [[ -z "$ip_cidr" ]]; then
        echo -e "${RED}无法获取接口 $default_iface 的 IP 信息，请手动配置网络参数${NC}"
        return 1
    fi
    if ! SUBNET=$(calculate_network_address "$ip_cidr"); then
        echo -e "${RED}计算子网失败，请手动配置网络参数${NC}"
        return 1
    fi
    GATEWAY=$(ip route show default | awk '/default/ {print $3}')
    if [[ -z "$SUBNET" || -z "$GATEWAY" ]]; then
        echo -e "${RED}自动检测局域网信息失败，请手动配置网络参数${NC}"
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

# 简单 JSON/YAML 格式检查
basic_config_check() {
    local file=$1
    local format=$2
    log "执行基本 $format 格式检查..."
    if [[ "$format" == "json" ]]; then
        if ! grep -q '^{.*}$' "$file" || grep -q '[^\\]{[^{]*[[:space:]]*,[[:space:]]*[^{]*}' "$file"; then
            echo -e "${RED}$file 可能不是有效的 JSON 文件${NC}"
            return 1
        fi
    elif [[ "$format" == "yaml" ]]; then
        if ! grep -q '^[a-zA-Z0-9_-]\+:' "$file"; then
            echo -e "${RED}$file 可能不是有效的 YAML 文件${NC}"
            return 1
        fi
    fi
    log "$file 基本 $format 格式检查通过"
    return 0
}

# 严格验证 Mihomo YAML 配置文件
validate_yaml_strictly() {
    local config_file=$1
    log "执行 Mihomo YAML 严格验证..."
    if command -v yq &>/dev/null; then
        local required_fields=("proxies" "proxy-groups" "rules")
        for field in "${required_fields[@]}"; do
            if ! yq e ".$field" "$config_file" >/dev/null 2>&1 || [ "$(yq e ".$field" "$config_file")" = "null" ]; then
                echo -e "${RED}Mihomo 配置文件缺少必要字段: $field${NC}"
                return 1
            fi
        done
        local mixed_port=$(yq e '.mixed-port' "$config_file" 2>/dev/null || echo "none")
        if [[ "$mixed_port" == "none" || ! "$mixed_port" =~ ^[0-9]+$ || $mixed_port -lt 1 || $mixed_port -gt 65535 ]]; then
            echo -e "${RED}Mihomo 配置文件中 mixed-port 无效或缺失${NC}"
            return 1
        fi
        log "Mihomo YAML 严格验证通过"
        return 0
    else
        echo -e "${YELLOW}未安装 yq，跳过 Mihomo 严格验证${NC}"
        return 0
    fi
}

# 检查配置文件目录和权限
check_config_dir() {
    local config_dir=$1
    local config_file=$2
    local format=$3
    log "检查配置文件目录和权限: $config_dir/$config_file"
    
    if [ ! -d "$config_dir" ]; then
        log "目录 $config_dir 不存在，创建目录..."
        mkdir -p "$config_dir" || {
            echo -e "${RED}无法创建目录 $config_dir，请检查权限${NC}"
            return 1
        }
    fi

    if [ ! -r "$config_dir/$config_file" ]; then
        echo -e "${RED}文件 $config_dir/$config_file 不存在或不可读${NC}"
        echo -e "${YELLOW}请确保文件存在并具有正确权限（例如：chmod 600 $config_dir/$config_file）${NC}"
        read -p "是否继续（忽略文件检查）？(y/N): " IGNORE_CHECK
        if [[ "$IGNORE_CHECK" =~ ^[Yy]$ ]]; then
            log "用户选择忽略文件检查，继续执行"
            return 0
        else
            return 1
        fi
    fi

    install_jq_yq

    if [[ "$format" == "json" ]]; then
        if command -v jq &>/dev/null; then
            if ! jq . "$config_dir/$config_file" >/dev/null 2>&1; then
                echo -e "${RED}$config_dir/$config_file 不是有效的 JSON 文件${NC}"
                echo -e "${YELLOW}错误详情：${NC}"
                jq . "$config_dir/$config_file" 2>&1 | sed 's/^/  /'
                echo -e "${YELLOW}请检查文件格式，常见问题包括：${NC}"
                echo -e "  - 缺少逗号或大括号"
                echo -e "  - 无效的键值对"
                echo -e "  - 编码问题（确保文件为 UTF-8）"
                read -p "是否尝试继续（忽略格式检查）？(y/N): " IGNORE_FORMAT
                if [[ "$IGNORE_FORMAT" =~ ^[Yy]$ ]]; then
                    log "用户选择忽略 JSON 格式检查，继续执行"
                else
                    return 1
                fi
            fi
        else
            basic_config_check "$config_dir/$config_file" "json" || return 1
        fi
    elif [[ "$format" == "yaml" ]]; then
        if command -v yq &>/dev/null; then
            if ! yq e . "$config_dir/$config_file" >/dev/null 2>&1; then
                echo -e "${RED}$config_dir/$config_file 不是有效的 YAML 文件${NC}"
                echo -e "${YELLOW}错误详情：${NC}"
                yq e . "$config_dir/$config_file" 2>&1 | sed 's/^/  /'
                echo -e "${YELLOW}请检查文件格式，常见问题包括：${NC}"
                echo -e "  - 缩进错误（应为2个空格）"
                echo -e "  - 无效的键值对或列表格式"
                echo -e "  - 特殊字符未正确转义"
                echo -e "  - 编码问题（确保文件为 UTF-8）"
                read -p "是否尝试继续（忽略格式检查）？(y/N): " IGNORE_FORMAT
                if [[ "$IGNORE_FORMAT" =~ ^[Yy]$ ]]; then
                    log "用户选择忽略 YAML 格式检查，继续执行"
                    return 0
                else
                    return 1
                fi
            fi
            validate_yaml_strictly "$config_dir/$config_file" || return 1
        else
            basic_config_check "$config_dir/$config_file" "yaml" || return 1
        fi
    fi

    chmod 600 "$config_dir/$config_file" || {
        echo -e "${RED}无法设置 $config_dir/$config_file 权限为600${NC}"
        return 1
    }
    chown root:root "$config_dir/$config_file" || {
        echo -e "${RED}无法设置 $config_dir/$config_file 所有者为 root${NC}"
        return 1
    }
    log "配置文件 $config_dir/$config_file 已验证，权限已设置为600"
    return 0
}

# 提取 Sing-box 配置文件中的端口
get_singbox_ports() {
    local config_file=$1
    SINGBOX_PORTS=()
    SINGBOX_UI_PORT="9090"  # 默认 UI 端口
    if command -v jq &>/dev/null; then
        # 提取 http、socks 或 mixed 类型的端口
        local ports
        ports=$(jq -r '.inbounds[] | select(.type == "http" or .type == "socks" or .type == "mixed") | .port' "$config_file" 2>/dev/null || true)
        if [[ -n "$ports" ]]; then
            while IFS= read -r port; do
                if [[ "$port" =~ ^[0-9]+$ && $port -ge 1 && $port -le 65535 ]]; then
                    SINGBOX_PORTS+=("$port")
                fi
            done <<< "$ports"
        fi
        # 提取 API 的 UI 端口
        local ui_port
        ui_port=$(jq -r '.inbounds[] | select(.type == "http" and .tag == "api") | .port' "$config_file" 2>/dev/null || echo "9090")
        if [[ "$ui_port" =~ ^[0-9]+$ && $ui_port -ge 1 && $ui_port -le 65535 ]]; then
            SINGBOX_UI_PORT="$ui_port"
        fi
    fi
    # 如果没有找到有效端口，使用默认值
    if [[ ${#SINGBOX_PORTS[@]} -eq 0 ]]; then
        echo -e "${YELLOW}未从 $config_file 中提取到有效端口，使用默认值：10808,10809${NC}"
        SINGBOX_PORTS=(10808 10809)
    fi
    log "Sing-box 端口：${SINGBOX_PORTS[*]}，管理界面端口：$SINGBOX_UI_PORT"
}

# 提取 Mihomo 配置文件中的端口
get_mihomo_ports() {
    local config_file=$1
    if command -v yq &>/dev/null; then
        MIHOMO_MIXED_PORT=$(yq e '.mixed-port' "$config_file" 2>/dev/null || echo "7893")
        MIHOMO_UI_PORT=$(yq e '.external-controller | split(":") | .[-1]' "$config_file" 2>/dev/null || echo "9090")
        MIHOMO_DNS_PORT=$(yq e '.dns.listen | split(":") | .[-1]' "$config_file" 2>/dev/null || echo "1053")
        MIHOMO_PORTS=("$MIHOMO_MIXED_PORT" "$MIHOMO_UI_PORT" "$MIHOMO_DNS_PORT")
    else
        echo -e "${YELLOW}未安装 yq，使用默认 Mihomo 端口：7893,9090,1053${NC}"
        MIHOMO_PORTS=(7893 9090 1053)
        MIHOMO_MIXED_PORT=7893
        MIHOMO_UI_PORT=9090
        MIHOMO_DNS_PORT=1053
    fi
    log "Mihomo 端口：${MIHOMO_PORTS[*]} (mixed-port: $MIHOMO_MIXED_PORT, UI: $MIHOMO_UI_PORT, DNS: $MIHOMO_DNS_PORT)"
}

# 检查 Docker 版本
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

# 备份配置文件
backup_config() {
    local config_dir=$1
    local config_file=$2
    local backup_dir="$config_dir/backup"
    local timestamp=$(date +'%Y%m%d_%H%M%S')
    if [[ -f "$config_dir/$config_file" ]]; then
        mkdir -p "$backup_dir"
        cp "$config_dir/$config_file" "$backup_dir/$config_file.$timestamp"
        log "已备份配置文件到 $backup_dir/$config_file.$timestamp"
    fi
}

# 创建 Macvlan 或桥接网络
create_macvlan_network() {
    local net_name=$1
    local subnet=$2
    local gateway=$3
    local parent=$4
    local ipv6_subnet=""
    local ipv6_gateway=""
    if [[ $IPV6_ENABLED -eq 1 ]]; then
        ipv6_subnet=$(ip -6 addr show dev "$parent" | awk '/inet6 .*global/ {print $2}' | head -n 1)
        if [[ -n "$ipv6_subnet" ]]; then
            ipv6_gateway=$(ip -6 route show default | awk '/default/ {print $3}')
            if ! validate_ipv6_config "$ipv6_subnet" "$ipv6_gateway"; then
                ipv6_subnet=""
                ipv6_gateway=""
            fi
        fi
    fi
    if [[ "$NETWORK_MODE" == "bridge" ]]; then
        log "创建桥接网络: $net_name"
        local create_cmd="docker network create -d bridge --subnet=$subnet --gateway=$gateway"
        if [[ -n "$ipv6_subnet" && -n "$ipv6_gateway" ]]; then
            create_cmd="$create_cmd --ipv6 --subnet=$ipv6_subnet --gateway=$ipv6_gateway"
        fi
        eval "$create_cmd $net_name" || {
            echo -e "${RED}创建桥接网络失败${NC}"
            exit 1
        }
    else
        enable_persistent_promisc "$parent"
        local create_cmd="docker network create -d macvlan --subnet=$subnet --gateway=$gateway -o parent=$parent"
        if [[ -n "$ipv6_subnet" && -n "$ipv6_gateway" ]]; then
            create_cmd="$create_cmd --ipv6 --subnet=$ipv6_subnet --gateway=$ipv6_gateway"
        fi
        log "创建 Macvlan 网络命令: $create_cmd $net_name"
        eval "$create_cmd $net_name" || {
            echo -e "${RED}创建 Macvlan 网络失败${NC}"
            exit 1
        }
    fi
}

# 检查容器状态
check_container_status() {
    local container_name=$1
    local ip=$2
    local ports=("${@:3}")
    log "检查容器 $container_name 状态..."
    if ! docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
        echo -e "${RED}容器 $container_name 未运行${NC}"
        return 1
    fi
    for port in "${ports[@]}"; do
        if ! nc -z -w 3 "$ip" "$port" >/dev/null 2>&1; then
            echo -e "${RED}容器 $container_name 的端口 $port 不可达${NC}"
            return 1
        fi
    done
    log "容器 $container_name 运行正常，端口 ${ports[*]} 可达"
    return 0
}

# 调试辅助函数
debug_docker_failure() {
    local container_name=$1
    local config_dir=$2
    local config_file=$3
    local image=$4
    echo -e "${RED}容器 $container_name 启动失败，执行以下步骤排查：${NC}"
    echo -e "1. 检查容器日志：${YELLOW}docker logs $container_name${NC}"
    echo -e "2. 验证配置文件：${YELLOW}cat $config_dir/$config_file${NC}"
    echo -e "3. 检查配置文件格式：${YELLOW}docker run --rm -v $config_dir:/etc/$container_name $image check -c /etc/$container_name/$config_file${NC}"
    echo -e "4. 检查网络配置：${YELLOW}docker network inspect $MACVLAN_NET_NAME${NC}"
    echo -e "5. 检查端口占用：${YELLOW}ss -tuln | grep -E '10808|10809|7893|9090|1053'${NC}"
    echo -e "6. 检查文件系统：${YELLOW}df -h${NC}"
    echo -e "7. 检查权限：${YELLOW}ls -ld $config_dir${NC}"
}

# 下载配置文件（带超时和重试）
download_config() {
    local url=$1
    local output=$2
    local retries=3
    local timeout=10
    local attempt=1
    while [[ $attempt -le $retries ]]; do
        log "尝试下载配置文件（第 $attempt 次）..."
        if curl -sSL --connect-timeout $timeout --max-time $timeout "$url" -o "$output"; then
            log "配置文件下载成功: $output"
            return 0
        fi
        echo -e "${YELLOW}下载失败，重试中...${NC}"
        sleep 2
        ((attempt++))
    done
    echo -e "${RED}配置文件下载失败，已尝试 $retries 次${NC}"
    return 1
}

# 上传本地配置文件
upload_config() {
    local local_file=$1
    local config_dir=$2
    local config_file=$3
    log "上传本地配置文件: $local_file 到 $config_dir/$config_file"
    if [[ ! -f "$local_file" ]]; then
        echo -e "${RED}本地文件 $local_file 不存在${NC}"
        return 1
    fi
    cp "$local_file" "$config_dir/$config_file" || {
        echo -e "${RED}无法复制 $local_file 到 $config_dir/$config_file${NC}"
        return 1
    }
    chmod 600 "$config_dir/$config_file"
    chown root:root "$config_dir/$config_file"
    log "本地配置文件已上传到 $config_dir/$config_file"
    return 0
}

# 部署 Sing-box
install_singbox() {
    check_root
    trap 'echo -e "${RED}安装中断，正在清理...${NC}"; cleanup; exit 1' INT
    SINGBOX_CONFIG_DIR="${SINGBOX_CONFIG_DIR:-/etc/sing-box}"
    SINGBOX_PORTS=("${SINGBOX_PORTS[@]:-}")
    check_ipv6_support
    check_system_requirements

    ARCH=$(get_arch)
    log "检测到系统架构: ${ARCH}"

    read -p "请输入 Sing-box 容器名称(默认: docker-sing-box): " CONTAINER_NAME
    CONTAINER_NAME=${CONTAINER_NAME:-docker-sing-box}
    log "Sing-box 容器名称: ${YELLOW}$CONTAINER_NAME${NC}"

    read -p "请输入 Sing-box 镜像版本(例如: 1.12.0 或 latest, 默认: latest): " VERSION
    VERSION=${VERSION:-latest}
    validate_version "$VERSION"
    log "Sing-box 镜像版本: ${YELLOW}$VERSION${NC}"

    install_docker_deps
    if ! check_docker_version; then
        echo -e "${RED}Docker 版本不符合要求，请升级 Docker 后重试${NC}"
        exit 1
    fi

    read -p "请输入 Sing-box 配置文件存储路径(默认: /etc/sing-box): " CONFIG_DIR
    CONFIG_DIR=${CONFIG_DIR:-/etc/sing-box}
    mkdir -p "$CONFIG_DIR"
    backup_config "$CONFIG_DIR" "config.json"

    echo "请选择 Sing-box 配置文件来源："
    echo "1. 从 URL 下载"
    echo "2. 使用本地文件"
    read -p "请输入选项(1-2): " CONFIG_SOURCE
    DEFAULT_CONFIG_PATH="$CONFIG_DIR/config.json"
    if [[ "$CONFIG_SOURCE" == "2" ]]; then
        if [[ -f "$DEFAULT_CONFIG_PATH" ]]; then
            log "检测到配置文件：$DEFAULT_CONFIG_PATH，自动使用"
            LOCAL_CONFIG_PATH="$DEFAULT_CONFIG_PATH"
        else
            log "未检测到默认配置文件：$DEFAULT_CONFIG_PATH"
            read -p "请输入本地配置文件路径(例如: /tmp/user_config.json): " LOCAL_CONFIG_PATH
            if [[ -z "$LOCAL_CONFIG_PATH" || ! -f "$LOCAL_CONFIG_PATH" ]]; then
                echo -e "${RED}无效的配置文件路径或文件不存在${NC}"
                cleanup
                exit 1
            fi
            # 仅当本地文件路径与默认路径不同时，执行上传
            if [[ "$LOCAL_CONFIG_PATH" != "$DEFAULT_CONFIG_PATH" ]]; then
                if ! upload_config "$LOCAL_CONFIG_PATH" "$CONFIG_DIR" "config.json"; then
                    echo -e "${RED}Sing-box 配置文件上传失败${NC}"
                    cleanup
                    exit 1
                fi
            fi
        fi
    else
        read -p "请输入 Sing-box 配置文件订阅 URL: " CONFIG_URL
        validate_url "$CONFIG_URL"
        validate_url_security "$CONFIG_URL" || exit 1
        if ! download_config "$CONFIG_URL" "$CONFIG_DIR/config.json"; then
            echo -e "${RED}Sing-box 配置文件下载失败${NC}"
            cleanup
            exit 1
        fi
    fi
    if ! check_config_dir "$CONFIG_DIR" "config.json" "json"; then
        echo -e "${RED}Sing-box 配置文件目录或权限不正确，请检查后重试${NC}"
        cleanup
        exit 1
    fi
    get_singbox_ports "$CONFIG_DIR/config.json"

    MACVLAN_NET_NAME="${SHARED_MACVLAN_NET_NAME:-macvlan-net}"
    log "Sing-box 将使用网络: ${YELLOW}$MACVLAN_NET_NAME${NC}"

    if ! docker network inspect "$MACVLAN_NET_NAME" >/dev/null 2>&1; then
        log "网络 $MACVLAN_NET_NAME 不存在，正在创建..."
        if ! detect_lan_subnet_gateway; then
            echo -e "${RED}自动检测局域网信息失败，请手动配置网络参数${NC}"
            read -p "请输入局域网段(例如: 192.168.3.0/24): " SUBNET
            read -p "请输入网关地址(例如: 192.168.3.1): " GATEWAY
            read -p "请输入父接口(例如: eth0): " PARENT_INTERFACE
        else
            SUBNET="$DETECTED_SUBNET"
            GATEWAY="$DETECTED_GATEWAY"
            PARENT_INTERFACE="$DETECTED_INTERFACE"
        fi

        if ! check_network_conflict "$SUBNET"; then
            echo -e "${YELLOW}建议：运行 'docker network ls' 查看现有网络，删除冲突网络后重试${NC}"
            read -p "是否尝试自动删除同名网络 $MACVLAN_NET_NAME？(y/N): " DELETE_NET
            if [[ "$DELETE_NET" =~ ^[Yy]$ ]]; then
                docker network rm "$MACVLAN_NET_NAME" >/dev/null 2>&1 || true
            else
                exit 1
            fi
        fi

        check_promisc_support "$PARENT_INTERFACE"
        create_macvlan_network "$MACVLAN_NET_NAME" "$SUBNET" "$GATEWAY" "$PARENT_INTERFACE"
        export SHARED_MACVLAN_NET_NAME="$MACVLAN_NET_NAME"
        export SHARED_SUBNET="$SUBNET"
        export SHARED_GATEWAY="$GATEWAY"
        export SHARED_PARENT_INTERFACE="$PARENT_INTERFACE"
    else
        log "网络 $MACVLAN_NET_NAME 已存在，将复用"
        SUBNET=$(docker network inspect "$MACVLAN_NET_NAME" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}')
        GATEWAY=$(docker network inspect "$MACVLAN_NET_NAME" --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}')
        PARENT_INTERFACE=$(docker network inspect "$MACVLAN_NET_NAME" --format '{{.Options.parent}}')
        check_promisc_support "$PARENT_INTERFACE"
        export SHARED_SUBNET="$SUBNET"
        export SHARED_GATEWAY="$GATEWAY"
        export SHARED_PARENT_INTERFACE="$PARENT_INTERFACE"
    fi

    read -p "请输入 Sing-box 容器静态 IP 地址(例如: 192.168.3.2，确保在 ${SUBNET} 网段内且未被占用): " MACVLAN_IP
    MACVLAN_IP=${MACVLAN_IP:-192.168.3.2}
    if ! validate_ip_in_subnet "$MACVLAN_IP" "$SUBNET"; then
        exit 1
    fi
    if ! check_ip_occupied "$MACVLAN_IP"; then
        exit 1
    fi

    # 仅检查有效端口
    for port in "${SINGBOX_PORTS[@]}" "$SINGBOX_UI_PORT"; do
        if [[ -n "$port" && "$port" =~ ^[0-9]+$ && $port -ge 1 && $port -le 65535 ]]; then
            if ! check_port_usage "$port"; then
                exit 1
            fi
        else
            log "跳过无效端口: $port"
        fi
    done

    clean_old_container "$CONTAINER_NAME"

    DOWNLOAD_URL="ghcr.io/sagernet/sing-box:$VERSION"
    log "Sing-box Docker 镜像: ${YELLOW}$DOWNLOAD_URL${NC}"

    DOCKER_RUN_CMD="docker run -d --name \"$CONTAINER_NAME\" --restart always --memory=128m --cpus=0.5 --network \"$MACVLAN_NET_NAME\" --ip \"$MACVLAN_IP\" --cap-add=NET_ADMIN --cap-add=NET_RAW --device=/dev/net/tun:/dev/net/tun -v \"$CONFIG_DIR\":/etc/sing-box $DOWNLOAD_URL run -c /etc/sing-box/config.json"

    log "执行 Sing-box Docker 命令: ${YELLOW}${DOCKER_RUN_CMD}${NC}"
    if ! eval "$DOCKER_RUN_CMD"; then
        debug_docker_failure "$CONTAINER_NAME" "$CONFIG_DIR" "config.json" "$DOWNLOAD_URL"
        cleanup
        exit 1
    fi

    GATEWAY_IP=$(get_gateway_ip)
    log "配置网关地址: ${GATEWAY_IP}"
    enable_ip_forwarding
    check_default_route
    check_iptables
    check_network

    check_container_status "$CONTAINER_NAME" "$MACVLAN_IP" "${SINGBOX_PORTS[@]}" "$SINGBOX_UI_PORT"

    echo -e "${GREEN}Sing-box Docker 安装完成！${NC}"
    echo -e "请将客户端网关设置为: ${MACVLAN_IP}"
    echo -e "代理端口：${SINGBOX_PORTS[*]}"
    echo -e "管理界面: ${MACVLAN_IP}:$SINGBOX_UI_PORT"
    echo -e "容器状态检查: ${YELLOW}docker ps -a${NC}"
    echo -e "容器日志查看: ${YELLOW}docker logs $CONTAINER_NAME${NC}"
    echo -e "实时监控: ${YELLOW}watch -n 5 'docker ps -a | grep $CONTAINER_NAME && nc -z $MACVLAN_IP ${SINGBOX_PORTS[0]}'${NC}"
}

# 部署 Mihomo
install_mihomo() {
    check_root
    trap 'echo -e "${RED}安装中断，正在清理...${NC}"; cleanup; exit 1' INT
    MIHOMO_CONFIG_DIR="${MIHOMO_CONFIG_DIR:-/etc/mihomo}"
    CONTAINER_NAME="${CONTAINER_NAME:-docker-mihomo}"
    MACVLAN_NET_NAME="${MACVLAN_NET_NAME:-macvlan-net}"
    SHARED_MACVLAN_NET_NAME="${SHARED_MACVLAN_NET_NAME:-macvlan-net}"
    check_ipv6_support
    check_system_requirements

    ARCH=$(get_arch)
    log "检测到系统架构: ${ARCH}"

    read -p "请输入 Mihomo 容器名称(默认: docker-mihomo): " MIHOMO_CONTAINER_NAME
    MIHOMO_CONTAINER_NAME=${MIHOMO_CONTAINER_NAME:-docker-mihomo}
    log "Mihomo 容器名称: ${YELLOW}$MIHOMO_CONTAINER_NAME${NC}"

    read -p "请输入 Mihomo 镜像版本(例如: 1.18.7 或 latest, 默认: latest): " MIHOMO_VERSION
    MIHOMO_VERSION=${MIHOMO_VERSION:-latest}
    validate_version "$MIHOMO_VERSION"
    log "Mihomo 镜像版本: ${YELLOW}$MIHOMO_VERSION${NC}"

    install_docker_deps
    if ! check_docker_version; then
        echo -e "${RED}Docker 版本不符合要求，请升级 Docker 后重试${NC}"
        exit 1
    fi

    echo "请选择 Mihomo 配置文件来源："
    echo "1. 从 URL 下载"
    echo "2. 使用本地文件"
    read -p "请输入选项(1-2): " CONFIG_SOURCE
    read -p "请输入 Mihomo 配置文件存储路径(默认: /etc/mihomo): " MIHOMO_CONFIG_DIR
    MIHOMO_CONFIG_DIR=${MIHOMO_CONFIG_DIR:-/etc/mihomo}
    mkdir -p "$MIHOMO_CONFIG_DIR"
    backup_config "$MIHOMO_CONFIG_DIR" "config.yaml"
    if [[ "$CONFIG_SOURCE" == "1" ]]; then
        read -p "请输入 Mihomo 配置文件订阅 URL: " MIHOMO_CONFIG_URL
        validate_url "$MIHOMO_CONFIG_URL"
        validate_url_security "$MIHOMO_CONFIG_URL" || exit 1
        if ! download_config "$MIHOMO_CONFIG_URL" "$MIHOMO_CONFIG_DIR/config.yaml"; then
            echo -e "${RED}Mihomo 配置文件下载失败${NC}"
            cleanup
            exit 1
        fi
    else
# 预设路径
DEFAULT_PATH="/etc/mihomo/config.yaml"

# 检查文件是否存在
if [ -f "$DEFAULT_PATH" ]; then
    echo "检测到配置文件：$DEFAULT_PATH，自动使用"
    TARGET_PATH="$DEFAULT_PATH"
else
    echo "未检测到配置文件：$DEFAULT_PATH"
    read -p "请确认配置文件路径（或输入新路径，回车使用默认）： " USER_PATH
    if [ -z "$USER_PATH" ]; then
        echo "未检测到配置文件，操作终止"
        exit 1
    elif [ -f "$USER_PATH" ]; then
        TARGET_PATH="$USER_PATH"
    else
        echo "路径无效或文件不存在：$USER_PATH"
        exit 1
    fi
fi

# 只在目标路径不同于目标路径时，才复制
if [ "$TARGET_PATH" != "$MIHOMO_CONFIG_DIR/config.yaml" ]; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] 复制配置文件到 $MIHOMO_CONFIG_DIR/config.yaml"
    cp "$TARGET_PATH" "$MIHOMO_CONFIG_DIR/config.yaml" || {
        echo "复制文件失败"
        exit 1
    }
else
    echo "配置文件已存在，无需复制"
fi
    fi
    if ! check_config_dir "$MIHOMO_CONFIG_DIR" "config.yaml" "yaml"; then
        echo -e "${RED}Mihomo 配置文件目录或权限不正确，请检查后重试${NC}"
        cleanup
        exit 1
    fi
    get_mihomo_ports "$MIHOMO_CONFIG_DIR/config.yaml"

    MACVLAN_NET_NAME="${SHARED_MACVLAN_NET_NAME:-macvlan-net}"
    log "Mihomo 将使用网络: ${YELLOW}$MACVLAN_NET_NAME${NC}"

    if ! docker network inspect "$MACVLAN_NET_NAME" >/dev/null 2>&1; then
        log "网络 $MACVLAN_NET_NAME 不存在，正在创建..."
        if ! detect_lan_subnet_gateway; then
            echo -e "${RED}自动检测局域网信息失败，请手动配置网络参数${NC}"
            read -p "请输入局域网段(例如: 192.168.3.0/24): " MIHOMO_SUBNET
            read -p "请输入网关地址(例如: 192.168.3.18): " MIHOMO_GATEWAY
            read -p "请输入父接口(例如: enx000a4300999a): " MIHOMO_PARENT_INTERFACE
        else
            MIHOMO_SUBNET="$DETECTED_SUBNET"
            MIHOMO_GATEWAY="$DETECTED_GATEWAY"
            MIHOMO_PARENT_INTERFACE="$DETECTED_INTERFACE"
        fi

        if ! check_network_conflict "$MIHOMO_SUBNET"; then
            echo -e "${YELLOW}建议：运行 'docker network ls' 查看现有网络，删除冲突网络后重试${NC}"
            read -p "是否尝试自动删除同名网络 $MACVLAN_NET_NAME？(y/N): " DELETE_NET
            if [[ "$DELETE_NET" =~ ^[Yy]$ ]]; then
                docker network rm "$MACVLAN_NET_NAME" >/dev/null 2>&1 || true
            else
                exit 1
            fi
        fi

        check_promisc_support "$MIHOMO_PARENT_INTERFACE"
        create_macvlan_network "$MACVLAN_NET_NAME" "$MIHOMO_SUBNET" "$MIHOMO_GATEWAY" "$MIHOMO_PARENT_INTERFACE"
        export SHARED_MACVLAN_NET_NAME="$MACVLAN_NET_NAME"
        export SHARED_SUBNET="$MIHOMO_SUBNET"
        export SHARED_GATEWAY="$MIHOMO_GATEWAY"
        export SHARED_PARENT_INTERFACE="$MIHOMO_PARENT_INTERFACE"
    else
        log "网络 $MACVLAN_NET_NAME 已存在，将复用"
        MIHOMO_SUBNET=$(docker network inspect "$MACVLAN_NET_NAME" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}')
        MIHOMO_GATEWAY=$(docker network inspect "$MACVLAN_NET_NAME" --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}')
        MIHOMO_PARENT_INTERFACE=$(docker network inspect "$MACVLAN_NET_NAME" --format '{{.Options.parent}}')
        check_promisc_support "$MIHOMO_PARENT_INTERFACE"
        export SHARED_SUBNET="$MIHOMO_SUBNET"
        export SHARED_GATEWAY="$MIHOMO_GATEWAY"
        export SHARED_PARENT_INTERFACE="$MIHOMO_PARENT_INTERFACE"
    fi

    read -p "请输入 Mihomo 容器静态 IP 地址(例如: 192.168.3.182，确保在 ${MIHOMO_SUBNET} 网段内且未被占用): " MIHOMO_IP
    MIHOMO_IP=${MIHOMO_IP:-192.168.3.182}
    if ! validate_ip_in_subnet "$MIHOMO_IP" "$MIHOMO_SUBNET"; then
        exit 1
    fi
    if ! check_ip_occupied "$MIHOMO_IP"; then
        exit 1
    fi

    for port in "${MIHOMO_PORTS[@]}"; do
        if ! check_port_usage "$port"; then
            exit 1
        fi
    done

    clean_old_container "$MIHOMO_CONTAINER_NAME"

    MIHOMO_DOWNLOAD_URL="metacubex/mihomo:$MIHOMO_VERSION"
    log "Mihomo Docker 镜像: ${YELLOW}$MIHOMO_DOWNLOAD_URL${NC}"

    MIHOMO_DOCKER_RUN_CMD="docker run -d --name \"$MIHOMO_CONTAINER_NAME\" --restart always --memory=256m --cpus=1.0 --network \"$MACVLAN_NET_NAME\" --ip \"$MIHOMO_IP\" --cap-add=NET_ADMIN --cap-add=NET_RAW -v \"$MIHOMO_CONFIG_DIR\":/root/.config/mihomo -v \"$MIHOMO_CONFIG_DIR/run\":/etc/mihomo/run --device=/dev/net/tun:/dev/net/tun $MIHOMO_DOWNLOAD_URL"

    log "执行 Mihomo Docker 命令: ${YELLOW}${MIHOMO_DOCKER_RUN_CMD}${NC}"
    if ! eval "$MIHOMO_DOCKER_RUN_CMD"; then
        debug_docker_failure "$MIHOMO_CONTAINER_NAME" "$MIHOMO_CONFIG_DIR" "config.yaml" "$MIHOMO_DOWNLOAD_URL"
        cleanup
        exit 1
    fi

    GATEWAY_IP=$(get_gateway_ip)
    log "配置网关地址: ${GATEWAY_IP}"
    enable_ip_forwarding
    check_default_route
    check_iptables
    check_network

    check_container_status "$MIHOMO_CONTAINER_NAME" "$MIHOMO_IP" "${MIHOMO_PORTS[@]}"

    echo -e "${GREEN}Mihomo Docker 安装完成！${NC}"
    echo -e "请将客户端网关设置为: ${MIHOMO_IP}"
    echo -e "代理端口："
    echo -e "  - HTTP/SOCKS: ${MIHOMO_IP}:$MIHOMO_MIXED_PORT (mixed-port)"
    echo -e "  - 管理界面: ${MIHOMO_IP}:$MIHOMO_UI_PORT"
    echo -e "  - DNS: ${MIHOMO_IP}:$MIHOMO_DNS_PORT"
    echo -e "容器状态检查: ${YELLOW}docker ps -a${NC}"
    echo -e "容器日志查看: ${YELLOW}docker logs $MIHOMO_CONTAINER_NAME${NC}"
    echo -e "实时监控: ${YELLOW}watch -n 5 'docker ps -a | grep $MIHOMO_CONTAINER_NAME && nc -z $MIHOMO_IP $MIHOMO_MIXED_PORT'${NC}"
}

# 查看当前配置
view_config() {
    echo -e "${GREEN}当前配置：${NC}"
    echo -e "Sing-box 容器名称: ${CONTAINER_NAME:-未设置}"
    echo -e "Sing-box IP: ${MACVLAN_IP:-未设置}"
    echo -e "Sing-box 配置文件: ${CONFIG_DIR:-未设置}/config.json"
    echo -e "Mihomo 容器名称: ${MIHOMO_CONTAINER_NAME:-未设置}"
    echo -e "Mihomo IP: ${MIHOMO_IP:-未设置}"
    echo -e "Mihomo 配置文件: ${MIHOMO_CONFIG_DIR:-未设置}/config.yaml"
    echo -e "Macvlan 网络: ${SHARED_MACVLAN_NET_NAME:-未设置}"
    echo -e "子网: ${SHARED_SUBNET:-未设置}"
    echo -e "网关: ${SHARED_GATEWAY:-未设置}"
    echo -e "父接口: ${SHARED_PARENT_INTERFACE:-未设置}"
}

# 更新配置文件
update_config() {
    local project=$1
    if [[ "$project" == "sing-box" ]]; then
        CONFIG_DIR="${CONFIG_DIR:-/etc/sing-box}"
        read -p "请输入新的 Sing-box 订阅 URL: " CONFIG_URL
        validate_url "$CONFIG_URL"
        validate_url_security "$CONFIG_URL" || exit 1
        backup_config "$CONFIG_DIR" "config.json"
        if ! download_config "$CONFIG_URL" "$CONFIG_DIR/config.json"; then
            echo -e "${RED}Sing-box 配置文件更新失败${NC}"
            exit 1
        fi
        check_config_dir "$CONFIG_DIR" "config.json" "json" || exit 1
        docker restart "$CONTAINER_NAME" || {
            echo -e "${RED}重启 Sing-box 容器失败${NC}"
            exit 1
        }
        log "Sing-box 配置文件已更新并重启容器"
    elif [[ "$project" == "mihomo" ]]; then
        echo "请选择新的 Mihomo 配置文件来源："
        echo "1. 从 URL 下载"
        echo "2. 使用本地文件"
        read -p "请输入选项(1-2): " CONFIG_SOURCE
        if [[ "$CONFIG_SOURCE" == "1" ]]; then
            read -p "请输入新的 Mihomo 订阅 URL: " MIHOMO_CONFIG_URL
            validate_url "$MIHOMO_CONFIG_URL"
            validate_url_security "$MIHOMO_CONFIG_URL" || exit 1
            backup_config "$MIHOMO_CONFIG_DIR" "config.yaml"
            if ! download_config "$MIHOMO_CONFIG_URL" "$MIHOMO_CONFIG_DIR/config.yaml"; then
                echo -e "${RED}Mihomo 配置文件更新失败${NC}"
                exit 1
            fi
        else
            read -p "请输入本地配置文件路径(例如: /tmp/user_config.yaml): " LOCAL_CONFIG_PATH
            if ! upload_config "$LOCAL_CONFIG_PATH" "$MIHOMO_CONFIG_DIR" "config.yaml"; then
                echo -e "${RED}Mihomo 配置文件上传失败${NC}"
                exit 1
            fi
        fi
        check_config_dir "$MIHOMO_CONFIG_DIR" "config.yaml" "yaml" || exit 1
        docker restart "$MIHOMO_CONTAINER_NAME" || {
            echo -e "${RED}重启 Mihomo 容器失败${NC}"
            exit 1
        }
        log "Mihomo 配置文件已更新并重启容器"
    fi
}

# 主菜单
main_menu() {
    echo -e "${GREEN}$SCRIPT_NAME (版本: $SCRIPT_VERSION)${NC}"
    echo -e "用于在 Docker 中部署 Sing-box 和 Mihomo 代理服务"
    echo -e "----------------------------------------"
    while true; do
        echo -e "${GREEN}请选择操作：${NC}"
        echo "1. 安装 Docker Sing-box"
        echo "2. 安装 Docker Mihomo"
        echo "3. 卸载 Docker Sing-box"
        echo "4. 卸载 Docker Mihomo"
        echo "5. 查看当前配置"
        echo "6. 更新 Sing-box 配置文件"
        echo "7. 更新 Mihomo 配置文件"
        echo "8. 退出"
        read -p "请输入选项(1-8): " choice
        case $choice in
            1) install_singbox ;;
            2) install_mihomo ;;
            3)
                read -p "请输入 Sing-box 容器名称(默认: docker-sing-box): " CONTAINER_NAME
                CONTAINER_NAME=${CONTAINER_NAME:-docker-sing-box}
                read -p "请输入 Macvlan 网络名称(默认: macvlan-net): " MACVLAN_NET_NAME
                MACVLAN_NET_NAME=${MACVLAN_NET_NAME:-macvlan-net}
                uninstall_docker "sing-box"
                ;;
            4)
                read -p "请输入 Mihomo 容器名称(默认: docker-mihomo): " MIHOMO_CONTAINER_NAME
                MIHOMO_CONTAINER_NAME=${MIHOMO_CONTAINER_NAME:-docker-mihomo}
                read -p "请输入 Macvlan 网络名称(默认: macvlan-net): " MACVLAN_NET_NAME
                MACVLAN_NET_NAME=${MACVLAN_NET_NAME:-macvlan-net}
                uninstall_docker "mihomo"
                ;;
            5) view_config ;;
            6) update_config "sing-box" ;;
            7) update_config "mihomo" ;;
            8)
                echo -e "${GREEN}退出脚本${NC}"
                exit 0
                ;;
            *) echo -e "${RED}无效选项，请选择 1-8${NC}" ;;
        esac
        echo -e "\n${YELLOW}操作完成，按 Enter 返回主菜单...${NC}"
        read -r
    done
}

# 主入口
main_menu
