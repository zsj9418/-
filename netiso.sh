#!/bin/sh
# ============================================================================
# OpenWrt VLAN / Multi-SSID / Network Isolation Interactive Setup Script
# Version: 2.0
# Description: 交互式配置 VLAN、多SSID、网络隔离
# Compatibility: OpenWrt 19.07 / 21.02 / 22.03 / 23.05 / 24.10+
# ============================================================================

# ========================== 全局变量 ==========================
SCRIPT_VERSION="2.0"
BACKUP_DIR="/tmp/netiso_backup_$(date +%Y%m%d_%H%M%S)"
LOG_FILE="/tmp/netiso_setup.log"
DSA_MODE=0          # 0=swconfig, 1=DSA
OPENWRT_VERSION=""
OPENWRT_MAJOR=0
OPENWRT_MINOR=0
WIFI_DEVICES=""
WIFI_COUNT=0
LAN_DEVICE=""
WAN_DEVICE=""
BRIDGE_NAME="br-lan"
HAS_SWITCH=0
SWITCH_NAME=""
CPU_PORT=""

# 预定义网络方案
ZONE_MAIN_SUBNET="192.168.1"
ZONE_GUEST_SUBNET="192.168.10"
ZONE_IOT_SUBNET="192.168.20"
ZONE_LAB_SUBNET="192.168.30"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# ========================== 工具函数 ==========================

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

print_banner() {
    clear
    printf "${CYAN}"
    cat << 'BANNER'
  ╔══════════════════════════════════════════════════════════════╗
  ║        OpenWrt VLAN / Multi-SSID / 网络隔离配置工具        ║
  ║                                                              ║
  ║   功能: VLAN划分 | 多SSID | 防火墙区域 | 网络隔离          ║
  ╚══════════════════════════════════════════════════════════════╝
BANNER
    printf "${NC}"
    printf "  ${MAGENTA}脚本版本: %s${NC}\n\n" "$SCRIPT_VERSION"
}

print_line() {
    printf "${BLUE}  ──────────────────────────────────────────────────────────${NC}\n"
}

print_section() {
    printf "\n${BOLD}${GREEN}  ▶ %s${NC}\n" "$1"
    print_line
}

print_info() {
    printf "  ${BLUE}[INFO]${NC} %s\n" "$1"
}

print_ok() {
    printf "  ${GREEN}[  OK]${NC} %s\n" "$1"
}

print_warn() {
    printf "  ${YELLOW}[WARN]${NC} %s\n" "$1"
}

print_err() {
    printf "  ${RED}[FAIL]${NC} %s\n" "$1"
}

print_step() {
    printf "  ${CYAN}[STEP]${NC} %s\n" "$1"
}

confirm() {
    local prompt="${1:-确认操作?}"
    local default="${2:-n}"
    local yn_hint
    if [ "$default" = "y" ]; then
        yn_hint="[Y/n]"
    else
        yn_hint="[y/N]"
    fi
    printf "\n  ${YELLOW}⚠ %s %s: ${NC}" "$prompt" "$yn_hint"
    read -r answer
    answer=$(echo "$answer" | tr 'A-Z' 'a-z')
    [ -z "$answer" ] && answer="$default"
    [ "$answer" = "y" ] || [ "$answer" = "yes" ]
}

press_enter() {
    printf "\n  ${CYAN}按 Enter 键继续...${NC}"
    read -r _
}

validate_subnet() {
    echo "$1" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'
}

validate_vlan_id() {
    [ "$1" -ge 2 ] 2>/dev/null && [ "$1" -le 4094 ] 2>/dev/null
}

# ========================== 系统检测 ==========================

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        print_err "此脚本需要 root 权限运行"
        exit 1
    fi
}

detect_openwrt_version() {
    print_step "检测 OpenWrt 版本..."

    if [ -f /etc/openwrt_release ]; then
        . /etc/openwrt_release
        OPENWRT_VERSION="$DISTRIB_RELEASE"
        local desc="$DISTRIB_DESCRIPTION"
    elif [ -f /etc/os-release ]; then
        . /etc/os-release
        OPENWRT_VERSION="$VERSION_ID"
        local desc="$PRETTY_NAME"
    fi

    if [ -z "$OPENWRT_VERSION" ]; then
        # 尝试从 banner 获取
        if [ -f /etc/banner ]; then
            OPENWRT_VERSION=$(grep -oE '[0-9]+\.[0-9]+' /etc/banner | head -1)
        fi
    fi

    if [ -z "$OPENWRT_VERSION" ]; then
        print_warn "无法检测 OpenWrt 版本，将尝试自动判断模式"
        OPENWRT_VERSION="unknown"
        OPENWRT_MAJOR=0
        OPENWRT_MINOR=0
    else
        OPENWRT_MAJOR=$(echo "$OPENWRT_VERSION" | cut -d'.' -f1)
        OPENWRT_MINOR=$(echo "$OPENWRT_VERSION" | cut -d'.' -f2)
        # 处理 SNAPSHOT
        if echo "$OPENWRT_VERSION" | grep -qi "snapshot"; then
            OPENWRT_MAJOR=99
            OPENWRT_MINOR=0
        fi
    fi

    print_ok "OpenWrt 版本: $OPENWRT_VERSION"
    log "OpenWrt version: $OPENWRT_VERSION (major=$OPENWRT_MAJOR, minor=$OPENWRT_MINOR)"
}

detect_network_mode() {
    print_step "检测网络架构模式 (DSA / swconfig)..."

    # 方法1: 检查 /sys/class/net 中是否有 DSA 特征
    if [ -d /sys/class/net ] && ls /sys/class/net/*/dsa 2>/dev/null | grep -q dsa; then
        DSA_MODE=1
        print_ok "检测到 DSA 模式 (通过 sysfs)"
        log "Network mode: DSA (sysfs)"
        return
    fi

    # 方法2: 检查 bridge vlan 支持
    if command -v bridge >/dev/null 2>&1 && bridge vlan show 2>/dev/null | grep -q .; then
        DSA_MODE=1
        print_ok "检测到 DSA 模式 (通过 bridge vlan)"
        log "Network mode: DSA (bridge vlan)"
        return
    fi

    # 方法3: 检查 uci 中是否有 swconfig 配置
    if uci show network 2>/dev/null | grep -q "network.@switch\["; then
        DSA_MODE=0
        HAS_SWITCH=1
        SWITCH_NAME=$(uci -q get network.@switch[0].name)
        CPU_PORT=$(uci -q get network.@switch_vlan[0].ports | grep -oE '[0-9]+t' | head -1 | tr -d 't')
        [ -z "$CPU_PORT" ] && CPU_PORT="0"
        print_ok "检测到 swconfig 模式 (交换机: $SWITCH_NAME, CPU端口: $CPU_PORT)"
        log "Network mode: swconfig (switch=$SWITCH_NAME, cpu_port=$CPU_PORT)"
        return
    fi

    # 方法4: 检查内核中是否有 DSA 标志
    if [ -d /sys/kernel/debug/dsa ] 2>/dev/null; then
        DSA_MODE=1
        print_ok "检测到 DSA 模式 (通过 debugfs)"
        log "Network mode: DSA (debugfs)"
        return
    fi

    # 方法5: 根据版本推断
    if [ "$OPENWRT_MAJOR" -ge 22 ] || [ "$OPENWRT_MAJOR" -eq 99 ]; then
        DSA_MODE=1
        print_ok "根据版本推断为 DSA 模式 (>= 22.x)"
    elif [ "$OPENWRT_MAJOR" -ge 21 ]; then
        # 21.02 混合期，部分设备 DSA 部分 swconfig
        if ip link show 2>/dev/null | grep -qE 'lan[0-9]|eth[0-9]\.' ; then
            DSA_MODE=1
            print_ok "检测到 DSA 模式 (21.x 系列)"
        else
            DSA_MODE=0
            print_ok "检测到 swconfig 模式 (21.x 系列)"
        fi
    else
        DSA_MODE=0
        print_ok "根据版本推断为 swconfig 模式 (< 21.x)"
    fi
    log "Network mode: $([ $DSA_MODE -eq 1 ] && echo 'DSA' || echo 'swconfig') (inferred)"
}

detect_network_devices() {
    print_step "检测网络设备..."

    # 检测 LAN 桥接设备
    LAN_DEVICE=$(uci -q get network.lan.device)
    if [ -z "$LAN_DEVICE" ]; then
        LAN_DEVICE=$(uci -q get network.lan.ifname)
    fi
    [ -z "$LAN_DEVICE" ] && LAN_DEVICE="br-lan"
    BRIDGE_NAME="$LAN_DEVICE"

    # 检测 WAN 设备
    WAN_DEVICE=$(uci -q get network.wan.device)
    if [ -z "$WAN_DEVICE" ]; then
        WAN_DEVICE=$(uci -q get network.wan.ifname)
    fi
    [ -z "$WAN_DEVICE" ] && WAN_DEVICE="eth1"

    print_ok "LAN 设备: $LAN_DEVICE"
    print_ok "WAN 设备: $WAN_DEVICE"

    # 检测物理以太网口 (DSA 模式)
    if [ $DSA_MODE -eq 1 ]; then
        local eth_ports=""
        for dev in /sys/class/net/lan* /sys/class/net/eth*; do
            [ -e "$dev" ] || continue
            local devname=$(basename "$dev")
            # 排除 WAN 口和桥接口
            [ "$devname" = "$WAN_DEVICE" ] && continue
            echo "$devname" | grep -q "^br-" && continue
            eth_ports="$eth_ports $devname"
        done
        if [ -n "$eth_ports" ]; then
            print_ok "检测到物理端口:$eth_ports"
        fi
    fi

    log "LAN device: $LAN_DEVICE, WAN device: $WAN_DEVICE"
}

detect_wifi() {
    print_step "检测无线网卡..."

    WIFI_DEVICES=""
    WIFI_COUNT=0

    local idx=0
    while true; do
        local radio=$(uci -q get wireless.radio${idx}.type)
        if [ -z "$radio" ]; then
            # 也检查 phy 设备
            if [ ! -e "/sys/class/ieee80211/phy${idx}" ]; then
                break
            fi
            radio="detected"
        fi

        local band=$(uci -q get wireless.radio${idx}.band)
        local channel=$(uci -q get wireless.radio${idx}.channel)
        local htmode=$(uci -q get wireless.radio${idx}.htmode)
        local hwmode=$(uci -q get wireless.radio${idx}.hwmode)
        local disabled=$(uci -q get wireless.radio${idx}.disabled)

        # 推断频段
        if [ -z "$band" ]; then
            if [ -n "$hwmode" ]; then
                case "$hwmode" in
                    *a*) band="5g" ;;
                    *g*|*b*) band="2g" ;;
                esac
            elif [ -n "$channel" ]; then
                if [ "$channel" -ge 36 ] 2>/dev/null; then
                    band="5g"
                else
                    band="2g"
                fi
            fi
        fi
        [ -z "$band" ] && band="unknown"

        local status="启用"
        [ "$disabled" = "1" ] && status="已禁用"

        WIFI_DEVICES="$WIFI_DEVICES radio${idx}"
        WIFI_COUNT=$((WIFI_COUNT + 1))

        printf "  ${GREEN}[  OK]${NC} radio%-2d | 频段: %-4s | 信道: %-4s | 模式: %-8s | %s\n" \
            "$idx" "$band" "${channel:-auto}" "${htmode:-$hwmode}" "$status"

        idx=$((idx + 1))
    done

    if [ $WIFI_COUNT -eq 0 ]; then
        print_warn "未检测到无线网卡 (仅支持有线 VLAN 配置)"
    else
        print_ok "共检测到 $WIFI_COUNT 个无线网卡"
    fi

    log "WiFi devices: $WIFI_DEVICES (count=$WIFI_COUNT)"
}

detect_existing_config() {
    print_step "检测现有网络配置..."

    # 列出现有接口
    local interfaces=$(uci show network 2>/dev/null | grep '=interface' | cut -d'.' -f2 | cut -d'=' -f1 | sort -u)
    print_info "现有网络接口: $(echo $interfaces | tr '\n' ' ')"

    # 列出现有 SSID
    local ssid_count=0
    local idx=0
    while true; do
        local ssid=$(uci -q get wireless.@wifi-iface[$idx].ssid)
        [ -z "$ssid" ] && break
        local net=$(uci -q get wireless.@wifi-iface[$idx].network)
        local mode=$(uci -q get wireless.@wifi-iface[$idx].mode)
        printf "    SSID: %-24s 网络: %-10s 模式: %s\n" "$ssid" "${net:-N/A}" "${mode:-ap}"
        ssid_count=$((ssid_count + 1))
        idx=$((idx + 1))
    done
    [ $ssid_count -eq 0 ] && print_info "未发现已配置的 SSID"

    # 列出防火墙区域
    local zone_idx=0
    local zones=""
    while true; do
        local zname=$(uci -q get firewall.@zone[$zone_idx].name)
        [ -z "$zname" ] && break
        zones="$zones $zname"
        zone_idx=$((zone_idx + 1))
    done
    [ -n "$zones" ] && print_info "现有防火墙区域:$zones"
}

# ========================== 依赖检查 ==========================

check_and_install_deps() {
    print_section "检查并安装依赖"

    local need_update=0
    local missing_pkgs=""

    # 基础依赖
    local deps="ip-full kmod-vlan-8021q firewall4 nftables"

    # swconfig 模式需要 swconfig 工具
    if [ $DSA_MODE -eq 0 ] && [ $HAS_SWITCH -eq 1 ]; then
        deps="$deps swconfig"
    fi

    # DSA 模式需要 bridge 工具
    if [ $DSA_MODE -eq 1 ]; then
        deps="$deps bridge ip-bridge"
    fi

    # 旧版本使用 firewall (iptables)
    if [ "$OPENWRT_MAJOR" -lt 22 ] && [ "$OPENWRT_MAJOR" -ne 99 ]; then
        deps="firewall iptables kmod-ipt-nat ip-full kmod-vlan-8021q"
        if [ $DSA_MODE -eq 0 ] && [ $HAS_SWITCH -eq 1 ]; then
            deps="$deps swconfig"
        fi
    fi

    for pkg in $deps; do
        if opkg list-installed 2>/dev/null | grep -q "^${pkg} "; then
            print_ok "$pkg 已安装"
        else
            # 有些包可能以不同名字存在
            local alt_installed=0
            case "$pkg" in
                ip-full)
                    opkg list-installed 2>/dev/null | grep -q "^ip-tiny " && alt_installed=1
                    command -v ip >/dev/null 2>&1 && alt_installed=1
                    ;;
                ip-bridge)
                    command -v bridge >/dev/null 2>&1 && alt_installed=1
                    ;;
                firewall4)
                    opkg list-installed 2>/dev/null | grep -q "^firewall " && alt_installed=1
                    ;;
                nftables)
                    command -v nft >/dev/null 2>&1 && alt_installed=1
                    ;;
            esac

            if [ $alt_installed -eq 1 ]; then
                print_ok "$pkg (替代包已就绪)"
            else
                print_warn "$pkg 未安装"
                missing_pkgs="$missing_pkgs $pkg"
                need_update=1
            fi
        fi
    done

    if [ $need_update -eq 1 ] && [ -n "$missing_pkgs" ]; then
        print_warn "缺少以下包:$missing_pkgs"
        if confirm "是否自动安装缺少的依赖包?"; then
            print_step "更新软件包列表..."
            opkg update >> "$LOG_FILE" 2>&1
            for pkg in $missing_pkgs; do
                print_step "安装 $pkg ..."
                if opkg install "$pkg" >> "$LOG_FILE" 2>&1; then
                    print_ok "$pkg 安装成功"
                else
                    print_warn "$pkg 安装失败 (可能不影响核心功能)"
                fi
            done
        else
            print_warn "跳过依赖安装，部分功能可能不可用"
        fi
    else
        print_ok "所有依赖已满足"
    fi
}

# ========================== 备份与恢复 ==========================

backup_config() {
    print_step "备份当前配置到 $BACKUP_DIR ..."
    mkdir -p "$BACKUP_DIR"

    for f in /etc/config/network /etc/config/wireless /etc/config/firewall /etc/config/dhcp; do
        if [ -f "$f" ]; then
            cp "$f" "$BACKUP_DIR/"
            log "Backed up $f"
        fi
    done

    # 也保存当前运行状态
    ip addr show > "$BACKUP_DIR/ip_addr.txt" 2>&1
    ip route show > "$BACKUP_DIR/ip_route.txt" 2>&1
    [ $DSA_MODE -eq 1 ] && bridge vlan show > "$BACKUP_DIR/bridge_vlan.txt" 2>&1

    print_ok "配置已备份到: $BACKUP_DIR"
    log "Backup completed: $BACKUP_DIR"
}

restore_config() {
    print_section "恢复配置"

    # 列出所有备份
    local backups=$(ls -d /tmp/netiso_backup_* 2>/dev/null | sort -r)
    if [ -z "$backups" ]; then
        print_err "未找到任何备份"
        press_enter
        return 1
    fi

    printf "\n  可用备份:\n"
    local i=1
    for bdir in $backups; do
        local bname=$(basename "$bdir")
        local btime=$(echo "$bname" | sed 's/netiso_backup_//' | sed 's/_/ /')
        printf "    ${CYAN}%d${NC}. %s\n" "$i" "$btime"
        i=$((i + 1))
    done

    printf "\n  请选择要恢复的备份编号 [1]: "
    read -r choice
    [ -z "$choice" ] && choice=1

    local selected=$(echo "$backups" | sed -n "${choice}p")
    if [ -z "$selected" ] || [ ! -d "$selected" ]; then
        print_err "无效选择"
        press_enter
        return 1
    fi

    if confirm "确认从 $(basename $selected) 恢复配置? 当前配置将被覆盖"; then
        for f in network wireless firewall dhcp; do
            if [ -f "$selected/$f" ]; then
                cp "$selected/$f" "/etc/config/$f"
                print_ok "已恢复 /etc/config/$f"
            fi
        done

        print_step "重启网络服务..."
        /etc/init.d/network restart >> "$LOG_FILE" 2>&1
        /etc/init.d/firewall restart >> "$LOG_FILE" 2>&1
        [ -x /etc/init.d/dnsmasq ] && /etc/init.d/dnsmasq restart >> "$LOG_FILE" 2>&1
        print_ok "配置恢复完成"
    fi

    press_enter
}

# ========================== 核心配置函数 ==========================

# --- 创建 VLAN 设备 ---
create_vlan_device() {
    local base_dev="$1"
    local vlan_id="$2"
    local vlan_dev="${base_dev}.${vlan_id}"

    if [ $DSA_MODE -eq 1 ]; then
        # DSA 模式: 在 bridge 上创建 VLAN filtering 或者在物理口上创建 802.1q
        # 检查 base_dev 是否是桥接
        if echo "$base_dev" | grep -q "^br-"; then
            # 使用 bridge VLAN
            uci -q batch <<EOF
set network.${base_dev//-/_}_vlan${vlan_id}=bridge-vlan
set network.${base_dev//-/_}_vlan${vlan_id}.device='$base_dev'
set network.${base_dev//-/_}_vlan${vlan_id}.vlan='$vlan_id'
EOF
            # 添加端口
            local ports=$(uci -q get network.@device[0].ports 2>/dev/null)
            if [ -n "$ports" ]; then
                for port in $ports; do
                    uci add_list "network.${base_dev//-/_}_vlan${vlan_id}.ports=${port}:t"
                done
            fi
            vlan_dev="${base_dev}.${vlan_id}"
        else
            # 物理口上的 802.1q VLAN
            uci -q batch <<EOF
set network.vlan${vlan_id}_dev=device
set network.vlan${vlan_id}_dev.type='8021q'
set network.vlan${vlan_id}_dev.ifname='$base_dev'
set network.vlan${vlan_id}_dev.vid='$vlan_id'
set network.vlan${vlan_id}_dev.name='$vlan_dev'
EOF
        fi
    else
        # swconfig 模式
        if [ $HAS_SWITCH -eq 1 ]; then
            # 通过 switch_vlan 创建
            local vlan_idx
            vlan_idx=$(uci show network 2>/dev/null | grep '=switch_vlan' | wc -l)

            uci -q batch <<EOF
add network switch_vlan
set network.@switch_vlan[-1].device='$SWITCH_NAME'
set network.@switch_vlan[-1].vlan='$vlan_id'
set network.@switch_vlan[-1].ports='${CPU_PORT}t'
EOF
            vlan_dev="${base_dev}.${vlan_id}"
        else
            # 没有硬件交换机，纯 802.1q
            uci -q batch <<EOF
set network.vlan${vlan_id}_dev=device
set network.vlan${vlan_id}_dev.type='8021q'
set network.vlan${vlan_id}_dev.ifname='$base_dev'
set network.vlan${vlan_id}_dev.vid='$vlan_id'
set network.vlan${vlan_id}_dev.name='$vlan_dev'
EOF
        fi
    fi

    echo "$vlan_dev"
    log "Created VLAN device: $vlan_dev (base=$base_dev, vid=$vlan_id, dsa=$DSA_MODE)"
}

# --- 创建网络接口 ---
create_interface() {
    local iface_name="$1"
    local subnet="$2"
    local vlan_id="$3"
    local device="$4"

    print_step "创建接口: $iface_name (${subnet}.0/24, VLAN $vlan_id)"

    # 如果需要 VLAN，先创建设备
    local iface_dev="$device"
    if [ -n "$vlan_id" ] && [ "$vlan_id" != "0" ]; then
        # 判断是否需要独立的桥接
        local bridge_name="br-${iface_name}"

        if [ $DSA_MODE -eq 1 ]; then
            # DSA: 创建独立桥接设备用于此接口
            uci -q batch <<EOF
set network.br_${iface_name}=device
set network.br_${iface_name}.type='bridge'
set network.br_${iface_name}.name='$bridge_name'
EOF
            iface_dev="$bridge_name"
        else
            # swconfig: 直接使用 VLAN 子接口
            local base_eth=$(uci -q get network.lan.ifname | cut -d' ' -f1)
            [ -z "$base_eth" ] && base_eth="eth0"
            iface_dev="${base_eth}.${vlan_id}"

            # 确保 switch_vlan 存在
            if [ $HAS_SWITCH -eq 1 ]; then
                local vlan_exists=0
                local sv_idx=0
                while true; do
                    local sv_vlan=$(uci -q get "network.@switch_vlan[$sv_idx].vlan")
                    [ -z "$sv_vlan" ] && break
                    [ "$sv_vlan" = "$vlan_id" ] && vlan_exists=1 && break
                    sv_idx=$((sv_idx + 1))
                done

                if [ $vlan_exists -eq 0 ]; then
                    uci -q batch <<EOF
add network switch_vlan
set network.@switch_vlan[-1].device='$SWITCH_NAME'
set network.@switch_vlan[-1].vlan='$vlan_id'
set network.@switch_vlan[-1].ports='${CPU_PORT}t'
EOF
                fi
            fi
        fi
    fi

    # 创建接口
    if [ $DSA_MODE -eq 1 ] || [ "$OPENWRT_MAJOR" -ge 21 ]; then
        # 新版本使用 device
        uci -q batch <<EOF
set network.${iface_name}=interface
set network.${iface_name}.proto='static'
set network.${iface_name}.device='$iface_dev'
set network.${iface_name}.ipaddr='${subnet}.1'
set network.${iface_name}.netmask='255.255.255.0'
EOF
    else
        # 旧版本使用 ifname
        uci -q batch <<EOF
set network.${iface_name}=interface
set network.${iface_name}.proto='static'
set network.${iface_name}.ifname='$iface_dev'
set network.${iface_name}.ipaddr='${subnet}.1'
set network.${iface_name}.netmask='255.255.255.0'
set network.${iface_name}.type='bridge'
EOF
    fi

    print_ok "接口 $iface_name 已创建 (IP: ${subnet}.1/24)"
    log "Created interface: $iface_name ($iface_dev, ${subnet}.0/24)"
}

# --- 配置 DHCP ---
configure_dhcp() {
    local iface_name="$1"
    local subnet="$2"
    local start="${3:-100}"
    local limit="${4:-150}"
    local leasetime="${5:-12h}"

    print_step "配置 DHCP: $iface_name (${subnet}.${start} - ${subnet}.$((start + limit - 1)))"

    uci -q batch <<EOF
set dhcp.${iface_name}=dhcp
set dhcp.${iface_name}.interface='${iface_name}'
set dhcp.${iface_name}.start='$start'
set dhcp.${iface_name}.limit='$limit'
set dhcp.${iface_name}.leasetime='$leasetime'
set dhcp.${iface_name}.dhcpv4='server'
set dhcp.${iface_name}.ra='server'
EOF

    # 为访客和IoT网络添加额外的DNS安全选项
    case "$iface_name" in
        guest*)
            # 访客网络: 设置 isolate 和 DNS
            uci -q set "dhcp.${iface_name}.dhcp_option=6,${subnet}.1"
            ;;
        iot*)
            # IoT 网络: 使用本地 DNS
            uci -q set "dhcp.${iface_name}.dhcp_option=6,${subnet}.1"
            ;;
    esac

    print_ok "DHCP 已配置"
    log "Configured DHCP for $iface_name"
}

# --- 创建防火墙区域 ---
create_firewall_zone() {
    local zone_name="$1"
    local iface_name="$2"
    local input="${3:-REJECT}"
    local output="${4:-ACCEPT}"
    local forward="${5:-REJECT}"
    local masq="${6:-0}"

    print_step "创建防火墙区域: $zone_name"

    # 检查区域是否已存在
    local zone_idx=0
    local zone_exists=-1
    while true; do
        local zn=$(uci -q get "firewall.@zone[$zone_idx].name")
        [ -z "$zn" ] && break
        if [ "$zn" = "$zone_name" ]; then
            zone_exists=$zone_idx
            break
        fi
        zone_idx=$((zone_idx + 1))
    done

    if [ $zone_exists -ge 0 ]; then
        print_warn "区域 $zone_name 已存在，将更新配置"
        uci -q batch <<EOF
set firewall.@zone[$zone_exists].input='$input'
set firewall.@zone[$zone_exists].output='$output'
set firewall.@zone[$zone_exists].forward='$forward'
set firewall.@zone[$zone_exists].masq='$masq'
EOF
        # 添加网络
        uci -q add_list "firewall.@zone[$zone_exists].network=$iface_name"
    else
        uci -q batch <<EOF
add firewall zone
set firewall.@zone[-1].name='$zone_name'
set firewall.@zone[-1].input='$input'
set firewall.@zone[-1].output='$output'
set firewall.@zone[-1].forward='$forward'
set firewall.@zone[-1].masq='$masq'
add_list firewall.@zone[-1].network='$iface_name'
EOF
    fi

    print_ok "防火墙区域 $zone_name 已配置"
    log "Created/updated firewall zone: $zone_name for $iface_name"
}

# --- 创建防火墙转发规则 ---
create_forwarding() {
    local src="$1"
    local dest="$2"

    # 检查是否已存在
    local fwd_idx=0
    while true; do
        local fs=$(uci -q get "firewall.@forwarding[$fwd_idx].src")
        [ -z "$fs" ] && break
        local fd=$(uci -q get "firewall.@forwarding[$fwd_idx].dest")
        if [ "$fs" = "$src" ] && [ "$fd" = "$dest" ]; then
            print_info "转发规则 $src -> $dest 已存在"
            return
        fi
        fwd_idx=$((fwd_idx + 1))
    done

    uci -q batch <<EOF
add firewall forwarding
set firewall.@forwarding[-1].src='$src'
set firewall.@forwarding[-1].dest='$dest'
EOF

    print_ok "转发: $src -> $dest"
    log "Created forwarding: $src -> $dest"
}

# --- 创建防火墙自定义规则 ---
create_firewall_rule() {
    local name="$1"
    local src="$2"
    local dest="$3"
    local target="$4"
    local proto="${5:-all}"
    local dest_port="$6"

    uci -q batch <<EOF
add firewall rule
set firewall.@rule[-1].name='$name'
set firewall.@rule[-1].src='$src'
set firewall.@rule[-1].dest='$dest'
set firewall.@rule[-1].target='$target'
set firewall.@rule[-1].proto='$proto'
EOF
    [ -n "$dest_port" ] && uci -q set "firewall.@rule[-1].dest_port=$dest_port"

    log "Created firewall rule: $name ($src->$dest, $target)"
}

# --- 创建 SSID ---
create_ssid() {
    local radio="$1"
    local ssid="$2"
    local network="$3"
    local encryption="${4:-psk2}"
    local key="$5"
    local isolate="${6:-0}"

    print_step "创建 SSID: $ssid (radio: $radio, 网络: $network)"

    local section_name="${network}_${radio}"

    uci -q batch <<EOF
set wireless.${section_name}=wifi-iface
set wireless.${section_name}.device='$radio'
set wireless.${section_name}.mode='ap'
set wireless.${section_name}.ssid='$ssid'
set wireless.${section_name}.network='$network'
set wireless.${section_name}.isolate='$isolate'
EOF

    if [ "$encryption" = "none" ]; then
        uci -q set "wireless.${section_name}.encryption=none"
    elif [ "$encryption" = "owe" ]; then
        uci -q batch <<EOF
set wireless.${section_name}.encryption='owe'
set wireless.${section_name}.ieee80211w='2'
EOF
    else
        uci -q batch <<EOF
set wireless.${section_name}.encryption='$encryption'
set wireless.${section_name}.key='$key'
EOF
    fi

    # 确保 radio 启用
    uci -q set "wireless.${radio}.disabled=0"

    print_ok "SSID '$ssid' 已创建"
    log "Created SSID: $ssid on $radio for network $network"
}

# ========================== 向导式配置 ==========================

wizard_guest_network() {
    print_section "访客网络配置向导"

    local vlan_id guest_subnet guest_ssid guest_key

    printf "\n  ${BOLD}访客网络将创建独立的WiFi和网段，访客只能上网，不能访问内网${NC}\n\n"

    # VLAN ID
    printf "  VLAN ID [10]: "
    read -r vlan_id
    [ -z "$vlan_id" ] && vlan_id=10
    if ! validate_vlan_id "$vlan_id"; then
        print_err "无效的 VLAN ID (2-4094)"
        press_enter
        return 1
    fi

    # 子网
    printf "  子网前缀 [192.168.10]: "
    read -r guest_subnet
    [ -z "$guest_subnet" ] && guest_subnet="192.168.10"
    if ! validate_subnet "$guest_subnet"; then
        print_err "无效的子网格式"
        press_enter
        return 1
    fi

    # SSID 名称
    local default_ssid="Guest_WiFi"
    printf "  SSID 名称 [%s]: " "$default_ssid"
    read -r guest_ssid
    [ -z "$guest_ssid" ] && guest_ssid="$default_ssid"

    # 加密方式
    printf "  加密方式:\n"
    printf "    1. WPA2-PSK (推荐)\n"
    printf "    2. WPA3-SAE\n"
    printf "    3. WPA2/WPA3 混合\n"
    printf "    4. 无加密 (开放)\n"
    printf "    5. OWE (增强型开放)\n"
    printf "  选择 [1]: "
    read -r enc_choice
    [ -z "$enc_choice" ] && enc_choice=1

    local encryption="psk2"
    case "$enc_choice" in
        1) encryption="psk2" ;;
        2) encryption="sae" ;;
        3) encryption="sae-mixed" ;;
        4) encryption="none" ;;
        5) encryption="owe" ;;
    esac

    # 密码
    if [ "$encryption" != "none" ] && [ "$encryption" != "owe" ]; then
        printf "  WiFi 密码 (至少8位): "
        read -r guest_key
        if [ -z "$guest_key" ] || [ ${#guest_key} -lt 8 ]; then
            print_err "密码长度至少8位"
            press_enter
            return 1
        fi
    fi

    # 限速 (可选)
    printf "  是否为访客网络设置带宽限制? [y/N]: "
    read -r do_limit
    local up_limit="" down_limit=""
    if [ "$do_limit" = "y" ] || [ "$do_limit" = "Y" ]; then
        printf "  上行限速 (kbps，如 2048 = 2Mbps) [2048]: "
        read -r up_limit
        [ -z "$up_limit" ] && up_limit="2048"
        printf "  下行限速 (kbps，如 10240 = 10Mbps) [10240]: "
        read -r down_limit
        [ -z "$down_limit" ] && down_limit="10240"
    fi

    print_line
    printf "\n  ${BOLD}配置摘要:${NC}\n"
    printf "  ├─ VLAN ID:   %s\n" "$vlan_id"
    printf "  ├─ 子网:      %s.0/24\n" "$guest_subnet"
    printf "  ├─ 网关:      %s.1\n" "$guest_subnet"
    printf "  ├─ SSID:      %s\n" "$guest_ssid"
    printf "  ├─ 加密:      %s\n" "$encryption"
    [ -n "$up_limit" ] && printf "  ├─ 上行限速:  %s kbps\n" "$up_limit"
    [ -n "$down_limit" ] && printf "  ├─ 下行限速:  %s kbps\n" "$down_limit"
    printf "  └─ 隔离策略:  仅允许上网，禁止访问内网\n"

    if ! confirm "确认创建访客网络?"; then
        return 0
    fi

    backup_config

    # 1. 创建接口
    create_interface "guest" "$guest_subnet" "$vlan_id" "$BRIDGE_NAME"

    # 2. 配置 DHCP
    configure_dhcp "guest" "$guest_subnet" 100 150 "2h"

    # 3. 创建防火墙区域
    create_firewall_zone "guest" "guest" "REJECT" "ACCEPT" "REJECT" "1"

    # 4. 允许 DHCP 和 DNS
    uci -q batch <<EOF
add firewall rule
set firewall.@rule[-1].name='Guest-DNS'
set firewall.@rule[-1].src='guest'
set firewall.@rule[-1].dest_port='53'
set firewall.@rule[-1].proto='tcp udp'
set firewall.@rule[-1].target='ACCEPT'

add firewall rule
set firewall.@rule[-1].name='Guest-DHCP'
set firewall.@rule[-1].src='guest'
set firewall.@rule[-1].dest_port='67-68'
set firewall.@rule[-1].proto='udp'
set firewall.@rule[-1].target='ACCEPT'
EOF

    # 5. 允许访客 -> WAN (上网)
    create_forwarding "guest" "wan"

    # 6. 创建 SSID
    if [ $WIFI_COUNT -gt 0 ]; then
        for radio in $WIFI_DEVICES; do
            create_ssid "$radio" "$guest_ssid" "guest" "$encryption" "$guest_key" "1"
        done
    fi

    # 7. 限速 (使用 SQM 或简单 tc)
    if [ -n "$up_limit" ] && [ -n "$down_limit" ]; then
        # 检查是否有 SQM
        if opkg list-installed 2>/dev/null | grep -q "^luci-app-sqm "; then
            print_info "检测到 SQM，建议通过 LuCI 配置 SQM 限速"
        else
            print_info "带宽限制已记录，可后续通过 SQM 或 tc 实现"
        fi
        log "Rate limit requested: up=${up_limit}kbps down=${down_limit}kbps"
    fi

    # 提交
    uci commit network
    uci commit wireless
    uci commit firewall
    uci commit dhcp

    print_ok "访客网络配置完成！"
    if confirm "是否立即应用配置? (网络将短暂中断)" "y"; then
        apply_config
    fi

    press_enter
}

wizard_iot_network() {
    print_section "IoT 设备网络配置向导"

    local vlan_id iot_subnet iot_ssid iot_key

    printf "\n  ${BOLD}IoT网络用于隔离智能家居设备，主网络可以访问IoT，反之不行${NC}\n\n"

    printf "  VLAN ID [20]: "
    read -r vlan_id
    [ -z "$vlan_id" ] && vlan_id=20
    if ! validate_vlan_id "$vlan_id"; then
        print_err "无效的 VLAN ID"
        press_enter
        return 1
    fi

    printf "  子网前缀 [192.168.20]: "
    read -r iot_subnet
    [ -z "$iot_subnet" ] && iot_subnet="192.168.20"

    local default_ssid="IoT_Devices"
    printf "  SSID 名称 [%s]: " "$default_ssid"
    read -r iot_ssid
    [ -z "$iot_ssid" ] && iot_ssid="$default_ssid"

    printf "  WiFi 密码 (至少8位): "
    read -r iot_key
    if [ -z "$iot_key" ] || [ ${#iot_key} -lt 8 ]; then
        print_err "密码长度至少8位"
        press_enter
        return 1
    fi

    # DNS 过滤选项
    printf "  是否为 IoT 设备启用 DNS 过滤 (阻止设备联网到未知服务器)? [y/N]: "
    read -r do_dns_filter
    local dns_filter=0
    [ "$do_dns_filter" = "y" ] || [ "$do_dns_filter" = "Y" ] && dns_filter=1

    print_line
    printf "\n  ${BOLD}配置摘要:${NC}\n"
    printf "  ├─ VLAN ID:   %s\n" "$vlan_id"
    printf "  ├─ 子网:      %s.0/24\n" "$iot_subnet"
    printf "  ├─ SSID:      %s\n" "$iot_ssid"
    printf "  ├─ 隔离策略:  主网络 → IoT (允许)\n"
    printf "  │              IoT → 主网络 (拒绝)\n"
    printf "  │              IoT → 互联网 (允许)\n"
    [ $dns_filter -eq 1 ] && printf "  └─ DNS过滤:   启用\n" || printf "  └─ DNS过滤:   禁用\n"

    if ! confirm "确认创建 IoT 网络?"; then
        return 0
    fi

    backup_config

    # 1. 创建接口
    create_interface "iot" "$iot_subnet" "$vlan_id" "$BRIDGE_NAME"

    # 2. 配置 DHCP
    configure_dhcp "iot" "$iot_subnet" 100 150 "24h"

    # 3. 创建防火墙区域
    create_firewall_zone "iot" "iot" "REJECT" "ACCEPT" "REJECT" "1"

    # 4. 允许 DHCP/DNS
    uci -q batch <<EOF
add firewall rule
set firewall.@rule[-1].name='IoT-DNS'
set firewall.@rule[-1].src='iot'
set firewall.@rule[-1].dest_port='53'
set firewall.@rule[-1].proto='tcp udp'
set firewall.@rule[-1].target='ACCEPT'

add firewall rule
set firewall.@rule[-1].name='IoT-DHCP'
set firewall.@rule[-1].src='iot'
set firewall.@rule[-1].dest_port='67-68'
set firewall.@rule[-1].proto='udp'
set firewall.@rule[-1].target='ACCEPT'
EOF

    # 5. IoT -> WAN (允许上网)
    create_forwarding "iot" "wan"

    # 6. LAN -> IoT (主网络可以访问IoT)
    create_forwarding "lan" "iot"

    # 7. IoT -> LAN (拒绝，默认已经是REJECT)
    create_firewall_rule "Block-IoT-to-LAN" "iot" "lan" "REJECT"

    # 8. DNS 过滤 (强制 IoT 设备使用路由器 DNS)
    if [ $dns_filter -eq 1 ]; then
        uci -q batch <<EOF
add firewall redirect
set firewall.@redirect[-1].name='Force-IoT-DNS'
set firewall.@redirect[-1].src='iot'
set firewall.@redirect[-1].src_dport='53'
set firewall.@redirect[-1].dest_port='53'
set firewall.@redirect[-1].proto='tcp udp'
set firewall.@redirect[-1].target='DNAT'
EOF
        print_ok "DNS 过滤已启用 (强制使用路由器 DNS)"
    fi

    # 9. 创建 SSID
    if [ $WIFI_COUNT -gt 0 ]; then
        for radio in $WIFI_DEVICES; do
            create_ssid "$radio" "$iot_ssid" "iot" "psk2" "$iot_key" "1"
        done
    fi

    uci commit network
    uci commit wireless
    uci commit firewall
    uci commit dhcp

    print_ok "IoT 网络配置完成！"
    if confirm "是否立即应用配置?" "y"; then
        apply_config
    fi

    press_enter
}

wizard_lab_network() {
    print_section "实验网络配置向导"

    local vlan_id lab_subnet lab_ssid lab_key

    printf "\n  ${BOLD}实验网络用于开发测试，与其他网络完全隔离${NC}\n\n"

    printf "  VLAN ID [30]: "
    read -r vlan_id
    [ -z "$vlan_id" ] && vlan_id=30

    printf "  子网前缀 [192.168.30]: "
    read -r lab_subnet
    [ -z "$lab_subnet" ] && lab_subnet="192.168.30"

    local default_ssid="Lab_Network"
    printf "  SSID 名称 [%s]: " "$default_ssid"
    read -r lab_ssid
    [ -z "$lab_ssid" ] && lab_ssid="$default_ssid"

    printf "  WiFi 密码 (至少8位): "
    read -r lab_key
    if [ -z "$lab_key" ] || [ ${#lab_key} -lt 8 ]; then
        print_err "密码长度至少8位"
        press_enter
        return 1
    fi

    # 是否允许上网
    printf "  实验网络是否允许访问互联网? [Y/n]: "
    read -r allow_wan
    local wan_access=1
    [ "$allow_wan" = "n" ] || [ "$allow_wan" = "N" ] && wan_access=0

    print_line
    printf "\n  ${BOLD}配置摘要:${NC}\n"
    printf "  ├─ VLAN ID:   %s\n" "$vlan_id"
    printf "  ├─ 子网:      %s.0/24\n" "$lab_subnet"
    printf "  ├─ SSID:      %s\n" "$lab_ssid"
    printf "  ├─ 互联网:    %s\n" "$([ $wan_access -eq 1 ] && echo '允许' || echo '禁止')"
    printf "  └─ 隔离:      完全隔离 (不可访问其他网络)\n"

    if ! confirm "确认创建实验网络?"; then
        return 0
    fi

    backup_config

    create_interface "lab" "$lab_subnet" "$vlan_id" "$BRIDGE_NAME"
    configure_dhcp "lab" "$lab_subnet" 100 150 "6h"
    create_firewall_zone "lab" "lab" "REJECT" "ACCEPT" "REJECT" "1"

    uci -q batch <<EOF
add firewall rule
set firewall.@rule[-1].name='Lab-DNS'
set firewall.@rule[-1].src='lab'
set firewall.@rule[-1].dest_port='53'
set firewall.@rule[-1].proto='tcp udp'
set firewall.@rule[-1].target='ACCEPT'

add firewall rule
set firewall.@rule[-1].name='Lab-DHCP'
set firewall.@rule[-1].src='lab'
set firewall.@rule[-1].dest_port='67-68'
set firewall.@rule[-1].proto='udp'
set firewall.@rule[-1].target='ACCEPT'
EOF

    if [ $wan_access -eq 1 ]; then
        create_forwarding "lab" "wan"
    fi

    # 阻止 lab 访问所有其他区域
    create_firewall_rule "Block-Lab-to-LAN" "lab" "lan" "REJECT"
    create_firewall_rule "Block-Lab-to-IoT" "lab" "iot" "REJECT"
    create_firewall_rule "Block-Lab-to-Guest" "lab" "guest" "REJECT"

    if [ $WIFI_COUNT -gt 0 ]; then
        for radio in $WIFI_DEVICES; do
            create_ssid "$radio" "$lab_ssid" "lab" "psk2" "$lab_key" "0"
        done
    fi

    uci commit network
    uci commit wireless
    uci commit firewall
    uci commit dhcp

    print_ok "实验网络配置完成！"
    if confirm "是否立即应用配置?" "y"; then
        apply_config
    fi

    press_enter
}

# ========================== 一键配置所有网络 ==========================

wizard_full_setup() {
    print_section "完整网络隔离方案 - 一键配置"

    printf "\n  ${BOLD}此向导将一次性创建以下所有网络:${NC}\n\n"
    printf "  ${GREEN}1. 主网络 (LAN)${NC}      - 保持现有配置\n"
    printf "  ${YELLOW}2. 访客网络 (Guest)${NC}  - VLAN 10, 192.168.10.0/24\n"
    printf "  ${CYAN}3. IoT 网络${NC}          - VLAN 20, 192.168.20.0/24\n"
    printf "  ${MAGENTA}4. 实验网络 (Lab)${NC}    - VLAN 30, 192.168.30.0/24\n"
    printf "\n"
    printf "  ${BOLD}隔离策略:${NC}\n"
    printf "  ├─ 主网络 → 所有网络   (允许)\n"
    printf "  ├─ 访客   → 仅互联网   (禁止内网)\n"
    printf "  ├─ IoT    → 仅互联网   (禁止访问主网络)\n"
    printf "  └─ 实验   → 仅互联网   (完全隔离)\n"

    if [ $WIFI_COUNT -eq 0 ]; then
        print_warn "未检测到无线网卡，将仅配置有线 VLAN"
    fi

    printf "\n"

    # 收集所有信息
    printf "  ${BOLD}--- 访客网络 ---${NC}\n"
    printf "  访客 SSID [Guest_WiFi]: "
    read -r guest_ssid
    [ -z "$guest_ssid" ] && guest_ssid="Guest_WiFi"

    local guest_enc="none"
    local guest_key=""
    printf "  访客网络加密? [y/N]: "
    read -r do_guest_enc
    if [ "$do_guest_enc" = "y" ] || [ "$do_guest_enc" = "Y" ]; then
        guest_enc="psk2"
        printf "  访客 WiFi 密码: "
        read -r guest_key
        if [ ${#guest_key} -lt 8 ]; then
            print_err "密码至少8位"
            press_enter
            return 1
        fi
    fi

    printf "\n  ${BOLD}--- IoT 网络 ---${NC}\n"
    printf "  IoT SSID [IoT_Devices]: "
    read -r iot_ssid
    [ -z "$iot_ssid" ] && iot_ssid="IoT_Devices"
    printf "  IoT WiFi 密码: "
    read -r iot_key
    if [ ${#iot_key} -lt 8 ]; then
        print_err "密码至少8位"
        press_enter
        return 1
    fi

    printf "\n  ${BOLD}--- 实验网络 ---${NC}\n"
    printf "  实验 SSID [Lab_Network]: "
    read -r lab_ssid
    [ -z "$lab_ssid" ] && lab_ssid="Lab_Network"
    printf "  实验 WiFi 密码: "
    read -r lab_key
    if [ ${#lab_key} -lt 8 ]; then
        print_err "密码至少8位"
        press_enter
        return 1
    fi

    print_line
    printf "\n  ${BOLD}${RED}警告: 此操作将修改网络、无线和防火墙配置${NC}\n"
    if ! confirm "确认执行完整配置?"; then
        return 0
    fi

    backup_config
    printf "\n"

    # ===== 访客网络 =====
    print_section "配置访客网络"
    create_interface "guest" "192.168.10" "10" "$BRIDGE_NAME"
    configure_dhcp "guest" "192.168.10" 100 150 "2h"
    create_firewall_zone "guest" "guest" "REJECT" "ACCEPT" "REJECT" "1"

    uci -q batch <<EOF
add firewall rule
set firewall.@rule[-1].name='Guest-DNS'
set firewall.@rule[-1].src='guest'
set firewall.@rule[-1].dest_port='53'
set firewall.@rule[-1].proto='tcp udp'
set firewall.@rule[-1].target='ACCEPT'

add firewall rule
set firewall.@rule[-1].name='Guest-DHCP'
set firewall.@rule[-1].src='guest'
set firewall.@rule[-1].dest_port='67-68'
set firewall.@rule[-1].proto='udp'
set firewall.@rule[-1].target='ACCEPT'
EOF

    create_forwarding "guest" "wan"

    if [ $WIFI_COUNT -gt 0 ]; then
        for radio in $WIFI_DEVICES; do
            create_ssid "$radio" "$guest_ssid" "guest" "$guest_enc" "$guest_key" "1"
        done
    fi

    # ===== IoT 网络 =====
    print_section "配置 IoT 网络"
    create_interface "iot" "192.168.20" "20" "$BRIDGE_NAME"
    configure_dhcp "iot" "192.168.20" 100 150 "24h"
    create_firewall_zone "iot" "iot" "REJECT" "ACCEPT" "REJECT" "1"

    uci -q batch <<EOF
add firewall rule
set firewall.@rule[-1].name='IoT-DNS'
set firewall.@rule[-1].src='iot'
set firewall.@rule[-1].dest_port='53'
set firewall.@rule[-1].proto='tcp udp'
set firewall.@rule[-1].target='ACCEPT'

add firewall rule
set firewall.@rule[-1].name='IoT-DHCP'
set firewall.@rule[-1].src='iot'
set firewall.@rule[-1].dest_port='67-68'
set firewall.@rule[-1].proto='udp'
set firewall.@rule[-1].target='ACCEPT'
EOF

    create_forwarding "iot" "wan"
    create_forwarding "lan" "iot"
    create_firewall_rule "Block-IoT-to-LAN" "iot" "lan" "REJECT"

    # 强制 IoT DNS
    uci -q batch <<EOF
add firewall redirect
set firewall.@redirect[-1].name='Force-IoT-DNS'
set firewall.@redirect[-1].src='iot'
set firewall.@redirect[-1].src_dport='53'
set firewall.@redirect[-1].dest_port='53'
set firewall.@redirect[-1].proto='tcp udp'
set firewall.@redirect[-1].target='DNAT'
EOF

    if [ $WIFI_COUNT -gt 0 ]; then
        for radio in $WIFI_DEVICES; do
            create_ssid "$radio" "$iot_ssid" "iot" "psk2" "$iot_key" "1"
        done
    fi

    # ===== 实验网络 =====
    print_section "配置实验网络"
    create_interface "lab" "192.168.30" "30" "$BRIDGE_NAME"
    configure_dhcp "lab" "192.168.30" 100 150 "6h"
    create_firewall_zone "lab" "lab" "REJECT" "ACCEPT" "REJECT" "1"

    uci -q batch <<EOF
add firewall rule
set firewall.@rule[-1].name='Lab-DNS'
set firewall.@rule[-1].src='lab'
set firewall.@rule[-1].dest_port='53'
set firewall.@rule[-1].proto='tcp udp'
set firewall.@rule[-1].target='ACCEPT'

add firewall rule
set firewall.@rule[-1].name='Lab-DHCP'
set firewall.@rule[-1].src='lab'
set firewall.@rule[-1].dest_port='67-68'
set firewall.@rule[-1].proto='udp'
set firewall.@rule[-1].target='ACCEPT'
EOF

    create_forwarding "lab" "wan"
    create_firewall_rule "Block-Lab-to-LAN" "lab" "lan" "REJECT"
    create_firewall_rule "Block-Lab-to-IoT" "lab" "iot" "REJECT"
    create_firewall_rule "Block-Lab-to-Guest" "lab" "guest" "REJECT"

    if [ $WIFI_COUNT -gt 0 ]; then
        for radio in $WIFI_DEVICES; do
            create_ssid "$radio" "$lab_ssid" "lab" "psk2" "$lab_key" "0"
        done
    fi

    # 提交所有更改
    uci commit network
    uci commit wireless
    uci commit firewall
    uci commit dhcp

    print_section "配置完成"
    print_ok "所有网络已配置完成！"
    printf "\n"
    printf "  ${BOLD}网络摘要:${NC}\n"
    printf "  ┌─────────────┬──────────┬──────────────────┬────────────────────┐\n"
    printf "  │ 网络        │ VLAN     │ 子网             │ SSID               │\n"
    printf "  ├─────────────┼──────────┼──────────────────┼────────────────────┤\n"
    printf "  │ 主网络      │ 默认     │ 保持不变         │ 保持不变           │\n"
    printf "  │ 访客网络    │ 10       │ 192.168.10.0/24  │ %-18s │\n" "$guest_ssid"
    printf "  │ IoT 网络    │ 20       │ 192.168.20.0/24  │ %-18s │\n" "$iot_ssid"
    printf "  │ 实验网络    │ 30       │ 192.168.30.0/24  │ %-18s │\n" "$lab_ssid"
    printf "  └─────────────┴──────────┴──────────────────┴────────────────────┘\n"

    if confirm "是否立即应用配置? (网络将短暂中断)" "y"; then
        apply_config
    fi

    press_enter
}

# ========================== 自定义 VLAN 配置 ==========================

custom_vlan_setup() {
    print_section "自定义 VLAN / 网络配置"

    printf "\n  创建一个自定义的隔离网络\n\n"

    # 名称
    printf "  网络名称 (英文，如 cameras): "
    read -r net_name
    if [ -z "$net_name" ] || echo "$net_name" | grep -qE '[^a-zA-Z0-9_]'; then
        print_err "名称只能包含英文字母、数字和下划线"
        press_enter
        return 1
    fi

    # 检查是否已存在
    if uci -q get "network.$net_name" >/dev/null 2>&1; then
        print_err "网络 '$net_name' 已存在"
        press_enter
        return 1
    fi

    printf "  VLAN ID [2-4094]: "
    read -r vlan_id
    if ! validate_vlan_id "$vlan_id"; then
        print_err "无效的 VLAN ID"
        press_enter
        return 1
    fi

    printf "  子网前缀 (如 192.168.50): "
    read -r subnet
    if ! validate_subnet "$subnet"; then
        print_err "无效的子网格式"
        press_enter
        return 1
    fi

    # 是否创建 WiFi
    local create_wifi=0
    local wifi_ssid="" wifi_key="" wifi_enc="psk2"
    if [ $WIFI_COUNT -gt 0 ]; then
        printf "  是否为此网络创建 WiFi? [Y/n]: "
        read -r do_wifi
        if [ "$do_wifi" != "n" ] && [ "$do_wifi" != "N" ]; then
            create_wifi=1
            printf "  SSID 名称: "
            read -r wifi_ssid
            [ -z "$wifi_ssid" ] && wifi_ssid="${net_name}_WiFi"
            printf "  WiFi 密码 (留空为开放): "
            read -r wifi_key
            if [ -n "$wifi_key" ] && [ ${#wifi_key} -lt 8 ]; then
                print_err "密码至少8位"
                press_enter
                return 1
            fi
            [ -z "$wifi_key" ] && wifi_enc="none"
        fi
    fi

    # 隔离策略
    printf "\n  隔离策略:\n"
    printf "    1. 完全隔离 (仅上网)\n"
    printf "    2. 主网络可访问此网络\n"
    printf "    3. 此网络可访问主网络\n"
    printf "    4. 双向互通\n"
    printf "    5. 完全隔离且无互联网\n"
    printf "  选择 [1]: "
    read -r isolation
    [ -z "$isolation" ] && isolation=1

    if ! confirm "确认创建自定义网络 '$net_name'?"; then
        return 0
    fi

    backup_config

    create_interface "$net_name" "$subnet" "$vlan_id" "$BRIDGE_NAME"
    configure_dhcp "$net_name" "$subnet" 100 150 "12h"
    create_firewall_zone "$net_name" "$net_name" "REJECT" "ACCEPT" "REJECT" "1"

    # 允许 DNS 和 DHCP
    uci -q batch <<EOF
add firewall rule
set firewall.@rule[-1].name='${net_name}-DNS'
set firewall.@rule[-1].src='$net_name'
set firewall.@rule[-1].dest_port='53'
set firewall.@rule[-1].proto='tcp udp'
set firewall.@rule[-1].target='ACCEPT'

add firewall rule
set firewall.@rule[-1].name='${net_name}-DHCP'
set firewall.@rule[-1].src='$net_name'
set firewall.@rule[-1].dest_port='67-68'
set firewall.@rule[-1].proto='udp'
set firewall.@rule[-1].target='ACCEPT'
EOF

    case "$isolation" in
        1)
            create_forwarding "$net_name" "wan"
            create_firewall_rule "Block-${net_name}-to-LAN" "$net_name" "lan" "REJECT"
            ;;
        2)
            create_forwarding "$net_name" "wan"
            create_forwarding "lan" "$net_name"
            create_firewall_rule "Block-${net_name}-to-LAN" "$net_name" "lan" "REJECT"
            ;;
        3)
            create_forwarding "$net_name" "wan"
            create_forwarding "$net_name" "lan"
            ;;
        4)
            create_forwarding "$net_name" "wan"
            create_forwarding "$net_name" "lan"
            create_forwarding "lan" "$net_name"
            ;;
        5)
            create_firewall_rule "Block-${net_name}-to-LAN" "$net_name" "lan" "REJECT"
            # 不创建到 WAN 的转发
            ;;
    esac

    if [ $create_wifi -eq 1 ]; then
        for radio in $WIFI_DEVICES; do
            create_ssid "$radio" "$wifi_ssid" "$net_name" "$wifi_enc" "$wifi_key" "1"
        done
    fi

    uci commit network
    uci commit wireless
    uci commit firewall
    uci commit dhcp

    print_ok "自定义网络 '$net_name' 配置完成！"
    if confirm "是否立即应用配置?" "y"; then
        apply_config
    fi

    press_enter
}

# ========================== 删除网络 ==========================

delete_network() {
    print_section "删除隔离网络"

    # 列出可删除的网络（排除 lan, wan, wan6, loopback）
    local networks=""
    local idx=0
    local ifaces=$(uci show network 2>/dev/null | grep '=interface' | cut -d'.' -f2 | cut -d'=' -f1)

    printf "\n  可删除的网络:\n"
    local count=0
    for iface in $ifaces; do
        case "$iface" in
            lan|wan|wan6|loopback|globals) continue ;;
        esac
        count=$((count + 1))
        local ip=$(uci -q get "network.$iface.ipaddr")
        printf "    ${CYAN}%d${NC}. %-15s IP: %s\n" "$count" "$iface" "${ip:-N/A}"
        networks="$networks $iface"
    done

    if [ $count -eq 0 ]; then
        print_info "没有可删除的自定义网络"
        press_enter
        return
    fi

    printf "\n  输入要删除的网络名称: "
    read -r del_name

    # 验证
    echo "$networks" | grep -qw "$del_name"
    if [ $? -ne 0 ]; then
        print_err "网络 '$del_name' 不存在或不可删除"
        press_enter
        return 1
    fi

    if ! confirm "确认删除网络 '$del_name' 及其相关 SSID、防火墙规则?"; then
        return 0
    fi

    backup_config

    # 删除接口
    uci -q delete "network.$del_name"
    print_ok "已删除接口: $del_name"

    # 删除关联的桥接设备
    uci -q delete "network.br_${del_name}"

    # 删除 DHCP
    uci -q delete "dhcp.$del_name"
    print_ok "已删除 DHCP: $del_name"

    # 删除 SSID
    local wifi_idx=0
    while true; do
        local wnet=$(uci -q get "wireless.@wifi-iface[$wifi_idx].network")
        if [ -z "$(uci -q get wireless.@wifi-iface[$wifi_idx])" ]; then
            break
        fi
        if [ "$wnet" = "$del_name" ]; then
            uci -q delete "wireless.@wifi-iface[$wifi_idx]"
            print_ok "已删除关联 SSID"
            # 索引不增加，因为列表缩短了
        else
            wifi_idx=$((wifi_idx + 1))
        fi
    done

    # 删除防火墙区域
    local zone_idx=0
    while true; do
        local zn=$(uci -q get "firewall.@zone[$zone_idx].name")
        [ -z "$zn" ] && break
        if [ "$zn" = "$del_name" ]; then
            uci -q delete "firewall.@zone[$zone_idx]"
            print_ok "已删除防火墙区域: $del_name"
            break
        fi
        zone_idx=$((zone_idx + 1))
    done

    # 删除相关转发规则
    local fwd_idx=0
    while true; do
        local fs=$(uci -q get "firewall.@forwarding[$fwd_idx].src")
        if [ -z "$(uci -q get firewall.@forwarding[$fwd_idx] 2>/dev/null)" ]; then
            break
        fi
        local fd=$(uci -q get "firewall.@forwarding[$fwd_idx].dest")
        if [ "$fs" = "$del_name" ] || [ "$fd" = "$del_name" ]; then
            uci -q delete "firewall.@forwarding[$fwd_idx]"
            print_ok "已删除转发规则: $fs -> $fd"
        else
            fwd_idx=$((fwd_idx + 1))
        fi
    done

    # 删除相关防火墙规则
    local rule_idx=0
    while true; do
        local rs=$(uci -q get "firewall.@rule[$rule_idx].src")
        if [ -z "$(uci -q get firewall.@rule[$rule_idx] 2>/dev/null)" ]; then
            break
        fi
        local rd=$(uci -q get "firewall.@rule[$rule_idx].dest")
        local rn=$(uci -q get "firewall.@rule[$rule_idx].name")
        if [ "$rs" = "$del_name" ] || [ "$rd" = "$del_name" ]; then
            uci -q delete "firewall.@rule[$rule_idx]"
            print_ok "已删除防火墙规则: $rn"
        else
            rule_idx=$((rule_idx + 1))
        fi
    done

    # 删除相关 redirect
    local redir_idx=0
    while true; do
        local rds=$(uci -q get "firewall.@redirect[$redir_idx].src")
        if [ -z "$(uci -q get firewall.@redirect[$redir_idx] 2>/dev/null)" ]; then
            break
        fi
        if [ "$rds" = "$del_name" ]; then
            uci -q delete "firewall.@redirect[$redir_idx]"
            print_ok "已删除重定向规则"
        else
            redir_idx=$((redir_idx + 1))
        fi
    done

    uci commit network
    uci commit wireless
    uci commit firewall
    uci commit dhcp

    print_ok "网络 '$del_name' 已完全删除"
    if confirm "是否立即应用配置?" "y"; then
        apply_config
    fi

    press_enter
}

# ========================== 状态查看 ==========================

show_status() {
    print_section "网络状态概览"

    # 系统信息
    printf "\n  ${BOLD}系统信息:${NC}\n"
    printf "  ├─ OpenWrt 版本:   %s\n" "$OPENWRT_VERSION"
    printf "  ├─ 网络模式:       %s\n" "$([ $DSA_MODE -eq 1 ] && echo 'DSA' || echo 'swconfig')"
    printf "  ├─ 内核版本:       %s\n" "$(uname -r)"
    printf "  └─ 运行时间:       %s\n" "$(uptime | sed 's/.*up //' | sed 's/,.*//')"

    # 接口状态
    printf "\n  ${BOLD}网络接口:${NC}\n"
    printf "  ┌─────────────┬──────────────────┬───────────────┬──────────┐\n"
    printf "  │ 接口        │ 设备             │ IP 地址       │ 状态     │\n"
    printf "  ├─────────────┼──────────────────┼───────────────┼──────────┤\n"

    local ifaces=$(uci show network 2>/dev/null | grep '=interface' | cut -d'.' -f2 | cut -d'=' -f1)
    for iface in $ifaces; do
        case "$iface" in
            globals) continue ;;
        esac
        local dev=$(uci -q get "network.$iface.device")
        [ -z "$dev" ] && dev=$(uci -q get "network.$iface.ifname")
        local ip=$(uci -q get "network.$iface.ipaddr")
        [ -z "$ip" ] && ip=$(uci -q get "network.$iface.proto")

        # 检查接口是否 up
        local status="down"
        if ip link show "br-$iface" >/dev/null 2>&1; then
            ip link show "br-$iface" 2>/dev/null | grep -q "state UP" && status="${GREEN}up${NC}" || status="${RED}down${NC}"
        elif ip link show "$dev" >/dev/null 2>&1; then
            ip link show "$dev" 2>/dev/null | grep -q "state UP" && status="${GREEN}up${NC}" || status="${RED}down${NC}"
        fi

        printf "  │ %-11s │ %-16s │ %-13s │ %-8b │\n" "$iface" "${dev:-N/A}" "${ip:-dynamic}" "$status"
    done
    printf "  └─────────────┴──────────────────┴───────────────┴──────────┘\n"

    # WiFi 状态
    if [ $WIFI_COUNT -gt 0 ]; then
        printf "\n  ${BOLD}无线网络 (SSID):${NC}\n"
        printf "  ┌──────────────────────────┬────────────┬──────────────┬──────────┐\n"
        printf "  │ SSID                     │ Radio      │ 网络         │ 客户端数 │\n"
        printf "  ├──────────────────────────┼────────────┼──────────────┼──────────┤\n"

        local widx=0
        while true; do
            local wssid=$(uci -q get "wireless.@wifi-iface[$widx].ssid")
            [ -z "$wssid" ] && break
            local wdev=$(uci -q get "wireless.@wifi-iface[$widx].device")
            local wnet=$(uci -q get "wireless.@wifi-iface[$widx].network")

            # 获取连接的客户端数
            local clients="N/A"
            local wif=$(iwinfo 2>/dev/null | grep "$wssid" -A1 | grep -oE 'wlan[0-9.-]+' | head -1)
            if [ -n "$wif" ]; then
                clients=$(iwinfo "$wif" assoclist 2>/dev/null | grep -c "dBm")
            fi

            printf "  │ %-24s │ %-10s │ %-12s │ %-8s │\n" "$wssid" "${wdev:-N/A}" "${wnet:-N/A}" "$clients"
            widx=$((widx + 1))
        done
        printf "  └──────────────────────────┴────────────┴──────────────┴──────────┘\n"
    fi

    # 防火墙区域
    printf "\n  ${BOLD}防火墙区域:${NC}\n"
    printf "  ┌─────────────┬──────────┬──────────┬──────────┬─────────┐\n"
    printf "  │ 区域        │ 入站     │ 出站     │ 转发     │ NAT     │\n"
    printf "  ├─────────────┼──────────┼──────────┼──────────┼─────────┤\n"

    local zidx=0
    while true; do
        local zname=$(uci -q get "firewall.@zone[$zidx].name")
        [ -z "$zname" ] && break
        local zinput=$(uci -q get "firewall.@zone[$zidx].input")
        local zoutput=$(uci -q get "firewall.@zone[$zidx].output")
        local zforward=$(uci -q get "firewall.@zone[$zidx].forward")
        local zmasq=$(uci -q get "firewall.@zone[$zidx].masq")
        [ "$zmasq" = "1" ] && zmasq="是" || zmasq="否"

        printf "  │ %-11s │ %-8s │ %-8s │ %-8s │ %-7s │\n" "$zname" "$zinput" "$zoutput" "$zforward" "$zmasq"
        zidx=$((zidx + 1))
    done
    printf "  └─────────────┴──────────┴──────────┴──────────┴─────────┘\n"

    # 转发规则
    printf "\n  ${BOLD}转发规则:${NC}\n"
    local fidx=0
    while true; do
        local fsrc=$(uci -q get "firewall.@forwarding[$fidx].src")
        [ -z "$fsrc" ] && break
        local fdst=$(uci -q get "firewall.@forwarding[$fidx].dest")
        printf "    %s → %s\n" "$fsrc" "$fdst"
        fidx=$((fidx + 1))
    done
    [ $fidx -eq 0 ] && printf "    (无)\n"

    # DHCP 租约
    printf "\n  ${BOLD}活跃 DHCP 租约:${NC}\n"
    if [ -f /tmp/dhcp.leases ]; then
        local lease_count=$(wc -l < /tmp/dhcp.leases)
        if [ "$lease_count" -gt 0 ]; then
            printf "  ┌───────────────────┬──────────────────┬──────────────────────┐\n"
            printf "  │ IP 地址           │ MAC 地址         │ 主机名               │\n"
            printf "  ├───────────────────┼──────────────────┼──────────────────────┤\n"
            while read -r ts mac ip hostname _; do
                [ -z "$ip" ] && continue
                printf "  │ %-17s │ %-16s │ %-20s │\n" "$ip" "$mac" "${hostname:-*}"
            done < /tmp/dhcp.leases
            printf "  └───────────────────┴──────────────────┴──────────────────────┘\n"
        else
            printf "    (暂无活跃租约)\n"
        fi
    else
        printf "    (无法读取租约文件)\n"
    fi

    press_enter
}

# ========================== 网络诊断 ==========================

network_diagnostics() {
    print_section "网络诊断"

    printf "\n  ${BOLD}选择诊断项目:${NC}\n"
    printf "    1. 检查所有接口状态\n"
    printf "    2. 检查 DHCP 服务\n"
    printf "    3. 检查防火墙规则\n"
    printf "    4. 检查 VLAN 配置\n"
    printf "    5. 连通性测试\n"
    printf "    6. 完整诊断\n"
    printf "    0. 返回\n"
    printf "\n  选择 [6]: "
    read -r diag_choice
    [ -z "$diag_choice" ] && diag_choice=6

    case "$diag_choice" in
        0) return ;;
    esac

    printf "\n"

    # 接口状态
    if [ "$diag_choice" = "1" ] || [ "$diag_choice" = "6" ]; then
        print_step "检查接口状态..."
        local ifaces=$(uci show network 2>/dev/null | grep '=interface' | cut -d'.' -f2 | cut -d'=' -f1)
        for iface in $ifaces; do
            case "$iface" in
                globals|loopback) continue ;;
            esac
            local l3dev=""
            # 尝试获取 L3 设备
            if [ -e "/sys/class/net/br-$iface" ]; then
                l3dev="br-$iface"
            else
                l3dev=$(uci -q get "network.$iface.device")
                [ -z "$l3dev" ] && l3dev=$(uci -q get "network.$iface.ifname")
            fi

            if [ -n "$l3dev" ] && ip link show "$l3dev" >/dev/null 2>&1; then
                local state=$(ip link show "$l3dev" 2>/dev/null | grep -oE 'state [A-Z]+' | cut -d' ' -f2)
                local ipaddr=$(ip -4 addr show "$l3dev" 2>/dev/null | grep -oE 'inet [0-9.]+' | cut -d' ' -f2)
                if [ "$state" = "UP" ]; then
                    print_ok "$iface ($l3dev): UP, IP=$ipaddr"
                else
                    print_warn "$iface ($l3dev): $state, IP=${ipaddr:-none}"
                fi
            else
                print_err "$iface: 设备 ${l3dev:-unknown} 不存在或未启动"
            fi
        done
    fi

    # DHCP 检查
    if [ "$diag_choice" = "2" ] || [ "$diag_choice" = "6" ]; then
        printf "\n"
        print_step "检查 DHCP 服务..."
        if pgrep -x dnsmasq >/dev/null 2>&1; then
            print_ok "dnsmasq 正在运行"
        elif pgrep -x odhcpd >/dev/null 2>&1; then
            print_ok "odhcpd 正在运行"
        else
            print_err "DHCP 服务未运行"
        fi

        # 检查各接口的 DHCP 配置
        local dhcp_ifaces=$(uci show dhcp 2>/dev/null | grep '=dhcp' | cut -d'.' -f2 | cut -d'=' -f1)
        for diface in $dhcp_ifaces; do
            local dinterface=$(uci -q get "dhcp.$diface.interface")
            local dignore=$(uci -q get "dhcp.$diface.ignore")
            if [ "$dignore" = "1" ]; then
                print_info "DHCP $diface: 已禁用"
            else
                local dstart=$(uci -q get "dhcp.$diface.start")
                local dlimit=$(uci -q get "dhcp.$diface.limit")
                print_ok "DHCP $diface: 起始=$dstart, 数量=$dlimit"
            fi
        done
    fi

    # 防火墙检查
    if [ "$diag_choice" = "3" ] || [ "$diag_choice" = "6" ]; then
        printf "\n"
        print_step "检查防火墙..."

        # 检查防火墙进程
        if [ "$OPENWRT_MAJOR" -ge 22 ] || [ "$OPENWRT_MAJOR" -eq 99 ]; then
            if nft list ruleset >/dev/null 2>&1; then
                local rule_count=$(nft list ruleset 2>/dev/null | grep -c "rule")
                print_ok "nftables 活跃 (规则数: $rule_count)"
            else
                print_err "nftables 不可用"
            fi
        else
            if iptables -L -n >/dev/null 2>&1; then
                local rule_count=$(iptables -L -n 2>/dev/null | grep -c "^[A-Z]")
                print_ok "iptables 活跃 (链数: $rule_count)"
            else
                print_err "iptables 不可用"
            fi
        fi
    fi

    # VLAN 检查
    if [ "$diag_choice" = "4" ] || [ "$diag_choice" = "6" ]; then
        printf "\n"
        print_step "检查 VLAN 配置..."

        if [ $DSA_MODE -eq 1 ]; then
            if command -v bridge >/dev/null 2>&1; then
                local vlan_info=$(bridge vlan show 2>/dev/null)
                if [ -n "$vlan_info" ]; then
                    print_ok "Bridge VLAN 配置:"
                    echo "$vlan_info" | sed 's/^/    /'
                else
                    print_info "无 bridge VLAN 配置 (可能使用 802.1q 子接口)"
                fi
            fi

            # 检查 802.1q 接口
            local vlan_ifs=$(ip link show 2>/dev/null | grep -oE '[a-z0-9]+\.[0-9]+' | sort -u)
            if [ -n "$vlan_ifs" ]; then
                print_ok "802.1q VLAN 接口:"
                for vif in $vlan_ifs; do
                    printf "    %s\n" "$vif"
                done
            fi
        else
            if command -v swconfig >/dev/null 2>&1 && [ -n "$SWITCH_NAME" ]; then
                print_ok "Switch VLAN 配置:"
                swconfig dev "$SWITCH_NAME" show 2>/dev/null | grep -A5 "VLAN" | sed 's/^/    /'
            fi
        fi
    fi

    # 连通性测试
    if [ "$diag_choice" = "5" ] || [ "$diag_choice" = "6" ]; then
        printf "\n"
        print_step "连通性测试..."

        # DNS 解析
        if nslookup openwrt.org >/dev/null 2>&1; then
            print_ok "DNS 解析正常"
        else
            print_err "DNS 解析失败"
        fi

        # 外网连通
        if ping -c 2 -W 3 8.8.8.8 >/dev/null 2>&1; then
            print_ok "互联网连通 (8.8.8.8)"
        else
            print_warn "互联网不可达 (8.8.8.8)"
        fi

        # 测试各子网网关
        local ifaces=$(uci show network 2>/dev/null | grep '=interface' | cut -d'.' -f2 | cut -d'=' -f1)
        for iface in $ifaces; do
            local gw=$(uci -q get "network.$iface.ipaddr")
            if [ -n "$gw" ] && [ "$gw" != "0.0.0.0" ]; then
                if ping -c 1 -W 2 "$gw" >/dev/null 2>&1; then
                    print_ok "网关可达: $iface ($gw)"
                else
                    print_warn "网关不可达: $iface ($gw)"
                fi
            fi
        done
    fi

    press_enter
}

# ========================== 应用配置 ==========================

apply_config() {
    print_step "应用配置中..."
    printf "\n"

    print_step "重启网络..."
    /etc/init.d/network restart >> "$LOG_FILE" 2>&1
    sleep 3

    print_step "重启防火墙..."
    /etc/init.d/firewall restart >> "$LOG_FILE" 2>&1
    sleep 1

    if [ -x /etc/init.d/dnsmasq ]; then
        print_step "重启 DHCP/DNS..."
        /etc/init.d/dnsmasq restart >> "$LOG_FILE" 2>&1
        sleep 1
    fi

    if [ $WIFI_COUNT -gt 0 ]; then
        print_step "重启无线..."
        wifi reload >> "$LOG_FILE" 2>&1
        sleep 2
    fi

    print_ok "所有服务已重启"

    # 验证
    sleep 2
    printf "\n"
    print_step "验证配置..."
    local errors=0

    local ifaces=$(uci show network 2>/dev/null | grep '=interface' | cut -d'.' -f2 | cut -d'=' -f1)
    for iface in $ifaces; do
        case "$iface" in
            globals|loopback) continue ;;
        esac
        local ip=$(uci -q get "network.$iface.ipaddr")
        [ -z "$ip" ] && continue
        local l3dev="br-$iface"
        [ ! -e "/sys/class/net/$l3dev" ] && l3dev=$(uci -q get "network.$iface.device")

        if [ -n "$l3dev" ] && ip addr show "$l3dev" 2>/dev/null | grep -q "$ip"; then
            print_ok "$iface: IP $ip 已分配"
        else
            print_warn "$iface: IP $ip 可能未正确分配 (设备: ${l3dev:-unknown})"
            errors=$((errors + 1))
        fi
    done

    if [ $errors -gt 0 ]; then
        print_warn "检测到 $errors 个潜在问题，请检查日志: $LOG_FILE"
        print_info "如需回滚，请使用菜单中的 '恢复备份' 功能"
    else
        print_ok "所有配置已成功应用！"
    fi
}

# ========================== 导出配置报告 ==========================

export_config_report() {
    print_section "导出配置报告"

    local report_file="/tmp/network_isolation_report_$(date +%Y%m%d_%H%M%S).txt"

    {
        echo "============================================"
        echo " OpenWrt 网络隔离配置报告"
        echo " 生成时间: $(date)"
        echo " 设备: $(cat /tmp/sysinfo/model 2>/dev/null || echo 'Unknown')"
        echo " OpenWrt: $OPENWRT_VERSION"
        echo " 模式: $([ $DSA_MODE -eq 1 ] && echo 'DSA' || echo 'swconfig')"
        echo "============================================"
        echo ""
        echo "--- /etc/config/network ---"
        cat /etc/config/network 2>/dev/null
        echo ""
        echo "--- /etc/config/wireless ---"
        cat /etc/config/wireless 2>/dev/null
        echo ""
        echo "--- /etc/config/firewall ---"
        cat /etc/config/firewall 2>/dev/null
        echo ""
        echo "--- /etc/config/dhcp ---"
        cat /etc/config/dhcp 2>/dev/null
        echo ""
        echo "--- ip addr ---"
        ip addr show 2>/dev/null
        echo ""
        echo "--- ip route ---"
        ip route show 2>/dev/null
        echo ""
        if [ $DSA_MODE -eq 1 ]; then
            echo "--- bridge vlan show ---"
            bridge vlan show 2>/dev/null
        fi
        echo ""
        echo "--- DHCP Leases ---"
        cat /tmp/dhcp.leases 2>/dev/null
        echo ""
        echo "============================================"
        echo " 报告结束"
        echo "============================================"
    } > "$report_file"

    print_ok "报告已导出: $report_file"
    print_info "文件大小: $(ls -lh "$report_file" | awk '{print $5}')"
    press_enter
}

# ========================== 主菜单 ==========================

main_menu() {
    while true; do
        print_banner

        printf "  ${BOLD}系统: ${NC}OpenWrt %s | ${BOLD}模式: ${NC}%s | ${BOLD}WiFi: ${NC}%d个\n\n" \
            "$OPENWRT_VERSION" \
            "$([ $DSA_MODE -eq 1 ] && echo 'DSA' || echo 'swconfig')" \
            "$WIFI_COUNT"

        printf "  ${BOLD}${GREEN}━━━ 快速配置向导 ━━━${NC}\n"
        printf "    ${CYAN}1${NC}.  🚀 一键完整配置 (访客+IoT+实验 全部网络)\n"
        printf "    ${CYAN}2${NC}.  👥 仅配置访客网络\n"
        printf "    ${CYAN}3${NC}.  🏠 仅配置 IoT 设备网络\n"
        printf "    ${CYAN}4${NC}.  🔬 仅配置实验网络\n"
        printf "\n"
        printf "  ${BOLD}${YELLOW}━━━ 高级操作 ━━━${NC}\n"
        printf "    ${CYAN}5${NC}.  ⚙️  自定义 VLAN / 网络\n"
        printf "    ${CYAN}6${NC}.  🗑️  删除隔离网络\n"
        printf "\n"
        printf "  ${BOLD}${BLUE}━━━ 状态与诊断 ━━━${NC}\n"
        printf "    ${CYAN}7${NC}.  📊 查看网络状态\n"
        printf "    ${CYAN}8${NC}.  🔍 网络诊断\n"
        printf "    ${CYAN}9${NC}.  📋 导出配置报告\n"
        printf "\n"
        printf "  ${BOLD}${MAGENTA}━━━ 维护 ━━━${NC}\n"
        printf "    ${CYAN}10${NC}. 💾 恢复备份配置\n"
        printf "    ${CYAN}11${NC}. 🔄 重新检测系统\n"
        printf "\n"
        printf "    ${CYAN}0${NC}.  ❌ 退出\n"
        printf "\n"
        print_line
        printf "  请选择 [0-11]: "
        read -r choice

        case "$choice" in
            1)  wizard_full_setup ;;
            2)  wizard_guest_network ;;
            3)  wizard_iot_network ;;
            4)  wizard_lab_network ;;
            5)  custom_vlan_setup ;;
            6)  delete_network ;;
            7)  show_status ;;
            8)  network_diagnostics ;;
            9)  export_config_report ;;
            10) restore_config ;;
            11)
                init_system
                press_enter
                ;;
            0|q|Q)
                printf "\n  ${GREEN}再见！${NC}\n\n"
                exit 0
                ;;
            *)
                print_err "无效选择"
                sleep 1
                ;;
        esac
    done
}

# ========================== 初始化 ==========================

init_system() {
    print_banner
    print_section "系统检测"

    detect_openwrt_version
    detect_network_mode
    detect_network_devices
    detect_wifi
    detect_existing_config

    print_line
    print_ok "系统检测完成"

    check_and_install_deps
}

# ========================== 入口点 ==========================

main() {
    # 初始化日志
    echo "=== NetIso Setup Log $(date) ===" > "$LOG_FILE"

    check_root
    init_system

    printf "\n"
    print_ok "初始化完成，进入主菜单"
    sleep 1

    main_menu
}

# 运行
main "$@"
