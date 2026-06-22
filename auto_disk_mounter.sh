#!/bin/sh

# ── 颜色输出 ────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { printf "${GREEN}[INFO]${NC}  %s\n" "$*"; }
warn()    { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
error()   { printf "${RED}[ERROR]${NC} %s\n" "$*"; }
title()   { printf "\n${CYAN}══════════ %s ══════════${NC}\n" "$*"; }

# ── 环境检测 ────────────────────────────────────────────────
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
    OS_ID=""

    # 检测 OpenWrt
    if [ -f /etc/openwrt_release ]; then
        IS_OPENWRT=1
        . /etc/openwrt_release 2>/dev/null
        OS_ID="openwrt"
        PKG_MANAGER="opkg"
        INSTALL_CMD="opkg update && opkg install"
        # OpenWrt 使用 procd / /etc/init.d/
        SVC_START="/etc/init.d/%s start"
        SVC_STOP="/etc/init.d/%s stop"
        SVC_ENABLE="/etc/init.d/%s enable"
        SVC_RESTART="/etc/init.d/%s restart"
        info "检测到 OpenWrt: ${DISTRIB_RELEASE} | 架构: ${ARCH}"
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
        if   command -v apt    >/dev/null 2>&1; then PKG_MANAGER="apt";    INSTALL_CMD="apt-get update && apt-get install -y"
        elif command -v dnf    >/dev/null 2>&1; then PKG_MANAGER="dnf";    INSTALL_CMD="dnf install -y"
        elif command -v yum    >/dev/null 2>&1; then PKG_MANAGER="yum";    INSTALL_CMD="yum install -y"
        elif command -v pacman >/dev/null 2>&1; then PKG_MANAGER="pacman"; INSTALL_CMD="pacman -Syu --noconfirm"
        fi
        info "检测到系统: ${PRETTY_NAME:-$OS_ID} | 架构: ${ARCH} | 包管理: ${PKG_MANAGER:-未知}"
    else
        warn "无法识别系统类型，部分功能可能受限。"
    fi
}

# ── 架构自适应依赖安装 ───────────────────────────────────────
ensure_pkg() {
    # $1=命令检测名  $2=opkg包名  $3=apt包名  $4=dnf/yum包名
    local cmd="$1" opkg_pkg="$2" apt_pkg="$3" dnf_pkg="$4"
    if command -v "$cmd" >/dev/null 2>&1; then
        return 0
    fi
    warn "缺少依赖: $cmd，尝试安装..."
    if [ "$IS_OPENWRT" = "1" ]; then
        opkg update >/dev/null 2>&1
        opkg install "$opkg_pkg" || { error "安装 $opkg_pkg 失败"; return 1; }
    elif [ "$PKG_MANAGER" = "apt" ]; then
        apt-get install -y "$apt_pkg" || { error "安装 $apt_pkg 失败"; return 1; }
    elif [ "$PKG_MANAGER" = "dnf" ] || [ "$PKG_MANAGER" = "yum" ]; then
        $PKG_MANAGER install -y "$dnf_pkg" || { error "安装 $dnf_pkg 失败"; return 1; }
    else
        error "无法自动安装 $cmd，请手动安装。"
        return 1
    fi
    info "$cmd 安装完成。"
}

ensure_base_deps() {
    title "检查基础依赖"
    ensure_pkg "blkid"    "util-linux"        "util-linux"     "util-linux"
    ensure_pkg "lsblk"    "lsblk"             "util-linux"     "util-linux"
    ensure_pkg "mkfs.ext4" "e2fsprogs"        "e2fsprogs"      "e2fsprogs"
    if [ "$IS_OPENWRT" = "1" ]; then
        ensure_pkg "block" "block-mount"       ""               ""
        ensure_pkg "uci"   "uci"              ""               ""
        ensure_pkg "kmod-fs-ext4" "kmod-fs-ext4" ""            ""
        # 根据架构追加内核模块
        case "$ARCH" in
            aarch64*) ensure_pkg "" "kmod-usb3"         "" "" ;;
            arm*)     ensure_pkg "" "kmod-usb2"         "" "" ;;
            x86_64)   ensure_pkg "" "kmod-usb3"         "" "" ;;
        esac
        # 常用文件系统支持
        opkg list-installed | grep -q "kmod-fs-vfat"  || opkg install kmod-fs-vfat  2>/dev/null
        opkg list-installed | grep -q "kmod-fs-ntfs3" || opkg install kmod-fs-ntfs3 2>/dev/null || \
        opkg list-installed | grep -q "ntfs-3g"       || opkg install ntfs-3g        2>/dev/null
        opkg list-installed | grep -q "kmod-fs-exfat" || opkg install kmod-fs-exfat 2>/dev/null
    fi
    info "基础依赖检查完成。"
}

# ── svc 辅助：执行服务命令 ───────────────────────────────────
svc() {
    # $1=action(start/stop/enable/restart) $2=service_name
    local action="$1" svc_name="$2"
    local tmpl=""
    case "$action" in
        start)   tmpl="$SVC_START"   ;;
        stop)    tmpl="$SVC_STOP"    ;;
        enable)  tmpl="$SVC_ENABLE"  ;;
        restart) tmpl="$SVC_RESTART" ;;
    esac
    # 简单字符串替换 %s -> svc_name
    local cmd; cmd=$(printf "$tmpl" "$svc_name")
    eval "$cmd" 2>/dev/null
}

# ════════════════════════════════════════════════════════════
#  模块 1：自动挂载安装（OpenWrt hotplug.d / Linux udev）
# ════════════════════════════════════════════════════════════

# ── OpenWrt hotplug 脚本内容 ─────────────────────────────────
HOTPLUG_CONTENT='#!/bin/sh
# /etc/hotplug.d/block/20-auto-mount
# OpenWrt 自动挂载块设备分区

[ "$ACTION" = "add" ] || [ "$ACTION" = "remove" ] || exit 0
[ "$DEVTYPE" = "partition" ] || exit 0

# 获取设备UUID
eval $(blkid -o udev -p /dev/${DEVICENAME} 2>/dev/null)
[ -z "$ID_FS_UUID" ] && exit 0

# 读取用户配置的挂载根目录（默认 /mnt）
MNT_BASE=$(uci get fstab.@global[0].auto_mount_base 2>/dev/null || echo "/mnt")

# 生成挂载点：取UUID前8位
SHORT_UUID="${ID_FS_UUID%%-*}"
MOUNT_POINT="${MNT_BASE}/${SHORT_UUID}"

# 检查是否为系统根设备
DEVPATH_PARENT="${DEVPATH%/*}"
SYS_DEV="${DEVPATH_PARENT##*/}"
IS_SYS_ROOT=$(df 2>/dev/null | awk -v d="$SYS_DEV" '"'"'$1~d{print $6}'"'"')
[ "$IS_SYS_ROOT" = "/" ] && exit 0

case "$ACTION" in
    add)
        [ -d "$MOUNT_POINT" ] || mkdir -p "$MOUNT_POINT"
        # 根据文件系统类型选择挂载选项
        case "$ID_FS_TYPE" in
            vfat|exfat)
                MOUNT_OPTS="rw,utf8,uid=0,gid=0,umask=000"
                ;;
            ntfs)
                MOUNT_OPTS="rw,uid=0,gid=0,umask=000"
                ;;
            *)
                MOUNT_OPTS="rw,defaults"
                ;;
        esac
        mount -t "$ID_FS_TYPE" -o "$MOUNT_OPTS" "/dev/${DEVICENAME}" "$MOUNT_POINT" 2>/dev/null \
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

# ── Linux udev 脚本内容 ──────────────────────────────────────
UDEV_BLOCK_CONTENT='#!/bin/bash
[ "$DEVTYPE" = "partition" ] || exit 0
eval $(blkid -o udev -p "$DEVNAME" 2>/dev/null)
[ -z "$ID_FS_UUID" ] && exit 0
SHORT_UUID="${ID_FS_UUID%%-*}"
MOUNT_POINT="/mnt/${SHORT_UUID}"
DEVPATH_PARENT="${DEVPATH%/*}"
SYS_DEV="${DEVPATH_PARENT##*/}"
IS_SYS_ROOT=$(df 2>/dev/null | awk -v d="$SYS_DEV" '"'"'$1~d{print $6}'"'"')
[ "$IS_SYS_ROOT" = "/" ] && exit 0
case "$ACTION" in
    add)
        [ -d "$MOUNT_POINT" ] || mkdir -p "$MOUNT_POINT"
        systemd-mount --no-block --collect "$DEVNAME" "$MOUNT_POINT" 2>/dev/null \
            || mount "$DEVNAME" "$MOUNT_POINT" 2>/dev/null
        chmod -R 777 "$MOUNT_POINT"
        ;;
    remove)
        systemd-mount -u "$MOUNT_POINT" 2>/dev/null || umount -l "$MOUNT_POINT" 2>/dev/null
        sync; rmdir "$MOUNT_POINT" 2>/dev/null
        ;;
esac
'

UDEV_RULES_CONTENT='KERNEL!="sd[a-z][0-9]|hd[a-z][0-9]|mmcblk[0-9]p[0-9]", GOTO="uuid_auto_mount_end"
SUBSYSTEM!="block", GOTO="uuid_auto_mount_end"
IMPORT{program}="/sbin/blkid -o udev -p %N"
ENV{ID_FS_TYPE}=="", GOTO="uuid_auto_mount_end"
ENV{ID_FS_UUID}=="", GOTO="uuid_auto_mount_end"
ACTION=="add|remove", RUN+="/bin/auto_block"
LABEL="uuid_auto_mount_end"'

# ── 安装自动挂载 ─────────────────────────────────────────────
install_auto_mount() {
    title "安装自动挂载功能"
    ensure_base_deps

    # 交互：自定义挂载根目录
    printf "${BLUE}请输入挂载根目录${NC} (默认 /mnt，按回车跳过): "
    read MNT_BASE_INPUT
    MNT_BASE="${MNT_BASE_INPUT:-/mnt}"
    [ -d "$MNT_BASE" ] || mkdir -p "$MNT_BASE"
    info "挂载根目录: $MNT_BASE"

    if [ "$IS_OPENWRT" = "1" ]; then
        # 写入 hotplug 脚本
        mkdir -p /etc/hotplug.d/block
        printf '%s' "$HOTPLUG_CONTENT" > /etc/hotplug.d/block/20-auto-mount
        chmod +x /etc/hotplug.d/block/20-auto-mount

        # 记录用户自定义挂载根目录到 UCI（写入 fstab global 扩展字段）
        uci set fstab.@global[0].auto_mount_base="$MNT_BASE" 2>/dev/null
        uci commit fstab 2>/dev/null

        # 确保 fstab 服务已启用
        /etc/init.d/fstab enable 2>/dev/null
        /etc/init.d/fstab start  2>/dev/null

        info "OpenWrt hotplug 自动挂载安装完成。"
        info "脚本位置: /etc/hotplug.d/block/20-auto-mount"
    else
        # Linux: udev 方式
        printf '%s' "$UDEV_BLOCK_CONTENT" > /bin/auto_block
        chmod +x /bin/auto_block
        printf '%s\n' "$UDEV_RULES_CONTENT" > /etc/udev/rules.d/10-auto_block.rules
        udevadm control --reload 2>/dev/null
        info "udev 自动挂载安装完成。"
    fi
}

# ════════════════════════════════════════════════════════════
#  模块 2：UCI fstab 持久挂载（OpenWrt）/ /etc/fstab（Linux）
# ════════════════════════════════════════════════════════════
manage_persistent_mount() {
    title "管理持久挂载（重启后自动挂载）"
    ensure_base_deps

    # 列出当前块设备
    echo ""
    info "扫描当前块设备分区..."
    if [ "$IS_OPENWRT" = "1" ]; then
        block info 2>/dev/null | grep -E "UUID|MOUNT|TYPE|DEVICE" | \
            awk '/DEVICE/{dev=$2} /UUID/{uuid=$2} /TYPE/{type=$2} /MOUNT/{mnt=$2;
                printf "  设备:%-12s UUID:%-38s 类型:%-8s 挂载:%s\n",dev,uuid,type,mnt}'
        echo ""
        # 获取所有未挂载到 / 的分区
        PART_LIST=$(block info 2>/dev/null | awk -F= '
            /^\/dev\//{dev=$1}
            /UUID/{uuid=$2}
            /TYPE/{type=$2}
            /MOUNT/{mnt=$2; if(mnt!="/" && mnt!="" ) print dev" "uuid" "type" "mnt}
            !/MOUNT/{if(dev!="" && uuid!="" && type!="") tmp=dev" "uuid" "type}
        ' | sed 's/"//g')
    else
        lsblk -o NAME,UUID,FSTYPE,MOUNTPOINT -P 2>/dev/null | \
            awk -F'"' '{printf "  %-10s UUID:%-38s 类型:%-8s 挂载:%s\n",$2,$4,$6,$8}' | \
            grep -v "^  NAME"
        PART_LIST=$(lsblk -o PATH,UUID,FSTYPE,MOUNTPOINT -n 2>/dev/null | \
            awk '{if($4!="/" && $2!="") print $1" "$2" "$3" "$4}')
    fi

    echo ""
    # 将设备列表按行编号展示
    OLD_IFS="$IFS"; IFS='
'
    PART_ARRAY=""
    IDX=0
    for line in $PART_LIST; do
        [ -z "$(echo $line | tr -d ' ')" ] && continue
        IDX=$((IDX+1))
        printf "  ${YELLOW}%2d.${NC} %s\n" $IDX "$line"
        PART_ARRAY="${PART_ARRAY}${IDX}:${line}
"
    done
    IFS="$OLD_IFS"

    if [ "$IDX" = "0" ]; then
        warn "未找到可配置的分区。请先插入设备。"
        return
    fi

    printf "\n${BLUE}请输入要持久挂载的分区编号${NC} (多个用空格分隔，如 1 3): "
    read SELECTED_NUMS

    for num in $SELECTED_NUMS; do
        # 从 PART_ARRAY 中提取对应行
        PART_LINE=$(echo "$PART_ARRAY" | grep "^${num}:" | sed "s/^${num}://")
        [ -z "$PART_LINE" ] && { warn "无效编号: $num，跳过。"; continue; }

        DEV=$(echo "$PART_LINE"  | awk '{print $1}')
        UUID=$(echo "$PART_LINE" | awk '{print $2}' | sed 's/UUID=//I;s/"//g')
        FSTYPE=$(echo "$PART_LINE" | awk '{print $3}' | sed 's/TYPE=//I;s/"//g')
        CURRENT_MNT=$(echo "$PART_LINE" | awk '{print $4}' | sed 's/"//g')

        # 交互：询问挂载点
        printf "${BLUE}为设备 ${DEV} (UUID:${UUID}) 设置挂载点${NC}"
        printf " (当前:${CURRENT_MNT:-未挂载}, 留空用 /mnt/${UUID%%-*}): "
        read USER_MNT
        MOUNT_PT="${USER_MNT:-/mnt/${UUID%%-*}}"

        # 交互：询问挂载选项
        printf "${BLUE}挂载选项${NC} (留空使用默认值"
        case "$FSTYPE" in
            vfat|exfat) printf " 'rw,utf8,uid=0,gid=0,umask=000'" ;;
            ntfs*)      printf " 'rw,uid=0,gid=0,umask=000'" ;;
            *)          printf " 'rw,defaults'" ;;
        esac
        printf "): "
        read USER_OPTS
        if [ -z "$USER_OPTS" ]; then
            case "$FSTYPE" in
                vfat|exfat) OPTS="rw,utf8,uid=0,gid=0,umask=000" ;;
                ntfs*)      OPTS="rw,uid=0,gid=0,umask=000" ;;
                *)          OPTS="rw,defaults" ;;
            esac
        else
            OPTS="$USER_OPTS"
        fi

        [ -d "$MOUNT_PT" ] || mkdir -p "$MOUNT_PT"

        if [ "$IS_OPENWRT" = "1" ]; then
            # ── OpenWrt：UCI fstab 配置 ──
            # 检查是否已存在相同UUID的条目
            EXIST=$(uci show fstab 2>/dev/null | grep "uuid='$UUID'" | head -1 | cut -d. -f1-2)
            if [ -n "$EXIST" ]; then
                warn "UUID $UUID 已存在UCI fstab中，更新配置..."
                uci set "${EXIST}.target=${MOUNT_PT}"
                uci set "${EXIST}.options=${OPTS}"
                uci set "${EXIST}.enabled=1"
            else
                uci add fstab mount > /dev/null
                uci set fstab.@mount[-1].uuid="$UUID"
                uci set fstab.@mount[-1].target="$MOUNT_PT"
                uci set fstab.@mount[-1].fstype="$FSTYPE"
                uci set fstab.@mount[-1].options="$OPTS"
                uci set fstab.@mount[-1].enabled=1
                uci set fstab.@mount[-1].device="$DEV"
            fi
            uci commit fstab
            # 立即挂载
            block mount 2>/dev/null || \
                mount -t "$FSTYPE" -o "$OPTS" "$DEV" "$MOUNT_PT" 2>/dev/null
            chmod 777 "$MOUNT_PT" 2>/dev/null
            info "UCI fstab 已配置: $DEV -> $MOUNT_PT (重启后自动生效)"

        else
            # ── Linux：/etc/fstab 配置 ──
            # 检查是否已存在
            if grep -q "UUID=$UUID" /etc/fstab 2>/dev/null; then
                warn "UUID=$UUID 已在 /etc/fstab 中，跳过写入。"
            else
                cp /etc/fstab /etc/fstab.bak.$(date +%Y%m%d%H%M%S)
                printf "UUID=%s\t%s\t%s\t%s\t0\t2\n" \
                    "$UUID" "$MOUNT_PT" "$FSTYPE" "$OPTS" >> /etc/fstab
                info "已写入 /etc/fstab: UUID=$UUID -> $MOUNT_PT"
            fi
            mount -a 2>/dev/null || mount -t "$FSTYPE" -o "$OPTS" "$DEV" "$MOUNT_PT" 2>/dev/null
            chmod 777 "$MOUNT_PT" 2>/dev/null
            info "持久挂载设置完成: $DEV -> $MOUNT_PT"
        fi
    done
}

# ── 查看当前持久挂载配置 ─────────────────────────────────────
show_persistent_mounts() {
    title "当前持久挂载配置"
    if [ "$IS_OPENWRT" = "1" ]; then
        info "UCI fstab 挂载条目:"
        uci show fstab 2>/dev/null | grep -E "^fstab\.@mount" || echo "  (无)"
        echo ""
        info "当前已挂载设备:"
        df -h 2>/dev/null | grep -v "tmpfs\|overlayfs\|rootfs"
    else
        info "/etc/fstab 内容 (非注释行):"
        grep -v "^#\|^$" /etc/fstab 2>/dev/null || echo "  (无)"
        echo ""
        info "当前已挂载设备:"
        df -h 2>/dev/null | grep -v "tmpfs\|udev\|/dev/loop"
    fi
}

# ── 移除持久挂载条目 ─────────────────────────────────────────
remove_persistent_mount() {
    title "移除持久挂载条目"
    if [ "$IS_OPENWRT" = "1" ]; then
        info "当前UCI fstab挂载条目:"
        ENTRIES=$(uci show fstab 2>/dev/null | grep "\.uuid=" | nl -ba)
        echo "$ENTRIES"
        [ -z "$ENTRIES" ] && { warn "无配置条目。"; return; }

        printf "${BLUE}输入要移除的条目序号${NC} (多个用空格): "
        read REMOVE_NUMS
        # 逆序删除避免索引偏移
        for num in $(echo "$REMOVE_NUMS" | tr ' ' '\n' | sort -rn); do
            IDX=$((num-1))
            MNT_PT=$(uci get fstab.@mount[$IDX].target 2>/dev/null)
            uci delete fstab.@mount[$IDX] 2>/dev/null
            uci commit fstab 2>/dev/null
            umount -l "$MNT_PT" 2>/dev/null
            info "已移除条目 $num (挂载点: $MNT_PT)"
        done
    else
        info "/etc/fstab 条目 (非注释):"
        grep -v "^#\|^$" /etc/fstab | nl -ba
        printf "${BLUE}输入要移除的行号${NC} (多个用空格): "
        read REMOVE_LINES
        cp /etc/fstab /etc/fstab.bak.$(date +%Y%m%d%H%M%S)
        for lnum in $(echo "$REMOVE_LINES" | tr ' ' '\n' | sort -rn); do
            MNT_PT=$(grep -v "^#\|^$" /etc/fstab | sed -n "${lnum}p" | awk '{print $2}')
            # 删除 /etc/fstab 中对应实际行
            REAL_LINE=$(grep -n "" /etc/fstab | grep -v "^[0-9]*:#\|^[0-9]*:$" | \
                        sed -n "${lnum}p" | cut -d: -f1)
            sed -i "${REAL_LINE}d" /etc/fstab 2>/dev/null
            umount -l "$MNT_PT" 2>/dev/null
            info "已移除行 $lnum (挂载点: $MNT_PT)"
        done
    fi
}

# ════════════════════════════════════════════════════════════
#  模块 3：卸载自动挂载功能
# ════════════════════════════════════════════════════════════
uninstall_auto_mount() {
    title "卸载自动挂载功能"
    if [ "$IS_OPENWRT" = "1" ]; then
        rm -f /etc/hotplug.d/block/20-auto-mount
        info "已移除 hotplug 脚本。"
        printf "${YELLOW}是否同时清除UCI fstab持久挂载配置?${NC} (y/N): "
        read CONFIRM_FSTAB
        if [ "$CONFIRM_FSTAB" = "y" ] || [ "$CONFIRM_FSTAB" = "Y" ]; then
            # 逆序删除所有 mount 条目
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

# ════════════════════════════════════════════════════════════
#  模块 4：测试当前配置
# ════════════════════════════════════════════════════════════
test_current_config() {
    title "测试当前挂载配置"
    echo ""
    info "── 系统信息 ──"
    echo "  系统   : ${OS_ID}"
    echo "  架构   : ${ARCH}"
    echo "  内核   : $(uname -r)"

    echo ""
    info "── 挂载脚本检查 ──"
    if [ "$IS_OPENWRT" = "1" ]; then
        if [ -f /etc/hotplug.d/block/20-auto-mount ]; then
            printf "  hotplug脚本: ${GREEN}已安装${NC}\n"
        else
            printf "  hotplug脚本: ${RED}未安装${NC}\n"
        fi
        echo ""
        info "── UCI fstab 挂载条目 ──"
        uci show fstab 2>/dev/null | grep -A5 "@mount" || echo "  (无)"
        echo ""
        info "── block 设备信息 ──"
        block info 2>/dev/null
    else
        [ -x /bin/auto_block ] && \
            printf "  auto_block:  ${GREEN}已安装${NC}\n" || \
            printf "  auto_block:  ${RED}未安装${NC}\n"
        [ -f /etc/udev/rules.d/10-auto_block.rules ] && \
            printf "  udev规则:    ${GREEN}已安装${NC}\n" || \
            printf "  udev规则:    ${RED}未安装${NC}\n"
    fi

    echo ""
    info "── 当前已挂载设备 ──"
    df -h 2>/dev/null | grep -v "tmpfs\|overlayfs\|rootfs\|udev\|loop"

    echo ""
    info "── 支持的文件系统 ──"
    if [ "$IS_OPENWRT" = "1" ]; then
        ls /proc/filesystems 2>/dev/null | head -1
        cat /proc/filesystems 2>/dev/null | awk '{print "  "$NF}' | grep -v "nodev"
    else
        cat /proc/filesystems 2>/dev/null | awk '{print "  "$NF}' | grep -v "nodev"
    fi

    if [ "$IS_OPENWRT" = "1" ]; then
        echo ""
        info "── 实时热插拔事件监控（Ctrl+C 退出）──"
        logread -f 2>/dev/null | grep -i "auto-mount\|block\|usb" &
        LOGPID=$!
        printf "${YELLOW}按回车键停止监控...${NC}\n"
        read
        kill $LOGPID 2>/dev/null
    else
        echo ""
        info "── 实时udev事件监控（Ctrl+C 退出）──"
        udevadm monitor --udev --subsystem-match=block
    fi
}

# ════════════════════════════════════════════════════════════
#  模块 5：SMB 共享管理（ksmbd / samba4）
# ════════════════════════════════════════════════════════════

# 检测SMB后端
detect_smb_backend() {
    SMB_BACKEND=""
    SMB_CONF=""
    SMB_SVC=""

    if [ "$IS_OPENWRT" = "1" ]; then
        # ksmbd (内核SMB，推荐)
        if opkg list-installed 2>/dev/null | grep -q "^ksmbd-server"; then
            SMB_BACKEND="ksmbd"
            SMB_CONF="/etc/ksmbd/smb.conf"
            SMB_SVC="ksmbd"
        # samba4
        elif opkg list-installed 2>/dev/null | grep -q "^samba4-server"; then
            SMB_BACKEND="samba4"
            SMB_CONF="/etc/samba/smb.conf"
            SMB_SVC="samba4"
        fi
    else
        if command -v smbd >/dev/null 2>&1; then
            SMB_BACKEND="samba"
            SMB_CONF="/etc/samba/smb.conf"
            SMB_SVC="smbd"
        fi
    fi
}

install_smb_backend() {
    if [ -n "$SMB_BACKEND" ]; then
        info "SMB 后端已安装: $SMB_BACKEND"
        return 0
    fi

    if [ "$IS_OPENWRT" = "1" ]; then
        echo "选择SMB后端:"
        echo "  1. ksmbd (内核态，轻量推荐，适合路由器)"
        echo "  2. samba4 (功能全，内存占用较高)"
        printf "${BLUE}输入选项${NC} (默认1): "
        read SMB_CHOICE
        case "${SMB_CHOICE:-1}" in
            2)
                opkg update && opkg install samba4-server luci-app-samba4 2>/dev/null || \
                    { error "samba4安装失败"; return 1; }
                SMB_BACKEND="samba4"; SMB_CONF="/etc/samba/smb.conf"; SMB_SVC="samba4"
                ;;
            *)
                opkg update && opkg install ksmbd-server luci-app-ksmbd ksmbd-utils 2>/dev/null || \
                    { error "ksmbd安装失败"; return 1; }
                SMB_BACKEND="ksmbd"; SMB_CONF="/etc/ksmbd/smb.conf"; SMB_SVC="ksmbd"
                ;;
        esac
    else
        SAMBA_PKG="samba"
        [ "$PKG_MANAGER" = "apt" ] && SAMBA_PKG="samba"
        [ "$PKG_MANAGER" = "dnf" ] || [ "$PKG_MANAGER" = "yum" ] && SAMBA_PKG="samba"
        eval "$INSTALL_CMD $SAMBA_PKG" || { error "Samba安装失败"; return 1; }
        SMB_BACKEND="samba"; SMB_CONF="/etc/samba/smb.conf"; SMB_SVC="smbd"
    fi
    info "$SMB_BACKEND 安装完成。"
}

manage_smb() {
    title "SMB 共享管理"
    detect_smb_backend

    echo "SMB 操作:"
    echo "  1. 安装/初始化 SMB 服务"
    echo "  2. 添加新共享"
    echo "  3. 查看当前共享"
    echo "  4. 删除共享"
    echo "  5. 启动/重启 SMB 服务"
    echo "  6. 停止 SMB 服务"
    echo "  0. 返回主菜单"
    printf "${BLUE}输入选项${NC}: "
    read SMB_OPT

    case "$SMB_OPT" in
        1)  # 安装
            install_smb_backend
            detect_smb_backend
            svc enable "$SMB_SVC" 2>/dev/null
            svc start  "$SMB_SVC" 2>/dev/null
            ;;

        2)  # 添加共享
            detect_smb_backend
            [ -z "$SMB_BACKEND" ] && { warn "SMB未安装，请先选择选项1安装。"; return; }

            info "当前已挂载分区:"
            if [ "$IS_OPENWRT" = "1" ]; then
                df -h | grep "/mnt" | nl -ba
            else
                df -h | grep -v "tmpfs\|/dev/loop\|udev" | grep "/" | nl -ba
            fi

            printf "${BLUE}输入挂载点路径${NC} (如 /mnt/sda1): "
            read SHARE_PATH
            [ -d "$SHARE_PATH" ] || { error "目录不存在: $SHARE_PATH"; return; }

            printf "${BLUE}共享名称${NC} (默认: $(basename $SHARE_PATH)): "
            read SHARE_NAME
            SHARE_NAME="${SHARE_NAME:-$(basename $SHARE_PATH)}"

            printf "${BLUE}是否需要密码访问?${NC} (y/N): "
            read NEED_PWD
            if [ "$NEED_PWD" = "y" ] || [ "$NEED_PWD" = "Y" ]; then
                GUEST_OK="no"
                printf "${BLUE}请输入访问用户名${NC}: "
                read SMB_USER
                printf "${BLUE}请输入访问密码${NC}: "
                read -s SMB_PASS
                echo ""
                # 创建系统用户（如不存在）
                id "$SMB_USER" >/dev/null 2>&1 || \
                    { adduser -D "$SMB_USER" 2>/dev/null || useradd -M "$SMB_USER" 2>/dev/null; }
                printf '%s\n%s\n' "$SMB_PASS" "$SMB_PASS" | smbpasswd -a "$SMB_USER" 2>/dev/null || \
                    printf '%s\n%s\n' "$SMB_PASS" "$SMB_PASS" | ksmbd.adduser -a "$SMB_USER" 2>/dev/null
                VALID_USERS="valid users = $SMB_USER"
            else
                GUEST_OK="yes"
                VALID_USERS=""
            fi

            # 生成唯一共享名
            BASE_NAME="$SHARE_NAME"; SFX=1
            while grep -q "^\[${SHARE_NAME}\]" "$SMB_CONF" 2>/dev/null; do
                SHARE_NAME="${BASE_NAME}_${SFX}"; SFX=$((SFX+1))
            done

            # 写入配置
            mkdir -p "$(dirname $SMB_CONF)"
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
            IP_ADDR=$(ip addr show 2>/dev/null | awk '/inet /{print $2}' | grep -v "127.0" | head -1 | cut -d/ -f1)
            info "共享 [$SHARE_NAME] 已创建。"
            info "访问地址: \\\\${IP_ADDR}\\${SHARE_NAME}"
            ;;

        3)  # 查看
            detect_smb_backend
            [ -z "$SMB_BACKEND" ] && { warn "SMB未安装。"; return; }
            info "当前共享配置 ($SMB_CONF):"
            grep -E "^\[|path|guest ok|writable" "$SMB_CONF" 2>/dev/null
            ;;

        4)  # 删除共享
            detect_smb_backend
            [ -z "$SMB_BACKEND" ] && { warn "SMB未安装。"; return; }
            info "当前共享列表:"
            SHARES=$(grep '^\[' "$SMB_CONF" | sed 's/^\[//;s/\]$//' | grep -v "^global$")
            echo "$SHARES" | nl -ba
            printf "${BLUE}输入要删除的共享编号${NC} (多个用空格): "
            read DEL_NUMS
            cp "$SMB_CONF" "${SMB_CONF}.bak.$(date +%Y%m%d%H%M%S)"
            for num in $DEL_NUMS; do
                SHARE=$(echo "$SHARES" | sed -n "${num}p")
                [ -z "$SHARE" ] && { warn "无效编号: $num"; continue; }
                # 删除该section（从 [name] 到下一个 [ 之前）
                sed -i "/^\[$SHARE\]/,/^\[/{/^\[/!d}; /^\[$SHARE\]/d" "$SMB_CONF"
                info "已删除共享: $SHARE"
            done
            svc restart "$SMB_SVC" 2>/dev/null
            ;;

        5)  svc restart "${SMB_SVC:-smbd}" 2>/dev/null; info "SMB 服务已重启。" ;;
        6)  svc stop   "${SMB_SVC:-smbd}" 2>/dev/null; info "SMB 服务已停止。" ;;
        0)  return ;;
        *)  warn "无效选项。" ;;
    esac
}

# ════════════════════════════════════════════════════════════
#  主程序入口
# ════════════════════════════════════════════════════════════
detect_env

while true; do
    printf "\n${CYAN}╔══════════════════════════════════════╗${NC}\n"
    printf "${CYAN}║   OpenWrt 自动挂载 & SMB 管理脚本   ║${NC}\n"
    printf "${CYAN}╚══════════════════════════════════════╝${NC}\n"
    echo "  1. 安装自动挂载功能 (hotplug/udev)"
    echo "  2. 配置持久挂载 (UCI fstab/etc/fstab)"
    echo "  3. 查看持久挂载配置"
    echo "  4. 移除持久挂载条目"
    echo "  5. 卸载自动挂载功能"
    echo "  6. 测试当前配置 & 设备监控"
    echo "  7. SMB 共享管理"
    echo "  0. 退出"
    printf "${BLUE}请输入选项${NC}: "
    read CHOICE

    case "$CHOICE" in
        1) install_auto_mount        ;;
        2) manage_persistent_mount   ;;
        3) show_persistent_mounts    ;;
        4) remove_persistent_mount   ;;
        5) uninstall_auto_mount      ;;
        6) test_current_config       ;;
        7) manage_smb                ;;
        0) info "退出程序。"; exit 0 ;;
        *) warn "无效选项，请重试。"  ;;
    esac
done
