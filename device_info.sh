#!/bin/sh

### 配置常量 ###
LOG_FILE="/var/log/device_info.log"  # 日志文件路径
WEBHOOK_URL=""                      # 企业微信机器人 Webhook URL
DEPENDENCIES="curl jq"              # 必需依赖
CONFIG_FILE="/etc/device_info.conf" # 配置文件路径
STATUS_FILE="/tmp/device_notify_status" # 通知状态文件路径
MAX_LOG_SIZE=2097152                # 最大日志文件大小 (2 MB)
SCRIPT_PATH="$(realpath "$0")"      # 当前脚本路径
PING_TARGET="223.5.5.5"             # 网络检测目标
MAX_RETRIES=10                      # 最大重试次数
RETRY_INTERVAL=5                    # 重试间隔时间（秒）
STABILIZATION_WAIT=20               # 重启后稳定等待时间（秒）

### 彩色输出函数 ###
red() { echo "\033[31m$*\033[0m"; }
yellow() { echo "\033[33m$*\033[0m"; }
green() { echo "\033[32m$*\033[0m"; }

### 检查依赖并补全 ###
check_dependencies() {
    echo "正在检查依赖..."
    local missing_deps=""
    for dep in $DEPENDENCIES; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing_deps="$missing_deps $dep"
        fi
    done

    if [ -n "$missing_deps" ];then
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

### 获取系统详细信息并格式化 ###
get_system_info() {
    local runtime=$(uptime -p | sed 's/up //')
    runtime=$(echo "$runtime" | sed 's/hours/小时/g; s/hour/小时/g; s/minutes/分钟/g; s/minute/分钟/g; s/,/，/g')

    cat <<EOF
主机名: $(hostname)
系统版本: $(grep -oP '(?<=PRETTY_NAME=").*(?=")' /etc/os-release || echo '未知')
Linux版本: $(uname -r)
CPU架构: $(uname -m)
CPU型号: $(grep -m 1 'model name' /proc/cpuinfo | cut -d ':' -f2 | xargs || echo '未知')
CPU核心数: $(nproc)
CPU频率: $(lscpu | grep -oP '(?<=CPU MHz:).*' | xargs || echo '未知')
局域网 IP:
$(get_lan_ip)
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

### 获取局域网 IPv4 地址 ###
get_lan_ip() {
    # 使用 `ip` 命令获取所有非回环接口的IP地址
    if command -v ip >/dev/null 2>&1; then
        ip_addresses=$(ip -4 addr show | awk '/inet / && !/127.0.0.1/ {gsub(/\/[0-9]+/, "", $2); print $2}')
    elif command -v ifconfig >/dev/null 2>&1; then
        ip_addresses=$(ifconfig | awk '/inet / && $1 != "127.0.0.1" {print $2}')
    else
        echo "未知"
        return
    fi

    # 初始化分类存储
    local ethernet_ip=""
    local wifi_ip=""

    # 获取所有网络接口的类型
    while read -r ip; do
        # 获取接口名称
        local interface=$(ip -4 addr show | awk -v ip="$ip" '$2 ~ ip {print $NF}')
        
        # 获取接口的类型
        local interface_type=$(cat /sys/class/net/$interface/type 2>/dev/null)

        if [[ "$interface_type" == "ether" ]]; then
            ethernet_ip+="$ip "
        elif [[ "$interface_type" == "wireless" ]]; then
            wifi_ip+="$ip "
        fi
    done <<< "$ip_addresses"

    # 格式化输出
    local output=""
    if [ -n "$ethernet_ip" ]; then
        output+="有线网络 IP: $ethernet_ip\n"
    fi
    if [ -n "$wifi_ip" ]; then
        output+="无线网络 IP: $wifi_ip\n"
    fi

    echo -e "$output"
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

### 日志记录 ###
log_info() {
    if [ ! -d "$(dirname "$LOG_FILE")" ]; then
        echo "日志目录不存在：$(dirname "$LOG_FILE")"
        return 1
    fi

    if [ -f "$LOG_FILE" ] && [ $(stat -c%s "$LOG_FILE") -ge $MAX_LOG_SIZE ]; then
        mv "$LOG_FILE" "${LOG_FILE}.bak"
        echo "日志文件已轮转为 ${LOG_FILE}.bak"
    fi

    get_system_info >> "$LOG_FILE"
}

### 发送企业微信通知 ###
send_wechat_notification() {
    if [ -z "$WEBHOOK_URL" ]; then
        yellow "未配置企业微信 Webhook，跳过通知"
        return
    fi

    # 检查状态文件是否存在且通知已成功
    if [ -f "$STATUS_FILE" ] && grep -q "success" "$STATUS_FILE"; then
        green "通知已成功发送，无需重复发送。"
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
            echo "success" > "$STATUS_FILE"
            return 0
        else
            red "通知发送失败，重试中...（第 $((retries + 1)) 次）"
            retries=$((retries + 1))
            sleep $RETRY_INTERVAL
        fi
    done

    red "通知发送失败次数已达上限（$MAX_RETRIES 次）。"
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
    elif [ -f "/etc/rc.local" ]; then
        if ! grep -q "$SCRIPT_PATH" /etc/rc.local; then
            sudo sed -i -e "\$i $SCRIPT_PATH &\n" /etc/rc.local
        fi
    else
        red "无法设置自启动，系统不支持 systemd 且没有 rc.local 文件。"
    fi
}

### 主函数 ###
main() {
    load_config
    check_dependencies
    sleep $STABILIZATION_WAIT  # 等待系统稳定
    send_wechat_notification  # 重启后发送完整通知
    log_info
    setup_autostart
}

main
