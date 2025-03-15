#!/bin/bash

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

# 检测设备架构
ARCH=$(uname -m)
echo "检测到的设备架构: $ARCH"

# 检查是否安装 nmcli
if ! command -v nmcli &> /dev/null; then
    echo "nmcli 未安装，正在安装 NetworkManager 工具..."
    if [[ "$DISTRO" == "debian" || "$DISTRO" == "ubuntu" ]]; then
        apt-get update && apt-get install -y network-manager
    elif [[ "$DISTRO" == "centos" || "$DISTRO" == "rhel" ]]; then
        yum install -y NetworkManager
    fi
fi

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
    exit 1
}

# 限制日志文件大小为 1MB 并清空
LOG_FILE="/var/log/wifi-hotspot.log"
if [[ -f "$LOG_FILE" ]]; then
    if [[ $(stat -c %s "$LOG_FILE") -gt 1048576 ]]; then
        > "$LOG_FILE"  # 清空日志文件
    fi
else
    touch "$LOG_FILE"
fi

# 将脚本的输出重定向到日志文件中
exec > >(tee -a "$LOG_FILE") 2>&1

# 动态检测无线网卡
INTERFACE=$(nmcli dev | grep wifi | awk '{print $1}' | head -n 1)
if [[ -z "$INTERFACE" ]]; then
    echo "未找到可用的无线网卡，请检查硬件配置。"
    exit 1
fi

echo "检测到的无线网卡: $INTERFACE"

# 显示菜单选项
echo "请选择操作:"
echo "1. 创建 Wi-Fi 发射点"
echo "2. 连接其他 Wi-Fi 网络并删除已创建的热点"
read -p "输入选项 (1 或 2): " choice

case $choice in
    1)
        # 删除所有旧的热点配置
        HOTSPOT_PREFIX="SharedHotspot-"
        OLD_HOTSPOTS=$(nmcli con | grep "${HOTSPOT_PREFIX}" | awk '{print $1}')
        if [[ -n "$OLD_HOTSPOTS" ]]; then
            echo "正在清理旧的热点配置..."
            for HOTSPOT in $OLD_HOTSPOTS; do
                echo "正在删除热点配置: $HOTSPOT"
                nmcli con down "$HOTSPOT" > /dev/null 2>&1
                nmcli con delete "$HOTSPOT" > /dev/null 2>&1
            done
            echo "旧的热点配置清理完成。"
        fi

        # 删除已连接的其他 Wi-Fi 网络
        CURRENT_CONNECTION=$(nmcli dev show "$INTERFACE" | grep "GENERAL.CONNECTION" | awk '{print $2}')
        if [[ -n "$CURRENT_CONNECTION" && "$CURRENT_CONNECTION" != "--" ]]; then
            echo "正在断开当前连接: $CURRENT_CONNECTION..."
            nmcli con down "$CURRENT_CONNECTION"
            echo "已断开连接: $CURRENT_CONNECTION"
        else
            echo "当前无线网卡未连接任何网络。"
        fi

        # 重置无线网卡
        echo "正在重置无线网卡: $INTERFACE..."
        nmcli dev set "$INTERFACE" managed no
        sleep 2
        nmcli dev set "$INTERFACE" managed yes
        sleep 2
        echo "无线网卡重置完成。"

        # 创建新的 Wi-Fi 发射点
        read -p "请输入 Wi-Fi 发射点名称（默认: 4G-WIFI）: " WIFI_NAME
        WIFI_NAME=${WIFI_NAME:-4G-WIFI}  # 如果用户未输入，则使用默认值

        # 提示用户输入 Wi-Fi 发射点密码
        while true; do
            read -p "请输入 Wi-Fi 发射点密码（默认: 12345678）: " WIFI_PASSWORD
            WIFI_PASSWORD=${WIFI_PASSWORD:-12345678}
            if [[ ${#WIFI_PASSWORD} -ge 8 ]]; then
                break
            else
                echo "密码长度必须至少为 8 位！"
            fi
        done

        # 创建 Wi-Fi 热点
        HOTSPOT_CONNECTION_NAME="SharedHotspot-$WIFI_NAME"
        echo "正在创建 Wi-Fi 发射点..."
        nmcli con add type wifi ifname "$INTERFACE" con-name "$HOTSPOT_CONNECTION_NAME" ssid "$WIFI_NAME" 802-11-wireless.mode ap
        nmcli con modify "$HOTSPOT_CONNECTION_NAME" 802-11-wireless-security.key-mgmt wpa-psk
        nmcli con modify "$HOTSPOT_CONNECTION_NAME" 802-11-wireless-security.psk "$WIFI_PASSWORD"
        nmcli con modify "$HOTSPOT_CONNECTION_NAME" ipv4.method shared
        nmcli con up "$HOTSPOT_CONNECTION_NAME"

        # 检查是否成功创建热点
        if [[ $? -eq 0 ]]; then
            echo "Wi-Fi 发射点已成功创建！"
            echo "-----------------------------------"
            echo "Wi-Fi 名称: $WIFI_NAME"
            echo "Wi-Fi 密码: $WIFI_PASSWORD"
            echo "-----------------------------------"
        else
            echo "创建 Wi-Fi 发射点失败，请检查无线网卡是否支持热点模式或驱动是否正常工作。"
            echo "提示：使用 'journalctl -xe NM_CONNECTION=$HOTSPOT_CONNECTION_NAME + NM_DEVICE=$INTERFACE' 来获得更详细的信息。"
            nmcli con show all 2>&1 | tee "$LOG_FILE"
            exit 1
        fi
        ;;
    2)
        # 删除所有旧的热点配置
        HOTSPOT_PREFIX="SharedHotspot-"
        OLD_HOTSPOTS=$(nmcli con | grep "${HOTSPOT_PREFIX}" | awk '{print $1}')
        if [[ -n "$OLD_HOTSPOTS" ]]; then
            echo "正在清理旧的热点配置..."
            for HOTSPOT in $OLD_HOTSPOTS; do
                echo "正在删除热点配置: $HOTSPOT"
                nmcli con down "$HOTSPOT" > /dev/null 2>&1
                nmcli con delete "$HOTSPOT" > /dev/null 2>&1
            done
            echo "旧的热点配置清理完成。"
        fi

        # 连接到其他 Wi-Fi 网络
        read -p "请输入要连接的 Wi-Fi 网络名称: " TARGET_SSID
        if [[ -z "$TARGET_SSID" ]]; then
            echo "Wi-Fi 网络名称不能为空！"
            exit 1
        fi

        # 提示用户输入要连接的 Wi-Fi 网络密码
        while true; do
            read -p "请输入要连接的 Wi-Fi 网络密码: " TARGET_PASSWORD
            if [[ -n "$TARGET_PASSWORD" ]]; then
                break
            else
                echo "Wi-Fi 网络密码不能为空！"
            fi
        done

        # 检查是否已经连接到目标 Wi-Fi 网络
        CURRENT_CONNECTION=$(nmcli dev show "$INTERFACE" | grep "GENERAL.CONNECTION" | awk '{print $2}')
        if [[ -n "$CURRENT_CONNECTION" && "$CURRENT_CONNECTION" == "$TARGET_SSID" ]]; then
            echo "已连接到目标 Wi-Fi 网络: $TARGET_SSID"
        else
            # 连接到目标 Wi-Fi 网络
            echo "正在连接到 Wi-Fi 网络: $TARGET_SSID..."
            nmcli dev wifi connect "$TARGET_SSID" password "$TARGET_PASSWORD"

            # 检查是否成功连接到目标 Wi-Fi 网络
            if [[ $? -ne 0 ]]; then
                echo "连接到 Wi-Fi 网络 $TARGET_SSID 失败，请检查输入的 SSID 和密码是否正确。"
                exit 1
            fi

            echo "成功连接到 Wi-Fi 网络: $TARGET_SSID"
        fi
        ;;
    *)
        echo "无效的选择，请输入 1 或 2。"
        usage
        ;;
esac

exit 0
