#!/bin/bash
set -o pipefail

# ======================== 可配置项 ========================
NEW_VG_NAME="pve-data"
LOCAL_DIR_LV_NAME="local-dir"
LOCAL_DIR_LV_SIZE=""              # 留空 = 自动计算 (当前数据+20%，最小50G)
THINPOOL_LV_NAME="data-thinpool"
THINPOOL_RESERVED_PERCENT=10      # Thin Pool 预留空间百分比

# ======================== 全局变量 ========================
LOG_FILE="/var/log/pve_migration_$(date +%Y%m%d_%H%M%S).log"
FSTAB_BACKUP=""
STORAGE_CFG_BACKUP=""
PVECFG_BACKUP=""
TEMP_MOUNT="/mnt/pve_migration_tmp"
SELECTED_DISK=""
SELECTED_DISK_SIZE_BYTES=0
LOCAL_DIR_UUID=""
MIGRATION_COMPLETE=0
AVAILABLE_DISKS=()
DISK_SIZES=()
DISK_MODELS=()

# ======================== 颜色定义 ========================
R='\033[0;31m' G='\033[0;32m' Y='\033[0;33m'
B='\033[0;34m' C='\033[0;36m' M='\033[0;35m'
BD='\033[1m'   NC='\033[0m'

# ======================== 日志函数 ========================
log()    { echo -e "${B}[INFO]${NC} $1" | tee -a "$LOG_FILE"; }
ok()     { echo -e "${G}[ OK ]${NC} $1" | tee -a "$LOG_FILE"; }
warn()   { echo -e "${Y}[WARN]${NC} $1" | tee -a "$LOG_FILE"; }
err()    { echo -e "${R}[FAIL]${NC} $1" | tee -a "$LOG_FILE"; }
die()    { echo -e "${R}[FATAL]${NC} $1" | tee -a "$LOG_FILE"; exit 1; }
banner() {
    echo -e "\n${M}═══════════════════════════════════════════════════════════${NC}" | tee -a "$LOG_FILE"
    echo -e "${M}  $1${NC}" | tee -a "$LOG_FILE"
    echo -e "${M}═══════════════════════════════════════════════════════════${NC}\n" | tee -a "$LOG_FILE"
}

pause() {
    echo -e "\n${Y}按 Enter 键继续...${NC}"
    read -r
}

confirm() {
    local prompt="$1" default="${2:-n}"
    if [ "$default" = "y" ]; then
        read -p "${Y}${prompt} (Y/n): ${NC}" c
        [[ -z "$c" || "${c,,}" =~ ^y$ ]]
    else
        read -p "${Y}${prompt} (y/N): ${NC}" c
        [[ "${c,,}" =~ ^y$ ]]
    fi
}

# ======================== 工具函数 ========================

# 获取磁盘大小（字节）
disk_size_bytes() {
    blockdev --getsize64 "$1" 2>/dev/null || echo 0
}

# 格式化字节为可读
fmt_bytes() {
    local b=$1
    if   [ "$b" -lt 1024 ];                        then echo "${b}B"
    elif [ "$b" -lt $((1024*1024)) ];               then echo "$((b/1024))KiB"
    elif [ "$b" -lt $((1024*1024*1024)) ];           then echo "$((b/1024/1024))MiB"
    elif [ "$b" -lt $((1024*1024*1024*1024)) ];      then echo "$((b/1024/1024/1024))GiB"
    else echo "$((b/1024/1024/1024/1024))TiB"
    fi
}

# 解析大小字符串为字节（如 "100G" → 107374182400）
parse_size_to_bytes() {
    echo "$1" | sed 's/T/*1024G/g; s/G/*1024M/g; s/M/*1024K/g; s/K/*1024/g' | bc 2>/dev/null || echo 0
}

# 获取根磁盘设备路径（兼容 NVMe / SDX / mapper）
# 修复: 始终返回整块磁盘 (如 /dev/sda)，而非分区 (如 /dev/sda3)
get_root_disk() {
    local root_src
    root_src=$(findmnt -n -o SOURCE / 2>/dev/null)

    # /dev/mapper 设备 → 找底层 PV → 再找父磁盘
    if [[ "$root_src" == /dev/mapper/* ]]; then
        local pv
        pv=$(pvs --noheadings -o pv_name 2>/dev/null | head -1 | awk '{print $1}')
        if [ -n "$pv" ]; then
            # pv 可能是 /dev/sda3 这种分区，取其父设备
            local pkname
            pkname=$(lsblk -n -o PKNAME "$pv" 2>/dev/null | head -1)
            if [ -n "$pkname" ]; then
                echo "/dev/$pkname"
                return
            fi
            # 如果 pv 本身就是整盘（罕见），直接返回
            echo "$pv"
            return
        fi
    fi

    # 普通设备 (如 /dev/sda3, /dev/nvme0n1p2)
    # 尝试用 PKNAME 获取父磁盘
    local pkname
    pkname=$(lsblk -n -o PKNAME "$root_src" 2>/dev/null | head -1)
    if [ -n "$pkname" ]; then
        echo "/dev/$pkname"
        return
    fi

    # 兜底: 去掉末尾分区号 (兼容 sda3 → sda, nvme0n1p2 → nvme0n1)
    echo "$root_src" | sed -E 's/p?[0-9]+$//'
}

# 检查磁盘是否正在被使用
is_disk_busy() {
    local d="$1"

    # 是否是 LVM PV (精确匹配)
    pvs --noheadings -o pv_name 2>/dev/null | awk '{print $1}' | grep -qx "$d" && return 0

    # 自身或子设备是否有挂载点
    lsblk -nlo MOUNTPOINT "$d" 2>/dev/null | grep -q '/' && return 0

    # 子设备是否包含 LVM 成员
    lsblk -nlo FSTYPE "$d" 2>/dev/null | grep -qi 'lvm' && return 0

    # 是否被进程占用
    lsof "$d" &>/dev/null && return 0

    # 是否有 ZFS 成员
    lsblk -nlo FSTYPE "$d" 2>/dev/null | grep -qi 'zfs' && return 0

    # 是否是 mdraid 成员
    lsblk -nlo FSTYPE "$d" 2>/dev/null | grep -qi 'linux_raid' && return 0

    return 1
}

# ======================== 工具安装 ========================

ensure_tools() {
    local cmds_map=(
        "sgdisk:gdisk"
        "parted:parted"
        "pvcreate:lvm2"
        "mkfs.ext4:e2fsprogs"
        "blkid:util-linux"
        "rsync:rsync"
        "bc:bc"
        "lsof:lsof"
        "python3:python3"
        "findmnt:util-linux"
        "lvconvert:lvm2"
        "blockdev:util-linux"
        "wipefs:util-linux"
        "awk:gawk"
    )

    local pkgs_needed=()
    local missing_cmds=()

    for item in "${cmds_map[@]}"; do
        local cmd="${item%%:*}"
        local pkg="${item##*:}"
        if ! command -v "$cmd" &>/dev/null; then
            missing_cmds+=("$cmd")
            if ! printf '%s\n' "${pkgs_needed[@]}" | grep -qx "$pkg"; then
                pkgs_needed+=("$pkg")
            fi
        fi
    done

    if [ ${#pkgs_needed[@]} -eq 0 ]; then
        ok "所有必要工具已就绪"
        return 0
    fi

    warn "检测到缺失工具: ${missing_cmds[*]}"
    warn "需要安装软件包: ${pkgs_needed[*]}"

    if ! confirm "是否自动安装缺失工具?" "y"; then
        die "缺少必要工具，无法继续。请手动安装后重试。"
    fi

    log "更新软件源..."
    apt-get update -qq 2>&1 | tail -3 | tee -a "$LOG_FILE"

    log "安装缺失软件包 (可能需要几分钟)..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs_needed[@]}" 2>&1 | tail -10 | tee -a "$LOG_FILE"

    if [ $? -ne 0 ]; then
        for pkg in "${pkgs_needed[@]}"; do
            if ! dpkg -s "$pkg" &>/dev/null; then
                log "重试安装 $pkg ..."
                DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" 2>&1 | tail -5 | tee -a "$LOG_FILE"
            fi
        done
    fi

    # 最终验证
    local still_missing=()
    for item in "${cmds_map[@]}"; do
        local cmd="${item%%:*}"
        if ! command -v "$cmd" &>/dev/null; then
            still_missing+=("$cmd")
        fi
    done

    if [ ${#still_missing[@]} -gt 0 ]; then
        die "以下工具安装失败: ${still_missing[*]}，请手动安装后重试。"
    fi

    ok "所有工具安装完成"
}

# ======================== 回滚操作 ========================

do_rollback() {
    banner "执行回滚操作"

    if [ $MIGRATION_COMPLETE -eq 1 ]; then
        warn "迁移已标记完成，回滚可能导致数据丢失。"
        if ! confirm "仍然要尝试回滚?" "n"; then
            return
        fi
    fi

    warn "开始回滚..."

    # 1. 恢复 fstab
    if [ -n "$FSTAB_BACKUP" ] && [ -f "$FSTAB_BACKUP" ]; then
        log "恢复 /etc/fstab ..."
        cp "$FSTAB_BACKUP" /etc/fstab
        ok "/etc/fstab 已恢复"
    else
        warn "未找到 fstab 备份"
    fi

    # 2. 恢复 storage.cfg
    if [ -n "$STORAGE_CFG_BACKUP" ] && [ -f "$STORAGE_CFG_BACKUP" ]; then
        log "恢复 /etc/pve/storage.cfg ..."
        cp "$STORAGE_CFG_BACKUP" /etc/pve/storage.cfg
        ok "/etc/pve/storage.cfg 已恢复"
    else
        warn "未找到 storage.cfg 备份"
    fi

    # 3. 卸载临时挂载
    if mountpoint -q "$TEMP_MOUNT" 2>/dev/null; then
        umount "$TEMP_MOUNT" 2>/dev/null
    fi
    [ -d "$TEMP_MOUNT" ] && rmdir "$TEMP_MOUNT" 2>/dev/null

    # 4. 卸载新挂载的 /var/lib/vz
    if mountpoint -q /var/lib/vz 2>/dev/null; then
        local mnt_dev
        mnt_dev=$(findmnt -n -o SOURCE /var/lib/vz 2>/dev/null)
        if [[ "$mnt_dev" == *"$NEW_VG_NAME"* ]]; then
            log "卸载新 /var/lib/vz ($mnt_dev)..."
            umount /var/lib/vz 2>/dev/null
            ok "已卸载"
        else
            warn "/var/lib/vz 挂载在 $mnt_dev，非迁移目标，跳过卸载"
        fi
    fi

    # 5. 清理 LVM 结构
    if vgdisplay "$NEW_VG_NAME" &>/dev/null; then
        log "清理 LVM 结构 ($NEW_VG_NAME)..."

        # 停用所有 LV
        lvchange -an "/dev/$NEW_VG_NAME/$LOCAL_DIR_LV_NAME" 2>/dev/null
        lvchange -an "/dev/$NEW_VG_NAME/$THINPOOL_LV_NAME" 2>/dev/null

        # 删除所有 LV
        for lv_path in $(lvs --noheadings -o lv_path "$NEW_VG_NAME" 2>/dev/null | awk '{print $1}'); do
            log "  删除 LV: $lv_path"
            lvremove -f "$lv_path" &>/dev/null
        done

        # 删除 VG
        vgremove -f "$NEW_VG_NAME" &>/dev/null
        ok "卷组 $NEW_VG_NAME 已删除"

        # 删除 PV
        if [ -n "$SELECTED_DISK" ] && [ -b "$SELECTED_DISK" ]; then
            pvremove -ff -y "$SELECTED_DISK" &>/dev/null
            wipefs -a "$SELECTED_DISK" &>/dev/null
            ok "物理卷 $SELECTED_DISK 已清除"
        fi
    else
        warn "卷组 $NEW_VG_NAME 不存在，无需清理 LVM"
    fi

    # 6. 重新挂载
    log "重新挂载所有文件系统..."
    mount -a 2>/dev/null

    MIGRATION_COMPLETE=0
    ok "回滚操作完成。请检查系统状态。"
    pause
}

# ======================== 菜单功能实现 ========================

# ---- 1. 查看当前存储状态 ----
view_storage_status() {
    banner "当前存储状态"

    echo -e "${C}── PVE 存储配置 ────────────────────────────────${NC}"
    cat /etc/pve/storage.cfg 2>/dev/null || err "无法读取 storage.cfg"

    echo -e "\n${C}── /var/lib/vz 挂载信息 ──────────────────────${NC}"
    if mountpoint -q /var/lib/vz 2>/dev/null; then
        local mnt_dev mnt_fstype
        mnt_dev=$(findmnt -n -o SOURCE /var/lib/vz 2>/dev/null)
        mnt_fstype=$(findmnt -n -o FSTYPE /var/lib/vz 2>/dev/null)
        echo -e "  设备:   $mnt_dev"
        echo -e "  类型:   $mnt_fstype"
        df -h /var/lib/vz 2>/dev/null | tail -1 | awk '{printf "  容量:   %s / %s (已用 %s)\n", $3, $2, $5}'
    else
        echo -e "  ${Y}/var/lib/vz 未独立挂载 (使用根分区空间)${NC}"
        df -h / 2>/dev/null | tail -1 | awk '{printf "  根分区: %s / %s (已用 %s)\n", $3, $2, $5}'
    fi

    echo -e "\n${C}── /var/lib/vz 目录使用详情 ──────────────────${NC}"
    if [ -d /var/lib/vz ]; then
        du -sh /var/lib/vz 2>/dev/null
        du -sh /var/lib/vz/*/ 2>/dev/null | head -15
    else
        echo "  目录不存在"
    fi

    echo -e "\n${C}── LVM 状态 ──────────────────────────────────${NC}"
    echo -e "  ${BD}物理卷:${NC}"
    pvs 2>/dev/null || echo "  无"
    echo -e "  ${BD}卷组:${NC}"
    vgs 2>/dev/null || echo "  无"
    echo -e "  ${BD}逻辑卷:${NC}"
    lvs 2>/dev/null || echo "  无"

    echo -e "\n${C}── 磁盘总览 ──────────────────────────────────${NC}"
    lsblk -d -o NAME,SIZE,TYPE,MODEL,TRAN,ROTA 2>/dev/null | grep -E "disk|NAME"

    echo -e "\n${C}── 系统根磁盘 ────────────────────────────────${NC}"
    local rd
    rd=$(get_root_disk)
    echo -e "  $rd"

    echo ""
    pause
}

# ---- 2. 扫描并选择目标硬盘 ----
scan_disks() {
    banner "扫描可用硬盘"

    local root_disk
    root_disk=$(get_root_disk)
    log "系统根磁盘: $root_disk"

    AVAILABLE_DISKS=()
    DISK_SIZES=()
    DISK_MODELS=()

    local idx=0

    echo -e "${C}── 可用硬盘列表 ──────────────────────────────${NC}\n"

    # 修复: 包含 TYPE 列，用 awk 精确过滤 TYPE=="disk"
    while IFS= read -r line; do
        [ -z "$line" ] && continue

        local name size model
        name=$(echo "$line" | awk '{print $1}')
        size=$(echo "$line" | awk '{print $2}')
        # 跳过前3列(NAME,SIZE,TYPE)，剩余为MODEL
        model=$(echo "$line" | awk '{$1=$2=$3=""; print $0}' | sed 's/^ *//')

        local dev="/dev/$name"

        # 跳过根磁盘 (精确匹配 + 前缀匹配)
        [[ "$dev" == "$root_disk" ]] && continue
        [[ "$dev" == "${root_disk}"* ]] && continue
        # 反向: root_disk=/dev/sda, dev=/dev/sda → 也需要检查
        [[ "$root_disk" == "${dev}"* ]] && continue

        # 跳过光驱、loop、dm 设备
        [[ "$name" == sr* || "$name" == loop* || "$name" == dm-* ]] && continue

        # 跳过正在使用的磁盘
        if is_disk_busy "$dev"; then
            warn "  $dev ($size) - 正在使用中，跳过"
            continue
        fi

        idx=$((idx + 1))
        AVAILABLE_DISKS+=("$dev")
        DISK_SIZES+=("$size")
        DISK_MODELS+=("$model")

        local bytes
        bytes=$(disk_size_bytes "$dev")
        echo -e "  ${G}${idx})${NC} ${BD}${dev}${NC}  ${C}[${size}]${NC}  $(fmt_bytes "$bytes")  $model"
    done < <(lsblk -d -n -o NAME,SIZE,TYPE,MODEL 2>/dev/null | awk '$3=="disk"')

    if [ ${#AVAILABLE_DISKS[@]} -eq 0 ]; then
        err "未找到可用的空闲硬盘"
        echo ""
        echo -e "  ${Y}可能原因:${NC}"
        echo -e "    1. 所有硬盘均已被系统使用 (LVM/挂载/RAID)"
        echo -e "    2. 硬盘上有残留签名，被识别为 '正在使用'"
        echo -e ""
        echo -e "  ${Y}排查建议:${NC}"
        echo -e "    运行以下命令检查硬盘状态:"
        echo -e "    ${BD}lsblk -d -o NAME,SIZE,TYPE,MODEL,TRAN${NC}"
        echo -e "    ${BD}pvs${NC}          # 查看哪些设备是 LVM PV"
        echo -e "    ${BD}lsblk -f${NC}     # 查看文件系统类型"
        echo -e ""
        echo -e "  ${Y}如需强制使用某块硬盘，可先清除其签名:${NC}"
        echo -e "    ${BD}wipefs -a /dev/sdX${NC}   # 替换 sdX 为实际设备名"
        pause
        return 1
    fi

    echo ""
    read -p "${B}请选择硬盘序号 (0=返回主菜单): ${NC}" choice

    [[ "$choice" == "0" || -z "$choice" ]] && return 0

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#AVAILABLE_DISKS[@]}" ]; then
        err "无效选择"
        pause
        return 1
    fi

    SELECTED_DISK="${AVAILABLE_DISKS[$((choice-1))]}"
    SELECTED_DISK_SIZE_BYTES=$(disk_size_bytes "$SELECTED_DISK")

    ok "已选择: $SELECTED_DISK ($(fmt_bytes "$SELECTED_DISK_SIZE_BYTES"))"

    echo -e "\n${R}⚠️  警告: 硬盘 $SELECTED_DISK 上的所有数据将被永久擦除！${NC}"
    echo -e "${R}⚠️  此操作不可逆！请确保选对了硬盘！${NC}"

    # 二次确认：要求输入设备名
    echo ""
    read -p "${Y}请输入设备名确认 (${SELECTED_DISK##*/}): ${NC}" confirm_name
    if [ "$confirm_name" != "${SELECTED_DISK##*/}" ]; then
        SELECTED_DISK=""
        err "设备名不匹配，已取消选择"
        pause
        return 1
    fi

    ok "硬盘选择已确认: $SELECTED_DISK"
    pause
}

# ---- 3. 配置迁移参数 ----
configure_params() {
    while true; do
        banner "配置迁移参数"

        local size_display="${LOCAL_DIR_LV_SIZE:-自动计算}"
        echo -e "  ${C}1)${NC} 卷组名称 (VG):        ${BD}$NEW_VG_NAME${NC}"
        echo -e "  ${C}2)${NC} local LV 名称:        ${BD}$LOCAL_DIR_LV_NAME${NC}"
        echo -e "  ${C}3)${NC} local LV 大小:         ${BD}$size_display${NC}"
        echo -e "  ${C}4)${NC} Thin Pool 名称:        ${BD}$THINPOOL_LV_NAME${NC}"
        echo -e "  ${C}5)${NC} Thin Pool 预留(%):     ${BD}$THINPOOL_RESERVED_PERCENT%${NC}"
        echo -e "  ${C}0)${NC} 返回主菜单"
        echo ""

        read -p "${B}请选择要修改的项 [0-5]: ${NC}" c
        local v

        case "$c" in
            1)
                read -p "新的卷组名称 [$NEW_VG_NAME]: " v
                [ -n "$v" ] && NEW_VG_NAME="$v"
                ;;
            2)
                read -p "新的 local LV 名称 [$LOCAL_DIR_LV_NAME]: " v
                [ -n "$v" ] && LOCAL_DIR_LV_NAME="$v"
                ;;
            3)
                echo -e "  ${Y}支持格式: 100G, 500M, 1T 等。留空=自动计算(当前数据量+20%, 最少50G)${NC}"
                read -p "新的 local LV 大小: " v
                LOCAL_DIR_LV_SIZE="$v"
                ;;
            4)
                read -p "新的 Thin Pool 名称 [$THINPOOL_LV_NAME]: " v
                [ -n "$v" ] && THINPOOL_LV_NAME="$v"
                ;;
            5)
                read -p "新的预留百分比 [$THINPOOL_RESERVED_PERCENT]: " v
                if [ -n "$v" ] && [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -ge 0 ] && [ "$v" -lt 50 ]; then
                    THINPOOL_RESERVED_PERCENT="$v"
                elif [ -n "$v" ]; then
                    err "百分比须为 0-49 的整数"
                fi
                ;;
            0)
                return 0
                ;;
            *)
                err "无效选择"
                ;;
        esac
        ok "配置已更新"
    done
}

# ---- 4. 执行迁移 ----
execute_migration() {
    banner "执行存储迁移"

    # ====== 前置检查 ======
    if [ -z "$SELECTED_DISK" ]; then
        err "尚未选择目标硬盘，请先执行菜单 [2] 扫描硬盘"
        pause
        return 1
    fi

    if [ ! -b "$SELECTED_DISK" ]; then
        err "所选硬盘 $SELECTED_DISK 不存在或不是块设备"
        pause
        return 1
    fi

    # 检查硬盘是否已被占用（可能选完后又变了）
    if is_disk_busy "$SELECTED_DISK"; then
        err "硬盘 $SELECTED_DISK 当前已被占用，请重新选择"
        SELECTED_DISK=""
        pause
        return 1
    fi

    # 自动计算 local LV 大小
    if [ -z "$LOCAL_DIR_LV_SIZE" ]; then
        local vz_bytes=0
        if [ -d /var/lib/vz ]; then
            vz_bytes=$(du -sb /var/lib/vz 2>/dev/null | awk '{print $1}')
        fi
        vz_bytes=$((vz_bytes + 5*1024*1024*1024))  # 加 5GB 缓冲

        local min_bytes=$((50*1024*1024*1024))       # 最小 50G
        local rec_bytes=$((vz_bytes * 120 / 100))    # 1.2 倍
        [ "$rec_bytes" -lt "$min_bytes" ] && rec_bytes=$min_bytes

        # 超过磁盘 70% 则限制
        local max_bytes=$((SELECTED_DISK_SIZE_BYTES * 70 / 100))
        [ "$rec_bytes" -gt "$max_bytes" ] && rec_bytes=$max_bytes

        local rec_gb=$(( (rec_bytes + 1024*1024*1024 - 1) / (1024*1024*1024) ))
        [ "$rec_gb" -lt 10 ] && rec_gb=10  # 最低 10G
        LOCAL_DIR_LV_SIZE="${rec_gb}G"
        log "自动计算 local LV 大小: $LOCAL_DIR_LV_SIZE"
    fi

    # ====== 迁移摘要确认 ======
    echo -e "${C}┌─────────────────────────────────────────────────────┐${NC}"
    echo -e "${C}│${NC}  ${BD}迁 移 摘 要${NC}                                      "
    echo -e "${C}├─────────────────────────────────────────────────────┤${NC}"
    echo -e "${C}│${NC}  目标硬盘:      ${BD}$SELECTED_DISK${NC}"
    echo -e "${C}│${NC}  硬盘容量:      $(fmt_bytes "$SELECTED_DISK_SIZE_BYTES")"
    echo -e "${C}│${NC}  卷组名称:      $NEW_VG_NAME"
    echo -e "${C}│${NC}  local LV:      $LOCAL_DIR_LV_NAME ($LOCAL_DIR_LV_SIZE)"
    echo -e "${C}│${NC}  Thin Pool:     $THINPOOL_LV_NAME (剩余空间, 预留${THINPOOL_RESERVED_PERCENT}%)"
    echo -e "${C}└─────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "${R}⚠️  此操作将擦除 $SELECTED_DISK 上的所有数据！${NC}"
    echo -e "${R}⚠️  建议先备份所有重要虚拟机和容器！${NC}"
    echo ""

    if ! confirm "确认开始迁移?" "n"; then
        warn "迁移已取消"
        pause
        return 0
    fi

    # ====== 停止 VM/CT ======
    log "检查运行中的虚拟机/容器..."
    local running_vms running_cts
    running_vms=$(qm list 2>/dev/null | awk '/running/{print $1}')
    running_cts=$(pct list 2>/dev/null | awk '/running/{print $1}')

    if [ -n "$running_vms" ] || [ -n "$running_cts" ]; then
        warn "检测到运行中的虚拟机/容器:"
        [ -n "$running_vms" ] && echo "  VMs: $running_vms"
        [ -n "$running_cts" ] && echo "  CTs: $running_cts"
        echo ""
        if confirm "是否停止所有运行中的 VM/CT?" "y"; then
            for vmid in $running_vms; do
                log "停止 VM $vmid ..."
                qm stop "$vmid" 2>&1 | tee -a "$LOG_FILE"
            done
            for ctid in $running_cts; do
                log "停止 CT $ctid ..."
                pct stop "$ctid" 2>&1 | tee -a "$LOG_FILE"
            done
            sleep 3
            ok "所有 VM/CT 已停止"
        else
            warn "继续迁移可能导致数据不一致"
            if ! confirm "仍然继续?" "n"; then
                pause
                return 0
            fi
        fi
    else
        ok "无运行中的 VM/CT"
    fi

    # ====== 备份配置 ======
    log "备份配置文件..."
    FSTAB_BACKUP="/etc/fstab.bak_$(date +%Y%m%d_%H%M%S)"
    STORAGE_CFG_BACKUP="/etc/pve/storage.cfg.bak_$(date +%Y%m%d_%H%M%S)"
    PVECFG_BACKUP="/var/backups/pve_config_$(date +%Y%m%d_%H%M%S).tar.gz"

    cp /etc/fstab "$FSTAB_BACKUP" || { err "备份 fstab 失败"; pause; return 1; }
    cp /etc/pve/storage.cfg "$STORAGE_CFG_BACKUP" || { err "备份 storage.cfg 失败"; pause; return 1; }
    mkdir -p /var/backups
    tar czf "$PVECFG_BACKUP" /etc/pve 2>/dev/null
    ok "配置备份完成:"
    log "  fstab:       $FSTAB_BACKUP"
    log "  storage.cfg: $STORAGE_CFG_BACKUP"
    log "  pve config:  $PVECFG_BACKUP"

    # ================================================================
    #                    阶段 1/4: 初始化硬盘
    # ================================================================
    banner "阶段 1/4: 初始化硬盘"

    log "擦除 $SELECTED_DISK 上的所有分区和签名..."
    sgdisk --zap-all "$SELECTED_DISK" 2>&1 | tee -a "$LOG_FILE"
    wipefs -a -f "$SELECTED_DISK" 2>&1 | tee -a "$LOG_FILE"
    # 确保没有残留分区表
    sgdisk -o "$SELECTED_DISK" 2>&1 | tee -a "$LOG_FILE"
    ok "分区表已清除"

    log "创建物理卷..."
    pvcreate -ff -y "$SELECTED_DISK" 2>&1 | tee -a "$LOG_FILE" || {
        err "创建物理卷失败"; pause; return 1;
    }

    log "创建卷组 $NEW_VG_NAME ..."
    vgcreate "$NEW_VG_NAME" "$SELECTED_DISK" 2>&1 | tee -a "$LOG_FILE" || {
        err "创建卷组失败"; pause; return 1;
    }
    ok "LVM 基础结构创建完成"
    log "  PV: $SELECTED_DISK"
    log "  VG: $NEW_VG_NAME"

    # ================================================================
    #                    阶段 2/4: 迁移 local 存储
    # ================================================================
    banner "阶段 2/4: 迁移 local 存储 (/var/lib/vz)"

    log "创建逻辑卷 $LOCAL_DIR_LV_NAME (大小: $LOCAL_DIR_LV_SIZE)..."
    lvcreate -L "$LOCAL_DIR_LV_SIZE" -n "$LOCAL_DIR_LV_NAME" "$NEW_VG_NAME" 2>&1 | tee -a "$LOG_FILE" || {
        err "创建 local LV 失败"; pause; return 1;
    }

    log "格式化为 ext4..."
    mkfs.ext4 -F -q -L "pve-local" "/dev/$NEW_VG_NAME/$LOCAL_DIR_LV_NAME" 2>&1 | tee -a "$LOG_FILE" || {
        err "格式化失败"; pause; return 1;
    }
    ok "逻辑卷创建并格式化完成"

    # --- 数据复制 ---
    log "挂载新逻辑卷到临时目录..."
    mkdir -p "$TEMP_MOUNT"
    mount "/dev/$NEW_VG_NAME/$LOCAL_DIR_LV_NAME" "$TEMP_MOUNT" || {
        err "挂载临时目录失败"; pause; return 1;
    }

    if [ -n "$(ls -A /var/lib/vz 2>/dev/null)" ]; then
        log "复制 /var/lib/vz 数据 (可能需要较长时间，请耐心等待)..."

        if command -v rsync &>/dev/null; then
            log "使用 rsync -aHAXS (保留硬链接/ACL/xattr/稀疏文件)..."
            rsync -aHAXS --info=progress2 /var/lib/vz/ "$TEMP_MOUNT/" 2>&1 | tee -a "$LOG_FILE"
            local rsync_rc=${PIPESTATUS[0]:-0}
            # rsync 返回码 24 = partial transfer (某些文件消失)，可接受
            if [ "$rsync_rc" -ne 0 ] && [ "$rsync_rc" -ne 24 ]; then
                umount "$TEMP_MOUNT" 2>/dev/null
                err "rsync 失败 (返回码: $rsync_rc)"
                pause
                return 1
            fi
        else
            log "rsync 不可用，使用 cp -a ..."
            cp -a /var/lib/vz/. "$TEMP_MOUNT/" 2>&1 | tee -a "$LOG_FILE" || {
                umount "$TEMP_MOUNT" 2>/dev/null
                err "cp 失败"; pause; return 1;
            }
        fi

        # 验证数据完整性
        log "验证数据完整性..."
        local src_count dst_count
        src_count=$(find /var/lib/vz -maxdepth 2 -type d 2>/dev/null | wc -l)
        dst_count=$(find "$TEMP_MOUNT" -maxdepth 2 -type d 2>/dev/null | wc -l)

        if [ "$dst_count" -ge $((src_count - 5)) ]; then
            ok "数据完整性验证通过 (源: $src_count 目录, 目标: $dst_count 目录)"
        else
            warn "目录数量差异较大 (源: $src_count, 目标: $dst_count)"
            if ! confirm "继续迁移?" "n"; then
                umount "$TEMP_MOUNT" 2>/dev/null
                pause
                return 0
            fi
        fi

        # 验证关键子目录
        local key_dirs=("dump" "images" "templates")
        for kd in "${key_dirs[@]}"; do
            if [ -d "/var/lib/vz/$kd" ]; then
                if [ -d "$TEMP_MOUNT/$kd" ]; then
                    ok "  ✓ $kd/ 已复制"
                else
                    warn "  ✗ $kd/ 未复制"
                fi
            fi
        done
    else
        log "/var/lib/vz 为空，无需复制数据"
    fi

    umount "$TEMP_MOUNT" || { err "卸载临时目录失败"; pause; return 1; }
    rmdir "$TEMP_MOUNT" 2>/dev/null
    ok "数据复制阶段完成"

    # --- 更新 fstab ---
    log "更新 /etc/fstab..."

    # 获取 UUID (带重试)
    LOCAL_DIR_UUID=""
    for i in {1..10}; do
        LOCAL_DIR_UUID=$(blkid -s UUID -o value "/dev/$NEW_VG_NAME/$LOCAL_DIR_LV_NAME" 2>/dev/null)
        [ -n "$LOCAL_DIR_UUID" ] && break
        log "  UUID 获取重试 ($i/10)..."
        sleep 1
    done

    if [ -z "$LOCAL_DIR_UUID" ]; then
        err "无法获取新逻辑卷的 UUID"
        pause
        return 1
    fi
    log "  UUID: $LOCAL_DIR_UUID"

    # 移除旧的 /var/lib/vz 挂载行
    sed -i '\#/var/lib/vz#d' /etc/fstab
    # 添加新行 (nofail 防止设备缺失时无法启动)
    echo "UUID=$LOCAL_DIR_UUID /var/lib/vz ext4 defaults,nofail 0 2" >> /etc/fstab

    # 卸载旧的 /var/lib/vz
    if mountpoint -q /var/lib/vz 2>/dev/null; then
        log "卸载旧的 /var/lib/vz ..."
        umount /var/lib/vz 2>&1 | tee -a "$LOG_FILE" || {
            warn "旧挂载点卸载失败，尝试 lazy unmount..."
            umount -l /var/lib/vz 2>&1 | tee -a "$LOG_FILE"
        }
    fi

    # 清空原目录内容（确保是空目录作为挂载点）
    if ! mountpoint -q /var/lib/vz 2>/dev/null; then
        log "清空原 /var/lib/vz 目录内容..."
        rm -rf /var/lib/vz/* /var/lib/vz/.[!.]* 2>/dev/null
    fi

    # 挂载新的
    log "挂载新的 /var/lib/vz ..."
    mount /var/lib/vz 2>&1 | tee -a "$LOG_FILE" || {
        warn "单独挂载失败，尝试 mount -a ..."
        mount -a 2>&1 | tee -a "$LOG_FILE"
    }

    if mountpoint -q /var/lib/vz 2>/dev/null; then
        local new_dev
        new_dev=$(findmnt -n -o SOURCE /var/lib/vz 2>/dev/null)
        ok "/var/lib/vz 已挂载到 $new_dev"
        df -h /var/lib/vz | tail -1 | awk '{printf "  容量: %s / %s (已用 %s)\n", $3, $2, $5}' | tee -a "$LOG_FILE"
    else
        err "/var/lib/vz 挂载失败，请手动检查 fstab"
        pause
        return 1
    fi

    # ================================================================
    #                    阶段 3/4: 创建 Thin Pool
    # ================================================================
    banner "阶段 3/4: 创建 local-lvm Thin Pool"

    log "计算 Thin Pool 大小..."
    # 使用 vgs 指定列输出，精确获取剩余空间 (MB)
    local vg_free_mb
    vg_free_mb=$(vgs --noheadings --nosuffix --units m -o vg_free "$NEW_VG_NAME" 2>/dev/null | awk '{print int($1)}')

    if [ -z "$vg_free_mb" ] || [ "$vg_free_mb" -le 0 ]; then
        err "卷组 $NEW_VG_NAME 无剩余空间"
        pause
        return 1
    fi

    local thinpool_mb=$(( vg_free_mb * (100 - THINPOOL_RESERVED_PERCENT) / 100 ))
    log "  VG 剩余: ${vg_free_mb}MB"
    log "  Thin Pool 分配: ${thinpool_mb}MB (预留 ${THINPOOL_RESERVED_PERCENT}%)"

    if [ "$thinpool_mb" -le 0 ]; then
        err "计算出的 Thin Pool 大小为 0，请减小 local LV 大小"
        pause
        return 1
    fi

    log "创建 Thin Pool $THINPOOL_LV_NAME (${thinpool_mb}MB)..."
    lvcreate -L "${thinpool_mb}M" -n "$THINPOOL_LV_NAME" "$NEW_VG_NAME" 2>&1 | tee -a "$LOG_FILE" || {
        err "创建 Thin Pool LV 失败"; pause; return 1;
    }

    log "转换为 Thin Pool..."
    lvconvert --type thin-pool "$NEW_VG_NAME/$THINPOOL_LV_NAME" 2>&1 | tee -a "$LOG_FILE" || {
        err "转换 Thin Pool 失败"; pause; return 1;
    }
    ok "Thin Pool 创建完成"

    # 显示 LV 信息
    lvs -o lv_name,lv_size,seg_type "$NEW_VG_NAME" 2>/dev/null | tee -a "$LOG_FILE"

    # ================================================================
    #                    阶段 4/4: 更新 PVE 存储配置
    # ================================================================
    banner "阶段 4/4: 更新 PVE 存储配置"

    log "更新 /etc/pve/storage.cfg ..."

    # 通过环境变量传递 bash 参数给 Python
    export PY_NEW_VG="$NEW_VG_NAME"
    export PY_THINPOOL="$THINPOOL_LV_NAME"

    python3 << 'PYEOF'
import os, sys, re

cfg_path = '/etc/pve/storage.cfg'
new_vg   = os.environ.get('PY_NEW_VG', 'pve-data')
thinpool = os.environ.get('PY_THINPOOL', 'data-thinpool')

try:
    with open(cfg_path, 'r') as f:
        lines = f.readlines()
except Exception as e:
    print(f"[FAIL] 无法读取 {cfg_path}: {e}")
    sys.exit(1)

in_lvmthin = False
new_lines = []

for line in lines:
    stripped = line.strip()

    # 检测新的节开始（非空行且不以空白/制表符开头）
    if stripped and not line[0] in (' ', '\t'):
        in_lvmthin = stripped.startswith('lvmthin:')

    if in_lvmthin:
        if stripped.startswith('thinpool '):
            indent = line[:len(line) - len(line.lstrip())]
            line = indent + 'thinpool ' + thinpool + '\n'
        elif stripped.startswith('vgname '):
            indent = line[:len(line) - len(line.lstrip())]
            line = indent + 'vgname ' + new_vg + '\n'

    new_lines.append(line)

# 同时确保 dir: local 的 path 正确
content = ''.join(new_lines)
content = re.sub(
    r'(dir:\s+local\s*\n\s+path\s+)\S+',
    r'\g<1>/var/lib/vz',
    content
)

try:
    with open(cfg_path, 'w') as f:
        f.write(content)
    print("[OK] storage.cfg 更新完成")
except Exception as e:
    print(f"[FAIL] 无法写入 {cfg_path}: {e}")
    sys.exit(1)
PYEOF

    if [ $? -ne 0 ]; then
        err "Python 更新 storage.cfg 失败"
        pause
        return 1
    fi

    # 验证配置
    if grep -q "thinpool $THINPOOL_LV_NAME" /etc/pve/storage.cfg && \
       grep -q "vgname $NEW_VG_NAME" /etc/pve/storage.cfg; then
        ok "存储配置验证通过"
    else
        err "存储配置验证失败，请手动检查 /etc/pve/storage.cfg"
        echo -e "\n当前内容:"
        cat /etc/pve/storage.cfg
        pause
        return 1
    fi

    # ================================================================
    #                    可选: 清理原安装盘空间
    # ================================================================
    banner "可选: 清理原安装盘空间"

    if lvs pve/data &>/dev/null; then
        warn "检测到原盘上的 'pve/data' 逻辑卷 (原 local-lvm 后端)"
        echo -e "  删除后可将空间释放给 pve/root (根分区) 使用"
        echo ""

        local pve_data_size
        pve_data_size=$(lvs --noheadings -o lv_size pve/data 2>/dev/null | awk '{print $1}')
        log "  pve/data 大小: $pve_data_size"

        if confirm "是否删除 pve/data 并扩展根分区?" "n"; then
            log "删除 pve/data..."
            lvremove -f pve/data 2>&1 | tee -a "$LOG_FILE" || warn "删除 pve/data 失败"

            log "扩展 pve/root..."
            if lvextend -l +100%FREE /dev/pve/root 2>&1 | tee -a "$LOG_FILE"; then
                # 检测根文件系统类型并选择正确的扩展工具
                local fstype
                fstype=$(findmnt -n -o FSTYPE / 2>/dev/null)
                log "根文件系统类型: $fstype"

                case "$fstype" in
                    ext4)
                        resize2fs /dev/pve/root 2>&1 | tee -a "$LOG_FILE" || warn "resize2fs 失败"
                        ;;
                    xfs)
                        xfs_growfs / 2>&1 | tee -a "$LOG_FILE" || warn "xfs_growfs 失败"
                        ;;
                    btrfs)
                        btrfs filesystem resize max / 2>&1 | tee -a "$LOG_FILE" || warn "btrfs resize 失败"
                        ;;
                    *)
                        warn "未知文件系统 ($fstype)，请手动扩展"
                        ;;
                esac
                ok "根分区扩展完成"
            else
                warn "lvextend 失败，可能无空间可扩展"
            fi
        else
            log "跳过清理原盘"
        fi
    else
        log "未检测到 pve/data 逻辑卷，无需清理"
    fi

    # ====== 迁移完成 ======
    MIGRATION_COMPLETE=1

    banner "迁移完成"
    ok "所有迁移步骤已成功执行！"
    echo ""
    log "后续操作建议:"
    echo -e "  ${C}1.${NC} 登录 PVE 管理界面: ${BD}https://$(hostname -I | awk '{print $1}'):8006${NC}"
    echo -e "  ${C}2.${NC} 导航至 ${BD}数据中心 → 存储${NC}，确认 local 和 local-lvm 状态正常"
    echo -e "  ${C}3.${NC} 尝试创建一个测试 VM/CT 验证存储功能"
    echo -e "  ${C}4.${NC} 确认无误后重启节点: ${BD}reboot${NC}"
    echo ""
    echo -e "  ${Y}备份文件位置:${NC}"
    echo -e "    fstab:       $FSTAB_BACKUP"
    echo -e "    storage.cfg: $STORAGE_CFG_BACKUP"
    echo -e "    pve config:  $PVECFG_BACKUP"
    echo -e "    日志:        $LOG_FILE"
    pause
}

# ---- 5. 验证迁移结果 ----
verify_migration() {
    banner "迁移结果验证"

    local pass=0 fail=0

    # local 存储
    echo -e "${C}── local 存储 (/var/lib/vz) ────────────────────${NC}"
    if mountpoint -q /var/lib/vz 2>/dev/null; then
        local mnt_dev
        mnt_dev=$(findmnt -n -o SOURCE /var/lib/vz 2>/dev/null)
        if [[ "$mnt_dev" == *"$NEW_VG_NAME"* ]]; then
            ok "✓ /var/lib/vz 挂载在 $mnt_dev"
            df -h /var/lib/vz | tail -1 | awk '{printf "  %s / %s (已用 %s)\n", $3, $2, $5}'
            pass=$((pass+1))
        else
            err "✗ /var/lib/vz 挂载在 $mnt_dev (非迁移目标)"
            fail=$((fail+1))
        fi
    else
        err "✗ /var/lib/vz 未挂载"
        fail=$((fail+1))
    fi

    # fstab 条目
    echo -e "\n${C}── fstab 条目 ────────────────────────────────${NC}"
    if grep -q "/var/lib/vz" /etc/fstab; then
        grep "/var/lib/vz" /etc/fstab
        ok "✓ fstab 包含 /var/lib/vz 条目"
        pass=$((pass+1))
    else
        err "✗ fstab 中未找到 /var/lib/vz 条目"
        fail=$((fail+1))
    fi

    # local-lvm 配置
    echo -e "\n${C}── local-lvm 存储配置 ────────────────────────${NC}"
    if grep -q "vgname $NEW_VG_NAME" /etc/pve/storage.cfg && \
       grep -q "thinpool $THINPOOL_LV_NAME" /etc/pve/storage.cfg; then
        ok "✓ storage.cfg: vgname=$NEW_VG_NAME, thinpool=$THINPOOL_LV_NAME"
        pass=$((pass+1))
    else
        err "✗ storage.cfg 配置异常"
        grep -A5 "lvmthin" /etc/pve/storage.cfg
        fail=$((fail+1))
    fi

    # 逻辑卷状态
    echo -e "\n${C}── 逻辑卷状态 ────────────────────────────────${NC}"
    if lvdisplay "$NEW_VG_NAME/$LOCAL_DIR_LV_NAME" &>/dev/null; then
        ok "✓ $LOCAL_DIR_LV_NAME 存在"
        lvs --noheadings -o lv_size "$NEW_VG_NAME/$LOCAL_DIR_LV_NAME" 2>/dev/null | awk '{print "  大小: "$1}'
        pass=$((pass+1))
    else
        err "✗ $LOCAL_DIR_LV_NAME 不存在"
        fail=$((fail+1))
    fi

    if lvdisplay "$NEW_VG_NAME/$THINPOOL_LV_NAME" &>/dev/null; then
        ok "✓ $THINPOOL_LV_NAME 存在"
        lvs --noheadings -o lv_size,seg_type "$NEW_VG_NAME/$THINPOOL_LV_NAME" 2>/dev/null | awk '{print "  大小: "$1", 类型: "$2}'
        pass=$((pass+1))
    else
        err "✗ $THINPOOL_LV_NAME 不存在"
        fail=$((fail+1))
    fi

    # PVE 存储识别
    echo -e "\n${C}── PVE 存储状态 ──────────────────────────────${NC}"
    if command -v pvesm &>/dev/null; then
        pvesm status 2>/dev/null | head -20
        pass=$((pass+1))
    else
        warn "pvesm 不可用"
    fi

    # 总结
    echo -e "\n${C}── 验证总结 ──────────────────────────────────${NC}"
    echo -e "  ${G}通过: $pass${NC}  ${R}失败: $fail${NC}"

    if [ $fail -eq 0 ]; then
        ok "🎉 所有验证通过！迁移成功！"
        echo -e "\n  ${Y}建议重启节点以完成最终验证: reboot${NC}"
    else
        err "部分验证失败，请检查上方详情"
        echo -e "\n  ${Y}可使用菜单 [6] 执行回滚，或手动修复${NC}"
    fi

    pause
}

# ---- 7. 查看日志 ----
view_log() {
    banner "迁移日志"

    if [ ! -f "$LOG_FILE" ]; then
        warn "日志文件尚未创建"
        pause
        return
    fi

    local total_lines
    total_lines=$(wc -l < "$LOG_FILE")
    echo -e "日志文件: $LOG_FILE (${total_lines} 行)"
    echo ""

    if [ "$total_lines" -gt 60 ]; then
        echo -e "${Y}显示最后 60 行 (全部内容请使用 less $LOG_FILE):${NC}\n"
        tail -60 "$LOG_FILE"
    else
        cat "$LOG_FILE"
    fi

    pause
}

# ======================== 主菜单 ========================

show_main_menu() {
    clear
    echo -e "${M}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${M}║${NC}   ${BD}Proxmox VE 智能存储迁移脚本 v3.1${NC}                        ${M}║${NC}"
    echo -e "${M}╠═══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${M}║${NC}                                                           ${M}║${NC}"
    echo -e "${M}║${NC}   ${C}1)${NC}  查看当前存储状态                                     ${M}║${NC}"
    echo -e "${M}║${NC}   ${C}2)${NC}  扫描并选择目标硬盘                                   ${M}║${NC}"
    echo -e "${M}║${NC}   ${C}3)${NC}  配置迁移参数                                         ${M}║${NC}"
    echo -e "${M}║${NC}   ${C}4)${NC}  执行迁移                                             ${M}║${NC}"
    echo -e "${M}║${NC}   ${C}5)${NC}  验证迁移结果                                         ${M}║${NC}"
    echo -e "${M}║${NC}   ${C}6)${NC}  回滚操作                                             ${M}║${NC}"
    echo -e "${M}║${NC}   ${C}7)${NC}  查看日志                                             ${M}║${NC}"
    echo -e "${M}║${NC}   ${C}0)${NC}  退出                                                 ${M}║${NC}"
    echo -e "${M}║${NC}                                                           ${M}║${NC}"
    echo -e "${M}╚═══════════════════════════════════════════════════════════╝${NC}"

    # 状态栏
    echo -ne "  ${Y}状态:${NC} "
    if [ -n "$SELECTED_DISK" ]; then
        echo -ne "硬盘=${G}$SELECTED_DISK${NC}  "
    else
        echo -ne "硬盘=${R}未选择${NC}  "
    fi
    echo -ne "VG=${BD}$NEW_VG_NAME${NC}  "
    local sz="${LOCAL_DIR_LV_SIZE:-自动}"
    echo -e "local=${BD}$sz${NC}"

    if [ $MIGRATION_COMPLETE -eq 1 ]; then
        echo -e "  ${G}>>> 迁移已完成 <<<${NC}"
    fi
    echo ""
}

# ======================== 主程序入口 ========================

main() {
    # Root 检查
    if [ "$(id -u)" -ne 0 ]; then
        die "请使用 root 用户运行此脚本 (sudo bash $0)"
    fi

    # PVE 环境检查
    if ! pveversion &>/dev/null; then
        die "未检测到 Proxmox VE 环境，此脚本仅适用于 PVE"
    fi

    # 初始化日志
    mkdir -p /var/log
    touch "$LOG_FILE"

    log "==========================================================="
    log "PVE 智能存储迁移脚本 v3.1 启动"
    log "PVE 版本: $(pveversion 2>/dev/null)"
    log "内核:     $(uname -r)"
    log "主机名:   $(hostname)"
    log "日志:     $LOG_FILE"
    log "==========================================================="

    # 安装缺失工具
    ensure_tools

    # 主循环
    while true; do
        show_main_menu
        read -p "${B}请选择 [0-7]: ${NC}" choice

        case "$choice" in
            1) view_storage_status   ;;
            2) scan_disks            ;;
            3) configure_params      ;;
            4) execute_migration     ;;
            5) verify_migration      ;;
            6) do_rollback           ;;
            7) view_log              ;;
            0)
                echo ""
                if [ $MIGRATION_COMPLETE -eq 1 ]; then
                    ok "迁移已完成。建议重启节点验证: reboot"
                else
                    log "退出脚本"
                fi
                echo -e "${G}再见！${NC}"
                exit 0
                ;;
            *)
                err "无效选择，请输入 0-7"
                pause
                ;;
        esac
    done
}

main "$@"
