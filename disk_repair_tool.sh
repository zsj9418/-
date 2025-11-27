#!/bin/bash

#===============================================================================
# PVE 硬盘智能检测与修复工具
# 版本: 1.1
# 功能: 自动检测硬盘健康状态，提供菜单式修复选项
#===============================================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
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
    for cmd in smartctl hdparm badblocks parted; do
        if ! command -v $cmd &>/dev/null; then
            need_install=1
            break
        fi
    done

    if [[ $need_install -eq 1 ]]; then
        echo -e "${YELLOW}正在安装必要工具...${NC}"
        apt update -qq 2>/dev/null
        apt install -y smartmontools hdparm e2fsprogs parted > /dev/null 2>&1
    fi
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

print_header() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║           PVE 硬盘智能检测与修复工具 v1.1                        ║"
    echo "║                                                                  ║"
    echo "║  ⚠️  警告: 修复操作可能导致数据丢失，请先备份重要数据！          ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_separator() {
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
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
# 硬盘检测函数
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
    
    # 检查是否是系统盘
    local root_device=$(findmnt -n -o SOURCE / 2>/dev/null)
    if [[ -n "$root_device" ]]; then
        local root_disk=$(lsblk -n -o PKNAME "$root_device" 2>/dev/null)
        if [[ "$disk" == "$root_disk" ]]; then
            return 0
        fi
    fi

    # 检查 LVM
    if pvs 2>/dev/null | grep -q "/dev/$disk"; then
        return 0
    fi

    # 检查 ZFS
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

#===============================================================================
# 主菜单
#===============================================================================

show_main_menu() {
    print_header
    echo -e "${GREEN}请选择操作:${NC}"
    echo ""
    echo "  1) 📊 扫描所有硬盘健康状态"
    echo "  2) 🔍 查看单个硬盘详细信息"
    echo "  3) 🔧 修复指定硬盘"
    echo "  4) 🚨 一键扫描并修复所有问题硬盘"
    echo "  5) 📋 查看修复日志"
    echo "  6) ❓ 帮助信息"
    echo "  0) 🚪 退出"
    echo ""
    print_separator
    read -p "请输入选项 [0-6]: " choice
    
    case $choice in
        1) scan_all_disks ;;
        2) view_disk_detail ;;
        3) repair_disk_menu ;;
        4) auto_repair_all ;;
        5) view_logs ;;
        6) show_help ;;
        0) echo "再见！"; exit 0 ;;
        *) echo -e "${RED}无效选项${NC}"; sleep 1 ;;
    esac
}

#===============================================================================
# 功能1: 扫描所有硬盘
#===============================================================================

scan_all_disks() {
    print_header
    echo -e "${GREEN}📊 正在扫描所有硬盘...${NC}"
    echo ""
    print_separator

    printf "%-6s %-25s %-8s %-8s %-10s %-10s %-8s %-6s %-8s\n" \
        "设备" "型号" "容量" "状态" "待处理" "已重映射" "运行时" "温度" "可操作"
    print_separator

    local disks=$(get_all_disks)
    local problem_count=0

    for disk in $disks; do
        local info=$(get_disk_info "$disk")
        IFS='|' read -r model size health pending reallocated uncorrectable hours temp <<< "$info"

        model=$(echo "$model" | cut -c1-23)
        local status=$(get_disk_status "$pending" "$reallocated" "$health")

        local operable
        if check_disk_in_use "$disk"; then
            operable="${RED}系统盘${NC}"
        elif check_disk_mounted "$disk"; then
            operable="${YELLOW}已挂载${NC}"
        else
            operable="${GREEN}可操作${NC}"
        fi

        if [[ "$pending" != "N/A" && "$pending" != "0" && -n "$pending" ]]; then
            ((problem_count++))
        fi

        printf "%-6s %-25s %-8s %-18b %-10s %-10s %-8s %-6s %-18b\n" \
            "$disk" "${model:-未知}" "$size" "$status" "${pending:-N/A}" "${reallocated:-N/A}" \
            "${hours:-N/A}h" "${temp:-N/A}C" "$operable"
    done

    print_separator
    echo ""

    if [[ $problem_count -gt 0 ]]; then
        echo -e "${RED}⚠️  发现 $problem_count 个硬盘存在问题，建议进行修复！${NC}"
    else
        echo -e "${GREEN}✅ 所有硬盘状态良好${NC}"
    fi

    log "扫描完成，发现 $problem_count 个问题硬盘"
    pause
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
    print_separator

    echo -e "${CYAN}【基本信息】${NC}"
    smartctl -i "/dev/$disk" 2>/dev/null | grep -E "Model|Serial|Capacity|Sector|Firmware"

    echo ""
    echo -e "${CYAN}【健康状态】${NC}"
    smartctl -H "/dev/$disk" 2>/dev/null | grep -E "overall-health|test result"

    echo ""
    echo -e "${CYAN}【关键 SMART 指标】${NC}"
    printf "%-30s %-10s %-10s %-10s\n" "指标" "当前值" "阈值" "原始值"
    print_separator

    smartctl -A "/dev/$disk" 2>/dev/null | grep -E "Reallocated_Sector|Current_Pending|Offline_Uncorrectable|Power_On_Hours|Temperature|Raw_Read_Error" | \
    while read -r line; do
        local name=$(echo "$line" | awk '{print $2}')
        local value=$(echo "$line" | awk '{print $4}')
        local thresh=$(echo "$line" | awk '{print $6}')
        local raw=$(echo "$line" | awk '{print $10}')
        printf "%-30s %-10s %-10s %-10s\n" "$name" "$value" "$thresh" "$raw"
    done

    echo ""
    echo -e "${CYAN}【自检历史】${NC}"
    smartctl -l selftest "/dev/$disk" 2>/dev/null | head -20

    echo ""
    echo -e "${CYAN}【分区信息】${NC}"
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE "/dev/$disk"

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

        echo -e "  $i) /dev/$disk - ${model:-未知} ($size) - 状态: $status 待处理坏道: ${pending:-0} $mount_status"
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
        echo ""
        print_separator
        echo -e "${GREEN}请选择修复方式:${NC}"
        echo ""
        echo "  1) 🔍 快速检测 - SMART 短测试 (约2分钟)"
        echo "  2) 🔎 完整检测 - SMART 长测试 (约1-2小时)"
        echo "  3) 📝 扫描坏块 - 只读扫描不修复 (约2-4小时)"
        echo "  4) ⚡ 快速修复 - 修复已知坏扇区 (几秒钟)"
        echo "  5) 🔧 标准修复 - 扫描并尝试修复 (约3-5小时)"
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
    echo "正在等待测试完成..."

    sleep 130

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

    log "SMART 长测试已启动: /dev/$disk"
    pause
}

scan_badblocks_readonly() {
    local disk="$1"
    print_header
    echo -e "${GREEN}📝 只读扫描坏块 /dev/$disk${NC}"
    print_separator

    echo -e "${YELLOW}此操作不���修改数据，但需要较长时间${NC}"
    echo ""

    if ! confirm "确认开始扫描?"; then
        return
    fi

    if check_disk_mounted "$disk"; then
        echo -e "${RED}硬盘已挂载，请先卸载或选择其他选项${NC}"
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
    echo "建议重新运行 SMART 测试验证修复效果"

    log "扇区修复完成: /dev/$disk LBA=$error_lba"
    pause
}

standard_repair() {
    local disk="$1"
    print_header
    echo -e "${GREEN}🔧 标准修复 /dev/$disk${NC}"
    print_separator

    echo -e "${YELLOW}此操作将:${NC}"
    echo "  1. 扫描全盘查找坏块（只读）"
    echo "  2. 尝试修复发现的坏扇区"
    echo "  3. 保留分区和数据（尽可能）"
    echo ""
    echo -e "${RED}⚠️  某些坏扇区的数据可能无法恢复${NC}"
    echo ""

    if check_disk_mounted "$disk"; then
        echo -e "${RED}错误: 硬盘已挂载，请先卸载${NC}"
        echo ""
        echo "使用以下命令卸载:"
        lsblk -o NAME,MOUNTPOINT "/dev/$disk" | grep "/" | while read -r line; do
            local mp=$(echo "$line" | awk '{print $2}')
            if [[ -n "$mp" ]]; then
                echo -e "${CYAN}  umount $mp${NC}"
            fi
        done
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
        echo -e "${GREEN}未发现坏块，硬盘状态良好${NC}"
    fi

    echo ""
    echo -e "${GREEN}修复完成！${NC}"
    smartctl -A "/dev/$disk" | grep -E "Reallocated|Current_Pending|Offline_Uncorrectable"

    log "标准修复完成: /dev/$disk"
    pause
}

destructive_repair() {
    local disk="$1"
    print_header
    echo -e "${RED}💪 强力修复（破坏性） /dev/$disk${NC}"
    print_separator

    echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                    ⚠️  严重警告 ⚠️                            ║${NC}"
    echo -e "${RED}║                                                              ║${NC}"
    echo -e "${RED}║  此操作将完全清除硬盘上的所有数据！                          ║${NC}"
    echo -e "${RED}║  包括所有分区、文件系统和文件！                              ║${NC}"
    echo -e "${RED}║                                                              ║${NC}"
    echo -e "${RED}║  此操作不可逆！请确保已备份重要数据！                        ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    if check_disk_mounted "$disk"; then
        echo -e "${RED}错误: 硬盘已挂载，请先卸载所有分区${NC}"
        pause
        return
    fi

    echo -e "即将破坏性修复: ${RED}/dev/$disk${NC}"
    echo ""
    read -p "请输入 'YES I UNDERSTAND' 确认操作: " confirm_text

    if [[ "$confirm_text" != "YES I UNDERSTAND" ]]; then
        echo -e "${YELLOW}操作已取消${NC}"
        pause
        return
    fi

    log "开始破坏性修复: /dev/$disk"

    echo ""
    echo -e "${CYAN}[1/2] 开始破坏性读写测试...${NC}"
    echo "这将花费较长时间，请耐心等待..."
    echo ""

    local badblocks_file="$LOG_DIR/badblocks_destructive_${disk}_$(date +%Y%m%d_%H%M%S).txt"

    badblocks -wsv -b 4096 -p 1 "/dev/$disk" -o "$badblocks_file" 2>&1 | tee -a "$LOG_FILE"

    echo ""
    echo -e "${CYAN}[2/2] 检查修复结果...${NC}"

    if [[ -s "$badblocks_file" ]]; then
        local count=$(wc -l < "$badblocks_file")
        echo -e "${YELLOW}仍有 $count 个无法修复的坏块${NC}"
        echo "坏块列表: $badblocks_file"
    else
        echo -e "${GREEN}所有坏块已修复或重映射！${NC}"
    fi

    echo ""
    smartctl -A "/dev/$disk" | grep -E "Reallocated|Current_Pending|Offline_Uncorrectable"

    log "破坏性修复完成: /dev/$disk"
    pause
}

full_rebuild() {
    local disk="$1"
    print_header
    echo -e "${RED}🔄 完整重建 /dev/$disk${NC}"
    print_separator

    echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                    ⚠️  最高级别警告 ⚠️                        ║${NC}"
    echo -e "${RED}║                                                              ║${NC}"
    echo -e "${RED}║  此操作将:                                                   ║${NC}"
    echo -e "${RED}║    1. 完全清除硬盘所有数据                                   ║${NC}"
    echo -e "${RED}║    2. 破坏性扫描修复全部坏道                                 ║${NC}"
    echo -e "${RED}║    3. 重新创建分区表                                         ║${NC}"
    echo -e "${RED}║    4. 格式化为 ext4 文件系统                                 ║${NC}"
    echo -e "${RED}║                                                              ║${NC}"
    echo -e "${RED}║  此操作绝对不可逆！                                          ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    if check_disk_mounted "$disk"; then
        echo -e "${RED}错误: 硬盘已挂载，请先卸载${NC}"
        pause
        return
    fi

    local disk_size=$(lsblk -d -n -o SIZE "/dev/$disk")
    local disk_model=$(smartctl -i "/dev/$disk" 2>/dev/null | grep "Device Model" | cut -d: -f2 | xargs 2>/dev/null)

    echo -e "目标硬盘: ${RED}/dev/$disk${NC}"
    echo -e "型号: ${CYAN}${disk_model:-未知}${NC}"
    echo -e "容量: ${CYAN}$disk_size${NC}"
    echo ""

    read -p "请输入硬盘设备名确认 (例如 sdb): " confirm_disk

    if [[ "$confirm_disk" != "$disk" ]]; then
        echo -e "${YELLOW}输入不匹配，操作已取消${NC}"
        pause
        return
    fi

    read -p "请输入 'DESTROY ALL DATA' 最终确认: " final_confirm

    if [[ "$final_confirm" != "DESTROY ALL DATA" ]]; then
        echo -e "${YELLOW}操作已取消${NC}"
        pause
        return
    fi

    log "开始完整重建: /dev/$disk"

    echo ""
    echo -e "${CYAN}[1/5] 破坏性扫描修复...${NC}"
    local badblocks_file="$LOG_DIR/badblocks_rebuild_${disk}_$(date +%Y%m%d_%H%M%S).txt"
    badblocks -wsv -b 4096 "/dev/$disk" -o "$badblocks_file" 2>&1 | tee -a "$LOG_FILE"

    echo ""
    echo -e "${CYAN}[2/5] 清除分区表...${NC}"
    wipefs -a "/dev/$disk" >> "$LOG_FILE" 2>&1
    dd if=/dev/zero of="/dev/$disk" bs=1M count=100 status=none 2>> "$LOG_FILE"

    echo ""
    echo -e "${CYAN}[3/5] 创建 GPT 分区表...${NC}"
    parted -s "/dev/$disk" mklabel gpt >> "$LOG_FILE" 2>&1
    parted -s "/dev/$disk" mkpart primary ext4 0% 100% >> "$LOG_FILE" 2>&1

    sleep 2

    echo ""
    echo -e "${CYAN}[4/5] 格式化分区...${NC}"
    if [[ -s "$badblocks_file" ]]; then
        echo "使用坏块列表格式化..."
        mkfs.ext4 -l "$badblocks_file" -L "Repaired_${disk}" "/dev/${disk}1" 2>&1 | tee -a "$LOG_FILE"
    else
        mkfs.ext4 -L "Repaired_${disk}" "/dev/${disk}1" 2>&1 | tee -a "$LOG_FILE"
    fi

    echo ""
    echo -e "${CYAN}[5/5] 验证结果...${NC}"
    echo ""
    echo "分区信息:"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL "/dev/$disk"

    echo ""
    echo "SMART 状态:"
    smartctl -A "/dev/$disk" | grep -E "Reallocated|Current_Pending|Offline_Uncorrectable"

    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}✅ 完整重建完成！${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"

    if [[ -s "$badblocks_file" ]]; then
        local count=$(wc -l < "$badblocks_file")
        echo -e "${YELLOW}注意: 仍有 $count 个无法修复的坏块已被标记排除${NC}"
    fi

    echo ""
    echo "挂载命令:"
    echo -e "${CYAN}  mkdir -p /mnt/repaired_${disk}${NC}"
    echo -e "${CYAN}  mount /dev/${disk}1 /mnt/repaired_${disk}${NC}"

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

    echo "正在扫描问题硬盘..."
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
            echo -e "  发现问题硬盘: ${RED}/dev/$disk${NC} - 待处理坏道: $pending"
        fi
    done

    echo ""

    if [[ ${#problem_disks[@]} -eq 0 ]]; then
        echo -e "${GREEN}✅ 未发现需要修复的硬盘${NC}"
        pause
        return
    fi

    echo -e "${YELLOW}发现 ${#problem_disks[@]} 个问题硬盘${NC}"
    echo ""
    echo "修复选项:"
    echo "  1) 快速修复 - 只修复已知坏扇区（推荐）"
    echo "  2) 标准修复 - 扫描并修复（较安全）"
    echo "  3) 强力修复 - 破坏性修复（数据丢失！）"
    echo "  0) 取消"
    echo ""

    read -p "请选择修复方式 [0-3]: " repair_mode

    case $repair_mode in
        1)
            for disk in "${problem_disks[@]}"; do
                if ! check_disk_mounted "$disk"; then
                    echo ""
                    echo -e "${CYAN}修复 /dev/$disk ...${NC}"
                    quick_fix_known_sectors "$disk"
                fi
            done
            ;;
        2)
            for disk in "${problem_disks[@]}"; do
                if ! check_disk_mounted "$disk"; then
                    echo ""
                    standard_repair "$disk"
                fi
            done
            ;;
        3)
            echo -e "${RED}此操作将清除所有问题硬盘的数据！${NC}"
            if confirm "确认对所有问题硬盘执行强力修复?"; then
                for disk in "${problem_disks[@]}"; do
                    if ! check_disk_mounted "$disk"; then
                        destructive_repair "$disk"
                    fi
                done
            fi
            ;;
        0)
            return
            ;;
    esac
}

#===============================================================================
# 功能5: 查看日志
#===============================================================================

view_logs() {
    print_header
    echo -e "${GREEN}📋 修复日志${NC}"
    print_separator

    if [[ ! -d "$LOG_DIR" ]]; then
        echo "暂无日志文件"
        pause
        return
    fi

    local -a logs
    local i=1
    
    echo "日志文件列表:"
    echo ""
    
    while IFS= read -r -d '' log_file; do
        logs+=("$log_file")
        local size=$(du -h "$log_file" 2>/dev/null | cut -f1)
        local date=$(stat -c %y "$log_file" 2>/dev/null | cut -d. -f1)
        echo "  $i) $(basename "$log_file") - $size - $date"
        ((i++))
    done < <(find "$LOG_DIR" -type f \( -name "*.txt" -o -name "*.log" \) -print0 2>/dev/null | sort -z)

    if [[ ${#logs[@]} -eq 0 ]]; then
        echo "暂无日志文件"
        pause
        return
    fi

    echo "  0) 返回"
    echo ""

    read -p "选择查看的日志 [0-$((i-1))]: " choice

    [[ "$choice" == "0" ]] && return

    if [[ "$choice" -ge 1 && "$choice" -lt "$i" ]] 2>/dev/null; then
        less "${logs[$((choice-1))]}"
    fi
}

#===============================================================================
# 功能6: 帮助信息
#===============================================================================

show_help() {
    print_header
    echo -e "${GREEN}❓ 帮助信息${NC}"
    print_separator

    echo "
【关于硬盘坏道】

  坏道是硬盘存储介质上无法正常读写的区域。
  坏道分为逻辑坏道（可修复）和物理坏道（不可修复，只能屏蔽）。

【SMART 关键指标解释】

  Reallocated_Sector_Ct   - 已重映射扇区数，硬盘已自动处理
  Current_Pending_Sector  - 等待重映射的扇区，需要关注！
  Offline_Uncorrectable   - 无法修复的扇区，严重问题！

【修复方式说明】

  快速检测：SMART 短测试，快速发现问题
  完整检测：SMART 长测试，全面检查硬盘
  扫描坏块：只读扫描，不破坏数据
  快速修复：对已知坏扇区写零，触发硬盘重映射
  标准修复：扫描+修复，尽量保留数据
  强力修复：破坏性读写测试，清除所有数据
  完整重建：修复+分区+格式化，完全重置硬盘

【建议】

  • Current_Pending_Sector > 0   ：尽快修复
  • Current_Pending_Sector > 100 ：建议更换硬盘
  • 修复后问题反复出现：硬盘正在恶化，必须更换

【日志位置】

  $LOG_DIR/
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
