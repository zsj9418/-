#!/bin/bash
set -euo pipefail
trap 'echo -e "\n${RED}脚本被中断${NC}"; exit 1' INT

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
CYAN='\033[0;36m'
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
    echo -e "${RED}错误：Docker 服务未运行！请启动 Docker 服务。${NC}"
    exit 1
  fi
}

# ==================== 检测架构 ====================
detect_architecture() {
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64 | amd64) PLATFORM="" ;; # amd64默认留空
    armv7l | armhf) PLATFORM="linux/arm/v7" ;;
    aarch64 | arm64) PLATFORM="linux/arm64" ;;
    mips | mipsel) PLATFORM="linux/mips" ;;
    *) echo -e "${RED}不支持的架构 ($ARCH)${NC}" && exit 1 ;;
  esac
}

# ==================== 检测操作系统 ====================
detect_os() {
  if [[ -f /etc/openwrt_release ]]; then
    OS="OpenWrt"
    PACKAGE_MANAGER="opkg"
    IS_OPENWRT=true
  elif [[ -f /etc/debian_version ]]; then
    OS="Debian/Ubuntu"
    PACKAGE_MANAGER="apt"
  elif [[ -f /etc/redhat-release ]]; then
    OS="CentOS/RHEL"
    PACKAGE_MANAGER="dnf"
  elif [[ -f /etc/alpine-release ]]; then
    OS="Alpine"
    PACKAGE_MANAGER="apk"
  else
    echo -e "${YELLOW}未能精准识别系统，将尝试通用回退方案。${NC}"
    PACKAGE_MANAGER="apt"
  fi
  export IS_OPENWRT
}

# ==================== 依赖安装 (包含jq用于无损更新) ====================
install_dependency() {
  local cmd=$1
  local install_cmd=$2
  if ! command -v "$cmd" &>/dev/null; then
    echo -e "${YELLOW}正在安装缺失依赖: $cmd...${NC}"
    if ! eval "$install_cmd" >/dev/null 2>&1; then
      echo -e "${RED}$cmd 安装失败，请手动安装后重试。${NC}"
      exit 1
    fi
  fi
}

check_dependencies() {
  detect_os
  if $IS_OPENWRT; then
    install_dependency "docker" "opkg update && opkg install dockerd docker"
    install_dependency "netstat" "opkg install net-tools"
    install_dependency "ss" "opkg install iproute2"
    install_dependency "jq" "opkg install jq"
    /etc/init.d/dockerd enable 2>/dev/null || true
    /etc/init.d/dockerd start 2>/dev/null || true
  else
    install_dependency "docker" "sudo $PACKAGE_MANAGER update && sudo $PACKAGE_MANAGER install -y docker.io"
    install_dependency "lsof" "sudo $PACKAGE_MANAGER install -y lsof"
    install_dependency "ss" "sudo $PACKAGE_MANAGER install -y iproute2"
    install_dependency "jq" "sudo $PACKAGE_MANAGER install -y jq"
    if ! systemctl is-active --quiet docker 2>/dev/null; then
      sudo systemctl start docker 2>/dev/null || true
      sudo systemctl enable docker 2>/dev/null || true
    fi
  fi
  check_docker
}

check_user_permission() {
  if $IS_OPENWRT; then
    if [[ $(id -u) -ne 0 ]]; then
      echo -e "${RED}OpenWrt 系统建议直接使用 root 用户运行此脚本。${NC}"
      exit 1
    fi
  else
    if ! id -nG "$(whoami)" | grep -qw "docker"; then
      echo -e "${YELLOW}尝试修复 Docker 权限问题...${NC}"
      if ! sudo usermod -aG docker "$(whoami)"; then
        echo -e "${RED}添加用户到 Docker 组失败，请手动执行 'sudo usermod -aG docker $(whoami)'。${NC}"
        exit 1
      fi
      echo -e "${RED}已将当前用户加入 Docker 用户组，请重新登录后再运行脚本。${NC}"
      exit 1
    fi
  fi
}

# ==================== 端口验证 ====================
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

validate_port() {
  local port=$1
  if [[ $port =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
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

# ==================== Key提取 (优化版，优先物理文件读取) ====================
extract_key() {
  # 直接读取物理文件速度最快、最可靠
  if [ -f "$SERVER_DATA_DIR/id_ed25519.pub" ]; then
    cat "$SERVER_DATA_DIR/id_ed25519.pub"
    return
  fi
  # 兜底：读取日志
  local container_name=$1
  for container in "$CONTAINER_NAME_HBBS" "$CONTAINER_NAME_HBBR"; do
    KEY_LINE=$(docker logs "$container" --tail 50 2>/dev/null | grep "Key:" | tail -1)
    if [ -n "$KEY_LINE" ]; then
      echo "$KEY_LINE" | sed -n 's/.*Key: \([^ ]*\).*/\1/p'
      return
    fi
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

# ==================== 防火墙自动放行 ====================
open_firewall() {
  local ports=("${HBBS_PORTS[@]}" "${HBBR_PORTS[@]}")
  if command -v ufw &>/dev/null; then
    for port in "${ports[@]}"; do
      sudo ufw allow "$port/tcp" &>/dev/null || true
    done
    sudo ufw allow 21116/udp &>/dev/null || true
    sudo ufw reload &>/dev/null || true
    echo -e "${GREEN}ufw 防火墙已放行对应端口${NC}"
  elif command -v firewall-cmd &>/dev/null; then
    for port in "${ports[@]}"; do
      sudo firewall-cmd --add-port="$port/tcp" --permanent &>/dev/null || true
    done
    sudo firewall-cmd --add-port=21116/udp --permanent &>/dev/null || true
    sudo firewall-cmd --reload &>/dev/null || true
    echo -e "${GREEN}firewalld 防火墙已放行对应端口${NC}"
  fi
}

# ==================== 部署 hbbs 和 hbbr ====================
deploy_hbbs_hbbr() {
  echo -e "${YELLOW}开始部署 RustDesk 服务器 (hbbs 和 hbbr)...${NC}"
  docker rm -f "$CONTAINER_NAME_HBBS" "$CONTAINER_NAME_HBBR" >/dev/null 2>&1 || true
  
  echo "请选择网络模式："
  echo "1) Host 模式（容器共享宿主机网络，无需映射，适合软路由）"
  echo "2) 桥接（Bridge）模式（容器隔离，适合公网 VPS）"
  read -p "输入（1 或 2，回车默认 1）： " net_mode
  net_mode=${net_mode:-1}
  
  if [ "$net_mode" == "1" ]; then
    echo -e "${GREEN}你选择了 Host 模式。${NC}"
    HBBS_PORTS=("21115" "21116" "21117" "21118" "21119")
    HBBR_PORTS=("21115" "21116" "21117" "21118" "21119")
    NET_MODE="host"
    if ! validate_ports_host_mode "${HBBS_PORTS[@]}"; then
      echo -e "${RED}错误：端口格式无效！${NC}"
      sleep 2
      return
    fi
  elif [ "$net_mode" == "2" ]; then
    echo -e "${YELLOW}你选择了桥接模式。${NC}"
   
    echo "默认 hbbs 宿主机端口：${HBBS_PORTS[*]}"
    read -p "请输入 hbbs 宿主机端口（多个用空格隔开，回车使用默认）： " hbbs_host_ports
    hbbs_host_ports=${hbbs_host_ports:-"${HBBS_PORTS[*]}"}
    read -r -a hbbs_ports_array <<< "$hbbs_host_ports"
    if [ ${#hbbs_ports_array[@]} -ne 5 ]; then
      echo -e "${RED}错误：请输入 5 个端口！${NC}"
      sleep 2
      return
    fi
    if ! validate_ports "${hbbs_ports_array[@]}"; then
      sleep 2
      return
    fi
    port_args_hbbs=""
    container_ports=("21115" "21116" "21117" "21118" "21119")
    for i in {0..4}; do
      port_args_hbbs="$port_args_hbbs -p ${hbbs_ports_array[$i]}:${container_ports[$i]}"
      if [ "${container_ports[$i]}" == "21116" ]; then
        port_args_hbbs="$port_args_hbbs -p ${hbbs_ports_array[$i]}:21116/udp"
      fi
    done
    HBBS_PORTS=("${hbbs_ports_array[@]}")
    
    echo "默认 hbbr 宿主机端口：${HBBR_PORTS[*]}"
    read -p "请输入 hbbr 宿主机端口（多个用空格隔开，回车使用默认）： " hbbr_host_ports
    hbbr_host_ports=${hbbr_host_ports:-"${HBBR_PORTS[*]}"}
    read -r -a hbbr_ports_array <<< "$hbbr_host_ports"
    if [ ${#hbbr_ports_array[@]} -ne 5 ]; then
      echo -e "${RED}错误：请输入 5 个端口！${NC}"
      sleep 2
      return
    fi
    if ! validate_ports "${hbbr_ports_array[@]}"; then
      sleep 2
      return
    fi
    port_args_hbbr=""
    for i in {0..4}; do
      port_args_hbbr="$port_args_hbbr -p ${hbbr_ports_array[$i]}:${container_ports[$i]}"
      if [ "${container_ports[$i]}" == "21116" ]; then
        port_args_hbbr="$port_args_hbbr -p ${hbbr_ports_array[$i]}:21116/udp"
      fi
    done
    HBBR_PORTS=("${hbbr_ports_array[@]}")
    NET_MODE="bridge"
  else
    echo -e "${RED}无效选择。${NC}"
    sleep 2
    return
  fi

  echo -e "${YELLOW}正在拉取镜像 $IMAGE_NAME_HBBS_HBBR...${NC}"
  local fallback_images=("rustdesk/rustdesk-server:1.1.10-1" "rustdesk/rustdesk-server:s6" "rustdesk/rustdesk-server:1.1.9-2")
  if ! docker pull "$IMAGE_NAME_HBBS_HBBR" 2>&1 | tee -a "$LOG_FILE"; then
    for fallback in "${fallback_images[@]}"; do
      echo -e "${YELLOW}尝试备用镜像：$fallback${NC}"
      if docker pull "$fallback" 2>&1 | tee -a "$LOG_FILE"; then
        IMAGE_NAME_HBBS_HBBR="$fallback"
        break
      fi
    done
  fi

  if [ "$NET_MODE" == "bridge" ]; then
    docker network create rustdesk-net >/dev/null 2>&1 || true
  fi

  echo -e "${YELLOW}开始部署 hbbs 容器...${NC}"
  local network_arg=$([ "$NET_MODE" == "bridge" ] && echo "--network rustdesk-net $port_args_hbbs" || echo "--net=host")
  if ! docker run -d --name "$CONTAINER_NAME_HBBS" --restart=unless-stopped $network_arg \
    -v "$SERVER_DATA_DIR:/root" ${PLATFORM:+--platform "$PLATFORM"} "$IMAGE_NAME_HBBS_HBBR" hbbs 2>&1 | tee -a "$LOG_FILE"; then
    echo -e "${RED}错误：hbbs 容器启动失败！请检查日志。${NC}"
    sleep 2
    return
  fi

  echo -e "${YELLOW}开始部署 hbbr 容器...${NC}"
  local network_arg=$([ "$NET_MODE" == "bridge" ] && echo "--network rustdesk-net $port_args_hbbr" || echo "--net=host")
  if ! docker run -d --name "$CONTAINER_NAME_HBBR" --restart=unless-stopped $network_arg \
    -v "$SERVER_DATA_DIR:/root" ${PLATFORM:+--platform "$PLATFORM"} "$IMAGE_NAME_HBBS_HBBR" hbbr 2>&1 | tee -a "$LOG_FILE"; then
    echo -e "${RED}错误：hbbr 容器启动失败！请检查日志。${NC}"
    docker rm -f "$CONTAINER_NAME_HBBS" >/dev/null 2>&1 || true
    sleep 2
    return
  fi

  open_firewall

  echo -e "${GREEN}容器已启动，等待密钥生成...${NC}"
  sleep 5
  KEY=$(extract_key "$CONTAINER_NAME_HBBS")
  SERVER_IP=$([ "$NET_MODE" == "host" ] && echo "127.0.0.1" || get_server_ip)
  SERVER_PORT=$([ "$NET_MODE" == "host" ] && echo "${HBBS_PORTS[2]}" || echo "${HBBR_PORTS[2]}")
  
  echo -e "\n${GREEN}== 服务器密钥信息 ==${NC}"
  echo "IP: $SERVER_IP"
  echo "中继端口: $SERVER_PORT"
  echo "Key: $KEY"
  echo "客户端配置指南："
  echo " ID 服务器: $SERVER_IP:${HBBS_PORTS[1]}"
  echo " 中继服务器: $SERVER_IP:$SERVER_PORT"
  echo -e "${YELLOW}请将公钥内容复制到客户端配置中${NC}"
  echo ""
  read -p "按回车返回主菜单..." temp
}

# ==================== 部署API ====================
deploy_api() {
  echo -e "${YELLOW}开始部署 RustDesk API 容器...${NC}"
  if ! docker ps -a --format '{{.Names}}' | grep -q "^$CONTAINER_NAME_HBBS$"; then
    echo -e "${RED}错误：hbbs 容器未运行！请先部署 hbbs 和 hbbr。${NC}"
    sleep 2
    return
  fi
  
  NET_MODE=$(docker inspect "$CONTAINER_NAME_HBBS" | grep '"NetworkMode":' | grep -q '"host"' && echo "host" || echo "bridge")
  echo -e "${GREEN}检测到 hbbs 使用 $NET_MODE 模式，API 将跟随使用相同模式。${NC}"
  
  if [ "$NET_MODE" == "host" ]; then
    port_args="--net=host"
    API_PORT=21114
    if ! validate_port_host_mode "$API_PORT"; then
      echo -e "${RED}错误：API 端口 $API_PORT 格式无效！${NC}"
      sleep 2
      return
    fi
    ID_PORT=21116
    RELAY_PORT=21117
    SERVER_IP="127.0.0.1"
    ID_SERVER="127.0.0.1"
    RELAY_SERVER="127.0.0.1"
  else
    read -p "请输入宿主机端口（回车使用默认 21114）： " host_port
    host_port=${host_port:-21114}
    if ! validate_port "$host_port"; then
      echo -e "${RED}错误：宿主机端口 $host_port 无效或已被占用！${NC}"
      sleep 2
      return
    fi
    port_args="-p $host_port:21114 --network rustdesk-net"
    API_PORT=$host_port
    ID_PORT=21116
    RELAY_PORT=21117
    SERVER_IP=$(get_server_ip)
    ID_SERVER="$CONTAINER_NAME_HBBS"
    RELAY_SERVER="$CONTAINER_NAME_HBBR"
  fi
  
  echo -e "${YELLOW}检测 hbbs 容器中的密钥...${NC}"
  RUSTDESK_KEY=$(extract_key "$CONTAINER_NAME_HBBS")
  if [ "$RUSTDESK_KEY" == "未检测到 Key 信息" ]; then
    echo -e "${YELLOW}未检测到密钥，建议留空以使用挂载文件。${NC}"
    read -p "请输入密钥（留空则使用挂载密钥文件）： " RUSTDESK_KEY
  else
    echo -e "${GREEN}检测到的密钥：$RUSTDESK_KEY${NC}"
    read -p "请输入密钥（回车使用检测到的密钥）： " input_key
    RUSTDESK_KEY=${input_key:-$RUSTDESK_KEY}
  fi
  
  if [ -z "$RUSTDESK_KEY" ]; then
    KEY_ENV=""
    KEY_VOLUME="-v $(realpath $SERVER_DATA_DIR):/app/data"
  else
    KEY_ENV="-e RUSTDESK_KEY=\"$RUSTDESK_KEY\""
    KEY_VOLUME=""
  fi
  
  read -p "请输入时区（默认 Asia/Shanghai）： " TZ
  TZ=${TZ:-Asia/Shanghai}
  read -p "请输入界面语言（默认 zh-CN）： " LANG
  LANG=${LANG:-zh-CN}
  
  docker rm -f "$CONTAINER_NAME_API" &> /dev/null || true
  
  echo -e "${YELLOW}正在拉取镜像 $IMAGE_NAME_API...${NC}"
  docker pull "$IMAGE_NAME_API" 2>&1 | tee -a "$LOG_FILE" || docker pull "lejianwen/rustdesk-api:full-s6"
  
  echo -e "${YELLOW}正在启动 RustDesk API 容器...${NC}"
  if ! docker run -d --name "$CONTAINER_NAME_API" \
    $port_args \
    -v "$(realpath $API_DATA_DIR):/app/data" \
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
    echo -e "${RED}错误：API 容器启动失败！请检查日志。${NC}"
    sleep 2
    return
  fi
  
  echo -e "${GREEN}RustDesk API 容器启动成功！${NC}"
  echo -e "${GREEN}访问地址：http://$SERVER_IP:$API_PORT/_admin/${NC}"
  echo -e "${GREEN}默认账号：admin，密码请查阅：docker logs $CONTAINER_NAME_API | grep password${NC}"
  read -p "按回车返回主菜单..." temp
}

# ==================== 无损更新核心功能 ====================
do_upgrade_container() {
    local cname="$1"
    local image="$2"
    local cmd_suffix="$3"

    if ! docker ps -a --format '{{.Names}}' | grep -q "^$cname$"; then
        echo -e "${YELLOW}容器 $cname 未部署，跳过。${NC}"
        return 0
    fi

    echo -e "${CYAN}📦 正在提取 $cname 配置...${NC}"
    local c_info=$(docker inspect "$cname")

    local net_mode=$(echo "$c_info" | jq -r '.[0].HostConfig.NetworkMode')
    local restart_policy=$(echo "$c_info" | jq -r '.[0].HostConfig.RestartPolicy.Name')

    local -a run_args=("-d" "--name" "$cname")
    [[ -n "$restart_policy" && "$restart_policy" != "no" && "$restart_policy" != "null" ]] && run_args+=("--restart" "$restart_policy")
    [[ -n "$net_mode" && "$net_mode" != "default" && "$net_mode" != "null" ]] && run_args+=("--network" "$net_mode")

    # 精准提取端口
    if [ "$net_mode" != "host" ]; then
        local -a ports
        mapfile -t ports < <(echo "$c_info" | jq -r 'if .[0].HostConfig.PortBindings then .[0].HostConfig.PortBindings | to_entries[] | "-p", "\(.value[0].HostPort):\(.key)" else empty end')
        (( ${#ports[@]} > 0 )) && run_args+=("${ports[@]}")
    fi

    # 提取挂载路径
    local -a mounts
    mapfile -t mounts < <(echo "$c_info" | jq -r '.[0].Mounts[]? | "-v", "\(.Source):\(.Destination)"')
    (( ${#mounts[@]} > 0 )) && run_args+=("${mounts[@]}")

    # 提取环境变量 (仅保留RUSTDESK相关和TZ，防止污染系统级变量)
    local -a envs
    mapfile -t envs < <(echo "$c_info" | jq -r '.[0].Config.Env[]? | select(test("^RUSTDESK_|^TZ=")) | "-e", .')
    (( ${#envs[@]} > 0 )) && run_args+=("${envs[@]}")

    echo -e "${YELLOW}⬇️ 正在拉取最新镜像 $image...${NC}"
    docker pull "$image" >/dev/null

    echo -e "${YELLOW}🗑️ 销毁并重建容器 $cname...${NC}"
    docker rm -f "$cname" >/dev/null 2>&1
    
    if [ -n "$cmd_suffix" ]; then
        docker run "${run_args[@]}" ${PLATFORM:+--platform "$PLATFORM"} "$image" $cmd_suffix >/dev/null
    else
        docker run "${run_args[@]}" ${PLATFORM:+--platform "$PLATFORM"} "$image" >/dev/null
    fi
    echo -e "${GREEN}✅ $cname 无损更新并启动成功！${NC}"
}

upgrade_rustdesk_all() {
    echo -e "\n${CYAN}--- 🔄 更新 RustDesk 组件 (无损保留所有配置) ---${NC}"
    echo "请选择要更新的组件："
    echo "1) 仅更新 服务器 (hbbs & hbbr)"
    echo "2) 仅更新 API 面板"
    echo "3) 全部更新"
    echo "4) 取消"
    read -p "请输入 [1-4]: " up_choice

    case $up_choice in
        1)
            do_upgrade_container "$CONTAINER_NAME_HBBS" "$IMAGE_NAME_HBBS_HBBR" "hbbs"
            do_upgrade_container "$CONTAINER_NAME_HBBR" "$IMAGE_NAME_HBBS_HBBR" "hbbr"
            ;;
        2)
            do_upgrade_container "$CONTAINER_NAME_API" "$IMAGE_NAME_API" ""
            ;;
        3)
            do_upgrade_container "$CONTAINER_NAME_HBBS" "$IMAGE_NAME_HBBS_HBBR" "hbbs"
            do_upgrade_container "$CONTAINER_NAME_HBBR" "$IMAGE_NAME_HBBS_HBBR" "hbbr"
            do_upgrade_container "$CONTAINER_NAME_API" "$IMAGE_NAME_API" ""
            ;;
        *) return ;;
    esac
    read -p "按回车返回主菜单..." temp
}

# ==================== 其他工具 ====================
reset_api_password() {
  if ! docker ps -a --format '{{.Names}}' | grep -q "^$CONTAINER_NAME_API$"; then
    echo -e "${RED}未部署 API 容器。${NC}"
    sleep 2
    return
  fi
  docker start "$CONTAINER_NAME_API" >/dev/null 2>&1
  read -p "请输入新密码（字母+数字，最少8位）： " NEW_PWD
  until [[ "$NEW_PWD" =~ ^[A-Za-z0-9]{8,}$ ]]; do
    read -p "格式错误，请重新输入： " NEW_PWD
  done
  if docker exec "$CONTAINER_NAME_API" ./apimain reset-admin-pwd "$NEW_PWD"; then
    echo -e "${GREEN}密码重置成功！新密码：$NEW_PWD${NC}"
  else
    echo -e "${RED}密码重置失败！${NC}"
  fi
  read -p "按回车返回..." temp
}

check_status() {
  echo -e "${YELLOW}容器状态：${NC}"
  docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "$CONTAINER_NAME_HBBS|$CONTAINER_NAME_HBBR|$CONTAINER_NAME_API" || echo "无容器运行"
  read -p "按回车返回..." temp
}

start_containers() {
  docker start "$CONTAINER_NAME_HBBS" "$CONTAINER_NAME_HBBR" "$CONTAINER_NAME_API" >/dev/null 2>&1 || true
  echo -e "${GREEN}相关容器已启动。${NC}"
  sleep 1
}

stop_containers() {
  docker stop "$CONTAINER_NAME_HBBS" "$CONTAINER_NAME_HBBR" "$CONTAINER_NAME_API" >/dev/null 2>&1 || true
  echo -e "${GREEN}相关容器已停止。${NC}"
  sleep 1
}

cleanup() {
  echo -e "${YELLOW}停止并删除所有容器...${NC}"
  docker rm -f "$CONTAINER_NAME_HBBS" "$CONTAINER_NAME_HBBR" "$CONTAINER_NAME_API" >/dev/null 2>&1 || true
  rm -rf "$DATA_DIR"
  docker network rm rustdesk-net >/dev/null 2>&1 || true
  echo -e "${GREEN}完成卸载清理。${NC}"
  read -p "按回车返回..." temp
}

view_latest_key() {
  echo -e "${YELLOW}正在提取最新 Key...${NC}"
  KEY=$(extract_key "$CONTAINER_NAME_HBBS")
  echo -e "${GREEN}Key：${NC}\n$KEY"
  read -p "按回车返回..." temp
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
  echo "中继地址：$RELAY_ADDR"
  echo "API 管理：$API_ADDR"
  read -p "按回车返回..." temp
}

# ==================== 主菜单 ====================
main_menu() {
  # 初始化操作仅在打开脚本时运行一次
  detect_architecture
  check_dependencies
  check_user_permission
  
  while true; do
    clear
    echo -e "${CYAN}================ RustDesk 终极部署脚本 ================${NC}"
    echo "1) 部署 RustDesk 服务器 (hbbs & hbbr)"
    echo "2) 部署 RustDesk API 管理面板"
    echo -e "3) 无损更新 RustDesk 相关组件 ${YELLOW}[保留配置]${NC}"
    echo "4) 重置 API 管理员密码"
    echo "5) 查看容器状态"
    echo "6) 启动所有容器"
    echo "7) 停止所有容器"
    echo "8) 卸载并清理数据"
    echo "9) 查看当前公钥 (Key)"
    echo "10) 查看客户端填写配置"
    echo "11) 退出"
    echo -e "${CYAN}=======================================================${NC}"
    read -p "请输入选择（1-11）： " choice
    case $choice in
      1) deploy_hbbs_hbbr ;;
      2) deploy_api ;;
      3) upgrade_rustdesk_all ;;
      4) reset_api_password ;;
      5) check_status ;;
      6) start_containers ;;
      7) stop_containers ;;
      8) cleanup ;;
      9) view_latest_key ;;
      10) view_server_info ;;
      11) echo -e "${GREEN}退出程序${NC}" ; exit 0 ;;
      *) echo -e "${RED}无效选择！${NC}" ; sleep 1 ;;
    esac
  done
}

# 脚本入口
main_menu
