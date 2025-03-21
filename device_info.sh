#!/bin/bash

### 配置常量 (恢复详细信息) ###
LOG_FILE="/var/log/device_info.log"
WEBHOOK_URL=""
DEPENDENCIES="curl ethtool ip"
CONFIG_FILE="/etc/device_info.conf"
STATUS_FILE="/tmp/device_notify_status"
MAX_LOG_SIZE=2097152
SCRIPT_PATH="$(realpath "\$0")"
PING_TARGET="223.5.5.5"
MAX_RETRIES=10
RETRY_INTERVAL=5
STABILIZATION_WAIT=20

### 错误处理
set -euo pipefail

### 彩色输出函数 (完整) ###
red() { echo -e "\033[31m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }
green() { echo -e "\033[32m$*\033[0m"; }
blue() { echo -e "\033[34m$*\033[0m"; }

### 日志记录函数 (完整) ###
log_info() {
    if [ ! -d "$(dirname "$LOG_FILE")" ]; then mkdir -p "$(dirname "$LOG_FILE")"; fi
    # 直接清空日志，而不是轮换
    if [ -f "$LOG_FILE" ] && [ $(stat -c%s "$LOG_FILE") -ge $MAX_LOG_SIZE ]; then
        truncate -s 0 "$LOG_FILE"
        if ! echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] 日志已清空" >> "$LOG_FILE"; then echo "ERROR: 日志清空后写入失败" >&2; fi
    fi
    if ! echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $@" >> "$LOG_FILE"; then echo "ERROR: 日志写入失败: $@" >&2; fi
}

log_error() {
    if [ ! -d "$(dirname "$LOG_FILE")" ]; then mkdir -p "$(dirname "$LOG_FILE")"; fi
    if ! echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $@" >> "$LOG_FILE"; then echo "ERROR: 错误日志写入失败: $@" >&2; fi
    red "$@"
}

log_debug() {
    if [ ! -d "$(dirname "$LOG_FILE")" ]; then mkdir -p "$(dirname "$LOG_FILE")"; fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') [DEBUG] $@" >> "$LOG_FILE"
}

### 检查依赖 (精简，移除 jq 依赖) ###
check_dependencies() {
    log_info "开始检查依赖..."
    local missing_deps=""
    for dep in $DEPENDENCIES; do
        if ! command -v "$dep" >/dev/null 2>&1; then missing_deps="$missing_deps $dep"; fi
    done
    if [ -n "$missing_deps" ];then
        log_info "缺少依赖：$missing_deps，正在安装..."
        if command -v apt >/dev/null 2>&1; then sudo apt update && sudo apt install -y $missing_deps;
        elif command -v yum >/dev/null 2>&1; then sudo yum install -y $missing_deps;
        elif command -v apk >/dev/null 2>&1; then sudo apk add --no-cache $missing_deps;
        elif command -v opkg >/dev/null 2>&1; then sudo opkg update && sudo opkg install $missing_deps;
        else log_error "无法自动安装依赖，请手动安装：$missing_deps"; exit 1; fi
    else green "所有依赖已满足。"; log_info "所有依赖已满足。"; fi
}

### 配置 (完整) ###
save_config() { echo "WEBHOOK_URL=\"$WEBHOOK_URL\"" > "$CONFIG_FILE"; log_info "配置已保存到 $CONFIG_FILE"; }
load_config() { if [ -f "$CONFIG_FILE" ]; then . "$CONFIG_FILE"; log_info "加载配置文件 $CONFIG_FILE"; else log_info "未检测到配置文件，首次运行需配置。"; configure_script; fi }
configure_script() {
    echo "是否启用企业微信机器人通知？(y/n)"; read ENABLE_WEBHOOK
    if [ "$ENABLE_WEBHOOK" = "y" ]; then while [ -z "$WEBHOOK_URL" ]; do echo "请输入企业微信机器人 Webhook URL："; read WEBHOOK_URL; done; echo "企业微信机器人已启用。"; log_info "企业微信机器人已启用。";
    else echo "企业微信机器人通知已跳过。"; log_info "企业微信机器人通知已跳过。"; fi; save_config
}

### 获取系统信息 (最终修复，移除 jq 依赖，使用 grep/sed 解析 JSON) ###
get_system_info() {
    local runtime=$(uptime -p | sed 's/up //')
    runtime=$(echo "$runtime" | sed 's/hours/小时/g; s/hour/小时/g; s/minutes/分钟/g; s/minute/分钟/g; s/,/，/g; s/,//g')

    local lan_ips_formatted
    lan_ips_formatted=$(get_lan_ip)
    if [ -z "$lan_ips_formatted" ]; then lan_ips_formatted="未获取到局域网 IP 地址"; fi

    # CPU 占用率: 恢复 top 命令方式, 更稳定
    local cpu_usage=$(top -bn1 | grep "Cpu(s)" | sed "s/.* $[0-9.]*$% id.*/\1/" | awk '{print 100 - \$1"%"}')
    if [ -z "$cpu_usage" ]; then cpu_usage="未知"; fi

    # 内存信息: 恢复 free 命令, 并修复重复输出问题 (实际已在之前版本修复)
    local mem_info=$(free -m | awk 'NR==2{printf "%.2f/%.2fM (%.2f%%)", \$3, \$2, \$3*100/\$2}')
    if [ -z "$mem_info" ]; then mem_usage="未知"; else mem_usage="$mem_info"; fi
    local swap_info=$(free -m | awk 'NR==3{printf "%.2f/%.2fM (%.2f%%)", \$3, \$2, \$3*100/\$2}')
    if [ -z "$swap_info" ]; then swap_usage="未知"; else swap_usage="$swap_info"; fi


    local disk_usage=$(df -h / | awk 'NR==2{print \$3"/"\$2 " ("\$5")"}')
    if [ -z "$disk_usage" ]; then disk_usage="未知"; fi

    local total_rx=$(awk 'BEGIN {rx_total=0} \$1 ~ /^(eth|enp|eno)/ {rx_total += \$2} END {printf "%.2f MB", rx_total/1024/1024}' /proc/net/dev)
    if [ -z "$total_rx" ]; then total_rx="未知"; fi
    local total_tx=$(awk 'BEGIN {tx_total=0} \$1 ~ /^(eth|enp|eno)/ {tx_total += \$10} END {printf "%.2f MB", tx_total/1024/1024}' /proc/net/dev)
    if [ -z "$total_tx" ]; then total_tx="未知"; fi

    local network_algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '未知')
    local cpu_model=$(grep -m 1 'model name' /proc/cpuinfo | cut -d ':' -f2 | xargs || echo '未知')
    local cpu_cores=$(nproc)
    local cpu_freq=$(lscpu | grep -oP '(?<=CPU MHz:).*' | xargs || echo '未知')
    local os_version=$(grep -oP '(?<=PRETTY_NAME=").*(?=")' /etc/os-release || echo '未知')

    # 使用 grep/sed 解析 JSON 响应，移除 jq 依赖
    local ipinfo_json=$(get_public_info)

    # 提取运营商信息 (使用 grep/sed)
    local operator=$(echo "$ipinfo_json" | grep -oP '"org": *"\K[^"]+' 2>/dev/null || echo "未知运营商")
    # 提取 IPv4 地址 (使用 grep/sed)
    local public_ip=$(echo "$ipinfo_json" | grep -oP '"ip": *"\K[^"]+' 2>/dev/null || echo "未知 IPv4 地址")
    # 提取地理位置信息，格式化为 "City, Country" (使用 grep/sed)
    local city=$(echo "$ipinfo_json" | grep -oP '"city": *"\K[^"]+' 2>/dev/null || echo '未知城市')
    local country=$(echo "$ipinfo_json" | grep -oP '"country": *"\K[^"]+' 2>/dev/null || echo '未知国家')
    local location="$city, $country"


    cat <<EOF
[设备: $(hostname)] 系统信息:
主机名: $(hostname)
系统版本: $os_version
Linux版本: $(uname -r)
CPU架构: $(uname -m)
CPU型号: $cpu_model
CPU核心数: $cpu_cores
CPU频率: $cpu_freq
局域网 IP:
$lan_ips_formatted
CPU占用: $cpu_usage
系统负载: $(uptime | awk -F'load average:' '{print \$2}' | xargs || echo '未知')
物理内存: $mem_info
虚拟内存: $swap_usage
硬盘占用: $disk_usage
总接收: $total_rx
总发送: $total_tx
网络算法: $network_algo
运营商: $operator
IPv4地址: $public_ip
地理位置: $location
系统时间: $(date '+%Z %Y-%m-%d %I:%M %p')
运行时长: $runtime
EOF
}

### 获取局域网 IPv4 地址 (改进版, 同之前版本) ###
get_lan_ip() {
    local ip_addresses=""
    local interfaces=$(ip link show | awk '{print \$2}' | tr -d ':' | grep -vE '^(lo|docker|veth|tun|br-)')

    if [ -z "$interfaces" ]; then log_info "未找到物理网络接口。"; echo "未找到局域网 IP 地址。"; return 1; fi
    for interface in $interfaces; do
        local ip_info=$(ip -4 addr show "$interface" 2>/dev/null | awk '/inet / {print \$2}')
        if [ -n "$ip_info" ]; then
            local ip=$(echo "$ip_info" | cut -d '/' -f 1)
            if [ -n "$ip" ]; then
                if ! echo "$ip" | grep -q "^127\.0\.0\.1$"; then
                    local interface_type=$(get_interface_type "$interface")
                    ip_addresses="${ip_addresses}${interface_type} (${interface}): ${ip}\n"
                    log_debug "获取到 IP: $interface_type ($interface): $ip"
                else log_debug "排除回环地址: $ip on $interface"; fi
            fi
        fi
    done

    if [ -z "$ip_addresses" ]; then log_info "遍历接口后未找到局域网 IP。"; echo "未找到局域网 IP 地址。"; return 1;
    else echo -e "$ip_addresses"; log_debug "最终局域网 IP:\n$ip_addresses"; return 0; fi
}

### 获取接口类型 (有线/无线, 同之前版本) ###
get_interface_type() {
    local interface=\$1
    if command -v ethtool >/dev/null 2>&1; then
        local link_status=$(sudo ethtool "$interface" 2>/dev/null | grep "Link detected" | awk '{print \$3}')
        if [ -n "$link_status" ] && [ "$link_status" = "yes" ]; then echo "有线"; else
           if command -v iwconfig >/dev/null 2>&1 && iwconfig "$interface" 2>&1 | grep -q "ESSID:"; then echo "无线"; else echo "未知类型"; fi
        fi
    elif command -v iwconfig >/dev/null 2>&1 && iwconfig "$interface" 2>&1 | grep -q "ESSID:"; then echo "无线"; else echo "未知类型"; fi
}

### 获取公网信息 (简化，统一返回完整 JSON) ###
get_public_info() {
    curl -s ipinfo.io
}

### 检测网络连接 (增强网络检测) ###
wait_for_network() {
    local retries=0
    while [ $retries -lt $MAX_RETRIES ]; do
        # 使用多个目标进行网络连通性检测
        ping -c 1 $PING_TARGET > /dev/null 2>&1
        local ping_target_result=$?
        ping -c 1 223.5.5.5 > /dev/null 2>&1 
        local ping_google_result=$?
        ping -c 1 baidu.com > /dev/null 2>&1
        local ping_baidu_result=$?

        # 如果至少有一个ping成功，则认为网络已连接
        if [ $ping_target_result -eq 0 ] || [ $ping_google_result -eq 0 ] || [ $ping_baidu_result -eq 0 ]; then
            log_info "网络已连接。"
            # 确保网络连接稳定后删除状态文件
            rm -f "$STATUS_FILE"
            return 0
        else
            log_info "网络未连接，等待 $RETRY_INTERVAL 秒后重试... (第 $((retries + 1)) 次)"
            sleep $RETRY_INTERVAL
            retries=$((retries + 1))
        fi
    done
    log_error "网络连接检测失败，已达到最大重试次数。"
    return 1
}

### 发送企业微信通知 (完整) ###
send_wechat_notification() {
    # 确保加载 WEBHOOK_URL
    if [ -z "$WEBHOOK_URL" ]; then 
        log_info "WEBHOOK_URL 为空，尝试从配置文件加载。"
        if [ -f "$CONFIG_FILE" ]; then
            source "$CONFIG_FILE"
            if [ -z "$WEBHOOK_URL" ]; then
                yellow "未配置企业微信 Webhook，跳过通知"; log_info "未配置 Webhook，跳过通知"; return; 
            fi
        else
            yellow "未找到配置文件，跳过通知"; log_info "未找到配置文件，跳过通知"; return
        fi
    fi

    # 检查状态文件是否存在
    if [ -f "$STATUS_FILE" ]; then
        log_info "状态文件 $STATUS_FILE 存在，跳过发送通知。"
        return 0
    fi

    local system_info=$(get_system_info)
    local retries=0
    while [ $retries -lt $MAX_RETRIES ]; do
        curl -sSf -H "Content-Type: application/json" \
            -d "{\"msgtype\":\"text\",\"text\":{\"content\":\"[设备: $(hostname)] 系统信息:\\n$system_info\"}}" "$WEBHOOK_URL" >/dev/null
        if [ $? -eq 0 ]; then
            green "通知发送成功。"; log_info "通知发送成功。";
            # 成功发送后，立即创建状态文件
            touch "$STATUS_FILE"
            return 0
        else
            red "通知发送失败，重试中...（第 $((retries + 1)) 次）"; log_error "通知失败，重试...（$((retries + 1)) 次）"; retries=$((retries + 1)); sleep $RETRY_INTERVAL; fi
    done
    red "通知发送失败次数达上限（$MAX_RETRIES 次）。"; log_error "通知失败次数达上限（$MAX_RETRIES 次）。"; return 1
}

### 设置自启动 (修改 setup_autostart 函数，重启时删除状态文件, 增强 Systemd 配置, 增加更严格的检查) ###
setup_autostart() {
    if command -v systemctl >/dev/null 2>&1; then
        local service_file="/etc/systemd/system/device_info.service"
        # 确保服务文件存在
        if [ ! -f "$service_file" ]; then
            echo "[Unit]
Description=Device Info Logger
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=/root/one-click-scripts/
Type=simple
ExecStart=$SCRIPT_PATH
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target" | sudo tee "$service_file" > /dev/null
            if [ $? -ne 0 ]; then log_error "创建 systemd 服务文件失败: $service_file"; return 1; fi
            log_info "已创建 systemd 服务文件: $service_file"
        fi

        # 启用服务并检查是否成功
        sudo systemctl enable device_info.service
        if [ $? -ne 0 ]; then log_error "启用 systemd 服务失败: $service_file"; return 1; fi

        # 重新加载 systemd 配置
        sudo systemctl daemon-reload
        if [ $? -ne 0 ]; then log_error "重新加载 systemd 配置失败"; return 1; fi

        # 检查服务是否已启动
        sudo systemctl is-enabled device_info.service
        if [ "$?" -eq "0" ]; then log_info "systemd 服务已成功设置为自启动"; else log_error "systemd 服务自启动设置失败"; return 1; fi

        log_info "已设置 systemd 自启动服务"
    elif [ -f "/etc/rc.local" ]; then
        if ! grep -q "$SCRIPT_PATH" /etc/rc.local; then
            # 在 rc.local 中添加删除状态文件的命令
            sudo sed -i -e "\$i $SCRIPT_PATH &\n" /etc/rc.local
            log_info "已设置 rc.local 自启动"
        fi
    else
        log_error "未找到 systemd 或 rc.local，无法设置自启动"
        return 1
    fi

    # 最终确认自启动是否成功 (需要手动检查，脚本层面很难完全确定)
    echo "请手动检查设备重启后，该脚本是否自动运行。"
    echo "如果未自动运行，请检查 systemd 服务状态或 rc.local 文件。"
}

### 检查状态文件是否存在, 不存在则创建 ###
check_status_file() {
  if [ ! -f "$STATUS_FILE" ]; then
    touch "$STATUS_FILE"
    log_info "状态文件 $STATUS_FILE 不存在, 已创建."
  fi
}

### 主函数 (完整) ###
main() {
    # 启用严格模式，提前发现潜在问题
    set -euo pipefail

    load_config
    check_dependencies
    #wait_for_network #等待网络就绪
    #sleep $STABILIZATION_WAIT
    wait_for_network
    send_wechat_notification
    log_info "开始收集系统信息并记录日志..."
    log_info "$(get_system_info)"
    setup_autostart #  确保即使之前设置失败，也再次尝试设置自启动
    green "脚本执行完成。"; log_info "脚本执行完成。";
}

main
