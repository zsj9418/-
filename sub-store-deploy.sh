#!/bin/bash

# 目录和变量
DATA_DIR="$HOME/substore/data"
SCRIPTS_DIR="$HOME/substore/scripts"
BACKUP_DIR="$HOME/substore/backup"
LOG_DIR="$HOME/substore/logs"
LOG_FILE="$LOG_DIR/docker_management.log"
LOG_MAX_SIZE=1048576
CONTAINER_NAME="substore"
WATCHTOWER_CONTAINER_NAME="watchtower"
TIMEZONE="Asia/Shanghai"
SUB_STORE_IMAGE_NAME="xream/sub-store"
WATCHTOWER_IMAGE_NAME="containrrr/watchtower"
DEFAULT_SUB_STORE_PATH="/12345678"
DEFAULT_FRONTEND_PORT=3000
DEFAULT_BACKEND_PORT=3001

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# 日志
log() {
  local level=$1
  local message=$2
  local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
  case "$level" in
    "INFO") echo -e "${GREEN}[INFO] $timestamp - $message${NC}" >&2 ;;
    "WARN") echo -e "${YELLOW}[WARN] $timestamp - $message${NC}" >&2 ;;
    "ERROR") echo -e "${RED}[ERROR] $timestamp - $message${NC}" >&2 ;;
  esac
  echo "[$level] $timestamp - $message" >> "$LOG_FILE"
  if [[ -f "$LOG_FILE" && $(wc -c < "$LOG_FILE") -ge $LOG_MAX_SIZE ]]; then
    > "$LOG_FILE"
    log "INFO" "日志文件大小超过 1M，已清空日志。"
  fi
}

create_directories() {
  mkdir -p "$DATA_DIR" "$SCRIPTS_DIR" "$BACKUP_DIR" "$LOG_DIR"
  log "INFO" "所有必要的目录已创建"
}

detect_system() {
  ARCH=$(uname -m)
  OS="unknown"
  if [ -f /etc/openwrt_release ] || grep -qi "openwrt" /etc/*release 2>/dev/null; then
    OS="openwrt"
  elif [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
  else
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  fi
  case "$ARCH" in
    "x86_64"|"amd64") ARCH="amd64" ;;
    "aarch64"|"arm64") ARCH="arm64" ;;
    "armv7l"|"armv6l") ARCH="arm" ;;
    "i386"|"i686") ARCH="386" ;;
  esac
  export ARCH OS
  log "INFO" "检测到系统: $OS, 架构: $ARCH"
}

check_network() {
  for i in {1..3}; do
    if curl -s -m 5 https://hub.docker.com >/dev/null; then
      return 0
    fi
    sleep 2
  done
  log "ERROR" "无法连接到网络，请检查网络"
  exit 1
}

check_docker_permissions() {
  if [[ ! -S /var/run/docker.sock || ! -r /var/run/docker.sock || ! -w /var/run/docker.sock ]]; then
    if ! groups "$USER" | grep -q docker; then
      if command -v usermod >/dev/null 2>&1; then
        sudo usermod -aG docker "$USER"
        log "INFO" "已添加用户到 docker 组，请重新登录"
      else
        log "ERROR" "无法找到 usermod 命令，请手动添加用户到 docker 组"
        exit 1
      fi
    fi
    if ! sudo chmod 660 /var/run/docker.sock || ! sudo chown root:docker /var/run/docker.sock 2>/dev/null; then
      log "ERROR" "无法修复 Docker 权限，请手动检查 /var/run/docker.sock"
      exit 1
    fi
  fi
}

install_dependencies() {
  # 检查 curl
  if ! command -v curl >/dev/null 2>&1; then
    case "$OS" in
      "ubuntu"|"debian") apt-get update && apt-get install -y curl ;;
      "centos"|"rhel"|"rocky"|"almalinux") yum install -y curl ;;
      "openwrt") opkg update; opkg install curl || log "WARN" "curl 安装失败，请手动安装" ;;
      *) log "ERROR" "不支持的操作系统: $OS"; exit 1 ;;
    esac
  fi

  # 检查 lsof/ss/netstat
  if ! command -v ss >/dev/null 2>&1 && ! command -v netstat >/dev/null 2>&1 && ! command -v lsof >/dev/null 2>&1; then
    case "$OS" in
      "ubuntu"|"debian") apt-get install -y net-tools lsof iproute2 ;;
      "centos"|"rhel"|"rocky"|"almalinux") yum install -y net-tools lsof iproute ;;
      "openwrt")
        opkg update
        opkg install lsof || log "WARN" "lsof 安装失败"
        opkg install netstat || log "WARN" "netstat 安装失败"
        opkg install ip-full || log "WARN" "ip-full 安装失败"
        ;;
      *) log "WARN" "未能自动安装端口检测工具，部分功能可能不可用" ;;
    esac
  fi

  # 检查 docker
  if ! command -v docker >/dev/null 2>&1; then
    case "$OS" in
      "ubuntu"|"debian")
        apt-get update && apt-get install -y ca-certificates
        curl -fsSL https://get.docker.com | sh
        ;;
      "centos"|"rhel"|"rocky"|"almalinux")
        yum install -y ca-certificates
        curl -fsSL https://get.docker.com | sh
        ;;
      "openwrt")
        log "WARN" "OpenWrt 请手动安装 Docker，安装命令：opkg update && opkg install docker dockerd"
        ;;
      *)
        log "ERROR" "不支持的操作系统: $OS"
        exit 1
        ;;
    esac
    if [ "$OS" != "openwrt" ]; then
      if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now docker >/dev/null 2>&1
      elif command -v service >/dev/null 2>&1; then
        service docker enable && service docker start
      fi
    fi
  fi

  # 检查 jq
  if ! command -v jq >/dev/null 2>&1; then
    case "$OS" in
      "ubuntu"|"debian") apt-get install -y jq ;;
      "centos"|"rhel"|"rocky"|"almalinux") yum install -y jq ;;
      "openwrt") opkg install jq || opkg install jq-full || log "WARN" "jq 安装失败，请手动安装" ;;
      *) log "ERROR" "不支持的操作系统: $OS"; exit 1 ;;
    esac
  fi
}

pull_image() {
  local image_name=$1
  local image_tag=$2
  for i in {1..3}; do
    if docker pull "$image_name:$image_tag"; then
      return 0
    fi
    sleep 5
  done
  log "ERROR" "拉取镜像 $image_name:$image_tag 失败。请确认镜像支持你的架构($ARCH)。"
  exit 1
}

check_port_available() {
  local port=$1
  if command -v ss >/dev/null 2>&1; then
    ss -tuln | grep -q ":$port" && return 1
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tuln | grep -q ":$port" && return 1
  elif command -v lsof >/dev/null 2>&1; then
    lsof -i:"$port" >/dev/null 2>&1 && return 1
  else
    log "WARN" "未找到 ss、netstat、lsof，跳过端口检查"
    return 0
  fi
  return 0
}

prompt_for_port() {
  local prompt_message=$1
  local default_port=$2
  local port=""
  while true; do
    read -p "$prompt_message [$default_port]: " port
    port=${port:-$default_port}
    if [[ $port =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
      if check_port_available "$port"; then
        echo "$port"
        return
      else
        log "WARN" "端口 $port 已被占用，请选择其他端口"
      fi
    else
      log "WARN" "无效的端口号，请输入 1 到 65535 之间的数字"
    fi
  done
}

prompt_for_path() {
  local default_path=$(basename "$DEFAULT_SUB_STORE_PATH")
  local user_input=""
  read -p "请输入 Sub-Store 前后端路径（只需输入路径名，不需加/） [$default_path]: " user_input
  user_input=${user_input:-$default_path}
  SUB_STORE_FRONTEND_BACKEND_PATH="/${user_input//[^a-zA-Z0-9_-./]/}"
}

get_substore_versions() {
  local versions
  for i in {1..3}; do
    versions=$(curl -s -m 15 "https://hub.docker.com/v2/repositories/xream/sub-store/tags/?page_size=15" | jq -r '.results[].name' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+(-http-meta)?$' | sort -r)
    [[ -n "$versions" ]] && break
    sleep 2
  done
  if [[ -z "$versions" ]]; then
    read -p "请输入 Sub-Store 版本（例如: latest 或 1.0.0）: " SUB_STORE_VERSION
    SUB_STORE_VERSION=${SUB_STORE_VERSION:-latest}
    echo "$SUB_STORE_VERSION"
  else
    echo "latest $versions"
  fi
}

prompt_for_version() {
  local versions=($(get_substore_versions))
  local num_versions=${#versions[@]}
  echo "请选择 Sub-Store 版本（推荐使用 latest 以确保自动更新）："
  for i in "${!versions[@]}"; do
    echo "$((i + 1)). ${versions[$i]}"
  done
  while true; do
    read -p "请输入版本编号: " version_choice
    if [[ $version_choice =~ ^[0-9]+$ ]] && [ "$version_choice" -ge 1 ] && [ "$version_choice" -le "$num_versions" ]; then
      SUB_STORE_VERSION=${versions[$((version_choice - 1))]}
      break
    else
      log "WARN" "无效的选择，请重新输入"
    fi
  done
}

install_substore() {
  prompt_for_version
  pull_image "$SUB_STORE_IMAGE_NAME" "$SUB_STORE_VERSION"
  while true; do
    read -p "请选择网络模式 (bridge 或 host) [默认: bridge]: " network_mode
    network_mode=${network_mode:-bridge}
    if [[ "$network_mode" == "bridge" || "$network_mode" == "host" ]]; then
      NETWORK_MODE="$network_mode"
      break
    fi
  done
  prompt_for_path
  local docker_cmd=(
    docker run -d
    --name "$CONTAINER_NAME"
    --restart=always
    -v "${DATA_DIR}:/opt/app/data"
    -v "${SCRIPTS_DIR}:/opt/app/scripts"
    -e TZ="$TIMEZONE"
    -e SUB_STORE_FRONTEND_BACKEND_PATH="$SUB_STORE_FRONTEND_BACKEND_PATH"
  )
  if [[ "$NETWORK_MODE" == "host" ]]; then
    docker_cmd+=(--network host)
  else
    HOST_PORT_1=$(prompt_for_port "请输入前端端口 (Web UI)" "$DEFAULT_FRONTEND_PORT")
    HOST_PORT_2=$(prompt_for_port "请输入后端端口" "$DEFAULT_BACKEND_PORT")
    docker_cmd+=(-p "${HOST_PORT_1}:3000" -p "${HOST_PORT_2}:3001")
  fi
  docker_cmd+=("$SUB_STORE_IMAGE_NAME:$SUB_STORE_VERSION")
  "${docker_cmd[@]}" || {
    log "ERROR" "容器启动失败"
    exit 1
  }
  log "INFO" "Sub-Store 容器启动成功"
}

manual_upgrade_substore() {
  if ! docker ps -a --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
    log "ERROR" "未检测到已部署的 Sub-Store 容器，无法升级。"
    return
  fi

  prompt_for_version
  pull_image "$SUB_STORE_IMAGE_NAME" "$SUB_STORE_VERSION"

  local old_network_mode
  old_network_mode=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$CONTAINER_NAME")
  local host_port_3000 host_port_3001
  host_port_3000=$(docker inspect "$CONTAINER_NAME" | jq -r '.[0].HostConfig.PortBindings["3000/tcp"][0].HostPort // empty')
  host_port_3001=$(docker inspect "$CONTAINER_NAME" | jq -r '.[0].HostConfig.PortBindings["3001/tcp"][0].HostPort // empty')
  local old_path
  old_path=$(docker inspect "$CONTAINER_NAME" | jq -r '.[0].Config.Env[]' | grep SUB_STORE_FRONTEND_BACKEND_PATH= | cut -d= -f2-)
  [ -z "$old_path" ] && old_path="$DEFAULT_SUB_STORE_PATH"

  docker stop "$CONTAINER_NAME" >/dev/null 2>&1
  docker rm "$CONTAINER_NAME" >/dev/null 2>&1

  local docker_cmd=(
    docker run -d
    --name "$CONTAINER_NAME"
    --restart=always
    -v "${DATA_DIR}:/opt/app/data"
    -v "${SCRIPTS_DIR}:/opt/app/scripts"
    -e TZ="$TIMEZONE"
    -e SUB_STORE_FRONTEND_BACKEND_PATH="$old_path"
  )

  if [[ "$old_network_mode" == "host" ]]; then
    docker_cmd+=(--network host)
  else
    [ -n "$host_port_3000" ] && docker_cmd+=(-p "${host_port_3000}:3000")
    [ -n "$host_port_3001" ] && docker_cmd+=(-p "${host_port_3001}:3001")
  fi

  docker_cmd+=("$SUB_STORE_IMAGE_NAME:$SUB_STORE_VERSION")
  "${docker_cmd[@]}" || {
    log "ERROR" "升级后容器启动失败"
    exit 1
  }
  log "INFO" "Sub-Store 已升级到 $SUB_STORE_VERSION 并自动恢复原有配置"
}

install_watchtower() {
  local containers
  mapfile -t containers < <(docker ps --format "{{.Names}}")
  if [ ${#containers[@]} -eq 0 ]; then
    log "WARN" "没有找到运行中的容器，无法部署 Watchtower"
    return
  fi
  echo "请选择要监控的容器（多个用空格分隔，推荐选择 substore）："
  for i in "${!containers[@]}"; do
    echo "$((i + 1)). ${containers[$i]}"
  done
  read -p "请输入容器编号（例如: 1 2 3）: " user_input
  local selected_indices=($user_input)
  local selected_containers=()
  for index in "${selected_indices[@]}"; do
    if [[ $index =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le ${#containers[@]} ]; then
      selected_containers+=("${containers[$((index - 1))]}")
    fi
  done
  if [ ${#selected_containers[@]} -eq 0 ]; then
    log "WARN" "没有有效的容器选择，取消部署"
    return
  fi
  local existing_containers
  mapfile -t existing_containers < <(docker ps -a --filter "name=watchtower" --format "{{.ID}}")
  if [ ${#existing_containers[@]} -gt 0 ]; then
    for container_id in "${existing_containers[@]}"; do
      docker stop "$container_id" >/dev/null 2>&1
      docker rm "$container_id" >/dev/null 2>&1
    done
  fi
  pull_image "$WATCHTOWER_IMAGE_NAME" "latest"
  local watchtower_cmd=(
    docker run -d
    --name "$WATCHTOWER_CONTAINER_NAME"
    --restart=always
    -v /var/run/docker.sock:/var/run/docker.sock
    "$WATCHTOWER_IMAGE_NAME:latest"
    --cleanup
    --schedule "0 */10 * * * *"
    --include-stopped
  )
  for container in "${selected_containers[@]}"; do
    watchtower_cmd+=("$container")
  done
  "${watchtower_cmd[@]}" || {
    log "ERROR" "Watchtower 容器启动失败"
    exit 1
  }
  sleep 3
  if ! docker ps --filter "name=$WATCHTOWER_CONTAINER_NAME" --format "{{.Status}}" | grep -q "Up"; then
    log "ERROR" "Watchtower 容器未能保持运行状态"
    exit 1
  fi
  log "INFO" "Watchtower 部署成功，监控容器：${selected_containers[*]}"
}

add_watchtower_containers() {
  if ! docker ps -a --format "{{.Names}}" | grep -q "^${WATCHTOWER_CONTAINER_NAME}$"; then
    log "ERROR" "Watchtower 未部署，请先选择菜单选项部署 Watchtower"
    return
  fi
  local current_containers
  mapfile -t current_containers < <(docker inspect "$WATCHTOWER_CONTAINER_NAME" | jq -r '.[0].Config.Entrypoint[] + " " + .[0].Config.Cmd[]' | grep -oE '[^ ]+$' | grep -vE '^--|^/')
  local all_containers
  mapfile -t all_containers < <(docker ps -a --format "{{.Names}}")
  local available_containers=()
  for container in "${all_containers[@]}"; do
    if ! [[ " ${current_containers[*]} " =~ " $container " ]]; then
      available_containers+=("$container")
    fi
  done
  if [ ${#available_containers[@]} -eq 0 ]; then
    log "WARN" "没有可添加的新容器"
    return
  fi
  echo "请选择要添加的容器（多个用空格分隔）："
  for i in "${!available_containers[@]}"; do
    echo "$((i + 1)). ${available_containers[$i]}"
  done
  read -p "请输入容器编号（例如: 1 2 3）: " user_input
  local selected_indices=($user_input)
  local selected_containers=()
  for index in "${selected_indices[@]}"; do
    if [[ $index =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le ${#available_containers[@]} ]; then
      selected_containers+=("${available_containers[$((index - 1))]}")
    fi
  done
  if [ ${#selected_containers[@]} -eq 0 ]; then
    log "WARN" "没有有效的容器选择，取消添加"
    return
  fi
  local updated_containers=("${current_containers[@]}" "${selected_containers[@]}")
  docker rm -f "$WATCHTOWER_CONTAINER_NAME" >/dev/null 2>&1
  local watchtower_cmd=(
    docker run -d
    --name "$WATCHTOWER_CONTAINER_NAME"
    --restart=always
    -v /var/run/docker.sock:/var/run/docker.sock
    "$WATCHTOWER_IMAGE_NAME"
    --cleanup
    --schedule "0 */10 * * * *"
    --include-stopped
  )
  for container in "${updated_containers[@]}"; do
    watchtower_cmd+=("$container")
  done
  "${watchtower_cmd[@]}" || {
    log "ERROR" "Watchtower 更新失败"
    exit 1
  }
  log "INFO" "Watchtower 已更新，新监控容器：${selected_containers[*]}"
}

check_all_containers_status() {
  docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

uninstall_container() {
  local container_name=$1
  local image_name=$2
  if docker ps -a --format "{{.Names}}" | grep -q "^${container_name}$"; then
    docker stop "$container_name" >/dev/null
    docker rm "$container_name" >/dev/null
    read -p "是否删除镜像 $image_name? (y/n) [默认: n]: " remove_image
    remove_image=${remove_image:-n}
    if [[ "$remove_image" =~ ^[yY]$ ]]; then
      docker rmi "$image_name" >/dev/null 2>&1
    fi
    if [[ "$container_name" == "$CONTAINER_NAME" ]]; then
      read -p "是否清理相关数据卷 $DATA_DIR? (y/n) [默认: n]: " remove_volume
      remove_volume=${remove_volume:-n}
      if [[ "$remove_volume" =~ ^[yY]$ ]]; then
        rm -rf "$DATA_DIR"
      fi
    fi
  fi
}

backup_data() {
  if [[ -d "$DATA_DIR" && -n "$(ls -A "$DATA_DIR")" ]]; then
    if [[ ! -w "$DATA_DIR" ]]; then
      log "ERROR" "数据目录 $DATA_DIR 不可写"
      exit 1
    fi
    local timestamp=$(date +%Y%m%d%H%M%S)
    local backup_file="$BACKUP_DIR/backup_$timestamp.tar.gz"
    mkdir -p "$BACKUP_DIR"
    tar -czf "$backup_file" -C "$DATA_DIR" .
    log "INFO" "数据已备份到: $backup_file"
  fi
}

restore_data() {
  local latest_backup
  latest_backup=$(ls -t "$BACKUP_DIR"/*.tar.gz 2>/dev/null | head -n 1)
  if [[ -z "$latest_backup" ]]; then
    log "WARN" "未找到备份文件"
    return
  fi
  mkdir -p "$DATA_DIR"
  tar -xzf "$latest_backup" -C "$DATA_DIR"
  log "INFO" "数据已从 $latest_backup 恢复"
}

interactive_menu() {
  while true; do
    echo -e "\n请选择操作："
    echo "1. 部署 Sub-Store"
    echo "2. 手动升级现有部署的 Sub-Store"
    echo "3. 部署 Watchtower（自动更新容器）"
    echo "4. 添加容器到 Watchtower 监控列表"
    echo "5. 查看所有容器状态"
    echo "6. 卸载容器（Sub-Store 或 Watchtower）"
    echo "7. 数据备份"
    echo "8. 数据恢复"
    echo "9. 退出"
    read -p "请输入选项编号: " choice
    case $choice in
      1) create_directories; install_substore ;;
      2) manual_upgrade_substore ;;
      3) install_watchtower ;;
      4) add_watchtower_containers ;;
      5) check_all_containers_status ;;
      6)
        echo -e "选择卸载的容器："
        echo "1. Sub-Store"
        echo "2. Watchtower"
        read -p "请输入选项编号: " uninstall_choice
        case $uninstall_choice in
          1) uninstall_container "$CONTAINER_NAME" "$SUB_STORE_IMAGE_NAME:$SUB_STORE_VERSION" ;;
          2) uninstall_container "$WATCHTOWER_CONTAINER_NAME" "$WATCHTOWER_IMAGE_NAME" ;;
        esac
        ;;
      7) backup_data ;;
      8) restore_data ;;
      9) log "INFO" "退出脚本"; exit 0 ;;
      *) log "WARN" "无效输入，请重新选择" ;;
    esac
  done
}

main() {
  create_directories
  detect_system
  check_network
  check_docker_permissions
  install_dependencies
  interactive_menu
}

main "$@"
