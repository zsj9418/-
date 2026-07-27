#!/bin/bash
set -uo pipefail
trap 'echo "[!] 已中断"; exit 1' INT

SCRIPT_VERSION="2.0"
BASE_IMAGE_NAME="b3log/siyuan"
CONTAINER_NAME="siyuan"
DEFAULT_TAG="latest"
DEFAULT_PORT="6806"
CONTAINER_WORKSPACE="/siyuan/workspace"
DEFAULT_AUTH_CODE="12345678"
MAX_LOG_SIZE="20m"
RETRY_COUNT=3

LOG_FILE="/var/log/siyuan_deploy.log"
BACKUP_PREFIX="siyuan-backup"

GH_MIRRORS=(
  ""
  "https://docker.1ms.run/"
  "https://docker.m.daocloud.io/"
  "https://docker.nju.edu.cn/"
  "https://mirror.baidubce.com/"
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
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE" 2>/dev/null || true
}

_have() { command -v "$1" >/dev/null 2>&1; }

if [[ "${EUID}" -ne 0 ]]; then
  _err "请以 root 权限运行此脚本"
  exit 1
fi

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || LOG_FILE="/tmp/siyuan_deploy.log"
touch "$LOG_FILE" 2>/dev/null || true
log "### 思源笔记部署脚本 v${SCRIPT_VERSION} 启动 ###"

OS_TYPE=""
PKG_MGR=""
ARCH_NAME=""

detect_os() {
  if [[ -f /etc/openwrt_release ]]; then
    OS_TYPE="openwrt"; PKG_MGR="opkg"
  elif [[ -f /etc/debian_version ]]; then
    OS_TYPE="debian"; PKG_MGR="apt-get"
  elif [[ -f /etc/redhat-release ]]; then
    OS_TYPE="redhat"; PKG_MGR="yum"
  elif [[ "$(uname -s)" == "Darwin" ]]; then
    OS_TYPE="macos"; PKG_MGR="brew"
  else
    _warn "未识别的操作系统，尝试继续..."
    OS_TYPE="unknown"; PKG_MGR=""
  fi
  log "操作系统：$OS_TYPE"
}

detect_arch() {
  local raw; raw=$(uname -m)
  case "$raw" in
    x86_64|amd64)        ARCH_NAME="amd64" ;;
    aarch64|arm64)       ARCH_NAME="arm64" ;;
    armv7l|armhf)        ARCH_NAME="armv7" ;;
    armv6l)              ARCH_NAME="armv6" ;;
    mips)                ARCH_NAME="mips" ;;
    mipsel|mipsle)       ARCH_NAME="mipsle" ;;
    riscv64)             ARCH_NAME="riscv64" ;;
    loong64|loongarch64) ARCH_NAME="loong64" ;;
    i386|i686)           ARCH_NAME="386" ;;
    *)
      _warn "未知架构：$raw，继续尝试..."
      ARCH_NAME="$raw"
      ;;
  esac
  _info "系统架构：$raw → $ARCH_NAME"
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
    elif [[ "$OS_TYPE" == "openwrt" ]]; then
      /etc/init.d/dockerd start >/dev/null 2>&1 || true
    fi
    sleep 3
    if ! docker info >/dev/null 2>&1; then
      _err "Docker 无法启动，请手动检查"
      return 1
    fi
  fi
  return 0
}

install_dependencies() {
  echo ""
  echo "===== 检查并安装依赖 ====="

  if _have docker && _have curl && _have jq; then
    _ok "所有依赖已满足"
    press_any_key; return 0
  fi

  case "$OS_TYPE" in
    openwrt)
      opkg update >/dev/null 2>&1 || true
      if ! _have docker; then
        _info "安装 Docker for OpenWrt..."
        opkg install dockerd docker luci-app-dockerman || {
          _err "Docker 安装失败"; press_any_key; return 1
        }
        /etc/init.d/dockerd enable
        /etc/init.d/dockerd start
      fi
      _have curl || opkg install curl || true
      _have jq   || opkg install jq   || true
      ;;
    debian)
      apt-get update -qq 2>/dev/null || true
      if ! _have docker; then
        _info "安装 Docker..."
        apt-get install -y -qq ca-certificates curl gnupg lsb-release 2>/dev/null || true
        curl -fsSL https://get.docker.com | sh 2>/dev/null || \
          apt-get install -y -qq docker.io || {
          _err "Docker 安装失败"; press_any_key; return 1
        }
        systemctl enable --now docker >/dev/null 2>&1 || true
      fi
      _have curl || apt-get install -y -qq curl || true
      _have jq   || apt-get install -y -qq jq   || true
      ;;
    redhat)
      if ! _have docker; then
        _info "安装 Docker..."
        yum install -y yum-utils 2>/dev/null || true
        yum-config-manager --add-repo \
          https://download.docker.com/linux/centos/docker-ce.repo 2>/dev/null || true
        yum install -y docker-ce docker-ce-cli containerd.io || \
          curl -fsSL https://get.docker.com | sh || {
          _err "Docker 安装失败"; press_any_key; return 1
        }
        systemctl enable --now docker >/dev/null 2>&1 || true
      fi
      _have curl || yum install -y curl || true
      _have jq   || yum install -y jq   || true
      ;;
    macos)
      _warn "macOS 请手动安装 Docker Desktop：https://www.docker.com/products/docker-desktop"
      if ! _have brew; then
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || true
      fi
      _have curl || brew install curl || true
      _have jq   || brew install jq   || true
      ;;
    *)
      _info "尝试使用官方一键脚本安装 Docker..."
      curl -fsSL https://get.docker.com | sh || {
        _err "Docker 安装失败，请手动安装"
        press_any_key; return 1
      }
      ;;
  esac

  if ! _have docker; then
    _err "Docker 安装后仍不可用"
    press_any_key; return 1
  fi

  local retry=0
  while ! docker info >/dev/null 2>&1 && [[ $retry -lt 10 ]]; do
    sleep 2; retry=$((retry + 1))
  done

  if ! docker info >/dev/null 2>&1; then
    _err "Docker 守护进程无法启动"
    press_any_key; return 1
  fi

  _ok "依赖安装完成"
  press_any_key
}

fix_openwrt_firewall() {
  if [[ "$OS_TYPE" != "openwrt" ]]; then
    _warn "此功能仅适用于 OpenWrt 系统"
    press_any_key; return
  fi

  echo ""
  echo "===== 修复 OpenWrt 防火墙 ====="

  local fwd_status
  fwd_status=$(uci -q get firewall.@defaults[0].forward || echo "")
  if [[ "$fwd_status" != "ACCEPT" ]]; then
    uci set firewall.@defaults[0].forward='ACCEPT'
    uci commit firewall
    _ok "已设置 forward=ACCEPT"
  fi

  if ! uci -q get network.docker0 >/dev/null 2>&1; then
    uci set network.docker0=interface
    uci set network.docker0.type='bridge'
    uci set network.docker0.proto='none'
    uci set network.docker0.firewall_zone='lan'
    uci commit network
    _ok "已配置 docker0 网络"
  fi

  local docker_subnet="172.17.0.0/16"
  if ! iptables -t nat -C POSTROUTING -s "$docker_subnet" ! -o docker0 -j MASQUERADE 2>/dev/null; then
    iptables -t nat -A POSTROUTING -s "$docker_subnet" ! -o docker0 -j MASQUERADE
    _ok "已添加 iptables NAT 规则"
  fi

  /etc/init.d/firewall restart 2>/dev/null || fw3 reload 2>/dev/null || true
  /etc/init.d/network reload 2>/dev/null || true
  _ok "OpenWrt 网络配置已优化"

  press_any_key
}

get_available_tags() {
  SELECTED_TAG="$DEFAULT_TAG"
  IMAGE_NAME="${BASE_IMAGE_NAME}:${SELECTED_TAG}"

  echo ""
  _info "从 Docker Hub 获取版本列表..."

  local raw_tags=""
  raw_tags=$(curl -fsSL -m 15 \
    "https://hub.docker.com/v2/repositories/${BASE_IMAGE_NAME}/tags/?page_size=50" \
    2>/dev/null | grep -o '"name":"[^"]*"' | cut -d'"' -f4 | grep -v "^latest$" | \
    sort -rV | head -n 20 || true)

  local tag_list=("latest")
  if [[ -n "$raw_tags" ]]; then
    mapfile -t extra_tags <<< "$raw_tags"
    tag_list+=("${extra_tags[@]}")
  fi

  echo ""
  echo "可用版本："
  local i=1
  for t in "${tag_list[@]}"; do
    if [[ "$i" -eq 1 ]]; then
      printf "  %2d. %s  (默认)\n" "$i" "$t"
    else
      printf "  %2d. %s\n" "$i" "$t"
    fi
    i=$((i + 1))
  done
  local manual_idx=$i
  printf "  %2d. 手动输入版本号\n" "$manual_idx"

  if [[ "$ARCH_NAME" == *"arm"* || "$ARCH_NAME" == *"mips"* || "$OS_TYPE" == "openwrt" ]]; then
    echo ""
    _warn "检测到 ARM/MIPS 架构或 OpenWrt 系统"
    _warn "思源从 v3.1.0 起可能不兼容老内核，建议选择 v3.0.17"
    _info "可直接在下方输入 v3.0.17 使用养老版"
  fi

  echo ""
  read -rp "请输入编号或直接输入版本号 [默认 1/latest]: " tag_choice </dev/tty
  tag_choice="${tag_choice:-1}"

  if [[ "$tag_choice" =~ ^[0-9]+$ ]]; then
    if [[ "$tag_choice" -ge 1 && "$tag_choice" -lt "$manual_idx" ]]; then
      SELECTED_TAG="${tag_list[$((tag_choice - 1))]}"
    elif [[ "$tag_choice" == "$manual_idx" ]]; then
      read -rp "请输入版本号（如 v3.0.17）: " SELECTED_TAG </dev/tty
      SELECTED_TAG="${SELECTED_TAG:-latest}"
    else
      _warn "编号超出范围，使用 latest"
      SELECTED_TAG="latest"
    fi
  else
    SELECTED_TAG="$tag_choice"
  fi

  IMAGE_NAME="${BASE_IMAGE_NAME}:${SELECTED_TAG}"
  _ok "已选择版本：$SELECTED_TAG"
}

pull_image() {
  _info "拉取镜像：$IMAGE_NAME"
  _info "优先尝试国内加速源..."

  for prefix in "${GH_MIRRORS[@]}"; do
    local pull_image_name
    if [[ -z "$prefix" ]]; then
      pull_image_name="$IMAGE_NAME"
      _info "尝试直连 Docker Hub..."
    else
      pull_image_name="${prefix}${IMAGE_NAME}"
      _info "尝试加速源：$prefix"
    fi

    local attempt=1
    while [[ $attempt -le $RETRY_COUNT ]]; do
      if docker pull "$pull_image_name" >/dev/null 2>&1; then
        if [[ "$pull_image_name" != "$IMAGE_NAME" ]]; then
          docker tag "$pull_image_name" "$IMAGE_NAME" >/dev/null 2>&1 || true
        fi
        _ok "镜像拉取成功：$IMAGE_NAME"
        return 0
      fi
      _warn "第 $attempt/$RETRY_COUNT 次失败，重试..."
      sleep 2
      attempt=$((attempt + 1))
    done
  done

  _err "所有镜像源拉取均失败，请检查网络"
  return 1
}

setup_workspace() {
  local default_ws="$CONTAINER_WORKSPACE"
  echo ""
  read -rp "宿主机数据存储路径 [默认: $default_ws]: " ws_input </dev/tty
  HOST_WORKSPACE="${ws_input:-$default_ws}"

  if ! mkdir -p "$HOST_WORKSPACE" 2>/dev/null; then
    _err "无法创建目录：$HOST_WORKSPACE"
    return 1
  fi

  chown -R 1000:1000 "$HOST_WORKSPACE" 2>/dev/null || true
  chmod 755 "$HOST_WORKSPACE" 2>/dev/null || true
  _ok "工作空间已就绪：$HOST_WORKSPACE"
}

get_user_input() {
  echo ""
  read -rp "访问授权码 [默认: $DEFAULT_AUTH_CODE，建议修改]: " auth_input </dev/tty
  AUTH_CODE="${auth_input:-$DEFAULT_AUTH_CODE}"
  if [[ "$AUTH_CODE" == "$DEFAULT_AUTH_CODE" ]]; then
    _warn "使用默认授权码存在安全风险，建议设置强密码"
  fi

  read -rp "主机映射端口 [默认: $DEFAULT_PORT]: " port_input </dev/tty
  HOST_PORT="${port_input:-$DEFAULT_PORT}"
  if ! [[ "$HOST_PORT" =~ ^[0-9]+$ ]] || [[ "$HOST_PORT" -lt 1 || "$HOST_PORT" -gt 65535 ]]; then
    _warn "端口无效，使用默认 $DEFAULT_PORT"
    HOST_PORT="$DEFAULT_PORT"
  fi
}

check_port() {
  local attempts=0
  while true; do
    local in_use=false
    if _have ss; then
      ss -tuln 2>/dev/null | grep -q ":${HOST_PORT} " && in_use=true
    elif _have netstat; then
      netstat -tuln 2>/dev/null | grep -q ":${HOST_PORT} " && in_use=true
    fi

    if [[ "$in_use" == false ]]; then
      _ok "端口 $HOST_PORT 可用"
      return 0
    fi

    _warn "端口 $HOST_PORT 已被占用"
    attempts=$((attempts + 1))
    if [[ $attempts -ge 5 ]]; then
      _err "端口尝试次数过多，返回菜单"
      return 1
    fi
    read -rp "请输入新端口: " HOST_PORT </dev/tty
    if ! [[ "$HOST_PORT" =~ ^[0-9]+$ ]] || [[ "$HOST_PORT" -lt 1 || "$HOST_PORT" -gt 65535 ]]; then
      _warn "端口无效，请重新输入"
      HOST_PORT="$DEFAULT_PORT"
    fi
  done
}

select_network_mode() {
  echo ""
  echo "请选择网络模式："
  echo "  1. bridge（推荐，最稳定）"
  echo "  2. host（高性能，端口共享宿主机）"
  echo "  0. 取消"
  read -rp "选项 [默认 1]: " net_choice </dev/tty

  case "${net_choice:-1}" in
    2)
      NETWORK_MODE="host"
      if [[ "$OS_TYPE" == "openwrt" ]]; then
        _warn "Host 模式在 OpenWrt 上可能导致端口冲突"
      fi
      _info "网络模式：host"
      ;;
    0)
      _warn "已取消"; return 1
      ;;
    *)
      NETWORK_MODE="bridge"
      _info "网络模式：bridge"
      if [[ "$OS_TYPE" == "openwrt" ]]; then
        _info "OpenWrt bridge 模式需要防火墙配置，如遇问题请使用选项 7 修复"
      fi
      ;;
  esac
}

_detect_serve_cmd() {
  local img="$1"
  local ver_str="${img##*:}"
  if [[ "$ver_str" == "latest" ]]; then
    echo "serve"
    return
  fi
  local ver_num; ver_num=$(echo "$ver_str" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
  if [[ -z "$ver_num" ]]; then
    echo "serve"; return
  fi
  local major minor patch
  IFS='.' read -r major minor patch <<< "$ver_num"
  if [[ "$major" -gt 3 ]] || \
     [[ "$major" -eq 3 && "$minor" -gt 7 ]] || \
     [[ "$major" -eq 3 && "$minor" -eq 7 && "${patch:-0}" -ge 0 ]]; then
    echo "serve"
  else
    echo ""
  fi
}

start_container() {
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
    _warn "检测到同名容器 $CONTAINER_NAME 已存在"
    read -rp "是否删除并重新创建？(y/N): " rm_choice </dev/tty
    if [[ "${rm_choice,,}" == "y" ]]; then
      docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    else
      _warn "已取消，请手动删除容器或修改容器名"
      return 1
    fi
  fi

  local serve_cmd; serve_cmd=$(_detect_serve_cmd "$IMAGE_NAME")

  local run_args=(
    docker run -d
    --name "$CONTAINER_NAME"
    --privileged
    --security-opt seccomp=unconfined
    -v "${HOST_WORKSPACE}:${CONTAINER_WORKSPACE}"
    -e TZ="Asia/Shanghai"
    -e PUID="1000"
    -e PGID="1000"
    -e SIYUAN_ACCESS_AUTH_CODE="$AUTH_CODE"
    --restart unless-stopped
    --log-opt max-size="$MAX_LOG_SIZE"
    --log-opt max-file="3"
  )

  if [[ "$NETWORK_MODE" == "host" ]]; then
    run_args+=(--network host)
  else
    run_args+=(-p "${HOST_PORT}:6806")
  fi

  run_args+=("$IMAGE_NAME")

  if [[ -n "$serve_cmd" ]]; then
    run_args+=("$serve_cmd")
  fi
  run_args+=(
    "--workspace=${CONTAINER_WORKSPACE}"
    "--accessAuthCode=${AUTH_CODE}"
  )

  _info "启动容器..."

  if "${run_args[@]}" >/dev/null 2>&1; then
    sleep 3
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
      local ip; ip=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' | head -n1 || \
                     hostname -I 2>/dev/null | awk '{print $1}' || echo "<本机IP>")
      _ok "容器启动成功！"
      _info "访问地址：http://${ip}:${HOST_PORT}"
      _info "工作空间：$HOST_WORKSPACE"
      _info "授权码：$AUTH_CODE"
      log "思源笔记部署成功，端口：$HOST_PORT，工作空间：$HOST_WORKSPACE"
    else
      _err "容器启动后异常退出，请查看日志：docker logs $CONTAINER_NAME"
      return 1
    fi
  else
    _err "容器启动失败，请查看日志：docker logs $CONTAINER_NAME"
    return 1
  fi
}

upgrade_siyuan() {
  echo ""
  echo "===== 无损更新思源笔记 ====="

  if ! _have jq; then
    _err "更新功能依赖 jq，请先通过选项安装依赖"
    press_any_key; return 1
  fi

  if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
    _err "未检测到容器 $CONTAINER_NAME，请先安装部署"
    press_any_key; return 1
  fi

  local cur_image
  cur_image=$(docker inspect --format='{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null || echo "未知")
  _info "当前镜像：$cur_image"

  get_available_tags

  _warn "更新将保留所有配置（挂载、端口、密码）"
  read -rp "确认继续？(y/N): " confirm </dev/tty
  [[ "${confirm,,}" == "y" ]] || { _warn "已取消"; press_any_key; return; }

  pull_image || { press_any_key; return 1; }

  _info "读取当前容器配置..."
  local c_info
  c_info=$(docker inspect "$CONTAINER_NAME" 2>/dev/null)

  local net_mode restart_policy
  net_mode=$(echo "$c_info" | jq -r '.[0].HostConfig.NetworkMode // "bridge"')
  restart_policy=$(echo "$c_info" | jq -r '.[0].HostConfig.RestartPolicy.Name // "unless-stopped"')

  local run_args=(-d --name "$CONTAINER_NAME" --privileged --security-opt seccomp=unconfined)
  run_args+=(--log-opt max-size="$MAX_LOG_SIZE" --log-opt max-file="3")

  [[ -n "$restart_policy" && "$restart_policy" != "no" && "$restart_policy" != "null" ]] && \
    run_args+=(--restart "$restart_policy")

  if [[ "$net_mode" != "host" ]]; then
    run_args+=(--network bridge)
    local ports=()
    mapfile -t ports < <(echo "$c_info" | jq -r '
      .[0].HostConfig.PortBindings // {} |
      to_entries[] |
      select(.value != null and (.value | length) > 0) |
      "-p", "\(.value[0].HostPort):\(.key | split("/")[0])"
    ' 2>/dev/null || true)
    [[ ${#ports[@]} -gt 0 ]] && run_args+=("${ports[@]}")
  else
    run_args+=(--network host)
  fi

  local mounts=()
  mapfile -t mounts < <(echo "$c_info" | jq -r '
    .[0].Mounts[]? |
    select(.Type == "bind") |
    "-v", "\(.Source):\(.Destination)"
  ' 2>/dev/null || true)
  [[ ${#mounts[@]} -gt 0 ]] && run_args+=("${mounts[@]}")

  local envs=()
  mapfile -t envs < <(echo "$c_info" | jq -r '
    .[0].Config.Env[]? |
    select(test("^(PATH|HOSTNAME|HOME|PWD|TERM)=") | not)
  ' 2>/dev/null || true)
  for e in "${envs[@]}"; do
    [[ -n "$e" ]] && run_args+=(-e "$e")
  done

  local cmd_args=()
  mapfile -t cmd_args < <(echo "$c_info" | jq -r '
    .[0].Config.Cmd[]? // empty
  ' 2>/dev/null || true)

  local serve_cmd; serve_cmd=$(_detect_serve_cmd "$IMAGE_NAME")
  if [[ -n "$serve_cmd" ]]; then
    local has_serve=false
    for ca in "${cmd_args[@]}"; do
      [[ "$ca" == "serve" ]] && has_serve=true && break
    done
    if [[ "$has_serve" == false ]]; then
      cmd_args=("serve" "${cmd_args[@]}")
    fi
  fi

  _info "停止并删除旧容器..."
  docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
  docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true

  _info "使用新镜像重建容器..."
  if docker run "${run_args[@]}" "$IMAGE_NAME" "${cmd_args[@]}" >/dev/null 2>&1; then
    sleep 3
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
      _ok "思源笔记已无损更新至 $SELECTED_TAG 并启动"
      log "更新成功：$SELECTED_TAG"
    else
      _err "更新后容器异常退出，请查看日志：docker logs $CONTAINER_NAME"
    fi
  else
    _err "容器重建失败，请查看日志"
  fi

  press_any_key
}

control_container() {
  echo ""
  echo "===== 容器启停控制 ====="

  if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
    _err "未检测到容器 $CONTAINER_NAME，请先安装部署"
    press_any_key; return
  fi

  local status
  status=$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "未知")
  _info "当前状态：$status"

  echo "  1. 启动容器"
  echo "  2. 停止容器"
  echo "  3. 重启容器"
  echo "  0. 返回"
  read -rp "选项: " ctrl_choice </dev/tty

  case "$ctrl_choice" in
    1)
      docker start "$CONTAINER_NAME" >/dev/null 2>&1 \
        && _ok "容器已启动" || _err "启动失败"
      ;;
    2)
      docker stop "$CONTAINER_NAME" >/dev/null 2>&1 \
        && _ok "容器已停止" || _err "停止失败"
      ;;
    3)
      docker restart "$CONTAINER_NAME" >/dev/null 2>&1 \
        && _ok "容器已重启" || _err "重启失败"
      ;;
    0) return ;;
    *) _warn "无效选项" ;;
  esac

  press_any_key
}

view_logs() {
  echo ""
  echo "===== 容器日志 ====="

  if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
    _err "未检测到容器 $CONTAINER_NAME"
    press_any_key; return
  fi

  echo "  1. 查看最近 50 行日志"
  echo "  2. 查看最近 200 行日志"
  echo "  3. 实时日志（Ctrl+C 退出）"
  echo "  0. 返回"
  read -rp "选项: " log_choice </dev/tty

  case "$log_choice" in
    1)
      echo ""
      docker logs --tail=50 "$CONTAINER_NAME" 2>&1
      press_any_key
      ;;
    2)
      echo ""
      docker logs --tail=200 "$CONTAINER_NAME" 2>&1
      press_any_key
      ;;
    3)
      _info "实时日志（Ctrl+C 退出）..."
      docker logs -f --tail=50 "$CONTAINER_NAME" 2>&1 || true
      press_any_key
      ;;
    0) return ;;
    *) _warn "无效选项"; press_any_key ;;
  esac
}

view_containers() {
  echo ""
  echo "===== 容器状态 ====="
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
    docker ps -a --filter "name=^${CONTAINER_NAME}$" \
      --format "  名称：{{.Names}}\n  状态：{{.Status}}\n  镜像：{{.Image}}\n  端口：{{.Ports}}" \
      2>/dev/null || true
  else
    _warn "未检测到思源笔记容器"
  fi

  echo ""
  echo "-- Docker 环境 --"
  if docker info >/dev/null 2>&1; then
    _ok "Docker 正在运行"
    _info "版本：$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo 未知)"
  else
    _warn "Docker 未运行"
  fi

  press_any_key
}

_select_backup_root() {
  echo "" >&2
  echo "请选择备份保存位置：" >&2
  echo "  1. 主目录 ($HOME)" >&2
  echo "  2. /tmp 目录（重启后丢失）" >&2
  echo "  3. 手动输入路径" >&2
  read -rp "选项 [默认 1]: " bc </dev/tty
  local backup_root
  case "${bc:-1}" in
    2) backup_root="/tmp" ;;
    3)
      read -rp "请输入目录路径: " custom_dir </dev/tty
      backup_root="${custom_dir:-$HOME}"
      ;;
    *) backup_root="$HOME" ;;
  esac
  if ! mkdir -p "$backup_root" 2>/dev/null || ! touch "$backup_root/.wtest" 2>/dev/null; then
    _err "目录不可写：$backup_root" >&2
    return 1
  fi
  rm -f "$backup_root/.wtest"
  _info "备份目录：$backup_root" >&2
  echo "$backup_root"
}

_scan_backup_files() {
  local scan_dirs=("$HOME" "/tmp" "/root" "/mnt" "/data")
  for d in "${scan_dirs[@]}"; do
    [[ -d "$d" ]] || continue
    find "$d" -maxdepth 3 -name "${BACKUP_PREFIX}-*.tar.gz" 2>/dev/null
  done | sort -ru
}

backup_data() {
  echo ""
  echo "===== 备份思源笔记数据 ====="

  local workspace_to_backup="$CONTAINER_WORKSPACE"

  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
    local detected_ws
    detected_ws=$(docker inspect "$CONTAINER_NAME" 2>/dev/null | \
      jq -r '.[0].Mounts[]? | select(.Destination == "/siyuan/workspace") | .Source' \
      2>/dev/null | head -n1 || true)
    [[ -n "$detected_ws" ]] && workspace_to_backup="$detected_ws"
  fi

  if [[ ! -d "$workspace_to_backup" ]]; then
    _warn "数据目录不存在：$workspace_to_backup"
    read -rp "手动输入工作空间路径: " manual_ws </dev/tty
    workspace_to_backup="${manual_ws:-$CONTAINER_WORKSPACE}"
    if [[ ! -d "$workspace_to_backup" ]]; then
      _err "目录不存在：$workspace_to_backup"
      press_any_key; return 1
    fi
  fi

  local file_count; file_count=$(find "$workspace_to_backup" -type f 2>/dev/null | wc -l || echo 0)
  _info "备份源：$workspace_to_backup（$file_count 个文件）"

  local avail_kb; avail_kb=$(df -k "$HOME" 2>/dev/null | awk 'NR==2{print $4}' || echo 999999)
  if [[ "$avail_kb" -lt 102400 ]]; then
    _warn "磁盘可用空间较少（${avail_kb}KB）"
    read -rp "是否继续？(y/N): " cont </dev/tty
    [[ "${cont,,}" == "y" ]] || { press_any_key; return; }
  fi

  local backup_root
  backup_root=$(_select_backup_root) || { press_any_key; return 1; }

  local stamp; stamp=$(date +%Y%m%d_%H%M%S)
  local backup_name="${BACKUP_PREFIX}-${stamp}"
  local backup_tmp="${backup_root}/${backup_name}"
  local backup_file="${backup_root}/${backup_name}.tar.gz"

  mkdir -p "$backup_tmp"

  local was_running=false
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
    was_running=true
    _info "暂停容器以确保数据一致性..."
    docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
  fi

  _info "复制数据..."
  mkdir -p "$backup_tmp/workspace"
  if ! cp -a "${workspace_to_backup}/." "$backup_tmp/workspace/" 2>/dev/null; then
    _err "数据复制失败"
    [[ "$was_running" == true ]] && docker start "$CONTAINER_NAME" >/dev/null 2>&1 || true
    rm -rf "$backup_tmp"
    press_any_key; return 1
  fi

  local cur_image=""
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
    cur_image=$(docker inspect --format='{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null || echo "未知")
  fi

  cat > "$backup_tmp/backup_info.txt" << EOF
备份时间：$(date '+%Y-%m-%d %H:%M:%S')
主机名：$(hostname)
架构：$(uname -m)
操作系统：${OS_TYPE}
容器名：${CONTAINER_NAME}
镜像版本：${cur_image}
工作空间：${workspace_to_backup}
EOF

  if [[ "$was_running" == true ]]; then
    _info "恢复容器运行..."
    docker start "$CONTAINER_NAME" >/dev/null 2>&1 \
      && _ok "容器已恢复" \
      || _warn "请手动启动：docker start $CONTAINER_NAME"
  fi

  _info "打包压缩中..."
  if tar -czf "$backup_file" -C "$backup_root" "$backup_name" 2>/dev/null; then
    rm -rf "$backup_tmp"
    local size; size=$(du -sh "$backup_file" 2>/dev/null | cut -f1 || echo "未知")
    _ok "备份完成：$backup_file（$size）"
    log "备份完成：$backup_file"
  else
    _err "打包失败，临时目录：$backup_tmp"
    press_any_key; return 1
  fi

  press_any_key
}

restore_data() {
  echo ""
  echo "===== 恢复思源笔记数据 ====="

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
      while IFS= read -r f; do found_files+=("$f"); done < <(_scan_backup_files)

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

  local info_file; info_file=$(find "$restore_tmp" -maxdepth 3 -name "backup_info.txt" | head -n1 || true)
  if [[ -n "$info_file" ]]; then
    echo ""
    echo "---- 备份信息 ----"
    cat "$info_file"
    echo "------------------"
  fi

  local restore_base; restore_base=$(dirname "${info_file:-$restore_tmp/x}")
  if [[ ! -d "$restore_base/workspace" ]]; then
    _err "备份包中无 workspace 目录"
    press_any_key; return 1
  fi

  local target_ws="$CONTAINER_WORKSPACE"
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
    local detected_ws
    detected_ws=$(docker inspect "$CONTAINER_NAME" 2>/dev/null | \
      jq -r '.[0].Mounts[]? | select(.Destination == "/siyuan/workspace") | .Source' \
      2>/dev/null | head -n1 || true)
    [[ -n "$detected_ws" ]] && target_ws="$detected_ws"
  fi

  echo ""
  _warn "将恢复到目录：$target_ws"
  read -rp "确认恢复？(y/N): " confirm </dev/tty
  [[ "${confirm,,}" == "y" ]] || { _warn "已取消"; press_any_key; return; }

  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
    _info "停止容器..."
    docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
  fi

  if [[ -d "$target_ws" ]]; then
    local bak_old="${target_ws}_old_$(date +%Y%m%d_%H%M%S)"
    mv "$target_ws" "$bak_old" 2>/dev/null \
      && _info "旧数据目录已保留：$bak_old" \
      || { _err "无法移动旧数据目录"; press_any_key; return 1; }
  fi

  mkdir -p "$target_ws"
  if cp -a "$restore_base/workspace/." "$target_ws/" 2>/dev/null; then
    chown -R 1000:1000 "$target_ws" 2>/dev/null || true
    local fc; fc=$(find "$target_ws" -type f 2>/dev/null | wc -l || echo 0)
    _ok "数据恢复完成（$fc 个文件）"
  else
    _err "数据恢复失败"
    press_any_key; return 1
  fi

  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
    docker start "$CONTAINER_NAME" >/dev/null 2>&1 \
      && _ok "容器已启动" \
      || _warn "请通过菜单手动启动容器"
  else
    _warn "容器不存在，请通过菜单重新部署（数据已恢复）"
  fi

  _ok "恢复完成"
  press_any_key
}

list_backups() {
  echo ""
  echo "---- 思源笔记备份文件列表 ----"
  local found=false
  while IFS= read -r f; do
    local sz; sz=$(du -sh "$f" 2>/dev/null | cut -f1 || echo "?")
    local ts; ts=$(echo "$f" | grep -oE '[0-9]{8}_[0-9]{6}' | \
      sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)_\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3 \4:\5:\6/' || echo "")
    printf "  %-52s [%s] %s\n" "$f" "$sz" "$ts"
    found=true
  done < <(_scan_backup_files)
  [[ "$found" == false ]] && _warn "未找到任何备份文件"
  echo "--------------------------------"
  press_any_key
}

uninstall() {
  echo ""
  echo "===== 卸载思源笔记 ====="

  local workspace_path="$CONTAINER_WORKSPACE"

  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
    workspace_path=$(docker inspect "$CONTAINER_NAME" 2>/dev/null | \
      jq -r '.[0].Mounts[]? | select(.Destination == "/siyuan/workspace") | .Source' \
      2>/dev/null | head -n1 || echo "$CONTAINER_WORKSPACE")

    _warn "将删除容器：$CONTAINER_NAME"
    read -rp "确认删除容器？(y/N): " del_container </dev/tty
    if [[ "${del_container,,}" == "y" ]]; then
      docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 \
        && _ok "容器已删除" \
        || _warn "删除失败，可能已不存在"
    else
      _warn "已取消"; press_any_key; return
    fi
  else
    _warn "未检测到容器 $CONTAINER_NAME"
  fi

  local images=()
  mapfile -t images < <(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | \
    grep "^${BASE_IMAGE_NAME}" || true)
  if [[ ${#images[@]} -gt 0 ]]; then
    echo ""
    echo "检测到以下镜像："
    for img in "${images[@]}"; do echo "  $img"; done
    read -rp "是否删除这些镜像？(y/N): " del_img </dev/tty
    if [[ "${del_img,,}" == "y" ]]; then
      for img in "${images[@]}"; do
        docker rmi "$img" >/dev/null 2>&1 && _ok "已删除：$img" || _warn "删除失败：$img"
      done
    fi
  fi

  if [[ -d "$workspace_path" ]]; then
    echo ""
    _warn "数据目录：$workspace_path"
    _warn "删除后所有笔记数据将永久丢失！"
    read -rp "是否先备份？(y/N): " do_backup </dev/tty
    if [[ "${do_backup,,}" == "y" ]]; then
      backup_data
    fi
    read -rp "确认删除数据目录？(输入 yes 确认): " del_data </dev/tty
    if [[ "$del_data" == "yes" ]]; then
      rm -rf "$workspace_path" \
        && _ok "数据目录已删除" \
        || _err "删除失败，请手动执行：rm -rf $workspace_path"
    else
      _warn "数据目录已保留：$workspace_path"
    fi
  fi

  read -rp "是否清理 Docker 悬空资源？(y/N): " clean_docker </dev/tty
  if [[ "${clean_docker,,}" == "y" ]]; then
    docker image prune -f >/dev/null 2>&1 && _ok "已清理悬空镜像"
    docker volume prune -f >/dev/null 2>&1 && _ok "已清理悬空卷"
  fi

  _ok "卸载完成"
  press_any_key
}

_get_status_line() {
  if ! _have docker; then
    echo "Docker 未安装"
    return
  fi
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
    local img; img=$(docker inspect --format='{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null || echo "")
    local port; port=$(docker port "$CONTAINER_NAME" 6806/tcp 2>/dev/null | head -n1 | grep -oE '[0-9]+$' || echo "")
    echo "运行中  [${img}${port:+，端口 $port}]"
  elif docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
    local img; img=$(docker inspect --format='{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null || echo "")
    echo "已停止  [${img}]"
  else
    echo "未部署"
  fi
}

detect_os
detect_arch

while true; do
  container_status=$(_get_status_line)
  local_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' | head -n1 || \
             hostname -I 2>/dev/null | awk '{print $1}' || echo "<本机IP>")

  echo ""
  echo "========== 思源笔记部署管理脚本 v${SCRIPT_VERSION} =========="
  echo "  系统：${OS_TYPE}    架构：${ARCH_NAME}    本机IP：${local_ip}"
  echo "  容器状态：${container_status}"
  echo "  镜像源：自动测速选择（国内加速 → 直连 Docker Hub）"
  echo "-----------------------------------------------------------"
  echo "  1. 安装并启动思源笔记"
  echo "  2. 无损更新（保留所有数据与配置）"
  echo "  3. 容器启停控制（启动/停止/重启）"
  echo "  4. 查看容器日志"
  echo "  5. 查看容器状态"
  echo "  6. 备份笔记数据"
  echo "  7. 恢复笔记数据"
  echo "  8. 查看备份列表"
  echo "  9. 卸载并清理"
  echo " 10. 安装依赖（Docker/curl/jq）"
  echo " 11. 修复 OpenWrt 网络防火墙"
  echo "  0. 退出"
  echo "==========================================================="
  read -rp "请输入选项: " choice </dev/tty

  case "$choice" in
    1)
      ensure_docker_running || { press_any_key; continue; }
      get_available_tags
      get_user_input
      setup_workspace || { press_any_key; continue; }
      check_port || { press_any_key; continue; }
      select_network_mode || { press_any_key; continue; }
      pull_image || { press_any_key; continue; }
      start_container || true
      press_any_key
      ;;
    2)  upgrade_siyuan ;;
    3)  control_container ;;
    4)  view_logs ;;
    5)  view_containers ;;
    6)  backup_data ;;
    7)  restore_data ;;
    8)  list_backups ;;
    9)  uninstall ;;
    10) install_dependencies ;;
    11) fix_openwrt_firewall ;;
    0)
      _ok "感谢使用，再见"
      exit 0
      ;;
    *)
      _warn "无效选项，请输入 0-11"
      ;;
  esac
done
