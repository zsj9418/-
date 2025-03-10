#!/bin/bash
# Docker管理脚本
# 功能：支持 Watchtower 和 Sub-Store 的部署、通知、日志记录和数据备份/恢复
# 增强功能：用户可以选择网络模式（bridge 或 host），支持自定义端口。

# 配置区（默认值）
DATA_DIR="/opt/substore/data"
BACKUP_DIR="/opt/substore/backup"
LOG_FILE="/var/log/docker_management.log"
CONTAINER_NAME="substore"
WATCHTOWER_CONTAINER_NAME="watchtower"
TIMEZONE="Asia/Shanghai"
SUB_STORE_IMAGE_NAME="xream/sub-store"
WATCHTOWER_IMAGE_NAME="containrrr/watchtower"
DEFAULT_SUB_STORE_PATH="/12345678"  # 修改默认路径

# 默认端口
DEFAULT_FRONTEND_PORT=3000
DEFAULT_BACKEND_PORT=3001

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# 初始化变量
ARCH=""
OS=""
WECHAT_WEBHOOK=""
TELEGRAM_URL=""
SUB_STORE_BACKEND_SYNC_CRON=""
NETWORK_MODE="bridge"  # 默认网络模式
HOST_PORT_1=""
HOST_PORT_2=""
SUB_STORE_FRONTEND_BACKEND_PATH=""

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
  echo "[$level] $timestamp - $message" >> "$LOG_FILE"
}

# 检测设备架构和操作系统
detect_system() {
  log "INFO" "正在检测设备架构和操作系统..."
  ARCH=$(uname -m)
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
  else
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  fi
  log "INFO" "设备架构: $ARCH, 操作系统: $OS"
}

# 检测端口是否可用
check_port_available() {
  local port=$1
  if lsof -i:"$port" >/dev/null 2>&1; then
    return 1  # 端口被占用
  else
    return 0  # 端口可用
  fi
}

# 提示用户输入端口
prompt_for_port() {
  local prompt_message=$1
  local default_port=$2
  local port=""

  while true; do
    read -p "$prompt_message [$default_port]: " port
    port=${port:-$default_port}  # 如果用户未输入，使用默认端口
    if [[ $port =~ ^[0-9]+$ ]] && [ $port -ge 1 ] && [ $port -le 65535 ]; then
      if check_port_available "$port"; then
        echo "$port"
        return
      else
        log "WARN" "端口 $port 已被占用，请选择其他端口"
      fi
    else
      log "WARN" "无效的端口号，请输入1到65535之间的数字"
    fi
  done
}

# 提示用户输入路径
prompt_for_path() {
  local default_path=$(basename "$DEFAULT_SUB_STORE_PATH")
  local user_input=""
  read -p "请输入 Sub-Store 前后端路径（只需输入路径名，不需加/） [$default_path]: " user_input
  user_input=${user_input:-$default_path}
  SUB_STORE_FRONTEND_BACKEND_PATH="/${user_input}"
  log "INFO" "设置前后端路径为: $SUB_STORE_FRONTEND_BACKEND_PATH"
}

# 安装依赖（根据系统和架构）
install_dependencies() {
  log "INFO" "正在安装依赖..."
  if ! command -v docker &> /dev/null; then
    if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
      apt update && apt install -y curl lsof || {
        log "ERROR" "依赖安装失败，请检查网络连接"
        exit 1
      }
      curl -fsSL https://get.docker.com | sh || {
        log "ERROR" "Docker安装失败"
        exit 1
      }
    elif [[ "$OS" == "centos" || "$OS" == "rhel" ]]; then
      yum install -y curl lsof || {
        log "ERROR" "依赖安装失败，请检查网络连接"
        exit 1
      }
      curl -fsSL https://get.docker.com | sh || {
        log "ERROR" "Docker安装失败"
        exit 1
      }
    else
      log "ERROR" "不支持的操作系统: $OS"
      exit 1
    fi
    systemctl enable --now docker
    log "INFO" "Docker 已成功安装"
  else
    log "INFO" "Docker 已存在，跳过安装"
  fi
}

# 部署 Watchtower
install_watchtower() {
  log "INFO" "正在部署 Watchtower..."
  docker run -d \
    --name $WATCHTOWER_CONTAINER_NAME \
    --restart=always \
    --net=host \
    -v /var/run/docker.sock:/var/run/docker.sock \
    $WATCHTOWER_IMAGE_NAME \
    --cleanup \
    -i 3600 \
    --warn-on-head-failure never \
    --notification-url "$TELEGRAM_URL" \
    --notification-title-tag "Watchtower" || {
      log "ERROR" "Watchtower 部署失败"
      exit 1
    }
  log "INFO" "Watchtower 部署成功"
}

# 部署 Sub-Store
install_substore() {
  log "INFO" "正在拉取最新镜像..."
  docker pull $SUB_STORE_IMAGE_NAME

  # 提示用户选择网络模式
  while true; do
    read -p "请选择网络模式 (bridge 或 host) [默认: bridge]: " network_mode
    network_mode=${network_mode:-bridge}
    if [[ "$network_mode" == "bridge" || "$network_mode" == "host" ]]; then
      NETWORK_MODE="$network_mode"
      break
    else
      log "WARN" "无效的网络模式，请重新输入"
    fi
  done

  # 提示用户输入路径
  prompt_for_path

  log "INFO" "正在启动容器，网络模式: $NETWORK_MODE"
  if [[ "$NETWORK_MODE" == "host" ]]; then
    docker run -d \
      --network host \
      --name $CONTAINER_NAME \
      --restart=always \
      -v "${DATA_DIR}:/opt/app/data" \
      -e "SUB_STORE_PUSH_SERVICE=${WECHAT_WEBHOOK}" \
      -e "SUB_STORE_BACKEND_SYNC_CRON=${SUB_STORE_BACKEND_SYNC_CRON}" \
      -e "SUB_STORE_FRONTEND_BACKEND_PATH=${SUB_STORE_FRONTEND_BACKEND_PATH}" \
      -e TZ=${TIMEZONE} \
      $SUB_STORE_IMAGE_NAME || {
        log "ERROR" "容器启动失败"
        exit 1
      }
  else
    log "INFO" "提示用户自定义端口..."
    HOST_PORT_1=$(prompt_for_port "请输入前端端口 (Web UI)" $DEFAULT_FRONTEND_PORT)
    HOST_PORT_2=$(prompt_for_port "请输入后端端口" $DEFAULT_BACKEND_PORT)

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
      $SUB_STORE_IMAGE_NAME || {
        log "ERROR" "容器启动失败"
        exit 1
      }
  fi

  log "INFO" "Sub-Store 部署成功"
}

# 增强版卸载容器
uninstall_container() {
  local container_name=$1
  local image_name=$2

  if docker ps -a --format "{{.Names}}" | grep -q "^${container_name}$"; then
    log "INFO" "正在卸载容器 $container_name..."
    docker stop $container_name
    docker rm $container_name
    log "INFO" "容器 $container_name 已停止并移除"

    # 询问是否删除镜像
    read -p "是否删除镜像 $image_name? (y/n) [默认: n]: " remove_image
    remove_image=${remove_image:-n}
    if [[ "$remove_image" == "y" || "$remove_image" == "Y" ]]; then
      docker rmi $image_name
      log "INFO" "镜像 $image_name 已删除"
    fi

    # 询问是否清理卷
    read -p "是否清理相关数据卷 $DATA_DIR? (y/n) [默认: n]: " remove_volume
    remove_volume=${remove_volume:-n}
    if [[ "$remove_volume" == "y" || "$remove_volume" == "Y" ]] && [ "$container_name" == "$CONTAINER_NAME" ]; then
      rm -rf "$DATA_DIR"
      log "INFO" "数据卷 $DATA_DIR 已清理"
    fi
  else
    log "WARN" "容器 $container_name 未运行，跳过卸载"
  fi
}

# 数据备份
backup_data() {
  if [ -d "$DATA_DIR" ]; then
    log "INFO" "正在备份数据..."
    TIMESTAMP=$(date +%Y%m%d%H%M%S)
    BACKUP_FILE="$BACKUP_DIR/backup_$TIMESTAMP.tar.gz"
    mkdir -p "$BACKUP_DIR"
    tar -czf "$BACKUP_FILE" -C "$DATA_DIR" .
    log "INFO" "数据已备份到: $BACKUP_FILE"
  else
    log "WARN" "未找到数据目录，跳过备份"
  fi
}

# 数据恢复
restore_data() {
  local latest_backup=$(ls -t $BACKUP_DIR/*.tar.gz 2>/dev/null | head -n 1)
  if [ -z "$latest_backup" ]; then
    log "WARN" "未找到备份文件，跳过恢复"
    return
  fi

  log "INFO" "正在恢复数据..."
  mkdir -p "$DATA_DIR"
  tar -xzf "$latest_backup" -C "$DATA_DIR"
  log "INFO" "数据已从 $latest_backup 恢复"
}

# 交互式菜单
interactive_menu() {
  while true; do
    echo -e "\n选择操作："
    echo "1. 部署 Sub-Store"
    echo "2. 部署 Watchtower"
    echo "3. 卸载容器（Sub-Store 或 Watchtower）"
    echo "4. 数据备份"
    echo "5. 数据恢复"
    echo "6. 退出"
    read -p "请输入选项编号: " choice

    case $choice in
      1)
        install_substore
        ;;
      2)
        install_watchtower
        ;;
      3)
        echo -e "选择卸载的容器："
        echo "1. Sub-Store"
        echo "2. Watchtower"
        read -p "请输入选项编号: " uninstall_choice
        case $uninstall_choice in
          1) uninstall_container $CONTAINER_NAME $SUB_STORE_IMAGE_NAME ;;
          2) uninstall_container $WATCHTOWER_CONTAINER_NAME $WATCHTOWER_IMAGE_NAME ;;
          *) log "WARN" "无效输入，返回主菜单" ;;
        esac
        ;;
      4)
        backup_data
        ;;
      5)
        restore_data
        ;;
      6)
        log "INFO" "退出脚本"
        exit 0
        ;;
      *)
        log "WARN" "无效输入，请重新选择"
        ;;
    esac
  done
}

# 主流程
main() {
  detect_system
  install_dependencies
  interactive_menu
}

# 执行入口
main "$@"
