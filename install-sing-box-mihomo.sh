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
SB_AUTOHEAL_BACKUP="$SB_BASE_DIR/.autoheal.bak"

MH_BASE_DIR="/etc/mihomo"
MH_BIN_PATH="/usr/local/bin/mihomo"
MH_CONFIG_FILE="$MH_BASE_DIR/config.yaml"
MH_ENV_FILE="$MH_BASE_DIR/.mihomo_env"
MH_SERVICE_NAME="mihomo"
MH_DNS_BACKUP_DIR="/etc/mihomo/.dns_backup"
MH_AUTOHEAL_BACKUP="$MH_BASE_DIR/.autoheal.bak"
MH_DEFAULT_DNS_PORT="7874"

SB_DNS_BACKUP_DIR="/etc/sing-box/.dns_backup"

BIN_DIR="/usr/local/bin"
LOG_FILE="/var/log/proxy-manager.log"
LOG_MAX_SIZE=5242880
DEPS_INSTALLED_MARKER="/var/lib/proxy_manager_deps_installed"
MIRROR_CACHE_FILE="/var/lib/proxy_manager_mirror.cache"

PROXY_MIRRORS="https://ghfast.top/ https://gh-proxy.com/ https://ghproxy.net/ https://cdn.yyds9527.nyc.mn/ https://mirror.ghproxy.com/"

DL_CONNECT_TIMEOUT=8
DL_MAX_TIME=180
DL_SPEED_LIMIT=1024
DL_SPEED_TIME=30
DL_RETRY=1
DL_RETRY_DELAY=2

CFG_CONNECT_TIMEOUT=10
CFG_MAX_TIME=120
CFG_SPEED_LIMIT=512
CFG_SPEED_TIME=60
CFG_RETRY=2
CFG_RETRY_DELAY=3

PROBE_TIMEOUT=5

AUTOHEAL_WAIT_INITIAL=3
AUTOHEAL_WAIT_RESTART=6

ENV_INSTALLED=0
ENV_CONFIG_EXISTS=0
ENV_CONFIG_VALID=0
ENV_SERVICE_RUNNING=0
ENV_SERVICE_ENABLED=0
ENV_DNS_CONFIGURED=0
ENV_NETWORK_OK=0
ENV_LOCAL_CONFIGS=""

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
    if [ -f /etc/openwrt_release ] || [ -f /etc/openwrt_version ]; then
        echo "openwrt"; return
    fi
    if [ -d /etc/config ] && command -v uci >/dev/null 2>&1; then
        echo "openwrt"; return
    fi
    if grep -qiE "openwrt|immortalwrt|lede|istoreos" /etc/banner 2>/dev/null; then
        echo "openwrt"; return
    fi
    if [ -f /etc/os-release ] && grep -qiE "openwrt|immortalwrt|lede" /etc/os-release 2>/dev/null; then
        echo "openwrt"; return
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
                curl $curl_opts -sS -o "$out" "$url"
            else
                curl $curl_opts -sS "$url"
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
    local connect_timeout="${2:-8}"
    local max_time="${3:-20}"
    http_fetch "$url" "" "$connect_timeout" "$max_time" 0 0
}

probe_url() {
    local url="$1"
    detect_download_tool || return 127
    case "$DL_TOOL" in
        curl)
            curl -sS -o /dev/null -m "$PROBE_TIMEOUT" --connect-timeout "$PROBE_TIMEOUT" -w "%{http_code}" "$url" 2>/dev/null
            ;;
        wget)
            wget --spider -q --timeout="$PROBE_TIMEOUT" --tries=1 "$url" 2>/dev/null && echo "200" || echo "000"
            ;;
        uclient-fetch)
            uclient-fetch --spider -q --timeout="$PROBE_TIMEOUT" "$url" 2>/dev/null && echo "200" || echo "000"
            ;;
    esac
}

load_best_mirror() {
    [ -f "$MIRROR_CACHE_FILE" ] && cat "$MIRROR_CACHE_FILE" 2>/dev/null
}

save_best_mirror() {
    local mirror="$1"
    mkdir -p "$(dirname "$MIRROR_CACHE_FILE")"
    echo "$mirror" > "$MIRROR_CACHE_FILE"
}

test_direct_github() {
    log "探测 GitHub 直连..."
    local code
    code=$(probe_url "https://api.github.com" 2>/dev/null)
    if [ "$code" = "200" ] || [ "$code" = "301" ] || [ "$code" = "302" ]; then
        green "GitHub 直连可用"
        return 0
    fi
    yellow "GitHub 直连不可用 (HTTP: ${code:-无})"
    return 1
}

download_file_smart() {
    local url="$1"
    local output_path="$2"
    local mode="${3:-binary}"
    local filename="${url##*/}"

    local connect_timeout max_time speed_limit speed_time
    if [ "$mode" = "config" ]; then
        connect_timeout=$CFG_CONNECT_TIMEOUT
        max_time=$CFG_MAX_TIME
        speed_limit=$CFG_SPEED_LIMIT
        speed_time=$CFG_SPEED_TIME
    else
        connect_timeout=$DL_CONNECT_TIMEOUT
        max_time=$DL_MAX_TIME
        speed_limit=$DL_SPEED_LIMIT
        speed_time=$DL_SPEED_TIME
    fi

    local cached_mirror
    cached_mirror=$(load_best_mirror)

    _try_download() {
        local turl="$1"
        rm -f "$output_path"
        log "下载 (工具: ${DL_TOOL:-未探测}, 模式: $mode): $(echo "$turl" | sed 's|https://[^/]*/||' | head -c 80)..."
        http_fetch "$turl" "$output_path" "$connect_timeout" "$max_time" "$speed_limit" "$speed_time"
        local ec=$?
        if [ "$ec" -eq 0 ] && [ -s "$output_path" ]; then
            return 0
        fi
        case "$ec" in
            6)  yellow "DNS 解析失败" ;;
            7)  yellow "无法连接到服务器" ;;
            28) yellow "下载超时" ;;
            35) yellow "SSL 握手失败" ;;
            56) yellow "数据传输中断" ;;
            127) red "无可用下载工具" ;;
            *)  yellow "下载失败，退出码: $ec" ;;
        esac
        return 1
    }

    if [ -n "$cached_mirror" ]; then
        log "使用缓存镜像: $cached_mirror"
        if _try_download "${cached_mirror}${url}"; then
            green "下载成功: $filename"
            return 0
        fi
        yellow "缓存镜像失效"
        rm -f "$MIRROR_CACHE_FILE"
    fi

    if [ ! -f "$MIRROR_CACHE_FILE" ] && test_direct_github; then
        if _try_download "$url"; then
            green "直连下载成功: $filename"
            save_best_mirror ""
            return 0
        fi
    fi

    log "轮询镜像加速下载..."
    for mirror in $PROXY_MIRRORS; do
        log "尝试镜像: $mirror"
        if _try_download "${mirror}${url}"; then
            green "镜像下载成功: $mirror"
            save_best_mirror "$mirror"
            return 0
        fi
    done

    red "所有下载源均失败: $filename"
    return 1
}

download_file_with_proxy() {
    download_file_smart "$@"
}

load_service_env() {
    local env_file="$1"
    local verbose="${2:-1}"
    unset PROXY_API_URL PROXY_MODE CRON_INTERVAL 2>/dev/null || true

    if [ ! -f "$env_file" ]; then
        [ "$verbose" = "1" ] && yellow "未检测到环境变量文件: $env_file"
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
        [ "$verbose" = "1" ] && yellow "env 未找到 PROXY_API_URL"
        return 1
    fi
    [ "$verbose" = "1" ] && green "已加载: $env_file"
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
        yellow "env 文件不存在"
        return 1
    fi

    if grep -q "^${key}=" "$env_file"; then
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$env_file"
    else
        echo "${key}=\"${value}\"" >> "$env_file"
    fi
}

fix_openwrt_curl() {
    yellow "尝试修复下载工具..."
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
        log "跳过依赖检查"
        detect_download_tool >/dev/null 2>&1 || fix_openwrt_curl
        return 0
    fi

    log "首次运行，安装依赖..."
    local pkg_manager install_cmd update_cmd pkgs failed_pkgs
    failed_pkgs=""

    case "$SYSTEM_TYPE" in
        debian)
            pkg_manager="apt"
            update_cmd="apt-get update"
            install_cmd="apt-get install -y"
            pkgs="curl wget tar iptables ipset jq psmisc cron unzip dnsutils"
            ;;
        centos)
            pkg_manager="yum"
            update_cmd=""
            install_cmd="yum install -y"
            pkgs="curl wget tar iptables ipset jq psmisc cronie unzip bind-utils"
            ;;
        alpine)
            pkg_manager="apk"
            update_cmd="apk update"
            install_cmd="apk add"
            pkgs="curl wget tar iptables ipset jq psmisc unzip bash bind-tools"
            ;;
        arch)
            pkg_manager="pacman"
            update_cmd="pacman -Sy"
            install_cmd="pacman -S --noconfirm"
            pkgs="curl wget tar iptables ipset jq psmisc cronie unzip bind"
            ;;
        openwrt)
            pkg_manager="opkg"
            update_cmd="opkg update"
            install_cmd="opkg install"
            pkgs="wget-ssl tar iptables ipset jq unzip bash ca-bundle ca-certificates bind-dig"
            ;;
        *)
            red "不支持的系统类型"
            return 1
            ;;
    esac

    log "使用包管理器: $pkg_manager"
    if [ -n "$update_cmd" ]; then
        if ! $update_cmd; then
            yellow "包列表更新失败，尝试直接安装..."
        fi
    fi

    for pkg in $pkgs; do
        if ! $install_cmd "$pkg" >/dev/null 2>&1; then
            yellow "安装 $pkg 失败"
            failed_pkgs="$failed_pkgs $pkg"
        else
            green "已安装: $pkg"
        fi
    done

    if [ "$SYSTEM_TYPE" = "openwrt" ]; then
        opkg install --force-reinstall libmbedtls libustream-mbedtls >/dev/null 2>&1 || true
        if command -v crond >/dev/null 2>&1 || [ -f /etc/init.d/cron ]; then
            /etc/init.d/cron enable 2>/dev/null || true
            /etc/init.d/cron start 2>/dev/null || true
        fi
    fi

    if ! detect_download_tool >/dev/null 2>&1; then
        fix_openwrt_curl
        detect_download_tool >/dev/null 2>&1 || { red "无可用下载工具"; return 1; }
    fi

    [ -n "$failed_pkgs" ] && yellow "失败依赖:$failed_pkgs" || green "所有依赖安装成功"
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
    if ping -c 1 -W 3 223.5.5.5 >/dev/null 2>&1 || ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
        green "网络连接正常"
        return 0
    fi
    if http_get "https://www.baidu.com" 5 10 >/dev/null 2>&1 || \
       http_get "https://1.1.1.1" 5 10 >/dev/null 2>&1; then
        green "网络连接正常 (http)"
        return 0
    fi
    red "无法连接到外网"
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

    sysctl -p >/dev/null 2>&1 || true

    local NAT_SOURCE_CIDR="192.168.0.0/16"
    if ! iptables -t nat -C POSTROUTING -s "$NAT_SOURCE_CIDR" -j MASQUERADE 2>/dev/null; then
        if iptables -t nat -A POSTROUTING -s "$NAT_SOURCE_CIDR" -j MASQUERADE; then
            green "IPv4 NAT 规则添加成功"
            if [ "$SYSTEM_TYPE" = "openwrt" ]; then
                yellow "OpenWrt: 请手动持久化 NAT 规则到 UCI 防火墙"
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
        if ! ip6tables -t nat -C POSTROUTING -s "$NAT_SOURCE_CIDR_V6" -j MASQUERADE 2>/dev/null; then
            if ip6tables -t nat -A POSTROUTING -s "$NAT_SOURCE_CIDR_V6" -j MASQUERADE; then
                green "IPv6 NAT 规则添加成功"
                if [ "$SYSTEM_TYPE" != "openwrt" ] && command -v ip6tables-save >/dev/null 2>&1; then
                    mkdir -p /etc/iptables
                    ip6tables-save > /etc/iptables/rules.v6 || yellow "ip6tables-save 失败"
                fi
            else
                yellow "IPv6 NAT 添加失败"
            fi
        else
            green "IPv6 NAT 规则已存在"
        fi
    fi
    return 0
}

clean_up_system_configs() {
    log "清理系统配置..."
    sed -i '/^net.ipv4.ip_forward=/d' /etc/sysctl.conf
    sed -i '/^net.ipv6.conf.all.forwarding=/d' /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1 || true

    if iptables -t nat -C POSTROUTING -s "192.168.0.0/16" -j MASQUERADE 2>/dev/null; then
        iptables -t nat -D POSTROUTING -s "192.168.0.0/16" -j MASQUERADE
        green "IPv4 NAT 规则已移除"
    fi
    if command -v ip6tables >/dev/null 2>&1; then
        if ip6tables -t nat -C POSTROUTING -s "fc00::/7" -j MASQUERADE 2>/dev/null; then
            ip6tables -t nat -D POSTROUTING -s "fc00::/7" -j MASQUERADE
            green "IPv6 NAT 规则已移除"
        fi
    fi
    green "系统配置清理完成"
}

setup_service_env() {
    local env_file="$1"
    local service_name="$2"

    log "设置 ${service_name} 环境变量..."

    local PROXY_API_URL=""
    while true; do
        printf "%b请输入 %s 订阅链接或 API 地址：%b\n" "$GREEN" "$service_name" "$NC"
        read -r PROXY_API_URL
        if [ -z "$PROXY_API_URL" ]; then
            red "订阅链接不能为空"
            continue
        fi
        if ! echo "$PROXY_API_URL" | grep -qE '^https?://'; then
            red "URL 格式无效"
            continue
        fi
        break
    done

    printf "%b请选择代理模式：%b\n  1) global\n  2) gfwlist\n  3) rule\n  4) direct\n" "$GREEN" "$NC"
    read -r PROXY_MODE_INPUT
    local PROXY_MODE="rule"
    case "$PROXY_MODE_INPUT" in
        1) PROXY_MODE="global" ;;
        2) PROXY_MODE="gfwlist" ;;
        3) PROXY_MODE="rule" ;;
        4) PROXY_MODE="direct" ;;
        *) yellow "无效选择，使用默认 rule 模式" ;;
    esac

    printf "%b请输入自动更新间隔（分钟，0=不更新，推荐 1440）：%b\n" "$GREEN" "$NC"
    read -r CRON_INTERVAL_INPUT
    local CRON_INTERVAL=1440
    if echo "$CRON_INTERVAL_INPUT" | grep -Eq '^[0-9]+$'; then
        CRON_INTERVAL="$CRON_INTERVAL_INPUT"
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

get_singbox_versions() {
    local arch="$1"
    local releases_info
    releases_info=$(http_get "https://api.github.com/repos/SagerNet/sing-box/releases?per_page=10" 10 20) || {
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
        red "未找到 $arch 架构的 Sing-box 版本"
        return 1
    fi
    return 0
}

install_singbox() {
    log "开始安装 Sing-box..."
    check_network || return 1
    configure_network_forwarding_nat || return 1

    local local_arch
    local_arch=$(get_arch) || return 1

    log "获取 Sing-box 版本列表..."
    local versions_raw
    versions_raw=$(get_singbox_versions "$local_arch") || return 1

    local versions_list=()
    while IFS= read -r line; do
        [ -n "$line" ] && versions_list+=("$line")
    done <<< "$versions_raw"

    [ "${#versions_list[@]}" -eq 0 ] && { red "版本列表为空"; return 1; }

    clear
    printf "\n%b=== 选择 Sing-box 版本 ===%b\n" "$GREEN" "$NC"
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
    printf "请输入选项 (1-%d): " "${#versions_list[@]}"
    read -r choice

    if ! echo "$choice" | grep -qE '^[0-9]+$' || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#versions_list[@]}" ]; then
        red "无效选项"
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
    if ! download_file_smart "$DOWNLOAD_URL" "$TAR_PATH" "binary"; then
        red "下载失败"; cleanup; return 1
    fi

    if ! tar -xzf "$TAR_PATH" -C "$TEMP_DIR"; then
        red "解压失败"; cleanup; return 1
    fi

    local SINGBOX_BIN
    SINGBOX_BIN=$(find "$TEMP_DIR" -type f -name "sing-box" -perm /a+x | head -n 1)
    [ -z "$SINGBOX_BIN" ] && { red "未找到二进制"; cleanup; return 1; }

    manage_service_internal "singbox" "stop" >/dev/null 2>&1 || true
    if [ "$SB_BIN_PATH" = "/usr/local/bin/sing-box" ] || [ ! -x "$SB_BIN_PATH" ]; then
        SB_BIN_PATH="/usr/local/bin/sing-box"
    fi
    mkdir -p "$(dirname "$SB_BIN_PATH")"
    cp "$SINGBOX_BIN" "$SB_BIN_PATH" && chmod +x "$SB_BIN_PATH" || { red "安装失败"; cleanup; return 1; }
    cleanup

    green "Sing-box $VERSION_TAG 安装成功！路径: $SB_BIN_PATH"
    [ ! -f "$SB_CONFIG_FILE" ] && generate_initial_singbox_config
    setup_service "singbox"
    manage_autostart_internal "singbox" "enable"
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
        {"type": "tun", "tag": "tun-in", "stack": "system", "auto_route": true, "strict_route": true, "inet4_address": "172.19.0.1/24", "sniff": true, "detour": "proxy"},
        {"type": "mixed", "tag": "mixed-in", "listen": "::", "listen_port": 2080, "detour": "proxy"}
    ],
    "outbounds": [
        {"type": "direct", "tag": "direct"},
        {"type": "block", "tag": "block"},
        {"type": "dns", "tag": "dns-out"},
        {"type": "selector", "tag": "proxy", "outbounds": ["direct"]}
    ],
    "route": {
        "rules": [
            {"protocol": "dns", "outbound": "dns-out"},
            {"inbound": ["tun-in", "mixed-in"], "outbound": "proxy"}
        ],
        "auto_detect_interface": true
    },
    "dns": {
        "servers": [
            {"tag": "google", "address": "8.8.8.8", "detour": "proxy"},
            {"tag": "local", "address": "223.5.5.5", "detour": "direct"}
        ],
        "rules": [
            {"outbound": "direct", "server": "local"}
        ]
    }
}
EOF
    green "Sing-box 初始配置已生成"
}

get_mihomo_latest_version() {
    local latest_version
    latest_version=$(http_get "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest" 10 20 | jq -r '.tag_name')
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
    latest_version=$(get_mihomo_latest_version) || { red "获取版本失败"; return 1; }
    green "Mihomo 最新版本: $latest_version"

    local local_arch
    local_arch=$(get_arch) || return 1

    local FILENAME=""
    case "$local_arch" in
        amd64)    FILENAME="mihomo-linux-amd64-${latest_version}.gz" ;;
        arm64)    FILENAME="mihomo-linux-arm64-${latest_version}.gz" ;;
        armv7)    FILENAME="mihomo-linux-armv7l-${latest_version}.gz" ;;
        armv6)    FILENAME="mihomo-linux-armv6-${latest_version}.gz" ;;
        riscv64)  FILENAME="mihomo-linux-riscv64-${latest_version}.gz" ;;
        386)      FILENAME="mihomo-linux-386-${latest_version}.gz" ;;
        mips)     FILENAME="mihomo-linux-mips-softfloat-${latest_version}.gz" ;;
        mipsle)   FILENAME="mihomo-linux-mipsle-softfloat-${latest_version}.gz" ;;
        mips64)   FILENAME="mihomo-linux-mips64-${latest_version}.gz" ;;
        mips64le) FILENAME="mihomo-linux-mips64le-${latest_version}.gz" ;;
        *) red "不支持的架构"; return 1 ;;
    esac

    local DOWNLOAD_URL="https://github.com/MetaCubeX/mihomo/releases/download/${latest_version}/${FILENAME}"
    TEMP_DIR=$(mktemp -d)
    local GZ_PATH="$TEMP_DIR/$FILENAME"

    log "下载 Mihomo ${latest_version}..."
    if ! download_file_smart "$DOWNLOAD_URL" "$GZ_PATH" "binary"; then
        red "下载失败"; cleanup; return 1
    fi

    if ! gzip -d "$GZ_PATH"; then
        red "解压失败"; cleanup; return 1
    fi
    local MIHOMO_BIN="${GZ_PATH%.gz}"
    [ ! -f "$MIHOMO_BIN" ] && { red "未找到二进制"; cleanup; return 1; }

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
    return 0
}

get_mihomo_alpha_versions() {
    local arch="$1"
    local page=1
    local found=0

    while [ "$page" -le 3 ]; do
        local releases_info
        releases_info=$(http_get "https://api.github.com/repos/vernesong/mihomo/releases?page=${page}&per_page=30" 10 20) || break

        local count
        count=$(echo "$releases_info" | jq 'length' 2>/dev/null)
        [ -z "$count" ] || [ "$count" -eq 0 ] && break

        while IFS= read -r release_info; do
            local rel_published
            rel_published=$(echo "$release_info" | jq -r '.published_at // "unknown"' | cut -d'T' -f1)
            while IFS= read -r asset_info; do
                local asset_name download_url commit_id
                asset_name=$(echo "$asset_info" | jq -r '.name')
                if echo "$asset_name" | grep -qE "mihomo-linux-${arch}(-compatible)?-alpha-smart-[0-9a-f]+\.gz"; then
                    commit_id=$(echo "$asset_name" | grep -oE '[0-9a-f]{7,}' | head -n 1)
                    download_url=$(echo "$asset_info" | jq -r '.browser_download_url')
                    printf "alpha-smart-%s|%s|%s|%s\n" "$commit_id" "$rel_published" "$download_url" "$asset_name"
                    found=$((found + 1))
                fi
            done < <(echo "$release_info" | jq -c '.assets[]')
        done < <(echo "$releases_info" | jq -c '.[]')

        page=$((page + 1))
    done

    if [ "$found" -eq 0 ]; then
        red "未找到 $arch 架构的 Alpha 版本"
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
        red "$local_arch 无 Alpha 版本"
        return 1
    fi

    log "获取 Alpha 版本列表..."
    local versions_raw
    versions_raw=$(get_mihomo_alpha_versions "$local_arch") || return 1

    local versions_list=()
    while IFS= read -r line; do
        [ -n "$line" ] && versions_list+=("$line")
    done <<< "$versions_raw"

    [ "${#versions_list[@]}" -eq 0 ] && { red "版本列表为空"; return 1; }

    clear
    printf "\n%b=== 选择 Mihomo Alpha 版本 ===%b\n" "$GREEN" "$NC"
    local i=1
    for version_info in "${versions_list[@]}"; do
        local ver_display published_at
        ver_display=$(echo "$version_info" | cut -d'|' -f1)
        published_at=$(echo "$version_info" | cut -d'|' -f2)
        printf "  %d) %s (发布于: %s)\n" "$i" "$ver_display" "$published_at"
        i=$((i + 1))
    done
    printf "请输入选项 (1-%d): " "${#versions_list[@]}"
    read -r choice

    if ! echo "$choice" | grep -qE '^[0-9]+$' || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#versions_list[@]}" ]; then
        red "无效选项"
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
    if ! download_file_smart "$DOWNLOAD_URL" "$GZ_PATH" "binary"; then
        red "下载失败"; cleanup; return 1
    fi

    if ! gzip -d "$GZ_PATH"; then
        red "解压失败"; cleanup; return 1
    fi
    local MIHOMO_BIN="${GZ_PATH%.gz}"
    [ ! -f "$MIHOMO_BIN" ] && { red "未找到二进制"; cleanup; return 1; }

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

    log "下载 LightGBM Model..."
    if download_file_smart "$FIXED_MODEL_URL" "$MODEL_BIN_PATH" "binary"; then
        chmod 644 "$MODEL_BIN_PATH"
        green "model.bin 下载成功"
    else
        yellow "model.bin 下载失败，Smart Group 功能受限"
    fi

    cleanup
    green "Mihomo Alpha ($VERSION_DISPLAY) 安装成功！路径: $MH_BIN_PATH"
    [ ! -f "$MH_CONFIG_FILE" ] && generate_initial_mihomo_config
    setup_service "mihomo"
    manage_autostart_internal "mihomo" "enable"
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
  auto-redirect: true
  strict-route: true
  inet4-address: 198.18.0.1/16
  dns-hijack:
    - "any:53"

dns:
  enable: true
  listen: 0.0.0.0:7874
  ipv6: false
  respect-rules: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter:
    - "+.lan"
    - "+.local"
    - "+.arpa"
    - "localhost"
  nameserver:
    - https://223.5.5.5/dns-query
    - https://1.12.12.12/dns-query
  fallback:
    - https://223.5.5.5/dns-query
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
        *) red "无效的服务类型"; return 1 ;;
    esac

    [ ! -x "$proxy_bin_path" ] && { red "$service_name_display 未安装"; return 1; }

    if ! load_service_env "$env_file"; then
        red "无法加载环境变量"
        return 1
    fi

    log "从 API 更新配置..."

    local tmp_config
    tmp_config=$(mktemp)

    local exit_code=1 attempt=0
    while [ "$attempt" -lt "$CFG_RETRY" ]; do
        attempt=$((attempt + 1))
        log "配置下载尝试 $attempt/$CFG_RETRY..."
        http_fetch "$PROXY_API_URL" "$tmp_config" "$CFG_CONNECT_TIMEOUT" "$CFG_MAX_TIME" "$CFG_SPEED_LIMIT" "$CFG_SPEED_TIME"
        exit_code=$?
        if [ "$exit_code" -eq 0 ] && [ -s "$tmp_config" ]; then
            break
        fi
        yellow "下载失败 (exit $exit_code)"
        if [ "$attempt" -lt "$CFG_RETRY" ]; then
            sleep "$CFG_RETRY_DELAY"
            > "$tmp_config"
        fi
    done

    if [ "$exit_code" -ne 0 ] || [ ! -s "$tmp_config" ]; then
        red "配置下载失败"
        rm -f "$tmp_config"
        return 1
    fi

    if [ "$service_type" = "singbox" ]; then
        if ! jq empty "$tmp_config" >/dev/null 2>&1; then
            red "不是有效 JSON"
            rm -f "$tmp_config"
            return 1
        fi
    elif [ "$service_type" = "mihomo" ]; then
        if ! grep -q "proxies:" "$tmp_config"; then
            red "配置不含 proxies 字段"
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
    fi

    manage_service_internal "$service_type" "restart"
    green "$service_name_display 配置更新并重启完成"
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
        *) red "无效服务类型"; return 1 ;;
    esac

    [ ! -x "$bin_path" ] && { red "$bin_path 不可执行"; return 1; }
    [ ! -f "$config_file" ] && { red "配置文件不存在: $config_file"; return 1; }

    if [ "$SYSTEM_TYPE" = "openwrt" ]; then
        local initd_path="/etc/init.d/$service_name"
        log "创建 OpenWrt 服务: $initd_path"
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
        green "OpenWrt 服务文件创建成功"
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
        green "Systemd 服务文件创建成功"
    fi
    return 0
}

setup_service() {
    local service_type="$1"
    local service_name_display env_file

    case "$service_type" in
        "singbox") service_name_display="Sing-box"; env_file="$SB_ENV_FILE" ;;
        "mihomo")  service_name_display="Mihomo";   env_file="$MH_ENV_FILE" ;;
        *) red "无效服务类型"; return 1 ;;
    esac

    if ! load_service_env "$env_file" 0 2>/dev/null; then
        if ! setup_service_env "$env_file" "$service_name_display"; then
            red "环境变量设置失败"
            return 1
        fi
    fi

    setup_service_files "$service_type" || { red "服务文件创建失败"; return 1; }
    manage_service_internal "$service_type" "restart"

    if load_service_env "$env_file" 0 2>/dev/null && [ "${CRON_INTERVAL:-0}" -gt 0 ]; then
        setup_cron_job_internal "$service_type" "${CRON_INTERVAL}"
    fi

    green "$service_name_display 服务部署成功"
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
        *) red "无效服务类型"; return 1 ;;
    esac

    yellow "警告：将完全卸载 ${service_name_display}"
    yellow "二进制路径: $bin_path"
    printf "确认继续？(y/N): "
    read -r confirm
    case "$confirm" in
        y|Y) ;;
        *) green "已取消"; return 0 ;;
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
        yellow "系统包管理器安装的二进制未删除"
    fi
    rm -rf "$base_dir"
    green "$service_name_display 卸载完成"
    return 0
}

parse_mihomo_dns_port() {
    local cfg="${1:-$MH_CONFIG_FILE}"
    [ ! -f "$cfg" ] && { echo ""; return 1; }
    local port
    port=$(awk '
        /^dns:/ { in_dns=1; next }
        /^[a-zA-Z]/ && !/^dns:/ { in_dns=0 }
        in_dns && /^[[:space:]]+listen:/ {
            gsub(/["'"'"']/, "")
            n=split($0, a, ":")
            print a[n]
            exit
        }
    ' "$cfg" | tr -d ' \t')
    echo "$port"
}

check_mihomo_dns_enabled() {
    local cfg="${1:-$MH_CONFIG_FILE}"
    [ ! -f "$cfg" ] && return 1
    awk '
        /^dns:/ { in_dns=1; next }
        /^[a-zA-Z]/ { in_dns=0 }
        in_dns && /^[[:space:]]+enable:[[:space:]]*true/ { print "yes"; exit }
    ' "$cfg" | grep -q "yes"
}

get_mihomo_yaml_field() {
    local section="$1"
    local field="$2"
    local cfg="${3:-$MH_CONFIG_FILE}"
    [ ! -f "$cfg" ] && { echo ""; return 1; }
    awk -v sec="^${section}:" -v fld="${field}:" '
        $0 ~ sec { in_sec=1; next }
        /^[a-zA-Z]/ && !($0 ~ sec) { in_sec=0 }
        in_sec {
            if (match($0, "^[[:space:]]+" fld "[[:space:]]*")) {
                v = substr($0, RSTART + RLENGTH)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
                gsub(/["'"'"']/, "", v)
                print v
                exit
            }
        }
    ' "$cfg"
}

update_mihomo_dns_port() {
    local new_port="$1"
    local cfg="$MH_CONFIG_FILE"
    [ ! -f "$cfg" ] && { red "配置文件不存在"; return 1; }

    cp "$cfg" "${cfg}.dnsbak"

    if grep -qE '^[[:space:]]+listen:' "$cfg"; then
        awk -v port="$new_port" '
            /^dns:/ { in_dns=1 }
            /^[a-zA-Z]/ && !/^dns:/ { in_dns=0 }
            in_dns && /^[[:space:]]+listen:/ {
                sub(/listen:.*/, "listen: 0.0.0.0:" port)
            }
            { print }
        ' "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
        green "Mihomo DNS 端口已更新: $new_port"
    else
        red "未找到 dns.listen 字段"
        return 1
    fi
    return 0
}

inject_mihomo_dns_block() {
    local port="$1"
    local cfg="$MH_CONFIG_FILE"
    [ ! -f "$cfg" ] && { red "配置文件不存在"; return 1; }

    cp "$cfg" "${cfg}.dnsbak"

    if grep -qE '^dns:' "$cfg"; then
        yellow "已有 dns 段，跳过注入"
        return 1
    fi

    cat >> "$cfg" << EOF

dns:
  enable: true
  listen: 0.0.0.0:${port}
  ipv6: false
  respect-rules: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter:
    - "+.lan"
    - "+.local"
    - "+.arpa"
    - "localhost"
  nameserver:
    - https://223.5.5.5/dns-query
    - https://1.12.12.12/dns-query
  fallback:
    - https://223.5.5.5/dns-query
  fallback-filter:
    geoip: true
    geoip-code: CN
EOF
    green "已注入 dns 段，端口: $port"
    return 0
}

parse_singbox_dns_port() {
    local cfg="${1:-$SB_CONFIG_FILE}"
    [ ! -f "$cfg" ] && { echo ""; return 1; }
    jq -r '.inbounds[]? | select(.type=="direct" and (.tag // "" | contains("dns"))) | .listen_port // empty' "$cfg" 2>/dev/null | head -n 1
}

check_singbox_dns_configured() {
    local cfg="${1:-$SB_CONFIG_FILE}"
    [ ! -f "$cfg" ] && return 1
    jq -e '.dns.servers | length > 0' "$cfg" >/dev/null 2>&1
}

detect_dns_backend() {
    if [ "$SYSTEM_TYPE" = "openwrt" ] && command -v uci >/dev/null 2>&1; then
        echo "dnsmasq-uci"; return
    fi
    if systemctl is-active systemd-resolved >/dev/null 2>&1; then
        echo "systemd-resolved"; return
    fi
    if [ -f /etc/dnsmasq.conf ] || systemctl is-active dnsmasq >/dev/null 2>&1 || \
       command -v dnsmasq >/dev/null 2>&1; then
        echo "dnsmasq"; return
    fi
    if [ -f /etc/resolv.conf ]; then
        echo "resolv.conf"; return
    fi
    echo "unknown"
}

backup_dns_config() {
    local backend="$1"
    local backup_dir="${2:-$MH_DNS_BACKUP_DIR}"
    mkdir -p "$backup_dir"
    case "$backend" in
        dnsmasq-uci)
            {
                echo "# backup at $(date)"
                uci show dhcp.@dnsmasq[0] 2>/dev/null
            } > "$backup_dir/dnsmasq-uci.bak"
            ;;
        systemd-resolved)
            [ -f /etc/systemd/resolved.conf ] && \
                cp /etc/systemd/resolved.conf "$backup_dir/resolved.conf.bak"
            ;;
        dnsmasq)
            [ -f /etc/dnsmasq.conf ] && cp /etc/dnsmasq.conf "$backup_dir/dnsmasq.conf.bak"
            [ -d /etc/dnsmasq.d ] && cp -r /etc/dnsmasq.d "$backup_dir/dnsmasq.d.bak" 2>/dev/null
            ;;
        resolv.conf)
            cp /etc/resolv.conf "$backup_dir/resolv.conf.bak"
            ;;
    esac
    green "DNS 配置已备份到 $backup_dir"
}

apply_dns_forward() {
    local target_port="$1"
    local backup_dir="${2:-$MH_DNS_BACKUP_DIR}"
    local backend
    backend=$(detect_dns_backend)

    log "DNS 后端: $backend"
    backup_dns_config "$backend" "$backup_dir"

    case "$backend" in
        dnsmasq-uci)
            uci set dhcp.@dnsmasq[0].noresolv='1'
            uci set dhcp.@dnsmasq[0].rebind_protection='0'
            uci -q delete dhcp.@dnsmasq[0].server
            uci add_list dhcp.@dnsmasq[0].server="127.0.0.1#${target_port}"
            uci commit dhcp
            if /etc/init.d/dnsmasq restart >/dev/null 2>&1; then
                green "dnsmasq(uci) 已转发到 127.0.0.1:${target_port}"
            else
                red "dnsmasq 重启失败"; return 1
            fi
            ;;
        systemd-resolved)
            mkdir -p /etc/systemd/resolved.conf.d
            cat > /etc/systemd/resolved.conf.d/proxy-manager.conf << EOF
[Resolve]
DNS=127.0.0.1:${target_port}
FallbackDNS=
Domains=~.
DNSStubListener=no
EOF
            if [ -L /etc/resolv.conf ] || [ ! -f /etc/resolv.conf ]; then
                rm -f /etc/resolv.conf
                echo "nameserver 127.0.0.1" > /etc/resolv.conf
            fi
            if systemctl restart systemd-resolved; then
                green "systemd-resolved 已转发"
            else
                red "重启失败"; return 1
            fi
            ;;
        dnsmasq)
            mkdir -p /etc/dnsmasq.d
            cat > /etc/dnsmasq.d/proxy-manager-forward.conf << EOF
no-resolv
server=127.0.0.1#${target_port}
EOF
            systemctl restart dnsmasq >/dev/null 2>&1 && green "dnsmasq 已转发" || { red "重启失败"; return 1; }
            ;;
        resolv.conf)
            yellow "仅使用 resolv.conf，DHCP 可能覆盖"
            echo "nameserver 127.0.0.1" > /etc/resolv.conf
            green "/etc/resolv.conf 已设置"
            ;;
        *) red "未识别的 DNS 后端"; return 1 ;;
    esac
    return 0
}

restore_dns_config() {
    local backup_dir="${1:-$MH_DNS_BACKUP_DIR}"
    local backend
    backend=$(detect_dns_backend)

    case "$backend" in
        dnsmasq-uci)
            [ ! -f "$backup_dir/dnsmasq-uci.bak" ] && { red "无备份"; return 1; }
            uci set dhcp.@dnsmasq[0].noresolv='0'
            uci set dhcp.@dnsmasq[0].rebind_protection='1'
            uci -q delete dhcp.@dnsmasq[0].server
            while IFS= read -r line; do
                case "$line" in
                    *".server="*)
                        local val
                        val=$(echo "$line" | sed -E "s/^[^=]+=//;s/^'//;s/'$//")
                        [ -n "$val" ] && uci add_list dhcp.@dnsmasq[0].server="$val"
                        ;;
                    *".noresolv="*)
                        local val
                        val=$(echo "$line" | sed -E "s/^[^=]+=//;s/^'//;s/'$//")
                        [ -n "$val" ] && uci set dhcp.@dnsmasq[0].noresolv="$val"
                        ;;
                    *".rebind_protection="*)
                        local val
                        val=$(echo "$line" | sed -E "s/^[^=]+=//;s/^'//;s/'$//")
                        [ -n "$val" ] && uci set dhcp.@dnsmasq[0].rebind_protection="$val"
                        ;;
                esac
            done < "$backup_dir/dnsmasq-uci.bak"
            uci commit dhcp
            /etc/init.d/dnsmasq restart >/dev/null 2>&1
            green "dnsmasq(uci) 已还原"
            ;;
        systemd-resolved)
            rm -f /etc/systemd/resolved.conf.d/proxy-manager.conf
            [ -f "$backup_dir/resolved.conf.bak" ] && cp "$backup_dir/resolved.conf.bak" /etc/systemd/resolved.conf
            systemctl restart systemd-resolved
            green "systemd-resolved 已还原"
            ;;
        dnsmasq)
            rm -f /etc/dnsmasq.d/proxy-manager-forward.conf
            [ -f "$backup_dir/dnsmasq.conf.bak" ] && cp "$backup_dir/dnsmasq.conf.bak" /etc/dnsmasq.conf
            systemctl restart dnsmasq >/dev/null 2>&1
            green "dnsmasq 已还原"
            ;;
        resolv.conf)
            [ -f "$backup_dir/resolv.conf.bak" ] && cp "$backup_dir/resolv.conf.bak" /etc/resolv.conf
            green "resolv.conf 已还原"
            ;;
        *) red "无法识别后端"; return 1 ;;
    esac
    return 0
}

detect_dns_forward_status() {
    local backend
    backend=$(detect_dns_backend)
    case "$backend" in
        dnsmasq-uci)
            local s
            s=$(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null)
            echo "$s" | grep -oE "127\.0\.0\.1#[0-9]+" | head -n 1
            ;;
        systemd-resolved)
            [ -f /etc/systemd/resolved.conf.d/proxy-manager.conf ] && \
                grep -oE "127\.0\.0\.1:[0-9]+" /etc/systemd/resolved.conf.d/proxy-manager.conf | head -n 1
            ;;
        dnsmasq)
            [ -f /etc/dnsmasq.d/proxy-manager-forward.conf ] && \
                grep -oE "127\.0\.0\.1#[0-9]+" /etc/dnsmasq.d/proxy-manager-forward.conf | head -n 1
            ;;
        resolv.conf)
            grep -E "^nameserver[[:space:]]+127\.0\.0\.1" /etc/resolv.conf 2>/dev/null | head -n 1 | awk '{print $2}'
            ;;
    esac
}

auto_configure_dns_forward_mihomo() {
    log "一键配置 Mihomo DNS 转发..."
    [ ! -f "$MH_CONFIG_FILE" ] && { red "Mihomo 配置不存在"; return 1; }

    local backend
    backend=$(detect_dns_backend)
    [ "$backend" = "unknown" ] && { red "无法识别 DNS 后端"; return 1; }
    log "系统 DNS 后端: $backend"

    local mh_port target_port
    mh_port=$(parse_mihomo_dns_port)

    if ! check_mihomo_dns_enabled; then
        yellow "配置未启用 DNS，将注入 dns 段（端口 $MH_DEFAULT_DNS_PORT）"
        printf "继续？(Y/n): "; read -r c
        case "$c" in n|N) return 0 ;; esac
        inject_mihomo_dns_block "$MH_DEFAULT_DNS_PORT" || return 1
        target_port="$MH_DEFAULT_DNS_PORT"
    elif [ "$mh_port" = "53" ] && [ "$backend" != "resolv.conf" ]; then
        yellow "Mihomo 监听 53 会冲突，改为 $MH_DEFAULT_DNS_PORT"
        printf "继续？(Y/n): "; read -r c
        case "$c" in n|N) return 0 ;; esac
        update_mihomo_dns_port "$MH_DEFAULT_DNS_PORT" || return 1
        target_port="$MH_DEFAULT_DNS_PORT"
    else
        target_port="$mh_port"
        green "使用现有端口: $target_port"
    fi

    manage_service_internal "mihomo" "restart"
    sleep 2

    apply_dns_forward "$target_port" "$MH_DNS_BACKUP_DIR" || return 1

    green "===== DNS 转发配置完成 ====="
    green "Mihomo DNS 端口: $target_port | 后端: $backend"

    yellow ""
    yellow "→ 3 秒后自动运行智能自愈诊断..."
    sleep 3
    smart_autoheal "mihomo"
    return 0
}

auto_configure_dns_forward_singbox() {
    log "一键配置 Sing-box DNS 转发..."
    [ ! -f "$SB_CONFIG_FILE" ] && { red "Sing-box 配置不存在"; return 1; }

    local backend
    backend=$(detect_dns_backend)
    [ "$backend" = "unknown" ] && { red "无法识别 DNS 后端"; return 1; }
    log "系统 DNS 后端: $backend"

    yellow "Sing-box 的 DNS 通常由 TUN 模式内部处理（dns-hijack）"
    yellow "如果 TUN 已启用，通常无需额外的系统级 DNS 转发"
    printf "仍要将系统 DNS 转发到 Sing-box 的 mixed 入站（端口 2080）？(y/N): "
    read -r c
    case "$c" in y|Y) ;; *) yellow "已取消"; return 0 ;; esac

    yellow "注意: Sing-box 通常使用 TUN dns-hijack，不建议再做系统 DNS 转发"
    yellow "详见: https://sing-box.sagernet.org/configuration/dns/"
    return 0
}

test_dns_resolution() {
    log "测试 DNS 解析..."
    local test_domain="www.google.com"

    yellow "--- 通过 127.0.0.1 查询 $test_domain ---"
    if command -v dig >/dev/null 2>&1; then
        dig @127.0.0.1 "$test_domain" +short +time=3 +tries=1 2>&1 | head -n 5
    elif command -v nslookup >/dev/null 2>&1; then
        nslookup "$test_domain" 127.0.0.1 2>&1 | head -n 15
    elif command -v host >/dev/null 2>&1; then
        host "$test_domain" 127.0.0.1 2>&1 | head -n 5
    else
        red "无 DNS 测试工具"
    fi

    yellow ""
    yellow "判断标准："
    yellow "  198.18.x.x  → fake-ip 生效 ✓"
    yellow "  真实海外 IP → redir-host / TUN 生效 ✓"
    yellow "  114/8.8.8.8 → 未生效 ✗"
    return 0
}

test_internet_connectivity() {
    local silent="${1:-0}"
    local pass=0

    [ "$silent" = "0" ] && log "联网测试..."

    local code1
    code1=$(probe_url "http://www.baidu.com" 2>/dev/null)
    if [ "$code1" = "200" ] || [ "$code1" = "301" ] || [ "$code1" = "302" ]; then
        [ "$silent" = "0" ] && green "  [1/3] 百度: OK ($code1)"
        pass=$((pass + 1))
    else
        [ "$silent" = "0" ] && red "  [1/3] 百度: FAIL (${code1:-无响应})"
    fi

    local code2
    code2=$(probe_url "http://www.gstatic.com/generate_204" 2>/dev/null)
    if [ "$code2" = "204" ] || [ "$code2" = "200" ]; then
        [ "$silent" = "0" ] && green "  [2/3] Google: OK ($code2)"
        pass=$((pass + 1))
    else
        [ "$silent" = "0" ] && red "  [2/3] Google: FAIL (${code2:-无响应})"
    fi

    local dns_result=""
    if command -v dig >/dev/null 2>&1; then
        dns_result=$(dig @127.0.0.1 www.baidu.com +short +time=3 +tries=1 2>/dev/null | head -n 1)
    elif command -v nslookup >/dev/null 2>&1; then
        dns_result=$(nslookup www.baidu.com 127.0.0.1 2>/dev/null | grep -E "Address" | grep -v "#53" | grep -v "127.0.0.1" | head -n 1 | awk '{print $NF}')
    elif command -v host >/dev/null 2>&1; then
        dns_result=$(host www.baidu.com 127.0.0.1 2>/dev/null | grep "has address" | head -n 1 | awk '{print $NF}')
    fi
    if [ -n "$dns_result" ] && echo "$dns_result" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        [ "$silent" = "0" ] && green "  [3/3] DNS: OK ($dns_result)"
        pass=$((pass + 1))
    else
        [ "$silent" = "0" ] && red "  [3/3] DNS: FAIL"
    fi

    [ "$silent" = "0" ] && log "结果: $pass/3"
    [ "$pass" -ge 2 ] && return 0 || return 1
}

apply_autoheal_tweaks_mihomo() {
    local cfg="$MH_CONFIG_FILE"
    [ ! -f "$cfg" ] && { red "配置文件不存在"; return 1; }

    cp "$cfg" "$MH_AUTOHEAL_BACKUP"
    green "已备份原配置到 $MH_AUTOHEAL_BACKUP"

    local tmpfile status_file
    tmpfile=$(mktemp)
    status_file=$(mktemp)

    awk '
        BEGIN { in_tun=0; in_dns=0; ar=0; sr=0; rr=0 }
        /^tun:/  { in_tun=1; in_dns=0; print; next }
        /^dns:/  { in_dns=1; in_tun=0; print; next }
        /^[a-zA-Z]/ && !/^tun:/ && !/^dns:/ { in_tun=0; in_dns=0 }
        in_tun && /^[[:space:]]+auto-redirect:/ { sub(/auto-redirect:.*/, "auto-redirect: true"); ar=1 }
        in_tun && /^[[:space:]]+strict-route:/  { sub(/strict-route:.*/, "strict-route: true"); sr=1 }
        in_dns && /^[[:space:]]+respect-rules:/ { sub(/respect-rules:.*/, "respect-rules: false"); rr=1 }
        { print }
        END { print "AR=" ar ",SR=" sr ",RR=" rr > "'"$status_file"'" }
    ' "$cfg" > "$tmpfile"
    mv "$tmpfile" "$cfg"

    local status
    status=$(cat "$status_file" 2>/dev/null)
    rm -f "$status_file"

    local ar sr rr
    ar=$(echo "$status" | grep -oE "AR=[01]" | cut -d= -f2)
    sr=$(echo "$status" | grep -oE "SR=[01]" | cut -d= -f2)
    rr=$(echo "$status" | grep -oE "RR=[01]" | cut -d= -f2)

    if [ "${ar:-0}" = "0" ] && grep -qE '^tun:' "$cfg"; then
        yellow "tun.auto-redirect 不存在，注入..."
        sed -i '/^tun:/a\  auto-redirect: true' "$cfg"
    fi
    if [ "${sr:-0}" = "0" ] && grep -qE '^tun:' "$cfg"; then
        yellow "tun.strict-route 不存在，注入..."
        sed -i '/^tun:/a\  strict-route: true' "$cfg"
    fi
    if [ "${rr:-0}" = "0" ] && grep -qE '^dns:' "$cfg"; then
        yellow "dns.respect-rules 不存在，注入..."
        sed -i '/^dns:/a\  respect-rules: false' "$cfg"
    fi

    green "已应用 Mihomo 自愈参数："
    green "  tun.auto-redirect: true"
    green "  tun.strict-route:  true"
    green "  dns.respect-rules: false"
    return 0
}

apply_autoheal_tweaks_singbox() {
    local cfg="$SB_CONFIG_FILE"
    [ ! -f "$cfg" ] && { red "配置文件不存在"; return 1; }

    cp "$cfg" "$SB_AUTOHEAL_BACKUP"
    green "已备份原配置到 $SB_AUTOHEAL_BACKUP"

    if ! jq empty "$cfg" >/dev/null 2>&1; then
        red "配置文件不是有效 JSON，无法自动修复"
        return 1
    fi

    local tmpfile
    tmpfile=$(mktemp)

    jq '
        .inbounds |= map(
            if .type == "tun" then
                . + {"strict_route": true, "auto_route": true, "endpoint_independent_nat": true}
            else . end
        )
        | .route |= (. // {}) + {"auto_detect_interface": true}
    ' "$cfg" > "$tmpfile" 2>/dev/null

    if [ -s "$tmpfile" ] && jq empty "$tmpfile" >/dev/null 2>&1; then
        mv "$tmpfile" "$cfg"
        green "已应用 Sing-box 自愈参数："
        green "  inbounds.tun.strict_route: true"
        green "  inbounds.tun.auto_route: true"
        green "  inbounds.tun.endpoint_independent_nat: true"
        green "  route.auto_detect_interface: true"
        return 0
    else
        rm -f "$tmpfile"
        red "自愈参数修改失败"
        return 1
    fi
}

restore_autoheal_backup() {
    local service_type="$1"
    local backup_file config_file
    case "$service_type" in
        singbox) backup_file="$SB_AUTOHEAL_BACKUP"; config_file="$SB_CONFIG_FILE" ;;
        mihomo)  backup_file="$MH_AUTOHEAL_BACKUP"; config_file="$MH_CONFIG_FILE" ;;
        *) return 1 ;;
    esac

    if [ ! -f "$backup_file" ]; then
        yellow "未找到自愈备份: $backup_file"
        return 1
    fi
    cp "$backup_file" "$config_file"
    green "已从备份还原原配置"
    return 0
}

show_diagnostic_report() {
    local service_type="${1:-mihomo}"
    local service_name bin_path config_file
    case "$service_type" in
        singbox) service_name="sing-box"; bin_path="$SB_BIN_PATH"; config_file="$SB_CONFIG_FILE" ;;
        mihomo)  service_name="mihomo"; bin_path="$MH_BIN_PATH"; config_file="$MH_CONFIG_FILE" ;;
        *) red "无效"; return 1 ;;
    esac

    yellow "═══════════════════════════════════════"
    yellow "   ${service_name} 完 整 诊 断 报 告"
    yellow "═══════════════════════════════════════"

    printf "\n%b[1] 进程状态%b\n" "$GREEN" "$NC"
    if pgrep -a "$service_name" 2>/dev/null; then
        green "  ✓ 进程运行中"
    else
        red "  ✗ 进程未运行"
    fi

    printf "\n%b[2] 端口监听%b\n" "$GREEN" "$NC"
    if command -v ss >/dev/null 2>&1; then
        ss -lntup 2>/dev/null | grep -E "$service_name|:7874|:7890|:9090|:2080|:53" | head -10 || red "  未监听关键端口"
    elif command -v netstat >/dev/null 2>&1; then
        netstat -lntup 2>/dev/null | grep -E "$service_name|:7874|:7890|:9090|:2080|:53" | head -10 || red "  未监听关键端口"
    fi

    printf "\n%b[3] TUN 网卡%b\n" "$GREEN" "$NC"
    if ip addr show tun0 2>/dev/null | head -3; then
        green "  ✓ TUN 已创建"
    else
        red "  ✗ TUN 未创建"
    fi

    printf "\n%b[4] TUN 路由%b\n" "$GREEN" "$NC"
    ip route 2>/dev/null | grep -E "tun0|198\.18|172\.19" | head -5 || yellow "  无 TUN 路由"

    printf "\n%b[5] DNS 转发%b\n" "$GREEN" "$NC"
    printf "  后端: %s\n" "$(detect_dns_backend)"
    printf "  转发: %s\n" "$(detect_dns_forward_status)"

    printf "\n%b[6] 配置关键字段%b\n" "$GREEN" "$NC"
    if [ -f "$config_file" ]; then
        if [ "$service_type" = "mihomo" ]; then
            printf "  tun.auto-redirect: %s\n" "$(get_mihomo_yaml_field tun auto-redirect)"
            printf "  tun.strict-route:  %s\n" "$(get_mihomo_yaml_field tun strict-route)"
            printf "  tun.stack:         %s\n" "$(get_mihomo_yaml_field tun stack)"
            printf "  tun.auto-route:    %s\n" "$(get_mihomo_yaml_field tun auto-route)"
            printf "  dns.respect-rules: %s\n" "$(get_mihomo_yaml_field dns respect-rules)"
            printf "  dns.enhanced-mode: %s\n" "$(get_mihomo_yaml_field dns enhanced-mode)"
            printf "  dns.listen:        %s\n" "$(parse_mihomo_dns_port)"
        else
            local tun_stack tun_auto_route tun_strict_route
            tun_stack=$(jq -r '.inbounds[]? | select(.type=="tun") | .stack // "empty"' "$config_file" 2>/dev/null | head -1)
            tun_auto_route=$(jq -r '.inbounds[]? | select(.type=="tun") | .auto_route // "empty"' "$config_file" 2>/dev/null | head -1)
            tun_strict_route=$(jq -r '.inbounds[]? | select(.type=="tun") | .strict_route // "empty"' "$config_file" 2>/dev/null | head -1)
            printf "  tun.stack:              %s\n" "${tun_stack:-未设置}"
            printf "  tun.auto_route:         %s\n" "${tun_auto_route:-未设置}"
            printf "  tun.strict_route:       %s\n" "${tun_strict_route:-未设置}"
            printf "  route.auto_detect_interface: %s\n" "$(jq -r '.route.auto_detect_interface // "empty"' "$config_file" 2>/dev/null)"
        fi
    fi

    printf "\n%b[7] 日志（最近20行）%b\n" "$GREEN" "$NC"
    if [ "$SYSTEM_TYPE" = "openwrt" ]; then
        logread -e "$service_name" 2>/dev/null | tail -20 || yellow "  无日志"
    else
        journalctl -u "$service_name" -n 20 --no-pager 2>/dev/null || yellow "  无日志"
    fi

    yellow ""
    yellow "═══════════════════════════════════════"
}

smart_autoheal() {
    local service_type="${1:-mihomo}"
    local service_name config_file backup_file apply_func
    case "$service_type" in
        singbox)
            service_name="sing-box"; config_file="$SB_CONFIG_FILE"
            backup_file="$SB_AUTOHEAL_BACKUP"
            apply_func="apply_autoheal_tweaks_singbox"
            ;;
        mihomo)
            service_name="mihomo"; config_file="$MH_CONFIG_FILE"
            backup_file="$MH_AUTOHEAL_BACKUP"
            apply_func="apply_autoheal_tweaks_mihomo"
            ;;
        *) red "无效服务类型"; return 1 ;;
    esac

    log "===== 启动 ${service_name} 智能自愈 ====="

    if [ ! -f "$config_file" ]; then
        red "配置文件不存在: $config_file"
        return 1
    fi

    if ! pgrep "$service_name" >/dev/null 2>&1; then
        yellow "${service_name} 未运行，尝试启动..."
        manage_service_internal "$service_type" "start"
        sleep 3
    fi

    log "步骤 1/3: 初次联网测试"
    sleep "$AUTOHEAL_WAIT_INITIAL"
    if test_internet_connectivity 0; then
        green "═══════════════════════════════════════"
        green "  ✅ 网络正常，无需修改配置"
        green "═══════════════════════════════════════"
        return 0
    fi

    yellow "═══════════════════════════════════════"
    yellow "  ⚠  网络异常，启动自愈修复"
    yellow "═══════════════════════════════════════"

    log "步骤 2/3: 应用自愈参数并重启"
    $apply_func || { red "参数修改失败"; return 1; }
    manage_service_internal "$service_type" "restart"
    sleep "$AUTOHEAL_WAIT_RESTART"

    log "步骤 3/3: 再次联网测试"
    if test_internet_connectivity 0; then
        green "═══════════════════════════════════════"
        green "  ✅ ${service_name} 自愈成功！"
        green "  备份文件: $backup_file"
        green "═══════════════════════════════════════"
        return 0
    fi

    red "═══════════════════════════════════════"
    red "  ❌ 自愈失败，还原原配置"
    red "═══════════════════════════════════════"
    restore_autoheal_backup "$service_type"
    manage_service_internal "$service_type" "restart"
    sleep 3

    show_diagnostic_report "$service_type"

    yellow ""
    yellow "请手动检查："
    yellow "  1) 订阅节点是否可用"
    yellow "  2) TUN 内核栈是否兼容"
    yellow "  3) DNS 配置是否循环"
    yellow "  4) 日志: /var/log/proxy-manager.log"
    return 1
}

manage_dns_forwarding_menu() {
    local service_type="${1:-mihomo}"
    local service_name config_file
    case "$service_type" in
        singbox) service_name="Sing-box"; config_file="$SB_CONFIG_FILE" ;;
        mihomo)  service_name="Mihomo"; config_file="$MH_CONFIG_FILE" ;;
        *) return 1 ;;
    esac

    while true; do
        clear
        local backend current_fwd
        backend=$(detect_dns_backend)
        current_fwd=$(detect_dns_forward_status)

        printf "\n%b=== %s DNS 转发管理 ===%b\n" "$GREEN" "$service_name" "$NC"
        printf "配置文件      : %s\n" "$config_file"
        printf "系统 DNS 后端 : %s\n" "$backend"
        printf "当前转发状态  : %s\n" "${current_fwd:-未转发}"

        if [ "$service_type" = "mihomo" ]; then
            local mh_port dns_enabled
            mh_port=$(parse_mihomo_dns_port)
            check_mihomo_dns_enabled && dns_enabled="已启用" || dns_enabled="未启用"
            printf "Mihomo DNS 状态: %s (端口: %s)\n" "$dns_enabled" "${mh_port:-未设置}"
        else
            local sb_dns
            check_singbox_dns_configured && sb_dns="已配置" || sb_dns="未配置"
            printf "Sing-box DNS  : %s\n" "$sb_dns"
        fi
        printf "%b============================%b\n\n" "$GREEN" "$NC"

        printf " 1) %b一键自动配置%b（含自愈）\n" "$GREEN" "$NC"
        if [ "$service_type" = "mihomo" ]; then
            printf " 2) 仅修改 Mihomo DNS 端口\n"
            printf " 3) 仅配置系统 DNS 转发\n"
            printf " 4) 注入完整 dns 段\n"
        fi
        printf " 5) %b还原系统 DNS 原配置%b\n" "$YELLOW" "$NC"
        printf " 6) 测试 DNS 解析\n"
        printf " 7) %b智能自愈诊断%b\n" "$GREEN" "$NC"
        printf " 8) 显示完整诊断报告\n"
        printf " 9) %b还原自愈修改%b\n" "$YELLOW" "$NC"
        printf " q) 返回\n"
        printf "%b============================%b\n" "$GREEN" "$NC"
        read -r -p "选项: " choice

        case "$choice" in
            1)
                if [ "$service_type" = "mihomo" ]; then
                    auto_configure_dns_forward_mihomo
                else
                    auto_configure_dns_forward_singbox
                fi
                ;;
            2)
                if [ "$service_type" = "mihomo" ]; then
                    printf "请输入端口（推荐 %s）: " "$MH_DEFAULT_DNS_PORT"
                    read -r np; [ -z "$np" ] && np="$MH_DEFAULT_DNS_PORT"
                    if echo "$np" | grep -qE '^[0-9]+$'; then
                        update_mihomo_dns_port "$np"
                        manage_service_internal "mihomo" "restart"
                    else red "无效"; fi
                else
                    yellow "Sing-box 不适用此选项"
                fi
                ;;
            3)
                if [ "$service_type" = "mihomo" ]; then
                    local mp; mp=$(parse_mihomo_dns_port)
                    [ -z "$mp" ] && red "无法解析端口" || apply_dns_forward "$mp" "$MH_DNS_BACKUP_DIR"
                else
                    yellow "Sing-box 不适用此选项"
                fi
                ;;
            4)
                if [ "$service_type" = "mihomo" ]; then
                    printf "请输入端口（推荐 %s）: " "$MH_DEFAULT_DNS_PORT"
                    read -r np; [ -z "$np" ] && np="$MH_DEFAULT_DNS_PORT"
                    inject_mihomo_dns_block "$np"
                    manage_service_internal "mihomo" "restart"
                else
                    yellow "Sing-box 不适用此选项"
                fi
                ;;
            5)
                local backup_dir
                [ "$service_type" = "mihomo" ] && backup_dir="$MH_DNS_BACKUP_DIR" || backup_dir="$SB_DNS_BACKUP_DIR"
                restore_dns_config "$backup_dir"
                ;;
            6) test_dns_resolution ;;
            7) smart_autoheal "$service_type" ;;
            8) show_diagnostic_report "$service_type" ;;
            9) restore_autoheal_backup "$service_type" && manage_service_internal "$service_type" "restart" ;;
            q|Q) return 0 ;;
            *) red "无效选项" ;;
        esac
        read -r -p "按 [Enter] 键继续..."
    done
}

validate_config_internal() {
    local service_type="$1"
    local config_file_override="${2:-}"
    local service_name bin_path config_path

    case "$service_type" in
        singbox) service_name="Sing-box"; bin_path="$SB_BIN_PATH"; config_path="$SB_CONFIG_FILE" ;;
        mihomo)  service_name="Mihomo"; bin_path="$MH_BIN_PATH"; config_path="$MH_BASE_DIR" ;;
        *) red "无效服务类型"; return 1 ;;
    esac

    [ ! -f "$bin_path" ] && { red "${service_name} 未安装"; return 1; }

    local validation_output exit_code temp_dir_created=0

    if [ "$service_type" = "singbox" ]; then
        local file_to_check="${config_file_override:-$config_path}"
        [ ! -f "$file_to_check" ] && { red "配置不存在"; return 1; }
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
            red "配置不存在"
            [ "$temp_dir_created" -eq 1 ] && rm -rf "$dir_to_check"
            return 1
        }
        validation_output=$("$bin_path" -d "$dir_to_check" -t 2>&1)
        exit_code=$?
        [ "$temp_dir_created" -eq 1 ] && rm -rf "$dir_to_check"
    fi

    if [ "$exit_code" -eq 0 ]; then
        [ -z "$config_file_override" ] && green "✅ ${service_name} 配置验证通过！"

        if [ -z "$config_file_override" ]; then
            if [ "$service_type" = "mihomo" ]; then
                local mh_port backend fwd
                mh_port=$(parse_mihomo_dns_port)
                backend=$(detect_dns_backend)
                printf "\n"
                if ! check_mihomo_dns_enabled; then
                    yellow "⚠  配置未启用 dns 段"
                elif [ "$mh_port" = "53" ] && [ "$backend" != "resolv.conf" ] && [ "$backend" != "unknown" ]; then
                    red "⚠  Mihomo DNS 监听 53 会与系统冲突"
                else
                    green "✓  Mihomo DNS 端口: $mh_port"
                    fwd=$(detect_dns_forward_status)
                    [ -z "$fwd" ] && yellow "⚠  系统未转发到 Mihomo" || green "✓  系统已转发: $fwd"
                fi

                local ar sr rr
                ar=$(get_mihomo_yaml_field tun auto-redirect)
                sr=$(get_mihomo_yaml_field tun strict-route)
                rr=$(get_mihomo_yaml_field dns respect-rules)
                printf "\n%b关键自愈参数:%b\n" "$GREEN" "$NC"
                printf "  tun.auto-redirect: %s %s\n" "${ar:-未设置}" "$([ "$ar" = "true" ] && echo "✓" || echo "⚠")"
                printf "  tun.strict-route:  %s %s\n" "${sr:-未设置}" "$([ "$sr" = "true" ] && echo "✓" || echo "⚠")"
                printf "  dns.respect-rules: %s %s\n" "${rr:-未设置}" "$([ "$rr" = "false" ] && echo "✓" || echo "⚠")"
                if [ "$ar" != "true" ] || [ "$sr" != "true" ] || [ "$rr" != "false" ]; then
                    yellow "\n⚠  参数与推荐值不符，若网络异常可运行智能自愈"
                fi
            else
                printf "\n%b关键 TUN 参数:%b\n" "$GREEN" "$NC"
                local tun_ar tun_sr
                tun_ar=$(jq -r '.inbounds[]? | select(.type=="tun") | .auto_route // "未设置"' "$config_path" 2>/dev/null | head -1)
                tun_sr=$(jq -r '.inbounds[]? | select(.type=="tun") | .strict_route // "未设置"' "$config_path" 2>/dev/null | head -1)
                printf "  tun.auto_route:   %s %s\n" "$tun_ar" "$([ "$tun_ar" = "true" ] && echo "✓" || echo "⚠")"
                printf "  tun.strict_route: %s %s\n" "$tun_sr" "$([ "$tun_sr" = "true" ] && echo "✓" || echo "⚠")"
                if [ "$tun_ar" != "true" ] || [ "$tun_sr" != "true" ]; then
                    yellow "\n⚠  参数与推荐值不符，若网络异常可运行智能自愈"
                fi
            fi
        fi
        return 0
    else
        red "❌ ${service_name} 配置验证失败！"
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
        *) red "无效服务类型"; return 1 ;;
    esac

    [ ! -f "$bin_path" ] && { yellow "${service_name} 未安装"; return 1; }

    log "对 ${service_name} 执行: $action"
    if [ "$SYSTEM_TYPE" = "openwrt" ]; then
        local init_script="/etc/init.d/$service_name"
        if [ -f "$init_script" ]; then
            "$init_script" "$action"
        else
            yellow "服务脚本不存在"
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
        *) return 1 ;;
    esac

    if [ -z "$action" ]; then
        clear
        printf "\n%b=== %s 自启动 ===%b\n" "$GREEN" "$service_name" "$NC"
        printf "  1) 启用\n  2) 禁用\n  q) 返回\n"
        read -r -p "选项: " choice
        case "$choice" in
            1) manage_autostart_internal "$service_type" "enable" ;;
            2) manage_autostart_internal "$service_type" "disable" ;;
        esac
        return 0
    fi

    if [ "$SYSTEM_TYPE" = "openwrt" ]; then
        local init_script="/etc/init.d/$service_name"
        [ ! -f "$init_script" ] && return 1
        case "$action" in
            enable)  "$init_script" enable  >/dev/null 2>&1; green "${service_name} 已启用自启" ;;
            disable) "$init_script" disable >/dev/null 2>&1; yellow "${service_name} 已禁用自启" ;;
        esac
    else
        case "$action" in
            enable)  systemctl enable  "$service_name" >/dev/null 2>&1; green "${service_name} 已启用自启" ;;
            disable) systemctl disable "$service_name" >/dev/null 2>&1; yellow "${service_name} 已禁用自启" ;;
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
    esac
    clear
    yellow "--- ${service_name} 服务日志（最近50行）---"
    if [ "$SYSTEM_TYPE" = "openwrt" ]; then
        logread -e "$service_name" 2>/dev/null | tail -n 50 || yellow "无法获取"
    else
        journalctl -u "$service_name" -n 50 --no-pager 2>/dev/null || yellow "无法获取"
    fi
    yellow "--- 脚本日志（最近30行）---"
    tail -n 30 "$LOG_FILE" 2>/dev/null || yellow "暂无"
    return 0
}

setup_cron_job_internal() {
    local service_type="$1"
    local interval="$2"
    local service_name cron_entry
    case "$service_type" in
        singbox) service_name="Sing-box" ;;
        mihomo)  service_name="Mihomo"   ;;
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

    (crontab -l 2>/dev/null | grep -v "$cron_job_id"; echo "# $cron_job_id"; echo "$cron_entry") | crontab -
    [ "$SYSTEM_TYPE" = "openwrt" ] && /etc/init.d/cron restart >/dev/null 2>&1 || true
    green "${service_name} 自动更新已设置（${interval}分钟）"
    return 0
}

disable_scheduled_update_internal() {
    local cron_job_id="${1}_proxy_update"
    (crontab -l 2>/dev/null | grep -v "$cron_job_id") | crontab -
    green "${1} 自动更新已禁用"
}

manage_scheduled_update_menu() {
    local service_type="$1"
    local service_name env_file
    case "$service_type" in
        singbox) service_name="Sing-box"; env_file="$SB_ENV_FILE" ;;
        mihomo)  service_name="Mihomo"; env_file="$MH_ENV_FILE" ;;
    esac

    if ! load_service_env "$env_file" 2>/dev/null; then
        red "请先设置订阅链接"
        return 1
    fi

    local current_interval="${CRON_INTERVAL:-0}"
    clear
    printf "\n%b=== %s 自动更新 ===%b\n" "$GREEN" "$service_name" "$NC"
    [ "$current_interval" -eq 0 ] && printf "状态: %b已禁用%b\n" "$RED" "$NC" || printf "状态: %b已启用%b (每 %s 分钟)\n" "$GREEN" "$NC" "$current_interval"
    printf "  1) 设置间隔\n  2) 禁用\n  q) 返回\n"
    read -r -p "选项: " choice
    case "$choice" in
        1)
            printf "请输入间隔（分钟，0=禁用）: "
            read -r ni
            echo "$ni" | grep -qE '^[0-9]+$' || { red "无效"; return 1; }
            update_env_field "$env_file" "CRON_INTERVAL" "$ni"
            [ "$ni" -gt 0 ] && setup_cron_job_internal "$service_type" "$ni" || disable_scheduled_update_internal "$service_type"
            ;;
        2)
            update_env_field "$env_file" "CRON_INTERVAL" "0"
            disable_scheduled_update_internal "$service_type"
            ;;
    esac
    return 0
}

view_version_internal() {
    local service_type="$1"
    local bin_path version_cmd service_name_display
    case "$service_type" in
        singbox) bin_path="$SB_BIN_PATH"; version_cmd="version"; service_name_display="Sing-box" ;;
        mihomo)  bin_path="$MH_BIN_PATH"; version_cmd="-v"; service_name_display="Mihomo" ;;
    esac
    [ ! -x "$bin_path" ] && { red "$service_name_display 未安装"; return 1; }
    green "$service_name_display 版本 (路径: $bin_path):"
    "$bin_path" $version_cmd 2>&1
    return 0
}

env_health_check() {
    local service_type="${1:-mihomo}"
    ENV_INSTALLED=0
    ENV_CONFIG_EXISTS=0
    ENV_CONFIG_VALID=0
    ENV_SERVICE_RUNNING=0
    ENV_SERVICE_ENABLED=0
    ENV_DNS_CONFIGURED=0
    ENV_NETWORK_OK=0
    ENV_LOCAL_CONFIGS=""

    local bin_path config_file service_name config_check_cmd
    local config_ext
    case "$service_type" in
        singbox)
            bin_path="$SB_BIN_PATH"; config_file="$SB_CONFIG_FILE"
            service_name="$SB_SERVICE_NAME"
            config_ext="json"
            ;;
        mihomo)
            bin_path="$MH_BIN_PATH"; config_file="$MH_CONFIG_FILE"
            service_name="$MH_SERVICE_NAME"
            config_ext="yaml yml"
            ;;
    esac

    [ -x "$bin_path" ] && ENV_INSTALLED=1
    [ -f "$config_file" ] && ENV_CONFIG_EXISTS=1

    if [ "$ENV_CONFIG_EXISTS" = "1" ] && [ "$ENV_INSTALLED" = "1" ]; then
        if [ "$service_type" = "singbox" ]; then
            "$bin_path" check -c "$config_file" >/dev/null 2>&1 && ENV_CONFIG_VALID=1
        else
            "$bin_path" -d "$MH_BASE_DIR" -t >/dev/null 2>&1 && ENV_CONFIG_VALID=1
        fi
    fi

    pgrep "$service_name" >/dev/null 2>&1 && ENV_SERVICE_RUNNING=1

    if [ "$SYSTEM_TYPE" = "openwrt" ]; then
        [ -L "/etc/rc.d/S95${service_name}" ] && ENV_SERVICE_ENABLED=1
    else
        systemctl is-enabled "$service_name" >/dev/null 2>&1 && ENV_SERVICE_ENABLED=1
    fi

    [ -n "$(detect_dns_forward_status)" ] && ENV_DNS_CONFIGURED=1

    ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1 && ENV_NETWORK_OK=1

    local script_dir
    script_dir=$(dirname "$SCRIPT_PATH")
    local pwd_configs script_configs
    if [ "$service_type" = "singbox" ]; then
        pwd_configs=$(find "$(pwd)" -maxdepth 1 -type f -name "*.json" 2>/dev/null)
        [ "$script_dir" != "$(pwd)" ] && script_configs=$(find "$script_dir" -maxdepth 1 -type f -name "*.json" 2>/dev/null)
    else
        pwd_configs=$(find "$(pwd)" -maxdepth 1 -type f \( -name "*.yaml" -o -name "*.yml" \) 2>/dev/null)
        [ "$script_dir" != "$(pwd)" ] && script_configs=$(find "$script_dir" -maxdepth 1 -type f \( -name "*.yaml" -o -name "*.yml" \) 2>/dev/null)
    fi
    ENV_LOCAL_CONFIGS=$(printf "%s\n%s" "$pwd_configs" "$script_configs" | sort -u | grep -v '^$')
}

import_and_validate() {
    local service_type="$1"
    local src="$2"
    [ -z "$src" ] || [ ! -f "$src" ] && { red "源文件无效: $src"; return 1; }

    local base_dir config_file bin_path check_key
    case "$service_type" in
        singbox)
            base_dir="$SB_BASE_DIR"; config_file="$SB_CONFIG_FILE"
            bin_path="$SB_BIN_PATH"; check_key="inbounds"
            ;;
        mihomo)
            base_dir="$MH_BASE_DIR"; config_file="$MH_CONFIG_FILE"
            bin_path="$MH_BIN_PATH"; check_key="proxies"
            ;;
        *) return 1 ;;
    esac

    mkdir -p "$base_dir"

    if [ -f "$config_file" ]; then
        cp "$config_file" "${config_file}.import.bak"
        yellow "已备份原配置到 ${config_file}.import.bak"
    fi

    if [ "$service_type" = "singbox" ]; then
        if ! jq empty "$src" >/dev/null 2>&1; then
            red "文件不是有效的 JSON"
            return 1
        fi
        if ! jq -e ".${check_key}" "$src" >/dev/null 2>&1; then
            red "配置不含 ${check_key} 字段"
            return 1
        fi
    else
        if ! grep -q "${check_key}:" "$src" 2>/dev/null; then
            red "配置不含 ${check_key} 字段"
            return 1
        fi
    fi

    cp "$src" "$config_file"
    green "配置已复制到 $config_file"

    if [ -x "$bin_path" ]; then
        log "验证配置..."
        local vo
        if [ "$service_type" = "singbox" ]; then
            vo=$("$bin_path" check -c "$config_file" 2>&1)
        else
            vo=$("$bin_path" -d "$base_dir" -t 2>&1)
        fi
        if [ $? -eq 0 ]; then
            green "✅ 配置验证通过"
            return 0
        else
            red "❌ 配置验证失败"
            yellow "--- 错误详情 ---"
            printf "%s\n" "$vo"
            yellow "----------------"
            printf "是否仍要保留此配置？(y/N): "
            read -r c
            case "$c" in
                y|Y) yellow "已保留"; return 0 ;;
                *)
                    if [ -f "${config_file}.import.bak" ]; then
                        cp "${config_file}.import.bak" "$config_file"
                        yellow "已回滚"
                    else
                        rm -f "$config_file"
                    fi
                    return 1
                    ;;
            esac
        fi
    else
        yellow "内核未安装，跳过验证"
        return 0
    fi
}

import_from_local_dir() {
    local service_type="$1"
    env_health_check "$service_type"

    if [ -z "$ENV_LOCAL_CONFIGS" ]; then
        red "未找到可用的配置文件"
        return 1
    fi

    local list=() i=1
    echo ""
    yellow "发现以下配置文件："
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        list+=("$f")
        local size
        size=$(du -h "$f" 2>/dev/null | cut -f1)
        printf "  %d) %s (%s)\n" "$i" "$f" "${size:-?}"
        i=$((i + 1))
    done <<< "$ENV_LOCAL_CONFIGS"

    printf "\n选择文件编号（q=取消）: "
    read -r n
    case "$n" in q|Q) return 1 ;; esac
    if ! echo "$n" | grep -qE '^[0-9]+$' || [ "$n" -lt 1 ] || [ "$n" -gt "${#list[@]}" ]; then
        red "无效"
        return 1
    fi

    import_and_validate "$service_type" "${list[$((n-1))]}"
}

import_from_path() {
    local service_type="$1"
    printf "请输入配置文件绝对路径: "
    read -r p
    [ -z "$p" ] && { red "路径不能为空"; return 1; }
    [ ! -f "$p" ] && { red "文件不存在: $p"; return 1; }
    import_and_validate "$service_type" "$p"
}

import_from_url() {
    local service_type="$1"
    local env_file
    case "$service_type" in
        singbox) env_file="$SB_ENV_FILE" ;;
        mihomo)  env_file="$MH_ENV_FILE" ;;
    esac

    printf "请输入订阅 URL: "
    read -r url
    [ -z "$url" ] && { red "URL 不能为空"; return 1; }
    if ! echo "$url" | grep -qE '^https?://'; then
        red "URL 格式无效"
        return 1
    fi

    local tmp
    tmp=$(mktemp)
    log "下载配置..."
    if ! http_fetch "$url" "$tmp" "$CFG_CONNECT_TIMEOUT" "$CFG_MAX_TIME"; then
        red "下载失败"
        rm -f "$tmp"
        return 1
    fi

    import_and_validate "$service_type" "$tmp"
    local ret=$?
    rm -f "$tmp"

    if [ "$ret" -eq 0 ]; then
        printf "\n保存订阅链接以便自动更新？(Y/n): "
        read -r c
        case "$c" in
            n|N) ;;
            *)
                printf "更新间隔（分钟，默认 1440）: "
                read -r ci
                [ -z "$ci" ] && ci=1440
                echo "$ci" | grep -qE '^[0-9]+$' || ci=1440
                local display_name
                [ "$service_type" = "singbox" ] && display_name="Sing-box" || display_name="Mihomo"
                write_env_file "$env_file" "$url" "rule" "$ci" "$display_name"
                [ "$ci" -gt 0 ] && setup_cron_job_internal "$service_type" "$ci"
                ;;
        esac
    fi
    return $ret
}

import_config_menu() {
    local service_type="$1"
    local service_name config_file
    case "$service_type" in
        singbox) service_name="Sing-box"; config_file="$SB_CONFIG_FILE" ;;
        mihomo)  service_name="Mihomo"; config_file="$MH_CONFIG_FILE" ;;
        *) return 1 ;;
    esac

    clear
    printf "\n%b=== %s 配置文件导入 ===%b\n\n" "$GREEN" "$service_name" "$NC"
    env_health_check "$service_type"
    if [ -n "$ENV_LOCAL_CONFIGS" ]; then
        local cnt
        cnt=$(echo "$ENV_LOCAL_CONFIGS" | wc -l)
        green "💡 检测到 $cnt 个可用配置文件"
    fi
    echo ""
    printf " 1) 从当前/脚本目录自动扫描\n"
    printf " 2) 输入本地文件绝对路径\n"
    printf " 3) 从订阅链接下载\n"
    printf " 4) 生成默认模板\n"
    if [ -f "$config_file" ]; then
        printf " 5) 保留现有配置\n"
    fi
    printf " q) 取消\n\n"
    read -r -p "请选择: " choice

    case "$choice" in
        1) import_from_local_dir "$service_type" ;;
        2) import_from_path "$service_type" ;;
        3) import_from_url "$service_type" ;;
        4)
            if [ "$service_type" = "singbox" ]; then
                generate_initial_singbox_config
            else
                generate_initial_mihomo_config
            fi
            ;;
        5) [ -f "$config_file" ] && { green "已保留"; return 0; } || { red "文件不存在"; return 1; } ;;
        q|Q) return 1 ;;
        *) red "无效选项"; return 1 ;;
    esac
}

show_deploy_summary() {
    local service_type="$1"
    env_health_check "$service_type"
    local bin_path config_file service_name_display default_panel_port default_proxy_port
    case "$service_type" in
        singbox)
            bin_path="$SB_BIN_PATH"; config_file="$SB_CONFIG_FILE"
            service_name_display="Sing-box"
            default_panel_port="9090"; default_proxy_port="2080"
            ;;
        mihomo)
            bin_path="$MH_BIN_PATH"; config_file="$MH_CONFIG_FILE"
            service_name_display="Mihomo"
            default_panel_port="9090"; default_proxy_port="7890"
            ;;
    esac

    local ip_addr
    ip_addr=$(ip -4 addr show 2>/dev/null | grep -oE 'inet [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | grep -v '127.0.0.1' | head -1 | awk '{print $2}')

    clear
    green "╔═══════════════════════════════════════════════╗"
    green "║              🎉  部 署 完 成  🎉              ║"
    green "╚═══════════════════════════════════════════════╝"
    echo ""
    yellow "【${service_name_display} 部署摘要】"
    printf "  版本            : %s\n" "$("$bin_path" $([ "$service_type" = "singbox" ] && echo "version" || echo "-v") 2>&1 | head -1)"
    printf "  二进制路径      : %s\n" "$bin_path"
    printf "  配置文件        : %s\n" "$config_file"
    printf "  服务状态        : %s\n" "$([ "$ENV_SERVICE_RUNNING" = "1" ] && echo "✅ 运行中" || echo "❌ 未运行")"
    printf "  开机自启        : %s\n" "$([ "$ENV_SERVICE_ENABLED" = "1" ] && echo "✅ 已启用" || echo "❌ 未启用")"
    if [ "$service_type" = "mihomo" ]; then
        printf "  Mihomo DNS 端口 : %s\n" "$(parse_mihomo_dns_port)"
        printf "  系统 DNS 转发   : %s\n" "$(detect_dns_forward_status || echo '未配置')"
    fi
    echo ""
    yellow "【使用指南】"
    printf "  📊 Web 面板     : http://%s:%s/ui\n" "${ip_addr:-路由器IP}" "$default_panel_port"
    printf "  🔌 代理端口     : %s:%s\n" "${ip_addr:-路由器IP}" "$default_proxy_port"
    echo ""
    yellow "【日常维护】"
    if [ "$SYSTEM_TYPE" = "openwrt" ]; then
        printf "  重启服务  : /etc/init.d/%s restart\n" "$service_type" | sed 's/singbox/sing-box/'
    else
        printf "  重启服务  : systemctl restart %s\n" "$service_type" | sed 's/singbox/sing-box/'
    fi
    printf "  运行菜单  : bash %s\n" "$SCRIPT_PATH"
    printf "  智能自愈  : bash %s --autoheal %s\n" "$SCRIPT_PATH" "$service_type"
    printf "  查看状态  : bash %s --status %s\n" "$SCRIPT_PATH" "$service_type"
    echo ""
    green "═════════════════════════════════════════════════"
}

one_click_deploy_wizard() {
    local service_type="$1"
    local service_name_display install_func generate_func config_file
    case "$service_type" in
        singbox)
            service_name_display="Sing-box"
            install_func="install_singbox"
            generate_func="generate_initial_singbox_config"
            config_file="$SB_CONFIG_FILE"
            ;;
        mihomo)
            service_name_display="Mihomo"
            config_file="$MH_CONFIG_FILE"
            ;;
        *) red "无效服务类型"; return 1 ;;
    esac

    clear
    printf "\n%b╔═══════════════════════════════════════╗%b\n" "$GREEN" "$NC"
    printf "%b║      %s 一键部署向导            %b\n" "$GREEN" "$service_name_display" "$NC"
    printf "%b╚═══════════════════════════════════════╝%b\n\n" "$GREEN" "$NC"

    env_health_check "$service_type"

    yellow "【环境自检】"
    printf "  内核已安装    : %s\n" "$([ "$ENV_INSTALLED" = "1" ] && echo "✓" || echo "✗")"
    printf "  配置已存在    : %s\n" "$([ "$ENV_CONFIG_EXISTS" = "1" ] && echo "✓" || echo "✗")"
    printf "  配置文件有效  : %s\n" "$([ "$ENV_CONFIG_VALID" = "1" ] && echo "✓" || echo "✗/未验证")"
    printf "  服务运行中    : %s\n" "$([ "$ENV_SERVICE_RUNNING" = "1" ] && echo "✓" || echo "✗")"
    printf "  开机自启      : %s\n" "$([ "$ENV_SERVICE_ENABLED" = "1" ] && echo "✓" || echo "✗")"
    printf "  DNS 转发      : %s\n" "$([ "$ENV_DNS_CONFIGURED" = "1" ] && echo "✓" || echo "✗")"
    printf "  网络正常      : %s\n" "$([ "$ENV_NETWORK_OK" = "1" ] && echo "✓" || echo "✗")"
    if [ -n "$ENV_LOCAL_CONFIGS" ]; then
        local cnt
        cnt=$(echo "$ENV_LOCAL_CONFIGS" | wc -l)
        printf "  本地配置文件  : ✓ 共 %d 个\n" "$cnt"
    fi

    echo ""
    printf "%b═════════════════════════════════════════%b\n" "$GREEN" "$NC"
    printf "即将执行:\n"
    [ "$ENV_INSTALLED" = "0" ] && printf "  [1] 下载安装 %s\n" "$service_name_display" || printf "  [1] 跳过安装（已装）\n"
    printf "  [2] 配置来源选择\n"
    printf "  [3] 配置验证\n"
    printf "  [4] 网络转发 + NAT\n"
    printf "  [5] 服务安装 + 开机自启\n"
    printf "  [6] 启动服务\n"
    printf "  [7] DNS 转发配置\n"
    printf "  [8] 智能自愈联网测试\n"
    printf "%b═════════════════════════════════════════%b\n\n" "$GREEN" "$NC"

    printf "开始部署？(Y/n): "
    read -r c
    case "$c" in n|N) yellow "已取消"; return 0 ;; esac

    log "===== 步骤 1/8: 安装 ${service_name_display} ====="
    if [ "$ENV_INSTALLED" = "0" ]; then
        if [ "$service_type" = "mihomo" ]; then
            printf "\n%b请选择安装版本：%b\n" "$GREEN" "$NC"
            printf "  1) 稳定版（推荐）\n"
            printf "  2) Alpha with Smart Group（仅 amd64/arm64）\n"
            read -r -p "选择: " vc
            case "$vc" in
                2) install_mihomo_alpha_smart || { red "安装失败"; return 1; } ;;
                *) install_mihomo || { red "安装失败"; return 1; } ;;
            esac
        else
            $install_func || { red "安装失败"; return 1; }
        fi
    else
        green "✓ 已安装，跳过"
    fi

    log "===== 步骤 2/8: 配置来源选择 ====="
    if [ "$ENV_CONFIG_EXISTS" = "1" ] && [ "$ENV_CONFIG_VALID" = "1" ]; then
        yellow "检测到已有有效配置: $config_file"
        printf "使用现有配置？(Y/n): "
        read -r c
        case "$c" in
            n|N) import_config_menu "$service_type" || { red "配置导入失败"; return 1; } ;;
            *) green "✓ 使用现有配置" ;;
        esac
    else
        import_config_menu "$service_type" || { red "配置导入失败"; return 1; }
    fi

    log "===== 步骤 3/8: 配置验证 ====="
    if [ "$service_type" = "singbox" ]; then
        if ! "$SB_BIN_PATH" check -c "$SB_CONFIG_FILE" >/dev/null 2>&1; then
            red "配置验证失败"
            "$SB_BIN_PATH" check -c "$SB_CONFIG_FILE" 2>&1 | head -20
            return 1
        fi
    else
        if ! "$MH_BIN_PATH" -d "$MH_BASE_DIR" -t >/dev/null 2>&1; then
            red "配置验证失败"
            "$MH_BIN_PATH" -d "$MH_BASE_DIR" -t 2>&1 | head -20
            return 1
        fi
    fi
    green "✓ 配置验证通过"

    log "===== 步骤 4/8: 网络转发 + NAT ====="
    configure_network_forwarding_nat

    log "===== 步骤 5/8: 服务安装 ====="
    setup_service_files "$service_type" || { red "服务文件创建失败"; return 1; }
    manage_autostart_internal "$service_type" "enable"

    log "===== 步骤 6/8: 启动服务 ====="
    manage_service_internal "$service_type" "restart"
    sleep 3

    log "===== 步骤 7/8: DNS 转发 ====="
    if [ "$service_type" = "mihomo" ]; then
        local backend
        backend=$(detect_dns_backend)
        if [ "$backend" = "unknown" ]; then
            yellow "无法识别 DNS 后端，跳过"
        else
            printf "自动配置 DNS 转发？(Y/n): "
            read -r c
            case "$c" in
                n|N) yellow "已跳过" ;;
                *)
                    local mh_port
                    mh_port=$(parse_mihomo_dns_port)
                    if ! check_mihomo_dns_enabled; then
                        inject_mihomo_dns_block "$MH_DEFAULT_DNS_PORT"
                        mh_port="$MH_DEFAULT_DNS_PORT"
                        manage_service_internal "mihomo" "restart"
                        sleep 3
                    elif [ "$mh_port" = "53" ] && [ "$backend" != "resolv.conf" ]; then
                        update_mihomo_dns_port "$MH_DEFAULT_DNS_PORT"
                        mh_port="$MH_DEFAULT_DNS_PORT"
                        manage_service_internal "mihomo" "restart"
                        sleep 3
                    fi
                    apply_dns_forward "$mh_port" "$MH_DNS_BACKUP_DIR"
                    ;;
            esac
        fi
    else
        yellow "Sing-box 通常使用 TUN dns-hijack 自动接管 DNS"
        yellow "如需系统级 DNS 转发，请手动进入 DNS 管理菜单"
    fi

    log "===== 步骤 8/8: 智能自愈测试 ====="
    smart_autoheal "$service_type"

    show_deploy_summary "$service_type"
    return 0
}

singbox_management_menu() {
    while true; do
        clear
        local config_status="未配置" service_status="未运行"
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
        printf " 9)  卸载\n"
        printf " 10) 查看版本\n"
        printf " w)  %b一键部署向导%b\n" "$GREEN" "$NC"
        printf " i)  %b导入/切换配置文件%b\n" "$GREEN" "$NC"
        printf " e)  管理自启动\n"
        printf " c)  验证配置文件\n"
        printf " d)  %bDNS 转发管理%b\n" "$GREEN" "$NC"
        printf " s)  %b智能自愈诊断%b\n" "$GREEN" "$NC"
        printf " r)  显示诊断报告\n"
        printf " v)  查看日志\n"
        printf " q)  返回\n"
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
            w|W) one_click_deploy_wizard "singbox" ;;
            i|I)
                import_config_menu "singbox"
                if [ $? -eq 0 ] && pgrep sing-box >/dev/null 2>&1; then
                    printf "重启 Sing-box？(Y/n): "
                    read -r c
                    case "$c" in n|N) ;; *) manage_service_internal "singbox" "restart" ;; esac
                fi
                ;;
            e|E) manage_autostart_internal "singbox" ;;
            c|C) validate_config_internal "singbox" ;;
            d|D) manage_dns_forwarding_menu "singbox" ;;
            s|S) smart_autoheal "singbox" ;;
            r|R) show_diagnostic_report "singbox" ;;
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
        local config_status="未配置" service_status="未运行"
        [ -f "$MH_CONFIG_FILE" ] && config_status="已配置"
        manage_service_internal "mihomo" "status" >/dev/null 2>&1 && service_status="运行中"
        local api_url
        api_url=$(get_config_manager_url "mihomo" 2>/dev/null)
        local dns_backend dns_fwd
        dns_backend=$(detect_dns_backend)
        dns_fwd=$(detect_dns_forward_status)

        printf "\n%b=== Mihomo 管理菜单 ===%b\n" "$GREEN" "$NC"
        printf "状态: %s | 配置: %s\n" "$service_status" "$config_status"
        printf "二进制: %s\n" "$MH_BIN_PATH"
        printf "DNS 后端: %s | 转发: %s\n" "$dns_backend" "${dns_fwd:-未转发}"
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
        printf " w)  %b一键部署向导%b\n" "$GREEN" "$NC"
        printf " i)  %b导入/切换配置文件%b\n" "$GREEN" "$NC"
        printf " a)  卸载\n"
        printf " e)  管理自启动\n"
        printf " c)  验证配置文件\n"
        printf " d)  %bDNS 转发管理%b\n" "$GREEN" "$NC"
        printf " s)  %b智能自愈诊断%b\n" "$GREEN" "$NC"
        printf " r)  显示诊断报告\n"
        printf " v)  查看日志\n"
        printf " q)  返回\n"
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
            w|W) one_click_deploy_wizard "mihomo" ;;
            i|I)
                import_config_menu "mihomo"
                if [ $? -eq 0 ] && pgrep mihomo >/dev/null 2>&1; then
                    printf "重启 Mihomo？(Y/n): "
                    read -r c
                    case "$c" in n|N) ;; *) manage_service_internal "mihomo" "restart" ;; esac
                fi
                ;;
            a|A) remove_all_files_and_service "mihomo" ;;
            e|E) manage_autostart_internal "mihomo" ;;
            c|C) validate_config_internal "mihomo" ;;
            d|D) manage_dns_forwarding_menu "mihomo" ;;
            s|S) smart_autoheal "mihomo" ;;
            r|R) show_diagnostic_report "mihomo" ;;
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
        printf " 3) 清理系统转发与 NAT\n"
        printf " 4) 修复下载工具\n"
        printf " 5) 清除镜像缓存\n"
        printf " 6) 手动探测最快镜像\n"
        printf " q) 返回\n"
        printf "%b=====================%b\n" "$GREEN" "$NC"
        read -r -p "选项: " choice
        case "$choice" in
            1) check_network ;;
            2) configure_network_forwarding_nat ;;
            3) clean_up_system_configs ;;
            4) fix_openwrt_curl; detect_download_tool && green "当前下载工具: $DL_TOOL" ;;
            5) rm -f "$MIRROR_CACHE_FILE"; green "镜像缓存已清除" ;;
            6)
                yellow "开始探测所有镜像..."
                for m in $PROXY_MIRRORS; do
                    printf "  测试 %s ... " "$m"
                    if probe_url "${m}https://raw.githubusercontent.com/MetaCubeX/mihomo/Meta/README.md" >/dev/null 2>&1; then
                        green "OK"
                    else
                        red "失败"
                    fi
                done
                ;;
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
        local sb_installed=0 sb_running=0 mh_installed=0 mh_running=0
        [ -x "$SB_BIN_PATH" ] && sb_installed=1
        [ -x "$MH_BIN_PATH" ] && mh_installed=1
        pgrep sing-box >/dev/null 2>&1 && sb_running=1
        pgrep mihomo >/dev/null 2>&1 && mh_running=1

        local cached_mirror
        cached_mirror=$(load_best_mirror)

        printf "\n%b╔═══════════════════════════════════════════╗%b\n" "$GREEN" "$NC"
        printf "%b║   代理管理器 v3.0 (Sing-box + Mihomo)     ║%b\n" "$GREEN" "$NC"
        printf "%b╚═══════════════════════════════════════════╝%b\n" "$GREEN" "$NC"
        printf "设备: %s | 系统: %s | 下载工具: %s\n" "$DEVICE_NAME" "$SYSTEM_TYPE" "${DL_TOOL:-未探测}"
        printf "镜像缓存: %s\n\n" "${cached_mirror:-未缓存}"

        yellow "【内核状态】"
        printf "  Sing-box: %s | %s\n" \
            "$([ "$sb_installed" = "1" ] && green "已安装" || red "未安装")" \
            "$([ "$sb_running" = "1" ] && green "运行中" || red "未运行")"
        printf "  Mihomo  : %s | %s\n" \
            "$([ "$mh_installed" = "1" ] && green "已安装" || red "未安装")" \
            "$([ "$mh_running" = "1" ] && green "运行中" || red "未运行")"

        echo ""
        printf "%b═══════════════════════════════════════════%b\n" "$GREEN" "$NC"
        printf " 1) 🎯 %bSing-box 管理%b（安装/配置/维护）\n" "$GREEN" "$NC"
        printf " 2) 🎯 %bMihomo 管理%b  （安装/配置/维护）\n" "$GREEN" "$NC"
        printf "%b───────────────────────────────────────────%b\n" "$GREEN" "$NC"
        printf " 3) 🚀 Sing-box 一键部署向导\n"
        printf " 4) 🚀 Mihomo 一键部署向导\n"
        printf "%b───────────────────────────────────────────%b\n" "$GREEN" "$NC"
        printf " 5) ⚙️  通用系统设置（网络/NAT/镜像）\n"
        printf " q) 退出\n"
        printf "%b═══════════════════════════════════════════%b\n" "$GREEN" "$NC"
        read -r -p "请选择操作: " choice

        case "$choice" in
            1) singbox_management_menu ;;
            2) mihomo_management_menu ;;
            3) one_click_deploy_wizard "singbox"; read -r -p "按 [Enter] 键继续..." ;;
            4) one_click_deploy_wizard "mihomo"; read -r -p "按 [Enter] 键继续..." ;;
            5) common_settings_menu ;;
            q|Q) green "正在退出..."; exit 0 ;;
            *) red "无效选项"; read -r -p "按 [Enter] 键继续..." ;;
        esac
    done
}

non_interactive_mode() {
    case "${1:-}" in
        --update)
            check_root
            local svc="${2:-}"
            [ -z "$svc" ] && { red "用法: $0 --update [singbox|mihomo]"; exit 1; }
            log "Cron 触发: 更新 $svc"
            update_config_and_start_service "$svc"
            ;;
        --autoheal)
            check_root
            local svc="${2:-mihomo}"
            log "命令行触发: $svc 智能自愈"
            smart_autoheal "$svc"
            ;;
        --diagnostic)
            check_root
            local svc="${2:-mihomo}"
            show_diagnostic_report "$svc"
            ;;
        --deploy)
            check_root
            local svc="${2:-}"
            [ -z "$svc" ] && { red "用法: $0 --deploy [singbox|mihomo]"; exit 1; }
            install_deps
            one_click_deploy_wizard "$svc"
            ;;
        --import)
            check_root
            local svc="${2:-}" src="${3:-}"
            if [ -z "$svc" ] || [ -z "$src" ] || [ ! -f "$src" ]; then
                red "用法: $0 --import [singbox|mihomo] <config-file>"
                exit 1
            fi
            install_deps
            import_and_validate "$svc" "$src"
            if [ $? -eq 0 ] && pgrep "$([ "$svc" = "singbox" ] && echo "sing-box" || echo "mihomo")" >/dev/null 2>&1; then
                manage_service_internal "$svc" "restart"
            fi
            ;;
        --status)
            local svc="${2:-mihomo}"
            env_health_check "$svc"
            printf "service=%s\n" "$svc"
            printf "installed=%s\n" "$([ "$ENV_INSTALLED" = "1" ] && echo "yes" || echo "no")"
            printf "config_exists=%s\n" "$([ "$ENV_CONFIG_EXISTS" = "1" ] && echo "yes" || echo "no")"
            printf "config_valid=%s\n" "$([ "$ENV_CONFIG_VALID" = "1" ] && echo "yes" || echo "no")"
            printf "service_running=%s\n" "$([ "$ENV_SERVICE_RUNNING" = "1" ] && echo "yes" || echo "no")"
            printf "service_enabled=%s\n" "$([ "$ENV_SERVICE_ENABLED" = "1" ] && echo "yes" || echo "no")"
            printf "dns_configured=%s\n" "$([ "$ENV_DNS_CONFIGURED" = "1" ] && echo "yes" || echo "no")"
            printf "network_ok=%s\n" "$([ "$ENV_NETWORK_OK" = "1" ] && echo "yes" || echo "no")"
            ;;
        --help|-h)
            echo "代理管理器命令行模式:"
            echo ""
            echo "  --deploy    [singbox|mihomo]              一键部署向导"
            echo "  --import    [singbox|mihomo] <config>     导入配置文件"
            echo "  --update    [singbox|mihomo]              从订阅更新"
            echo "  --autoheal  [singbox|mihomo]              智能自愈"
            echo "  --diagnostic [singbox|mihomo]             诊断报告"
            echo "  --status    [singbox|mihomo]              状态查询"
            echo "  --help                                    显示帮助"
            echo ""
            echo "无参数进入交互式菜单"
            ;;
        *)
            red "不支持的命令: ${1:-}"
            echo "运行 $0 --help 查看帮助"
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
