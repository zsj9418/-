#!/bin/bash
DATA_DIR="$HOME/substore/data"
SCRIPTS_DIR="$HOME/substore/scripts"
BACKUP_DIR="$HOME/substore/backup"
LOG_DIR="$HOME/substore/logs"
LOG_FILE="$LOG_DIR/docker_management.log"
LOG_MAX_SIZE=1048576
CONTAINER_NAME="substore"
WATCHTOWER_CONTAINER_NAME="watchtower"
TIMEZONE="Asia/Shanghai"
DOCKERHUB_IMAGE_NAME="xream/sub-store"
GHCR_IMAGE_NAME="ghcr.io/xream/sub-store"
SUB_STORE_IMAGE_NAME="$DOCKERHUB_IMAGE_NAME"
IMAGE_SOURCE="dockerhub"
WATCHTOWER_IMAGE_NAME="containrrr/watchtower"
DEFAULT_SUB_STORE_PATH="/12345678"
DEFAULT_PORT=3001
BACKEND_API_PORT=3001
SYNC_CRON="55 23 * * *"
GITHUB_REPO="sub-store-org/Sub-Store"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'
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
get_server_ip() {
  local ip=""
  ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1)
  if [[ -z "$ip" ]]; then
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  fi
  if [[ -z "$ip" ]]; then
    ip=$(ifconfig 2>/dev/null | awk '/inet / && $2!="127.0.0.1"{print $2; exit}')
  fi
  [[ -z "$ip" ]] && ip="<服务器IP>"
  echo "$ip"
}
build_cors_origin() {
  local port=$1
  local ip
  ip=$(get_server_ip)
  if [[ -z "$ip" || "$ip" == "<服务器IP>" ]]; then
    echo "*"
    return
  fi
  echo "http://${ip}:${port},http://127.0.0.1:${port},http://localhost:${port}"
}
show_access_info() {
  local port=$1
  local sub_path=$2
  local network_mode=$3
  local server_ip
  server_ip=$(get_server_ip)
  echo -e "${CYAN}================ Sub-Store 部署成功 ================${NC}"
  echo -e "${GREEN}▶ 前端 Web UI 访问地址：${NC}"
  echo -e "  ${CYAN}http://${server_ip}:${port}${NC}"
  echo -e "${GREEN}▶ 在弹出的【后端连接配置】框中请输入：${NC}"
  echo -e "  ${YELLOW}http://${server_ip}:${port}${sub_path}${NC}"
  if [[ "$network_mode" == "bridge" ]]; then
    echo -e "${YELLOW}▶ 请确保防火墙/安全组已放行端口 ${port}${NC}"
  fi
  echo -e "${CYAN}====================================================${NC}"
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
  local test_urls=(
    "https://www.baidu.com"
    "https://registry.npmmirror.com"
    "https://ghcr.io"
  )
  for url in "${test_urls[@]}"; do
    local ok=false
    for i in 1 2; do
      if curl -sk -m 5 "$url" >/dev/null 2>&1; then
        ok=true
        break
      fi
      sleep 1
    done
    if [[ "$ok" == true ]]; then
      log "INFO" "网络检测通过: $url"
      return 0
    fi
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
  if ! command -v curl >/dev/null 2>&1; then
    case "$OS" in
      "ubuntu"|"debian") apt-get update && apt-get install -y curl ;;
      "centos"|"rhel"|"rocky"|"almalinux") yum install -y curl ;;
      "openwrt") opkg update; opkg install curl || log "WARN" "curl 安装失败，请手动安装" ;;
      *) log "ERROR" "不支持的操作系统: $OS"; exit 1 ;;
    esac
  fi
  if ! command -v ss >/dev/null 2>&1 && ! command -v netstat >/dev/null 2>&1 && ! command -v lsof >/dev/null 2>&1; then
    case "$OS" in
      "ubuntu"|"debian") apt-get install -y net-tools lsof iproute2 ;;
      "centos"|"rhel"|"rocky"|"almalinux") yum install -y net-tools lsof iproute ;;
      "openwrt")
        opkg update
        opkg install lsof || log "WARN" "lsof 安装失败"
        opkg install net-tools || log "WARN" "net-tools 安装失败"
        opkg install ip-full || log "WARN" "ip-full 安装失败"
        ;;
      *) log "WARN" "未能自动安装端口检测工具，部分功能可能不可用" ;;
    esac
  fi
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
  if ! command -v jq >/dev/null 2>&1; then
    case "$OS" in
      "ubuntu"|"debian") apt-get install -y jq ;;
      "centos"|"rhel"|"rocky"|"almalinux") yum install -y jq ;;
      "openwrt") opkg install jq || opkg install jq-full || log "WARN" "jq 安装失败，请手动安装" ;;
      *) log "ERROR" "不支持的操作系统: $OS"; exit 1 ;;
    esac
  fi
}
select_image_source() {
  echo "请选择 Sub-Store 镜像拉取源："
  echo "1. GitHub Container Registry (ghcr.io/xream/sub-store) - 推荐，速度快"
  echo "2. Docker Hub (xream/sub-store)"
  while true; do
    read -p "请输入选项编号 [默认: 1]: " source_choice
    source_choice=${source_choice:-1}
    case "$source_choice" in
      1)
        SUB_STORE_IMAGE_NAME="$GHCR_IMAGE_NAME"
        IMAGE_SOURCE="ghcr"
        log "INFO" "已选择 GitHub Container Registry 作为镜像源"
        break
        ;;
      2)
        SUB_STORE_IMAGE_NAME="$DOCKERHUB_IMAGE_NAME"
        IMAGE_SOURCE="dockerhub"
        log "INFO" "已选择 Docker Hub 作为镜像源"
        break
        ;;
      *) log "WARN" "无效的选择，请重新输入" ;;
    esac
  done
}
pull_image() {
  local image_name=$1
  local image_tag=$2
  for i in {1..3}; do
    if docker pull "$image_name:$image_tag"; then
      return 0
    fi
    log "WARN" "第 $i 次拉取失败，5 秒后重试..."
    sleep 5
  done
  log "ERROR" "拉取镜像 $image_name:$image_tag 失败。请确认镜像支持你的架构($ARCH)。"
  return 1
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
  local default_path
  default_path=$(basename "$DEFAULT_SUB_STORE_PATH")
  local user_input=""
  read -p "请输入 Sub-Store 后端 API 路径（只需输入路径名，不需加/） [$default_path]: " user_input
  user_input=${user_input:-$default_path}
  SUB_STORE_FRONTEND_BACKEND_PATH="/${user_input//[^a-zA-Z0-9_.\/-]/}"
}
_fetch_github_releases() {
  local versions=""
  for i in {1..3}; do
    versions=$(curl -s -m 20 -H "Accept: application/vnd.github+json" "https://api.github.com/repos/${GITHUB_REPO}/releases?per_page=30" 2>/dev/null | jq -r '.[]?.tag_name // empty' 2>/dev/null | sed 's/^v//' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$')
    [[ -n "$versions" ]] && break
    sleep 2
  done
  echo "$versions"
}
_fetch_ghcr_tags() {
  local all_tags=""
  local token
  token=$(curl -s -m 10 "https://ghcr.io/token?scope=repository:xream/sub-store:pull&service=ghcr.io" | jq -r '.token // empty')
  [[ -z "$token" ]] && return 1
  local url="https://ghcr.io/v2/xream/sub-store/tags/list?n=200"
  local page=0
  while [[ -n "$url" && $page -lt 5 ]]; do
    local resp_headers="/tmp/.ghcr_h_$$"
    local resp_body
    resp_body=$(curl -s -m 20 -D "$resp_headers" -H "Authorization: Bearer $token" "$url" 2>/dev/null)
    local tags
    tags=$(echo "$resp_body" | jq -r '.tags[]? // empty' 2>/dev/null)
    all_tags="${all_tags}${tags}
"
    local link
    link=$(grep -i '^link:' "$resp_headers" 2>/dev/null | sed -n 's/.*<\([^>]*\)>; rel="next".*/\1/p')
    rm -f "$resp_headers"
    if [[ -n "$link" ]]; then
      if [[ "$link" == /* ]]; then
        url="https://ghcr.io${link}"
      else
        url="$link"
      fi
      page=$((page + 1))
    else
      url=""
    fi
  done
  echo "$all_tags"
}
_fetch_dockerhub_tags() {
  local all_tags=""
  local url="https://hub.docker.com/v2/repositories/xream/sub-store/tags/?page_size=100"
  local page=0
  while [[ -n "$url" && "$url" != "null" && $page -lt 5 ]]; do
    local resp
    resp=$(curl -s -m 20 "$url" 2>/dev/null)
    local tags
    tags=$(echo "$resp" | jq -r '.results[]?.name // empty' 2>/dev/null)
    all_tags="${all_tags}${tags}
"
    url=$(echo "$resp" | jq -r '.next // empty' 2>/dev/null)
    page=$((page + 1))
  done
  echo "$all_tags"
}
get_substore_versions() {
  local source=${1:-"ghcr"}
  local raw_tags=""
  if [[ "$source" == "ghcr" ]]; then
    raw_tags=$(_fetch_ghcr_tags)
  else
    raw_tags=$(_fetch_dockerhub_tags)
  fi
  local stable_versions=""
  local meta_versions=""
  if [[ -n "$raw_tags" ]]; then
    stable_versions=$(echo "$raw_tags" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -rV | head -n 15)
    meta_versions=$(echo "$raw_tags" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+-http-meta$' | sort -rV | head -n 5)
  fi
  local gh_versions=""
  if [[ -z "$stable_versions" ]]; then
    log "WARN" "从镜像仓库获取版本失败，尝试从 GitHub Releases 获取..." >&2
    gh_versions=$(_fetch_github_releases | sort -rV | head -n 15)
    stable_versions="$gh_versions"
  else
    gh_versions=$(_fetch_github_releases | sort -rV | head -n 5)
    if [[ -n "$gh_versions" ]]; then
      local latest_gh
      latest_gh=$(echo "$gh_versions" | head -n 1)
      local latest_tag
      latest_tag=$(echo "$stable_versions" | head -n 1)
      if [[ -n "$latest_gh" && -n "$latest_tag" ]]; then
        local newer
        newer=$(printf '%s\n%s\n' "$latest_gh" "$latest_tag" | sort -rV | head -n 1)
        if [[ "$newer" == "$latest_gh" && "$latest_gh" != "$latest_tag" ]]; then
          stable_versions=$(printf '%s\n%s\n' "$gh_versions" "$stable_versions" | awk '!seen[$0]++' | sort -rV | head -n 15)
        fi
      fi
    fi
  fi
  echo "latest"
  [[ -n "$stable_versions" ]] && echo "$stable_versions"
  [[ -n "$meta_versions" ]] && echo "$meta_versions"
}
prompt_for_version() {
  log "INFO" "正在获取版本列表（可能需要几秒）..."
  local versions
  mapfile -t versions < <(get_substore_versions "$IMAGE_SOURCE" | awk 'NF && !seen[$0]++')
  local num_versions=${#versions[@]}
  if [[ $num_versions -eq 0 ]]; then
    log "WARN" "无法获取版本列表"
    read -p "请输入版本 tag (如 latest / 2.42.3): " SUB_STORE_VERSION
    SUB_STORE_VERSION=${SUB_STORE_VERSION:-latest}
    return
  fi
  echo "请选择 Sub-Store 版本（推荐使用 latest 以确保自动更新）："
  for i in "${!versions[@]}"; do
    echo "$((i + 1)). ${versions[$i]}"
  done
  echo "$((num_versions + 1)). 手动输入版本号"
  while true; do
    read -p "请输入版本编号 [默认: 1]: " version_choice
    version_choice=${version_choice:-1}
    if [[ $version_choice =~ ^[0-9]+$ ]] && [ "$version_choice" -ge 1 ] && [ "$version_choice" -le "$num_versions" ]; then
      SUB_STORE_VERSION=${versions[$((version_choice - 1))]}
      break
    elif [[ "$version_choice" == "$((num_versions + 1))" ]]; then
      read -p "请输入版本 tag (如 latest / 2.42.3): " SUB_STORE_VERSION
      SUB_STORE_VERSION=${SUB_STORE_VERSION:-latest}
      break
    else
      log "WARN" "无效的选择，请重新输入"
    fi
  done
}
build_substore_env_args() {
  local path=$1
  local origin=$2
  local extra_args=()
  extra_args+=(-e SUB_STORE_BACKEND_MERGE=true)
  extra_args+=(-e SUB_STORE_BACKEND_API_PORT="$BACKEND_API_PORT")
  extra_args+=(-e SUB_STORE_FRONTEND_BACKEND_PATH="$path")
  extra_args+=(-e SUB_STORE_CORS_ALLOWED_ORIGINS="$origin")
  extra_args+=(-e SUB_STORE_BACKEND_SYNC_CRON="$SYNC_CRON")
  printf '%s\n' "${extra_args[@]}"
}
get_container_port() {
  local port
  port=$(docker inspect "$CONTAINER_NAME" 2>/dev/null | jq -r '.[0].HostConfig.PortBindings["3001/tcp"][0].HostPort // empty')
  [[ -z "$port" ]] && port=$(docker inspect "$CONTAINER_NAME" 2>/dev/null | jq -r '.[0].HostConfig.PortBindings["3000/tcp"][0].HostPort // empty')
  echo "$port"
}
install_substore() {
  select_image_source
  prompt_for_version
  pull_image "$SUB_STORE_IMAGE_NAME" "$SUB_STORE_VERSION" || return 1
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
  )
  if [[ "$NETWORK_MODE" == "host" ]]; then
    HOST_PORT=$BACKEND_API_PORT
    docker_cmd+=(--network host)
  else
    HOST_PORT=$(prompt_for_port "请输入访问端口 (前端与后端已合并)" "$DEFAULT_PORT")
    docker_cmd+=(-p "${HOST_PORT}:${BACKEND_API_PORT}")
  fi
  local cors_origin
  cors_origin=$(build_cors_origin "$HOST_PORT")
  local env_args
  mapfile -t env_args < <(build_substore_env_args "$SUB_STORE_FRONTEND_BACKEND_PATH" "$cors_origin")
  docker_cmd+=("${env_args[@]}")
  docker_cmd+=("$SUB_STORE_IMAGE_NAME:$SUB_STORE_VERSION")
  "${docker_cmd[@]}" || {
    log "ERROR" "容器启动失败"
    return 1
  }
  sleep 3
  log "INFO" "Sub-Store 容器启动成功"
  show_access_info "$HOST_PORT" "$SUB_STORE_FRONTEND_BACKEND_PATH" "$NETWORK_MODE"
}
manual_upgrade_substore() {
  if ! docker ps -a --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
    log "ERROR" "未检测到已部署的 Sub-Store 容器，无法升级。"
    return
  fi
  local current_image
  current_image=$(docker inspect "$CONTAINER_NAME" | jq -r '.[0].Config.Image' 2>/dev/null)
  if [[ "$current_image" == ghcr.io/* ]]; then
    SUB_STORE_IMAGE_NAME="$GHCR_IMAGE_NAME"
    IMAGE_SOURCE="ghcr"
    log "INFO" "检测到当前使用 GitHub Container Registry"
  else
    SUB_STORE_IMAGE_NAME="$DOCKERHUB_IMAGE_NAME"
    IMAGE_SOURCE="dockerhub"
    log "INFO" "检测到当前使用 Docker Hub"
  fi
  echo "是否切换镜像源？当前: $SUB_STORE_IMAGE_NAME"
  read -p "切换镜像源? (y/n) [默认: n]: " switch_source
  switch_source=${switch_source:-n}
  if [[ "$switch_source" =~ ^[yY]$ ]]; then
    select_image_source
  fi
  prompt_for_version
  pull_image "$SUB_STORE_IMAGE_NAME" "$SUB_STORE_VERSION" || return 1
  local old_network_mode
  old_network_mode=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$CONTAINER_NAME")
  local host_port
  host_port=$(get_container_port)
  local old_path
  old_path=$(docker inspect "$CONTAINER_NAME" | jq -r '.[0].Config.Env[]' | grep 'SUB_STORE_FRONTEND_BACKEND_PATH=' | head -n1 | cut -d= -f2-)
  [ -z "$old_path" ] && old_path="$DEFAULT_SUB_STORE_PATH"
  docker stop "$CONTAINER_NAME" >/dev/null 2>&1
  docker rm "$CONTAINER_NAME" >/dev/null 2>&1
  local disp_port disp_mode
  local docker_cmd=(
    docker run -d
    --name "$CONTAINER_NAME"
    --restart=always
    -v "${DATA_DIR}:/opt/app/data"
    -v "${SCRIPTS_DIR}:/opt/app/scripts"
    -e TZ="$TIMEZONE"
  )
  if [[ "$old_network_mode" == "host" ]]; then
    docker_cmd+=(--network host)
    disp_port=$BACKEND_API_PORT
    disp_mode="host"
  else
    [[ -z "$host_port" ]] && host_port=$DEFAULT_PORT
    docker_cmd+=(-p "${host_port}:${BACKEND_API_PORT}")
    disp_port=$host_port
    disp_mode="bridge"
  fi
  local cors_origin
  cors_origin=$(build_cors_origin "$disp_port")
  local env_args
  mapfile -t env_args < <(build_substore_env_args "$old_path" "$cors_origin")
  docker_cmd+=("${env_args[@]}")
  docker_cmd+=("$SUB_STORE_IMAGE_NAME:$SUB_STORE_VERSION")
  "${docker_cmd[@]}" || {
    log "ERROR" "升级后容器启动失败"
    return 1
  }
  sleep 3
  log "INFO" "Sub-Store 已升级到 $SUB_STORE_VERSION 并自动恢复原有配置"
  show_access_info "$disp_port" "$old_path" "$disp_mode"
}
show_current_access() {
  if ! docker ps -a --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
    log "WARN" "Sub-Store 容器未部署"
    return
  fi
  local nmode port sub_path
  nmode=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$CONTAINER_NAME" 2>/dev/null)
  port=$(get_container_port)
  sub_path=$(docker inspect "$CONTAINER_NAME" 2>/dev/null | jq -r '.[0].Config.Env[]' | grep 'SUB_STORE_FRONTEND_BACKEND_PATH=' | head -n1 | cut -d= -f2-)
  if [[ "$nmode" == "host" ]]; then
    port=$BACKEND_API_PORT
  fi
  [[ -z "$sub_path" ]] && sub_path="$DEFAULT_SUB_STORE_PATH"
  show_access_info "$port" "$sub_path" "$nmode"
}
manage_container() {
  while true; do
    echo "========== 容器管理 =========="
    echo "请选择要管理的容器："
    echo "1. Sub-Store"
    echo "2. Watchtower"
    echo "0. 返回主菜单"
    echo "=============================="
    read -p "请输入选项编号: " container_choice
    case $container_choice in
      1) _manage_single_container "$CONTAINER_NAME" ;;
      2) _manage_single_container "$WATCHTOWER_CONTAINER_NAME" ;;
      0) return ;;
      *) log "WARN" "无效输入，请重新选择" ;;
    esac
  done
}
_manage_single_container() {
  local cname=$1
  if ! docker ps -a --format "{{.Names}}" | grep -q "^${cname}$"; then
    log "WARN" "容器 $cname 不存在"
    return
  fi
  while true; do
    local status
    status=$(docker inspect -f '{{.State.Status}}' "$cname" 2>/dev/null || echo "未知")
    echo "======== $cname [$status] ========"
    echo "1. 启动"
    echo "2. 停止"
    echo "3. 重启"
    echo "4. 查看实时日志 (Ctrl+C 退出)"
    echo "0. 返回"
    echo "=================================="
    read -p "请输入选项编号: " op
    case $op in
      1) docker start "$cname" && log "INFO" "$cname 已启动" || log "ERROR" "$cname 启动失败" ;;
      2) docker stop "$cname" && log "INFO" "$cname 已停止" || log "ERROR" "$cname 停止失败" ;;
      3) docker restart "$cname" && log "INFO" "$cname 已重启" || log "ERROR" "$cname 重启失败" ;;
      4) docker logs -f --tail=50 "$cname" || true ;;
      0) return ;;
      *) log "WARN" "无效输入" ;;
    esac
  done
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
  pull_image "$WATCHTOWER_IMAGE_NAME" "latest" || return 1
  local watchtower_cmd=(
    docker run -d
    --name "$WATCHTOWER_CONTAINER_NAME"
    --restart=always
    -e DOCKER_API_VERSION=1.40
    -v /var/run/docker.sock:/var/run/docker.sock
    "$WATCHTOWER_IMAGE_NAME:latest"
    --cleanup
    --interval 3600
    --include-stopped
  )
  for container in "${selected_containers[@]}"; do
    watchtower_cmd+=("$container")
  done
  "${watchtower_cmd[@]}" || {
    log "ERROR" "Watchtower 容器启动失败"
    return 1
  }
  sleep 3
  if ! docker ps --filter "name=$WATCHTOWER_CONTAINER_NAME" --format "{{.Status}}" | grep -q "Up"; then
    log "ERROR" "Watchtower 容器未能保持运行状态"
    return 1
  fi
  log "INFO" "Watchtower 部署成功，监控容器：${selected_containers[*]}"
}
add_watchtower_containers() {
  if ! docker ps -a --format "{{.Names}}" | grep -q "^${WATCHTOWER_CONTAINER_NAME}$"; then
    log "ERROR" "Watchtower 未部署，请先选择菜单选项部署 Watchtower"
    return
  fi
  local current_containers
  mapfile -t current_containers < <(
    docker inspect "$WATCHTOWER_CONTAINER_NAME" | \
    jq -r '.[0].Config.Cmd[]' | \
    awk 'skip{skip=0;next} /^--(schedule|interval)$/{skip=1;next} /^--/{next} {print}'
  )
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
    -e DOCKER_API_VERSION=1.40
    -v /var/run/docker.sock:/var/run/docker.sock
    "$WATCHTOWER_IMAGE_NAME"
    --cleanup
    --interval 3600
    --include-stopped
  )
  for container in "${updated_containers[@]}"; do
    watchtower_cmd+=("$container")
  done
  "${watchtower_cmd[@]}" || {
    log "ERROR" "Watchtower 更新失败"
    return 1
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
    docker stop "$container_name" >/dev/null && log "INFO" "容器 $container_name 已停止" || log "WARN" "容器 $container_name 停止失败"
    docker rm "$container_name" >/dev/null && log "INFO" "容器 $container_name 已删除" || log "WARN" "容器 $container_name 删除失败"
    read -p "是否删除镜像 $image_name? (y/n) [默认: n]: " remove_image
    remove_image=${remove_image:-n}
    if [[ "$remove_image" =~ ^[yY]$ ]]; then
      docker rmi "$image_name" >/dev/null 2>&1 && log "INFO" "镜像 $image_name 已删除" || log "WARN" "镜像 $image_name 删除失败（可能仍被其他容器使用）"
    fi
    if [[ "$container_name" == "$CONTAINER_NAME" ]]; then
      read -p "是否清理相关数据卷 $DATA_DIR? (y/n) [默认: n]: " remove_volume
      remove_volume=${remove_volume:-n}
      if [[ "$remove_volume" =~ ^[yY]$ ]]; then
        rm -rf "$DATA_DIR" && log "INFO" "数据目录已删除" || log "WARN" "数据目录删除失败"
      fi
    fi
  else
    log "WARN" "容器 $container_name 不存在，无需卸载"
  fi
}
_select_backup_root() {
  echo "请选择备份存储位置：" >&2
  echo "1. 主目录 ($HOME)" >&2
  echo "2. /tmp 目录（重启后丢失）" >&2
  echo "3. 手动输入路径" >&2
  read -p "选项 (1-3，默认 1): " bc
  local backup_root=""
  case "${bc:-1}" in
    2) backup_root="/tmp" ;;
    3)
      read -p "请输入目录路径: " custom_dir
      backup_root="${custom_dir:-$HOME}"
      ;;
    *) backup_root="$HOME" ;;
  esac
  if ! mkdir -p "$backup_root" 2>/dev/null || ! touch "$backup_root/.wtest" 2>/dev/null; then
    log "ERROR" "目录 $backup_root 不可写"
    return 1
  fi
  rm -f "$backup_root/.wtest"
  log "INFO" "备份目录：$backup_root"
  echo "$backup_root"
}
_scan_backup_files() {
  local scan_dirs=("$HOME" "/tmp" "$BACKUP_DIR" "/mnt" "/data")
  for d in "${scan_dirs[@]}"; do
    [[ -d "$d" ]] || continue
    find "$d" -maxdepth 3 -name "substore-backup-*.tar.gz" 2>/dev/null
  done | sort -ru
}
backup_data() {
  if [[ ! -d "$DATA_DIR" || -z "$(ls -A "$DATA_DIR" 2>/dev/null)" ]]; then
    log "WARN" "数据目录为空或不存在，跳过备份"
    return
  fi
  if [[ ! -w "$DATA_DIR" ]]; then
    log "ERROR" "数据目录 $DATA_DIR 不可写"
    return 1
  fi
  local avail_kb
  avail_kb=$(df -k "$HOME" 2>/dev/null | awk 'NR==2{print $4}' || echo 999999)
  if [[ "$avail_kb" -lt 51200 ]]; then
    log "WARN" "磁盘可用空间不足（${avail_kb}KB），建议清理后再备份"
    read -p "是否继续？(y/n，默认 n): " sc
    [[ ! "${sc:-n}" =~ ^[yY]$ ]] && return
  fi
  local backup_root
  backup_root=$(_select_backup_root) || return 1
  local stamp; stamp=$(date +%Y%m%d_%H%M%S)
  local backup_name="substore-backup-${stamp}"
  local backup_tmp="${backup_root}/${backup_name}"
  local backup_file="${backup_root}/${backup_name}.tar.gz"
  mkdir -p "$backup_tmp"
  log "INFO" "暂停容器以确保数据一致性..."
  local was_running=false
  if docker ps --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
    was_running=true
    docker stop "$CONTAINER_NAME" >/dev/null 2>&1
  fi
  log "INFO" "复制数据目录..."
  mkdir -p "$backup_tmp/data"
  if ! cp -a "$DATA_DIR/." "$backup_tmp/data/" 2>/dev/null; then
    log "ERROR" "数据复制失败"
    [[ "$was_running" == true ]] && docker start "$CONTAINER_NAME" >/dev/null 2>&1
    rm -rf "$backup_tmp"
    return 1
  fi
  local cur_image="" access_port="" sub_path=""
  cur_image=$(docker inspect "$CONTAINER_NAME" --format '{{.Config.Image}}' 2>/dev/null || echo "未知")
  access_port=$(get_container_port)
  sub_path=$(docker inspect "$CONTAINER_NAME" 2>/dev/null | jq -r '.[0].Config.Env[]' 2>/dev/null | grep 'SUB_STORE_FRONTEND_BACKEND_PATH=' | head -n1 | cut -d= -f2- || echo "")
  cat > "$backup_tmp/backup_info.txt" << EOF
备份时间：$(date '+%Y-%m-%d %H:%M:%S')
主机名：$(hostname)
系统：${OS} / ${ARCH}
镜像版本：${cur_image}
访问端口：${access_port}
访问路径：${sub_path}
数据目录：${DATA_DIR}
EOF
  if [[ "$was_running" == true ]]; then
    log "INFO" "重新启动容器..."
    docker start "$CONTAINER_NAME" >/dev/null 2>&1 && log "INFO" "容器已恢复运行" || log "WARN" "请手动启动：docker start $CONTAINER_NAME"
  fi
  log "INFO" "打包压缩中..."
  if tar -czf "$backup_file" -C "$backup_root" "$backup_name" 2>/dev/null; then
    rm -rf "$backup_tmp"
    local size; size=$(du -sh "$backup_file" 2>/dev/null | cut -f1 || echo "未知")
    log "INFO" "备份完成：$backup_file（$size）"
    echo "  备份文件：$backup_file"
    echo "  文件大小：$size"
    echo "  请将备份文件复制到安全位置（U盘/NAS/云盘）"
  else
    log "ERROR" "打包失败，临时目录保留在：$backup_tmp"
    return 1
  fi
}
restore_data() {
  echo "请选择备份文件来源："
  echo "1. 自动扫描列出备份文件"
  echo "2. 手动输入备份文件路径"
  read -p "选项 (1-2，默认 1): " sc
  sc=${sc:-1}
  local backup_file=""
  case "$sc" in
    2) read -p "请输入备份文件路径: " backup_file ;;
    *)
      log "INFO" "正在扫描备份文件..."
      local found_files=()
      while IFS= read -r f; do
        found_files+=("$f")
      done < <(_scan_backup_files)
      if [[ ${#found_files[@]} -eq 0 ]]; then
        log "WARN" "未找到备份文件"
        read -p "请手动输入备份文件路径: " backup_file
      else
        local i=1
        for f in "${found_files[@]}"; do
          local sz; sz=$(du -sh "$f" 2>/dev/null | cut -f1 || echo "?")
          local ts; ts=$(echo "$f" | grep -oE '[0-9]{8}_[0-9]{6}' | sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)_\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3 \4:\5:\6/' || echo "")
          printf "  %d. %-52s [%s] %s\n" "$i" "$f" "$sz" "$ts"
          i=$((i + 1))
        done
        read -p "请输入编号（留空手动输入路径）: " fc
        if [[ -z "$fc" ]]; then
          read -p "请输入备份文件路径: " backup_file
        elif [[ "$fc" =~ ^[0-9]+$ ]] && [[ "$fc" -ge 1 && "$fc" -le ${#found_files[@]} ]]; then
          backup_file="${found_files[$((fc-1))]}"
        else
          log "ERROR" "无效选项"; return 1
        fi
      fi
      ;;
  esac
  if [[ -z "$backup_file" || ! -f "$backup_file" ]]; then
    log "ERROR" "备份文件不存在：$backup_file"; return 1
  fi
  log "INFO" "使用备份文件：$backup_file"
  local restore_tmp="/tmp/substore_restore_$$"
  mkdir -p "$restore_tmp"
  log "INFO" "解压备份文件..."
  if ! tar -xzf "$backup_file" -C "$restore_tmp" 2>/dev/null; then
    log "ERROR" "解压失败，文件可能已损坏"; rm -rf "$restore_tmp"; return 1
  fi
  local restore_info
  restore_info=$(find "$restore_tmp" -maxdepth 3 -name "backup_info.txt" | head -n1)
  if [[ -z "$restore_info" ]]; then
    log "ERROR" "备份包格式不正确，未找到 backup_info.txt"
    rm -rf "$restore_tmp"; return 1
  fi
  local restore_base; restore_base=$(dirname "$restore_info")
  echo "---- 备份信息 ----"
  cat "$restore_base/backup_info.txt"
  echo "------------------"
  read -p "确认恢复？(y/n，默认 n): " confirm
  [[ ! "${confirm:-n}" =~ ^[yY]$ ]] && { log "INFO" "已取消恢复"; rm -rf "$restore_tmp"; return 0; }
  if [[ ! -d "$restore_base/data" ]]; then
    log "ERROR" "备份包中无 data 目录"; rm -rf "$restore_tmp"; return 1
  fi
  log "INFO" "停止容器..."
  if docker ps --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
    docker stop "$CONTAINER_NAME" >/dev/null 2>&1
  fi
  if [[ -d "$DATA_DIR" ]]; then
    local bak_old="${DATA_DIR}_old_$(date +%Y%m%d_%H%M%S)"
    mv "$DATA_DIR" "$bak_old" 2>/dev/null && log "INFO" "旧数据目录已保留：$bak_old" || { log "ERROR" "无法移动旧数据目录"; rm -rf "$restore_tmp"; return 1; }
  fi
  mkdir -p "$DATA_DIR"
  if cp -a "$restore_base/data/." "$DATA_DIR/" 2>/dev/null; then
    local fc; fc=$(find "$DATA_DIR" -type f 2>/dev/null | wc -l || echo 0)
    log "INFO" "数据恢复完成（$fc 个文件）"
  else
    log "ERROR" "数据恢复失败"; rm -rf "$restore_tmp"; return 1
  fi
  rm -rf "$restore_tmp"
  if docker ps -a --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
    docker start "$CONTAINER_NAME" >/dev/null 2>&1 && log "INFO" "容器已启动" || log "WARN" "请手动启动：docker start $CONTAINER_NAME"
  else
    log "WARN" "容器不存在，请通过菜单重新部署（数据目录已恢复）"
  fi
  log "INFO" "恢复完成"
}
list_backups() {
  echo "---- Sub-Store 备份文件列表 ----"
  local found=false
  while IFS= read -r f; do
    local sz; sz=$(du -sh "$f" 2>/dev/null | cut -f1 || echo "?")
    local ts; ts=$(echo "$f" | grep -oE '[0-9]{8}_[0-9]{6}' | sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)_\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3 \4:\5:\6/' || echo "")
    printf "  %-52s [%s] %s\n" "$f" "$sz" "$ts"
    found=true
  done < <(_scan_backup_files)
  [[ "$found" == false ]] && log "WARN" "未找到任何备份文件"
  echo "--------------------------------"
}
_get_container_status() {
  local cname=$1
  if docker ps --format "{{.Names}}" | grep -q "^${cname}$"; then
    echo "运行中"
  elif docker ps -a --format "{{.Names}}" | grep -q "^${cname}$"; then
    echo "已停止"
  else
    echo "未部署"
  fi
}
interactive_menu() {
  while true; do
    local ss_status; ss_status=$(_get_container_status "$CONTAINER_NAME")
    local wt_status; wt_status=$(_get_container_status "$WATCHTOWER_CONTAINER_NAME")
    local ss_image="" ss_port="" ss_path=""
    if [[ "$ss_status" != "未部署" ]]; then
      ss_image=$(docker inspect "$CONTAINER_NAME" --format '{{.Config.Image}}' 2>/dev/null || echo "")
      ss_port=$(get_container_port)
      ss_path=$(docker inspect "$CONTAINER_NAME" 2>/dev/null | jq -r '.[0].Config.Env[]' 2>/dev/null | grep 'SUB_STORE_FRONTEND_BACKEND_PATH=' | head -n1 | cut -d= -f2- || echo "")
    fi
    echo "========== Sub-Store 管理 =========="
    echo "  Sub-Store  : $ss_status${ss_image:+  [$ss_image]}"
    [[ -n "$ss_port" ]] && echo "  访问端口   : $ss_port"
    [[ -n "$ss_path" ]] && echo "  访问路径   : $ss_path"
    echo "  Watchtower : $wt_status"
    echo "------------------------------------"
    echo "   1. 部署 Sub-Store"
    echo "   2. 升级 Sub-Store"
    echo "   3. 管理容器（启动/停止/重启/日志）"
    echo "   4. 部署 Watchtower"
    echo "   5. 添加容器到 Watchtower 监控列表"
    echo "   6. 查看所有容器状态"
    echo "   7. 显示 Sub-Store 访问地址"
    echo "   8. 卸载容器"
    echo "   9. 备份数据"
    echo "  10. 恢复数据"
    echo "  11. 查看备份列表"
    echo "  12. 退出"
    echo "====================================="
    read -p "请输入选项编号: " choice
    case $choice in
      1) create_directories; install_substore ;;
      2) manual_upgrade_substore ;;
      3) manage_container ;;
      4) install_watchtower ;;
      5) add_watchtower_containers ;;
      6) check_all_containers_status ;;
      7) show_current_access ;;
      8)
        echo "选择卸载的容器："
        echo "1. Sub-Store"
        echo "2. Watchtower"
        read -p "请输入选项编号: " uninstall_choice
        case $uninstall_choice in
          1)
            local current_image
            current_image=$(docker inspect "$CONTAINER_NAME" 2>/dev/null | jq -r '.[0].Config.Image // empty')
            uninstall_container "$CONTAINER_NAME" "${current_image:-$GHCR_IMAGE_NAME}"
            ;;
          2) uninstall_container "$WATCHTOWER_CONTAINER_NAME" "$WATCHTOWER_IMAGE_NAME" ;;
          *) log "WARN" "无效输入" ;;
        esac
        ;;
      9) backup_data ;;
      10) restore_data ;;
      11) list_backups ;;
      12) log "INFO" "退出脚本"; exit 0 ;;
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
