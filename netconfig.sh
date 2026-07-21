#!/bin/sh

VERSION="4.0"
CONFIG_DIR="/etc/config"
BACKUP_DIR="/etc/backups"
LOG_FILE="/tmp/netconfig.log"
SWITCH_DEVICE=""
SWPORT_MAP=""
PHYSICAL_IFACES=""
VLAN_CAPABLE=0
SELECTED_RESULT=""

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m'

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

init_check() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}此脚本必须以root权限运行${NC}"
        exit 1
    fi
    if ! grep -qi "openwrt\|lede" /etc/os-release 2>/dev/null; then
        if [ ! -f /etc/openwrt_release ] && [ ! -f /etc/openwrt_version ]; then
            echo -e "${RED}此脚本仅适用于OpenWRT系统${NC}"
            exit 1
        fi
    fi
    mkdir -p "$BACKUP_DIR"
    touch "$LOG_FILE"
    log "===== 脚本初始化 ====="
    if [ -n "$SSH_CONNECTION" ]; then
        echo -e "${YELLOW}警告: 当前通过SSH连接,配置网络可能导致连接中断${NC}"
        printf "按回车键继续或Ctrl+C退出..."
        read dummy
    fi
}

get_system_info() {
    ARCH=$(uname -m)
    MODEL=""
    if [ -f /tmp/sysinfo/model ]; then
        MODEL=$(cat /tmp/sysinfo/model)
    elif [ -f /proc/device-tree/model ]; then
        MODEL=$(cat /proc/device-tree/model 2>/dev/null)
    else
        MODEL=$(grep -i 'machine\|model name\|system type' /proc/cpuinfo 2>/dev/null | head -1 | cut -d':' -f2 | sed 's/^[ \t]*//')
    fi
    SWITCH_DEVICE=""
    if command -v swconfig >/dev/null 2>&1; then
        SWITCH_DEVICE=$(swconfig list 2>/dev/null | awk '{print $2}' | head -n1)
    fi
    echo -e "${BLUE}系统架构: ${ARCH}${NC}"
    echo -e "${BLUE}设备型号: ${MODEL}${NC}"
    if [ -n "$SWITCH_DEVICE" ]; then
        echo -e "${BLUE}交换机: ${SWITCH_DEVICE}${NC}"
    fi
    log "系统信息收集完成"
}

init_switch_port_map() {
    SWPORT_MAP=""
    if [ -n "$SWITCH_DEVICE" ]; then
        for port in $(swconfig dev "$SWITCH_DEVICE" show 2>/dev/null | grep -oE 'Port [0-9]+:' | cut -d' ' -f2 | tr -d :); do
            iface=$(swconfig dev "$SWITCH_DEVICE" port "$port" show 2>/dev/null | grep -Eo 'link: port:[^ ]+' | cut -d':' -f3)
            if [ -n "$iface" ]; then
                SWPORT_MAP="$SWPORT_MAP ${iface}:${port}"
            fi
        done
        log "交换机端口映射: $SWPORT_MAP"
    fi
}

detect_interfaces() {
    PHYSICAL_IFACES=""
    for path in /sys/class/net/*; do
        iface=$(basename "$path")
        case "$iface" in
            lo|br-*|br[0-9]*|veth*|docker*|vir*|wlan*|ra*|rai*|rax*|apcli*|apclii*) continue ;;
        esac
        if [ -d "/sys/class/net/$iface/device" ] || echo "$iface" | grep -qE '^eth[0-9]'; then
            PHYSICAL_IFACES="$PHYSICAL_IFACES $iface"
        fi
    done
    PHYSICAL_IFACES=$(echo "$PHYSICAL_IFACES" | xargs)
    if [ -z "$PHYSICAL_IFACES" ]; then
        echo -e "${RED}未检测到物理网络接口${NC}"
        exit 1
    fi
    VLAN_CAPABLE=0
    if [ -n "$SWITCH_DEVICE" ]; then
        VLAN_CAPABLE=1
    fi
    log "检测到物理接口: $PHYSICAL_IFACES"
}

validate_ip() {
    if ! echo "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        return 1
    fi
    local IFS='.'
    set -- $1
    for octet in "$1" "$2" "$3" "$4"; do
        if [ "$octet" -gt 255 ] 2>/dev/null; then
            return 1
        fi
    done
    return 0
}

validate_netmask() {
    if ! validate_ip "$1"; then
        return 1
    fi
    case "$1" in
        255.255.255.0|255.255.0.0|255.0.0.0|255.255.255.128|255.255.255.192|255.255.255.224|255.255.255.240|255.255.255.248|255.255.255.252|255.255.128.0|255.255.192.0|255.255.224.0|255.255.240.0|255.255.248.0|255.255.252.0|255.255.254.0)
            return 0 ;;
        *)
            return 1 ;;
    esac
}

show_current_config() {
    clear
    echo -e "${YELLOW}=== 当前网络配置 ===${NC}"
    echo -e "\n${GREEN}接口配置:${NC}"
    uci show network 2>/dev/null | grep -E "interface|ifname|device|proto|ipaddr|type|ports|gateway|dns" | sed 's/network\./  /'
    echo -e "\n${GREEN}物理接口状态:${NC}"
    for iface in $PHYSICAL_IFACES; do
        state=$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || echo "unknown")
        speed=""
        if command -v ethtool >/dev/null 2>&1; then
            speed=$(ethtool "$iface" 2>/dev/null | grep -i "speed:" | awk '{print $2}')
        fi
        if [ -z "$speed" ]; then
            speed=$(cat "/sys/class/net/$iface/speed" 2>/dev/null)
            if [ -n "$speed" ] && [ "$speed" != "-1" ]; then
                speed="${speed}Mb/s"
            else
                speed="N/A"
            fi
        fi
        printf "  %-10s state=%-8s speed=%s\n" "$iface" "$state" "$speed"
    done
    if [ $VLAN_CAPABLE -eq 1 ]; then
        echo -e "\n${GREEN}VLAN配置:${NC}"
        swconfig dev "$SWITCH_DEVICE" show 2>/dev/null | grep -E 'vid|ports' | sed 's/^/  /'
    fi
    echo -e "\n${GREEN}防火墙区域:${NC}"
    uci show firewall 2>/dev/null | grep -E "\.name=|\.network=|\.input=|\.forward=" | sed 's/firewall\./  /'
    echo -e "\n${GREEN}桥接信息:${NC}"
    if command -v brctl >/dev/null 2>&1; then
        brctl show 2>/dev/null | sed 's/^/  /'
    fi
    echo -e "\n${GREEN}DHCP状态:${NC}"
    local dhcp_ignore=$(uci -q get dhcp.lan.ignore)
    if [ "$dhcp_ignore" = "1" ]; then
        echo "  LAN DHCP: 已禁用"
    else
        echo "  LAN DHCP: 已启用"
    fi
    echo -e "\n${GREEN}Flow Offloading:${NC}"
    local fo=$(uci -q get firewall.@defaults[0].flow_offloading)
    local fohw=$(uci -q get firewall.@defaults[0].flow_offloading_hw)
    echo "  软件分载: ${fo:-未设置}"
    echo "  硬件分载: ${fohw:-未设置}"
    log "显示当前配置"
}

select_interfaces() {
    local prompt=$1
    local multi=$2
    local selected=""
    SELECTED_RESULT=""
    echo -e "\n${GREEN}${prompt}${NC}"
    echo "可用接口:"
    local i=1
    local iface_arr=""
    for iface in $PHYSICAL_IFACES; do
        state=$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || echo "unknown")
        echo "  $i) $iface ($state)"
        iface_arr="$iface_arr $iface"
        i=$((i + 1))
    done
    local max=$((i - 1))
    if [ "$max" -eq 0 ]; then
        echo -e "${RED}没有可用接口${NC}"
        return 1
    fi
    if [ "$multi" = "multi" ]; then
        echo "可多选(空格分隔):"
        printf "请输入: "
        read choices
        if [ -z "$choices" ]; then
            echo -e "${RED}未选择任何接口${NC}"
            return 1
        fi
        for choice in $choices; do
            if ! echo "$choice" | grep -qE '^[0-9]+$'; then
                echo -e "${RED}无效输入 '$choice'${NC}"
                return 1
            fi
            if [ "$choice" -lt 1 ] || [ "$choice" -gt "$max" ]; then
                echo -e "${RED}选择 $choice 超出范围${NC}"
                return 1
            fi
            local idx=1
            for iface in $iface_arr; do
                if [ "$choice" -eq "$idx" ]; then
                    selected="$selected $iface"
                    break
                fi
                idx=$((idx + 1))
            done
        done
    else
        printf "请输入选择 (1-%d): " "$max"
        read choice
        if ! echo "$choice" | grep -qE '^[0-9]+$'; then
            echo -e "${RED}无效输入${NC}"
            return 1
        fi
        if [ "$choice" -lt 1 ] || [ "$choice" -gt "$max" ]; then
            echo -e "${RED}超出范围${NC}"
            return 1
        fi
        local idx=1
        for iface in $iface_arr; do
            if [ "$choice" -eq "$idx" ]; then
                selected="$iface"
                break
            fi
            idx=$((idx + 1))
        done
    fi
    if [ -z "$selected" ]; then
        echo -e "${RED}选择无效${NC}"
        return 1
    fi
    selected=$(echo "$selected" | xargs)
    echo -e "已选择: ${YELLOW}$selected${NC}"
    log "接口选择: $selected"
    SELECTED_RESULT="$selected"
    return 0
}

port_iface_to_switch() {
    local iface=$1
    echo "$SWPORT_MAP" | tr ' ' '\n' | grep "^${iface}:" | cut -d':' -f2 | head -1
}

configure_wan() {
    echo -e "\n${YELLOW}=== 配置WAN接口 ===${NC}"
    if ! select_interfaces "请选择WAN接口" "single"; then
        return 1
    fi
    local wan_iface=$SELECTED_RESULT
    echo -e "\n${GREEN}选择WAN类型:${NC}"
    echo "  1) PPPoE"
    echo "  2) DHCP"
    echo "  3) 静态IP"
    echo "  4) 取消"
    local wan_type=""
    while true; do
        printf "请选择 [1-4]: "
        read choice
        case $choice in
            1) wan_type="pppoe"; break ;;
            2) wan_type="dhcp"; break ;;
            3) wan_type="static"; break ;;
            4) return ;;
            *) echo -e "${RED}无效${NC}" ;;
        esac
    done
    case $wan_type in
        "pppoe")
            printf "PPPoE用户名: "
            read pppoe_user
            if [ -z "$pppoe_user" ]; then
                echo -e "${RED}用户名不能为空${NC}"
                return 1
            fi
            printf "PPPoE密码: "
            stty -echo 2>/dev/null
            read pppoe_pass
            stty echo 2>/dev/null
            echo
            if [ -z "$pppoe_pass" ]; then
                echo -e "${RED}密码不能为空${NC}"
                return 1
            fi
            uci set network.wan=interface
            uci set network.wan.device="$wan_iface"
            uci set network.wan.proto="pppoe"
            uci set network.wan.username="$pppoe_user"
            uci set network.wan.password="$pppoe_pass"
            uci set network.wan.ipv6="auto"
            ;;
        "dhcp")
            uci set network.wan=interface
            uci set network.wan.device="$wan_iface"
            uci set network.wan.proto="dhcp"
            uci set network.wan.ipv6="auto"
            ;;
        "static")
            local static_ip static_mask static_gw static_dns
            while true; do
                printf "静态IP (如192.168.1.100): "
                read static_ip
                validate_ip "$static_ip" && break
                echo -e "${RED}无效IP${NC}"
            done
            while true; do
                printf "子网掩码 (如255.255.255.0): "
                read static_mask
                validate_netmask "$static_mask" && break
                echo -e "${RED}无效掩码${NC}"
            done
            while true; do
                printf "网关 (留空跳过): "
                read static_gw
                if [ -z "$static_gw" ]; then break; fi
                validate_ip "$static_gw" && break
                echo -e "${RED}无效网关${NC}"
            done
            while true; do
                printf "DNS (留空跳过): "
                read static_dns
                if [ -z "$static_dns" ]; then break; fi
                validate_ip "$static_dns" && break
                echo -e "${RED}无效DNS${NC}"
            done
            uci set network.wan=interface
            uci set network.wan.device="$wan_iface"
            uci set network.wan.proto="static"
            uci set network.wan.ipaddr="$static_ip"
            uci set network.wan.netmask="$static_mask"
            [ -n "$static_gw" ] && uci set network.wan.gateway="$static_gw"
            if [ -n "$static_dns" ]; then
                uci -q delete network.wan.dns
                uci add_list network.wan.dns="$static_dns"
            fi
            ;;
    esac
    local wan_zone_exists=0
    local zone_idx=0
    while uci -q get "firewall.@zone[$zone_idx]" >/dev/null 2>&1; do
        local zname=$(uci -q get "firewall.@zone[$zone_idx].name")
        if [ "$zname" = "wan" ]; then
            wan_zone_exists=1
            uci -q delete "firewall.@zone[$zone_idx].network"
            uci add_list "firewall.@zone[$zone_idx].network"='wan'
            break
        fi
        zone_idx=$((zone_idx + 1))
    done
    if [ $wan_zone_exists -eq 0 ]; then
        uci add firewall zone
        uci set "firewall.@zone[-1].name"='wan'
        uci set "firewall.@zone[-1].input"='REJECT'
        uci set "firewall.@zone[-1].output"='ACCEPT'
        uci set "firewall.@zone[-1].forward"='REJECT'
        uci set "firewall.@zone[-1].masq"='1'
        uci set "firewall.@zone[-1].mtu_fix"='1'
        uci add_list "firewall.@zone[-1].network"='wan'
    fi
    echo -e "${GREEN}WAN配置完成${NC}"
    log "WAN: $wan_iface type=$wan_type"
    return 0
}

configure_lan() {
    echo -e "\n${YELLOW}=== 配置LAN接口 ===${NC}"
    if ! select_interfaces "请选择LAN接口(可多选)" "multi"; then
        return 1
    fi
    local lan_ifaces=$SELECTED_RESULT
    local lan_ip
    while true; do
        printf "LAN IP (如192.168.1.1): "
        read lan_ip
        validate_ip "$lan_ip" && break
        echo -e "${RED}无效IP${NC}"
    done
    uci set network.lan=interface
    uci set network.lan.proto='static'
    uci set network.lan.ipaddr="$lan_ip"
    uci set network.lan.netmask='255.255.255.0'
    local iface_count=$(echo "$lan_ifaces" | wc -w)
    if [ "$iface_count" -gt 1 ]; then
        local br_section=$(uci show network 2>/dev/null | grep "\.name='br-lan'" | head -1 | cut -d'.' -f2)
        if [ -z "$br_section" ]; then
            br_section=$(uci add network device)
        fi
        uci set "network.$br_section.name"='br-lan'
        uci set "network.$br_section.type"='bridge'
        uci -q delete "network.$br_section.ports"
        for p in $lan_ifaces; do
            uci add_list "network.$br_section.ports"="$p"
        done
        uci set network.lan.device='br-lan'
    else
        uci set network.lan.device="$lan_ifaces"
    fi
    configure_dhcp "$lan_ip"
    echo -e "${GREEN}LAN配置完成${NC}"
    log "LAN: $lan_ifaces IP=$lan_ip"
    return 0
}

configure_dhcp() {
    local lan_ip=$1
    local base=$(echo "$lan_ip" | cut -d'.' -f1-3)
    echo -e "\n${YELLOW}=== DHCP配置 ===${NC}"
    printf "启用DHCP? [Y/n]: "
    read enable_dhcp
    enable_dhcp=${enable_dhcp:-y}
    case "$enable_dhcp" in
        y|Y)
            local input_start input_end input_lease
            while true; do
                printf "起始地址 [%s.100]: " "$base"
                read input_start
                input_start=${input_start:-${base}.100}
                validate_ip "$input_start" && break
                echo -e "${RED}无效IP${NC}"
            done
            while true; do
                printf "结束地址 [%s.200]: " "$base"
                read input_end
                input_end=${input_end:-${base}.200}
                validate_ip "$input_end" && break
                echo -e "${RED}无效IP${NC}"
            done
            printf "租约时间 [12h]: "
            read input_lease
            input_lease=${input_lease:-12h}
            local s=$(echo "$input_start" | cut -d'.' -f4)
            local e=$(echo "$input_end" | cut -d'.' -f4)
            local limit=$((e - s + 1))
            if [ "$limit" -le 0 ]; then
                echo -e "${RED}结束地址必须大于起始地址${NC}"
                return 1
            fi
            uci set dhcp.lan=dhcp
            uci set dhcp.lan.interface='lan'
            uci set dhcp.lan.start="$s"
            uci set dhcp.lan.limit="$limit"
            uci set dhcp.lan.leasetime="$input_lease"
            uci -q delete dhcp.lan.ignore
            echo -e "${GREEN}DHCP已启用${NC}"
            ;;
        *)
            uci set dhcp.lan=dhcp
            uci set dhcp.lan.interface='lan'
            uci set dhcp.lan.ignore='1'
            echo -e "${YELLOW}DHCP已禁用${NC}"
            ;;
    esac
}

configure_vlan() {
    if [ $VLAN_CAPABLE -eq 0 ]; then
        echo -e "${RED}设备不支持VLAN${NC}"
        return 1
    fi
    echo -e "\n${YELLOW}=== VLAN配置 ===${NC}"
    echo "当前VLAN:"
    swconfig dev "$SWITCH_DEVICE" show 2>/dev/null | grep -E 'vid|ports' | sed 's/^/  /'
    echo -e "\n  1) 创建VLAN"
    echo "  2) 删除VLAN"
    echo "  3) 返回"
    while true; do
        printf "请选择 [1-3]: "
        read choice
        case $choice in
            1) create_vlan; break ;;
            2) delete_vlan; break ;;
            3) return ;;
            *) echo -e "${RED}无效${NC}" ;;
        esac
    done
}

create_vlan() {
    local vlan_id
    while true; do
        printf "VLAN ID (2-4094): "
        read vlan_id
        if ! echo "$vlan_id" | grep -qE '^[0-9]+$'; then
            echo -e "${RED}请输入数字${NC}"
            continue
        fi
        if [ "$vlan_id" -lt 2 ] || [ "$vlan_id" -gt 4094 ]; then
            echo -e "${RED}范围2-4094${NC}"
            continue
        fi
        if swconfig dev "$SWITCH_DEVICE" show 2>/dev/null | grep -q "vid: $vlan_id"; then
            echo -e "${RED}VLAN $vlan_id 已存在${NC}"
            continue
        fi
        break
    done
    if ! select_interfaces "选择VLAN成员接口(可多选)" "multi"; then
        return 1
    fi
    local vlan_members=$SELECTED_RESULT
    local tagged_ports=""
    for iface in $vlan_members; do
        port=$(port_iface_to_switch "$iface")
        if [ -z "$port" ]; then
            echo -e "${RED}无法找到 $iface 的交换机端口${NC}"
            return 1
        fi
        tagged_ports="$tagged_ports $port"
    done
    tagged_ports=$(echo "$tagged_ports" | xargs)
    uci set "network.vlan${vlan_id}_switch=switch_vlan"
    uci set "network.vlan${vlan_id}_switch.device=$SWITCH_DEVICE"
    uci set "network.vlan${vlan_id}_switch.vlan=$vlan_id"
    uci set "network.vlan${vlan_id}_switch.ports=$tagged_ports"
    uci set "network.vlan$vlan_id=interface"
    uci set "network.vlan$vlan_id.device=eth0.$vlan_id"
    uci set "network.vlan$vlan_id.proto=static"
    printf "为此VLAN配置IP? [y/N]: "
    read config_ip
    case "$config_ip" in
        y|Y)
            local vlan_ip
            while true; do
                printf "VLAN %d IP: " "$vlan_id"
                read vlan_ip
                validate_ip "$vlan_ip" && break
                echo -e "${RED}无效IP${NC}"
            done
            uci set "network.vlan$vlan_id.ipaddr=$vlan_ip"
            uci set "network.vlan$vlan_id.netmask=255.255.255.0"
            ;;
    esac
    echo -e "${GREEN}VLAN $vlan_id 已创建${NC}"
    log "创建VLAN $vlan_id ports=$tagged_ports"
}

delete_vlan() {
    local existing_vlans=$(swconfig dev "$SWITCH_DEVICE" show 2>/dev/null | grep 'vid:' | awk '{print $2}')
    if [ -z "$existing_vlans" ]; then
        echo -e "${YELLOW}无可删除的VLAN${NC}"
        return
    fi
    echo -e "\n${GREEN}现有VLAN:${NC}"
    for vlan in $existing_vlans; do
        echo "  VLAN $vlan"
    done
    local del_vlan
    while true; do
        printf "要删除的VLAN ID: "
        read del_vlan
        if echo "$existing_vlans" | grep -qw "$del_vlan"; then
            break
        fi
        echo -e "${RED}无效VLAN ID${NC}"
    done
    printf "确认删除VLAN %s? [y/N]: " "$del_vlan"
    read confirm
    case "$confirm" in
        y|Y) ;;
        *) echo -e "${YELLOW}已取消${NC}"; return ;;
    esac
    uci -q delete "network.vlan$del_vlan"
    uci -q delete "network.vlan${del_vlan}_switch"
    echo -e "${GREEN}VLAN $del_vlan 已删除${NC}"
    log "删除VLAN $del_vlan"
}

get_all_switch_ports() {
    if [ -z "$SWITCH_DEVICE" ]; then
        return
    fi
    swconfig dev "$SWITCH_DEVICE" show 2>/dev/null | grep -oE 'Port [0-9]+:' | cut -d' ' -f2 | tr -d : | sort -n | tr '\n' ' ' | xargs
}

get_cpu_port() {
    if [ -z "$SWITCH_DEVICE" ]; then
        return
    fi
    local all_vlans_ports=""
    local idx=0
    while uci -q get "network.@switch_vlan[$idx]" >/dev/null 2>&1; do
        local ports=$(uci -q get "network.@switch_vlan[$idx].ports")
        all_vlans_ports="$all_vlans_ports $ports"
        idx=$((idx + 1))
    done
    local max_port=""
    for p in $all_vlans_ports; do
        p_num=$(echo "$p" | tr -d 't')
        if [ -z "$max_port" ]; then
            max_port=$p_num
        elif [ "$p_num" -gt "$max_port" ] 2>/dev/null; then
            max_port=$p_num
        fi
    done
    local help_cpu=$(swconfig dev "$SWITCH_DEVICE" help 2>/dev/null | grep -oE 'cpu @ [0-9]+' | grep -oE '[0-9]+')
    if [ -n "$help_cpu" ]; then
        echo "$help_cpu"
    elif [ -n "$max_port" ]; then
        echo "$max_port"
    else
        echo "6"
    fi
}

configure_ap_mode() {
    echo -e "\n${YELLOW}=================================================${NC}"
    echo -e "  ${GREEN}AP/桥接模式一键配置${NC}"
    echo -e "${YELLOW}=================================================${NC}"
    echo -e ""
    echo -e "  ${BLUE}此功能将执行以下操作:${NC}"
    echo -e "  [1] 询问并设置管理IP/子网掩码/网关/DNS"
    echo -e "  [2] 所有网口并入LAN桥接(含原WAN口)"
    echo -e "  [3] 合并交换机VLAN(如适用)"
    echo -e "  [4] 删除WAN/WAN6接口"
    echo -e "  [5] 关闭DHCP服务器"
    echo -e "  [6] 清理IPv6多余配置"
    echo -e "  [7] 关闭Flow Offloading"
    echo -e "  [8] 停用防火墙"
    echo -e ""
    echo -e "  ${YELLOW}完成后设备将作为纯AP/交换机使用${NC}"
    echo -e "  ${YELLOW}由主路由负责DHCP/NAT/拨号${NC}"
    echo -e ""
    printf "继续? [y/N]: "
    read ap_confirm
    case "$ap_confirm" in
        y|Y) ;;
        *) echo -e "${YELLOW}已取消${NC}"; return ;;
    esac
    echo -e "\n${BLUE}[步骤1] 备份当前配置${NC}"
    backup_config
    echo -e "\n${BLUE}[步骤2] 设置网络参数${NC}"
    echo -e "${YELLOW}请根据主路由所在网段填写以下信息${NC}"
    echo -e "${YELLOW}(主路由通常为 192.168.x.1,本机IP不要与其冲突)${NC}"
    echo ""
    local current_ip=$(uci -q get network.lan.ipaddr)
    local current_mask=$(uci -q get network.lan.netmask)
    local current_gw=$(uci -q get network.lan.gateway)
    local current_dns=""
    current_dns=$(uci -q get network.lan.dns 2>/dev/null)
    local ap_ip ap_mask ap_gateway ap_dns
    while true; do
        printf "本机管理IP [%s]: " "${current_ip:-192.168.1.2}"
        read ap_ip
        ap_ip=${ap_ip:-${current_ip:-192.168.1.2}}
        if validate_ip "$ap_ip"; then
            break
        fi
        echo -e "${RED}无效IP,请重新输入${NC}"
    done
    while true; do
        printf "子网掩码 [%s]: " "${current_mask:-255.255.255.0}"
        read ap_mask
        ap_mask=${ap_mask:-${current_mask:-255.255.255.0}}
        if validate_netmask "$ap_mask"; then
            break
        fi
        echo -e "${RED}无效子网掩码,请重新输入${NC}"
    done
    local default_gw=""
    if [ -n "$current_gw" ]; then
        default_gw="$current_gw"
    else
        default_gw=$(echo "$ap_ip" | cut -d'.' -f1-3).1
    fi
    while true; do
        printf "主路由网关地址 [%s]: " "$default_gw"
        read ap_gateway
        ap_gateway=${ap_gateway:-$default_gw}
        if validate_ip "$ap_gateway"; then
            break
        fi
        echo -e "${RED}无效网关,请重新输入${NC}"
    done
    local default_dns="${current_dns:-$ap_gateway}"
    while true; do
        printf "DNS服务器 [%s]: " "$default_dns"
        read ap_dns
        ap_dns=${ap_dns:-$default_dns}
        if validate_ip "$ap_dns"; then
            break
        fi
        echo -e "${RED}无效DNS,请重新输入${NC}"
    done
    echo -e "\n${YELLOW}--- 确认配置信息 ---${NC}"
    echo -e "  管理IP:   ${GREEN}$ap_ip${NC}"
    echo -e "  子网掩码: ${GREEN}$ap_mask${NC}"
    echo -e "  网关:     ${GREEN}$ap_gateway${NC}"
    echo -e "  DNS:      ${GREEN}$ap_dns${NC}"
    echo -e "  桥接网口: ${GREEN}$PHYSICAL_IFACES${NC}"
    echo ""
    printf "以上信息是否正确? [Y/n]: "
    read info_confirm
    case "$info_confirm" in
        n|N) echo -e "${YELLOW}已取消,请重新运行${NC}"; return ;;
    esac
    echo -e "\n${BLUE}[步骤3] 配置网络接口${NC}"
    local current_mac=$(uci -q get network.lan.macaddr)
    if [ -z "$current_mac" ]; then
        local br_sec=$(uci show network 2>/dev/null | grep "\.name='br-lan'" | head -1 | cut -d'.' -f2)
        if [ -n "$br_sec" ]; then
            current_mac=$(uci -q get "network.$br_sec.macaddr")
        fi
    fi
    if [ -z "$current_mac" ]; then
        current_mac=$(cat /sys/class/net/br-lan/address 2>/dev/null)
    fi
    if [ -z "$current_mac" ]; then
        local first_eth=$(echo "$PHYSICAL_IFACES" | awk '{print $1}')
        current_mac=$(cat "/sys/class/net/$first_eth/address" 2>/dev/null)
    fi
    local br_section=$(uci show network 2>/dev/null | grep "\.name='br-lan'" | head -1 | cut -d'.' -f2)
    if [ -z "$br_section" ]; then
        br_section=$(uci add network device)
    fi
    uci set "network.$br_section.name"='br-lan'
    uci set "network.$br_section.type"='bridge'
    uci -q delete "network.$br_section.ports"
    for p in $PHYSICAL_IFACES; do
        uci add_list "network.$br_section.ports"="$p"
    done
    if [ -n "$current_mac" ]; then
        uci set "network.$br_section.macaddr"="$current_mac"
    fi
    echo -e "  ${GREEN}桥接设备br-lan已配置,成员: $PHYSICAL_IFACES${NC}"
    uci set network.lan=interface
    uci set network.lan.device='br-lan'
    uci set network.lan.proto='static'
    uci set network.lan.ipaddr="$ap_ip"
    uci set network.lan.netmask="$ap_mask"
    uci set network.lan.gateway="$ap_gateway"
    uci -q delete network.lan.dns
    uci add_list network.lan.dns="$ap_dns"
    uci -q delete network.lan.ip6assign
    uci -q delete network.lan.ip6ifaceid
    uci -q delete network.lan.ip6hint
    uci -q delete network.lan.ip6class
    uci set network.lan.delegate='0'
    if [ -n "$current_mac" ]; then
        uci set network.lan.macaddr="$current_mac"
    fi
    uci -q delete network.lan.ifname
    uci -q delete network.lan.type
    echo -e "  ${GREEN}LAN接口已配置: IP=$ap_ip GW=$ap_gateway DNS=$ap_dns${NC}"
    echo -e "\n${BLUE}[步骤4] 合并交换机端口${NC}"
    if [ -n "$SWITCH_DEVICE" ]; then
        local cpu_port=$(get_cpu_port)
        local all_ports=$(get_all_switch_ports)
        local user_ports=""
        for p in $all_ports; do
            if [ "$p" != "$cpu_port" ]; then
                user_ports="$user_ports $p"
            fi
        done
        user_ports=$(echo "$user_ports" | xargs)
        local merged_ports="$user_ports $cpu_port"
        merged_ports=$(echo "$merged_ports" | xargs)
        echo -e "  交换机: $SWITCH_DEVICE"
        echo -e "  CPU端口: $cpu_port"
        echo -e "  用户端口: $user_ports"
        echo -e "  合并后VLAN1端口: $merged_ports"
        local vlan_idx=0
        while uci -q get "network.@switch_vlan[$vlan_idx]" >/dev/null 2>&1; do
            vlan_idx=$((vlan_idx + 1))
        done
        local del_idx=$((vlan_idx - 1))
        while [ $del_idx -ge 0 ]; do
            uci -q delete "network.@switch_vlan[$del_idx]"
            del_idx=$((del_idx - 1))
        done
        uci add network switch_vlan
        uci set "network.@switch_vlan[-1].device=$SWITCH_DEVICE"
        uci set "network.@switch_vlan[-1].vlan=1"
        uci set "network.@switch_vlan[-1].ports=$merged_ports"
        echo -e "  ${GREEN}所有交换机端口已合并到VLAN1${NC}"
    else
        echo -e "  ${YELLOW}无swconfig交换机,跳过VLAN合并${NC}"
    fi
    echo -e "\n${BLUE}[步骤5] 删除WAN相关接口${NC}"
    uci -q delete network.wan
    uci -q delete network.wan6
    echo -e "  ${GREEN}已删除wan和wan6接口${NC}"
    echo -e "\n${BLUE}[步骤6] 关闭DHCP${NC}"
    uci set dhcp.lan=dhcp
    uci set dhcp.lan.interface='lan'
    uci set dhcp.lan.ignore='1'
    uci -q set dhcp.lan.dynamicdhcp='0'
    uci -q set dhcp.lan.ra='disabled'
    uci -q set dhcp.lan.dhcpv6='disabled'
    uci -q set dhcp.lan.ra_management='0'
    if uci -q get dhcp.odhcpd >/dev/null 2>&1; then
        uci set dhcp.odhcpd.maindhcp='0'
    fi
    echo -e "  ${GREEN}DHCP/DHCPv6/RA已关闭${NC}"
    echo -e "\n${BLUE}[步骤7] 关闭Flow Offloading${NC}"
    if uci -q get firewall.@defaults[0] >/dev/null 2>&1; then
        uci set firewall.@defaults[0].flow_offloading='0'
        uci set firewall.@defaults[0].flow_offloading_hw='0'
    fi
    echo -e "  ${GREEN}Flow Offloading已关闭${NC}"
    echo -e "\n${BLUE}[步骤8] 处理防火墙${NC}"
    printf "  停用防火墙? (AP模式建议停用) [Y/n]: "
    read fw_confirm
    fw_confirm=${fw_confirm:-y}
    local fw_action=""
    case "$fw_confirm" in
        y|Y)
            fw_action="disable"
            ;;
        *)
            fw_action="clean"
            ;;
    esac
    echo -e "\n${BLUE}[步骤9] 提交配置${NC}"
    uci commit network
    uci commit dhcp
    uci commit firewall
    echo -e "  ${GREEN}所有UCI配置已提交${NC}"
    if [ "$fw_action" = "disable" ]; then
        /etc/init.d/firewall stop 2>/dev/null
        /etc/init.d/firewall disable 2>/dev/null
        echo -e "  ${GREEN}防火墙已停用${NC}"
    else
        local zone_idx=0
        local zones_to_del=""
        while uci -q get "firewall.@zone[$zone_idx]" >/dev/null 2>&1; do
            local zname=$(uci -q get "firewall.@zone[$zone_idx].name")
            if [ "$zname" = "wan" ]; then
                zones_to_del="$zones_to_del $zone_idx"
            fi
            zone_idx=$((zone_idx + 1))
        done
        local sorted_del=$(echo "$zones_to_del" | tr ' ' '\n' | sort -rn | xargs)
        for didx in $sorted_del; do
            uci -q delete "firewall.@zone[$didx]"
        done
        local fwd_idx=0
        local fwd_to_del=""
        while uci -q get "firewall.@forwarding[$fwd_idx]" >/dev/null 2>&1; do
            local fsrc=$(uci -q get "firewall.@forwarding[$fwd_idx].src")
            local fdst=$(uci -q get "firewall.@forwarding[$fwd_idx].dest")
            if [ "$fdst" = "wan" ] || [ "$fsrc" = "wan" ]; then
                fwd_to_del="$fwd_to_del $fwd_idx"
            fi
            fwd_idx=$((fwd_idx + 1))
        done
        sorted_del=$(echo "$fwd_to_del" | tr ' ' '\n' | sort -rn | xargs)
        for didx in $sorted_del; do
            uci -q delete "firewall.@forwarding[$didx]"
        done
        uci commit firewall
        /etc/init.d/firewall restart 2>/dev/null
        echo -e "  ${YELLOW}防火墙保留,已清理wan相关配置${NC}"
    fi
    echo -e "\n${YELLOW}============= AP模式配置摘要 =============${NC}"
    echo -e "  管理IP:    ${GREEN}$ap_ip${NC}"
    echo -e "  子网掩码:  ${GREEN}$ap_mask${NC}"
    echo -e "  网关:      ${GREEN}$ap_gateway${NC}"
    echo -e "  DNS:       ${GREEN}$ap_dns${NC}"
    echo -e "  桥接网口:  ${GREEN}$PHYSICAL_IFACES${NC}"
    echo -e "  DHCP:      ${RED}已关闭${NC}"
    echo -e "  IPv6 RA:   ${RED}已关闭${NC}"
    echo -e "  Offload:   ${RED}已关闭${NC}"
    if [ "$fw_action" = "disable" ]; then
        echo -e "  防火墙:    ${RED}已停用${NC}"
    else
        echo -e "  防火墙:    ${YELLOW}运行中(已清理wan)${NC}"
    fi
    echo -e "${YELLOW}==========================================${NC}"
    echo ""
    echo -e "${YELLOW}重要提示:${NC}"
    echo -e "  1. 请用网线连接主路由LAN口到本机任意网口"
    echo -e "  2. 主路由DHCP地址池请避开 $ap_ip"
    echo -e "  3. 应用后请通过 $ap_ip 重新连接管理"
    echo -e "  4. 如出问题可用备份恢复"
    echo ""
    printf "立即重启网络使配置生效? [y/N]: "
    read restart_confirm
    case "$restart_confirm" in
        y|Y)
            echo -e "\n${BLUE}正在重启网络服务...${NC}"
            /etc/init.d/network restart
            sleep 3
            if /etc/init.d/dnsmasq enabled 2>/dev/null; then
                /etc/init.d/dnsmasq restart 2>/dev/null
            fi
            echo -e "${GREEN}网络已重启${NC}"
            echo ""
            echo -e "${BLUE}正在验证连通性...${NC}"
            sleep 2
            local gw_ok=0
            local dns_ok=0
            local inet_ok=0
            if ping -c 2 -W 3 "$ap_gateway" >/dev/null 2>&1; then
                gw_ok=1
                echo -e "  网关 $ap_gateway: ${GREEN}可达${NC}"
            else
                echo -e "  网关 $ap_gateway: ${RED}不可达${NC}"
            fi
            if ping -c 2 -W 3 223.5.5.5 >/dev/null 2>&1; then
                inet_ok=1
                echo -e "  外网 223.5.5.5:  ${GREEN}可达${NC}"
            else
                echo -e "  外网 223.5.5.5:  ${RED}不可达${NC}"
            fi
            if command -v nslookup >/dev/null 2>&1; then
                if nslookup openwrt.org >/dev/null 2>&1; then
                    dns_ok=1
                    echo -e "  DNS解析:         ${GREEN}正常${NC}"
                else
                    echo -e "  DNS解析:         ${RED}失败${NC}"
                fi
            fi
            echo ""
            if [ $gw_ok -eq 1 ] && [ $inet_ok -eq 1 ]; then
                echo -e "${GREEN}AP模式配置成功,网络正常!${NC}"
            elif [ $gw_ok -eq 1 ]; then
                echo -e "${YELLOW}网关可达但外网不通,请检查主路由是否正常上网${NC}"
            else
                echo -e "${RED}网关不可达,请检查:${NC}"
                echo -e "  1. 网线是否连接到主路由LAN口"
                echo -e "  2. 网关地址 $ap_gateway 是否正确"
                echo -e "  3. IP $ap_ip 是否与主路由同网段"
                echo -e "  4. 可运行备份恢复: sh $BACKUP_DIR/config_*/restore.sh"
            fi
            log "AP模式完成 gw=$gw_ok inet=$inet_ok dns=$dns_ok"
            ;;
        *)
            echo -e "${YELLOW}配置已保存未生效,手动执行:${NC}"
            echo -e "  /etc/init.d/network restart"
            log "AP模式配置完成,未重启"
            ;;
    esac
}

configure_offloading() {
    echo -e "\n${YELLOW}=== Flow Offloading 配置 ===${NC}"
    if ! /etc/init.d/firewall enabled 2>/dev/null; then
        echo -e "${YELLOW}防火墙未启用,Flow Offloading无法工作${NC}"
        printf "是否先启用防火墙? [y/N]: "
        read fw_en
        case "$fw_en" in
            y|Y)
                /etc/init.d/firewall enable 2>/dev/null
                /etc/init.d/firewall start 2>/dev/null
                ;;
            *) return ;;
        esac
    fi
    local fo=$(uci -q get firewall.@defaults[0].flow_offloading)
    local fohw=$(uci -q get firewall.@defaults[0].flow_offloading_hw)
    echo "当前状态:"
    echo "  软件分载: ${fo:-未设置(关闭)}"
    echo "  硬件分载: ${fohw:-未设置(关闭)}"
    local has_module=0
    if lsmod 2>/dev/null | grep -q "nf_flow_table\|xt_FLOWOFFLOAD"; then
        has_module=1
        echo -e "  内核模块: ${GREEN}已加载${NC}"
    else
        echo -e "  内核模块: ${YELLOW}未检测到${NC}"
    fi
    local has_hw=0
    if lsmod 2>/dev/null | grep -qE "nf_flow_table_hw|mtkhnat|shortcut_fe"; then
        has_hw=1
        echo -e "  硬件加速: ${GREEN}已加载${NC}"
    else
        echo -e "  硬件加速: ${YELLOW}未检测到${NC}"
    fi
    echo ""
    echo "  1) 开启软件流量分载"
    echo "  2) 开启软件+硬件流量分载"
    echo "  3) 关闭所有流量分载"
    echo "  4) 返回"
    while true; do
        printf "请选择 [1-4]: "
        read choice
        case $choice in
            1)
                uci set firewall.@defaults[0].flow_offloading='1'
                uci set firewall.@defaults[0].flow_offloading_hw='0'
                uci commit firewall
                /etc/init.d/firewall restart 2>/dev/null
                echo -e "${GREEN}软件分载已开启${NC}"
                log "开启软件offloading"
                break
                ;;
            2)
                if [ $has_hw -eq 0 ]; then
                    echo -e "${YELLOW}未检测到硬件加速模块,可能不生效${NC}"
                    printf "继续? [y/N]: "
                    read hw_c
                    case "$hw_c" in
                        y|Y) ;;
                        *) continue ;;
                    esac
                fi
                uci set firewall.@defaults[0].flow_offloading='1'
                uci set firewall.@defaults[0].flow_offloading_hw='1'
                uci commit firewall
                /etc/init.d/firewall restart 2>/dev/null
                echo -e "${GREEN}软件+硬件分载已开启${NC}"
                log "开启软件+硬件offloading"
                break
                ;;
            3)
                uci set firewall.@defaults[0].flow_offloading='0'
                uci set firewall.@defaults[0].flow_offloading_hw='0'
                uci commit firewall
                /etc/init.d/firewall restart 2>/dev/null
                echo -e "${GREEN}已关闭${NC}"
                log "关闭offloading"
                break
                ;;
            4) return ;;
            *) echo -e "${RED}无效${NC}" ;;
        esac
    done
    echo -e "\n${BLUE}验证:${NC}"
    if command -v iptables-save >/dev/null 2>&1; then
        local r=$(iptables-save 2>/dev/null | grep FLOWOFFLOAD)
        if [ -n "$r" ]; then
            echo -e "  IPv4: ${GREEN}$r${NC}"
        else
            echo -e "  IPv4: ${YELLOW}无FLOWOFFLOAD规则${NC}"
        fi
    fi
    if command -v ip6tables-save >/dev/null 2>&1; then
        local r6=$(ip6tables-save 2>/dev/null | grep FLOWOFFLOAD)
        if [ -n "$r6" ]; then
            echo -e "  IPv6: ${GREEN}$r6${NC}"
        else
            echo -e "  IPv6: ${YELLOW}无FLOWOFFLOAD规则${NC}"
        fi
    fi
}

backup_config() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_name="config_$timestamp"
    mkdir -p "$BACKUP_DIR/$backup_name"
    for f in network firewall dhcp wireless; do
        if [ -f "$CONFIG_DIR/$f" ]; then
            cp "$CONFIG_DIR/$f" "$BACKUP_DIR/$backup_name/"
        fi
    done
    if [ $VLAN_CAPABLE -eq 1 ]; then
        swconfig dev "$SWITCH_DEVICE" show > "$BACKUP_DIR/$backup_name/vlan_config" 2>/dev/null
    fi
    cat > "$BACKUP_DIR/$backup_name/restore.sh" <<RESTORE_EOF
#!/bin/sh
SCRIPT_DIR=\$(cd "\$(dirname "\$0")" && pwd)
for f in network firewall dhcp wireless; do
    if [ -f "\$SCRIPT_DIR/\$f" ]; then
        cp "\$SCRIPT_DIR/\$f" "$CONFIG_DIR/"
    fi
done
/etc/init.d/network restart
/etc/init.d/firewall enable 2>/dev/null
/etc/init.d/firewall restart 2>/dev/null
/etc/init.d/dnsmasq restart 2>/dev/null
echo "配置已恢复"
RESTORE_EOF
    chmod +x "$BACKUP_DIR/$backup_name/restore.sh"
    echo -e "${GREEN}已备份到: ${BACKUP_DIR}/${backup_name}${NC}"
    log "备份: $backup_name"
}

restore_config() {
    local backups=$(ls -d "$BACKUP_DIR"/config_* 2>/dev/null | sort -r)
    if [ -z "$backups" ]; then
        echo -e "${RED}无备份可恢复${NC}"
        return 1
    fi
    echo -e "\n${YELLOW}=== 恢复配置 ===${NC}"
    local i=1
    local backup_list=""
    for backup in $backups; do
        echo "  $i) $(basename "$backup")"
        backup_list="$backup_list $backup"
        i=$((i + 1))
    done
    local max=$((i - 1))
    local selected_backup=""
    while true; do
        printf "选择备份 (1-%d): " "$max"
        read choice
        if ! echo "$choice" | grep -qE '^[0-9]+$'; then
            echo -e "${RED}无效输入${NC}"
            continue
        fi
        if [ "$choice" -lt 1 ] || [ "$choice" -gt "$max" ]; then
            echo -e "${RED}超出范围${NC}"
            continue
        fi
        local idx=1
        for b in $backup_list; do
            if [ "$idx" -eq "$choice" ]; then
                selected_backup="$b"
                break
            fi
            idx=$((idx + 1))
        done
        break
    done
    printf "确认恢复 %s? [y/N]: " "$(basename "$selected_backup")"
    read confirm
    case "$confirm" in
        y|Y) ;;
        *) echo -e "${YELLOW}已取消${NC}"; return ;;
    esac
    for f in network firewall dhcp wireless; do
        if [ -f "$selected_backup/$f" ]; then
            cp "$selected_backup/$f" "$CONFIG_DIR/"
        fi
    done
    /etc/init.d/network restart
    /etc/init.d/firewall enable 2>/dev/null
    /etc/init.d/firewall restart 2>/dev/null
    /etc/init.d/dnsmasq restart 2>/dev/null
    echo -e "${GREEN}已恢复${NC}"
    log "恢复: $(basename "$selected_backup")"
}

apply_configuration() {
    echo -e "\n${YELLOW}=== 应用配置 ===${NC}"
    local changes=$(uci changes 2>/dev/null)
    if [ -z "$changes" ]; then
        echo -e "${YELLOW}无待应用的更改${NC}"
        return
    fi
    echo -e "${GREEN}待应用:${NC}"
    echo "$changes" | sed 's/^/  /'
    echo ""
    printf "确认? [y/N]: "
    read confirm
    case "$confirm" in
        y|Y) ;;
        *) echo -e "${YELLOW}已取消${NC}"; return ;;
    esac
    uci commit network
    uci commit firewall
    uci commit dhcp
    /etc/init.d/network restart
    /etc/init.d/firewall restart 2>/dev/null
    /etc/init.d/dnsmasq restart 2>/dev/null
    echo -e "${GREEN}已应用${NC}"
    log "配置已应用"
}

network_diagnostics() {
    echo -e "\n${YELLOW}=== 网络诊断 ===${NC}"
    local lan_ip=$(uci -q get network.lan.ipaddr)
    local lan_gw=$(uci -q get network.lan.gateway)
    local lan_dns=$(uci -q get network.lan.dns 2>/dev/null)
    echo -e "\n${GREEN}[基本信息]${NC}"
    echo "  本机IP: ${lan_ip:-未设置}"
    echo "  网关:   ${lan_gw:-未设置}"
    echo "  DNS:    ${lan_dns:-未设置}"
    echo -e "\n${GREEN}[IPv4路由表]${NC}"
    ip route 2>/dev/null | sed 's/^/  /'
    echo -e "\n${GREEN}[IPv6路由表]${NC}"
    ip -6 route 2>/dev/null | head -10 | sed 's/^/  /'
    if [ -n "$lan_gw" ]; then
        echo -e "\n${GREEN}[网关连通]${NC}"
        if ping -c 2 -W 3 "$lan_gw" >/dev/null 2>&1; then
            echo -e "  ping $lan_gw: ${GREEN}通${NC}"
        else
            echo -e "  ping $lan_gw: ${RED}不通${NC}"
        fi
    else
        echo -e "\n${GREEN}[网关连通]${NC}"
        echo -e "  ${RED}未设置网关${NC}"
    fi
    echo -e "\n${GREEN}[外网连通]${NC}"
    if ping -c 2 -W 3 223.5.5.5 >/dev/null 2>&1; then
        echo -e "  ping 223.5.5.5: ${GREEN}通${NC}"
    else
        echo -e "  ping 223.5.5.5: ${RED}不通${NC}"
    fi
    echo -e "\n${GREEN}[DNS解析]${NC}"
    if command -v nslookup >/dev/null 2>&1; then
        if nslookup openwrt.org >/dev/null 2>&1; then
            echo -e "  DNS: ${GREEN}正常${NC}"
        else
            echo -e "  DNS: ${RED}失败${NC}"
        fi
    else
        echo -e "  ${YELLOW}nslookup不可用${NC}"
    fi
    echo -e "\n${GREEN}[桥接状态]${NC}"
    if command -v brctl >/dev/null 2>&1; then
        brctl show 2>/dev/null | sed 's/^/  /'
    else
        ip link show type bridge 2>/dev/null | sed 's/^/  /'
    fi
    echo -e "\n${GREEN}[接口状态]${NC}"
    for iface in $PHYSICAL_IFACES; do
        local st=$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || echo "unknown")
        local cr=$(cat "/sys/class/net/$iface/carrier" 2>/dev/null || echo "0")
        printf "  %-10s state=%-8s carrier=%s\n" "$iface" "$st" "$cr"
    done
    echo -e "\n${GREEN}[服务状态]${NC}"
    if /etc/init.d/firewall enabled 2>/dev/null; then
        echo -e "  防火墙: ${GREEN}启用${NC}"
    else
        echo -e "  防火墙: ${YELLOW}禁用${NC}"
    fi
    local dhcp_ign=$(uci -q get dhcp.lan.ignore)
    if [ "$dhcp_ign" = "1" ]; then
        echo -e "  DHCP:   ${YELLOW}关闭${NC}"
    else
        echo -e "  DHCP:   ${GREEN}开启${NC}"
    fi
    local wan_exists=$(uci -q get network.wan)
    if [ -n "$wan_exists" ]; then
        echo -e "  WAN口:  ${GREEN}存在${NC}"
    else
        echo -e "  WAN口:  ${YELLOW}不存在(AP模式)${NC}"
    fi
    log "诊断完成"
}

show_main_menu() {
    clear
    echo -e "${YELLOW}=================================================${NC}"
    echo -e "  OpenWRT 多网口高级配置工具 ${GREEN}v${VERSION}${NC}"
    echo -e "${YELLOW}=================================================${NC}"
    echo -e "  ${GREEN} 1.${NC} 显示当前网络配置"
    echo -e "  ${GREEN} 2.${NC} 配置WAN接口"
    echo -e "  ${GREEN} 3.${NC} 配置LAN接口"
    echo -e "  ${GREEN} 4.${NC} 配置VLAN"
    echo -e "  ${GREEN} 5.${NC} 备份当前配置"
    echo -e "  ${GREEN} 6.${NC} 恢复备份配置"
    echo -e "  ${GREEN} 7.${NC} 应用所有配置"
    echo -e "  ${GREEN} 8.${NC} AP/桥接模式一键配置"
    echo -e "  ${GREEN} 9.${NC} Flow Offloading 配置"
    echo -e "  ${GREEN}10.${NC} 网络诊断"
    echo -e "  ${GREEN} 0.${NC} 退出"
    echo -e "${YELLOW}=================================================${NC}"
}

main_loop() {
    while true; do
        show_main_menu
        printf "请输入 [0-10]: "
        read option
        case $option in
            1) show_current_config ;;
            2) configure_wan ;;
            3) configure_lan ;;
            4) configure_vlan ;;
            5) backup_config ;;
            6) restore_config ;;
            7) apply_configuration ;;
            8) configure_ap_mode ;;
            9) configure_offloading ;;
            10) network_diagnostics ;;
            0)
                echo -e "${GREEN}再见${NC}"
                log "退出"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选项${NC}"
                sleep 1
                ;;
        esac
        echo
        printf "按回车返回菜单..."
        read dummy
    done
}

init_check
get_system_info
init_switch_port_map
detect_interfaces
main_loop
