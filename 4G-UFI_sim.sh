#!/bin/bash

# 脚本名称: 4G-UFI_sim.sh
# 功能: 在高通410棒子上执行切卡操作

# 设置日志文件路径
LOGFILE="/var/log/switch_sim.log"

# 记录日志函数
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOGFILE"
}

# 检查是否以 root 用户运行
if [ "$EUID" -ne 0 ]; then
    log "请以 root 用户运行此脚本。"
    exit 1
fi

# 等待 3 秒，确保系统初始化完成
log "等待 3 秒..."
sleep 3

# 检查 USB 设备是否处于全速模式，如果是则切换到 host 模式
log "检查 USB 设备模式..."
if grep 0 /sys/kernel/debug/usb/ci_hdrc.0/device | grep speed; then
    log "切换到 host 模式..."
    echo host > /sys/kernel/debug/usb/ci_hdrc.0/role || log "切换 host 模式失败！"
else
    log "USB 设备已处于 host 模式。"
fi

# 控制 SIM 卡相关 LED 状态
log "设置 SIM 卡 LED 状态..."
echo 1 > /sys/class/leds/sim:sel/brightness || log "设置 sim:sel 失败！"
echo 0 > /sys/class/leds/sim:en/brightness || log "设置 sim:en 失败！"
echo 0 > /sys/class/leds/sim:sel2/brightness || log "设置 sim:sel2 失败！"
echo 0 > /sys/class/leds/sim:en2/brightness || log "设置 sim:en2 失败！"

# 重新加载调制解调器驱动
log "重新加载调制解调器驱动..."
modprobe -r qcom-q6v5-mss || log "卸载 qcom-q6v5-mss 驱动失败！"
modprobe qcom-q6v5-mss || log "加载 qcom-q6v5-mss 驱动失败！"

# 重启 rmtfs 和 ModemManager 服务
log "重启 rmtfs 服务..."
systemctl restart rmtfs || log "重启 rmtfs 服务失败！"

log "重启 ModemManager 服务..."
systemctl restart dbus-org.freedesktop.ModemManager1.service || log "重启 ModemManager 服务失败！"

# 等待 3 秒，确保服务重启完成
log "等待 3 秒..."
sleep 3

# 停止 ModemManager，重置 SIM 卡电源，然后重新启动 ModemManager
log "重置 SIM 卡电源..."
systemctl stop ModemManager || log "停止 ModemManager 服务失败！"
qmicli -d /dev/wwan0qmi0 --uim-sim-power-off=1 || log "关闭 SIM 卡电源失败！"
qmicli -d /dev/wwan0qmi0 --uim-sim-power-on=1 || log "打开 SIM 卡电源失败！"
systemctl start ModemManager || log "启动 ModemManager 服务失败！"

log "切卡操作完成！"
