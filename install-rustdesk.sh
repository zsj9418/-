#!/bin/bash
set -euo pipefail
trap 'echo -e "${RED}脚本被中断${NC}"; exit 1' INT

# 日志文件路径
LOG_FILE="/var/log/rustdesk_deploy.log"
LOG_MAX_SIZE=1048576 # 1MB
if [[ -f "$LOG_FILE" && $(stat -c%s "$LOG_FILE") -ge $LOG_MAX_SIZE ]]; then
  > "$LOG_FILE"
fi
touch "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 容器名称
CONTAINER_NAME_HBBS="rustdesk_hbbs"
CONTAINER_NAME_HBBR="rustdesk_hbbr"
CONTAINER_NAME_API="rustdesk_api"

IMAGE_NAME_HBBS_HBBR="rustdesk/rustdesk-server:latest"
IMAGE_NAME_API="lejianwen/rustdesk-api:latest"

DATA_DIR="./rustdesk_data"
API_DATA_DIR="$DATA_DIR/api"
SERVER_DATA_DIR="$DATA_DIR/server"
DEFAULT_PORT=21115

# 保存端口配置
HBBS_PORTS=("21115" "21116" "21117" "21118" "21119")
HBBR_PORTS=("31115" "31116" "31117" "31118" "31119")

# 确保数据目录存在
mkdir -p "$DATA_DIR" "$API_DATA_DIR" "$SERVER_DATA_DIR"

# ==================== 修复1：初始化全局变量 ====================
IS_OPENWRT=false
PLATFORM=""
OS=""
PACKAGE_MANAGER=""

# ==================== 检查 Docker ====================
check_docker() {
  if ! command -v docker &> /dev/null; then
    echo -e "${RED}错误：未安装 Docker！请先安装 Docker。${NC}"
    exit 1
  fi
  if ! docker info &> /dev/null; then
    echo -e "${RED}错误：Docker 服务未运行！请启动 Docker 服务（例如：sudo systemctl start docker）。${NC}"
    exit 1
  fi
  echo -e "${GREEN}Docker 环境正常。${NC}"
}

# ==================== 检测架构 ====================
detect_architecture() {
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64 | amd64) PLATFORM="linux/amd64" ;;
    armv7l | armhf) PLATFORM="linux/arm/v7" ;;
    aarch64 | arm64) PLATFORM="linux/arm64" ;;
    mips | mipsel) PLATFORM="linux/mips" ;;
    *) echo -e "${RED}不支持的架构 ($ARCH)${NC}" && exit 1 ;;
  esac
  # 修复11：仅非amd64时使用platform
  if [[ "$PLATFORM" == "linux/amd64" ]]; then
    PLATFORM=""
  fi
  echo -e "${GREEN}设备架构：$ARCH，适配平台：$PLATFORM${NC}"
}

# ==================== 检测操作系统（修复1） ====================
detect_os() {
  if [[ -f /etc/openwrt_release ]]; then
    OS="OpenWrt"
    PACKAGE_MANAGER="opkg"
    IS_OPENWRT=true
    export IS_OPENWRT  # 修复：立即导出
  elif [[ -f /etc/debian_version ]]; then
    OS="Debian/Ubuntu"
    PACKAGE_MANAGER="apt"
    IS_OPENWRT=false
    export IS_OPENWRT
  elif [[ -f /etc/redhat-release ]]; then
    OS="CentOS/RHEL"
    PACKAGE_MANAGER="dnf"  # 修复3：yum → dnf
    IS_OPENWRT=false
    export IS_OPENWRT
  else
    echo -e "${RED}不支持的操作系统${NC}" && exit 1
  fi
  echo -e "${GREEN}操作系统：$OS${NC}"
}

# ==================== 依赖安装（修复2、4） ====================
install_dependency() {
  local cmd=$1
  local install_cmd=$2
  if ! command -v "$cmd" &>/dev/null; then
    echo -e "${YELLOW}正在安装 $cmd...${NC}"
    if ! eval "$install_cmd"; then
      echo -e "${RED}$cmd 安装失败，请手动安装。${NC}"
      exit 1
    fi
    echo -e "${GREEN}$cmd 安装成功。${NC}"
  fi
}

check_dependencies() {
  if [[ ! -f "/var/log/rustdesk_dependencies_checked" ]]; then
    # 修复：先检测系统
    detect_os
    if $IS_OPENWRT; then
      # 修复2：OpenWrt Docker 安装
      install_dependency "docker" "opkg update && opkg install dockerd docker"
      install_dependency "netstat" "opkg install net-tools"
      /etc/init.d/dockerd enable
      /etc/init.d/dockerd start || /etc/init.d/dockerd restart
    else
      install_dependency "docker" "sudo $PACKAGE_MANAGER update && sudo $PACKAGE_MANAGER install -y docker.io"
      install_dependency "lsof" "sudo $PACKAGE_MANAGER install -y lsof"
      if ! systemctl is-active --quiet docker; then
        echo -e "${YELLOW}启动 Docker 服务...${NC}"
        sudo systemctl start docker
        sudo systemctl enable docker
      fi
    fi
    touch "/var/log/rustdesk_dependencies_checked"
  else
    check_docker
    # 修复4：统一使用 ss 检查端口（兼容性最佳）
    if ! command -v ss &>/dev/null; then
      if $IS_OPENWRT; then
        install_dependency "ss" "opkg install iproute2"
      else
        install_dependency "ss" "sudo $PACKAGE_MANAGER install -y iproute2"
      fi
    fi
    echo -e "${GREEN}依赖检查完成。${NC}"
  fi
}

# ==================== 权限检查 ====================
check_user_permission() {
  if $IS_OPENWRT; then
    if [[ $(id -u) -ne 0 ]]; then
      echo -e "${RED}OpenWrt 系统建议直接使用 root 用户运行此脚本。${NC}"
      exit 1
    fi
    echo -e "${GREEN}检测到 root 用户权限，继续执行...${NC}"
  else
    if ! id -nG "$(whoami)" | grep -qw "docker"; then
      echo -e "${YELLOW}当前用户未加入 Docker 用户组，尝试解决权限问题...${NC}"
      if ! sudo usermod -aG docker "$(whoami)"; then
        echo -e "${RED}添加用户到 Docker 组失败，请手动执行 'sudo usermod -aG docker $(whoami)'。${NC}"
        exit 1
      fi
      echo -e "${RED}已将当前用户加入 Docker 用户组，请重新登录后再运行脚本，或使用 'sudo' 运行脚本。${NC}"
      exit 1
    fi
  fi
}

# ==================== 端口验证（修复5：新增Host模式特殊处理） ====================
find_available_port() {
  local start_port=${1:-$DEFAULT_PORT}
  while :; do
    # 修复5：优先使用 ss，其次 netstat/lsof
    if command -v ss &>/dev/null && ! ss -tuln | grep -q ":$start_port "; then
      break
    elif $IS_OPENWRT && command -v netstat &>/dev/null && ! netstat -tuln | grep -q ":$start_port "; then
      break
    elif ! lsof -i:$start_port &>/dev/null 2>&1; then
      break
    fi
    ((start_port++))
  done
  echo $start_port
}

# 新增：Host模式专用验证（不检查占用状态）
validate_port_host_mode() {
  local port=$1
  [[ $port =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

validate_ports_host_mode() {
  local ports=("$@")
  for port in "${ports[@]}"; do
    if ! validate_port_host_mode "$port"; then
      echo -e "${RED}错误：端口 $port 格式无效！${NC}"
      return 1
    fi
  done
  return 0
}

# 原版Bridge模式验证
validate_port() {
  local port=$1
  if [[ $port =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
    # 修复5：优先使用 ss
    if command -v ss &>/dev/null && ss -tuln | grep -q ":$port "; then
      return 1
    elif $IS_OPENWRT && command -v netstat &>/dev/null && netstat -tuln | grep -q ":$port "; then
      return 1
    elif lsof -i:$port &>/dev/null 2>&1; then
      return 1
    fi
    return 0
  fi
  return 1
}

validate_ports() {
  local ports=("$@")
  for port in "${ports[@]}"; do
    if ! validate_port "$port"; then
      echo -e "${RED}错误：端口 $port 无效或已被占用！${NC}"
      return 1
    fi
  done
  return 0
}

# ==================== 获取IP ====================
get_server_ip() {
  local ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}' | grep -v '127.0.0.1' | head -n1)
  if [ -z "$ip" ] && command -v ip &> /dev/null; then
    ip=$(ip -4 addr show scope global 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)
  elif [ -z "$ip" ] && command -v ifconfig &> /dev/null; then
    ip=$(ifconfig 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n1)
  fi
  echo "${ip:-192.168.1.66}"
}

# ==================== Key提取（修复10） ====================
extract_key() {
  local container_name=$1
  # 修复10：同时检查两个容器
  for container in "$CONTAINER_NAME_HBBS" "$CONTAINER_NAME_HBBR"; do
    for i in {1..30}; do
      KEY_LINE=$(docker logs "$container" --tail 50 2>/dev/null | grep "Key:" | tail -1)
      if [ -n "$KEY_LINE" ]; then
        echo "$KEY_LINE" | sed -n 's/.*Key: \([^ ]*\).*/\1/p'
        return
      fi
      sleep 1
    done
  done
  echo "未检测到 Key 信息"
}

get_server_id() {
  local container_name=$1
  id=$(docker logs "$container_name" 2>/dev/null | grep "Generated new keypair for id:" | tail -1 | sed 's/.*for id: *//')
  if [ -z "$id" ]; then
    id="未检测到 ID 或容器未启动"
  fi
  echo "$id"
}

get_relay_address() {
  local net_mode=$1
  local server_ip
  if [ "$net_mode" == "host" ]; then
    server_ip="127.0.0.1"
    echo "${server_ip}:${HBBS_PORTS[2]}"
  else
    server_ip=$(get_server_ip)
    echo "${server_ip}:${HBBR_PORTS[2]}"
  fi
}

# ==================== 防火墙自动放行（新增） ====================
open_firewall() {
  local ports=("${HBBS_PORTS[@]}" "${HBBR_PORTS[@]}")
  if command -v ufw &>/dev/null; then
    for port in "${ports[@]}"; do
      sudo ufw allow "$port/tcp" &>/dev/null || true
    done
    sudo ufw allow 21116/udp &>/dev/null || true
    sudo ufw reload &>/dev/null || true
    echo -e "${GREEN}ufw 防火墙已放行${NC}"
  elif command -v firewall-cmd &>/dev/null; then
    for port in "${ports[@]}"; do
      sudo firewall-cmd --add-port="$port/tcp" --permanent &>/dev/null || true
    done
    sudo firewall-cmd --add-port=21116/udp --permanent &>/dev/null || true
    sudo firewall-cmd --reload &>/dev/null || true
    echo -e "${GREEN}firewalld 已放行${NC}"
  fi
}

# ==================== 部署 hbbs 和 hbbr（修复主要问题） ====================
deploy_hbbs_hbbr() {
  check_docker
  echo -e "${YELLOW}开始部署 RustDesk 服务器 (hbbs 和 hbbr)...${NC}"
  docker rm -f "$CONTAINER_NAME_HBBS" "$CONTAINER_NAME_HBBR" >/dev/null 2>&1 || true
  
  echo "请选择网络模式："
  echo "1) Host 模式（容器共享宿主机网络，使用 127.0.0.1 通信，适合简单部署）"
  echo "2) 桥接（Bridge）模式（容器隔离，使用容器名称通信，适合安全隔离）"
  read -p "输入（1 或 2，回车默认 1）： " net_mode
  net_mode=${net_mode:-1}
  
  if [ "$net_mode" == "1" ]; then
    echo -e "${GREEN}你选择了 Host 模式，容器共享宿主机网络命名空间。${NC}"
    port_config="Host 模式"
    HBBS_PORTS=("21115" "21116" "21117" "21118" "21119")
    HBBR_PORTS=("21115" "21116" "21117" "21118" "21119")
    NET_MODE="host"
    # 修复主要问题：Host模式使用新验证函数
    if ! validate_ports_host_mode "${HBBS_PORTS[@]}"; then
      echo -e "${RED}错误：端口 ${HBBS_PORTS[*]} 格式无效！${NC}"
      sleep 2
      main_menu
    fi
    echo -e "${YELLOW}Host模式下请确保端口 ${HBBS_PORTS[*]} 空闲（容器启动后会自动接管）${NC}"
  elif [ "$net_mode" == "2" ]; then
    echo -e "${YELLOW}你选择了桥接模式，容器将加入 rustdesk-net 网络。${NC}"
    echo "注意：hbbs 和 hbbr 需使用不同的宿主机端口！"
    echo "hbbs 端口用途：21115 (TCP), 21116 (TCP/UDP, ID 服务器), 21117 (TCP), 21118 (TCP), 21119 (TCP)"
    echo "hbbr 端口用途：21115 (TCP), 21116 (TCP/UDP), 21117 (TCP, 中继服务器), 21118 (TCP), 21119 (TCP)"
   
    # 配置 hbbs 端口
    echo "默认 hbbs 宿主机端口：${HBBS_PORTS[*]}"
    read -p "请输入 hbbs 宿主机端口（多个用空格隔开，回车使用默认）： " hbbs_host_ports
    hbbs_host_ports=${hbbs_host_ports:-"${HBBS_PORTS[*]}"}
    read -r -a hbbs_ports_array <<< "$hbbs_host_ports"
    if [ ${#hbbs_ports_array[@]} -ne 5 ]; then
      echo -e "${RED}错误：请输入 5 个端口！${NC}"
      sleep 2
      main_menu
    fi
    if ! validate_ports "${hbbs_ports_array[@]}"; then
      echo -e "${RED}错误：hbbs 端口无效或已被占用，请重新选择！${NC}"
      sleep 2
      main_menu
    fi
    port_args_hbbs=""
    container_ports=("21115" "21116" "21117" "21118" "21119")
    index=0
    for host_port in "${hbbs_ports_array[@]}"; do
      port_args_hbbs="$port_args_hbbs -p $host_port:${container_ports[$index]}"
      if [ "${container_ports[$index]}" == "21116" ]; then
        port_args_hbbs="$port_args_hbbs -p $host_port:21116/udp"
      fi
      index=$((index + 1))
    done
    HBBS_PORTS=("${hbbs_ports_array[@]}")
    
    # 配置 hbbr 端口
    echo "默认 hbbr 宿主机端口：${HBBR_PORTS[*]}"
    read -p "请输入 hbbr 宿主机端口（多个用空格隔开，回车使用默认）： " hbbr_host_ports
    hbbr_host_ports=${hbbr_host_ports:-"${HBBR_PORTS[*]}"}
    read -r -a hbbr_ports_array <<< "$hbbr_host_ports"
    if [ ${#hbbr_ports_array[@]} -ne 5 ]; then
      echo -e "${RED}错误：请输入 5 个端口！${NC}"
      sleep 2
      main_menu
    fi
    if ! validate_ports "${hbbr_ports_array[@]}"; then
      echo -e "${RED}错误：hbbr 端口无效或已被占用，请重新选择！${NC}"
      sleep 2
      main_menu
    fi
    port_args_hbbr=""
    index=0
    for host_port in "${hbbr_ports_array[@]}"; do
      port_args_hbbr="$port_args_hbbr -p $host_port:${container_ports[$index]}"
      if [ "${container_ports[$index]}" == "21116" ]; then
        port_args_hbbr="$port_args_hbbr -p $host_port:21116/udp"
      fi
      index=$((index + 1))
    done
    HBBR_PORTS=("${hbbr_ports_array[@]}")
    port_config="hbbs 宿主机端口：$hbbs_host_ports\nhbbr 宿主机端口：$hbbr_host_ports"
    NET_MODE="bridge"
  else
    echo -e "${RED}无效选择，返回主菜单。${NC}"
    sleep 2
    main_menu
  fi

  # 修复12：更多备用镜像
  echo -e "${YELLOW}正在拉取镜像 $IMAGE_NAME_HBBS_HBBR...${NC}"
  local fallback_images=(
    "rustdesk/rustdesk-server:1.1.10-1"
    "rustdesk/rustdesk-server:s6"
    "rustdesk/rustdesk-server:1.1.9-2"
  )
  if ! docker pull "$IMAGE_NAME_HBBS_HBBR" 2>&1 | tee -a "$LOG_FILE"; then
    for fallback in "${fallback_images[@]}"; do
      echo -e "${YELLOW}尝试备用镜像：$fallback${NC}"
      if docker pull "$fallback" 2>&1 | tee -a "$LOG_FILE"; then
        IMAGE_NAME_HBBS_HBBR="$fallback"
        break
      fi
    done
    if [[ "$IMAGE_NAME_HBBS_HBBR" == "rustdesk/rustdesk-server:latest" ]]; then
      echo -e "${RED}所有镜像拉取失败，请检查网络${NC}"
      exit 1
    fi
  fi

  if [ "$NET_MODE" == "bridge" ]; then
    docker network create rustdesk-net >/dev/null 2>&1 || true
  fi

  # 启动 hbbs 容器
  echo -e "${YELLOW}开始部署 hbbs 容器...${NC}"
  local network_arg=""
  if [ "$NET_MODE" == "bridge" ]; then
    network_arg="--network rustdesk-net $port_args_hbbs"
  else
    network_arg="--net=host"
  fi
  if ! docker run -d --name "$CONTAINER_NAME_HBBS" --restart=unless-stopped $network_arg \
    -v "$SERVER_DATA_DIR:/root" ${PLATFORM:+--platform "$PLATFORM"} "$IMAGE_NAME_HBBS_HBBR" hbbs 2>&1 | tee -a "$LOG_FILE"; then
    echo -e "${RED}错误：hbbs 容器启动失败！请检查日志（docker logs $CONTAINER_NAME_HBBS 或 $LOG_FILE）。${NC}"
    sleep 2
    main_menu
  fi

  # 启动 hbbr 容器
  echo -e "${YELLOW}开始部署 hbbr 容器...${NC}"
  if [ "$NET_MODE" == "bridge" ]; then
    network_arg="--network rustdesk-net $port_args_hbbr"
  else
    network_arg="--net=host"
  fi
  if ! docker run -d --name "$CONTAINER_NAME_HBBR" --restart=unless-stopped $network_arg \
    -v "$SERVER_DATA_DIR:/root" ${PLATFORM:+--platform "$PLATFORM"} "$IMAGE_NAME_HBBS_HBBR" hbbr 2>&1 | tee -a "$LOG_FILE"; then
    echo -e "${RED}错误：hbbr 容器启动失败！请检查日志（docker logs $CONTAINER_NAME_HBBR 或 $LOG_FILE）。${NC}"
    docker rm -f "$CONTAINER_NAME_HBBS" >/dev/null 2>&1 || true
    sleep 2
    main_menu
  fi

  # 新增：自动放行防火墙
  open_firewall

  echo -e "${GREEN}容器已启动，等待密钥生成...${NC}"
  sleep 8  # 增加等待时间
  KEY=$(extract_key "$CONTAINER_NAME_HBBS")
  SERVER_IP=$([ "$NET_MODE" == "host" ] && echo "127.0.0.1" || get_server_ip)
  SERVER_PORT=$([ "$NET_MODE" == "host" ] && echo "${HBBS_PORTS[2]}" || echo "${HBBR_PORTS[2]}")
  
  echo -e "\n${GREEN}== 服务器密钥信息 ==${NC}"
  echo "IP: $SERVER_IP"
  echo "中继端口: $SERVER_PORT"
  echo "Key: $KEY"
  echo "客户端配置："
  echo " ID 服务器: $SERVER_IP:${HBBS_PORTS[1]}"
  echo " 中继服务器: $SERVER_IP:$SERVER_PORT"
  echo -e "${YELLOW}请将公钥内容复制到客户端配置中${NC}"
  echo "（可用命令：docker logs $CONTAINER_NAME_HBBS --tail 50 | grep 'Key:'）"
  echo ""
  read -p "按回车返回主菜单..." temp
  main_menu
}

# ==================== 部署API（修复6、7） ====================
deploy_api() {
  check_docker
  echo -e "${YELLOW}开始部署 RustDesk API 容器...${NC}"
  if ! docker ps -a --format '{{.Names}}' | grep -q "^$CONTAINER_NAME_HBBS$"; then
    echo -e "${RED}错误：hbbs 容器未运行！请先部署 hbbs 和 hbbr。${NC}"
    sleep 2
    main_menu
  fi
  
  NET_MODE=$(docker inspect "$CONTAINER_NAME_HBBS" | grep '"NetworkMode":' | grep -q '"host"' && echo "host" || echo "bridge")
  echo -e "${GREEN}检测到 $CONTAINER_NAME_HBBS 使用 $NET_MODE 模式，API 将使用相同模式。${NC}"
  
  if [ "$NET_MODE" == "host" ]; then
    echo -e "${GREEN}使用 Host 模式，容器共享宿主机网络，使用 127.0.0.1 通信。${NC}"
    port_args="--net=host"
    API_PORT=21114
    # Host模式不检查端口占用
    if ! validate_port_host_mode "$API_PORT"; then
      echo -e "${RED}错误：API 端口 $API_PORT 格式无效！${NC}"
      sleep 2
      main_menu
    fi
    ID_PORT=21116
    RELAY_PORT=21117
    SERVER_IP="127.0.0.1"
    ID_SERVER="127.0.0.1"
    RELAY_SERVER="127.0.0.1"
  else
    echo -e "${YELLOW}使用桥接模式，容器加入 rustdesk-net 网络，使用容器名称通信。${NC}"
    read -p "请输入宿主机端口（回车使用默认 21114）： " host_port
    host_port=${host_port:-21114}
    if ! validate_port "$host_port"; then
      echo -e "${RED}错误：宿主机端口 $host_port 无效或已被占用！${NC}"
      sleep 2
      main_menu
    fi
    port_args="-p $host_port:21114 --network rustdesk-net"
    API_PORT=$host_port
    ID_PORT=21116
    RELAY_PORT=21117
    SERVER_IP=$(get_server_ip)
    ID_SERVER="$CONTAINER_NAME_HBBS"
    RELAY_SERVER="$CONTAINER_NAME_HBBR"
  fi
  
  # 密钥配置（修复10）
  echo -e "${YELLOW}检测 hbbs 容器中的密钥...${NC}"
  RUSTDESK_KEY=$(extract_key "$CONTAINER_NAME_HBBS")
  if [ "$RUSTDESK_KEY" == "未检测到 Key 信息" ]; then
    echo -e "${YELLOW}未检测到密钥，建议手动输入或确保密钥文件存在于 $SERVER_DATA_DIR/id_ed25519.pub${NC}"
    read -p "请输入 RustDesk 加密密钥（留空则使用挂载的密钥文件）： " RUSTDESK_KEY
  else
    echo -e "${GREEN}检测到的密钥：$RUSTDESK_KEY${NC}"
    read -p "请输入 RustDesk 加密密钥（回车使用检测到的密钥）： " input_key
    RUSTDESK_KEY=${input_key:-$RUSTDESK_KEY}
  fi
  
  if [ -z "$RUSTDESK_KEY" ]; then
    KEY_ENV=""
    KEY_VOLUME="-v $SERVER_DATA_DIR:/app/data"  # 修复6：正确路径
    echo -e "${YELLOW}将使用挂载的密钥文件：$SERVER_DATA_DIR/id_ed25519.pub${NC}"
  else
    KEY_ENV="-e RUSTDESK_KEY=\"$RUSTDESK_KEY\""  # 修复7：正确环境变量名
    KEY_VOLUME=""
  fi
  
  read -p "请输入时区（默认 Asia/Shanghai，回车使用默认值）： " TZ
  TZ=${TZ:-Asia/Shanghai}
  read -p "请输入界面语言（默认 zh-CN，回车使用默认值）： " LANG
  LANG=${LANG:-zh-CN}
  
  if docker ps -a --format '{{.Names}}' | grep -q "^$CONTAINER_NAME_API$"; then
    echo -e "${YELLOW}检测到已有 $CONTAINER_NAME_API 容器，正在停止并删除...${NC}"
    docker stop "$CONTAINER_NAME_API" &> /dev/null
    docker rm "$CONTAINER_NAME_API" &> /dev/null
  fi
  
  echo -e "${YELLOW}正在拉取镜像 $IMAGE_NAME_API...${NC}"
  docker pull "$IMAGE_NAME_API" 2>&1 | tee -a "$LOG_FILE" || {
    echo -e "${YELLOW}尝试备用镜像 lejainwen/rustdesk-api:full-s6${NC}"
    IMAGE_NAME_API="lejianwen/rustdesk-api:full-s6"
    docker pull "$IMAGE_NAME_API"
  }
  
  echo -e "${YELLOW}正在启动 RustDesk API 容器...${NC}"
  if ! docker run -d --name "$CONTAINER_NAME_API" \
    $port_args \
    -v "$API_DATA_DIR:/app/data" \
    $KEY_VOLUME \
    -e TZ="$TZ" \
    -e RUSTDESK_API_LANG="$LANG" \
    -e RUSTDESK_ID_SERVER="$ID_SERVER:$ID_PORT" \
    -e RUSTDESK_RELAY_SERVER="$RELAY_SERVER:$RELAY_PORT" \
    -e RUSTDESK_API_SERVER="http://$SERVER_IP:$API_PORT" \
    $KEY_ENV \
    --restart=unless-stopped \
    ${PLATFORM:+--platform "$PLATFORM"} \
    "$IMAGE_NAME_API" 2>&1 | tee -a "$LOG_FILE"; then
    echo -e "${RED}错误：API 容器启动失败！请检查日志（docker logs $CONTAINER_NAME_API 或 $LOG_FILE）。${NC}"
    sleep 2
    main_menu
  fi
  
  echo -e "${GREEN}RustDesk API 容器启动成功！${NC}"
  echo -e "${GREEN}访问地址：http://$SERVER_IP:$API_PORT/_admin/${NC}"
  echo -e "${GREEN}默认用户名：admin，密码请查看容器日志（docker logs $CONTAINER_NAME_API | grep password）${NC}"
  read -p "按回车返回主菜单..." temp
  main_menu
}

# ==================== 其他功能保持原样 ====================
reset_api_password() {
  check_docker
  echo -e "${YELLOW}开始重置 RustDesk API 管理员密码...${NC}"
  if ! docker ps -a --format '{{.Names}}' | grep -q "^$CONTAINER_NAME_API$"; then
    echo -e "${RED}错误：未找到 $CONTAINER_NAME_API 容器！请先部署 API 容器。${NC}"
    read -p "按回车返回主菜单..." temp
    main_menu
  fi
  if ! docker ps --format '{{.Names}}' | grep -q "^$CONTAINER_NAME_API$"; then
    echo -e "${YELLOW}容器未运行，正在启动...${NC}"
    docker start "$CONTAINER_NAME_API"
    if [ $? -ne 0 ]; then
      echo -e "${RED}错误：无法启动容器！${NC}"
      read -p "按回车返回主菜单..." temp
      main_menu
    fi
  fi
  read -p "请输入新的管理员密码（至少 8 位，包含字母和数字）： " NEW_PWD
  until [[ "$NEW_PWD" =~ ^[A-Za-z0-9]{8,}$ ]]; do
    echo -e "${RED}错误：密码必须至少 8 位，包含字母和数字！${NC}"
    read -p "请重新输入新密码： " NEW_PWD
  done
  docker exec "$CONTAINER_NAME_API" ./apimain reset-admin-pwd "$NEW_PWD"
  if [ $? -eq 0 ]; then
    echo -e "${GREEN}管理员密码重置成功！新密码：$NEW_PWD${NC}"
  else
    echo -e "${RED}错误：密码重置失败！请检查容器日志（docker logs $CONTAINER_NAME_API）。${NC}"
  fi
  read -p "按回车返回主菜单..." temp
  main_menu
}

check_status() {
  check_docker
  echo -e "${YELLOW}容器状态：${NC}"
  docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "$CONTAINER_NAME_HBBS|$CONTAINER_NAME_HBBR|$CONTAINER_NAME_API" || echo -e "${YELLOW}无相关容器运行。${NC}"
  read -p "按回车返回主菜单..." temp
  main_menu
}

start_containers() {
  check_docker
  docker start "$CONTAINER_NAME_HBBS" "$CONTAINER_NAME_HBBR" "$CONTAINER_NAME_API" >/dev/null 2>&1 || true
  echo -e "${GREEN}所有容器已启动（或部分容器未找到）。${NC}"
  read -p "按回车返回主菜单..." temp
  main_menu
}

stop_containers() {
  check_docker
  docker stop "$CONTAINER_NAME_HBBS" "$CONTAINER_NAME_HBBR" "$CONTAINER_NAME_API" >/dev/null 2>&1 || true
  echo -e "${GREEN}所有容器已停止（或部分容器未找到）。${NC}"
  read -p "按回车返回主菜单..." temp
  main_menu
}

cleanup() {
  check_docker
  echo -e "${YELLOW}停止并删除所有容器...${NC}"
  docker rm -f "$CONTAINER_NAME_HBBS" "$CONTAINER_NAME_HBBR" "$CONTAINER_NAME_API" >/dev/null 2>&1 || true
  echo -e "${YELLOW}删除数据目录...${NC}"
  rm -rf "$DATA_DIR"
  docker network rm rustdesk-net >/dev/null 2>&1 || true
  echo -e "${GREEN}完成卸载清理。${NC}"
  read -p "按回车返回主菜单..." temp
  main_menu
}

view_latest_key() {
  check_docker
  echo -e "${YELLOW}正在提取最新 Key...${NC}"
  KEY=$(extract_key "$CONTAINER_NAME_HBBS")
  if [ "$KEY" == "未检测到 Key 信息" ]; then
    echo -e "${RED}未检测到 Key 信息，请确保 hbbs 容器已启动并生成密钥。${NC}"
  else
    echo -e "${GREEN}最新生成的 Key：${NC}"
    echo "$KEY"
  fi
  read -p "按回车返回主菜单..." temp
  main_menu
}

view_server_info() {
  SERVER_ID=$(get_server_id "$CONTAINER_NAME_HBBS")
  NET_MODE=$(docker inspect "$CONTAINER_NAME_HBBS" 2>/dev/null | grep '"NetworkMode":' | grep -q '"host"' && echo "host" || echo "bridge")
  SERVER_IP=$([ "$NET_MODE" == "host" ] && echo "127.0.0.1" || get_server_ip)
  RELAY_ADDR=$(get_relay_address "$NET_MODE")
  API_ADDR="http://$SERVER_IP:21114/_admin/"
  echo -e "${GREEN}服务器信息：${NC}"
  echo "服务器 ID：$SERVER_ID"
  echo "服务器地址：$SERVER_IP"
  echo "中继服务器地址：$RELAY_ADDR"
  echo "API 管理地址：$API_ADDR"
  echo ""
  read -p "按回车返回主菜单..." temp
  main_menu
}

# ==================== 主菜单（修复8：改为循环） ====================
main_menu() {
  while true; do
    clear
    detect_architecture
    detect_os
    check_dependencies
    check_user_permission
    echo -e "${YELLOW}================ RustDesk 自部署脚本 ================${NC}"
    echo "请选择操作："
    echo "1) 部署 RustDesk 服务器 (hbbs 和 hbbr)"
    echo "2) 部署 RustDesk API 容器"
    echo "3) 重置 API 管理员密码"
    echo "4) 查看容器状态"
    echo "5) 启动所有容器"
    echo "6) 停止所有容器"
    echo "7) 卸载清理"
    echo "8) 查看最新生成的 Key"
    echo "9) 查看服务器 ID、地址和中继地址"
    echo "10) 退出"
    echo -e "${YELLOW}=====================================================${NC}"
    read -p "请输入选择（1-10）： " choice
    case $choice in
      1) deploy_hbbs_hbbr ;;
      2) deploy_api ;;
      3) reset_api_password ;;
      4) check_status ;;
      5) start_containers ;;
      6) stop_containers ;;
      7) cleanup ;;
      8) view_latest_key ;;
      9) view_server_info ;;
      10) echo -e "${GREEN}退出程序${NC}" ; exit 0 ;;
      *) echo -e "${RED}无效选择！${NC}" ; sleep 2 ;;
    esac
  done
}

# 脚本入口
echo -e "${GREEN}欢迎使用 RustDesk 自部署脚本！${NC}"
main_menu
