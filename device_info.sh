#!/bin/bash

### 配置常量 (移除 STATUS_FILE) ###
LOG_FILE="/var/log/device_info.log"
WEBHOOK_URL="" # 将在配置中加载或设置
DEPENDENCIES="curl ethtool ip"
CONFIG_FILE="/etc/device_info.conf"
# STATUS_FILE="/tmp/device_notify_status" # --- REMOVED ---
MAX_LOG_SIZE=2097152 # 2MB 日志大小限制
SCRIPT_PATH="$(realpath "$0")"
PING_TARGET="223.5.5.5" # 用于检测基本网络连接的目标
MAX_RETRIES=20 # 网络检测和通知发送的最大重试次数
RETRY_INTERVAL=8 # 重试间隔（秒）
SYSTEMD_PRE_SLEEP=20 # 在 systemd 服务启动脚本前等待的秒数

### 彩色输出函数 (完整) ###
red() { echo -e "\033[31m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }
green() { echo -e "\033[32m$*\033[0m"; }
blue() { echo -e "\033[34m$*\033[0m"; }

### 日志记录函数 (完整) ###
log_info() {
    # Ensure log directory exists
    local log_dir
    log_dir=$(dirname "$LOG_FILE")
    if [ ! -d "$log_dir" ]; then
        if ! mkdir -p "$log_dir"; then
            echo "ERROR: Failed to create log directory $log_dir. Cannot log." >&2
            logger -t device_info "ERROR: Failed to create log directory $log_dir"
            return 1
        fi
    fi
    # Check log size and truncate if necessary
    if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE")" -ge "$MAX_LOG_SIZE" ]; then
        truncate -s 0 "$LOG_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Log truncated due to size limit." >> "$LOG_FILE" 2>/dev/null || logger -t device_info "ERROR: Failed to write log truncation message."
    fi
    # Write log message
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $@" >> "$LOG_FILE" 2>/dev/null || logger -t device_info "ERROR: Failed to write info log: $@"
}

log_error() {
    local log_dir
    log_dir=$(dirname "$LOG_FILE")
    # Try creating silently if it doesn't exist
    if [ ! -d "$log_dir" ]; then mkdir -p "$log_dir" >/dev/null 2>&1; fi
    # Write log message
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $@" >> "$LOG_FILE" 2>/dev/null || logger -t device_info "ERROR: Failed to write error log: $@"
    # Output error in red to stderr
    red "$@" >&2
}

log_debug() {
    # Disabled by default to avoid excessive logging
    :
    # To enable debug logging, uncomment the following lines:
    # local log_dir=$(dirname "$LOG_FILE")
    # if [ ! -d "$log_dir" ]; then mkdir -p "$log_dir" >/dev/null 2>&1; fi
    # echo "$(date '+%Y-%m-%d %H:%M:%S') [DEBUG] $@" >> "$LOG_FILE" 2>/dev/null
}

### 检查依赖 (完整) ###
check_dependencies() {
    log_info "开始检查依赖: $DEPENDENCIES"
    local missing_deps=""
    for dep in $DEPENDENCIES; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing_deps="$missing_deps $dep"
        fi
    done

    if [ -n "$missing_deps" ]; then
        missing_deps=$(echo "$missing_deps" | xargs) # Trim leading/trailing whitespace
        log_info "缺少依赖：$missing_deps，正在尝试自动安装..."
        yellow "缺少依赖：$missing_deps，正在尝试自动安装..."

        # Check for sudo if not root
        if ! command -v sudo > /dev/null 2>&1 && [ "$(id -u)" -ne 0 ]; then
            log_error "缺少依赖且 sudo 命令不存在，无法自动安装。"
            red "错误：缺少依赖且 sudo 命令不存在，请手动安装：$missing_deps"
            exit 1
        fi

        local install_cmd=""
        # Determine package manager and build install command
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

        # Attempt installation
        log_info "执行安装命令: $install_cmd"
        if ! eval "$install_cmd"; then # Use eval to handle potential complex commands like apt update && install
            log_error "依赖安装命令执行失败。"
            red "错误：自动安装依赖失败，请检查网络或手动安装。"
            # Don't exit immediately, perform re-check
        fi

        # Re-check dependencies after attempting installation
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


### 配置 (完整) ###
save_config() {
    local config_dir
    config_dir=$(dirname "$CONFIG_FILE")
    if ! mkdir -p "$config_dir"; then
        log_error "无法创建配置目录: $config_dir"
        red "错误: 无法创建配置目录 $config_dir"
        return 1
    fi

    # Check write permissions or use sudo
    if [ -e "$CONFIG_FILE" ] && [ ! -w "$CONFIG_FILE" ] && [ "$(id -u)" -ne 0 ]; then
        echo "WEBHOOK_URL=\"$WEBHOOK_URL\"" | sudo tee "$CONFIG_FILE" > /dev/null
        if [ $? -ne 0 ]; then
            log_error "使用 sudo 写入配置文件 $CONFIG_FILE 失败。"
            red "错误: 使用 sudo 写入配置文件 $CONFIG_FILE 失败。"
            return 1
        fi
    elif ! echo "WEBHOOK_URL=\"$WEBHOOK_URL\"" > "$CONFIG_FILE"; then
        log_error "写入配置文件 $CONFIG_FILE 失败 (权限或磁盘空间问题?)"
        red "错误: 写入配置文件 $CONFIG_FILE 失败。"
        return 1
    fi

    log_info "配置已保存到 $CONFIG_FILE"
    return 0
}

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # Source the config file, handle potential errors during sourcing
        if ! source "$CONFIG_FILE"; then
             log_error "加载配置文件 $CONFIG_FILE 时出错。"
             red "错误: 加载配置文件 $CONFIG_FILE 时出错。"
             # Decide if this is fatal, maybe exit?
             # exit 1
        else
             log_info "已加载配置文件 $CONFIG_FILE"
        fi
    else
        log_info "未检测到配置文件 ($CONFIG_FILE)，进行首次配置..."
        configure_script # Call configuration function
    fi
}

configure_script() {
    # Assumes interactive run
    echo # Newline for clarity
    blue "--- 脚本配置 ---"
    local enable_webhook=""
    # Loop until valid input (y/n)
    while [[ "$enable_webhook" != "y" && "$enable_webhook" != "n" ]]; do
        read -p "是否启用企业微信机器人通知？(y/n): " enable_webhook
        enable_webhook=$(echo "$enable_webhook" | tr '[:upper:]' '[:lower:]') # Convert to lowercase
    done

    if [ "$enable_webhook" = "y" ]; then
        WEBHOOK_URL="" # Clear potentially loaded value before asking
        # Loop until a non-empty and potentially valid URL is entered
        while [ -z "$WEBHOOK_URL" ]; do
            read -p "请输入企业微信机器人 Webhook URL: " WEBHOOK_URL
            if [[ -z "$WEBHOOK_URL" ]]; then
                yellow "Webhook URL 不能为空，请重新输入。"
            elif [[ ! "$WEBHOOK_URL" =~ ^https?:// ]]; then
                yellow "Webhook URL 格式似乎无效 (应以 http:// 或 https:// 开头)，请重新输入。"
                WEBHOOK_URL="" # Clear invalid input
            fi
        done
        green "企业微信机器人通知已启用。"
        log_info "企业微信机器人通知已启用。"
    else
        WEBHOOK_URL="" # Explicitly set to empty if disabled
        yellow "企业微信机器人通知已禁用/跳过。"
        log_info "企业微信机器人通知已禁用/跳过。"
    fi

    # Save the configuration
    save_config
    if [ $? -ne 0 ]; then
        red "配置保存失败!"
        # Consider if script should exit here
        # exit 1
    fi
}

### 获取系统信息 (完整) ###
get_system_info() {
    log_debug "开始获取系统信息..."
    local runtime info_str
    # Runtime
    runtime=$(uptime -p 2>/dev/null | sed 's/up //')
    runtime=$(echo "$runtime" | sed \
        -e 's/years/年/g; s/year/年/g' \
        -e 's/months/月/g; s/month/月/g' \
        -e 's/weeks/周/g; s/week/周/g' \
        -e 's/days/天/g; s/day/天/g' \
        -e 's/hours/小时/g; s/hour/小时/g' \
        -e 's/minutes/分钟/g; s/minute/分钟/g' \
        -e 's/,/，/g')

    # LAN IPs
    local lan_ips_formatted
    lan_ips_formatted=$(get_lan_ip) # Call function to get formatted IPs
    if [[ -z "$lan_ips_formatted" || "$lan_ips_formatted" == *"未找到"* ]]; then
        lan_ips_formatted="  未能获取局域网 IP 地址"
        log_info "未能获取局域网 IP 地址。"
    fi

    # CPU Usage
    local cpu_idle cpu_usage="未知"
    cpu_idle=$(top -bn1 | grep "Cpu(s)" | sed "s/.*,\s*\([0-9.]*\)\s*%id.*/\1/")
    if [[ "$cpu_idle" =~ ^[0-9.]+$ ]]; then
        cpu_usage=$(awk -v idle="$cpu_idle" 'BEGIN { printf "%.2f%%", 100 - idle }')
    fi
    log_debug "CPU Usage: $cpu_usage (Idle: $cpu_idle%)"

    # Memory Usage
    local mem_info mem_usage="未知"
    mem_info=$(free -m | awk 'NR==2{printf "%.2f/%.2f MiB (%.2f%%)", $3, $2, $3*100/$2}')
    [ -n "$mem_info" ] && mem_usage="$mem_info"
    log_debug "Memory Usage: $mem_usage"

    # Swap Usage
    local swap_info swap_usage="未知"
    swap_info=$(free -m | awk 'NR==3{if ($2>0) printf "%.2f/%.2f MiB (%.2f%%)", $3, $2, $3*100/$2; else print "N/A"}')
     [ -n "$swap_info" ] && swap_usage="$swap_info"
    log_debug "Swap Usage: $swap_usage"

    # Disk Usage (Root filesystem)
    local disk_usage="未知"
    info_str=$(df -h / 2>/dev/null | awk 'NR==2{print $3"/"$2 " ("$5")"}')
    [ -n "$info_str" ] && disk_usage="$info_str"
    log_debug "Disk Usage (/): $disk_usage"

    # Network Traffic (Common interfaces)
    local total_rx="未知" total_tx="未知"
    info_str=$(awk 'BEGIN {rx=0} $1 ~ /^(eth|enp|eno|wlan|wlp)/ {rx += $2} END {printf "%.2f MiB", rx/1024/1024}' /proc/net/dev 2>/dev/null)
    [ -n "$info_str" ] && total_rx="$info_str"
    info_str=$(awk 'BEGIN {tx=0} $1 ~ /^(eth|enp|eno|wlan|wlp)/ {tx += $10} END {printf "%.2f MiB", tx/1024/1024}' /proc/net/dev 2>/dev/null)
    [ -n "$info_str" ] && total_tx="$info_str"
    log_debug "Net Traffic: RX $total_rx, TX $total_tx"

    # Other System Info
    local network_algo="未知" cpu_model="未知" cpu_cores="未知" cpu_freq="未知"
    local os_version="未知" kernel_version="未知" architecture="未知" hostname
    hostname=$(hostname)
    network_algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '未知')
    cpu_model=$(grep -m 1 'model name' /proc/cpuinfo | cut -d ':' -f2 | xargs 2>/dev/null || echo '未知')
    cpu_cores=$(nproc 2>/dev/null || echo '未知')
    info_str=$(lscpu | grep -oP 'CPU MHz:\s*\K[0-9.]+' | xargs 2>/dev/null)
    [ -n "$info_str" ] && cpu_freq="${info_str} MHz"
    os_version=$(grep -oP '(?<=PRETTY_NAME=").*(?=")' /etc/os-release 2>/dev/null || cat /etc/os-release | head -n 1 2>/dev/null || echo '未知')
    kernel_version=$(uname -r 2>/dev/null || echo '未知')
    architecture=$(uname -m 2>/dev/null || echo '未知')

    # Public IP Info
    local ipinfo_json="" public_ip="获取中..." operator="获取中..." location="获取中..."
    ipinfo_json=$(curl -s --connect-timeout 10 --max-time 15 ipinfo.io 2>/dev/null)
    if [ -n "$ipinfo_json" ]; then
        log_debug "Got ipinfo.io response"
        public_ip=$(echo "$ipinfo_json" | grep -oP '"ip": *"\K[^"]+' || echo "未知 IPv4")
        operator=$(echo "$ipinfo_json" | grep -oP '"org": *"\K[^"]+' || echo "未知运营商")
        local city country
        city=$(echo "$ipinfo_json" | grep -oP '"city": *"\K[^"]+' || echo '')
        country=$(echo "$ipinfo_json" | grep -oP '"country": *"\K[^"]+' || echo '')
        if [ -n "$city" ] && [ -n "$country" ]; then location="$city, $country"
        elif [ -n "$city" ]; then location="$city"
        elif [ -n "$country" ]; then location="$country"
        else location="未知地点"; fi
    else
        log_error "获取公网信息失败 (curl ipinfo.io)"
        public_ip="获取失败"; operator="获取失败"; location="获取失败"
    fi
    log_debug "Public IP: $public_ip"

    # Format the output using printf for better control
    printf "[设备: %s] 系统信息:\n" "$hostname"
    printf "主机名: %s\n" "$hostname"
    printf "系统版本: %s\n" "$os_version"
    printf "Linux版本: %s\n" "$kernel_version"
    printf "CPU架构: %s\n" "$architecture"
    printf "CPU型号: %s\n" "$cpu_model"
    printf "CPU核心数: %s\n" "$cpu_cores"
    printf "CPU频率: %s\n" "$cpu_freq"
    printf "局域网 IP:\n%s\n" "$lan_ips_formatted" # Already has indentation
    printf "CPU占用: %s\n" "$cpu_usage"
    printf "系统负载: %s\n" "$(uptime | awk -F'load average:' '{print $2}' | xargs 2>/dev/null || echo '未知')"
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


### 获取局域网 IPv4 地址 (修正语法错误) ###
get_lan_ip() {
    local ip_addresses=""
    # Get interface names: up, no carrier removed, excludes common virtual/loopback
    # Pipe stderr to /dev/null for 'ip link' in case of errors on some systems
    local interfaces
    interfaces=$(ip -o link show 2>/dev/null | awk -F': ' '!/NO-CARRIER/ {print $2}' | grep -Ev '^(lo|docker|veth|tun|br-|virbr|vnet)')

    if [ -z "$interfaces" ]; then
        log_info "未找到合适的物理网络接口。"
        # Return the message directly, no need for echo here as it's captured by caller
        printf "  未找到局域网 IP 地址。"
        return 1
    fi

    log_debug "检测到的网络接口: $interfaces"
    local interface ip_info ip interface_type
    for interface in $interfaces; do
        # Get IPv4 address info for the interface
        ip_info=$(ip -4 -o addr show "$interface" 2>/dev/null | awk '{print $4}')
        if [ -n "$ip_info" ]; then
            ip=$(echo "$ip_info" | cut -d '/' -f 1)
            # Ensure IP is not empty and not loopback
            if [ -n "$ip" ] && [[ "$ip" != "127.0.0.1" ]]; then
                interface_type=$(get_interface_type "$interface")
                # Append formatted string, ensure newline is literal \n for printf later
                ip_addresses="${ip_addresses}  ${interface_type} (${interface}): ${ip}\\n"
                log_debug "获取到 IP: $interface_type ($interface): $ip"
            elif [[ "$ip" == "127.0.0.1" ]]; then
                 log_debug "排除回环地址: $ip on $interface"
            fi
        else
             log_debug "接口 $interface 没有 IPv4 地址。"
        fi
    done

    if [ -z "$ip_addresses" ]; then
        log_info "遍历所有接口后未找到有效的局域网 IPv4 地址。"
        printf "  未找到局域网 IP 地址。"
        return 1
    else
        # Use printf to interpret the \n correctly and remove the last one
        printf "%b" "${ip_addresses%\\n}"
        log_debug "最终格式化的局域网 IP (raw): $ip_addresses"
        return 0
    fi
}

### 获取接口类型 (完整) ###
get_interface_type() {
    local interface=$1
    local type="未知类型" # Default type

    # Try ethtool (needs privileges usually)
    if command -v ethtool >/dev/null 2>&1; then
        local ethtool_cmd="ethtool"
        # Use sudo if available and not root
        if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
            ethtool_cmd="sudo ethtool"
        fi
        # Check link status or WoL support, suppress errors for non-ethernet interfaces
        if $ethtool_cmd "$interface" 2>/dev/null | grep -q "Link detected: yes"; then
            type="有线"
        elif $ethtool_cmd "$interface" 2>/dev/null | grep -q "Supports Wake-on:"; then
            type="有线"
        fi
        # Return if type found
        if [ "$type" != "未知类型" ]; then echo "$type"; return 0; fi
    fi

    # Try iwconfig for wireless
    if command -v iwconfig >/dev/null 2>&1; then
        # Check for ESSID or Mode:Master, suppress errors
        if iwconfig "$interface" 2>&1 | grep -qE "(ESSID:|Mode:Master)"; then
            if iwconfig "$interface" 2>&1 | grep -q "Mode:Master"; then
                type="无线AP"
            else
                type="无线"
            fi
        fi
        # Return if type found
        if [ "$type" != "未知类型" ]; then echo "$type"; return 0; fi
    fi

    # Check sysfs paths for wireless
    if [[ -d "/sys/class/net/$interface/wireless" || -d "/sys/class/net/$interface/phy80211" ]]; then
        type="无线"
        # Return if type found
        if [ "$type" != "未知类型" ]; then echo "$type"; return 0; fi
    fi

    # Fallback guess based on common ethernet names
    if [[ "$interface" =~ ^(eth|enp|eno) ]]; then
         type="有线 (推测)"
    fi

    echo "$type"
}

### 检测网络连接 (修改: 增加 Webhook URL 检测) ###
wait_for_network() {
    local retries=0
    log_info "开始等待网络连接 (Ping: $PING_TARGET, Webhook Reachability, Max: $MAX_RETRIES 次)..."

    # Check Webhook URL - needed for the check inside loop
    if [ -z "$WEBHOOK_URL" ]; then
        log_info "Webhook URL 未配置，跳过 Webhook 可达性检测。"
        # If only ping is desired when no webhook, modify logic here
        # For now, webhook_ok defaults to true if URL is empty
    fi

    while [ $retries -lt $MAX_RETRIES ]; do
        local ping_ok=false
        local webhook_ok=false
        local curl_exit_code=99 # Use distinct code for "not run"

        # 1. Ping Test
        if ping -c 1 -W 2 $PING_TARGET > /dev/null 2>&1; then
            ping_ok=true
            log_debug "Ping $PING_TARGET 成功。"
        else
            log_debug "Ping $PING_TARGET 失败。"
        fi

        # 2. Webhook Reachability Test (only if URL is set)
        if [ -n "$WEBHOOK_URL" ]; then
            # Use curl --head for lighter check, add user agent
            curl --head --fail --silent --output /dev/null \
                 --connect-timeout 5 --max-time 8 \
                 -A "DeviceInfoScript/1.0" "$WEBHOOK_URL"
            curl_exit_code=$?
            if [ $curl_exit_code -eq 0 ]; then
                 webhook_ok=true
                 log_debug "Webhook URL 可达性检测成功。"
            else
                 log_debug "Webhook URL 可达性检测失败 (curl exit code: $curl_exit_code)."
            fi
        else
            # If URL is not configured, consider this check passed
            webhook_ok=true
            curl_exit_code=0 # Simulate success for logic below
        fi

        # Check if both conditions met
        if [ "$ping_ok" = true ] && [ "$webhook_ok" = true ]; then
            log_info "网络已连接 (Ping 成功，Webhook URL 可达/未配置)。"
            return 0 # Success
        fi

        # Increment retry counter and wait
        retries=$((retries + 1))
        log_info "网络未就绪 (Ping OK: $ping_ok, Webhook OK: $webhook_ok [curl code:$curl_exit_code]), 等待 $RETRY_INTERVAL 秒后重试... (第 $retries/$MAX_RETRIES 次)"
        sleep $RETRY_INTERVAL
    done

    log_error "网络连接检测失败 (Ping 或 Webhook 检测未通过)，已达到最大重试次数 ($MAX_RETRIES)。"
    return 1 # Failure
}


### 发送企业微信通知 (修改: 移除状态文件检查) ###
send_wechat_notification() {
    # Reload config just in case it wasn't loaded in main (e.g., direct function call)
    # Also ensures WEBHOOK_URL is up-to-date if changed externally? Unlikely needed.
    if [ -z "$WEBHOOK_URL" ] && [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi

    # Check if webhook is configured
    if [ -z "$WEBHOOK_URL" ]; then
        yellow "未配置或未启用企业微信 Webhook，跳过通知。"
        log_info "Webhook URL 为空或未配置，跳过通知。"
        return 0 # Successful operation (nothing to do)
    fi

    # Script now attempts to send every time it runs (relies on systemd for once-per-boot)
    log_info "准备发送企业微信通知 (Webhook: ${WEBHOOK_URL:0:30}...)"
    yellow "准备发送企业微信通知..."

    local system_info
    system_info=$(get_system_info)
    if [ -z "$system_info" ]; then
        log_error "获取系统信息失败，无法发送通知内容。"
        red "错误: 获取系统信息失败。"
        return 1
    fi

    # Escape JSON string: backslashes, double quotes, newlines
    local escaped_info
    escaped_info=$(echo "$system_info" | sed -e ':a' -e 'N' -e '$!ba' -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\n/\\n/g')
    local json_payload="{\"msgtype\":\"text\",\"text\":{\"content\":\"$escaped_info\"}}"

    local retries=0
    local curl_error_log="/tmp/curl_error.$$.log" # Temporary file for stderr

    while [ $retries -lt $MAX_RETRIES ]; do
        local http_code curl_exit_code curl_error_msg error_reason

        # Attempt to send using curl
        # Use --fail, silent, capture http_code, connect/total timeouts, stderr capture
        http_code=$(curl --fail -s -o /dev/null -w "%{http_code}" \
                       -H "Content-Type: application/json" \
                       -X POST -d "$json_payload" "$WEBHOOK_URL" \
                       --connect-timeout 10 --max-time 20 \
                       -A "DeviceInfoScript/1.0" \
                       2> "$curl_error_log")
        curl_exit_code=$?
        # Read stderr only if the temp file exists (it might not if curl didn't produce stderr)
        [ -f "$curl_error_log" ] && curl_error_msg=$(<"$curl_error_log")
        rm -f "$curl_error_log" # Clean up

        # Check for success (curl exit code 0 AND http status 200)
        if [ $curl_exit_code -eq 0 ] && [ "$http_code" -eq 200 ]; then
            green "企业微信通知发送成功 (HTTP $http_code)。"
            log_info "企业微信通知发送成功。"
            return 0 # Success
        else
            # Failure path: increment retry, log error, sleep
            retries=$((retries + 1))
            error_reason="未知错误" # Default reason
            if [ $curl_exit_code -ne 0 ]; then
                 # Provide more context based on common curl exit codes
                 case $curl_exit_code in
                     6) error_reason="无法解析主机 (DNS 问题?)";;
                     7) error_reason="无法连接到主机";;
                     22) error_reason="HTTP 错误 >= 400 (HTTP $http_code)";; # Handled by --fail
                     28) error_reason="操作超时";;
                     *) error_reason="curl 命令失败 (Exit Code: $curl_exit_code)";;
                 esac
                 # Append stderr if available
                 [ -n "$curl_error_msg" ] && error_reason="$error_reason - $curl_error_msg"
            elif [ "$http_code" -ne 200 ]; then
                 error_reason="服务器返回非 200 状态码 (HTTP $http_code)"
            fi

            red "企业微信通知发送失败 ($error_reason)，将在 $RETRY_INTERVAL 秒后重试...（第 $retries/$MAX_RETRIES 次）"
            log_error "企业微信通知发送失败 ($error_reason)，重试...（$retries 次）"
            sleep $RETRY_INTERVAL
        fi
    done

    red "企业微信通知发送失败次数达到上限（$MAX_RETRIES 次）。"
    log_error "企业微信通知发送失败次数达到上限（$MAX_RETRIES 次）。"
    return 1 # Failure after retries
}


### 设置自启动 (增强 Systemd 配置, 增加启动延迟) ###
setup_autostart() {
    log_info "检查并设置自启动..."

    # Prefer systemd if available
    if command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then
        local service_name="device_info_notify.service"
        local service_file="/etc/systemd/system/$service_name"
        local need_reload=false
        local need_update=false
        # Get the absolute path for ExecStart
        local full_script_path
        if ! full_script_path=$(realpath "$SCRIPT_PATH"); then
             log_error "无法解析脚本的绝对路径: $SCRIPT_PATH"
             red "错误: 无法解析脚本路径 '$SCRIPT_PATH'"
             return 1
        fi
        local working_dir
        working_dir=$(dirname "$full_script_path")

        # Define the expected content using a heredoc for readability
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

[Install]
WantedBy=multi-user.target
EOF

        # Check if service file exists and if content matches
        if [ ! -f "$service_file" ] || ! cmp -s <(echo "$expected_service_content") "$service_file"; then
            log_info "创建或更新 systemd 服务文件: $service_file"
            yellow "检测到 systemd 服务文件需要创建或更新..."
            need_update=true
        fi

        # Update the service file if needed
        if [ "$need_update" = true ]; then
            # Use sudo tee to write the file
            if ! echo "$expected_service_content" | sudo tee "$service_file" > /dev/null; then
                log_error "创建/更新 systemd 服务文件失败: $service_file"
                red "错误：创建/更新 systemd 服务文件失败。"
                return 1 # Cannot proceed if file creation fails
            fi
            log_info "已成功创建/更新 systemd 服务文件: $service_file"
            need_reload=true # File changed, need daemon-reload
        fi

        # Check if the service is enabled, enable if not
        if ! sudo systemctl is-enabled "$service_name" >/dev/null 2>&1; then
            log_info "启用 systemd 服务: $service_name"
            yellow "正在启用 systemd 服务..."
            if ! sudo systemctl enable "$service_name"; then
                log_error "启用 systemd 服务失败: $service_name"
                red "错误：启用 systemd 服务失败。"
                # Don't necessarily return 1 here, maybe reload is still needed
            else
                log_info "已成功启用 systemd 服务: $service_name"
                need_reload=true # Status changed, reload recommended
            fi
        fi

        # Reload systemd daemon if changes were made
        if [ "$need_reload" = true ]; then
            log_info "重新加载 systemd 配置..."
            if ! sudo systemctl daemon-reload; then
                log_error "重新加载 systemd 配置失败。"
                red "警告：重新加载 systemd 配置失败。"
                # Log warning but don't return error
            else
                log_info "Systemd 配置已重新加载。"
            fi
        fi

        green "Systemd 自启动设置检查/配置完成。"
        log_info "Systemd 自启动设置检查/配置完成。"
        return 0 # Systemd setup successful or already correct

    # Fallback to rc.local
    elif [ -f "/etc/rc.local" ]; then
        log_info "检测到 /etc/rc.local，将尝试使用它设置自启动。"
        # Ensure script path is correctly added (run in background)
        local rc_command="$SCRIPT_PATH &"
        # Use grep -F to match fixed string, avoids regex issues with path chars
        if ! grep -qF "$SCRIPT_PATH" /etc/rc.local; then
            log_info "尝试将脚本添加到 /etc/rc.local..."
            yellow "正在尝试配置 rc.local 自启动..."
            # Ensure rc.local is executable
            if [ ! -x "/etc/rc.local" ]; then
                if ! sudo chmod +x /etc/rc.local; then
                     log_error "无法使 /etc/rc.local 可执行。"
                     red "错误: 无法设置 /etc/rc.local 执行权限。"
                     return 1
                fi
                log_info "/etc/rc.local 文件已设置为可执行。"
            fi
            # Insert before 'exit 0' if it exists, otherwise append
            if grep -q '^\s*exit\s\+0' /etc/rc.local; then
                # Insert before the line containing 'exit 0'
                if ! sudo sed -i "/^\s*exit\s\+0/i $rc_command" /etc/rc.local; then
                     log_error "使用 sed 向 /etc/rc.local 添加命令失败。"
                     red "错误: 添加命令到 /etc/rc.local 失败 (sed)。"
                     return 1
                fi
            else
                # Append to the end of the file
                if ! echo "$rc_command" | sudo tee -a /etc/rc.local > /dev/null; then
                     log_error "使用 tee 向 /etc/rc.local 追加命令失败。"
                     red "错误: 添加命令到 /etc/rc.local 失败 (tee)。"
                     return 1
                fi
            fi
            # Verify addition
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
        return 0 # rc.local setup successful or already correct
    else
        # No known autostart method found
        log_error "未找到 systemd 或 /etc/rc.local，无法自动设置自启动。"
        red "错误：未找到 systemd 或 /etc/rc.local，请手动配置自启动。"
        return 1 # Autostart setup failed
    fi
}

### 主函数 (完整) ###
main() {
    # Check if running as root, warn if not and sudo is missing
    if [ "$(id -u)" -ne 0 ]; then
        if ! command -v sudo >/dev/null 2>&1; then
            red "警告: 当前用户非 root，且 sudo 命令不可用。依赖安装和自启动设置可能失败。"
            log_error "非 root 用户运行，且 sudo 不可用。"
            # Continue execution, but some functions might fail later
        else
            yellow "提示: 脚本的部分操作 (如安装依赖、设置自启动) 可能需要 sudo 权限。"
        fi
    fi

    log_info "--- 脚本开始执行 (PID: $$) ---"
    blue "--- 设备信息通知脚本 (V3.1 - Whitespace Cleaned) ---"

    # Load config first, as wait_for_network needs WEBHOOK_URL
    if ! load_config; then
        log_error "配置加载/设置失败，退出。"
        exit 1
    fi

    # Check dependencies
    if ! check_dependencies; then
        log_error "依赖检查或安装失败，退出。"
        exit 1
    fi

    # Wait for network connectivity (includes specific webhook check)
    if ! wait_for_network; then
        log_error "网络未就绪，无法发送通知。退出。"
        red "网络连接失败，脚本退出。"
        exit 1
    fi

    # Attempt to send notification (no internal status check anymore)
    send_wechat_notification
    local send_status=$? # Capture the exit status

    # Log system info snapshot regardless of notification status
    log_info "开始收集并记录系统信息快照..."
    local current_info
    current_info=$(get_system_info) # Capture output
    if [ -n "$current_info" ]; then
        log_info "-- SysInfo Snapshot Start --"
        # Use printf to log, avoids issues with echo potentially interpreting backslashes
        printf "%s\n" "$current_info" >> "$LOG_FILE" 2>/dev/null || log_error "写入 SysInfo 快照到日志失败。"
        log_info "-- SysInfo Snapshot End --"
        # Display info to console as well
        echo # Blank line
        blue "--- 当前系统信息 ---"
        echo "$current_info"
        echo # Blank line
    else
        log_error "获取系统信息失败，无法记录快照。"
    fi

    # Ensure autostart mechanism is properly configured
    if ! setup_autostart; then
         log_error "设置自启动时遇到错误。"
         # Continue script execution, but warn user
         red "警告: 设置自启动失败，脚本可能不会在重启后自动运行。"
    fi

    # Final status message based on notification attempt
    if [ $send_status -eq 0 ]; then
        green "脚本执行完成 (通知尝试成功或因未配置而跳过)。"
    else
        yellow "脚本执行完成，但通知发送失败 (详见日志: $LOG_FILE)。"
    fi
    log_info "--- 脚本执行完毕 (通知发送状态: $send_status) ---"
    echo # Blank line for clarity

    # Exit with the status of the notification attempt
    exit $send_status
}

# --- Script Entry Point ---
# Execute the main function
main
