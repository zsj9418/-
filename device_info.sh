#!/bin/bash

### 配置常量 ###
LOG_FILE="/var/log/device_info.log"  # 日志文件路径
WEBHOOK_URL=""                      # 企业微信机器人 Webhook URL
DEPENDENCIES="curl jq ethtool ip"  # 依赖列表
CONFIG_FILE="/etc/device_info.conf" # 配置文件路径
STATUS_FILE="/tmp/device_notify_status" # 通知状态文件路径
MAX_LOG_SIZE=2097152                # 最大日志文件大小 (2 MB)
SCRIPT_PATH="$(realpath "$0")"      # 当前脚本路径
PING_TARGET="223.5.5.5"             # 网络检测目标
MAX_RETRIES=10                      # 最大重试次数
RETRY_INTERVAL=5                    # 重试间隔时间（秒）
STABILIZATION_WAIT=20               # 重启后稳定等待时间（秒）

### 彩色输出函数 ###
red() { echo -e "\033[31m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }
green() { echo -e "\033[32m$*\033[0m"; }
blue() { echo -e "\033[34m$*\033[0m"; } # 新增蓝色输出，用于调试信息

### 日志记录函数 (增强，增加写入错误检查) ###
log_info() {
    if [ ! -d "$(dirname "$LOG_FILE")" ]; then
        mkdir -p "$(dirname "$LOG_FILE")"
    fi

    if [ -f "$LOG_FILE" ] && [ $(stat -c%s "$LOG_FILE") -ge $MAX_LOG_SIZE ]; then
        mv "$LOG_FILE" "${LOG_FILE}.bak"
        if ! echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] 日志文件已轮转为 ${LOG_FILE}.bak" >> "$LOG_FILE"; then
            echo "ERROR: 日志轮转信息写入失败 (磁盘空间不足?)" >&2 # 输出到 stderr
        fi
    fi

    if ! echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $@" >> "$LOG_FILE"; then
        echo "ERROR: 日志信息写入失败 (磁盘空间不足?): $@" >&2 # 输出到 stderr
    fi
}

log_error() {
    if [ ! -d "$(dirname "$LOG_FILE")" ]; then
        mkdir -p "$(dirname "$LOG_FILE")"
    fi
    if ! echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $@" >> "$LOG_FILE"; then
        echo "ERROR: 错误日志写入失败 (磁盘空间不足?): $@" >&2 # 输出到 stderr
    fi
    red "$@" # 错误信息同时输出到终端
}

log_debug() {
    if [ ! -d "$(dirname "$LOG_FILE")" ]; then
        mkdir -p "$(dirname "$LOG_FILE")"
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') [DEBUG] $@" >> "$LOG_FILE"
}


### 检查依赖并补全 ###
check_dependencies() {
    log_info "开始检查依赖..."
    local missing_deps=""
    for dep in $DEPENDENCIES; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing_deps="$missing_deps $dep"
        fi
    done

    if [ -n "$missing_deps" ];then
        log_info "缺少以下依赖：$missing_deps"
        log_info "正在安装依赖..."
        if command -v apt >/dev/null 2>&1; then
            sudo apt update && sudo apt install -y $missing_deps
        elif command -v yum >/dev/null 2>&1; then
            sudo yum install -y $missing_deps
        elif command -v apk >/dev/null 2>&1; then
            sudo apk add --no-cache $missing_deps
        elif command -v opkg >/dev/null 2>&1; then
            sudo opkg update && sudo opkg install $missing_deps
        else
            log_error "无法自动安装依赖，请手动安装以下工具：$missing_deps"
            exit 1
        fi
    else
        green "所有依赖已满足。"
        log_info "所有依赖已满足。"
    fi
}

### 保存用户配置 ###
save_config() {
    echo "WEBHOOK_URL=\"$WEBHOOK_URL\"" > "$CONFIG_FILE"
    log_info "已保存配置到 $CONFIG_FILE"
}

### 加载用户配置 ###
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        . "$CONFIG_FILE"
        log_info "已加载配置文件 $CONFIG_FILE"
    else
        log_info "未检测到配置文件，首次运行需要配置。"
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
        log_info "企业微信机器人已启用。"
    else
        echo "企业微信机器人通知已跳过。"
        log_info "企业微信机器人通知已跳过。"
    fi
    save_config
}

### 获取系统详细信息并格式化 ###
get_system_info() {
    local runtime=$(uptime -p | sed 's/up //')
    runtime=$(echo "$runtime" | sed 's/hours/小时/g; s/hour/小时/g; s/minutes/分钟/g; s/minute/分钟/g; s/,/，/g; s/,//g')

    local lan_ips_formatted
    lan_ips_formatted=$(get_lan_ip)
    if [ -z "$lan_ips_formatted" ]; then
        lan_ips_formatted="未获取到局域网 IP 地址"
    fi

    cat <<EOF
主机名: $(hostname)
系统版本: $(grep -oP '(?<=PRETTY_NAME=").*(?=")' /etc/os-release || echo '未知')
Linux版本: $(uname -r)
CPU架构: $(uname -m)
CPU型号: $(grep -m 1 'model name' /proc/cpuinfo | cut -d ':' -f2 | xargs || echo '未知')
CPU核心数: $(nproc)
CPU频率: $(lscpu | grep -oP '(?<=CPU MHz:).*' | xargs || echo '未知')
局域网 IP:
$lan_ips_formatted
CPU占用: $(top -bn1 | grep "Cpu(s)" | sed "s/.* \([0-9.]*\)% id.*/\1/" | awk '{print 100 - $1"%"}' || echo '未知')
系统负载: $(uptime | awk -F'load average:' '{print $2}' | xargs || echo '未知')
物理内存: $(free -m | awk 'NR==2{printf "%.2f/%.2fM (%.2f%%)", $3, $2, $3*100/$2}' || echo '未知')
虚拟内存: $(free -m | awk 'NR==3{printf "%.2f/%.2fM (%.2f%%)", $3, $2, $3*100/$2}' || echo '未知')
硬盘占用: $(df -h / | awk 'NR==2{print $3"/"$2 " ("$5")"}' || echo '未知')
总接收: $(awk 'BEGIN {rx_total=0} $1 ~ /^(eth|enp|eno)/ {rx_total += $2} END {printf "%.2f MB", rx_total/1024/1024}' /proc/net/dev || echo '未知')
总发送: $(awk 'BEGIN {tx_total=0} $1 ~ /^(eth|enp|eno)/ {tx_total += $10} END {printf "%.2f MB", tx_total/1024/1024}' /proc/net/dev || echo '未知')
网络算法: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '未知')
运营商: $(get_public_info org)
IPv4地址: $(get_public_info ip)
地理位置: $(get_public_info location)
系统时间: $(date '+%Z %Y-%m-%d %I:%M %p')
运行时长: $runtime
EOF
}

### 获取局域网 IPv4 地址 (改进版) ###
get_lan_ip() {
    local ip_addresses=""
    local interfaces=$(ip link show | awk '{print $2}' | tr -d ':' | grep -vE '^(lo|docker|veth|tun|br-)')

    if [ -z "$interfaces" ]; then
        log_info "未找到任何物理网络接口。"
        echo "未找到局域网 IP 地址。"
        return 1
    fi

    for interface in $interfaces; do
        local ip_info=$(ip -4 addr show "$interface" 2>/dev/null | awk '/inet / {print $2}')
        if [ -n "$ip_info" ]; then
            local ip=$(echo "$ip_info" | cut -d '/' -f 1)
            if [ -n "$ip" ]; then
                if ! echo "$ip" | grep -q "^127\.0\.0\.1$"; then
                    local interface_type=$(get_interface_type "$interface")
                    ip_addresses="${ip_addresses}${interface_type} (${interface}): ${ip}\n"
                    log_debug "获取到 IP: $interface_type ($interface): $ip"
                else
                    log_debug "排除回环地址: $ip on interface $interface"
                fi
            fi
        fi
    done

    if [ -z "$ip_addresses" ]; then
        log_info "遍历所有接口后仍未找到局域网 IP 地址。"
        echo "未找到局域网 IP 地址。"
        return 1
    else
        echo -e "$ip_addresses"
        log_debug "最终获取到的局域网 IP 地址:\n$ip_addresses"
        return 0
    fi
}

### 获取接口类型 (有线/无线) ###
get_interface_type() {
    local interface=$1
    if command -v ethtool >/dev/null 2>&1; then
        local link_status=$(sudo ethtool "$interface" 2>/dev/null | grep "Link detected" | awk '{print $3}')
        if [ -n "$link_status" ] && [ "$link_status" = "yes" ]; then
            echo "有线"
        else
           if command -v iwconfig >/dev/null 2>&1 && iwconfig "$interface" 2>&1 | grep -q "ESSID:"; then
               echo "无线"
           else
               echo "未知类型"
           fi
        fi
    elif command -v iwconfig >/dev/null 2>&1 && iwconfig "$interface" 2>&1 | grep -q "ESSID:"; then
        echo "无线"
    else
        echo "未知类型"
    fi
}

### 获取公网信息（通过 ipinfo.io，优化版） ###
get_public_info() {
    local field=$1
    local result
    local ipinfo_data=$(curl -s ipinfo.io) # 一次请求获取所有数据

    if [ -n "$ipinfo_data" ]; then # 检查是否成功获取数据
        if echo "$ipinfo_data" | jq -e '.'; then # 检查是否是有效的 JSON (防止 curl 错误信息)
            case "$field" in
                "org") result=$(echo "$ipinfo_data" | jq -r '.org' 2>/dev/null || echo "未知运营商") ;;
                "ip") result=$(echo "$ipinfo_data" | jq -r '.ip' 2>/dev/null || echo "未知 IPv4 地址") ;;
                "location") result="$(echo "$ipinfo_data" | jq -r '.city' 2>/dev/null || echo "未知城市"), $(echo "$ipinfo_data" | jq -r '.country' 2>/dev/null || echo "未知国家")" ;;
                *) result="未知信息" ;;
            esac
        else
            log_error "获取公网信息失败 (ipinfo.io 返回非 JSON 数据): $ipinfo_data"
            result="未知信息"
        fi
    else
        log_error "获取公网信息失败 (无法连接 ipinfo.io)"
        result="未知信息"
    fi
    echo "$result"
}


### 发送企业微信通知 ###
send_wechat_notification() {
    if [ -z "$WEBHOOK_URL" ]; then
        yellow "未配置企业微信 Webhook，跳过通知"
        log_info "未配置企业微信 Webhook，跳过通知"
        return
    fi

    if [ -f "$STATUS_FILE" ] && grep -q "success" "$STATUS_FILE"; then
        green "通知已成功发送，无需重复发送。"
        log_info "通知已成功发送，无需重复发送。"
        return 0
    fi

    local system_info=$(get_system_info)
    local retries=0

    while [ $retries -lt $MAX_RETRIES ]; do
        curl -sSf -H "Content-Type: application/json" \
            -d "{\"msgtype\":\"text\":\"text\", \"text\":{\"content\":\"[设备: $(hostname)] 系统信息:\\n$system_info\"}}" \
            "$WEBHOOK_URL" >/dev/null
        if [ $? -eq 0 ]; then
            green "通知发送成功。"
            log_info "通知发送成功。"
            echo "success" > "$STATUS_FILE"
            return 0
        else
            red "通知发送失败，重试中...（第 $((retries + 1)) 次）"
            log_error "通知发送失败，重试中...（第 $((retries + 1)) 次）"
            retries=$((retries + 1))
            sleep $RETRY_INTERVAL
        fi
    done

    red "通知发送失败次数已达上限（$MAX_RETRIES 次）。"
    log_error "通知发送失败次数已达上限（$MAX_RETRIES 次）。"
    return 1
}

### 设置自启动 ###
setup_autostart() {
    if command -v systemctl >/dev/null 2>&1; then
        local service_file="/etc/systemd/system/device_info.service"
        echo "[Unit]
Description=Device Info Logger

[Service]
Type=simple
ExecStart=$SCRIPT_PATH
Restart=always
Restart=on-failure # 建议添加 restart policy

[Install]
WantedBy=multi-user.target" | sudo tee "$service_file" > /dev/null
        sudo systemctl enable device_info.service
        log_info "已设置 systemd 自启动服务"
    elif [ -f "/etc/rc.local" ]; then
        if ! grep -q "$SCRIPT_PATH" /etc/rc.local; then
            sudo sed -i -e "\$i $SCRIPT_PATH &\n" /etc/rc.local
            log_info "已设置 rc.local 自启动"
        fi
    else
        red "无法设置自启动，系统不支持 systemd 且没有 rc.local 文件。"
        log_error "无法设置自启动，系统不支持 systemd 且没有 rc.local 文件。"
    fi
}

### 主函数 ###
main() {
    load_config
    check_dependencies
    sleep $STABILIZATION_WAIT
    send_wechat_notification
    log_info "开始收集系统信息并记录日志..."
    log_info "$(get_system_info)"
    setup_autostart
    green "脚本执行完成。"
    log_info "脚本执行完成。"
}

main
