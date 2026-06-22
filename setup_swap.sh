#!/bin/sh

# ============================================================
#  OpenWrt 一键交互式 Swap 设置工具  v2.1
#  功能：创建/卸载还原 Swap，不影响现有磁盘数据
# ============================================================

SCRIPT_VERSION="2.1"
SWAP_RECORD="/etc/swap_setup.conf"

# ---------- 颜色定义 ----------
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
PLAIN='\033[0m'

# ---------- 工具函数 ----------
print_line() {
    echo "────────────────────────────────────────────────────"
}

print_title() {
    echo ""
    print_line
    echo -e "${CYAN}  $1${PLAIN}"
    print_line
}

print_info() {
    echo -e "${GREEN}[✓]${PLAIN} $1"
}

print_warn() {
    echo -e "${YELLOW}[!]${PLAIN} $1"
}

print_error() {
    echo -e "${RED}[✗]${PLAIN} $1"
}

# ✅ 取消时 return 1，不 exit，让调用方决定如何处理
confirm_continue() {
    echo ""
    echo -ne "${YELLOW}是否继续？[y/N]: ${PLAIN}"
    read answer
    case "$answer" in
        y|Y|yes|YES) return 0 ;;
        *)
            echo ""
            echo -e "  ${YELLOW}已取消，返回主菜单。${PLAIN}"
            sleep 1
            return 1
            ;;
    esac
}

# 按回车返回菜单
press_enter_return() {
    echo ""
    echo -ne "  ${YELLOW}按 Enter 返回主菜单...${PLAIN}"
    read _dummy
}

# ---------- 清理函数（trap 用） ----------
CLEANUP_FILE=""
cleanup_on_exit() {
    if [ -n "$CLEANUP_FILE" ] && [ -f "$CLEANUP_FILE" ]; then
        print_warn "检测到中断，正在清理临时文件..."
        swapoff "$CLEANUP_FILE" 2>/dev/null
        rm -f "$CLEANUP_FILE"
        print_info "已清理 $CLEANUP_FILE"
    fi
}
trap cleanup_on_exit INT TERM

# ---------- 检查 root 权限 ----------
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
        SYS_NAME="${DISTRIB_ID:-OpenWrt}"
        SYS_VER="${DISTRIB_RELEASE:-unknown}"
        SYS_DESC="${DISTRIB_DESCRIPTION:-unknown}"
    elif [ -f /etc/os-release ]; then
        . /etc/os-release
        SYS_NAME="${NAME:-Linux}"
        SYS_VER="${VERSION:-unknown}"
        SYS_DESC="${PRETTY_NAME:-unknown}"
    else
        SYS_NAME="Unknown"
        SYS_VER="unknown"
        SYS_DESC="unknown"
    fi

    ARCH=$(uname -m)
    KERNEL=$(uname -r)
    MEM_TOTAL_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo)
    MEM_TOTAL_MB=$((MEM_TOTAL_KB / 1024))
    SWAP_TOTAL_KB=$(awk '/SwapTotal/{print $2}' /proc/meminfo)
    SWAP_TOTAL_MB=$((SWAP_TOTAL_KB / 1024))

    echo -e "  系统名称：${GREEN}${SYS_DESC}${PLAIN}"
    echo -e "  系统版本：${GREEN}${SYS_VER}${PLAIN}"
    echo -e "  CPU 架构：${GREEN}${ARCH}${PLAIN}"
    echo -e "  内核版本：${GREEN}${KERNEL}${PLAIN}"
    echo -e "  物理内存：${GREEN}${MEM_TOTAL_MB} MB${PLAIN}"

    if [ "$SWAP_TOTAL_MB" -gt 0 ]; then
        echo -e "  当前Swap：${YELLOW}${SWAP_TOTAL_MB} MB（已存在）${PLAIN}"
    else
        echo -e "  当前Swap：${RED}无${PLAIN}"
    fi
}

# ---------- 获取文件系统类型 ----------
get_fs_type() {
    local mount_point="$1"
    mount | grep " ${mount_point} " | head -1 | sed 's/.*type \([^ ]*\).*/\1/'
}

# ---------- 检查文件系统是否支持 swap 文件 ----------
check_fs_support() {
    local fs_type="$1"
    case "$fs_type" in
        ext2|ext3|ext4|f2fs|xfs|btrfs|jffs2)
            return 0 ;;
        vfat|fat16|fat32|ntfs|exfat|fuseblk)
            return 1 ;;
        *)
            return 0 ;;
    esac
}

# ---------- 检查已有 swap ----------
check_existing_swap() {
    EXISTING_SWAPS=$(tail -n +2 /proc/swaps)
    KEEP_OLD_SWAP=0

    if [ -n "$EXISTING_SWAPS" ]; then
        echo ""
        print_warn "检测到系统已有以下 Swap："
        echo ""
        cat /proc/swaps
        echo ""
        echo -ne "${YELLOW}是否先关闭已有 Swap 再重新设置？[y/N]: ${PLAIN}"
        read del_answer
        case "$del_answer" in
            y|Y|yes|YES)
                print_info "正在关闭所有已有 Swap..."
                OLD_SWAP_LIST=$(tail -n +2 /proc/swaps | awk '{print $1}')
                swapoff -a 2>/dev/null

                for old_swap in $OLD_SWAP_LIST; do
                    if [ -f "$old_swap" ]; then
                        echo -ne "  是否删除旧 swap 文件 ${old_swap}？[y/N]: "
                        read del_file
                        case "$del_file" in
                            y|Y) rm -f "$old_swap"; print_info "已删除 $old_swap" ;;
                            *)   print_warn "保留 $old_swap" ;;
                        esac
                    fi
                done

                if command -v uci >/dev/null 2>&1 && [ -f /etc/config/fstab ]; then
                    while uci -q get fstab.@swap[0] >/dev/null 2>&1; do
                        uci delete fstab.@swap[0] 2>/dev/null
                    done
                    uci commit fstab 2>/dev/null
                    print_info "已清除 fstab 中的旧 Swap 配置"
                fi
                KEEP_OLD_SWAP=0
                ;;
            *)
                print_warn "保留已有 Swap，将追加新的 Swap。"
                KEEP_OLD_SWAP=1
                ;;
        esac
    fi
}

# ---------- 安装依赖 ----------
install_deps() {
    print_title "② 检查并安装依赖"

    NEED_INSTALL=""
    NEED_SWAP_UTILS=0
    NEED_BLOCK=0

    if ! command -v mkswap >/dev/null 2>&1; then
        NEED_SWAP_UTILS=1
        print_warn "缺少 mkswap（swap-utils）"
    else
        print_info "mkswap 已存在"
    fi

    if ! command -v swapon >/dev/null 2>&1; then
        NEED_SWAP_UTILS=1
        print_warn "缺少 swapon（swap-utils）"
    else
        print_info "swapon 已存在"
    fi

    [ "$NEED_SWAP_UTILS" -eq 1 ] && NEED_INSTALL="${NEED_INSTALL} swap-utils"

    if ! command -v block >/dev/null 2>&1; then
        NEED_BLOCK=1
        print_warn "缺少 block（block-mount）"
    else
        print_info "block 已存在"
    fi

    if [ ! -f /etc/config/fstab ]; then
        NEED_BLOCK=1
        print_warn "缺少 /etc/config/fstab"
    else
        print_info "/etc/config/fstab 已存在"
    fi

    [ "$NEED_BLOCK" -eq 1 ] && NEED_INSTALL="${NEED_INSTALL} block-mount"

    if [ -n "$NEED_INSTALL" ]; then
        echo ""
        print_warn "需要安装以下软件包：${NEED_INSTALL}"
        echo -ne "${YELLOW}是否立即安装？[Y/n]: ${PLAIN}"
        read inst_answer
        case "$inst_answer" in
            n|N|no|NO)
                print_error "缺少必要依赖，无法继续。"
                return 1
                ;;
            *)
                print_info "正在更新软件源..."
                opkg update
                if [ $? -ne 0 ]; then
                    print_error "opkg update 失败，请检查网络连接！"
                    return 1
                fi
                for pkg in $NEED_INSTALL; do
                    print_info "正在安装 ${pkg}..."
                    opkg install "$pkg"
                    if [ $? -ne 0 ]; then
                        print_error "安装 ${pkg} 失败！"
                        return 1
                    fi
                done
                print_info "所有依赖安装完成"
                ;;
        esac
    else
        print_info "所有依赖已满足，无需安装"
    fi
    return 0
}

# ---------- 扫描可用存储设备 ----------
scan_storage() {
    print_title "③ 扫描可用存储设备"

    STORAGE_COUNT=0

    # 根分区
    ROOT_DEV=$(df / | tail -1 | awk '{print $1}')
    ROOT_MOUNT=$(df / | tail -1 | awk '{print $6}')
    ROOT_TOTAL=$(df -h / | tail -1 | awk '{print $2}')
    ROOT_AVAIL=$(df -h / | tail -1 | awk '{print $4}')
    ROOT_AVAIL_KB=$(df / | tail -1 | awk '{print $4}')
    ROOT_FS=$(get_fs_type "$ROOT_MOUNT")

    if [ "$ROOT_AVAIL_KB" -gt 102400 ]; then
        if check_fs_support "$ROOT_FS"; then
            STORAGE_COUNT=$((STORAGE_COUNT + 1))
            eval "STOR_${STORAGE_COUNT}_DEV='${ROOT_DEV}'"
            eval "STOR_${STORAGE_COUNT}_MOUNT='${ROOT_MOUNT}'"
            eval "STOR_${STORAGE_COUNT}_TOTAL='${ROOT_TOTAL}'"
            eval "STOR_${STORAGE_COUNT}_AVAIL='${ROOT_AVAIL}'"
            eval "STOR_${STORAGE_COUNT}_AVAIL_KB='${ROOT_AVAIL_KB}'"
            eval "STOR_${STORAGE_COUNT}_TYPE='eMMC/内部存储'"
            eval "STOR_${STORAGE_COUNT}_FS='${ROOT_FS}'"
            eval "STOR_${STORAGE_COUNT}_WARN='eMMC有写入寿命限制，建议swappiness调低'"
        else
            print_warn "根分区文件系统 ${ROOT_FS} 不支持 swap 文件，已跳过"
        fi
    fi

    # 外接 USB / SATA / NVMe
    mount | grep -E '^/dev/(sd|nvme)' | awk '{print $1 ":" $3}' > /tmp/.swap_scan_$$
    while IFS=':' read -r EXT_DEV EXT_MOUNT; do
        [ -z "$EXT_DEV" ] && continue
        EXT_TOTAL=$(df -h "$EXT_MOUNT" 2>/dev/null | tail -1 | awk '{print $2}')
        EXT_AVAIL=$(df -h "$EXT_MOUNT" 2>/dev/null | tail -1 | awk '{print $4}')
        EXT_AVAIL_KB=$(df "$EXT_MOUNT" 2>/dev/null | tail -1 | awk '{print $4}')
        EXT_FS=$(get_fs_type "$EXT_MOUNT")
        [ -z "$EXT_AVAIL_KB" ] && continue
        if [ "$EXT_AVAIL_KB" -gt 102400 ] 2>/dev/null; then
            if check_fs_support "$EXT_FS"; then
                STORAGE_COUNT=$((STORAGE_COUNT + 1))
                eval "STOR_${STORAGE_COUNT}_DEV='${EXT_DEV}'"
                eval "STOR_${STORAGE_COUNT}_MOUNT='${EXT_MOUNT}'"
                eval "STOR_${STORAGE_COUNT}_TOTAL='${EXT_TOTAL}'"
                eval "STOR_${STORAGE_COUNT}_AVAIL='${EXT_AVAIL}'"
                eval "STOR_${STORAGE_COUNT}_AVAIL_KB='${EXT_AVAIL_KB}'"
                eval "STOR_${STORAGE_COUNT}_TYPE='外接USB/SATA/NVMe'"
                eval "STOR_${STORAGE_COUNT}_FS='${EXT_FS}'"
                eval "STOR_${STORAGE_COUNT}_WARN='外接设备，推荐 ✅'"
            else
                print_warn "${EXT_MOUNT} 文件系统 ${EXT_FS} 不支持 swap，已跳过"
            fi
        fi
    done < /tmp/.swap_scan_$$
    rm -f /tmp/.swap_scan_$$

    # mmcblk 非根分区
    mount | grep '^/dev/mmcblk' | grep -v "$ROOT_DEV" | grep -v 'squashfs' \
        | awk '{print $1 ":" $3}' > /tmp/.swap_scan_mmc_$$
    while IFS=':' read -r MMC_DEV MMC_MOUNT; do
        [ -z "$MMC_DEV" ] && continue
        case "$MMC_MOUNT" in
            /rom|/proc|/sys|/dev|/tmp) continue ;;
        esac
        MMC_TOTAL=$(df -h "$MMC_MOUNT" 2>/dev/null | tail -1 | awk '{print $2}')
        MMC_AVAIL=$(df -h "$MMC_MOUNT" 2>/dev/null | tail -1 | awk '{print $4}')
        MMC_AVAIL_KB=$(df "$MMC_MOUNT" 2>/dev/null | tail -1 | awk '{print $4}')
        MMC_FS=$(get_fs_type "$MMC_MOUNT")
        [ -z "$MMC_AVAIL_KB" ] && continue
        if [ "$MMC_AVAIL_KB" -gt 102400 ] 2>/dev/null; then
            if check_fs_support "$MMC_FS"; then
                STORAGE_COUNT=$((STORAGE_COUNT + 1))
                eval "STOR_${STORAGE_COUNT}_DEV='${MMC_DEV}'"
                eval "STOR_${STORAGE_COUNT}_MOUNT='${MMC_MOUNT}'"
                eval "STOR_${STORAGE_COUNT}_TOTAL='${MMC_TOTAL}'"
                eval "STOR_${STORAGE_COUNT}_AVAIL='${MMC_AVAIL}'"
                eval "STOR_${STORAGE_COUNT}_AVAIL_KB='${MMC_AVAIL_KB}'"
                eval "STOR_${STORAGE_COUNT}_TYPE='eMMC其他分区'"
                eval "STOR_${STORAGE_COUNT}_FS='${MMC_FS}'"
                eval "STOR_${STORAGE_COUNT}_WARN='eMMC有写入寿命限制'"
            else
                print_warn "${MMC_MOUNT} 文件系统 ${MMC_FS} 不支持 swap，已跳过"
            fi
        fi
    done < /tmp/.swap_scan_mmc_$$
    rm -f /tmp/.swap_scan_mmc_$$

    if [ "$STORAGE_COUNT" -eq 0 ]; then
        print_error "未找到可用存储设备（需 > 100MB 空闲，且为 Linux 原生文件系统）"
        return 1
    fi

    echo ""
    printf "  ${BLUE}%-4s %-20s %-14s %-8s %-10s %-10s %s${PLAIN}\n" \
        "编号" "设备" "类型" "文件系统" "总容量" "可用" "说明"
    print_line

    i=1
    while [ $i -le $STORAGE_COUNT ]; do
        eval "s_dev=\${STOR_${i}_DEV}"
        eval "s_type=\${STOR_${i}_TYPE}"
        eval "s_total=\${STOR_${i}_TOTAL}"
        eval "s_avail=\${STOR_${i}_AVAIL}"
        eval "s_mount=\${STOR_${i}_MOUNT}"
        eval "s_warn=\${STOR_${i}_WARN}"
        eval "s_fs=\${STOR_${i}_FS}"
        printf "  %-4s %-20s %-14s %-8s %-10s %-10s %s\n" \
            "[$i]" "$s_dev" "$s_type" "$s_fs" "$s_total" "$s_avail" "$s_warn"
        echo "       挂载点: $s_mount"
        i=$((i + 1))
    done
    return 0
}

# ---------- 用户选择存储 ----------
choose_storage() {
    print_title "④ 选择存储设备"

    echo -ne "  请输入编号 [1-${STORAGE_COUNT}]: "
    read choice

    case "$choice" in
        ''|*[!0-9]*)
            print_error "无效选择！请输入数字。"
            return 1
            ;;
    esac

    if [ "$choice" -lt 1 ] || [ "$choice" -gt "$STORAGE_COUNT" ]; then
        print_error "无效选择！超出范围。"
        return 1
    fi

    eval "CHOSEN_DEV=\${STOR_${choice}_DEV}"
    eval "CHOSEN_MOUNT=\${STOR_${choice}_MOUNT}"
    eval "CHOSEN_TYPE=\${STOR_${choice}_TYPE}"
    eval "CHOSEN_AVAIL=\${STOR_${choice}_AVAIL}"
    eval "CHOSEN_AVAIL_KB=\${STOR_${choice}_AVAIL_KB}"
    eval "CHOSEN_WARN=\${STOR_${choice}_WARN}"
    eval "CHOSEN_FS=\${STOR_${choice}_FS}"

    CHOSEN_AVAIL_MB=$((CHOSEN_AVAIL_KB / 1024))

    print_info "已选择：${CHOSEN_DEV}（${CHOSEN_TYPE}）"
    print_info "挂载点：${CHOSEN_MOUNT}"
    print_info "文件系统：${CHOSEN_FS}"
    print_info "可用空间：${CHOSEN_AVAIL}"
    return 0
}

# ---------- 用户选择大小 ----------
choose_size() {
    print_title "⑤ 设置 Swap 大小"

    if [ "$MEM_TOTAL_MB" -le 128 ]; then
        REC_SIZE=256
    elif [ "$MEM_TOTAL_MB" -le 512 ]; then
        REC_SIZE=512
    elif [ "$MEM_TOTAL_MB" -le 1024 ]; then
        REC_SIZE=512
    else
        REC_SIZE=1024
    fi

    MAX_SWAP=$((CHOSEN_AVAIL_MB - 200))
    if [ "$MAX_SWAP" -lt 64 ]; then
        print_error "可用空间不足（需至少预留 200MB）！"
        return 1
    fi

    [ "$REC_SIZE" -gt "$MAX_SWAP" ] && REC_SIZE=$MAX_SWAP

    echo -e "  物理内存：${GREEN}${MEM_TOTAL_MB} MB${PLAIN}"
    echo -e "  可用空间：${GREEN}${CHOSEN_AVAIL_MB} MB${PLAIN}（预留200MB后最大 ${MAX_SWAP} MB）"
    echo -e "  推荐大小：${GREEN}${REC_SIZE} MB${PLAIN}"
    echo ""
    echo "  常用选项："
    echo "    [1] 128 MB"
    echo "    [2] 256 MB"
    echo "    [3] 512 MB"
    echo "    [4] 1024 MB (1GB)"
    echo "    [5] 自定义大小"
    echo ""
    echo -ne "  请选择 [1-5]（回车默认推荐 ${REC_SIZE}MB）: "
    read size_choice

    case "$size_choice" in
        1) SWAP_SIZE=128 ;;
        2) SWAP_SIZE=256 ;;
        3) SWAP_SIZE=512 ;;
        4) SWAP_SIZE=1024 ;;
        5)
            echo -ne "  请输入自定义大小（单位MB，64-${MAX_SWAP}）: "
            read custom_size
            case "$custom_size" in
                ''|*[!0-9]*)
                    print_error "输入无效，请输入纯数字！"
                    return 1
                    ;;
            esac
            if [ "$custom_size" -lt 64 ] || [ "$custom_size" -gt "$MAX_SWAP" ]; then
                print_error "输入超出范围（64-${MAX_SWAP}）！"
                return 1
            fi
            SWAP_SIZE=$custom_size
            ;;
        "")
            SWAP_SIZE=$REC_SIZE
            ;;
        *)
            print_error "无效选择！"
            return 1
            ;;
    esac

    if [ "$SWAP_SIZE" -gt "$MAX_SWAP" ]; then
        print_error "选择的大小 (${SWAP_SIZE}MB) 超出可用空间 (最大${MAX_SWAP}MB)！"
        return 1
    fi

    print_info "将创建 ${SWAP_SIZE} MB 的 Swap"
    return 0
}

# ---------- 选择 swappiness ----------
choose_swappiness() {
    print_title "⑥ 设置 swappiness（内核使用swap的积极程度）"

    echo "  数值越低，越倾向使用物理内存，减少闪存磨损"
    echo ""
    echo "    [1]  5  — 极少使用swap（闪存友好）"
    echo "    [2] 10  — 推荐值 ✅"
    echo "    [3] 30  — 适中"
    echo "    [4] 60  — 系统默认"
    echo ""

    case "$CHOSEN_TYPE" in
        *eMMC*|*内部*)
            echo -e "  ${YELLOW}提示：你选择的是eMMC，建议选 [1] 或 [2]${PLAIN}"
            DEFAULT_SW=10
            ;;
        *)
            echo -e "  ${GREEN}提示：外接设备，选 [2] 或 [3] 即可${PLAIN}"
            DEFAULT_SW=10
            ;;
    esac

    echo ""
    echo -ne "  请选择 [1-4]（回车默认 ${DEFAULT_SW}）: "
    read sw_choice

    case "$sw_choice" in
        1) SWAPPINESS=5 ;;
        2) SWAPPINESS=10 ;;
        3) SWAPPINESS=30 ;;
        4) SWAPPINESS=60 ;;
        "") SWAPPINESS=$DEFAULT_SW ;;
        *)
            print_error "无效选择！"
            return 1
            ;;
    esac

    print_info "swappiness 将设置为 ${SWAPPINESS}"
    return 0
}

# ---------- 确认汇总 ----------
show_summary() {
    # ✅ 先赋值再显示
    if [ "$CHOSEN_MOUNT" = "/" ]; then
        SWAP_FILE="/swapfile"
    else
        SWAP_FILE="${CHOSEN_MOUNT}/swapfile"
    fi

    print_title "⑦ 配置确认"

    echo -e "  系统：      ${GREEN}${SYS_DESC}${PLAIN}"
    echo -e "  架构：      ${GREEN}${ARCH}${PLAIN}"
    echo -e "  物理内存：  ${GREEN}${MEM_TOTAL_MB} MB${PLAIN}"
    echo -e "  存储设备：  ${GREEN}${CHOSEN_DEV} (${CHOSEN_TYPE})${PLAIN}"
    echo -e "  文件系统：  ${GREEN}${CHOSEN_FS}${PLAIN}"
    echo -e "  挂载点：    ${GREEN}${CHOSEN_MOUNT}${PLAIN}"
    echo -e "  Swap文件：  ${GREEN}${SWAP_FILE}${PLAIN}"
    echo -e "  Swap大小：  ${GREEN}${SWAP_SIZE} MB${PLAIN}"
    echo -e "  swappiness：${GREEN}${SWAPPINESS}${PLAIN}"
    echo -e "  开机自启：  ${GREEN}是${PLAIN}"

    if [ -f "$SWAP_FILE" ]; then
        echo ""
        print_warn "文件 ${SWAP_FILE} 已存在，将被覆盖！"
    fi

    echo ""
    echo -e "  ${GREEN}✔ 此操作仅创建一个新文件，不会格式化磁盘或影响现有数据${PLAIN}"

    # ✅ confirm_continue 返回 1 时，show_summary 也返回 1
    confirm_continue || return 1
    return 0
}

# ---------- 备份配置文件 ----------
backup_configs() {
    local timestamp=$(date +%Y%m%d%H%M%S)

    if [ -f /etc/sysctl.conf ]; then
        cp /etc/sysctl.conf "/etc/sysctl.conf.bak.${timestamp}"
        print_info "已备份 /etc/sysctl.conf.bak.${timestamp}"
    fi

    if [ -f /etc/config/fstab ]; then
        cp /etc/config/fstab "/etc/config/fstab.bak.${timestamp}"
        print_info "已备份 /etc/config/fstab.bak.${timestamp}"
    fi

    BACKUP_TIMESTAMP="$timestamp"
}

# ---------- 执行创建 ----------
create_swap() {
    print_title "⑧ 正在创建 Swap"

    backup_configs

    if [ -f "$SWAP_FILE" ]; then
        print_warn "文件 ${SWAP_FILE} 已存在，清除旧文件..."
        swapoff "$SWAP_FILE" 2>/dev/null
        rm -f "$SWAP_FILE"
        print_info "已删除旧文件"
    fi

    CLEANUP_FILE="$SWAP_FILE"

    # 1. 创建文件（使用 bs=1024 保证 busybox dd 兼容性）
    echo -ne "  [1/7] 创建 ${SWAP_SIZE}MB 文件... "
    dd if=/dev/zero of="$SWAP_FILE" bs=1024 count=$((SWAP_SIZE * 1024)) 2>/dev/null
    if [ $? -ne 0 ]; then
        echo ""
        print_error "创建文件失败！空间不足？"
        rm -f "$SWAP_FILE"
        CLEANUP_FILE=""
        return 1
    fi
    echo -e "${GREEN}完成${PLAIN}"

    # 2. 权限
    echo -ne "  [2/7] 设置权限... "
    chmod 600 "$SWAP_FILE"
    echo -e "${GREEN}完成${PLAIN}"

    # 3. 格式化
    echo -ne "  [3/7] 格式化为 swap... "
    mkswap "$SWAP_FILE" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo ""
        print_error "mkswap 失败！"
        rm -f "$SWAP_FILE"
        CLEANUP_FILE=""
        return 1
    fi
    echo -e "${GREEN}完成${PLAIN}"

    # 4. 启用
    echo -ne "  [4/7] 启用 swap... "
    swapon "$SWAP_FILE"
    if [ $? -ne 0 ]; then
        echo ""
        print_error "swapon 失败！文件系统可能不支持 swap 文件。"
        rm -f "$SWAP_FILE"
        CLEANUP_FILE=""
        return 1
    fi
    echo -e "${GREEN}完成${PLAIN}"

    # 5. swappiness
    echo -ne "  [5/7] 设置 swappiness=${SWAPPINESS}... "
    echo "$SWAPPINESS" > /proc/sys/vm/swappiness
    if [ -f /etc/sysctl.conf ]; then
        sed -i '/^vm.swappiness/d' /etc/sysctl.conf
    fi
    echo "vm.swappiness=${SWAPPINESS}" >> /etc/sysctl.conf
    echo -e "${GREEN}完成${PLAIN}"

    # 6. UCI fstab 开机自启
    echo -ne "  [6/7] 配置 UCI fstab 开机自启... "
    if [ "${KEEP_OLD_SWAP:-0}" -eq 0 ]; then
        while uci -q get fstab.@swap[0] >/dev/null 2>&1; do
            uci delete fstab.@swap[0] 2>/dev/null
        done
    fi
    uci add fstab swap >/dev/null
    uci set fstab.@swap[-1].device="$SWAP_FILE"
    uci set fstab.@swap[-1].enabled='1'
    uci commit fstab
    /etc/init.d/fstab enable 2>/dev/null
    echo -e "${GREEN}完成${PLAIN}"

    # 7. rc.local 备用启动
    echo -ne "  [7/7] 配置 rc.local 备用启动... "
    if [ -f /etc/rc.local ]; then
        sed -i '/# SWAP_SETUP_BEGIN/,/# SWAP_SETUP_END/d' /etc/rc.local
        sed -i "/^exit 0/i\\
# SWAP_SETUP_BEGIN\\
if [ -f \"${SWAP_FILE}\" ] && ! grep -q \"${SWAP_FILE}\" /proc/swaps; then\\
    swapon \"${SWAP_FILE}\" 2>/dev/null\\
fi\\
[ -f /proc/sys/vm/swappiness ] && echo ${SWAPPINESS} > /proc/sys/vm/swappiness\\
# SWAP_SETUP_END" /etc/rc.local
    fi
    echo -e "${GREEN}完成${PLAIN}"

    CLEANUP_FILE=""

    # 保存安装记录
    cat > "$SWAP_RECORD" <<EOF
SWAP_FILE="${SWAP_FILE}"
SWAP_SIZE="${SWAP_SIZE}"
SWAPPINESS="${SWAPPINESS}"
CHOSEN_DEV="${CHOSEN_DEV}"
CHOSEN_MOUNT="${CHOSEN_MOUNT}"
CHOSEN_TYPE="${CHOSEN_TYPE}"
BACKUP_TIMESTAMP="${BACKUP_TIMESTAMP}"
INSTALL_DATE="$(date '+%Y-%m-%d %H:%M:%S')"
EOF
    print_info "安装记录已保存到 ${SWAP_RECORD}"
    return 0
}

# ---------- 显示结果 ----------
show_result() {
    print_title "⑨ 设置完成！"

    echo -e "  ${GREEN}Swap 已成功创建并启用！${PLAIN}"
    echo ""
    echo "  ── free ──"
    free 2>/dev/null || cat /proc/meminfo
    echo ""
    echo "  ── /proc/swaps ──"
    cat /proc/swaps
    echo ""
    echo "  ── swappiness ──"
    echo "  当前值: $(cat /proc/sys/vm/swappiness)"
    echo ""
    echo "  ── fstab 配置 ──"
    uci show fstab 2>/dev/null | grep swap
    echo ""
    print_line
    echo -e "  ${GREEN}✅ 重启后 Swap 将自动加载${PLAIN}"
    echo ""
    echo -e "  管理命令："
    echo -e "    查看状态:  ${CYAN}free -h${PLAIN}"
    echo -e "    卸载还原:  ${CYAN}sh $0${PLAIN}  → 选 [2]"
    print_line

    press_enter_return
}

# ============================================================
#  查看状态
# ============================================================
do_status() {
    clear
    print_title "Swap 状态信息"

    if [ -f "$SWAP_RECORD" ]; then
        . "$SWAP_RECORD"
        echo -e "  安装记录：${GREEN}存在${PLAIN}"
        echo -e "  Swap文件：${GREEN}${SWAP_FILE}${PLAIN}"
        echo -e "  Swap大小：${GREEN}${SWAP_SIZE} MB${PLAIN}"
        echo -e "  安装时间：${GREEN}${INSTALL_DATE}${PLAIN}"
        if [ -n "$BACKUP_TIMESTAMP" ]; then
            echo -e "  配置备份：${GREEN}${BACKUP_TIMESTAMP}${PLAIN}"
        fi
    else
        echo -e "  安装记录：${YELLOW}未找到 ${SWAP_RECORD}${PLAIN}"
    fi

    echo ""
    echo "  ── free ──"
    free 2>/dev/null || cat /proc/meminfo
    echo ""
    echo "  ── /proc/swaps ──"
    cat /proc/swaps
    echo ""
    echo "  ── swappiness ──"
    echo "  当前值: $(cat /proc/sys/vm/swappiness)"
    echo ""

    press_enter_return  # ✅ 等待用户确认，再返回菜单
}

# ============================================================
#  卸载还原
# ============================================================
do_uninstall() {
    clear
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════╗${PLAIN}"
    echo -e "${CYAN}║     OpenWrt Swap 卸载还原工具  v${SCRIPT_VERSION}             ║${PLAIN}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════╝${PLAIN}"
    echo ""

    # 检查安装记录
    if [ ! -f "$SWAP_RECORD" ]; then
        print_warn "未找到安装记录文件 ${SWAP_RECORD}"
        echo ""
        echo -ne "  ${YELLOW}是否尝试手动卸载当前所有 swap？[y/N]: ${PLAIN}"
        read manual_answer
        case "$manual_answer" in
            y|Y|yes|YES) ;;
            *)
                # ✅ 改为 return，不 exit
                echo -e "  ${YELLOW}已取消，返回主菜单。${PLAIN}"
                sleep 1
                return
                ;;
        esac
        RECORD_SWAP_FILE=""
        BACKUP_TIMESTAMP=""
    else
        . "$SWAP_RECORD"
        RECORD_SWAP_FILE="$SWAP_FILE"
        echo ""
        print_info "找到安装记录："
        echo -e "    Swap文件：  ${GREEN}${SWAP_FILE}${PLAIN}"
        echo -e "    Swap大小：  ${GREEN}${SWAP_SIZE} MB${PLAIN}"
        echo -e "    swappiness：${GREEN}${SWAPPINESS}${PLAIN}"
        echo -e "    存储设备：  ${GREEN}${CHOSEN_DEV} (${CHOSEN_TYPE})${PLAIN}"
        echo -e "    安装时间：  ${GREEN}${INSTALL_DATE}${PLAIN}"
        [ -n "$BACKUP_TIMESTAMP" ] && \
            echo -e "    配置备份：  ${GREEN}${BACKUP_TIMESTAMP}${PLAIN}"
    fi

    echo ""
    print_line
    echo -e "  ${YELLOW}卸载将执行以下操作：${PLAIN}"
    echo "    1. 关闭 swap"
    echo "    2. 删除 swap 文件"
    echo "    3. 清除 UCI fstab 中的 swap 配置"
    echo "    4. 清除 rc.local 中的 swap 启动配置"
    echo "    5. 还原 swappiness 为系统默认值 60"
    echo "    6. 还原配置文件备份（如有）"
    print_line

    # ✅ confirm_continue 取消时 return 1，此处 return 回菜单
    confirm_continue || return

    print_title "正在卸载..."

    # 1. 关闭 swap
    echo -ne "  [1/6] 关闭 swap... "
    if [ -n "$RECORD_SWAP_FILE" ] && grep -q "$RECORD_SWAP_FILE" /proc/swaps 2>/dev/null; then
        swapoff "$RECORD_SWAP_FILE" 2>/dev/null
    else
        for sf in $(awk 'NR>1{print $1}' /proc/swaps 2>/dev/null); do
            swapoff "$sf" 2>/dev/null
        done
    fi
    echo -e "${GREEN}完成${PLAIN}"

    # 2. 删除 swap 文件
    echo -ne "  [2/6] 删除 swap 文件... "
    if [ -n "$RECORD_SWAP_FILE" ] && [ -f "$RECORD_SWAP_FILE" ]; then
        rm -f "$RECORD_SWAP_FILE"
        echo -e "${GREEN}已删除 ${RECORD_SWAP_FILE}${PLAIN}"
    else
        echo -e "${YELLOW}未找到 swap 文件（可能已删除）${PLAIN}"
    fi

    # 3. 清除 UCI fstab
    echo -ne "  [3/6] 清除 fstab swap 配置... "
    if command -v uci >/dev/null 2>&1 && [ -f /etc/config/fstab ]; then
        while uci -q get fstab.@swap[0] >/dev/null 2>&1; do
            uci delete fstab.@swap[0] 2>/dev/null
        done
        uci commit fstab 2>/dev/null
    fi
    echo -e "${GREEN}完成${PLAIN}"

    # 4. 清除 rc.local
    echo -ne "  [4/6] 清除 rc.local 配置... "
    if [ -f /etc/rc.local ]; then
        sed -i '/# SWAP_SETUP_BEGIN/,/# SWAP_SETUP_END/d' /etc/rc.local
    fi
    echo -e "${GREEN}完成${PLAIN}"

    # 5. 还原 swappiness
    echo -ne "  [5/6] 还原 swappiness 为默认值 60... "
    [ -f /etc/sysctl.conf ] && sed -i '/^vm.swappiness/d' /etc/sysctl.conf
    echo 60 > /proc/sys/vm/swappiness
    echo -e "${GREEN}完成${PLAIN}"

    # 6. 还原配置备份
    echo -ne "  [6/6] 还原配置文件备份... "
    RESTORED=0
    if [ -n "$BACKUP_TIMESTAMP" ]; then
        if [ -f "/etc/sysctl.conf.bak.${BACKUP_TIMESTAMP}" ]; then
            cp "/etc/sysctl.conf.bak.${BACKUP_TIMESTAMP}" /etc/sysctl.conf
            rm -f "/etc/sysctl.conf.bak.${BACKUP_TIMESTAMP}"
            RESTORED=1
        fi
        if [ -f "/etc/config/fstab.bak.${BACKUP_TIMESTAMP}" ]; then
            cp "/etc/config/fstab.bak.${BACKUP_TIMESTAMP}" /etc/config/fstab
            uci commit fstab 2>/dev/null
            rm -f "/etc/config/fstab.bak.${BACKUP_TIMESTAMP}"
            RESTORED=1
        fi
    fi
    [ "$RESTORED" -eq 1 ] \
        && echo -e "${GREEN}已从备份还原${PLAIN}" \
        || echo -e "${YELLOW}无备份可还原${PLAIN}"

    rm -f "$SWAP_RECORD"

    echo ""
    print_line
    echo -e "  ${GREEN}✅ Swap 已完全卸载还原！${PLAIN}"
    echo ""
    echo "  ── free ──"
    free 2>/dev/null || cat /proc/meminfo
    echo ""
    echo "  ── /proc/swaps ──"
    cat /proc/swaps
    echo ""
    echo "  ── swappiness ──"
    echo "  当前值: $(cat /proc/sys/vm/swappiness)"
    print_line

    press_enter_return  # ✅ 等待用户确认，再返回菜单
}

# ============================================================
#  安装主流程
# ============================================================
do_install() {
    clear
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════╗${PLAIN}"
    echo -e "${CYAN}║     OpenWrt 一键交互式 Swap 设置工具  v${SCRIPT_VERSION}      ║${PLAIN}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════╝${PLAIN}"
    echo ""

    detect_system
    check_existing_swap
    install_deps   || { press_enter_return; return; }
    scan_storage   || { press_enter_return; return; }
    choose_storage || { press_enter_return; return; }
    choose_size    || { press_enter_return; return; }
    choose_swappiness || { press_enter_return; return; }
    show_summary   || return   # 用户在确认页取消，直接回菜单无需提示
    create_swap    || { press_enter_return; return; }
    show_result
}

# ============================================================
#  主菜单（while 循环，永不意外退出）
# ============================================================
show_menu() {
    while true; do
        clear
        echo ""
        echo -e "${CYAN}╔══════════════════════════════════════════════════╗${PLAIN}"
        echo -e "${CYAN}║       OpenWrt Swap 管理工具  v${SCRIPT_VERSION}              ║${PLAIN}"
        echo -e "${CYAN}╚══════════════════════════════════════════════════╝${PLAIN}"
        echo ""

        # 实时状态显示
        _swap_kb=$(awk '/SwapTotal/{print $2}' /proc/meminfo)
        _swap_mb=$((_swap_kb / 1024))
        _swap_used_kb=$(awk '/SwapFree/{print $2}' /proc/meminfo)
        _swap_used_mb=$(((_swap_kb - _swap_used_kb) / 1024))

        if [ "$_swap_mb" -gt 0 ]; then
            echo -e "  当前Swap：${GREEN}${_swap_mb} MB 已启用（已用 ${_swap_used_mb} MB）${PLAIN}"
        else
            echo -e "  当前Swap：${RED}未启用${PLAIN}"
        fi
        echo ""
        echo "  [1] 创建/重新设置 Swap"
        echo "  [2] 卸载还原 Swap（完全恢复）"
        echo "  [3] 查看当前 Swap 状态"
        echo "  [0] 退出"
        echo ""
        echo -ne "  请选择 [0-3]: "
        read menu_choice

        case "$menu_choice" in
            1) do_install   ;;
            2) do_uninstall ;;
            3) do_status    ;;
            0)
                echo ""
                echo -e "  ${GREEN}再见！${PLAIN}"
                echo ""
                exit 0
                ;;
            *)
                echo ""
                print_error "无效选择，请重新输入！"
                sleep 1
                ;;
        esac
    done
}

# ============================================================
#  入口：支持命令行参数，默认显示菜单
# ============================================================
check_root

case "${1:-}" in
    install)   do_install   ;;
    uninstall) do_uninstall ;;
    status)    do_status    ;;
    *)         show_menu    ;;
esac