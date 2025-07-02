#!/bin/bash

set -euo pipefail

BACKUP_DIR="/tmp/network_backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

# 全局变量
OS_NAME=""
OS_VERSION=""
DEFAULT_IF=""
CURRENT_GW=""
CONFIG_FILES=()

# 用于提示危险操作
function warn_user(){
  echo "!!! 警告 !!!"
  echo "修改网络配置可能导致失去远程连接。"
  echo "请确保你有另一种方式访问此设备。"
  echo "请谨慎操作。"
  echo "-------------------------------------------"
}

function detect_system() {
    if [ -f /etc/os-release ]; then
        source /etc/os-release
        OS_NAME=$ID
        OS_VERSION=$VERSION_ID
    elif command -v lsb_release &>/dev/null; then
        OS_NAME=$(lsb_release -is | tr '[:upper:]' '[:lower:]')
        OS_VERSION=$(lsb_release -rs)
    else
        echo "无法检测系统类型，脚本退出"
        exit 1
    fi
}

# 通过 ip route 查找默认网络接口及网关
function detect_default_route() {
    # shellcheck disable=SC2046
    route_info=$(ip route show default 2>/dev/null || true)
    if [[ -z "$route_info" ]]; then
        echo "没有检测到默认路由"
        DEFAULT_IF=""
        CURRENT_GW=""
    else
        # ip route default format eg:
        # default via 192.168.1.1 dev eth0 proto dhcp metric 100
        CURRENT_GW=$(echo "$route_info" | awk '/default/ {for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}' || true)
        DEFAULT_IF=$(echo "$route_info" | awk '/default/ {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' || true)
    fi
}

# 备份网络配置
function backup_config() {
    echo "[备份] 开始备份当前网络配置..."
    CONFIG_FILES=()
    case "$OS_NAME" in
        ubuntu|debian)
            if command -v netplan >/dev/null 2>&1 && ls /etc/netplan/*.yaml 1> /dev/null 2>&1; then
                cp /etc/netplan/*.yaml "$BACKUP_DIR/" && CONFIG_FILES+=("/etc/netplan/*.yaml")
                echo "已备份 /etc/netplan/*.yaml 到 $BACKUP_DIR"
            else
                if [ -f /etc/network/interfaces ]; then
                    cp /etc/network/interfaces "$BACKUP_DIR/"
                    CONFIG_FILES+=("/etc/network/interfaces")
                    echo "已备份 /etc/network/interfaces 到 $BACKUP_DIR"
                else
                    echo "未找到需要备份的网络配置文件"
                fi
            fi
            ;;
        centos|rhel|rocky|fedora)
            # 备份所有ifcfg-接口配置和network文件
            cp /etc/sysconfig/network-scripts/ifcfg-* "$BACKUP_DIR/" 2>/dev/null || true
            cp /etc/sysconfig/network "$BACKUP_DIR/" 2>/dev/null || true
            if compgen -G "/etc/sysconfig/network-scripts/ifcfg-*" > /dev/null; then
              CONFIG_FILES+=("/etc/sysconfig/network-scripts/ifcfg-*")
            fi
            if [ -f /etc/sysconfig/network ]; then
              CONFIG_FILES+=("/etc/sysconfig/network")
            fi
            echo "已备份 CentOS/RHEL 网络配置到 $BACKUP_DIR"
            ;;
        *)
            echo "不支持的系统，无法自动备份配置，请手动备份"
            ;;
    esac
    echo "[备份] 完成！"
}

# 恢复备份
function restore_config() {
    echo "-------- 恢复操作 --------"
    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR")" ]; then
        echo "未发现备份文件或备份目录为空($BACKUP_DIR)，无法恢复"
        return
    fi

    echo "确认恢复备份吗？这将覆盖当前网络配置。"
    read -rp "输入 yes 以确认恢复： " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo "取消恢复操作。"
        return
    fi

    case "$OS_NAME" in
        ubuntu|debian)
            if command -v netplan >/dev/null 2>&1 && ls /etc/netplan/*.yaml > /dev/null 2>&1; then
                echo "恢复备份的 netplan 配置..."
                cp "$BACKUP_DIR"/*.yaml /etc/netplan/
                echo "恢复完成。请执行 'sudo netplan apply' 使之生效。"
            else
                if [ -f "$BACKUP_DIR/interfaces" ]; then
                    echo "恢复备份的 /etc/network/interfaces..."
                    cp "$BACKUP_DIR/interfaces" /etc/network/interfaces
                    echo "恢复完成。请重启网络或机器生效。"
                else
                    echo "未找到备份文件 interfaces。"
                fi
            fi
            ;;
        centos|rhel|rocky|fedora)
            echo "恢复备份的网络配置脚本..."
            cp "$BACKUP_DIR"/ifcfg-* /etc/sysconfig/network-scripts/ 2>/dev/null || true
            cp "$BACKUP_DIR"/network /etc/sysconfig/ 2>/dev/null || true
            echo "恢复完成。请重启网络服务或系统。"
            ;;
        *)
            echo "不支持自动恢复，请手动恢复备份文件。"
            ;;
    esac
}

# 配置网关（自动识别配置方式）
function configure_gateway() {
    if [ -z "$DEFAULT_IF" ]; then
        echo "未检测到默认网络接口，无法修改配置"
        return
    fi
    echo "当前默认网卡：$DEFAULT_IF"
    echo "当前默认网关：$CURRENT_GW"
    echo "请输入新的默认网关地址（留空取消修改）："
    read -r NEW_GW
    if [[ -z "$NEW_GW" ]]; then
        echo "取消修改。"
        return
    fi

    if ! [[ "$NEW_GW" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "输入的网关地址格式不正确，取消修改。"
        return
    fi

    warn_user
    backup_config

    case "$OS_NAME" in
        ubuntu|debian)
            if command -v netplan >/dev/null 2>&1 && ls /etc/netplan/*.yaml > /dev/null 2>&1; then
                NETPLAN_FILE=$(ls /etc/netplan/*.yaml | head -n1)
                cp "$NETPLAN_FILE" "$BACKUP_DIR/netplan_backup.yaml"
                echo "[修改] 修改 $NETPLAN_FILE 的网关..."
                if grep -q "gateway4:" "$NETPLAN_FILE"; then
                    sed -i "s/\(gateway4:\).*/\1 $NEW_GW/" "$NETPLAN_FILE"
                else
                    # 为防止格式出错，这里只提示手动修改
                    echo "netplan 配置文件中无 'gateway4:' 字段，请手动检查。"
                    return
                fi
                echo "[修改] 应用 netplan 配置..."
                if netplan apply; then
                    echo "netplan 应用成功，网络立即生效。"
                else
                    echo "netplan 应用失败，请手动检查。"
                fi
            else
                IFACE_FILE="/etc/network/interfaces"
                cp "$IFACE_FILE" "$BACKUP_DIR/interfaces_backup"
                echo "[修改] 修改 $IFACE_FILE 添加或替换网关配置..."
                if grep -q "gateway" "$IFACE_FILE"; then
                    sed -i "s/^gateway.*/gateway $NEW_GW/" "$IFACE_FILE"
                else
                    sed -i "/iface $DEFAULT_IF inet static/a gateway $NEW_GW" "$IFACE_FILE"
                fi
                echo "重启 networking 服务使配置生效..."
                if systemctl restart networking 2>/dev/null; then
                    echo "networking 服务重启成功。"
                elif /etc/init.d/networking restart 2>/dev/null; then
                    echo "networking 服务重启成功。"
                else
                    echo "networking 服务重启失败，请手动重启网络或重启机器。"
                fi
            fi
            ;;
        centos|rhel|rocky|fedora)
            CFG_FILE="/etc/sysconfig/network-scripts/ifcfg-$DEFAULT_IF"
            if [ ! -f "$CFG_FILE" ]; then
                echo "$CFG_FILE 未找到，无法修改。"
                return
            fi
            cp "$CFG_FILE" "$BACKUP_DIR/ifcfg-$DEFAULT_IF.backup"
            echo "[修改] 修改 $CFG_FILE 添加或替换 GATEWAY=$NEW_GW ..."
            if grep -q "^GATEWAY=" "$CFG_FILE"; then
                sed -i "s/^GATEWAY=.*/GATEWAY=$NEW_GW/" "$CFG_FILE"
            else
                echo "GATEWAY=$NEW_GW" >> "$CFG_FILE"
            fi
            NET_FILE="/etc/sysconfig/network"
            if [ -f "$NET_FILE" ]; then
                if grep -q "^GATEWAY=" "$NET_FILE"; then
                    sed -i "s/^GATEWAY=.*/GATEWAY=$NEW_GW/" "$NET_FILE"
                else
                    echo "GATEWAY=$NEW_GW" >> "$NET_FILE"
                fi
            fi
            echo "重启 NetworkManager 服务使配置生效..."
            if systemctl restart NetworkManager 2>/dev/null; then
                echo "NetworkManager 重启成功，网络立即生效。"
            elif service network restart 2>/dev/null; then
                echo "network 服务重启成功，网络立即生效。"
            else
                echo "重启服务失败，请手动重启网络或机器。"
            fi
            ;;
        *)
            echo "系统不支持自动修改网关，请手动修改配置。"
            ;;
    esac
}

function show_status() {
    echo "系统信息：$OS_NAME $OS_VERSION"
    echo "默认网络接口：$DEFAULT_IF"
    echo "当前默认网关：$CURRENT_GW"
    echo "备份目录：$BACKUP_DIR"
}

function main_menu() {
    while true; do
        detect_default_route
        clear
        show_status
        echo "-----------------------------------------"
        echo " 1) 备份当前网络配置"
        echo " 2) 恢复网络配置（恢复最近备份）"
        echo " 3) 查看当前默认网关"
        echo " 4) 修改默认网关"
        echo " 5) 退出"
        echo "请选择操作 (1-5):"
        read -r choice
        case $choice in
            1) backup_config ;;
            2) restore_config ;;
            3) echo "当前默认网关: $CURRENT_GW"; read -rp "按回车返回菜单" dummy ;;
            4) configure_gateway; read -rp "按回车返回菜单" dummy ;;
            5) echo "退出程序"; exit 0 ;;
            *) echo "无效选择，请输入 1-5"; read -rp "按回车继续" dummy ;;
        esac
    done
}

# 入口
detect_system
warn_user
main_menu
