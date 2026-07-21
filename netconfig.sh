#!/bin/sh

VERSION="1.1"
CONFIG_DIR="/etc/config"
BACKUP_DIR="/etc/backups"
LOG_FILE="/tmp/netconfig.log"
SWITCH_DEVICE=""
SWPORT_MAP=""
PHYSICAL_IFACES=""
VLAN_CAPABLE=0
SELECTED_RESULT=""
NET_STYLE=""

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
    log "===== 脚本初始化 v${VERSION} ====="
    if [ -n "$SSH_CONNECTION" ]; then
        echo -e "${YELLOW}警告: SSH连接中,配置网络可能导致断开${NC}"
        printf "按回车继续或Ctrl+C退出..."
        read dummy
    fi
}

detect_net_style() {
    NET_STYLE="new"
    if uci show network 2>/dev/null | grep -q "\.ifname="; then
        if ! uci show network 2>/dev/null | grep -q "\.type='bridge'"; then
            NET_STYLE="old"
        fi
    fi
    if uci show network 2>/dev/null | grep -qE "config device.*bridge"; then
        NET_STYLE="new"
    fi
    local test_dev=$(uci show network 2>/dev/null | grep "\.name='br-lan'" | head -1)
    if [ -n "$test_dev" ]; then
        NET_STYLE="new"
    fi
    log "网络配置风格: $NET_STYLE"
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
        echo -e "${BLUE}交换机: ${SWITCH_DEVICE} (swconfig)${NC}"
    else
        local dsa_ports=""
        for d in /sys/class/net/lan* /sys/class/net/wan*; do
            [ -e "$d" ] && dsa_ports="$dsa_ports $(basename "$d")"
        done
        dsa_ports=$(echo "$dsa_ports" | xargs)
        if [ -n "$dsa_ports" ]; then
            echo -e "${BLUE}DSA端口: ${dsa_ports}${NC}"
        fi
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
        if [ -d "/sys/class/net/$iface/device" ] || echo "$iface" | grep -qE '^(eth[0-9]|lan[0-9]|wan[0-9]?$)'; then
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
    log "物理接口: $PHYSICAL_IFACES"
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
        echo -e "\n${GREEN}交换机VLAN:${NC}"
        swconfig dev "$SWITCH_DEVICE" show 2>/dev/null | grep -E 'vid|ports' | sed 's/^/  /'
    fi
    echo -e "\n${GREEN}防火墙区域:${NC}"
    uci show firewall 2>/dev/null | grep -E "\.name=|\.network=|\.input=|\.forward=" | sed 's/firewall\./  /'
    echo -e "\n${GREEN}桥接:${NC}"
    if command -v brctl >/dev/null 2>&1; then
        brctl show 2>/dev/null | sed 's/^/  /'
    fi
    echo -e "\n${GREEN}DHCP:${NC}"
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
            echo -e "${RED}未选择${NC}"
            return 1
        fi
        for choice in $choices; do
            if ! echo "$choice" | grep -qE '^[0-9]+$'; then
                echo -e "${RED}无效输入 '$choice'${NC}"
                return 1
            fi
            if [ "$choice" -lt 1 ] || [ "$choice" -gt "$max" ]; then
                echo -e "${RED}$choice 超出范围${NC}"
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
        printf "请选择 (1-%d): " "$max"
        read choice
        if ! echo "$choice" | grep -qE '^[0-9]+$'; then
            echo -e "${RED}无效${NC}"
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
    echo -e "\n${GREEN}WAN类型:${NC}"
    echo "  1) PPPoE"
    echo "  2) DHCP"
    echo "  3) 静态IP"
    echo "  4) 取消"
    local wan_type=""
    while true; do
        printf "选择 [1-4]: "
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
            printf "用户名: "
            read pppoe_user
            if [ -z "$pppoe_user" ]; then
                echo -e "${RED}不能为空${NC}"
                return 1
            fi
            printf "密码: "
            stty -echo 2>/dev/null
            read pppoe_pass
            stty echo 2>/dev/null
            echo
            if [ -z "$pppoe_pass" ]; then
                echo -e "${RED}不能为空${NC}"
                return 1
            fi
            uci set network.wan=interface
            if [ "$NET_STYLE" = "old" ]; then
                uci set network.wan.ifname="$wan_iface"
            else
                uci set network.wan.device="$wan_iface"
            fi
            uci set network.wan.proto="pppoe"
            uci set network.wan.username="$pppoe_user"
            uci set network.wan.password="$pppoe_pass"
            ;;
        "dhcp")
            uci set network.wan=interface
            if [ "$NET_STYLE" = "old" ]; then
                uci set network.wan.ifname="$wan_iface"
            else
                uci set network.wan.device="$wan_iface"
            fi
            uci set network.wan.proto="dhcp"
            ;;
        "static")
            local static_ip static_mask static_gw static_dns
            while true; do
                printf "IP: "
                read static_ip
                validate_ip "$static_ip" && break
                echo -e "${RED}无效${NC}"
            done
            while true; do
                printf "掩码 [255.255.255.0]: "
                read static_mask
                static_mask=${static_mask:-255.255.255.0}
                validate_netmask "$static_mask" && break
                echo -e "${RED}无效${NC}"
            done
            while true; do
                printf "网关(留空跳过): "
                read static_gw
                if [ -z "$static_gw" ]; then break; fi
                validate_ip "$static_gw" && break
                echo -e "${RED}无效${NC}"
            done
            while true; do
                printf "DNS(留空跳过): "
                read static_dns
                if [ -z "$static_dns" ]; then break; fi
                validate_ip "$static_dns" && break
                echo -e "${RED}无效${NC}"
            done
            uci set network.wan=interface
            if [ "$NET_STYLE" = "old" ]; then
                uci set network.wan.ifname="$wan_iface"
            else
                uci set network.wan.device="$wan_iface"
            fi
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
        if [ "$(uci -q get "firewall.@zone[$zone_idx].name")" = "wan" ]; then
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
}

configure_lan() {
    echo -e "\n${YELLOW}=== 配置LAN接口 ===${NC}"
    if ! select_interfaces "选择LAN接口(可多选)" "multi"; then
        return 1
    fi
    local lan_ifaces=$SELECTED_RESULT
    local lan_ip
    while true; do
        printf "LAN IP: "
        read lan_ip
        validate_ip "$lan_ip" && break
        echo -e "${RED}无效${NC}"
    done
    uci set network.lan=interface
    uci set network.lan.proto='static'
    uci set network.lan.ipaddr="$lan_ip"
    uci set network.lan.netmask='255.255.255.0'
    local iface_count=$(echo "$lan_ifaces" | wc -w)
    if [ "$iface_count" -gt 1 ]; then
        if [ "$NET_STYLE" = "old" ]; then
            uci set network.lan.type='bridge'
            uci set network.lan.ifname="$lan_ifaces"
        else
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
        fi
    else
        if [ "$NET_STYLE" = "old" ]; then
            uci set network.lan.ifname="$lan_ifaces"
        else
            uci set network.lan.device="$lan_ifaces"
        fi
    fi
    configure_dhcp "$lan_ip"
    echo -e "${GREEN}LAN配置完成${NC}"
    log "LAN: $lan_ifaces IP=$lan_ip"
}

configure_dhcp() {
    local lan_ip=$1
    local base=$(echo "$lan_ip" | cut -d'.' -f1-3)
    echo -e "\n${YELLOW}=== DHCP ===${NC}"
    printf "启用DHCP? [Y/n]: "
    read en
    en=${en:-y}
    case "$en" in
        y|Y)
            local s e lt
            while true; do
                printf "起始 [%s.100]: " "$base"
                read s
                s=${s:-${base}.100}
                validate_ip "$s" && break
                echo -e "${RED}无效${NC}"
            done
            while true; do
                printf "结束 [%s.200]: " "$base"
                read e
                e=${e:-${base}.200}
                validate_ip "$e" && break
                echo -e "${RED}无效${NC}"
            done
            printf "租约 [12h]: "
            read lt
            lt=${lt:-12h}
            local sn=$(echo "$s" | cut -d'.' -f4)
            local en_n=$(echo "$e" | cut -d'.' -f4)
            local lim=$((en_n - sn + 1))
            if [ "$lim" -le 0 ]; then
                echo -e "${RED}结束必须大于起始${NC}"
                return 1
            fi
            uci set dhcp.lan=dhcp
            uci set dhcp.lan.interface='lan'
            uci set dhcp.lan.start="$sn"
            uci set dhcp.lan.limit="$lim"
            uci set dhcp.lan.leasetime="$lt"
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
        echo -e "${RED}不支持VLAN${NC}"
        return 1
    fi
    echo -e "\n${YELLOW}=== VLAN ===${NC}"
    echo "当前:"
    swconfig dev "$SWITCH_DEVICE" show 2>/dev/null | grep -E 'vid|ports' | sed 's/^/  /'
    echo ""
    echo "  1) 创建"
    echo "  2) 删除"
    echo "  3) 返回"
    while true; do
        printf "选择 [1-3]: "
        read c
        case $c in
            1) create_vlan; break ;;
            2) delete_vlan; break ;;
            3) return ;;
            *) echo -e "${RED}无效${NC}" ;;
        esac
    done
}

create_vlan() {
    local vid
    while true; do
        printf "VLAN ID (2-4094): "
        read vid
        if ! echo "$vid" | grep -qE '^[0-9]+$'; then
            echo -e "${RED}请输入数字${NC}"; continue
        fi
        if [ "$vid" -lt 2 ] || [ "$vid" -gt 4094 ]; then
            echo -e "${RED}范围2-4094${NC}"; continue
        fi
        if swconfig dev "$SWITCH_DEVICE" show 2>/dev/null | grep -q "vid: $vid"; then
            echo -e "${RED}已存在${NC}"; continue
        fi
        break
    done
    if ! select_interfaces "选择成员(可多选)" "multi"; then
        return 1
    fi
    local members=$SELECTED_RESULT
    local ports=""
    for iface in $members; do
        port=$(port_iface_to_switch "$iface")
        if [ -z "$port" ]; then
            echo -e "${RED}找不到 $iface 端口${NC}"
            return 1
        fi
        ports="$ports $port"
    done
    ports=$(echo "$ports" | xargs)
    uci set "network.vlan${vid}_sw=switch_vlan"
    uci set "network.vlan${vid}_sw.device=$SWITCH_DEVICE"
    uci set "network.vlan${vid}_sw.vlan=$vid"
    uci set "network.vlan${vid}_sw.ports=$ports"
    uci set "network.vlan$vid=interface"
    uci set "network.vlan$vid.device=eth0.$vid"
    uci set "network.vlan$vid.proto=static"
    printf "配置IP? [y/N]: "
    read ci
    case "$ci" in
        y|Y)
            local vip
            while true; do
                printf "IP: "
                read vip
                validate_ip "$vip" && break
                echo -e "${RED}无效${NC}"
            done
            uci set "network.vlan$vid.ipaddr=$vip"
            uci set "network.vlan$vid.netmask=255.255.255.0"
            ;;
    esac
    echo -e "${GREEN}VLAN $vid 已创建${NC}"
    log "创建VLAN $vid"
}

delete_vlan() {
    local vlans=$(swconfig dev "$SWITCH_DEVICE" show 2>/dev/null | grep 'vid:' | awk '{print $2}')
    if [ -z "$vlans" ]; then
        echo -e "${YELLOW}无VLAN${NC}"
        return
    fi
    echo "现有:"
    for v in $vlans; do echo "  VLAN $v"; done
    local dv
    while true; do
        printf "删除哪个: "
        read dv
        echo "$vlans" | grep -qw "$dv" && break
        echo -e "${RED}无效${NC}"
    done
    printf "确认删除 %s? [y/N]: " "$dv"
    read cf
    case "$cf" in
        y|Y) ;;
        *) return ;;
    esac
    uci -q delete "network.vlan$dv"
    uci -q delete "network.vlan${dv}_sw"
    echo -e "${GREEN}已删除${NC}"
    log "删除VLAN $dv"
}

get_bridge_mac() {
    local mac=""
    mac=$(cat /sys/class/net/br-lan/address 2>/dev/null)
    if [ -z "$mac" ]; then
        mac=$(uci -q get network.lan.macaddr)
    fi
    if [ -z "$mac" ]; then
        local br_sec=$(uci show network 2>/dev/null | grep "\.name='br-lan'" | head -1 | cut -d'.' -f2)
        if [ -n "$br_sec" ]; then
            mac=$(uci -q get "network.$br_sec.macaddr")
        fi
    fi
    if [ -z "$mac" ]; then
        local first_eth=$(echo "$PHYSICAL_IFACES" | awk '{print $1}')
        mac=$(cat "/sys/class/net/$first_eth/address" 2>/dev/null)
    fi
    echo "$mac"
}

setup_bridge_old_style() {
    local ifaces="$1"
    uci set network.lan.type='bridge'
    uci -q delete network.lan.ifname
    uci set network.lan.ifname="$ifaces"
}

setup_bridge_new_style() {
    local ifaces="$1"
    local mac="$2"
    local br_section=$(uci show network 2>/dev/null | grep "\.name='br-lan'" | head -1 | cut -d'.' -f2)
    if [ -z "$br_section" ]; then
        br_section=$(uci add network device)
    fi
    uci set "network.$br_section.name"='br-lan'
    uci set "network.$br_section.type"='bridge'
    uci -q delete "network.$br_section.ports"
    for p in $ifaces; do
        uci add_list "network.$br_section.ports"="$p"
    done
    if [ -n "$mac" ]; then
        uci set "network.$br_section.macaddr"="$mac"
    fi
    uci -q delete network.lan.ifname
    uci -q delete network.lan.type
    uci set network.lan.device='br-lan'
}

configure_ap_mode() {
    echo -e "\n${YELLOW}=================================================${NC}"
    echo -e "  ${GREEN}AP/桥接模式一键配置${NC}"
    echo -e "${YELLOW}=================================================${NC}"
    echo ""
    echo -e "  ${BLUE}将执行:${NC}"
    echo -e "  [1] 设置管理IP/子网掩码/网关/DNS"
    echo -e "  [2] 所有网口并入LAN桥接(含WAN口)"
    echo -e "  [3] 删除WAN/WAN6接口"
    echo -e "  [4] 关闭DHCP/DHCPv6/RA"
    echo -e "  [5] 清理IPv6配置"
    echo -e "  [6] 关闭Flow Offloading"
    echo -e "  [7] 停用防火墙"
    echo ""
    echo -e "  ${YELLOW}完成后作为纯AP/交换机,由主路由负责拨号/DHCP/NAT${NC}"
    echo ""
    printf "继续? [y/N]: "
    read ap_cf
    case "$ap_cf" in
        y|Y) ;;
        *) echo -e "${YELLOW}已取消${NC}"; return ;;
    esac
    echo -e "\n${BLUE}[1/9] 备份当前配置${NC}"
    backup_config
    echo -e "\n${BLUE}[2/9] 设置网络参数${NC}"
    echo ""
    echo -e "${YELLOW}请根据主路由网段填写(主路由一般为192.168.x.1)${NC}"
    echo -e "${YELLOW}本机IP不要和主路由或其他设备冲突${NC}"
    echo ""
    local current_ip=$(uci -q get network.lan.ipaddr)
    local current_mask=$(uci -q get network.lan.netmask)
    local current_gw=$(uci -q get network.lan.gateway)
    local current_dns=$(uci -q get network.lan.dns 2>/dev/null)
    local ap_ip ap_mask ap_gateway ap_dns
    while true; do
        printf "本机管理IP [%s]: " "${current_ip:-192.168.1.2}"
        read ap_ip
        ap_ip=${ap_ip:-${current_ip:-192.168.1.2}}
        if validate_ip "$ap_ip"; then break; fi
        echo -e "${RED}无效,重新输入${NC}"
    done
    while true; do
        printf "子网掩码 [%s]: " "${current_mask:-255.255.255.0}"
        read ap_mask
        ap_mask=${ap_mask:-${current_mask:-255.255.255.0}}
        if validate_netmask "$ap_mask"; then break; fi
        echo -e "${RED}无效,重新输入${NC}"
    done
    local default_gw=""
    if [ -n "$current_gw" ]; then
        default_gw="$current_gw"
    else
        default_gw=$(echo "$ap_ip" | cut -d'.' -f1-3).1
    fi
    while true; do
        printf "主路由网关 [%s]: " "$default_gw"
        read ap_gateway
        ap_gateway=${ap_gateway:-$default_gw}
        if validate_ip "$ap_gateway"; then break; fi
        echo -e "${RED}无效,重新输入${NC}"
    done
    local default_dns="${current_dns:-$ap_gateway}"
    while true; do
        printf "DNS服务器 [%s]: " "$default_dns"
        read ap_dns
        ap_dns=${ap_dns:-$default_dns}
        if validate_ip "$ap_dns"; then break; fi
        echo -e "${RED}无效,重新输入${NC}"
    done
    local ap_net=$(echo "$ap_ip" | cut -d'.' -f1-3)
    local gw_net=$(echo "$ap_gateway" | cut -d'.' -f1-3)
    if [ "$ap_net" != "$gw_net" ]; then
        echo -e "${RED}警告: 管理IP($ap_ip)和网关($ap_gateway)不在同一网段${NC}"
        printf "确定继续? [y/N]: "
        read seg_cf
        case "$seg_cf" in
            y|Y) ;;
            *) echo -e "${YELLOW}已取消${NC}"; return ;;
        esac
    fi
    if [ "$ap_ip" = "$ap_gateway" ]; then
        echo -e "${RED}管理IP不能和网关相同${NC}"
        return
    fi
    echo -e "\n${YELLOW}--- 确认配置 ---${NC}"
    echo -e "  管理IP:   ${GREEN}$ap_ip${NC}"
    echo -e "  子网掩码: ${GREEN}$ap_mask${NC}"
    echo -e "  网关:     ${GREEN}$ap_gateway${NC}"
    echo -e "  DNS:      ${GREEN}$ap_dns${NC}"
    echo -e "  桥接网口: ${GREEN}$PHYSICAL_IFACES${NC}"
    echo ""
    printf "正确? [Y/n]: "
    read info_cf
    case "$info_cf" in
        n|N) echo -e "${YELLOW}已取消${NC}"; return ;;
    esac
    echo -e "\n${BLUE}[3/9] 配置桥接${NC}"
    local current_mac=$(get_bridge_mac)
    if [ "$NET_STYLE" = "old" ]; then
        setup_bridge_old_style "$PHYSICAL_IFACES"
    else
        setup_bridge_new_style "$PHYSICAL_IFACES" "$current_mac"
    fi
    echo -e "  ${GREEN}桥接成员: $PHYSICAL_IFACES${NC}"
    echo -e "\n${BLUE}[4/9] 配置LAN接口${NC}"
    uci set network.lan=interface
    if [ "$NET_STYLE" = "old" ]; then
        true
    else
        uci set network.lan.device='br-lan'
    fi
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
    uci -q delete network.lan.ip6prefix
    uci set network.lan.delegate='0'
    if [ -n "$current_mac" ]; then
        uci set network.lan.macaddr="$current_mac"
    fi
    echo -e "  ${GREEN}IP=$ap_ip 掩码=$ap_mask 网关=$ap_gateway DNS=$ap_dns${NC}"
    echo -e "\n${BLUE}[5/9] 删除WAN接口${NC}"
    uci -q delete network.wan
    uci -q delete network.wan6
    echo -e "  ${GREEN}wan/wan6已删除${NC}"
    echo -e "\n${BLUE}[6/9] 关闭DHCP/IPv6${NC}"
    uci set dhcp.lan=dhcp
    uci set dhcp.lan.interface='lan'
    uci set dhcp.lan.ignore='1'
    uci -q set dhcp.lan.dynamicdhcp='0'
    uci -q set dhcp.lan.ra='disabled'
    uci -q set dhcp.lan.dhcpv6='disabled'
    uci -q set dhcp.lan.ra_management='0'
    uci -q set dhcp.lan.ra_default='0'
    if uci -q get dhcp.odhcpd >/dev/null 2>&1; then
        uci set dhcp.odhcpd.maindhcp='0'
    fi
    echo -e "  ${GREEN}DHCP/DHCPv6/RA已关闭${NC}"
    echo -e "\n${BLUE}[7/9] 关闭Flow Offloading${NC}"
    if uci -q get firewall.@defaults[0] >/dev/null 2>&1; then
        uci set firewall.@defaults[0].flow_offloading='0'
        uci set firewall.@defaults[0].flow_offloading_hw='0'
    fi
    echo -e "  ${GREEN}已关闭${NC}"
    echo -e "\n${BLUE}[8/9] 停用防火墙${NC}"
    printf "  停用防火墙? (AP模式建议停用) [Y/n]: "
    read fw_cf
    fw_cf=${fw_cf:-y}
    local fw_action=""
    case "$fw_cf" in
        y|Y) fw_action="disable" ;;
        *) fw_action="clean" ;;
    esac
    echo -e "\n${BLUE}[9/9] 提交配置${NC}"
    uci commit network
    uci commit dhcp
    uci commit firewall
    if [ "$fw_action" = "disable" ]; then
        /etc/init.d/firewall stop 2>/dev/null
        /etc/init.d/firewall disable 2>/dev/null
        echo -e "  ${GREEN}防火墙已停用${NC}"
    else
        local zone_idx=0
        local del_list=""
        while uci -q get "firewall.@zone[$zone_idx]" >/dev/null 2>&1; do
            if [ "$(uci -q get "firewall.@zone[$zone_idx].name")" = "wan" ]; then
                del_list="$del_list $zone_idx"
            fi
            zone_idx=$((zone_idx + 1))
        done
        for didx in $(echo "$del_list" | tr ' ' '\n' | sort -rn); do
            uci -q delete "firewall.@zone[$didx]"
        done
        local fwd_idx=0
        local fwd_del=""
        while uci -q get "firewall.@forwarding[$fwd_idx]" >/dev/null 2>&1; do
            local fs=$(uci -q get "firewall.@forwarding[$fwd_idx].src")
            local fd=$(uci -q get "firewall.@forwarding[$fwd_idx].dest")
            if [ "$fd" = "wan" ] || [ "$fs" = "wan" ]; then
                fwd_del="$fwd_del $fwd_idx"
            fi
            fwd_idx=$((fwd_idx + 1))
        done
        for didx in $(echo "$fwd_del" | tr ' ' '\n' | sort -rn); do
            uci -q delete "firewall.@forwarding[$didx]"
        done
        uci commit firewall
        echo -e "  ${YELLOW}防火墙保留,已清理wan区域${NC}"
    fi
    echo -e "  ${GREEN}配置已提交${NC}"
    echo -e "\n${YELLOW}============= 配置摘要 =============${NC}"
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
        echo -e "  防火墙:    ${YELLOW}保留(已清理wan)${NC}"
    fi
    echo -e "${YELLOW}====================================${NC}"
    echo ""
    echo -e "${YELLOW}注意事项:${NC}"
    echo -e "  1. 主路由LAN口 → 网线 → 本机任意网口"
    echo -e "  2. 主路由DHCP池请避开 $ap_ip"
    echo -e "  3. 重启后用 $ap_ip 访问管理页面"
    echo -e "  4. 出问题可运行: sh $BACKUP_DIR/config_*/restore.sh"
    echo ""
    printf "立即重启网络生效? [y/N]: "
    read rst_cf
    case "$rst_cf" in
        y|Y)
            echo -e "\n${BLUE}重启网络...${NC}"
            /etc/init.d/network restart
            sleep 3
            if /etc/init.d/dnsmasq enabled 2>/dev/null; then
                /etc/init.d/dnsmasq restart 2>/dev/null
            fi
            if [ "$fw_action" != "disable" ]; then
                /etc/init.d/firewall restart 2>/dev/null
            fi
            echo -e "${GREEN}网络已重启${NC}"
            echo ""
            echo -e "${BLUE}验证连通性...${NC}"
            sleep 2
            local gw_ok=0 inet_ok=0 dns_ok=0
            if ping -c 2 -W 3 "$ap_gateway" >/dev/null 2>&1; then
                gw_ok=1
                echo -e "  网关 $ap_gateway: ${GREEN}通${NC}"
            else
                echo -e "  网关 $ap_gateway: ${RED}不通${NC}"
            fi
            if ping -c 2 -W 3 223.5.5.5 >/dev/null 2>&1; then
                inet_ok=1
                echo -e "  外网 223.5.5.5:  ${GREEN}通${NC}"
            else
                echo -e "  外网 223.5.5.5:  ${RED}不通${NC}"
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
                echo -e "${GREEN}配置成功! 网络正常!${NC}"
            elif [ $gw_ok -eq 1 ]; then
                echo -e "${YELLOW}网关通但外网不通,检查主路由是否联网${NC}"
            else
                echo -e "${RED}网关不通,请检查:${NC}"
                echo -e "  - 网线是否连主路由LAN口"
                echo -e "  - 网关 $ap_gateway 是否正确"
                echo -e "  - IP $ap_ip 是否与主路由同网段"
                echo -e "  - 恢复: sh $BACKUP_DIR/config_*/restore.sh"
            fi
            log "AP完成 gw=$gw_ok inet=$inet_ok dns=$dns_ok"
            ;;
        *)
            echo -e "${YELLOW}已保存未生效,手动执行: /etc/init.d/network restart${NC}"
            log "AP配置完成,未重启"
            ;;
    esac
}

configure_offloading() {
    echo -e "\n${YELLOW}=== Flow Offloading ===${NC}"
    if ! /etc/init.d/firewall enabled 2>/dev/null; then
        echo -e "${YELLOW}防火墙未启用,Offloading无法工作${NC}"
        printf "先启用防火墙? [y/N]: "
        read fe
        case "$fe" in
            y|Y)
                /etc/init.d/firewall enable 2>/dev/null
                /etc/init.d/firewall start 2>/dev/null
                ;;
            *) return ;;
        esac
    fi
    local fo=$(uci -q get firewall.@defaults[0].flow_offloading)
    local fohw=$(uci -q get firewall.@defaults[0].flow_offloading_hw)
    echo "当前:"
    echo "  软件分载: ${fo:-关闭}"
    echo "  硬件分载: ${fohw:-关闭}"
    local has_hw=0
    if lsmod 2>/dev/null | grep -qE "nf_flow_table_hw|mtkhnat|shortcut_fe"; then
        has_hw=1
        echo -e "  硬件模块: ${GREEN}已加载${NC}"
    else
        echo -e "  硬件模块: ${YELLOW}未检测到${NC}"
    fi
    echo ""
    echo "  1) 开启软件分载"
    echo "  2) 开启软件+硬件分载"
    echo "  3) 全部关闭"
    echo "  4) 返回"
    while true; do
        printf "选择 [1-4]: "
        read c
        case $c in
            1)
                uci set firewall.@defaults[0].flow_offloading='1'
                uci set firewall.@defaults[0].flow_offloading_hw='0'
                uci commit firewall
                /etc/init.d/firewall restart 2>/dev/null
                echo -e "${GREEN}软件分载已开启${NC}"
                break ;;
            2)
                if [ $has_hw -eq 0 ]; then
                    echo -e "${YELLOW}未检测到硬件模块${NC}"
                    printf "继续? [y/N]: "
                    read hc
                    case "$hc" in y|Y) ;; *) continue ;; esac
                fi
                uci set firewall.@defaults[0].flow_offloading='1'
                uci set firewall.@defaults[0].flow_offloading_hw='1'
                uci commit firewall
                /etc/init.d/firewall restart 2>/dev/null
                echo -e "${GREEN}软件+硬件分载已开启${NC}"
                break ;;
            3)
                uci set firewall.@defaults[0].flow_offloading='0'
                uci set firewall.@defaults[0].flow_offloading_hw='0'
                uci commit firewall
                /etc/init.d/firewall restart 2>/dev/null
                echo -e "${GREEN}已关闭${NC}"
                break ;;
            4) return ;;
            *) echo -e "${RED}无效${NC}" ;;
        esac
    done
    echo -e "\n${BLUE}验证:${NC}"
    if command -v iptables-save >/dev/null 2>&1; then
        local r=$(iptables-save 2>/dev/null | grep FLOWOFFLOAD)
        if [ -n "$r" ]; then
            echo -e "  ${GREEN}$r${NC}"
        else
            echo -e "  ${YELLOW}无FLOWOFFLOAD规则${NC}"
        fi
    fi
}

backup_config() {
    local ts=$(date +%Y%m%d_%H%M%S)
    local bn="config_$ts"
    mkdir -p "$BACKUP_DIR/$bn"
    for f in network firewall dhcp wireless; do
        [ -f "$CONFIG_DIR/$f" ] && cp "$CONFIG_DIR/$f" "$BACKUP_DIR/$bn/"
    done
    if [ $VLAN_CAPABLE -eq 1 ]; then
        swconfig dev "$SWITCH_DEVICE" show > "$BACKUP_DIR/$bn/vlan_config" 2>/dev/null
    fi
    cat > "$BACKUP_DIR/$bn/restore.sh" <<REOF
#!/bin/sh
D=\$(cd "\$(dirname "\$0")" && pwd)
for f in network firewall dhcp wireless; do
    [ -f "\$D/\$f" ] && cp "\$D/\$f" "$CONFIG_DIR/"
done
/etc/init.d/network restart
/etc/init.d/firewall enable 2>/dev/null
/etc/init.d/firewall restart 2>/dev/null
/etc/init.d/dnsmasq restart 2>/dev/null
echo "已恢复"
REOF
    chmod +x "$BACKUP_DIR/$bn/restore.sh"
    echo -e "${GREEN}已备份: ${BACKUP_DIR}/${bn}${NC}"
    log "备份: $bn"
}

restore_config() {
    local bks=$(ls -d "$BACKUP_DIR"/config_* 2>/dev/null | sort -r)
    if [ -z "$bks" ]; then
        echo -e "${RED}无备份${NC}"
        return 1
    fi
    echo -e "\n${YELLOW}=== 恢复 ===${NC}"
    local i=1 blist=""
    for b in $bks; do
        echo "  $i) $(basename "$b")"
        blist="$blist $b"
        i=$((i + 1))
    done
    local mx=$((i - 1)) sb=""
    while true; do
        printf "选择 (1-%d): " "$mx"
        read ch
        if ! echo "$ch" | grep -qE '^[0-9]+$'; then
            echo -e "${RED}无效${NC}"; continue
        fi
        if [ "$ch" -lt 1 ] || [ "$ch" -gt "$mx" ]; then
            echo -e "${RED}超出${NC}"; continue
        fi
        local idx=1
        for b in $blist; do
            [ "$idx" -eq "$ch" ] && sb="$b" && break
            idx=$((idx + 1))
        done
        break
    done
    printf "确认恢复 %s? [y/N]: " "$(basename "$sb")"
    read cf
    case "$cf" in y|Y) ;; *) echo -e "${YELLOW}取消${NC}"; return ;; esac
    for f in network firewall dhcp wireless; do
        [ -f "$sb/$f" ] && cp "$sb/$f" "$CONFIG_DIR/"
    done
    /etc/init.d/network restart
    /etc/init.d/firewall enable 2>/dev/null
    /etc/init.d/firewall restart 2>/dev/null
    /etc/init.d/dnsmasq restart 2>/dev/null
    echo -e "${GREEN}已恢复${NC}"
    log "恢复: $(basename "$sb")"
}

apply_configuration() {
    echo -e "\n${YELLOW}=== 应用 ===${NC}"
    local ch=$(uci changes 2>/dev/null)
    if [ -z "$ch" ]; then
        echo -e "${YELLOW}无更改${NC}"
        return
    fi
    echo -e "${GREEN}待应用:${NC}"
    echo "$ch" | sed 's/^/  /'
    printf "\n确认? [y/N]: "
    read cf
    case "$cf" in y|Y) ;; *) echo -e "${YELLOW}取消${NC}"; return ;; esac
    uci commit network
    uci commit firewall
    uci commit dhcp
    /etc/init.d/network restart
    /etc/init.d/firewall restart 2>/dev/null
    /etc/init.d/dnsmasq restart 2>/dev/null
    echo -e "${GREEN}已应用${NC}"
    log "已应用"
}

network_diagnostics() {
    echo -e "\n${YELLOW}=== 网络诊断 ===${NC}"
    local lip=$(uci -q get network.lan.ipaddr)
    local lgw=$(uci -q get network.lan.gateway)
    local ldns=$(uci -q get network.lan.dns 2>/dev/null)
    echo -e "\n${GREEN}[基本信息]${NC}"
    echo "  IP:   ${lip:-未设置}"
    echo "  网关: ${lgw:-未设置}"
    echo "  DNS:  ${ldns:-未设置}"
    echo -e "\n${GREEN}[路由表]${NC}"
    ip route 2>/dev/null | sed 's/^/  /'
    if [ -n "$lgw" ]; then
        echo -e "\n${GREEN}[网关]${NC}"
        if ping -c 2 -W 3 "$lgw" >/dev/null 2>&1; then
            echo -e "  $lgw: ${GREEN}通${NC}"
        else
            echo -e "  $lgw: ${RED}不通${NC}"
        fi
    fi
    echo -e "\n${GREEN}[外网]${NC}"
    if ping -c 2 -W 3 223.5.5.5 >/dev/null 2>&1; then
        echo -e "  223.5.5.5: ${GREEN}通${NC}"
    else
        echo -e "  223.5.5.5: ${RED}不通${NC}"
    fi
    echo -e "\n${GREEN}[DNS]${NC}"
    if command -v nslookup >/dev/null 2>&1; then
        if nslookup openwrt.org >/dev/null 2>&1; then
            echo -e "  ${GREEN}正常${NC}"
        else
            echo -e "  ${RED}失败${NC}"
        fi
    else
        echo -e "  ${YELLOW}nslookup不可用${NC}"
    fi
    echo -e "\n${GREEN}[桥接]${NC}"
    if command -v brctl >/dev/null 2>&1; then
        brctl show 2>/dev/null | sed 's/^/  /'
    fi
    echo -e "\n${GREEN}[接口]${NC}"
    for iface in $PHYSICAL_IFACES; do
        local st=$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || echo "?")
        local cr=$(cat "/sys/class/net/$iface/carrier" 2>/dev/null || echo "?")
        printf "  %-10s state=%-6s carrier=%s\n" "$iface" "$st" "$cr"
    done
    echo -e "\n${GREEN}[服务]${NC}"
    if /etc/init.d/firewall enabled 2>/dev/null; then
        echo -e "  防火墙: ${GREEN}启用${NC}"
    else
        echo -e "  防火墙: ${YELLOW}禁用${NC}"
    fi
    local di=$(uci -q get dhcp.lan.ignore)
    if [ "$di" = "1" ]; then
        echo -e "  DHCP:   ${YELLOW}关闭${NC}"
    else
        echo -e "  DHCP:   ${GREEN}开启${NC}"
    fi
    if uci -q get network.wan >/dev/null 2>&1; then
        echo -e "  WAN:    ${GREEN}存在${NC}"
    else
        echo -e "  WAN:    ${YELLOW}不存在(AP模式)${NC}"
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
                echo -e "${RED}无效${NC}"
                sleep 1
                ;;
        esac
        echo
        printf "按回车返回..."
        read dummy
    done
}

init_check
get_system_info
detect_net_style
init_switch_port_map
detect_interfaces
main_loop
