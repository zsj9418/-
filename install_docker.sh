#!/bin/bash
set -o pipefail

#====================== 基本配置 ======================#

REQ_DEPS=("curl" "wget" "jq")
OPT_DEPS=("fzf")

DOCKER_VERSIONS_URL="https://download.docker.com/linux/static/stable/"
COMPOSE_RELEASES_URL="https://api.github.com/repos/docker/compose/releases"

# 仅用于代理 GitHub 相关 URL
PROXY_PREFIXES=(
  "https://ghproxy.com/"
  "https://gitclone.com/"
  "https://gitdl.cn/"
)

# 默认镜像加速源（daemon.json 用）
REGISTRY_MIRRORS_DEFAULT=(
  "https://docker.1ms.run"
  "https://docker.xuanyuan.me"
  "https://docker.m.daocloud.io"
  "https://dockerproxy.net"
  "https://docker.1panel.live"
)

# daemon.json 备份目录
DAEMON_BACKUP_DIR="/etc/docker/backups"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# 全局变量
DOCKER_URL=""
DOCKER_INSTALL_DIR=""
ARCH=""
OS=""
PKG_MANAGER=""
FORCE_LEGACY_DOCKER="false"
RECOMMENDED_LEGACY_DOCKER_VERSION="27.3.1"

#====================== 日志配置 ======================#

LOG_DIR="/var/log/docker_manager"
LOG_FILE="${LOG_DIR}/docker_manager.log"
LOG_MAX_SIZE_MB=5
LOG_MAX_BACKUPS=3

rotate_log() {
  [[ ! -f "$LOG_FILE" ]] && return 0

  local size_bytes
  size_bytes=$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)
  local size_mb=$(( size_bytes / 1024 / 1024 ))

  if (( size_mb < LOG_MAX_SIZE_MB )); then
    return 0
  fi

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] 日志文件达到 ${size_mb}MB，触发轮转..." >> "$LOG_FILE"

  local oldest="${LOG_FILE}.${LOG_MAX_BACKUPS}.gz"
  [[ -f "$oldest" ]] && rm -f "$oldest"

  for (( i = LOG_MAX_BACKUPS - 1; i >= 1; i-- )); do
    local src="${LOG_FILE}.${i}.gz"
    local dst="${LOG_FILE}.$((i+1)).gz"
    [[ -f "$src" ]] && mv "$src" "$dst"
  done

  gzip -c "$LOG_FILE" > "${LOG_FILE}.1.gz"
  : > "$LOG_FILE"

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] 日志轮转完成，已归档至 ${LOG_FILE}.1.gz" >> "$LOG_FILE"
}

init_log() {
  mkdir -p "$LOG_DIR"
  rotate_log
  {
    echo ""
    echo "════════════════════════════════════════"
    echo "  会话开始: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  PID: $$  |  用户: ${SUDO_USER:-$USER}"
    echo "════════════════════════════════════════"
  } >> "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
}

#====================== 信号捕获 ======================#

cleanup() {
  echo -e "\n${YELLOW}检测到中断信号，正在清理临时文件...${NC}"
  [[ -n "$DOCKER_INSTALL_DIR" && -d "$DOCKER_INSTALL_DIR" ]] && rm -rf "$DOCKER_INSTALL_DIR"
  echo -e "${YELLOW}日志已保存至: ${LOG_FILE}${NC}"
  exit 130
}
trap cleanup INT TERM

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

install_dependencies() {
  echo "正在检测并安装所有缺失的依赖..."
  local missing_req_deps=()
  for dep in "${REQ_DEPS[@]}"; do
    command -v "$dep" >/dev/null 2>&1 || missing_req_deps+=("$dep")
  done

  local missing_opt_deps=()
  for dep in "${OPT_DEPS[@]}"; do
    command -v "$dep" >/dev/null 2>&1 || missing_opt_deps+=("$dep")
  done

  if [[ ${#missing_req_deps[@]} -eq 0 && ${#missing_opt_deps[@]} -eq 0 ]]; then
    echo -e "${GREEN}所有依赖均已安装。${NC}"
    return 0
  fi

  case "$PKG_MANAGER" in
    apt-get)
      apt-get update || true
      if [[ ${#missing_req_deps[@]} -gt 0 ]]; then
        echo "正在安装必需依赖: ${missing_req_deps[*]}"
        apt-get install -y --no-install-recommends "${missing_req_deps[@]}" || {
          echo -e "${RED}安装必需依赖失败${NC}"; exit 1; }
      fi
      if [[ ${#missing_opt_deps[@]} -gt 0 ]]; then
        echo "正在安装可选依赖: ${missing_opt_deps[*]}"
        apt-get install -y --no-install-recommends "${missing_opt_deps[@]}" 2>/dev/null || true
      fi
      ;;
    dnf|yum)
      if [[ ${#missing_req_deps[@]} -gt 0 ]]; then
        echo "正在安装必需依赖: ${missing_req_deps[*]}"
        "${PKG_MANAGER}" install -y "${missing_req_deps[@]}" || {
          echo -e "${RED}安装必需依赖失败${NC}"; exit 1; }
      fi
      if [[ ${#missing_opt_deps[@]} -gt 0 ]]; then
        echo "正在安装可选依赖: ${missing_opt_deps[*]}"
        "${PKG_MANAGER}" install -y "${missing_opt_deps[@]}" 2>/dev/null || true
      fi
      ;;
  esac
}

get_architecture() {
  local m
  m=$(uname -m)
  case "$m" in
    x86_64)  ARCH="x86_64" ;;
    aarch64) ARCH="aarch64" ;;
    armv7l)  ARCH="armv7" ;;
    armv6l)  ARCH="armv6" ;;
    *) echo -e "${RED}不支持的架构: $m${NC}" >&2; exit 1 ;;
  esac
  echo "$ARCH"
}

get_os_version() {
  if [[ -f /etc/os-release ]]; then
    OS_NAME=$(grep ^ID= /etc/os-release | awk -F= '{print $2}' | tr -d '"')
    OS_VERSION=$(grep ^VERSION_ID= /etc/os-release | awk -F= '{print $2}' | tr -d '"')
    echo "$OS_NAME $OS_VERSION"
  else
    echo -e "${YELLOW}警告: 无法读取 /etc/os-release，系统版本未知。${NC}" >&2
    echo "unknown"
  fi
}

check_and_set_install_dir() {
  local REQUIRED_SPACE=500
  local realpath_cmd
  realpath_cmd=$(command -v realpath 2>/dev/null || echo "readlink -f")

  local DIR
  if [[ "$0" == "bash" || "$0" == "-bash" || "$0" == "sh" || "$0" == "-sh" ]]; then
    DIR="/tmp"
  else
    DIR=$(dirname "$($realpath_cmd "$0" 2>/dev/null || echo "$0")")
  fi
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

# 统一下载函数，区分 GitHub URL 与其他 URL 的代理策略
download_with_fallback() {
  local url="$1"
  local dest="$2"

  echo "下载: $url" >&2
  if curl -fSL --retry 3 --connect-timeout 20 "$url" -o "$dest"; then
    return 0
  fi

  echo -e "${YELLOW}直连失败，尝试代理...${NC}" >&2

  if [[ "$url" == *"github.com"* || "$url" == *"githubusercontent.com"* ]]; then
    for prefix in "${PROXY_PREFIXES[@]}"; do
      local proxy_url="${prefix}${url}"
      echo "代理下载: $proxy_url" >&2
      if curl -fSL --retry 3 --connect-timeout 20 "$proxy_url" -o "$dest"; then
        echo -e "${GREEN}代理下载成功${NC}" >&2
        return 0
      fi
      echo -e "${YELLOW}代理失败: $proxy_url${NC}" >&2
    done
  else
    echo -e "${YELLOW}注意：该地址不支持代理加速，已重试 3 次仍失败。${NC}" >&2
  fi

  return 1
}

#====================== Docker 前置准备 ======================#

ensure_docker_prereqs() {
  echo "正在配置 Docker 运行环境..."

  echo "检查 Docker 必需的内核模块..."
  modprobe overlay 2>/dev/null || true
  modprobe br_netfilter 2>/dev/null || true

  if ! iptables -t raw -L >/dev/null 2>&1; then
    echo -e "${YELLOW}检测到 iptables 'raw' 表不可用，新版 Docker (>=28) 强依赖此功能。${NC}"
    echo -e "${YELLOW}正在尝试加载 'iptable_raw' 内核模块...${NC}"
    modprobe iptable_raw 2>/dev/null || true
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

  if [[ "$FORCE_LEGACY_DOCKER" == "false" ]]; then
    printf "overlay\nbr_netfilter\niptable_raw\n" >/etc/modules-load.d/docker.conf
  else
    printf "overlay\nbr_netfilter\n" >/etc/modules-load.d/docker.conf
  fi

  cat >/etc/sysctl.d/99-docker.conf <<'EOF'
net.ipv4.ip_forward=1
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
EOF
  sysctl --system >/dev/null 2>&1 || true

  if command -v update-alternatives >/dev/null 2>&1 && [[ -f /usr/sbin/iptables-legacy ]]; then
    if iptables -V 2>/dev/null | grep -q 'nf_tables'; then
      echo -e "${YELLOW}检测到系统正在使用 iptables-nft 后端... 正在切换到 legacy...${NC}"
      update-alternatives --set iptables /usr/sbin/iptables-legacy >/dev/null 2>&1
      update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy >/dev/null 2>&1
      if iptables -V 2>/dev/null | grep -q 'legacy'; then
        echo -e "${GREEN}iptables 后端已成功切换到 legacy 模式。${NC}"
      else
        echo -e "${RED}iptables 后端切换失败。${NC}"
      fi
    else
      echo -e "${GREEN}iptables 后端检查完成，当前为 legacy 模式或无需切换。${NC}"
    fi
  fi

  if ! iptables -t nat -L >/dev/null 2>&1; then
    modprobe iptable_nat nf_nat 2>/dev/null || true
    if ! iptables -t nat -L >/dev/null 2>&1; then
      echo -e "${YELLOW}警告：系统无法访问 iptables NAT 表。Docker 端口映射等网络功能可能无法使用。${NC}"
    fi
  fi

  local cg
  cg=$(stat -f -c %T /sys/fs/cgroup 2>/dev/null || echo "")
  if [[ "$cg" != "cgroup2fs" && -n "$cg" ]]; then
    echo -e "${YELLOW}注意：当前未使用 cgroup v2 统一层级，建议在内核参数启用（可选）。${NC}"
  fi

  echo -e "${GREEN}Docker 运行环境配置完成。${NC}"
}

ensure_daemon_json() {
  mkdir -p /etc/docker
  if [[ ! -s /etc/docker/daemon.json ]]; then
    # 将 REGISTRY_MIRRORS_DEFAULT 数组转为 JSON 数组
    local mirrors_json
    mirrors_json=$(printf '%s\n' "${REGISTRY_MIRRORS_DEFAULT[@]}" | jq -R . | jq -s .)
    cat >/etc/docker/daemon.json <<EOF
{
  "iptables": true,
  "ip6tables": true,
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "registry-mirrors": ${mirrors_json}
}
EOF
  fi

  if ! grep -qw overlay /proc/filesystems; then
    case "$PKG_MANAGER" in
      apt-get) apt-get install -y fuse-overlayfs >/dev/null 2>&1 || true ;;
      dnf|yum) "${PKG_MANAGER}" install -y fuse-overlayfs >/dev/null 2>&1 || true ;;
    esac
    if command -v jq >/dev/null 2>&1; then
      local tmp
      tmp=$(mktemp)
      jq '. + {"storage-driver":"fuse-overlayfs"}' /etc/docker/daemon.json > "$tmp" \
        && mv "$tmp" /etc/docker/daemon.json
    else
      backup_daemon_json
      local mirrors_json
      mirrors_json=$(printf '%s\n' "${REGISTRY_MIRRORS_DEFAULT[@]}" | jq -R . | jq -s . 2>/dev/null \
        || printf '[\n%s\n]' "$(printf '    "%s",\n' "${REGISTRY_MIRRORS_DEFAULT[@]}" | sed '$s/,$//')")
      cat >/etc/docker/daemon.json <<EOF
{
  "iptables": true,
  "ip6tables": true,
  "exec-opts": ["native.cgroupdriver=systemd"],
  "storage-driver": "fuse-overlayfs",
  "registry-mirrors": ${mirrors_json}
}
EOF
    fi
  fi
}

#====================== 版本获取/选择 ======================#

fetch_docker_versions() {
  local CACHE_FILE="/tmp/docker_versions_cache"
  if [[ -f "$CACHE_FILE" && \
        $(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0) -gt $(( $(date +%s) - 3600 )) ]]; then
    cat "$CACHE_FILE"
    return
  fi
  ARCH=$(get_architecture)
  local URL="${DOCKER_VERSIONS_URL}${ARCH}/"
  local VERSIONS
  VERSIONS=$(curl -s --connect-timeout 15 "$URL" \
    | grep -oP 'docker-\K[0-9]+\.[0-9]+\.[0-9]+' \
    | sort -Vr | uniq)
  if [[ -z "$VERSIONS" ]]; then
    echo -e "${RED}无法获取 Docker 版本列表，请检查网络。${NC}" >&2
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
    if [[ -n "$SELECTED_VERSION" ]]; then
      echo "$SELECTED_VERSION"
      return
    else
      echo -e "${YELLOW}未选择，使用最新版本...${NC}" >&2
      echo "${VERSIONS[0]}"
      return
    fi
  fi

  echo "可用版本列表:" >&2
  PS3="请选择版本 (默认 1 为最新): "
  select VERSION in "${VERSIONS[@]}" "取消"; do
    case $REPLY in
      ''|1)
        echo "${VERSIONS[0]}"
        return
        ;;
      *)
        if [[ "$REPLY" =~ ^[0-9]+$ ]] && (( REPLY >= 2 && REPLY <= ${#VERSIONS[@]} )); then
          echo "${VERSIONS[$((REPLY-1))]}"
          return
        else
          echo -e "${YELLOW}无效选择，使用最新版本...${NC}" >&2
          echo "${VERSIONS[0]}"
          return
        fi
        ;;
    esac
  done
}

fetch_docker_compose_versions() {
  local VERSIONS
  VERSIONS=$(curl -s --connect-timeout 15 "$COMPOSE_RELEASES_URL" \
    | jq -r '.[].tag_name' | sort -Vr | uniq)
  if [[ -z "$VERSIONS" ]]; then
    echo -e "${RED}无法获取 Docker Compose 版本列表。${NC}" >&2
    exit 1
  fi
  echo "$VERSIONS"
}

#====================== daemon.json 备份与回滚 ======================#

backup_daemon_json() {
  [[ -f /etc/docker/daemon.json ]] || return 0
  mkdir -p "$DAEMON_BACKUP_DIR"
  local bak="${DAEMON_BACKUP_DIR}/daemon.json.$(date +%Y%m%d_%H%M%S)"
  if cp /etc/docker/daemon.json "$bak"; then
    echo -e "${GREEN}已备份 daemon.json 至: $bak${NC}"
  else
    echo -e "${RED}备份失败${NC}"
  fi
}

restore_daemon_json() {
  mkdir -p "$DAEMON_BACKUP_DIR"
  local backups=()
  while IFS= read -r -d '' f; do
    backups+=("$f")
  done < <(find "$DAEMON_BACKUP_DIR" -maxdepth 1 -name "daemon.json.*" -print0 2>/dev/null | sort -z)

  if [[ ${#backups[@]} -eq 0 ]]; then
    echo -e "${YELLOW}暂无备份文件，请先执行备份操作。${NC}"
    return
  fi

  echo -e "${CYAN}可用的备份列表：${NC}"
  local i=1
  for f in "${backups[@]}"; do
    echo "  $i) $(basename "$f")  ($(stat -c %y "$f" 2>/dev/null | cut -d. -f1))"
    ((i++))
  done

  read -r -p "请输入要回滚的备份编号 (回车取消): " IDX
  if [[ -z "$IDX" ]]; then
    echo -e "${YELLOW}已取消回滚。${NC}"
    return
  fi
  if ! [[ "$IDX" =~ ^[0-9]+$ ]] || (( IDX < 1 || IDX > ${#backups[@]} )); then
    echo -e "${RED}无效编号。${NC}"
    return
  fi

  local selected="${backups[$((IDX-1))]}"
  backup_daemon_json
  if cp "$selected" /etc/docker/daemon.json; then
    echo -e "${GREEN}已回滚至: $(basename "$selected")${NC}"
  else
    echo -e "${RED}回滚失败${NC}"
    return
  fi

  if jq . /etc/docker/daemon.json >/dev/null 2>&1; then
    echo -e "${GREEN}daemon.json 格式校验通过。${NC}"
    read -r -p "是否立即重启 Docker 以应用配置？(y/n): " DORESTART
    [[ "$DORESTART" == "y" ]] && _restart_docker
  else
    echo -e "${RED}警告：回滚后的 daemon.json 格式不正确，请检查！${NC}"
  fi
}

manage_daemon_json() {
  while true; do
    echo -e "\n${CYAN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       daemon.json 备份与回滚             ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
    echo "  1. 备份当前 daemon.json"
    echo "  2. 查看所有备份"
    echo "  3. 回滚到指定备份"
    echo "  4. 删除指定备份"
    echo "  0. 返回主菜单"
    read -r -p "请选择操作: " DCHOICE
    case "$DCHOICE" in
      1) backup_daemon_json ;;
      2)
        local backups=()
        while IFS= read -r -d '' f; do
          backups+=("$f")
        done < <(find "$DAEMON_BACKUP_DIR" -maxdepth 1 -name "daemon.json.*" -print0 2>/dev/null | sort -z)
        if [[ ${#backups[@]} -eq 0 ]]; then
          echo -e "${YELLOW}暂无备份。${NC}"
        else
          echo -e "${CYAN}现有备份：${NC}"
          for f in "${backups[@]}"; do
            echo "  - $(basename "$f")  ($(stat -c %y "$f" 2>/dev/null | cut -d. -f1))"
          done
        fi
        ;;
      3) restore_daemon_json ;;
      4)
        local backups=()
        while IFS= read -r -d '' f; do
          backups+=("$f")
        done < <(find "$DAEMON_BACKUP_DIR" -maxdepth 1 -name "daemon.json.*" -print0 2>/dev/null | sort -z)
        if [[ ${#backups[@]} -eq 0 ]]; then
          echo -e "${YELLOW}暂无备份。${NC}"
        else
          local i=1
          for f in "${backups[@]}"; do
            echo "  $i) $(basename "$f")"
            ((i++))
          done
          read -r -p "请输入要删除的编号 (回车取消): " DIDX
          if [[ "$DIDX" =~ ^[0-9]+$ ]] && (( DIDX >= 1 && DIDX <= ${#backups[@]} )); then
            rm -f "${backups[$((DIDX-1))]}" && \
              echo -e "${GREEN}已删除备份。${NC}" || \
              echo -e "${RED}删除失败。${NC}"
          else
            echo -e "${YELLOW}已取消。${NC}"
          fi
        fi
        ;;
      0) break ;;
      *) echo -e "${RED}无效的选择，请重试。${NC}" ;;
    esac
  done
}

#====================== Docker 服务管理 ======================#

_start_docker() {
  echo -e "${CYAN}正在启动 Docker 服务...${NC}"
  if systemctl start docker; then
    echo -e "${GREEN}Docker 服务已启动。${NC}"
  else
    echo -e "${RED}Docker 服务启动失败，请查看日志：journalctl -u docker -n 50 --no-pager${NC}"
  fi
}

_stop_docker() {
  echo -e "${CYAN}正在停止 Docker 服务...${NC}"
  read -r -p "停止 Docker 会中断所有运行中容器，确认继续？(y/n): " CONFIRM
  [[ "$CONFIRM" != "y" ]] && { echo -e "${YELLOW}已取消。${NC}"; return; }
  if systemctl stop docker; then
    echo -e "${GREEN}Docker 服务已停止。${NC}"
  else
    echo -e "${RED}Docker 服务停止失败。${NC}"
  fi
}

_restart_docker() {
  echo -e "${CYAN}正在重启 Docker 服务...${NC}"
  if systemctl restart docker; then
    echo -e "${GREEN}Docker 服务已重启。${NC}"
  else
    echo -e "${RED}Docker 服务重启失败，请查看日志：journalctl -u docker -n 50 --no-pager${NC}"
  fi
}

manage_docker_service() {
  if ! command -v docker >/dev/null 2>&1; then
    echo -e "${RED}Docker 未安装，无法进行服务管理。${NC}"
    return
  fi
  while true; do
    local svc_status svc_enabled
    svc_status=$(systemctl is-active docker 2>/dev/null)
    svc_enabled=$(systemctl is-enabled docker 2>/dev/null)

    echo -e "\n${CYAN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║          Docker 服务管理                 ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
    if [[ "$svc_status" == "active" ]]; then
      echo -e "  当前状态: ${GREEN}● 运行中${NC}  |  开机自启: ${svc_enabled}"
    else
      echo -e "  当前状态: ${RED}● ${svc_status}${NC}  |  开机自启: ${svc_enabled}"
    fi
    echo -e "${CYAN}──────────────────────────────────────────${NC}"
    echo "  1. 启动 Docker"
    echo "  2. 停止 Docker"
    echo "  3. 重启 Docker"
    echo "  4. 开启开机自启"
    echo "  5. 关闭开机自启"
    echo "  6. 查看实时日志（最近 50 行）"
    echo "  0. 返回主菜单"
    echo -e "${CYAN}──────────────────────────────────────────${NC}"
    read -r -p "请选择操作: " SCHOICE
    case "$SCHOICE" in
      1) _start_docker ;;
      2) _stop_docker ;;
      3) _restart_docker ;;
      4)
        systemctl enable docker >/dev/null 2>&1 && \
          echo -e "${GREEN}已开启开机自启。${NC}" || \
          echo -e "${RED}操作失败。${NC}"
        ;;
      5)
        systemctl disable docker >/dev/null 2>&1 && \
          echo -e "${GREEN}已关闭开机自启。${NC}" || \
          echo -e "${RED}操作失败。${NC}"
        ;;
      6)
        echo -e "${CYAN}--- Docker 服务日志（最近 50 行）---${NC}"
        journalctl -u docker -n 50 --no-pager 2>/dev/null || \
          echo -e "${RED}无法读取 Docker 日志。${NC}"
        ;;
      0) break ;;
      *) echo -e "${RED}无效的选择，请重试。${NC}" ;;
    esac
  done
}

#====================== Docker 状态仪表盘 ======================#

show_docker_status() {
  echo -e "\n${BOLD}${CYAN}╔══════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYAN}║           Docker 状态仪表盘              ║${NC}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════╝${NC}"

  # ── 安装状态 ──────────────────────────────
  echo -e "\n${BOLD}[ 安装状态 ]${NC}"
  if command -v docker >/dev/null 2>&1; then
    echo -e "  Docker:         ${GREEN}已安装 $(docker --version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1)${NC}"
  else
    echo -e "  Docker:         ${RED}未安装${NC}"
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    echo -e "  Compose 独立版: ${GREEN}已安装 $(docker-compose --version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1)${NC}"
  else
    echo -e "  Compose 独立版: ${YELLOW}未安装${NC}"
  fi
  if docker compose version >/dev/null 2>&1; then
    echo -e "  Compose 插件:   ${GREEN}已安装 $(docker compose version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1)${NC}"
  else
    echo -e "  Compose 插件:   ${YELLOW}未安装${NC}"
  fi

  # ── 服务状态 ──────────────────────────────
  echo -e "\n${BOLD}[ 服务状态 ]${NC}"
  local svc_status svc_enabled
  svc_status=$(systemctl is-active docker 2>/dev/null || echo "inactive")
  svc_enabled=$(systemctl is-enabled docker 2>/dev/null || echo "disabled")
  if [[ "$svc_status" == "active" ]]; then
    echo -e "  服务:     ${GREEN}● 运行中${NC}"
  else
    echo -e "  服务:     ${RED}● ${svc_status}${NC}"
  fi
  if [[ "$svc_enabled" == "enabled" ]]; then
    echo -e "  开机自启: ${GREEN}已开启${NC}"
  else
    echo -e "  开机自启: ${YELLOW}${svc_enabled}${NC}"
  fi

  # ── 运行时资源 ────────────────────────────
  if [[ "$svc_status" == "active" ]] && command -v docker >/dev/null 2>&1; then
    echo -e "\n${BOLD}[ 运行时资源 ]${NC}"
    local total_c running_c stopped_c
    total_c=$(docker ps -aq 2>/dev/null | wc -l)
    running_c=$(docker ps -q 2>/dev/null | wc -l)
    stopped_c=$(( total_c - running_c ))
    echo -e "  容器: ${GREEN}${running_c} 运行中${NC} / ${YELLOW}${stopped_c} 已停止${NC} / 共 ${total_c}"
    echo -e "  镜像: $(docker images -q 2>/dev/null | wc -l) 个"
    echo -e "  数据卷: $(docker volume ls -q 2>/dev/null | wc -l) 个"
    echo -e "  网络: $(docker network ls -q 2>/dev/null | wc -l) 个"

    echo -e "\n${BOLD}[ 磁盘占用 ]${NC}"
    docker system df 2>/dev/null | while IFS= read -r line; do
      echo "  $line"
    done

    local running_list
    running_list=$(docker ps --format \
      "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null)
    if [[ -n "$running_list" ]]; then
      echo -e "\n${BOLD}[ 运行中容器 ]${NC}"
      echo "$running_list" | while IFS= read -r line; do
        echo "  $line"
      done
    fi
  fi

  # ── 镜像加速源 ────────────────────────────
  echo -e "\n${BOLD}[ 镜像加速源 ]${NC}"
  echo -e "  ${CYAN}脚本内置默认源（共 ${#REGISTRY_MIRRORS_DEFAULT[@]} 个）:${NC}"
  for m in "${REGISTRY_MIRRORS_DEFAULT[@]}"; do
    echo -e "    ${CYAN}• ${m}${NC}"
  done

  # ── 配置文件状态 ──────────────────────────
  echo -e "\n${BOLD}[ daemon.json 配置 ]${NC}"
  if [[ -f /etc/docker/daemon.json ]]; then
    if jq . /etc/docker/daemon.json >/dev/null 2>&1; then
      echo -e "  状态:     ${GREEN}存在，格式合法${NC}"
      local mirrors storage log_driver data_root
      mirrors=$(jq -r '.["registry-mirrors"][]? // empty' /etc/docker/daemon.json 2>/dev/null)
      storage=$(jq -r '."storage-driver" // "overlay2 (默认)"' /etc/docker/daemon.json 2>/dev/null)
      log_driver=$(jq -r '."log-driver" // "json-file (默认)"' /etc/docker/daemon.json 2>/dev/null)
      data_root=$(jq -r '."data-root" // "/var/lib/docker (默认)"' /etc/docker/daemon.json 2>/dev/null)
      if [[ -n "$mirrors" ]]; then
        echo -e "  镜像加速:"
        while IFS= read -r m; do
          echo -e "    ${CYAN}• ${m}${NC}"
        done <<< "$mirrors"
      else
        echo -e "  镜像加速: ${YELLOW}未配置${NC}"
      fi
      echo -e "  存储驱动: ${CYAN}${storage}${NC}"
      echo -e "  日志驱动: ${CYAN}${log_driver}${NC}"
      echo -e "  数据目录: ${CYAN}${data_root}${NC}"
    else
      echo -e "  状态:     ${RED}存在，但 JSON 格式错误！${NC}"
    fi
    local bak_count
    bak_count=$(find "$DAEMON_BACKUP_DIR" -maxdepth 1 -name "daemon.json.*" 2>/dev/null | wc -l)
    echo -e "  备份数量: ${bak_count} 个（目录: ${DAEMON_BACKUP_DIR}）"
  else
    echo -e "  状态:     ${YELLOW}daemon.json 不存在${NC}"
  fi

  # ── 系统信息 ──────────────────────────────
  echo -e "\n${BOLD}[ 系统信息 ]${NC}"
  echo -e "  架构:   $(uname -m)"
  echo -e "  内核:   $(uname -r)"
  echo -e "  系统:   $(get_os_version 2>/dev/null)"
  local mem_total mem_free
  mem_total=$(free -m 2>/dev/null | awk '/^Mem/{print $2}')
  mem_free=$(free -m 2>/dev/null | awk '/^Mem/{print $4}')
  echo -e "  内存:   已用 $((mem_total - mem_free))MB / 共 ${mem_total}MB"
  echo -e "  根分区: $(df -h / 2>/dev/null | tail -1 | \
    awk '{print "已用 "$3" / 共 "$2" ("$5" used)"}')"

  # ── 日志信息 ──────────────────────────────
  echo -e "\n${BOLD}[ 日志信息 ]${NC}"
  if [[ -f "$LOG_FILE" ]]; then
    local log_size
    log_size=$(du -sh "$LOG_FILE" 2>/dev/null | awk '{print $1}')
    local log_bak
    log_bak=$(find "$LOG_DIR" -maxdepth 1 -name "*.gz" 2>/dev/null | wc -l)
    echo -e "  当前日志: ${log_size}  (上限: ${LOG_MAX_SIZE_MB}MB)"
    echo -e "  历史备份: ${log_bak} 个  (上限: ${LOG_MAX_BACKUPS} 个)"
    echo -e "  日志路径: ${LOG_FILE}"
  else
    echo -e "  ${YELLOW}日志文件不存在${NC}"
  fi

  echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${NC}\n"
}

#====================== 日志管理菜单 ======================#

_human_size() {
  du -sh "$1" 2>/dev/null | awk '{print $1}' || echo "未知"
}

manage_logs() {
  while true; do
    local current_size="N/A" total_size="N/A" backup_count=0
    [[ -f "$LOG_FILE" ]] && current_size=$(_human_size "$LOG_FILE")
    backup_count=$(find "$LOG_DIR" -maxdepth 1 -name "*.gz" 2>/dev/null | wc -l)
    [[ -d "$LOG_DIR" ]] && total_size=$(_human_size "$LOG_DIR")

    echo -e "\n${CYAN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              日志管理                    ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
    echo -e "  日志目录:   ${LOG_DIR}"
    echo -e "  当前日志:   ${current_size}  (上限: ${LOG_MAX_SIZE_MB}MB)"
    echo -e "  历史备份:   ${backup_count} 个  (上限: ${LOG_MAX_BACKUPS} 个)"
    echo -e "  目录总占用: ${total_size}"
    echo -e "${CYAN}──────────────────────────────────────────${NC}"
    echo "  1. 查看当前日志（最后 50 行）"
    echo "  2. 查看所有历史备份"
    echo "  3. 立即手动轮转日志"
    echo "  4. 清空当前日志"
    echo "  5. 删除所有历史备份（保留当前）"
    echo "  6. 删除全部日志（当前 + 历史）"
    echo "  7. 修改日志策略（大小上限 / 保留数量）"
    echo "  0. 返回主菜单"
    echo -e "${CYAN}──────────────────────────────────────────${NC}"
    read -r -p "请选择操作: " LCHOICE

    case "$LCHOICE" in
      1)
        if [[ ! -f "$LOG_FILE" ]]; then
          echo -e "${YELLOW}当前日志文件不存在。${NC}"
        else
          echo -e "${CYAN}── 当前日志（最后 50 行）──${NC}"
          tail -n 50 "$LOG_FILE"
          echo -e "${CYAN}────────────────────────────${NC}"
          echo -e "完整日志路径: ${LOG_FILE}"
        fi
        ;;
      2)
        local backups=()
        while IFS= read -r -d '' f; do
          backups+=("$f")
        done < <(find "$LOG_DIR" -maxdepth 1 -name "*.gz" -print0 2>/dev/null | sort -z)
        if [[ ${#backups[@]} -eq 0 ]]; then
          echo -e "${YELLOW}暂无历史备份。${NC}"
        else
          echo -e "${CYAN}历史备份列表：${NC}"
          local i=1
          for f in "${backups[@]}"; do
            printf "  %2d) %-45s  %s\n" "$i" "$(basename "$f")" "$(_human_size "$f")"
            ((i++))
          done
          read -r -p "是否查看某个备份内容？输入编号（回车跳过）: " BIDX
          if [[ "$BIDX" =~ ^[0-9]+$ ]] && \
             (( BIDX >= 1 && BIDX <= ${#backups[@]} )); then
            echo -e "${CYAN}── 备份内容（最后 50 行）──${NC}"
            zcat "${backups[$((BIDX-1))]}" 2>/dev/null | tail -n 50
          fi
        fi
        ;;
      3)
        local old_max=$LOG_MAX_SIZE_MB
        LOG_MAX_SIZE_MB=0
        rotate_log
        LOG_MAX_SIZE_MB=$old_max
        echo -e "${GREEN}手动轮转完成。${NC}"
        ;;
      4)
        read -r -p "确认清空当前日志内容？操作不可恢复 (y/n): " CONFIRM
        if [[ "$CONFIRM" == "y" ]]; then
          : > "$LOG_FILE"
          echo "[$(date '+%Y-%m-%d %H:%M:%S')] 日志已手动清空。" >> "$LOG_FILE"
          echo -e "${GREEN}当前日志已清空。${NC}"
        else
          echo -e "${YELLOW}已取消。${NC}"
        fi
        ;;
      5)
        local gz_files=()
        while IFS= read -r -d '' f; do
          gz_files+=("$f")
        done < <(find "$LOG_DIR" -maxdepth 1 -name "*.gz" -print0 2>/dev/null)
        if [[ ${#gz_files[@]} -eq 0 ]]; then
          echo -e "${YELLOW}没有历史备份文件。${NC}"
        else
          read -r -p "确认删除 ${#gz_files[@]} 个历史备份？(y/n): " CONFIRM
          if [[ "$CONFIRM" == "y" ]]; then
            rm -f "${gz_files[@]}"
            echo -e "${GREEN}已删除所有历史备份。${NC}"
          else
            echo -e "${YELLOW}已取消。${NC}"
          fi
        fi
        ;;
      6)
        read -r -p "确认删除所有日志（含当前 + 历史）？操作不可恢复 (y/n): " CONFIRM
        if [[ "$CONFIRM" == "y" ]]; then
          find "$LOG_DIR" -maxdepth 1 -name "*.gz" -delete 2>/dev/null
          : > "$LOG_FILE"
          echo "[$(date '+%Y-%m-%d %H:%M:%S')] 所有日志已清除。" >> "$LOG_FILE"
          echo -e "${GREEN}所有日志已清除。${NC}"
        else
          echo -e "${YELLOW}已取消。${NC}"
        fi
        ;;
      7)
        echo -e "${CYAN}当前策略: 单文件上限 ${LOG_MAX_SIZE_MB}MB，保留 ${LOG_MAX_BACKUPS} 个备份${NC}"
        read -r -p "新的单文件大小上限 MB（当前 ${LOG_MAX_SIZE_MB}，回车不改）: " NEW_SIZE
        if [[ "$NEW_SIZE" =~ ^[0-9]+$ ]] && (( NEW_SIZE > 0 )); then
          LOG_MAX_SIZE_MB=$NEW_SIZE
          echo -e "${GREEN}大小上限已更新为 ${LOG_MAX_SIZE_MB}MB${NC}"
        elif [[ -n "$NEW_SIZE" ]]; then
          echo -e "${RED}无效输入，保持原值 ${LOG_MAX_SIZE_MB}MB${NC}"
        fi
        read -r -p "新的历史备份保留数量（当前 ${LOG_MAX_BACKUPS}，回车不改）: " NEW_BACKUPS
        if [[ "$NEW_BACKUPS" =~ ^[0-9]+$ ]] && (( NEW_BACKUPS >= 1 )); then
          LOG_MAX_BACKUPS=$NEW_BACKUPS
          echo -e "${GREEN}保留数量已更新为 ${LOG_MAX_BACKUPS} 个${NC}"
        elif [[ -n "$NEW_BACKUPS" ]]; then
          echo -e "${RED}无效输入，保持原值 ${LOG_MAX_BACKUPS} 个${NC}"
        fi
        echo -e "${YELLOW}注意：策略修改仅对本次会话有效。"
        echo -e "如需永久生效，请修改脚本顶部 LOG_MAX_SIZE_MB / LOG_MAX_BACKUPS 变量。${NC}"
        ;;
      0) break ;;
      *) echo -e "${RED}无效的选择，请重试。${NC}" ;;
    esac
  done
}

#====================== 核心：安装/卸载 ======================#

install_docker() {
  if check_docker_installed; then
    read -r -p "Docker 已安装，是否重新安装？(y/n): " REINSTALL
    [[ "$REINSTALL" != "y" ]] && { echo -e "${YELLOW}跳过 Docker 安装。${NC}"; return; }
  fi

  ensure_docker_prereqs

  ARCH=$(get_architecture)
  check_and_set_install_dir

  local VERSION

  if [[ "$FORCE_LEGACY_DOCKER" == "true" ]]; then
    echo -e "${YELLOW}由于系统环境限制，将为您安装兼容性最好的旧版 Docker。${NC}"
    VERSION="$RECOMMENDED_LEGACY_DOCKER_VERSION"
    local available_versions
    available_versions=$(fetch_docker_versions)
    if ! echo "$available_versions" | grep -q "^${VERSION}$"; then
      echo -e "${RED}推荐的兼容版本 ${VERSION} 不在可用列表中！安装中止。${NC}"
      exit 1
    fi
  else
    echo "获取可用 Docker 版本..."
    mapfile -t VERSIONS_ARR <<< "$(fetch_docker_versions)"
    VERSION=$(select_version "${VERSIONS_ARR[@]}")
    [[ -z "$VERSION" ]] && { echo -e "${RED}未获得版本号${NC}"; exit 1; }
  fi

  echo -e "${GREEN}选择的 Docker 版本：$VERSION${NC}"
  DOCKER_URL="${DOCKER_VERSIONS_URL}${ARCH}/docker-${VERSION}.tgz"

  echo "下载 Docker 二进制包：$DOCKER_URL"
  if ! download_with_fallback "$DOCKER_URL" "$DOCKER_INSTALL_DIR/docker.tgz"; then
    echo -e "${RED}所有下载方式均失败，请检查网络后重试。${NC}"
    rm -rf "$DOCKER_INSTALL_DIR"
    exit 1
  fi

  echo "解压 Docker 包..."
  tar -zxf "$DOCKER_INSTALL_DIR/docker.tgz" -C "$DOCKER_INSTALL_DIR" || {
    echo -e "${RED}解压失败${NC}"; rm -rf "$DOCKER_INSTALL_DIR"; exit 1; }

  echo "安装 Docker 二进制到 /usr/local/bin ..."
  chown root:root "$DOCKER_INSTALL_DIR/docker/"*
  mv "$DOCKER_INSTALL_DIR/docker/"* /usr/local/bin/ || {
    echo -e "${RED}移动文件失败${NC}"; exit 1; }

  echo "创建 docker 用户组..."
  groupadd -f docker
  CURRENT_USER="${SUDO_USER:-$USER}"
  if [[ -n "$CURRENT_USER" && "$CURRENT_USER" != "root" ]]; then
    gpasswd -a "$CURRENT_USER" docker >/dev/null 2>&1 || true
  fi

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
  mapfile -t COMPOSE_ARR <<< "$(fetch_docker_compose_versions)"
  local COMPOSE_VERSION
  COMPOSE_VERSION=$(select_version "${COMPOSE_ARR[@]}")
  if [[ -z "$COMPOSE_VERSION" ]]; then
    echo -e "${YELLOW}未选择，将安装最新版本...${NC}"
    COMPOSE_VERSION=$(curl -s --connect-timeout 15 \
      https://api.github.com/repos/docker/compose/releases/latest | jq -r .tag_name)
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
        x86_64)  compose_file="docker-compose-linux-x86_64" ;;
        aarch64) compose_file="docker-compose-linux-aarch64" ;;
        armv7l)  compose_file="docker-compose-linux-armv7" ;;
        armv6l)  compose_file="docker-compose-linux-armv6" ;;
        *) echo -e "${RED}不支持的 Linux 架构: $arch_name${NC}"; exit 1 ;;
      esac ;;
    Darwin)
      case "$arch_name" in
        x86_64) compose_file="docker-compose-darwin-x86_64" ;;
        arm64)  compose_file="docker-compose-darwin-aarch64" ;;
        *) echo -e "${RED}不支持的 macOS 架构: $arch_name${NC}"; exit 1 ;;
      esac ;;
    *) echo -e "${RED}不支持的操作系统: $os_name${NC}"; exit 1 ;;
  esac

  local COMPOSE_URL="https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/${compose_file}"
  echo "下载 Docker Compose：$COMPOSE_URL"
  if ! download_with_fallback "$COMPOSE_URL" "/usr/local/bin/docker-compose"; then
    echo -e "${RED}Docker Compose 下载失败，请检查网络后重试。${NC}"
    exit 1
  fi
  chmod +x /usr/local/bin/docker-compose

  mkdir -p /usr/local/lib/docker/cli-plugins
  cp /usr/local/bin/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose

  echo -e "${GREEN}Docker Compose 安装完成（支持 docker compose 与 docker-compose）。${NC}"
}

uninstall_docker() {
  echo "正在卸载 Docker..."

  if systemctl is-active --quiet docker 2>/dev/null; then
    read -r -p "是否清理所有容器/镜像/数据卷？(y/n): " DOPRUNE
    [[ "$DOPRUNE" == "y" ]] && docker system prune -a -f 2>/dev/null || true
  fi

  systemctl stop docker.service 2>/dev/null || true
  systemctl disable docker.service 2>/dev/null || true

  case "$PKG_MANAGER" in
    apt-get)
      apt-get remove -y --purge docker docker-engine docker.io \
        containerd runc docker-ce docker-ce-cli 2>/dev/null || true ;;
    dnf|yum)
      "${PKG_MANAGER}" remove -y docker docker-engine docker.io \
        containerd runc docker-ce docker-ce-cli 2>/dev/null || true ;;
  esac

  rm -rf /var/lib/docker /etc/docker /usr/local/bin/docker* \
    /usr/bin/docker* /usr/sbin/docker* /opt/docker
  rm -f /etc/systemd/system/docker.service /etc/systemd/system/docker.socket
  rm -f /etc/modules-load.d/docker.conf /etc/sysctl.d/99-docker.conf
  rm -rf /var/lib/containerd /run/containerd \
    /usr/local/bin/containerd* /usr/local/bin/runc 2>/dev/null || true

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
  backup_daemon_json

  local DEFAULT_DATA_ROOT="/var/lib/docker"
  local DEFAULT_LOG_MAX_SIZE="10m"
  local DEFAULT_LOG_MAX_FILE="3"

  read -r -p "请输入 Docker data-root 路径 (默认: ${DEFAULT_DATA_ROOT}): " DATA_ROOT_INPUT
  local DATA_ROOT="${DATA_ROOT_INPUT:-${DEFAULT_DATA_ROOT}}"

  local REGISTRY_MIRRORS_JSON
  REGISTRY_MIRRORS_JSON=$(printf '%s\n' "${REGISTRY_MIRRORS_DEFAULT[@]}" | jq -R . | jq -s .)

  local DAEMON_CONFIG
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
    echo -e "${RED}生成的 JSON 格式不正确。${NC}"
    exit 1
  fi

  mkdir -p /etc/docker
  if echo "$DAEMON_CONFIG" > /etc/docker/daemon.json; then
    echo -e "${GREEN}/etc/docker/daemon.json 生成成功。${NC}"
    read -r -p "是否立即重启 Docker 以应用配置？(y/n): " DORESTART
    [[ "$DORESTART" == "y" ]] && _restart_docker
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
    echo -e "${YELLOW}提示: Docker 目前对 nf_tables 支持不完善，建议使用 legacy 模式。${NC}"
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

print_menu() {
  echo -e "\n${BOLD}${CYAN}╔══════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYAN}║      Docker / Compose 智能管理脚本       ║${NC}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════╝${NC}"
  echo -e "  架构: ${ARCH}  |  系统: ${OS}  |  包管理: ${PKG_MANAGER}"
  echo -e "${CYAN}──────────────────────────────────────────${NC}"
  echo -e "  ${GREEN}1.${NC}  安装 Docker"
  echo -e "  ${GREEN}2.${NC}  安装 Docker Compose"
  echo -e "  ${GREEN}3.${NC}  安装 Docker 和 Docker Compose"
  echo -e "  ${RED}4.${NC}  卸载 Docker"
  echo -e "  ${RED}5.${NC}  卸载 Docker Compose"
  echo -e "  ${RED}6.${NC}  卸载 Docker 和 Docker Compose"
  echo -e "${CYAN}──────────────────────────────────────────${NC}"
  echo -e "  ${YELLOW}7.${NC}  查询安装状态"
  echo -e "  ${YELLOW}8.${NC}  生成 daemon.json 配置文件"
  echo -e "  ${YELLOW}9.${NC}  查看当前 iptables 后端模式"
  echo -e "${CYAN}──────────────────────────────────────────${NC}"
  echo -e "  ${BLUE}10.${NC} Docker 服务管理（启动 / 停止 / 重启）"
  echo -e "  ${BLUE}11.${NC} Docker 状态仪表盘"
  echo -e "  ${BLUE}12.${NC} daemon.json 备份与回滚"
  echo -e "  ${BLUE}13.${NC} 日志管理"
  echo -e "${CYAN}──────────────────────────────────────────${NC}"
  echo -e "  ${RED}0.${NC}  退出脚本"
  echo -e "${CYAN}──────────────────────────────────────────${NC}"
  echo -e "  日志: ${LOG_FILE}"
}

main() {
  check_sudo
  detect_package_manager
  init_log
  install_dependencies

  echo "检测系统信息..."
  ARCH=$(get_architecture)
  OS=$(get_os_version)

  while true; do
    print_menu
    read -r -p "请输入数字 (0-13): " CHOICE

    if [[ -z "$CHOICE" ]]; then
      echo -e "${RED}请输入有效数字。${NC}"
      continue
    fi
    if ! [[ "$CHOICE" =~ ^[0-9]+$ ]]; then
      echo -e "${RED}无效的选择，请输入数字。${NC}"
      continue
    fi

    case "$CHOICE" in
      1)  install_docker ;;
      2)  install_docker_compose ;;
      3)  install_docker; install_docker_compose ;;
      4)  uninstall_docker ;;
      5)  uninstall_docker_compose ;;
      6)  uninstall_docker; uninstall_docker_compose ;;
      7)  check_docker_installed; check_docker_compose_installed ;;
      8)  generate_daemon_config ;;
      9)  check_iptables_mode ;;
      10) manage_docker_service ;;
      11) show_docker_status ;;
      12) manage_daemon_json ;;
      13) manage_logs ;;
      0)
        echo -e "${GREEN}退出脚本。日志已保存至: ${LOG_FILE}${NC}"
        break
        ;;
      *)
        echo -e "${RED}无效的选择，请输入 0-13 之间的数字。${NC}"
        continue
        ;;
    esac

    [[ "$CHOICE" -ne 0 ]] && read -n 1 -s -r -p $'\n按任意键返回主菜单...'
  done
}

main
