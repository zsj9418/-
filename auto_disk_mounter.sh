#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

LOG_FILE="/var/log/auto_disk_mounter.log"
LOG_MAX_SIZE=$((1024 * 1024)) # 1MB

log() {
    local message="$1"
    echo "$(date +'%Y-%m-%d %H:%M:%S') - $message" >> "$LOG_FILE"
    
    if [ $(stat -c%s "$LOG_FILE") -ge $LOG_MAX_SIZE ]; then
        > "$LOG_FILE"
    fi
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}错误：此脚本需要root权限！${NC}"
        log "错误：此脚本需要root权限！"
        exit 1
    fi
}

install_dependencies() {
    local needed=("udev" "systemd" "util-linux")
    local missing=()
    
    for pkg in "${needed[@]}"; do
        if ! command -v "$pkg" >/dev/null 2>&1; then
            missing+=("$pkg")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${YELLOW}缺少必要依赖: ${missing[*]}${NC}"
        log "缺少必要依赖: ${missing[*]}"
        read -rp "是否尝试安装？(y/n): " choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            if command -v apt-get >/dev/null 2>&1; then
                apt-get update && apt-get install -y "${missing[@]}"
            elif command -v yum >/dev/null 2>&1; then
                yum install -y "${missing[@]}"
            elif command -v dnf >/dev/null 2>&1; then
                dnf install -y "${missing[@]}"
            elif command -v pacman >/dev/null 2>&1; then
                pacman -Syu --noconfirm "${missing[@]}"
            else
                echo -e "${RED}无法自动安装依赖，请手动安装后重试。${NC}"
                log "无法自动安装依赖，请手动安装后重试。"
                exit 1
            fi
        else
            echo -e "${RED}依赖不满足，脚本退出。${NC}"
            log "依赖不满足，脚本退出。"
            exit 1
        fi
    fi
}

create_auto_block() {
    cat > /bin/auto_block << 'EOF'
#!/bin/bash
[ "$DEVTYPE" = "partition" ] || exit 0
suuid=(${ID_FS_UUID//-/ })
gzpath="/mnt/${suuid:0:8}"
devpaths=${DEVPATH%\/*}
get_sys_fs="$(df 2>/dev/null | awk '$1~/'${devpaths##*\/}'/{print $6}')"
[ "$get_sys_fs" = '/' ] && exit 0

case "$ACTION" in
    add)
        [ -d "$gzpath" ] || mkdir -p "$gzpath"
        if ! mountpoint -q "$gzpath"; then
            if systemd-mount --no-block --collect "$devnode" "$gzpath"; then
                echo "成功挂载到 $gzpath"
            else
                echo "挂载失败，尝试使用fallback方法..."
                mount "$devnode" "$gzpath" || exit 1
            fi
        fi
        ;;
    remove)
        if mountpoint -q "$gzpath"; then
            if ! umount "$gzpath"; then
                echo "卸载失败，尝试强制卸载..."
                umount -l "$gzpath"
            fi
        fi
        sync
        rmdir "$gzpath" 2>/dev/null
        ;;
esac
EOF

    chmod +x /bin/auto_block
    echo -e "${GREEN}已创建 /bin/auto_block 脚本${NC}"
    log "已创建 /bin/auto_block 脚本"
}

create_udev_rule() {
    cat > /etc/udev/rules.d/10-auto_block.rules << 'EOF'
KERNEL!="sd[a-z][0-9]|hd[a-z][0-9]|mmcblk[0-9]p[0-9]", GOTO="uuid_auto_mount_end"
SUBSYSTEM!="block",GOTO="uuid_auto_mount_end"
IMPORT{program}="/sbin/blkid -o udev -p %N"
ENV{ID_FS_TYPE}=="", GOTO="uuid_auto_mount_end"
ENV{ID_FS_UUID}=="", GOTO="uuid_auto_mount_end"
ACTION=="add|remove", RUN+="/bin/auto_block"
LABEL="uuid_auto_mount_end"
EOF

    echo -e "${GREEN}已创建 udev 规则文件${NC}"
    log "已创建 udev 规则文件"
}

test_configuration() {
    echo -e "\n${YELLOW}正在测试配置...${NC}"
    log "正在测试配置..."
    udevadm control --reload
    udevadm trigger --action=add
    
    echo -e "\n${YELLOW}当前挂载点：${NC}"
    ls -l /mnt/
    df -h | grep -i "/mnt/"
    
    echo -e "\n${GREEN}测试完成！可以尝试插拔磁盘查看自动挂载/卸载效果。${NC}"
    log "测试完成！可以尝试插拔磁盘查看自动挂载/卸载效果。"
}

main_menu() {
    clear
    echo -e "\n${GREEN}=== 自动磁盘挂载设置脚本 ===${NC}"
    echo "1. 完整安装自动挂载功能"
    echo "2. 仅创建auto_block脚本"
    echo "3. 仅创建udev规则"
    echo "4. 测试当前配置"
    echo "5. 卸载自动挂载功能"
    echo "0. 退出"
    
    read -rp "请选择操作 [0-5]: " choice
    case "$choice" in
        1)
            check_root
            install_dependencies
            create_auto_block
            create_udev_rule
            test_configuration
            ;;
        2)
            check_root
            create_auto_block
            ;;
        3)
            check_root
            create_udev_rule
            ;;
        4)
            check_root
            test_configuration
            ;;
        5)
            check_root
            uninstall
            ;;
        0)
            echo "退出脚本。"
            log "退出脚本。"
            exit 0
            ;;
        *)
            echo -e "${RED}无效选择！${NC}"
            log "无效选择！"
            sleep 1
            main_menu
            ;;
    esac
}

uninstall() {
    echo -e "\n${YELLOW}正在卸载自动挂载功能...${NC}"
    log "正在卸载自动挂载功能..."
    
    [ -f /bin/auto_block ] && rm -f /bin/auto_block
    [ -f /etc/udev/rules.d/10-auto_block.rules ] && rm -f /etc/udev/rules.d/10-auto_block.rules
    
    udevadm control --reload
    echo -e "${GREEN}已卸载自动挂载功能！${NC}"
    log "已卸载自动挂载功能！"
    
    read -rp "是否清理已创建的挂载点？(y/n): " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        for mountpoint in /mnt/*; do
            if [ -d "$mountpoint" ]; then
                umount -l "$mountpoint" 2>/dev/null
                rmdir "$mountpoint" 2>/dev/null
            fi
        done
        echo -e "${GREEN}已清理挂载点！${NC}"
        log "已清理挂载点！"
    fi
}

check_root
main_menu

read -rp "按Enter键返回主菜单..." -n 1
main_menu
