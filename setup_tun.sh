#!/bin/bash

# 默认推荐的 TUN IP 地址
DEFAULT_TUN_IP="10.0.0.1/24"

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
        }
    fi

    # 检查 iptables
    if ! command -v iptables >/dev/null 2>&1; then
        echo "iptables not found. Attempting to install iptables..."
        if command -v apt >/dev/null 2>&1; then
            apt install -y iptables || {
                echo "Error: Failed to install iptables" >&2
                exit 1
            }
        elif command -v yum >/dev/null 2>&1; then
            yum install -y iptables || {
                echo "Error: Failed to install iptables" >&2
                exit 1
            }
        elif command -v apk >/dev/null 2>&1; then
            apk add iptables || {
                echo "Error: Failed to install iptables" >&2
                exit 1
            }
        else
            echo "Error: iptables not found and no known package manager detected" >&2
            exit 1
        }
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
        echo "Error: Invalid IP address format. Example: 10.0.0.1/24" >&2
        return 1
    fi
    return 0
}

# 检查 IP 是否冲突
check_ip_conflict() {
    local ip=$1
    local dev=$2
    if ip addr show | grep -q "${ip%%/*}"; then
        for iface in $(ip addr show | grep "${ip%%/*}" | awk '{print $NF}'); do
            if [ "$iface" != "$dev" ]; then
                echo "Error: IP $ip is already in use on interface $iface" >&2
                return 1
            fi
        done
    fi
    return 0
}

# 生成唯一的 TUN 设备名
generate_tun_dev() {
    local i=0
    local dev
    while true; do
        dev="tun$i"
        if ! ip link show "$dev" >/dev/null 2>&1; then
            echo "$dev"
            return 0
        fi
        ((i++))
    done
}

# 获取未使用的路由表 ID
get_free_route_table() {
    local i=100
    while grep -q "^$i[[:space:]]" /etc/iproute2/rt_tables 2>/dev/null; do
        ((i++))
    done
    echo "$i"
}

# 获取可用网卡列表（优先 UP 状态）
get_available_interfaces() {
    local interfaces=()
    while IFS= read -r line; do
        iface=$(echo "$line" | awk -F': ' '{print $2}')
        if [[ "$iface" != "lo" ]]; then
            interfaces+=("$iface")
        fi
    done < <(ip link show | grep '^[0-9]+:' | grep -E 'state (UP|UNKNOWN)')
    if [ ${#interfaces[@]} -eq 0 ]; then
        # 回退到所有非 lo 接口
        ip link show | awk -F': ' '/^[0-9]+:/ {print $2}' | grep -v '^lo$'
    else
        printf '%s\n' "${interfaces[@]}"
    fi
}

# 清理函数（失败时回滚）
cleanup() {
    local dev=$1
    local table_id=$2
    echo "Cleaning up partial configuration..."
    ip link delete "$dev" 2>/dev/null
    ip rule del table "$table_id" 2>/dev/null
    ip route flush table "$table_id" 2>/dev/null
    iptables -t nat -F POSTROUTING 2>/dev/null
}

# 选项 1：创建并永久配置 TUN 接口
setup_tun() {
    local dev
    local ip_addr
    local lan_dev
    local table_id
    local ipv6_enable="no"

    # 动态生成 TUN 设备名
    dev=$(generate_tun_dev)
    echo "Using TUN interface: $dev"

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

    # 获取 IP 地址
    read -p "Enter IP address for $dev (default: $DEFAULT_TUN_IP): " ip_addr
    ip_addr=${ip_addr:-$DEFAULT_TUN_IP}
    if ! validate_ip "$ip_addr"; then
        return 1
    fi
    if ! check_ip_conflict "$ip_addr" "$dev"; then
        return 1
    fi

    # 询问是否启用 IPv6
    read -p "Enable IPv6 for $dev? [y/N]: " confirm_ipv6
    if [[ $confirm_ipv6 =~ ^[Yy]$ ]]; then
        ipv6_enable="yes"
    fi

    # 获取局域网网卡
    mapfile -t interfaces < <(get_available_interfaces)
    if [ ${#interfaces[@]} -eq 0 ]; then
        echo "Error: No network interfaces found" >&2
        return 1
    fi
    if [ ${#interfaces[@]} -eq 1 ]; then
        lan_dev="${interfaces[0]}"
        echo "Using LAN interface: $lan_dev"
    else
        echo "Available LAN interfaces:"
        for i in "${!interfaces[@]}"; do
            echo "$((i+1)). ${interfaces[i]}"
        done
        read -p "Select LAN interface number (1-${#interfaces[@]}): " choice
        if [[ ! $choice =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#interfaces[@]} ];        lan_dev="${interfaces[$((choice-1))]}"
    fi

    # 获取路由表 ID
    table_id=$(get_free_route_table)

    # 创建 TUN 接口
    ip tuntap add mode tun dev "$dev" || {
        echo "Error: Failed to create $dev interface" >&2
        return 1
    }
    ip link set "$dev" up || {
        echo "Error: Failed to activate $dev interface" >&2
        cleanup "$dev" "$table_id"
        return 1
    }
    ip addr add "$ip_addr" dev "$dev" || {
        echo "Error: Failed to set IP address $ip_addr on $dev" >&2
        cleanup "$dev" "$table_id"
        return 1
    }
    if [ "$ipv6_enable" = "yes" ]; then
        ip -6 addr add "fd00::1/64" dev "$dev" || {
            echo "Warning: Failed to set IPv6 address on $dev" >&2
        }
    fi

    # 配置 NAT 和路由
    echo "Configuring NAT and routing for transparent proxy..."
    sysctl -w net.ipv4.ip_forward=1 >/dev/null || {
        echo "Error: Failed to enable IP forwarding" >&2
        cleanup "$dev" "$table_id"
        return 1
    }
    if [ "$ipv6_enable" = "yes" ]; then
        sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null || {
            echo "Warning: Failed to enable IPv6 forwarding" >&2
        }
    fi
    iptables -t nat -A POSTROUTING -o "$lan_dev" -j MASQUERADE || {
        echo "Error: Failed to set NAT rules" >&2
        cleanup "$dev" "$table_id"
        return 1
    }
    ip route add default dev "$dev" table "$table_id" || {
        echo "Error: Failed to add routing rule" >&2
        cleanup "$dev" "$table_id"
        return 1
    }
    ip rule add fwmark 1 table "$table_id" || {
        echo "Error: Failed to add routing policy" >&2
        cleanup "$dev" "$table_id"
        return 1
    }
    if [ "$ipv6_enable" = "yes" ]; then
        ip -6 route add default dev "$dev" table "$table_id" || {
            echo "Warning: Failed to add IPv6 routing rule" >&2
        }
        ip -6 rule add fwmark 1 table "$table_id" || {
            echo "Warning: Failed to add IPv6 routing policy" >&2
        }
    fi

    # 配置持久化
    echo "Configuring persistent TUN interface..."
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active systemd-networkd >/dev/null 2>&1; then
        echo "Using systemd-networkd for persistence..."
        cat > "/etc/systemd/network/20-$dev.netdev" <<EOF
[NetDev]
Name=$dev
Kind=tun
EOF
        cat > "/etc/systemd/network/20-$dev.network" <<EOF
[Match]
Name=$dev

[Network]
Address=$ip_addr
EOF
        if [ "$ipv6_enable" = "yes" ]; then
            echo "Address=fd00::1/64" >> "/etc/systemd/network/20-$dev.network"
        fi
        systemctl restart systemd-networkd || {
            echo "Warning: Failed to restart systemd-networkd" >&2
        }
    elif [ -f /etc/network/interfaces ]; then
        echo "Using /etc/network/interfaces for persistence..."
        echo -e "\nauto $dev\niface $dev inet static\n    address ${ip_addr%%/*}\n    netmask $(ipcalc -m "$ip_addr" | cut -d= -f2)" >> /etc/network/interfaces
        if [ "$ipv6_enable" = "yes" ]; then
            echo -e "\niface $dev inet6 static\n    address fd00::1\n    netmask 64" >> /etc/network/interfaces
        fi
    else
        echo "Warning: No supported method for persistent TUN configuration found."
        read -p "Continue without persistent TUN configuration? [y/N]: " confirm
        if [[ ! $confirm =~ ^[Yy]$ ]]; then
            cleanup "$dev" "$table_id"
            return 1
        fi
    fi

    # 保存 iptables 规则
    echo "Configuring persistent iptables rules..."
    if command -v iptables-save >/dev/null 2>&1; then
        iptables-save > /etc/iptables.rules
        if command -v iptables-persistent >/dev/null 2>&1; then
            echo "Using iptables-persistent for persistence..."
            systemctl enable iptables-persistent 2>/dev/null
        elif [ -f /etc/rc.local ]; then
            echo "Using /etc/rc.local for iptables persistence..."
            sed -i '/exit 0/d' /etc/rc.local
            echo "iptables-restore < /etc/iptables.rules" >> /etc/rc.local
            echo "exit 0" >> /etc/rc.local
            chmod +x /etc/rc.local
        else
            echo "Warning: No supported method for persistent iptables rules found."
            read -p "Continue without persistent iptables rules? [y/N]: " confirm
            if [[ ! $confirm =~ ^[Yy]$ ]]; then
                cleanup "$dev" "$table_id"
                return 1
            fi
        fi
    fi

    echo "TUN interface $dev configured for transparent proxy with IP $ip_addr"
    if [ "$ipv6_enable" = "yes" ]; then
        echo "IPv6 address fd00::1/64 configured on $dev"
    fi
    echo "Configure your proxy tool (e.g., sing-box, mihomo) to use $dev"
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
    if [[ ! $choice =~ ^[0-9]+$' ]]; then
        echo "Error: Invalid selection" >&2
        return 1
    fi
    if [ "$choice" -lt 1 ] || [ "$choice" -gt ${#interfaces[@]} ]; then
        echo "Error: Invalid selection" >&2
        return 1
    fi
    dev="${interfaces[$((choice-1))]}"

    echo "Setting $dev to promiscuous mode..."
    ip link set "$dev" promisc on || {
        echo "Error: Failed to set $dev to promiscuous mode" >&2
        return 1
    }

    # 配置持久化
    echo "Configuring persistent promiscuous mode..."
    if command -v systemctl >/dev/null 2>&1; then
        echo "Using systemd service for persistence..."
        cat > "/etc/systemd/system/promisc-$dev.service" <<EOF
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
        systemctl enable "promisc-$dev.service"
        systemctl start "promisc-$dev “

.service" || {
            echo "Warning: Failed to start promisc-$dev.service" >&2
        }
    elif [ -f /etc/rc.local ]; then
        echo "Using /etc/rc.local for persistence..."
        sed -i '/exit 0/d' /etc/rc.local
        echo "ip link set $dev promisc on" >> /etc/rc.local
        echo "exit 0" >> /etc/rc.local
        chmod +x /etc/rc.local
    else
        echo "Warning: No supported method for persistent promiscuous mode found."
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
    echo -e "\nDetailed status for TUN interfaces:"
    local found=0
    for dev in $(ip link show | awk -F': ' '/tun[0-9]+/ {print $2}'); do
        ip addr show "$dev"
        found=1
    done
    if [ "$found" -eq 0 ]; then
        echo "No TUN interfaces found"
    fi
}

# 主菜单
main_menu() {
    while true; do
        echo -e "\n=== Transparent Proxy TUN Configuration Menu ==="
        echo "1. Setup persistent TUN interface for transparent proxy"
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
