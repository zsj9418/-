#!/bin/bash

# 默认推荐的 TUN IP 地址
DEFAULT_TUN_IP="10.0.0.1/24"

# 检查是否以 root 权限运行
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo "错误：此脚本必须以 root 权限运行" >&2
        exit 1
    fi
}

# 检查依赖并自动修复
check_dependencies() {
    # 检查 iproute2
    if ! command -v ip >/dev/null 2>&1; then
        echo "ip 命令未找到，尝试安装 iproute2..."
        if command -v apt >/dev/null 2>&1; then
            apt update && apt install -y iproute2 || {
                echo "错误：无法安装 iproute2" >&2
                exit 1
            }
        elif command -v yum >/dev/null 2>&1; then
            yum install -y iproute2 || {
                echo "错误：无法安装 iproute2" >&2
                exit 1
            }
        elif command -v apk >/dev/null 2>&1; then
            apk add iproute2 || {
                echo "错误：无法安装 iproute2" >&2
                exit 1
            }
        else
            echo "错误：未找到 iproute2 且未检测到已知包管理器" >&2
            exit 1
        fi
    fi

    # 检查 iptables
    if ! command -v iptables >/dev/null 2>&1; then
        echo "iptables 未找到，尝试安装 iptables..."
        if command -v apt >/dev/null 2>&1; then
            apt install -y iptables || {
                echo "错误：无法安装 iptables" >&2
                exit 1
            }
        elif command -v yum >/dev/null 2>&1; then
            yum install -y iptables || {
                echo "错误：无法安装 iptables" >&2
                exit 1
            }
        elif command -v apk >/dev/null 2>&1; then
            apk add iptables || {
                echo "错误：无法安装 iptables" >&2
                exit 1
            }
        else
            echo "错误：未找到 iptables 且未检测到已知包管理器" >&2
            exit 1
        fi
    fi

    # 检查 ipcalc（用于 /etc/network/interfaces）
    if ! command -v ipcalc >/dev/null 2>&1; then
        echo "ipcalc 未找到，尝试安装 ipcalc..."
        if command -v apt >/dev/null 2>&1; then
            apt install -y ipcalc || {
                echo "警告：无法安装 ipcalc，/etc/network/interfaces 配置可能失败" >&2
            }
        elif command -v yum >/dev/null 2>&1; then
            yum install -y ipcalc || {
                echo "警告：无法安装 ipcalc，/etc/network/interfaces 配置可能失败" >&2
            }
        elif command -v apk >/dev/null 2>&1; then
            apk add ipcalc || {
                echo "警告：无法安装 ipcalc，/etc/network/interfaces 配置可能失败" >&2
            }
        else
            echo "警告：未找到 ipcalc，/etc/network/interfaces 配置可能失败" >&2
        fi
    fi

    # 检查 tun 支持
    if lsmod | grep -q tun; then
        echo "tun 模块已加载"
    elif [ -c /dev/net/tun ]; then
        echo "tun 功能可能已编译进内核，/dev/net/tun 存在"
    else
        echo "尝试加载 tun 模块..."
        modprobe tun 2>/dev/null
        if lsmod | grep -q tun; then
            echo "tun 模块加载成功"
        else
            echo "创建 /dev/net/tun 设备..."
            mkdir -p /dev/net
            mknod /dev/net/tun c 10 200 2>/dev/null
            chmod 666 /dev/net/tun 2>/dev/null
            if [ -c /dev/net/tun ]; then
                echo "/dev/net/tun 创建成功，tun 可能已编译进内核"
            else
                echo "错误：无法加载 tun 模块或创建 /dev/net/tun" >&2
                echo "请检查内核是否支持 TUN/TAP（CONFIG_TUN），或运行选项 4 修复" >&2
                return 1
            fi
        fi
    fi

    # 检查容器环境
    if [ -f /proc/1/cgroup ] && grep -q 'docker\|lxc\|podman' /proc/1/cgroup; then
        echo "警告：检测到容器环境，请确保已设置 --cap-add=NET_ADMIN 和 --device=/dev/net/tun"
        read -p "是否继续？[y/N]: " confirm
        if [[ ! $confirm =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
}

# 修复 TUN 模块
fix_tun() {
    echo "检查 TUN/TAP 支持状态..."
    if lsmod | grep -q tun; then
        echo "tun 模块已加载，无需修复"
    elif [ -c /dev/net/tun ]; then
        echo "tun 功能可能已编译进内核，/dev/net/tun 存在，无需修复"
    else
        echo "尝试加载 tun 模块..."
        modprobe tun 2>/dev/null
        if lsmod | grep -q tun; then
            echo "tun 模块加载成功"
        else
            echo "尝试创建 /dev/net/tun 设备..."
            mkdir -p /dev/net
            mknod /dev/net/tun c 10 200 2>/dev/null
            chmod 666 /dev/net/tun 2>/dev/null
            if [ -c /dev/net/tun ]; then
                echo "/dev/net/tun 创建成功，tun 可能已编译进内核"
            else
                echo "错误：无法加载 tun 模块或创建 /dev/net/tun" >&2
                echo "可能原因："
                echo "1. 内核未启用 CONFIG_TUN（TUN/TAP 支持）"
                echo "2. 内核模块目录 /lib/modules/$(uname -r) 缺失或不完整"
                echo "3. 系统限制（如容器或自定义内核）"
                echo "建议修复步骤："
                echo "- 检查内核配置：cat /boot/config-$(uname -r) | grep CONFIG_TUN"
                echo "  - CONFIG_TUN=m 表示模块化支持"
                echo "  - CONFIG_TUN=y 表示编译进内核"
                echo "  - 未找到表示不支持"
                echo "- 安装匹配的内核模块："
                echo "  - Ubuntu/Debian：sudo apt install linux-modules-$(uname -r)"
                echo "  - CentOS：sudo yum install kernel-modules-$(uname -r)"
                echo "- 重新编译内核启用 CONFIG_TUN：参考内核文档"
                echo "- 若在容器中，确保 --device=/dev/net/tun 已设置"
                read -p "是否尝试重新加载模块并继续？[y/N]: " confirm
                if [[ $confirm =~ ^[Yy]$ ]]; then
                    modprobe tun 2>/dev/null
                    if lsmod | grep -q tun || [ -c /dev/net/tun ]; then
                        echo "tun 支持已修复"
                    else
                        echo "错误：修复失败，请按上述建议手动修复" >&2
                        return 1
                    fi
                else
                    echo "操作已取消"
                    return 1
                fi
            fi
        fi
    fi
    echo "TUN/TAP 检查完成"
}

# 验证 IP 地址格式
validate_ip() {
    local ip=$1
    if [[ ! $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo "错误：IP 地址格式无效，示例：10.0.0.1/24" >&2
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
                echo "错误：IP $ip 已被接口 $iface 使用" >&2
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
    echo "清理部分配置..."
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
    echo "使用 TUN 接口：$dev"

    # 检查是否已存在
    if ip link show "$dev" >/dev/null 2>&1; then
        echo "警告：$dev 已存在"
        read -p "是否删除并重新创建 $dev？[y/N]: " confirm
        if [[ $confirm =~ ^[Yy]$ ]]; then
            ip link delete "$dev" || {
                echo "错误：无法删除 $dev" >&2
                return 1
            }
        else
            echo "操作已取消"
            return 1
        fi
    fi

    # 获取 IP 地址
    read -p "输入 $dev 的 IP 地址（默认：$DEFAULT_TUN_IP）： " ip_addr
    ip_addr=${ip_addr:-$DEFAULT_TUN_IP}
    if ! validate_ip "$ip_addr"; then
        return 1
    fi
    if ! check_ip_conflict "$ip_addr" "$dev"; then
        return 1
    fi

    # 询问是否启用 IPv6
    read -p "为 $dev 启用 IPv6？[y/N]: " confirm_ipv6
    if [[ $confirm_ipv6 =~ ^[Yy]$支架y]$ ]]; then
        ipv6_enable="yes"
    fi

    # 获取局域网网卡
    mapfile -t interfaces < <(get_available_interfaces)
    if [ ${#interfaces[@]} -eq 0 ]; then
        echo "错误：未找到网络接口" >&2
        return 1
    fi
    if [ ${#interfaces[@]} -eq 1 ]; then
        lan_dev="${interfaces[0]}"
        echo "使用局域网接口：$lan_dev"
    else
        echo "可用局域网接口："
        for i in "${!interfaces[@]}"; do
            echo "$((i+1)). ${interfaces[i]}"
        done
        read -p "选择局域网接口编号 (1-${#interfaces[@]}): " choice
        if [[ ! $choice =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#interfaces[@]} ]; then
            echo "错误：无效的选择" >&2
            return 1
        fi
        lan_dev="${interfaces[$((choice-1))]}"
    fi

    # 获取路由表 ID
    table_id=$(get_free_route_table)

    # 创建 TUN 接口
    ip tuntap add mode tun dev "$dev" || {
        echo "错误：无法创建 $dev 接口" >&2
        return 1
    }
    ip link set "$dev" up || {
        echo "错误：无法激活 $dev 接口" >&2
        cleanup "$dev" "$table_id"
        return 1
    }
    ip addr add "$ip_addr" dev "$dev" || {
        echo "错误：无法为 $dev 设置 IP 地址 $ip_addr" >&2
        cleanup "$dev" "$table_id"
        return 1
    }
    if [ "$ipv6_enable" = "yes" ]; then
        ip -6 addr add "fd00::1/64" dev "$dev" || {
            echo "警告：无法为 $dev 设置 IPv6 地址" >&2
        }
    fi

    # 配置 NAT 和路由
    echo "为透明代理配置 NAT 和路由..."
    sysctl -w net.ipv4.ip_forward=1 >/dev/null || {
        echo "错误：无法启用 IP 转发" >&2
        cleanup "$dev" "$table_id"
        return 1
    }
    if [ "$ipv6_enable" = "yes" ]; then
        sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null || {
            echo "警告：无法启用 IPv6 转发" >&2
        }
    fi
    iptables -t nat -A POSTROUTING -o "$lan_dev" -j MASQUERADE || {
        echo "错误：无法设置 NAT 规则" >&2
        cleanup "$dev" "$table_id"
        return 1
    }
    ip route add default dev "$dev" table "$table_id" || {
        echo "错误：无法添加路由规则" >&2
        cleanup "$dev" "$table_id"
        return 1
    }
    ip rule add fwmark 1 table "$table_id" || {
        echo "错误：无法添加路由策略" >&2
        cleanup "$dev" "$table_id"
        return 1
    }
    if [ "$ipv6_enable" = "yes" ]; then
        ip -6 route add default dev "$dev" table "$table_id" || {
            echo "警告：无法添加 IPv6 路由规则" >&2
        }
        ip -6 rule add fwmark 1 table "$table_id" || {
            echo "警告：无法添加 IPv6 路由策略" >&2
        }
    fi

    # 配置持久化
    echo "配置持久化 TUN 接口..."
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active systemd-networkd >/dev/null 2>&1; then
        echo "使用 systemd-networkd 进行持久化..."
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
            echo "警告：无法重启 systemd-networkd" >&2
        }
    elif [ -f /etc/network/interfaces ]; then
        echo "使用 /etc/network/interfaces 进行持久化..."
        echo -e "\nauto $dev\niface $dev inet static\n    address ${ip_addr%%/*}\n    netmask $(ipcalc -m "$ip_addr" | cut -d= -f2)" >> /etc/network/interfaces
        if [ "$ipv6_enable" = "yes" ]; then
            echo -e "\niface $dev inet6 static\n    address fd00::1\n    netmask 64" >> /etc/network/interfaces
        fi
    else
        echo "警告：未找到支持的持久化方法"
        read -p "是否继续而不进行持久化配置？[y/N]: " confirm
        if [[ ! $confirm =~ ^[Yy]$ ]]; then
            cleanup "$dev" "$table_id"
            return 1
        fi
    fi

    # 保存 iptables 规则
    echo "配置持久化 iptables 规则..."
    if command -v iptables-save >/dev/null 2>&1; then
        iptables-save > /etc/iptables.rules
        if command -v iptables-persistent >/dev/null 2>&1; then
            echo "使用 iptables-persistent 进行持久化..."
            systemctl enable iptables-persistent 2>/dev/null
        elif [ -f /etc/rc.local ]; then
            echo "使用 /etc/rc.local 进行 iptables 持久化..."
            sed -i '/exit 0/d' /etc/rc.local
            echo "iptables-restore < /etc/iptables.rules" >> /etc/rc.local
            echo "exit 0" >> /etc/rc.local
            chmod +x /etc/rc.local
        else
            echo "警告：未找到支持的 iptables 持久化方法"
            read -p "是否继续而不进行持久化 iptables 规则？[y/N]: " confirm
            if [[ ! $confirm =~ ^[Yy]$ ]]; then
                cleanup "$dev" "$table_id"
                return 1
            fi
        fi
    fi

    echo "TUN 接口 $dev 已为透明代理配置完成，IP 为 $ip_addr"
    if [ "$ipv6_enable" = "yes" ]; then
        echo "IPv6 地址 fd00::1/64 已配置在 $dev 上"
    fi
    echo "请配置您的代理工具（如 sing-box、mihomo）使用 $dev"
    ip addr show "$dev"
}

# 选项 2：设置网卡混杂模式并永久生效
setup_promisc() {
    local dev
    local interfaces

    # 获取可用网卡
    mapfile -t interfaces < <(get_available_interfaces)
    if [ ${#interfaces[@]} -eq 0 ]; then
        echo "错误：未找到网络接口" >&2
        return 1
    fi

    # 显示网卡列表供用户选择
    echo "可用网络接口："
    for i in "${!interfaces[@]}"; do
        echo "$((i+1)). ${interfaces[i]}"
    done
    read -p "选择接口编号 (1-${#interfaces[@]}): " choice
    if [[ ! $choice =~ ^[0-9]+$ ]]; then
        echo "错误：无效的选择" >&2
        return 1
    fi
    if [ "$choice" -lt 1 ] || [ "$choice" -gt ${#interfaces[@]} ]; then
        echo "错误：无效的选择" >&2
        return 1
    fi
    dev="${interfaces[$((choice-1))]}"

    echo "设置 $dev 为混杂模式..."
    ip link set "$dev" promisc on || {
        echo "错误：无法将 $dev 设置为混杂模式" >&2
        return 1
    }

    # 配置持久化
    echo "配置持久化混杂模式..."
    if command -v systemctl >/dev/null 2>&1; then
        echo "使用 systemd 服务进行持久化..."
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
        systemctl start "promisc-$dev.service" || {
            echo "警告：无法启动 promisc-$dev.service" >&2
        }
    elif [ -f /etc/rc.local ]; then
        echo "使用 /etc/rc.local 进行持久化..."
        sed -i '/exit 0/d' /etc/rc.local
        echo "ip link set $dev promisc on" >> /etc/rc.local
        echo "exit 0" >> /etc/rc.local
        chmod +x /etc/rc.local
    else
        echo "警告：未找到支持的持久化方法"
        read -p "是否继续而不进行持久化配置？[y/N]: " confirm
        if [[ ! $confirm =~ ^[Yy]$ ]]; then
            return 1
        fi
    fi

    echo "接口 $dev 已成功设置为混杂模式"
    ip link show "$dev"
}

# 选项 3：查看接口状态
show_status() {
    echo "列出所有网络接口："
    ip link show
    echo -e "\nTUN 接口详细信息："
    local found=0
    for dev in $(ip link show | awk -F': ' '/tun[0-9]+/ {print $2}'); do
        ip addr show "$dev"
        found=1
    done
    if [ "$found" -eq 0 ]; then
        echo "未找到 TUN 接口"
    fi
}

# 主菜单
main_menu() {
    while true; do
        echo -e "\n=== 透明代理 TUN 配置主菜单 ==="
        echo "1. 设置持久化的透明代理 TUN 接口"
        echo "2. 为接口设置混杂模式"
        echo "3. 查看网络接口状态"
        echo "4. 修复 TUN 模块问题"
        echo "5. 退出"
        read -p "选择一个选项 [1-5]: " choice

        case $choice in
            1)
                setup_tun
                echo -e "\n操作完成，返回主菜单..."
                ;;
            2)
                setup_promisc
                echo -e "\n操作完成，返回主菜单..."
                ;;
            3)
                show_status
                echo -e "\n操作完成，返回主菜单..."
                ;;
            4)
                fix_tun
                echo -e "\n操作完成，返回主菜单..."
                ;;
            5)
                echo "退出..."
                exit 0
                ;;
            *)
                echo "无效选项，请选择 1-5"
                ;;
        esac
    done
}

# 主程序
check_root
check_dependencies
main_menu
