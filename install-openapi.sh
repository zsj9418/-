#!/bin/bash
set -uo pipefail
trap 'echo -e "\n\e[31m操作被用户中断。\e[0m"; exit 1' INT
OS=""
PACKAGE_MANAGER=""
ARCH=""
PLATFORM=""
PORT=""
NETWORK_MODE=""
LOG_FILE=""
SELECTED_IMAGE=""
DEFAULT_TZ="Asia/Shanghai"
ONE_API_IMAGE_BASE="ghcr.io/songquanpeng/one-api"
NEW_API_IMAGE_BASE="calciumion/new-api"
NEW_API_HORIZON_IMAGE_BASE="calciumion/new-api-horizon"
FREELLMAPI_IMAGE_BASE="ghcr.io/tashfeenahmed/freellmapi"
OMNIROUTE_IMAGE_BASE="diegosouzapw/omniroute"
FREELLMAPI_COMPOSE_DIR="$HOME/freellmapi"
COMPOSE_FALLBACK_VERSION="v2.39.1"
GHCR_PROXIES=("ghcr.chenby.cn" "ghcr.registry.cyou" "ghcr.1ms.run" "ghcr.nju.edu.cn" "ghcr.m.daocloud.io")
DOCKERHUB_PROXIES=("docker.1ms.run" "docker.chenby.cn" "docker.m.daocloud.io" "docker.nju.edu.cn" "hub.rat.dev")
DOCKERHUB_MIRRORS=("https://docker.1ms.run" "https://docker.chenby.cn" "https://docker.m.daocloud.io" "https://docker.nju.edu.cn" "https://hub.rat.dev")
BEST_GHCR_PROXY=""
BEST_DOCKERHUB_PROXY=""
GHCR_DIRECT_OK=false
DOCKERHUB_DIRECT_OK=false
NET_TIMEOUT=4
RUNTIME_NM=""
RUNTIME_PT=""
RUNTIME_BINDIP=""
RUNTIME_MOUNTS=()
RUNTIME_ENVS=()
RUNTIME_CMD=()
function green()  { echo -e "\e[32m$1\e[0m"; }
function red()    { echo -e "\e[31m$1\e[0m"; }
function yellow() { echo -e "\e[33m$1\e[0m"; }
function cyan()   { echo -e "\e[36m$1\e[0m"; }
function press_any_key() { echo ""; read -rn 1 -s -p "按任意键继续..." </dev/tty; echo ""; }
function _http_get() {
  local url="$1" timeout="${2:-$NET_TIMEOUT}"
  if command -v curl &>/dev/null; then curl -sSL --connect-timeout "$timeout" --max-time "$timeout" "$url" 2>/dev/null
  elif command -v wget &>/dev/null; then wget -qO- --timeout="$timeout" "$url" 2>/dev/null; fi
}
function _http_code() {
  local url="$1" timeout="${2:-$NET_TIMEOUT}"
  if command -v curl &>/dev/null; then curl -sSL --connect-timeout "$timeout" --max-time "$timeout" -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000"
  else wget -qO /dev/null --timeout="$timeout" --server-response "$url" 2>&1 | awk '/^  HTTP/{print $2}' | tail -1 || echo "000"; fi
}
function _test_registry() {
  local host="$1" timeout="${2:-$NET_TIMEOUT}"
  local code; code=$(_http_code "https://${host}/v2/" "$timeout")
  [[ "$code" =~ ^(200|401|403|301|302)$ ]] && return 0
  return 1
}
function _test_registry_ms() {
  local host="$1" timeout="${2:-$NET_TIMEOUT}"
  local start end ms
  start=$(date +%s%3N 2>/dev/null || echo $(($(date +%s)*1000)))
  if _test_registry "$host" "$timeout"; then
    end=$(date +%s%3N 2>/dev/null || echo $(($(date +%s)*1000)))
    ms=$((end - start))
    echo "$ms"
    return 0
  fi
  echo "9999"
  return 1
}
function _detect_network() {
  cyan "检测网络连通性..."
  yellow "  测试 ghcr.io..."
  if _test_registry "ghcr.io" 3; then
    GHCR_DIRECT_OK=true
    green "    ✓ ghcr.io 直连可用"
  else
    yellow "    ✗ ghcr.io 不可达，测速选择最优代理..."
    local best_ms=9999 best_host=""
    for proxy in "${GHCR_PROXIES[@]}"; do
      printf "      测试 %-25s" "$proxy"
      local ms; ms=$(_test_registry_ms "$proxy" 3)
      if [[ "$ms" -lt 9000 ]]; then
        printf "\e[32m%dms\e[0m\n" "$ms"
        [[ "$ms" -lt "$best_ms" ]] && { best_ms="$ms"; best_host="$proxy"; }
      else
        printf "\e[31m超时\e[0m\n"
      fi
    done
    if [[ -n "$best_host" ]]; then
      BEST_GHCR_PROXY="$best_host"
      green "    ✓ 最优代理: $best_host (${best_ms}ms)"
    else
      red "    ✗ 所有代理不可用"
    fi
  fi
  yellow "  测试 Docker Hub..."
  if _test_registry "registry-1.docker.io" 3; then
    DOCKERHUB_DIRECT_OK=true
    green "    ✓ Docker Hub 直连可用"
  else
    yellow "    ✗ Docker Hub 不可达，测速选择最优代理..."
    local best_ms=9999 best_host=""
    for proxy in "${DOCKERHUB_PROXIES[@]}"; do
      printf "      测试 %-25s" "$proxy"
      local ms; ms=$(_test_registry_ms "$proxy" 3)
      if [[ "$ms" -lt 9000 ]]; then
        printf "\e[32m%dms\e[0m\n" "$ms"
        [[ "$ms" -lt "$best_ms" ]] && { best_ms="$ms"; best_host="$proxy"; }
      else
        printf "\e[31m超时\e[0m\n"
      fi
    done
    if [[ -n "$best_host" ]]; then
      BEST_DOCKERHUB_PROXY="$best_host"
      green "    ✓ 最优代理: $best_host (${best_ms}ms)"
    else
      red "    ✗ 所有代理不可用"
    fi
  fi
  echo ""
}
function _is_ghcr_image() { [[ "${1%%/*}" == "ghcr.io" ]]; }
function _is_dockerhub_image() {
  local image="$1"
  [[ "${image%%/*}" == "docker.io" ]] && return 0
  [[ "$image" != *"."*"/"* ]] && return 0
  return 1
}
function _get_pull_image() {
  local image="$1"
  if _is_ghcr_image "$image"; then
    if [[ "$GHCR_DIRECT_OK" == true ]]; then echo "$image"
    elif [[ -n "$BEST_GHCR_PROXY" ]]; then echo "${image/ghcr.io/$BEST_GHCR_PROXY}"
    else echo "$image"; fi
  elif _is_dockerhub_image "$image"; then
    if [[ "$DOCKERHUB_DIRECT_OK" == true ]]; then echo "$image"
    elif [[ -n "$BEST_DOCKERHUB_PROXY" ]]; then
      if [[ "$image" != *"/"* ]]; then echo "${BEST_DOCKERHUB_PROXY}/library/${image}"
      else echo "${BEST_DOCKERHUB_PROXY}/${image}"; fi
    else echo "$image"; fi
  else echo "$image"; fi
}
function _smart_pull() {
  local image="$1" pa=""
  [[ -n "${PLATFORM:-}" ]] && pa="--platform $PLATFORM"
  local pull_image; pull_image=$(_get_pull_image "$image")
  if [[ "$pull_image" != "$image" ]]; then
    yellow "拉取镜像: $image"
    yellow "  使用代理: $pull_image"
    yellow "  ⏳ 镜像约 250-500MB，请耐心等待..."
    if timeout 600 docker pull $pa "$pull_image"; then
      docker tag "$pull_image" "$image" 2>/dev/null || true
      green "  ✅ 拉取成功，已标记为: $image"
      return 0
    fi
    yellow "  代理拉取失败或超时，尝试其他代理..."
    if _is_ghcr_image "$image"; then
      for proxy in "${GHCR_PROXIES[@]}"; do
        [[ "$proxy" == "$BEST_GHCR_PROXY" ]] && continue
        local try_image="${image/ghcr.io/$proxy}"
        yellow "  尝试: $try_image"
        if timeout 600 docker pull $pa "$try_image"; then
          docker tag "$try_image" "$image" 2>/dev/null || true
          green "  ✅ 拉取成功"; return 0
        fi
      done
    elif _is_dockerhub_image "$image"; then
      for proxy in "${DOCKERHUB_PROXIES[@]}"; do
        [[ "$proxy" == "$BEST_DOCKERHUB_PROXY" ]] && continue
        local try_image
        if [[ "$image" != *"/"* ]]; then try_image="${proxy}/library/${image}"
        else try_image="${proxy}/${image}"; fi
        yellow "  尝试: $try_image"
        if timeout 600 docker pull $pa "$try_image"; then
          docker tag "$try_image" "$image" 2>/dev/null || true
          green "  ✅ 拉取成功"; return 0
        fi
      done
    fi
    red "  ❌ 所有代理均失败"; return 1
  else
    yellow "拉取镜像: $image"
    if timeout 600 docker pull $pa "$image"; then green "  ✅ 拉取成功"; return 0; fi
    red "  ❌ 拉取失败"; return 1
  fi
}
function pull_image_with_retry() {
  local img="$1"
  if ! _smart_pull "$img"; then
    echo ""
    yellow "拉取失败，可选操作："
    echo "  1. 重新检测网络并重试"
    echo "  2. 手动选择代理重试"
    echo "  3. 跳过代理直接拉取（需科学上网）"
    echo "  0. 放弃"
    read -rp "选项 (默认 1): " rp </dev/tty
    case "${rp:-1}" in
      1) _detect_network; _smart_pull "$img" || { red "仍然失败，请检查网络。"; return 1; } ;;
      2) _manual_proxy_pull "$img" || return 1 ;;
      3) local pa=""; [[ -n "${PLATFORM:-}" ]] && pa="--platform $PLATFORM"; yellow "直接拉取: $img"; timeout 600 docker pull $pa "$img" || { red "直接拉取失败"; return 1; }; green "✅ 拉取成功" ;;
      *) red "放弃拉取: $img"; return 1 ;;
    esac
  fi
}
function _manual_proxy_pull() {
  local img="$1"
  local proxies=()
  if _is_ghcr_image "$img"; then proxies=("${GHCR_PROXIES[@]}")
  else proxies=("${DOCKERHUB_PROXIES[@]}"); fi
  echo "选择代理："
  local i=1
  for p in "${proxies[@]}"; do echo "  $i. $p"; i=$((i+1)); done
  read -rp "编号: " pn </dev/tty
  if [[ "$pn" =~ ^[0-9]+$ && "$pn" -ge 1 && "$pn" -le ${#proxies[@]} ]]; then
    local proxy="${proxies[$((pn-1))]}"
    local pull_img="" pa=""
    [[ -n "${PLATFORM:-}" ]] && pa="--platform $PLATFORM"
    if _is_ghcr_image "$img"; then pull_img="${img/ghcr.io/$proxy}"
    else
      if [[ "$img" != *"/"* ]]; then pull_img="${proxy}/library/${img}"
      else pull_img="${proxy}/${img}"; fi
    fi
    yellow "拉取: $pull_img"
    if timeout 600 docker pull $pa "$pull_img"; then
      docker tag "$pull_img" "$img" 2>/dev/null || true
      green "✅ 拉取成功"; return 0
    fi
  fi
  red "拉取失败"; return 1
}
function setup_logging() {
  local tmp_id=""
  [[ -f /etc/os-release ]] && tmp_id=$(grep '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]')
  if [[ "$tmp_id" == "openwrt" || "$tmp_id" == "libwrt" ]]; then
    LOG_FILE="/tmp/deploy_script.log"
    yellow "提示：OpenWrt 日志写入 /tmp，重启后丢失。"
  else LOG_FILE="$HOME/.deploy_script.log"; fi
  local LOG_MAX_SIZE=3145728 cur_size=0
  [[ -f "$LOG_FILE" ]] && cur_size=$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
  [[ "$cur_size" -ge "$LOG_MAX_SIZE" ]] && echo "日志超限，已清空。" > "$LOG_FILE"
  touch "$LOG_FILE" || { red "无法创建日志文件：$LOG_FILE"; exit 1; }
  exec > >(tee -a "$LOG_FILE") 2>&1
}
function detect_architecture() {
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64|amd64)   PLATFORM="linux/amd64"  ;;
    i386|i686)      PLATFORM="linux/386"    ;;
    armv7l|armhf)   PLATFORM="linux/arm/v7" ;;
    aarch64|arm64)  PLATFORM="linux/arm64"  ;;
    *)              yellow "警告：未知架构 ($ARCH)，不指定 Docker 平台。"; PLATFORM="" ;;
  esac
  [[ -n "$PLATFORM" ]] && green "架构：$ARCH → 平台：$PLATFORM"
}
function detect_os() {
  if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    local id="${ID,,}"
    case "$id" in
      ubuntu|debian|raspbian) OS="debian"; PACKAGE_MANAGER="apt" ;;
      centos|rhel|rocky|almalinux) OS="$id"; [[ -f /usr/bin/dnf ]] && PACKAGE_MANAGER="dnf" || PACKAGE_MANAGER="yum" ;;
      fedora) OS="fedora"; PACKAGE_MANAGER="dnf" ;;
      arch|manjaro) OS="arch"; PACKAGE_MANAGER="pacman" ;;
      openwrt|libwrt|nwrt|qwrt|hwrt|lede|immortalwrt|x-wrt|istoreos) OS="openwrt"; PACKAGE_MANAGER="opkg" ;;
      alpine) OS="alpine"; PACKAGE_MANAGER="apk" ;;
      *) OS="$id"; yellow "未明确支持的系统（$OS），尝试自动检测..."
        if command -v apt &>/dev/null; then PACKAGE_MANAGER="apt"
        elif command -v dnf &>/dev/null; then PACKAGE_MANAGER="dnf"
        elif command -v yum &>/dev/null; then PACKAGE_MANAGER="yum"
        elif command -v pacman &>/dev/null; then PACKAGE_MANAGER="pacman"
        elif command -v opkg &>/dev/null; then PACKAGE_MANAGER="opkg"
        elif command -v apk &>/dev/null; then PACKAGE_MANAGER="apk"
        else red "无法找到包管理器，退出。"; exit 1; fi ;;
    esac
  elif [[ "$(uname -s)" == "Darwin" ]]; then OS="macos"; PACKAGE_MANAGER="brew"
  elif [[ "$(uname -s)" == "Linux" ]]; then
    if command -v apt &>/dev/null; then OS="debian"; PACKAGE_MANAGER="apt"
    elif command -v dnf &>/dev/null; then OS="fedora"; PACKAGE_MANAGER="dnf"
    elif command -v yum &>/dev/null; then OS="centos"; PACKAGE_MANAGER="yum"
    elif command -v pacman &>/dev/null; then OS="arch"; PACKAGE_MANAGER="pacman"
    elif command -v opkg &>/dev/null; then OS="openwrt"; PACKAGE_MANAGER="opkg"
    elif command -v apk &>/dev/null; then OS="alpine"; PACKAGE_MANAGER="apk"
    else red "无法识别操作系统，退出。"; exit 1; fi
  else red "不支持的操作系统：$(uname -s)"; exit 1; fi
  green "系统：$OS（包管理器：$PACKAGE_MANAGER）"
}
function install_dependency() {
  local cmd="$1" pkg="$2" update_cmd="" install_cmd=""
  command -v "$cmd" &>/dev/null && { green "$cmd 已安装。"; return 0; }
  yellow "安装 $pkg..."
  case "$PACKAGE_MANAGER" in
    apt) update_cmd="apt update"; install_cmd="apt install -y $pkg" ;;
    yum) install_cmd="yum install -y $pkg" ;;
    dnf) install_cmd="dnf install -y $pkg" ;;
    pacman) update_cmd="pacman -Syu --noconfirm"; install_cmd="pacman -S --noconfirm $pkg" ;;
    opkg) update_cmd="opkg update"; install_cmd="opkg install $pkg" ;;
    apk) update_cmd="apk update"; install_cmd="apk add $pkg" ;;
    brew) install_cmd="brew install $pkg" ;;
    *) red "不支持的包管理器：$PACKAGE_MANAGER"; exit 1 ;;
  esac
  if [[ "$OS" != "openwrt" && "$OS" != "macos" && "$EUID" -ne 0 ]]; then
    [[ -n "$update_cmd" && "$update_cmd" != sudo* ]] && update_cmd="sudo $update_cmd"
    [[ -n "$install_cmd" && "$install_cmd" != sudo* ]] && install_cmd="sudo $install_cmd"
  fi
  [[ -n "$update_cmd" ]] && { eval "$update_cmd" || yellow "包列表更新失败，继续..."; }
  if eval "$install_cmd"; then green "$pkg 安装成功。"
  else red "$pkg 安装失败，请手动安装。"; return 1; fi
}
function check_base_dependencies() {
  if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then install_dependency "curl" "curl" || true; fi
  if ! command -v ss &>/dev/null && ! command -v netstat &>/dev/null; then
    local netstat_pkg="net-tools" ss_pkg="iproute2"
    [[ "$PACKAGE_MANAGER" == "opkg" ]] && ss_pkg="ip-full"
    [[ "$PACKAGE_MANAGER" == "yum" || "$PACKAGE_MANAGER" == "dnf" ]] && ss_pkg="iproute"
    [[ "$PACKAGE_MANAGER" == "apk" ]] && ss_pkg="iproute2"
    install_dependency "netstat" "$netstat_pkg" || install_dependency "ss" "$ss_pkg" || yellow "端口检查工具安装失败，跳过。"
  fi
}
function check_docker_dependencies() {
  local docker_pkg="docker" needs_repo=false
  case "$PACKAGE_MANAGER" in
    apt) docker_pkg="docker.io" ;;
    yum|dnf) rpm -q docker-ce &>/dev/null || needs_repo=true
      docker_pkg="docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin" ;;
    pacman) docker_pkg="docker docker-compose" ;;
    opkg) docker_pkg="docker dockerd docker-compose" ;;
    apk) docker_pkg="docker docker-cli-compose" ;;
    brew) docker_pkg="--cask docker" ;;
  esac
  if [[ "$needs_repo" == true && "$OS" != "openwrt" ]]; then
    local repo_pkg="" repo_cmd=""
    if command -v dnf &>/dev/null; then repo_pkg="dnf-plugins-core"
      [[ "$OS" == "fedora" ]] && repo_cmd="dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo" \
        || repo_cmd="dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo"
    elif command -v yum &>/dev/null; then repo_pkg="yum-utils"
      repo_cmd="yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo"
    fi
    if [[ -n "$repo_pkg" ]]; then
      local ic="$PACKAGE_MANAGER install -y $repo_pkg"; [[ "$EUID" -ne 0 ]] && ic="sudo $ic"; eval "$ic" || true
      local fc="$repo_cmd"; [[ "$EUID" -ne 0 && "$fc" != sudo* ]] && fc="sudo $fc"; eval "$fc" || yellow "添加 Docker 仓库失败，继续..."
    fi
  fi
  install_dependency "docker" "$docker_pkg" || true
  if [[ "$OS" == "openwrt" ]]; then
    /etc/init.d/dockerd status 2>/dev/null | grep -q "running" || { /etc/init.d/dockerd enable || true; /etc/init.d/dockerd start || yellow "请手动启动：/etc/init.d/dockerd start"; }
  elif [[ "$OS" == "alpine" ]]; then
    rc-service docker status 2>/dev/null | grep -q "started" || { rc-update add docker default 2>/dev/null || true; rc-service docker start || yellow "请手动启动：rc-service docker start"; }
  elif [[ "$OS" == "macos" ]]; then docker info &>/dev/null || yellow "请启动 Docker Desktop"
  elif command -v systemctl &>/dev/null; then
    systemctl is-active --quiet docker || { local sc="systemctl enable --now docker"; [[ "$EUID" -ne 0 ]] && sc="sudo $sc"; eval "$sc" || yellow "请手动启动 Docker 服务。"; }
  fi
  docker info &>/dev/null || { red "Docker 无法连接，请检查安装。"; exit 1; }
  if docker compose version &>/dev/null; then green "Docker Compose 插件：$(docker compose version | head -n1)"
  elif command -v docker-compose &>/dev/null; then green "Docker Compose：$(docker-compose --version)"
  else
    yellow "安装 Docker Compose 独立版..."
    local cv; cv=$(_http_get "https://api.github.com/repos/docker/compose/releases/latest" 5 | grep '"tag_name"' | head -n1 | cut -d'"' -f4 2>/dev/null || echo "$COMPOSE_FALLBACK_VERSION")
    local url="https://github.com/docker/compose/releases/download/${cv}/docker-compose-$(uname -s)-$(uname -m)"
    local dst="/usr/local/bin/docker-compose"; [[ -w "/usr/local/bin" ]] || dst="/usr/bin/docker-compose"
    local dl=""; command -v curl &>/dev/null && dl="curl -sSL \"$url\" -o /tmp/docker-compose" || dl="wget -q \"$url\" -O /tmp/docker-compose"
    eval "$dl" || { red "下载 docker-compose 失败。"; return 1; }
    local mv_cmd="mv /tmp/docker-compose \"$dst\"" cx_cmd="chmod +x \"$dst\""
    [[ "$EUID" -ne 0 ]] && mv_cmd="sudo $mv_cmd" && cx_cmd="sudo $cx_cmd"
    eval "$mv_cmd" && eval "$cx_cmd" && green "docker-compose $cv 安装成功。" || { red "安装失败。"; rm -f /tmp/docker-compose; return 1; }
  fi
}
function check_user_permission() {
  [[ "$OS" == "openwrt" || "$OS" == "macos" ]] && return 0
  [[ "$EUID" -eq 0 ]] && { green "当前为 root 用户。"; return 0; }
  if groups "$USER" | grep -q '\bdocker\b'; then green "用户 $USER 已在 docker 组。"
  else
    yellow "将用户 $USER 加入 docker 组..."
    if command -v sudo &>/dev/null; then sudo usermod -aG docker "$USER" && green "已加入，请执行 'newgrp docker' 或重新登录生效。" || red "加入失败，请手动：sudo usermod -aG docker $USER"
    else red "缺少 sudo，请手动：usermod -aG docker $USER"; fi
  fi
}
function find_available_port() {
  local p=${1:-3000} ck=""
  command -v ss &>/dev/null && ck="ss -tuln"; command -v netstat &>/dev/null && ck="${ck:-netstat -tuln}"
  [[ -z "$ck" ]] && { echo "$p"; return; }
  while $ck | grep -Eq "[:.\[]${p}[[:space:]]+"; do p=$((p + 1)); [[ "$p" -gt 65535 ]] && { p=${1:-3000}; break; }; done
  echo "$p"
}
function validate_port() {
  local hint=${1:-3000} sug; sug=$(find_available_port "$hint"); green "建议端口：$sug"
  local attempts=0
  while true; do
    attempts=$((attempts + 1)); [[ "$attempts" -gt 10 ]] && { red "端口错误次数过多，退出。"; return 1; }
    read -rp "输入端口（留空使用 $sug）：" up </dev/tty; PORT=${up:-$sug}
    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [[ "$PORT" -lt 1 || "$PORT" -gt 65535 ]]; then red "无效端口。"; continue; fi
    local ck=""; command -v ss &>/dev/null && ck="ss -tuln"; command -v netstat &>/dev/null && ck="${ck:-netstat -tuln}"
    if [[ -n "$ck" ]] && $ck | grep -Eq "[:.\[]${PORT}[[:space:]]+"; then red "端口 $PORT 已被占用。"; continue; fi
    green "使用端口：$PORT"; return 0
  done
}
function choose_network_mode() {
  echo "网络模式："
  echo "  1. bridge（推荐，端口映射访问）"
  echo "  2. host  （共享主机网络，端口冲突风险高）"
  read -rp "选项 (1-2，默认 1)：" mc </dev/tty
  case "${mc:-1}" in 2) NETWORK_MODE="host"; green "网络模式：host" ;; *) NETWORK_MODE="bridge"; green "网络模式：bridge" ;; esac
}
function get_local_ip() {
  local ip="<服务器IP>"
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || ip -4 addr show scope global 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -n1 || hostname -I 2>/dev/null | awk '{print $1}' || ifconfig 2>/dev/null | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | head -n1 || echo "$ip")
  echo "$ip"
}
function ensure_dir_writable() {
  local d="$1"; mkdir -p "$d"
  if ! touch "$d/.wtest" 2>/dev/null; then
    red "目录 $d 不可写，尝试修复..."
    local cc="chown $(id -u):$(id -g) \"$d\"" cm="chmod u+rwx \"$d\""
    [[ "$EUID" -ne 0 ]] && cc="sudo $cc" && cm="sudo $cm"
    eval "$cc" || true; eval "$cm" || true
    touch "$d/.wtest" 2>/dev/null || { red "修复失败：$d"; return 1; }
  fi
  rm -f "$d/.wtest"
}
function check_existing_container() {
  local n="$1"
  if docker ps -a --format '{{.Names}}' | grep -Eq "^${n}$"; then red "容器 '$n' 已存在，请先卸载。"; return 1; fi
  return 0
}
function _show_deploy_result() {
  local svc="$1" ip="$2" port="$3" data_info="${4:-}" extra="${5:-}"
  echo ""; green "✅ $svc 部署成功"
  green "   Web UI : http://${ip}:${port}"
  green "   API    : http://${ip}:${port}/v1/chat/completions"
  green "   账号   : root   密码: 123456"
  [[ -n "$data_info" ]] && green "   数据   : ${data_info}"
  [[ -n "$extra" ]] && yellow "   信息   : ${extra}"
  yellow "   ⚠️  请登录后立即修改默认密码！"
  yellow "   建议：主菜单 → 备份/恢复 完成首次备份"; echo ""
}
function _check_pack_tools() {
  if command -v tar &>/dev/null && command -v gzip &>/dev/null; then echo "tar.gz"
  elif command -v tar &>/dev/null && command -v bzip2 &>/dev/null; then echo "tar.bz2"
  elif command -v tar &>/dev/null && command -v xz &>/dev/null; then echo "tar.xz"
  elif command -v tar &>/dev/null; then echo "tar"
  elif command -v zip &>/dev/null; then echo "zip"
  else echo "none"; fi
}
function _do_pack() {
  local src_dir="$1" src_base="$2" out_file="$3" pack_type="$4"
  local abs_out; abs_out=$(readlink -f "$out_file" 2>/dev/null || echo "$out_file")
  local err_file="/tmp/_pack_err_$$"
  case "$pack_type" in
    tar.gz) tar -czf "$abs_out" -C "$src_dir" "$src_base" 2>"$err_file" ;;
    tar.bz2) tar -cjf "$abs_out" -C "$src_dir" "$src_base" 2>"$err_file" ;;
    tar.xz) tar -cJf "$abs_out" -C "$src_dir" "$src_base" 2>"$err_file" ;;
    tar) tar -cf "$abs_out" -C "$src_dir" "$src_base" 2>"$err_file" ;;
    zip) local prev="$PWD"; cd "$src_dir" || { rm -f "$err_file"; return 1; }
      zip -qr "$abs_out" "$src_base" 2>"$err_file"; local zrc=$?; cd "$prev" || true
      if [[ $zrc -ne 0 ]]; then [[ -s "$err_file" ]] && while IFS= read -r l; do red "  $l"; done < "$err_file"; rm -f "$err_file"; return 1; fi ;;
  esac
  local rc=$?
  if [[ "$pack_type" != "zip" && $rc -ne 0 ]]; then [[ -s "$err_file" ]] && while IFS= read -r l; do red "  $l"; done < "$err_file"; rm -f "$err_file"; return 1; fi
  rm -f "$err_file"
  [[ ! -f "$abs_out" ]] && { red "打包文件未生成：$abs_out"; return 1; }
  local fsize; fsize=$(stat -c%s "$abs_out" 2>/dev/null || stat -f%z "$abs_out" 2>/dev/null || echo 0)
  [[ "$fsize" -lt 10 ]] && { red "打包文件异常（${fsize}B）"; rm -f "$abs_out"; return 1; }
  return 0
}
function _do_unpack() {
  local archive="$1" dest_dir="$2" err_file="/tmp/_unpack_err_$$"
  case "$archive" in
    *.tar.gz|*.tgz) tar -xzf "$archive" -C "$dest_dir" 2>"$err_file" ;;
    *.tar.bz2) tar -xjf "$archive" -C "$dest_dir" 2>"$err_file" ;;
    *.tar.xz) tar -xJf "$archive" -C "$dest_dir" 2>"$err_file" ;;
    *.tar) tar -xf "$archive" -C "$dest_dir" 2>"$err_file" ;;
    *.zip) unzip -q "$archive" -d "$dest_dir" 2>"$err_file" ;;
    *) red "未知格式：$archive"; rm -f "$err_file"; return 1 ;;
  esac
  local rc=$?
  if [[ $rc -ne 0 ]]; then [[ -s "$err_file" ]] && while IFS= read -r l; do red "  $l"; done < "$err_file"; rm -f "$err_file"; return 1; fi
  rm -f "$err_file"; return 0
}
function _select_backup_root() {
  echo "" >&2; echo "备份位置：" >&2; echo "  1. 主目录 ($HOME)" >&2; echo "  2. /tmp（重启丢失）" >&2; echo "  3. 手动输入" >&2
  read -rp "选项 (1-3，默认 1)：" bc </dev/tty
  local backup_root=""
  case "${bc:-1}" in 2) backup_root="/tmp" ;; 3) read -rp "目录路径：" custom_dir </dev/tty; backup_root="${custom_dir:-$HOME}" ;; *) backup_root="$HOME" ;; esac
  mkdir -p "$backup_root" 2>/dev/null || { echo -e "\e[31m目录 $backup_root 无法创建。\e[0m" >&2; return 1; }
  touch "$backup_root/.wtest" 2>/dev/null || { echo -e "\e[31m目录 $backup_root 不可写。\e[0m" >&2; return 1; }
  rm -f "$backup_root/.wtest"; echo -e "\e[32m备份目录：$backup_root\e[0m" >&2; echo "$backup_root"
}
function _check_disk_space() {
  local target_dir="$1" min_kb="${2:-51200}"
  local avail_kb; avail_kb=$(df -k "$target_dir" 2>/dev/null | awk 'NR==2{print $4}' || echo 999999)
  if [[ "$avail_kb" -lt "$min_kb" ]]; then
    yellow "⚠️  可用空间不足（${avail_kb}KB，建议 ${min_kb}KB）"
    read -rp "是否继续？(y/n，默认 n)：" sc </dev/tty; [[ ! "${sc:-n}" =~ ^[Yy]$ ]] && return 1
  fi
  return 0
}
function _scan_backup_files() {
  local prefix="$1" scan_dirs=("$HOME" "/tmp" "/mnt" "/data" "/backup")
  for d in "${scan_dirs[@]}"; do
    [[ -d "$d" ]] || continue
    find "$d" -maxdepth 3 \( -name "${prefix}-*.tar.gz" -o -name "${prefix}-*.tar.bz2" -o -name "${prefix}-*.tar.xz" -o -name "${prefix}-*.tar" -o -name "${prefix}-*.zip" \) 2>/dev/null | sort -r
  done
}
function _get_daemon_json_path() { echo "/etc/docker/daemon.json"; }
function _read_current_mirrors() {
  local daemon_json; daemon_json=$(_get_daemon_json_path); [[ ! -f "$daemon_json" ]] && { echo ""; return; }
  if command -v python3 &>/dev/null; then
    python3 -c "import json
try:
    with open('$daemon_json') as f: d = json.load(f)
    [print(m) for m in d.get('registry-mirrors', [])]
except: pass" 2>/dev/null || echo ""
  elif command -v jq &>/dev/null; then jq -r '.["registry-mirrors"][]? // empty' "$daemon_json" 2>/dev/null || echo ""
  else echo ""; fi
}
function _write_mirrors_to_daemon() {
  local daemon_json; daemon_json=$(_get_daemon_json_path)
  local mirrors_json="$1" write_cmd="tee"
  [[ "$EUID" -ne 0 ]] && command -v sudo &>/dev/null && write_cmd="sudo tee"
  local tmp_py="/tmp/_dmj_$$.py"
  cat > "$tmp_py" << 'PYEOF'
import json, sys
daemon_json = sys.argv[1]
mirrors_json_str = sys.argv[2]
try:
    with open(daemon_json, 'r') as f: data = json.load(f)
except: data = {}
mirrors = json.loads(mirrors_json_str)
if mirrors: data['registry-mirrors'] = mirrors
elif 'registry-mirrors' in data: del data['registry-mirrors']
print(json.dumps(data, indent=2, ensure_ascii=False))
PYEOF
  local new_content=""
  if command -v python3 &>/dev/null; then new_content=$(python3 "$tmp_py" "$daemon_json" "$mirrors_json" 2>/dev/null)
  elif command -v python &>/dev/null; then new_content=$(python "$tmp_py" "$daemon_json" "$mirrors_json" 2>/dev/null); fi
  rm -f "$tmp_py"
  if [[ -n "$new_content" ]]; then echo "$new_content" | $write_cmd "$daemon_json" >/dev/null; return $?; fi
  if [[ "$mirrors_json" == "[]" ]]; then printf '{\n}\n' | $write_cmd "$daemon_json" >/dev/null
  else printf '{\n  "registry-mirrors": %s\n}\n' "$mirrors_json" | $write_cmd "$daemon_json" >/dev/null; fi
}
function _restart_docker_daemon() {
  yellow "重启 Docker 守护进程..."
  if command -v systemctl &>/dev/null; then
    local cmd="systemctl restart docker"; [[ "$EUID" -ne 0 ]] && cmd="sudo $cmd"
    eval "$cmd" && green "✅ Docker 已重启。" || { red "重启失败，请手动：sudo systemctl restart docker"; return 1; }
  elif [[ "$OS" == "openwrt" ]]; then /etc/init.d/dockerd restart && green "✅ Docker 已重启。" || red "请手动：/etc/init.d/dockerd restart"
  elif [[ "$OS" == "alpine" ]]; then rc-service docker restart && green "✅ Docker 已重启。" || red "请手动：rc-service docker restart"
  else yellow "请手动重启 Docker 服务。"; fi
}
function _copy_volume_to_dir() {
  local volume_name="$1" dest_dir="$2"; mkdir -p "$dest_dir"
  yellow "  策略1：直接读取卷路径..."
  local vol_path; vol_path=$(docker volume inspect "$volume_name" --format '{{.Mountpoint}}' 2>/dev/null || echo "")
  if [[ -n "$vol_path" && -d "$vol_path" ]]; then
    local ok=false
    if [[ "$EUID" -eq 0 ]]; then cp -a "$vol_path/." "$dest_dir/" 2>/dev/null && ok=true
    elif command -v sudo &>/dev/null; then sudo cp -a "$vol_path/." "$dest_dir/" 2>/dev/null && sudo chown -R "$(id -u):$(id -g)" "$dest_dir" 2>/dev/null && ok=true || true; fi
    if $ok; then local fc; fc=$(find "$dest_dir" -type f 2>/dev/null | wc -l || echo 0); green "  策略1 成功（$fc 个文件）"; return 0; fi
    yellow "  策略1 失败，下一策略..."
  else yellow "  策略1 失败（路径不可访问），下一策略..."; fi
  yellow "  策略2：使用本地轻量镜像..."
  local helper=""
  for c in "alpine:latest" "alpine" "busybox:latest" "busybox"; do docker image inspect "$c" &>/dev/null && { helper="$c"; break; }; done
  if [[ -n "$helper" ]]; then
    if docker run --rm -v "${volume_name}:/source:ro" -v "${dest_dir}:/backup" "$helper" sh -c "cp -a /source/. /backup/" 2>/dev/null; then
      local fc; fc=$(find "$dest_dir" -type f 2>/dev/null | wc -l || echo 0); [[ "$fc" -gt 0 ]] && { green "  策略2 成功（$fc 个文件）"; return 0; }
    fi
    yellow "  策略2 失败，下一策略..."
  fi
  yellow "  策略3：拉取 alpine..."
  _smart_pull "alpine:latest" &>/dev/null && docker run --rm -v "${volume_name}:/source:ro" -v "${dest_dir}:/backup" alpine sh -c "cp -a /source/. /backup/" 2>/dev/null && { green "  策略3 成功"; return 0; }
  red "  ❌ 所有备份策略失败，请检查 Docker 卷或网络。"; return 1
}
function _copy_dir_to_volume() {
  local src_dir="$1" volume_name="$2"
  yellow "  策略1：直接写入卷路径..."
  local vol_path; vol_path=$(docker volume inspect "$volume_name" --format '{{.Mountpoint}}' 2>/dev/null || echo "")
  if [[ -n "$vol_path" && -d "$vol_path" ]]; then
    local ok=false
    [[ "$EUID" -eq 0 ]] && cp -a "$src_dir/." "$vol_path/" 2>/dev/null && ok=true
    if ! $ok && command -v sudo &>/dev/null; then sudo cp -a "$src_dir/." "$vol_path/" 2>/dev/null && ok=true; fi
    $ok && { green "  策略1 成功"; return 0; }
    yellow "  策略1 失败，下一策略..."
  fi
  yellow "  策略2：使用本地轻量镜像..."
  local helper=""
  for c in "alpine:latest" "alpine" "busybox:latest" "busybox"; do docker image inspect "$c" &>/dev/null && { helper="$c"; break; }; done
  if [[ -n "$helper" ]]; then
    docker run --rm -v "${volume_name}:/target" -v "${src_dir}:/source:ro" "$helper" sh -c "rm -rf /target/* /target/.[!.]* 2>/dev/null; cp -a /source/. /target/" 2>/dev/null && { green "  策略2 成功"; return 0; }
    yellow "  策略2 失败，下一策略..."
  fi
  yellow "  策略3：拉取 alpine..."
  _smart_pull "alpine:latest" &>/dev/null && docker run --rm -v "${volume_name}:/target" -v "${src_dir}:/source:ro" alpine sh -c "rm -rf /target/* /target/.[!.]* 2>/dev/null; cp -a /source/. /target/" 2>/dev/null && { green "  策略3 成功"; return 0; }
  red "  ❌ 所有恢复策略失败！"; return 1
}
function _fetch_versions_github() {
  local repo="$1" limit="${2:-8}"
  local resp; resp=$(_http_get "https://api.github.com/repos/${repo}/releases?per_page=100" 10) || return 1
  [[ -z "$resp" ]] && return 1
  echo "$resp" | grep '"tag_name"' | cut -d'"' -f4 | head -n"$limit"
}
function _fetch_versions_ghcr() {
  local image_path="$1" limit="${2:-8}"
  local token; token=$(_http_get "https://ghcr.io/token?scope=repository:${image_path}:pull&service=ghcr.io" 5 | grep -o '"token":"[^"]*"' | cut -d'"' -f4 2>/dev/null || true)
  [[ -z "$token" ]] && return 1
  local all_tags="" next_url="https://ghcr.io/v2/${image_path}/tags/list?n=1000"
  while [[ -n "$next_url" ]]; do
    local resp="" headers=""
    if command -v curl &>/dev/null; then
      headers=$(curl -sSL --connect-timeout 8 --max-time 15 -H "Authorization: Bearer $token" -D - -o /tmp/_ghcr_tags_$$.json "$next_url" 2>/dev/null || true)
      resp=$(cat /tmp/_ghcr_tags_$$.json 2>/dev/null || true)
      rm -f /tmp/_ghcr_tags_$$.json
    elif command -v wget &>/dev/null; then
      resp=$(wget -qO- --timeout=15 --header="Authorization: Bearer $token" "$next_url" 2>/dev/null || true)
      headers=""
    fi
    [[ -z "$resp" ]] && break
    all_tags+=" $resp"
    local link_next; link_next=$(echo "$headers" | grep -i '^Link:' | grep -o '<[^>]*>' | grep 'rel="next"' | head -1 | tr -d '<>' | sed 's/;.*$//' || true)
    [[ -n "$link_next" ]] && next_url="$link_next" || next_url=""
  done
  [[ -z "$all_tags" ]] && return 1
  echo "$all_tags" | grep -o '"[^"]*"' | tr -d '"' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -rV | head -n"$limit"
}
function _fetch_versions_dockerhub() {
  local repo="$1" limit="${2:-8}"
  local resp; resp=$(_http_get "https://hub.docker.com/v2/repositories/${repo}/tags?page_size=50&ordering=last_updated" 8) || return 1
  [[ -z "$resp" ]] && return 1
  echo "$resp" | grep -o '"name":"[^"]*"' | cut -d'"' -f4 | grep -E '^v?[0-9]' | head -n"$limit"
}
function select_image_version() {
  local svc_name="$1" img_base="$2" fetch_type="$3" fetch_src="$4" limit="${5:-8}"
  SELECTED_IMAGE="${img_base}:latest"
  yellow "获取 ${svc_name} 版本列表..."
  local versions=() fetch_ok=false
  if [[ "$fetch_type" == "github" ]]; then
    mapfile -t versions < <(_fetch_versions_github "$fetch_src" "$limit" 2>/dev/null)
    [[ ${#versions[@]} -gt 0 ]] && fetch_ok=true
    if ! $fetch_ok; then mapfile -t versions < <(_fetch_versions_ghcr "$fetch_src" "$limit" 2>/dev/null); [[ ${#versions[@]} -gt 0 ]] && fetch_ok=true; fi
  elif [[ "$fetch_type" == "ghcr" ]]; then
    mapfile -t versions < <(_fetch_versions_ghcr "$fetch_src" "$limit" 2>/dev/null)
    [[ ${#versions[@]} -gt 0 ]] && fetch_ok=true
    if ! $fetch_ok; then mapfile -t versions < <(_fetch_versions_github "$fetch_src" "$limit" 2>/dev/null); [[ ${#versions[@]} -gt 0 ]] && fetch_ok=true; fi
  elif [[ "$fetch_type" == "dockerhub" ]]; then
    mapfile -t versions < <(_fetch_versions_dockerhub "$fetch_src" "$limit" 2>/dev/null); [[ ${#versions[@]} -gt 0 ]] && fetch_ok=true
  fi
  local clean=(); for v in "${versions[@]}"; do [[ -n "$v" ]] && clean+=("$v"); done; versions=("${clean[@]+"${clean[@]}"}")
  echo ""; cyan "选择 ${svc_name} 版本："; echo "  1. latest（始终最新）"
  local i=2
  if [[ ${#versions[@]} -gt 0 ]]; then for v in "${versions[@]}"; do local label=""; [[ "$i" -eq 2 ]] && label="  ← 最新"; printf "  %d. %-22s%s\n" "$i" "$v" "$label"; i=$((i + 1)); done; fi
  local midx=$i; printf "  %d. 手动输入\n" "$midx"; echo ""
  ! $fetch_ok && yellow "（版本列表获取失败，可选 latest 或手动输入）"
  read -rp "版本编号（留空用 latest）：" vc </dev/tty
  if [[ -z "$vc" || "$vc" == "1" ]]; then SELECTED_IMAGE="${img_base}:latest"
  elif [[ "$vc" =~ ^[0-9]+$ ]] && [[ "$vc" -ge 2 && "$vc" -lt "$midx" ]]; then SELECTED_IMAGE="${img_base}:${versions[$((vc-2))]}"
  elif [[ "$vc" == "$midx" ]]; then read -rp "输入版本号（如 v1.2.3）：" mv </dev/tty; SELECTED_IMAGE="${img_base}:${mv:-latest}"
  else yellow "无效选项，使用 latest。"; SELECTED_IMAGE="${img_base}:latest"; fi
  green "已选：$SELECTED_IMAGE"
}
function _prompt_backup_before_action() {
  local action="${1:-此操作}"
  yellow "⚠️  建议在${action}前先备份（主菜单 → 备份/恢复）"
  read -rp "继续${action}？(y/n，默认 y)：" pc </dev/tty; [[ ! "${pc:-y}" =~ ^[Yy]$ ]] && { yellow "已取消。"; return 1; }; return 0
}
function _capture_container_runtime() {
  local cname="$1"
  RUNTIME_NM=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$cname" 2>/dev/null || echo "bridge")
  RUNTIME_PT=$(docker inspect "$cname" --format '{{range $p, $c := .HostConfig.PortBindings}}{{range $c}}{{.HostPort}}{{end}}{{end}}' 2>/dev/null | head -n1)
  RUNTIME_BINDIP=$(docker inspect "$cname" --format '{{range $p, $c := .HostConfig.PortBindings}}{{range $c}}{{.HostIp}}{{end}}{{end}}' 2>/dev/null | head -n1)
  RUNTIME_MOUNTS=()
  while IFS= read -r line; do [[ -n "$line" ]] && RUNTIME_MOUNTS+=("$line"); done < <(docker inspect "$cname" --format '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{else}}{{.Source}}{{end}}:{{.Destination}}{{println}}{{end}}' 2>/dev/null)
  RUNTIME_ENVS=()
  while IFS= read -r line; do
    case "$line" in PATH=*|HOSTNAME=*|HOME=*|TZ=*) continue ;; esac
    [[ -n "$line" ]] && RUNTIME_ENVS+=("$line")
  done < <(docker inspect "$cname" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null)
  RUNTIME_CMD=()
  while IFS= read -r line; do [[ -n "$line" ]] && RUNTIME_CMD+=("$line"); done < <(docker inspect "$cname" --format '{{range .Config.Cmd}}{{println .}}{{end}}' 2>/dev/null)
}
function _backup_bind_service() {
  local svc_label="$1" container_name="$2" data_dir="$3" backup_prefix="$4"
  echo ""; cyan "备份：$svc_label"
  if [[ ! -d "$data_dir" ]]; then red "数据目录不存在：$data_dir"; return 1; fi
  local fc; fc=$(find "$data_dir" -type f 2>/dev/null | wc -l || echo 0); green "数据目录：$data_dir（$fc 个文件）"
  local pack_type; pack_type=$(_check_pack_tools); [[ "$pack_type" == "none" ]] && { red "未找到打包工具！"; return 1; }
  local backup_root; backup_root=$(_select_backup_root) || return 1
  _check_disk_space "$backup_root" 51200 || return 1
  local stamp; stamp=$(date +%Y%m%d_%H%M%S)
  local bname="${backup_prefix}-${stamp}"
  local btmp="${backup_root}/${bname}"
  local barch="${backup_root}/${bname}.${pack_type}"
  mkdir -p "$btmp"
  yellow "1/3 暂停容器..."
  local was_running=false
  if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then was_running=true; docker stop "$container_name" &>/dev/null || true; green "  容器已暂停"
  else yellow "  容器未运行，直接备份"; fi
  yellow "2/3 复制数据..."; mkdir -p "$btmp/data"
  if cp -a "$data_dir/." "$btmp/data/" 2>/dev/null; then local copied; copied=$(find "$btmp/data" -type f 2>/dev/null | wc -l || echo 0); green "  复制完成（$copied 个文件）"
  else red "  复制失败"; [[ "$was_running" == true ]] && docker start "$container_name" &>/dev/null || true; rm -rf "$btmp"; return 1; fi
  local cur_image; cur_image=$(docker inspect "$container_name" --format '{{.Config.Image}}' 2>/dev/null || echo "未知")
  cat > "$btmp/backup_info.txt" << EOF
服务名称：${svc_label}
容器名称：${container_name}
备份时间：$(date '+%Y-%m-%d %H:%M:%S')
主机名：$(hostname)
系统：${OS} / ${ARCH}
镜像版本：${cur_image}
数据目录：${data_dir}
打包格式：${pack_type}
EOF
  [[ "$was_running" == true ]] && { yellow "  重启容器..."; docker start "$container_name" &>/dev/null && green "  容器已恢复" || yellow "  请手动：docker start $container_name"; }
  yellow "3/3 打包压缩（$pack_type）..."
  if _do_pack "$backup_root" "$bname" "$barch" "$pack_type"; then
    rm -rf "$btmp"; local size; size=$(du -sh "$barch" 2>/dev/null | cut -f1 || echo "未知")
    echo ""; green "✅ $svc_label 备份完成"; green "   文件：$barch"; green "   大小：$size"
    yellow "   ⚠️  请将备份文件保存到安全位置（U盘/NAS/云盘）"
  else red "打包失败！临时目录：$btmp"; return 1; fi
}
function _restore_bind_service() {
  local svc_label="$1" container_name="$2" data_dir="$3" backup_prefix="$4"
  echo ""; cyan "恢复：$svc_label"; echo "  1. 手动输入路径  2. 自动扫描"
  read -rp "选项 (1-2，默认 2)：" sc </dev/tty
  local barch=""
  case "${sc:-2}" in 1) read -rp "备份文件路径：" barch </dev/tty ;;
    *) yellow "扫描备份文件..."
      local found_files=(); while IFS= read -r f; do found_files+=("$f"); done < <(_scan_backup_files "$backup_prefix")
      if [[ ${#found_files[@]} -eq 0 ]]; then yellow "未找到备份文件。"; read -rp "手动输入路径：" barch </dev/tty
      else
        local i=1; for f in "${found_files[@]}"; do local sz; sz=$(du -sh "$f" 2>/dev/null | cut -f1 || echo "?")
          local ts; ts=$(echo "$f" | grep -oE '[0-9]{8}_[0-9]{6}' | sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)_\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3 \4:\5:\6/' || echo "")
          printf "  %d. %-50s [%s] %s\n" "$i" "$f" "$sz" "$ts"; i=$((i + 1)); done
        read -rp "选择编号（留空手动输入）：" fc </dev/tty
        if [[ -z "$fc" ]]; then read -rp "手动输入路径：" barch </dev/tty
        elif [[ "$fc" =~ ^[0-9]+$ && "$fc" -ge 1 && "$fc" -le ${#found_files[@]} ]]; then barch="${found_files[$((fc-1))]}"
        else red "无效选项。"; return 1; fi
      fi ;;
  esac
  [[ -z "$barch" || ! -f "$barch" ]] && { red "备份文件不存在：$barch"; return 1; }; green "使用备份：$barch"
  local rtmp="/tmp/${backup_prefix}_restore_$$"; mkdir -p "$rtmp"
  yellow "1/4 解压..."; _do_unpack "$barch" "$rtmp" || { red "解压失败。"; rm -rf "$rtmp"; return 1; }
  local rinfo; rinfo=$(find "$rtmp" -maxdepth 3 -name "backup_info.txt" | head -n1)
  [[ -z "$rinfo" ]] && { red "未找到 backup_info.txt，备份格式错误！"; rm -rf "$rtmp"; return 1; }
  local rbase; rbase=$(dirname "$rinfo"); [[ -f "$rbase/backup_info.txt" ]] && { echo ""; cyan "备份信息："; cat "$rbase/backup_info.txt"; echo ""; }
  [[ ! -d "$rbase/data" ]] && { red "备份中无 data 目录！"; rm -rf "$rtmp"; return 1; }
  yellow "2/4 停止容器..."
  docker ps --format '{{.Names}}' | grep -q "^${container_name}$" && { docker stop "$container_name" &>/dev/null; green "  容器已停止"; } || yellow "  容器未运行"
  yellow "3/4 恢复数据..."
  if [[ -d "$data_dir" ]]; then local bak_old="${data_dir}_old_$(date +%Y%m%d_%H%M%S)"; mv "$data_dir" "$bak_old" 2>/dev/null || { red "无法移动旧数据目录"; rm -rf "$rtmp"; return 1; }; green "  旧数据已保留：$bak_old"; fi
  mkdir -p "$data_dir"
  if cp -a "$rbase/data/." "$data_dir/" 2>/dev/null; then local fc; fc=$(find "$data_dir" -type f 2>/dev/null | wc -l || echo 0); green "  恢复完成（$fc 个文件）"
  else red "  数据恢复失败"; rm -rf "$rtmp"; return 1; fi
  rm -rf "$rtmp"; yellow "4/4 启动容器..."
  docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$" && { docker start "$container_name" &>/dev/null && green "  容器已启动" || red "  请手动：docker start $container_name"; } || yellow "  容器不存在，请重新部署（数据已恢复）。"
  echo ""; green "✅ $svc_label 恢复完成"
}
function _list_bind_service_backups() {
  local svc_label="$1" backup_prefix="$2"; echo ""; cyan "$svc_label 备份列表："
  local found=false
  while IFS= read -r f; do local sz; sz=$(du -sh "$f" 2>/dev/null | cut -f1 || echo "?")
    local ts; ts=$(echo "$f" | grep -oE '[0-9]{8}_[0-9]{6}' | sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)_\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3 \4:\5:\6/' || echo "")
    printf "  📦 %-48s [%s] %s\n" "$f" "$sz" "$ts"; found=true
  done < <(_scan_backup_files "$backup_prefix"); $found || yellow "  未找到备份文件。"
}
function _backup_volume_service() {
  local svc_label="$1" container_name="$2" volume_name="$3" backup_prefix="$4"
  echo ""; cyan "备份：$svc_label（Docker 命名卷：$volume_name）"
  if ! docker volume inspect "$volume_name" &>/dev/null; then red "数据卷 $volume_name 不存在，请确认服务已正确部署。"; return 1; fi
  local pack_type; pack_type=$(_check_pack_tools); [[ "$pack_type" == "none" ]] && { red "未找到打包工具！"; return 1; }
  local backup_root; backup_root=$(_select_backup_root) || return 1; _check_disk_space "$backup_root" 102400 || return 1
  local stamp; stamp=$(date +%Y%m%d_%H%M%S)
  local bname="${backup_prefix}-${stamp}"
  local btmp="${backup_root}/${bname}"
  local barch="${backup_root}/${bname}.${pack_type}"
  mkdir -p "$btmp/data"; yellow "1/3 暂停容器保证数据一致性..."
  local was_running=false
  if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then was_running=true; docker stop "$container_name" &>/dev/null || true; green "  容器已暂停"
  else yellow "  容器未运行，直接备份"; fi
  yellow "2/3 导出数据卷..."
  if ! _copy_volume_to_dir "$volume_name" "$btmp/data"; then red "  数据卷导出失败"; [[ "$was_running" == true ]] && docker start "$container_name" &>/dev/null || true; rm -rf "$btmp"; return 1; fi
  local cur_image; cur_image=$(docker inspect "$container_name" --format '{{.Config.Image}}' 2>/dev/null || echo "未知")
  cat > "$btmp/backup_info.txt" << EOF
服务名称：${svc_label}
容器名称：${container_name}
备份时间：$(date '+%Y-%m-%d %H:%M:%S')
主机名：$(hostname)
系统：${OS} / ${ARCH}
镜像版本：${cur_image}
Docker卷：${volume_name}
打包格式：${pack_type}
EOF
  [[ "$was_running" == true ]] && { yellow "  重启容器..."; docker start "$container_name" &>/dev/null && green "  容器已恢复" || yellow "  请手动：docker start $container_name"; }
  yellow "3/3 打包压缩（$pack_type）..."
  if _do_pack "$backup_root" "$bname" "$barch" "$pack_type"; then
    rm -rf "$btmp"; local size; size=$(du -sh "$barch" 2>/dev/null | cut -f1 || echo "未知")
    echo ""; green "✅ $svc_label 备份完成"; green "   文件：$barch"; green "   大小：$size"
    yellow "   ⚠️  请将备份文件保存到安全位置（U盘/NAS/云盘）"
  else red "打包失败！临时目录：$btmp"; return 1; fi
}
function _restore_volume_service() {
  local svc_label="$1" container_name="$2" volume_name="$3" backup_prefix="$4"
  echo ""; cyan "恢复：$svc_label（Docker 命名卷：$volume_name）"
  if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
    yellow "⚠️  容器 $container_name 已存在，恢复将停止容器并覆盖数据卷！"
    read -rp "确认继续？(y/n，默认 n)：" cc </dev/tty; [[ ! "${cc:-n}" =~ ^[Yy]$ ]] && { yellow "已取消。"; return 0; }
    docker stop "$container_name" &>/dev/null || true; green "  容器已停止"
  fi
  echo "  1. 手动输入路径  2. 自动扫描"; read -rp "选项 (1-2，默认 2)：" sc </dev/tty
  local barch=""
  case "${sc:-2}" in 1) read -rp "备份文件路径：" barch </dev/tty ;;
    *) yellow "扫描备份文件..."
      local found_files=(); while IFS= read -r f; do found_files+=("$f"); done < <(_scan_backup_files "$backup_prefix")
      if [[ ${#found_files[@]} -eq 0 ]]; then yellow "未找到备份文件。"; read -rp "手动输入路径：" barch </dev/tty
      else
        local i=1; for f in "${found_files[@]}"; do local sz; sz=$(du -sh "$f" 2>/dev/null | cut -f1 || echo "?")
          local ts; ts=$(echo "$f" | grep -oE '[0-9]{8}_[0-9]{6}' | sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)_\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3 \4:\5:\6/' || echo "")
          printf "  %d. %-50s [%s] %s\n" "$i" "$f" "$sz" "$ts"; i=$((i + 1)); done
        read -rp "选择编号（留空手动输入）：" fc </dev/tty
        if [[ -z "$fc" ]]; then read -rp "手动输入路径：" barch </dev/tty
        elif [[ "$fc" =~ ^[0-9]+$ && "$fc" -ge 1 && "$fc" -le ${#found_files[@]} ]]; then barch="${found_files[$((fc-1))]}"
        else red "无效选项。"; return 1; fi
      fi ;;
  esac
  [[ -z "$barch" || ! -f "$barch" ]] && { red "备份文件不存在：$barch"; return 1; }; green "使用备份：$barch"
  local rtmp="/tmp/${backup_prefix}_restore_$$"; mkdir -p "$rtmp"
  yellow "1/4 解压..."; _do_unpack "$barch" "$rtmp" || { red "解压失败。"; rm -rf "$rtmp"; return 1; }
  local rinfo; rinfo=$(find "$rtmp" -maxdepth 3 -name "backup_info.txt" | head -n1)
  [[ -z "$rinfo" ]] && { red "未找到 backup_info.txt，备份格式错误！"; rm -rf "$rtmp"; return 1; }
  local rbase; rbase=$(dirname "$rinfo"); [[ -f "$rbase/backup_info.txt" ]] && { echo ""; cyan "备份信息："; cat "$rbase/backup_info.txt"; echo ""; }
  [[ ! -d "$rbase/data" ]] && { red "备份中无 data 目录！"; rm -rf "$rtmp"; return 1; }
  yellow "2/4 准备数据卷..."
  if docker volume inspect "$volume_name" &>/dev/null; then yellow "  数据卷已存在，将覆盖..."
  else docker volume create "$volume_name" &>/dev/null && green "  数据卷已创建"; fi
  yellow "3/4 恢复数据到卷..."; if ! _copy_dir_to_volume "$rbase/data" "$volume_name"; then red "  数据卷恢复失败"; rm -rf "$rtmp"; return 1; fi; green "  数据卷恢复完成"
  rm -rf "$rtmp"; yellow "4/4 启动容器..."
  docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$" && { docker start "$container_name" &>/dev/null && green "  容器已启动" || red "  请手动：docker start $container_name"; } || yellow "  容器不存在，请通过主菜单重新部署（数据卷已恢复）。"
  echo ""; green "✅ $svc_label 恢复完成"
}
function _list_volume_service_backups() {
  local svc_label="$1" backup_prefix="$2"; echo ""; cyan "$svc_label 备份列表："
  local found=false
  while IFS= read -r f; do local sz; sz=$(du -sh "$f" 2>/dev/null | cut -f1 || echo "?")
    local ts; ts=$(echo "$f" | grep -oE '[0-9]{8}_[0-9]{6}' | sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)_\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3 \4:\5:\6/' || echo "")
    printf "  📦 %-48s [%s] %s\n" "$f" "$sz" "$ts"; found=true
  done < <(_scan_backup_files "$backup_prefix"); $found || yellow "  未找到备份文件。"
}
function configure_docker_mirror() {
  while true; do
    echo ""; cyan "Docker 镜像加速器配置"; echo "──────────────────────"
    local current_mirrors; current_mirrors=$(_read_current_mirrors)
    if [[ -n "$current_mirrors" ]]; then green "当前加速器："; while IFS= read -r m; do [[ -n "$m" ]] && echo "  ✅ $m"; done <<< "$current_mirrors"
    else yellow "当前未配置加速器"; fi
    echo ""; echo "  1. 一键测速并配置最优加速器"; echo "  2. 查看预设加速器测速"; echo "  3. 手动添加加速器地址"; echo "  4. 清除所有加速器"; echo "  5. 查看 daemon.json"; echo "  0. 返回"; echo ""
    read -rp "选项 (0-5)：" ch </dev/tty
    case "$ch" in 1) _mirror_auto_setup; press_any_key ;; 2) _mirror_test_all; press_any_key ;; 3) _mirror_add_custom; press_any_key ;; 4) _mirror_clear_all; press_any_key ;; 5) _mirror_show_daemon_json; press_any_key ;; 0) return 0 ;; *) red "无效选项。" ;; esac
  done
}
function _mirror_auto_setup() {
  echo ""; yellow "测速中，请稍候..."
  local best_mirror="" best_time=99999 results=()
  for mirror in "${DOCKERHUB_MIRRORS[@]}"; do
    printf "  %-42s" "$mirror"; local ms; ms=$(_test_registry_ms "${mirror#https://}" 5)
    if [[ "$ms" -lt 9000 ]]; then printf "\e[32m%dms\e[0m\n" "$ms"; results+=("$ms|$mirror"); [[ "$ms" -lt "$best_time" ]] && { best_time="$ms"; best_mirror="$mirror"; }
    else printf "\e[31m超时\e[0m\n"; fi
  done
  echo ""; [[ -z "$best_mirror" ]] && { red "所有加速器不可达。"; return 1; }; green "最优：$best_mirror（${best_time}ms）"
  local selected=()
  for entry in "${results[@]}"; do local ms="${entry%%|*}" url="${entry##*|}"; [[ "$ms" -lt 5000 ]] && selected+=("$url"); done
  [[ ${#selected[@]} -eq 0 ]] && selected=("$best_mirror")
  local mj="[" first=true; for m in "${selected[@]}"; do $first && mj+="\"$m\"" || mj+=", \"$m\""; first=false; done; mj+="]"
  read -rp "写入配置并重启 Docker？(y/n，默认 y)：" cf </dev/tty; [[ ! "${cf:-y}" =~ ^[Yy]$ ]] && { yellow "已取消。"; return 0; }
  _write_mirrors_to_daemon "$mj" || { red "写入失败。"; return 1; }; green "✅ 加速器已写入"; _restart_docker_daemon || return 1
  docker info 2>/dev/null | grep -A5 "Registry Mirrors" || true
}
function _mirror_test_all() {
  echo ""; cyan "预设加速器测速："; printf "  %-42s %s\n" "地址" "延迟"; printf "  %-42s %s\n" "──────────────────────────────────────────" "──────"
  for mirror in "${DOCKERHUB_MIRRORS[@]}"; do printf "  %-42s" "$mirror"; local ms; ms=$(_test_registry_ms "${mirror#https://}" 5); [[ "$ms" -lt 9000 ]] && printf "\e[32m%dms\e[0m\n" "$ms" || printf "\e[31m超时\e[0m\n"; done
}
function _mirror_add_custom() {
  echo ""; read -rp "输入加速器地址（多个空格分隔，留空取消）：" custom_input </dev/tty; [[ -z "$custom_input" ]] && { yellow "已取消。"; return 0; }
  local new_mirrors=()
  for addr in $custom_input; do if [[ "$addr" =~ ^https?:// ]]; then new_mirrors+=("$addr"); green "  添加：$addr"; else yellow "  格式错误，跳过：$addr"; fi; done
  [[ ${#new_mirrors[@]} -eq 0 ]] && { red "无有效地址。"; return 1; }
  local existing=(); while IFS= read -r m; do [[ -n "$m" ]] && existing+=("$m"); done < <(_read_current_mirrors)
  local all=("${existing[@]+"${existing[@]}"}" "${new_mirrors[@]}") seen=() unique=()
  for m in "${all[@]}"; do local dup=false; [[ ${#seen[@]} -gt 0 ]] && for s in "${seen[@]}"; do [[ "$s" == "$m" ]] && dup=true && break; done; $dup || { unique+=("$m"); seen+=("$m"); }; done
  local mj="[" first=true; for m in "${unique[@]}"; do $first && mj+="\"$m\"" || mj+=", \"$m\""; first=false; done; mj+="]"
  _write_mirrors_to_daemon "$mj" || { red "写入失败。"; return 1; }; green "✅ 加速器已添加"; _restart_docker_daemon || return 1
}
function _mirror_clear_all() {
  red "⚠️  将清除所有加速器配置！"; read -rp "确认？(y/n，默认 n)：" cf </dev/tty; [[ ! "${cf:-n}" =~ ^[Yy]$ ]] && { yellow "已取消。"; return 0; }
  _write_mirrors_to_daemon "[]" || { red "写入失败。"; return 1; }; green "✅ 加速器已清除"; _restart_docker_daemon || return 1
}
function _mirror_show_daemon_json() { local dj; dj=$(_get_daemon_json_path); echo ""; cyan "/etc/docker/daemon.json："; [[ -f "$dj" ]] && cat "$dj" || yellow "文件不存在"; }
function general_backup_menu() {
  while true; do
    echo ""; cyan "One-API / New-API / New-API Horizon 备份/恢复"; echo "──────────────────────────────────────────────"
    local s1="未部署" s2="未部署" s3="未部署" s4="未部署"
    docker ps -a --format '{{.Names}}' | grep -q "^one-api$" && s1="已部署"
    docker ps -a --format '{{.Names}}' | grep -q "^one-api-mysql$" && s2="已部署"
    docker ps -a --format '{{.Names}}' | grep -q "^new-api$" && s3="已部署"
    docker ps -a --format '{{.Names}}' | grep -q "^new-api-horizon$" && s4="已部署"
    [[ -d "$HOME/one-api-data" ]] && s1+=" [数据存在]"; [[ -d "$HOME/one-api-mysql-logs" ]] && s2+=" [数据存在]"
    [[ -d "$HOME/new-api-data" ]] && s3+=" [数据存在]"; [[ -d "$HOME/new-api-horizon-data" ]] && s4+=" [数据存在]"
    echo "  One-API SQLite   [$s1]"; echo "  1. 备份  2. 恢复  3. 列表"; echo ""
    echo "  One-API MySQL    [$s2]"; echo "  4. 备份  5. 恢复  6. 列表"; echo ""
    echo "  New-API          [$s3]"; echo "  7. 备份  8. 恢复  9. 列表"; echo ""
    echo "  New-API Horizon  [$s4]"; echo "  10. 备份  11. 恢复  12. 列表"; echo ""; echo "  0. 返回"; echo ""
    read -rp "选项 (0-12)：" ch </dev/tty
    case "$ch" in
      1) _backup_bind_service "One-API SQLite" "one-api" "$HOME/one-api-data" "oneapi-sqlite-backup" || true; press_any_key ;;
      2) _restore_bind_service "One-API SQLite" "one-api" "$HOME/one-api-data" "oneapi-sqlite-backup" || true; press_any_key ;;
      3) _list_bind_service_backups "One-API SQLite" "oneapi-sqlite-backup"; press_any_key ;;
      4) _backup_bind_service "One-API MySQL" "one-api-mysql" "$HOME/one-api-mysql-logs" "oneapi-mysql-backup" || true; press_any_key ;;
      5) _restore_bind_service "One-API MySQL" "one-api-mysql" "$HOME/one-api-mysql-logs" "oneapi-mysql-backup" || true; press_any_key ;;
      6) _list_bind_service_backups "One-API MySQL" "oneapi-mysql-backup"; press_any_key ;;
      7) _backup_bind_service "New-API" "new-api" "$HOME/new-api-data" "newapi-backup" || true; press_any_key ;;
      8) _restore_bind_service "New-API" "new-api" "$HOME/new-api-data" "newapi-backup" || true; press_any_key ;;
      9) _list_bind_service_backups "New-API" "newapi-backup"; press_any_key ;;
      10) _backup_bind_service "New-API Horizon" "new-api-horizon" "$HOME/new-api-horizon-data" "newapi-horizon-backup" || true; press_any_key ;;
      11) _restore_bind_service "New-API Horizon" "new-api-horizon" "$HOME/new-api-horizon-data" "newapi-horizon-backup" || true; press_any_key ;;
      12) _list_bind_service_backups "New-API Horizon" "newapi-horizon-backup"; press_any_key ;;
      0) return 0 ;; *) red "无效选项，请输入 0-12。" ;;
    esac
  done
}
function omniroute_backup_menu() {
  while true; do
    echo ""; cyan "OmniRoute 备份/恢复"; echo "──────────────────────────────────────────────"
    local s_docker="未部署"; docker ps -a --format '{{.Names}}' | grep -q "^omniroute$" && s_docker="已部署(Docker)"
    docker volume inspect omniroute-data &>/dev/null && s_docker+=" [卷存在]"
    echo "  OmniRoute Docker [$s_docker]"; echo "  1. 备份（数据卷导出打包）"; echo "  2. 恢复（覆盖数据卷并启动）"; echo "  3. 查看备份列表"; echo ""; echo "  0. 返回"; echo ""
    read -rp "选项 (0-3)：" ch </dev/tty
    case "$ch" in
      1) _backup_volume_service "OmniRoute" "omniroute" "omniroute-data" "omniroute-backup" || true; press_any_key ;;
      2) _restore_volume_service "OmniRoute" "omniroute" "omniroute-data" "omniroute-backup" || true; press_any_key ;;
      3) _list_volume_service_backups "OmniRoute" "omniroute-backup"; press_any_key ;;
      0) return 0 ;; *) red "无效选项，请输入 0-3。" ;;
    esac
  done
}
function freellmapi_backup_menu() {
  while true; do
    echo ""; cyan "FreeLLMAPI 备份/恢复"; yellow "⚠️  ENCRYPTION_KEY + 数据卷 必须同时迁移"; echo "──────────────────────"
    echo "  1. 备份（KEY + 数据卷 + 配置）"; echo "  2. 恢复（覆盖并自动启动）"; echo "  3. 查看备份列表"; echo "  0. 返回"; echo ""
    read -rp "选项 (0-3)：" ch </dev/tty
    case "$ch" in 1) freellmapi_backup || true; press_any_key ;; 2) freellmapi_restore || true; press_any_key ;; 3) freellmapi_list_backups; press_any_key ;; 0) return 0 ;; *) red "无效选项。" ;; esac
  done
}
function freellmapi_backup() {
  local key_file="$HOME/.freellmapi_encryption_key" compose_dir="$FREELLMAPI_COMPOSE_DIR"
  echo ""; cyan "FreeLLMAPI 数据备份"; echo "────────────────────"
  [[ ! -f "$key_file" ]] && { red "未找到 ENCRYPTION_KEY（$key_file），中止！"; return 1; }
  local pack_type; pack_type=$(_check_pack_tools); [[ "$pack_type" == "none" ]] && { red "未找到打包工具！"; return 1; }
  local backup_root; backup_root=$(_select_backup_root) || return 1; _check_disk_space "$backup_root" 51200 || return 1
  local stamp; stamp=$(date +%Y%m%d_%H%M%S)
  local bname="freellmapi-backup-${stamp}"
  local btmp="${backup_root}/${bname}"
  local barch="${backup_root}/${bname}.${pack_type}"
  mkdir -p "$btmp"; yellow "1/4 备份 ENCRYPTION_KEY..."
  cp "$key_file" "$btmp/.freellmapi_encryption_key" || { red "复制失败"; rm -rf "$btmp"; return 1; }; chmod 600 "$btmp/.freellmapi_encryption_key"; green "  KEY 已备份"
  yellow "2/4 备份配置文件..."
  [[ -f "$compose_dir/.env" ]] && cp "$compose_dir/.env" "$btmp/env_config" && green "  .env 已备份"
  [[ -f "$compose_dir/docker-compose.yml" ]] && cp "$compose_dir/docker-compose.yml" "$btmp/docker-compose.yml" && green "  docker-compose.yml 已备份"
  yellow "3/4 备份数据卷..."
  if docker volume inspect freellmapi-data &>/dev/null; then
    local was_running=false; docker ps --format '{{.Names}}' | grep -q "^freellmapi$" && was_running=true
    $was_running && { yellow "  暂停容器..."; docker stop freellmapi &>/dev/null || true; }; mkdir -p "$btmp/data"
    if ! _copy_volume_to_dir "freellmapi-data" "$btmp/data"; then red "  数据卷备份失败"; $was_running && docker start freellmapi &>/dev/null || true; rm -rf "$btmp"; return 1; fi
    if $was_running; then [[ -f "$compose_dir/docker-compose.yml" ]] && { cd "$compose_dir" || true; docker compose up -d &>/dev/null || true; cd - >/dev/null || true; } || docker start freellmapi &>/dev/null || true; green "  容器已恢复"; fi
  else yellow "  未找到 freellmapi-data 卷，跳过"; fi
  yellow "4/4 打包压缩..."
  local cur_image; cur_image=$(docker inspect freellmapi --format '{{.Config.Image}}' 2>/dev/null || echo "未知")
  cat > "$btmp/backup_info.txt" << EOF
服务名称：FreeLLMAPI
备份时间：$(date '+%Y-%m-%d %H:%M:%S')
主机名：$(hostname)
系统：${OS} / ${ARCH}
镜像版本：${cur_image}
打包格式：${pack_type}
Docker卷：freellmapi-data
EOF
  if _do_pack "$backup_root" "$bname" "$barch" "$pack_type"; then
    rm -rf "$btmp"; local size; size=$(du -sh "$barch" 2>/dev/null | cut -f1 || echo "未知")
    echo ""; green "✅ FreeLLMAPI 备份完成"; green "   文件：$barch  大小：$size"; yellow "   ⚠️  请将备份文件保存到安全位置！"
  else red "打包失败！临时目录：$btmp"; return 1; fi
}
function freellmapi_restore() {
  local key_file="$HOME/.freellmapi_encryption_key" compose_dir="$FREELLMAPI_COMPOSE_DIR"
  echo ""; cyan "FreeLLMAPI 数据恢复"; echo "────────────────────"
  if docker ps -a --format '{{.Names}}' | grep -q "^freellmapi$"; then
    yellow "⚠️  freellmapi 容器已存在，恢复将覆盖现有数据！"
    read -rp "确认继续？(y/n，默认 n)：" cc </dev/tty; [[ ! "${cc:-n}" =~ ^[Yy]$ ]] && { yellow "已取消。"; return 0; }
    [[ -f "$compose_dir/docker-compose.yml" ]] && { cd "$compose_dir" || true; docker compose down 2>/dev/null || true; cd - >/dev/null || true; }
    docker stop freellmapi &>/dev/null || true; docker rm freellmapi &>/dev/null || true; green "现有容器已清理"
  fi
  echo "  1. 手动输入路径  2. 自动扫描"; read -rp "选项 (1-2，默认 2)：" sc </dev/tty
  local barch=""
  case "${sc:-2}" in 1) read -rp "备份文件路径：" barch </dev/tty ;;
    *) yellow "扫描备份文件..."
      local found_files=(); while IFS= read -r f; do found_files+=("$f"); done < <(_scan_backup_files "freellmapi-backup")
      if [[ ${#found_files[@]} -eq 0 ]]; then yellow "未找到。"; read -rp "手动输入：" barch </dev/tty
      else
        local i=1; for f in "${found_files[@]}"; do local sz; sz=$(du -sh "$f" 2>/dev/null | cut -f1 || echo "?"); printf "  %d. %-50s [%s]\n" "$i" "$f" "$sz"; i=$((i + 1)); done
        read -rp "选择编号（留空手动输入）：" fc </dev/tty
        [[ -z "$fc" ]] && read -rp "手动输入：" barch </dev/tty || { [[ "$fc" =~ ^[0-9]+$ && "$fc" -ge 1 && "$fc" -le ${#found_files[@]} ]] && barch="${found_files[$((fc-1))]}" || { red "无效选项。"; return 1; }; }
      fi ;;
  esac
  [[ -z "$barch" || ! -f "$barch" ]] && { red "备份文件不存在：$barch"; return 1; }; green "使用：$barch"
  local rtmp="/tmp/freellmapi_restore_$$"; mkdir -p "$rtmp"
  yellow "1/5 解压..."; _do_unpack "$barch" "$rtmp" || { red "解压失败。"; rm -rf "$rtmp"; return 1; }
  local rinner; rinner=$(find "$rtmp" -maxdepth 2 -name ".freellmapi_encryption_key" | head -n1)
  [[ -z "$rinner" ]] && { red "未找到 ENCRYPTION_KEY，备份不完整！"; rm -rf "$rtmp"; return 1; }
  local rbase; rbase=$(dirname "$rinner"); green "  解压成功"
  local bak_image=""
  if [[ -f "$rbase/backup_info.txt" ]]; then cyan "备份信息："; cat "$rbase/backup_info.txt"; echo ""
    bak_image=$(grep "^镜像版本" "$rbase/backup_info.txt" | cut -d: -f2- | tr -d ' ' || true)
    if [[ -n "$bak_image" ]]; then
      read -rp "使用备份版本 $bak_image 启动？(y/n，默认 y)：" ubv </dev/tty
      if [[ ! "${ubv:-y}" =~ ^[Yy]$ ]]; then select_image_version "FreeLLMAPI" "$FREELLMAPI_IMAGE_BASE" "github" "tashfeenahmed/freellmapi" 8; bak_image="$SELECTED_IMAGE"; fi
    fi
  fi
  yellow "2/5 恢复 KEY..."
  [[ -f "$key_file" ]] && { read -rp "  当前已有 KEY，确认覆盖？(y/n，默认 y)：" ok </dev/tty; [[ ! "${ok:-y}" =~ ^[Yy]$ ]] && { rm -rf "$rtmp"; return 0; }; }
  cp "$rbase/.freellmapi_encryption_key" "$key_file"; chmod 600 "$key_file"; green "  KEY 已恢复"
  yellow "3/5 恢复配置..."; mkdir -p "$compose_dir"
  [[ -f "$rbase/env_config" ]] && { cp "$rbase/env_config" "$compose_dir/.env"; chmod 600 "$compose_dir/.env"; green "  .env 已恢复"; }
  if [[ -f "$rbase/docker-compose.yml" ]]; then cp "$rbase/docker-compose.yml" "$compose_dir/docker-compose.yml"
    [[ -n "$bak_image" ]] && sed -i "s|image:.*freellmapi.*|image: ${bak_image}|" "$compose_dir/docker-compose.yml" || true; green "  docker-compose.yml 已恢复"
  fi
  yellow "4/5 恢复数据卷..."
  if [[ -d "$rbase/data" ]]; then docker volume inspect freellmapi-data &>/dev/null && yellow "  覆盖已有数据卷..." || docker volume create freellmapi-data &>/dev/null
    _copy_dir_to_volume "$rbase/data" "freellmapi-data" || { red "数据卷恢复失败"; rm -rf "$rtmp"; return 1; }; green "  数据卷已恢复"
  else yellow "  备份中无数据卷，跳过"; fi
  rm -rf "$rtmp"; yellow "5/5 拉取镜像并启动..."
  if [[ -f "$compose_dir/docker-compose.yml" ]]; then
    local restore_image
    restore_image=$(grep -oP 'image:\s*\K\S+' "$compose_dir/docker-compose.yml" 2>/dev/null | head -1 || echo "${bak_image:-}")
    if [[ -n "$restore_image" ]]; then
      pull_image_with_retry "$restore_image" || { red "镜像拉取失败，请检查网络后重试。"; return 1; }
    fi
    cd "$compose_dir" || { red "无法进入目录：$compose_dir"; return 1; }
    docker compose up -d --no-pull 2>/dev/null || docker compose up -d && cd - >/dev/null || true; sleep 10
    if docker ps --format '{{.Names}}' | grep -q "^freellmapi$"; then local ip; ip=$(get_local_ip)
      local port; port=$(grep '^PORT=' "$compose_dir/.env" 2>/dev/null | cut -d= -f2 | tr -d ' ' || echo "3001"); [[ -z "$port" ]] && port="3001"
      echo ""; green "✅ FreeLLMAPI 恢复成功"; green "   Dashboard : http://$ip:$port"; green "   API       : http://$ip:$port/v1/chat/completions"
    else red "容器启动异常："; docker compose -f "$compose_dir/docker-compose.yml" logs --tail=30 2>/dev/null || true; fi
  else yellow "未找到 docker-compose.yml，请重新部署。"; fi
}
function freellmapi_list_backups() {
  echo ""; cyan "FreeLLMAPI 备份列表："; local found=false
  while IFS= read -r f; do local sz; sz=$(du -sh "$f" 2>/dev/null | cut -f1 || echo "?"); printf "  📦 %-48s [%s]\n" "$f" "$sz"; found=true; done < <(_scan_backup_files "freellmapi-backup")
  $found || yellow "  未找到备份文件。"
}
function backup_restore_menu() {
  while true; do
    echo ""; cyan "备份/恢复管理"; echo "──────────────"
    echo "  1. One-API / New-API / Horizon（绑定挂载卷）"; echo "  2. OmniRoute（Docker 命名卷）"; echo "  3. FreeLLMAPI（KEY + Docker 命名卷）"; echo "  0. 返回"; echo ""
    read -rp "选项 (0-3)：" ch </dev/tty
    case "$ch" in 1) general_backup_menu || true ;; 2) omniroute_backup_menu || true ;; 3) freellmapi_backup_menu || true ;; 0) return 0 ;; *) red "无效选项。" ;; esac
  done
}
function deploy_service_sqlite() {
  local cname="$1" image="$2" int_port="$3" data_name="$4" data_dir="$HOME/$data_name"
  check_existing_container "$cname" || return 1; validate_port "$int_port" || return 1; choose_network_mode; pull_image_with_retry "$image" || return 1
  [[ "$OS" == "openwrt" ]] && { yellow "OpenWrt 存储有限，数据在 $data_dir，建议挂载外部存储。"; read -rp "按 Enter 继续，Ctrl+C 退出..." </dev/tty; }
  ensure_dir_writable "$data_dir" || return 1
  local cmd=(docker run -d --name "$cname" --restart unless-stopped)
  [[ "$NETWORK_MODE" == "host" ]] && cmd+=(--network host) || cmd+=(--network bridge -p "$PORT:$int_port")
  cmd+=(-v "$data_dir:/data" -e "TZ=$DEFAULT_TZ" "$image")
  yellow "执行：${cmd[*]}"; "${cmd[@]}" || { red "启动失败！"; docker rm "$cname" &>/dev/null || true; return 1; }
  local ip; ip=$(get_local_ip); local ap=$PORT; [[ "$NETWORK_MODE" == "host" ]] && ap=$int_port
  _show_deploy_result "$cname" "$ip" "$ap" "$data_dir"
}
function _upgrade_bind_service() {
  local svc_label="$1" cname="$2" int_port="$3" data_dir="$4" img_base="$5" fetch_type="$6" fetch_src="$7"
  echo ""; cyan "升级：$svc_label"
  docker ps -a --format '{{.Names}}' | grep -q "^${cname}$" || { red "未发现容器 $cname，请先部署。"; return 1; }
  local cur_image; cur_image=$(docker inspect "$cname" --format '{{.Config.Image}}' 2>/dev/null || echo "未知"); green "当前版本：$cur_image"
  _prompt_backup_before_action "升级" || return 0
  select_image_version "$svc_label" "$img_base" "$fetch_type" "$fetch_src" 8
  local new_image="$SELECTED_IMAGE"
  if [[ "$new_image" == "$cur_image" ]]; then yellow "版本相同。"; read -rp "强制重新拉取并重启？(y/n，默认 n)：" fr </dev/tty; [[ ! "${fr:-n}" =~ ^[Yy]$ ]] && { yellow "已取消。"; return 0; }; fi
  pull_image_with_retry "$new_image" || return 1
  _capture_container_runtime "$cname"
  local nm="$RUNTIME_NM" pt="${RUNTIME_PT:-$int_port}"
  yellow "停止旧容器..."; docker stop "$cname" &>/dev/null || true; docker rm "$cname" &>/dev/null || true
  local cmd=(docker run -d --name "$cname" --restart unless-stopped)
  [[ "$nm" == "host" ]] && cmd+=(--network host) || cmd+=(--network bridge -p "${pt}:${int_port}")
  local m; for m in "${RUNTIME_MOUNTS[@]}"; do cmd+=(-v "$m"); done
  [[ ${#RUNTIME_MOUNTS[@]} -eq 0 ]] && cmd+=(-v "$data_dir:/data")
  local e; for e in "${RUNTIME_ENVS[@]}"; do cmd+=(-e "$e"); done
  cmd+=(-e "TZ=$DEFAULT_TZ" "$new_image")
  local c; for c in "${RUNTIME_CMD[@]}"; do cmd+=("$c"); done
  yellow "执行：${cmd[*]//SQL_DSN=*/SQL_DSN=***}"
  "${cmd[@]}" && green "✅ $svc_label 已升级到：$new_image" || { red "升级后启动失败。"; return 1; }
}
function deploy_one_api_sqlite() {
  echo ""; cyan "部署 One-API（SQLite）"; cyan "镜像：ghcr.io/songquanpeng/one-api"; echo ""
  check_existing_container "one-api" || return 1
  select_image_version "One-API" "$ONE_API_IMAGE_BASE" "github" "songquanpeng/one-api" 8
  deploy_service_sqlite "one-api" "$SELECTED_IMAGE" 3000 "one-api-data"
}
function deploy_one_api_mysql() {
  local cname="one-api-mysql" int_port="3000" data_dir="$HOME/one-api-mysql-logs"
  echo ""; cyan "部署 One-API（MySQL）"; cyan "镜像：ghcr.io/songquanpeng/one-api"; echo ""
  check_existing_container "$cname" || return 1
  select_image_version "One-API" "$ONE_API_IMAGE_BASE" "github" "songquanpeng/one-api" 8
  local sel_image="$SELECTED_IMAGE"; validate_port "$int_port" || return 1; choose_network_mode
  yellow "MySQL 连接信息："
  read -rp "  主机：" db_host </dev/tty; read -rp "  端口（默认 3306）：" db_port </dev/tty; db_port=${db_port:-3306}
  read -rp "  用户名：" db_user </dev/tty; read -rsp "  密码：" db_pass </dev/tty; echo; read -rp "  库名：" db_name </dev/tty
  [[ -z "$db_host" || -z "$db_user" || -z "$db_name" ]] && { red "主机/用户名/库名不能为空。"; return 1; }
  [[ ! "$db_port" =~ ^[0-9]+$ ]] && { red "端口须为数字。"; return 1; }
  local dsn="${db_user}:${db_pass}@tcp(${db_host}:${db_port})/${db_name}"
  pull_image_with_retry "$sel_image" || return 1; ensure_dir_writable "$data_dir" || return 1
  local cmd=(docker run -d --name "$cname" --restart unless-stopped)
  [[ "$NETWORK_MODE" == "host" ]] && cmd+=(--network host) || cmd+=(--network bridge -p "$PORT:$int_port")
  cmd+=(-v "$data_dir:/data" -e "TZ=$DEFAULT_TZ" -e "SQL_DSN=$dsn" "$sel_image")
  yellow "执行：${cmd[*]//SQL_DSN=*/SQL_DSN=***}"; "${cmd[@]}" || { red "启动失败！"; docker rm "$cname" &>/dev/null || true; return 1; }
  local ip; ip=$(get_local_ip); local ap=$PORT; [[ "$NETWORK_MODE" == "host" ]] && ap=$int_port
  _show_deploy_result "$cname (MySQL)" "$ip" "$ap" "$data_dir" "MySQL: ${db_user}@${db_host}:${db_port}/${db_name}"
}
function _deploy_new_api_common() {
  local cname="$1" sel_image="$2" int_port="$3" data_name="$4" svc_label="$5"
  echo ""; read -rp "数据库：(1) SQLite  (2) MySQL  (3) PostgreSQL  [默认 1]：" db_mode </dev/tty; db_mode=${db_mode:-1}
  local data_dir="$HOME/$data_name" logs_dir="$HOME/${data_name}-logs"
  validate_port "$int_port" || return 1; choose_network_mode; pull_image_with_retry "$sel_image" || return 1
  ensure_dir_writable "$data_dir" || return 1; ensure_dir_writable "$logs_dir" || return 1
  local cmd=(docker run -d --name "$cname" --restart unless-stopped)
  [[ "$NETWORK_MODE" == "host" ]] && cmd+=(--network host) || cmd+=(--network bridge -p "$PORT:$int_port")
  cmd+=(-v "$data_dir:/data" -v "$logs_dir:/app/logs" -e "TZ=$DEFAULT_TZ" --log-opt max-size=10m --log-opt max-file=3)
  local db_extra="" db_info="" label_suffix="(SQLite)"
  if [[ "$db_mode" == "2" ]]; then
    yellow "MySQL 连接信息："; read -rp "  主机：" db_host </dev/tty; read -rp "  端口（默认 3306）：" db_port </dev/tty; db_port=${db_port:-3306}
    read -rp "  用户名：" db_user </dev/tty; read -rsp "  密码：" db_pass </dev/tty; echo; read -rp "  库名：" db_name </dev/tty
    [[ -z "$db_host" || -z "$db_user" || -z "$db_name" ]] && { red "字段不能为空。"; return 1; }; [[ ! "$db_port" =~ ^[0-9]+$ ]] && { red "端口须为数字。"; return 1; }
    db_extra="${db_user}:${db_pass}@tcp(${db_host}:${db_port})/${db_name}"; db_info="MySQL: ${db_user}@${db_host}:${db_port}/${db_name}"; label_suffix="(MySQL)"; cmd+=(-e "SQL_DSN=$db_extra")
  elif [[ "$db_mode" == "3" ]]; then
    yellow "PostgreSQL 连接信息："; read -rp "  主机：" db_host </dev/tty; read -rp "  端口（默认 5432）：" db_port </dev/tty; db_port=${db_port:-5432}
    read -rp "  用户名：" db_user </dev/tty; read -rsp "  密码：" db_pass </dev/tty; echo; read -rp "  库名：" db_name </dev/tty
    [[ -z "$db_host" || -z "$db_user" || -z "$db_name" ]] && { red "字段不能为空。"; return 1; }; [[ ! "$db_port" =~ ^[0-9]+$ ]] && { red "端口须为数字。"; return 1; }
    db_extra="postgres://${db_user}:${db_pass}@${db_host}:${db_port}/${db_name}"; db_info="PgSQL: ${db_user}@${db_host}:${db_port}/${db_name}"; label_suffix="(PostgreSQL)"; cmd+=(-e "SQL_DSN=$db_extra")
  fi
  cmd+=("$sel_image" "--log-dir" "/app/logs")
  if [[ -n "$db_extra" ]]; then yellow "执行：${cmd[*]//SQL_DSN=*/SQL_DSN=***}"; else yellow "执行：${cmd[*]}"; fi
  "${cmd[@]}" || { red "启动失败！"; docker rm "$cname" &>/dev/null || true; return 1; }
  local ip; ip=$(get_local_ip); local ap=$PORT; [[ "$NETWORK_MODE" == "host" ]] && ap=$int_port
  _show_deploy_result "${svc_label} ${label_suffix}" "$ip" "$ap" "$data_dir" "$db_info"
}
function deploy_new_api() {
  echo ""; cyan "部署 New-API"; cyan "镜像：calciumion/new-api（Docker Hub）"; cyan "支持：SQLite / MySQL / PostgreSQL + 日志目录"; echo ""
  check_existing_container "new-api" || return 1
  select_image_version "New-API" "$NEW_API_IMAGE_BASE" "dockerhub" "calciumion/new-api" 8
  _deploy_new_api_common "new-api" "$SELECTED_IMAGE" 3000 "new-api-data" "New-API"
}
function deploy_new_api_horizon() {
  echo ""; cyan "部署 New-API Horizon（高性能版）⭐ 推荐"; cyan "镜像：calciumion/new-api-horizon（Docker Hub）"
  yellow "· CPU 占用降低约 5%，覆盖 One-API/New-API 全部功能"; yellow "· 支持 OpenAI / Claude / Gemini 兼容接口"; yellow "· 支持 SQLite / MySQL / PostgreSQL + 日志目录"; echo ""
  check_existing_container "new-api-horizon" || return 1
  select_image_version "New-API Horizon" "$NEW_API_HORIZON_IMAGE_BASE" "dockerhub" "calciumion/new-api-horizon" 8
  _deploy_new_api_common "new-api-horizon" "$SELECTED_IMAGE" 3000 "new-api-horizon-data" "New-API Horizon"
}
function deploy_omniroute() {
  local cname="omniroute" int_port="20128" volume_name="omniroute-data"
  echo ""; cyan "部署 OmniRoute（Docker）"; cyan "镜像：diegosouzapw/omniroute（Docker Hub）"
  yellow "· 支持 268+ AI 提供商 / 500+ 模型，智能路由自动降级"; yellow "· Token 压缩节省 15-95%，MCP Server，100% 本地运行"; echo ""
  check_existing_container "$cname" || return 1
  select_image_version "OmniRoute" "$OMNIROUTE_IMAGE_BASE" "dockerhub" "diegosouzapw/omniroute" 8
  local sel_image="$SELECTED_IMAGE" sug_port; sug_port=$(find_available_port "$int_port"); green "建议端口：$sug_port"
  local attempts=0
  while true; do
    attempts=$((attempts + 1)); [[ "$attempts" -gt 10 ]] && { red "端口输入错误次数过多。"; return 1; }
    read -rp "输入端口（留空使用 $sug_port）：" up </dev/tty; PORT=${up:-$sug_port}
    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [[ "$PORT" -lt 1 || "$PORT" -gt 65535 ]]; then red "无效端口。"; continue; fi
    local ck=""; command -v ss &>/dev/null && ck="ss -tuln"; command -v netstat &>/dev/null && ck="${ck:-netstat -tuln}"
    if [[ -n "$ck" ]] && $ck | grep -Eq "[:.\[]${PORT}[[:space:]]+"; then red "端口 $PORT 已被占用。"; continue; fi
    green "使用端口：$PORT"; break
  done
  local host_bind="127.0.0.1"; echo ""; echo "网络访问范围："; echo "  1. 仅本机（127.0.0.1：安全，推荐）"; echo "  2. 局域网（0.0.0.0：共享访问）"
  read -rp "选项 (1-2，默认 1)：" bc </dev/tty; [[ "${bc:-1}" == "2" ]] && { host_bind="0.0.0.0"; yellow "⚠️  局域网模式"; }; green "绑定地址：$host_bind"
  pull_image_with_retry "$sel_image" || return 1
  if ! docker volume inspect "$volume_name" &>/dev/null; then yellow "创建数据卷 $volume_name..."; docker volume create "$volume_name" &>/dev/null && green "  数据卷已创建" || { red "数据卷创建失败！"; return 1; }
  else yellow "  数据卷 $volume_name 已存在，复用。"; fi
  local cmd=(docker run -d --name "$cname" --restart unless-stopped --stop-timeout 40 -p "${host_bind}:${PORT}:${int_port}" -v "${volume_name}:/app/data" -e "TZ=$DEFAULT_TZ" -e "PORT=${int_port}" "$sel_image")
  yellow "执行：${cmd[*]}"; if ! "${cmd[@]}"; then red "启动失败！"; docker rm "$cname" &>/dev/null || true; return 1; fi
  yellow "等待服务启动（8 秒）..."; sleep 8
  if ! docker ps --format '{{.Names}}' | grep -q "^${cname}$"; then red "容器启动后异常退出："; docker logs --tail=30 "$cname" 2>/dev/null || true; return 1; fi
  local ip; ip=$(get_local_ip); local display_host; [[ "$host_bind" == "0.0.0.0" ]] && display_host="$ip" || display_host="localhost"
  echo ""; green "✅ OmniRoute (Docker) 部署成功"; green "   Dashboard  : http://${display_host}:${PORT}/dashboard"
  green "   API 端点   : http://${display_host}:${PORT}/v1/chat/completions"; green "   模型列表   : http://${display_host}:${PORT}/v1/models"; green "   数据卷     : $volume_name"
  yellow "   ⚠️  首次访问 Dashboard 配置 Provider API Key 后即可使用"; echo ""
}
function deploy_freellmapi() {
  local cname="freellmapi" int_port="3001" compose_dir="$FREELLMAPI_COMPOSE_DIR"
  echo ""; cyan "部署 FreeLLMAPI"; cyan "镜像：ghcr.io/tashfeenahmed/freellmapi"
  yellow "聚合多家 LLM 平台免费额度，OpenAI 兼容 /v1 端点"; red "⚠️  仅供个人实验，需出网访问各 LLM 平台"; echo ""
  check_existing_container "$cname" || return 1; command -v openssl &>/dev/null || install_dependency "openssl" "openssl" || true
  select_image_version "FreeLLMAPI" "$FREELLMAPI_IMAGE_BASE" "github" "tashfeenahmed/freellmapi" 8
  local sel_image="$SELECTED_IMAGE"; validate_port "$int_port" || return 1; local chosen_port="$PORT"
  local host_bind="127.0.0.1"; echo ""; echo "网络访问范围："; echo "  1. 仅本机（安全）"; echo "  2. 局域网"
  read -rp "选项 (1-2，默认 1)：" bc </dev/tty; [[ "${bc:-1}" == "2" ]] && { host_bind="0.0.0.0"; yellow "⚠️  局域网模式"; }; green "绑定：$host_bind"
  local key_file="$HOME/.freellmapi_encryption_key" enc_key=""
  if [[ -f "$key_file" ]]; then enc_key=$(cat "$key_file"); green "复用已有 KEY"
  else enc_key=$(openssl rand -hex 32); echo "$enc_key" > "$key_file"; chmod 600 "$key_file"; green "已生成新 KEY：$key_file"; red "⚠️  请备份此文件！"; fi
  if [[ -d "$compose_dir" ]]; then yellow "已有部署目录：$compose_dir"; read -rp "覆盖重新部署？(y/n，默认 n)：" ow </dev/tty; [[ ! "${ow:-n}" =~ ^[Yy]$ ]] && { yellow "已取消。"; return 0; }; fi
  mkdir -p "$compose_dir"
  cat > "$compose_dir/.env" << EOF
ENCRYPTION_KEY=${enc_key}
PORT=3001
HOST_BIND=${host_bind}
EOF
  chmod 600 "$compose_dir/.env"
  cat > "$compose_dir/docker-compose.yml" << EOF
services:
  freellmapi:
    image: ${sel_image}
    container_name: freellmapi
    restart: unless-stopped
    ports:
      - "${host_bind}:${chosen_port}:3001"
    volumes:
      - freellmapi-data:/app/server/data
    env_file:
      - .env
    environment:
      - TZ=${DEFAULT_TZ}
      - NODE_ENV=production
      - PORT=3001
    healthcheck:
      test:
        [
          "CMD",
          "node",
          "-e",
          "fetch('http://127.0.0.1:3001/api/ping').then((res) => { if (!res.ok) process.exit(1); }).catch(() => process.exit(1));"
        ]
      interval: 30s
      timeout: 5s
      start_period: 15s
      retries: 3
volumes:
  freellmapi-data:
    name: freellmapi-data
EOF
  green "配置已写入"; pull_image_with_retry "$sel_image" || return 1
  cd "$compose_dir" || { red "无法进入目录"; return 1; }; docker compose up -d || { red "启动失败！"; cd - >/dev/null || true; return 1; }; cd - >/dev/null || true
  yellow "等待启动（10 秒）..."; sleep 10
  if ! docker ps --format '{{.Names}}' | grep -q "^freellmapi$"; then red "容器已退出："; docker compose -f "$compose_dir/docker-compose.yml" logs --tail=30 2>/dev/null || true; return 1; fi
  local ip; ip=$(get_local_ip); local url; [[ "$host_bind" == "0.0.0.0" ]] && url="http://$ip:$chosen_port" || url="http://localhost:$chosen_port"
  echo ""; green "✅ FreeLLMAPI 部署成功"; green "   Dashboard : $url"; green "   API       : $url/v1/chat/completions"; echo ""
}
function deploy_menu() {
  while true; do
    echo ""; cyan "部署新服务"; echo "──────────────────────────────────────────────"
    echo "  1. One-API        SQLite   ghcr.io/songquanpeng/one-api"
    echo "  2. One-API        MySQL    ghcr.io/songquanpeng/one-api"
    echo "  3. New-API                 calciumion/new-api"
    echo "  4. New-API Horizon         calciumion/new-api-horizon  ⭐"
    echo "  5. OmniRoute               diegosouzapw/omniroute"
    echo "  6. FreeLLMAPI              ghcr.io/tashfeenahmed/freellmapi"; echo ""
    yellow "  💡 New-API Horizon + OmniRoute 功能互补，可同时部署"; echo ""; echo "  0. 返回"; echo ""
    read -rp "选项 (0-6)：" ch </dev/tty
    case "$ch" in 1) deploy_one_api_sqlite || true; press_any_key ;; 2) deploy_one_api_mysql || true; press_any_key ;; 3) deploy_new_api || true; press_any_key ;; 4) deploy_new_api_horizon || true; press_any_key ;; 5) deploy_omniroute || true; press_any_key ;; 6) deploy_freellmapi || true; press_any_key ;; 0) return 0 ;; *) red "无效选项。" ;; esac
  done
}
function _manage_service_menu() {
  local svc_label="$1" cname="$2" int_port="$3" data_dir="$4" img_base="$5" fetch_type="$6" fetch_src="$7" img_pat="$8" data_name="$9"
  while true; do
    echo ""; cyan "管理：$svc_label"
    docker ps -a --format '{{.Names}}' | grep -q "^${cname}$" || { yellow "未发现容器 $cname，请先部署。"; press_any_key; return 0; }
    docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" | grep -E "NAMES|^${cname}" || true; echo ""
    echo "  1. 实时日志（Ctrl+C 退出）"; echo "  2. 最近 100 行日志"; echo "  3. 停止"; echo "  4. 启动"; echo "  5. 重启"; echo "  6. 升级版本"; echo "  7. 卸载"; echo "  0. 返回"
    read -rp "选项 (0-7)：" mc </dev/tty; echo ""
    case "$mc" in
      1) docker logs -f "$cname" || true ;; 2) docker logs --tail=100 "$cname" || true; press_any_key ;; 3) docker stop "$cname" && green "✅ 已停止。" || red "停止失败。"; press_any_key ;;
      4) docker start "$cname" && green "✅ 已启动。" || red "启动失败。"; press_any_key ;; 5) docker restart "$cname" || true; sleep 3; docker ps --format "  {{.Names}} {{.Status}}" | grep "^  ${cname}" || true; press_any_key ;;
      6) _upgrade_bind_service "$svc_label" "$cname" "$int_port" "$data_dir" "$img_base" "$fetch_type" "$fetch_src" || true; press_any_key ;; 7) _uninstall_bind_service "$cname" "$data_name" "$img_pat" || true; press_any_key ;; 0) return 0 ;; *) red "无效选项。" ;;
    esac
  done
}
function manage_one_api() {
  local found_containers=()
  docker ps -a --format '{{.Names}}' | grep -q "^one-api$" && found_containers+=("one-api")
  docker ps -a --format '{{.Names}}' | grep -q "^one-api-mysql$" && found_containers+=("one-api-mysql")
  if [[ ${#found_containers[@]} -eq 0 ]]; then yellow "未发现 One-API 容器，请先部署。"; press_any_key; return 0; fi
  local target_cname="${found_containers[0]}"
  if [[ ${#found_containers[@]} -gt 1 ]]; then echo "选择操作对象："; local idx=1; for cn in "${found_containers[@]}"; do echo "  $idx. $cn"; idx=$((idx+1)); done
    read -rp "选项（默认 1）：" ci </dev/tty; ci=${ci:-1}; [[ "$ci" =~ ^[0-9]+$ && "$ci" -ge 1 && "$ci" -le ${#found_containers[@]} ]] && target_cname="${found_containers[$((ci-1))]}"; fi
  local data_name="one-api-data"; [[ "$target_cname" == "one-api-mysql" ]] && data_name="one-api-mysql-logs"
  _manage_service_menu "One-API" "$target_cname" 3000 "$HOME/$data_name" "$ONE_API_IMAGE_BASE" "github" "songquanpeng/one-api" "ghcr.io/songquanpeng/one-api" "$data_name"
}
function manage_new_api() { _manage_service_menu "New-API" "new-api" 3000 "$HOME/new-api-data" "$NEW_API_IMAGE_BASE" "dockerhub" "calciumion/new-api" "calciumion/new-api" "new-api-data"; }
function manage_new_api_horizon() { _manage_service_menu "New-API Horizon ⭐" "new-api-horizon" 3000 "$HOME/new-api-horizon-data" "$NEW_API_HORIZON_IMAGE_BASE" "dockerhub" "calciumion/new-api-horizon" "calciumion/new-api-horizon" "new-api-horizon-data"; }
function manage_omniroute() {
  local cname="omniroute" volume_name="omniroute-data" has_docker=false
  docker ps -a --format '{{.Names}}' | grep -q "^${cname}$" && has_docker=true
  while true; do
    echo ""; cyan "管理：OmniRoute"; echo ""
    $has_docker && { docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" | grep -E "NAMES|^${cname}" || true; echo ""; }
    echo "  Docker 容器操作："; echo "  1. 实时日志  2. 停止  3. 启动  4. 重启  5. 升级  6. 卸载"; echo ""; echo "  通用操作："; echo "  7. 查看数据卷信息"; echo ""; echo "  0. 返回"
    read -rp "选项：" mc </dev/tty; echo ""
    case "$mc" in
      1) $has_docker && docker logs -f "$cname" || yellow "Docker 容器不存在" ;; 2) $has_docker && { docker stop "$cname" && green "✅ 已停止"; } || yellow "Docker 容器不存在"; press_any_key ;;
      3) $has_docker && { docker start "$cname" && green "✅ 已启动"; } || yellow "Docker 容器不存在"; press_any_key ;;
      4) $has_docker && { docker stop "$cname" &>/dev/null; sleep 2; docker start "$cname" && green "✅ 已重启"; } || yellow "Docker 容器不存在"; press_any_key ;;
      5) $has_docker || { yellow "Docker 容器不存在"; press_any_key; continue; }; _prompt_backup_before_action "升级" || { press_any_key; continue; }
        local cur_image; cur_image=$(docker inspect "$cname" --format '{{.Config.Image}}' 2>/dev/null || echo "未知"); green "当前版本：$cur_image"
        select_image_version "OmniRoute" "$OMNIROUTE_IMAGE_BASE" "dockerhub" "diegosouzapw/omniroute" 8; local new_image="$SELECTED_IMAGE"
        [[ "$new_image" == "$cur_image" ]] && { yellow "版本相同"; read -rp "强制重拉？(y/n)：" fr </dev/tty; [[ ! "${fr:-n}" =~ ^[Yy]$ ]] && { press_any_key; continue; }; }
        pull_image_with_retry "$new_image" || { press_any_key; continue; }
        _capture_container_runtime "$cname"
        local bindip="${RUNTIME_BINDIP:-127.0.0.1}" pt="${RUNTIME_PT:-20128}"
        docker stop "$cname" &>/dev/null; docker rm "$cname" &>/dev/null
        local ncmd=(docker run -d --name "$cname" --restart unless-stopped --stop-timeout 40 -p "${bindip}:${pt}:20128")
        local m; for m in "${RUNTIME_MOUNTS[@]}"; do ncmd+=(-v "$m"); done
        [[ ${#RUNTIME_MOUNTS[@]} -eq 0 ]] && ncmd+=(-v "${volume_name}:/app/data")
        local e; for e in "${RUNTIME_ENVS[@]}"; do ncmd+=(-e "$e"); done
        ncmd+=(-e "TZ=$DEFAULT_TZ" "$new_image")
        "${ncmd[@]}" && green "✅ 已升级到：$new_image" || red "升级失败"; press_any_key ;;
      6) $has_docker || { yellow "Docker 容器不存在"; press_any_key; continue; }; _prompt_backup_before_action "卸载" || { press_any_key; continue; }
        docker stop "$cname" &>/dev/null; docker rm "$cname" &>/dev/null; green "  容器已删除"
        local imgs; imgs=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep "^diegosouzapw/omniroute" || true)
        [[ -n "$imgs" ]] && { echo "$imgs" | while read -r i; do echo "  镜像：$i"; done; read -rp "删除镜像？(y/n)：" di </dev/tty; [[ "${di:-n}" =~ ^[Yy]$ ]] && echo "$imgs" | xargs docker rmi 2>/dev/null; }
        docker volume inspect "$volume_name" &>/dev/null && { red "  ⚠️  删除数据卷将丢失所有配置！"; read -rp "删除数据卷？(y/n)：" dv </dev/tty; [[ "${dv:-n}" =~ ^[Yy]$ ]] && docker volume rm "$volume_name"; }
        has_docker=false; green "✅ Docker 卸载完成"; press_any_key ;;
      7) cyan "Docker 数据卷："; docker volume inspect "$volume_name" 2>/dev/null || yellow "未找到"; press_any_key ;; 0) return 0 ;; *) red "无效选项。" ;;
    esac
  done
}
function _freellmapi_upgrade_version() {
  local compose_dir="$FREELLMAPI_COMPOSE_DIR" compose_file="$compose_dir/docker-compose.yml"
  echo ""; cyan "FreeLLMAPI 版本升级"
  docker ps -a --format '{{.Names}}' | grep -q "^freellmapi$" || { yellow "未发现容器，请先部署。"; return 1; }
  local cur; cur=$(docker inspect freellmapi --format '{{.Config.Image}}' 2>/dev/null || echo "未知"); green "当前版本：$cur"
  _prompt_backup_before_action "版本切换" || return 0
  select_image_version "FreeLLMAPI" "$FREELLMAPI_IMAGE_BASE" "github" "tashfeenahmed/freellmapi" 8; local new_image="$SELECTED_IMAGE"
  [[ "$new_image" == "$cur" ]] && { yellow "版本相同"; read -rp "强制重拉？(y/n)：" fr </dev/tty; [[ ! "${fr:-n}" =~ ^[Yy]$ ]] && return 0; }
  pull_image_with_retry "$new_image" || return 1
  if [[ -f "$compose_file" ]]; then sed -i "s|image:.*freellmapi.*|image: ${new_image}|" "$compose_file" || true; cd "$compose_dir" || return 1; docker compose up -d --no-deps --no-pull freellmapi 2>/dev/null || docker compose up -d --no-deps freellmapi || true; cd - >/dev/null || true; fi
  sleep 8; docker ps --format '{{.Names}}' | grep -q "^freellmapi$" && green "✅ 切换成功" || red "容器启动异常"
}
function _freellmapi_show_setup_code() {
  cyan "查询 Setup Code..."; local result; result=$(docker logs freellmapi 2>&1 | grep -iE "code|setup|one.time|one-time|pin" || true)
  if [[ -n "$result" ]]; then green "找到相关日志："; echo "$result"; else yellow "关键词未匹配，显示启动前 80 行："; docker logs freellmapi 2>&1 | head -80 || true; fi
}
function manage_freellmapi() {
  local compose_file="$FREELLMAPI_COMPOSE_DIR/docker-compose.yml"
  while true; do
    echo ""; cyan "管理：FreeLLMAPI"
    docker ps -a --format '{{.Names}}' | grep -q "^freellmapi$" || { yellow "未发现容器，请先部署。"; press_any_key; return 0; }
    docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" | grep -E "NAMES|freellmapi" || true; echo ""
    local use_compose=false; [[ -f "$compose_file" ]] && use_compose=true
    echo "  1. 实时日志  2. 最近100行  3. 停止  4. 启动  5. 重启"; echo "  6. 升级版本  7. 数据卷  8. Setup Code  9. 卸载"; echo "  0. 返回"
    read -rp "选项 (0-9)：" mc </dev/tty; echo ""
    case "$mc" in
      1) $use_compose && docker compose -f "$compose_file" logs -f freellmapi || docker logs -f freellmapi || true ;; 2) $use_compose && docker compose -f "$compose_file" logs --tail=100 freellmapi || docker logs --tail=100 freellmapi || true; press_any_key ;;
      3) $use_compose && docker compose -f "$compose_file" stop freellmapi || docker stop freellmapi || true; green "✅ 已停止"; press_any_key ;; 4) $use_compose && docker compose -f "$compose_file" start freellmapi || docker start freellmapi || true; green "✅ 已启动"; press_any_key ;;
      5) $use_compose && docker compose -f "$compose_file" restart freellmapi || docker restart freellmapi || true; sleep 5; docker ps --format "  {{.Names}} {{.Status}}" | grep "freellmapi" || true; press_any_key ;;
      6) _freellmapi_upgrade_version || true; press_any_key ;; 7) docker volume inspect freellmapi-data &>/dev/null && docker volume inspect freellmapi-data || yellow "未找到数据卷"; press_any_key ;; 8) _freellmapi_show_setup_code; press_any_key ;;
      9) uninstall_freellmapi || true; press_any_key ;; 0) return 0 ;; *) red "无效选项。" ;;
    esac
  done
}
function _uninstall_bind_service() {
  local cname="$1" data_name="$2" img_pat="$3" data_dir="$HOME/$data_name"
  yellow "卸载：$cname"
  if docker ps -a --format '{{.Names}}' | grep -Eq "^${cname}$"; then docker stop "$cname" &>/dev/null || true; docker rm "$cname" &>/dev/null || true; green "  容器已删除"; else yellow "  未发现容器，跳过"; fi
  local imgs; imgs=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -E "^(${img_pat})" || true)
  if [[ -n "$imgs" ]]; then echo "$imgs" | while read -r i; do echo "  镜像：$i"; done; read -rp "  删除镜像？(y/n，默认 n)：" di </dev/tty; [[ "${di:-n}" =~ ^[Yy]$ ]] && echo "$imgs" | xargs docker rmi 2>/dev/null && green "  镜像已删除" || yellow "  跳过"; fi
  if [[ -d "$data_dir" ]]; then
    read -rp "  删除数据目录 $data_dir？(y/n，默认 n)：" dd </dev/tty
    if [[ "${dd:-n}" =~ ^[Yy]$ ]]; then read -rp "  先备份？(y/n，默认 n)：" bk </dev/tty; local do_del=true
      [[ "${bk:-n}" =~ ^[Yy]$ ]] && { local bdir="${data_dir}-backup-$(date +%Y%m%d_%H%M%S)"; cp -a "$data_dir" "$bdir" && green "  已备份：$bdir" || { red "  备份失败"; do_del=false; }; }
      if $do_del; then local rc="rm -rf \"$data_dir\""; [[ "$EUID" -ne 0 ]] && command -v sudo &>/dev/null && rc="sudo $rc"; eval "$rc" && green "  数据已删除" || red "  请手动：rm -rf $data_dir"; fi
    else yellow "  保留数据目录"; fi
  fi
  green "卸载完成：$cname"
}
function uninstall_freellmapi() {
  local compose_dir="$FREELLMAPI_COMPOSE_DIR" compose_file="$compose_dir/docker-compose.yml" key_file="$HOME/.freellmapi_encryption_key"
  echo ""; red "完全卸载 FreeLLMAPI"; _prompt_backup_before_action "卸载" || return 0
  read -rp "再次确认（输入 yes）：" cf </dev/tty; [[ "$cf" != "yes" ]] && { yellow "已取消。"; return 0; }
  yellow "1/6 停止并删除容器..."
  if docker ps -a --format '{{.Names}}' | grep -q "^freellmapi$"; then [[ -f "$compose_file" ]] && { cd "$compose_dir" || true; docker compose down 2>/dev/null || true; cd - >/dev/null || true; }
    docker stop freellmapi &>/dev/null || true; docker rm freellmapi &>/dev/null || true; green "  容器已删除"; fi
  yellow "2/6 删除镜像..."; local imgs; imgs=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep "^ghcr.io/tashfeenahmed/freellmapi" || true)
  [[ -n "$imgs" ]] && { read -rp "删除镜像？(y/n)：" di </dev/tty; [[ "${di:-y}" =~ ^[Yy]$ ]] && echo "$imgs" | xargs docker rmi 2>/dev/null; }
  yellow "3/6 删除数据卷..."; docker volume inspect freellmapi-data &>/dev/null && { read -rp "删除数据卷？(y/n)：" bv </dev/tty; [[ "${bv:-n}" =~ ^[Yy]$ ]] && docker volume rm freellmapi-data; }
  yellow "4/6 删除项目目录..."; [[ -d "$compose_dir" ]] && { read -rp "删除 $compose_dir？(y/n)：" dd </dev/tty; [[ "${dd:-y}" =~ ^[Yy]$ ]] && rm -rf "$compose_dir"; }
  yellow "5/6 处理 ENCRYPTION_KEY..."; [[ -f "$key_file" ]] && { red "  ⚠️  此文件是密钥唯一备份！"; read -rp "删除？(y/n)：" dk </dev/tty; [[ "${dk:-n}" =~ ^[Yy]$ ]] && rm -f "$key_file"; }
  yellow "6/6 清理悬空镜像..."; local dangling; dangling=$(docker images -f "dangling=true" -q 2>/dev/null || true)
  [[ -n "$dangling" ]] && { read -rp "清理悬空镜像？(y/n)：" cd2 </dev/tty; [[ "${cd2:-n}" =~ ^[Yy]$ ]] && docker image prune -f; }
  green "✅ FreeLLMAPI 已完全卸载"
}
function view_container_status() {
  cyan "Docker 容器："; [[ $(docker ps -a --format '{{.Names}}' | wc -l) -eq 0 ]] && yellow "  无任何容器。" || docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"
  echo ""; cyan "Docker 磁盘占用："; docker system df 2>/dev/null || true
}
function _svc_status_tag() {
  local cname="$1"
  if docker ps --format '{{.Names}}' | grep -q "^${cname}$"; then local ver; ver=$(docker inspect "$cname" --format '{{.Config.Image}}' 2>/dev/null | grep -oE '[^:]+$' || echo ""); echo "运行中 [${ver}]"
  elif docker ps -a --format '{{.Names}}' | grep -q "^${cname}$"; then echo "已停止"
  else echo "未部署"; fi
}
function manage_services_menu() {
  while true; do
    echo ""; cyan "服务管理"; echo "──────────────"
    local s1 s2 s3 s4 s5 s6
    s1=$(_svc_status_tag "one-api"); s2=$(_svc_status_tag "one-api-mysql"); s3=$(_svc_status_tag "new-api")
    s4=$(_svc_status_tag "new-api-horizon"); s5=$(_svc_status_tag "omniroute"); s6=$(_svc_status_tag "freellmapi")
    echo "  1. One-API            [$s1]"
    echo "  2. One-API (MySQL)    [$s2]"
    echo "  3. New-API            [$s3]"
    echo "  4. New-API Horizon ⭐ [$s4]"
    echo "  5. OmniRoute          [$s5]"
    echo "  6. FreeLLMAPI         [$s6]"
    echo "  0. 返回"
    read -rp "选项 (0-6)：" ch </dev/tty
    case "$ch" in
      1|2) manage_one_api || true ;;
      3) manage_new_api || true ;;
      4) manage_new_api_horizon || true ;;
      5) manage_omniroute || true ;;
      6) manage_freellmapi || true ;;
      0) return 0 ;; *) red "无效选项。" ;;
    esac
  done
}
function system_tools_menu() {
  while true; do
    echo ""; cyan "系统工具"; echo "──────────────"
    echo "  1. 查看容器状态"
    echo "  2. 镜像加速器配置"
    echo "  3. 重新检测网络"
    echo "  0. 返回"
    read -rp "选项 (0-3)：" ch </dev/tty
    case "$ch" in
      1) view_container_status || true; press_any_key ;;
      2) configure_docker_mirror || true ;;
      3) _detect_network; press_any_key ;;
      0) return 0 ;; *) red "无效选项。" ;;
    esac
  done
}
function main_menu() {
  detect_architecture; detect_os; setup_logging; check_base_dependencies
  docker info &>/dev/null && check_docker_dependencies || yellow "Docker 未安装，部分功能不可用"
  docker info &>/dev/null && check_user_permission || true; _detect_network
  [[ "$OS" == "openwrt" ]] && { yellow "OpenWrt 提示：Bash 未装请先 opkg install bash"; sleep 1; }
  while true; do
    local dv="未安装" cv="未安装"; docker --version &>/dev/null && dv=$(docker --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
    docker compose version &>/dev/null && cv=$(docker compose version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1) || { command -v docker-compose &>/dev/null && cv=$(docker-compose --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1); }
    local s1; s1=$(_svc_status_tag "one-api"); local s2; s2=$(_svc_status_tag "one-api-mysql"); local s3; s3=$(_svc_status_tag "new-api")
    local s4; s4=$(_svc_status_tag "new-api-horizon"); local s5; s5=$(_svc_status_tag "omniroute"); local s6; s6=$(_svc_status_tag "freellmapi")
    local mirror_status="未配置"; local cur_mirrors; cur_mirrors=$(_read_current_mirrors); [[ -n "$cur_mirrors" ]] && { local mc; mc=$(echo "$cur_mirrors" | grep -c 'http' || echo 0); mirror_status="已配置 ${mc} 个"; }
    local net_status=""; [[ "$GHCR_DIRECT_OK" == true ]] && net_status+="ghcr✓ " || { [[ -n "$BEST_GHCR_PROXY" ]] && net_status+="ghcr→代理 " || net_status+="ghcr✗ "; }
    [[ "$DOCKERHUB_DIRECT_OK" == true ]] && net_status+="hub✓" || { [[ -n "$BEST_DOCKERHUB_PROXY" ]] && net_status+="hub→代理" || net_status+="hub✗"; }
    echo ""; cyan "─── AI 服务管理 ────────────────────────────────────"
    echo "  系统: $OS  架构: $ARCH"; echo "  Docker: $dv  Compose: $cv"; echo "  镜像加速器: $mirror_status"; echo "  网络: $net_status"; echo ""
    echo "  One-API  (SQLite)  : $s1"; echo "  One-API  (MySQL)   : $s2"; echo "  New-API            : $s3"; echo "  New-API  Horizon ⭐: $s4"; echo "  OmniRoute          : $s5"; echo "  FreeLLMAPI         : $s6"; echo ""
    cyan "─── 操作 ──────────────────────────────────────────"
    echo "  1. 部署新服务"; echo "  2. 服务管理"; echo "  3. 备份 / 恢复"; echo "  4. 系统工具（状态/加速器/网络）"; echo "  0. 退出"; echo ""
    read -rp "选项 (0-4): " ch </dev/tty; echo ""
    case "$ch" in
      1) deploy_menu || true ;; 2) manage_services_menu || true ;; 3) backup_restore_menu || true ;; 4) system_tools_menu || true ;; 0) green "感谢使用，退出。"; exit 0 ;; *) red "无效选项，请输入 0-4。" ;;
    esac
  done
}
main_menu
