#!/bin/bash

# --- 默认配置 ---
DEFAULT_INSTALL_DIR="/opt/shinobi-nvr"
DEFAULT_WEB_PORT=8080
TIMEZONE="Asia/Shanghai"
COMPOSE_FILE_NAME="docker-compose.yml"
BACKUP_DIR="${DEFAULT_INSTALL_DIR}/backups"

# 镜像源 (官方 vs 社区兼容版)
IMAGE_OFFICIAL="shinobisystems/shinobi:latest"
IMAGE_COMMUNITY="migoller/shinobi:latest"

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- 全局变量 ---
INSTALL_DIR=""
VIDEO_PATH=""
CONFIG_PATH=""
LOCAL_IP=""
DOCKER_COMPOSE_CMD=""
SELECTED_PORT=""
SELECTED_IMAGE=""

# --- 辅助函数 ---
log_info() { echo -e "${GREEN}[信息]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[警告]${NC} $1"; }
log_error() { echo -e "${RED}[错误]${NC} $1"; }
log_step() { echo -e "${BLUE}[步骤]${NC} $1"; }
log_success() { echo -e "${CYAN}[成功]${NC} $1"; }

# 检查 Root 权限
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "请使用 sudo 运行此脚本 (sudo ./nvr_manager.sh)"
        exit 1
    fi
}

# 获取本机局域网 IP
get_local_ip() {
    LOCAL_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n 1)
    if [ -z "$LOCAL_IP" ]; then
        LOCAL_IP="<服务器IP>"
    fi
}

# 检测端口是否被占用
check_port() {
    local port=$1
    if ss -tuln | grep -q ":$port "; then
        return 1 # 被占用
    else
        return 0 # 可用
    fi
}

# --- 核心逻辑: 环境准备 ---
ensure_docker() {
    local HAS_DOCKER=false
    if command -v docker &> /dev/null; then
        HAS_DOCKER=true
    fi

    if docker compose version &> /dev/null; then
        DOCKER_COMPOSE_CMD="docker compose"
    elif command -v docker-compose &> /dev/null; then
        DOCKER_COMPOSE_CMD="docker-compose"
    fi

    if [ "$HAS_DOCKER" = true ] && [ -n "$DOCKER_COMPOSE_CMD" ]; then
        log_info "Docker 环境已就绪 ($DOCKER_COMPOSE_CMD)."
        return
    fi

    log_step "正在安装/更新 Docker CE 及 Compose 插件..."
    apt-get update -y > /dev/null 2>&1
    apt-get install -y ca-certificates curl gnupg lsb-release > /dev/null 2>&1
    
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    apt-get update -y > /dev/null 2>&1
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /dev/null 2>&1
    
    systemctl enable --now docker
    
    DOCKER_COMPOSE_CMD="docker compose"
    log_success "Docker 安装完成."
}

# --- 配置 Docker 国内加速源 (应对拉取失败) ---
action_set_mirror() {
    check_root
    log_step "配置 Docker 国内加速源..."
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<EOF
{
  "registry-mirrors": [
    "https://mirror.ccs.tencentyun.com",
    "https://hub-mirror.c.163.com",
    "https://docker.mirrors.sjtug.sjtu.edu.cn"
  ]
}
EOF
    systemctl daemon-reload
    systemctl restart docker
    log_success "Docker 加速源配置完成，已重启 Docker 服务."
}

# --- 核心逻辑: 交互式配置 ---
interactive_config() {
    echo ""
    log_step "步骤 1: 选择镜像版本 (部署失败的替代方案)"
    echo "1) 官方镜像 (shinobisystems/shinobi) - 推荐，适合 x86 服务器"
    echo "2) 社区镜像 (migoller/shinobi) - 备选，适合 ARM 设备或官方运行报错时使用"
    read -p "请选择镜像 [1-2, 默认1]: " img_choice
    if [ "$img_choice" == "2" ]; then
        SELECTED_IMAGE=$IMAGE_COMMUNITY
        log_info "已选择: 社区兼容镜像"
    else
        SELECTED_IMAGE=$IMAGE_OFFICIAL
        log_info "已选择: 官方镜像"
    fi

    echo ""
    log_step "步骤 2: 配置 Web 访问端口"
    SELECTED_PORT=$DEFAULT_WEB_PORT
    while true; do
        if check_port "$SELECTED_PORT"; then
            log_info "端口 $SELECTED_PORT 可用."
            break
        else
            log_warn "端口 $SELECTED_PORT 已被其他程序占用!"
            read -p "请输入一个新的端口号 (如 8081, 8888): " new_port
            if [[ "$new_port" =~ ^[0-9]+$ ]]; then
                SELECTED_PORT=$new_port
            fi
        fi
    done

    echo ""
    log_step "步骤 3: 配置录像存储路径"
    echo "默认路径: ${DEFAULT_INSTALL_DIR}/videos"
    read -p "请输入录像保存的绝对路径 (直接回车使用默认): " input_path
    
    if [ -z "$input_path" ]; then
        VIDEO_PATH="${DEFAULT_INSTALL_DIR}/videos"
    else
        VIDEO_PATH="${input_path%/}"
    fi

    CONFIG_PATH="${DEFAULT_INSTALL_DIR}/config"
    INSTALL_DIR="${DEFAULT_INSTALL_DIR}"

    if [ ! -d "$VIDEO_PATH" ]; then
        mkdir -p "$VIDEO_PATH" || { log_error "无法创建目录，请检查权限"; return 1; }
    fi

    chmod -R 777 "$VIDEO_PATH"
    mkdir -p "$CONFIG_PATH"
    chmod -R 777 "$CONFIG_PATH"
    log_success "存储路径已设定: $VIDEO_PATH"
}

# --- 核心逻辑: 生成 Compose 文件 ---
generate_compose() {
    log_step "生成 Docker Compose 配置文件..."
    mkdir -p "${INSTALL_DIR}"
    
    HW_ACCEL_BLOCK=""
    if [ -d "/dev/dri" ]; then
        HW_ACCEL_BLOCK="    devices:
      - /dev/dri:/dev/dri"
        log_info "检测到显卡设备 (/dev/dri)，已开启硬件加速映射."
    fi

    cat > "${INSTALL_DIR}/${COMPOSE_FILE_NAME}" <<EOF
version: '3.8'
services:
  shinobi:
    image: ${SELECTED_IMAGE}
    container_name: shinobi-nvr
    restart: unless-stopped
    ports:
      - "${SELECTED_PORT}:8080"
    volumes:
      - ./config:/config
      - ${VIDEO_PATH}:/videos
      - /dev/shm:/dev/shm
    environment:
      - TZ=${TIMEZONE}
${HW_ACCEL_BLOCK}
    security_opt:
      - no-new-privileges:true
EOF
}

# --- 动作: 部署/更新 ---
action_deploy() {
    check_root
    get_local_ip
    ensure_docker
    interactive_config || return
    generate_compose
    
    log_step "正在拉取镜像并启动服务..."
    cd "${INSTALL_DIR}"
    
    if ! $DOCKER_COMPOSE_CMD pull; then
        echo ""
        log_error "镜像拉取失败！这通常是因为国内网络访问 Docker Hub 受限。"
        log_warn "建议尝试方案："
        log_warn "1. 在主菜单选择 [8] 一键配置 Docker 国内加速源，然后重试部署。"
        log_warn "2. 重新部署时，在步骤1选择 [2] 社区镜像 试试。"
        return
    fi
    
    $DOCKER_COMPOSE_CMD up -d
    sleep 5
    
    if [ "$(docker ps -q -f name=shinobi-nvr)" ]; then
        echo ""
        echo "=========================================="
        echo -e "${GREEN}       部署成功!                  ${NC}"
        echo "=========================================="
        log_info "面板地址: http://${LOCAL_IP}:${SELECTED_PORT}"
        echo -e "${YELLOW}查看初始密码请在主菜单选择 [5] 实时查看日志${NC}"
        echo "默认账号(参考): admin@shinobi.video (或 admin)"
        log_info "录像位置: ${VIDEO_PATH}"
    else
        log_error "容器启动失败，请选择 [5] 查看日志排查问题。"
    fi
}

# --- 动作: 状态与日志 ---
action_status() {
    check_root; ensure_docker
    if [ ! -f "${DEFAULT_INSTALL_DIR}/${COMPOSE_FILE_NAME}" ]; then log_warn "未安装"; return; fi
    cd "${DEFAULT_INSTALL_DIR}"
    $DOCKER_COMPOSE_CMD ps
    
    if [ -d "$VIDEO_PATH" ]; then
        log_info "录像占用空间: $(du -sh "$VIDEO_PATH" 2>/dev/null | cut -f1)"
    fi
}

action_logs() {
    check_root; ensure_docker
    if [ ! -f "${DEFAULT_INSTALL_DIR}/${COMPOSE_FILE_NAME}" ]; then log_warn "未安装"; return; fi
    log_info "正在输出实时日志... (按 Ctrl+C 退出查看)"
    echo "------------------------------------------------"
    cd "${DEFAULT_INSTALL_DIR}"
    $DOCKER_COMPOSE_CMD logs -f
}

# --- 动作: 停止/重启 ---
action_stop() {
    check_root; ensure_docker
    if [ ! -f "${DEFAULT_INSTALL_DIR}/${COMPOSE_FILE_NAME}" ]; then log_warn "未安装"; return; fi
    log_step "停止服务..."
    cd "${DEFAULT_INSTALL_DIR}" && $DOCKER_COMPOSE_CMD down
    log_success "服务已停止."
}

action_restart() {
    check_root; ensure_docker
    if [ ! -f "${DEFAULT_INSTALL_DIR}/${COMPOSE_FILE_NAME}" ]; then log_warn "未安装"; return; fi
    log_step "重启服务..."
    cd "${DEFAULT_INSTALL_DIR}" && $DOCKER_COMPOSE_CMD restart
    log_success "服务已重启."
}

# --- 动作: 备份与卸载 ---
action_backup() {
    check_root
    if [ ! -d "${DEFAULT_INSTALL_DIR}/config" ]; then log_warn "无配置文件可备份."; return; fi
    mkdir -p "$BACKUP_DIR"
    BACKUP_FILE="${BACKUP_DIR}/shinobi_backup_$(date +"%Y%m%d_%H%M%S").tar.gz"
    tar -czf "$BACKUP_FILE" -C "${DEFAULT_INSTALL_DIR}" config
    log_success "备份完成: $BACKUP_FILE"
}

action_uninstall() {
    check_root; ensure_docker
    if [ ! -f "${DEFAULT_INSTALL_DIR}/${COMPOSE_FILE_NAME}" ]; then log_warn "未安装"; return; fi
    
    echo ""; log_warn "!!! 卸载警告 !!!"
    read -p "是否保留录像文件? (y/n): " keep_videos
    cd "${DEFAULT_INSTALL_DIR}" && $DOCKER_COMPOSE_CMD down
    
    if [[ "$keep_videos" =~ ^[Nn]$ ]]; then
        SAVED_PATH=$(grep -A1 'volumes:' ${COMPOSE_FILE_NAME} | grep '/videos' | awk '{print $1}' | sed 's/- //')
        if [ -n "$SAVED_PATH" ] && [ "$SAVED_PATH" != "./videos" ]; then
             read -p "输入 'yes' 确认删除 $SAVED_PATH: " confirm
             if [ "$confirm" == "yes" ]; then rm -rf "${SAVED_PATH}"; log_info "录像已删除."; fi
        fi
    fi
    rm -rf "${DEFAULT_INSTALL_DIR}"
    log_success "卸载完成."
}

# --- 主菜单 ---
show_menu() {
    clear
    echo "=========================================="
    echo "   Ubuntu 家庭监控 NVR 管理工具 (终极版)  "
    echo "=========================================="
    echo " ---------- 部署与维护 ----------"
    echo "  1. 🚀 部署 / 更新 NVR 服务 (支持多版本)"
    echo "  2. 🔄 重启 NVR 服务"
    echo "  3. ⏹️  停止 NVR 服务"
    echo " ---------- 监控与排障 ----------"
    echo "  4. 📊 查看运行状态 & 磁盘占用"
    echo "  5. 📄 实时查看运行日志 (获取密码/排障)"
    echo " ---------- 数据与环境 ----------"
    echo "  6. 💾 备份配置文件"
    echo "  7. 🗑️  完全卸载服务"
    echo "  8. ⚡ 配置 Docker 国内加速源 (解决下载失败)"
    echo "  0. ❌ 退出"
    echo "=========================================="
    read -p "请选择操作 [0-8]: " option
}

main() {
    while true; do
        show_menu
        case $option in
            1) action_deploy ;;
            2) action_restart ;;
            3) action_stop ;;
            4) action_status ;;
            5) action_logs ;;
            6) action_backup ;;
            7) action_uninstall ;;
            8) action_set_mirror ;;
            0) log_info "退出程序."; exit 0 ;;
            *) log_warn "无效选项，请重新选择." ;;
        esac
        echo ""
        read -p "按回车键返回主菜单..."
    done
}

main
