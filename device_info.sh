#!/bin/bash
LOG_FILE="/var/log/device_info.log"
WEBHOOK_URL=""
DEPENDENCIES="curl ethtool ip"
CONFIG_FILE="/etc/device_info.conf"
MAX_LOG_SIZE=2097152
RETRY_INTERVAL=8
SYSTEMD_PRE_SLEEP=10
SEND_RETRY_INTERVAL=15
PING_TARGETS="1.1.1.1 8.8.8.8 223.5.5.5 9.9.9.9"
get_script_path() {
    if command -v realpath >/dev/null 2>&1; then
        realpath "$0"
    elif command -v readlink >/dev/null 2>&1; then
        readlink -f "$0"
    else
        local script="$0"
        local dir
        dir="$(cd "$(dirname "$script")" 2>/dev/null && pwd)"
        echo "${dir}/$(basename "$script")"
    fi
}
SCRIPT_PATH="$(get_script_path)"
red() { echo -e "\033[31m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }
green() { echo -e "\033[32m$*\033[0m"; }
blue() { echo -e "\033[34m$*\033[0m"; }
get_file_size() {
    local file="$1"
    if stat --version >/dev/null 2>&1; then
        stat -c%s "$file" 2>/dev/null
    else
        stat -f%z "$file" 2>/dev/null
    fi
}
log_info() {
    local log_dir
    log_dir=$(dirname "$LOG_FILE")
    if [ ! -d "$log_dir" ]; then
        if ! mkdir -p "$log_dir"; then
            echo "ERROR: Failed to create log directory $log_dir." >&2
            logger -t device_info "ERROR: Failed to create log directory $log_dir"
            return 1
        fi
    fi
    if [ -f "$LOG_FILE" ] && [ "$(get_file_size "$LOG_FILE")" -ge "$MAX_LOG_SIZE" ]; then
        truncate -s 0 "$LOG_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Log truncated due to size limit." >> "$LOG_FILE" 2>/dev/null || logger -t device_info "ERROR: Failed to write log truncation message."
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $*" >> "$LOG_FILE" 2>/dev/null || logger -t device_info "ERROR: Failed to write info log: $*"
}
log_error() {
    local log_dir
    log_dir=$(dirname "$LOG_FILE")
    if [ ! -d "$log_dir" ]; then mkdir -p "$log_dir" >/dev/null 2>&1; fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $*" >> "$LOG_FILE" 2>/dev/null || logger -t device_info "ERROR: Failed to write error log: $*"
    red "$*" >&2
}
log_debug() {
    :
}
check_dependencies() {
    log_info "开始检查依赖: $DEPENDENCIES"
    local missing_deps=""
    for dep in $DEPENDENCIES; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing_deps="$missing_deps $dep"
        fi
    done
    if [ -n "$missing_deps" ]; then
        missing_deps=$(echo "$missing_deps" | xargs)
        log_info "缺少依赖：$missing_deps，正在尝试自动安装..."
        yellow "缺少依赖：$missing_deps，正在尝试自动安装..."
        if ! command -v sudo > /dev/null 2>&1 && [ "$(id -u)" -ne 0 ]; then
            log_error "缺少依赖且 sudo 命令不存在，无法自动安装。"
            red "错误：缺少依赖且 sudo 命令不存在，请手动安装：$missing_deps"
            exit 1
        fi
        local install_cmd=""
        if command -v apt-get >/dev/null 2>&1; then
            install_cmd="sudo apt-get update && sudo apt-get install -y $missing_deps"
        elif command -v yum >/dev/null 2>&1; then
            install_cmd="sudo yum install -y $missing_deps"
        elif command -v dnf >/dev/null 2>&1; then
            install_cmd="sudo dnf install -y $missing_deps"
        elif command -v apk >/dev/null 2>&1; then
            install_cmd="sudo apk add --no-cache $missing_deps"
        elif command -v opkg >/dev/null 2>&1; then
            install_cmd="sudo opkg update && sudo opkg install $missing_deps"
        else
            log_error "无法识别的包管理器，请手动安装依赖：$missing_deps"
            red "无法识别的包管理器，请手动安装依赖：$missing_deps"
            exit 1
        fi
        log_info "执行安装命令: $install_cmd"
        if ! eval "$install_cmd"; then
            log_error "依赖安装命令执行失败。"
            red "错误：自动安装依赖失败，请检查网络或手动安装。"
        fi
        local still_missing=""
        for dep in $missing_deps; do
            if ! command -v "$dep" >/dev/null 2>&1; then
                still_missing="$still_missing $dep"
            fi
        done
        if [ -n "$still_missing" ]; then
            still_missing=$(echo "$still_missing" | xargs)
            log_error "以下依赖安装失败或仍未找到: $still_missing"
            red "错误：以下依赖安装失败或仍未找到: $still_missing"
            exit 1
        fi
        green "依赖 $missing_deps 似乎已成功安装。"
        log_info "依赖 $missing_deps 安装成功。"
    else
        green "所有依赖 ($DEPENDENCIES) 已满足。"
        log_info "所有依赖已满足。"
    fi
}
save_config() {
    local config_dir
    config_dir=$(dirname "$CONFIG_FILE")
    if ! mkdir -p "$config_dir"; then
        log_error "无法创建配置目录: $config_dir"
        red "错误: 无法创建配置目录 $config_dir"
        return 1
    fi
    if [ -e "$CONFIG_FILE" ] && [ ! -w "$CONFIG_FILE" ] && [ "$(id -u)" -ne 0 ]; then
        echo "WEBHOOK_URL=\"$WEBHOOK_URL\"" | sudo tee "$CONFIG_FILE" > /dev/null
        if [ $? -ne 0 ]; then
            log_error "使用 sudo 写入配置文件 $CONFIG_FILE 失败。"
            red "错误: 使用 sudo 写入配置文件 $CONFIG_FILE 失败。"
            return 1
        fi
    elif ! echo "WEBHOOK_URL=\"$WEBHOOK_URL\"" > "$CONFIG_FILE"; then
        log_error "写入配置文件 $CONFIG_FILE 失败"
        red "错误: 写入配置文件 $CONFIG_FILE 失败。"
        return 1
    fi
    chmod 600 "$CONFIG_FILE" 2>/dev/null || log_error "无法设置配置文件权限为 600"
    log_info "配置已保存到 $CONFIG_FILE"
    return 0
}
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        if ! grep -qE '^WEBHOOK_URL=' "$CONFIG_FILE"; then
            log_error "配置文件格式异常: $CONFIG_FILE"
            WEBHOOK_URL=$(grep '^WEBHOOK_URL=' "$CONFIG_FILE" | cut -d'=' -f2- | sed 's/^"//;s/"$//')
        else
            if ! source "$CONFIG_FILE" 2>/dev/null; then
                log_error "加载配置文件失败，尝试手动解析"
                WEBHOOK_URL=$(grep '^WEBHOOK_URL=' "$CONFIG_FILE" | cut -d'=' -f2- | sed 's/^"//;s/"$//')
            fi
        fi
        log_info "配置加载完成，Webhook 已${WEBHOOK_URL:+配置}${WEBHOOK_URL:-未配置}"
    else
        if [ ! -t 0 ]; then
            log_error "非交互式环境且无配置文件，退出。"
            red "错误：请先在交互式终端中运行脚本完成初始配置。"
            exit 1
        fi
        log_info "未检测到配置文件 ($CONFIG_FILE)，进行首次配置..."
        configure_script
    fi
}
configure_script() {
    if [ ! -t 0 ]; then
        log_error "非交互式环境且无配置文件，无法完成配置。"
        red "错误：请先在交互式终端中运行脚本完成初始配置。"
        exit 1
    fi
    echo
    blue "--- 脚本配置 ---"
    local enable_webhook=""
    while [[ "$enable_webhook" != "y" && "$enable_webhook" != "n" ]]; do
        read -p "是否启用企业微信机器人通知？(y/n): " enable_webhook
        enable_webhook=$(echo "$enable_webhook" | tr '[:upper:]' '[:lower:]')
    done
    if [ "$enable_webhook" = "y" ]; then
        WEBHOOK_URL=""
        while [ -z "$WEBHOOK_URL" ]; do
            read -p "请输入企业微信机器人 Webhook URL: " WEBHOOK_URL
            if [[ -z "$WEBHOOK_URL" ]]; then
                yellow "Webhook URL 不能为空，请重新输入。"
            elif [[ ! "$WEBHOOK_URL" =~ ^https?:// ]]; then
                yellow "Webhook URL 格式似乎无效 (应以 http:// 或 https:// 开头)，请重新输入。"
                WEBHOOK_URL=""
            fi
        done
        green "企业微信机器人通知已启用。"
        log_info "企业微信机器人通知已启用。"
    else
        WEBHOOK_URL=""
        yellow "企业微信机器人通知已禁用/跳过。"
        log_info "企业微信机器人通知已禁用/跳过。"
    fi
    save_config
    if [ $? -ne 0 ]; then
        red "配置保存失败!"
    fi
}
get_os_version() {
    local ver=""
    if [ -f /etc/os-release ]; then
        ver=$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")
    fi
    if [ -z "$ver" ] && [ -f /etc/os-release ]; then
        ver=$(sed -n 's/^PRETTY_NAME="\(.*\)"/\1/p' /etc/os-release 2>/dev/null)
    fi
    if [ -z "$ver" ] && [ -f /etc/issue ]; then
        ver=$(head -1 /etc/issue 2>/dev/null | sed 's/\\[^ ]//g' | xargs)
    fi
    echo "${ver:-未知}"
}
get_cpu_freq() {
    local freq=""
    if command -v lscpu >/dev/null 2>&1; then
        freq=$(lscpu 2>/dev/null | grep -i "cpu mhz" | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)
    fi
    if [ -z "$freq" ]; then
        freq=$(grep -m1 "cpu MHz" /proc/cpuinfo 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)?')
    fi
    if [ -z "$freq" ]; then
        local khz
        khz=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null)
        [ -n "$khz" ] && freq=$(awk "BEGIN {printf \"%.0f\", $khz/1000}")
    fi
    echo "${freq:+${freq} MHz}"
}
get_cpu_usage() {
    local cpu_usage=""
    if [ -f /proc/stat ]; then
        local cpu_line1 cpu_line2
        cpu_line1=$(grep '^cpu ' /proc/stat 2>/dev/null)
        sleep 1
        cpu_line2=$(grep '^cpu ' /proc/stat 2>/dev/null)
        if [ -n "$cpu_line1" ] && [ -n "$cpu_line2" ]; then
            cpu_usage=$(echo "$cpu_line1 $cpu_line2" | awk '{
                idle1=$5; total1=$2+$3+$4+$5+$6+$7+$8
                idle2=$13; total2=$10+$11+$12+$13+$14+$15+$16
                if ((total2-total1)>0)
                    printf "%.2f%%", (1-(idle2-idle1)/(total2-total1))*100
                else
                    print "未知"
            }')
        fi
    fi
    if [ -z "$cpu_usage" ] && command -v top >/dev/null 2>&1; then
        local cpu_idle
        cpu_idle=$(LC_ALL=C top -bn1 2>/dev/null | \
            grep -iE "^(%)?cpu" | \
            grep -oE '[0-9]+\.?[0-9]* *id' | \
            grep -oE '[0-9]+\.?[0-9]*' | head -1)
        if [ -n "$cpu_idle" ]; then
            cpu_usage=$(awk -v idle="$cpu_idle" 'BEGIN {printf "%.2f%%", 100-idle}')
        fi
    fi
    echo "${cpu_usage:-未知}"
}
get_memory_info() {
    local mem_info=""
    if command -v free >/dev/null 2>&1; then
        mem_info=$(free -m 2>/dev/null | awk '
            /^Mem:/ {
                if ($2 > 0)
                    printf "%.2f/%.2f MiB (%.2f%%)", $3, $2, $3*100/$2
            }')
    fi
    if [ -z "$mem_info" ] && [ -f /proc/meminfo ]; then
        local total avail used
        total=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
        avail=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
        if [ -n "$total" ] && [ -n "$avail" ] && [ "$total" -gt 0 ]; then
            used=$((total - avail))
            mem_info=$(awk "BEGIN {printf \"%.2f/%.2f MiB (%.2f%%)\", $used/1024, $total/1024, $used*100/$total}")
        fi
    fi
    echo "${mem_info:-未知}"
}
get_swap_info() {
    local swap_info=""
    if command -v free >/dev/null 2>&1; then
        swap_info=$(free -m 2>/dev/null | awk '
            /^Swap:/ {
                if ($2 > 0)
                    printf "%.2f/%.2f MiB (%.2f%%)", $3, $2, $3*100/$2
                else
                    print "N/A"
            }')
    fi
    if [ -z "$swap_info" ] && [ -f /proc/meminfo ]; then
        local total free_swap
        total=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)
        free_swap=$(awk '/^SwapFree:/{print $2}' /proc/meminfo)
        if [ -n "$total" ] && [ "$total" -gt 0 ]; then
            local swap_used=$((total - free_swap))
            swap_info=$(awk "BEGIN {printf \"%.2f/%.2f MiB (%.2f%%)\", $swap_used/1024, $total/1024, $swap_used*100/$total}")
        else
            swap_info="N/A"
        fi
    fi
    echo "${swap_info:-未知}"
}
get_net_traffic() {
    local rx_bytes=0 tx_bytes=0
    while IFS= read -r line; do
        local iface data
        iface=$(echo "$line" | awk -F: '{print $1}' | xargs)
        data=$(echo "$line" | awk -F: '{print $2}')
        if echo "$iface" | grep -qE '^(eth|enp|eno|wlan|wlp|ens)'; then
            local rx tx
            rx=$(echo "$data" | awk '{print $1}')
            tx=$(echo "$data" | awk '{print $9}')
            rx_bytes=$((rx_bytes + ${rx:-0}))
            tx_bytes=$((tx_bytes + ${tx:-0}))
        fi
    done < <(tail -n +3 /proc/net/dev 2>/dev/null)
    local total_rx total_tx
    total_rx=$(awk "BEGIN {printf \"%.2f MiB\", $rx_bytes/1048576}")
    total_tx=$(awk "BEGIN {printf \"%.2f MiB\", $tx_bytes/1048576}")
    echo "$total_rx $total_tx"
}
escape_json_string() {
    local input="$1"
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "
import json, sys
data = sys.stdin.read()
print(json.dumps(data)[1:-1], end='')
" <<< "$input"
        return
    fi
    if command -v python >/dev/null 2>&1; then
        python -c "
import json, sys
data = sys.stdin.read()
print(json.dumps(data)[1:-1], end='')
" <<< "$input"
        return
    fi
    printf '%s' "$input" | sed \
        -e 's/\\/\\\\/g' \
        -e 's/"/\\"/g' \
        -e 's/\t/\\t/g' \
        -e 's/\r/\\r/g' \
        -e ':a;N;$!ba;s/\n/\\n/g' \
        -e 's/[[:cntrl:]]//g'
}
get_interface_type() {
    local interface=$1
    local type="未知类型"
    if command -v ethtool >/dev/null 2>&1; then
        local ethtool_cmd="ethtool"
        if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
            ethtool_cmd="sudo ethtool"
        fi
        if $ethtool_cmd "$interface" 2>/dev/null | grep -q "Link detected: yes"; then
            type="有线"
        elif $ethtool_cmd "$interface" 2>/dev/null | grep -q "Supports Wake-on:"; then
            type="有线"
        fi
        if [ "$type" != "未知类型" ]; then echo "$type"; return 0; fi
    fi
    if command -v iwconfig >/dev/null 2>&1; then
        if iwconfig "$interface" 2>&1 | grep -qE "(ESSID:|Mode:Master)"; then
            if iwconfig "$interface" 2>&1 | grep -q "Mode:Master"; then
                type="无线AP"
            else
                type="无线"
            fi
        fi
        if [ "$type" != "未知类型" ]; then echo "$type"; return 0; fi
    fi
    if [ -d "/sys/class/net/$interface/wireless" ] || [ -d "/sys/class/net/$interface/phy80211" ]; then
        type="无线"
        echo "$type"; return 0
    fi
    if echo "$interface" | grep -qE '^(eth|enp|eno)'; then
        type="有线 (推测)"
    fi
    echo "$type"
}
get_lan_ip() {
    local ip_addresses=""
    local interfaces
    interfaces=$(ip -o link show 2>/dev/null | awk -F': ' '!/NO-CARRIER/ {print $2}' | grep -Ev '^(lo|docker|veth|tun|br-|virbr|vnet)')
    if [ -z "$interfaces" ]; then
        log_info "未找到合适的物理网络接口。"
        printf "  未找到局域网 IP 地址。"
        return 1
    fi
    local interface ip_info ip interface_type
    for interface in $interfaces; do
        ip_info=$(ip -4 -o addr show "$interface" 2>/dev/null | awk '{print $4}')
        if [ -n "$ip_info" ]; then
            ip=$(echo "$ip_info" | cut -d '/' -f 1)
            if [ -n "$ip" ] && [ "$ip" != "127.0.0.1" ]; then
                interface_type=$(get_interface_type "$interface")
                ip_addresses="${ip_addresses}  ${interface_type} (${interface}): ${ip}\\n"
            fi
        fi
    done
    if [ -z "$ip_addresses" ]; then
        log_info "遍历所有接口后未找到有效的局域网 IPv4 地址。"
        printf "  未找到局域网 IP 地址。"
        return 1
    else
        printf "%b" "${ip_addresses%\\n}"
        return 0
    fi
}
check_ping() {
    local target="$1"
    ping -c 1 -W 2 "$target" > /dev/null 2>&1
    return $?
}
get_public_ip_info() {
    local ipinfo_json=""
    local providers="ipinfo.io ip.sb/geoip ifconfig.co/json"
    for provider in $providers; do
        log_info "尝试从 $provider 获取公网信息..."
        ipinfo_json=$(curl -s --connect-timeout 8 --max-time 12 \
            -A "DeviceInfoScript/1.0" "https://$provider" 2>/dev/null)
        if [ -n "$ipinfo_json" ]; then
            log_info "成功从 $provider 获取公网信息"
            echo "$ipinfo_json"
            return 0
        fi
        log_info "从 $provider 获取公网信息失败，尝试下一个..."
    done
    log_error "所有公网信息源均获取失败"
    return 1
}
parse_ip_info() {
    local json="$1"
    local public_ip operator city country location
    public_ip=$(echo "$json" | sed -n 's/.*"ip": *"\([^"]*\)".*/\1/p' | head -1)
    [ -z "$public_ip" ] && public_ip=$(echo "$json" | sed -n 's/.*"ip":"\([^"]*\)".*/\1/p' | head -1)
    operator=$(echo "$json" | sed -n 's/.*"org": *"\([^"]*\)".*/\1/p' | head -1)
    [ -z "$operator" ] && operator=$(echo "$json" | sed -n 's/.*"isp": *"\([^"]*\)".*/\1/p' | head -1)
    city=$(echo "$json" | sed -n 's/.*"city": *"\([^"]*\)".*/\1/p' | head -1)
    country=$(echo "$json" | sed -n 's/.*"country": *"\([^"]*\)".*/\1/p' | head -1)
    [ -z "$country" ] && country=$(echo "$json" | sed -n 's/.*"country_name": *"\([^"]*\)".*/\1/p' | head -1)
    if [ -n "$city" ] && [ -n "$country" ]; then
        location="$city, $country"
    elif [ -n "$city" ]; then
        location="$city"
    elif [ -n "$country" ]; then
        location="$country"
    else
        location="未知地点"
    fi
    echo "${public_ip:-获取失败}|${operator:-未知运营商}|${location}"
}
get_system_info() {
    local runtime
    runtime=$(uptime -p 2>/dev/null | sed 's/up //')
    runtime=$(echo "$runtime" | sed \
        -e 's/years/年/g; s/year/年/g' \
        -e 's/months/月/g; s/month/月/g' \
        -e 's/weeks/周/g; s/week/周/g' \
        -e 's/days/天/g; s/day/天/g' \
        -e 's/hours/小时/g; s/hour/小时/g' \
        -e 's/minutes/分钟/g; s/minute/分钟/g' \
        -e 's/,/，/g')
    local lan_ips_formatted
    lan_ips_formatted=$(get_lan_ip)
    if [ -z "$lan_ips_formatted" ] || echo "$lan_ips_formatted" | grep -q "未找到"; then
        lan_ips_formatted="  未能获取局域网 IP 地址"
    fi
    local cpu_usage
    cpu_usage=$(get_cpu_usage)
    local mem_usage
    mem_usage=$(get_memory_info)
    local swap_usage
    swap_usage=$(get_swap_info)
    local disk_usage="未知"
    local info_str
    info_str=$(df -h / 2>/dev/null | awk 'NR==2{print $3"/"$2 " ("$5")"}')
    [ -n "$info_str" ] && disk_usage="$info_str"
    local net_traffic total_rx total_tx
    net_traffic=$(get_net_traffic)
    total_rx=$(echo "$net_traffic" | awk '{print $1, $2}')
    total_tx=$(echo "$net_traffic" | awk '{print $3, $4}')
    local network_algo cpu_model cpu_cores cpu_freq
    local os_version kernel_version architecture hostname
    hostname=$(hostname)
    network_algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '未知')
    cpu_model=$(grep -m 1 'model name' /proc/cpuinfo 2>/dev/null | cut -d ':' -f2 | xargs || echo '未知')
    cpu_cores=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo '未知')
    cpu_freq=$(get_cpu_freq)
    [ -z "$cpu_freq" ] && cpu_freq="未知"
    os_version=$(get_os_version)
    kernel_version=$(uname -r 2>/dev/null || echo '未知')
    architecture=$(uname -m 2>/dev/null || echo '未知')
    local public_ip="获取失败" operator="获取失败" location="获取失败"
    local ipinfo_json
    ipinfo_json=$(get_public_ip_info)
    if [ -n "$ipinfo_json" ]; then
        local parsed
        parsed=$(parse_ip_info "$ipinfo_json")
        public_ip=$(echo "$parsed" | cut -d'|' -f1)
        operator=$(echo "$parsed" | cut -d'|' -f2)
        location=$(echo "$parsed" | cut -d'|' -f3)
    fi
    local load_avg
    load_avg=$(uptime 2>/dev/null | awk -F'load average:' '{print $2}' | xargs || echo '未知')
    printf "[设备: %s] 系统信息:\n" "$hostname"
    printf "主机名: %s\n" "$hostname"
    printf "系统版本: %s\n" "$os_version"
    printf "Linux版本: %s\n" "$kernel_version"
    printf "CPU架构: %s\n" "$architecture"
    printf "CPU型号: %s\n" "$cpu_model"
    printf "CPU核心数: %s\n" "$cpu_cores"
    printf "CPU频率: %s\n" "$cpu_freq"
    printf "局域网 IP:\n%s\n" "$lan_ips_formatted"
    printf "CPU占用: %s\n" "$cpu_usage"
    printf "系统负载: %s\n" "$load_avg"
    printf "物理内存: %s\n" "$mem_usage"
    printf "虚拟内存: %s\n" "$swap_usage"
    printf "硬盘占用: %s\n" "$disk_usage"
    printf "总接收: %s\n" "$total_rx"
    printf "总发送: %s\n" "$total_tx"
    printf "网络算法: %s\n" "$network_algo"
    printf "运营商: %s\n" "$operator"
    printf "IPv4地址: %s\n" "$public_ip"
    printf "地理位置: %s\n" "$location"
    printf "系统时间: %s\n" "$(date '+%Z %Y-%m-%d %I:%M %p')"
    printf "运行时长: %s\n" "$runtime"
}
wait_for_network() {
    local retries=0
    log_info "开始等待网络连接，将持续等待直到网络就绪..."
    while true; do
        local ping_ok=false
        local target_ok=false
        local curl_exit_code=99
        for target in $PING_TARGETS; do
            if check_ping "$target"; then
                ping_ok=true
                log_info "Ping $target 成功"
                break
            fi
        done
        if [ -n "$WEBHOOK_URL" ]; then
            curl --head --fail --silent --output /dev/null \
                 --connect-timeout 8 --max-time 12 \
                 -A "DeviceInfoScript/1.0" "$WEBHOOK_URL"
            curl_exit_code=$?
            if [ $curl_exit_code -eq 0 ]; then
                target_ok=true
            fi
        else
            target_ok=true
            curl_exit_code=0
        fi
        if [ "$ping_ok" = true ] && [ "$target_ok" = true ]; then
            log_info "网络已就绪 (Ping 成功, Webhook 可达/未配置)，共等待 $retries 次。"
            return 0
        fi
        retries=$((retries + 1))
        log_info "网络未就绪 (Ping: $ping_ok, Webhook: $target_ok [curl:$curl_exit_code]), ${RETRY_INTERVAL}秒后重试 (第 $retries 次)..."
        sleep $RETRY_INTERVAL
    done
}
send_wechat_notification() {
    if [ -z "$WEBHOOK_URL" ] && [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE" 2>/dev/null || \
            WEBHOOK_URL=$(grep '^WEBHOOK_URL=' "$CONFIG_FILE" | cut -d'=' -f2- | sed 's/^"//;s/"$//')
    fi
    if [ -z "$WEBHOOK_URL" ]; then
        yellow "未配置或未启用企业微信 Webhook，跳过通知。"
        log_info "Webhook URL 为空或未配置，跳过通知。"
        return 0
    fi
    log_info "准备发送企业微信通知 (Webhook: ${WEBHOOK_URL:0:30}...)"
    yellow "准备发送企业微信通知..."
    local system_info
    system_info=$(get_system_info)
    if [ -z "$system_info" ]; then
        log_error "获取系统信息失败，无法发送通知内容。"
        red "错误: 获取系统信息失败。"
        return 1
    fi
    local escaped_info
    escaped_info=$(escape_json_string "$system_info")
    local json_payload="{\"msgtype\":\"text\",\"text\":{\"content\":\"$escaped_info\"}}"
    local retries=0
    local curl_error_log
    curl_error_log=$(mktemp /tmp/curl_error.XXXXXX 2>/dev/null) || curl_error_log="/tmp/curl_error.$$"
    while true; do
        local http_code curl_exit_code curl_error_msg error_reason
        http_code=$(curl --fail -s -o /dev/null -w "%{http_code}" \
                       -H "Content-Type: application/json" \
                       -X POST -d "$json_payload" "$WEBHOOK_URL" \
                       --connect-timeout 15 --max-time 30 \
                       -A "DeviceInfoScript/1.0" \
                       2> "$curl_error_log")
        curl_exit_code=$?
        [ -f "$curl_error_log" ] && curl_error_msg=$(<"$curl_error_log")
        if [ $curl_exit_code -eq 0 ] && [ "$http_code" -eq 200 ]; then
            green "企业微信通知发送成功 (HTTP $http_code)。"
            log_info "企业微信通知发送成功，共重试 $retries 次。"
            rm -f "$curl_error_log"
            return 0
        else
            retries=$((retries + 1))
            error_reason="未知错误"
            if [ $curl_exit_code -ne 0 ]; then
                case $curl_exit_code in
                    6) error_reason="无法解析主机 (DNS 问题?)";;
                    7) error_reason="无法连接到主机";;
                    22) error_reason="HTTP 错误 >= 400 (HTTP $http_code)";;
                    28) error_reason="操作超时";;
                    *) error_reason="curl 命令失败 (Exit Code: $curl_exit_code)";;
                esac
                [ -n "$curl_error_msg" ] && error_reason="$error_reason - $curl_error_msg"
            elif [ "$http_code" -ne 200 ]; then
                error_reason="服务器返回非 200 状态码 (HTTP $http_code)"
            fi
            red "发送失败 ($error_reason)，${SEND_RETRY_INTERVAL}秒后重试 (第 $retries 次)..."
            log_error "企业微信通知发送失败 ($error_reason)，重试第 $retries 次..."
            sleep $SEND_RETRY_INTERVAL
        fi
    done
}
check_and_enable_service() {
    local service_name="$1"
    local status
    status=$(sudo systemctl is-enabled "$service_name" 2>/dev/null)
    case "$status" in
        enabled|static)
            log_info "服务 $service_name 已启用 (状态: $status)"
            ;;
        disabled|"")
            log_info "启用服务: $service_name"
            if ! sudo systemctl enable "$service_name" 2>/dev/null; then
                log_error "启用服务失败: $service_name"
                return 1
            fi
            log_info "已成功启用服务: $service_name"
            ;;
        *)
            log_info "服务状态未知 ($status)，尝试启用..."
            sudo systemctl enable "$service_name" 2>/dev/null || log_error "启用服务失败: $service_name"
            ;;
    esac
    return 0
}
setup_autostart() {
    log_info "检查并设置自启动..."
    if command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then
        local service_name="device_info_notify.service"
        local service_file="/etc/systemd/system/$service_name"
        local need_reload=false
        local need_update=false
        local full_script_path
        if ! full_script_path=$(get_script_path); then
            log_error "无法解析脚本的绝对路径: $SCRIPT_PATH"
            red "错误: 无法解析脚本路径 '$SCRIPT_PATH'"
            return 1
        fi
        local working_dir
        working_dir=$(dirname "$full_script_path")
        local expected_service_content
        read -r -d '' expected_service_content << EOF
[Unit]
Description=Device Info Notifier on Boot After Network
After=network-online.target network.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=no
ExecStartPre=/bin/sleep $SYSTEMD_PRE_SLEEP
ExecStart=$full_script_path
User=root
WorkingDirectory=$working_dir
Restart=on-failure
RestartSec=30
StartLimitIntervalSec=600
StartLimitBurst=10

[Install]
WantedBy=multi-user.target
EOF
        if [ ! -f "$service_file" ] || ! cmp -s <(echo "$expected_service_content") "$service_file"; then
            log_info "创建或更新 systemd 服务文件: $service_file"
            yellow "检测到 systemd 服务文件需要创建或更新..."
            need_update=true
        fi
        if [ "$need_update" = true ]; then
            if ! echo "$expected_service_content" | sudo tee "$service_file" > /dev/null; then
                log_error "创建/更新 systemd 服务文件失败: $service_file"
                red "错误：创建/更新 systemd 服务文件失败。"
                return 1
            fi
            log_info "已成功创建/更新 systemd 服务文件: $service_file"
            need_reload=true
        fi
        if ! check_and_enable_service "$service_name"; then
            log_error "服务启用步骤失败: $service_name"
        else
            need_reload=true
        fi
        if [ "$need_reload" = true ]; then
            log_info "重新加载 systemd 配置..."
            if ! sudo systemctl daemon-reload; then
                log_error "重新加载 systemd 配置失败。"
                red "警告：重新加载 systemd 配置失败。"
            else
                log_info "Systemd 配置已重新加载。"
            fi
        fi
        green "Systemd 自启动设置检查/配置完成。"
        log_info "Systemd 自启动设置检查/配置完成。"
        return 0
    elif [ -f "/etc/rc.local" ]; then
        log_info "检测到 /etc/rc.local，将尝试使用它设置自启动。"
        local rc_command="$SCRIPT_PATH &"
        if ! grep -qF "$SCRIPT_PATH" /etc/rc.local; then
            log_info "尝试将脚本添加到 /etc/rc.local..."
            yellow "正在尝试配置 rc.local 自启动..."
            if [ ! -x "/etc/rc.local" ]; then
                if ! sudo chmod +x /etc/rc.local; then
                    log_error "无法使 /etc/rc.local 可执行。"
                    red "错误: 无法设置 /etc/rc.local 执行权限。"
                    return 1
                fi
                log_info "/etc/rc.local 文件已设置为可执行。"
            fi
            if grep -q '^\s*exit\s\+0' /etc/rc.local; then
                if ! sudo sed -i "/^\s*exit\s\+0/i $rc_command" /etc/rc.local; then
                    log_error "使用 sed 向 /etc/rc.local 添加命令失败。"
                    red "错误: 添加命令到 /etc/rc.local 失败 (sed)。"
                    return 1
                fi
            else
                if ! echo "$rc_command" | sudo tee -a /etc/rc.local > /dev/null; then
                    log_error "使用 tee 向 /etc/rc.local 追加命令失败。"
                    red "错误: 添加命令到 /etc/rc.local 失败 (tee)。"
                    return 1
                fi
            fi
            if grep -qF "$SCRIPT_PATH" /etc/rc.local; then
                log_info "已将脚本添加到 rc.local 自启动。"
                green "已将脚本添加到 rc.local 自启动。"
            else
                log_error "验证时发现命令未能成功添加到 /etc/rc.local。"
                red "错误：将脚本添加到 rc.local 失败 (验证失败)。"
                return 1
            fi
        else
            log_info "脚本已存在于 /etc/rc.local 中，无需重复添加。"
            green "脚本已配置在 rc.local 中。"
        fi
        return 0
    else
        log_error "未找到 systemd 或 /etc/rc.local，无法自动设置自启动。"
        red "错误：未找到 systemd 或 /etc/rc.local，请手动配置自启动。"
        return 1
    fi
}
main() {
    if [ "$(id -u)" -ne 0 ]; then
        if ! command -v sudo >/dev/null 2>&1; then
            red "警告: 当前用户非 root，且 sudo 命令不可用。依赖安装和自启动设置可能失败。"
            log_error "非 root 用户运行，且 sudo 不可用。"
        else
            yellow "提示: 脚本的部分操作 (如安装依赖、设置自启动) 可能需要 sudo 权限。"
        fi
    fi
    log_info "--- 脚本开始执行 (PID: $$) ---"
    blue "--- 设备信息通知脚本 ---"
    load_config
    check_dependencies
    wait_for_network
    send_wechat_notification
    local send_status=$?
    log_info "开始收集并记录系统信息快照..."
    local current_info
    current_info=$(get_system_info)
    if [ -n "$current_info" ]; then
        log_info "-- SysInfo Snapshot Start --"
        printf "%s\n" "$current_info" >> "$LOG_FILE" 2>/dev/null || log_error "写入 SysInfo 快照到日志失败。"
        log_info "-- SysInfo Snapshot End --"
        echo
        blue "--- 当前系统信息 ---"
        echo "$current_info"
        echo
    else
        log_error "获取系统信息失败，无法记录快照。"
    fi
    if ! setup_autostart; then
        log_error "设置自启动时遇到错误。"
        red "警告: 设置自启动失败，脚本可能不会在重启后自动运行。"
    fi
    if [ $send_status -eq 0 ]; then
        green "脚本执行完成 (通知发送成功或因未配置而跳过)。"
    else
        yellow "脚本执行完成，但通知发送失败 (详见日志: $LOG_FILE)。"
    fi
    log_info "--- 脚本执行完毕 (通知发送状态: $send_status) ---"
    echo
    exit $send_status
}
main
