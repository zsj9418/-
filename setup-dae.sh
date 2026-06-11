#!/bin/sh

# 核心路径定义
CONFIG_FILE="/etc/dae/config.dae"
GEO_DIR="/usr/share/dae"
PERSIST_DIR="/etc/dae/persist.d"
UPDATE_GEO_SCRIPT="/etc/dae/update-geo.sh"
ENV_FILE="$HOME/.dae_env"
LOG_FILE="/var/log/dae.log"
LOG_SIZE_LIMIT=$((1 * 1024 * 1024)) # 1MB

# 严格遵循 POSIX 标准的颜色转义定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# 检查 root 权限
if [ "$(id -u)" != "0" ]; then
    printf "${RED}[错误] 请以 root 权限运行此脚本${NC}\n"
    exit 1
fi

# ==================== 环境变量与通知组件 ====================

load_env() {
    if [ -f "$ENV_FILE" ]; then
        . "$ENV_FILE"
    fi
}

save_env() {
    local key=$1
    local value=$2
    if [ ! -f "$ENV_FILE" ]; then
        touch "$ENV_FILE"
        chmod 0600 "$ENV_FILE"
    fi
    if grep -q "^$key=" "$ENV_FILE"; then
        sed -i "s|^$key=.*|$key=\"$value\"|" "$ENV_FILE"
    else
        echo "$key=\"$value\"" >> "$ENV_FILE"
    fi
}

send_wechat_notification() {
    load_env
    if [ -z "$WECHAT_WEBHOOK" ]; then
        return 0
    fi
    local msg=$1
    printf "${BLUE}[通知] 正在向企业微信发送即时运维报告...${NC}\n"
    curl -s -X POST "$WECHAT_WEBHOOK" \
       -H 'Content-Type: application/json' \
       -d "{
            \"msgtype\": \"text\",
            \"text\": {
                \"content\": \"【大鹅云助手】运维状态更新\n报告时间：\$(date '+%Y-%m-%d %H:%M:%S')\n事件详情：$msg\"
            }
       }" >/dev/null
}

check_log_size() {
    if [ -f "$LOG_FILE" ]; then
        local log_size
        log_size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$log_size" -gt "$LOG_SIZE_LIMIT" ]; then
            printf "${YELLOW}[系统] 日志文件超过1MB，正在自动轮转清空...${NC}\n"
            > "$LOG_FILE"
        fi
    fi
}

clean_network_resources() {
    printf "${YELLOW}[清理] 正在排查并清理现有网络挂载资源以防冲突...${NC}\n"
    ip rule del fwmark 114514 2>/dev/null
    ip route flush table 114514 2>/dev/null
    ip link delete dae 2>/dev/null
    if pgrep dae >/dev/null 2>&1; then
        printf "${YELLOW}[清理] 检测到残留 dae 后台进程，正在尝试优雅终止...${NC}\n"
        killall dae 2>/dev/null
        sleep 1
    fi
}

# ==================== 智能识别与跨平台依赖 ====================

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

    if command -v systemctl >/dev/null 2>&1 && pidof systemd >/dev/null 2>&1; then
        SERVICE_MGR="systemd"
    else
        SERVICE_MGR="initd"
    fi
}

check_dependencies() {
    for dep in curl unzip ip pidof; do
        if ! command -v $dep >/dev/null 2>&1; then
            printf "${YELLOW}缺少依赖 $dep，正在尝试通过 $PKG_MANAGER 安装...${NC}\n"
            if [ -n "$INSTALL_CMD" ]; then
                local pkg_name=$dep
                [ "$dep" = "ip" ] && pkg_name="iproute2"
                [ "$dep" = "pidof" ] && [ "$PKG_MANAGER" = "opkg" ] && pkg_name="procps-ng-pidof"
                $INSTALL_CMD $pkg_name >/dev/null 2>&1
            fi
        fi
    done
}

check_ebpf_support() {
    printf "${BLUE}[体检] 正在诊断系统底层内核 eBPF 支持特征...${NC}\n"
    KERNEL_VER=$(uname -r)
    local main_ver sub_ver
    main_ver=$(echo "$KERNEL_VER" | cut -d. -f1)
    sub_ver=$(echo "$KERNEL_VER" | cut -d. -f2)
    printf "${CYAN}- 当前系统内核版本: $KERNEL_VER${NC}\n"
    
    if [ "$main_ver" -lt 5 ] || { [ "$main_ver" -eq 5 ] && [ "$sub_ver" -lt 17 ]; }; then
        printf "${RED}[警告] 您的系统内核低于 dae 官方推荐的最低底线 5.17！${NC}\n"
        printf "是否仍要强行冒险继续？(y/n, 默认n): "
        read -r force_kernel
        if [ "$force_kernel" != "y" ] && [ "$force_kernel" != "Y" ]; then
            printf "${RED}[终止] 请升级系统固件后再试。${NC}\n"
            exit 1
        fi
    fi
    return 0
}

# ==================== 网络接口侦测 ====================

get_network_info() {
    DEFAULT_IFACE=$(ip route 2>/dev/null | grep default | awk '{print $5}' | head -n1)
    
    if [ -n "$DEFAULT_IFACE" ]; then
        LAN_IFACE="$DEFAULT_IFACE"
        WAN_IFACE="$DEFAULT_IFACE"
        LAN_CIDR=$(ip addr show "$LAN_IFACE" 2>/dev/null | awk '/inet / {print $2}' | head -n1)
        LAN_IP=$(echo "$LAN_CIDR" | cut -d/ -f1)
    else
        if command -v uci >/dev/null 2>&1; then
            LAN_IFACE=$(uci get network.lan.device 2>/dev/null || uci get network.lan.ifname 2>/dev/null || echo "br-lan")
            LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null || ip addr show "$LAN_IFACE" 2>/dev/null | grep -o "inet [0-9.]\+" | cut -d' ' -f2)
            WAN_IFACE=$(uci get network.wan.device 2>/dev/null || uci get network.wan.ifname 2>/dev/null || echo "wan")
            LAN_CIDR="$LAN_IP/24"
        else
            printf "${RED}无法自动获取网络接口信息，请检查网络配置！${NC}\n"
            exit 1
        fi
    fi

    if [ -z "$LAN_IP" ]; then
        printf "${RED}获取 IP 失败，网络拓扑异常！${NC}\n"
        exit 1
    fi
}

smart_interface_sniffer() {
    printf "${BLUE}[嗅探] 正在分析物理网络拓扑接口...${NC}\n"
    local all_interfaces
    all_interfaces=$(ip -o link show | awk -F': ' '{print $2}' | grep -vE 'lo|docker|veth|br-|dae|gretun|sit|tun')
    
    printf "${YELLOW}--- 发现的可用局域网卡候选列表 ---${NC}\n"
    local count=1
    for iface in $all_interfaces; do
        local iface_ip
        iface_ip=$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1)
        printf "$count) 网卡名称: ${GREEN}%s${NC} [当前IP: ${CYAN}%s${NC}]\n" "$iface" "${iface_ip:-未分配}"
        count=$((count + 1))
    done
    
    printf "${YELLOW}请输入数字选择局域网接口 (LAN口)。直接敲回车将全选接管(更稳妥):${NC}\n"
    read -r user_iface_choice
    
    if [ -z "$user_iface_choice" ]; then
        local merged_ifaces=""
        for iface in $all_interfaces; do
            if [ -z "$merged_ifaces" ]; then
                merged_ifaces="$iface"
            else
                merged_ifaces="$merged_ifaces, $iface"
            fi
        done
        LAN_IFACE_SETTING="lan_interface: $merged_ifaces"
        printf "${GREEN}[广撒网策略] 已绑定全部物理网口: %s${NC}\n" "$merged_ifaces"
    else
        local selected_iface=""
        local idx=1
        for iface in $all_interfaces; do
            if [ "$idx" -eq "$user_iface_choice" ]; then
                selected_iface=$iface
                break
            fi
            idx=$((idx + 1))
        done
        if [ -n "$selected_iface" ]; then
            LAN_IFACE_SETTING="lan_interface: $selected_iface"
            printf "${GREEN}[精准绑定] 已锁定接口: %s${NC}\n" "$selected_iface"
        else
            LAN_IFACE_SETTING="lan_interface: $LAN_IFACE"
            printf "${RED}[选择越界] 自动 fallback 缺省选用: %s${NC}\n" "$LAN_IFACE"
        fi
    fi
}

detect_router_mode() {
    if ip route 2>/dev/null | grep -q "^default via"; then
        echo "side"
    else
        echo "main"
    fi
}

validate_subscription() {
    if echo "$1" | grep -qE "^https?://"; then
        return 0
    else
        return 1
    fi
}

cleanup_sing_box() {
    if pgrep sing-box >/dev/null 2>&1; then
        printf "${YELLOW}检测到冲突项 sing-box 正在运行，正在停止...${NC}\n"
        if [ "$SERVICE_MGR" = "systemd" ]; then 
            systemctl stop sing-box 2>/dev/null
        else 
            /etc/init.d/sing-box stop 2>/dev/null
        fi
        killall sing-box >/dev/null 2>&1
    fi
}

# ==================== 服务生命周期控制管理器 ====================

manage_service() {
    local action=$1
    local svc_name="dae"
    
    if [ "$SERVICE_MGR" = "systemd" ]; then
        if [ "$action" = "status" ]; then
            systemctl is-active --quiet $svc_name && printf "${GREEN}${svc_name} 正在活跃运行中${NC}\n" || printf "${RED}${svc_name} 未活跃/已停止${NC}\n"
        else
            systemctl $action $svc_name 2>/dev/null
        fi
    else
        if [ "$action" = "status" ]; then
            pgrep $svc_name >/dev/null && printf "${GREEN}${svc_name} 正在活跃运行中${NC}\n" || printf "${RED}${svc_name} 未活跃/已停止${NC}\n"
        elif [ "$action" = "enable" ] || [ "$action" = "disable" ]; then
            /etc/init.d/$svc_name $action 2>/dev/null
        else
            /etc/init.d/$svc_name $action 2>/dev/null || killall $svc_name 2>/dev/null
        fi
    fi
}

# ==================== 核心配置生成 ====================

generate_dae_config() {
    local subscription_url=$1
    local router_mode=$2
    local wan_setting="wan_interface: auto"

    if [ "$router_mode" = "main" ]; then
        wan_setting="wan_interface: $WAN_IFACE"
    fi

    mkdir -p "$PERSIST_DIR"
    mkdir -p "$(dirname "$CONFIG_FILE")"
    mkdir -p "$GEO_DIR"
    
    cat << EOF > "$CONFIG_FILE"
global {
    tproxy_port: 12345
    tproxy_port_protect: true
    pprof_port: 0
    so_mark_from_dae: 0
    log_level: info
    disable_waiting_network: false
    enable_local_tcp_fast_redirect: false

    $LAN_IFACE_SETTING
    $wan_setting

    auto_config_kernel_parameter: true

    tcp_check_url: 'http://cp.cloudflare.com,1.1.1.1,2606:4700:4700::1111'
    tcp_check_http_method: HEAD
    udp_check_dns: 'dns.google:53,8.8.8.8,2001:4860:4860::8888'
    check_interval: 30s
    check_tolerance: 50ms
    fallback_resolver: '8.8.8.8:53'

    dial_mode: domain
    allow_insecure: false
    sniffing_timeout: 100ms
    tls_implementation: tls
    utls_imitate: chrome_auto
    mptcp: false

    bandwidth_max_tx: '200 mbps'
    bandwidth_max_rx: '1 gbps'
}

subscription {
    sub_store_link: '$subscription_url'
}

node {
}

dns {
    ipversion_prefer: 4
    fixed_domain_ttl {
        ddns.example.org: 10
        api.steampowered.com: 3600
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
        filter: subtag(sub_store_link)
        policy: min_moving_avg
    }
    high_speed {
        filter: subtag(sub_store_link) && name(keyword: 'Premium', 'VIP', '专线', 'IEPL')
        policy: min_moving_avg
    }
    ai_media {
        filter: subtag(sub_store_link)
        policy: min_moving_avg
    }
    gaming {
        filter: subtag(sub_store_link) && name(keyword: 'Game', 'HK', 'SG', '游戏', '直连')
        policy: min
        tcp_check_url: 'http://test.steampowered.com'
        check_interval: 10s
    }
}

routing {
    pname(NetworkManager, systemd-networkd) -> direct
    dip(224.0.0.0/3, 'ff00::/8') -> direct
    dip(geoip:private) -> direct

    l4proto(udp) && dport(443) -> block
    dip(geoip:cn) -> direct
    domain(geosite:cn) -> direct
    
    domain(keyword: 'openai', keyword: 'chatgpt') -> ai_media
    domain(keyword: 'gemini', keyword: 'generativelanguage') -> ai_media
    domain(keyword: 'anthropic', keyword: 'claude') -> ai_media
    domain(keyword: 'netflix', keyword: 'disney', keyword: 'hbo') -> ai_media
    
    domain(geosite:steam) -> gaming
    domain(geosite:google, geosite:youtube, geosite:github) -> high_speed

    fallback: my_group
}
EOF
    chmod 0600 "$CONFIG_FILE"
    printf "${GREEN}✅ 已成功组装 Sub-Store 特调分流配置文件：${CONFIG_FILE}${NC}\n"
    
    if command -v dae >/dev/null 2>&1; then
        printf "${YELLOW}正在通过 Sub-Store 节点树进行内核本地沙盒语义模拟校验...${NC}\n"
        if dae validate -c "$CONFIG_FILE" >/dev/null 2>&1; then
            printf "${GREEN}[成功] 配置文件完美通过 dae 官方内核语法校验！${NC}\n"
        else
            printf "${YELLOW}[提醒] 如果大鹅报 GEO 映射错误，请运行选单 3 同步最新本地规则库后再行点火。${NC}\n"
        fi
    fi
}

# ==================== 核心下载与无损更新 ====================

upgrade_dae_core() {
    printf "\n${CYAN}--- 🔄 无损更新/安装 dae 核心 ---${NC}\n"
    check_ebpf_support
    
    local arch target_arch
    arch=$(uname -m)
    case "$arch" in
        x86_64) target_arch="x86_64" ;;
        aarch64) target_arch="arm64" ;;
        arm64) target_arch="arm64" ;;
        *) printf "${RED}自动更新暂不支持此架构: %s${NC}\n" "$arch"; return 1 ;;
    esac

    printf "${YELLOW}正在从 GitHub API 拉取最新发行版本标记...${NC}\n"
    local latest_version
    latest_version=$(curl -s "https://api.github.com/repos/daeuniverse/dae/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [ -z "$latest_version" ]; then
        printf "${RED}无法获取云端版本信息，请检查国际网络连通性。${NC}\n"
        return 1
    fi

    local current_version="未安装"
    if command -v dae >/dev/null 2>&1; then
        current_version=$(dae --version 2>/dev/null | awk '{print $3}')
    fi
    printf "当前本地版本: ${GREEN}%s${NC}\n" "${current_version}"
    printf "云端最新版本: ${GREEN}%s${NC}\n" "${latest_version}"

    if [ "v${current_version}" = "${latest_version}" ] || [ "${current_version}" = "${latest_version}" ]; then
        printf "${GREEN}当前已是最新版本，无需覆盖安装！${NC}\n"
        return 0
    fi

    local download_url="https://github.com/daeuniverse/dae/releases/download/${latest_version}/dae-linux-${target_arch}.zip"
    printf "${YELLOW}⬇️ 正在下载二进制核心压缩包...${NC}\n"
    curl -L -o /tmp/dae-update.zip "$download_url"
    if [ $? -ne 0 ]; then
        printf "${RED}核心文件下载超时，请检查路由上游链路！${NC}\n"
        return 1
    fi

    printf "${YELLOW}正在安全挂起当前大鹅代理状态...${NC}\n"
    manage_service "stop"
    clean_network_resources

    unzip -o /tmp/dae-update.zip dae -d /tmp/ >/dev/null 2>&1
    if [ ! -f /tmp/dae ]; then
        unzip -o /tmp/dae-update.zip -d /tmp/ >/dev/null 2>&1
    fi

    if [ -f /tmp/dae ] || [ -f /tmp/dae-linux-* ]; then
        local dae_path
        dae_path=$(command -v dae || echo "/usr/bin/dae")
        [ -f /tmp/dae-linux-* ] && mv /tmp/dae-linux-* /tmp/dae
        mv /tmp/dae "$dae_path"
        chmod +x "$dae_path"
        printf "${GREEN}✅ 核心文件无损落地成功！${NC}\n"
    else
        printf "${RED}解压和结构提取破损。${NC}\n"
        rm -f /tmp/dae-update.zip
        return 1
    fi
    rm -f /tmp/dae-update.zip

    if [ "$SERVICE_MGR" = "systemd" ] && [ ! -f /etc/systemd/system/dae.service ]; then
        cat <<EOF > /etc/systemd/system/dae.service
[Unit]
Description=dae Advanced eBPF Proxy Service
After=network.target network-online.target

[Service]
Type=simple
User=root
ExecStart=$dae_path run --config /etc/dae/config.dae
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    fi

    printf "${YELLOW}正在重新点火加载服务...${NC}\n"
    manage_service "start"
    send_wechat_notification "大鹅底层核心可执行组件成功无损同步更新至 ${latest_version}。"
}

# ==================== GEO 规则数据自动化集成 ====================

create_geo_update_script() {
    mkdir -p "$(dirname "$UPDATE_GEO_SCRIPT")"
    cat << EOF > "$UPDATE_GEO_SCRIPT"
#!/bin/sh
mkdir -p "$GEO_DIR"
echo "正在从社区骨干网同步 geoip.dat..."
curl -L -o "$GEO_DIR/geoip.dat" "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
echo "正在从社区骨干网同步 geosite.dat..."
curl -L -o "$GEO_DIR/geosite.dat" "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
chmod 644 "$GEO_DIR/geoip.dat" "$GEO_DIR/geosite.dat"

mkdir -p /etc/dae
ln -sf "$GEO_DIR/geoip.dat" /etc/dae/geoip.dat 2>/dev/null
ln -sf "$GEO_DIR/geosite.dat" /etc/dae/geosite.dat 2>/dev/null

if [ -f /lib/lsb/init-functions ] || [ ! -f /etc/init.d/dae ]; then
    systemctl restart dae >/dev/null 2>&1
else
    /etc/init.d/dae restart >/dev/null 2>&1
fi
EOF
    chmod +x "$UPDATE_GEO_SCRIPT"
}

update_geo_data() {
    if [ ! -f "$UPDATE_GEO_SCRIPT" ]; then
        create_geo_update_script
    fi
    printf "${YELLOW}[运行] 正在触发执行底层的 GEO 规则库全量拉取链...${NC}\n"
    "$UPDATE_GEO_SCRIPT"
    printf "${GREEN}✅ 数据同步完成。${NC}\n"
}

set_geo_update_schedule() {
    printf "\n${PURPLE}--- 🗓️ 规则自动更新计划任务设定 ---${NC}\n"
    echo "1) 每天夜间凌晨自动轮询更新"
    echo "2) 每周一凌晨自动轮询更新"
    echo "3) 每月1号自动轮询更新"
    read -r freq
    case $freq in
        1) cron_schedule="0 0 * * *" ;;
        2) cron_schedule="0 0 * * 1" ;;
        3) cron_schedule="0 0 1 * *" ;;
        *) cron_schedule="0 0 * * 1" ;;
    esac

    crontab -l > /tmp/crontab.tmp 2>/dev/null
    sed -i "/update-geo.sh/d" /tmp/crontab.tmp
    echo "$cron_schedule $UPDATE_GEO_SCRIPT >/dev/null 2>&1" >> /tmp/crontab.tmp
    crontab /tmp/crontab.tmp
    rm /tmp/crontab.tmp
    
    if [ "$SERVICE_MGR" = "systemd" ]; then
        systemctl restart cron 2>/dev/null || systemctl restart crond 2>/dev/null
    else
        /etc/init.d/cron restart 2>/dev/null || /etc/init.d/crond restart 2>/dev/null
    fi
    printf "${GREEN}✅ 定时计划任务配置成功，已自动剔除历史重复项。${NC}\n"
}

# ==================== Docker 特权隔离沙盒模式 ====================

install_dae_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        printf "${RED}[阻断] 宿主机未检测到 Docker 容器引擎。请先安装 Docker。${NC}\n"
        return 1
    fi
    check_ebpf_support
    
    printf "${RED}⚠️【警告】大鹅涉及深度内核态注入，非极度特殊纯净环境不建议在容器内跑。${NC}\n"
    printf "确认要采用沙盒虚拟化形态部署吗？(y/n): "
    read -r continue_docker
    if [ "$continue_docker" != "y" ] && [ "$continue_docker" != "Y" ]; then
        return 0
    fi

    printf "请输入底座镜像类型（直接回车缺省使用 ubuntu:22.04）: "
    read -r docker_image
    docker_image=${docker_image:-ubuntu:22.04}

    printf "请粘贴你在 Sub-Store 复制的通用订阅链接 URL: "
    read -r doc_sub
    if ! validate_subscription "$doc_sub"; then
        printf "${RED}订阅地址不合法。${NC}\n"
        return 1
    fi

    if docker ps -a | grep -q dae; then
        docker rm -f dae >/dev/null 2>&1
    fi

    mkdir -p /etc/dae
    LAN_IFACE_SETTING="lan_interface: \"\""
    generate_dae_config "$doc_sub" "main"

    printf "${BLUE}[Docker] 正在全速拉取并构建特权容器沙盒环境...${NC}\n"
    local m_arch
    m_arch=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')

    docker run --rm --privileged --network=host -v /etc/dae:/etc/dae "$docker_image" /bin/bash -c "
        apt-get update && apt-get install -y curl unzip >/dev/null &&
        curl -L -o /tmp/dae.zip https://github.com/daeuniverse/dae/releases/download/v0.9.0/dae-linux-${m_arch}.zip &&
        unzip -o /tmp/dae.zip -d /etc/dae/ &&
        mv /etc/dae/dae-linux-* /etc/dae/dae 2>/dev/null || true
    "

    docker run -d \
        --name dae \
        --restart always \
        --privileged \
        --network=host \
        -v /sys:/sys \
        -v /dev:/dev \
        -v /etc/dae:/etc/dae \
        "$docker_image" \
        /etc/dae/dae run --config /etc/dae/config.dae

    if [ "$(docker inspect -f '{{.State.Running}}' dae 2>/dev/null)" = "true" ]; then
        printf "${GREEN}🎉 Docker 特权大鹅沙盒已点火成功上线！${NC}\n"
        send_wechat_notification "Docker沙盒特权模式下的大鹅透明代理已点火启动。"
    else
        printf "${RED}[熄火] 容器因提权受阻异常退栈。请通过 docker logs dae 查看。${NC}\n"
    fi
}

# ==================== 旁路由与引导面板 ====================

display_side_router_instructions() {
    if [ "$(detect_router_mode)" = "side" ]; then
        printf "\n${YELLOW}💡 侦测到您当前处于【旁路由网关】生态，请确保主路由侧完成如下补强配对：${NC}\n"
        printf "1. 主路由的 DHCP 分发网关和 DNS 指向当前设备的局域网内网IP: ${CYAN}%s${NC}\n" "$LAN_IP"
        printf "2. 如果防火墙未自动咬合，可在主路由或本旁路由中补入 TPROXY 标记转换:\n"
        printf "   iptables -t mangle -A PREROUTING -i %s -p tcp -j TPROXY --on-port 12345 --tproxy-mark 0x1\n" "$LAN_IFACE"
    fi
}

# ==================== 系统主控入口驱动 ====================

main_menu() {
    detect_system_env
    check_dependencies
    get_network_info
    cleanup_sing_box
    load_env
    
    while true; do
        check_log_size
        printf "\n"
        printf "${GREEN}================================================================${NC}\n"
        printf "${GREEN}   🦢 dae (大鹅) 高性能 eBPF 透明代理全平台融合配置管家 (修复版)${NC}\n"
        printf "   当前系统环境: ${YELLOW}%s (%s)${NC} | 拓扑检测: ${CYAN}%s路由${NC}\n" "${SERVICE_MGR}" "${PKG_MANAGER:-未知}" "$(detect_router_mode)"
        printf "   内网默认接口: ${GREEN}%s${NC} | 本机IP: ${GREEN}%s${NC}\n" "${LAN_IFACE}" "${LAN_IP}"
        printf "${GREEN}================================================================${NC}\n"
        printf " 1) ${GREEN}⚡ 智能向导：一键安装/更新 dae 核心【完美保留现有配置】${NC}\n"
        printf " 2) ✍️ 交互配置：粘贴 Sub-Store 链接并生成流媒体/AI分流矩阵\n"
        printf " 3) 🔄 立即全量拉取更新本地 GEO 规则数据库文件\n"
        printf " 4) 🗓️ 规划配置：设定 Crontab 计划任务定时自动化洗刷 Geo 规则\n"
        printf " 5) ⚙️ 控制中心：查看 dae 服务运行看板与启动/重启/停止拦截\n"
        printf " 6) 🐳 独立沙盒：使用 Docker 特权提权链路容器化部署 dae\n"
        printf " 7) 🔔 外部联动：配置/修改企业微信运维通知推送 Webhook 密钥\n"
        printf " 8) ❌ 退出当前向导程序\n"
        printf "${GREEN}================================================================${NC}\n"
        printf "请输入数字选项 [1-8]："
        read -r choice
        case $choice in
            1)
                upgrade_dae_core
                ;;
            2)
                printf "${PURPLE}【✨ Sub-Store 操作指引】${NC}\n"
                printf "${YELLOW}请在 Sub-Store 预览截图中点击第一项「通用订阅」右侧的复制按钮获取链接。${NC}\n"
                printf "请粘贴复制好的 Sub-Store 通用订阅地址 (http/https): "
                read -r SUBSCRIPTION_URL
                if validate_subscription "$SUBSCRIPTION_URL"; then
                    smart_interface_sniffer
                    local r_mode
                    r_mode=$(detect_router_mode)
                    generate_dae_config "$SUBSCRIPTION_URL" "$r_mode"
                    display_side_router_instructions
                    printf "${YELLOW}正在使能并冷重启服务以加载节点树...${NC}\n"
                    manage_service "enable" >/dev/null 2>&1
                    clean_network_resources
                    manage_service "restart"
                    send_wechat_notification "大鹅成功同步 Sub-Store 聚合订阅，透明分流矩阵已刷新。"
                else
                    printf "${RED}[异常] 链入的 URL 格式非法，必须以 http:// 或 https:// 开头！${NC}\n"
                fi
                ;;
            3) update_geo_data ;;
            4) set_geo_update_schedule ;;
            5)
                echo "1) 强起大鹅内核接管 (Start)"
                echo "2) 挂起撤回大鹅内核接管 (Stop)"
                echo "3) 全盘冷启动复位重载 (Restart)"
                echo "4) 调取当前实时健康看板 (Status)"
                printf "请指派动作 [1-4]: "
                read -r svc_act
                case $svc_act in
                    1) clean_network_resources; manage_service "start"; echo "已触发启动。";;
                    2) manage_service "stop"; clean_network_resources; echo "已安全撤消。";;
                    3) clean_network_resources; manage_service "restart"; echo "已全盘重启。";;
                    4) manage_service "status" ;;
                esac
                ;;
            6) install_dae_docker ;;
            7)
                printf "请粘贴企业微信群机器人的 Webhook 完整 URL: "
                read -r input_wx
                if [ -n "$input_wx" ]; then
                    WECHAT_WEBHOOK="$input_wx"
                    save_env "WECHAT_WEBHOOK" "$WECHAT_WEBHOOK"
                    printf "${GREEN}通知通道已固化绑定。${NC}\n"
                fi
                ;;
            8)
                printf "${GREEN}退出程序。祝您网络畅通！${NC}\n"
                exit 0
                ;;
            *)
                printf "${RED}输入有误，请输入1-8之间的有效编号。${NC}\n"
                ;;
        esac
    done
}

# 挂载运行入口
main_menu
