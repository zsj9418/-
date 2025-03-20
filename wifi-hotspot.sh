#!/bin/bash

# 全局变量，用于保存自定义 Wi-Fi 名称和密码，设置默认值
CUSTOM_WIFI_NAME="4G-WIFI"
CUSTOM_WIFI_PASSWORD="12345678"

# 检测操作系统类型
OS_TYPE=$(uname -s)
if [[ "$OS_TYPE" == "Linux" ]]; then
    DISTRO=$(cat /etc/os-release | grep "^ID=" | cut -d'=' -f2 | tr -d '"')
    if [[ "$DISTRO" == "debian" || "$DISTRO" == "ubuntu" ]]; then
        echo "检测到 Debian/Ubuntu 系统。"
    elif [[ "$DISTRO" == "centos" || "$DISTRO" == "rhel" ]]; then
        echo "检测到 CentOS/RHEL 系统。"
    else
        echo "不支持的操作系统: $DISTRO" >&2
        exit 1
    fi
else
    echo "不支持的操作系统: $OS_TYPE" >&2
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
    echo "请以 root 权限运行此脚本。" >&2
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
    echo "  7. 退出"
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
        echo "网口 $NET_INTERFACE 不存在，请检查接口名称。" >&2
        return 2  # 网线接口不存在
    fi
}

# 清理旧的热点配置
clear_old_hotspots() {
    local HOTSPOT_PREFIX="AutoHotspot-"  # 保持前缀不变
    local OLD_HOTSPOTS=$(nmcli con show | grep "^$HOTSPOT_PREFIX" | awk '{print $1}')
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

# 检测是否支持 HT40 模式
check_ht40_support() {
    local TEMP_CONN_NAME="ht40-test-conn-$(date +%s)" # 创建一个临时连接名
    nmcli con add type wifi ifname lo con-name "$TEMP_CONN_NAME" ssid "test-ssid" 2>/dev/null # 创建一个临时连接，忽略错误输出
    if nmcli con modify "$TEMP_CONN_NAME" 802-11-wireless.ht-mode HT40 2>&1 | grep -E "无效的属性|invalid property" >/dev/null; then
        nmcli con delete "$TEMP_CONN_NAME" 2>/dev/null # 清理临时连接，忽略错误输出
        return 1 # 不支持 HT40
    else
        nmcli con delete "$TEMP_CONN_NAME" 2>/dev/null # 清理临时连接，忽略错误输出
        return 0 # 支持 HT40
    fi
}


# 创建 Wi-Fi 热点
create_wifi_hotspot() {
    local INTERFACE=$1
    local WIFI_NAME=$2
    local WIFI_PASSWORD=$3
    local HOTSPOT_CONNECTION_NAME="AutoHotspot-$WIFI_NAME"
    local HT40_SUPPORTED

    # 清理旧的热点配置
    clear_old_hotspots

    echo "正在创建 Wi-Fi 发射点..."

    # --- 调试信息输出 --- (已移除)
    # echo "调试信息: "
    # echo "  INTERFACE: $INTERFACE"
    # echo "  WIFI_NAME: $WIFI_NAME"
    # echo "  WIFI_PASSWORD: $WIFI_PASSWORD"
    # echo "  HOTSPOT_CONNECTION_NAME: $HOTSPOT_CONNECTION_NAME"
    # --- 调试信息输出结束 --- (已移除)

    # 将 nmcli con add 命令的错误输出重定向到文件 /tmp/hotspot_error.log
    nmcli con add type wifi ifname "$INTERFACE" con-name "$HOTSPOT_CONNECTION_NAME" ssid "$WIFI_NAME" 802-11-wireless.mode ap 2> /tmp/hotspot_error.log

    if [[ $? -ne 0 ]]; then # 检查 nmcli con add 是否成功
        echo "创建 Wi-Fi 热点连接配置失败 (nmcli con add)，详细错误信息请查看 /tmp/hotspot_error.log。" >&2
        cat /tmp/hotspot_error.log >&2 # 将错误日志输出到终端，方便查看
        return 1 # 返回错误
    fi


    nmcli con modify "$HOTSPOT_CONNECTION_NAME" 802-11-wireless-security.key-mgmt wpa-psk
    nmcli con modify "$HOTSPOT_CONNECTION_NAME" 802-11-wireless-security.psk "$WIFI_PASSWORD"
    nmcli con modify "$HOTSPOT_CONNECTION_NAME" ipv4.method shared
    nmcli con modify "$HOTSPOT_CONNECTION_NAME" 802-11-wireless.band bg  # 显式指定为 2.4GHz 频段 (b/g/n)
    nmcli con modify "$HOTSPOT_CONNECTION_NAME" 802-11-wireless.channel 9  # 设置信道为 9

    # 检测 HT40 支持并设置
    if check_ht40_support; then
        HT40_SUPPORTED=0 # 支持 HT40
        nmcli con modify "$HOTSPOT_CONNECTION_NAME" 802-11-wireless.ht-mode HT40
    else
        HT40_SUPPORTED=1 # 不支持 HT40
        echo "当前环境不支持 HT40 模式，将使用兼容模式。"
    fi

    nmcli con up "$HOTSPOT_CONNECTION_NAME"

    if [[ $? -eq 0 ]]; then
        if [[ "$HT40_SUPPORTED" -eq 0 ]]; then
            echo "Wi-Fi 热点模式已启动：SSID=$WIFI_NAME，密码=$WIFI_PASSWORD，信道=9 (2.4GHz)，模式=802.11n HT40 (最佳模式)"
        else
            echo "Wi-Fi 热点模式已启动：SSID=$WIFI_NAME，密码=$WIFI_PASSWORD，信道=9 (2.4GHz)，模式=兼容模式"
        fi
        return 0 # 返回成功
    else
        echo "启动 Wi-Fi 热点失败 (nmcli con up)，请检查无线网卡是否支持热点模式或驱动是否正常工作。" >&2
        return 1 # 返回错误
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
        if [[ $? -ne 0 ]]; then
            echo "断开当前连接 $CURRENT_CONNECTION 失败。" >&2
            return 1  # 返回错误
        fi
        echo "已断开连接: $CURRENT_CONNECTION"
    fi

    echo "正在连接到 Wi-Fi 网络: $TARGET_SSID..."
    nmcli dev wifi connect "$TARGET_SSID" password "$TARGET_PASSWORD"  2>&1 | tee /tmp/wifi_connect.log # 重定向全部输出到日志

    sleep 3 # 等待3秒，给连接一些时间

    if [[ $? -eq 0 ]]; then
        echo "成功连接到 Wi-Fi 网络：$TARGET_SSID"
        return 0  # 返回成功
    else
        echo "连接到 Wi-Fi 网络失败，请检查 SSID 和密码，详细信息请查看 /tmp/wifi_connect.log。" >&2
        # 检查一下日志文件，看看是否有更详细的错误信息
        tail /tmp/wifi_connect.log
        return 1 # 返回错误
    fi
}

# 连接之前保存的 Wi-Fi 网络 (改进版 - 顺序尝试)
connect_previously_saved_wifi() {
    local INTERFACE=$1
    local connected=0  # 添加一个标志来跟踪是否成功连接

    echo "正在尝试连接已保存的 Wi-Fi 网络..."

    local SAVED_CONNECTIONS=$(nmcli con show | grep wifi | awk '{print $1}')

    if [[ -n "$SAVED_CONNECTIONS" ]]; then
        echo "已保存的 Wi-Fi 网络列表:"
        for CONNECTION in $SAVED_CONNECTIONS; do
            # 排除自身创建的热点（通过检查连接类型）
            CONNECTION_TYPE=$(nmcli con show "$CONNECTION" | grep "802-11-wireless.mode" | awk '{print $3}')
            if [[ "$CONNECTION_TYPE" == "ap" ]]; then
                echo "跳过自身创建的热点: $CONNECTION"
                continue
            fi

            echo "尝试连接到 Wi-Fi 网络: $CONNECTION..."
            nmcli con up "$CONNECTION" ifname "$INTERFACE"
            if [[ $? -eq 0 ]]; then
                echo "成功连接到 Wi-Fi 网络：$CONNECTION"
                connected=1 # 设置标志为已连接
                return 0  # 连接成功，退出函数
            else
                echo "连接到 Wi-Fi 网络 $CONNECTION 失败，请检查配置。"
            fi
        done

        echo "所有已保存的 Wi-Fi 网络连接尝试均失败。"
    else
        echo "没有找到已保存的 Wi-Fi 网络。"
    fi

    echo "未能自动连接到任何已保存的 Wi-Fi 网络。"
    return 1  # 所有尝试都失败，返回 1
}


# 自动切换 Wi-Fi 模式
auto_switch_wifi_mode() {
    local WIFI_INTERFACE=$(detect_wifi_interface)
    local NET_INTERFACE=$(detect_ethernet_interface)

    if [[ -z "$WIFI_INTERFACE" ]]; then
        echo "未检测到无线网卡，请检查硬件配置。" >&2
        return 1
    fi

    if [[ -z "$NET_INTERFACE" ]]; then
        echo "未检测到网线接口，请检查硬件配置。" >&2
        return 1
    fi

    # 强制断开所有 Wi-Fi 连接
    nmcli con down $(nmcli con show | grep wifi | awk '{print $1}') > /dev/null 2>&1
    echo "已断开所有 Wi-Fi 连接。"

    echo "正在检测网线状态..."
    check_ethernet_connection "$NET_INTERFACE"
    CONNECTION_STATUS=$?

    if [[ $CONNECTION_STATUS -eq 0 ]]; then
        echo "网线已连接，切换到 Wi-Fi 热点模式。"
        # 使用全局变量 CUSTOM_WIFI_NAME 和 CUSTOM_WIFI_PASSWORD 作为热点名称和密码
        create_wifi_hotspot "$WIFI_INTERFACE" "$CUSTOM_WIFI_NAME" "$CUSTOM_WIFI_PASSWORD"
        if [[ $? -ne 0 ]]; then
            echo "创建热点失败，请检查无线网卡是否支持热点模式或驱动是否正常工作。" >&2
        fi
    elif [[ $CONNECTION_STATUS -eq 1 ]]; then
        echo "网线未连接，切换到 Wi-Fi 客户端模式。"
        if connect_previously_saved_wifi "$WIFI_INTERFACE"; then
            echo "成功连接到 Wi-Fi 网络，保持客户端模式。"
        else
            echo "未能连接到任何已保存的 Wi-Fi 网络，切换到热点模式。"
            # 使用全局变量 CUSTOM_WIFI_NAME 和 CUSTOM_WIFI_PASSWORD 作为热点名称和密码
            create_wifi_hotspot "$WIFI_INTERFACE" "$CUSTOM_WIFI_NAME" "$CUSTOM_WIFI_PASSWORD"
            if [[ $? -ne 0 ]]; then
                echo "创建热点失败，请检查无线网卡是否支持热点模式或驱动是否正常工作。" >&2
            fi
        fi
    else
        echo "未检测到网线接口，请检查设备配置。" >&2
        return 1
    fi
    return 0
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
show_menu() {
    echo "请选择操作:"
    echo "1. 创建 Wi-Fi 发射点"
    echo "2. 连接其他 Wi-Fi 网络并删除已创建的热点"
    echo "3. 自动切换 Wi-Fi 模式（根据网线状态）"
    echo "4. 后台运行自动切换模式（自启动）"
    echo "5. 停止并卸载后台服务"
    echo "6. 查看保存的 Wi-Fi 网络并添加新网络"
    echo "7. 退出"
    read -p "输入选项 (1, 2, 3, 4, 5, 6 或 7): " choice
}

# 主循环
if [[ "$1" == "auto-switch" ]]; then
    local LAST_CONNECTION_STATUS=-1  # 初始化为无效状态
    local NET_INTERFACE=$(detect_ethernet_interface)  # 确保 NET_INTERFACE 被定义
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
    while true; do
        show_menu

        case $choice in
            1)
                INTERFACE=$(detect_wifi_interface)
                if [[ -z "$INTERFACE" ]]; then
                    echo "未检测到无线网卡，请检查硬件配置。" >&2
                    continue
                fi
                read -p "请输入 Wi-Fi 发射点名称（默认: 4G-WIFI）: " WIFI_NAME_INPUT
                WIFI_NAME="${WIFI_NAME_INPUT:-"$CUSTOM_WIFI_NAME"}" # 使用输入值或全局默认值
                read -p "请输入 Wi-Fi 发射点密码（默认: 12345678）: " WIFI_PASSWORD_INPUT
                WIFI_PASSWORD="${WIFI_PASSWORD_INPUT:-"$CUSTOM_WIFI_PASSWORD"}" # 使用输入值或全局默认值
                create_wifi_hotspot "$INTERFACE" "$WIFI_NAME" "$WIFI_PASSWORD"
                if [[ $? -ne 0 ]]; then
                    echo "创建 Wi-Fi 热点失败。" >&2
                fi
                ;;
            2)
                INTERFACE=$(detect_wifi_interface)
                if [[ -z "$INTERFACE" ]]; then
                    echo "未检测到无线网卡，请检查硬件配置。" >&2
                    continue
                fi
                read -p "请输入要连接的 Wi-Fi 网络名称: " TARGET_SSID
                read -p "请输入要连接的 Wi-Fi 网络密码: " TARGET_PASSWORD
                connect_wifi_network "$INTERFACE" "$TARGET_SSID" "$TARGET_PASSWORD"
                if [[ $? -ne 0 ]]; then
                    echo "连接 Wi-Fi 失败，请重试或检查日志。" >&2
                fi
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
            7)
                echo "退出脚本。"
                exit 0
                ;;
            *)
                echo "无效的选择，请输入 1、2、3、4、5、6 或 7。" >&2
                usage
                ;;
        esac
    done
fi

exit 0
