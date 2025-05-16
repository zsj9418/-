#!/bin/bash

# 默认 TUN 设备名称
DEFAULT_TUN_DEV="tun0"

# 检查是否以 root 权限运行
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo "Error: This script must be run as root" >&2
        exit 1
    fi
}

# 检查依赖并自动修复
check_dependencies() {
    # 检查 iproute2
    if ! command -v ip >/dev/null 2>&1; then
        echo "ip command not found. Attempting to install iproute2..."
        if command -v apt >/dev/null 2>&1; then
            apt update && apt install -y iproute2 || {
                echo "Error: Failed to install iproute2" >&2
                exit 1
            }
        elif command -v yum >/dev/null 2>&1; then
            yum install -y iproute2 || {
                echo "Error: Failed to install iproute2" >&2
                exit 1
            }
        elif command -v apk >/dev/null 2>&1; then
            apk add iproute2 || {
                echo "Error: Failed to install iproute2" >&2
                exit 1
            }
        else
            echo "Error: iproute2 not found and no known package manager detected" >&2
            exit 1
        fi
    fi

    # 检查 tun 模块
    if ! lsmod | grep -q tun; then
        echo "Loading tun module..."
        modprobe tun || {
            echo "Error: Failed to load tun module. Ensure kernel supports TUN/TAP" >&2
            exit 1
        }
    fi

    # 检查 /dev/net/tun
    if [ ! -c /dev/net/tun ]; then
        echo "Creating /dev/net/tun device..."
        mkdir -p /dev/net
        mknod /dev/net/tun c 10 200 || {
            echo "Error: Failed to create /dev/net/tun" >&2
            exit 1
        }
        chmod 666 /dev/net/tun
    fi

    # 检查容器环境
    if [ -f /proc/1/cgroup ] && grep -q 'docker\|lxc\|podman' /proc/1/cgroup; then
        echo "Warning: Running in a container. Ensure --cap-add=NET_ADMIN and --device=/dev/net/tun are set."
        read -p "Continue? [y/N]: " confirm
        [[ ! $confirm =~ ^[Yy]$ ]] && exit 1
    fi
}

# 验证 IP 地址格式
validate_ip() {
    local ip=$1
    if [[ ! $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo "Error: Invalid IP address format. Example: 192.168.1.1/24" >&2
        return 1
    fi
    return 0
}

# 获取可用网卡列表
get_available_interfaces() {
    ip link show | awk -F': ' '/^[0-9]+:/ {print $2}' | grep -v '^lo$'
}

# 选项 1：创建并永久配置 TUN 接口
setup_tun() {
    local dev="$DEFAULT_TUN_DEV"
    local ip_addr

    echo "Setting up TUN interface ($dev)..."
    # 检查是否已存在
    if ip link show "$dev" >/dev/null 2>&1; then
        echo "Warning: $dev already exists."
        read -p "Delete and recreate $dev? [y/N]: " confirm
        if [[ $confirm =~ ^[Yy]$ ]]; then
            ip link delete "$dev" || {
                echo "Error: Failed to delete $dev" >&2
                return 1
            }
        else
            echo "Operation aborted."
            return 1
        fi
    fi

    # 创建 TUN 接口
    ip tuntap add mode tun dev "$dev" || {
        echo "Error: Failed to create $dev interface" >&2
        return 1
    }
    ip link set "$dev" up || {
        echo "Error: Failed to activate $dev interface" >&2
        return 1
    }

    # 获取 IP 地址
    read -p "Enter IP address for $dev (e.g., 192.168.1.1/24): " ip_addr
    if ! validate_ip "$ip_addr"; then
        return 1
    fi
    ip addr add "$ip_addr" dev "$dev" || {
        echo "Error: Failed to set IP address $ip_addr on $dev" >&2
        return 1
    }

    # 自动检测持久化方式
    echo "Configuring persistent TUN interface..."
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active systemd-networkd >/dev/null 2>&1; then
        echo "Using systemd-networkd for persistence..."
        cat > /etc/systemd/network/20-tun0.netdev <<EOF
[NetDev]
Name=$dev
Kind=tun
EOF
        cat > /etc/systemd/network/20-tun0.network <<EOF
[Match]
Name=$dev

[Network]
Address=$ip_addr
EOF
        systemctl restart systemd-networkd || {
            echo "Warning: Failed to restart systemd-networkd" >&2
        }
    elif [ -f /etc/network/interfaces ]; then
        echo "Using /etc/network/interfaces for persistence..."
        echo -e "\nauto $dev\niface $dev inet static\n    address ${ip_addr%%/*}\n    netmask $(ipcalc -m "$ip_addr" | cut -d= -f2)" >> /etc/network/interfaces
    else
        echo "Warning: No supported method for persistent configuration found."
        read -p "Continue without persistent configuration? [y/N]: " confirm
        [[ ! $confirm =~ ^[Yy]$ ]] && return 1
    fi

    echo "TUN interface $dev created and configured successfully with IP $ip_addr"
    ip addr show "$dev"
}

# 选项 2：设置网卡混杂模式并永久生效
setup_promisc() {
    local dev
    local interfaces

    # 获取可用网卡
    mapfile -t interfaces < <(get_available_interfaces)
    if [ ${#interfaces[@]} -eq 0 ]; then
        echo "Error: No network interfaces found" >&2
        return 1
    fi

    # 显示网卡列表供用户选择
    echo "Available network interfaces:"
    for i in "${!interfaces[@]}"; do
        echo "$((i+1)). ${interfaces[i]}"
    done
    read -p "Select interface number (1-${#interfaces[@]}): " choice
    if [[ ! $choice =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#interfaces[@]} ]; then
        echo "Error: Invalid selection" >&2
        return 1
    fi
    dev="${interfaces[$((choice-1))]}"

    echo "Setting $dev to promiscuous mode..."
    ip link set "$dev" promisc on || {
        echo "Error: Failed to set $dev to promiscuous mode" >&2
        return 1
    }

    # 自动检测持久化方式
    echo "Configuring persistent promiscuous mode..."
    if command -v systemctl >/dev/null 2>&1; then
        echo "Using systemd service for persistence..."
        cat > /etc/systemd/system/promisc-$dev.service <<EOF
[Unit]
Description=Set $dev to promiscuous mode
After=network.target

[Service]
Type=oneshot
ExecStart=/sbin/ip link set $dev promisc on
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        systemctl enable promisc-$dev.service
        systemctl start promisc-$dev.service || {
            echo "Warning: Failed to start promisc-$dev.service" >&2
        }
    elif [ -f /etc/rc.local ]; then
        echo "Using /etc/rc.local for persistence..."
        sed -i '/exit 0/d' /etc/rc.local
        echo "ip link set $dev promisc on" >> /etc/rc.local
        echo "exit 0" >> /etc/rc.local
        chmod +x /etc/rc.local
    else
        echo "Warning: No supported method for persistent configuration found."
        read -p "Continue without persistent configuration? [y/N]: " confirm
        [[ ! $confirm =~ ^[Yy]$ ]] && return 1
    fi

    echo "Interface $dev set to promiscuous mode successfully"
    ip link show "$dev"
}

# 选项 3：查看接口状态
show_status() {
    echo "Listing all network interfaces:"
    ip link show
    echo -e "\nDetailed status for $DEFAULT_TUN_DEV (if exists):"
    ip addr show "$DEFAULT_TUN_DEV" 2>/dev/null || echo "$DEFAULT_TUN_DEV does not exist"
}

# 主菜单
main_menu() {
    while true; do
        echo -e "\n=== TUN Interface Configuration Menu ==="
        echo "1. Setup persistent TUN interface"
        echo "2. Set promiscuous mode for an interface"
        echo "3. Show network interface status"
        echo "4. Exit"
        read -p "Select an option [1-4]: " choice

        case $choice in
            1)
                setup_tun
                echo -e "\nOperation completed. Returning to main menu..."
                ;;
            2)
                setup_promisc
                echo -e "\nOperation completed. Returning to main menu..."
                ;;
            3)
                show_status
                echo -e "\nOperation completed. Returning to main menu..."
                ;;
            4)
                echo "Exiting..."
                exit 0
                ;;
            *)
                echo "Invalid option. Please select 1-4."
                ;;
        esac
    done
}

# 主程序
check_root
check_dependencies
main_menu
