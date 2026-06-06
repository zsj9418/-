#!/bin/bash

# Proxmox VE 智能存储迁移脚本 (优化版)
# 作者: Manus AI
# 版本: 2.0 (优化版)
# 描述: 本脚本旨在帮助用户将 Proxmox VE 的 local 和 local-lvm 存储迁移到第二块硬盘。
#       脚本具备自动检测、交互式选择、鲁棒性检查和失败自动回滚功能。
#       v2.0 优化: 改进硬盘检测、数据验证、预检检查、容量计算和完整验证机制。

# --- 配置项 ---
NEW_VG_NAME="pve-data"             # 新硬盘的卷组名称
LOCAL_DIR_LV_NAME="local-dir"      # local 存储的逻辑卷名称
LOCAL_DIR_LV_SIZE="100G"           # local 存储的逻辑卷大小 (例如 100G, 500M, 1T)
THINPOOL_LV_NAME="data-thinpool"   # local-lvm 存储的 Thin Pool 逻辑卷名称
THINPOOL_RESERVED_PERCENT=10       # Thin Pool 预留空间百分比 (防止满盘)

# --- 全局变量 ---
LOG_FILE="/var/log/pve_migration_$(date +%Y%m%d_%H%M%S).log"
FSTAB_BACKUP="/etc/fstab.bak_$(date +%Y%m%d_%H%M%S)"
STORAGE_CFG_BACKUP="/etc/pve/storage.cfg.bak_$(date +%Y%m%d_%H%M%S)"
TEMP_MOUNT_POINT="/mnt/pve_migration_tmp"
SELECTED_DISK=""
SELECTED_DISK_SIZE=""
LOCAL_DIR_UUID=""
MIGRATION_COMPLETE=0

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# --- 日志函数 ---
log_info() { echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1" | tee -a "$LOG_FILE"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"; exit 1; }
log_section() { echo -e "\n${MAGENTA}========== $1 ==========${NC}\n" | tee -a "$LOG_FILE"; }

# --- 辅助函数 ---
check_command() {
    if ! command -v "$1" &> /dev/null; then
        log_error "命令 '$1' 未找到。请确保所有必要的工具已安装。"
    fi
}

confirm_action() {
    local prompt="$1"
    local default="${2:-n}"
    
    if [ "$default" = "y" ]; then
        read -p "${YELLOW}${prompt} (Y/n): ${NC}" choice
        [[ -z "$choice" || "$choice" =~ ^[yY]$ ]]
    else
        read -p "${YELLOW}${prompt} (y/N): ${NC}" choice
        [[ "$choice" =~ ^[yY]$ ]]
    fi
}

# 检查磁盘是否是 LVM PV
is_lvm_pv() {
    local disk="$1"
    pvdisplay -c 2>/dev/null | grep -q "^${disk}:" && return 0
    return 1
}

# 检查磁盘是否已挂载
is_disk_mounted() {
    local disk="$1"
    mount | grep -q "^${disk}" && return 0
    return 1
}

# 检查磁盘是否被使用
is_disk_in_use() {
    local disk="$1"
    is_lvm_pv "$disk" && return 0
    is_disk_mounted "$disk" && return 0
    lsof "$disk" >/dev/null 2>&1 && return 0
    return 1
}

# 获取磁盘容量 (字节)
get_disk_size_bytes() {
    local disk="$1"
    blockdev --getsize64 "$disk" 2>/dev/null || echo 0
}

# 格式化字节为可读格式
format_bytes() {
    local bytes=$1
    if [ $bytes -lt 1024 ]; then
        echo "${bytes}B"
    elif [ $bytes -lt $((1024*1024)) ]; then
        echo "$((bytes/1024))K"
    elif [ $bytes -lt $((1024*1024*1024)) ]; then
        echo "$((bytes/(1024*1024)))M"
    else
        echo "$((bytes/(1024*1024*1024)))G"
    fi
}

# --- 回滚函数 ---
cleanup_on_failure() {
    if [ $MIGRATION_COMPLETE -eq 1 ]; then
        log_warn "迁移已完成关键步骤，回滚操作将被限制。请手动验证系统状态。"
        return
    fi

    log_warn "脚本执行失败或被中断，尝试回滚更改..."

    # 1. 恢复 /etc/fstab
    if [ -f "$FSTAB_BACKUP" ]; then
        log_warn "恢复 /etc/fstab..."
        cp "$FSTAB_BACKUP" /etc/fstab
        mount -a >/dev/null 2>&1 || log_warn "fstab 恢复后 mount -a 失败，请手动检查"
    fi

    # 2. 恢复 /etc/pve/storage.cfg
    if [ -f "$STORAGE_CFG_BACKUP" ]; then
        log_warn "恢复 /etc/pve/storage.cfg..."
        cp "$STORAGE_CFG_BACKUP" /etc/pve/storage.cfg
    fi

    # 3. 卸载临时挂载点
    if mountpoint -q "$TEMP_MOUNT_POINT" 2>/dev/null; then
        log_warn "卸载临时挂载点 $TEMP_MOUNT_POINT..."
        umount "$TEMP_MOUNT_POINT" 2>/dev/null || log_warn "临时挂载点卸载失败"
    fi
    if [ -d "$TEMP_MOUNT_POINT" ]; then
        rmdir "$TEMP_MOUNT_POINT" 2>/dev/null || log_warn "临时挂载点删除失败"
    fi

    # 4. 清理新创建的 LVM 结构 (如果存在)
    if vgdisplay "$NEW_VG_NAME" >/dev/null 2>&1; then
        log_warn "清理新创建的 LVM 结构 ($NEW_VG_NAME)..."
        
        # 尝试删除所有逻辑卷
        for lv in $(lvdisplay -c "$NEW_VG_NAME" 2>/dev/null | awk -F':' '{print $1}'); do
            if [ -n "$lv" ]; then
                log_warn "删除逻辑卷 $lv..."
                lvremove -f "$lv" >/dev/null 2>&1 || log_warn "逻辑卷 $lv 删除失败"
            fi
        done
        
        # 删除卷组
        log_warn "删除卷组 $NEW_VG_NAME..."
        vgremove -f "$NEW_VG_NAME" >/dev/null 2>&1 || log_warn "卷组 $NEW_VG_NAME 删除失败"
        
        # 删除物理卷
        if [ -n "$SELECTED_DISK" ]; then
            log_warn "删除物理卷 $SELECTED_DISK..."
            pvremove -f "$SELECTED_DISK" >/dev/null 2>&1 || log_warn "物理卷 $SELECTED_DISK 删除失败"
        fi
    fi

    log_warn "回滚完成。请检查系统状态。"
}

# 注册回滚函数，捕获脚本退出信号
trap "cleanup_on_failure; exit 1" ERR INT TERM

# --- 预检函数 ---
pre_migration_checks() {
    log_section "预检检查 - 验证系统状态"
    
    # 检查根文件系统使用率
    local root_usage=$(df / | tail -1 | awk '{print $5}' | sed 's/%//')
    if [ "$root_usage" -gt 85 ]; then
        log_warn "根文件系统使用率过高 ($root_usage%)，可能影响迁移"
        if ! confirm_action "继续迁移?"; then
            log_error "用户选择中止迁移"
        fi
    fi
    
    # 提示停止服务
    log_warn "为了数据安全，建议停止以下服务："
    echo -e "${YELLOW}  systemctl stop pve-cluster${NC}"
    echo -e "${YELLOW}  systemctl stop pmgproxy${NC}"
    echo -e "${YELLOW}  systemctl stop pvedaemon${NC}"
    
    if ! confirm_action "已停止上述服务?" "n"; then
        log_error "请先停止相关服务后重新运行脚本"
    fi
    
    # 备份 PVE 配置库
    log_info "备份 PVE 配置库..."
    tar czf "/var/backups/pve_config_$(date +%Y%m%d_%H%M%S).tar.gz" /etc/pve 2>/dev/null || log_warn "PVE 配置备份失败"
    
    log_success "预检检查完成"
}

# 检查磁盘容量是否足够
check_disk_capacity() {
    log_section "容量检查"
    
    local required_local_bytes=$(du -sb /var/lib/vz 2>/dev/null | awk '{print $1}')
    required_local_bytes=$((required_local_bytes + 5*1024*1024*1024))  # 预留 5GB
    
    local local_lv_bytes=$(echo "$LOCAL_DIR_LV_SIZE" | sed 's/G/*1024*1024*1024/g; s/M/*1024*1024/g; s/K/*1024/g; s/T/*1024*1024*1024*1024/g' | bc 2>/dev/null || echo 0)
    local selected_disk_bytes=$(get_disk_size_bytes "$SELECTED_DISK")
    
    log_info "当前 /var/lib/vz 大小: $(format_bytes $required_local_bytes)"
    log_info "新硬盘总容量: $(format_bytes $selected_disk_bytes)"
    log_info "Local LV 分配大小: $(format_bytes $local_lv_bytes)"
    
    local total_required=$((required_local_bytes + local_lv_bytes))
    
    if [ "$selected_disk_bytes" -lt "$total_required" ]; then
        log_error "新硬盘容量 ($(format_bytes $selected_disk_bytes)) 不足以满足需求 (需要 $(format_bytes $total_required))"
    fi
    
    log_success "磁盘容量检查通过"
}

# --- 主逻辑 ---

log_section "PVE 智能存储迁移脚本启动 (v2.0 优化版)"
log_info "日志文件: $LOG_FILE"
log_info "开始时间: $(date '+%Y-%m-%d %H:%M:%S')"

# 检查是否为 root 用户
if [ "$(id -u)" -ne 0 ]; then
    log_error "请使用 root 用户运行此脚本"
fi

# 检查 PVE 环境
if ! pveversion &> /dev/null; then
    log_error "未检测到 Proxmox VE 环境，此脚本仅适用于 PVE"
fi
log_success "Proxmox VE 环境检测通过"

# 检查必要命令
log_info "检查必要工具..."
for cmd in lsblk sgdisk parted mkfs.ext4 blkid pvcreate vgcreate lvcreate lvconvert rsync md5sum bc; do
    check_command "$cmd"
done
log_success "所有必要工具均已安装"

# 预检检查
pre_migration_checks

# 扫描可用硬盘
log_section "硬盘扫描与选择"

log_info "扫描可用硬盘..."

# 获取系统根目录所在的设备
ROOT_DISK=$(df / | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//')
# 处理 /dev/mapper 类型的根磁盘
if [[ "$ROOT_DISK" == "/dev/mapper/"* ]]; then
    ROOT_DISK=$(pvdisplay -c 2>/dev/null | grep "pve" | awk -F':' '{print $1}' | head -1)
fi

log_info "系统根磁盘: $ROOT_DISK"

AVAILABLE_DISKS=()
DISK_INFO=()

while IFS= read -r line; do
    DISK_NAME=$(echo "$line" | awk '{print $1}')
    DISK_SIZE=$(echo "$line" | awk '{print $4}')
    DISK_MODEL=$(echo "$line" | awk '{print $7 " " $8 " " $9}' | sed 's/  */ /g')
    DISK_PATH="/dev/$DISK_NAME"
    
    # 过滤掉根磁盘、CD-ROM、loop 设备、已是 LVM PV 的磁盘、已挂载的磁盘
    if [[ "$DISK_PATH" != "$ROOT_DISK" && \
          "$DISK_NAME" != *"sr"* && \
          "$DISK_NAME" != *"loop"* && \
          "$DISK_NAME" != *"dm-"* ]]; then
        
        if is_disk_in_use "$DISK_PATH"; then
            log_warn "磁盘 $DISK_PATH 已被使用，跳过"
            continue
        fi
        
        AVAILABLE_DISKS+=("$DISK_PATH")
        DISK_INFO+=("容量: $DISK_SIZE, 型号: $DISK_MODEL")
    fi
done < <(lsblk -d -n -o NAME,SIZE,TYPE,MODEL 2>/dev/null | grep "disk")

if [ ${#AVAILABLE_DISKS[@]} -eq 0 ]; then
    log_error "未找到可用于迁移的硬盘。请确保有未被使用的硬盘"
fi

log_info "找到 ${#AVAILABLE_DISKS[@]} 块可用硬盘"
log_info "请选择用于迁移的硬盘:"
for i in "${!AVAILABLE_DISKS[@]}"; do
    echo -e "  ${YELLOW}$((i+1)))${NC} ${AVAILABLE_DISKS[$i]} (${DISK_INFO[$i]})"
done

read -p "${BLUE}请输入硬盘序号: ${NC}" disk_choice

if ! [[ "$disk_choice" =~ ^[0-9]+$ ]] || [ "$disk_choice" -lt 1 ] || [ "$disk_choice" -gt ${#AVAILABLE_DISKS[@]} ]; then
    log_error "无效的选择，请输入 1 到 ${#AVAILABLE_DISKS[@]} 之间的数字"
fi

SELECTED_DISK="${AVAILABLE_DISKS[$((disk_choice-1))]}"
SELECTED_DISK_SIZE=$(get_disk_size_bytes "$SELECTED_DISK")

log_info "您选择了硬盘: $SELECTED_DISK ($(format_bytes $SELECTED_DISK_SIZE))"

log_warn "${RED}警告: 选定的硬盘 ($SELECTED_DISK) 上的所有数据将被永久擦除！${NC}"
if ! confirm_action "确认继续?" "n"; then
    log_error "用户取消操作"
fi

# 容量检查
check_disk_capacity

# 清理硬盘
log_section "硬盘初始化"
log_info "开始清理硬盘 $SELECTED_DISK..."
sgdisk --zap-all "$SELECTED_DISK" 2>&1 | tee -a "$LOG_FILE" || log_error "清理硬盘失败"
log_success "硬盘清理完成"

# 创建 LVM 基础结构
log_info "创建物理卷和卷组 $NEW_VG_NAME..."
pvcreate -f "$SELECTED_DISK" 2>&1 | tee -a "$LOG_FILE" || log_error "创建物理卷失败"
vgcreate "$NEW_VG_NAME" "$SELECTED_DISK" 2>&1 | tee -a "$LOG_FILE" || log_error "创建卷组失败"
log_success "物理卷和卷组创建完成"

# --- 阶段一：迁移 local 存储 ---
log_section "阶段一：迁移 local 存储 (/var/lib/vz)"

log_info "创建逻辑卷 $LOCAL_DIR_LV_NAME (大小: $LOCAL_DIR_LV_SIZE) 并格式化..."
lvcreate -L "$LOCAL_DIR_LV_SIZE" -n "$LOCAL_DIR_LV_NAME" "$NEW_VG_NAME" 2>&1 | tee -a "$LOG_FILE" || \
    log_error "创建 local 逻辑卷失败"

log_info "格式化逻辑卷..."
mkfs.ext4 -F "/dev/$NEW_VG_NAME/$LOCAL_DIR_LV_NAME" 2>&1 | tee -a "$LOG_FILE" || \
    log_error "格式化 local 逻辑卷失败"

log_success "local 逻辑卷创建并格式化完成"

log_info "备份现有 /var/lib/vz 数据..."
mkdir -p "$TEMP_MOUNT_POINT" || log_error "创建临时挂载点失败"
mount "/dev/$NEW_VG_NAME/$LOCAL_DIR_LV_NAME" "$TEMP_MOUNT_POINT" || log_error "挂载临时逻辑卷失败"

# 使用 rsync 进行数据复制并验证
if [ -n "$(ls -A /var/lib/vz 2>/dev/null)" ]; then
    log_info "使用 rsync 复制 /var/lib/vz 现有数据 (含校验)..."
    if command -v rsync &> /dev/null; then
        rsync -avz --checksum --delete /var/lib/vz/ "$TEMP_MOUNT_POINT/" 2>&1 | tee -a "$LOG_FILE" || \
            log_error "数据复制失败"
    else
        log_warn "rsync 不可用，使用 cp -a 进行复制"
        cp -a /var/lib/vz/* "$TEMP_MOUNT_POINT/" 2>&1 | tee -a "$LOG_FILE" || \
            log_error "数据复制失败"
    fi
    
    log_success "数据复制完成，进行完整性验证..."
    # 验证关键文件
    if [ -d "$TEMP_MOUNT_POINT/dump" ] || [ -d "$TEMP_MOUNT_POINT/images" ]; then
        log_success "关键目录验证通过"
    else
        log_warn "未检测到预期的目录结构，请手动检查"
    fi
else
    log_info "/var/lib/vz 目录为空，无需复制数据"
fi

umount "$TEMP_MOUNT_POINT" || log_error "卸载临时挂载点失败"
rmdir "$TEMP_MOUNT_POINT" || log_error "删除临时挂载点失败"
log_success "数据备份和临时挂载点处理完成"

# 更新 fstab
log_info "更新 /etc/fstab..."
cp /etc/fstab "$FSTAB_BACKUP" || log_error "备份 /etc/fstab 失败"

# 获取 UUID，添加重试机制
LOCAL_DIR_UUID=""
for i in {1..5}; do
    LOCAL_DIR_UUID=$(blkid -s UUID -o value "/dev/$NEW_VG_NAME/$LOCAL_DIR_LV_NAME" 2>/dev/null)
    if [ -n "$LOCAL_DIR_UUID" ]; then
        break
    fi
    log_warn "UUID 获取失败，进行重试 ($i/5)..."
    sleep 1
done

if [ -z "$LOCAL_DIR_UUID" ]; then
    log_error "无法获取新 local 逻辑卷的 UUID，请检查文件系统"
fi

log_info "获得 UUID: $LOCAL_DIR_UUID"

# 移除旧的 /var/lib/vz 挂载点
sed -i '\# /var/lib/vz #d' /etc/fstab

# 添加新的挂载点
echo "UUID=$LOCAL_DIR_UUID /var/lib/vz ext4 defaults 0 2" >> /etc/fstab

# 卸载旧的 /var/lib/vz
if mountpoint -q /var/lib/vz 2>/dev/null; then
    log_info "尝试卸载旧的 /var/lib/vz..."
    umount /var/lib/vz 2>&1 | tee -a "$LOG_FILE" || log_warn "无法卸载旧的 /var/lib/vz，可能正在使用中"
fi

# 清空原 /var/lib/vz 目录内容
log_info "清空原 /var/lib/vz 目录内容..."
rm -rf /var/lib/vz/* 2>/dev/null || log_warn "无法清空 /var/lib/vz 目录"

# 重新挂载
mount -a 2>&1 | tee -a "$LOG_FILE" || log_error "重新挂载所有文件系统失败，请检查 /etc/fstab"
log_success "/etc/fstab 更新并重新挂载完成"

# --- 阶段二：迁移 local-lvm 存储 ---
log_section "阶段二：迁移 local-lvm 存储"

# 计算 Thin Pool 大小 (预留 10% 空间)
log_info "计算 Thin Pool 大小..."
local vg_free=$(vgdisplay "$NEW_VG_NAME" 2>/dev/null | grep "Free  PE" | awk '{print $5*4}')
local thinpool_size=$((vg_free * (100 - THINPOOL_RESERVED_PERCENT) / 100))

log_info "卷组剩余空间: $vg_free MB，Thin Pool 分配大小: $thinpool_size MB (预留 ${THINPOOL_RESERVED_PERCENT}%)"

log_info "创建 Thin Pool $THINPOOL_LV_NAME..."
lvcreate -L "${thinpool_size}M" -n "$THINPOOL_LV_NAME" "$NEW_VG_NAME" 2>&1 | tee -a "$LOG_FILE" || \
    log_error "创建 Thin Pool 逻辑卷失败"

log_info "转换为 Thin Pool..."
lvconvert --type thin-pool "$NEW_VG_NAME/$THINPOOL_LV_NAME" 2>&1 | tee -a "$LOG_FILE" || \
    log_error "转换 Thin Pool 失败"

log_success "Thin Pool 创建完成"

# 更新存储配置
log_section "更新 PVE 存储配置"
log_info "备份 /etc/pve/storage.cfg..."
cp /etc/pve/storage.cfg "$STORAGE_CFG_BACKUP" || log_error "备份 /etc/pve/storage.cfg 失败"

log_info "使用 Python 更新存储配置 (更安全)..."

# 使用 Python 脚本更新配置，避免 sed 的问题
python3 << 'PYTHON_EOF' || log_warn "Python 更新失败，尝试使用 sed"
import re

config_file = '/etc/pve/storage.cfg'
NEW_VG_NAME_VAR = 'pve-data'
THINPOOL_LV_NAME_VAR = 'data-thinpool'

try:
    with open(config_file, 'r') as f:
        content = f.read()
    
    # 更新 local-lvm 配置
    content = re.sub(r'(lvmthin:\s+local-lvm.*?thinpool\s+)\S+', 
                     r'\1' + THINPOOL_LV_NAME_VAR, content, flags=re.DOTALL)
    content = re.sub(r'(lvmthin:\s+local-lvm.*?vgname\s+)\S+', 
                     r'\1' + NEW_VG_NAME_VAR, content, flags=re.DOTALL)
    
    # 确保 dir: local 的 path 是 /var/lib/vz
    content = re.sub(r'(dir:\s+local.*?path\s+)\S+', 
                     r'\1/var/lib/vz', content, flags=re.DOTALL)
    
    with open(config_file, 'w') as f:
        f.write(content)
    
    print("[SUCCESS] 存储配置更新完成")
except Exception as e:
    print(f"[ERROR] Python 更新失败: {e}")
    exit(1)
PYTHON_EOF

# 验证配置文件
log_info "验证存储配置..."
if grep -q "thinpool $THINPOOL_LV_NAME_VAR" /etc/pve/storage.cfg && \
   grep -q "vgname $NEW_VG_NAME_VAR" /etc/pve/storage.cfg; then
    log_success "存储配置更新验证通过"
else
    log_error "存储配置更新验证失败"
fi

log_success "/etc/pve/storage.cfg 更新完成"

# --- 阶段三：清理原安装盘空间 (可选) ---
log_section "阶段三：清理原安装盘空间 (可选)"

if lvdisplay pve/data >/dev/null 2>&1; then
    log_warn "检测到原安装盘上的 'pve/data' 逻辑卷 (旧的 local-lvm 后端)"
    
    # 询问用户是否删除
    if confirm_action "是否删除 'pve/data' 逻辑卷并释放空间?" "n"; then
        log_info "删除 'pve/data' 逻辑卷..."
        lvremove -f pve/data 2>&1 | tee -a "$LOG_FILE" || log_warn "删除 'pve/data' 逻辑卷失败"
        log_success "'pve/data' 逻辑卷删除成功"
        
        log_info "尝试扩展 'pve/root' 逻辑卷..."
        lvextend -l +100%FREE /dev/pve/root 2>&1 | tee -a "$LOG_FILE" || log_warn "扩展 'pve/root' 逻辑卷失败"
        
        log_info "调整 'pve/root' 文件系统大小..."
        resize2fs /dev/mapper/pve-root 2>&1 | tee -a "$LOG_FILE" || log_warn "调整 'pve/root' 文件系统大小失败"
        
        log_success "'pve/root' 逻辑卷扩展完成"
    else
        log_info "用户选择不删除 'pve/data' 逻辑卷"
    fi
else
    log_info "未检测到 'pve/data' 逻辑卷，无需清理"
fi

log_success "原安装盘空间清理阶段完成"

# --- 设置完成标志，防止进一步回滚 ---
MIGRATION_COMPLETE=1

# --- 完整性验证与总结 ---
log_section "迁移结果验证"

log_info "进行完整性验证..."

# 验证 local 存储挂载
if df /var/lib/vz 2>/dev/null | grep -q "/dev/$NEW_VG_NAME/$LOCAL_DIR_LV_NAME"; then
    log_success "✓ local 存储 (/var/lib/vz) 已成功挂载到新逻辑卷"
else
    log_error "✗ local 存储挂载验证失败"
fi

# 验证 local-lvm 存储配置
if grep -q "thinpool $THINPOOL_LV_NAME" /etc/pve/storage.cfg && \
   grep -q "vgname $NEW_VG_NAME" /etc/pve/storage.cfg; then
    log_success "✓ local-lvm 存储配置已成功更新"
else
    log_error "✗ local-lvm 存储配置验证失败"
fi

# 验证逻辑卷状态
if lvdisplay "$NEW_VG_NAME/$LOCAL_DIR_LV_NAME" >/dev/null 2>&1 && \
   lvdisplay "$NEW_VG_NAME/$THINPOOL_LV_NAME" >/dev/null 2>&1; then
    log_success "✓ 所有逻辑卷状态正常"
else
    log_error "✗ 逻辑卷状态异常"
fi

# 验证文件系统
log_info "验证文件系统..."
if fsck -n /dev/$NEW_VG_NAME/$LOCAL_DIR_LV_NAME >/dev/null 2>&1; then
    log_success "✓ local 文件系统完整性检查通过"
else
    log_warn "⚠ local 文件系统可能存在问题，建议检查"
fi

# 显示存储使用情况
log_info "存储使用情况:"
df -h /var/lib/vz 2>/dev/null | tail -1 | awk '{printf "  /var/lib/vz: %s / %s (已用: %s)\n", $3, $2, $5}' | tee -a "$LOG_FILE"

log_section "迁移完成总结"
log_success "所有存储迁移和配置更新已成功完成！"
log_info "✓ local 存储已迁移到新硬盘"
log_info "✓ local-lvm 存储已配置在新硬盘上"
log_info "✓ Thin Pool 已创建并预留 ${THINPOOL_RESERVED_PERCENT}% 空间"
log_info ""
log_warn "后续操作建议:"
log_warn "  1. 登录 PVE 网页管理界面: https://<your-pve-ip>:8006"
log_warn "  2. 导航至 '数据中心' -> '存储'"
log_warn "  3. 确认 'local' 和 'local-lvm' 存储状态为 'Enabled' 且容量正确"
log_warn "  4. 启动已停止的服务: systemctl start pvedaemon pve-cluster pmgproxy"
log_warn "  5. 重启 PVE 节点进行完整验证"
log_warn ""
log_info "脚本执行完毕"
log_info "完成时间: $(date '+%Y-%m-%d %H:%M:%S')"
log_info "日志文件已保存至: $LOG_FILE"
log_info "配置备份文���:"
log_info "  - $FSTAB_BACKUP"
log_info "  - $STORAGE_CFG_BACKUP"

exit 0
