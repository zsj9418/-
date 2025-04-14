#!/bin/bash

# 定义依赖项
REQUIRED_TOOLS=("hdparm" "dd" "iostat")

# 检查并安装缺失的依赖
missing_tools=()
for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v $tool &> /dev/null; then
        missing_tools+=($tool)
    fi
done

if [ ${#missing_tools[@]} -gt 0 ]; then
    echo "检测到缺失的依赖: ${missing_tools[*]}"
    if [ -f "/etc/os-release" ]; then
        . /etc/os-release
        case "$ID" in
            ubuntu|debian)
                sudo apt update && sudo apt install -y "${missing_tools[@]}"
                ;;
            centos|rhel|fedora)
                sudo yum install -y "${missing_tools[@]}"
                ;;
            arch)
                sudo pacman -Sy --noconfirm "${missing_tools[@]}"
                ;;
            *)
                echo "不支持的 Linux 发行版，请手动安装: ${missing_tools[*]}"
                exit 1
                ;;
        esac
    else
        echo "无法检测系统类型，请手动安装: ${missing_tools[*]}"
        exit 1
    fi
fi

# 获取所有磁盘设备，并确保正确排除光驱 (sr0)
DISKS=($(lsblk -d -o NAME | awk 'NR>1' | grep -v '^sr'))

if [ ${#DISKS[@]} -eq 0 ]; then
    echo "未发现任何磁盘设备！"
    exit 1
fi

# 显示磁盘设备选项
echo "检测到以下磁盘设备："
for i in "${!DISKS[@]}"; do
    echo "$((i+1)). ${DISKS[i]}"
done
echo "$(( ${#DISKS[@]} +1 )). **测试所有磁盘**"
echo "$(( ${#DISKS[@]} +2 )). **退出**"

# 用户选择磁盘
read -p "请选择要测试的磁盘编号（输入数字）： " choice

if [[ "$choice" -eq "$(( ${#DISKS[@]} +2 ))" ]]; then
    echo "已退出程序。"
    exit 0
elif [[ "$choice" -eq "$(( ${#DISKS[@]} +1 ))" ]]; then
    SELECTED_DISKS=("${DISKS[@]}")
else
    choice_index=$((choice-1))
    if [[ "$choice_index" -ge 0 && "$choice_index" -lt "${#DISKS[@]}" ]]; then
        SELECTED_DISKS=("${DISKS[choice_index]}")
    else
        echo "输入错误，请重新运行脚本并选择正确的选项！"
        exit 1
    fi
fi

# 运行测试并收集数据
declare -A RESULTS

for DISK in "${SELECTED_DISKS[@]}"; do
    DEVICE="/dev/$DISK"
    echo "正在测试 $DEVICE 的性能..."
    echo "-----------------------------------"

    # hdparm 测试读取速度
    HDPARM_RESULT=$(sudo hdparm -tT $DEVICE 2>/dev/null | grep -E "Timing buffered|Timing cached")
    CACHED_READ=$(echo "$HDPARM_RESULT" | grep "Timing cached" | awk '{print $5}')
    BUFFERED_READ=$(echo "$HDPARM_RESULT" | grep "Timing buffered" | awk '{print $5}')
    
    # dd 测试写入速度
    TEST_FILE="/tmp/testfile_$DISK"
    DD_RESULT=$(dd if=/dev/zero of=$TEST_FILE bs=1G count=1 oflag=direct 2>&1 | grep -o "[0-9\.]\+ MB/s")
    
    # iostat 监测磁盘IO
    IOSTAT_RESULT=$(iostat -d -x $DEVICE 1 3 | tail -n 3 | head -n 1)
    IOSTAT_RMB=$(echo "$IOSTAT_RESULT" | awk '{print $6}')
    IOSTAT_WMB=$(echo "$IOSTAT_RESULT" | awk '{print $7}')
    
    # 清理临时文件
    sync && rm -f $TEST_FILE

    # 结果存储
    RESULTS[$DISK]="
    **$DISK 设备:**
    读取速度: 缓存读取速度高达 ${CACHED_READ:-"未知"} MB/sec，缓冲磁盘读取速度为 ${BUFFERED_READ:-"未知"} MB/sec，表现良好。
    写入速度: ${DD_RESULT:-"未知"} MB/s，可能影响写入性能。
    I/O 性能: 读取性能 ${IOSTAT_RMB:-"未检测"} MB/s，写入性能 ${IOSTAT_WMB:-"未检测"} MB/s。
    "
done

# 显示结果摘要
echo -e "\n📊 **测试结果汇总**"
for DISK in "${SELECTED_DISKS[@]}"; do
    echo -e "${RESULTS[$DISK]}"
done
echo -e "✅ **所有选定磁盘性能测试完成！**"
