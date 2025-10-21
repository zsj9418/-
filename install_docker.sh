#!/bin/bash
set -o pipefail

#====================== 基本配置 ======================#

# 必需依赖（脚本自身 + Docker 运行时）与可选依赖
# 将所有依赖集中于此，一次性安装
REQ_DEPS=("curl" "wget" "jq" "iptables" "nftables" "iproute2" "ca-certificates")
OPT_DEPS=("fzf")

DOCKER_VERSIONS_URL="https://download.docker.com/linux/static/stable/"
COMPOSE_RELEASES_URL="https://api.github.com/repos/docker/compose/releases"

# 代理前缀（按顺序尝试）
PROXY_PREFIXES=(
  "https://ghproxy.com/"
  "https://mirror.ghproxy.com/"
)

# 默认镜像加速源（daemon.json 用）
REGISTRY_MIRRORS_DEFAULT=(
  "https://docker.m.daocloud.io"
  "https://hub.rat.dev"
  "https://dockerpull.com"
)

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# 全局变量
INSTALL_STATUS=$(mktemp)
DOCKER_URL=""
DOCKER_INSTALL_DIR=""
ARCH=""
OS=""
PKG_MANAGER=""
FORCE_LEGACY_DOCKER="false"
RECOMMENDED_LEGACY_DOCKER_VERSION="27.3.1"


#====================== 通用工具函数 ======================#

check_sudo() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}此脚本需要 root 权限运行。请使用 sudo 或切换到 root。${NC}"
    exit 1
  fi
}

detect_package_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt-get"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
  else
    echo -e "${RED}未检测到受支持的包管理器（apt-get/dnf/yum）。${NC}"
    exit 1
  fi
}

# 按不同包管理器安装所有依赖（必需 + 可选），只在脚本启动时执行一次
install_dependencies() {
  echo "正在检测并安装所有缺失的依赖..."
  local missing_req_deps=()
  for dep in "${REQ_DEPS[@]}"; do
    if ! command -v "$dep" >/dev/null 2>&1; then
      missing_req_deps+=("$dep")
    fi
  done

  local missing_opt_deps=()
  for dep in "${OPT_DEPS[@]}"; do
    if ! command -v "$dep" >/dev/null 2>&1; then
      missing_opt_deps+=("$dep")
    fi
  done

  # 如果没有任何依赖缺失，则直接返回
  if [ ${#missing_req_deps[@]} -eq 0 ] && [ ${#missing_opt_deps[@]} -eq 0 ]; then
    echo -e "${GREEN}所有依赖均已安装。${NC}"
    return 0
  fi

  # 只有在需要安装时才执行包管理器操作
  case "$PKG_MANAGER" in
    apt-get)
      apt-get update || true
      if [ ${#missing_req_deps[@]} -gt 0 ]; then
        echo "正在安装必需依赖: ${missing_req_deps[*]}"
        apt-get install -y --no-install-recommends "${missing_req_deps[@]}" || {
          echo -e "${RED}安装必需依赖失败${NC}"; exit 1; }
      fi
      if [ ${#missing_opt_deps[@]} -gt 0 ]; then
        echo "正在安装可选依赖: ${missing_opt_deps[*]}"
        apt-get install -y --no-install-recommends "${missing_opt_deps[@]}" 2>/dev/null || true
      fi
      ;;
    dnf|yum)
      if [ ${#missing_req_deps[@]} -gt 0 ]; then
        echo "正在安装必需依赖: ${missing_req_deps[*]}"
        "${PKG_MANAGER}" install -y "${missing_req_deps[@]}" || {
          echo -e "${RED}安装必需依赖失败${NC}"; exit 1; }
      fi
      if [ ${#missing_opt_deps[@]} -gt 0 ]; then
        echo "正在安装可选依赖: ${missing_opt_deps[*]}"
        "${PKG_MANAGER}" install -y "${missing_opt_deps[@]}" 2>/dev/null || true
      fi
      ;;
  esac
}

get_architecture() {
  local m=$(uname -m)
  case "$m" in
    x86_64) ARCH="x86_64" ;;
    aarch64) ARCH="aarch64" ;;
    armv7l) ARCH="armv7" ;; # 注意 Docker 静态包的命名 armv7
    armv6l) ARCH="armv6" ;; # 注意 Docker 静态包的命名 armv6
    *) echo -e "${RED}不支持的架构: $m${NC}"; exit 1 ;;
  esac
  echo "$ARCH"
}

get_os_version() {
  if [ -f /etc/os-release ]; then
    OS_NAME=$(grep ^ID= /etc/os-release | awk -F= '{print $2}' | tr -d '"')
    OS_VERSION=$(grep ^VERSION_ID= /etc/os-release | awk -F= '{print $2}' | tr -d '"')
    echo "$OS_NAME $OS_VERSION"
  else
    echo -e "${RED}无法检测系统版本（缺少 /etc/os-release）。${NC}"
    exit 1
  fi
}

check_and_set_install_dir() {
  local REQUIRED_SPACE=500  # MB
  local realpath_cmd
  if command -v realpath >/dev/null 2>&1; then
    realpath_cmd="realpath"
  else
    realpath_cmd="readlink -f"
  fi
  local DIR
  DIR=$(dirname "$($realpath_cmd "$0")")
  local DEFAULT_DIR="${DIR}/docker_install"

  mkdir -p "$DEFAULT_DIR" 2>/dev/null || {
    echo -e "${RED}无法创建默认目录 $DEFAULT_DIR${NC}"; exit 1; }

  local AVAILABLE_SPACE
  AVAILABLE_SPACE=$(df -m "$DEFAULT_DIR" 2>/dev/null | tail -1 | awk '{print $4}')
  if [[ -z "$AVAILABLE_SPACE" ]]; then
    echo -e "${RED}无法检测目录 $DEFAULT_DIR 的可用空间。${NC}"
    exit 1
  fi

  echo -e "${YELLOW}默认目录: $DEFAULT_DIR (可用: ${AVAILABLE_SPACE}MB, 需: ${REQUIRED_SPACE}MB)${NC}"
  read -r -p "是否指定自定义安装目录？(回车使用默认): " CUSTOM_DIR

  if [[ -n "$CUSTOM_DIR" ]]; then
    mkdir -p "$CUSTOM_DIR" 2>/dev/null || { echo -e "${RED}无法创建 $CUSTOM_DIR${NC}"; exit 1; }
    AVAILABLE_SPACE=$(df -m "$CUSTOM_DIR" 2>/dev/null | tail -1 | awk '{print $4}')
    [[ -z "$AVAILABLE_SPACE" ]] && { echo -e "${RED}无法检测 $CUSTOM_DIR 可用空间${NC}"; exit 1; }
    if (( AVAILABLE_SPACE < REQUIRED_SPACE )); then
      echo -e "${RED}$CUSTOM_DIR 空间不足 (可用: ${AVAILABLE_SPACE}MB, 需: ${REQUIRED_SPACE}MB)${NC}"
      exit 1
    fi
    DOCKER_INSTALL_DIR="$CUSTOM_DIR/docker_install"
    echo -e "${GREEN}使用自定义目录: $DOCKER_INSTALL_DIR${NC}"
  else
    if (( AVAILABLE_SPACE < REQUIRED_SPACE )); then
      echo -e "${RED}$DEFAULT_DIR 空间不足 (可用: ${AVAILABLE_SPACE}MB, 需: ${REQUIRED_SPACE}MB)${NC}"
      exit 1
    fi
    DOCKER_INSTALL_DIR="$DEFAULT_DIR"
    echo -e "${GREEN}使用默认目录: $DOCKER_INSTALL_DIR${NC}"
  fi

  mkdir -p "$DOCKER_INSTALL_DIR" || {
    echo -e "${RED}创建目录 $DOCKER_INSTALL_DIR 失败${NC}"; exit 1; }
}

check_docker_installed() {
  if command -v docker >/dev/null 2>&1; then
    echo -e "${GREEN}Docker 已安装：$(docker --version)${NC}"
    return 0
  fi
  echo -e "${YELLOW}Docker 未安装。${NC}"
  return 1
}

check_docker_compose_installed() {
  if command -v docker-compose >/dev/null 2>&1; then
    echo -e "${GREEN}docker-compose 已安装：$(docker-compose --version)${NC}"
    return 0
  fi
  if docker compose version >/dev/null 2>&1; then
    echo -e "${GREEN}Docker Compose 插件已安装：$(docker compose version | head -n1)${NC}"
    return 0
  fi
  echo -e "${YELLOW}Docker Compose 未安装。${NC}"
  return 1
}

#====================== Docker 前置准备 ======================#

ensure_docker_prereqs() {
  echo "正在配置 Docker 运行环境..."

  # 1) 【核心】检查并加载 Docker 必需的内核模块
  echo "检查 Docker 必需的内核模块..."
  
  # 1a) 检查并加载基础模块
  modprobe overlay 2>/dev/null || true
  modprobe br_netfilter 2>/dev/null || true

  # 1b) 【智能降级检测】检查 iptable_raw 模块
  if ! iptables -t raw -L >/dev/null 2>&1; then
    echo -e "${YELLOW}检测到 iptables 'raw' 表不可用，新版 Docker (>=28) 强依赖此功能。${NC}"
    echo -e "${YELLOW}正在尝试加载 'iptable_raw' 内核模块...${NC}"
    modprobe iptable_raw
    # 再次检查，如果仍然失败，则设置降级标志
    if ! iptables -t raw -L >/dev/null 2>&1; then
      echo -e "${RED}警告: 'iptable_raw' 内核模块加载失败！${NC}"
      echo -e "${YELLOW}这通常发生在内核过于精简或在特殊的虚拟化环境（如 OpenVZ）中。${NC}"
      echo -e "${GREEN}为了保证可用性，脚本将自动为您安装兼容的旧版 Docker (${RECOMMENDED_LEGACY_DOCKER_VERSION})。${NC}"
      FORCE_LEGACY_DOCKER="true"
    else
      echo -e "${GREEN}'iptable_raw' 模块加载成功，系统支持最新版 Docker。${NC}"
    fi
  else
      echo -e "${GREEN}iptables 'raw' 表可用，兼容性良好。${NC}"
  fi
  
  # 2) 将必需模块写入配置文件，确保开机自启
  if [[ "$FORCE_LEGACY_DOCKER" == "false" ]]; then
    # 正常模式下，添加所有模块
    printf "overlay\nbr_netfilter\niptable_raw\n" >/etc/modules-load.d/docker.conf
  else
    # 降级模式下，不需要 raw 模块
    printf "overlay\nbr_netfilter\n" >/etc/modules-load.d/docker.conf
  fi

  # 3) sysctl 开启转发与桥接
  cat >/etc/sysctl.d/99-docker.conf <<'EOF'
net.ipv4.ip_forward=1
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
EOF
  sysctl --system >/dev/null 2>&1 || true

  # 4) 智能检测并切换 iptables 后端
  if command -v update-alternatives >/dev/null 2>&1 && [ -f /usr/sbin/iptables-legacy ]; then
    if iptables -V | grep -q 'nf_tables'; then
      echo -e "${YELLOW}检测到系统正在使用 iptables-nft 后端... 正在切换到 legacy...${NC}"
      update-alternatives --set iptables /usr/sbin/iptables-legacy >/dev/null 2>&1
      update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy >/dev/null 2>&1
      if iptables -V | grep -q 'legacy'; then
        echo -e "${GREEN}iptables 后端已成功切换到 legacy 模式。${NC}"
      else
        echo -e "${RED}iptables 后端切换失败。${NC}"
      fi
    else
      echo -e "${GREEN}iptables 后端检查完成，当前为 legacy 模式或无需切换。${NC}"
    fi
  fi

  # 5) 最终校验 NAT 表
  # 确保 NAT 表可用；不通则尝试加载相关内核模块
  if ! iptables -t nat -L >/dev/null 2>&1; then
    modprobe iptable_nat nf_nat 2>/dev/null || true
    # 再测一次
    if ! iptables -t nat -L >/dev/null 2>&1; then
      echo -e "${YELLOW}警告：系统无法访问 iptables NAT 表。Docker 的端口映射等网络功能可能无法使用。${NC}"
    fi
  fi

  # 6) 提示 cgroup（仅提示）
  local cg
  cg=$(stat -f -c %T /sys/fs/cgroup 2>/dev/null || echo "")
  if [[ "$cg" != "cgroup2fs" && -n "$cg" ]]; then
    echo -e "${YELLOW}注意：当前未使用 cgroup v2 统一层级，建议在内核参数启用（可选）。${NC}"
  fi

  echo -e "${GREEN}Docker 运行环境配置完成。${NC}"
}

# 生成/补全 daemon.json（若不存在则创建）
ensure_daemon_json() {
  mkdir -p /etc/docker
  if [ ! -s /etc/docker/daemon.json ]; then
cat >/etc/docker/daemon.json <<EOF
{
  "iptables": true,
  "ip6tables": true,
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "registry-mirrors": [
    "${REGISTRY_MIRRORS_DEFAULT[0]}",
    "${REGISTRY_MIRRORS_DEFAULT[1]}",
    "${REGISTRY_MIRRORS_DEFAULT[2]}"
  ]
}
EOF
  fi

  # 如内核无 overlay，尝试 fuse-overlayfs
  if ! grep -qw overlay /proc/filesystems; then
    case "$PKG_MANAGER" in
      apt-get) apt-get install -y fuse-overlayfs >/dev/null 2>&1 || true ;;
      dnf|yum) "${PKG_MANAGER}" install -y fuse-overlayfs >/dev/null 2>&1 || true ;;
    esac
    if command -v jq >/dev/null 2>&1; then
      tmp=$(mktemp)
      jq '. + {"storage-driver":"fuse-overlayfs"}' /etc/docker/daemon.json > "$tmp" && mv "$tmp" /etc/docker/daemon.json
    else
      # 简化追加
cat >/etc/docker/daemon.json <<'EOF'
{
  "iptables": true,
  "ip6tables": true,
  "exec-opts": ["native.cgroupdriver=systemd"],
  "storage-driver": "fuse-overlayfs"
}
EOF
    fi
  fi
}

#====================== 版本获取/选择 ======================#

fetch_docker_versions() {
  local CACHE_FILE="$DOCKER_INSTALL_DIR/docker_versions_cache"
  if [[ -f "$CACHE_FILE" && $(stat -c %Y "$CACHE_FILE") -gt $(($(date +%s) - 3600)) ]]; then
    cat "$CACHE_FILE"
    return
  fi
  ARCH=$(get_architecture)
  local URL="$DOCKER_VERSIONS_URL$ARCH/"
  local VERSIONS
  VERSIONS=$(curl -s "$URL" | grep -oP 'docker-\K[0-9]+\.[0-9]+\.[0-9]+' | sort -Vr | uniq)
  if [ -z "$VERSIONS" ]; then
    echo -e "${RED}无法获取 Docker 版本列表，请检查网络。${NC}"
    exit 1
  fi
  echo "$VERSIONS" > "$CACHE_FILE"
  echo "$VERSIONS"
}

select_version() {
  local VERSIONS=("$@")
  if command -v fzf >/dev/null 2>&1; then
    local SELECTED_VERSION
    SELECTED_VERSION=$(printf "%s\n" "${VERSIONS[@]}" | fzf \
      --prompt="请选择版本 > " \
      --header="选择版本（回车确认）" \
      --height=20 --reverse --border)
    if [ -n "$SELECTED_VERSION" ]; then
      echo "$SELECTED_VERSION"; return
    else
      echo -e "${YELLOW}未选择，使用最新版本...${NC}"
      echo "${VERSIONS[0]}"; return
    fi
  fi

  echo "可用版本列表:"
  PS3="请选择版本 (默认1为最新): "
  select VERSION in "${VERSIONS[@]}" "取消"; do
    case $REPLY in
      ''|1) echo "${VERSIONS[0]}"; return ;;
      [2-9]|[1-9][0-9]) 
        if [ "$REPLY" -le "${#VERSIONS[@]}" ]; then
          echo "${VERSIONS[$((REPLY-1))]}"; return
        fi ;;
      *) echo -e "${YELLOW}未选择，使用最新版本...${NC}"; echo "${VERSIONS[0]}"; return ;;
    esac
  done
}

fetch_docker_compose_versions() {
  local VERSIONS
  VERSIONS=$(curl -s "$COMPOSE_RELEASES_URL" | jq -r '.[].tag_name' | sort -Vr | uniq)
  if [ -z "$VERSIONS" ]; then
    echo -e "${RED}无法获取 Docker Compose 版本列表。${NC}"
    exit 1
  fi
  echo "$VERSIONS"
}

#====================== 核心：安装/卸载 ======================#

install_docker() {
  if check_docker_installed; then
    read -r -p "Docker 已安装，是否重新安装？(y/n): " REINSTALL
    [[ "$REINSTALL" != "y" ]] && { echo -e "${YELLOW}跳过 Docker 安装。${NC}"; return; }
  fi

  # 配置 Docker 运行环境（内核模块、sysctl 等）
  # 这一步会根据系统情况设置 FORCE_LEGACY_DOCKER 标志
  ensure_docker_prereqs

  ARCH=$(get_architecture)
  check_and_set_install_dir

  local VERSION

  # 【核心智能降级逻辑】
  if [[ "$FORCE_LEGACY_DOCKER" == "true" ]]; then
    echo -e "${YELLOW}由于系统环境限制，将为您安装兼容性最好的旧版 Docker。${NC}"
    VERSION="$RECOMMENDED_LEGACY_DOCKER_VERSION"
    # 检查推荐的版本是否存在
    local available_versions
    available_versions=$(fetch_docker_versions)
    if ! echo "$available_versions" | grep -q "^${VERSION}$"; then
      echo -e "${RED}推荐的兼容版本 ${VERSION} 不在可用列表中！${NC}"
      echo -e "${RED}安装中止。请检查网络或手动选择一个可用版本。${NC}"
      exit 1
    fi
  else
    echo "获取可用 Docker 版本..."
    local VERSIONS
    VERSIONS=$(fetch_docker_versions)
    VERSION=$(select_version $VERSIONS)
    [[ -z "$VERSION" ]] && { echo -e "${RED}未获得版本号${NC}"; exit 1; }
  fi

  echo -e "${GREEN}选择的 Docker 版本：$VERSION${NC}"
  DOCKER_URL="$DOCKER_VERSIONS_URL$ARCH/docker-$VERSION.tgz"

  echo "下载 Docker 二进制包：$DOCKER_URL"
  if ! curl -fSL --retry 3 "$DOCKER_URL" -o "$DOCKER_INSTALL_DIR/docker.tgz"; then
    echo -e "${YELLOW}直连失败，尝试代理...${NC}"
    local DOWNLOAD_SUCCESS=false
    for PROXY_PREFIX in "${PROXY_PREFIXES[@]}"; do
      local PROXY_DOCKER_URL="${PROXY_PREFIX}${DOCKER_URL}"
      echo "代理下载：$PROXY_DOCKER_URL"
      if curl -fSL --retry 3 "$PROXY_DOCKER_URL" -o "$DOCKER_INSTALL_DIR/docker.tgz"; then
        echo -e "${GREEN}代理下载成功${NC}"
        DOWNLOAD_SUCCESS=true
        break
      else
        echo -e "${YELLOW}代理下载失败：${PROXY_DOCKER_URL}${NC}"
      fi
    done
    $DOWNLOAD_SUCCESS || { echo -e "${RED}所有下载方式均失败${NC}"; rm -rf "$DOCKER_INSTALL_DIR"; exit 1; }
  fi

  echo "解压 Docker 包..."
  tar -zxf "$DOCKER_INSTALL_DIR/docker.tgz" -C "$DOCKER_INSTALL_DIR" || {
    echo -e "${RED}解压失败${NC}"; rm -rf "$DOCKER_INSTALL_DIR"; exit 1; }

  echo "安装 Docker 二进制到 /usr/local/bin ..."
  chown root:root "$DOCKER_INSTALL_DIR/docker/"*
  mv "$DOCKER_INSTALL_DIR/docker/"* /usr/local/bin/ || {
    echo -e "${RED}移动文件失败${NC}"; exit 1; }

  echo "创建 docker 用户组并加入当前用户（可选）..."
  groupadd -f docker
  CURRENT_USER="${SUDO_USER:-$USER}"
  if [[ -n "$CURRENT_USER" && "$CURRENT_USER" != "root" ]]; then
    gpasswd -a "$CURRENT_USER" docker >/dev/null 2>&1 || true
  fi

  # 生成/补全 daemon.json
  ensure_daemon_json

  echo "写入 systemd Unit ..."
cat >/etc/systemd/system/docker.service <<'EOF'
[Unit]
Description=Docker Application Container Engine
Documentation=https://docs.docker.com
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/local/bin/dockerd
ExecReload=/bin/kill -s HUP $MAINPID
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
Delegate=yes
KillMode=process
OOMScoreAdjust=-500

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable docker >/dev/null 2>&1 || true
  echo "启动 Docker ..."
  if ! systemctl start docker; then
    echo -e "${YELLOW}启动失败，查看日志：journalctl -u docker -n 200 --no-pager${NC}"
    exit 1
  fi

  if command -v docker >/dev/null 2>&1 && docker version >/dev/null 2>&1; then
    echo -e "${GREEN}Docker 安装并启动成功！${NC}"
    echo -e "${YELLOW}若需要无 sudo 运行，请重新登录以应用用户组变更。${NC}"
  else
    echo -e "${RED}Docker 安装或启动失败，请查看日志。${NC}"
    exit 1
  fi

  echo "清理临时文件..."
  rm -rf "$DOCKER_INSTALL_DIR"
}

install_docker_compose() {
  if check_docker_compose_installed; then
    read -r -p "Docker Compose 已安装，是否重新安装？(y/n): " REINSTALL
    [[ "$REINSTALL" != "y" ]] && { echo -e "${YELLOW}跳过 Docker Compose 安装。${NC}"; return; }
  fi

  echo "获取 Docker Compose 版本列表..."
  local COMPOSE_VERSIONS
  COMPOSE_VERSIONS=$(fetch_docker_compose_versions)
  local COMPOSE_VERSION
  COMPOSE_VERSION=$(select_version $COMPOSE_VERSIONS)
  if [ -z "$COMPOSE_VERSION" ]; then
    echo -e "${YELLOW}未选择，将安装最新版本...${NC}"
    COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | jq -r .tag_name)
  else
    COMPOSE_VERSION=$(echo "$COMPOSE_VERSION" | tr -d '[:space:]')
  fi
  echo -e "${GREEN}选择的 Docker Compose 版本：$COMPOSE_VERSION${NC}"

  local os_name arch_name compose_file
  os_name=$(uname -s)
  arch_name=$(uname -m)
  case "$os_name" in
    Linux)
      case "$arch_name" in
        x86_64) compose_file="docker-compose-linux-x86_64" ;;
        aarch64) compose_file="docker-compose-linux-aarch64" ;;
        armv7l) compose_file="docker-compose-linux-armv7" ;;
        armv6l) compose_file="docker-compose-linux-armv6" ;;
        *) echo -e "${RED}不支持的 Linux 架构: $arch_name${NC}"; exit 1 ;;
      esac ;;
    Darwin)
      case "$arch_name" in
        x86_64) compose_file="docker-compose-darwin-x86_64" ;;
        arm64)  compose_file="docker-compose-darwin-aarch64" ;;
        *) echo -e "${RED}不支持的 macOS 架构: $arch_name${NC}"; exit 1 ;;
      esac ;;
    *)
      echo -e "${RED}不支持的操作系统: $os_name${NC}"; exit 1 ;;
  esac

  echo "下载 Docker Compose：$COMPOSE_VERSION"
  curl -fsSL "https://github.com/docker/compose/releases/download/$COMPOSE_VERSION/$compose_file" \
      -o /usr/local/bin/docker-compose || { echo -e "${RED}下载失败${NC}"; exit 1; }
  chmod +x /usr/local/bin/docker-compose

  # 安装为 CLI 插件，支持 `docker compose`
  mkdir -p /usr/local/lib/docker/cli-plugins
  cp /usr/local/bin/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose

  echo -e "${GREEN}Docker Compose 安装完成（支持 docker compose 与 docker-compose）。${NC}"
}

uninstall_docker() {
  echo "正在卸载 Docker..."

  # 优先清理镜像/容器（若可用）
  docker system prune -a -f 2>/dev/null || true

  # 停止与禁用服务
  systemctl stop docker.service 2>/dev/null || true
  systemctl disable docker.service 2>/dev/null || true

  # 移除可能通过包管理器安装的包（忽略失败）
  case "$PKG_MANAGER" in
    apt-get) apt-get remove -y --purge docker docker-engine docker.io containerd runc docker-ce docker-ce-cli 2>/dev/null || true ;;
    dnf|yum) "${PKG_MANAGER}" remove -y docker docker-engine docker.io containerd runc docker-ce docker-ce-cli 2>/dev/null || true ;;
  esac

  # 删除静态二进制与目录
  rm -rf /var/lib/docker /etc/docker /usr/local/bin/docker* /usr/bin/docker* /usr/sbin/docker* /opt/docker
  rm -f /etc/systemd/system/docker.service /etc/systemd/system/docker.socket
  rm -f /etc/modules-load.d/docker.conf /etc/sysctl.d/99-docker.conf

  # 清理 containerd/runc 残留
  rm -rf /var/lib/containerd /run/containerd /usr/local/bin/containerd* /usr/local/bin/runc 2>/dev/null || true

  # 删除 docker 组
  groupdel docker 2>/dev/null || true

  systemctl daemon-reload 2>/dev/null || true
  systemctl reset-failed 2>/dev/null || true

  echo -e "${GREEN}Docker 已卸载并清理。${NC}"
}

uninstall_docker_compose() {
  echo "正在卸载 Docker Compose..."
  rm -f /usr/local/bin/docker-compose
  rm -f /usr/local/lib/docker/cli-plugins/docker-compose
  rm -rf ~/.docker/compose 2>/dev/null || true
  rm -rf /opt/docker-compose 2>/dev/null || true
  echo -e "${GREEN}Docker Compose 已卸载。${NC}"
}

generate_daemon_config() {
  echo "正在生成 Docker daemon.json 配置文件..."
  local DEFAULT_DATA_ROOT="/var/lib/docker"
  local DEFAULT_LOG_MAX_SIZE="10m"
  local DEFAULT_LOG_MAX_FILE="3"

  read -r -p "请输入 Docker data-root 路径 (默认: ${DEFAULT_DATA_ROOT}): " DATA_ROOT_INPUT
  DATA_ROOT="${DATA_ROOT_INPUT:-${DEFAULT_DATA_ROOT}}"

  local REGISTRY_MIRRORS_JSON
  REGISTRY_MIRRORS_JSON=$(printf '%s\n' "${REGISTRY_MIRRORS_DEFAULT[@]}" | jq -R . | jq -s .)

  DAEMON_CONFIG=$(cat <<EOF
{
  "iptables": true,
  "ip6tables": true,
  "exec-opts": ["native.cgroupdriver=systemd"],
  "registry-mirrors": ${REGISTRY_MIRRORS_JSON},
  "data-root": "${DATA_ROOT}",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "${DEFAULT_LOG_MAX_SIZE}",
    "max-file": "${DEFAULT_LOG_MAX_FILE}"
  }
}
EOF
)
  echo "daemon.json 内容："
  echo "$DAEMON_CONFIG"

  if ! echo "$DAEMON_CONFIG" | jq . >/dev/null 2>&1; then
    echo -e "${RED}生成的 JSON 格式不正确（请确认 jq 可用）。${NC}"
    exit 1
  fi

  mkdir -p /etc/docker
  echo "$DAEMON_CONFIG" > /etc/docker/daemon.json

  if [ $? -eq 0 ]; then
    echo -e "${GREEN}/etc/docker/daemon.json 生成成功。${NC}"
    echo "重启 Docker 以应用配置..."
    if systemctl restart docker; then
      echo -e "${GREEN}Docker 重启成功。${NC}"
    else
      echo -e "${YELLOW}Docker 重启失败，请手动执行：systemctl restart docker${NC}"
    fi
  else
    echo -e "${RED}写入 /etc/docker/daemon.json 失败。${NC}"
  fi
}

check_iptables_mode() {
  echo "正在检测 iptables 后端模式..."
  if ! command -v iptables >/dev/null 2>&1; then
    echo -e "${RED}系统中未找到 iptables 命令。${NC}"
    return
  fi

  local iptables_version
  iptables_version=$(iptables -V 2>/dev/null)

  if echo "$iptables_version" | grep -q 'nf_tables'; then
    echo -e "当前 iptables 后端为: ${YELLOW}nf_tables${NC}"
    echo -e "版本信息: $iptables_version"
    echo -e "${YELLOW}提示: Docker 目前对 nf_tables 支持不完善，建议使用 legacy 模式以获得最佳兼容性。${NC}"
  elif echo "$iptables_version" | grep -q 'legacy'; then
    echo -e "当前 iptables 后端为: ${GREEN}legacy${NC}"
    echo -e "版本信息: $iptables_version"
    echo -e "${GREEN}提示: 此模式与 Docker 兼容性良好。${NC}"
  else
    echo -e "${YELLOW}无法明确识别 iptables 后端模式。${NC}"
    echo -e "版本信息: $iptables_version"
  fi
}

#====================== 主菜单 ======================#

main() {
  check_sudo
  detect_package_manager
  # 在脚本开始时，一次性安装所有依赖
  install_dependencies

  echo "欢迎使用 Docker/Compose 智能安装脚本"
  echo "检测系统信息..."
  ARCH=$(get_architecture)
  OS=$(get_os_version)
  echo "系统架构: $ARCH"
  echo "系统版本: $OS"

  while true; do
    echo -e "\n${YELLOW}请选择要执行的操作：${NC}"
    echo -e "${GREEN}1. 安装 Docker${NC}"
    echo -e "${GREEN}2. 安装 Docker Compose${NC}"
    echo -e "${GREEN}3. 安装 Docker 和 Docker Compose${NC}"
    echo -e "${RED}4. 卸载 Docker${NC}"
    echo -e "${RED}5. 卸载 Docker Compose${NC}"
    echo -e "${RED}6. 卸载 Docker 和 Docker Compose${NC}"
    echo -e "${YELLOW}7. 查询 Docker 和 Docker Compose 的安装状态${NC}"
    echo -e "${YELLOW}8. 生成 daemon.json 配置文件${NC}"
    echo -e "${GREEN}9. 查看当前 iptables 后端模式${NC}"
    echo -e "${RED}10. 退出脚本${NC}"
    read -r -p "请输入数字 (1-10): " CHOICE

    case "$CHOICE" in
      1) install_docker ;;
      2) install_docker_compose ;;
      3) install_docker; install_docker_compose ;;
      4) uninstall_docker ;;
      5) uninstall_docker_compose ;;
      6) uninstall_docker; uninstall_docker_compose ;;
      7) check_docker_installed; check_docker_compose_installed ;;
      8) generate_daemon_config ;;
      9) check_iptables_mode ;;
      10) echo -e "${GREEN}退出脚本。${NC}"; break ;;
      *) echo -e "${RED}无效的选择，请重试。${NC}" ;;
    esac
    [[ -n "$CHOICE" && "$CHOICE" -ne 10 ]] && read -n 1 -s -r -p "按任意键返回主菜单..."
  done
}

main
rm -f "$INSTALL_STATUS"
