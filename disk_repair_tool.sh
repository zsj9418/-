#!/bin/bash

#===============================================================================
#硬盘智能管理与修复工具
# 版本: 2.0
# 功能: 硬盘检测、修复、格式化、分区管理
#===============================================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# 日志文件
LOG_DIR="/var/log/disk_repair"
LOG_FILE="$LOG_DIR/repair_$(date +%Y%m%d_%H%M%S).log"

#===============================================================================
# 基础函数
#===============================================================================

init() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 此脚本需要 root 权限运行${NC}"
        exit 1
    fi
    mkdir -p "$LOG_DIR"
    install_dependencies
}

install_dependencies() {
    local need_install=0
    for cmd in smartctl hdparm badblocks parted mkfs.ext4 mkfs.xfs mkfs.btrfs mkfs.ntfs mkfs.vfat; do
        if ! command -v $cmd &>/dev/null; then
            need_install=1
            break
        fi
    done

    if [[ $need_install -eq 1 ]]; then
        echo -e "${YELLOW}正在安装必要工具...${NC}"
        apt update -qq 2>/dev/null
        apt install -y smartmontools hdparm e2fsprogs parted xfsprogs btrfs-progs ntfs-3g dosfstools exfatprogs > /dev/null 2>&1
    fi
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

print_header() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════════════╗"
    echo "║            硬盘智能管理与修复工具 v2.0                          ║"
    echo "║                                                                      ║"
    echo "║    功能: 硬盘检测 | 坏道修复 | 分区管理 | 多格式格式化              ║"
    echo "║                                                                      ║"
    echo "║    ⚠️  警告: 部分操作可能导致数据丢失，请先备份重要数据！            ║"
    echo "╚══════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_separator() {
    echo -e "${BLUE}────────────────────────────────────────────────────────────────────────${NC}"
}

print_double_separator() {
    echo -e "${CYAN}════════════════════════════════════════════════════════════════════════${NC}"
}

pause() {
    echo ""
    read -p "按 Enter 键继续..."
}

confirm() {
    local msg="$1"
    echo -e "${YELLOW}$msg${NC}"
    read -p "确认操作? (yes/no): " choice
    [[ "$choice" == "yes" ]]
}

#===============================================================================
# 硬盘信息函数
#===============================================================================

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
        health="N/A"
        pending="N/A"
        reallocated="N/A"
        uncorrectable="N/A"
        hours="N/A"
        temp="N/A"
    fi

    echo "$model|$size|$health|$pending|$reallocated|$uncorrectable|$hours|$temp"
}

check_disk_mounted() {
    local disk="/dev/$1"
    if mount | grep -q "^${disk}"; then
        return 0
    fi
    if lsblk -n -o MOUNTPOINT "$disk" 2>/dev/null | grep -q "/"; then
        return 0
    fi
    return 1
}

check_disk_in_use() {
    local disk="$1"
    
    local root_device=$(findmnt -n -o SOURCE / 2>/dev/null)
    if [[ -n "$root_device" ]]; then
        local root_disk=$(lsblk -n -o PKNAME "$root_device" 2>/dev/null)
        if [[ "$disk" == "$root_disk" ]]; then
            return 0
        fi
    fi

    if pvs 2>/dev/null | grep -q "/dev/$disk"; then
        return 0
    fi

    if command -v zpool &>/dev/null; then
        if zpool status 2>/dev/null | grep -q "$disk"; then
            return 0
        fi
    fi

    return 1
}

get_disk_status() {
    local pending="$1"
    local reallocated="$2"
    local health="$3"

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

get_fs_type_name() {
    case "$1" in
        ext4) echo "ext4 (Linux 推荐)" ;;
        ext3) echo "ext3 (Linux 兼容)" ;;
        xfs) echo "XFS (大文件优化)" ;;
        btrfs) echo "Btrfs (快照支持)" ;;
        ntfs) echo "NTFS (Windows)" ;;
        vfat) echo "FAT32 (通用兼容)" ;;
        exfat) echo "exFAT (大文件+兼容)" ;;
        *) echo "$1" ;;
    esac
}

#===============================================================================
# 显示所有硬盘概览
#===============================================================================

show_all_disks_overview() {
    print_header
    echo -e "${GREEN}📊 所有硬盘概览${NC}"
    echo ""
    print_double_separator
    
    printf "${WHITE}%-6s %-28s %-10s %-12s %-8s %-10s${NC}\n" \
        "设备" "型号" "总容量" "文件系统" "状态" "可操作"
    print_double_separator

    for disk in $(get_all_disks); do
        local info=$(get_disk_info "$disk")
        IFS='|' read -r model size health pending reallocated uncorrectable hours temp <<< "$info"
        
        model=$(echo "${model:-未知}" | cut -c1-26)
        local status=$(get_disk_status "$pending" "$reallocated" "$health")
        
        local operable
        if check_disk_in_use "$disk"; then
            operable="${RED}系统盘${NC}"
        elif check_disk_mounted "$disk"; then
            operable="${YELLOW}已挂载${NC}"
        else
            operable="${GREEN}可操作${NC}"
        fi

        # 获取分区文件系统信息
        local fs_info=$(lsblk -n -o FSTYPE "/dev/$disk" 2>/dev/null | grep -v "^$" | sort -u | tr '\n' ',' | sed 's/,$//')
        fs_info="${fs_info:-无分区}"

        printf "%-6s %-28s %-10s %-12s %-18b %-18b\n" \
            "$disk" "$model" "$size" "$fs_info" "$status" "$operable"

        # 显示分区详情
        lsblk -n -o NAME,SIZE,FSTYPE,MOUNTPOINT,LABEL "/dev/$disk" 2>/dev/null | grep -v "^$disk " | while read -r line; do
            local pname=$(echo "$line" | awk '{print $1}')
            local psize=$(echo "$line" | awk '{print $2}')
            local pfs=$(echo "$line" | awk '{print $3}')
            local pmount=$(echo "$line" | awk '{print $4}')
            local plabel=$(echo "$line" | awk '{print $5}')
            
            pname=$(echo "$pname" | sed 's/[├└│─]//g' | xargs)
            
            if [[ -n "$pname" ]]; then
                local mount_info=""
                if [[ -n "$pmount" ]]; then
                    mount_info="${CYAN}→ $pmount${NC}"
                fi
                local label_info=""
                if [[ -n "$plabel" ]]; then
                    label_info="[$plabel]"
                fi
                printf "  ${PURPLE}└─ %-8s %-8s %-10s %s %b${NC}\n" "$pname" "$psize" "${pfs:-未格式化}" "$label_info" "$mount_info"
            fi
        done
    done

    print_double_separator
    echo ""
    
    # 统计信息
    local total_disks=$(get_all_disks | wc -w)
    local problem_disks=0
    for disk in $(get_all_disks); do
        local info=$(get_disk_info "$disk")
        IFS='|' read -r model size health pending reallocated uncorrectable hours temp <<< "$info"
        if [[ "$pending" != "N/A" && "$pending" != "0" && -n "$pending" ]]; then
            ((problem_disks++))
        fi
    done

    echo -e "硬盘总数: ${CYAN}$total_disks${NC}  |  问题硬盘: ${RED}$problem_disks${NC}"
    
    log "显示硬盘概览: 总计 $total_disks 块，问题 $problem_disks 块"
}

#===============================================================================
# 主菜单
#===============================================================================

show_main_menu() {
    print_header
    
    # 快速显示硬盘状态
    echo -e "${WHITE}当前硬盘状态:${NC}"
    print_separator
    for disk in $(get_all_disks); do
        local size=$(lsblk -d -n -o SIZE "/dev/$disk")
        local model=$(smartctl -i "/dev/$disk" 2>/dev/null | grep "Device Model" | cut -d: -f2 | xargs 2>/dev/null)
        local info=$(get_disk_info "$disk")
        IFS='|' read -r m s health pending r u h t <<< "$info"
        local status=$(get_disk_status "$pending" "$r" "$health")
        
        local use_status=""
        if check_disk_in_use "$disk"; then
            use_status="${RED}[系统]${NC}"
        elif check_disk_mounted "$disk"; then
            use_status="${YELLOW}[挂载]${NC}"
        fi
        
        echo -e "  /dev/$disk  $size  ${model:-未知}  $status $use_status"
    done
    print_separator
    echo ""

    echo -e "${GREEN}请选择操作:${NC}"
    echo ""
    echo "  ┌─────────────────────────────────────────────────────────┐"
    echo "  │  ${WHITE}信息查看${NC}                                              │"
    echo "  │    1) 📊 查看所有硬盘详细概览                           │"
    echo "  │    2) 🔍 查看单个硬盘 SMART 详情                        │"
    echo "  │                                                         │"
    echo "  │  ${WHITE}硬盘修复${NC}                                              │"
    echo "  │    3) 🔧 硬盘检测与修复                                 │"
    echo "  │    4) 🚨 一键扫描修复所有问题硬盘                       │"
    echo "  │                                                         │"
    echo "  │  ${WHITE}分区格式化${NC}                                            │"
    echo "  │    5) 💾 格式化硬盘（多格式可选）                       │"
    echo "  │    6) 📁 分区管理                                       │"
    echo "  │    7) 🗂️  快速挂载/卸载                                  │"
    echo "  │                                                         │"
    echo "  │  ${WHITE}其他功能${NC}                                              │"
    echo "  │    8) 📋 查看修复日志                                   │"
    echo "  │    9) ❓ 帮助信息                                       │"
    echo "  │    0) 🚪 退出                                           │"
    echo "  └─────────────────────────────────────────────────────────┘"
    echo ""
    
    read -p "请输入选项 [0-9]: " choice
    
    case $choice in
        1) show_all_disks_overview; pause ;;
        2) view_disk_detail ;;
        3) repair_disk_menu ;;
        4) auto_repair_all ;;
        5) format_disk_menu ;;
        6) partition_menu ;;
        7) mount_menu ;;
        8) view_logs ;;
        9) show_help ;;
        0) echo "再见！"; exit 0 ;;
        *) echo -e "${RED}无效选项${NC}"; sleep 1 ;;
    esac
}

#===============================================================================
# 功能2: 查看硬盘详情
#===============================================================================

view_disk_detail() {
    print_header
    echo -e "${GREEN}🔍 查看硬盘详细信息${NC}"
    echo ""

    echo "可用硬盘列表:"
    print_separator
    
    local i=1
    local -a disks
    for disk in $(get_all_disks); do
        disks+=("$disk")
        local size=$(lsblk -d -n -o SIZE "/dev/$disk")
        local model=$(smartctl -i "/dev/$disk" 2>/dev/null | grep "Device Model" | cut -d: -f2 | xargs 2>/dev/null)
        echo "  $i) /dev/$disk - ${model:-未知} ($size)"
        ((i++))
    done
    echo "  0) 返回主菜单"
    print_separator

    read -p "请选择硬盘 [0-$((i-1))]: " choice

    [[ "$choice" == "0" ]] && return

    if [[ "$choice" -ge 1 && "$choice" -lt "$i" ]] 2>/dev/null; then
        local selected_disk="${disks[$((choice-1))]}"
        show_disk_detail "$selected_disk"
    else
        echo -e "${RED}无效选项${NC}"
        sleep 1
    fi
}

show_disk_detail() {
    local disk="$1"
    print_header
    echo -e "${GREEN}📋 /dev/$disk 详细信息${NC}"
    print_double_separator

    echo -e "${CYAN}【基本信息】${NC}"
    smartctl -i "/dev/$disk" 2>/dev/null | grep -E "Model|Serial|Capacity|Sector|Firmware|Rotation"

    echo ""
    echo -e "${CYAN}【健康状态】${NC}"
    smartctl -H "/dev/$disk" 2>/dev/null | grep -E "overall-health|test result"

    echo ""
    echo -e "${CYAN}【关键 SMART 指标】${NC}"
    printf "%-30s %-10s %-10s %-15s\n" "指标" "当前值" "阈值" "原始值"
    print_separator

    smartctl -A "/dev/$disk" 2>/dev/null | grep -E "Reallocated_Sector|Current_Pending|Offline_Uncorrectable|Power_On_Hours|Temperature|Raw_Read_Error|Spin_Retry|Seek_Error" | \
    while read -r line; do
        local name=$(echo "$line" | awk '{print $2}')
        local value=$(echo "$line" | awk '{print $4}')
        local thresh=$(echo "$line" | awk '{print $6}')
        local raw=$(echo "$line" | awk '{print $10}')
        printf "%-30s %-10s %-10s %-15s\n" "$name" "$value" "$thresh" "$raw"
    done

    echo ""
    echo -e "${CYAN}【自检历史】${NC}"
    smartctl -l selftest "/dev/$disk" 2>/dev/null | head -20

    echo ""
    echo -e "${CYAN}【分区信息】${NC}"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,LABEL,UUID "/dev/$disk"

    pause
}

#===============================================================================
# 功能3: 修复硬盘菜单
#===============================================================================

repair_disk_menu() {
    print_header
    echo -e "${GREEN}🔧 选择要修复的硬盘${NC}"
    echo ""

    echo "可修复硬盘列表:"
    print_separator
    
    local i=1
    local -a disks

    for disk in $(get_all_disks); do
        if check_disk_in_use "$disk"; then
            continue
        fi

        disks+=("$disk")
        local info=$(get_disk_info "$disk")
        IFS='|' read -r model size health pending reallocated uncorrectable hours temp <<< "$info"
        local status=$(get_disk_status "$pending" "$reallocated" "$health")

        local mount_status=""
        if check_disk_mounted "$disk"; then
            mount_status="${YELLOW}[已挂载]${NC}"
        fi

        echo -e "  $i) /dev/$disk - ${model:-未知} ($size) - 状态: $status 待处理: ${pending:-0} $mount_status"
        ((i++))
    done

    if [[ ${#disks[@]} -eq 0 ]]; then
        echo -e "${YELLOW}没有可修复的硬盘（系统盘已排除）${NC}"
        pause
        return
    fi

    echo "  0) 返回主菜单"
    print_separator

    read -p "请选择硬盘 [0-$((i-1))]: " choice

    [[ "$choice" == "0" ]] && return

    if [[ "$choice" -ge 1 && "$choice" -lt "$i" ]] 2>/dev/null; then
        local selected_disk="${disks[$((choice-1))]}"
        repair_options_menu "$selected_disk"
    else
        echo -e "${RED}无效选项${NC}"
        sleep 1
    fi
}

repair_options_menu() {
    local disk="$1"

    while true; do
        print_header
        echo -e "${GREEN}🔧 /dev/$disk 修复选项${NC}"
        echo ""

        local info=$(get_disk_info "$disk")
        IFS='|' read -r model size health pending reallocated uncorrectable hours temp <<< "$info"

        echo -e "型号: ${CYAN}${model:-未知}${NC}"
        echo -e "容量: ${CYAN}$size${NC}"
        echo -e "健康: ${CYAN}${health:-N/A}${NC}"
        echo -e "待处理坏道: ${YELLOW}${pending:-0}${NC}"
        echo -e "已重映射: ${CYAN}${reallocated:-0}${NC}"
        echo -e "运行时间: ${CYAN}${hours:-N/A}${NC} 小时"
        echo -e "温度: ${CYAN}${temp:-N/A}${NC} °C"
        echo ""
        print_separator
        echo -e "${GREEN}请选择修复方式:${NC}"
        echo ""
        echo "  1) 🔍 快速检测 - SMART 短测试 (约2分钟)"
        echo "  2) 🔎 完整检测 - SMART 长测试 (约1-2小时)"
        echo "  3) 📝 扫描坏块 - 只读扫描不修复 (约2-4小时)"
        echo "  4) ⚡ 快速修复 - 修复已知坏扇区"
        echo "  5) 🔧 标准修复 - 扫描并尝试修复"
        echo -e "  6) 💪 强力修复 - 破坏性全盘修复 ${RED}[数据丢失!]${NC}"
        echo -e "  7) 🔄 完整重建 - 修复+分区+格式化 ${RED}[数据丢失!]${NC}"
        echo "  0) ← 返回上级菜单"
        echo ""
        print_separator

        read -p "请输入选项 [0-7]: " repair_choice

        case $repair_choice in
            1) smart_short_test "$disk" ;;
            2) smart_long_test "$disk" ;;
            3) scan_badblocks_readonly "$disk" ;;
            4) quick_fix_known_sectors "$disk" ;;
            5) standard_repair "$disk" ;;
            6) destructive_repair "$disk" ;;
            7) full_rebuild "$disk" ;;
            0) return ;;
            *) echo -e "${RED}无效选项${NC}"; sleep 1 ;;
        esac
    done
}

#===============================================================================
# 修复函数
#===============================================================================

smart_short_test() {
    local disk="$1"
    print_header
    echo -e "${GREEN}🔍 运行 SMART 短测试 /dev/$disk${NC}"
    print_separator

    log "开始 SMART 短测试: /dev/$disk"

    smartctl -t short "/dev/$disk"
    echo ""
    echo -e "${YELLOW}测试已启动，预计需要 2 分钟...${NC}"
    
    local count=0
    while [[ $count -lt 130 ]]; do
        echo -ne "\r等待中... $((130-count)) 秒 "
        sleep 1
        ((count++))
    done
    echo ""

    echo ""
    echo -e "${GREEN}测试结果:${NC}"
    smartctl -l selftest "/dev/$disk" | head -15

    log "SMART 短测试完成: /dev/$disk"
    pause
}

smart_long_test() {
    local disk="$1"
    print_header
    echo -e "${GREEN}🔎 运行 SMART 长测试 /dev/$disk${NC}"
    print_separator

    local est_time=$(smartctl -c "/dev/$disk" 2>/dev/null | grep "Extended self-test" | grep -oE "[0-9]+" | head -1)

    echo -e "${YELLOW}预计需要 ${est_time:-90} 分钟，测试将在后台运行${NC}"

    if ! confirm "确认开始长测试?"; then
        return
    fi

    log "开始 SMART 长测试: /dev/$disk"

    smartctl -t long "/dev/$disk"

    echo ""
    echo -e "${GREEN}测试已启动！${NC}"
    echo "可以使用以下命令查看进度:"
    echo -e "${CYAN}  smartctl -l selftest /dev/$disk${NC}"
    echo -e "${CYAN}  smartctl -a /dev/$disk | grep -i progress${NC}"

    log "SMART 长测试已启动: /dev/$disk"
    pause
}

scan_badblocks_readonly() {
    local disk="$1"
    print_header
    echo -e "${GREEN}📝 只读扫描坏块 /dev/$disk${NC}"
    print_separator

    echo -e "${YELLOW}此操作不会修改数据，但需要较长时间${NC}"
    echo ""

    if ! confirm "确认开始扫描?"; then
        return
    fi

    if check_disk_mounted "$disk"; then
        echo -e "${RED}硬盘已挂载，请先卸载${NC}"
        pause
        return
    fi

    log "开始只读坏块扫描: /dev/$disk"

    local output_file="$LOG_DIR/badblocks_${disk}_$(date +%Y%m%d_%H%M%S).txt"

    echo -e "${CYAN}扫描进行中，输出文件: $output_file${NC}"
    echo ""

    badblocks -sv -b 512 "/dev/$disk" -o "$output_file" 2>&1 | tee -a "$LOG_FILE"

    echo ""
    if [[ -s "$output_file" ]]; then
        local count=$(wc -l < "$output_file")
        echo -e "${RED}发现 $count 个坏块！${NC}"
        echo "坏块列表已保存到: $output_file"
    else
        echo -e "${GREEN}未发现坏块！${NC}"
    fi

    log "只读坏块扫描完成: /dev/$disk"
    pause
}

quick_fix_known_sectors() {
    local disk="$1"
    print_header
    echo -e "${GREEN}⚡ 快速修复已知坏扇区 /dev/$disk${NC}"
    print_separator

    local error_lba=$(smartctl -l selftest "/dev/$disk" 2>/dev/null | grep -E "read failure|Completed.*failure" | head -1 | awk '{print $NF}')

    if [[ -z "$error_lba" || "$error_lba" == "-" ]]; then
        echo -e "${YELLOW}未找到已知的坏扇区 LBA${NC}"
        echo "建议先运行 SMART 测试或坏块扫描"
        pause
        return
    fi

    echo -e "发现错误扇区 LBA: ${RED}$error_lba${NC}"
    echo ""
    echo -e "${YELLOW}⚠️  此操作将向该扇区写入零，该扇区的数据将丢失！${NC}"
    echo ""

    if ! confirm "确认修复扇区 $error_lba?"; then
        return
    fi

    log "开始修复扇区: /dev/$disk LBA=$error_lba"

    echo "正在修复..."
    hdparm --write-sector "$error_lba" --yes-i-know-what-i-am-doing "/dev/$disk" 2>&1 | tee -a "$LOG_FILE"

    echo ""
    echo -e "${GREEN}扇区修复命令已执行${NC}"

    log "扇区修复完成: /dev/$disk LBA=$error_lba"
    pause
}

standard_repair() {
    local disk="$1"
    print_header
    echo -e "${GREEN}🔧 标准修复 /dev/$disk${NC}"
    print_separator

    echo -e "${YELLOW}此操作将:${NC}"
    echo "  1. 扫描全盘查找坏块"
    echo "  2. 尝试修复发现的坏扇区"
    echo ""

    if check_disk_mounted "$disk"; then
        echo -e "${RED}错误: 硬盘已挂载，请先卸载${NC}"
        pause
        return
    fi

    if ! confirm "确认开始标准修复?"; then
        return
    fi

    log "开始标准修复: /dev/$disk"

    local badblocks_file="$LOG_DIR/badblocks_${disk}_$(date +%Y%m%d_%H%M%S).txt"

    echo ""
    echo -e "${CYAN}[1/3] 扫描坏块...${NC}"
    badblocks -sv -b 512 "/dev/$disk" -o "$badblocks_file" 2>&1 | tee -a "$LOG_FILE"

    if [[ -s "$badblocks_file" ]]; then
        echo ""
        echo -e "${CYAN}[2/3] 发现坏块，尝试修复...${NC}"

        while read -r lba; do
            echo "修复 LBA: $lba"
            hdparm --write-sector "$lba" --yes-i-know-what-i-am-doing "/dev/$disk" >> "$LOG_FILE" 2>&1
        done < "$badblocks_file"

        echo ""
        echo -e "${CYAN}[3/3] 验证修复结果...${NC}"
        smartctl -t short "/dev/$disk"
        sleep 130
        smartctl -l selftest "/dev/$disk"
    else
        echo ""
        echo -e "${GREEN}未发现坏块${NC}"
    fi

    echo ""
    smartctl -A "/dev/$disk" | grep -E "Reallocated|Current_Pending|Offline_Uncorrectable"

    log "标准修复完成: /dev/$disk"
    pause
}

destructive_repair() {
    local disk="$1"
    print_header
    echo -e "${RED}💪 强力修复（破坏性） /dev/$disk${NC}"
    print_separator

    echo -e "${RED}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                      ⚠️  严重警告 ⚠️                            ║${NC}"
    echo -e "${RED}║                                                                ║${NC}"
    echo -e "${RED}║    此操作将完全清除硬盘上的所有数据！                          ║${NC}"
    echo -e "${RED}║    此操作不可逆！请确保已备份重要数据！                        ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    if check_disk_mounted "$disk"; then
        echo -e "${RED}错误: 硬盘已挂载，请先卸载${NC}"
        pause
        return
    fi

    read -p "请输入 'YES' 确认: " confirm_text

    if [[ "$confirm_text" != "YES" ]]; then
        echo -e "${YELLOW}操作已取消${NC}"
        pause
        return
    fi

    log "开始破坏性修复: /dev/$disk"

    local badblocks_file="$LOG_DIR/badblocks_destructive_${disk}_$(date +%Y%m%d_%H%M%S).txt"

    echo ""
    echo -e "${CYAN}开始破坏性读写测试...${NC}"
    badblocks -wsv -b 4096 -p 1 "/dev/$disk" -o "$badblocks_file" 2>&1 | tee -a "$LOG_FILE"

    echo ""
    if [[ -s "$badblocks_file" ]]; then
        local count=$(wc -l < "$badblocks_file")
        echo -e "${YELLOW}仍有 $count 个无法修复的坏块${NC}"
    else
        echo -e "${GREEN}所有坏块已修复！${NC}"
    fi

    smartctl -A "/dev/$disk" | grep -E "Reallocated|Current_Pending|Offline_Uncorrectable"

    log "破坏性修复完成: /dev/$disk"
    pause
}

full_rebuild() {
    local disk="$1"
    print_header
    echo -e "${RED}🔄 完整重建 /dev/$disk${NC}"
    print_separator

    echo -e "${RED}此操作将清除所有数据并重建硬盘！${NC}"
    echo ""

    if check_disk_mounted "$disk"; then
        echo -e "${RED}错误: 硬盘已挂载${NC}"
        pause
        return
    fi

    read -p "请输入硬盘名确认 (如 sdb): " confirm_disk
    if [[ "$confirm_disk" != "$disk" ]]; then
        echo -e "${YELLOW}操作已取消${NC}"
        pause
        return
    fi

    read -p "请输入 'DESTROY ALL DATA' 确认: " final_confirm
    if [[ "$final_confirm" != "DESTROY ALL DATA" ]]; then
        echo -e "${YELLOW}操作已取消${NC}"
        pause
        return
    fi

    # 选择文件系统
    echo ""
    echo "选择文件系统格式:"
    echo "  1) ext4  - Linux 推荐"
    echo "  2) xfs   - 大文件优化"
    echo "  3) btrfs - 快照支持"
    echo ""
    read -p "选择 [1-3]: " fs_choice

    local fs_type
    case $fs_choice in
        1) fs_type="ext4" ;;
        2) fs_type="xfs" ;;
        3) fs_type="btrfs" ;;
        *) fs_type="ext4" ;;
    esac

    log "开始完整重建: /dev/$disk 文件系统: $fs_type"

    local badblocks_file="$LOG_DIR/badblocks_rebuild_${disk}_$(date +%Y%m%d_%H%M%S).txt"

    echo ""
    echo -e "${CYAN}[1/5] 破坏性扫描修复...${NC}"
    badblocks -wsv -b 4096 "/dev/$disk" -o "$badblocks_file" 2>&1 | tee -a "$LOG_FILE"

    echo ""
    echo -e "${CYAN}[2/5] 清除分区表...${NC}"
    wipefs -af "/dev/$disk" >> "$LOG_FILE" 2>&1
    dd if=/dev/zero of="/dev/$disk" bs=1M count=100 status=none 2>> "$LOG_FILE"

    echo ""
    echo -e "${CYAN}[3/5] 创建分区表...${NC}"
    parted -s "/dev/$disk" mklabel gpt >> "$LOG_FILE" 2>&1
    parted -s "/dev/$disk" mkpart primary "$fs_type" 0% 100% >> "$LOG_FILE" 2>&1
    sleep 2

    echo ""
    echo -e "${CYAN}[4/5] 格式化为 $fs_type...${NC}"
    
    case $fs_type in
        ext4)
            if [[ -s "$badblocks_file" ]]; then
                mkfs.ext4 -l "$badblocks_file" -L "Disk_${disk}" "/dev/${disk}1" 2>&1 | tee -a "$LOG_FILE"
            else
                mkfs.ext4 -L "Disk_${disk}" "/dev/${disk}1" 2>&1 | tee -a "$LOG_FILE"
            fi
            ;;
        xfs)
            mkfs.xfs -f -L "Disk_${disk}" "/dev/${disk}1" 2>&1 | tee -a "$LOG_FILE"
            ;;
        btrfs)
            mkfs.btrfs -f -L "Disk_${disk}" "/dev/${disk}1" 2>&1 | tee -a "$LOG_FILE"
            ;;
    esac

    echo ""
    echo -e "${CYAN}[5/5] 验证结果...${NC}"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL "/dev/$disk"

    echo ""
    echo -e "${GREEN}✅ 完整重建完成！${NC}"

    log "完整重建完成: /dev/$disk"
    pause
}

#===============================================================================
# 功能4: 自动修复所有问题硬盘
#===============================================================================

auto_repair_all() {
    print_header
    echo -e "${GREEN}🚨 自动扫描并修复所有问题硬盘${NC}"
    print_separator

    echo "正在扫描..."
    echo ""

    local -a problem_disks

    for disk in $(get_all_disks); do
        if check_disk_in_use "$disk"; then
            continue
        fi

        local info=$(get_disk_info "$disk")
        IFS='|' read -r model size health pending reallocated uncorrectable hours temp <<< "$info"

        if [[ "$pending" != "N/A" && "$pending" != "0" && -n "$pending" ]]; then
            problem_disks+=("$disk")
            echo -e "  发现: ${RED}/dev/$disk${NC} - 待处理坏道: $pending"
        fi
    done

    echo ""

    if [[ ${#problem_disks[@]} -eq 0 ]]; then
        echo -e "${GREEN}✅ 未发现问题硬盘${NC}"
        pause
        return
    fi

    echo -e "${YELLOW}发现 ${#problem_disks[@]} 个问题硬盘${NC}"
    echo ""
    echo "修复选项:"
    echo "  1) 快速修复 - 修复已知坏扇区"
    echo "  2) 标准修复 - 扫描并修复"
    echo -e "  3) 强力修复 - ${RED}数据丢失${NC}"
    echo "  0) 取消"
    echo ""

    read -p "选择 [0-3]: " repair_mode

    case $repair_mode in
        1)
            for disk in "${problem_disks[@]}"; do
                if ! check_disk_mounted "$disk"; then
                    quick_fix_known_sectors "$disk"
                fi
            done
            ;;
        2)
            for disk in "${problem_disks[@]}"; do
                if ! check_disk_mounted "$disk"; then
                    standard_repair "$disk"
                fi
            done
            ;;
        3)
            if confirm "确认强力修复所有问题硬盘?"; then
                for disk in "${problem_disks[@]}"; do
                    if ! check_disk_mounted "$disk"; then
                        destructive_repair "$disk"
                    fi
                done
            fi
            ;;
    esac
}

#===============================================================================
# 功能5: 格式化硬盘
#===============================================================================

format_disk_menu() {
    print_header
    echo -e "${GREEN}💾 格式化硬盘${NC}"
    echo ""

    # 显示可格式化的硬盘
    echo "可格式化的硬盘/分区:"
    print_separator
    
    local i=1
    local -a targets
    local -a target_types

    for disk in $(get_all_disks); do
        if check_disk_in_use "$disk"; then
            continue
        fi

        local size=$(lsblk -d -n -o SIZE "/dev/$disk")
        local model=$(smartctl -i "/dev/$disk" 2>/dev/null | grep "Device Model" | cut -d: -f2 | xargs 2>/dev/null)
        
        local mount_warn=""
        if check_disk_mounted "$disk"; then
            mount_warn="${YELLOW}[已挂载]${NC}"
        fi

        echo -e "  $i) /dev/$disk - ${model:-未知} ($size) - 整块硬盘 $mount_warn"
        targets+=("$disk")
        target_types+=("disk")
        ((i++))

        # 显示分区
        for part in $(lsblk -n -o NAME "/dev/$disk" 2>/dev/null | grep -v "^$disk$"); do
            part=$(echo "$part" | sed 's/[├└│─]//g' | xargs)
            if [[ -n "$part" ]]; then
                local psize=$(lsblk -n -o SIZE "/dev/$part" 2>/dev/null)
                local pfs=$(lsblk -n -o FSTYPE "/dev/$part" 2>/dev/null)
                local pmount=$(lsblk -n -o MOUNTPOINT "/dev/$part" 2>/dev/null)
                
                local part_warn=""
                if [[ -n "$pmount" ]]; then
                    part_warn="${YELLOW}[挂载于 $pmount]${NC}"
                fi

                echo -e "  $i)   └─ /dev/$part ($psize) ${pfs:-未格式化} $part_warn"
                targets+=("$part")
                target_types+=("part")
                ((i++))
            fi
        done
    done

    if [[ ${#targets[@]} -eq 0 ]]; then
        echo -e "${YELLOW}没有可格式化的硬盘${NC}"
        pause
        return
    fi

    echo "  0) 返回主菜单"
    print_separator

    read -p "选择目标 [0-$((i-1))]: " choice

    [[ "$choice" == "0" ]] && return

    if [[ "$choice" -ge 1 && "$choice" -lt "$i" ]] 2>/dev/null; then
        local target="${targets[$((choice-1))]}"
        local ttype="${target_types[$((choice-1))]}"
        format_target "$target" "$ttype"
    else
        echo -e "${RED}无效选项${NC}"
        sleep 1
    fi
}

format_target() {
    local target="$1"
    local ttype="$2"

    print_header
    echo -e "${GREEN}💾 格式化 /dev/$target${NC}"
    print_separator

    # 检查挂载
    if mount | grep -q "/dev/$target"; then
        echo -e "${RED}目标已挂载，请先卸载${NC}"
        echo ""
        mount | grep "/dev/$target"
        pause
        return
    fi

    local size=$(lsblk -d -n -o SIZE "/dev/$target" 2>/dev/null)
    echo -e "目标: ${CYAN}/dev/$target${NC}"
    echo -e "容量: ${CYAN}$size${NC}"
    echo -e "类型: ${CYAN}$ttype${NC}"
    echo ""

    echo -e "${WHITE}选择文件系统格式:${NC}"
    echo ""
    echo "  ┌─────────────────────────────────────────────────────────┐"
    echo "  │  ${GREEN}Linux 文件系统${NC}                                        │"
    echo "  │    1) ext4   - Linux 标准，推荐大多数场景              │"
    echo "  │    2) ext3   - 兼容旧系统                              │"
    echo "  │    3) xfs    - 大文件和高性能场景                      │"
    echo "  │    4) btrfs  - 支持快照、压缩                          │"
    echo "  │                                                         │"
    echo "  │  ${YELLOW}跨平台文件系统${NC}                                        │"
    echo "  │    5) ntfs   - Windows 兼容                            │"
    echo "  │    6) fat32  - 最大兼容性 (单文件≤4GB)                 │"
    echo "  │    7) exfat  - 大文件 + 跨平台兼容                     │"
    echo "  │                                                         │"
    echo "  │    0) 取消                                              │"
    echo "  └─────────────────────────────────────────────────────────┘"
    echo ""

    read -p "选择文件系统 [0-7]: " fs_choice

    local fs_type fs_cmd
    case $fs_choice in
        1) fs_type="ext4"; fs_cmd="mkfs.ext4" ;;
        2) fs_type="ext3"; fs_cmd="mkfs.ext3" ;;
        3) fs_type="xfs"; fs_cmd="mkfs.xfs -f" ;;
        4) fs_type="btrfs"; fs_cmd="mkfs.btrfs -f" ;;
        5) fs_type="ntfs"; fs_cmd="mkfs.ntfs -f" ;;
        6) fs_type="vfat"; fs_cmd="mkfs.vfat -F 32" ;;
        7) fs_type="exfat"; fs_cmd="mkfs.exfat" ;;
        0) return ;;
        *) echo -e "${RED}无效选项${NC}"; sleep 1; return ;;
    esac

    # 输入卷标
    echo ""
    read -p "输入卷标 (直接回车使用默认): " label
    label="${label:-Disk_$target}"

    # 如果是整块硬盘，需要先分区
    local format_target="/dev/$target"
    
    if [[ "$ttype" == "disk" ]]; then
        echo ""
        echo -e "${YELLOW}将对整块硬盘进行分区...${NC}"
        
        if ! confirm "确认格式化整块硬盘 /dev/$target?"; then
            return
        fi

        echo ""
        echo -e "${CYAN}[1/3] 清除分区表...${NC}"
        wipefs -af "/dev/$target" >> "$LOG_FILE" 2>&1
        dd if=/dev/zero of="/dev/$target" bs=1M count=10 status=none 2>> "$LOG_FILE"

        echo -e "${CYAN}[2/3] 创建分区...${NC}"
        parted -s "/dev/$target" mklabel gpt >> "$LOG_FILE" 2>&1
        parted -s "/dev/$target" mkpart primary "$fs_type" 0% 100% >> "$LOG_FILE" 2>&1
        sleep 2
        partprobe "/dev/$target" 2>/dev/null

        format_target="/dev/${target}1"
        echo -e "${CYAN}[3/3] 格式化分区...${NC}"
    else
        if ! confirm "确认格式化 /dev/$target?"; then
            return
        fi
    fi

    echo ""
    echo -e "${CYAN}正在格式化为 $fs_type...${NC}"

    local label_opt=""
    case $fs_type in
        ext4|ext3) label_opt="-L '$label'" ;;
        xfs|btrfs) label_opt="-L '$label'" ;;
        ntfs) label_opt="-L '$label'" ;;
        vfat) label_opt="-n '${label:0:11}'" ;;  # FAT32 标签最多11字符
        exfat) label_opt="-n '$label'" ;;
    esac

    eval "$fs_cmd $label_opt '$format_target'" 2>&1 | tee -a "$LOG_FILE"

    echo ""
    print_double_separator
    echo -e "${GREEN}✅ 格式化完成！${NC}"
    print_double_separator
    echo ""
    echo "分区信息:"
    if [[ "$ttype" == "disk" ]]; then
        lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,UUID "/dev/$target"
    else
        lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,UUID "$format_target"
    fi

    echo ""
    echo "挂载命令:"
    echo -e "${CYAN}  mkdir -p /mnt/$label${NC}"
    echo -e "${CYAN}  mount $format_target /mnt/$label${NC}"

    log "格式化完成: $format_target 文件系统: $fs_type 卷标: $label"
    pause
}

#===============================================================================
# 功能6: 分区管理
#===============================================================================

partition_menu() {
    while true; do
        print_header
        echo -e "${GREEN}📁 分区管理${NC}"
        echo ""

        # 显示当前分区状态
        echo -e "${WHITE}当前分区状态:${NC}"
        print_separator
        lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,LABEL
        print_separator
        echo ""

        echo "操作选项:"
        echo "  1) 查看详细分区信息"
        echo "  2) 创建新分区表 (GPT/MBR)"
        echo "  3) 创建新分区"
        echo "  4) 删除分区"
        echo "  5) 调整分区大小"
        echo "  0) 返回主菜单"
        echo ""

        read -p "选择 [0-5]: " part_choice

        case $part_choice in
            1) show_partition_detail ;;
            2) create_partition_table ;;
            3) create_partition ;;
            4) delete_partition ;;
            5) resize_partition ;;
            0) return ;;
            *) echo -e "${RED}无效选项${NC}"; sleep 1 ;;
        esac
    done
}

show_partition_detail() {
    print_header
    echo -e "${GREEN}分区详细信息${NC}"
    print_separator

    for disk in $(get_all_disks); do
        echo ""
        echo -e "${CYAN}=== /dev/$disk ===${NC}"
        parted "/dev/$disk" print 2>/dev/null
    done

    pause
}

create_partition_table() {
    print_header
    echo -e "${GREEN}创建新分区表${NC}"
    echo ""

    echo "选择硬盘:"
    local i=1
    local -a disks
    for disk in $(get_all_disks); do
        if check_disk_in_use "$disk"; then
            continue
        fi
        disks+=("$disk")
        local size=$(lsblk -d -n -o SIZE "/dev/$disk")
        echo "  $i) /dev/$disk ($size)"
        ((i++))
    done
    echo "  0) 取消"

    read -p "选择 [0-$((i-1))]: " choice
    [[ "$choice" == "0" ]] && return

    if [[ "$choice" -ge 1 && "$choice" -lt "$i" ]] 2>/dev/null; then
        local disk="${disks[$((choice-1))]}"

        if check_disk_mounted "$disk"; then
            echo -e "${RED}硬盘已挂载${NC}"
            pause
            return
        fi

        echo ""
        echo "选择分区表类型:"
        echo "  1) GPT - 推荐，支持大于2TB"
        echo "  2) MBR - 兼容旧系统"
        read -p "选择 [1-2]: " table_type

        local label
        case $table_type in
            1) label="gpt" ;;
            2) label="msdos" ;;
            *) echo -e "${RED}无效选项${NC}"; pause; return ;;
        esac

        echo ""
        echo -e "${RED}⚠️  这将清除 /dev/$disk 上的所有数据！${NC}"
        if confirm "确认创建 $label 分区表?"; then
            wipefs -af "/dev/$disk" >> "$LOG_FILE" 2>&1
            parted -s "/dev/$disk" mklabel "$label"
            echo -e "${GREEN}分区表创建成功！${NC}"
            log "创建分区表: /dev/$disk $label"
        fi
    fi
    pause
}

create_partition() {
    print_header
    echo -e "${GREEN}创建新分区${NC}"
    echo ""

    echo "选择硬盘:"
    local i=1
    local -a disks
    for disk in $(get_all_disks); do
        if check_disk_in_use "$disk"; then
            continue
        fi
        disks+=("$disk")
        local size=$(lsblk -d -n -o SIZE "/dev/$disk")
        local parts=$(lsblk -n "/dev/$disk" | wc -l)
        echo "  $i) /dev/$disk ($size) - $((parts-1)) 个分区"
        ((i++))
    done
    echo "  0) 取消"

    read -p "选择 [0-$((i-1))]: " choice
    [[ "$choice" == "0" ]] && return

    if [[ "$choice" -ge 1 && "$choice" -lt "$i" ]] 2>/dev/null; then
        local disk="${disks[$((choice-1))]}"

        echo ""
        echo "当前分区:"
        parted "/dev/$disk" print free 2>/dev/null

        echo ""
        echo "输入分区大小 (例如: 100GB, 50%, 或直接回车使用全部空间):"
        read -p "大小: " psize
        psize="${psize:-100%}"

        echo ""
        if confirm "确认在 /dev/$disk 上创建分区?"; then
            parted -s "/dev/$disk" mkpart primary 0% "$psize" 2>&1 | tee -a "$LOG_FILE"
            partprobe "/dev/$disk" 2>/dev/null
            echo -e "${GREEN}分区创建成功！${NC}"
            lsblk "/dev/$disk"
            log "创建分区: /dev/$disk 大小: $psize"
        fi
    fi
    pause
}

delete_partition() {
    print_header
    echo -e "${GREEN}删除分区${NC}"
    echo ""

    echo "选择要删除的分区:"
    local i=1
    local -a parts

    for disk in $(get_all_disks); do
        if check_disk_in_use "$disk"; then
            continue
        fi
        for part in $(lsblk -n -o NAME "/dev/$disk" 2>/dev/null | grep -v "^$disk$"); do
            part=$(echo "$part" | sed 's/[├└│─]//g' | xargs)
            if [[ -n "$part" ]]; then
                local pmount=$(lsblk -n -o MOUNTPOINT "/dev/$part" 2>/dev/null)
                if [[ -z "$pmount" ]]; then
                    parts+=("$part")
                    local psize=$(lsblk -n -o SIZE "/dev/$part")
                    local pfs=$(lsblk -n -o FSTYPE "/dev/$part")
                    echo "  $i) /dev/$part ($psize) $pfs"
                    ((i++))
                fi
            fi
        done
    done
    echo "  0) 取消"

    if [[ ${#parts[@]} -eq 0 ]]; then
        echo -e "${YELLOW}没有可删除的分区${NC}"
        pause
        return
    fi

    read -p "选择 [0-$((i-1))]: " choice
    [[ "$choice" == "0" ]] && return

    if [[ "$choice" -ge 1 && "$choice" -lt "$i" ]] 2>/dev/null; then
        local part="${parts[$((choice-1))]}"
        local disk=$(echo "$part" | sed 's/[0-9]*$//')
        local partnum=$(echo "$part" | grep -oE '[0-9]+$')

        echo ""
        echo -e "${RED}⚠️  这将删除 /dev/$part 上的所有数据！${NC}"
        if confirm "确认删除分区?"; then
            parted -s "/dev/$disk" rm "$partnum" 2>&1 | tee -a "$LOG_FILE"
            partprobe "/dev/$disk" 2>/dev/null
            echo -e "${GREEN}分区删除成功！${NC}"
            log "删除分区: /dev/$part"
        fi
    fi
    pause
}

resize_partition() {
    echo -e "${YELLOW}分区调整功能需要使用专业工具${NC}"
    echo ""
    echo "推荐命令:"
    echo -e "${CYAN}  parted /dev/sdX resizepart N SIZE${NC}"
    echo -e "${CYAN}  resize2fs /dev/sdXN  # ext4${NC}"
    echo -e "${CYAN}  xfs_growfs /mountpoint  # xfs${NC}"
    pause
}

#===============================================================================
# 功能7: 挂载管理
#===============================================================================

mount_menu() {
    while true; do
        print_header
        echo -e "${GREEN}🗂️  挂载/卸载管理${NC}"
        echo ""

        echo -e "${WHITE}当前挂载状态:${NC}"
        print_separator
        lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,LABEL | grep -v "^loop"
        print_separator
        echo ""

        echo "操作选项:"
        echo "  1) 挂载分区"
        echo "  2) 卸载分区"
        echo "  3) 查看挂载详情"
        echo "  0) 返回主菜单"
        echo ""

        read -p "选择 [0-3]: " mount_choice

        case $mount_choice in
            1) mount_partition ;;
            2) unmount_partition ;;
            3) mount | grep "^/dev"; pause ;;
            0) return ;;
            *) echo -e "${RED}无效选项${NC}"; sleep 1 ;;
        esac
    done
}

mount_partition() {
    print_header
    echo -e "${GREEN}挂载分区${NC}"
    echo ""

    echo "可挂载的分区:"
    local i=1
    local -a parts

    for disk in $(get_all_disks); do
        for part in $(lsblk -n -o NAME "/dev/$disk" 2>/dev/null | grep -v "^$disk$"); do
            part=$(echo "$part" | sed 's/[├└│─]//g' | xargs)
            if [[ -n "$part" ]]; then
                local pmount=$(lsblk -n -o MOUNTPOINT "/dev/$part" 2>/dev/null)
                local pfs=$(lsblk -n -o FSTYPE "/dev/$part" 2>/dev/null)
                if [[ -z "$pmount" && -n "$pfs" ]]; then
                    parts+=("$part")
                    local psize=$(lsblk -n -o SIZE "/dev/$part")
                    local plabel=$(lsblk -n -o LABEL "/dev/$part")
                    echo "  $i) /dev/$part ($psize) $pfs ${plabel:+[$plabel]}"
                    ((i++))
                fi
            fi
        done
    done
    echo "  0) 取消"

    if [[ ${#parts[@]} -eq 0 ]]; then
        echo -e "${YELLOW}没有可挂载的分区${NC}"
        pause
        return
    fi

    read -p "选择 [0-$((i-1))]: " choice
    [[ "$choice" == "0" ]] && return

    if [[ "$choice" -ge 1 && "$choice" -lt "$i" ]] 2>/dev/null; then
        local part="${parts[$((choice-1))]}"

        echo ""
        read -p "输入挂载点 (默认 /mnt/$part): " mpoint
        mpoint="${mpoint:-/mnt/$part}"

        mkdir -p "$mpoint"
        if mount "/dev/$part" "$mpoint"; then
            echo -e "${GREEN}挂载成功！${NC}"
            echo "挂载点: $mpoint"
            log "挂载: /dev/$part -> $mpoint"
        else
            echo -e "${RED}挂载失败${NC}"
        fi
    fi
    pause
}

unmount_partition() {
    print_header
    echo -e "${GREEN}卸载分区${NC}"
    echo ""

    echo "已挂载的分区:"
    local i=1
    local -a mounts

    while read -r line; do
        local dev=$(echo "$line" | awk '{print $1}')
        local mp=$(echo "$line" | awk '{print $3}')
        
        # 排除系统关键挂载点
        if [[ "$mp" != "/" && "$mp" != "/boot"* && "$mp" != "/home" ]]; then
            mounts+=("$dev:$mp")
            echo "  $i) $dev -> $mp"
            ((i++))
        fi
    done < <(mount | grep "^/dev/sd")

    echo "  0) 取消"

    if [[ ${#mounts[@]} -eq 0 ]]; then
        echo -e "${YELLOW}没有可卸载的分区${NC}"
        pause
        return
    fi

    read -p "选择 [0-$((i-1))]: " choice
    [[ "$choice" == "0" ]] && return

    if [[ "$choice" -ge 1 && "$choice" -lt "$i" ]] 2>/dev/null; then
        local mount_info="${mounts[$((choice-1))]}"
        local dev=$(echo "$mount_info" | cut -d: -f1)
        local mp=$(echo "$mount_info" | cut -d: -f2)

        if umount "$mp"; then
            echo -e "${GREEN}卸载成功！${NC}"
            log "卸载: $dev from $mp"
        else
            echo -e "${RED}卸载失败，可能有进程正在使用${NC}"
            echo "使用以下命令查看:"
            echo -e "${CYAN}  lsof $mp${NC}"
            echo -e "${CYAN}  fuser -m $mp${NC}"
        fi
    fi
    pause
}

#===============================================================================
# 功能8: 查看日志
#===============================================================================

view_logs() {
    print_header
    echo -e "${GREEN}📋 修复日志${NC}"
    print_separator

    if [[ ! -d "$LOG_DIR" ]]; then
        echo "暂无日志"
        pause
        return
    fi

    local -a logs
    local i=1
    
    while IFS= read -r -d '' log_file; do
        logs+=("$log_file")
        local size=$(du -h "$log_file" 2>/dev/null | cut -f1)
        local date=$(stat -c %y "$log_file" 2>/dev/null | cut -d. -f1)
        echo "  $i) $(basename "$log_file") - $size - $date"
        ((i++))
    done < <(find "$LOG_DIR" -type f \( -name "*.txt" -o -name "*.log" \) -print0 2>/dev/null | sort -z)

    if [[ ${#logs[@]} -eq 0 ]]; then
        echo "暂无日志"
        pause
        return
    fi

    echo "  0) 返回"
    echo ""

    read -p "选择 [0-$((i-1))]: " choice
    [[ "$choice" == "0" ]] && return

    if [[ "$choice" -ge 1 && "$choice" -lt "$i" ]] 2>/dev/null; then
        less "${logs[$((choice-1))]}"
    fi
}

#===============================================================================
# 功能9: 帮助信息
#===============================================================================

show_help() {
    print_header
    echo -e "${GREEN}❓ 帮助信息${NC}"
    print_double_separator

    echo "
${WHITE}【文件系统选择指南】${NC}

  ${CYAN}ext4${NC}   - Linux 默认，稳定可靠，推荐大多数场景
  ${CYAN}xfs${NC}    - 高性能，适合大文件和数据库
  ${CYAN}btrfs${NC}  - 支持快照、压缩、RAID
  ${CYAN}ntfs${NC}   - Windows 兼容，跨平台数据交换
  ${CYAN}fat32${NC}  - 最大兼容性，但单文件不能超过 4GB
  ${CYAN}exfat${NC}  - 大文件支持，U盘/移动硬盘推荐

${WHITE}【SMART 指标说明】${NC}

  Reallocated_Sector_Ct   - 已重映射扇区（硬盘已处理）
  Current_Pending_Sector  - 待处理坏扇区（需要关注！）
  Offline_Uncorrectable   - 无法修复扇区（严重！）

${WHITE}【修复级别】${NC}

  快速修复 - 仅修复已知坏扇区，数据安全
  标准修复 - 扫描+修复，尽量保留数据
  强力修复 - 破坏性修复，数据会丢失
  完整重建 - 修复+分区+格式化

${WHITE}【建议】${NC}

  • Current_Pending > 0   : 尽快修复
  • Current_Pending > 100 : 考虑更换硬盘
  • 硬盘异响            : 立即备份数据

${WHITE}【日志位置】${NC} $LOG_DIR/
"
    pause
}

#===============================================================================
# 主程序
#===============================================================================

main() {
    init
    while true; do
        show_main_menu
    done
}

main "$@"
