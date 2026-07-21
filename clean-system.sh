#!/bin/bash

set -uo pipefail

IS_CRON=0
DRY_RUN=0
AGGRESSIVE=0

# ---- 颜色输出 ----
red()    { echo -e "\033[31m$*\033[0m"; }
green()  { echo -e "\033[32m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }
cyan()   { echo -e "\033[36m$*\033[0m"; }
bold()   { echo -e "\033[1m$*\033[0m"; }

# ---- 日志 ----
LOG_FILE="/var/log/clean-system.log"

init_log() {
    if [[ ! -w "$(dirname "$LOG_FILE")" ]]; then
        LOG_FILE="/tmp/clean-system.log"
    fi
    touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/clean-system.log"
    exec > >(tee -a "$LOG_FILE") 2>&1
    echo ""
    echo "========== $(date '+%Y-%m-%d %H:%M:%S') 开始 =========="
    [[ $IS_CRON -eq 0 ]] && green "日志: $LOG_FILE"
}

# ============================================================
# 工具函数 —— 纯 bash，零依赖
# ============================================================

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
    local size
    size=$(du -sb "$dir" 2>/dev/null | awk '{print $1}') || \
    size=$(du -sk "$dir" 2>/dev/null | awk '{print $1 * 1024}') || \
    size=0
    [[ "$size" =~ ^[0-9]+$ ]] || size=0
    echo "$size"
}

get_file_size() {
    local f="${1:-}"
    [[ -f "$f" ]] || { echo 0; return; }
    local size
    size=$(stat -c%s "$f" 2>/dev/null) || \
    size=$(stat -f%z "$f" 2>/dev/null) || \
    size=$(wc -c < "$f" 2>/dev/null) || \
    size=0
    [[ "$size" =~ ^[0-9]+$ ]] || size=0
    echo "$size"
}

get_root_avail() {
    df -h / 2>/dev/null | awk 'NR==2 {print $4}' || echo "N/A"
}

get_root_avail_bytes() {
    local avail
    avail=$(df -B1 / 2>/dev/null | awk 'NR==2 {print $4}') || \
    avail=$(df -k / 2>/dev/null | awk 'NR==2 {print $4 * 1024}') || \
    avail=0
    [[ "$avail" =~ ^[0-9]+$ ]] || avail=0
    echo "$avail"
}

safe_exec() {
    if [[ $DRY_RUN -eq 1 ]]; then
        yellow "  [DRY] $*"
    else
        eval "$@" 2>/dev/null || true
    fi
}

info()    { echo "  >> $*"; }
success() { green "  [OK] $*"; }
skip()    { yellow "  [--] $*"; }
warn()    { yellow "  [!!] $*"; }

# ============================================================
# 系统检测
# ============================================================
OS_TYPE=""
ARCH=""
PKG_MANAGER=""

detect_system() {
    case "$(uname -m)" in
        x86_64|amd64)       ARCH="amd64" ;;
        aarch64|arm64)      ARCH="arm64" ;;
        armv7l|armhf)       ARCH="armv7" ;;
        armv6l)             ARCH="armv6" ;;
        i386|i686)          ARCH="i386"  ;;
        mips*)              ARCH="mips"  ;;
        riscv64)            ARCH="riscv64" ;;
        s390x)              ARCH="s390x" ;;
        ppc64*)             ARCH="ppc64" ;;
        *)                  ARCH="$(uname -m)" ;;
    esac

    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release 2>/dev/null || true
        local id_lower id_like_lower
        id_lower=$(echo "${ID:-unknown}" | tr '[:upper:]' '[:lower:]')
        id_like_lower=$(echo "${ID_LIKE:-}" | tr '[:upper:]' '[:lower:]')

        case "$id_lower" in
            ubuntu|debian|linuxmint|pop|kali|raspbian|armbian|deepin|uos)
                OS_TYPE="debian"; PKG_MANAGER="apt" ;;
            centos|rhel|rocky|almalinux|ol|openeuler|anolis)
                OS_TYPE="centos"; PKG_MANAGER="yum"
                command -v dnf &>/dev/null && PKG_MANAGER="dnf"
                ;;
            fedora)
                OS_TYPE="centos"; PKG_MANAGER="dnf" ;;
            arch|manjaro|endeavouros)
                OS_TYPE="arch"; PKG_MANAGER="pacman" ;;
            opensuse*|sles)
                OS_TYPE="suse"; PKG_MANAGER="zypper" ;;
            alpine)
                OS_TYPE="alpine"; PKG_MANAGER="apk" ;;
            *)
                if echo "$id_like_lower" | grep -qE "debian|ubuntu"; then
                    OS_TYPE="debian"; PKG_MANAGER="apt"
                elif echo "$id_like_lower" | grep -qE "rhel|centos|fedora"; then
                    OS_TYPE="centos"
                    command -v dnf &>/dev/null && PKG_MANAGER="dnf" || PKG_MANAGER="yum"
                elif echo "$id_like_lower" | grep -qE "arch"; then
                    OS_TYPE="arch"; PKG_MANAGER="pacman"
                else
                    OS_TYPE="unknown"; PKG_MANAGER="unknown"
                fi
                ;;
        esac
    elif [[ -f /etc/alpine-release ]]; then
        OS_TYPE="alpine"; PKG_MANAGER="apk"
    else
        OS_TYPE="unknown"; PKG_MANAGER="unknown"
    fi

    [[ $IS_CRON -eq 0 ]] && info "系统: $OS_TYPE | 架构: $ARCH | 包管理器: $PKG_MANAGER"
}

# ============================================================
# 依赖安装
# ============================================================
install_dependencies() {
    local missing=()
    command -v crontab &>/dev/null || {
        case "$OS_TYPE" in
            debian) missing+=("cron") ;;
            centos) missing+=("cronie") ;;
            arch)   missing+=("cronie") ;;
            alpine) missing+=("dcron") ;;
        esac
    }

    if [[ ${#missing[@]} -gt 0 ]]; then
        yellow "安装缺失依赖: ${missing[*]}..."
        case "$OS_TYPE" in
            debian)  sudo apt-get update -qq && sudo apt-get install -y -qq "${missing[@]}" || true ;;
            centos)
                if [[ "$PKG_MANAGER" == "dnf" ]]; then
                    sudo dnf install -y -q "${missing[@]}" || true
                else
                    sudo yum install -y -q "${missing[@]}" || true
                fi
                ;;
            arch)    sudo pacman -Sy --noconfirm "${missing[@]}" || true ;;
            alpine)  sudo apk add --no-cache "${missing[@]}" || true ;;
        esac
    fi
}

# ============================================================
# 清理模块 1：临时文件
# ============================================================
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
}

# ============================================================
# 清理模块 2：系统日志
# ============================================================
clean_logs() {
    yellow "[2/12] 清理系统日志..."

    # journalctl
    if command -v journalctl &>/dev/null; then
        local j_before=0 j_after=0
        [[ -d /var/log/journal ]] && j_before=$(get_dir_size /var/log/journal)
        [[ -d /run/log/journal ]] && j_before=$(( j_before + $(get_dir_size /run/log/journal) ))

        safe_exec "sudo journalctl --vacuum-time=2d --vacuum-size=100M"

        [[ -d /var/log/journal ]] && j_after=$(get_dir_size /var/log/journal)
        [[ -d /run/log/journal ]] && j_after=$(( j_after + $(get_dir_size /run/log/journal) ))

        local j_freed=$(( j_before - j_after ))
        (( j_freed < 0 )) && j_freed=0
        (( j_freed > 0 )) && success "Journal释放: $(bytes_to_human $j_freed)"
    fi

    # 旧日志
    safe_exec "find /var/log -type f \( -name '*.log.*' -o -name '*.gz' -o -name '*.xz' -o -name '*.bz2' -o -name '*.old' -o -name '*.1' -o -name '*.2' -o -name '*.3' \) -mtime +2 -delete"

    # truncate 大日志（保留文件不删除）
    safe_exec "find /var/log -type f -name '*.log' -size +50M -exec truncate -s 0 {} \;"

    # wtmp / btmp / lastlog
    for f in /var/log/wtmp /var/log/btmp /var/log/lastlog; do
        if [[ -f "$f" ]]; then
            local fsize
            fsize=$(get_file_size "$f")
            if (( fsize > 10485760 )); then
                safe_exec "sudo truncate -s 0 '$f'"
                success "已清空 $f ($(bytes_to_human $fsize))"
            fi
        fi
    done

    success "系统日志清理完成"
}

# ============================================================
# 清理模块 3：旧内核
# ============================================================
clean_old_kernels() {
    yellow "[3/12] 清理旧内核..."
    local current_kernel
    current_kernel=$(uname -r)

    case "$OS_TYPE" in
        debian)
            local old_kernels
            old_kernels=$(dpkg -l 2>/dev/null \
                | grep '^ii' \
                | awk '{print $2}' \
                | grep -E '^linux-(image|headers|modules)-[0-9]' \
                | grep -v "$(echo "$current_kernel" | sed 's/-generic//' | sed 's/-[a-z]*$//')" \
                || true)

            if [[ -n "$old_kernels" ]]; then
                success "当前内核: $current_kernel"
                warn "旧内核包:"
                echo "$old_kernels" | sed 's/^/    /'

                local do_clean=0
                if [[ $IS_CRON -eq 1 || $AGGRESSIVE -eq 1 ]]; then
                    do_clean=1
                else
                    read -p "  删除旧内核? [y/N]: " ans
                    [[ "${ans:-n}" =~ ^[Yy]$ ]] && do_clean=1
                fi

                if [[ $do_clean -eq 1 ]]; then
                    safe_exec "DEBIAN_FRONTEND=noninteractive sudo apt-get purge -y --auto-remove $old_kernels"
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
                safe_exec "sudo package-cleanup --oldkernels --count=1 -y"
            elif command -v dnf &>/dev/null; then
                safe_exec "sudo dnf remove --oldinstallonly --setopt installonly_limit=2 -y"
            fi
            success "旧内核检查完成"
            ;;

        arch)
            command -v paccache &>/dev/null && safe_exec "sudo paccache -r"
            ;;
    esac
}

# ============================================================
# 清理模块 4：包管理器
# ============================================================
clean_package_manager() {
    yellow "[4/12] 清理包管理器缓存..."
    export DEBIAN_FRONTEND=noninteractive

    case "$OS_TYPE" in
        debian)
            local before
            before=$(get_dir_size /var/cache/apt)
            safe_exec "sudo apt-get clean -y"
            safe_exec "sudo apt-get autoclean -y"
            safe_exec "sudo apt-get autoremove -y --purge"

            # 残留配置包
            local rc_pkgs
            rc_pkgs=$(dpkg -l 2>/dev/null | awk '/^rc/{print $2}' || true)
            if [[ -n "$rc_pkgs" ]]; then
                safe_exec "echo '$rc_pkgs' | xargs sudo dpkg --purge"
                success "残留配置: $(echo "$rc_pkgs" | wc -w) 个已清理"
            fi

            # 激进：清 apt lists
            if [[ $AGGRESSIVE -eq 1 ]]; then
                safe_exec "sudo rm -rf /var/lib/apt/lists/*"
                success "APT lists 已清理 (apt update 可恢复)"
            fi

            local after
            after=$(get_dir_size /var/cache/apt)
            local freed=$(( before - after ))
            (( freed < 0 )) && freed=0
            success "APT缓存释放: $(bytes_to_human $freed)"
            ;;

        centos)
            if [[ "$PKG_MANAGER" == "dnf" ]]; then
                safe_exec "sudo dnf clean all"
                safe_exec "sudo dnf autoremove -y"
                safe_exec "sudo rm -rf /var/cache/dnf/*"
            else
                safe_exec "sudo yum clean all"
                safe_exec "sudo yum autoremove -y"
                safe_exec "sudo rm -rf /var/cache/yum/*"
            fi
            success "YUM/DNF 缓存已清理"
            ;;

        arch)
            safe_exec "sudo pacman -Sc --noconfirm"
            command -v paccache &>/dev/null && safe_exec "sudo paccache -rk2"
            # 孤立包
            local orphans
            orphans=$(pacman -Qdtq 2>/dev/null || true)
            if [[ -n "$orphans" ]]; then
                safe_exec "echo '$orphans' | sudo pacman -Rns --noconfirm -"
                success "孤立包已清理"
            fi
            success "Pacman 缓存已清理"
            ;;

        alpine)
            safe_exec "sudo apk cache clean"
            safe_exec "sudo rm -rf /var/cache/apk/*"
            success "APK 缓存已清理"
            ;;

        suse)
            safe_exec "sudo zypper clean --all"
            success "Zypper 缓存已清理"
            ;;
    esac
}

# ============================================================
# 清理模块 5：Snap
# ============================================================
clean_snap() {
    command -v snap &>/dev/null || return 0

    yellow "[5/12] 清理 Snap 旧版本..."

    snap list --all 2>/dev/null \
        | awk '/disabled/{print $1, $3}' \
        | while read -r snapname revision; do
            safe_exec "sudo snap remove '$snapname' --revision='$revision'"
            success "移除 $snapname (rev $revision)"
          done

    if [[ -d /var/lib/snapd/cache ]]; then
        local sz
        sz=$(get_dir_size /var/lib/snapd/cache)
        safe_exec "sudo rm -rf /var/lib/snapd/cache/*"
        success "Snap缓存释放: $(bytes_to_human $sz)"
    fi
}

# ============================================================
# 清理模块 6：Flatpak
# ============================================================
clean_flatpak() {
    command -v flatpak &>/dev/null || return 0

    yellow "[6/12] 清理 Flatpak..."
    safe_exec "sudo flatpak uninstall --unused -y"
    success "Flatpak 清理完成"
}

# ============================================================
# 清理模块 7：Docker
# ============================================================
clean_docker() {
    command -v docker &>/dev/null || return 0
    docker info &>/dev/null || { skip "Docker 未运行"; return 0; }

    yellow "[7/12] 清理 Docker..."

    [[ $IS_CRON -eq 0 ]] && { info "Docker 磁盘使用:"; docker system df 2>/dev/null || true; echo ""; }

    # 停止的容器
    local stopped
    stopped=$(docker ps -aq --filter "status=exited" 2>/dev/null || true)
    [[ -n "$stopped" ]] && safe_exec "docker rm $stopped"

    # 悬挂镜像
    safe_exec "docker image prune -f"

    # 未使用网络
    safe_exec "docker network prune -f"

    # 构建缓存
    safe_exec "docker builder prune -af"

    # 激进/定时任务：全面清理
    if [[ $AGGRESSIVE -eq 1 || $IS_CRON -eq 1 ]]; then
        safe_exec "docker system prune -af --volumes"
        success "Docker 深度清理完成"
    else
        # 标准模式询问是否清理未使用卷
        read -p "  清理 Docker 未使用的卷? [y/N]: " ans
        [[ "${ans:-n}" =~ ^[Yy]$ ]] && safe_exec "docker volume prune -f"
        success "Docker 清理完成"
    fi
}

# ============================================================
# 清理模块 8：开发环境缓存
# ============================================================
clean_dev_caches() {
    yellow "[8/12] 清理开发环境缓存..."
    local found=0

    # --- Node.js ---
    if command -v npm &>/dev/null; then
        found=1
        local npm_dir
        npm_dir=$(npm config get cache 2>/dev/null || echo "$HOME/.npm")
        local npm_sz=0
        [[ -d "$npm_dir" ]] && npm_sz=$(get_dir_size "$npm_dir")
        safe_exec "npm cache clean --force"
        success "NPM: $(bytes_to_human $npm_sz)"
    fi
    if command -v yarn &>/dev/null; then
        found=1
        safe_exec "yarn cache clean"
        success "Yarn 缓存已清理"
    fi
    if command -v pnpm &>/dev/null; then
        found=1
        safe_exec "pnpm store prune"
        success "pnpm store 已修剪"
    fi

    # --- Python ---
    if command -v pip3 &>/dev/null; then
        found=1
        safe_exec "pip3 cache purge"
        success "pip3 缓存已清理"
    elif command -v pip &>/dev/null; then
        found=1
        safe_exec "pip cache purge"
        success "pip 缓存已清理"
    fi
    if command -v uv &>/dev/null; then
        found=1
        safe_exec "uv cache clean"
        success "uv 缓存已清理"
    fi
    if command -v conda &>/dev/null; then
        found=1
        safe_exec "conda clean --all -y"
        success "conda 缓存已清理"
    fi

    # --- Go ---
    if command -v go &>/dev/null; then
        found=1
        local go_cache go_sz=0
        go_cache=$(go env GOCACHE 2>/dev/null || echo "")
        [[ -n "$go_cache" && -d "$go_cache" ]] && go_sz=$(get_dir_size "$go_cache")
        safe_exec "go clean -cache"
        safe_exec "go clean -testcache"
        [[ $AGGRESSIVE -eq 1 ]] && safe_exec "go clean -modcache"
        success "Go 缓存: $(bytes_to_human $go_sz)"
    fi

    # --- Rust ---
    if command -v cargo &>/dev/null && [[ $AGGRESSIVE -eq 1 ]]; then
        found=1
        if [[ -d "$HOME/.cargo/registry" ]]; then
            local cargo_sz
            cargo_sz=$(get_dir_size "$HOME/.cargo/registry")
            safe_exec "rm -rf '$HOME/.cargo/registry/cache' '$HOME/.cargo/registry/src'"
            success "Cargo: $(bytes_to_human $cargo_sz)"
        fi
    fi

    # --- Java ---
    if [[ -d "$HOME/.m2/repository" && $AGGRESSIVE -eq 1 ]]; then
        found=1
        safe_exec "find '$HOME/.m2/repository' -type f -atime +30 -delete"
        success "Maven 旧依赖已清理"
    fi
    if [[ -d "$HOME/.gradle/caches" && $AGGRESSIVE -eq 1 ]]; then
        found=1
        safe_exec "find '$HOME/.gradle/caches' -type f -atime +30 -delete"
        success "Gradle 旧缓存已清理"
    fi

    # --- PHP ---
    if command -v composer &>/dev/null; then
        found=1
        safe_exec "composer clearcache"
        success "Composer 缓存已清理"
    fi

    # --- Ruby ---
    if command -v gem &>/dev/null; then
        found=1
        safe_exec "gem cleanup"
        success "Ruby Gem 旧版本已清理"
    fi

    (( found == 0 )) && skip "未检测到开发环境"
}

# ============================================================
# 清理模块 9：用户缓存
# ============================================================
clean_user_caches() {
    yellow "[9/12] 清理用户缓存..."

    # 编辑器临时文件
    safe_exec "find /home /root -type f \( -name '*.swp' -o -name '*.swo' -o -name '*~' -o -name '*.save' -o -name '*.bak' -o -name '#*#' \) -delete"
    success "编辑器临时文件已清理"

    # 缩略图
    safe_exec "find /home /root -type d -name 'thumbnails' -exec rm -rf {} +"

    # 回收站
    safe_exec "find /home /root -path '*/.local/share/Trash/*' -delete"
    safe_exec "find /home /root -path '*/.local/share/Trash' -type d -exec rm -rf {}/* +"
    success "回收站已清空"

    # .cache 目录 (>7天)
    for user_home in /home/* /root; do
        [[ -d "$user_home/.cache" ]] || continue
        safe_exec "find '$user_home/.cache' -type f -atime +7 -delete"
        safe_exec "find '$user_home/.cache' -type d -empty -delete"
    done
    success "用户 .cache 已清理 (>7天未访问)"

    # 激进：清空 shell 历史
    if [[ $AGGRESSIVE -eq 1 ]]; then
        safe_exec "find /home /root -maxdepth 1 \( -name '.bash_history' -o -name '.zsh_history' -o -name '.ash_history' \) -exec truncate -s 0 {} \;"
        success "Shell 历史已清空"
    fi
}

# ============================================================
# 清理模块 10：崩溃转储
# ============================================================
clean_coredumps() {
    yellow "[10/12] 清理崩溃转储..."

    # systemd coredump
    if [[ -d /var/lib/systemd/coredump ]]; then
        local sz
        sz=$(get_dir_size /var/lib/systemd/coredump)
        safe_exec "sudo rm -rf /var/lib/systemd/coredump/*"
        (( sz > 0 )) && success "Coredump: $(bytes_to_human $sz)"
    fi

    # 传统 core 文件
    safe_exec "find /tmp /home /root /var -maxdepth 3 -type f \( -name 'core' -size +1M -o -name 'core.[0-9]*' \) -delete"

    # Ubuntu apport 崩溃报告
    if [[ -d /var/crash ]]; then
        local crash_sz
        crash_sz=$(get_dir_size /var/crash)
        safe_exec "sudo rm -rf /var/crash/*"
        (( crash_sz > 0 )) && success "崩溃报告: $(bytes_to_human $crash_sz)"
    fi

    success "崩溃转储清理完成"
}

# ============================================================
# 清理模块 11：系统杂项
# ============================================================
clean_misc() {
    yellow "[11/12] 清理系统杂项..."

    # 各种系统缓存
    for dir in /var/cache/fontconfig /var/cache/man /var/cache/ldconfig; do
        [[ -d "$dir" ]] && safe_exec "sudo rm -rf '$dir'/*"
    done

    # DHCP 过期租约
    safe_exec "find /var/lib/dhcp /var/lib/dhclient -name '*.leases~' -delete"

    # SSH 旧记录
    safe_exec "find /home /root -maxdepth 2 -name 'known_hosts.old' -delete"

    # systemd 失败单元
    safe_exec "sudo systemctl reset-failed"

    # pip/npm 临时目录
    safe_exec "find /tmp -maxdepth 1 \( -name 'pip-*' -o -name 'npm-*' -o -name 'yarn-*' \) -type d -mtime +1 -exec rm -rf {} +"

    if [[ $AGGRESSIVE -eq 1 ]]; then
        # 多余 locale（只保留 en/zh/C/POSIX）
        if [[ -d /usr/share/locale ]]; then
            safe_exec "find /usr/share/locale -mindepth 1 -maxdepth 1 -type d ! -name 'en*' ! -name 'zh*' ! -name 'C' ! -name 'POSIX' -exec rm -rf {} +"
            success "多余 locale 已清理"
        fi

        # 无用文档
        if [[ -d /usr/share/doc ]]; then
            safe_exec "find /usr/share/doc -type f ! -name 'copyright' ! -name 'changelog*' -delete"
            success "无用文档已清理"
        fi

        # man 页面缓存
        safe_exec "find /var/cache/man -type f -delete"
    fi

    success "杂项清理完成"
}

# ============================================================
# 清理模块 12：已删除未释放文件
# ============================================================
clean_deleted_open_files() {
    yellow "[12/12] 检测已删除但仍占空间的文件..."

    # 只在有 lsof 时执行
    if ! command -v lsof &>/dev/null; then
        skip "lsof 未安装，跳过 (可选: apt install lsof)"
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
        warn "重启相关服务（如 nginx、rsyslog）可释放空间"
    fi
}

# ============================================================
# 磁盘占用分析
# ============================================================
disk_usage_analysis() {
    echo ""
    cyan "=== 根目录 Top 15 大目录 ==="
    du -hx --max-depth=3 / 2>/dev/null | sort -rh | head -15 | awk '{printf "  %-8s %s\n", $1, $2}'
    echo ""
    cyan "=== Top 10 大文件 (>100MB) ==="
    find / -xdev -type f -size +100M 2>/dev/null \
        | head -30 \
        | xargs -I{} du -h {} 2>/dev/null \
        | sort -rh \
        | head -10 \
        | awk '{printf "  %-8s %s\n", $1, $2}'
    echo ""
}

# ============================================================
# 主清理流程
# ============================================================
clean_system() {
    detect_system

    local space_before space_before_bytes
    space_before=$(get_root_avail)
    space_before_bytes=$(get_root_avail_bytes)

    echo ""
    bold ">> 开始系统深度清理..."
    info "系统: $OS_TYPE | 架构: $ARCH"
    info "清理前可用: $space_before"
    echo ""

    # 交互模式选择等级
    if [[ $IS_CRON -eq 0 ]]; then
        echo "清理等级:"
        echo "  1) 标准清理 (安全，日常推荐)"
        echo "  2) 深度清理 (旧内核 + 激进缓存)"
        echo "  3) 仅分析磁盘占用"
        read -p "选择 [1/2/3，默认 1]: " level
        case "${level:-1}" in
            2) AGGRESSIVE=1 ;;
            3) disk_usage_analysis; return 0 ;;
            *) AGGRESSIVE=0 ;;
        esac
    fi

    echo ""

    # 按顺序执行全部12个模块
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

    # ========== 最终统计 ==========
    local space_after space_after_bytes freed
    space_after=$(get_root_avail)
    space_after_bytes=$(get_root_avail_bytes)
    freed=$(( space_after_bytes - space_before_bytes ))
    (( freed < 0 )) && freed=0

    echo ""
    echo "=================================================="
    green "            系统清理完成!"
    echo "=================================================="
    green "  清理前可用:  $space_before"
    green "  清理后可用:  $space_after"
    if (( freed > 1024 )); then
        green "  本次释放:    $(bytes_to_human $freed)"
    else
        yellow "  本次释放:    < 1 KB (系统已很干净)"
    fi
    echo "=================================================="

    # 交互模式：询问是否分析磁盘
    if [[ $IS_CRON -eq 0 ]]; then
        echo ""
        read -p "查看磁盘占用分析? [y/N]: " show
        [[ "${show:-n}" =~ ^[Yy]$ ]] && disk_usage_analysis
    fi

    # 显式返回成功，确保回到菜单
    return 0
}

# ============================================================
# 定时任务 —— 默认深度清理
# ============================================================
setup_cron() {
    detect_system
    install_dependencies

    local script_path
    script_path="$(realpath "$0")"

    echo ""
    echo "定时清理频率:"
    echo "  1) 每天 03:00"
    echo "  2) 每两天 03:00 (推荐)"
    echo "  3) 每周日 03:00"
    echo "  4) 每月 1 号 03:00"
    echo "  5) 自定义 cron 表达式"
    read -p "选择 [1-5，默认 2]: " freq

    local schedule
    case "${freq:-2}" in
        1) schedule="0 3 * * *" ;;
        2) schedule="0 3 */2 * *" ;;
        3) schedule="0 3 * * 0" ;;
        4) schedule="0 3 1 * *" ;;
        5) read -p "输入 cron 表达式 (分 时 日 月 周): " schedule ;;
        *) schedule="0 3 */2 * *" ;;
    esac

    # 关键：定时任务带 --aggressive 确保深度清理
    local cron_job="$schedule /bin/bash $script_path --cron --aggressive >> /var/log/clean-cron.log 2>&1"

    local tmpfile
    tmpfile=$(mktemp)
    sudo crontab -l 2>/dev/null | grep -v "$script_path" > "$tmpfile" || true
    echo "$cron_job" >> "$tmpfile"
    sudo crontab "$tmpfile"
    rm -f "$tmpfile"

    echo ""
    success "定时任务已设置"
    green "  频率: $schedule"
    green "  模式: 深度清理 (--aggressive)"
    green "  日志: /var/log/clean-cron.log"
    echo ""
    yellow "当前 crontab:"
    sudo crontab -l
    echo ""

    return 0
}

# ============================================================
# 快捷命令
# ============================================================
create_symlink() {
    while true; do
        read -p "输入快捷命令名 (如 clean): " shortcut
        [[ "$shortcut" =~ ^[a-zA-Z0-9_-]+$ ]] || { red "无效名称"; continue; }

        local target="/usr/local/bin/$shortcut"
        if [[ -e "$target" ]]; then
            read -p "'$shortcut' 已存在，覆盖? [y/N]: " ow
            [[ "${ow:-n}" =~ ^[Yy]$ ]] || continue
            sudo rm -f "$target"
        fi

        sudo ln -sf "$(realpath "$0")" "$target"
        sudo chmod +x "$target"
        success "快捷命令 '$shortcut' 已创建"
        break
    done
    return 0
}

# ============================================================
# 卸载
# ============================================================
uninstall() {
    local script_path
    script_path="$(realpath "$0")"

    # 移除 crontab
    local tmpfile
    tmpfile=$(mktemp)
    sudo crontab -l 2>/dev/null | grep -v "$script_path" > "$tmpfile" || true
    sudo crontab "$tmpfile"
    rm -f "$tmpfile"
    success "定时任务已移除"

    # 移除快捷链接
    find /usr/local/bin -lname "$script_path" -delete 2>/dev/null || true
    success "快捷链接已移除"

    read -p "删除脚本本身? [y/N]: " del
    if [[ "${del:-n}" =~ ^[Yy]$ ]]; then
        rm -f "$script_path"
        success "脚本已删除"
    fi

    green "卸载完成"
    return 0
}

# ============================================================
# 主函数
# ============================================================
main() {
    # 参数解析
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cron)       IS_CRON=1;    shift ;;
            --dry-run)    DRY_RUN=1;    shift ;;
            --aggressive) AGGRESSIVE=1; shift ;;
            --help|-h)
                cat <<'EOF'
系统深度清理工具 v2.2

用法: clean [选项]
  --cron         静默模式 (定时任务)
  --dry-run      模拟运行，不实际删除
  --aggressive   激进深度清理
  --help         帮助

定时任务自动以 --cron --aggressive 运行
EOF
                exit 0
                ;;
            *) red "未知参数: $1"; exit 1 ;;
        esac
    done

    # root 提示
    if [[ $EUID -ne 0 ]]; then
        yellow "提示: 建议使用 sudo 运行以获得完整清理效果"
    fi

    init_log

    # 静默模式：直接清理
    if [[ $IS_CRON -eq 1 ]]; then
        detect_system
        # 定时任务始终用深度模式
        AGGRESSIVE=1
        clean_system
        echo "========== $(date '+%Y-%m-%d %H:%M:%S') 完成 =========="
        exit 0
    fi

    # ========== 交互菜单循环 ==========
    while true; do
        echo ""
        cyan "=============================="
        cyan "  系统深度清理工具 v2.2"
        cyan "=============================="
        echo "  1. 执行清理"
        echo "  2. 设置定时任务"
        echo "  3. 创建快捷命令"
        echo "  4. 磁盘占用分析"
        echo "  5. 卸载本工具"
        echo "  6. 退出"
        cyan "=============================="
        read -p "选择 [1-6]: " choice

        case "${choice:-}" in
            1) clean_system ;;
            2) setup_cron ;;
            3) create_symlink ;;
            4) detect_system; disk_usage_analysis ;;
            5) uninstall; exit 0 ;;
            6) green "再见!"; exit 0 ;;
            *) red "无效选项" ;;
        esac
    done
}

main "$@"
