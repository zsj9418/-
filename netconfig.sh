#!/bin/sh

# OpenWRT 多网口高级配置脚本
# 终极优化版 v3.0
# 功能：支持任意数量网口的WAN/LAN/VLAN配置，含智能检测与容错机制

# 全局变量
VERSION="3.0"
CONFIG_DIR="/etc/config"
BACKUP_DIR="/etc/backups"
LOG_FILE="/tmp/netconfig.log"

# 颜色定义
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m'

# 日志记录
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> $LOG_FILE
}

# 初始化检查
init_check() {
    # 检查root权限
    [ "$(id -u)" -ne 0 ] && {
        echo -e "${RED}错误: 此脚本必须以root权限运行！${NC}" 
        log "权限检查失败"
        exit 1
    }

    # 检查OpenWRT系统
    ! grep -q "OpenWrt" /etc/os-release 2>/dev/null && {
        echo -e "${RED}错误: 此脚本仅适用于OpenWRT系统！${NC}"
        log "系统检查失败"
        exit 1
    }

    # 创建必要目录
    mkdir -p $BACKUP_DIR
    touch $LOG_FILE
    log "===== 脚本初始化 ====="
}

# 获取系统信息
get_system_info() {
    ARCH=$(uname -m)
    MODEL=$(cat /proc/cpuinfo | grep -i 'model name' | head -1 | cut -d':' -f2 | sed 's/^[ \t]*//')
    SWITCH_INFO=$(swconfig dev switch0 help 2>/dev/null | head -1)
    
    echo -e "${BLUE}系统架构: ${ARCH}${NC}"
    echo -e "${BLUE}设备型号: ${MODEL}${NC}"
    [ -n "$SWITCH_INFO" ] && echo -e "${BLUE}交换机信息: ${SWITCH_INFO}${NC}"
    
    log "系统信息收集完成"
}

# 网络接口检测
detect_interfaces() {
    # 物理接口检测
    PHYSICAL_IFACES=$(ls -1 /sys/class/net/ | grep -E 'eth[0-9]+|enp[0-9]+s[0-9]+|wan[0-9]*|lan[0-9]*' | sort | uniq)
    [ -z "$PHYSICAL_IFACES" ] && {
        echo -e "${RED}错误: 未检测到物理网络接口！${NC}"
        log "接口检测失败"
        exit 1
    }

    # VLAN能力检测
    VLAN_CAPABLE=0
    [ -n "$(command -v swconfig)" ] && VLAN_CAPABLE=1
    
    log "检测到物理接口: $PHYSICAL_IFACES"
    log "VLAN支持: $VLAN_CAPABLE"
}

# IP地址验证
validate_ip() {
    echo "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'
}

# 子网掩码验证
validate_netmask() {
    validate_ip "$1" && {
        local mask=$1
        local binary=$(echo "$mask" | awk -F. '{printf "%d%d%d%d", $1,$2,$3,$4}')
        echo "$binary" | grep -Eq '^(1*0*)$'
    }
}

# 显示当前配置
show_current_config() {
    clear
    echo -e "${YELLOW}=== 当前网络配置 ===${NC}"
    
    # 接口配置
    echo -e "\n${GREEN}接口配置:${NC}"
    uci show network | grep -E "interface|ifname|proto|ipaddr|type" | sed 's/network\.//'
    
    # 物理接口状态
    echo -e "\n${GREEN}物理接口状态:${NC}"
    for iface in $PHYSICAL_IFACES; do
        state=$(ip link show $iface 2>/dev/null | grep -Eo 'state [A-Z]+' | cut -d' ' -f2 || echo "不存在")
        speed=$(ethtool $iface 2>/dev/null | grep -Eo '[0-9]+Mb/s' || echo "未知")
        echo -e "$iface: 状态=${state}, 速度=${speed}"
    done
    
    # VLAN配置
    [ $VLAN_CAPABLE -eq 1 ] && {
        echo -e "\n${GREEN}VLAN配置:${NC}"
        swconfig dev switch0 show | grep -E 'vid|ports'
    }
    
    # 防火墙配置
    echo -e "\n${GREEN}防火墙区域:${NC}"
    uci show firewall | grep -E "name|network|input|output|forward"
    
    log "显示当前配置完成"
}

# 智能接口选择
select_interfaces() {
    local prompt=$1
    local multi=$2
    local selected=""
    
    echo -e "\n${GREEN}${prompt}${NC}"
    echo "可用接口:"
    
    # 显示接口菜单
    local i=1
    local iface_list=""
    for iface in $PHYSICAL_IFACES; do
        state=$(ip link show $iface | grep -Eo 'state [A-Z]+' | cut -d' ' -f2)
        echo "$i) $iface (状态: $state)"
        iface_list="$iface_list $iface"
        i=$((i+1))
    done
    
    # 多选处理
    if [ "$multi" = "multi" ]; then
        echo "可多选 (用空格分隔数字，如 1 2 3):"
        read -p "请输入选择: " choices
        
        for choice in $choices; do
            local idx=1
            for iface in $iface_list; do
                if [ "$choice" = "$idx" ]; then
                    selected="$selected $iface"
                    break
                fi
                idx=$((idx+1))
            done
        done
    else
        # 单选处理
        read -p "请输入选择 (1-$((i-1))): " choice
        local idx=1
        for iface in $iface_list; do
            if [ "$choice" = "$idx" ]; then
                selected=$iface
                break
            fi
            idx=$((idx+1))
        done
    fi
    
    # 验证选择
    if [ -z "$selected" ]; then
        echo -e "${RED}错误: 无效的选择！${NC}"
        log "接口选择失败: 用户输入=$choices"
        return 1
    fi
    
    # 去除多余空格
    selected=$(echo $selected | xargs)
    echo -e "已选择: ${YELLOW}$selected${NC}"
    log "接口选择结果: $selected"
    
    # 返回选择结果
    SELECTED_RESULT=$selected
    return 0
}

# WAN接口配置
configure_wan() {
    echo -e "\n${YELLOW}=== 配置WAN接口 ===${NC}"
    
    # 接口选择
    if ! select_interfaces "请选择WAN接口" "single"; then
        return 1
    fi
    local wan_iface=$SELECTED_RESULT
    
    # WAN类型选择
    echo -e "\n${GREEN}选择WAN类型:${NC}"
    echo "1) PPPoE (ADSL拨号)"
    echo "2) DHCP (自动获取IP)"
    echo "3) Static (静态IP)"
    echo "4) 取消"
    
    while true; do
        read -p "请输入选择 [1-4]: " choice
        case $choice in
            1) wan_type="pppoe"; break ;;
            2) wan_type="dhcp"; break ;;
            3) wan_type="static"; break ;;
            4) return ;;
            *) echo -e "${RED}无效选择，请重新输入！${NC}" ;;
        esac
    done
    
    # 根据类型配置
    case $wan_type in
        "pppoe")
            read -p "输入PPPoE用户名: " pppoe_user
            [ -z "$pppoe_user" ] && {
                echo -e "${RED}错误: 用户名不能为空！${NC}"
                return 1
            }
            
            read -s -p "输入PPPoE密码: " pppoe_pass
            echo
            [ -z "$pppoe_pass" ] && {
                echo -e "${RED}错误: 密码不能为空！${NC}"
                return 1
            }
            
            uci set network.wan=interface
            uci set network.wan.ifname="$wan_iface"
            uci set network.wan.proto="pppoe"
            uci set network.wan.username="$pppoe_user"
            uci set network.wan.password="$pppoe_pass"
            uci set network.wan.ipv6="auto"
            
            log "配置PPPoE WAN接口: $wan_iface"
            ;;
            
        "dhcp")
            uci set network.wan=interface
            uci set network.wan.ifname="$wan_iface"
            uci set network.wan.proto="dhcp"
            uci set network.wan.ipv6="auto"
            
            log "配置DHCP WAN接口: $wan_iface"
            ;;
            
        "static")
            while true; do
                read -p "输入静态IP地址 (如192.168.1.100): " static_ip
                validate_ip "$static_ip" && break
                echo -e "${RED}错误: 无效的IP地址格式！${NC}"
            done
            
            while true; do
                read -p "输入子网掩码 (如255.255.255.0): " static_mask
                validate_netmask "$static_mask" && break
                echo -e "${RED}错误: 无效的子网掩码格式！${NC}"
            done
            
            read -p "输入网关地址: " static_gw
            read -p "输入DNS服务器: " static_dns
            
            uci set network.wan=interface
            uci set network.wan.ifname="$wan_iface"
            uci set network.wan.proto="static"
            uci set network.wan.ipaddr="$static_ip"
            uci set network.wan.netmask="$static_mask"
            [ -n "$static_gw" ] && uci set network.wan.gateway="$static_gw"
            [ -n "$static_dns" ] && uci set network.wan.dns="$static_dns"
            
            log "配置静态WAN接口: $wan_iface IP=$static_ip"
            ;;
    esac
    
    # 防火墙配置
    uci set firewall.@zone[1].network='wan'
    uci commit firewall
    
    echo -e "${GREEN}WAN接口配置完成！${NC}"
    return 0
}

# LAN接口配置
configure_lan() {
    echo -e "\n${YELLOW}=== 配置LAN接口 ===${NC}"
    
    # 接口选择
    if ! select_interfaces "请选择LAN接口 (可多选)" "multi"; then
        return 1
    fi
    local lan_ifaces=$SELECTED_RESULT
    
    # IP地址设置
    while true; do
        read -p "输入LAN IP地址 (如192.168.1.1): " lan_ip
        validate_ip "$lan_ip" && break
        echo -e "${RED}错误: 无效的IP地址格式！${NC}"
    done
    
    # 基本LAN配置
    uci set network.lan=interface
    uci set network.lan.proto='static'
    uci set network.lan.ipaddr="$lan_ip"
    uci set network.lan.netmask='255.255.255.0'
    
    # 多接口桥接处理
    if [ $(echo "$lan_ifaces" | wc -w) -gt 1 ]; then
        uci set network.lan.type='bridge'
        for iface in $lan_ifaces; do
            uci add_list network.lan.ifname="$iface"
        done
        log "配置桥接LAN接口: $lan_ifaces"
    else
        uci set network.lan.ifname="$lan_ifaces"
        log "配置单一LAN接口: $lan_ifaces"
    fi
    
    # DHCP配置
    configure_dhcp "$lan_ip"
    
    echo -e "${GREEN}LAN接口配置完成！${NC}"
    return 0
}

# DHCP服务器配置
configure_dhcp() {
    local lan_ip=$1
    local dhcp_start=$(echo "$lan_ip" | cut -d'.' -f1-3).100
    local dhcp_end=$(echo "$lan_ip" | cut -d'.' -f1-3).200
    local dhcp_leasetime="12h"
    
    echo -e "\n${YELLOW}=== 配置DHCP服务器 ===${NC}"
    read -p "启用DHCP服务器? [Y/n]: " enable_dhcp
    enable_dhcp=${enable_dhcp:-y}
    
    if [ "$enable_dhcp" = "y" ] || [ "$enable_dhcp" = "Y" ]; then
        # 起始地址
        while true; do
            read -p "输入DHCP起始地址 [$dhcp_start]: " input_start
            [ -z "$input_start" ] && input_start=$dhcp_start
            validate_ip "$input_start" && break
            echo -e "${RED}错误: 无效的IP地址格式！${NC}"
        done
        
        # 结束地址
        while true; do
            read -p "输入DHCP结束地址 [$dhcp_end]: " input_end
            [ -z "$input_end" ] && input_end=$dhcp_end
            validate_ip "$input_end" && break
            echo -e "${RED}错误: 无效的IP地址格式！${NC}"
        done
        
        # 租约时间
        read -p "输入DHCP租约时间 [$dhcp_leasetime]: " input_leasetime
        input_leasetime=${input_leasetime:-$dhcp_leasetime}
        
        # 应用配置
        uci set dhcp.lan=dhcp
        uci set dhcp.lan.interface='lan'
        uci set dhcp.lan.start="$(echo $input_start | cut -d'.' -f4)"
        uci set dhcp.lan.limit="$(($(echo $input_end | cut -d'.' -f4)-$(echo $input_start | cut -d'.' -f4)+1))"
        uci set dhcp.lan.leasetime="$input_leasetime"
        
        echo -e "${GREEN}DHCP服务器已启用 (${input_start}-${input_end})${NC}"
        log "配置DHCP: ${input_start}-${input_end} leasetime=${input_leasetime}"
    else
        uci delete dhcp.lan >/dev/null 2>&1
        echo -e "${YELLOW}DHCP服务器已禁用${NC}"
        log "禁用DHCP服务器"
    fi
}

# VLAN配置
configure_vlan() {
    [ $VLAN_CAPABLE -eq 0 ] && {
        echo -e "${RED}错误: 当前设备不支持VLAN配置！${NC}"
        log "VLAN配置尝试失败: 设备不支持"
        return 1
    }
    
    echo -e "\n${YELLOW}=== 配置VLAN ===${NC}"
    echo -e "当前VLAN配置:"
    swconfig dev switch0 show | grep -E 'vid|ports'
    
    # VLAN操作选择
    echo -e "\n${GREEN}选择操作:${NC}"
    echo "1) 创建新VLAN"
    echo "2) 删除现有VLAN"
    echo "3) 返回"
    
    while true; do
        read -p "请输入选择 [1-3]: " choice
        case $choice in
            1) create_vlan; break ;;
            2) delete_vlan; break ;;
            3) return ;;
            *) echo -e "${RED}无效选择，请重新输入！${NC}" ;;
        esac
    done
    
    return 0
}

# 创建VLAN
create_vlan() {
    # VLAN ID输入
    while true; do
        read -p "输入VLAN ID (2-4094): " vlan_id
        if [[ "$vlan_id" =~ ^[0-9]+$ ]] && [ "$vlan_id" -ge 2 ] && [ "$vlan_id" -le 4094 ]; then
            # 检查是否已存在
            swconfig dev switch0 show | grep -q "vid: $vlan_id" && {
                echo -e "${RED}错误: VLAN $vlan_id 已存在！${NC}"
                continue
            }
            break
        fi
        echo -e "${RED}错误: VLAN ID必须是2-4094之间的数字！${NC}"
    done
    
    # 接口选择
    if ! select_interfaces "请选择属于此VLAN的接口 (可多选)" "multi"; then
        return 1
    fi
    local vlan_members=$SELECTED_RESULT
    
    # 标记端口
    local tagged_ports=""
    for iface in $vlan_members; do
        port=${iface#eth}
        tagged_ports="$tagged_ports ${port}t"
    done
    
    # 配置交换机VLAN
    uci set network.vlan$vlan_id=switch_vlan
    uci set network.vlan$vlan_id.device='switch0'
    uci set network.vlan$vlan_id.vlan='$vlan_id'
    uci set network.vlan$vlan_id.ports="$tagged_ports"
    
    # 配置VLAN接口
    uci set network.vlan$vlan_id=interface
    uci set network.vlan$vlan_id.ifname="eth0.$vlan_id"
    uci set network.vlan$vlan_id.proto='static'
    
    # IP地址设置
    read -p "是否为此VLAN配置IP地址? [y/N]: " config_ip
    if [ "$config_ip" = "y" ] || [ "$config_ip" = "Y" ]; then
        while true; do
            read -p "输入VLAN $vlan_id IP地址: " vlan_ip
            validate_ip "$vlan_ip" && break
            echo -e "${RED}错误: 无效的IP地址格式！${NC}"
        done
        
        uci set network.vlan$vlan_id.ipaddr="$vlan_ip"
        uci set network.vlan$vlan_id.netmask='255.255.255.0'
    fi
    
    echo -e "${GREEN}VLAN $vlan_id 创建成功！${NC}"
    log "创建VLAN: id=$vlan_id 成员=$vlan_members IP=${vlan_ip:-未配置}"
}

# 删除VLAN
delete_vlan() {
    # 获取现有VLAN列表
    local existing_vlans=$(swconfig dev switch0 show | grep 'vid:' | awk '{print $2}')
    [ -z "$existing_vlans" ] && {
        echo -e "${YELLOW}没有可删除的VLAN配置！${NC}"
        return
    }
    
    echo -e "\n${GREEN}现有VLAN列表:${NC}"
    for vlan in $existing_vlans; do
        ports=$(swconfig dev switch0 show | grep "vid: $vlan" | awk -F'ports: ' '{print $2}')
        echo "VLAN $vlan: 端口 $ports"
    done
    
    # 选择要删除的VLAN
    while true; do
        read -p "输入要删除的VLAN ID: " del_vlan
        if echo "$existing_vlans" | grep -q "$del_vlan"; then
            break
        fi
        echo -e "${RED}错误: 无效的VLAN ID！${NC}"
    done
    
    # 确认删除
    read -p "确认删除VLAN $del_vlan? 此操作不可恢复！ [y/N]: " confirm
    [ "$confirm" = "y" ] || [ "$confirm" = "Y" ] || {
        echo -e "${YELLOW}已取消删除操作${NC}"
        return
    }
    
    # 执行删除
    uci delete network.vlan$del_vlan >/dev/null 2>&1
    uci delete network.@switch_vlan[$(uci show network | grep -n "vlan='$del_vlan'" | cut -d':' -f1)] >/dev/null 2>&1
    
    echo -e "${GREEN}VLAN $del_vlan 已删除！${NC}"
    log "删除VLAN: id=$del_vlan"
}

# 备份配置
backup_config() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_name="config_$timestamp"
    
    mkdir -p "$BACKUP_DIR/$backup_name"
    
    # 备份关键配置文件
    cp $CONFIG_DIR/network "$BACKUP_DIR/$backup_name/network"
    cp $CONFIG_DIR/firewall "$BACKUP_DIR/$backup_name/firewall"
    cp $CONFIG_DIR/dhcp "$BACKUP_DIR/$backup_name/dhcp"
    
    # 备份VLAN配置
    [ $VLAN_CAPABLE -eq 1 ] && {
        swconfig dev switch0 show > "$BACKUP_DIR/$backup_name/vlan_config"
    }
    
    # 创建恢复脚本
    cat > "$BACKUP_DIR/$backup_name/restore.sh" <<EOF
#!/bin/sh
# 自动生成的恢复脚本
cp network $CONFIG_DIR/
cp firewall $CONFIG_DIR/
cp dhcp $CONFIG_DIR/
/etc/init.d/network restart
/etc/init.d/firewall restart >/dev/null 2>&1
/etc/init.d/dnsmasq restart >/dev/null 2>&1
echo "配置已从备份 $backup_name 恢复！"
EOF
    chmod +x "$BACKUP_DIR/$backup_name/restore.sh"
    
    echo -e "${GREEN}配置已备份到: ${BACKUP_DIR}/${backup_name}${NC}"
    log "创建配置备份: $backup_name"
}

# 恢复配置
restore_config() {
    local backups=$(ls -d $BACKUP_DIR/config_* 2>/dev/null | sort -r)
    [ -z "$backups" ] && {
        echo -e "${RED}错误: 找不到任何备份配置！${NC}"
        log "恢复失败: 无备份文件"
        return 1
    }
    
    echo -e "\n${YELLOW}=== 恢复配置 ===${NC}"
    echo -e "${GREEN}可用的备份:${NC}"
    
    local i=1
    local backup_list=""
    for backup in $backups; do
        backup_name=$(basename $backup)
        backup_date=$(echo $backup_name | cut -d'_' -f2- | sed 's/$$....$$$$..$$$$..$$_$$..$$$$..$$$$..$$/\1-\2-\3 \4:\5:\6/')
        echo "$i) $backup_name (${backup_date})"
        backup_list="$backup_list $backup"
        i=$((i+1))
    done
    
    # 选择备份
    while true; do
        read -p "选择要恢复的备份 (1-$((i-1))): " choice
        if [ "$choice" -ge 1 ] && [ "$choice" -lt $i ] 2>/dev/null; then
            selected_backup=$(echo $backup_list | cut -d' ' -f$choice)
            break
        fi
        echo -e "${RED}错误: 无效的选择！${NC}"
    done
    
    # 确认恢复
    read -p "确认从 ${selected_backup} 恢复配置? [y/N]: " confirm
    [ "$confirm" = "y" ] || [ "$confirm" = "Y" ] || {
        echo -e "${YELLOW}已取消恢复操作${NC}"
        return
    }
    
    # 执行恢复
    cp "$selected_backup/network" $CONFIG_DIR/
    cp "$selected_backup/firewall" $CONFIG_DIR/
    cp "$selected_backup/dhcp" $CONFIG_DIR/
    
    /etc/init.d/network restart
    /etc/init.d/firewall restart >/dev/null 2>&1
    /etc/init.d/dnsmasq restart >/dev/null 2>&1
    
    echo -e "${GREEN}配置已从 ${selected_backup} 成功恢复！${NC}"
    log "恢复配置从: $(basename $selected_backup)"
}

# 应用配置
apply_configuration() {
    echo -e "\n${YELLOW}=== 应用配置 ===${NC}"
    
    # 提交所有更改
    uci commit network
    uci commit firewall
    uci commit dhcp
    
    # 显示待应用的更改
    echo -e "${GREEN}以下配置将被应用:${NC}"
    uci changes
    
    # 确认应用
    read -p "确认应用以上所有配置? [y/N]: " confirm
    [ "$confirm" = "y" ] || [ "$confirm" = "Y" ] || {
        echo -e "${YELLOW}已取消应用配置${NC}"
        log "用户取消应用配置"
        return
    }
    
    # 执行应用
    echo -e "${BLUE}应用配置中，请稍候...${NC}"
    /etc/init.d/network restart
    /etc/init.d/firewall restart >/dev/null 2>&1
    /etc/init.d/dnsmasq restart >/dev/null 2>&1
    
    echo -e "${GREEN}所有配置已成功应用！${NC}"
    log "配置已应用并生效"
}

# 显示主菜单
show_main_menu() {
    clear
    echo -e "${YELLOW}=============================================${NC}"
    echo -e " OpenWRT 多网口高级配置工具 ${GREEN}v${VERSION}${NC}"
    echo -e "${YELLOW}=============================================${NC}"
    echo -e "${GREEN} 1. 显示当前网络配置${NC}"
    echo -e "${GREEN} 2. 配置WAN接口${NC}"
    echo -e "${GREEN} 3. 配置LAN接口${NC}"
    echo -e "${GREEN} 4. 配置VLAN${NC}"
    echo -e "${GREEN} 5. 备份当前配置${NC}"
    echo -e "${GREEN} 6. 恢复备份配置${NC}"
    echo -e "${GREEN} 7. 应用所有配置${NC}"
    echo -e "${GREEN} 8. 退出${NC}"
    echo -e "${YELLOW}=============================================${NC}"
}

# 主循环
main_loop() {
    while true; do
        show_main_menu
        
        read -p "请输入操作选项 [1-8]: " option
        case $option in
            1) show_current_config ;;
            2) configure_wan ;;
            3) configure_lan ;;
            4) configure_vlan ;;
            5) backup_config ;;
            6) restore_config ;;
            7) apply_configuration ;;
            8) 
                echo -e "${GREEN}感谢使用，再见！${NC}"
                log "脚本正常退出"
                exit 0
                ;;
            *) 
                echo -e "${RED}错误: 无效的选项！${NC}"
                sleep 1
                ;;
        esac
        
        echo
        read -p "按回车键返回主菜单..."
    done
}

# 主程序
init_check
get_system_info
detect_interfaces
main_loop
