#!/bin/bash

# 启用严格模式
set -euo pipefail
trap 'echo "脚本被中断"; exit 1' INT

# 日志文件路径
LOG_FILE="/var/log/deploy_script.log"
LOG_MAX_SIZE=1048576  # 1M
if [[ -f "$LOG_FILE" && $(stat -c%s "$LOG_FILE") -ge $LOG_MAX_SIZE ]]; then
  > "$LOG_FILE"
fi
touch "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

# 常量
DEFAULT_PORT=100
LOBE_CHAT_IMAGE="lobehub/lobe-chat:latest"
WEBSSH_IMAGE="jrohy/webssh"
LOOKING_GLASS_IMAGE="wikihostinc/looking-glass-server"
SPEEDTEST_IMAGE="ghcr.io/librespeed/speedtest"

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
    mips | mipsel) PLATFORM="linux/mips" ;;
    *) red "不支持的架构 ($ARCH)" && exit 1 ;;
  esac
  green "设备架构：$ARCH，适配平台：$PLATFORM"
}

# 检测操作系统
function detect_os() {
  if [[ -f /etc/openwrt_release ]]; then
    OS="OpenWrt"
    PACKAGE_MANAGER="opkg"
    IS_OPENWRT=true
  elif [[ -f /etc/debian_version ]]; then
    OS="Debian/Ubuntu"
    PACKAGE_MANAGER="apt"
    IS_OPENWRT=false
  elif [[ -f /etc/redhat-release ]]; then
    OS="CentOS/RHEL"
    PACKAGE_MANAGER="yum"
    IS_OPENWRT=false
  else
    red "不支持的操作系统" && exit 1
  fi
  green "操作系统：$OS"
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

# 检查依赖（仅首次运行时检查）
function check_dependencies() {
  if [[ ! -f "/var/log/deploy_dependencies_checked" ]]; then
    if $IS_OPENWRT; then
      # OpenWrt 特殊处理
      install_dependency "docker" "opkg install docker"
      install_dependency "lsof" "opkg install lsof"
      # OpenWrt 需要额外配置 Docker
      /etc/init.d/dockerd enable
      /etc/init.d/dockerd start
    else
      install_dependency "docker" "sudo $PACKAGE_MANAGER install -y docker.io"
      install_dependency "lsof" "sudo $PACKAGE_MANAGER install -y lsof"
    fi
    touch "/var/log/deploy_dependencies_checked"
  else
    green "依赖已安装，跳过检查。"
  fi
}

# 检查用户权限 - OpenWrt 兼容版本
function check_user_permission() {
  if $IS_OPENWRT; then
    # OpenWrt 通常直接使用 root 用户，无需检查用户组
    if [[ $(id -u) -ne 0 ]]; then
      red "OpenWrt 系统建议直接使用 root 用户运行此脚本。"
      exit 1
    fi
    green "检测到 root 用户权限，继续执行..."
  else
    # 非 OpenWrt 系统使用原有检查逻辑
    if ! id -nG "$(whoami)" | grep -qw "docker"; then
      yellow "当前用户未加入 Docker 用户组，尝试解决权限问题..."
      sudo usermod -aG docker "$(whoami)"
      red "已将当前用户加入 Docker 用户组，请重新登录后再运行脚本，或使用 'sudo' 运行脚本。"
      exit 1
    fi
  fi
}

# 自动分配可用端口 - OpenWrt 兼容版本
function find_available_port() {
  local start_port=${1:-$DEFAULT_PORT}
  
  # 兼容性端口检查
  while :; do
    if $IS_OPENWRT; then
      # OpenWrt 使用 netstat 检查端口
      if ! netstat -tuln | grep -q ":$start_port "; then
        break
      fi
    else
      # 其他系统使用 lsof 检查端口
      if ! lsof -i:$start_port &>/dev/null; then
        break
      fi
    fi
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
  if ! [[ "$PORT" =~ ^[0-9]+$ && "$PORT" -ge 1 && "$PORT" -le 65535 ]]; then
    red "端口号无效，请输入 1 到 65535 范围内的数字。"
    exit 1
  fi
}

# 提供网络模式选择
function choose_network_mode() {
  echo "请选择网络模式："
  echo "1. bridge（推荐）"
  echo "2. host（使用主机网络）"
  read -p "请输入选项（1 或 2）： " mode
  case $mode in
    1) NETWORK_MODE="bridge"; green "选择的网络模式：bridge"; ;;
    2) NETWORK_MODE="host"; green "选择的网络模式：host"; ;;
    *) red "无效选项，请重新选择。" && choose_network_mode ;;
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

  validate_port
  choose_network_mode
  check_existing_container "$name"

  green "正在拉取镜像 $image..."
  docker pull $image || { red "镜像拉取失败，请检查网络连接或镜像地址。"; exit 1; }

  green "正在部署 $name..."
  if [[ "$NETWORK_MODE" == "host" ]]; then
    docker run -d --name $name \
      --network host \
      --restart always \
      $image || { red "容器启动失败，请检查日志：docker logs $name"; exit 1; }
  else
    docker run -d --name $name \
      --network bridge \
      -p $PORT:$internal_port \
      --restart always \
      $image || { red "容器启动失败，请检查日志：docker logs $name"; exit 1; }
  fi

  green "$name 部署成功！访问地址：http://<您的服务器IP>:$PORT"
}

# 卸载服务
function uninstall_service() {
  local name=$1

  green "正在卸载 $name..."
  if docker ps -a --format '{{.Names}}' | grep -q "^$name$"; then
    docker stop $name && docker rm $name
    green "容器已删除。"
  else
    yellow "未发现 $name 容器。"
  fi

  docker network prune -f || true
  docker volume prune -f || true
  green "无用的网络和卷已清理。"
}

# 查看所有容器状态
function check_all_containers_status() {
  green "正在检查所有容器状态..."
  docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

# 部署 Lobe Chat
function deploy_lobe_chat() {
  deploy_service "lobe-chat" $LOBE_CHAT_IMAGE 3210
}

# 部署 WebSSH
function deploy_webssh() {
  deploy_service "webssh" $WEBSSH_IMAGE 5032
}

# 部署 Looking Glass Server
function deploy_looking_glass() {
  deploy_service "looking-glass" $LOOKING_GLASS_IMAGE 80
}

# 部署 Speedtest
function deploy_speedtest() {
  deploy_service "speedtest" $SPEEDTEST_IMAGE 8080
}

# 主菜单
function main_menu() {
  detect_architecture
  detect_os
  check_dependencies
  check_user_permission

  while true; do
    echo "请选择要操作的项目："
    echo "1. 部署 Lobe Chat"
    echo "2. 部署 WebSSH"
    echo "3. 部署 Looking Glass Server"
    echo "4. 部署 Speedtest"
    echo "5. 卸载 Lobe Chat"
    echo "6. 卸载 WebSSH"
    echo "7. 卸载 Looking Glass Server"
    echo "8. 卸载 Speedtest"
    echo "9. 查看所有容器状态"
    echo "10. 退出脚本"
    read -p "请输入选择（1-10）： " choice
    case $choice in
      1) deploy_lobe_chat ;;
      2) deploy_webssh ;;
      3) deploy_looking_glass ;;
      4) deploy_speedtest ;;
      5) uninstall_service "lobe-chat" ;;
      6) uninstall_service "webssh" ;;
      7) uninstall_service "looking-glass" ;;
      8) uninstall_service "speedtest" ;;
      9) check_all_containers_status ;;
      10) green "感谢您的使用！脚本退出。" && exit 0 ;;
      *) red "无效选项，请重新选择。" ;;
    esac
  done
}

# 启动脚本
main_menu
