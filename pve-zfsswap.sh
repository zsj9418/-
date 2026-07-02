#!/bin/sh

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
PLAIN='\033[0m'

SWAP_FILE=""
SWAP_SIZE_MB=""
SWAPPINESS=""
CHOSEN_MOUNT=""
CHOSEN_DEV=""
CHOSEN_TYPE=""
CHOSEN_AVAIL_KB=""
CHOSEN_FSTYPE=""
SYSTEM_TYPE=""
ROOT_FS_TYPE=""
STORAGE_COUNT=0
MEM_TOTAL_MB=0
HAS_ZFS="no"
ZFS_DATASET="rpool/swap"
ZFS_ZVOL="/dev/zvol/rpool/swap"
TEMP_SWAP_FILE=""
TEMP_SWAP_MARKER="/var/run/swap_temp_active"

# ---------- 工具函数 ----------
print_line() {
    printf "────────────────────────────────────────────────────────\n"
}

print_title() {
    printf "\n"
    print_line
    printf "${CYAN}  %s${PLAIN}\n" "$1"
    print_line
}

print_info() {
    printf "  ${GREEN}[✓]${PLAIN} %s\n" "$1"
}

print_warn() {
    printf "  ${YELLOW}[!]${PLAIN} %s\n" "$1"
}

print_error() {
    printf "  ${RED}[✗]${PLAIN} %s\n" "$1"
}

confirm_yes_no() {
    printf "\n"
    printf "  ${YELLOW}%s [y/N]: ${PLAIN}" "$1"
    read answer
    case "$answer" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

confirm_type_yes() {
    printf "\n"
    printf "  ${RED}%s${PLAIN}\n" "$1"
    printf "  ${YELLOW}请输入 'yes' 确认: ${PLAIN}"
    read answer
    [ "$answer" = "yes" ]
}

# ---------- 检查 root ----------
check_root() {
    if [ "$(id -u)" != "0" ]; then
        print_error "请以 root 用户运行此脚本！"
        exit 1
    fi
}

# ---------- 检测系统信息 ----------
detect_system() {
    print_title "① 检测系统信息"

    if [ -f /etc/openwrt_release ]; then
        . /etc/openwrt_release
        SYSTEM_TYPE="openwrt"
        SYS_NAME="${DISTRIB_ID:-OpenWrt}"
        SYS_VER="${DISTRIB_RELEASE:-unknown}"
        SYS_DESC="${DISTRIB_DESCRIPTION:-unknown}"
    elif [ -f /etc/os-release ]; then
        . /etc/os-release
        SYSTEM_TYPE="linux"
        SYS_NAME="${NAME:-Linux}"
        SYS_VER="${VERSION_ID:-unknown}"
        SYS_DESC="${PRETTY_NAME:-unknown}"
    else
        SYSTEM_TYPE="linux"
        SYS_NAME="Unknown Linux"
        SYS_VER="unknown"
        SYS_DESC="Unknown"
    fi

    # 检测 Armbian
    IS_ARMBIAN="no"
    if [ -f /etc/armbian-release ] || printf "%s" "$SYS_DESC" | grep -qi "armbian"; then
        IS_ARMBIAN="yes"
    fi

    ARCH=$(uname -m)
    KERNEL=$(uname -r)

    MEM_TOTAL_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    MEM_TOTAL_MB=$((MEM_TOTAL_KB / 1024))

    SWAP_TOTAL_KB=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
    SWAP_TOTAL_MB=$((SWAP_TOTAL_KB / 1024))

    ROOT_FS_TYPE=$(df -T / 2>/dev/null | awk 'NR==2 {print $2}')
    if [ -z "$ROOT_FS_TYPE" ]; then
        ROOT_FS_TYPE=$(mount | grep ' / ' | head -1 | awk '{print $5}')
    fi

    HAS_ZFS="no"
    if command -v zfs >/dev/null 2>&1; then
        if zpool list >/dev/null 2>&1; then
            HAS_ZFS="yes"
        fi
    fi

    # 检测 zram swap
    HAS_ZRAM_SWAP="no"
    ZRAM_SWAP_DEV=""
    ZRAM_SWAP_SIZE=""
    ZRAM_SERVICE=""

    if grep -q '/dev/zram' /proc/swaps 2>/dev/null; then
        HAS_ZRAM_SWAP="yes"
        ZRAM_SWAP_DEV=$(awk '/\/dev\/zram/ {print $1}' /proc/swaps | head -1)
        ZRAM_SWAP_SIZE=$(awk '/\/dev\/zram/ {print int($3/1024)}' /proc/swaps | head -1)
    fi

    # 检测 zram 服务来源
    if [ "$HAS_ZRAM_SWAP" = "yes" ] || command -v zramctl >/dev/null 2>&1; then
        if systemctl list-unit-files 2>/dev/null | grep -qi "armbian-zram"; then
            ZRAM_SERVICE="armbian-zram-config"
        elif systemctl list-unit-files 2>/dev/null | grep -qi "zram-generator"; then
            ZRAM_SERVICE="systemd-zram-generator"
        elif systemctl list-unit-files 2>/dev/null | grep -qi "zramswap"; then
            ZRAM_SERVICE="zramswap"
        elif [ -f /etc/systemd/zram-generator.conf ]; then
            ZRAM_SERVICE="systemd-zram-generator"
        elif [ -f /etc/default/armbian-zram-config ]; then
            ZRAM_SERVICE="armbian-zram-config"
        elif [ -f /etc/default/zramswap ]; then
            ZRAM_SERVICE="zramswap"
        fi
    fi

    printf "  系统类型：    ${GREEN}%s${PLAIN}\n" "$SYS_DESC"
    printf "  平台识别：    ${GREEN}%s${PLAIN}" "$SYSTEM_TYPE"
    if [ "$IS_ARMBIAN" = "yes" ]; then
        printf " ${CYAN}(Armbian)${PLAIN}"
    fi
    printf "\n"
    printf "  CPU 架构：    ${GREEN}%s${PLAIN}\n" "$ARCH"
    printf "  内核版本：    ${GREEN}%s${PLAIN}\n" "$KERNEL"
    printf "  物理内存：    ${GREEN}%s MB${PLAIN}\n" "$MEM_TOTAL_MB"
    printf "  根文件系统：  ${GREEN}%s${PLAIN}\n" "$ROOT_FS_TYPE"
    printf "  ZFS 支持：    ${GREEN}%s${PLAIN}\n" "$HAS_ZFS"

    if [ "$HAS_ZRAM_SWAP" = "yes" ]; then
        printf "  zram Swap：   ${YELLOW}%s (%s MB)${PLAIN}\n" "$ZRAM_SWAP_DEV" "$ZRAM_SWAP_SIZE"
        if [ -n "$ZRAM_SERVICE" ]; then
            printf "  zram 服务：   ${YELLOW}%s${PLAIN}\n" "$ZRAM_SERVICE"
        fi
    fi

    if [ "$SWAP_TOTAL_MB" -gt 0 ]; then
        printf "  当前 Swap：   ${YELLOW}%s MB（已存在）${PLAIN}\n" "$SWAP_TOTAL_MB"
    else
        printf "  当前 Swap：   ${RED}无${PLAIN}\n"
    fi

    # btrfs 特别提示
    if [ "$ROOT_FS_TYPE" = "btrfs" ]; then
        printf "\n"
        print_warn "检测到 btrfs 文件系统，将使用 btrfs 专用方式创建 swapfile"
    fi
}

# ---------- 安装依赖 ----------
install_deps() {
    print_title "② 检查并安装依赖"

    if [ "$SYSTEM_TYPE" = "openwrt" ]; then
        NEED_INSTALL=""

        if ! command -v mkswap >/dev/null 2>&1; then
            NEED_INSTALL="${NEED_INSTALL} swap-utils"
            print_warn "缺少 mkswap（swap-utils）"
        else
            print_info "mkswap 已存在"
        fi

        if ! command -v swapon >/dev/null 2>&1; then
            if ! printf "%s" "$NEED_INSTALL" | grep -q "swap-utils"; then
                NEED_INSTALL="${NEED_INSTALL} swap-utils"
            fi
            print_warn "缺少 swapon"
        else
            print_info "swapon 已存在"
        fi

        if ! command -v block >/dev/null 2>&1; then
            NEED_INSTALL="${NEED_INSTALL} block-mount"
            print_warn "缺少 block（block-mount）"
        else
            print_info "block 已存在"
        fi

        if [ ! -f /etc/config/fstab ]; then
            if ! printf "%s" "$NEED_INSTALL" | grep -q "block-mount"; then
                NEED_INSTALL="${NEED_INSTALL} block-mount"
            fi
            print_warn "缺少 /etc/config/fstab"
        else
            print_info "/etc/config/fstab 已存在"
        fi

        if [ -n "$NEED_INSTALL" ]; then
            printf "\n"
            print_warn "需要安装：${NEED_INSTALL}"
            if confirm_yes_no "是否立即安装？"; then
                print_info "更新软件源..."
                opkg update
                if [ $? -ne 0 ]; then
                    print_error "opkg update 失败，请检查网络！"
                    exit 1
                fi
                for pkg in $NEED_INSTALL; do
                    print_info "安装 ${pkg}..."
                    opkg install "$pkg"
                    if [ $? -ne 0 ]; then
                        print_error "安装 ${pkg} 失败！"
                        exit 1
                    fi
                done
                print_info "依赖安装完成"
            else
                print_error "缺少依赖，无法继续"
                exit 1
            fi
        else
            print_info "所有依赖已满足"
        fi
    else
        ALL_OK=1
        for cmd in mkswap swapon swapoff free; do
            if command -v "$cmd" >/dev/null 2>&1; then
                print_info "$cmd 已存在"
            else
                print_warn "缺少 $cmd"
                ALL_OK=0
            fi
        done

        if [ "$ALL_OK" = "0" ]; then
            print_error "缺少必要命令，请先安装 util-linux"
            exit 1
        else
            print_info "所有依赖已满足"
        fi
    fi
}

# ============================================================
#  收集所有 swap 路径
# ============================================================
collect_all_swap_paths() {
    ALL_SWAP_PATHS=""
    ALL_SWAP_TYPES=""

    # 来源1: /proc/swaps
    if [ -f /proc/swaps ]; then
        proc_swaps=$(awk 'NR>1 {print $1}' /proc/swaps)
        for p in $proc_swaps; do
            ALL_SWAP_PATHS="${ALL_SWAP_PATHS} ${p}"
            case "$p" in
                /dev/zram*)   ALL_SWAP_TYPES="${ALL_SWAP_TYPES} zram" ;;
                /dev/zvol/*)  ALL_SWAP_TYPES="${ALL_SWAP_TYPES} zvol" ;;
                /dev/sd*|/dev/mmcblk*|/dev/nvme*|/dev/vd*)
                              ALL_SWAP_TYPES="${ALL_SWAP_TYPES} partition" ;;
                *)            ALL_SWAP_TYPES="${ALL_SWAP_TYPES} file" ;;
            esac
        done
    fi

    # 来源2: OpenWrt UCI
    if [ "$SYSTEM_TYPE" = "openwrt" ] && command -v uci >/dev/null 2>&1; then
        idx=0
        while true; do
            uci_dev=$(uci -q get fstab.@swap[${idx}].device 2>/dev/null)
            if [ -z "$uci_dev" ]; then
                break
            fi
            case " $ALL_SWAP_PATHS " in
                *" $uci_dev "*) ;;
                *) ALL_SWAP_PATHS="${ALL_SWAP_PATHS} ${uci_dev}"
                   ALL_SWAP_TYPES="${ALL_SWAP_TYPES} file" ;;
            esac
            idx=$((idx + 1))
        done
    fi

    # 来源3: /etc/fstab
    if [ -f /etc/fstab ]; then
        fstab_swaps=$(grep -v '^#' /etc/fstab | awk '/swap/ {print $1}')
        for p in $fstab_swaps; do
            case " $ALL_SWAP_PATHS " in
                *" $p "*) ;;
                *)
                    ALL_SWAP_PATHS="${ALL_SWAP_PATHS} ${p}"
                    case "$p" in
                        /dev/zram*)   ALL_SWAP_TYPES="${ALL_SWAP_TYPES} zram" ;;
                        /dev/zvol/*)  ALL_SWAP_TYPES="${ALL_SWAP_TYPES} zvol" ;;
                        /dev/*)       ALL_SWAP_TYPES="${ALL_SWAP_TYPES} partition" ;;
                        *)            ALL_SWAP_TYPES="${ALL_SWAP_TYPES} file" ;;
                    esac
                    ;;
            esac
        done
    fi

    # 来源4: 搜索常见 swapfile（含临时文件）
    for sf in /swapfile /swap /swapfile.temp \
              /mnt/*/swapfile /mnt/*/swapfile.temp \
              /opt/swapfile /opt/swapfile.temp; do
        if [ -f "$sf" ]; then
            case " $ALL_SWAP_PATHS " in
                *" $sf "*) ;;
                *) ALL_SWAP_PATHS="${ALL_SWAP_PATHS} ${sf}"
                   ALL_SWAP_TYPES="${ALL_SWAP_TYPES} file" ;;
            esac
        fi
    done

    # 来源5: find 搜索（含 .temp 后缀）
    found_files=$(find / -maxdepth 3 \( -name "swapfile" -o -name "swapfile.temp" \) -type f 2>/dev/null)
    for sf in $found_files; do
        case " $ALL_SWAP_PATHS " in
            *" $sf "*) ;;
            *) ALL_SWAP_PATHS="${ALL_SWAP_PATHS} ${sf}"
               ALL_SWAP_TYPES="${ALL_SWAP_TYPES} file" ;;
        esac
    done

    ALL_SWAP_PATHS=$(printf "%s" "$ALL_SWAP_PATHS" | sed 's/^ *//')
    ALL_SWAP_TYPES=$(printf "%s" "$ALL_SWAP_TYPES" | sed 's/^ *//')
}

# ============================================================
#  获取 swap 条目的类型描述
# ============================================================
get_swap_type_desc() {
    local path="$1"
    case "$path" in
        /dev/zram*)
            printf "zram（内存压缩设备，不占磁盘）" ;;
        /dev/zvol/*)
            printf "ZFS zvol（ZFS 虚拟卷）" ;;
        /dev/sd*|/dev/mmcblk*|/dev/nvme*|/dev/vd*)
            printf "swap 分区（磁盘分区）" ;;
        *)
            if [ -f "$path" ]; then
                local fs_type=$(df -T "$path" 2>/dev/null | awk 'NR==2 {print $2}')
                case "$path" in
                    *.temp) printf "临时 swap 文件（%s 文件系统）" "$fs_type" ;;
                    *)      printf "swap 文件（%s 文件系统）" "$fs_type" ;;
                esac
            else
                printf "配置残留（文件不存在）"
            fi
            ;;
    esac
}

# ---------- 查看 swap 状态 ----------
show_swap_status() {
    print_title "当前 Swap 状态"

    printf "  ── /proc/swaps ──\n"
    cat /proc/swaps
    printf "\n"

    printf "  ── 内存使用 ──\n"
    free -h 2>/dev/null || free
    printf "\n"

    printf "  ── swappiness ──\n"
    printf "  当前值: %s\n" "$(cat /proc/sys/vm/swappiness)"
    printf "\n"

    # zram 详情
    if command -v zramctl >/dev/null 2>&1; then
        zram_output=$(zramctl 2>/dev/null)
        if [ -n "$zram_output" ]; then
            printf "  ── zram 设备 ──\n"
            zramctl
            printf "\n"
        fi
    fi

    # swap 类型详情
    collect_all_swap_paths
    if [ -n "$ALL_SWAP_PATHS" ]; then
        printf "  ── Swap 类型分析 ──\n"
        for sp in $ALL_SWAP_PATHS; do
            type_desc=$(get_swap_type_desc "$sp")
            # 临时 swap 标记
            temp_tag=""
            case "$sp" in *.temp) temp_tag=" ${YELLOW}[临时]${PLAIN}" ;; esac
            if grep -q "$sp" /proc/swaps 2>/dev/null; then
                printf "    ${GREEN}●${PLAIN} %s%b\n" "$sp" "$temp_tag"
                printf "      类型: %s  状态: ${GREEN}使用中${PLAIN}\n" "$type_desc"
            else
                printf "    ${YELLOW}○${PLAIN} %s%b\n" "$sp" "$temp_tag"
                printf "      类型: %s  状态: ${YELLOW}未激活${PLAIN}\n" "$type_desc"
            fi
        done
        printf "\n"
    fi

    # 临时 swap 状态
    if [ -f "$TEMP_SWAP_MARKER" ]; then
        _tf=$(cat "$TEMP_SWAP_MARKER" 2>/dev/null)
        if [ -n "$_tf" ]; then
            printf "  ── 临时 Swap 状态 ──\n"
            if grep -q "$_tf" /proc/swaps 2>/dev/null; then
                _sz=$(awk -v p="$_tf" '$1==p {print int($3/1024)}' /proc/swaps)
                printf "    文件: ${GREEN}%s${PLAIN}  大小: ${GREEN}%s MB${PLAIN}  ${YELLOW}重启后自动清理${PLAIN}\n" "$_tf" "$_sz"
            else
                printf "    文件: ${YELLOW}%s${PLAIN}  ${RED}（已停用但文件残留）${PLAIN}\n" "$_tf"
            fi
            printf "\n"
        fi
    fi

    # zram 服务信息
    if [ -n "$ZRAM_SERVICE" ]; then
        printf "  ── zram 管理服务 ──\n"
        printf "    服务名: %s\n" "$ZRAM_SERVICE"
        if systemctl is-active "$ZRAM_SERVICE" >/dev/null 2>&1; then
            printf "    状态: ${GREEN}运行中${PLAIN}\n"
        else
            printf "    状态: ${YELLOW}未运行${PLAIN}\n"
        fi
        if systemctl is-enabled "$ZRAM_SERVICE" >/dev/null 2>&1; then
            printf "    开机自启: ${GREEN}已启用${PLAIN}\n"
        else
            printf "    开机自启: ${YELLOW}已禁用${PLAIN}\n"
        fi
        printf "\n"
    fi

    if [ "$SYSTEM_TYPE" = "openwrt" ] && [ -f /etc/config/fstab ]; then
        printf "  ── UCI fstab swap 配置 ──\n"
        uci show fstab 2>/dev/null | grep swap || printf "  无\n"
        printf "\n"
    fi

    if [ "$SYSTEM_TYPE" = "linux" ] && [ -f /etc/fstab ]; then
        printf "  ── /etc/fstab swap 条目 ──\n"
        grep -i swap /etc/fstab 2>/dev/null || printf "  无\n"
        printf "\n"
    fi

    printf "  ── 磁盘空间 ──\n"
    df -h | grep -vE 'tmpfs|devtmpfs|proc|sysfs|cgroup|debugfs|bpffs|devpts' | head -10
}

# ---------- 扫描存储设备 ----------
scan_storage() {
    print_title "③ 扫描可用存储设备"

    STORAGE_COUNT=0

    ROOT_DEV=$(df / | tail -1 | awk '{print $1}')
    ROOT_TOTAL=$(df -h / | tail -1 | awk '{print $2}')
    ROOT_AVAIL=$(df -h / | tail -1 | awk '{print $4}')
    ROOT_AVAIL_KB=$(df / | tail -1 | awk '{print $4}')

    if [ "$ROOT_AVAIL_KB" -gt 102400 ] 2>/dev/null; then
        STORAGE_COUNT=$((STORAGE_COUNT + 1))
        eval "STOR_${STORAGE_COUNT}_DEV='${ROOT_DEV}'"
        eval "STOR_${STORAGE_COUNT}_MOUNT='/'"
        eval "STOR_${STORAGE_COUNT}_TOTAL='${ROOT_TOTAL}'"
        eval "STOR_${STORAGE_COUNT}_AVAIL='${ROOT_AVAIL}'"
        eval "STOR_${STORAGE_COUNT}_AVAIL_KB='${ROOT_AVAIL_KB}'"
        eval "STOR_${STORAGE_COUNT}_FSTYPE='${ROOT_FS_TYPE}'"

        case "$ROOT_DEV" in
            /dev/mmcblk*)
                eval "STOR_${STORAGE_COUNT}_TYPE='eMMC/TF内部存储'"
                eval "STOR_${STORAGE_COUNT}_WARN='闪存设备，建议swappiness调低'" ;;
            /dev/nvme*)
                eval "STOR_${STORAGE_COUNT}_TYPE='NVMe SSD'"
                eval "STOR_${STORAGE_COUNT}_WARN=''" ;;
            /dev/sd*)
                eval "STOR_${STORAGE_COUNT}_TYPE='SATA/USB磁盘'"
                eval "STOR_${STORAGE_COUNT}_WARN=''" ;;
            *)
                case "$ROOT_FS_TYPE" in
                    zfs)  eval "STOR_${STORAGE_COUNT}_TYPE='ZFS根分区'"
                          eval "STOR_${STORAGE_COUNT}_WARN='推荐用zvol方式'" ;;
                    *)    eval "STOR_${STORAGE_COUNT}_TYPE='系统根分区'"
                          eval "STOR_${STORAGE_COUNT}_WARN=''" ;;
                esac
                ;;
        esac

        if [ "$ROOT_FS_TYPE" = "btrfs" ]; then
            eval "STOR_${STORAGE_COUNT}_WARN='btrfs: 将使用专用方式创建'"
        fi
    fi

    # 外接 /dev/sd*
    mount_lines=$(mount | grep '^/dev/sd' | awk '{print $1 ":" $3 ":" $5}')
    for mnt_line in $mount_lines; do
        EXT_DEV=$(printf "%s" "$mnt_line" | cut -d: -f1)
        EXT_MOUNT=$(printf "%s" "$mnt_line" | cut -d: -f2)
        EXT_FSTYPE=$(printf "%s" "$mnt_line" | cut -d: -f3)

        [ "$EXT_DEV" = "$ROOT_DEV" ] && continue

        EXT_AVAIL_KB=$(df "$EXT_MOUNT" 2>/dev/null | tail -1 | awk '{print $4}')

        if [ "$EXT_AVAIL_KB" -gt 102400 ] 2>/dev/null; then
            EXT_TOTAL=$(df -h "$EXT_MOUNT" | tail -1 | awk '{print $2}')
            EXT_AVAIL=$(df -h "$EXT_MOUNT" | tail -1 | awk '{print $4}')
            STORAGE_COUNT=$((STORAGE_COUNT + 1))
            eval "STOR_${STORAGE_COUNT}_DEV='${EXT_DEV}'"
            eval "STOR_${STORAGE_COUNT}_MOUNT='${EXT_MOUNT}'"
            eval "STOR_${STORAGE_COUNT}_TOTAL='${EXT_TOTAL}'"
            eval "STOR_${STORAGE_COUNT}_AVAIL='${EXT_AVAIL}'"
            eval "STOR_${STORAGE_COUNT}_AVAIL_KB='${EXT_AVAIL_KB}'"
            eval "STOR_${STORAGE_COUNT}_FSTYPE='${EXT_FSTYPE}'"
            eval "STOR_${STORAGE_COUNT}_TYPE='外接USB/SATA'"
            eval "STOR_${STORAGE_COUNT}_WARN='推荐，不伤内部闪存'"
        fi
    done

    # eMMC 其他分区 (OpenWrt)
    if [ "$SYSTEM_TYPE" = "openwrt" ]; then
        mount_lines=$(mount | grep '^/dev/mmcblk' | grep -v "$ROOT_DEV" | grep -v 'squashfs' | awk '{print $1 ":" $3 ":" $5}')
        for mnt_line in $mount_lines; do
            MMC_DEV=$(printf "%s" "$mnt_line" | cut -d: -f1)
            MMC_MOUNT=$(printf "%s" "$mnt_line" | cut -d: -f2)
            MMC_FSTYPE=$(printf "%s" "$mnt_line" | cut -d: -f3)

            case "$MMC_MOUNT" in
                /rom|/proc|/sys|/dev|/tmp) continue ;;
            esac

            MMC_AVAIL_KB=$(df "$MMC_MOUNT" 2>/dev/null | tail -1 | awk '{print $4}')
            if [ "$MMC_AVAIL_KB" -gt 102400 ] 2>/dev/null; then
                MMC_TOTAL=$(df -h "$MMC_MOUNT" | tail -1 | awk '{print $2}')
                MMC_AVAIL=$(df -h "$MMC_MOUNT" | tail -1 | awk '{print $4}')
                STORAGE_COUNT=$((STORAGE_COUNT + 1))
                eval "STOR_${STORAGE_COUNT}_DEV='${MMC_DEV}'"
                eval "STOR_${STORAGE_COUNT}_MOUNT='${MMC_MOUNT}'"
                eval "STOR_${STORAGE_COUNT}_TOTAL='${MMC_TOTAL}'"
                eval "STOR_${STORAGE_COUNT}_AVAIL='${MMC_AVAIL}'"
                eval "STOR_${STORAGE_COUNT}_AVAIL_KB='${MMC_AVAIL_KB}'"
                eval "STOR_${STORAGE_COUNT}_FSTYPE='${MMC_FSTYPE}'"
                eval "STOR_${STORAGE_COUNT}_TYPE='eMMC其他分区'"
                eval "STOR_${STORAGE_COUNT}_WARN='注意闪存写入寿命'"
            fi
        done
    fi

    # ZFS 池
    if [ "$HAS_ZFS" = "yes" ]; then
        ZFS_FREE=$(zpool list -H -o free rpool 2>/dev/null | sed 's/[^0-9.]//g')
        ZFS_SIZE=$(zpool list -H -o size rpool 2>/dev/null)
        if [ -n "$ZFS_FREE" ]; then
            ZFS_FREE_NUM=$(printf "%s" "$ZFS_FREE" | awk '{printf "%d", $1 * 1024 * 1024}')
            if [ "$ZFS_FREE_NUM" -gt 102400 ] 2>/dev/null; then
                STORAGE_COUNT=$((STORAGE_COUNT + 1))
                eval "STOR_${STORAGE_COUNT}_DEV='rpool (ZFS)'"
                eval "STOR_${STORAGE_COUNT}_MOUNT='ZFS Pool'"
                eval "STOR_${STORAGE_COUNT}_TOTAL='${ZFS_SIZE}'"
                eval "STOR_${STORAGE_COUNT}_AVAIL='${ZFS_FREE}G'"
                eval "STOR_${STORAGE_COUNT}_AVAIL_KB='${ZFS_FREE_NUM}'"
                eval "STOR_${STORAGE_COUNT}_FSTYPE='zfs'"
                eval "STOR_${STORAGE_COUNT}_TYPE='ZFS存储池'"
                eval "STOR_${STORAGE_COUNT}_WARN='zvol方式，性能最优'"
            fi
        fi
    fi

    if [ "$STORAGE_COUNT" -eq 0 ]; then
        print_error "未找到可用存储（需 > 100MB 空闲）"
        return 1
    fi

    printf "\n"
    printf "  ${BLUE}%-4s %-22s %-16s %-8s %-8s %-6s %s${PLAIN}\n" \
        "编号" "设备" "类型" "总容量" "可用" "格式" "说明"
    print_line

    i=1
    while [ $i -le $STORAGE_COUNT ]; do
        eval "s_dev=\${STOR_${i}_DEV}"
        eval "s_type=\${STOR_${i}_TYPE}"
        eval "s_total=\${STOR_${i}_TOTAL}"
        eval "s_avail=\${STOR_${i}_AVAIL}"
        eval "s_mount=\${STOR_${i}_MOUNT}"
        eval "s_warn=\${STOR_${i}_WARN}"
        eval "s_fs=\${STOR_${i}_FSTYPE}"
        printf "  %-4s %-22s %-16s %-8s %-8s %-6s %s\n" \
            "[$i]" "$s_dev" "$s_type" "$s_total" "$s_avail" "$s_fs" "$s_warn"
        printf "       挂载点: %s\n" "$s_mount"
        i=$((i + 1))
    done
}

# ---------- 用户选择存储 ----------
choose_storage() {
    print_title "④ 选择存储设备"

    printf "  请输入编号 [1-%s]: " "$STORAGE_COUNT"
    read choice

    if [ -z "$choice" ] || ! printf "%s" "$choice" | grep -qE '^[0-9]+$'; then
        print_error "请输入数字！"
        return 1
    fi
    if [ "$choice" -lt 1 ] || [ "$choice" -gt "$STORAGE_COUNT" ]; then
        print_error "编号超出范围！"
        return 1
    fi

    eval "CHOSEN_DEV=\${STOR_${choice}_DEV}"
    eval "CHOSEN_MOUNT=\${STOR_${choice}_MOUNT}"
    eval "CHOSEN_TYPE=\${STOR_${choice}_TYPE}"
    eval "CHOSEN_AVAIL=\${STOR_${choice}_AVAIL}"
    eval "CHOSEN_AVAIL_KB=\${STOR_${choice}_AVAIL_KB}"
    eval "CHOSEN_FSTYPE=\${STOR_${choice}_FSTYPE}"

    print_info "已选择：${CHOSEN_DEV}（${CHOSEN_TYPE}，${CHOSEN_FSTYPE}）"
    print_info "可用空间：${CHOSEN_AVAIL}"
    return 0
}

# ---------- 用户选择大小 ----------
choose_size() {
    print_title "⑤ 设置 Swap 大小"

    CHOSEN_AVAIL_MB=$((CHOSEN_AVAIL_KB / 1024))

    if [ "$MEM_TOTAL_MB" -le 128 ]; then
        REC_SIZE=256
    elif [ "$MEM_TOTAL_MB" -le 256 ]; then
        REC_SIZE=256
    elif [ "$MEM_TOTAL_MB" -le 512 ]; then
        REC_SIZE=512
    elif [ "$MEM_TOTAL_MB" -le 1024 ]; then
        REC_SIZE=512
    else
        REC_SIZE=$((MEM_TOTAL_MB * 2))
    fi

    MAX_SWAP=$((CHOSEN_AVAIL_MB - 500))
    if [ "$MAX_SWAP" -lt 64 ]; then
        print_error "可用空间不足！"
        return 1
    fi

    if [ "$REC_SIZE" -gt "$MAX_SWAP" ]; then
        REC_SIZE=$MAX_SWAP
    fi

    printf "  物理内存：  ${GREEN}%s MB${PLAIN}\n" "$MEM_TOTAL_MB"
    printf "  可用空间：  ${GREEN}%s MB${PLAIN}（最大可分配 %s MB）\n" "$CHOSEN_AVAIL_MB" "$MAX_SWAP"
    printf "  推荐大小：  ${GREEN}%s MB${PLAIN}\n" "$REC_SIZE"
    printf "\n"
    printf "  常用选项：\n"
    printf "    [1] 128 MB\n"
    printf "    [2] 256 MB\n"
    printf "    [3] 512 MB\n"
    printf "    [4] 1024 MB (1GB)\n"
    printf "    [5] 2048 MB (2GB)\n"
    printf "    [6] 4096 MB (4GB)\n"
    printf "    [7] 自定义大小\n"
    printf "\n"
    printf "  请选择 [1-7]（回车默认 %sMB）: " "$REC_SIZE"
    read size_choice

    case "$size_choice" in
        1) SWAP_SIZE_MB=128 ;;
        2) SWAP_SIZE_MB=256 ;;
        3) SWAP_SIZE_MB=512 ;;
        4) SWAP_SIZE_MB=1024 ;;
        5) SWAP_SIZE_MB=2048 ;;
        6) SWAP_SIZE_MB=4096 ;;
        7)
            printf "  请输入大小（MB，64-%s）: " "$MAX_SWAP"
            read custom_size
            if ! printf "%s" "$custom_size" | grep -qE '^[0-9]+$'; then
                print_error "请输入数字！"
                return 1
            fi
            if [ "$custom_size" -lt 64 ] || [ "$custom_size" -gt "$MAX_SWAP" ]; then
                print_error "超出范围（64-${MAX_SWAP}）！"
                return 1
            fi
            SWAP_SIZE_MB=$custom_size
            ;;
        "")
            SWAP_SIZE_MB=$REC_SIZE
            ;;
        *)
            print_error "无效选择！"
            return 1
            ;;
    esac

    if [ "$SWAP_SIZE_MB" -gt "$MAX_SWAP" ]; then
        print_error "大小（${SWAP_SIZE_MB}MB）超出可用空间！"
        return 1
    fi

    print_info "将创建 ${SWAP_SIZE_MB} MB 的 Swap"
    return 0
}

# ---------- 选择 swappiness ----------
choose_swappiness() {
    print_title "⑥ 设置 swappiness"

    printf "  数值越低 = 越少使用swap = 减少磨损\n"
    printf "\n"
    printf "    [1]  5  — 极少使用（闪存/eMMC 推荐）\n"
    printf "    [2] 10  — 通用推荐 ✅\n"
    printf "    [3] 30  — 适中\n"
    printf "    [4] 60  — 系统默认\n"
    printf "\n"

    case "$CHOSEN_DEV" in
        /dev/mmcblk*|/dev/mtd*)
            printf "  ${YELLOW}eMMC/闪存设备，建议 [1] 或 [2]${PLAIN}\n" ;;
        /dev/nvme*)
            printf "  ${GREEN}NVMe SSD，选 [2] 或 [3] 即可${PLAIN}\n" ;;
        *ZFS*|*zfs*)
            printf "  ${GREEN}ZFS 存储，选 [2] 或 [3] 即可${PLAIN}\n" ;;
        /dev/sd*)
            printf "  ${GREEN}SATA/USB 设备，选 [2] 或 [3] 即可${PLAIN}\n" ;;
        *)
            printf "  ${GREEN}通用建议：选 [2]${PLAIN}\n" ;;
    esac

    printf "\n"
    printf "  请选择 [1-4]（回车默认 10）: "
    read sw_choice

    case "$sw_choice" in
        1) SWAPPINESS=5 ;;
        2) SWAPPINESS=10 ;;
        3) SWAPPINESS=30 ;;
        4) SWAPPINESS=60 ;;
        "") SWAPPINESS=10 ;;
        *) print_error "无效！"; return 1 ;;
    esac

    print_info "swappiness = ${SWAPPINESS}"
    return 0
}

# ---------- 应用 swappiness ----------
apply_swappiness() {
    printf "%s" "$SWAPPINESS" > /proc/sys/vm/swappiness 2>/dev/null

    if [ -f /etc/sysctl.conf ]; then
        sed -i '/^vm.swappiness/d' /etc/sysctl.conf
    fi
    printf "vm.swappiness=%s\n" "$SWAPPINESS" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
}

# ---------- 配置开机自启 ----------
setup_autostart() {
    if [ "$SYSTEM_TYPE" = "openwrt" ]; then
        while uci -q get fstab.@swap[0] >/dev/null 2>&1; do
            uci delete fstab.@swap[0] 2>/dev/null
        done
        uci add fstab swap >/dev/null
        uci set fstab.@swap[-1].device="$SWAP_FILE"
        uci set fstab.@swap[-1].enabled='1'
        uci commit fstab
        /etc/init.d/fstab enable 2>/dev/null
    else
        if [ -f /etc/fstab ]; then
            sed -i "\|${SWAP_FILE}|d" /etc/fstab
        fi
        printf "%s none swap sw 0 0\n" "$SWAP_FILE" >> /etc/fstab
    fi
}

# ============================================================
#  创建 Swap - btrfs 专用
# ============================================================
create_btrfs_swap() {
    print_title "正在创建 btrfs Swap 文件（专用模式）"

    if [ "$CHOSEN_MOUNT" = "/" ]; then
        SWAP_FILE="/swapfile"
    else
        SWAP_FILE="${CHOSEN_MOUNT}/swapfile"
    fi

    if [ -f "$SWAP_FILE" ]; then
        print_warn "文件 ${SWAP_FILE} 已存在"
        printf "\n"
        printf "  [1] 尝试启用已有文件\n"
        printf "  [2] 删除后重新创建\n"
        printf "  [3] 取消\n"
        printf "  请选择 [1-3]: "
        read file_choice

        case "$file_choice" in
            1)
                printf "  启用 %s... " "$SWAP_FILE"
                if swapon "$SWAP_FILE" 2>/dev/null; then
                    printf "${GREEN}成功${PLAIN}\n"
                else
                    printf "${RED}失败（可能需要重新创建）${PLAIN}\n"
                fi
                return 0
                ;;
            2)
                swapoff "$SWAP_FILE" 2>/dev/null
                rm -f "$SWAP_FILE"
                print_info "已删除旧文件"
                ;;
            3) printf "  取消。\n"; return 0 ;;
            *) printf "  无效选择。\n"; return 0 ;;
        esac
    fi

    BTRFS_VER=$(btrfs --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
    KERNEL_MAJOR=$(uname -r | cut -d. -f1)
    KERNEL_MINOR=$(uname -r | cut -d. -f2)

    printf "  btrfs-progs: %s  内核: %s.%s\n" "${BTRFS_VER:-未知}" "$KERNEL_MAJOR" "$KERNEL_MINOR"
    printf "\n"

    if command -v btrfs >/dev/null 2>&1 && btrfs filesystem mkswapfile --help >/dev/null 2>&1; then
        printf "  ${GREEN}检测到 btrfs mkswapfile 命令，使用原生方式${PLAIN}\n\n"

        printf "  [1/4] 创建 btrfs swapfile (%sMB)... " "$SWAP_SIZE_MB"
        btrfs filesystem mkswapfile --size ${SWAP_SIZE_MB}M "$SWAP_FILE" >/dev/null 2>&1
        if [ $? -ne 0 ]; then
            printf "${RED}失败${PLAIN}\n"
            print_error "btrfs mkswapfile 失败"
            rm -f "$SWAP_FILE" 2>/dev/null
            return 1
        fi
        printf "${GREEN}完成${PLAIN}\n"

    else
        printf "  ${YELLOW}使用手动方式创建 btrfs swapfile${PLAIN}\n\n"

        printf "  [1/5] 创建空文件... "
        truncate -s 0 "$SWAP_FILE"
        if [ $? -ne 0 ]; then
            printf "${RED}失败${PLAIN}\n"
            return 1
        fi
        printf "${GREEN}完成${PLAIN}\n"

        printf "  [2/5] 禁用 COW (chattr +C)... "
        chattr +C "$SWAP_FILE" 2>/dev/null
        if [ $? -ne 0 ]; then
            printf "${YELLOW}跳过（可能已禁用）${PLAIN}\n"
        else
            printf "${GREEN}完成${PLAIN}\n"
        fi

        printf "  [3/5] 禁用压缩... "
        btrfs property set "$SWAP_FILE" compression none 2>/dev/null
        printf "${GREEN}完成${PLAIN}\n"

        printf "  [4/5] 用 dd 填充 %sMB... " "$SWAP_SIZE_MB"
        dd if=/dev/zero of="$SWAP_FILE" bs=1M count=$SWAP_SIZE_MB status=none 2>/dev/null
        if [ $? -ne 0 ]; then
            printf "${RED}失败${PLAIN}\n"
            rm -f "$SWAP_FILE"
            return 1
        fi
        printf "${GREEN}完成${PLAIN}\n"

        printf "  [5/5] 设置权限... "
        chmod 600 "$SWAP_FILE"
        printf "${GREEN}完成${PLAIN}\n"
    fi

    printf "  格式化为 swap... "
    mkswap "$SWAP_FILE" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        printf "${RED}失败${PLAIN}\n"
        rm -f "$SWAP_FILE"
        return 1
    fi
    printf "${GREEN}完成${PLAIN}\n"

    printf "  启用 swap... "
    swapon "$SWAP_FILE" 2>&1
    if [ $? -ne 0 ]; then
        printf "${RED}失败${PLAIN}\n"
        print_error "swapon 失败！可能的原因："
        printf "    1. 内核版本 < 5.0（不支持 btrfs swapfile）\n"
        printf "    2. swapfile 跨越多个 btrfs chunk\n"
        printf "    3. swapfile 在 btrfs RAID/多设备卷上\n"
        printf "    4. swapfile 所在子卷有快照\n"
        printf "\n"
        printf "  你的内核: %s\n" "$(uname -r)"
        printf "\n"

        if [ "$KERNEL_MAJOR" -lt 5 ]; then
            print_error "内核版本 < 5.0，不支持 btrfs swapfile"
            printf "  建议：升级内核或使用 swap 分区\n"
        fi

        MOUNT_SUBVOL=$(mount | grep " / " | grep -o 'subvol=[^ ,]*' | head -1)
        if [ -n "$MOUNT_SUBVOL" ]; then
            printf "  当前子卷: %s\n" "$MOUNT_SUBVOL"
            printf "  如有快照，swapfile 不可用\n"
        fi

        rm -f "$SWAP_FILE"
        return 1
    fi
    printf "${GREEN}完成${PLAIN}\n"

    printf "  设置 swappiness=%s... " "$SWAPPINESS"
    apply_swappiness
    printf "${GREEN}完成${PLAIN}\n"

    printf "  配置开机自启... "
    setup_autostart
    printf "${GREEN}完成${PLAIN}\n"

    print_info "btrfs Swap 创建完成 (${SWAP_SIZE_MB}MB @ ${SWAP_FILE})"
    return 0
}

# ============================================================
#  创建 Swap - ZFS zvol
# ============================================================
create_zfs_swap() {
    print_title "正在创建 ZFS Swap (zvol)"

    local swap_size_display="${SWAP_SIZE_MB}M"
    if [ "$SWAP_SIZE_MB" -ge 1024 ]; then
        swap_size_display="$((SWAP_SIZE_MB / 1024))G"
    fi

    if zfs list "$ZFS_DATASET" >/dev/null 2>&1; then
        print_warn "ZFS 数据集 '${ZFS_DATASET}' 已存在"

        if grep -q "$ZFS_ZVOL" /proc/swaps 2>/dev/null; then
            print_info "且已作为 swap 启用"
            return 0
        fi

        printf "\n"
        printf "  [1] 尝试激活已有的 zvol\n"
        printf "  [2] 删除后重新创建\n"
        printf "  [3] 取消\n"
        printf "  请选择 [1-3]: "
        read zfs_choice

        case "$zfs_choice" in
            1)
                printf "  激活 %s... " "$ZFS_ZVOL"
                if swapon "$ZFS_ZVOL" 2>/dev/null; then
                    printf "${GREEN}成功${PLAIN}\n"
                else
                    printf "${RED}失败${PLAIN}\n"
                fi
                return 0
                ;;
            2)
                delete_zfs_swap_internal
                if [ $? -ne 0 ]; then return 1; fi
                ;;
            3) return 0 ;;
            *) return 0 ;;
        esac
    fi

    printf "  [1/4] 创建 ZFS zvol (%s)... " "$swap_size_display"
    zfs create -V ${swap_size_display} -b 8k "$ZFS_DATASET" 2>/dev/null
    if [ $? -ne 0 ]; then
        printf "${RED}失败${PLAIN}\n"
        return 1
    fi
    printf "${GREEN}完成${PLAIN}\n"

    sleep 2

    printf "  [2/4] 格式化 swap... "
    mkswap "$ZFS_ZVOL" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        printf "${RED}失败${PLAIN}\n"
        zfs destroy "$ZFS_DATASET" 2>/dev/null
        return 1
    fi
    printf "${GREEN}完成${PLAIN}\n"

    printf "  [3/4] 启用 swap... "
    swapon "$ZFS_ZVOL"
    if [ $? -ne 0 ]; then
        printf "${RED}失败${PLAIN}\n"
        return 1
    fi
    printf "${GREEN}完成${PLAIN}\n"

    printf "  [4/4] 写入 /etc/fstab... "
    if ! grep -q "$ZFS_ZVOL" /etc/fstab 2>/dev/null; then
        printf "%s none swap sw 0 0\n" "$ZFS_ZVOL" >> /etc/fstab
    fi
    printf "${GREEN}完成${PLAIN}\n"

    SWAP_FILE="$ZFS_ZVOL"
    apply_swappiness
    print_info "ZFS Swap 创建完成 (${swap_size_display})"
}

delete_zfs_swap_internal() {
    if grep -q "$ZFS_ZVOL" /proc/swaps 2>/dev/null; then
        swapoff "$ZFS_ZVOL" 2>/dev/null
    fi

    local retry=3
    while [ $retry -gt 0 ]; do
        zfs destroy "$ZFS_DATASET" 2>/dev/null
        if [ $? -eq 0 ]; then
            print_info "ZFS 数据集 ${ZFS_DATASET} 已删除"
            [ -f /etc/fstab ] && sed -i "\|${ZFS_ZVOL}|d" /etc/fstab
            return 0
        fi
        retry=$((retry - 1))
        [ $retry -gt 0 ] && sleep 2
    done
    print_error "删除 ZFS 数据集失败"
    return 1
}

# ============================================================
#  创建 Swap - 普通文件（ext4/xfs 等）
# ============================================================
create_file_swap() {
    print_title "正在创建 Swap 文件"

    if [ "$CHOSEN_MOUNT" = "/" ]; then
        SWAP_FILE="/swapfile"
    else
        SWAP_FILE="${CHOSEN_MOUNT}/swapfile"
    fi

    if [ -f "$SWAP_FILE" ]; then
        print_warn "文件 ${SWAP_FILE} 已存在"
        printf "\n"
        printf "  [1] 尝试启用已有文件\n"
        printf "  [2] 删除后重新创建\n"
        printf "  [3] 取消\n"
        printf "  请选择 [1-3]: "
        read file_choice

        case "$file_choice" in
            1)
                printf "  启用 %s... " "$SWAP_FILE"
                if swapon "$SWAP_FILE" 2>/dev/null; then
                    printf "${GREEN}成功${PLAIN}\n"
                else
                    printf "${RED}失败${PLAIN}\n"
                fi
                return 0
                ;;
            2)
                swapoff "$SWAP_FILE" 2>/dev/null
                rm -f "$SWAP_FILE"
                print_info "已删除旧文件"
                ;;
            3) return 0 ;;
            *) return 0 ;;
        esac
    fi

    printf "  [1/6] 创建 %sMB 文件... " "$SWAP_SIZE_MB"
    if command -v fallocate >/dev/null 2>&1; then
        fallocate -l ${SWAP_SIZE_MB}M "$SWAP_FILE" 2>/dev/null
        if [ $? -ne 0 ]; then
            dd if=/dev/zero of="$SWAP_FILE" bs=1M count=$SWAP_SIZE_MB status=none 2>/dev/null
        fi
    else
        dd if=/dev/zero of="$SWAP_FILE" bs=1M count=$SWAP_SIZE_MB status=none 2>/dev/null
    fi
    if [ $? -ne 0 ]; then
        printf "${RED}失败${PLAIN}\n"
        return 1
    fi
    printf "${GREEN}完成${PLAIN}\n"

    printf "  [2/6] 设置权限 600... "
    chmod 600 "$SWAP_FILE"
    printf "${GREEN}完成${PLAIN}\n"

    printf "  [3/6] 格式化为 swap... "
    mkswap "$SWAP_FILE" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        printf "${RED}失败${PLAIN}\n"
        rm -f "$SWAP_FILE"
        return 1
    fi
    printf "${GREEN}完成${PLAIN}\n"

    printf "  [4/6] 启用 swap... "
    swapon "$SWAP_FILE" 2>&1
    if [ $? -ne 0 ]; then
        printf "${RED}失败${PLAIN}\n"
        print_error "swapon 失败！正在清理..."
        rm -f "$SWAP_FILE"
        return 1
    fi
    printf "${GREEN}完成${PLAIN}\n"

    printf "  [5/6] 设置 swappiness=%s... " "$SWAPPINESS"
    apply_swappiness
    printf "${GREEN}完成${PLAIN}\n"

    printf "  [6/6] 配置开机自启... "
    setup_autostart
    printf "${GREEN}完成${PLAIN}\n"

    print_info "Swap 文件创建完成 (${SWAP_SIZE_MB}MB @ ${SWAP_FILE})"
}

# ============================================================
#  卸载 Swap
# ============================================================
disable_all_swap() {
    print_title "卸载 Swap"

    EXISTING=$(awk 'NR>1' /proc/swaps)
    if [ -z "$EXISTING" ]; then
        print_warn "当前没有启用任何 Swap"
        return 0
    fi

    printf "  当前 Swap：\n\n"
    awk 'NR>1 {print $1}' /proc/swaps | while read sp; do
        type_desc=$(get_swap_type_desc "$sp")
        sp_size=$(awk -v p="$sp" '$1==p {print int($3/1024)}' /proc/swaps)
        printf "    %s  (%s MB)\n" "$sp" "$sp_size"
        printf "    类型: %s\n\n" "$type_desc"
    done

    has_zram_in_swap=$(awk 'NR>1 && /zram/ {print $1}' /proc/swaps)
    if [ -n "$has_zram_in_swap" ]; then
        print_warn "包含 zram swap，卸载后不会释放磁盘空间（这是正常的）"
        if [ -n "$ZRAM_SERVICE" ]; then
            print_warn "zram 由 ${ZRAM_SERVICE} 管理，重启后可能自动恢复"
        fi
    fi

    if confirm_yes_no "确认卸载所有 Swap？"; then
        sync
        swapoff -a 2>/dev/null
        if [ $? -eq 0 ]; then
            print_info "所有 Swap 已卸载"
        else
            print_error "卸载失败，尝试逐个关闭..."
            awk 'NR>1 {print $1}' /proc/swaps | while read sp; do
                swapoff "$sp" 2>/dev/null
                if [ $? -eq 0 ]; then
                    print_info "已卸载 $sp"
                else
                    print_error "卸载失败: $sp"
                fi
            done
        fi
    fi
}

# ============================================================
#  彻底删除 Swap
# ============================================================
delete_swap() {
    print_title "彻底删除 Swap"

    collect_all_swap_paths

    if [ -z "$ALL_SWAP_PATHS" ]; then
        print_warn "没有找到任何 Swap 或残留文件"
        return 0
    fi

    printf "\n"
    printf "  ${YELLOW}发现以下 Swap 相关内容：${PLAIN}\n\n"

    has_zram=0
    has_file=0
    has_zvol=0

    for sp in $ALL_SWAP_PATHS; do
        type_desc=$(get_swap_type_desc "$sp")

        case "$sp" in
            /dev/zram*) has_zram=1 ;;
            /dev/zvol/*) has_zvol=1 ;;
            *) [ -f "$sp" ] && has_file=1 ;;
        esac

        if grep -q "$sp" /proc/swaps 2>/dev/null; then
            sp_status="${GREEN}使用中${PLAIN}"
            sp_size=$(awk -v p="$sp" '$1==p {print int($3/1024)" MB"}' /proc/swaps)
        else
            sp_status="${YELLOW}未激活${PLAIN}"
            if [ -f "$sp" ]; then
                sp_size=$(ls -lh "$sp" 2>/dev/null | awk '{print $5}')
            else
                sp_size="N/A"
            fi
        fi

        printf "    ● %s\n" "$sp"
        printf "      类型: %-30s 大小: %-10s 状态: %b\n" "$type_desc" "$sp_size" "$sp_status"
        printf "\n"
    done

    if [ "$has_zram" = "1" ]; then
        print_line
        printf "  ${YELLOW}⚠ 关于 zram swap：${PLAIN}\n"
        printf "    • zram 是内存压缩设备，${RED}不占用磁盘空间${PLAIN}\n"
        printf "    • 删除后 df -h 不会增加，这是正常现象\n"
        if [ -n "$ZRAM_SERVICE" ]; then
            printf "    • zram 由 ${CYAN}%s${PLAIN} 服务管理\n" "$ZRAM_SERVICE"
            printf "    • 仅 swapoff 重启后会恢复，需禁用服务才能永久关闭\n"
        fi
        print_line
        printf "\n"
    fi

    printf "  ${YELLOW}删除前磁盘空间：${PLAIN}\n"
    df -h | grep -vE 'tmpfs|devtmpfs|proc|sysfs|cgroup|debugfs|bpffs|devpts|overlay' | head -10
    printf "\n"

    if ! confirm_type_yes "警告：将删除以上所有 Swap 及配置，此操作不可恢复！"; then
        printf "  已取消。\n"
        return 0
    fi

    printf "\n"

    printf "  [1/6] 关闭所有 swap... "
    sync
    swapoff -a 2>/dev/null
    for sp in $ALL_SWAP_PATHS; do
        swapoff "$sp" 2>/dev/null
    done
    printf "${GREEN}完成${PLAIN}\n"

    printf "  [2/6] 删除 swap 文件... "
    file_del=0
    for sp in $ALL_SWAP_PATHS; do
        if [ -f "$sp" ]; then
            rm -f "$sp"
            if [ $? -eq 0 ]; then
                file_del=$((file_del + 1))
                printf "\n"
                print_info "已删除: $sp"
                printf "         "
            fi
        fi
    done
    if [ "$file_del" -eq 0 ]; then
        printf "无文件需删除\n"
    else
        printf "\n"
    fi

    # 清理临时 swap 标记
    if [ -f "$TEMP_SWAP_MARKER" ]; then
        rm -f "$TEMP_SWAP_MARKER"
    fi

    printf "  [3/6] 检查 ZFS zvol... "
    if [ "$HAS_ZFS" = "yes" ] && zfs list "$ZFS_DATASET" >/dev/null 2>&1; then
        printf "\n"
        delete_zfs_swap_internal
    else
        printf "无\n"
    fi

    printf "  [4/6] 处理 zram 服务... "
    if [ "$has_zram" = "1" ] && [ -n "$ZRAM_SERVICE" ]; then
        printf "\n"
        printf "\n"
        printf "  ${YELLOW}检测到 zram 由 %s 管理${PLAIN}\n" "$ZRAM_SERVICE"
        printf "  如果仅 swapoff，重启后 zram swap 会自动恢复\n"
        printf "\n"
        printf "  [1] 禁用 %s 服务（永久关闭 zram swap）\n" "$ZRAM_SERVICE"
        printf "  [2] 仅本次关闭（重启后恢复）\n"
        printf "  请选择 [1-2]: "
        read zram_choice

        case "$zram_choice" in
            1)
                printf "  正在禁用 %s... " "$ZRAM_SERVICE"
                systemctl stop "$ZRAM_SERVICE" 2>/dev/null
                systemctl disable "$ZRAM_SERVICE" 2>/dev/null

                if [ "$ZRAM_SERVICE" = "armbian-zram-config" ]; then
                    if [ -f /etc/default/armbian-zram-config ]; then
                        sed -i 's/^ENABLED=.*/ENABLED=false/' /etc/default/armbian-zram-config 2>/dev/null
                        if ! grep -q "^ENABLED=" /etc/default/armbian-zram-config; then
                            printf "ENABLED=false\n" >> /etc/default/armbian-zram-config
                        fi
                    fi
                fi

                if [ "$ZRAM_SERVICE" = "zramswap" ]; then
                    if [ -f /etc/default/zramswap ]; then
                        sed -i 's/^ENABLED=.*/ENABLED=0/' /etc/default/zramswap 2>/dev/null
                    fi
                fi

                printf "${GREEN}完成${PLAIN}\n"
                print_info "zram 服务已禁用，重启后不会自动创建 zram swap"

                other_zram=$(zramctl 2>/dev/null | grep -v "SWAP" | tail -n +2)
                if [ -n "$other_zram" ]; then
                    printf "\n"
                    print_warn "注意：以下 zram 设备不是 swap，不受影响："
                    zramctl 2>/dev/null | grep -v "SWAP"
                fi
                ;;
            2)
                printf "  仅本次关闭\n"
                print_warn "重启后 zram swap 将自动恢复"
                ;;
        esac
    else
        printf "无 zram 服务\n"
    fi

    printf "  [5/6] 清理启动配置... "
    config_cleaned=0

    if [ "$SYSTEM_TYPE" = "openwrt" ] && command -v uci >/dev/null 2>&1; then
        while uci -q get fstab.@swap[0] >/dev/null 2>&1; do
            uci delete fstab.@swap[0] 2>/dev/null
            config_cleaned=1
        done
        [ "$config_cleaned" = "1" ] && uci commit fstab 2>/dev/null
    fi

    if [ -f /etc/fstab ]; then
        fstab_before=$(wc -l < /etc/fstab)
        for sp in $ALL_SWAP_PATHS; do
            case "$sp" in
                /dev/zram*) continue ;;
            esac
            escaped_sp=$(printf "%s" "$sp" | sed 's/[\/&]/\\&/g')
            sed -i "/${escaped_sp}/d" /etc/fstab 2>/dev/null
        done
        sed -i '/^[^#].*[[:space:]]swap[[:space:]]/d' /etc/fstab 2>/dev/null
        fstab_after=$(wc -l < /etc/fstab)
        [ "$fstab_before" != "$fstab_after" ] && config_cleaned=1
    fi

    # 清理临时 swap 自启服务
    if [ -f /etc/systemd/system/swap-temp-cleanup.service ]; then
        systemctl disable swap-temp-cleanup.service >/dev/null 2>&1
        rm -f /etc/systemd/system/swap-temp-cleanup.service
        systemctl daemon-reload >/dev/null 2>&1
        config_cleaned=1
    fi
    if [ -f /etc/rc.local ]; then
        sed -i '/# swap-temp-cleanup-start/,/# swap-temp-cleanup-end/d' /etc/rc.local 2>/dev/null
    fi

    if [ "$config_cleaned" = "1" ]; then
        printf "${GREEN}完成${PLAIN}\n"
    else
        printf "无需清理\n"
    fi

    printf "  [6/6] 清理 swappiness 配置... "
    if [ -f /etc/sysctl.conf ] && grep -q '^vm.swappiness' /etc/sysctl.conf; then
        sed -i '/^vm.swappiness/d' /etc/sysctl.conf
        printf "${GREEN}完成${PLAIN}\n"
    else
        printf "无需清理\n"
    fi

    printf "\n"
    print_line
    printf "  ${CYAN}删除结果验证${PLAIN}\n"
    print_line
    printf "\n"

    remaining=$(awk 'NR>1' /proc/swaps)
    if [ -z "$remaining" ]; then
        print_info "Swap 已完全关闭"
    else
        print_warn "仍有 Swap 存在："
        cat /proc/swaps
    fi

    for sp in $ALL_SWAP_PATHS; do
        case "$sp" in /dev/zram*|/dev/zvol/*|/dev/sd*|/dev/mmcblk*) continue ;; esac
        if [ -f "$sp" ]; then
            print_error "文件仍存在: $sp"
        fi
    done

    printf "\n"
    printf "  ${YELLOW}删除后磁盘空间：${PLAIN}\n"
    df -h | grep -vE 'tmpfs|devtmpfs|proc|sysfs|cgroup|debugfs|bpffs|devpts|overlay' | head -10

    printf "\n"
    free -h 2>/dev/null || free

    printf "\n"
    print_info "Swap 清理完成"
}

# ============================================================
#  临时 Swap - 普通文件（ext4/xfs 等）
# ============================================================
create_temp_file_swap() {
    printf "\n"

    printf "  [1/4] 创建 %sMB 临时文件... " "$SWAP_SIZE_MB"
    if command -v fallocate >/dev/null 2>&1; then
        fallocate -l ${SWAP_SIZE_MB}M "$TEMP_SWAP_FILE" 2>/dev/null
        if [ $? -ne 0 ]; then
            dd if=/dev/zero of="$TEMP_SWAP_FILE" bs=1M count=$SWAP_SIZE_MB status=none 2>/dev/null
        fi
    else
        dd if=/dev/zero of="$TEMP_SWAP_FILE" bs=1M count=$SWAP_SIZE_MB status=none 2>/dev/null
    fi
    if [ $? -ne 0 ]; then
        printf "${RED}失败${PLAIN}\n"
        return 1
    fi
    printf "${GREEN}完成${PLAIN}\n"

    printf "  [2/4] 设置权限... "
    chmod 600 "$TEMP_SWAP_FILE"
    printf "${GREEN}完成${PLAIN}\n"

    printf "  [3/4] 格式化... "
    mkswap "$TEMP_SWAP_FILE" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        printf "${RED}失败${PLAIN}\n"
        rm -f "$TEMP_SWAP_FILE"
        return 1
    fi
    printf "${GREEN}完成${PLAIN}\n"

    printf "  [4/4] 启用... "
    swapon "$TEMP_SWAP_FILE" 2>&1
    if [ $? -ne 0 ]; then
        printf "${RED}失败${PLAIN}\n"
        rm -f "$TEMP_SWAP_FILE"
        return 1
    fi
    printf "${GREEN}完成${PLAIN}\n"
    return 0
}

# ============================================================
#  临时 Swap - btrfs 专用
# ============================================================
create_temp_btrfs_swap() {
    printf "\n"

    if command -v btrfs >/dev/null 2>&1 && btrfs filesystem mkswapfile --help >/dev/null 2>&1; then
        printf "  ${GREEN}检测到 btrfs mkswapfile，使用原生方式${PLAIN}\n\n"

        printf "  [1/2] 创建 btrfs swapfile (%sMB)... " "$SWAP_SIZE_MB"
        btrfs filesystem mkswapfile --size ${SWAP_SIZE_MB}M "$TEMP_SWAP_FILE" >/dev/null 2>&1
        if [ $? -ne 0 ]; then
            printf "${RED}失败${PLAIN}\n"
            rm -f "$TEMP_SWAP_FILE" 2>/dev/null
            return 1
        fi
        printf "${GREEN}完成${PLAIN}\n"

        printf "  [2/2] 启用... "
        swapon "$TEMP_SWAP_FILE" 2>&1
        if [ $? -ne 0 ]; then
            printf "${RED}失败${PLAIN}\n"
            rm -f "$TEMP_SWAP_FILE"
            return 1
        fi
        printf "${GREEN}完成${PLAIN}\n"

    else
        printf "  ${YELLOW}使用手动方式创建 btrfs swapfile${PLAIN}\n\n"

        printf "  [1/6] 创建空文件... "
        truncate -s 0 "$TEMP_SWAP_FILE"
        if [ $? -ne 0 ]; then
            printf "${RED}失败${PLAIN}\n"
            return 1
        fi
        printf "${GREEN}完成${PLAIN}\n"

        printf "  [2/6] 禁用 COW (chattr +C)... "
        chattr +C "$TEMP_SWAP_FILE" 2>/dev/null
        if [ $? -ne 0 ]; then
            printf "${YELLOW}跳过${PLAIN}\n"
        else
            printf "${GREEN}完成${PLAIN}\n"
        fi

        printf "  [3/6] 禁用压缩... "
        btrfs property set "$TEMP_SWAP_FILE" compression none 2>/dev/null
        printf "${GREEN}完成${PLAIN}\n"

        printf "  [4/6] 用 dd 填充 %sMB... " "$SWAP_SIZE_MB"
        dd if=/dev/zero of="$TEMP_SWAP_FILE" bs=1M count=$SWAP_SIZE_MB status=none 2>/dev/null
        if [ $? -ne 0 ]; then
            printf "${RED}失败${PLAIN}\n"
            rm -f "$TEMP_SWAP_FILE"
            return 1
        fi
        printf "${GREEN}完成${PLAIN}\n"

        printf "  [5/6] 格式化... "
        chmod 600 "$TEMP_SWAP_FILE"
        mkswap "$TEMP_SWAP_FILE" >/dev/null 2>&1
        if [ $? -ne 0 ]; then
            printf "${RED}失败${PLAIN}\n"
            rm -f "$TEMP_SWAP_FILE"
            return 1
        fi
        printf "${GREEN}完成${PLAIN}\n"

        printf "  [6/6] 启用... "
        swapon "$TEMP_SWAP_FILE" 2>&1
        if [ $? -ne 0 ]; then
            printf "${RED}失败${PLAIN}\n"
            print_error "swapon 失败！可能原因：内核<5.0 / 子卷有快照 / RAID"
            rm -f "$TEMP_SWAP_FILE"
            return 1
        fi
        printf "${GREEN}完成${PLAIN}\n"
    fi
    return 0
}

# ============================================================
#  注册重启后自动清理临时 swap
# ============================================================
setup_temp_swap_cleanup() {
    if [ "$SYSTEM_TYPE" = "openwrt" ]; then
        if [ -f /etc/rc.local ]; then
            sed -i '/# swap-temp-cleanup-start/,/# swap-temp-cleanup-end/d' /etc/rc.local
            sed -i "/^exit 0/i\\
# swap-temp-cleanup-start\\
if [ -f \"${TEMP_SWAP_MARKER}\" ]; then\\
    _tf=\$(cat \"${TEMP_SWAP_MARKER}\")\\
    [ -n \"\$_tf\" ] && { swapoff \"\$_tf\" 2>/dev/null; rm -f \"\$_tf\"; }\\
    rm -f \"${TEMP_SWAP_MARKER}\"\\
fi\\
# swap-temp-cleanup-end" /etc/rc.local
        fi
    else
        cat > /etc/systemd/system/swap-temp-cleanup.service << UNIT_EOF
[Unit]
Description=Clean up temporary swap file on boot
DefaultDependencies=no
After=local-fs.target
Before=swap.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c '[ -f "${TEMP_SWAP_MARKER}" ] && { _tf=\$(cat "${TEMP_SWAP_MARKER}"); [ -n "\$_tf" ] && [ -f "\$_tf" ] && { swapoff "\$_tf" 2>/dev/null; rm -f "\$_tf"; }; rm -f "${TEMP_SWAP_MARKER}"; } || true'
RemainAfterExit=no

[Install]
WantedBy=sysinit.target
UNIT_EOF
        systemctl daemon-reload 2>/dev/null
        systemctl enable swap-temp-cleanup.service >/dev/null 2>&1
    fi
}

# ============================================================
#  手动移除临时 swap
# ============================================================
remove_temp_swap() {
    print_title "移除临时 Swap"

    if [ ! -f "$TEMP_SWAP_MARKER" ]; then
        print_warn "当前没有活跃的临时 Swap（标记文件不存在）"
        # 兜底：检查是否有残留 .temp 文件
        for sf in /swapfile.temp /mnt/*/swapfile.temp /opt/swapfile.temp; do
            if [ -f "$sf" ]; then
                print_warn "发现残留文件: $sf"
                if confirm_yes_no "是否清理此残留文件？"; then
                    swapoff "$sf" 2>/dev/null
                    rm -f "$sf"
                    print_info "已清理: $sf"
                fi
            fi
        done
        return 0
    fi

    EXISTING_TEMP=$(cat "$TEMP_SWAP_MARKER" 2>/dev/null)
    if [ -z "$EXISTING_TEMP" ]; then
        rm -f "$TEMP_SWAP_MARKER"
        print_warn "标记文件异常，已清理"
        return 0
    fi

    printf "\n"
    if grep -q "$EXISTING_TEMP" /proc/swaps 2>/dev/null; then
        temp_size=$(awk -v p="$EXISTING_TEMP" '$1==p {print int($3/1024)}' /proc/swaps)
        printf "  临时 Swap：${GREEN}%s${PLAIN}  大小: ${GREEN}%s MB${PLAIN}  状态: ${GREEN}使用中${PLAIN}\n" \
            "$EXISTING_TEMP" "$temp_size"
    else
        printf "  临时 Swap：${YELLOW}%s${PLAIN}  状态: ${YELLOW}已停用（文件可能残留）${PLAIN}\n" \
            "$EXISTING_TEMP"
    fi

    printf "\n"
    if confirm_yes_no "确认立即移除临时 Swap？"; then
        printf "\n"
        printf "  [1/4] 关闭 swap... "
        swapoff "$EXISTING_TEMP" 2>/dev/null
        printf "${GREEN}完成${PLAIN}\n"

        printf "  [2/4] 删除文件... "
        rm -f "$EXISTING_TEMP"
        if [ $? -eq 0 ]; then
            printf "${GREEN}完成${PLAIN}\n"
        else
            printf "${YELLOW}文件不存在或已删除${PLAIN}\n"
        fi

        printf "  [3/4] 清理标记... "
        rm -f "$TEMP_SWAP_MARKER"
        printf "${GREEN}完成${PLAIN}\n"

        printf "  [4/4] 清理自启服务... "
        if [ -f /etc/systemd/system/swap-temp-cleanup.service ]; then
            systemctl disable swap-temp-cleanup.service >/dev/null 2>&1
            rm -f /etc/systemd/system/swap-temp-cleanup.service
            systemctl daemon-reload >/dev/null 2>&1
            printf "${GREEN}完成${PLAIN}\n"
        elif [ -f /etc/rc.local ]; then
            sed -i '/# swap-temp-cleanup-start/,/# swap-temp-cleanup-end/d' /etc/rc.local 2>/dev/null
            printf "${GREEN}完成${PLAIN}\n"
        else
            printf "无需清理\n"
        fi

        printf "\n"
        print_info "临时 Swap 已完全移除"
        printf "\n"
        printf "  当前内存状态：\n"
        free -h 2>/dev/null || free
        printf "\n"
        printf "  当前 Swap 状态：\n"
        cat /proc/swaps
    else
        printf "  已取消。\n"
    fi
}

# ============================================================
#  临时 Swap 主流程
# ============================================================
create_temp_swap_flow() {
    print_title "创建临时 Swap（仅本次开机有效）"

    printf "  ${CYAN}功能说明：${PLAIN}\n"
    printf "    • 立即增加虚拟内存，应对当前内存不足\n"
    printf "    • ${YELLOW}不写入 fstab，重启后自动失效并清理文件${PLAIN}\n"
    printf "    • 适合临时编译、运行大程序等短期场景\n"
    printf "    • 与现有 zram / 永久 swap 共存叠加使用\n"
    printf "\n"

    # 显示当前内存状态
    printf "  当前内存状态：\n"
    free -h 2>/dev/null || free
    printf "\n"

    # 检查是否已有临时 swap
    if [ -f "$TEMP_SWAP_MARKER" ]; then
        EXISTING_TEMP=$(cat "$TEMP_SWAP_MARKER" 2>/dev/null)
        if [ -n "$EXISTING_TEMP" ] && grep -q "$EXISTING_TEMP" /proc/swaps 2>/dev/null; then
            existing_size=$(awk -v p="$EXISTING_TEMP" '$1==p {print int($3/1024)}' /proc/swaps)
            print_warn "已存在临时 Swap: ${EXISTING_TEMP} (${existing_size} MB)"
            printf "\n"
            printf "  [1] 替换（先删除旧的再创建）\n"
            printf "  [2] 取消\n"
            printf "  请选择 [1-2]: "
            read temp_exist_choice
            case "$temp_exist_choice" in
                1)
                    swapoff "$EXISTING_TEMP" 2>/dev/null
                    rm -f "$EXISTING_TEMP"
                    rm -f "$TEMP_SWAP_MARKER"
                    print_info "已删除旧临时 Swap"
                    ;;
                *)
                    printf "  已取消。\n"
                    return 0
                    ;;
            esac
        else
            [ -n "$EXISTING_TEMP" ] && [ -f "$EXISTING_TEMP" ] && rm -f "$EXISTING_TEMP"
            rm -f "$TEMP_SWAP_MARKER"
        fi
    fi

    scan_storage || return
    choose_storage || return
    choose_size || return

    # 确定临时文件路径
    if [ "$CHOSEN_MOUNT" = "/" ]; then
        TEMP_SWAP_FILE="/swapfile.temp"
    else
        TEMP_SWAP_FILE="${CHOSEN_MOUNT}/swapfile.temp"
    fi

    # 清理同路径残留
    if [ -f "$TEMP_SWAP_FILE" ]; then
        swapoff "$TEMP_SWAP_FILE" 2>/dev/null
        rm -f "$TEMP_SWAP_FILE"
    fi

    print_title "临时 Swap 配置确认"
    printf "  存储设备：    ${GREEN}%s (%s)${PLAIN}\n" "$CHOSEN_DEV" "$CHOSEN_TYPE"
    printf "  文件系统：    ${GREEN}%s${PLAIN}\n" "$CHOSEN_FSTYPE"
    printf "  Swap 大小：   ${GREEN}%s MB${PLAIN}\n" "$SWAP_SIZE_MB"
    printf "  临时文件：    ${GREEN}%s${PLAIN}\n" "$TEMP_SWAP_FILE"
    printf "  写入 fstab：  ${YELLOW}否（不持久化）${PLAIN}\n"
    printf "  重启行为：    ${YELLOW}自动清理文件，恢复重启前状态${PLAIN}\n"

    if ! confirm_yes_no "确认创建临时 Swap？"; then
        printf "  已取消。\n"
        return
    fi

    # 临时设置 swappiness（仅写 /proc，不持久化）
    printf "\n"
    printf "  临时设置 swappiness=60（不写入 sysctl.conf）... "
    printf "60" > /proc/sys/vm/swappiness 2>/dev/null
    printf "${GREEN}完成${PLAIN}\n"

    # 根据文件系统选择创建方式
    create_result=1
    case "$CHOSEN_FSTYPE" in
        zfs)
            print_error "ZFS 不支持临时 swap（zvol 本身是持久化对象）"
            printf "  请使用菜单 [1] 创建永久 Swap\n"
            return 1
            ;;
        btrfs)
            create_temp_btrfs_swap
            create_result=$?
            ;;
        *)
            create_temp_file_swap
            create_result=$?
            ;;
    esac

    if [ "$create_result" -eq 0 ]; then
        # 写入标记文件
        printf "%s" "$TEMP_SWAP_FILE" > "$TEMP_SWAP_MARKER"

        # 注册重启清理服务
        setup_temp_swap_cleanup

        printf "\n"
        print_line
        printf "  ${GREEN}✅ 临时 Swap 已创建并启用${PLAIN}\n"
        printf "  ${GREEN}   大小: %s MB  文件: %s${PLAIN}\n" "$SWAP_SIZE_MB" "$TEMP_SWAP_FILE"
        printf "  ${YELLOW}⏰ 重启后自动清理，无需手动操作${PLAIN}\n"
        printf "  ${CYAN}💡 如需提前移除，使用主菜单 [6]${PLAIN}\n"
        print_line
        printf "\n"

        printf "  当前内存状态：\n"
        free -h 2>/dev/null || free
        printf "\n"

        printf "  当前所有 Swap：\n"
        cat /proc/swaps
    else
        printf "\n"
        print_line
        printf "  ${RED}❌ 临时 Swap 创建失败，已自动清理${PLAIN}\n"
        print_line
        printf "\n"
        printf "  可能的解决方案：\n"
        case "$CHOSEN_FSTYPE" in
            btrfs)
                printf "    1. 确保内核版本 >= 5.0（当前: %s）\n" "$(uname -r)"
                printf "    2. 确保 swapfile 所在子卷没有快照\n"
                printf "    3. 可继续使用现有 zram swap\n"
                ;;
            *)
                printf "    1. 检查磁盘空间是否充足\n"
                printf "    2. 检查文件系统是否只读\n"
                printf "    3. 尝试较小的 swap 大小\n"
                ;;
        esac
    fi
}

# ============================================================
#  创建流程（永久）
# ============================================================
create_swap_flow() {
    scan_storage || return

    if [ "$HAS_ZRAM_SWAP" = "yes" ]; then
        printf "\n"
        print_warn "当前已有 zram swap（${ZRAM_SWAP_DEV}，${ZRAM_SWAP_SIZE}MB）"
        printf "  创建新的 swapfile 后，系统会同时使用 zram + swapfile\n"
        printf "  如果你想替换 zram，请先在主菜单选 [4] 删除\n"
        printf "\n"
    fi

    choose_storage || return
    choose_size || return
    choose_swappiness || return

    print_title "⑦ 配置确认"
    printf "  系统：        ${GREEN}%s${PLAIN}\n" "$SYS_DESC"
    printf "  架构：        ${GREEN}%s${PLAIN}\n" "$ARCH"
    printf "  物理内存：    ${GREEN}%s MB${PLAIN}\n" "$MEM_TOTAL_MB"
    printf "  存储设备：    ${GREEN}%s (%s)${PLAIN}\n" "$CHOSEN_DEV" "$CHOSEN_TYPE"
    printf "  文件系统：    ${GREEN}%s${PLAIN}\n" "$CHOSEN_FSTYPE"
    printf "  Swap 大小：   ${GREEN}%s MB${PLAIN}\n" "$SWAP_SIZE_MB"
    printf "  swappiness：  ${GREEN}%s${PLAIN}\n" "$SWAPPINESS"
    printf "  开机自启：    ${GREEN}是${PLAIN}\n"

    if [ "$CHOSEN_FSTYPE" = "btrfs" ]; then
        printf "  创建方式：    ${YELLOW}btrfs 专用（禁用COW+压缩）${PLAIN}\n"
    fi

    if ! confirm_yes_no "确认以上配置并开始创建？"; then
        printf "  已取消。\n"
        return
    fi

    create_result=1
    case "$CHOSEN_FSTYPE" in
        zfs)
            create_zfs_swap
            create_result=$?
            ;;
        btrfs)
            create_btrfs_swap
            create_result=$?
            ;;
        *)
            create_file_swap
            create_result=$?
            ;;
    esac

    if [ "$create_result" -eq 0 ]; then
        if grep -q "$SWAP_FILE" /proc/swaps 2>/dev/null; then
            printf "\n"
            show_swap_status
            print_line
            printf "  ${GREEN}✅ 设置完成，重启后 Swap 将自动加载${PLAIN}\n"
            print_line
        else
            printf "\n"
            print_error "Swap 文件已创建但未成功激活，请手动检查"
        fi
    else
        printf "\n"
        print_line
        printf "  ${RED}❌ Swap 创建失败，已自动清理${PLAIN}\n"
        print_line
        printf "\n"
        printf "  可能的解决方案：\n"
        case "$CHOSEN_FSTYPE" in
            btrfs)
                printf "    1. 确保内核版本 >= 5.0\n"
                printf "    2. 确保 swapfile 所在子卷没有快照\n"
                printf "    3. 尝试用 swap 分区代替 swapfile\n"
                printf "    4. 如果是 Armbian，可继续使用 zram swap\n"
                ;;
            *)
                printf "    1. 检查磁盘空间是否充足\n"
                printf "    2. 检查文件系统是否只读\n"
                printf "    3. 尝试较小的 swap 大小\n"
                ;;
        esac
    fi
}

# ============================================================
#  主菜单
# ============================================================
main_menu() {
    while true; do
        printf "\n"
        print_line
        printf "  ${CYAN}Swap 管理主菜单${PLAIN}\n"
        print_line
        printf "\n"
        printf "    [1] 创建并启用 Swap（永久，写入 fstab）\n"
        printf "    [2] 查看当前 Swap 状态\n"
        printf "    [3] 卸载 Swap（临时关闭，不删文件）\n"
        printf "    [4] 彻底删除 Swap（含文件和配置）\n"
        print_line
        printf "    [5] 创建临时 Swap ${YELLOW}（仅本次开机有效，重启自动清理）${PLAIN}\n"
        printf "    [6] 移除临时 Swap\n"
        print_line
        printf "    [0] 退出\n"
        printf "\n"

        # 若有活跃临时 swap，在菜单中提示
        if [ -f "$TEMP_SWAP_MARKER" ]; then
            _tf=$(cat "$TEMP_SWAP_MARKER" 2>/dev/null)
            if [ -n "$_tf" ] && grep -q "$_tf" /proc/swaps 2>/dev/null; then
                _tsz=$(awk -v p="$_tf" '$1==p {print int($3/1024)}' /proc/swaps)
                printf "  ${YELLOW}[临时Swap运行中] %s (%s MB) — 重启后自动清理${PLAIN}\n" "$_tf" "$_tsz"
                printf "\n"
            fi
        fi

        printf "  请选择 [0-6]: "
        read menu_choice

        case "$menu_choice" in
            1) create_swap_flow ;;
            2) show_swap_status ;;
            3) disable_all_swap ;;
            4) delete_swap ;;
            5) create_temp_swap_flow ;;
            6) remove_temp_swap ;;
            0) printf "\n  再见！\n\n"; exit 0 ;;
            *) print_error "无效选择，请重新输入" ;;
        esac
    done
}

# ============================================================
#  入口
# ============================================================
main() {
    clear
    printf "\n"
    printf "${CYAN}╔══════════════════════════════════════════════════════╗${PLAIN}\n"
    printf "${CYAN}║   全平台一键交互式 Swap 管理工具  v3.1             ║${PLAIN}\n"
    printf "${CYAN}║   OpenWrt / Armbian / Debian / Ubuntu / PVE(ZFS)   ║${PLAIN}\n"
    printf "${CYAN}╚══════════════════════════════════════════════════════╝${PLAIN}\n"
    printf "\n"

    check_root
    detect_system
    install_deps
    main_menu
}

main
