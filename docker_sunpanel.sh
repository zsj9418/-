#!/bin/bash
# Docker管理脚本
# 功能：支持 Sun-Panel 的部署、通知、日志记录和数据备份/恢复
# 增强功能：用户可以选择网络模式（bridge 或 host），支持自定义端口，并支持选择版本。

# 配置区（默认值）
DATA_DIR="/opt/sun-panel/data"
BACKUP_DIR="/opt/sun-panel/backup"
LOG_FILE="/var/log/docker_management.log"
LOG_MAX_SIZE=1048576  # 1M
CONTAINER_NAME="sun-panel"
TIMEZONE="Asia/Shanghai"
SUN_PANEL_IMAGE_NAME="hslr/sun-panel"
DEFAULT_SUN_PANEL_PORT=3002

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# 初始化日志
log() {
  local level=$1
  local message=$2
  local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  case $level in
    "INFO") echo -e "${GREEN}[INFO] $timestamp - $message${NC}" >&2 ;; # Redirect to stderr
    "WARN") echo -e "${YELLOW}[WARN] $timestamp - $message${NC}" >&2 ;; # Redirect to stderr
    "ERROR") echo -e "${RED}[ERROR] $timestamp - $message${NC}" >&2 ;; # Redirect to stderr
  esac
  echo "[$level] $timestamp - $message" >> "$LOG_FILE"

  # 限制日志大小为 1M，超过后清空
  if [[ -f "$LOG_FILE" && $(stat -c%s "$LOG_FILE") -ge $LOG_MAX_SIZE ]]; then
    > "$LOG_FILE"
    log "INFO" "日志文件大小超过 1M，已清空日志。"
  fi
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

  # 检查并安装 jq
  if ! command -v jq &> /dev/null; then
    if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
      apt install -y jq || {
        log "ERROR" "jq 安装失败"
        exit 1
      }
    elif [[ "$OS" == "centos" || "$OS" == "rhel" ]]; then
      yum install -y jq || {
        log "ERROR" "jq 安装失败"
        exit 1
      }
    else
      log "ERROR" "不支持的操作系统: $OS"
      exit 1
    fi
    log "INFO" "jq 已成功安装"
  else
    log "INFO" "jq 已存在，跳过安装"
  fi
}

# 获取 Sun-Panel 版本列表
get_sunpanel_versions() {
  log "INFO" "正在获取 Sun-Panel 版本列表..."
  # 调用 Docker Hub API 获取版本信息
  curl -s "https://hub.docker.com/v2/repositories/hslr/sun-panel/tags/?page_size=15" | jq -r '.results[].name' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+(-beta[0-9]+-[0-9]{2}-[0-9]{2})?$' | sort -r
}

# 提示用户选择版本
prompt_for_version() {
  local versions=($(get_sunpanel_versions))
  local num_versions=${#versions[@]}

  if [ $num_versions -eq 0 ]; then
    log "ERROR" "无法获取 Sun-Panel 版本列表"
    exit 1
  fi

  echo "请选择 Sun-Panel 版本："
  for i in "${!versions[@]}"; do
    echo "$((i + 1)). ${versions[$i]}"
  done

  while true; do
    read -p "请输入版本编号: " version_choice
    if [[ $version_choice =~ ^[0-9]+$ ]] && [ $version_choice -ge 1 ] && [ $version_choice -le $num_versions ]; then
      SUN_PANEL_VERSION=${versions[$((version_choice - 1))]}
      break
    else
      log "WARN" "无效的选择，请重新输入"
    fi
  done

  log "INFO" "选择的 Sun-Panel 版本: $SUN_PANEL_VERSION"
}

# 部署 Sun-Panel
install_sunpanel() {
  prompt_for_version

  log "INFO" "正在拉取镜像 $SUN_PANEL_IMAGE_NAME:$SUN_PANEL_VERSION..."
  docker pull "$SUN_PANEL_IMAGE_NAME:$SUN_PANEL_VERSION"

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

  log "INFO" "提示用户自定义端口..."
  HOST_PORT=$(prompt_for_port "请输入前端端口 (Web UI)" $DEFAULT_SUN_PANEL_PORT)

  log "INFO" "正在启动容器，网络模式: $NETWORK_MODE"
  if [[ "$NETWORK_MODE" == "host" ]]; then
    docker run -d \
      --network host \
      --name $CONTAINER_NAME \
      --restart=always \
      -v "${DATA_DIR}/conf:/app/conf" \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -e TZ=${TIMEZONE} \
      "$SUN_PANEL_IMAGE_NAME:$SUN_PANEL_VERSION" || {
        log "ERROR" "容器启动失败"
        exit 1
      }
  else
    docker run -d \
      --name $CONTAINER_NAME \
      --restart=always \
      -p $HOST_PORT:3002 \
      -v "${DATA_DIR}/conf:/app/conf" \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -e TZ=${TIMEZONE} \
      "$SUN_PANEL_IMAGE_NAME:$SUN_PANEL_VERSION" || {
        log "ERROR" "容器启动失败"
        exit 1
      }
  fi

  log "INFO" "Sun-Panel 部署成功"

  # 提示用户如何使用
  echo -e "\n${GREEN}部署完成！以下是使用信息：${NC}"
  echo "默认账号密码："
  echo "账号：admin@sun.cc"
  echo "密码：12345678"
  echo "访问地址："
  if [[ "$NETWORK_MODE" == "host" ]]; then
    echo "http://<你的服务器IP>:3002"
  else
    echo "http://<你的服务器IP>:$HOST_PORT"
  fi
  echo -e "请确保防火墙允许 $HOST_PORT 端口的访问。\n"
}

# 查看所有容器状态
check_all_containers_status() {
  log "INFO" "正在检查所有容器状态..."
  docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

# 增强版卸载容器
uninstall_container() {
  local container_name=$1

  if docker ps -a --format "{{.Names}}" | grep -q "^${container_name}$"; then
    log "INFO" "正在卸载容器 $container_name..."
    docker stop $container_name
    docker rm $container_name
    log "INFO" "容器 $container_name 已停止并移除"

    # 询问是否删除镜像
    read -p "是否删除镜像 $SUN_PANEL_IMAGE_NAME:$SUN_PANEL_VERSION? (y/n) [默认: n]: " remove_image
    remove_image=${remove_image:-n}
    if [[ "$remove_image" == "y" || "$remove_image" == "Y" ]]; then
      docker rmi "$SUN_PANEL_IMAGE_NAME:$SUN_PANEL_VERSION"
      log "INFO" "镜像 $SUN_PANEL_IMAGE_NAME:$SUN_PANEL_VERSION 已删除"
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
    echo "1. 部署 Sun-Panel"
    echo "2. 查看所有容器状态"
    echo "3. 卸载容器（Sun-Panel）"
    echo "4. 数据备份"
    echo "5. 数据恢复"
    echo "6. 退出"
    read -p "请输入选项编号: " choice

    case $choice in
      1) install_sunpanel ;;
      2) check_all_containers_status ;;
      3) uninstall_container $CONTAINER_NAME ;;
      4) backup_data ;;
      5) restore_data ;;
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
