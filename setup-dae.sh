#!/bin/bash

set -euo pipefail

SCRIPT_VERSION="4.0"

DAE_CONFIG_FILE="/etc/dae/config.dae"
DAED_CONFIG_DIR="/etc/daed"
DAE_BIN_PATH="/usr/bin/dae"
DAED_BIN_PATH="/usr/bin/daed"
GEO_DIR="/usr/share/dae"
UPDATE_GEO_SCRIPT="/etc/dae/update-geo.sh"
ENV_FILE="$HOME/.dae_env"
LOG_FILE="/var/log/dae.log"
DAED_LOG_FILE="/var/log/daed.log"
LOG_SIZE_LIMIT=$((1 * 1024 * 1024))

RED='\033[0;31m';    GREEN='\033[0;32m';  YELLOW='\033[1;33m'
BLUE='\033[0;34m';   PURPLE='\033[0;35m'; CYAN='\033[0;36m'
NC='\033[0m'

LAN_IFACE_SETTING=""
LAN_IFACE=""
LAN_IP=""
WAN_IFACE=""
SERVICE_MGR="initd"
PKG_MANAGER=""
INSTALL_CMD=""

_log() { printf "${1}[%s] %s${NC}\n" "$2" "$3"; }
info()  { _log "$GREEN"  "信息" "$1"; }
warn()  { _log "$YELLOW" "警告" "$1"; }
err()   { _log "$RED"    "错误" "$1"; }
step()  { _log "$CYAN"   "步骤" "$1"; }

if [ -z "${BASH_VERSION:-}" ]; then
    printf "${RED}[错误] 需要 bash: bash %s${NC}\n" "$0"; exit 1
fi

BASH_MAJOR="${BASH_VERSION%%.*}"
if [ "${BASH_MAJOR:-0}" -lt 4 ]; then
    warn "Bash < 4.0，部分功能降级运行（不影响核心功能）"
fi

if [ "$(id -u)" != "0" ]; then
    err "请以 root 运行此脚本"; exit 1
fi

# ==================== 工具函数 ====================

is_elf_binary() {
    local f="$1"
    [ -f "$f" ] || return 1
    local magic
    magic=$(head -c4 "$f" 2>/dev/null | od -A n -t x1 | tr -d ' \n' || true)
    [ "$magic" = "7f454c46" ]
}

docker_compose_cmd() {
    if docker compose version >/dev/null 2>&1; then
        printf '%s' "docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        printf '%s' "docker-compose"
    else
        printf ''
    fi
}

log_check_size() {
    local lf sz
    for lf in "$LOG_FILE" "$DAED_LOG_FILE"; do
        [ -f "$lf" ] || continue
        sz=0
        if command -v stat >/dev/null 2>&1; then
            sz=$(stat -c%s "$lf" 2>/dev/null \
                || stat -f%z "$lf" 2>/dev/null \
                || wc -c < "$lf" 2>/dev/null \
                || echo 0)
        else
            sz=$(wc -c < "$lf" 2>/dev/null || echo 0)
        fi
        sz=$(printf '%s' "${sz}" | tr -cd '0-9')
        if [ "${sz:-0}" -gt "$LOG_SIZE_LIMIT" ]; then
            warn "$lf 超 1MB，自动轮转..."
            : > "$lf"
        fi
    done
}

load_env() { [ -f "$ENV_FILE" ] && . "$ENV_FILE" || true; }

save_env() {
    local key="$1" value="$2"
    [ ! -f "$ENV_FILE" ] && touch "$ENV_FILE" && chmod 0600 "$ENV_FILE"
    local escaped_val escaped_key
    escaped_val=$(printf '%s' "$value" | sed 's/[\&\/|]/\\&/g; s/\[/\\[/g; s/\]/\\]/g')
    escaped_key=$(printf '%s' "$key"   | sed 's/[\&\/|]/\\&/g')
    if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
        sed -i "s|^${escaped_key}=.*|${key}=\"${escaped_val}\"|" "$ENV_FILE"
    else
        printf '%s="%s"\n' "$key" "$value" >> "$ENV_FILE"
    fi
}

send_wechat_notification() {
    load_env
    [ -z "${WECHAT_WEBHOOK:-}" ] && return 0
    local msg="$1"
    local esc
    esc=$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g')
    curl -s -X POST "${WECHAT_WEBHOOK}" \
        -H 'Content-Type: application/json' \
        -d "{\"msgtype\":\"text\",\"text\":{\"content\":\"[dae] $(date '+%Y-%m-%d %H:%M:%S')\n${esc}\"}}" \
        >/dev/null 2>&1 || true
}

validate_subscription() {
    printf '%s' "$1" | grep -qE '^https?://'
}

# ==================== 内存检测 ====================
get_free_memory_mb() {
    local mb=0
    if command -v free >/dev/null 2>&1; then
        mb=$(free -m 2>/dev/null | awk '/^Mem:/{print $7}')
        [ -z "$mb" ] || [ "$mb" = "0" ] && \
            mb=$(free -m 2>/dev/null | awk '/^Mem:/{print $4}')
    fi
    [ -z "$mb" ] || [ "$mb" = "0" ] && \
        mb=$(awk '/^MemAvailable:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || true)
    [ -z "$mb" ] || [ "$mb" = "0" ] && \
        mb=$(awk '/^MemFree:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || true)
    mb=$(printf '%s' "${mb:-0}" | tr -cd '0-9')
    printf '%d' "${mb:-0}"
}

# ==================== eBPF 预检 ====================
check_ebpf_full() {
    [ -z "$SERVICE_MGR" ] && detect_system_env

    local warn_count=0
    printf "${BLUE}[预检] ══ eBPF & 系统兼容性诊断 ══${NC}\n"

    local kver major minor
    kver=$(uname -r)
    major=$(printf '%s' "$kver" | cut -d. -f1)
    minor=$(printf '%s' "$kver" | cut -d. -f2)
    printf "  内核  : ${CYAN}%s${NC}\n" "$kver"
    if [ "${major:-0}" -lt 5 ] || \
       { [ "${major:-0}" -eq 5 ] && [ "${minor:-0}" -lt 17 ]; }; then
        printf "  ${RED}✗ 内核 < 5.17，dae/daed 最低要求 5.17${NC}\n"
        warn_count=$((warn_count+1))
    else
        printf "  ${GREEN}✓ 内核版本达标${NC}\n"
    fi

    if [ -f /sys/kernel/btf/vmlinux ]; then
        printf "  ${GREEN}✓ BTF (/sys/kernel/btf/vmlinux) 存在${NC}\n"
    else
        printf "  ${RED}✗ 缺少 BTF！eBPF 加载将失败${NC}\n"
        warn_count=$((warn_count+1))
        local kname
        kname=$(uname -r)
        printf "\n  ${YELLOW}━━ BTF 缺失解决方案 ━━${NC}\n"
        if printf '%s' "$kname" | grep -qiE 'msm|qcom|sdm|sm[0-9]'; then
            printf "  高通平台: 方案1【推荐】Docker 部署 → 菜单 B\n"
            printf "           方案2  刷入支持 BTF 的主线内核\n"
        else
            printf "  方案1  重新编译内核: CONFIG_DEBUG_INFO_BTF=y\n"
            printf "  方案2  Docker 部署 → 菜单 B\n"
        fi
        printf "\n"
    fi

    if mount | grep -q 'type bpf'; then
        printf "  ${GREEN}✓ BPF FS 已挂载${NC}\n"
    else
        printf "  ${YELLOW}⚠ BPF FS 未挂载，尝试修复...${NC}\n"
        mkdir -p /sys/fs/bpf
        if mount -t bpf bpf /sys/fs/bpf 2>/dev/null; then
            printf "  ${GREEN}✓ BPF FS 挂载成功${NC}\n"
            grep -q '/sys/fs/bpf' /etc/fstab 2>/dev/null \
                || echo 'bpf /sys/fs/bpf bpf defaults 0 0' >> /etc/fstab
        else
            printf "  ${RED}✗ BPF FS 挂载失败${NC}\n"
            warn_count=$((warn_count+1))
        fi
    fi

    local free_mb
    free_mb=$(get_free_memory_mb)
    printf "  内存  : ${CYAN}%d MB 可用${NC}\n" "$free_mb"
    if [ "$free_mb" -lt 128 ]; then
        printf "  ${RED}✗ 可用内存不足 128MB！${NC}\n"
        warn_count=$((warn_count+1))
    else
        printf "  ${GREEN}✓ 内存充足${NC}\n"
    fi

    local ipfwd
    ipfwd=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)
    if [ "${ipfwd:-0}" = "1" ]; then
        printf "  ${GREEN}✓ ip_forward 已开启${NC}\n"
    else
        echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
        grep -q 'net.ipv4.ip_forward=1' /etc/sysctl.conf 2>/dev/null \
            || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1 || true
        printf "  ${GREEN}✓ ip_forward 已启用${NC}\n"
    fi

    local cfg_path=""
    for p in /proc/config.gz "/boot/config-$(uname -r)" /boot/config; do
        [ -f "$p" ] && cfg_path="$p" && break
    done

    if [ -n "$cfg_path" ]; then
        printf "  ${CYAN}内核配置: %s${NC}\n" "$cfg_path"
        local cfg_content
        if printf '%s' "$cfg_path" | grep -q '\.gz$'; then
            cfg_content=$(zcat "$cfg_path" 2>/dev/null || true)
        else
            cfg_content=$(cat "$cfg_path" 2>/dev/null || true)
        fi
        for kopt in CONFIG_BPF CONFIG_BPF_SYSCALL CONFIG_BPF_JIT \
                    CONFIG_CGROUPS CONFIG_CGROUP_BPF \
                    CONFIG_NET_CLS_BPF CONFIG_NET_CLS_ACT \
                    CONFIG_DEBUG_INFO_BTF; do
            if printf '%s' "$cfg_content" | grep -q "^${kopt}=y"; then
                printf "  ${GREEN}✓ %-32s = y${NC}\n" "$kopt"
            elif printf '%s' "$cfg_content" | grep -q "^${kopt}=m"; then
                printf "  ${YELLOW}△ %-32s = m (模块，需已加载)${NC}\n" "$kopt"
            else
                printf "  ${RED}✗ %-32s 未启用${NC}\n" "$kopt"
                [ "$kopt" = "CONFIG_DEBUG_INFO_BTF" ] && warn_count=$((warn_count+1))
            fi
        done
    else
        printf "  ${YELLOW}△ 未找到内核配置文件，跳过 CONFIG 检测${NC}\n"
    fi

    printf "\n"
    if [ "$warn_count" -gt 0 ]; then
        printf "${RED}[预检] 发现 %d 个问题，强行继续？(y/n 默认n): ${NC}" "$warn_count"
        read -r fc
        if [ "${fc:-n}" != "y" ] && [ "${fc:-n}" != "Y" ]; then
            warn "已中止。"; return 1
        fi
    else
        printf "${GREEN}[预检] ✅ 所有检测项通过！${NC}\n"
    fi
    return 0
}

# ==================== resolv.conf 修复 ====================
fix_resolv_conf() {
    local resolv="/etc/resolv.conf"
    if grep -qE '^nameserver[[:space:]]+127\.' "$resolv" 2>/dev/null; then
        warn "resolv.conf 含 127.x DNS，自动替换..."
        cp "$resolv" "${resolv}.dae-backup.$(date +%s)" 2>/dev/null || true
        printf "nameserver 223.5.5.5\nnameserver 119.29.29.29\n" > "$resolv"
        info "resolv.conf 已修复"
    fi
    if command -v systemctl >/dev/null 2>&1 \
        && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        local stub
        stub=$(grep -E '^DNSStubListener' /etc/systemd/resolved.conf 2>/dev/null \
               | tail -1 || true)
        if [ "$stub" != "DNSStubListener=no" ]; then
            warn "systemd-resolved 占用 53 端口，修复中..."
            sed -i '/^DNSStubListener/d' /etc/systemd/resolved.conf 2>/dev/null || true
            echo "DNSStubListener=no" >> /etc/systemd/resolved.conf
            systemctl restart systemd-resolved 2>/dev/null || true
            info "stub 监听已关闭"
        fi
    fi
}

# ==================== 防火墙放行 ====================
open_firewall_ports() {
    local ports="${1:-2023}"
    printf "${YELLOW}[防火墙] 放行端口: %s${NC}\n" "$ports"
    for port in $(echo "$ports" | tr ',' ' '); do
        if command -v ufw >/dev/null 2>&1 \
            && ufw status 2>/dev/null | grep -q "Status: active"; then
            ufw allow "${port}/tcp" >/dev/null 2>&1 || true
            printf "  ${GREEN}✓ ufw: %s/tcp${NC}\n" "$port"; continue
        fi
        if command -v firewall-cmd >/dev/null 2>&1 \
            && systemctl is-active --quiet firewalld 2>/dev/null; then
            firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || true
            firewall-cmd --reload >/dev/null 2>&1 || true
            printf "  ${GREEN}✓ firewalld: %s/tcp${NC}\n" "$port"; continue
        fi
        if command -v nft >/dev/null 2>&1; then
            nft add rule inet filter input tcp dport "$port" accept 2>/dev/null \
                || nft insert rule ip filter INPUT tcp dport "$port" accept 2>/dev/null \
                || true
            printf "  ${GREEN}✓ nftables: %s/tcp${NC}\n" "$port"; continue
        fi
        if command -v iptables >/dev/null 2>&1; then
            iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null \
                || iptables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
            printf "  ${GREEN}✓ iptables: %s/tcp${NC}\n" "$port"; continue
        fi
        printf "  ${YELLOW}△ 未检测到防火墙工具，请手动放行 TCP %s${NC}\n" "$port"
    done
}

# ==================== 网络资源清理 ====================
clean_network_resources() {
    printf "${YELLOW}[清理] 清理 eBPF 网络挂载资源...${NC}\n"
    if ip rule show 2>/dev/null | grep -qE "fwmark 0x1bf52|fwmark 114514"; then
        ip rule del fwmark 114514 table 114514 2>/dev/null || true
        printf "  - fwmark 114514 [${GREEN}OK${NC}]\n"
    fi
    ip route flush table 114514 2>/dev/null || true
    if ip link show dae >/dev/null 2>&1; then
        ip link delete dae 2>/dev/null || true
        printf "  - eBPF 虚接口 dae [${GREEN}OK${NC}]\n"
    fi
    for proc in dae daed; do
        if pgrep -x "$proc" >/dev/null 2>&1; then
            killall "$proc" 2>/dev/null || true
            sleep 2
            pgrep -x "$proc" >/dev/null 2>&1 && killall -9 "$proc" 2>/dev/null || true
            sleep 1
            pgrep -x "$proc" >/dev/null 2>&1 \
                && printf "  ${RED}%s 清理失败${NC}\n" "$proc" \
                || printf "  ${GREEN}%s 已清除${NC}\n" "$proc"
        fi
    done
}

# ==================== 系统环境检测 ====================
detect_system_env() {
    PKG_MANAGER=""; INSTALL_CMD=""
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt";    INSTALL_CMD="apt-get install -y --no-install-recommends"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf";    INSTALL_CMD="dnf install -y"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum";    INSTALL_CMD="yum install -y"
    elif command -v pacman >/dev/null 2>&1; then
        PKG_MANAGER="pacman"; INSTALL_CMD="pacman -Sy --noconfirm"
    elif command -v apk >/dev/null 2>&1; then
        PKG_MANAGER="apk";    INSTALL_CMD="apk add --no-cache"
    elif command -v opkg >/dev/null 2>&1; then
        PKG_MANAGER="opkg";   INSTALL_CMD="opkg install"
        opkg update >/dev/null 2>&1 || true
    elif command -v zypper >/dev/null 2>&1; then
        PKG_MANAGER="zypper"; INSTALL_CMD="zypper install -y"
    fi

    if command -v systemctl >/dev/null 2>&1 && pidof systemd >/dev/null 2>&1; then
        SERVICE_MGR="systemd"
    elif command -v rc-service >/dev/null 2>&1 && [ -d /etc/runlevels ]; then
        SERVICE_MGR="openrc"
    elif command -v procd >/dev/null 2>&1 || \
         { [ -f /etc/openwrt_release ] && command -v /etc/init.d/boot >/dev/null 2>&1; }; then
        SERVICE_MGR="procd"
    else
        SERVICE_MGR="initd"
    fi
}

check_dependencies() {
    local missing="" dep pkg
    for dep in curl unzip ip pgrep; do
        command -v "$dep" >/dev/null 2>&1 || missing="$missing $dep"
    done
    [ -z "$missing" ] && return 0
    warn "缺少依赖:$missing，正在安装..."
    [ -z "${INSTALL_CMD:-}" ] && {
        err "未找到包管理器，请手动安装:$missing"; exit 1; }
    for dep in $missing; do
        pkg="$dep"
        case "$dep" in
            ip)    [ "$PKG_MANAGER" = "opkg" ] && pkg="ip-full"   || pkg="iproute2" ;;
            pgrep) [ "$PKG_MANAGER" = "opkg" ] && pkg="procps-ng" || pkg="procps"   ;;
        esac
        $INSTALL_CMD "$pkg" >/dev/null 2>&1 || true
        command -v "$dep" >/dev/null 2>&1 || {
            err "$dep ($pkg) 安装失败！"; exit 1; }
    done
}

get_network_info() {
    if command -v uci >/dev/null 2>&1; then
        LAN_IFACE=$(uci get network.lan.device 2>/dev/null \
            || uci get network.lan.ifname 2>/dev/null || echo "br-lan")
        LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null || true)
        [ -z "${LAN_IP:-}" ] && LAN_IP=$(ip -4 addr show "$LAN_IFACE" 2>/dev/null \
            | awk '/inet /{split($2,a,"/");print a[1]}' | head -n1 || true)
        WAN_IFACE=$(uci get network.wan.device 2>/dev/null \
            || uci get network.wan.ifname 2>/dev/null || echo "eth0")
    else
        local def_iface
        def_iface=$(ip route get 8.8.8.8 2>/dev/null \
            | awk '/dev/{for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1);exit}}}' || true)
        if [ -n "${def_iface:-}" ]; then
            LAN_IFACE="$def_iface"
            WAN_IFACE="$def_iface"
            LAN_IP=$(ip -4 addr show "$LAN_IFACE" 2>/dev/null \
                | awk '/inet /{split($2,a,"/");print a[1]}' | head -n1 || true)
        fi
    fi
    if [ -z "${LAN_IP:-}" ]; then
        printf "${RED}无法自动获取网络接口，请手动输入：${NC}\n"
        printf "LAN 接口名 (如 eth0): "; read -r LAN_IFACE
        printf "接口 IP   (如 192.168.1.1): "; read -r LAN_IP
        [ -z "${LAN_IFACE:-}" ] || [ -z "${LAN_IP:-}" ] && {
            err "输入不足，退出。"; exit 1; }
        WAN_IFACE="${LAN_IFACE}"
    fi
}

smart_interface_sniffer() {
    printf "${BLUE}[嗅探] 分析物理网络接口...${NC}\n"
    local all_ifaces
    all_ifaces=$(ip -o link show 2>/dev/null \
        | awk -F': ' '{print $2}' \
        | grep -vE '^(lo|docker|veth|dae|gretun|sit|tun|bond|dummy)' || true)
    if [ -z "${all_ifaces:-}" ]; then
        LAN_IFACE_SETTING="lan_interface: ${LAN_IFACE:-auto}"; return
    fi
    printf "${YELLOW}--- 可用网卡列表 ---${NC}\n"
    local count=1
    for iface in $all_ifaces; do
        local iface_ip
        iface_ip=$(ip -4 addr show "$iface" 2>/dev/null \
            | awk '/inet /{split($2,a,"/");print a[1]}' | head -n1 || true)
        printf " %d) ${GREEN}%s${NC} [IP: ${CYAN}%s${NC}]\n" \
            "$count" "$iface" "${iface_ip:-未分配}"
        count=$((count+1))
    done
    printf "${YELLOW}输入序号选择 LAN 接口（直接回车=全选）: ${NC}"
    read -r user_choice
    if [ -z "${user_choice:-}" ]; then
        local merged=""
        for iface in $all_ifaces; do merged="${merged:+$merged, }$iface"; done
        LAN_IFACE_SETTING="lan_interface: $merged"
        printf "${GREEN}[全选] %s${NC}\n" "$merged"
    else
        local idx=1 sel=""
        for iface in $all_ifaces; do
            [ "$idx" -eq "${user_choice:-0}" ] 2>/dev/null && sel="$iface" && break
            idx=$((idx+1))
        done
        if [ -n "${sel:-}" ]; then
            LAN_IFACE_SETTING="lan_interface: $sel"
            printf "${GREEN}[精选] %s${NC}\n" "$sel"
        else
            LAN_IFACE_SETTING="lan_interface: ${LAN_IFACE:-auto}"
            printf "${RED}[越界] fallback: %s${NC}\n" "${LAN_IFACE:-auto}"
        fi
    fi
}

detect_router_mode() {
    ip route show default 2>/dev/null | grep -q "via" && echo "side" || echo "main"
}

cleanup_sing_box() {
    pgrep -x sing-box >/dev/null 2>&1 || return 0
    warn "检测到 sing-box，正在停止..."
    case "${SERVICE_MGR:-initd}" in
        systemd) systemctl stop sing-box 2>/dev/null || true ;;
        openrc)  rc-service sing-box stop 2>/dev/null || true ;;
        procd)   /etc/init.d/sing-box stop 2>/dev/null || true ;;
    esac
    killall sing-box 2>/dev/null || true
}

detect_current_mode() {
    pgrep -x daed >/dev/null 2>&1 && echo "daed" && return
    pgrep -x dae  >/dev/null 2>&1 && echo "dae"  && return
    echo "none"
}

check_mode_conflict() {
    local target_mode="$1"
    local current_mode
    current_mode=$(detect_current_mode)
    { [ "$current_mode" = "none" ] || [ "$current_mode" = "$target_mode" ]; } && return 0
    printf "${RED}[冲突] 当前运行 %s，目标 %s，不能同时运行！${NC}\n" \
        "$current_mode" "$target_mode"
    printf "停止 %s 并切换到 %s？(y/n): " "$current_mode" "$target_mode"
    read -r cf
    [ "${cf:-n}" != "y" ] && [ "${cf:-n}" != "Y" ] && {
        info "已取消。"; return 1; }
    manage_service_generic "$current_mode" "stop" 2>/dev/null || true
    clean_network_resources
    return 0
}

# ==================== 订阅链接收集 ====================
collect_subscriptions() {
    printf "\n${CYAN}══ 订阅链接配置 ══${NC}\n"
    printf "${YELLOW}请逐一输入订阅链接（v2ray/base64 格式，不支持 Clash）${NC}\n"
    printf "${YELLOW}输入完成后直接回车继续下一步，不输入直接回车则结束输入${NC}\n\n"

    local idx=1
    SUB_NAMES=""
    SUB_LINES=""

    while true; do
        printf "${CYAN}订阅 %d URL（留空结束）: ${NC}" "$idx"
        read -r sub_url
        [ -z "${sub_url:-}" ] && break

        if ! validate_subscription "$sub_url"; then
            warn "URL 必须以 http:// 或 https:// 开头，请重新输入"
            continue
        fi

        local sub_name="sub${idx}"
        printf "${CYAN}为此订阅命名（直接回车使用默认名 '%s'）: ${NC}" "$sub_name"
        read -r custom_name
        [ -n "${custom_name:-}" ] && sub_name="$custom_name"

        sub_name=$(printf '%s' "$sub_name" | tr -cd 'a-zA-Z0-9_')
        [ -z "$sub_name" ] && sub_name="sub${idx}"

        SUB_LINES="${SUB_LINES}    ${sub_name}: '${sub_url}'\n"
        SUB_NAMES="${SUB_NAMES}${sub_name},"
        printf "${GREEN}  ✓ 已添加: %s${NC}\n" "$sub_name"
        idx=$((idx+1))
    done

    if [ -z "${SUB_LINES:-}" ]; then
        warn "未输入任何订阅，配置将使用空订阅（需安装后在 daed 面板添加）"
        SUB_LINES="    # 请在 daed 面板中添加订阅\n"
        SUB_NAMES=""
    fi

    SUB_NAMES="${SUB_NAMES%,}"
    printf "${GREEN}订阅配置完成，共 %d 条${NC}\n" "$((idx-1))"
}

# ==================== GEO 数据更新 ====================
create_geo_update_script() {
    mkdir -p "$(dirname "$UPDATE_GEO_SCRIPT")"
    cat > "$UPDATE_GEO_SCRIPT" << 'GEOEOF'
#!/bin/sh
GEO_DIR="/usr/share/dae"
mkdir -p "$GEO_DIR"

dl() {
    local url="$1" out="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 30 -o "${out}.tmp" "$url" \
            && mv "${out}.tmp" "$out" && return 0
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -qO "${out}.tmp" "$url" \
            && mv "${out}.tmp" "$out" && return 0
    fi
    echo "[GEO 错误] 缺少 curl/wget"; return 1
}

echo "[GEO] 同步 geoip.dat..."
dl "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" \
   "$GEO_DIR/geoip.dat" || exit 1

echo "[GEO] 同步 geosite.dat..."
dl "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" \
   "$GEO_DIR/geosite.dat" || exit 1

chmod 644 "$GEO_DIR/geoip.dat" "$GEO_DIR/geosite.dat"

for d in /etc/dae /etc/daed; do
    mkdir -p "$d"
    ln -sf "$GEO_DIR/geoip.dat"   "$d/geoip.dat"   2>/dev/null || true
    ln -sf "$GEO_DIR/geosite.dat" "$d/geosite.dat" 2>/dev/null || true
done

for svc in dae daed; do
    pgrep -x "$svc" >/dev/null 2>&1 || continue
    echo "[GEO] $svc 运行中，热重载..."
    if command -v systemctl >/dev/null 2>&1 && pidof systemd >/dev/null 2>&1; then
        systemctl reload-or-restart "$svc" 2>/dev/null || true
    elif [ -f "/etc/init.d/$svc" ]; then
        "/etc/init.d/$svc" restart 2>/dev/null || true
    else
        killall -HUP "$svc" 2>/dev/null || true
    fi
done
echo "[GEO] 同步完成"
GEOEOF
    chmod +x "$UPDATE_GEO_SCRIPT"
}

update_geo_data() {
    [ ! -f "$UPDATE_GEO_SCRIPT" ] && create_geo_update_script
    mkdir -p "$GEO_DIR" /etc/dae /etc/daed
    printf "${YELLOW}[GEO] 拉取中...${NC}\n"
    sh "$UPDATE_GEO_SCRIPT"
    printf "${GREEN}✅ GEO 同步完成${NC}\n"
}

# ==================== 架构映射 ====================
resolve_arch() {
    local machine
    machine=$(uname -m)
    case "$machine" in
        x86_64)              echo "x86_64"     ;;
        aarch64|arm64)       echo "arm64"       ;;
        armv7*|armv7l|armhf) echo "armv7"       ;;
        riscv64)             echo "riscv64"     ;;
        loongarch64|loong64) echo "loongarch64" ;;
        i386|i686)           echo "x86"         ;;
        *)
            err "不支持的架构: $machine"
            return 1 ;;
    esac
}

# ==================== dae 配置生成 ====================
generate_dae_config() {
    [ -z "${LAN_IFACE_SETTING:-}" ] && LAN_IFACE_SETTING="lan_interface: auto"

    collect_subscriptions

    local sub_section="$SUB_LINES"

    local filter_expr="subtag(my_sub)"
    if [ -n "${SUB_NAMES:-}" ]; then
        local first_name
        first_name=$(printf '%s' "$SUB_NAMES" | cut -d',' -f1)
        filter_expr="subtag(${first_name})"
        if printf '%s' "$SUB_NAMES" | grep -q ','; then
            filter_expr="subtag(${SUB_NAMES//,/, })"
        fi
    fi

    mkdir -p "$(dirname "$DAE_CONFIG_FILE")" "$GEO_DIR"

    cat > "$DAE_CONFIG_FILE" << EOF
global {
    tproxy_port: 12345
    tproxy_port_protect: true
    pprof_port: 0
    so_mark_from_dae: 0

    log_level: error
    allow_insecure: false
    mptcp: false

    disable_waiting_network: true

    enable_local_tcp_fast_redirect: false

    ${LAN_IFACE_SETTING}
    wan_interface: auto
    auto_config_kernel_parameter: true

    tcp_check_url: 'http://cp.cloudflare.com,1.1.1.1,2606:4700:4700::1111'
    tcp_check_http_method: HEAD
    udp_check_dns: 'dns.alidns.com:53,8.8.8.8,2001:4860:4860::8888'

    check_interval: 30s
    check_tolerance: 50ms

    dial_mode: domain++

    sniffing_timeout: 100ms
    tls_implementation: tls
    utls_imitate: chrome_auto

    fallback_resolver: '223.5.5.5:53'

    bandwidth_max_tx: '200 mbps'
    bandwidth_max_rx: '1 gbps'
}

subscription {
$(printf '%b' "$sub_section")}

node {}

dns {
    ipversion_prefer: 4

    upstream {
        alidns:    'udp://dns.alidns.com:53'
        googledns: 'tcp+udp://dns.google:53'
    }

    routing {
        request {
            qtype(https) -> reject

            qname(keyword:m-team)    -> alidns
            qname(keyword:rousi)     -> alidns
            qname(keyword:nicept)    -> alidns
            qname(keyword:0ff)       -> alidns
            qname(keyword:xingtan)   -> alidns
            qname(suffix:118112.xyz) -> alidns
            qname(keyword:synology)  -> alidns

            qname(geosite:apple)             -> alidns
            qname(geosite:steam@cn)          -> alidns
            qname(geosite:tencent)           -> alidns
            qname(geosite:category-games@cn) -> alidns
            qname(geosite:cn)                -> alidns

            qname(keyword:gemini)    -> googledns
            qname(keyword:javdb)     -> googledns
            qname(keyword:javbus)    -> googledns
            qname(geosite:google)    -> googledns
            qname(geosite:tiktok)    -> googledns
            qname(geosite:netflix)   -> googledns
            qname(geosite:telegram)  -> googledns
            qname(geosite:twitter)   -> googledns
            qname(geosite:github)    -> googledns
            qname(geosite:openai)    -> googledns
            qname(geosite:youtube)   -> googledns
            qname(geosite:spotify)   -> googledns
            qname(geosite:microsoft) -> googledns
            qname(geosite:notion)    -> googledns
            qname(geosite:geolocation-!cn) -> googledns

            fallback: googledns
        }

        response {
            upstream(googledns) -> accept
            ip(geoip:private) && !qname(geosite:cn) -> googledns
            fallback: accept
        }
    }
}

group {
    proxy {
        filter: ${filter_expr}
        policy: min_moving_avg
    }

    ai {
        filter: ${filter_expr}
        policy: min_moving_avg
    }
}

routing {
    pname(dnsmasq, dropbear) -> must_direct

    dip(223.5.5.5, 223.6.6.6)       -> direct
    domain(full:dns.alidns.com)      -> direct
    dip(119.29.29.29, 119.28.28.28) -> direct
    domain(full:doh.pub)             -> direct

    dip(8.8.8.8, 8.8.4.4)          -> proxy
    domain(full:dns.google)          -> proxy
    dip(1.1.1.1, 1.0.0.1)          -> proxy
    domain(full:one.one.one.one)     -> proxy

    dip(224.0.0.0/3, 'ff00::/8') -> must_direct
    dip(geoip:private) -> direct

    l4proto(udp) && dport(443) -> block

    domain(geosite:category-ads-all) -> block

    dport(36881) -> direct

    domain(keyword:m-team)    -> direct
    domain(keyword:rousi)     -> direct
    domain(keyword:nicept)    -> direct
    domain(keyword:0ff)       -> direct
    domain(keyword:xingtan)   -> direct
    domain(suffix:118112.xyz) -> direct
    domain(keyword:synology)  -> direct

    domain(geosite:apple)             -> direct
    domain(geosite:steam@cn)          -> direct
    domain(geosite:tencent)           -> direct
    domain(geosite:category-games@cn) -> direct
    domain(geosite:cn)                -> direct
    dip(geoip:cn)                     -> direct

    domain(geosite:google)   -> proxy
    domain(geosite:tiktok)   -> proxy
    domain(geosite:netflix)  -> proxy
    domain(geosite:telegram) -> proxy
    domain(geosite:twitter)  -> proxy
    domain(geosite:youtube)  -> proxy
    domain(geosite:spotify)  -> proxy

    domain(keyword:gemini)    -> ai
    domain(keyword:javdb)     -> ai
    domain(keyword:javbus)    -> ai
    domain(geosite:github)    -> ai
    domain(geosite:openai)    -> ai
    domain(geosite:microsoft) -> ai
    domain(geosite:notion)    -> ai

    domain(geosite:geolocation-!cn) -> proxy

    fallback: proxy
}
EOF

    chmod 0600 "$DAE_CONFIG_FILE"
    info "配置文件已生成: $DAE_CONFIG_FILE"

    if [ ! -f "$GEO_DIR/geoip.dat" ] || [ ! -f "$GEO_DIR/geosite.dat" ]; then
        warn "GEO 缺失，自动拉取..."
        update_geo_data
    fi

    if command -v dae >/dev/null 2>&1; then
        step "校验配置语法..."
        if dae validate -c "$DAE_CONFIG_FILE" > /tmp/dae_validate.log 2>&1; then
            info "配置语法校验通过"
        else
            err "语法错误："
            cat /tmp/dae_validate.log
        fi
    fi
}

# ==================== 通用服务管理 ====================
manage_service_generic() {
    local svc="$1"
    local action="$2"

    local bin_path desc cfg_or_dir log_path
    if [ "$svc" = "daed" ]; then
        bin_path="$DAED_BIN_PATH"
        cfg_or_dir="$DAED_CONFIG_DIR"
        desc="daed eBPF Proxy with Web Dashboard"
        log_path="$DAED_LOG_FILE"
    else
        bin_path="$DAE_BIN_PATH"
        cfg_or_dir="$DAE_CONFIG_FILE"
        desc="dae eBPF Transparent Proxy"
        log_path="$LOG_FILE"
    fi

    case "${SERVICE_MGR:-initd}" in
        systemd)
            case "$action" in
                status)
                    systemctl is-active --quiet "$svc" 2>/dev/null \
                        && printf "${GREEN}%s 运行中${NC}\n" "$svc" \
                        || printf "${RED}%s 未运行${NC}\n" "$svc" ;;
                enable|disable|start|stop|restart)
                    systemctl "$action" "$svc" 2>/dev/null || true ;;
            esac ;;

        openrc)
            case "$action" in
                start|stop|restart) rc-service "$svc" "$action" 2>/dev/null || true ;;
                enable)  rc-update add "$svc" default 2>/dev/null || true ;;
                disable) rc-update del "$svc" default 2>/dev/null || true ;;
                status)  rc-service "$svc" status 2>/dev/null || true ;;
            esac ;;

        procd|initd)
            if [ -f "/etc/init.d/${svc}" ]; then
                case "$action" in
                    start|stop|restart|enable|disable)
                        "/etc/init.d/${svc}" "$action" 2>/dev/null || true ;;
                    status)
                        pgrep -x "$svc" >/dev/null \
                            && printf "${GREEN}%s 运行中${NC}\n" "$svc" \
                            || printf "${RED}%s 已停止${NC}\n" "$svc" ;;
                esac
            else
                case "$action" in
                    start)
                        if [ "$svc" = "daed" ]; then
                            nohup "$bin_path" run > "$log_path" 2>&1 &
                        else
                            nohup "$bin_path" run -c "$cfg_or_dir" > "$log_path" 2>&1 &
                        fi
                        printf "${GREEN}%s 已后台启动${NC}\n" "$svc" ;;
                    stop)
                        killall "$svc" 2>/dev/null || true ;;
                    restart)
                        killall "$svc" 2>/dev/null || true; sleep 1
                        if [ "$svc" = "daed" ]; then
                            nohup "$bin_path" run > "$log_path" 2>&1 &
                        else
                            nohup "$bin_path" run -c "$cfg_or_dir" > "$log_path" 2>&1 &
                        fi
                        printf "${GREEN}%s 已重启${NC}\n" "$svc" ;;
                    enable|disable)
                        printf "${YELLOW}[提示] %s 下 %s 开机自启需手动配置${NC}\n" \
                            "$SERVICE_MGR" "$svc" ;;
                    status)
                        pgrep -x "$svc" >/dev/null \
                            && printf "${GREEN}%s 运行中${NC}\n" "$svc" \
                            || printf "${RED}%s 已停止${NC}\n" "$svc" ;;
                esac
            fi ;;
    esac
}

manage_service() { manage_service_generic "dae" "$1"; }

# ==================== 服务状态诊断 ====================
print_service_live_status() {
    local svc="${1:-dae}"
    step "$svc 服务状态验证..."
    sleep 2
    if pgrep -x "$svc" >/dev/null 2>&1; then
        local pid
        pid=$(pgrep -x "$svc" | head -n1)
        printf "  状态: ${GREEN}● 活跃${NC} | PID: ${CYAN}%s${NC}\n" "$pid"
        if [ "$svc" = "daed" ]; then
            printf "  面板: ${GREEN}http://%s:2023${NC}\n" "${LAN_IP:-localhost}"
            printf "  GraphQL: ${CYAN}http://%s:2023/graphql${NC}\n" "${LAN_IP:-localhost}"
        fi
        return 0
    else
        printf "  状态: ${RED}■ 停止/启动失败${NC}\n"
        local logf="$LOG_FILE"
        [ "$svc" = "daed" ] && logf="$DAED_LOG_FILE"
        printf "  ${YELLOW}查看日志: tail -n 30 %s${NC}\n" "$logf"
        return 1
    fi
}

# ==================== 服务单元安装 ====================
install_service_unit() {
    local svc="${1:-dae}"

    local bin_path desc cfg_or_dir log_path
    if [ "$svc" = "daed" ]; then
        bin_path="$DAED_BIN_PATH"
        cfg_or_dir="$DAED_CONFIG_DIR"
        desc="daed eBPF Proxy with Web Dashboard"
        log_path="$DAED_LOG_FILE"
    else
        bin_path="$DAE_BIN_PATH"
        cfg_or_dir="$DAE_CONFIG_FILE"
        desc="dae eBPF Transparent Proxy"
        log_path="$LOG_FILE"
    fi

    local exec_start
    if [ "$svc" = "daed" ]; then
        exec_start="${bin_path} run"
    else
        exec_start="${bin_path} run -c ${cfg_or_dir}"
    fi

    case "${SERVICE_MGR:-initd}" in
        systemd)
            local unit_file="/etc/systemd/system/${svc}.service"
            if [ ! -f "$unit_file" ]; then
                cat > "$unit_file" << EOF
[Unit]
Description=${desc}
Documentation=https://github.com/daeuniverse/dae
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${exec_start}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
                systemctl daemon-reload
                info "systemd: ${svc}.service 已安装"
            fi ;;

        openrc)
            if [ ! -f "/etc/init.d/${svc}" ]; then
                cat > "/etc/init.d/${svc}" << EOF
#!/sbin/openrc-run
description="${desc}"
command="${bin_path}"
command_args="run${svc:+ }$([ "$svc" = "dae" ] && echo "-c ${cfg_or_dir}" || echo "")"
command_background=true
pidfile="/run/${svc}.pid"
depend() { need net; }
EOF
                chmod +x "/etc/init.d/${svc}"
                rc-update add "$svc" default 2>/dev/null || true
                info "OpenRC: /etc/init.d/${svc} 已安装"
            fi ;;

        procd)
            if [ ! -f "/etc/init.d/${svc}" ]; then
                cat > "/etc/init.d/${svc}" << EOF
#!/bin/sh /etc/rc.common
START=95
STOP=10
USE_PROCD=1
start_service() {
    procd_open_instance
    procd_set_param command ${exec_start}
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param respawn 3600 5 5
    procd_close_instance
}
EOF
                chmod +x "/etc/init.d/${svc}"
                "/etc/init.d/${svc}" enable 2>/dev/null || true
                info "procd: /etc/init.d/${svc} 已安装"
            fi ;;

        initd)
            if [ ! -f "/etc/init.d/${svc}" ]; then
                cat > "/etc/init.d/${svc}" << EOF
#!/bin/sh
### BEGIN INIT INFO
# Provides:          ${svc}
# Required-Start:    \$network
# Required-Stop:     \$network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: ${desc}
### END INIT INFO
BIN="${bin_path}"
LOG="${log_path}"
case "\$1" in
    start)   nohup "\$BIN" ${exec_start#${bin_path} } > "\$LOG" 2>&1 & ;;
    stop)    killall ${svc} 2>/dev/null || true ;;
    restart) \$0 stop; sleep 1; \$0 start ;;
    status)  pgrep -x ${svc} >/dev/null && echo "running" || echo "stopped" ;;
    *)       echo "Usage: \$0 {start|stop|restart|status}" ;;
esac
EOF
                chmod +x "/etc/init.d/${svc}"
                update-rc.d "$svc" defaults 2>/dev/null || true
                info "SysVinit: /etc/init.d/${svc} 已安装"
            fi ;;
    esac
}

# ==================== daed 面板安装/更新 ====================
install_daed_panel() {
    printf "\n${CYAN}═══════════════════════════════════════${NC}\n"
    printf "${CYAN}   🖥️  daed Web 面板安装/更新          ${NC}\n"
    printf "${CYAN}═══════════════════════════════════════${NC}\n"

    check_mode_conflict "daed" || return 1
    check_ebpf_full || warn "预检有问题，但您选择继续。"

    local target_arch
    target_arch=$(resolve_arch) || return 1
    printf "${CYAN}[架构] %s${NC}\n" "$target_arch"

    step "拉取 daed 发行版列表..."
    local release_list
    release_list=$(curl -fsSL --connect-timeout 15 \
        "https://api.github.com/repos/daeuniverse/daed/releases" 2>/dev/null || true)
    [ -z "${release_list:-}" ] && { err "无法获取版本列表，请检查网络。"; return 1; }

    local version_list
    version_list=$(printf '%s' "$release_list" \
        | grep '"tag_name":' \
        | sed -E 's/.*"([^"]+)".*/\1/' \
        | head -n 5)
    [ -z "${version_list:-}" ] && { err "版本列表解析失败。"; return 1; }

    local current_version="未安装"
    if [ -f "$DAED_BIN_PATH" ] && [ -x "$DAED_BIN_PATH" ]; then
        current_version=$("$DAED_BIN_PATH" --version 2>/dev/null \
            | awk 'NR==1{print $3}' | head -n1 || echo "未知")
    fi

    printf "当前版本: ${GREEN}%s${NC}\n" "$current_version"
    printf "${PURPLE}可选版本:${NC}\n"
    local count=1
    while IFS= read -r v; do
        [ -z "$v" ] && continue
        [ $count -eq 1 ] \
            && printf " %d) %s ${YELLOW}(最新)${NC}\n" "$count" "$v" \
            || printf " %d) %s\n" "$count" "$v"
        count=$((count+1))
    done << VEREOF
$version_list
VEREOF
    printf " 0) 取消\n"

    printf "输入序号 [0-%d]: " "$((count-1))"
    read -r choice
    local selected_version=""
    case "${choice:-0}" in
        [1-5]) selected_version=$(printf '%s\n' "$version_list" | sed -n "${choice}p") ;;
        0) info "已取消。"; return 0 ;;
        *) err "无效输入。"; return 1 ;;
    esac
    [ -z "${selected_version:-}" ] && { err "版本选择失败。"; return 1; }

    local installed=0
    local base_url="https://github.com/daeuniverse/daed/releases/download/${selected_version}"

    if [ "$PKG_MANAGER" = "apt" ] && [ "$installed" -eq 0 ]; then
        local deb_url="${base_url}/installer-daed-linux-${target_arch}.deb"
        local tmp_deb="/tmp/daed-installer.$$.deb"
        step "尝试 .deb 包..."
        local hc
        hc=$(curl -fsSL -w "%{http_code}" --connect-timeout 60 \
            -o "$tmp_deb" "$deb_url" 2>/dev/null || echo "000")
        if [ "$hc" = "200" ] && dpkg-deb -I "$tmp_deb" >/dev/null 2>&1; then
            dpkg -i "$tmp_deb" 2>/dev/null || true
            apt-get --fix-broken install -y >/dev/null 2>&1 || true
            command -v daed >/dev/null 2>&1 && installed=1 \
                && info ".deb 包安装成功"
            rm -f "$tmp_deb"
        else
            rm -f "$tmp_deb"
            warn ".deb 下载失败 (HTTP $hc)，尝试裸二进制..."
        fi
    fi

    if [ "$PKG_MANAGER" = "dnf" ] || [ "$PKG_MANAGER" = "yum" ]; then
        local rpm_url="${base_url}/installer-daed-linux-${target_arch}.rpm"
        local tmp_rpm="/tmp/daed-installer.$$.rpm"
        step "尝试 .rpm 包..."
        local hc
        hc=$(curl -fsSL -w "%{http_code}" --connect-timeout 60 \
            -o "$tmp_rpm" "$rpm_url" 2>/dev/null || echo "000")
        if [ "$hc" = "200" ]; then
            rpm -ivh "$tmp_rpm" 2>/dev/null || true
            command -v daed >/dev/null 2>&1 && installed=1 \
                && info ".rpm 包安装成功"
            rm -f "$tmp_rpm"
        else
            rm -f "$tmp_rpm"
            warn ".rpm 下载失败 (HTTP $hc)，尝试裸二进制..."
        fi
    fi

    if [ "$PKG_MANAGER" = "zypper" ] && [ "$installed" -eq 0 ]; then
        local rpm_url="${base_url}/installer-daed-linux-${target_arch}.rpm"
        local tmp_rpm="/tmp/daed-installer.$$.rpm"
        step "尝试 openSUSE .rpm 包..."
        local hc
        hc=$(curl -fsSL -w "%{http_code}" --connect-timeout 60 \
            -o "$tmp_rpm" "$rpm_url" 2>/dev/null || echo "000")
        if [ "$hc" = "200" ]; then
            zypper install -y "$tmp_rpm" 2>/dev/null || true
            command -v daed >/dev/null 2>&1 && installed=1 \
                && info ".rpm(zypper) 安装成功"
            rm -f "$tmp_rpm"
        else
            rm -f "$tmp_rpm"
            warn "zypper .rpm 失败，尝试裸二进制..."
        fi
    fi

    if [ "$installed" -eq 0 ]; then
        local bin_url="${base_url}/daed-linux-${target_arch}"
        local tmp_bin="/tmp/daed-bin.$$"
        step "尝试裸二进制..."
        local hc
        hc=$(curl -fsSL -w "%{http_code}" --connect-timeout 60 \
            -o "$tmp_bin" "$bin_url" 2>/dev/null || echo "000")
        if [ "$hc" != "200" ] || ! is_elf_binary "$tmp_bin"; then
            rm -f "$tmp_bin"
            local zip_url="${bin_url}.zip"
            local tmp_zip="/tmp/daed-bin.$$.zip"
            step "尝试 .zip 包..."
            hc=$(curl -fsSL -w "%{http_code}" --connect-timeout 60 \
                -o "$tmp_zip" "$zip_url" 2>/dev/null || echo "000")
            if [ "$hc" = "200" ] && unzip -t "$tmp_zip" >/dev/null 2>&1; then
                local td="/tmp/daed-unzip-$$"
                mkdir -p "$td"
                unzip -o "$tmp_zip" -d "$td" >/dev/null 2>&1
                local ef
                ef=$(find "$td" -type f ! -name "*.zip" ! -name "*.md" \
                    ! -name "*.txt" | head -n1 || true)
                [ -n "${ef:-}" ] && mv "$ef" "$tmp_bin"
                rm -rf "$td" "$tmp_zip"
            else
                rm -f "$tmp_bin" "$tmp_zip" 2>/dev/null || true
                err "所有下载方式均失败！"
                return 1
            fi
        fi
        if is_elf_binary "$tmp_bin"; then
            install -Dm755 "$tmp_bin" "$DAED_BIN_PATH"
            rm -f "$tmp_bin"
            installed=1
            info "裸二进制安装成功"
        else
            rm -f "$tmp_bin"
            err "ELF 校验失败，中止安装。"
            return 1
        fi
    fi

    local actual_ver
    actual_ver=$("$DAED_BIN_PATH" --version 2>/dev/null \
        | awk 'NR==1{print $3}' | head -n1 || echo "未知")
    info "已安装版本: $actual_ver"

    mkdir -p "$DAED_CONFIG_DIR"
    chmod 0700 "$DAED_CONFIG_DIR"
    [ ! -f "$GEO_DIR/geoip.dat" ] || [ ! -f "$GEO_DIR/geosite.dat" ] && update_geo_data
    install_service_unit "daed"
    open_firewall_ports "2023"
    fix_resolv_conf

    printf "\n${GREEN}╔══════════════════════════════════════════════╗${NC}\n"
    printf "${GREEN}║  ✅ daed 安装完成！版本: %-20s║${NC}\n" "$selected_version"
    printf "${GREEN}║  🌐 面板: http://%-27s║${NC}\n" "${LAN_IP:-localhost}:2023"
    printf "${GREEN}╚══════════════════════════════════════════════╝${NC}\n"

    printf "\n立即启动 daed 服务？(y/n): "; read -r start_now
    if [ "${start_now:-n}" = "y" ] || [ "${start_now:-n}" = "Y" ]; then
        manage_service_generic "daed" "enable" 2>/dev/null || true
        manage_service_generic "daed" "start"
        print_service_live_status "daed"
    else
        printf "${YELLOW}手动启动: %s run${NC}\n" "$DAED_BIN_PATH"
    fi
    send_wechat_notification "daed ${selected_version} 已安装"
}

# ==================== Docker Compose 部署 ====================
install_daed_docker_compose() {
    command -v docker >/dev/null 2>&1 \
        || { err "未检测到 Docker。"; return 1; }

    local DC_CMD
    DC_CMD=$(docker_compose_cmd)
    [ -z "$DC_CMD" ] && {
        err "未找到 docker compose 或 docker-compose，请先安装。"
        return 1
    }
    printf "${CYAN}[Docker] 使用: %s${NC}\n" "$DC_CMD"

    if [ ! -f /sys/kernel/btf/vmlinux ]; then
        err "缺少 BTF，daed 容器启动将失败！"
        printf "强行继续？(y/n): "; read -r f
        [ "${f:-n}" != "y" ] && [ "${f:-n}" != "Y" ] && return 0
    fi

    if ! mount | grep -q 'type bpf'; then
        mkdir -p /sys/fs/bpf
        mount -t bpf bpf /sys/fs/bpf 2>/dev/null \
            || { err "BPF FS 挂载失败。"; return 1; }
    fi

    printf "\n${PURPLE}选择镜像源:${NC}\n"
    printf " 1) Docker Hub  : daeuniverse/daed:latest\n"
    printf " 2) GHCR        : ghcr.io/daeuniverse/daed:latest\n"
    printf " 3) Quay.io     : quay.io/daeuniverse/daed:latest\n"
    printf "选择 [1-3, 默认2]: "; read -r img_choice
    local daed_image
    case "${img_choice:-2}" in
        1) daed_image="daeuniverse/daed:latest" ;;
        3) daed_image="quay.io/daeuniverse/daed:latest" ;;
        *) daed_image="ghcr.io/daeuniverse/daed:latest" ;;
    esac

    mkdir -p "$DAED_CONFIG_DIR"
    local compose_file="$DAED_CONFIG_DIR/docker-compose.yml"
    cat > "$compose_file" << EOF
services:
  daed:
    image: ${daed_image}
    container_name: daed
    privileged: true
    network_mode: host
    pid: host
    restart: always
    volumes:
      - /sys:/sys
      - /etc/daed:/etc/daed
EOF

    info "Compose 文件: $compose_file"
    update_geo_data
    open_firewall_ports "2023"

    step "拉取 $daed_image..."
    docker pull "$daed_image" || { err "镜像拉取失败。"; return 1; }

    step "启动容器..."
    $DC_CMD -f "$compose_file" up -d

    sleep 3
    if [ "$(docker inspect -f '{{.State.Running}}' daed 2>/dev/null)" = "true" ]; then
        printf "\n${GREEN}╔══════════════════════════════════════════╗${NC}\n"
        printf "${GREEN}║  🎉 daed Docker 容器启动成功！           ║${NC}\n"
        printf "${GREEN}║  面板: http://%-27s║${NC}\n" "${LAN_IP:-localhost}:2023"
        printf "${GREEN}╚══════════════════════════════════════════╝${NC}\n"
        send_wechat_notification "daed Docker 已启动 http://${LAN_IP:-localhost}:2023"
    else
        err "容器异常退出："
        docker logs --tail=20 daed 2>/dev/null || true
    fi
}

# ==================== dae CLI 安装/更新 ====================
upgrade_dae_core() {
    printf "\n${CYAN}--- ⚡ dae CLI 安装/更新 ---${NC}\n"
    check_mode_conflict "dae" || return 1
    check_ebpf_full || true

    local target_arch
    target_arch=$(resolve_arch) || return 1

    step "拉取 dae 发行版列表..."
    local release_list
    release_list=$(curl -fsSL --connect-timeout 15 \
        "https://api.github.com/repos/daeuniverse/dae/releases" 2>/dev/null || true)
    [ -z "${release_list:-}" ] && { err "无法获取版本列表。"; return 1; }

    local version_list
    version_list=$(printf '%s' "$release_list" \
        | grep '"tag_name":' \
        | sed -E 's/.*"([^"]+)".*/\1/' \
        | head -n 5)
    [ -z "${version_list:-}" ] && { err "版本列表解析失败。"; return 1; }

    local current_version="未安装"
    if [ -f "$DAE_BIN_PATH" ] && [ -x "$DAE_BIN_PATH" ]; then
        current_version=$("$DAE_BIN_PATH" --version 2>/dev/null \
            | awk 'NR==1{print $3}' | head -n1 || echo "未知")
    fi

    printf "当前版本: ${GREEN}%s${NC}\n" "$current_version"
    printf "${PURPLE}可选版本:${NC}\n"
    local count=1
    while IFS= read -r v; do
        [ -z "$v" ] && continue
        [ $count -eq 1 ] \
            && printf " %d) %s ${YELLOW}(最新)${NC}\n" "$count" "$v" \
            || printf " %d) %s\n" "$count" "$v"
        count=$((count+1))
    done << VEREOF
$version_list
VEREOF
    printf " 0) 取消\n"

    printf "输入序号 [0-%d]: " "$((count-1))"
    read -r choice
    local selected_version=""
    case "${choice:-0}" in
        [1-5]) selected_version=$(printf '%s\n' "$version_list" | sed -n "${choice}p") ;;
        0) info "已取消。"; return 0 ;;
        *) err "无效输入。"; return 1 ;;
    esac
    [ -z "${selected_version:-}" ] && { err "版本选择失败。"; return 1; }

    local download_url="https://github.com/daeuniverse/dae/releases/download/${selected_version}/dae-linux-${target_arch}.zip"
    local tmp_zip="/tmp/dae-update.$$.zip"

    step "下载 dae ${selected_version} (${target_arch})..."
    local http_code
    http_code=$(curl -fsSL -w "%{http_code}" --connect-timeout 60 \
        -o "$tmp_zip" "$download_url" 2>/dev/null || echo "000")

    if [ "$http_code" != "200" ] || ! unzip -t "$tmp_zip" >/dev/null 2>&1; then
        err "下载失败 (HTTP $http_code) 或 ZIP 损坏。"
        rm -f "$tmp_zip"; return 1
    fi

    manage_service_generic "dae" "stop"
    clean_network_resources

    local tmp_dir="/tmp/dae-unzip-$$"
    mkdir -p "$tmp_dir"
    unzip -o "$tmp_zip" -d "$tmp_dir" >/dev/null 2>&1
    local dae_file
    dae_file=$(find "$tmp_dir" -type f -name "dae-linux-*" \
        ! -name "*.zip" ! -name "*.md" | head -n1 || true)

    if [ -n "${dae_file:-}" ] && is_elf_binary "$dae_file"; then
        install -Dm755 "$dae_file" "$DAE_BIN_PATH"
        rm -rf "$tmp_dir" "$tmp_zip"
        local actual_ver
        actual_ver=$("$DAE_BIN_PATH" --version 2>/dev/null \
            | awk 'NR==1{print $3}' | head -n1 || echo "未知")
        info "dae 安装完成: $actual_ver ($target_arch)"
    else
        rm -rf "$tmp_dir" "$tmp_zip"
        err "解压失败或非 ELF 二进制。"
        return 1
    fi

    install_service_unit "dae"
    fix_resolv_conf

    if [ ! -f "$DAE_CONFIG_FILE" ]; then
        warn "首次安装：请执行菜单 3 同步规则，再执行菜单 2 生成配置。"
    else
        manage_service_generic "dae" "start"
        print_service_live_status "dae"
    fi
    send_wechat_notification "dae 更新至 ${selected_version} (${target_arch})"
}

# ==================== 定时任务 ====================
set_geo_update_schedule() {
    command -v crontab >/dev/null 2>&1 \
        || { err "未安装 crontab。"; return 1; }
    printf " 1) 每天凌晨 3 点\n 2) 每周一凌晨 3 点\n 3) 每月 1 日凌晨 3 点\n"
    printf "选择 [1-3]: "; read -r freq
    local sched
    case "${freq:-2}" in
        1) sched="0 3 * * *" ;;
        2) sched="0 3 * * 1" ;;
        3) sched="0 3 1 * *" ;;
        *) sched="0 3 * * 1" ;;
    esac
    (crontab -l 2>/dev/null | grep -v "$UPDATE_GEO_SCRIPT"; \
     printf '%s %s >/dev/null 2>&1\n' "$sched" "$UPDATE_GEO_SCRIPT") | crontab -
    info "定时任务已设置: $sched"
}

# ==================== 卸载 ====================
uninstall_all() {
    printf "\n${RED}--- ☠️ 彻底卸载（dae + daed）---${NC}\n"
    printf "${YELLOW}将删除所有二进制、配置、GEO、服务。确认？(y/n): ${NC}"
    read -r confirm
    [ "${confirm:-n}" != "y" ] && [ "${confirm:-n}" != "Y" ] \
        && { info "已取消。"; return; }

    for svc in dae daed; do
        manage_service_generic "$svc" "stop"    2>/dev/null || true
        manage_service_generic "$svc" "disable" 2>/dev/null || true
    done
    clean_network_resources
    docker rm -f dae-container daed 2>/dev/null || true

    rm -f "$DAE_BIN_PATH" "$DAED_BIN_PATH" \
        /etc/systemd/system/dae.service \
        /etc/systemd/system/daed.service \
        /etc/init.d/dae /etc/init.d/daed \
        "$ENV_FILE"
    rm -rf /etc/dae /etc/daed /usr/share/dae

    command -v crontab >/dev/null 2>&1 \
        && (crontab -l 2>/dev/null | grep -v "$UPDATE_GEO_SCRIPT") | crontab - || true
    [ "${SERVICE_MGR:-}" = "systemd" ] && systemctl daemon-reload 2>/dev/null || true
    info "已完全卸载。"
    send_wechat_notification "dae/daed 已彻底卸载"
}

display_side_router_tip() {
    [ "$(detect_router_mode)" != "side" ] && return
    printf "\n${YELLOW}💡 旁路由提示：主路由需配置：${NC}\n"
    printf "  1. DHCP 网关和 DNS 指向本机: ${CYAN}%s${NC}\n" "${LAN_IP:-<本机IP>}"
    printf "  2. 放行端口 12345 (tproxy) 和 2023 (daed 面板)\n"
}

# ==================== 主菜单 ====================
main_menu() {
    detect_system_env
    check_dependencies
    [ "${1:-}" != "--no-clean" ] && clean_network_resources
    get_network_info
    fix_resolv_conf
    cleanup_sing_box
    load_env

    while true; do
        log_check_size

        local cur_mode mode_display
        cur_mode=$(detect_current_mode)
        case "$cur_mode" in
            dae)  mode_display="${GREEN}● dae CLI 运行中${NC}"  ;;
            daed) mode_display="${GREEN}● daed 面板运行中${NC}" ;;
            none) mode_display="${RED}■ 未运行${NC}"            ;;
            *)    mode_display="${YELLOW}? 未知${NC}"           ;;
        esac

        local free_mb
        free_mb=$(get_free_memory_mb)

        printf "\n"
        printf "${GREEN}═══════════════════════════════════════════════════════════${NC}\n"
        printf "${GREEN}   🦢 dae 全平台管家 v%s${NC}\n" "$SCRIPT_VERSION"
        printf "   系统: ${CYAN}%s %s${NC} | 内核: ${PURPLE}%s${NC}\n" \
            "$(uname -s)" "${SERVICE_MGR:-?}" "$(uname -r)"
        printf "   架构: ${PURPLE}%s${NC} | 内存: ${CYAN}%d MB 可用${NC}\n" \
            "$(uname -m)" "$free_mb"
        printf "   接口: ${GREEN}%s${NC} | IP: ${GREEN}%s${NC} | 拓扑: ${CYAN}%s路由${NC}\n" \
            "${LAN_IFACE:-?}" "${LAN_IP:-?}" "$(detect_router_mode)"
        printf "   状态: "; printf "$mode_display\n"
        printf "${GREEN}═══════════════════════════════════════════════════════════${NC}\n"
        printf "\n  ${CYAN}── 面板模式（daed）──${NC}\n"
        printf "  A) 🖥️  安装/更新 daed Web 面板\n"
        printf "  B) 🐳  Docker Compose 一键部署 daed\n"
        printf "  C) ⚙️  daed 服务控制（启动/停止/重启/状态）\n"
        printf "  D) 🔎  查看 daed 实时日志\n"
        printf "\n  ${CYAN}── CLI 模式（dae）──${NC}\n"
        printf "  1) ⚡  安装/更新 dae CLI 核心\n"
        printf "  2) ✍️  生成 dae 配置（含订阅链接交互式录入）\n"
        printf "  3) 🔄  立即同步 GEO 规则数据库\n"
        printf "  4) 🗓️  设置 GEO 定时自动更新\n"
        printf "  5) ⚙️  dae 服务控制（启动/停止/重启/状态）\n"
        printf "  6) 🔎  查看 dae 实时日志\n"
        printf "\n  ${CYAN}── 系统工具 ──${NC}\n"
        printf "  7) 🔬  eBPF & 内核兼容性完整预检\n"
        printf "  8) 🔔  配置企业微信 Webhook 通知\n"
        printf "  ${RED}U) ☠️  彻底卸载 dae + daed 全部组件${NC}\n"
        printf "  0) 退出\n"
        printf "${GREEN}═══════════════════════════════════════════════════════════${NC}\n"
        printf "请输入选项: "
        read -r choice

        case "${choice:-}" in
            [Aa]) install_daed_panel ;;

            [Bb]) install_daed_docker_compose ;;

            [Cc])
                printf "  1) 启动  2) 停止  3) 重启  4) 状态\n"
                printf "选择 [1-4]: "; read -r sact
                case "${sact:-}" in
                    1) clean_network_resources
                       manage_service_generic "daed" "start"
                       print_service_live_status "daed" ;;
                    2) manage_service_generic "daed" "stop"
                       clean_network_resources
                       info "daed 已停止。" ;;
                    3) clean_network_resources
                       manage_service_generic "daed" "restart"
                       print_service_live_status "daed" ;;
                    4) manage_service_generic "daed" "status" ;;
                    *) err "无效选项。" ;;
                esac ;;

            [Dd])
                if [ -f "$DAED_LOG_FILE" ] && [ -s "$DAED_LOG_FILE" ]; then
                    printf "${YELLOW}daed 日志（Ctrl+C 退出）...${NC}\n"
                    tail -f "$DAED_LOG_FILE"
                elif command -v journalctl >/dev/null 2>&1 \
                    && [ "${SERVICE_MGR:-}" = "systemd" ]; then
                    journalctl -u daed -f
                elif docker ps 2>/dev/null | grep -q daed; then
                    docker logs -f daed
                else
                    warn "daed 日志不存在或为空。请先启动服务（选项 C → 1）。"
                fi ;;

            1) upgrade_dae_core ;;

            2)
                smart_interface_sniffer
                check_mode_conflict "dae" || continue
                generate_dae_config
                display_side_router_tip
                manage_service_generic "dae" "enable" 2>/dev/null || true
                clean_network_resources
                manage_service_generic "dae" "restart"
                print_service_live_status "dae"
                send_wechat_notification "dae 配置已更新" ;;

            3) update_geo_data ;;
            4) set_geo_update_schedule ;;

            5)
                printf "  1) 启动  2) 停止  3) 重启  4) 状态\n"
                printf "选择 [1-4]: "; read -r sact
                case "${sact:-}" in
                    1) clean_network_resources
                       manage_service_generic "dae" "start"
                       print_service_live_status "dae" ;;
                    2) manage_service_generic "dae" "stop"
                       clean_network_resources ;;
                    3) clean_network_resources
                       manage_service_generic "dae" "restart"
                       print_service_live_status "dae" ;;
                    4) manage_service_generic "dae" "status" ;;
                    *) err "无效选项。" ;;
                esac ;;

            6)
                if [ -f "$LOG_FILE" ] && [ -s "$LOG_FILE" ]; then
                    printf "${YELLOW}dae 日志（Ctrl+C 退出）...${NC}\n"
                    tail -f "$LOG_FILE"
                elif command -v journalctl >/dev/null 2>&1 \
                    && [ "${SERVICE_MGR:-}" = "systemd" ]; then
                    journalctl -u dae -f
                else
                    warn "dae 日志不存在或为空。请先启动服务（选项 5 → 1）。"
                fi ;;

            7) check_ebpf_full ;;

            8)
                printf "企业微信 Webhook URL（留空清除）: "; read -r wx_url
                WECHAT_WEBHOOK="${wx_url:-}"
                save_env "WECHAT_WEBHOOK" "${wx_url:-}"
                [ -n "${wx_url:-}" ] \
                    && info "Webhook 已绑定。" \
                    || warn "Webhook 已清除。" ;;

            [Uu]) uninstall_all ;;

            0) info "退出，祝网络畅通！"; exit 0 ;;

            *) err "无效选项「${choice:-}」。" ;;
        esac

        printf "${CYAN}按 Enter 返回主菜单...${NC}"; read -r _dummy
    done
}

main_menu "$@"
