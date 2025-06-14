#!/bin/bash

# 启用严格模式
set -euo pipefail
trap 'echo -e "${RED}脚本被中断${NC}"; exit 1' INT

# 日志文件路径
LOG_FILE="/var/log/rustdesk_deploy.log"
LOG_MAX_SIZE=1048576  # 1MB
if [[ -f "$LOG_FILE" && $(stat -c%s "$LOG_FILE") -ge $LOG_MAX_SIZE ]]; then
  > "$LOG_FILE"
fi
touch "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # 无颜色

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

# 检查 Docker 是否安装并运行
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

# 检测设备架构
detect_architecture() {
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64 | amd64) PLATFORM="linux/amd64" ;;
    armv7l | armhf) PLATFORM="linux/arm/v7" ;;
    aarch64 | arm64) PLATFORM="linux/arm64" ;;
    mips | mipsel) PLATFORM="linux/mips" ;;
    *) echo -e "${RED}不支持的架构 ($ARCH)${NC}" && exit 1 ;;
  esac
  echo -e "${GREEN}设备架构：$ARCH，适配平台：$PLATFORM${NC}"
}

# 检测操作系统
detect_os() {
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
    echo -e "${RED}不支持的操作系统${NC}" && exit 1
  fi
  echo -e "${GREEN}操作系统：$OS${NC}"
}

# 通用依赖安装函数
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

# 检查依赖
check_dependencies() {
  if [[ ! -f "/var/log/rustdesk_dependencies_checked" ]]; then
    if $IS_OPENWRT; then
      install_dependency "docker" "opkg update && opkg install docker"
      install_dependency "netstat" "opkg install net-tools"
      /etc/init.d/dockerd enable
      /etc/init.d/dockerd start
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
    if $IS_OPENWRT; then
      install_dependency "netstat" "opkg install net-tools"
    else
      install_dependency "lsof" "sudo $PACKAGE_MANAGER install -y lsof"
    fi
    echo -e "${GREEN}依赖检查完成。${NC}"
  fi
}

# 检查用户权限
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

# 自动分配可用端口
find_available_port() {
  local start_port=${1:-$DEFAULT_PORT}
  while :; do
    if $IS_OPENWRT; then
      if ! netstat -tuln | grep -q ":$start_port "; then
        break
      fi
    else
      if ! lsof -i:$start_port &>/dev/null; then
        break
      fi
    fi
    ((start_port++))
  done
  echo $start_port
}

# 验证端口
validate_port() {
  local port=$1
  if [[ $port =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
    if $IS_OPENWRT; then
      netstat -tuln | grep -q ":$port " && return 1
    else
      lsof -i:$port &>/dev/null && return 1
    fi
    return 0
  fi
  return 1
}

# 验证一组端口
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

# 获取服务器 IP
get_server_ip() {
  local ip
  ip=$(hostname -I | awk '{print $1}' | grep -v '127.0.0.1')
  if [ -z "$ip" ] && command -v ip &> /dev/null; then
    ip=$(ip addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n 1)
  elif [ -z "$ip" ] && command -v ifconfig &> /dev/null; then
    ip=$(ifconfig | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n 1)
  fi
  echo "${ip:-192.168.1.66}"
}

# 验证 IP 地址格式
validate_ip() {
  local ip=$1
  if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    IFS='.' read -r -a octets <<< "$ip"
    for octet in "${octets[@]}"; do
      if [ "$octet" -gt 255 ]; then
        return 1
      fi
    done
    return 0
  fi
  return 1
}

# 提取最新 Key
extract_key() {
  local container_name=$1
  for i in {1..30}; do
    KEY_LINE=$(docker logs "$container_name" --tail 50 2>/dev/null | grep "Key:" | tail -1)
    if [ -n "$KEY_LINE" ]; then
      echo "$KEY_LINE" | sed -n 's/.*Key: \([^ ]*\).*/\1/p'
      return
    fi
    sleep 1
  done
  echo "未检测到 Key 信息"
}

# 获取服务器 ID
get_server_id() {
  local container_name=$1
  id=$(docker logs "$container_name" 2>/dev/null | grep "Generated new keypair for id:" | tail -1 | sed 's/.*for id: *//')
  if [ -z "$id" ]; then
    id="未检测到 ID 或容器未启动"
  fi
  echo "$id"
}

# 获取中继服务器地址
get_relay_address() {
  local net_mode=$1
  local server_ip
  if [ "$net_mode" == "host" ]; then
    server_ip="127.0.0.1"
    echo "${server_ip}:${HBBS_PORTS[2]}"  # 21117
  else
    server_ip=$(get_server_ip)
    echo "${server_ip}:${HBBR_PORTS[2]}"  # 31117
  fi
}

# 部署 hbbs 和 hbbr
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
    port_args_hbbs="--net=host"
    port_args_hbbr="--net=host"
    port_config="Host 模式"
    HBBS_PORTS=("21115" "21116" "21117" "21118" "21119")
    HBBR_PORTS=("21115" "21116" "21117" "21118" "21119")
    NET_MODE="host"

    # 验证端口
    if ! validate_ports "${HBBS_PORTS[@]}"; then
      echo -e "${RED}错误：端口 ${HBBS_PORTS[*]} 中有端口被占用！请释放端口或选择其他端口。${NC}"
      sleep 2
      main_menu
    fi
  elif [ "$net_mode" == "2" ]; then
    echo -e "${YELLOW}你选择了桥接模式，容器将加入 rustdesk-net 网络。${NC}"
    echo "注意：hbbs 和 hbbr 需使用不同的宿主机端口！"
    echo "hbbs 端口用途：21115 (TCP), 21116 (TCP/UDP, ID 服务器), 21117 (TCP), 21118 (TCP), 21119 (TCP)"
    echo "hbbr 端口用途：21115 (TCP), 21116 (TCP/UDP), 21117 (TCP, 中继服务器), 21118 (TCP), 21119 (TCP)"
    
    # 配置 hbbs 端口
    echo "默认 hbbs 宿主机端口：${HBBS_PORTS[*]}"
    echo "容器端口固定为：21115(TCP) 21116(TCP/UDP) 21117(TCP) 21118(TCP) 21119(TCP)"
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
    echo "容器端口固定为：21115(TCP) 21116(TCP/UDP) 21117(TCP) 21118(TCP) 21119(TCP)"
    read -p "请输入 Hbbr 宿主机端口（多个用空格隔开，回车使用默认）： " hbbr_host_ports
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

  echo -e "${YELLOW}正在拉取镜像 $IMAGE_NAME_HBBS_HBBR...${NC}"
  docker pull "$IMAGE_NAME_HBBS_HBBR" >/dev/null || { echo -e "${RED}镜像拉取失败，请检查网络连接或镜像地址。${NC}"; exit 1; }

  # 创建自定义网络（桥接模式需要）
  if [ "$NET_MODE" == "bridge" ]; then
    docker network create rustdesk-net >/dev/null 2>&1 || true
  fi

  # 启动 hbbs 容器
  echo -e "${YELLOW}开始部署 hbbs 容器...${NC}"
  local network_arg=""
  if [ "$NET_MODE" == "bridge" ]; then
    network_arg="--network rustdesk-net"
  else
    network_arg="--net=host"
  fi
  if ! docker run -d --name "$CONTAINER_NAME_HBBS" --restart=unless-stopped $port_args_hbbs $network_arg \
    -v "$DATA_DIR:/root" --platform "$PLATFORM" "$IMAGE_NAME_HBBS_HBBR" hbbs; then
    echo -e "${RED}错误：hbbs 容器启动失败！请检查日志（docker logs $CONTAINER_NAME_HBBS）。${NC}"
    docker rm -f "$CONTAINER_NAME_HBBS" >/dev/null 2>&1 || true
    sleep 2
    main_menu
  fi

  # 启动 hbbr 容器
  echo -e "${YELLOW}开始部署 hbbr 容器...${NC}"
  if ! docker run -d --name "$CONTAINER_NAME_HBBR" --restart=unless-stopped $port_args_hbbr $network_arg \
    -v "$DATA_DIR:/root" --platform "$PLATFORM" "$IMAGE_NAME_HBBS_HBBR" hbbr; then
    echo -e "${RED}错误：hbbr 容器启动失败！请检查日志（docker logs $CONTAINER_NAME_HBBR）。${NC}"
    docker rm -f "$CONTAINER_NAME_HBBS" "$CONTAINER_NAME_HBBR" >/dev/null 2>&1 || true
    sleep 2
    main_menu
  fi

  echo -e "${GREEN}容器已启动，等待密钥生成...${NC}"
  sleep 5

  # 提取 Key
  KEY=$(extract_key "$CONTAINER_NAME_HBBS")
  SERVER_IP=$([ "$NET_MODE" == "host" ] && echo "127.0.0.1" || get_server_ip)
  SERVER_PORT=$([ "$NET_MODE" == "host" ] && echo "${HBBS_PORTS[2]}" || echo "${HBBR_PORTS[2]}")

  echo -e "\n${GREEN}== 服务器密钥信息 ==${NC}"
  echo "IP: $SERVER_IP"
  echo "中继端口: $SERVER_PORT"
  echo "Key: $KEY"
  echo "客户端配置："
  echo "  ID 服务器: $SERVER_IP:${HBBS_PORTS[1]}"
  echo "  中继服务器: $SERVER_IP:$SERVER_PORT"
  echo "请将公钥内容复制到客户端配置中："
  echo "（可用命令：docker logs $CONTAINER_NAME_HBBS --tail 50 | grep 'Key:'）"
  echo ""
  read -p "按回车返回主菜单..." temp
  main_menu
}

# 部署 rustdesk-api
deploy_api() {
  check_docker
  echo -e "${YELLOW}开始部署 RustDesk API 容器...${NC}"

  # 检查 hbbs 是否运行
  if ! docker ps -a --format '{{.Names}}' | grep -q "^$CONTAINER_NAME_HBBS$"; then
    echo -e "${RED}错误：hbbs 容器未运行！请先部署 hbbs 和 hbbr。${NC}"
    sleep 2
    main_menu
  fi

  # 检查网络模式（从 hbbs 容器获取）
  NET_MODE=$(docker inspect "$CONTAINER_NAME_HBBS" | grep '"NetworkMode":' | grep -q '"host"' && echo "host" || echo "bridge")
  echo -e "${GREEN}检测到 $CONTAINER_NAME_HBBS 使用 $NET_MODE 模式，API 将使用相同模式。${NC}"

  if [ "$NET_MODE" == "host" ]; then
    echo -e "${GREEN}使用 Host 模式，容器共享宿主机网络，使用 127.0.0.1 通信。${NC}"
    port_args="--net=host"
    API_PORT=21114
    ID_PORT=21116
    RELAY_PORT=21117
    SERVER_IP="127.0.0.1"
    ID_SERVER="127.0.0.1"
    RELAY_SERVER="127.0.0.1"
    port_config="Host 模式"

    # 验证 API 端口
    if ! validate_port "$API_PORT"; then
      echo -e "${RED}错误：API 端口 $API_PORT 被占用！请释放端口或选择其他端口。${NC}"
      sleep 2
      main_menu
    fi
  else
    echo -e "${YELLOW}使用桥接模式，容器加入 rustdesk-net 网络，使用容器名称通信。${NC}"
    echo "默认宿主机端口：21114"
    echo "容器端口固定为：21114（无需输入）"
    read -p "请输入宿主机端口（回车使用默认 21114）： " host_port
    host_port=${host_port:-21114}
    if ! validate_port "$host_port"; then
      echo -e "${RED}错误：宿主机端口 $host_port 无效或已被占用！${NC}"
      sleep 2
      main_menu
    fi
    port_args="-p $host_port:21114"
    API_PORT=$host_port
    ID_PORT=21116
    RELAY_PORT=21117
    SERVER_IP=$(get_server_ip)
    ID_SERVER="$CONTAINER_NAME_HBBS"
    RELAY_SERVER="$CONTAINER_NAME_HBBR"
    port_config="宿主机端口：$host_port"
  fi

  # 密钥配置
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
    KEY_VOLUME="-v $SERVER_DATA_DIR:/app/conf/data"
    echo -e "${YELLOW}将使用挂载的密钥文件：$SERVER_DATA_DIR/id_ed25519.pub${NC}"
  else
    KEY_ENV="-e RUSTDESK_API_RUSTDESK_KEY=$RUSTDESK_KEY"
    KEY_VOLUME=""
  fi

  # 时区和语言
  read -p "请输入时区（默认 Asia/Shanghai，回车使用默认值）： " TZ
  TZ=${TZ:-Asia/Shanghai}
  read -p "请输入界面语言（默认 zh-CN，回车使用默认值）： " LANG
  LANG=${LANG:-zh-CN}

  # 检查容器是否已存在
  if docker ps -a --format '{{.Names}}' | grep -q "^$CONTAINER_NAME_API$"; then
    echo -e "${YELLOW}检测到已有 $CONTAINER_NAME_API 容器，正在停止并删除...${NC}"
    docker stop "$CONTAINER_NAME_API" &> /dev/null
    docker rm "$CONTAINER_NAME_API" &> /dev/null
  fi

  echo -e "${YELLOW}正在拉取镜像 $IMAGE_NAME_API...${NC}"
  docker pull "$IMAGE_NAME_API" >/dev/null || { echo -e "${RED}镜像拉取失败，请检查网络连接或镜像地址。${NC}"; exit 1; }

  # 启动 API 容器
  echo -e "${YELLOW}正在启动 RustDesk API 容器...${NC}"
  local network_arg=""
  if [ "$NET_MODE" == "bridge" ]; then
    network_arg="--network rustdesk-net"
  else
    network_arg="--net=host"
  fi
  docker run -d --name "$CONTAINER_NAME_API" \
    $port_args \
    $network_arg \
    -v "$API_DATA_DIR:/app/data" \
    $KEY_VOLUME \
    -e TZ="$TZ" \
    -e RUSTDESK_API_LANG="$LANG" \
    -e RUSTDESK_API_RUSTDESK_ID_SERVER="$ID_SERVER:$ID_PORT" \
    -e RUSTDESK_API_RUSTDESK_RELAY_SERVER="$RELAY_SERVER:$RELAY_PORT" \
    -e RUSTDESK_API_RUSTDESK_API_SERVER="http://$SERVER_IP:$API_PORT" \
    $KEY_ENV \
    --restart=unless-stopped \
    --platform "$PLATFORM" \
    "$IMAGE_NAME_API"

  if [ $? -eq 0 ]; then
    echo -e "${GREEN}RustDesk API 容器启动成功！${NC}"
    echo -e "${GREEN}访问地址：http://$SERVER_IP:$API_PORT/_admin/${NC}"
    echo -e "${GREEN}默认用户名：admin，密码请查看容器日志（docker logs $CONTAINER_NAME_API）${NC}"
    if [ "$NET_MODE" == "bridge" ]; then
      echo -e "${YELLOW}注意：桥接模式下，check_cmd 可能需要修改 hbbs 代码或使用代理以支持非回环地址请求。${NC}"
    fi
  else
    echo -e "${RED}错误：API 容器启动失败！请检查日志（docker logs $CONTAINER_NAME_API）。${NC}"
  fi
  read -p "按回车返回主菜单..." temp
  main_menu
}

# 重置 API 管理员密码
reset_api_password() {
  check_docker
  echo -e "${YELLOW}开始重置 RustDesk API 管理员密码...${NC}"

  # 检查容器是否存在
  if ! docker ps -a --format '{{.Names}}' | grep -q "^$CONTAINER_NAME_API$"; then
    echo -e "${RED}错误：未找到 $CONTAINER_NAME_API 容器！请先部署 API 容器。${NC}"
    read -p "按回车返回主菜单..." temp
    main_menu
  fi

  # 检查容器是否运行
  if ! docker ps --format '{{.Names}}' | grep -q "^$CONTAINER_NAME_API$"; then
    echo -e "${YELLOW}容器未运行，正在启动...${NC}"
    docker start "$CONTAINER_NAME_API"
    if [ $? -ne 0 ]; then
      echo -e "${RED}错误：无法启动容器！${NC}"
      read -p "按回车返回主菜单..." temp
      main_menu
    fi
  fi

  # 输入新密码
  read -p "请输入新的管理员密码（至少 8 位，包含字母和数字）： " NEW_PWD
  until [[ "$NEW_PWD" =~ ^[A-Za-z0-9]{8,}$ ]]; do
    echo -e "${RED}错误：密码必须至少 8 位，包含字母和数字！${NC}"
    read -p "请重新输入新密码： " NEW_PWD
  done

  # 执行密码重置
  docker exec "$CONTAINER_NAME_API" ./apimain reset-admin-pwd "$NEW_PWD"
  if [ $? -eq 0 ]; then
    echo -e "${GREEN}管理员密码重置成功！新密码：$NEW_PWD${NC}"
  else
    echo -e "${RED}错误：密码重置失败！请检查容器日志（docker logs $CONTAINER_NAME_API）。${NC}"
  fi
  read -p "按回车返回主菜单..." temp
  main_menu
}

# 查看容器状态
check_status() {
  check_docker
  echo -e "${YELLOW}容器状态：${NC}"
  docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "$CONTAINER_NAME_HBBS|$CONTAINER_NAME_HBBR|$CONTAINER_NAME_API" || echo -e "${YELLOW}无相关容器运行。${NC}"
  read -p "按回车返回主菜单..." temp
  main_menu
}

# 启动容器
start_containers() {
  check_docker
  docker start "$CONTAINER_NAME_HBBS" "$CONTAINER_NAME_HBBR" "$CONTAINER_NAME_API" >/dev/null 2>&1 || true
  echo -e "${GREEN}所有容器已启动（或部分容器未找到）。${NC}"
  read -p "按回车返回主菜单..." temp
  main_menu
}

# 停止容器
stop_containers() {
  check_docker
  docker stop "$CONTAINER_NAME_HBBS" "$CONTAINER_NAME_HBBR" "$CONTAINER_NAME_API" >/dev/null 2>&1 || true
  echo -e "${GREEN}所有容器已停止（或部分容器未找到）。${NC}"
  read -p "按回车返回主菜单..." temp
  main_menu
}

# 卸载清理
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

# 查看最新生成的 Key
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

# 查看服务器信息
view_server_info() {
  SERVER_ID=$(get_server_id "$CONTAINER_NAME_HBBS")
  NET_MODE=$(docker inspect "$CONTAINER_NAME_HBBS" | grep '"NetworkMode":' | grep -q '"host"' && echo "host" || echo "bridge")
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

# 主菜单
main_menu() {
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
    *) echo -e "${RED}无效选择！${NC}" ; sleep 2 ; main_menu ;;
  esac
}

# 脚本入口
echo -e "${GREEN}欢迎使用 RustDesk 自部署脚本！${NC}"
main_menu
