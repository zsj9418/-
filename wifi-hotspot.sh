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

# 检测操作系统类型
OS_TYPE=$(uname -s)
if [[ "$OS_TYPE" == "Linux" ]]; then
    DISTRO=$(cat /etc/os-release | grep "^ID=" | cut -d'=' -f2 | tr -d '"')
    if [[ "$DISTRO" == "debian" || "$DISTRO" == "ubuntu" ]]; then
        echo "检测到 Debian/Ubuntu 系统。"
    elif [[ "$DISTRO" == "centos" || "$DISTRO" == "rhel" ]]; then
        echo "检测到 CentOS/RHEL 系统。"
    else
        echo "不支持的操作系统: $DISTRO"
        exit 1
    fi
else
    echo "不支持的操作系统: $OS_TYPE"
    exit 1
fi

# 检查是否安装 nmcli
if ! command -v nmcli &> /dev/null; then
    echo "nmcli 未安装，正在安装 NetworkManager 工具..."
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
    echo "请以 root 权限运行此脚本。"
    echo "请使用 sudo 或以 root 身份运行。"
    exit 1
fi

# 使用帮助信息
usage() {
    echo "Usage: $SCRIPT_NAME"
    echo "  1. 创建 Wi-Fi 发射点"
    echo "  2. 连接其他 Wi-Fi 网络并删除已创建的热点"
    echo "  3. 自动切换 Wi-Fi 模式（根据网线状态）"
    echo "  4. 后台运行自动切换模式（自启动）"
    echo "  5. 停止并卸载后台服务"
    echo "  6. 查看保存的 Wi-Fi 网络并添加新网络"
    echo "  7. 退出"
    echo "  8. 手动触发自动切换 Wi-Fi 模式"
    exit 1
}

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
            echo "网线状态检查: $interface 已断开" | tee -a "$LOG_FILE"
            return 0  # 网线已断开
        else
            echo "网线状态检查: $interface 已连接" | tee -a "$LOG_FILE"
            return 1  # 网线未断开
        fi
    else
        echo "网线状态检查: $interface 接口不存在，视为断开" | tee -a "$LOG_FILE"
        return 0  # 接口不存在，视为未连接
    fi
}

# 清理旧的热点配置
clear_old_hotspots() {
    local HOTSPOT_PREFIX="AutoHotspot-"
    local OLD_HOTSPOTS=$(nmcli con | grep "$HOTSPOT_PREFIX" | awk '{print $1}')
    if [[ -n "$OLD_HOTSPOTS" ]]; then
        echo "正在清理旧的热点配置..." | tee -a "$LOG_FILE"
        for HOTSPOT in $OLD_HOTSPOTS; do
            echo "正在删除热点配置: $HOTSPOT" | tee -a "$LOG_FILE"
            nmcli con down "$HOTSPOT" > /dev/null 2>&1
            nmcli con delete "$HOTSPOT" > /dev/null 2>&1
        done
        echo "旧的热点配置清理完成。" | tee -a "$LOG_FILE"
    else
        echo "没有找到旧的热点配置。" | tee -a "$LOG_FILE"
    fi
}

# 创建 Wi-Fi 热点
create_wifi_hotspot() {
    local INTERFACE=$1
    local WIFI_NAME=${2:-"4G-WIFI"}
    local WIFI_PASSWORD=${3:-"12345678"}
    local HOTSPOT_CONNECTION_NAME="AutoHotspot-$WIFI_NAME"

    # 断开当前 Wi-Fi 连接
    local CURRENT_CONNECTION=$(nmcli dev show "$INTERFACE" | grep "GENERAL.CONNECTION" | awk '{print $2}')
    if [[ -n "$CURRENT_CONNECTION" && "$CURRENT_CONNECTION" != "--" ]]; then
        echo "正在断开当前 Wi-Fi 连接: $CURRENT_CONNECTION..." | tee -a "$LOG_FILE"
        nmcli con down "$CURRENT_CONNECTION" > /dev/null 2>&1
        sleep 2
    fi

    clear_old_hotspots

    echo "正在创建 Wi-Fi 发射点..." | tee -a "$LOG_FILE"
    nmcli con add type wifi ifname "$INTERFACE" con-name "$HOTSPOT_CONNECTION_NAME" ssid "$WIFI_NAME" 802-11-wireless.mode ap
    nmcli con modify "$HOTSPOT_CONNECTION_NAME" 802-11-wireless-security.key-mgmt wpa-psk
    nmcli con modify "$HOTSPOT_CONNECTION_NAME" 802-11-wireless-security.psk "$WIFI_PASSWORD"
    nmcli con modify "$HOTSPOT_CONNECTION_NAME" ipv4.method shared
    nmcli con up "$HOTSPOT_CONNECTION_NAME"

    if [[ $? -eq 0 ]]; then
        echo "Wi-Fi 热点模式已启动：SSID=$WIFI_NAME，密码=$WIFI_PASSWORD" | tee -a "$LOG_FILE"
    else
        echo "创建 Wi-Fi 发射点失败，请检查无线网卡是否支持热点模式或驱动是否正常工作。" | tee -a "$LOG_FILE"
        exit 1
    fi
}

# 连接 Wi-Fi 网络
connect_wifi_network() {
    local INTERFACE=$1
    local TARGET_SSID=$2
    local TARGET_PASSWORD=$3

    echo "尝试连接 Wi-Fi，无线网卡接口: $INTERFACE" | tee -a "$LOG_FILE"
    CURRENT_CONNECTION=$(nmcli dev show "$INTERFACE" | grep "GENERAL.CONNECTION" | awk '{print $2}')
    if [[ -n "$CURRENT_CONNECTION" && "$CURRENT_CONNECTION" != "--" ]]; then
        echo "正在断开当前连接: $CURRENT_CONNECTION..." | tee -a "$LOG_FILE"
        nmcli con down "$CURRENT_CONNECTION"
        echo "已断开连接: $CURRENT_CONNECTION" | tee -a "$LOG_FILE"
    fi

    sleep 2

    echo "正在连接到 Wi-Fi 网络: $TARGET_SSID..." | tee -a "$LOG_FILE"
    nmcli dev wifi connect "$TARGET_SSID" password "$TARGET_PASSWORD" 2>&1 | tee -a "$LOG_FILE"
    if [[ $? -eq 0 ]]; then
        echo "成功连接到 Wi-Fi 网络：$TARGET_SSID" | tee -a "$LOG_FILE"
    else
        echo "连接到 Wi-Fi 网络失败，请检查 SSID 和密码。" | tee -a "$LOG_FILE"
    fi
}

# 连接之前保存的 Wi-Fi 网络（排除自建热点）
connect_previously_saved_wifi() {
    local INTERFACE=$1
    local MAX_RETRIES=3
    local WAIT_TIME=5
    local HOTSPOT_PREFIX="AutoHotspot-"

    echo "正在尝试连接已保存的非自建 Wi-Fi 网络..." | tee -a "$LOG_FILE"
    local SAVED_CONNECTIONS=$(nmcli con show | grep wifi | awk '{print $1}')

    if [[ -n "$SAVED_CONNECTIONS" ]]; then
        for CONNECTION in $SAVED_CONNECTIONS; do
            if [[ "$CONNECTION" == *"$HOTSPOT_PREFIX"* ]]; then
                echo "跳过自建热点: $CONNECTION" | tee -a "$LOG_FILE"
                continue
            fi

            local attempt=0
            echo "尝试连接到: $CONNECTION" | tee -a "$LOG_FILE"
            while [[ $attempt -lt $MAX_RETRIES ]]; do
                nmcli con up "$CONNECTION" ifname "$INTERFACE" 2>&1 | tee -a "$LOG_FILE"
                if [[ $? -eq 0 ]]; then
                    echo "成功连接到 Wi-Fi 网络：$CONNECTION" | tee -a "$LOG_FILE"
                    return 0
                else
                    echo "连接失败，重试 $((attempt + 1))/$MAX_RETRIES..." | tee -a "$LOG_FILE"
                    attempt=$((attempt + 1))
                    sleep $WAIT_TIME
                fi
            done
        done
        echo "所有非自建 Wi-Fi 网络连接尝试均失败。" | tee -a "$LOG_FILE"
    else
        echo "没有找到非自建的已保存 Wi-Fi 网络。" | tee -a "$LOG_FILE"
    fi
    return 1
}

# 自动切换 Wi-Fi 模式
auto_switch_wifi_mode() {
    echo "自动切换 Wi-Fi 模式触发..." | tee -a "$LOG_FILE"

    local WIFI_INTERFACE=$(detect_wifi_interface)
    local NET_INTERFACE=$(detect_ethernet_interface)

    if [[ -z "$WIFI_INTERFACE" ]]; then
        echo "未检测到无线网卡，请检查硬件配置。" | tee -a "$LOG_FILE"
        return 1
    fi
    if [[ -z "$NET_INTERFACE" ]]; then
        echo "未检测到网线接口，请检查硬件配置。" | tee -a "$LOG_FILE"
        return 1
    fi

    if is_ethernet_disconnected "$NET_INTERFACE"; then
        echo "网线已断开，尝试连接非自建的已保存 Wi-Fi 网络..." | tee -a "$LOG_FILE"
        # 断开当前热点（如果存在）
        local CURRENT_CONNECTION=$(nmcli dev show "$WIFI_INTERFACE" | grep "GENERAL.CONNECTION" | awk '{print $2}')
        if [[ -n "$CURRENT_CONNECTION" && "$CURRENT_CONNECTION" != "--" ]]; then
            echo "正在断开当前连接: $CURRENT_CONNECTION..." | tee -a "$LOG_FILE"
            nmcli con down "$CURRENT_CONNECTION" > /dev/null 2>&1
            sleep 2
        fi

        if connect_previously_saved_wifi "$WIFI_INTERFACE"; then
            echo "成功连接到非自建 Wi-Fi 网络，保持客户端模式。" | tee -a "$LOG_FILE"
        else
            echo "未能连接到任何非自建 Wi-Fi 网络，切换到热点模式。" | tee -a "$LOG_FILE"
            local HOTSPOT_WIFI_NAME=${CUSTOM_WIFI_NAME:-"4G-WIFI"}
            local HOTSPOT_WIFI_PASSWORD=${CUSTOM_WIFI_PASSWORD:-"12345678"}
            create_wifi_hotspot "$WIFI_INTERFACE" "$HOTSPOT_WIFI_NAME" "$HOTSPOT_WIFI_PASSWORD"
        fi
    else
        echo "网线已连接，切换到热点模式并分享网络..." | tee -a "$LOG_FILE"
        local HOTSPOT_WIFI_NAME=${CUSTOM_WIFI_NAME:-"4G-WIFI"}
        local HOTSPOT_WIFI_PASSWORD=${CUSTOM_WIFI_PASSWORD:-"12345678"}
        create_wifi_hotspot "$WIFI_INTERFACE" "$HOTSPOT_WIFI_NAME" "$HOTSPOT_WIFI_PASSWORD"
    fi
}

# 后台运行自动切换模式
start_background_service() {
    local DISPATCHER_SCRIPT="/etc/NetworkManager/dispatcher.d/wifi-auto-switch.sh"

    echo "安装 NetworkManager Dispatcher 脚本..." | tee -a "$LOG_FILE"
    mkdir -p "$CONFIG_DIR"
    local ETH_INTERFACE=$(detect_ethernet_interface)
    if [[ -z "$ETH_INTERFACE" ]]; then
        echo "未检测到网线接口，无法配置 Dispatcher 脚本。" | tee -a "$LOG_FILE"
        return 1
    fi
    echo "检测到网线接口: $ETH_INTERFACE" | tee -a "$LOG_FILE"
    echo "$ETH_INTERFACE" > "$INTERFACE_NAME_FILE"

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
        echo "\$(date '+%Y-%m-%d %H:%M:%S') - 网线断开 (\$ACTION)，尝试连接非自建 Wi-Fi" >> "\$LOG_FILE"
        /usr/local/bin/$SCRIPT_NAME auto-switch-dispatcher
    fi
else
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - 忽略非网线接口事件 (Interface: \$INTERFACE, Action: \$ACTION)" >> "\$LOG_FILE"
fi

# 开机初始化检查
if [[ "\$ACTION" == "up" && "\$INTERFACE" == "lo" ]]; then
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - 系统启动，检查网线状态并执行切换" >> "\$LOG_FILE"
    /usr/local/bin/$SCRIPT_NAME auto-switch-dispatcher
fi

exit 0
EOF

    chmod +x "$DISPATCHER_SCRIPT"
    cp "$0" "/usr/local/bin/$SCRIPT_NAME"
    chmod +x "/usr/local/bin/$SCRIPT_NAME"
    echo "Dispatcher 脚本已安装到 $DISPATCHER_SCRIPT" | tee -a "$LOG_FILE"
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
            echo "后台服务已卸载。" | tee -a "$LOG_FILE"
        fi
    else
        echo "后台服务未运行。" | tee -a "$LOG_FILE"
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

# 主菜单逻辑
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
                echo "未检测到无线网卡，请检查硬件配置。"
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
                echo "未检测到无线网卡，请检查硬件配置。"
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
            echo "退出程序。"
            exit 0
            ;;
        *)
            echo "无效的选择，请输入 1-8。"
            ;;
    esac
done

if [[ "$1" == "auto-switch-dispatcher" ]]; then
    auto_switch_wifi_mode
fi

exit 0
