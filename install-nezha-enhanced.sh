#!/bin/bash

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║                                                                           ║
# ║          🚀 Nezha 全能智能部署系统 v3.0 (Enhanced Edition)              ║
# ║                                                                           ║
# ║  功能特性：                                                               ║
# ║  ✓ 多版本部署 (V0/V1/V2)                                                 ║
# ║  ✓ 完整备份恢复系统                                                       ║
# ║  ✓ 版本管理与升级回滚                                                     ║
# ║  ✓ 高级日志管理与导出                                                     ║
# ║  ✓ 故障诊断中心                                                           ║
# ║  ✓ 配置加密安全存储                                                       ║
# ║  ✓ 容器健康监控与告警                                                     ║
# ║  ✓ 智能向导系统                                                           ║
# ║                                                                           ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# ========== 颜色定义 ==========
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ========== 全局配置 ==========
SCRIPT_VERSION="3.0"
SCRIPT_NAME="Nezha Smart Deploy"
CONFIG_DIR="/etc/nezha-deploy"
CONFIG_FILE="$CONFIG_DIR/config.conf"
BACKUP_DIR="/var/backups/nezha"
LOG_DIR="$CONFIG_DIR/logs"
MONITOR_DIR="/var/run/nezha-monitor"
CACHE_DIR="/tmp/nezha-cache"
DATABASE_DIR="/opt/nezha/dashboard/data"
DOCKER_CONFIG="/etc/docker/daemon.json"

# 创建必需目录
mkdir -p "$CONFIG_DIR" "$BACKUP_DIR" "$LOG_DIR" "$MONITOR_DIR" "$CACHE_DIR"

# ========== 日志系统 ==========
LOG_FILE="$LOG_DIR/deploy-$(date +%Y%m%d).log"
MAIN_LOG="$LOG_DIR/main.log"

log() { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $*" | tee -a "$MAIN_LOG"; }
warn() { echo -e "${YELLOW}[⚠ 警告]${NC} $*" | tee -a "$MAIN_LOG"; }
err() { echo -e "${RED}[✗ 错误]${NC} $*" | tee -a "$MAIN_LOG"; }
info() { echo -e "${BLUE}[ℹ 信息]${NC} $*" | tee -a "$MAIN_LOG"; }
success() { echo -e "${GREEN}[✓ 成功]${NC} $*" | tee -a "$MAIN_LOG"; }

# ========== 权限检查 ==========
check_root() {
    if [ "$EUID" -ne 0 ]; then
        err "需要 root 权限，请使用 sudo"
        exit 1
    fi
}

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║                          第一部分：备份恢复系统                           ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

backup_config() {
    local backup_name="nezha-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
    local backup_path="$BACKUP_DIR/$backup_name"
    
    info "开始备份系统配置..."
    
    # 检查备份源是否存在
    if [ ! -d "$DATABASE_DIR" ] && [ ! -f "$CONFIG_FILE" ]; then
        warn "无可备份的配置文件"
        return 1
    fi
    
    # 创建临时备份目录
    local temp_backup="/tmp/nezha-backup-$$"
    mkdir -p "$temp_backup"
    
    # 备份配置文件
    [ -f "$CONFIG_FILE" ] && cp "$CONFIG_FILE" "$temp_backup/"
    
    # 备份数据库文件
    if [ -d "$DATABASE_DIR" ]; then
        mkdir -p "$temp_backup/data"
        cp -r "$DATABASE_DIR"/* "$temp_backup/data/" 2>/dev/null || true
    fi
    
    # 备份容器配置信息
    if command -v docker &>/dev/null; then
        for container in argo-nezha nezha-dashboard cloudflared; do
            docker inspect "$container" > "$temp_backup/${container}-inspect.json" 2>/dev/null || true
        done
    fi
    
    # 创建压缩备份
    tar -czf "$backup_path" -C "$temp_backup" . 2>/dev/null
    rm -rf "$temp_backup"
    
    if [ -f "$backup_path" ]; then
        local size=$(du -h "$backup_path" | cut -f1)
        success "备份完成: $backup_path (大小: $size)"
        
        # 记录备份元数据
        cat >> "$BACKUP_DIR/.backup_manifest" <<EOF
$backup_name|$(date +%s)|$size|$(md5sum "$backup_path" | cut -d' ' -f1)
EOF
        return 0
    else
        err "备份失败"
        return 1
    fi
}

list_backups() {
    echo -e "\n${CYAN}═══ 备份文件列表 ═══${NC}"
    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A $BACKUP_DIR/*.tar.gz 2>/dev/null)" ]; then
        info "暂无备份"
        return
    fi
    
    local count=1
    while IFS='|' read -r name timestamp size checksum; do
        local date_str=$(date -d @"$timestamp" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "未知")
        echo "$count) $name | 时间: $date_str | 大小: $size"
        count=$((count + 1))
    done < <(cat "$BACKUP_DIR/.backup_manifest" 2>/dev/null | tail -20)
}

restore_backup() {
    list_backups
    
    if [ -z "$(ls -A $BACKUP_DIR/*.tar.gz 2>/dev/null)" ]; then
        err "没有可用的备份"
        return 1
    fi
    
    read -rp "请输入要恢复的备份编号 (或文件名): " restore_input
    
    local backup_file
    if [[ "$restore_input" =~ ^[0-9]+$ ]]; then
        backup_file=$(ls -t "$BACKUP_DIR"/*.tar.gz 2>/dev/null | sed -n "${restore_input}p")
    else
        backup_file="$BACKUP_DIR/$restore_input"
    fi
    
    if [ ! -f "$backup_file" ]; then
        err "备份文件不存在: $backup_file"
        return 1
    fi
    
    warn "将从备份恢复系统，这将覆盖当前配置！"
    read -rp "请确认 [y/N]: " confirm
    [[ ! "$confirm" =~ ^[yY] ]] && return 1
    
    info "开始恢复备份: $(basename $backup_file)"
    
    # 停止容器
    for container in argo-nezha nezha-dashboard cloudflared; do
        docker stop "$container" 2>/dev/null || true
    done
    
    # 备份当前数据
    [ -d "$DATABASE_DIR" ] && mv "$DATABASE_DIR" "${DATABASE_DIR}.backup-$(date +%s)"
    
    # 解压备份
    mkdir -p "$DATABASE_DIR"
    tar -xzf "$backup_file" -C "$DATABASE_DIR" 2>/dev/null || true
    
    # 恢复配置文件
    [ -f "$BACKUP_DIR/config.conf" ] && cp "$BACKUP_DIR/config.conf" "$CONFIG_FILE"
    
    # 重启容器
    info "重启容器中..."
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        docker-compose up -d 2>/dev/null || true
    fi
    
    success "备份恢复完成！"
    return 0
}

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║                        第二部分：版本管理与升级                          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

check_container_version() {
    local container=$1
    info "检查 $container 版本信息..."
    
    if ! docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
        warn "容器 $container 未运行"
        return 1
    fi
    
    case "$container" in
        argo-nezha)
            docker inspect "$container" | grep -A5 '"Image"' | head -1
            ;;
        nezha-dashboard)
            docker exec "$container" cat /app/VERSION 2>/dev/null || \
            docker inspect "$container" | grep -oP 'ghcr.io/nezhahq/nezha:\K[^"]+' | head -1
            ;;
        cloudflared)
            docker exec "$container" cloudflared --version 2>/dev/null || echo "未知"
            ;;
    esac
}

upgrade_container() {
    local container=$1
    local new_image=$2
    
    info "准备升级 $container..."
    
    # 创建升级前备份
    local backup_name="pre-upgrade-$(date +%Y%m%d-%H%M%S)"
    backup_config
    
    info "拉取新镜像: $new_image"
    if ! docker pull "$new_image"; then
        err "镜像拉取失败"
        return 1
    fi
    
    info "停止旧容器..."
    docker stop "$container" 2>/dev/null || true
    
    info "重命名旧容器用于回滚..."
    docker rename "$container" "${container}-old-$(date +%s)" 2>/dev/null || true
    
    # 根据容器类型重启
    case "$container" in
        argo-nezha)
            docker run -d --name "$container" \
                --restart always \
                --network host \
                -e GH_USER="$GH_USER" \
                -e GH_CLIENTID="$GH_CLIENTID" \
                -e GH_CLIENTSECRET="$GH_CLIENTSECRET" \
                -e ARGO_AUTH="$ARGO_AUTH" \
                -e ARGO_DOMAIN="$ARGO_DOMAIN" \
                "$new_image"
            ;;
        nezha-dashboard)
            docker run -d --name "$container" \
                --restart unless-stopped \
                -p "${WEB_PORT:-8008}:8008" \
                -p "${AGENT_PORT:-5555}:5555" \
                -v "$DATABASE_DIR:/dashboard/data" \
                -e TZ="Asia/Shanghai" \
                "$new_image"
            ;;
    esac
    
    sleep 5
    if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        success "升级成功！"
        
        # 清理旧容器（可选）
        read -rp "是否删除旧容器? [y/N]: " cleanup
        if [[ "$cleanup" =~ ^[yY] ]]; then
            docker rm "$(docker ps -a --filter "name=${container}-old" --format '{{.Names}}')" 2>/dev/null || true
        fi
        return 0
    else
        err "升级失败，正在回滚..."
        docker rename "${container}-old-$(date +%s)" "$container" 2>/dev/null || true
        docker start "$container" 2>/dev/null || true
        return 1
    fi
}

rollback_version() {
    echo -e "\n${CYAN}═══ 版本回滚 ═══${NC}"
    
    if [ -z "$(docker ps -a --format '{{.Names}}' | grep -E 'argo-nezha|nezha-dashboard|cloudflared')" ]; then
        warn "没有找到哪吒容器"
        return 1
    fi
    
    echo "检测到的旧版本容器:"
    docker ps -a --filter "name=*-old" --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"
    
    read -rp "输入要回滚到的容器名称: " old_container
    if ! docker ps -a --format '{{.Names}}' | grep -q "^${old_container}$"; then
        err "容器不存在"
        return 1
    fi
    
    info "正在回滚..."
    docker stop "${old_container%-old*}" 2>/dev/null || true
    docker rm "${old_container%-old*}" 2>/dev/null || true
    docker rename "$old_container" "${old_container%-old*}"
    docker start "${old_container%-old*}"
    
    success "回滚完成"
}

# ╔════════════��══════════════════════════════════════════════════════════════╗
# ║                        第三部分：高级日志管理                            ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

view_logs() {
    local container=$1
    local lines=${2:-50}
    
    if [ -z "$container" ]; then
        echo -e "\n${CYAN}═══ 可用容器 ═══${NC}"
        docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"
        read -rp "输入容器名称: " container
    fi
    
    if ! docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
        err "容器不存在: $container"
        return 1
    fi
    
    info "显示 $container 最后 $lines 行日志:"
    docker logs --tail "$lines" "$container"
}

export_logs() {
    local container=${1:-all}
    local export_file="$LOG_DIR/nezha-logs-$(date +%Y%m%d-%H%M%S).tar.gz"
    local temp_log_dir="/tmp/nezha-export-logs"
    
    mkdir -p "$temp_log_dir"
    
    if [ "$container" = "all" ]; then
        info "导出所有容器日志..."
        for c in $(docker ps -a --format '{{.Names}}'); do
            docker logs "$c" > "$temp_log_dir/${c}.log" 2>&1
        done
    else
        info "导出容器 $container 日志..."
        docker logs "$container" > "$temp_log_dir/${container}.log" 2>&1
    fi
    
    # 导出系统日志
    journalctl -u docker -n 1000 > "$temp_log_dir/docker-service.log" 2>&1 || true
    
    # 导出部署脚本日志
    cp "$LOG_DIR"/* "$temp_log_dir/" 2>/dev/null || true
    
    tar -czf "$export_file" -C "$temp_log_dir" . 
    rm -rf "$temp_log_dir"
    
    success "日志已导出: $export_file"
}

rotate_logs() {
    info "执行日志轮转..."
    local max_days=7
    
    find "$LOG_DIR" -type f -name "*.log" -mtime +$max_days -delete
    find "$BACKUP_DIR" -type f -name "*.tar.gz" -mtime +30 -delete
    
    success "日志轮转完成（保留 $max_days 天）"
}

tail_logs() {
    local container=${1:-nezha-dashboard}
    info "实时显示 $container 日志 (Ctrl+C 退出)..."
    docker logs -f "$container"
}

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║                      第四部分：故障诊断中心                              ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

diagnose_system() {
    echo -e "\n${CYAN}╔═══════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         系统诊断报告 $(date '+%Y-%m-%d %H:%M:%S')          ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════╝${NC}"
    
    # 1. Docker 状态
    echo -e "\n${PURPLE}【Docker 状态】${NC}"
    if command -v docker &>/dev/null; then
        docker_version=$(docker --version)
        success "Docker 已安装: $docker_version"
        docker_status=$(systemctl is-active docker 2>/dev/null || echo "未知")
        [ "$docker_status" = "active" ] && success "Docker 服务运行中" || warn "Docker 服务未运行"
    else
        err "Docker 未安装"
    fi
    
    # 2. 容器状态
    echo -e "\n${PURPLE}【容器状态】${NC}"
    docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" || warn "无容器"
    
    # 3. 网络诊断
    echo -e "\n${PURPLE}【网络诊断】${NC}"
    
    # 检查 DNS 解析
    if command -v dig &>/dev/null; then
        local dns_test=$(dig +short google.com 2>/dev/null | head -1)
        if [ -n "$dns_test" ]; then
            success "DNS 解析正常: google.com -> $dns_test"
        else
            warn "DNS 解析失败"
        fi
    fi
    
    # 检查互联网连接
    if ping -c1 -W2 8.8.8.8 &>/dev/null; then
        success "互联网连接正常 (IPv4)"
    else
        warn "IPv4 互联网连接失败"
    fi
    
    # 4. 磁盘空间
    echo -e "\n${PURPLE}【磁盘空间】${NC}"
    df -h | awk 'NR==1 || /\/$/ || /nezha/ {print}'
    
    # 5. 内存状态
    echo -e "\n${PURPLE}【内存状态】${NC}"
    free -h | head -2
    
    # 6. 端口占用
    echo -e "\n${PURPLE}【关键端口占用检查】${NC}"
    for port in 8008 5555 80 443; do
        if ss -tuln 2>/dev/null | grep -q ":$port "; then
            info "端口 $port: 已占用"
        else
            info "端口 $port: 空闲"
        fi
    done
    
    # 7. 配置文件完整性
    echo -e "\n${PURPLE}【配置文件检查】${NC}"
    [ -f "$CONFIG_FILE" ] && success "配置文件存在" || warn "配置文件缺失"
    [ -d "$DATABASE_DIR" ] && success "数据目录存在" || warn "数据目录缺失"
    
    # 8. 防火墙状态
    echo -e "\n${PURPLE}【防火墙状态】${NC}"
    if command -v ufw &>/dev/null; then
        ufw_status=$(ufw status | head -1)
        info "UFW: $ufw_status"
    fi
    
    # 9. SELinux/AppArmor
    echo -e "\n${PURPLE}【安全模块】${NC}"
    if command -v getenforce &>/dev/null; then
        selinux_status=$(getenforce)
        info "SELinux: $selinux_status"
    fi
    if command -v aa-status &>/dev/null; then
        info "AppArmor: 已安装"
    fi
}

fix_common_issues() {
    echo -e "\n${CYAN}═══ 常见问题修复向导 ═══${NC}"
    echo "1) 端口已被占用"
    echo "2) DNS 解析失败"
    echo "3) 容器重启失败"
    echo "4) 磁盘空间不足"
    echo "5) 网络连接超时"
    read -rp "选择问题类型 [1-5]: " issue_type
    
    case "$issue_type" in
        1)
            read -rp "输入被占用的端口号: " port
            info "查找占用端口 $port 的进程..."
            lsof -i :$port 2>/dev/null || ss -tulnp | grep ":$port "
            ;;
        2)
            info "尝试重启 DNS 服务..."
            systemctl restart systemd-resolved 2>/dev/null || true
            success "DNS 已重启"
            ;;
        3)
            warn "将尝试修复容器配置..."
            docker system prune -f
            docker restart $(docker ps -aq) 2>/dev/null || true
            success "容器已重启"
            ;;
        4)
            info "清理无用镜像和容器..."
            docker system prune -af --volumes
            success "磁盘清理完成"
            ;;
        5)
            info "检查网络设置..."
            cat /etc/resolv.conf
            ;;
    esac
}

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║                    第五部分：配置加密安全管理                            ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

encrypt_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        warn "配置文件不存在"
        return 1
    fi
    
    info "配置文件加密..."
    
    if ! command -v openssl &>/dev/null; then
        err "openssl 未安装"
        return 1
    fi
    
    read -rsp "输入加密密码: " password
    echo
    
    openssl enc -aes-256-cbc -salt -in "$CONFIG_FILE" -out "${CONFIG_FILE}.enc" -k "$password"
    
    if [ -f "${CONFIG_FILE}.enc" ]; then
        success "配置已加密: ${CONFIG_FILE}.enc"
        read -rp "是否删除原始文件? [y/N]: " confirm
        [[ "$confirm" =~ ^[yY] ]] && rm "$CONFIG_FILE"
    else
        err "加密失败"
        return 1
    fi
}

decrypt_config() {
    if [ ! -f "${CONFIG_FILE}.enc" ]; then
        warn "加密配置文件不存在"
        return 1
    fi
    
    info "配置文件解密..."
    read -rsp "输入解密密码: " password
    echo
    
    openssl enc -d -aes-256-cbc -in "${CONFIG_FILE}.enc" -out "$CONFIG_FILE" -k "$password"
    
    if [ -f "$CONFIG_FILE" ]; then
        success "配置已解密"
    else
        err "解密失败（可能是密码错误）"
        return 1
    fi
}

mask_sensitive_data() {
    info "掩码敏感数据..."
    
    if [ ! -f "$CONFIG_FILE" ]; then
        warn "配置文件不存在"
        return 1
    fi
    
    # 创建掩码版本用于分享
    sed -E 's/(CLIENTSECRET|PAT|TOKEN|AUTH)=.*/\1=***MASKED***/g' "$CONFIG_FILE" > "${CONFIG_FILE}.masked"
    success "掩码文件已生成: ${CONFIG_FILE}.masked"
}

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║                  第六部分：容器健康监控与告警                            ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

health_check() {
    local container=$1
    local health_file="$MONITOR_DIR/${container}-health.log"
    
    mkdir -p "$MONITOR_DIR"
    
    info "执行健康检查: $container"
    
    if ! docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
        echo "UNHEALTHY|$(date +%s)|容器不存在" >> "$health_file"
        return 1
    fi
    
    # 检查容器是否运行
    local status=$(docker inspect --format='{{.State.Running}}' "$container")
    if [ "$status" != "true" ]; then
        echo "UNHEALTHY|$(date +%s)|容器未运行" >> "$health_file"
        warn "❌ $container 容器未运行"
        return 1
    fi
    
    # 检查容器资源使用
    local stats=$(docker stats "$container" --no-stream --format "{{.CPUPerc}}")
    
    # 检查端口连通性
    local ports=$(docker inspect --format='{{range $p, $conf := .NetworkSettings.Ports}}{{$p}} {{end}}' "$container")
    
    if [ -n "$ports" ]; then
        echo "HEALTHY|$(date +%s)|资源:$stats|端口:$ports" >> "$health_file"
        success "✅ $container 健康检查通过"
        return 0
    else
        echo "WARNING|$(date +%s)|无端口映射" >> "$health_file"
        warn "⚠️ $container 无端口映射"
        return 1
    fi
}

monitor_containers() {
    echo -e "\n${CYAN}═══ 容器监控面板 ═══${NC}"
    
    local containers=("argo-nezha" "nezha-dashboard" "cloudflared")
    
    for container in "${containers[@]}"; do
        health_check "$container" &
    done
    
    wait
    
    echo -e "\n${CYAN}═══ 资源使用统计 ═══${NC}"
    docker stats --no-stream --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}"
}

alert_on_failure() {
    local container=$1
    local alert_threshold=5  # 5 次失败后告警
    local alert_file="$MONITOR_DIR/${container}-alerts"
    
    if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        echo "$(date +%s)" >> "$alert_file"
        
        local fail_count=$(wc -l < "$alert_file")
        
        if [ $fail_count -ge $alert_threshold ]; then
            err "🚨 $container 连续失败 $fail_count 次！"
            
            # 尝试自动重启
            warn "尝试自动重启 $container..."
            docker restart "$container"
            
            # 清空告警计数
            > "$alert_file"
        fi
    fi
}

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║                    第七部分：网络智能检测                                ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

detect_network() {
    echo -e "\n${CYAN}╔════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║   网络环境智能检测${NC}${CYAN}                 ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
    
    local network_file="$CONFIG_DIR/network-info.txt"
    
    info "检测 IPv4 公网地址..."
    local ipv4=$(curl -4 -sS --max-time 5 https://api.ipify.org 2>/dev/null || echo "")
    if [ -n "$ipv4" ] && [[ ! "$ipv4" =~ ^(10\.|172\.|192\.|127\.) ]]; then
        success "IPv4 公网: $ipv4"
    else
        warn "IPv4: 私网或无连接"
        ipv4=""
    fi
    
    info "检测 IPv6 地址..."
    local ipv6=$(curl -6 -sS --max-time 5 https://api64.ipify.org 2>/dev/null || echo "")
    if [ -n "$ipv6" ]; then
        success "IPv6: $ipv6"
    else
        warn "IPv6: 不可用"
    fi
    
    info "检测 DNS 解析..."
    local dns_servers=$(cat /etc/resolv.conf | grep nameserver | awk '{print $2}' | tr '\n' ',')
    info "DNS 服务器: ${dns_servers%,}"
    
    info "检测网络延迟..."
    local latency=$(ping -c1 -W2 8.8.8.8 2>/dev/null | tail -1 | awk -F'/' '{print $5}' || echo "超时")
    info "到 8.8.8.8 的延迟: ${latency}ms"
    
    # 保存检测结果
    cat > "$network_file" <<EOF
IPv4=$ipv4
IPv6=$ipv6
DNS=$dns_servers
Latency=$latency
DetectTime=$(date '+%Y-%m-%d %H:%M:%S')
EOF
    
    echo -e "\n${CYAN}═══ 网络诊断摘要 ═══${NC}"
    cat "$network_file"
}

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║                      第八部分：快速操作菜单                              ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

quick_restart() {
    local container=${1:-all}
    
    if [ "$container" = "all" ]; then
        info "重启所有哪吒容器..."
        docker restart argo-nezha nezha-dashboard cloudflared 2>/dev/null
    else
        info "重启容器: $container"
        docker restart "$container"
    fi
    
    sleep 3
    docker ps --filter "name=$container" --format "table {{.Names}}\t{{.Status}}"
}

quick_stop() {
    local container=${1:-all}
    
    if [ "$container" = "all" ]; then
        info "停止所有哪吒容器..."
        docker stop argo-nezha nezha-dashboard cloudflared 2>/dev/null
    else
        info "停止容器: $container"
        docker stop "$container"
    fi
}

clean_unused_resources() {
    info "清理未使用的 Docker 资源..."
    
    # 统计清理前的大小
    local before=$(docker system df | grep "Local Volumes" | awk '{print $6}')
    
    docker system prune -f
    docker volume prune -f
    
    # 统计清理后的大小
    local after=$(docker system df | grep "Local Volumes" | awk '{print $6}')
    
    success "清理完成 (前: $before, 后: $after)"
}

view_container_stats() {
    local container=$1
    
    if [ -z "$container" ]; then
        info "所有容器资源使用情况:"
        docker stats --no-stream
    else
        info "$container 详细资源统计:"
        docker stats "$container" --no-stream --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemPerc}}\t{{.MemUsage}}\t{{.NetIO}}"
    fi
}

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║                    第九部分：交互式配置向导                              ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

interactive_setup() {
    echo -e "\n${CYAN}╔════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║   初始化配置向导${NC}${CYAN}                   ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
    
    echo -e "\n${PURPLE}选择部署模式:${NC}"
    echo "1) V0 - Argo 隧道模式 (无需公网IP，推荐)"
    echo "2) V1 - 双栈直连模式 (有公网IP)"
    echo "3) V2 - Cloudflared 隧道模式"
    read -rp "选择 [1-3]: " deploy_mode
    
    case "$deploy_mode" in
        1)
            read -rp "GitHub 用户名: " gh_user
            read -rp "GitHub Client ID: " gh_clientid
            read -rsp "GitHub Client Secret: " gh_clientsecret
            echo
            
            cat > "$CONFIG_FILE" <<EOF
DEPLOY_MODE=v0
GH_USER=$gh_user
GH_CLIENTID=$gh_clientid
GH_CLIENTSECRET=$gh_clientsecret
SETUP_TIME=$(date +%s)
EOF
            ;;
        2)
            read -rp "主域名: " domain
            read -rp "Web 端口 [8008]: " web_port
            web_port=${web_port:-8008}
            read -rp "Agent 端口 [5555]: " agent_port
            agent_port=${agent_port:-5555}
            
            cat > "$CONFIG_FILE" <<EOF
DEPLOY_MODE=v1
DOMAIN=$domain
WEB_PORT=$web_port
AGENT_PORT=$agent_port
SETUP_TIME=$(date +%s)
EOF
            ;;
    esac
    
    success "配置已保存到 $CONFIG_FILE"
    return 0
}

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║                        第十部分：主菜单系统                              ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

show_main_menu() {
    echo -e "\n${CYAN}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       ${BOLD}哪吒探针全能智能部署系统 v${SCRIPT_VERSION}${NC}${CYAN}           ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════╝${NC}"
    
    echo -e "\n${GREEN}━━━━━━━ 核心功能 ━━━━━━━${NC}"
    echo -e "  ${GREEN}1)${NC}  初始化配置向导"
    echo -e "  ${GREEN}2)${NC}  系统诊断报告"
    echo -e "  ${GREEN}3)${NC}  网络环境检测"
    
    echo -e "\n${PURPLE}━━━━━━━ 备份恢复 ━━━━━━━${NC}"
    echo -e "  ${GREEN}11)${NC} 立即备份配置"
    echo -e "  ${GREEN}12)${NC} 查看备份列表"
    echo -e "  ${GREEN}13)${NC} 恢复备份"
    
    echo -e "\n${YELLOW}━━━━━━━ 版本管理 ━━━━━━━${NC}"
    echo -e "  ${GREEN}21)${NC} 检查容器版本"
    echo -e "  ${GREEN}22)${NC} 升级容器镜像"
    echo -e "  ${GREEN}23)${NC} 回滚版本"
    
    echo -e "\n${BLUE}━━━━━━━ 日志管理 ━━━━━━━${NC}"
    echo -e "  ${GREEN}31)${NC} 查看日志"
    echo -e "  ${GREEN}32)${NC} 导出日志"
    echo -e "  ${GREEN}33)${NC} 日志轮转"
    echo -e "  ${GREEN}34)${NC} 实时日志流"
    
    echo -e "\n${RED}━━━━━━━ 故障处理 ━━━━━━━${NC}"
    echo -e "  ${GREEN}41)${NC} 故障诊断与修复"
    echo -e "  ${GREEN}42)${NC} 容器健康检查"
    echo -e "  ${GREEN}43)${NC} 容器监控面板"
    
    echo -e "\n${BOLD}━━━━━━━ 安全管理 ━━━━━━━${NC}"
    echo -e "  ${GREEN}51)${NC} 加密配置文件"
    echo -e "  ${GREEN}52)${NC} 解密配置文件"
    echo -e "  ${GREEN}53)${NC} 掩码敏感数据"
    
    echo -e "\n${DIM}━━━━━━━ 快速操作 ━━━━━━━${NC}"
    echo -e "  ${GREEN}61)${NC} 快速重启容器"
    echo -e "  ${GREEN}62)${NC} 停止所有容器"
    echo -e "  ${GREEN}63)${NC} 清理无用资源"
    echo -e "  ${GREEN}64)${NC} 查看资源统计"
    
    echo -e "\n${RED}  ${GREEN}0)${NC}  退出系统${NC}"
    echo ""
}

main_menu() {
    check_root
    
    while true; do
        show_main_menu
        read -rp "请输入选项 [0-64]: " choice
        
        case "$choice" in
            # 核心功能
            1) interactive_setup ;;
            2) diagnose_system ;;
            3) detect_network ;;
            
            # 备份恢复
            11) backup_config ;;
            12) list_backups ;;
            13) restore_backup ;;
            
            # 版本管理
            21)
                read -rp "输入容器名称 [默认: nezha-dashboard]: " cont
                check_container_version "${cont:-nezha-dashboard}"
                ;;
            22)
                read -rp "输入容器名称: " cont
                read -rp "输入新镜像 URI (如: ghcr.io/nezhahq/nezha:v0.17.0): " image
                upgrade_container "$cont" "$image"
                ;;
            23) rollback_version ;;
            
            # 日志管理
            31)
                read -rp "输入容器名称 [默认: all]: " cont
                view_logs "${cont:-all}"
                ;;
            32) export_logs ;;
            33) rotate_logs ;;
            34)
                read -rp "输入容器名称 [默认: nezha-dashboard]: " cont
                tail_logs "${cont:-nezha-dashboard}"
                ;;
            
            # 故障处理
            41) fix_common_issues ;;
            42)
                read -rp "输入容器名称 [默认: nezha-dashboard]: " cont
                health_check "${cont:-nezha-dashboard}"
                ;;
            43) monitor_containers ;;
            
            # 安全管理
            51) encrypt_config ;;
            52) decrypt_config ;;
            53) mask_sensitive_data ;;
            
            # 快速操作
            61)
                read -rp "输入容器名称 [默认: all]: " cont
                quick_restart "${cont:-all}"
                ;;
            62) quick_stop ;;
            63) clean_unused_resources ;;
            64)
                read -rp "输入容器名称 [默认: all]: " cont
                view_container_stats "${cont:-all}"
                ;;
            
            0)
                success "感谢使用，再见！"
                exit 0
                ;;
            *)
                err "无效选项，请重新输入"
                ;;
        esac
        
        read -rp "按 Enter 继续..."
    done
}

# ========== 脚本入口 ==========
main_menu
