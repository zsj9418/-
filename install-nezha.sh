#!/bin/bash
# ============================================================
#  Nezha Smart Deploy v2.5 - 满血完全体修复版
#  包含: 100% 全功能 + API 网络强制 IPv4 修复 + 智能域名追溯
# ============================================================

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
SCRIPT_VERSION="2.5"
CONFIG_DIR="/etc/nezha-deploy"
CONFIG_FILE="$CONFIG_DIR/config.conf"
LOG_FILE="$CONFIG_DIR/deploy.log"
NETWORK_INFO_FILE="$CONFIG_DIR/network_info"
DOCKER_CONFIG="/etc/docker/daemon.json"

mkdir -p "$CONFIG_DIR" 2>/dev/null

# ============== 工具函数 ==============
log() { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[警告]${NC} $1" | tee -a "$LOG_FILE"; }
err() { echo -e "${RED}[错误]${NC} $1" | tee -a "$LOG_FILE"; }
info() { echo -e "${BLUE}[信息]${NC} $1" | tee -a "$LOG_FILE"; }

check_root() {
    if [ "$EUID" -ne 0 ]; then
        err "请使用 sudo 或 root 运行此脚本"
        exit 1
    fi
}

# ============== 网络智能检测模块 ==============
detect_network() {
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
    # 强制 IPv4 防止机顶盒网络卡死
    CF_STATUS=$(curl -4 -sS -o /dev/null -w "%{http_code}" --max-time 8 https://api.cloudflare.com/ || echo "000")
    if [[ "$CF_STATUS" =~ ^(200|403)$ ]]; then
        log "✓ Cloudflare API 可达"
    else
        warn "Cloudflare API 状态码: $CF_STATUS, 可能影响自动DNS配置"
    fi
}

# ============== 通用 Docker 安装 ==============
install_docker() {
    if command -v docker &>/dev/null; then
        log "Docker 已安装: $(docker --version)"
        return 0
    fi
    
    log "正在安装 Docker..."
    curl -fsSL https://get.docker.com | bash 2>&1 | tee -a "$LOG_FILE"
    systemctl start docker 2>/dev/null || true
    systemctl enable docker 2>/dev/null || true
    
    mkdir -p /etc/docker
    if [ ! -f "$DOCKER_CONFIG" ]; then
        cat > "$DOCKER_CONFIG" <<'EOF'
{
  "ipv6": true,
  "fixed-cidr-v6": "2001:db8:1::/64",
  "ip6tables": true,
  "experimental": true,
  "ip-forward": true
}
EOF
        systemctl restart docker 2>/dev/null || true
        sleep 3
    fi
    log "Docker 安装完成"
}

# ============== Cloudflare API 客户端 (修复了强制IPv4防假死) ==============
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
    local response
    response=$(cf_api GET "/zones?name=${domain}")
    echo "$response" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4
}

cf_get_record() {
    local zone_id=$1 name=$2 type=$3
    cf_api GET "/zones/${zone_id}/dns_records?name=${name}&type=${type}" | \
        grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4
}

cf_create_record() {
    local zone_id=$1 type=$2 name=$3 content=$4 proxied=$5
    local data="{\"type\":\"${type}\",\"name\":\"${name}\",\"content\":\"${content}\",\"proxied\":${proxied},\"ttl\":1,\"comment\":\"Nezha auto-deploy\"}"
    local resp=$(cf_api POST "/zones/${zone_id}/dns_records" "$data")
    if echo "$resp" | grep -q '"success":true'; then
        log "✓ DNS 记录创建成功: ${name} -> ${content}"
        return 0
    else
        err "DNS 创建失败: $resp"
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
        err "DNS 更新失败: $resp"
        return 1
    fi
}

# ============== Cloudflare 智能配置向导 (带有自动查父域名功能) ==============
configure_cloudflare() {
    echo -e "\n${CYAN}═══ Cloudflare 自动配置 ═══${NC}"
    
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        if [ -n "$CF_FULL_DOMAIN" ] && [ -n "$CF_API_TOKEN" ]; then
            log "已加载历史Cloudflare配置: $CF_FULL_DOMAIN"
            read -rp "是否使用历史配置? [Y/n]: " USE_OLD
            if [[ "$USE_OLD" =~ ^([nN][oO]|[nN])$ ]]; then
                rm -f "$CONFIG_FILE"
            else
                return 0
            fi
        fi
    fi
    
    read -rp "请输入主域名 (只填纯域名): " CF_ROOT_DOMAIN
    while [[ -z "$CF_ROOT_DOMAIN" ]]; do
        read -rp "域名不能为空, 请重新输入: " CF_ROOT_DOMAIN
    done
    # 自动清理输入错误
    CF_ROOT_DOMAIN=$(echo "$CF_ROOT_DOMAIN" | sed -e 's|^[^/]*//||' -e 's|/.*$||' -e 's|^www\.||')
    
    read -rp "请输入子域名 (留空使用 nz, 完整域名将为 nz.$CF_ROOT_DOMAIN): " CF_SUBDOMAIN
    CF_SUBDOMAIN=${CF_SUBDOMAIN:-nz}
    CF_FULL_DOMAIN="${CF_SUBDOMAIN}.${CF_ROOT_DOMAIN}"
    
    echo -e "\n${PURPLE}【如何获取 Cloudflare API Token】${NC}"
    echo -e "1. 浏览器打开并登录: ${BOLD}https://dash.cloudflare.com/profile/api-tokens${NC}"
    echo -e "2. 点击 ${GREEN}[创建令牌 (Create Token)]${NC} -> 拉到最下方点击 ${GREEN}[自定义令牌 (Custom Token)]${NC}"
    echo -e "3. ${RED}★★ 最重要的一步 - 请务必添加以下两个权限 ★★${NC}:"
    echo -e "   第 1 行: [区域(Zone)] - ${BOLD}[区域(Zone)] - [读取(Read)]${NC}   <-- 获取域名ID必需"
    echo -e "   第 2 行: [区域(Zone)] - ${BOLD}[DNS] - [编辑(Edit)]${NC}         <-- 修改DNS解析必需"
    echo -e "4. ${BOLD}区域资源(Zone Resources)${NC} 选择: [包括(Include)] - [特定区域(Specific Zone)] - [选择你的域名]"
    echo -e "5. 点击继续并创建，复制那一串代码。"
    echo -e "--------------------------------------------------------"
    
    read -rp "请输入获取到的 Cloudflare API Token: " CF_API_TOKEN
    while [[ -z "$CF_API_TOKEN" ]]; do
        read -rp "API Token 不能为空, 请重新输入: " CF_API_TOKEN
    done
    
    # 【核心修复】先验证 Token 的连通性和有效性
    info "正在验证 API Token 网络连通性与有效性..."
    test_resp=$(cf_api GET "/user/tokens/verify" 2>&1)
    
    if echo "$test_resp" | grep -q "Could not resolve host\|Connection timed out\|Network is unreachable"; then
        err "服务器无法连接 Cloudflare API！"
        echo -e "${YELLOW}底层报错: $test_resp${NC}"
        warn "请检查你的设备能否正常访问外网(DNS是否正确)。"
        return 1
    fi
    
    if ! echo "$test_resp" | grep -q '"status":"active"\|"success":true'; then
        err "API Token 验证失败，可能失效或权限不足！"
        echo -e "${YELLOW}API返回: $test_resp${NC}"
        return 1
    fi
    log "✓ API Token 验证通过"
    
    # 【核心修复】智能获取 Zone ID 与 域名自动追溯
    info "正在获取域名 ${CF_ROOT_DOMAIN} 的 Zone ID..."
    ZONE_ID=$(cf_get_zone_id "$CF_ROOT_DOMAIN")
    
    if [ -z "$ZONE_ID" ]; then
        # 尝试剥离一级域名去查
        PARENT_DOMAIN=$(echo "$CF_ROOT_DOMAIN" | cut -d. -f2-)
        if [ "$PARENT_DOMAIN" != "$CF_ROOT_DOMAIN" ] && [ -n "$PARENT_DOMAIN" ] && echo "$PARENT_DOMAIN" | grep -q "\."; then
            info "找不到子域，尝试自动查找父顶级域名 ${PARENT_DOMAIN} 的 Zone ID..."
            ZONE_ID=$(cf_get_zone_id "$PARENT_DOMAIN")
            if [ -n "$ZONE_ID" ]; then
                log "✓ 自动修正成功！找到顶级域名 Zone ID: $ZONE_ID"
                # 重新修正变量关系，保证组合依然正确
                CF_ROOT_DOMAIN="$PARENT_DOMAIN"
                CF_SUBDOMAIN="${CF_FULL_DOMAIN%.$CF_ROOT_DOMAIN}"
                CF_SUBDOMAIN="${CF_SUBDOMAIN%.}" # 去掉末尾多余的点
            fi
        fi
    fi
    
    if [ -z "$ZONE_ID" ]; then
        err "最终无法获取到 Zone ID!"
        warn "请检查 Cloudflare 首页显示的顶级域名到底是什么，确认 Token 的区域资源包含了该域名。"
        return 1
    fi
    log "✓ Zone ID 最终确认: $ZONE_ID"
    
    cat > "$CONFIG_FILE" <<EOF
CF_API_TOKEN=${CF_API_TOKEN}
CF_ROOT_DOMAIN=${CF_ROOT_DOMAIN}
CF_SUBDOMAIN=${CF_SUBDOMAIN}
CF_FULL_DOMAIN=${CF_FULL_DOMAIN}
ZONE_ID=${ZONE_ID}
EOF
    return 0
}

# ============== 智能 DNS 解析 ==============
smart_dns_setup() {
    local record_type=$1 record_value=$2
    info "正在配置 DNS 记录: ${CF_FULL_DOMAIN} (${record_type}) -> ${record_value}"
    
    local existing_id=$(cf_get_record "$ZONE_ID" "${CF_SUBDOMAIN}.${CF_ROOT_DOMAIN}" "$record_type")
    
    if [ -n "$existing_id" ]; then
        log "发现现有 ${record_type} 记录, 正在更新..."
        cf_update_record "$ZONE_ID" "$existing_id" "$record_type" "${CF_SUBDOMAIN}.${CF_ROOT_DOMAIN}" "$record_value" "true"
    else
        log "创建新 ${record_type} 记录..."
        cf_create_record "$ZONE_ID" "$record_type" "${CF_SUBDOMAIN}.${CF_ROOT_DOMAIN}" "$record_value" "true"
    fi
}

# ============== 端口与防火墙 ==============
check_port_available() {
    local port=$1
    if ss -tuln 2>/dev/null | grep -q ":${port} "; then return 1; fi
    if netstat -tuln 2>/dev/null | grep -q ":${port} "; then return 1; fi
    return 0
}

get_available_port() {
    local default=$1 port=$default max_attempts=100 attempt=0
    while ! check_port_available "$port"; do
        port=$((port + 1))
        attempt=$((attempt + 1))
        if [ $attempt -gt $max_attempts ]; then
            err "找不到可用端口"
            return 1
        fi
    done
    echo $port
}

setup_firewall() {
    local web_port=$1 agent_port=$2
    info "正在配置防火墙规则..."
    if command -v ufw &>/dev/null; then
        ufw allow "${web_port}/tcp" comment "Nezha Web" 2>/dev/null || true
        ufw allow "${agent_port}/tcp" comment "Nezha Agent" 2>/dev/null || true
        ufw reload 2>/dev/null || true
    fi
    if command -v iptables &>/dev/null; then
        iptables -I INPUT -p tcp --dport "$web_port" -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p tcp --dport "$agent_port" -j ACCEPT 2>/dev/null || true
    fi
    if command -v ip6tables &>/dev/null; then
        ip6tables -I INPUT -p tcp --dport "$web_port" -j ACCEPT 2>/dev/null || true
        ip6tables -I INPUT -p tcp --dport "$agent_port" -j ACCEPT 2>/dev/null || true
    fi
    log "✓ 防火墙规则已配置 (Web:${web_port} Agent:${agent_port})"
    warn "⚠️ 如果部署后公网无法访问，请务必检查家用路由器 / 云服务器安全组 的防火墙！"
}

# ============== V0: Argo Nezha 部署 ==============
v0_deploy() {
    echo -e "\n${PURPLE}══════════════════════════════${NC}"
    echo -e "${PURPLE}  V0: Argo Nezha 一键部署模式${NC}"
    echo -e "${PURPLE}  适用: 任何网络环境(无需公网IP)${NC}"
    echo -e "${PURPLE}══════════════════════════════${NC}"
    
    configure_cloudflare || return 1
    
    echo -e "\n${CYAN}═══ GitHub OAuth 配置 ═══${NC}"
    echo -e "${PURPLE}【如何获取 GitHub OAuth 信息】${NC}"
    echo -e "1. 浏览器打开: ${BOLD}https://github.com/settings/developers${NC}"
    echo -e "2. 点击右上方 ${GREEN}[New OAuth App]${NC} 按钮"
    echo -e "3. Application name: 随意填写 (如 Nezha)"
    echo -e "4. Homepage URL 填写: ${BOLD}https://${CF_FULL_DOMAIN}${NC}"
    echo -e "5. Authorization callback URL 填写: ${BOLD}https://${CF_FULL_DOMAIN}/oauth2/callback${NC}"
    echo -e "6. 点击 Register application 注册获取 Client ID，并生成 Client Secret。"
    echo -e "--------------------------------------------------------"
    
    read -rp "请输入 GitHub 用户名 (你的GitHub ID): " GH_USER
    read -rp "请输入 GitHub Client ID: " GH_CLIENTID
    read -rp "请输入 GitHub Client Secret: " GH_CLIENTSECRET
    
    echo -e "\n${CYAN}═══ Cloudflare Argo Tunnel ═══${NC}"
    echo "1) 使用 Cloudflare 账户 Token (推荐, 域名固定)"
    echo "2) 使用临时隧道 (无需Token, 但域名可能变化)"
    read -rp "选择 [1/2, 默认1]: " ARGO_TYPE
    
    ARGO_AUTH=""
    if [ "$ARGO_TYPE" != "2" ]; then
        echo -e "\n${PURPLE}【如何获取 Tunnel Token】${NC}"
        echo -e "浏览器打开 ${BOLD}https://one.dash.cloudflare.com/${NC} -> [Networks] -> [Tunnels] 创建并获取Token。服务类型 (HTTP),URL (localhost:8008)"
        read -rp "请输入 Tunnel Token (ey...开头): " ARGO_AUTH
    else
        ARGO_AUTH="Tunnel"
    fi
    
    info "开始拉取 Argo Nezha 镜像并启动容器..."
    docker pull fscarmen/argo-nezha:latest
    docker stop argo-nezha 2>/dev/null || true
    docker rm argo-nezha 2>/dev/null || true
    
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
        fscarmen/argo-nezha:latest
    
    sleep 10
    v0_verify "$CF_FULL_DOMAIN"
}

v0_verify() {
    local domain=$1
    echo -e "\n${CYAN}═══ V0 部署验证 ═══${NC}"
    info "等待 Argo 隧道建立连接 (约15秒)..."
    sleep 15
    docker ps --filter "name=argo-nezha" --format "table {{.Status}}" || true
    
    HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 20 "https://${domain}" || echo "000")
    if [[ "$HTTP_CODE" =~ ^(200|301|302)$ ]]; then
        log "🎉 域名可访问: https://${domain}"
        log "V0 部署彻底完成！"
    else
        warn "访问返回 HTTP ${HTTP_CODE}, 容器可能仍在启动，可使用 docker logs argo-nezha 检查报错"
    fi
}

# ============== V1: 双栈直连模式 ==============
v1_deploy() {
    echo -e "\n${PURPLE}══════════════════════════════${NC}"
    echo -e "${PURPLE}  V1: Nezha Dashboard 双栈直连${NC}"
    echo -e "${PURPLE}  适用: 拥有公网IPv4或IPv6的环境${NC}"
    echo -e "${PURPLE}══════════════════════════════${NC}"
    
    if [ -f "$NETWORK_INFO_FILE" ]; then
        source "$NETWORK_INFO_FILE"
    else
        detect_network
    fi
    
    configure_cloudflare || return 1
    
    echo -e "\n${CYAN}═══ 端口与网络配置 ═══${NC}"
    WEB_PORT=$(get_available_port 8008)
    AGENT_PORT=$(get_available_port 5555)
    log "自动分配端口: Web面板=${WEB_PORT}, 探针Agent=${AGENT_PORT}"
    
    NET_MODE="1"
    if [ "$HAS_IPV4_PUBLIC" = "yes" ] || [ "$HAS_IPV6_PUBLIC" = "yes" ]; then
        echo -e "\n请选择 Docker 网络模式:"
        echo "1) bridge + 端口映射 (推荐, 支持 IPv4+IPv6 双栈监听)"
        echo "2) host (容器与主机共享网络栈)"
        read -rp "选择 [1/2, 默认1]: " NET_MODE
        NET_MODE=${NET_MODE:-1}
    fi
    
    echo -e "\n${CYAN}═══ 智能 DNS 自动配置 ═══${NC}"
    if [ "$HAS_IPV4_PUBLIC" = "yes" ] && [ -n "$IPV4_ADDR" ]; then
        smart_dns_setup "A" "$IPV4_ADDR"
    else
        warn "未检测到可用 IPv4 公网，跳过 A 记录注册"
    fi
    
    if [ "$HAS_IPV6_PUBLIC" = "yes" ] && [ -n "$IPV6_ADDR" ]; then
        smart_dns_setup "AAAA" "$IPV6_ADDR"
    else
        warn "未检测到可用 IPv6 公网，跳过 AAAA 记录注册"
    fi
    
    setup_firewall "$WEB_PORT" "$AGENT_PORT"
    
    info "拉取 Nezha 最新官方镜像..."
    docker pull ghcr.io/nezhahq/nezha:latest
    docker stop nezha-dashboard 2>/dev/null || true
    docker rm nezha-dashboard 2>/dev/null || true
    
    DATA_DIR="/opt/nezha/dashboard"
    mkdir -p "$DATA_DIR"
    chown -R 1000:1000 "$DATA_DIR" 2>/dev/null || true
    
    info "启动 Nezha 容器..."
    if [ "$NET_MODE" == "2" ]; then
        docker run -d --name nezha-dashboard \
            --restart unless-stopped \
            --network host \
            -v "$DATA_DIR:/dashboard/data" \
            -v /etc/localtime:/etc/localtime:ro \
            -e TZ="Asia/Shanghai" \
            -e PORT="$WEB_PORT" \
            ghcr.io/nezhahq/nezha:latest
    else
        docker run -d --name nezha-dashboard \
            --restart unless-stopped \
            -p "${WEB_PORT}:8008" \
            -p "${AGENT_PORT}:5555" \
            -v "$DATA_DIR:/dashboard/data" \
            -v /etc/localtime:/etc/localtime:ro \
            -e TZ="Asia/Shanghai" \
            -e PORT="$WEB_PORT" \
            ghcr.io/nezhahq/nezha:latest
    fi
    
    sleep 8
    v1_verify "$CF_FULL_DOMAIN" "$WEB_PORT" "$AGENT_PORT"
}

v1_verify() {
    local domain=$1 web_port=$2 agent_port=$3
    echo -e "\n${CYAN}═══ V1 部署连通性验证 ═══${NC}"
    docker ps --filter "name=nezha-dashboard" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" || true
    
    info "本地服务连通性测试..."
    IPV4_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:${web_port}" || echo "000")
    if [ "$IPV4_STATUS" != "000" ]; then log "✓ 本地 IPv4 访问正常 (HTTP ${IPV4_STATUS})"; fi
    
    IPV6_STATUS=$(curl -6 -s -o /dev/null -w "%{http_code}" --max-time 5 "http://[::1]:${web_port}" 2>/dev/null || echo "000")
    if [ "$IPV6_STATUS" != "000" ]; then log "✓ 本地 IPv6 访问正常 (HTTP ${IPV6_STATUS})"; fi
    
    info "DNS 解析验证 (等待Cloudflare生效)..."
    sleep 5
    A_RECORD=$(dig +short A "$domain" 2>/dev/null | head -1 || true)
    AAAA_RECORD=$(dig +short AAAA "$domain" 2>/dev/null | head -1 || true)
    [ -n "$A_RECORD" ] && log "✓ A 记录已解析: $A_RECORD"
    [ -n "$AAAA_RECORD" ] && log "✓ AAAA 记录已解析: $AAAA_RECORD"
    
    info "通过 Cloudflare 边缘节点访问测试..."
    sleep 3
    CF_RESULT=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 25 "https://${domain}" || echo "000")
    if [[ "$CF_RESULT" =~ ^(200|301|302|404|502|503)$ ]]; then
        if [ "$CF_RESULT" = "200" ]; then
            log "🎉 恭喜！域名通过 Cloudflare 访问成功！"
        else
            warn "Cloudflare 返回 HTTP $CF_RESULT (可能是Cloudflare同步慢，稍等刷新即可)"
        fi
    else
        warn "外网域名访问失败 (HTTP $CF_RESULT)"
        warn "排查原因: 1) Cloudflare 尚未同步  2) 你的路由器防火墙尚未放行 ${web_port} 端口入站"
    fi
    
    echo -e "\n${CYAN}═══ 后续配置指南 ═══${NC}"
    echo -e "1. 浏览器打开 ${BOLD}https://${domain}${NC} 登录管理员账号。"
    echo -e "2. 进入 [设置] -> [面板配置] 页面:"
    echo -e "   - 通讯域名 / 服务器IP地址 填写: ${BOLD}${domain}${NC}"
    echo -e "   - 探针/Agent 端口 填写: ${BOLD}${agent_port}${NC}"
    echo -e "   - 必须勾选: ${BOLD}[未接入 CDN]${NC} 或 ${BOLD}[未开启 TLS]${NC} (因为走的是CF直连代理)"
    echo -e "3. 保存后，在其他小鸡上执行生成的 Agent 安装命令即可。"
}

# ============== V2: Cloudflared 官方隧道 ==============
v2_deploy() {
    echo -e "\n${PURPLE}══════════════════════════════${NC}"
    echo -e "${PURPLE}  V2: Cloudflared 官方隧道部署${NC}"
    echo -e "${PURPLE}  适用: 无公网IP，且不想配 GitHub OAuth 的用户${NC}"
    echo -e "${PURPLE}══════════════════════════════${NC}"
    
    configure_cloudflare || return 1
    
    WEB_PORT=$(get_available_port 8008)
    AGENT_PORT=$(get_available_port 5555)
    
    install_docker
    info "启动 Nezha Dashboard..."
    docker stop nezha-dashboard 2>/dev/null || true
    docker rm nezha-dashboard 2>/dev/null || true
    
    DATA_DIR="/opt/nezha/dashboard"
    mkdir -p "$DATA_DIR"
    chown -R 1000:1000 "$DATA_DIR" 2>/dev/null || true
    
    docker run -d --name nezha-dashboard \
        --restart unless-stopped \
        -p "${WEB_PORT}:8008" \
        -p "${AGENT_PORT}:5555" \
        -v "$DATA_DIR:/dashboard/data" \
        -v /etc/localtime:/etc/localtime:ro \
        -e TZ="Asia/Shanghai" \
        ghcr.io/nezhahq/nezha:latest
    
    echo -e "\n${CYAN}═══ Cloudflared 隧道配置 ═══${NC}"
    echo -e "${PURPLE}【如何获取 Cloudflare Tunnel Token】${NC}"
    echo -e "1. 浏览器打开 Zero Trust 控制台: ${BOLD}https://one.dash.cloudflare.com/${NC}"
    echo -e "2. 左侧菜单点击 ${GREEN}[Networks]${NC} -> ${GREEN}[Tunnels]${NC}"
    echo -e "3. 点击右侧的 ${GREEN}[Create a tunnel]${NC}"
    echo -e "4. Select connector type 选择 ${BOLD}Cloudflared${NC}, Next"
    echo -e "5. 随便起个名字, Save tunnel"
    echo -e "6. 在提供的安装命令中，复制包含 ${BOLD}ey...${NC} 的一长串字符。"
    echo -e "--------------------------------------------------------"
    
    read -rp "请粘贴 Tunnel Token: " CF_TUNNEL_TOKEN
    while [[ -z "$CF_TUNNEL_TOKEN" ]]; do
        read -rp "Token 不能为空, 请重试: " CF_TUNNEL_TOKEN
    done
    
    local tunnel_id=$(echo "$CF_TUNNEL_TOKEN" | cut -d'.' -f1)
    local tunnel_secret=$(echo "$CF_TUNNEL_TOKEN" | cut -d'.' -f2)
    
    mkdir -p /etc/cloudflared
    cat > /etc/cloudflared/config.yml <<EOF
tunnel: ${tunnel_id}
credentials-file: /etc/cloudflared/${tunnel_id}.json
ingress:
  - hostname: ${CF_FULL_DOMAIN}
    service: http://localhost:${WEB_PORT}
  - service: http_status:404
EOF
    cat > "/etc/cloudflared/${tunnel_id}.json" <<EOF
{
  "AccountTag": "auto",
  "TunnelSecret": "${tunnel_secret}",
  "TunnelID": "${tunnel_id}"
}
EOF
    
    info "拉取并启动 Cloudflared 隧道代理..."
    docker pull cloudflare/cloudflared:latest
    docker stop cloudflared 2>/dev/null || true
    docker rm cloudflared 2>/dev/null || true
    
    docker run -d --name cloudflared \
        --restart always \
        -v /etc/cloudflared:/etc/cloudflared \
        --network host \
        cloudflare/cloudflared:latest \
        tunnel --no-autoupdate run
    
    info "配置 Cloudflare CNAME 自动路由指向隧道..."
    cname_data="{\"type\":\"CNAME\",\"name\":\"${CF_SUBDOMAIN}\",\"content\":\"${tunnel_id}.cfargotunnel.com\",\"proxied\":true}"
    cf_api POST "/zones/${ZONE_ID}/dns_records" "$cname_data" | tee -a "$LOG_FILE"
    
    sleep 10
    v2_verify "$CF_FULL_DOMAIN"
}

v2_verify() {
    local domain=$1
    echo -e "\n${CYAN}═══ V2 部署连通性验证 ═══${NC}"
    docker ps --format "table {{.Names}}\t{{.Status}}" || true
    sleep 10
    HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 20 "https://${domain}" || echo "000")
    if [[ "$HTTP_CODE" =~ ^(200|301|302)$ ]]; then
        log "🎉 V2 隧道部署彻底完成!"
        log "访问地址: https://${domain}"
    else
        warn "HTTP $HTTP_CODE，隧道尚未同步就绪，请使用 docker logs cloudflared 检查原因"
    fi
}

# ============== 智能推荐引擎 ==============
smart_recommend() {
    if [ ! -f "$NETWORK_INFO_FILE" ]; then detect_network; fi
    source "$NETWORK_INFO_FILE"
    
    echo -e "\n${CYAN}╔════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         ${BOLD}智能推荐部署方案${NC}${CYAN}                    ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════╝${NC}"
    
    if [ "$HAS_IPV4_PUBLIC" = "yes" ] && [ "$HAS_IPV6_PUBLIC" = "yes" ]; then
        echo -e "您的网络: ${GREEN}双栈公网${NC} (性能完美)"
        echo -e "最佳方案: ${GREEN}★ V1 双栈直连部署${NC} (响应最快，支持探针原生连接)"
    elif [ "$HAS_IPV4_PUBLIC" = "yes" ]; then
        echo -e "您的网络: ${GREEN}IPv4公网${NC}"
        echo -e "最佳方案: ${GREEN}★ V1 双栈直连部署${NC} (最稳定可靠)"
    elif [ "$HAS_IPV6_PUBLIC" = "yes" ]; then
        echo -e "您的网络: ${GREEN}仅 IPv6 公网${NC}"
        echo -e "系统建议:"
        echo -e "  ${GREEN}方案A: V1 直连部署${NC} (最快，但需要你懂怎么在路由器里放行 IPv6 端口)"
        echo -e "  ${BLUE}方案B: V0 Argo隧道部署${NC} (最省事，路由器防火墙直接穿透，无需配置)"
    else
        echo -e "您的网络: ${YELLOW}纯大内网无公网 IP${NC}"
        echo -e "系统建议:"
        echo -e "  ${GREEN}最佳方案: V0 Argo隧道部署${NC} (原生自带隧道，穿透力极强)"
        echo -e "  ${BLUE}备选方案: V2 Cloudflared隧道${NC}"
    fi
    echo ""
}

# ============== 卸载模块 ==============
uninstall_nezha() {
    warn "该操作将彻底删除所有哪吒面板和隧道容器及配置文件！"
    read -rp "请确认是否继续卸载? [y/N]: " CONFIRM
    if [[ "$CONFIRM" =~ ^[yY] ]]; then
        info "正在停止并删除容器..."
        for c in argo-nezha nezha-dashboard cloudflared; do
            docker stop $c 2>/dev/null || true
            docker rm $c 2>/dev/null || true
        done
        info "正在清理数据目录..."
        rm -rf /opt/nezha /etc/nezha-deploy
        log "卸载完成！系统已恢复纯净。"
    else
        log "已取消卸载。"
    fi
}

# ============== 主菜单 ==============
main_menu() {
    check_root
    install_docker
    
    while true; do
        echo -e "\n${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║       ${BOLD}哪吒探针全智能多模部署系统 v${SCRIPT_VERSION}${NC}${CYAN}               ║${NC}"
        echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
        echo -e "  ${GREEN}1)${NC} 网络环境智能检测"
        echo -e "  ${GREEN}2)${NC} V1 双栈直连部署 ${YELLOW}(有公网IP推荐)${NC}"
        echo -e "  ${GREEN}3)${NC} V0 Argo隧道部署 ${YELLOW}(无公网/不想配置路由器的推荐)${NC}"
        echo -e "  ${GREEN}4)${NC} V2 Cloudflared官方隧道部署"
        echo -e "  ${GREEN}5)${NC} ${BOLD}一键智能推荐并部署${NC} ${PURPLE}<<不知道怎么选就选这个!${NC}"
        echo -e "  ${GREEN}6)${NC} 查看当前容器与网络状态"
        echo -e "  ${GREEN}7)${NC} 卸载面板系统"
        echo -e "  ${RED}0)${NC} 退出"
        echo ""
        read -rp "请输入选项 [0-7]: " CHOICE
        
        case $CHOICE in
            1) detect_network ;;
            2) [ ! -f "$NETWORK_INFO_FILE" ] && detect_network; v1_deploy ;;
            3) v0_deploy ;;
            4) v2_deploy ;;
            5)
                detect_network
                smart_recommend
                read -rp "系统推荐完成, 是否采用 V1 (直连模式)? 选 N 将使用 V0 (隧道模式) [Y/n]: " AUTO_CHOICE
                if [[ "$AUTO_CHOICE" =~ ^([nN][oO]|[nN])$ ]]; then
                    v0_deploy
                else
                    v1_deploy
                fi
                ;;
            6)
                echo -e "\n${BLUE}【Docker 容器运行状态】${NC}"
                docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" || true
                echo -e "\n${BLUE}【本地网络信息缓存】${NC}"
                [ -f "$NETWORK_INFO_FILE" ] && cat "$NETWORK_INFO_FILE" || echo "未检测"
                ;;
            7) uninstall_nezha ;;
            0) log "感谢使用，再见！"; exit 0 ;;
            *) err "无效选项，请重新输入" ;;
        esac
    done
}

# 开始执行
main_menu
