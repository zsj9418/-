#!/bin/bash
# Sub-Store Docker一键管理脚本
# 功能：支持企业微信通知、交互式配置、自定义路径和完整管理功能
# 网络模式：支持 host 模式和 bridge 模式（可指定端口）
# 通知内容：个性化通知，包含前端和后端版本号

# 配置区（默认值）
DATA_DIR="/opt/substore/data"
BACKUP_DIR="/opt/substore/backup"
CONTAINER_NAME="substore"
TIMEZONE="Asia/Shanghai"
IMAGE_NAME="xream/sub-store"
SUB_STORE_FRONTEND_BACKEND_PATH="/zsj9418"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# 初始化变量
WECHAT_WEBHOOK=""
SUB_STORE_BACKEND_SYNC_CRON=""
USE_HOST_NETWORK=true
HOST_PORT_1=""
HOST_PORT_2=""

# 日志记录函数
log() {
  local level=$1
  local message=$2
  local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  case $level in
    "INFO") echo -e "${GREEN}[INFO] $timestamp - $message${NC}" ;;
    "WARN") echo -e "${YELLOW}[WARN] $timestamp - $message${NC}" ;;
    "ERROR") echo -e "${RED}[ERROR] $timestamp - $message${NC}" ;;
  esac
}

# 企业微信通知函数
send_wechat() {
  local message=$1
  if [ -z "$WECHAT_WEBHOOK" ]; then
    log "WARN" "未配置企业微信机器人地址"
    return
  fi

  curl -s -H "Content-Type: application/json" \
    -d "{\"msgtype\":\"text\",\"text\":{\"content\":\"$message\"}}" \
    "$WECHAT_WEBHOOK" >/dev/null
}

# 获取容器版本号
get_container_version() {
  docker exec $CONTAINER_NAME sh -c "cat /app/package.json | grep version" | awk -F '"' '{print $4}'
}

# 检查端口是否被占用
check_port() {
  local port=$1
  if lsof -i :$port &>/dev/null; then
    log "ERROR" "端口 $port 已被占用"
    return 1
  else
    log "INFO" "端口 $port 可用"
    return 0
  fi
}

# 交互式配置
interactive_config() {
  # 要求输入企业微信地址
  while true; do
    read -p "请输入企业微信机器人地址: " WECHAT_WEBHOOK
    if [[ "$WECHAT_WEBHOOK" =~ ^https://qyapi.weixin.qq.com/cgi-bin/webhook.* ]]; then
      break
    else
      log "ERROR" "地址格式错误，请重新输入"
    fi
  done

  # 配置同步计划
  read -p "请输入后端同步计划cron表达式（默认55 23 * * *）: " cron_input
  SUB_STORE_BACKEND_SYNC_CRON=${cron_input:-"55 23 * * *"}

  # 询问是否使用 host 网络模式
  read -p "是否使用 host 网络模式？[Y/n] " USE_HOST_NETWORK_INPUT
  if [[ "$USE_HOST_NETWORK_INPUT" =~ ^[Nn]$ ]]; then
    USE_HOST_NETWORK=false
    # 询问并检测端口
    while true; do
      read -p "请输入后端服务端口号（默认3000）: " HOST_PORT_1
      HOST_PORT_1=${HOST_PORT_1:-3000}
      if check_port $HOST_PORT_1; then
        break
      fi
    done
    while true; do
      read -p "请输入前端服务端口号（默认3001）: " HOST_PORT_2
      HOST_PORT_2=${HOST_PORT_2:-3001}
      if check_port $HOST_PORT_2; then
        break
      fi
    done
  fi
}

# 安装依赖
install_dependencies() {
  if ! command -v docker &> /dev/null; then
    log "INFO" "正在安装Docker..."
    curl -fsSL https://get.docker.com | sh || {
      log "ERROR" "Docker安装失败"
      exit 1
    }
    systemctl enable --now docker
  fi

  if ! command -v docker-compose &> /dev/null; then
    log "INFO" "正在安装Docker Compose..."
    LATEST_COMPOSE=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep tag_name | cut -d '"' -f 4)
    curl -L "https://github.com/docker/compose/releases/download/${LATEST_COMPOSE}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose || {
      log "ERROR" "Docker Compose安装失败"
      exit 1
    }
    chmod +x /usr/local/bin/docker-compose
  fi
}

# 检查容器状态
check_container_status() {
  if docker ps -a --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
    CONTAINER_STATUS=$(docker inspect -f '{{.State.Status}}' ${CONTAINER_NAME})
    CONTAINER_RUNNING=$(docker inspect -f '{{.State.Running}}' ${CONTAINER_NAME})
    return 0
  else
    return 1
  fi
}

# 备份配置
backup_config() {
  if [ -d "$DATA_DIR" ]; then
    log "INFO" "正在备份配置..."
    TIMESTAMP=$(date +%Y%m%d%H%M%S)
    BACKUP_FILE="$BACKUP_DIR/config_$TIMESTAMP.tar.gz"
    mkdir -p "$BACKUP_DIR"
    tar -czf "$BACKUP_FILE" -C "$DATA_DIR" .
    log "INFO" "配置已备份到: $BACKUP_FILE"
  else
    log "WARN" "未找到配置目录，跳过备份"
  fi
}

# 恢复配置
restore_config() {
  LATEST_BACKUP=$(ls -t "$BACKUP_DIR"/*.tar.gz 2>/dev/null | head -1)
  if [ -f "$LATEST_BACKUP" ]; then
    log "INFO" "正在恢复配置..."
    tar -xzf "$LATEST_BACKUP" -C "$DATA_DIR"
    log "INFO" "配置已从 $LATEST_BACKUP 恢复"
  else
    log "WARN" "未找到备份文件，跳过恢复"
  fi
}

# 卸载 Sub-Store
uninstall_substore() {
  if check_container_status; then
    log "INFO" "正在卸载 Sub-Store..."
    docker stop $CONTAINER_NAME
    docker rm $CONTAINER_NAME
    log "INFO" "容器已卸载"
  fi

  read -p "是否删除镜像？[y/N] " REMOVE_IMAGE
  if [[ "$REMOVE_IMAGE" =~ ^[Yy]$ ]]; then
    IMAGE_ID=$(docker images -q $IMAGE_NAME)
    if [ -n "$IMAGE_ID" ]; then
      docker rmi $IMAGE_ID
      log "INFO" "镜像已删除"
    fi
  fi

  read -p "是否删除数据目录？[y/N] " REMOVE_DATA
  if [[ "$REMOVE_DATA" =~ ^[Yy]$ ]]; then
    rm -rf "$DATA_DIR"
    log "INFO" "数据目录已删除"
  fi

  read -p "是否重新安装 Sub-Store？[y/N] " REINSTALL
  if [[ "$REINSTALL" =~ ^[Yy]$ ]]; then
    install_substore
  else
    log "INFO" "操作完成，退出脚本"
    exit 0
  fi
}

# 安装 Sub-Store
install_substore() {
  log "INFO" "正在拉取最新镜像..."
  docker pull $IMAGE_NAME:latest

  log "INFO" "正在启动容器..."
  if $USE_HOST_NETWORK; then
    docker run -d \
      --network host \
      --name $CONTAINER_NAME \
      --restart=always \
      -v "${DATA_DIR}:/opt/app/data" \
      -e "SUB_STORE_PUSH_SERVICE=${WECHAT_WEBHOOK}" \
      -e "SUB_STORE_BACKEND_SYNC_CRON=${SUB_STORE_BACKEND_SYNC_CRON}" \
      -e "SUB_STORE_FRONTEND_BACKEND_PATH=${SUB_STORE_FRONTEND_BACKEND_PATH}" \
      -e TZ=${TIMEZONE} \
      $IMAGE_NAME || {
        log "ERROR" "容器启动失败"
        exit 1
      }
  else
    docker run -d \
      --name $CONTAINER_NAME \
      --restart=always \
      -p $HOST_PORT_1:3000 \
      -p $HOST_PORT_2:3001 \
      -v "${DATA_DIR}:/opt/app/data" \
      -e "SUB_STORE_PUSH_SERVICE=${WECHAT_WEBHOOK}" \
      -e "SUB_STORE_BACKEND_SYNC_CRON=${SUB_STORE_BACKEND_SYNC_CRON}" \
      -e "SUB_STORE_FRONTEND_BACKEND_PATH=${SUB_STORE_FRONTEND_BACKEND_PATH}" \
      -e TZ=${TIMEZONE} \
      $IMAGE_NAME || {
        log "ERROR" "容器启动失败"
        exit 1
      }
  fi

  if check_container_status; then
    # 获取版本号
    VERSION=$(get_container_version)
    # 发送通知
    send_wechat "Sub-Store 部署成功\n服务器: $(hostname)\n时间: $(date +'%F %T')\n版本号: $VERSION"
    log "INFO" "Sub-Store 已成功启动"
    if $USE_HOST_NETWORK; then
      log "INFO" "后端服务地址: http://<服务器IP>:3000${SUB_STORE_FRONTEND_BACKEND_PATH}"
      log "INFO" "前端服务地址: http://<服务器IP>:3001${SUB_STORE_FRONTEND_BACKEND_PATH}"
    else
      log "INFO" "后端服务地址: http://<服务器IP>:${HOST_PORT_1}${SUB_STORE_FRONTEND_BACKEND_PATH}"
      log "INFO" "前端服务地址: http://<服务器IP>:${HOST_PORT_2}${SUB_STORE_FRONTEND_BACKEND_PATH}"
    fi
  else
    log "ERROR" "容器启动失败，请检查日志"
    exit 1
  fi
}

# 主流程
main() {
  # 交互式配置
  interactive_config

  # 安装依赖
  install_dependencies

  # 检查现有容器
  if check_container_status; then
    read -p "检测到已有容器，是否卸载并重新安装？[y/N] " reinstall
    if [[ "$reinstall" =~ [Yy] ]]; then
      uninstall_substore
    else
      log "INFO" "操作已取消"
      exit 0
    fi
  fi

  # 启动容器
  install_substore
}

# 执行入口
main "$@"
