#!/bin/bash
# ============== 颜色定义 ==============
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# ============== 全局配置 ==============
SCRIPT_VERSION="1.0"
CONFIG_DIR="/etc/nezha-deploy"
CONFIG_FILE="$CONFIG_DIR/config.conf"
LOG_FILE="$CONFIG_DIR/deploy.log"
NETWORK_INFO_FILE="$CONFIG_DIR/network_info"
DOCKER_CONFIG="/etc/docker/daemon.json"

# ============== 核心基础函数 (彻底解决乱码与文件报错) ==============
init_env() {
    mkdir -p "$CONFIG_DIR" 2>/dev/null
    touch "$LOG_FILE" 2>/dev/null
}

# 屏幕与文件分离写入，杜绝底层 tee 缓冲引发的拼字乱码
log() { init_env; echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $1"; echo "[$(date '+%H:%M:%S')] $1" >> "$LOG_FILE"; }
warn() { init_env; echo -e "${YELLOW}[警告]${NC} $1"; echo "[警告] $1" >> "$LOG_FILE"; }
err() { init_env; echo -e "${RED}[错误]${NC} $1"; echo "[错误] $1" >> "$LOG_FILE"; }
info() { init_env; echo -e "${BLUE}[信息]${NC} $1"; echo "[信息] $1" >> "$LOG_FILE"; }

check_root() {
    if [ "$EUID" -ne 0 ]; then
        err "请使用 sudo 或 root 运行此脚本"
        exit 1
    fi
}

# ============== HTTP 穿透级强力对时 (绕过NTP屏蔽与SSL报错) ==============
sync_time() {
    info "正在强制同步系统真实时间 (在公网模式下尤为重要)..."
    
    HTTP_DATE=$(curl -sI --max-time 5 http://www.baidu.com | grep -i '^date:' | sed 's/^[Dd]ate: //g' | tr -d '\r')
    
    if [ -n "$HTTP_DATE" ]; then
        date -s "$HTTP_DATE" >/dev/null 2>&1
        log "利用 HTTP 请求强制时间校准成功！"
    else
        warn "HTTP 对时失败，尝试降级使用 NTP 服务..."
        if command -v ntpdate &>/dev/null; then
            ntpdate pool.ntp.org >/dev/null 2>&1 || true
        else
            (apt-get update -y >/dev/null 2>&1 && apt-get install ntpdate -y >/dev/null 2>&1) || (yum install ntpdate -y >/dev/null 2>&1)
            ntpdate pool.ntp.org >/dev/null 2>&1 || true
        fi
    fi
    log "当前系统真实时间: $(date)"
}

# ============== 网络智能检测模块 ==============
detect_network() {
    init_env
    echo -e "\n${CYAN}╔════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║   ${BOLD}开始网络环境智能检测...${NC}${CYAN}              ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
    
    HAS_IPV4_PUBLIC="no"
    HAS_IPV6_PUBLIC="no"
    IPV4_ADDR=""
    IPV6_ADDR=""
    
    info "检测 IPv4 公网地址..."
    IPV4_ADDR=$(curl -4 -sS --max-time 8 https://api.ipify.org 2>/dev/null || \
                curl -4 -sS --max-time 8 https://ifconfig.me 2>/dev/null || \
                curl -4 -sS --max-time 8 https://ipv4.icanhazip.com 2>/dev/null || true)
    
    if [ -n "$IPV4_ADDR" ]; then
        if [[ ! "$IPV4_ADDR" =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.|127\.) ]]; then
            HAS_IPV4_PUBLIC="yes"
            log "✓ 检测到 IPv4 公网: $IPV4_ADDR"
        else
            log "✗ IPv4 是私网地址: $IPV4_ADDR"
            IPV4_ADDR=""
        fi
    else
        log "✗ 无法获取 IPv4 公网地址"
    fi
    
    info "检测 IPv6 公网地址..."
    IPV6_ADDR=$(curl -6 -sS --max-time 8 https://api64.ipify.org 2>/dev/null || \
                curl -6 -sS --max-time 8 https://ifconfig.co 2>/dev/null || \
                ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2}' | cut -d/ -f1 | head -1 || true)
    
    if [ -n "$IPV6_ADDR" ] && [[ "$IPV6_ADDR" =~ ^([0-9a-fA-F]{1,4}:){2,7} ]]; then
        if [[ ! "$IPV6_ADDR" =~ ^fe80: ]]; then
            HAS_IPV6_PUBLIC="yes"
            log "✓ 检测到 IPv6 公网: $IPV6_ADDR"
        else
            log "✗ IPv6 是链路本地地址: $IPV6_ADDR"
            IPV6_ADDR=""
        fi
    else
        log "✗ 无法获取 IPv6 公网地址"
    fi
    
    cat > "$NETWORK_INFO_FILE" <<EOF
HAS_IPV4_PUBLIC=$HAS_IPV4_PUBLIC
HAS_IPV6_PUBLIC=$HAS_IPV6_PUBLIC
IPV4_ADDR=$IPV4_ADDR
IPV6_ADDR=$IPV6_ADDR
DETECT_TIME=$(date +%s)
EOF
    
    echo -e "\n${PURPLE}══════════ 网络诊断报告 ══════════${NC}"
    echo -e "  IPv4 公网: $([ "$HAS_IPV4_PUBLIC" = "yes" ] && echo -e "${GREEN}✓ 可用${NC}" || echo -e "${RED}✗ 不可用${NC}")"
    echo -e "  IPv6 公网: $([ "$HAS_IPV6_PUBLIC" = "yes" ] && echo -e "${GREEN}✓ 可用${NC}" || echo -e "${RED}✗ 不可用${NC}")"
    
    info "验证 Cloudflare 连通性..."
    CF_STATUS=$(curl -4 -sS -o /dev/null -w "%{http_code}" --max-time 8 https://api.cloudflare.com/ || echo "000")
    if [[ "$CF_STATUS" =~ ^(200|403)$ ]]; then
        log "✓ Cloudflare API 可达"
    else
        warn "Cloudflare API 状态码: $CF_STATUS, 可能影响自动DNS配置"
    fi
}

# ============== 通用 Docker 安装 (含智能IPv6配置) ==============
install_docker() {
    init_env
    if command -v docker &>/dev/null; then
        log "Docker 已安装: $(docker --version)"
    else
        info "正在为您自动安装 Docker 环境 (请耐心等待)..."
        curl -fsSL https://get.docker.com | bash 2>&1 | tee -a "$LOG_FILE"
        systemctl start docker 2>/dev/null || true
        systemctl enable docker 2>/dev/null || true
    fi
    
    mkdir -p /etc/docker
    if [ ! -f "$DOCKER_CONFIG" ]; then
        if ip -6 addr show scope global | grep -q inet6; then
            warn "检测到主机支持IPv6，将为Docker启用IPv6支持以获得最佳性能。"
            cat > "$DOCKER_CONFIG" <<'EOF'
{
  "ipv6": true,
  "fixed-cidr-v6": "2001:db8:1::/64"
}
EOF
            info "正在重启Docker以应用IPv6配置..."
            systemctl restart docker 2>/dev/null || { err "重启Docker失败，IPv6配置可能不兼容，已回滚"; rm -f "$DOCKER_CONFIG"; }
            sleep 3
        fi
    fi
    log "Docker 环境配置完成！"
}

# ============== Cloudflare API 通信模块 (公网模式专用) ==============
cf_api() {
    local method=$1 path=$2 data=$3
    if [ -n "$data" ]; then
        curl -4 -sS --max-time 15 -X "$method" "https://api.cloudflare.com/client/v4${path}" \
            -H "Authorization: Bearer ${CF_API_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "${data}"
    else
        curl -4 -sS --max-time 15 -X "$method" "https://api.cloudflare.com/client/v4${path}" \
            -H "Authorization: Bearer ${CF_API_TOKEN}" \
            -H "Content-Type: application/json"
    fi
}

cf_get_zone_id() {
    local domain=$1
    local response=$(cf_api GET "/zones?name=${domain}")
    echo "$response" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4
}

cf_get_record() {
    local zone_id=$1 name=$2 type=$3
    cf_api GET "/zones/${zone_id}/dns_records?name=${name}&type=${type}" | \
        grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4
}

cf_create_record() {
    local zone_id=$1 type=$2 name=$3 content=$4 proxied=$5
    local data="{\"type\":\"${type}\",\"name\":\"${name}\",\"content\":\"${content}\",\"proxied\":${proxied},\"ttl\":1,\"comment\":\"Nezha auto-deploy by script v${SCRIPT_VERSION}\"}"
    local resp=$(cf_api POST "/zones/${zone_id}/dns_records" "$data")
    if echo "$resp" | grep -q '"success":true'; then
        log "✓ DNS 记录注册成功: ${name} -> ${content}"
        return 0
    else
        err "DNS 创建失败，API返回报错: $resp"
        return 1
    fi
}

cf_update_record() {
    local zone_id=$1 record_id=$2 type=$3 name=$4 content=$5 proxied=$6
    local data="{\"type\":\"${type}\",\"name\":\"${name}\",\"content\":\"${content}\",\"proxied\":${proxied}}"
    local resp=$(cf_api PUT "/zones/${zone_id}/dns_records/${record_id}" "$data")
    if echo "$resp" | grep -q '"success":true'; then
        log "✓ DNS 记录更新成功"
        return 0
    else
        err "DNS 更新失败，API返回报错: $resp"
        return 1
    fi
}

configure_cloudflare() {
    init_env
    echo -e "\n${CYAN}═══ Cloudflare 自动配置向导 ═══${NC}"
    
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        if [ -n "$CF_FULL_DOMAIN" ] && [ -n "$CF_API_TOKEN" ]; then
            log "已发现历史配置: $CF_FULL_DOMAIN"
            read -rp "是否直接使用历史配置? [Y/n]: " USE_OLD
            if [[ "$USE_OLD" =~ ^([nN][oO]|[nN])$ ]]; then
                rm -f "$CONFIG_FILE"
            else
                return 0
            fi
        fi
    fi
    
    read -rp "请输入主域名 (例如: example.com): " CF_ROOT_DOMAIN
    while [[ -z "$CF_ROOT_DOMAIN" ]]; do
        read -rp "域名不能为空, 请重新输入: " CF_ROOT_DOMAIN
    done
    CF_ROOT_DOMAIN=$(echo "$CF_ROOT_DOMAIN" | sed -e 's|^[^/]*//||' -e 's|/.*$||' -e 's|^www\.||')
    
    read -rp "请输入你想使用的子域名前缀 (留空默认使用 nz): " CF_SUBDOMAIN
    CF_SUBDOMAIN=${CF_SUBDOMAIN:-nz}
    CF_FULL_DOMAIN="${CF_SUBDOMAIN}.${CF_ROOT_DOMAIN}"
    
    echo -e "\n${PURPLE}【保姆级教程：如何获取 Cloudflare API Token】${NC}"
    echo -e "1. 浏览器登录并打开: ${BOLD}https://dash.cloudflare.com/profile/api-tokens${NC}"
    echo -e "2. 点击右侧 ${GREEN}[创建令牌 (Create Token)]${NC}"
    echo -e "3. 在 ${BOLD}[自定义令牌 (Custom Token)]${NC} 模板旁，点击 ${GREEN}[开始使用 (Get started)]${NC}"
    echo -e "4. ${RED}★★ 最重要的一步 - 请务必添加以下两个权限 ★★${NC}:"
    echo -e "   权限一: [区域(Zone)] - ${BOLD}[区域(Zone)] - [读取(Read)]${NC}   <-- 不给这个权限会报错找不到ID"
    echo -e "   权限二: [区域(Zone)] - ${BOLD}[DNS] - [编辑(Edit)]${NC}         <-- 不给这个权限无法修改DNS"
    echo -e "5. ${BOLD}区域资源(Zone Resources)${NC} 选择: [包括(Include)] - [特定区域(Specific Zone)] - [选择你的域名]"
    echo -e "6. 点击继续，复制生成的那一串代码。"
    echo -e "--------------------------------------------------------"
    
    read -rp "请输入 Cloudflare API Token: " CF_API_TOKEN
    while [[ -z "$CF_API_TOKEN" ]]; do
        read -rp "Token 不能为空, 请重新输入: " CF_API_TOKEN
    done
    
    info "正在验证 API Token 网络连通性与有效性..."
    test_resp=$(cf_api GET "/user/tokens/verify" 2>&1)
    
    if echo "$test_resp" | grep -q "Could not resolve host\|Connection timed out\|Network is unreachable\|certificate is not yet valid"; then
        err "服务器无法连接 Cloudflare API！"
        warn "系统时间可能仍未同步，或设备被断网。请检查报错堆栈: $test_resp"
        return 1
    fi
    
    if ! echo "$test_resp" | grep -q '"status":"active"\|"success":true'; then
        err "API Token 验证失败，可能输入错误或权限不足！"
        return 1
    fi
    log "✓ API Token 验证通过"
    
    info "正在获取域名 ${CF_ROOT_DOMAIN} 的 Zone ID..."
    ZONE_ID=$(cf_get_zone_id "$CF_ROOT_DOMAIN")
    
    if [ -z "$ZONE_ID" ]; then
        PARENT_DOMAIN=$(echo "$CF_ROOT_DOMAIN" | cut -d. -f2-)
        if [ "$PARENT_DOMAIN" != "$CF_ROOT_DOMAIN" ] && [ -n "$PARENT_DOMAIN" ] && echo "$PARENT_DOMAIN" | grep -q "\."; then
            info "找不到当前域，触发智能追溯，正在查找父域名 ${PARENT_DOMAIN} 的 Zone ID..."
            ZONE_ID=$(cf_get_zone_id "$PARENT_DOMAIN")
            if [ -n "$ZONE_ID" ]; then
                log "✓ 自动修正成功！成功捕获顶级域名 Zone ID: $ZONE_ID"
                CF_ROOT_DOMAIN="$PARENT_DOMAIN"
                CF_SUBDOMAIN="${CF_FULL_DOMAIN%.$CF_ROOT_DOMAIN}"
                CF_SUBDOMAIN="${CF_SUBDOMAIN%.}"
            fi
        fi
    fi
    
    if [ -z "$ZONE_ID" ]; then
        err "最终无法获取到 Zone ID! 请确认 Token 的权限是否包含了该域名。"
        return 1
    fi
    log "✓ Zone ID 捕获成功: $ZONE_ID"
    
    cat > "$CONFIG_FILE" <<EOF
CF_API_TOKEN=${CF_API_TOKEN}
CF_ROOT_DOMAIN=${CF_ROOT_DOMAIN}
CF_SUBDOMAIN=${CF_SUBDOMAIN}
CF_FULL_DOMAIN=${CF_FULL_DOMAIN}
ZONE_ID=${ZONE_ID}
EOF
    return 0
}

smart_dns_setup() {
    local record_type=$1 record_value=$2
    info "正在注册 DNS 记录: ${CF_FULL_DOMAIN} (${record_type}) -> ${record_value}"
    
    local existing_id=$(cf_get_record "$ZONE_ID" "${CF_SUBDOMAIN}.${CF_ROOT_DOMAIN}" "$record_type")
    if [ -n "$existing_id" ]; then
        log "发现历史 ${record_type} 记录, 正在执行强制更新..."
        cf_update_record "$ZONE_ID" "$existing_id" "$record_type" "${CF_SUBDOMAIN}.${CF_ROOT_DOMAIN}" "$record_value" "true"
    else
        log "未发现记录，正在创建全新 ${record_type} 记录..."
        cf_create_record "$ZONE_ID" "$record_type" "${CF_SUBDOMAIN}.${CF_ROOT_DOMAIN}" "$record_value" "true"
    fi
}

# ============== 端口与防火墙 (增强版) ==============
check_port_available() {
    local port=$1
    if command -v ss &>/dev/null; then
        if ss -tuln 2>/dev/null | grep -q ":${port} "; then return 1; fi
    elif command -v netstat &>/dev/null; then
        if netstat -tuln 2>/dev/null | grep -q ":${port} "; then return 1; fi
    fi
    return 0
}

get_available_port() {
    local port="$1"
    local max_attempts=100
    local attempt=0
    
    while true; do
        if check_port_available "$port"; then
            echo "$port"
            return 0
        fi
        port=$((port + 1))
        attempt=$((attempt + 1))
        if [ $attempt -gt $max_attempts ]; then
            echo ""
            return 1
        fi
    done
}

setup_firewall() {
    local web_port=$1 agent_port=$2
    info "正在智能配置系统防火墙放行规则..."
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port=${web_port}/tcp >/dev/null 2>&1
        firewall-cmd --permanent --add-port=${agent_port}/tcp >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    elif command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        ufw allow "${web_port}/tcp" comment "Nezha Web" 2>/dev/null || true
        ufw allow "${agent_port}/tcp" comment "Nezha Agent" 2>/dev/null || true
        ufw reload 2>/dev/null || true
    elif command -v iptables &>/dev/null; then
        iptables -I INPUT -p tcp --dport "$web_port" -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p tcp --dport "$agent_port" -j ACCEPT 2>/dev/null || true
        if command -v ip6tables &>/dev/null; then
           ip6tables -I INPUT -p tcp --dport "$web_port" -j ACCEPT 2>/dev/null || true
           ip6tables -I INPUT -p tcp --dport "$agent_port" -j ACCEPT 2>/dev/null || true
        fi
    fi
    log "✓ 防火墙已尝试放行 (Web:${web_port} Agent:${agent_port})。请注意，这不包括您的云服务商安全组或家庭路由器防火墙。"
}

# ============== 最终配置指南 (核心) ==============
display_final_instructions() {
    local mode=$1 domain=$2 agent_port=$3 host_ip=$4
    
    echo -e "\n${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                ${BOLD}🎉 部署完成 - 最后配置指南 🎉${NC}${CYAN}               ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"

    case $mode in
        "V3_LAN")
            echo -e "1. ${BOLD}访问面板:${NC}"
            echo -e "   在你的浏览器中打开: ${BOLD}http://${host_ip}:8008${NC}  (或 http://localhost:8008)"
            echo -e "   (首次访问需要设置管理员账号和密码)"
            echo -e "\n2. ${BOLD}登录后台后，进入 [设置] 页面，进行关键配置：${NC}"
            echo -e "   - ${GREEN}服务器IP/通讯域名${NC} 必须填写部署哪吒这台机器的【内网IP】: ${BOLD}${host_ip}${NC}"
            echo -e "   - ${GREEN}Agent 探针端口${NC} 必须填写: ${BOLD}${agent_port}${NC}"
            echo -e "   - ${RED}必须勾选${NC}: ${BOLD}[未接入 CDN]${NC} 或 ${BOLD}[未开启 TLS]${NC}"
            echo -e "\n3. ${BOLD}添加 Agent (探针):${NC}"
            echo -e "   在其他需要被监控的【局域网内】设备上，直接使用后台生成的一键安装命令即可。"
            echo -e "   (因为上一步已配置好内网IP，生成的命令天生就是为局域网准备的)"
            ;;
        "V1_DIRECT")
            echo -e "1. 浏览器打开你的面板后台: ${BOLD}https://${domain}${NC}"
            echo -e "   (使用 GitHub 账号登录)"
            echo -e "\n2. 进入 ${BOLD}[设置]${NC} 页面，找到 ${BOLD}[面板设置]${NC}，进行关键配置："
            echo -e "   - ${GREEN}服务器IP/通讯域名${NC} 必须填写你的域名: ${BOLD}${domain}${NC}"
            echo -e "   - ${GREEN}Agent 探针端口${NC} 必须填写: ${BOLD}${agent_port}${NC}"
            echo -e "   - ${RED}无需勾选${NC} [未接入 CDN] 或 [未开启 TLS]。"
            echo -e "\n3. ${BOLD}Agent 连接方式:${NC}"
            echo -e "   在其他需要被监控的机器上，复制后台生成的一键安装命令即可。Agent 会通过公网 (${domain}:${agent_port}) 连接回来。"
            ;;
        "V0_TUNNEL"|"V2_TUNNEL")
            echo -e "1. 浏览器打开你的面板后台: ${BOLD}https://${domain}${NC}"
            echo -e "   (使用 GitHub 账号登录)"
            echo -e "\n2. 进入 ${BOLD}[设置]${NC} 页面，找到 ${BOLD}[面板设置]${NC}，进行关键配置："
            echo -e "   - ${GREEN}服务器IP/通讯域名${NC} 必须填写你的域名: ${BOLD}${domain}${NC}"
            echo -e "   - ${GREEN}Agent 探针端口${NC} 必须填写: ${BOLD}${agent_port}${NC}"
            echo -e "   - ${RED}【非常重要】必须勾选${NC}: ${BOLD}[未接入 CDN]${NC} 或 ${BOLD}[未开启 TLS]${NC}"
            echo -e "     (因为 Agent 数据不走 CDN 隧道，勾选后才能正确生成不带TLS的连接命令)"
            
            echo -e "\n3. ${BOLD}Agent 连接方式 (请根据情况选择):${NC}"
            echo -e "   ${PURPLE}场景A: 监控家里或同一局域网内的其他设备 (例如: 另一台电脑, NAS)${NC}"
            echo -e "     - 在后台复制一键安装命令后，手动修改命令，将 ${domain} 替换为部署哪吒这台机器的【内网IP】(例如: ${host_ip})。"
            
            echo -e "\n   ${CYAN}场景B: 监控一个公网的VPS (高级用法)${NC}"
            echo -e "     - ${YELLOW}此模式下，隧道默认不转发 Agent 数据流。${NC}"
            echo -e "     - 你 ${BOLD}必须${NC} 在家里的【路由器】或【光猫】上，设置一条【端口转发】规则："
            echo -e "       ${BOLD}协议: TCP | 外部端口: ${agent_port} | 内部IP: ${host_ip} | 内部端口: ${agent_port}${NC}"
            echo -e "     - 设置好后，在公网VPS上可直接使用后台生成的一键安装命令（命令中的域名 ${domain} 会解析到你家宽带的公网IP，端口转发会把它指向哪吒）。"
            ;;
    esac
    
    echo -e "\n4. 保存设置后，你的哪吒监控系统就正式启用了！"
}

# ============== V0: Argo Nezha 全自动部署 ==============
v0_deploy() {
    init_env
    echo -e "\n${PURPLE}══════════════════════════════${NC}"
    echo -e "${PURPLE}  V0: Argo Nezha 一键部署模式${NC}"
    echo -e "${PURPLE}  适用场景: 任意网络环境(包含无公网的大内网)${NC}"
    echo -e "${PURPLE}══════════════════════════════${NC}"
    
    configure_cloudflare || return 1
    
    echo -e "\n${CYAN}═══ GitHub OAuth 配置指引 ═══${NC}"
    echo -e "1. 浏览器打开: ${BOLD}https://github.com/settings/developers${NC}"
    echo -e "2. 点击右上角 ${GREEN}[New OAuth App]${NC}"
    echo -e "3. Application name: 随意填写 (如 Nezha-Monitor)"
    echo -e "4. Homepage URL 填写: ${BOLD}https://${CF_FULL_DOMAIN}${NC}"
    echo -e "5. Authorization callback URL 填写: ${BOLD}https://${CF_FULL_DOMAIN}/oauth2/callback${NC}"
    echo -e "6. 注册后，生成并保存 Client ID 与 Client Secret。"
    echo -e "--------------------------------------------------------"
    
    read -rp "请输入您的 GitHub 用户名 (Github ID): " GH_USER
    read -rp "请输入 GitHub Client ID: " GH_CLIENTID
    read -rp "请输入 GitHub Client Secret: " GH_CLIENTSECRET
    
    echo -e "\n${CYAN}═══ Cloudflare Argo Tunnel Token ═══${NC}"
    echo -e "1) 使用您自己的 Cloudflare Tunnel Token (强烈推荐，域名固定稳定)"
    echo -e "2) 使用系统分配的临时隧道 (无需Token，但每次重启可能导致域名变化)"
    read -rp "请选择 [1/2, 默认1]: " ARGO_TYPE
    
    ARGO_AUTH=""
    if [ "$ARGO_TYPE" != "2" ]; then
        echo -e "\n${PURPLE}如何获取? 打开 https://one.dash.cloudflare.com/ -> Networks -> Tunnels 创建并复制 Token。${NC}"
        read -rp "请粘贴 Tunnel Token (包含 ey... 的长串): " ARGO_AUTH
    else
        ARGO_AUTH="Tunnel"
    fi
    
    install_docker
    info "开始拉取 fscarmen/argo-nezha 镜像 (网络慢请耐心等待)..."
    docker pull fscarmen/argo-nezha:latest >/dev/null 2>&1
    
    info "清理可能存在的旧容器..."
    docker stop argo-nezha 2>/dev/null || true
    docker rm argo-nezha 2>/dev/null || true
    
    # 注意：fscarmen/argo-nezha 内部默认 agent 端口是 5555
    AGENT_PORT=5555
    HOST_IP=$(hostname -I | awk '{print $1}')
    
    info "启动 Argo 隧道与面板混合容器..."
    docker run -d --name argo-nezha \
        --restart always \
        --network host \
        -e GH_USER="$GH_USER" \
        -e GH_CLIENTID="$GH_CLIENTID" \
        -e GH_CLIENTSECRET="$GH_CLIENTSECRET" \
        -e ARGO_AUTH="$ARGO_AUTH" \
        -e ARGO_DOMAIN="$CF_FULL_DOMAIN" \
        -e REVERSE_PROXY_MODE="caddy" \
        -e DASHBOARD_VERSION="v0.17.9" \
        fscarmen/argo-nezha:latest >/dev/null 2>&1
    
    sleep 10
    v0_verify "$CF_FULL_DOMAIN" "$AGENT_PORT" "$HOST_IP"
}

v0_verify() {
    local domain=$1 agent_port=$2 host_ip=$3
    echo -e "\n${CYAN}═══ V0 部署结果验证 ═══${NC}"
    info "隧道正在与 Cloudflare 边缘节点握手，请等待约 15 秒..."
    sleep 15
    docker ps --filter "name=argo-nezha" --format "table {{.Names}}\t{{.Status}}" || true
    
    HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 20 "https://${domain}" || echo "000")
    if [[ "$HTTP_CODE" =~ ^(200|301|302)$ ]]; then
        log "🎉 恭喜！外网已可正常连通！"
        display_final_instructions "V0_TUNNEL" "$domain" "$agent_port" "$host_ip"
    else
        warn "连通性测试返回 HTTP ${HTTP_CODE}。容器可能仍在后台启动中，请稍后刷新浏览器尝试。"
        warn "如果持续失败，请检查 Docker 日志: docker logs argo-nezha"
    fi
}

# ============== V1: 双栈直连原生部署 ==============
v1_deploy() {
    init_env
    echo -e "\n${PURPLE}══════════════════════════════${NC}"
    echo -e "${PURPLE}  V1: Nezha Dashboard 原生双栈直连部署${NC}"
    echo -e "${PURPLE}  适用场景: 拥有公网IPv4或IPv6，追求极致低延迟${NC}"
    echo -e "${PURPLE}══════════════════════════════${NC}"
    
    if [ ! -f "$NETWORK_INFO_FILE" ]; then detect_network; fi
    source "$NETWORK_INFO_FILE"
    
    configure_cloudflare || return 1
    
    WEB_PORT=$(get_available_port 8008)
    AGENT_PORT=$(get_available_port 5555)
    if [ -z "$WEB_PORT" ] || [ -z "$AGENT_PORT" ]; then err "系统无可用端口分配！"; return 1; fi
    log "系统已自动为您分配安全内网端口: Web面板=${WEB_PORT}, 探针Agent=${AGENT_PORT}"
    
    NET_MODE="1"
    if [ "$HAS_IPV4_PUBLIC" = "yes" ] || [ "$HAS_IPV6_PUBLIC" = "yes" ]; then
        echo -e "\n请选择 Docker 网络挂载模式:"
        echo "1) bridge 桥接 + 端口映射 (极度推荐, 支持 IPv4+IPv6 独立双栈监听)"
        echo "2) host (容器与主机完全共享网络栈，高危但省事)"
        read -rp "请选择 [1/2, 默认1]: " NET_MODE
        NET_MODE=${NET_MODE:-1}
    fi
    
    echo -e "\n${CYAN}═══ 开始执行智能自动化部署 ═══${NC}"
    if [ "$HAS_IPV4_PUBLIC" = "yes" ] && [ -n "$IPV4_ADDR" ]; then
        smart_dns_setup "A" "$IPV4_ADDR"
    else
        warn "当前环境不具备可用 IPv4 公网，已自动跳过 A 记录注册"
    fi
    
    if [ "$HAS_IPV6_PUBLIC" = "yes" ] && [ -n "$IPV6_ADDR" ]; then
        smart_dns_setup "AAAA" "$IPV6_ADDR"
    else
        warn "当前环境不具备可用 IPv6 公网，已自动跳过 AAAA 记录注册"
    fi
    
    setup_firewall "$WEB_PORT" "$AGENT_PORT"
    install_docker
    
    info "拉取 Nezha 官方源镜像..."
    docker pull ghcr.io/nezhahq/nezha:latest >/dev/null 2>&1
    
    info "清理环境残留..."
    docker stop nezha-dashboard 2>/dev/null || true
    docker rm nezha-dashboard 2>/dev/null || true
    
    DATA_DIR="/opt/nezha/dashboard"
    mkdir -p "$DATA_DIR"; chown -R 1000:1000 "$DATA_DIR" 2>/dev/null || true
    
    info "正式启动 Nezha 核心容器..."
    if [ "$NET_MODE" == "2" ]; then
        docker run -d --name nezha-dashboard --restart unless-stopped --network host \
            -v "$DATA_DIR:/dashboard/data" -v /etc/localtime:/etc/localtime:ro \
            -e TZ="Asia/Shanghai" -e PORT="$WEB_PORT" ghcr.io/nezhahq/nezha:latest >/dev/null 2>&1
    else
        docker run -d --name nezha-dashboard --restart unless-stopped \
            -p "${WEB_PORT}:8008" -p "${AGENT_PORT}:5555" \
            -v "$DATA_DIR:/dashboard/data" -v /etc/localtime:/etc/localtime:ro \
            -e TZ="Asia/Shanghai" -e PORT="$WEB_PORT" ghcr.io/nezhahq/nezha:latest >/dev/null 2>&1
    fi
    
    sleep 8
    v1_verify "$CF_FULL_DOMAIN" "$WEB_PORT" "$AGENT_PORT"
}

v1_verify() {
    local domain=$1 web_port=$2 agent_port=$3
    echo -e "\n${CYAN}═══ V1 部署连通性综合验证 ═══${NC}"
    docker ps --filter "name=nezha-dashboard" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" || true
    
    info "执行本地环回测试..."
    local local_ip="127.0.0.1"
    if [ -f "$NETWORK_INFO_FILE" ]; then
        source "$NETWORK_INFO_FILE"
        [ "$HAS_IPV6_PUBLIC" = "yes" ] && local_ip="::1"
    fi
    
    LOCAL_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://${local_ip}:${web_port}" || echo "000")
    if [ "$LOCAL_STATUS" != "000" ] && [ "$LOCAL_STATUS" != "404" ]; then log "✓ 本地连通正常 (HTTP ${LOCAL_STATUS})"; fi
    
    info "等待 Cloudflare CDN 全球广播生效 (约 5 秒)..."
    sleep 5
    A_RECORD=$(dig +short A "$domain" 2>/dev/null | head -1 || true)
    AAAA_RECORD=$(dig +short AAAA "$domain" 2>/dev/null | head -1 || true)
    [ -n "$A_RECORD" ] && log "✓ CF A 记录查询成功: $A_RECORD"
    [ -n "$AAAA_RECORD" ] && log "✓ CF AAAA 记录查询成功: $AAAA_RECORD"
    
    info "执行外网边缘节点 HTTPS 穿透测试..."
    sleep 3
    CF_RESULT=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 25 "https://${domain}" || echo "000")
    if [[ "$CF_RESULT" =~ ^(200|301|302|404)$ ]]; then
        if [ "$CF_RESULT" = "200" ]; then
            log "🎉 恭喜！外网访问链路彻底打通！"
            display_final_instructions "V1_DIRECT" "$domain" "$agent_port"
        else
            warn "CF 节点已响应，但状态码为 $CF_RESULT (正常现象，请登录后台配置)"
            display_final_instructions "V1_DIRECT" "$domain" "$agent_port"
        fi
    else
        warn "外网直接访问失败 (HTTP $CF_RESULT)！"
        warn "${RED}请立即排查：您家中的【光猫或路由器】防火墙，是否已将外网的 ${web_port} 和 ${agent_port} 端口，【端口转发】到本机的IP地址？${NC}"
    fi
}

# ============== V2: Cloudflared 官方分离隧道部署 ==============
v2_deploy() {
    init_env
    echo -e "\n${PURPLE}══════════════════════════════${NC}"
    echo -e "${PURPLE}  V2: 网页端托管分离隧道部署${NC}"
    echo -e "${PURPLE}  适用场景: 无公网IP，不想搞复杂的 OAuth 配置，追求绝对稳定${NC}"
    echo -e "${PURPLE}══════════════════════════════${NC}"
    
    WEB_PORT=$(get_available_port 8008)
    AGENT_PORT=$(get_available_port 5555)
    if [ -z "$WEB_PORT" ]; then err "系统端口被耗尽！"; exit 1; fi
    log "系统已预留内网核心通信端口: 面板端=${WEB_PORT}, 探针端=${AGENT_PORT}"
    
    echo -e "\n${CYAN}═══ Cloudflare 隧道强制绑定 ═══${NC}"
    echo -e "${PURPLE}【说明】本模式依托您在 Zero Trust 网页端配置的路由规则，极度稳定！${NC}"
    echo -e "1. 浏览器登录并打开: ${BOLD}https://one.dash.cloudflare.com/${NC}"
    echo -e "2. 依次展开左侧菜单: ${GREEN}[Networks]${NC} -> ${GREEN}[Tunnels]${NC} -> ${GREEN}[Create a tunnel]${NC}"
    echo -e "3. 根据引导随便起个名字并保存，你将看到一条包含 ${BOLD}ey...${NC} 长代码的安装命令。"
    echo -e "--------------------------------------------------------"
    read -rp "请在此粘贴提取出的 Tunnel Token: " CF_TUNNEL_TOKEN
    while [[ -z "$CF_TUNNEL_TOKEN" ]]; do
        read -rp "Token 不能为空, 请重试: " CF_TUNNEL_TOKEN
    done
    
    install_docker
    info "清理过期的容器环境..."
    docker stop nezha-dashboard cloudflared 2>/dev/null || true
    docker rm nezha-dashboard cloudflared 2>/dev/null || true
    
    DATA_DIR="/opt/nezha/dashboard"
    mkdir -p "$DATA_DIR"; chown -R 1000:1000 "$DATA_DIR" 2>/dev/null || true
    
    info "启动 Nezha 核心管控系统..."
    docker run -d --name nezha-dashboard \
        --restart unless-stopped \
        -p "${WEB_PORT}:8008" \
        -p "${AGENT_PORT}:5555" \
        -v "$DATA_DIR:/dashboard/data" \
        -v /etc/localtime:/etc/localtime:ro \
        -e TZ="Asia/Shanghai" \
        ghcr.io/nezhahq/nezha:latest >/dev/null 2>&1
    
    info "植入 Cloudflared 安全隧道组件 (强行挂载 HTTP2 协议突破网络封锁)..."
    docker pull cloudflare/cloudflared:latest >/dev/null 2>&1
    
    docker run -d --name cloudflared \
        --restart always \
        --network host \
        -e TUNNEL_TRANSPORT_PROTOCOL="http2" \
        cloudflare/cloudflared:latest \
        tunnel --no-autoupdate run --token "$CF_TUNNEL_TOKEN" >/dev/null 2>&1
    
    sleep 6
    echo -e "\n${CYAN}═══ 边缘节点握手验证 ═══${NC}"
    LOG_CHECK=$(docker logs cloudflared 2>&1 | grep "Registered tunnel connection")
    HOST_IP=$(hostname -I | awk '{print $1}')

    if [ -n "$LOG_CHECK" ]; then
        log "🎉 万岁！隧道底层已与 Cloudflare 全球边缘节点建立高度加密连接！"
        echo -e "\n${YELLOW}【⚠️ 极其重要的最后一步：网页配置 ⚠️】${NC}"
        echo -e "要让外部能访问到面板，请务必回到 Cloudflare 网页端的 Tunnel 配置项："
        echo -e "1. 找到你刚创建的隧道，点击 ${BOLD}[Configure]${NC}."
        echo -e "2. 切换到 ${BOLD}[Public Hostname]${NC} 标签页, 点击 ${BOLD}[Add a public hostname]${NC}."
        echo -e "3. ${GREEN}Subdomain/Domain${NC}: 填写你想用来访问的域名 (例如: nz.example.com)."
        echo -e "4. ${GREEN}Service Type${NC} (服务类型) 必须选: ${BOLD}HTTP${NC}"
        echo -e "5. ${GREEN}URL${NC} (目标地址) 必须填: ${BOLD}localhost:${WEB_PORT}${NC}"
        echo -e "6. 保存后，稍等片刻，然后用你填写的域名访问。"
        echo -e "--------------------------------------------------------"
        read -rp "请在此输入你刚刚在Cloudflare上配置好的域名 (例如: nz.example.com): " TUNNEL_DOMAIN
        display_final_instructions "V2_TUNNEL" "$TUNNEL_DOMAIN" "$AGENT_PORT" "$HOST_IP"
    else
        warn "检测不到底层隧道回包，可能是被深度包检测拦截，以下是报错堆栈："
        docker logs --tail 15 cloudflared
    fi
}

# ============== V3: 纯局域网部署 ==============
v3_deploy_lan() {
    init_env
    echo -e "\n${PURPLE}══════════════════════════════${NC}"
    echo -e "${PURPLE}  V3: 纯局域网模式部署 (零外部依赖)${NC}"
    echo -e "${PURPLE}  适用场景: 只想在家里或公司内网使用，不暴露到公网${NC}"
    echo -e "${PURPLE}══════════════════════════════${NC}"
    
    install_docker

    WEB_PORT=8008
    AGENT_PORT=5555
    HOST_IP=$(hostname -I | awk '{print $1}')
    if [ -z "$HOST_IP" ]; then
        err "无法获取本机内网IP地址，请检查网络配置！"
        return 1
    fi
    log "本机内网IP为: ${HOST_IP}"

    if ! check_port_available "$WEB_PORT"; then
        warn "端口 ${WEB_PORT} 已被占用。脚本将尝试重用现有面板。"
    fi
    if ! check_port_available "$AGENT_PORT"; then
        warn "端口 ${AGENT_PORT} 已被占用。脚本将尝试重用现有面板。"
    fi

    info "清理可能存在的旧容器..."
    docker stop nezha-dashboard 2>/dev/null || true
    docker rm nezha-dashboard 2>/dev/null || true

    info "拉取 Nezha 官方源镜像..."
    docker pull ghcr.io/nezhahq/nezha:latest >/dev/null 2>&1
    
    DATA_DIR="/opt/nezha/dashboard"
    mkdir -p "$DATA_DIR"; chown -R 1000:1000 "$DATA_DIR" 2>/dev/null || true

    info "正式启动 Nezha 核心容器..."
    docker run -d --name nezha-dashboard --restart unless-stopped \
        -p "127.0.0.1:${WEB_PORT}:8008" \
        -p "${HOST_IP}:${WEB_PORT}:8008" \
        -p "${AGENT_PORT}:5555" \
        -v "$DATA_DIR:/dashboard/data" \
        -v /etc/localtime:/etc/localtime:ro \
        -e TZ="Asia/Shanghai" \
        ghcr.io/nezhahq/nezha:latest >/dev/null 2>&1
        
    sleep 8
    
    echo -e "\n${CYAN}═══ V3 部署结果验证 ═══${NC}"
    if docker ps --filter "name=nezha-dashboard" --format "{{.Names}}" | grep -q "nezha-dashboard"; then
        log "🎉 恭喜！Nezha 面板容器已成功启动！"
        docker ps --filter "name=nezha-dashboard" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
        display_final_instructions "V3_LAN" "" "$AGENT_PORT" "$HOST_IP"
    else
        err "容器启动失败！请检查 Docker 日志以排查问题："
        echo -e "${RED}docker logs nezha-dashboard${NC}"
    fi
}

# ============== 智能推荐雷达 ==============
smart_recommend() {
    init_env
    if [ ! -f "$NETWORK_INFO_FILE" ]; then detect_network; fi
    source "$NETWORK_INFO_FILE"
    
    echo -e "\n${CYAN}╔════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         ${BOLD}智能 AI 部署方案推荐雷达${NC}${CYAN}            ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════╝${NC}"
    
    if [ "$HAS_IPV4_PUBLIC" = "yes" ] || [ "$HAS_IPV6_PUBLIC" = "yes" ]; then
        echo -e "检测到您处于: ${GREEN}公网环境${NC}"
        echo -e "雷达建议方案: ${GREEN}★ 选择 V1 公网直连部署${NC} (跑满原生带宽，探针数据零延迟)"
    else
        echo -e "检测到您处于: ${YELLOW}深层大内网环境 (无任何公网暴露能力)${NC}"
        echo -e "雷达建议方案:"
        echo -e "  > ${GREEN}追求稳定与灵活性?${NC} 选择 V2 云隧道穿透模式 (官方推荐)。"
        echo -e "  > ${BLUE}想一个容器搞定所有?${NC} 选择 V0 混合隧道模式 (老牌方案)。"
    fi
    echo ""
}

# ============== 暴力清理 (增强版) ==============
uninstall_nezha() {
    init_env
    warn "执行该操作将把哪吒面板系统从当前主机连根拔起！"
    read -rp "您确定要继续吗? [y/N]: " CONFIRM
    if [[ "$CONFIRM" =~ ^[yY] ]]; then
        info "正在关闭并销毁容器组..."
        for c in argo-nezha nezha-dashboard cloudflared; do
            docker stop $c >/dev/null 2>&1 || true
            docker rm $c >/dev/null 2>&1 || true
        done
        
        info "正在清理相关的 Docker 镜像..."
        docker rmi fscarmen/argo-nezha:latest >/dev/null 2>&1 || true
        docker rmi ghcr.io/nezhahq/nezha:latest >/dev/null 2>&1 || true
        docker rmi cloudflare/cloudflared:latest >/dev/null 2>&1 || true

        info "正在抹除持久化数据与环境变量..."
        rm -rf /opt/nezha "$CONFIG_DIR" >/dev/null 2>&1 || true
        init_env
        log "执行完毕！系统已恢复出厂纯净态。"
    else
        log "操作已由用户手动撤销。"
    fi
}

# ============== 中枢调度主菜单 ==============
main_menu() {
    check_root
    sync_time # 全局时间校准，确保所有操作时间戳正确
    
    while true; do
        init_env
        echo -e "\n${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║     ${BOLD}哪吒探针全维态·智能融合部署系统 v${SCRIPT_VERSION}${NC}             ║${NC}"
        echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
        echo -e " ${PURPLE}--- 纯局域网 / 内网模式 ---${NC}"
        echo -e "  ${GREEN}3)${NC} ${BOLD}V3 纯局域网部署${NC} ${YELLOW}(推荐! 无需任何公网/域名，开箱即用)${NC}"
        echo -e "\n ${CYAN}--- 公网 / 互联网模式 ---${NC}"
        echo -e "  ${GREEN}1)${NC} 扫描当前主机的外网暴露面 (部署公网模式前必看)"
        echo -e "  ${GREEN}2)${NC} ${BOLD}V1 公网直连部署${NC} ${YELLOW}(有公网IP，追求性能首选)${NC}"
        echo -e "  ${GREEN}4)${NC} V2 Cloudflared官方隧道部署 ${YELLOW}(无公网IP，最稳定穿透方案)${NC}"
        echo -e "  ${GREEN}5)${NC} V0 Argo混合隧道部署 ${YELLOW}(老牌内网穿透方案，适合怀旧)${NC}"
        echo -e "\n ${BLUE}--- 辅助功能 ---${NC}"
        echo -e "  ${GREEN}6)${NC} ${BOLD}一键无脑自动部署${NC} ${PURPLE}<< 让系统帮你选公网方案${NC}"
        echo -e "  ${GREEN}7)${NC} 观测 Docker 底层运行与日志矩阵"
        echo -e "  ${GREEN}8)${NC} 执行系统清理 (重装前必点)"
        echo -e "  ${RED}0)${NC} 离开系统"
        echo ""
        read -rp "请输入指令执行序列 [0-8]: " CHOICE
        
        case $CHOICE in
            1) detect_network ;;
            2) [ ! -f "$NETWORK_INFO_FILE" ] && detect_network; v1_deploy ;;
            3) v3_deploy_lan ;;
            4) v2_deploy ;;
            5) v0_deploy ;;
            6)
                detect_network
                smart_recommend
                read -rp "看完上面的分析，想用高性能 V1 直连请输入 1，想用无脑 V2 隧道穿透请输入 2。 [1/2]: " AUTO_CHOICE
                if [[ "$AUTO_CHOICE" == "2" ]]; then v2_deploy; else v1_deploy; fi
                ;;
            7)
                echo -e "\n${BLUE}【Docker 底层存活矩阵】${NC}"
                docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" || true
                echo -e "\n${BLUE}【网卡环境快照缓存】${NC}"
                [ -f "$NETWORK_INFO_FILE" ] && cat "$NETWORK_INFO_FILE" || echo "缓存为空"
                ;;
            8) uninstall_nezha ;;
            0) log "指令下线，后会有期！"; exit 0 ;;
            *) err "不合法的指令调度，请重新输入" ;;
        esac
    done
}

# 开始执行
main_menu
