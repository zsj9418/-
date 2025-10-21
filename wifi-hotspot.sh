#!/bin/bash

# 脚本版本
SCRIPT_VERSION="1.0"

# 全局变量，用于保存自定义 Wi-Fi 名称和密码
CUSTOM_WIFI_NAME=""
CUSTOM_WIFI_PASSWORD=""

# 脚本名称
SCRIPT_NAME=$(basename "$0")

# 配置文件目录
CONFIG_DIR="/var/lib/wifi_auto_switch"
# 网线接口名称文件
INTERFACE_NAME_FILE="$CONFIG_DIR/eth_iface"
# 日志文件
LOG_FILE="/var/log/wifi_auto_switch.log"
# 日志最大大小（1MB = 1048576 字节）
MAX_LOG_SIZE=1048576

# 检查并限制日志文件大小
restrict_log_size() {
    if [[ -f "$LOG_FILE" ]]; then
        local LOG_SIZE=$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)
        if [[ $LOG_SIZE -ge $MAX_LOG_SIZE ]]; then
            truncate -s 0 "$LOG_FILE"
            echo "$(date '+%Y-%m-%d %H:%M:%S') - 日志文件超过 1MB，已清空。" > "$LOG_FILE"
        fi
    fi
}

# 记录日志的函数
log() {
    restrict_log_size
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE" 2>/dev/null || echo "警告：日志写入失败，可能是磁盘空间不足。"
}

# 初始化日志
log "脚本启动，版本: $SCRIPT_VERSION"

# 检测操作系统类型
OS_TYPE=$(uname -s)
if [[ "$OS_TYPE" == "Linux" ]]; then
    DISTRO=$(cat /etc/os-release | grep "^ID=" | cut -d'=' -f2 | tr -d '"')
    if [[ "$DISTRO" == "debian" || "$DISTRO" == "ubuntu" ]]; then
        echo "检测到 Debian/Ubuntu 系统。" | tee -a "$LOG_FILE"
    elif [[ "$DISTRO" == "centos" || "$DISTRO" == "rhel" ]]; then
        echo "检测到 CentOS/RHEL 系统。" | tee -a "$LOG_FILE"
    else
        echo "不支持的操作系统: $DISTRO" | tee -a "$LOG_FILE"
        exit 1
    fi
else
    echo "不支持的操作系统: $OS_TYPE" | tee -a "$LOG_FILE"
    exit 1
fi

# 检查是否安装 nmcli
if ! command -v nmcli &> /dev/null; then
    log "nmcli 未安装，正在安装 NetworkManager 工具..."
    if [[ "$DISTRO" == "debian" || "$DISTRO" == "ubuntu" ]]; then
        apt-get update && apt-get install -y network-manager
    elif [[ "$DISTRO" == "centos" || "$DISTRO" == "rhel" ]]; then
        yum install -y NetworkManager
    fi
fi

# 确保 NetworkManager 在系统启动时自动启动
systemctl enable NetworkManager
systemctl start NetworkManager

# 检查是否为 root 用户
if [[ $EUID -ne 0 ]]; then
    echo "请以 root 权限运行此脚本。" | tee -a "$LOG_FILE"
    exit 1
fi

# 动态检测无线网卡
detect_wifi_interface() {
    nmcli dev | grep wifi | awk '{print $1}' | head -n 1
}

# 自动检测网线接口
detect_ethernet_interface() {
    nmcli dev | grep ethernet | awk '{print $1}' | head -n 1
}

# 检查网线是否已经断开
is_ethernet_disconnected() {
    local interface=$1
    if [[ -f "/sys/class/net/$interface/carrier" ]]; then
        if [[ "$(cat /sys/class/net/$interface/carrier)" -eq 0 ]]; then
            log "网线状态检查: $interface 已断开"
            return 0
        else
            log "网线状态检查: $interface 已连接"
            return 1
        fi
    else
        log "网线状态检查: $interface 接口不存在，视为断开"
        return 0
    fi
}

# 清理旧的热点配置
clear_old_hotspots() {
    local HOTSPOT_PREFIX="AutoHotspot-"
    local OLD_HOTSPOTS=$(nmcli con | grep "$HOTSPOT_PREFIX" | awk '{print $1}')
    if [[ -n "$OLD_HOTSPOTS" ]]; then
        log "正在清理旧的热点配置..."
        for HOTSPOT in $OLD_HOTSPOTS; do
            nmcli con down "$HOTSPOT" > /dev/null 2>&1
            nmcli con delete "$HOTSPOT" > /dev/null 2>&1
        done
        log "旧的热点配置清理完成。"
    fi
}

# 创建 Wi-Fi 热点
create_wifi_hotspot() {
    local INTERFACE=$1
    local WIFI_NAME=${2:-"4G-WIFI"}
    local WIFI_PASSWORD=${3:-"12345678"}
    local HOTSPOT_CONNECTION_NAME="AutoHotspot-$WIFI_NAME"

    clear_old_hotspots

    log "正在创建 Wi-Fi 发射点: $WIFI_NAME"
    nmcli con add type wifi ifname "$INTERFACE" con-name "$HOTSPOT_CONNECTION_NAME" ssid "$WIFI_NAME" 802-11-wireless.mode ap
    nmcli con modify "$HOTSPOT_CONNECTION_NAME" 802-11-wireless-security.key-mgmt wpa-psk
    nmcli con modify "$HOTSPOT_CONNECTION_NAME" 802-11-wireless-security.psk "$WIFI_PASSWORD"
    nmcli con modify "$HOTSPOT_CONNECTION_NAME" ipv4.method shared
    nmcli con up "$HOTSPOT_CONNECTION_NAME"

    if [[ $? -eq 0 ]]; then
        log "Wi-Fi 热点模式已启动：SSID=$WIFI_NAME，密码=$WIFI_PASSWORD"
    else
        log "创建 Wi-Fi 发射点失败，请检查无线网卡是否支持热点模式。"
        exit 1
    fi
}

# 手动连接 Wi-Fi 网络
connect_wifi_network() {
    local INTERFACE=$1
    local SSID=$2
    local PASSWORD=$3

    log "尝试手动连接 Wi-Fi: $SSID"
    nmcli dev wifi connect "$SSID" password "$PASSWORD" ifname "$INTERFACE" 2>&1 | tee -a "$LOG_FILE"
    if [[ $? -eq 0 ]]; then
        log "成功连接到 Wi-Fi 网络：$SSID"
    else
        log "连接 $SSID 失败，请检查网络名称或密码。"
    fi
}

# 智能连接 Wi-Fi（尝试保存的配置和扫描可用网络）
smart_connect_wifi() {
    local INTERFACE=$1
    local MAX_RETRIES=3
    local WAIT_TIME=5
    local RETRY_CYCLE=2
    local HOTSPOT_PREFIX="AutoHotspot-"

    log "正在尝试智能连接 Wi-Fi..."

    # 第一步：尝试已保存的非自建 Wi-Fi
    log "尝试连接已保存的非自建 Wi-Fi 网络..."
    local SAVED_CONNECTIONS=$(nmcli con show | grep wifi | grep -v "$HOTSPOT_PREFIX" | awk '{print $1}')
    if [[ -n "$SAVED_CONNECTIONS" ]]; then
        for ((cycle = 1; cycle <= $RETRY_CYCLE; cycle++)); do
            log "开始第 $cycle 次尝试连接已保存的非自建 Wi-Fi..."
            for CONNECTION in $SAVED_CONNECTIONS; do
                local attempt=0
                while [[ $attempt -lt $MAX_RETRIES ]]; do
                    log "尝试连接保存的网络: $CONNECTION (第 $((attempt + 1))/$MAX_RETRIES 次)"
                    nmcli con up "$CONNECTION" ifname "$INTERFACE" > /dev/null 2>&1
                    if [[ $? -eq 0 ]]; then
                        log "成功连接到保存的 Wi-Fi 网络：$CONNECTION"
                        return 0
                    fi
                    attempt=$((attempt + 1))
                    sleep $WAIT_TIME
                done
            done
            log "第 $cycle 次循环未成功连接保存的网络，等待后重试..."
            sleep 10
        done
    else
        log "未找到已保存的非自建 Wi-Fi 网络。"
    fi

    # 第二步：扫描可用 Wi-Fi 并尝试连接
    log "未连接保存的网络，开始扫描可用 Wi-Fi..."
    nmcli dev wifi rescan ifname "$INTERFACE" > /dev/null 2>&1
    sleep 2
    local AVAILABLE_WIFI=$(nmcli -f SSID,SIGNAL,SECURITY dev wifi list ifname "$INTERFACE" | grep -v "$HOTSPOT_PREFIX" | sort -k2 -nr | head -n 5)
    if [[ -n "$AVAILABLE_WIFI" ]]; then
        while IFS= read -r line; do
            local SSID=$(echo "$line" | awk '{print $1}')
            local SIGNAL=$(echo "$line" | awk '{print $2}')
            local SECURITY=$(echo "$line" | awk '{print $3}')
            if [[ -n "$SSID" && "$SSID" != "--" ]]; then
                log "发现可用 Wi-Fi: SSID=$SSID, 信号强度=$SIGNAL, 安全性=$SECURITY"
                if [[ "$SECURITY" == "-" || $(nmcli con show | grep -q "$SSID") ]]; then
                    log "尝试连接可用网络: $SSID (信号强度: $SIGNAL)"
                    nmcli dev wifi connect "$SSID" ifname "$INTERFACE" > /dev/null 2>&1
                    if [[ $? -eq 0 ]]; then
                        log "成功连接到扫描到的 Wi-Fi 网络：$SSID"
                        return 0
                    else
                        log "连接 $SSID 失败，继续尝试其他网络..."
                    fi
                fi
            fi
        done <<< "$AVAILABLE_WIFI"
    else
        log "未扫描到可用 Wi-Fi 网络。"
    fi

    log "所有 Wi-Fi 连接尝试均失败。"
    return 1
}

# 自动切换 Wi-Fi 模式
auto_switch_wifi_mode() {
    log "自动切换 Wi-Fi 模式触发..."

    local WIFI_INTERFACE=$(detect_wifi_interface)
    local NET_INTERFACE=$(detect_ethernet_interface)

    if [[ -z "$WIFI_INTERFACE" ]]; then
        log "未检测到无线网卡，请检查硬件配置。"
        return 1
    fi
    if [[ -z "$NET_INTERFACE" ]]; then
        log "未检测到网线接口，请检查硬件配置。"
        return 1
    fi

    if ! is_ethernet_disconnected "$NET_INTERFACE"; then
        log "网线已连接，直接切换到热点模式..."
        create_wifi_hotspot "$WIFI_INTERFACE" "${CUSTOM_WIFI_NAME:-4G-WIFI}" "${CUSTOM_WIFI_PASSWORD:-12345678}"
    else
        log "网线已断开，尝试智能连接 Wi-Fi..."
        if smart_connect_wifi "$WIFI_INTERFACE"; then
            log "已成功连接 Wi-Fi，保持客户端模式。"
        else
            log "未连接到任何 Wi-Fi，切换到热点模式。"
            create_wifi_hotspot "$WIFI_INTERFACE" "${CUSTOM_WIFI_NAME:-4G-WIFI}" "${CUSTOM_WIFI_PASSWORD:-12345678}"
        fi
    fi
}

# 后台运行自动切换模式
start_background_service() {
    local DISPATCHER_SCRIPT="/etc/NetworkManager/dispatcher.d/wifi-auto-switch.sh"

    log "安装 NetworkManager Dispatcher 脚本..."
    mkdir -p "$CONFIG_DIR"
    local ETH_INTERFACE=$(detect_ethernet_interface)
    if [[ -z "$ETH_INTERFACE" ]]; then
        log "未检测到网线接口，无法配置 Dispatcher 脚本。"
        return 1
    fi
    log "检测到网线接口: $ETH_INTERFACE"
    echo "$ETH_INTERFACE" > "$INTERFACE_NAME_FILE"

    # 等待系统网络服务就绪
    local TIMEOUT=30
    local COUNT=0
    while [[ $(nmcli networking connectivity) != "full" && $COUNT -lt $TIMEOUT ]]; do
        log "等待网络服务就绪 ($COUNT/$TIMEOUT)..."
        sleep 1
        COUNT=$((COUNT + 1))
    done

    cat <<EOF > "$DISPATCHER_SCRIPT"
#!/bin/bash
INTERFACE=\$1
ACTION=\$2
ETH_INTERFACE_FILE="$INTERFACE_NAME_FILE"
LOG_FILE="$LOG_FILE"

if [[ -f "\$ETH_INTERFACE_FILE" ]]; then
    ETH_INTERFACE_NAME=\$(cat "\$ETH_INTERFACE_FILE")
else
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - 错误：无法读取网线接口名称文件 \$ETH_INTERFACE_FILE" >> "\$LOG_FILE"
    exit 1
fi

echo "\$(date '+%Y-%m-%d %H:%M:%S') - Dispatcher 触发: Interface=\$INTERFACE, Action=\$ACTION" >> "\$LOG_FILE"

if [[ "\$INTERFACE" == "\$ETH_INTERFACE_NAME" ]]; then
    if [[ "\$ACTION" == "up" ]]; then
        echo "\$(date '+%Y-%m-%d %H:%M:%S') - 网线连接 (up)，创建热点" >> "\$LOG_FILE"
        /usr/local/bin/$SCRIPT_NAME auto-switch-dispatcher
    elif [[ "\$ACTION" == "down" || "\$ACTION" == "pre-down" || "\$ACTION" == "post-down" ]]; then
        echo "\$(date '+%Y-%m-%d %H:%M:%S') - 网线断开 (\$ACTION)，尝试智能连接 Wi-Fi" >> "\$LOG_FILE"
        /usr/local/bin/$SCRIPT_NAME auto-switch-dispatcher
    fi
elif [[ "\$ACTION" == "up" && "\$INTERFACE" == "lo" ]]; then
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - 系统启动，检查网线状态并执行切换" >> "\$LOG_FILE"
    /usr/local/bin/$SCRIPT_NAME auto-switch-dispatcher
else
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - 忽略非目标接口事件 (Interface: \$INTERFACE, Action: \$ACTION)" >> "\$LOG_FILE"
fi

exit 0
EOF

    chmod +x "$DISPATCHER_SCRIPT"
    cp "$0" "/usr/local/bin/$SCRIPT_NAME"
    chmod +x "/usr/local/bin/$SCRIPT_NAME"
    log "Dispatcher 脚本已安装到 $DISPATCHER_SCRIPT"

    # 初始化检查
    auto_switch_wifi_mode
}

# 停止并卸载后台服务
stop_and_uninstall_service() {
    local DISPATCHER_SCRIPT="/etc/NetworkManager/dispatcher.d/wifi-auto-switch.sh"
    if [[ -f "$DISPATCHER_SCRIPT" ]]; then
        read -p "是否确认停止并卸载后台服务？(y/n): " choice
        if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
            rm "$DISPATCHER_SCRIPT"
            rm "/usr/local/bin/$SCRIPT_NAME"
            rm -rf "$CONFIG_DIR"
            log "后台服务已卸载。"
            exit 0  # 退出脚本
        fi
    else
        log "后台服务未运行。"
        exit 0  # 退出脚本
    fi
}

# 查看保存的 Wi-Fi 网络并添加新网络
manage_saved_wifi() {
    echo "以下是设备保存的 Wi-Fi 网络："
    nmcli con show | grep wifi | awk '{print $1}'
    echo "-----------------------------------"
    read -p "是否要添加新的 Wi-Fi 网络？(y/n): " choice
    if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
        read -p "请输入 Wi-Fi 网络名称: " NEW_SSID
        read -p "请输入 Wi-Fi 网络密码: " NEW_PASSWORD
        connect_wifi_network "$(detect_wifi_interface)" "$NEW_SSID" "$NEW_PASSWORD"
    fi
}

# 处理命令行参数，避免进入交互模式
if [[ "$1" == "auto-switch-dispatcher" ]]; then
    auto_switch_wifi_mode
    exit 0
fi

# 主菜单逻辑（仅在交互模式下运行）
if [[ -t 0 ]]; then
    while true; do
        echo "请选择操作:"
        echo "1. 创建 Wi-Fi 发射点"
        echo "2. 连接其他 Wi-Fi 网络并删除已创建的热点"
        echo "3. 自动切换 Wi-Fi 模式（根据网线状态）"
        echo "4. 后台运行自动切换模式（自启动）"
        echo "5. 停止并卸载后台服务"
        echo "6. 查看保存的 Wi-Fi 网络并添加新网络"
        echo "7. 退出"
        echo "8. 手动触发自动切换 Wi-Fi 模式"
        read -p "输入选项 (1-8): " choice

        case $choice in
            1)
                INTERFACE=$(detect_wifi_interface)
                if [[ -z "$INTERFACE" ]]; then
                    echo "未检测到无线网卡，请检查硬件配置。" | tee -a "$LOG_FILE"
                    continue
                fi
                read -p "请输入 Wi-Fi 发射点名称（默认: 4G-WIFI）: " WIFI_NAME
                WIFI_NAME=${WIFI_NAME:-"4G-WIFI"}
                read -p "请输入 Wi-Fi 发射点密码（默认: 12345678）: " WIFI_PASSWORD
                WIFI_PASSWORD=${WIFI_PASSWORD:-"12345678"}
                CUSTOM_WIFI_NAME="$WIFI_NAME"
                CUSTOM_WIFI_PASSWORD="$WIFI_PASSWORD"
                create_wifi_hotspot "$INTERFACE" "$WIFI_NAME" "$WIFI_PASSWORD"
                ;;
            2)
                INTERFACE=$(detect_wifi_interface)
                if [[ -z "$INTERFACE" ]]; then
                    echo "未检测到无线网卡，请检查硬件配置。" | tee -a "$LOG_FILE"
                    continue
                fi
                read -p "请输入要连接的 Wi-Fi 网络名称: " TARGET_SSID
                read -p "请输入要连接的 Wi-Fi 网络密码: " TARGET_PASSWORD
                connect_wifi_network "$INTERFACE" "$TARGET_SSID" "$TARGET_PASSWORD"
                ;;
            3|8)
                auto_switch_wifi_mode
                ;;
            4)
                start_background_service
                ;;
            5)
                stop_and_uninstall_service
                ;;
            6)
                manage_saved_wifi
                ;;
            7)
                echo "退出程序。" | tee -a "$LOG_FILE"
                exit 0
                ;;
            *)
                echo "无效的选择，请输入 1-8。" | tee -a "$LOG_FILE"
                ;;
        esac
    done
else
    log "非交互模式，退出脚本。"
    exit 0
fi

exit 0
