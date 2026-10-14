#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
  if command -v bash >/dev/null 2>&1; then exec bash "$0" "$@"; else echo "需要 bash 环境，请先安装 bash"; exit 1; fi
fi
DATA_DIR="$HOME/substore/data"
SCRIPTS_DIR="$HOME/substore/scripts"
BACKUP_DIR="$HOME/substore/backup"
LOG_DIR="$HOME/substore/logs"
LOG_FILE="$LOG_DIR/docker_management.log"
LOG_MAX_SIZE=1048576
CONFIG_FILE="$HOME/substore/config.env"
CONTAINER_NAME="substore"
WATCHTOWER_CONTAINER_NAME="watchtower"
TIMEZONE="${TZ:-Asia/Shanghai}"
DOCKERHUB_IMAGE_NAME="xream/sub-store"
GHCR_IMAGE_NAME="ghcr.io/xream/sub-store"
SUB_STORE_IMAGE_NAME="$GHCR_IMAGE_NAME"
IMAGE_SOURCE="ghcr"
WATCHTOWER_IMAGE_NAME="containrrr/watchtower"
DEFAULT_PORT=3001
BACKEND_API_PORT=3001
SYNC_CRON="55 23 * * *"
GITHUB_REPO="sub-store-org/Sub-Store"
CRON_TAG="#substore-autoupdate"
AUTO_UPDATE=0
AUTOUPDATE_TIME="04:23"
VERSION_POLICY="auto"
NETWORK_MODE="bridge"
HOST_PORT=""
MAGIC_PATH=""
LAST_TAG=""
SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P)
SCRIPT_PATH="${SCRIPT_DIR}/$(basename -- "$0")"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'
OPT_TAG=""
OPT_PORT=""
OPT_PATH=""
OPT_SOURCE=""
OPT_NETWORK=""
OPT_QUIET=0
OPT_YES=0
OPT_TIME=""
POS_ARGS=()
log() {
  local level=$1
  local message=$2
  local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
  case "$level" in
    "INFO") echo -e "${GREEN}[INFO] $timestamp - $message${NC}" >&2 ;;
    "WARN") echo -e "${YELLOW}[WARN] $timestamp - $message${NC}" >&2 ;;
    "ERROR") echo -e "${RED}[ERROR] $timestamp - $message${NC}" >&2 ;;
  esac
  mkdir -p "$LOG_DIR" 2>/dev/null
  echo "[$level] $timestamp - $message" >> "$LOG_FILE" 2>/dev/null
  if [[ -f "$LOG_FILE" && $(wc -c < "$LOG_FILE" 2>/dev/null) -ge $LOG_MAX_SIZE ]]; then
    > "$LOG_FILE"
    log "INFO" "日志文件大小超过 1M，已清空日志。"
  fi
}
is_interactive() {
  [[ -t 0 && $OPT_QUIET != 1 && $OPT_YES != 1 ]]
}
confirm_yes() {
  local prompt_text=$1
  [[ $OPT_YES == 1 ]] && return 0
  if ! is_interactive; then
    return 1
  fi
  local answer=""
  read -p "$prompt_text (y/n) [默认: n]: " answer
  [[ "${answer:-n}" =~ ^[yY]$ ]]
}
save_config() {
  mkdir -p "$(dirname "$CONFIG_FILE")" 2>/dev/null
  local tmp="${CONFIG_FILE}.tmp"
  {
    echo "IMAGE_SOURCE=$IMAGE_SOURCE"
    echo "SUB_STORE_IMAGE_NAME=$SUB_STORE_IMAGE_NAME"
    echo "VERSION_POLICY=$VERSION_POLICY"
    echo "NETWORK_MODE=$NETWORK_MODE"
    echo "HOST_PORT=$HOST_PORT"
    echo "MAGIC_PATH=$MAGIC_PATH"
    echo "AUTO_UPDATE=$AUTO_UPDATE"
    echo "AUTOUPDATE_TIME=$AUTOUPDATE_TIME"
    echo "LAST_TAG=$LAST_TAG"
  } > "$tmp" 2>/dev/null && mv "$tmp" "$CONFIG_FILE" 2>/dev/null
}
load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    . "$CONFIG_FILE" 2>/dev/null
    if [[ "$IMAGE_SOURCE" == "ghcr" ]]; then
      SUB_STORE_IMAGE_NAME="$GHCR_IMAGE_NAME"
    elif [[ "$IMAGE_SOURCE" == "dockerhub" ]]; then
      SUB_STORE_IMAGE_NAME="$DOCKERHUB_IMAGE_NAME"
    fi
  fi
}
get_server_ip() {
  local ip=""
  ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1)
  if [[ -z "$ip" && "$OS" == "macos" ]]; then
    ip=$(ipconfig getifaddr en0 2>/dev/null)
  fi
  if [[ -z "$ip" ]]; then
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  fi
  if [[ -z "$ip" ]]; then
    ip=$(ifconfig 2>/dev/null | awk '/inet / && $2!="127.0.0.1"{print $2; exit}')
  fi
  [[ -z "$ip" ]] && ip="<服务器IP>"
  echo "$ip"
}
rand_string() {
  local len=${1:-20}
  local out=""
  if command -v openssl >/dev/null 2>&1; then
    out=$(openssl rand -base64 64 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c "$len")
  fi
  if [[ -z "$out" ]]; then
    out=$(tr -dc 'a-zA-Z0-9' < /dev/urandom 2>/dev/null | head -c "$len")
  fi
  if [[ -z "$out" ]]; then
    out=$( (date +%s%N 2>/dev/null || date +%s) | md5sum 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c "$len")
  fi
  if [[ -z "$out" ]]; then
    out=$( (date +%s 2>/dev/null; echo $$) | md5 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c "$len")
  fi
  echo "$out"
}
sanitize_path() {
  local raw=$1
  raw="${raw//[^a-zA-Z0-9_.\/-]/}"
  raw="${raw#/}"
  [[ -z "$raw" ]] && raw=$(rand_string 20)
  echo "/$raw"
}
check_port_available() {
  local port=$1
  if command -v ss >/dev/null 2>&1; then
    ss -tuln 2>/dev/null | grep -q ":$port " && return 1
    ss -tuln 2>/dev/null | grep -q ":$port$" && return 1
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tuln 2>/dev/null | grep -q ":$port " && return 1
  elif command -v lsof >/dev/null 2>&1; then
    lsof -i:"$port" >/dev/null 2>&1 && return 1
  else
    return 0
  fi
  return 0
}
find_free_port() {
  local base=${1:-$DEFAULT_PORT}
  local p=$base
  local end=$((base + 200))
  while [[ $p -le $end ]]; do
    if check_port_available "$p"; then
      echo "$p"
      return 0
    fi
    p=$((p + 1))
  done
  echo "$base"
}
valid_port() {
  [[ $1 =~ ^[0-9]+$ && $1 -ge 1 && $1 -le 65535 ]]
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
  mkdir -p "$DATA_DIR" "$SCRIPTS_DIR" "$BACKUP_DIR" "$LOG_DIR" 2>/dev/null
}
detect_system() {
  ARCH=$(uname -m)
  KERNEL=$(uname -s)
  OS="unknown"
  case "$KERNEL" in
    Darwin) OS="macos" ;;
    Linux)
      if [ -f /etc/synoinfo.conf ]; then
        OS="synology"
      elif [ -f /etc/openwrt_release ] || grep -qi "openwrt" /etc/*release 2>/dev/null; then
        OS="openwrt"
      elif [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=${ID:-unknown}
      else
        OS=$(uname -s | tr '[:upper:]' '[:lower:]')
      fi
      ;;
    *) OS=$(uname -s | tr '[:upper:]' '[:lower:]') ;;
  esac
  case "$ARCH" in
    "x86_64"|"amd64") ARCH="amd64" ;;
    "aarch64"|"arm64") ARCH="arm64" ;;
    "armv7l"|"armv6l") ARCH="arm" ;;
    "i386"|"i686") ARCH="386" ;;
    "riscv64") ARCH="riscv64" ;;
  esac
  export ARCH OS KERNEL
  log "INFO" "检测到系统: $OS, 架构: $ARCH"
}
pkg_install() {
  local pkgs=("$@")
  [[ ${#pkgs[@]} -eq 0 ]] && return 0
  local sudo_cmd=""
  if [[ $(id -u) -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
    sudo_cmd="sudo"
  fi
  case "$OS" in
    "ubuntu"|"debian"|"linuxmint"|"kali"|"raspbian"|"pop"|"deepin")
      $sudo_cmd apt-get update -qq && $sudo_cmd apt-get install -y "${pkgs[@]}" ;;
    "centos"|"rhel"|"rocky"|"almalinux"|"amzn"|"ol")
      if command -v dnf >/dev/null 2>&1; then
        $sudo_cmd dnf install -y "${pkgs[@]}"
      else
        $sudo_cmd yum install -y "${pkgs[@]}"
      fi ;;
    "fedora")
      $sudo_cmd dnf install -y "${pkgs[@]}" ;;
    "opensuse"*|"sles"|"sled")
      $sudo_cmd zypper --non-interactive install "${pkgs[@]}" ;;
    "arch"|"manjaro"|"endeavouros")
      $sudo_cmd pacman -Sy --noconfirm --needed "${pkgs[@]}" ;;
    "alpine")
      $sudo_cmd apk add --no-cache "${pkgs[@]}" ;;
    "openwrt")
      opkg update && opkg install "${pkgs[@]}" ;;
    "macos")
      if command -v brew >/dev/null 2>&1; then
        brew install "${pkgs[@]}"
      else
        log "WARN" "未检测到 Homebrew，请手动安装: ${pkgs[*]}"
        return 1
      fi ;;
    "synology")
      log "WARN" "群晖系统请通过套件中心/EasyBootstrapManager 安装: ${pkgs[*]}"
      return 1 ;;
    *)
      log "WARN" "未知系统 $OS，请手动安装: ${pkgs[*]}"
      return 1 ;;
  esac
}
ensure_tool() {
  local cmd=$1
  shift
  if command -v "$cmd" >/dev/null 2>&1; then
    return 0
  fi
  log "INFO" "正在安装依赖: $cmd"
  pkg_install "$@" || log "WARN" "$cmd 自动安装失败，部分功能可能不可用"
}
start_docker_service() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now docker >/dev/null 2>&1 || log "WARN" "systemctl 启动 docker 失败"
  elif command -v rc-service >/dev/null 2>&1; then
    rc-update add docker default >/dev/null 2>&1
    rc-service docker start >/dev/null 2>&1 || log "WARN" "rc-service 启动 docker 失败"
  elif [ -x /etc/init.d/dockerd ]; then
    /etc/init.d/dockerd enable >/dev/null 2>&1
    /etc/init.d/dockerd start >/dev/null 2>&1 || log "WARN" "dockerd 启动失败"
  elif command -v service >/dev/null 2>&1; then
    service docker start >/dev/null 2>&1 || log "WARN" "service 启动 docker 失败"
  fi
}
install_dependencies() {
  ensure_tool curl curl
  if ! command -v ss >/dev/null 2>&1 && ! command -v netstat >/dev/null 2>&1 && ! command -v lsof >/dev/null 2>&1; then
    case "$OS" in
      "ubuntu"|"debian"|"linuxmint"|"kali"|"raspbian"|"pop"|"deepin"|"opensuse"*|"arch"|"manjaro"|"alpine") pkg_install net-tools lsof iproute2 || true ;;
      "centos"|"rhel"|"rocky"|"almalinux"|"amzn"|"ol"|"fedora") pkg_install net-tools lsof iproute || true ;;
      "openwrt")
        opkg update 2>/dev/null
        opkg install lsof 2>/dev/null || log "WARN" "lsof 安装失败"
        opkg install ip-full 2>/dev/null || log "WARN" "ip-full 安装失败"
        ;;
      *) log "WARN" "未能自动安装端口检测工具，部分功能可能不可用" ;;
    esac
  fi
  if ! command -v docker >/dev/null 2>&1; then
    case "$OS" in
      "ubuntu"|"debian"|"linuxmint"|"kali"|"raspbian"|"pop"|"deepin"|"centos"|"rhel"|"rocky"|"almalinux"|"amzn"|"ol"|"fedora")
        ensure_tool ca-certificates ca-certificates
        curl -fsSL https://get.docker.com 2>/dev/null | sh || log "ERROR" "Docker 自动安装失败，请手动安装"
        ;;
      "alpine")
        pkg_install docker && start_docker_service
        ;;
      "opensuse"*|"sles")
        pkg_install docker && start_docker_service
        ;;
      "arch"|"manjaro")
        pkg_install docker && start_docker_service
        ;;
      "openwrt")
        log "WARN" "请手动安装 Docker：opkg update && opkg install docker dockerd luci-app-dockerman"
        ;;
      "synology")
        log "WARN" "请在群晖套件中心安装 Container Manager / Docker"
        ;;
      "macos")
        log "WARN" "请安装 Docker Desktop 或 OrbStack：brew install --cask orbstack"
        ;;
      *)
        log "ERROR" "不支持自动安装 Docker 的系统: $OS"
        ;;
    esac
    start_docker_service
  fi
  ensure_tool jq jq
  if [[ "$OS" == "openwrt" ]] && command -v opkg >/dev/null 2>&1; then
    [ -d /sys/module/veth ] || opkg install kmod-veth >/dev/null 2>&1 || true
    [ -d /sys/module/br_netfilter ] || opkg install kmod-br-netfilter >/dev/null 2>&1 || true
  fi
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
  if [[ $EUID -eq 0 || $(id -u) -eq 0 ]]; then
    return 0
  fi
  if [[ "$OS" == "macos" ]]; then
    return 0
  fi
  if [[ ! -S /var/run/docker.sock ]]; then
    return 0
  fi
  if [[ ! -r /var/run/docker.sock || ! -w /var/run/docker.sock ]]; then
    if ! groups 2>/dev/null | grep -q docker; then
      if command -v usermod >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1; then
        sudo usermod -aG docker "$USER" 2>/dev/null
        log "WARN" "已将用户 $USER 加入 docker 组，请重新登录后再运行本脚本"
      fi
    fi
    if command -v sudo >/dev/null 2>&1; then
      sudo chmod 660 /var/run/docker.sock 2>/dev/null || true
      sudo chown root:docker /var/run/docker.sock 2>/dev/null || true
    fi
  fi
  if ! docker ps >/dev/null 2>&1; then
    log "ERROR" "当前用户无法访问 Docker，请重新登录或使用 sudo / root 运行"
    exit 1
  fi
}
apply_source_choice() {
  local choice=$1
  case "$choice" in
    1|"ghcr")
      SUB_STORE_IMAGE_NAME="$GHCR_IMAGE_NAME"
      IMAGE_SOURCE="ghcr"
      ;;
    2|"dockerhub")
      SUB_STORE_IMAGE_NAME="$DOCKERHUB_IMAGE_NAME"
      IMAGE_SOURCE="dockerhub"
      ;;
    *)
      return 1 ;;
  esac
  return 0
}
select_image_source() {
  local preset=${OPT_SOURCE:-${SUBSTORE_IMAGE_SOURCE:-}}
  if [[ -n "$preset" ]]; then
    if apply_source_choice "$preset"; then
      log "INFO" "镜像源: $SUB_STORE_IMAGE_NAME"
      return 0
    else
      log "WARN" "无效镜像源: $preset，回退为 ghcr"
      apply_source_choice ghcr
      return 0
    fi
  fi
  if ! is_interactive; then
    apply_source_choice ghcr
    log "INFO" "非交互模式，使用默认镜像源: $SUB_STORE_IMAGE_NAME"
    return 0
  fi
  echo "请选择 Sub-Store 镜像拉取源："
  echo "1. GitHub Container Registry (ghcr.io/xream/sub-store) - 推荐，速度快"
  echo "2. Docker Hub (xream/sub-store)"
  while true; do
    read -p "请输入选项编号 [默认: 1]: " source_choice
    source_choice=${source_choice:-1}
    if apply_source_choice "$source_choice"; then
      log "INFO" "已选择镜像源: $SUB_STORE_IMAGE_NAME"
      break
    fi
    log "WARN" "无效的选择，请重新输入"
  done
}
pull_image() {
  local image_name=$1
  local image_tag=$2
  for i in 1 2 3; do
    if docker pull "$image_name:$image_tag"; then
      return 0
    fi
    log "WARN" "第 $i 次拉取失败，5 秒后重试..."
    sleep 5
  done
  log "ERROR" "拉取镜像 $image_name:$image_tag 失败。请确认镜像支持你的架构($ARCH)。"
  return 1
}
prompt_for_port() {
  local prompt_message=$1
  local default_port=$2
  local port=""
  if ! is_interactive; then
    port=$(find_free_port "$default_port")
    echo "$port"
    return 0
  fi
  local auto_default
  auto_default=$(find_free_port "$default_port")
  while true; do
    read -p "$prompt_message [$auto_default]: " port
    port=${port:-$auto_default}
    if valid_port "$port"; then
      if check_port_available "$port"; then
        echo "$port"
        return 0
      else
        log "WARN" "端口 $port 已被占用，请选择其他端口"
      fi
    else
      log "WARN" "无效的端口号，请输入 1 到 65535 之间的数字"
    fi
  done
}
prompt_for_path() {
  local auto_path
  auto_path=$(rand_string 20)
  if ! is_interactive; then
    SUB_STORE_FRONTEND_BACKEND_PATH="/$auto_path"
    return 0
  fi
  local user_input=""
  read -p "请输入 Sub-Store 后端 API 路径（留空自动生成随机路径） [$auto_path]: " user_input
  user_input=${user_input:-$auto_path}
  SUB_STORE_FRONTEND_BACKEND_PATH=$(sanitize_path "$user_input")
}
_fetch_github_releases() {
  local versions=""
  for i in 1 2 3; do
    if command -v jq >/dev/null 2>&1; then
      versions=$(curl -s -m 20 -H "Accept: application/vnd.github+json" "https://api.github.com/repos/${GITHUB_REPO}/releases?per_page=30" 2>/dev/null | jq -r '.[]?.tag_name // empty' 2>/dev/null | sed 's/^v//' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$')
    fi
    if [[ -z "$versions" ]]; then
      versions=$(curl -sL -m 20 "https://github.com/${GITHUB_REPO}/releases" 2>/dev/null | grep -oE "tag/v?[0-9]+\.[0-9]+\.[0-9]+" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+$' | awk '!seen[$0]++')
    fi
    [[ -n "$versions" ]] && break
    sleep 2
  done
  echo "$versions"
}
_fetch_ghcr_tags() {
  local all_tags=""
  command -v jq >/dev/null 2>&1 || return 1
  local token
  token=$(curl -s -m 10 "https://ghcr.io/token?scope=repository:xream/sub-store:pull&service=ghcr.io" 2>/dev/null | jq -r '.token // empty' 2>/dev/null)
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
  command -v jq >/dev/null 2>&1 || return 1
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
resolve_latest_version() {
  local source=${1:-$IMAGE_SOURCE}
  local raw_tags=""
  if [[ "$source" == "ghcr" ]]; then
    raw_tags=$(_fetch_ghcr_tags)
  else
    raw_tags=$(_fetch_dockerhub_tags)
  fi
  local latest=""
  if [[ -n "$raw_tags" ]]; then
    latest=$(echo "$raw_tags" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -rV | head -n1)
  fi
  if [[ -z "$latest" ]]; then
    latest=$(_fetch_github_releases | sort -rV | head -n1)
  fi
  [[ -z "$latest" ]] && latest="latest"
  echo "$latest"
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
    gh_versions=$(_fetch_github_releases | sort -rV | head -n 15)
    stable_versions="$gh_versions"
  fi
  echo "latest"
  [[ -n "$stable_versions" ]] && echo "$stable_versions"
  [[ -n "$meta_versions" ]] && echo "$meta_versions"
}
prompt_for_version() {
  local preset=${OPT_TAG:-${SUBSTORE_VERSION:-}}
  if [[ -n "$preset" ]]; then
    SUB_STORE_VERSION="$preset"
    VERSION_POLICY="$preset"
    log "INFO" "使用指定版本: $SUB_STORE_VERSION"
    return 0
  fi
  if ! is_interactive; then
    SUB_STORE_VERSION=$(resolve_latest_version "$IMAGE_SOURCE")
    VERSION_POLICY="auto"
    log "INFO" "自动解析最新版本: $SUB_STORE_VERSION"
    return 0
  fi
  echo "版本选择方式："
  echo "1. 自动获取最新稳定版（推荐）"
  echo "2. 从版本列表选择"
  echo "3. 手动输入版本号"
  read -p "请输入选项编号 [默认: 1]: " vmode
  case "${vmode:-1}" in
    1)
      log "INFO" "正在解析最新版本..."
      SUB_STORE_VERSION=$(resolve_latest_version "$IMAGE_SOURCE")
      VERSION_POLICY="auto"
      log "INFO" "自动解析最新版本: $SUB_STORE_VERSION"
      ;;
    2)
      log "INFO" "正在获取版本列表（可能需要几秒）..."
      local versions
      mapfile -t versions < <(get_substore_versions "$IMAGE_SOURCE" | awk 'NF && !seen[$0]++')
      local num_versions=${#versions[@]}
      if [[ $num_versions -eq 0 ]]; then
        log "WARN" "无法获取版本列表，回退为 latest"
        SUB_STORE_VERSION="latest"
        VERSION_POLICY="auto"
        return 0
      fi
      for i in "${!versions[@]}"; do
        echo "$((i + 1)). ${versions[$i]}"
      done
      while true; do
        read -p "请输入版本编号 [默认: 1]: " version_choice
        version_choice=${version_choice:-1}
        if [[ $version_choice =~ ^[0-9]+$ && $version_choice -ge 1 && $version_choice -le $num_versions ]]; then
          SUB_STORE_VERSION=${versions[$((version_choice - 1))]}
          if [[ "$SUB_STORE_VERSION" == "latest" ]]; then
            VERSION_POLICY="auto"
          else
            VERSION_POLICY="$SUB_STORE_VERSION"
          fi
          break
        fi
        log "WARN" "无效的选择，请重新输入"
      done
      ;;
    3)
      read -p "请输入版本 tag (如 latest / 2.42.3): " SUB_STORE_VERSION
      SUB_STORE_VERSION=${SUB_STORE_VERSION:-latest}
      if [[ "$SUB_STORE_VERSION" == "latest" ]]; then
        VERSION_POLICY="auto"
      else
        VERSION_POLICY="$SUB_STORE_VERSION"
      fi
      ;;
    *)
      SUB_STORE_VERSION=$(resolve_latest_version "$IMAGE_SOURCE")
      VERSION_POLICY="auto"
      ;;
  esac
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
container_exists() {
  docker ps -a --format "{{.Names}}" 2>/dev/null | grep -q "^${1:-$CONTAINER_NAME}$"
}
container_running() {
  docker ps --format "{{.Names}}" 2>/dev/null | grep -q "^${1:-$CONTAINER_NAME}$"
}
get_container_port() {
  local port
  port=$(docker inspect "$CONTAINER_NAME" 2>/dev/null | jq -r '.[0].HostConfig.PortBindings["3001/tcp"][0].HostPort // empty' 2>/dev/null)
  [[ -z "$port" ]] && port=$(docker inspect "$CONTAINER_NAME" 2>/dev/null | jq -r '.[0].HostConfig.PortBindings["3000/tcp"][0].HostPort // empty' 2>/dev/null)
  echo "$port"
}
get_container_path() {
  local p
  p=$(docker inspect "$CONTAINER_NAME" 2>/dev/null | jq -r '.[0].Config.Env[]? // empty' 2>/dev/null | grep '^SUB_STORE_FRONTEND_BACKEND_PATH=' | head -n1 | cut -d= -f2-)
  [[ -z "$p" ]] && p=$(docker inspect "$CONTAINER_NAME" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep '^SUB_STORE_FRONTEND_BACKEND_PATH=' | head -n1 | cut -d= -f2-)
  echo "$p"
}
get_container_image() {
  docker inspect "$CONTAINER_NAME" --format '{{.Config.Image}}' 2>/dev/null
}
get_container_tag() {
  local img
  img=$(get_container_image)
  echo "${img##*:}"
}
deploy_container() {
  local image_ref=$1
  local port=$2
  local sub_path=$3
  local nmode=$4
  local origin=$5
  local docker_cmd=(
    docker run -d
    --name "$CONTAINER_NAME"
    --restart=always
    -v "${DATA_DIR}:/opt/app/data"
    -v "${SCRIPTS_DIR}:/opt/app/scripts"
    -e TZ="$TIMEZONE"
  )
  if [[ "$nmode" == "host" ]]; then
    docker_cmd+=(--network host)
  else
    docker_cmd+=(-p "${port}:${BACKEND_API_PORT}")
  fi
  local env_args
  mapfile -t env_args < <(build_substore_env_args "$sub_path" "$origin")
  docker_cmd+=("${env_args[@]}")
  docker_cmd+=("$image_ref")
  "${docker_cmd[@]}"
}
docker_bridge_ok() {
  if [[ "$OS" == "macos" ]]; then
    return 0
  fi
  if docker info 2>/dev/null | grep -qi "rootless"; then
    return 0
  fi
  if [ -d /sys/class/net/docker0 ]; then
    return 0
  fi
  if command -v ip >/dev/null 2>&1; then
    ip link show docker0 >/dev/null 2>&1 && return 0
    return 1
  fi
  docker network inspect bridge >/dev/null 2>&1
}
repair_docker_bridge() {
  log "WARN" "检测到 Docker bridge 网桥 (docker0) 缺失，尝试自动修复..."
  if [[ "$OS" == "openwrt" ]] && command -v opkg >/dev/null 2>&1; then
    opkg update >/dev/null 2>&1
    [ -d /sys/module/veth ] || opkg install kmod-veth >/dev/null 2>&1
    [ -d /sys/module/br_netfilter ] || opkg install kmod-br-netfilter >/dev/null 2>&1
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart docker >/dev/null 2>&1
  elif command -v rc-service >/dev/null 2>&1; then
    rc-service docker restart >/dev/null 2>&1
  elif [ -x /etc/init.d/dockerd ]; then
    /etc/init.d/dockerd restart >/dev/null 2>&1
  elif command -v service >/dev/null 2>&1; then
    service docker restart >/dev/null 2>&1
  fi
  local i
  for i in $(seq 1 15); do
    if docker info >/dev/null 2>&1 && docker_bridge_ok; then
      log "INFO" "Docker bridge 网桥已恢复"
      return 0
    fi
    sleep 2
  done
  docker_bridge_ok
}
switch_to_host_confirm() {
  if is_interactive; then
    local answer=""
    read -p "bridge 网络不可用，是否改用 host 模式继续？(y/n) [默认: y]: " answer
    answer=${answer:-y}
    [[ "$answer" =~ ^[yY]$ ]]
    return $?
  fi
  log "WARN" "非交互模式，自动回退为 host 网络模式"
  return 0
}
deploy_with_fallback() {
  local image_ref=$1
  local port=$2
  local sub_path=$3
  local nmode=$4
  local origin=$5
  if deploy_container "$image_ref" "$port" "$sub_path" "$nmode" "$origin"; then
    return 0
  fi
  if [[ "$nmode" == "bridge" ]]; then
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1
    log "WARN" "bridge 模式容器启动失败（OpenWrt 常见原因为 docker0 网桥缺失或 kmod-veth 未加载）"
    if ! docker_bridge_ok; then
      repair_docker_bridge
    fi
    if docker_bridge_ok; then
      log "INFO" "重试 bridge 模式部署..."
      if deploy_container "$image_ref" "$port" "$sub_path" "$nmode" "$origin"; then
        return 0
      fi
      docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1
    fi
    if switch_to_host_confirm; then
      local host_origin
      host_origin=$(build_cors_origin "$BACKEND_API_PORT")
      log "WARN" "已切换为 host 网络模式重新部署"
      NETWORK_MODE="host"
      if deploy_container "$image_ref" "$port" "$sub_path" "host" "$host_origin"; then
        return 0
      fi
      docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1
      log "ERROR" "host 模式部署同样失败"
    fi
  fi
  return 1
}
health_check() {
  local port=$1
  local sub_path=$2
  local nmode=$3
  local check_port=$port
  [[ "$nmode" == "host" ]] && check_port=$BACKEND_API_PORT
  local i
  for i in $(seq 1 15); do
    if ! container_running; then
      sleep 2
      continue
    fi
    if command -v curl >/dev/null 2>&1; then
      local code
      code=$(curl -sk -o /dev/null -w '%{http_code}' -m 5 "http://127.0.0.1:${check_port}${sub_path}/" 2>/dev/null)
      if [[ "$code" != "000" && -n "$code" ]]; then
        return 0
      fi
      code=$(curl -sk -o /dev/null -w '%{http_code}' -m 5 "http://127.0.0.1:${check_port}/" 2>/dev/null)
      if [[ "$code" != "000" && -n "$code" ]]; then
        return 0
      fi
    else
      return 0
    fi
    sleep 2
  done
  container_running && return 0
  return 1
}
install_substore() {
  if container_exists; then
    log "WARN" "检测到已存在的 $CONTAINER_NAME 容器，如需升级请使用 upgrade；如需重装请先卸载"
    if confirm_yes "是否卸载旧容器并重新安装"; then
      docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1
    else
      return 1
    fi
  fi
  select_image_source
  prompt_for_version
  pull_image "$SUB_STORE_IMAGE_NAME" "$SUB_STORE_VERSION" || return 1
  local preset_network=${OPT_NETWORK:-${SUBSTORE_NETWORK:-}}
  if [[ -n "$preset_network" && ( "$preset_network" == "bridge" || "$preset_network" == "host" ) ]]; then
    NETWORK_MODE="$preset_network"
  elif is_interactive; then
    while true; do
      read -p "请选择网络模式 (bridge 或 host) [默认: bridge]: " network_mode
      network_mode=${network_mode:-bridge}
      if [[ "$network_mode" == "bridge" || "$network_mode" == "host" ]]; then
        NETWORK_MODE="$network_mode"
        break
      fi
      log "WARN" "无效输入，请输入 bridge 或 host"
    done
  else
    NETWORK_MODE="bridge"
  fi
  if [[ "$NETWORK_MODE" == "bridge" ]] && ! docker_bridge_ok; then
    repair_docker_bridge || true
  fi
  local preset_path=${OPT_PATH:-${SUBSTORE_PATH:-}}
  if [[ -n "$preset_path" ]]; then
    SUB_STORE_FRONTEND_BACKEND_PATH=$(sanitize_path "$preset_path")
  else
    prompt_for_path
  fi
  MAGIC_PATH="$SUB_STORE_FRONTEND_BACKEND_PATH"
  local preset_port=${OPT_PORT:-${SUBSTORE_PORT:-}}
  if [[ "$NETWORK_MODE" == "host" ]]; then
    HOST_PORT=$BACKEND_API_PORT
  elif [[ -n "$preset_port" ]] && valid_port "$preset_port"; then
    if check_port_available "$preset_port"; then
      HOST_PORT=$preset_port
    else
      log "WARN" "指定端口 $preset_port 被占用，自动选择空闲端口"
      HOST_PORT=$(find_free_port "$DEFAULT_PORT")
    fi
  else
    HOST_PORT=$(prompt_for_port "请输入访问端口 (前端与后端已合并)" "$DEFAULT_PORT")
  fi
  local cors_origin
  cors_origin=$(build_cors_origin "$HOST_PORT")
  if ! deploy_with_fallback "$SUB_STORE_IMAGE_NAME:$SUB_STORE_VERSION" "$HOST_PORT" "$MAGIC_PATH" "$NETWORK_MODE" "$cors_origin"; then
    log "ERROR" "容器启动失败"
    return 1
  fi
  if [[ "$NETWORK_MODE" == "host" ]]; then
    HOST_PORT=$BACKEND_API_PORT
  fi
  if health_check "$HOST_PORT" "$MAGIC_PATH" "$NETWORK_MODE"; then
    log "INFO" "Sub-Store 容器启动成功，健康检查通过"
  else
    log "WARN" "容器已创建但健康检测未通过，请用日志排查: $SCRIPT_PATH logs"
  fi
  LAST_TAG="$SUB_STORE_VERSION"
  save_config
  show_access_info "$HOST_PORT" "$MAGIC_PATH" "$NETWORK_MODE"
  local preset_auto=${SUBSTORE_AUTOUPDATE:-}
  if [[ "$preset_auto" == "1" || "$preset_auto" == "on" ]]; then
    enable_autoupdate
  elif [[ "$preset_auto" == "0" || "$preset_auto" == "off" ]]; then
    disable_autoupdate >/dev/null 2>&1
  elif is_interactive; then
    if confirm_yes "是否开启每日自动升级(默认 n)"; then
      enable_autoupdate
    fi
  fi
}
upgrade_substore() {
  if ! container_exists; then
    log "ERROR" "未检测到已部署的 Sub-Store 容器，请先安装: $SCRIPT_PATH install"
    return 1
  fi
  load_config
  local current_image
  current_image=$(get_container_image)
  local preset_source=${OPT_SOURCE:-}
  if [[ -n "$preset_source" ]]; then
    apply_source_choice "$preset_source" || log "WARN" "无效镜像源 $preset_source，保持原镜像源"
  elif [[ "$current_image" == ghcr.io/* ]]; then
    IMAGE_SOURCE="ghcr"
    SUB_STORE_IMAGE_NAME="$GHCR_IMAGE_NAME"
  elif [[ -n "$current_image" ]]; then
    IMAGE_SOURCE="dockerhub"
    SUB_STORE_IMAGE_NAME="$DOCKERHUB_IMAGE_NAME"
  fi
  local target=${OPT_TAG:-${SUBSTORE_VERSION:-}}
  if [[ -z "$target" ]]; then
    if [[ -n "$VERSION_POLICY" && "$VERSION_POLICY" != "auto" ]]; then
      target="$VERSION_POLICY"
    else
      target=$(resolve_latest_version "$IMAGE_SOURCE")
    fi
  fi
  [[ -z "$target" ]] && target="latest"
  local cur_tag
  cur_tag=$(get_container_tag)
  local img_id_before
  img_id_before=$(docker image inspect "$SUB_STORE_IMAGE_NAME:$target" -f '{{.Id}}' 2>/dev/null)
  pull_image "$SUB_STORE_IMAGE_NAME" "$target" || return 1
  local img_id_after
  img_id_after=$(docker image inspect "$SUB_STORE_IMAGE_NAME:$target" -f '{{.Id}}' 2>/dev/null)
  if [[ "$cur_tag" == "$target" && -n "$img_id_before" && "$img_id_before" == "$img_id_after" ]]; then
    log "INFO" "当前已是最新版本 ($target)，无需升级"
    return 0
  fi
  local prev_image_ref="$current_image"
  local nmode
  nmode=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$CONTAINER_NAME" 2>/dev/null)
  [[ -z "$nmode" ]] && nmode="${NETWORK_MODE:-bridge}"
  local port
  port=$(get_container_port)
  local sub_path
  sub_path=$(get_container_path)
  [[ -z "$sub_path" ]] && sub_path="${MAGIC_PATH}"
  [[ -z "$sub_path" || "$sub_path" == "/" ]] && sub_path="/$(rand_string 20)"
  if [[ "$nmode" == "host" ]]; then
    port=$BACKEND_API_PORT
  else
    [[ -z "$port" ]] && port="${HOST_PORT:-$DEFAULT_PORT}"
  fi
  docker stop "$CONTAINER_NAME" >/dev/null 2>&1
  docker rm "$CONTAINER_NAME" >/dev/null 2>&1
  local cors_origin
  cors_origin=$(build_cors_origin "$port")
  NETWORK_MODE="$nmode"
  if ! deploy_with_fallback "$SUB_STORE_IMAGE_NAME:$target" "$port" "$sub_path" "$nmode" "$cors_origin"; then
    log "ERROR" "新版本容器启动失败，尝试回滚到 $prev_image_ref"
    if [[ -n "$prev_image_ref" ]]; then
      deploy_with_fallback "$prev_image_ref" "$port" "$sub_path" "$nmode" "$cors_origin" && log "INFO" "已回滚到原版本" || log "ERROR" "回滚失败，请手动检查"
    fi
    return 1
  fi
  nmode="$NETWORK_MODE"
  if [[ "$nmode" == "host" ]]; then
    port=$BACKEND_API_PORT
  fi
  if health_check "$port" "$sub_path" "$nmode"; then
    NETWORK_MODE="$nmode"
    HOST_PORT="$port"
    MAGIC_PATH="$sub_path"
    LAST_TAG="$target"
    if [[ -z "$OPT_TAG" && -z "${SUBSTORE_VERSION:-}" ]]; then
      VERSION_POLICY="auto"
    fi
    save_config
    log "INFO" "Sub-Store 已从 ${cur_tag:-未知} 升级到 $target，健康检查通过"
    show_access_info "$port" "$sub_path" "$nmode"
    return 0
  fi
  log "ERROR" "新版本健康检查未通过，自动回滚到 $prev_image_ref"
  docker stop "$CONTAINER_NAME" >/dev/null 2>&1
  docker rm "$CONTAINER_NAME" >/dev/null 2>&1
  if [[ -n "$prev_image_ref" ]]; then
    deploy_with_fallback "$prev_image_ref" "$port" "$sub_path" "$nmode" "$cors_origin" >/dev/null 2>&1
    nmode="$NETWORK_MODE"
    if [[ "$nmode" == "host" ]]; then
      port=$BACKEND_API_PORT
    fi
    if health_check "$port" "$sub_path" "$nmode"; then
      log "INFO" "回滚成功，服务保持原版本运行"
    else
      log "ERROR" "回滚后健康检查仍未通过，请手动排查: docker logs $CONTAINER_NAME"
    fi
  fi
  return 1
}
normalize_time() {
  local t=$1
  if [[ $t =~ ^([01]?[0-9]|2[0-3]):([0-5][0-9])$ ]]; then
    printf '%02d:%02d\n' "$((10#${BASH_REMATCH[1]}))" "$((10#${BASH_REMATCH[2]}))"
    return 0
  fi
  return 1
}
prompt_autoupdate_time() {
  local preset=${OPT_TIME:-${SUBSTORE_AUTOUPDATE_TIME:-}}
  if [[ -n "$preset" ]]; then
    local nt
    if nt=$(normalize_time "$preset"); then
      AUTOUPDATE_TIME=$nt
    else
      log "WARN" "无效时间格式: $preset，使用默认时间 $AUTOUPDATE_TIME"
    fi
    return 0
  fi
  if ! is_interactive; then
    return 0
  fi
  local input="" nt=""
  while true; do
    read -p "请输入每日自动升级时间 (格式 HH:MM，回车默认) [$AUTOUPDATE_TIME]: " input
    [[ -z "$input" ]] && return 0
    if nt=$(normalize_time "$input"); then
      AUTOUPDATE_TIME=$nt
      return 0
    fi
    log "WARN" "无效时间格式，请输入如 04:23 的 24 小时制时间"
  done
}
_cron_schedule() {
  local hh=${AUTOUPDATE_TIME%%:*}
  local mm=${AUTOUPDATE_TIME##*:}
  echo "$((10#$mm)) $((10#$hh)) * * *"
}
_cron_line() {
  echo "$(_cron_schedule) HOME=$HOME $SCRIPT_PATH upgrade --quiet >> $LOG_DIR/autoupdate.log 2>&1 $CRON_TAG"
}
_cron_active() {
  if command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -qF "$CRON_TAG"; then
    return 0
  fi
  if [[ -f /etc/crontabs/root ]] && grep -qF "$CRON_TAG" /etc/crontabs/root 2>/dev/null; then
    return 0
  fi
  if [[ -f /etc/cron.d/substore-autoupdate ]] && grep -qF "$CRON_TAG" /etc/cron.d/substore-autoupdate 2>/dev/null; then
    return 0
  fi
  return 1
}
enable_autoupdate() {
  prompt_autoupdate_time
  local ok=false
  if [[ "$OS" == "openwrt" || -f /etc/openwrt_release ]]; then
    touch /etc/crontabs/root 2>/dev/null
    sed -i "\|$CRON_TAG|d" /etc/crontabs/root 2>/dev/null
    _cron_line >> /etc/crontabs/root
    if [ -x /etc/init.d/cron ]; then
      /etc/init.d/cron restart >/dev/null 2>&1
    elif [ -x /etc/init.d/crond ]; then
      /etc/init.d/crond restart >/dev/null 2>&1
    fi
    ok=true
  elif command -v crontab >/dev/null 2>&1; then
    (crontab -l 2>/dev/null | grep -vF "$CRON_TAG"; _cron_line) | crontab - 2>/dev/null && ok=true
  elif [[ $(id -u) -eq 0 ]]; then
    mkdir -p /etc/cron.d 2>/dev/null
    {
      echo "SHELL=/bin/bash"
      echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
      echo "$(_cron_schedule) root HOME=$HOME $SCRIPT_PATH upgrade --quiet >> $LOG_DIR/autoupdate.log 2>&1 $CRON_TAG"
    } > /etc/cron.d/substore-autoupdate 2>/dev/null && ok=true
  fi
  if [[ "$ok" == true ]] && _cron_active; then
    AUTO_UPDATE=1
    save_config
    log "INFO" "每日自动升级已开启（每天 $AUTOUPDATE_TIME 自动检查并升级，日志: $LOG_DIR/autoupdate.log）"
    return 0
  fi
  save_config
  log "WARN" "无法自动配置定时任务，请手动添加以下计划任务（NAS 可用任务计划）："
  echo "  $(_cron_line)"
  return 1
}
disable_autoupdate() {
  if command -v crontab >/dev/null 2>&1; then
    (crontab -l 2>/dev/null | grep -vF "$CRON_TAG") | crontab - 2>/dev/null
  fi
  if [[ -f /etc/crontabs/root ]]; then
    sed -i "\|$CRON_TAG|d" /etc/crontabs/root 2>/dev/null
    if [ -x /etc/init.d/cron ]; then
      /etc/init.d/cron restart >/dev/null 2>&1
    elif [ -x /etc/init.d/crond ]; then
      /etc/init.d/crond restart >/dev/null 2>&1
    fi
  fi
  rm -f /etc/cron.d/substore-autoupdate 2>/dev/null
  AUTO_UPDATE=0
  save_config
  log "INFO" "每日自动升级已关闭"
}
autoupdate_status() {
  if _cron_active; then
    echo -e "${GREEN}自动升级：已开启（每日 $AUTOUPDATE_TIME）${NC}"
    if command -v crontab >/dev/null 2>&1; then
      crontab -l 2>/dev/null | grep -F "$CRON_TAG" | head -n1
    fi
  else
    echo -e "${YELLOW}自动升级：未开启${NC}"
    echo "  开启命令: $SCRIPT_PATH autoupdate on"
  fi
}
watchtower_api_env() {
  local v minor
  v=$(docker version --format '{{.Server.APIVersion}}' 2>/dev/null)
  if [[ "$v" =~ ^1\.([0-9]+)$ ]]; then
    minor=${BASH_REMATCH[1]}
    if (( minor >= 44 )); then
      echo "1.40"
      return 0
    fi
  fi
  echo ""
}
build_watchtower_cmd() {
  shift_containers=("$@")
  local wt_cmd=(
    docker run -d
    --name "$WATCHTOWER_CONTAINER_NAME"
    --restart=always
    -v /var/run/docker.sock:/var/run/docker.sock
  )
  local api_v
  api_v=$(watchtower_api_env)
  if [[ -n "$api_v" ]]; then
    wt_cmd+=(-e "DOCKER_API_VERSION=$api_v")
  fi
  wt_cmd+=("$WATCHTOWER_IMAGE_NAME:latest" --cleanup --interval 3600 --include-stopped)
  local c
  for c in "${shift_containers[@]}"; do
    wt_cmd+=("$c")
  done
  printf '%s\n' "${wt_cmd[@]}"
}
install_watchtower() {
  local containers
  mapfile -t containers < <(docker ps --format "{{.Names}}" 2>/dev/null)
  if [ ${#containers[@]} -eq 0 ]; then
    log "WARN" "没有找到运行中的容器，无法部署 Watchtower"
    return 1
  fi
  local selected_containers=()
  if is_interactive; then
    echo "请选择要监控的容器（多个用空格分隔，推荐选择 substore）："
    for i in "${!containers[@]}"; do
      echo "$((i + 1)). ${containers[$i]}"
    done
    read -p "请输入容器编号（例如: 1 2 3） [默认: 全部]: " user_input
    if [[ -z "$user_input" ]]; then
      selected_containers=("${containers[@]}")
    else
      local selected_indices=($user_input)
      for index in "${selected_indices[@]}"; do
        if [[ $index =~ ^[0-9]+$ && $index -ge 1 && $index -le ${#containers[@]} ]]; then
          selected_containers+=("${containers[$((index - 1))]}")
        fi
      done
    fi
  else
    if container_running "$CONTAINER_NAME"; then
      selected_containers=("$CONTAINER_NAME")
    else
      selected_containers=("${containers[@]}")
    fi
  fi
  if [ ${#selected_containers[@]} -eq 0 ]; then
    log "WARN" "没有有效的容器选择，取消部署"
    return 1
  fi
  local existing_containers
  mapfile -t existing_containers < <(docker ps -a --filter "name=watchtower" --format "{{.ID}}" 2>/dev/null)
  if [ ${#existing_containers[@]} -gt 0 ]; then
    for container_id in "${existing_containers[@]}"; do
      docker stop "$container_id" >/dev/null 2>&1
      docker rm "$container_id" >/dev/null 2>&1
    done
  fi
  pull_image "$WATCHTOWER_IMAGE_NAME" "latest" || return 1
  local watchtower_args
  mapfile -t watchtower_args < <(build_watchtower_cmd "${selected_containers[@]}")
  if ! "${watchtower_args[@]}"; then
    log "ERROR" "Watchtower 容器启动失败"
    return 1
  fi
  sleep 3
  if ! docker ps --filter "name=$WATCHTOWER_CONTAINER_NAME" --format "{{.Status}}" 2>/dev/null | grep -q "Up"; then
    log "ERROR" "Watchtower 容器未能保持运行状态"
    return 1
  fi
  log "INFO" "Watchtower 部署成功，监控容器：${selected_containers[*]}"
}
add_watchtower_containers() {
  if ! container_exists "$WATCHTOWER_CONTAINER_NAME"; then
    log "ERROR" "Watchtower 未部署，请先部署 Watchtower"
    return 1
  fi
  local current_containers
  mapfile -t current_containers < <(
    docker inspect "$WATCHTOWER_CONTAINER_NAME" 2>/dev/null | \
    jq -r '.[0].Config.Cmd[]?' 2>/dev/null | \
    awk 'skip{skip=0;next} /^--(schedule|interval)$/{skip=1;next} /^--/{next} {print}'
  )
  local all_containers
  mapfile -t all_containers < <(docker ps -a --format "{{.Names}}" 2>/dev/null)
  local available_containers=()
  for container in "${all_containers[@]}"; do
    if ! [[ " ${current_containers[*]} " =~ " $container " ]]; then
      available_containers+=("$container")
    fi
  done
  if [ ${#available_containers[@]} -eq 0 ]; then
    log "WARN" "没有可添加的新容器"
    return 1
  fi
  local selected_containers=()
  if is_interactive; then
    echo "请选择要添加的容器（多个用空格分隔）："
    for i in "${!available_containers[@]}"; do
      echo "$((i + 1)). ${available_containers[$i]}"
    done
    read -p "请输入容器编号（例如: 1 2 3） [默认: 全部]: " user_input
    if [[ -z "$user_input" ]]; then
      selected_containers=("${available_containers[@]}")
    else
      local selected_indices=($user_input)
      for index in "${selected_indices[@]}"; do
        if [[ $index =~ ^[0-9]+$ && $index -ge 1 && $index -le ${#available_containers[@]} ]]; then
          selected_containers+=("${available_containers[$((index - 1))]}")
        fi
      done
    fi
  else
    selected_containers=("${available_containers[@]}")
  fi
  if [ ${#selected_containers[@]} -eq 0 ]; then
    log "WARN" "没有有效的容器选择，取消添加"
    return 1
  fi
  local updated_containers=("${current_containers[@]}" "${selected_containers[@]}")
  docker rm -f "$WATCHTOWER_CONTAINER_NAME" >/dev/null 2>&1
  local watchtower_args
  mapfile -t watchtower_args < <(build_watchtower_cmd "${updated_containers[@]}")
  if ! "${watchtower_args[@]}"; then
    log "ERROR" "Watchtower 更新失败"
    return 1
  fi
  log "INFO" "Watchtower 已更新，新监控容器：${selected_containers[*]}"
}
check_all_containers_status() {
  docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null
}
show_current_access() {
  if ! container_exists; then
    log "WARN" "Sub-Store 容器未部署"
    return 1
  fi
  local nmode port sub_path
  nmode=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$CONTAINER_NAME" 2>/dev/null)
  port=$(get_container_port)
  sub_path=$(get_container_path)
  if [[ "$nmode" == "host" ]]; then
    port=$BACKEND_API_PORT
  fi
  [[ -z "$port" ]] && port="${HOST_PORT:-$DEFAULT_PORT}"
  [[ -z "$sub_path" ]] && sub_path="${MAGIC_PATH:-/<未设置>}"
  show_access_info "$port" "$sub_path" "$nmode"
}
uninstall_container() {
  local container_name=$1
  local image_name=$2
  if container_exists "$container_name"; then
    docker stop "$container_name" >/dev/null 2>&1 && log "INFO" "容器 $container_name 已停止" || log "WARN" "容器 $container_name 停止失败"
    docker rm "$container_name" >/dev/null 2>&1 && log "INFO" "容器 $container_name 已删除" || log "WARN" "容器 $container_name 删除失败"
    if [[ "$container_name" == "$CONTAINER_NAME" ]]; then
      disable_autoupdate >/dev/null 2>&1
    fi
    if confirm_yes "是否删除镜像 $image_name"; then
      docker rmi "$image_name" >/dev/null 2>&1 && log "INFO" "镜像 $image_name 已删除" || log "WARN" "镜像 $image_name 删除失败（可能仍被其他容器使用）"
    fi
    if [[ "$container_name" == "$CONTAINER_NAME" ]]; then
      if confirm_yes "是否清理相关数据卷 $DATA_DIR"; then
        rm -rf "$DATA_DIR" && log "INFO" "数据目录已删除" || log "WARN" "数据目录删除失败"
      fi
    fi
  else
    log "WARN" "容器 $container_name 不存在，无需卸载"
  fi
}
manage_container() {
  while true; do
    echo "========== 容器管理 =========="
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
  if ! container_exists "$cname"; then
    log "WARN" "容器 $cname 不存在"
    return 1
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
_select_backup_root() {
  echo "请选择备份存储位置：" >&2
  echo "1. 主目录 ($HOME)" >&2
  echo "2. /tmp 目录（重启后丢失）" >&2
  echo "3. 手动输入路径" >&2
  local backup_root=""
  if is_interactive; then
    read -p "选项 (1-3，默认 1): " bc
    case "${bc:-1}" in
      2) backup_root="/tmp" ;;
      3)
        read -p "请输入目录路径: " custom_dir
        backup_root="${custom_dir:-$HOME}"
        ;;
      *) backup_root="$HOME" ;;
    esac
  else
    backup_root="$HOME"
  fi
  if ! mkdir -p "$backup_root" 2>/dev/null || ! touch "$backup_root/.wtest" 2>/dev/null; then
    log "ERROR" "目录 $backup_root 不可写"
    return 1
  fi
  rm -f "$backup_root/.wtest"
  log "INFO" "备份目录：$backup_root"
  echo "$backup_root"
}
_scan_backup_files() {
  local scan_dirs=("$HOME" "/tmp" "$BACKUP_DIR" "/mnt" "/data" "/volume1" "/share")
  for d in "${scan_dirs[@]}"; do
    [[ -d "$d" ]] || continue
    find "$d" -maxdepth 3 -name "substore-backup-*.tar.gz" 2>/dev/null
  done | sort -ru
}
backup_data() {
  if [[ ! -d "$DATA_DIR" || -z "$(ls -A "$DATA_DIR" 2>/dev/null)" ]]; then
    log "WARN" "数据目录为空或不存在，跳过备份"
    return 1
  fi
  local avail_kb
  avail_kb=$(df -k "$HOME" 2>/dev/null | awk 'NR==2{print $4}' || echo 999999)
  if [[ "$avail_kb" -lt 51200 ]]; then
    log "WARN" "磁盘可用空间不足（${avail_kb}KB），建议清理后再备份"
    if ! confirm_yes "是否继续备份"; then
      return 1
    fi
  fi
  local backup_root
  backup_root=$(_select_backup_root) || return 1
  backup_root=$(echo "$backup_root" | tail -n1)
  local stamp; stamp=$(date +%Y%m%d_%H%M%S)
  local backup_name="substore-backup-${stamp}"
  local backup_tmp="${backup_root}/${backup_name}"
  local backup_file="${backup_root}/${backup_name}.tar.gz"
  mkdir -p "$backup_tmp"
  log "INFO" "暂停容器以确保数据一致性..."
  local was_running=false
  if container_running; then
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
  cur_image=$(get_container_image)
  [[ -z "$cur_image" ]] && cur_image="未知"
  access_port=$(get_container_port)
  sub_path=$(get_container_path)
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
  local backup_file=${1:-}
  if [[ -n "$backup_file" && ! -f "$backup_file" ]]; then
    log "ERROR" "备份文件不存在：$backup_file"
    return 1
  fi
  if [[ -z "$backup_file" ]]; then
    if ! is_interactive; then
      log "ERROR" "非交互模式请指定备份文件路径: $SCRIPT_PATH restore /path/to/backup.tar.gz"
      return 1
    fi
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
        printf "  %d. %-52s [%s]\n" "$i" "$f" "$sz"
        i=$((i + 1))
      done
      read -p "请输入编号（留空手动输入路径）: " fc
      if [[ -z "$fc" ]]; then
        read -p "请输入备份文件路径: " backup_file
      elif [[ "$fc" =~ ^[0-9]+$ && $fc -ge 1 && $fc -le ${#found_files[@]} ]]; then
        backup_file="${found_files[$((fc-1))]}"
      else
        log "ERROR" "无效选项"
        return 1
      fi
    fi
  fi
  if [[ -z "$backup_file" || ! -f "$backup_file" ]]; then
    log "ERROR" "备份文件不存在：$backup_file"
    return 1
  fi
  log "INFO" "使用备份文件：$backup_file"
  local restore_tmp="/tmp/substore_restore_$$"
  mkdir -p "$restore_tmp"
  log "INFO" "解压备份文件..."
  if ! tar -xzf "$backup_file" -C "$restore_tmp" 2>/dev/null; then
    log "ERROR" "解压失败，文件可能已损坏"
    rm -rf "$restore_tmp"
    return 1
  fi
  local restore_info
  restore_info=$(find "$restore_tmp" -maxdepth 3 -name "backup_info.txt" | head -n1)
  if [[ -z "$restore_info" ]]; then
    log "ERROR" "备份包格式不正确，未找到 backup_info.txt"
    rm -rf "$restore_tmp"
    return 1
  fi
  local restore_base; restore_base=$(dirname "$restore_info")
  echo "---- 备份信息 ----"
  cat "$restore_base/backup_info.txt"
  echo "------------------"
  if ! confirm_yes "确认恢复"; then
    log "INFO" "已取消恢复"
    rm -rf "$restore_tmp"
    return 0
  fi
  if [[ ! -d "$restore_base/data" ]]; then
    log "ERROR" "备份包中无 data 目录"
    rm -rf "$restore_tmp"
    return 1
  fi
  log "INFO" "停止容器..."
  if container_running; then
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
    log "ERROR" "数据恢复失败"
    rm -rf "$restore_tmp"
    return 1
  fi
  rm -rf "$restore_tmp"
  if container_exists; then
    docker start "$CONTAINER_NAME" >/dev/null 2>&1 && log "INFO" "容器已启动" || log "WARN" "请手动启动：docker start $CONTAINER_NAME"
  else
    log "WARN" "容器不存在，请重新安装（数据目录已恢复）: $SCRIPT_PATH install"
  fi
  log "INFO" "恢复完成"
}
list_backups() {
  echo "---- Sub-Store 备份文件列表 ----"
  local found=false
  while IFS= read -r f; do
    local sz; sz=$(du -sh "$f" 2>/dev/null | cut -f1 || echo "?")
    printf "  %-52s [%s]\n" "$f" "$sz"
    found=true
  done < <(_scan_backup_files)
  [[ "$found" == false ]] && log "WARN" "未找到任何备份文件"
  echo "--------------------------------"
}
_get_container_status() {
  local cname=$1
  if container_running "$cname"; then
    echo "运行中"
  elif container_exists "$cname"; then
    echo "已停止"
  else
    echo "未部署"
  fi
}
_autoupdate_menu() {
  while true; do
    echo "========== 自动升级设置 =========="
    autoupdate_status
    echo "----------------------------------"
    echo "1. 开启每日自动升级（可自定义时间）"
    echo "2. 关闭每日自动升级"
    echo "3. 查看状态"
    echo "0. 返回主菜单"
    echo "=================================="
    read -p "请输入选项编号: " au_choice
    case $au_choice in
      1) enable_autoupdate ;;
      2) disable_autoupdate ;;
      3) autoupdate_status ;;
      0) return ;;
      *) log "WARN" "无效输入，请重新选择" ;;
    esac
  done
}
interactive_menu() {
  while true; do
    local ss_status; ss_status=$(_get_container_status "$CONTAINER_NAME")
    local wt_status; wt_status=$(_get_container_status "$WATCHTOWER_CONTAINER_NAME")
    local ss_image="" ss_port="" ss_path="" au_status="关闭"
    if _cron_active; then
      au_status="开启 ($AUTOUPDATE_TIME)"
    fi
    if [[ "$ss_status" != "未部署" ]]; then
      ss_image=$(get_container_image)
      ss_port=$(get_container_port)
      ss_path=$(get_container_path)
    fi
    echo "========== Sub-Store 管理 =========="
    echo "  Sub-Store  : $ss_status${ss_image:+  [$ss_image]}"
    [[ -n "$ss_port" ]] && echo "  访问端口   : $ss_port"
    [[ -n "$ss_path" ]] && echo "  访问路径   : $ss_path"
    echo "  Watchtower : $wt_status"
    echo "  自动升级   : $au_status"
    echo "------------------------------------"
    echo "   1. 部署 Sub-Store（自动获取最新版）"
    echo "   2. 升级 Sub-Store（自动获取最新版）"
    echo "   3. 管理容器（启动/停止/重启/日志）"
    echo "   4. 自动升级设置（开启/关闭/状态）"
    echo "   5. 部署 Watchtower（可选自动更新方式）"
    echo "   6. 添加容器到 Watchtower 监控列表"
    echo "   7. 查看所有容器状态"
    echo "   8. 显示 Sub-Store 访问地址"
    echo "   9. 卸载容器"
    echo "  10. 备份数据"
    echo "  11. 恢复数据"
    echo "  12. 查看备份列表"
    echo "  13. 退出"
    echo "====================================="
    read -p "请输入选项编号: " choice
    case $choice in
      1) install_substore ;;
      2) upgrade_substore ;;
      3) manage_container ;;
      4) _autoupdate_menu ;;
      5) install_watchtower ;;
      6) add_watchtower_containers ;;
      7) check_all_containers_status ;;
      8) show_current_access ;;
      9)
        echo "选择卸载的容器："
        echo "1. Sub-Store"
        echo "2. Watchtower"
        read -p "请输入选项编号: " uninstall_choice
        case $uninstall_choice in
          1)
            local current_image
            current_image=$(get_container_image)
            uninstall_container "$CONTAINER_NAME" "${current_image:-$SUB_STORE_IMAGE_NAME}"
            ;;
          2) uninstall_container "$WATCHTOWER_CONTAINER_NAME" "$WATCHTOWER_IMAGE_NAME" ;;
          *) log "WARN" "无效输入" ;;
        esac
        ;;
      10) backup_data ;;
      11) restore_data ;;
      12) list_backups ;;
      13) log "INFO" "退出脚本"; exit 0 ;;
      *) log "WARN" "无效输入，请重新选择" ;;
    esac
  done
}
usage() {
  echo "Sub-Store 一体化管理脚本（生产自动化版）"
  echo ""
  echo "用法: $SCRIPT_PATH <命令> [参数]"
  echo ""
  echo "命令:"
  echo "  install              部署 Sub-Store（自动解析最新版，默认随机路径/自动端口）"
  echo "  upgrade              升级到最新版（带健康检查与自动回滚）"
  echo "  autoupdate <on|off|status>  每日自动升级开关与状态"
  echo "  watchtower <install|add>    Watchtower 部署与监控追加（可选更新方式）"
  echo "  status               查看容器状态与访问地址"
  echo "  access               显示访问地址"
  echo "  logs [容器名]         跟踪日志（默认 substore）"
  echo "  start|stop|restart [容器名]  容器操作（默认 substore）"
  echo "  backup               备份数据"
  echo "  restore [备份文件]    恢复数据"
  echo "  list-backups         列出备份文件"
  echo "  uninstall <substore|watchtower>  卸载"
  echo "  menu                 进入交互菜单"
  echo "  help                 显示本帮助"
  echo ""
  echo "参数:"
  echo "  --tag <版本>          指定版本（默认自动解析最新稳定版）"
  echo "  --port <端口>         指定访问端口（默认自动选空闲端口）"
  echo "  --path <路径>         指定后端 API 路径（默认随机生成）"
  echo "  --source <ghcr|dockerhub>  指定镜像源"
  echo "  --network <bridge|host>    指定网络模式"
  echo "  --time <HH:MM>       指定每日自动升级时间（默认 04:23）"
  echo "  -q, --quiet          静默模式（供 cron/自动化调用）"
  echo "  -y, --yes            所有确认自动选择是"
  echo ""
  echo "环境变量覆盖（无需修改脚本）:"
  echo "  SUBSTORE_IMAGE_SOURCE, SUBSTORE_VERSION, SUBSTORE_NETWORK,"
  echo "  SUBSTORE_PORT, SUBSTORE_PATH, SUBSTORE_AUTOUPDATE(1/0),"
  echo "  SUBSTORE_AUTOUPDATE_TIME(HH:MM)"
  echo ""
  echo "示例:"
  echo "  $SCRIPT_PATH install                                  # 全自动部署"
  echo "  $SCRIPT_PATH install --source ghcr --port 3001 -y     # 无交互全自动"
  echo "  $SCRIPT_PATH upgrade --quiet                          # cron 自动升级调用"
  echo "  $SCRIPT_PATH autoupdate on --time 04:23               # 开启每日 04:23 自动升级"
  echo "  SUBSTORE_AUTOUPDATE=1 SUBSTORE_AUTOUPDATE_TIME=02:30 $SCRIPT_PATH install -y"
}
parse_flags() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tag) OPT_TAG=$2; shift 2 ;;
      --port) OPT_PORT=$2; shift 2 ;;
      --path) OPT_PATH=$2; shift 2 ;;
      --source) OPT_SOURCE=$2; shift 2 ;;
      --network) OPT_NETWORK=$2; shift 2 ;;
      --time) OPT_TIME=$2; shift 2 ;;
      -q|--quiet) OPT_QUIET=1; shift ;;
      -y|--yes) OPT_YES=1; shift ;;
      *) POS_ARGS+=("$1"); shift ;;
    esac
  done
}
main() {
  create_directories
  detect_system
  load_config
  local command_name=${1:-}
  if [[ -n "$command_name" ]]; then
    shift
  fi
  parse_flags "$@"
  case "$command_name" in
    ""|"menu")
      check_network
      install_dependencies
      check_docker_permissions
      interactive_menu
      ;;
    "install")
      check_network
      install_dependencies
      check_docker_permissions
      install_substore
      ;;
    "upgrade")
      check_docker_permissions
      upgrade_substore
      ;;
    "autoupdate"|"auto-update")
      local au_action=${POS_ARGS[0]:-status}
      case "$au_action" in
        on|enable|1) enable_autoupdate ;;
        off|disable|0) disable_autoupdate ;;
        *) autoupdate_status ;;
      esac
      ;;
    "watchtower")
      local wt_action=${POS_ARGS[0]:-install}
      check_docker_permissions
      case "$wt_action" in
        install|deploy) install_watchtower ;;
        add) add_watchtower_containers ;;
        *) log "ERROR" "未知 Watchtower 操作: $wt_action"; exit 1 ;;
      esac
      ;;
    "status")
      check_all_containers_status
      container_exists && show_current_access
      autoupdate_status
      ;;
    "access")
      show_current_access
      ;;
    "logs")
      local log_target=${POS_ARGS[0]:-$CONTAINER_NAME}
      docker logs -f --tail=50 "$log_target"
      ;;
    "start"|"stop"|"restart")
      local op_target=${POS_ARGS[0]:-$CONTAINER_NAME}
      docker "$command_name" "$op_target" && log "INFO" "$op_target 已执行 $command_name" || log "ERROR" "$op_target $command_name 失败"
      ;;
    "backup")
      backup_data
      ;;
    "restore")
      restore_data "${POS_ARGS[0]:-}"
      ;;
    "list-backups")
      list_backups
      ;;
    "uninstall")
      check_docker_permissions
      case "${POS_ARGS[0]:-substore}" in
        substore)
          local ci
          ci=$(get_container_image)
          uninstall_container "$CONTAINER_NAME" "${ci:-$SUB_STORE_IMAGE_NAME}"
          ;;
        watchtower)
          uninstall_container "$WATCHTOWER_CONTAINER_NAME" "$WATCHTOWER_IMAGE_NAME"
          ;;
        *)
          log "ERROR" "未知卸载目标: ${POS_ARGS[0]}"
          exit 1
          ;;
      esac
      ;;
    "version")
      resolve_latest_version "$IMAGE_SOURCE"
      ;;
    "help"|"-h"|"--help")
      usage
      ;;
    *)
      log "ERROR" "未知命令: $command_name"
      usage
      exit 1
      ;;
  esac
}
main "$@"
