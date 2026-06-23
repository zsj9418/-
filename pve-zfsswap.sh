#!/bin/sh

# ---------- 颜色定义 ----------
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
PLAIN='\033[0m'

# ---------- 全局变量 ----------
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

    printf "  系统类型：${GREEN}%s${PLAIN}\n" "$SYS_DESC"
    printf "  平台识别：${GREEN}%s${PLAIN}\n" "$SYSTEM_TYPE"
    printf "  CPU 架构：${GREEN}%s${PLAIN}\n" "$ARCH"
    printf "  内核版本：${GREEN}%s${PLAIN}\n" "$KERNEL"
    printf "  物理内存：${GREEN}%s MB${PLAIN}\n" "$MEM_TOTAL_MB"
    printf "  根文件系统：${GREEN}%s${PLAIN}\n" "$ROOT_FS_TYPE"
    printf "  ZFS 支持：${GREEN}%s${PLAIN}\n" "$HAS_ZFS"

    if [ "$SWAP_TOTAL_MB" -gt 0 ]; then
        printf "  当前 Swap：${YELLOW}%s MB（已存在）${PLAIN}\n" "$SWAP_TOTAL_MB"
    else
        printf "  当前 Swap：${RED}无${PLAIN}\n"
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
            if ! echo "$NEED_INSTALL" | grep -q "swap-utils"; then
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
            if ! echo "$NEED_INSTALL" | grep -q "block-mount"; then
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

    if [ "$SYSTEM_TYPE" = "openwrt" ] && [ -f /etc/config/fstab ]; then
        printf "  ── UCI fstab swap 配置 ──\n"
        uci show fstab 2>/dev/null | grep swap || printf "  无\n"
    fi

    if [ "$SYSTEM_TYPE" = "linux" ] && [ -f /etc/fstab ]; then
        printf "  ── /etc/fstab swap 条目 ──\n"
        grep -i swap /etc/fstab || printf "  无\n"
    fi
}

# ---------- 扫描存储设备 ----------
scan_storage() {
    print_title "③ 扫描可用存储设备"

    STORAGE_COUNT=0

    # --- 根分区 ---
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

        case "$ROOT_FS_TYPE" in
            zfs)  eval "STOR_${STORAGE_COUNT}_TYPE='ZFS根分区'"
                  eval "STOR_${STORAGE_COUNT}_WARN='推荐用zvol方式'" ;;
            ext4) eval "STOR_${STORAGE_COUNT}_TYPE='内部存储'"
                  eval "STOR_${STORAGE_COUNT}_WARN='注意写入寿命'" ;;
            *)    eval "STOR_${STORAGE_COUNT}_TYPE='系统根分区'"
                  eval "STOR_${STORAGE_COUNT}_WARN=''" ;;
        esac
    fi

    # --- 外接 /dev/sd* ---
    mount_lines=$(mount | grep '^/dev/sd' | awk '{print $1 ":" $3 ":" $5}')
    for mnt_line in $mount_lines; do
        EXT_DEV=$(echo "$mnt_line" | cut -d: -f1)
        EXT_MOUNT=$(echo "$mnt_line" | cut -d: -f2)
        EXT_FSTYPE=$(echo "$mnt_line" | cut -d: -f3)
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

    # --- eMMC 其他分区 (OpenWrt) ---
    if [ "$SYSTEM_TYPE" = "openwrt" ]; then
        mount_lines=$(mount | grep '^/dev/mmcblk' | grep -v "$ROOT_DEV" | grep -v 'squashfs' | awk '{print $1 ":" $3 ":" $5}')
        for mnt_line in $mount_lines; do
            MMC_DEV=$(echo "$mnt_line" | cut -d: -f1)
            MMC_MOUNT=$(echo "$mnt_line" | cut -d: -f2)
            MMC_FSTYPE=$(echo "$mnt_line" | cut -d: -f3)

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

    # --- ZFS 池 ---
    if [ "$HAS_ZFS" = "yes" ]; then
        ZFS_FREE=$(zpool list -H -o free rpool 2>/dev/null | sed 's/[^0-9.]//g')
        ZFS_SIZE=$(zpool list -H -o size rpool 2>/dev/null)
        if [ -n "$ZFS_FREE" ]; then
            ZFS_FREE_NUM=$(echo "$ZFS_FREE" | awk '{printf "%d", $1 * 1024 * 1024}')
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

    # --- 显示结果 ---
    if [ "$STORAGE_COUNT" -eq 0 ]; then
        print_error "未找到可用存储（需 > 100MB 空闲）"
        exit 1
    fi

    printf "\n"
    printf "  ${BLUE}%-4s %-22s %-14s %-8s %-8s %-6s %s${PLAIN}\n" \
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
        printf "  %-4s %-22s %-14s %-8s %-8s %-6s %s\n" \
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

    if [ -z "$choice" ] || ! echo "$choice" | grep -qE '^[0-9]+$'; then
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
            if ! echo "$custom_size" | grep -qE '^[0-9]+$'; then
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
        print_error "大小（${SWAP_SIZE_MB}MB）超出可用空间（最大${MAX_SWAP}MB）！"
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

    case "$CHOSEN_FSTYPE" in
        *zfs*)
            printf "  ${GREEN}ZFS 存储，选 [2] 或 [3] 即可${PLAIN}\n" ;;
        *)
            case "$CHOSEN_TYPE" in
                *eMMC*|*内部*)
                    printf "  ${YELLOW}eMMC/闪存，建议 [1] 或 [2]${PLAIN}\n" ;;
                *)
                    printf "  ${GREEN}外接设备，选 [2] 或 [3] 即可${PLAIN}\n" ;;
            esac
            ;;
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

# ============================================================
#  创建 Swap - ZFS 方式
# ============================================================
create_zfs_swap() {
    print_title "正在创建 ZFS Swap (zvol)"

    local swap_size_mb="$SWAP_SIZE_MB"
    local swap_size_display="${swap_size_mb}M"

    if [ "$swap_size_mb" -ge 1024 ]; then
        swap_size_display="$((swap_size_mb / 1024))G"
    fi

    if zfs list "$ZFS_DATASET" >/dev/null 2>&1; then
        print_warn "ZFS 数据集 '${ZFS_DATASET}' 已存在"

        if grep -q "$ZFS_ZVOL" /proc/swaps 2>/dev/null; then
            print_info "且已作为 swap 启用"
            show_swap_status
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
                if [ $? -ne 0 ]; then
                    print_error "删除失败，终止"
                    return 1
                fi
                ;;
            3) printf "  取消。\n"; return 0 ;;
            *) printf "  无效选择。\n"; return 0 ;;
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

# ---------- 删除 ZFS Swap (内部) ----------
delete_zfs_swap_internal() {
    if grep -q "$ZFS_ZVOL" /proc/swaps 2>/dev/null; then
        swapoff "$ZFS_ZVOL" 2>/dev/null
    fi

    local retry=3
    while [ $retry -gt 0 ]; do
        zfs destroy "$ZFS_DATASET" 2>/dev/null
        if [ $? -eq 0 ]; then
            print_info "ZFS 数据集 ${ZFS_DATASET} 已删除"
            if [ -f /etc/fstab ]; then
                sed -i "\|${ZFS_ZVOL}|d" /etc/fstab
            fi
            return 0
        fi
        retry=$((retry - 1))
        if [ $retry -gt 0 ]; then
            print_warn "删除失败，${retry} 次重试剩余，等待 2 秒..."
            sleep 2
        fi
    done
    print_error "删除 ZFS 数据集失败，请手动处理"
    return 1
}

# ============================================================
#  创建 Swap - 文件方式
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
            3) printf "  取消。\n"; return 0 ;;
            *) printf "  无效选择。\n"; return 0 ;;
        esac
    fi

    printf "  [1/6] 创建 %sMB 文件... " "$SWAP_SIZE_MB"
    if command -v fallocate >/dev/null 2>&1; then
        fallocate -l ${SWAP_SIZE_MB}M "$SWAP_FILE" 2>/dev/null
        if [ $? -ne 0 ]; then
            dd if=/dev/zero of="$SWAP_FILE" bs=1M count=$SWAP_SIZE_MB 2>/dev/null
        fi
    else
        dd if=/dev/zero of="$SWAP_FILE" bs=1M count=$SWAP_SIZE_MB 2>/dev/null
    fi
    if [ $? -ne 0 ]; then
        printf "${RED}失败${PLAIN}\n"
        print_error "创建文件失败！空间不足？"
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
    swapon "$SWAP_FILE"
    if [ $? -ne 0 ]; then
        printf "${RED}失败${PLAIN}\n"
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
#  卸载 Swap
# ============================================================
disable_all_swap() {
    print_title "卸载 Swap"

    EXISTING=$(cat /proc/swaps | tail -n +2)
    if [ -z "$EXISTING" ]; then
        print_warn "当前没有启用任何 Swap"
        return 0
    fi

    printf "  当前 Swap：\n"
    cat /proc/swaps
    printf "\n"

    if confirm_yes_no "确认卸载所有 Swap？"; then
        sync
        swapoff -a 2>/dev/null
        if [ $? -eq 0 ]; then
            print_info "所有 Swap 已卸载"
        else
            print_error "卸载失败，可能有进程占用"
        fi
    fi
}

# ============================================================
#  彻底删除 Swap
# ============================================================
delete_swap() {
    print_title "彻底删除 Swap"

    EXISTING=$(cat /proc/swaps | tail -n +2)
    HAS_SOMETHING=0

    if [ -n "$EXISTING" ]; then
        HAS_SOMETHING=1
    fi

    # 检查残留
    for sf in /swapfile /mnt/*/swapfile; do
        if [ -f "$sf" ]; then
            HAS_SOMETHING=1
        fi
    done

    if [ "$HAS_ZFS" = "yes" ] && zfs list "$ZFS_DATASET" >/dev/null 2>&1; then
        HAS_SOMETHING=1
    fi

    if [ "$HAS_SOMETHING" = "0" ]; then
        print_warn "没有找到任何 Swap 或残留文件"
        return 0
    fi

    printf "\n"
    printf "  将要删除的内容：\n"

    cat /proc/swaps | tail -n +2 | while read swap_line; do
        swap_path=$(printf "%s" "$swap_line" | awk '{print $1}')
        swap_size=$(printf "%s" "$swap_line" | awk '{print $3}')
        printf "    - %s (%s KB)\n" "$swap_path" "$swap_size"
    done

    for sf in /swapfile /mnt/*/swapfile; do
        if [ -f "$sf" ]; then
            printf "    - 文件: %s\n" "$sf"
        fi
    done

    if [ "$HAS_ZFS" = "yes" ] && zfs list "$ZFS_DATASET" >/dev/null 2>&1; then
        printf "    - ZFS: %s\n" "$ZFS_DATASET"
    fi

    if ! confirm_type_yes "警告：此操作不可恢复！"; then
        printf "  已取消。\n"
        return 0
    fi

    printf "\n"

    sync
    swapoff -a 2>/dev/null
    print_info "所有 swap 已关闭"

    for sf in /swapfile /mnt/*/swapfile; do
        if [ -f "$sf" ]; then
            rm -f "$sf"
            print_info "已删除文件 $sf"
        fi
    done

    if [ "$HAS_ZFS" = "yes" ] && zfs list "$ZFS_DATASET" >/dev/null 2>&1; then
        delete_zfs_swap_internal
    fi

    if [ "$SYSTEM_TYPE" = "openwrt" ]; then
        while uci -q get fstab.@swap[0] >/dev/null 2>&1; do
            uci delete fstab.@swap[0] 2>/dev/null
        done
        uci commit fstab 2>/dev/null
        print_info "已清除 UCI fstab swap 配置"
    fi

    if [ -f /etc/fstab ]; then
        sed -i '/swap/d' /etc/fstab 2>/dev/null
        print_info "已清除 /etc/fstab swap 条目"
    fi

    if [ -f /etc/sysctl.conf ]; then
        sed -i '/^vm.swappiness/d' /etc/sysctl.conf
        print_info "已清除 sysctl swappiness 配置"
    fi

    printf "\n"
    print_info "Swap 已彻底删除"
}

# ============================================================
#  创建流程
# ============================================================
create_swap_flow() {
    scan_storage
    choose_storage || return
    choose_size || return
    choose_swappiness || return

    # 确认
    print_title "⑦ 配置确认"
    printf "  系统：        ${GREEN}%s${PLAIN}\n" "$SYS_DESC"
    printf "  架构：        ${GREEN}%s${PLAIN}\n" "$ARCH"
    printf "  物理内存：    ${GREEN}%s MB${PLAIN}\n" "$MEM_TOTAL_MB"
    printf "  存储设备：    ${GREEN}%s (%s)${PLAIN}\n" "$CHOSEN_DEV" "$CHOSEN_TYPE"
    printf "  文件系统：    ${GREEN}%s${PLAIN}\n" "$CHOSEN_FSTYPE"
    printf "  Swap 大小：   ${GREEN}%s MB${PLAIN}\n" "$SWAP_SIZE_MB"
    printf "  swappiness：  ${GREEN}%s${PLAIN}\n" "$SWAPPINESS"
    printf "  开机自启：    ${GREEN}是${PLAIN}\n"

    if ! confirm_yes_no "确认以上配置并开始创建？"; then
        printf "  已取消。\n"
        return
    fi

    if [ "$CHOSEN_FSTYPE" = "zfs" ]; then
        create_zfs_swap
    else
        create_file_swap
    fi

    printf "\n"
    show_swap_status

    print_line
    printf "  ${GREEN}✅ 设置完成，重启后 Swap 将自动加载${PLAIN}\n"
    print_line
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
        printf "    [1] 创建并启用 Swap\n"
        printf "    [2] 查看当前 Swap 状态\n"
        printf "    [3] 卸载 Swap（临时关闭）\n"
        printf "    [4] 彻底删除 Swap（含文件和配置）\n"
        printf "    [0] 退出\n"
        printf "\n"
        printf "  请选择 [0-4]: "
        read menu_choice

        case "$menu_choice" in
            1) create_swap_flow ;;
            2) show_swap_status ;;
            3) disable_all_swap ;;
            4) delete_swap ;;
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
    printf "${CYAN}║   全平台一键交互式 Swap 管理工具  v2.1             ║${PLAIN}\n"
    printf "${CYAN}║   支持: OpenWrt / Debian / Ubuntu / PVE(ZFS)       ║${PLAIN}\n"
    printf "${CYAN}╚══════════════════════════════════════════════════════╝${PLAIN}\n"
    printf "\n"

    check_root
    detect_system
    install_deps
    main_menu
}

main
