#!/bin/bash

# 定义 auto_block 脚本和 udev 规则文件的路径
AUTO_BLOCK_PATH="/bin/auto_block"
UDEV_RULES_PATH="/etc/udev/rules.d/10-auto_block.rules"

# 函数：完整安装自动挂载功能
install_full() {
    echo "安装自动挂载功能..."
    # 复制 auto_block 文件到 /bin 并设置权限
    cp /path/to/auto_block "$AUTO_BLOCK_PATH"
    chmod +x "$AUTO_BLOCK_PATH"

    # 创建 udev 规则文件
    cat << EOF > "$UDEV_RULES_PATH"
KERNEL!="sd[a-z][0-9]|hd[a-z][0-9]|mmcblk[0-9]p[0-9]", GOTO="uuid_auto_mount_end"
SUBSYSTEM!="block", GOTO="uuid_auto_mount_end"
IMPORT{program}="/sbin/blkid -o udev -p %N"
ENV{ID_FS_TYPE}=="", GOTO="uuid_auto_mount_end"
ENV{ID_FS_UUID}=="", GOTO="uuid_auto_mount_end"
ACTION=="add|remove", RUN+="$AUTO_BLOCK_PATH"
LABEL="uuid_auto_mount_end"
EOF

    # 重新加载 udev 规则
    udevadm control --reload

    echo "自动挂载功能安装完成，请重启设备以生效。"
}

# 函数：仅创建 auto_block 脚本
create_auto_block() {
    echo "创建 auto_block 脚本..."
    cp /path/to/auto_block "$AUTO_BLOCK_PATH"
    chmod +x "$AUTO_BLOCK_PATH"
    echo "auto_block 脚本创建完成。"
}

# 函数：仅创建 udev 规则
create_udev_rules() {
    echo "创建 udev 规则..."
    cat << EOF > "$UDEV_RULES_PATH"
KERNEL!="sd[a-z][0-9]|hd[a-z][0-9]|mmcblk[0-9]p[0-9]", GOTO="uuid_auto_mount_end"
SUBSYSTEM!="block", GOTO="uuid_auto_mount_end"
IMPORT{program}="/sbin/blkid -o udev -p %N"
ENV{ID_FS_TYPE}=="", GOTO="uuid_auto_mount_end"
ENV{ID_FS_UUID}=="", GOTO="uuid_auto_mount_end"
ACTION=="add|remove", RUN+="$AUTO_BLOCK_PATH"
LABEL="uuid_auto_mount_end"
EOF

    # 重新加载 udev 规则
    udevadm control --reload

    echo "udev 规则创建完成。"
}

# 函数：测试当前配置
test_current_config() {
    echo "测试当前配置..."
    if [ -x "$AUTO_BLOCK_PATH" ] && [ -f "$UDEV_RULES_PATH" ]; then
        echo "配置正常: auto_block 脚本和 udev 规则均已存在。"
    else
        echo "配置异常: 请检查 auto_block 脚本和 udev 规则是否存在。"
    fi
}

# 函数：卸载自动挂载功能
uninstall() {
    echo "卸载自动挂载功能..."
    rm -f "$AUTO_BLOCK_PATH"
    rm -f "$UDEV_RULES_PATH"
    udevadm control --reload
    echo "自动挂载功能已卸载。"
}

# 主菜单循环
while true; do
    echo "请选择操作:"
    echo "1. 完整安装自动挂载功能"
    echo "2. 仅创建 auto_block 脚本"
    echo "3. 仅创建 udev 规则"
    echo "4. 测试当前配置"
    echo "5. 卸载自动挂载功能"
    echo "0. 退出"

    read -p "输入选项: " choice

    case "$choice" in
        1) install_full ;;
        2) create_auto_block ;;
        3) create_udev_rules ;;
        4) test_current_config ;;
        5) uninstall ;;
        0) echo "退出程序。"; exit 0 ;;
        *) echo "无效选项，请重试。" ;;
    esac

    echo # 输出空行以增加可读性
done
