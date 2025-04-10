#!/bin/sh

# OpenWRT 多网口高级配置脚本
# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# 检查 root 权限
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}错误: 此脚本必须以 root 权限运行！${NC}"
        exit 1
    fi
}

# 检查 OpenWRT 系统
check_openwrt() {
    if ! grep -q "OpenWrt" /etc/os-release 2>/dev/null; then
        echo -e "${RED}错误: 此脚本仅适用于 OpenWRT 系统！${NC}"
        exit 1
    fi
}

# 获取系统信息
get_system_info() {
    ARCH=$(uname -m)
    MODEL=$(cat /proc/cpuinfo | grep -i 'model name' | head -1 | cut -d':' -f2 | sed 's/^[ \t]*//')
    echo -e "${GREEN}系统架构: ${ARCH}${NC}"
    echo -e "${GREEN}设备型号: ${MODEL}${NC}"
}

# 获取网络接口
get_interfaces() {
    # 获取所有物理接口
    PHYSICAL_IFACES=$(ls -1 /sys/class/net/ | grep -E 'eth[0-9]+|enp[0-9]+s[0-9]+|wan[0-9]+|lan[0-9]+' | sort | uniq)
    
    # 获取当前配置的接口
    CONFIGURED_IFACES=$(uci show network | grep -oE 'interface.*' | cut -d'.' -f2 | sort -u | grep -vE 'loopback|wan6')
    
    # 获取 VLAN 信息
    VLAN_INFO=$(swconfig dev switch0 show 2>/dev/null || echo "")
}

# 显示当前配置
show_current_config() {
    clear
    echo -e "${YELLOW}=== 当前网络配置 ===${NC}"
    echo -e "${GREEN}接口配置:${NC}"
    uci show network | grep -E "interface|ifname|proto|ipaddr|type" | sed 's/network\.//'
    
    echo -e "\n${GREEN}物理接口状态:${NC}"
    for iface in $PHYSICAL_IFACES; do
        echo -n "$iface: "
        ip link show $iface | grep -Eo 'state [A-Z]+' | cut -d' ' -f2
    done
    
    if [ -n "$VLAN_INFO" ]; then
        echo -e "\n${GREEN}VLAN 配置:${NC}"
        echo "$VLAN_INFO"
    fi
    
    echo -e "\n${GREEN}防火墙区域:${NC}"
    uci show firewall | grep -E "name|network|input|output|forward"
}

# 选择接口 (支持多选)
select_interface() {
    local prompt=$1
    local ifaces=$2
    local multi=$3
    
    echo -e "\n${GREEN}${prompt}${NC}"
    echo "可用接口:"
    
    local i=1
    for iface in $ifaces; do
        echo "$i) $iface"
        i=$((i+1))
    done
    
    if [ "$multi" = "multi" ]; then
        echo "可多选 (用空格分隔数字，如 1 2 3):"
        read -p "请输入选择: " choices
        
        SELECTED_IFACE=""
        for choice in $choices; do
            local idx=1
            for iface in $ifaces; do
                if [ "$choice" = "$idx" ]; then
                    SELECTED_IFACE="$SELECTED_IFACE $iface"
                    break
                fi
                idx=$((idx+1))
            done
        done
        SELECTED_IFACE=$(echo "$SELECTED_IFACE" | xargs) # 去除多余空格
    else
        read -p "请输入选择 (1-$((i-1))): " choice
        local idx=1
        for iface in $ifaces; do
            if [ "$choice" = "$idx" ]; then
                SELECTED_IFACE=$iface
                break
            fi
            idx=$((idx+1))
        done
    fi
    
    if [ -z "$SELECTED_IFACE" ]; then
        echo -e "${RED}无效选择！${NC}"
        return 1
    fi
    
    echo -e "已选择: ${YELLOW}$SELECTED_IFACE${NC}"
    return 0
}

# 配置 WAN 接口
configure_wan() {
    echo -e "\n${YELLOW}=== 配置 WAN 接口 ===${NC}"
    
    if ! select_interface "选择作为 WAN 的物理接口" "$PHYSICAL_IFACES"; then
        return
    fi
    WAN_IFACE=$SELECTED_IFACE
    
    echo -e "\n${GREEN}选择 WAN 类型:${NC}"
    echo "1) pppoe"
    echo "2) dhcp"
    echo "3) static"
    echo "4) none"
    read -p "请输入选择 (1-4): " choice
    
    case $choice in
        1) WAN_TYPE="pppoe" ;;
        2) WAN_TYPE="dhcp" ;;
        3) WAN_TYPE="static" ;;
        4) WAN_TYPE="none" ;;
        *) 
            echo -e "${RED}无效选择！${NC}"
            return
            ;;
    esac
    
    case $WAN_TYPE in
        "pppoe")
            read -p "输入 PPPoE 用户名: " PPPOE_USER
            read -s -p "输入 PPPoE 密码: " PPPOE_PASS
            echo ""
            ;;
        "static")
            read -p "输入静态 IP 地址 (如 192.168.1.100): " STATIC_IP
            read -p "输入子网掩码 (如 255.255.255.0): " STATIC_NETMASK
            read -p "输入网关地址: " STATIC_GATEWAY
            read -p "输入 DNS 服务器: " STATIC_DNS
            ;;
        "none")
            echo -e "${YELLOW}跳过 WAN 接口配置${NC}"
            return
            ;;
    esac
    
    # 配置 WAN
    uci set network.wan=interface
    uci set network.wan.ifname="$WAN_IFACE"
    uci set network.wan.proto="$WAN_TYPE"
    
    case $WAN_TYPE in
        "pppoe")
            uci set network.wan.username="$PPPOE_USER"
            uci set network.wan.password="$PPPOE_PASS"
            ;;
        "static")
            uci set network.wan.ipaddr="$STATIC_IP"
            uci set network.wan.netmask="$STATIC_NETMASK"
            uci set network.wan.gateway="$STATIC_GATEWAY"
            uci set network.wan.dns="$STATIC_DNS"
            ;;
    esac
    
    # 配置防火墙
    uci set firewall.@zone[1].network='wan'
    uci commit firewall
    
    echo -e "${GREEN}WAN 接口配置完成！${NC}"
}

# 配置 LAN 接口
configure_lan() {
    echo -e "\n${YELLOW}=== 配置 LAN 接口 ===${NC}"
    
    if ! select_interface "选择作为 LAN 的物理接口 (输入多个数字用空格分隔)" "$PHYSICAL_IFACES" "multi"; then
        return
    fi
    LAN_IFACES=$SELECTED_IFACE
    
    read -p "输入 LAN IP 地址 (如 192.168.1.1): " LAN_IP
    
    # 配置 LAN
    uci set network.lan=interface
    uci set network.lan.proto='static'
    uci set network.lan.ipaddr="$LAN_IP"
    uci set network.lan.netmask='255.255.255.0'
    
    if [ $(echo "$LAN_IFACES" | wc -w) -gt 1 ]; then
        uci set network.lan.type='bridge'
        for iface in $LAN_IFACES; do
            uci add_list network.lan.ifname="$iface"
        done
    else
        uci set network.lan.ifname="$LAN_IFACES"
    fi
    
    # 配置 DHCP
    configure_dhcp "$LAN_IP"
    
    echo -e "${GREEN}LAN 接口配置完成！${NC}"
}

# 配置 DHCP
configure_dhcp() {
    local lan_ip=$1
    local start_range=$(echo "$lan_ip" | cut -d'.' -f1-3).100
    local end_range=$(echo "$lan_ip" | cut -d'.' -f1-3).200
    
    echo -e "\n${YELLOW}=== 配置 DHCP 服务器 ===${NC}"
    read -p "启用 DHCP 服务器? (y/n) [y]: " ENABLE_DHCP
    ENABLE_DHCP=${ENABLE_DHCP:-y}
    
    if [ "$ENABLE_DHCP" = "y" ] || [ "$ENABLE_DHCP" = "Y" ]; then
        uci set dhcp.lan=dhcp
        uci set dhcp.lan.interface='lan'
        uci set dhcp.lan.start='100'
        uci set dhcp.lan.limit='100'
        uci set dhcp.lan.leasetime='12h'
        uci set dhcp.lan.dhcpv4='server'
        uci set dhcp.lan.dhcpv6='server'
        
        read -p "输入 DHCP 起始地址 [${start_range}]: " DHCP_START
        DHCP_START=${DHCP_START:-$start_range}
        uci set dhcp.lan.start="$DHCP_START"
        
        read -p "输入 DHCP 结束地址 [${end_range}]: " DHCP_END
        DHCP_END=${DHCP_END:-$end_range}
        uci set dhcp.lan.limit="$DHCP_END"
        
        echo -e "${GREEN}DHCP 服务器配置完成！${NC}"
    else
        uci delete dhcp.lan >/dev/null 2>&1
        echo -e "${YELLOW}已禁用 DHCP 服务器${NC}"
    fi
}

# 配置 VLAN
configure_vlan() {
    echo -e "\n${YELLOW}=== 配置 VLAN ===${NC}"
    
    if [ -z "$VLAN_INFO" ]; then
        echo -e "${RED}错误: 未检测到支持 VLAN 的交换机设备！${NC}"
        return
    fi
    
    echo "当前 VLAN 配置:"
    echo "$VLAN_INFO"
    
    read -p "创建新的 VLAN? (y/n) " CREATE_VLAN
    if [ "$CREATE_VLAN" != "y" ] && [ "$CREATE_VLAN" != "Y" ]; then
        return
    fi
    
    read -p "输入 VLAN ID (2-4094): " VLAN_ID
    if ! [[ "$VLAN_ID" =~ ^[0-9]+$ ]] || [ "$VLAN_ID" -lt 2 ] || [ "$VLAN_ID" -gt 4094 ]; then
        echo -e "${RED}错误: 无效的 VLAN ID${NC}"
        return
    fi
    
    if ! select_interface "选择属于此 VLAN 的物理接口 (输入多个数字用空格分隔)" "$PHYSICAL_IFACES" "multi"; then
        return
    fi
    VLAN_IFACES=$SELECTED_IFACE
    
    # 配置 VLAN 接口
    uci set network.vlan${VLAN_ID}=interface
    uci set network.vlan${VLAN_ID}.proto='static'
    uci set network.vlan${VLAN_ID}.type='bridge'
    for iface in $VLAN_IFACES; do
        uci add_list network.vlan${VLAN_ID}.ifname="$iface"
    done
    
    # 配置交换机 VLAN
    uci set network.@switch_vlan[0]=switch_vlan
    uci set network.@switch_vlan[0].device='switch0'
    uci set network.@switch_vlan[0].vlan="$VLAN_ID"
    uci set network.@switch_vlan[0].ports="$VLAN_IFACES"
    
    echo -e "${GREEN}VLAN ${VLAN_ID} 配置完成！${NC}"
}

# 备份配置
backup_config() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    mkdir -p /etc/backups
    cp /etc/config/network /etc/backups/network.$timestamp
    cp /etc/config/firewall /etc/backups/firewall.$timestamp
    cp /etc/config/dhcp /etc/backups/dhcp.$timestamp
    echo -e "${GREEN}配置已备份到 /etc/backups/${NC}"
}

# 恢复配置
restore_config() {
    echo -e "\n${YELLOW}=== 恢复配置 ===${NC}"
    local backups=$(ls /etc/backups/network.* 2>/dev/null)
    
    if [ -z "$backups" ]; then
        echo -e "${RED}找不到备份文件！${NC}"
        return
    fi
    
    echo "可用备份:"
    local i=1
    for backup in $backups; do
        echo "$i) $backup"
        i=$((i+1))
    done
    
    read -p "请输入选择 (1-$((i-1))): " choice
    local idx=1
    for backup in $backups; do
        if [ "$choice" = "$idx" ]; then
            local timestamp=$(echo "$backup" | cut -d'.' -f2)
            cp "/etc/backups/network.$timestamp" /etc/config/network
            cp "/etc/backups/firewall.$timestamp" /etc/config/firewall 2>/dev/null
            cp "/etc/backups/dhcp.$timestamp" /etc/config/dhcp 2>/dev/null
            
            echo -e "${GREEN}配置已从备份恢复 (${timestamp})${NC}"
            read -p "立即应用配置? (y/n) " APPLY_NOW
            if [ "$APPLY_NOW" = "y" ] || [ "$APPLY_NOW" = "Y" ]; then
                /etc/init.d/network restart
                /etc/init.d/firewall restart >/dev/null 2>&1
                /etc/init.d/dnsmasq restart >/dev/null 2>&1
                echo -e "${GREEN}网络服务已重启！${NC}"
            fi
            return
        fi
        idx=$((idx+1))
    done
    
    echo -e "${RED}无效选择！${NC}"
}

# 应用配置
apply_configuration() {
    echo -e "\n${YELLOW}=== 应用配置 ===${NC}"
    uci commit network
    uci commit firewall
    uci commit dhcp
    
    echo -e "${GREEN}配置已保存！${NC}"
    
    read -p "现在重启网络服务使更改生效? (y/n) " RESTART_NETWORK
    if [ "$RESTART_NETWORK" = "y" ] || [ "$RESTART_NETWORK" = "Y" ]; then
        /etc/init.d/network restart
        /etc/init.d/firewall restart >/dev/null 2>&1
        /etc/init.d/dnsmasq restart >/dev/null 2>&1
        echo -e "${GREEN}网络服务已重启！${NC}"
    fi
}

# 主菜单
main_menu() {
    while true; do
        clear
        echo -e "${YELLOW}========================================${NC}"
        echo -e "${YELLOW} OpenWRT 多网口高级配置工具 ${NC}"
        echo -e "${YELLOW}========================================${NC}"
        echo -e "${GREEN} 1. 显示当前网络配置${NC}"
        echo -e "${GREEN} 2. 配置 WAN 接口${NC}"
        echo -e "${GREEN} 3. 配置 LAN 接口${NC}"
        echo -e "${GREEN} 4. 配置 VLAN${NC}"
        echo -e "${GREEN} 5. 备份当前配置${NC}"
        echo -e "${GREEN} 6. 恢复备份配置${NC}"
        echo -e "${GREEN} 7. 应用所有配置${NC}"
        echo -e "${GREEN} 8. 退出${NC}"
        echo -e "${YELLOW}========================================${NC}"
        read -p "请选择操作 [1-8]: " OPTION

        case $OPTION in
            1) show_current_config ;;
            2) configure_wan ;;
            3) configure_lan ;;
            4) configure_vlan ;;
            5) backup_config ;;
            6) restore_config ;;
            7) apply_configuration ;;
            8) exit 0 ;;
            *) echo -e "${RED}无效选项，请重新输入！${NC}" ;;
        esac

        echo ""
        read -p "按回车键返回主菜单..."
    done
}

# 初始化
initialize() {
    check_root
    check_openwrt
    get_system_info
    get_interfaces
}

# 主程序
initialize
main_menu
