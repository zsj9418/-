#!/bin/bash

# 定义彩色输出
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
NC="\033[0m" # 无色

LOG_FILE="/var/log/format_script.log"
STATUS_FILE="/var/lib/format_script_status.txt"

manage_log() {
    if [ -f "$LOG_FILE" ]; then
        local size=$(stat -c%s "$LOG_FILE")
        if [ "$size" -ge 1048576 ]; then
            mv "$LOG_FILE" "$LOG_FILE.old"
            echo "日志文件已备份: $LOG_FILE.old" >> "$LOG_FILE"
        fi
    fi
}

check_dependencies() {
    local dependencies=("dosfstools" "e2fsprogs" "ntfs-3g" "parted" "util-linux")
    local missing=()
    local installed=1

    for pkg in "${dependencies[@]}"; do
        if ! dpkg -l | grep -q "^ii  $pkg"; then
            missing+=($pkg)
            installed=0
        fi
    done

    if [ $installed -eq 0 ]; then
        echo -e "${YELLOW}正在安装缺失的依赖: ${missing[@]}...${NC}"
        if command -v apt-get &> /dev/null; then
            sudo apt-get update
            sudo apt-get install -y "${missing[@]}" >> "$LOG_FILE" 2>&1
        elif command -v yum &> /dev/null; then
            sudo yum install -y "${missing[@]}" >> "$LOG_FILE" 2>&1
        elif command -v brew &> /dev/null; then
            brew install "${missing[@]}" >> "$LOG_FILE" 2>&1
        else
            echo -e "${RED}不支持的操作系统，请手动安装依赖。${NC}" >> "$LOG_FILE"
            exit 1
        fi
        echo "${missing[@]}" >> "$STATUS_FILE"
    else
        echo -e "${GREEN}所有依赖已安装，无需更新。${NC}"
    fi
}

list_disks() {
    echo -e "${GREEN}可用硬盘列表:${NC}"
    lsblk -d -n -o NAME,SIZE | grep -E '^sd|^nvme' | nl
}

is_mounted() {
    mount | grep "/dev/$1" &> /dev/null
}

refresh_partition_table() {
    local disk=$1
    sudo partprobe "/dev/$disk"
    sudo udevadm settle || true
}

wait_for_partition() {
    local partition=$1
    local timeout=10
    local elapsed=0
    while [ ! -b "/dev/$partition" ]; do
        sleep 1
        elapsed=$((elapsed+1))
        if [ $elapsed -ge $timeout ]; then
            echo -e "${RED}等待 /dev/$partition 超时，请检测硬件或手动刷新分区表。${NC}"
            exit 1
        fi
    done
}

unmount_partition() {
    local partition=$1
    echo -e "${YELLOW}正在卸载 $partition...${NC}"
    sudo umount /dev/$partition >> "$LOG_FILE" 2>&1
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}分区 $partition 卸载成功！${NC}"
    else
        echo -e "${RED}分区 $partition 卸载失败！请检查日志文件。${NC}"
        exit 1
    fi
}

release_all_partition_locks() {
    local disk=$1
    # 卸载所有挂载的分区
    for part in $(lsblk -ln -o NAME "/dev/$disk" | sed 1d); do
        if is_mounted "$part"; then
            echo -e "${YELLOW}正在卸载挂载点 $(findmnt -n -o TARGET "/dev/$part")...${NC}"
            sudo umount "/dev/$part" >> "$LOG_FILE" 2>&1
        fi
        # swap
        if swapon --show=NAME | grep -qw "/dev/$part"; then
            echo -e "${YELLOW}正在关闭swap分区 /dev/$part ...${NC}"
            sudo swapoff "/dev/$part"
        fi
    done
    # LVM解锁
    if command -v pvs &>/dev/null; then
        for pv in $(pvs --noheadings -o pv_name | xargs -n1); do
            if [[ "$pv" =~ ^/dev/$disk ]]; then
                echo -e "${YELLOW}正在释放LVM卷 $pv ...${NC}"
                for vg in $(pvs --noheadings -o vg_name "$pv" | grep -v "^ *$"); do
                    sudo vgchange -an "$vg"
                done
            fi
        done
    fi
    # mdadm解锁
    if command -v mdadm &>/dev/null; then
        for mddev in $(cat /proc/mdstat | grep ^md | awk '{print $1}'); do
            devices=$(mdadm --detail "/dev/$mddev" | grep "/dev/$disk" || true)
            if [ -n "$devices" ]; then
                echo -e "${YELLOW}正在停止RAID阵列 $mddev ...${NC}"
                sudo mdadm --stop "/dev/$mddev"
            fi
        done
    fi
}

delete_all_partitions() {
    local disk=$1
    release_all_partition_locks "$disk"
    echo -e "${YELLOW}正在删除 $disk 的所有分区...${NC}"
    echo -e "o\nw" | sudo fdisk /dev/$disk >> "$LOG_FILE" 2>&1
    refresh_partition_table "$disk"
    sleep 2
    if ! lsblk "/dev/$disk" | grep -q part; then
        echo -e "${GREEN}分区删除成功！${NC}"
    else
        echo -e "${RED}警告: 分区似乎没有被正确清理。如果系统仍然报告‘unable to inform the kernel’，你需要重启后重试。${NC}"
        read -p "是否重启？[y/n] " ans
        if [[ "$ans" =~ ^([yY])$ ]]; then
            sudo reboot
        else
            exit 1
        fi
    fi
}

create_single_partition() {
    local disk=$1
    local table_choice
    echo -e "${YELLOW}请选择分区表类型:${NC}"
    echo "1. MBR (传统分区表)"
    echo "2. GPT (GUID 分区表)"
    read -p "输入选项 (1-2): " table_choice
    case "$table_choice" in
        1)
            (echo -e "o\nn\np\n1\n\n\nw" | sudo fdisk /dev/$disk) >> "$LOG_FILE" 2>&1
            ;;
        2)
            (echo -e "g\nn\n\n\n\n\nw" | sudo fdisk /dev/$disk) >> "$LOG_FILE" 2>&1
            ;;
        *)
            echo -e "${RED}无效的选择，请重试。${NC}" && exit 1 ;;
    esac
    refresh_partition_table "$disk"
}

delete_and_create_partition() {
    local disk=$1
    delete_all_partitions "$disk"
    create_single_partition "$disk"
    wait_for_partition "${disk}1"
}

format_ntfs_partition() {
    local partition=$1
    if command -v mkfs.ntfs &>/dev/null; then
        sudo mkfs.ntfs -F "/dev/$partition" >> "$LOG_FILE" 2>&1
    elif command -v mkntfs &>/dev/null; then
        sudo mkntfs -F "/dev/$partition" >> "$LOG_FILE" 2>&1
    else
        echo -e "${RED}NTFS格式化工具未安装。${NC}"
        exit 1
    fi

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}/dev/$partition 格式化为 NTFS 成功！${NC}"
    else
        echo -e "${RED}/dev/$partition NTFS格式化失败，请检查日志。${NC}"
        exit 1
    fi
}

format_disk() {
    local disk=$1
    local partition=$(lsblk /dev/$disk -ln -o NAME,TYPE | awk '$2=="part"{print $1; exit}')
    if [ -z "$partition" ]; then
        partition="${disk}1"
    fi
    if is_mounted "$partition"; then
        echo -e "${RED}分区 $partition 当前已挂载。${NC}"
        read -p "您是否希望卸载该分区并继续操作？ (y/n): " confirm
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            unmount_partition "$partition"
        else
            echo -e "${RED}操作已取消。${NC}"
            exit 1
        fi
    fi

    echo -e "${YELLOW}请选择要使用的文件系统格式:${NC}"
    echo "1. ext4"
    echo "2. ext3"
    echo "3. ext2"
    echo "4. ntfs"
    echo "5. vfat"
    read -p "输入选项 (1-5): " format_choice
    local format_type

    case "$format_choice" in
        1) format_type="ext4" ;;
        2) format_type="ext3" ;;
        3) format_type="ext2" ;;
        4) format_type="ntfs" ;;
        5) format_type="vfat" ;;
        *) echo -e "${RED}无效的选择，请重试。${NC}" && return ;;
    esac

    if [ "$format_type" == "ntfs" ]; then
        delete_and_create_partition "$disk"
        format_ntfs_partition "${disk}1"
        return
    fi

    wait_for_partition "$partition"
    sudo mkfs.$format_type "/dev/$partition" >> "$LOG_FILE" 2>&1
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}/dev/$partition 格式化为 $format_type 成功！${NC}"
    else
        echo -e "${RED}/dev/$partition 格式化失败！${NC}"
        exit 1
    fi
}

main_menu() {
    manage_log
    check_dependencies
    list_disks
    read -p "请选择要操作的硬盘（输入编号）： " disk_number
    local disk=$(lsblk -d -n -o NAME | grep -E '^sd|^nvme' | sed -n "${disk_number}p")
    if [ -z "$disk" ]; then
        echo -e "${RED}无效的选择，请重试。${NC}"
        exit 1
    fi
    read -p "您想要（1）删除分区或（2）创建新分区？ (1-2): " action_choice
    case "$action_choice" in
        1)
            delete_all_partitions "$disk"
            ;;
        2)
            create_single_partition "$disk"
            ;;
        *)
            echo -e "${RED}无效的选择，请重试。${NC}" && exit 1 ;;
    esac
    format_disk "$disk"
}

main_menu
