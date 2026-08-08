#!/bin/bash
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; PURPLE='\033[0;35m'; CYAN='\033[0;36m'; WHITE='\033[1;37m'; NC='\033[0m'
LOG_DIR="/var/log/disk_manager"
LOG_FILE="$LOG_DIR/manager_$(date +%Y%m%d_%H%M%S).log"
info()  { printf "${GREEN}[INFO]${NC}  %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
error() { printf "${RED}[ERROR]${NC} %s\n" "$*"; }
title() { printf "\n${CYAN}--- %s ---${NC}\n" "$*"; }
log()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }
pause() { echo ""; read -rp "按 Enter 键继续..."; }
confirm() {
    local msg="$1"
    echo -e "${YELLOW}${msg}${NC}"
    read -rp "确认操作? (yes/no): " choice
    [[ "$choice" == "yes" ]]
}
detect_env() {
    IS_OPENWRT=0
    IS_SYSTEMD=0
    PKG_MANAGER=""
    INSTALL_CMD=""
    SVC_START=""
    SVC_STOP=""
    SVC_ENABLE=""
    SVC_RESTART=""
    ARCH=$(uname -m 2>/dev/null || echo "unknown")
    KERNEL_VER=$(uname -r 2>/dev/null | cut -d. -f1-2)
    KERNEL_MAJOR=$(echo "$KERNEL_VER" | cut -d. -f1)
    KERNEL_MINOR=$(echo "$KERNEL_VER" | cut -d. -f2)
    OS_ID=""
    if [ -f /etc/openwrt_release ]; then
        IS_OPENWRT=1
        . /etc/openwrt_release 2>/dev/null
        OS_ID="openwrt"
        PKG_MANAGER="opkg"
        INSTALL_CMD="opkg update && opkg install"
        SVC_START="/etc/init.d/%s start"
        SVC_STOP="/etc/init.d/%s stop"
        SVC_ENABLE="/etc/init.d/%s enable"
        SVC_RESTART="/etc/init.d/%s restart"
        info "检测到 OpenWrt: ${DISTRIB_RELEASE} | 架构: ${ARCH} | 内核: $(uname -r)"
    elif [ -f /etc/os-release ]; then
        . /etc/os-release 2>/dev/null
        OS_ID="${ID:-unknown}"
        if command -v systemctl >/dev/null 2>&1; then
            IS_SYSTEMD=1
            SVC_START="systemctl start %s"
            SVC_STOP="systemctl stop %s"
            SVC_ENABLE="systemctl enable %s"
            SVC_RESTART="systemctl restart %s"
        fi
        if   command -v apt    >/dev/null 2>&1; then PKG_MANAGER="apt";    INSTALL_CMD="apt-get install -y"
        elif command -v dnf    >/dev/null 2>&1; then PKG_MANAGER="dnf";    INSTALL_CMD="dnf install -y"
        elif command -v yum    >/dev/null 2>&1; then PKG_MANAGER="yum";    INSTALL_CMD="yum install -y"
        elif command -v pacman >/dev/null 2>&1; then PKG_MANAGER="pacman"; INSTALL_CMD="pacman -S --noconfirm"
        elif command -v zypper >/dev/null 2>&1; then PKG_MANAGER="zypper"; INSTALL_CMD="zypper install -y"
        fi
        info "检测到系统: ${PRETTY_NAME:-$OS_ID} | 架构: ${ARCH} | 内核: $(uname -r) | 包管理: ${PKG_MANAGER:-未知}"
    else
        warn "无法识别系统类型，部分功能可能受限。"
    fi
}
kernel_ge() {
    local req_maj="$1" req_min="$2"
    [ "$KERNEL_MAJOR" -gt "$req_maj" ] && return 0
    [ "$KERNEL_MAJOR" -eq "$req_maj" ] && [ "$KERNEL_MINOR" -ge "$req_min" ] && return 0
    return 1
}
ensure_pkg() {
    local cmd="$1" opkg_pkg="$2" apt_pkg="$3" dnf_pkg="$4" pac_pkg="${5:-$3}"
    [ -n "$cmd" ] && command -v "$cmd" >/dev/null 2>&1 && return 0
    [ -z "$opkg_pkg" ] && [ -z "$apt_pkg" ] && [ -z "$dnf_pkg" ] && return 1
    warn "缺少依赖: ${cmd:-${apt_pkg}}，尝试安装..."
    if [ "$IS_OPENWRT" = "1" ]; then
        [ -n "$opkg_pkg" ] || return 1
        opkg update >/dev/null 2>&1
        opkg install "$opkg_pkg" || { error "安装 $opkg_pkg 失败"; return 1; }
    elif [ "$PKG_MANAGER" = "apt" ]; then
        apt-get install -y "$apt_pkg" || { error "安装 $apt_pkg 失败"; return 1; }
    elif [ "$PKG_MANAGER" = "dnf" ] || [ "$PKG_MANAGER" = "yum" ]; then
        $PKG_MANAGER install -y "$dnf_pkg" || { error "安装 $dnf_pkg 失败"; return 1; }
    elif [ "$PKG_MANAGER" = "pacman" ]; then
        pacman -S --noconfirm "$pac_pkg" || { error "安装 $pac_pkg 失败"; return 1; }
    elif [ "$PKG_MANAGER" = "zypper" ]; then
        zypper install -y "$apt_pkg" || { error "安装 $apt_pkg 失败"; return 1; }
    else
        error "无法自动安装 ${cmd}，请手动安装。"
        return 1
    fi
    info "${cmd:-${apt_pkg}} 安装完成。"
}
ensure_fs_support() {
    local fs="$1"
    case "$fs" in
        exfat)
            if [ "$IS_OPENWRT" = "1" ]; then
                opkg list-installed | grep -q "kmod-fs-exfat" || opkg install kmod-fs-exfat 2>/dev/null
                opkg list-installed | grep -q "kmod-fs-vfat"  || opkg install kmod-fs-vfat  2>/dev/null
            elif kernel_ge 5 4; then
                ensure_pkg "mkfs.exfat" "" "exfatprogs" "exfatprogs" "exfatprogs"
            else
                ensure_pkg "mount.exfat" "" "exfat-fuse exfat-utils" "fuse-exfat exfat-utils" "exfat-utils"
            fi
            ;;
        ntfs|ntfs3)
            if [ "$IS_OPENWRT" = "1" ]; then
                opkg list-installed | grep -q "kmod-fs-ntfs3" || opkg install kmod-fs-ntfs3 2>/dev/null || \
                opkg list-installed | grep -q "ntfs-3g"       || opkg install ntfs-3g        2>/dev/null
            else
                ensure_pkg "ntfs-3g" "" "ntfs-3g" "ntfs-3g" "ntfs-3g"
            fi
            ;;
        vfat|fat|fat32|msdos)
            if [ "$IS_OPENWRT" = "1" ]; then
                opkg list-installed | grep -q "kmod-fs-vfat"  || opkg install kmod-fs-vfat   2>/dev/null
                opkg list-installed | grep -q "kmod-nls-utf8" || opkg install kmod-nls-utf8  2>/dev/null
                opkg list-installed | grep -q "kmod-nls-cp437"|| opkg install kmod-nls-cp437 2>/dev/null
            else
                ensure_pkg "" "" "dosfstools" "dosfstools" "dosfstools"
            fi
            ;;
        btrfs)
            if [ "$IS_OPENWRT" = "1" ]; then
                opkg list-installed | grep -q "kmod-fs-btrfs" || opkg install kmod-fs-btrfs btrfs-progs 2>/dev/null
            else
                ensure_pkg "btrfs" "" "btrfs-progs" "btrfs-progs" "btrfs-progs"
            fi
            ;;
        xfs)
            if [ "$IS_OPENWRT" = "1" ]; then
                opkg list-installed | grep -q "kmod-fs-xfs" || opkg install kmod-fs-xfs 2>/dev/null
            else
                ensure_pkg "xfs_info" "" "xfsprogs" "xfsprogs" "xfsprogs"
            fi
            ;;
        f2fs)
            if [ "$IS_OPENWRT" = "1" ]; then
                opkg list-installed | grep -q "kmod-fs-f2fs" || opkg install kmod-fs-f2fs 2>/dev/null
            else
                ensure_pkg "fsck.f2fs" "" "f2fs-tools" "f2fs-tools" "f2fs-tools"
            fi
            ;;
        hfsplus|hfs+)
            if [ "$IS_OPENWRT" = "1" ]; then
                opkg list-installed | grep -q "kmod-fs-hfsplus" || opkg install kmod-fs-hfsplus 2>/dev/null
            else
                ensure_pkg "fsck.hfsplus" "" "hfsplus hfsprogs" "hfsplus-tools" "hfsplus"
            fi
            ;;
        ext2|ext3|ext4)
            if [ "$IS_OPENWRT" = "1" ]; then
                opkg list-installed | grep -q "kmod-fs-ext4" || opkg install kmod-fs-ext4 e2fsprogs 2>/dev/null
            else
                ensure_pkg "mkfs.ext4" "" "e2fsprogs" "e2fsprogs" "e2fsprogs"
            fi
            ;;
        *)
            warn "未知文件系统类型: $fs，跳过驱动安装。"
            ;;
    esac
}
get_fs_mount_opts() {
    local fs="$1"
    case "$fs" in
        vfat|fat|fat32|msdos) echo "rw,utf8,uid=0,gid=0,umask=000,nofail" ;;
        exfat)
            if kernel_ge 5 4 && [ "$IS_OPENWRT" != "1" ]; then
                echo "rw,uid=0,gid=0,umask=000,nofail"
            else
                echo "rw,utf8,uid=0,gid=0,umask=000,nofail"
            fi
            ;;
        ntfs)
            if kernel_ge 5 15 && [ "$IS_OPENWRT" != "1" ]; then
                echo "rw,uid=0,gid=0,umask=000,nofail"
            else
                echo "rw,uid=0,gid=0,umask=000,nofail,big_writes"
            fi
            ;;
        ntfs3)  echo "rw,uid=0,gid=0,umask=000,nofail" ;;
        btrfs)  echo "rw,defaults,nofail,compress=zstd" ;;
        xfs)    echo "rw,defaults,nofail,noatime" ;;
        f2fs)   echo "rw,defaults,nofail,noatime" ;;
        hfsplus|hfs+) echo "rw,defaults,nofail" ;;
        ext2|ext3|ext4) echo "rw,defaults,nofail,noatime" ;;
        *)      echo "rw,defaults,nofail" ;;
    esac
}
get_real_fstype() {
    local fs="$1"
    case "$fs" in
        ntfs)
            if kernel_ge 5 15 && [ "$IS_OPENWRT" != "1" ]; then
                echo "ntfs3"
            else
                echo "ntfs-3g"
            fi
            ;;
        fat|fat32|msdos) echo "vfat" ;;
        hfs+) echo "hfsplus" ;;
        *) echo "$fs" ;;
    esac
}
make_mount_name() {
    local label="$1" uuid="$2" fs="$3"
    local name=""
    if [ -n "$label" ] && [ "$label" != '""' ] && [ "$label" != "" ]; then
        name=$(echo "$label" | sed 's/[^A-Za-z0-9_\-]/_/g' | sed 's/__*/_/g' | sed 's/^_//;s/_$//')
    fi
    if [ -z "$name" ]; then
        name="${uuid%%-*}"
        [ -z "$name" ] && name="${fs}_disk"
    fi
    echo "$name"
}
ensure_base_deps() {
    title "检查基础依赖"
    ensure_pkg "blkid"   "util-linux"  "util-linux"     "util-linux"
    ensure_pkg "lsblk"   "lsblk"       "util-linux"     "util-linux"
    ensure_pkg "findmnt" "util-linux"  "util-linux"     "util-linux"
    ensure_pkg "parted"  "parted"      "parted"         "parted"
    ensure_pkg "wipefs"  "util-linux"  "util-linux"     "util-linux"
    if [ "$IS_OPENWRT" = "1" ]; then
        ensure_pkg "block" "block-mount" "" ""
        ensure_pkg "uci"   "uci"         "" ""
        opkg list-installed | grep -q "kmod-fs-ext4"     || opkg install kmod-fs-ext4     2>/dev/null
        opkg list-installed | grep -q "kmod-usb-storage" || opkg install kmod-usb-storage 2>/dev/null
        case "$ARCH" in
            aarch64*|x86_64) opkg list-installed | grep -q "kmod-usb3" || opkg install kmod-usb3 2>/dev/null ;;
            arm*)            opkg list-installed | grep -q "kmod-usb2" || opkg install kmod-usb2 2>/dev/null ;;
        esac
    else
        ensure_pkg "smartctl"  "" "smartmontools" "smartmontools" "smartmontools"
        ensure_pkg "hdparm"    "" "hdparm"        "hdparm"        "hdparm"
        ensure_pkg "badblocks" "" "e2fsprogs"     "e2fsprogs"     "e2fsprogs"
        ensure_pkg "mkfs.ext4" "" "e2fsprogs"     "e2fsprogs"     "e2fsprogs"
        ensure_pkg "mkfs.xfs"  "" "xfsprogs"      "xfsprogs"      "xfsprogs"
        ensure_pkg "mkfs.ntfs" "" "ntfs-3g"       "ntfs-3g"       "ntfs-3g"
        ensure_pkg "mkfs.vfat" "" "dosfstools"    "dosfstools"    "dosfstools"
    fi
    info "基础依赖检查完成。"
}
svc() {
    local action="$1" svc_name="$2" tmpl="" cmd=""
    case "$action" in
        start)   tmpl="$SVC_START"   ;;
        stop)    tmpl="$SVC_STOP"    ;;
        enable)  tmpl="$SVC_ENABLE"  ;;
        restart) tmpl="$SVC_RESTART" ;;
    esac
    cmd=$(printf "$tmpl" "$svc_name")
    eval "$cmd" 2>/dev/null
}
get_all_disks() {
    lsblk -d -n -o NAME,TYPE | awk '$2=="disk" {print $1}'
}
get_disk_info() {
    local disk="/dev/$1"
    local model size health pending reallocated uncorrectable hours temp
    model=$(smartctl -i "$disk" 2>/dev/null | grep -E "Device Model|Model Family" | head -1 | cut -d: -f2 | xargs 2>/dev/null)
    size=$(lsblk -d -n -o SIZE "$disk" 2>/dev/null)
    if smartctl -i "$disk" 2>/dev/null | grep -q "SMART support is: Enabled"; then
        health=$(smartctl -H "$disk" 2>/dev/null | grep "overall-health" | awk '{print $NF}')
        pending=$(smartctl -A "$disk" 2>/dev/null | grep "Current_Pending_Sector" | awk '{print $NF}')
        reallocated=$(smartctl -A "$disk" 2>/dev/null | grep "Reallocated_Sector_Ct" | awk '{print $NF}')
        uncorrectable=$(smartctl -A "$disk" 2>/dev/null | grep "Offline_Uncorrectable" | awk '{print $NF}')
        hours=$(smartctl -A "$disk" 2>/dev/null | grep "Power_On_Hours" | awk '{print $NF}')
        temp=$(smartctl -A "$disk" 2>/dev/null | grep "Temperature_Celsius" | awk '{print $NF}')
    else
        health="N/A"; pending="N/A"; reallocated="N/A"
        uncorrectable="N/A"; hours="N/A"; temp="N/A"
    fi
    echo "$model|$size|$health|$pending|$reallocated|$uncorrectable|$hours|$temp"
}
check_disk_mounted() {
    local disk="/dev/$1"
    mount | grep -q "^${disk}" && return 0
    lsblk -n -o MOUNTPOINT "$disk" 2>/dev/null | grep -q "/" && return 0
    return 1
}
check_disk_in_use() {
    local disk="$1"
    local root_device
    root_device=$(findmnt -n -o SOURCE / 2>/dev/null)
    if [[ -n "$root_device" ]]; then
        local root_disk
        root_disk=$(lsblk -n -o PKNAME "$root_device" 2>/dev/null)
        [[ "$disk" == "$root_disk" ]] && return 0
    fi
    pvs 2>/dev/null | grep -q "/dev/$disk" && return 0
    command -v zpool &>/dev/null && zpool status 2>/dev/null | grep -q "$disk" && return 0
    return 1
}
get_disk_status() {
    local pending="$1" reallocated="$2" health="$3"
    if [[ "$health" == "PASSED" ]] && [[ "$pending" == "0" || "$pending" == "N/A" || -z "$pending" ]]; then
        echo -e "${GREEN}健康${NC}"
    elif [[ "$pending" != "N/A" && -n "$pending" ]] && [[ "$pending" -gt 0 && "$pending" -lt 50 ]] 2>/dev/null; then
        echo -e "${YELLOW}警告${NC}"
    elif [[ "$pending" != "N/A" && -n "$pending" ]] && [[ "$pending" -ge 50 ]] 2>/dev/null; then
        echo -e "${RED}危险${NC}"
    elif [[ "$health" == "FAILED" ]]; then
        echo -e "${RED}故障${NC}"
    else
        echo -e "${BLUE}未知${NC}"
    fi
}
HOTPLUG_CONTENT='#!/bin/sh
[ "$ACTION" = "add" ] || [ "$ACTION" = "remove" ] || exit 0
[ "$DEVTYPE" = "partition" ] || exit 0
DEV_INFO=$(blkid -o export /dev/${DEVICENAME} 2>/dev/null)
[ -z "$DEV_INFO" ] && exit 0
ID_FS_UUID=$(echo "$DEV_INFO" | grep "^UUID=" | cut -d= -f2-)
ID_FS_TYPE=$(echo "$DEV_INFO" | grep "^TYPE=" | cut -d= -f2-)
ID_FS_LABEL=$(echo "$DEV_INFO" | grep "^LABEL=" | cut -d= -f2-)
[ -z "$ID_FS_UUID" ] && exit 0
MNT_BASE=$(uci get fstab.@global[0].auto_mount_base 2>/dev/null || echo "/mnt")
if [ -n "$ID_FS_LABEL" ]; then
    CLEAN_LABEL=$(echo "$ID_FS_LABEL" | sed "s/[^A-Za-z0-9_-]/_/g;s/__*/_/g;s/^_//;s/_$//")
    MOUNT_NAME="$CLEAN_LABEL"
else
    MOUNT_NAME="${ID_FS_UUID%%-*}"
fi
MOUNT_POINT="${MNT_BASE}/${MOUNT_NAME}"
DEVPATH_PARENT="${DEVPATH%/*}"
SYS_DEV="${DEVPATH_PARENT##*/}"
IS_SYS_ROOT=$(df 2>/dev/null | awk -v d="$SYS_DEV" '"'"'$1~d{print $6}'"'"')
[ "$IS_SYS_ROOT" = "/" ] && exit 0
case "$ACTION" in
    add)
        [ -d "$MOUNT_POINT" ] || mkdir -p "$MOUNT_POINT"
        case "$ID_FS_TYPE" in
            vfat) MTYPE="vfat"; MOPTS="rw,utf8,uid=0,gid=0,umask=000" ;;
            exfat) MTYPE="exfat"; MOPTS="rw,uid=0,gid=0,umask=000" ;;
            ntfs)
                if grep -q "ntfs3" /proc/filesystems 2>/dev/null; then
                    MTYPE="ntfs3"; MOPTS="rw,uid=0,gid=0,umask=000"
                elif command -v ntfs-3g >/dev/null 2>&1; then
                    MTYPE="ntfs-3g"; MOPTS="rw,uid=0,gid=0,umask=000,big_writes"
                else
                    MTYPE="ntfs"; MOPTS="rw,uid=0,gid=0,umask=000"
                fi
                ;;
            ext2|ext3|ext4) MTYPE="$ID_FS_TYPE"; MOPTS="rw,defaults,noatime" ;;
            btrfs) MTYPE="btrfs"; MOPTS="rw,defaults,compress=zstd" ;;
            xfs)   MTYPE="xfs";   MOPTS="rw,defaults,noatime" ;;
            f2fs)  MTYPE="f2fs";  MOPTS="rw,defaults,noatime" ;;
            hfsplus) MTYPE="hfsplus"; MOPTS="rw,defaults" ;;
            *) MTYPE="$ID_FS_TYPE"; MOPTS="rw,defaults" ;;
        esac
        mount -t "$MTYPE" -o "$MOPTS" "/dev/${DEVICENAME}" "$MOUNT_POINT" 2>/dev/null \
            || mount -o rw "/dev/${DEVICENAME}" "$MOUNT_POINT" 2>/dev/null
        chmod 777 "$MOUNT_POINT" 2>/dev/null
        logger -t auto-mount "已挂载 /dev/${DEVICENAME} -> $MOUNT_POINT (${ID_FS_TYPE})"
        ;;
    remove)
        umount -l "$MOUNT_POINT" 2>/dev/null
        sync
        rmdir "$MOUNT_POINT" 2>/dev/null
        logger -t auto-mount "已卸载 $MOUNT_POINT"
        ;;
esac
'
UDEV_BLOCK_CONTENT='#!/bin/bash
[ "$DEVTYPE" = "partition" ] || exit 0
DEV_INFO=$(blkid -o export "$DEVNAME" 2>/dev/null)
[ -z "$DEV_INFO" ] && exit 0
ID_FS_UUID=$(echo "$DEV_INFO" | grep "^UUID=" | cut -d= -f2-)
ID_FS_TYPE=$(echo "$DEV_INFO" | grep "^TYPE=" | cut -d= -f2-)
ID_FS_LABEL=$(echo "$DEV_INFO" | grep "^LABEL=" | cut -d= -f2-)
[ -z "$ID_FS_UUID" ] && exit 0
if [ -n "$ID_FS_LABEL" ]; then
    CLEAN_LABEL=$(echo "$ID_FS_LABEL" | sed "s/[^A-Za-z0-9_-]/_/g;s/__*/_/g;s/^_//;s/_$//")
    MOUNT_NAME="$CLEAN_LABEL"
else
    MOUNT_NAME="${ID_FS_UUID%%-*}"
fi
MOUNT_POINT="/mnt/${MOUNT_NAME}"
DEVPATH_PARENT="${DEVPATH%/*}"
SYS_DEV="${DEVPATH_PARENT##*/}"
IS_SYS_ROOT=$(df 2>/dev/null | awk -v d="$SYS_DEV" '"'"'$1~d{print $6}'"'"')
[ "$IS_SYS_ROOT" = "/" ] && exit 0
case "$ACTION" in
    add)
        [ -d "$MOUNT_POINT" ] || mkdir -p "$MOUNT_POINT"
        case "$ID_FS_TYPE" in
            vfat) MTYPE="vfat"; MOPTS="rw,utf8,uid=0,gid=0,umask=000" ;;
            exfat) MTYPE="exfat"; MOPTS="rw,uid=0,gid=0,umask=000" ;;
            ntfs)
                if grep -q "ntfs3" /proc/filesystems 2>/dev/null; then
                    MTYPE="ntfs3"; MOPTS="rw,uid=0,gid=0,umask=000"
                elif command -v ntfs-3g >/dev/null 2>&1; then
                    MTYPE="ntfs-3g"; MOPTS="rw,uid=0,gid=0,umask=000,big_writes"
                else
                    MTYPE="ntfs"; MOPTS="rw,uid=0,gid=0,umask=000"
                fi
                ;;
            ext2|ext3|ext4) MTYPE="$ID_FS_TYPE"; MOPTS="rw,defaults,noatime" ;;
            btrfs) MTYPE="btrfs"; MOPTS="rw,defaults,compress=zstd" ;;
            xfs)   MTYPE="xfs";   MOPTS="rw,defaults,noatime" ;;
            f2fs)  MTYPE="f2fs";  MOPTS="rw,defaults,noatime" ;;
            hfsplus) MTYPE="hfsplus"; MOPTS="rw,defaults" ;;
            *) MTYPE="$ID_FS_TYPE"; MOPTS="rw,defaults" ;;
        esac
        mount -t "$MTYPE" -o "$MOPTS" "$DEVNAME" "$MOUNT_POINT" 2>/dev/null \
            || mount "$DEVNAME" "$MOUNT_POINT" 2>/dev/null
        chmod -R 777 "$MOUNT_POINT" 2>/dev/null
        ;;
    remove)
        umount -l "$MOUNT_POINT" 2>/dev/null
        sync
        rmdir "$MOUNT_POINT" 2>/dev/null
        ;;
esac
'
UDEV_RULES_CONTENT='KERNEL!="sd[a-z][0-9]*|hd[a-z][0-9]*|mmcblk[0-9]*p[0-9]*|nvme[0-9]*n[0-9]*p[0-9]*|vd[a-z][0-9]*", GOTO="uuid_auto_mount_end"
SUBSYSTEM!="block", GOTO="uuid_auto_mount_end"
IMPORT{program}="/sbin/blkid -o udev -p %N"
ENV{ID_FS_TYPE}=="", GOTO="uuid_auto_mount_end"
ENV{ID_FS_UUID}=="", GOTO="uuid_auto_mount_end"
ACTION=="add|remove", RUN+="/bin/auto_block"
LABEL="uuid_auto_mount_end"'
show_all_disks_overview() {
    title "所有硬盘概览"
    printf "${WHITE}%-6s %-28s %-10s %-14s %-10s %-10s${NC}\n" "设备" "型号" "容量" "文件系统" "状态" "可操作"
    printf -- "--------------------------------------------------------------------------------\n"
    for disk in $(get_all_disks); do
        local info
        info=$(get_disk_info "$disk")
        IFS='|' read -r model size health pending reallocated uncorrectable hours temp <<< "$info"
        model=$(echo "${model:-未知}" | cut -c1-26)
        local status
        status=$(get_disk_status "$pending" "$reallocated" "$health")
        local operable
        if check_disk_in_use "$disk"; then
            operable="${RED}系统盘${NC}"
        elif check_disk_mounted "$disk"; then
            operable="${YELLOW}已挂载${NC}"
        else
            operable="${GREEN}可操作${NC}"
        fi
        local fs_info
        fs_info=$(lsblk -n -o FSTYPE "/dev/$disk" 2>/dev/null | grep -v "^$" | sort -u | tr '\n' ',' | sed 's/,$//')
        fs_info="${fs_info:-无分区}"
        printf "%-6s %-28s %-10s %-14s %-18b %-18b\n" "$disk" "$model" "$size" "$fs_info" "$status" "$operable"
        lsblk -n -o NAME,SIZE,FSTYPE,MOUNTPOINT,LABEL "/dev/$disk" 2>/dev/null | grep -v "^$disk " | while read -r line; do
            local pname psize pfs pmount plabel
            pname=$(echo "$line" | awk '{print $1}' | sed 's/[├└│─]//g' | xargs)
            psize=$(echo "$line" | awk '{print $2}')
            pfs=$(echo "$line" | awk '{print $3}')
            pmount=$(echo "$line" | awk '{print $4}')
            plabel=$(echo "$line" | awk '{print $5}')
            if [[ -n "$pname" ]]; then
                local mount_info="" label_info=""
                [[ -n "$pmount" ]] && mount_info="${CYAN}→ $pmount${NC}"
                [[ -n "$plabel" ]] && label_info="[$plabel]"
                printf "  ${PURPLE}└─ %-8s %-8s %-10s %s %b${NC}\n" "$pname" "$psize" "${pfs:-未格式化}" "$label_info" "$mount_info"
            fi
        done
    done
    printf -- "--------------------------------------------------------------------------------\n"
    local total_disks problem_disks=0
    total_disks=$(get_all_disks | wc -w)
    for disk in $(get_all_disks); do
        local info
        info=$(get_disk_info "$disk")
        IFS='|' read -r model size health pending reallocated uncorrectable hours temp <<< "$info"
        [[ "$pending" != "N/A" && "$pending" != "0" && -n "$pending" ]] && ((problem_disks++))
    done
    echo -e "硬盘总数: ${CYAN}$total_disks${NC}  |  问题硬盘: ${RED}$problem_disks${NC}"
    log "显示硬盘概览: 总计 $total_disks 块，问题 $problem_disks 块"
    pause
}
view_disk_detail() {
    title "查看硬盘 SMART 详情"
    local i=1
    local -a disks
    for disk in $(get_all_disks); do
        disks+=("$disk")
        local size model
        size=$(lsblk -d -n -o SIZE "/dev/$disk")
        model=$(smartctl -i "/dev/$disk" 2>/dev/null | grep "Device Model" | cut -d: -f2 | xargs 2>/dev/null)
        echo "  $i) /dev/$disk - ${model:-未知} ($size)"
        ((i++))
    done
    echo "  0) 返回"
    read -rp "请选择硬盘 [0-$((i-1))]: " choice
    [[ "$choice" == "0" ]] && return
    if [[ "$choice" -ge 1 && "$choice" -lt "$i" ]] 2>/dev/null; then
        local selected_disk="${disks[$((choice-1))]}"
        show_disk_smart_detail "$selected_disk"
    else
        error "无效选项"; sleep 1
    fi
}
show_disk_smart_detail() {
    local disk="$1"
    title "/dev/$disk SMART 详情"
    echo -e "${CYAN}基本信息:${NC}"
    smartctl -i "/dev/$disk" 2>/dev/null | grep -E "Model|Serial|Capacity|Sector|Firmware|Rotation"
    echo -e "${CYAN}健康状态:${NC}"
    smartctl -H "/dev/$disk" 2>/dev/null | grep -E "overall-health|test result"
    echo -e "${CYAN}关键 SMART 指标:${NC}"
    printf "%-30s %-10s %-10s %-15s\n" "指标" "当前值" "阈值" "原始值"
    printf -- "----------------------------------------------------------------------\n"
    smartctl -A "/dev/$disk" 2>/dev/null | grep -E "Reallocated_Sector|Current_Pending|Offline_Uncorrectable|Power_On_Hours|Temperature|Raw_Read_Error|Spin_Retry|Seek_Error" | \
    while read -r line; do
        local name value thresh raw
        name=$(echo "$line" | awk '{print $2}')
        value=$(echo "$line" | awk '{print $4}')
        thresh=$(echo "$line" | awk '{print $6}')
        raw=$(echo "$line" | awk '{print $10}')
        printf "%-30s %-10s %-10s %-15s\n" "$name" "$value" "$thresh" "$raw"
    done
    echo -e "${CYAN}自检历史:${NC}"
    smartctl -l selftest "/dev/$disk" 2>/dev/null | head -20
    echo -e "${CYAN}分区信息:${NC}"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,LABEL,UUID "/dev/$disk"
    pause
}
repair_disk_menu() {
    title "选择要修复的硬盘"
    local i=1
    local -a disks
    for disk in $(get_all_disks); do
        check_disk_in_use "$disk" && continue
        disks+=("$disk")
        local info
        info=$(get_disk_info "$disk")
        IFS='|' read -r model size health pending reallocated uncorrectable hours temp <<< "$info"
        local status
        status=$(get_disk_status "$pending" "$reallocated" "$health")
        local mount_status=""
        check_disk_mounted "$disk" && mount_status="${YELLOW}[已挂载]${NC}"
        echo -e "  $i) /dev/$disk - ${model:-未知} ($size) 状态: $status 待处理: ${pending:-0} $mount_status"
        ((i++))
    done
    if [[ ${#disks[@]} -eq 0 ]]; then
        warn "没有可修复的硬盘（系统盘已排除）"
        pause; return
    fi
    echo "  0) 返回"
    read -rp "请选择硬盘 [0-$((i-1))]: " choice
    [[ "$choice" == "0" ]] && return
    if [[ "$choice" -ge 1 && "$choice" -lt "$i" ]] 2>/dev/null; then
        repair_options_menu "${disks[$((choice-1))]}"
    else
        error "无效选项"; sleep 1
    fi
}
repair_options_menu() {
    local disk="$1"
    while true; do
        title "/dev/$disk 修复选项"
        local info
        info=$(get_disk_info "$disk")
        IFS='|' read -r model size health pending reallocated uncorrectable hours temp <<< "$info"
        echo -e "型号: ${CYAN}${model:-未知}${NC}  容量: ${CYAN}$size${NC}  健康: ${CYAN}${health:-N/A}${NC}"
        echo -e "待处理坏道: ${YELLOW}${pending:-0}${NC}  已重映射: ${CYAN}${reallocated:-0}${NC}  运行: ${CYAN}${hours:-N/A}${NC}h  温度: ${CYAN}${temp:-N/A}${NC}°C"
        echo "  1) 快速检测 - SMART 短测试 (约2分钟)"
        echo "  2) 完整检测 - SMART 长测试 (约1-2小时)"
        echo "  3) 扫描坏块 - 只读扫描不修复"
        echo "  4) 快速修复 - 修复已知坏扇区"
        echo "  5) 标准修复 - 扫描并尝试修复"
        echo -e "  6) 强力修复 - 破坏性全盘修复 ${RED}[数据丢失]${NC}"
        echo -e "  7) 完整重建 - 修复+分区+格式化 ${RED}[数据丢失]${NC}"
        echo "  0) 返回"
        read -rp "请输入选项 [0-7]: " repair_choice
        case $repair_choice in
            1) smart_short_test "$disk" ;;
            2) smart_long_test "$disk" ;;
            3) scan_badblocks_readonly "$disk" ;;
            4) quick_fix_known_sectors "$disk" ;;
            5) standard_repair "$disk" ;;
            6) destructive_repair "$disk" ;;
            7) full_rebuild "$disk" ;;
            0) return ;;
            *) error "无效选项"; sleep 1 ;;
        esac
    done
}
smart_short_test() {
    local disk="$1"
    title "SMART 短测试 /dev/$disk"
    log "开始 SMART 短测试: /dev/$disk"
    smartctl -t short "/dev/$disk"
    echo -e "${YELLOW}测试已启动，等待约 2 分钟...${NC}"
    local count=0
    while [[ $count -lt 130 ]]; do
        echo -ne "\r等待中... $((130-count)) 秒 "
        sleep 1
        ((count++))
    done
    echo ""
    echo -e "${GREEN}测试结果:${NC}"
    smartctl -l selftest "/dev/$disk" | head -15
    log "SMART 短测试完成: /dev/$disk"
    pause
}
smart_long_test() {
    local disk="$1"
    title "SMART 长测试 /dev/$disk"
    local est_time
    est_time=$(smartctl -c "/dev/$disk" 2>/dev/null | grep "Extended self-test" | grep -oE "[0-9]+" | head -1)
    echo -e "${YELLOW}预计需要 ${est_time:-90} 分钟，测试将在后台运行${NC}"
    confirm "确认开始长测试?" || return
    log "开始 SMART 长测试: /dev/$disk"
    smartctl -t long "/dev/$disk"
    echo -e "${GREEN}测试已启动！查看进度:${NC}"
    echo -e "${CYAN}  smartctl -l selftest /dev/$disk${NC}"
    echo -e "${CYAN}  smartctl -a /dev/$disk | grep -i progress${NC}"
    log "SMART 长测试已启动: /dev/$disk"
    pause
}
scan_badblocks_readonly() {
    local disk="$1"
    title "只读扫描坏块 /dev/$disk"
    echo -e "${YELLOW}此操作不会修改数据，但需要较长时间${NC}"
    confirm "确认开始扫描?" || return
    if check_disk_mounted "$disk"; then
        error "硬盘已挂载，请先卸载"; pause; return
    fi
    log "开始只读坏块扫描: /dev/$disk"
    local output_file="$LOG_DIR/badblocks_${disk}_$(date +%Y%m%d_%H%M%S).txt"
    info "扫描进行中，输出文件: $output_file"
    badblocks -sv -b 512 "/dev/$disk" -o "$output_file" 2>&1 | tee -a "$LOG_FILE"
    if [[ -s "$output_file" ]]; then
        local count
        count=$(wc -l < "$output_file")
        error "发现 $count 个坏块！坏块列表已保存到: $output_file"
    else
        info "未发现坏块！"
    fi
    log "只读坏块扫描完成: /dev/$disk"
    pause
}
quick_fix_known_sectors() {
    local disk="$1"
    title "快速修复已知坏扇区 /dev/$disk"
    local error_lba
    error_lba=$(smartctl -l selftest "/dev/$disk" 2>/dev/null | grep -E "read failure|Completed.*failure" | head -1 | awk '{print $NF}')
    if [[ -z "$error_lba" || "$error_lba" == "-" ]]; then
        warn "未找到已知的坏扇区 LBA，建议先运行 SMART 测试或坏块扫描"
        pause; return
    fi
    echo -e "发现错误扇区 LBA: ${RED}$error_lba${NC}"
    echo -e "${YELLOW}此操作将向该扇区写入零，该扇区的数据将丢失！${NC}"
    confirm "确认修复扇区 $error_lba?" || return
    log "开始修复扇区: /dev/$disk LBA=$error_lba"
    hdparm --write-sector "$error_lba" --yes-i-know-what-i-am-doing "/dev/$disk" 2>&1 | tee -a "$LOG_FILE"
    info "扇区修复命令已执行"
    log "扇区修复完成: /dev/$disk LBA=$error_lba"
    pause
}
standard_repair() {
    local disk="$1"
    title "标准修复 /dev/$disk"
    echo -e "${YELLOW}将扫描全盘查找坏块并尝试修复${NC}"
    if check_disk_mounted "$disk"; then
        error "硬盘已挂载，请先卸载"; pause; return
    fi
    confirm "确认开始标准修复?" || return
    log "开始标准修复: /dev/$disk"
    local badblocks_file="$LOG_DIR/badblocks_${disk}_$(date +%Y%m%d_%H%M%S).txt"
    echo -e "${CYAN}[1/3] 扫描坏块...${NC}"
    badblocks -sv -b 512 "/dev/$disk" -o "$badblocks_file" 2>&1 | tee -a "$LOG_FILE"
    if [[ -s "$badblocks_file" ]]; then
        echo -e "${CYAN}[2/3] 发现坏块，尝试修复...${NC}"
        while read -r lba; do
            echo "修复 LBA: $lba"
            hdparm --write-sector "$lba" --yes-i-know-what-i-am-doing "/dev/$disk" >> "$LOG_FILE" 2>&1
        done < "$badblocks_file"
        echo -e "${CYAN}[3/3] 验证修复结果...${NC}"
        smartctl -t short "/dev/$disk"
        sleep 130
        smartctl -l selftest "/dev/$disk"
    else
        info "未发现坏块"
    fi
    smartctl -A "/dev/$disk" | grep -E "Reallocated|Current_Pending|Offline_Uncorrectable"
    log "标准修复完成: /dev/$disk"
    pause
}
destructive_repair() {
    local disk="$1"
    title "强力修复（破坏性） /dev/$disk"
    echo -e "${RED}严重警告：此操作将完全清除硬盘上的所有数据，不可逆！${NC}"
    if check_disk_mounted "$disk"; then
        error "硬盘已挂载，请先卸载"; pause; return
    fi
    read -rp "请输入 'YES' 确认: " confirm_text
    if [[ "$confirm_text" != "YES" ]]; then
        warn "操作已取消"; pause; return
    fi
    log "开始破坏性修复: /dev/$disk"
    local badblocks_file="$LOG_DIR/badblocks_destructive_${disk}_$(date +%Y%m%d_%H%M%S).txt"
    info "开始破坏性读写测试..."
    badblocks -wsv -b 4096 -p 1 "/dev/$disk" -o "$badblocks_file" 2>&1 | tee -a "$LOG_FILE"
    if [[ -s "$badblocks_file" ]]; then
        local count
        count=$(wc -l < "$badblocks_file")
        warn "仍有 $count 个无法修复的坏块"
    else
        info "所有坏块已修复！"
    fi
    smartctl -A "/dev/$disk" | grep -E "Reallocated|Current_Pending|Offline_Uncorrectable"
    log "破坏性修复完成: /dev/$disk"
    pause
}
full_rebuild() {
    local disk="$1"
    title "完整重建 /dev/$disk"
    echo -e "${RED}此操作将清除所有数据并重建硬盘！${NC}"
    if check_disk_mounted "$disk"; then
        error "硬盘已挂载"; pause; return
    fi
    read -rp "请输入硬盘名确认 (如 sdb): " confirm_disk
    if [[ "$confirm_disk" != "$disk" ]]; then
        warn "操作已取消"; pause; return
    fi
    read -rp "请输入 'DESTROY ALL DATA' 确认: " final_confirm
    if [[ "$final_confirm" != "DESTROY ALL DATA" ]]; then
        warn "操作已取消"; pause; return
    fi
    echo "选择文件系统格式:"
    echo "  1) ext4  2) xfs  3) btrfs  4) ntfs  5) exfat"
    read -rp "选择 [1-5]: " fs_choice
    local fs_type
    case $fs_choice in
        1) fs_type="ext4" ;;
        2) fs_type="xfs" ;;
        3) fs_type="btrfs" ;;
        4) fs_type="ntfs" ;;
        5) fs_type="exfat" ;;
        *) fs_type="ext4" ;;
    esac
    ensure_fs_support "$fs_type"
    log "开始完整重建: /dev/$disk 文件系统: $fs_type"
    local badblocks_file="$LOG_DIR/badblocks_rebuild_${disk}_$(date +%Y%m%d_%H%M%S).txt"
    echo -e "${CYAN}[1/5] 破坏性扫描修复...${NC}"
    badblocks -wsv -b 4096 "/dev/$disk" -o "$badblocks_file" 2>&1 | tee -a "$LOG_FILE"
    echo -e "${CYAN}[2/5] 清除分区表...${NC}"
    wipefs -af "/dev/$disk" >> "$LOG_FILE" 2>&1
    dd if=/dev/zero of="/dev/$disk" bs=1M count=100 status=none 2>> "$LOG_FILE"
    echo -e "${CYAN}[3/5] 创建 GPT 分区表...${NC}"
    parted -s "/dev/$disk" mklabel gpt >> "$LOG_FILE" 2>&1
    parted -s "/dev/$disk" mkpart primary "$fs_type" 0% 100% >> "$LOG_FILE" 2>&1
    sleep 2
    partprobe "/dev/$disk" 2>/dev/null
    echo -e "${CYAN}[4/5] 格式化为 $fs_type...${NC}"
    local real_fs
    real_fs=$(get_real_fstype "$fs_type")
    case $real_fs in
        ext4)
            if [[ -s "$badblocks_file" ]]; then
                mkfs.ext4 -l "$badblocks_file" -L "Disk_${disk}" "/dev/${disk}1" 2>&1 | tee -a "$LOG_FILE"
            else
                mkfs.ext4 -L "Disk_${disk}" "/dev/${disk}1" 2>&1 | tee -a "$LOG_FILE"
            fi
            ;;
        xfs)     mkfs.xfs   -f -L "Disk_${disk}" "/dev/${disk}1" 2>&1 | tee -a "$LOG_FILE" ;;
        btrfs)   mkfs.btrfs -f -L "Disk_${disk}" "/dev/${disk}1" 2>&1 | tee -a "$LOG_FILE" ;;
        ntfs-3g) mkfs.ntfs  -f -L "Disk_${disk}" "/dev/${disk}1" 2>&1 | tee -a "$LOG_FILE" ;;
        exfat)   mkfs.exfat    -n "Disk_${disk}" "/dev/${disk}1" 2>&1 | tee -a "$LOG_FILE" ;;
    esac
    echo -e "${CYAN}[5/5] 验证结果...${NC}"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL "/dev/$disk"
    info "完整重建完成！"
    log "完整重建完成: /dev/$disk"
    pause
}
auto_repair_all() {
    title "自动扫描并修复所有问题硬盘"
    info "正在扫描..."
    local -a problem_disks
    for disk in $(get_all_disks); do
        check_disk_in_use "$disk" && continue
        local info
        info=$(get_disk_info "$disk")
        IFS='|' read -r model size health pending reallocated uncorrectable hours temp <<< "$info"
        if [[ "$pending" != "N/A" && "$pending" != "0" && -n "$pending" ]]; then
            problem_disks+=("$disk")
            echo -e "  发现: ${RED}/dev/$disk${NC} - 待处理坏道: $pending"
        fi
    done
    if [[ ${#problem_disks[@]} -eq 0 ]]; then
        info "未发现问题硬盘"; pause; return
    fi
    warn "发现 ${#problem_disks[@]} 个问题硬盘"
    echo "  1) 快速修复 - 修复已知坏扇区"
    echo "  2) 标准修复 - 扫描并修复"
    echo -e "  3) 强力修复 - ${RED}数据丢失${NC}"
    echo "  0) 取消"
    read -rp "选择 [0-3]: " repair_mode
    case $repair_mode in
        1) for disk in "${problem_disks[@]}"; do check_disk_mounted "$disk" || quick_fix_known_sectors "$disk"; done ;;
        2) for disk in "${problem_disks[@]}"; do check_disk_mounted "$disk" || standard_repair "$disk"; done ;;
        3) confirm "确认强力修复所有问题硬盘?" && \
           for disk in "${problem_disks[@]}"; do check_disk_mounted "$disk" || destructive_repair "$disk"; done ;;
    esac
}
format_disk_menu() {
    title "格式化硬盘/分区"
    local i=1
    local -a targets
    local -a target_types
    for disk in $(get_all_disks); do
        check_disk_in_use "$disk" && continue
        local size model mount_warn=""
        size=$(lsblk -d -n -o SIZE "/dev/$disk")
        model=$(smartctl -i "/dev/$disk" 2>/dev/null | grep "Device Model" | cut -d: -f2 | xargs 2>/dev/null)
        check_disk_mounted "$disk" && mount_warn="${YELLOW}[已挂载]${NC}"
        echo -e "  $i) /dev/$disk - ${model:-未知} ($size) 整块硬盘 $mount_warn"
        targets+=("$disk"); target_types+=("disk"); ((i++))
        for part in $(lsblk -n -o NAME "/dev/$disk" 2>/dev/null | grep -v "^$disk$"); do
            part=$(echo "$part" | sed 's/[├└│─]//g' | xargs)
            if [[ -n "$part" ]]; then
                local psize pfs pmount part_warn=""
                psize=$(lsblk -n -o SIZE "/dev/$part" 2>/dev/null)
                pfs=$(lsblk -n -o FSTYPE "/dev/$part" 2>/dev/null)
                pmount=$(lsblk -n -o MOUNTPOINT "/dev/$part" 2>/dev/null)
                [[ -n "$pmount" ]] && part_warn="${YELLOW}[挂载于 $pmount]${NC}"
                echo -e "  $i)   └─ /dev/$part ($psize) ${pfs:-未格式化} $part_warn"
                targets+=("$part"); target_types+=("part"); ((i++))
            fi
        done
    done
    if [[ ${#targets[@]} -eq 0 ]]; then
        warn "没有可格式化的硬盘"; pause; return
    fi
    echo "  0) 返回"
    read -rp "选择目标 [0-$((i-1))]: " choice
    [[ "$choice" == "0" ]] && return
    if [[ "$choice" -ge 1 && "$choice" -lt "$i" ]] 2>/dev/null; then
        format_target "${targets[$((choice-1))]}" "${target_types[$((choice-1))]}"
    else
        error "无效选项"; sleep 1
    fi
}
format_target() {
    local target="$1" ttype="$2"
    title "格式化 /dev/$target"
    if mount | grep -q "/dev/$target"; then
        error "目标已挂载，请先卸载"
        mount | grep "/dev/$target"
        pause; return
    fi
    local size
    size=$(lsblk -d -n -o SIZE "/dev/$target" 2>/dev/null)
    echo -e "目标: ${CYAN}/dev/$target${NC}  容量: ${CYAN}$size${NC}  类型: ${CYAN}$ttype${NC}"
    echo "选择文件系统格式:"
    echo "  1) ext4   - Linux 标准推荐"
    echo "  2) ext3   - 兼容旧系统"
    echo "  3) xfs    - 大文件高性能"
    echo "  4) btrfs  - 快照压缩支持"
    echo "  5) ntfs   - Windows 兼容"
    echo "  6) fat32  - 最大兼容性(单文件≤4GB)"
    echo "  7) exfat  - 大文件+跨平台"
    echo "  0) 取消"
    read -rp "选择文件系统 [0-7]: " fs_choice
    local fs_type
    case $fs_choice in
        1) fs_type="ext4" ;;
        2) fs_type="ext3" ;;
        3) fs_type="xfs" ;;
        4) fs_type="btrfs" ;;
        5) fs_type="ntfs" ;;
        6) fs_type="vfat" ;;
        7) fs_type="exfat" ;;
        0) return ;;
        *) error "无效选项"; sleep 1; return ;;
    esac
    ensure_fs_support "$fs_type"
    read -rp "输入卷标 (直接回车默认 Disk_$target): " label
    label="${label:-Disk_$target}"
    local format_target_dev="/dev/$target"
    if [[ "$ttype" == "disk" ]]; then
        warn "将对整块硬盘进行分区和格式化..."
        confirm "确认格式化整块硬盘 /dev/$target?" || return
        echo -e "${CYAN}[1/3] 清除分区表...${NC}"
        wipefs -af "/dev/$target" >> "$LOG_FILE" 2>&1
        dd if=/dev/zero of="/dev/$target" bs=1M count=10 status=none 2>> "$LOG_FILE"
        echo -e "${CYAN}[2/3] 创建 GPT 分区...${NC}"
        parted -s "/dev/$target" mklabel gpt >> "$LOG_FILE" 2>&1
        parted -s "/dev/$target" mkpart primary "$fs_type" 0% 100% >> "$LOG_FILE" 2>&1
        sleep 2
        partprobe "/dev/$target" 2>/dev/null
        format_target_dev="/dev/${target}1"
        echo -e "${CYAN}[3/3] 格式化分区...${NC}"
    else
        confirm "确认格式化 /dev/$target?" || return
    fi
    info "正在格式化为 $fs_type..."
    local real_fs
    real_fs=$(get_real_fstype "$fs_type")
    case $real_fs in
        ext4|ext3) mkfs.${real_fs} -L "$label" "$format_target_dev" 2>&1 | tee -a "$LOG_FILE" ;;
        xfs)       mkfs.xfs   -f -L "$label" "$format_target_dev" 2>&1 | tee -a "$LOG_FILE" ;;
        btrfs)     mkfs.btrfs -f -L "$label" "$format_target_dev" 2>&1 | tee -a "$LOG_FILE" ;;
        ntfs-3g)   mkfs.ntfs  -f -L "$label" "$format_target_dev" 2>&1 | tee -a "$LOG_FILE" ;;
        vfat)      mkfs.vfat -F 32 -n "${label:0:11}" "$format_target_dev" 2>&1 | tee -a "$LOG_FILE" ;;
        exfat)     mkfs.exfat   -n "$label" "$format_target_dev" 2>&1 | tee -a "$LOG_FILE" ;;
    esac
    info "格式化完成！"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,UUID "/dev/$target"
    echo -e "${CYAN}挂载命令: mkdir -p /mnt/$label && mount $format_target_dev /mnt/$label${NC}"
    log "格式化完成: $format_target_dev 文件系统: $fs_type 卷标: $label"
    pause
}
partition_menu() {
    while true; do
        title "分区管理"
        echo -e "${WHITE}当前分区状态:${NC}"
        lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,LABEL
        echo "  1) 查看详细分区信息"
        echo "  2) 创建新分区表 (GPT/MBR)"
        echo "  3) 创建新分区"
        echo "  4) 删除分区"
        echo "  5) 分区调整参考命令"
        echo "  0) 返回"
        read -rp "选择 [0-5]: " part_choice
        case $part_choice in
            1) show_partition_detail ;;
            2) create_partition_table ;;
            3) create_partition ;;
            4) delete_partition ;;
            5) resize_partition_info ;;
            0) return ;;
            *) error "无效选项"; sleep 1 ;;
        esac
    done
}
show_partition_detail() {
    title "分区详细信息"
    for disk in $(get_all_disks); do
        echo -e "${CYAN}=== /dev/$disk ===${NC}"
        parted "/dev/$disk" print 2>/dev/null
    done
    pause
}
create_partition_table() {
    title "创建新分区表"
    local i=1
    local -a disks
    for disk in $(get_all_disks); do
        check_disk_in_use "$disk" && continue
        disks+=("$disk")
        local size
        size=$(lsblk -d -n -o SIZE "/dev/$disk")
        echo "  $i) /dev/$disk ($size)"
        ((i++))
    done
    echo "  0) 取消"
    read -rp "选择 [0-$((i-1))]: " choice
    [[ "$choice" == "0" ]] && return
    if [[ "$choice" -ge 1 && "$choice" -lt "$i" ]] 2>/dev/null; then
        local disk="${disks[$((choice-1))]}"
        if check_disk_mounted "$disk"; then
            error "硬盘已挂载"; pause; return
        fi
        echo "  1) GPT - 推荐，支持大于2TB"
        echo "  2) MBR - 兼容旧系统"
        read -rp "选择 [1-2]: " table_type
        local label
        case $table_type in
            1) label="gpt" ;;
            2) label="msdos" ;;
            *) error "无效选项"; pause; return ;;
        esac
        echo -e "${RED}这将清除 /dev/$disk 上的所有数据！${NC}"
        if confirm "确认创建 $label 分区表?"; then
            wipefs -af "/dev/$disk" >> "$LOG_FILE" 2>&1
            parted -s "/dev/$disk" mklabel "$label"
            info "分区表创建成功！"
            log "创建分区表: /dev/$disk $label"
        fi
    fi
    pause
}
create_partition() {
    title "创建新分区"
    local i=1
    local -a disks
    for disk in $(get_all_disks); do
        check_disk_in_use "$disk" && continue
        disks+=("$disk")
        local size parts
        size=$(lsblk -d -n -o SIZE "/dev/$disk")
        parts=$(lsblk -n "/dev/$disk" | wc -l)
        echo "  $i) /dev/$disk ($size) - $((parts-1)) 个分区"
        ((i++))
    done
    echo "  0) 取消"
    read -rp "选择 [0-$((i-1))]: " choice
    [[ "$choice" == "0" ]] && return
    if [[ "$choice" -ge 1 && "$choice" -lt "$i" ]] 2>/dev/null; then
        local disk="${disks[$((choice-1))]}"
        parted "/dev/$disk" print free 2>/dev/null
        read -rp "输入分区大小 (如 100GB、50%、留空全部): " psize
        psize="${psize:-100%}"
        if confirm "确认在 /dev/$disk 上创建分区?"; then
            parted -s "/dev/$disk" mkpart primary 0% "$psize" 2>&1 | tee -a "$LOG_FILE"
            partprobe "/dev/$disk" 2>/dev/null
            info "分区创建成功！"
            lsblk "/dev/$disk"
            log "创建分区: /dev/$disk 大小: $psize"
        fi
    fi
    pause
}
delete_partition() {
    title "删除分区"
    local i=1
    local -a parts
    for disk in $(get_all_disks); do
        check_disk_in_use "$disk" && continue
        for part in $(lsblk -n -o NAME "/dev/$disk" 2>/dev/null | grep -v "^$disk$"); do
            part=$(echo "$part" | sed 's/[├└│─]//g' | xargs)
            if [[ -n "$part" ]]; then
                local pmount
                pmount=$(lsblk -n -o MOUNTPOINT "/dev/$part" 2>/dev/null)
                if [[ -z "$pmount" ]]; then
                    parts+=("$part")
                    local psize pfs
                    psize=$(lsblk -n -o SIZE "/dev/$part")
                    pfs=$(lsblk -n -o FSTYPE "/dev/$part")
                    echo "  $i) /dev/$part ($psize) $pfs"
                    ((i++))
                fi
            fi
        done
    done
    echo "  0) 取消"
    if [[ ${#parts[@]} -eq 0 ]]; then
        warn "没有可删除的分区"; pause; return
    fi
    read -rp "选择 [0-$((i-1))]: " choice
    [[ "$choice" == "0" ]] && return
    if [[ "$choice" -ge 1 && "$choice" -lt "$i" ]] 2>/dev/null; then
        local part="${parts[$((choice-1))]}"
        local disk partnum
        disk=$(echo "$part" | sed 's/[0-9]*$//')
        partnum=$(echo "$part" | grep -oE '[0-9]+$')
        echo -e "${RED}这将删除 /dev/$part 上的所有数据！${NC}"
        if confirm "确认删除分区?"; then
            parted -s "/dev/$disk" rm "$partnum" 2>&1 | tee -a "$LOG_FILE"
            partprobe "/dev/$disk" 2>/dev/null
            info "分区删除成功！"
            log "删除分区: /dev/$part"
        fi
    fi
    pause
}
resize_partition_info() {
    title "分区调整参考命令"
    echo -e "${CYAN}  parted /dev/sdX resizepart N SIZE${NC}"
    echo -e "${CYAN}  resize2fs /dev/sdXN          # ext4${NC}"
    echo -e "${CYAN}  xfs_growfs /mountpoint        # xfs${NC}"
    echo -e "${CYAN}  btrfs filesystem resize max / # btrfs${NC}"
    pause
}
install_auto_mount() {
    title "安装自动挂载功能"
    ensure_base_deps
    read -rp "请输入挂载根目录 (默认 /mnt，按回车跳过): " MNT_BASE_INPUT
    MNT_BASE="${MNT_BASE_INPUT:-/mnt}"
    [ -d "$MNT_BASE" ] || mkdir -p "$MNT_BASE"
    info "挂载根目录: $MNT_BASE"
    if [ "$IS_OPENWRT" = "1" ]; then
        mkdir -p /etc/hotplug.d/block
        printf '%s' "$HOTPLUG_CONTENT" > /etc/hotplug.d/block/20-auto-mount
        chmod +x /etc/hotplug.d/block/20-auto-mount
        uci set fstab.@global[0].auto_mount_base="$MNT_BASE" 2>/dev/null
        uci commit fstab 2>/dev/null
        /etc/init.d/fstab enable 2>/dev/null
        /etc/init.d/fstab start  2>/dev/null
        info "OpenWrt hotplug 自动挂载安装完成。"
        info "脚本位置: /etc/hotplug.d/block/20-auto-mount"
    else
        printf '%s' "$UDEV_BLOCK_CONTENT" > /bin/auto_block
        chmod +x /bin/auto_block
        printf '%s\n' "$UDEV_RULES_CONTENT" > /etc/udev/rules.d/10-auto_block.rules
        udevadm control --reload 2>/dev/null
        info "udev 自动挂载安装完成。"
    fi
}
manage_persistent_mount() {
    title "配置持久挂载（重启后自动挂载）"
    ensure_base_deps
    info "扫描当前块设备分区..."
    if [ "$IS_OPENWRT" = "1" ]; then
        block info 2>/dev/null
        PART_LIST=$(block info 2>/dev/null | awk '
        /^\/dev\// { split($0,a,":"); dev=a[1]; uuid=""; fstype=""; label=""; mnt="" }
        /UUID=/    { match($0,/UUID="([^"]+)"/,u);  uuid=u[1] }
        /TYPE=/    { match($0,/TYPE="([^"]+)"/,t);  fstype=t[1] }
        /LABEL=/   { match($0,/LABEL="([^"]+)"/,l); label=l[1] }
        /MOUNT=/   { match($0,/MOUNT="([^"]+)"/,m); mnt=m[1]
            if(mnt != "/" && dev != "" && uuid != "") print dev" "uuid" "fstype" "label" "mnt
        }')
    else
        lsblk -o PATH,UUID,FSTYPE,LABEL,MOUNTPOINT -n -p 2>/dev/null | \
            awk '{if($2!="" && $3!="") printf "  %-12s UUID:%-38s 类型:%-8s 标签:%-16s 挂载:%s\n",$1,$2,$3,$4,$5}'
        PART_LIST=$(lsblk -o PATH,UUID,FSTYPE,LABEL,MOUNTPOINT -n -p 2>/dev/null | \
            awk '{if($2!="" && $3!="" && $5!="/") print $1" "$2" "$3" "$4" "$5}')
    fi
    local OLD_IFS="$IFS"
    IFS='
'
    local PART_ARRAY="" IDX=0
    for line in $PART_LIST; do
        [ -z "$(echo "$line" | tr -d ' ')" ] && continue
        IDX=$((IDX+1))
        printf "  ${YELLOW}%2d.${NC} %s\n" $IDX "$line"
        PART_ARRAY="${PART_ARRAY}${IDX}:${line}
"
    done
    IFS="$OLD_IFS"
    if [ "$IDX" = "0" ]; then
        warn "未找到可配置的分区，请先插入设备。"; return
    fi
    read -rp "请输入要持久挂载的分区编号 (多个用空格，如 1 3): " SELECTED_NUMS
    for num in $SELECTED_NUMS; do
        local PART_LINE
        PART_LINE=$(echo "$PART_ARRAY" | grep "^${num}:" | sed "s/^${num}://")
        [ -z "$PART_LINE" ] && { warn "无效编号: $num，跳过。"; continue; }
        local DEV UUID FSTYPE LABEL CURRENT_MNT
        DEV=$(echo "$PART_LINE"    | awk '{print $1}')
        UUID=$(echo "$PART_LINE"   | awk '{print $2}' | sed 's/UUID=//I;s/"//g')
        FSTYPE=$(echo "$PART_LINE" | awk '{print $3}' | sed 's/TYPE=//I;s/"//g')
        LABEL=$(echo "$PART_LINE"  | awk '{print $4}' | sed 's/LABEL=//I;s/"//g')
        CURRENT_MNT=$(echo "$PART_LINE" | awk '{print $5}' | sed 's/"//g')
        ensure_fs_support "$FSTYPE"
        local REAL_FSTYPE MOUNT_NAME DEFAULT_MNT
        REAL_FSTYPE=$(get_real_fstype "$FSTYPE")
        MOUNT_NAME=$(make_mount_name "$LABEL" "$UUID" "$FSTYPE")
        DEFAULT_MNT="/mnt/${MOUNT_NAME}"
        read -rp "为设备 ${DEV} [${FSTYPE}] 标签:'${LABEL}' 设置挂载点 (建议: ${DEFAULT_MNT}, 留空使用建议值): " USER_MNT
        local MOUNT_PT="${USER_MNT:-$DEFAULT_MNT}"
        local DEFAULT_OPTS
        DEFAULT_OPTS=$(get_fs_mount_opts "$FSTYPE")
        read -rp "挂载选项 (留空使用默认: '${DEFAULT_OPTS}'): " USER_OPTS
        local OPTS="${USER_OPTS:-$DEFAULT_OPTS}"
        [ -d "$MOUNT_PT" ] || mkdir -p "$MOUNT_PT"
        if [ "$IS_OPENWRT" = "1" ]; then
            local EXIST
            EXIST=$(uci show fstab 2>/dev/null | grep "uuid='$UUID'" | head -1 | cut -d. -f1-2)
            if [ -n "$EXIST" ]; then
                warn "UUID $UUID 已存在UCI fstab，更新配置..."
                uci set "${EXIST}.target=${MOUNT_PT}"
                uci set "${EXIST}.options=${OPTS}"
                uci set "${EXIST}.fstype=${REAL_FSTYPE}"
                uci set "${EXIST}.enabled=1"
            else
                uci add fstab mount > /dev/null
                uci set fstab.@mount[-1].uuid="$UUID"
                uci set fstab.@mount[-1].target="$MOUNT_PT"
                uci set fstab.@mount[-1].fstype="$REAL_FSTYPE"
                uci set fstab.@mount[-1].options="$OPTS"
                uci set fstab.@mount[-1].enabled=1
                uci set fstab.@mount[-1].device="$DEV"
                [ -n "$LABEL" ] && uci set fstab.@mount[-1].label="$LABEL"
            fi
            uci commit fstab
            block mount 2>/dev/null || mount -t "$REAL_FSTYPE" -o "$OPTS" "$DEV" "$MOUNT_PT" 2>/dev/null
            chmod 777 "$MOUNT_PT" 2>/dev/null
            info "UCI fstab 已配置: $DEV ($REAL_FSTYPE) -> $MOUNT_PT"
        else
            if grep -q "UUID=$UUID" /etc/fstab 2>/dev/null; then
                warn "UUID=$UUID 已在 /etc/fstab 中，跳过写入。"
            else
                cp /etc/fstab /etc/fstab.bak.$(date +%Y%m%d%H%M%S)
                printf "UUID=%s\t%s\t%s\t%s\t0\t2\n" "$UUID" "$MOUNT_PT" "$REAL_FSTYPE" "$OPTS" >> /etc/fstab
                info "已写入 /etc/fstab: UUID=$UUID ($REAL_FSTYPE) -> $MOUNT_PT"
            fi
            mount -a 2>/dev/null || mount -t "$REAL_FSTYPE" -o "$OPTS" "$DEV" "$MOUNT_PT" 2>/dev/null
            chmod 777 "$MOUNT_PT" 2>/dev/null
            info "持久挂载设置完成: $DEV -> $MOUNT_PT"
        fi
    done
}
show_persistent_mounts() {
    title "当前持久挂载配置"
    if [ "$IS_OPENWRT" = "1" ]; then
        info "UCI fstab 挂载条目:"
        uci show fstab 2>/dev/null | grep -E "^fstab\.@mount" || printf "  (无)\n"
        info "当前已挂载设备:"
        df -h 2>/dev/null | grep -v "tmpfs\|overlayfs\|rootfs"
    else
        info "/etc/fstab 内容 (非注释行):"
        grep -v "^#\|^$" /etc/fstab 2>/dev/null || printf "  (无)\n"
        info "当前已挂载设备:"
        df -h 2>/dev/null | grep -v "tmpfs\|udev\|/dev/loop"
    fi
    pause
}
remove_persistent_mount() {
    title "移除持久挂载条目"
    if [ "$IS_OPENWRT" = "1" ]; then
        info "当前UCI fstab挂载条目:"
        local ENTRIES
        ENTRIES=$(uci show fstab 2>/dev/null | grep "\.uuid=" | nl -ba)
        printf "%s\n" "$ENTRIES"
        [ -z "$ENTRIES" ] && { warn "无配置条目。"; return; }
        read -rp "输入要移除的条目序号 (多个用空格): " REMOVE_NUMS
        for num in $(printf '%s' "$REMOVE_NUMS" | tr ' ' '\n' | sort -rn); do
            local IDX=$((num-1))
            local MNT_PT
            MNT_PT=$(uci get fstab.@mount[$IDX].target 2>/dev/null)
            uci delete fstab.@mount[$IDX] 2>/dev/null
            uci commit fstab 2>/dev/null
            umount -l "$MNT_PT" 2>/dev/null
            info "已移除条目 $num (挂载点: $MNT_PT)"
        done
    else
        info "/etc/fstab 条目 (非注释):"
        grep -v "^#\|^$" /etc/fstab | nl -ba
        read -rp "输入要移除的行号 (多个用空格): " REMOVE_LINES
        cp /etc/fstab /etc/fstab.bak.$(date +%Y%m%d%H%M%S)
        for lnum in $(printf '%s' "$REMOVE_LINES" | tr ' ' '\n' | sort -rn); do
            local MNT_PT REAL_LINE
            MNT_PT=$(grep -v "^#\|^$" /etc/fstab | sed -n "${lnum}p" | awk '{print $2}')
            REAL_LINE=$(grep -n "" /etc/fstab | grep -v "^[0-9]*:#\|^[0-9]*:$" | sed -n "${lnum}p" | cut -d: -f1)
            sed -i "${REAL_LINE}d" /etc/fstab 2>/dev/null
            umount -l "$MNT_PT" 2>/dev/null
            info "已移除行 $lnum (挂载点: $MNT_PT)"
        done
    fi
}
uninstall_auto_mount() {
    title "卸载自动挂载功能"
    if [ "$IS_OPENWRT" = "1" ]; then
        rm -f /etc/hotplug.d/block/20-auto-mount
        info "已移除 hotplug 脚本。"
        read -rp "是否同时清除UCI fstab持久挂载配置? (y/N): " CONFIRM_FSTAB
        if [ "$CONFIRM_FSTAB" = "y" ] || [ "$CONFIRM_FSTAB" = "Y" ]; then
            local COUNT
            COUNT=$(uci show fstab 2>/dev/null | grep -c "^fstab\.@mount\[")
            while [ "$COUNT" -gt 0 ]; do
                COUNT=$((COUNT-1))
                uci delete fstab.@mount[$COUNT] 2>/dev/null
            done
            uci commit fstab 2>/dev/null
            info "UCI fstab 挂载条目已清除。"
        fi
    else
        rm -f /bin/auto_block /etc/udev/rules.d/10-auto_block.rules
        udevadm control --reload 2>/dev/null
        info "udev 自动挂载已卸载。"
    fi
}
mount_partition() {
    title "挂载分区"
    local i=1
    local -a parts
    for disk in $(get_all_disks); do
        for part in $(lsblk -n -o NAME "/dev/$disk" 2>/dev/null | grep -v "^$disk$"); do
            part=$(echo "$part" | sed 's/[├└│─]//g' | xargs)
            if [[ -n "$part" ]]; then
                local pmount pfs plabel psize
                pmount=$(lsblk -n -o MOUNTPOINT "/dev/$part" 2>/dev/null)
                pfs=$(lsblk -n -o FSTYPE "/dev/$part" 2>/dev/null)
                if [[ -z "$pmount" && -n "$pfs" ]]; then
                    parts+=("$part")
                    psize=$(lsblk -n -o SIZE "/dev/$part")
                    plabel=$(lsblk -n -o LABEL "/dev/$part")
                    echo "  $i) /dev/$part ($psize) $pfs ${plabel:+[$plabel]}"
                    ((i++))
                fi
            fi
        done
    done
    echo "  0) 取消"
    if [[ ${#parts[@]} -eq 0 ]]; then
        warn "没有可挂载的分区"; pause; return
    fi
    read -rp "选择 [0-$((i-1))]: " choice
    [[ "$choice" == "0" ]] && return
    if [[ "$choice" -ge 1 && "$choice" -lt "$i" ]] 2>/dev/null; then
        local part="${parts[$((choice-1))]}"
        local pfs plabel mpoint
        pfs=$(lsblk -n -o FSTYPE "/dev/$part" 2>/dev/null)
        plabel=$(lsblk -n -o LABEL "/dev/$part" 2>/dev/null)
        local MOUNT_NAME
        MOUNT_NAME=$(make_mount_name "$plabel" "" "$pfs")
        read -rp "输入挂载点 (默认 /mnt/${MOUNT_NAME}): " mpoint
        mpoint="${mpoint:-/mnt/${MOUNT_NAME}}"
        mkdir -p "$mpoint"
        ensure_fs_support "$pfs"
        local real_fs opts
        real_fs=$(get_real_fstype "$pfs")
        opts=$(get_fs_mount_opts "$pfs")
        if mount -t "$real_fs" -o "$opts" "/dev/$part" "$mpoint" 2>/dev/null || mount "/dev/$part" "$mpoint"; then
            chmod 777 "$mpoint" 2>/dev/null
            info "挂载成功！挂载点: $mpoint"
            log "挂载: /dev/$part -> $mpoint"
        else
            error "挂载失败"
        fi
    fi
    pause
}
unmount_partition() {
    title "卸载分区"
    local i=1
    local -a mounts
    while read -r line; do
        local dev mp
        dev=$(echo "$line" | awk '{print $1}')
        mp=$(echo "$line" | awk '{print $3}')
        if [[ "$mp" != "/" && "$mp" != "/boot"* && "$mp" != "/home" && "$mp" != "/var" && "$mp" != "/usr" ]]; then
            mounts+=("$dev:$mp")
            echo "  $i) $dev -> $mp"
            ((i++))
        fi
    done < <(mount | grep "^/dev/")
    echo "  0) 取消"
    if [[ ${#mounts[@]} -eq 0 ]]; then
        warn "没有可卸载的分区"; pause; return
    fi
    read -rp "选择 [0-$((i-1))]: " choice
    [[ "$choice" == "0" ]] && return
    if [[ "$choice" -ge 1 && "$choice" -lt "$i" ]] 2>/dev/null; then
        local mount_info="${mounts[$((choice-1))]}"
        local dev mp
        dev=$(echo "$mount_info" | cut -d: -f1)
        mp=$(echo "$mount_info" | cut -d: -f2-)
        if umount "$mp"; then
            info "卸载成功！"
            log "卸载: $dev from $mp"
        else
            error "卸载失败，可能有进程正在使用"
            echo -e "${CYAN}  lsof $mp${NC}"
            echo -e "${CYAN}  fuser -m $mp${NC}"
        fi
    fi
    pause
}
mount_menu() {
    while true; do
        title "挂载/卸载管理"
        echo -e "${WHITE}当前挂载状态:${NC}"
        lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,LABEL | grep -v "^loop"
        echo "  1) 挂载分区"
        echo "  2) 卸载分区"
        echo "  3) 查看所有挂载详情"
        echo "  0) 返回"
        read -rp "选择 [0-3]: " mount_choice
        case $mount_choice in
            1) mount_partition ;;
            2) unmount_partition ;;
            3) mount | grep "^/dev"; pause ;;
            0) return ;;
            *) error "无效选项"; sleep 1 ;;
        esac
    done
}
test_current_config() {
    title "测试当前挂载配置"
    info "系统: ${OS_ID} | 架构: ${ARCH} | 内核: $(uname -r)"
    info "挂载脚本检查:"
    if [ "$IS_OPENWRT" = "1" ]; then
        if [ -f /etc/hotplug.d/block/20-auto-mount ]; then
            printf "  hotplug脚本: ${GREEN}已安装${NC}\n"
        else
            printf "  hotplug脚本: ${RED}未安装${NC}\n"
        fi
        info "UCI fstab 挂载条目:"
        uci show fstab 2>/dev/null | grep -A5 "@mount" || printf "  (无)\n"
        info "block 设备信息:"
        block info 2>/dev/null
    else
        if [ -x /bin/auto_block ]; then
            printf "  auto_block:  ${GREEN}已安装${NC}\n"
        else
            printf "  auto_block:  ${RED}未安装${NC}\n"
        fi
        if [ -f /etc/udev/rules.d/10-auto_block.rules ]; then
            printf "  udev规则:    ${GREEN}已安装${NC}\n"
        else
            printf "  udev规则:    ${RED}未安装${NC}\n"
        fi
    fi
    info "当前已挂载设备:"
    df -h 2>/dev/null | grep -v "tmpfs\|overlayfs\|rootfs\|udev\|loop"
    info "支持的文件系统:"
    cat /proc/filesystems 2>/dev/null | awk '{print "  "$NF}' | grep -v "nodev"
    info "所有块设备信息:"
    lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINT 2>/dev/null
    if [ "$IS_OPENWRT" = "1" ]; then
        info "实时热插拔事件监控（按回车停止）:"
        logread -f 2>/dev/null | grep -i "auto-mount\|block\|usb" &
        LOGPID=$!
        read -r
        kill $LOGPID 2>/dev/null
    else
        info "实时udev事件监控（Ctrl+C 退出）:"
        udevadm monitor --udev --subsystem-match=block
    fi
}
detect_smb_backend() {
    SMB_BACKEND=""
    SMB_CONF=""
    SMB_SVC=""
    if [ "$IS_OPENWRT" = "1" ]; then
        if opkg list-installed 2>/dev/null | grep -q "^ksmbd-server"; then
            SMB_BACKEND="ksmbd"; SMB_CONF="/etc/ksmbd/smb.conf"; SMB_SVC="ksmbd"
        elif opkg list-installed 2>/dev/null | grep -q "^samba4-server"; then
            SMB_BACKEND="samba4"; SMB_CONF="/etc/samba/smb.conf"; SMB_SVC="samba4"
        fi
    else
        if command -v smbd >/dev/null 2>&1; then
            SMB_BACKEND="samba"; SMB_CONF="/etc/samba/smb.conf"; SMB_SVC="smbd"
        fi
    fi
}
install_smb_backend() {
    if [ -n "$SMB_BACKEND" ]; then
        info "SMB 后端已安装: $SMB_BACKEND"; return 0
    fi
    if [ "$IS_OPENWRT" = "1" ]; then
        printf "  1. ksmbd (轻量推荐)\n  2. samba4 (功能全)\n"
        read -rp "输入选项 (默认1): " SMB_CHOICE
        case "${SMB_CHOICE:-1}" in
            2)
                opkg update && opkg install samba4-server luci-app-samba4 2>/dev/null || { error "samba4安装失败"; return 1; }
                SMB_BACKEND="samba4"; SMB_CONF="/etc/samba/smb.conf"; SMB_SVC="samba4"
                ;;
            *)
                opkg update && opkg install ksmbd-server luci-app-ksmbd ksmbd-utils 2>/dev/null || { error "ksmbd安装失败"; return 1; }
                SMB_BACKEND="ksmbd"; SMB_CONF="/etc/ksmbd/smb.conf"; SMB_SVC="ksmbd"
                ;;
        esac
    else
        ensure_pkg "smbd" "" "samba" "samba" "samba"
        SMB_BACKEND="samba"; SMB_CONF="/etc/samba/smb.conf"; SMB_SVC="smbd"
    fi
    info "$SMB_BACKEND 安装完成。"
}
manage_smb() {
    title "SMB 共享管理"
    detect_smb_backend
    echo "  1. 安装/初始化 SMB 服务"
    echo "  2. 添加新共享"
    echo "  3. 查看当前共享"
    echo "  4. 删除共享"
    echo "  5. 启动/重启 SMB 服务"
    echo "  6. 停止 SMB 服务"
    echo "  0. 返回"
    read -rp "输入选项: " SMB_OPT
    case "$SMB_OPT" in
        1)
            install_smb_backend
            detect_smb_backend
            svc enable "$SMB_SVC" 2>/dev/null
            svc start  "$SMB_SVC" 2>/dev/null
            ;;
        2)
            detect_smb_backend
            [ -z "$SMB_BACKEND" ] && { warn "SMB未安装，请先选择选项1安装。"; return; }
            info "当前已挂载分区:"
            df -h | grep -v "tmpfs\|/dev/loop\|udev" | grep "/" | nl -ba
            read -rp "输入挂载点路径 (如 /mnt/MyDisk): " SHARE_PATH
            [ -d "$SHARE_PATH" ] || { error "目录不存在: $SHARE_PATH"; return; }
            read -rp "共享名称 (默认: $(basename "$SHARE_PATH")): " SHARE_NAME
            SHARE_NAME="${SHARE_NAME:-$(basename "$SHARE_PATH")}"
            read -rp "是否需要密码访问? (y/N): " NEED_PWD
            local GUEST_OK VALID_USERS=""
            if [ "$NEED_PWD" = "y" ] || [ "$NEED_PWD" = "Y" ]; then
                GUEST_OK="no"
                read -rp "请输入访问用户名: " SMB_USER
                read -rsp "请输入访问密码: " SMB_PASS
                printf "\n"
                id "$SMB_USER" >/dev/null 2>&1 || { adduser -D "$SMB_USER" 2>/dev/null || useradd -M "$SMB_USER" 2>/dev/null; }
                printf '%s\n%s\n' "$SMB_PASS" "$SMB_PASS" | smbpasswd -a "$SMB_USER" 2>/dev/null || \
                    printf '%s\n%s\n' "$SMB_PASS" "$SMB_PASS" | ksmbd.adduser -a "$SMB_USER" 2>/dev/null
                VALID_USERS="valid users = $SMB_USER"
            else
                GUEST_OK="yes"
            fi
            local BASE_NAME="$SHARE_NAME" SFX=1
            while grep -q "^\[${SHARE_NAME}\]" "$SMB_CONF" 2>/dev/null; do
                SHARE_NAME="${BASE_NAME}_${SFX}"; SFX=$((SFX+1))
            done
            mkdir -p "$(dirname "$SMB_CONF")"
            cat >> "$SMB_CONF" << SMBEOF

[$SHARE_NAME]
   path = $SHARE_PATH
   browseable = yes
   writable = yes
   guest ok = $GUEST_OK
   read only = no
   create mask = 0777
   directory mask = 0777
   $VALID_USERS
SMBEOF
            chmod 777 "$SHARE_PATH" 2>/dev/null
            svc restart "$SMB_SVC" 2>/dev/null
            local IP_ADDR
            IP_ADDR=$(ip addr show 2>/dev/null | awk '/inet /{print $2}' | grep -v "127.0" | head -1 | cut -d/ -f1)
            info "共享 [$SHARE_NAME] 已创建。访问地址: \\\\${IP_ADDR}\\${SHARE_NAME}"
            ;;
        3)
            detect_smb_backend
            [ -z "$SMB_BACKEND" ] && { warn "SMB未安装。"; return; }
            info "当前共享配置 ($SMB_CONF):"
            grep -E "^\[|path|guest ok|writable" "$SMB_CONF" 2>/dev/null
            ;;
        4)
            detect_smb_backend
            [ -z "$SMB_BACKEND" ] && { warn "SMB未安装。"; return; }
            info "当前共享列表:"
            local SHARES
            SHARES=$(grep '^\[' "$SMB_CONF" | sed 's/^\[//;s/\]$//' | grep -v "^global$")
            printf "%s\n" "$SHARES" | nl -ba
            read -rp "输入要删除的共享编号 (多个用空格): " DEL_NUMS
            cp "$SMB_CONF" "${SMB_CONF}.bak.$(date +%Y%m%d%H%M%S)"
            for num in $DEL_NUMS; do
                local SHARE
                SHARE=$(printf "%s\n" "$SHARES" | sed -n "${num}p")
                [ -z "$SHARE" ] && { warn "无效编号: $num"; continue; }
                sed -i "/^\[$SHARE\]/,/^\[/{/^\[/!d}; /^\[$SHARE\]/d" "$SMB_CONF"
                info "已删除共享: $SHARE"
            done
            svc restart "$SMB_SVC" 2>/dev/null
            ;;
        5) svc restart "${SMB_SVC:-smbd}" 2>/dev/null; info "SMB 服务已重启。" ;;
        6) svc stop   "${SMB_SVC:-smbd}" 2>/dev/null; info "SMB 服务已停止。" ;;
        0) return ;;
        *) warn "无效选项。" ;;
    esac
}
view_logs() {
    title "管理日志"
    if [[ ! -d "$LOG_DIR" ]]; then
        warn "暂无日志"; pause; return
    fi
    local -a logs
    local i=1
    while IFS= read -r -d '' log_file; do
        logs+=("$log_file")
        local size date_info
        size=$(du -h "$log_file" 2>/dev/null | cut -f1)
        date_info=$(stat -c %y "$log_file" 2>/dev/null | cut -d. -f1)
        echo "  $i) $(basename "$log_file") - $size - $date_info"
        ((i++))
    done < <(find "$LOG_DIR" -type f \( -name "*.txt" -o -name "*.log" \) -print0 2>/dev/null | sort -z)
    if [[ ${#logs[@]} -eq 0 ]]; then
        warn "暂无日志"; pause; return
    fi
    echo "  0) 返回"
    read -rp "选择 [0-$((i-1))]: " choice
    [[ "$choice" == "0" ]] && return
    if [[ "$choice" -ge 1 && "$choice" -lt "$i" ]] 2>/dev/null; then
        less "${logs[$((choice-1))]}"
    fi
}
show_help() {
    title "帮助信息"
    echo -e "${WHITE}文件系统选择指南:${NC}"
    echo -e "  ${CYAN}ext4${NC}    Linux 默认，稳定可靠，推荐大多数场景"
    echo -e "  ${CYAN}xfs${NC}     高性能，适合大文件和数据库"
    echo -e "  ${CYAN}btrfs${NC}   支持快照、压缩、RAID"
    echo -e "  ${CYAN}ntfs${NC}    Windows 兼容，跨平台数据交换"
    echo -e "  ${CYAN}fat32${NC}   最大兼容性，单文件不超过 4GB"
    echo -e "  ${CYAN}exfat${NC}   大文件支持，U盘/移动硬盘推荐"
    echo -e "  ${CYAN}f2fs${NC}    Flash 友好，适合 eMMC/SSD"
    echo -e "  ${CYAN}hfsplus${NC} macOS 兼容"
    echo -e "${WHITE}SMART 指标说明:${NC}"
    echo -e "  Reallocated_Sector_Ct   已重映射扇区（硬盘已处理）"
    echo -e "  Current_Pending_Sector  待处理坏扇区 ${YELLOW}（需关注！）${NC}"
    echo -e "  Offline_Uncorrectable   无法修复扇区 ${RED}（严重！）${NC}"
    echo -e "${WHITE}修复级别说明:${NC}"
    echo "  快速修复  仅修复已知坏扇区，数据安全"
    echo "  标准修复  扫描+修复，尽量保留数据"
    echo "  强力修复  破坏性修复，数据会丢失"
    echo "  完整重建  修复+分区+格式化"
    echo -e "${WHITE}挂载命名规则:${NC}"
    echo "  优先使用磁盘卷标作为挂载点名称，保证重启后路径不变"
    echo "  无卷标时使用 UUID 前8位命名，确保唯一性"
    echo -e "${WHITE}建议:${NC}"
    echo -e "  Pending > 0   ${YELLOW}尽快修复${NC}"
    echo -e "  Pending > 100 ${RED}考虑更换硬盘${NC}"
    echo -e "  硬盘异响      ${RED}立即备份数据${NC}"
    echo -e "${WHITE}日志位置:${NC} $LOG_DIR/"
    pause
}
show_main_menu() {
    printf "${CYAN}硬盘智能管理与修复工具 v3.0${NC}\n"
    printf "${WHITE}当前硬盘状态:${NC}\n"
    printf -- "------------------------------------------------------------\n"
    for disk in $(get_all_disks); do
        local size model info health pending r use_status=""
        size=$(lsblk -d -n -o SIZE "/dev/$disk")
        model=$(smartctl -i "/dev/$disk" 2>/dev/null | grep "Device Model" | cut -d: -f2 | xargs 2>/dev/null)
        info=$(get_disk_info "$disk")
        IFS='|' read -r m s health pending r u h t <<< "$info"
        local status
        status=$(get_disk_status "$pending" "$r" "$health")
        check_disk_in_use "$disk" && use_status="${RED}[系统]${NC}"
        check_disk_mounted "$disk" && [ -z "$use_status" ] && use_status="${YELLOW}[挂载]${NC}"
        echo -e "  /dev/$disk  $size  ${model:-未知}  $status $use_status"
    done
    printf -- "------------------------------------------------------------\n"
    echo ""
    echo -e "${GREEN}信息查看:${NC}"
    echo "   1) 查看所有硬盘概览"
    echo "   2) 查看单个硬盘 SMART 详情"
    echo -e "${GREEN}硬盘修复:${NC}"
    echo "   3) 硬盘检测与修复"
    echo "   4) 一键扫描修复所有问题硬盘"
    echo -e "${GREEN}格式化与分区:${NC}"
    echo "   5) 格式化硬盘（多格式可选）"
    echo "   6) 分区管理"
    echo -e "${GREEN}挂载管理:${NC}"
    echo "   7) 安装自动挂载 (hotplug/udev)"
    echo "   8) 配置持久挂载 (fstab)"
    echo "   9) 查看持久挂载配置"
    echo "  10) 移除持久挂载条目"
    echo "  11) 快速挂载/卸载"
    echo "  12) 卸载自动挂载功能"
    echo "  13) 测试挂载配置 & 设备监控"
    echo -e "${GREEN}其他功能:${NC}"
    echo "  14) SMB 共享管理"
    echo "  15) 查看管理日志"
    echo "  16) 帮助信息"
    echo "   0) 退出"
    echo ""
    read -rp "请输入选项 [0-16]: " choice
    case $choice in
        1)  show_all_disks_overview ;;
        2)  view_disk_detail ;;
        3)  repair_disk_menu ;;
        4)  auto_repair_all ;;
        5)  format_disk_menu ;;
        6)  partition_menu ;;
        7)  install_auto_mount ;;
        8)  manage_persistent_mount ;;
        9)  show_persistent_mounts ;;
        10) remove_persistent_mount ;;
        11) mount_menu ;;
        12) uninstall_auto_mount ;;
        13) test_current_config ;;
        14) manage_smb ;;
        15) view_logs ;;
        16) show_help ;;
        0)  info "退出程序。"; exit 0 ;;
        *)  warn "无效选项，请重试。"; sleep 1 ;;
    esac
}
init() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 此脚本需要 root 权限运行${NC}"
        exit 1
    fi
    mkdir -p "$LOG_DIR"
    detect_env
    ensure_base_deps
}
main() {
    init
    while true; do
        show_main_menu
    done
}
main "$@"
