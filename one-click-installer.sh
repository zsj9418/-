#!/usr/bin/env bash
set -uo pipefail
if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ] || \
   { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 3 ]; }; then
    echo "本脚本需要 bash 4.3 或更高版本(当前: ${BASH_VERSION:-unknown})"
    exit 1
fi
SCRIPT_VERSION="2.1"
HOME="${HOME:-/root}"
SCRIPT_DIR="${ONE_CLICK_DIR:-$HOME/one-click-scripts}"
LOG_FILE="$SCRIPT_DIR/installer.log"
LOG_MAX_SIZE=1048576
RETRY_COUNT=3
CACHE_TTL_MIN=1440
LOG_SCRIPT_OUTPUT="${LOG_SCRIPT_OUTPUT:-0}"
CUSTOM_MENU_FILE="$SCRIPT_DIR/custom_menu.conf"
FIRST_RUN_FLAG="$SCRIPT_DIR/.initialized"
SYMLINK_NAME="a"
PROXY_PREFIXES=(
    "https://un.ax18.ggff.net/"
    "https://cdn.yyds9527.nyc.mn/"
)
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m';  C_BOLD=$'\033[1m'
    C_RED=$'\033[31m';   C_GREEN=$'\033[32m';  C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m';  C_MAGENTA=$'\033[35m'; C_CYAN=$'\033[36m'
    C_WHITE=$'\033[37m'; C_GRAY=$'\033[90m'
else
    C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""
    C_BLUE=""; C_MAGENTA=""; C_CYAN=""; C_WHITE=""; C_GRAY=""
fi
REPO_RAW="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main"
declare -A DEFAULT_SCRIPTS=(
    ["1"]="$REPO_RAW/install_docker.sh"
    ["2"]="$REPO_RAW/install_tools.sh"
    ["3"]="$REPO_RAW/clean-system.sh"
    ["4"]="$REPO_RAW/device_info.sh"
    ["5"]="$REPO_RAW/setup_cronjob.sh"
    ["6"]="$REPO_RAW/singbox-manager.sh"
    ["7"]="$REPO_RAW/install_singbox_docker.sh"
    ["8"]="$REPO_RAW/install-sing-box-mihomo.sh"
    ["9"]="$REPO_RAW/setup-dae.sh"
    ["10"]="$REPO_RAW/dae_manager.sh"
    ["11"]="$REPO_RAW/setup_tun.sh"
    ["12"]="$REPO_RAW/install-subc.sh"
    ["13"]="$REPO_RAW/sub-store-deploy.sh"
    ["14"]="$REPO_RAW/set-dns.sh"
    ["15"]="$REPO_RAW/install_mosdns.sh"
    ["16"]="$REPO_RAW/install-adg.sh"
    ["17"]="$REPO_RAW/cloudflared-deploy.sh"
    ["18"]="$REPO_RAW/install-caddy.sh"
    ["19"]="$REPO_RAW/install_docker_ddns_go.sh"
    ["20"]="$REPO_RAW/ipwg.sh"
    ["21"]="$REPO_RAW/deploy_containers.sh"
    ["22"]="$REPO_RAW/install-alist.sh"
    ["23"]="$REPO_RAW/install-nexterm.sh"
    ["24"]="$REPO_RAW/install-rustdesk.sh"
    ["25"]="$REPO_RAW/install_docker_lucky.sh"
    ["26"]="$REPO_RAW/ql.sh"
    ["27"]="$REPO_RAW/install-nezha.sh"
    ["28"]="$REPO_RAW/install_siyuan.sh"
    ["29"]="$REPO_RAW/docker_sunpanel.sh"
    ["30"]="$REPO_RAW/casaos_installer.sh"
    ["31"]="$REPO_RAW/install-openapi.sh"
    ["32"]="$REPO_RAW/install-deploy_frigate.sh"
    ["33"]="$REPO_RAW/Shinobi.sh"
    ["34"]="$REPO_RAW/disk_repair_tool.sh"
    ["35"]="$REPO_RAW/auto_disk_mounter.sh"
    ["36"]="$REPO_RAW/disk_speed_test.sh"
    ["37"]="$REPO_RAW/pve-zfsswap.sh"
    ["38"]="$REPO_RAW/wifi-hotspot.sh"
    ["39"]="$REPO_RAW/4G-UFI_sim.sh"
    ["40"]="$REPO_RAW/manage_openwrt.sh"
    ["41"]="$REPO_RAW/netconfig.sh"
    ["42"]="$REPO_RAW/openclaw-manager.sh"
    ["43"]="$REPO_RAW/argon_beauty.sh"
    ["44"]="$REPO_RAW/pve_smart_migration.sh"
    ["45"]="$REPO_RAW/uninstall_histb.sh"
    ["46"]="$REPO_RAW/cpu-tool.sh"
    ["47"]="$REPO_RAW/Docker-image-backup.sh"
    ["48"]="$REPO_RAW/img-expand.sh"
    ["49"]="$REPO_RAW/netiso.sh"
    ["50"]="$REPO_RAW/install-yingshi.sh"
)
DEFAULT_OPTIONS=(
    "1. 安装 Docker"
    "2. 安装常用工具"
    "3. 清理系统垃圾"
    "4. 获取设备信息"
    "5. 配置定时任务"
    "6. 管理 Sing-box"
    "7. 部署 Docker 版 Sing-box"
    "8. 安装裸核 Sing-box 和 Mihomo"
    "9. 配置 dae"
    "10. 管理 dae"
    "11. 开启 tun 模式"
    "12. 安装 Subconverter"
    "13. 部署 Sub-Store"
    "14. 设置 DNS"
    "15. 安装 MosDNS"
    "16. 安装 AdGuard Home"
    "17. 安装 cloudflared"
    "18. 开启 Caddy 反代功能"
    "19. 安装 Docker 版 ddns-go"
    "20. 设备网关设置"
    "21. SSH 工具 & 测速容器"
    "22. 安装 Alist"
    "23. 安装 NexTerm"
    "24. Docker 部署 RustDesk"
    "25. 安装 Docker 版 Lucky"
    "26. 安装 Docker 版青龙面板"
    "27. 哪吒探针部署"
    "28. 安装思源笔记"
    "29. 安装 Sun-Panel"
    "30. CasaOS 部署"
    "31. 安装 OpenAPI"
    "32. 部署 Frigate 监控"
    "33. 部署 Shinobi 监控"
    "34. 硬盘修复 / 格式化工具"
    "35. 自动挂载外置硬盘"
    "36. 硬盘测速"
    "37. 设置虚拟内存"
    "38. 设置 WiFi 热点"
    "39. 4G-UFI 切卡管理"
    "40. 安装 Docker 版 OpenWrt"
    "41. OpenWrt 网口配置"
    "42. OpenClaw部署"
    "43. OpenWrt UI 界面美化"
    "44. PVE 智能存储迁移"
    "45. 海纳思内置卸载"
    "46. CPU频率仪表"
    "47. docker镜像备份还原"
    "48. pve中openwrt扩容"
    "49. openwrt设置VLAN"
    "50. 部署影视服务器"
    "98. 快捷键管理"
)
declare -A SCRIPTS=()
declare -A CUSTOM_SCRIPT_NAMES=()
declare -A MENU_TEXT_MAP=()
declare -A MENU_WIDTH_MAP=()
declare -a SORTED_IDS=()
OPTIONS=()
DOWNLOADED_PATH=""
DIRECT_OK=-1
SELF_PATH=""
UTF8_OK=0
OS=""
PKG_MANAGER=""
is_root()    { [ "$(id -u)" -eq 0 ]; }
is_openwrt() { [[ -f /etc/openwrt_release ]]; }
log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE" 2>/dev/null || true; }
pause() { read -rp "${1:-按回车键继续...}" _ || true; }
clear_screen() {
    [[ -t 1 ]] || return 0
    clear 2>/dev/null || printf '\033[2J\033[H'
}
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}
get_real_path() {
    local path="$1"
    if command -v realpath >/dev/null 2>&1; then
        realpath "$path" 2>/dev/null || echo "$path"
    elif command -v readlink >/dev/null 2>&1; then
        readlink -f "$path" 2>/dev/null || echo "$path"
    else
        echo "$path"
    fi
}
resolve_self() {
    local src="${BASH_SOURCE[0]:-$0}"
    if [[ -f "$src" && "$src" != /dev/* && "$src" != /proc/* ]]; then
        SELF_PATH="$(get_real_path "$src")"
    else
        SELF_PATH=""
    fi
}
usage() {
    cat <<EOF
一键脚本管理平台 v${SCRIPT_VERSION}
用法:
  $(basename "$0")          打开交互菜单
  $(basename "$0") <编号>   直接运行对应菜单项(如: $(basename "$0") 6)
  $(basename "$0") -v       显示版本
  $(basename "$0") -h       显示帮助
环境变量:
  ONE_CLICK_DIR       数据目录(默认 ~/one-click-scripts)
  LOG_SCRIPT_OUTPUT=1 同时记录子脚本输出到日志
EOF
}
setup_locale() {
    local cm loc
    cm="$(locale charmap 2>/dev/null || true)"
    if [[ "${cm^^}" == "UTF-8" ]]; then UTF8_OK=1; return 0; fi
    for loc in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8 zh_CN.UTF-8 zh_CN.utf8; do
        if LC_ALL="$loc" locale charmap 2>/dev/null | grep -qi 'utf-8'; then
            export LC_ALL="$loc"
            UTF8_OK=1
            return 0
        fi
    done
    UTF8_OK=0
}
str_display_width() {
    local s="$1" len=${#1} i ch code w=0
    for ((i = 0; i < len; i++)); do
        ch="${s:i:1}"
        printf -v code '%d' "'$ch" 2>/dev/null || code=65
        if (( UTF8_OK )); then
            if (( code >= 0x1100 && (
                  code <= 0x115F ||
                  (code >= 0x2E80  && code <= 0xA4CF)  ||
                  (code >= 0xAC00  && code <= 0xD7A3)  ||
                  (code >= 0xF900  && code <= 0xFAFF)  ||
                  (code >= 0xFE30  && code <= 0xFE4F)  ||
                  (code >= 0xFF00  && code <= 0xFF60)  ||
                  (code >= 0xFFE0  && code <= 0xFFE6)  ||
                  (code >= 0x1F300 && code <= 0x1F64F) ||
                  (code >= 0x1F900 && code <= 0x1F9FF) ||
                  (code >= 0x20000 && code <= 0x2FFFD) ||
                  (code >= 0x30000 && code <= 0x3FFFD)
                  ) )); then
                w=$((w + 2))
            else
                w=$((w + 1))
            fi
        else
            code=$((code & 0xFF))
            if (( code >= 0xE0 )); then
                w=$((w + 2))
            elif (( code >= 0x80 && code <= 0xBF )); then
                :
            else
                w=$((w + 1))
            fi
        fi
    done
    if [[ -n "${2:-}" ]]; then printf -v "$2" '%d' "$w"; else echo "$w"; fi
}
pad_right() {
    local s="$1" width="$2" cur pad
    str_display_width "$s" cur
    pad=$((width - cur))
    (( pad < 0 )) && pad=0
    printf -v "$3" '%s%*s' "$s" "$pad" ''
}
get_term_width() {
    local w
    w="$(tput cols 2>/dev/null)" || w=""
    [[ "$w" =~ ^[0-9]+$ ]] || w="${COLUMNS:-}"
    [[ "$w" =~ ^[0-9]+$ ]] || w="$(stty size 2>/dev/null | awk '{print $2}')"
    [[ "$w" =~ ^[0-9]+$ ]] && (( w > 0 )) || w=80
    echo "$w"
}
detect_os_pkg() {
    if [[ -f /etc/os-release ]]; then
        OS="$(. /etc/os-release 2>/dev/null; echo "${ID:-unknown}")"
    fi
    if   command -v opkg    >/dev/null 2>&1; then PKG_MANAGER="opkg"
    elif command -v apt-get >/dev/null 2>&1; then PKG_MANAGER="apt-get"
    elif command -v dnf     >/dev/null 2>&1; then PKG_MANAGER="dnf"
    elif command -v yum     >/dev/null 2>&1; then PKG_MANAGER="yum"
    elif command -v apk     >/dev/null 2>&1; then PKG_MANAGER="apk"
    elif command -v pacman  >/dev/null 2>&1; then PKG_MANAGER="pacman"
    else PKG_MANAGER=""
    fi
}
check_and_install_deps() {
    local missing=() cmd
    for cmd in curl wget tar; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if is_openwrt; then
        command -v nano >/dev/null 2>&1 || missing+=(nano)
    fi
    (( ${#missing[@]} == 0 )) && return 0
    detect_os_pkg
    echo "缺少以下依赖:${missing[*]}"
    if [[ -z "$PKG_MANAGER" ]]; then
        echo "无法检测包管理器,请手动安装:${missing[*]}"
        command -v curl >/dev/null 2>&1 && return 0 || return 1
    fi
    local SUDO=""
    if ! is_root && [[ "$PKG_MANAGER" != "opkg" ]]; then
        if command -v sudo >/dev/null 2>&1; then
            SUDO="sudo"
        else
            echo "需要 root 权限安装依赖,请使用 root 运行"
            command -v curl >/dev/null 2>&1 && return 0 || return 1
        fi
    fi
    echo "正在使用 $PKG_MANAGER 安装依赖..."
    case "$PKG_MANAGER" in
        apt-get) $SUDO apt-get update -qq; $SUDO apt-get install -y "${missing[@]}" ;;
        yum)     $SUDO yum install -y "${missing[@]}" ;;
        dnf)     $SUDO dnf install -y "${missing[@]}" ;;
        apk)     $SUDO apk add --no-cache "${missing[@]}" ;;
        pacman)  $SUDO pacman -Sy --noconfirm "${missing[@]}" ;;
        opkg)    opkg update; opkg install "${missing[@]}" ;;
    esac
    if ! command -v curl >/dev/null 2>&1; then
        echo "❌ curl 安装失败,无法继续"
        return 1
    fi
    for cmd in "${missing[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || echo "⚠️ 未能安装可选依赖: $cmd(部分子脚本可能受影响)"
    done
    return 0
}
init_dirs() {
    local d
    for d in "$SCRIPT_DIR" "$SCRIPT_DIR/core_scripts" "$SCRIPT_DIR/user_scripts"; do
        mkdir -p "$d" || { echo "无法创建目录:$d"; return 1; }
    done
    chmod 700 "$SCRIPT_DIR" 2>/dev/null || true
    touch "$LOG_FILE" "$CUSTOM_MENU_FILE" 2>/dev/null || {
        echo "无法创建必要文件"
        return 1
    }
}
check_network() {
    if curl -sSI --connect-timeout 5 --max-time 8 -o /dev/null \
            "https://raw.githubusercontent.com" 2>/dev/null; then
        DIRECT_OK=1; return 0
    fi
    DIRECT_OK=0; return 1
}
is_cache_fresh() {
    local f="$1" mtime now
    [[ -s "$f" ]] || return 1
    mtime="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || date -r "$f" +%s 2>/dev/null)" || return 1
    [[ "$mtime" =~ ^[0-9]+$ ]] || return 1
    now="$(date +%s)"
    (( now - mtime < CACHE_TTL_MIN * 60 ))
}
looks_like_html() {
    head -c 512 "$1" 2>/dev/null | grep -qiE '<!doctype html|<html'
}
get_cache_path() {
    local choice="$1" url="$2" base key
    base="${CUSTOM_SCRIPT_NAMES[$choice]:-}"
    [[ -z "$base" ]] && base="$(basename "${url%%\?*}")"
    base="${base//[^A-Za-z0-9._-]/_}"
    key="$(printf '%s' "$url" | cksum)"
    key="${key%% *}"
    echo "$SCRIPT_DIR/core_scripts/${choice}-${key}-${base}"
}
download_script() {
    local choice="$1"
    local url="${SCRIPTS[$choice]:-}"
    DOWNLOADED_PATH=""
    if [[ -z "$url" ]]; then
        echo "此选项没有对应的脚本 URL" >&2
        return 1
    fi
    if [[ ! "$url" =~ ^https?:// ]]; then
        local lp="${url/#\~/$HOME}"
        if [[ -f "$lp" ]]; then
            DOWNLOADED_PATH="$(get_real_path "$lp")"
            return 0
        fi
        echo "❌ 本地脚本不存在:$lp" >&2
        return 1
    fi
    local script_path tmp
    script_path="$(get_cache_path "$choice" "$url")"
    tmp="${script_path}.tmp.$$"
    if is_cache_fresh "$script_path"; then
        echo "使用本地缓存: $script_path"
        DOWNLOADED_PATH="$script_path"
        return 0
    fi
    [[ -f "$script_path" ]] && echo "缓存已过期,重新下载..."
    if (( DIRECT_OK != 1 )); then
        echo -n "检测网络连通性... "
        if check_network; then echo "直连可用"; else echo "直连不可用,将使用代理"; fi
    fi
    local urls_to_try=() proxy
    (( DIRECT_OK == 1 )) && urls_to_try+=("$url")
    if [[ "$url" == https://raw.githubusercontent.com/* || "$url" == https://github.com/* ]]; then
        for proxy in "${PROXY_PREFIXES[@]}"; do
            urls_to_try+=("${proxy}${url}")
        done
    fi
    (( ${#urls_to_try[@]} == 0 )) && urls_to_try+=("$url")
    local total=$(( ${#urls_to_try[@]} * RETRY_COUNT )) attempt=0 try_url i rc
    for try_url in "${urls_to_try[@]}"; do
        for ((i = 1; i <= RETRY_COUNT; i++)); do
            attempt=$((attempt + 1))
            echo "下载尝试 $attempt/$total: $try_url"
            curl -fsSL --connect-timeout 10 --max-time 60 "$try_url" -o "$tmp" 2>/dev/null
            rc=$?
            if (( rc == 0 )); then
                if [[ ! -s "$tmp" ]]; then
                    echo "下载文件为空,重试..."
                elif looks_like_html "$tmp"; then
                    echo "内容异常(疑似网页/错误页),重试..."
                else
                    mv -f "$tmp" "$script_path"
                    chmod +x "$script_path"
                    echo "下载成功 ✅"
                    log "下载成功: $script_path (来源: $try_url)"
                    DOWNLOADED_PATH="$script_path"
                    return 0
                fi
            else
                echo "curl 失败(退出码 $rc),重试 ($i/$RETRY_COUNT)..."
            fi
            rm -f "$tmp" 2>/dev/null
            (( i < RETRY_COUNT )) && sleep 2
        done
    done
    if [[ -s "$script_path" ]]; then
        echo "⚠️ 下载失败,改用过期缓存: $script_path"
        log "下载失败,使用过期缓存: $script_path"
        DOWNLOADED_PATH="$script_path"
        return 0
    fi
    echo "❌ 所有下载均失败,URL: $url" >&2
    echo "   提示:OpenWrt 请确认已安装 ca-bundle / libustream-* 以支持 HTTPS" >&2
    log "下载失败: choice=$choice url=$url"
    return 1
}
run_script() {
    local script_path="$1" first_line="" rc
    if [[ ! -f "$script_path" ]]; then
        echo "脚本文件不存在:$script_path"
        log "运行失败,文件不存在: $script_path"
        return 1
    fi
    chmod +x "$script_path" 2>/dev/null
    local cmd=(bash "$script_path")
    read -r first_line < "$script_path" || true
    case "$first_line" in
        '#!'*python*|'#!'*perl*|'#!'*node*|'#!'*ruby*|'#!'*php*) cmd=("$script_path") ;;
    esac
    log "开始运行: $script_path"
    trap ':' INT
    if [[ "$LOG_SCRIPT_OUTPUT" == "1" ]]; then
        "${cmd[@]}" 2>&1 | tee -a "$LOG_FILE"
        rc="${PIPESTATUS[0]}"
    else
        "${cmd[@]}"
        rc=$?
    fi
    trap - INT
    echo ""
    if (( rc == 0 )); then
        echo "✅ 脚本运行成功"
        log "运行成功: $script_path"
    elif (( rc == 130 )); then
        echo "⚠️ 脚本已被用户中断"
        log "运行被中断: $script_path"
    else
        echo "❌ 脚本运行失败(退出码: $rc),请查看日志: $LOG_FILE"
        log "运行失败(退出码: $rc): $script_path"
    fi
    return "$rc"
}
manage_logs() {
    [[ -f "$LOG_FILE" ]] || return 0
    local log_size
    log_size="$(wc -c < "$LOG_FILE" 2>/dev/null | tr -d '[:space:]')"
    log_size="${log_size:-0}"
    if (( log_size >= LOG_MAX_SIZE )); then
        local keep_size=$((LOG_MAX_SIZE / 2))
        tail -c "$keep_size" "$LOG_FILE" > "${LOG_FILE}.tmp" && \
            mv -f "${LOG_FILE}.tmp" "$LOG_FILE"
        log "日志已轮转,原大小: ${log_size} 字节"
    fi
}
shortcut_dirs() {
    if is_openwrt; then
        printf '%s\n' /usr/bin /bin "$HOME/.local/bin"
    else
        printf '%s\n' /usr/local/bin /usr/bin /bin "$HOME/.local/bin"
    fi
}
get_symlink_dir() {
    local d
    while IFS= read -r d; do
        mkdir -p "$d" 2>/dev/null || continue
        if [[ -w "$d" ]] || is_root; then
            echo "$d"
            return 0
        fi
    done < <(shortcut_dirs)
    return 1
}
warn_if_not_in_path() {
    case ":$PATH:" in
        *":$1:"*) ;;
        *) echo "⚠️ 目录 $1 不在 PATH 中,请把它加入 PATH 才能直接输入快捷键" ;;
    esac
}
add_script_shortcut() {
    [[ -f "$FIRST_RUN_FLAG" ]] && return 0
    if [[ -z "$SELF_PATH" ]]; then
        echo "提示:当前不是从本地文件运行(如管道/进程替换),已跳过快捷键设置。"
        echo "      可先保存再运行: curl -fsSL <脚本URL> -o ~/menu.sh && bash ~/menu.sh"
        return 0
    fi
    local chosen_dir
    chosen_dir="$(get_symlink_dir)" || {
        echo "没有可写目录,跳过快捷键设置"
        touch "$FIRST_RUN_FLAG"
        return 0
    }
    local link="${chosen_dir}/${SYMLINK_NAME}"
    if [[ -L "$link" && "$(get_real_path "$link")" == "$SELF_PATH" ]]; then
        echo "快捷键 '$SYMLINK_NAME' 已存在,可直接输入 '$SYMLINK_NAME' 启动本脚本"
        touch "$FIRST_RUN_FLAG"
        return 0
    fi
    if [[ -e "$link" || -L "$link" ]]; then
        echo "⚠️ $link 已存在且不是本脚本,为避免覆盖已跳过。"
        echo "   可在主菜单 98 中创建其它名称的快捷键。"
        touch "$FIRST_RUN_FLAG"
        return 0
    fi
    echo ""
    local ans
    echo -ne "是否创建快捷键 '$SYMLINK_NAME' 到 $chosen_dir?(回车=是,n=跳过): "
    read -r ans || ans="n"
    case "${ans:-y}" in
        n|N|no|NO)
            echo "已跳过快捷键设置"
            touch "$FIRST_RUN_FLAG"
            return 0
            ;;
    esac
    if ln -s "$SELF_PATH" "$link" 2>/dev/null && chmod +x "$SELF_PATH"; then
        echo "快捷键 '$SYMLINK_NAME' 创建成功,后续直接输入 '$SYMLINK_NAME' 即可启动"
        warn_if_not_in_path "$chosen_dir"
    else
        echo "快捷键创建失败(可能权限不足),可手动执行:"
        echo "  ln -s '$SELF_PATH' '$link'"
    fi
    touch "$FIRST_RUN_FLAG"
}
list_shortcuts_for() {
    local target="$1" d link found=0 rd
    local -A seen=()
    while IFS= read -r d; do
        [[ -d "$d" ]] || continue
        rd="$(get_real_path "$d")"
        [[ -n "${seen[$rd]+_}" ]] && continue
        seen["$rd"]=1
        for link in "$d"/*; do
            [[ -L "$link" ]] || continue
            if [[ "$(get_real_path "$link")" == "$target" ]]; then
                echo "  ${link##*/} -> $target   ($d)"
                found=1
            fi
        done
    done < <(shortcut_dirs)
    (( found )) || echo "  (暂无)"
}
delete_shortcut() {
    local name="$1" target="$2" d link deleted=0
    while IFS= read -r d; do
        link="$d/$name"
        [[ -L "$link" ]] || continue
        [[ "$(get_real_path "$link")" == "$target" ]] || continue
        if rm -f "$link" 2>/dev/null || { command -v sudo >/dev/null 2>&1 && sudo rm -f "$link" 2>/dev/null; }; then
            echo "已删除快捷键 '$name' ($d)"
            deleted=1
        fi
    done < <(shortcut_dirs)
    (( deleted )) || echo "未找到指向当前脚本的快捷键 '$name'"
}
manage_symlink() {
    local choice
    while true; do
        clear_screen
        echo "========================================"
        echo "           快捷键管理"
        echo "========================================"
        echo "1. 管理当前脚本快捷键"
        echo "2. 绑定指定脚本到快捷键"
        echo "0. 返回主菜单"
        echo "----------------------------------------"
        read -rp "请输入选项编号: " choice || break
        case "$choice" in
            1) manage_current_script_symlink "$SELF_PATH" ;;
            2) bind_script_to_shortcut ;;
            0) break ;;
            *) echo "无效选项"; sleep 1 ;;
        esac
    done
}
manage_current_script_symlink() {
    local current_script="$1" choice shortcut link symlink_dir
    if [[ -z "$current_script" ]]; then
        echo "当前不是从本地文件运行,无法管理快捷键。请先把脚本保存为文件再运行。"
        pause "按回车键返回..."
        return 1
    fi
    symlink_dir="$(get_symlink_dir)" || {
        echo "未找到可写目录"
        pause "按回车键返回..."
        return 1
    }
    while true; do
        clear_screen
        echo "========================================"
        echo "    管理当前脚本快捷键"
        echo "========================================"
        echo "当前脚本: $current_script"
        echo "创建目录: $symlink_dir"
        echo ""
        echo "当前已创建的快捷键:"
        list_shortcuts_for "$current_script"
        echo ""
        echo "1. 创建新快捷键"
        echo "2. 删除快捷键"
        echo "0. 返回上级"
        read -rp "请输入选项编号: " choice || break
        case "$choice" in
            1)
                read -rp "请输入快捷键名称(仅字母数字): " shortcut
                if [[ ! "$shortcut" =~ ^[a-zA-Z0-9]+$ ]]; then
                    echo "快捷键只能含字母和数字"; sleep 1; continue
                fi
                link="$symlink_dir/$shortcut"
                if [[ -e "$link" || -L "$link" ]]; then
                    echo "快捷键已存在,请换一个名称"; sleep 1; continue
                fi
                if ln -s "$current_script" "$link" 2>/dev/null; then
                    echo "✅ 快捷键 '$shortcut' 创建成功"
                    warn_if_not_in_path "$symlink_dir"
                elif command -v sudo >/dev/null 2>&1 && sudo ln -s "$current_script" "$link" 2>/dev/null; then
                    echo "✅ 快捷键 '$shortcut' 创建成功(使用了 sudo)"
                else
                    echo "❌ 创建失败,请检查权限"
                fi
                pause
                ;;
            2)
                read -rp "请输入要删除的快捷键名称: " shortcut
                if [[ ! "$shortcut" =~ ^[a-zA-Z0-9]+$ ]]; then
                    echo "名称无效"; sleep 1; continue
                fi
                delete_shortcut "$shortcut" "$current_script"
                pause
                ;;
            0) break ;;
            *) echo "无效选项"; sleep 1 ;;
        esac
    done
}
bind_script_to_shortcut() {
    local script_path first_line ans shortcut symlink_dir link
    while true; do
        clear_screen
        echo "========================================"
        echo "    绑定指定脚本到快捷键"
        echo "========================================"
        read -rp "请输入脚本的完整路径(0=返回): " script_path || break
        script_path="$(trim "$script_path")"
        [[ "$script_path" == "0" ]] && break
        script_path="${script_path/#\~/$HOME}"
        script_path="$(get_real_path "$script_path")"
        if [[ ! -f "$script_path" ]]; then
            echo "文件不存在: $script_path"; sleep 1; continue
        fi
        read -r first_line < "$script_path" || true
        if [[ ! "$first_line" =~ ^#! ]]; then
            echo "警告:文件没有 shebang,可能不是有效脚本"
            read -rp "仍然继续?[y/N]: " ans
            [[ "${ans:-n}" == [yY] ]] || continue
        fi
        read -rp "请输入快捷键名称(仅字母数字): " shortcut
        if [[ ! "$shortcut" =~ ^[a-zA-Z0-9]+$ ]]; then
            echo "快捷键只能含字母和数字"; sleep 1; continue
        fi
        symlink_dir="$(get_symlink_dir)" || { echo "未找到可写目录"; sleep 1; continue; }
        link="$symlink_dir/$shortcut"
        if [[ -e "$link" || -L "$link" ]]; then
            echo "快捷键 '$shortcut' 已存在"; sleep 1; continue
        fi
        if ln -s "$script_path" "$link" && chmod +x "$script_path"; then
            echo "✅ 成功: $link -> $script_path"
            warn_if_not_in_path "$symlink_dir"
        else
            echo "❌ 创建失败,可尝试手动执行:"
            echo "   ln -s '$script_path' '$link'"
        fi
        pause
        break
    done
}
is_reserved_id() { [[ "$1" == "0" || "$1" == "98" || "$1" == "99" ]]; }
get_next_custom_menu_id() {
    local max_id=0 opt num id rest
    for opt in "${DEFAULT_OPTIONS[@]}"; do
        num="${opt%%.*}"
        [[ "$num" =~ ^[0-9]+$ ]] || continue
        is_reserved_id "$num" && continue
        (( num > max_id )) && max_id=$num
    done
    while IFS='|' read -r id rest || [[ -n "$id" ]]; do
        [[ "$id" =~ ^[0-9]+$ ]] || continue
        id=$((10#$id))
        is_reserved_id "$id" && continue
        (( id > max_id )) && max_id=$id
    done < <(cat "$CUSTOM_MENU_FILE" 2>/dev/null)
    local next=$((max_id + 1))
    (( next == 98 || next == 99 )) && next=100
    echo "$next"
}
load_menu() {
    OPTIONS=(); SCRIPTS=(); CUSTOM_SCRIPT_NAMES=()
    MENU_TEXT_MAP=(); MENU_WIDTH_MAP=(); SORTED_IDS=()
    local -A seen_ids=()
    local all_ids=() opt num text id name url script_name
    _reg() {
        seen_ids["$1"]=1
        OPTIONS+=("$1. $2")
        all_ids+=("$1")
        MENU_TEXT_MAP["$1"]="$2"
        str_display_width "$2" "_w"
        MENU_WIDTH_MAP["$1"]="$_w"
        SCRIPTS["$1"]="$3"
        CUSTOM_SCRIPT_NAMES["$1"]="$4"
    }
    for opt in "${DEFAULT_OPTIONS[@]}"; do
        num="${opt%%.*}"
        [[ -n "${seen_ids[$num]+_}" ]] && continue
        text="${opt#*.}"; text="${text# }"
        if [[ -v DEFAULT_SCRIPTS["$num"] ]]; then
            _reg "$num" "$text" "${DEFAULT_SCRIPTS[$num]}" "$(basename "${DEFAULT_SCRIPTS[$num]}")"
        else
            _reg "$num" "$text" "" ""
        fi
    done
    while IFS='|' read -r id name url script_name || [[ -n "$id" ]]; do
        [[ -z "$id" || "$id" == \#* ]] && continue
        [[ "$id" =~ ^[0-9]+$ ]] || continue
        id=$((10#$id))
        is_reserved_id "$id" && continue
        [[ -n "${seen_ids[$id]+_}" ]] && continue
        [[ -z "$name" || -z "$url" ]] && continue
        _reg "$id" "$name" "$url" "${script_name:-custom_${id}.sh}"
    done < <(cat "$CUSTOM_MENU_FILE" 2>/dev/null)
    [[ -z "${seen_ids[99]+_}" ]] && { OPTIONS+=("99. 管理自定义菜单"); SCRIPTS["99"]=""; }
    [[ -z "${seen_ids[0]+_}"  ]] && { OPTIONS+=("0. 退出");            SCRIPTS["0"]=""; }
    unset -f _reg
    local normal_ids=() i
    for i in "${all_ids[@]}"; do
        is_reserved_id "$i" && continue
        normal_ids+=("$i")
    done
    mapfile -t SORTED_IDS < <(printf '%s\n' "${normal_ids[@]}" | sort -n)
}
normalize_script_source() {
    local in="$1" lp
    if [[ "$in" =~ ^https?://[^[:space:]]+$ ]]; then
        printf '%s' "$in"; return 0
    fi
    lp="${in/#\~/$HOME}"
    if [[ -f "$lp" ]]; then
        get_real_path "$lp" | tr -d '\n'; return 0
    fi
    return 1
}
valid_menu_id() { [[ "$1" =~ ^[0-9]+$ ]]; }
add_custom_item() {
    local next_id name url script_name
    next_id="$(get_next_custom_menu_id)"
    read -rp "请输入菜单名称: " name
    name="$(trim "$name")"; name="${name//|/／}"
    [[ -z "$name" ]] && { echo "名称不能为空"; return 1; }
    read -rp "请输入脚本 URL 或本地路径: " url
    url="$(trim "$url")"
    [[ -z "$url" ]] && { echo "URL 不能为空"; return 1; }
    url="$(normalize_script_source "$url")" || {
        echo "❌ 必须是 http(s):// 链接,或已存在的本地文件"; return 1; }
    [[ "$url" == *"|"* ]] && { echo "❌ 地址中不能包含 '|'"; return 1; }
    script_name="$(printf '%s' "$name" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]').sh"
    [[ "$script_name" == ".sh" ]] && script_name="custom_${next_id}.sh"
    [[ -s "$CUSTOM_MENU_FILE" && -n "$(tail -c1 "$CUSTOM_MENU_FILE")" ]] && echo >> "$CUSTOM_MENU_FILE"
    printf '%s|%s|%s|%s\n' "$next_id" "$name" "$url" "$script_name" >> "$CUSTOM_MENU_FILE"
    echo "✅ 已添加菜单项 $next_id: $name"
}
delete_custom_item() {
    local id tmp="${CUSTOM_MENU_FILE}.tmp"
    read -rp "请输入要删除的菜单项编号: " id
    id="$(trim "$id")"
    valid_menu_id "$id" || { echo "编号无效"; return 1; }
    if grep -q "^${id}|" "$CUSTOM_MENU_FILE" 2>/dev/null; then
        grep -v "^${id}|" "$CUSTOM_MENU_FILE" > "$tmp" || true
        mv -f "$tmp" "$CUSTOM_MENU_FILE"
        echo "✅ 已删除菜单项 $id"
    else
        echo "未找到编号 $id 的菜单项"
    fi
}
edit_custom_item() {
    local id line old_id old_name old_url old_sn name url l tmp="${CUSTOM_MENU_FILE}.tmp"
    read -rp "请输入要修改的菜单项编号: " id
    id="$(trim "$id")"
    valid_menu_id "$id" || { echo "编号无效"; return 1; }
    line="$(grep -m1 "^${id}|" "$CUSTOM_MENU_FILE" 2>/dev/null)" || { echo "未找到编号 $id 的菜单项"; return 1; }
    IFS='|' read -r old_id old_name old_url old_sn <<< "$line"
    read -rp "新名称(回车保持 [$old_name]): " name
    name="$(trim "$name")"; name="${name//|/／}"
    [[ -z "$name" ]] && name="$old_name"
    read -rp "新 URL/路径(回车保持 [$old_url]): " url
    url="$(trim "$url")"
    if [[ -z "$url" ]]; then
        url="$old_url"
    else
        url="$(normalize_script_source "$url")" || { echo "❌ 地址无效"; return 1; }
        [[ "$url" == *"|"* ]] && { echo "❌ 地址中不能包含 '|'"; return 1; }
    fi
    while IFS= read -r l || [[ -n "$l" ]]; do
        if [[ "$l" == "${id}|"* ]]; then
            printf '%s|%s|%s|%s\n' "$id" "$name" "$url" "${old_sn:-custom_${id}.sh}"
        else
            printf '%s\n' "$l"
        fi
    done < "$CUSTOM_MENU_FILE" > "$tmp" && mv -f "$tmp" "$CUSTOM_MENU_FILE"
    echo "✅ 已修改菜单项 $id"
}
clear_script_cache() {
    local n
    n="$(find "$SCRIPT_DIR/core_scripts" -type f 2>/dev/null | wc -l | tr -d '[:space:]')"
    rm -f "$SCRIPT_DIR"/core_scripts/* 2>/dev/null
    echo "✅ 已清除 ${n:-0} 个缓存脚本,下次运行将重新下载最新版本"
    log "手动清除脚本缓存 (${n:-0} 个)"
}
manage_custom_menu() {
    local choice id name url script_name count
    while true; do
        clear_screen
        echo "========================================"
        echo "          自定义菜单管理"
        echo "========================================"
        echo "当前自定义菜单选项:"
        count=0
        while IFS='|' read -r id name url script_name || [[ -n "$id" ]]; do
            [[ -z "$id" || "$id" == \#* ]] && continue
            echo "  $id. $name  [$url]"
            count=$((count + 1))
        done < <(cat "$CUSTOM_MENU_FILE" 2>/dev/null)
        (( count == 0 )) && echo "  (暂无自定义菜单项)"
        echo "----------------------------------------"
        echo "1. 添加菜单选项"
        echo "2. 删除菜单选项"
        echo "3. 修改菜单选项"
        echo "4. 清除脚本缓存(强制更新)"
        echo "0. 返回主菜单"
        echo "----------------------------------------"
        read -rp "请输入选项编号: " choice || break
        case "$choice" in
            1) add_custom_item;    pause ;;
            2) delete_custom_item; pause ;;
            3) edit_custom_item;   pause ;;
            4) clear_script_cache; pause ;;
            0) break ;;
            *) echo "无效选项"; sleep 1 ;;
        esac
    done
}
print_menu() {
    clear_screen
    local term_width line_width line
    term_width="$(get_term_width)"
    line_width="$term_width"
    (( line_width > 100 )) && line_width=100
    (( line_width < 40 ))  && line_width=40
    printf -v line '%*s' "$line_width" ''
    line="${line// /=}"
    local total=${#SORTED_IDS[@]} max_text_w=0 id w
    for id in "${SORTED_IDS[@]}"; do
        w="${MENU_WIDTH_MAP[$id]:-0}"
        (( w > max_text_w )) && max_text_w=$w
    done
    local cell_width=$((4 + max_text_w)) gap=3 col_count=1 c
    for c in 2 3 4 5; do
        if (( 1 + cell_width * c + gap * (c - 1) <= term_width )); then
            col_count=$c
        else
            break
        fi
    done
    echo "${C_BOLD}${line}${C_RESET}"
    echo "${C_BOLD}     🚀 一键脚本管理平台 v${SCRIPT_VERSION} 🚀${C_RESET}"
    is_root || echo "  ${C_YELLOW}⚠️ 当前非 root 用户,部分脚本可能因权限不足失败${C_RESET}"
    echo "${C_BOLD}${line}${C_RESET}"
    local idx=0 row id_part text_part gapstr
    printf -v gapstr '%*s' "$gap" ''
    while (( idx < total )); do
        row=" "
        for ((c = 0; c < col_count && idx < total; c++, idx++)); do
            id="${SORTED_IDS[$idx]}"
            printf -v id_part '%2s.' "$id"
            pad_right "${MENU_TEXT_MAP[$id]}" "$max_text_w" text_part
            (( c > 0 )) && row+="$gapstr"
            row+="${C_CYAN}${id_part}${C_RESET} ${text_part}"
        done
        printf '%s\n' "$row"
    done
    echo "${C_BOLD}${line}${C_RESET}"
    echo "  ${C_YELLOW}98.${C_RESET} 快捷键管理  ${C_YELLOW}99.${C_RESET} 自定义菜单  ${C_RED}0.${C_RESET} 退出"
    echo "${C_BOLD}${line}${C_RESET}"
}
run_choice() {
    local choice="$1" url
    if [[ ! -v SCRIPTS["$choice"] ]]; then
        echo "无效选项:$choice"
        return 2
    fi
    url="${SCRIPTS[$choice]}"
    if [[ -z "$url" ]]; then
        echo "该选项是内部功能,请重新选择"
        return 2
    fi
    manage_logs
    if download_script "$choice"; then
        run_script "$DOWNLOADED_PATH"
        return $?
    fi
    echo ""
    echo "❌ 下载失败,请检查以上错误信息或网络状态"
    log "下载失败: choice=$choice"
    return 1
}
main() {
    case "${1:-}" in
        -h|--help)    usage; exit 0 ;;
        -v|--version) echo "v${SCRIPT_VERSION}"; exit 0 ;;
    esac
    setup_locale
    resolve_self
    init_dirs              || exit 1
    check_and_install_deps || exit 1
    manage_logs
    if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
        load_menu
        run_choice "$((10#$1))"
        exit $?
    fi
    add_script_shortcut
    local choice rc
    while true; do
        load_menu
        print_menu
        read -rp "请输入选项编号: " choice || { echo; echo "再见!"; exit 0; }
        choice="${choice//[[:space:]]/}"
        [[ "$choice" =~ ^[0-9]{1,6}$ ]] && choice=$((10#$choice))
        case "$choice" in
            0)
                echo "再见!"
                exit 0
                ;;
            98) manage_symlink ;;
            99) manage_custom_menu ;;
            ''|*[!0-9]*)
                echo "请输入有效数字"
                sleep 1
                ;;
            *)
                run_choice "$choice"; rc=$?
                if (( rc == 2 )); then
                    sleep 1
                else
                    echo ""
                    pause "按回车键返回主菜单..."
                fi
                ;;
        esac
    done
}
main "$@"
