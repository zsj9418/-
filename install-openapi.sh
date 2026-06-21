#!/bin/bash

# --- 基本设置 ---
set -euo pipefail
trap 'echo -e "\n\e[31m操作被用户中断。\e[0m"; exit 1' INT

# --- 全局变量 ---
OS=""
PACKAGE_MANAGER=""
PLATFORM=""
PORT=""
NETWORK_MODE=""
LOG_FILE=""
DEFAULT_TZ="Asia/Shanghai"
TEMP_DIR="/tmp/uni_api_deploy_$(date +%s)"

# --- 服务配置常量 ---
# ⚠️ 维护提示：以下版本号请定期手动核查并更新
DEFAULT_PORT=1314

# One-API 镜像（定期到 https://github.com/songquanpeng/one-api/releases 检查最新版）
# ✅ 已更新：原为 v0.6.11-preview.1
ONE_API_IMAGE_SPECIFIC="justsong/one-api:v0.6.11-preview.1"
LATEST_ONE_API_IMAGE="ghcr.io/songquanpeng/one-api:latest"

# Duck2API 镜像
# ⛔ 警告：Duck2API 项目已于 2025-04-15 被作者归档为只读状态，停止维护。
# 镜像目前仍可拉取，但随着 DuckDuckGo 接口变动服务可能随时失效且不会修复。
# 强烈建议迁移至 New-API 或 One-API。
DUCK2API_IMAGE="ghcr.io/aurora-develop/duck2api:latest"

# Uni-API 镜像（本地构建，依赖克隆 GitHub 仓库）
# ⚠️ 注意：通过源码构建，网络不通或上游变更可能导致构建失败
UNI_API_IMAGE="uni-api:latest"

# New-API (calciumion) 镜像
NEW_API_CALCIUMION_IMAGE="calciumion/new-api:latest"

# Docker Compose 独立版兜底版本（优先动态获取最新版）
# ✅ 已更新：原为 v2.29.2
COMPOSE_FALLBACK_VERSION="v2.39.1"

# --- 日志设置 ---
function setup_logging() {
  local temp_os_check=""
  if [[ -f /etc/os-release ]]; then
    temp_os_check=$(grep '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]')
  fi

  if [[ "$temp_os_check" == "openwrt" ]] || [[ "$temp_os_check" == "libwrt" ]]; then
    LOG_FILE="/tmp/deploy_script.log"
    yellow "提示: OpenWrt/LibWRT 系统日志将写入 /tmp，重启后会丢失。"
  else
    LOG_FILE="$HOME/.deploy_script.log"
  fi

  local LOG_MAX_SIZE=3145728
  local current_size=0
  if [[ -f "$LOG_FILE" ]]; then
    current_size=$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
  fi
  if [[ "$current_size" -ge "$LOG_MAX_SIZE" ]]; then
    echo "日志文件 $LOG_FILE 超过 ${LOG_MAX_SIZE} bytes，正在清空..." > "$LOG_FILE"
  fi
  touch "$LOG_FILE" || { red "错误：无法创建或访问日志文件 $LOG_FILE"; exit 1; }
  exec > >(tee -a "$LOG_FILE") 2>&1
}

# --- 颜色输出函数 ---
function green()  { echo -e "\e[32m$1\e[0m"; }
function red()    { echo -e "\e[31m$1\e[0m"; }
function yellow() { echo -e "\e[33m$1\e[0m"; }

# --- 系统检测函数 ---
function detect_architecture() {
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64 | amd64)   PLATFORM="linux/amd64" ;;
    i386 | i686)      PLATFORM="linux/386" ;;
    armv7l | armhf)   PLATFORM="linux/arm/v7" ;;
    aarch64 | arm64)  PLATFORM="linux/arm64" ;;
    *) yellow "警告：未知的架构 ($ARCH)，将不指定 Docker 平台，可能导致拉取错误。" && PLATFORM="" ;;
  esac
  if [[ -n "$PLATFORM" ]]; then
    green "设备架构：$ARCH，适配平台：$PLATFORM"
  fi
}

function detect_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    local detected_id="${ID,,}"
    case "$detected_id" in
      ubuntu | debian | raspbian)
        OS="debian"
        PACKAGE_MANAGER="apt"
        ;;
      centos | rhel | fedora | rocky | almalinux)
        OS="$detected_id"
        if [[ -f /usr/bin/dnf ]]; then
          PACKAGE_MANAGER="dnf"
        elif [[ -f /usr/bin/yum ]]; then
          PACKAGE_MANAGER="yum"
        else
          red "错误：在 $detected_id 系统上未找到 yum 或 dnf。" && exit 1
        fi
        ;;
      arch | manjaro)
        OS="arch"
        PACKAGE_MANAGER="pacman"
        ;;
      openwrt | libwrt | nwrt | qwrt | hwrt | lede | immortalwrt | x-wrt | istoreos)
        OS="openwrt"
        PACKAGE_MANAGER="opkg"
        ;;
      *)
        OS="$detected_id"
        yellow "警告：检测到未明确支持的操作系统 ($OS)，将尝试通用方法。"
        if   command -v apt    &>/dev/null; then PACKAGE_MANAGER="apt"
        elif command -v dnf    &>/dev/null; then PACKAGE_MANAGER="dnf"
        elif command -v yum    &>/dev/null; then PACKAGE_MANAGER="yum"
        elif command -v pacman &>/dev/null; then PACKAGE_MANAGER="pacman"
        elif command -v opkg   &>/dev/null; then PACKAGE_MANAGER="opkg"
        else red "错误：无法识别的操作系统且未找到已知包管理器。" && exit 1
        fi
        ;;
    esac
  elif [[ "$(uname -s)" == "Linux" ]]; then
    yellow "警告：未找到 /etc/os-release 文件，尝试备用检测。"
    if   command -v apt    &>/dev/null; then OS="debian";  PACKAGE_MANAGER="apt"
    elif command -v dnf    &>/dev/null; then OS="fedora";  PACKAGE_MANAGER="dnf"
    elif command -v yum    &>/dev/null; then OS="centos";  PACKAGE_MANAGER="yum"
    elif command -v pacman &>/dev/null; then OS="arch";    PACKAGE_MANAGER="pacman"
    elif command -v opkg   &>/dev/null; then OS="openwrt"; PACKAGE_MANAGER="opkg"
    else red "错误：无法识别操作系统或找到包管理器。" && exit 1
    fi
  else
    red "错误：不支持的操作系统 ($(uname -s))" && exit 1
  fi
  green "操作系统识别为：$OS (包管理器: $PACKAGE_MANAGER)"
}

# --- 依赖管理函数 ---

# ✅ 修复 Bug A：防止 sudo 被重复添加（原逻辑无论命令是否已含 sudo 均会再次添加）
function install_dependency() {
  local cmd=$1
  local package_name=$2
  local install_cmd=""
  local update_cmd=""

  if command -v "$cmd" &>/dev/null; then
    green "$cmd 已安装。"
    return 0
  fi

  yellow "正在准备安装 $package_name (提供 $cmd 命令)..."

  case "$PACKAGE_MANAGER" in
    apt)
      update_cmd="apt update"
      install_cmd="apt install -y $package_name"
      ;;
    yum)
      install_cmd="yum install -y $package_name"
      ;;
    dnf)
      install_cmd="dnf install -y $package_name"
      ;;
    pacman)
      update_cmd="pacman -Syu --noconfirm"
      install_cmd="pacman -S --noconfirm $package_name"
      ;;
    opkg)
      update_cmd="opkg update"
      install_cmd="opkg install $package_name"
      ;;
    *)
      red "错误：不支持的包管理器：$PACKAGE_MANAGER"
      exit 1
      ;;
  esac

  # ✅ 修复核心：仅在非 root、非 openwrt、且命令未以 sudo 开头时才添加 sudo
  if [[ "$OS" != "openwrt" ]] && [[ "$EUID" -ne 0 ]]; then
    [[ -n "$update_cmd"  && "$update_cmd"  != sudo* ]] && update_cmd="sudo $update_cmd"
    [[ -n "$install_cmd" && "$install_cmd" != sudo* ]] && install_cmd="sudo $install_cmd"
  fi

  if [[ -n "$update_cmd" ]]; then
    yellow "执行包管理器更新命令: $update_cmd"
    if ! eval "$update_cmd"; then
      yellow "警告：包列表更新失败，将继续尝试安装。"
    fi
  fi

  yellow "执行安装命令: $install_cmd"
  if eval "$install_cmd"; then
    green "$package_name 安装成功。"
  else
    red "$package_name 安装失败，请检查错误信息并尝试手动安装。"
    exit 1
  fi
}

function check_base_dependencies() {
  if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
    yellow "curl 和 wget 都未安装，尝试安装 curl..."
    install_dependency "curl" "curl"
  elif command -v curl &>/dev/null; then
    green "curl 已安装。"
  else
    green "wget 已安装。"
  fi

  if ! command -v ss &>/dev/null && ! command -v netstat &>/dev/null; then
    yellow "端口检查工具 ss 和 netstat 都未安装。"
    local ss_pkg="iproute2"
    local netstat_pkg="net-tools"
    if [[ "$PACKAGE_MANAGER" == "opkg" ]]; then
      ss_pkg="ip-full"
      netstat_pkg="netstat"
    elif [[ "$PACKAGE_MANAGER" == "yum" ]] || [[ "$PACKAGE_MANAGER" == "dnf" ]]; then
      ss_pkg="iproute"
    fi
    yellow "尝试安装 $netstat_pkg (提供 netstat)..."
    install_dependency "netstat" "$netstat_pkg" || true
    if ! command -v netstat &>/dev/null; then
      yellow "尝试安装 $ss_pkg (提供 ss)..."
      install_dependency "ss" "$ss_pkg" || yellow "警告: 安装端口检查工具失败，端口检查可能无法工作。"
    fi
  elif command -v ss &>/dev/null; then
    green "端口检查工具 ss 已安装。"
  else
    green "端口检查工具 netstat 已安装。"
  fi
}

function check_docker_dependencies() {
  local docker_package="docker"
  local needs_repo=false

  case "$PACKAGE_MANAGER" in
    apt)
      docker_package="docker.io"
      ;;
    yum | dnf)
      if ! command -v docker &>/dev/null; then
        if ! rpm -q docker-ce &>/dev/null; then
          needs_repo=true
        fi
      fi
      docker_package="docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
      ;;
    pacman)
      docker_package="docker docker-compose"
      ;;
    opkg)
      docker_package="docker dockerd docker-compose"
      ;;
  esac

  if [[ "$needs_repo" == true ]] && [[ "$OS" != "openwrt" ]]; then
    yellow "为 CentOS/RHEL/Fedora 添加 Docker CE 仓库..."
    local repo_manager_pkg=""
    local repo_add_cmd=""
    if command -v dnf &>/dev/null; then
      repo_manager_pkg="dnf-plugins-core"
      repo_add_cmd="dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo"
      if [[ "$OS" == "centos" ]] || [[ "$OS" == "rhel" ]] || [[ "$OS" == "rocky" ]] || [[ "$OS" == "almalinux" ]]; then
        repo_add_cmd="dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo"
      fi
    elif command -v yum &>/dev/null; then
      repo_manager_pkg="yum-utils"
      repo_add_cmd="yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo"
    fi

    if [[ -n "$repo_manager_pkg" ]]; then
      install_dependency "config-manager" "$repo_manager_pkg"
      # 添加 sudo（如果需要）
      local full_repo_cmd="$repo_add_cmd"
      if [[ "$EUID" -ne 0 ]] && [[ "$full_repo_cmd" != sudo* ]]; then
        full_repo_cmd="sudo $full_repo_cmd"
      fi
      yellow "执行: $full_repo_cmd"
      eval "$full_repo_cmd" || red "添加 Docker repo 失败"
    else
      yellow "警告：无法确定用于添加仓库的命令。"
    fi
  fi

  install_dependency "docker" "$docker_package"

  if [[ "$OS" == "openwrt" ]]; then
    if ! /etc/init.d/dockerd status 2>/dev/null | grep -q "running"; then
      yellow "尝试启动并启用 Docker 服务 (OpenWrt init.d)..."
      /etc/init.d/dockerd enable || yellow "警告：无法启用 Docker 服务。"
      /etc/init.d/dockerd start  || yellow "警告：无法启动 Docker 服务，请手动检查：/etc/init.d/dockerd start"
    else
      green "Docker 服务已运行 (OpenWrt init.d)。"
    fi
  elif command -v systemctl &>/dev/null; then
    if ! systemctl is-active --quiet docker &>/dev/null; then
      yellow "尝试启动并启用 Docker 服务 (systemd)..."
      local systemctl_cmd="systemctl enable --now docker"
      if [[ "$EUID" -ne 0 ]]; then systemctl_cmd="sudo $systemctl_cmd"; fi
      eval "$systemctl_cmd" || yellow "警告：无法自动启动或启用 Docker 服务，请手动操作。"
    else
      green "Docker 服务已运行 (systemd)。"
    fi
  else
    yellow "警告：未知的服务管理器，请确保 Docker 服务已手动启动。"
  fi

  if ! docker info &>/dev/null; then
    red "错误：Docker 服务未能成功启动或无法连接。请手动检查 Docker 安装和状态。"
    exit 1
  fi

  # 检查 Docker Compose
  if docker compose version &>/dev/null; then
    green "Docker Compose 插件已安装: $(docker compose version | head -n 1)"
  elif command -v docker-compose &>/dev/null; then
    green "Docker Compose (独立版) 已安装: $(docker-compose --version)"
  else
    if [[ "$PACKAGE_MANAGER" == "opkg" ]] && opkg list-installed | grep -q "docker-compose"; then
      yellow "警告：opkg 显示 docker-compose 已安装，但命令未找到。请检查 PATH 或安装是否完整。"
    fi

    yellow "Docker Compose 未找到，尝试安装独立版..."

    # ✅ 修复：动态获取最新版本，原来硬编码为 v2.29.2，已过旧
    local compose_version
    compose_version=$(curl -sSL "https://api.github.com/repos/docker/compose/releases/latest" \
      | grep '"tag_name"' | head -n1 | cut -d'"' -f4 2>/dev/null \
      || echo "$COMPOSE_FALLBACK_VERSION")
    yellow "将安装 Docker Compose 版本: $compose_version"

    local compose_url="https://github.com/docker/compose/releases/download/${compose_version}/docker-compose-$(uname -s)-$(uname -m)"
    local install_path="/usr/local/bin/docker-compose"

    if ! [[ -d "/usr/local/bin" ]] || ! [[ -w "/usr/local/bin" ]]; then
      if [[ -d "/usr/bin" ]] && [[ -w "/usr/bin" ]]; then
        install_path="/usr/bin/docker-compose"
        yellow "将尝试安装到 /usr/bin/docker-compose"
      else
        red "错误：无法找到合适的位置安装 docker-compose。请检查权限或手动安装。"
        exit 1
      fi
    fi

    yellow "下载 Docker Compose ${compose_version} 到 $install_path ..."
    local download_cmd=""
    if command -v curl &>/dev/null; then
      download_cmd="curl -sSL \"$compose_url\" -o /tmp/docker-compose"
    elif command -v wget &>/dev/null; then
      download_cmd="wget -q \"$compose_url\" -O /tmp/docker-compose"
    else
      red "错误：需要 curl 或 wget 来下载 docker-compose。"
      exit 1
    fi

    if eval "$download_cmd"; then
      local mv_cmd="mv /tmp/docker-compose \"$install_path\""
      local chmod_cmd="chmod +x \"$install_path\""
      if [[ "$EUID" -ne 0 ]]; then
        mv_cmd="sudo $mv_cmd"
        chmod_cmd="sudo $chmod_cmd"
      fi
      if eval "$mv_cmd" && eval "$chmod_cmd"; then
        if command -v docker-compose &>/dev/null; then
          green "docker-compose $compose_version 安装成功。"
        else
          red "docker-compose 文件已移动，但命令仍未找到。请检查 PATH 环境变量。"
          exit 1
        fi
      else
        red "移动或设置 docker-compose 权限失败。"
        rm -f /tmp/docker-compose
        exit 1
      fi
    else
      red "docker-compose 下载失败，请检查网络连接或手动下载安装。"
      exit 1
    fi
  fi
}

function check_user_permission() {
  if [[ "$OS" == "openwrt" ]]; then
    if [[ "$EUID" -eq 0 ]]; then
      green "当前用户是 root，拥有 Docker 权限。"
    else
      yellow "警告：在 OpenWrt 上但未使用 root 用户 ($USER)。后续 Docker 命令可能需要手动添加 'sudo'。"
    fi
    return 0
  fi

  if [[ "$EUID" -eq 0 ]]; then
    green "当前用户是 root，拥有 Docker 权限。"
    return 0
  fi

  if groups "$USER" | grep -q '\bdocker\b'; then
    green "当前用户 ($USER) 已在 Docker 用户组中。"
  else
    yellow "警告：当前用户 ($USER) 未加入 Docker 用户组。"
    if command -v sudo &>/dev/null; then
      yellow "尝试将用户添加到 docker 组..."
      if sudo usermod -aG docker "$USER"; then
        green "已将用户 $USER 添加到 docker 组。"
        red "请完全注销并重新登录，或者运行 'newgrp docker' 命令以使组成员资格生效！"
        read -n 1 -s -r -p "按任意键继续，或按 Ctrl+C 退出并重新登录..."
        echo
      else
        red "错误：无法将用户添加到 docker 组。请手动添加或使用 sudo 运行 Docker 命令。"
      fi
    else
      red "错误：缺少 sudo 命令，无法自动将用户添加到 docker 组。请切换到 root 或手动添加。"
    fi
  fi
}

# --- 网络和端口函数 ---
function find_available_port() {
  local start_port=${1:-$DEFAULT_PORT}
  local check_cmd=""

  if command -v ss &>/dev/null; then
    check_cmd="ss -tuln"
  elif command -v netstat &>/dev/null; then
    check_cmd="netstat -tuln"
  else
    yellow "警告：未找到 ss 或 netstat 命令，无法自动检查端口占用。将直接使用建议端口。"
    echo "$start_port"
    return
  fi

  while $check_cmd | grep -Eq "[:.\[]${start_port}[[:space:]]+"; do
    ((start_port++))
    if [[ "$start_port" -gt 65535 ]]; then
      red "错误：无法找到 65535 以下的可用端口。"
      start_port=${1:-$DEFAULT_PORT}
      break
    fi
  done
  echo $start_port
}

function validate_port() {
  local initial_suggestion=${1:-$DEFAULT_PORT}
  local suggested_port
  suggested_port=$(find_available_port "$initial_suggestion")
  green "建议使用的端口：$suggested_port"
  read -p "请输入您希望使用的端口（留空使用 $suggested_port）： " user_port
  PORT=${user_port:-$suggested_port}

  if ! [[ "$PORT" =~ ^[0-9]+$ && "$PORT" -ge 1 && "$PORT" -le 65535 ]]; then
    red "端口号无效，请输入 1 到 65535 范围内的数字。"
    validate_port "$initial_suggestion"
    return
  fi

  local check_cmd=""
  if command -v ss &>/dev/null; then check_cmd="ss -tuln"
  elif command -v netstat &>/dev/null; then check_cmd="netstat -tuln"; fi

  if [[ -n "$check_cmd" ]] && $check_cmd | grep -Eq "[:.\[]${PORT}[[:space:]]+"; then
    red "端口 $PORT 已被占用，请选择其他端口。"
    validate_port "$initial_suggestion"
    return
  fi
  green "将使用端口: $PORT"
}

function choose_network_mode() {
  echo "请选择 Docker 网络模式："
  echo "  1. bridge (推荐, 容器有独立 IP, 通过端口映射访问)"
  echo "  2. host (容器共享主机网络, 性能稍好, 但端口冲突风险高)"
  read -p "请输入选项 (1-2, 默认 1): " mode_choice
  local chosen_mode=${mode_choice:-1}
  case $chosen_mode in
    1) NETWORK_MODE="bridge"; green "选择的网络模式：bridge" ;;
    2) NETWORK_MODE="host";   green "选择的网络模式：host" ;;
    *) red "无效选项，将使用默认 bridge 模式。" && NETWORK_MODE="bridge" ;;
  esac
}

function validate_network_mode() {
  case "$NETWORK_MODE" in
    bridge|host) ;;
    *) red "内部错误：无效的网络模式 '$NETWORK_MODE'" && exit 1 ;;
  esac
}

# --- Docker 操作函数 ---
function check_existing_container() {
  local name="$1"
  if docker ps -a --format '{{.Names}}' | grep -Eq "^${name}$"; then
    red "错误：名为 '$name' 的容器已存在。"
    yellow "请先使用卸载选项移除现有容器，或为新部署选择其他名称。"
    return 1
  fi
  return 0
}

function pull_image_with_retry() {
  local image=$1
  local platform_arg=""
  if [[ -n "${PLATFORM:-}" ]]; then
    platform_arg="--platform $PLATFORM"
  fi

  yellow "正在拉取镜像 $image (平台: ${PLATFORM:-自动检测})..."
  # shellcheck disable=SC2086
  if ! docker pull $platform_arg "$image"; then
    red "镜像 $image 拉取失败。"
    read -p "是否重试？(y/n，默认 n): " retry_pull
    if [[ "${retry_pull:-n}" =~ ^[Yy]$ ]]; then
      pull_image_with_retry "$image"
    else
      red "放弃拉取镜像 $image。"
      return 1
    fi
  else
    green "镜像 $image 拉取成功。"
    return 0
  fi
}

# --- 通用辅助函数：确保目录可写 ---
function ensure_dir_writable() {
  local dir="$1"
  mkdir -p "$dir"
  if ! touch "$dir/.writable_test" 2>/dev/null; then
    red "错误：数据目录 $dir 不可写，请检查权限。"
    if [[ "$EUID" -eq 0 ]] || command -v sudo &>/dev/null; then
      yellow "尝试修复目录权限..."
      local chown_cmd="chown $(id -u):$(id -g) \"$dir\""
      local chmod_cmd="chmod u+rwx \"$dir\""
      if [[ "$EUID" -ne 0 ]]; then
        chown_cmd="sudo $chown_cmd"
        chmod_cmd="sudo $chmod_cmd"
      fi
      eval "$chown_cmd" || true
      eval "$chmod_cmd" || true
      if ! touch "$dir/.writable_test" 2>/dev/null; then
        red "自动修复权限失败，请手动检查 $dir"
        return 1
      fi
      rm -f "$dir/.writable_test"
      green "目录权限已尝试修复。"
    else
      red "请手动检查 $dir 的权限。"
      return 1
    fi
  else
    rm -f "$dir/.writable_test"
    green "数据目录 $dir 可写。"
  fi
}

# --- 通用辅助函数：获取本机 IP ---
function get_local_ip() {
  local ip="<您的服务器IP>"
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || \
       ip -4 addr show scope global 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -n 1 || \
       hostname -I 2>/dev/null | awk '{print $1}' || \
       echo "$ip")
  echo "$ip"
}

# --- 通用部署服务函数 (SQLite 版本) ---
function deploy_service_sqlite() {
  local name="$1"
  local image="$2"
  local internal_port="$3"
  local data_dir_name="$4"
  local data_dir="$HOME/$data_dir_name"

  if ! check_existing_container "$name"; then return 1; fi

  validate_port "$internal_port"
  choose_network_mode
  validate_network_mode

  if ! pull_image_with_retry "$image"; then return 1; fi

  if [[ "$OS" == "openwrt" ]]; then
    yellow "警告：OpenWrt/LibWRT 存储空间有限，数据将存放在 $data_dir。"
    yellow "强烈建议将数据映射到外部存储！"
    read -p "按 Enter 继续使用默认路径，或按 Ctrl+C 退出以修改脚本..." </dev/tty
  fi

  if ! ensure_dir_writable "$data_dir"; then return 1; fi

  green "正在部署 $name (SQLite 模式)..."
  local docker_run_cmd=()
  docker_run_cmd+=(docker run -d --name "$name")
  docker_run_cmd+=(--restart always)

  if [[ "$NETWORK_MODE" == "host" ]]; then
    docker_run_cmd+=(--network host)
    yellow "使用 host 网络模式，容器将尝试监听端口 $internal_port。"
  else
    docker_run_cmd+=(--network bridge)
    docker_run_cmd+=(-p "$PORT:$internal_port")
  fi

  docker_run_cmd+=(-v "$data_dir:/data")
  docker_run_cmd+=(-e "TZ=$DEFAULT_TZ")
  docker_run_cmd+=("$image")

  yellow "执行命令: ${docker_run_cmd[*]}"
  if ! eval "${docker_run_cmd[*]}"; then
    red "容器 $name 启动失败！"
    yellow "请检查容器日志获取详细错误信息: docker logs $name"
    docker rm "$name" &>/dev/null || true
    return 1
  fi

  local access_ip
  access_ip=$(get_local_ip)
  local access_port=$PORT
  [[ "$NETWORK_MODE" == "host" ]] && access_port=$internal_port

  green "$name 部署成功！"
  green "访问地址: http://$access_ip:$access_port"
  green "数据目录: $data_dir"
  green "查看日志: docker logs $name"
  green "停止容器: docker stop $name"
  green "启动容器: docker start $name"
  green "卸载服务请使用脚本菜单。"
}

# --- 部署 One-API (MySQL) ---
function deploy_one_api_mysql() {
  local name="one-api-mysql"
  local image="$LATEST_ONE_API_IMAGE"
  local internal_port="3000"
  local data_dir_name="one-api-mysql-logs"
  local data_dir="$HOME/$data_dir_name"
  local db_host db_port db_user db_pass db_name sql_dsn

  yellow "--- 部署 One-API (使用 MySQL) ---"

  if ! check_existing_container "$name"; then return 1; fi

  validate_port "$internal_port"
  choose_network_mode
  validate_network_mode

  yellow "请输入 MySQL 数据库连接信息:"
  read -p "  数据库主机 (例如: localhost, 192.168.1.10): " db_host </dev/tty
  read -p "  数据库端口 (默认 3306): " db_port </dev/tty
  db_port=${db_port:-3306}
  read -p "  数据库用户名 (例如: root, oneapi_user): " db_user </dev/tty
  read -sp "  数据库密码: " db_pass </dev/tty
  echo
  read -p "  数据库名称 (例如: oneapi): " db_name </dev/tty

  if [[ -z "$db_host" || -z "$db_user" || -z "$db_name" ]]; then
    red "错误：数据库主机、用户名和名称不能为空。"
    return 1
  fi
  if ! [[ "$db_port" =~ ^[0-9]+$ ]]; then
    red "错误：数据库端口必须是数字。"
    return 1
  fi

  sql_dsn="${db_user}:${db_pass}@tcp(${db_host}:${db_port})/${db_name}"
  yellow "将使用的 SQL_DSN: ${db_user}:******@tcp(${db_host}:${db_port})/${db_name}"

  if ! pull_image_with_retry "$image"; then return 1; fi

  if [[ "$OS" == "openwrt" ]]; then
    yellow "警告：OpenWrt/LibWRT 存储空间有限，日志等数据将存放在 $data_dir。"
    read -p "按 Enter 继续，或按 Ctrl+C 退出..." </dev/tty
  fi

  if ! ensure_dir_writable "$data_dir"; then return 1; fi

  green "正在部署 $name (MySQL 模式)..."
  local docker_run_cmd=()
  docker_run_cmd+=(docker run -d --name "$name")
  docker_run_cmd+=(--restart always)

  if [[ "$NETWORK_MODE" == "host" ]]; then
    docker_run_cmd+=(--network host)
    yellow "使用 host 网络模式，容器将尝试监听端口 $internal_port。"
  else
    docker_run_cmd+=(--network bridge)
    docker_run_cmd+=(-p "$PORT:$internal_port")
  fi

  docker_run_cmd+=(-v "$data_dir:/data")
  docker_run_cmd+=(-e "TZ=$DEFAULT_TZ")
  docker_run_cmd+=(-e "SQL_DSN=$sql_dsn")
  docker_run_cmd+=("$image")

  yellow "执行命令: ${docker_run_cmd[*]}"
  if ! eval "${docker_run_cmd[*]}"; then
    red "容器 $name 启动失败！"
    yellow "请检查数据库连接信息是否正确，以及容器日志: docker logs $name"
    docker rm "$name" &>/dev/null || true
    return 1
  fi

  local access_ip
  access_ip=$(get_local_ip)
  local access_port=$PORT
  [[ "$NETWORK_MODE" == "host" ]] && access_port=$internal_port

  green "$name 部署成功！(使用 MySQL)"
  green "访问地址: http://$access_ip:$access_port"
  green "数据库配置: ${db_user}@${db_host}:${db_port}/${db_name}"
  green "日志/数据目录 (非数据库): $data_dir"
  green "查看日志: docker logs $name"
}

# --- 部署 Uni-API ---
# ⚠️ 注意：Uni-API 通过克隆 GitHub 仓库源码本地构建，以下情况可能导致构建失败：
#   1. 网络无法访问 GitHub
#   2. 上游 Dockerfile 或依赖发生变更
#   3. 构建环境缺少必要工具链
# 如有预构建镜像可用，建议修改 UNI_API_IMAGE 并跳过 git clone + docker build 步骤。
# 参考：https://github.com/yym68686/uni-api
function deploy_uni_api() {
  local name="uni-api"
  local image="$UNI_API_IMAGE"
  local internal_port="8000"
  local data_dir_name="uni-api-data"
  local data_dir="$HOME/$data_dir_name"
  local env_file="$data_dir/.env"

  yellow "--- 部署 Uni-API ---"
  yellow "⚠️  注意：Uni-API 将通过克隆源码本地构建，需要访问 GitHub 且构建耗时较长。"

  if ! check_existing_container "$name"; then return 1; fi

  validate_port "$internal_port"
  choose_network_mode
  validate_network_mode

  yellow "检查 git 是否安装..."
  install_dependency "git" "git"

  yellow "克隆 uni-api 仓库到临时目录 $TEMP_DIR..."
  rm -rf "$TEMP_DIR" && mkdir -p "$TEMP_DIR"
  if ! git clone https://github.com/yym68686/uni-api.git "$TEMP_DIR"; then
    red "错误：克隆 uni-api 仓库失败，请检查网络或仓库地址。"
    rm -rf "$TEMP_DIR"
    return 1
  fi

  yellow "构建 uni-api Docker 镜像 $image..."
  cd "$TEMP_DIR"
  local platform_arg=""
  [[ -n "${PLATFORM:-}" ]] && platform_arg="--platform $PLATFORM"
  # shellcheck disable=SC2086
  if ! docker build $platform_arg -t "$image" .; then
    red "错误：构建 uni-api 镜像失败，请检查 Dockerfile 或构建日志。"
    cd - >/dev/null
    rm -rf "$TEMP_DIR"
    return 1
  fi
  cd - >/dev/null
  rm -rf "$TEMP_DIR"
  green "uni-api 镜像 $image 构建成功。"

  if [[ "$OS" == "openwrt" ]]; then
    yellow "警告：OpenWrt/LibWRT 存储空间有限，数据将存放在 $data_dir。"
    yellow "强烈建议将数据映射到外部存储！"
    read -p "按 Enter 继续，或按 Ctrl+C 退出..." </dev/tty
  fi

  if ! ensure_dir_writable "$data_dir"; then return 1; fi

  yellow "uni-api 需要 .env 文件配置 API 密钥（如 OPENAI_API_KEY）。"
  read -p "是否生成示例 .env 文件？(y/n，默认 y): " env_choice </dev/tty
  if [[ "${env_choice:-y}" =~ ^[Yy]$ ]]; then
    cat > "$env_file" << 'EOF'
DATABASE_URL=sqlite:////app/data/uni_api.db
OPENAI_API_KEY=your_openai_key
ANTHROPIC_API_KEY=your_anthropic_key
GROQ_API_KEY=your_groq_key
# 添加其他 API 密钥或配置
EOF
    green "示例 .env 文件已生成：$env_file"
    yellow "请编辑 $env_file 添加有效的 API 密钥，否则服务可能无法正常工作。"
    read -p "按 Enter 继续，或按 Ctrl+C 退出以编辑 .env 文件..." </dev/tty
  fi
  if [[ ! -f "$env_file" ]]; then
    yellow "警告：未找到 .env 文件，容器可能因缺少配置而失败。"
  fi

  green "正在部署 $name..."
  local docker_run_cmd=()
  docker_run_cmd+=(docker run -d --name "$name")
  docker_run_cmd+=(--restart always)

  if [[ "$NETWORK_MODE" == "host" ]]; then
    docker_run_cmd+=(--network host)
    yellow "使用 host 网络模式，容器将监听端口 $internal_port。"
  else
    docker_run_cmd+=(--network bridge)
    docker_run_cmd+=(-p "$PORT:$internal_port")
  fi

  docker_run_cmd+=(-v "$data_dir:/app/data")
  [[ -f "$env_file" ]] && docker_run_cmd+=(-v "$env_file:/app/.env")
  docker_run_cmd+=(-e "TZ=$DEFAULT_TZ")
  docker_run_cmd+=("$image")

  yellow "执行命令: ${docker_run_cmd[*]}"
  if ! eval "${docker_run_cmd[*]}"; then
    red "容器 $name 启动失败！"
    yellow "请检查容器日志：docker logs $name"
    docker rm "$name" &>/dev/null || true
    return 1
  fi

  local access_ip
  access_ip=$(get_local_ip)
  local access_port=$PORT
  [[ "$NETWORK_MODE" == "host" ]] && access_port=$internal_port

  green "$name 部署成功！"
  green "访问地址: http://$access_ip:$access_port"
  green "数据目录: $data_dir"
  green ".env 文件: $env_file"
  green "查看日志: docker logs $name"
  yellow "请确保 $env_file 中的 API 密钥正确配置。"
}

# --- 部署 New-API (calciumion) ---
# ✅ 修复：新增 MySQL/SQLite 模式选择，原版直接调用 deploy_service_sqlite 无任何选项
function deploy_new_api_calciumion() {
  local name="new-api-calciumion"
  local image="$NEW_API_CALCIUMION_IMAGE"
  local internal_port="3000"
  local data_dir_name="new-api-calciumion-data"
  local data_dir="$HOME/$data_dir_name"

  yellow "--- 部署 New-API (calciumion/new-api:latest) ---"
  yellow "参考文档：https://docs.newapi.pro/en/docs"

  if ! check_existing_container "$name"; then return 1; fi

  # 询问数据库模式
  read -p "请选择数据库模式: (1) SQLite  (2) MySQL  [默认 1]: " db_mode_choice </dev/tty
  db_mode_choice=${db_mode_choice:-1}

  if [[ "$db_mode_choice" == "2" ]]; then
    # MySQL 模式
    validate_port "$internal_port"
    choose_network_mode
    validate_network_mode

    local db_host db_port db_user db_pass db_name sql_dsn
    yellow "请输入 MySQL 数据库连接信息:"
    read -p "  数据库主机 (例如: localhost): " db_host </dev/tty
    read -p "  数据库端口 (默认 3306): " db_port </dev/tty
    db_port=${db_port:-3306}
    read -p "  数据库用户名: " db_user </dev/tty
    read -sp "  数据库密码: " db_pass </dev/tty
    echo
    read -p "  数据库名称: " db_name </dev/tty

    if [[ -z "$db_host" || -z "$db_user" || -z "$db_name" ]]; then
      red "错误：数据库主机、用户名和名称不能为空。"
      return 1
    fi
    if ! [[ "$db_port" =~ ^[0-9]+$ ]]; then
      red "错误：数据库端口必须是数字。"
      return 1
    fi

    sql_dsn="${db_user}:${db_pass}@tcp(${db_host}:${db_port})/${db_name}"
    yellow "将使用的 SQL_DSN: ${db_user}:******@tcp(${db_host}:${db_port})/${db_name}"

    if ! pull_image_with_retry "$image"; then return 1; fi

    if [[ "$OS" == "openwrt" ]]; then
      yellow "警告：OpenWrt/LibWRT 存储空间有限，日志数据将存放在 $data_dir。"
      read -p "按 Enter 继续，或按 Ctrl+C 退出..." </dev/tty
    fi

    if ! ensure_dir_writable "$data_dir"; then return 1; fi

    green "正在部署 $name (MySQL 模式)..."
    local docker_run_cmd=()
    docker_run_cmd+=(docker run -d --name "$name")
    docker_run_cmd+=(--restart always)

    if [[ "$NETWORK_MODE" == "host" ]]; then
      docker_run_cmd+=(--network host)
      yellow "使用 host 网络模式，容器将尝试监听端口 $internal_port。"
    else
      docker_run_cmd+=(--network bridge)
      docker_run_cmd+=(-p "$PORT:$internal_port")
    fi

    docker_run_cmd+=(-v "$data_dir:/data")
    docker_run_cmd+=(-e "TZ=$DEFAULT_TZ")
    docker_run_cmd+=(-e "SQL_DSN=$sql_dsn")
    docker_run_cmd+=("$image")

    yellow "执行命令: ${docker_run_cmd[*]}"
    if ! eval "${docker_run_cmd[*]}"; then
      red "容器 $name 启动失败！"
      yellow "请检查数据库连接信息是否正确，以及容器日志: docker logs $name"
      docker rm "$name" &>/dev/null || true
      return 1
    fi

    local access_ip
    access_ip=$(get_local_ip)
    local access_port=$PORT
    [[ "$NETWORK_MODE" == "host" ]] && access_port=$internal_port

    green "$name 部署成功！(MySQL 模式)"
    green "访问地址: http://$access_ip:$access_port"
    green "数据库配置: ${db_user}@${db_host}:${db_port}/${db_name}"
    green "数据目录: $data_dir"
    green "查看日志: docker logs $name"
  else
    # SQLite 模式（默认）
    deploy_service_sqlite "$name" "$image" "$internal_port" "$data_dir_name"
  fi
}

# --- 卸载服务 (通用) ---
# ✅ 修复 Bug B：镜像名 grep 正则修复，防止 uni-api:latest 中的 tag 导致二次拼接 ":"
function uninstall_service() {
  local name="$1"
  local data_dir_name="$2"
  local data_dir="$HOME/$data_dir_name"

  yellow "--- 卸载服务: $name ---"

  local container_exists=false
  if docker ps -a --format '{{.Names}}' | grep -Eq "^${name}$"; then
    container_exists=true
    yellow "正在停止并移除容器 $name..."
    if docker stop "$name" && docker rm "$name"; then
      green "容器 $name 已成功停止并移除。"
    else
      red "错误：停止或移除容器 $name 失败。请手动检查：docker ps -a"
    fi
  else
    yellow "未发现名为 '$name' 的容器。"
  fi

  # ✅ 修复 Bug B：统一去掉 image_pattern 中可能带有的 :tag 部分，防止 grep 变成 "^name:tag:"
  local image_pattern=""
  case "$name" in
    one-api)              image_pattern="${ONE_API_IMAGE_SPECIFIC%%:*}" ;;
    one-api-latest | one-api-mysql) image_pattern="${LATEST_ONE_API_IMAGE%%:*}" ;;
    duck2api)             image_pattern="${DUCK2API_IMAGE%%:*}" ;;
    uni-api)              image_pattern="${UNI_API_IMAGE%%:*}" ;;
    new-api-calciumion)   image_pattern="${NEW_API_CALCIUMION_IMAGE%%:*}" ;;
    *) yellow "警告：无法确定 '$name' 对应的镜像名称模式，跳过镜像移除。" ;;
  esac

  if [[ -n "$image_pattern" ]]; then
    local images_to_remove
    images_to_remove=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep "^${image_pattern}:" || true)
    if [[ -n "$images_to_remove" ]]; then
      yellow "发现可能相关的镜像:"
      echo "$images_to_remove"
      read -p "是否尝试移除这些镜像？(y/n，默认 n): " confirm_rmi </dev/tty
      if [[ "${confirm_rmi:-n}" =~ ^[Yy]$ ]]; then
        # shellcheck disable=SC2086
        if docker rmi $images_to_remove; then
          green "相关镜像已尝试移除。"
        else
          yellow "警告：部分或全部相关镜像移除失败（可能正在被其他容器使用）。"
        fi
      else
        yellow "跳过移除镜像。"
      fi
    else
      yellow "未发现与 '$image_pattern' 相关的镜像。"
    fi
  fi

  if [[ -d "$data_dir" ]]; then
    yellow "发现数据目录: $data_dir"
    read -p "是否删除此数据目录及其所有内容？警告：此操作不可逆！(y/n，默认 n): " confirm_rm_data </dev/tty
    if [[ "${confirm_rm_data:-n}" =~ ^[Yy]$ ]]; then
      read -p "删除前是否备份数据目录 $data_dir？(y/n，默认 n): " backup_choice </dev/tty
      local do_delete=true
      if [[ "${backup_choice:-n}" =~ ^[Yy]$ ]]; then
        local backup_dir="${data_dir}-backup-$(date +%Y%m%d_%H%M%S)"
        yellow "正在备份数据到 $backup_dir ..."
        if cp -a "$data_dir" "$backup_dir"; then
          green "数据目录已备份到 $backup_dir。"
        else
          red "错误：备份数据目录失败！请检查权限和磁盘空间。"
          yellow "数据目录未被删除。"
          do_delete=false
        fi
      fi

      if [[ "$do_delete" == true ]]; then
        yellow "正在删除数据目录 $data_dir ..."
        local rm_cmd="rm -rf \"$data_dir\""
        if [[ "$EUID" -ne 0 ]] && command -v sudo &>/dev/null; then rm_cmd="sudo $rm_cmd"; fi
        if eval "$rm_cmd"; then
          green "数据目录 $data_dir 已删除。"
        else
          red "错误：删除数据目录 $data_dir 失败！请检查权限。"
        fi
      fi
    else
      yellow "数据目录 $data_dir 已保留。"
    fi
  elif [[ "$container_exists" == true ]]; then
    yellow "未找到关联的数据目录 $data_dir（或路径不匹配）。"
  fi

  green "卸载流程完成。"
}

# --- 服务部署快捷方式 ---
function deploy_one_api_specific() {
  deploy_service_sqlite "one-api" "$ONE_API_IMAGE_SPECIFIC" 3000 "one-api-data"
}

function deploy_latest_one_api_sqlite() {
  deploy_service_sqlite "one-api-latest" "$LATEST_ONE_API_IMAGE" 3000 "one-api-latest-data"
}

function deploy_duck2api() {
  # ⛔ 警告提示：Duck2API 已停止维护，部署前告知用户
  red    "╔══════════════════════════════════════════════════════════╗"
  red    "║  ⛔  警告：Duck2API 已于 2025-04-15 归档，停止维护！      ║"
  red    "║  镜像目前仍可拉取，但随着 DuckDuckGo 接口变动，           ║"
  red    "║  服务可能随时失效且不会有任何修复更新。                   ║"
  red    "║  强烈建议使用 New-API 或 One-API 作为替代方案。           ║"
  red    "╚══════════════════════════════════════════════════════════╝"
  read -p "您了解上述风险，是否仍要继续部署？(y/n，默认 n): " duck_confirm </dev/tty
  if [[ "${duck_confirm:-n}" =~ ^[Yy]$ ]]; then
    deploy_service_sqlite "duck2api" "$DUCK2API_IMAGE" 8080 "duck2api-data"
  else
    yellow "已取消部署 Duck2API。建议选择 New-API (选项 6) 作为替代。"
  fi
}

# --- 卸载项目菜单 ---
function uninstall_project() {
  echo "请选择要卸载的项目："
  echo "  1. One-API 特定版本 (SQLite,  容器名: one-api,             数据: $HOME/one-api-data)"
  echo "  2. One-API 最新版   (SQLite,  容器名: one-api-latest,      数据: $HOME/one-api-latest-data)"
  echo "  3. One-API 最新版   (MySQL,   容器名: one-api-mysql,       数据: $HOME/one-api-mysql-logs)"
  echo "  4. Duck2API         (⛔已归档, 容器名: duck2api,           数据: $HOME/duck2api-data)"
  echo "  5. Uni-API                    (容器名: uni-api,            数据: $HOME/uni-api-data)"
  echo "  6. New-API (calciumion)       (容器名: new-api-calciumion, 数据: $HOME/new-api-calciumion-data)"
  echo "  0. 返回主菜单"
  read -p "请输入选择（0-6）： " project_choice </dev/tty
  case $project_choice in
    1) uninstall_service "one-api"             "one-api-data" ;;
    2) uninstall_service "one-api-latest"      "one-api-latest-data" ;;
    3) uninstall_service "one-api-mysql"       "one-api-mysql-logs" ;;
    4) uninstall_service "duck2api"            "duck2api-data" ;;
    5) uninstall_service "uni-api"             "uni-api-data" ;;
    6) uninstall_service "new-api-calciumion"  "new-api-calciumion-data" ;;
    0) return ;;
    *) red "无效选项，请重新选择。" && uninstall_project ;;
  esac
}

# --- 查看容器状态 ---
# ✅ 修复 Bug C：移除 docker ps 错误使用 --size <数值> 参数（该参数为布尔开关而非数值）
function view_container_status() {
  green "--- 当前 Docker 容器状态 ---"
  if ! docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" &>/dev/null; then
    yellow "无法获取容器列表，请检查 Docker 是否运行正常。"
  elif [[ $(docker ps -a --format '{{.Names}}' | wc -l) -eq 0 ]]; then
    yellow "当前没有 Docker 容器。"
  else
    # ✅ 修复：直接输出，移除错误的 --size <数值> 用法
    docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"
  fi
  echo "-----------------------------"
}

# --- 主菜单函数 ---
function main_menu() {
  detect_architecture
  detect_os
  setup_logging
  check_base_dependencies
  check_docker_dependencies
  check_user_permission

  if [[ "$OS" == "openwrt" ]]; then
    yellow "==== OpenWrt/LibWRT 环境提示 ===="
    yellow " - 脚本使用 Bash，如果报错请先安装: opkg install bash"
    yellow " - 设备存储有限，默认数据目录在 $HOME 下，建议映射到外部存储。"
    yellow " - Docker 服务管理使用 /etc/init.d/dockerd"
    yellow "================================"
    sleep 1
  fi

  while true; do
    local docker_version_info="未运行"
    if docker --version &>/dev/null; then docker_version_info=$(docker --version); fi
    local compose_version_info="未安装"
    if docker compose version &>/dev/null; then
      compose_version_info=$(docker compose version | head -n 1)
    elif command -v docker-compose &>/dev/null; then
      compose_version_info=$(docker-compose --version)
    fi

    echo ""
    echo "========================================================"
    echo "             Docker 服务管理脚本"
    echo "          (支持 Linux & OpenWrt/LibWRT)"
    echo "========================================================"
    echo " 系统: $OS ($ARCH)"
    echo " Docker: $docker_version_info"
    echo " Compose: $compose_version_info"
    echo "--------------------------------------------------------"
    echo "请选择要执行的操作："
    echo "  1. 部署 One-API 特定版本 (SQLite)"
    echo "  2. 部署 One-API 最新版   (SQLite)"
    echo "  3. 部署 One-API 最新版   (MySQL)"
    echo "  4. 部署 Duck2API         (⛔ 已归档停止维护，不推荐)"
    echo "  5. 部署 Uni-API"
    echo "  6. 部署 New-API          (calciumion/new-api, 推荐替代 Duck2API)"
    echo "--------------------------------------------------------"
    echo "  7. 卸载服务"
    echo "  8. 查看所有容器状态"
    echo "--------------------------------------------------------"
    echo "  0. 退出脚本"
    echo "========================================================"
    read -p "请输入选项编号 (0-8): " choice </dev/tty
    echo ""

    case $choice in
      1) deploy_one_api_specific ;;
      2) deploy_latest_one_api_sqlite ;;
      3) deploy_one_api_mysql ;;
      4) deploy_duck2api ;;
      5) deploy_uni_api ;;
      6) deploy_new_api_calciumion ;;
      7) uninstall_project ;;
      8) view_container_status ;;
      0) green "感谢您的使用！脚本退出。" && exit 0 ;;
      *) red "无效选项 '$choice'，请输入 0 到 8 之间的数字。" ;;
    esac

    if [[ "$choice" != "0" ]]; then
      echo ""
      read -n 1 -s -r -p "按任意键返回主菜单..." </dev/tty
      echo ""
    fi
  done
}

# --- 脚本入口 ---
main_menu
