#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
    echo "错误: 请使用 bash 运行此脚本" >&2
    exit 1
fi
_BASH_MAJOR="${BASH_VERSINFO[0]:-0}"
_BASH_MINOR="${BASH_VERSINFO[1]:-0}"
if [ "$_BASH_MAJOR" -lt 3 ] || { [ "$_BASH_MAJOR" -eq 3 ] && [ "$_BASH_MINOR" -lt 2 ]; }; then
    echo "错误: 需要 bash 3.2 或更高版本，当前版本: ${BASH_VERSION}" >&2
    exit 1
fi
set -u
(set -o pipefail) 2>/dev/null && set -o pipefail
trap '_trap_int' INT
trap '_trap_exit $?' EXIT

GLOBAL_EXTRACT_DIR=""
GLOBAL_DEPLOY_CFG_FILE=""
GLOBAL_RESTORE_LIST=""
GLOBAL_BACKUP_DIR=""
GLOBAL_EXPORT_PREFIX="backup_$(date +%Y%m%d_%H%M%S)"
GLOBAL_IMAGES_TO_SAVE=""
GLOBAL_IMAGE_COUNT=0
GLOBAL_LAST_LOADED_IMAGES=()
FOUND_BACKUP_FILES=()

OS_NAME="unknown"
OS_ARCH="unknown"
HAS_SUDO=false
HAS_DOCKER=false
HAS_GZIP=false
HAS_TPUT=false
HAS_CRANE=false

C_GREEN=""
C_RED=""
C_YELLOW=""
C_CYAN=""
C_BOLD=""
C_RESET=""

LOG_FILE="${HOME:-/tmp}/.deploy_script.log"
_SCRIPT_EXITING=false

_trap_int() {
    printf '\n\033[31m操作被用户中断。\033[0m\n' >&2
    _SCRIPT_EXITING=true
    exit 130
}

_trap_exit() {
    local code="${1:-0}"
    if [ "$code" -ne 0 ] && [ "$code" -ne 130 ] && [ "$_SCRIPT_EXITING" = "false" ]; then
        printf '\033[31m[退出] 脚本异常退出，退出码: %s\033[0m\n' "$code" >&2
    fi
}

green()  { printf '%s%s%s\n' "$C_GREEN"  "$*" "$C_RESET" >&2; }
red()    { printf '%s%s%s\n' "$C_RED"    "$*" "$C_RESET" >&2; }
yellow() { printf '%s%s%s\n' "$C_YELLOW" "$*" "$C_RESET" >&2; }
cyan()   { printf '%s%s%s\n' "$C_CYAN"   "$*" "$C_RESET" >&2; }
bold()   { printf '%s%s%s\n' "$C_BOLD"   "$*" "$C_RESET" >&2; }

press_any_key() {
    printf '\n按任意键继续...' >&2
    if [ -r /dev/tty ]; then
        IFS= read -r -n 1 -s _pkey </dev/tty || true
    elif [ -t 0 ]; then
        IFS= read -r -n 1 -s _pkey || true
    fi
    printf '\n' >&2
}

_read_line() {
    local _varname="$1"
    shift
    local _prompt="${*:-}"
    local _val=""
    [ -n "$_prompt" ] && printf '%s' "$_prompt" >&2
    if [ -r /dev/tty ]; then
        IFS= read -r _val </dev/tty || true
    elif [ -t 0 ]; then
        IFS= read -r _val || true
    else
        IFS= read -r _val || true
    fi
    printf -v "$_varname" '%s' "$_val"
}

_lower() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

_trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

_get_file_size() {
    local f="$1"
    [ -f "$f" ] || { printf '0\n'; return 0; }
    stat -c%s "$f" 2>/dev/null && return 0
    stat -f%z "$f" 2>/dev/null && return 0
    wc -c < "$f" 2>/dev/null | tr -d ' ' || printf '0\n'
}

_get_hsize() {
    local f="$1"
    local s=""
    s=$(du -h "$f" 2>/dev/null | awk 'NR==1{print $1;exit}') || true
    [ -n "$s" ] || s=$(ls -lh "$f" 2>/dev/null | awk '{print $5; exit}') || true
    [ -n "$s" ] || s="未知"
    printf '%s\n' "$s"
}

_setup_colors() {
    if [ -t 2 ] && command -v tput >/dev/null 2>&1; then
        local ncolors=0
        ncolors=$(tput colors 2>/dev/null) || ncolors=0
        if [ "${ncolors:-0}" -ge 8 ] 2>/dev/null; then
            HAS_TPUT=true
            C_GREEN=$(tput setaf 2 2>/dev/null) || C_GREEN=""
            C_RED=$(tput setaf 1 2>/dev/null)   || C_RED=""
            C_YELLOW=$(tput setaf 3 2>/dev/null) || C_YELLOW=""
            C_CYAN=$(tput setaf 6 2>/dev/null)   || C_CYAN=""
            C_BOLD=$(tput bold 2>/dev/null)       || C_BOLD=""
            C_RESET=$(tput sgr0 2>/dev/null)      || C_RESET=""
            return 0
        fi
    fi
    if [ -t 2 ]; then
        C_GREEN=$'\033[32m'
        C_RED=$'\033[31m'
        C_YELLOW=$'\033[33m'
        C_CYAN=$'\033[36m'
        C_BOLD=$'\033[1m'
        C_RESET=$'\033[0m'
    fi
}

setup_logging() {
    local max_size=3145728
    local cur_size=0
    : >> "$LOG_FILE" 2>/dev/null || { LOG_FILE="/tmp/.deploy_script_$$.log"; : >> "$LOG_FILE" 2>/dev/null || return 0; }
    cur_size=$(_get_file_size "$LOG_FILE")
    [ "${cur_size:-0}" -gt "$max_size" ] 2>/dev/null && : > "$LOG_FILE" || true
    if command -v tee >/dev/null 2>&1 && [ "$_BASH_MAJOR" -ge 3 ]; then
        exec > >(tee -a "$LOG_FILE") 2>&1 || exec >> "$LOG_FILE" 2>&1
    else
        exec >> "$LOG_FILE" 2>&1
    fi
}

detect_os() {
    _setup_colors
    OS_ARCH=$(uname -m 2>/dev/null || printf 'unknown')
    case "$OS_ARCH" in
        x86_64|amd64)             OS_ARCH="x86_64"  ;;
        aarch64|arm64)            OS_ARCH="arm64"   ;;
        armv7l|armv7|armhf)       OS_ARCH="armv7"   ;;
        armv6l|armv6)             OS_ARCH="armv6"   ;;
        i386|i686)                OS_ARCH="x86"     ;;
        mips|mipsel|mips64*|mips64el*) OS_ARCH="mips" ;;
        riscv64)                  OS_ARCH="riscv64" ;;
        s390x)                    OS_ARCH="s390x"   ;;
        ppc64le|ppc64)            OS_ARCH="ppc64"   ;;
    esac
    if command -v sw_vers >/dev/null 2>&1 || uname -s 2>/dev/null | grep -qi darwin; then
        OS_NAME="macos"
    elif grep -qi openwrt /etc/os-release 2>/dev/null \
        || uname -v 2>/dev/null | grep -qi libwrt \
        || [ -f /etc/openwrt_release ]; then
        OS_NAME="openwrt"
    elif [ -f /etc/alpine-release ]; then
        OS_NAME="alpine"
    elif [ -f /etc/fedora-release ] || grep -qi fedora /etc/os-release 2>/dev/null; then
        OS_NAME="fedora"
    elif grep -qE 'centos|rhel|rocky|almalinux' /etc/os-release 2>/dev/null; then
        OS_NAME="centos"
    elif grep -qE 'debian|ubuntu|raspbian|linuxmint|pop!_os' /etc/os-release 2>/dev/null; then
        OS_NAME="debian"
    elif grep -qE 'arch|manjaro|endeavouros|artix' /etc/os-release 2>/dev/null; then
        OS_NAME="arch"
    elif grep -qi suse /etc/os-release 2>/dev/null; then
        OS_NAME="suse"
    elif grep -qi gentoo /etc/os-release 2>/dev/null; then
        OS_NAME="gentoo"
    else
        OS_NAME="unknown"
    fi
    if command -v sudo >/dev/null 2>&1; then
        if [ "$(id -u)" -eq 0 ]; then
            HAS_SUDO=false
        elif sudo -n true 2>/dev/null; then
            HAS_SUDO=true
        else
            HAS_SUDO=true
        fi
    else
        HAS_SUDO=false
    fi
    command -v docker >/dev/null 2>&1 && HAS_DOCKER=true  || HAS_DOCKER=false
    command -v gzip   >/dev/null 2>&1 && HAS_GZIP=true    || HAS_GZIP=false
    command -v crane  >/dev/null 2>&1 && HAS_CRANE=true   || HAS_CRANE=false
    cyan "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf '%s系统: %s | 架构: %s | Bash: %s%s\n' \
        "$C_CYAN" "$OS_NAME" "$OS_ARCH" "$BASH_VERSION" "$C_RESET" >&2
    cyan "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

self_check() {
    local missing=""
    local cmd=""
    for cmd in date find grep sed awk sort tr cut du mkdir ls; do
        command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
    done
    if [ -n "$missing" ]; then
        red "缺少基础命令:$missing"
        exit 1
    fi
    if [ -f "$0" ] && [ -r "$0" ]; then
        bash -n "$0" >/dev/null 2>&1 || {
            red "脚本语法自检失败，请检查脚本完整性。"
            exit 1
        }
    fi
}

_sudo_prefix() {
    [ "$(id -u)" -eq 0 ] && printf '' && return 0
    [ "$HAS_SUDO" = "true" ] && printf 'sudo' && return 0
    printf ''
}

install_dependency() {
    local dep_name="$1"
    local pkg_name="${2:-$1}"
    local sp=""
    sp=$(_sudo_prefix)
    yellow "正在安装依赖: ${dep_name} (包名: ${pkg_name})..."
    case "$OS_NAME" in
        debian)
            if [ -n "$sp" ]; then
                $sp apt-get update -qq 2>/dev/null || true
                $sp apt-get install -y -qq "$pkg_name" 2>/dev/null
            else
                apt-get update -qq 2>/dev/null || true
                apt-get install -y -qq "$pkg_name" 2>/dev/null
            fi
            ;;
        centos)
            if command -v dnf >/dev/null 2>&1; then
                if [ -n "$sp" ]; then $sp dnf install -y "$pkg_name" 2>/dev/null
                else dnf install -y "$pkg_name" 2>/dev/null; fi
            else
                if [ -n "$sp" ]; then $sp yum install -y "$pkg_name" 2>/dev/null
                else yum install -y "$pkg_name" 2>/dev/null; fi
            fi
            ;;
        fedora)
            if [ -n "$sp" ]; then $sp dnf install -y "$pkg_name" 2>/dev/null
            else dnf install -y "$pkg_name" 2>/dev/null; fi
            ;;
        arch)
            if [ -n "$sp" ]; then $sp pacman -Sy --noconfirm "$pkg_name" 2>/dev/null
            else pacman -Sy --noconfirm "$pkg_name" 2>/dev/null; fi
            ;;
        alpine)
            apk add --no-cache "$pkg_name" 2>/dev/null
            ;;
        openwrt)
            opkg update 2>/dev/null || true
            opkg install "$pkg_name" 2>/dev/null
            ;;
        suse)
            if [ -n "$sp" ]; then $sp zypper install -y "$pkg_name" 2>/dev/null
            else zypper install -y "$pkg_name" 2>/dev/null; fi
            ;;
        gentoo)
            if [ -n "$sp" ]; then $sp emerge --ask=n "$pkg_name" 2>/dev/null
            else emerge --ask=n "$pkg_name" 2>/dev/null; fi
            ;;
        macos)
            if command -v brew >/dev/null 2>&1; then
                brew install "$pkg_name" 2>/dev/null
            else
                red "请先安装 Homebrew: https://brew.sh"
                return 1
            fi
            ;;
        *)
            red "不支持自动安装，请手动安装: ${pkg_name}"
            return 1
            ;;
    esac
    if command -v "$dep_name" >/dev/null 2>&1; then
        green "  ✓ ${dep_name} 安装成功"
        return 0
    else
        red "  ✗ ${dep_name} 安装失败，请手动安装"
        return 1
    fi
}

ensure_dependency() {
    local cmd="$1"
    local pkg="${2:-$1}"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        yellow "未找到 ${cmd}，尝试自动安装..."
        install_dependency "$cmd" "$pkg" || return 1
    fi
    return 0
}

_ping_test() {
    local host="$1"
    ping -c1 -W2 "$host" >/dev/null 2>&1 && return 0
    ping -c1 -W2000 "$host" >/dev/null 2>&1 && return 0
    ping -c1 -w2 "$host" >/dev/null 2>&1 && return 0
    ping -c1 "$host" >/dev/null 2>&1 && return 0
    return 1
}

_http_get() {
    local url="$1"
    local timeout="${2:-10}"
    if command -v curl >/dev/null 2>&1; then
        curl -sL --connect-timeout "$timeout" --max-time $((timeout * 3)) "$url" 2>/dev/null
        return $?
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- --timeout="$timeout" "$url" 2>/dev/null
        return $?
    else
        red "未找到 curl 或 wget，请安装其中一个。" >&2
        return 1
    fi
}

_detect_network() {
    local network_status="unknown"
    local ping_ok=false
    local http_ok=false
    _ping_test 8.8.8.8 && ping_ok=true || true
    if command -v curl >/dev/null 2>&1; then
        curl -sI --connect-timeout 5 --max-time 10 https://github.com >/dev/null 2>&1 && http_ok=true || true
    elif command -v wget >/dev/null 2>&1; then
        wget -q --spider --timeout=10 https://github.com >/dev/null 2>&1 && http_ok=true || true
    fi
    if [ "$ping_ok" = "true" ] && [ "$http_ok" = "true" ]; then
        network_status="direct"
    elif [ "$ping_ok" = "true" ]; then
        network_status="limited"
    else
        network_status="offline"
    fi
    printf '%s\n' "$network_status"
}

_sort_versions() {
    if sort -V /dev/null >/dev/null 2>&1; then
        sort -V -r
    else
        sort -r
    fi
}

get_image_versions() {
    local service_name="$1"
    local image_base="$2"
    local source="$3"
    local limit="${4:-20}"
    local tag_list=""
    case "$source" in
        github)
            local releases_json=""
            releases_json=$(_http_get \
                "https://api.github.com/repos/${image_base}/releases?per_page=${limit}")
            tag_list=$(printf '%s\n' "$releases_json" \
                | grep -o '"tag_name": "[^"]*"' \
                | sed 's/"tag_name": "//;s/"//' \
                | _sort_versions \
                | head -"$limit") || tag_list=""
            if [ -z "$tag_list" ] && [ "$HAS_CRANE" = "true" ]; then
                local ghcr_image=""
                ghcr_image=$(printf '%s' "$image_base" | tr '[:upper:]' '[:lower:]')
                tag_list=$(crane list "ghcr.io/${ghcr_image}" 2>/dev/null \
                    | grep -E '^v?[0-9]+\.[0-9]+' \
                    | _sort_versions \
                    | head -"$limit") || tag_list=""
            fi
            ;;
        ghcr)
            if [ "$HAS_CRANE" = "true" ]; then
                local ghcr_image=""
                ghcr_image=$(printf '%s' "$image_base" | tr '[:upper:]' '[:lower:]')
                tag_list=$(crane list "ghcr.io/${ghcr_image}" 2>/dev/null \
                    | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' \
                    | _sort_versions \
                    | head -"$limit") || tag_list=""
            else
                yellow "未安装 crane，无法查询 ghcr 标签。"
            fi
            ;;
        dockerhub)
            local dh_json=""
            dh_json=$(_http_get \
                "https://hub.docker.com/v2/repositories/${image_base}/tags/?page_size=${limit}")
            tag_list=$(printf '%s\n' "$dh_json" \
                | grep -o '"name":"[^"]*"' \
                | sed 's/"name":"//;s/"//' \
                | grep -E '^v?[0-9]' \
                | _sort_versions \
                | head -"$limit") || tag_list=""
            ;;
        *)
            red "未知来源: ${source}"
            ;;
    esac
    printf 'latest\n'
    [ -n "$tag_list" ] && printf '%s\n' "$tag_list"
    printf 'manual_input\n'
}

select_image_version() {
    local service_name="$1"
    local image_base="$2"
    local fetch_type="$3"
    local fetch_source="$4"
    local max_count="${5:-20}"
    cyan "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    cyan "  可支持的版本列表 (${service_name})"
    cyan "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    yellow "正在获取版本列表，请稍候..."
    local version_list=""
    version_list=$(get_image_versions "$service_name" "$image_base" "$fetch_source" "$max_count")
    local count=0
    local versions_indexed=()
    while IFS= read -r ver; do
        [ -n "$ver" ] || continue
        count=$((count + 1))
        versions_indexed+=("$ver")
        local display_ver="$ver"
        [ "$ver" = "latest" ]       && display_ver="${C_GREEN}latest${C_RESET}"
        [ "$ver" = "manual_input" ] && display_ver="${C_YELLOW}手动输入版本号${C_RESET}"
        printf '  %3d. %b\n' "$count" "$display_ver" >&2
    done <<< "$version_list"
    printf '\n' >&2
    local version_input=""
    local selected_version=""
    while true; do
        _read_line version_input "请输入选项编号 (1-${count}，或直接输入版本号): "
        if [ -z "$version_input" ]; then
            red "输入不能为空，请重试。"
            continue
        fi
        if printf '%s' "$version_input" | grep -qE '^[0-9]+$'; then
            if [ "$version_input" -ge 1 ] && [ "$version_input" -le "$count" ]; then
                local _idx=$(( version_input - 1 ))
                selected_version="${versions_indexed[$_idx]}"
                if [ "$selected_version" = "manual_input" ]; then
                    _read_line selected_version "请输入版本号: "
                fi
                break
            else
                red "编号超出范围 (1-${count})，请重试。"
            fi
        else
            selected_version="$version_input"
            break
        fi
    done
    printf '%s\n' "$selected_version"
}

select_version_menu() {
    select_image_version "$@"
}

_check_docker() {
    if [ "$HAS_DOCKER" != "true" ]; then
        red "未检测到 Docker，请先安装 Docker。"
        return 1
    fi
    if ! docker info >/dev/null 2>&1; then
        red "Docker daemon 未运行，请先启动 Docker 服务。"
        case "$OS_NAME" in
            debian|centos|fedora|arch|suse) yellow "提示: sudo systemctl start docker" ;;
            alpine|openwrt)                 yellow "提示: service docker start" ;;
            macos)                          yellow "提示: 请启动 Docker Desktop 应用" ;;
        esac
        return 1
    fi
    return 0
}

_list_local_images() {
    local filter="${1:-}"
    local result=""
    result=$(docker images \
        --format '{{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.Size}}' \
        2>/dev/null | grep -v '^<none>:' | sort 2>/dev/null) || result=""
    if [ -n "$filter" ]; then
        result=$(printf '%s\n' "$result" | grep -i "$filter" 2>/dev/null) || result=""
    fi
    printf '%s\n' "$result"
}

_parse_indices() {
    local input="$1"
    local max="$2"
    local cleaned=""
    cleaned=$(printf '%s' "$input" | tr -d ' ')
    [ -n "$cleaned" ] || return 1
    case "$(_lower "$cleaned")" in
        all|a) printf 'all\n'; return 0 ;;
    esac
    local list=""
    local parts=()
    IFS=',' read -r -a parts <<< "$cleaned"
    local part=""
    local start="" end="" i=""
    for part in "${parts[@]}"; do
        if printf '%s' "$part" | grep -qE '^[0-9]+-[0-9]+$'; then
            start="${part%-*}"
            end="${part#*-}"
            if [ "$start" -le "$end" ]; then
                i="$start"
                while [ "$i" -le "$end" ]; do
                    [ "$i" -ge 1 ] && [ "$i" -le "$max" ] && list="$list $i"
                    i=$((i + 1))
                done
            else
                i="$end"
                while [ "$i" -le "$start" ]; do
                    [ "$i" -ge 1 ] && [ "$i" -le "$max" ] && list="$list $i"
                    i=$((i + 1))
                done
            fi
        elif printf '%s' "$part" | grep -qE '^[0-9]+$'; then
            [ "$part" -ge 1 ] && [ "$part" -le "$max" ] && list="$list $part"
        fi
    done
    list=$(printf '%s\n' $list 2>/dev/null \
        | grep -E '^[0-9]+$' \
        | sort -un \
        | tr '\n' ' ' \
        | sed 's/^ *//;s/ *$//')
    [ -n "$list" ] || return 1
    printf '%s\n' "$list"
}

list_local_images_menu() {
    local filter="${1:-}"
    local images_data=""
    local idx=0
    local input_raw=""
    local result_indices=""
    cyan "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    cyan "  本机已拉取的 Docker 镜像"
    cyan "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    images_data=$(_list_local_images "$filter")
    if [ -z "$images_data" ]; then
        red "未找到任何本地镜像，请先执行 docker pull 拉取镜像。"
        press_any_key
        return 1
    fi
    printf '  %-4s %-45s %-15s %s\n' "编号" "镜像名称" "标签" "大小" >&2
    printf '  %-4s %-45s %-15s %s\n' \
        "────" \
        "─────────────────────────────────────────────" \
        "───────────────" \
        "──────" >&2
    while IFS=$'\t' read -r full_repo image_id image_size; do
        [ -n "$full_repo" ] || continue
        idx=$((idx + 1))
        local short_repo="${full_repo%:*}"
        local short_tag="${full_repo##*:}"
        [ "$short_repo" = "$full_repo" ] && short_tag="latest"
        printf '  [%-2d] %-45s %-15s %s\n' \
            "$idx" "$short_repo" "$short_tag" "$image_size" >&2
    done <<< "$images_data"
    printf '\n' >&2
    cyan "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf '  %s\n' "输入示例: 1,3,5-8  (逗号分隔，支持范围)" >&2
    printf '  %s\n' "输入 all 表示全部操作" >&2
    printf '  %s\n' "输入 q   返回上级" >&2
    cyan "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf '\n' >&2
    _read_line input_raw "请选择要操作的镜像编号: "
    case "$(_lower "$input_raw")" in
        q|quit) return 1 ;;
        all|a)  printf 'all\n'; return 0 ;;
        "")
            red "未选择任何镜像。"
            press_any_key
            return 1
            ;;
    esac
    result_indices=$(_parse_indices "$input_raw" "$idx" 2>/dev/null) || true
    if [ -z "$result_indices" ]; then
        red "没有有效的选项，请重新选择。"
        press_any_key
        return 1
    fi
    printf '%s\n' "$result_indices"
}

extract_images() {
    _check_docker || return 1
    ensure_dependency gzip || return 1
    local export_dir="${GLOBAL_EXTRACT_DIR:-$(pwd)/docker_images_$(date +%Y%m%d_%H%M%S)}"
    local export_prefix="${GLOBAL_EXPORT_PREFIX:-backup}"
    mkdir -p "$export_dir" 2>/dev/null || {
        red "无法创建目录: $export_dir"
        press_any_key
        return 1
    }
    local selected_items=""
    selected_items=$(list_local_images_menu "") || return 0
    [ -n "$selected_items" ] || return 0
    local images_data=""
    images_data=$(_list_local_images "")
    local items_array=()
    local idx=0
    if [ "$selected_items" = "all" ]; then
        while IFS=$'\t' read -r repo _id _size; do
            [ -n "$repo" ] && items_array+=("$repo")
        done <<< "$images_data"
    else
        while IFS=$'\t' read -r repo _id _size; do
            [ -n "$repo" ] || continue
            idx=$((idx + 1))
            for sel in $selected_items; do
                if [ "$sel" = "$idx" ]; then
                    items_array+=("$repo")
                    break
                fi
            done
        done <<< "$images_data"
    fi
    if [ "${#items_array[@]}" -eq 0 ]; then
        red "未选择任何镜像。"
        press_any_key
        return 0
    fi
    GLOBAL_IMAGE_COUNT="${#items_array[@]}"
    cyan "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    cyan "  确认保存信息"
    cyan "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf '  目标目录: %s\n' "$export_dir" >&2
    printf '  文件前缀: %s\n' "$export_prefix" >&2
    printf '  镜像数量: %s\n' "$GLOBAL_IMAGE_COUNT" >&2
    printf '\n  镜像列表:\n' >&2
    for img in "${items_array[@]}"; do
        printf '    • %s\n' "$img" >&2
    done
    printf '\n' >&2
    local confirm=""
    _read_line confirm "确认保存这些镜像？(y/N): "
    case "$(_lower "$confirm")" in
        y|yes) ;;
        *)
            red "已取消操作。"
            press_any_key
            return 0
            ;;
    esac
    local total="${#items_array[@]}"
    local success_count=0
    local fail_count=0
    for i in "${!items_array[@]}"; do
        local num=$((i + 1))
        local img="${items_array[$i]}"
        local safe_name=""
        safe_name=$(printf '%s' "$img" | tr '/:@' '___')
        if [ "$HAS_GZIP" = "true" ]; then
            local save_target="${export_dir}/${export_prefix}_${safe_name}.tar.gz"
            yellow "[${num}/${total}] 正在保存: ${img}"
            if docker save "$img" 2>/dev/null | gzip > "$save_target"; then
                green "  ✓ 完成 ($(_get_hsize "$save_target")) -> $(basename "$save_target")"
                success_count=$((success_count + 1))
            else
                red "  ✗ 保存失败: $img"
                rm -f "$save_target" 2>/dev/null || true
                fail_count=$((fail_count + 1))
            fi
        else
            local save_target="${export_dir}/${export_prefix}_${safe_name}.tar"
            yellow "[${num}/${total}] 正在保存: ${img}"
            if docker save "$img" > "$save_target" 2>/dev/null; then
                green "  ✓ 完成 ($(_get_hsize "$save_target")) -> $(basename "$save_target")"
                success_count=$((success_count + 1))
            else
                red "  ✗ 保存失败: $img"
                rm -f "$save_target" 2>/dev/null || true
                fail_count=$((fail_count + 1))
            fi
        fi
    done
    GLOBAL_BACKUP_DIR="$export_dir"
    GLOBAL_IMAGES_TO_SAVE="${items_array[*]}"
    cyan "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    green "  保存完成！成功: ${success_count}，失败: ${fail_count}"
    printf '  文件位置: %s\n' "$export_dir" >&2
    ls -lh "$export_dir"/ 2>/dev/null || true
    cyan "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    press_any_key
}

_collect_backup_files() {
    local dir="$1"
    FOUND_BACKUP_FILES=()
    while IFS= read -r f; do
        [ -n "$f" ] && FOUND_BACKUP_FILES+=("$f")
    done < <(find "$dir" -maxdepth 1 -type f \
        \( -name '*.tar' -o -name '*.tar.gz' \) \
        -print 2>/dev/null | sort)
}

verify_saved_images() {
    local dir_path="$1"
    local verified_count=0
    local failed_count=0
    [ -d "$dir_path" ] || {
        red "目录不存在: $dir_path"
        return 1
    }
    _check_docker || return 1
    _collect_backup_files "$dir_path"
    if [ "${#FOUND_BACKUP_FILES[@]}" -eq 0 ]; then
        red "目录中没有找到 .tar 或 .tar.gz 文件。"
        return 1
    fi
    cyan "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    cyan "  正在校验备份文件"
    cyan "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    for f in "${FOUND_BACKUP_FILES[@]}"; do
        local fname=""
        fname=$(basename "$f")
        printf '  校验: %s ... ' "$fname" >&2
        if docker load -i "$f" >/dev/null 2>&1; then
            verified_count=$((verified_count + 1))
            printf '%s✓ 有效%s\n' "$C_GREEN" "$C_RESET" >&2
        else
            failed_count=$((failed_count + 1))
            printf '%s✗ 异常%s\n' "$C_RED" "$C_RESET" >&2
        fi
    done
    printf '\n' >&2
    if [ "$failed_count" -eq 0 ]; then
        green "校验通过，共 ${verified_count} 个文件全部有效。"
    else
        red "校验完成：有效 ${verified_count} 个，异常 ${failed_count} 个。"
        return 1
    fi
    return 0
}

deploy_result() {
    local service_name="$1"
    local ip_addr="$2"
    local port_info="${3:-无}"
    local data_info="${4:-无}"
    local extra_info="${5:-}"
    local deploy_cmd="${6:-}"
    cyan "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    green "  ${service_name} 部署信息"
    cyan "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf '  %-12s %s\n' "IP 地址:"  "$ip_addr"  >&2
    printf '  %-12s %s\n' "端口:"     "$port_info" >&2
    printf '  %-12s %s\n' "数据目录:" "$data_info" >&2
    printf '\n' >&2
    if [ -n "$deploy_cmd" ]; then
        printf '  启动命令:\n' >&2
        printf '    %s\n' "$deploy_cmd" >&2
        printf '\n' >&2
    fi
    if [[ "$extra_info" == *password* ]] \
        || [[ "$extra_info" == *密码* ]] \
        || [[ "$extra_info" == *密钥* ]]; then
        red "  ⚠ 警告：包含敏感信息，请及时修改默认密码和密钥！"
        printf '\n' >&2
    fi
    green "  💡 建议：部署完成后请及时备份数据。"
    cyan "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

_append_unique_loaded_image() {
    local ref="$1"
    [ -n "$ref" ] || return 0
    local item=""
    for item in "${GLOBAL_LAST_LOADED_IMAGES[@]+"${GLOBAL_LAST_LOADED_IMAGES[@]}"}"; do
        [ "$item" = "$ref" ] && return 0
    done
    GLOBAL_LAST_LOADED_IMAGES+=("$ref")
}

_parse_load_output_images() {
    local text="$1"
    local line=""
    local ref=""
    while IFS= read -r line; do
        case "$line" in
            "Loaded image: "*)
                ref="${line#Loaded image: }"
                ref=$(_trim "$ref")
                [ -n "$ref" ] && _append_unique_loaded_image "$ref"
                ;;
            "Loaded image ID: "*)
                true
                ;;
        esac
    done <<< "$text"
}

_default_container_name() {
    local ref="$1"
    local base="$ref"
    base="${base%@*}"
    base="${base%:*}"
    base="${base##*/}"
    base=$(printf '%s' "$base" \
        | tr '[:upper:]' '[:lower:]' \
        | tr -cs 'a-z0-9_.-' '-' \
        | sed 's/^-//;s/-$//')
    [ -n "$base" ] || base="container"
    printf '%s-ctr\n' "$base"
}

_quote_cmd() {
    local out=""
    local arg=""
    for arg in "$@"; do
        out="${out}$(printf '%q ' "$arg")"
    done
    out="${out% }"
    printf '%s\n' "$out"
}

_get_exposed_ports() {
    local image_ref="$1"
    local raw=""
    raw=$(docker inspect --format='{{range $p, $conf := .Config.ExposedPorts}}{{$p}} {{end}}' \
        "$image_ref" 2>/dev/null) || true
    [ -z "$raw" ] && return 0
    local cp=""
    local seen=""
    for cp in $raw; do
        cp="${cp%/tcp}"
        cp="${cp%/udp}"
        printf -v seen '%s\n' "${seen}${cp}"
    done
    printf '%s' "$seen" | grep -E '^[0-9]+$' | sort -un || true
}

_parse_host_port() {
    local pp="$1"
    case "$pp" in
        *:*|*/*) printf '%s\n' "$pp"; return 0 ;;
    esac
    if printf '%s' "$pp" | grep -qE '^[0-9]+$'; then
        printf '%s\n' "${pp}:${pp}"
    else
        printf '%s\n' ""
    fi
}

_configure_port_mapping() {
    local image_ref="$1"
    local input_port="$2"
    local -a cmd_arr=("${@:3}")
    local -a exposed=()
    local ep=""
    while IFS= read -r ep; do
        [ -n "$ep" ] && exposed+=("$ep")
    done < <(_get_exposed_ports "$image_ref")

    local resolved=""
    resolved=$(_parse_host_port "$input_port")
    if [ -n "$resolved" ]; then
        cmd_arr+=(-p "$resolved")
        printf '%s\n' "${cmd_arr[*]}"
        return 0
    fi

    if [ "${#exposed[@]}" -eq 0 ]; then
        if [ -n "$input_port" ]; then
            cmd_arr+=(-p "$input_port")
        fi
        printf '%s\n' "${cmd_arr[*]}"
        return 0
    fi

    local mapped=()
    local hint=""
    hint=$(printf ', ' "${exposed[@]}")
    hint="${hint%, }"
    printf '  %s %b 内部端口:%s\n' "${C_CYAN}" "[信息]" "$hint" >&2

    if [ -z "$input_port" ]; then
        local s=8000 i=""
        for i in "${exposed[@]}"; do
            mapped+=(-p "${s}:${i}")
            s=$((s + 1))
        done
    elif printf '%s' "$input_port" | grep -qE '^[0-9]+-[0-9]+$'; then
        local start="${input_port%-*}" end="${input_port#*-}"
        local n=${#exposed[@]} range=$((end - start + 1))
        if [ "$range" -ge "$n" ]; then
            local ii=0 si="$start"
            for ii in $(seq 0 $((n - 1))); do
                mapped+=(-p "${si}:${exposed[$ii]}")
                si=$((si + 1))
            done
        else
            red "  范围 ${start}-${end} 包含 ${range} 个端口,不足容器 ${n} 个 EXPOSE 端口,跳过映射。"
        fi
    elif printf '%s' "$input_port" | grep -qE '^[0-9]+$'; then
        local base="$input_port" ii=""
        for ii in "${exposed[@]}"; do
            mapped+=(-p "${base}:${ii}")
            base=$((base + 1))
        done
    else
        local pp=""
        for pp in $(printf '%s\n' "$input_port" | tr ',' '\n'); do
            pp=$(_trim "$pp")
            resolved=$(_parse_host_port "$pp")
            [ -n "$resolved" ] && cmd_arr+=(-p "$resolved")
        done
    fi

    local ci=""
    for ci in "${mapped[@]+"${mapped[@]}"}"; do
        cmd_arr+=("$ci")
    done
    printf '%s\n' "${cmd_arr[*]}"
}

_get_local_ip() {
    local ip=""
    ip=$(hostname -I 2>/dev/null | awk '{print $1; exit}') || true
    [ -n "$ip" ] || ip=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}') || true
    [ -n "$ip" ] || ip=$(ifconfig 2>/dev/null | grep -Eo 'inet (addr:)?[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | grep -v '127.0.0.1' | head -1 | awk '{print $NF}') || true
    [ -n "$ip" ] || ip="localhost"
    printf '%s\n' "$ip"
}

_collect_local_unique_images() {
    GLOBAL_LAST_LOADED_IMAGES=()
    local refs_text=""
    refs_text=$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
        | grep -v '^<none>:' \
        | sort -u) || refs_text=""
    local line=""
    while IFS= read -r line; do
        [ -n "$line" ] && _append_unique_loaded_image "$line"
    done <<< "$refs_text"
}

_configure_and_run_containers() {
    local images_to_use=()
    if [ "${#GLOBAL_LAST_LOADED_IMAGES[@]}" -eq 0 ]; then
        _collect_local_unique_images
    fi
    images_to_use=("${GLOBAL_LAST_LOADED_IMAGES[@]+"${GLOBAL_LAST_LOADED_IMAGES[@]}"}")
    if [ "${#images_to_use[@]}" -eq 0 ]; then
        red "没有可用于启动的镜像。"
        return 1
    fi
    local idx=0
    local local_ip=""
    local_ip=$(_get_local_ip)
    for image_ref in "${images_to_use[@]}"; do
        [ -n "$image_ref" ] || continue
        idx=$((idx + 1))
        local short_repo="${image_ref%:*}"
        local short_tag="${image_ref##*:}"
        [ "$short_repo" = "$image_ref" ] && short_tag="latest"
        local default_name=""
        default_name=$(_default_container_name "$image_ref")
        local container_name=""
        local host_port=""
        local env_vars=""
        local volume_mounts=""
        local net_mode=""
        local restart_policy=""
        local run_now=""
        cyan "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        printf '  容器 %d: %s:%s\n' "$idx" "$short_repo" "$short_tag" >&2
        printf '\n' >&2
        _read_line container_name "  容器名称 [${default_name}]: "
        container_name="${container_name:-$default_name}"
        _read_line host_port "  主机端口映射 (如 8080:80，多个用逗号，留空跳过): "
        _read_line env_vars "  环境变量 (KEY=VAL,KEY2=VAL2，留空跳过): "
        _read_line volume_mounts "  数据卷 (/host:/container,/h2:/c2，留空跳过): "
        _read_line net_mode "  网络模式 [bridge]: "
        net_mode="${net_mode:-bridge}"
        _read_line restart_policy "  重启策略 (always/on-failure/no) [always]: "
        restart_policy="${restart_policy:-always}"
        local cmd=()
        cmd=($(_configure_port_mapping \
            "$image_ref" "$host_port" \
            docker run -d \
            --name "$container_name" \
            --network "$net_mode" \
            --restart "$restart_policy"))
        if [ -n "$env_vars" ]; then
            local env_parts=()
            IFS=',' read -r -a env_parts <<< "$env_vars"
            local ev=""
            for ev in "${env_parts[@]}"; do
                ev=$(_trim "$ev")
                [ -n "$ev" ] && cmd+=(-e "$ev")
            done
        fi
        if [ -n "$volume_mounts" ]; then
            local vol_parts=()
            IFS=',' read -r -a vol_parts <<< "$volume_mounts"
            local vm=""
            for vm in "${vol_parts[@]}"; do
                vm=$(_trim "$vm")
                [ -n "$vm" ] && cmd+=(-v "$vm")
            done
        fi
        cmd+=("$image_ref")
        local deploy_cmd_text=""
        deploy_cmd_text=$(_quote_cmd "${cmd[@]}")
        deploy_result \
            "${short_repo}" \
            "$local_ip" \
            "${host_port:-无}" \
            "${volume_mounts:-无}" \
            "${env_vars}" \
            "$deploy_cmd_text"
        printf '\n' >&2
        _read_line run_now "  立即执行该命令？(y/N): "
        case "$(_lower "$run_now")" in
            y|yes)
                yellow "  正在启动容器..."
                if "${cmd[@]}" >/dev/null 2>&1; then
                    green "  ✓ 容器 ${container_name} 已启动"
                else
                    red "  ✗ 启动失败，请检查端口、卷挂载、网络和镜像参数"
                fi
                ;;
            *)
                yellow "  已跳过，可稍后手动执行上方命令。"
                ;;
        esac
        printf '\n' >&2
    done
    cyan "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    green "  容器配置流程已完成。"
    cyan "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    return 0
}

restore_images() {
    _check_docker || return 1
    local backup_path="${GLOBAL_BACKUP_DIR:-$(pwd)}"
    local restore_all=""
    local selected_raw=""
    local selected_indices=""
    local chosen_files=()
    local load_errors=0
    local load_successes=0
    local fp=""
    local idx=0
    cyan "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    cyan "  从备份恢复 Docker 镜像"
    cyan "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [ ! -d "$backup_path" ]; then
        red "目录不存在: $backup_path"
        _read_line backup_path "请输入备份目录路径: "
    fi
    [ -d "$backup_path" ] || {
        red "目录不存在: $backup_path"
        press_any_key
        return 1
    }
    _collect_backup_files "$backup_path"
    if [ "${#FOUND_BACKUP_FILES[@]}" -eq 0 ]; then
        red "目录中没有找到 .tar 或 .tar.gz 文件。"
        press_any_key
        return 1
    fi
    yellow "找到的备份文件:"
    idx=0
    for fp in "${FOUND_BACKUP_FILES[@]}"; do
        idx=$((idx + 1))
        printf '  %d. %s  (%s)\n' "$idx" "$(basename "$fp")" "$(_get_hsize "$fp")" >&2
    done
    printf '\n' >&2
    _read_line restore_all "是否恢复所有文件？(y/N): "
    case "$(_lower "$restore_all")" in
        y|yes)
            chosen_files=("${FOUND_BACKUP_FILES[@]}")
            ;;
        *)
            _read_line selected_raw "请输入编号（如 1,3,5-8，q 返回）: "
            case "$(_lower "$selected_raw")" in
                q|quit)
                    return 0
                    ;;
                all|a)
                    chosen_files=("${FOUND_BACKUP_FILES[@]}")
                    ;;
                *)
                    selected_indices=$(_parse_indices "$selected_raw" "${#FOUND_BACKUP_FILES[@]}" 2>/dev/null) || true
                    if [ -z "$selected_indices" ]; then
                        red "没有有效的选项。"
                        press_any_key
                        return 1
                    fi
                    for idx in $selected_indices; do
                        chosen_files+=("${FOUND_BACKUP_FILES[$((idx - 1))]}")
                    done
                    ;;
            esac
            ;;
    esac
    if [ "${#chosen_files[@]}" -eq 0 ]; then
        red "没有选中任何文件。"
        press_any_key
        return 1
    fi
    GLOBAL_LAST_LOADED_IMAGES=()
    local total_chosen="${#chosen_files[@]}"
    idx=0
    for fp in "${chosen_files[@]}"; do
        idx=$((idx + 1))
        local fname=""
        fname=$(basename "$fp")
        yellow "[${idx}/${total_chosen}] 加载: ${fname}"
        local load_out=""
        if load_out=$(docker load -i "$fp" 2>&1); then
            load_successes=$((load_successes + 1))
            _parse_load_output_images "$load_out"
            green "  ✓ 已导入"
        else
            load_errors=$((load_errors + 1))
            red "  ✗ 加载失败: $fname"
            [ -n "$load_out" ] && printf '%s\n' "$load_out" >&2 || true
        fi
    done
    printf '\n' >&2
    cyan "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [ "$load_successes" -gt 0 ]; then
        green "  镜像加载完成，成功: ${load_successes}，失败: ${load_errors}。"
    else
        red "  没有成功加载任何镜像，请检查文件完整性。"
        press_any_key
        return 1
    fi
    [ "$load_errors" -gt 0 ] && red "  共 ${load_errors} 个文件加载失败。" || true
    cyan "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf '\n' >&2
    local start_now=""
    _read_line start_now "是否立即配置并启动容器？(y/N): "
    case "$(_lower "$start_now")" in
        y|yes)
            _configure_and_run_containers
            ;;
        *)
            yellow "可稍后手动执行 docker run 命令启动容器。"
            ;;
    esac
    press_any_key
}

show_local_images() {
    _check_docker || return 1
    local filter_result=""
    filter_result=$(_list_local_images "")
    cyan "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    cyan "  本机已拉取的 Docker 镜像"
    cyan "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [ -z "$filter_result" ]; then
        red "  未找到任何镜像。请先拉取镜像后重试。"
    else
        printf '\n' >&2
        printf '  %-45s %-15s %s\n' "仓库名称" "标签" "大小" >&2
        printf '  %-45s %-15s %s\n' \
            "─────────────────────────────────────────────" \
            "───────────────" \
            "──────" >&2
        while IFS=$'\t' read -r repo _id size; do
            [ -n "$repo" ] || continue
            local r="${repo%:*}"
            local t="${repo##*:}"
            [ "$r" = "$repo" ] && t="latest"
            printf '  %-45s %-15s %s\n' "$r" "$t" "$size" >&2
        done <<< "$filter_result"
    fi
    cyan "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    return 0
}

main_menu() {
    local choice=""
    local verify_dir=""
    while true; do
        printf '\n' >&2
        cyan "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        cyan "   Docker 镜像备份与恢复工具"
        printf '   %s系统: %s | 架构: %s%s\n' \
            "$C_CYAN" "$OS_NAME" "$OS_ARCH" "$C_RESET" >&2
        cyan "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        printf '\n' >&2
        printf '  1. 保存镜像到本地目录\n' >&2
        printf '  2. 从备份目录恢复镜像\n' >&2
        printf '  3. 校验备份文件有效性\n' >&2
        printf '  4. 查看本机镜像列表\n'  >&2
        printf '  0. 退出\n'               >&2
        printf '\n' >&2
        _read_line choice "请选择操作: "
        case "$choice" in
            1)
                GLOBAL_EXTRACT_DIR="$(pwd)/docker_images_$(date +%Y%m%d_%H%M%S)"
                extract_images || true
                ;;
            2)
                [ -n "$GLOBAL_BACKUP_DIR" ] || GLOBAL_BACKUP_DIR="$(pwd)"
                restore_images || true
                ;;
            3)
                _read_line verify_dir \
                    "请输入备份目录路径 [${GLOBAL_BACKUP_DIR:-$(pwd)}]: "
                [ -n "$verify_dir" ] || verify_dir="${GLOBAL_BACKUP_DIR:-$(pwd)}"
                verify_saved_images "$verify_dir" || true
                press_any_key
                ;;
            4)
                show_local_images || true
                press_any_key
                ;;
            0)
                green "感谢使用，再见！"
                _SCRIPT_EXITING=true
                exit 0
                ;;
            *)
                red "无效选项: '${choice}'，请重新选择。"
                ;;
        esac
    done
}

main() {
    setup_logging
    detect_os
    self_check
    if [ "$HAS_DOCKER" != "true" ]; then
        yellow "⚠ 未检测到 Docker，保存/恢复/校验/查看功能将不可用。"
        yellow "  安装文档: https://docs.docker.com/engine/install/"
    fi
    local net_status=""
    net_status=$(_detect_network)
    case "$net_status" in
        offline) yellow "⚠ 网络状态: 离线，在线功能将不可用。" ;;
        limited) yellow "⚠ 网络状态: 受限，部分在线功能可能不可用。" ;;
    esac
    main_menu
}

main "$@"
