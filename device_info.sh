#!/bin/sh

### 配置常量 ###
LOG_FILE="/var/log/device_info.log"  # 日志文件路径
WEBHOOK_URL=""                      # 企业微信机器人 Webhook URL
DEPENDENCIES="curl"                 # 必需依赖
CONFIG_FILE="/etc/device_info.conf" # 配置文件路径
MAX_LOG_LINES=1000                  # 限制日志文件最大行数
SCRIPT_PATH="$(realpath "$0")"      # 当前脚本路径
PING_TARGET="223.5.5.5"             # 网络检测目标

### 彩色输出函数 ###
red() { echo "\033[31m$*\033[0m"; }
yellow() { echo "\033[33m$*\033[0m"; }
green() { echo "\033[32m$*\033[0m"; }

### 检查依赖并补全（仅首次安装时运行） ###
check_dependencies() {
    echo "正在检查依赖..."
    local missing_deps=""
    for dep in $DEPENDENCIES; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing_deps="$missing_deps $dep"
        fi
    done

    if [ -n "$missing_deps" ]; then
        echo "缺少以下依赖：$missing_deps"
        echo "正在安装依赖..."
        if command -v apt >/dev/null 2>&1; then
            sudo apt update && sudo apt install -y $missing_deps
        elif command -v yum >/dev/null 2>&1; then
            sudo yum install -y $missing_deps
        elif command -v apk >/dev/null 2>&1; then
            sudo apk add --no-cache $missing_deps
        elif command -v opkg >/dev/null 2>&1; then
            sudo opkg update && sudo opkg install $missing_deps
        else
            echo "无法自动安装依赖，请手动安装以下工具：$missing_deps"
            exit 1
        fi
    else
        green "所有依赖已满足。"
    fi
}

### 保存用户配置 ###
save_config() {
    echo "WEBHOOK_URL=\"$WEBHOOK_URL\"" > "$CONFIG_FILE"
}

### 加载用户配置 ###
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        . "$CONFIG_FILE"
    else
        echo "未检测到配置文件，首次运行需要配置。"
        configure_script
    fi
}

### 配置脚本（首次运行时提示配置机器人 URL） ###
configure_script() {
    echo "是否启用企业微信机器人通知？(y/n)"
    read ENABLE_WEBHOOK
    if [ "$ENABLE_WEBHOOK" = "y" ]; then
        while [ -z "$WEBHOOK_URL" ]; do
            echo "请输入企业微信机器人 Webhook URL："
            read WEBHOOK_URL
        done
        echo "企业微信机器人已启用。"
    else
        echo "企业微信机器人通知已跳过。"
    fi
    save_config
}

### 获取系统详细信息 ###
get_system_info() {
    # 翻译运行时长
    local runtime=$(uptime -p | sed 's/up //')  # 去掉前缀 "up"
    runtime=$(echo "$runtime" | sed 's/hours/小时/g; s/hour/小时/g; s/minutes/分钟/g; s/minute/分钟/g; s/,/，/g')  # 替换为中文

    echo "-------------"
    echo "主机名:       $(hostname)"
    echo "系统版本:     $(grep -oP '(?<=PRETTY_NAME=").*(?=")' /etc/os-release)"
    echo "Linux版本:    $(uname -r)"
    echo "-------------"
    echo "CPU架构:      $(uname -m)"
    echo "CPU型号:      $(grep -m 1 'model name' /proc/cpuinfo | cut -d ':' -f2 | xargs)"
    echo "CPU核心数:    $(nproc)"
    echo "CPU频率:      $(lscpu | grep -oP '(?<=CPU MHz:).*' | xargs)"
    echo "-------------"
    echo "局域网 IP:    $(get_lan_ip)"
    echo "-------------"
    echo "CPU占用:      $(top -bn1 | grep "Cpu(s)" | sed "s/.* \([0-9.]*\)% id.*/\1/" | awk '{print 100 - $1"%"}')"
    echo "系统负载:     $(uptime | awk -F'load average:' '{print $2}' | xargs)"
    echo "物理内存:     $(free -m | awk 'NR==2{printf "%.2f/%.2fM (%.2f%%)", $3, $2, $3*100/$2}')"
    echo "虚拟内存:     $(free -m | awk 'NR==3{printf "%.2f/%.2fM (%.2f%%)", $3, $2, $3*100/$2}')"
    echo "硬盘占用:     $(df -h / | awk 'NR==2{print $3"/"$2 " ("$5")"}')"
    echo "-------------"
    echo "总接收:       $(awk 'BEGIN {rx_total=0} $1 ~ /^(eth|enp|eno)/ {rx_total += $2} END {printf "%.2f MB", rx_total/1024/1024}' /proc/net/dev)"
    echo "总发送:       $(awk 'BEGIN {tx_total=0} $1 ~ /^(eth|enp|eno)/ {tx_total += $10} END {printf "%.2f MB", tx_total/1024/1024}' /proc/net/dev)"
    echo "-------------"
    echo "网络算法:     $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "无法获取网络算法")"
    echo "-------------"
    echo "运营商:       $(curl -s ipinfo.io/org | xargs)"
    echo "IPv4地址:     $(curl -s ipinfo.io/ip)"
    echo "DNS地址:      $(cat /etc/resolv.conf | grep nameserver | awk '{print $2}' | xargs)"
    echo "地理位置:     $(curl -s ipinfo.io/city), $(curl -s ipinfo.io/country)"
    echo "系统时间:     $(date '+%Z %Y-%m-%d %I:%M %p')"
    echo "-------------"
    echo "运行时长:     $runtime"
}

### 获取局域网 IPv4 地址 ###
get_lan_ip() {
    if command -v ip >/dev/null 2>&1; then
        ip -4 addr show | awk '/inet / && !/127.0.0.1/ && !/docker/ && !/br-/ && !/virbr/ {gsub(/\/[0-9]+/, "", $2); print $2}' | head -n 1
    elif command -v ifconfig >/dev/null 2>&1; then
        ifconfig | awk '/inet / && $1 != "127.0.0.1" {print $2}' | head -n 1
    else
        echo "无法检测局域网 IP，未找到 ip 或 ifconfig 命令"
    fi
}

### 发送企业微信通知 ###
send_wechat_notification() {
    if [ -z "$WEBHOOK_URL" ]; then
        yellow "未配置企业微信 Webhook，跳过通知"
        return
    fi
    local message=$1
    local device_name
    device_name=$(hostname)  # 使用主机名作为设备名称
    curl -sSf -H "Content-Type: application/json" \
        -d "{\"msgtype\":\"text\",\"text\":{\"content\":\"[设备: $device_name] $message\"}}" \
        "$WEBHOOK_URL" >/dev/null || red "通知发送失败"
}

### 日志记录 ###
log_info() {
    if [ ! -d "$(dirname "$LOG_FILE")" ]; then
        echo "日志目录不存在：$(dirname "$LOG_FILE")"
        return 1
    fi
    get_system_info >> "$LOG_FILE"
}

### 主函数 ###
main() {
    load_config
    check_dependencies
    local system_info
    system_info=$(get_system_info)
    echo "$system_info"
    log_info
    send_wechat_notification "$system_info"
}

main
