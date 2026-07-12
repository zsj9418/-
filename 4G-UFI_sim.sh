#!/bin/bash

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

# ============================================================
# 新增功能：开启设备 IPv6 地址获取
# ============================================================
enable_ipv6() {
    log "========== 开启 IPv6 地址获取 =========="

    echo "==============================="
    echo "  IPv6 开启选项"
    echo "==============================="
    echo "1. 仅开启 IPv6（纯 IPv6）"
    echo "2. 开启 IPv4 + IPv6 双栈（推荐）"
    echo "3. 关闭 IPv6（恢复纯 IPv4）"
    echo "4. 查看当前 IPv6 状态"
    echo "5. 返回主菜单"
    echo "==============================="
    read -p "请输入选项 (1-5): " ipv6_choice

    case $ipv6_choice in
        1)
            log "用户选择：仅开启 IPv6"
            _set_ipv6_mode "ipv6"
            ;;
        2)
            log "用户选择：开启 IPv4 + IPv6 双栈"
            _set_ipv6_mode "ipv4v6"
            ;;
        3)
            log "用户选择：关闭 IPv6，恢复纯 IPv4"
            _set_ipv6_mode "ipv4"
            ;;
        4)
            _show_ipv6_status
            ;;
        5)
            return
            ;;
        *)
            log "无效选项，返回主菜单。"
            return
            ;;
    esac
}

# 设置 IP 协议模式（内部函数）
_set_ipv6_mode() {
    local MODE="$1"   # ipv4 / ipv6 / ipv4v6

    # --------------------------------------------------
    # 第一步：内核层面确保 IPv6 模块已启用
    # --------------------------------------------------
    if [ "$MODE" = "ipv4" ]; then
        log "在内核层面禁用 IPv6..."
        sysctl -w net.ipv6.conf.all.disable_ipv6=1        2>/dev/null
        sysctl -w net.ipv6.conf.default.disable_ipv6=1     2>/dev/null
        sysctl -w net.ipv6.conf.wwan0.disable_ipv6=1       2>/dev/null
        sysctl -w net.ipv6.conf.wwan0qmi0.disable_ipv6=1   2>/dev/null
        # 写入持久化配置
        _persist_sysctl_ipv6 1
    else
        log "在内核层面启用 IPv6..."
        sysctl -w net.ipv6.conf.all.disable_ipv6=0        2>/dev/null
        sysctl -w net.ipv6.conf.default.disable_ipv6=0     2>/dev/null
        sysctl -w net.ipv6.conf.wwan0.disable_ipv6=0       2>/dev/null
        sysctl -w net.ipv6.conf.wwan0qmi0.disable_ipv6=0   2>/dev/null
        # 开启接受 RA（路由通告）以获取 SLAAC 地址
        sysctl -w net.ipv6.conf.wwan0.accept_ra=2          2>/dev/null
        sysctl -w net.ipv6.conf.wwan0qmi0.accept_ra=2      2>/dev/null
        # 写入持久化配置
        _persist_sysctl_ipv6 0
    fi

    # --------------------------------------------------
    # 第二步：通过 qmicli 设置 Modem 的 IP 协议模式
    # --------------------------------------------------
    local QMI_DEV="/dev/wwan0qmi0"

    if [ ! -c "$QMI_DEV" ]; then
        log "错误：QMI 设备 $QMI_DEV 不存在！"
        return 1
    fi

    log "通过 qmicli 设置 WDS IP 协议为: $MODE ..."

    # 先断开现有数据连接
    log "断开现有移动数据连接..."
    nmcli con down modem 2>/dev/null
    sleep 2

    # 使用 qmicli 设置 IP family preference
    case $MODE in
        ipv4)
            qmicli -d "$QMI_DEV" --wds-set-ip-family=4 2>/dev/null
            log "Modem 已设置为 IPv4 模式"
            ;;
        ipv6)
            qmicli -d "$QMI_DEV" --wds-set-ip-family=6 2>/dev/null
            log "Modem 已设置为 IPv6 模式"
            ;;
        ipv4v6)
            qmicli -d "$QMI_DEV" --wds-set-ip-family=9 2>/dev/null
            log "Modem 已设置为 IPv4v6 双栈模式"
            ;;
    esac

    # --------------------------------------------------
    # 第三步：修改 NetworkManager 连接的 IP 协议配置
    # --------------------------------------------------
    log "更新 NetworkManager 连接 'modem' 的协议配置..."

    # 检查连接是否存在
    if ! nmcli con show modem &>/dev/null; then
        log "警告：未找到名为 'modem' 的连接，请先创建 APN 连接（菜单选项1）。"
        return 1
    fi

    case $MODE in
        ipv4)
            # 纯 IPv4
            nmcli con mod modem ipv6.method "disabled"     2>/dev/null || \
            nmcli con mod modem ipv6.method "ignore"       2>/dev/null
            nmcli con mod modem ipv4.method "auto"
            log "NetworkManager: IPv6 已禁用，仅使用 IPv4"
            ;;
        ipv6)
            # 纯 IPv6
            nmcli con mod modem ipv6.method "auto"
            nmcli con mod modem ipv4.method "disabled"     2>/dev/null || \
            nmcli con mod modem ipv4.method "manual"       2>/dev/null
            log "NetworkManager: IPv4 已禁用，仅使用 IPv6"
            ;;
        ipv4v6)
            # 双栈
            nmcli con mod modem ipv4.method "auto"
            nmcli con mod modem ipv6.method "auto"
            nmcli con mod modem ipv6.addr-gen-mode "stable-privacy" 2>/dev/null
            log "NetworkManager: 已启用 IPv4 + IPv6 双栈"
            ;;
    esac

    # --------------------------------------------------
    # 第四步：重新激活连接
    # --------------------------------------------------
    log "重新激活移动数据连接..."
    sleep 2
    nmcli con up modem || {
        log "警告：自动激活连接失败，尝试重启 ModemManager 后再试..."
        systemctl restart ModemManager
        sleep 5
        nmcli con up modem || log "错误：连接激活失败，请检查 SIM 卡和信号状态。"
    }

    # --------------------------------------------------
    # 第五步：等待并显示结果
    # --------------------------------------------------
    log "等待地址分配（最多 15 秒）..."
    sleep 10

    _show_ipv6_status

    log "========== IPv6 配置完成 =========="
}

# 持久化 sysctl IPv6 配置（内部函数）
_persist_sysctl_ipv6() {
    local DISABLE_VAL="$1"  # 0=启用IPv6  1=禁用IPv6
    local SYSCTL_CONF="/etc/sysctl.d/99-ipv6.conf"

    cat > "$SYSCTL_CONF" <<EOF
# IPv6 配置 - 由 SIM 管理工具自动生成
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
net.ipv6.conf.all.disable_ipv6 = ${DISABLE_VAL}
net.ipv6.conf.default.disable_ipv6 = ${DISABLE_VAL}
EOF

    if [ "$DISABLE_VAL" -eq 0 ]; then
        cat >> "$SYSCTL_CONF" <<EOF
net.ipv6.conf.wwan0.accept_ra = 2
net.ipv6.conf.wwan0qmi0.accept_ra = 2
EOF
    fi

    sysctl --system >/dev/null 2>&1
    log "sysctl IPv6 配置已持久化到 $SYSCTL_CONF"
}

# 显示当前 IPv6 状态（内部函数）
_show_ipv6_status() {
    echo ""
    echo "============================================"
    echo "  当前网络 IPv6 状态"
    echo "============================================"

    # 显示内核 IPv6 开关状态
    local ALL_DISABLE=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)
    if [ "$ALL_DISABLE" = "0" ]; then
        echo "  内核 IPv6:  ✅ 已启用"
    else
        echo "  内核 IPv6:  ❌ 已禁用"
    fi

    echo ""
    echo "  --- 网络接口地址 ---"

    # 显示 wwan0 的地址
    if ip addr show wwan0 &>/dev/null; then
        echo "  [wwan0]"
        local IPV4_ADDR=$(ip -4 addr show wwan0 2>/dev/null | grep -oP 'inet \K[\d.]+')
        local IPV6_ADDR=$(ip -6 addr show wwan0 scope global 2>/dev/null | grep -oP 'inet6 \K[^ ]+')
        local IPV6_LINK=$(ip -6 addr show wwan0 scope link 2>/dev/null | grep -oP 'inet6 \K[^ ]+')

        [ -n "$IPV4_ADDR" ] && echo "    IPv4:        $IPV4_ADDR" || echo "    IPv4:        未分配"
        [ -n "$IPV6_ADDR" ] && echo "    IPv6 全局:   $IPV6_ADDR" || echo "    IPv6 全局:   未分配"
        [ -n "$IPV6_LINK" ] && echo "    IPv6 链路:   $IPV6_LINK" || echo "    IPv6 链路:   未分配"
    fi

    # 显示 wwan0qmi0 的地址
    if ip addr show wwan0qmi0 &>/dev/null; then
        echo "  [wwan0qmi0]"
        local IPV4_ADDR2=$(ip -4 addr show wwan0qmi0 2>/dev/null | grep -oP 'inet \K[\d.]+')
        local IPV6_ADDR2=$(ip -6 addr show wwan0qmi0 scope global 2>/dev/null | grep -oP 'inet6 \K[^ ]+')
        local IPV6_LINK2=$(ip -6 addr show wwan0qmi0 scope link 2>/dev/null | grep -oP 'inet6 \K[^ ]+')

        [ -n "$IPV4_ADDR2" ] && echo "    IPv4:        $IPV4_ADDR2" || echo "    IPv4:        未分配"
        [ -n "$IPV6_ADDR2" ] && echo "    IPv6 全局:   $IPV6_ADDR2" || echo "    IPv6 全局:   未分配"
        [ -n "$IPV6_LINK2" ] && echo "    IPv6 链路:   $IPV6_LINK2" || echo "    IPv6 链路:   未分配"
    fi

    echo ""

    # 显示 DNS 信息
    echo "  --- DNS 服务器 ---"
    if command -v resolvectl &>/dev/null; then
        resolvectl status 2>/dev/null | grep -A5 "wwan" | grep "DNS Server" | sed 's/^/    /'
    else
        grep "nameserver" /etc/resolv.conf 2>/dev/null | sed 's/^/    /'
    fi

    echo ""

    # IPv6 连通性测试
    echo "  --- IPv6 连通性测试 ---"
    if ping -6 -c 1 -W 3 2001:4860:4860::8888 &>/dev/null; then
        echo "    Google DNS (IPv6): ✅ 可达"
    else
        echo "    Google DNS (IPv6): ❌ 不可达"
    fi

    if ping -6 -c 1 -W 3 2400:3200::1 &>/dev/null; then
        echo "    阿里 DNS  (IPv6): ✅ 可达"
    else
        echo "    阿里 DNS  (IPv6): ❌ 不可达"
    fi

    echo "============================================"
    echo ""

    log "IPv6 状态查看完成"
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
    # 清理 IPv6 sysctl 配置
    rm -f /etc/sysctl.d/99-ipv6.conf 2>/dev/null
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
    echo "  高通410棒子SIM卡管理工具"
    echo "==============================="
    echo "1. 创建 APN 连接"
    echo "2. 切换到卡槽"
    echo "3. 切换到 eSIM"
    echo "4. 开启设备 IPv6 地址获取"
    echo "5. 设置为自启动"
    echo "6. 卸载清理"
    echo "7. 查看 Modem 状态"
    echo "8. 退出"
    echo "==============================="
}

# 主函数
main() {
    check_root
    while true; do
        show_menu
        read -p "请输入选项 (1-8): " choice
        case $choice in
            1) create_apn ;;
            2) switch_to_slot ;;
            3) switch_to_esim ;;
            4) enable_ipv6 ;;
            5) enable_autostart ;;
            6) uninstall ;;
            7) check_modem_status ;;
            8) log "退出脚本。" && exit 0 ;;
            *) log "无效选项，请重新输入。" ;;
        esac
        read -p "按回车键继续..."
    done
}

# 执行主函数
main
