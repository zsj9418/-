#!/bin/bash

# -----------------------------------------------------------------------------
# Docker 服务管理脚本 (增强通用性，适配 OpenWrt)
#
# 功能:
# - 部署 One-API (SQLite/MySQL), Duck2API 等 Docker 服务
# - 自动检测系统架构和操作系统 (包括 OpenWrt)
# - 自动处理依赖安装 (apt, yum, dnf, pacman, opkg)
# - 端口自动建议与验证
# - 网络模式选择 (bridge/host)
# - 服务卸载与数据清理选项
# - 查看容器状态
#
# 注意:
# - 需要 Bash 环境 (OpenWrt 可能需手动安装: opkg install bash)
# - OpenWrt 存储有限，建议将数据卷映射到外部存储
# - OpenWrt 可能需要手动启动 Docker 服务
# -----------------------------------------------------------------------------

# --- 基本设置 ---
# 启用严格模式
set -euo pipefail
# 更友好的中断处理
trap 'echo -e "\n\e[31m操作被用户中断。\e[0m"; exit 1' INT

# --- 全局变量 ---
OS=""                   # 操作系统类型
PACKAGE_MANAGER=""      # 包管理器
PLATFORM=""             # Docker 平台架构
PORT=""                 # 选定的服务端口
NETWORK_MODE=""         # 选定的网络模式
LOG_FILE=""             # 日志文件路径
DEFAULT_TZ="Asia/Shanghai" # 默认时区

# --- 服务配置常量 ---
DEFAULT_PORT=3000
# One-API 镜像
ONE_API_IMAGE_SPECIFIC="justsong/one-api:v0.6.11-preview.1" # 保留特定版本
LATEST_ONE_API_IMAGE="ghcr.io/songquanpeng/one-api:latest"
# Duck2API 镜像
DUCK2API_IMAGE="ghcr.io/aurora-develop/duck2api:latest"

# --- 日志设置 ---
function setup_logging() {
  # 根据系统决定日志路径
  if [[ "$OS" == "openwrt" ]]; then
    LOG_FILE="/tmp/deploy_script.log" # OpenWrt 使用 /tmp
    yellow "提示: OpenWrt 系统日志将写入 /tmp，重启后会丢失。"
  else
    LOG_FILE="$HOME/.deploy_script.log"
  fi

  local LOG_MAX_SIZE=3145728 # 3MB
  # 检查日志文件大小，如果超过限制则清空
  if [[ -f "$LOG_FILE" ]] && [[ "$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)" -ge "$LOG_MAX_SIZE" ]]; then
    echo "日志文件 $LOG_FILE 超过 ${LOG_MAX_SIZE} bytes，正在清空..." > "$LOG_FILE"
  fi
  # 确保日志文件存在且可写
  touch "$LOG_FILE" || { red "错误：无法创建或访问日志文件 $LOG_FILE"; exit 1; }
  # 将标准输出和标准错误都重定向到日志文件，并同时在终端显示
  # 注意：如果系统不支持 process substitution，此行会报错
  exec > >(tee -a "$LOG_FILE") 2>&1
}

# --- 颜色输出函数 ---
function green() { echo -e "\e[32m$1\e[0m"; }
function red() { echo -e "\e[31m$1\e[0m"; }
function yellow() { echo -e "\e[33m$1\e[0m"; }

# --- 系统检测函数 ---
# 检测设备架构
function detect_architecture() {
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64 | amd64) PLATFORM="linux/amd64" ;;
    i386 | i686)    PLATFORM="linux/386" ;; # 添加 32 位 x86 支持
    armv7l | armhf) PLATFORM="linux/arm/v7" ;;
    aarch64 | arm64) PLATFORM="linux/arm64" ;;
    *) yellow "警告：未知的架构 ($ARCH)，将不指定 Docker 平台，可能导致拉取错误。" && PLATFORM="" ;;
  esac
  if [[ -n "$PLATFORM" ]]; then
      green "设备架构：$ARCH，适配平台：$PLATFORM"
  fi
}

# 检测操作系统和包管理器
function detect_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    OS="${ID,,}" # 转小写
    case "$OS" in
      ubuntu | debian | raspbian)
        PACKAGE_MANAGER="apt"
        ;;
      centos | rhel | fedora | rocky | almalinux)
        # CentOS 7 使用 yum，更高版本及 Fedora 使用 dnf
        if [[ -f /usr/bin/dnf ]]; then
            PACKAGE_MANAGER="dnf"
        elif [[ -f /usr/bin/yum ]]; then
            PACKAGE_MANAGER="yum"
        else
            red "错误：在 $ID 系统上未找到 yum 或 dnf。" && exit 1
        fi
        ;;
      arch | manjaro)
        PACKAGE_MANAGER="pacman"
        ;;
      openwrt)
        PACKAGE_MANAGER="opkg"
        ;;
      *)
        yellow "警告：检测到未明确支持的操作系统 ($ID)，将尝试通用方法。"
        # 尝试猜测包管理器
        if command -v apt &>/dev/null; then PACKAGE_MANAGER="apt";
        elif command -v dnf &>/dev/null; then PACKAGE_MANAGER="dnf";
        elif command -v yum &>/dev/null; then PACKAGE_MANAGER="yum";
        elif command -v pacman &>/dev/null; then PACKAGE_MANAGER="pacman";
        elif command -v opkg &>/dev/null; then PACKAGE_MANAGER="opkg";
        else red "错误：无法识别的操作系统且未找到已知包管理器。" && exit 1; fi
        ;;
    esac
  elif [[ "$(uname -s)" == "Linux" ]]; then
      # 备用检测，如果 /etc/os-release 不存在
      if command -v apt &>/dev/null; then OS="debian"; PACKAGE_MANAGER="apt";
      elif command -v dnf &>/dev/null; then OS="fedora"; PACKAGE_MANAGER="dnf";
      elif command -v yum &>/dev/null; then OS="centos"; PACKAGE_MANAGER="yum";
      elif command -v pacman &>/dev/null; then OS="arch"; PACKAGE_MANAGER="pacman";
      elif command -v opkg &>/dev/null; then OS="openwrt"; PACKAGE_MANAGER="opkg";
      else red "错误：无法识别操作系统或找到包管理器。" && exit 1; fi
  else
      red "错误：不支持的操作系统 ($(uname -s))" && exit 1
  fi
  green "操作系统：$OS (包管理器: $PACKAGE_MANAGER)"
}

# --- 依赖管理函数 ---
# 通用依赖安装函数
function install_dependency() {
  local cmd=$1
  local package_name=$2
  local install_cmd=""
  local update_cmd=""
  local install_options="-y" # 默认自动确认

  if command -v $cmd &>/dev/null; then
    green "$cmd 已安装。"
    return 0
  fi

  yellow "正在准备安装 $package_name (提供 $cmd 命令)..."

  case "$PACKAGE_MANAGER" in
    apt)
      update_cmd="sudo apt update"
      install_cmd="sudo apt install $install_options $package_name"
      ;;
    yum)
      # yum 不需要单独的 update 命令，install 会处理
      install_cmd="sudo yum install $install_options $package_name"
      ;;
    dnf)
      # dnf 也不需要单独的 update
      install_cmd="sudo dnf install $install_options $package_name"
      ;;
    pacman)
      update_cmd="sudo pacman -Syu --noconfirm" # Arch 推荐更新整个系统
      install_cmd="sudo pacman -S --noconfirm $package_name"
      install_options="" # pacman 的 --noconfirm 在 -S 后面
      ;;
    opkg)
      update_cmd="opkg update"
      install_cmd="opkg install $package_name" # opkg 通常在 root 下运行，无需 sudo
      install_options="" # opkg 没有统一的 -y 选项
      ;;
    *)
      red "错误：不支持的包管理器：$PACKAGE_MANAGER"
      exit 1
      ;;
  esac

  # 执行更新命令（如果需要）
  if [[ -n "$update_cmd" ]]; then
      yellow "执行包管理器更新命令: $update_cmd"
      if ! eval "$update_cmd"; then
          yellow "警告：包列表更新失败，将继续尝试安装。"
      fi
  fi

  # 执行安装命令
  yellow "执行安装命令: $install_cmd"
  if eval "$install_cmd"; then
      green "$package_name 安装成功。"
  else
      red "$package_name 安装失败，请检查错误信息并尝试手动安装。"
      exit 1
  fi
}

# 检查并安装基础依赖 (curl/wget, net-tools/iproute2)
function check_base_dependencies() {
    # 检查 curl 或 wget
    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        yellow "curl 和 wget 都未安装，尝试安装 curl..."
        install_dependency "curl" "curl"
    elif command -v curl &>/dev/null; then
        green "curl 已安装。"
    else
        green "wget 已安装。" # 至少有一个就行
    fi

    # 检查端口检查工具 ss 或 netstat
    if ! command -v ss &>/dev/null && ! command -v netstat &>/dev/null; then
        yellow "端口检查工具 ss 和 netstat 都未安装。"
        if [[ "$PACKAGE_MANAGER" == "opkg" ]]; then
            yellow "尝试安装 ip-full (提供 ss)..."
            install_dependency "ss" "ip-full" # OpenWrt 上 ss 在 ip-full 包
        elif [[ "$PACKAGE_MANAGER" == "apt" ]]; then
             yellow "尝试安装 net-tools (提供 netstat) 和 iproute2 (提供 ss)..."
             install_dependency "netstat" "net-tools" || true # 允许失败
             install_dependency "ss" "iproute2" || yellow "警告: 安装端口检查工具失败，端口检查可能无法工作。"
        elif [[ "$PACKAGE_MANAGER" == "yum" ]] || [[ "$PACKAGE_MANAGER" == "dnf" ]]; then
             yellow "尝试安装 net-tools (提供 netstat) 和 iproute (提供 ss)..."
             install_dependency "netstat" "net-tools" || true
             install_dependency "ss" "iproute" || yellow "警告: 安装端口检查工具失败，端口检查可能无法工作。"
        elif [[ "$PACKAGE_MANAGER" == "pacman" ]]; then
             yellow "尝试安装 net-tools (提供 netstat) 和 iproute2 (提供 ss)..."
             install_dependency "netstat" "net-tools" || true
             install_dependency "ss" "iproute2" || yellow "警告: 安装端口检查工具失败，端口检查可能无法工作。"
        else
             yellow "警告: 无法自动安装端口检查工具 (ss/netstat)，端口检查可能无法工作。"
        fi
    elif command -v ss &>/dev/null; then
        green "端口检查工具 ss 已安装。"
    else
        green "端口检查工具 netstat 已安装。"
    fi
}


# 检查并安装 Docker 和 Docker Compose
function check_docker_dependencies() {
  # 检查 Docker
  local docker_package="docker" # 默认包名
  local needs_repo=false

  case "$PACKAGE_MANAGER" in
    apt)
      docker_package="docker.io"
      ;;
    yum | dnf)
      # RHEL/CentOS/Fedora 推荐使用官方仓库
      if ! command -v docker &>/dev/null; then
        if ! rpm -q docker-ce &>/dev/null; then
            needs_repo=true
        fi
      fi
      docker_package="docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
      ;;
    pacman)
      docker_package="docker docker-compose" # Arch 通常一起安装
      ;;
    opkg)
      docker_package="docker dockerd docker-compose" # OpenWrt 可能需要这些
      ;;
  esac

  # 添加 Docker 官方仓库 (如果需要)
  if [[ "$needs_repo" == true ]]; then
      yellow "为 CentOS/RHEL/Fedora 添加 Docker CE 仓库..."
      install_dependency "yum-config-manager" "yum-utils" # RHEL/CentOS
      install_dependency "dnf-plugins-core" "dnf-plugins-core" # Fedora
      if command -v yum-config-manager &>/dev/null; then
         sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo || red "添加 Docker repo 失败 (yum)"
      elif command -v dnf &>/dev/null; then
         sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo || red "添加 Docker repo 失败 (dnf)"
      fi
  fi

  # 安装 Docker
  install_dependency "docker" "$docker_package"

  # 启动并启用 Docker 服务 (Linux only)
  if [[ "$OS" != "openwrt" ]] && [[ "$(uname -s)" == "Linux" ]]; then
      if ! systemctl is-active --quiet docker &>/dev/null; then
          yellow "尝试启动并启用 Docker 服务 (systemd)..."
          sudo systemctl enable --now docker || yellow "警告：无法自动启动或启用 Docker 服务，请手动操作。"
      else
           green "Docker 服务已运行 (systemd)。"
      fi
  elif [[ "$OS" == "openwrt" ]]; then
      # OpenWrt 使用 init.d
      if ! /etc/init.d/dockerd status &>/dev/null || ! /etc/init.d/dockerd status | grep -q "running"; then
           yellow "尝试启动并启用 Docker 服务 (OpenWrt init.d)..."
           /etc/init.d/dockerd enable || yellow "警告：无法启用 Docker 服务。"
           /etc/init.d/dockerd start || yellow "警告：无法启动 Docker 服务，请手动检查：/etc/init.d/dockerd start"
      else
           green "Docker 服务已运行 (OpenWrt init.d)。"
      fi
  fi
   # 再次检查 Docker 是否真的在运行
   if ! docker info &>/dev/null; then
       red "错误：Docker 服务未能成功启动或无法连接。请手动检查 Docker 安装和状态。"
       exit 1
   fi


  # 检查 Docker Compose (作为插件或独立二进制文件)
  if docker compose version &>/dev/null; then
      green "Docker Compose 插件已安装。"
  elif command -v docker-compose &>/dev/null; then
      green "Docker Compose (独立版) 已安装。"
  else
      yellow "Docker Compose 未找到，尝试安装独立版..."
      local compose_version="v2.29.2" # 可以更新为最新稳定版
      local compose_url="https://github.com/docker/compose/releases/download/${compose_version}/docker-compose-$(uname -s)-$(uname -m)"
      local install_path="/usr/local/bin/docker-compose" # 优先安装到这里
      # 如果 /usr/local/bin 不存在或不可写，尝试 /usr/bin
      if ! [[ -d "/usr/local/bin" ]] || ! [[ -w "/usr/local/bin" ]]; then
          if [[ -w "/usr/bin" ]]; then
             install_path="/usr/bin/docker-compose"
          else
             red "错误：无法找到合适的位置安装 docker-compose (尝试了 /usr/local/bin 和 /usr/bin)。请检查权限或手动安装。"
             exit 1
          fi
      fi

      yellow "下载 Docker Compose ${compose_version} 到 $install_path ..."
      # 使用 curl 或 wget 下载
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
          # 移动并设置权限
          if [[ "$OS" == "openwrt" ]] || [[ "$EUID" -eq 0 ]]; then
              # OpenWrt 或已经是 root
              mv /tmp/docker-compose "$install_path"
              chmod +x "$install_path"
          else
              sudo mv /tmp/docker-compose "$install_path"
              sudo chmod +x "$install_path"
          fi

          if command -v docker-compose &>/dev/null; then
              green "docker-compose 安装成功。"
          else
              red "docker-compose 安装失败，请手动安装。"
              exit 1
          fi
      else
          red "docker-compose 下载失败，请检查网络连接或手动下载安装。"
          exit 1
      fi
  fi
}

# 检查用户权限 (对 OpenWrt 简化)
function check_user_permission() {
  # OpenWrt 通常以 root 运行，无需检查
  if [[ "$OS" == "openwrt" ]]; then
      green "在 OpenWrt 上，通常以 root 运行，跳过 Docker 用户组检查。"
      return 0
  fi

  # 检查是否 root 用户
  if [[ "$EUID" -eq 0 ]]; then
      green "当前用户是 root，拥有 Docker 权限。"
      return 0
  fi

  # 检查是否在 docker 组
  if groups "$USER" | grep -q '\bdocker\b'; then
    green "当前用户已在 Docker 用户组中。"
  else
    yellow "警告：当前用户 ($USER) 未加入 Docker 用户组。"
    yellow "尝试将用户添加到 docker 组..."
    if sudo usermod -aG docker "$USER"; then
        green "已将用户 $USER 添加到 docker 组。"
        red "请完全注销并重新登录，或者运行 'newgrp docker' 命令以使组成员资格生效，否则后续 Docker 命令可能失败！"
        read -n 1 -s -r -p "按任意键继续，或按 Ctrl+C 退出并重新登录..."
        echo
    else
        red "错误：无法将用户添加到 docker 组。请手动添加或使用 sudo 运行 Docker 命令。"
        # 允许继续，但可能会失败
    fi
  fi
}

# --- 网络和端口函数 ---
# 自动分配可用端口
function find_available_port() {
  local start_port=${1:-$DEFAULT_PORT}
  local check_cmd=""

  # 选择可用的端口检查命令
  if command -v ss &>/dev/null; then
      check_cmd="ss -tuln"
  elif command -v netstat &>/dev/null; then
      check_cmd="netstat -tuln"
  else
      yellow "警告：未找到 ss 或 netstat 命令，无法自动检查端口占用。将直接使用建议端口。"
      echo "$start_port"
      return
  fi

  # 循环查找未被占用的端口
  while $check_cmd | grep -q ":$start_port "; do
    ((start_port++))
  done
  echo $start_port
}

# 验证端口
function validate_port() {
  local suggested_port
  suggested_port=$(find_available_port "${1:-$DEFAULT_PORT}")
  green "建议使用的端口：$suggested_port"
  read -p "请输入您希望使用的端口（留空使用 $suggested_port）： " user_port
  PORT=${user_port:-$suggested_port} # 设置全局 PORT

  if ! [[ "$PORT" =~ ^[0-9]+$ && "$PORT" -ge 1 && "$PORT" -le 65535 ]]; then
    red "端口号无效，请输入 1 到 65535 范围内的数字。"
    validate_port "$suggested_port" # 重新验证
    return
  fi

  # 再次检查最终选择的端口是否被占用 (如果检查命令可用)
  local check_cmd=""
  if command -v ss &>/dev/null; then check_cmd="ss -tuln";
  elif command -v netstat &>/dev/null; then check_cmd="netstat -tuln"; fi

  if [[ -n "$check_cmd" ]] && $check_cmd | grep -q ":$PORT "; then
      red "端口 $PORT 已被占用，请选择其他端口。"
      validate_port "$suggested_port" # 重新验证
      return
  fi
  green "将使用端口: $PORT"
}

# 提供网络模式选择
function choose_network_mode() {
  echo "请选择 Docker 网络模式："
  echo "  1. bridge (推荐, 容器有独立 IP, 通过端口映射访问)"
  echo "  2. host (容器共享主机网络, 性能稍好, 但端口冲突风险高)"
  read -p "请输入选项 (1-2, 默认 1): " mode
  NETWORK_MODE=${mode:-1} # 设置全局 NETWORK_MODE
  case $NETWORK_MODE in
    1) NETWORK_MODE="bridge"; green "选择的网络模式：bridge"; ;;
    2) NETWORK_MODE="host"; green "选择的网络模式：host"; ;;
    *) red "无效选项，将使用默认 bridge 模式。" && NETWORK_MODE="bridge" ;;
  esac
}

# 验证网络模式 (内部检查)
function validate_network_mode() {
  case "$NETWORK_MODE" in
    bridge|host) ;;
    *) red "内部错误：无效的网络模式 '$NETWORK_MODE'" && exit 1 ;;
  esac
}

# --- Docker 操作函数 ---
# 检查是否存在同名容器
function check_existing_container() {
  local name="$1"
  if docker ps -a --format '{{.Names}}' | grep -Eq "^${name}$"; then
    red "错误：名为 '$name' 的容器已存在。"
    yellow "请先使用卸载选项移除现有容器，或为新部署选择其他名称（如果脚本支持）。"
    return 1 # 返回失败状态码
  fi
  return 0 # 返回成功状态码
}

# 拉取镜像函数（带重试和平台指定）
function pull_image_with_retry() {
    local image=$1
    local platform_arg=""
    # 如果 PLATFORM 已定义且非空，则添加 --platform 参数
    if [[ -n "${PLATFORM:-}" ]]; then
        platform_arg="--platform $PLATFORM"
    fi

    yellow "正在拉取镜像 $image (平台: ${PLATFORM:-自动检测})..."
    # shellcheck disable=SC2086 # platform_arg 可能为空，需要 unquoted
    if ! docker pull $platform_arg "$image"; then
        red "镜像 $image 拉取失败。"
        read -p "是否重试？(y/n，默认 n): " retry
        if [[ "$retry" =~ ^[Yy]$ ]]; then
            pull_image_with_retry "$image" # 递归调用
        else
            red "放弃拉取镜像 $image。"
            return 1 # 返回失败
        fi
    else
        green "镜像 $image 拉取成功。"
        return 0 # 返回成功
    fi
}

# 通用部署服务函数 (SQLite 版本)
# 参数: name, image, internal_port, data_dir_name
function deploy_service_sqlite() {
  local name="$1"
  local image="$2"
  local internal_port="$3"
  local data_dir_name="$4"
  local data_dir # 本地数据目录完整路径

  # 1. 检查容器名冲突
  if ! check_existing_container "$name"; then return 1; fi

  # 2. 端口和网络模式
  validate_port "$internal_port" # 设置全局 PORT
  choose_network_mode # 设置全局 NETWORK_MODE
  validate_network_mode

  # 3. 拉取镜像
  if ! pull_image_with_retry "$image"; then return 1; fi

  # 4. 创建数据目录（使用绝对路径）
  # OpenWrt 警告
  if [[ "$OS" == "openwrt" ]]; then
      yellow "警告：OpenWrt 存储空间有限，数据将存放在 $HOME/$data_dir_name。"
      yellow "强烈建议将数据映射到外部存储！"
      read -p "按 Enter 继续使用默认路径，或按 Ctrl+C 退出以修改脚本..."
  fi
  data_dir="$HOME/$data_dir_name" # 将数据目录放在用户主目录下
  yellow "确保数据目录存在: $data_dir"
  mkdir -p "$data_dir"
  # 检查目录是否可写
  if ! [[ -w "$data_dir" ]]; then
      red "错误：数据目录 $data_dir 不可写，请检查权限。"
      # 尝试修复权限 (如果是 root 或 sudo)
      if [[ "$EUID" -eq 0 ]] || command -v sudo &>/dev/null; then
          yellow "尝试修复目录权限..."
          chown "$(id -u):$(id -g)" "$data_dir" || sudo chown "$(id -u):$(id -g)" "$data_dir" || true
          chmod u+rwx "$data_dir" || true
          if ! [[ -w "$data_dir" ]]; then
              red "自动修复权限失败，请手动检查 $data_dir"
              return 1
          fi
          green "目录权限已尝试修复。"
      else
          red "请手动检查 $data_dir 的权限。"
          return 1
      fi
  fi


  # 5. 构建并执行 docker run 命令
  green "正在部署 $name (SQLite 模式)..."
  local docker_run_cmd=()
  docker_run_cmd+=(docker run -d --name "$name")
  docker_run_cmd+=(--restart always)

  # 网络模式
  if [[ "$NETWORK_MODE" == "host" ]]; then
    docker_run_cmd+=(--network host)
    yellow "使用 host 网络模式，容器将尝试监听端口 $internal_port。"
  else # bridge 模式
    docker_run_cmd+=(--network bridge)
    docker_run_cmd+=(-p "$PORT:$internal_port") # 使用验证后的 PORT
  fi

  # 添加数据卷和时区
  docker_run_cmd+=(-v "$data_dir:/data")
  docker_run_cmd+=(-e "TZ=$DEFAULT_TZ")
  # 添加平台参数（如果支持）
  # if [[ -n "$PLATFORM" ]]; then
  #    docker_run_cmd+=(--platform "$PLATFORM") # run 命令通常不需要 platform
  # fi
  docker_run_cmd+=("$image")

  # 执行命令
  yellow "执行命令: ${docker_run_cmd[*]}"
  if ! eval "${docker_run_cmd[*]}"; then
      red "容器 $name 启动失败！"
      yellow "请检查容器日志获取详细错误信息: docker logs $name"
      # 尝试清理失败的容器
      docker rm "$name" &>/dev/null || true
      return 1
  fi

  # 6. 部署成功后的提示
  green "$name 部署成功！"
  local access_ip="<您的服务器IP>"
  # 尝试获取 IP (可能不准确，尤其是在 NAT 或多网卡环境下)
  if command -v ip &>/dev/null; then
      access_ip=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -vE '^127\.' | head -n 1 || echo "$access_ip")
  elif command -v hostname &>/dev/null && hostname -I &>/dev/null; then
      access_ip=$(hostname -I | awk '{print $1}' || echo "$access_ip")
  fi

  local access_port=$PORT
  if [[ "$NETWORK_MODE" == "host" ]]; then
      access_port=$internal_port # Host 模式下，访问端口是容器内部监听的端口
      green "访问地址 (host 模式): http://$access_ip:$access_port"
  else
      green "访问地址 (bridge 模式): http://$access_ip:$access_port"
  fi
  green "数据目录: $data_dir"
  green "查看容器日志: docker logs $name"
  green "停止容器: docker stop $name"
  green "启动容器: docker start $name"
  green "卸载服务请使用脚本菜单。"
}

# 部署 One-API 使用 MySQL 的函数
function deploy_one_api_mysql() {
  local name="one-api-mysql" # 固定容器名
  local image="$LATEST_ONE_API_IMAGE" # 使用最新镜像
  local internal_port="3000" # One-API 默认端口
  local data_dir_name="one-api-mysql-logs" # 数据目录名 (只存日志等非DB数据)
  local data_dir # 本地数据目录完整路径
  local db_host db_port db_user db_pass db_name sql_dsn

  yellow "--- 部署 One-API (使用 MySQL) ---"

  # 1. 检查容器名冲突
  if ! check_existing_container "$name"; then return 1; fi

  # 2. 端口和网络模式
  validate_port "$internal_port" # 设置全局 PORT
  choose_network_mode # 设置全局 NETWORK_MODE
  validate_network_mode

  # 3. 获取 MySQL 连接信息
  yellow "请输入 MySQL 数据库连接信息:"
  read -p "  数据库主机 (例如: localhost, 192.168.1.10): " db_host
  read -p "  数据库端口 (默认 3306): " db_port
  db_port=${db_port:-3306}
  read -p "  数据库用户名 (例如: root, oneapi_user): " db_user
  read -sp "  数据库密码: " db_pass # -s 静默输入
  echo # 换行
  read -p "  数据库名称 (例如: oneapi): " db_name

  # 基本验证
  if [[ -z "$db_host" || -z "$db_user" || -z "$db_name" ]]; then
      red "错误：数据库主机、用户名和名称不能为空。"
      return 1
  fi
   if ! [[ "$db_port" =~ ^[0-9]+$ ]]; then
       red "错误：数据库端口必须是数字。"
       return 1
   fi
   # 密码可以为空

  # 构造 SQL_DSN 字符串
  sql_dsn="${db_user}:${db_pass}@tcp(${db_host}:${db_port})/${db_name}"
  yellow "将使用的 SQL_DSN: ${db_user}:******@tcp(${db_host}:${db_port})/${db_name}" # 不显示密码

  # 4. 拉取镜像
  if ! pull_image_with_retry "$image"; then return 1; fi

  # 5. 创建数据目录 (用于存储非数据库数据，如日志)
  # OpenWrt 警告
  if [[ "$OS" == "openwrt" ]]; then
      yellow "警告：OpenWrt 存储空间有限，日志等数据将存放在 $HOME/$data_dir_name。"
      read -p "按 Enter 继续，或按 Ctrl+C 退出..."
  fi
  data_dir="$HOME/$data_dir_name"
  yellow "确保日志/数据目录存在: $data_dir"
  mkdir -p "$data_dir"
   if ! [[ -w "$data_dir" ]]; then
      red "错误：数据目录 $data_dir 不可写，请检查权限。"
      # 尝试修复
      if [[ "$EUID" -eq 0 ]] || command -v sudo &>/dev/null; then
          chown "$(id -u):$(id -g)" "$data_dir" || sudo chown "$(id -u):$(id -g)" "$data_dir" || true
          chmod u+rwx "$data_dir" || true
          if ! [[ -w "$data_dir" ]]; then red "自动修复权限失败！"; return 1; fi
          green "目录权限已尝试修复。"
      else
          red "请手动检查 $data_dir 权限。"
          return 1
      fi
  fi

  # 6. 构建并执行 docker run 命令
  green "正在部署 $name (MySQL 模式)..."
  local docker_run_cmd=()
  docker_run_cmd+=(docker run -d --name "$name")
  docker_run_cmd+=(--restart always)

  # 网络模式
  if [[ "$NETWORK_MODE" == "host" ]]; then
    docker_run_cmd+=(--network host)
    yellow "使用 host 网络模式，容器将尝试监听端口 $internal_port。"
  else # bridge 模式
    docker_run_cmd+=(--network bridge)
    docker_run_cmd+=(-p "$PORT:$internal_port")
  fi

  # 添加数据卷、时区和 MySQL DSN 环境变量
  docker_run_cmd+=(-v "$data_dir:/data") # 映射 /data 目录
  docker_run_cmd+=(-e "TZ=$DEFAULT_TZ")
  docker_run_cmd+=(-e "SQL_DSN=$sql_dsn") # 添加 MySQL 连接字符串
  docker_run_cmd+=("$image")

  # 执行命令
  yellow "执行命令: ${docker_run_cmd[*]}" # 注意 DSN 中的密码会显示在这里，但日志中已隐藏
  if ! eval "${docker_run_cmd[*]}"; then
      red "容器 $name 启动失败！"
      yellow "请检查数据库连接信息是否正确，以及容器日志: docker logs $name"
      docker rm "$name" &>/dev/null || true
      return 1
  fi

  # 7. 部署成功提示
  green "$name 部署成功！(使用 MySQL)"
  local access_ip="<您的服务器IP>"
  if command -v ip &>/dev/null; then
      access_ip=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -vE '^127\.' | head -n 1 || echo "$access_ip")
  elif command -v hostname &>/dev/null && hostname -I &>/dev/null; then
      access_ip=$(hostname -I | awk '{print $1}' || echo "$access_ip")
  fi
  local access_port=$PORT
  if [[ "$NETWORK_MODE" == "host" ]]; then
      access_port=$internal_port
      green "访问地址 (host 模式): http://$access_ip:$access_port"
  else
      green "访问地址 (bridge 模式): http://$access_ip:$access_port"
  fi
  green "数据库配置: ${db_user}@${db_host}:${db_port}/${db_name}"
  green "日志/数据目录 (非数据库): $data_dir"
  green "查看容器日志: docker logs $name"
}

# 卸载服务 (通用)
# 参数: name, data_dir_name
function uninstall_service() {
  local name="$1"
  local data_dir_name="$2"
  local data_dir="$HOME/$data_dir_name" # 推断数据目录路径

  yellow "--- 卸载服务: $name ---"

  local container_exists=false
  # 检查容器是否存在
  if docker ps -a --format '{{.Names}}' | grep -Eq "^${name}$"; then
      container_exists=true
      yellow "正在停止并移除容器 $name..."
      if docker stop "$name" && docker rm "$name"; then
          green "容器 $name 已成功停止并移除。"
      else
          red "错误：停止或移除容器 $name 失败。请手动检查：docker ps -a"
          # 即使失败也继续尝试删除镜像和数据
      fi
  else
    yellow "未发现名为 '$name' 的容器。"
  fi

  # 尝试查找并移除与服务相关的镜像 (基于镜像名关键字)
  local image_pattern=""
  case "$name" in
      one-api) image_pattern=$(echo "$ONE_API_IMAGE_SPECIFIC" | cut -d: -f1) ;; # justsong/one-api
      one-api-latest | one-api-mysql) image_pattern=$(echo "$LATEST_ONE_API_IMAGE" | cut -d: -f1) ;; # ghcr.io/songquanpeng/one-api
      duck2api) image_pattern=$(echo "$DUCK2API_IMAGE" | cut -d: -f1) ;; # ghcr.io/aurora-develop/duck2api
      *) yellow "警告：无法确定 '$name' 对应的镜像名称模式，跳过镜像移除。" ;;
  esac

  if [[ -n "$image_pattern" ]]; then
      local images_to_remove
      images_to_remove=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep "$image_pattern" || true)
      if [[ -n "$images_to_remove" ]]; then
           yellow "发现可能相关的镜像:"
           echo "$images_to_remove"
           read -p "是否尝试移除这些镜像？(y/n，默认 n): " confirm_rmi
           if [[ "$confirm_rmi" =~ ^[Yy]$ ]]; then
               # shellcheck disable=SC2086 # images_to_remove 可能包含多个镜像
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


  # 处理数据目录
  if [[ -d "$data_dir" ]]; then
    yellow "发现数据目录: $data_dir"
    read -p "是否删除此数据目录及其所有内容？警告：此操作不可逆！(y/n，默认 n): " confirm_rm_data
    if [[ "$confirm_rm_data" =~ ^[Yy]$ ]]; then
      # 提供备份选项
      read -p "删除前是否备份数据目录 $data_dir？(y/n，默认 n): " backup
      if [[ "$backup" =~ ^[Yy]$ ]]; then
        local backup_dir="${data_dir}-backup-$(date +%Y%m%d_%H%M%S)"
        yellow "正在备份数据到 $backup_dir ..."
        if mv "$data_dir" "$backup_dir"; then
            green "数据目录已备份到 $backup_dir。"
        else
            red "错误：备份数据目录失败！请检查权限。"
            yellow "数据目录未被删除。"
            # 如果备份失败，则不进行删除
            confirm_rm_data="n"
        fi
      fi

      # 再次确认备份后是否删除 (如果用户选了备份且备份成功)
      if [[ "$confirm_rm_data" =~ ^[Yy]$ ]]; then
          yellow "正在删除数据目录 $data_dir ..."
          if rm -rf "$data_dir"; then
              green "数据目录 $data_dir 已删除。"
          else
              red "错误：删除数据目录 $data_dir 失败！请检查权限。"
          fi
      fi
    else
      yellow "数据目录 $data_dir 已保留。"
    fi
  elif [[ "$container_exists" == true ]]; then
       # 如果容器存在但目录不存在，也提示一下
       yellow "未找到关联的数据目录 $data_dir（或路径不匹配）。"
  fi

  green "卸载流程完成。"
}

# --- 服务部署/卸载快捷方式 ---
# 部署特定版本 One-API (SQLite)
function deploy_one_api_specific() {
  deploy_service_sqlite "one-api" "$ONE_API_IMAGE_SPECIFIC" 3000 "one-api-data"
}

# 部署最新版 One-API (SQLite)
function deploy_latest_one_api_sqlite() {
  deploy_service_sqlite "one-api-latest" "$LATEST_ONE_API_IMAGE" 3000 "one-api-latest-data"
}

# 部署 Duck2API
function deploy_duck2api() {
  deploy_service_sqlite "duck2api" "$DUCK2API_IMAGE" 8080 "duck2api-data"
}

# 卸载项目菜单
function uninstall_project() {
  echo "请选择要卸载的项目："
  echo "  1. One-API 特定版本 (SQLite, 容器名: one-api, 数据: $HOME/one-api-data)"
  echo "  2. One-API 最新版 (SQLite, 容器名: one-api-latest, 数据: $HOME/one-api-latest-data)"
  echo "  3. One-API 最新版 (MySQL, 容器名: one-api-mysql, 日志/数据: $HOME/one-api-mysql-logs)"
  echo "  4. Duck2API (容器名: duck2api, 数据: $HOME/duck2api-data)"
  echo "  0. 返回主菜单"
  read -p "请输入选择（0-4）： " project_choice
  case $project_choice in
    1) uninstall_service "one-api" "one-api-data" ;;
    2) uninstall_service "one-api-latest" "one-api-latest-data" ;;
    3) uninstall_service "one-api-mysql" "one-api-mysql-logs" ;; # 注意数据目录名不同
    4) uninstall_service "duck2api" "duck2api-data" ;;
    0) return ;;
    *) red "无效选项，请重新选择。" && uninstall_project ;;
  esac
}

# 查看所有容器状态
function view_container_status() {
  green "--- 当前 Docker 容器状态 ---"
  if ! docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" &>/dev/null; then
      yellow "无法获取容器列表，请检查 Docker 是否运行正常。"
  elif [[ $(docker ps -a --format '{{.Names}}' | wc -l) -eq 0 ]]; then
      yellow "当前没有 Docker 容器。"
  else
      docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"
  fi
  echo "-----------------------------"
}

# --- 主菜单函数 ---
function main_menu() {
  # 初始化检查
  detect_architecture
  detect_os
  setup_logging # 在检测到 OS 后设置日志
  check_base_dependencies # 检查 curl/wget, ss/netstat
  check_docker_dependencies # 检查并安装 Docker 和 Compose
  check_user_permission # 检查 Docker 用户组权限

  # OpenWrt 特定提示
  if [[ "$OS" == "openwrt" ]]; then
      yellow "==== OpenWrt 环境提示 ===="
      yellow " - 脚本使用 Bash，如果报错请先安装: opkg install bash"
      yellow " - 设备存储有限，默认数据目录在 /root 下，建议映射到外部存储。"
      yellow " - Docker 服务可能需要手动启动: /etc/init.d/dockerd start"
      yellow "=========================="
      sleep 2 # 短暂暂停让用户看到
  fi


  while true; do
    echo ""
    echo "========================================"
    echo "        Docker 服务管理脚本"
    echo "       (支持 Linux & OpenWrt)"
    echo "========================================"
    echo " 系统: $OS ($ARCH) | Docker: $(docker --version || echo 未运行) | Compose: $(docker compose version 2>/dev/null || docker-compose --version 2>/dev/null || echo 未安装)"
    echo "----------------------------------------"
    echo "请选择要执行的操作："
    echo "  1. 部署 One-API 特定版本 (SQLite)"
    echo "  2. 部署 One-API 最新版 (SQLite)"
    echo "  3. 部署 One-API 最新版 (使用 MySQL)"
    echo "  4. 部署 Duck2API"
    echo "----------------------------------------"
    echo "  5. 卸载服务"
    echo "  6. 查看所有容器状态"
    echo "----------------------------------------"
    echo "  0. 退出脚本"
    echo "========================================"
    read -p "请输入选项编号 (0-6): " choice

    # 添加换行增加可读性
    echo ""

    case $choice in
      1) deploy_one_api_specific ;;
      2) deploy_latest_one_api_sqlite ;;
      3) deploy_one_api_mysql ;;
      4) deploy_duck2api ;;
      5) uninstall_project ;;
      6) view_container_status ;;
      0) green "感谢您的使用！脚本退出。" && exit 0 ;;
      *) red "无效选项 '$choice'，请输入 0 到 6 之间的数字。" ;;
    esac

    # 在每次操作后暂停，让用户看到输出
    if [[ "$choice" != "0" ]]; then
        echo ""
        read -n 1 -s -r -p "按任意键返回主菜单..."
        echo "" # 换行
    fi
    # clear # 清屏使菜单更清晰 (可选，根据喜好取消注释)
  done
}

# --- 脚本入口 ---
# 清屏开始 (可选)
# clear
main_menu
