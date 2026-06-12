#!/bin/sh

# ==================== 全局配置 ====================
SCRIPT_VERSION="1.5"

# 核心路径定义
CONFIG_FILE="/etc/dae/config.dae"
GEO_DIR="/usr/share/dae"
PERSIST_DIR="/etc/dae/persist.d"
UPDATE_GEO_SCRIPT="/etc/dae/update-geo.sh"
DAE_BIN_PATH="/usr/bin/dae"
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
    escaped_value=$(printf '%s\n' "$value" | sed 's/[&/\]/\\&/g')
    if grep -q "^$key=" "$ENV_FILE"; then
        sed -i "s|^$key=.*|$key=\"$escaped_value\"|" "$ENV_FILE"
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
    escaped_msg=$(printf '%s' "$msg" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed 's/\n/\\n/g')
    curl -s -X POST "$WECHAT_WEBHOOK" \
       -H 'Content-Type: application/json' \
       -d "{
            \"msgtype\": \"text\",
            \"text\": {
                \"content\": \"【大鹅云助手】运维状态更新\n报告时间：$(date '+%Y-%m-%d %H:%M:%S')\n事件详情：$escaped_msg\"
            }
       }" >/dev/null
}

check_log_size() {
    if [ -f "$LOG_FILE" ]; then
        local log_size
        log_size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$log_size" -gt "$LOG_SIZE_LIMIT" ]; then
            printf "${YELLOW}[系统] 日志文件超过1MB，正在自动轮转清空...${NC}\n"
            cat /dev/null > "$LOG_FILE"
        fi
    fi
}

# ==================== 确定感补强：无痕清理与状态诊断 ====================

clean_network_resources() {
    printf "${YELLOW}[清理] 正在排查并深度无痕清理网络挂载资源...${NC}\n"
    
    if ip rule show | grep -q "fwmark 0x1bf52"; then
        ip rule del fwmark 114514 table 114514 2>/dev/null
        printf "  - 已成功解除并注销内核 fwmark 114514 策略路由规则 [${GREEN}OK${NC}]\n"
    else
        printf "  - 未发现残留的 fwmark 114514 策略规则 [${CYAN}干净${NC}]\n"
    fi

    ip route flush table 114514 2>/dev/null
    
    if ip link show dae >/dev/null 2>&1; then
        ip link delete dae 2>/dev/null
        printf "  - 检测到残留的 eBPF 虚接口 dae，已强行卸载销毁 [${GREEN}OK${NC}]\n"
    else
        printf "  - 内核网卡设备中未见 dae 残留接口 [${CYAN}干净${NC}]\n"
    fi

    if pgrep -x dae >/dev/null 2>&1; then
        local pid_list
        pid_list=$(pgrep -x dae)
        printf "${YELLOW}  - 预警：检测到正在运行的 dae 核心进程 (PID: %s)，开始优雅终止...${NC}\n" "$pid_list"
        killall dae 2>/dev/null
        sleep 2
        if pgrep -x dae >/dev/null 2>&1; then
            printf "${RED}  - 警告：dae 进程拒绝优雅退出，正在触发硬核强杀 (kill -9)...${NC}\n"
            killall -9 dae 2>/dev/null
            sleep 1
        fi
        if pgrep -x dae >/dev/null 2>&1; then
            printf "  - 进程清理反馈：${RED}清理失败，进程依旧顽固存在，请检查内核锁！${NC}\n"
        else
            printf "  - 进程清理反馈：${GREEN}所有残留大鹅进程已被无痕连根拔起！${NC}\n"
        fi
    else
        printf "  - 进程清理反馈：${GREEN}后台纯净，无任何残留大鹅进程运行${NC}\n"
    fi
}

print_service_live_status() {
    printf "${YELLOW}[诊断] 正在对点火后的 dae 服务状态进行即时抓取验证...${NC}\n"
    sleep 2
    
    if pgrep -x dae >/dev/null 2>&1; then
        local active_pid
        active_pid=$(pgrep -x dae | head -n1)
        printf "  - 运行状态：${GREEN}● 活跃中 (Running)${NC}\n"
        printf "  - 主进程 PID：${CYAN}%s${NC}\n" "$active_pid"
        
        if command -v netstat >/dev/null 2>&1; then
            if netstat -tunlp 2>/dev/null | grep -q "dae"; then
                printf "  - 端口绑定：${GREEN}成功监听 TProxy 流量导入网关${NC}\n"
            fi
        elif command -v ss >/dev/null 2>&1; then
            if ss -tunlp 2>/dev/null | grep -q "dae"; then
                printf "  - 端口绑定：${GREEN}成功监听 TProxy 流量导入网关${NC}\n"
            fi
        fi
        return 0
    else
        printf "  - 运行状态：${RED}■ 熄火/启动失败 (Stopped)${NC}\n"
        printf "  - 错误成因排查：\n"
        if [ ! -f "$CONFIG_FILE" ]; then
            printf "    ${RED}[原因] 核心配置文件 /etc/dae/config.dae 不存在！${NC}\n"
        elif [ ! -f "$GEO_DIR/geoip.dat" ] || [ ! -f "$GEO_DIR/geosite.dat" ]; then
            printf "    ${RED}[原因] 缺少 GEO 规则依赖库，请执行菜单选项 3 刷新规则库！${NC}\n"
        else
            printf "    ${RED}[原因] 疑似订阅链接内的节点协议内核无法解析，或网卡绑定冲突。${NC}\n"
            printf "    ${YELLOW}💡 建议排查日志：tail -n 20 %s 或 logread | grep dae${NC}\n" "$LOG_FILE"
        fi
        return 1
    fi
}

# ==================== 智能识别与跨平台依赖 ====================

detect_system_env() {
    PKG_MANAGER=""
    INSTALL_CMD=""
    
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt"
        INSTALL_CMD="apt-get install -y --no-install-recommends"
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
        INSTALL_CMD="apk add --no-cache"
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
    local missing_deps=""
    for dep in curl unzip ip pidof; do
        if ! command -v $dep >/dev/null 2>&1; then
            missing_deps="$missing_deps $dep"
        fi
    done

    if [ -n "$missing_deps" ]; then
        printf "${YELLOW}缺少核心依赖:%s，正在尝试通过 $PKG_MANAGER 安装...${NC}\n" "$missing_deps"
        if [ -n "$INSTALL_CMD" ]; then
            for dep in $missing_deps; do
                local pkg_name=$dep
                [ "$dep" = "ip" ] && ( [ "$PKG_MANAGER" = "apt" ] || [ "$PKG_MANAGER" = "yum" ] || [ "$PKG_MANAGER" = "dnf" ] ) && pkg_name="iproute2"
                [ "$dep" = "pidof" ] && [ "$PKG_MANAGER" = "opkg" ] && pkg_name="procps-ng-pidof"
                $INSTALL_CMD $pkg_name >/dev/null 2>&1
                if ! command -v $dep >/dev/null 2>&1; then
                     printf "${RED}依赖 $dep ($pkg_name) 自动安装失败，请手动安装后重试！${NC}\n"
                     exit 1
                fi
            done
        else
            printf "${RED}无法找到包管理器，请手动安装以下依赖后重试:%s${NC}\n" "$missing_deps"
            exit 1
        fi
    fi
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

# 【关键修复】重写网络信息获取逻辑，优先适配 OpenWrt
get_network_info() {
    if command -v uci >/dev/null 2>&1; then
        # OpenWrt 环境：使用 uci 作为信息源
        LAN_IFACE=$(uci get network.lan.device 2>/dev/null || uci get network.lan.ifname 2>/dev/null || echo "br-lan")
        LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null)
        # 如果 uci 拿不到 IP，再用 ip addr 命令作为后备
        if [ -z "$LAN_IP" ]; then
            LAN_IP=$(ip addr show "$LAN_IFACE" 2>/dev/null | grep -o "inet [0-9.]\+" | cut -d' ' -f2 | head -n1)
        fi
        WAN_IFACE=$(uci get network.wan.device 2>/dev/null || uci get network.wan.ifname 2>/dev/null || echo "eth0.2") # 默认一个常见值
    else
        # 标准 Linux 环境
        DEFAULT_IFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '/dev/ {print $5}' | head -n1)
        if [ -n "$DEFAULT_IFACE" ]; then
            LAN_IFACE="$DEFAULT_IFACE"
            WAN_IFACE="$DEFAULT_IFACE"
            LAN_CIDR=$(ip addr show "$LAN_IFACE" 2>/dev/null | awk '/inet / {print $2}' | head -n1)
            LAN_IP=$(echo "$LAN_CIDR" | cut -d/ -f1)
        fi
    fi

    # 如果所有自动方法都失败，则请求用户手动输入
    if [ -z "$LAN_IP" ]; then
        printf "${RED}无法自动获取网络接口信息！${NC}\n"
        printf "请输入您的局域网接口名称 (例如 eth0, br-lan): "
        read -r LAN_IFACE
        printf "请输入该接口的IP地址 (例如 192.168.1.1): "
        read -r LAN_IP
        if [ -z "$LAN_IFACE" ] || [ -z "$LAN_IP" ]; then
            printf "${RED}信息不足，无法继续。${NC}\n"
            exit 1
        fi
        WAN_IFACE="$LAN_IFACE" # 在未知情况下，假定为单网卡模式
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
        printf "${YELLOW}你选择了全选策略，这将绑定所有非虚拟物理网卡，请确认 (y/n): ${NC}"
        read -r confirm_all
        if [ "$confirm_all" != "y" ] && [ "$confirm_all" != "Y" ]; then
             LAN_IFACE_SETTING="lan_interface: $LAN_IFACE"
             printf "${GREEN}[保守策略] 已选用系统默认接口: %s${NC}\n" "$LAN_IFACE"
             return
        fi
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
    if ip route show default | grep -q "via"; then
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
    if pgrep -x sing-box >/dev/null 2>&1; then
        printf "${YELLOW}检测到冲突项 sing-box 正在运行，正在停止并解除占用...${NC}\n"
        if [ "$SERVICE_MGR" = "systemd" ]; then 
            systemctl stop sing-box 2>/dev/null
        else 
            /etc/init.d/sing-box stop 2>/dev/null
        fi
        killall sing-box >/dev/null 2>&1
    fi
}

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
            pgrep -x $svc_name >/dev/null && printf "${GREEN}${svc_name} 正在活跃运行中${NC}\n" || printf "${RED}${svc_name} 未活跃/已停止${NC}\n"
        elif [ -f "/etc/init.d/$svc_name" ]; then
             /etc/init.d/$svc_name $action 2>/dev/null
        elif [ "$action" = "start" ]; then
             nohup "$DAE_BIN_PATH" run --config "$CONFIG_FILE" > "$LOG_FILE" 2>&1 &
        elif [ "$action" = "stop" ]; then
             killall $svc_name 2>/dev/null
        fi
    fi
}

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
# Generated by dae-helper script v$SCRIPT_VERSION on $(date)
global {
    tproxy_port: 12345
    tproxy_port_protect: true
    pprof_port: 0
    so_mark_from_dae: 0
    log_level: info
    log_output: "$LOG_FILE"
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
            printf "${RED}[语法报错] dae 校验器提示配置不合规！请排查接口绑定名或日志。${NC}\n"
        fi
    fi
}

upgrade_dae_core() {
    printf "\n${CYAN}--- 🔄 无损更新/安装 dae 核心 ---${NC}\n"
    check_ebpf_support
    
    local arch target_arch
    arch=$(uname -m)
    case "$arch" in
        x86_64) target_arch="x86_64" ;;
        aarch64|arm64) target_arch="arm64" ;;
        *) printf "${RED}自动更新暂不支持此架构: %s${NC}\n" "$arch"; return 1 ;;
    esac

    printf "${YELLOW}正在从 GitHub API 拉取最新发行版本标记...${NC}\n"
    local latest_version
    latest_version=$(curl -s "https://api.github.com/repos/daeuniverse/dae/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [ -z "$latest_version" ]; then
        printf "${RED}无法获取云端版本信息，请检查网络连通性。${NC}\n"
        return 1
    fi

    local current_version="未安装"
    if [ -f "$DAE_BIN_PATH" ] && [ -x "$DAE_BIN_PATH" ]; then
        current_version=$("$DAE_BIN_PATH" --version 2>/dev/null | awk '{print $3}')
    fi
    printf "当前本地版本: ${GREEN}%s${NC}\n" "${current_version}"
    printf "云端最新版本: ${GREEN}%s${NC}\n" "${latest_version}"

    if [ "v${current_version}" = "${latest_version}" ] || [ "${current_version}" = "${latest_version}" ]; then
        printf "${GREEN}当前已是最新版本，无需覆盖安装！${NC}\n"
        return 0
    fi

    local download_url="https://github.com/daeuniverse/dae/releases/download/${latest_version}/dae-linux-${target_arch}.zip"
    local tmp_zip="/tmp/dae-update.zip"
    printf "${YELLOW}⬇️ 正在下载二进制核心压缩包...${NC}\n"
    curl -L -o "$tmp_zip" "$download_url"
    if [ $? -ne 0 ]; then
        printf "${RED}核心文件下载超时，请检查路由上游链路！${NC}\n"
        rm -f "$tmp_zip"
        return 1
    fi

    if ! unzip -t "$tmp_zip" >/dev/null 2>&1; then
        printf "${RED}下载的文件不是一个有效的 ZIP 压缩包，更新中止。${NC}\n"
        rm -f "$tmp_zip"
        return 1
    fi

    printf "${YELLOW}正在安全挂起当前大鹅代理状态...${NC}\n"
    manage_service "stop"
    clean_network_resources

    local tmp_dir="/tmp/dae-unzip-$$"
    mkdir -p "$tmp_dir"
    unzip -o "$tmp_zip" -d "$tmp_dir" >/dev/null 2>&1
    local dae_file
    dae_file=$(find "$tmp_dir" -type f -name "dae" | head -n1)

    if [ -n "$dae_file" ] && [ -f "$dae_file" ]; then
        mv "$dae_file" "$DAE_BIN_PATH"
        chmod +x "$DAE_BIN_PATH"
        printf "${GREEN}✅ 核心文件无损落地成功！${NC}\n"
    else
        printf "${RED}解压失败或压缩包内找不到 'dae' 文件。${NC}\n"
        rm -rf "$tmp_dir" "$tmp_zip"
        return 1
    fi
    rm -rf "$tmp_dir" "$tmp_zip"

    if [ "$SERVICE_MGR" = "systemd" ]; then
        if [ ! -f /etc/systemd/system/dae.service ]; then
            cat <<EOF > /etc/systemd/system/dae.service
[Unit]
Description=dae Advanced eBPF Proxy Service
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=$DAE_BIN_PATH run --config $CONFIG_FILE
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
        fi
    else
        if [ ! -f "/etc/init.d/dae" ]; then
            cat << 'EOF' > /etc/init.d/dae
#!/bin/sh /etc/rc.common
START=95
USE_PROCD=1

start_service() {
    procd_open_instance
    procd_set_param command /usr/bin/dae run --config /etc/dae/config.dae
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param respawn
    procd_close_instance
}
EOF
            chmod +x /etc/init.d/dae
        fi
    fi

    printf "${YELLOW}正在重新点火加载服务...${NC}\n"
    manage_service "start"
    print_service_live_status
    send_wechat_notification "大鹅底层核心可执行组件成功无损同步更新至 ${latest_version}。"
}

create_geo_update_script() {
    mkdir -p "$(dirname "$UPDATE_GEO_SCRIPT")"
    cat << 'EOF' > "$UPDATE_GEO_SCRIPT"
#!/bin/sh
GEO_DIR="/usr/share/dae"
mkdir -p "$GEO_DIR"
echo "正在从社区骨干网同步 geoip.dat..."
curl -L -o "$GEO_DIR/geoip.dat.tmp" "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" && mv "$GEO_DIR/geoip.dat.tmp" "$GEO_DIR/geoip.dat"
echo "正在从社区骨干网同步 geosite.dat..."
curl -L -o "$GEO_DIR/geosite.dat.tmp" "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" && mv "$GEO_DIR/geosite.dat.tmp" "$GEO_DIR/geosite.dat"
chmod 644 "$GEO_DIR/geoip.dat" "$GEO_DIR/geosite.dat"

mkdir -p /etc/dae
ln -sf "$GEO_DIR/geoip.dat" /etc/dae/geoip.dat 2>/dev/null
ln -sf "$GEO_DIR/geosite.dat" /etc/dae/geosite.dat 2>/dev/null

if pgrep -x dae >/dev/null 2>&1; then
    echo "检测到 dae 正在运行，将重启以应用新规则..."
    if command -v systemctl >/dev/null 2>&1 && pidof systemd >/dev/null 2>&1; then
        systemctl restart dae >/dev/null 2>&1
    elif [ -f /etc/init.d/dae ]; then
        /etc/init.d/dae restart >/dev/null 2>&1
    fi
fi
EOF
    chmod +x "$UPDATE_GEO_SCRIPT"
}

update_geo_data() {
    if [ ! -f "$UPDATE_GEO_SCRIPT" ]; then
        create_geo_update_script
    fi
    printf "${YELLOW}[运行] 正在触发执行底层的 GEO 规则库全量拉取链...${NC}\n"
    sh "$UPDATE_GEO_SCRIPT"
    printf "${GREEN}✅ 数据同步完成。${NC}\n"
}

set_geo_update_schedule() {
    if ! command -v crontab >/dev/null 2>&1; then
        printf "${RED}系统未安装 crontab，无法设定计划任务。${NC}\n"
        return 1
    fi
    printf "\n${PURPLE}--- 🗓️ 规则自动更新计划任务设定 ---${NC}\n"
    echo "1) 每天凌晨3点自动更新"
    echo "2) 每周一凌晨3点自动更新"
    echo "3) 每月1号凌晨3点自动更新"
    read -r freq
    case $freq in
        1) cron_schedule="0 3 * * *" ;;
        2) cron_schedule="0 3 * * 1" ;;
        3) cron_schedule="0 3 1 * *" ;;
        *) cron_schedule="0 3 * * 1" ;;
    esac
    
    (crontab -l 2>/dev/null | grep -v "$UPDATE_GEO_SCRIPT"; echo "$cron_schedule $UPDATE_GEO_SCRIPT >/dev/null 2>&1") | crontab -

    if [ "$SERVICE_MGR" = "systemd" ]; then
        systemctl restart cron 2>/dev/null || systemctl restart crond 2>/dev/null
    else
        [ -f /etc/init.d/cron ] && /etc/init.d/cron restart >/dev/null 2>&1
    fi
    printf "${GREEN}✅ 定时计划任务配置成功，已自动剔除历史重复项。${NC}\n"
}

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

    printf "请粘贴你在 Sub-Store 复制的通用订阅链接 URL: "
    read -r doc_sub
    if ! validate_subscription "$doc_sub"; then
        printf "${RED}订阅地址不合法。${NC}\n"
        return 1
    fi

    if docker ps -a | grep -q dae-container; then
        docker rm -f dae-container >/dev/null 2>&1
    fi

    mkdir -p /etc/dae/docker/data
    mkdir -p /etc/dae/persist.d
    LAN_IFACE_SETTING="lan_interface: \"\" # Docker模式下留空"
    generate_dae_config "$doc_sub" "main"

    printf "${BLUE}[Docker] 正在全速拉取 dae 官方镜像...${NC}\n"
    if ! docker pull ghcr.io/daeuniverse/dae:latest; then
        printf "${RED}Docker 镜像拉取失败，请检查网络或 Docker Hub 连通性。${NC}\n"
        return 1
    fi
    
    printf "${BLUE}为 Docker 容器准备最新的 GEO 数据...${NC}\n"
    curl -L -o "/etc/dae/docker/data/geoip.dat" "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
    curl -L -o "/etc/dae/docker/data/geosite.dat" "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"

    printf "${BLUE}正在启动 dae 特权容器...${NC}\n"
    docker run -d \
        --name dae-container \
        --restart always \
        --privileged \
        --network=host \
        -v /etc/dae/config.dae:/etc/dae/config.dae:ro \
        -v /etc/dae/docker/data:/usr/share/dae \
        -v /etc/dae/persist.d:/etc/dae/persist.d \
        ghcr.io/daeuniverse/dae:latest

    sleep 3
    if [ "$(docker inspect -f '{{.State.Running}}' dae-container 2>/dev/null)" = "true" ]; then
        printf "${GREEN}🎉 Docker 特权大鹅沙盒已点火成功上线！${NC}\n"
        send_wechat_notification "Docker沙盒特权模式下的大鹅透明代理已点火启动。"
    else
        printf "${RED}[熄火] 容器因提权受阻或配置问题异常退出。${NC}\n"
        printf "${YELLOW}请通过以下命令查看日志：docker logs dae-container${NC}\n"
    fi
}

uninstall_dae() {
    printf "\n${RED}--- ☠️ 彻底卸载 dae ---${NC}\n"
    printf "${YELLOW}此操作将从系统中移除 dae 核心、所有配置文件、GEO数据和计划任务。${NC}\n"
    printf "确认要继续吗? (y/n): "
    read -r confirm_uninstall
    if [ "$confirm_uninstall" != "y" ] && [ "$confirm_uninstall" != "Y" ]; then
        printf "${GREEN}操作已取消。${NC}\n"
        return
    fi
    
    printf "${YELLOW}正在停止并禁用 dae 服务...${NC}\n"
    manage_service "stop"
    manage_service "disable"
    
    printf "${YELLOW}正在执行深度网络资源清理...${NC}\n"
    clean_network_resources
    
    if docker ps -a --format '{{.Names}}' | grep -q dae-container; then
        printf "${YELLOW}正在清理 Docker 容器...${NC}\n"
        docker rm -f dae-container >/dev/null 2>&1
    fi
    
    printf "${YELLOW}正在移除相关文件和目录...${NC}\n"
    rm -f "$DAE_BIN_PATH" /etc/systemd/system/dae.service /etc/init.d/dae "$ENV_FILE"
    rm -rf /etc/dae /usr/share/dae
    
    printf "${YELLOW}正在清理 Crontab 计划任务...${NC}\n"
    if command -v crontab >/dev/null 2>&1; then
        (crontab -l 2>/dev/null | grep -v "$UPDATE_GEO_SCRIPT") | crontab -
    fi
    
    if [ "$SERVICE_MGR" = "systemd" ]; then
        systemctl daemon-reload 2>/dev/null
    fi
    
    printf "${GREEN}✅ dae 已被彻底从系统中移除。${NC}\n"
    send_wechat_notification "dae 已被从系统中彻底卸载。"
}

display_side_router_instructions() {
    if [ "$(detect_router_mode)" = "side" ]; then
        printf "\n${YELLOW}💡 侦测到您当前处于【旁路由网关】生态，请确保主路由侧完成如下补强配对：${NC}\n"
        printf "1. 主路由的 DHCP 分发网关和 DNS 指向当前设备的局域网内网IP: ${CYAN}%s${NC}\n" "$LAN_IP"
        printf "2. 如果防火墙未自动咬合，可在主路由或本旁路由中补入 TPROXY 标记转换:\n"
        printf "   iptables -t mangle -A PREROUTING -i %s -p tcp -j TPROXY --on-port 12345 --tproxy-mark 0x1\n" "$LAN_IFACE"
    fi
}

main_menu() {
    # 【关键修复】在脚本启动时首先净化网络环境，避免后续网络操作被自身劫持
    detect_system_env
    check_dependencies
    clean_network_resources 

    # 在干净的网络环境下获取信息
    get_network_info
    cleanup_sing_box
    load_env
    
    while true; do
        check_log_size
        printf "\n"
        printf "${GREEN}================================================================${NC}\n"
        printf "${GREEN}   🦢 dae 高性能 eBPF 透明代理全平台融合配置管家 (v%s)${NC}\n" "$SCRIPT_VERSION"
        printf "   当前系统: ${YELLOW}%s (%s)${NC} | 拓扑: ${CYAN}%s路由${NC} | 内核: ${PURPLE}%s${NC}\n" "${SERVICE_MGR}" "${PKG_MANAGER:-未知}" "$(detect_router_mode)" "$(uname -r)"
        printf "   内网接口: ${GREEN}%s${NC} | 本机IP: ${GREEN}%s${NC}\n" "${LAN_IFACE}" "${LAN_IP}"
        printf "${GREEN}================================================================${NC}\n"
        printf " 1) ${GREEN}⚡ 智能向导：一键安装/更新 dae 核心【完美保留现有配置】${NC}\n"
        printf " 2) ✍️ 交互配置：粘贴 Sub-Store 链接并生成流媒体/AI分流矩阵\n"
        printf " 3) 🔄 立即全量拉取更新本地 GEO 规则数据库文件\n"
        printf " 4) 🗓️ 规划配置：设定 Crontab 计划任务定时自动化洗刷 Geo 规则\n"
        printf " 5) ⚙️ 控制中心：查看 dae 服务运行看板与启动/重启/停止拦截\n"
        printf " 6) 🐳 独立沙盒：使用 Docker 特权提权链路容器化部署 dae\n"
        printf " 7) 🔔 外部联动：配置/修改企业微信运维通知推送 Webhook 密钥\n"
        printf " 8) 🔎 查看日志：实时滚动查看 dae 运行日志\n"
        printf " 9) ${RED}❌ 彻底卸载：从系统中完整移除 dae 及所有配置${NC}\n"
        printf " 0) 退出当前向导程序\n"
        printf "${GREEN}================================================================${NC}\n"
        printf "请输入数字选项 [0-9]："
        read -r choice
        case $choice in
            1) upgrade_dae_core ;;
            2)
                printf "${PURPLE}【✨ Sub-Store 操作指引】${NC}\n"
                printf "${YELLOW}请在 Sub-Store 复制「通用订阅」链接。${NC}\n"
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
                    print_service_live_status
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
                    1) clean_network_resources; manage_service "start"; print_service_live_status;;
                    2) manage_service "stop"; clean_network_resources; printf "${GREEN}已安全完成无痕撤消。${NC}\n";;
                    3) clean_network_resources; manage_service "restart"; print_service_live_status;;
                    4) manage_service "status";;
                esac
                ;;
            6) install_dae_docker ;;
            7)
                printf "请粘贴企业微信群机器人的 Webhook 完整 URL (留空则取消): "
                read -r input_wx
                WECHAT_WEBHOOK="$input_wx"
                save_env "WECHAT_WEBHOOK" "$WECHAT_WEBHOOK"
                if [ -n "$input_wx" ]; then
                    printf "${GREEN}通知通道已固化绑定。${NC}\n"
                else
                    printf "${YELLOW}通知通道已解绑。${NC}\n"
                fi
                ;;
            8)
                if [ -f "$LOG_FILE" ]; then
                    printf "${YELLOW}正在实时滚动显示日志，按 Ctrl+C 退出...${NC}\n"
                    tail -f "$LOG_FILE"
                else
                    printf "${RED}日志文件 %s 不存在。${NC}\n" "$LOG_FILE"
                fi
                ;;
            9) uninstall_dae ;;
            0) printf "${GREEN}退出程序。祝您网络畅通！${NC}\n"; exit 0 ;;
            *) printf "${RED}输入有误，请输入0-9之间的有效编号。${NC}\n" ;;
        esac
        printf "${CYAN}按 Enter 键返回主菜单...${NC}"
        read -r
    done
}

# 挂载运行入口
main_menu
