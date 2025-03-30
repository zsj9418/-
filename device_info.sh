#!/bin/bash

### 配置常量 (恢复详细信息) ###
LOG_FILE="/var/log/device_info.log"
WEBHOOK_URL=""
DEPENDENCIES="curl ethtool ip"
CONFIG_FILE="/etc/device_info.conf"
STATUS_FILE="/tmp/device_notify_status" # 状态文件路径
MAX_LOG_SIZE=2097152 # 2MB 日志大小限制
SCRIPT_PATH="$(realpath "$0")"
PING_TARGET="223.5.5.5" # 用于检测网络连接的目标
MAX_RETRIES=10 # 网络检测和通知发送的最大重试次数
RETRY_INTERVAL=5 # 重试间隔（秒）
STABILIZATION_WAIT=20 # (当前未使用，但保留变量)

### 彩色输出函数 (完整) ###
red() { echo -e "\033[31m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }
green() { echo -e "\033[32m$*\033[0m"; }
blue() { echo -e "\033[34m$*\033[0m"; }

### 日志记录函数 (完整) ###
log_info() {
    if [ ! -d "$(dirname "$LOG_FILE")" ]; then mkdir -p "$(dirname "$LOG_FILE")"; fi
    # 检查日志大小，超过限制则清空
    if [ -f "$LOG_FILE" ] && [ $(stat -c%s "$LOG_FILE") -ge $MAX_LOG_SIZE ]; then
        truncate -s 0 "$LOG_FILE"
        if ! echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Log truncated due to size limit." >> "$LOG_FILE"; then echo "ERROR: Failed to write log truncation message." >&2; fi
    fi
    if ! echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $@" >> "$LOG_FILE"; then echo "ERROR: Failed to write info log: $@" >&2; fi
}

log_error() {
    if [ ! -d "$(dirname "$LOG_FILE")" ]; then mkdir -p "$(dirname "$LOG_FILE")"; fi
    if ! echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $@" >> "$LOG_FILE"; then echo "ERROR: Failed to write error log: $@" >&2; fi
    red "$@" # 同时在终端输出红色错误信息
}

log_debug() {
    # 可以根据需要启用或禁用调试日志
    # if [ ! -d "$(dirname "$LOG_FILE")" ]; then mkdir -p "$(dirname "$LOG_FILE")"; fi
    # echo "$(date '+%Y-%m-%d %H:%M:%S') [DEBUG] $@" >> "$LOG_FILE"
    : # 默认禁用，避免日志过多
}

### 检查依赖 (精简，移除 jq 依赖) ###
check_dependencies() {
    log_info "开始检查依赖: $DEPENDENCIES"
    local missing_deps=""
    for dep in $DEPENDENCIES; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing_deps="$missing_deps $dep"
        fi
    done

    if [ -n "$missing_deps" ]; then
        # 清理字符串前导空格
        missing_deps=$(echo "$missing_deps" | xargs)
        log_info "缺少依赖：$missing_deps，正在尝试自动安装..."
        yellow "缺少依赖：$missing_deps，正在尝试自动安装..."
        # 根据包管理器安装依赖
        if command -v apt-get >/dev/null 2>&1; then
            sudo apt-get update && sudo apt-get install -y $missing_deps
        elif command -v yum >/dev/null 2>&1; then
            sudo yum install -y $missing_deps
        elif command -v apk >/dev/null 2>&1; then
             sudo apk add --no-cache $missing_deps
        elif command -v opkg >/dev/null 2>&1; then
             sudo opkg update && sudo opkg install $missing_deps
        else
            log_error "无法识别的包管理器，请手动安装依赖：$missing_deps"
            red "无法识别的包管理器，请手动安装依赖：$missing_deps"
            exit 1
        fi
        # 再次检查是否安装成功
        for dep in $missing_deps; do
            if ! command -v "$dep" >/dev/null 2>&1; then
                log_error "依赖 $dep 安装失败，请手动检查并安装。"
                red "依赖 $dep 安装失败，请手动检查并安装。"
                exit 1
            fi
        done
        green "依赖 $missing_deps 安装成功。"
        log_info "依赖 $missing_deps 安装成功。"
    else
        green "所有依赖 ($DEPENDENCIES) 已满足。"
        log_info "所有依赖已满足。"
    fi
}

### 配置 (完整) ###
save_config() {
    # 保存配置到文件，确保目录存在
    mkdir -p "$(dirname "$CONFIG_FILE")"
    echo "WEBHOOK_URL=\"$WEBHOOK_URL\"" > "$CONFIG_FILE"
    log_info "配置已保存到 $CONFIG_FILE"
}

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # 从配置文件加载配置
        source "$CONFIG_FILE"
        log_info "已加载配置文件 $CONFIG_FILE"
    else
        log_info "未检测到配置文件 ($CONFIG_FILE)，将进行首次配置。"
        yellow "未检测到配置文件，需要进行首次配置..."
        configure_script # 调用配置函数
    fi
}

configure_script() {
    echo # 换行美观
    blue "--- 脚本配置 ---"
    local ENABLE_WEBHOOK=""
    # 循环直到用户输入 y 或 n
    while [[ "$ENABLE_WEBHOOK" != "y" && "$ENABLE_WEBHOOK" != "n" ]]; do
        read -p "是否启用企业微信机器人通知？(y/n): " ENABLE_WEBHOOK
        ENABLE_WEBHOOK=$(echo "$ENABLE_WEBHOOK" | tr '[:upper:]' '[:lower:]') # 转小写
    done

    if [ "$ENABLE_WEBHOOK" = "y" ]; then
        # 循环直到用户输入非空 URL
        while [ -z "$WEBHOOK_URL" ]; do
            read -p "请输入企业微信机器人 Webhook URL: " WEBHOOK_URL
            # 可选：添加 URL 格式校验
            if [[ -z "$WEBHOOK_URL" ]]; then
                yellow "Webhook URL 不能为空，请重新输入。"
            fi
        done
        green "企业微信机器人通知已启用。"
        log_info "企业微信机器人通知已启用，URL 已配置。"
    else
        WEBHOOK_URL="" # 明确设置为空
        yellow "企业微信机器人通知已禁用/跳过。"
        log_info "企业微信机器人通知已禁用/跳过。"
    fi
    save_config # 保存配置
}

### 获取系统信息 (最终修复，移除 jq 依赖，使用 grep/sed 解析 JSON) ###
get_system_info() {
    log_debug "开始获取系统信息..."
    local runtime=$(uptime -p | sed 's/up //')
    # 转换为中文时间单位
    runtime=$(echo "$runtime" | sed 's/years/年/g; s/year/年/g; s/months/月/g; s/month/月/g; s/weeks/周/g; s/week/周/g; s/days/天/g; s/day/天/g; s/hours/小时/g; s/hour/小时/g; s/minutes/分钟/g; s/minute/分钟/g; s/,/，/g;')

    local lan_ips_formatted
    lan_ips_formatted=$(get_lan_ip) # 获取格式化后的局域网 IP
    if [ -z "$lan_ips_formatted" ]; then
        lan_ips_formatted="未能获取局域网 IP 地址"
        log_info "未能获取局域网 IP 地址。"
    fi

    # CPU 占用率: 使用 top 命令获取空闲率，然后计算占用率
    local cpu_idle=$(top -bn1 | grep "Cpu(s)" | sed "s/.*,\s*\([0-9.]*\)\s*%id.*/\1/")
    local cpu_usage="未知"
    if [[ "$cpu_idle" =~ ^[0-9.]+$ ]]; then
        cpu_usage=$(awk -v idle="$cpu_idle" 'BEGIN { printf "%.2f%%", 100 - idle }')
    fi
    log_debug "CPU Idle: $cpu_idle, CPU Usage: $cpu_usage"

    # 内存信息: 使用 free 命令获取
    local mem_info=$(free -m | awk 'NR==2{printf "%.2f/%.2f MiB (%.2f%%)", $3, $2, $3*100/$2}')
    if [ -z "$mem_info" ]; then mem_usage="未知"; else mem_usage="$mem_info"; fi
    log_debug "Memory Usage: $mem_usage"

    # Swap 信息: 使用 free 命令获取
    local swap_info=$(free -m | awk 'NR==3{if ($2>0) printf "%.2f/%.2f MiB (%.2f%%)", $3, $2, $3*100/$2; else print "N/A"}')
     if [ -z "$swap_info" ]; then swap_usage="未知"; else swap_usage="$swap_info"; fi
    log_debug "Swap Usage: $swap_usage"

    # 硬盘占用: 获取根目录使用情况
    local disk_usage=$(df -h / | awk 'NR==2{print $3"/"$2 " ("$5")"}')
    if [ -z "$disk_usage" ]; then disk_usage="未知"; fi
    log_debug "Disk Usage (/): $disk_usage"

    # 网络流量统计 (仅统计 eth*, enp*, eno* 开头的接口)
    local total_rx=$(awk 'BEGIN {rx_total=0} $1 ~ /^(eth|enp|eno)/ {rx_total += $2} END {printf "%.2f MiB", rx_total/1024/1024}' /proc/net/dev)
    if [ -z "$total_rx" ]; then total_rx="未知"; fi
    local total_tx=$(awk 'BEGIN {tx_total=0} $1 ~ /^(eth|enp|eno)/ {tx_total += $10} END {printf "%.2f MiB", tx_total/1024/1024}' /proc/net/dev)
    if [ -z "$total_tx" ]; then total_tx="未知"; fi
    log_debug "Total RX: $total_rx, Total TX: $total_tx"

    # 其他系统信息
    local network_algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '未知')
    local cpu_model=$(grep -m 1 'model name' /proc/cpuinfo | cut -d ':' -f2 | xargs || echo '未知')
    local cpu_cores=$(nproc || echo '未知')
    local cpu_freq=$(lscpu | grep -oP 'CPU MHz:\s*\K[0-9.]+' | xargs || echo '未知')
    if [ -n "$cpu_freq" ]; then cpu_freq="${cpu_freq} MHz"; fi
    local os_version=$(grep -oP '(?<=PRETTY_NAME=").*(?=")' /etc/os-release || cat /etc/os-release | head -n 1 || echo '未知')
    local kernel_version=$(uname -r)
    local architecture=$(uname -m)
    local hostname=$(hostname)

    # 获取公网信息 (使用 grep/sed 解析)
    local ipinfo_json=""
    local public_ip="获取中..."
    local operator="获取中..."
    local location="获取中..."

    # 尝试获取公网信息，增加超时和重试可能更好，但暂时保持简单
    ipinfo_json=$(curl -s --connect-timeout 5 ipinfo.io)
    if [ -n "$ipinfo_json" ]; then
        log_debug "Got ipinfo.io response: $ipinfo_json"
        # 提取 IPv4 地址 (优先使用 ip 字段)
        public_ip=$(echo "$ipinfo_json" | grep -oP '"ip": *"\K[^"]+' || echo "未知 IPv4")
        # 提取运营商信息 (使用 org 字段)
        operator=$(echo "$ipinfo_json" | grep -oP '"org": *"\K[^"]+' || echo "未知运营商")
        # 提取地理位置信息 (City, Country)
        local city=$(echo "$ipinfo_json" | grep -oP '"city": *"\K[^"]+' || echo '')
        local country=$(echo "$ipinfo_json" | grep -oP '"country": *"\K[^"]+' || echo '')
        if [ -n "$city" ] && [ -n "$country" ]; then
            location="$city, $country"
        elif [ -n "$city" ]; then
            location="$city"
        elif [ -n "$country" ]; then
            location="$country"
        else
            location="未知地点"
        fi
    else
        log_error "获取公网信息失败 (curl ipinfo.io)"
        public_ip="获取失败"
        operator="获取失败"
        location="获取失败"
    fi
    log_debug "Public IP: $public_ip, Operator: $operator, Location: $location"

    # 格式化输出
    cat <<EOF
[设备: $hostname] 系统信息:
--------------------------------------
主机名    : $hostname
系统版本  : $os_version
Linux 内核: $kernel_version
CPU 架构  : $architecture
CPU 型号  : $cpu_model
CPU 核心数: $cpu_cores
CPU 频率  : $cpu_freq MHz
--------------------------------------
局域网 IP :
$lan_ips_formatted
--------------------------------------
公网信息  :
  运营商  : $operator
  IPv4 地址: $public_ip
  地理位置: $location
--------------------------------------
资源使用  :
  CPU 占用 : $cpu_usage
  系统负载 : $(uptime | awk -F'load average:' '{print $2}' | xargs || echo '未知')
  物理内存 : $mem_usage
  虚拟内存 : $swap_usage
  硬盘占用 : $disk_usage (/)
--------------------------------------
网络状态  :
  总接收量 : $total_rx
  总发送量 : $total_tx
  TCP 算法 : $network_algo
--------------------------------------
系统时间  : $(date '+%Z %Y-%m-%d %I:%M:%S %p')
运行时长  : $runtime
--------------------------------------
EOF
}

### 获取局域网 IPv4 地址 (改进版) ###
get_lan_ip() {
    local ip_addresses=""
    # 获取所有非虚拟、非回环、非 docker/bridge 的接口名
    local interfaces=$(ip -o link show | awk -F': ' '{print $2}' | grep -vE '^(lo|docker|veth|tun|br-|virbr|vnet)')

    if [ -z "$interfaces" ]; then
        log_info "未找到合适的物理网络接口。"
        echo "  未找到局域网 IP 地址。" # 返回缩进格式
        return 1
    fi

    log_debug "检测到的网络接口: $interfaces"
    for interface in $interfaces; do
        # 获取该接口的 IPv4 地址
        local ip_info=$(ip -4 -o addr show "$interface" | awk '{print $4}')
        if [ -n "$ip_info" ]; then
            local ip=$(echo "$ip_info" | cut -d '/' -f 1)
            if [ -n "$ip" ]; then
                # 排除回环地址 (虽然接口筛选已做，双重保险)
                if [[ "$ip" != "127.0.0.1" ]]; then
                    local interface_type=$(get_interface_type "$interface")
                    # 添加缩进以匹配输出格式
                    ip_addresses="${ip_addresses}  ${interface_type} (${interface}): ${ip}\n"
                    log_debug "获取到 IP: $interface_type ($interface): $ip"
                else
                    log_debug "排除回环地址: $ip on $interface"
                fi
            fi
        else
             log_debug "接口 $interface 没有 IPv4 地址。"
        fi
    done

    if [ -z "$ip_addresses" ]; then
        log_info "遍历所有接口后未找到有效的局域网 IPv4 地址。"
        echo "  未找到局域网 IP 地址。" # 返回缩进格式
        return 1
    else
        # 移除最后一个换行符
        echo -e "${ip_addresses%\\n}"
        log_debug "最终格式化的局域网 IP:\n$ip_addresses"
        return 0
    fi
}

### 获取接口类型 (有线/无线) ###
get_interface_type() {
    local interface=$1
    # 尝试使用 ethtool 判断是否为有线接口 (需要 root 或相应权限)
    if command -v ethtool >/dev/null 2>&1; then
        # 忽略错误输出，因为非以太网接口会报错
        if sudo ethtool "$interface" 2>/dev/null | grep -q "Link detected: yes"; then
            echo "有线"
            return 0
        # 检查是否支持 Wake-on-LAN，也可能是物理接口的标志
        elif sudo ethtool "$interface" 2>/dev/null | grep -q "Supports Wake-on:"; then
             echo "有线"
             return 0
        fi
    fi
    # 尝试使用 iwconfig 判断是否为无线接口
    if command -v iwconfig >/dev/null 2>&1; then
        if iwconfig "$interface" 2>&1 | grep -q "ESSID:"; then
            echo "无线"
            return 0
        fi
         if iwconfig "$interface" 2>&1 | grep -q "Mode:Master"; then
            echo "无线AP" # 如果是 AP 模式
            return 0
        fi
    fi
    # 根据接口路径判断（不一定可靠）
    if [[ -d "/sys/class/net/$interface/wireless" ]]; then
        echo "无线"
        return 0
    fi
     if [[ -d "/sys/class/net/$interface/phy80211" ]]; then
        echo "无线"
        return 0
    fi
    # 默认或无法判断
    echo "未知类型"
}

### 获取公网信息 (已集成到 get_system_info 中) ###
# get_public_info() 函数不再单独需要，逻辑已合并

### 检测网络连接 (增强网络检测, 移除状态文件删除操作) ###
wait_for_network() {
    local retries=0
    log_info "开始等待网络连接..."
    while [ $retries -lt $MAX_RETRIES ]; do
        # 使用配置的目标进行 ping 测试
        ping -c 1 -W 2 $PING_TARGET > /dev/null 2>&1 # -W 2 设置超时为 2 秒
        local ping_result=$?

        # 如果 ping 成功，则认为网络已连接
        if [ $ping_result -eq 0 ]; then
            log_info "网络已连接 (ping $PING_TARGET 成功)。"
            # !!! --- 关键修改：移除了下面这行代码 --- !!!
            # rm -f "$STATUS_FILE"
            # !!! --- 关键修改：移除了下面这行代码 --- !!!
            return 0 # 返回成功状态码
        else
            log_info "网络未连接，等待 $RETRY_INTERVAL 秒后重试... (第 $((retries + 1))/$MAX_RETRIES 次)"
            sleep $RETRY_INTERVAL
            retries=$((retries + 1))
        fi
    done
    log_error "网络连接检测失败，已达到最大重试次数 ($MAX_RETRIES)。"
    return 1 # 返回失败状态码
}

### 发送企业微信通知 (完整) ###
send_wechat_notification() {
    # 再次检查 WEBHOOK_URL 是否已加载且非空
    if [ -z "$WEBHOOK_URL" ]; then
        # 尝试从配置文件加载 (如果 main 函数未加载)
        if [ -f "$CONFIG_FILE" ]; then
            source "$CONFIG_FILE"
        fi
        # 再次检查
        if [ -z "$WEBHOOK_URL" ]; then
            yellow "未配置或未启用企业微信 Webhook，跳过通知。"
            log_info "Webhook URL 为空或未配置，跳过通知。"
            return 0 # 返回成功，因为这是预期行为
        fi
    fi

    # 核心逻辑：检查状态文件是否存在
    if [ -f "$STATUS_FILE" ]; then
        log_info "状态文件 $STATUS_FILE 已存在，表示本次启动已发送过通知，跳过发送。"
        green "通知已发送过，本次跳过。"
        return 0 # 返回成功，因为无需发送
    fi

    log_info "状态文件不存在，准备发送企业微信通知..."
    yellow "准备发送企业微信通知..."

    local system_info
    system_info=$(get_system_info) # 获取最新的系统信息用于通知

    # 构造 JSON payload
    # 注意 content 中换行符需要转义为 \n
    local escaped_info=$(echo "$system_info" | sed ':a;N;$!ba;s/\n/\\n/g')
    local json_payload="{\"msgtype\":\"text\",\"text\":{\"content\":\"$escaped_info\"}}"

    local retries=0
    while [ $retries -lt $MAX_RETRIES ]; do
        # 发送 POST 请求
        local http_code=$(curl -s -o /dev/null -w "%{http_code}" -H "Content-Type: application/json" \
            -X POST -d "$json_payload" "$WEBHOOK_URL" --connect-timeout 10) # 增加连接超时

        if [ "$http_code" -eq 200 ]; then
            green "企业微信通知发送成功 (HTTP $http_code)。"
            log_info "企业微信通知发送成功。"
            # 成功发送后，立即创建状态文件
            if touch "$STATUS_FILE"; then
                log_info "已创建状态文件 $STATUS_FILE。"
            else
                log_error "创建状态文件 $STATUS_FILE 失败！后续可能会重复发送通知。"
                red "错误：创建状态文件失败！"
                # 虽然通知发送成功，但创建状态文件失败，返回错误码提示问题
                return 1
            fi
            return 0 # 通知发送且状态文件创建成功
        else
            red "企业微信通知发送失败 (HTTP $http_code)，将在 $RETRY_INTERVAL 秒后重试...（第 $((retries + 1))/$MAX_RETRIES 次）"
            log_error "企业微信通知发送失败 (HTTP $http_code)，重试...（$((retries + 1)) 次）"
            retries=$((retries + 1))
            sleep $RETRY_INTERVAL
        fi
    done

    red "企业微信通知发送失败次数达到上限（$MAX_RETRIES 次）。"
    log_error "企业微信通知发送失败次数达到上限（$MAX_RETRIES 次）。"
    return 1 # 返回失败状态码
}

### 设置自启动 (增强 Systemd 配置, 增加更严格的检查) ###
setup_autostart() {
    log_info "检查并设置自启动..."
    # 优先使用 systemd
    if command -v systemctl >/dev/null 2>&1; then
        local service_name="device_info.service"
        local service_file="/etc/systemd/system/$service_name"
        local need_reload=false

        # 检查服务文件是否存在或内容是否需要更新 (确保 ExecStart 指向当前脚本)
        local current_exec_start=$(grep -oP '^ExecStart=\K.*' "$service_file" 2>/dev/null)
        if [ ! -f "$service_file" ] || [ "$current_exec_start" != "$SCRIPT_PATH" ]; then
            log_info "创建或更新 systemd 服务文件: $service_file"
            # 使用 sudo tee 写入文件
            echo "[Unit]
Description=Device Info Notifier on Boot
After=network-online.target network.target # 等待网络就绪
Wants=network-online.target

[Service]
Type=oneshot # 脚本是运行一次性的任务
RemainAfterExit=no # 运行后即退出状态
ExecStart=$SCRIPT_PATH # 使用变量确保路径正确
User=root # 假设脚本需要 root 权限 (如果不需要可以改为普通用户)
WorkingDirectory=$(dirname "$SCRIPT_PATH") # 设置工作目录为脚本所在目录

[Install]
WantedBy=multi-user.target" | sudo tee "$service_file" > /dev/null

            if [ $? -ne 0 ]; then
                log_error "创建/更新 systemd 服务文件失败: $service_file"
                red "错误：创建/更新 systemd 服务文件失败。"
                return 1
            fi
            log_info "已成功创建/更新 systemd 服务文件: $service_file"
            need_reload=true # 文件已更改，需要 reload
        fi

        # 检查服务是否已启用
        if ! sudo systemctl is-enabled "$service_name" >/dev/null 2>&1; then
            log_info "启用 systemd 服务: $service_name"
            sudo systemctl enable "$service_name"
            if [ $? -ne 0 ]; then
                log_error "启用 systemd 服务失败: $service_name"
                red "错误：启用 systemd 服务失败。"
                # 即使启用失败，也继续尝试 reload (如果需要)
            else
                log_info "已成功启用 systemd 服务: $service_name"
                need_reload=true # 启用状态改变，建议 reload
            fi
        fi

        # 如果需要，重新加载 systemd 配置
        if [ "$need_reload" = true ]; then
            log_info "重新加载 systemd 配置..."
            sudo systemctl daemon-reload
            if [ $? -ne 0 ]; then
                log_error "重新加载 systemd 配置失败。"
                red "警告：重新加载 systemd 配置失败，服务可能未按预期运行。"
                # 不认为是致命错误，继续执行
            else
                 log_info "Systemd 配置已重新加载。"
            fi
        fi

        log_info "Systemd 自启动设置检查完成。"
        green "Systemd 自启动设置检查完成。"

    # 备选方案：rc.local (兼容老系统)
    elif [ -f "/etc/rc.local" ]; then
        # 检查脚本路径是否已存在于 rc.local 中 (忽略注释行和 exit 0 之后的行)
        if ! grep -q "^\s*[^#].*$(basename "$SCRIPT_PATH")" /etc/rc.local || ! grep -q "$SCRIPT_PATH" /etc/rc.local; then
             log_info "尝试将脚本添加到 /etc/rc.local..."
            # 确保 rc.local 可执行
            if [ ! -x "/etc/rc.local" ]; then
                sudo chmod +x /etc/rc.local
                log_info "/etc/rc.local 文件已设置为可执行。"
            fi
            # 在 exit 0 (如果存在) 之前插入脚本执行命令
            if grep -q '^exit 0' /etc/rc.local; then
                sudo sed -i "/^exit 0/i $SCRIPT_PATH &" /etc/rc.local
            else
                # 如果没有 exit 0，则追加到文件末尾
                echo "$SCRIPT_PATH &" | sudo tee -a /etc/rc.local > /dev/null
            fi

            # 再次检查是否添加成功
            if grep -q "$SCRIPT_PATH" /etc/rc.local; then
                 log_info "已将脚本添加到 rc.local 自启动。"
                 green "已将脚本添加到 rc.local 自启动。"
            else
                 log_error "将脚本添加到 rc.local 失败。"
                 red "错误：将脚本添加到 rc.local 失败。"
                 return 1
            fi
        else
            log_info "脚本已存在于 /etc/rc.local 中，无需重复添加。"
            green "脚本已配置在 rc.local 中。"
        fi
    else
        log_error "未找到 systemd 或 rc.local，无法自动设置自启动。"
        red "错误：未找到 systemd 或 rc.local，无法自动设置自启动。请手动配置。"
        return 1 # 返回失败
    fi
    return 0 # 设置成功或已设置
}

### 主函数 (完整) ###
main() {
    # 确保脚本以 root 权限运行（如果需要执行 sudo 命令）
    # if [ "$(id -u)" -ne 0 ]; then
    #    red "此脚本需要 root 权限运行，请使用 sudo。"
    #    log_error "脚本未以 root 权限运行。"
    #    exit 1
    # fi

    log_info "--- 脚本开始执行 ---"
    blue "--- 设备信息通知脚本 ---"

    # 加载或请求配置
    load_config

    # 检查依赖
    check_dependencies
    if [ $? -ne 0 ]; then exit 1; fi # 依赖检查失败则退出

    # 等待网络连接就绪
    wait_for_network
    if [ $? -ne 0 ]; then
        log_error "网络未连接，无法继续执行。退出。"
        red "网络连接失败，脚本退出。"
        exit 1 # 网络不通则退出
    fi

    # 发送企业微信通知 (包含状态检查)
    send_wechat_notification
    # send_wechat_notification 的返回值可以忽略，因为日志会记录结果
    # 但如果创建状态文件失败，会返回 1

    # 记录当前系统信息到日志文件（无论是否发送通知）
    log_info "开始收集并记录当前系统信息..."
    current_info=$(get_system_info)
    log_info "-------------------- 系统信息快照 --------------------"
    # 使用 printf 避免 echo 解析转义字符
    printf "%s\n" "$current_info" >> "$LOG_FILE"
    log_info "-----------------------------------------------------"
    # 同时在终端显示信息
    echo # 换行
    blue "--- 当前系统信息 ---"
    echo "$current_info"
    echo # 换行

    # 检查并设置自启动 (每次运行都检查确保配置存在且正确)
    setup_autostart

    green "脚本执行完成。"
    log_info "--- 脚本执行完毕 ---"
    echo # 换行
}

# 执行主函数
main
