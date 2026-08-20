#!/bin/bash
set -uo pipefail
IS_CRON=0
DRY_RUN=0
AGGRESSIVE=0
NOTIFY_ONLY=0
NOTIFIED=0
WECOM_WEBHOOK="${WECOM_WEBHOOK:-}"
LOG_FILE="/var/log/clean-system.log"
CRON_LOG="/var/log/clean-cron.log"
LOCK_FILE="/var/lock/clean-system.lock"
CRON_D_FILE="/etc/cron.d/clean-system"
WECOM_CONF="/etc/clean-system-wecom.conf"
STATS_FREED_BYTES=0
STATS_SPACE_BEFORE=""
STATS_SPACE_AFTER=""
STATS_HOSTNAME=""
STATS_OS=""
STATS_START_TIME=""
STATS_MODULES_LOG=""
STATS_STATUS="success"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
[[ -d /opt/homebrew/bin ]] && export PATH="/opt/homebrew/bin:$PATH"
[[ -d /usr/local/opt/coreutils/libexec/gnubin ]] && export PATH="/usr/local/opt/coreutils/libexec/gnubin:$PATH"
_color() { [[ $IS_CRON -eq 1 ]] && { echo "$2"; return; }; echo -e "\033[${1}m${2}\033[0m"; }
red()    { _color 31 "$*"; }
green()  { _color 32 "$*"; }
yellow() { _color 33 "$*"; }
cyan()   { _color 36 "$*"; }
bold()   { _color 1  "$*"; }
info()    { echo "  >> $*"; }
success() { green "  [OK] $*"; }
skip()    { yellow "  [--] $*"; }
warn()    { yellow "  [!!] $*"; }
resolve_self() {
    local self="${BASH_SOURCE[0]:-$0}"
    if command -v realpath &>/dev/null; then
        realpath "$self" 2>/dev/null && return
    fi
    if command -v readlink &>/dev/null; then
        readlink -f "$self" 2>/dev/null && return
    fi
    echo "$self"
}
SCRIPT_PATH="$(resolve_self)"
acquire_lock() {
    if command -v flock &>/dev/null; then
        mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || LOCK_FILE="/tmp/clean-system.lock"
        exec 9>"$LOCK_FILE" 2>/dev/null || { LOCK_FILE="/tmp/clean-system.lock"; exec 9>"$LOCK_FILE"; }
        if ! flock -n 9; then
            [[ $IS_CRON -eq 1 ]] && echo "$(date '+%F %T') 另一实例正在运行，退出" >> "$CRON_LOG"
            [[ $IS_CRON -eq 0 ]] && red "另一实例正在运行 (锁: $LOCK_FILE)"
            exit 0
        fi
    else
        if [[ -f "$LOCK_FILE" ]]; then
            local oldpid
            oldpid=$(cat "$LOCK_FILE" 2>/dev/null)
            if [[ "$oldpid" =~ ^[0-9]+$ ]] && kill -0 "$oldpid" 2>/dev/null; then
                [[ $IS_CRON -eq 0 ]] && red "另一实例正在运行 (PID $oldpid)"
                exit 0
            fi
        fi
        echo "$$" > "$LOCK_FILE" 2>/dev/null || true
        trap 'rm -f "$LOCK_FILE" 2>/dev/null' EXIT
    fi
}
init_log() {
    local log_dir
    log_dir="$(dirname "$LOG_FILE")"
    [[ -w "$log_dir" ]] || LOG_FILE="/tmp/clean-system.log"
    touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/clean-system.log"
    if [[ $IS_CRON -eq 1 ]]; then
        exec >> "$LOG_FILE" 2>&1
    else
        if command -v tee &>/dev/null; then
            exec > >(tee -a "$LOG_FILE") 2>&1
        else
            exec >> "$LOG_FILE" 2>&1
        fi
    fi
    STATS_START_TIME=$(date '+%Y-%m-%d %H:%M:%S')
    echo "========== $STATS_START_TIME 开始 (PID=$$, MODE=$([[ $IS_CRON -eq 1 ]] && echo cron || echo interactive)) =========="
    [[ $IS_CRON -eq 0 ]] && green "日志: $LOG_FILE"
}
bytes_to_human() {
    local bytes="${1:-0}"
    [[ "$bytes" =~ ^-?[0-9]+$ ]] || { echo "0 B"; return; }
    (( bytes < 0 )) && bytes=0
    if (( bytes >= 1073741824 )); then
        local g=$(( bytes / 1073741824 ))
        local gd=$(( (bytes % 1073741824) * 100 / 1073741824 ))
        printf "%d.%02d GB" "$g" "$gd"
    elif (( bytes >= 1048576 )); then
        local m=$(( bytes / 1048576 ))
        local md=$(( (bytes % 1048576) * 100 / 1048576 ))
        printf "%d.%02d MB" "$m" "$md"
    elif (( bytes >= 1024 )); then
        local k=$(( bytes / 1024 ))
        printf "%d KB" "$k"
    else
        printf "%d B" "$bytes"
    fi
}
get_dir_size() {
    local dir="${1:-}"
    [[ -d "$dir" ]] || { echo 0; return; }
    local size=0
    if size=$(du -sb "$dir" 2>/dev/null | awk '{print $1}') && [[ "$size" =~ ^[0-9]+$ ]]; then
        echo "$size"
    elif size=$(du -sk "$dir" 2>/dev/null | awk '{print $1 * 1024}') && [[ "$size" =~ ^[0-9]+$ ]]; then
        echo "$size"
    else
        echo 0
    fi
}
get_file_size() {
    local f="${1:-}"
    [[ -f "$f" ]] || { echo 0; return; }
    local size=0
    if size=$(stat -c%s "$f" 2>/dev/null) && [[ "$size" =~ ^[0-9]+$ ]]; then
        echo "$size"
    elif size=$(stat -f%z "$f" 2>/dev/null) && [[ "$size" =~ ^[0-9]+$ ]]; then
        echo "$size"
    elif size=$(wc -c < "$f" 2>/dev/null | tr -d ' ') && [[ "$size" =~ ^[0-9]+$ ]]; then
        echo "$size"
    else
        echo 0
    fi
}
get_root_avail() { df -h / 2>/dev/null | awk 'NR==2 {print $4}' || echo "N/A"; }
get_root_avail_bytes() {
    local avail=0
    if avail=$(df -B1 / 2>/dev/null | awk 'NR==2 {print $4}') && [[ "$avail" =~ ^[0-9]+$ ]]; then
        echo "$avail"; return
    fi
    if avail=$(df -k / 2>/dev/null | awk 'NR==2 {print $4}') && [[ "$avail" =~ ^[0-9]+$ ]]; then
        echo $(( avail * 1024 )); return
    fi
    echo 0
}
get_root_total() {
    local total=0
    if total=$(df -B1 / 2>/dev/null | awk 'NR==2 {print $2}') && [[ "$total" =~ ^[0-9]+$ ]]; then
        echo "$total"; return
    fi
    if total=$(df -k / 2>/dev/null | awk 'NR==2 {print $2}') && [[ "$total" =~ ^[0-9]+$ ]]; then
        echo $(( total * 1024 )); return
    fi
    echo 0
}
get_root_use_percent() { df / 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%' || echo "N/A"; }
safe_exec() {
    if [[ $DRY_RUN -eq 1 ]]; then
        yellow "  [DRY] $*"
    else
        eval "$@" 2>/dev/null || true
    fi
}
append_module_stat() {
    local module="$1"
    local freed_bytes="${2:-0}"
    local note="${3:-}"
    [[ "$freed_bytes" =~ ^[0-9]+$ ]] || freed_bytes=0
    STATS_FREED_BYTES=$(( STATS_FREED_BYTES + freed_bytes ))
    local human
    human=$(bytes_to_human "$freed_bytes")
    if (( freed_bytes > 0 )); then
        STATS_MODULES_LOG="${STATS_MODULES_LOG}• ${module}: 释放 ${human}"
        [[ -n "$note" ]] && STATS_MODULES_LOG="${STATS_MODULES_LOG} (${note})"
        STATS_MODULES_LOG="${STATS_MODULES_LOG}\n"
    fi
}
_wecom_valid_url() {
    local url="${1:-}"
    [[ "$url" =~ ^https://qyapi\.weixin\.qq\.com/cgi-bin/webhook/send\?key= ]]
}
_wecom_send() {
    local payload="$1"
    local url="$WECOM_WEBHOOK"
    if command -v curl &>/dev/null; then
        curl -s -S --connect-timeout 10 --max-time 30 -H "Content-Type: application/json" -d "$payload" "$url" 2>/dev/null
        return $?
    elif command -v wget &>/dev/null; then
        wget -q -O- --timeout=30 --header="Content-Type: application/json" --post-data="$payload" "$url" 2>/dev/null
        return $?
    else
        warn "企业微信通知: 未找到 curl/wget，跳过发送"
        return 1
    fi
}
send_wecom_notify() {
    local status="${1:-success}"
    if [[ $NOTIFIED -eq 1 ]]; then
        [[ $IS_CRON -eq 0 ]] && skip "通知已发送，跳过重复发送"
        return 0
    fi
    if [[ -z "$WECOM_WEBHOOK" ]]; then
        [[ $IS_CRON -eq 0 ]] && skip "WECOM_WEBHOOK 未配置，跳过通知"
        NOTIFIED=1
        return 0
    fi
    if ! _wecom_valid_url "$WECOM_WEBHOOK"; then
        warn "WECOM_WEBHOOK 格式不正确，跳过通知"
        NOTIFIED=1
        return 1
    fi
    local hostname="${STATS_HOSTNAME:-$(hostname 2>/dev/null || echo 'unknown')}"
    local os_info="${STATS_OS:-unknown}"
    local end_time
    end_time=$(date '+%Y-%m-%d %H:%M:%S')
    local freed_human
    freed_human=$(bytes_to_human "$STATS_FREED_BYTES")
    local use_pct
    use_pct=$(get_root_use_percent)
    local total_human
    total_human=$(bytes_to_human "$(get_root_total)")
    local icon title
    case "$status" in
        success) icon="✅"; title="系统清理完成通知" ;;
        failed)  icon="❌"; title="系统清理异常通知" ;;
        test)    icon="🔔"; title="企业微信通知测试" ;;
        *)       icon="ℹ️"; title="系统清理通知" ;;
    esac
    local modules_section=""
    if [[ -n "$STATS_MODULES_LOG" ]]; then
        local module_lines
        module_lines=$(echo -e "$STATS_MODULES_LOG" | head -8)
        modules_section="\n**清理明细:**\n${module_lines}"
    fi
    local log_hint="日志: \`${LOG_FILE}\`"
    local content
    content="${icon} **${title}**

> **主机:** ${hostname}
> **系统:** ${os_info}
> **开始:** ${STATS_START_TIME}
> **完成:** ${end_time}

**磁盘空间变化:**
> 清理前可用: **${STATS_SPACE_BEFORE}**
> 清理后可用: **${STATS_SPACE_AFTER}**
> 本次释放:   **${freed_human}**
> 磁盘总量:   ${total_human}  |  使用率: ${use_pct}%
${modules_section}

${log_hint}"
    local safe_content
    safe_content=$(echo "$content" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk '{printf "%s\\n", $0}' | sed 's/\\n$//')
    local payload
    payload=$(cat <<EOF
{"msgtype":"markdown","markdown":{"content":"${safe_content}"}}
EOF
)
    local resp
    resp=$(_wecom_send "$payload")
    local send_ret=$?
    NOTIFIED=1
    if [[ $send_ret -ne 0 ]]; then
        warn "企业微信通知发送失败 (网络错误)"
        return 1
    fi
    local errcode
    errcode=$(echo "$resp" | grep -o '"errcode":[0-9]*' | grep -o '[0-9]*' | head -1)
    if [[ "$errcode" == "0" ]]; then
        success "企业微信通知已发送"
        return 0
    else
        local errmsg
        errmsg=$(echo "$resp" | grep -o '"errmsg":"[^"]*"' | cut -d'"' -f4)
        warn "企业微信通知失败: errcode=$errcode errmsg=$errmsg"
        return 1
    fi
}
setup_wecom() {
    cyan "=== 企业微信通知配置 ==="
    echo "获取 Webhook 步骤:"
    echo "  企业微信群 -> 右键 -> 添加群机器人 -> 新建 -> 复制 Webhook URL"
    if [[ -f "$WECOM_CONF" ]]; then
        source "$WECOM_CONF" 2>/dev/null || true
        yellow "当前配置: ${WECOM_WEBHOOK:0:60}..."
        read -p "重新配置? [y/N]: " reconf
        [[ "${reconf:-n}" =~ ^[Yy]$ ]] || return 0
    fi
    while true; do
        read -p "粘贴 Webhook URL: " input_url
        input_url=$(echo "$input_url" | tr -d ' \t\r\n')
        if _wecom_valid_url "$input_url"; then
            WECOM_WEBHOOK="$input_url"
            break
        else
            red "URL 格式不正确"
        fi
    done
    local conf_dir
    conf_dir="$(dirname "$WECOM_CONF")"
    [[ -w "$conf_dir" ]] || WECOM_CONF="$HOME/.clean-system-wecom.conf"
    cat > "$WECOM_CONF" <<EOF
WECOM_WEBHOOK="${WECOM_WEBHOOK}"
EOF
    chmod 600 "$WECOM_CONF" 2>/dev/null || true
    success "配置已保存至 $WECOM_CONF"
    read -p "发送测试通知? [Y/n]: " do_test
    if [[ "${do_test:-y}" =~ ^[Yy]$ ]]; then
        STATS_HOSTNAME=$(hostname 2>/dev/null || echo 'unknown')
        STATS_OS="$OS_TYPE"
        STATS_SPACE_BEFORE=$(get_root_avail)
        STATS_SPACE_AFTER=$(get_root_avail)
        STATS_FREED_BYTES=0
        STATS_MODULES_LOG=""
        STATS_START_TIME=$(date '+%Y-%m-%d %H:%M:%S')
        NOTIFIED=0
        send_wecom_notify "test"
    fi
}
load_wecom_config() {
    if [[ -z "$WECOM_WEBHOOK" ]]; then
        for cfg in "$WECOM_CONF" "$HOME/.clean-system-wecom.conf"; do
            if [[ -f "$cfg" ]]; then
                source "$cfg" 2>/dev/null || true
                [[ -n "$WECOM_WEBHOOK" ]] && break
            fi
        done
    fi
}
OS_TYPE=""
ARCH=""
PKG_MANAGER=""
IS_MACOS=0
detect_system() {
    case "$(uname -m)" in
        x86_64|amd64)    ARCH="amd64"   ;;
        aarch64|arm64)   ARCH="arm64"   ;;
        armv7l|armhf)    ARCH="armv7"   ;;
        armv6l)          ARCH="armv6"   ;;
        i386|i686)       ARCH="i386"    ;;
        mips*)           ARCH="mips"    ;;
        riscv64)         ARCH="riscv64" ;;
        s390x)           ARCH="s390x"   ;;
        ppc64*)          ARCH="ppc64"   ;;
        *)               ARCH="$(uname -m)" ;;
    esac
    if [[ "$(uname -s)" == "Darwin" ]]; then
        OS_TYPE="macos"
        PKG_MANAGER="brew"
        IS_MACOS=1
        STATS_OS="macOS $(sw_vers -productVersion 2>/dev/null || echo '')"
        STATS_HOSTNAME=$(hostname 2>/dev/null || echo 'unknown')
        [[ $IS_CRON -eq 0 ]] && info "系统: macOS | 架构: $ARCH"
        return
    fi
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release 2>/dev/null || true
        local id_lower id_like_lower
        id_lower=$(echo "${ID:-unknown}" | tr '[:upper:]' '[:lower:]')
        id_like_lower=$(echo "${ID_LIKE:-}" | tr '[:upper:]' '[:lower:]')
        STATS_OS="${PRETTY_NAME:-$id_lower}"
        case "$id_lower" in
            ubuntu|debian|linuxmint|pop|kali|raspbian|armbian|deepin|uos|parrot)
                OS_TYPE="debian"; PKG_MANAGER="apt" ;;
            centos|rhel|rocky|almalinux|ol|openeuler|anolis|kylin)
                OS_TYPE="centos"
                command -v dnf &>/dev/null && PKG_MANAGER="dnf" || PKG_MANAGER="yum"
                ;;
            fedora)
                OS_TYPE="centos"; PKG_MANAGER="dnf" ;;
            arch|manjaro|endeavouros|garuda|artix)
                OS_TYPE="arch"; PKG_MANAGER="pacman" ;;
            opensuse*|sles|sled)
                OS_TYPE="suse"; PKG_MANAGER="zypper" ;;
            alpine)
                OS_TYPE="alpine"; PKG_MANAGER="apk" ;;
            void)
                OS_TYPE="void"; PKG_MANAGER="xbps" ;;
            gentoo)
                OS_TYPE="gentoo"; PKG_MANAGER="emerge" ;;
            nixos)
                OS_TYPE="nixos"; PKG_MANAGER="nix" ;;
            *)
                if echo "$id_like_lower" | grep -qE "debian|ubuntu"; then
                    OS_TYPE="debian"; PKG_MANAGER="apt"
                elif echo "$id_like_lower" | grep -qE "rhel|centos|fedora"; then
                    OS_TYPE="centos"
                    command -v dnf &>/dev/null && PKG_MANAGER="dnf" || PKG_MANAGER="yum"
                elif echo "$id_like_lower" | grep -qE "^arch"; then
                    OS_TYPE="arch"; PKG_MANAGER="pacman"
                elif echo "$id_like_lower" | grep -qE "suse"; then
                    OS_TYPE="suse"; PKG_MANAGER="zypper"
                else
                    OS_TYPE="unknown"; PKG_MANAGER="unknown"
                fi
                ;;
        esac
    elif [[ -f /etc/alpine-release ]]; then
        OS_TYPE="alpine"; PKG_MANAGER="apk"
        STATS_OS="Alpine $(cat /etc/alpine-release 2>/dev/null)"
    elif [[ -f /etc/arch-release ]]; then
        OS_TYPE="arch"; PKG_MANAGER="pacman"
        STATS_OS="Arch Linux"
    else
        OS_TYPE="unknown"; PKG_MANAGER="unknown"
        STATS_OS="Unknown Linux"
    fi
    STATS_HOSTNAME=$(hostname 2>/dev/null || echo 'unknown')
    [[ $IS_CRON -eq 0 ]] && info "系统: $OS_TYPE | 架构: $ARCH | 包管理器: $PKG_MANAGER"
}
install_dependencies() {
    local missing=()
    if ! command -v crontab &>/dev/null; then
        case "$OS_TYPE" in
            debian)  missing+=("cron") ;;
            centos)  missing+=("cronie") ;;
            arch)    missing+=("cronie") ;;
            alpine)  missing+=("dcron") ;;
            suse)    missing+=("cron") ;;
        esac
    fi
    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        case "$OS_TYPE" in
            debian|centos|arch|alpine|suse) missing+=("curl") ;;
        esac
    fi
    if ! command -v flock &>/dev/null; then
        case "$OS_TYPE" in
            debian) missing+=("util-linux") ;;
            centos) missing+=("util-linux") ;;
            alpine) missing+=("flock") ;;
        esac
    fi
    if [[ ${#missing[@]} -gt 0 ]]; then
        yellow "安装缺失依赖: ${missing[*]}..."
        case "$OS_TYPE" in
            debian)
                apt-get update -qq 2>/dev/null || true
                apt-get install -y -qq "${missing[@]}" 2>/dev/null || true
                ;;
            centos)
                if [[ "$PKG_MANAGER" == "dnf" ]]; then
                    dnf install -y -q "${missing[@]}" 2>/dev/null || true
                else
                    yum install -y -q "${missing[@]}" 2>/dev/null || true
                fi
                ;;
            arch)    pacman -Sy --noconfirm "${missing[@]}" 2>/dev/null || true ;;
            alpine)  apk add --no-cache "${missing[@]}" 2>/dev/null || true ;;
            suse)    zypper install -y "${missing[@]}" 2>/dev/null || true ;;
        esac
    fi
}
clean_tmp_files() {
    yellow "[1/12] 清理临时文件..."
    local before=0 after=0
    for dir in /tmp /var/tmp; do
        [[ -d "$dir" ]] || continue
        before=$(( before + $(get_dir_size "$dir") ))
    done
    safe_exec "find /tmp -type f -atime +1 -delete"
    safe_exec "find /var/tmp -type f -atime +1 -delete"
    safe_exec "find /tmp -mindepth 1 -type d -empty -delete"
    safe_exec "find /var/tmp -mindepth 1 -type d -empty -delete"
    for dir in /tmp /var/tmp; do
        [[ -d "$dir" ]] || continue
        after=$(( after + $(get_dir_size "$dir") ))
    done
    local freed=$(( before - after ))
    (( freed < 0 )) && freed=0
    success "临时文件释放: $(bytes_to_human $freed)"
    append_module_stat "临时文件" "$freed"
}
clean_logs() {
    yellow "[2/12] 清理系统日志..."
    local total_freed=0
    if command -v journalctl &>/dev/null; then
        local j_before=0 j_after=0
        for jdir in /var/log/journal /run/log/journal; do
            [[ -d "$jdir" ]] && j_before=$(( j_before + $(get_dir_size "$jdir") ))
        done
        safe_exec "journalctl --vacuum-time=2d --vacuum-size=100M"
        for jdir in /var/log/journal /run/log/journal; do
            [[ -d "$jdir" ]] && j_after=$(( j_after + $(get_dir_size "$jdir") ))
        done
        local j_freed=$(( j_before - j_after ))
        (( j_freed < 0 )) && j_freed=0
        (( j_freed > 0 )) && success "Journal释放: $(bytes_to_human $j_freed)"
        total_freed=$(( total_freed + j_freed ))
    fi
    if [[ $IS_MACOS -eq 1 ]]; then
        if [[ -d ~/Library/Logs ]]; then
            local mac_before mac_after
            mac_before=$(get_dir_size ~/Library/Logs)
            safe_exec "find ~/Library/Logs -type f -mtime +7 -delete"
            mac_after=$(get_dir_size ~/Library/Logs)
            local mac_freed=$(( mac_before - mac_after ))
            (( mac_freed < 0 )) && mac_freed=0
            (( mac_freed > 0 )) && success "macOS Logs释放: $(bytes_to_human $mac_freed)"
            total_freed=$(( total_freed + mac_freed ))
        fi
        safe_exec "find /private/var/log -name '*.asl' -mtime +7 -delete"
    fi
    if [[ -d /var/log ]]; then
        safe_exec "find /var/log -type f \( -name '*.log.*' -o -name '*.gz' -o -name '*.xz' -o -name '*.bz2' -o -name '*.old' -o -name '*.1' -o -name '*.2' -o -name '*.3' \) -mtime +2 -delete"
        if command -v truncate &>/dev/null; then
            safe_exec "find /var/log -type f -name '*.log' -size +50M -exec truncate -s 0 {} \;"
        fi
        for f in /var/log/wtmp /var/log/btmp /var/log/lastlog; do
            if [[ -f "$f" ]]; then
                local fsize
                fsize=$(get_file_size "$f")
                if (( fsize > 10485760 )); then
                    safe_exec "truncate -s 0 '$f'"
                    success "已清空 $f ($(bytes_to_human $fsize))"
                    total_freed=$(( total_freed + fsize ))
                fi
            fi
        done
    fi
    success "系统日志清理完成"
    append_module_stat "系统日志" "$total_freed"
}
clean_old_kernels() {
    [[ $IS_MACOS -eq 1 ]] && return 0
    yellow "[3/12] 清理旧内核..."
    local current_kernel
    current_kernel=$(uname -r)
    case "$OS_TYPE" in
        debian)
            local old_kernels
            old_kernels=$(dpkg -l 2>/dev/null | grep '^ii' | awk '{print $2}' | grep -E '^linux-(image|headers|modules)-[0-9]' | grep -v "$(echo "$current_kernel" | sed 's/-generic//' | sed 's/-[a-z]*$//')" || true)
            if [[ -n "$old_kernels" ]]; then
                success "当前内核: $current_kernel"
                warn "发现旧内核包:"
                echo "$old_kernels" | sed 's/^/    /'
                local do_clean=0
                if [[ $IS_CRON -eq 1 || $AGGRESSIVE -eq 1 ]]; then
                    do_clean=1
                else
                    read -p "  删除旧内核? [y/N]: " ans
                    [[ "${ans:-n}" =~ ^[Yy]$ ]] && do_clean=1
                fi
                if [[ $do_clean -eq 1 ]]; then
                    safe_exec "DEBIAN_FRONTEND=noninteractive apt-get purge -y --auto-remove $old_kernels"
                    success "旧内核已清理"
                else
                    skip "跳过旧内核"
                fi
            else
                success "无旧内核"
            fi
            ;;
        centos)
            if command -v package-cleanup &>/dev/null; then
                safe_exec "package-cleanup --oldkernels --count=1 -y"
            elif command -v dnf &>/dev/null; then
                safe_exec "dnf remove --oldinstallonly --setopt installonly_limit=2 -y"
            fi
            success "旧内核检查完成"
            ;;
        arch)
            command -v paccache &>/dev/null && safe_exec "paccache -r --noconfirm"
            ;;
        *)
            skip "该系统跳过内核清理"
            ;;
    esac
}
clean_package_manager() {
    yellow "[4/12] 清理包管理器缓存..."
    export DEBIAN_FRONTEND=noninteractive
    local freed_est=0
    case "$OS_TYPE" in
        debian)
            local before
            before=$(get_dir_size /var/cache/apt)
            safe_exec "apt-get clean -y"
            safe_exec "apt-get autoclean -y"
            safe_exec "apt-get autoremove -y --purge"
            local rc_pkgs
            rc_pkgs=$(dpkg -l 2>/dev/null | awk '/^rc/{print $2}' || true)
            if [[ -n "$rc_pkgs" ]]; then
                safe_exec "echo '$rc_pkgs' | xargs dpkg --purge"
                success "残留配置: $(echo "$rc_pkgs" | wc -w | tr -d ' ') 个已清理"
            fi
            [[ $AGGRESSIVE -eq 1 ]] && {
                safe_exec "rm -rf /var/lib/apt/lists/*"
                success "APT lists 已清理"
            }
            local after
            after=$(get_dir_size /var/cache/apt)
            freed_est=$(( before - after ))
            (( freed_est < 0 )) && freed_est=0
            success "APT缓存释放: $(bytes_to_human $freed_est)"
            ;;
        centos)
            local cache_dir="/var/cache/dnf"
            [[ "$PKG_MANAGER" == "yum" ]] && cache_dir="/var/cache/yum"
            local before
            before=$(get_dir_size "$cache_dir")
            if [[ "$PKG_MANAGER" == "dnf" ]]; then
                safe_exec "dnf clean all"
                safe_exec "dnf autoremove -y"
                safe_exec "rm -rf /var/cache/dnf/*"
            else
                safe_exec "yum clean all"
                safe_exec "yum autoremove -y"
                safe_exec "rm -rf /var/cache/yum/*"
            fi
            freed_est=$before
            success "YUM/DNF 缓存释放: $(bytes_to_human $freed_est)"
            ;;
        arch)
            local before
            before=$(get_dir_size /var/cache/pacman/pkg)
            safe_exec "pacman -Sc --noconfirm"
            command -v paccache &>/dev/null && safe_exec "paccache -rk2 --noconfirm"
            local orphans
            orphans=$(pacman -Qdtq 2>/dev/null || true)
            if [[ -n "$orphans" ]]; then
                safe_exec "echo '$orphans' | pacman -Rns --noconfirm -"
                success "孤立包已清理"
            fi
            local after
            after=$(get_dir_size /var/cache/pacman/pkg)
            freed_est=$(( before - after ))
            (( freed_est < 0 )) && freed_est=0
            success "Pacman 缓存释放: $(bytes_to_human $freed_est)"
            ;;
        alpine)
            local before
            before=$(get_dir_size /var/cache/apk)
            safe_exec "apk cache clean"
            safe_exec "rm -rf /var/cache/apk/*"
            freed_est=$before
            success "APK 缓存已清理"
            ;;
        suse)
            safe_exec "zypper clean --all"
            success "Zypper 缓存已清理"
            ;;
        void)
            safe_exec "xbps-remove -Oo"
            success "XBPS 缓存已清理"
            ;;
        macos)
            if command -v brew &>/dev/null; then
                local before
                before=$(get_dir_size "$(brew --cache 2>/dev/null || echo '/tmp/brew')")
                safe_exec "brew cleanup --prune=all"
                safe_exec "brew autoremove"
                local after
                after=$(get_dir_size "$(brew --cache 2>/dev/null || echo '/tmp/brew')")
                freed_est=$(( before - after ))
                (( freed_est < 0 )) && freed_est=0
                success "Homebrew 缓存释放: $(bytes_to_human $freed_est)"
            else
                skip "未安装 Homebrew"
            fi
            ;;
    esac
    append_module_stat "包管理器缓存" "$freed_est"
}
clean_snap() {
    command -v snap &>/dev/null || return 0
    [[ $IS_MACOS -eq 1 ]] && return 0
    yellow "[5/12] 清理 Snap 旧版本..."
    local freed_est=0
    snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}' | while read -r snapname revision; do
        safe_exec "snap remove '$snapname' --revision='$revision'"
        success "移除 $snapname (rev $revision)"
    done
    if [[ -d /var/lib/snapd/cache ]]; then
        local sz
        sz=$(get_dir_size /var/lib/snapd/cache)
        safe_exec "rm -rf /var/lib/snapd/cache/*"
        success "Snap缓存释放: $(bytes_to_human $sz)"
        freed_est=$sz
    fi
    append_module_stat "Snap" "$freed_est"
}
clean_flatpak() {
    command -v flatpak &>/dev/null || return 0
    yellow "[6/12] 清理 Flatpak..."
    safe_exec "flatpak uninstall --unused -y"
    success "Flatpak 清理完成"
}
clean_docker() {
    command -v docker &>/dev/null || return 0
    docker info &>/dev/null || { skip "Docker 未运行"; return 0; }
    yellow "[7/12] 清理 Docker..."
    local df_before=0
    local docker_root
    docker_root=$(docker info 2>/dev/null | awk '/Docker Root Dir/{print $4}')
    [[ -d "$docker_root" ]] && df_before=$(get_dir_size "$docker_root")
    [[ $IS_CRON -eq 0 ]] && { info "Docker 磁盘使用:"; docker system df 2>/dev/null || true; }
    local stopped
    stopped=$(docker ps -aq --filter "status=exited" 2>/dev/null || true)
    [[ -n "$stopped" ]] && safe_exec "docker rm $stopped"
    safe_exec "docker image prune -f"
    safe_exec "docker network prune -f"
    safe_exec "docker builder prune -af"
    if [[ $AGGRESSIVE -eq 1 || $IS_CRON -eq 1 ]]; then
        safe_exec "docker system prune -af --volumes"
        success "Docker 深度清理完成"
    else
        read -p "  清理 Docker 未使用的卷? [y/N]: " ans
        [[ "${ans:-n}" =~ ^[Yy]$ ]] && safe_exec "docker volume prune -f"
        success "Docker 清理完成"
    fi
    local df_after=0
    [[ -d "$docker_root" ]] && df_after=$(get_dir_size "$docker_root")
    local freed=$(( df_before - df_after ))
    (( freed < 0 )) && freed=0
    append_module_stat "Docker" "$freed"
}
clean_dev_caches() {
    yellow "[8/12] 清理开发环境缓存..."
    local found=0
    local total_freed=0
    _dev_freed() { local dir="${1:-}"; [[ -d "$dir" ]] && get_dir_size "$dir" || echo 0; }
    if command -v npm &>/dev/null; then
        found=1
        local npm_dir npm_sz=0
        npm_dir=$(npm config get cache 2>/dev/null || echo "$HOME/.npm")
        [[ -d "$npm_dir" ]] && npm_sz=$(get_dir_size "$npm_dir")
        safe_exec "npm cache clean --force"
        total_freed=$(( total_freed + npm_sz ))
        success "NPM: $(bytes_to_human $npm_sz)"
    fi
    if command -v yarn &>/dev/null; then
        found=1
        local yarn_dir yarn_sz
        yarn_dir=$(yarn cache dir 2>/dev/null || echo "$HOME/.yarn")
        yarn_sz=$(_dev_freed "$yarn_dir")
        safe_exec "yarn cache clean"
        total_freed=$(( total_freed + yarn_sz ))
        success "Yarn: $(bytes_to_human $yarn_sz)"
    fi
    if command -v pnpm &>/dev/null; then
        found=1
        safe_exec "pnpm store prune"
        success "pnpm store 已修剪"
    fi
    if command -v bun &>/dev/null; then
        found=1
        local bun_cache="${HOME}/.bun/install/cache"
        local bun_sz
        bun_sz=$(_dev_freed "$bun_cache")
        safe_exec "rm -rf '$bun_cache'/*"
        total_freed=$(( total_freed + bun_sz ))
        success "Bun: $(bytes_to_human $bun_sz)"
    fi
    for pip_cmd in pip3 pip; do
        if command -v "$pip_cmd" &>/dev/null; then
            found=1
            safe_exec "$pip_cmd cache purge"
            success "$pip_cmd 缓存已清理"
            break
        fi
    done
    if command -v uv &>/dev/null; then
        found=1; safe_exec "uv cache clean"; success "uv 缓存已清理"
    fi
    if command -v conda &>/dev/null; then
        found=1; safe_exec "conda clean --all -y"; success "conda 已清理"
    fi
    if [[ $AGGRESSIVE -eq 1 ]]; then
        found=1
        local pycache_before
        pycache_before=$(find /home /root /opt /srv 2>/dev/null -type d -name '__pycache__' -exec du -sb {} + 2>/dev/null | awk '{s+=$1}END{print s+0}')
        safe_exec "find /home /root /opt /srv -type d -name '__pycache__' -exec rm -rf {} +"
        total_freed=$(( total_freed + pycache_before ))
        (( pycache_before > 0 )) && success "__pycache__: $(bytes_to_human $pycache_before)"
    fi
    if command -v go &>/dev/null; then
        found=1
        local go_cache go_sz=0
        go_cache=$(go env GOCACHE 2>/dev/null || echo "")
        [[ -n "$go_cache" && -d "$go_cache" ]] && go_sz=$(get_dir_size "$go_cache")
        safe_exec "go clean -cache"
        safe_exec "go clean -testcache"
        [[ $AGGRESSIVE -eq 1 ]] && safe_exec "go clean -modcache"
        total_freed=$(( total_freed + go_sz ))
        success "Go: $(bytes_to_human $go_sz)"
    fi
    if command -v cargo &>/dev/null && [[ $AGGRESSIVE -eq 1 ]]; then
        found=1
        if [[ -d "$HOME/.cargo/registry" ]]; then
            local cargo_sz
            cargo_sz=$(get_dir_size "$HOME/.cargo/registry")
            safe_exec "rm -rf '$HOME/.cargo/registry/cache' '$HOME/.cargo/registry/src'"
            total_freed=$(( total_freed + cargo_sz ))
            success "Cargo: $(bytes_to_human $cargo_sz)"
        fi
    fi
    if [[ -d "$HOME/.m2/repository" && $AGGRESSIVE -eq 1 ]]; then
        found=1
        safe_exec "find '$HOME/.m2/repository' -type f -atime +30 -delete"
        success "Maven 旧依赖已清理"
    fi
    if [[ -d "$HOME/.gradle/caches" && $AGGRESSIVE -eq 1 ]]; then
        found=1
        local gradle_sz
        gradle_sz=$(get_dir_size "$HOME/.gradle/caches")
        safe_exec "find '$HOME/.gradle/caches' -type f -atime +30 -delete"
        total_freed=$(( total_freed + gradle_sz ))
        success "Gradle: $(bytes_to_human $gradle_sz)"
    fi
    if command -v composer &>/dev/null; then
        found=1; safe_exec "composer clearcache"; success "Composer 已清理"
    fi
    if command -v gem &>/dev/null; then
        found=1; safe_exec "gem cleanup"; success "Ruby Gem 已清理"
    fi
    (( found == 0 )) && skip "未检测到开发环境"
    append_module_stat "开发环境缓存" "$total_freed"
}
clean_user_caches() {
    yellow "[9/12] 清理用户缓存..."
    local total_freed=0
    local home_dirs=()
    if [[ $IS_MACOS -eq 1 ]]; then
        for d in /Users/*; do [[ -d "$d" ]] && home_dirs+=("$d"); done
        [[ -d /var/root ]] && home_dirs+=(/var/root)
    else
        for d in /home/*; do [[ -d "$d" ]] && home_dirs+=("$d"); done
        [[ -d /root ]] && home_dirs+=(/root)
    fi
    (( ${#home_dirs[@]} == 0 )) && { skip "无用户家目录"; return 0; }
    for hd in "${home_dirs[@]}"; do
        safe_exec "find '$hd' -type f \( -name '*.swp' -o -name '*.swo' -o -name '*~' -o -name '*.save' -o -name '*.bak' -o -name '#*#' \) -delete 2>/dev/null"
    done
    success "编辑器临时文件已清理"
    for hd in "${home_dirs[@]}"; do
        safe_exec "find '$hd' -type d -name 'thumbnails' -exec rm -rf {} + 2>/dev/null"
    done
    if [[ $IS_MACOS -eq 0 ]]; then
        for hd in "${home_dirs[@]}"; do
            safe_exec "find '$hd' -path '*/.local/share/Trash/*' -delete 2>/dev/null"
        done
        success "回收站已清空"
    fi
    if [[ $IS_MACOS -eq 1 ]]; then
        for hd in "${home_dirs[@]}"; do
            [[ -d "$hd/.Trash" ]] || continue
            local trash_sz
            trash_sz=$(get_dir_size "$hd/.Trash")
            safe_exec "rm -rf '$hd/.Trash/'*"
            total_freed=$(( total_freed + trash_sz ))
        done
        success "macOS 回收站已清空"
    fi
    for hd in "${home_dirs[@]}"; do
        [[ -d "$hd/.cache" ]] || continue
        local cache_before cache_after
        cache_before=$(get_dir_size "$hd/.cache")
        safe_exec "find '$hd/.cache' -type f -atime +7 -delete 2>/dev/null"
        safe_exec "find '$hd/.cache' -type d -empty -delete 2>/dev/null"
        cache_after=$(get_dir_size "$hd/.cache")
        local diff=$(( cache_before - cache_after ))
        (( diff > 0 )) && total_freed=$(( total_freed + diff ))
    done
    success "用户 .cache 已清理"
    if [[ $IS_MACOS -eq 1 ]]; then
        for hd in "${home_dirs[@]}"; do
            [[ -d "$hd/Library/Caches" ]] || continue
            local mac_cache_sz
            mac_cache_sz=$(get_dir_size "$hd/Library/Caches")
            safe_exec "find '$hd/Library/Caches' -type f -atime +7 -delete 2>/dev/null"
            total_freed=$(( total_freed + mac_cache_sz ))
        done
        success "macOS Library/Caches 已清理"
    fi
    if [[ $AGGRESSIVE -eq 1 ]]; then
        for hd in "${home_dirs[@]}"; do
            safe_exec "find '$hd' -maxdepth 1 \( -name '.bash_history' -o -name '.zsh_history' -o -name '.ash_history' \) -exec truncate -s 0 {} \; 2>/dev/null"
        done
        success "Shell 历史已清空"
    fi
    append_module_stat "用户缓存" "$total_freed"
}
clean_coredumps() {
    yellow "[10/12] 清理崩溃转储..."
    local total_freed=0
    if [[ -d /var/lib/systemd/coredump ]]; then
        local sz
        sz=$(get_dir_size /var/lib/systemd/coredump)
        safe_exec "rm -rf /var/lib/systemd/coredump/*"
        (( sz > 0 )) && { success "Coredump: $(bytes_to_human $sz)"; total_freed=$(( total_freed + sz )); }
    fi
    safe_exec "find /tmp /home /root /var -maxdepth 3 -type f \( -name 'core' -size +1M -o -name 'core.[0-9]*' \) -delete 2>/dev/null"
    if [[ -d /var/crash ]]; then
        local crash_sz
        crash_sz=$(get_dir_size /var/crash)
        safe_exec "rm -rf /var/crash/*"
        (( crash_sz > 0 )) && { success "崩溃报告: $(bytes_to_human $crash_sz)"; total_freed=$(( total_freed + crash_sz )); }
    fi
    if [[ $IS_MACOS -eq 1 ]]; then
        for cdir in ~/Library/Logs/DiagnosticReports /Library/Logs/DiagnosticReports; do
            [[ -d "$cdir" ]] || continue
            local csz
            csz=$(get_dir_size "$cdir")
            safe_exec "find '$cdir' -type f -name '*.crash' -mtime +7 -delete"
            total_freed=$(( total_freed + csz ))
        done
        success "macOS 崩溃报告已清理"
    fi
    success "崩溃转储清理完成"
    append_module_stat "崩溃转储" "$total_freed"
}
clean_misc() {
    yellow "[11/12] 清理系统杂项..."
    if [[ $IS_MACOS -eq 0 ]]; then
        for dir in /var/cache/fontconfig /var/cache/man /var/cache/ldconfig; do
            [[ -d "$dir" ]] && safe_exec "rm -rf '$dir'/*"
        done
        safe_exec "find /var/lib/dhcp /var/lib/dhclient -name '*.leases~' -delete 2>/dev/null"
        command -v systemctl &>/dev/null && safe_exec "systemctl reset-failed 2>/dev/null"
    fi
    safe_exec "find /home /root -maxdepth 2 -name 'known_hosts.old' -delete 2>/dev/null"
    safe_exec "find /tmp -maxdepth 1 \( -name 'pip-*' -o -name 'npm-*' -o -name 'yarn-*' \) -type d -mtime +1 -exec rm -rf {} + 2>/dev/null"
    if [[ $AGGRESSIVE -eq 1 && $IS_MACOS -eq 0 ]]; then
        if [[ -d /usr/share/locale ]]; then
            safe_exec "find /usr/share/locale -mindepth 1 -maxdepth 1 -type d ! -name 'en*' ! -name 'zh*' ! -name 'C' ! -name 'POSIX' -exec rm -rf {} +"
            success "多余 locale 已清理"
        fi
        if [[ -d /usr/share/doc ]]; then
            safe_exec "find /usr/share/doc -type f ! -name 'copyright' ! -name 'changelog*' -delete"
            success "无用文档已清理"
        fi
    fi
    success "杂项清理完成"
}
clean_deleted_open_files() {
    yellow "[12/12] 检测已删除但仍占空间的文件..."
    [[ $IS_MACOS -eq 1 ]] && { skip "macOS 跳过此检测"; return 0; }
    if ! command -v lsof &>/dev/null; then
        skip "lsof 未安装，跳过"
        return 0
    fi
    local deleted_info
    deleted_info=$(lsof +L1 2>/dev/null | awk 'NR>1 && /deleted/ && $7+0 > 1048576 {printf "%-16s %-8s %-12s %s\n",$1,$2,$7,$9}' | head -15 || true)
    if [[ -z "$deleted_info" ]]; then
        success "无大文件被占用"
        return 0
    fi
    local total=0
    warn "以下进程持有已删除大文件:"
    printf "  %-16s %-8s %-12s %s\n" "进程" "PID" "大小(B)" "路径"
    echo "  ------------------------------------------------"
    while IFS= read -r line; do
        echo "  $line"
        local sz_field
        sz_field=$(echo "$line" | awk '{print $3}')
        [[ "$sz_field" =~ ^[0-9]+$ ]] && total=$(( total + sz_field ))
    done <<< "$deleted_info"
    if (( total > 0 )); then
        warn "合计占用: $(bytes_to_human $total)"
        warn "重启相关服务可释放"
        STATS_MODULES_LOG="${STATS_MODULES_LOG}• 待释放(重启服务): $(bytes_to_human $total)\n"
    fi
}
disk_usage_analysis() {
    cyan "=== 根目录 Top 15 大目录 ==="
    if [[ $IS_MACOS -eq 1 ]]; then
        du -hd3 / 2>/dev/null | sort -rh | head -15 | awk '{printf "  %-8s %s\n", $1, $2}'
    else
        du -hx --max-depth=3 / 2>/dev/null | sort -rh | head -15 | awk '{printf "  %-8s %s\n", $1, $2}'
    fi
    cyan "=== Top 10 大文件 (>100MB) ==="
    find / -xdev -type f -size +100M 2>/dev/null | head -30 | xargs -I{} du -h {} 2>/dev/null | sort -rh | head -10 | awk '{printf "  %-8s %s\n", $1, $2}'
}
clean_system() {
    detect_system
    load_wecom_config
    STATS_HOSTNAME=$(hostname 2>/dev/null || echo 'unknown')
    STATS_OS="${STATS_OS:-$OS_TYPE}"
    STATS_SPACE_BEFORE=$(get_root_avail)
    local space_before_bytes
    space_before_bytes=$(get_root_avail_bytes)
    STATS_FREED_BYTES=0
    STATS_MODULES_LOG=""
    STATS_STATUS="success"
    bold ">> 开始系统深度清理..."
    info "主机: $STATS_HOSTNAME | 系统: $OS_TYPE | 架构: $ARCH"
    info "清理前可用: $STATS_SPACE_BEFORE"
    if [[ $IS_CRON -eq 0 ]]; then
        echo "清理等级:"
        echo "  1) 标准清理"
        echo "  2) 深度清理"
        echo "  3) 仅分析磁盘占用"
        read -p "选择 [1/2/3，默认 1]: " level
        case "${level:-1}" in
            2) AGGRESSIVE=1 ;;
            3) disk_usage_analysis; return 0 ;;
            *) AGGRESSIVE=0 ;;
        esac
    fi
    clean_tmp_files
    clean_logs
    clean_old_kernels
    clean_package_manager
    clean_snap
    clean_flatpak
    clean_docker
    clean_dev_caches
    clean_user_caches
    clean_coredumps
    clean_misc
    clean_deleted_open_files
    STATS_SPACE_AFTER=$(get_root_avail)
    local space_after_bytes
    space_after_bytes=$(get_root_avail_bytes)
    local freed=$(( space_after_bytes - space_before_bytes ))
    (( freed < 0 )) && freed=0
    (( STATS_FREED_BYTES > freed )) && freed=$STATS_FREED_BYTES
    STATS_FREED_BYTES=$freed
    echo "=================================================="
    green "            系统清理完成!"
    echo "=================================================="
    green "  清理前可用:  $STATS_SPACE_BEFORE"
    green "  清理后可用:  $STATS_SPACE_AFTER"
    if (( freed > 1024 )); then
        green "  本次释放:    $(bytes_to_human $freed)"
    else
        yellow "  本次释放:    < 1 KB"
    fi
    echo "=================================================="
    if [[ $IS_CRON -eq 0 ]]; then
        read -p "查看磁盘占用分析? [y/N]: " show
        [[ "${show:-n}" =~ ^[Yy]$ ]] && disk_usage_analysis
        read -p "现在发送企业微信通知? [y/N]: " snotify
        [[ "${snotify:-n}" =~ ^[Yy]$ ]] && send_wecom_notify "success"
    fi
    return 0
}
remove_all_cron_entries() {
    [[ -f "$CRON_D_FILE" ]] && { rm -f "$CRON_D_FILE"; success "已移除 $CRON_D_FILE"; }
    if command -v crontab &>/dev/null; then
        local tmpfile
        tmpfile=$(mktemp)
        crontab -l 2>/dev/null | grep -v -F "clean-system" | grep -v -F "$SCRIPT_PATH" > "$tmpfile" || true
        if [[ -s "$tmpfile" ]]; then
            crontab "$tmpfile" 2>/dev/null || true
        else
            crontab -r 2>/dev/null || true
        fi
        rm -f "$tmpfile"
        success "用户 crontab 中相关条目已清理"
    fi
    local plist="$HOME/Library/LaunchAgents/com.clean-system.plist"
    if [[ -f "$plist" ]]; then
        launchctl unload "$plist" 2>/dev/null || true
        rm -f "$plist"
        success "launchd 任务已移除"
    fi
}
setup_cron() {
    detect_system
    install_dependencies
    if [[ $IS_MACOS -eq 1 ]]; then
        _setup_launchd
        return 0
    fi
    echo "定时清理频率:"
    echo "  1) 每天 03:00"
    echo "  2) 每两天 03:00 (推荐)"
    echo "  3) 每周日 03:00"
    echo "  4) 每月 1 号 03:00"
    echo "  5) 自定义 cron 表达式"
    read -p "选择 [1-5，默认 2]: " freq
    local schedule
    case "${freq:-2}" in
        1) schedule="0 3 * * *"   ;;
        2) schedule="0 3 */2 * *" ;;
        3) schedule="0 3 * * 0"   ;;
        4) schedule="0 3 1 * *"   ;;
        5) read -p "输入 cron 表达式: " schedule ;;
        *) schedule="0 3 */2 * *" ;;
    esac
    yellow "清理所有旧的定时任务条目 (避免重复触发)..."
    remove_all_cron_entries
    if [[ -d /etc/cron.d ]] && [[ -w /etc/cron.d ]]; then
        cat > "$CRON_D_FILE" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=""
${schedule} root /bin/bash ${SCRIPT_PATH} --cron --aggressive >> ${CRON_LOG} 2>&1
EOF
        chmod 644 "$CRON_D_FILE"
        success "定时任务已写入 $CRON_D_FILE"
    else
        local tmpfile
        tmpfile=$(mktemp)
        crontab -l 2>/dev/null > "$tmpfile" || true
        echo "${schedule} /bin/bash ${SCRIPT_PATH} --cron --aggressive >> ${CRON_LOG} 2>&1" >> "$tmpfile"
        crontab "$tmpfile"
        rm -f "$tmpfile"
        success "定时任务已写入用户 crontab"
    fi
    success "定时任务设置完成"
    green "  频率: $schedule"
    green "  日志: $CRON_LOG"
    _start_cron_service
}
_start_cron_service() {
    yellow "启动 cron 服务..."
    if command -v systemctl &>/dev/null; then
        for svc in cron crond dcron fcron; do
            if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
                safe_exec "systemctl enable --now $svc"
                success "cron 服务 ($svc) 已启动"
                return 0
            fi
        done
    fi
    if command -v rc-service &>/dev/null; then
        safe_exec "rc-service dcron start"
        safe_exec "rc-update add dcron"
        success "dcron 已启动"
        return 0
    fi
    if command -v service &>/dev/null; then
        for svc in cron crond; do
            if service "$svc" status &>/dev/null; then
                success "cron 服务 ($svc) 已运行"
                return 0
            fi
        done
        for svc in cron crond; do
            safe_exec "service $svc start" && { success "$svc 启动成功"; return 0; }
        done
    fi
    warn "未识别 init 系统，请手动确认 cron 服务运行"
}
_setup_launchd() {
    local plist_file="$HOME/Library/LaunchAgents/com.clean-system.plist"
    local log_path="$HOME/Library/Logs/clean-system-cron.log"
    mkdir -p "$HOME/Library/LaunchAgents"
    if [[ -f "$plist_file" ]]; then
        launchctl unload "$plist_file" 2>/dev/null || true
        rm -f "$plist_file"
    fi
    cat > "$plist_file" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.clean-system</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${SCRIPT_PATH}</string>
        <string>--cron</string>
        <string>--aggressive</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>3</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>${log_path}</string>
    <key>StandardErrorPath</key>
    <string>${log_path}</string>
    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>
EOF
    launchctl load "$plist_file"
    success "macOS launchd 任务已注册: $plist_file"
    green "  日志: $log_path"
}
create_symlink() {
    while true; do
        read -p "输入快捷命令名 (如 clean): " shortcut
        [[ "$shortcut" =~ ^[a-zA-Z0-9_-]+$ ]] || { red "无效名称"; continue; }
        local target="/usr/local/bin/$shortcut"
        if [[ -e "$target" ]]; then
            read -p "'$shortcut' 已存在，覆盖? [y/N]: " ow
            [[ "${ow:-n}" =~ ^[Yy]$ ]] || continue
            rm -f "$target"
        fi
        ln -sf "$SCRIPT_PATH" "$target"
        chmod +x "$target"
        success "快捷命令 '$shortcut' 已创建 -> $target"
        break
    done
    return 0
}
uninstall() {
    remove_all_cron_entries
    [[ -f "$WECOM_CONF" ]] && { rm -f "$WECOM_CONF"; success "企业微信配置已移除"; }
    [[ -f "$HOME/.clean-system-wecom.conf" ]] && rm -f "$HOME/.clean-system-wecom.conf"
    [[ -f "$LOCK_FILE" ]] && rm -f "$LOCK_FILE"
    find /usr/local/bin -maxdepth 1 -lname "*clean-system*" -delete 2>/dev/null || true
    find /usr/local/bin -maxdepth 1 -lname "$SCRIPT_PATH" -delete 2>/dev/null || true
    success "快捷链接已移除"
    read -p "删除脚本本身? [y/N]: " del
    if [[ "${del:-n}" =~ ^[Yy]$ ]]; then
        rm -f "$SCRIPT_PATH"
        success "脚本已删除"
    fi
    green "卸载完成"
    return 0
}
main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cron)        IS_CRON=1;     shift ;;
            --dry-run)     DRY_RUN=1;     shift ;;
            --aggressive)  AGGRESSIVE=1;  shift ;;
            --notify-test) NOTIFY_ONLY=1; shift ;;
            --help|-h)
                cat <<'EOF'
系统深度清理工具 v3.1
用法: clean [选项]
  --cron          静默模式 (定时任务使用)
  --dry-run       模拟运行
  --aggressive    激进深度清理
  --notify-test   测试企业微信通知
  --help          帮助
配置文件: /etc/clean-system-wecom.conf
锁文件:   /var/lock/clean-system.lock
EOF
                exit 0
                ;;
            *) red "未知参数: $1"; exit 1 ;;
        esac
    done
    if [[ $EUID -ne 0 ]]; then
        [[ $IS_CRON -eq 0 ]] && yellow "提示: 建议使用 sudo 运行"
    fi
    acquire_lock
    init_log
    if [[ $NOTIFY_ONLY -eq 1 ]]; then
        detect_system
        load_wecom_config
        STATS_HOSTNAME=$(hostname 2>/dev/null || echo 'unknown')
        STATS_SPACE_BEFORE=$(get_root_avail)
        STATS_SPACE_AFTER=$(get_root_avail)
        STATS_FREED_BYTES=0
        STATS_MODULES_LOG="• 这是一条测试消息\n"
        STATS_START_TIME=$(date '+%Y-%m-%d %H:%M:%S')
        NOTIFIED=0
        send_wecom_notify "test"
        exit 0
    fi
    if [[ $IS_CRON -eq 1 ]]; then
        detect_system
        load_wecom_config
        AGGRESSIVE=1
        STATS_START_TIME=$(date '+%Y-%m-%d %H:%M:%S')
        local cs_ret=0
        clean_system || cs_ret=$?
        if [[ $cs_ret -eq 0 ]]; then
            send_wecom_notify "success"
        else
            STATS_SPACE_AFTER=$(get_root_avail)
            send_wecom_notify "failed"
        fi
        echo "========== $(date '+%Y-%m-%d %H:%M:%S') 完成 =========="
        exit 0
    fi
    while true; do
        cyan "======================================"
        cyan "  系统深度清理工具 v1.1"
        cyan "======================================"
        echo "  1. 执行清理"
        echo "  2. 设置定时任务"
        echo "  3. 创建快捷命令"
        echo "  4. 磁盘占用分析"
        echo "  5. 配置企业微信通知"
        echo "  6. 测试企业微信通知"
        echo "  7. 卸载本工具"
        echo "  8. 退出"
        cyan "======================================"
        read -p "选择 [1-8]: " choice
        NOTIFIED=0
        case "${choice:-}" in
            1) clean_system ;;
            2) setup_cron ;;
            3) create_symlink ;;
            4) detect_system; disk_usage_analysis ;;
            5) detect_system; setup_wecom ;;
            6)
                detect_system
                load_wecom_config
                STATS_HOSTNAME=$(hostname 2>/dev/null || echo 'unknown')
                STATS_SPACE_BEFORE=$(get_root_avail)
                STATS_SPACE_AFTER=$(get_root_avail)
                STATS_FREED_BYTES=12345678
                STATS_MODULES_LOG="• 临时文件: 释放 5.00 MB\n• APT缓存: 释放 6.78 MB\n"
                STATS_START_TIME=$(date '+%Y-%m-%d %H:%M:%S')
                send_wecom_notify "test"
                ;;
            7) uninstall; exit 0 ;;
            8) green "再见!"; exit 0 ;;
            *) red "无效选项" ;;
        esac
    done
}
main "$@"
