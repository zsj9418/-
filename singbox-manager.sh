#!/bin/sh
set -eu  # 使用 POSIX 兼容的 set 选项

# 定义颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# 可配置路径和默认值
BASE_DIR="/etc/sing-box"
BIN_DIR="/usr/local/bin"
CONFIG_FILE="$BASE_DIR/config.json"
ENV_FILE="$HOME/.singbox_env"
LOG_FILE="/var/log/sing-box-script.log"
SCRIPT_PATH="$0"  # 使用 $0 获取脚本名
UPDATE_SCRIPT="$BASE_DIR/update-singbox.sh"

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

# 日志记录函数
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
    log "正在检查并安装依赖..."
    if command -v apt >/dev/null 2>&1; then
        apt update && apt install -y curl tar iptables ipset jq psmisc cron || return 1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl tar iptables ipset jq psmisc cronie || return 1
    elif command -v apk >/dev/null 2>&1; then
        apk add curl tar iptables ipset jq psmisc cronie || return 1
    elif command -v opkg >/dev/null 2>&1; then # OpenWrt
        opkg update && opkg install curl tar iptables ipset jq psmisc cron || return 1
    else
        red "不支持的包管理器，请手动安装 curl tar iptables ipset jq psmisc cron"
        return 1
    fi
    if ! command -v crontab >/dev/null 2>&1; then
        red "crontab 命令未找到，请手动安装 cron"
        return 1
    fi
    green "依赖安装完成"
}

# 获取网关 IP
get_gateway_ip() {
    iface=$(ip route show default | awk '/default/ {print $5}')
    if [ -z "$iface" ]; then
        red "无法获取默认网络接口"
        return 1
    fi
    ip addr show dev "$iface" | awk '/inet / {print $2}' | cut -d'/' -f1
}

# 验证版本号格式
validate_version() {
    version="$1"
    if ! echo "$version" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.-]+)?$' >/dev/null; then
        red "无效的版本号格式"
        return 1
    fi
}

# 清理临时文件
cleanup() {
    if [ -d "$TEMP_DIR" ]; then
        log "清理临时文件..."
        rm -rf "$TEMP_DIR"
    fi
}

# 检查网络通畅性
check_network() {
    log "检查网络通畅性..."
    if ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1 || curl -s --max-time 10 https://www.google.com >/dev/null 2>&1; then
        green "网络连接正常"
        return 0
    else
        red "无法连接到外网，请检查网络配置"
        return 1
    fi
}

# 配置网络（启用转发和 iptables）
configure_network() {
    log "配置网络..."
    sysctl -w net.ipv4.ip_forward=1
    echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
    if ! iptables -t nat -L POSTROUTING -n | grep -q "192.168.0.0/16.*MASQUERADE"; then
        iptables -t nat -A POSTROUTING -s 192.168.0.0/16 -j MASQUERADE
        if command -v iptables-save >/dev/null 2>&1; then
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules.v4
        fi
    fi
}

# 加载环境变量
load_env() {
    if [ -f "$ENV_FILE" ]; then
        . "$ENV_FILE"
        green "已加载环境变量配置文件 $ENV_FILE"
    else
        yellow "未检测到环境变量配置文件，将进入交互式变量输入"
        setup_env
    fi
}

# 保存环境变量到文件
save_env() {
    cat >"$ENV_FILE" <<EOF
WX_WEBHOOK="$WX_WEBHOOK"
SUBSCRIBE_URLS="$SUBSCRIBE_URLS"
CONFIG_PATH="$CONFIG_FILE"
LOG_FILE="$LOG_FILE"
EOF
    green "环境变量已保存到 $ENV_FILE"
}

# 交互式配置环境变量
setup_env() {
    printf "请输入企业微信 Webhook 地址（可直接回车跳过，默认不通知）: "
    read WX_WEBHOOK
    WX_WEBHOOK=${WX_WEBHOOK:-""}

    while true; do
        printf "请输入订阅链接（多个链接用空格分隔，必填）: "
        read SUBSCRIBE_URLS
        if [ -z "$SUBSCRIBE_URLS" ]; then
            red "订阅链接不能为空，请重新输入"
        else
            break
        fi
    done
    save_env
}

# 企业微信通知函数
send_wx_notification() {
    wx_webhook="$1"
    message="$2"
    if [ -z "$wx_webhook" ]; then
        yellow "未配置企业微信 Webhook，跳过通知"
        return
    fi
    curl -sSf -H "Content-Type: application/json" \
        -d "{\"msgtype\":\"text\",\"text\":{\"content\":\"设备 [$DEVICE_NAME] 通知：\n$message\"}}" \
        "$wx_webhook" >/dev/null || red "通知发送失败"
}

# 停止 sing-box 服务
stop_singbox() {
    if pgrep -f "$BIN_DIR/sing-box" >/dev/null 2>&1; then
        pkill -f "$BIN_DIR/sing-box" || true
        green "sing-box 进程已终止"
    else
        yellow "sing-box 未运行"
    fi
}

# 启动 sing-box 服务（统一使用 nohup）
start_singbox() {
    stop_singbox # 先停止现有实例
    nohup "$BIN_DIR/sing-box" run -c "$CONFIG_FILE" >/dev/null 2>&1 &
    sleep 2
    if pgrep -f "$BIN_DIR/sing-box" >/dev/null 2>&1; then
        green "sing-box 已通过手动方式启动，使用配置文件: $CONFIG_FILE"
    else
        red "sing-box 启动失败，请检查配置文件 $CONFIG_FILE 或日志 $LOG_FILE"
        return 1
    fi
    return 0
}

# 设置开机自启动
setup_autostart() {
    log "设置开机自启动..."
    start_cmd="$BIN_DIR/sing-box run -c $CONFIG_FILE"
    if [ -f /etc/rc.local ] && [ -x /etc/rc.local ]; then
        if ! grep -q "$start_cmd" /etc/rc.local; then
            sed -i "/exit 0/i nohup $start_cmd >/dev/null 2>&1 &" /etc/rc.local
            green "已添加到 /etc/rc.local 开机自启动"
        fi
    else
        # 使用 cron @reboot 替代
        (crontab -l 2>/dev/null | grep -v "$start_cmd"; echo "@reboot nohup $start_cmd >/dev/null 2>&1 &") | crontab -
        green "已通过 cron @reboot 设置开机自启动"
    fi
}

# 选项 1: 安装 sing-box（不启动，添加 TUN 检测和创建，兼容 OpenWrt）
install_singbox() {
    check_root
    TEMP_DIR=$(mktemp -d) || { red "创建临时目录失败"; return 1; }
    trap 'red "安装中断，正在清理..."; cleanup; return 1' INT

    ARCH=$(get_arch)
    log "检测到系统架构: $ARCH"

    SYSTEM=$(detect_system)
    log "检测到系统类型: $SYSTEM"

    printf "选择版本类型 (测试版输入 a / 正式版输入 s): "
    read version_type
    case "$version_type" in
        a*) printf "请输入测试版版本号 (如 1.12.0-alpha.9): "; read version ;;
        s*) printf "请输入正式版版本号 (如 1.11.3): "; read version ;;
        *)  red "无效选择"; cleanup; return 1 ;;
    esac
    validate_version "$version" || { cleanup; return 1; }

    install_deps || { cleanup; return 1; }
    download_url="https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-${ARCH}.tar.gz"
    log "下载地址: $download_url"

    if ! curl -sSL --max-time 60 "$download_url" | tar xz -C "$TEMP_DIR"; then
        red "下载或解压失败"
        cleanup
        return 1
    fi

    mkdir -p "$BIN_DIR" "$BASE_DIR"
    cp "$TEMP_DIR/sing-box-${version}-linux-${ARCH}/sing-box" "$BIN_DIR/" || { red "复制文件失败"; cleanup; return 1; }
    chmod +x "$BIN_DIR/sing-box"

    # 检查并配置 TUN 设备（OpenWrt 跳过，非 OpenWrt 可选继续）
    if [ "$SYSTEM" = "openwrt" ]; then
        yellow "检测到 OpenWrt 系统，跳过 TUN 设备配置（假设已预装）"
    else
        log "检查 TUN 设备..."
        if ls /dev/net/tun >/dev/null 2>&1; then
            green "TUN 设备已存在，跳过创建"
        else
            log "TUN 设备不存在，尝试创建..."
            modprobe tun || yellow "加载 TUN 模块失败，可能内核不支持"
            mkdir -p /dev/net
            mknod /dev/net/tun c 10 200 || yellow "创建 TUN 设备失败"
            chmod 0666 /dev/net/tun
            if ls /dev/net/tun >/dev/null 2>&1; then
                green "TUN 设备创建成功"
            else
                red "TUN 设备创建失败"
                printf "是否继续安装？(y/n): "
                read continue_choice
                if [ "$continue_choice" != "y" ] && [ "$continue_choice" != "Y" ]; then
                    cleanup
                    return 1
                fi
                yellow "用户选择继续安装，跳过 TUN 配置"
            fi
        fi
    fi

    echo '{}' > "$CONFIG_FILE"
    configure_network
    setup_autostart # 设置开机自启动
    gateway_ip=$(get_gateway_ip)
    cleanup
    green "安装完成！请将其他设备的网关设置为: $gateway_ip"
    printf "请运行选项 2 配置订阅链接并启动 sing-box。\n"
    return 0
}

# 选项 2: 更新配置并生成更新脚本
update_config() {
    log "配置 sing-box 更新..."
    load_env

    # 生成更新脚本（使用 POSIX 兼容语法）
    cat <<EOF > "$UPDATE_SCRIPT"
#!/bin/sh
set -eu

# 环境变量文件路径
ENV_FILE="$HOME/.singbox_env"

# 彩色输出
red() { printf "\033[31m%s\033[0m\n" "\$1"; }
green() { printf "\033[32m%s\033[0m\n" "\$1"; }
yellow() { printf "\033[33m%s\033[0m\n" "\$1"; }

# 加载环境变量
load_env() {
  if [ -f "\$ENV_FILE" ]; then
    . "\$ENV_FILE"
    green "已加载环境变量配置文件 \$ENV_FILE"
  else
    yellow "未检测到环境变量配置文件，将进入交互式变量输入"
    setup_env
  fi
}

# 保存环境变量到文件
save_env() {
  cat >"\$ENV_FILE" <<EOF2
WX_WEBHOOK="\$WX_WEBHOOK"
SUBSCRIBE_URLS="\$SUBSCRIBE_URLS"
CONFIG_PATH="\$CONFIG_PATH"
LOG_FILE="\$LOG_FILE"
EOF2
  green "环境变量已保存到 \$ENV_FILE"
}

# 交互式配置环境变量
setup_env() {
  printf "请输入企业微信 Webhook 地址（可直接回车跳过，默认不通知）: "
  read WX_WEBHOOK
  WX_WEBHOOK=\${WX_WEBHOOK:-""}

  while true; do
    printf "请输入订阅链接（多个链接用空格分隔，必填）: "
    read SUBSCRIBE_URLS
    if [ -z "\$SUBSCRIBE_URLS" ]; then
      red "订阅链接不能为空，请重新运行脚本配置"
    else
      break
    fi
  done

  printf "请输入配置文件路径 [默认: /etc/sing-box/config.json]: "
  read CONFIG_PATH
  CONFIG_PATH=\${CONFIG_PATH:-/etc/sing-box/config.json}

  printf "请输入日志文件路径 [默认: /var/log/sing-box-update.log]: "
  read LOG_FILE
  LOG_FILE=\${LOG_FILE:-/var/log/sing-box-update.log}

  save_env
}

# 限制日志文件行数
limit_log_lines() {
  max_lines=500
  if [ -f "\$LOG_FILE" ]; then
    current_lines=\`wc -l "\$LOG_FILE" | awk '{print \$1}'\`
    if [ "\$current_lines" -gt "\$max_lines" ]; then
      yellow "日志文件超过 \$max_lines 行，正在限制行数..."
      tail -n "\$max_lines" "\$LOG_FILE" > "\$LOG_FILE.tmp"
      mv "\$LOG_FILE.tmp" "\$LOG_FILE"
      green "日志文件已裁剪至最近 \$max_lines 行"
    fi
  fi
}

# 获取设备名称
get_device_name() {
  if command -v hostname >/dev/null 2>&1 && [ -n "\`hostname\`" ]; then
    hostname
  elif [ -f "/etc/hostname" ]; then
    cat /etc/hostname
  elif command -v uname >/dev/null 2>&1; then
    uname -n
  else
    echo "未知设备"
  fi
}

# 企业微信通知
send_msg() {
  if [ -z "\$WX_WEBHOOK" ]; then
    yellow "未配置企业微信 Webhook，跳过通知"
    return
  fi
  msg=\$1
  device_name=\$(get_device_name)
  curl -sSf -H "Content-Type: application/json" \
    -d "{\"msgtype\":\"text\",\"text\":{\"content\":\"[设备: \$device_name] \$msg\"}}" \
    "\$WX_WEBHOOK" >/dev/null || red "通知发送失败"
}

# 安装依赖
install_dependencies() {
  if ! command -v jq >/dev/null 2>&1; then
    yellow "检测到 jq 未安装，正在安装..."
    if command -v opkg >/dev/null 2>&1; then
      opkg update && opkg install jq
    else
      red "未找到支持的包管理器，请手动安装 jq"
      exit 1
    fi
    green "jq 安装完成"
  fi
}

# 停止 sing-box 服务
stop_singbox() {
  if pgrep sing-box >/dev/null 2>&1; then
    yellow "检测到 sing-box 正在运行，尝试关闭..."
    killall sing-box || true
    sleep 3  # 等待资源释放

    # 检查是否完全关闭，最多重试 5 次
    attempts=0
    while pgrep sing-box >/dev/null 2>&1; do
      attempts=\`expr \$attempts + 1\`
      if [ "\$attempts" -ge 5 ]; then
        red "sing-box 无法关闭，系统即将重启以释放资源"
        send_msg "❌ [设备: \$(get_device_name)] sing-box 无法停止，系统即将重启"
        reboot
        exit 1
      fi
      yellow "尝试强制关闭 sing-box (第 \$attempts 次)..."
      killall -9 sing-box || true
      sleep 3
    done
    green "sing-box 已成功关闭"
  else
    yellow "sing-box 未运行"
  fi
}

# 启动 sing-box 服务
start_singbox() {
  yellow "正在启动 sing-box..."
  nohup sing-box run -c "\$CONFIG_PATH" >> "\$LOG_FILE" 2>&1 &
  sleep 1  # 确保进程已启动
  if pgrep sing-box >/dev/null 2>&1; then
    green "sing-box 已成功启动"
  else
    red "sing-box 启动失败，请检查配置文件是否正确"
    send_msg "❌ [设备: \$(get_device_name)] sing-box 启动失败，请检查配置"
    exit 1
  fi
}

# 备份配置文件
backup_config() {
  if [ -f "\$CONFIG_PATH" ]; then
    cp "\$CONFIG_PATH" "\${CONFIG_PATH}.bak"
    green "配置文件已备份到: \${CONFIG_PATH}.bak"
  else
    yellow "配置文件不存在，跳过备份"
  fi
}

# 还原配置文件
restore_config() {
  if [ -f "\${CONFIG_PATH}.bak" ]; then
    cp "\${CONFIG_PATH}.bak" "\$CONFIG_PATH"
    green "配置文件已还原: \$CONFIG_PATH"
  else
    red "无备份文件，无法还原"
  fi
}

# 验证配置文件是否有效
validate_config() {
  if [ ! -s "\$CONFIG_PATH" ]; then
    red "配置文件为空"
    return 1
  fi
  if ! jq empty "\$CONFIG_PATH" >/dev/null 2>&1; then
    red "配置文件格式无效"
    return 1
  fi
  return 0
}

# 获取节点数量
get_node_count() {
  jq '.outbounds | length' "\$CONFIG_PATH" 2>/dev/null || echo "0"
}

# 更新配置文件
update_config() {
  message="📡 sing-box 更新报告"
  success=false
  for sub in \$SUBSCRIBE_URLS; do
    yellow "正在从 \$sub 下载配置..."
    if curl -L "\$sub" -o "\$CONFIG_PATH" >/dev/null 2>&1; then
      if validate_config; then
        backup_config
        stop_singbox
        start_singbox
        node_count=\$(get_node_count)
        if [ "\$node_count" -eq "0" ]; then
          message="\$message\n⚠️ 更新成功但未检测到节点: \$sub"
        else
          message="\$message\n✅ 更新成功: \$sub\n节点数: \$node_count"
        fi
        success=true
        break
      else
        message="\$message\n❌ 无效的配置文件: \$sub"
        restore_config
      fi
    else
      message="\$message\n❌ 下载失败: \$sub"
    fi
  done

  if [ "\$success" = "false" ]; then
    restore_config
    message="\$message\n❌ 所有订阅链接均失败，已还原备份配置"
  fi

  send_msg "\$message"
  printf "%b\n" "\$message"
}

# 主流程
main() {
  load_env
  install_dependencies
  limit_log_lines  # 限制日志文件行数
  update_config
}

main
EOF

    chmod +x "$UPDATE_SCRIPT"  # 给更新脚本赋予执行权限

    "$UPDATE_SCRIPT" # 立即执行一次更新
    if check_network; then
        green "配置更新完成！更新脚本已生成: $UPDATE_SCRIPT"
        yellow "请检查配置文件是否启用 Web UI，例如添加 'experimental.clash_api' 字段。"
        yellow "默认 Web UI 地址: http://127.0.0.1:9090"
        return 0
    else
        red "更新后网络异常，请检查配置或日志 $LOG_FILE"
        return 1
    fi
}

# 选项 3: 设置定时更新（支持默认值和清除定时）
setup_scheduled_update() {
    if [ ! -f "$UPDATE_SCRIPT" ]; then
        red "请先运行选项 2 生成更新脚本"
        return 1
    fi

    # 显示当前定时任务（如果存在）
    current_cron=$(crontab -l 2>/dev/null | grep "$UPDATE_SCRIPT")
    if [ -n "$current_cron" ]; then
        yellow "当前定时任务: $current_cron"
        printf "是否清除现有定时任务？(y/n，默认为 n): "
        read clear_choice
        if [ "$clear_choice" = "y" ] || [ "$clear_choice" = "Y" ]; then
            if ! crontab -l 2>/dev/null | grep -v "$UPDATE_SCRIPT" | crontab -; then
                red "清除定时任务失败，请检查权限或 crontab 配置"
                return 1
            fi
            green "已清除现有定时任务"
        fi
    else
        yellow "当前无定时任务"
    fi

    # 设置新的定时任务
    printf "请输入 cron 表达式 (默认 0 4 * * *，每天凌晨4点，直接回车使用默认): "
    read cron_expr
    if [ -z "$cron_expr" ]; then
        cron_expr="0 4 * * *"
        green "未输入，使用默认值: $cron_expr"
    fi

    # 确保写入 crontab
    temp_cron_file=$(mktemp)
    crontab -l 2>/dev/null | grep -v "$UPDATE_SCRIPT" > "$temp_cron_file" || true
    echo "$cron_expr $UPDATE_SCRIPT" >> "$temp_cron_file"
    if ! crontab "$temp_cron_file"; then
        red "设置定时任务失败，请检查权限或 crontab 配置"
        rm -f "$temp_cron_file"
        return 1
    fi
    rm -f "$temp_cron_file"
    green "定时更新已设置为: $cron_expr"
    return 0
}

# 选项 4: 查看状态并控制运行
manage_service() {
    status="未知"
    if pgrep -f "$BIN_DIR/sing-box" >/dev/null 2>&1; then
        status="active"
    else
        status="inactive"
    fi
    yellow "sing-box 当前状态: $status"

    printf "1. 启动 sing-box\n2. 停止 sing-box\n请选择操作 (1 或 2，留空退出): "
    read action
    case "$action" in
        1)
            if [ "$status" = "active" ]; then
                yellow "sing-box 已运行"
            else
                start_singbox
            fi
            ;;
        2)
            if [ "$status" = "inactive" ]; then
                yellow "sing-box 已停止"
            else
                stop_singbox
            fi
            ;;
        *) ;;
    esac
}

# 选项 5: 卸载 sing-box
uninstall_singbox() {
    check_root
    log "开始卸载 sing-box..."
    stop_singbox
    rm -f "$BIN_DIR/sing-box" "$UPDATE_SCRIPT"
    rm -rf "$BASE_DIR" "$ENV_FILE"
    crontab -l 2>/dev/null | grep -v "$UPDATE_SCRIPT" | crontab -
    crontab -l 2>/dev/null | grep -v "$BIN_DIR/sing-box" | crontab -
    if [ -f /etc/rc.local ]; then
        sed -i "/$BIN_DIR\/sing-box/d" /etc/rc.local
    fi
    iptables -t nat -D POSTROUTING -s 192.168.0.0/16 -j MASQUERADE 2>/dev/null || true
    if command -v iptables-save >/dev/null 2>&1; then
        iptables-save > /etc/iptables/rules.v4
    fi
    green "sing-box 已卸载，网络配置已恢复，定时任务和自启动已移除"
}

# 主菜单
main_menu() {
    while true; do
        printf "%b=== sing-box 管理脚本 ===%b\n" "$GREEN" "$NC"
        echo "1. 安装 sing-box"
        echo "2. 配置并更新 sing-box（含企业微信通知）"
        echo "3. 设置定时更新"
        echo "4. 查看状态并控制运行"
        echo "5. 卸载 sing-box"
        echo "6. 退出"
        printf "请输入选项 (1-6): "
        read choice
        case "$choice" in
            1)
                if install_singbox; then
                    green "sing-box 安装成功"
                else
                    red "sing-box 安装失败，请检查日志"
                fi
                ;;
            2)
                if update_config; then
                    green "配置更新成功"
                else
                    red "配置更新失败，请检查日志"
                fi
                ;;
            3)
                setup_scheduled_update
                ;;
            4)
                manage_service
                ;;
            5)
                uninstall_singbox
                ;;
            6)
                green "退出脚本"
                exit 0
                ;;
            *)
                red "无效选项"
                ;;
        esac
    done
}

# 主入口
main_menu
