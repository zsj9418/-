#!/bin/bash

# Proxmox VE 智能存储迁移脚本
# 作者: Manus AI
# 版本: 1.0
# 描述: 本脚本旨在帮助用户将 Proxmox VE 的 local 和 local-lvm 存储迁移到第二块硬盘。
#       脚本具备自动检测、交互式选择、鲁棒性检查和失败自动回滚功能。

# --- 配置项 ---
NEW_VG_NAME="pve-data"             # 新硬盘的卷组名称
LOCAL_DIR_LV_NAME="local-dir"      # local 存储的逻辑卷名称
LOCAL_DIR_LV_SIZE="100G"           # local 存储的逻辑卷大小 (例如 100G, 500M, 1T)
THINPOOL_LV_NAME="data-thinpool"   # local-lvm 存储的 Thin Pool 逻辑卷名称

# --- 全局变量 ---
LOG_FILE="/var/log/pve_migration_$(date +%Y%m%d_%H%M%S).log"
FSTAB_BACKUP="/etc/fstab.bak_$(date +%Y%m%d_%H%M%S)"
STORAGE_CFG_BACKUP="/etc/pve/storage.cfg.bak_$(date +%Y%m%d_%H%M%S)"
TEMP_MOUNT_POINT="/mnt/pve_migration_tmp"
SELECTED_DISK=""
LOCAL_DIR_UUID=""

# --- 颜色定义 ---
RED=\033[0;31m
GREEN=\033[0;32m
YELLOW=\033[0;33m
BLUE=\033[0;34m
NC=\033[0m # No Color

# --- 日志函数 ---
log_info() { echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1" | tee -a "$LOG_FILE"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"; exit 1; }

# --- 回滚函数 ---
cleanup_on_failure() {
    log_error "脚本执行失败或被中断，尝试回滚更改..."

    # 1. 恢复 /etc/fstab
    if [ -f "$FSTAB_BACKUP" ]; then
        log_warn "恢复 /etc/fstab..."
        mv "$FSTAB_BACKUP" /etc/fstab
        mount -a >/dev/null 2>&1
    fi

    # 2. 恢复 /etc/pve/storage.cfg
    if [ -f "$STORAGE_CFG_BACKUP" ]; then
        log_warn "恢复 /etc/pve/storage.cfg..."
        mv "$STORAGE_CFG_BACKUP" /etc/pve/storage.cfg
    fi

    # 3. 卸载临时挂载点
    if mountpoint -q "$TEMP_MOUNT_POINT"; then
        log_warn "卸载临时挂载点 $TEMP_MOUNT_POINT..."
        umount "$TEMP_MOUNT_POINT"
    fi
    if [ -d "$TEMP_MOUNT_POINT" ]; then
        rmdir "$TEMP_MOUNT_POINT"
    fi

    # 4. 清理新创建的 LVM 结构 (如果存在)
    if vgdisplay "$NEW_VG_NAME" >/dev/null 2>&1; then
        log_warn "清理新创建的 LVM 结构 ($NEW_VG_NAME)..."
        # 尝试删除所有逻辑卷
        for lv in $(lvdisplay -c "$NEW_VG_NAME" | awk -F':' '{print $1}'); do
            log_warn "删除逻辑卷 $lv..."
            lvremove -f "$lv" >/dev/null 2>&1
        done
        # 删除卷组
        log_warn "删除卷组 $NEW_VG_NAME..."
        vgremove -f "$NEW_VG_NAME" >/dev/null 2>&1
        # 删除物理卷
        if [ -n "$SELECTED_DISK" ]; then
            log_warn "删除物理卷 $SELECTED_DISK..."
            pvremove -f "$SELECTED_DISK" >/dev/null 2>&1
        fi
    fi

    log_error "回滚完成。请检查系统状态并手动清理可能残留的配置。"
    exit 1
}

# 注册回滚函数，捕获脚本退出信号
trap cleanup_on_failure ERR INT TERM

# --- 辅助函数 ---
check_command() {
    if ! command -v "$1" &> /dev/null; then
        log_error "命令 '$1' 未找到。请确保所有必要的工具已安装。"
    fi
}

confirm_action() {
    read -p "${YELLOW}请确认此操作 (y/N): ${NC}" choice
    [[ "$choice" =~ ^[yY]$ ]]
}

# --- 主逻辑 ---

log_info "PVE 智能存储迁移脚本启动..."
log_info "日志文件: $LOG_FILE"

# 检查是否为 root 用户
if [ "$(id -u)" -ne 0 ]; then
    log_error "请使用 root 用户运行此脚本。"
fi

# 检查 PVE 环境
if ! pveversion &> /dev/null; then
    log_error "未检测到 Proxmox VE 环境。此脚本仅适用于 PVE。"
fi
log_success "Proxmox VE 环境检测通过。"

# 检查必要命令
check_command lsblk
check_command sgdisk
check_command parted
check_command mkfs.ext4
check_command blkid
check_command pvcreate
check_command vgcreate
check_command lvcreate
check_command lvconvert
check_command nano # 用于编辑配置文件，用户可手动确认

log_info "扫描可用硬盘..."

# 获取系统根目录所在的设备
ROOT_DISK=$(df / | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//')
if [[ "$ROOT_DISK" == "/dev/mapper/pve-root" ]]; then
    ROOT_DISK=$(pvdisplay -c | grep "pve" | awk -F':' '{print $1}')
fi

AVAILABLE_DISKS=()
DISK_INFO=()

while IFS= read -r line; do
    DISK_NAME=$(echo "$line" | awk '{print $1}')
    DISK_SIZE=$(echo "$line" | awk '{print $4}')
    DISK_MODEL=$(echo "$line" | awk '{print $7 " " $8 " " $9}')

    # 过滤掉根磁盘、CD-ROM、loop设备、已是LVM PV的磁盘
    if [[ "$DISK_NAME" != "$ROOT_DISK" && \
          "$DISK_NAME" != *"sr"* && \
          "$DISK_NAME" != *"loop"* && \
          ! $(pvdisplay -c | grep "$DISK_NAME" | grep -q "$DISK_NAME" && echo true) ]]; then
        AVAILABLE_DISKS+=("/dev/$DISK_NAME")
        DISK_INFO+=("容量: $DISK_SIZE, 型号: $DISK_MODEL")
    fi
done < <(lsblk -d -o NAME,SIZE,TYPE,MODEL | grep "disk")

if [ ${#AVAILABLE_DISKS[@]} -eq 0 ]; then
    log_error "未找到可用于迁移的硬盘。请确保有未被使用的硬盘。"
fi

log_info "请选择用于迁移的硬盘："
for i in "${!AVAILABLE_DISKS[@]}"; do
    echo -e "  ${YELLOW}$((i+1)))${NC} ${AVAILABLE_DISKS[$i]} (${DISK_INFO[$i]})"
done

read -p "${BLUE}请输入硬盘序号: ${NC}" disk_choice

if ! [[ "$disk_choice" =~ ^[0-9]+$ ]] || [ "$disk_choice" -lt 1 ] || [ "$disk_choice" -gt ${#AVAILABLE_DISKS[@]} ]; then
    log_error "无效的选择。请重新运行脚本并输入正确的序号。"
fi

SELECTED_DISK="${AVAILABLE_DISKS[$((disk_choice-1))]}"
log_info "您选择了硬盘: $SELECTED_DISK"

log_warn "${RED}警告: 选定的硬盘 ($SELECTED_DISK) 上的所有数据将被擦除！${NC}"
if ! confirm_action; then
    log_error "用户取消操作。"
fi

log_info "开始清理硬盘 $SELECTED_DISK..."
sgdisk --zap-all "$SELECTED_DISK" || log_error "清理硬盘失败。"
log_success "硬盘清理完成。"

log_info "创建物理卷和卷组 $NEW_VG_NAME..."
pvcreate "$SELECTED_DISK" || log_error "创建物理卷失败。"
vgcreate "$NEW_VG_NAME" "$SELECTED_DISK" || log_error "创建卷组失败。"
log_success "物理卷和卷组创建完成。"

# --- 阶段一：迁移 local 存储 ---
log_info "开始迁移 local 存储 (/var/lib/vz)..."

log_info "创建逻辑卷 $LOCAL_DIR_LV_NAME 并格式化..."
lvcreate -L "$LOCAL_DIR_LV_SIZE" -n "$LOCAL_DIR_LV_NAME" "$NEW_VG_NAME" || log_error "创建 local 逻辑卷失败。"
mkfs.ext4 "/dev/$NEW_VG_NAME/$LOCAL_DIR_LV_NAME" || log_error "格式化 local 逻辑卷失败。"
log_success "local 逻辑卷创建并格式化完成。"

log_info "备份现有 /var/lib/vz 数据并准备挂载..."
mkdir -p "$TEMP_MOUNT_POINT" || log_error "创建临时挂载点失败。"
mount "/dev/$NEW_VG_NAME/$LOCAL_DIR_LV_NAME" "$TEMP_MOUNT_POINT" || log_error "挂载临时逻辑卷失败。"

# 检查 /var/lib/vz 是否有内容，如果有则复制
if [ -n "$(ls -A /var/lib/vz)" ]; then
    log_info "复制 /var/lib/vz 现有数据到新位置..."
    cp -a /var/lib/vz/* "$TEMP_MOUNT_POINT/" || log_error "复制数据失败。"
else
    log_info "/var/lib/vz 目录为空，无需复制数据。"
fi

umount "$TEMP_MOUNT_POINT" || log_error "卸载临时挂载点失败。"
rmdir "$TEMP_MOUNT_POINT" || log_error "删除临时挂载点失败。"
log_success "数据备份和临时挂载点处理完成。"

log_info "更新 /etc/fstab..."
cp /etc/fstab "$FSTAB_BACKUP" || log_error "备份 /etc/fstab 失败。"

LOCAL_DIR_UUID=$(blkid -s UUID -o value "/dev/$NEW_VG_NAME/$LOCAL_DIR_LV_NAME")
if [ -z "$LOCAL_DIR_UUID" ]; then
    log_error "无法获取新 local 逻辑卷的 UUID。"
fi

# 移除旧的 /var/lib/vz 挂载点 (如果存在于 fstab)
sed -i "\# /var/lib/vz #d" /etc/fstab

# 添加新的挂载点
echo "UUID=$LOCAL_DIR_UUID /var/lib/vz ext4 defaults 0 2" >> /etc/fstab

# 尝试卸载旧的 /var/lib/vz (如果它是一个独立分区)
if mountpoint -q /var/lib/vz; then
    log_info "尝试卸载旧的 /var/lib/vz..."
    umount /var/lib/vz || log_warn "无法卸载旧的 /var/lib/vz，可能正在使用中。请手动检查。"
fi

# 清空原 /var/lib/vz 目录内容 (如果未卸载成功，可能需要手动处理)
log_info "清空原 /var/lib/vz 目录内容..."
rm -rf /var/lib/vz/* || log_warn "无法清空 /var/lib/vz 目录内容。"

mount -a || log_error "重新挂载所有文件系统失败，请检查 /etc/fstab。"
log_success "/etc/fstab 更新并重新挂载完成。"

# --- 阶段二：迁移 local-lvm 存储 ---
log_info "开始迁移 local-lvm 存储..."

log_info "创建 Thin Pool $THINPOOL_LV_NAME..."
lvcreate -l +100%FREE -n "$THINPOOL_LV_NAME" "$NEW_VG_NAME" || log_error "创建 Thin Pool 逻辑卷失败。"
lvconvert --type thin-pool "$NEW_VG_NAME/$THINPOOL_LV_NAME" || log_error "转换 Thin Pool 失败。"
log_success "Thin Pool 创建完成。"

log_info "更新 /etc/pve/storage.cfg..."
cp /etc/pve/storage.cfg "$STORAGE_CFG_BACKUP" || log_error "备份 /etc/pve/storage.cfg 失败。"

# 替换 local-lvm 配置
sed -i "/lvmthin: local-lvm/{N;N;s/\(thinpool \).*/\1$THINPOOL_LV_NAME/;s/\(vgname \).*/\1$NEW_VG_NAME/}" /etc/pve/storage.cfg

# 确保 dir: local 的 path 是 /var/lib/vz (如果被修改过)
sed -i "/dir: local/{N;s/\(path \).*/\1\/var\/lib\/vz/}" /etc/pve/storage.cfg

log_success "/etc/pve/storage.cfg 更新完成。"

# --- 阶段三：清理原安装盘空间 (可选) ---
log_info "开始清理原安装盘空间 (可选)..."

if lvdisplay pve/data >/dev/null 2>&1; then
    log_warn "检测到原安装盘上的 'pve/data' 逻辑卷 (旧的 local-lvm 后端)。"
    read -p "${YELLOW}是否删除 'pve/data' 逻辑卷并释放空间？ (y/N): ${NC}" choice
    if [[ "$choice" =~ ^[yY]$ ]]; then
        log_info "删除 'pve/data' 逻辑卷..."
        lvremove -f pve/data || log_error "删除 'pve/data' 逻辑卷失败。"
        log_success "'pve/data' 逻辑卷删除成功。"

        log_info "尝试扩展 'pve/root' 逻辑卷..."
        lvextend -l +100%FREE /dev/pve/root || log_warn "扩展 'pve/root' 逻辑卷失败，可能没有可用空间。"
        resize2fs /dev/mapper/pve-root || log_warn "调整 'pve/root' 文件系统大小失败。"
        log_success "'pve/root' 逻辑卷扩展完成。"
    else
        log_info "用户选择不删除 'pve/data' 逻辑卷。"
    fi
else
    log_info "未检测到 'pve/data' 逻辑卷，无需清理。"
fi

log_success "原安装盘空间清理阶段完成。"

# --- 验证与总结 ---
log_info "开始验证迁移结果..."

if df -h /var/lib/vz | grep -q "/dev/$NEW_VG_NAME/$LOCAL_DIR_LV_NAME"; then
    log_success "local 存储 (/var/lib/vz) 已成功挂载到新逻辑卷。"
else
    log_error "local 存储挂载验证失败。"
fi

if grep -q "thinpool $THINPOOL_LV_NAME" /etc/pve/storage.cfg && grep -q "vgname $NEW_VG_NAME" /etc/pve/storage.cfg; then
    log_success "local-lvm 存储配置已成功更新。"
else
    log_error "local-lvm 存储配置验证失败。"
fi

log_success "所有存储迁移和配置更新已成功完成！"
log_info "请登录 PVE 网页管理界面，在 '数据中心' -> '存储' 中确认 'local' 和 'local-lvm' 状态和容量。"
log_info "脚本执行完毕。"

exit 0
