#!/bin/bash

set -e

# 检查是否为root或有sudo权限
if ! sudo -v &>/dev/null; then
    echo "本脚本需要root权限或sudo权限，请以root或有sudo权限的用户运行！"
    exit 1
fi

# 定义依赖项及其对应包名
declare -A TOOL_TO_PKG
TOOL_TO_PKG=(
    [hdparm]="hdparm"
    [dd]="coreutils"
    [iostat]="sysstat"
    [lsblk]="util-linux"
    [awk]="gawk"
    [grep]="grep"
    [head]="coreutils"
    [tail]="coreutils"
    [df]="coreutils"
    [mktemp]="coreutils"
)

REQUIRED_TOOLS=("hdparm" "dd" "iostat" "lsblk" "awk" "grep" "head" "tail" "df" "mktemp")
missing_tools=()
missing_pkgs=()

for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v $tool &> /dev/null; then
        missing_tools+=($tool)
        pkg=${TOOL_TO_PKG[$tool]}
        # 避免重复包名
        if [[ ! " ${missing_pkgs[@]} " =~ " $pkg " ]]; then
            missing_pkgs+=($pkg)
        fi
    fi
done

if [ ${#missing_tools[@]} -gt 0 ]; then
    echo "检测到缺失的依赖: ${missing_tools[*]}"
    if [ -f "/etc/os-release" ]; then
        . /etc/os-release
        case "$ID" in
            ubuntu|debian)
                sudo apt update
                sudo apt install -y "${missing_pkgs[@]}" || { echo "依赖安装失败！"; exit 1; }
                ;;
            centos|rhel|fedora)
                sudo yum install -y "${missing_pkgs[@]}" || { echo "依赖安装失败！"; exit 1; }
                ;;
            arch)
                sudo pacman -Sy --noconfirm "${missing_pkgs[@]}" || { echo "依赖安装失败！"; exit 1; }
                ;;
            *)
                echo "不支持的 Linux 发行版，请手动安装: ${missing_pkgs[*]}"
                exit 1
                ;;
        esac
    else
        echo "无法检测系统类型，请手动安装: ${missing_pkgs[*]}"
        exit 1
    fi
fi

# 更健壮的磁盘检测（仅type为disk，排除loop、rom等）
DISKS=($(lsblk -d -n -o NAME,TYPE | awk '$2=="disk"{print $1}'))

if [ ${#DISKS[@]} -eq 0 ]; then
    echo "未发现任何磁盘设备！"
    exit 1
fi

echo "检测到以下磁盘设备："
for i in "${!DISKS[@]}"; do
    echo "$((i+1)). ${DISKS[i]}"
done
echo "$(( ${#DISKS[@]} +1 )). **测试所有磁盘**"
echo "$(( ${#DISKS[@]} +2 )). **退出**"

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

declare -A RESULTS

for DISK in "${SELECTED_DISKS[@]}"; do
    DEVICE="/dev/$DISK"
    echo "正在测试 $DEVICE 的性能..."
    echo "-----------------------------------"

    # hdparm 测试读取速度
    HDPARM_RESULT=$(sudo hdparm -tT $DEVICE 2>/dev/null || true)
    CACHED_READ=$(echo "$HDPARM_RESULT" | grep "Timing cached" | awk '{print $5}')
    BUFFERED_READ=$(echo "$HDPARM_RESULT" | grep "Timing buffered" | awk '{print $5}')

    # 检查磁盘挂载点
    MOUNTPOINT=$(lsblk -n -o MOUNTPOINT $DEVICE | grep -v '^$' | head -n1)
    DD_RESULT=""
    TEST_FILE=""
    if [ -z "$MOUNTPOINT" ]; then
        # 没有挂载点，写入到 /tmp 并警告
        echo "警告：$DEVICE 未挂载，将在 /tmp 目录下进行写入测试，结果仅供参考。"
        TEST_FILE=$(mktemp /tmp/testfile_${DISK}_XXXX)
        # 检查 /tmp 空间
        AVAIL=$(df --output=avail -k /tmp | tail -1)
        if [ "$AVAIL" -lt $((1024*1024)) ]; then
            echo "警告：/tmp 空间不足，跳过写入测试。"
            DD_RESULT="空间不足"
        fi
    else
        # 检查空间
        AVAIL=$(df --output=avail -k "$MOUNTPOINT" | tail -1)
        if [ "$AVAIL" -lt $((1024*1024)) ]; then
            echo "磁盘空间不足，跳过写入测试。"
            DD_RESULT="空间不足"
        else
            TEST_FILE=$(mktemp "$MOUNTPOINT/testfile_${DISK}_XXXX")
        fi
    fi

    # dd 测试写入速度
    if [ -z "$DD_RESULT" ] && [ -n "$TEST_FILE" ]; then
        echo "正在进行写入测试（1GB），请稍候..."
        DD_RESULT=$( (dd if=/dev/zero of=$TEST_FILE bs=1M count=1024 oflag=direct status=progress 2>&1) | grep -o "[0-9\.]\+ MB/s" | tail -1 )
        sync && rm -f $TEST_FILE
    fi

    # iostat 监测磁盘IO
    IOSTAT_RESULT=$(iostat -d -x $DEVICE 1 3 | awk 'NR>3{print $0}' | tail -n 1)
    # 兼容不同iostat版本
    IOSTAT_RMB=$(echo "$IOSTAT_RESULT" | awk '{print $(NF-1)}')
    IOSTAT_WMB=$(echo "$IOSTAT_RESULT" | awk '{print $NF}')

    RESULTS[$DISK]="
    **$DISK 设备:**
    读取速度: 缓存读取速度高达 ${CACHED_READ:-"未知"} MB/sec，缓冲磁盘读取速度为 ${BUFFERED_READ:-"未知"} MB/sec。
    写入速度: ${DD_RESULT:-"未知"} MB/s。
    I/O 性能: 读取性能 ${IOSTAT_RMB:-"未检测"} MB/s，写入性能 ${IOSTAT_WMB:-"未检测"} MB/s。
    "
done

echo -e "\n📊 **测试结果汇总**"
for DISK in "${SELECTED_DISKS[@]}"; do
    echo -e "${RESULTS[$DISK]}"
done
echo -e "✅ **所有选定磁盘性能测试完成！**"
