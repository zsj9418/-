#!/bin/bash

set -euo pipefail

# ============================================================
# 全局配置
# ============================================================
readonly SCRIPT_VERSION="2.0"
readonly BASE_CONTAINER_NAME="cloudflared"
readonly LOG_FILE="/var/log/cloudflared_deploy.log"
readonly LOG_MAX_SIZE=1048576
readonly LOG_BACKUP_COUNT=3
readonly TOKEN_STORE="/etc/cloudflared/.tokens"

# 健康检查参数（实际用于docker run）
readonly HC_INTERVAL=30
readonly HC_START_PERIOD=60
readonly HC_TIMEOUT=10
readonly HC_RETRIES=3

# 网络配置默认值
NETWORK_MODE="host"
PROTOCOL="http2"

# 颜色定义
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# 全局变量
IMAGE_NAME=""
TOKEN_ARRAY=()
SELECTED_DISKS=()

# ============================================================
# 系统类型检测
# ============================================================
detect_system() {
    IS_OPENWRT=false
    
    if [[ -f "/etc/openwrt_release" ]]; then
        IS_OPENWRT=true
        SYSTEM_TYPE="OpenWrt"
    elif grep -qi "alpine" /etc/os-release 2>/dev/null; then
        SYSTEM_TYPE="Alpine"
    elif grep -qi "debian\|ubuntu" /etc/os-release 2>/dev/null; then
        SYSTEM_TYPE="Debian/Ubuntu"
    elif grep -qi "centos\|red hat\|rocky\|alma" /etc/os-release 2>/dev/null; then
        SYSTEM_TYPE="CentOS/RedHat"
    elif grep -qi "fedora" /etc/os-release 2>/dev/null; then
        SYSTEM_TYPE="Fedora"
    else
        SYSTEM_TYPE="Unknown"
    fi
    
    log "INFO" "检测到系统类型: ${SYSTEM_TYPE}"
}

# ============================================================
# 日志系统（带轮转）
# ============================================================
log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    
    # 控制台彩色输出
    case "$level" in
        "INFO")  echo -e "${GREEN}[INFO]  $timestamp - $message${NC}" ;;
        "WARN")  echo -e "${YELLOW}[WARN]  $timestamp - $message${NC}" ;;
        "ERROR") echo -e "${RED}[ERROR] $timestamp - $message${NC}" >&2 ;;
        "DEBUG") echo -e "${BLUE}[DEBUG] $timestamp - $message${NC}" ;;
    esac
    
    # 确保日志目录存在
    local log_dir
    log_dir=$(dirname "$LOG_FILE")
    [[ ! -d "$log_dir" ]] && mkdir -p "$log_dir"
    
    # 写入日志（Token内容不写入日志）
    echo "[$level] $timestamp - $message" >> "$LOG_FILE"
    
    # 日志轮转（替代直接清空）
    rotate_log
}

rotate_log() {
    [[ ! -f "$LOG_FILE" ]] && return
    
    local current_size
    current_size=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
    
    if [[ "$current_size" -ge "$LOG_MAX_SIZE" ]]; then
        # 轮转备份
        for i in $(seq $((LOG_BACKUP_COUNT - 1)) -1 1); do
            [[ -f "${LOG_FILE}.$i" ]] && \
                mv "${LOG_FILE}.$i" "${LOG_FILE}.$((i + 1))"
        done
        mv "$LOG_FILE" "${LOG_FILE}.1"
        touch "$LOG_FILE"
        echo "[INFO] $(date +"%Y-%m-%d %H:%M:%S") - 日志已轮转" >> "$LOG_FILE"
    fi
}

# ============================================================
# 前置检查
# ============================================================
check_docker() {
    if ! command -v docker &>/dev/null; then
        log "ERROR" "Docker 未安装，请先安装 Docker 后再运行此脚本。"
        exit 1
    fi
    
    # 检查Docker守护进程是否运行
    if ! docker info &>/dev/null; then
        log "ERROR" "Docker 守护进程未运行，请启动 Docker 服务。"
        exit 1
    fi
    
    log "INFO" "Docker 检测通过: $(docker --version)"
}

check_dependencies() {
    local missing=()
    
    # 检查jq（健康状态查看需要）
    if ! command -v jq &>/dev/null; then
        missing+=("jq")
        log "WARN" "未检测到 jq，健康检查状态显示将受限。"
    fi
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log "WARN" "缺失可选工具: ${missing[*]}，部分功能将降级运行。"
    fi
}

check_architecture() {
    local arch
    arch=$(uname -m)
    
    case "$arch" in
        "x86_64"|"amd64")
            IMAGE_NAME="cloudflare/cloudflared:latest"
            ;;
        "armv7l"|"armhf")
            IMAGE_NAME="cloudflare/cloudflared:latest-arm"
            ;;
        "aarch64"|"arm64")
            IMAGE_NAME="cloudflare/cloudflared:latest-arm64"
            ;;
        *)
            log "ERROR" "不支持的架构: $arch"
            exit 1
            ;;
    esac
    
    log "INFO" "检测到架构: $arch，使用镜像: $IMAGE_NAME"
}

# ============================================================
# 网络连通性检查
# ============================================================
check_network() {
    log "INFO" "检查 Cloudflare 网络连通性..."
    
    if curl -sf --max-time 10 "https://cloudflare.com" &>/dev/null; then
        log "INFO" "✅ 网络连通性正常"
        return 0
    else
        log "WARN" "⚠️  无法访问 cloudflare.com，请检查网络连接"
        read -rp "网络可能不通，是否继续？(y/N): " cont
        [[ "${cont,,}" != "y" ]] && exit 0
    fi
}

# ============================================================
# Token 安全处理
# ============================================================
validate_token() {
    local token="$1"
    
    # 基本非空检查
    if [[ -z "$token" ]]; then
        return 1
    fi
    
    # JWT格式验证（三段，由.分隔）
    local segment_count
    segment_count=$(echo "$token" | tr -cd '.' | wc -c)
    if [[ "$segment_count" -lt 2 ]]; then
        log "WARN" "Token 格式可能不正确（非标准格式），请确认后继续"
        return 1
    fi
    
    # 长度检查（Cloudflare tunnel token通常较长）
    if [[ ${#token} -lt 50 ]]; then
        log "WARN" "Token 长度异常（${#token}字符），请确认"
        return 1
    fi
    
    return 0
}

# Token安全存储（不记录到普通日志）
store_token() {
    local index="$1"
    local token="$2"
    
    mkdir -p "$(dirname "$TOKEN_STORE")"
    chmod 700 "$(dirname "$TOKEN_STORE")"
    
    # 追加存储格式：序号|时间戳（不存Token明文到日志）
    echo "TOKEN_$index=$(date +%s)" >> "$TOKEN_STORE"
    chmod 600 "$TOKEN_STORE"
    
    # 日志只记录索引，不记录Token内容
    log "INFO" "Token #$index 已验证并暂存（内容不记录日志）"
}

prompt_for_tokens() {
    local num_tunnels
    
    read -rp "请输入要部署的 Cloudflare Tunnel 容器数量: " num_tunnels
    
    if ! [[ "$num_tunnels" =~ ^[1-9][0-9]*$ ]]; then
        log "ERROR" "无效的容器数量，必须是大于 0 的整数。"
        return 1
    fi
    
    TOKEN_ARRAY=()
    
    for i in $(seq 1 "$num_tunnels"); do
        local attempts=0
        local max_attempts=3
        
        while [[ $attempts -lt $max_attempts ]]; do
            # 使用 -s 隐藏输入（安全）
            read -rsp "请输入第 $i 个 Cloudflare Tunnel Token（输入不可见）: " TOKEN
            echo ""  # 换行
            
            if [[ -z "$TOKEN" ]]; then
                log "ERROR" "Token 为空，退出脚本。"
                exit 1
            fi
            
            if validate_token "$TOKEN"; then
                TOKEN_ARRAY+=("$TOKEN")
                store_token "$i" "$TOKEN"
                break
            else
                attempts=$((attempts + 1))
                if [[ $attempts -lt $max_attempts ]]; then
                    log "WARN" "Token 格式验证警告，还可重试 $((max_attempts - attempts)) 次"
                    read -rp "是否仍要使用此 Token？(y/N): " force_use
                    if [[ "${force_use,,}" == "y" ]]; then
                        TOKEN_ARRAY+=("$TOKEN")
                        log "WARN" "用户强制接受 Token #$i（格式未通过验证）"
                        break
                    fi
                else
                    log "ERROR" "Token #$i 多次验证失败，跳过。"
                fi
            fi
        done
    done
    
    if [[ ${#TOKEN_ARRAY[@]} -eq 0 ]]; then
        log "ERROR" "未收集到任何有效 Token。"
        return 1
    fi
    
    log "INFO" "共收集到 ${#TOKEN_ARRAY[@]} 个 Token，准备部署。"
}

# ============================================================
# 唯一容器名生成
# ============================================================
generate_unique_container_name() {
    local base_name="$BASE_CONTAINER_NAME"
    local suffix=1
    local candidate="$base_name"
    
    while docker ps -a \
        --filter "name=^${candidate}$" \
        --format "{{.Names}}" | grep -q "^${candidate}$"; do
        candidate="${base_name}_${suffix}"
        suffix=$((suffix + 1))
    done
    
    echo "$candidate"
}

# ============================================================
# 网络模式选择
# ============================================================
select_network_mode() {
    echo ""
    echo "请选择 Docker 网络模式："
    echo "  1. host    - 宿主机网络（性能最佳，默认）"
    echo "  2. bridge  - 桥接网络（更好的隔离性）"
    echo "  3. 自定义  - 指定网络名称"
    
    read -rp "请选择 [1-3，默认1]: " net_choice
    net_choice=${net_choice:-1}
    
    case "$net_choice" in
        1)
            NETWORK_MODE="host"
            ;;
        2)
            NETWORK_MODE="bridge"
            ;;
        3)
            read -rp "输入自定义 Docker 网络名称: " custom_net
            if [[ -z "$custom_net" ]]; then
                log "WARN" "网络名称为空，使用默认 host 模式"
                NETWORK_MODE="host"
            else
                if ! docker network inspect "$custom_net" &>/dev/null; then
                    log "INFO" "网络 '$custom_net' 不存在，正在创建..."
                    docker network create "$custom_net"
                fi
                NETWORK_MODE="$custom_net"
            fi
            ;;
        *)
            NETWORK_MODE="host"
            ;;
    esac
    
    log "INFO" "使用网络模式: $NETWORK_MODE"
}

# ============================================================
# 协议选择
# ============================================================
select_protocol() {
    echo ""
    echo "请选择传输协议："
    echo "  1. http2 - HTTP/2（默认，兼容性好）"
    echo "  2. quic  - QUIC/UDP（延迟更低，需UDP支持）"
    echo "  3. auto  - 自动选择"
    
    read -rp "请选择 [1-3，默认1]: " proto_choice
    proto_choice=${proto_choice:-1}
    
    case "$proto_choice" in
        1) PROTOCOL="http2" ;;
        2) PROTOCOL="quic" ;;
        3) PROTOCOL="auto" ;;
        *) PROTOCOL="http2" ;;
    esac
    
    log "INFO" "使用协议: $PROTOCOL"
}

# ============================================================
# 部署容器（修复eval注入）
# ============================================================
deploy_single_cloudflared() {
    local token="$1"
    local index="$2"
    local total="$3"
    local container_name
    container_name=$(generate_unique_container_name)
    
    log "INFO" "正在部署容器: $container_name (${index}/${total})..."
    
    # 构建网络参数
    local net_args
    if [[ "$NETWORK_MODE" == "host" || "$NETWORK_MODE" == "bridge" ]]; then
        net_args="--network $NETWORK_MODE"
    else
        net_args="--network $NETWORK_MODE"
    fi
    
    # 直接使用数组构建命令（避免eval注入）
    # shellcheck disable=SC2086
    if docker run -d \
        --name "$container_name" \
        --restart=always \
        $net_args \
        --health-cmd="cloudflared tunnel info 2>/dev/null || exit 1" \
        --health-interval="${HC_INTERVAL}s" \
        --health-start-period="${HC_START_PERIOD}s" \
        --health-timeout="${HC_TIMEOUT}s" \
        --health-retries="$HC_RETRIES" \
        --memory="256m" \
        --cpus="0.5" \
        "$IMAGE_NAME" \
        tunnel --no-autoupdate run \
        --protocol "$PROTOCOL" \
        --token "$token"; then
        
        log "INFO" "✅ 容器 $container_name 部署成功 (${index}/${total})"
        echo -e "${GREEN}✅ 容器 $container_name 部署成功${NC}"
        return 0
    else
        log "ERROR" "❌ 容器 $container_name 部署失败 (${index}/${total})"
        echo -e "${RED}❌ 容器 $container_name 部署失败${NC}"
        return 1
    fi
}

deploy_multiple_cloudflared() {
    # 修复：正确的数组空值检测
    if [[ ${#TOKEN_ARRAY[@]} -eq 0 ]]; then
        log "ERROR" "未提供任何 Token，无法部署容器。"
        return 1
    fi
    
    # 选择网络模式和协议
    select_network_mode
    select_protocol
    
    local success_count=0
    local fail_count=0
    local total="${#TOKEN_ARRAY[@]}"
    
    for i in "${!TOKEN_ARRAY[@]}"; do
        local token="${TOKEN_ARRAY[$i]}"
        local index=$((i + 1))  # 修复：正确的算术表达式
        
        if deploy_single_cloudflared "$token" "$index" "$total"; then
            success_count=$((success_count + 1))
        else
            fail_count=$((fail_count + 1))
        fi
    done
    
    echo ""
    echo -e "${GREEN}部署完成: ${success_count}/${total} 成功${NC}"
    [[ $fail_count -gt 0 ]] && \
        echo -e "${RED}失败: ${fail_count}/${total}${NC}"
    
    log "INFO" "部署汇总: 成功 $success_count，失败 $fail_count，共 $total"
}

# ============================================================
# 状态检查（jq可选降级）
# ============================================================
check_status() {
    log "INFO" "正在检查容器状态..."
    
    echo ""
    echo "═══════════════════════════════════════════════"
    echo "  容器运行状态"
    echo "═══════════════════════════════════════════════"
    
    docker ps -a \
        --filter "name=^${BASE_CONTAINER_NAME}" \
        --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" \
    || log "ERROR" "无法获取容器状态"
    
    echo ""
    echo "═══════════════════════════════════════════════"
    echo "  健康检查状态"
    echo "═══════════════════════════════════════════════"
    
    local containers
    mapfile -t containers < <(
        docker ps --format "{{.Names}}" \
            --filter "name=^${BASE_CONTAINER_NAME}" 2>/dev/null
    )
    
    if [[ ${#containers[@]} -eq 0 ]]; then
        echo "未发现运行中的 cloudflared 容器。"
        return
    fi
    
    for container in "${containers[@]}"; do
        echo ""
        echo "  容器: $container"
        
        if command -v jq &>/dev/null; then
            docker inspect \
                --format "{{json .State.Health}}" \
                "$container" 2>/dev/null | \
                jq -r '.Status // "健康检查未配置"' | \
                sed 's/^/    状态: /'
        else
            # jq不可用时的降级处理
            local health_status
            health_status=$(docker inspect \
                --format "{{.State.Health.Status}}" \
                "$container" 2>/dev/null || echo "未知")
            echo "    状态: $health_status"
        fi
    done
}

# ============================================================
# 重启容器（修复子Shell exit问题）
# ============================================================
restart_container() {
    log "INFO" "正在重启 Cloudflared 容器..."
    
    local containers
    mapfile -t containers < <(
        docker ps --format "{{.Names}}" \
            --filter "name=^${BASE_CONTAINER_NAME}" 2>/dev/null
    )
    
    if [[ ${#containers[@]} -eq 0 ]]; then
        log "WARN" "未发现运行中的 cloudflared 容器。"
        return
    fi
    
    local success=0
    local fail=0
    
    # 修复：不使用管道（避免子Shell），直接遍历数组
    for container in "${containers[@]}"; do
        if docker restart "$container" &>/dev/null; then
            log "INFO" "✅ 容器 $container 重启成功"
            echo -e "${GREEN}✅ $container 重启成功${NC}"
            success=$((success + 1))
        else
            log "ERROR" "❌ 容器 $container 重启失败"
            echo -e "${RED}❌ $container 重启失败${NC}"
            fail=$((fail + 1))
        fi
    done
    
    log "INFO" "重启汇总: 成功 $success，失败 $fail"
}

# ============================================================
# 卸载容器（带错误处理）
# ============================================================
uninstall_container() {
    log "INFO" "正在卸载 Cloudflared 容器..."
    
    local containers
    mapfile -t containers < <(
        docker ps -a --format "{{.Names}}" \
            --filter "name=^${BASE_CONTAINER_NAME}" 2>/dev/null
    )
    
    if [[ ${#containers[@]} -eq 0 ]]; then
        log "WARN" "未发现 cloudflared 容器。"
        return
    fi
    
    echo "将要卸载以下容器："
    printf '  - %s\n' "${containers[@]}"
    
    read -rp "确认卸载？(y/N): " confirm
    [[ "${confirm,,}" != "y" ]] && {
        log "INFO" "用户取消卸载操作"
        return
    }
    
    for container in "${containers[@]}"; do
        # 先停止，再删除（带错误处理）
        if docker stop "$container" &>/dev/null; then
            log "INFO" "容器 $container 已停止"
        else
            log "WARN" "容器 $container 停止失败，尝试强制删除"
        fi
        
        if docker rm -f "$container" &>/dev/null; then
            log "INFO" "✅ 容器 $container 已删除"
            echo -e "${GREEN}✅ $container 已卸载${NC}"
        else
            log "ERROR" "❌ 容器 $container 删除失败"
            echo -e "${RED}❌ $container 删除失败${NC}"
        fi
    done
    
    # 询问是否删除镜像
    echo ""
    read -rp "是否同时删除 Cloudflared 镜像？(y/N): " remove_image
    remove_image=${remove_image:-n}
    
    if [[ "${remove_image,,}" == "y" ]]; then
        if docker rmi "$IMAGE_NAME" &>/dev/null; then
            log "INFO" "镜像 $IMAGE_NAME 已删除"
            echo -e "${GREEN}镜像已删除${NC}"
        else
            log "WARN" "镜像删除失败（可能有其他容器在使用）"
        fi
    fi
}

# ============================================================
# 查看容器日志
# ============================================================
view_logs() {
    local containers
    mapfile -t containers < <(
        docker ps -a --format "{{.Names}}" \
            --filter "name=^${BASE_CONTAINER_NAME}" 2>/dev/null
    )
    
    if [[ ${#containers[@]} -eq 0 ]]; then
        log "WARN" "未发现 cloudflared 容器。"
        return
    fi
    
    if [[ ${#containers[@]} -eq 1 ]]; then
        docker logs --tail 50 -f "${containers[0]}"
    else
        echo "选择要查看日志的容器："
        for i in "${!containers[@]}"; do
            echo "  $((i+1)). ${containers[$i]}"
        done
        
        read -rp "请选择 [1-${#containers[@]}]: " log_choice
        if [[ "$log_choice" =~ ^[0-9]+$ ]] && \
           [[ "$log_choice" -ge 1 ]] && \
           [[ "$log_choice" -le "${#containers[@]}" ]]; then
            docker logs --tail 50 -f "${containers[$((log_choice-1))]}"
        else
            log "WARN" "无效选择"
        fi
    fi
}

# ============================================================
# UDP缓冲区调整
# ============================================================
adjust_udp_buffer() {
    if [[ "$IS_OPENWRT" == true ]]; then
        log "INFO" "OpenWrt 系统，跳过 UDP 缓冲区调整。"
        return
    fi
    
    log "INFO" "正在调整 UDP 缓冲区大小..."
    
    local current_rmem
    current_rmem=$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)
    log "INFO" "当前 rmem_max: $current_rmem"
    
    if sudo sysctl -w net.core.rmem_max=8388608 && \
       sudo sysctl -w net.core.rmem_default=8388608; then
        log "INFO" "UDP 缓冲区已调整为 8MB"
        
        # 持久化（非OpenWrt）
        if [[ -d /etc/sysctl.d ]]; then
            echo "net.core.rmem_max=8388608" | \
                sudo tee /etc/sysctl.d/99-cloudflared.conf > /dev/null
            echo "net.core.rmem_default=8388608" | \
                sudo tee -a /etc/sysctl.d/99-cloudflared.conf > /dev/null
            log "INFO" "配置已持久化到 /etc/sysctl.d/99-cloudflared.conf"
        fi
    else
        log "ERROR" "UDP 缓冲区调整失败（可能需要root权限）"
    fi
}

# ============================================================
# 镜像更新
# ============================================================
update_image() {
    log "INFO" "正在拉取最新镜像: $IMAGE_NAME"
    
    if docker pull "$IMAGE_NAME"; then
        log "INFO" "镜像更新成功"
        echo -e "${GREEN}✅ 镜像已更新为最新版本${NC}"
        
        # 询问是否重启容器以使用新镜像
        read -rp "是否重启所有容器以应用新镜像？(y/N): " restart_all
        [[ "${restart_all,,}" == "y" ]] && restart_container
    else
        log "ERROR" "镜像拉取失败"
    fi
}

# ============================================================
# 交互式菜单
# ============================================================
show_banner() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║   Cloudflared 隧道部署管理工具 v${SCRIPT_VERSION}    ║${NC}"
    echo -e "${BLUE}║   系统: ${SYSTEM_TYPE}                           ${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════╝${NC}"
}

interactive_menu() {
    while true; do
        show_banner
        echo ""
        echo "  1. 部署 Cloudflared 容器（支持多个）"
        echo "  2. 查看容器运行状态和健康检查"
        echo "  3. 查看容器实时日志"
        echo "  4. 重启容器"
        echo "  5. 卸载容器"
        echo "  6. 更新镜像"
        echo "  7. 调整 UDP 缓冲区大小"
        echo "  8. 退出脚本"
        echo ""
        read -rp "请输入选项编号 [1-8]: " choice
        
        case "$choice" in
            1)
                check_network
                prompt_for_tokens && deploy_multiple_cloudflared
                ;;
            2)
                check_status
                ;;
            3)
                view_logs
                ;;
            4)
                restart_container
                ;;
            5)
                uninstall_container
                ;;
            6)
                update_image
                ;;
            7)
                adjust_udp_buffer
                ;;
            8)
                log "INFO" "用户退出脚本。"
                echo -e "${GREEN}再见！${NC}"
                exit 0
                ;;
            *)
                log "WARN" "无效输入: '$choice'，请重新选择。"
                ;;
        esac
        
        echo ""
        read -rp "按 Enter 键返回主菜单..." _
    done
}

# ============================================================
# 主入口
# ============================================================
main() {
    # 确保日志目录存在
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    
    log "INFO" "=== Cloudflared 部署脚本 v${SCRIPT_VERSION} 启动 ==="
    
    detect_system
    check_docker
    check_dependencies
    check_architecture
    adjust_udp_buffer
    interactive_menu
}

main "$@"
