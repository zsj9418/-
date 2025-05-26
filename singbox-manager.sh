#!/bin/sh
set -eu

# 定义颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# 可配置路径和默认值
BASE_DIR="/etc/sing-box"
BIN_DIR="/usr/bin"
CONFIG_FILE="$BASE_DIR/config.json"
ENV_FILE="$BASE_DIR/singbox_env"
LOG_FILE="/var/log/sing-box-script.log"
SCRIPT_PATH="$0"
UPDATE_SCRIPT="$BASE_DIR/update-singbox.sh"

# 获取设备名称
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

# 日志记录函数
log() {
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    printf "%b[%s] %s%b\n" "$YELLOW" "$timestamp" "$1" "$NC"
    echo "[$timestamp] $1" >> "$LOG_FILE"
}

# 彩色输出函数
red() { printf "%b%s%b\n" "$RED" "$1" "$NC"; }
green() { printf "%b%s%b\n" "$GREEN" "$1" "$NC"; }
yellow() { printf "%b%s%b\n" "$YELLOW" "$1" "$NC"; }

# 检查 root 用户
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        red "此脚本必须以 root 用户运行"
        exit 1
    fi
}

# 获取架构信息
get_arch() {
    case $(uname -m) in
        x86_64)   echo "amd64" ;;
        aarch64)  echo "arm64" ;;
        armv7l)   echo "armv7" ;;
        armv5*)   echo "armv5" ;;
        armv6*)   echo "armv6" ;;
        mips)     echo "mips" ;;
        mipsel)   echo "mipsel" ;;
        riscv64)  echo "riscv64" ;;
        *)        red "不支持的架构: $(uname -m)"; exit 1 ;;
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

# 安装依赖
install_deps() {
    log "正在检查并安装依赖..."
    pkg_manager=""
    install_cmd=""
    update_cmd=""
    pkgs="curl tar jq psmisc kmod-ipt-tproxy"
    cron_pkg="cron"
    installed_pkgs=""
    failed_pkgs=""
    # 检测包管理器
    if command -v opkg >/dev/null 2>&1; then
        pkg_manager="opkg"
        update_cmd="opkg update"
        install_cmd="opkg install"
    elif command -v apt >/dev/null 2>&1; then
        pkg_manager="apt"
        update_cmd="apt update"
        install_cmd="apt install -y"
        pkgs="curl tar iptables ipset jq psmisc cron fzf"
    elif command -v yum >/dev/null 2>&1; then
        pkg_manager="yum"
        update_cmd=""
        install_cmd="yum install -y"
        cron_pkg="cronie"
        pkgs="curl tar iptables ipset jq psmisc cronie fzf"
    elif command -v apk >/dev/null 2>&1; then
        pkg_manager="apk"
        update_cmd="apk update"
        install_cmd="apk add"
        cron_pkg="cronie"
        pkgs="curl tar iptables ipset jq psmisc cronie fzf"
    else
        red "不支持的包管理器，请手动安装依赖"
        return 1
    fi
    # 替换 cron 包名
    pkgs=$(echo "$pkgs" | sed "s/cron/$cron_pkg/")
    log "使用包管理器: $pkg_manager"
    # 更新软件源
    if [ -n "$update_cmd" ]; then
        $update_cmd || { red "包列表更新失败"; return 1; }
    fi
    # 安装每个包
    for pkg in $pkgs; do
        if [ "$pkg_manager" = "opkg" ]; then
            if opkg list | grep -q "^$pkg -"; then
                if $install_cmd $pkg 2>>"$LOG_FILE"; then
                    installed_pkgs="$installed_pkgs $pkg"
                    log "已安装或更新包: $pkg"
                else
                    failed_pkgs="$failed_pkgs $pkg"
                    log "安装包失败: $pkg"
                fi
            else
                failed_pkgs="$failed_pkgs $pkg"
                log "包不可用: $pkg"
            fi
        else
            if $install_cmd $pkg 2>>"$LOG_FILE"; then
                installed_pkgs="$installed_pkgs $pkg"
                log "已安装或更新包: $pkg"
            else
                failed_pkgs="$failed_pkgs $pkg"
                log "安装包失败: $pkg"
            fi
        fi
    done
    # 检查 fzf
    if ! command -v fzf >/dev/null 2>&1; then
        red "未检测到 fzf，请手动安装"
        failed_pkgs="$failed_pkgs fzf"
    else
        installed_pkgs="$installed_pkgs fzf"
    fi
    # 清理包列表
    installed_pkgs=$(echo "$installed_pkgs" | sed 's/^ //')
    failed_pkgs=$(echo "$failed_pkgs" | sed 's/^ //')
    # 处理依赖安装失败
    if [ -n "$failed_pkgs" ]; then
        red "依赖安装失败：部分包未找到或无法安装"
        yellow "已安装的包：${installed_pkgs:-无}"
        yellow "未安装的包：${failed_pkgs:-无}"
        yellow "请尝试运行 'opkg update' 或手动安装缺失包"
        printf "是否继续安装 sing-box？(y/n): "
        read continue_install
        if [ "$continue_install" = "y" ] || [ "$continue_install" = "Y" ]; then
            yellow "用户选择继续安装"
            return 0
        else
            red "用户取消安装"
            return 1
        fi
    else
        green "依赖安装完成"
        return 0
    fi
}

# 获取网关 IP
get_gateway_ip() {
    iface=$(ip route show default | awk '/default/ {print $5}' | head -n 1)
    if [ -z "$iface" ]; then
        red "无法获取默认网络接口"
        for iface_try in eth0 br-lan; do
            if ip addr show dev "$iface_try" >/dev/null 2>&1; then
                gw_ip=$(ip addr show dev "$iface_try" | awk '/inet / {print $2}' | cut -d'/' -f1 | head -n 1)
                if [ -n "$gw_ip" ]; then
                    yellow "使用接口 $iface_try 的 IP: $gw_ip"
                    echo "$gw_ip"
                    return 0
                fi
            fi
        done
        red "无法从常见接口获取 IP"
        return 1
    fi
    gw_ip=$(ip addr show dev "$iface" | awk '/inet / {print $2}' | cut -d'/' -f1 | head -n 1)
    if [ -z "$gw_ip" ]; then
        red "在接口 $iface 上找不到 IPv4 地址"
        return 1
    fi
    echo "$gw_ip"
}

# 验证版本号
validate_version() {
    version="$1"
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
trap 'echo "脚本意外中断，执行清理..."; cleanup; exit 1' INT TERM EXIT

# 检查网络
check_network() {
    log "检查网络通畅性..."
    if ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1; then
        green "网络连接正常 (ping 8.8.8.8)"
        return 0
    else
        log "ping 8.8.8.8 失败，尝试 curl..."
        if curl -s --head --connect-timeout 10 --max-time 15 https://www.google.com >/dev/null 2>&1; then
            green "网络连接正常 (curl google.com)"
            return 0
        else
            red "无法连接到外网，请检查网络配置"
            return 1
        fi
    fi
}

# 配置网络
configure_network() {
    log "配置网络..."
    SYSTEM=$(detect_system)
    if [ "$SYSTEM" != "openwrt" ]; then
        if sysctl net.ipv4.ip_forward | grep -q "net.ipv4.ip_forward = 1"; then
            green "IPv4 转发已启用"
        else
            yellow "启用 IPv4 转发..."
            sysctl -w net.ipv4.ip_forward=1
            if grep -q "^net.ipv4.ip_forward=" /etc/sysctl.conf; then
                sed -i 's/^net.ipv4.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
            else
                echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
            fi
            green "IPv4 转发已启用并持久化"
        fi
    else
        yellow "OpenWrt 系统，跳过 IP 转发设置，请通过 LuCI 或 uci 配置"
    fi
    nat_rule_exists=$(iptables -t nat -C POSTROUTING -s 192.168.0.0/16 -j MASQUERADE 2>/dev/null; echo $?)
    if [ "$nat_rule_exists" -eq 0 ]; then
        green "NAT 规则已存在"
    else
        yellow "添加 NAT 规则..."
        if iptables -t nat -A POSTROUTING -s 192.168.0.0/16 -j MASQUERADE; then
            green "NAT 规则添加成功"
            if command -v iptables-save >/dev/null 2>&1; then
                mkdir -p /etc/iptables
                iptables-save > /etc/iptables/rules.v4 || red "保存 iptables 规则失败"
            else
                yellow "未找到 iptables-save，NAT 规则可能不持久"
            fi
        else
            red "添加 NAT 规则失败"
        fi
    fi
}

# 加载环境变量
load_env() {
    if [ -f "$ENV_FILE" ]; then
        . "$ENV_FILE"
        green "已加载环境变量 $ENV_FILE"
    else
        yellow "未检测到 $ENV_FILE，将进入交互式配置..."
        if setup_env; then
            . "$ENV_FILE"
        else
            red "环境变量设置失败"
            return 1
        fi
    fi
    if [ -z "${SUBSCRIBE_URLS:-}" ]; then
        red "SUBSCRIBE_URLS 未设置"
        return 1
    fi
    return 0
}

# 保存环境变量
save_env() {
    mkdir -p "$(dirname "$ENV_FILE")"
    cat >"$ENV_FILE" <<EOF
# sing-box 脚本环境变量
# 由脚本自动生成于 $(date)
WX_WEBHOOK="${WX_WEBHOOK:-}"
SUBSCRIBE_URLS="${SUBSCRIBE_URLS:-}"
CONFIG_PATH="${CONFIG_FILE:-}"
UPDATE_LOG_FILE="${UPDATE_LOG_FILE:-/var/log/sing-box-update.log}"
SINGBOX_BIN_PATH="${BIN_DIR:-}/sing-box"
EOF
    chmod 600 "$ENV_FILE"
    chown root:root "$ENV_FILE"
    green "环境变量已保存到 $ENV_FILE"
}

# 交互式配置环境变量
setup_env() {
    printf "请输入企业微信 Webhook 地址（可选，回车跳过）: "
    read user_wx_webhook
    WX_WEBHOOK=${user_wx_webhook:-}
    while true; do
        printf "请输入订阅链接（必填，多个用空格分隔）: "
        read user_subscribe_urls
        if [ -z "$user_subscribe_urls" ]; then
            red "订阅链接不能为空"
        elif echo "$user_subscribe_urls" | grep -q 'http'; then
            SUBSCRIBE_URLS="$user_subscribe_urls"
            break
        else
            red "请输入有效的 URL（包含 http:// 或 https://）"
        fi
    done
    default_update_log="/var/log/sing-box-update.log"
    printf "请输入更新日志路径 [默认: %s]: " "$default_update_log"
    read user_update_log
    UPDATE_LOG_FILE=${user_update_log:-$default_update_log}
    save_env
    return 0
}

# 企业微信通知
send_wx_notification() {
    webhook_url="$1"
    message_content="$2"
    if [ -z "$webhook_url" ]; then
        yellow "未配置企业微信 Webhook，跳过通知"
        return
    fi
    json_payload=$(printf '{"msgtype":"text","text":{"content":"设备 [%s] 通知：\n%s"}}' "$DEVICE_NAME" "$message_content")
    log "发送企业微信通知..."
    if curl -sSf -H "Content-Type: application/json" --connect-timeout 10 --max-time 20 -d "$json_payload" "$webhook_url" >/dev/null; then
        green "通知发送成功"
    else
        red "通知发送失败"
    fi
}

# 启动 sing-box
start_singbox() {
    SYSTEM=$(detect_system)
    if [ "$SYSTEM" = "openwrt" ]; then
        log "在 OpenWrt 上启动 sing-box..."
        if [ -x /etc/init.d/sing-box ]; then
            if /etc/init.d/sing-box start; then
                green "sing-box 服务启动成功"
                return 0
            else
                red "sing-box 服务启动失败"
                return 1
            fi
        else
            red "未找到 /etc/init.d/sing-box"
            return 1
        fi
    else
        if [ ! -r "$CONFIG_FILE" ] || [ ! -x "$BIN_DIR/sing-box" ]; then
            red "配置文件或可执行文件不可用"
            return 1
        fi
        log "使用 nohup 启动 sing-box..."
        nohup "$BIN_DIR/sing-box" run -c "$CONFIG_FILE" >/dev/null 2>&1 &
        sleep 3
        if pgrep -f "$BIN_DIR/sing-box run -c $CONFIG_FILE" >/dev/null 2>&1; then
            pid=$(pgrep -f "$BIN_DIR/sing-box run -c $CONFIG_FILE")
            green "sing-box 启动成功 (PID: $pid)"
            return 0
        else
            red "sing-box 启动失败"
            return 1
        fi
    fi
}

# 停止 sing-box
stop_singbox() {
    SYSTEM=$(detect_system)
    if [ "$SYSTEM" = "openwrt" ]; then
        log "在 OpenWrt 上停止 sing-box..."
        if [ -x /etc/init.d/sing-box ]; then
            if /etc/init.d/sing-box stop; then
                green "sing-box 服务停止成功"
                return 0
            else
                red "sing-box 服务停止失败"
                return 1
            fi
        else
            red "未找到 /etc/init.d/sing-box"
            return 1
        fi
    else
        log "停止 sing-box 进程..."
        if pkill -f "$BIN_DIR/sing-box run -c $CONFIG_FILE" || true; then
            sleep 2
            if pgrep -f "$BIN_DIR/sing-box run -c $CONFIG_FILE" >/dev/null 2>&1; then
                yellow "进程仍在运行，强制停止..."
                pkill -9 -f "$BIN_DIR/sing-box run -c $CONFIG_FILE" || true
                sleep 1
                if pgrep -f "$BIN_DIR/sing-box run -c $CONFIG_FILE" >/dev/null 2>&1; then
                    red "强制停止失败"
                    return 1
                fi
            fi
            green "sing-box 进程已停止"
        else
            yellow "sing-box 未运行"
        fi
        return 0
    fi
}

# 设置开机自启动
setup_autostart() {
    SYSTEM=$(detect_system)
    log "设置开机自启动..."
    if [ "$SYSTEM" = "openwrt" ]; then
        if [ -x /etc/init.d/sing-box ]; then
            if /etc/init.d/sing-box enable; then
                green "sing-box 服务自启动已启用"
                return 0
            else
                red "设置服务自启动失败"
                return 1
            fi
        else
            red "未找到 /etc/init.d/sing-box"
            return 1
        fi
    else
        start_cmd_raw="$BIN_DIR/sing-box run -c $CONFIG_FILE"
        start_cmd="nohup $start_cmd_raw >/dev/null 2>&1 &"
        autostart_set=false
        if command -v systemctl >/dev/null 2>&1; then
            log "创建 systemd 服务..."
            service_file="/etc/systemd/system/sing-box.service"
            cat > "$service_file" << EOF
[Unit]
Description=Sing-Box Service
After=network.target
[Service]
WorkingDirectory=$BASE_DIR
ExecStart=$start_cmd_raw
Restart=on-failure
RestartSec=5s
[Install]
WantedBy=multi-user.target
EOF
            chmod 644 "$service_file"
            if systemctl daemon-reload && systemctl enable sing-box; then
                green "systemd 服务已启用"
                autostart_set=true
            else
                red "systemd 服务创建失败"
                rm -f "$service_file"
            fi
        fi
        if [ "$autostart_set" = false ] && [ -f /etc/rc.local ] && [ -x /etc/rc.local ]; then
            log "添加到 /etc/rc.local..."
            if ! grep -q "$start_cmd_raw" /etc/rc.local; then
                if sed -i "/^exit 0/i $start_cmd" /etc/rc.local; then
                    green "已添加到 rc.local"
                    autostart_set=true
                else
                    red "添加到 rc.local 失败"
                fi
            else
                yellow "rc.local 已包含启动命令"
                autostart_set=true
            fi
        fi
        if [ "$autostart_set" = false ] && command -v crontab >/dev/null 2>&1; then
            log "使用 cron @reboot..."
            current_crontab=$(crontab -l 2>/dev/null | grep -v "$start_cmd_raw")
            new_crontab=$(printf "%s\n%s\n" "$current_crontab" "@reboot $start_cmd")
            echo "$new_crontab" | crontab -
            if crontab -l 2>/dev/null | grep -q "@reboot.*$start_cmd_raw"; then
                green "cron @reboot 自启动已设置"
                autostart_set=true
            else
                red "cron @reboot 设置失败"
            fi
        fi
        if [ "$autostart_set" = false ]; then
            red "无法设置自启动，请手动配置"
            return 1
        fi
        return 0
    fi
}

# 安装 sing-box
install_singbox() {
    check_root
    TEMP_DIR=$(mktemp -d) || { red "创建临时目录失败"; return 1; }
    trap 'echo "安装中断，清理..."; cleanup; trap - INT TERM EXIT; return 1' INT TERM
    trap 'cleanup; trap - INT TERM EXIT' EXIT
    ARCH=$(get_arch)
    log "检测到架构: $ARCH"
    SYSTEM=$(detect_system)
    log "检测到系统: $SYSTEM"
    install_deps || { red "依赖安装失败"; return 1; }
    log "获取 GitHub 版本信息..."
    api_url="https://api.github.com/repos/SagerNet/sing-box/releases?per_page=30"
    releases_json=""
    for attempt in 1 2 3; do
        releases_json=$(curl -sSL --connect-timeout 10 --max-time 20 "$api_url")
        if [ -n "$releases_json" ] && echo "$releases_json" | grep -q '"tag_name"'; then
            log "获取 GitHub API 数据成功 (尝试 $attempt)"
            break
        fi
        log "获取 GitHub API 数据失败 (尝试 $attempt)"
        sleep 2
    done
    if [ -z "$releases_json" ] || echo "$releases_json" | grep -q '"message": "Not Found"'; then
        red "无法获取版本信息"
        while [ -z "$version" ]; do
            printf "请输入版本号 (如 1.9.0): "
            read manual_version
            validate_version "$manual_version" || continue
            version="$manual_version"
        done
    else
        releases_json_file="$TEMP_DIR/releases.json"
        echo "$releases_json" > "$releases_json_file"
        cleaned_json=$(tr -d '\000-\037' < "$releases_json_file")
        stable_versions=$(echo "$cleaned_json" | jq -r '.[] | select(.prerelease == false) | [.tag_name, "稳定版", .published_at] | join("\t")' | sort -r -k3 | head -n 5 | awk '{print $1 " - " $2}')
        prerelease_versions=$(echo "$cleaned_json" | jq -r '.[] | select(.prerelease == true) | [.tag_name, "预发布版", .published_at] | join("\t")' | sort -r -k3 | head -n 5 | awk '{print $1 " - " $2}')
        version_list=$(printf "%s\n%s" "$stable_versions" "$prerelease_versions")
        if [ -z "$version_list" ]; then
            red "无法解析版本列表"
            return 1
        fi
        default_version=$(echo "$stable_versions" | head -n 1 | awk '{print $1}')
        yellow "推荐安装最新稳定版: $default_version"
        if command -v fzf >/dev/null 2>&1; then
            version=$(echo "$version_list" | fzf --prompt="请选择 sing-box 版本 [默认: $default_version] > " --height=20 --reverse --select-1 --query="$default_version" || echo "$default_version")
        else
            yellow "未检测到 fzf，使用序号选择版本"
            version_list_file="$TEMP_DIR/version_list.txt"
            echo "$version_list" > "$version_list_file"
            printf "\n可用版本列表：\n"
            i=1
            while IFS= read -r ver; do
                printf "%2d. %s\n" "$i" "$ver"
                i=$(expr $i + 1)
            done < "$version_list_file"
            max_index=$(expr $i - 1)
            while true; do
                printf "\n请输入版本序号 [1-%d，默认: 1] 或 'q' 使用默认版本: " "$max_index"
                read version_index
                if [ -z "$version_index" ] || [ "$version_index" = "q" ] || [ "$version_index" = "Q" ]; then
                    version="$default_version"
                    log "用户选择默认版本: $version"
                    break
                fi
                if echo "$version_index" | grep -qE '^[0-9]+$' && [ "$version_index" -ge 1 ] && [ "$version_index" -le "$max_index" ]; then
                    version=$(sed -n "${version_index}p" "$version_list_file" | awk '{print $1}')
                    log "用户选择版本: $version"
                    break
                else
                    red "无效输入，请输入 1-$max_index 或 'q'"
                fi
            done
        fi
        validate_version "$version" || { red "版本号无效"; return 1; }
    fi
    version=${version#v}
    log "将安装版本: $version"
    download_url="https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-${ARCH}.tar.gz"
    for attempt in 1 2 3; do
        if curl -L --connect-timeout 15 --max-time 120 "$download_url" -o "$TEMP_DIR/sing-box.tar.gz"; then
            green "下载完成"
            break
        fi
        red "下载失败 (尝试 $attempt)"
        sleep 2
        if [ "$attempt" -eq 3 ]; then
            red "下载失败"
            printf "是否重新选择版本？(y/n): "
            read retry_version
            if [ "$retry_version" = "y" ] || [ "$retry_version" = "Y" ]; then
                return 2
            else
                return 1
            fi
        fi
    done
    if ! tar xzf "$TEMP_DIR/sing-box.tar.gz" -C "$TEMP_DIR"; then
        red "解压失败"
        return 1
    fi
    extracted_dir=$(find "$TEMP_DIR" -maxdepth 1 -type d -name "sing-box-*-linux-$ARCH")
    if [ -z "$extracted_dir" ] || [ ! -f "$extracted_dir/sing-box" ]; then
        if [ -f "$TEMP_DIR/sing-box" ]; then
            extracted_singbox="$TEMP_DIR/sing-box"
        else
            red "未找到 sing-box 可执行文件"
            return 1
        fi
    else
        extracted_singbox="$extracted_dir/sing-box"
    fi
    mkdir -p "$BIN_DIR" "$BASE_DIR"
    log "安装 sing-box 到 $BIN_DIR/sing-box..."
    if ! cp "$extracted_singbox" "$BIN_DIR/sing-box"; then
        red "复制文件失败"
        return 1
    fi
    chmod +x "$BIN_DIR/sing-box"
    green "sing-box 可执行文件已安装"
    if [ "$SYSTEM" = "openwrt" ]; then
        log "创建 OpenWrt 服务脚本..."
        cat > /etc/init.d/sing-box << EOF
#!/bin/sh /etc/rc.common
START=90
STOP=10
USE_PROCD=1
start_service() {
    procd_open_instance
    procd_set_param command $BIN_DIR/sing-box run -c $CONFIG_FILE
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param file $CONFIG_FILE
    procd_close_instance
}
EOF
        chmod +x /etc/init.d/sing-box
        green "已创建 OpenWrt 服务脚本"
    fi
    if [ "$SYSTEM" != "openwrt" ]; then
        log "检查 TUN 设备..."
        if ls /dev/net/tun >/dev/null 2>&1; then
            green "TUN 设备已存在"
        else
            yellow "TUN 设备不存在，尝试创建..."
            modprobe tun || yellow "加载 TUN 模块失败"
            mkdir -p /dev/net
            if mknod /dev/net/tun c 10 200; then
                chmod 0666 /dev/net/tun
                green "TUN 设备创建成功"
            else
                red "创建 TUN 设备失败"
            fi
        fi
    else
        yellow "OpenWrt 系统，跳过 TUN 设备检查"
        if ! lsmod | grep -q "tun"; then
            yellow "未检测到 TUN 模块，请运行 'modprobe tun'"
        fi
    fi
    if [ ! -f "$CONFIG_FILE" ]; then
        log "创建空配置文件..."
        echo "{}" > "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
    else
        yellow "配置文件已存在"
    fi
    configure_network
    setup_autostart
    gateway_ip=$(get_gateway_ip) || gateway_ip=""
    green "sing-box v$version 安装完成"
    if [ -n "$gateway_ip" ]; then
        yellow "网关和 DNS 可设置为: $gateway_ip"
    fi
    green "请运行选项 2 配置订阅链接"
    return 0
}

# 更新配置并运行
update_config_and_run() {
    log "开始配置更新任务..."
    check_root
    if ! load_env; then
        red "无法加载环境变量"
        return 1
    fi
    log "生成更新脚本: $UPDATE_SCRIPT..."
    cat >"$UPDATE_SCRIPT" <<EOF
#!/bin/sh
set -eu
ENV_FILE="$ENV_FILE"
CONFIG_PATH=""
UPDATE_LOG_FILE="/var/log/sing-box-update.log"
WX_WEBHOOK=""
SINGBOX_BIN_PATH=""
SUBSCRIBE_URLS=""
TIMESTAMP=\$(date '+%Y-%m-%d %H:%M:%S')
DEVICE_NAME="\$(hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null || echo 'unknown-device')"
SYSTEM="\$( [ -f /etc/openwrt_release ] && echo 'openwrt' || echo 'other' )"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'
_log() {
    printf "%b[%s] %s%b\\n" "\$YELLOW" "\$TIMESTAMP" "\$1" "\$NC"
    echo "[\$TIMESTAMP] \$1" >> "\$UPDATE_LOG_FILE"
}
red_log() { printf "%b%s%b\\n" "\$RED" "\$1" "\$NC"; echo "[\$TIMESTAMP] ERROR: \$1" >> "\$UPDATE_LOG_FILE"; }
green_log() { printf "%b%s%b\\n" "\$GREEN" "\$1" "\$NC"; echo "[\$TIMESTAMP] SUCCESS: \$1" >> "\$UPDATE_LOG_FILE"; }
yellow_log() { printf "%b%s%b\\n" "\$YELLOW" "\$1" "\$NC"; echo "[\$TIMESTAMP] INFO: \$1" >> "\$UPDATE_LOG_FILE"; }
load_env_vars() {
    if [ ! -f "\$ENV_FILE" ]; then
        red_log "环境变量文件 \$ENV_FILE 未找到"
        exit 1
    fi
    . "\$ENV_FILE"
    if [ -z "\$CONFIG_PATH" ] || [ -z "\$UPDATE_LOG_FILE" ] || [ -z "\$SINGBOX_BIN_PATH" ] || [ -z "\$SUBSCRIBE_URLS" ]; then
        red_log "缺少必要环境变量"
        exit 1
    fi
    mkdir -p "\$(dirname "\$UPDATE_LOG_FILE")"
    _log "环境变量加载成功"
}
limit_log_lines() {
    max_size=1048576
    if [ -f "\$UPDATE_LOG_FILE" ]; then
        current_size=\$(wc -c < "\$UPDATE_LOG_FILE")
        if [ "\$current_size" -gt "\$max_size" ]; then
            _log "更新日志超过 1MB，清空..."
            > "\$UPDATE_LOG_FILE"
            _log "更新日志已清空"
        fi
    fi
}
send_msg() {
    message_content="\$1"
    if [ -z "\$WX_WEBHOOK" ]; then
        return
    fi
    json_payload=\$(printf '{"msgtype":"text","text":{"content":"[设备: %s] sing-box 更新通知：\\n%s"}}' "\$DEVICE_NAME" "\$message_content")
    _log "发送企业微信通知..."
    if curl -sSf -H "Content-Type: application/json" --connect-timeout 10 --max-time 20 -d "\$json_payload" "\$WX_WEBHOOK" >/dev/null; then
        _log "通知发送成功"
    else
        red_log "通知发送失败"
    fi
}
install_jq_if_needed() {
    if command -v jq >/dev/null 2>&1; then
        return 0
    fi
    _log "未检测到 jq，尝试安装..."
    pkg_cmd=""
    if [ "\$SYSTEM" = "openwrt" ]; then pkg_cmd="opkg update && opkg install jq";
    elif command -v apt >/dev/null 2>&1; then pkg_cmd="apt update && apt install -y jq";
    elif command -v yum >/dev/null 2>&1; then pkg_cmd="yum install -y jq";
    elif command -v apk >/dev/null 2>&1; then pkg_cmd="apk add jq";
    fi
    if [ -n "\$pkg_cmd" ] && eval "\$pkg_cmd"; then
        _log "jq 安装成功"
    else
        red_log "安装 jq 失败"
        exit 1
    fi
}
validate_config() {
    file_to_check="\$1"
    if [ ! -s "\$file_to_check" ]; then
        red_log "配置文件 \$file_to_check 不存在或为空"
        return 1
    fi
    if jq -e . "\$file_to_check" >/dev/null 2>&1; then
        _log "配置文件 \$file_to_check JSON 语法有效"
        if [ -x "\$SINGBOX_BIN_PATH" ]; then
            if "\$SINGBOX_BIN_PATH" check -c "\$file_to_check" >/dev/null 2>&1; then
                _log "配置文件 \$file_to_check 通过 sing-box check 验证"
                return 0
            else
                red_log "配置文件 \$file_to_check 未通过 sing-box check 验证"
                return 1
            fi
        else
            yellow_log "未找到 sing-box 可执行文件，跳过 sing-box check"
            return 0
        fi
    else
        error_msg=\$(jq . "\$file_to_check" 2>&1)
        red_log "配置文件 \$file_to_check JSON 格式无效！错误: \$error_msg"
        return 1
    fi
}
get_node_count() {
    if jq -e '.outbounds | type == "array"' "\$CONFIG_PATH" >/dev/null 2>&1; then
        jq '.outbounds | length' "\$CONFIG_PATH"
    else
        echo "0"
    fi
}
backup_config() {
    backup_file="\${CONFIG_PATH}.bak"
    if [ -f "\$CONFIG_PATH" ]; then
        if cp "\$CONFIG_PATH" "\$backup_file"; then
            _log "配置文件已备份到 \$backup_file"
        else
            red_log "备份配置文件失败"
        fi
    else
        _log "原始配置文件不存在，跳过备份"
    fi
}
restore_config() {
    backup_file="\${CONFIG_PATH}.bak"
    if [ -f "\$backup_file" ]; then
        if cp "\$backup_file" "\$CONFIG_PATH"; then
            yellow_log "已从 \$backup_file 还原配置"
            return 0
        else
            red_log "还原备份配置失败"
            return 1
        fi
    else
        red_log "备份文件 \$backup_file 不存在"
        return 1
    fi
}
start_service() {
    if [ "\$SYSTEM" = "openwrt" ]; then
        if [ -x /etc/init.d/sing-box ]; then
            /etc/init.d/sing-box restart && sleep 2
            if /etc/init.d/sing-box status | grep -q "running"; then
                green_log "sing-box 服务重启成功"
                return 0
            else
                red_log "sing-box 服务重启失败"
                return 1
            fi
        else
            red_log "未找到 /etc/init.d/sing-box"
            return 1
        fi
    else
        if [ ! -r "\$CONFIG_PATH" ] || [ ! -x "\$SINGBOX_BIN_PATH" ]; then
            red_log "配置文件或可执行文件不可用"
            return 1
        fi
        pkill -f "\$SINGBOX_BIN_PATH run -c \$CONFIG_PATH" || true
        sleep 1
        nohup "\$SINGBOX_BIN_PATH" run -c "\$CONFIG_PATH" >> "\$UPDATE_LOG_FILE" 2>&1 &
        sleep 3
        if pgrep -f "\$SINGBOX_BIN_PATH run -c \$CONFIG_PATH" >/dev/null 2>&1; then
            green_log "sing-box 启动成功"
            return 0
        else
            red_log "sing-box 启动失败"
            return 1
        fi
    fi
}
run_update() {
    _log "=== 开始执行 sing-box 配置更新 ==="
    final_message="📡 sing-box 更新报告 (\$(date '+%H:%M:%S'))"
    overall_success=false
    TEMP_CONFIG_PATH="\${CONFIG_PATH}.tmp.\$\$"
    for sub_url in \$SUBSCRIBE_URLS; do
        yellow_log "处理订阅链接: \$sub_url"
        if curl -kfsSL --connect-timeout 20 --max-time 90 --retry 2 "\$sub_url" -o "\$TEMP_CONFIG_PATH"; then
            _log "成功下载配置"
            if validate_config "\$TEMP_CONFIG_PATH"; then
                green_log "配置文件验证通过"
                backup_config
                if mv "\$TEMP_CONFIG_PATH" "\$CONFIG_PATH"; then
                    green_log "新配置已应用"
                    if start_service; then
                        node_count=\$(get_node_count)
                        green_log "服务启动成功，节点数: \$node_count"
                        final_message="\$final_message\n✅ 成功更新并启动"
                        overall_success=true
                        break
                    else
                        red_log "服务启动失败"
                        restore_config && start_service
                        final_message="\$final_message\n❌ 启动失败，已还原配置"
                    fi
                else
                    red_log "应用新配置失败"
                    final_message="\$final_message\n❌ 应用新配置失败"
                fi
            else
                red_log "配置验证失败"
                final_message="\$final_message\n❌ 验证失败"
            fi
            rm -f "\$TEMP_CONFIG_PATH"
        else
            red_log "下载配置失败"
            final_message="\$final_message\n❌ 下载失败"
            rm -f "\$TEMP_CONFIG_PATH"
        fi
    done
    rm -f "\$TEMP_CONFIG_PATH"
    if [ "\$overall_success" = true ]; then
        green_log "更新成功完成"
    else
        red_log "更新失败"
        if [ "\$SYSTEM" = "openwrt" ] && [ -x /etc/init.d/sing-box ]; then
            /etc/init.d/sing-box status | grep -q "running" && yellow_log "sing-box 仍在运行旧配置" || yellow_log "sing-box 未运行"
        else
            pgrep -f "\$SINGBOX_BIN_PATH run -c \$CONFIG_PATH" >/dev/null 2>&1 && yellow_log "sing-box 仍在运行旧配置" || yellow_log "sing-box 未运行"
        fi
    fi
    send_msg "\$final_message"
    [ "\$overall_success" = true ] && return 0 || return 1
}
main() {
    load_env_vars
    limit_log_lines
    install_jq_if_needed
    run_update
}
main
EOF
    chmod +x "$UPDATE_SCRIPT"
    green "更新脚本 $UPDATE_SCRIPT 已生成"
    log "执行更新脚本..."
    if "$UPDATE_SCRIPT"; then
        green "首次配置更新成功"
        check_network || yellow "网络检查失败，请核实配置"
        yellow "日志文件: $UPDATE_LOG_FILE"
        if [ -f "$CONFIG_FILE" ] && jq -e '.experimental.clash_api' "$CONFIG_FILE" >/dev/null 2>&1; then
            clash_port=$(jq -r '.experimental.clash_api.listen | split(":")[1]' "$CONFIG_FILE" 2>/dev/null || echo "9090")
            yellow "Clash API 已启用，Web UI 地址: http://<设备IP>:$clash_port/ui"
        else
            yellow "未检测到 Clash API，默认 Web UI 地址 (如启用): http://<设备IP>:9090/ui"
        fi
        return 0
    else
        red "配置更新失败，请检查日志: $LOG_FILE, $UPDATE_LOG_FILE"
        return 1
    fi
}

# 设置定时更新
setup_scheduled_update() {
    check_root
    if [ ! -f "$UPDATE_SCRIPT" ]; then
        red "更新脚本 $UPDATE_SCRIPT 不存在"
        return 1
    fi
    if ! command -v crontab >/dev/null 2>&1; then
        red "crontab 未找到"
        return 1
    fi
    log "配置定时更新任务..."
    yellow "当前 crontab 任务:"
    crontab -l 2>/dev/null | grep "$UPDATE_SCRIPT" || echo " (无)"
    printf "请选择操作：[1] 添加/修改定时任务 [2] 清除定时任务 [其他] 取消 : "
    read cron_action
    case "$cron_action" in
        1)
            default_cron_expr="0 4 * * *"
            printf "请输入 cron 表达式 [默认: %s]: " "$default_cron_expr"
            read cron_expr
            cron_expr=${cron_expr:-$default_cron_expr}
            if ! echo "$cron_expr" | grep -Eq '^([0-9*,/-]+ +){4}[0-9*,/-]+$'; then
                red "无效的 cron 表达式: $cron_expr"
                return 1
            fi
            temp_cron_file=$(mktemp)
            crontab -l 2>/dev/null | grep -v "$UPDATE_SCRIPT" > "$temp_cron_file" || true
            echo "$cron_expr $UPDATE_SCRIPT" >> "$temp_cron_file"
            if crontab "$temp_cron_file"; then
                green "定时任务设置为: $cron_expr $UPDATE_SCRIPT"
                rm -f "$temp_cron_file"
                return 0
            else
                red "设置定时任务失败"
                rm -f "$temp_cron_file"
                return 1
            fi
            ;;
        2)
            log "清除定时任务..."
            temp_cron_file=$(mktemp)
            crontab -l 2>/dev/null | grep -v "$UPDATE_SCRIPT" > "$temp_cron_file" || true
            if crontab "$temp_cron_file"; then
                green "定时任务已清除"
                rm -f "$temp_cron_file"
                return 0
            else
                red "清除定时任务失败"
                rm -f "$temp_cron_file"
                return 1
            fi
            ;;
        *)
            yellow "操作取消"
            return 0
            ;;
    esac
}

# 查看状态/控制服务
manage_service() {
    check_root
    SYSTEM=$(detect_system)
    status="未知"
    if [ "$SYSTEM" = "openwrt" ]; then
        if [ -x /etc/init.d/sing-box ]; then
            if /etc/init.d/sing-box status | grep -q "running"; then
                status="active (running)"
                pid=$(/etc/init.d/sing-box status | grep -o 'pid.*' | awk '{print $2}')
                green "sing-box 状态: $status (PID: $pid)"
            else
                status="inactive (dead)"
                red "sing-box 状态: $status"
            fi
        else
            red "未找到 /etc/init.d/sing-box"
            status="error"
        fi
    else
        if pgrep -f "$BIN_DIR/sing-box run -c $CONFIG_FILE" >/dev/null 2>&1; then
            pid=$(pgrep -f "$BIN_DIR/sing-box run -c $CONFIG_FILE")
            status="active (running)"
            green "sing-box 状态: $status (PID: $pid)"
        else
            status="inactive (dead)"
            red "sing-box 状态: $status"
        fi
    fi
    printf "请选择操作：[1] 启动 [2] 停止 [3] 重启 [其他] 返回 : "
    read action
    case "$action" in
        1)
            if [ "$status" = "active (running)" ]; then
                yellow "sing-box 已在运行"
            else
                log "启动 sing-box..."
                start_singbox
            fi
            ;;
        2)
            if [ "$status" = "inactive (dead)" ]; then
                yellow "sing-box 已停止"
            else
                log "停止 sing-box..."
                stop_singbox
            fi
            ;;
        3)
            log "重启 sing-box..."
            if [ "$SYSTEM" = "openwrt" ] && [ -x /etc/init.d/sing-box ]; then
                if /etc/init.d/sing-box restart; then
                    green "sing-box 重启成功"
                else
                    red "sing-box 重启失败"
                fi
            else
                stop_singbox && sleep 1 && start_singbox
            fi
            ;;
        *)
            yellow "返回主菜单"
            ;;
    esac
}

# 卸载 sing-box
uninstall_singbox() {
    check_root
    red "警告：这将删除 sing-box 相关文件和服务"
    printf "请输入 'yes' 确认卸载: "
    read confirmation
    if [ "$confirmation" != "yes" ]; then
        yellow "卸载取消"
        return
    fi
    log "开始卸载 sing-box..."
    SYSTEM=$(detect_system)
    stop_singbox
    if [ "$SYSTEM" = "openwrt" ]; then
        if [ -x /etc/init.d/sing-box ]; then
            /etc/init.d/sing-box disable
            rm -f /etc/init.d/sing-box
            green "OpenWrt 服务脚本已移除"
        fi
    else
        if command -v systemctl >/dev/null 2>&1 && [ -f /etc/systemd/system/sing-box.service ]; then
            systemctl stop sing-box.service 2>/dev/null || true
            systemctl disable sing-box.service 2>/dev/null || true
            rm -f /etc/systemd/system/sing-box.service
            systemctl daemon-reload 2>/dev/null || true
            green "systemd 服务已移除"
        fi
    fi
    log "移除 crontab 任务..."
    if command -v crontab >/dev/null 2>&1; then
        (crontab -l 2>/dev/null | grep -v "$UPDATE_SCRIPT" | grep -v "$BIN_DIR/sing-box") | crontab - 2>/dev/null || true
        green "crontab 任务已移除"
    fi
    if [ -f /etc/rc.local ]; then
        sed -i "\#$BIN_DIR/sing-box#d" /etc/rc.local 2>/dev/null || true
        green "rc.local 启动项已移除"
    fi
    rm -f "$BIN_DIR/sing-box"
    rm -f "$UPDATE_SCRIPT"
    rm -rf "$BASE_DIR"
    rm -f "$ENV_FILE"
    rm -f "/var/log/sing-box-update.log"
    rm -f "$LOG_FILE"
    green "相关文件已删除"
    log "移除 NAT 规则..."
    if iptables -t nat -D POSTROUTING -s 192.168.0.0/16 -j MASQUERADE 2>/dev/null; then
        green "NAT 规则已移除"
        if command -v iptables-save >/dev/null 2>&1; then
            iptables-save > /etc/iptables/rules.v4 || red "保存 iptables 规则失败"
        fi
    else
        yellow "未找到 NAT 规则"
    fi
    green "sing-box 卸载完成"
    yellow "IP 转发设置未禁用，请手动修改 /etc/sysctl.conf"
}

# 限制主脚本日志大小
limit_main_log_lines() {
    max_size=1048576
    if [ -f "$LOG_FILE" ]; then
        current_size=$(wc -c < "$LOG_FILE")
        if [ "$current_size" -gt "$max_size" ]; then
            log "主脚本日志超过 1MB，清空..."
            > "$LOG_FILE"
            log "主脚本日志已清空"
        fi
    fi
}

# 主菜单
main_menu() {
    while true; do
        printf "\n%b=== sing-box 管理脚本 (OpenWrt 优化版) ===%b\n" "$GREEN" "$NC"
        echo " 1. 安装 sing-box"
        echo " 2. 配置订阅链接并更新"
        echo " 3. 设置定时更新任务"
        echo " 4. 查看状态 / 启动 | 停止 | 重启"
        echo " 5. 卸载 sing-box"
        echo " 6. 退出脚本"
        printf "%b=====================================%b\n" "$GREEN" "$NC"
        printf "请输入选项 [1-6]: "
        read choice
        exit_code=0
        limit_main_log_lines
        case "$choice" in
            1) install_singbox || exit_code=$? ;;
            2) update_config_and_run || exit_code=$? ;;
            3) setup_scheduled_update || exit_code=$? ;;
            4) manage_service || exit_code=$? ;;
            5) uninstall_singbox || exit_code=$? ;;
            6) green "退出脚本..."; trap - INT TERM EXIT; exit 0 ;;
            *) red "无效选项 '$choice'"; exit_code=1 ;;
        esac
        if [ "$exit_code" -ne 0 ] && [ "$choice" -ne 6 ]; then
            yellow "操作失败 (退出码: $exit_code)，请检查日志: $LOG_FILE"
        fi
        if [ "$choice" -ne 6 ]; then
            printf "\n按 [Enter] 返回主菜单..."
            read dummy_input
        fi
    done
}

# 脚本入口
log_dir=$(dirname "$LOG_FILE")
if [ ! -d "$log_dir" ]; then
    mkdir -p "$log_dir" || { echo "无法创建日志目录 $log_dir"; exit 1; }
fi
touch "$LOG_FILE" 2>/dev/null || { echo "无法写入日志 $LOG_FILE"; exit 1; }
limit_main_log_lines
log "=== 主脚本启动 ==="
main_menu
log "=== 主脚本正常退出 ==="
trap - INT TERM EXIT
exit 0
