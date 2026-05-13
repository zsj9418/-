#!/bin/bash

set -e

# --- 默认配置 ---
DEFAULT_INSTALL_DIR="/opt/shinobi-nvr"
DEFAULT_WEB_PORT=8080
TIMEZONE="Asia/Shanghai"
COMPOSE_FILE_NAME="docker-compose.yml"
BACKUP_DIR="${DEFAULT_INSTALL_DIR}/backups"

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
DOCKER_COMPOSE_CMD="" # 动态存储 compose 命令

# --- 辅助函数 ---
log_info() { echo -e "${GREEN}[信息]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[警告]${NC} $1"; }
log_error() { echo -e "${RED}[错误]${NC} $1"; exit 1; }
log_step() { echo -e "${BLUE}[步骤]${NC} $1"; }
log_success() { echo -e "${CYAN}[成功]${NC} $1"; }

# 检查 Root 权限
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "请使用 sudo 运行此脚本 (sudo ./nvr_manager_cn.sh)"
    fi
}

# 获取本机局域网 IP
get_local_ip() {
    LOCAL_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n 1)
    if [ -z "$LOCAL_IP" ]; then
        LOCAL_IP="<服务器IP>"
    fi
}

# --- 核心逻辑: 环境准备 ---
ensure_docker() {
    # 1. 检测是否安装了 Docker
    local HAS_DOCKER=false
    if command -v docker &> /dev/null; then
        HAS_DOCKER=true
    fi

    # 2. 检测 Compose 版本 (优先 V2，降级 V1)
    if docker compose version &> /dev/null; then
        DOCKER_COMPOSE_CMD="docker compose"
    elif command -v docker-compose &> /dev/null; then
        DOCKER_COMPOSE_CMD="docker-compose"
    fi

    # 3. 如果 Docker 和 Compose 都存在，直接返回
    if [ "$HAS_DOCKER" = true ] && [ -n "$DOCKER_COMPOSE_CMD" ]; then
        log_info "Docker 环境已就绪 (使用: $DOCKER_COMPOSE_CMD)."
        return
    fi

    # 4. 如果不完整，开始安装/更新
    log_step "正在安装/更新 Docker CE 及 Compose 插件..."
    
    # 防止旧版卸载冲突，先更新包列表
    apt-get update -y > /dev/null 2>&1
    apt-get install -y ca-certificates curl gnupg lsb-release > /dev/null 2>&1
    
    install -m 0755 -d /etc/apt/keyrings
    # 覆盖已存在的gpg密钥文件以防报错
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    apt-get update -y > /dev/null 2>&1
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /dev/null 2>&1
    
    systemctl enable --now docker
    
    # 重新检测命令
    DOCKER_COMPOSE_CMD="docker compose"
    log_success "Docker 及 Compose 安装完成."
}

# --- 核心逻辑: 存储配置与检查 ---
configure_storage() {
    echo ""
    log_step "配置录像存储路径"
    echo "----------------------------------------"
    echo "提示: 建议使用外置硬盘或大容量分区."
    echo "默认路径: ${DEFAULT_INSTALL_DIR}/videos"
    echo ""
    
    read -p "请输入录像保存的绝对路径 (直接回车使用默认): " input_path
    
    if [ -z "$input_path" ]; then
        VIDEO_PATH="${DEFAULT_INSTALL_DIR}/videos"
    else
        VIDEO_PATH="${input_path%/}"
    fi

    CONFIG_PATH="${DEFAULT_INSTALL_DIR}/config"
    INSTALL_DIR="${DEFAULT_INSTALL_DIR}"

    if [ -d "$(dirname "$VIDEO_PATH")" ]; then
        AVAILABLE_SPACE=$(df -BG "$(dirname "$VIDEO_PATH")" | tail -1 | awk '{print $4}' | sed 's/G//')
        if [ "$AVAILABLE_SPACE" -lt 10 ]; then
            log_warn "警告: 目标磁盘剩余空间不足 10GB (${AVAILABLE_SPACE}GB). 录像可能很快写满磁盘!"
            read -p "是否继续? (y/n): " confirm_space
            if [[ ! "$confirm_space" =~ ^[Yy]$ ]]; then
                log_error "用户取消操作."
            fi
        fi
    fi

    if [ ! -d "$VIDEO_PATH" ]; then
        log_warn "目录不存在: $VIDEO_PATH"
        read -p "是否自动创建该目录? (y/n): " create_dir
        if [[ "$create_dir" =~ ^[Yy]$ ]]; then
            mkdir -p "$VIDEO_PATH"
            log_info "目录已创建."
        else
            log_error "存储目录必须存在. 请手动创建后重试."
        fi
    fi

    log_info "正在设置目录权限..."
    chmod -R 777 "$VIDEO_PATH"
    mkdir -p "$CONFIG_PATH"
    chmod -R 777 "$CONFIG_PATH"
    
    log_success "存储路径已设定: $VIDEO_PATH"
}

# --- 核心逻辑: 生成 Compose 文件 ---
generate_compose() {
    log_step "生成 Docker Compose 配置文件..."
    
    mkdir -p "${INSTALL_DIR}"
    
    # 动态生成 devices 块，防止在无显卡环境报错
    HW_ACCEL_BLOCK=""
    if [ -d "/dev/dri" ]; then
        HW_ACCEL_BLOCK="    devices:
      - /dev/dri:/dev/dri"
        log_info "检测到显卡设备 (/dev/dri)，已启用硬件加速支持."
    else
        log_warn "未检测到显卡设备，将使用 CPU 进行视频处理."
    fi

    cat > "${INSTALL_DIR}/${COMPOSE_FILE_NAME}" <<EOF
version: '3.8'
services:
  shinobi:
    image: shinobisystems/shinobi:latest
    container_name: shinobi-nvr
    restart: unless-stopped
    ports:
      - "${DEFAULT_WEB_PORT}:8080"
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
    log_success "配置文件已生成."
}

# --- 动作: 部署/更新 ---
action_deploy() {
    log_step "开始部署/更新 Shinobi NVR..."
    
    check_root
    get_local_ip
    ensure_docker
    configure_storage
    generate_compose
    
    log_step "正在拉取最新镜像并启动服务 (使用 $DOCKER_COMPOSE_CMD)..."
    cd "${INSTALL_DIR}"
    $DOCKER_COMPOSE_CMD pull
    $DOCKER_COMPOSE_CMD up -d
    
    sleep 5
    
    if [ "$(docker ps -q -f name=shinobi-nvr)" ]; then
        echo ""
        echo "=========================================="
        echo -e "${GREEN}       部署成功!                  ${NC}"
        echo "=========================================="
        echo ""
        log_info "访问地址: http://${LOCAL_IP}:${DEFAULT_WEB_PORT}"
        echo ""
        log_warn "重要: 请立即获取初始管理员密码:"
        echo -e "${YELLOW}   docker logs shinobi-nvr 2>&1 | grep 'Super User Password'${NC}"
        echo ""
        log_info "默认用户名: admin"
        log_info "录像存储位置: ${VIDEO_PATH}"
        echo ""
    else
        log_error "部署失败. 请查看日志: docker logs shinobi-nvr"
    fi
}

# --- 动作: 状态检查 ---
action_status() {
    check_root
    ensure_docker
    if [ ! -f "${DEFAULT_INSTALL_DIR}/${COMPOSE_FILE_NAME}" ]; then
        log_warn "未找到安装文件. 请先执行部署."
        return
    fi

    echo ""
    log_step "服务运行状态"
    echo "----------------------------------------"
    cd "${DEFAULT_INSTALL_DIR}"
    $DOCKER_COMPOSE_CMD ps
    echo ""
    
    log_info "最近日志 (最后 15 行):"
    echo "----------------------------------------"
    $DOCKER_COMPOSE_CMD logs --tail=15
    echo ""
    
    if [ -d "$VIDEO_PATH" ]; then
        USAGE=$(du -sh "$VIDEO_PATH" 2>/dev/null | cut -f1)
        log_info "当前录像文件夹占用空间: ${USAGE}"
    fi
}

# --- 动作: 停止服务 ---
action_stop() {
    check_root
    ensure_docker
    if [ ! -f "${DEFAULT_INSTALL_DIR}/${COMPOSE_FILE_NAME}" ]; then
        log_warn "服务未安装."
        return
    fi
    
    log_step "正在停止 Shinobi NVR..."
    cd "${DEFAULT_INSTALL_DIR}"
    $DOCKER_COMPOSE_CMD down
    log_success "服务已停止."
}

# --- 动作: 备份配置 ---
action_backup() {
    check_root
    if [ ! -d "${DEFAULT_INSTALL_DIR}/config" ]; then
        log_warn "未找到配置文件，无法备份."
        return
    fi

    mkdir -p "$BACKUP_DIR"
    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
    BACKUP_FILE="${BACKUP_DIR}/shinobi_config_backup_${TIMESTAMP}.tar.gz"
    
    log_step "正在备份配置文件..."
    tar -czf "$BACKUP_FILE" -C "${DEFAULT_INSTALL_DIR}" config
    
    if [ -f "$BACKUP_FILE" ]; then
        log_success "备份完成: $BACKUP_FILE"
    else
        log_error "备份失败."
    fi
}

# --- 动作: 卸载 ---
action_uninstall() {
    check_root
    ensure_docker
    if [ ! -f "${DEFAULT_INSTALL_DIR}/${COMPOSE_FILE_NAME}" ]; then
        log_warn "服务未安装."
        return
    fi

    echo ""
    log_warn "!!! 卸载警告 !!!"
    echo "----------------------------------------"
    echo "此操作将删除 Shinobi 程序容器及配置文件."
    read -p "是否保留录像文件? (强烈建议选 y) (y/n): " keep_videos
    
    cd "${DEFAULT_INSTALL_DIR}"
    $DOCKER_COMPOSE_CMD down
    
    if [[ "$keep_videos" =~ ^[Nn]$ ]]; then
        echo ""
        log_warn "您选择了不保留录像."
        SAVED_VIDEO_PATH=$(grep -A1 'volumes:' ${COMPOSE_FILE_NAME} | grep '/videos' | awk '{print $1}' | sed 's/- //')
        
        if [ -n "$SAVED_VIDEO_PATH" ] && [ "$SAVED_VIDEO_PATH" != "./videos" ]; then
             log_warn "即将删除路径: ${SAVED_VIDEO_PATH}"
             read -p "请输入 'yes' 确认删除所有录像数据: " confirm_del
             if [ "$confirm_del" == "yes" ]; then
                 rm -rf "${SAVED_VIDEO_PATH}"
                 log_info "录像数据已删除."
             else
                 log_info "取消删除录像."
             fi
        else
            log_info "录像位于默认卷或未定义，请手动清理."
        fi
    else
        log_info "录像文件已保留在: ${VIDEO_PATH:-未知路径}"
    fi

    log_step "正在删除程序文件..."
    cd /
    rm -rf "${DEFAULT_INSTALL_DIR}"
    log_success "卸载完成."
}

# --- 主菜单 ---
show_menu() {
    clear
    echo "=========================================="
    echo "   Ubuntu 家庭监控 NVR 管理工具 (Shinobi) "
    echo "=========================================="
    echo "1. 部署 / 更新 NVR 服务"
    echo "2. 查看运行状态 & 日志"
    echo "3. 停止服务"
    echo "4. 备份配置文件"
    echo "5. 卸载服务"
    echo "0. 退出"
    echo "------------------------------------------"
    read -p "请选择操作 [0-5]: " option
}

main() {
    while true; do
        show_menu
        case $option in
            1) action_deploy ;;
            2) action_status ;;
            3) action_stop ;;
            4) action_backup ;;
            5) action_uninstall ;;
            0) log_info "退出程序."; exit 0 ;;
            *) log_warn "无效选项，请重新选择." ;;
        esac
        echo ""
        read -p "按回车键继续..."
    done
}

main
