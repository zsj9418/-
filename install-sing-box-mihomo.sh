#!/bin/bash

set -u

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

SB_BASE_DIR="/etc/sing-box"
SB_BIN_PATH="/usr/local/bin/sing-box"
SB_CONFIG_FILE="$SB_BASE_DIR/config.json"
SB_ENV_FILE="$SB_BASE_DIR/.singbox_env"
SB_SERVICE_NAME="sing-box"

MH_BASE_DIR="/etc/mihomo"
MH_BIN_PATH="/usr/local/bin/mihomo"
MH_CONFIG_FILE="$MH_BASE_DIR/config.yaml"
MH_ENV_FILE="$MH_BASE_DIR/.mihomo_env"
MH_SERVICE_NAME="mihomo"

BIN_DIR="/usr/local/bin"
LOG_FILE="/var/log/proxy-manager.log"
LOG_MAX_SIZE=5242880
DEPS_INSTALLED_MARKER="/var/lib/proxy_manager_deps_installed"

PROXY_PREFIX="https://cdn.yyds9527.nyc.mn/"

DL_CONNECT_TIMEOUT=15
DL_MAX_TIME=300
DL_SPEED_LIMIT=1024
DL_SPEED_TIME=30
DL_RETRY=3
DL_RETRY_DELAY=5

CFG_CONNECT_TIMEOUT=15
CFG_MAX_TIME=120
CFG_SPEED_LIMIT=512
CFG_SPEED_TIME=60
CFG_RETRY=3
CFG_RETRY_DELAY=8

log() {
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    printf "%b[%s] %s%b\n" "$YELLOW" "$timestamp" "$1" "$NC"
    if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)" -gt "$LOG_MAX_SIZE" ]; then
        mv "$LOG_FILE" "${LOG_FILE}.bak"
    fi
    echo "[$timestamp] $1" >> "$LOG_FILE" 2>/dev/null || true
}

red()    { printf "%b%s%b\n" "$RED"    "$1" "$NC"; }
green()  { printf "%b%s%b\n" "$GREEN"  "$1" "$NC"; }
yellow() { printf "%b%s%b\n" "$YELLOW" "$1" "$NC"; }

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        red "此脚本必须以 root 用户运行"
        exit 1
    fi
}

check_bash_on_openwrt() {
    if [ -f /etc/openwrt_release ] || grep -q "OpenWrt" /etc/banner 2>/dev/null; then
        if ! command -v bash >/dev/null 2>&1; then
            echo "检测到 OpenWrt 系统，但未安装 bash。"
            echo "请先执行: opkg update && opkg install bash"
            exit 1
        fi
        if [ -z "${BASH_VERSION:-}" ]; then
            exec bash "$0" "$@"
        fi
    fi
}

get_script_path() {
    if command -v readlink >/dev/null 2>&1; then
        readlink -f "$0"
    else
        local script_name="$0"
        local script_path
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

detect_system() {
    if [ -f /etc/openwrt_release ] \
       || [ -f /etc/openwrt_version ]; then
        echo "openwrt"
        return
    fi
    if [ -d /etc/config ] && command -v uci >/dev/null 2>&1; then
        echo "openwrt"
        return
    fi
    if grep -qiE "openwrt|immortalwrt|lede|istoreos" /etc/banner 2>/dev/null; then
        echo "openwrt"
        return
    fi
    if [ -f /etc/os-release ] && grep -qiE "openwrt|immortalwrt|lede" /etc/os-release 2>/dev/null; then
        echo "openwrt"
        return
    fi

    local os_id=""
    if [ -f /etc/os-release ]; then
        os_id=$(. /etc/os-release && echo "${ID:-}" | tr '[:upper:]' '[:lower:]')
    fi
    case "$os_id" in
        ubuntu|debian|raspbian|kali|linuxmint) echo "debian" ;;
        centos|rhel|fedora|rocky|almalinux)    echo "centos" ;;
        alpine)                                 echo "alpine" ;;
        arch|manjaro)                           echo "arch"   ;;
        *)
            if command -v apt-get >/dev/null 2>&1; then echo "debian"
            elif command -v yum >/dev/null 2>&1;    then echo "centos"
            elif command -v apk >/dev/null 2>&1;    then echo "alpine"
            elif command -v pacman >/dev/null 2>&1; then echo "arch"
            else echo "unknown"
            fi
            ;;
    esac
}
SYSTEM_TYPE=$(detect_system)

detect_existing_binary() {
    local name="$1"
    local default_path="$2"
    local candidates="$default_path /usr/bin/$name /usr/sbin/$name /usr/local/sbin/$name /opt/$name/$name"

    for p in $candidates; do
        if [ -x "$p" ]; then
            echo "$p"
            return 0
        fi
    done

    local found
    found=$(command -v "$name" 2>/dev/null)
    if [ -n "$found" ] && [ -x "$found" ]; then
        echo "$found"
        return 0
    fi

    echo "$default_path"
    return 1
}

_detected_sb=$(detect_existing_binary "sing-box" "$SB_BIN_PATH")
if [ "$_detected_sb" != "$SB_BIN_PATH" ] && [ -x "$_detected_sb" ]; then
    SB_BIN_PATH="$_detected_sb"
fi

_detected_mh=$(detect_existing_binary "mihomo" "$MH_BIN_PATH")
if [ "$_detected_mh" != "$MH_BIN_PATH" ] && [ -x "$_detected_mh" ]; then
    MH_BIN_PATH="$_detected_mh"
fi

DL_TOOL=""
detect_download_tool() {
    if command -v curl >/dev/null 2>&1; then
        if curl --help >/dev/null 2>&1; then
            DL_TOOL="curl"
            return 0
        fi
    fi
    if command -v wget >/dev/null 2>&1; then
        if wget --help >/dev/null 2>&1; then
            DL_TOOL="wget"
            return 0
        fi
    fi
    if command -v uclient-fetch >/dev/null 2>&1; then
        DL_TOOL="uclient-fetch"
        return 0
    fi
    DL_TOOL=""
    return 1
}

http_fetch() {
    local url="$1"
    local out="$2"
    local connect_timeout="${3:-15}"
    local max_time="${4:-120}"
    local speed_limit="${5:-0}"
    local speed_time="${6:-0}"

    detect_download_tool || return 127

    case "$DL_TOOL" in
        curl)
            local curl_opts="-L --connect-timeout $connect_timeout --max-time $max_time --retry 0"
            if [ "$speed_limit" -gt 0 ] && [ "$speed_time" -gt 0 ]; then
                curl_opts="$curl_opts --speed-limit $speed_limit --speed-time $speed_time"
            fi
            if [ -n "$out" ]; then
                curl $curl_opts -o "$out" "$url"
            else
                curl $curl_opts -s "$url"
            fi
            return $?
            ;;
        wget)
            if [ -n "$out" ]; then
                wget --timeout="$max_time" --tries=1 -q -O "$out" "$url"
            else
                wget --timeout="$max_time" --tries=1 -q -O - "$url"
            fi
            return $?
            ;;
        uclient-fetch)
            if [ -n "$out" ]; then
                uclient-fetch --timeout="$max_time" -q -O "$out" "$url"
            else
                uclient-fetch --timeout="$max_time" -q -O - "$url"
            fi
            return $?
            ;;
    esac
    return 1
}

http_get() {
    local url="$1"
    local connect_timeout="${2:-15}"
    local max_time="${3:-30}"
    http_fetch "$url" "" "$connect_timeout" "$max_time" 0 0
}

download_file_with_proxy() {
    local url="$1"
    local output_path="$2"
    local mode="${3:-binary}"
    local filename="${url##*/}"

    local connect_timeout max_time speed_limit speed_time retry retry_delay
    if [ "$mode" = "config" ]; then
        connect_timeout=$CFG_CONNECT_TIMEOUT
        max_time=$CFG_MAX_TIME
        speed_limit=$CFG_SPEED_LIMIT
        speed_time=$CFG_SPEED_TIME
        retry=$CFG_RETRY
        retry_delay=$CFG_RETRY_DELAY
    else
        connect_timeout=$DL_CONNECT_TIMEOUT
        max_time=$DL_MAX_TIME
        speed_limit=$DL_SPEED_LIMIT
        speed_time=$DL_SPEED_TIME
        retry=$DL_RETRY
        retry_delay=$DL_RETRY_DELAY
    fi

    _do_download() {
        local target_url="$1"
        local out_path="$2"
        local attempt=0
        local exit_code=1

        while [ "$attempt" -lt "$retry" ]; do
            attempt=$((attempt + 1))
            log "下载尝试 $attempt/$retry: $filename (工具: ${DL_TOOL:-未探测}, 模式: $mode)"

            http_fetch "$target_url" "$out_path" "$connect_timeout" "$max_time" "$speed_limit" "$speed_time"
            exit_code=$?

            if [ "$exit_code" -eq 127 ]; then
                red "未找到可用下载工具（curl/wget/uclient-fetch 均不可用）"
                red "OpenWrt 请执行: opkg update && opkg install wget-ssl"
                red "或修复 curl: opkg install --force-reinstall libustream-mbedtls libmbedtls"
                return 1
            fi

            if [ "$exit_code" -eq 0 ] && [ -s "$out_path" ]; then
                return 0
            fi

            case "$exit_code" in
                6)  yellow "DNS 解析失败 (exit 6)" ;;
                7)  yellow "无法连接到服务器 (exit 7)" ;;
                28) yellow "下载超时 (exit 28)" ;;
                35) yellow "SSL 握手失败 (exit 35)" ;;
                56) yellow "数据传输中断 (exit 56)" ;;
                *)  yellow "下载失败，退出码: $exit_code" ;;
            esac

            if [ "$attempt" -lt "$retry" ]; then
                yellow "等待 ${retry_delay}s 后重试..."
                sleep "$retry_delay"
                rm -f "$out_path"
            fi
        done
        return 1
    }

    log "尝试直连下载 $filename..."
    if _do_download "$url" "$output_path"; then
        green "直连下载成功: $filename"
        return 0
    fi

    yellow "直连下载失败，尝试代理加速下载..."
    local proxied_url="${PROXY_PREFIX}${url}"
    log "代理下载地址: $proxied_url"
    rm -f "$output_path"

    if _do_download "$proxied_url" "$output_path"; then
        green "代理下载成功: $filename"
        return 0
    fi

    red "直连和代理均下载失败: $filename"
    return 1
}

load_service_env() {
    local env_file="$1"
    local verbose="${2:-1}"
    unset PROXY_API_URL PROXY_MODE CRON_INTERVAL 2>/dev/null || true

    if [ ! -f "$env_file" ]; then
        [ "$verbose" = "1" ] && yellow "未检测到环境变量配置文件: $env_file"
        return 1
    fi

    local key value line
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            '#'*|'') continue ;;
        esac
        key="${line%%=*}"
        value="${line#*=}"
        value="${value%\"}"
        value="${value#\"}"
        value="${value%\'}"
        value="${value#\'}"
        case "$key" in
            PROXY_API_URL|PROXY_MODE|CRON_INTERVAL)
                export "$key=$value"
                ;;
        esac
    done < "$env_file"

    if [ -z "${PROXY_API_URL:-}" ]; then
        [ "$verbose" = "1" ] && yellow "env 文件中未找到 PROXY_API_URL"
        return 1
    fi
    [ "$verbose" = "1" ] && green "成功加载环境变量文件: $env_file"
    return 0
}

write_env_file() {
    local env_file="$1"
    local api_url="$2"
    local mode="$3"
    local interval="$4"
    local service_display="${5:-Service}"

    mkdir -p "$(dirname "$env_file")"
    : > "$env_file"
    chmod 600 "$env_file"

    cat >> "$env_file" << EOF
# ${service_display} 环境变量配置文件
PROXY_API_URL="${api_url}"
PROXY_MODE="${mode}"
CRON_INTERVAL="${interval}"
EOF
    green "环境变量已保存到 $env_file"
}

update_env_field() {
    local env_file="$1"
    local key="$2"
    local value="$3"

    if [ ! -f "$env_file" ]; then
        yellow "env 文件不存在，无法更新字段 $key"
        return 1
    fi

    if grep -q "^${key}=" "$env_file"; then
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$env_file"
    else
        echo "${key}=\"${value}\"" >> "$env_file"
    fi
}

fix_openwrt_curl() {
    yellow "检测到 curl 库依赖问题，尝试修复..."
    if command -v opkg >/dev/null 2>&1; then
        opkg update >/dev/null 2>&1 || true
        opkg install --force-reinstall libmbedtls libustream-mbedtls ca-bundle ca-certificates >/dev/null 2>&1 || true
        if ! opkg install wget-ssl >/dev/null 2>&1; then
            opkg install wget >/dev/null 2>&1 || true
        fi
    fi
}

install_deps() {
    if [ -f "$DEPS_INSTALLED_MARKER" ]; then
        log "已检测到依赖标记文件，跳过依赖检查。"
        detect_download_tool >/dev/null 2>&1 || fix_openwrt_curl
        return 0
    fi

    log "首次运行，正在检查并安装依赖..."
    local pkg_manager install_cmd update_cmd pkgs cron_pkg failed_pkgs
    failed_pkgs=""
    cron_pkg="cron"

    case "$SYSTEM_TYPE" in
        debian)
            pkg_manager="apt"
            update_cmd="apt-get update"
            install_cmd="apt-get install -y"
            pkgs="curl wget tar iptables ipset jq psmisc cron unzip fzf"
            ;;
        centos)
            pkg_manager="yum"
            update_cmd=""
            install_cmd="yum install -y"
            cron_pkg="cronie"
            pkgs="curl wget tar iptables ipset jq psmisc cronie unzip fzf"
            ;;
        alpine)
            pkg_manager="apk"
            update_cmd="apk update"
            install_cmd="apk add"
            cron_pkg="cronie"
            pkgs="curl wget tar iptables ipset jq psmisc cronie unzip fzf bash"
            ;;
        arch)
            pkg_manager="pacman"
            update_cmd="pacman -Sy"
            install_cmd="pacman -S --noconfirm"
            cron_pkg="cronie"
            pkgs="curl wget tar iptables ipset jq psmisc cronie unzip fzf"
            ;;
        openwrt)
            pkg_manager="opkg"
            update_cmd="opkg update"
            install_cmd="opkg install"
            pkgs="wget-ssl tar iptables ipset jq unzip bash ca-bundle ca-certificates"
            cron_pkg="cron"
            ;;
        *)
            red "不支持的系统类型，请手动安装依赖"
            return 1
            ;;
    esac

    log "使用包管理器: $pkg_manager"
    if [ -n "$update_cmd" ]; then
        if ! $update_cmd; then
            yellow "包列表更新失败，将尝试直接安装..."
        fi
    fi

    for pkg in $pkgs; do
        if ! $install_cmd "$pkg" >/dev/null 2>&1; then
            yellow "安装 $pkg 失败（可能不在软件源中），跳过。"
            failed_pkgs="$failed_pkgs $pkg"
        else
            green "已安装: $pkg"
        fi
    done

    if [ "$SYSTEM_TYPE" = "openwrt" ]; then
        opkg install --force-reinstall libmbedtls libustream-mbedtls >/dev/null 2>&1 || true
        if command -v crond >/dev/null 2>&1 || [ -f /etc/init.d/cron ]; then
            /etc/init.d/cron enable 2>/dev/null || true
            /etc/init.d/cron start 2>/dev/null || yellow "无法启动 cron"
        else
            yellow "未检测到 cron，请执行: opkg install cron"
        fi
    fi

    if ! detect_download_tool >/dev/null 2>&1; then
        red "未检测到可用的下载工具，尝试修复..."
        fix_openwrt_curl
        if ! detect_download_tool >/dev/null 2>&1; then
            red "修复失败，请手动安装 wget-ssl 或修复 curl"
            return 1
        fi
    fi

    if [ -n "$failed_pkgs" ]; then
        yellow "以下依赖安装失败:$failed_pkgs"
    else
        green "所有依赖安装成功。"
    fi

    touch "$DEPS_INSTALLED_MARKER"
    return 0
}

TEMP_DIR=""
cleanup() {
    if [ -n "${TEMP_DIR:-}" ] && [ -d "${TEMP_DIR}" ]; then
        log "清理临时文件: $TEMP_DIR"
        rm -rf "$TEMP_DIR"
        TEMP_DIR=""
    fi
}

trap 'red "脚本被中断，执行清理..."; cleanup; exit 130' INT TERM
trap 'cleanup' EXIT

check_network() {
    log "检查网络连通性..."
    if ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1 || ping -c 1 -W 5 223.5.5.5 >/dev/null 2>&1; then
        green "网络连接正常 (ping 成功)"
        return 0
    fi
    log "ping 失败，尝试 http 检测..."
    if http_get "https://www.baidu.com" 10 15 >/dev/null 2>&1 || \
       http_get "https://www.google.com" 10 15 >/dev/null 2>&1; then
        green "网络连接正常 (http 成功)"
        return 0
    fi
    red "无法连接到外网，请检查网络配置"
    return 1
}

configure_network_forwarding_nat() {
    log "配置 IPv4/IPv6 转发及 NAT..."

    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || { red "启用 IPv4 转发失败"; return 1; }
    if grep -q "^net.ipv4.ip_forward=" /etc/sysctl.conf 2>/dev/null; then
        sed -i 's/^net.ipv4.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
    else
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    fi
    green "IPv4 转发已启用"

    if sysctl net.ipv6.conf.all.forwarding >/dev/null 2>&1; then
        sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || yellow "IPv6 转发启用失败"
        if grep -q "^net.ipv6.conf.all.forwarding=" /etc/sysctl.conf 2>/dev/null; then
            sed -i 's/^net.ipv6.conf.all.forwarding=.*/net.ipv6.conf.all.forwarding=1/' /etc/sysctl.conf
        else
            echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
        fi
        sed -i '/^net.ipv6.conf.all.disable_ipv6=/d' /etc/sysctl.conf
        sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 || true
        green "IPv6 转发已启用"
    else
        yellow "系统不支持 IPv6 转发，跳过"
    fi

    sysctl -p >/dev/null 2>&1 || yellow "sysctl -p 部分配置可能无效"

    local NAT_SOURCE_CIDR="192.168.0.0/16"
    if ! iptables -t nat -C POSTROUTING -s "$NAT_SOURCE_CIDR" -j MASQUERADE 2>/dev/null; then
        if iptables -t nat -A POSTROUTING -s "$NAT_SOURCE_CIDR" -j MASQUERADE; then
            green "IPv4 NAT 规则添加成功"
            if [ "$SYSTEM_TYPE" = "openwrt" ]; then
                yellow "OpenWrt: 请手动将 NAT 规则写入 UCI 防火墙以持久化"
            elif command -v iptables-save >/dev/null 2>&1; then
                mkdir -p /etc/iptables
                iptables-save > /etc/iptables/rules.v4 || yellow "iptables-save 失败"
            fi
        else
            red "IPv4 NAT 规则添加失败"
        fi
    else
        green "IPv4 NAT 规则已存在"
    fi

    local NAT_SOURCE_CIDR_V6="fc00::/7"
    if command -v ip6tables >/dev/null 2>&1; then
        yellow "注意: IPv6 NAT (NAT66) 会破坏 IPv6 端到端连通性"
        if ! ip6tables -t nat -C POSTROUTING -s "$NAT_SOURCE_CIDR_V6" -j MASQUERADE 2>/dev/null; then
            if ip6tables -t nat -A POSTROUTING -s "$NAT_SOURCE_CIDR_V6" -j MASQUERADE; then
                green "IPv6 NAT 规则添加成功"
                if [ "$SYSTEM_TYPE" != "openwrt" ] && command -v ip6tables-save >/dev/null 2>&1; then
                    mkdir -p /etc/iptables
                    ip6tables-save > /etc/iptables/rules.v6 || yellow "ip6tables-save 失败"
                fi
            else
                yellow "IPv6 NAT 规则添加失败"
            fi
        else
            green "IPv6 NAT 规则已存在"
        fi
    else
        yellow "ip6tables 未安装，跳过 IPv6 NAT"
    fi
    return 0
}

clean_up_system_configs() {
    log "正在清理系统配置..."
    sed -i '/^net.ipv4.ip_forward=/d' /etc/sysctl.conf
    sed -i '/^net.ipv6.conf.all.forwarding=/d' /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1 || true

    local NAT_SOURCE_CIDR="192.168.0.0/16"
    local NAT_SOURCE_CIDR_V6="fc00::/7"

    if iptables -t nat -C POSTROUTING -s "$NAT_SOURCE_CIDR" -j MASQUERADE 2>/dev/null; then
        iptables -t nat -D POSTROUTING -s "$NAT_SOURCE_CIDR" -j MASQUERADE
        green "IPv4 NAT 规则已移除"
        [ "$SYSTEM_TYPE" != "openwrt" ] && command -v iptables-save >/dev/null 2>&1 && \
            iptables-save > /etc/iptables/rules.v4
    else
        yellow "未找到 IPv4 NAT 规则"
    fi

    if command -v ip6tables >/dev/null 2>&1; then
        if ip6tables -t nat -C POSTROUTING -s "$NAT_SOURCE_CIDR_V6" -j MASQUERADE 2>/dev/null; then
            ip6tables -t nat -D POSTROUTING -s "$NAT_SOURCE_CIDR_V6" -j MASQUERADE
            green "IPv6 NAT 规则已移除"
            [ "$SYSTEM_TYPE" != "openwrt" ] && command -v ip6tables-save >/dev/null 2>&1 && \
                ip6tables-save > /etc/iptables/rules.v6
        else
            yellow "未找到 IPv6 NAT 规则"
        fi
    fi
    green "系统配置清理完成。"
}

setup_service_env() {
    local env_file="$1"
    local service_name="$2"

    log "正在设置 ${service_name} 环境变量..."

    local PROXY_API_URL=""
    while true; do
        printf "%b请输入 %s 订阅链接或 API 地址：%b\n" "$GREEN" "$service_name" "$NC"
        read -r PROXY_API_URL
        if [ -z "$PROXY_API_URL" ]; then
            red "订阅链接不能为空！"
            continue
        fi
        if ! echo "$PROXY_API_URL" | grep -qE '^https?://'; then
            red "URL 格式无效，必须以 http:// 或 https:// 开头"
            continue
        fi
        break
    done

    printf "%b请选择代理模式：%b\n  1) 全局 (global)\n  2) GFWList\n  3) 规则 (rule)\n  4) 直连 (direct)\n" "$GREEN" "$NC"
    read -r PROXY_MODE_INPUT
    local PROXY_MODE="rule"
    case "$PROXY_MODE_INPUT" in
        1) PROXY_MODE="global" ;;
        2) PROXY_MODE="gfwlist" ;;
        3) PROXY_MODE="rule" ;;
        4) PROXY_MODE="direct" ;;
        *) yellow "无效选择，使用默认 rule 模式" ;;
    esac

    printf "%b请输入自动更新间隔（分钟，0=不自动更新，推荐 1440）：%b\n" "$GREEN" "$NC"
    read -r CRON_INTERVAL_INPUT
    local CRON_INTERVAL=1440
    if echo "$CRON_INTERVAL_INPUT" | grep -Eq '^[0-9]+$'; then
        CRON_INTERVAL="$CRON_INTERVAL_INPUT"
    else
        yellow "无效输入，使用默认 1440 分钟"
    fi

    write_env_file "$env_file" "$PROXY_API_URL" "$PROXY_MODE" "$CRON_INTERVAL" "$service_name"

    local service_type=""
    case "$service_name" in
        "Sing-box") service_type="singbox" ;;
        "Mihomo")   service_type="mihomo"  ;;
    esac

    if [ -n "$service_type" ]; then
        if [ "$CRON_INTERVAL" -gt 0 ]; then
            setup_cron_job_internal "$service_type" "$CRON_INTERVAL"
        else
            disable_scheduled_update_internal "$service_type"
        fi
    fi
    return 0
}

get_config_manager_url() {
    local service_type="$1"
    local env_file
    case "$service_type" in
        "singbox") env_file="$SB_ENV_FILE" ;;
        "mihomo")  env_file="$MH_ENV_FILE" ;;
        *) echo ""; return 1 ;;
    esac
    if load_service_env "$env_file" 0 2>/dev/null; then
        echo "${PROXY_API_URL:-}"
    else
        echo ""
        return 1
    fi
}

get_singbox_versions() {
    local arch="$1"
    local releases_info
    releases_info=$(http_get "https://api.github.com/repos/SagerNet/sing-box/releases?per_page=10" 15 30) || {
        red "无法获取 Sing-box 版本信息"
        return 1
    }

    local found=0
    while IFS= read -r release_info; do
        local tag_name is_prerelease asset_name download_url
        tag_name=$(echo "$release_info" | jq -r '.tag_name')
        is_prerelease=$(echo "$release_info" | jq -r '.prerelease')
        asset_name="sing-box-$(echo "$tag_name" | sed 's/^v//')-linux-${arch}.tar.gz"
        download_url=$(echo "$release_info" | jq -r ".assets[] | select(.name == \"$asset_name\") | .browser_download_url")

        if [ -n "$download_url" ] && [ "$download_url" != "null" ]; then
            printf "%s|%s|%s|%s\n" "$tag_name" "$is_prerelease" "$download_url" "$asset_name"
            found=$((found + 1))
        fi
    done < <(echo "$releases_info" | jq -c '.[]')

    if [ "$found" -eq 0 ]; then
        red "未找到适用于架构 $arch 的 Sing-box 版本"
        return 1
    fi
    return 0
}

get_arch() {
    local machine_arch
    machine_arch=$(uname -m)
    case "$machine_arch" in
        x86_64)          echo "amd64"    ;;
        aarch64|armv8l)  echo "arm64"   ;;
        armv7l|armv7)    echo "armv7"   ;;
        armv6l|armv6)    echo "armv6"   ;;
        riscv64)         echo "riscv64" ;;
        i386|i686)       echo "386"     ;;
        mips)            echo "mips"    ;;
        mipsel)          echo "mipsle"  ;;
        mips64)          echo "mips64"  ;;
        mips64el)        echo "mips64le" ;;
        *) red "不支持的架构: $machine_arch"; return 1 ;;
    esac
}

install_singbox() {
    log "开始安装 Sing-box..."
    check_network || return 1
    configure_network_forwarding_nat || return 1

    local local_arch
    local_arch=$(get_arch) || return 1

    log "正在获取 Sing-box 可用版本列表..."
    local versions_raw
    versions_raw=$(get_singbox_versions "$local_arch") || return 1

    local versions_list=()
    while IFS= read -r line; do
        [ -n "$line" ] && versions_list+=("$line")
    done <<< "$versions_raw"

    if [ "${#versions_list[@]}" -eq 0 ]; then
        red "版本列表为空"
        return 1
    fi

    clear
    printf "\n%b=== 选择要安装的 Sing-box 版本 ===%b\n" "$GREEN" "$NC"
    local i=1
    for version_info in "${versions_list[@]}"; do
        local tag_name is_prerelease
        tag_name=$(echo "$version_info" | cut -d'|' -f1)
        is_prerelease=$(echo "$version_info" | cut -d'|' -f2)
        if [ "$is_prerelease" = "true" ]; then
            printf "  %d) %b%s (Pre-release)%b\n" "$i" "$YELLOW" "$tag_name" "$NC"
        else
            printf "  %d) %s (Stable)\n" "$i" "$tag_name"
        fi
        i=$((i + 1))
    done
    printf "%b=====================================%b\n" "$GREEN" "$NC"
    printf "请输入选项 (1-%d): " "${#versions_list[@]}"
    read -r choice

    if ! echo "$choice" | grep -qE '^[0-9]+$' || \
       [ "$choice" -lt 1 ] || [ "$choice" -gt "${#versions_list[@]}" ]; then
        red "无效选项，安装取消"
        return 1
    fi

    local selected="${versions_list[$((choice-1))]}"
    local DOWNLOAD_URL FILENAME VERSION_TAG
    DOWNLOAD_URL=$(echo "$selected" | cut -d'|' -f3)
    FILENAME=$(echo "$selected" | cut -d'|' -f4)
    VERSION_TAG=$(echo "$selected" | cut -d'|' -f1)

    TEMP_DIR=$(mktemp -d)
    local TAR_PATH="$TEMP_DIR/$FILENAME"

    log "下载 Sing-box $VERSION_TAG ($local_arch)..."
    if ! download_file_with_proxy "$DOWNLOAD_URL" "$TAR_PATH" "binary"; then
        red "下载失败"; cleanup; return 1
    fi

    log "解压文件..."
    if ! tar -xzf "$TAR_PATH" -C "$TEMP_DIR"; then
        red "解压失败"; cleanup; return 1
    fi

    local SINGBOX_BIN
    SINGBOX_BIN=$(find "$TEMP_DIR" -type f -name "sing-box" -perm /a+x | head -n 1)
    if [ -z "$SINGBOX_BIN" ]; then
        red "未找到 sing-box 可执行文件"; cleanup; return 1
    fi

    manage_service_internal "singbox" "stop" >/dev/null 2>&1 || true
    if [ "$SB_BIN_PATH" = "/usr/local/bin/sing-box" ] || [ ! -x "$SB_BIN_PATH" ]; then
        SB_BIN_PATH="/usr/local/bin/sing-box"
    fi
    mkdir -p "$(dirname "$SB_BIN_PATH")"
    if ! cp "$SINGBOX_BIN" "$SB_BIN_PATH"; then
        red "安装失败（文件复制错误）"; cleanup; return 1
    fi
    chmod +x "$SB_BIN_PATH"
    cleanup

    green "Sing-box $VERSION_TAG 安装成功！路径: $SB_BIN_PATH"
    [ ! -f "$SB_CONFIG_FILE" ] && generate_initial_singbox_config
    setup_service "singbox"
    manage_autostart_internal "singbox" "enable"
    green "Sing-box 部署完成，已设置开机自启。"
    return 0
}

generate_initial_singbox_config() {
    log "生成初始 Sing-box 配置: $SB_CONFIG_FILE"
    mkdir -p "$(dirname "$SB_CONFIG_FILE")"
    if [ -f "$SB_CONFIG_FILE" ]; then
        yellow "已备份现有配置到 ${SB_CONFIG_FILE}.bak"
        cp "$SB_CONFIG_FILE" "${SB_CONFIG_FILE}.bak"
    fi
    cat > "$SB_CONFIG_FILE" << 'EOF'
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
    green "Sing-box 初始配置已生成"
}

get_mihomo_latest_version() {
    local latest_version
    latest_version=$(http_get "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest" 15 30 | jq -r '.tag_name')
    if [ -z "$latest_version" ] || [ "$latest_version" = "null" ]; then
        return 1
    fi
    echo "$latest_version"
}

install_mihomo() {
    log "开始安装 Mihomo..."
    check_network || return 1
    configure_network_forwarding_nat || return 1

    local latest_version
    latest_version=$(get_mihomo_latest_version) || { red "获取 Mihomo 版本失败"; return 1; }
    green "Mihomo 最新版本: $latest_version"

    local local_arch
    local_arch=$(get_arch) || return 1

    local FILENAME=""
    case "$local_arch" in
        amd64)   FILENAME="mihomo-linux-amd64-${latest_version}.gz" ;;
        arm64)   FILENAME="mihomo-linux-arm64-${latest_version}.gz" ;;
        armv7)   FILENAME="mihomo-linux-armv7l-${latest_version}.gz" ;;
        armv6)   FILENAME="mihomo-linux-armv6-${latest_version}.gz" ;;
        riscv64) FILENAME="mihomo-linux-riscv64-${latest_version}.gz" ;;
        386)     FILENAME="mihomo-linux-386-${latest_version}.gz" ;;
        mips)    FILENAME="mihomo-linux-mips-softfloat-${latest_version}.gz" ;;
        mipsle)  FILENAME="mihomo-linux-mipsle-softfloat-${latest_version}.gz" ;;
        mips64)  FILENAME="mihomo-linux-mips64-${latest_version}.gz" ;;
        mips64le) FILENAME="mihomo-linux-mips64le-${latest_version}.gz" ;;
        *) red "不支持的架构: $local_arch"; return 1 ;;
    esac

    local DOWNLOAD_URL="https://github.com/MetaCubeX/mihomo/releases/download/${latest_version}/${FILENAME}"
    TEMP_DIR=$(mktemp -d)
    local GZ_PATH="$TEMP_DIR/$FILENAME"

    log "下载 Mihomo ${latest_version} (${local_arch})..."
    if ! download_file_with_proxy "$DOWNLOAD_URL" "$GZ_PATH" "binary"; then
        red "下载失败"; cleanup; return 1
    fi

    if ! gzip -d "$GZ_PATH"; then
        red "解压失败"; cleanup; return 1
    fi
    local MIHOMO_BIN="${GZ_PATH%.gz}"
    [ ! -f "$MIHOMO_BIN" ] && { red "未找到 Mihomo 可执行文件"; cleanup; return 1; }

    manage_service_internal "mihomo" "stop" >/dev/null 2>&1 || true
    if [ "$MH_BIN_PATH" = "/usr/local/bin/mihomo" ] || [ ! -x "$MH_BIN_PATH" ]; then
        MH_BIN_PATH="/usr/local/bin/mihomo"
    fi
    mkdir -p "$(dirname "$MH_BIN_PATH")"
    cp "$MIHOMO_BIN" "$MH_BIN_PATH"
    chmod +x "$MH_BIN_PATH"
    cleanup

    green "Mihomo $latest_version 安装成功！路径: $MH_BIN_PATH"
    [ ! -f "$MH_CONFIG_FILE" ] && generate_initial_mihomo_config
    setup_service "mihomo"
    manage_autostart_internal "mihomo" "enable"
    green "Mihomo 部署完成，已设置开机自启。"
    return 0
}

get_mihomo_alpha_versions() {
    local arch="$1"
    local page=1
    local found=0

    while true; do
        local releases_info
        releases_info=$(http_get "https://api.github.com/repos/vernesong/mihomo/releases?page=${page}&per_page=30" 15 30) || break

        local count
        count=$(echo "$releases_info" | jq 'length' 2>/dev/null)
        [ -z "$count" ] || [ "$count" -eq 0 ] && break

        while IFS= read -r asset_info; do
            local asset_name download_url commit_id published_at
            asset_name=$(echo "$asset_info" | jq -r '.name')
            if echo "$asset_name" | grep -qE "mihomo-linux-${arch}(-compatible)?-alpha-smart-[0-9a-f]+\.gz"; then
                commit_id=$(echo "$asset_name" | grep -oE '[0-9a-f]{7,}' | head -n 1)
                download_url=$(echo "$asset_info" | jq -r '.browser_download_url')
                published_at=$(echo "$asset_info" | jq -r '.published_at' | cut -d'T' -f1)
                printf "alpha-smart-%s|%s|%s|%s\n" "$commit_id" "$published_at" "$download_url" "$asset_name"
                found=$((found + 1))
            fi
        done < <(echo "$releases_info" | jq -c '.[] | .assets[]')

        page=$((page + 1))
        [ "$page" -gt 5 ] && break
    done

    if [ "$found" -eq 0 ]; then
        red "未找到架构 $arch 的 Mihomo Alpha 版本，请使用稳定版"
        return 1
    fi
    return 0
}

install_mihomo_alpha_smart() {
    log "开始安装 Mihomo Alpha with Smart Group..."
    check_network || return 1
    configure_network_forwarding_nat || return 1

    local local_arch
    local_arch=$(get_arch) || return 1
    if ! echo " amd64 arm64 " | grep -q " ${local_arch} "; then
        red "暂无 $local_arch 架构的 Mihomo Alpha 版本，请使用稳定版"
        return 1
    fi

    log "正在获取 Mihomo Alpha 版本列表..."
    local versions_raw
    versions_raw=$(get_mihomo_alpha_versions "$local_arch") || return 1

    local versions_list=()
    while IFS= read -r line; do
        [ -n "$line" ] && versions_list+=("$line")
    done <<< "$versions_raw"

    if [ "${#versions_list[@]}" -eq 0 ]; then
        red "版本列表为空"
        return 1
    fi

    clear
    printf "\n%b=== 选择 Mihomo Alpha (Smart Group) 版本 ===%b\n" "$GREEN" "$NC"
    local i=1
    for version_info in "${versions_list[@]}"; do
        local ver_display published_at
        ver_display=$(echo "$version_info" | cut -d'|' -f1)
        published_at=$(echo "$version_info" | cut -d'|' -f2)
        printf "  %d) %s (发布于: %s)\n" "$i" "$ver_display" "$published_at"
        i=$((i + 1))
    done
    printf "%b=====================================%b\n" "$GREEN" "$NC"
    printf "请输入选项 (1-%d): " "${#versions_list[@]}"
    read -r choice

    if ! echo "$choice" | grep -qE '^[0-9]+$' || \
       [ "$choice" -lt 1 ] || [ "$choice" -gt "${#versions_list[@]}" ]; then
        red "无效选项，安装取消"
        return 1
    fi

    local selected="${versions_list[$((choice-1))]}"
    local DOWNLOAD_URL FILENAME VERSION_DISPLAY
    VERSION_DISPLAY=$(echo "$selected" | cut -d'|' -f1)
    DOWNLOAD_URL=$(echo "$selected" | cut -d'|' -f3)
    FILENAME=$(echo "$selected" | cut -d'|' -f4)

    TEMP_DIR=$(mktemp -d)
    local GZ_PATH="$TEMP_DIR/$FILENAME"

    log "下载 Mihomo Alpha ($VERSION_DISPLAY)..."
    if ! download_file_with_proxy "$DOWNLOAD_URL" "$GZ_PATH" "binary"; then
        red "下载失败"; cleanup; return 1
    fi

    if ! gzip -d "$GZ_PATH"; then
        red "解压失败"; cleanup; return 1
    fi
    local MIHOMO_BIN="${GZ_PATH%.gz}"
    [ ! -f "$MIHOMO_BIN" ] && { red "未找到可执行文件"; cleanup; return 1; }

    manage_service_internal "mihomo" "stop" >/dev/null 2>&1 || true
    if [ "$MH_BIN_PATH" = "/usr/local/bin/mihomo" ] || [ ! -x "$MH_BIN_PATH" ]; then
        MH_BIN_PATH="/usr/local/bin/mihomo"
    fi
    mkdir -p "$(dirname "$MH_BIN_PATH")"
    cp "$MIHOMO_BIN" "$MH_BIN_PATH"
    chmod +x "$MH_BIN_PATH"

    local MODEL_BIN_PATH="$MH_BASE_DIR/model.bin"
    local FIXED_MODEL_URL="https://github.com/vernesong/mihomo/releases/download/LightGBM-Model/model.bin"
    mkdir -p "$MH_BASE_DIR"
    chmod 755 "$MH_BASE_DIR"

    log "下载 LightGBM Model..."
    if download_file_with_proxy "$FIXED_MODEL_URL" "$MODEL_BIN_PATH" "binary"; then
        chmod 644 "$MODEL_BIN_PATH"
        green "model.bin 下载成功"
    else
        yellow "model.bin 下载失败，Smart Group 功能可能受限"
    fi

    cleanup
    green "Mihomo Alpha ($VERSION_DISPLAY) 安装成功！路径: $MH_BIN_PATH"
    [ ! -f "$MH_CONFIG_FILE" ] && generate_initial_mihomo_config
    setup_service "mihomo"
    manage_autostart_internal "mihomo" "enable"
    green "Mihomo Alpha 部署完成，已设置开机自启。"
    return 0
}

generate_initial_mihomo_config() {
    log "生成初始 Mihomo 配置: $MH_CONFIG_FILE"
    mkdir -p "$(dirname "$MH_CONFIG_FILE")"
    if [ -f "$MH_CONFIG_FILE" ]; then
        yellow "已备份现有配置到 ${MH_CONFIG_FILE}.bak"
        cp "$MH_CONFIG_FILE" "${MH_CONFIG_FILE}.bak"
    fi
    cat > "$MH_CONFIG_FILE" << 'EOF'
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

proxies:
  - name: "Example-Proxy"
    type: ss
    server: 1.2.3.4
    port: 443
    cipher: auto
    password: "password"

proxy-groups:
  - name: Proxy
    type: select
    proxies: [Example-Proxy, DIRECT]
  - name: Others
    type: select
    proxies: [Proxy, DIRECT]

rules:
  - GEOIP,CN,DIRECT
  - MATCH,Others
EOF
    green "Mihomo 初始配置已生成"
}

update_config_and_start_service() {
    local service_type="$1"
    local proxy_bin_path config_file env_file service_name_display

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
            red "无效的服务类型: $service_type"; return 1 ;;
    esac

    [ ! -x "$proxy_bin_path" ] && { red "$service_name_display 未安装或不可执行"; return 1; }

    if ! load_service_env "$env_file"; then
        red "无法加载环境变量，请重新设置配置"; return 1
    fi

    log "正在从 API 更新配置..."

    local tmp_config
    tmp_config=$(mktemp)

    local exit_code=1
    local attempt=0

    while [ "$attempt" -lt "$CFG_RETRY" ]; do
        attempt=$((attempt + 1))
        log "配置下载尝试 $attempt/$CFG_RETRY..."

        http_fetch "$PROXY_API_URL" "$tmp_config" "$CFG_CONNECT_TIMEOUT" "$CFG_MAX_TIME" "$CFG_SPEED_LIMIT" "$CFG_SPEED_TIME"
        exit_code=$?

        if [ "$exit_code" -eq 0 ] && [ -s "$tmp_config" ]; then
            break
        fi

        yellow "配置下载失败 (exit $exit_code)"

        if [ "$attempt" -lt "$CFG_RETRY" ]; then
            yellow "等待 ${CFG_RETRY_DELAY}s 后重试..."
            sleep "$CFG_RETRY_DELAY"
            > "$tmp_config"
        fi
    done

    if [ "$exit_code" -ne 0 ] || [ ! -s "$tmp_config" ]; then
        red "配置下载失败（已重试 $CFG_RETRY 次）"
        rm -f "$tmp_config"
        return 1
    fi

    if [ "$service_type" = "singbox" ]; then
        if ! jq empty "$tmp_config" >/dev/null 2>&1; then
            red "下载的配置不是有效 JSON"
            rm -f "$tmp_config"
            return 1
        fi
    elif [ "$service_type" = "mihomo" ]; then
        if ! grep -q "proxies:" "$tmp_config"; then
            red "下载的配置不包含 proxies 字段"
            rm -f "$tmp_config"
            return 1
        fi
    fi

    mv "$tmp_config" "$config_file"
    green "配置文件更新成功: $config_file"

    if [ "$service_type" = "mihomo" ]; then
        local mode="${PROXY_MODE:-rule}"
        if grep -q "^mode:" "$config_file"; then
            sed -i "s/^mode:.*/mode: $mode/" "$config_file"
        else
            sed -i "1a mode: $mode" "$config_file"
        fi
        green "代理模式已设置为: $mode"
    elif [ "$service_type" = "singbox" ]; then
        yellow "Sing-box 模式切换需手动编辑 JSON 路由配置"
    fi

    manage_service_internal "$service_type" "restart"
    green "$service_name_display 配置更新并重启完成。"
    return 0
}

setup_service_files() {
    local service_type="$1"
    local bin_path config_file base_dir env_file service_name exec_start

    case "$service_type" in
        "singbox")
            bin_path="$SB_BIN_PATH"; config_file="$SB_CONFIG_FILE"
            base_dir="$SB_BASE_DIR"; env_file="$SB_ENV_FILE"
            service_name="$SB_SERVICE_NAME"
            exec_start="$SB_BIN_PATH run -c $SB_CONFIG_FILE"
            ;;
        "mihomo")
            bin_path="$MH_BIN_PATH"; config_file="$MH_CONFIG_FILE"
            base_dir="$MH_BASE_DIR"; env_file="$MH_ENV_FILE"
            service_name="$MH_SERVICE_NAME"
            exec_start="$MH_BIN_PATH -d $MH_BASE_DIR"
            ;;
        *)
            red "无效的服务类型: $service_type"; return 1 ;;
    esac

    [ ! -x "$bin_path" ] && { red "$bin_path 不存在或不可执行"; return 1; }
    [ ! -f "$config_file" ] && { red "配置文件 $config_file 不存在"; return 1; }

    if [ "$SYSTEM_TYPE" = "openwrt" ]; then
        local initd_path="/etc/init.d/$service_name"
        log "创建 OpenWrt Init.d 服务: $initd_path"
        cat > "$initd_path" << EOF
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=95
STOP=01

start_service() {
    procd_open_instance
    procd_set_param command $exec_start
    procd_set_param user root
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param pidfile /var/run/${service_name}.pid
    procd_set_param nice -5
    procd_set_param file "${config_file}"
    procd_set_param respawn 30 5 0
    procd_close_instance
}

service_triggers() {
    procd_add_reload_trigger "network"
}
EOF
        chmod +x "$initd_path"
        green "OpenWrt 服务文件创建成功: $initd_path"

    else
        local service_path="/etc/systemd/system/${service_name}.service"
        log "创建 Systemd 服务: $service_path"
        cat > "$service_path" << EOF
[Unit]
Description=${service_name} Proxy Service
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${base_dir}
EnvironmentFile=-${env_file}
ExecStart=${exec_start}
Restart=always
RestartSec=5
LimitNPROC=500
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        green "Systemd 服务文件创建成功: $service_path"
    fi
    return 0
}

setup_service() {
    local service_type="$1"
    local service_name_display env_file

    case "$service_type" in
        "singbox") service_name_display="Sing-box"; env_file="$SB_ENV_FILE" ;;
        "mihomo")  service_name_display="Mihomo";   env_file="$MH_ENV_FILE" ;;
        *) red "无效服务类型: $service_type"; return 1 ;;
    esac

    if ! load_service_env "$env_file" 0 2>/dev/null; then
        if ! setup_service_env "$env_file" "$service_name_display"; then
            red "环境变量设置失败"; return 1
        fi
    fi

    setup_service_files "$service_type" || { red "服务文件创建失败"; return 1; }
    manage_service_internal "$service_type" "restart"

    if load_service_env "$env_file" 0 2>/dev/null && [ "${CRON_INTERVAL:-0}" -gt 0 ]; then
        setup_cron_job_internal "$service_type" "${CRON_INTERVAL}"
    fi

    green "$service_name_display 服务部署成功！"
    return 0
}

remove_all_files_and_service() {
    local service_type="$1"
    local bin_path config_file base_dir service_name service_name_display

    case "$service_type" in
        "singbox")
            bin_path="$SB_BIN_PATH"; config_file="$SB_CONFIG_FILE"
            base_dir="$SB_BASE_DIR"; service_name="$SB_SERVICE_NAME"
            service_name_display="Sing-box"
            ;;
        "mihomo")
            bin_path="$MH_BIN_PATH"; config_file="$MH_CONFIG_FILE"
            base_dir="$MH_BASE_DIR"; service_name="$MH_SERVICE_NAME"
            service_name_display="Mihomo"
            ;;
        *) red "无效服务类型: $service_type"; return 1 ;;
    esac

    yellow "警告：将完全卸载 ${service_name_display} 及其所有文件"
    yellow "二进制路径: $bin_path"
    printf "确认继续？(y/N): "
    read -r confirm
    case "$confirm" in
        y|Y) ;;
        *) green "卸载已取消"; return 0 ;;
    esac

    manage_service_internal "$service_type" "stop"  >/dev/null 2>&1 || true
    manage_autostart_internal "$service_type" "disable" >/dev/null 2>&1 || true
    disable_scheduled_update_internal "$service_type" >/dev/null 2>&1 || true

    if [ "$SYSTEM_TYPE" = "openwrt" ]; then
        rm -f "/etc/init.d/$service_name"
    else
        rm -f "/etc/systemd/system/${service_name}.service"
        systemctl daemon-reload
    fi

    if [ -x "$bin_path" ] && [ "$bin_path" != "/usr/bin/$service_name" ] && [ "$bin_path" != "/usr/sbin/$service_name" ]; then
        rm -f "$bin_path"
    else
        yellow "二进制 $bin_path 由系统包管理器管理，不予删除"
    fi
    rm -rf "$base_dir"
    green "$service_name_display 卸载完成。"
    return 0
}

validate_config_internal() {
    local service_type="$1"
    local config_file_override="${2:-}"
    local service_name bin_path config_path

    case "$service_type" in
        singbox) service_name="Sing-box"; bin_path="$SB_BIN_PATH"; config_path="$SB_CONFIG_FILE" ;;
        mihomo)  service_name="Mihomo";   bin_path="$MH_BIN_PATH"; config_path="$MH_BASE_DIR"   ;;
        *) red "无效服务类型: $service_type"; return 1 ;;
    esac

    [ ! -f "$bin_path" ] && { red "${service_name} 未安装"; return 1; }

    local validation_output exit_code
    local temp_dir_created=0

    if [ "$service_type" = "singbox" ]; then
        local file_to_check="${config_file_override:-$config_path}"
        [ ! -f "$file_to_check" ] && { red "配置文件不存在: $file_to_check"; return 1; }
        validation_output=$("$bin_path" check -c "$file_to_check" 2>&1)
        exit_code=$?
    else
        local dir_to_check
        if [ -n "$config_file_override" ]; then
            dir_to_check=$(mktemp -d)
            temp_dir_created=1
            cp "$config_file_override" "$dir_to_check/config.yaml"
            [ -f "$MH_BASE_DIR/model.bin" ] && cp "$MH_BASE_DIR/model.bin" "$dir_to_check/"
        else
            dir_to_check="$config_path"
        fi
        [ ! -f "$dir_to_check/config.yaml" ] && {
            red "配置文件不存在: $dir_to_check/config.yaml"
            [ "$temp_dir_created" -eq 1 ] && rm -rf "$dir_to_check"
            return 1
        }
        validation_output=$("$bin_path" -d "$dir_to_check" -t 2>&1)
        exit_code=$?
        [ "$temp_dir_created" -eq 1 ] && rm -rf "$dir_to_check"
    fi

    if [ "$exit_code" -eq 0 ]; then
        [ -z "$config_file_override" ] && green "✅ ${service_name} 配置文件验证通过！"
        return 0
    else
        red "❌ ${service_name} 配置文件验证失败！"
        if [ -z "$config_file_override" ]; then
            yellow "--- 错误详情 ---"
            printf "%s\n" "$validation_output"
            yellow "----------------"
        fi
        return 1
    fi
}

manage_service_internal() {
    local service_type="$1"
    local action="$2"
    local service_name bin_path

    case "$service_type" in
        singbox) service_name="$SB_SERVICE_NAME"; bin_path="$SB_BIN_PATH" ;;
        mihomo)  service_name="$MH_SERVICE_NAME"; bin_path="$MH_BIN_PATH" ;;
        *) red "无效服务类型: $service_type"; return 1 ;;
    esac

    [ ! -f "$bin_path" ] && { yellow "${service_name} 未安装，跳过 $action"; return 1; }

    log "对 ${service_name} 执行: $action"
    if [ "$SYSTEM_TYPE" = "openwrt" ]; then
        local init_script="/etc/init.d/$service_name"
        if [ -f "$init_script" ]; then
            "$init_script" "$action"
        else
            yellow "服务脚本不存在: $init_script"
            return 1
        fi
    else
        systemctl "$action" "$service_name"
    fi
    return $?
}

manage_autostart_internal() {
    local service_type="$1"
    local action="${2:-}"
    local service_name

    case "$service_type" in
        singbox) service_name="$SB_SERVICE_NAME" ;;
        mihomo)  service_name="$MH_SERVICE_NAME"  ;;
        *) red "无效服务类型: $service_type"; return 1 ;;
    esac

    if [ -z "$action" ]; then
        clear
        printf "\n%b=== 管理 %s 自启动 ===%b\n" "$GREEN" "$service_name" "$NC"
        printf "  1) 启用开机自启\n  2) 禁用开机自启\n  q) 返回\n"
        read -r -p "请输入选项: " choice
        case "$choice" in
            1) manage_autostart_internal "$service_type" "enable" ;;
            2) manage_autostart_internal "$service_type" "disable" ;;
            q|Q) return 0 ;;
            *) red "无效选项" ;;
        esac
        return 0
    fi

    if [ "$SYSTEM_TYPE" = "openwrt" ]; then
        local init_script="/etc/init.d/$service_name"
        [ ! -f "$init_script" ] && { red "服务未安装"; return 1; }
        case "$action" in
            enable)  "$init_script" enable  >/dev/null 2>&1; green "${service_name} 已启用自启" ;;
            disable) "$init_script" disable >/dev/null 2>&1; yellow "${service_name} 已禁用自启" ;;
            status)
                if [ -L "/etc/rc.d/S95${service_name}" ]; then green "已启用"
                else red "已禁用"; fi ;;
        esac
    else
        case "$action" in
            enable)  systemctl enable  "$service_name" >/dev/null 2>&1; green "${service_name} 已启用自启" ;;
            disable) systemctl disable "$service_name" >/dev/null 2>&1; yellow "${service_name} 已禁用自启" ;;
            status)
                if systemctl is-enabled "$service_name" >/dev/null 2>&1; then green "已启用"
                else red "已禁用"; fi ;;
        esac
    fi
    return 0
}

view_log_internal() {
    local service_type="$1"
    local service_name

    case "$service_type" in
        singbox) service_name="$SB_SERVICE_NAME" ;;
        mihomo)  service_name="$MH_SERVICE_NAME"  ;;
        *) red "无效服务类型: $service_type"; return 1 ;;
    esac

    clear
    yellow "--- ${service_name} 服务日志 (最近50行) ---"
    if [ "$SYSTEM_TYPE" = "openwrt" ]; then
        logread -e "$service_name" 2>/dev/null | tail -n 50 || yellow "无法获取日志"
    else
        journalctl -u "$service_name" -n 50 --no-pager 2>/dev/null || yellow "无法获取日志"
    fi
    yellow "--- 脚本日志 ($LOG_FILE) (最近50行) ---"
    tail -n 50 "$LOG_FILE" 2>/dev/null || yellow "暂无脚本日志"
    yellow "----------------------------------------"
    return 0
}

setup_cron_job_internal() {
    local service_type="$1"
    local interval="$2"
    local service_name cron_entry

    case "$service_type" in
        singbox) service_name="Sing-box" ;;
        mihomo)  service_name="Mihomo"   ;;
        *) red "无效服务类型: $service_type"; return 1 ;;
    esac

    local cron_job_id="${service_type}_proxy_update"

    if [ "$interval" -ge 1440 ]; then
        local days=$((interval / 1440))
        cron_entry="0 2 */${days} * * bash $SCRIPT_PATH --update $service_type >> $LOG_FILE 2>&1"
    elif [ "$interval" -ge 60 ]; then
        local hours=$((interval / 60))
        cron_entry="0 */${hours} * * * bash $SCRIPT_PATH --update $service_type >> $LOG_FILE 2>&1"
    else
        cron_entry="*/${interval} * * * * bash $SCRIPT_PATH --update $service_type >> $LOG_FILE 2>&1"
    fi

    (crontab -l 2>/dev/null | grep -v "$cron_job_id"; \
     echo "# $cron_job_id"; \
     echo "$cron_entry") | crontab -

    [ "$SYSTEM_TYPE" = "openwrt" ] && command -v crond >/dev/null 2>&1 && \
        /etc/init.d/cron restart >/dev/null 2>&1 || true

    green "${service_name} 自动更新已设置（间隔: ${interval} 分钟）"
    green "Cron 表达式: $cron_entry"
    return 0
}

disable_scheduled_update_internal() {
    local service_type="$1"
    local cron_job_id="${service_type}_proxy_update"
    (crontab -l 2>/dev/null | grep -v "$cron_job_id") | crontab -
    green "${service_type} 自动更新已禁用"
}

manage_scheduled_update_menu() {
    local service_type="$1"
    local service_name env_file

    case "$service_type" in
        singbox) service_name="Sing-box"; env_file="$SB_ENV_FILE" ;;
        mihomo)  service_name="Mihomo";   env_file="$MH_ENV_FILE"  ;;
        *) red "无效服务类型: $service_type"; return 1 ;;
    esac

    if ! load_service_env "$env_file" 2>/dev/null || [ -z "${PROXY_API_URL:-}" ]; then
        red "请先设置订阅链接，再管理自动更新"
        return 1
    fi

    local current_interval="${CRON_INTERVAL:-0}"
    clear
    printf "\n%b=== 管理 %s 自动更新 ===%b\n" "$GREEN" "$service_name" "$NC"
    if [ "$current_interval" -eq 0 ]; then
        printf "当前状态: %b已禁用%b\n" "$RED" "$NC"
    else
        printf "当前状态: %b已启用%b (每 %s 分钟)\n" "$GREEN" "$NC" "$current_interval"
    fi
    printf "  1) 设置/更改更新间隔\n  2) 禁用自动更新\n  q) 返回\n"
    read -r -p "请输入选项: " choice

    case "$choice" in
        1)
            printf "请输入新间隔（分钟，0=禁用）: "
            read -r new_interval
            if ! echo "$new_interval" | grep -qE '^[0-9]+$'; then
                red "无效输入"; return 1
            fi
            update_env_field "$env_file" "CRON_INTERVAL" "$new_interval"
            if [ "$new_interval" -gt 0 ]; then
                setup_cron_job_internal "$service_type" "$new_interval"
            else
                disable_scheduled_update_internal "$service_type"
            fi
            ;;
        2)
            update_env_field "$env_file" "CRON_INTERVAL" "0"
            disable_scheduled_update_internal "$service_type"
            ;;
        q|Q) return 0 ;;
        *) red "无效选项" ;;
    esac
    return 0
}

view_version_internal() {
    local service_type="$1"
    local bin_path version_cmd service_name_display

    case "$service_type" in
        singbox) bin_path="$SB_BIN_PATH"; version_cmd="version"; service_name_display="Sing-box" ;;
        mihomo)  bin_path="$MH_BIN_PATH"; version_cmd="-v";      service_name_display="Mihomo"  ;;
        *) red "无效服务类型: $service_type"; return 1 ;;
    esac

    [ ! -x "$bin_path" ] && { red "$service_name_display 未安装"; return 1; }

    local output
    output=$("$bin_path" $version_cmd 2>&1)
    if [ $? -eq 0 ]; then
        green "$service_name_display 版本信息 (路径: $bin_path):"
        printf "%s\n" "$output"
    else
        red "查看版本失败: $output"
    fi
    return 0
}

singbox_management_menu() {
    while true; do
        clear
        local config_status="未配置"
        local service_status="未运行"
        [ -f "$SB_CONFIG_FILE" ] && config_status="已配置"
        manage_service_internal "singbox" "status" >/dev/null 2>&1 && service_status="运行中"
        local api_url
        api_url=$(get_config_manager_url "singbox" 2>/dev/null)

        printf "\n%b=== Sing-box 管理菜单 ===%b\n" "$GREEN" "$NC"
        printf "状态: %s | 配置: %s\n" "$service_status" "$config_status"
        printf "二进制: %s\n" "$SB_BIN_PATH"
        printf "API: %s\n" "${api_url:-未设置}"
        printf "%b=========================%b\n" "$GREEN" "$NC"
        printf " 1)  安装/更新 Sing-box\n"
        printf " 2)  设置环境变量（订阅）\n"
        printf " 3)  更新配置并重启\n"
        printf " 4)  启动服务\n"
        printf " 5)  停止服务\n"
        printf " 6)  重启服务\n"
        printf " 7)  查看服务状态\n"
        printf " 8)  %b管理自动更新%b\n" "$YELLOW" "$NC"
        printf " 9)  卸载 Sing-box\n"
        printf " 10) 查看版本\n"
        printf " e)  管理自启动\n"
        printf " c)  验证配置文件\n"
        printf " v)  查看日志\n"
        printf " q)  返回主菜单\n"
        printf "%b========================%b\n" "$GREEN" "$NC"
        read -r -p "请输入选项: " choice

        case "$choice" in
            1)  install_singbox ;;
            2)  setup_service_env "$SB_ENV_FILE" "Sing-box" ;;
            3)  update_config_and_start_service "singbox" ;;
            4)  manage_service_internal "singbox" "start" ;;
            5)  manage_service_internal "singbox" "stop" ;;
            6)  manage_service_internal "singbox" "restart" ;;
            7)  manage_service_internal "singbox" "status" ;;
            8)  manage_scheduled_update_menu "singbox" ;;
            9)  remove_all_files_and_service "singbox" ;;
            10) view_version_internal "singbox" ;;
            e|E) manage_autostart_internal "singbox" ;;
            c|C) validate_config_internal "singbox" ;;
            v|V) view_log_internal "singbox" ;;
            q|Q) return 0 ;;
            *) red "无效选项" ;;
        esac
        read -r -p "按 [Enter] 键继续..."
    done
}

mihomo_management_menu() {
    while true; do
        clear
        local config_status="未配置"
        local service_status="未运行"
        [ -f "$MH_CONFIG_FILE" ] && config_status="已配置"
        manage_service_internal "mihomo" "status" >/dev/null 2>&1 && service_status="运行中"
        local api_url
        api_url=$(get_config_manager_url "mihomo" 2>/dev/null)

        printf "\n%b=== Mihomo 管理菜单 ===%b\n" "$GREEN" "$NC"
        printf "状态: %s | 配置: %s\n" "$service_status" "$config_status"
        printf "二进制: %s\n" "$MH_BIN_PATH"
        printf "API: %s\n" "${api_url:-未设置}"
        printf "%b=========================%b\n" "$GREEN" "$NC"
        printf " 1)  安装/更新 Mihomo（稳定版）\n"
        printf " 2)  安装/更新 Mihomo Alpha（Smart Group）\n"
        printf " 3)  设置环境变量（订阅）\n"
        printf " 4)  更新配置并重启\n"
        printf " 5)  启动服务\n"
        printf " 6)  停止服务\n"
        printf " 7)  重启服务\n"
        printf " 8)  查看服务状态\n"
        printf " 9)  %b管理自动更新%b\n" "$YELLOW" "$NC"
        printf " 10) 查看版本\n"
        printf " a)  卸载 Mihomo\n"
        printf " e)  管理自启动\n"
        printf " c)  验证配置文件\n"
        printf " v)  查看日志\n"
        printf " q)  返回主菜单\n"
        printf "%b========================%b\n" "$GREEN" "$NC"
        read -r -p "请输入选项: " choice

        case "$choice" in
            1)  install_mihomo ;;
            2)  install_mihomo_alpha_smart ;;
            3)  setup_service_env "$MH_ENV_FILE" "Mihomo" ;;
            4)  update_config_and_start_service "mihomo" ;;
            5)  manage_service_internal "mihomo" "start" ;;
            6)  manage_service_internal "mihomo" "stop" ;;
            7)  manage_service_internal "mihomo" "restart" ;;
            8)  manage_service_internal "mihomo" "status" ;;
            9)  manage_scheduled_update_menu "mihomo" ;;
            10) view_version_internal "mihomo" ;;
            a|A) remove_all_files_and_service "mihomo" ;;
            e|E) manage_autostart_internal "mihomo" ;;
            c|C) validate_config_internal "mihomo" ;;
            v|V) view_log_internal "mihomo" ;;
            q|Q) return 0 ;;
            *) red "无效选项" ;;
        esac
        read -r -p "按 [Enter] 键继续..."
    done
}

common_settings_menu() {
    while true; do
        clear
        printf "\n%b=== 通用系统设置 ===%b\n" "$GREEN" "$NC"
        printf " 1) 检查网络连通性\n"
        printf " 2) 配置网络转发与 NAT\n"
        printf " 3) 清理系统转发与 NAT 配置\n"
        printf " 4) 修复下载工具（curl/wget）\n"
        printf " q) 返回主菜单\n"
        printf "%b=====================%b\n" "$GREEN" "$NC"
        read -r -p "请输入选项: " choice
        case "$choice" in
            1) check_network ;;
            2) configure_network_forwarding_nat ;;
            3) clean_up_system_configs ;;
            4) fix_openwrt_curl; detect_download_tool && green "当前下载工具: $DL_TOOL" ;;
            q|Q) return 0 ;;
            *) red "无效选项" ;;
        esac
        read -r -p "按 [Enter] 键继续..."
    done
}

initial_selection_menu() {
    detect_download_tool >/dev/null 2>&1 || true
    while true; do
        clear
        printf "\n%b=== 代理管理器 v2.1 ===%b\n" "$GREEN" "$NC"
        printf "设备: %s | 系统: %s | 下载工具: %s\n" "$DEVICE_NAME" "$SYSTEM_TYPE" "${DL_TOOL:-未探测}"
        printf "%b================================%b\n" "$GREEN" "$NC"
        printf " 1) 管理 Sing-box\n"
        printf " 2) 管理 Mihomo\n"
        printf " 3) 通用系统设置\n"
        printf " q) 退出\n"
        printf "%b================================%b\n" "$GREEN" "$NC"
        read -r -p "请选择操作: " choice
        case "$choice" in
            1) singbox_management_menu ;;
            2) mihomo_management_menu ;;
            3) common_settings_menu ;;
            q|Q) green "正在退出..."; exit 0 ;;
            *) red "无效选项" ;;
        esac
    done
}

non_interactive_mode() {
    case "${1:-}" in
        --update)
            check_root
            local svc="${2:-}"
            [ -z "$svc" ] && { red "用法: $0 --update [singbox|mihomo]"; exit 1; }
            log "Cron 触发: 更新 $svc 配置"
            update_config_and_start_service "$svc"
            ;;
        *)
            red "不支持的命令: ${1:-}"
            exit 1
            ;;
    esac
    exit 0
}

main() {
    check_bash_on_openwrt "$@"

    if [ $# -gt 0 ]; then
        non_interactive_mode "$@"
        return
    fi

    check_root
    install_deps
    initial_selection_menu
}

main "$@"
