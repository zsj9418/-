#!/bin/bash
set -uo pipefail
trap 'echo "[!] 已中断"; exit 1' INT

SCRIPT_VERSION="4.1"
SCRIPT_LOG_FILE="/var/log/casaos_zimaos_deploy.log"
DOCKER_CONFIG_FILE="/etc/docker/daemon.json"

ARCH=""
CASAOS_INSTALL_TYPE="unknown"
CASAOS_PORT=80
CASAOS_CONTAINER_NAME="casa"
PKG_MGR=""
PKG_UPDATE=""
PKG_INSTALL=""
OS_ID=""
OS_NAME=""

CASA_IMAGE_GHCR="ghcr.io/dockur/casa"
CASA_IMAGE_DOCKERHUB="dockurr/casa"

ZIMAOS_GITHUB_REPO="IceWhaleTech/ZimaOS"
ZIMAOS_RELEASES_URL="https://github.com/${ZIMAOS_GITHUB_REPO}/releases"

GH_MIRRORS=(
  ""
  "https://gh-proxy.com/"
  "https://ghproxy.link/"
  "https://ghfast.top/"
  "https://ghps.cc/"
)

RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; RESET='\033[0m'

_ok()   { echo -e "${GREEN}[✓]${RESET} $*"; }
_warn() { echo -e "${YELLOW}[!]${RESET} $*"; }
_err()  { echo -e "${RED}[x]${RESET} $*" >&2; }
_info() { echo -e "[i] $*"; }

press_any_key() {
  echo ""
  read -rn1 -s -p "按任意键返回..." _j </dev/tty || true
  echo ""
}

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
  echo "$msg" >> "$SCRIPT_LOG_FILE" 2>/dev/null || true
  echo -e "$1"
}

_have() { command -v "$1" >/dev/null 2>&1; }
# ── Docker 安装公共函数（统一模块）──SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"[[ -f "${SCRIPT_DIR}/docker-install-common.sh" ]] && source "${SCRIPT_DIR}/docker-install-common.sh"

if [[ "${EUID}" -ne 0 ]]; then
  _err "请以 root 权限运行此脚本"
  exit 1
fi

mkdir -p "$(dirname "$SCRIPT_LOG_FILE")" 2>/dev/null || SCRIPT_LOG_FILE="/tmp/casaos_zimaos_deploy.log"
touch "$SCRIPT_LOG_FILE" 2>/dev/null || true
log "### CasaOS/ZimaOS 部署脚本 v${SCRIPT_VERSION} 启动 ###"

detect_pkg_manager() {
  if _have apt-get; then
    PKG_MGR="apt"; PKG_UPDATE="apt-get update -qq"; PKG_INSTALL="apt-get install -y -qq"
  elif _have dnf; then
    PKG_MGR="dnf"; PKG_UPDATE="dnf makecache -q"; PKG_INSTALL="dnf install -y -q"
  elif _have yum; then
    PKG_MGR="yum"; PKG_UPDATE="yum makecache -q"; PKG_INSTALL="yum install -y -q"
  elif _have pacman; then
    PKG_MGR="pacman"; PKG_UPDATE="pacman -Sy --noconfirm -q"; PKG_INSTALL="pacman -S --noconfirm -q"
  else
    PKG_MGR="none"; PKG_UPDATE=":"; PKG_INSTALL=":"
    _warn "未检测到支持的包管理器"
  fi
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)        ARCH="amd64" ;;
    aarch64|arm64)       ARCH="arm64" ;;
    armv7l|armhf)        ARCH="armv7" ;;
    riscv64)             ARCH="riscv64" ;;
    loong64|loongarch64) ARCH="loong64" ;;
    i386|i686)           ARCH="386" ;;
    *)
      _err "不支持的架构：$(uname -m)"
      return 1
      ;;
  esac
  _info "系统架构：$(uname -m) → $ARCH"
}

detect_os() {
  OS_ID=""
  OS_NAME=""
  if [[ -f /etc/os-release ]]; then
    OS_ID=$(grep "^ID=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]' || echo "")
    OS_NAME=$(grep "^PRETTY_NAME=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "未知")
  fi
  _info "操作系统：${OS_NAME:-未知}"
}

check_casaos_status() {
  CASAOS_INSTALL_TYPE="unknown"
  CASAOS_PORT=80
  CASAOS_CONTAINER_NAME="casa"

  if _have casaos && \
     systemctl list-unit-files 2>/dev/null | grep -qE 'casaos\.service|casaos-gateway\.service'; then
    CASAOS_INSTALL_TYPE="standard"
    local gw_port
    gw_port=$(grep -Po 'Listen\s*:\s*\K[0-9]+' /etc/casaos/gateway.ini 2>/dev/null || echo "")
    CASAOS_PORT="${gw_port:-80}"
    return 0
  fi

  if _have docker; then
    local cname
    for cname in casaos casa; do
      if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${cname}$"; then
        CASAOS_INSTALL_TYPE="docker"
        CASAOS_CONTAINER_NAME="$cname"
        local pm
        pm=$(docker port "$cname" 8080/tcp 2>/dev/null | head -n1 || \
             docker port "$cname" 80/tcp 2>/dev/null | head -n1 || echo "")
        if [[ "$pm" =~ :([0-9]+)$ ]]; then
          CASAOS_PORT="${BASH_REMATCH[1]}"
        else
          CASAOS_PORT=8080
        fi
        return 0
      fi
    done
  fi

  return 1
}

get_local_ip() {
  local ip=""
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' | head -n1 || true)
  [[ -z "$ip" ]] && ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
  echo "${ip:-<本机IP>}"
}

select_casa_image() {
  echo ""
  echo "请选择镜像拉取源："
  echo "  1. ghcr.io/dockur/casa  （GitHub，推荐，国内直连更快，无速率限制）"
  echo "  2. dockurr/casa         （Docker Hub，需配合镜像加速器）"
  read -rp "选项 [默认 1]: " img_src_choice </dev/tty
  case "${img_src_choice:-1}" in
    2) SELECTED_CASA_IMAGE="$CASA_IMAGE_DOCKERHUB" ;;
    *) SELECTED_CASA_IMAGE="$CASA_IMAGE_GHCR" ;;
  esac
  _info "使用镜像源：$SELECTED_CASA_IMAGE"
}


ensure_docker_running() {
  if ! _have docker; then
    _err "Docker 未安装，请先通过菜单安装 Docker"
    return 1
  fi
  if ! docker info >/dev/null 2>&1; then
    _warn "Docker 未运行，尝试启动..."
    if _have systemctl; then
      systemctl start docker >/dev/null 2>&1 || true
    fi
    sleep 3
    if ! docker info >/dev/null 2>&1; then
      _err "Docker 守护进程无法启动，请检查：journalctl -u docker -n 50"
      return 1
    fi
  fi
  return 0
}

config_docker_mirror() {
  echo ""
  echo "===== 配置 Docker 镜像加速器 ====="

  ensure_docker_running || { press_any_key; return 1; }

  local candidates=(
    "https://docker.m.daocloud.io"
    "https://docker.nju.edu.cn"
    "https://mirror.baidubce.com"
    "https://docker.1ms.run"
    "https://dockerproxy.com"
  )

  local available_mirrors=()
  _info "测试镜像源连通性，请稍候..."

  for mirror in "${candidates[@]}"; do
    local http_code
    http_code=$(curl -o /dev/null -s -m 8 -w "%{http_code}" "${mirror}/v2/" 2>/dev/null || echo "000")
    if [[ "$http_code" =~ ^(200|301|302|401)$ ]]; then
      available_mirrors+=("$mirror")
      _ok "可用：$mirror（${http_code}）"
    else
      _warn "不可达：$mirror（${http_code}）"
    fi
  done

  if [[ ${#available_mirrors[@]} -eq 0 ]]; then
    _warn "所有预设镜像源均不可达，跳过配置"
    press_any_key; return 0
  fi

  echo ""
  read -rp "是否将以上可用源写入 Docker 配置并重启 Docker？(y/N): " confirm </dev/tty
  [[ "${confirm,,}" == "y" ]] || { _warn "已取消"; press_any_key; return 0; }

  if [[ -f "$DOCKER_CONFIG_FILE" ]]; then
    local bak="${DOCKER_CONFIG_FILE}.bak_$(date +%Y%m%d%H%M%S)"
    cp "$DOCKER_CONFIG_FILE" "$bak" && _info "原配置已备份：$bak"
  fi
  mkdir -p /etc/docker

  local mirror_list=""
  local first=true
  for m in "${available_mirrors[@]}"; do
    if [[ "$first" == true ]]; then
      mirror_list="\"$m\""
      first=false
    else
      mirror_list+=", \"$m\""
    fi
  done

  if _have python3; then
    python3 - <<PYEOF
import json, sys, os

cfg_file = '$DOCKER_CONFIG_FILE'
try:
    with open(cfg_file, 'r') as f:
        data = json.load(f)
except Exception:
    data = {}

data['registry-mirrors'] = [${mirror_list}]
data.setdefault('live-restore', True)
data.setdefault('log-driver', 'json-file')
data.setdefault('log-opts', {'max-size': '20m', 'max-file': '3'})

with open(cfg_file, 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
print('配置写入成功')
PYEOF
  else
    cat > "$DOCKER_CONFIG_FILE" << JSONEOF
{
  "registry-mirrors": [${mirror_list}],
  "live-restore": true,
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "20m",
    "max-file": "3"
  }
}
JSONEOF
  fi

  if [[ $? -ne 0 ]]; then
    _err "配置文件写入失败"
    press_any_key; return 1
  fi

  if _have systemctl; then
    systemctl daemon-reload 2>/dev/null || true
    if ! systemctl restart docker 2>/dev/null; then
      _err "Docker 重启失败，请检查配置：cat $DOCKER_CONFIG_FILE"
      press_any_key; return 1
    fi
  fi

  sleep 3
  _ok "Docker 镜像加速器配置完成"
  docker info 2>/dev/null | grep -A8 "Registry Mirrors" || true
  press_any_key
}

pre_flight_check() {
  echo ""
  echo "===== 环境检查 ====="

  detect_os
  detect_arch || return 1

  local mem_mb; mem_mb=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}' || echo "未知")
  local disk_avail; disk_avail=$(df -BG / 2>/dev/null | awk 'NR==2{print $4}' | tr -d 'G' || echo "未知")
  _info "系统内存：${mem_mb}MB    根分区可用：${disk_avail}GB"

  if [[ "$mem_mb" != "未知" && "$mem_mb" -lt 512 ]]; then
    _warn "内存不足 512MB（当前 ${mem_mb}MB），CasaOS 可能运行不稳定"
  fi
  if [[ "$disk_avail" != "未知" && "$disk_avail" -lt 8 ]]; then
    _warn "磁盘可用空间不足 8GB（当前 ${disk_avail}GB），建议清理后再安装"
  fi

  _info "检查网络连通性..."

  if curl -fsSL --connect-timeout 8 https://get.casaos.io -o /dev/null 2>/dev/null; then
    _ok "get.casaos.io 可达"
  else
    _warn "get.casaos.io 不可达，标准安装可能失败"
  fi

  if curl -fsSL --connect-timeout 8 https://ghcr.io -o /dev/null 2>/dev/null; then
    _ok "ghcr.io 可达（推荐镜像源）"
  else
    _warn "ghcr.io 不可达，建议切换到 Docker Hub + 加速器"
  fi

  if curl -fsSL --connect-timeout 8 https://hub.docker.com -o /dev/null 2>/dev/null; then
    _ok "Docker Hub 可达"
  else
    _warn "Docker Hub 不可达，建议先配置镜像加速器（选项 8）"
  fi

  if curl -fsSL --connect-timeout 8 https://github.com -o /dev/null 2>/dev/null; then
    _ok "GitHub 可达"
  else
    _warn "GitHub 不可达，ZimaOS 下载和版本查询可能受影响"
  fi

  if _have docker && docker info >/dev/null 2>&1; then
    _ok "Docker：$(docker --version 2>/dev/null | head -n1)"
  else
    _warn "Docker 未安装或未运行"
  fi

  echo "===================="
  return 0
}

install_docker_only() {
  echo ""
  echo "===== 安装 Docker ====="
  pre_flight_check || { press_any_key; return; }
  install_docker || { press_any_key; return; }
  _ok "Docker 安装完成"
  press_any_key
}

install_casaos_standard() {
  echo ""
  echo "===== 安装 CasaOS（官方标准方式）====="

  if [[ "$ARCH" != "amd64" && "$ARCH" != "arm64" && "$ARCH" != "armv7" ]]; then
    _warn "当前架构 $ARCH 不在 CasaOS 官方支持列表（amd64/arm64/armv7）"
    read -rp "是否仍然继续尝试安装？(y/N): " force_arch </dev/tty
    [[ "${force_arch,,}" == "y" ]] || { press_any_key; return; }
  fi

  pre_flight_check || { press_any_key; return 1; }
  install_docker || { press_any_key; return 1; }

  echo ""
  read -rp "是否在安装前配置 Docker 镜像加速器？(y/N): " do_mirror </dev/tty
  [[ "${do_mirror,,}" == "y" ]] && config_docker_mirror

  _info "执行 CasaOS 官方安装脚本..."
  log "开始 CasaOS 标准安装"

  if ! curl -fsSL https://get.casaos.io | bash; then
    _err "官方安装脚本执行失败"
    _info "请检查日志：/var/log/casaos/install.log"
    press_any_key; return 1
  fi

  sleep 5
  check_casaos_status
  if [[ "$CASAOS_INSTALL_TYPE" == "standard" ]]; then
    local ip; ip=$(get_local_ip)
    _ok "CasaOS 标准安装成功！"
    _info "访问地址：http://${ip}:${CASAOS_PORT}"
    log "CasaOS 标准安装成功，端口：${CASAOS_PORT}"
  else
    _err "安装后验证失败，请检查：/var/log/casaos/install.log"
    _info "尝试手动检查：systemctl status casaos-gateway"
    press_any_key; return 1
  fi

  press_any_key
}

install_casaos_docker() {
  echo ""
  echo "===== 使用 Docker 部署 CasaOS ====="

  pre_flight_check || { press_any_key; return 1; }
  install_docker || { press_any_key; return 1; }
  ensure_docker_running || { press_any_key; return 1; }

  select_casa_image

  if [[ "$SELECTED_CASA_IMAGE" == "$CASA_IMAGE_DOCKERHUB" ]]; then
    echo ""
    read -rp "是否在部署前配置 Docker 镜像加速器？(y/N): " do_mirror </dev/tty
    [[ "${do_mirror,,}" == "y" ]] && config_docker_mirror
  fi

  for cname in casaos casa; do
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${cname}$"; then
      _warn "检测到已存在容器：$cname"
      read -rp "停止并移除现有容器以重新部署？(y/N): " rm_existing </dev/tty
      if [[ "${rm_existing,,}" == "y" ]]; then
        docker stop "$cname" >/dev/null 2>&1 || true
        docker rm "$cname" >/dev/null 2>&1 || true
        _ok "容器 $cname 已移除"
      else
        _warn "已取消"; press_any_key; return
      fi
    fi
  done

  local default_data_dir="${HOME}/casa"
  echo ""
  read -rp "数据目录（本机路径） [默认: $default_data_dir]: " input_dir </dev/tty
  local data_dir="${input_dir:-$default_data_dir}"

  read -rp "映射端口 [默认: 8080]: " input_port </dev/tty
  local port="${input_port:-8080}"
  if ! [[ "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 || "$port" -gt 65535 ]]; then
    _warn "端口无效，使用默认 8080"
    port=8080
  fi

  read -rp "镜像标签 [默认: latest]: " input_tag </dev/tty
  local tag="${input_tag:-latest}"

  _info "拉取镜像：${SELECTED_CASA_IMAGE}:${tag}"
  if ! docker pull "${SELECTED_CASA_IMAGE}:${tag}"; then
    _err "镜像拉取失败"
    if [[ "$SELECTED_CASA_IMAGE" == "$CASA_IMAGE_GHCR" ]]; then
      _info "ghcr.io 拉取失败，可重新选择并改用 Docker Hub + 加速器"
    else
      _info "请检查网络或配置镜像加速器（选项 8）"
    fi
    press_any_key; return 1
  fi

  if ! mkdir -p "$data_dir" 2>/dev/null; then
    _err "无法创建数据目录：$data_dir"
    press_any_key; return 1
  fi

  _info "创建并启动容器..."
  local run_result=0
  docker run -d \
    --name casa \
    --restart=always \
    -p "${port}:8080" \
    -v "${data_dir}:/DATA" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    --stop-timeout 60 \
    "${SELECTED_CASA_IMAGE}:${tag}" || run_result=$?

  if [[ $run_result -ne 0 ]]; then
    _err "容器创建失败，请检查：docker logs casa"
    press_any_key; return 1
  fi

  _info "等待容器启动（最多 20 秒）..."
  local waited=0
  while [[ $waited -lt 20 ]]; do
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^casa$"; then
      break
    fi
    sleep 2
    waited=$((waited + 2))
  done

  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^casa$"; then
    CASAOS_PORT=$port
    local ip; ip=$(get_local_ip)
    _ok "CasaOS Docker 部署成功！"
    _info "访问地址：http://${ip}:${port}"
    _info "数据目录：$data_dir"
    _info "使用镜像：${SELECTED_CASA_IMAGE}:${tag}"
    log "CasaOS Docker 部署成功，镜像：${SELECTED_CASA_IMAGE}:${tag}，端口：${port}，数据：${data_dir}"
  else
    _err "容器未能正常运行，查看日志："
    docker logs casa 2>&1 | tail -n 30 || true
    press_any_key; return 1
  fi

  press_any_key
}

install_casaos_toolbox() {
  echo ""
  echo "===== 安装 CasaOS Toolbox ====="

  ensure_docker_running || { press_any_key; return 1; }

  local default_port=8088
  read -rp "Toolbox 映射端口 [默认: $default_port]: " input_port </dev/tty
  local port="${input_port:-$default_port}"
  if ! [[ "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 || "$port" -gt 65535 ]]; then
    port=$default_port
  fi

  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^casaos-toolbox$"; then
    _warn "casaos-toolbox 容器已存在"
    read -rp "移除并重新部署？(y/N): " rm_tb </dev/tty
    if [[ "${rm_tb,,}" == "y" ]]; then
      docker stop casaos-toolbox >/dev/null 2>&1 || true
      docker rm casaos-toolbox >/dev/null 2>&1 || true
      _ok "旧容器已移除"
    else
      _warn "已取消"; press_any_key; return
    fi
  fi

  _info "拉取镜像：wisdomsky/casaos-toolbox:latest"
  if ! docker pull wisdomsky/casaos-toolbox:latest; then
    _err "镜像拉取失败"
    press_any_key; return 1
  fi

  local run_result=0
  docker run -d \
    --name casaos-toolbox \
    --restart=always \
    -p "${port}:80" \
    wisdomsky/casaos-toolbox:latest || run_result=$?

  if [[ $run_result -ne 0 ]]; then
    _err "容器创建失败"
    press_any_key; return 1
  fi

  sleep 8

  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^casaos-toolbox$"; then
    local ip; ip=$(get_local_ip)
    _ok "CasaOS Toolbox 部署成功！"
    _info "访问地址：http://${ip}:${port}"
  else
    _err "容器启动异常，查看日志："
    docker logs casaos-toolbox 2>&1 | tail -n 20 || true
    press_any_key; return 1
  fi

  press_any_key
}

_zimaos_get_latest_version() {
  local ver=""
  for prefix in "${GH_MIRRORS[@]}"; do
    local api_url="${prefix}https://api.github.com/repos/${ZIMAOS_GITHUB_REPO}/releases/latest"
    ver=$(curl -fsSL --connect-timeout 10 "$api_url" 2>/dev/null | \
      grep '"tag_name"' | head -n1 | grep -oE '[0-9]+\.[0-9]+[0-9a-zA-Z._-]*' | head -n1 || true)
    [[ -n "$ver" ]] && break
  done
  echo "${ver:-未知}"
}

_zimaos_show_latest() {
  echo ""
  _info "查询 ZimaOS 最新版本..."
  local ver; ver=$(_zimaos_get_latest_version)
  if [[ "$ver" == "未知" ]]; then
    _warn "无法获取版本信息，请直接访问："
    _info "  $ZIMAOS_RELEASES_URL"
  else
    _ok "ZimaOS 最新版本：$ver"
    _info "Release 页面：${ZIMAOS_RELEASES_URL}"
    _info "安装镜像文件名：zimaos_zimacube-${ver}_installer.img"
  fi
}

_zimaos_download_img() {
  echo ""
  echo "===== 下载 ZimaOS 安装镜像 ====="

  _warn "重要提示：ZimaOS 基于 Buildroot，不能在现有 Linux 系统上原地安装"
  _warn "必须将下载的 .img 文件烧录到 U 盘，然后从 U 盘引导安装到目标设备"
  echo ""

  if [[ "$ARCH" != "amd64" ]]; then
    _warn "ZimaOS 目前仅支持 x86-64（amd64）架构，当前架构为 $ARCH"
    _warn "如需在 ARM 设备上运行，请使用 CasaOS"
    read -rp "仍然继续下载？(y/N): " force_dl </dev/tty
    [[ "${force_dl,,}" == "y" ]] || { press_any_key; return; }
  fi

  local ver; ver=$(_zimaos_get_latest_version)
  if [[ "$ver" == "未知" ]]; then
    _warn "无法自动获取版本号，请手动输入"
    read -rp "请输入版本号（如 1.6.1）: " ver </dev/tty
    [[ -z "$ver" ]] && { _err "版本号不能为空"; press_any_key; return; }
  else
    _info "最新版本：$ver"
    read -rp "是否下载此版本？（留空确认，输入其他版本号可替换）: " custom_ver </dev/tty
    [[ -n "$custom_ver" ]] && ver="$custom_ver"
  fi

  local img_filename="zimaos_zimacube-${ver}_installer.img"
  local gh_url="https://github.com/${ZIMAOS_GITHUB_REPO}/releases/download/${ver}/${img_filename}"

  local default_save_dir="${HOME}"
  read -rp "保存目录 [默认: $default_save_dir]: " save_dir </dev/tty
  save_dir="${save_dir:-$default_save_dir}"

  if ! mkdir -p "$save_dir" 2>/dev/null; then
    _err "无法创建目录：$save_dir"
    press_any_key; return 1
  fi

  local save_path="${save_dir}/${img_filename}"

  if [[ -f "$save_path" ]]; then
    _warn "文件已存在：$save_path"
    read -rp "是否重新下载？(y/N): " redownload </dev/tty
    [[ "${redownload,,}" == "y" ]] || { _info "跳过下载，使用已有文件"; press_any_key; return; }
  fi

  _info "下载文件：$img_filename"
  _info "大小约 500MB，请耐心等待..."

  local download_ok=false
  for prefix in "${GH_MIRRORS[@]}"; do
    local dl_url="${prefix}${gh_url}"
    _info "尝试：$dl_url"
    if curl -fL --connect-timeout 15 --max-time 1800 \
       --progress-bar -o "${save_path}.tmp" "$dl_url" 2>/dev/null; then
      local sz; sz=$(stat -c%s "${save_path}.tmp" 2>/dev/null || stat -f%z "${save_path}.tmp" 2>/dev/null || echo 0)
      if [[ "$sz" -gt 104857600 ]]; then
        mv "${save_path}.tmp" "$save_path"
        download_ok=true
        break
      else
        _warn "文件大小异常（${sz}字节），尝试下一个镜像源..."
        rm -f "${save_path}.tmp"
      fi
    else
      rm -f "${save_path}.tmp"
    fi
  done

  if [[ "$download_ok" == false ]]; then
    _err "所有下载源均失败，请手动下载："
    _info "  $ZIMAOS_RELEASES_URL"
    press_any_key; return 1
  fi

  local final_size; final_size=$(du -sh "$save_path" 2>/dev/null | cut -f1 || echo "未知")
  _ok "下载完成：$save_path（$final_size）"
  echo ""
  _info "后续步骤："
  _info "1. 使用 Balena Etcher 将 $img_filename 烧录到 U 盘（至少 8GB）"
  _info "   下载地址：https://etcher.balena.io"
  _info "2. 将 U 盘插入目标设备（x86-64，需支持 UEFI 启动）"
  _info "3. 在 BIOS 中关闭 Secure Boot，选择从 U 盘 UEFI 启动"
  _info "4. 按照屏幕提示选择安装磁盘（注意：目标磁盘数据将被清除）"
  _info "5. 安装完成后拔出 U 盘重启，通过 ZimaClient 或浏览器访问"

  press_any_key
}

_zimaos_show_install_guide() {
  echo ""
  echo "===== ZimaOS 安装说明 ====="
  echo ""
  echo "  架构支持：仅 x86-64（amd64），需要 UEFI 启动"
  echo "  支持设备：ZimaCube / ZimaBoard / ZimaBlade / Intel NUC 等 x86-64 PC"
  echo ""
  echo "  安装步骤："
  echo "  1. 准备工作"
  echo "     - 在 BIOS 中启用 UEFI 启动，禁用 Secure Boot"
  echo "     - 备份目标磁盘上的重要数据（安装会清空整个磁盘）"
  echo ""
  echo "  2. 下载镜像"
  echo "     - 访问：$ZIMAOS_RELEASES_URL"
  echo "     - 下载文件名为 zimaos_XXXXX_installer.img 的文件"
  echo "     - 或使用本脚本选项 2 自动下载"
  echo ""
  echo "  3. 制作启动 U 盘"
  echo "     - 下载 Balena Etcher：https://etcher.balena.io"
  echo "     - 选择下载的 .img 文件和目标 U 盘，点击 Flash"
  echo ""
  echo "  4. 安装系统"
  echo "     - 将 U 盘插入目标设备"
  echo "     - 开机进入启动菜单，选择从 U 盘 UEFI 启动"
  echo "     - 按屏幕提示选择目标磁盘并确认安装"
  echo "     - 安装完成后拔出 U 盘，重启设备"
  echo ""
  echo "  5. 初始化访问"
  echo "     - 安装 ZimaClient：https://www.zimaspace.com/zimaos/download"
  echo "     - ZimaClient 会自动扫描局域网内的 ZimaOS 设备"
  echo "     - 或直接在浏览器访问设备 IP"
  echo ""
  echo "  注意：ZimaOS 基于 Buildroot，不支持在现有 Linux 系统上叠加安装"
  echo "  如需在现有系统上运行类 CasaOS 功能，请使用主菜单的 CasaOS 部署选项"
  echo "==========================="
}

_zimaos_migration_guide() {
  echo ""
  echo "===== CasaOS → ZimaOS 迁移指南 ====="
  echo ""
  echo "  迁移分三个阶段，可按需选择："
  echo ""
  echo "  阶段一：文件迁移（SMB 协议，无需额外工具）"
  echo "  ─────────────────────────────────────────"
  echo "  1. 在 CasaOS 文件管理器中，对需要迁移的目录启用共享"
  echo "  2. 在 ZimaOS Files 中添加网络存储，输入 CasaOS 的 IP 和账号"
  echo "  3. 直接从 ZimaOS 复制文件到本地存储"
  echo ""
  echo "  阶段二：应用迁移（CTOZ 工具，一键迁移容器配置）"
  echo "  ─────────────────────────────────────────────"
  echo "  CTOZ（CasaOS To ZimaOS）是官方提供的迁移工具"
  echo "  可迁移容器镜像、配置文件（不含用户数据）"
  echo "  使用方法：本菜单选项 5 下载 CTOZ 工具"
  echo "  CTOZ GitHub：https://github.com/IceWhaleTech/CTOZ"
  echo ""
  echo "  阶段三：数据迁移"
  echo "  ─────────────────"
  echo "  应用数据（如 Jellyfin 媒体库索引等）需在完成阶段一后"
  echo "  手动复制 AppData 目录到 ZimaOS 对应位置"
  echo ""
  echo "  社区注意事项："
  echo "  - 目前不支持原地升级，必须全新安装 ZimaOS 后迁移"
  echo "  - ARM 设备（如树莓派）暂不支持 ZimaOS，请继续使用 CasaOS"
  echo "  - 迁移前务必在本脚本主菜单中完成 CasaOS 备份"
  echo ""
  echo "  官方迁移文档："
  echo "  https://www.zimaspace.com/docs/zimaos/casaos-to-zimaos-migration"
  echo "======================================"
}

_zimaos_download_ctoz() {
  echo ""
  echo "===== 下载 CTOZ 应用迁移工具 ====="

  _info "查询 CTOZ 最新版本..."
  local ctoz_ver=""
  for prefix in "${GH_MIRRORS[@]}"; do
    ctoz_ver=$(curl -fsSL --connect-timeout 10 \
      "${prefix}https://api.github.com/repos/IceWhaleTech/CTOZ/releases/latest" 2>/dev/null | \
      grep '"tag_name"' | head -n1 | grep -oE 'v?[0-9]+\.[0-9]+[0-9a-zA-Z._-]*' | head -n1 || true)
    [[ -n "$ctoz_ver" ]] && break
  done

  if [[ -z "$ctoz_ver" ]]; then
    _warn "无法自动获取 CTOZ 版本，请访问："
    _info "  https://github.com/IceWhaleTech/CTOZ/releases"
    press_any_key; return
  fi

  _info "CTOZ 最新版本：$ctoz_ver"

  local ctoz_arch="amd64"
  case "$ARCH" in
    arm64) ctoz_arch="arm64" ;;
    armv7) ctoz_arch="arm" ;;
  esac

  local ctoz_filename="ctoz_${ctoz_ver}_linux_${ctoz_arch}"
  local ctoz_url="https://github.com/IceWhaleTech/CTOZ/releases/download/${ctoz_ver}/${ctoz_filename}"
  local save_path="${HOME}/${ctoz_filename}"

  _info "下载 CTOZ..."
  local dl_ok=false
  for prefix in "${GH_MIRRORS[@]}"; do
    if curl -fsSL --connect-timeout 15 --max-time 120 \
       --progress-bar -o "$save_path" "${prefix}${ctoz_url}" 2>/dev/null; then
      local sz; sz=$(stat -c%s "$save_path" 2>/dev/null || echo 0)
      if [[ "$sz" -gt 1024 ]]; then
        chmod +x "$save_path"
        dl_ok=true
        break
      fi
      rm -f "$save_path"
    fi
  done

  if [[ "$dl_ok" == true ]]; then
    _ok "CTOZ 下载完成：$save_path"
    _info "使用方法：$save_path --help"
    _info "请在 CasaOS 主机上运行 CTOZ 以导出应用，然后在 ZimaOS 上导入"
  else
    _err "CTOZ 下载失败，请手动访问："
    _info "  https://github.com/IceWhaleTech/CTOZ/releases"
  fi

  press_any_key
}

zimaos_menu() {
  while true; do
    echo ""
    echo "===== ZimaOS 管理 ====="
    echo "  1. 查看最新版本信息"
    echo "  2. 下载 ZimaOS 安装镜像（.img）"
    echo "  3. 查看安装说明"
    echo "  4. CasaOS → ZimaOS 迁移指南"
    echo "  5. 下载 CTOZ 应用迁移工具"
    echo "  0. 返回主菜单"
    echo "========================"
    read -rp "请输入选项: " zc </dev/tty

    case "$zc" in
      1) _zimaos_show_latest;        press_any_key ;;
      2) _zimaos_download_img ;;
      3) _zimaos_show_install_guide; press_any_key ;;
      4) _zimaos_migration_guide;    press_any_key ;;
      5) _zimaos_download_ctoz ;;
      0) return ;;
      *) _warn "无效选项" ;;
    esac
  done
}

update_casaos() {
  echo ""
  echo "===== 更新 CasaOS ====="

  check_casaos_status
  if [[ "$CASAOS_INSTALL_TYPE" == "unknown" ]]; then
    _warn "未检测到 CasaOS 安装"
    press_any_key; return 1
  fi

  _info "当前安装类型：$CASAOS_INSTALL_TYPE"

  if [[ "$CASAOS_INSTALL_TYPE" == "standard" ]]; then
    _info "使用官方更新脚本..."
    if curl -fsSL https://get.casaos.io/update | bash; then
      _ok "CasaOS 更新脚本执行完成，请访问 Web UI 确认版本"
    else
      _err "更新失败，请检查网络或访问官方文档"
    fi
    press_any_key; return
  fi

  if [[ "$CASAOS_INSTALL_TYPE" == "docker" ]]; then
    local cname="$CASAOS_CONTAINER_NAME"
    local cur_image
    cur_image=$(docker inspect --format='{{.Config.Image}}' "$cname" 2>/dev/null || echo "未知")
    _info "当前镜像：$cur_image"

    select_casa_image

    read -rp "更新到的镜像标签 [默认: latest]: " new_tag </dev/tty
    new_tag="${new_tag:-latest}"

    _info "拉取新镜像：${SELECTED_CASA_IMAGE}:${new_tag}"
    if ! docker pull "${SELECTED_CASA_IMAGE}:${new_tag}"; then
      _err "拉取失败，请检查网络"
      press_any_key; return 1
    fi

    local net_mode
    net_mode=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$cname" 2>/dev/null || echo "bridge")

    local old_port="$CASAOS_PORT"
    local old_binds=()

    if _have python3; then
      mapfile -t old_binds < <(
        docker inspect "$cname" 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)[0]
    for b in d.get('HostConfig', {}).get('Binds', []):
        print(b)
except:
    pass
" 2>/dev/null || true
      )
    else
      mapfile -t old_binds < <(
        docker inspect --format='{{range .HostConfig.Binds}}{{.}}{{println}}{{end}}' "$cname" 2>/dev/null || true
      )
    fi

    _info "停止并移除旧容器（数据卷保留）..."
    docker stop "$cname" >/dev/null 2>&1 || true
    docker rm "$cname" >/dev/null 2>&1 || true

    _info "使用新镜像重新创建容器..."
    local run_args=(
      docker run -d
      --name "$cname"
      --restart=always
      --stop-timeout 60
    )

    if [[ "$net_mode" == "host" ]]; then
      run_args+=(--network host)
    else
      run_args+=(-p "${old_port}:8080")
    fi

    if [[ ${#old_binds[@]} -gt 0 ]]; then
      for bind in "${old_binds[@]}"; do
        [[ -n "$bind" ]] && run_args+=(-v "$bind")
      done
    else
      run_args+=(-v "${HOME}/casa:/DATA")
      run_args+=(-v /var/run/docker.sock:/var/run/docker.sock)
    fi

    run_args+=("${SELECTED_CASA_IMAGE}:${new_tag}")

    if "${run_args[@]}"; then
      sleep 10
      if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${cname}$"; then
        _ok "CasaOS 更新完成！访问地址：http://$(get_local_ip):${old_port}"
        _info "当前镜像：${SELECTED_CASA_IMAGE}:${new_tag}"
      else
        _err "更新后容器异常退出，查看日志："
        docker logs "$cname" 2>&1 | tail -n 30 || true
      fi
    else
      _err "容器重新创建失败"
    fi
  fi

  press_any_key
}

uninstall_casaos() {
  echo ""
  echo "===== 卸载 CasaOS ====="

  check_casaos_status
  if [[ "$CASAOS_INSTALL_TYPE" == "unknown" ]]; then
    _warn "未检测到 CasaOS 安装"
    press_any_key; return 1
  fi

  _warn "此操作将停止相关服务并可能移除文件，不可逆！"
  echo ""
  read -rp "确认卸载 CasaOS？(输入 yes 确认，其他取消): " confirm </dev/tty
  [[ "$confirm" == "yes" ]] || { _warn "已取消"; press_any_key; return; }

  local official_script="/usr/local/bin/casaos-uninstall.sh"
  if [[ -f "$official_script" ]]; then
    _info "使用官方卸载脚本..."
    bash "$official_script" || _warn "官方脚本执行出错，继续手动清理..."
    check_casaos_status
    if [[ "$CASAOS_INSTALL_TYPE" == "unknown" ]]; then
      _ok "CasaOS 已通过官方脚本卸载完成"
      press_any_key; return
    fi
    _warn "仍检测到残留，继续手动清理..."
  fi

  if [[ "$CASAOS_INSTALL_TYPE" == "docker" ]]; then
    local cname="$CASAOS_CONTAINER_NAME"
    _info "停止并移除容器：$cname"
    docker stop "$cname" >/dev/null 2>&1 || true
    docker rm "$cname" >/dev/null 2>&1 || true
    _ok "容器已移除"

    read -rp "是否删除 CasaOS 镜像？(y/N): " del_img </dev/tty
    if [[ "${del_img,,}" == "y" ]]; then
      for img in "$CASA_IMAGE_GHCR" "$CASA_IMAGE_DOCKERHUB"; do
        docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | \
          grep "^${img}" | xargs -r docker rmi 2>/dev/null || true
      done
      _ok "镜像已删除"
    fi
  fi

  if [[ "$CASAOS_INSTALL_TYPE" == "standard" ]]; then
    local services=(
      casaos.service casaos-gateway.service
      casaos-user-service.service casaos-app-management.service
      casaos-local-storage.service
    )
    for svc in "${services[@]}"; do
      if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}"; then
        systemctl stop "$svc" >/dev/null 2>&1 || true
        systemctl disable "$svc" >/dev/null 2>&1 || true
        _info "已停止并禁用：$svc"
      fi
    done
    systemctl daemon-reload >/dev/null 2>&1 || true

    read -rp "是否删除二进制文件和服务文件？(y/N): " del_bin </dev/tty
    if [[ "${del_bin,,}" == "y" ]]; then
      rm -f /usr/local/bin/casaos /usr/local/bin/casaos-cli
      rm -rf /var/log/casaos
      local svc_files=()
      mapfile -t svc_files < <(find /etc/systemd/system -name 'casaos*.service' 2>/dev/null || true)
      for f in "${svc_files[@]}"; do
        [[ -f "$f" ]] && rm -f "$f" && _info "已删除：$f"
      done
      systemctl daemon-reload >/dev/null 2>&1 || true
      _ok "二进制和服务文件已清理"
    fi
  fi

  echo ""
  _warn "以下目录脚本不会自动删除（防止数据丢失）："
  echo "  /etc/casaos        （配置）"
  echo "  /var/lib/casaos    （应用数据）"
  echo "  ~/casa             （Docker 数据卷）"
  echo "  /DATA              （旧版数据目录）"
  echo ""
  echo "如需删除，请手动执行对应 rm -rf 命令"

  check_casaos_status
  if [[ "$CASAOS_INSTALL_TYPE" == "unknown" ]]; then
    _ok "CasaOS 卸载完成"
    log "CasaOS 卸载完成"
  else
    _warn "仍检测到残留，请根据提示手动清理"
  fi

  press_any_key
}

view_casaos_info() {
  echo ""
  echo "===== CasaOS 状态信息 ====="

  check_casaos_status
  if [[ "$CASAOS_INSTALL_TYPE" == "unknown" ]]; then
    _warn "未检测到 CasaOS 安装"
    press_any_key; return
  fi

  _info "安装类型：$CASAOS_INSTALL_TYPE"

  if [[ "$CASAOS_INSTALL_TYPE" == "standard" ]]; then
    local ver=""
    if _have casaos; then
      ver=$(casaos version 2>/dev/null || casaos -v 2>/dev/null || echo "未知")
    fi
    _info "版本：$ver"
    echo ""
    echo "-- 服务状态 --"
    local svcs=(casaos.service casaos-gateway.service casaos-user-service.service)
    for svc in "${svcs[@]}"; do
      if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}"; then
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
          _ok "$svc：运行中"
        else
          _warn "$svc：未运行"
        fi
      fi
    done
  fi

  if [[ "$CASAOS_INSTALL_TYPE" == "docker" ]]; then
    local cname="$CASAOS_CONTAINER_NAME"
    local image
    image=$(docker inspect --format='{{.Config.Image}}' "$cname" 2>/dev/null || echo "未知")
    _info "Docker 镜像：$image"
    echo ""
    echo "-- 容器状态 --"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${cname}$"; then
      _ok "容器 $cname：运行中"
      docker ps --filter "name=^${cname}$" \
        --format "  状态：{{.Status}}  端口：{{.Ports}}" 2>/dev/null || true
    else
      _warn "容器 $cname：未运行"
      docker ps -a --filter "name=^${cname}$" \
        --format "  状态：{{.Status}}" 2>/dev/null || true
    fi
  fi

  echo ""
  echo "-- Docker 环境 --"
  if _have docker && docker info >/dev/null 2>&1; then
    _ok "Docker 守护进程：运行中"
    _info "版本：$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo 未知)"
    if docker info 2>/dev/null | grep -q "Registry Mirrors"; then
      _info "镜像加速器："
      docker info 2>/dev/null | grep -A5 "Registry Mirrors" | grep "http" | sed 's/^/  /' || true
    fi
  else
    _warn "Docker：未运行或未安装"
  fi

  echo ""
  local ip; ip=$(get_local_ip)
  _info "访问地址：http://${ip}:${CASAOS_PORT}"
  _info "配置目录：/etc/casaos"
  _info "脚本日志：$SCRIPT_LOG_FILE"

  echo ""
  echo "-- 最近日志（10行）--"
  tail -n 10 "$SCRIPT_LOG_FILE" 2>/dev/null || echo "（日志为空）"
  echo "========================="

  press_any_key
}

switch_apt_source() {
  echo ""
  echo "===== 切换 APT 软件源 ====="

  if ! _have apt-get; then
    _warn "当前系统不使用 APT 包管理器"
    press_any_key; return
  fi

  local sources_file="/etc/apt/sources.list"
  if [[ ! -f "$sources_file" ]]; then
    _warn "未找到 $sources_file"
    press_any_key; return
  fi

  echo ""
  echo "请选择镜像源："
  echo "  1. 清华大学 (mirrors.tuna.tsinghua.edu.cn)"
  echo "  2. 阿里云    (mirrors.aliyun.com)"
  echo "  3. 中科大    (mirrors.ustc.edu.cn)"
  echo "  0. 取消"
  echo ""
  read -rp "选项: " src_choice </dev/tty

  local mirror_host=""
  case "$src_choice" in
    1) mirror_host="mirrors.tuna.tsinghua.edu.cn" ;;
    2) mirror_host="mirrors.aliyun.com" ;;
    3) mirror_host="mirrors.ustc.edu.cn" ;;
    0) _warn "已取消"; press_any_key; return ;;
    *) _warn "无效选项"; press_any_key; return ;;
  esac

  local bak="${sources_file}.bak_$(date +%Y%m%d%H%M%S)"
  cp "$sources_file" "$bak" && _info "原文件已备份：$bak"

  sed -i \
    -e "s|ports\.ubuntu\.com|${mirror_host}|g" \
    -e "s|archive\.ubuntu\.com|${mirror_host}|g" \
    -e "s|security\.ubuntu\.com|${mirror_host}|g" \
    -e "s|deb\.debian\.org|${mirror_host}|g" \
    -e "s|security\.debian\.org|${mirror_host}/debian-security|g" \
    "$sources_file"

  _info "更新包列表..."
  if apt-get update -qq 2>&1 | tail -n 5; then
    _ok "APT 源已切换到：$mirror_host"
  else
    _warn "apt-get update 出现错误，可还原：cp $bak $sources_file"
  fi

  press_any_key
}

backup_casaos() {
  echo ""
  echo "===== 备份 CasaOS/ZimaOS 配置 ====="

  check_casaos_status

  local backup_dirs=()
  [[ -d "/etc/casaos" ]]           && backup_dirs+=("/etc/casaos")
  [[ -d "/var/lib/casaos" ]]       && backup_dirs+=("/var/lib/casaos")
  [[ -d "${HOME}/casa" ]]          && backup_dirs+=("${HOME}/casa")
  [[ -d "/DATA" && "$CASAOS_INSTALL_TYPE" != "unknown" ]] && backup_dirs+=("/DATA")

  if [[ ${#backup_dirs[@]} -eq 0 ]]; then
    _warn "未找到任何可备份的 CasaOS 数据目录"
    press_any_key; return
  fi

  _info "找到以下目录："
  for d in "${backup_dirs[@]}"; do
    local fc; fc=$(find "$d" -type f 2>/dev/null | wc -l || echo 0)
    _info "  $d（$fc 个文件）"
  done

  local avail_kb; avail_kb=$(df -k "$HOME" 2>/dev/null | awk 'NR==2{print $4}' || echo 999999)
  if [[ "$avail_kb" -lt 102400 ]]; then
    _warn "磁盘可用空间较少（${avail_kb}KB），备份可能失败"
    read -rp "是否继续？(y/N): " cont </dev/tty
    [[ "${cont,,}" == "y" ]] || { press_any_key; return; }
  fi

  echo ""
  echo "请选择备份保存位置："
  echo "  1. 主目录 ($HOME)"
  echo "  2. /tmp 目录（重启后丢失）"
  echo "  3. 手动输入"
  read -rp "选项 [默认 1]: " bk_opt </dev/tty
  local bak_dir
  case "${bk_opt:-1}" in
    2) bak_dir="/tmp" ;;
    3) read -rp "请输入目录路径: " bak_dir </dev/tty; bak_dir="${bak_dir:-$HOME}" ;;
    *) bak_dir="$HOME" ;;
  esac

  if ! mkdir -p "$bak_dir" 2>/dev/null || ! touch "$bak_dir/.wtest" 2>/dev/null; then
    _err "目录不可写：$bak_dir"
    press_any_key; return 1
  fi
  rm -f "$bak_dir/.wtest"

  local stamp; stamp=$(date +%Y%m%d_%H%M%S)
  local bak_name="casaos-backup-${stamp}"
  local bak_tmp="${bak_dir}/${bak_name}"
  local bak_file="${bak_dir}/${bak_name}.tar.gz"

  mkdir -p "$bak_tmp"

  local was_running=false
  if [[ "$CASAOS_INSTALL_TYPE" == "docker" ]]; then
    local cname="$CASAOS_CONTAINER_NAME"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${cname}$"; then
      was_running=true
      _info "暂停容器以确保数据一致性..."
      docker stop "$cname" >/dev/null 2>&1 || true
    fi
  fi

  local backed_up=false
  for d in "${backup_dirs[@]}"; do
    local target_name; target_name=$(echo "$d" | tr '/' '_' | sed 's/^_//')
    mkdir -p "${bak_tmp}/${target_name}"
    if cp -a "${d}/." "${bak_tmp}/${target_name}/" 2>/dev/null; then
      _ok "已备份：$d"
      backed_up=true
    else
      _warn "备份失败：$d"
    fi
  done

  local cur_image=""
  if [[ "$CASAOS_INSTALL_TYPE" == "docker" ]]; then
    cur_image=$(docker inspect --format='{{.Config.Image}}' "$CASAOS_CONTAINER_NAME" 2>/dev/null || echo "未知")
  fi

  cat > "${bak_tmp}/backup_info.txt" << EOF
备份时间：$(date '+%Y-%m-%d %H:%M:%S')
主机名：$(hostname)
架构：$(uname -m)
操作系统：${OS_NAME:-未知}
安装类型：${CASAOS_INSTALL_TYPE}
CasaOS 端口：${CASAOS_PORT}
Docker 镜像：${cur_image}
备份目录列表：${backup_dirs[*]}
EOF

  if [[ "$was_running" == true ]]; then
    _info "恢复容器运行..."
    docker start "$CASAOS_CONTAINER_NAME" >/dev/null 2>&1 \
      && _ok "容器已恢复" \
      || _warn "请手动启动：docker start $CASAOS_CONTAINER_NAME"
  fi

  _info "打包压缩中..."
  if tar -czf "$bak_file" -C "$bak_dir" "$bak_name" 2>/dev/null; then
    rm -rf "$bak_tmp"
    local size; size=$(du -sh "$bak_file" 2>/dev/null | cut -f1 || echo "未知")
    _ok "备份完成：$bak_file（$size）"
    log "备份完成：$bak_file"
  else
    _err "打包失败，临时目录：$bak_tmp"
    press_any_key; return 1
  fi

  press_any_key
}

restore_casaos() {
  echo ""
  echo "===== 恢复 CasaOS 配置 ====="

  echo "请选择备份文件来源："
  echo "  1. 自动扫描"
  echo "  2. 手动输入路径"
  read -rp "选项 [默认 1]: " sc </dev/tty
  sc="${sc:-1}"

  local backup_file=""
  case "$sc" in
    2) read -rp "请输入备份文件路径: " backup_file </dev/tty ;;
    *)
      _info "扫描备份文件..."
      local found_files=()
      mapfile -t found_files < <(
        find "$HOME" /tmp /root /mnt /data -maxdepth 3 \
          -name "casaos-backup-*.tar.gz" 2>/dev/null | sort -r || true
      )
      if [[ ${#found_files[@]} -eq 0 ]]; then
        _warn "未找到备份文件"
        read -rp "请手动输入路径: " backup_file </dev/tty
      else
        echo ""
        local i=1
        for f in "${found_files[@]}"; do
          local sz; sz=$(du -sh "$f" 2>/dev/null | cut -f1 || echo "?")
          local ts; ts=$(echo "$f" | grep -oE '[0-9]{8}_[0-9]{6}' | \
            sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)_\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3 \4:\5:\6/' || echo "")
          printf "  %d. %-50s [%s] %s\n" "$i" "$f" "$sz" "$ts"
          i=$((i + 1))
        done
        echo ""
        read -rp "请输入编号（留空手动输入）: " fc </dev/tty
        if [[ -z "$fc" ]]; then
          read -rp "请输入路径: " backup_file </dev/tty
        elif [[ "$fc" =~ ^[0-9]+$ ]] && [[ "$fc" -ge 1 && "$fc" -le ${#found_files[@]} ]]; then
          backup_file="${found_files[$((fc-1))]}"
        else
          _err "无效选项"; press_any_key; return 1
        fi
      fi
      ;;
  esac

  if [[ -z "$backup_file" || ! -f "$backup_file" ]]; then
    _err "备份文件不存在：$backup_file"
    press_any_key; return 1
  fi

  local restore_tmp; restore_tmp=$(mktemp -d)
  trap "rm -rf '$restore_tmp'" RETURN

  _info "解压备份文件..."
  if ! tar -xzf "$backup_file" -C "$restore_tmp" 2>/dev/null; then
    _err "解压失败，文件可能已损坏"
    press_any_key; return 1
  fi

  local info_file; info_file=$(find "$restore_tmp" -name "backup_info.txt" | head -n1 || true)
  if [[ -n "$info_file" ]]; then
    echo ""
    echo "---- 备份信息 ----"
    cat "$info_file"
    echo "------------------"
  else
    _warn "未找到 backup_info.txt，备份格式可能不正确"
    read -rp "是否继续恢复？(y/N): " force_restore </dev/tty
    [[ "${force_restore,,}" == "y" ]] || { press_any_key; return; }
  fi

  echo ""
  read -rp "确认恢复？这将覆盖现有配置 (y/N): " confirm </dev/tty
  [[ "${confirm,,}" == "y" ]] || { _warn "已取消"; press_any_key; return; }

  check_casaos_status
  if [[ "$CASAOS_INSTALL_TYPE" == "docker" ]]; then
    local cname="$CASAOS_CONTAINER_NAME"
    _info "停止容器：$cname"
    docker stop "$cname" >/dev/null 2>&1 || true
  fi

  local restore_base; restore_base=$(dirname "${info_file:-$restore_tmp/x}")
  local found_any=false

  for src_dir in "$restore_base"/*/; do
    [[ -d "$src_dir" ]] || continue
    local dir_name; dir_name=$(basename "$src_dir")
    local target_path="/${dir_name//_//}"

    if [[ -d "$target_path" ]]; then
      local bak_old="${target_path}_restore_bak_$(date +%s)"
      mv "$target_path" "$bak_old" 2>/dev/null && \
        _info "旧目录保留为：$bak_old"
    fi

    mkdir -p "$target_path"
    if cp -a "${src_dir}." "$target_path/" 2>/dev/null; then
      _ok "已恢复：$target_path"
      found_any=true
    else
      _warn "恢复失败：$target_path"
    fi
  done

  if [[ "$found_any" == false ]]; then
    _warn "未恢复任何目录，请检查备份包内容"
    press_any_key; return 1
  fi

  if [[ "$CASAOS_INSTALL_TYPE" == "docker" ]]; then
    docker start "$CASAOS_CONTAINER_NAME" >/dev/null 2>&1 \
      && _ok "容器已启动" \
      || _warn "请通过菜单手动启动容器"
  elif [[ "$CASAOS_INSTALL_TYPE" == "standard" ]]; then
    systemctl restart casaos-gateway >/dev/null 2>&1 || true
    _info "已尝试重启 casaos-gateway 服务"
  fi

  _ok "恢复完成"
  press_any_key
}

_get_status_line() {
  check_casaos_status 2>/dev/null || true
  if [[ "$CASAOS_INSTALL_TYPE" == "unknown" ]]; then
    echo "未安装"
    return
  fi

  local svc_ok=false
  if [[ "$CASAOS_INSTALL_TYPE" == "standard" ]]; then
    systemctl is-active --quiet casaos-gateway.service 2>/dev/null && svc_ok=true || true
  elif [[ "$CASAOS_INSTALL_TYPE" == "docker" ]]; then
    local cname="${CASAOS_CONTAINER_NAME:-casa}"
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${cname}$" && svc_ok=true || true
  fi

  if [[ "$svc_ok" == true ]]; then
    echo "运行中  [${CASAOS_INSTALL_TYPE}，端口 ${CASAOS_PORT}]"
  else
    echo "已停止  [${CASAOS_INSTALL_TYPE}]"
  fi
}

detect_pkg_manager
detect_os
detect_arch 2>/dev/null || true

while true; do
  casaos_status=$(_get_status_line)
  local_ip=$(get_local_ip)

  docker_status="未安装"
  if _have docker && docker info >/dev/null 2>&1; then
    docker_status="运行中  [$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo 未知)]"
  elif _have docker; then
    docker_status="已安装（未运行）"
  fi

  zimaos_ver=$(_zimaos_get_latest_version 2>/dev/null || echo "未知")

  echo ""
  echo "========== CasaOS / ZimaOS 部署脚本 v${SCRIPT_VERSION} =========="
  echo "  本机 IP    ：$local_ip    架构：$ARCH"
  echo "  CasaOS     ：$casaos_status"
  echo "  Docker     ：$docker_status"
  echo "  ZimaOS 最新：$zimaos_ver（仅 x86-64 UEFI）"
  echo "-------------------------------------------------------------"
  echo "  [CasaOS 部署]"
  echo "  1. 标准安装 CasaOS（官方脚本）"
  echo "  2. Docker 部署 CasaOS（可选 ghcr.io/Docker Hub + 指定端口/版本）"
  echo "  3. 安装 CasaOS Toolbox"
  echo ""
  echo "  [ZimaOS]"
  echo "  4. ZimaOS 管理（下载镜像/安装说明/迁移指南/CTOZ工具）"
  echo ""
  echo "  [CasaOS 管理]"
  echo "  5. 更新 CasaOS"
  echo "  6. 查看状态与信息"
  echo "  7. 卸载 CasaOS"
  echo ""
  echo "  [系统工具]"
  echo "  8. 配置 Docker 镜像加速器"
  echo "  9. 安装 Docker"
  echo " 10. 切换 APT 软件源"
  echo " 11. 备份配置"
  echo " 12. 恢复配置"
  echo " 13. 清空脚本日志"
  echo "  0. 退出"
  echo "============================================================="
  read -rp "请输入选项: " choice </dev/tty

  case "$choice" in
    1)  install_casaos_standard ;;
    2)  install_casaos_docker ;;
    3)  install_casaos_toolbox ;;
    4)  zimaos_menu ;;
    5)  update_casaos ;;
    6)  view_casaos_info ;;
    7)  uninstall_casaos ;;
    8)  config_docker_mirror ;;
    9)  install_docker_only ;;
    10) switch_apt_source ;;
    11) backup_casaos ;;
    12) restore_casaos ;;
    13)
      echo "" > "$SCRIPT_LOG_FILE" 2>/dev/null && _ok "日志已清空" || _warn "清空失败"
      press_any_key
      ;;
    0)
      _ok "感谢使用，脚本退出"
      exit 0
      ;;
    *)
      _warn "无效选项，请输入 0-13"
      ;;
  esac
done
