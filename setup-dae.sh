#!/bin/sh
# 一键设置 dae 的 Bash 脚本，适配 OpenWrt 主路由和旁路由
# 功能：配置 dae、更新 geo 数据、管理服务、中文菜单驱动
# 避免硬编码，动态获取 IP、网段和接口，兼容多设备

CONFIG_FILE="/etc/dae/config.dae"
GEO_DIR="/usr/share/dae"
PERSIST_DIR="/etc/dae/persist.d"
UPDATE_GEO_SCRIPT="/etc/dae/update-geo.sh"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 检查 root 权限
if [ "$(id -u)" != "0" ]; then
    echo "${RED}请以 root 权限运行此脚本${NC}"
    exit 1
fi

# 检查依赖
check_dependencies() {
    if ! command -v ipcalc.sh >/dev/null 2>&1; then
        echo "${YELLOW}安装 ipcalc.sh 依赖...${NC}"
        opkg update && opkg install ipcalc
        if [ $? -ne 0 ]; then
            echo "${RED}无法安装 ipcalc.sh，请检查软件源${NC}"
            exit 1
        fi
    fi
}

# 动态获取 LAN 接口、IP 和网段
get_network_info() {
    LAN_IFACE=$(uci get network.lan.ifname 2>/dev/null || echo "br-lan")
    LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null || ip addr show "$LAN_IFACE" | grep -o "inet [0-9.]\+" | cut -d' ' -f2)
    LAN_NETMASK=$(uci get network.lan.netmask 2>/dev/null || echo "255.255.255.0")
    WAN_IFACE=$(uci get network.wan.ifname 2>/dev/null || echo "wan")
    if [ -z "$LAN_IP" ]; then
        echo "${RED}无法获取 LAN IP，请检查网络配置${NC}"
        exit 1
    fi
    # 计算网段
    LAN_CIDR=$(ipcalc.sh "$LAN_IP" "$LAN_NETMASK" | grep NETWORK | cut -d= -f2)/24
}

# 检测主路由或旁路由
detect_router_mode() {
    if ip link show "$WAN_IFACE" >/dev/null 2>&1 && ip addr show "$WAN_IFACE" | grep -q "inet "; then
        echo "main"
    elif ip route | grep -q "^default via"; then
        echo "side"
    else
        echo "main"
    fi
}

# 验证订阅地址
validate_subscription() {
    local url=$1
    if curl -s -I "$url" | grep -q "200 OK"; then
        return 0
    else
        return 1
    fi
}

# 检查并清理 sing-box
cleanup_sing_box() {
    if pgrep sing-box >/dev/null; then
        echo "${YELLOW}检测到 sing-box 正在运行，正在停止...${NC}"
        /etc/init.d/sing-box stop 2>/dev/null
        killall sing-box 2>/dev/null
    fi
    if opkg list-installed | grep -q sing-box; then
        echo "${YELLOW}卸载 sing-box 以避免冲突...${NC}"
        opkg remove sing-box
    fi
}

# 生成 dae 配置文件
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
    cat << EOF > "$CONFIG_FILE"
global {
    ##### Software options.

    # tproxy port to listen on. It is NOT a HTTP/SOCKS port, and is just used by eBPF program.
    # In normal case, you do not need to use it.
    tproxy_port: 12345

    # Set it true to protect tproxy port from unsolicited traffic. Set it false to allow users to use self-managed
    # iptables tproxy rules.
    tproxy_port_protect: true

    # Set non-zero value to enable pprof.
    pprof_port: 0

    # If not zero, traffic sent from dae will be set SO_MARK. It is useful to avoid traffic loop with iptables tproxy
    # rules.
    so_mark_from_dae: 0

    # Log level: error, warn, info, debug, trace.
    log_level: info

    # Disable waiting for network before pulling subscriptions.
    disable_waiting_network: false

    # Enable fast redirect for local TCP connections. There is a known kernel issue that breaks certain clients/proxies, such as nadoo/glider. Users may enable this experimental option at their own risks.
    enable_local_tcp_fast_redirect: false

    ##### Interface and kernel options.

    # The LAN interface to bind. Use it if you want to proxy LAN.
    # Multiple interfaces split by ",".
    $lan_setting

    # The WAN interface to bind. Use it if you want to proxy localhost.
    # Multiple interfaces split by ",". Use "auto" to auto detect.
    $wan_setting

    # Automatically configure Linux kernel parameters like ip_forward and send_redirects. Check out
    # https://github.com/daeuniverse/dae/blob/main/docs/en/user-guide/kernel-parameters.md to see what will dae do.
    auto_config_kernel_parameter: true

    ##### Node connectivity check.
    # These options, as defaults, are effective when no definition is given in the group.

    # Host of URL should have both IPv4 and IPv6 if you have double stack in local.
    # First is URL, others are IP addresses if given.
    # Considering traffic consumption, it is recommended to choose a site with anycast IP and less response.
    #tcp_check_url: 'http://cp.cloudflare.com'
    tcp_check_url: 'http://cp.cloudflare.com,1.1.1.1,2606:4700:4700::1111'

    # The HTTP request method to `tcp_check_url`. Use 'HEAD' by default because some server implementations bypass
    # accounting for this kind of traffic.
    tcp_check_http_method: HEAD

    # This DNS will be used to check UDP connectivity of nodes. And if dns_upstream below contains tcp, it also be used to check
    # TCP DNS connectivity of nodes.
    # First is URL, others are IP addresses if given.
    # This DNS should have both IPv4 and IPv6 if you have double stack in local.
    #udp_check_dns: 'dns.google:53'
    udp_check_dns: 'dns.google:53,8.8.8.8,2001:4860:4860::8888'

    check_interval: 30s

    # Group will switch node only when new_latency <= old_latency - tolerance.
    check_tolerance: 50ms

    # Specify a fallback DNS resolver to be used when DNS resolution using resolv.conf fails. 
    # This ensures DNS resolution continues to work even when the system's default DNS servers are unavailable or not responding properly.
    fallback_resolver: '8.8.8.8:53'

    ##### Connecting options.

    # Optional values of dial_mode are:
    # 1. "ip". Dial proxy using the IP from DNS directly. This allows your ipv4, ipv6 to choose the optimal path
    #       respectively, and makes the IP version requested by the application meet expectations. For example, if you
    #       use curl -4 ip.sb, you will request IPv4 via proxy and get a IPv4 echo. And curl -6 ip.sb will request IPv6.
    #       This may solve some wierd full-cone problem if your are be your node support that. Sniffing will be disabled
    #       in this mode.
    # 2. "domain". Dial proxy using the domain from sniffing. This will relieve DNS pollution problem to a great extent
    #       if have impure DNS environment. Generally, this mode brings faster proxy response time because proxy will
    #       re-resolve the domain in remote, thus get better IP result to connect. This policy does not impact routing.
    #       That is to say, domain rewrite will be after traffic split of routing and dae will not re-route it.
    # 3. "domain+". Based on domain mode but do not check the reality of sniffed domain. It is useful for users whose
    #       DNS requests do not go through dae but want faster proxy response time. Notice that, if DNS requests do not
    #       go through dae, dae cannot split traffic by domain.
    # 4. "domain++". Based on domain+ mode but force to re-route traffic using sniffed domain to partially recover
    #       domain based traffic split ability. It doesn't work for direct traffic and consumes more CPU resources.
    dial_mode: domain

    # Allow insecure TLS certificates. It is not recommended to turn it on unless you have to.
    allow_insecure: false

    # Timeout to waiting for first data sending for sniffing. It is always 0 if dial_mode is ip. Set it higher is useful
    # in high latency LAN network.
    sniffing_timeout: 100ms

    # TLS implementation. tls is to use Go's crypto/tls. utls is to use uTLS, which can imitate browser's Client Hello.
    tls_implementation: tls

    # The Client Hello ID for uTLS to imitate. This takes effect only if tls_implementation is utls.
    # See more: https://github.com/daeuniverse/dae/blob/331fa23c16/component/outbound/transport/tls/utls.go#L17
    utls_imitate: chrome_auto

    # Multipath TCP (MPTCP) support. If is true, dae will try to use MPTCP to connect all nodes, but it will only take
    # effects when the node supports MPTCP. It can use for load balance and failover to multiple interfaces and IPs.
    mptcp: false

    # The maximum bandwidth for accessing the Internet. It is useful for some specific protocols (e.g., Hysteria2),
    # which will perform better with bandwith information provided. The unit can be b, kb, mb, gb, tb or bytes per second.
    # supported formats: https://v2.hysteria.network/docs/advanced/Full-Client-Config/#bandwidth
    bandwidth_max_tx: '200 mbps'
    bandwidth_max_rx: '1 gbps'
}

# Subscriptions defined here will be resolved as nodes and merged as a part of the global node pool.
# Support to give the subscription a tag, and filter nodes from a given subscription in the group section.
subscription {
    # Add your subscription links here.
    kokk_sub: 'https-file://$subscription_url'
}

# Nodes defined here will be merged as a part of the global node pool.
node {
    # Add your node links here.
    # Support socks5, http, https, ss, ssr, vmess, vless, trojan, tuic, juicity, hysteria2, etc.
    # Full support list: https://github.com/daeuniverse/dae/blob/main/docs/en/proxy-protocols.md
}

# See https://github.com/daeuniverse/dae/blob/main/docs/en/configuration/dns.md for full examples.
dns {
    # For example, if ipversion_prefer is 4 and the domain name has both type A and type AAAA records, the dae will only
    # respond to type A queries and response empty answer to type AAAA queries.
    ipversion_prefer: 4

    # Give a fixed ttl for domains. Zero means that dae will request to upstream every time and not cache DNS results
    # for these domains.
    fixed_domain_ttl {
        ddns.example.org: 10
        api.steampowered.com: 3600
        test.example.org: 3600
    }

    upstream {
        # Value can be scheme://host:port, where the scheme can be tcp/udp/tcp+udp/h3/http3/quic/https/tls.
        # If the protocol is h3/http3/https, it supports setting a custom path, that is, the format can be "protocol://host:port/custom path".
        # If host is a domain and has both IPv4 and IPv6 record, dae will automatically choose
        # IPv4 or IPv6 to use according to group policy (such as min latency policy).
        # Please make sure DNS traffic will go through and be forwarded by dae, which is REQUIRED for domain routing.
        # If dial_mode is "ip", the upstream DNS answer SHOULD NOT be polluted, so domestic public DNS is not recommended.
        alidns: 'udp://dns.alidns.com:53'
        googledns: 'tcp+udp://dns.google:53'
        google_doh: 'https://dns.google:443/dns-query'
        cloudflare_dot: 'tls://1.1.1.1:853'
    }
    routing {
        # According to the request of dns query, decide to use which DNS upstream.
        # Match rules from top to bottom.
        request {
            # Lookup China mainland domains using alidns, otherwise googledns.
            qname(geosite:cn) -> alidns
            qname(geosite:steam) -> google_doh
            fallback: cloudflare_dot
        }
        # According to the response of dns query, decide to accept or re-lookup using another DNS upstream.
        # Match rules from top to bottom.
        response {
            # Trusted upstream. Always accept its result.
            upstream(googledns, google_doh, cloudflare_dot) -> accept
            # Possibly polluted, re-lookup using googledns.
            ip(geoip:private) && !qname(geosite:cn) -> google_doh
            # fallback is also called default.
            fallback: accept
        }
    }
}

# Node group (outbound).
group {
    my_group {
        # No filter. Use all nodes.
        filter: subtag(kokk_sub)
        # Select the node with min moving average of latencies from the group for every connection.
        policy: min_moving_avg
    }

    high_speed {
        filter: subtag(kokk_sub) && name(keyword: 'Premium', 'VIP')
        # Select the node with min moving average of latencies from the group for every connection.
        policy: min_moving_avg
        tcp_check_url: 'http://cp.cloudflare.com,1.1.1.1'
        check_interval: 15s
        check_tolerance: 20ms
    }

    gaming {
        filter: subtag(kokk_sub) && name(keyword: 'Game', 'HK', 'SG')
        # Select the node with min last latency from the group for every connection.
        policy: min
        tcp_check_url: 'http://test.steampowered.com'
        udp_check_dns: 'dns.google:53,8.8.8.8'
        check_interval: 10s
        check_tolerance: 10ms
    }

    streaming {
        filter: subtag(kokk_sub) && name(keyword: 'Netflix', 'US', 'Streaming')
        # Select the node with min average of the last 10 latencies from the group for every connection.
        policy: min_avg10
        tcp_check_url: 'http://netflix.com'
        check_interval: 30s
        check_tolerance: 50ms
    }

    steam {
        filter: subtag(kokk_sub) && !name(keyword: 'ExpireAt:')
        # Select the node with min moving average of latencies from the group for every connection.
        policy: min_moving_avg
        # Override tcp_check_url in global.
        tcp_check_url: 'http://test.steampowered.com'
        # Override tcp_check_http_method in global
        tcp_check_http_method: HEAD
        # Override udp_check_dns in global
        udp_check_dns: 'dns.google:53,8.8.8.8,2001:4860:4860::8888'
        # Override check_interval in global
        check_interval: 30s
        # Override check_tolerance in global
        check_tolerance: 50ms
    }
}

# See https://github.com/daeuniverse/dae/blob/main/docs/en/configuration/routing.md for full examples.
routing {
    ### Preset rules.

    # Network managers in localhost should be direct to avoid false negative network connectivity check when binding to
    # WAN.
    pname(NetworkManager, systemd-networkd) -> direct

    # Put it in the front to prevent broadcast, multicast and other packets that should be sent to the LAN from being
    # forwarded by the proxy.
    # "dip" means destination IP.
    dip(224.0.0.0/3, 'ff00::/8') -> direct

    # This line allows you to access private addresses directly instead of via your proxy. If you really want to access
    # private addresses in your proxy host network, modify the below line.
    dip(geoip:private) -> direct

    ### Write your rules below.

    # Disable h3 because it usually consumes too much cpu/mem resources.
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
    echo "${GREEN}已生成 $CONFIG_FILE${NC}"

    if dae validate -c "$CONFIG_FILE"; then
        echo "${GREEN}配置文件验证通过${NC}"
    else
        echo "${RED}配置文件验证失败${NC}"
        return 1
    fi
}

# 创建 geo 更新脚本
create_geo_update_script() {
    mkdir -p "$(dirname "$UPDATE_GEO_SCRIPT")"
    cat << EOF > "$UPDATE_GEO_SCRIPT"
#!/bin/sh
# 更新 dae 的 geoip.dat 和 geosite.dat
# 存储至 $GEO_DIR

mkdir -p "$GEO_DIR"

echo "正在下载 geoip.dat..."
curl -L -o "$GEO_DIR/geoip.dat" "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
if [ \$? -eq 0 ]; then
    echo "geoip.dat 下载成功"
else
    echo "geoip.dat 下载失败"
    exit 1
fi

echo "正在下载 geosite.dat..."
curl -L -o "$GEO_DIR/geosite.dat" "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
if [ \$? -eq 0 ]; then
    echo "geosite.dat 下载成功"
else
    echo "geosite.dat 下载失败"
    exit 1
fi

chmod 644 "$GEO_DIR/geoip.dat" "$GEO_DIR/geosite.dat"

/etc/init.d/dae restart
echo "dae 已重启，应用新 geo 数据"
EOF

    chmod +x "$UPDATE_GEO_SCRIPT"
    echo "${GREEN}已创建 $UPDATE_GEO_SCRIPT${NC}"
}

# 更新 geo 数据
update_geo_data() {
    if [ -f "$UPDATE_GEO_SCRIPT" ]; then
        "$UPDATE_GEO_SCRIPT"
    else
        echo "${RED}未找到 geo 更新脚本，正在创建...${NC}"
        create_geo_update_script
        "$UPDATE_GEO_SCRIPT"
    fi
}

# 设置 geo 更新计划
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
            echo "${RED}无效选项，使用默认（每周一）${NC}"
            cron_schedule="0 0 * * 1"
            ;;
    esac

    crontab -l > /tmp/crontab.tmp 2>/dev/null
    sed -i "/update-geo.sh/d" /tmp/crontab.tmp
    echo "$cron_schedule $UPDATE_GEO_SCRIPT" >> /tmp/crontab.tmp
    crontab /tmp/crontab.tmp
    rm /tmp/crontab.tmp
    echo "${GREEN}geo 更新计划已设置：$cron_schedule${NC}"
}

# 管理自启动
manage_auto_start() {
    echo "1) 启用自启动"
    echo "2) 禁用自启动"
    echo -n "请输入选项 [1-2]："
    read choice
    case $choice in
        1)
            /etc/init.d/dae enable
            echo "${GREEN}已启用自启动${NC}"
            ;;
        2)
            /etc/init.d/dae disable
            echo "${GREEN}已禁用自启动${NC}"
            ;;
        *)
            echo "${RED}无效选项${NC}"
            ;;
    esac
}

# 服务控制
service_control() {
    echo "1) 启动 dae"
    echo "2) 停止 dae"
    echo "3) 重启 dae"
    echo "4) 查看状态"
    echo -n "请输入选项 [1-4]："
    read choice
    case $choice in
        1)
            /etc/init.d/dae start
            echo "${GREEN}dae 已启动${NC}"
            ;;
        2)
            /etc/init.d/dae stop
            echo "${GREEN}dae 已停止${NC}"
            ;;
        3)
            /etc/init.d/dae restart
            echo "${GREEN}dae 已重启${NC}"
            ;;
        4)
            if pgrep dae >/dev/null; then
                echo "${GREEN}dae 正在运行${NC}"
            else
                echo "${YELLOW}dae 未运行${NC}"
            fi
            echo "近期日志："
            logread | grep dae | tail -n 10
            ;;
        *)
            echo "${RED}无效选项${NC}"
            ;;
    esac
}

# 显示旁路由主路由配置说明
display_side_router_instructions() {
    if [ "$(detect_router_mode)" = "side" ]; then
        echo "${YELLOW}检测到旁路由模式，请在主路由上配置以下内容：${NC}"
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

# 主菜单
main_menu() {
    check_dependencies
    get_network_info
    cleanup_sing_box
    while true; do
        echo ""
        echo "===== dae 设置菜单 ====="
        echo "1) 配置 dae（设置订阅地址）"
        echo "2) 立即更新 geo 数据"
        echo "3) 设置 geo 数据更新计划"
        echo "4) 管理自启动"
        echo "5) 服务控制（启动/停止/状态）"
        echo "6) 退出"
        echo -n "请输入选项 [1-6]："
        read choice
        case $choice in
            1)
                echo -n "请输入订阅地址（例如 http://example.com/sub）："
                read SUBSCRIPTION_URL
                if validate_subscription "$SUBSCRIPTION_URL"; then
                    router_mode=$(detect_router_mode)
                    echo "${YELLOW}检测到 $router_mode 路由模式${NC}"
                    generate_dae_config "$SUBSCRIPTION_URL" "$router_mode"
                    display_side_router_instructions
                else
                    echo "${RED}订阅地址无效${NC}"
                fi
                ;;
            2)
                update_geo_data
                ;;
            3)
                set_geo_update_schedule
                ;;
            4)
                manage_auto_start
                ;;
            5)
                service_control
                ;;
            6)
                echo "${GREEN}退出程序...${NC}"
                exit 0
                ;;
            *)
                echo "${RED}无效选项${NC}"
                ;;
        esac
    done
}

# 主执行
echo "${GREEN}启动 dae 设置脚本...${NC}"
main_menu
