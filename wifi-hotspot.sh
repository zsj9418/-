#!/bin/bash

# 全局变量，用于保存自定义 Wi-Fi 名称和密码
CUSTOM_WIFI_NAME=""
CUSTOM_WIFI_PASSWORD=""

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
    exit 1
fi

# 使用帮助信息
usage() {
    echo "Usage: $0"
    echo "  1. 创建 Wi-Fi 发射点"
    echo "  2. 连接其他 Wi-Fi 网络并删除已创建的热点"
    echo "  3. 自动切换 Wi-Fi 模式（根据网线状态）"
    echo "  4. 后台运行自动切换模式（自启动）"
    echo "  5. 停止并卸载后台服务"
    echo "  6. 查看保存的 Wi-Fi 网络并添加新网络"
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

# 检测网线状态
check_ethernet_connection() {
    local NET_INTERFACE=$1
    if [[ -f "/sys/class/net/$NET_INTERFACE/carrier" ]]; then
        if [[ "$(cat /sys/class/net/$NET_INTERFACE/carrier)" -eq 1 ]]; then
            return 0  # 网线已连接
        else
            return 1  # 网线未连接
        fi
    else
        echo "网口 $NET_INTERFACE 不存在，请检查接口名称。"
        return 2  # 网线接口不存在
    fi
}

# 清理旧的热点配置
clear_old_hotspots() {
    local HOTSPOT_PREFIX="AutoHotspot-"
    local OLD_HOTSPOTS=$(nmcli con | grep "$HOTSPOT_PREFIX" | awk '{print $1}')
    if [[ -n "$OLD_HOTSPOTS" ]]; then
        echo "正在清理旧的热点配置..."
        for HOTSPOT in $OLD_HOTSPOTS; do
            echo "正在删除热点配置: $HOTSPOT"
            nmcli con down "$HOTSPOT" > /dev/null 2>&1
            nmcli con delete "$HOTSPOT" > /dev/null 2>&1
        done
        echo "旧的热点配置清理完成。"
    else
        echo "没有找到旧的热点配置。"
    fi
}

# 创建 Wi-Fi 热点
create_wifi_hotspot() {
    local INTERFACE=$1
    local WIFI_NAME=${2:-"4G-WIFI"}
    local WIFI_PASSWORD=${3:-"12345678"}
    local HOTSPOT_CONNECTION_NAME="AutoHotspot-$WIFI_NAME"

    # 清理旧的热点配置
    clear_old_hotspots

    echo "正在创建 Wi-Fi 发射点..."
    nmcli con add type wifi ifname "$INTERFACE" con-name "$HOTSPOT_CONNECTION_NAME" ssid "$WIFI_NAME" 802-11-wireless.mode ap
    nmcli con modify "$HOTSPOT_CONNECTION_NAME" 802-11-wireless-security.key-mgmt wpa-psk
    nmcli con modify "$HOTSPOT_CONNECTION_NAME" 802-11-wireless-security.psk "$WIFI_PASSWORD"
    nmcli con modify "$HOTSPOT_CONNECTION_NAME" ipv4.method shared
    nmcli con up "$HOTSPOT_CONNECTION_NAME"

    if [[ $? -eq 0 ]]; then
        echo "Wi-Fi 热点模式已启动：SSID=$WIFI_NAME，密码=$WIFI_PASSWORD"
    else
        echo "创建 Wi-Fi 发射点失败，请检查无线网卡是否支持热点模式或驱动是否正常工作。"
        exit 1
    fi
}

# 连接 Wi-Fi 网络
connect_wifi_network() {
    local INTERFACE=$1
    local TARGET_SSID=$2
    local TARGET_PASSWORD=$3

    echo "尝试连接 Wi-Fi，无线网卡接口: $INTERFACE" # 调试输出
    # 断开当前连接
    CURRENT_CONNECTION=$(nmcli dev show "$INTERFACE" | grep "GENERAL.CONNECTION" | awk '{print $2}')
    if [[ -n "$CURRENT_CONNECTION" && "$CURRENT_CONNECTION" != "--" ]]; then
        echo "正在断开当前连接: $CURRENT_CONNECTION..."
        nmcli con down "$CURRENT_CONNECTION"
        echo "已断开连接: $CURRENT_CONNECTION"
    fi

    echo "正在连接到 Wi-Fi 网络: $TARGET_SSID..."
    nmcli dev wifi connect "$TARGET_SSID" password "$TARGET_PASSWORD"  2>&1 | tee /tmp/wifi_connect.log # 移除 -v, 重定向全部输出到日志
    # nmcli dev wifi connect "$TARGET_SSID" password "$TARGET_PASSWORD" # 原命令

    if [[ $? -eq 0 ]]; then
        echo "成功连接到 Wi-Fi 网络：$TARGET_SSID"
    else
        echo "连接到 Wi-Fi 网络失败，请检查 SSID 和密码，详细信息请查看 /tmp/wifi_connect.log。"
        exit 1
    fi
}

# 自动切换 Wi-Fi 模式
auto_switch_wifi_mode() {
    local WIFI_INTERFACE=$(detect_wifi_interface)
    local NET_INTERFACE=$(detect_ethernet_interface)

    if [[ -z "$WIFI_INTERFACE" ]]; then
        echo "未检测到无线网卡，请检查硬件配置。"
        exit 1
    fi

    if [[ -z "$NET_INTERFACE" ]]; then
        echo "未检测到网线接口，请检查硬件配置。"
        exit 1
    fi

    echo "正在检测网线状态..."
    check_ethernet_connection "$NET_INTERFACE"
    CONNECTION_STATUS=$?

    if [[ $CONNECTION_STATUS -eq 0 ]]; then
        echo "网线已连接，切换到 Wi-Fi 热点模式。"
        # 使用自定义名称和密码，如果已设置
        local HOTSPOT_WIFI_NAME=${CUSTOM_WIFI_NAME:-"4G-WIFI"}
        local HOTSPOT_WIFI_PASSWORD=${CUSTOM_WIFI_PASSWORD:-"12345678"}
        create_wifi_hotspot "$WIFI_INTERFACE" "$HOTSPOT_WIFI_NAME" "$HOTSPOT_WIFI_PASSWORD"
    elif [[ $CONNECTION_STATUS -eq 1 ]]; then
        echo "网线未连接，切换到 Wi-Fi 客户端模式。"
        connect_previously_saved_wifi "$WIFI_INTERFACE"
    else
        echo "未检测到网线接口，请检查设备配置。"
    fi
}

# 连接之前保存的 Wi-Fi 网络 (改进版，排除热点，检查信号)
connect_previously_saved_wifi() {
    local INTERFACE=$1

    echo "正在扫描可用 Wi-Fi 网络..."
    AVAILABLE_WIFI_LIST=$(nmcli dev wifi list)

    if [[ -n "$AVAILABLE_WIFI_LIST" ]]; then
        echo "可用 Wi-Fi 网络列表 (扫描结果):"
        echo "$AVAILABLE_WIFI_LIST"
        echo "-----------------------------------"

        local SAVED_CONNECTIONS=$(nmcli con show | grep wifi | awk '{print $1}')
        local BEST_SAVED_CONNECTION=""

        if [[ -n "$SAVED_CONNECTIONS" ]]; then
            echo "正在检查已保存的 Wi-Fi 网络..."
            for CONNECTION in $SAVED_CONNECTIONS; do
                # 排除以 "AutoHotspot-" 开头的连接 (设备自身热点)
                if [[ "$CONNECTION" == AutoHotspot-* ]]; then
                    echo "跳过已保存的热点配置: $CONNECTION"
                    continue
                fi

                # 获取已保存连接的 SSID
                SAVED_SSID=$(nmcli con show "$CONNECTION" | grep "connection.id" | awk '{print $3}')

                # 在扫描结果中查找匹配的 SSID 并且有信号
                SIGNAL_STRENGTH=$(echo "$AVAILABLE_WIFI_LIST" | grep "$SAVED_SSID" | awk '{print $6}')

                if [[ -n "$SIGNAL_STRENGTH" && "$SIGNAL_STRENGTH" != "--" ]]; then # 检查信号强度不为空且不为 "--" (表示有信号)
                    echo "找到已保存且有信号的 Wi-Fi 网络: $SAVED_SSID (连接名称: $CONNECTION, 信号强度: $SIGNAL_STRENGTH)"
                    BEST_SAVED_CONNECTION="$CONNECTION" # 找到第一个符合条件的保存网络就尝试连接
                    break # 找到一个就跳出循环，连接第一个找到的
                else
                    echo "已保存网络 $SAVED_SSID (连接名称: $CONNECTION) 无信号或未在扫描结果中找到。"
                fi
            done

            if [[ -n "$BEST_SAVED_CONNECTION" ]]; then
                echo "尝试连接到最佳已保存 Wi-Fi 网络: $BEST_SAVED_CONNECTION..."
                nmcli con up "$BEST_SAVED_CONNECTION" ifname "$INTERFACE"
                if [[ $? -eq 0 ]]; then
                    echo "成功连接到 Wi-Fi 网络：$BEST_SAVED_CONNECTION"
                    return 0 # 连接成功返回 0
                else
                    echo "连接到 Wi-Fi 网络 $BEST_SAVED_CONNECTION 失败，请检查配置。"
                    return 1 # 连接失败返回 1
                fi
            else
                echo "没有找到已保存的且有信号的 Wi-Fi 网络。"
                # 可以选择是否继续扫描并提示用户手动连接，这里先保持原有的扫描提示逻辑
            fi
        else
            echo "没有找到已保存的 Wi-Fi 网络，将扫描可用网络。"
            # 继续执行扫描和提示用户连接的逻辑 (如果需要)
        fi
    else
        echo "没有扫描到可用的 Wi-Fi 网络。"
        return 1 # 没有可用网络返回 1
    fi

    #  如果以上尝试都失败，可以考虑 fallback 到提示用户手动选择或扫描网络
    #  为了简化，这里先不修改 fallback 逻辑，保持之前的行为，即没有找到合适的保存网络，可能后续会提示扫描
    echo "未能自动连接到已保存的 Wi-Fi 网络，请检查或手动添加网络。"
    return 1 # 默认返回 1，表示连接失败或没有进行连接
}

# 后台运行自动切换模式
start_background_service() {
    local SCRIPT_PATH=$(realpath "$0")
    local SERVICE_NAME="wifi_auto_switch.service"

    echo "创建 systemd 服务以后台运行自动切换模式..."
    cat <<EOF > /etc/systemd/system/$SERVICE_NAME
[Unit]
Description=WiFi Auto Switch Service
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$SCRIPT_PATH auto-switch
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    systemctl start "$SERVICE_NAME"
    echo "后台服务已启动，自动切换 Wi-Fi 模式。"
}

# 检查服务状态
check_service_status() {
    local SERVICE_NAME="wifi_auto_switch.service"
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        return 0  # 服务正在运行
    else
        return 1  # 服务未运行
    fi
}

# 停止并卸载后台服务
stop_and_uninstall_service() {
    local SERVICE_NAME="wifi_auto_switch.service"

    check_service_status
    SERVICE_STATUS=$?

    if [[ $SERVICE_STATUS -eq 0 ]]; then
        echo "服务 $SERVICE_NAME 正在运行。"
        read -p "是否确认停止并卸载该服务？(y/n): " choice
        if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
            echo "停止并卸载后台服务..."
            systemctl stop "$SERVICE_NAME"
            systemctl disable "$SERVICE_NAME"
            rm /etc/systemd/system/$SERVICE_NAME
            systemctl daemon-reload
            echo "后台服务已停止并卸载。"
        else
            echo "取消停止并卸载服务。"
        fi
    else
        echo "服务 $SERVICE_NAME 未运行。"
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
        nmcli dev wifi connect "$NEW_SSID" password "$NEW_PASSWORD"
        if [[ $? -eq 0 ]]; then
            echo "成功添加并连接到 Wi-Fi 网络：$NEW_SSID"
        else
            echo "添加 Wi-Fi 网络失败，请检查输入的 SSID 和密码。"
        fi
    fi
}

# 主菜单逻辑
if [[ "$1" == "auto-switch" ]]; then
    local LAST_CONNECTION_STATUS=-1  # 初始化为无效状态
    while true; do
        auto_switch_wifi_mode
        check_ethernet_connection "$NET_INTERFACE"
        CURRENT_CONNECTION_STATUS=$?
        if [[ $CURRENT_CONNECTION_STATUS -eq $LAST_CONNECTION_STATUS ]]; then
            sleep 60  # 如果状态未变化，增加检测间隔时间
        else
            sleep 5  # 如果状态变化，减少检测间隔时间
        fi
        LAST_CONNECTION_STATUS=$CURRENT_CONNECTION_STATUS
    done
else
    echo "请选择操作:"
    echo "1. 创建 Wi-Fi 发射点"
    echo "2. 连接其他 Wi-Fi 网络并删除已创建的热点"
    echo "3. 自动切换 Wi-Fi 模式（根据网线状态）"
    echo "4. 后台运行自动切换模式（自启动）"
    echo "5. 停止并卸载后台服务"
    echo "6. 查看保存的 Wi-Fi 网络并添加新网络"
    read -p "输入选项 (1, 2, 3, 4, 5 或 6): " choice

    case $choice in
        1)
            INTERFACE=$(detect_wifi_interface)
            if [[ -z "$INTERFACE" ]]; then
                echo "未检测到无线网卡，请检查硬件配置。"
                exit 1
            fi
            read -p "请输入 Wi-Fi 发射点名称（默认: 4G-WIFI）: " WIFI_NAME
            WIFI_NAME=${WIFI_NAME:-"4G-WIFI"}
            read -p "请输入 Wi-Fi 发射点密码（默认: 12345678）: " WIFI_PASSWORD
            WIFI_PASSWORD=${WIFI_PASSWORD:-"12345678"}
            # 保存自定义名称和密码
            CUSTOM_WIFI_NAME="$WIFI_NAME"
            CUSTOM_WIFI_PASSWORD="$WIFI_PASSWORD"
            create_wifi_hotspot "$INTERFACE" "$WIFI_NAME" "$WIFI_PASSWORD"
            ;;
        2)
            INTERFACE=$(detect_wifi_interface)
            if [[ -z "$INTERFACE" ]]; then
                echo "未检测到无线网卡，请检查硬件配置。"
                exit 1
            fi
            read -p "请输入要连接的 Wi-Fi 网络名称: " TARGET_SSID
            read -p "请输入要连接的 Wi-Fi 网络密码: " TARGET_PASSWORD
            connect_wifi_network "$INTERFACE" "$TARGET_SSID" "$TARGET_PASSWORD"
            ;;
        3)
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
        *)
            echo "无效的选择，请输入 1、2、3、4、5 或 6。"
            usage
            ;;
    esac
fi

exit 0
