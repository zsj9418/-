#!/bin/bash

### 配置常量 ###
LOG_FILE="/var/log/device_info.log"  # 日志文件路径
WEBHOOK_URL=""                      # 企业微信机器人 Webhook URL
DEPENDENCIES="curl jq ethtool ip"  # 修改：依赖列表只包含 ip, 不再有 iproute2
CONFIG_FILE="/etc/device_info.conf" # 配置文件路径
STATUS_FILE="/tmp/device_notify_status" # 通知状态文件路径
MAX_LOG_SIZE=2097152                # 最大日志文件大小 (2 MB)
SCRIPT_PATH="$(realpath "$0")"      # 当前脚本路径
PING_TARGET="223.5.5.5"             # 网络检测目标，用于判断网络连通性
MAX_RETRIES=10                      # 最大重试次数
RETRY_INTERVAL=5                    # 重试间隔时间（秒）
STABILIZATION_WAIT=20               # 重启后稳定等待时间（秒）

### 彩色输出函数 ###
red() { echo -e "\033[31m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }
green() { echo -e "\033[32m$*\033[0m"; }
blue() { echo -e "\033[34m$*\033[0m"; } # 新增蓝色输出，用于调试信息

### 日志记录函数 (增强) ###
log_info() {
    if [ ! -d "$(dirname "$LOG_FILE")" ]; then
        mkdir -p "$(dirname "$LOG_FILE")" # 自动创建日志目录
    fi

    if [ -f "$LOG_FILE" ] && [ $(stat -c%s "$LOG_FILE") -ge $MAX_LOG_SIZE ]; then
        mv "$LOG_FILE" "${LOG_FILE}.bak"
        echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] 日志文件已轮转为 ${LOG_FILE}.bak" >> "$LOG_FILE"
    fi

    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $@" >> "$LOG_FILE"
}

log_error() {
    if [ ! -d "$(dirname "$LOG_FILE")" ]; then
        mkdir -p "$(dirname "$LOG_FILE")"
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $@" >> "$LOG_FILE"
    red "$@" # 错误信息同时输出到终端
}

log_debug() { # 新增 debug 日志函数，默认不输出到终端，需要时可调整
    if [ ! -d "$(dirname "$LOG_FILE")" ]; then
        mkdir -p "$(dirname "$LOG_FILE")"
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') [DEBUG] $@" >> "$LOG_FILE"
    # blue "$@" # 可以选择性地将 debug 信息输出到终端，调试时取消注释
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
            # 特别处理 ip 依赖，安装 iproute2 软件包
            if echo "$missing_deps" | grep -q "ip"; then
                sudo apt update && sudo apt install -y curl jq ethtool iproute2 # 直接安装所有需要的包，包括 iproute2
            else
                sudo apt update && sudo apt install -y $missing_deps
            fi
        elif command -v yum >/dev/null 2>&1; then
             # 特别处理 ip 依赖，安装 iproute2 软件包
            if echo "$missing_deps" | grep -q "ip"; then
                sudo yum install -y curl jq ethtool iproute2 # 直接安装所有需要的包，包括 iproute2
            else
                sudo yum install -y $missing_deps
            fi
        elif command -v apk >/dev/null 2>&1; then
             # 特别处理 ip 依赖，安装 iproute2 软件包
            if echo "$missing_deps" | grep -q "ip"; then
                sudo apk add --no-cache curl jq ethtool iproute2 # 直接安装所有需要的包，包括 iproute2
            else
                sudo apk add --no-cache $missing_deps
            fi
        elif command -v opkg >/dev/null 2>&1; then
             # 特别处理 ip 依赖，安装 iproute2 软件包
            if echo "$missing_deps" | grep -q "ip"; then
                sudo opkg update && sudo opkg install curl jq ethtool iproute2 # 直接安装所有需要的包，包括 iproute2
            else
                sudo opkg update && sudo opkg install $missing_deps
            fi
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
    runtime=$(echo "$runtime" | sed 's/hours/小时/g; s/hour/小时/g; s/minutes/分钟/g; s/minute/分钟/g; s/,/，/g; s/,//g') # 移除多余的逗号

    local lan_ips_formatted
    lan_ips_formatted=$(get_lan_ip)
    if [ -z "$lan_ips_formatted" ]; then
        lan_ips_formatted="未获取到局域网 IP 地址" # 如果为空，显示更友好的提示
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

    # 优先使用默认路由接口获取 IP (更可靠)
    local default_interface=$(ip route get 8.8.8.8 2>/dev/null | awk 'NR==1 {print $5}') # 获取默认路由接口
    log_debug "默认路由接口: $default_interface"

    if [ -n "$default_interface" ]; then
        local default_ip_info=$(ip -4 addr show "$default_interface" 2>/dev/null | awk '/inet / {print $2}')
        if [ -n "$default_ip_info" ]; then
            local default_ip=$(echo "$default_ip_info" | cut -d '/' -f 1)
            if [ -n "$default_ip" ]; then
                # 使用 ethtool 判断接口类型 (如果可用)
                local interface_type=$(get_interface_type "$default_interface")
                ip_addresses="${ip_addresses}${interface_type} (${default_interface}): ${default_ip}\n" # 修改：使用传统拼接
                log_debug "通过默认路由接口获取到 IP: $ip_addresses"
                echo -e "$ip_addresses"
                return 0 # 成功获取到 IP，直接返回
            fi
        fi
        log_debug "默认路由接口 '$default_interface' 未获取到有效 IP，尝试遍历所有接口。"
    else
        log_debug "未找到默认路由接口，尝试遍历所有接口。"
    fi


    # 如果默认路由接口方法失败，则遍历所有网络接口 (原有逻辑增强)
    local interfaces=$(ip link show | awk '{print $2}' | tr -d ':' | grep -vE '^(lo|docker|veth|tun|br-)') # 排除 bridge 接口
    log_debug "待检查的接口列表: $interfaces"

    if [ -z "$interfaces" ]; then
        log_info "未找到任何物理网络接口。"
        echo "未找到局域网 IP 地址。" # 返回给调用者
        return 1
    fi


    for interface in $interfaces; do
        local ip_info=$(ip -4 addr show "$interface" 2>/dev/null | awk '/inet / {print $2}')

        if [ -n "$ip_info" ]; then
            local ip=$(echo "$ip_info" | cut -d '/' -f 1)

            if [ -n "$ip" ]; then
                # 排除回环地址和 Docker 等虚拟网段，不过滤所有私有IP，避免误判
                if ! echo "$ip" | grep -Eq "^(127\.0\.0\.1|172\.1[7-9]\.|172\.2[0-9]\.|172\.3[0-1]\.|192\.0\.0\.|192\.0\.2\.|192\.88\.99\.|192\.168\.|198\.1[8-9]\.|198\.51\.100\.|203\.0\.113\. )"; then #  保留 10. 开头的私有 IP 段
                    local interface_type=$(get_interface_type "$interface")
                    ip_addresses="${ip_addresses}${interface_type} (${interface}): ${ip}\n" # 修改：使用传统拼接
                    log_debug "遍历接口获取到 IP: $interface_type ($interface): $ip"
                else
                    log_debug "排除私有或保留 IP: $ip on interface $interface"
                fi
            fi
        fi
    done

    if [ -z "$ip_addresses" ]; then
        log_info "遍历所有接口后仍未找到局域网 IP 地址。"
        echo "未找到局域网 IP 地址。"
        return 1
    else
        echo -e "$ip_addresses" # 返回所有找到的局域网 IP 地址
        log_debug "最终获取到的局域网 IP 地址:\n$ip_addresses"
        return 0
    fi
}

### 获取接口类型 (有线/无线) ###
get_interface_type() {
    local interface=$1
    if command -v ethtool >/dev/null 2>&1; then
        local link_status=$(sudo ethtool "$interface" 2>/dev/null | grep "Link detected" | awk '{print $3}')
        # 彻底替换为 [ ... ] 语法，并注意空格和双引号
        if [ -n "$link_status" ] && [ "$link_status" = "yes" ]; then
            echo "有线"
        else
           if command -v iwconfig >/dev/null 2>&1 && iwconfig "$interface" 2>&1 | grep -q "ESSID:"; then
               echo "无线"
           else
               echo "未知类型" # 无法确定接口类型
           fi
        fi
    elif command -v iwconfig >/dev/null 2>&1 && iwconfig "$interface" 2>&1 | grep -q "ESSID:"; then
        echo "无线"
    else
        echo "未知类型" # 无法确定接口类型
    fi
}


### 获取公网信息（通过 ipinfo.io） ###
get_public_info() {
    local field=$1
    local result

    case "$field" in
        "org") result=$(curl -s ipinfo.io/org || echo "未知运营商") ;;
        "ip") result=$(curl -s ipinfo.io/ip || echo "未知 IPv4 地址") ;;
        "location") result="$(curl -s ipinfo.io/city || echo "未知城市"), $(curl -s ipinfo.io/country || echo "未知国家")" ;;
        *) result="未知信息" ;;
    esac

    echo "$result"
}


### 发送企业微信通知 ###
send_wechat_notification() {
    if [ -z "$WEBHOOK_URL" ]; then
        yellow "未配置企业微信 Webhook，跳过通知"
        log_info "未配置企业微信 Webhook，跳过通知"
        return
    fi

    # 检查状态文件是否存在且通知已成功
    if [ -f "$STATUS_FILE" ] && grep -q "success" "$STATUS_FILE"; then
        green "通知已成功发送，无需重复发送。"
        log_info "通知已成功发送，无需重复发送。"
        return 0
    fi

    local system_info=$(get_system_info)
    local retries=0

    while [ $retries -lt $MAX_RETRIES ]; do
        curl -sSf -H "Content-Type: application/json" \
            -d "{\"msgtype\":\"text\",\"text\":{\"content\":\"[设备: $(hostname)] 系统信息:\n$system_info\"}}" \
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
    sleep $STABILIZATION_WAIT  # 等待系统稳定
    send_wechat_notification  # 重启后发送完整通知
    log_info "开始收集系统信息并记录日志..."
    log_info "$(get_system_info)" # 直接将系统信息函数的结果记录到日志
    setup_autostart
    green "脚本执行完成。"
    log_info "脚本执行完成。"
}

main
