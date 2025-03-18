#!/bin/bash

# 启用严格模式
set -euo pipefail
trap 'echo "脚本被中断"; exit 1' INT

# 日志文件路径
LOG_FILE="$HOME/.deploy_script.log"
LOG_MAX_SIZE=3145728  # 3M
if [[ -f "$LOG_FILE" && $(stat -c%s "$LOG_FILE") -ge $LOG_MAX_SIZE ]]; then
  > "$LOG_FILE"
fi
touch "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

# 常量
DEFAULT_PORT=3000
ONE_API_IMAGE="justsong/one-api:v0.6.11-preview.1"
LATEST_ONE_API_IMAGE="ghcr.io/songquanpeng/one-api:latest"
DUCK2API_IMAGE="ghcr.io/aurora-develop/duck2api:latest"

# 彩色输出
function green() { echo -e "\e[32m$1\e[0m"; }
function red() { echo -e "\e[31m$1\e[0m"; }
function yellow() { echo -e "\e[33m$1\e[0m"; }

# 检测设备架构
function detect_architecture() {
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64 | amd64) PLATFORM="linux/amd64" ;;
    armv7l | armhf) PLATFORM="linux/arm/v7" ;;
    aarch64 | arm64) PLATFORM="linux/arm64" ;;
    *) red "不支持的架构 ($ARCH)" && exit 1 ;;
  esac
  green "设备架构：$ARCH，适配平台：$PLATFORM"
}

# 检测操作系统
function detect_os() {
  if [[ -f /etc/debian_version ]]; then
    OS="Debian/Ubuntu"
    PACKAGE_MANAGER="apt"
  elif [[ -f /etc/redhat-release ]]; then
    OS="CentOS/RHEL"
    if grep -q "CentOS Linux release 7" /etc/redhat-release; then
      PACKAGE_MANAGER="yum"
    else
      PACKAGE_MANAGER="dnf"
    fi
  elif [[ -f /etc/arch-release ]]; then
    OS="Arch Linux"
    PACKAGE_MANAGER="pacman"
  else
    red "不支持的操作系统" && exit 1
  fi
  green "操作系统：$OS"
}

# 通用依赖安装函数
function install_dependency() {
  local cmd=$1
  local package_name=$2 # 添加 package_name 参数
  local install_cmd=""
  case "$PACKAGE_MANAGER" in
    apt)
      install_cmd="sudo apt update && sudo apt install -y $package_name" # 使用 package_name
      ;;
    yum)
      install_cmd="sudo yum install -y $package_name" # 使用 package_name
      ;;
    dnf)
      install_cmd="sudo dnf install -y $package_name" # 使用 package_name
      ;;
    pacman)
      install_cmd="sudo pacman -S --noconfirm $package_name" # 使用 package_name
      ;;
    *)
      red "不支持的包管理器：$PACKAGE_MANAGER"
      exit 1
      ;;
  esac
  if ! command -v $cmd &>/dev/null; then
    yellow "正在安装 $cmd..."
    eval "$install_cmd"
    if command -v $cmd &>/dev/null; then
      green "$cmd 安装成功。"
    else
      red "$cmd 安装失败，请手动安装。"
      exit 1
    fi
  else
    green "$cmd 已安装，跳过安装。"
  fi
}

# 检查依赖
function check_dependencies() {
  # 检查 Docker
  if ! command -v docker &>/dev/null; then
    install_dependency "docker" "docker.io" # 修正 docker 安装，使用 package_name
  else
    green "Docker 已安装，跳过安装。"
  fi

  # 检查 Docker Compose
  if ! command -v docker-compose &>/dev/null; then
    yellow "正在安装 docker-compose..."
    DOCKER_COMPOSE_URL="https://github.com/docker/compose/releases/download/v2.29.2/docker-compose-$(uname -s)-$(uname -m)"
    if curl -sSL "$DOCKER_COMPOSE_URL" -o /tmp/docker-compose; then
      sudo mv /tmp/docker-compose /usr/local/bin/docker-compose
      sudo chmod +x /usr/local/bin/docker-compose
      if command -v docker-compose &>/dev/null; then
        green "docker-compose 安装成功。"
      else
        red "docker-compose 安装失败，请手动安装。"
        exit 1
      fi
    else
      red "docker-compose 下载失败，请检查网络连接或手动下载安装。"
      exit 1
    fi
  else
    green "Docker Compose 已安装，跳过安装。"
  fi
}

# 检查用户权限
function check_user_permission() {
  if ! groups | grep -q docker; then
    yellow "当前用户未加入 Docker 用户组，尝试解决权限问题..."
    sudo usermod -aG docker $USER
    red "已将当前用户加入 Docker 用户组，请重新登录后再运行脚本，或使用 'sudo' 运行脚本。"
    exit 1
  fi
}

# 自动分配可用端口
function find_available_port() {
  local start_port=${1:-$DEFAULT_PORT}
  while lsof -i:$start_port &>/dev/null; do
    ((start_port++))
  done
  echo $start_port
}

# 验证端口
function validate_port() {
  local suggested_port=$(find_available_port $DEFAULT_PORT)
  green "建议使用的端口：$suggested_port"
  read -p "请输入您希望使用的端口（默认 $suggested_port）： " user_port
  PORT=${user_port:-$suggested_port}
  if [[ "$PORT" =~ ^[0-9]+$ && "$PORT" -ge 1 && "$PORT" -le 65535 ]]; then
    if lsof -i:$PORT &>/dev/null; then
      red "端口 $PORT 已被占用，请选择其他端口。"
      validate_port
    fi
  else
    red "端口号无效，请输入 1 到 65535 范围内的数字。"
    validate_port
  fi
}

# 提供网络模式选择
function choose_network_mode() {
  echo "请选择网络模式："
  echo "1. bridge（推荐）"
  echo "2. host（使用主机网络）"
  echo "3. macvlan（高级模式）"
  read -p "请输入选项（1-3）： " mode
  case $mode in
    1) NETWORK_MODE="bridge"; green "选择的网络模式：bridge"; ;;
    2) NETWORK_MODE="host"; green "选择的网络模式：host"; ;;
    3) NETWORK_MODE="macvlan"; green "选择的网络模式：macvlan"; ;;
    *) red "无效选项，请重新选择。" && choose_network_mode ;;
  esac
}

# 验证网络模式
function validate_network_mode() {
  case "$NETWORK_MODE" in
    bridge|host|macvlan) ;;
    *) red "无效的网络模式，请重新选择。" && choose_network_mode ;;
  esac
}

# 检查是否存在同名容器
function check_existing_container() {
  if docker ps -a --format '{{.Names}}' | grep -q "^$1$"; then
    red "容器 $1 已存在，请先卸载或选择其他名称。"
    exit 1
  fi
}

# 通用部署服务函数
function deploy_service() {
  local name=$1
  local image=$2
  local internal_port=$3
  local data_dir=$4

  validate_port
  choose_network_mode
  validate_network_mode
  check_existing_container "$name"

  green "正在拉取镜像 $image..."
  if ! docker pull $image; then
    red "镜像拉取失败，请检查网络连接或镜像地址。"
    read -p "是否重试？(y/n)： " retry
    if [[ "$retry" =~ ^[Yy]$ ]]; then
      deploy_service "$name" "$image" "$internal_port" "$data_dir"
    else
      exit 1
    fi
  fi

  mkdir -p $data_dir

  green "正在部署 $name..."
  if [[ "$NETWORK_MODE" == "host" ]]; then
    docker run -d --name $name \
      --network host \
      -v $(pwd)/$data_dir:/data \
      --restart always \
      $image || { red "容器启动失败，请检查日志：docker logs $name"; exit 1; }
  else
    docker run -d --name $name \
      --network bridge \
      -p $PORT:$internal_port \
      -v $(pwd)/$data_dir:/data \
      --restart always \
      $image || { red "容器启动失败，请检查日志：docker logs $name"; exit 1; }
  fi

  green "$name 部署成功！访问地址：http://<您的服务器IP>:$PORT"
  echo "数据目录：$data_dir"
  echo "查看容器日志：docker logs $name"
}

# 卸载服务
function uninstall_service() {
  local name=$1
  local data_dir=$2

  green "正在卸载 $name..."
  if docker ps -a --format '{{.Names}}' | grep -q "^$name$"; then
    docker stop $name && docker rm $name
    green "容器已删除。"
  else
    yellow "未发现 $name 容器。"
  fi

  if docker images | grep -q "$name"; then
    docker rmi "$name" || true
    green "镜像已删除。"
  fi

  if [[ -d "$data_dir" ]]; then
    read -p "是否删除持久化数据目录 $data_dir？(y/n)： " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      read -p "是否备份数据目录 $data_dir？(y/n)： " backup
      if [[ "$backup" =~ ^[Yy]$ ]]; then
        backup_dir="$data_dir-backup-$(date +%Y%m%d%H%M%S)"
        mv "$data_dir" "$backup_dir"
        green "数据目录已备份到 $backup_dir。"
      else
        rm -rf "$data_dir"
        green "数据目录已删除。"
      fi
    else
      yellow "数据目录保留，方便下次部署。"
    fi
  fi

  docker network prune -f || true
  docker volume prune -f || true
  green "无用的网络和卷已清理。"
}

# 部署特定版本 One-API
function deploy_one_api() {
  deploy_service "one-api" $ONE_API_IMAGE 3000 "one-api-data"
}

# 部署最新版 One-API
function deploy_latest_one_api() {
  deploy_service "one-api-latest" $LATEST_ONE_API_IMAGE 3000 "one-api-latest-data"
}

# 部署 Duck2API
function deploy_duck2api() {
  deploy_service "duck2api" $DUCK2API_IMAGE 8080 "duck2api-data"
}

# 卸载项目
function uninstall_project() {
  echo "请选择要卸载的项目："
  echo "1. 特定版本 One-API"
  echo "2. 最新版 One-API"
  echo "3. Duck2API"
  read -p "请输入选择（1-3）： " project
  case $project in
    1) uninstall_service "one-api" "one-api-data" ;;
    2) uninstall_service "one-api-latest" "one-api-latest-data" ;;
    3) uninstall_service "duck2api" "duck2api-data" ;;
    *) red "无效选项，请重新运行脚本。" && exit 1 ;;
  esac
}

# 查看所有容器状态
function view_container_status() {
  green "当前所有容器状态："
  docker ps -a
}

# 主菜单
function main_menu() {
  detect_architecture
  detect_os
  check_dependencies
  check_user_permission

  while true; do
    echo "请选择要操作的项目："
    echo "1. One-API特定版本 (v0.6.11-preview.1)"
    echo "2. 部署最新版 One-API"
    echo "3. 部署 Duck2API"
    echo "4. 卸载服务"
    echo "5. 查看容器状态"
    echo "6. 退出脚本"
    read -p "请输入选择（1-6）： " choice
    case $choice in
      1) deploy_one_api ;;
      2) deploy_latest_one_api ;;
      3) deploy_duck2api ;;
      4) uninstall_project ;;
      5) view_container_status ;;
      6) green "感谢您的使用！脚本退出。" && exit 0 ;;
      *) red "无效选项，请重新选择。" ;;
    esac
  done
}

# 启动脚本
main_menu
