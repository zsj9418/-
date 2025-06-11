#!/bin/bash
set -u  # 仅保留未定义变量检查，移除 -e 以避免自动退出

# 定义颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# 可配置路径和默认值
# --- Sing-box Specific Paths ---
SB_BASE_DIR="/etc/sing-box"
SB_BIN_PATH="/usr/local/bin/sing-box"
SB_CONFIG_FILE="$SB_BASE_DIR/config.json"
SB_ENV_FILE="$SB_BASE_DIR/.singbox_env"
SB_SERVICE_NAME="sing-box"

# --- Mihomo Specific Paths ---
MH_BASE_DIR="/etc/mihomo"
MH_BIN_PATH="/usr/local/bin/mihomo"
MH_CONFIG_FILE="$MH_BASE_DIR/config.yaml"
MH_ENV_FILE="$MH_BASE_DIR/.mihomo_env"
MH_SERVICE_NAME="mihomo"

# --- Common Paths ---
BIN_DIR="/usr/local/bin"
LOG_FILE="/var/log/proxy-manager.log"
DEPS_INSTALLED_MARKER="/var/lib/proxy_manager_deps_installed"

# 获取脚本的绝对路径（兼容 OpenWrt）
get_script_path() {
    if command -v readlink >/dev/null 2>&1; then
        readlink -f "$0"
    else
        script_name="$0"
        if [ "${script_name##/}" = "$script_name" ]; then
            script_path="$(pwd)/$script_name"
        else
            script_path="$script_name"
        fi
        script_path=$(cd "$(dirname "$script_path")" && pwd)/$(basename "$script_path")
        echo "$script_path"
    fi
}
SCRIPT_PATH=$(get_script_path)

# 获取设备名称（兼容 OpenWrt 和其他系统）
get_device_name() {
    if command -v hostname >/dev/null 2>&1; then
        hostname
    elif [ -f /proc/sys/kernel/hostname ]; then
        cat /proc/sys/kernel/hostname
    else
        echo "unknown-device"
    fi
}
DEVICE_NAME=$(get_device_name)

# 日志记录函数
log() {
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    printf "%b[%s] %s%b\n" "$YELLOW" "$timestamp" "$1" "$NC"
    echo "[$timestamp] $1" >> "$LOG_FILE"
}

# 彩色输出函数
red() { printf "%b%s%b\n" "$RED" "$1" "$NC"; }
green() { printf "%b%s%b\n" "$GREEN" "$1" "$NC"; }
yellow() { printf "%b%s%b\n" "$YELLOW" "$1" "$NC"; }

# 检查是否为 root 用户
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        red "此脚本必须以 root 用户运行"
        exit 1
    fi
}

# 获取架构信息（通用性，支持多种架构）
get_arch() {
    case $(uname -m) in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;; # 修正此处，将 aarch64 映射到 arm64
        armv7l)  echo "armv7" ;;
        riscv64) echo "riscv64" ;;
        *)       red "不支持的架构: $(uname -m)"; return 1 ;;
    esac
}

# 判断系统类型
detect_system() {
    if [ -f /etc/openwrt_release ]; then
        echo "openwrt"
    elif command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then
        echo "systemd" # 更通用的 systemd 检测
    elif command -v apt >/dev/null 2>&1; then
        echo "debian"
    elif command -v yum >/dev/null 2>&1; then
        echo "centos"
    elif command -v apk >/dev/null 2>&1; then
        echo "alpine"
    else
        echo "unknown"
    fi
}
SYSTEM_TYPE=$(detect_system)

# 安装依赖（兼容 OpenWrt 和其他系统，首次运行检查）
install_deps() {
    if [ -f "$DEPS_INSTALLED_MARKER" ]; then
        log "已检测到依赖已安装标记文件，跳过依赖检查。"
        return 0
    fi

    log "首次运行，正在检查并安装依赖 (curl, tar, iptables, ipset, jq, psmisc, cron, unzip, fzf)..."
    local pkg_manager=""
    local install_cmd=""
    local update_cmd=""
    local pkgs=""
    local cron_pkg="cron"
    local failed_pkgs=""

    case "$SYSTEM_TYPE" in
        debian|systemd)
            pkg_manager="apt"
            update_cmd="apt update"
            install_cmd="apt install -y"
            pkgs="curl tar iptables ipset jq psmisc cron unzip fzf"
            ;;
        centos)
            pkg_manager="yum"
            update_cmd=""
            install_cmd="yum install -y"
            cron_pkg="cronie"
            pkgs="curl tar iptables ipset jq psmisc cronie unzip fzf"
            ;;
        alpine)
            pkg_manager="apk"
            update_cmd="apk update"
            install_cmd="apk add"
            cron_pkg="cronie"
            pkgs="curl tar iptables ipset jq psmisc cronie unzip fzf"
            ;;
        openwrt)
            pkg_manager="opkg"
            update_cmd="opkg update"
            install_cmd="opkg install"
            pkgs="curl tar iptables ipset jq psmisc unzip" # 移除 fzf，设为可选
            ;;
        *)
            red "不支持的包管理器，请手动安装 curl, tar, iptables, ipset, jq, psmisc, cron, unzip, fzf"
            return 1
            ;;
    esac

    pkgs=$(echo "$pkgs" | sed "s/cron/$cron_pkg/")

    log "使用包管理器: $pkg_manager"
    if [ -n "$update_cmd" ]; then
        $update_cmd || { red "包列表更新失败"; return 1; }
    fi

    for pkg in $pkgs; do
        if ! $install_cmd "$pkg" >/dev/null 2>&1; then
            yellow "安装依赖 $pkg 失败，稍后请手动安装。"
            failed_pkgs="$failed_pkgs $pkg"
        else
            green "成功安装依赖 $pkg"
        fi
    done

    if ! command -v fzf >/dev/null 2>&1; then
        if [ "$SYSTEM_TYPE" = "openwrt" ]; then
            yellow "fzf 在 OpenWrt 默认软件源中可能不可用，跳过 fzf 安装。"
        else
            yellow "未检测到 fzf。请手动安装 fzf，命令示例: $install_cmd fzf"
            failed_pkgs="$failed_pkgs fzf"
        fi
    fi

    if ! command -v killall >/dev/null 2>&1; then
        yellow "未检测到 killall 命令（通常由 psmisc 提供）。请手动安装 psmisc。"
        failed_pkgs="$failed_pkgs psmisc"
    fi

    if [ "$SYSTEM_TYPE" = "openwrt" ]; then
        if [ -f /etc/init.d/cron ]; then
            /etc/init.d/cron enable || yellow "无法启用 cron 服务。"
            /etc/init.d/cron start || yellow "无法启动 cron 服务。"
        else
            yellow "未检测到 cron 服务，请确保 cron 已安装并启用。"
            failed_pkgs="$failed_pkgs $cron_pkg"
        fi
    fi

    if [ -n "$failed_pkgs" ]; then
        yellow "以下依赖安装失败：$failed_pkgs"
        yellow "脚本将继续运行，但某些功能可能受限。请手动安装缺失的依赖。"
    else
        green "所有依赖安装完成。"
    fi

    touch "$DEPS_INSTALLED_MARKER"
    green "依赖检查完成，将跳过后续检查。"
    return 0
}

# 清理临时文件
cleanup() {
    if [ -n "${TEMP_DIR:-}" ] && [ -d "$TEMP_DIR" ]; then
        log "清理临时文件: $TEMP_DIR"
        rm -rf "$TEMP_DIR"
    fi
}
trap 'red "脚本因中断信号（Ctrl+C）终止，执行清理..."; cleanup; exit 1' INT TERM

# 检查网络通畅性
check_network() {
    log "检查网络通畅性 (ping 8.8.8.8)..."
    if ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1; then
        green "网络连接正常 (ping 8.8.8.8 成功)"
        return 0
    else
        log "ping 8.8.8.8 失败, 尝试 curl google.com..."
        if curl -s --head --connect-timeout 10 --max-time 15 https://www.google.com >/dev/null 2>&1; then
             green "网络连接正常 (curl google.com 成功)"
             return 0
        else
             red "无法连接到外网 (ping 和 curl 都失败)，请检查网络配置"
             return 1
        fi
    fi
}

# 配置网络（启用 IPv4 和 IPv6 转发以及 NAT）
configure_network_forwarding_nat() {
    log "配置 IPv4 和 IPv6 转发以及 NAT..."

    # 启用 IPv4 转发
    yellow "确保 IPv4 转发已启用..."
    if sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1; then
        green "IPv4 转发已通过 sysctl -w 启用。"
    else
        red "临时启用 IPv4 转发失败。"
        return 1
    fi

    if grep -q "^net.ipv4.ip_forward=" /etc/sysctl.conf; then
        sed -i 's/^net.ipv4.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
        green "IPv4 转发配置已更新到 /etc/sysctl.conf。"
    else
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        green "IPv4 转发配置已写入 /etc/sysctl.conf。"
    fi

    # 启用 IPv6 转发
    yellow "确保 IPv6 转发已启用..."
    if sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1; then
        green "IPv6 转发已通过 sysctl -w 启用。"
    else
        red "临时启用 IPv6 转发失败，可能是系统不支持 IPv6。"
        # 这里不返回失败，因为有些系统可能不需要或不支持IPv6转发
    fi

    if grep -q "^net.ipv6.conf.all.forwarding=" /etc/sysctl.conf; then
        sed -i 's/^net.ipv6.conf.all.forwarding=.*/net.ipv6.conf.all.forwarding=1/' /etc/sysctl.conf
        green "IPv6 转发配置已更新到 /etc/sysctl.conf。"
    else
        echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
        green "IPv6 转发配置已写入 /etc/sysctl.conf。"
    fi

    # 清理可能的禁用 IPv6 配置
    if grep -q "^net.ipv6.conf.all.disable_ipv6=" /etc/sysctl.conf; then
        sed -i '/^net.ipv6.conf.all.disable_ipv6=/d' /etc/sysctl.conf
        yellow "已移除 /etc/sysctl.conf 中的禁用 IPv6 配置。"
    fi
    sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1

    # 应用 sysctl 配置并验证
    log "正在应用 sysctl 配置 ('sysctl -p') 并验证其输出..."
    local sysctl_p_output
    # 捕获 sysctl -p 的输出，包括标准输出和标准错误
    sysctl_p_output=$(sysctl -p 2>&1)
    local sysctl_p_exit_code=$?
    if [ "$sysctl_p_exit_code" -eq 0 ]; then
        green "sysctl 配置已成功应用 ('sysctl -p' 返回成功)。"
    else
        red "sysctl 配置应用失败 ('sysctl -p' 返回错误)。"
        yellow "sysctl -p 错误输出:\n$sysctl_p_output"
        return 1
    fi

    log "sysctl -p 输出:\n$sysctl_p_output"

    # 明确验证预期结果
    local ipv4_forward_ok=0
    local ipv6_forward_ok=0

    if echo "$sysctl_p_output" | grep -q "net.ipv4.ip_forward = 1"; then
        green "验证成功: net.ipv4.ip_forward = 1 已在 'sysctl -p' 输出中找到。"
        ipv4_forward_ok=1
    else
        red "验证失败: net.ipv4.ip_forward = 1 未在 'sysctl -p' 输出中找到。"
    fi

    if echo "$sysctl_p_output" | grep -q "net.ipv6.conf.all.forwarding = 1"; then
        green "验证成功: net.ipv6.conf.all.forwarding = 1 已在 'sysctl -p' 输出中找到。"
        ipv6_forward_ok=1
    else
        red "验证失败: net.ipv6.conf.all.forwarding = 1 未在 'sysctl -p' 输出中找到。"
        yellow "(注意: 如果系统不支持 IPv6，此项可能预期为失败)"
    fi

    if [ "$ipv4_forward_ok" -eq 1 ] && [ "$ipv6_forward_ok" -eq 1 ]; then
        green "恭喜！所有转发规则已成功设置并验证。"
    else
        red "部分或全部转发规则验证失败。请手动检查并解决问题。"
        return 1
    fi

    # 配置 IPv4 NAT 规则
    local NAT_SOURCE_CIDR="192.168.0.0/16"
    if ! iptables -t nat -C POSTROUTING -s "$NAT_SOURCE_CIDR" -j MASQUERADE 2>/dev/null; then
        yellow "添加 IPv4 NAT 规则 (MASQUERADE for $NAT_SOURCE_CIDR)..."
        if iptables -t nat -A POSTROUTING -s "$NAT_SOURCE_CIDR" -j MASQUERADE; then
            green "IPv4 NAT 规则添加成功"
            if [ "$SYSTEM_TYPE" = "openwrt" ]; then
                yellow "OpenWrt 系统：请手动将 IPv4 NAT 规则添加到 UCI 防火墙配置以实现持久化。"
                yellow "示例命令："
                yellow "  uci add firewall rule"
                yellow "  uci set firewall.@rule[-1].name='Masquerade_Proxy_IPv4'"
                yellow "  uci set firewall.@rule[-1].src='lan'"
                yellow "  uci set firewall.@rule[-1].target='MASQUERADE'"
                yellow "  uci commit firewall && /etc/init.d/firewall restart"
            elif command -v iptables-save >/dev/null 2>&1; then
                mkdir -p /etc/iptables
                if iptables-save > /etc/iptables/rules.v4; then
                    green "IPv4 iptables 规则已保存到 /etc/iptables/rules.v4"
                else
                    red "IPv4 iptables-save 保存规则失败"
                fi
            else
                yellow "未找到 iptables-save 命令，IPv4 NAT 规则可能不会持久化。"
            fi
        else
            red "添加 IPv4 NAT 规则失败"
            return 1
        fi
    else
        green "IPv4 NAT 规则 (MASQUERADE for $NAT_SOURCE_CIDR) 已存在"
    fi

    # 配置 IPv6 NAT 规则
    local NAT_SOURCE_CIDR_V6="fc00::/7"
    if command -v ip6tables >/dev/null 2>&1; then
        if ! ip6tables -t nat -C POSTROUTING -s "$NAT_SOURCE_CIDR_V6" -j MASQUERADE 2>/dev/null; then
            yellow "添加 IPv6 NAT 规则 (MASQUERADE for $NAT_SOURCE_CIDR_V6)..."
            if ip6tables -t nat -A POSTROUTING -s "$NAT_SOURCE_CIDR_V6" -j MASQUERADE; then
                green "IPv6 NAT 规则添加成功"
                if [ "$SYSTEM_TYPE" = "openwrt" ]; then
                    yellow "OpenWrt 系统：请手动将 IPv6 NAT 规则添加到 UCI 防火墙配置以实现持久化。"
                    yellow "示例命令："
                    yellow "  uci add firewall rule"
                    yellow "  uci set firewall.@rule[-1].name='Masquerade_Proxy_IPv6'"
                    yellow "  uci set firewall.@rule[-1].src='lan'"
                    yellow "  uci set firewall.@rule[-1].family='ipv6'"
                    yellow "  uci set firewall.@rule[-1].target='MASQUERADE'"
                    # 修正：uci commit firewall && /etc/init.d/firewall restart 应该单独一行
                    # 并确保UCI命令是在用户知情下执行，此处仅作为示例
                    # uci commit firewall && /etc/init.d/firewall restart
                elif command -v ip6tables-save >/dev/null 2>&1; then
                    mkdir -p /etc/iptables
                    if ip6tables-save > /etc/iptables/rules.v6; then
                        green "IPv6 ip6tables 规则已保存到 /etc/iptables/rules.v6"
                    else
                        red "IPv6 ip6tables-save 保存规则失败"
                    fi
                else
                    yellow "未找到 ip6tables-save 命令，IPv6 NAT 规则可能不会持久化。"
                fi
            else
                red "添加 IPv6 NAT 规则失败"
                return 1
            fi
        else
            green "IPv6 NAT 规则 (MASQUERADE for $NAT_SOURCE_CIDR_V6) 已存在"
        fi
    else
        yellow "未找到 ip6tables 命令，跳过 IPv6 NAT 配置。请确保已安装 ip6tables。"
    fi

    return 0
}

# 加载环境变量
load_service_env() {
    local env_file="$1"
    if [ -f "$env_file" ]; then
        . "$env_file"
        return 0
    else
        yellow "未检测到环境变量配置文件 $env_file"
        return 1
    fi
}

# 设置环境变量
setup_service_env() {
    local env_file="$1"
    local service_name="$2"
    local default_mode_options="$3"

    log "正在设置 ${service_name} 环境变量..."
    printf "%b请输入您的 %s 订阅链接或 API 地址：%b\n" "$GREEN" "$service_name" "$NC"
    read -r PROXY_API_URL_INPUT
    if [ -z "$PROXY_API_URL_INPUT" ]; then
        red "订阅链接或 API 地址不能为空！"
        return 1
    fi
    local PROXY_API_URL="$PROXY_API_URL_INPUT"

    printf "%b请选择 %s 代理模式 (%s)：%b\n" "$GREEN" "$service_name" "$default_mode_options" "$NC"
    printf "  1) 全局 (Global)\n"
    printf "  2) GFWList\n"
    printf "  3) 规则 (Rule)\n"
    printf "  4) 直连 (Direct)\n"
    read -r PROXY_MODE_INPUT
    local PROXY_MODE=""
    case "$PROXY_MODE_INPUT" in
        1) PROXY_MODE="global" ;;
        2) PROXY_MODE="gfwlist" ;;
        3) PROXY_MODE="rule" ;;
        4) PROXY_MODE="direct" ;;
        *) red "无效选择，将使用默认规则模式 (rule)。"; PROXY_MODE="rule" ;;
    esac

    printf "%b请输入自动更新间隔时间 (分钟, 0 表示不自动更新，推荐 1440 为每天一次):%b\n" "$GREEN" "$NC"
    read -r CRON_INTERVAL_INPUT
    if ! echo "$CRON_INTERVAL_INPUT" | grep -Eq '^[0-9]+$'; then
        red "无效的间隔时间，将使用默认值 1440 分钟 (每天一次)。"
        CRON_INTERVAL=1440
    else
        CRON_INTERVAL="$CRON_INTERVAL_INPUT"
    fi

    mkdir -p "$(dirname "$env_file")"
    cat << EOF > "$env_file"
# This file stores environment variables for ${service_name}.
PROXY_API_URL="$PROXY_API_URL"
PROXY_MODE="$PROXY_MODE"
CRON_INTERVAL="$CRON_INTERVAL"
EOF
    green "${service_name} 环境变量设置完成并保存到 $env_file。"
    return 0
}

# 获取 Sing-box 最新版本号
get_singbox_latest_version() {
    local latest_version
    latest_version=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r '.tag_name')
    if [ -z "$latest_version" ] || [ "$latest_version" = "null" ]; then
        return 1
    fi
    echo "$latest_version"
    return 0
}

# 安装 Sing-box
install_singbox() {
    log "开始安装 Sing-box..."
    check_network || return 1
    configure_network_forwarding_nat || return 1

    log "正在获取 Sing-box 最新版本号..."
    local latest_version
    latest_version=$(get_singbox_latest_version) || { red "获取 Sing-box 最新版本失败。"; return 1; }
    green "Sing-box 最新版本: $latest_version"

    local version_without_v=$(echo "$latest_version" | sed 's/^v//')
    local local_arch=$(get_arch) || return 1
    local FILENAME=""
    case "$local_arch" in
        amd64) FILENAME="sing-box-${version_without_v}-linux-amd64.tar.gz" ;;
        arm64) FILENAME="sing-box-${version_without_v}-linux-arm64.tar.gz" ;;
        armv7) FILENAME="sing-box-${version_without_v}-linux-armv7.tar.gz" ;;
        riscv64) FILENAME="sing-box-${version_without_v}-linux-riscv64.tar.gz" ;;
        *) red "不支持的架构: $local_arch"; return 1 ;;
    esac

    local DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${latest_version}/${FILENAME}"
    TEMP_DIR=$(mktemp -d)
    local TAR_PATH="$TEMP_DIR/$FILENAME"

    log "下载 Sing-box $latest_version ($local_arch)..."
    if ! curl -L -o "$TAR_PATH" "$DOWNLOAD_URL"; then
        red "下载 Sing-box 失败！URL: ${DOWNLOAD_URL}"
        cleanup
        return 1
    fi

    log "解压文件..."
    if ! tar -xzf "$TAR_PATH" -C "$TEMP_DIR"; then
        red "解压 Sing-box 失败！"
        cleanup
        return 1
    fi

    local SINGBOX_BIN_UNPACKED=$(find "$TEMP_DIR" -type f -name "sing-box" -perm /a+x | head -n 1)
    if [ -z "$SINGBOX_BIN_UNPACKED" ]; then
        red "未找到 Sing-box 可执行文件！"
        cleanup
        return 1
    fi

    mkdir -p "$(dirname "$SB_BIN_PATH")" || { red "创建安装目录 $(dirname "$SB_BIN_PATH") 失败"; cleanup; return 1; }

    log "安装 Sing-box 到 $SB_BIN_PATH..."
    cp "$SINGBOX_BIN_UNPACKED" "$SB_BIN_PATH"
    chmod +x "$SB_BIN_PATH"

    cleanup
    green "Sing-box $latest_version 安装成功！"

    generate_initial_singbox_config
    setup_service "singbox"
    green "Sing-box 部署完成。"
    return 0
}

# 生成初始 Sing-box 配置
generate_initial_singbox_config() {
    log "生成初始 Sing-box 配置文件到 $SB_CONFIG_FILE..."
    mkdir -p "$(dirname "$SB_CONFIG_FILE")"
    if [ -f "$SB_CONFIG_FILE" ]; then
        yellow "检测到现有 Sing-box 配置文件，将备份到 ${SB_CONFIG_FILE}.bak"
        cp "$SB_CONFIG_FILE" "${SB_CONFIG_FILE}.bak"
    fi

    cat << EOF > "$SB_CONFIG_FILE"
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "tun", "tag": "tun-in", "stack": "system",
      "auto_route": true, "inet4_address": "172.19.0.1/24",
      "sniff": true, "detour": "proxy"
    },
    {
      "type": "mixed", "tag": "mixed-in", "listen": "::",
      "listen_port": 2080, "detour": "proxy"
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "block", "tag": "block" },
    { "type": "dns", "tag": "dns-out" },
    { "type": "selector", "tag": "proxy", "outbounds": ["direct"] }
  ],
  "route": { "rules": [{ "inbound": ["tun-in", "mixed-in"], "outbound": "proxy" }] },
  "dns": { "servers": [{ "address": "8.8.8.8", "detour": "direct" }] }
}
EOF
    if [ $? -eq 0 ]; then
        green "Sing-box 初始配置文件已生成：$SB_CONFIG_FILE"
        yellow "提示：请编辑 $SB_CONFIG_FILE 以配置您的代理！"
    else
        red "Sing-box 初始配置文件生成失败！"
        return 1
    fi
    return 0
}

# 获取 Mihomo 最新版本号
get_mihomo_latest_version() {
    local latest_version
    latest_version=$(curl -s "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest" | jq -r '.tag_name')
    if [ -z "$latest_version" ] || [ "$latest_version" = "null" ]; then
        return 1
    fi
    echo "$latest_version"
    return 0
}

# 安装 Mihomo
install_mihomo() {
    log "开始安装 Mihomo..."
    check_network || return 1
    configure_network_forwarding_nat || return 1

    log "正在获取 Mihomo 最新版本号..."
    local latest_version
    latest_version=$(get_mihomo_latest_version) || { red "获取 Mihomo 最新版本失败。"; return 1; }
    green "Mihomo 最新版本: $latest_version"

    local local_arch=$(get_arch) || return 1
    local FILENAME=""
    case "$local_arch" in
        amd64) FILENAME="mihomo-linux-${local_arch}-${latest_version}.gz" ;;
        arm64) FILENAME="mihomo-linux-${local_arch}-${latest_version}.gz" ;;
        armv7) FILENAME="mihomo-linux-${local_arch}-v7-${latest_version}.gz" ;;
        riscv64) FILENAME="mihomo-linux-${local_arch}-${latest_version}.gz" ;;
        *) red "不支持的架构: $local_arch"; return 1 ;;
    esac

    local DOWNLOAD_URL="https://github.com/MetaCubeX/mihomo/releases/download/${latest_version}/${FILENAME}"
    TEMP_DIR=$(mktemp -d)
    local GZ_PATH="$TEMP_DIR/$FILENAME"

    log "下载 Mihomo ${latest_version} (${local_arch})..."
    if ! curl -L -o "$GZ_PATH" "$DOWNLOAD_URL"; then
        red "下载 Mihomo 失败！URL: ${DOWNLOAD_URL}"
        cleanup
        return 1
    fi

    log "解压文件..."
    if ! gzip -d "$GZ_PATH"; then
        red "解压 Mihomo 失败！"
        cleanup
        return 1
    fi
    local MIHOMO_BIN_UNPACKED="${GZ_PATH%.gz}"

    if [ ! -f "$MIHOMO_BIN_UNPACKED" ]; then
        red "未找到 Mihomo 可执行文件！"
        cleanup
        return 1
    fi

    mkdir -p "$(dirname "$MH_BIN_PATH")" || { red "创建安装目录 $(dirname "$MH_BIN_PATH") 失败"; cleanup; return 1; }

    log "安装 Mihomo 到 $MH_BIN_PATH..."
    cp "$MIHOMO_BIN_UNPACKED" "$MH_BIN_PATH"
    chmod +x "$MH_BIN_PATH"

    cleanup
    green "Mihomo $latest_version 安装成功！"

    generate_initial_mihomo_config
    setup_service "mihomo"
    green "Mihomo 部署完成。"
    return 0
}

# 获取 Mihomo Alpha (Smart Group) 版本列表
get_mihomo_alpha_versions() {
    local arch="$1" # 例如 amd64, arm64
    local releases_info
    releases_info=$(curl -s "https://api.github.com/repos/vernesong/mihomo/releases") || {
        red "无法获取 Mihomo Alpha 版本信息，请检查网络或 GitHub API 限制。"
        return 1
    }

    # 解析 releases，提取 Prerelease-Alpha 版本的资产
    local versions=()
    local i=0
    while IFS= read -r asset_info; do
        local asset_name
        local download_url
        local commit_id
        local published_at
        asset_name=$(echo "$asset_info" | jq -r '.name')
        # 匹配 mihomo-linux-<arch>-alpha-smart-<commit>.gz
        if [[ "$asset_name" =~ mihomo-linux-${arch}(-compatible)?-alpha-smart-([0-9a-f]+)\.gz ]]; then
            commit_id="${BASH_REMATCH[2]}"
            download_url=$(echo "$asset_info" | jq -r '.browser_download_url')
            published_at=$(echo "$asset_info" | jq -r '.published_at' | cut -d'T' -f1)
            versions[$i]="${commit_id}|${published_at}|${download_url}|${asset_name}"
            ((i++))
        fi
    done < <(echo "$releases_info" | jq -c '.[] | .assets[]')

    if [ ${#versions[@]} -eq 0 ]; then
        red "未找到适用于架构 $arch 的 Mihomo Alpha (Smart Group) 版本。"
        return 1
    fi

    echo "${versions[@]}"
    return 0
}

# 获取 Mihomo Model.bin 的最新下载链接
get_mihomo_model_bin_url() {
    local releases_info
    releases_info=$(curl -s "https://api.github.com/repos/vernesong/mihomo/releases") || {
        red "无法获取 Mihomo 发布信息以查找 Model.bin，请检查网络或 GitHub API 限制。"
        return 1
    }

    # 查找 LightGBM-Model 标签下的 Model.bin 文件
    local model_bin_url
    model_bin_url=$(echo "$releases_info" | jq -r '.[] | select(.tag_name == "LightGBM-Model") | .assets[] | select(.name == "Model.bin") | .browser_download_url')

    if [ -z "$model_bin_url" ]; then
        red "未找到 LightGBM-Model 标签下的 Model.bin 文件。"
        return 1
    fi

    echo "$model_bin_url"
    return 0
}

# 安装 Mihomo Alpha with Smart Group 版本
install_mihomo_alpha_smart() {
    log "开始安装 Mihomo Alpha with Smart Group 版本..."
    check_network || return 1
    configure_network_forwarding_nat || return 1

    local local_arch=$(get_arch) || return 1
    local supported_arches=("amd64" "arm64") # 当前已知的 alpha-smart 支持架构
    local arch_supported=0
    for supported_arch in "${supported_arches[@]}"; do
        if [ "$local_arch" = "$supported_arch" ]; then
            arch_supported=1
            break
        fi
    done
    if [ "$arch_supported" -eq 0 ]; then
        red "暂无 $local_arch 架构的 Mihomo Alpha with Smart Group 版本支持，目前仅支持 amd64 和 arm64。"
        return 1
    fi

    log "正在获取 Mihomo Alpha with Smart Group 可用版本..."
    local versions
    versions=$(get_mihomo_alpha_versions "$local_arch") || return 1

    # 解析版本并显示选择菜单
    local version_array=($versions)
    clear
    printf "\\n%b=== 选择 Mihomo Alpha (Smart Group) 版本 ===%b\\n" "$GREEN" "$NC"
    local i=1
    declare -A version_map
    for version_info in "${version_array[@]}"; do
        IFS='|' read -r commit_id published_at download_url asset_name <<< "$version_info"
        printf "  %d) Commit: %s (发布日期: %s, 文件: %s)\\n" "$i" "$commit_id" "$published_at" "$asset_name"
        version_map[$i]="$download_url|$asset_name"
        ((i++))
    done
    printf "%b=====================================%b\\n" "$GREEN" "$NC"
    printf "请输入选项 (1-%d): " "${#version_array[@]}"
    read -r choice

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#version_array[@]}" ]; then
        red "无效选项 '$choice'，安装取消。"
        return 1
    fi

    local selected_version=${version_map[$choice]}
    local DOWNLOAD_URL=$(echo "$selected_version" | cut -d'|' -f1)
    local FILENAME=$(echo "$selected_version" | cut -d'|' -f2)

    TEMP_DIR=$(mktemp -d)
    local GZ_PATH="$TEMP_DIR/$FILENAME"

    log "下载 Mihomo Alpha with Smart Group ($local_arch, 文件: $FILENAME)..."
    if ! curl -L -o "$GZ_PATH" "$DOWNLOAD_URL"; then
        red "下载 Mihomo Alpha with Smart Group 失败！URL: ${DOWNLOAD_URL}"
        cleanup
        return 1
    fi

    log "解压文件..."
    if ! gzip -d "$GZ_PATH"; then
        red "解压 Mihomo Alpha with Smart Group 失败！"
        cleanup
        return 1
    fi
    local MIHOMO_BIN_UNPACKED="${GZ_PATH%.gz}"

    if [ ! -f "$MIHOMO_BIN_UNPACKED" ]; then
        red "未找到 Mihomo Alpha with Smart Group 可执行文件！"
        cleanup
        return 1
    fi

    mkdir -p "$(dirname "$MH_BIN_PATH")" || { red "创建安装目录 $(dirname "$MH_BIN_PATH") 失败"; cleanup; return 1; }

    log "安装 Mihomo Alpha with Smart Group 到 $MH_BIN_PATH..."
    cp "$MIHOMO_BIN_UNPACKED" "$MH_BIN_PATH"
    chmod +x "$MH_BIN_PATH"

    # 下载 Model.bin 文件到 Mihomo 配置目录
    local MODEL_BIN_PATH="$MH_BASE_DIR/Model.bin"
    log "正在获取最新 Model.bin 下载链接..."
    local MODEL_BIN_URL
    MODEL_BIN_URL=$(get_mihomo_model_bin_url) || {
        yellow "无法获取 Model.bin 下载链接，将跳过 Model.bin 下载，Mihomo Smart Group 功能可能受限。"
    }

    if [ -n "$MODEL_BIN_URL" ]; then
        log "下载 Model.bin 到 $MODEL_BIN_PATH..."
        mkdir -p "$MH_BASE_DIR" # 确保配置目录存在
        if ! curl -L -o "$MODEL_BIN_PATH" "$MODEL_BIN_URL"; then
            red "下载 Model.bin 失败！URL: ${MODEL_BIN_URL}"
            yellow "Model.bin 下载失败，Mihomo Smart Group 功能可能受限。"
        else
            green "Model.bin 下载成功，保存为 $MODEL_BIN_PATH。"
        fi
    fi

    cleanup
    green "Mihomo Alpha with Smart Group 安装成功！"

    generate_initial_mihomo_config
    setup_service "mihomo"
    green "Mihomo Alpha with Smart Group 部署完成。"
    return 0
}

# 生成初始 Mihomo 配置
generate_initial_mihomo_config() {
    log "生成初始 Mihomo 配置文件到 $MH_CONFIG_FILE..."
    mkdir -p "$(dirname "$MH_CONFIG_FILE")"
    if [ -f "$MH_CONFIG_FILE" ]; then
        yellow "检测到现有 Mihomo 配置文件，将备份到 ${MH_CONFIG_FILE}.bak"
        cp "$MH_CONFIG_FILE" "${MH_CONFIG_FILE}.bak"
    fi

    cat << EOF > "$MH_CONFIG_FILE"
# Mihomo 基础配置文件模板
port: 7890
socks-port: 7891
redir-port: 7892
tproxy-port: 7893
allow-lan: true
mode: rule
log-level: info
external-controller: 0.0.0.0:9090
tun:
  enable: true
  stack: system
  auto-route: true
  auto-detect-interface: true
  inet4-address: 198.18.0.1/16
  dns-hijack:
    - "any:53"
dns:
  enable: true
  listen: 0.0.0.0:53
  enhanced-mode: true
  nameserver:
    - 8.8.8.8
    - 1.1.1.1
  fallback:
    - https://dns.google/dns-query
  fallback-filter: { geoip: true, geoip-code: CN }
EOF
    if [ $? -eq 0 ]; then
        green "Mihomo 初始配置文件已生成：$MH_CONFIG_FILE"
        yellow "提示：请编辑 $MH_CONFIG_FILE 配置您的代理！"
    else
        red "Mihomo 初始配置文件生成失败！"
        return 1
    fi
    return 0
}

# 通用服务安装/设置函数
setup_service() {
    local service_type="$1"
    log "设置 ${service_type} 服务..."

    if [ "$SYSTEM_TYPE" = "openwrt" ]; then
        local service_name="" bin_path="" exec_params=""
        case "$service_type" in
            singbox) service_name="$SB_SERVICE_NAME"; bin_path="$SB_BIN_PATH"; exec_params="run -c $SB_CONFIG_FILE" ;;
            mihomo) service_name="$MH_SERVICE_NAME"; bin_path="$MH_BIN_PATH"; exec_params="-d $MH_BASE_DIR" ;;
        esac
        local service_file="/etc/init.d/$service_name"

        log "为 OpenWrt 创建 procd init 脚本: $service_file"
        cat << EOF > "$service_file"
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=95
STOP=10
start_service() {
    procd_open_instance
    procd_set_param command "$bin_path" $exec_params
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
reload_service() {
    stop
    start
}
EOF
        chmod +x "$service_file"
        "$service_file" enable || yellow "启用 ${service_name} 服务失败"
        green "${service_name} OpenWrt 服务已创建并设置为开机自启。"
    else
        local service_name="" description="" exec_start=""
        case "$service_type" in
            singbox) service_name="$SB_SERVICE_NAME"; description="Sing-box"; exec_start="$SB_BIN_PATH run -c $SB_CONFIG_FILE" ;;
            mihomo) service_name="$MH_SERVICE_NAME"; description="Mihomo"; exec_start="$MH_BIN_PATH -d $MH_BASE_DIR" ;;
        esac
        local service_file="/etc/systemd/system/$service_name.service"
        log "为 systemd 创建 service unit: $service_file"
        cat << EOF > "$service_file"
[Unit]
Description=$description proxy service
After=network.target nss-lookup.target

[Service]
ExecStart=$exec_start
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable "$service_name" || yellow "启用 ${service_name} 服务失败"
        green "${service_name} Systemd 服务已创建并设置为开机自启。"
    fi
    return 0
}

# 通用服务卸载函数
uninstall_service() {
    local service_type="$1"
    yellow "警告：这将完全卸载 ${service_type} 及其所有相关文件。"
    printf "您确定要继续吗？(y/N): "
    read -r confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        green "卸载已取消。"
        return 0
    fi

    local service_name="" bin_path="" base_dir=""
    case "$service_type" in
        singbox) service_name="$SB_SERVICE_NAME"; bin_path="$SB_BIN_PATH"; base_dir="$SB_BASE_DIR" ;;
        mihomo) service_name="$MH_SERVICE_NAME"; bin_path="$MH_BIN_PATH"; base_dir="$MH_BASE_DIR" ;;
    esac

    log "正在停止并禁用 ${service_name} 服务..."
    if [ "$SYSTEM_TYPE" = "openwrt" ]; then
        local service_file="/etc/init.d/$service_name"
        if [ -f "$service_file" ]; then
            "$service_file" stop || true
            "$service_file" disable || true
            rm -f "$service_file"
        fi
    else
        systemctl stop "$service_name" || true
        systemctl disable "$service_name" || true
        rm -f "/etc/systemd/system/$service_name.service"
        systemctl daemon-reload
    fi

    log "正在删除 ${service_name} 可执行文件和配置文件..."
    rm -f "$bin_path"
    rm -rf "$base_dir"
    green "${service_name} 已成功卸载。"
    return 0
}

# 更新配置并运行
update_config_and_run_internal() {
    local service_type="$1"
    local service_name="" config_file="" bin_path="" env_file="" convert_mode_prefix=""
    case "$service_type" in
        singbox) service_name="Sing-box"; config_file="$SB_CONFIG_FILE"; bin_path="$SB_BIN_PATH"; env_file="$SB_ENV_FILE"; convert_mode_prefix="singbox" ;;
        mihomo) service_name="Mihomo"; config_file="$MH_CONFIG_FILE"; bin_path="$MH_BIN_PATH"; env_file="$MH_ENV_FILE"; convert_mode_prefix="clash" ;;
        *) red "内部错误: 无效的服务类型 '$service_type'。"; return 1 ;;
    esac

    if [ ! -f "$bin_path" ]; then
        red "${service_name} 未安装，请先安装。"
        return 1
    fi

    local PROXY_API_URL=""
    local PROXY_MODE=""
    local CRON_INTERVAL=""

    # 加载环境变量
    if ! load_service_env "$env_file"; then
        yellow "${service_name} 环境变量未配置，请先设置。"
        return 1
    fi
    # 重新加载变量到当前shell
    . "$env_file"

    log "正在获取最新 ${service_name} 配置并运行..."

    # 确保 PROXY_MODE 有默认值
    PROXY_MODE="${PROXY_MODE:-rule}"
    log "从 API 获取 ${service_name} 配置 (模式: ${PROXY_MODE})..."

    local convert_mode=""
    case "$PROXY_MODE" in
        global|gfwlist|rule|direct) convert_mode="${convert_mode_prefix}_${PROXY_MODE}" ;;
        *) convert_mode="${convert_mode_prefix}_rule" ;; # 默认规则模式
    esac

    local api_url_with_mode="$PROXY_API_URL"
    if ! echo "$PROXY_API_URL" | grep -q '?'; then
        api_url_with_mode="${api_url_with_mode}?"
    else
        api_url_with_mode="${api_url_with_mode}&"
    fi
    api_url_with_mode="${api_url_with_mode}mode=${convert_mode}"

    local CONVERTED_CONFIG=""
    CONVERTED_CONFIG=$(curl -s -L --connect-timeout 10 --max-time 30 "$api_url_with_mode")

    if [ -z "$CONVERTED_CONFIG" ]; then
        red "获取或转换 ${service_name} 配置失败。"
        return 1
    fi

    # 验证配置格式
    if [ "$service_type" = "singbox" ] && ! echo "$CONVERTED_CONFIG" | jq . >/dev/null 2>&1; then
        red "获取到的 Sing-box 配置不是有效的 JSON 格式。"
        return 1
    elif [ "$service_type" = "mihomo" ] && ! (echo "$CONVERTED_CONFIG" | grep -q 'port:' && echo "$CONVERTED_CONFIG" | grep -q 'proxies:'); then
        red "获取到的 Mihomo 配置不是有效的 YAML 格式。"
        return 1
    fi

    yellow "正在备份旧的 ${service_name} 配置文件..."
    cp "$config_file" "${config_file}.bak" || { red "备份配置失败"; return 1; }

    echo "$CONVERTED_CONFIG" > "$config_file"
    if [ $? -eq 0 ]; then
        green "${service_name} 配置已更新到 $config_file"
        manage_service_internal "$service_type" "restart" || return 1
    else
        red "写入 ${service_name} 配置失败！"
        return 1
    fi
    return 0
}

# 设置自动更新
setup_scheduled_update_internal() {
    local service_type="$1"
    local cron_target_script=""
    local service_name=""
    local env_file=""

    case "$service_type" in
        singbox)
            service_name="Sing-box"
            cron_target_script="$SB_BASE_DIR/update_config.sh"
            env_file="$SB_ENV_FILE"
            if [ ! -f "$SB_BIN_PATH" ]; then
                red "Sing-box 未安装，无法设置自动更新。"
                return 1
            fi
            ;;
        mihomo)
            service_name="Mihomo"
            cron_target_script="$MH_BASE_DIR/update_config.sh"
            env_file="$MH_ENV_FILE"
            if [ ! -f "$MH_BIN_PATH" ]; then
                red "Mihomo 未安装，无法设置自动更新。"
                return 1
            fi
            ;;
        *)
            red "内部错误: 无效的服务类型 '$service_type'。"
            return 1
            ;;
    esac

    local PROXY_API_URL=""
    local PROXY_MODE=""
    local CRON_INTERVAL=""

    if ! load_service_env "$env_file"; then
        yellow "${service_name} 环境变量未配置，请先设置。"
        setup_service_env "$env_file" "$service_name" "global/gfwlist/rule/direct" || return 1
        . "$env_file" # 重新加载新设置的环境变量
    fi

    . "$env_file" # 加载环境变量

    if [ -z "$CRON_INTERVAL" ] || [ "$CRON_INTERVAL" -eq 0 ]; then
        yellow "${service_name} 自动更新未启用 (间隔时间为 0 或未设置)。"
        disable_scheduled_update_internal "$service_type" # 禁用确保没有残留
        return 0
    fi

    log "正在为 ${service_name} 设置自动更新 (每 ${CRON_INTERVAL} 分钟)..."

    mkdir -p "$(dirname "$cron_target_script")"
    # 创建一个用于cron执行的脚本
    cat << EOF > "$cron_target_script"
#!/bin/bash
# 自动更新 ${service_name} 配置脚本
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
LOG_FILE="$LOG_FILE"
RED='\\033[0;31m'
GREEN='\\033[0;32m'
YELLOW='\\033[0;33m'
NC='\\033[0m'

log() {
    timestamp=\$(date +'%Y-%m-%d %H:%M:%S')
    echo "[\$timestamp] \$1" >> "\$LOG_FILE"
}

red() { printf "%b%s%b\\n" "\$RED" "\$1" "\$NC"; }
green() { printf "%b%s%b\\n" "\$GREEN" "\$1" "\$NC"; }
yellow() { printf "%b%s%b\\n" "\$YELLOW" "\$1" "\$NC"; }

check_network() {
    ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1
}

# 加载服务环境变量
if [ -f "$env_file" ]; then
    . "$env_file"
else
    log "${service_name} 环境变量文件 \$env_file 不存在，无法更新。"
    exit 1
fi

if ! check_network; then
    log "网络连接中断，跳过 ${service_name} 配置更新。"
    exit 1
fi

SERVICE_TYPE="${service_type}"
SERVICE_NAME_DISPLAY="${service_name}"
CONFIG_FILE="${config_file}"
BIN_PATH="${bin_path}"
ENV_FILE="${env_file}"
CONVERT_MODE_PREFIX="${convert_mode_prefix}"

log "开始自动更新 \$SERVICE_NAME_DISPLAY 配置..."

# 确保 PROXY_MODE 有默认值
PROXY_MODE="\${PROXY_MODE:-rule}"

local_convert_mode=""
case "\$PROXY_MODE" in
    global|gfwlist|rule|direct) local_convert_mode="\${CONVERT_MODE_PREFIX}_\$PROXY_MODE" ;;
    *) local_convert_mode="\${CONVERT_MODE_PREFIX}_rule" ;;
esac

api_url_to_fetch="\$PROXY_API_URL"
if ! echo "\$PROXY_API_URL" | grep -q '?'; then
    api_url_to_fetch="\${api_url_to_fetch}?"
else
    api_url_to_fetch="\${api_url_to_fetch}&"
fi
api_url_to_fetch="\${api_url_to_fetch}mode=\${local_convert_mode}"

CONVERTED_CONFIG=\$(curl -s -L --connect-timeout 15 --max-time 60 "\$api_url_to_fetch")

if [ -z "\$CONVERTED_CONFIG" ]; then
    log "自动更新失败: 获取或转换 \$SERVICE_NAME_DISPLAY 配置失败。"
    exit 1
fi

if [ "\$SERVICE_TYPE" = "singbox" ] && ! echo "\$CONVERTED_CONFIG" | jq . >/dev/null 2>&1; then
    log "自动更新失败: 获取到的 Sing-box 配置不是有效的 JSON 格式。"
    exit 1
elif [ "\$SERVICE_TYPE" = "mihomo" ] && ! (echo "\$CONVERTED_CONFIG" | grep -q 'port:' && echo "\$CONVERTED_CONFIG" | grep -q 'proxies:'); then
    log "自动更新失败: 获取到的 Mihomo 配置不是有效的 YAML 格式。"
    exit 1
fi

cp "\$CONFIG_FILE" "\${CONFIG_FILE}.bak" || { log "自动更新失败: 备份配置失败"; exit 1; }
echo "\$CONVERTED_CONFIG" > "\$CONFIG_FILE"
if [ \$? -eq 0 ]; then
    log "\$SERVICE_NAME_DISPLAY 配置已成功更新。"
    # 尝试重启服务
    if command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then
        systemctl restart "\$SERVICE_TYPE" || log "自动更新后重启 \$SERVICE_TYPE 服务失败。"
    elif [ -f "/etc/init.d/\$SERVICE_TYPE" ]; then # OpenWrt
        "/etc/init.d/\$SERVICE_TYPE" restart || log "自动更新后重启 \$SERVICE_TYPE 服务失败。"
    else
        log "无法识别系统服务管理器，请手动重启 \$SERVICE_TYPE 服务。"
    fi
else
    log "自动更新失败: 写入 \$SERVICE_NAME_DISPLAY 配置失败！"
    exit 1
fi
EOF
    chmod +x "$cron_target_script"

    # 添加或更新 Cron 任务
    local cron_job_id="${service_type}_proxy_update"
    local cron_entry="*/${CRON_INTERVAL} * * * * bash $cron_target_script >> $LOG_FILE 2>&1"

    # 移除旧的 cron 任务，如果存在
    (crontab -l 2>/dev/null | grep -v "$cron_job_id") | crontab -
    # 添加新的 cron 任务
    (crontab -l 2>/dev/null; echo "# $cron_job_id"; echo "$cron_entry") | crontab -

    green "${service_name} 自动更新已设置成功，每 ${CRON_INTERVAL} 分钟执行一次。"
    return 0
}

# 禁用自动更新
disable_scheduled_update_internal() {
    local service_type="$1"
    local service_name=""
    local cron_target_script=""

    case "$service_type" in
        singbox)
            service_name="Sing-box"
            cron_target_script="$SB_BASE_DIR/update_config.sh"
            ;;
        mihomo)
            service_name="Mihomo"
            cron_target_script="$MH_BASE_DIR/update_config.sh"
            ;;
        *)
            red "内部错误: 无效的服务类型 '$service_type'。"
            return 1
            ;;
    esac

    log "正在禁用 ${service_name} 自动更新..."
    local cron_job_id="${service_type}_proxy_update"
    (crontab -l 2>/dev/null | grep -v "$cron_job_id") | crontab -
    rm -f "$cron_target_script" # 删除 cron 脚本
    green "${service_name} 自动更新已禁用。"
    return 0
}

# 管理服务（启动、停止、重启、查看状态）
manage_service_internal() {
    local service_type="$1"
    local action="$2"
    local service_name=""

    case "$service_type" in
        singbox) service_name="$SB_SERVICE_NAME" ;;
        mihomo) service_name="$MH_SERVICE_NAME" ;;
        *) red "内部错误: 无效的服务类型 '$service_type'。"; return 1 ;;
    esac

    local service_bin=""
    case "$service_type" in
        singbox) service_bin="$SB_BIN_PATH" ;;
        mihomo) service_bin="$MH_BIN_PATH" ;;
    esac

    if [ ! -f "$service_bin" ]; then
        red "${service_name} 未安装，无法执行操作 $action。"
        return 1
    fi

    log "正在对 ${service_name} 执行操作: $action..."
    if [ "$SYSTEM_TYPE" = "openwrt" ]; then
        local init_script="/etc/init.d/$service_name"
        if [ ! -f "$init_script" ]; then
            red "OpenWrt Init 脚本 $init_script 不存在，请先安装服务。"
            return 1
        fi
        case "$action" in
            start) "$init_script" start ;;
            stop) "$init_script" stop ;;
            restart) "$init_script" restart ;;
            status) "$init_script" status ;;
            *) red "OpenWrt 不支持的操作: $action" ; return 1 ;;
        esac
    else # systemd 或其他
        if ! command -v systemctl >/dev/null 2>&1; then
            red "未找到 systemctl 命令，无法管理服务。"
            return 1
        fi
        case "$action" in
            start) systemctl start "$service_name" ;;
            stop) systemctl stop "$service_name" ;;
            restart) systemctl restart "$service_name" ;;
            status) systemctl status "$service_name" ;;
            *) red "不支持的操作: $action" ; return 1 ;;
        esac
    fi

    if [ $? -eq 0 ]; then
        green "${service_name} 已成功执行 $action 操作。"
        return 0
    else
        red "${service_name} 执行 $action 操作失败！"
        return 1
    fi
}

# 查看日志
view_log_internal() {
    local service_type="$1"
    local log_path="$LOG_FILE" # 脚本本身的日志
    local service_log_cmd=""

    case "$service_type" in
        singbox)
            if [ "$SYSTEM_TYPE" = "openwrt" ]; then
                service_log_cmd="logread -e sing-box" # OpenWrt 查看 sing-box 日志
            else
                service_log_cmd="journalctl -u sing-box --since \"1 hour ago\"" # systemd 查看 sing-box 日志
            fi
            ;;
        mihomo)
            if [ "$SYSTEM_TYPE" = "openwrt" ]; then
                service_log_cmd="logread -e mihomo" # OpenWrt 查看 mihomo 日志
            else
                service_log_cmd="journalctl -u mihomo --since \"1 hour ago\"" # systemd 查看 mihomo 日志
            fi
            ;;
        *)
            red "内部错误: 无效的服务类型 '$service_type'。"
            return 1
            ;;
    esac

    log "正在查看 ${service_type} 日志..."
    echo ""
    yellow "=== ${service_type} 服务日志 (最近1小时，或OpenWrt系统日志中的相关条目) ==="
    if [ -n "$service_log_cmd" ]; then
        eval "$service_log_cmd" | tail -n 50 || yellow "无法获取 ${service_type} 服务日志，可能服务没有生成日志或日志已滚动。"
    else
        yellow "当前系统下无法通过标准方式获取 ${service_type} 服务日志，请手动查看相关日志文件或journalctl。"
    fi
    echo ""
    yellow "=== 脚本自身日志 ($log_path) (最近50行) ==="
    tail -n 50 "$log_path" || yellow "无法读取脚本日志文件: $log_path"
    echo ""
    return 0
}

# Sing-box 管理菜单
singbox_management_menu() {
    while true; do
        clear
        printf "\\n%b=== Sing-box 管理 ===%b\\n" "$GREEN" "$NC"
        printf "  1) 安装/重新安装 Sing-box\n"
        printf "  2) 设置 Sing-box 环境变量\n"
        printf "  3) 更新 Sing-box 配置并运行\n"
        printf "  4) 启动 Sing-box 服务\n"
        printf "  5) 停止 Sing-box 服务\n"
        printf "  6) 重启 Sing-box 服务\n"
        printf "  7) 查看 Sing-box 服务状态\n"
        printf "  8) 设置/禁用 Sing-box 自动更新\n"
        printf "  9) 卸载 Sing-box\n"
        printf "  v) 查看 Sing-box 日志\n"
        printf "  b) 返回主菜单\n"
        printf "%b========================%b\\n" "$GREEN" "$NC"
        printf "请输入选项: "
        read -r choice

        case "$choice" in
            1) install_singbox ;;
            2) setup_service_env "$SB_ENV_FILE" "Sing-box" "global/gfwlist/rule/direct" ;;
            3) update_config_and_run_internal "singbox" ;;
            4) manage_service_internal "singbox" "start" ;;
            5) manage_service_internal "singbox" "stop" ;;
            6) manage_service_internal "singbox" "restart" ;;
            7) manage_service_internal "singbox" "status" ;;
            8)
                printf "%b请选择自动更新操作:%b\\n" "$YELLOW" "$NC"
                printf "    1) 设置自动更新\n"
                printf "    2) 禁用自动更新\n"
                printf "    q) 取消\n"
                printf "  请输入选项: "
                read -r update_choice
                case "$update_choice" in
                    1) setup_scheduled_update_internal "singbox" ;;
                    2) disable_scheduled_update_internal "singbox" ;;
                    q|Q) green "取消自动更新操作。";;
                    *) red "无效选项 '$update_choice'";;
                esac
                ;;
            9) uninstall_service "singbox" ;;
            v|V) view_log_internal "singbox" ;;
            b|B) green "返回主菜单。"; return 0 ;;
            *) red "无效选项 '$choice'" ;;
        esac
        printf "\\n%b按 [Enter] 键继续...%b" "$YELLOW" "$NC"
        read -r dummy_input
    done
}

# Mihomo 管理菜单
mihomo_management_menu() {
    while true; do
        clear
        printf "\\n%b=== Mihomo 管理 ===%b\\n" "$GREEN" "$NC"
        printf "  1) 安装/重新安装 Mihomo (稳定版)\n"
        printf "  2) 安装/重新安装 Mihomo Alpha (Smart Group)\n"
        printf "  3) 设置 Mihomo 环境变量\n"
        printf "  4) 更新 Mihomo 配置并运行\n"
        printf "  5) 启动 Mihomo 服务\n"
        printf "  6) 停止 Mihomo 服务\n"
        printf "  7) 重启 Mihomo 服务\n"
        printf "  8) 查看 Mihomo 服务状态\n"
        printf "  9) 设置/禁用 Mihomo 自动更新\n"
        printf "  a) 卸载 Mihomo\n"
        printf "  v) 查看 Mihomo 日志\n"
        printf "  b) 返回主菜单\n"
        printf "%b========================%b\\n" "$GREEN" "$NC"
        printf "请输入选项: "
        read -r choice

        case "$choice" in
            1) install_mihomo ;;
            2) install_mihomo_alpha_smart ;;
            3) setup_service_env "$MH_ENV_FILE" "Mihomo" "global/gfwlist/rule/direct" ;;
            4) update_config_and_run_internal "mihomo" ;;
            5) manage_service_internal "mihomo" "start" ;;
            6) manage_service_internal "mihomo" "stop" ;;
            7) manage_service_internal "mihomo" "restart" ;;
            8) manage_service_internal "mihomo" "status" ;;
            9)
                printf "%b请选择自动更新操作:%b\\n" "$YELLOW" "$NC"
                printf "    1) 设置自动更新\n"
                printf "    2) 禁用自动更新\n"
                printf "    q) 取消\n"
                printf "  请输入选项: "
                read -r update_choice
                case "$update_choice" in
                    1) setup_scheduled_update_internal "mihomo" ;;
                    2) disable_scheduled_update_internal "mihomo" ;;
                    q|Q) green "取消自动更新操作。";;
                    *) red "无效选项 '$update_choice'";;
                esac
                ;;
            a|A) uninstall_service "mihomo" ;;
            v|V) view_log_internal "mihomo" ;;
            b|B) green "返回主菜单。"; return 0 ;;
            *) red "无效选项 '$choice'" ;;
        esac
        printf "\\n%b按 [Enter] 键继续...%b" "$YELLOW" "$NC"
        read -r dummy_input
    done
}

# 通用系统设置菜单
common_settings_menu() {
    while true; do
        clear
        printf "\\n%b=== 通用系统设置 ===%b\\n" "$GREEN" "$NC"
        printf "  1) 检查网络连通性\n"
        printf "  2) 配置网络转发与 NAT\n"
        printf "  q) 返回主菜单\n"
        printf "%b======================%b\\n" "$GREEN" "$NC"
        printf "请输入选项: "
        read -r choice

        case "$choice" in
            1) check_network ;;
            2) configure_network_forwarding_nat ;;
            q|Q) green "返回主菜单。"; return 0 ;;
            *) red "无效选项 '$choice'" ;;
        esac
        printf "\\n%b按 [Enter] 键继续...%b" "$YELLOW" "$NC"
        read -r dummy_input
    done
}


# 脚本入口菜单
initial_selection_menu() {
    while true; do
        clear
        printf "\\n%b=== 代理管理器 (v1.5) ===%b\\n" "$GREEN" "$NC"
        printf "设备: %s (%s)\\n" "$DEVICE_NAME" "$SYSTEM_TYPE"
        printf "日志: %s\\n" "$LOG_FILE"
        printf "\\n%b请选择您要管理的服务或操作:%b\\n" "$YELLOW" "$NC"
        printf "  1) 管理 Sing-box\\n"
        printf "  2) 管理 Mihomo\\n"
        printf "  3) 通用系统设置\\n"
        printf "  q) 退出脚本\\n"
        printf "%b============================%b\\n" "$GREEN" "$NC"
        printf "请输入选项: "
        read -r choice

        case "$choice" in
            1) singbox_management_menu ;;
            2) mihomo_management_menu ;;
            3) common_settings_menu ;;
            q|Q) green "正在退出脚本..."; exit 0 ;;
            *) red "无效选项 '$choice'";;
        esac
        printf "\\n%b按 [Enter] 键继续...%b" "$YELLOW" "$NC"
        read -r dummy_input
    done
}

# 脚本主程序
main() {
    check_root
    install_deps # 首次运行安装依赖
    initial_selection_menu
}

# 执行主程序
main
