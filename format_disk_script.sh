#!/bin/bash

# 定义彩色输出
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
NC="\033[0m" # 无色

# 日志文件路径
LOG_FILE="/var/log/format_script.log"
# 状态文件路径
STATUS_FILE="/var/lib/format_script_status.txt"

# 限制日志文件大小为 1M
manage_log() {
    if [ -f "$LOG_FILE" ]; then
        local size=$(stat -c%s "$LOG_FILE")
        if [ "$size" -ge 1048576 ]; then
            mv "$LOG_FILE" "$LOG_FILE.old"
            echo "日志文件已备份: $LOG_FILE.old" >> "$LOG_FILE"
        fi
    fi
}

# 检查并安装缺失的依赖
check_dependencies() {
    local dependencies=("dosfstools" "e2fsprogs" "ntfs-3g")
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
        # 更新状态文件，记录已安装的依赖
        echo "${missing[@]}" >> "$STATUS_FILE"
    else
        echo -e "${GREEN}所有依赖已安装，无需更新。${NC}"
    fi
}

# 列出所有硬盘
list_disks() {
    echo -e "${GREEN}可用硬盘列表:${NC}"
    lsblk -d -n -o NAME,SIZE | grep -E '^sd|^nvme' | nl
}

# 检查分区是否挂载
is_mounted() {
    mount | grep "/dev/$1" &> /dev/null
}

# 卸载分区
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

# 删除分区
delete_partition() {
    local disk=$1
    if is_mounted "${disk}1"; then
        echo -e "${RED}分区 ${disk}1 当前已挂载。${NC}"
        read -p "您是否希望卸载该分区并继续操作？ (y/n): " confirm
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            unmount_partition "${disk}1"
        else
            echo -e "${RED}操作已取消。${NC}"
            exit 1
        fi
    fi

    echo -e "${YELLOW}正在删除 $disk 的所有分区...${NC}"
    (echo -e "d\n\n" | sudo fdisk /dev/$disk) >> "$LOG_FILE" 2>&1
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}分区删除成功！${NC}"
    else
        echo -e "${RED}分区删除失败！请查看日志文件。${NC}"
    fi
}

# 创建分区
create_partition() {
    local disk=$1
    echo -e "${YELLOW}请选择分区表类型:${NC}"
    echo "1. MBR (传统分区表)"
    echo "2. GPT (GUID 分区表)"
    
    read -p "输入选项 (1-2): " table_choice
    local table_type

    case "$table_choice" in
        1) 
            table_type="mbr"
            (echo -e "o\nn\np\n1\n\n\nw" | sudo fdisk /dev/$disk) >> "$LOG_FILE" 2>&1
            ;;
        2) 
            table_type="gpt"
            (echo -e "g\nn\n\n\n\nw" | sudo fdisk /dev/$disk) >> "$LOG_FILE" 2>&1
            ;;
        *) 
            echo -e "${RED}无效的选择，请重试。${NC}" && return 
            ;;
    esac

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}分区表类型为 $table_type，分区创建成功！${NC}"
    else
        echo -e "${RED}分区创建失败！请查看日志文件。${NC}"
    fi
}

# 格式化指定硬盘
format_disk() {
    local disk=$1
    if is_mounted "${disk}1"; then
        echo -e "${RED}分区 ${disk}1 当前已挂载。${NC}"
        read -p "您是否希望卸载该分区并继续操作？ (y/n): " confirm
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            unmount_partition "${disk}1"
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

    echo -e "${YELLOW}正在格式化 $disk 为 $format_type...${NC}"
    sudo mkfs.$format_type /dev/${disk}1 >> "$LOG_FILE" 2>&1
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}$disk 格式化为 $format_type 成功！${NC}"
    else
        echo -e "${RED}$disk 格式化失败！请查看日志文件。${NC}"
    fi
}

# 主菜单
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
        1) delete_partition "$disk" ;;
        2) create_partition "$disk" ;;
        *) echo -e "${RED}无效的选择，请重试。${NC}" && exit 1 ;;
    esac

    format_disk "$disk"
}

# 运行主菜单
main_menu
