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
