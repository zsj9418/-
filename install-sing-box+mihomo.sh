#!/bin/sh
set -eu  # 使用 POSIX 兼容的 set 选项

# 定义颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# 可配置路径和默认值
# --- Sing-box Specific Paths ---
SB_BASE_DIR="/etc/sing-box"
SB_BIN_PATH="/usr/local/bin/sing-box" # 直接指定可执行文件路径
SB_CONFIG_FILE="$SB_BASE_DIR/config.json"
SB_ENV_FILE="$SB_BASE_DIR/.singbox_env" # Sing-box 专属环境变量文件
SB_SERVICE_NAME="sing-box"

# --- Mihomo Specific Paths ---
MH_BASE_DIR="/etc/mihomo"
MH_BIN_PATH="/usr/local/bin/mihomo" # 直接指定可执行文件路径
MH_CONFIG_FILE="$MH_BASE_DIR/config.yaml"
MH_ENV_FILE="$MH_BASE_DIR/.mihomo_env" # Mihomo 专属环境变量文件
MH_SERVICE_NAME="mihomo"
# MH_DASHBOARD_DIR="$MH_BASE_DIR/dashboard" # Mihomo Dashboard 目录 - 已取消

# --- Common Paths ---
BIN_DIR="/usr/local/bin" # 存放可执行文件的通用目录
LOG_FILE="/var/log/proxy-manager.log" # 主脚本日志，更名为通用名称
SCRIPT_PATH="$(realpath "$0")"  # 使用 realpath 获取脚本的绝对路径，确保定时任务中正确引用
DEPS_INSTALLED_MARKER="/var/lib/proxy_manager_deps_installed" # 依赖安装标记文件


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
        x88_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l)  echo "armv7" ;; # 对于 armv7，通常 Mihomo 和 Sing-box 提供 armv7
        riscv64) echo "riscv64" ;;
        *)       red "不支持的架构: $(uname -m)"; return 1 ;;
    esac
}

# 判断系统类型
detect_system() {
    if [ -f /etc/openwrt_release ]; then
        echo "openwrt"
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

# 安装依赖（兼容 OpenWrt 和其他系统，首次运行检查）
install_deps() {
    if [ -f "$DEPS_INSTALLED_MARKER" ]; then
        log "已检测到依赖已安装标记文件，跳过依赖检查。"
        return 0
    fi

    log "首次运行，正在检查并安装依赖 (fzf, curl, tar, iptables, ipset, jq, psmisc, cron, unzip)..."
    local pkg_manager=""
    local install_cmd=""
    local update_cmd=""
    local pkgs="curl tar iptables ipset jq psmisc cron unzip fzf" # 包括 fzf 和 unzip
    local cron_pkg="cron" # 默认cron包名
    local system_type=$(detect_system)

    case "$system_type" in
        debian)
            pkg_manager="apt"
            update_cmd="apt update"
            install_cmd="apt install -y"
            ;;
        centos)
            pkg_manager="yum"
            update_cmd="" # yum usually doesn't need separate update before install
            install_cmd="yum install -y"
            cron_pkg="cronie" # CentOS/RHEL use cronie
            ;;
        alpine)
            pkg_manager="apk"
            update_cmd="apk update"
            install_cmd="apk add"
            cron_pkg="cronie" # Alpine might use cronie too, or just cron
            ;;
        openwrt)
            pkg_manager="opkg"
            update_cmd="opkg update"
            install_cmd="opkg install"
            pkgs="curl tar jq coreutils-killall unzip" # Adjust based on OpenWrt specifics, fzf may not be available or needs separate opkg-install
            cron_pkg="cron"
            ;;
        *)
            red "不支持的包管理器，请手动安装 curl, tar, iptables, ipset, jq, psmisc, cron, unzip, fzf"
            return 1
            ;;
    esac

    # Adjust cron package name if needed
    pkgs=$(echo "$pkgs" | sed "s/cron/$cron_pkg/")

    log "使用包管理器: $pkg_manager"
    if [ -n "$update_cmd" ]; then
        $update_cmd || { red "包列表更新失败"; return 1; }
    fi
    if ! $install_cmd $pkgs; then
         red "依赖安装失败: $pkgs"
         yellow "请尝试手动安装上述依赖包。"
         return 1
    fi

    # 检查 fzf 是否安装 (OpenWrt 上 fzf 可能需要单独处理)
    if ! command -v fzf >/dev/null 2>&1; then
        if [ "$system_type" = "openwrt" ]; then
            yellow "fzf 在 OpenWrt 上可能需要手动安装或从软件包源获取。"
            yellow "您可以尝试 'opkg install fzf' 或从官方源获取。"
        else
            red "未检测到 fzf。请手动安装 fzf，命令示例: $install_cmd fzf"
            return 1
        fi
    fi

    touch "$DEPS_INSTALLED_MARKER" # 创建标记文件
    green "依赖安装完成，并将跳过后续检查。"
    return 0
}

# 清理临时文件
cleanup() {
    if [ -n "${TEMP_DIR:-}" ] && [ -d "$TEMP_DIR" ]; then
        log "清理临时文件: $TEMP_DIR"
        rm -rf "$TEMP_DIR"
    fi
}
# 设置 trap 以确保清理
trap 'echo "脚本意外中断，执行清理..."; cleanup' INT TERM EXIT


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

# 配置网络（启用转发和 iptables NAT）
configure_network_forwarding_nat() {
    log "配置 IPv4 转发和 NAT..."
    # 启用 IP 转发
    if sysctl net.ipv4.ip_forward | grep -q "net.ipv4.ip_forward = 1"; then
        green "IPv4 转发已启用"
    else
        yellow "启用 IPv4 转发..."
        sysctl -w net.ipv4.ip_forward=1
        # 持久化
        if grep -q "^net.ipv4.ip_forward=" /etc/sysctl.conf; then
            sed -i 's/^net.ipv4.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
        else
            echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
        fi
        green "IPv4 转发已启用并持久化"
    fi

    # 配置 NAT (Masquerade) - 假设内网是 192.168.0.0/16, 可根据需要修改
    local NAT_SOURCE_CIDR="192.168.0.0/16" # 可以根据实际局域网IP段修改
    if ! iptables -t nat -C POSTROUTING -s "$NAT_SOURCE_CIDR" -j MASQUERADE 2>/dev/null; then
        yellow "添加 NAT 规则 (MASQUERADE for $NAT_SOURCE_CIDR)..."
        if iptables -t nat -A POSTROUTING -s "$NAT_SOURCE_CIDR" -j MASQUERADE; then
             green "NAT 规则添加成功"
             # 尝试持久化 iptables 规则，考虑 OpenWrt 等特殊情况
             if [ "$(detect_system)" = "openwrt" ]; then
                 yellow "OpenWrt 系统，请通过 UCI 或防火墙配置文件手动保存 iptables 规则。"
                 yellow "例如：'uci commit firewall' 或编辑 '/etc/config/firewall'"
             elif command -v iptables-save >/dev/null 2>&1; then
                 mkdir -p /etc/iptables
                 if iptables-save > /etc/iptables/rules.v4; then
                     green "iptables 规则已保存到 /etc/iptables/rules.v4"
                     yellow "请确保系统启动时会加载此规则 (例如通过 netfilter-persistent 或 rc.local)"
                 else
                     red "iptables-save 保存规则失败"
                 fi
             else
                 yellow "未找到 iptables-save 命令，NAT 规则可能不会持久化，请手动配置"
             fi
        else
            red "添加 NAT 规则失败"
            return 1
        fi
    else
        green "NAT 规则 (MASQUERADE for $NAT_SOURCE_CIDR) 已存在"
    fi
    return 0
}

# 加载环境变量 (针对特定服务)
load_service_env() {
    local env_file="$1"
    if [ -f "$env_file" ]; then
        # shellcheck source=/dev/null
        . "$env_file"
        # 确保变量在函数外部也可用，但避免全局冲突，这里通过返回状态来指示加载成功
        # 内部变量PROX_API_URL、PROX_MODE、CRON_INTERVAL 可以在调用此函数后直接使用
        return 0
    else
        yellow "未检测到环境变量配置文件 $env_file"
        return 1
    fi
}

# 设置环境变量 (针对特定服务)
setup_service_env() {
    local env_file="$1"
    local service_name="$2"
    local default_mode_options="$3" # 例如 "1-全局/2-GFWList/3-规则/4-直连"

    log "正在设置 ${service_name} 环境变量..."
    printf "%b请输入您的 %s 订阅链接或 API 地址：%b\n" "$GREEN" "$service_name" "$NC"
    read -r PROXY_API_URL_INPUT
    if [ -z "$PROXY_API_URL_INPUT" ]; then
        red "订阅链接或 API 地址不能为空！"
        return 1
    fi
    # 将用户输入的变量赋值给当前函数作用域内的同名变量，以便保存到文件
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
    local CRON_INTERVAL=""
    if ! echo "$CRON_INTERVAL_INPUT" | grep -Eq '^[0-9]+$'; then
        red "无效的间隔时间，将使用默认值 1440 分钟 (每天一次)。"
        CRON_INTERVAL=1440
    else
        CRON_INTERVAL="$CRON_INTERVAL_INPUT"
    fi

    # 保存环境变量到文件
    mkdir -p "$(dirname "$env_file")"
    cat << EOF > "$env_file"
# This file stores environment variables for ${service_name}.
# Do not modify manually unless you know what you are doing.
PROXY_API_URL="$PROXY_API_URL"
PROXY_MODE="$PROXY_MODE"
CRON_INTERVAL="$CRON_INTERVAL"
EOF
    green "${service_name} 环境变量设置完成并保存到 $env_file。"
    return 0
}

# --- Sing-box 相关功能 ---

# 获取 Sing-box 最新版本号 (只返回版本号，不打印额外日志)
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
    # install_deps 已在脚本启动时执行一次，这里不再重复调用。
    configure_network_forwarding_nat || return 1 # 确保网络转发和NAT已配置

    log "正在获取 Sing-box 最新版本号..."
    local latest_version
    latest_version=$(get_singbox_latest_version) || { red "获取 Sing-box 最新版本失败，请检查网络或稍后再试。"; return 1; }
    green "Sing-box 最新版本: $latest_version"

    # 从版本号中移除 'v' 前缀，用于文件名
    local version_without_v=$(echo "$latest_version" | sed 's/^v//')

    local local_arch=$(get_arch) || return 1
    local FILENAME=""
    case "$local_arch" in
        amd64) FILENAME="sing-box-${version_without_v}-linux-amd64.tar.gz" ;; # 使用 version_without_v
        arm64) FILENAME="sing-box-${version_without_v}-linux-arm64.tar.gz" ;; # 使用 version_without_v
        armv7) FILENAME="sing-box-${version_without_v}-linux-armv7.tar.gz" ;; # 使用 version_without_v
        riscv64) FILENAME="sing-box-${version_without_v}-linux-riscv64.tar.gz" ;; # 使用 version_without_v
        *) red "不支持的架构: $local_arch"; return 1 ;;
    esac

    local DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${latest_version}/${FILENAME}"
    TEMP_DIR=$(mktemp -d)
    local TAR_PATH="$TEMP_DIR/$FILENAME"

    log "下载 Sing-box $latest_version ($local_arch) 从 $DOWNLOAD_URL 到 $TAR_PATH..."
    if ! curl -L -o "$TAR_PATH" "$DOWNLOAD_URL"; then
        red "下载 Sing-box 失败！请检查 URL 或网络。尝试了: ${DOWNLOAD_URL}"
        rm -rf "$TEMP_DIR"
        return 1
    fi

    log "解压文件..."
    if ! tar -xzf "$TAR_PATH" -C "$TEMP_DIR"; then
        red "解压 Sing-box 失败！"
        rm -rf "$TEMP_DIR"
        return 1
    fi

    local SINGBOX_BIN_UNPACKED=$(find "$TEMP_DIR" -type f -name "sing-box" -perm /a+x | head -n 1)
    if [ -z "$SINGBOX_BIN_UNPACKED" ]; then
        red "未找到 Sing-box 可执行文件！"
        rm -rf "$TEMP_DIR"
        return 1
    fi

    log "安装 Sing-box 到 $SB_BIN_PATH..."
    mkdir -p "$SB_BASE_DIR"
    cp "$SINGBOX_BIN_UNPACKED" "$SB_BIN_PATH"
    chmod +x "$SB_BIN_PATH"

    # 清理
    rm -rf "$TEMP_DIR"
    green "Sing-box $latest_version 安装成功！"

    # 生成初始配置文件
    generate_initial_singbox_config

    # 设置 Systemd 服务
    setup_singbox_systemd_service

    green "Sing-box 部署完成。请更新配置并启动服务。"
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
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "network": "ipv4",
      "stack": "system",
      "auto_route": true,
      "auto_detect_interface": true,
      "inet4_address": "172.19.0.1/24",
      "mtu": 9000,
      "strict_route": true,
      "sniff": true,
      "endpoint_independent_nat": true,
      "link_fake_ip": true,
      "udp_timeout": 60,
      "detour": "proxy"
    },
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "::",
      "listen_port": 2080,
      "udp_timeout": 60,
      "detour": "proxy"
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    },
    {
      "type": "dns",
      "tag": "dns-out"
    },
    {
      "type": "selector",
      "tag": "proxy",
      "outbounds": [
        "direct"
      ]
    }
  ],
  "route": {
    "rules": [
      {
        "inbound": [
          "tun-in",
          "mixed-in"
        ],
        "outbound": "proxy"
      }
    ]
  },
  "dns": {
    "servers": [
      {
        "address": "8.8.8.8",
        "detour": "direct"
      },
      {
        "address": "1.1.1.1",
        "detour": "direct"
      }
    ]
  }
}
EOF
    if [ $? -eq 0 ]; then
        green "Sing-box 初始配置文件已生成：$SB_CONFIG_FILE"
        yellow "重要提示：请务必编辑 $SB_CONFIG_FILE 以配置您的代理节点和路由规则！"
    else
        red "Sing-box 初始配置文件生成失败！"
        return 1
    fi
    return 0
}

# 设置 Sing-box Systemd 服务
setup_singbox_systemd_service() {
    log "设置 Sing-box Systemd 服务..."
    local SERVICE_FILE="/etc/systemd/system/$SB_SERVICE_NAME.service"

    cat << EOF > "$SERVICE_FILE"
[Unit]
Description=Sing-box proxy service
After=network.target nss-lookup.target

[Service]
ExecStart=$SB_BIN_PATH run -c $SB_CONFIG_FILE
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SB_SERVICE_NAME"
    green "Sing-box Systemd 服务已创建并设置为开机自启。"
    return 0
}

# 卸载 Sing-box
uninstall_singbox() {
    yellow "警告：这将完全卸载 Sing-box 及其所有相关文件。"
    printf "您确定要继续吗？(y/N): "
    read -r confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        green "卸载已取消。"
        return 0
    fi

    log "正在停止并禁用 Sing-box 服务..."
    systemctl stop "$SB_SERVICE_NAME" || true
    systemctl disable "$SB_SERVICE_NAME" || true
    rm -f "/etc/systemd/system/$SB_SERVICE_NAME.service"
    systemctl daemon-reload

    log "正在删除 Sing-box 可执行文件和配置文件..."
    rm -f "$SB_BIN_PATH"
    rm -rf "$SB_BASE_DIR" # 删除整个配置目录包括环境变量文件

    green "Sing-box 已成功卸载。"
    return 0
}


# --- Mihomo 相关功能 ---

# 获取 Mihomo 最新版本号 (只返回版本号，不打印额外日志)
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
    # install_deps 已在脚本启动时执行一次，这里不再重复调用。
    configure_network_forwarding_nat || return 1 # 确保网络转发和NAT已配置

    log "正在获取 Mihomo 最新版本号..."
    local latest_version
    latest_version=$(get_mihomo_latest_version) || { red "获取 Mihomo 最新版本失败，请检查网络或稍后再试。"; return 1; }
    green "Mihomo 最新版本: $latest_version"

    local local_arch=$(get_arch) || return 1

    local FILENAME=""
    # Mihomo 的命名规则相对固定，例如 mihomo-linux-amd64-v1.19.8.gz
    # 但 armv7 有时会带有 '-v7'，需要特殊处理
    case "$local_arch" in
        amd64) FILENAME="mihomo-linux-${local_arch}-${latest_version}.gz" ;;
        arm64) FILENAME="mihomo-linux-${local_arch}-${latest_version}.gz" ;;
        armv7) FILENAME="mihomo-linux-${local_arch}-v7-${latest_version}.gz" ;; # Mihomo armv7 通常带 v7
        riscv64) FILENAME="mihomo-linux-${local_arch}-${latest_version}.gz" ;;
        *) red "不支持的架构: $local_arch"; return 1 ;;
    esac

    local DOWNLOAD_URL="https://github.com/MetaCubeX/mihomo/releases/download/${latest_version}/${FILENAME}"
    TEMP_DIR=$(mktemp -d)
    local GZ_PATH="$TEMP_DIR/$FILENAME"

    log "下载 Mihomo ${latest_version} (${local_arch}) 从 ${DOWNLOAD_URL} 到 ${GZ_PATH}..."
    if ! curl -L -o "$GZ_PATH" "$DOWNLOAD_URL"; then
        # 尝试查询一下可能的替代文件名，例如去掉版本号中的v
        local alt_version=$(echo "$latest_version" | sed 's/^v//')
        local alt_filename=""
        case "$local_arch" in
            amd64) alt_filename="mihomo-linux-${local_arch}-${alt_version}.gz" ;;
            arm64) alt_filename="mihomo-linux-${local_arch}-${alt_version}.gz" ;;
            armv7) alt_filename="mihomo-linux-${local_arch}-v7-${alt_version}.gz" ;;
            riscv64) alt_filename="mihomo-linux-${local_arch}-${alt_version}.gz" ;;
            *) alt_filename="" ;;
        esac

        if [ -n "$alt_filename" ] && [ "$alt_filename" != "$FILENAME" ]; then
             local ALT_DOWNLOAD_URL="https://github.com/MetaCubeX/mihomo/releases/download/${latest_version}/${alt_filename}"
             log "初次下载失败，尝试备用 URL: ${ALT_DOWNLOAD_URL}"
             if curl -L -o "$GZ_PATH" "$ALT_DOWNLOAD_URL"; then
                 green "成功使用备用 URL 下载 Mihomo。"
             else
                 red "下载 Mihomo 失败！请检查 URL 或网络。尝试了: ${DOWNLOAD_URL} 和 ${ALT_DOWNLOAD_URL}"
                 rm -rf "$TEMP_DIR"
                 return 1
             fi
        else
            red "下载 Mihomo 失败！请检查 URL 或网络。尝试了: ${DOWNLOAD_URL}"
            rm -rf "$TEMP_DIR"
            return 1
        fi
    fi

    log "解压文件..."
    if ! gzip -d "$GZ_PATH"; then
        red "解压 Mihomo 失败！"
        rm -rf "$TEMP_DIR"
        return 1
    fi
    local MIHOMO_BIN_UNPACKED="${GZ_PATH%.gz}"

    if [ ! -f "$MIHOMO_BIN_UNPACKED" ]; then
        red "未找到 Mihomo 可执行文件！"
        rm -rf "$TEMP_DIR"
        return 1
    fi

    log "安装 Mihomo 到 $MH_BIN_PATH..."
    mkdir -p "$MH_BASE_DIR"
    cp "$MIHOMO_BIN_UNPACKED" "$MH_BIN_PATH"
    chmod +x "$MH_BIN_PATH"

    # 清理
    rm -rf "$TEMP_DIR"
    green "Mihomo $latest_version 安装成功！"

    # 生成初始配置文件
    generate_initial_mihomo_config

    # 取消下载 Clash Dashboard 的功能
    # download_clash_dashboard # 这行已被移除

    # 设置 Systemd 服务
    setup_mihomo_systemd_service

    green "Mihomo 部署完成。请更新配置并启动服务。"
    return 0
}

# 生成初始 Mihomo 配置 (不变)
generate_initial_mihomo_config() {
    log "生成初始 Mihomo 配置文件到 $MH_CONFIG_FILE..."
    mkdir -p "$(dirname "$MH_CONFIG_FILE")"
    if [ -f "$MH_CONFIG_FILE" ]; then
        yellow "检测到现有 Mihomo 配置文件，将备份到 ${MH_CONFIG_FILE}.bak"
        cp "$MH_CONFIG_FILE" "${MH_CONFIG_FILE}.bak"
    fi

    cat << EOF > "$MH_CONFIG_FILE"
# Mihomo 基础配置文件模板
# 请将此文件替换为您的订阅内容或手动配置您的代理节点

port: 7890             # HTTP 代理端口
socks-port: 7891       # SOCKS5 代理端口
redir-port: 7892       # 透明代理端口 (tproxy/redirect)
tproxy-port: 7893      # TProxy 端口 (Linux only)

allow-lan: true        # 允许局域网连接
mode: rule             # 代理模式: rule(规则), global(全局), direct(直连)
log-level: info        # 日志级别: info, warning, error, debug, silent
external-controller: 0.0.0.0:9090 # 外部控制器，用于 Dashboard (即使不下载Dashboard，这个端口也可能用于API)
# external-ui: dashboard # Dashboard 目录名，与 download_clash_dashboard 中的保持一致 - 如果不使用Dashboard，可以注释或删除此行

# Mihomo TUN 模式配置（推荐用于全局代理）
tun:
  enable: true
  stack: system # 或者 gvisor
  auto-route: true
  auto-detect-interface: true
  strict-route: true
  inet4-address: 198.18.0.1/16 # TUN 虚拟网卡 IP
  mtu: 9000
  dns-hijack:
    - "any:53" # 劫持所有发往 53 端口的 DNS 请求

dns:
  enable: true
  listen: 0.0.0.0:53
  enhanced-mode: true
  nameserver:
    - 114.114.114.114
    - 8.8.8.8
  fallback:
    - https://dns.google/dns-query
    - https://1.1.1.1/dns-query
  fallback-filter:
    geoip: true
    geoip-code: CN
    ipcidr:
      - 240.0.0.0/4 # 保留地址，通常用于内部
  default-nameserver:
    - 114.114.114.114
    - 8.8.8.8

# proxies: # 您的代理节点配置将在这里，通常由订阅链接生成
#   - name: "Proxy1"
#     type: ss
#     server: your.server.com
#     port: 443
#     cipher: aes-256-gcm
#     password: "your_password"

# proxy-groups: # 您的代理组配置将在这里
#   - name: "Proxy"
#     type: select
#     proxies:
#       - direct
#       - Proxy1 # 替换为您的代理节点名称

# rules: # 您的规则配置将在这里
#   - DOMAIN-SUFFIX,google.com,Proxy
#   - IP-CIDR,0.0.0.0/8,DIRECT,no-resolve
#   - MATCH,Proxy # 默认匹配规则，所有不匹配的流量都走 Proxy 组
EOF
    if [ $? -eq 0 ]; then
        green "Mihomo 初始配置文件已生成：$MH_CONFIG_FILE"
        yellow "重要提示：请务必编辑 $MH_CONFIG_FILE 以配置您的代理节点和路由规则！"
        yellow "您可以使用订阅转换工具将您的订阅链接转换为 Clash (Mihomo) 配置。"
    else
        red "Mihomo 初始配置文件生成失败！"
        return 1
    fi
    return 0
}

# download_clash_dashboard() 函数已从脚本中移除。

# 设置 Mihomo Systemd 服务 (不变)
setup_mihomo_systemd_service() {
    log "设置 Mihomo Systemd 服务..."
    local SERVICE_FILE="/etc/systemd/system/$MH_SERVICE_NAME.service"

    cat << EOF > "$SERVICE_FILE"
[Unit]
Description=Mihomo proxy service
After=network.target nss-lookup.target

[Service]
ExecStart=$MH_BIN_PATH -d $MH_BASE_DIR # -d 指定配置目录
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$MH_SERVICE_NAME"
    green "Mihomo Systemd 服务已创建并设置为开机自启。"
    return 0
}

# 卸载 Mihomo (不变)
uninstall_mihomo() {
    yellow "警告：这将完全卸载 Mihomo 及其所有相关文件。"
    printf "您确定要继续吗？(y/N): "
    read -r confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        green "卸载已取消。"
        return 0
    fi

    log "正在停止并禁用 Mihomo 服务..."
    systemctl stop "$MH_SERVICE_NAME" || true
    systemctl disable "$MH_SERVICE_NAME" || true
    rm -f "/etc/systemd/system/$MH_SERVICE_NAME.service"
    systemctl daemon-reload

    log "正在删除 Mihomo 可执行文件和配置文件..."
    rm -f "$MH_BIN_PATH"
    # 由于不下载 Dashboard，所以这里不再包含 MH_DASHBOARD_DIR 的清理，直接删除整个MH_BASE_DIR
    rm -rf "$MH_BASE_DIR" # 删除整个配置目录包括环境变量文件

    green "Mihomo 已成功卸载。"
    return 0
}


# --- 通用功能 (服务管理，配置更新等) ---

# 更新配置并运行 - 内部调用，需要传入服务类型
# type: singbox 或 mihomo
update_config_and_run_internal() {
    local service_type="$1" # 'singbox' 或 'mihomo'
    local service_name=""
    local config_file=""
    local bin_path=""
    local env_file=""
    local convert_mode_prefix=""

    case "$service_type" in
        singbox)
            service_name="Sing-box"
            config_file="$SB_CONFIG_FILE"
            bin_path="$SB_BIN_PATH"
            env_file="$SB_ENV_FILE"
            convert_mode_prefix="singbox"
            ;;
        mihomo)
            service_name="Mihomo"
            config_file="$MH_CONFIG_FILE"
            bin_path="$MH_BIN_PATH"
            env_file="$MH_ENV_FILE"
            convert_mode_prefix="clash" # Mihomo 使用 Clash 订阅格式
            ;;
        *)
            red "内部错误: 无效的服务类型 '$service_type'。"
            return 1
            ;;
    esac

    if [ ! -f "$bin_path" ]; then
        red "${service_name} 未安装，请先安装。"
        return 1
    fi

    # 尝试加载服务专属环境变量
    local PROXY_API_URL=""
    local PROXY_MODE=""
    local CRON_INTERVAL=""

    if ! load_service_env "$env_file"; then
        yellow "${service_name} 环境变量未配置或缺失，请通过菜单选项 '配置 ${service_name} 订阅和模式' 进行设置。"
        return 1
    fi

    # 重新加载变量到当前函数作用域，因为 load_service_env 是在子 shell中执行 sourcing
    # shellcheck source=/dev/null
    . "$env_file"

    log "正在获取最新 ${service_name} 配置并运行..."

    # 使用服务专属的 PROXY_API_URL 和 PROXY_MODE
    # 再次检查，确保加载后变量非空
    if [ -z "${PROXY_API_URL:-}" ]; then
        red "警告：${service_name} 订阅链接未设置。请先通过菜单选项 '配置 ${service_name} 订阅和模式' 进行设置。"
        return 1
    fi
    # PROXY_MODE 默认值为 'rule'
    PROXY_MODE="${PROXY_MODE:-rule}"

    log "从 ${PROXY_API_URL} 获取 ${service_name} 配置... (当前模式: ${PROXY_MODE})"
    local convert_mode=""
    case "$PROXY_MODE" in
        global) convert_mode="${convert_mode_prefix}_global" ;;
        gfwlist) convert_mode="${convert_mode_prefix}_gfwlist" ;;
        rule) convert_mode="${convert_mode_prefix}_rule" ;;
        direct) convert_mode="${convert_mode_prefix}_direct" ;;
        *) convert_mode="${convert_mode_prefix}_rule" ;;
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
        red "获取或转换 ${service_name} 配置失败，请检查订阅链接或 API 服务。"
        return 1
    fi

    if [ "$service_type" = "singbox" ]; then
        if ! echo "$CONVERTED_CONFIG" | jq . >/dev/null 2>&1; then
            red "获取到的 Sing-box 配置不是有效的 JSON 格式。请手动检查或更新配置。"
            log "无效配置内容：$CONVERTED_CONFIG"
            return 1
        fi
    elif [ "$service_type" = "mihomo" ]; then
        if ! echo "$CONVERTED_CONFIG" | grep -q 'port:' && ! echo "$CONVERTED_CONFIG" | grep -q 'proxies:'; then
             red "获取到的 Mihomo 配置不是有效的 YAML 格式或不包含基本配置。请手动检查或更新配置。"
             log "无效配置内容：$CONVERTED_CONFIG"
             return 1
        fi
    fi


    yellow "正在备份旧的 ${service_name} 配置文件到 ${config_file}.bak..."
    cp "$config_file" "${config_file}.bak" || { red "备份 ${service_name} 配置失败"; return 1; }

    echo "$CONVERTED_CONFIG" > "$config_file"
    if [ $? -eq 0 ]; then
        green "${service_name} 配置已更新到 $config_file"
        log "尝试重启 ${service_name} 服务以应用新配置..."
        systemctl restart "${service_type}" || { red "重启 ${service_name} 服务失败，请检查配置或日志。"; return 1; }
        green "${service_name} 服务已重启。"
        green "配置更新并运行成功！"
    else
        red "写入 ${service_name} 配置失败！"
        return 1
    fi
    return 0
}

# 设置自动更新 - 内部调用，需要传入服务类型
setup_scheduled_update_internal() {
    local service_type="$1" # 'singbox' 或 'mihomo'
    local cron_target_script=""
    local service_name=""
    local env_file=""

    case "$service_type" in
        singbox)
            service_name="Sing-box"
            cron_target_script="$SB_BASE_DIR/update_singbox_config.sh"
            env_file="$SB_ENV_FILE"
            if [ ! -f "$SB_BIN_PATH" ]; then
                red "Sing-box 未安装，无法设置自动更新。"
                return 1
            fi
            ;;
        mihomo)
            service_name="Mihomo"
            cron_target_script="$MH_BASE_DIR/update_mihomo_config.sh"
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

    # 加载服务专属环境变量以获取 CRON_INTERVAL
    local PROXY_API_URL=""
    local PROXY_MODE=""
    local CRON_INTERVAL="" # 定义局部变量，避免全局污染

    if ! load_service_env "$env_file"; then
        yellow "${service_name} 环境变量未配置或缺失，请先通过菜单选项 '配置 ${service_name} 订阅和模式' 进行设置。"
        return 1
    fi
    # 重新加载变量到当前函数作用域
    # shellcheck source=/dev/null
    . "$env_file"


    # 使用服务专属的 CRON_INTERVAL
    local CRON_INTERVAL_LOCAL="${CRON_INTERVAL:-0}" # 默认0，不自动更新

    log "正在配置 ${service_name} 自动更新..."

    if [ "$CRON_INTERVAL_LOCAL" -eq 0 ]; then
        log "CRON_INTERVAL 设置为 0，禁用自动更新。"
        # 移除与该服务相关的 cron 任务
        (crontab -l 2>/dev/null | grep -v "$cron_target_script") | crontab -
        rm -f "$cron_target_script" # 删除旧的更新脚本
        green "${service_name} 自动更新已禁用。"
        return 0
    fi

    mkdir -p "$(dirname "$cron_target_script")"
    cat << EOF > "$cron_target_script"
#!/bin/sh
# This script is for automated proxy config updates for $service_name.
# DO NOT EDIT MANUALLY!

# 加载主脚本的函数和环境变量
# 必须使用完整的脚本路径来 source，否则函数定义会丢失
. "$(realpath "$SCRIPT_PATH")"

# 源服务专属的环境变量文件，确保 cron 任务能获取到订阅信息
. "$env_file"

# 调用主脚本的内部更新函数
# 注意：这里需要确保 update_config_and_run_internal 函数在脚本中是全局可见的
# 通过 `declare -f function_name` 可以将函数定义导出到子shell
# 但在 source 整个脚本的情况下，通常不需要
update_config_and_run_internal "$service_type" >> "$LOG_FILE" 2>&1

EOF
    chmod +x "$cron_target_script"

    # 添加或更新 cron 任务
    local CRON_SCHEDULE="*/$CRON_INTERVAL_LOCAL * * * *" # 每 CRON_INTERVAL 分钟执行一次
    local JOB_COMMENT="# Proxy config update for ${service_name}"
    local CRON_JOB="$CRON_SCHEDULE $cron_target_script $JOB_COMMENT" # 将注释放在行尾，有些cron实现更喜欢

    # 移除旧的相同任务（如果存在，防止重复）
    (crontab -l 2>/dev/null | grep -v -F "$JOB_COMMENT") | crontab -
    # 添加新的任务
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -

    if [ $? -eq 0 ]; then
        green "${service_name} 自动更新已设置为每 ${CRON_INTERVAL_LOCAL} 分钟执行一次。"
        green "日志文件: $LOG_FILE"
    else
        red "${service_name} 自动更新设置失败！"
        return 1
    fi
    return 0
}

# 管理服务（启动/停止/重启/查看状态） - 内部调用，需要传入服务类型
manage_service_internal() {
    local service_type="$1" # 'singbox' 或 'mihomo'
    local target_service=""
    local bin_path=""

    case "$service_type" in
        singbox)
            target_service="$SB_SERVICE_NAME"
            bin_path="$SB_BIN_PATH"
            ;;
        mihomo)
            target_service="$MH_SERVICE_NAME"
            bin_path="$MH_BIN_PATH"
            ;;
        *)
            red "内部错误: 无效的服务类型 '$service_type'。"
            return 1
            ;;
    esac

    if [ ! -f "$bin_path" ]; then
        red "${target_service} 未安装，无法管理服务。"
        return 1
    fi

    green "正在管理 ${target_service} 服务..."
    printf "  1) 启动\n"
    printf "  2) 停止\n"
    printf "  3) 重启\n"
    printf "  4) 查看状态\n"
    printf "  q) 返回上一级菜单\n"
    printf "\n%b请输入您的选择: %b" "$GREEN" "$NC"
    read -r action_choice

    local exit_code=0
    case "$action_choice" in
        1)
            log "正在启动 ${target_service} 服务..."
            # 将 'start' 改为 'restart'，确保加载最新配置
            systemctl restart "$target_service" && green "${target_service} 服务已启动。" || red "启动 ${target_service} 服务失败。"
            ;;
        2)
            log "正在停止 ${target_service} 服务..."
            systemctl stop "$target_service" && green "${target_service} 服务已停止。" || red "停止 ${target_service} 服务失败。"
            ;;
        3)
            log "正在重启 ${target_service} 服务..."
            systemctl restart "$target_service" && green "${target_service} 服务已重启。" || red "重启 ${target_service} 服务失败。"
            ;;
        4)
            log "正在查看 ${target_service} 服务状态..."
            systemctl status "$target_service" || yellow "查看 ${target_service} 服务状态失败或服务未运行。"
            ;;
        q|Q)
            green "返回上一级菜单。"
            return 0
            ;;
        *)
            red "无效选择，请重新输入。"
            exit_code=1
            ;;
    esac
    return "$exit_code"
}


# --- Sing-box 管理菜单 ---
singbox_management_menu() {
    while true; do
        printf "\n%b=== Sing-box 管理菜单 ===%b\n" "$GREEN" "$NC"
        printf "  1) 部署/更新 Sing-box 核心\n"
        printf "  2) 配置 Sing-box 订阅和模式 (首次配置或修改)\n"
        printf "  3) 更新 Sing-box 配置并立即运行\n"
        printf "  4) 设置/管理 Sing-box 自动更新任务\n"
        printf "  5) 管理 Sing-box 服务 (启动/停止/重启/状态)\n"
        printf "  6) 卸载 Sing-box\n"
        printf "  q) 返回主菜单\n"
        printf "%b=========================%b\n" "$GREEN" "$NC"
        printf "请输入选项 [1-6, q]: "
        read -r choice

        local exit_code=0
        case "$choice" in
            1) install_singbox || exit_code=$? ;;
            2) setup_service_env "$SB_ENV_FILE" "Sing-box" "1-全局/2-GFWList/3-规则/4-直连" || exit_code=$? ;;
            3) update_config_and_run_internal "singbox" || exit_code=$? ;;
            4) setup_scheduled_update_internal "singbox" || exit_code=$? ;;
            5) manage_service_internal "singbox" || exit_code=$? ;;
            6) uninstall_singbox || exit_code=$? ;;
            q|Q) green "返回主菜单。"; return 0 ;;
            *) red "无效选项 '$choice'，请重新输入。"; exit_code=1 ;;
        esac

        if [ "$exit_code" -ne 0 ]; then
             yellow "操作执行期间可能遇到问题 (退出码: $exit_code)，请检查日志: $LOG_FILE"
        fi
        printf "\n按 [Enter] 键返回 Sing-box 菜单..."
        read -r dummy_input
    done
}

# --- Mihomo 管理菜单 ---
mihomo_management_menu() {
    while true; do
        printf "\n%b=== Mihomo 管理菜单 ===%b\n" "$GREEN" "$NC"
        printf "  1) 部署/更新 Mihomo 核心\n"
        printf "  2) 配置 Mihomo 订阅和模式 (首次配置或修改)\n"
        printf "  3) 更新 Mihomo 配置并立即运行\n"
        printf "  4) 设置/管理 Mihomo 自动更新任务\n"
        printf "  5) 管理 Mihomo 服务 (启动/停止/重启/状态)\n"
        printf "  6) 卸载 Mihomo\n"
        printf "  q) 返回主菜单\n"
        printf "%b=========================%b\n" "$GREEN" "$NC"
        printf "请输入选项 [1-6, q]: "
        read -r choice

        local exit_code=0
        case "$choice" in
            1) install_mihomo || exit_code=$? ;;
            2) setup_service_env "$MH_ENV_FILE" "Mihomo" "1-全局/2-GFWList/3-规则/4-直连" || exit_code=$? ;;
            3) update_config_and_run_internal "mihomo" || exit_code=$? ;;
            4) setup_scheduled_update_internal "mihomo" || exit_code=$? ;;
            5) manage_service_internal "mihomo" || exit_code=$? ;;
            6) uninstall_mihomo || exit_code=$? ;;
            q|Q) green "返回主菜单。"; return 0 ;;
            *) red "无效选项 '$choice'，请重新输入。"; exit_code=1 ;;
        esac

        if [ "$exit_code" -ne 0 ]; then
             yellow "操作执行期间可能遇到问题 (退出码: $exit_code)，请检查日志: $LOG_FILE"
        fi
        printf "\n按 [Enter] 键返回 Mihomo 菜单..."
        read -r dummy_input
    done
}

# --- 通用设置菜单 ---
common_settings_menu() {
    while true; do
        printf "\n%b=== 通用系统设置菜单 ===%b\n" "$GREEN" "$NC"
        printf "  1) 检查网络连接\n"
        printf "  2) 重新配置网络转发和NAT (IPv4)\n"
        printf "  q) 返回主菜单\n"
        printf "%b=========================%b\n" "$GREEN" "$NC"
        printf "请输入选项 [1-2, q]: "
        read -r choice

        local exit_code=0
        case "$choice" in
            1) check_network || exit_code=$? ;;
            2) configure_network_forwarding_nat || exit_code=$? ;;
            q|Q) green "返回主菜单。"; return 0 ;;
            *) red "无效选项 '$choice'，请重新输入。"; exit_code=1 ;;
        esac

        if [ "$exit_code" -ne 0 ]; then
             yellow "操作执行期间可能遇到问题 (退出码: $exit_code)，请检查日志: $LOG_FILE"
        fi
        printf "\n按 [Enter] 键返回通用设置菜单..."
        read -r dummy_input
    done
}


# --- 脚本入口菜单 (Initial Selection Menu) ---
initial_selection_menu() {
    while true; do
        printf "\n%b=== 代理管理器 (v1.4) ===%b\n" "$GREEN" "$NC"
        printf "当前设备: %s\n" "$DEVICE_NAME"
        printf "日志文件: %s\n" "$LOG_FILE"
        printf "\n%b请选择您要管理的服务或通用操作:%b\n" "$YELLOW" "$NC"
        printf "  1) 管理 Sing-box 代理\n"
        printf "  2) 管理 Mihomo 代理\n"
        printf "  3) 通用系统设置 (网络、依赖等)\n"
        printf "  q) 退出脚本\n"
        printf "%b==================================%b\n" "$GREEN" "$NC"
        printf "请输入选项 [1-3, q]: "
        read -r choice

        local exit_code=0
        case "$choice" in
            1) singbox_management_menu ;;
            2) mihomo_management_menu ;;
            3) common_settings_menu ;;
            q|Q) green "正在退出脚本..."; exit 0 ;;
            *) red "无效选项 '$choice'，请重新输入。"; exit_code=1 ;;
        esac

        if [ "$exit_code" -ne 0 ] && [ "$choice" != "q" ] && [ "$choice" != "Q" ]; then
             yellow "操作执行期间可能遇到问题 (退出码: $exit_code)，请检查日志: $LOG_FILE"
        fi
        # 顶层菜单，除了退出和进入子菜单外，其他操作后暂停
        case "$choice" in
            1|2|3|q|Q) ;; # 进入子菜单或退出时不暂停
            *)
                printf "\n按 [Enter] 键返回主选择菜单..."
                read -r dummy_input
                ;;
        esac
    done
}

# --- 脚本入口 ---
# 确保日志文件可写
log_dir=$(dirname "$LOG_FILE")
if [ ! -d "$log_dir" ]; then
    mkdir -p "$log_dir" || { red "无法创建日志目录: $log_dir"; exit 1; }
fi
touch "$LOG_FILE" || { red "无法创建或写入日志文件: $LOG_FILE"; exit 1; }

check_root
install_deps # 只在脚本启动时执行一次依赖检查和安装

initial_selection_menu # 调用顶层菜单
