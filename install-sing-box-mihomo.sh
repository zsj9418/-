#!/bin/bash
set -u # 仅保留未定义变量检查，移除 -e 以避免自动退出

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

# 新增：下载加速代理前缀 (直连失败时自动回退使用)
PROXY_PREFIX="https://cdn.yyds9527.nyc.mn/"

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

# 获取架构信息（增强兼容，支持更多变种）
get_arch() {
    local machine_arch=$(uname -m)
    case "$machine_arch" in
        x86_64) echo "amd64" ;;
        aarch64|armv8l) echo "arm64" ;;
        armv7l|armv7) echo "armv7" ;;
        armv6l|armv6) echo "armv6" ;;
        riscv64) echo "riscv64" ;;
        i386|i686) echo "386" ;;
        *) red "不支持的架构: $machine_arch"; return 1 ;;
    esac
}

# 判断系统类型（增强 OpenWrt 变种检测）
detect_system() {
    if [ -f /etc/openwrt_release ] || grep -q "OpenWrt" /etc/banner 2>/dev/null; then
        echo "openwrt"
    elif command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then
        echo "systemd"
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

# 通用下载函数，支持代理回退
download_file_with_proxy() {
    local url="$1"
    local output_path="$2"
    local filename="${url##*/}" # 用于日志显示

    log "尝试直连下载 $filename..."
    # 尝试直连下载，超时时间设为 15 秒
    if curl -L --connect-timeout 10 --max-time 15 -o "$output_path" "$url"; then
        green "直连下载成功: $filename"
        return 0
    else
        yellow "直连下载 $filename 失败，正在尝试使用代理下载..."
        local proxied_url="${PROXY_PREFIX}${url}"
        log "代理下载地址: $proxied_url"
        
        # 尝试代理下载，超时时间设为 30 秒
        if curl -L --connect-timeout 10 --max-time 30 -o "$output_path" "$proxied_url"; then
            green "使用代理下载成功: $filename"
            return 0
        else
            red "使用代理下载 $filename 仍然失败！请检查代理前缀或网络。"
            return 1
        fi
    fi
}


# 安装依赖（增强 OpenWrt 变种兼容，处理 opkg 源问题）
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
            pkgs="curl tar iptables ipset jq psmisc unzip" # fzf 可选，cron 在 OpenWrt 中通常内置 busybox
            cron_pkg="cron" # OpenWrt 变种可能使用 busybox-cron
            ;;
        *)
            red "不支持的包管理器，请手动安装 curl, tar, iptables, ipset, jq, psmisc, cron, unzip, fzf"
            return 1
            ;;
    esac

    pkgs=$(echo "$pkgs" | sed "s/cron/$cron_pkg/")

    log "使用包管理器: $pkg_manager"
    if [ -n "$update_cmd" ]; then
        $update_cmd || { red "包列表更新失败（OpenWrt 变种请检查 opkg 源）"; return 1; }
    fi

    for pkg in $pkgs; do
        if ! $install_cmd "$pkg" >/dev/null 2>&1; then
            yellow "安装依赖 $pkg 失败（OpenWrt 变种可能需手动添加第三方源），稍后请手动安装。"
            failed_pkgs="$failed_pkgs $pkg"
        else
            green "成功安装依赖 $pkg"
        fi
    done

    if ! command -v fzf >/dev/null 2>&1; then
        if [ "$SYSTEM_TYPE" = "openwrt" ]; then
            yellow "fzf 在 OpenWrt 默认软件源中可能不可用，跳过 fzf 安装（可选依赖）。"
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
        if [ -f /etc/init.d/cron ] || command -v crond >/dev/null 2>&1; then
            /etc/init.d/cron enable 2>/dev/null || yellow "无法启用 cron 服务（OpenWrt 变种请检查 busybox 配置）。"
            /etc/init.d/cron start 2>/dev/null || yellow "无法启动 cron 服务。"
        else
            yellow "未检测到 cron 服务，请确保 cron 已安装并启用（OpenWrt 变种可能需 opkg install busybox）。"
            failed_pkgs="$failed_pkgs $cron_pkg"
        fi
    fi

    if [ -n "$failed_pkgs" ]; then
        yellow "以下依赖安装失败：$failed_pkgs"
        yellow "脚本将继续运行，但某些功能可能受限。请手动安装缺失的依赖（OpenWrt: opkg install <pkg>）。"
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
trap 'red "脚本因中断信号（Ctrl+C）终止，执行清理..."; cleanup; exit 1' INT TERM EXIT

# 检查网络通畅性（增强，添加备用服务器）
check_network() {
    log "检查网络通畅性 (ping 8.8.8.8 / 8.8.4.4)..."
    if ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1 || ping -c 1 -W 5 8.8.4.4 >/dev/null 2>&1; then
        green "网络连接正常 (ping 成功)"
        return 0
    else
        log "ping 失败, 尝试 curl google.com / cloudflare.com..."
        if curl -s --head --connect-timeout 10 --max-time 15 https://www.google.com >/dev/null 2>&1 || curl -s --head --connect-timeout 10 --max-time 15 https://1.1.1.1 >/dev/null 2>&1; then
            green "网络连接正常 (curl 成功)"
            return 0
        else
            red "无法连接到外网 (ping 和 curl 都失败)，请检查网络配置"
            return 1
        fi
    fi
}

# 配置网络（启用 IPv4 和 IPv6 转发以及 NAT，增强兼容 IPv6 禁用）
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

    if grep -q "^net.ipv4.ip_forward=" /etc/sysctl.conf 2>/dev/null; then
        sed -i 's/^net.ipv4.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
        green "IPv4 转发配置已更新到 /etc/sysctl.conf。"
    else
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        green "IPv4 转发配置已写入 /etc/sysctl.conf。"
    fi

    # 启用 IPv6 转发（检查是否支持）
    if sysctl net.ipv6.conf.all.forwarding >/dev/null 2>&1; then
        yellow "确保 IPv6 转发已启用..."
        if sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1; then
            green "IPv6 转发已通过 sysctl -w 启用。"
        else
            yellow "临时启用 IPv6 转发失败，系统可能禁用 IPv6。"
        fi

        if grep -q "^net.ipv6.conf.all.forwarding=" /etc/sysctl.conf 2>/dev/null; then
            sed -i 's/^net.ipv6.conf.all.forwarding=.*/net.ipv6.conf.all.forwarding=1/' /etc/sysctl.conf
            green "IPv6 转发配置已更新到 /etc/sysctl.conf。"
        else
            echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
            green "IPv6 转发配置已写入 /etc/sysctl.conf。"
        fi
    else
        yellow "系统不支持 IPv6 转发，跳过。"
    fi

    # 清理可能的禁用 IPv6 配置
    if grep -q "^net.ipv6.conf.all.disable_ipv6=" /etc/sysctl.conf 2>/dev/null; then
        sed -i '/^net.ipv6.conf.all.disable_ipv6=/d' /etc/sysctl.conf
        yellow "已移除 /etc/sysctl.conf 中的禁用 IPv6 配置。"
    fi
    sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1

    # 应用 sysctl 配置
    sysctl -p >/dev/null 2>&1 || yellow "sysctl -p 应用配置时出错，可能部分设置无效（OpenWrt 变种请检查 sysctl.conf）。"

    # 配置 IPv4 NAT 规则
    local NAT_SOURCE_CIDR="192.168.0.0/16"
    if ! iptables -t nat -C POSTROUTING -s "$NAT_SOURCE_CIDR" -j MASQUERADE 2>/dev/null; then
        yellow "添加 IPv4 NAT 规则 (MASQUERADE for $NAT_SOURCE_CIDR)..."
        if iptables -t nat -A POSTROUTING -s "$NAT_SOURCE_CIDR" -j MASQUERADE; then
            green "IPv4 NAT 规则添加成功"
            if [ "$SYSTEM_TYPE" = "openwrt" ]; then
                yellow "OpenWrt 系统：请手动将 IPv4 NAT 规则添加到 UCI 防火墙配置以实现持久化（uci set firewall...）。"
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

    # 配置 IPv6 NAT 规则（如果 ip6tables 可用）
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
    else
        yellow "ip6tables 未安装或不支持，跳过 IPv6 NAT。"
    fi

    return 0
}

# 加载环境变量
load_service_env() {
    local env_file="$1"
    if [ -f "$env_file" ]; then
        # 清空可能存在的旧变量，避免干扰
        unset PROXY_API_URL PROXY_MODE CRON_INTERVAL 2>/dev/null
        # 使用 source 加载文件，并检查语法
        if ! source "$env_file" 2>/dev/null; then
            red "加载环境变量文件 $env_file 失败，文件格式可能不正确。"
            return 1
        fi
        green "成功加载环境变量文件 $env_file。"
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
    local service_type

    # 根据 service_name 设置 service_type
    case "$service_name" in
        "Sing-box") service_type="singbox" ;;
        "Mihomo") service_type="mihomo" ;;
        *) red "无效的服务名称: $service_name"; return 1 ;;
    esac

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

    # 如果设置了 cron，立即应用
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
    printf "\n%b=== 选择要安装的 Sing-box 版本 ===%b\n" "$GREEN" "$NC"
    local i=1
    declare -A version_map
    for version_info in "${versions_array[@]}"; do
        IFS='|' read -r tag_name is_prerelease download_url asset_name <<< "$version_info"
        if [ "$is_prerelease" = "true" ]; then
            printf "  %d) %b%s (Pre-release)%b\n" "$i" "$YELLOW" "$tag_name" "$NC"
        else
            printf "  %d) %s (Stable)\n" "$i" "$tag_name"
        fi
        version_map[$i]="$download_url|$asset_name|$tag_name"
        ((i++))
    done
    printf "%b=====================================%b\n" "$GREEN" "$NC"
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
    # 使用代理下载函数
    if ! download_file_with_proxy "$DOWNLOAD_URL" "$TAR_PATH"; then
        red "下载 Sing-box 失败！"; cleanup; return 1
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

# 安装 Mihomo 稳定版（已更新下载逻辑）
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
        armv7) FILENAME="mihomo-linux-armv7l-${latest_version}.gz" ;;
        armv6) FILENAME="mihomo-linux-armv6-${latest_version}.gz" ;;
        riscv64) FILENAME="mihomo-linux-${local_arch}-${latest_version}.gz" ;;
        386) FILENAME="mihomo-linux-386-${latest_version}.gz" ;;
        *) red "不支持的架构: $local_arch"; return 1 ;;
    esac

    local DOWNLOAD_URL="https://github.com/MetaCubeX/mihomo/releases/download/${latest_version}/${FILENAME}"
    TEMP_DIR=$(mktemp -d)
    local GZ_PATH="$TEMP_DIR/$FILENAME"

    log "下载 Mihomo ${latest_version} (${local_arch})..."
    # 使用代理下载函数
    if ! download_file_with_proxy "$DOWNLOAD_URL" "$GZ_PATH"; then
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

# 获取 Mihomo Alpha 版本列表 (此函数已修复，避免未找到命令的错误)
get_mihomo_alpha_versions() {
    local arch="$1"
    local page=1
    local versions=()
    local i=0

    while true; do
        local releases_info
        releases_info=$(curl -s "https://api.github.com/repos/vernesong/mihomo/releases?page=$page&per_page=30") || {
            red "无法获取 Mihomo Alpha 版本信息。"; return 1
        }

        if [ "$(echo "$releases_info" | jq 'length')" -eq 0 ]; then
            break
        fi

        while IFS= read -r asset_info; do
            local asset_name download_url commit_id published_at version_display
            asset_name=$(echo "$asset_info" | jq -r '.name')
            if [[ "$asset_name" =~ mihomo-linux-${arch}(-compatible)?-alpha-smart-([0-9a-f]+)\.gz ]]; then
                commit_id="${BASH_REMATCH[2]}"
                download_url=$(echo "$asset_info" | jq -r '.browser_download_url')
                published_at=$(echo "$asset_info" | jq -r '.published_at' | cut -d'T' -f1)
                version_display="alpha-smart-$commit_id"
                versions[$i]="${version_display}|${published_at}|${download_url}|${asset_name}"
                ((i++))
            fi
        done < <(echo "$releases_info" | jq -c '.[] | .assets[]')

        ((page++))
    done

    if [ ${#versions[@]} -eq 0 ]; then
        red "未找到适用于架构 $arch 的 Mihomo Alpha (Smart Group) 版本。请尝试稳定版。"
        return 1
    fi

    echo "${versions[@]}"
    return 0
}

# 安装 Mihomo Alpha 版（已更新下载逻辑，Model 下载失败不中断安装）
install_mihomo_alpha_smart() {
    log "开始安装 Mihomo Alpha with Smart Group 版本..."
    check_network || return 1
    configure_network_forwarding_nat || return 1

    local local_arch; local_arch=$(get_arch) || return 1
    if [[ ! " amd64 arm64 " =~ " ${local_arch} " ]]; then
        red "暂无 $local_arch 架构的 Mihomo Alpha with Smart Group 版本支持。请使用稳定版。"
        return 1
    fi

    log "正在获取 Mihomo Alpha with Smart Group 可用版本..."
    local versions; versions=$(get_mihomo_alpha_versions "$local_arch") || return 1

    local version_array=($versions)
    clear
    printf "\n%b=== 选择 Mihomo Alpha (Smart Group) 版本 ===%b\n" "$GREEN" "$NC"
    local i=1
    declare -A version_map
    for version_info in "${version_array[@]}"; do
        IFS='|' read -r version_display published_at download_url asset_name <<< "$version_info"
        printf "  %d) 版本: %s (发布于: %s)\n" "$i" "$version_display" "$published_at"
        version_map[$i]="$download_url|$asset_name|$version_display"
        ((i++))
    done
    printf "%b=====================================%b\n" "$GREEN" "$NC"
    printf "请输入选项 (1-%d): " "${#version_array[@]}"
    read -r choice

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#version_array[@]}" ]; then
        red "无效选项 '$choice'，安装取消。"; return 1
    fi

    local selected_version=${version_map[$choice]}
    local DOWNLOAD_URL; DOWNLOAD_URL=$(echo "$selected_version" | cut -d'|' -f1)
    local FILENAME; FILENAME=$(echo "$selected_version" | cut -d'|' -f2)
    local VERSION_DISPLAY; VERSION_DISPLAY=$(echo "$selected_version" | cut -d'|' -f3)

    TEMP_DIR=$(mktemp -d)
    local GZ_PATH="$TEMP_DIR/$FILENAME"

    log "下载 Mihomo Alpha ($VERSION_DISPLAY)..."
    # 使用代理下载函数
    if ! download_file_with_proxy "$DOWNLOAD_URL" "$GZ_PATH"; then
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

    # 动态获取 LightGBM Model 版本列表
    local MODEL_BIN_PATH="$MH_BASE_DIR/model.bin"
    log "正在获取 LightGBM Model 版本列表..."
    local releases_info
    releases_info=$(curl -s "https://api.github.com/repos/vernesong/mihomo/releases/tag/LightGBM-Model") || {
        red "无法获取 LightGBM Model 版本信息，请检查网络或 GitHub API 限制。";
        # Model获取失败不是致命错误，继续安装核心
    }

    local model_assets=()
    local i=0
    if [ -n "$releases_info" ]; then
        while IFS= read -r asset_info; do
            local asset_name download_url
            asset_name=$(echo "$asset_info" | jq -r '.name')
            if [[ "$asset_name" =~ ^model(-[a-zA-Z0-9]+)?\.bin$ ]]; then
                download_url=$(echo "$asset_info" | jq -r '.browser_download_url')
                model_assets[$i]="$asset_name|$download_url"
                ((i++))
            fi
        done < <(echo "$releases_info" | jq -c '.assets[]')
    fi
    
    local model_choice=0
    if [ ${#model_assets[@]} -eq 0 ]; then
        yellow "未找到可用的 LightGBM Model 文件。请手动从 GitHub 下载。"
    else
        # 显示 Model 选择界面
        clear
        printf "\n%b=== 选择 LightGBM Model 版本 ===%b\n" "$GREEN" "$NC"
        local j=1
        declare -A model_map
        for asset_info in "${model_assets[@]}"; do
            IFS='|' read -r asset_name download_url <<< "$asset_info"
            case "$asset_name" in
                "model-large.bin") description="大模型，推荐用于高性能设备" ;;
                "model.bin") description="标准模型，适合通用设备" ;;
                *) description="其他模型" ;;
            esac
            printf "  %d) %s (%s)\n" "$j" "$asset_name" "$description"
            model_map[$j]="$download_url|$asset_name"
            ((j++))
        done
        printf "%b================================%b\n" "$GREEN" "$NC"
        printf "请输入选项 (1-%d): " "${#model_assets[@]}"
        read -r model_choice_input
        
        if ! [[ "$model_choice_input" =~ ^[0-9]+$ ]] || [ "$model_choice_input" -lt 1 ] || [ "$model_choice_input" -gt "${#model_assets[@]}" ]; then
            red "无效选项 '$model_choice_input'，将尝试使用默认 model.bin。"
            # 尝试查找默认 model.bin 的索引
            for i in "${!model_assets[@]}"; do 
                if [[ "${model_assets[$i]}" =~ model\.bin$ ]]; then model_choice=$((i+1)); break; fi 
            done
            if [ "$model_choice" -eq 0 ]; then
                yellow "未找到默认 model.bin，将跳过 Model 文件下载。"
            fi
        else
            model_choice="$model_choice_input"
        fi
    fi

    if [ "$model_choice" -gt 0 ]; then
        local selected_model=${model_map[$model_choice]}
        local selected_model_url=$(echo "$selected_model" | cut -d'|' -f1)
        local selected_model_name=$(echo "$selected_model" | cut -d'|' -f2)

        # 确保目标目录存在
        log "创建 Model 文件目标目录: $MH_BASE_DIR"
        mkdir -p "$MH_BASE_DIR" || { red "创建目录 $MH_BASE_DIR 失败"; cleanup; return 1; }
        chmod 755 "$MH_BASE_DIR" || { red "设置目录 $MH_BASE_DIR 权限失败"; cleanup; return 1; }

        # 下载 Model 文件（使用代理下载函数，下载失败不中断安装）
        log "正在下载 $selected_model_name 到 $MODEL_BIN_PATH..."
        local model_download_success=false
        
        if download_file_with_proxy "$selected_model_url" "$MODEL_BIN_PATH"; then
            model_download_success=true
        fi

        if [ "$model_download_success" = true ]; then
            # 验证文件（如果 md5sum 可用）
            if command -v md5sum >/dev/null 2>&1; then
                local local_md5=$(md5sum "$MODEL_BIN_PATH" | cut -d' ' -f1)
                log "$selected_model_name MD5: $local_md5 (验证通过如果非空)"
            fi
            green "$selected_model_name 下载成功并保存为 $MODEL_BIN_PATH。"
        else
            # 修复点：Model 下载失败不中断安装
            red "下载 $selected_model_name 失败。请手动从 $selected_model_url 下载并放置到 $MODEL_BIN_PATH。"
            yellow "警告：LightGBM Model 下载失败不中断安装，但 Smart Group 功能可能受限，安装将继续。"
        fi

        # 确保文件权限
        if [ -f "$MODEL_BIN_PATH" ]; then
            chmod 644 "$MODEL_BIN_PATH" || {
                # 修复点：Model 权限失败不中断安装
                red "设置文件 $MODEL_BIN_PATH 权限失败。"; 
                yellow "警告：Model 文件权限设置失败，请手动检查（文件路径：$MODEL_BIN_PATH）。"
            }
        fi
    fi
    
    # 清理 Mihomo 安装的临时文件
    cleanup
    
    green "Mihomo Alpha with Smart Group ($VERSION_DISPLAY) 安装成功！"

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

proxies:
  # 示例: 替换为您的实际节点配置
  - name: "Example-Proxy"
    type: ss
    server: 1.2.3.4
    port: 443
    cipher: auto
    password: "password"

proxy-groups:
  # 主选择组，用于用户在面板中选择线路
  - name: Proxy
    type: select
    proxies:
      - Example-Proxy
      - DIRECT
      - Block

  # 策略组 - 广告屏蔽
  - name: AdBlock
    type: select
    proxies:
      - Block
      - DIRECT

  # 策略组 - 微软服务
  - name: Microsoft
    type: select
    proxies:
      - DIRECT
      - Proxy

  # 策略组 - 苹果服务
  - name: Apple
    type: select
    proxies:
      - DIRECT
      - Proxy
      
  # 策略组 - 谷歌服务
  - name: Google
    type: select
    proxies:
      - Proxy
      - DIRECT

  # 策略组 - 国内直连
  - name: Domestic
    type: select
    proxies:
      - DIRECT
      - Proxy

  # 策略组 - 其它（兜底）
  - name: Others
    type: select
    proxies:
      - Proxy
      - DIRECT
      
rules:
  - GEOIP,CN,Domestic
  - DOMAIN-SUFFIX,cn,Domestic
  - DOMAIN-SUFFIX,baidu.com,Domestic
  - DOMAIN-SUFFIX,qq.com,Domestic
  - DOMAIN-SUFFIX,taobao.com,Domestic
  - DOMAIN-SUFFIX,alipay.com,Domestic
  
  - DOMAIN-SET,microsoft,Microsoft
  - DOMAIN-SET,apple,Apple
  - DOMAIN-SET,google,Google
  
  - MATCH,Others
EOF
    green "Mihomo 初始配置文件已生成：$MH_CONFIG_FILE"
    yellow "警告：默认配置中包含示例代理节点，请使用外部配置文件管理工具更新您的订阅！"
    return 0
}


# 获取配置管理工具的 URL
get_config_manager_url() {
    local service_type="$1"
    local env_file
    case "$service_type" in
        "singbox") env_file="$SB_ENV_FILE" ;;
        "mihomo") env_file="$MH_ENV_FILE" ;;
        *) return "" ;;
    esac
    
    if load_service_env "$env_file"; then
        echo "$PROXY_API_URL"
    else
        return ""
    fi
}


# 更新配置并重启服务
update_config_and_start_service() {
    local service_type="$1"
    local proxy_bin_path
    local config_file
    local env_file
    
    case "$service_type" in
        "singbox")
            proxy_bin_path="$SB_BIN_PATH"
            config_file="$SB_CONFIG_FILE"
            env_file="$SB_ENV_FILE"
            service_name_display="Sing-box"
            ;;
        "mihomo")
            proxy_bin_path="$MH_BIN_PATH"
            config_file="$MH_CONFIG_FILE"
            env_file="$MH_ENV_FILE"
            service_name_display="Mihomo"
            ;;
        *)
            red "无效的服务类型: $service_type"
            return 1
            ;;
    esac
    
    if [ ! -x "$proxy_bin_path" ]; then
        red "$service_name_display 核心程序 $proxy_bin_path 不存在或不可执行，请重新安装。"
        return 1
    fi
    
    log "正在加载 $service_name_display 环境变量..."
    if ! load_service_env "$env_file"; then
        red "无法加载环境变量，请重新设置配置。";
        return 1
    fi
    
    log "正在从 $PROXY_API_URL 更新配置..."
    local config_content
    local API_URL_SANITIZED=${PROXY_API_URL//&/%26} # 对URL中的&进行编码，防止bash解析错误
    
    if [ "$service_type" = "singbox" ]; then
        # 针对 sing-box 的 API 格式，使用 sing-box 订阅转换
        local config_url="${API_URL_SANITIZED}&target=singbox&urlencode=1"
        # 尝试使用 Clash 格式的 API 转换
        config_content=$(curl -sL -m 30 "${config_url}")
        if [ "$?" -ne 0 ] || [ -z "$config_content" ]; then
            red "从 API 更新 Sing-box 配置失败！URL: ${config_url}"
            return 1
        fi
        
        # 简单的JSON格式检查
        if ! echo "$config_content" | jq empty >/dev/null 2>&1; then
            red "获取到的配置内容不是有效的 JSON 格式，请检查订阅链接或 API。"
            return 1
        fi
    elif [ "$service_type" = "mihomo" ]; then
        # 针对 mihomo 的 API 格式，使用 mihomo/clash 订阅转换
        local config_url="${API_URL_SANITIZED}"
        config_content=$(curl -sL -m 30 "${config_url}")
        if [ "$?" -ne 0 ] || [ -z "$config_content" ]; then
            red "从 API 更新 Mihomo 配置失败！URL: ${config_url}"
            return 1
        fi
        
        # 简单的YAML格式检查
        # 检查是否包含最基本的字段
        if ! echo "$config_content" | grep -q "proxies:"; then
             red "获取到的配置内容似乎不是有效的 Clash/Mihomo YAML 格式，请检查订阅链接或 API。"
             return 1
        fi
    fi
    
    # 写入新的配置文件
    log "配置下载成功，正在写入 $config_file..."
    echo "$config_content" > "$config_file"
    
    # 启用模式切换
    log "正在根据环境变量 PROXY_MODE: $PROXY_MODE 设置代理模式..."
    if [ "$service_type" = "mihomo" ]; then
        # Mihomo/Clash 配置中修改 mode
        if grep -q "^mode:" "$config_file"; then
            sed -i "s/^mode:.*/mode: $PROXY_MODE/" "$config_file"
        else
            # 如果没有找到 mode 字段，尝试在 log-level 之后添加
            sed -i "/^log-level:/a mode: $PROXY_MODE" "$config_file"
        fi
    elif [ "$service_type" = "singbox" ]; then
        # Sing-box 配置中修改路由规则 (此处逻辑复杂，暂不实现自动修改，仅保留下载功能)
        yellow "Sing-box 模式切换（$PROXY_MODE）需要修改 JSON 路由配置，请手动编辑 $config_file"
    fi
    
    green "配置文件 $config_file 更新成功！"
    
    manage_service_internal "$service_type" "restart"
    
    green "$service_name_display 配置更新并重启服务完成。"
    return 0
}

# 设置服务文件（Systemd 或 OpenWrt Init.d）
setup_service_files() {
    local service_type="$1"
    local bin_path
    local config_file
    local base_dir
    local env_file
    local service_name
    
    case "$service_type" in
        "singbox")
            bin_path="$SB_BIN_PATH"
            config_file="$SB_CONFIG_FILE"
            base_dir="$SB_BASE_DIR"
            env_file="$SB_ENV_FILE"
            service_name="$SB_SERVICE_NAME"
            ;;
        "mihomo")
            bin_path="$MH_BIN_PATH"
            config_file="$MH_CONFIG_FILE"
            base_dir="$MH_BASE_DIR"
            env_file="$MH_ENV_FILE"
            service_name="$MH_SERVICE_NAME"
            ;;
        *)
            red "无效的服务类型: $service_type"
            return 1
            ;;
    esac

    if [ ! -x "$bin_path" ]; then
        red "核心程序 $bin_path 不存在或不可执行，请先安装。"
        return 1
    fi
    
    if [ ! -f "$config_file" ]; then
        red "配置文件 $config_file 不存在，请先生成默认配置。"
        return 1
    fi
    
    log "正在为 $service_name 设置服务文件..."
    
    if [ "$SYSTEM_TYPE" = "systemd" ]; then
        local service_path="/etc/systemd/system/${service_name}.service"
        log "创建 Systemd 服务文件: $service_path"
        
        # 创建 Systemd Unit 文件
        cat << EOF > "$service_path"
[Unit]
Description=$service_name Service
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$base_dir
EnvironmentFile=-$env_file
ExecStart=$bin_path run -D $config_file
Restart=always
RestartSec=3
LimitNPROC=500
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
        
        systemctl daemon-reload
        green "Systemd 服务文件创建成功。"
    
    elif [ "$SYSTEM_TYPE" = "openwrt" ]; then
        local initd_path="/etc/init.d/$service_name"
        log "创建 OpenWrt Init.d 服务文件: $initd_path"
        
        # 创建 OpenWrt Init.d 脚本
        cat << EOF > "$initd_path"
#!/bin/sh /etc/rc.common

USE_PROCD=1
START=95
STOP=01

# 加载环境变量
. $env_file 2>/dev/null

# 默认配置路径
CONFIG_FILE="$config_file"

# 检查 PROXY_MODE 并设置启动参数
TUN_ARGS=""
if [ "\$PROXY_MODE" = "global" ]; then
    TUN_ARGS="-g" # 假设 -g 代表全局模式，具体需根据脚本作者约定
fi

start_service() {
    procd_open_instance
    procd_set_param command "$bin_path"
    procd_append_param command run -D "\$CONFIG_FILE" 
    # procd_append_param command "\$TUN_ARGS" # 如果有额外的启动参数
    procd_set_param user root
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param pidfile /var/run/\$name.pid
    procd_set_param nice -5
    procd_set_param file "\$CONFIG_FILE"
    procd_set_param respawn 30 5 
    procd_close_instance
}

service_triggers() {
    procd_add_interface_trigger "interface.*" "ifup" "\$interface" /etc/init.d/\$name reload
}

EOF
        
        chmod +x "$initd_path"
        green "OpenWrt Init.d 服务文件创建成功。"
    else
        yellow "当前系统类型 ($SYSTEM_TYPE) 不支持自动创建服务文件，请手动设置 $service_name 的启动服务。"
        return 1
    fi
    
    return 0
}


# 设置服务 (安装配置、服务文件、启动自启)
setup_service() {
    local service_type="$1"
    local service_name_display
    local env_file
    
    case "$service_type" in
        "singbox")
            service_name_display="Sing-box"
            env_file="$SB_ENV_FILE"
            ;;
        "mihomo")
            service_name_display="Mihomo"
            env_file="$MH_ENV_FILE"
            ;;
        *)
            red "无效的服务类型: $service_type"; return 1 ;;
    esac
    
    log "正在设置 $service_name_display 服务..."
    
    # 1. 设置环境变量
    if ! load_service_env "$env_file"; then
        if ! setup_service_env "$env_file" "$service_name_display" "(rule/global/direct/gfwlist)"; then
            red "环境变量设置失败，服务部署取消。"; return 1
        fi
    fi
    
    # 2. 创建服务文件
    if ! setup_service_files "$service_type"; then
        red "服务文件创建失败，服务部署取消。"; return 1
    fi
    
    # 3. 启动服务
    manage_service_internal "$service_type" "restart"
    
    # 4. 设置自动更新 Cron Job
    if load_service_env "$env_file" && [ "$CRON_INTERVAL" -gt 0 ]; then
        setup_cron_job_internal "$service_type" "$CRON_INTERVAL"
    fi
    
    green "$service_name_display 服务部署成功！"
    return 0
}


# 服务管理内部函数
manage_service_internal() {
    local service_type="$1"
    local action="$2"
    local service_name
    
    case "$service_type" in
        "singbox") service_name="$SB_SERVICE_NAME" ;;
        "mihomo") service_name="$MH_SERVICE_NAME" ;;
        *) red "无效的服务类型: $service_type"; return 1 ;;
    esac
    
    log "正在对 $service_name 执行操作: $action..."
    
    if [ "$SYSTEM_TYPE" = "systemd" ]; then
        if command -v systemctl >/dev/null 2>&1; then
            systemctl "$action" "$service_name" || yellow "Systemd $action $service_name 失败或服务不存在。"
            return 0
        else
            red "Systemd 系统但未找到 systemctl 命令。"
            return 1
        fi
    elif [ "$SYSTEM_TYPE" = "openwrt" ]; then
        if [ -f "/etc/init.d/$service_name" ]; then
            /etc/init.d/"$service_name" "$action" || yellow "OpenWrt Init.d $action $service_name 失败。"
            return 0
        else
            red "OpenWrt 系统但未找到 /etc/init.d/$service_name 脚本。"
            return 1
        fi
    else
        red "当前系统类型 ($SYSTEM_TYPE) 不支持自动服务管理，请手动执行操作。"
        return 1
    fi
}


# 自动启动管理内部函数
manage_autostart_internal() {
    local service_type="$1"
    local action="$2"
    local service_name
    
    case "$service_type" in
        "singbox") service_name="$SB_SERVICE_NAME" ;;
        "mihomo") service_name="$MH_SERVICE_NAME" ;;
        *) red "无效的服务类型: $service_type"; return 1 ;;
    esac
    
    log "正在为 $service_name 设置开机自启: $action..."
    
    if [ "$SYSTEM_TYPE" = "systemd" ]; then
        if command -v systemctl >/dev/null 2>&1; then
            systemctl "$action" "$service_name" || yellow "Systemd $action $service_name 自动启动失败。"
            return 0
        fi
    elif [ "$SYSTEM_TYPE" = "openwrt" ]; then
        if [ -f "/etc/init.d/$service_name" ]; then
            /etc/init.d/"$service_name" "$action" || yellow "OpenWrt Init.d $action $service_name 自动启动失败。"
            return 0
        fi
    fi
    
    yellow "当前系统类型 ($SYSTEM_TYPE) 不支持自动设置开机自启，请手动配置。"
    return 1
}


# 设置 Cron Job 内部函数
setup_cron_job_internal() {
    local service_type="$1"
    local interval="$2" # 分钟
    local service_name_display
    
    case "$service_type" in
        "singbox") service_name_display="Sing-box" ;;
        "mihomo") service_name_display="Mihomo" ;;
        *) red "无效的服务类型: $service_type"; return 1 ;;
    esac

    if [ "$interval" -eq 0 ]; then
        disable_scheduled_update_internal "$service_type"
        return 0
    fi
    
    local cron_entry="*/$interval * * * * $SCRIPT_PATH --update $service_type"
    
    log "正在设置 $service_name_display 的 Cron 自动更新任务 (每 $interval 分钟)..."
    
    # 移除旧的 Cron 任务
    (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH --update $service_type"; echo "$cron_entry") | crontab -
    
    if [ "$?" -eq 0 ]; then
        green "$service_name_display 自动更新任务设置成功！"
    else
        red "设置 Cron 任务失败，请检查 cron 服务是否运行。"
        return 1
    fi
    
    return 0
}


# 禁用定时更新内部函数
disable_scheduled_update_internal() {
    local service_type="$1"
    local service_name_display
    
    case "$service_type" in
        "singbox") service_name_display="Sing-box" ;;
        "mihomo") service_name_display="Mihomo" ;;
        *) red "无效的服务类型: $service_type"; return 1 ;;
    esac
    
    log "正在禁用 $service_name_display 的 Cron 自动更新任务..."
    
    (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH --update $service_type") | crontab -
    
    if [ "$?" -eq 0 ]; then
        yellow "$service_name_display 自动更新任务已禁用。"
    else
        red "禁用 Cron 任务失败，请检查 cron 服务是否运行。"
        return 1
    fi
    
    return 0
}


# 移除所有文件和服务
remove_all_files_and_service() {
    local service_type="$1"
    local bin_path
    local config_file
    local base_dir
    local env_file
    local service_name
    
    case "$service_type" in
        "singbox")
            bin_path="$SB_BIN_PATH"
            config_file="$SB_CONFIG_FILE"
            base_dir="$SB_BASE_DIR"
            env_file="$SB_ENV_FILE"
            service_name="$SB_SERVICE_NAME"
            service_name_display="Sing-box"
            ;;
        "mihomo")
            bin_path="$MH_BIN_PATH"
            config_file="$MH_CONFIG_FILE"
            base_dir="$MH_BASE_DIR"
            env_file="$MH_ENV_FILE"
            service_name="$MH_SERVICE_NAME"
            service_name_display="Mihomo"
            ;;
        *)
            red "无效的服务类型: $service_type"; return 1 ;;
    esac
    
    log "正在卸载 $service_name_display..."
    
    # 停止并禁用服务
    manage_service_internal "$service_type" "stop" &>/dev/null
    manage_autostart_internal "$service_type" "disable" &>/dev/null
    disable_scheduled_update_internal "$service_type" &>/dev/null
    
    # 移除服务文件
    if [ "$SYSTEM_TYPE" = "systemd" ]; then
        log "移除 Systemd 服务文件..."
        rm -f "/etc/systemd/system/${service_name}.service"
        systemctl daemon-reload
    elif [ "$SYSTEM_TYPE" = "openwrt" ]; then
        log "移除 OpenWrt Init.d 服务文件..."
        rm -f "/etc/init.d/$service_name"
    fi
    
    # 移除核心程序和配置
    log "移除核心程序: $bin_path"
    rm -f "$bin_path"
    log "移除配置文件和数据目录: $base_dir"
    rm -rf "$base_dir"
    
    green "$service_name_display 卸载完成。请手动清理 iptables/ip6tables 规则。"
    return 0
}

# 清理系统配置
clean_up_system_configs() {
    log "正在清理系统配置..."
    
    # 移除转发配置
    yellow "正在移除 sysctl 中的 IPv4/IPv6 转发配置..."
    sed -i '/^net.ipv4.ip_forward=/d' /etc/sysctl.conf
    sed -i '/^net.ipv6.conf.all.forwarding=/d' /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1 || yellow "sysctl -p 失败。"
    
    # 移除 NAT 规则（只移除脚本添加的特定规则）
    local NAT_SOURCE_CIDR="192.168.0.0/16"
    local NAT_SOURCE_CIDR_V6="fc00::/7"
    
    yellow "尝试移除 IPv4 NAT 规则 (MASQUERADE for $NAT_SOURCE_CIDR)..."
    if iptables -t nat -C POSTROUTING -s "$NAT_SOURCE_CIDR" -j MASQUERADE 2>/dev/null; then
        iptables -t nat -D POSTROUTING -s "$NAT_SOURCE_CIDR" -j MASQUERADE
        green "IPv4 NAT 规则移除成功。"
        if command -v iptables-save >/dev/null 2>&1 && [ ! "$SYSTEM_TYPE" = "openwrt" ]; then
            iptables-save > /etc/iptables/rules.v4
        fi
    else
        yellow "未找到 IPv4 NAT 规则，跳过。"
    fi
    
    if command -v ip6tables >/dev/null 2>&1; then
        yellow "尝试移除 IPv6 NAT 规则 (MASQUERADE for $NAT_SOURCE_CIDR_V6)..."
        if ip6tables -t nat -C POSTROUTING -s "$NAT_SOURCE_CIDR_V6" -j MASQUERADE 2>/dev/null; then
            ip6tables -t nat -D POSTROUTING -s "$NAT_SOURCE_CIDR_V6" -j MASQUERADE
            green "IPv6 NAT 规则移除成功。"
            if command -v ip6tables-save >/dev/null 2>&1 && [ ! "$SYSTEM_TYPE" = "openwrt" ]; then
                ip6tables-save > /etc/iptables/rules.v6
            fi
        else
            yellow "未找到 IPv6 NAT 规则，跳过。"
        fi
    fi
    
    green "系统配置清理完成。注意：此操作不会卸载任何核心程序。"
    read -r -p "按 [Enter] 键继续..."
    return 0
}


# Sing-box 管理菜单
singbox_management_menu() {
    while true; do
        clear
        local config_status="未配置"
        if [ -f "$SB_CONFIG_FILE" ]; then config_status="已配置" ; fi
        local service_status="未知"
        if manage_service_internal "singbox" "status" >/dev/null 2>&1; then service_status="运行中" ; else service_status="未运行" ; fi
        local api_url; api_url=$(get_config_manager_url "singbox")

        printf "\n%b=== Sing-box 管理菜单 ===%b\n" "$GREEN" "$NC"
        printf "状态: %s | 配置: %s\n" "$service_status" "$config_status"
        printf "API URL: %s\n" "${api_url:-未设置}"
        printf "%b=========================%b\n" "$GREEN" "$NC"
        printf "  1) 安装/更新 Sing-box\n"
        printf "  2) 设置/修改配置和更新链接\n"
        printf "  3) 启动/重启服务\n"
        printf "  4) 停止服务\n"
        printf "  5) 从 API 更新配置并重启\n"
        printf "  6) 卸载 Sing-box\n"
        printf "  q) 返回主菜单\n"
        printf "%b=========================%b\n" "$GREEN" "$NC"
        read -r -p "请选择操作: " choice

        case "$choice" in
            1) install_deps; install_singbox ;;\
            2) install_deps; setup_service_env "$SB_ENV_FILE" "Sing-box" "(tun/mixed 模式)" ;;\
            3) manage_service_internal "singbox" "restart" ;;\
            4) manage_service_internal "singbox" "stop" ;;\
            5) install_deps; update_config_and_start_service "singbox" ;;\
            6) remove_all_files_and_service "singbox" ;;\
            q|Q) return 0 ;;\
            *) red "无效选项" ;;\
        esac
        read -r -p "按 [Enter] 键继续..."
    done
}


# Mihomo 管理菜单
mihomo_management_menu() {
    while true; do
        clear
        local config_status="未配置"
        if [ -f "$MH_CONFIG_FILE" ]; then config_status="已配置" ; fi
        local service_status="未知"
        if manage_service_internal "mihomo" "status" >/dev/null 2>&1; then service_status="运行中" ; else service_status="未运行" ; fi
        local api_url; api_url=$(get_config_manager_url "mihomo")
        
        printf "\n%b=== Mihomo 管理菜单 ===%b\n" "$GREEN" "$NC"
        printf "状态: %s | 配置: %s\n" "$service_status" "$config_status"
        printf "API URL: %s\n" "${api_url:-未设置}"
        printf "%b=========================%b\n" "$GREEN" "$NC"
        printf "  1) 安装/更新 Mihomo 稳定版\n"
        printf "  2) 安装/更新 Mihomo Alpha Smart\n"
        printf "  3) 设置/修改配置和更新链接\n"
        printf "  4) 启动/重启服务\n"
        printf "  5) 停止服务\n"
        printf "  6) 从 API 更新配置并重启\n"
        printf "  7) 卸载 Mihomo\n"
        printf "  q) 返回主菜单\n"
        printf "%b=========================%b\n" "$GREEN" "$NC"
        read -r -p "请选择操作: " choice

        case "$choice" in
            1) install_deps; install_mihomo ;;\
            2) install_deps; install_mihomo_alpha_smart ;;\
            3) install_deps; setup_service_env "$MH_ENV_FILE" "Mihomo" "(rule/global/direct/gfwlist)" ;;\
            4) manage_service_internal "mihomo" "restart" ;;\
            5) manage_service_internal "mihomo" "stop" ;;\
            6) install_deps; update_config_and_start_service "mihomo" ;;\
            7) remove_all_files_and_service "mihomo" ;;\
            q|Q) return 0 ;;\
            *) red "无效选项" ;;\
        esac
        read -r -p "按 [Enter] 键继续..."
    done
}


# 通用系统设置菜单
common_settings_menu() {
    while true; do
        clear
        printf "\n%b=== 通用系统设置 ===%b\n" "$GREEN" "$NC"
        printf "  1) 检查网络连通性\n"
        printf "  2) 检查并配置网络转发/NAT\n"
        printf "  3) 清理系统转发/NAT配置\n"
        printf "  q) 返回主菜单\n"
        printf "%b====================%b\n" "$GREEN" "$NC"
        read -r -p "请选择操作: " choice

        case "$choice" in
            1) check_network ;;\
            2) configure_network_forwarding_nat ;;\
            3) clean_up_system_configs ;;\
            q|Q) return 0 ;;\
            *) red "无效选项" ;;\
        esac
        read -r -p "按 [Enter] 键继续..."
    done
}

# 主菜单
initial_selection_menu() {
    while true; do
        clear
        printf "\n%b=== 代理管理器 (v1.0 - UI/UX Refined) ===%b\n" "$GREEN" "$NC"
        printf "设备: %s (%s)\n" "$DEVICE_NAME" "$SYSTEM_TYPE"
        printf "%b==========================================%b\n" "$GREEN" "$NC"
        printf "  1) 管理 Sing-box\n"
        printf "  2) 管理 Mihomo\n"
        printf "  3) 通用系统设置\n"
        printf "  q) 退出脚本\n"
        printf "%b==========================================%b\n" "$GREEN" "$NC"
        read -r -p "请选择您要管理的服务或操作: " choice
        case "$choice" in
            1) singbox_management_menu ;;\
            2) mihomo_management_menu ;;\
            3) common_settings_menu ;;\
            q|Q) green "正在退出脚本..."; exit 0 ;;\
            *) red "无效选项" ;;\
        esac
    done
}

# 非交互式模式处理 (用于 cron 等)
non_interactive_mode() {
    case "$1" in
        --update)
            check_root
            log "Cron 任务触发: 更新 $2"
            update_config_and_start_service "$2"
            ;;
        *)
            red "无效的非交互式模式参数: $1"
            ;;
    esac
}

# 脚本启动主逻辑
main() {
    if [ "$#" -gt 0 ]; then
        non_interactive_mode "$@"
    else
        check_root
        install_deps
        initial_selection_menu
    fi
}

# 执行主函数
main "$@"
