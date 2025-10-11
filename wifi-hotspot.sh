#!/bin/bash
# ===============================================================
# Wi‑Fi 自动热点 / 自动切换脚本
# 版本: 1.0
# ===============================================================
# 功能清单：
# ✅ 自动检测/安装 NetworkManager 和 dnsmasq
# ✅ 自动识别无线/有线/4G 接口
# ✅ 自动检查无线网卡 AP 模式
# ✅ 自动清理/列出旧热点
# ✅ 创建热点（含 DHCP/NAT 自修复）
# ✅ 连接 Wi‑Fi 网络（手动/智能）
# ✅ 自动模式切换 (网线插拔智能启用)
# ✅ 后台 Dispatcher 服务
# ✅ 日志管理、1MB 自动清理
# ---------------------------------------------------------------

SCRIPT_VERSION="1.0"
SCRIPT_NAME=$(basename "$0")

CONFIG_DIR="/var/lib/wifi_auto_switch"
INTERFACE_NAME_FILE="$CONFIG_DIR/eth_iface"
LOG_FILE="/var/log/wifi_auto_switch.log"
MAX_LOG_SIZE=1048576

CUSTOM_WIFI_NAME=""
CUSTOM_WIFI_PASSWORD=""

# ===============================================================
# 日志与通用函数
# ===============================================================
restrict_log_size() {
    [[ -f "$LOG_FILE" ]] || return
    local size
    size=$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)
    if (( size >= MAX_LOG_SIZE )); then
        : >"$LOG_FILE" && echo "$(date '+%F %T') - 日志超过1MB已清空" >"$LOG_FILE"
    fi
}

log() {
    restrict_log_size
    echo "$(date '+%F %T') - $1" >>"$LOG_FILE"
}

[[ $EUID -eq 0 ]] || { echo "❌ 请以 root 权限运行"; exit 1; }

log "=== 启动 wifi_auto_switch v$SCRIPT_VERSION ==="

# ===============================================================
# dnsmasq 自动检测、安装
# ===============================================================
find_dnsmasq_binary() {
    for p in /usr/sbin/dnsmasq /usr/bin/dnsmasq /sbin/dnsmasq /bin/dnsmasq; do
        [[ -x "$p" ]] && { echo "$p"; return; }
    done
    echo ""
}

DNSMASQ_BIN=$(find_dnsmasq_binary)
if [[ -z "$DNSMASQ_BIN" ]]; then
    log "未找到 dnsmasq，尝试安装"
    if command -v apt-get &>/dev/null; then
        apt-get update -y && apt-get install -y dnsmasq
    elif command -v yum &>/dev/null; then
        yum install -y dnsmasq
    fi
    DNSMASQ_BIN=$(find_dnsmasq_binary)
    if [[ -z "$DNSMASQ_BIN" ]]; then
        echo "⚠️ 未检测到 dnsmasq，将使用 NetworkManager 内置 DHCP 而非外部服务"
        log "降级为 NetworkManager 内置 DHCP"
    else
        log "dnsmasq 安装成功，路径: $DNSMASQ_BIN"
    fi
fi

# ===============================================================
# NetworkManager 存在性检测
# ===============================================================
if ! command -v nmcli &>/dev/null; then
    log "安装 NetworkManager"
    if command -v apt-get &>/dev/null; then
        apt-get update -y && apt-get install -y network-manager wireless-tools
    elif command -v yum &>/dev/null; then
        yum install -y NetworkManager wireless-tools
    fi
fi

# 确保 NetworkManager 开启并使用 dnsmasq
systemctl enable --now NetworkManager 2>/dev/null
grep -q "dns=dnsmasq" /etc/NetworkManager/NetworkManager.conf ||
    echo -e "[main]\ndns=dnsmasq\n" >>/etc/NetworkManager/NetworkManager.conf
systemctl restart NetworkManager >/dev/null 2>&1

# ===============================================================
# 基础接口与检测函数
# ===============================================================
detect_wifi_interface() { nmcli -t -f DEVICE,TYPE dev | awk -F: '$2=="wifi"{print $1;exit}'; }
detect_eth_interface() { nmcli -t -f DEVICE,TYPE dev | awk -F: '$2=="ethernet"{print $1;exit}'; }
is_eth_disconnected() { [[ -f /sys/class/net/$1/carrier ]] && [[ $(< /sys/class/net/$1/carrier) -eq 0 ]]; }
check_wifi_ap_support() { iw list 2>/dev/null | awk '/Supported interface modes/,/valid interface combinations/' | grep -q " AP"; }

# ===============================================================
# 热点管理：列出与清理
# ===============================================================
list_and_clean_hotspots() {
    local list
    list=$(nmcli -t -f NAME,UUID,TYPE con | awk -F: '$3=="wifi" && $1~/^AutoHotspot-/{print NR". "$1" ["$2"]"}')
    if [[ -z "$list" ]]; then
        echo "💡 当前没有旧热点"
        return 0
    fi
    echo "当前已存在的 AutoHotspot-* 连接列表："
    echo "$list"
    read -rp "是否要清理这些旧连接？(y/n): " C
    if [[ "$C" =~ ^[Yy]$ ]]; then
        nmcli -t -f UUID,TYPE con | awk -F: '$2=="wifi"{print $1}' | xargs -r -n1 nmcli con delete uuid >/dev/null 2>&1
        echo "✅ 已清理旧热点连接"; log "用户手动清理旧热点"
    fi
}

# ===============================================================
# DHCP & NAT 服务
# ===============================================================
ensure_dhcp_nat() {
    local IFACE=$1 OUT=$2
    ip addr show "$IFACE" | grep -q "10\.42\.0\.1" || {
        ip addr flush dev "$IFACE"
        ip addr add 10.42.0.1/24 dev "$IFACE"
        log "为接口 $IFACE 配置静态地址 10.42.0.1/24"
    }

    if [[ -n "$DNSMASQ_BIN" ]]; then
        if ! pgrep -a dnsmasq | grep -q "$IFACE"; then
            log "启动 dnsmasq 服务绑定 $IFACE"
            "$DNSMASQ_BIN" --interface="$IFACE" --bind-interfaces --except-interface=lo \
                --dhcp-range=10.42.0.10,10.42.0.100,12h \
                --dhcp-option=3,10.42.0.1 --dhcp-option=6,223.5.5.5,8.8.8.8 \
                --log-facility=/var/log/dnsmasq-hotspot.log &
        fi
    else
        log "无外部 dnsmasq，使用 NetworkManager 内置 DNS/DHCP"
    fi

    # 启用转发与 NAT
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    iptables -t nat -C POSTROUTING -o "$OUT" -j MASQUERADE 2>/dev/null ||
        iptables -t nat -A POSTROUTING -o "$OUT" -j MASQUERADE
    log "启用 NAT 转发 ($IFACE → $OUT)"
}

# ===============================================================
# 创建 Wi‑Fi 热点
# ===============================================================
create_wifi_hotspot() {
    local IFACE=$1
    local SSID=${2:-4G-WIFI}
    local PASS=${3:-12345678}
    local OUT
    OUT=$(detect_eth_interface)
    [[ -z "$OUT" ]] && OUT="wwan0"

    # 展示并处理旧热点
    list_and_clean_hotspots

    [[ -z "$IFACE" ]] && { echo "❌ 未检测到无线网卡"; return; }
    if ! check_wifi_ap_support "$IFACE"; then
        echo "❌ 当前无线芯片不支持 AP 模式"; return
    fi

    nmcli con add type wifi ifname "$IFACE" con-name "AutoHotspot-$SSID" ssid "$SSID" \
        802-11-wireless.mode ap 802-11-wireless.band bg \
        ipv4.addresses 10.42.0.1/24 ipv4.method shared ipv6.method ignore >/dev/null
    nmcli con mod "AutoHotspot-$SSID" 802-11-wireless-security.key-mgmt wpa-psk \
        802-11-wireless-security.psk "$PASS"

    if nmcli con up "AutoHotspot-$SSID" >/dev/null 2>&1; then
        echo "✅ 热点已启动：$SSID"; log "热点创建成功"
        ensure_dhcp_nat "$IFACE" "$OUT"
    else
        echo "⚙️ NetworkManager 启动失败，采用手动 DHCP/NAT 方案"
        ip link set "$IFACE" up
        ip addr flush dev "$IFACE"
        ip addr add 10.42.0.1/24 dev "$IFACE"
        ensure_dhcp_nat "$IFACE" "$OUT"
    fi
}

# ===============================================================
# Wi‑Fi 连接功能
# ===============================================================
connect_wifi_network() {
    local IFACE=$1 SSID=$2 PASS=$3
    nmcli dev wifi connect "$SSID" password "$PASS" ifname "$IFACE"
}

smart_connect_wifi() {
    local IFACE=$1
    local SAVED
    SAVED=$(nmcli -t -f NAME,TYPE con | awk -F: '$2=="wifi"{print $1}')
    for S in $SAVED; do nmcli con up "$S" ifname "$IFACE" && return 0; done
    nmcli dev wifi rescan ifname "$IFACE" >/dev/null; sleep 2
    nmcli -t -f SSID,SIGNAL dev wifi list ifname "$IFACE" | head -n 5 |
        while IFS=: read -r ss sig; do nmcli dev wifi connect "$ss" ifname "$IFACE" && return 0; done
    return 1
}

# ===============================================================
# 自动切换（根据网线状态）
# ===============================================================
auto_switch_wifi_mode() {
    local WIFI
    WIFI=$(detect_wifi_interface)
    local ETH
    ETH=$(detect_eth_interface)
    [[ -z "$ETH" ]] && ETH="wwan0"

    [[ -z "$WIFI" ]] && { log "无无线网卡"; return; }

    if is_eth_disconnected "$ETH"; then
        log "有线断开 → Wi‑Fi 模式"
        smart_connect_wifi "$WIFI" || create_wifi_hotspot "$WIFI"
    else
        log "有线连接 → 热点模式"
        create_wifi_hotspot "$WIFI"
    fi
}

# ===============================================================
# 后台 Dispatcher 服务
# ===============================================================
start_background_service() {
    local DISP="/etc/NetworkManager/dispatcher.d/wifi-auto-switch.sh"
    mkdir -p "$CONFIG_DIR"
    echo "$(detect_eth_interface)" >"$INTERFACE_NAME_FILE"

    cat >"$DISP" <<EOF
#!/bin/bash
IF=\$1; ACT=\$2
LOGFILE="$LOG_FILE"; ETH_FILE="$INTERFACE_NAME_FILE"
[[ -f "\$ETH_FILE" ]] && ETH=\$(cat "\$ETH_FILE")
echo "\$(date '+%F %T') - Dispatcher: \$IF \$ACT" >>"\$LOGFILE"
if [[ "\$IF" == "\$ETH" && "\$ACT" =~ ^(up|down|pre-down|post-down)$ ]]; then
    /usr/local/bin/$SCRIPT_NAME auto-switch-dispatcher
fi
EOF

    chmod +x "$DISP"
    cp "$0" "/usr/local/bin/$SCRIPT_NAME"
    chmod +x "/usr/local/bin/$SCRIPT_NAME"
    log "后台 Dispatcher 已安装"
    auto_switch_wifi_mode
}

stop_background_service() {
    rm -f "/etc/NetworkManager/dispatcher.d/wifi-auto-switch.sh"
    rm -f "/usr/local/bin/$SCRIPT_NAME"
    rm -rf "$CONFIG_DIR"
    log "后台服务已卸载"
}

# ===============================================================
# 管理保存的 Wi‑Fi
# ===============================================================
manage_saved_wifi() {
    echo "以下为保存的 Wi‑Fi 网络："
    nmcli con show | grep wifi | awk '{print NR". "$1}'
    read -rp "是否添加新 Wi‑Fi？(y/n): " C
    [[ "$C" =~ ^[Yy]$ ]] || return
    read -rp "输入 SSID: " S
    read -rp "输入 密码: " P
    connect_wifi_network "$(detect_wifi_interface)" "$S" "$P"
}

# ===============================================================
# 命令行参数 / 主菜单
# ===============================================================
[[ "$1" == "auto-switch-dispatcher" ]] && { auto_switch_wifi_mode; exit 0; }

while true; do
    echo "========= Wi‑Fi 自动切换 v$SCRIPT_VERSION ========="
    echo "1. 创建热点"
    echo "2. 连接指定 Wi‑Fi"
    echo "3. 手动切换测试"
    echo "4. 启动后台服务"
    echo "5. 卸载后台服务"
    echo "6. 管理保存 Wi‑Fi"
    echo "7. 列出/清理旧热点"
    echo "8. 退出"
    read -rp "选择 (1-8): " CH
    case $CH in
        1)
            IF=$(detect_wifi_interface)
            read -rp "热点名(默认4G-WIFI): " SS; SS=${SS:-4G-WIFI}
            read -rp "密码(默认12345678): " PW; PW=${PW:-12345678}
            CUSTOM_WIFI_NAME="$SS"
            CUSTOM_WIFI_PASSWORD="$PW"
            create_wifi_hotspot "$IF" "$SS" "$PW"
            ;;
        2)
            IF=$(detect_wifi_interface)
            read -rp "Wi‑Fi 名称: " SS
            read -rp "密码: " PW
            connect_wifi_network "$IF" "$SS" "$PW"
            ;;
        3) auto_switch_wifi_mode ;;
        4) start_background_service ;;
        5) stop_background_service ;;
        6) manage_saved_wifi ;;
        7) list_and_clean_hotspots ;;
        8) echo "退出"; exit 0 ;;
        *) echo "无效选择";;
    esac
done
