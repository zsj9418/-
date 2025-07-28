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

    # 应用 sysctl 配置
    sysctl -p >/dev/null 2>&1 || yellow "sysctl -p 应用配置时出错，可能部分设置无效。"


    # 配置 IPv4 NAT 规则
    local NAT_SOURCE_CIDR="192.168.0.0/16"
    if ! iptables -t nat -C POSTROUTING -s "$NAT_SOURCE_CIDR" -j MASQUERADE 2>/dev/null; then
        yellow "添加 IPv4 NAT 规则 (MASQUERADE for $NAT_SOURCE_CIDR)..."
        if iptables -t nat -A POSTROUTING -s "$NAT_SOURCE_CIDR" -j MASQUERADE; then
            green "IPv4 NAT 规则添加成功"
            if [ "$SYSTEM_TYPE" = "openwrt" ]; then
                yellow "OpenWrt 系统：请手动将 IPv4 NAT 规则添加到 UCI 防火墙配置以实现持久化。"
                yellow "  示例: uci add firewall rule; uci set firewall.@rule[-1].name='Masquerade_Proxy_IPv4'; ..."
            elif command -v iptables-save >/dev/null 2>&1; then
                mkdir -p /etc/iptables
                iptables-save > /etc/iptables/rules.v4 || red "IPv4 iptables-save 保存规则失败"
            fi
        else
            red "添加 IPv4 NAT 规则失败"
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
                elif command -v ip6tables-save >/dev/null 2>&1; then
                    mkdir -p /etc/iptables
                    ip6tables-save > /etc/iptables/rules.v6 || red "IPv6 ip6tables-save 保存规则失败"
                fi
            else
                red "添加 IPv6 NAT 规则失败"
            fi
        else
            green "IPv6 NAT 规则 (MASQUERADE for $NAT_SOURCE_CIDR_V6) 已存在"
        fi
    fi

    return 0
}

# 加载环境变量
load_service_env() {
    local env_file="$1"
    if [ -f "$env_file" ]; then
        # 清空可能存在的旧变量，避免干扰
        PROXY_API_URL=""
        PROXY_MODE=""
        CRON_INTERVAL=""
        # shellcheck source=/dev/null
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
    chmod 600 "$env_file"
    green "${service_name} 环境变量设置完成并保存到 $env_file。"
    
    # 如果设置了cron，立即应用
    if [ "$CRON_INTERVAL" -gt 0 ]; then
        setup_cron_job_internal "$service_type" "$CRON_INTERVAL"
    else
        disable_scheduled_update_internal "$service_type"
    fi
    return 0
}

# 获取 Sing-box 版本列表
get_singbox_versions() {
    local arch="$1"
    local releases_info
    releases_info=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases?per_page=10") || {
        red "无法获取 Sing-box 版本信息，请检查网络或 GitHub API 限制。"
        return 1
    }

    local versions=()
    local i=0
    while IFS= read -r release_info; do
        local tag_name is_prerelease download_url asset_name
        
        tag_name=$(echo "$release_info" | jq -r '.tag_name')
        is_prerelease=$(echo "$release_info" | jq -r '.prerelease')
        
        asset_name="sing-box-$(echo "$tag_name" | sed 's/^v//')-linux-${arch}.tar.gz"
        download_url=$(echo "$release_info" | jq -r ".assets[] | select(.name == \"$asset_name\") | .browser_download_url")

        if [ -n "$download_url" ]; then
            versions[$i]="${tag_name}|${is_prerelease}|${download_url}|${asset_name}"
            ((i++))
        fi
    done < <(echo "$releases_info" | jq -c '.[]')

    if [ ${#versions[@]} -eq 0 ]; then
        red "未找到适用于架构 $arch 的 Sing-box 版本。"
        return 1
    fi

    echo "${versions[@]}"
    return 0
}

# 安装 Sing-box (交互式版本选择)
install_singbox() {
    log "开始安装 Sing-box..."
    check_network || return 1
    configure_network_forwarding_nat || return 1

    local local_arch; local_arch=$(get_arch) || return 1
    
    log "正在获取 Sing-box 可用版本列表..."
    local versions_str; versions_str=$(get_singbox_versions "$local_arch") || return 1

    local versions_array=($versions_str)
    clear
    printf "\\n%b=== 选择要安装的 Sing-box 版本 ===%b\\n" "$GREEN" "$NC"
    local i=1
    declare -A version_map
    for version_info in "${versions_array[@]}"; do
        IFS='|' read -r tag_name is_prerelease download_url asset_name <<< "$version_info"
        if [ "$is_prerelease" = "true" ]; then
            printf "  %d) %b%s (Pre-release)%b\\n" "$i" "$YELLOW" "$tag_name" "$NC"
        else
            printf "  %d) %s (Stable)\\n" "$i" "$tag_name"
        fi
        version_map[$i]="$download_url|$asset_name|$tag_name"
        ((i++))
    done
    printf "%b=====================================%b\\n" "$GREEN" "$NC"
    printf "请输入选项 (1-%d，推荐选择最新的 Stable 版本): " "${#versions_array[@]}"
    read -r choice

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#versions_array[@]}" ]; then
        red "无效选项 '$choice'，安装取消。"
        return 1
    fi

    local selected_version=${version_map[$choice]}
    local DOWNLOAD_URL; DOWNLOAD_URL=$(echo "$selected_version" | cut -d'|' -f1)
    local FILENAME; FILENAME=$(echo "$selected_version" | cut -d'|' -f2)
    local VERSION_TAG; VERSION_TAG=$(echo "$selected_version" | cut -d'|' -f3)

    TEMP_DIR=$(mktemp -d)
    local TAR_PATH="$TEMP_DIR/$FILENAME"

    log "下载 Sing-box $VERSION_TAG ($local_arch)..."
    if ! curl -L -o "$TAR_PATH" "$DOWNLOAD_URL"; then
        red "下载 Sing-box 失败！URL: ${DOWNLOAD_URL}"; cleanup; return 1
    fi

    log "解压文件..."
    if ! tar -xzf "$TAR_PATH" -C "$TEMP_DIR"; then
        red "解压 Sing-box 失败！"; cleanup; return 1
    fi

    local SINGBOX_BIN_UNPACKED; SINGBOX_BIN_UNPACKED=$(find "$TEMP_DIR" -type f -name "sing-box" -perm /a+x | head -n 1)
    if [ -z "$SINGBOX_BIN_UNPACKED" ]; then
        red "未找到 Sing-box 可执行文件！"; cleanup; return 1
    fi
    
    manage_service_internal "singbox" "stop" &>/dev/null
    mkdir -p "$(dirname "$SB_BIN_PATH")" || { red "创建安装目录失败"; cleanup; return 1; }

    log "安装 Sing-box 到 $SB_BIN_PATH..."
    if ! cp "$SINGBOX_BIN_UNPACKED" "$SB_BIN_PATH"; then
        red "复制 Sing-box 可执行文件失败。"; cleanup; return 1
    fi
    chmod +x "$SB_BIN_PATH"

    cleanup
    green "Sing-box $VERSION_TAG 安装成功！"

    if [ ! -f "$SB_CONFIG_FILE" ]; then generate_initial_singbox_config; fi
    setup_service "singbox"
    manage_autostart_internal "singbox" "enable"
    
    green "Sing-box 部署完成。默认已设置为开机自启。"
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
    green "Sing-box 初始配置文件已生成：$SB_CONFIG_FILE"
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

# 安装 Mihomo 稳定版
install_mihomo() {
    log "开始安装 Mihomo..."
    check_network || return 1
    configure_network_forwarding_nat || return 1

    log "正在获取 Mihomo 最新版本号..."
    local latest_version; latest_version=$(get_mihomo_latest_version) || { red "获取 Mihomo 最新版本失败。"; return 1; }
    green "Mihomo 最新版本: $latest_version"

    local local_arch; local_arch=$(get_arch) || return 1
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
        red "下载 Mihomo 失败！"; cleanup; return 1
    fi

    log "解压文件..."
    if ! gzip -d "$GZ_PATH"; then
        red "解压 Mihomo 失败！"; cleanup; return 1
    fi
    local MIHOMO_BIN_UNPACKED="${GZ_PATH%.gz}"

    if [ ! -f "$MIHOMO_BIN_UNPACKED" ]; then
        red "未找到 Mihomo 可执行文件！"; cleanup; return 1
    fi
    
    manage_service_internal "mihomo" "stop" &>/dev/null
    mkdir -p "$(dirname "$MH_BIN_PATH")" || { red "创建安装目录失败"; cleanup; return 1; }

    log "安装 Mihomo 到 $MH_BIN_PATH..."
    cp "$MIHOMO_BIN_UNPACKED" "$MH_BIN_PATH"
    chmod +x "$MH_BIN_PATH"

    cleanup
    green "Mihomo $latest_version 安装成功！"

    if [ ! -f "$MH_CONFIG_FILE" ]; then generate_initial_mihomo_config; fi
    setup_service "mihomo"
    manage_autostart_internal "mihomo" "enable"
    
    green "Mihomo 部署完成。默认已设置为开机自启。"
    return 0
}

# 获取 Mihomo Alpha 版本列表
get_mihomo_alpha_versions() {
    local arch="$1"
    local releases_info
    releases_info=$(curl -s "https://api.github.com/repos/vernesong/mihomo/releases") || {
        red "无法获取 Mihomo Alpha 版本信息。"; return 1
    }

    local versions=()
    local i=0
    while IFS= read -r asset_info; do
        local asset_name download_url commit_id published_at
        asset_name=$(echo "$asset_info" | jq -r '.name')
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

# 安装 Mihomo Alpha 版
install_mihomo_alpha_smart() {
    log "开始安装 Mihomo Alpha with Smart Group 版本..."
    check_network || return 1
    configure_network_forwarding_nat || return 1

    local local_arch; local_arch=$(get_arch) || return 1
    if [[ ! " amd64 arm64 " =~ " ${local_arch} " ]]; then
        red "暂无 $local_arch 架构的 Mihomo Alpha with Smart Group 版本支持。"
        return 1
    fi

    log "正在获取 Mihomo Alpha with Smart Group 可用版本..."
    local versions; versions=$(get_mihomo_alpha_versions "$local_arch") || return 1

    local version_array=($versions)
    clear
    printf "\\n%b=== 选择 Mihomo Alpha (Smart Group) 版本 ===%b\\n" "$GREEN" "$NC"
    local i=1
    declare -A version_map
    for version_info in "${version_array[@]}"; do
        IFS='|' read -r commit_id published_at download_url asset_name <<< "$version_info"
        printf "  %d) Commit: %s (发布于: %s)\\n" "$i" "$commit_id" "$published_at"
        version_map[$i]="$download_url|$asset_name"
        ((i++))
    done
    printf "%b=====================================%b\\n" "$GREEN" "$NC"
    printf "请输入选项 (1-%d): " "${#version_array[@]}"
    read -r choice

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#version_array[@]}" ]; then
        red "无效选项 '$choice'，安装取消。"; return 1
    fi

    local selected_version=${version_map[$choice]}
    local DOWNLOAD_URL; DOWNLOAD_URL=$(echo "$selected_version" | cut -d'|' -f1)
    local FILENAME; FILENAME=$(echo "$selected_version" | cut -d'|' -f2)

    TEMP_DIR=$(mktemp -d)
    local GZ_PATH="$TEMP_DIR/$FILENAME"

    log "下载 Mihomo Alpha ($FILENAME)..."
    if ! curl -L -o "$GZ_PATH" "$DOWNLOAD_URL"; then
        red "下载失败！"; cleanup; return 1
    fi

    log "解压文件..."
    if ! gzip -d "$GZ_PATH"; then
        red "解压失败！"; cleanup; return 1
    fi
    local MIHOMO_BIN_UNPACKED="${GZ_PATH%.gz}"

    if [ ! -f "$MIHOMO_BIN_UNPACKED" ]; then
        red "未找到可执行文件！"; cleanup; return 1
    fi

    manage_service_internal "mihomo" "stop" &>/dev/null
    mkdir -p "$(dirname "$MH_BIN_PATH")" || { red "创建安装目录失败"; cleanup; return 1; }

    log "安装 Mihomo Alpha 到 $MH_BIN_PATH..."
    cp "$MIHOMO_BIN_UNPACKED" "$MH_BIN_PATH"
    chmod +x "$MH_BIN_PATH"

    local MODEL_BIN_PATH="$MH_BASE_DIR/Model.bin"
    log "正在检查 LightGBM Model (Model.bin)..."
    local model_url
    model_url=$(curl -s "https://api.github.com/repos/vernesong/mihomo/releases/tags/LightGBM-Model" | jq -r '.assets[] | select(.name == "Model.bin") | .browser_download_url')

    if [ -n "$model_url" ]; then
        log "下载 Model.bin 到 $MODEL_BIN_PATH..."
        curl -L -o "$MODEL_BIN_PATH" "$model_url" || red "下载 Model.bin 失败。"
    else
        yellow "未找到 Model.bin 下载链接，跳过。"
    fi
    
    cleanup
    green "Mihomo Alpha with Smart Group 安装成功！"

    if [ ! -f "$MH_CONFIG_FILE" ]; then generate_initial_mihomo_config; fi
    setup_service "mihomo"
    manage_autostart_internal "mihomo" "enable"
    green "Mihomo Alpha 部署完成。默认已设置为开机自启。"
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
    green "Mihomo 初始配置文件已生成：$MH_CONFIG_FILE"
    return 0
}

# 创建服务文件
setup_service() {
    local service_type="$1"
    log "创建/更新 ${service_type} 服务文件..."

    if [ "$SYSTEM_TYPE" = "openwrt" ]; then
        local service_name="" bin_path="" exec_params=""
        case "$service_type" in
            singbox) service_name="$SB_SERVICE_NAME"; bin_path="$SB_BIN_PATH"; exec_params="run -c $SB_CONFIG_FILE" ;;
            mihomo) service_name="$MH_SERVICE_NAME"; bin_path="$MH_BIN_PATH"; exec_params="-d $MH_BASE_DIR" ;;
        esac
        local service_file="/etc/init.d/$service_name"
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
    else
        local service_name="" description="" exec_start=""
        case "$service_type" in
            singbox) service_name="$SB_SERVICE_NAME"; description="Sing-box"; exec_start="$SB_BIN_PATH run -c $SB_CONFIG_FILE" ;;
            mihomo) service_name="$MH_SERVICE_NAME"; description="Mihomo"; exec_start="$MH_BIN_PATH -d $MH_BASE_DIR" ;;
        esac
        local service_file="/etc/systemd/system/$service_name.service"
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
    fi
    green "${service_type} 服务文件已创建/更新。"
    return 0
}

# 卸载服务
uninstall_service() {
    local service_type="$1"
    yellow "警告：这将完全卸载 ${service_type} 及其所有相关文件。"
    printf "您确定要继续吗？(y/N): "
    read -r confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        green "卸载已取消。"
        return 0
    fi

    local service_name="" bin_path="" base_dir=""
    case "$service_type" in
        singbox) service_name="$SB_SERVICE_NAME"; bin_path="$SB_BIN_PATH"; base_dir="$SB_BASE_DIR" ;;
        mihomo) service_name="$MH_SERVICE_NAME"; bin_path="$MH_BIN_PATH"; base_dir="$MH_BASE_DIR" ;;
    esac

    log "正在停止并禁用 ${service_name} 服务..."
    manage_service_internal "$service_type" "stop"
    manage_autostart_internal "$service_type" "disable"

    if [ "$SYSTEM_TYPE" = "openwrt" ]; then
        rm -f "/etc/init.d/$service_name"
    else
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
        *) red "内部错误。"; return 1 ;;
    esac

    if [ ! -f "$bin_path" ]; then red "${service_name} 未安装。"; return 1; fi
    
    if ! load_service_env "$env_file"; then
        yellow "${service_name} 环境变量未配置。"
        return 1
    fi
    
    if [ -z "${PROXY_API_URL:-}" ]; then
        red "错误: 环境变量 PROXY_API_URL 未在 $env_file 中定义！"
        return 1
    fi
    
    local current_proxy_mode=${PROXY_MODE:-rule}
    
    log "从 API 获取 ${service_name} 配置 (模式: ${current_proxy_mode})..."

    local convert_mode="${convert_mode_prefix}_${current_proxy_mode}"
    local api_url_with_mode="${PROXY_API_URL}"
    if ! echo "$api_url_with_mode" | grep -q '?'; then api_url_with_mode+="?"; else api_url_with_mode+="&"; fi
    api_url_with_mode+="mode=${convert_mode}"

    local CONVERTED_CONFIG; CONVERTED_CONFIG=$(curl -s -L --connect-timeout 10 --max-time 30 "$api_url_with_mode")

    if [ -z "$CONVERTED_CONFIG" ]; then red "获取或转换配置失败。"; return 1; fi
    
    local temp_config_file; temp_config_file=$(mktemp)
    echo "$CONVERTED_CONFIG" > "$temp_config_file"
    
    yellow "正在验证新的 ${service_name} 配置文件..."
    if ! validate_config_internal "$service_type" "$temp_config_file"; then
        red "从 API 获取的新配置未通过有效性检查！已中止更新。"; rm -f "$temp_config_file"; return 1
    fi
    rm -f "$temp_config_file"

    yellow "正在备份旧配置并应用新配置..."
    cp "$config_file" "${config_file}.bak"
    echo "$CONVERTED_CONFIG" > "$config_file"
    green "${service_name} 配置已更新到 $config_file"
    manage_service_internal "$service_type" "restart"
    return 0
}

# ⭐⭐⭐ REFACTORED: Cron setup logic ⭐⭐⭐

# 仅负责创建 cron 任务
setup_cron_job_internal() {
    local service_type="$1"
    local interval="$2"
    local service_name
    case "$service_type" in
        singbox) service_name="Sing-box" ;;
        mihomo) service_name="Mihomo" ;;
    esac

    log "正在为 ${service_name} 设置自动更新 (每 ${interval} 分钟)..."
    local cron_job_id="${service_type}_proxy_update"
    local cron_entry="*/${interval} * * * * bash $SCRIPT_PATH --update $service_type >> $LOG_FILE 2>&1"
    
    (crontab -l 2>/dev/null | grep -v "$cron_job_id") | crontab -
    (crontab -l 2>/dev/null; echo "# $cron_job_id"; echo "$cron_entry") | crontab -
    
    green "${service_name} 自动更新已设置为每 ${interval} 分钟执行一次。"
}

# 禁用自动更新
disable_scheduled_update_internal() {
    local service_type="$1"
    local service_name
    case "$service_type" in
        singbox) service_name="Sing-box" ;;
        mihomo) service_name="Mihomo" ;;
    esac

    log "正在禁用 ${service_name} 自动更新..."
    local cron_job_id="${service_type}_proxy_update"
    (crontab -l 2>/dev/null | grep -v "$cron_job_id") | crontab -
    green "${service_name} 自动更新已禁用。"
    return 0
}

# ⭐⭐⭐ NEW: Interactive menu for auto-update management ⭐⭐⭐
manage_scheduled_update_menu() {
    local service_type="$1"
    local service_name env_file
    case "$service_type" in
        singbox) service_name="Sing-box"; env_file="$SB_ENV_FILE" ;;
        mihomo) service_name="Mihomo"; env_file="$MH_ENV_FILE" ;;
    esac

    # 检查是否已设置订阅链接
    if ! load_service_env "$env_file" || [ -z "${PROXY_API_URL:-}" ]; then
        red "必须先在“设置环境变量”中配置订阅链接，才能管理自动更新。"
        return 1
    fi
    local current_interval=${CRON_INTERVAL:-0}
    
    clear
    printf "\\n%b=== 管理 %s 自动更新 ===%b\\n" "$GREEN" "$service_name" "$NC"
    if [ "$current_interval" -eq 0 ]; then
        printf "当前状态: %b已禁用%b\\n" "$RED" "$NC"
    else
        printf "当前状态: %b已启用%b (每 %s 分钟一次)\\n" "$GREEN" "$NC" "$current_interval"
    fi
    printf "\\n  1) 设置/更改更新间隔\\n"
    printf "  2) 禁用自动更新\\n"
    printf "  q) 返回\\n"
    printf "%b==============================%b\\n" "$GREEN" "$NC"
    read -r -p "请输入选项: " choice

    case "$choice" in
        1)
            printf "请输入新的自动更新间隔 (分钟, 0 表示禁用): "
            read -r new_interval
            if ! [[ "$new_interval" =~ ^[0-9]+$ ]]; then
                red "无效输入，必须是数字。"
                return 1
            fi
            
            # 更新 .env 文件
            local current_api_url=${PROXY_API_URL}
            local current_mode=${PROXY_MODE:-rule}
            cat << EOF > "$env_file"
# This file stores environment variables for ${service_name}.
PROXY_API_URL="$current_api_url"
PROXY_MODE="$current_mode"
CRON_INTERVAL="$new_interval"
EOF
            chmod 600 "$env_file"

            if [ "$new_interval" -gt 0 ]; then
                setup_cron_job_internal "$service_type" "$new_interval"
            else
                disable_scheduled_update_internal "$service_type"
            fi
            ;;
        2)
            # 更新 .env 文件
            local current_api_url=${PROXY_API_URL}
            local current_mode=${PROXY_MODE:-rule}
            cat << EOF > "$env_file"
# This file stores environment variables for ${service_name}.
PROXY_API_URL="$current_api_url"
PROXY_MODE="$current_mode"
CRON_INTERVAL="0"
EOF
            chmod 600 "$env_file"
            disable_scheduled_update_internal "$service_type"
            ;;
        q|Q)
            return 0
            ;;
        *)
            red "无效选项"
            ;;
    esac
    return 0
}


# 管理服务（启动/停止/重启/状态）
manage_service_internal() {
    local service_type="$1"
    local action="$2"
    local service_name=""
    case "$service_type" in
        singbox) service_name="$SB_SERVICE_NAME" ;;
        mihomo) service_name="$MH_SERVICE_NAME" ;;
        *) red "内部错误。"; return 1 ;;
    esac

    local bin_path; if [ "$service_type" = "singbox" ]; then bin_path="$SB_BIN_PATH"; else bin_path="$MH_BIN_PATH"; fi
    if [ ! -f "$bin_path" ]; then red "${service_name} 未安装。"; return 1; fi

    log "正在对 ${service_name} 执行操作: $action..."
    if [ "$SYSTEM_TYPE" = "openwrt" ]; then
        local init_script="/etc/init.d/$service_name"
        if [ -f "$init_script" ]; then "$init_script" "$action"; fi
    else 
        systemctl "$action" "$service_name"
    fi
    return $?
}

# 验证配置文件
validate_config_internal() {
    local service_type="$1"
    local config_file_override=${2:-}
    local service_name bin_path config_path
    case "$service_type" in
        singbox) service_name="Sing-box"; bin_path="$SB_BIN_PATH"; config_path="$SB_CONFIG_FILE" ;;
        mihomo) service_name="Mihomo"; bin_path="$MH_BIN_PATH"; config_path="$MH_BASE_DIR" ;;
        *) red "内部错误。"; return 1 ;;
    esac

    if [ ! -f "$bin_path" ]; then red "${service_name} 未安装。"; return 1; fi

    local validation_output exit_code
    if [ "$service_type" = "singbox" ]; then
        local file_to_check=${config_file_override:-$config_path}
        if [ ! -f "$file_to_check" ]; then red "配置文件 $file_to_check 不存在。"; return 1; fi
        validation_output=$("$bin_path" check -c "$file_to_check" 2>&1)
        exit_code=$?
    else # mihomo
        local dir_to_check; local temp_dir_created=false
        if [ -n "$config_file_override" ]; then
            dir_to_check=$(mktemp -d); temp_dir_created=true
            cp "$config_file_override" "$dir_to_check/config.yaml"
            [ -f "$MH_BASE_DIR/Model.bin" ] && cp "$MH_BASE_DIR/Model.bin" "$dir_to_check/"
        else
            dir_to_check="$config_path"
        fi
        if [ ! -f "$dir_to_check/config.yaml" ]; then red "配置文件 $dir_to_check/config.yaml 不存在。"; $temp_dir_created && rm -rf "$dir_to_check"; return 1; fi
        validation_output=$("$bin_path" -d "$dir_to_check" -t 2>&1)
        exit_code=$?
        $temp_dir_created && rm -rf "$dir_to_check"
    fi

    if [ $exit_code -eq 0 ]; then
        [ -z "$config_file_override" ] && green "🎉 ${service_name} 配置文件验证通过！"
        return 0
    else
        red "❌ ${service_name} 配置文件验证失败！"
        if [ -z "$config_file_override" ]; then 
            yellow "--- 错误详情 ---"
            printf "%s\n" "$validation_output"
            yellow "------------------"
        fi
        return 1
    fi
}

# 管理自启动
manage_autostart_internal() {
    local service_type="$1"
    local action=${2:-}
    local service_name
    case "$service_type" in
        singbox) service_name="$SB_SERVICE_NAME" ;;
        mihomo) service_name="$MH_SERVICE_NAME" ;;
        *) red "内部错误。"; return 1 ;;
    esac

    if [ -z "$action" ]; then
        clear
        printf "\\n%b=== 管理 %s 自启动 ===%b\\n" "$GREEN" "$service_name" "$NC"
        printf "当前状态: "; manage_autostart_internal "$service_type" "status"
        printf "\\n  1) %b启用%b 开机自启动\\n" "$GREEN" "$NC"
        printf "  2) %b禁用%b 开机自启动\\n" "$RED" "$NC"
        printf "  q) 返回\\n"
        printf "%b========================%b\\n" "$GREEN" "$NC"
        read -r -p "请输入选项: " choice
        case "$choice" in
            1) manage_autostart_internal "$service_type" "enable" ;;
            2) manage_autostart_internal "$service_type" "disable" ;;
            *) return 0 ;;
        esac
        return 0
    fi
    
    if [ "$SYSTEM_TYPE" = "openwrt" ]; then
        local init_script="/etc/init.d/$service_name"
        if [ ! -f "$init_script" ]; then red "服务未安装。"; return 1; fi
        case "$action" in
            enable) "$init_script" enable &>/dev/null; green "${service_name} 已设置为开机自启。" ;;
            disable) "$init_script" disable &>/dev/null; red "${service_name} 已禁止开机自启。" ;;
            status) if [ -L "/etc/rc.d/S95${service_name}" ]; then green "已启用"; else red "已禁用"; fi ;;
        esac
    else # systemd
        case "$action" in
            enable) systemctl enable "$service_name" &>/dev/null; green "${service_name} 已设置为开机自启。" ;;
            disable) systemctl disable "$service_name" &>/dev/null; red "${service_name} 已禁止开机自启。" ;;
            status) if systemctl is-enabled "$service_name" &>/dev/null; then green "已启用"; else red "已禁用"; fi ;;
        esac
    fi
    return 0
}

# 查看日志
view_log_internal() {
    local service_type="$1"
    local log_cmd
    case "$service_type" in
        singbox) log_cmd="journalctl -u $SB_SERVICE_NAME -n 50 --no-pager"; [ "$SYSTEM_TYPE" = "openwrt" ] && log_cmd="logread -e $SB_SERVICE_NAME | tail -n 50" ;;
        mihomo) log_cmd="journalctl -u $MH_SERVICE_NAME -n 50 --no-pager"; [ "$SYSTEM_TYPE" = "openwrt" ] && log_cmd="logread -e $MH_SERVICE_NAME | tail -n 50" ;;
        *) red "内部错误。"; return 1 ;;
    esac
    
    clear
    yellow "--- ${service_type} 服务日志 (最近50条) ---"
    eval "$log_cmd" || yellow "无法获取日志。"
    yellow "----------------------------------------"
    yellow "--- 脚本自身日志 ($LOG_FILE) (最近50行) ---"
    tail -n 50 "$LOG_FILE" || yellow "无法读取脚本日志。"
    yellow "----------------------------------------"
    return 0
}

# Sing-box 管理菜单
singbox_management_menu() {
    while true; do
        clear
        printf "\\n%b=== Sing-box 管理 ===%b\\n" "$GREEN" "$NC"
        printf "  1) 安装/更新 Sing-box (可选版本)\\n"
        printf "  2) 设置环境变量 (订阅等)\n"
        printf "  3) 更新配置并重启\n"
        printf "  4) 启动服务\n"
        printf "  5) 停止服务\n"
        printf "  6) 重启服务\n"
        printf "  7) 查看服务状态\n"
        printf "  8) %b管理自动更新%b\n" "$YELLOW" "$NC"
        printf "  9) 卸载 Sing-box\n"
        printf "  e) 管理服务自启动\n"
        printf "  c) 验证配置文件\n"
        printf "  v) 查看日志\n"
        printf "  b) 返回主菜单\n"
        printf "%b========================%b\\n" "$GREEN" "$NC"
        read -r -p "请输入选项: " choice

        case "$choice" in
            1) install_singbox ;;
            2) setup_service_env "singbox" ;;
            3) update_config_and_run_internal "singbox" ;;
            4) manage_service_internal "singbox" "start" ;;
            5) manage_service_internal "singbox" "stop" ;;
            6) manage_service_internal "singbox" "restart" ;;
            7) manage_service_internal "singbox" "status" ;;
            8) manage_scheduled_update_menu "singbox" ;;
            9) uninstall_service "singbox" ;;
            e|E) manage_autostart_internal "singbox" ;;
            c|C) validate_config_internal "singbox" ;;
            v|V) view_log_internal "singbox" ;;
            b|B) return 0 ;;
            *) red "无效选项" ;;
        esac
        read -r -p "按 [Enter] 键继续..."
    done
}

# Mihomo 管理菜单
mihomo_management_menu() {
    while true; do
        clear
        printf "\\n%b=== Mihomo 管理 ===%b\\n" "$GREEN" "$NC"
        printf "  1) 安装/更新 Mihomo (稳定版)\\n"
        printf "  2) 安装/更新 Mihomo Alpha (Smart Group)\\n"
        printf "  3) 设置环境变量 (订阅等)\n"
        printf "  4) 更新配置并重启\n"
        printf "  5) 启动服务\n"
        printf "  6) 停止服务\n"
        printf "  7) 重启服务\n"
        printf "  8) 查看服务状态\n"
        printf "  9) %b管理自动更新%b\n" "$YELLOW" "$NC"
        printf "  a) 卸载 Mihomo\n"
        printf "  e) 管理服务自启动\n"
        printf "  c) 验证配置文件\n"
        printf "  v) 查看日志\n"
        printf "  b) 返回主菜单\n"
        printf "%b========================%b\\n" "$GREEN" "$NC"
        read -r -p "请输入选项: " choice

        case "$choice" in
            1) install_mihomo ;;
            2) install_mihomo_alpha_smart ;;
            3) setup_service_env "mihomo" ;;
            4) update_config_and_run_internal "mihomo" ;;
            5) manage_service_internal "mihomo" "start" ;;
            6) manage_service_internal "mihomo" "stop" ;;
            7) manage_service_internal "mihomo" "restart" ;;
            8) manage_service_internal "mihomo" "status" ;;
            9) manage_scheduled_update_menu "mihomo" ;;
            a|A) uninstall_service "mihomo" ;;
            e|E) manage_autostart_internal "mihomo" ;;
            c|C) validate_config_internal "mihomo" ;;
            v|V) view_log_internal "mihomo" ;;
            b|B) return 0 ;;
            *) red "无效选项" ;;
        esac
        read -r -p "按 [Enter] 键继续..."
    done
}

# 通用设置菜单
common_settings_menu() {
    while true; do
        clear
        printf "\\n%b=== 通用系统设置 ===%b\\n" "$GREEN" "$NC"
        printf "  1) 检查网络连通性\n"
        printf "  2) 配置网络转发与 NAT\n"
        printf "  q) 返回主菜单\n"
        printf "%b======================%b\\n" "$GREEN" "$NC"
        read -r -p "请输入选项: " choice
        case "$choice" in
            1) check_network ;;
            2) configure_network_forwarding_nat ;;
            q|Q) return 0 ;;
            *) red "无效选项" ;;
        esac
        read -r -p "按 [Enter] 键继续..."
    done
}

# 主菜单
initial_selection_menu() {
    while true; do
        clear
        printf "\\n%b=== 代理管理器 (v1.0 - UI/UX Refined) ===%b\\n" "$GREEN" "$NC"
        printf "设备: %s (%s)\\n" "$DEVICE_NAME" "$SYSTEM_TYPE"
        printf "%b==========================================%b\\n" "$GREEN" "$NC"
        printf "  1) 管理 Sing-box\\n"
        printf "  2) 管理 Mihomo\\n"
        printf "  3) 通用系统设置\\n"
        printf "  q) 退出脚本\\n"
        printf "%b==========================================%b\\n" "$GREEN" "$NC"
        read -r -p "请选择您要管理的服务或操作: " choice
        case "$choice" in
            1) singbox_management_menu ;;
            2) mihomo_management_menu ;;
            3) common_settings_menu ;;
            q|Q) green "正在退出脚本..."; exit 0 ;;
            *) red "无效选项" ;;
        esac
    done
}

# 非交互式模式处理 (用于cron等)
non_interactive_mode() {
    case "$1" in
        --update)
            check_root
            log "Cron 任务触发: 更新 $2"
            update_config_and_run_internal "$2"
            ;;
        *)
            red "不支持的非交互式命令。"
            exit 1
            ;;
    esac
    exit 0
}

# 脚本主程序
main() {
    # 如果有命令行参数，则进入非交互式模式
    if [ $# -gt 0 ]; then
        non_interactive_mode "$@"
        return
    fi

    check_root
    install_deps
    initial_selection_menu
}

# 执行主程序
main "$@"
