#!/bin/bash

# 定义 auto_block 脚本和 udev 规则文件的内容
AUTO_BLOCK_CONTENT="#!/bin/bash
[ \"\$DEVTYPE\" = \"partition\" ]||exit 0
suuid=(\${ID_FS_UUID//-/ })
gzpath=\"/mnt/\${suuid:0:8}\"
devpaths=\${DEVPATH%\/*}
get_sys_fs=\"\$(df 2>/dev/null|awk '\$1~/'\${devpaths##*\/}'/{print \$6}')\"
[ \"\$get_sys_fs\" = '/' ]&&exit 0
case \"\$ACTION\" in
add)
[ -d \"\$gzpath\" ]||mkdir \$gzpath
systemd-mount --no-block --collect \$devnode \"\$DEVNAME\" \"\$gzpath\"
;;
remove)
systemd-mount -u \"\$gzpath\" 2>/dev/null
sync
rmdir \$gzpath
;;
esac"

UDEV_RULES_CONTENT="KERNEL!=\"sd[a-z][0-9]|hd[a-z][0-9]|mmcblk[0-9]p[0-9]\", GOTO=\"uuid_auto_mount_end\"
SUBSYSTEM!=\"block\", GOTO=\"uuid_auto_mount_end\"
IMPORT{program}=\"/sbin/blkid -o udev -p %N\"
ENV{ID_FS_TYPE}==\"\", GOTO=\"uuid_auto_mount_end\"
ENV{ID_FS_UUID}==\"\", GOTO=\"uuid_auto_mount_end\"
ACTION==\"add|remove\", RUN+=\"/bin/auto_block\"
LABEL=\"uuid_auto_mount_end\""

# 函数：完整安装自动挂载功能
install_full() {
    echo "安装自动挂载功能..."
    # 创建 auto_block 脚本
    echo "$AUTO_BLOCK_CONTENT" > /bin/auto_block
    chmod +x /bin/auto_block

    # 创建 udev 规则文件
    echo "$UDEV_RULES_CONTENT" > /etc/udev/rules.d/10-auto_block.rules

    # 重新加载 udev 规则
    udevadm control --reload

    echo "自动挂载功能安装完成，请重启设备以生效。"
}

# 函数：仅创建 auto_block 脚本
create_auto_block() {
    echo "创建 auto_block 脚本..."
    echo "$AUTO_BLOCK_CONTENT" > /bin/auto_block
    chmod +x /bin/auto_block
    echo "auto_block 脚本创建完成。"
}

# 函数：仅创建 udev 规则
create_udev_rules() {
    echo "创建 udev 规则..."
    echo "$UDEV_RULES_CONTENT" > /etc/udev/rules.d/10-auto_block.rules
    udevadm control --reload
    echo "udev 规则创建完成。"
}

# 函数：测试当前配置
test_current_config() {
    echo "测试当前配置..."
    if [ -x /bin/auto_block ] && [ -f /etc/udev/rules.d/10-auto_block.rules ]; then
        echo "配置正常: auto_block 脚本和 udev 规则均已存在。"
        echo "请插入设备并等待，监控 udev 事件..."
        udevadm monitor --udev --subsystem-match=block
    else
        echo "配置异常: 请检查 auto_block 脚本和 udev 规则是否存在。"
    fi
}

# 函数：卸载自动挂载功能
uninstall() {
    echo "卸载自动挂载功能..."
    rm -f /bin/auto_block
    rm -f /etc/udev/rules.d/10-auto_block.rules
    udevadm control --reload
    echo "自动挂载功能已卸载。"
}

# 新函数：检查并安装SMB开启分享（增强版，支持多个设备、多系统兼容，并添加停止分享功能）
install_smb_share() {
    echo "检查并安装SMB开启分享..."

    # 检测包管理器并安装Samba（增强通用性，支持多系统）
    if command -v apt >/dev/null; then
        PKG_MANAGER="apt"
        INSTALL_CMD="apt update && apt install -y samba"
    elif command -v dnf >/dev/null; then
        PKG_MANAGER="dnf"
        INSTALL_CMD="dnf install -y samba"
    elif command -v yum >/dev/null; then
        PKG_MANAGER="yum"
        INSTALL_CMD="yum install -y samba"
    elif command -v pacman >/dev/null; then
        PKG_MANAGER="pacman"
        INSTALL_CMD="pacman -Syu --noconfirm samba"
    else
        echo "错误: 未检测到支持的包管理器（apt, dnf, yum, pacman）。请手动安装Samba。"
        return
    fi

    # 检查Samba是否已安装
    if ! command -v smbd >/dev/null; then
        echo "Samba 未安装，正在使用 $PKG_MANAGER 安装..."
        eval "$INSTALL_CMD"
    else
        echo "Samba 已安装。"
    fi

    # 检测服务管理命令
    if command -v systemctl >/dev/null; then
        START_CMD="systemctl start smbd"
        STOP_CMD="systemctl stop smbd"
        ENABLE_CMD="systemctl enable smbd"
        RESTART_CMD="systemctl restart smbd"
    elif command -v service >/dev/null; then
        START_CMD="service smbd start"
        STOP_CMD="service smbd stop"
        ENABLE_CMD="chkconfig smbd on"
        RESTART_CMD="service smbd restart"
    else
        echo "警告: 未检测到systemd或service命令。SMB服务操作可能需要手动执行。"
        START_CMD="echo '请手动启动SMB服务'"
        STOP_CMD="echo '请手动停止SMB服务'"
        ENABLE_CMD="echo '请手动启用SMB服务'"
        RESTART_CMD="echo '请手动重启SMB服务'"
    fi

    # 启用并启动SMB服务（如果尚未启动）
    eval "$ENABLE_CMD"
    eval "$START_CMD"
    echo "SMB 服务已启用并启动。"

    # 列出所有挂载的块设备分区（使用lsblk增强通用性，保留树状符号以便查看）
    echo "检测挂载的设备分区..."
    mounted_devices=$(lsblk -f -o NAME,MOUNTPOINT | grep '/' | awk '{if ($2 != "/") print $1 " (" $2 ")"}' | grep -E 'sd[a-z][0-9]|hd[a-z][0-9]|mmcblk[0-9]p[0-9]')
    if [ -z "$mounted_devices" ]; then
        echo "警告: 未检测到任何挂载的非根分区设备。您仍可进行其他操作。"
    fi

    # 子菜单：选择操作模式
    echo "选择SMB操作模式:"
    echo "1. 共享特定设备（输入编号，多个用逗号分隔，如1,3）"
    echo "2. 共享全部设备"
    echo "3. 停止SMB分享（停止服务并可选移除共享配置）"
    echo "0. 取消"
    read -p "输入选项: " mode_choice

    case "$mode_choice" in
        1|2)
            # 显示设备列表（如果有）
            if [ -n "$mounted_devices" ]; then
                echo "可用挂载设备:"
                IFS=$'\n'
                device_list=($mounted_devices)
                for i in "${!device_list[@]}"; do
                    echo "$((i+1)). ${device_list[$i]}"
                done
            else
                echo "错误: 未检测到任何挂载设备，无法创建共享。"
                return
            fi

            if [ "$mode_choice" = "1" ]; then
                read -p "输入设备编号（多个用逗号分隔）: " selected_nums
                IFS=',' read -r -a selected_array <<< "$selected_nums"
                selected_devices=()
                for num in "${selected_array[@]}"; do
                    if (( num > 0 && num <= ${#device_list[@]} )); then
                        selected_devices+=("${device_list[$((num-1))]}")
                    else
                        echo "警告: 无效编号 $num，已忽略。"
                    fi
                done
                if [ ${#selected_devices[@]} -eq 0 ]; then
                    echo "错误: 未选择有效设备。"
                    return
                fi
            else
                selected_devices=("${device_list[@]}")
            fi

            # 对于每个选中的设备，创建SMB共享
            created_shares=()
            for device_info in "${selected_devices[@]}"; do
                # 提取devname时移除树状符号（如└─、├─）
                devname=$(echo "$device_info" | awk '{print $1}' | sed 's/[├└─]//g')
                mount_point=$(echo "$device_info" | awk '{print $2}' | tr -d '()')

                # 生成唯一的共享名（基于清理后的devname，如果重复则递增，如sda1_2）
                base_name="$devname"
                suffix=1
                share_name="$base_name"
                while grep -q "^\[$share_name\]" /etc/samba/smb.conf 2>/dev/null; do
                    share_name="${base_name}_${suffix}"
                    suffix=$((suffix + 1))
                done

                # 添加共享配置到 smb.conf
                cat << EOF >> /etc/samba/smb.conf

[$share_name]
path = $mount_point
browseable = yes
writable = yes
guest ok = yes
read only = no
EOF

                created_shares+=("$share_name (路径: $mount_point, 设备: $devname)")
            done

            # 重启SMB服务
            eval "$RESTART_CMD"

            # 显示创建的共享信息
            echo "SMB 共享已创建并开启。以下是共享详情:"
            for share in "${created_shares[@]}"; do
                echo "- $share"
            done
            echo "您可以通过网络访问这些共享（例如: \\\\your_server_ip\\share_name）。"
            echo "注意: 共享配置为公开访问（无密码），请根据需要手动调整 /etc/samba/smb.conf。"
            ;;

        3)
            # 停止SMB分享功能
            echo "停止SMB分享..."

            # 先停止服务
            eval "$STOP_CMD"
            echo "SMB 服务已停止。"

            # 检查smb.conf是否存在
            if [ ! -f /etc/samba/smb.conf ]; then
                echo "错误: /etc/samba/smb.conf 不存在。无共享可移除。"
                return
            fi

            # 列出当前所有共享（grep ^[ 找出section）
            current_shares=$(grep '^\[' /etc/samba/smb.conf | sed 's/^\[//;s/\]$//')
            if [ -z "$current_shares" ]; then
                echo "无现有共享配置。"
                return
            fi

            # 显示列表并编号
            echo "当前SMB共享:"
            IFS=$'\n'
            share_list=($current_shares)
            for i in "${!share_list[@]}"; do
                echo "$((i+1)). ${share_list[$i]}"
            done

            # 提示用户选择移除模式
            echo "选择移除模式:"
            echo "1. 移除特定共享（输入编号，多个用逗号分隔，如1,3）"
            echo "2. 移除全部共享"
            echo "0. 不移除配置，仅停止服务"
            read -p "输入选项: " remove_choice

            case "$remove_choice" in
                1)
                    read -p "输入共享编号（多个用逗号分隔）: " selected_nums
                    IFS=',' read -r -a selected_array <<< "$selected_nums"
                    selected_shares=()
                    for num in "${selected_array[@]}"; do
                        if (( num > 0 && num <= ${#share_list[@]} )); then
                            selected_shares+=("${share_list[$((num-1))]}")
                        else
                            echo "警告: 无效编号 $num，已忽略。"
                        fi
                    done
                    if [ ${#selected_shares[@]} -eq 0 ]; then
                        echo "错误: 未选择有效共享。"
                        return
                    fi
                    ;;
                2)
                    selected_shares=("${share_list[@]}")
                    ;;
                0)
                    echo "仅停止服务，未移除配置。"
                    return
                    ;;
                *)
                    echo "无效选项，未移除配置。"
                    return
                    ;;
            esac

            # 备份smb.conf
            cp /etc/samba/smb.conf /etc/samba/smb.conf.bak
            echo "已备份 /etc/samba/smb.conf 到 /etc/samba/smb.conf.bak。"

            # 移除选定的共享section（使用sed删除从[share]到下一个[或文件末尾）
            for share in "${selected_shares[@]}"; do
                sed -i "/^\[$share\]/,/^\[/{/^\[/!d}; /^\[$share\]/d" /etc/samba/smb.conf
                echo "已移除共享: $share"
            done

            # 重启服务（如果需要继续运行）
            eval "$RESTART_CMD"
            echo "SMB 配置更新完成。如果需要完全卸载Samba，请手动操作。"
            ;;

        0)
            echo "操作已取消。"
            return
            ;;
        *)
            echo "无效选项，操作已取消。"
            return
            ;;
    esac
}

# 主菜单循环
while true; do
    echo "请选择操作:"
    echo "1. 完整安装自动挂载功能"
    echo "2. 仅创建 auto_block 脚本"
    echo "3. 仅创建 udev 规则"
    echo "4. 测试当前配置"
    echo "5. 卸载自动挂载功能"
    echo "6. 检查并安装SMB开启分享"
    echo "0. 退出"

    read -p "输入选项: " choice

    case "$choice" in
        1) install_full ;;
        2) create_auto_block ;;
        3) create_udev_rules ;;
        4) test_current_config ;;
        5) uninstall ;;
        6) install_smb_share ;;
        0) echo "退出程序。"; exit 0 ;;
        *) echo "无效选项，请重试。" ;;
    esac

    echo # 输出空行以增加可读性
done
