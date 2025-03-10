#!/bin/bash

# 启用严格模式
set -euo pipefail
trap 'echo "脚本被中断"; exit 1' INT

# 日志文件路径
LOG_FILE="/var/log/deploy_script.log"
if ! touch "$LOG_FILE" &>/dev/null; then
  LOG_FILE="$HOME/deploy_script.log"
  touch "$LOG_FILE"
fi
exec > >(tee -a "$LOG_FILE") 2>&1

# 常量
ONE_API_IMAGE="justsong/one-api:v0.6.11-preview.1"
LATEST_ONE_API_IMAGE="ghcr.io/songquanpeng/one-api:latest"
DUCK2API_IMAGE="ghcr.io/aurora-develop/duck2api:latest"
DEFAULT_PORT=3000

# 彩色输出
function green() { echo -e "\e[32m$1\e[0m"; }
function red() { echo -e "\e[31m$1\e[0m"; }
function yellow() { echo -e "\e[33m$1\e[0m"; }

# 检测设备架构
function detect_architecture() {
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64 | amd64)
      PLATFORM="linux/amd64"
      ;;
    armv7l | armhf)
      PLATFORM="linux/arm/v7"
      ;;
    aarch64 | arm64)
      PLATFORM="linux/arm64"
      ;;
    *)
      red "当前设备架构 ($ARCH) 未被支持，可能无法正常运行，请确认所使用的镜像支持该架构。"
      PLATFORM="unknown"
      ;;
  esac
  green "检测到设备架构：$ARCH，适配平台：$PLATFORM"
}

# 检测操作系统
function detect_os() {
  if [[ -f /etc/debian_version ]]; then
    OS="Debian/Ubuntu"
    PACKAGE_MANAGER="apt"
  elif [[ -f /etc/redhat-release ]]; then
    OS="CentOS/RHEL"
    PACKAGE_MANAGER="yum"
  elif [[ "$(uname -s)" == "Darwin" ]]; then
    OS="macOS"
    PACKAGE_MANAGER="brew"
  else
    OS="Unknown"
    PACKAGE_MANAGER=""
    red "当前操作系统未被支持，请手动安装所需依赖。"
    exit 1
  fi
  green "检测到操作系统：$OS"
}

# 通用依赖安装函数
function install_dependency() {
  local cmd=$1
  local install_cmd=$2
  if ! command -v $cmd &>/dev/null; then
    yellow "正在安装 $cmd..."
    eval "$install_cmd"
    if command -v $cmd &>/dev/null; then
      green "$cmd 安装成功。"
    else
      red "$cmd 安装失败，请手动安装。"
      exit 1
    fi
  fi
}

# 检查依赖
function check_dependencies() {
  install_dependency "docker" "sudo $PACKAGE_MANAGER update && sudo $PACKAGE_MANAGER install -y docker.io"
  install_dependency "docker-compose" "sudo curl -L https://github.com/docker/compose/releases/download/v2.23.0/docker-compose-$(uname -s)-$(uname -m) -o /usr/local/bin/docker-compose && sudo chmod +x /usr/local/bin/docker-compose"
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
  local start_port=${1:-3000}
  while lsof -i:$start_port &>/dev/null; do
    ((start_port++))
  done
  echo $start_port
}

function validate_port() {
  port=$(find_available_port $DEFAULT_PORT)
  green "建议使用的端口：$port"
  read -p "请输入您希望使用的端口（默认 $port）：" user_port
  port=${user_port:-$port}
}

# 检查是否存在同名容器
function check_existing_container() {
  if docker ps -a --format '{{.Names}}' | grep -q "^$1$"; then
    red "容器 $1 已存在，请先卸载或选择其他名称。"
    exit 1
  fi
}

# 获取 Docker Compose 命令
function get_docker_compose_command() {
  if command -v docker-compose &>/dev/null; then
    echo "docker-compose"
  elif docker compose version &>/dev/null; then
    echo "docker compose"
  else
    red "未找到 docker-compose 或 docker compose，请先安装其中之一。"
    exit 1
  fi
}

# 通用部署服务函数
function deploy_service() {
  local name=$1
  local image=$2
  local default_port=$3
  local data_dir=$4

  validate_port
  check_existing_container "$name"

  read -p "请选择部署方式（1：Docker，2：Docker Compose）： " method
  case $method in
    1)
      green "正在使用 Docker 部署 $name..."
      docker pull $image
      docker run -d --name $name \
        -p $port:$default_port \
        -v $(pwd)/$data_dir:/data \
        --restart always \
        $image
      green "$name 部署成功！访问地址：http://<您的服务器IP>:$port"
      ;;
    2)
      green "正在使用 Docker Compose 部署 $name..."
      compose_cmd=$(get_docker_compose_command)
      cat >docker-compose.yml <<EOF
services:
  $name:
    image: $image
    platform: $PLATFORM
    ports:
      - $port:$default_port
    volumes:
      - ./$data_dir:/data
    restart: always
EOF
      mkdir -p $data_dir
      $compose_cmd up -d
      green "$name 部署成功！访问地址：http://<您的服务器IP>:$port"
      ;;
    *)
      red "无效的选项，请重新运行脚本。"
      exit 1
      ;;
  esac
}

# 部署 One-API
function deploy_one_api() {
  deploy_service "one-api" $ONE_API_IMAGE $DEFAULT_PORT "one-api-data"
}

# 部署最新版 One-API
function deploy_latest_one_api() {
  deploy_service "one-api-latest" $LATEST_ONE_API_IMAGE $DEFAULT_PORT "one-api-latest-data"
}

# 部署 Duck2API
function deploy_duck2api() {
  deploy_service "duck2api" $DUCK2API_IMAGE $DEFAULT_PORT "duck2api-data"
}

# 卸载服务
function uninstall_project() {
  read -p "请选择要卸载的项目（1：one-api，2：duck2api）： " project
  case $project in
    1)
      green "正在卸载 one-api..."
      docker stop one-api && docker rm one-api
      rm -rf one-api-data docker-compose.yml
      green "one-api 卸载成功。"
      ;;
    2)
      green "正在卸载 duck2api..."
      docker stop duck2api && docker rm duck2api
      rm -rf duck2api-data docker-compose.yml
      green "duck2api 卸载成功。"
      ;;
    *)
      red "无效的选项，请重新运行脚本。"
      exit 1
      ;;
  esac
}

# 主菜单
function main_menu() {
  yellow "欢迎使用一键部署脚本！"
  detect_architecture
  detect_os
  check_dependencies
  check_user_permission

  while true; do
    echo "请选择要操作的项目："
    echo "1：部署 One-API"
    echo "2：部署最新版 One-API"
    echo "3：部署 Duck2API"
    echo "4：卸载服务"
    echo "5：退出"
    read -p "请输入选择（1-5）： " project
    case $project in
      1) deploy_one_api ;;
      2) deploy_latest_one_api ;;
      3) deploy_duck2api ;;
      4) uninstall_project ;;
      5)
        green "感谢您的使用！脚本退出。"
        exit 0
        ;;
      *)
        red "无效的选项，请重新选择。"
        ;;
    esac
  done
}

# 启动脚本
main_menu
