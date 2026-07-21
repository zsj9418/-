#!/bin/sh
VERSION="1.2"
CONFIG_DIR="/etc/config"
BACKUP_DIR="/etc/backups"
LOG_FILE="/tmp/netconfig.log"
SWITCH_DEVICE=""
SWPORT_MAP=""
PHYSICAL_IFACES=""
DSA_CPU_IFACES=""
VLAN_CAPABLE=0
SELECTED_RESULT=""
NET_STYLE=""
HW_SWITCH_TYPE="none"
DEFAULT_MAC="72:3D:E5:25:E0:DD"
INIT_SCRIPT="/etc/init.d/set_mac"
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
BOLD='\033[1m'
NC='\033[0m'
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}
info()    { echo -e "${GREEN}[信息]${NC} $*"; }
warn()    { echo -e "${YELLOW}[警告]${NC} $*"; }
err()     { echo -e "${RED}[错误]${NC} $*"; }
success() { echo -e "${GREEN}${BOLD}[成功]${NC} $*"; }
fail()    { echo -e "${RED}${BOLD}[失败]${NC} $*"; }
sep()     { echo -e "${CYAN}------------------------------------------------------------${NC}"; }
init_check() {
    if [ "$(id -u)" -ne 0 ]; then
        err "此脚本必须以root权限运行"
        exit 1
    fi
    if ! grep -qi "openwrt\|lede" /etc/os-release 2>/dev/null; then
        if [ ! -f /etc/openwrt_release ] && [ ! -f /etc/openwrt_version ]; then
            err "此脚本仅适用于OpenWRT系统"
            exit 1
        fi
    fi
    mkdir -p "$BACKUP_DIR"
    touch "$LOG_FILE"
    log "===== 脚本初始化 v${VERSION} ====="
    if [ -n "$SSH_CONNECTION" ]; then
        echo -e "${YELLOW}警告: SSH连接中，配置网络可能导致断开${NC}"
        printf "按回车继续或Ctrl+C退出..."
        read dummy
    fi
}
detect_net_style() {
    NET_STYLE="new"
    HW_SWITCH_TYPE="none"
    if command -v swconfig >/dev/null 2>&1; then
        local sw
        sw=$(swconfig list 2>/dev/null | awk '{print $2}' | head -n1)
        if [ -n "$sw" ]; then
            SWITCH_DEVICE="$sw"
            HW_SWITCH_TYPE="swconfig"
            VLAN_CAPABLE=1
        fi
    fi
    local dsa_found=0
    for d in /sys/class/net/lan* /sys/class/net/wan*; do
        [ -e "$d" ] || continue
        local ifname
        ifname=$(basename "$d")
        if [ -f "/sys/class/net/$ifname/phys_port_name" ] || \
           [ -f "/sys/class/net/$ifname/phys_switch_id" ]; then
            dsa_found=1
        fi
    done
    if ip link show 2>/dev/null | grep -qE '(lan|wan)[0-9]+@eth'; then
        dsa_found=1
    fi
    if [ "$dsa_found" -eq 1 ] && [ "$HW_SWITCH_TYPE" != "swconfig" ]; then
        HW_SWITCH_TYPE="dsa"
        VLAN_CAPABLE=1
    fi
    if uci show network 2>/dev/null | grep -q "config device"; then
        NET_STYLE="new"
    elif uci show network 2>/dev/null | grep -qE "\.type='bridge'"; then
        NET_STYLE="new"
    fi
    if uci show network 2>/dev/null | grep -q "\.ifname="; then
        if ! uci show network 2>/dev/null | grep -qE "config device|\.name='br-"; then
            NET_STYLE="old"
        fi
    fi
    log "HW_SWITCH_TYPE=$HW_SWITCH_TYPE  NET_STYLE=$NET_STYLE  SWITCH_DEVICE=${SWITCH_DEVICE:-N/A}"
}
get_system_info() {
    ARCH=$(uname -m)
    MODEL=""
    if [ -f /tmp/sysinfo/model ]; then
        MODEL=$(cat /tmp/sysinfo/model)
    elif [ -f /proc/device-tree/model ]; then
        MODEL=$(cat /proc/device-tree/model 2>/dev/null)
    else
        MODEL=$(grep -i 'machine\|model name\|system type' /proc/cpuinfo 2>/dev/null \
                | head -1 | cut -d':' -f2 | sed 's/^[ \t]*//')
    fi
    echo -e "${BLUE}系统架构: ${ARCH}${NC}"
    echo -e "${BLUE}设备型号: ${MODEL:-未知}${NC}"
    echo -e "${BLUE}交换架构: ${HW_SWITCH_TYPE}${NC}"
    echo -e "${BLUE}UCI风格:  ${NET_STYLE}${NC}"
    [ -n "$SWITCH_DEVICE" ] && echo -e "${BLUE}swconfig设备: ${SWITCH_DEVICE}${NC}"
    log "系统信息: arch=$ARCH model=${MODEL:-unknown}"
}
init_switch_port_map() {
    SWPORT_MAP=""
    [ "$HW_SWITCH_TYPE" != "swconfig" ] && return
    [ -z "$SWITCH_DEVICE" ] && return
    for port in $(swconfig dev "$SWITCH_DEVICE" show 2>/dev/null \
                  | grep -oE 'Port [0-9]+:' | cut -d' ' -f2 | tr -d :); do
        local iface
        iface=$(swconfig dev "$SWITCH_DEVICE" port "$port" show 2>/dev/null \
                | grep -Eo 'link: port:[^ ]+' | cut -d':' -f3)
        if [ -n "$iface" ]; then
            SWPORT_MAP="$SWPORT_MAP ${iface}:${port}"
        fi
    done
    log "swconfig端口映射: $SWPORT_MAP"
}
detect_interfaces() {
    PHYSICAL_IFACES=""
    DSA_CPU_IFACES=""
    local dsa_subports="" dsa_cpu_set=""
    if [ "$HW_SWITCH_TYPE" = "dsa" ]; then
        ip link show 2>/dev/null | while IFS= read -r line; do
            if echo "$line" | grep -qE '(lan|wan)[0-9]*@eth[0-9]'; then
                local sub cpu
                sub=$(echo "$line" | grep -oE '(lan|wan)[0-9]+@eth[0-9]+' | cut -d'@' -f1 | head -1)
                cpu=$(echo "$line" | grep -oE '(lan|wan)[0-9]+@eth[0-9]+' | cut -d'@' -f2 | head -1)
                echo "${sub}:${cpu}"
            fi
        done > /tmp/_dsa_ports_$$ 2>/dev/null
        if [ -f /tmp/_dsa_ports_$$ ]; then
            while IFS=: read -r sub cpu; do
                [ -n "$sub" ] && dsa_subports="$dsa_subports $sub"
                [ -n "$cpu" ] && dsa_cpu_set="$dsa_cpu_set $cpu"
            done < /tmp/_dsa_ports_$$
            rm -f /tmp/_dsa_ports_$$
        fi
        if [ -z "$dsa_subports" ]; then
            for path in /sys/class/net/*; do
                local iface
                iface=$(basename "$path")
                if [ -f "/sys/class/net/$iface/phys_port_name" ]; then
                    dsa_subports="$dsa_subports $iface"
                fi
            done
        fi
        dsa_subports=$(echo "$dsa_subports" | tr ' ' '\n' | sort -u | xargs)
        dsa_cpu_set=$(echo "$dsa_cpu_set"   | tr ' ' '\n' | sort -u | xargs)
        DSA_CPU_IFACES="$dsa_cpu_set"
        log "DSA子口: $dsa_subports   CPU口: $dsa_cpu_set"
    fi
    for path in /sys/class/net/*; do
        local iface
        iface=$(basename "$path")
        case "$iface" in
            lo|br-*|br[0-9]*|veth*|docker*|vir*|dummy*|\
            wlan*|ra*|rai*|rax*|apcli*|apclii*|phy*|teql*|ifb*) continue ;;
        esac
        if [ "$HW_SWITCH_TYPE" = "dsa" ]; then
            if echo " $dsa_subports " | grep -q " ${iface} "; then
                PHYSICAL_IFACES="$PHYSICAL_IFACES $iface"
                continue
            fi
            if echo "$iface" | grep -qE '^eth[0-9]+$'; then
                if ip link show 2>/dev/null | grep -qE "@${iface}:"; then
                    DSA_CPU_IFACES="$DSA_CPU_IFACES $iface"
                    log "识别为DSA CPU总线口（排除）: $iface"
                    continue
                fi
                if [ -d "/sys/class/net/$iface/device" ]; then
                    PHYSICAL_IFACES="$PHYSICAL_IFACES $iface"
                fi
            fi
            if echo "$iface" | grep -qE '^(lan|wan)[0-9]*$'; then
                if ! echo " $dsa_subports " | grep -q " ${iface} "; then
                    if [ -d "/sys/class/net/$iface/device" ]; then
                        PHYSICAL_IFACES="$PHYSICAL_IFACES $iface"
                    fi
                fi
            fi
            continue
        fi
        if [ "$HW_SWITCH_TYPE" = "swconfig" ]; then
            if echo "$iface" | grep -qE '^eth[0-9]+$'; then
                if [ -d "/sys/class/net/$iface/device" ]; then
                    PHYSICAL_IFACES="$PHYSICAL_IFACES $iface"
                fi
            fi
            continue
        fi
        if [ -d "/sys/class/net/$iface/device" ]; then
            PHYSICAL_IFACES="$PHYSICAL_IFACES $iface"
        elif echo "$iface" | grep -qE '^(eth[0-9]|lan[0-9]|wan[0-9]?)$'; then
            PHYSICAL_IFACES="$PHYSICAL_IFACES $iface"
        fi
    done
    PHYSICAL_IFACES=$(echo "$PHYSICAL_IFACES" | tr ' ' '\n' | sort -u \
                      | grep -v '^\s*$' | xargs)
    DSA_CPU_IFACES=$(echo "$DSA_CPU_IFACES"   | tr ' ' '\n' | sort -u \
                     | grep -v '^\s*$' | xargs)
    if [ -z "$PHYSICAL_IFACES" ]; then
        err "未检测到可用物理网络接口"
        log "错误: PHYSICAL_IFACES为空，HW=$HW_SWITCH_TYPE"
        exit 1
    fi
    log "可用物理接口: $PHYSICAL_IFACES"
    log "DSA CPU总线口(不参与桥接): $DSA_CPU_IFACES"
}
validate_ip() {
    if ! echo "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        return 1
    fi
    local IFS='.'
    set -- $1
    for octet in "$1" "$2" "$3" "$4"; do
        [ "$octet" -gt 255 ] 2>/dev/null && return 1
    done
    return 0
}
validate_netmask() {
    validate_ip "$1" || return 1
    case "$1" in
        255.255.255.0|255.255.0.0|255.0.0.0|\
        255.255.255.128|255.255.255.192|255.255.255.224|\
        255.255.255.240|255.255.255.248|255.255.255.252|\
        255.255.128.0|255.255.192.0|255.255.224.0|\
        255.255.240.0|255.255.248.0|255.255.252.0|255.255.254.0)
            return 0 ;;
        *) return 1 ;;
    esac
}
validate_mac() {
    echo "$1" | grep -qiE '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$'
}
to_upper() { echo "$1" | tr 'a-f' 'A-F'; }
iface_exists() {
    [ -d "/sys/class/net/$1" ] && return 0
    command -v ip       >/dev/null 2>&1 && ip link show "$1"  >/dev/null 2>&1 && return 0
    command -v ifconfig >/dev/null 2>&1 && ifconfig "$1"      >/dev/null 2>&1 && return 0
    return 1
}
get_current_mac() {
    local _if="$1"
    if [ -f "/sys/class/net/${_if}/address" ]; then
        tr 'a-f' 'A-F' < "/sys/class/net/${_if}/address"
    elif command -v ip >/dev/null 2>&1; then
        ip link show "$_if" 2>/dev/null | awk '/ether/{print toupper($2)}'
    elif command -v ifconfig >/dev/null 2>&1; then
        ifconfig "$_if" 2>/dev/null \
            | grep -ioE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' \
            | head -1 | tr 'a-f' 'A-F'
    fi
}
generate_mac() {
    local suffix
    if [ -r /dev/urandom ] && command -v hexdump >/dev/null 2>&1; then
        suffix=$(dd if=/dev/urandom bs=1 count=3 2>/dev/null \
                 | hexdump -v -e '3/1 "%02X:"' | sed 's/:$//')
    elif [ -r /dev/urandom ] && command -v od >/dev/null 2>&1; then
        suffix=$(dd if=/dev/urandom bs=1 count=3 2>/dev/null \
                 | od -An -tx1 | tr -d ' \n' \
                 | sed 's/\(..\)\(..\)\(..\)/\1:\2:\3/' | tr 'a-f' 'A-F')
    elif command -v awk >/dev/null 2>&1; then
        suffix=$(awk 'BEGIN{srand();for(i=1;i<=3;i++){printf "%02X%s",int(rand()*256),(i<3?":":"")}}')
    else
        local _seed _b1 _b2 _b3
        _seed=$(($$  + $(date +%s)))
        _b1=$(( (_seed * 1103515245 + 12345) % 256 ))
        _b2=$(( (_b1  * 1103515245 + 12345) % 256 ))
        _b3=$(( (_b2  * 1103515245 + 12345) % 256 ))
        suffix=$(printf '%02X:%02X:%02X' "$_b1" "$_b2" "$_b3")
    fi
    echo "72:3D:E5:${suffix}"
}
list_all_ifaces() {
    if [ -d /sys/class/net ]; then
        ls /sys/class/net/ 2>/dev/null | grep -v '^lo$'
    elif command -v ip >/dev/null 2>&1; then
        ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -v '^lo$'
    elif command -v ifconfig >/dev/null 2>&1; then
        ifconfig -a 2>/dev/null | grep -oE '^[a-zA-Z0-9_.-]+' | grep -v '^lo$'
    fi
}
apply_mac_now() {
    local _mac="$1" _if="$2" _step_ok=0
    echo -e "\n${YELLOW}=== 即时应用MAC地址 ===${NC}"
    sep
    if command -v ip >/dev/null 2>&1; then
        info "使用 [ip link] 命令应用..."
        printf "    %-40s" "ip link set ${_if} down"
        if ip link set "${_if}" down 2>/tmp/_mac_err; then
            success "down成功"
        else
            fail "down失败: $(cat /tmp/_mac_err)"
            warn "尝试强制继续..."
        fi
        printf "    %-40s" "ip link set ${_if} address ${_mac}"
        if ip link set "${_if}" address "${_mac}" 2>/tmp/_mac_err; then
            success "MAC已写入"
            _step_ok=1
        else
            fail "MAC写入失败: $(cat /tmp/_mac_err)"
        fi
        printf "    %-40s" "ip link set ${_if} up"
        if ip link set "${_if}" up 2>/tmp/_mac_err; then
            success "up成功"
        else
            fail "up失败: $(cat /tmp/_mac_err)"
        fi
    elif command -v ifconfig >/dev/null 2>&1; then
        info "使用 [ifconfig] 命令应用..."
        printf "    %-40s" "ifconfig ${_if} down"
        ifconfig "${_if}" down 2>/tmp/_mac_err && success "down成功" || fail "down失败: $(cat /tmp/_mac_err)"
        printf "    %-40s" "ifconfig ${_if} hw ether ${_mac}"
        if ifconfig "${_if}" hw ether "${_mac}" 2>/tmp/_mac_err; then
            success "MAC已写入"
            _step_ok=1
        else
            fail "MAC写入失败: $(cat /tmp/_mac_err)"
        fi
        printf "    %-40s" "ifconfig ${_if} up"
        ifconfig "${_if}" up 2>/tmp/_mac_err && success "up成功" || fail "up失败: $(cat /tmp/_mac_err)"
    else
        fail "系统中未找到 ip 或 ifconfig 命令"
        return 1
    fi
    sep
    local _real_mac _target_upper
    _real_mac=$(get_current_mac "${_if}")
    _target_upper=$(to_upper "${_mac}")
    if [ "$_step_ok" -eq 1 ]; then
        if [ "$(to_upper "${_real_mac}")" = "$_target_upper" ]; then
            success "验证通过  当前MAC: ${_real_mac}"
        else
            warn "MAC命令执行成功，但读取值为: ${_real_mac}"
            warn "部分虚拟网桥可能需要重启网络后才生效"
        fi
    else
        fail "即时应用失败，将依赖重启后init脚本生效"
    fi
    rm -f /tmp/_mac_err
    return $([ "$_step_ok" -eq 1 ] && echo 0 || echo 1)
}
reload_network_service() {
    local _if="$1"
    echo -e "\n${YELLOW}=== 重载网络配置 ===${NC}"
    sep
    local _reload_ok=0
    if command -v ubus >/dev/null 2>&1; then
        printf "    %-44s" "[方法1] ubus call network reload"
        if ubus call network reload 2>/tmp/_net_err; then
            success "成功"
            _reload_ok=1
        else
            fail "失败: $(cat /tmp/_net_err | head -1)"
        fi
    else
        warn "[方法1] ubus不可用，跳过"
    fi
    if [ "$_reload_ok" -eq 0 ] && command -v reload_config >/dev/null 2>&1; then
        printf "    %-44s" "[方法2] reload_config"
        if reload_config 2>/tmp/_net_err; then
            success "成功"
            _reload_ok=1
        else
            fail "失败: $(cat /tmp/_net_err | head -1)"
        fi
    fi
    if [ "$_reload_ok" -eq 0 ]; then
        printf "    %-44s" "[方法3] network restart"
        for _cmd in ifdown ifup; do
            _path=$(command -v "$_cmd" 2>/dev/null)
            if [ -n "$_path" ] && [ ! -x "$_path" ]; then
                chmod +x "$_path" 2>/dev/null
            fi
        done
        if /etc/init.d/network restart 2>/tmp/_net_err; then
            success "成功"
            _reload_ok=1
        else
            fail "失败: $(cat /tmp/_net_err | head -1)"
        fi
    fi
    if [ "$_reload_ok" -eq 0 ]; then
        printf "    %-44s" "[方法4] 仅重启接口${_if}"
        if command -v ip >/dev/null 2>&1; then
            if ip link set "${_if}" down 2>/dev/null && ip link set "${_if}" up 2>/dev/null; then
                success "接口重启成功"
                _reload_ok=1
            else
                fail "接口重启失败"
            fi
        fi
    fi
    sep
    if [ "$_reload_ok" -eq 1 ]; then
        success "网络配置重载完成"
    else
        warn "所有自动重载方法均失败，请手动reboot"
    fi
    rm -f /tmp/_net_err
    return $([ "$_reload_ok" -eq 1 ] && echo 0 || echo 1)
}
set_mac_uci() {
    local _mac="$1" _iface="$2" _applied=0
    command -v uci >/dev/null 2>&1 || return 1
    local _dev_idx=0
    while uci -q get "network.@device[${_dev_idx}]" >/dev/null 2>&1; do
        local _dev_name
        _dev_name=$(uci -q get "network.@device[${_dev_idx}].name" 2>/dev/null)
        if [ "$_dev_name" = "$_iface" ]; then
            uci set "network.@device[${_dev_idx}].macaddr=${_mac}"
            info "UCI: network.@device[${_dev_idx}].macaddr = ${_mac}"
            _applied=1
            break
        fi
        _dev_idx=$((_dev_idx + 1))
    done
    local _section
    case "$_iface" in
        br-*) _section="${_iface#br-}" ;;
        *)    _section=$(uci show network 2>/dev/null \
                | grep -E "(ifname|device)='?${_iface}'?" \
                | head -1 | cut -d. -f2) ;;
    esac
    if [ -n "$_section" ] && uci -q get "network.${_section}" >/dev/null 2>&1; then
        uci set "network.${_section}.macaddr=${_mac}"
        info "UCI: network.${_section}.macaddr = ${_mac}"
        _applied=1
    fi
    [ "$_applied" -eq 1 ] && uci commit network && return 0
    warn "UCI: 未找到接口 '${_iface}' 对应配置段"
    return 1
}
create_init_script() {
    local _mac="$1" _iface="$2"
    local _down _set _up
    if command -v ip >/dev/null 2>&1; then
        _down="ip link set ${_iface} down"
        _set="ip link set ${_iface} address ${_mac}"
        _up="ip link set ${_iface} up"
    elif command -v ifconfig >/dev/null 2>&1; then
        _down="ifconfig ${_iface} down"
        _set="ifconfig ${_iface} hw ether ${_mac}"
        _up="ifconfig ${_iface} up"
    else
        err "未找到ip或ifconfig"
        return 1
    fi
    if [ -f /etc/rc.common ]; then
        cat > "${INIT_SCRIPT}" <<INITEOF
#!/bin/sh /etc/rc.common
START=99
start() {
    _wait=0
    while [ ! -d "/sys/class/net/${_iface}" ] && [ "\$_wait" -lt 30 ]; do
        sleep 1; _wait=\$((_wait+1))
    done
    [ ! -d "/sys/class/net/${_iface}" ] && logger -t set_mac "接口${_iface}未就绪" && return 1
    ${_down}
    ${_set}
    ${_up}
    logger -t set_mac "${_iface} MAC已固定为${_mac}"
}
INITEOF
    else
        cat > "${INIT_SCRIPT}" <<INITEOF
#!/bin/sh
case "\$1" in
    start)
        [ -d "/sys/class/net/${_iface}" ] || exit 0
        ${_down}; ${_set}; ${_up}
        logger -t set_mac "${_iface} MAC已固定为${_mac}" ;;
    stop) ;;
    restart) \$0 start ;;
    *) echo "Usage: \$0 {start|stop|restart}"; exit 1 ;;
esac
INITEOF
    fi
    chmod +x "${INIT_SCRIPT}"
    if [ -f /etc/rc.common ]; then
        "${INIT_SCRIPT}" enable 2>/dev/null && info "init.d脚本已启用(rc.common)"
    elif command -v update-rc.d >/dev/null 2>&1; then
        update-rc.d set_mac defaults 2>/dev/null && info "init.d脚本已启用(update-rc.d)"
    elif command -v chkconfig >/dev/null 2>&1; then
        chkconfig --add set_mac 2>/dev/null && info "init.d脚本已启用(chkconfig)"
    else
        warn "未能自动注册开机自启，请手动添加"
    fi
    return 0
}
configure_mac() {
    clear
    echo -e "${YELLOW}=== MAC地址管理 ===${NC}"
    local interfaces
    interfaces=$(list_all_ifaces)
    if [ -n "$interfaces" ]; then
        info "检测到以下网络接口:"
        echo "$interfaces" | while read -r _if; do
            local _cmac
            _cmac=$(get_current_mac "$_if")
            printf "   %-16s 当前MAC: %s\n" "$_if" "${_cmac:-未知}"
        done
    else
        warn "未检测到网络接口，将使用默认: br-lan"
    fi
    echo ""
    printf "请输入要修改的接口名称 [默认: br-lan]: "
    read target_iface
    target_iface="${target_iface:-br-lan}"
    if ! iface_exists "$target_iface"; then
        warn "接口 '${target_iface}' 当前不存在"
        printf "是否仍然继续? (y/N): "
        read _c
        case "$_c" in y|Y) ;; *) info "已取消"; return ;; esac
    fi
    local current_mac
    current_mac=$(get_current_mac "$target_iface")
    [ -n "$current_mac" ] && info "接口 ${target_iface} 当前MAC: ${current_mac}"
    echo -e "\n${GREEN}MAC来源:${NC}"
    echo "  1) 自定义MAC（直接回车使用默认 ${DEFAULT_MAC}）"
    echo "  2) 自动生成随机MAC"
    echo "  3) 返回"
    printf "请输入选项 [1-3]: "
    read choice
    local mac_address
    case "$choice" in
        1)
            printf "请输入MAC地址 [默认: ${DEFAULT_MAC}]: "
            read user_mac
            if [ -z "$user_mac" ]; then
                mac_address="$DEFAULT_MAC"
                info "使用默认MAC: $mac_address"
            else
                mac_address=$(to_upper "$user_mac")
                if ! validate_mac "$mac_address"; then
                    err "无效的MAC地址格式"
                    return 1
                fi
                info "自定义MAC: $mac_address"
            fi
            ;;
        2)
            mac_address=$(generate_mac)
            info "自动生成MAC: $mac_address"
            ;;
        3) return ;;
        *) err "无效选项"; return 1 ;;
    esac
    echo -e "\n${YELLOW}--- 确认 ---${NC}"
    sep
    echo "  目标接口:  ${target_iface}"
    echo "  当前MAC:   ${current_mac:-未知}"
    echo "  新的MAC:   ${mac_address}"
    sep
    printf "确认应用以上更改? (y/N): "
    read final_confirm
    case "$final_confirm" in y|Y|yes|YES) ;; *) info "已取消"; return ;; esac
    if [ -f "${INIT_SCRIPT}" ]; then
        cp "${INIT_SCRIPT}" "${INIT_SCRIPT}.bak.$(date +%Y%m%d%H%M%S)"
        info "已备份现有init脚本"
    fi
    echo -e "\n${YELLOW}=== 写入持久化配置 ===${NC}"
    sep
    local uci_ok=0 init_ok=0
    if command -v uci >/dev/null 2>&1; then
        if set_mac_uci "$mac_address" "$target_iface"; then
            uci_ok=1
            success "UCI持久化配置写入完成"
        else
            fail "UCI写入失败，将仅依赖init脚本"
        fi
    fi
    if create_init_script "$mac_address" "$target_iface"; then
        init_ok=1
        success "init.d启动脚本部署完成"
    else
        fail "init.d脚本部署失败"
    fi
    apply_mac_now "$mac_address" "$target_iface"
    local apply_ok=$?
    reload_network_service "$target_iface"
    local reload_ok=$?
    echo -e "\n${YELLOW}=== 最终结果汇总 ===${NC}"
    sep
    printf "  %-30s" "UCI持久化配置:"
    [ "$uci_ok"    -eq 1 ] && success "成功" || fail "失败/跳过"
    printf "  %-30s" "init.d开机脚本:"
    [ "$init_ok"   -eq 1 ] && success "成功" || fail "失败"
    printf "  %-30s" "即时MAC应用:"
    [ "$apply_ok"  -eq 0 ] && success "成功" || warn "失败(重启后生效)"
    printf "  %-30s" "网络配置重载:"
    [ "$reload_ok" -eq 0 ] && success "成功" || warn "失败(重启后生效)"
    sep
    if [ "$apply_ok" -eq 0 ] && [ "$reload_ok" -eq 0 ]; then
        success "所有操作成功，MAC更改已即时生效，无需重启"
        local _final_mac
        _final_mac=$(get_current_mac "$target_iface")
        info "当前接口 ${target_iface} MAC地址: ${_final_mac}"
    elif [ "$uci_ok" -eq 1 ] || [ "$init_ok" -eq 1 ]; then
        warn "持久化配置已保存，但即时应用存在问题，建议执行: reboot"
    else
        fail "所有操作均失败，请检查系统环境"
        return 1
    fi
    info "如需撤销，请运行:"
    echo "    ${INIT_SCRIPT} disable 2>/dev/null; rm -f ${INIT_SCRIPT}"
    [ "$uci_ok" -eq 1 ] && echo "    uci delete network.lan.macaddr; uci commit network"
    log "MAC配置: iface=$target_iface mac=$mac_address apply=$apply_ok reload=$reload_ok"
}
show_current_config() {
    clear
    echo -e "${YELLOW}=== 当前网络配置 ===${NC}"
    echo -e "\n${GREEN}交换架构: ${HW_SWITCH_TYPE}  UCI风格: ${NET_STYLE}${NC}"
    [ -n "$DSA_CPU_IFACES" ] && \
        echo -e "${YELLOW}DSA CPU总线口(不可直接桥接): $DSA_CPU_IFACES${NC}"
    echo -e "\n${GREEN}接口配置:${NC}"
    uci show network 2>/dev/null \
        | grep -E "interface|ifname|device|proto|ipaddr|type|ports|gateway|dns" \
        | sed 's/network\./  /'
    echo -e "\n${GREEN}物理接口状态:${NC}"
    for iface in $PHYSICAL_IFACES; do
        local state speed
        state=$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || echo "unknown")
        speed=$(cat "/sys/class/net/$iface/speed" 2>/dev/null)
        if [ -n "$speed" ] && [ "$speed" != "-1" ]; then
            speed="${speed}Mb/s"
        else
            speed="N/A"
        fi
        printf "  %-10s state=%-8s speed=%s\n" "$iface" "$state" "$speed"
    done
    if [ "$HW_SWITCH_TYPE" = "swconfig" ] && [ -n "$SWITCH_DEVICE" ]; then
        echo -e "\n${GREEN}交换机VLAN (swconfig):${NC}"
        swconfig dev "$SWITCH_DEVICE" show 2>/dev/null \
            | grep -E 'vid|ports' | sed 's/^/  /'
    fi
    if [ "$HW_SWITCH_TYPE" = "dsa" ]; then
        echo -e "\n${GREEN}DSA端口列表:${NC}"
        ip link show 2>/dev/null \
            | grep -E '(lan|wan)[0-9]*@eth' | sed 's/^/  /'
    fi
    echo -e "\n${GREEN}防火墙区域:${NC}"
    uci show firewall 2>/dev/null \
        | grep -E "\.name=|\.network=|\.input=|\.forward=" \
        | sed 's/firewall\./  /'
    echo -e "\n${GREEN}桥接:${NC}"
    command -v brctl >/dev/null 2>&1 && brctl show 2>/dev/null | sed 's/^/  /'
    echo -e "\n${GREEN}DHCP:${NC}"
    local dhcp_ignore
    dhcp_ignore=$(uci -q get dhcp.lan.ignore)
    [ "$dhcp_ignore" = "1" ] && echo "  LAN DHCP: 已禁用" || echo "  LAN DHCP: 已启用"
    echo -e "\n${GREEN}Flow Offloading:${NC}"
    local fo fohw
    fo=$(uci -q get firewall.@defaults[0].flow_offloading)
    fohw=$(uci -q get firewall.@defaults[0].flow_offloading_hw)
    echo "  软件分载: ${fo:-未设置}"
    echo "  硬件分载: ${fohw:-未设置}"
    echo -e "\n${GREEN}MAC地址:${NC}"
    for iface in $(list_all_ifaces); do
        local mac
        mac=$(get_current_mac "$iface")
        printf "  %-16s %s\n" "$iface" "${mac:-未知}"
    done
    log "显示当前配置"
}
select_interfaces() {
    local prompt=$1 multi=$2 selected=""
    SELECTED_RESULT=""
    echo -e "\n${GREEN}${prompt}${NC}"
    echo "可用接口:"
    local i=1 iface_arr=""
    for iface in $PHYSICAL_IFACES; do
        local state
        state=$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || echo "unknown")
        printf "  %2d) %-10s (%s)\n" "$i" "$iface" "$state"
        iface_arr="$iface_arr $iface"
        i=$((i + 1))
    done
    local max=$((i - 1))
    if [ "$max" -eq 0 ]; then
        echo -e "${RED}没有可用接口${NC}"; return 1
    fi
    if [ "$multi" = "multi" ]; then
        echo "可多选(空格分隔编号):"
        printf "请输入: "
        read choices
        [ -z "$choices" ] && echo -e "${RED}未选择${NC}" && return 1
        for choice in $choices; do
            echo "$choice" | grep -qE '^[0-9]+$' || { echo -e "${RED}无效 '$choice'${NC}"; return 1; }
            { [ "$choice" -lt 1 ] || [ "$choice" -gt "$max" ]; } && \
                { echo -e "${RED}$choice 超出范围${NC}"; return 1; }
            local idx=1
            for iface in $iface_arr; do
                [ "$choice" -eq "$idx" ] && selected="$selected $iface" && break
                idx=$((idx + 1))
            done
        done
    else
        printf "请选择 (1-%d): " "$max"
        read choice
        echo "$choice" | grep -qE '^[0-9]+$' || { echo -e "${RED}无效${NC}"; return 1; }
        { [ "$choice" -lt 1 ] || [ "$choice" -gt "$max" ]; } && \
            { echo -e "${RED}超出范围${NC}"; return 1; }
        local idx=1
        for iface in $iface_arr; do
            [ "$choice" -eq "$idx" ] && selected="$iface" && break
            idx=$((idx + 1))
        done
    fi
    [ -z "$selected" ] && echo -e "${RED}选择无效${NC}" && return 1
    selected=$(echo "$selected" | xargs)
    echo -e "已选择: ${YELLOW}$selected${NC}"
    log "接口选择: $selected"
    SELECTED_RESULT="$selected"
    return 0
}
port_iface_to_switch() {
    echo "$SWPORT_MAP" | tr ' ' '\n' | grep "^${1}:" | cut -d':' -f2 | head -1
}
configure_wan() {
    echo -e "\n${YELLOW}=== 配置WAN接口 ===${NC}"
    if ! select_interfaces "请选择WAN接口" "single"; then return 1; fi
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
            2) wan_type="dhcp";  break ;;
            3) wan_type="static"; break ;;
            4) return ;;
            *) echo -e "${RED}无效${NC}" ;;
        esac
    done
    case $wan_type in
        "pppoe")
            printf "用户名: "; read pppoe_user
            [ -z "$pppoe_user" ] && echo -e "${RED}不能为空${NC}" && return 1
            printf "密码: "; stty -echo 2>/dev/null; read pppoe_pass; stty echo 2>/dev/null; echo
            [ -z "$pppoe_pass" ] && echo -e "${RED}不能为空${NC}" && return 1
            uci set network.wan=interface
            [ "$NET_STYLE" = "old" ] && uci set network.wan.ifname="$wan_iface" \
                                     || uci set network.wan.device="$wan_iface"
            uci set network.wan.proto="pppoe"
            uci set network.wan.username="$pppoe_user"
            uci set network.wan.password="$pppoe_pass"
            ;;
        "dhcp")
            uci set network.wan=interface
            [ "$NET_STYLE" = "old" ] && uci set network.wan.ifname="$wan_iface" \
                                     || uci set network.wan.device="$wan_iface"
            uci set network.wan.proto="dhcp"
            ;;
        "static")
            local static_ip static_mask static_gw static_dns
            while true; do printf "IP: "; read static_ip; validate_ip "$static_ip" && break; echo -e "${RED}无效${NC}"; done
            while true; do printf "掩码 [255.255.255.0]: "; read static_mask; static_mask=${static_mask:-255.255.255.0}; validate_netmask "$static_mask" && break; echo -e "${RED}无效${NC}"; done
            while true; do printf "网关(留空跳过): "; read static_gw; [ -z "$static_gw" ] && break; validate_ip "$static_gw" && break; echo -e "${RED}无效${NC}"; done
            while true; do printf "DNS(留空跳过): "; read static_dns; [ -z "$static_dns" ] && break; validate_ip "$static_dns" && break; echo -e "${RED}无效${NC}"; done
            uci set network.wan=interface
            [ "$NET_STYLE" = "old" ] && uci set network.wan.ifname="$wan_iface" \
                                     || uci set network.wan.device="$wan_iface"
            uci set network.wan.proto="static"
            uci set network.wan.ipaddr="$static_ip"
            uci set network.wan.netmask="$static_mask"
            [ -n "$static_gw" ]  && uci set network.wan.gateway="$static_gw"
            if [ -n "$static_dns" ]; then
                uci -q delete network.wan.dns
                uci add_list network.wan.dns="$static_dns"
            fi
            ;;
    esac
    local wan_zone_exists=0 zone_idx=0
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
    if ! select_interfaces "选择LAN接口(可多选)" "multi"; then return 1; fi
    local lan_ifaces=$SELECTED_RESULT
    local lan_ip
    while true; do printf "LAN IP: "; read lan_ip; validate_ip "$lan_ip" && break; echo -e "${RED}无效${NC}"; done
    uci set network.lan=interface
    uci set network.lan.proto='static'
    uci set network.lan.ipaddr="$lan_ip"
    uci set network.lan.netmask='255.255.255.0'
    local iface_count
    iface_count=$(echo "$lan_ifaces" | wc -w)
    if [ "$iface_count" -gt 1 ]; then
        if [ "$NET_STYLE" = "old" ]; then
            uci set network.lan.type='bridge'
            uci set network.lan.ifname="$lan_ifaces"
        else
            local br_section
            br_section=$(uci show network 2>/dev/null | grep "\.name='br-lan'" | head -1 | cut -d'.' -f2)
            [ -z "$br_section" ] && br_section=$(uci add network device)
            uci set "network.$br_section.name"='br-lan'
            uci set "network.$br_section.type"='bridge'
            uci -q delete "network.$br_section.ports"
            for p in $lan_ifaces; do uci add_list "network.$br_section.ports"="$p"; done
            uci set network.lan.device='br-lan'
        fi
    else
        [ "$NET_STYLE" = "old" ] && uci set network.lan.ifname="$lan_ifaces" \
                                 || uci set network.lan.device="$lan_ifaces"
    fi
    configure_dhcp "$lan_ip"
    echo -e "${GREEN}LAN配置完成${NC}"
    log "LAN: $lan_ifaces IP=$lan_ip"
}
configure_dhcp() {
    local lan_ip=$1
    local base
    base=$(echo "$lan_ip" | cut -d'.' -f1-3)
    echo -e "\n${YELLOW}=== DHCP ===${NC}"
    printf "启用DHCP? [Y/n]: "
    read en; en=${en:-y}
    case "$en" in
        y|Y)
            local s e lt
            while true; do printf "起始 [%s.100]: " "$base"; read s; s=${s:-${base}.100}; validate_ip "$s" && break; echo -e "${RED}无效${NC}"; done
            while true; do printf "结束 [%s.200]: " "$base"; read e; e=${e:-${base}.200}; validate_ip "$e" && break; echo -e "${RED}无效${NC}"; done
            printf "租约 [12h]: "; read lt; lt=${lt:-12h}
            local sn en_n lim
            sn=$(echo "$s" | cut -d'.' -f4)
            en_n=$(echo "$e" | cut -d'.' -f4)
            lim=$((en_n - sn + 1))
            [ "$lim" -le 0 ] && echo -e "${RED}结束必须大于起始${NC}" && return 1
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
        echo -e "${RED}此设备不支持VLAN管理（需要DSA或swconfig）${NC}"
        return 1
    fi
    echo -e "\n${YELLOW}=== VLAN ===${NC}"
    echo -e "当前交换架构: ${HW_SWITCH_TYPE}"
    if [ "$HW_SWITCH_TYPE" = "swconfig" ]; then
        echo "当前:"
        swconfig dev "$SWITCH_DEVICE" show 2>/dev/null | grep -E 'vid|ports' | sed 's/^/  /'
    fi
    echo "  1) 创建VLAN"
    echo "  2) 删除VLAN"
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
        printf "VLAN ID (2-4094): "; read vid
        echo "$vid" | grep -qE '^[0-9]+$' || { echo -e "${RED}请输入数字${NC}"; continue; }
        { [ "$vid" -lt 2 ] || [ "$vid" -gt 4094 ]; } && { echo -e "${RED}范围2-4094${NC}"; continue; }
        if [ "$HW_SWITCH_TYPE" = "swconfig" ]; then
            swconfig dev "$SWITCH_DEVICE" show 2>/dev/null | grep -q "vid: $vid" && \
                { echo -e "${RED}已存在${NC}"; continue; }
        fi
        break
    done
    if ! select_interfaces "选择成员(可多选)" "multi"; then return 1; fi
    local members=$SELECTED_RESULT
    if [ "$HW_SWITCH_TYPE" = "swconfig" ]; then
        local ports=""
        for iface in $members; do
            local port
            port=$(port_iface_to_switch "$iface")
            [ -z "$port" ] && { echo -e "${RED}找不到 $iface 对应的交换机端口${NC}"; return 1; }
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
    else
        uci set "network.vlan$vid=interface"
        uci set "network.vlan$vid.device=br-lan.$vid"
        uci set "network.vlan$vid.proto=static"
        uci add network bridge-vlan 2>/dev/null || true
        uci set "network.@bridge-vlan[-1].device=br-lan"
        uci set "network.@bridge-vlan[-1].vlan=$vid"
        for iface in $members; do
            uci add_list "network.@bridge-vlan[-1].ports"="$iface:u*"
        done
    fi
    printf "配置IP? [y/N]: "; read ci
    case "$ci" in
        y|Y)
            local vip
            while true; do printf "IP: "; read vip; validate_ip "$vip" && break; echo -e "${RED}无效${NC}"; done
            uci set "network.vlan$vid.ipaddr=$vip"
            uci set "network.vlan$vid.netmask=255.255.255.0"
            ;;
    esac
    echo -e "${GREEN}VLAN $vid 已创建${NC}"
    log "创建VLAN $vid members=$members"
}
delete_vlan() {
    local vlans=""
    if [ "$HW_SWITCH_TYPE" = "swconfig" ]; then
        vlans=$(swconfig dev "$SWITCH_DEVICE" show 2>/dev/null | grep 'vid:' | awk '{print $2}')
    else
        vlans=$(uci show network 2>/dev/null | grep "@bridge-vlan" | grep "\.vlan=" \
                | grep -oE '=[0-9]+' | tr -d '=')
    fi
    [ -z "$vlans" ] && echo -e "${YELLOW}无VLAN${NC}" && return
    echo "现有:"; for v in $vlans; do echo "  VLAN $v"; done
    local dv
    while true; do
        printf "删除哪个: "; read dv
        echo "$vlans" | grep -qw "$dv" && break
        echo -e "${RED}无效${NC}"
    done
    printf "确认删除 VLAN %s? [y/N]: " "$dv"; read cf
    case "$cf" in y|Y) ;; *) return ;; esac
    uci -q delete "network.vlan$dv"
    uci -q delete "network.vlan${dv}_sw"
    local bv_idx=0
    while uci -q get "network.@bridge-vlan[$bv_idx]" >/dev/null 2>&1; do
        if [ "$(uci -q get "network.@bridge-vlan[$bv_idx].vlan")" = "$dv" ]; then
            uci -q delete "network.@bridge-vlan[$bv_idx]"
            break
        fi
        bv_idx=$((bv_idx + 1))
    done
    echo -e "${GREEN}已删除${NC}"
    log "删除VLAN $dv"
}
get_bridge_mac() {
    local mac=""
    mac=$(cat /sys/class/net/br-lan/address 2>/dev/null)
    [ -n "$mac" ] && echo "$mac" && return
    mac=$(uci -q get network.lan.macaddr)
    [ -n "$mac" ] && echo "$mac" && return
    local br_sec
    br_sec=$(uci show network 2>/dev/null | grep "\.name='br-lan'" | head -1 | cut -d'.' -f2)
    if [ -n "$br_sec" ]; then
        mac=$(uci -q get "network.$br_sec.macaddr")
        [ -n "$mac" ] && echo "$mac" && return
    fi
    local first_eth
    for f in $PHYSICAL_IFACES; do first_eth=$f; break; done
    cat "/sys/class/net/$first_eth/address" 2>/dev/null
}
setup_bridge_old_style() {
    local ifaces="$1"
    uci set network.lan.type='bridge'
    uci -q delete network.lan.ifname
    uci set network.lan.ifname="$ifaces"
}
setup_bridge_new_style() {
    local ifaces="$1" mac="$2"
    local br_section
    br_section=$(uci show network 2>/dev/null | grep "\.name='br-lan'" | head -1 | cut -d'.' -f2)
    [ -z "$br_section" ] && br_section=$(uci add network device)
    uci set "network.$br_section.name"='br-lan'
    uci set "network.$br_section.type"='bridge'
    uci -q delete "network.$br_section.ports"
    for p in $ifaces; do
        uci add_list "network.$br_section.ports"="$p"
    done
    [ -n "$mac" ] && uci set "network.$br_section.macaddr"="$mac"
    uci -q delete network.lan.ifname
    uci -q delete network.lan.type
    uci set network.lan.device='br-lan'
}
configure_ap_mode() {
    clear
    echo -e "${YELLOW}=================================================${NC}"
    echo -e "  ${GREEN}AP/桥接模式一键配置${NC}"
    echo -e "${YELLOW}=================================================${NC}"
    echo -e "  ${BLUE}当前识别:${NC}"
    echo -e "  交换架构: ${GREEN}${HW_SWITCH_TYPE}${NC}"
    echo -e "  UCI风格:  ${GREEN}${NET_STYLE}${NC}"
    echo -e "  可用物理口: ${GREEN}${PHYSICAL_IFACES}${NC}"
    if [ -n "$DSA_CPU_IFACES" ]; then
        echo -e "  ${RED}DSA CPU总线口(已自动排除): ${DSA_CPU_IFACES}${NC}"
        echo -e "  ${RED}⚠  将这些口加入桥接会导致网络失联${NC}"
    fi
    echo -e "  ${BLUE}将执行:${NC}"
    echo -e "  [1] 设置管理IP/子网掩码/网关/DNS"
    echo -e "  [2] 所有可用网口并入LAN桥接"
    echo -e "  [3] 删除WAN/WAN6接口"
    echo -e "  [4] 关闭DHCP/DHCPv6/RA"
    echo -e "  [5] 清理IPv6配置"
    echo -e "  [6] 关闭Flow Offloading"
    echo -e "  [7] 停用防火墙"
    echo -e "  ${YELLOW}完成后作为纯AP/交换机，由主路由负责拨号/DHCP/NAT${NC}"
    printf "继续? [y/N]: "
    read ap_cf
    case "$ap_cf" in y|Y) ;; *) echo -e "${YELLOW}已取消${NC}"; return ;; esac
    echo -e "\n${BLUE}[1/9] 备份当前配置${NC}"
    backup_config
    echo -e "\n${BLUE}[2/9] 设置网络参数${NC}"
    echo -e "${YELLOW}请根据主路由网段填写（主路由一般为192.168.x.1）${NC}"
    echo -e "${YELLOW}本机IP不要与主路由或其他设备冲突${NC}"
    local current_ip current_mask current_gw current_dns
    current_ip=$(uci -q get network.lan.ipaddr)
    current_mask=$(uci -q get network.lan.netmask)
    current_gw=$(uci -q get network.lan.gateway)
    current_dns=$(uci -q get network.lan.dns 2>/dev/null)
    local ap_ip ap_mask ap_gateway ap_dns
    while true; do
        printf "本机管理IP [%s]: " "${current_ip:-192.168.1.2}"
        read ap_ip; ap_ip=${ap_ip:-${current_ip:-192.168.1.2}}
        validate_ip "$ap_ip" && break
        echo -e "${RED}无效，重新输入${NC}"
    done
    while true; do
        printf "子网掩码 [%s]: " "${current_mask:-255.255.255.0}"
        read ap_mask; ap_mask=${ap_mask:-${current_mask:-255.255.255.0}}
        validate_netmask "$ap_mask" && break
        echo -e "${RED}无效，重新输入${NC}"
    done
    local default_gw
    if [ -n "$current_gw" ]; then
        default_gw="$current_gw"
    else
        default_gw=$(echo "$ap_ip" | cut -d'.' -f1-3).1
    fi
    while true; do
        printf "主路由网关 [%s]: " "$default_gw"
        read ap_gateway; ap_gateway=${ap_gateway:-$default_gw}
        validate_ip "$ap_gateway" && break
        echo -e "${RED}无效，重新输入${NC}"
    done
    local default_dns="${current_dns:-$ap_gateway}"
    while true; do
        printf "DNS服务器 [%s]: " "$default_dns"
        read ap_dns; ap_dns=${ap_dns:-$default_dns}
        validate_ip "$ap_dns" && break
        echo -e "${RED}无效，重新输入${NC}"
    done
    local ap_net gw_net
    ap_net=$(echo "$ap_ip"      | cut -d'.' -f1-3)
    gw_net=$(echo "$ap_gateway" | cut -d'.' -f1-3)
    if [ "$ap_net" != "$gw_net" ]; then
        echo -e "${RED}警告: 管理IP($ap_ip)和网关($ap_gateway)不在同一网段${NC}"
        printf "确定继续? [y/N]: "; read seg_cf
        case "$seg_cf" in y|Y) ;; *) echo -e "${YELLOW}已取消${NC}"; return ;; esac
    fi
    if [ "$ap_ip" = "$ap_gateway" ]; then
        echo -e "${RED}管理IP不能和网关相同${NC}"; return
    fi
    echo ""
    echo -e "${YELLOW}=== 选择桥接网口 ===${NC}"
    echo -e "${GREEN}当前可用物理接口:${NC}"
    local i=1 iface_arr=""
    for iface in $PHYSICAL_IFACES; do
        local state
        state=$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || echo "unknown")
        printf "  %2d) %-10s (%s)\n" "$i" "$iface" "$state"
        iface_arr="$iface_arr $iface"
        i=$((i + 1))
    done
    local max=$((i - 1))
    echo -e "  ${GREEN}a) 全部加入桥接（推荐）${NC}"
    echo -e "  ${YELLOW}s) 手动选择${NC}"
    printf "选择 [a/s]: "
    read br_sel; br_sel=${br_sel:-a}
    local bridge_ifaces=""
    case "$br_sel" in
        a|A)
            bridge_ifaces="$PHYSICAL_IFACES"
            ;;
        s|S)
            printf "输入编号(空格分隔，1-%d): " "$max"
            read choices
            for choice in $choices; do
                echo "$choice" | grep -qE '^[0-9]+$' || { echo -e "${RED}无效 '$choice'${NC}"; return 1; }
                { [ "$choice" -lt 1 ] || [ "$choice" -gt "$max" ]; } && \
                    { echo -e "${RED}$choice 超出范围${NC}"; return 1; }
                local idx=1
                for iface in $iface_arr; do
                    [ "$choice" -eq "$idx" ] && bridge_ifaces="$bridge_ifaces $iface" && break
                    idx=$((idx + 1))
                done
            done
            bridge_ifaces=$(echo "$bridge_ifaces" | xargs)
            [ -z "$bridge_ifaces" ] && echo -e "${RED}未选择任何接口${NC}" && return 1
            ;;
        *) echo -e "${RED}无效${NC}"; return 1 ;;
    esac
    echo -e "\n${YELLOW}--- 确认配置 ---${NC}"
    echo -e "  管理IP:   ${GREEN}$ap_ip${NC}"
    echo -e "  子网掩码: ${GREEN}$ap_mask${NC}"
    echo -e "  网关:     ${GREEN}$ap_gateway${NC}"
    echo -e "  DNS:      ${GREEN}$ap_dns${NC}"
    echo -e "  桥接网口: ${GREEN}$bridge_ifaces${NC}"
    [ -n "$DSA_CPU_IFACES" ] && \
        echo -e "  排除口:   ${RED}$DSA_CPU_IFACES（DSA CPU口，不参与桥接）${NC}"
    printf "正确? [Y/n]: "; read info_cf
    case "$info_cf" in n|N) echo -e "${YELLOW}已取消${NC}"; return ;; esac
    echo -e "\n${BLUE}[3/9] 配置桥接${NC}"
    local current_mac
    current_mac=$(get_bridge_mac)
    if [ "$NET_STYLE" = "old" ]; then
        setup_bridge_old_style "$bridge_ifaces"
        echo -e "  ${GREEN}[swconfig/旧式] 桥接: $bridge_ifaces${NC}"
    else
        setup_bridge_new_style "$bridge_ifaces" "$current_mac"
        echo -e "  ${GREEN}[DSA/新式] br-lan成员: $bridge_ifaces${NC}"
    fi
    echo -e "\n${BLUE}[4/9] 配置LAN接口${NC}"
    uci set network.lan=interface
    [ "$NET_STYLE" != "old" ] && uci set network.lan.device='br-lan'
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
    [ -n "$current_mac" ] && uci set network.lan.macaddr="$current_mac"
    echo -e "  ${GREEN}IP=$ap_ip  掩码=$ap_mask  网关=$ap_gateway  DNS=$ap_dns${NC}"
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
    uci -q get dhcp.odhcpd >/dev/null 2>&1 && uci set dhcp.odhcpd.maindhcp='0'
    echo -e "  ${GREEN}DHCP/DHCPv6/RA已关闭${NC}"
    echo -e "\n${BLUE}[7/9] 关闭Flow Offloading${NC}"
    if uci -q get firewall.@defaults[0] >/dev/null 2>&1; then
        uci set firewall.@defaults[0].flow_offloading='0'
        uci set firewall.@defaults[0].flow_offloading_hw='0'
    fi
    echo -e "  ${GREEN}已关闭${NC}"
    echo -e "\n${BLUE}[8/9] 停用防火墙${NC}"
    printf "  停用防火墙? (AP模式建议停用) [Y/n]: "
    read fw_cf; fw_cf=${fw_cf:-y}
    local fw_action
    case "$fw_cf" in y|Y) fw_action="disable" ;; *) fw_action="clean" ;; esac
    echo -e "\n${BLUE}[9/9] 提交配置${NC}"
    uci commit network
    uci commit dhcp
    uci commit firewall
    if [ "$fw_action" = "disable" ]; then
        /etc/init.d/firewall stop 2>/dev/null
        /etc/init.d/firewall disable 2>/dev/null
        echo -e "  ${GREEN}防火墙已停用${NC}"
    else
        local zone_idx=0 del_list=""
        while uci -q get "firewall.@zone[$zone_idx]" >/dev/null 2>&1; do
            [ "$(uci -q get "firewall.@zone[$zone_idx].name")" = "wan" ] && \
                del_list="$del_list $zone_idx"
            zone_idx=$((zone_idx + 1))
        done
        for didx in $(echo "$del_list" | tr ' ' '\n' | sort -rn); do
            uci -q delete "firewall.@zone[$didx]"
        done
        local fwd_idx=0 fwd_del=""
        while uci -q get "firewall.@forwarding[$fwd_idx]" >/dev/null 2>&1; do
            local fs fd
            fs=$(uci -q get "firewall.@forwarding[$fwd_idx].src")
            fd=$(uci -q get "firewall.@forwarding[$fwd_idx].dest")
            { [ "$fd" = "wan" ] || [ "$fs" = "wan" ]; } && fwd_del="$fwd_del $fwd_idx"
            fwd_idx=$((fwd_idx + 1))
        done
        for didx in $(echo "$fwd_del" | tr ' ' '\n' | sort -rn); do
            uci -q delete "firewall.@forwarding[$didx]"
        done
        uci commit firewall
        echo -e "  ${YELLOW}防火墙保留，已清理wan区域${NC}"
    fi
    echo -e "  ${GREEN}配置已提交${NC}"
    echo -e "\n${YELLOW}============= 配置摘要 =============${NC}"
    echo -e "  管理IP:    ${GREEN}$ap_ip${NC}"
    echo -e "  子网掩码:  ${GREEN}$ap_mask${NC}"
    echo -e "  网关:      ${GREEN}$ap_gateway${NC}"
    echo -e "  DNS:       ${GREEN}$ap_dns${NC}"
    echo -e "  桥接网口:  ${GREEN}$bridge_ifaces${NC}"
    [ -n "$DSA_CPU_IFACES" ] && echo -e "  排除(CPU): ${RED}$DSA_CPU_IFACES${NC}"
    echo -e "  DHCP:      ${RED}已关闭${NC}"
    echo -e "  IPv6 RA:   ${RED}已关闭${NC}"
    echo -e "  Offload:   ${RED}已关闭${NC}"
    [ "$fw_action" = "disable" ] && echo -e "  防火墙:    ${RED}已停用${NC}" \
                                 || echo -e "  防火墙:    ${YELLOW}保留(已清理wan)${NC}"
    echo -e "${YELLOW}====================================${NC}"
    echo -e "${YELLOW}注意事项:${NC}"
    echo -e "  1. 主路由LAN口 → 网线 → 本机任意可用口"
    echo -e "  2. 主路由DHCP池请避开 $ap_ip"
    echo -e "  3. 重启后用 $ap_ip 访问管理页面"
    echo -e "  4. 出问题可运行: sh $BACKUP_DIR/config_*/restore.sh"
    printf "立即重启网络生效? [y/N]: "
    read rst_cf
    case "$rst_cf" in
        y|Y)
            echo -e "\n${BLUE}重启网络...${NC}"
            /etc/init.d/network restart
            sleep 3
            /etc/init.d/dnsmasq enabled 2>/dev/null && \
                /etc/init.d/dnsmasq restart 2>/dev/null
            [ "$fw_action" != "disable" ] && /etc/init.d/firewall restart 2>/dev/null
            echo -e "${GREEN}网络已重启${NC}"
            echo -e "${BLUE}验证连通性...${NC}"
            sleep 2
            local gw_ok=0 inet_ok=0 dns_ok=0
            if ping -c 2 -W 3 "$ap_gateway" >/dev/null 2>&1; then
                gw_ok=1; echo -e "  网关 $ap_gateway: ${GREEN}通${NC}"
            else
                echo -e "  网关 $ap_gateway: ${RED}不通${NC}"
            fi
            if ping -c 2 -W 3 223.5.5.5 >/dev/null 2>&1; then
                inet_ok=1; echo -e "  外网 223.5.5.5:  ${GREEN}通${NC}"
            else
                echo -e "  外网 223.5.5.5:  ${RED}不通${NC}"
            fi
            if command -v nslookup >/dev/null 2>&1; then
                if nslookup openwrt.org >/dev/null 2>&1; then
                    dns_ok=1; echo -e "  DNS解析:         ${GREEN}正常${NC}"
                else
                    echo -e "  DNS解析:         ${RED}失败${NC}"
                fi
            fi
            if [ $gw_ok -eq 1 ] && [ $inet_ok -eq 1 ]; then
                echo -e "${GREEN}配置成功！网络正常！${NC}"
            elif [ $gw_ok -eq 1 ]; then
                echo -e "${YELLOW}网关通但外网不通，检查主路由是否联网${NC}"
            else
                echo -e "${RED}网关不通，请检查:${NC}"
                echo -e "  - 网线是否连主路由LAN口"
                echo -e "  - 网关 $ap_gateway 是否正确"
                echo -e "  - IP $ap_ip 是否与主路由同网段"
                echo -e "  - 恢复: sh $BACKUP_DIR/config_*/restore.sh"
            fi
            log "AP完成 gw=$gw_ok inet=$inet_ok dns=$dns_ok bridge=$bridge_ifaces"
            ;;
        *)
            echo -e "${YELLOW}已保存未生效，手动执行: /etc/init.d/network restart${NC}"
            log "AP配置完成未重启 bridge=$bridge_ifaces"
            ;;
    esac
}
configure_offloading() {
    echo -e "\n${YELLOW}=== Flow Offloading ===${NC}"
    if ! /etc/init.d/firewall enabled 2>/dev/null; then
        echo -e "${YELLOW}防火墙未启用，Offloading无法工作${NC}"
        printf "先启用防火墙? [y/N]: "; read fe
        case "$fe" in
            y|Y) /etc/init.d/firewall enable 2>/dev/null; /etc/init.d/firewall start 2>/dev/null ;;
            *) return ;;
        esac
    fi
    local fo fohw has_hw=0
    fo=$(uci -q get firewall.@defaults[0].flow_offloading)
    fohw=$(uci -q get firewall.@defaults[0].flow_offloading_hw)
    echo "当前:"; echo "  软件分载: ${fo:-关闭}"; echo "  硬件分载: ${fohw:-关闭}"
    lsmod 2>/dev/null | grep -qE "nf_flow_table_hw|mtkhnat|shortcut_fe" && \
        has_hw=1 && echo -e "  硬件模块: ${GREEN}已加载${NC}" || \
        echo -e "  硬件模块: ${YELLOW}未检测到${NC}"
    echo "  1) 开启软件分载"
    echo "  2) 开启软件+硬件分载"
    echo "  3) 全部关闭"
    echo "  4) 返回"
    while true; do
        printf "选择 [1-4]: "; read c
        case $c in
            1) uci set firewall.@defaults[0].flow_offloading='1'
               uci set firewall.@defaults[0].flow_offloading_hw='0'
               uci commit firewall; /etc/init.d/firewall restart 2>/dev/null
               echo -e "${GREEN}软件分载已开启${NC}"; break ;;
            2) if [ $has_hw -eq 0 ]; then
                   echo -e "${YELLOW}未检测到硬件模块${NC}"
                   printf "继续? [y/N]: "; read hc
                   case "$hc" in y|Y) ;; *) continue ;; esac
               fi
               uci set firewall.@defaults[0].flow_offloading='1'
               uci set firewall.@defaults[0].flow_offloading_hw='1'
               uci commit firewall; /etc/init.d/firewall restart 2>/dev/null
               echo -e "${GREEN}软件+硬件分载已开启${NC}"; break ;;
            3) uci set firewall.@defaults[0].flow_offloading='0'
               uci set firewall.@defaults[0].flow_offloading_hw='0'
               uci commit firewall; /etc/init.d/firewall restart 2>/dev/null
               echo -e "${GREEN}已关闭${NC}"; break ;;
            4) return ;;
            *) echo -e "${RED}无效${NC}" ;;
        esac
    done
}
backup_config() {
    local ts bn
    ts=$(date +%Y%m%d_%H%M%S)
    bn="config_$ts"
    mkdir -p "$BACKUP_DIR/$bn"
    for f in network firewall dhcp wireless; do
        [ -f "$CONFIG_DIR/$f" ] && cp "$CONFIG_DIR/$f" "$BACKUP_DIR/$bn/"
    done
    [ "$HW_SWITCH_TYPE" = "swconfig" ] && [ -n "$SWITCH_DEVICE" ] && \
        swconfig dev "$SWITCH_DEVICE" show > "$BACKUP_DIR/$bn/vlan_config" 2>/dev/null
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
    local bks
    bks=$(ls -d "$BACKUP_DIR"/config_* 2>/dev/null | sort -r)
    [ -z "$bks" ] && echo -e "${RED}无备份${NC}" && return 1
    echo -e "\n${YELLOW}=== 恢复 ===${NC}"
    local i=1 blist=""
    for b in $bks; do
        echo "  $i) $(basename "$b")"; blist="$blist $b"; i=$((i + 1))
    done
    local mx=$((i - 1)) sb=""
    while true; do
        printf "选择 (1-%d): " "$mx"; read ch
        echo "$ch" | grep -qE '^[0-9]+$' || { echo -e "${RED}无效${NC}"; continue; }
        { [ "$ch" -lt 1 ] || [ "$ch" -gt "$mx" ]; } && { echo -e "${RED}超出${NC}"; continue; }
        local idx=1
        for b in $blist; do [ "$idx" -eq "$ch" ] && sb="$b" && break; idx=$((idx+1)); done
        break
    done
    printf "确认恢复 %s? [y/N]: " "$(basename "$sb")"; read cf
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
    local ch
    ch=$(uci changes 2>/dev/null)
    [ -z "$ch" ] && echo -e "${YELLOW}无更改${NC}" && return
    echo -e "${GREEN}待应用:${NC}"; echo "$ch" | sed 's/^/  /'
    printf "\n确认? [y/N]: "; read cf
    case "$cf" in y|Y) ;; *) echo -e "${YELLOW}取消${NC}"; return ;; esac
    uci commit network; uci commit firewall; uci commit dhcp
    /etc/init.d/network restart
    /etc/init.d/firewall restart 2>/dev/null
    /etc/init.d/dnsmasq restart 2>/dev/null
    echo -e "${GREEN}已应用${NC}"
    log "已应用"
}
network_diagnostics() {
    echo -e "\n${YELLOW}=== 网络诊断 ===${NC}"
    local lip lgw ldns
    lip=$(uci -q get network.lan.ipaddr)
    lgw=$(uci -q get network.lan.gateway)
    ldns=$(uci -q get network.lan.dns 2>/dev/null)
    echo -e "\n${GREEN}[基本信息]${NC}"
    echo "  IP:   ${lip:-未设置}"
    echo "  网关: ${lgw:-未设置}"
    echo "  DNS:  ${ldns:-未设置}"
    echo -e "\n${GREEN}[架构]${NC}"
    echo "  交换类型: $HW_SWITCH_TYPE   UCI风格: $NET_STYLE"
    echo "  可用物理口: $PHYSICAL_IFACES"
    [ -n "$DSA_CPU_IFACES" ] && echo "  DSA CPU口: $DSA_CPU_IFACES"
    echo -e "\n${GREEN}[路由表]${NC}"
    ip route 2>/dev/null | sed 's/^/  /'
    if [ -n "$lgw" ]; then
        echo -e "\n${GREEN}[网关]${NC}"
        ping -c 2 -W 3 "$lgw" >/dev/null 2>&1 && \
            echo -e "  $lgw: ${GREEN}通${NC}" || echo -e "  $lgw: ${RED}不通${NC}"
    fi
    echo -e "\n${GREEN}[外网]${NC}"
    ping -c 2 -W 3 223.5.5.5 >/dev/null 2>&1 && \
        echo -e "  223.5.5.5: ${GREEN}通${NC}" || echo -e "  223.5.5.5: ${RED}不通${NC}"
    echo -e "\n${GREEN}[DNS]${NC}"
    if command -v nslookup >/dev/null 2>&1; then
        nslookup openwrt.org >/dev/null 2>&1 && \
            echo -e "  ${GREEN}正常${NC}" || echo -e "  ${RED}失败${NC}"
    else
        echo -e "  ${YELLOW}nslookup不可用${NC}"
    fi
    echo -e "\n${GREEN}[桥接]${NC}"
    command -v brctl >/dev/null 2>&1 && brctl show 2>/dev/null | sed 's/^/  /'
    echo -e "\n${GREEN}[接口状态]${NC}"
    for iface in $PHYSICAL_IFACES; do
        local st cr
        st=$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || echo "?")
        cr=$(cat "/sys/class/net/$iface/carrier"   2>/dev/null || echo "?")
        printf "  %-10s state=%-6s carrier=%s\n" "$iface" "$st" "$cr"
    done
    echo -e "\n${GREEN}[MAC地址]${NC}"
    for iface in $(list_all_ifaces); do
        local mac
        mac=$(get_current_mac "$iface")
        printf "  %-16s %s\n" "$iface" "${mac:-未知}"
    done
    echo -e "\n${GREEN}[服务]${NC}"
    /etc/init.d/firewall enabled 2>/dev/null && \
        echo -e "  防火墙: ${GREEN}启用${NC}" || echo -e "  防火墙: ${YELLOW}禁用${NC}"
    local di; di=$(uci -q get dhcp.lan.ignore)
    [ "$di" = "1" ] && echo -e "  DHCP:   ${YELLOW}关闭${NC}" || echo -e "  DHCP:   ${GREEN}开启${NC}"
    uci -q get network.wan >/dev/null 2>&1 && \
        echo -e "  WAN:    ${GREEN}存在${NC}" || echo -e "  WAN:    ${YELLOW}不存在(AP模式)${NC}"
    log "诊断完成"
}
show_main_menu() {
    clear
    echo -e "${YELLOW}=================================================${NC}"
    echo -e "  OpenWRT 多网口高级配置工具 ${GREEN}v${VERSION}${NC}"
    echo -e "  架构: ${BLUE}${HW_SWITCH_TYPE}${NC}  风格: ${BLUE}${NET_STYLE}${NC}"
    echo -e "${YELLOW}=================================================${NC}"
    echo -e "  ${GREEN} 1.${NC} 显示当前网络配置"
    echo -e "  ${GREEN} 2.${NC} 配置WAN接口"
    echo -e "  ${GREEN} 3.${NC} 配置LAN接口"
    echo -e "  ${GREEN} 4.${NC} 配置VLAN"
    echo -e "  ${GREEN} 5.${NC} 配置MAC地址"
    echo -e "  ${GREEN} 6.${NC} 备份当前配置"
    echo -e "  ${GREEN} 7.${NC} 恢复备份配置"
    echo -e "  ${GREEN} 8.${NC} 应用所有配置"
    echo -e "  ${GREEN} 9.${NC} AP/桥接模式一键配置"
    echo -e "  ${GREEN}10.${NC} Flow Offloading配置"
    echo -e "  ${GREEN}11.${NC} 网络诊断"
    echo -e "  ${GREEN} 0.${NC} 退出"
    echo -e "${YELLOW}=================================================${NC}"
}
main_loop() {
    while true; do
        show_main_menu
        printf "请输入 [0-11]: "
        read option
        case $option in
            1)  show_current_config ;;
            2)  configure_wan ;;
            3)  configure_lan ;;
            4)  configure_vlan ;;
            5)  configure_mac ;;
            6)  backup_config ;;
            7)  restore_config ;;
            8)  apply_configuration ;;
            9)  configure_ap_mode ;;
            10) configure_offloading ;;
            11) network_diagnostics ;;
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
detect_net_style
get_system_info
init_switch_port_map
detect_interfaces
main_loop
