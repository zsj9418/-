#!/bin/bash
set -euo pipefail

# 定义颜色输出
red() { echo -e "\033[31m$@\033[0m"; }
green() { echo -e "\033[32m$@\033[0m"; }
yellow() { echo -e "\033[33m$@\033[0m"; }

# 默认 DNS 设置
DNS_CHINA_DEFAULT="223.5.5.5"
DNS_GLOBAL_DEFAULT="8.8.8.8"

# 初始化日志
LOG_FILE="/var/log/set_dns.log"
init_log() {
    if [[ ! -w "$(dirname "$LOG_FILE")" ]]; then
        LOG_FILE="/tmp/set_dns.log"
    fi
    touch "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
    yellow "日志文件: $LOG_FILE"
}

# 获取系统和架构类型
get_system_and_arch() {
    local os=""
    local arch=""
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        case "$ID" in
            ubuntu|debian) os="ubuntu/debian" ;;
            centos|rhel|fedora) os="centos" ;;
            arch) os="arch" ;;
            alpine) os="alpine" ;;
            *) os="unsupported" ;;
        esac
    fi

    case "$(uname -m)" in
        x86_64|amd64) arch="amd64" ;;
        aarch64) arch="arm64" ;;
        armv7l|armhf) arch="armv7" ;;
        *) arch="unsupported" ;;
    esac

    echo "$os $arch"
}

# 验证 DNS 地址是否合法
validate_ip() {
    local ip="$1"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 0
    else
        return 1
    fi
}

# 设置 DNS 解析地址
set_dns() {
    local dns_china=${1:-$DNS_CHINA_DEFAULT}
    local dns_global=${2:-$DNS_GLOBAL_DEFAULT}

    # 验证输入的 DNS 地址
    if ! validate_ip "$dns_china" || ! validate_ip "$dns_global"; then
        red "错误: 无效的 DNS 地址，请输入合法的 IPv4 地址！"
        exit 1
    fi

    yellow "正在设置 DNS 解析地址..."
    local system_arch
    system_arch=$(get_system_and_arch)
    local os_type=$(echo "$system_arch" | awk '{print $1}')
    local arch_type=$(echo "$system_arch" | awk '{print $2}')

    case "$os_type" in
        "ubuntu/debian"|"arch")
            # 使用 resolvconf 设置 DNS
            if [[ -f /etc/resolv.conf ]]; then
                cp /etc/resolv.conf /etc/resolv.conf.bak
            fi
            echo "nameserver $dns_china" | sudo tee /etc/resolv.conf > /dev/null
            echo "nameserver $dns_global" | sudo tee -a /etc/resolv.conf > /dev/null
            ;;
        "centos")
            # 使用 NetworkManager 设置 DNS
            local connection_name=$(nmcli -t -f NAME connection show --active | head -n 1)
            if [[ -z "$connection_name" ]]; then
                red "未找到活动的网络连接！"
                exit 1
            fi
            nmcli connection modify "$connection_name" ipv4.dns "$dns_china,$dns_global"
            nmcli connection reload "$connection_name"
            nmcli connection up "$connection_name"
            ;;
        "alpine")
            # Alpine Linux DNS 设置
            echo "nameserver $dns_china" | sudo tee /etc/resolv.conf > /dev/null
            echo "nameserver $dns_global" | sudo tee -a /etc/resolv.conf > /dev/null
            ;;
        *)
            red "不支持的系统类型: $os_type"
            exit 1
            ;;
    esac

    green "DNS 解析地址已设置为："
    echo "国内 DNS: $dns_china"
    echo "国外 DNS: $dns_global"
}

# 测试网络连通性
test_network() {
    yellow "正在测试网络连通性..."
    local test_urls=("https://www.baidu.com" "https://www.google.com")
    for url in "${test_urls[@]}"; do
        if curl --max-time 5 --output /dev/null --silent --head --fail "$url"; then
            green "访问 $url 成功！"
        else
            red "访问 $url 失败！"
        fi
    done
}

# 安装依赖
install_dependencies() {
    yellow "正在检查并安装依赖..."
    local system_arch
    system_arch=$(get_system_and_arch)
    local os_type=$(echo "$system_arch" | awk '{print $1}')

    case "$os_type" in
        "ubuntu/debian")
            if ! command -v resolvconf &>/dev/null; then
                yellow "安装 resolvconf..."
                sudo apt update && sudo apt install -y resolvconf
            fi
            ;;
        "centos")
            if ! command -v nmcli &>/dev/null; then
                yellow "安装 NetworkManager..."
                sudo yum install -y NetworkManager
            fi
            ;;
        "arch")
            if ! command -v resolvconf &>/dev/null; then
                yellow "安装 resolvconf..."
                sudo pacman -S --noconfirm resolvconf
            fi
            ;;
        "alpine")
            yellow "Alpine 系统无需额外安装依赖。"
            ;;
        *)
            red "当前系统不支持自动安装，请手动安装必要依赖。"
            exit 1
            ;;
    esac
    green "依赖检查完成！"
}

# 主流程
main() {
    init_log
    yellow "欢迎使用一键设置 DNS 解析地址脚本！"

    # 检查并安装依赖
    install_dependencies

    # 设置默认 DNS
    set_dns "$DNS_CHINA_DEFAULT" "$DNS_GLOBAL_DEFAULT"

    # 测试网络连通性
    test_network

    # 交互式设置 DNS
    read -p "请输入国内 DNS 地址（默认: $DNS_CHINA_DEFAULT）：" dns_china
    read -p "请输入国外 DNS 地址（默认: $DNS_GLOBAL_DEFAULT）：" dns_global

    # 设置用户指定的 DNS
    set_dns "$dns_china" "$dns_global"

    # 再次测试网络连通性
    read -p "是否测试网络连通性？(y/n, 默认: y)：" test_network_choice
    if [[ "$test_network_choice" != "n" ]]; then
        test_network
    fi

    green "DNS 设置和网络测试完成！"
}

main "$@"
