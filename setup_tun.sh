#!/bin/bash

# 脚本名称
SCRIPT_NAME="setup_tun.sh"

# 默认配置
DEFAULT_TUN_INTERFACE="tun0"
DEFAULT_TUN_IP="10.0.0.1/24"
LOG_FILE="/var/log/setup_tun.log"

# 检测所需的命令
REQUIRED_COMMANDS=("ip" "modprobe" "systemctl")

# 检查并安装缺失的依赖
install_dependencies() {
    echo -e "\033[33m正在检查并安装缺失的依赖...\033[0m"
    
    # 检测操作系统
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_NAME=$NAME
        OS_VERSION=$VERSION_ID
    else
        echo -e "\033[31m错误: 无法检测操作系统。\033[0m"
        exit 1
    fi

    # 根据不同的操作系统安装依赖
    for cmd in "${REQUIRED_COMMANDS[@]}"; do
        if ! command -v $cmd &> /dev/null; then
            case $OS_NAME in
                *Ubuntu*|*Debian*)
                    echo -e "\033[33m未找到命令 $cmd，正在安装...\033[0m"
                    sudo apt update && sudo apt install -y iproute2
                    ;;
                *CentOS*|*RHEL*)
                    echo -e "\033[33m未找到命令 $cmd，正在安装...\033[0m"
                    sudo yum install -y iproute
                    ;;
                *macOS*)
                    echo -e "\033[33m未找到命令 $cmd，正在安装...\033[0m"
                    brew install iproute2mac
                    ;;
                *)
                    echo -e "\033[31m错误: 不支持的操作系统 $OS_NAME。\033[0m"
                    exit 1
                    ;;
            esac
        fi
    done
}

# 检查 TUN/TAP 支持
check_tun_support() {
    if [ ! -c /dev/net/tun ]; then
        echo -e "\033[31m错误: 设备不支持 TUN/TAP 功能，/dev/net/tun 不存在。\033[0m"
        exit 1
    fi
}

# 函数：记录日志
log_message() {
    # 限制日志文件大小为 1MB
    if [ -f "$LOG_FILE" ] && [ $(stat -c%s "$LOG_FILE") -ge 1048576 ]; then
        echo "" > $LOG_FILE  # 清空日志文件
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a $LOG_FILE
}

# 检查现有的 TUN 接口
check_existing_tun_interfaces() {
    echo -e "\033[33m当前设备上已开启的 TUN 接口:\033[0m"
    existing_interfaces=$(ip a | grep "tun" | awk '{print $2}' | sed 's/://')
    
    if [ -z "$existing_interfaces" ]; then
        echo -e "\033[32m没有发现已开启的 TUN 接口。\033[0m"
    else
        echo -e "\033[31m已开启的 TUN 接口: $existing_interfaces\033[0m"
        echo -e "\033[31m请注意，这些接口可能会与您即将创建的接口冲突。\033[0m"
    fi
}

# 配置防火墙规则
configure_firewall() {
    echo -e "\033[33m正在配置防火墙以允许 TUN 接口流量...\033[0m"
    
    # 检测操作系统
    if [[ "$OS_NAME" == *"Ubuntu"* || "$OS_NAME" == *"Debian"* ]]; then
        # 使用 UFW
        sudo ufw allow in on $TUN_INTERFACE
        sudo ufw allow out on $TUN_INTERFACE
    elif [[ "$OS_NAME" == *"CentOS"* || "$OS_NAME" == *"RHEL"* ]]; then
        # 使用 firewalld
        sudo firewall-cmd --zone=public --add-interface=$TUN_INTERFACE --permanent
        sudo firewall-cmd --reload
    else
        echo -e "\033[31m警告: 防火墙配置未处理，手动配置可能是必要的。\033[0m"
    fi
}

# 主程序
main() {
    install_dependencies    # 检查并安装缺失的依赖
    check_tun_support       # 检查 TUN/TAP 支持
    check_existing_tun_interfaces

    # 提示用户决定是否继续
    read -p "您希望继续创建 TUN 接口 $DEFAULT_TUN_INTERFACE 吗？(y/n): " user_choice
    if [[ "$user_choice" != "y" && "$user_choice" != "Y" ]]; then
        echo -e "\033[33m操作已取消。\033[0m"
        exit 0
    fi

    # 用户输入配置
    read -p "请输入 TUN 接口名称 (默认: $DEFAULT_TUN_INTERFACE): " USER_TUN_INTERFACE
    read -p "请输入 TUN IP 地址 (默认: $DEFAULT_TUN_IP): " USER_TUN_IP

    # 设置变量
    TUN_INTERFACE=${USER_TUN_INTERFACE:-$DEFAULT_TUN_INTERFACE}
    TUN_IP=${USER_TUN_IP:-$DEFAULT_TUN_IP}

    load_tun_module
    check_and_remove_tun_interface
    create_service
    enable_service
    configure_firewall  # 配置防火墙规则

    # 检查TUN接口状态
    if ip a show $TUN_INTERFACE &> /dev/null; then
        log_message "TUN接口 $TUN_INTERFACE 已成功创建并启动。"
    else
        log_message "错误: TUN接口 $TUN_INTERFACE 创建失败。"
        exit 1
    fi
}

# 加载TUN模块
load_tun_module() {
    if ! lsmod | grep -q tun; then
        if sudo modprobe tun; then
            log_message "成功: 加载 TUN 模块。"
        else
            log_message "错误: 加载 TUN 模块失败。"
            exit 1
        fi
    else
        log_message "警告: TUN 模块已加载。"
    fi
}

# 检查并删除现有的TUN接口
check_and_remove_tun_interface() {
    if ip a show $TUN_INTERFACE &> /dev/null; then
        log_message "警告: TUN接口 $TUN_INTERFACE 已存在，正在删除..."

        # 先将接口设置为关闭状态
        sudo ip link set dev $TUN_INTERFACE down 2>/dev/null

        # 尝试删除接口，支持重试机制
        for attempt in {1..3}; do
            if sudo ip tuntap del dev $TUN_INTERFACE; then
                log_message "成功: 删除现有的 TUN 接口 $TUN_INTERFACE。"
                return
            else
                log_message "错误: 删除 TUN 接口 $TUN_INTERFACE 失败，尝试 $attempt/3。"
                sleep 1
            fi
        done
        log_message "错误: 无法删除 TUN 接口 $TUN_INTERFACE，请手动检查。"
        exit 1
    fi
}

# 创建或更新TUN接口的服务文件
create_service() {
    SERVICE_FILE="/etc/systemd/system/tun.service"

    echo -e "[Unit]
Description=Setup TUN interface
After=network.target

[Service]
Type=oneshot
ExecStartPre=/sbin/ip tuntap del dev $TUN_INTERFACE
ExecStart=/sbin/ip tuntap add dev $TUN_INTERFACE mode tun
ExecStart=/sbin/ip addr add $TUN_IP dev $TUN_INTERFACE
ExecStart=/sbin/ip link set dev $TUN_INTERFACE up
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target" | sudo tee $SERVICE_FILE > /dev/null

    log_message "成功: 创建或更新服务文件 $SERVICE_FILE。"
}

# 启用并启动服务
enable_service() {
    sudo systemctl daemon-reload
    sudo systemctl enable tun.service
    sudo systemctl start tun.service

    if systemctl is-active --quiet tun.service; then
        log_message "成功: TUN 服务已启用并启动。"
    else
        log_message "错误: TUN 服务启动失败，请检查状态。"
        systemctl status tun.service | tee -a $LOG_FILE
        exit 1
    fi
}

# 执行主程序
main
