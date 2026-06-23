#!/bin/bash
set -uo pipefail

# ==================== 全局常量 ====================
SCRIPT_VERSION="3.2 (Full Bug-Fix Edition)"

DAE_CONFIG_FILE="/etc/dae/config.dae"
DAED_CONFIG_DIR="/etc/daed"
DAE_BIN_PATH="/usr/bin/dae"
DAED_BIN_PATH="/usr/bin/daed"
GEO_DIR="/usr/share/dae"
PERSIST_DIR="/etc/dae/persist.d"
UPDATE_GEO_SCRIPT="/etc/dae/update-geo.sh"
ENV_FILE="$HOME/.dae_env"
LOG_FILE="/var/log/dae.log"
DAED_LOG_FILE="/var/log/daed.log"
LOG_SIZE_LIMIT=$((1 * 1024 * 1024))   # 1 MB

# 颜色
RED='\033[0;31m';    GREEN='\033[0;32m';  YELLOW='\033[1;33m'
BLUE='\033[0;34m';   PURPLE='\033[0;35m'; CYAN='\033[0;36m'
NC='\033[0m'

# [B3] 全局变量预初始化，防止 set -u 触发 unbound variable
LAN_IFACE_SETTING=""
LAN_IFACE=""
LAN_IP=""
WAN_IFACE=""          # [B12]
SERVICE_MGR="initd"
PKG_MANAGER=""
INSTALL_CMD=""

# ── bash 检测 ──
if [ -z "${BASH_VERSION:-}" ]; then
    printf "${RED}[错误] 需要 bash: bash %s${NC}\n" "$0"
    exit 1
fi

# ── root 检测 ──
if [ "$(id -u)" != "0" ]; then
    printf "${RED}[错误] 请以 root 运行此脚本${NC}\n"
    exit 1
fi

# ==================== 工具函数 ====================

# [B5] ELF 魔数校验（不依赖 file 命令）
is_elf_binary() {
    local f="$1"
    [ -f "$f" ] || return 1
    # ELF 魔数：0x7f 'E' 'L' 'F'
    local magic
    magic=$(head -c4 "$f" 2>/dev/null | od -A n -t x1 | tr -d ' \n' || true)
    [ "$magic" = "7f454c46" ]
}

# [B6] Docker Compose 命令检测
docker_compose_cmd() {
    if docker compose version >/dev/null 2>&1; then
        echo "docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        echo "docker-compose"
    else
        echo ""
    fi
}

log_check_size() {
    for lf in "$LOG_FILE" "$DAED_LOG_FILE"; do
        [ -f "$lf" ] || continue
        local sz
        sz=$(stat -c%s "$lf" 2>/dev/null || echo 0)
        if [ "${sz:-0}" -gt "$LOG_SIZE_LIMIT" ]; then
            printf "${YELLOW}[日志] %s 超 1MB，自动轮转...${NC}\n" "$lf"
            : > "$lf"
        fi
    done
}

load_env()  { [ -f "$ENV_FILE" ] && . "$ENV_FILE" || true; }

save_env() {
    local key="$1" value="$2"
    [ ! -f "$ENV_FILE" ] && touch "$ENV_FILE" && chmod 0600 "$ENV_FILE"
    # [B: 原 save_env 用 | 分隔符但未转义 |]  → 改用 python-safe 转义
    local escaped
    escaped=$(printf '%s' "$value" | sed 's/[&\\|]/\\&/g')
    if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=\"${escaped}\"|" "$ENV_FILE"
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
        -d "{\"msgtype\":\"text\",\"text\":{\"content\":\"【大鹅助手】\n时间：$(date '+%Y-%m-%d %H:%M:%S')\n详情：${esc}\"}}" \
        >/dev/null 2>&1 || true
}

validate_subscription() {
    printf '%s' "$1" | grep -qE '^https?://'
}

# ==================== [B1] 内存检测（多路 fallback）====================
get_free_memory_mb() {
    local mb=0

    # 路径1: free -m 第7列（available，procps >= 3.3.10）
    if command -v free >/dev/null 2>&1; then
        mb=$(free -m 2>/dev/null | awk '/^Mem:/{print $7}')
        # [B10] 某些旧版 free 只有6列，$7 为空
        if [ -z "$mb" ] || [ "$mb" = "0" ]; then
            # 路径2: free -m 第4列（free，旧版格式）
            mb=$(free -m 2>/dev/null | awk '/^Mem:/{print $4}')
        fi
    fi

    # 路径3: /proc/meminfo MemAvailable
    if [ -z "$mb" ] || [ "$mb" = "0" ]; then
        mb=$(awk '/^MemAvailable:/{printf "%d", $2/1024}' \
            /proc/meminfo 2>/dev/null || true)
    fi

    # 路径4: /proc/meminfo MemFree（最后手段）
    if [ -z "$mb" ] || [ "$mb" = "0" ]; then
        mb=$(awk '/^MemFree:/{printf "%d", $2/1024}' \
            /proc/meminfo 2>/dev/null || true)
    fi

    # 确保是整数
    mb=$(printf '%s' "${mb:-0}" | tr -cd '0-9')
    printf '%d' "${mb:-0}"
}

# ==================== [B8][B14] eBPF 完整预检 ====================
check_ebpf_full() {
    # [B8] 确保 SERVICE_MGR 已初始化
    [ -z "$SERVICE_MGR" ] && detect_system_env

    local warn=0
    printf "${BLUE}[预检] ══ eBPF & 系统兼容性诊断 ══${NC}\n"

    # ── 内核版本 ──
    local kver major minor
    kver=$(uname -r)
    major=$(printf '%s' "$kver" | cut -d. -f1)
    minor=$(printf '%s' "$kver" | cut -d. -f2)
    printf "  内核  : ${CYAN}%s${NC}\n" "$kver"
    if [ "${major:-0}" -lt 5 ] || \
       { [ "${major:-0}" -eq 5 ] && [ "${minor:-0}" -lt 17 ]; }; then
        printf "  ${RED}✗ 内核 < 5.17，dae/daed 最低要求 5.17${NC}\n"
        warn=$((warn+1))
    else
        printf "  ${GREEN}✓ 内核版本达标${NC}\n"
    fi

    # ── [B14] BTF 检测 + 嵌入式设备专项指引 ──
    if [ -f /sys/kernel/btf/vmlinux ]; then
        printf "  ${GREEN}✓ BTF (/sys/kernel/btf/vmlinux) 存在${NC}\n"
    else
        printf "  ${RED}✗ 缺少 BTF！dae eBPF 加载将直接失败${NC}\n"
        warn=$((warn+1))

        # 识别设备类型给出针对性建议
        local kname
        kname=$(uname -r)
        printf "\n  ${YELLOW}━━ BTF 缺失解决方案 ━━${NC}\n"

        # msm8916 / 高通 ARM 设备（如用户当前环境）
        if printf '%s' "$kname" | grep -qiE 'msm|qcom|sdm|sm[0-9]'; then
            printf "  ${CYAN}当前设备识别为高通（Qualcomm/MSM）平台：${NC}\n"
            printf "  方案1【推荐】用 Docker 部署（无需 BTF，镜像自带运行环境）:\n"
            printf "         → 菜单选项 B\n"
            printf "  方案2  刷入支持 BTF 的主线内核固件:\n"
            printf "         → 搜索 'Armbian %s BTF kernel' 或使用 mainline-kernel\n" "$kname"
            printf "  方案3  使用 pahole 手动生成 BTF（高级用户）:\n"
            printf "         apt install dwarves\n"
            printf "         pahole --btf_encode_detached=/sys/kernel/btf/vmlinux vmlinux\n"

        # Rockchip / 全志 / 瑞芯微 ARM SBC
        elif printf '%s' "$kname" | grep -qiE 'rockchip|rk[0-9]|sun[0-9]|allwinner|h[0-9]{2,3}'; then
            printf "  ${CYAN}当前设备识别为 Rockchip/全志 ARM SBC 平台：${NC}\n"
            printf "  方案1【推荐】刷入 Armbian 官方 current/edge 内核（已含 BTF）:\n"
            printf "         armbian-config → System → Other kernels → current\n"
            printf "  方案2  Docker 部署（绕过 BTF 要求）:\n"
            printf "         → 菜单选项 B\n"

        # OpenWRT / 路由器
        elif command -v opkg >/dev/null 2>&1 || [ -f /etc/openwrt_release ]; then
            printf "  ${CYAN}当前设备识别为 OpenWRT 路由器：${NC}\n"
            printf "  ${RED}⚠️  OpenWRT 标准内核不含 BTF，dae 官方不推荐在 OpenWRT 上直接运行！${NC}\n"
            printf "  方案1【推荐】使用支持 BTF 的第三方固件（如 ImmortalWRT 23.05+）:\n"
            printf "         https://immortalwrt.org/\n"
            printf "  方案2  旁路由模式：在主路由旁挂一台 x86/ARM 设备跑 dae\n"

        # 通用 ARM / x86 设备
        else
            printf "  ${CYAN}通用建议：${NC}\n"
            printf "  方案1  重新编译内核时启用:\n"
            printf "         CONFIG_DEBUG_INFO_BTF=y\n"
            printf "         CONFIG_DEBUG_INFO=y\n"
            printf "  方案2  Debian/Ubuntu 安装 BTF 增强内核:\n"
            printf "         apt install linux-image-\$(uname -r)-dbgsym  # 或\n"
            printf "         apt install linux-image-generic-hwe-22.04\n"
            printf "  方案3  Docker 部署（镜像内置运行时）:\n"
            printf "         → 菜单选项 B\n"
        fi
        printf "\n"
    fi

    # ── BPF 文件系统 ──
    if mount | grep -q 'type bpf'; then
        printf "  ${GREEN}✓ BPF FS (/sys/fs/bpf) 已挂载${NC}\n"
    else
        printf "  ${YELLOW}⚠ BPF FS 未挂载，尝试自动修复...${NC}\n"
        mkdir -p /sys/fs/bpf
        if mount -t bpf bpf /sys/fs/bpf 2>/dev/null; then
            printf "  ${GREEN}✓ BPF FS 挂载成功${NC}\n"
            grep -q '/sys/fs/bpf' /etc/fstab 2>/dev/null \
                || echo 'bpf /sys/fs/bpf bpf defaults 0 0' >> /etc/fstab
        else
            printf "  ${RED}✗ BPF FS 挂载失败（内核未编译 CONFIG_BPF_SYSCALL）${NC}\n"
            warn=$((warn+1))
        fi
    fi

    # ── [B1] 内存检测 ──
    local free_mb
    free_mb=$(get_free_memory_mb)
    printf "  内存  : ${CYAN}%d MB 可用${NC}\n" "$free_mb"
    if [ "$free_mb" -lt 128 ]; then
        printf "  ${RED}✗ 可用内存不足 128MB，eBPF 加载阶段可能 OOM！${NC}\n"
        warn=$((warn+1))
    else
        printf "  ${GREEN}✓ 内存充足${NC}\n"
    fi

    # ── ip_forward ──
    local ipfwd
    ipfwd=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)
    if [ "${ipfwd:-0}" = "1" ]; then
        printf "  ${GREEN}✓ ip_forward 开启${NC}\n"
    else
        echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
        grep -q 'net.ipv4.ip_forward=1' /etc/sysctl.conf 2>/dev/null \
            || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1 || true
        printf "  ${GREEN}✓ ip_forward 已修复${NC}\n"
    fi

    # ── 内核 CONFIG 检测（有内核配置文件时）──
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
                    CONFIG_NET_CLS_BPF CONFIG_NET_ACT_BPF \
                    CONFIG_DEBUG_INFO_BTF; do
            if printf '%s' "$cfg_content" | grep -q "^${kopt}=y"; then
                printf "  ${GREEN}✓ %-32s = y${NC}\n" "$kopt"
            elif printf '%s' "$cfg_content" | grep -q "^${kopt}=m"; then
                printf "  ${YELLOW}△ %-32s = m（模块，需已加载）${NC}\n" "$kopt"
            else
                printf "  ${RED}✗ %-32s 未启用${NC}\n" "$kopt"
                [ "$kopt" = "CONFIG_DEBUG_INFO_BTF" ] && warn=$((warn+1))
            fi
        done
    else
        printf "  ${YELLOW}△ 未找到内核配置文件，跳过逐项 CONFIG 检测${NC}\n"
    fi

    # ── 汇总 ──
    printf "\n"
    if [ "$warn" -gt 0 ]; then
        printf "${RED}[预检] 发现 %d 个关键问题，强行继续？(y/n 默认n): ${NC}" "$warn"
        read -r fc
        if [ "${fc:-n}" != "y" ] && [ "${fc:-n}" != "Y" ]; then
            printf "${YELLOW}[预检] 已中止，请根据上方建议解决后重试。${NC}\n"
            return 1
        fi
    else
        printf "${GREEN}[预检] ✅ 所有检测项通过，系统就绪！${NC}\n"
    fi
    return 0
}

# ==================== resolv.conf 修复 ====================
fix_resolv_conf() {
    local resolv="/etc/resolv.conf"
    if grep -qE '^nameserver[[:space:]]+127\.' "$resolv" 2>/dev/null; then
        printf "${YELLOW}[修复] resolv.conf 含 127.x DNS（循环依赖），自动替换...${NC}\n"
        cp "$resolv" "${resolv}.dae-backup.$(date +%s)" 2>/dev/null || true
        printf "nameserver 223.5.5.5\nnameserver 119.29.29.29\n" > "$resolv"
        printf "${GREEN}[修复] resolv.conf 已修复${NC}\n"
    fi
    # systemd-resolved stub 占用 53 端口
    if command -v systemctl >/dev/null 2>&1 \
        && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        local stub
        stub=$(grep -E '^DNSStubListener' /etc/systemd/resolved.conf 2>/dev/null \
               | tail -1 || true)
        if [ "$stub" != "DNSStubListener=no" ]; then
            printf "${YELLOW}[修复] systemd-resolved 占用 53 端口，修复中...${NC}\n"
            sed -i '/^DNSStubListener/d' /etc/systemd/resolved.conf 2>/dev/null || true
            echo "DNSStubListener=no" >> /etc/systemd/resolved.conf
            systemctl restart systemd-resolved 2>/dev/null || true
            printf "${GREEN}[修复] stub 监听已关闭${NC}\n"
        fi
    fi
}

# ==================== [B9] 防火墙放行 2023 端口 ====================
open_firewall_port_2023() {
    local port="2023"
    printf "${YELLOW}[防火墙] 放行 TCP %s 端口（daed 面板）...${NC}\n" "$port"

    # ufw
    if command -v ufw >/dev/null 2>&1 \
        && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${port}/tcp" >/dev/null 2>&1 || true
        printf "  ${GREEN}✓ ufw: 已放行 %s/tcp${NC}\n" "$port"
        return
    fi

    # firewalld
    if command -v firewall-cmd >/dev/null 2>&1 \
        && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        printf "  ${GREEN}✓ firewalld: 已放行 %s/tcp${NC}\n" "$port"
        return
    fi

    # [B9] nftables：不假设表名，在 INPUT 链方向直接追加
    if command -v nft >/dev/null 2>&1; then
        # 先尝试 inet filter input，若不存在则创建
        if nft list chain inet filter input >/dev/null 2>&1; then
            nft add rule inet filter input tcp dport "$port" accept 2>/dev/null || true
            printf "  ${GREEN}✓ nftables (inet filter input): 已放行 %s/tcp${NC}\n" "$port"
        elif nft list chain ip filter INPUT >/dev/null 2>&1; then
            nft add rule ip filter INPUT tcp dport "$port" accept 2>/dev/null || true
            printf "  ${GREEN}✓ nftables (ip filter INPUT): 已放行 %s/tcp${NC}\n" "$port"
        else
            # 创建最小规则集
            nft add table inet filter_dae 2>/dev/null || true
            nft add chain inet filter_dae input \
                '{ type filter hook input priority 0; }' 2>/dev/null || true
            nft add rule inet filter_dae input tcp dport "$port" accept 2>/dev/null || true
            printf "  ${GREEN}✓ nftables: 创建 inet filter_dae 表并放行 %s/tcp${NC}\n" "$port"
        fi
        return
    fi

    # iptables（兜底）
    if command -v iptables >/dev/null 2>&1; then
        iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null \
            || iptables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
        printf "  ${GREEN}✓ iptables: 已放行 %s/tcp${NC}\n" "$port"
        return
    fi

    printf "  ${YELLOW}△ 未检测到防火墙管理工具，请手动放行 TCP %s 端口${NC}\n" "$port"
}

# ==================== 网络资源清理 ====================
clean_network_resources() {
    printf "${YELLOW}[清理] 清理 eBPF 网络挂载资源...${NC}\n"

    if ip rule show 2>/dev/null | grep -qE "fwmark 0x1bf52|fwmark 114514"; then
        ip rule del fwmark 114514 table 114514 2>/dev/null || true
        printf "  - fwmark 114514 已清除 [${GREEN}OK${NC}]\n"
    else
        printf "  - 无 fwmark 残留 [${CYAN}干净${NC}]\n"
    fi

    ip route flush table 114514 2>/dev/null || true

    if ip link show dae >/dev/null 2>&1; then
        ip link delete dae 2>/dev/null || true
        printf "  - eBPF 虚接口 dae 已销毁 [${GREEN}OK${NC}]\n"
    fi

    # [B16] 同时清理 dae 和 daed 进程
    for proc in dae daed; do
        if pgrep -x "$proc" >/dev/null 2>&1; then
            local pids
            pids=$(pgrep -x "$proc" | tr '\n' ' ')
            printf "${YELLOW}  - 终止 %s (PID: %s)...${NC}\n" "$proc" "$pids"
            killall "$proc" 2>/dev/null || true
            sleep 2
            if pgrep -x "$proc" >/dev/null 2>&1; then
                printf "${RED}  - 强制 kill -9 %s...${NC}\n" "$proc"
                killall -9 "$proc" 2>/dev/null || true
                sleep 1
            fi
            pgrep -x "$proc" >/dev/null 2>&1 \
                && printf "  - ${RED}%s 清理失败！${NC}\n" "$proc" \
                || printf "  - ${GREEN}%s 已清除${NC}\n" "$proc"
        fi
    done
}

# ==================== 多系统环境检测 ====================
detect_system_env() {
    PKG_MANAGER=""
    INSTALL_CMD=""

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
    fi

    if command -v systemctl >/dev/null 2>&1 && pidof systemd >/dev/null 2>&1; then
        SERVICE_MGR="systemd"
    elif command -v rc-service >/dev/null 2>&1 && [ -d /etc/runlevels ]; then
        SERVICE_MGR="openrc"
    elif command -v procd >/dev/null 2>&1 || [ -f /etc/init.d/boot ]; then
        SERVICE_MGR="procd"
    else
        SERVICE_MGR="initd"
    fi
}

check_dependencies() {
    local missing=""
    for dep in curl unzip ip pgrep; do
        command -v "$dep" >/dev/null 2>&1 || missing="$missing $dep"
    done
    [ -z "$missing" ] && return 0

    printf "${YELLOW}缺少依赖:%s，正在安装...${NC}\n" "$missing"
    [ -z "${INSTALL_CMD:-}" ] && {
        printf "${RED}未找到包管理器，请手动安装:%s${NC}\n" "$missing"; exit 1; }

    for dep in $missing; do
        local pkg="$dep"
        case "$dep" in
            ip)    [ "$PKG_MANAGER" = "opkg" ] && pkg="ip-full"  || pkg="iproute2" ;;
            pgrep) [ "$PKG_MANAGER" = "opkg" ] && pkg="procps-ng" || pkg="procps"  ;;
            unzip) [ "$PKG_MANAGER" = "opkg" ] && pkg="unzip"    ;;
        esac
        $INSTALL_CMD "$pkg" >/dev/null 2>&1 || true
        command -v "$dep" >/dev/null 2>&1 || {
            printf "${RED}%s (%s) 安装失败，请手动安装！${NC}\n" "$dep" "$pkg"
            exit 1
        }
    done
}

get_network_info() {
    if command -v uci >/dev/null 2>&1; then
        LAN_IFACE=$(uci get network.lan.device 2>/dev/null \
            || uci get network.lan.ifname 2>/dev/null \
            || echo "br-lan")
        LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null || true)
        [ -z "${LAN_IP:-}" ] && LAN_IP=$(ip -4 addr show "$LAN_IFACE" 2>/dev/null \
            | awk '/inet /{split($2,a,"/");print a[1]}' | head -n1 || true)
        WAN_IFACE=$(uci get network.wan.device 2>/dev/null \
            || uci get network.wan.ifname 2>/dev/null \
            || echo "eth0")   # [B12] 合理缺省值
    else
        local def_iface
        def_iface=$(ip route get 8.8.8.8 2>/dev/null \
            | awk '/dev/{print $5;exit}' || true)
        if [ -n "${def_iface:-}" ]; then
            LAN_IFACE="$def_iface"
            WAN_IFACE="$def_iface"    # [B12]
            LAN_IP=$(ip -4 addr show "$LAN_IFACE" 2>/dev/null \
                | awk '/inet /{split($2,a,"/");print a[1]}' | head -n1 || true)
        fi
    fi

    if [ -z "${LAN_IP:-}" ]; then
        printf "${RED}无法自动获取网络接口，请手动输入：${NC}\n"
        printf "LAN 接口名 (如 eth0): ";  read -r LAN_IFACE
        printf "接口 IP (如 192.168.1.1): "; read -r LAN_IP
        [ -z "${LAN_IFACE:-}" ] || [ -z "${LAN_IP:-}" ] && {
            printf "${RED}输入不足，退出。${NC}\n"; exit 1; }
        WAN_IFACE="${LAN_IFACE}"    # [B12]
    fi
}

smart_interface_sniffer() {
    printf "${BLUE}[嗅探] 分析物理网络接口...${NC}\n"
    local all_ifaces
    all_ifaces=$(ip -o link show 2>/dev/null \
        | awk -F': ' '{print $2}' \
        | grep -vE '^(lo|docker|veth|dae|gretun|sit|tun|bond|dummy)' \
        || true)

    if [ -z "${all_ifaces:-}" ]; then
        printf "${YELLOW}[嗅探] 未找到物理网卡，使用当前 LAN 接口: %s${NC}\n" \
            "${LAN_IFACE:-auto}"
        LAN_IFACE_SETTING="lan_interface: ${LAN_IFACE:-auto}"
        return
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
        for iface in $all_ifaces; do
            merged="${merged:+$merged, }$iface"
        done
        LAN_IFACE_SETTING="lan_interface: $merged"
        printf "${GREEN}[全选] 绑定所有接口: %s${NC}\n" "$merged"
    else
        local idx=1 sel=""
        for iface in $all_ifaces; do
            [ "$idx" -eq "${user_choice:-0}" ] 2>/dev/null && sel="$iface" && break
            idx=$((idx+1))
        done
        if [ -n "${sel:-}" ]; then
            LAN_IFACE_SETTING="lan_interface: $sel"
            printf "${GREEN}[精选] 绑定: %s${NC}\n" "$sel"
        else
            LAN_IFACE_SETTING="lan_interface: ${LAN_IFACE:-auto}"
            printf "${RED}[越界] fallback 到默认: %s${NC}\n" "${LAN_IFACE:-auto}"
        fi
    fi
}

detect_router_mode() {
    ip route show default 2>/dev/null | grep -q "via" && echo "side" || echo "main"
}

cleanup_sing_box() {
    pgrep -x sing-box >/dev/null 2>&1 || return 0
    printf "${YELLOW}[冲突] 检测到 sing-box，正在停止...${NC}\n"
    case "${SERVICE_MGR:-initd}" in
        systemd) systemctl stop sing-box 2>/dev/null || true ;;
        openrc)  rc-service sing-box stop 2>/dev/null || true ;;
        procd)   /etc/init.d/sing-box stop 2>/dev/null || true ;;
    esac
    killall sing-box 2>/dev/null || true
}

# ==================== 运行模式互斥检测 ====================
detect_current_mode() {
    pgrep -x daed >/dev/null 2>&1 && echo "daed" && return
    pgrep -x dae  >/dev/null 2>&1 && echo "dae"  && return
    echo "none"
}

check_mode_conflict() {
    local target_mode="$1"
    local current_mode
    current_mode=$(detect_current_mode)
    [ "$current_mode" = "none" ] || [ "$current_mode" = "$target_mode" ] && return 0

    printf "${RED}╔══════════════════════════════════════════════════════╗${NC}\n"
    printf "${RED}║  ⚠️  模式冲突：当前运行 %-6s  目标切换 %-6s      ║${NC}\n" \
        "$current_mode" "$target_mode"
    printf "${RED}║  dae 与 daed 不能同时运行！                          ║${NC}\n"
    printf "${RED}╚══════════════════════════════════════════════════════╝${NC}\n"
    printf "停止 %s 并切换到 %s？(y/n): " "$current_mode" "$target_mode"
    read -r cf
    [ "${cf:-n}" != "y" ] && [ "${cf:-n}" != "Y" ] && {
        printf "${GREEN}已取消。${NC}\n"; return 1; }
    manage_service_generic "$current_mode" "stop" 2>/dev/null || true
    clean_network_resources
    return 0
}

# ==================== 通用服务管理 ====================
manage_service_generic() {
    local svc="$1"
    local action="$2"

    case "${SERVICE_MGR:-initd}" in
        systemd)
            case "$action" in
                status)
                    systemctl is-active --quiet "$svc" 2>/dev/null \
                        && printf "${GREEN}%s 活跃运行中${NC}\n" "$svc" \
                        || printf "${RED}%s 未运行${NC}\n" "$svc" ;;
                enable|disable|start|stop|restart)
                    systemctl "$action" "$svc" 2>/dev/null || true ;;
            esac ;;

        openrc)
            case "$action" in
                start|stop|restart)
                    rc-service "$svc" "$action" 2>/dev/null || true ;;
                enable)  rc-update add "$svc" default 2>/dev/null || true ;;
                disable) rc-update del "$svc" default 2>/dev/null || true ;;
                status)  rc-service "$svc" status 2>/dev/null || true ;;
            esac ;;

        procd|initd)  # [B7] 补全 enable/disable
            local bin_path="$DAE_BIN_PATH"
            local log_path="$LOG_FILE"
            local cfg_arg="-c $DAE_CONFIG_FILE"
            if [ "$svc" = "daed" ]; then
                bin_path="$DAED_BIN_PATH"
                log_path="$DAED_LOG_FILE"
                # [B13] 目录路径含空格时安全包裹
                cfg_arg="-c \"$DAED_CONFIG_DIR\""
            fi

            if [ -f "/etc/init.d/${svc}" ]; then
                case "$action" in
                    start|stop|restart)
                        "/etc/init.d/${svc}" "$action" 2>/dev/null || true ;;
                    enable)
                        "/etc/init.d/${svc}" enable 2>/dev/null || true ;;
                    disable)
                        "/etc/init.d/${svc}" disable 2>/dev/null || true ;;
                    status)
                        pgrep -x "$svc" >/dev/null \
                            && printf "${GREEN}%s 运行中${NC}\n" "$svc" \
                            || printf "${RED}%s 已停止${NC}\n" "$svc" ;;
                esac
            else
                case "$action" in
                    start)
                        # shellcheck disable=SC2086
                        nohup "$bin_path" run $cfg_arg > "$log_path" 2>&1 &
                        printf "${GREEN}%s 已后台启动${NC}\n" "$svc" ;;
                    stop)
                        killall "$svc" 2>/dev/null || true ;;
                    restart)
                        killall "$svc" 2>/dev/null || true; sleep 1
                        # shellcheck disable=SC2086
                        nohup "$bin_path" run $cfg_arg > "$log_path" 2>&1 &
                        printf "${GREEN}%s 已重启${NC}\n" "$svc" ;;
                    enable|disable)
                        # procd/initd 下无通用 enable 机制，提示用户
                        printf "${YELLOW}[提示] %s 系统下 %s 的开机自启需手动配置${NC}\n" \
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
    printf "${YELLOW}[诊断] %s 服务状态验证...${NC}\n" "$svc"
    sleep 2
    if pgrep -x "$svc" >/dev/null 2>&1; then
        local pid
        pid=$(pgrep -x "$svc" | head -n1)
        printf "  状态: ${GREEN}● 活跃 (Running)${NC} | PID: ${CYAN}%s${NC}\n" "$pid"
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
        [ "$svc" = "dae" ] && [ ! -f "$DAE_CONFIG_FILE" ] && \
            printf "  ${RED}原因: 配置文件 %s 不存在${NC}\n" "$DAE_CONFIG_FILE"
        [ "$svc" = "dae" ] && [ ! -f "$GEO_DIR/geoip.dat" ] && \
            printf "  ${RED}原因: GEO 规则库缺失，请执行菜单选项 3${NC}\n"
        return 1
    fi
}

# ==================== 服务单元文件安装 ====================
install_service_unit() {
    local svc="${1:-dae}"
    local bin_path desc
    local exec_start

    if [ "$svc" = "daed" ]; then
        bin_path="$DAED_BIN_PATH"
        desc="daed eBPF Proxy with Web Dashboard"
        # [B13] 目录路径用引号包裹
        exec_start="${DAED_BIN_PATH} run -c \"${DAED_CONFIG_DIR}\""
    else
        bin_path="$DAE_BIN_PATH"
        desc="dae eBPF Transparent Proxy"
        exec_start="${DAE_BIN_PATH} run -c ${DAE_CONFIG_FILE}"
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
                printf "${GREEN}[服务] systemd: %s.service 已安装${NC}\n" "$svc"
            fi ;;

        openrc)
            if [ ! -f "/etc/init.d/${svc}" ]; then
                cat > "/etc/init.d/${svc}" << EOF
#!/sbin/openrc-run
description="${desc}"
command="${bin_path}"
command_args="run"
command_background=true
pidfile="/run/${svc}.pid"
depend() { need net; }
EOF
                chmod +x "/etc/init.d/${svc}"
                rc-update add "$svc" default 2>/dev/null || true
                printf "${GREEN}[服务] OpenRC: /etc/init.d/%s 已安装${NC}\n" "$svc"
            fi ;;

        procd)
            if [ ! -f "/etc/init.d/${svc}" ]; then
                local procd_cfg
                if [ "$svc" = "daed" ]; then
                    procd_cfg="$DAED_CONFIG_DIR"
                else
                    procd_cfg="$DAE_CONFIG_FILE"
                fi
                cat > "/etc/init.d/${svc}" << EOF
#!/bin/sh /etc/rc.common
START=95
STOP=10
USE_PROCD=1
start_service() {
    procd_open_instance
    procd_set_param command ${bin_path} run -c "${procd_cfg}"
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param respawn 3600 5 5
    procd_close_instance
}
EOF
                chmod +x "/etc/init.d/${svc}"
                "/etc/init.d/${svc}" enable 2>/dev/null || true
                printf "${GREEN}[服务] procd: /etc/init.d/%s 已安装${NC}\n" "$svc"
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
CFG="${DAED_CONFIG_DIR:-$DAE_CONFIG_FILE}"
LOG="${DAED_LOG_FILE:-$LOG_FILE}"
case "\$1" in
    start)   nohup "\$BIN" run -c "\$CFG" > "\$LOG" 2>&1 & ;;
    stop)    killall ${svc} 2>/dev/null || true ;;
    restart) \$0 stop; sleep 1; \$0 start ;;
    status)  pgrep -x ${svc} >/dev/null && echo "running" || echo "stopped" ;;
    *)       echo "Usage: \$0 {start|stop|restart|status}" ;;
esac
EOF
                chmod +x "/etc/init.d/${svc}"
                update-rc.d "$svc" defaults 2>/dev/null || true
                printf "${GREEN}[服务] SysVinit: /etc/init.d/%s 已安装${NC}\n" "$svc"
            fi ;;
    esac
}

# ==================== GEO 更新脚本 ====================
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

# [B15] 确保目标目录存在再建软链
for d in /etc/dae /etc/daed; do
    mkdir -p "$d"
    ln -sf "$GEO_DIR/geoip.dat"   "$d/geoip.dat"   2>/dev/null || true
    ln -sf "$GEO_DIR/geosite.dat" "$d/geosite.dat" 2>/dev/null || true
done

# 热重载正在运行的实例
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
echo "[GEO] ✅ 同步完成"
GEOEOF
    chmod +x "$UPDATE_GEO_SCRIPT"
}

update_geo_data() {
    [ ! -f "$UPDATE_GEO_SCRIPT" ] && create_geo_update_script
    # [B15] 预建目录
    mkdir -p "$GEO_DIR" /etc/dae /etc/daed
    printf "${YELLOW}[GEO] 全量拉取中...${NC}\n"
    sh "$UPDATE_GEO_SCRIPT"
    printf "${GREEN}✅ GEO 数据同步完成${NC}\n"
}

# ==================== [B17] 多架构映射（移除无用参数）====================
resolve_arch() {
    local machine
    machine=$(uname -m)
    case "$machine" in
        x86_64)              echo "x86_64"      ;;
        aarch64|arm64)       echo "arm64"        ;;
        armv7*|armv7l|armhf) echo "armv7"        ;;
        riscv64)             echo "riscv64"      ;;
        loongarch64|loong64) echo "loongarch64"  ;;
        i386|i686)           echo "x86"          ;;
        *)
            printf "${RED}[架构] 不支持: %s${NC}\n" "$machine" >&2
            return 1 ;;
    esac
}

# ==================== dae CLI 配置生成 ====================
generate_dae_config() {
    local sub_airport="$1"
    local sub_home="${2:-}"
    local router_mode="${3:-side}"
    local wan_setting="wan_interface: auto"
    [ "$router_mode" = "main" ] && wan_setting="wan_interface: ${WAN_IFACE:-auto}"

    # [B3] LAN_IFACE_SETTING 保护
    [ -z "${LAN_IFACE_SETTING:-}" ] && LAN_IFACE_SETTING="lan_interface: auto"

    mkdir -p "$PERSIST_DIR" "$(dirname "$DAE_CONFIG_FILE")" "$GEO_DIR"

    local sub_section residential_filter
    if [ -n "$sub_home" ]; then
        sub_section="    airport: '${sub_airport}'
    home: '${sub_home}'"
        residential_filter="subtag(home)"
    else
        sub_section="    airport: '${sub_airport}'"
        residential_filter="subtag(airport)"
        printf "${YELLOW}[提示] 无住宅订阅，AI/社交 fallback 到机场节点${NC}\n"
    fi

    cat > "$DAE_CONFIG_FILE" << EOF
# Generated by dae-helper v${SCRIPT_VERSION}
# Date  : $(date '+%Y-%m-%d %H:%M:%S')
# Arch  : $(uname -m) | Kernel: $(uname -r)

global {
    tproxy_port: 12345
    tproxy_port_protect: true
    so_mark_from_dae: 0
    log_level: info
    disable_waiting_network: false

    ${LAN_IFACE_SETTING}
    ${wan_setting}

    auto_config_kernel_parameter: true

    tcp_check_url: 'http://cp.cloudflare.com,1.1.1.1'
    tcp_check_http_method: HEAD
    udp_check_dns: '223.5.5.5:53,119.29.29.29:53'
    check_interval: 30s
    check_tolerance: 50ms

    dial_mode: domain
    allow_insecure: false
    sniffing_timeout: 100ms
    tls_implementation: tls
    utls_imitate: chrome_auto
    bandwidth_max_tx: '200 mbps'
    bandwidth_max_rx: '1 gbps'
}

subscription {
${sub_section}
}

node {}

dns {
    ipversion_prefer: 4
    upstream {
        alidns:    'udp://223.5.5.5:53'
        googledns: 'tcp+udp://8.8.8.8:53'
    }
    routing {
        request {
            qtype(AAAA) -> reject
            qname(geosite:cn) -> alidns
            fallback: googledns
        }
        response {
            upstream(googledns) -> accept
            ip(geoip:cn) && !qname(geosite:cn) -> googledns
            fallback: accept
        }
    }
}

group {
    proxy {
        filter: subtag(airport)
        policy: min_moving_avg
    }
    residential {
        filter: ${residential_filter}
        policy: min_moving_avg
    }
}

routing {
    pname(NetworkManager, systemd-resolved, dnsmasq,
          systemd-networkd, chronyd, ntpd, dhcpcd) -> must_direct
    dip(geoip:private) -> direct
    dport(53) && !dip(223.5.5.5, 119.29.29.29, 114.114.114.114, 180.184.1.1) -> proxy

    domain(geosite:openai) -> residential
    domain(suffix: anthropic.com, suffix: claude.ai) -> residential
    domain(suffix: gemini.google.com, suffix: ai.google.dev,
           suffix: aistudio.google.com,
           suffix: generativelanguage.googleapis.com,
           suffix: notebooklm.google.com,
           suffix: deepmind.google) -> residential
    domain(suffix: x.ai, suffix: grok.com) -> residential
    domain(suffix: perplexity.ai) -> residential
    domain(suffix: cursor.com, suffix: cursor.sh) -> residential
    domain(suffix: codeium.com, suffix: windsurf.com, suffix: windsurf.ai) -> residential
    domain(suffix: huggingface.co, suffix: hf.co) -> residential

    domain(geosite:twitter)   -> residential
    domain(geosite:facebook)  -> residential
    domain(geosite:instagram) -> residential
    domain(geosite:whatsapp)  -> residential
    domain(geosite:tiktok)    -> residential
    domain(geosite:linkedin)  -> residential
    domain(geosite:reddit)    -> residential
    domain(geosite:youtube)   -> residential

    domain(geosite:apple-cn) -> direct
    domain(geosite:apple)    -> direct
    domain(geosite:cn)       -> direct
    dip(geoip:cn)            -> direct

    domain(geosite:netflix)  -> proxy
    domain(geosite:disney)   -> proxy
    domain(geosite:github)   -> proxy
    domain(geosite:telegram) -> proxy

    fallback: proxy
}
EOF
    chmod 0600 "$DAE_CONFIG_FILE"
    printf "${GREEN}✅ 配置文件生成: %s${NC}\n" "$DAE_CONFIG_FILE"

    if [ ! -f "$GEO_DIR/geoip.dat" ] || [ ! -f "$GEO_DIR/geosite.dat" ]; then
        printf "${YELLOW}[自动补救] GEO 缺失，拉取中...${NC}\n"
        update_geo_data
    fi

    if command -v dae >/dev/null 2>&1; then
        printf "${YELLOW}[校验] dae validate...${NC}\n"
        if dae validate -c "$DAE_CONFIG_FILE" > /tmp/dae_validate.log 2>&1; then
            printf "${GREEN}[校验] ✅ 配置语法通过${NC}\n"
        else
            printf "${RED}[校验] ✗ 语法错误：${NC}\n"
            cat /tmp/dae_validate.log
        fi
    fi
}

# ==================== [B4] daed 面板安装 ====================
install_daed_panel() {
    printf "\n${CYAN}═══════════════════════════════════════════════════════════${NC}\n"
    printf "${CYAN}   🖥️  daed Web 面板安装                                    ${NC}\n"
    printf "${CYAN}═══════════════════════════════════════════════════════════${NC}\n"

    check_mode_conflict "daed" || return 1
    check_ebpf_full || {
        printf "${YELLOW}[提示] 预检有问题，但您选择继续。${NC}\n"
    }

    local target_arch
    target_arch=$(resolve_arch) || return 1
    printf "${CYAN}[架构] %s${NC}\n" "$target_arch"

    # 获取 daed 版本列表
    printf "${YELLOW}[版本] 拉取 daed 发行版列表...${NC}\n"
    local release_list
    release_list=$(curl -fsSL --connect-timeout 15 \
        "https://api.github.com/repos/daeuniverse/daed/releases" \
        2>/dev/null || true)
    if [ -z "${release_list:-}" ]; then
        printf "${RED}无法获取版本列表，请检查网络。${NC}\n"; return 1
    fi

    local version_list
    version_list=$(printf '%s' "$release_list" \
        | grep '"tag_name":' \
        | sed -E 's/.*"([^"]+)".*/\1/' \
        | head -n 5)

    # [B11] version_list 空值保护
    if [ -z "${version_list:-}" ]; then
        printf "${RED}未能解析版本列表，API 响应可能异常。${NC}\n"; return 1
    fi

    local current_version="未安装"
    [ -f "$DAED_BIN_PATH" ] && [ -x "$DAED_BIN_PATH" ] \
        && current_version=$("$DAED_BIN_PATH" --version 2>/dev/null \
            | awk '{print $NF}' | head -n1 || echo "未知")

    printf "当前版本: ${GREEN}%s${NC}\n" "$current_version"
    printf "${PURPLE}可选版本:${NC}\n"
    local count=1 first_ver=""
    while IFS= read -r v; do
        [ -z "$v" ] && continue
        [ $count -eq 1 ] && first_ver="$v" \
            && printf " %d) %s ${YELLOW}(最新)${NC}\n" "$count" "$v" \
            || printf " %d) %s\n" "$count" "$v"
        count=$((count+1))
    done <<< "$version_list"
    printf " 0) 取消\n"

    printf "输入序号 [0-5]: "; read -r choice
    local selected_version=""
    case "${choice:-0}" in
        [1-5]) selected_version=$(printf '%s\n' "$version_list" \
                   | sed -n "${choice}p") ;;
        0) printf "${GREEN}已取消。${NC}\n"; return 0 ;;
        *) printf "${RED}无效输入。${NC}\n"; return 1 ;;
    esac
    [ -z "${selected_version:-}" ] && { printf "${RED}版本选择失败。${NC}\n"; return 1; }

    # [B4] daed 官方发布包格式：installer-daed-linux-<arch>.deb / .rpm / 裸二进制
    # 优先尝试系统包管理器格式，其次尝试裸二进制
    local installed=0
    local base_url="https://github.com/daeuniverse/daed/releases/download/${selected_version}"

    # 尝试 .deb（Debian/Ubuntu/Armbian）
    if [ "$PKG_MANAGER" = "apt" ] && ! [ "$installed" -eq 1 ]; then
        local deb_url="${base_url}/installer-daed-linux-${target_arch}.deb"
        local tmp_deb="/tmp/daed-installer.$$.deb"
        printf "${YELLOW}[下载] 尝试 .deb 包: %s${NC}\n" "$deb_url"
        local hc
        hc=$(curl -fsSL -w "%{http_code}" --connect-timeout 60 \
            -o "$tmp_deb" "$deb_url" 2>/dev/null || echo "000")
        if [ "$hc" = "200" ] && dpkg-deb -I "$tmp_deb" >/dev/null 2>&1; then
            dpkg -i "$tmp_deb" 2>/dev/null \
                && installed=1 \
                && printf "${GREEN}✅ .deb 包安装成功${NC}\n"
            rm -f "$tmp_deb"
        else
            rm -f "$tmp_deb"
            printf "${YELLOW}[回退] .deb 下载失败 (HTTP %s)，尝试裸二进制...${NC}\n" "$hc"
        fi
    fi

    # 尝试 .rpm（CentOS/Fedora/openSUSE）
    if [ "$PKG_MANAGER" = "dnf" ] || [ "$PKG_MANAGER" = "yum" ]; then
        if [ "$installed" -eq 0 ]; then
            local rpm_url="${base_url}/installer-daed-linux-${target_arch}.rpm"
            local tmp_rpm="/tmp/daed-installer.$$.rpm"
            printf "${YELLOW}[下载] 尝试 .rpm 包: %s${NC}\n" "$rpm_url"
            local hc
            hc=$(curl -fsSL -w "%{http_code}" --connect-timeout 60 \
                -o "$tmp_rpm" "$rpm_url" 2>/dev/null || echo "000")
            if [ "$hc" = "200" ]; then
                rpm -ivh --force "$tmp_rpm" 2>/dev/null \
                    && installed=1 \
                    && printf "${GREEN}✅ .rpm 包安装成功${NC}\n"
                rm -f "$tmp_rpm"
            else
                rm -f "$tmp_rpm"
                printf "${YELLOW}[回退] .rpm 下载失败 (HTTP %s)...${NC}\n" "$hc"
            fi
        fi
    fi

    # 尝试裸二进制（通用兜底）
    if [ "$installed" -eq 0 ]; then
        local bin_url="${base_url}/daed-linux-${target_arch}"
        local tmp_bin="/tmp/daed-bin.$$"
        printf "${YELLOW}[下载] 尝试裸二进制: %s${NC}\n" "$bin_url"
        local hc
        hc=$(curl -fsSL -w "%{http_code}" --connect-timeout 60 \
            -o "$tmp_bin" "$bin_url" 2>/dev/null || echo "000")

        if [ "$hc" != "200" ]; then
            # 再尝试 .zip
            local zip_url="${bin_url}.zip"
            local tmp_zip="/tmp/daed-bin.$$.zip"
            printf "${YELLOW}[下载] 尝试 .zip: %s${NC}\n" "$zip_url"
            hc=$(curl -fsSL -w "%{http_code}" --connect-timeout 60 \
                -o "$tmp_zip" "$zip_url" 2>/dev/null || echo "000")
            if [ "$hc" = "200" ] && unzip -t "$tmp_zip" >/dev/null 2>&1; then
                local td="/tmp/daed-unzip-$$"
                mkdir -p "$td"
                unzip -o "$tmp_zip" -d "$td" >/dev/null 2>&1
                local ef
                ef=$(find "$td" -type f ! -name "*.zip" \
                    -not -name "*.md" | head -n1 || true)
                [ -n "${ef:-}" ] && mv "$ef" "$tmp_bin"
                rm -rf "$td" "$tmp_zip"
            else
                rm -f "$tmp_bin" "$tmp_zip" 2>/dev/null || true
                printf "${RED}所有下载方式均失败！\n"
                printf "请手动从以下地址下载后执行 install -Dm755 daed %s：\n" "$DAED_BIN_PATH"
                printf "https://github.com/daeuniverse/daed/releases/tag/%s${NC}\n" \
                    "$selected_version"
                return 1
            fi
        fi

        # [B5] ELF 魔数校验（替代 file 命令）
        if is_elf_binary "$tmp_bin"; then
            install -Dm755 "$tmp_bin" "$DAED_BIN_PATH"
            rm -f "$tmp_bin"
            installed=1
            printf "${GREEN}✅ 裸二进制安装成功${NC}\n"
        else
            rm -f "$tmp_bin"
            printf "${RED}[B5] 下载的文件不是有效 ELF 二进制，中止安装。${NC}\n"
            printf "${YELLOW}文件头魔数校验失败，可能是网络劫持或文件损坏。${NC}\n"
            return 1
        fi
    fi

    # 以下步骤无论哪种安装方式都执行
    mkdir -p "$DAED_CONFIG_DIR"
    chmod 0700 "$DAED_CONFIG_DIR"

    if [ ! -f "$GEO_DIR/geoip.dat" ] || [ ! -f "$GEO_DIR/geosite.dat" ]; then
        printf "${YELLOW}[GEO] 拉取规则库...${NC}\n"
        update_geo_data
    fi

    install_service_unit "daed"
    open_firewall_port_2023
    fix_resolv_conf

    printf "\n${GREEN}╔══════════════════════════════════════════════════════════╗${NC}\n"
    printf "${GREEN}║  ✅ daed 安装完成！版本: %-30s║${NC}\n" "$selected_version"
    printf "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}\n"
    printf "${GREEN}║  🌐 面板地址: http://%-33s║${NC}\n" "${LAN_IP:-localhost}:2023"
    printf "${GREEN}║                                                          ║${NC}\n"
    printf "${GREEN}║  📋 面板初始化向导（3步）：                               ║${NC}\n"
    printf "${GREEN}║  步骤1 GraphQL接口: http://%-29s║${NC}\n" \
        "${LAN_IP:-localhost}:2023/graphql"
    printf "${GREEN}║  步骤2 设置登录用户名和密码                               ║${NC}\n"
    printf "${GREEN}║  步骤3 在面板中导入订阅、配置分组和路由规则                ║${NC}\n"
    printf "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}\n"

    printf "\n立即启动 daed 服务？(y/n): "; read -r start_now
    if [ "${start_now:-n}" = "y" ] || [ "${start_now:-n}" = "Y" ]; then
        manage_service_generic "daed" "enable" 2>/dev/null || true
        manage_service_generic "daed" "start"
        print_service_live_status "daed"
    else
        printf "${YELLOW}手动启动: daed run -c %s${NC}\n" "$DAED_CONFIG_DIR"
    fi

    send_wechat_notification "daed 面板 ${selected_version} 已安装，访问 http://${LAN_IP:-localhost}:2023"
}

# ==================== [B6] Docker Compose 面板部署 ====================
install_daed_docker_compose() {
    command -v docker >/dev/null 2>&1 \
        || { printf "${RED}未检测到 Docker。${NC}\n"; return 1; }

    # [B6] 检测 docker compose 命令
    local dc_cmd
    dc_cmd=$(docker_compose_cmd)
    if [ -z "${dc_cmd:-}" ]; then
        printf "${RED}未找到 docker compose 或 docker-compose，请先安装。${NC}\n"
        return 1
    fi
    printf "${CYAN}[Docker] 使用命令: %s${NC}\n" "$dc_cmd"

    # BTF 检测
    if [ ! -f /sys/kernel/btf/vmlinux ]; then
        printf "${RED}⚠️ 缺少 BTF，daed 容器启动将失败！${NC}\n"
        printf "强行继续？(y/n): "; read -r f
        [ "${f:-n}" != "y" ] && [ "${f:-n}" != "Y" ] && return 0
    fi

    # BPF FS
    if ! mount | grep -q 'type bpf'; then
        mkdir -p /sys/fs/bpf
        mount -t bpf bpf /sys/fs/bpf 2>/dev/null \
            || { printf "${RED}BPF FS 挂载失败。${NC}\n"; return 1; }
    fi

    check_ebpf_full || true

    printf "\n${PURPLE}选择镜像源:${NC}\n"
    printf " 1) Docker Hub : daeuniverse/daed:latest\n"
    printf " 2) GHCR       : ghcr.io/daeuniverse/daed:latest\n"
    printf "选择 [1-2, 默认1]: "; read -r img_choice
    local daed_image
    [ "${img_choice:-1}" = "2" ] \
        && daed_image="ghcr.io/daeuniverse/daed:latest" \
        || daed_image="daeuniverse/daed:latest"

    mkdir -p "$DAED_CONFIG_DIR"
    local compose_file="$DAED_CONFIG_DIR/docker-compose.yml"

    # 生成 compose 文件（与官方文档一致）
    cat > "$compose_file" << EOF
# daed Docker Compose
# 官方文档: https://github.com/daeuniverse/daed/blob/main/docs/getting-started.md
# 面板访问: http://${LAN_IP:-<本机IP>}:2023
# Generated: $(date '+%Y-%m-%d %H:%M:%S')

services:
  daed:
    image: ${daed_image}
    container_name: daed
    privileged: true
    network_mode: host
    pid: host
    restart: unless-stopped
    volumes:
      - /sys:/sys
      - /etc/daed:/etc/daed
EOF

    printf "${GREEN}✅ Compose 文件: %s${NC}\n" "$compose_file"
    update_geo_data
    open_firewall_port_2023

    printf "${BLUE}[Docker] 拉取 %s...${NC}\n" "$daed_image"
    docker pull "$daed_image" || { printf "${RED}镜像拉取失败。${NC}\n"; return 1; }

    printf "${BLUE}[Docker] 启动容器...${NC}\n"
    cd "$DAED_CONFIG_DIR" && $dc_cmd up -d

    sleep 3
    if [ "$(docker inspect -f '{{.State.Running}}' daed 2>/dev/null)" = "true" ]; then
        printf "\n${GREEN}╔══════════════════════════════════════════════════════╗${NC}\n"
        printf "${GREEN}║  🎉 daed Docker 容器启动成功！                         ║${NC}\n"
        printf "${GREEN}║  面板: http://%-37s║${NC}\n" "${LAN_IP:-localhost}:2023"
        printf "${GREEN}║  GraphQL: http://%-33s║${NC}\n" \
            "${LAN_IP:-localhost}:2023/graphql"
        printf "${GREEN}║  日志: docker logs -f daed                           ║${NC}\n"
        printf "${GREEN}╚══════════════════════════════════════════════════════╝${NC}\n"
        send_wechat_notification "daed Docker 面板已启动 http://${LAN_IP:-localhost}:2023"
    else
        printf "${RED}容器异常退出：${NC}\n"
        docker logs --tail=20 daed 2>/dev/null || true
    fi
}

# ==================== dae CLI 核心升级 ====================
upgrade_dae_core() {
    printf "\n${CYAN}--- ⚡ dae CLI 安装/更新 ---${NC}\n"
    check_mode_conflict "dae" || return 1
    check_ebpf_full || true

    local target_arch
    target_arch=$(resolve_arch) || return 1

    local release_list
    release_list=$(curl -fsSL --connect-timeout 15 \
        "https://api.github.com/repos/daeuniverse/dae/releases" \
        2>/dev/null || true)
    [ -z "${release_list:-}" ] && {
        printf "${RED}无法获取版本列表。${NC}\n"; return 1; }

    local version_list
    version_list=$(printf '%s' "$release_list" \
        | grep '"tag_name":' \
        | sed -E 's/.*"([^"]+)".*/\1/' \
        | head -n 5)

    # [B11] 版本列表空值保护
    [ -z "${version_list:-}" ] && {
        printf "${RED}版本列表解析失败。${NC}\n"; return 1; }

    local current_version="未安装"
    [ -f "$DAE_BIN_PATH" ] && [ -x "$DAE_BIN_PATH" ] \
        && current_version=$("$DAE_BIN_PATH" --version 2>/dev/null \
            | awk '{print $3}' || echo "未知")

    printf "当前版本: ${GREEN}%s${NC}\n" "$current_version"
    printf "${PURPLE}可选版本:${NC}\n"
    local count=1
    while IFS= read -r v; do
        [ -z "$v" ] && continue
        [ $count -eq 1 ] \
            && printf " %d) %s ${YELLOW}(最新)${NC}\n" "$count" "$v" \
            || printf " %d) %s\n" "$count" "$v"
        count=$((count+1))
    done <<< "$version_list"
    printf " 0) 取消\n"

    printf "输入序号 [0-5]: "; read -r choice
    local selected_version=""
    case "${choice:-0}" in
        [1-5]) selected_version=$(printf '%s\n' "$version_list" \
                   | sed -n "${choice}p") ;;
        0) printf "${GREEN}已取消。${NC}\n"; return 0 ;;
        *) printf "${RED}无效输入。${NC}\n"; return 1 ;;
    esac
    [ -z "${selected_version:-}" ] && { printf "${RED}版本选择失败。${NC}\n"; return 1; }

    local download_url="https://github.com/daeuniverse/dae/releases/download/${selected_version}/dae-linux-${target_arch}.zip"
    local tmp_zip="/tmp/dae-update.$$.zip"

    printf "${YELLOW}⬇️  下载 dae %s (%s)...${NC}\n" "$selected_version" "$target_arch"
    local http_code
    http_code=$(curl -fsSL -w "%{http_code}" --connect-timeout 60 \
        -o "$tmp_zip" "$download_url" 2>/dev/null || echo "000")

    if [ "$http_code" != "200" ] || ! unzip -t "$tmp_zip" >/dev/null 2>&1; then
        printf "${RED}下载失败 (HTTP %s) 或 ZIP 损坏。${NC}\n" "$http_code"
        rm -f "$tmp_zip"; return 1
    fi

    manage_service_generic "dae" "stop"
    clean_network_resources

    local tmp_dir="/tmp/dae-unzip-$$"
    mkdir -p "$tmp_dir"
    unzip -o "$tmp_zip" -d "$tmp_dir" >/dev/null 2>&1
    local dae_file
    dae_file=$(find "$tmp_dir" -type f -name "dae-linux-*" \
        ! -name "*.zip" | head -n1 || true)

    if [ -n "${dae_file:-}" ] && is_elf_binary "$dae_file"; then
        install -Dm755 "$dae_file" "$DAE_BIN_PATH"
        printf "${GREEN}✅ dae 安装完成: %s (%s)${NC}\n" "$selected_version" "$target_arch"
    else
        printf "${RED}解压失败或非 ELF 二进制。${NC}\n"
        rm -rf "$tmp_dir" "$tmp_zip"; return 1
    fi
    rm -rf "$tmp_dir" "$tmp_zip"

    install_service_unit "dae"
    fix_resolv_conf

    if [ ! -f "$DAE_CONFIG_FILE" ]; then
        printf "${YELLOW}[提示] 首次安装：执行菜单 3 同步规则，再执行菜单 2 生成配置。${NC}\n"
    else
        manage_service_generic "dae" "start"
        print_service_live_status "dae"
    fi

    send_wechat_notification "dae CLI 更新至 ${selected_version} (${target_arch})"
}

# ==================== 定时任务 ====================
set_geo_update_schedule() {
    command -v crontab >/dev/null 2>&1 \
        || { printf "${RED}未安装 crontab。${NC}\n"; return 1; }
    printf " 1) 每天凌晨 3 点\n 2) 每周一凌晨 3 点\n 3) 每月 1 号凌晨 3 点\n"
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
    printf "${GREEN}✅ 定时任务已设置: %s${NC}\n" "$sched"
}

# ==================== 卸载 ====================
uninstall_all() {
    printf "\n${RED}--- ☠️ 彻底卸载（dae + daed）---${NC}\n"
    printf "${YELLOW}将删除所有二进制、配置、GEO、服务。确认？(y/n): ${NC}"
    read -r confirm
    [ "${confirm:-n}" != "y" ] && [ "${confirm:-n}" != "Y" ] \
        && { printf "${GREEN}已取消。${NC}\n"; return; }

    for svc in dae daed; do
        manage_service_generic "$svc" "stop"   2>/dev/null || true
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
        && (crontab -l 2>/dev/null \
            | grep -v "$UPDATE_GEO_SCRIPT") | crontab - || true

    [ "${SERVICE_MGR:-}" = "systemd" ] && systemctl daemon-reload 2>/dev/null || true
    printf "${GREEN}✅ 已完全卸载。${NC}\n"
    send_wechat_notification "dae/daed 已从系统彻底卸载"
}

display_side_router_tip() {
    [ "$(detect_router_mode)" != "side" ] && return
    printf "\n${YELLOW}💡 旁路由提示：主路由需配置：${NC}\n"
    printf "  1. DHCP 网关和 DNS 指向本机: ${CYAN}%s${NC}\n" "${LAN_IP:-<本机IP>}"
    printf "  2. 放行端口 12345 (dae tproxy) 和 2023 (daed 面板)\n"
}

# ==================== [B2] 主菜单（选项编号去重）====================
main_menu() {
    # [B8] 确保 detect_system_env 第一个调用
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
            dae)  mode_display="${GREEN}● dae CLI 运行中${NC}"    ;;
            daed) mode_display="${GREEN}● daed 面板运行中${NC}"   ;;
            none) mode_display="${RED}■ 未运行${NC}"              ;;
            *)    mode_display="${YELLOW}? 未知${NC}"             ;;
        esac

        # [B1] 内存实时显示
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
        # [B2] 面板模式 A/B/C/D，CLI 模式 1-6，系统工具 7/8，卸载 U
        printf "\n  ${CYAN}── 面板模式（daed，推荐：Web UI 可视化配置）──${NC}\n"
        printf "  A) 🖥️  安装/更新 daed Web 面板（自动识别架构和包格式）\n"
        printf "  B) 🐳  Docker Compose 一键部署 daed 面板\n"
        printf "  C) ⚙️  daed 服务控制（启动/停止/重启/状态）\n"
        printf "  D) 🔎  查看 daed 实时日志\n"
        printf "\n  ${CYAN}── CLI 模式（dae，命令行配置）──${NC}\n"
        printf "  1) ⚡  安装/更新 dae CLI 核心\n"
        printf "  2) ✍️   生成 dae 配置（支持双订阅：机场+住宅）\n"
        printf "  3) 🔄  立即同步 GEO 规则数据库\n"
        printf "  4) 🗓️   设置 GEO 定时自动更新\n"
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

        # [B18] case 与菜单显示完全对齐
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
                       printf "${GREEN}daed 已停止。${NC}\n" ;;
                    3) clean_network_resources
                       manage_service_generic "daed" "restart"
                       print_service_live_status "daed" ;;
                    4) manage_service_generic "daed" "status" ;;
                    *) printf "${RED}无效选项。${NC}\n" ;;
                esac ;;

            [Dd])
                if [ -f "$DAED_LOG_FILE" ]; then
                    printf "${YELLOW}daed 日志（Ctrl+C 退出）...${NC}\n"
                    tail -f "$DAED_LOG_FILE"
                elif command -v journalctl >/dev/null 2>&1 \
                    && [ "${SERVICE_MGR:-}" = "systemd" ]; then
                    journalctl -u daed -f
                elif docker ps 2>/dev/null | grep -q daed; then
                    docker logs -f daed
                else
                    printf "${RED}未找到 daed 日志来源。${NC}\n"
                fi ;;

            1) upgrade_dae_core ;;

            2)
                printf "${RED}⚠️  仅支持 v2ray/base64 订阅，不支持 Clash！${NC}\n"
                printf "机场订阅 URL: "; read -r SUB_AIRPORT
                validate_subscription "${SUB_AIRPORT:-}" \
                    || { printf "${RED}URL 格式非法（需 http/https 开头）${NC}\n"; continue; }
                printf "住宅订阅 URL（无则直接回车）: "; read -r SUB_HOME
                smart_interface_sniffer
                check_mode_conflict "dae" || continue
                generate_dae_config "${SUB_AIRPORT}" "${SUB_HOME:-}" \
                    "$(detect_router_mode)"
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
                    *) printf "${RED}无效选项。${NC}\n" ;;
                esac ;;

            6)
                if [ -f "$LOG_FILE" ]; then
                    printf "${YELLOW}dae 日志（Ctrl+C 退出）...${NC}\n"
                    tail -f "$LOG_FILE"
                elif command -v journalctl >/dev/null 2>&1 \
                    && [ "${SERVICE_MGR:-}" = "systemd" ]; then
                    journalctl -u dae -f
                else
                    printf "${RED}未找到日志文件 %s${NC}\n" "$LOG_FILE"
                fi ;;

            7) check_ebpf_full ;;

            8)
                printf "企业微信 Webhook URL（留空清除）: "; read -r wx_url
                WECHAT_WEBHOOK="${wx_url:-}"
                save_env "WECHAT_WEBHOOK" "${wx_url:-}"
                [ -n "${wx_url:-}" ] \
                    && printf "${GREEN}Webhook 已绑定。${NC}\n" \
                    || printf "${YELLOW}Webhook 已清除。${NC}\n" ;;

            [Uu]) uninstall_all ;;

            0) printf "${GREEN}退出，祝网络畅通！${NC}\n"; exit 0 ;;

            *) printf "${RED}无效选项「%s」，请输入菜单中的有效编号。${NC}\n" "${choice:-}" ;;
        esac

        printf "${CYAN}按 Enter 返回主菜单...${NC}"; read -r _
    done
}

# ── 入口 ──
main_menu "$@"
