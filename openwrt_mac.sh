#!/bin/sh

# ---- 配置区 ----
DEFAULT_MAC="72:3D:E5:25:E0:DD"
DEFAULT_IFACE="br-lan"
INIT_SCRIPT="/etc/init.d/set_mac"

# ---- 颜色输出 (终端不支持则自动降级) ----
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && tput colors >/dev/null 2>&1; then
    RED=$(tput setaf 1); GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3)
    CYAN=$(tput setaf 6); BOLD=$(tput bold); RESET=$(tput sgr0)
else
    RED="" GREEN="" YELLOW="" CYAN="" BOLD="" RESET=""
fi

info()    { echo "${GREEN}[信息]${RESET} $*"; }
warn()    { echo "${YELLOW}[警告]${RESET} $*"; }
err()     { echo "${RED}[错误]${RESET} $*"; }
success() { echo "${GREEN}${BOLD}[成功]${RESET} $*"; }
fail()    { echo "${RED}${BOLD}[失败]${RESET} $*"; }
title()   { echo ""; echo "${BOLD}${CYAN}=== $* ===${RESET}"; }
sep()     { echo "${CYAN}------------------------------------------------------------${RESET}"; }

# ============================================================
#  函数定义
# ============================================================

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        err "请以 root 用户运行此脚本。"
        exit 1
    fi
}

generate_mac() {
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
        _seed=$(($$  + $(date +%s)))
        _b1=$(( (_seed * 1103515245 + 12345) % 256 ))
        _b2=$(( (_b1  * 1103515245 + 12345) % 256 ))
        _b3=$(( (_b2  * 1103515245 + 12345) % 256 ))
        suffix=$(printf '%02X:%02X:%02X' "$_b1" "$_b2" "$_b3")
    fi
    echo "72:3D:E5:${suffix}"
}

validate_mac() {
    echo "$1" | grep -qiE '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$'
}

to_upper() { echo "$1" | tr 'a-f' 'A-F'; }

detect_interfaces() {
    if [ -d /sys/class/net ]; then
        ls /sys/class/net/ 2>/dev/null | grep -v '^lo$'
    elif command -v ip >/dev/null 2>&1; then
        ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -v '^lo$'
    elif command -v ifconfig >/dev/null 2>&1; then
        ifconfig -a 2>/dev/null | grep -oE '^[a-zA-Z0-9_.-]+' | grep -v '^lo$'
    fi
}

iface_exists() {
    [ -d "/sys/class/net/$1" ] && return 0
    command -v ip       >/dev/null 2>&1 && ip link show "$1"  >/dev/null 2>&1 && return 0
    command -v ifconfig >/dev/null 2>&1 && ifconfig "$1"      >/dev/null 2>&1 && return 0
    return 1
}

get_current_mac() {
    _if="$1"
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

# ============================================================
#  ★ 核心：立即应用 MAC（带详细成功/失败输出）
# ============================================================
apply_mac_now() {
    _mac="$1"
    _if="$2"
    _step_ok=0

    title "即时应用 MAC 地址"
    sep

    # ---- 优先用 ip 命令 ----
    if command -v ip >/dev/null 2>&1; then
        info "使用 [ip link] 命令应用..."

        # 1) down
        printf "    %-40s" "ip link set ${_if} down"
        if ip link set "${_if}" down 2>/tmp/_mac_err; then
            success "down 成功"
        else
            fail "down 失败: $(cat /tmp/_mac_err)"
            warn "尝试强制继续..."
        fi

        # 2) set mac
        printf "    %-40s" "ip link set ${_if} address ${_mac}"
        if ip link set "${_if}" address "${_mac}" 2>/tmp/_mac_err; then
            success "MAC 已写入"
            _step_ok=1
        else
            fail "MAC 写入失败: $(cat /tmp/_mac_err)"
        fi

        # 3) up
        printf "    %-40s" "ip link set ${_if} up"
        if ip link set "${_if}" up 2>/tmp/_mac_err; then
            success "up 成功"
        else
            fail "up 失败: $(cat /tmp/_mac_err)"
        fi

    # ---- 回退到 ifconfig ----
    elif command -v ifconfig >/dev/null 2>&1; then
        info "使用 [ifconfig] 命令应用..."

        printf "    %-40s" "ifconfig ${_if} down"
        if ifconfig "${_if}" down 2>/tmp/_mac_err; then
            success "down 成功"
        else
            fail "down 失败: $(cat /tmp/_mac_err)"
        fi

        printf "    %-40s" "ifconfig ${_if} hw ether ${_mac}"
        if ifconfig "${_if}" hw ether "${_mac}" 2>/tmp/_mac_err; then
            success "MAC 已写入"
            _step_ok=1
        else
            fail "MAC 写入失败: $(cat /tmp/_mac_err)"
        fi

        printf "    %-40s" "ifconfig ${_if} up"
        if ifconfig "${_if}" up 2>/tmp/_mac_err; then
            success "up 成功"
        else
            fail "up 失败: $(cat /tmp/_mac_err)"
        fi
    else
        fail "系统中未找到 'ip' 或 'ifconfig' 命令！"
        return 1
    fi

    # ---- 验证 MAC 是否真正生效 ----
    sep
    _real_mac=$(get_current_mac "${_if}")
    _target_upper=$(to_upper "${_mac}")
    if [ "$_step_ok" -eq 1 ]; then
        if [ "$(to_upper "${_real_mac}")" = "$_target_upper" ]; then
            success "验证通过 ✓  当前 MAC: ${_real_mac}"
        else
            warn "MAC 命令执行成功，但读取到的值为: ${_real_mac}"
            warn "部分虚拟网桥可能需要重启网络后才生效"
        fi
    else
        fail "即时应用失败，将依赖重启后 init 脚本生效"
    fi

    rm -f /tmp/_mac_err
    return $([ "$_step_ok" -eq 1 ] && echo 0 || echo 1)
}

# ============================================================
#  ★ 核心：重载网络（多级回退 + 每步成功/失败提示）
# ============================================================
reload_network() {
    _if="$1"

    title "重载网络配置"
    sep
    _reload_ok=0

    # ---------- 方法1: ubus call network reload ----------
    # 最安全，只重读配置，不触碰 ifdown
    if command -v ubus >/dev/null 2>&1; then
        printf "    %-44s" "[方法1] ubus call network reload"
        if ubus call network reload 2>/tmp/_net_err; then
            success "成功 ✓"
            _reload_ok=1
        else
            fail "失败: $(cat /tmp/_net_err | head -1)"
        fi
    else
        warn "[方法1] ubus 不可用，跳过"
    fi

    # ---------- 方法2: reload_config ----------
    if [ "$_reload_ok" -eq 0 ]; then
        if command -v reload_config >/dev/null 2>&1; then
            printf "    %-44s" "[方法2] reload_config"
            if reload_config 2>/tmp/_net_err; then
                success "成功 ✓"
                _reload_ok=1
            else
                fail "失败: $(cat /tmp/_net_err | head -1)"
            fi
        else
            warn "[方法2] reload_config 不可用，跳过"
        fi
    fi

    # ---------- 方法3: 修复 ifdown 权限后再 network restart ----------
    if [ "$_reload_ok" -eq 0 ]; then
        printf "    %-44s" "[方法3] 修复 ifdown 权限 + network restart"

        # 查找 ifdown/ifup 并修复权限
        for _cmd in ifdown ifup; do
            _path=$(command -v "$_cmd" 2>/dev/null)
            if [ -n "$_path" ] && [ ! -x "$_path" ]; then
                chmod +x "$_path" 2>/dev/null
                warn "已修复 ${_path} 执行权限"
            fi
        done

        if /etc/init.d/network restart 2>/tmp/_net_err; then
            success "成功 ✓"
            _reload_ok=1
        else
            fail "失败: $(cat /tmp/_net_err | head -1)"
        fi
    fi

    # ---------- 方法4: 仅重启目标接口 ----------
    if [ "$_reload_ok" -eq 0 ]; then
        printf "    %-44s" "[方法4] 仅重启接口 ${_if}"
        if command -v ip >/dev/null 2>&1; then
            if ip link set "${_if}" down 2>/dev/null \
               && ip link set "${_if}" up 2>/dev/null; then
                success "接口重启成功 ✓"
                _reload_ok=1
            else
                fail "接口重启失败"
            fi
        elif command -v ifconfig >/dev/null 2>&1; then
            if ifconfig "${_if}" down 2>/dev/null \
               && ifconfig "${_if}" up 2>/dev/null; then
                success "接口重启成功 ✓"
                _reload_ok=1
            else
                fail "接口重启失败"
            fi
        fi
    fi

    sep
    if [ "$_reload_ok" -eq 1 ]; then
        success "网络配置重载完成 ✓"
    else
        warn "所有自动重载方法均失败"
        warn "配置已保存，请手动执行 reboot 使配置生效"
    fi

    rm -f /tmp/_net_err
    return $([ "$_reload_ok" -eq 1 ] && echo 0 || echo 1)
}

# ---- UCI 配置 ----
set_mac_uci() {
    _mac="$1"; _iface="$2"
    command -v uci >/dev/null 2>&1 || return 1
    _applied=0

    # 新版 OpenWRT 21.02+ (@device 段)
    _dev_idx=0
    while uci -q get "network.@device[${_dev_idx}]" >/dev/null 2>&1; do
        _dev_name=$(uci -q get "network.@device[${_dev_idx}].name" 2>/dev/null)
        if [ "$_dev_name" = "$_iface" ]; then
            uci set "network.@device[${_dev_idx}].macaddr=${_mac}"
            info "UCI: network.@device[${_dev_idx}].macaddr = ${_mac}"
            _applied=1; break
        fi
        _dev_idx=$((_dev_idx + 1))
    done

    # 旧版 (interface 段)
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

# ---- 生成 init.d 脚本 ----
create_init_script() {
    _mac="$1"; _iface="$2"

    if command -v ip >/dev/null 2>&1; then
        _down="ip link set ${_iface} down"
        _set="ip link set ${_iface} address ${_mac}"
        _up="ip link set ${_iface} up"
    elif command -v ifconfig >/dev/null 2>&1; then
        _down="ifconfig ${_iface} down"
        _set="ifconfig ${_iface} hw ether ${_mac}"
        _up="ifconfig ${_iface} up"
    else
        err "未找到 ip 或 ifconfig！"
        return 1
    fi

    if [ -f /etc/rc.common ]; then
        cat > "${INIT_SCRIPT}" <<INITEOF
#!/bin/sh /etc/rc.common
# MAC 固定脚本 — 自动生成
START=99

start() {
    _wait=0
    while [ ! -d "/sys/class/net/${_iface}" ] && [ "\$_wait" -lt 30 ]; do
        sleep 1; _wait=\$((_wait+1))
    done
    if [ ! -d "/sys/class/net/${_iface}" ]; then
        logger -t set_mac "接口 ${_iface} 未就绪，跳过"
        return 1
    fi
    ${_down}
    ${_set}
    ${_up}
    logger -t set_mac "${_iface} MAC 已固定为 ${_mac}"
}
INITEOF
    else
        cat > "${INIT_SCRIPT}" <<INITEOF
#!/bin/sh
### BEGIN INIT INFO
# Provides: set_mac
# Required-Start: \$network
# Default-Start: 2 3 4 5
### END INIT INFO
case "\$1" in
    start)
        [ -d "/sys/class/net/${_iface}" ] || exit 0
        ${_down}; ${_set}; ${_up}
        logger -t set_mac "${_iface} MAC 已固定为 ${_mac}" ;;
    stop) ;;
    restart) \$0 start ;;
    *) echo "Usage: \$0 {start|stop|restart}"; exit 1 ;;
esac
INITEOF
    fi

    chmod +x "${INIT_SCRIPT}"

    if [ -f /etc/rc.common ]; then
        "${INIT_SCRIPT}" enable 2>/dev/null && info "init.d 脚本已启用 (rc.common) ✓"
    elif command -v update-rc.d >/dev/null 2>&1; then
        update-rc.d set_mac defaults 2>/dev/null && info "init.d 脚本已启用 (update-rc.d) ✓"
    elif command -v chkconfig >/dev/null 2>&1; then
        chkconfig --add set_mac 2>/dev/null && info "init.d 脚本已启用 (chkconfig) ✓"
    else
        warn "未能自动注册开机自启，请手动添加"
    fi
    return 0
}

# ============================================================
#  主流程
# ============================================================

check_root

title "OpenWRT / ImmortalWrt MAC 地址修改工具"
echo "  兼容: ash / bash / dash | OpenWRT 全版本 / 全架构"

# ---- 1. 选择接口 ----
title "第1步: 选择网络接口"
interfaces=$(detect_interfaces)
if [ -n "$interfaces" ]; then
    info "检测到以下网络接口:"
    echo "$interfaces" | while read -r _if; do
        _cmac=$(get_current_mac "$_if")
        printf "   %-16s 当前MAC: %s\n" "$_if" "${_cmac:-未知}"
    done
else
    warn "未检测到网络接口，将使用默认: ${DEFAULT_IFACE}"
fi
echo ""
printf "请输入要修改的接口名称 [默认: ${DEFAULT_IFACE}]: "
read target_iface
target_iface="${target_iface:-$DEFAULT_IFACE}"

if ! iface_exists "$target_iface"; then
    warn "接口 '${target_iface}' 当前不存在。"
    printf "是否仍然继续? (y/N): "
    read _c; case "$_c" in y|Y) ;; *) info "已取消。"; exit 0 ;; esac
fi

current_mac=$(get_current_mac "$target_iface")
[ -n "$current_mac" ] && info "接口 ${target_iface} 当前 MAC: ${current_mac}"

# ---- 2. 选择 MAC ----
title "第2步: 设置 MAC 地址"
echo "  1) 自定义 MAC（直接回车使用默认）"
echo "  2) 自动生成随机 MAC"
printf "请输入选项 (1 或 2): "
read choice

case "$choice" in
    1)
        printf "请输入 MAC 地址 [默认: ${DEFAULT_MAC}]: "
        read user_mac
        if [ -z "$user_mac" ]; then
            mac_address="$DEFAULT_MAC"
            info "使用默认 MAC: $mac_address"
        else
            mac_address=$(to_upper "$user_mac")
            if ! validate_mac "$mac_address"; then
                err "无效的 MAC 地址格式！退出。"; exit 1
            fi
            info "自定义 MAC: $mac_address"
        fi
        ;;
    2)
        mac_address=$(generate_mac)
        info "自动生成 MAC: $mac_address"
        ;;
    *)
        err "无效选项！退出。"; exit 1 ;;
esac

# ---- 3. 确认 ----
title "确认"
sep
echo "  目标接口:  ${target_iface}"
echo "  当前 MAC:  ${current_mac:-未知}"
echo "  新的 MAC:  ${mac_address}"
sep
printf "确认应用以上更改? (y/N): "
read final_confirm
case "$final_confirm" in
    y|Y|yes|YES) ;;
    *) info "已取消。"; exit 0 ;;
esac

# ---- 4. 备份 ----
if [ -f "${INIT_SCRIPT}" ]; then
    cp "${INIT_SCRIPT}" "${INIT_SCRIPT}.bak.$(date +%Y%m%d%H%M%S)"
    info "已备份现有 init 脚本"
fi

# ---- 5. 写入配置 ----
title "写入持久化配置"
sep
uci_ok=0
init_ok=0

if command -v uci >/dev/null 2>&1; then
    if set_mac_uci "$mac_address" "$target_iface"; then
        uci_ok=1
        success "UCI 持久化配置写入完成 ✓"
    else
        fail "UCI 写入失败，将仅依赖 init 脚本"
    fi
fi

if create_init_script "$mac_address" "$target_iface"; then
    init_ok=1
    success "init.d 启动脚本部署完成 ✓"
else
    fail "init.d 脚本部署失败"
fi

# ---- 6. ★ 立即应用 MAC ----
apply_mac_now "$mac_address" "$target_iface"
apply_ok=$?

# ---- 7. ★ 重载网络 ----
reload_network "$target_iface"
reload_ok=$?

# ---- 8. 最终汇总 ----
title "最终结果汇总"
sep

_label_w=30
printf "  %-${_label_w}s" "UCI 持久化配置:"
[ "$uci_ok"    -eq 1 ] && success "✓ 成功" || fail    "✗ 失败/跳过"

printf "  %-${_label_w}s" "init.d 开机脚本:"
[ "$init_ok"   -eq 1 ] && success "✓ 成功" || fail    "✗ 失败"

printf "  %-${_label_w}s" "即时 MAC 应用:"
[ "$apply_ok"  -eq 0 ] && success "✓ 成功" || warn     "△ 失败(重启后生效)"

printf "  %-${_label_w}s" "网络配置重载:"
[ "$reload_ok" -eq 0 ] && success "✓ 成功" || warn     "△ 失败(重启后生效)"

sep
echo ""

# 判断整体是否需要重启
if [ "$apply_ok" -eq 0 ] && [ "$reload_ok" -eq 0 ]; then
    success "所有操作均已成功，MAC 更改已即时生效，无需重启！"
    echo ""
    _final_mac=$(get_current_mac "$target_iface")
    info "当前接口 ${target_iface} MAC 地址: ${_final_mac}"
elif [ "$uci_ok" -eq 1 ] || [ "$init_ok" -eq 1 ]; then
    warn "持久化配置已保存，但即时应用或网络重载存在问题。"
    warn "建议执行:  ${BOLD}reboot${RESET}"
else
    fail "所有操作均失败，请检查系统环境。"
    exit 1
fi

echo ""
info "如需撤销，请运行:"
echo "    ${INIT_SCRIPT} disable 2>/dev/null; rm -f ${INIT_SCRIPT}"
[ "$uci_ok" -eq 1 ] && echo "    uci delete network.lan.macaddr; uci commit network"
echo ""
