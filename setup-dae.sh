#!/bin/sh
# 一键设置 dae 的全平台兼容脚本 (支持 Ubuntu/Debian/CentOS/Alpine/OpenWrt)
# 功能：配置 dae、无损更新核心、更新 geo 数据、管理服务、中文菜单驱动
# 避免硬编码，动态获取 IP、网段和接口，兼容多设备

CONFIG_FILE="/etc/dae/config.dae"
GEO_DIR="/usr/share/dae"
PERSIST_DIR="/etc/dae/persist.d"
UPDATE_GEO_SCRIPT="/etc/dae/update-geo.sh"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 检查 root 权限
if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}请以 root 权限运行此脚本${NC}"
    exit 1
fi

# ================= 智能识别与跨平台依赖 =================
detect_system_env() {
    PKG_MANAGER=""
    INSTALL_CMD=""
    
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt"
        INSTALL_CMD="apt-get install -y"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
        INSTALL_CMD="dnf install -y"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
        INSTALL_CMD="yum install -y"
    elif command -v pacman >/dev/null 2>&1; then
        PKG_MANAGER="pacman"
        INSTALL_CMD="pacman -Sy --noconfirm"
    elif command -v apk >/dev/null 2>&1; then
        PKG_MANAGER="apk"
        INSTALL_CMD="apk add"
    elif command -v opkg >/dev/null 2>&1; then
        PKG_MANAGER="opkg"
        INSTALL_CMD="opkg install"
        opkg update >/dev/null 2>&1
    fi

    # 识别服务管理器 (systemd vs init.d)
    if command -v systemctl >/dev/null 2>&1 && pidof systemd >/dev/null 2>&1; then
        SERVICE_MGR="systemd"
    else
        SERVICE_MGR="initd"
    fi
}

check_dependencies() {
    local deps="curl unzip iproute2"
    for dep in curl unzip ip; do
        if ! command -v $dep >/dev/null 2>&1; then
            echo -e "${YELLOW}缺少依赖 $dep，正在尝试通过 $PKG_MANAGER 安装...${NC}"
            if [ -n "$INSTALL_CMD" ]; then
                local pkg_name=$dep
                [ "$dep" = "ip" ] && pkg_name="iproute2"
                $INSTALL_CMD $pkg_name >/dev/null 2>&1
            fi
        fi
    done
}

manage_service() {
    local action=$1
    local svc_name="dae"
    
    if [ "$SERVICE_MGR" = "systemd" ]; then
        if [ "$action" = "status" ]; then
            systemctl is-active --quiet $svc_name && echo -e "${GREEN}${svc_name} 正在运行${NC}" || echo -e "${YELLOW}${svc_name} 未运行${NC}"
        else
            systemctl $action $svc_name 2>/dev/null
        fi
    else
        if [ "$action" = "status" ]; then
            pgrep $svc_name >/dev/null && echo -e "${GREEN}${svc_name} 正在运行${NC}" || echo -e "${YELLOW}${svc_name} 未运行${NC}"
        elif [ "$action" = "enable" ] || [ "$action" = "disable" ]; then
            /etc/init.d/$svc_name $action 2>/dev/null
        else
            /etc/init.d/$svc_name $action 2>/dev/null || killall $svc_name 2>/dev/null
        fi
    fi
}
# ========================================================

# 动态获取 LAN 接口、IP 和网段 (兼容跨平台与新老 OpenWrt)
get_network_info() {
    # 优先使用通用 Linux 底层命令获取
    DEFAULT_IFACE=$(ip route 2>/dev/null | grep default | awk '{print $5}' | head -n1)
    
    if [ -n "$DEFAULT_IFACE" ]; then
        LAN_IFACE="$DEFAULT_IFACE"
        WAN_IFACE="$DEFAULT_IFACE"
        LAN_CIDR=$(ip addr show "$LAN_IFACE" 2>/dev/null | awk '/inet / {print $2}' | head -n1)
        LAN_IP=$(echo "$LAN_CIDR" | cut -d/ -f1)
    else
        # 兜底 OpenWrt uci
        if command -v uci >/dev/null 2>&1; then
            LAN_IFACE=$(uci get network.lan.device 2>/dev/null || uci get network.lan.ifname 2>/dev/null || echo "br-lan")
            LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null || ip addr show "$LAN_IFACE" | grep -o "inet [0-9.]\+" | cut -d' ' -f2)
            WAN_IFACE=$(uci get network.wan.device 2>/dev/null || uci get network.wan.ifname 2>/dev/null || echo "wan")
            LAN_NETMASK=$(uci get network.lan.netmask 2>/dev/null || echo "255.255.255.0")
            LAN_CIDR="$LAN_IP/24"
        else
            echo -e "${RED}无法获取网络接口信息，请检查网络配置！${NC}"
            exit 1
        fi
    fi

    if [ -z "$LAN_IP" ]; then
        echo -e "${RED}获取 IP 失败，请检查网络！${NC}"
        exit 1
    fi
}

# 检测主路由或旁路由
detect_router_mode() {
    if ip route | grep -q "^default via"; then
        echo "side"
    else
        echo "main"
    fi
}

# 验证订阅地址（采用更合理的正则校验）
validate_subscription() {
    local url=$1
    if echo "$url" | grep -qE "^https?://"; then
        return 0
    else
        return 1
    fi
}

# 检查并清理 sing-box
cleanup_sing_box() {
    if pgrep sing-box >/dev/null 2>&1; then
        echo -e "${YELLOW}检测到 sing-box 正在运行，正在停止...${NC}"
        if [ "$SERVICE_MGR" = "systemd" ]; then systemctl stop sing-box 2>/dev/null; else /etc/init.d/sing-box stop 2>/dev/null; fi
        killall sing-box >/dev/null 2>&1
    fi
}

# ================= 还原：完整版 dae 配置生成 =================
generate_dae_config() {
    local subscription_url=$1
    local router_mode=$2
    local wan_setting="wan_interface: auto"
    local lan_setting="#lan_interface: docker0"

    if [ "$router_mode" = "main" ]; then
        wan_setting="wan_interface: $WAN_IFACE"
    else
        lan_setting="lan_interface: $LAN_IFACE"
    fi

    mkdir -p "$PERSIST_DIR"
    mkdir -p "$(dirname "$CONFIG_FILE")"
    
    cat << EOF > "$CONFIG_FILE"
global {
    ##### Software options.

    # tproxy port to listen on. It is NOT a HTTP/SOCKS port, and is just used by eBPF program.
    tproxy_port: 12345

    # Set it true to protect tproxy port from unsolicited traffic.
    tproxy_port_protect: true

    # Set non-zero value to enable pprof.
    pprof_port: 0

    # If not zero, traffic sent from dae will be set SO_MARK.
    so_mark_from_dae: 0

    # Log level: error, warn, info, debug, trace.
    log_level: info

    # Disable waiting for network before pulling subscriptions.
    disable_waiting_network: false

    # Enable fast redirect for local TCP connections.
    enable_local_tcp_fast_redirect: false

    ##### Interface and kernel options.

    # The LAN interface to bind. Use it if you want to proxy LAN.
    $lan_setting

    # The WAN interface to bind. Use it if you want to proxy localhost.
    $wan_setting

    # Automatically configure Linux kernel parameters like ip_forward and send_redirects.
    auto_config_kernel_parameter: true

    ##### Node connectivity check.
    tcp_check_url: 'http://cp.cloudflare.com,1.1.1.1,2606:4700:4700::1111'
    tcp_check_http_method: HEAD
    udp_check_dns: 'dns.google:53,8.8.8.8,2001:4860:4860::8888'

    check_interval: 30s
    check_tolerance: 50ms

    # Specify a fallback DNS resolver
    fallback_resolver: '8.8.8.8:53'

    ##### Connecting options.
    dial_mode: domain
    allow_insecure: false
    sniffing_timeout: 100ms
    tls_implementation: tls
    utls_imitate: chrome_auto
    mptcp: false

    # bandwidth control
    bandwidth_max_tx: '200 mbps'
    bandwidth_max_rx: '1 gbps'
}

subscription {
    kokk_sub: '$subscription_url'
}

node {
}

dns {
    ipversion_prefer: 4
    fixed_domain_ttl {
        ddns.example.org: 10
        api.steampowered.com: 3600
        test.example.org: 3600
    }
    upstream {
        alidns: 'udp://dns.alidns.com:53'
        googledns: 'tcp+udp://dns.google:53'
        google_doh: 'https://dns.google:443/dns-query'
        cloudflare_dot: 'tls://1.1.1.1:853'
    }
    routing {
        request {
            qname(geosite:cn) -> alidns
            qname(geosite:steam) -> google_doh
            fallback: cloudflare_dot
        }
        response {
            upstream(googledns, google_doh, cloudflare_dot) -> accept
            ip(geoip:private) && !qname(geosite:cn) -> google_doh
            fallback: accept
        }
    }
}

group {
    my_group {
        filter: subtag(kokk_sub)
        policy: min_moving_avg
    }

    high_speed {
        filter: subtag(kokk_sub) && name(keyword: 'Premium', 'VIP')
        policy: min_moving_avg
        tcp_check_url: 'http://cp.cloudflare.com,1.1.1.1'
        check_interval: 15s
        check_tolerance: 20ms
    }

    gaming {
        filter: subtag(kokk_sub) && name(keyword: 'Game', 'HK', 'SG')
        policy: min
        tcp_check_url: 'http://test.steampowered.com'
        udp_check_dns: 'dns.google:53,8.8.8.8'
        check_interval: 10s
        check_tolerance: 10ms
    }

    streaming {
        filter: subtag(kokk_sub) && name(keyword: 'Netflix', 'US', 'Streaming')
        policy: min_avg10
        tcp_check_url: 'http://netflix.com'
        check_interval: 30s
        check_tolerance: 50ms
    }

    steam {
        filter: subtag(kokk_sub) && !name(keyword: 'ExpireAt:')
        policy: min_moving_avg
        tcp_check_url: 'http://test.steampowered.com'
        tcp_check_http_method: HEAD
        udp_check_dns: 'dns.google:53,8.8.8.8,2001:4860:4860::8888'
        check_interval: 30s
        check_tolerance: 50ms
    }
}

routing {
    pname(NetworkManager, systemd-networkd) -> direct
    dip(224.0.0.0/3, 'ff00::/8') -> direct
    dip(geoip:private) -> direct

    l4proto(udp) && dport(443) -> block
    dip(geoip:cn) -> direct
    domain(geosite:cn) -> direct
    
    domain(geosite:steam) -> gaming
    domain(geosite:netflix, geosite:hbo, geosite:disney) -> streaming
    domain(geosite:google, geosite:youtube, geosite:github) -> high_speed

    fallback: my_group
}
EOF

    chmod 0600 "$CONFIG_FILE"
    echo -e "${GREEN}✅ 已生成高级配置文件：$CONFIG_FILE${NC}"

    if command -v dae >/dev/null 2>&1; then
        if dae validate -c "$CONFIG_FILE" >/dev/null 2>&1; then
            echo -e "${GREEN}配置文件验证通过${NC}"
        else
            echo -e "${RED}警告：配置验证失败，可能 dae 核心过旧或缺少 geo 库。${NC}"
        fi
    fi
}

# ================= 核心功能：一键无损更新 dae 核心 =================
upgrade_dae_core() {
    echo -e "\n${CYAN}--- 🔄 无损更新 dae 核心 ---${NC}"
    
    local arch=$(uname -m)
    local target_arch=""
    case "$arch" in
        x86_64) target_arch="x86_64" ;;
        aarch64|arm64) target_arch="arm64" ;;
        *) echo -e "${RED}自动更新暂不支持此架构: $arch${NC}"; return 1 ;;
    esac

    echo -e "${YELLOW}正在拉取最新版本信息...${NC}"
    local latest_version=$(curl -s "https://api.github.com/repos/daeuniverse/dae/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [ -z "$latest_version" ]; then
        echo -e "${RED}无法获取最新版本信息，请检查网络。${NC}"
        return 1
    fi

    local current_version="未知"
    if command -v dae >/dev/null 2>&1; then
        current_version=$(dae --version 2>/dev/null | awk '{print $3}')
    fi
    
    echo -e "当前版本: ${GREEN}${current_version}${NC}"
    echo -e "最新版本: ${GREEN}${latest_version}${NC}"

    if [ "v${current_version}" = "${latest_version}" ] || [ "${current_version}" = "${latest_version}" ]; then
        echo -e "${GREEN}当前已是最新版本，无需更新！${NC}"
        return 0
    fi

    local download_url="https://github.com/daeuniverse/dae/releases/download/${latest_version}/dae-linux-${target_arch}.zip"
    
    echo -e "${YELLOW}⬇️ 正在下载最新核心文件...${NC}"
    curl -L -o /tmp/dae-update.zip "$download_url"
    if [ $? -ne 0 ]; then
        echo -e "${RED}下载失败，请稍后重试！${NC}"
        rm -f /tmp/dae-update.zip
        return 1
    fi

    echo -e "${YELLOW}正在停止 dae 服务...${NC}"
    manage_service "stop"

    echo -e "${YELLOW}正在替换核心可执行文件...${NC}"
    unzip -o /tmp/dae-update.zip dae -d /tmp/ >/dev/null 2>&1
    if [ -f /tmp/dae ]; then
        local dae_path=$(command -v dae || echo "/usr/bin/dae")
        mv /tmp/dae "$dae_path"
        chmod +x "$dae_path"
        echo -e "${GREEN}✅ 核心文件替换成功！${NC}"
    else
        echo -e "${RED}解压失败！${NC}"
        rm -f /tmp/dae-update.zip
        return 1
    fi

    rm -f /tmp/dae-update.zip
    echo -e "${YELLOW}正在重启 dae 服务生效...${NC}"
    manage_service "start"
    echo -e "${GREEN}🎉 dae 已成功更新至 $latest_version ！(配置已完美保留)${NC}"
}

# ================= 还原：GEO 数据管理与计划任务 =================
create_geo_update_script() {
    mkdir -p "$(dirname "$UPDATE_GEO_SCRIPT")"
    cat << EOF > "$UPDATE_GEO_SCRIPT"
#!/bin/sh
# 更新 dae 的 geoip.dat 和 geosite.dat
mkdir -p "$GEO_DIR"

echo "正在下载 geoip.dat..."
curl -L -o "$GEO_DIR/geoip.dat" "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
if [ \$? -eq 0 ]; then echo "geoip.dat 下载成功"; else echo "geoip.dat 下载失败"; exit 1; fi

echo "正在下载 geosite.dat..."
curl -L -o "$GEO_DIR/geosite.dat" "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
if [ \$? -eq 0 ]; then echo "geosite.dat 下载成功"; else echo "geosite.dat 下载失败"; exit 1; fi

chmod 644 "$GEO_DIR/geoip.dat" "$GEO_DIR/geosite.dat"

# 跨平台重启 dae
if command -v systemctl >/dev/null 2>&1 && pidof systemd >/dev/null 2>&1; then
    systemctl restart dae
else
    /etc/init.d/dae restart 2>/dev/null || killall dae
fi
echo "dae 已重启，应用新 geo 数据"
EOF

    chmod +x "$UPDATE_GEO_SCRIPT"
    echo -e "${GREEN}已创建 GEO 更新脚本：$UPDATE_GEO_SCRIPT${NC}"
}

update_geo_data() {
    if [ ! -f "$UPDATE_GEO_SCRIPT" ]; then
        echo -e "${RED}未找到 geo 更新脚本，正在创建...${NC}"
        create_geo_update_script
    fi
    "$UPDATE_GEO_SCRIPT"
}

set_geo_update_schedule() {
    echo "请选择更新频率："
    echo "1) 每日"
    echo "2) 每周（星期一）"
    echo "3) 每月（1日）"
    echo "4) 自定义（输入 cron 表达式）"
    echo -n "请输入选项 [1-4]："
    read freq
    case $freq in
        1) cron_schedule="0 0 * * *" ;;
        2) cron_schedule="0 0 * * 1" ;;
        3) cron_schedule="0 0 1 * *" ;;
        4)
            echo "请输入 cron 表达式（例如 '0 0 * * 1' 表示每周一）："
            read cron_schedule
            ;;
        *)
            echo -e "${RED}无效选项，使用默认（每周一）${NC}"
            cron_schedule="0 0 * * 1"
            ;;
    esac

    crontab -l > /tmp/crontab.tmp 2>/dev/null
    sed -i "/update-geo.sh/d" /tmp/crontab.tmp
    echo "$cron_schedule $UPDATE_GEO_SCRIPT" >> /tmp/crontab.tmp
    crontab /tmp/crontab.tmp
    rm /tmp/crontab.tmp
    
    # 尝试跨平台重启 cron
    if [ "$SERVICE_MGR" = "systemd" ]; then
        systemctl restart cron 2>/dev/null || systemctl restart crond 2>/dev/null
    else
        /etc/init.d/cron restart 2>/dev/null
    fi
    
    echo -e "${GREEN}geo 更新计划已成功设置：$cron_schedule${NC}"
}

# ================= 还原：服务管理与旁路由指导 =================
manage_auto_start() {
    echo "1) 启用自启动"
    echo "2) 禁用自启动"
    echo -n "请输入选项 [1-2]："
    read choice
    case $choice in
        1) manage_service "enable"; echo -e "${GREEN}已启用自启动${NC}" ;;
        2) manage_service "disable"; echo -e "${GREEN}已禁用自启动${NC}" ;;
        *) echo -e "${RED}无效选项${NC}" ;;
    esac
}

service_control() {
    echo "1) 启动 dae"
    echo "2) 停止 dae"
    echo "3) 重启 dae"
    echo "4) 查看状态"
    echo -n "请输入选项 [1-4]："
    read choice
    case $choice in
        1) manage_service "start"; echo -e "${GREEN}dae 已启动${NC}" ;;
        2) manage_service "stop"; echo -e "${GREEN}dae 已停止${NC}" ;;
        3) manage_service "restart"; echo -e "${GREEN}dae 已重启${NC}" ;;
        4) manage_service "status" ;;
        *) echo -e "${RED}无效选项${NC}" ;;
    esac
}

display_side_router_instructions() {
    if [ "$(detect_router_mode)" = "side" ]; then
        echo -e "\n${YELLOW}检测到旁路由模式，请在主路由上配置以下内容：${NC}"
        echo "1. 设置 DNS 服务器为 $LAN_IP"
        echo "   uci set dhcp.@dnsmasq[0].server='$LAN_IP'"
        echo "   uci commit dhcp"
        echo "   /etc/init.d/dnsmasq restart"
        echo "2. 添加静态路由，将流量转发到 $LAN_IP"
        echo "   uci add network route"
        echo "   uci set network.@route[-1].interface='lan'"
        echo "   uci set network.@route[-1].target='0.0.0.0'"
        echo "   uci set network.@route[-1].netmask='0.0.0.0'"
        echo "   uci set network.@route[-1].gateway='$LAN_IP'"
        echo "   uci commit network"
        echo "   /etc/init.d/network reload"
        echo "3. 配置 iptables 实现透明代理"
        echo "   ipset -! create dae_bypass hash:ip"
        echo "   iptables -t mangle -N DAE"
        echo "   iptables -t mangle -A DAE -d 192.168.0.0/16 -j RETURN"
        echo "   iptables -t mangle -A DAE -d 10.0.0.0/8 -j RETURN"
        echo "   iptables -t mangle -A DAE -d 172.16.0.0/12 -j RETURN"
        echo "   iptables -t mangle -A DAE -m set --match-set dae_bypass dst -j RETURN"
        echo "   iptables -t mangle -A DAE -p tcp -j TPROXY --on-port 12345 --on-ip $LAN_IP --tproxy-mark 0x1"
        echo "   iptables -t mangle -A DAE -p udp -j TPROXY --on-port 12345 --on-ip $LAN_IP --tproxy-mark 0x1"
        echo "   iptables -t mangle -A PREROUTING -i br-lan -p tcp -j DAE"
        echo "   iptables -t mangle -A PREROUTING -i br-lan -p udp -j DAE"
        echo "4. 保存 iptables 规则"
        echo "   iptables-save > /etc/iptables.rules"
    fi
}

# ================= 脚本主入口 =================
main_menu() {
    detect_system_env
    check_dependencies
    get_network_info
    cleanup_sing_box
    
    while true; do
        echo ""
        echo -e "${CYAN}===== dae 全平台配置管家 =====${NC}"
        echo -e "当前系统环境: ${YELLOW}${SERVICE_MGR} (${PKG_MANAGER})${NC}"
        echo -e "网络接口侦测: ${GREEN}${LAN_IFACE} (${LAN_IP})${NC}"
        echo "---------------------------------"
        echo "1) 配置 dae（设置订阅地址并生成高级分流）"
        echo "2) 无损更新 dae 核心 ${YELLOW}[完美保留配置]${NC}"
        echo "3) 立即更新 geo 数据"
        echo "4) 设置 geo 数据定时更新计划"
        echo "5) 管理服务开机自启动"
        echo "6) 启停控制与运行状态"
        echo "7) 退出"
        echo -n "请输入选项 [1-7]："
        read choice
        case $choice in
            1)
                echo -n "请输入订阅地址（例如 https://example.com/sub）："
                read SUBSCRIPTION_URL
                if validate_subscription "$SUBSCRIPTION_URL"; then
                    router_mode=$(detect_router_mode)
                    echo -e "${YELLOW}检测到 $router_mode 路由模式${NC}"
                    generate_dae_config "$SUBSCRIPTION_URL" "$router_mode"
                    display_side_router_instructions
                    
                    echo -e "${YELLOW}配置生成完毕，正在重启服务...${NC}"
                    manage_service "restart"
                else
                    echo -e "${RED}订阅地址格式无效，请确保以 http:// 或 https:// 开头${NC}"
                fi
                ;;
            2)
                upgrade_dae_core
                ;;
            3)
                update_geo_data
                ;;
            4)
                set_geo_update_schedule
                ;;
            5)
                manage_auto_start
                ;;
            6)
                service_control
                ;;
            7)
                echo -e "${GREEN}退出程序...${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选项${NC}"
                ;;
        esac
    done
}

echo -e "${GREEN}启动 dae 设置脚本...${NC}"
main_menu
