#!/bin/bash

# 脚本名称: 4G-UFI_sim.sh
# 功能: 高通410棒子SIM卡管理工具

# 设置日志文件路径
LOGFILE="/var/log/sim_manager.log"
# 日志文件大小限制 (1MB)
LOG_SIZE_LIMIT=$((1 * 1024 * 1024))

# 检查日志文件大小，超过限制则清空
check_log_size() {
    if [ -f "$LOGFILE" ] && [ $(stat -c%s "$LOGFILE") -gt "$LOG_SIZE_LIMIT" ]; then
        echo "" > "$LOGFILE"
        log "日志文件超过 1MB，已清空。"
    fi
}

# 记录日志函数
log() {
    check_log_size
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOGFILE"
}

# 检查是否以 root 用户运行
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log "请以 root 用户运行此脚本。"
        exit 1
    fi
}

# 创建 APN 连接
create_apn() {
    log "创建 APN 连接..."
    # 删除现有的 APN 连接
    nmcli con del modem 2>/dev/null || log "删除现有 APN 连接失败或连接不存在。"

    # 选择运营商
    echo "请选择运营商："
    echo "1. 中国移动 (cmnet)"
    echo "2. 中国移动 (cmtds)"
    echo "3. 中国电信 (ctlte)"
    echo "4. 中国电信 (ctnet)"
    echo "5. 中国联通 (3gnet)"
    echo "6. 中国联通 (cmtds)"
    echo "7. 中国广电 (cbnet)"
    echo "8. 中国广电 (cmnet)"
    read -p "请输入选项 (1-8): " apn_choice

    case $apn_choice in
        1) APN="cmnet" ;;
        2) APN="cmtds" ;;
        3) APN="ctlte" ;;
        4) APN="ctnet" ;;
        5) APN="3gnet" ;;
        6) APN="cmtds" ;;
        7) APN="cbnet" ;;
        8) APN="cmnet" ;;
        *) log "无效选项，未创建 APN 连接。" && return ;;
    esac

    # 创建 APN 连接
    nmcli con add type gsm ifname wwan0qmi0 con-name modem apn "$APN" || log "创建 APN 连接失败！"
    log "APN 连接创建完成，APN: $APN"
}

# 切换为卡槽
switch_to_slot() {
    log "切换到卡槽..."
    echo 1 > /sys/class/leds/sim:sel/brightness || log "设置 sim:sel 失败！"
    echo 0 > /sys/class/leds/sim:en/brightness || log "设置 sim:en 失败！"
    echo 0 > /sys/class/leds/sim:sel2/brightness || log "设置 sim:sel2 失败！"
    echo 0 > /sys/class/leds/sim:en2/brightness || log "设置 sim:en2 失败！"
    modprobe -r qcom-q6v5-mss || log "卸载 qcom-q6v5-mss 驱动失败！"
    modprobe qcom-q6v5-mss || log "加载 qcom-q6v5-mss 驱动失败！"
    systemctl restart rmtfs || log "重启 rmtfs 服务失败！"
    systemctl restart dbus-org.freedesktop.ModemManager1.service || log "重启 ModemManager 服务失败！"
    sleep 5 && systemctl stop ModemManager && qmicli -d /dev/wwan0qmi0 --uim-sim-power-off=1 && qmicli -d /dev/wwan0qmi0 --uim-sim-power-on=1 && systemctl start ModemManager || log "卡槽切换后操作 ModemManager 和 qmicli 命令失败！"
    log "切换到卡槽完成！"
}

# 切换为 eSIM
switch_to_esim() {
    log "切换到 eSIM..."
    echo 0 > /sys/class/leds/sim:sel/brightness || log "设置 sim:sel 失败！"
    echo 0 > /sys/class/leds/sim:en/brightness || log "设置 sim:en 失败！"
    echo 1 > /sys/class/leds/sim:sel2/brightness || log "设置 sim:sel2 失败！"
    echo 0 > /sys/class/leds/sim:en2/brightness || log "设置 sim:en2 失败！"
    modprobe -r qcom-q6v5-mss || log "卸载 qcom-q6v5-mss 驱动失败！"
    modprobe qcom-q6v5-mss || log "加载 qcom-q6v5-mss 驱动失败！"
    systemctl restart rmtfs || log "重启 rmtfs 服务失败！"
    systemctl restart dbus-org.freedesktop.ModemManager1.service || log "重启 ModemManager 服务失败！"
    sleep 5 && systemctl stop ModemManager && qmicli -d /dev/wwan0qmi0 --uim-sim-power-off=1 && qmicli -d /dev/wwan0qmi0 --uim-sim-power-on=1 && systemctl start ModemManager || log "eSIM 切换后操作 ModemManager 和 qmicli 命令失败！"
    log "切换到 eSIM 完成！"
}

# 设置为自启动
enable_autostart() {
    log "设置脚本为自启动..."
    cat <<EOF | sudo tee /etc/systemd/system/sim_manager.service > /dev/null
[Unit]
Description=SIM Card Manager Script
After=network.target

[Service]
ExecStart=/usr/local/bin/sim_manager.sh
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload || log "重新加载 systemd 配置失败！"
    systemctl enable sim_manager.service || log "启用自启动失败！"
    systemctl start sim_manager.service || log "启动服务失败！"
    log "自启动设置完成！"
}

# 卸载清理
uninstall() {
    log "卸载脚本及服务..."
    systemctl stop sim_manager.service || log "停止服务失败！"
    systemctl disable sim_manager.service || log "禁用服务失败！"
    rm /etc/systemd/system/sim_manager.service || log "删除服务文件失败！"
    rm /usr/local/bin/sim_manager.sh || log "删除脚本文件失败！"
    systemctl daemon-reload || log "重新加载 systemd 配置失败！"
    log "卸载完成！"
}

# 查看 Modem 状态
check_modem_status() {
    log "查看 Modem 状态..."
    mmcli -m 0
    mmcli -i 0
}

# 显示菜单
show_menu() {
    echo "==============================="
    echo "高通410棒子SIM卡管理工具"
    echo "1. 创建 APN 连接"
    echo "2. 切换到卡槽"
    echo "3. 切换到 eSIM"
    echo "4. 设置为自启动"
    echo "5. 卸载清理"
    echo "6. 查看 Modem 状态"
    echo "7. 退出"
    echo "==============================="
}

# 主函数
main() {
    check_root
    while true; do
        show_menu
        read -p "请输入选项 (1-7): " choice
        case $choice in
            1) create_apn ;;
            2) switch_to_slot ;;
            3) switch_to_esim ;;
            4) enable_autostart ;;
            5) uninstall ;;
            6) check_modem_status ;;
            7) log "退出脚本。" && exit 0 ;;
            *) log "无效选项，请重新输入。" ;;
        esac
        read -p "按回车键继续..."
    done
}

# 执行主函数
main
