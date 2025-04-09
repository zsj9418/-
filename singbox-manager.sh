#!/bin/sh
set -eu  # 使用 POSIX 兼容的 set 选项

# 定义颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# 可配置路径和默认值
BASE_DIR="/etc/sing-box"
BIN_DIR="/usr/local/bin"
CONFIG_FILE="$BASE_DIR/config.json"
ENV_FILE="$HOME/.singbox_env" # 注意：放用户家目录可能更合适，避免权限问题
LOG_FILE="/var/log/sing-box-script.log" # 主脚本日志
SCRIPT_PATH="$0"  # 使用 $0 获取脚本名
UPDATE_SCRIPT="$BASE_DIR/update-singbox.sh" # 更新脚本路径

# 获取设备名称（兼容 OpenWrt 和其他系统）
get_device_name() {
    if command -v hostname >/dev/null 2>&1; then
        hostname
    elif [ -f /proc/sys/kernel/hostname ]; then
        cat /proc/sys/kernel/hostname
    else
        echo "unknown-device"
    fi
}
DEVICE_NAME=$(get_device_name)

# 日志记录函数 (主脚本用)
log() {
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    printf "%b[%s] %s%b\n" "$YELLOW" "$timestamp" "$1" "$NC"
    echo "[$timestamp] $1" >> "$LOG_FILE"
}

# 彩色输出函数
red() { printf "%b%s%b\n" "$RED" "$1" "$NC"; }
green() { printf "%b%s%b\n" "$GREEN" "$1" "$NC"; }
yellow() { printf "%b%s%b\n" "$YELLOW" "$1" "$NC"; }

# 检查是否为 root 用户
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        red "此脚本必须以 root 用户运行"
        exit 1
    fi
}

# 获取架构信息（通用性，支持多种架构）
get_arch() {
    case $(uname -m) in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l)  echo "armv7" ;;
        riscv64) echo "riscv64" ;;
        *)       red "不支持的架构: $(uname -m)"; exit 1 ;;
    esac
}

# 判断系统类型
detect_system() {
    if [ -f /etc/openwrt_release ]; then
        echo "openwrt"
    elif command -v apt >/dev/null 2>&1; then
        echo "debian"
    elif command -v yum >/dev/null 2>&1; then
        echo "centos"
    elif command -v apk >/dev/null 2>&1; then
        echo "alpine"
    else
        echo "unknown"
    fi
}

# 安装依赖（兼容 OpenWrt 和其他系统）
install_deps() {
    log "正在检查并安装依赖 (fzf, curl, tar, iptables, ipset, jq, psmisc, cron)..."
    pkg_manager=""
    install_cmd=""
    update_cmd=""
    pkgs="curl tar iptables ipset jq psmisc cron fzf" # 包括 fzf
    cron_pkg="cron" # 默认cron包名

    if command -v apt >/dev/null 2>&1; then
        pkg_manager="apt"
        update_cmd="apt update"
        install_cmd="apt install -y"
    elif command -v yum >/dev/null 2>&1; then
        pkg_manager="yum"
        update_cmd="" # yum usually doesn't need separate update before install
        install_cmd="yum install -y"
        cron_pkg="cronie" # CentOS/RHEL use cronie
    elif command -v apk >/dev/null 2>&1; then
        pkg_manager="apk"
        update_cmd="apk update"
        install_cmd="apk add"
        cron_pkg="cronie" # Alpine might use cronie too, or just cron
    elif command -v opkg >/dev/null 2>&1; then # OpenWrt
        pkg_manager="opkg"
        update_cmd="opkg update"
        install_cmd="opkg install"
        pkgs="curl tar jq coreutils-killall" # Adjust based on OpenWrt specifics
        cron_pkg="cron"
    else
        red "不支持的包管理器，请手动安装 curl, tar, iptables, ipset, jq, psmisc, cron, fzf"
        return 1
    fi

    # Adjust cron package name if needed
    pkgs=$(echo "$pkgs" | sed "s/cron/$cron_pkg/")

    log "使用包管理器: $pkg_manager"
    if [ -n "$update_cmd" ]; then
        $update_cmd || { red "包列表更新失败"; return 1; }
    fi
    if ! $install_cmd $pkgs; then
         red "依赖安装失败: $pkgs"
         yellow "请尝试手动安装上述依赖包。"
         return 1
    fi

    # 检查 fzf 是否安装
    if ! command -v fzf >/dev/null 2>&1; then
        red "未检测到 fzf。请手动安装 fzf，命令示例: $install_cmd fzf"
        return 1
    fi

    green "依赖安装完成"
}

# 获取网关 IP
get_gateway_ip() {
    iface=$(ip route show default | awk '/default/ {print $5}' | head -n 1) # Get first default interface
    if [ -z "$iface" ]; then
        red "无法获取默认网络接口"
        # Fallback: try guessing common LAN interface names
        for iface_try in eth0 ens160 br-lan; do
            if ip addr show dev "$iface_try" > /dev/null 2>&1; then
                 gw_ip=$(ip addr show dev "$iface_try" | awk '/inet / {print $2}' | cut -d'/' -f1 | head -n 1)
                 if [ -n "$gw_ip" ]; then
                     yellow "无法获取默认接口，猜测使用 $iface_try 的 IP: $gw_ip"
                     echo "$gw_ip"
                     return 0
                 fi
            fi
        done
        red "也无法从常见接口猜测IP。"
        return 1
    fi
    gw_ip=$(ip addr show dev "$iface" | awk '/inet / {print $2}' | cut -d'/' -f1 | head -n 1)
    if [ -z "$gw_ip" ]; then
        red "在接口 $iface 上找不到 IPv4 地址"
        return 1
    fi
    echo "$gw_ip"
}

# 验证版本号格式
validate_version() {
    version="$1"
    # 允许 v 开头，兼容 alpha, beta, rc 等后缀
    if ! echo "$version" | grep -Eq '^v?[0-9]+\.[0-9]+\.[0-9]+([.-][a-zA-Z0-9.-]+)*$'; then
        red "无效的版本号格式: $version"
        return 1
    fi
}

# 清理临时文件
cleanup() {
    if [ -n "${TEMP_DIR:-}" ] && [ -d "$TEMP_DIR" ]; then
        log "清理临时文件: $TEMP_DIR"
        rm -rf "$TEMP_DIR"
    fi
}
# 设置 trap 以确保清理
trap 'echo "脚本意外中断，执行清理..."; cleanup' INT TERM EXIT


# 检查网络通畅性
check_network() {
    log "检查网络通畅性 (ping 8.8.8.8)..."
    # 使用 ping 并设置超时
    if ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1; then
        green "网络连接正常 (ping 8.8.8.8 成功)"
        return 0
    else
        log "ping 8.8.8.8 失败, 尝试 curl google.com..."
        # 如果 ping 失败，尝试 curl
        if curl -s --head --connect-timeout 10 --max-time 15 https://www.google.com >/dev/null 2>&1; then
             green "网络连接正常 (curl google.com 成功)"
             return 0
        else
             red "无法连接到外网 (ping 和 curl 都失败)，请检查网络配置"
             return 1
        fi
    fi
}

# 配置网络（启用转发和 iptables NAT）
configure_network() {
    log "配置 IPv4 转发和 NAT..."
    # 启用 IP 转发
    if sysctl net.ipv4.ip_forward | grep -q "net.ipv4.ip_forward = 1"; then
        green "IPv4 转发已启用"
    else
        yellow "启用 IPv4 转发..."
        sysctl -w net.ipv4.ip_forward=1
        # 持久化
        if grep -q "^net.ipv4.ip_forward=" /etc/sysctl.conf; then
            sed -i 's/^net.ipv4.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
        else
            echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
        fi
        green "IPv4 转发已启用并持久化"
    fi

    # 配置 NAT (Masquerade) - 假设内网是 192.168.0.0/16, 可根据需要修改
    nat_rule_exists=$(iptables -t nat -C POSTROUTING -s 192.168.0.0/16 -j MASQUERADE 2>/dev/null; echo $?)
    if [ "$nat_rule_exists" -eq 0 ]; then
        green "NAT 规则 (MASQUERADE for 192.168.0.0/16) 已存在"
    else
        yellow "添加 NAT 规则 (MASQUERADE for 192.168.0.0/16)..."
        if iptables -t nat -A POSTROUTING -s 192.168.0.0/16 -j MASQUERADE; then
             green "NAT 规则添加成功"
             # 尝试持久化 iptables 规则
             if command -v iptables-save >/dev/null 2>&1; then
                 mkdir -p /etc/iptables
                 if iptables-save > /etc/iptables/rules.v4; then
                     green "iptables 规则已保存到 /etc/iptables/rules.v4"
                     yellow "请确保系统启动时会加载此规则 (例如通过 netfilter-persistent 或 rc.local)"
                 else
                     red "iptables-save 保存规则失败"
                 fi
             else
                 yellow "未找到 iptables-save 命令，NAT 规则可能不会持久化，请手动配置"
             fi
        else
            red "添加 NAT 规则失败"
        fi
    fi
}


# 加载环境变量
load_env() {
    if [ -f "$ENV_FILE" ]; then
        # shellcheck source=/dev/null
        . "$ENV_FILE"
        green "已加载环境变量配置文件 $ENV_FILE"
    else
        yellow "未检测到环境变量配置文件 $ENV_FILE"
        yellow "将进入交互式变量输入..."
        if setup_env; then # setup_env 会调用 save_env
             # shellcheck source=/dev/null
            . "$ENV_FILE" # 重新加载以使当前脚本生效
        else
            red "环境变量设置失败。"
            return 1 # 指示失败
        fi
    fi
    # 检查必要变量是否已加载
    if [ -z "${SUBSCRIBE_URLS:-}" ]; then
         red "错误：环境变量 SUBSCRIBE_URLS 未设置或为空！"
         yellow "请重新运行脚本并选择选项2来设置订阅链接。"
         return 1
    fi
    return 0 # 指示成功
}

# 保存环境变量到文件
save_env() {
    # 确保目录存在
    mkdir -p "$(dirname "$ENV_FILE")"
    # 使用 cat 和 EOF 创建或覆盖文件
    cat >"$ENV_FILE" <<EOF
# sing-box 脚本环境变量
# 由脚本自动生成于 $(date)

# 企业微信 Webhook 地址 (可选)
WX_WEBHOOK="${WX_WEBHOOK:-}"

# 订阅链接 (必填, 多个用空格分隔)
SUBSCRIBE_URLS="${SUBSCRIBE_URLS:-}"

# sing-box 配置文件路径 (由主脚本定义，更新脚本会读取此文件)
CONFIG_PATH="${CONFIG_FILE:-}"

# 更新脚本日志文件路径 (供更新脚本使用)
UPDATE_LOG_FILE="${UPDATE_LOG_FILE:-/var/log/sing-box-update.log}"

# sing-box 可执行文件路径 (供更新脚本使用)
SINGBOX_BIN_PATH="${BIN_DIR:-}/sing-box"
EOF
    # 设置权限，避免敏感信息泄露（如果在家目录，用户权限即可；如果在/etc下，可能需要root）
    chmod 600 "$ENV_FILE"
    green "环境变量已保存到 $ENV_FILE"
}

# 交互式配置环境变量
setup_env() {
    printf "请输入企业微信 Webhook 地址（可选，用于接收更新通知，直接回车跳过）: "
    read user_wx_webhook
    WX_WEBHOOK=${user_wx_webhook:-} # 保留空值如果用户跳过

    while true; do
        printf "请输入 sing-box 订阅链接（必填，多个链接请用空格分隔）: "
        read user_subscribe_urls
        if [ -z "$user_subscribe_urls" ]; then
            red "订阅链接不能为空，请重新输入。"
        else
            # 简单验证是否像 URL (包含 http)
            if echo "$user_subscribe_urls" | grep -q 'http'; then
                 SUBSCRIBE_URLS="$user_subscribe_urls"
                 break
            else
                 red "输入的似乎不是有效的 URL，请确保包含 http:// 或 https://。"
            fi
        fi
    done

    # 定义更新脚本的日志文件路径 (这里可以给个默认值)
    default_update_log="/var/log/sing-box-update.log"
    printf "请输入更新脚本的日志文件路径 [默认: %s]: " "$default_update_log"
    read user_update_log
    UPDATE_LOG_FILE=${user_update_log:-$default_update_log}

    # 其他变量 (CONFIG_FILE, BIN_DIR) 由脚本顶部定义，直接使用
    save_env # 调用保存函数
    return 0 # 指示成功
}

# 企业微信通知函数 (主脚本用)
send_wx_notification() {
    local webhook_url="$1"
    local message_content="$2"
    if [ -z "$webhook_url" ]; then
        yellow "未配置企业微信 Webhook (主脚本)，跳过通知"
        return
    fi
    # 准备 JSON 数据
    json_payload=$(printf '{"msgtype":"text","text":{"content":"设备 [%s] 通知 (主脚本)：\n%s"}}' "$DEVICE_NAME" "$message_content")

    log "向企业微信发送通知..."
    # 发送请求，增加超时和错误处理
    if curl -sSf -H "Content-Type: application/json" \
        --connect-timeout 10 --max-time 20 \
        -d "$json_payload" \
        "$webhook_url" >/dev/null; then
        green "通知发送成功"
    else
        ret_code=$?
        red "通知发送失败 (curl 退出码: $ret_code)"
        log "通知发送失败: $message_content (curl code: $ret_code)"
    fi
}

# 停止 sing-box 服务 (使用 pkill)
stop_singbox() {
    log "尝试停止 sing-box 进程..."
    # 使用 pkill 查找并杀死包含特定路径的进程，更精确
    # 添加 || true 防止在进程未找到时 set -e 退出脚本
    if pkill -f "$BIN_DIR/sing-box run -c $CONFIG_FILE" || true; then
        # 等待一小段时间让进程退出
        log "等待 sing-box 进程退出..."
        sleep 2
        # 再次检查确认
        # 添加 || true 防止在进程已退出时 set -e 退出脚本
        if pgrep -f "$BIN_DIR/sing-box run -c $CONFIG_FILE" >/dev/null 2>&1 || true; then
             # 只有在 pgrep 真的找到进程 (退出码0) 时才尝试 kill -9
             if [ $? -eq 0 ]; then
                 yellow "第一次 pkill 后进程仍在运行，尝试强制杀死 (SIGKILL)..."
                 pkill -9 -f "$BIN_DIR/sing-box run -c $CONFIG_FILE" || true # 强制杀死
                 sleep 1
                 # 最后检查一次
                 if pgrep -f "$BIN_DIR/sing-box run -c $CONFIG_FILE" >/dev/null 2>&1; then
                      red "强制杀死 sing-box 失败！"
                      return 1 # 明确返回失败
                 fi
             fi
        fi
        green "sing-box 进程已终止 (或未运行)"
    else
        # 如果 pkill 本身出错 (不是未找到进程)，记录错误
        if [ $? -ne 0 ]; then
            red "执行 pkill 时发生错误 (退出码: $?)"
            return 1
        fi
        # 如果 pkill 返回0但未杀死，或者返回非0但不是错误（上面 || true 处理了）
        # 这里逻辑有点绕，之前的if分支已处理大部分情况
        # 保留原始yellow信息
         yellow "sing-box 未运行 (或 pkill 未找到匹配进程)"
    fi
    return 0 # 明确返回成功
}

# 启动 sing-box 服务（使用 nohup 在后台运行）
start_singbox() {
    # 检查配置文件是否存在且可读
    if [ ! -r "$CONFIG_FILE" ]; then
        red "配置文件 $CONFIG_FILE 不存在或不可读，无法启动 sing-box"
        return 1
    fi
    # 检查可执行文件是否存在且可执行
    if [ ! -x "$BIN_DIR/sing-box" ]; then
        red "sing-box 可执行文件 $BIN_DIR/sing-box 不存在或不可执行"
        return 1
    fi

    # 先确保已停止 - 调用修改后的 stop_singbox
    # 不需要 || true 了，因为 stop_singbox 现在会返回 0 即使进程未运行
    if ! stop_singbox; then
        red "启动前停止旧进程失败，中断启动";
        return 1;
    fi
    # 短暂延时确保端口释放等
    sleep 1

    log "尝试使用 nohup 启动 sing-box..."
    start_cmd="nohup $BIN_DIR/sing-box run -c $CONFIG_FILE >/dev/null 2>&1 &"
    # 使用 eval 执行命令，确保 & 后台符号正确处理
    eval "$start_cmd"
    # 等待一小段时间让进程启动
    log "等待 sing-box 启动..."
    sleep 3

    # 检查进程是否已启动
    # 添加 || true 防止在进程未启动时 set -e 退出脚本
    if pgrep -f "$BIN_DIR/sing-box run -c $CONFIG_FILE" >/dev/null 2>&1 || true; then
        # 再次检查退出码确保是真的找到了进程
        if [ $? -eq 0 ]; then
            pid=$(pgrep -f "$BIN_DIR/sing-box run -c $CONFIG_FILE")
            green "sing-box 已通过 nohup 启动 (PID: $pid)，使用配置文件: $CONFIG_FILE"
            return 0 # 明确返回成功
        else
            red "sing-box 启动失败，请检查配置文件 $CONFIG_FILE 或使用 'sing-box run -c $CONFIG_FILE' 手动运行查看错误"
            log "sing-box 启动失败，命令: $BIN_DIR/sing-box run -c $CONFIG_FILE"
            # 尝试读取 sing-box 自身日志？（如果配置了）
            return 1 # 明确返回失败
        fi
    else
        # pgrep 出错 (不是未找到进程)
         if [ $? -ne 0 ] && [ $? -ne 1 ]; then # $?=1 是没找到，其他是非零错误
            red "检查进程状态时 pgrep 命令出错 (退出码: $?)"
         fi
         red "sing-box 启动失败，请检查配置文件 $CONFIG_FILE 或使用 'sing-box run -c $CONFIG_FILE' 手动运行查看错误"
         log "sing-box 启动失败，命令: $BIN_DIR/sing-box run -c $CONFIG_FILE"
         return 1 # 明确返回失败
    fi
}

# 设置开机自启动 (尝试多种方式)
setup_autostart() {
    log "设置开机自启动..."
    start_cmd_raw="$BIN_DIR/sing-box run -c $CONFIG_FILE"
    # 使用 nohup 并重定向输出
    start_cmd="nohup $start_cmd_raw >/dev/null 2>&1 &"
    autostart_set=false

    # 1. 尝试 systemd (如果可用)
    if command -v systemctl >/dev/null 2>&1; then
        log "检测到 systemd，尝试创建 service 文件..."
        service_file="/etc/systemd/system/sing-box.service"
        cat > "$service_file" << EOF
[Unit]
Description=Sing-Box Service
After=network.target network-online.target nss-lookup.target

[Service]
WorkingDirectory=$BASE_DIR
ExecStart=$start_cmd_raw
Restart=on-failure
RestartSec=5s
LimitNPROC=512
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
        chmod 644 "$service_file"
        if systemctl daemon-reload && systemctl enable sing-box; then
             green "已创建并启用 systemd 服务: sing-box.service"
             autostart_set=true
             # 如果之前有 rc.local 或 cron 启动项，移除它们
             if [ -f /etc/rc.local ]; then
                sed -i "\|$start_cmd_raw|d" /etc/rc.local 2>/dev/null || true
             fi
             (crontab -l 2>/dev/null | grep -v "$start_cmd_raw") | crontab - 2>/dev/null || true
        else
             red "创建或启用 systemd 服务失败，将尝试其他方法..."
             rm -f "$service_file" # 清理失败的文件
        fi
    fi

    # 2. 尝试 rc.local (如果 systemd 失败或不可用)
    if [ "$autostart_set" = false ] && [ -f /etc/rc.local ] && [ -x /etc/rc.local ]; then
        log "尝试添加到 /etc/rc.local..."
        # 检查是否已存在（更精确匹配）
        if ! grep -Fq "$start_cmd_raw" /etc/rc.local; then
            # 在 exit 0 之前插入命令
            if sed -i "/^exit 0/i $start_cmd" /etc/rc.local; then
                 green "已添加到 /etc/rc.local 开机自启动"
                 autostart_set=true
                 # 如果之前有 cron 启动项，移除它
                 (crontab -l 2>/dev/null | grep -v "$start_cmd_raw") | crontab - 2>/dev/null || true
            else
                 red "添加到 /etc/rc.local 失败"
            fi
        else
            yellow "/etc/rc.local 中已存在启动命令，跳过添加"
            autostart_set=true # 认为已设置
        fi
    fi

    # 3. 尝试 cron @reboot (如果以上都失败)
    if [ "$autostart_set" = false ] && command -v crontab >/dev/null 2>&1; then
         log "尝试使用 cron @reboot ..."
         # 移除旧的（可能存在的）相同命令
         current_crontab=$(crontab -l 2>/dev/null | grep -v "$start_cmd_raw")
         # 添加新的 @reboot 命令
         new_crontab=$(printf "%s\n%s\n" "$current_crontab" "@reboot $start_cmd")
         # 加载新的 crontab
         echo "$new_crontab" | crontab -
         if crontab -l 2>/dev/null | grep -q "@reboot.*$start_cmd_raw"; then
             green "已通过 cron @reboot 设置开机自启动"
             autostart_set=true
         else
             red "通过 cron @reboot 设置失败"
         fi
    fi

    if [ "$autostart_set" = false ]; then
        red "未能成功设置开机自启动，请手动配置"
        return 1
    fi
    return 0
}

# 选项 1: 安装 sing-box
install_singbox() {
    check_root
    TEMP_DIR=$(mktemp -d) || { red "创建临时目录失败"; return 1; }
    # 确保 cleanup 在退出时执行
    trap 'echo "安装中断，正在清理..."; cleanup; trap - INT TERM EXIT; return 1' INT TERM
    trap 'cleanup; trap - INT TERM EXIT' EXIT # 正常退出时也清理

    ARCH=$(get_arch)
    log "检测到系统架构: $ARCH"

    SYSTEM=$(detect_system)
    log "检测到系统类型: $SYSTEM"

    # 提前安装依赖，确保 jq 和 fzf 等工具可用
    log "准备安装过程，首先确保依赖已安装..."
    install_deps || { red "依赖安装失败，无法继续。"; return 1; }

    # 获取版本列表
    log "正在从 GitHub API 获取最新版本信息..."
    api_url="https://api.github.com/repos/SagerNet/sing-box/releases?per_page=30" # 获取 30 个以确保足够数据
    releases_json=""
    
    # 尝试三次获取 API 数据
    for attempt in 1 2 3; do
        releases_json=$(curl -sSL --connect-timeout 10 --max-time 20 "$api_url")
        if [ -n "$releases_json" ] && echo "$releases_json" | grep -q '"tag_name"'; then
            log "成功获取 GitHub API 数据 (尝试 $attempt)"
            break
        fi
        log "第 $attempt 次尝试获取 GitHub API 数据失败，重试中..."
        sleep 2
    done

    if [ -z "$releases_json" ] || echo "$releases_json" | grep -q '"message": "Not Found"'; then
        red "无法从 GitHub API 获取版本信息（可能是网络问题或 API 限制）。"
        log "API 返回为空或错误"
        # 如果 API 失败，提示手动输入
        while [ -z "$version" ]; do
            printf "请手动输入版本号 (例如 1.9.0 或 1.12.0-beta.2): "
            read manual_version
            if [ -z "$manual_version" ]; then
                red "版本号不能为空，请重新输入。"
                continue
            fi
            validate_version "$manual_version" || continue
            version="$manual_version"
        done
    else
        # 保存原始 JSON 数据到临时文件以便调试
        releases_json_file="$TEMP_DIR/releases.json"
        echo "$releases_json" > "$releases_json_file"
        log "API 返回的原始数据已保存到: $releases_json_file"

        # 清理控制字符
        cleaned_json=$(cat "$releases_json_file" | tr -d '\000-\037')

        # 获取最新的 5 个稳定版和 5 个预发布版
        stable_versions=$(echo "$cleaned_json" | jq -r '.[] | select(.prerelease == false) | [.tag_name, "稳定版", .published_at] | join("\t")' | sort -r -k3 | head -n 5 | awk '{print $1 " - " $2}' | grep -v '^$')
        prerelease_versions=$(echo "$cleaned_json" | jq -r '.[] | select(.prerelease == true) | [.tag_name, "预发布版", .published_at] | join("\t")' | sort -r -k3 | head -n 5 | awk '{print $1 " - " $2}' | grep -v '^$')

        # 调试：记录原始版本列表
        log "提取的稳定版列表: $stable_versions"
        log "提取的预发布版列表: $prerelease_versions"

        # 合并版本列表，使用 printf 避免 -e 问题
        version_list=$(printf "%s\n%s" "$stable_versions" "$prerelease_versions")

        if [ -z "$version_list" ]; then
            yellow "无法解析版本列表，可能是 JSON 格式问题。以下是原始版本号："
            version_list=$(echo "$cleaned_json" | grep -o '"tag_name":\s*"[^"]*"' | sed 's/"tag_name":\s*"\(.*\)"/\1/' | head -n 10)
        fi

        # 使用 fzf 让用户选择版本
        yellow "以下是最新的 5 个稳定版和 5 个预发布版（按发布日期排序）："
        echo "$version_list" | nl -w2 -s '. '
        version=$(echo "$version_list" | fzf --prompt="请选择要安装的 sing-box 版本 > " --height=20 --reverse | awk '{print $1}')

        # 检查 fzf 是否成功选择
        if [ -z "$version" ]; then
            red "未选择任何版本，退出安装。"
            return 1
        fi

        # 验证选择的版本号格式
        if ! validate_version "$version"; then
            red "选择的版本号 '$version' 格式无效，请重新运行脚本选择。"
            return 1
        fi

        log "用户选择的版本: $version"
    fi

    # 去掉版本号可能带的 'v' 前缀
    version=${version#v}
    log "将安装版本: $version"

    # 构建下载 URL
    download_url="https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-${ARCH}.tar.gz"
    log "下载地址: $download_url"

    # 下载并验证（带重试机制）
    printf "正在下载 sing-box v%s...\n" "$version"
    for attempt in 1 2 3; do
        if curl -L --connect-timeout 15 --max-time 120 "$download_url" -o "$TEMP_DIR/sing-box.tar.gz"; then
            green "下载完成 (尝试 $attempt)。"
            break
        fi
        red "下载失败 (尝试 $attempt)，将在 2 秒后重试..."
        sleep 2
        if [ "$attempt" -eq 3 ]; then
            red "下载失败！请检查版本号 '$version' 是否正确，或者网络是否可用。"
            printf "是否重新运行脚本选择版本？(y/n): "
            read retry_version
            if [ "$retry_version" = "y" ] || [ "$retry_version" = "Y" ]; then
                return 2 # 返回特殊值以重新运行
            else
                return 1
            fi
        fi
    done

    # 解压文件
    printf "正在解压文件...\n"
    if ! tar xzf "$TEMP_DIR/sing-box.tar.gz" -C "$TEMP_DIR"; then
        red "解压失败!"
        return 1
    fi
    green "解压完成。"

    # 查找解压后的 sing-box 文件
    extracted_dir=$(find "$TEMP_DIR" -maxdepth 1 -type d -name "sing-box-*-linux-$ARCH")
    if [ -z "$extracted_dir" ] || [ ! -f "$extracted_dir/sing-box" ]; then
        if [ -f "$TEMP_DIR/sing-box" ]; then
            extracted_singbox="$TEMP_DIR/sing-box"
        else
            red "在解压的文件中未找到 sing-box 可执行文件！"
            find "$TEMP_DIR" # 打印临时目录内容帮助调试
            return 1
        fi
    else
        extracted_singbox="$extracted_dir/sing-box"
    fi

    # 创建目标目录并安装
    mkdir -p "$BIN_DIR" "$BASE_DIR"
    log "将 sing-box 安装到 $BIN_DIR/sing-box..."
    if ! cp "$extracted_singbox" "$BIN_DIR/sing-box"; then
        red "复制文件失败！请检查权限。"
        return 1
    fi
    chmod +x "$BIN_DIR/sing-box"
    green "sing-box 可执行文件已安装到 $BIN_DIR/sing-box"

    # 检查 TUN 设备 (非 OpenWrt 系统)
    if [ "$SYSTEM" != "openwrt" ]; then
        log "检查 TUN 设备..."
        if ls /dev/net/tun >/dev/null 2>&1; then
            green "TUN 设备 (/dev/net/tun) 已存在"
        else
            yellow "TUN 设备不存在，尝试创建..."
            modprobe tun || yellow "加载 TUN 内核模块失败，可能内核不支持或未编译"
            mkdir -p /dev/net
            if mknod /dev/net/tun c 10 200; then
                chmod 0666 /dev/net/tun
                if ls /dev/net/tun >/dev/null 2>&1; then
                    green "TUN 设备创建成功 (/dev/net/tun)"
                else
                    red "创建 TUN 设备节点失败，即使 mknod 成功？"
                fi
            else
                red "创建 TUN 设备节点 (mknod) 失败，请检查系统日志"
                yellow "如果需要使用 TUN 模式，请手动配置 TUN 设备"
            fi
        fi
    else
        yellow "检测到 OpenWrt 系统，跳过 TUN 设备检查（通常由系统管理）"
    fi

    # 创建空的配置文件（如果不存在）
    if [ ! -f "$CONFIG_FILE" ]; then
        log "创建空的配置文件 $CONFIG_FILE..."
        echo "{}" > "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
    else
        yellow "配置文件 $CONFIG_FILE 已存在，跳过创建"
    fi

    # 配置网络转发和 NAT
    configure_network

    # 设置开机自启动
    setup_autostart

    gateway_ip=$(get_gateway_ip) || gateway_ip="无法自动获取"

    green "sing-box v$version 安装完成！"
    if [ "$gateway_ip" != "无法自动获取" ]; then
        yellow "如果需要将此设备作为网关，请将其他设备的网关和 DNS 设置为: $gateway_ip"
    fi
    green "下一步：请运行选项 2 来配置订阅链接并首次生成配置。"
    return 0
}

# 选项 2: 更新配置并生成/执行更新脚本（含热重载逻辑）
update_config_and_run() {
    log "开始配置 sing-box 更新任务..."
    check_root # 确保 root 权限

    # 1. 加载或设置环境变量 (SUBSCRIBE_URLS 是必须的)
    if ! load_env; then
        red "无法加载或设置必要的环境变量 (特别是 SUBSCRIBE_URLS)。"
        red "请确保 $ENV_FILE 文件存在且包含 SUBSCRIBE_URLS，或者重新运行选项2进行设置。"
        return 1
    fi

    # 2. 生成 update-singbox.sh 脚本 (内置热重载逻辑)
    log "正在生成更新脚本: $UPDATE_SCRIPT (包含热重载逻辑)..."
    # 使用 cat 和 EOF 创建脚本，注意变量转义 \$
    # 这个脚本是独立运行的，需要包含所有必要的函数和变量加载逻辑
    cat <<EOF > "$UPDATE_SCRIPT"
#!/bin/sh
set -eu

# === sing-box 自动更新脚本 ===
# 由主脚本生成于 $(date)
# 功能：从订阅链接下载配置，验证后热重载 sing-box 或在需要时启动。

# --- 配置变量 ---
# 从环境变量文件加载实际值
ENV_FILE="$HOME/.singbox_env" # 和主脚本保持一致
CONFIG_PATH="" # 将从 ENV_FILE 加载
UPDATE_LOG_FILE="" # 将从 ENV_FILE 加载
WX_WEBHOOK="" # 将从 ENV_FILE 加载
SINGBOX_BIN_PATH="" # 将从 ENV_FILE 加载
SUBSCRIBE_URLS="" # 将从 ENV_FILE 加载

# --- 内部变量 ---
TIMESTAMP=\$(date +'%Y-%m-%d %H:%M:%S')
DEVICE_NAME="\$(hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null || echo 'unknown-device')"

# --- 日志和颜色函数 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

_log() {
    printf "%b[%s] %s%b\\n" "\$YELLOW" "\$TIMESTAMP" "\$1" "\$NC" # 输出到控制台
    echo "[\$TIMESTAMP] \$1" >> "\$UPDATE_LOG_FILE" # 记录到日志文件
}
red_log() { printf "%b%s%b\\n" "\$RED" "\$1" "\$NC"; echo "[\$TIMESTAMP] ERROR: \$1" >> "\$UPDATE_LOG_FILE"; }
green_log() { printf "%b%s%b\\n" "\$GREEN" "\$1" "\$NC"; echo "[\$TIMESTAMP] SUCCESS: \$1" >> "\$UPDATE_LOG_FILE"; }
yellow_log() { printf "%b%s%b\\n" "\$YELLOW" "\$1" "\$NC"; echo "[\$TIMESTAMP] INFO: \$1" >> "\$UPDATE_LOG_FILE"; }


# --- 核心功能函数 ---

# 加载环境变量
load_env_vars() {
    if [ ! -f "\$ENV_FILE" ]; then
        red_log "环境变量文件 \$ENV_FILE 未找到！无法继续。"
        exit 1
    fi
    # shellcheck source=/dev/null
    . "\$ENV_FILE" # 加载变量
    # 检查必要变量
    if [ -z "\$CONFIG_PATH" ] || [ -z "\$UPDATE_LOG_FILE" ] || [ -z "\$SINGBOX_BIN_PATH" ] || [ -z "\$SUBSCRIBE_URLS" ]; then
        red_log "环境变量文件 \$ENV_FILE 中缺少必要的变量 (CONFIG_PATH, UPDATE_LOG_FILE, SINGBOX_BIN_PATH, SUBSCRIBE_URLS)。"
        exit 1
    fi
    # 确保日志目录存在
    mkdir -p "\$(dirname "\$UPDATE_LOG_FILE")"
    _log "环境变量加载成功。"
}

# 限制日志文件行数
limit_log_lines() {
    max_lines=1000 # 保留最近 1000 行
    if [ -f "\$UPDATE_LOG_FILE" ]; then
        current_lines=\$(wc -l < "\$UPDATE_LOG_FILE")
        if [ "\$current_lines" -gt "\$max_lines" ]; then
            _log "日志文件超过 \$max_lines 行，正在裁剪..."
            tail -n "\$max_lines" "\$UPDATE_LOG_FILE" > "\$UPDATE_LOG_FILE.tmp" && \
            mv "\$UPDATE_LOG_FILE.tmp" "\$UPDATE_LOG_FILE" && \
            _log "日志文件已裁剪至最近 \$max_lines 行。" || \
            red_log "裁剪日志文件失败！"
        fi
    fi
}

# 企业微信通知 (仅在 WX_WEBHOOK 设置时发送)
send_msg() {
    local message_content="\$1"
    if [ -z "\$WX_WEBHOOK" ]; then
        # yellow_log "未配置企业微信 Webhook，跳过通知。" # 不在日志里重复太多这个信息
        return
    fi
    # 准备 JSON
    json_payload=\$(printf '{"msgtype":"text","text":{"content":"[设备: %s] sing-box 更新脚本通知：\\n%s"}}' "\$DEVICE_NAME" "\$message_content")
    _log "正在尝试发送企业微信通知..."
    # 发送请求
    if curl -sSf -H "Content-Type: application/json" --connect-timeout 10 --max-time 20 -d "\$json_payload" "\$WX_WEBHOOK" >/dev/null; then
        _log "企业微信通知发送成功。"
    else
        ret_code=\$?
        red_log "企业微信通知发送失败 (curl 退出码: \$ret_code)。"
    fi
}

# 检查并安装 jq (如果不存在)
install_jq_if_needed() {
    if command -v jq >/dev/null 2>&1; then
        return 0 # jq 已安装
    fi
    _log "未检测到 jq 命令，尝试自动安装..."
    pkg_cmd=""
    if command -v apt >/dev/null 2>&1; then pkg_cmd="apt update && apt install -y jq";
    elif command -v yum >/dev/null 2>&1; then pkg_cmd="yum install -y jq";
    elif command -v apk >/dev/null 2>&1; then pkg_cmd="apk add jq";
    elif command -v opkg >/dev/null 2>&1; then pkg_cmd="opkg update && opkg install jq";
    fi

    if [ -n "\$pkg_cmd" ]; then
        if eval "\$pkg_cmd"; then
             _log "jq 安装成功。"
        else
             red_log "自动安装 jq 失败！请手动安装 jq。"
             exit 1
        fi
    else
        red_log "未知的包管理器，无法自动安装 jq。请手动安装。"
        exit 1
    fi
}

# 验证配置文件 (接受文件路径作为参数)
validate_config() {
    local file_to_check="\$1"
    if [ ! -s "\$file_to_check" ]; then # 检查文件是否存在且非空
        red_log "配置文件 '\$file_to_check' 不存在或为空。"
        return 1
    fi
    # 使用 jq 检查 JSON 语法是否有效
    if jq -e . "\$file_to_check" >/dev/null 2>&1; then
        _log "配置文件 '\$file_to_check' JSON 语法有效。"
        # 这里可以添加更多 sing-box 特定的检查，例如 .outbounds 是否存在且为数组
        # if ! jq -e '.outbounds | type == "array"' "\$file_to_check" >/dev/null 2>&1; then
        #    red_log "配置文件 '\$file_to_check' 缺少有效的 '.outbounds' 数组。"
        #    return 1
        # fi
        return 0 # 验证通过
    else
        error_msg=\$(jq . "\$file_to_check" 2>&1) # 获取 jq 的错误信息
        red_log "配置文件 '\$file_to_check' JSON 格式无效！错误: \$error_msg"
        return 1 # 验证失败
    fi
}

# 获取节点数量 (从指定配置文件)
get_node_count() {
    # 检查 .outbounds 是否为数组，然后获取长度
    if jq -e '.outbounds | type == "array"' "\$CONFIG_PATH" >/dev/null 2>&1; then
        jq '.outbounds | length' "\$CONFIG_PATH"
    else
        echo "0" # 如果 .outbounds 不是数组或不存在，返回 0
    fi
}

# 备份当前配置文件
backup_config() {
    backup_file="\${CONFIG_PATH}.bak"
    if [ -f "\$CONFIG_PATH" ]; then
        if cp "\$CONFIG_PATH" "\$backup_file"; then
             _log "当前配置文件已备份到: \$backup_file"
        else
             red_log "备份配置文件失败！"
        fi
    else
        _log "原始配置文件不存在，跳过备份。"
    fi
}

# 还原备份的配置文件
restore_config() {
    backup_file="\${CONFIG_PATH}.bak"
    if [ -f "\$backup_file" ]; then
        if cp "\$backup_file" "\$CONFIG_PATH"; then
             yellow_log "已从备份文件 \$backup_file 还原配置。"
             return 0
        else
             red_log "从备份文件还原配置失败！"
             return 1
        fi
    else
        red_log "备份文件 \$backup_file 不存在，无法还原。"
        return 1
    fi
}

# 停止 sing-box 服务 (更新脚本内部使用)
_stop_singbox() {
    yellow_log "尝试停止 sing-box..."
    # 使用 pkill 查找精确命令
    if pkill -f "\$SINGBOX_BIN_PATH run -c \$CONFIG_PATH"; then
        sleep 2
        if pgrep -f "\$SINGBOX_BIN_PATH run -c \$CONFIG_PATH" >/dev/null 2>&1; then
            yellow_log "进程仍在运行，强制停止 (SIGKILL)..."
            pkill -9 -f "\$SINGBOX_BIN_PATH run -c \$CONFIG_PATH" || true
            sleep 1
        fi
        _log "sing-box 进程已停止。"
    else
        _log "sing-box 未运行。"
    fi
}

# 启动 sing-box 服务 (更新脚本内部使用)
_start_singbox() {
    if [ ! -r "\$CONFIG_PATH" ]; then red_log "配置文件 \$CONFIG_PATH 不可读!"; return 1; fi
    if [ ! -x "\$SINGBOX_BIN_PATH" ]; then red_log "执行文件 \$SINGBOX_BIN_PATH 不可执行!"; return 1; fi
    _stop_singbox # 确保旧进程已停止
    yellow_log "正在使用 nohup 启动 sing-box..."
    # 在后台启动，忽略 SIGHUP 信号，并将标准输出和错误重定向到日志文件
    nohup "\$SINGBOX_BIN_PATH" run -c "\$CONFIG_PATH" >> "\$UPDATE_LOG_FILE" 2>&1 &
    sleep 3 # 等待启动
    # 检查是否成功启动
    if pgrep -f "\$SINGBOX_BIN_PATH run -c \$CONFIG_PATH" >/dev/null 2>&1; then
        pid=\$(pgrep -f "\$SINGBOX_BIN_PATH run -c \$CONFIG_PATH")
        green_log "sing-box 启动成功 (PID: \$pid)。"
        return 0
    else
        red_log "sing-box 启动失败！请检查日志文件 \$UPDATE_LOG_FILE 获取详细错误。"
        # 尝试读取日志最后几行
        tail -n 10 "\$UPDATE_LOG_FILE"
        return 1
    fi
}

# 热重载或启动 sing-box
reload_or_start_singbox() {
    singbox_pid=\$(pgrep -f "\$SINGBOX_BIN_PATH run -c \$CONFIG_PATH" 2>/dev/null)

    if [ -n "\$singbox_pid" ]; then
        yellow_log "sing-box (PID: \$singbox_pid) 正在运行。发送 SIGHUP 信号尝试热重载..."
        if kill -HUP "\$singbox_pid"; then
            sleep 2 # 等待重载
            # 验证进程是否还在
            if kill -0 "\$singbox_pid" >/dev/null 2>&1; then
                green_log "SIGHUP 信号已发送，sing-box 仍在运行 (PID: \$singbox_pid)。假定热重载成功。"
                return 0 # 热重载成功
            else
                red_log "sing-box 在发送 SIGHUP 后停止运行！可能是新配置有问题。"
                send_msg "❌ 热重载失败，sing-box 进程消失！"
                # 尝试恢复备份并重启
                yellow_log "尝试恢复备份配置并重启..."
                if restore_config; then
                     if _start_singbox; then
                         yellow_log "已使用备份配置重启 sing-box。"
                         send_msg "⚠️ 已使用备份配置重启 sing-box。"
                         return 1 # 指示重载失败，但已尝试恢复
                     else
                         red_log "使用备份配置重启也失败了！"
                         send_msg "❌ 使用备份配置重启也失败了！请检查系统。"
                         return 1 # 启动失败
                     fi
                else
                    red_log "恢复备份配置失败，无法重启。"
                    send_msg "❌ 恢复备份配置失败，无法重启！"
                    return 1 # 恢复失败
                fi
            fi
        else
            red_log "发送 SIGHUP 信号到 PID \$singbox_pid 失败！"
            send_msg "❌ 发送 SIGHUP 信号失败！"
            # 可以选择在这里尝试停止并启动，或者仅报告错误
            yellow_log "将尝试停止并重新启动..."
            if _start_singbox; then
                 return 0 # 停止并启动成功
            else
                 return 1 # 停止并启动失败
            fi
        fi
    else
        yellow_log "sing-box 未运行。将尝试启动..."
        if _start_singbox; then
            return 0 # 启动成功
        else
            return 1 # 启动失败
        fi
    fi
}


# --- 主更新逻辑 ---
run_update() {
    _log "=== 开始执行 sing-box 配置更新 ==="
    final_message="📡 sing-box 更新报告 (\$(date +'%H:%M:%S'))"
    overall_success=false # 标记整个更新过程是否最终成功
    config_applied_and_reloaded=false # 标记是否成功应用并重载/启动了新配置

    # 创建临时文件用于下载
    TEMP_CONFIG_PATH="\${CONFIG_PATH}.tmp.\$\$" # 添加进程ID确保临时文件唯一性

    # 遍历所有订阅链接
    for sub_url in \$SUBSCRIBE_URLS; do
        yellow_log "处理订阅链接: \$sub_url"
        # 下载配置到临时文件
        if curl -kfsSL --connect-timeout 20 --max-time 90 --retry 2 "\$sub_url" -o "\$TEMP_CONFIG_PATH"; then
            _log "成功从 \$sub_url 下载配置到临时文件。"
            # 验证下载的配置文件
            if validate_config "\$TEMP_CONFIG_PATH"; then
                green_log "下载的配置文件 \$TEMP_CONFIG_PATH 验证通过。"
                # 备份当前配置文件
                backup_config
                # 用新配置覆盖当前配置
                if mv "\$TEMP_CONFIG_PATH" "\$CONFIG_PATH"; then
                     green_log "新配置已成功应用到 \$CONFIG_PATH。"
                     # 尝试热重载或启动
                     if reload_or_start_singbox; then
                         node_count=\$(get_node_count)
                         green_log "热重载/启动成功。检测到节点数: \$node_count。"
                         final_message="\$final_message\n✅ 成功从 [\$sub_url] 更新并热重载/启动。\n   节点数: \$node_count。"
                         overall_success=true
                         config_applied_and_reloaded=true
                     else
                         red_log "热重载或启动失败 (来自 \$sub_url)。"
                         # reload_or_start_singbox 内部已尝试恢复和发送消息
                         final_message="\$final_message\n❌ 热重载/启动失败 (来自 \$sub_url)。已尝试恢复旧配置。"
                         overall_success=false # 即使下载验证成功，重载失败也算失败
                     fi
                else
                     red_log "移动临时文件 \$TEMP_CONFIG_PATH 到 \$CONFIG_PATH 失败！权限问题？"
                     final_message="\$final_message\n❌ 应用新配置失败 (来自 \$sub_url)。"
                     overall_success=false
                     # 尝试清理临时文件
                     rm -f "\$TEMP_CONFIG_PATH"
                fi
                # 无论成功与否，处理完一个有效的订阅链接后就退出循环
                break
            else
                red_log "从 \$sub_url 下载的配置未能通过验证。"
                final_message="\$final_message\n❌ 验证失败 (来自 \$sub_url)。"
                # 清理无效的临时文件
                rm -f "\$TEMP_CONFIG_PATH"
            fi
        else
            ret_code=\$?
            red_log "从 \$sub_url 下载配置失败 (curl 退出码: \$ret_code)。"
            final_message="\$final_message\n❌ 下载失败 (来自 \$sub_url)。"
            # 确保清理临时文件
            rm -f "\$TEMP_CONFIG_PATH"
        fi
    done # 订阅链接循环结束

    # 清理可能残留的临时文件
    rm -f "\$TEMP_CONFIG_PATH"

    # 根据最终状态发送总结通知
    if [ "\$overall_success" = true ] && [ "\$config_applied_and_reloaded" = true ]; then
         green_log "更新过程成功完成。"
    elif [ "\$config_applied_and_reloaded" = false ]; then
         # 如果从未成功应用和重载过新配置（所有链接都失败了）
         red_log "所有订阅链接处理失败，sing-box 配置未改变。"
         final_message="\$final_message\n❌ 所有订阅链接均未能成功更新配置。"
         # 检查 sing-box 是否仍在运行（如果之前就在运行）
         if pgrep -f "\$SINGBOX_BIN_PATH run -c \$CONFIG_PATH" >/dev/null 2>&1; then
              yellow_log "sing-box 仍在运行旧配置。"
              final_message="\$final_message (sing-box 仍在运行旧配置)"
         else
              yellow_log "sing-box 当前未运行。"
              final_message="\$final_message (sing-box 当前未运行)"
         fi
    else
         # 应用了新配置，但重载/启动环节失败了（上面循环中已处理恢复逻辑）
         red_log "更新过程中发生错误，已尝试恢复到先前状态。"
    fi

    _log "=== sing-box 配置更新执行完毕 ==="
    send_msg "\$final_message" # 发送最终的总结通知

    # 返回最终状态码
    if [ "\$overall_success" = true ]; then return 0; else return 1; fi
}

# --- 脚本入口 ---
main() {
    # 1. 加载环境变量
    load_env_vars

    # 2. 限制日志文件大小
    limit_log_lines

    # 3. 检查并安装 jq
    install_jq_if_needed

    # 4. 执行更新逻辑
    if run_update; then
        exit 0 # 成功退出
    else
        exit 1 # 失败退出
    fi
}

# 执行主函数
main

EOF
    # --- Heredoc 结束 ---

    # 赋予更新脚本执行权限
    chmod +x "$UPDATE_SCRIPT"
    green "更新脚本 $UPDATE_SCRIPT 已生成并设置执行权限。"

    # 3. 立即执行一次更新脚本
    log "立即执行一次更新脚本 $UPDATE_SCRIPT ..."
    if "$UPDATE_SCRIPT"; then
        green "首次配置更新执行成功！"
        # 检查网络是否仍然通畅
        check_network || yellow "警告：更新后网络检查失败，请核实配置是否生效或存在问题。"
        yellow "你可以检查更新脚本的日志文件获取详细信息: $UPDATE_LOG_FILE"
        # 提示 Web UI（如果用户可能需要）
        yellow "如果你的配置中启用了 Clash API (experimental.clash_api)，"
        yellow "默认 Web UI 地址通常是: http://<设备IP>:9090/ui (例如 Yacd, Metacubexd)"
        return 0
    else
        red "首次配置更新执行失败！"
        red "请检查主脚本日志 ($LOG_FILE) 和更新脚本日志 ($UPDATE_LOG_FILE) 以获取详细错误信息。"
        return 1
    fi
}


# 选项 3: 设置定时更新（使用生成的 UPDATE_SCRIPT）
setup_scheduled_update() {
    check_root
    if [ ! -f "$UPDATE_SCRIPT" ]; then
        red "错误：更新脚本 $UPDATE_SCRIPT 不存在。"
        red "请先运行选项 2 来生成更新脚本并进行初始配置。"
        return 1
    fi
    if ! command -v crontab >/dev/null 2>&1; then
        red "错误：crontab 命令未找到，无法设置定时任务。"
        red "请确保 cron 服务已安装并运行。"
        return 1
    fi

    log "配置定时更新任务..."

    # 显示当前相关的定时任务
    yellow "当前 crontab 中与 $UPDATE_SCRIPT 相关的任务:"
    crontab -l 2>/dev/null | grep "$UPDATE_SCRIPT" || echo " (无)"

    # 询问操作：添加/修改 或 清除
    printf "请选择操作：[1] 添加/修改定时任务 [2] 清除定时任务 [其他] 取消 : "
    read cron_action
    case "$cron_action" in
        1) # 添加或修改
            default_cron_expr="0 4 * * *" # 默认每天凌晨4点
            printf "请输入 cron 表达式 [例如 '0 4 * * *' 表示每天凌晨4点，默认: %s]: " "$default_cron_expr"
            read cron_expr
            cron_expr=${cron_expr:-$default_cron_expr} # 使用默认值如果输入为空

            # 验证 cron 表达式的基本格式 (非常基础的检查)
            if ! echo "$cron_expr" | grep -Eq '^([0-9*,/-]+ +){4}[0-9*,/-]+$'; then
                 red "输入的 Cron 表达式 '$cron_expr' 格式似乎不正确，请重新输入。"
                 return 1
            fi

            log "准备将任务 '$cron_expr $UPDATE_SCRIPT' 添加到 crontab..."
            # 使用临时文件确保原子性操作，并避免重复添加
            temp_cron_file=$(mktemp)
            # 获取当前 crontab 内容，并移除所有旧的 $UPDATE_SCRIPT 任务
            crontab -l 2>/dev/null | grep -v "$UPDATE_SCRIPT" > "$temp_cron_file" || true
            # 添加新的任务
            echo "$cron_expr $UPDATE_SCRIPT" >> "$temp_cron_file"
            # 加载新的 crontab
            if crontab "$temp_cron_file"; then
                 green "定时任务已成功设置为: $cron_expr $UPDATE_SCRIPT"
                 rm -f "$temp_cron_file"
                 return 0
            else
                 red "设置定时任务失败！请检查 crontab 服务和权限。"
                 rm -f "$temp_cron_file"
                 return 1
            fi
            ;;
        2) # 清除
            log "准备清除所有与 $UPDATE_SCRIPT 相关的定时任务..."
            temp_cron_file=$(mktemp)
            # 获取当前 crontab 内容，并移除所有 $UPDATE_SCRIPT 任务
            crontab -l 2>/dev/null | grep -v "$UPDATE_SCRIPT" > "$temp_cron_file" || true
            # 加载清理后的 crontab
            if crontab "$temp_cron_file"; then
                 green "已成功清除所有相关的定时任务。"
                 rm -f "$temp_cron_file"
                 return 0
            else
                 red "清除定时任务失败！请检查 crontab 服务和权限。"
                 rm -f "$temp_cron_file"
                 return 1
            fi
            ;;
        *) # 取消
            yellow "操作已取消。"
            return 0
            ;;
    esac
}


# 选项 4: 查看状态并控制运行 (启动/停止/重启)
manage_service() {
    check_root
    status="未知"
    pid=""
    # 使用 pgrep 查找进程
    # 添加 || true 防止在进程未找到时 set -e 退出脚本
    pgrep_output=$(pgrep -f "$BIN_DIR/sing-box run -c $CONFIG_FILE" || true)
    pgrep_status=$? # 保存 pgrep 的退出状态

    if [ $pgrep_status -eq 0 ] && [ -n "$pgrep_output" ]; then
        pid=$pgrep_output
        status="active (running)"
        green "sing-box 当前状态: $status (PID: $pid)"
    elif [ $pgrep_status -eq 1 ]; then # pgrep 退出码 1 表示未找到
        status="inactive (dead)"
        red "sing-box 当前状态: $status"
    else # 其他非零退出码表示 pgrep 命令本身出错
        status="error (pgrep failed with status $pgrep_status)"
        red "无法确定 sing-box 状态 (pgrep 错误)"
    fi

    # 提供操作选项
    printf "请选择操作：[1] 启动 sing-box [2] 停止 sing-box [3] 重启 sing-box [其他] 返回菜单 : "
    read action
    case "$action" in
        1) # 启动
            if [ "$status" = "active (running)" ]; then
                yellow "sing-box 已经在运行 (PID: $pid)。"
            else
                log "手动启动 sing-box..."
                # 调用修改后的 start_singbox
                if start_singbox; then
                     green "sing-box 启动命令已执行，请稍后再次检查状态。"
                else
                     red "sing-box 启动失败。"
                     # start_singbox 内部会打印更详细的日志
                fi
            fi
            ;;
        2) # 停止
            if [ "$status" = "inactive (dead)" ]; then
                yellow "sing-box 已经停止。"
            elif [ "$status" = "active (running)" ]; then
                log "手动停止 sing-box..."
                # 调用修改后的 stop_singbox
                if stop_singbox; then
                     green "sing-box 停止成功。"
                else
                     red "sing-box 停止失败。"
                fi
            else
                yellow "sing-box 状态未知或错误，无法执行停止操作。"
            fi
            ;;
        3) # 重启
             log "手动重启 sing-box..."
             # 调用修改后的函数
             if stop_singbox; then
                  log "旧进程已停止，等待后启动新进程..."
                  sleep 1 # 短暂等待
                  if start_singbox; then
                      green "sing-box 重启命令已执行，请稍后再次检查状态。"
                  else
                      red "sing-box 重启失败（停止后未能启动）。"
                  fi
             else
                  red "sing-box 重启失败（未能停止旧进程）。"
             fi
            ;;
        *) # 返回
            yellow "返回主菜单。"
            ;;
    esac
    # 不需要显式 return 0 或 1 了，函数自然结束即可
}

# 选项 5: 卸载 sing-box
uninstall_singbox() {
    check_root
    red "！！！警告！！！"
    red "这将停止 sing-box 服务，删除其可执行文件、配置文件、环境变量、"
    red "更新脚本、定时任务、自启动设置，并尝试移除相关的 NAT 规则。"
    printf "确定要卸载 sing-box 吗？请输入 'yes' 确认: "
    read confirmation
    if [ "$confirmation" != "yes" ]; then
        yellow "卸载操作已取消。"
        return
    fi

    log "开始卸载 sing-box..."

    # 1. 停止服务
    log "停止 sing-box 服务..."
    stop_singbox

    # 2. 禁用并删除 systemd 服务 (如果存在)
    if command -v systemctl >/dev/null 2>&1 && [ -f /etc/systemd/system/sing-box.service ]; then
        log "禁用并删除 systemd 服务..."
        systemctl stop sing-box.service 2>/dev/null || true
        systemctl disable sing-box.service 2>/dev/null || true
        rm -f /etc/systemd/system/sing-box.service
        systemctl daemon-reload 2>/dev/null || true
        systemctl reset-failed 2>/dev/null || true
        green "systemd 服务已移除。"
    fi

    # 3. 移除 crontab 定时任务
    log "移除 crontab 定时任务..."
    if command -v crontab >/dev/null 2>&1; then
         (crontab -l 2>/dev/null | grep -v "$UPDATE_SCRIPT" | grep -v "$BIN_DIR/sing-box") | crontab - 2>/dev/null || true
         green "相关的 crontab 任务已移除。"
    fi

    # 4. 移除 rc.local 启动项
    log "移除 /etc/rc.local 启动项..."
    if [ -f /etc/rc.local ]; then
        # 使用 sed -i 需要小心，确保路径分隔符不冲突，使用 # 作为分隔符
        sed -i "\#$BIN_DIR/sing-box#d" /etc/rc.local 2>/dev/null || true
        green "/etc/rc.local 中的启动项已尝试移除。"
    fi

    # 5. 删除文件和目录
    log "删除相关文件和目录..."
    rm -f "$BIN_DIR/sing-box" # 删除可执行文件
    rm -f "$UPDATE_SCRIPT"   # 删除更新脚本
    rm -rf "$BASE_DIR"       # 删除配置目录 (包含 config.json 和可能的 .bak)
    rm -f "$ENV_FILE"        # 删除环境变量文件
    rm -f "/var/log/sing-box-update.log" # 删除默认的更新日志
    rm -f "$LOG_FILE" # 删除主脚本日志
    green "相关文件和目录已删除。"

    # 6. 尝试移除 NAT 规则
    log "尝试移除 NAT 规则 (MASQUERADE for 192.168.0.0/16)..."
    if iptables -t nat -D POSTROUTING -s 192.168.0.0/16 -j MASQUERADE 2>/dev/null; then
         green "NAT 规则已移除。"
         # 尝试重新保存 iptables 规则
         if command -v iptables-save >/dev/null 2>&1; then
             if iptables-save > /etc/iptables/rules.v4; then
                  green "iptables 规则已重新保存。"
             else
                  red "重新保存 iptables 规则失败。"
             fi
         fi
    else
        yellow "未找到匹配的 NAT 规则，或移除失败。"
    fi

    green "sing-box 卸载完成。"
    yellow "请注意：系统 IP 转发设置 (net.ipv4.ip_forward=1) 未被禁用，"
    yellow "如果您不再需要，请手动修改 /etc/sysctl.conf 并运行 'sysctl -p'。"
}


# 主菜单
main_menu() {
    while true; do
        printf "\n%b=== sing-box 管理脚本 (v1.1 - 热更新版) ===%b\n" "$GREEN" "$NC"
        echo " 1. 安装 sing-box (自动获取最新版或指定版本)"
        echo " 2. 配置订阅链接并首次运行/更新 (生成热更新脚本)"
        echo " 3. 设置/管理定时自动更新任务"
        echo " 4. 查看 sing-box 状态 / 手动 启动 | 停止 | 重启"
        echo " 5. 卸载 sing-box"
        echo " 6. 退出脚本"
        printf "%b============================================%b\n" "$GREEN" "$NC"
        printf "请输入选项 [1-6]: "
        read choice

        exit_code=0 # 用于记录函数执行结果
        case "$choice" in
            1)
                install_singbox || exit_code=$?
                ;;
            2)
                update_config_and_run || exit_code=$?
                ;;
            3)
                setup_scheduled_update || exit_code=$?
                ;;
            4)
                manage_service || exit_code=$? # 虽然 manage_service 不明确返回错误码，但可以捕获 set -e 的退出
                ;;
            5)
                uninstall_singbox || exit_code=$?
                ;;
            6)
                green "正在退出脚本..."
                exit 0 # 正常退出
                ;;
            *)
                red "无效选项 '$choice'，请输入 1 到 6 之间的数字。"
                exit_code=1 # 无效选项也算一种“失败”
                ;;
        esac

        # 如果函数执行失败 (非0退出码)，打印提示信息
        if [ "$exit_code" -ne 0 ] && [ "$choice" -ne 6 ]; then
             yellow "操作执行期间可能遇到问题 (退出码: $exit_code)，请检查日志: $LOG_FILE"
        fi

        # 在每个操作后暂停，等待用户按 Enter 继续 (选项6除外)
        if [ "$choice" -ne 6 ]; then
            printf "\n按 [Enter] 键返回主菜单..."
            read -r dummy_input
        fi
    done
}

# --- 脚本入口 ---
# 确保日志文件可写
# 检查日志目录是否存在
log_dir=$(dirname "$LOG_FILE")
if [ ! -d "$log_dir" ]; then
    mkdir -p "$log_dir" || { echo "错误: 无法创建日志目录 $log_dir"; exit 1; }
fi
touch "$LOG_FILE" 2>/dev/null || { echo "错误: 无法写入日志文件 $LOG_FILE，请检查权限。"; exit 1; }

# 记录脚本启动
log "=== 主脚本启动 ==="

# 运行主菜单
main_menu

# 脚本正常退出时记录日志 (理论上 main_menu 的 exit 0 会先执行)
log "=== 主脚本正常退出 ==="
exit 0
