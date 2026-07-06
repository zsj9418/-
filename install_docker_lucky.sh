#!/usr/bin/env bash
set -euo pipefail
trap 'echo -e "\n[!] 已中断"; exit 1' INT

SCRIPT_NAME="Lucky 终极部署管理器"
SCRIPT_VERSION="1.6.8-fixed"

CONTAINER_NAME="lucky"
IMAGE_NAME="gdy666/lucky"
CONTAINER_PORT_DEFAULT=16601

# Native
LUCKY_INSTALL_DIR="/usr/local/lucky"
LUCKY_BIN="/usr/local/bin/lucky"
LUCKY_SERVICE="/etc/systemd/system/lucky.service"

# Data
LUCKY_DATA_DIR="/var/lib/lucky"
LUCKY_DATA_DIR_LEGACY="/root/luckyconf"
DOCKER_CONFIG_DIR="${LUCKY_DATA_DIR_LEGACY}"
BACKUP_GLOB="/root/lucky_backup_*"

# GitHub
LUCKY_GITHUB_REPO="gdy666/lucky"
LUCKY_GITHUB_RELEASE="https://github.com/${LUCKY_GITHUB_REPO}/releases/download"
GH_API_MIRRORS=(
  "https://api.github.com/repos/${LUCKY_GITHUB_REPO}/releases"
  "https://gh-proxy.com/https://api.github.com/repos/${LUCKY_GITHUB_REPO}/releases"
  "https://ghproxy.link/https://api.github.com/repos/${LUCKY_GITHUB_REPO}/releases"
)
GH_DL_MIRRORS=( "" "https://gh-proxy.com/" "https://ghproxy.link/" "https://ghfast.top/" "https://ghps.cc/" "https://mirror.ghproxy.com/" )

# ── 终端颜色配置 ──────────────────────────────────────
if [[ -t 1 ]]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
  BLUE=$'\033[34m'; CYAN=$'\033[36m'; RESET=$'\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; RESET=''
fi

logi(){ echo -e "${CYAN}[i]${RESET} $*"; }
ok(){   echo -e "${GREEN}[✓]${RESET} $*"; }
warn(){ echo -e "${YELLOW}[!]${RESET} $*"; }
err(){  echo -e "${RED}[x]${RESET} $*" >&2; }
die(){  err "$*"; exit 1; }

have(){      command -v "$1" >/dev/null 2>&1; }
need_root(){ [[ "${EUID}" -eq 0 ]] || die "该操作需要 root 权限。"; }

# ── 交互读取 ──────────────────────────────────────
_READ_VAL=""

_read_tty(){
  local _rt_prompt="$1" _rt_silent="${2:-false}"
  _READ_VAL=""
  if [[ -r /dev/tty ]]; then
    if [[ "$_rt_silent" == "true" ]]; then
      read -r -s -p "$_rt_prompt" _READ_VAL </dev/tty || true; echo "" >/dev/tty
    else
      read -r -p "$_rt_prompt" _READ_VAL </dev/tty || true
    fi
  else
    if [[ "$_rt_silent" == "true" ]]; then
      read -r -s -p "$_rt_prompt" _READ_VAL || true; echo ""
    else
      read -r -p "$_rt_prompt" _READ_VAL || true
    fi
  fi
}

read_default(){
  local _rd_prompt="$1" _rd_def="$2" _rd_outvar="$3"
  _read_tty "$_rd_prompt [$_rd_def]: " false
  [[ -z "$_READ_VAL" ]] && _READ_VAL="$_rd_def"
  printf -v "$_rd_outvar" '%s' "$_READ_VAL"
}

read_yesno_default(){
  local _ry_prompt="$1" _ry_def="${2^^}" _ry_outvar="$3"
  _read_tty "$_ry_prompt (Y/N, 默认 $_ry_def): " false
  _READ_VAL="${_READ_VAL^^}"
  [[ -z "$_READ_VAL" ]] && _READ_VAL="$_ry_def"
  if [[ "$_READ_VAL" == "Y" ]]; then
    printf -v "$_ry_outvar" '%s' "true"
  else
    printf -v "$_ry_outvar" '%s' "false"
  fi
}

press_any(){
  [[ -r /dev/tty ]] || { echo ""; return 0; }
  local _junk=""
  read -rn1 -s -p "按任意键返回..." _junk </dev/tty || true
  echo "" >/dev/tty
}

ensure_pkg_tools(){
  have curl || die "缺少 curl，请先安装"
  have tar  || die "缺少 tar，请先安装"
}

install_docker_if_missing(){
  if have docker; then return 0; fi
  warn "未检测到 Docker，准备自动安装。"
  need_root
  local tmp="/tmp/get-docker.sh"
  curl -fsSL https://get.docker.com -o "$tmp" || die "下载 Docker 安装脚本失败"
  sh "$tmp" || die "Docker 安装失败"
  rm -f "$tmp" || true
  have systemctl && systemctl enable --now docker >/dev/null 2>&1 || true
  have docker || die "Docker 仍不可用"
  ok "Docker OK：$(docker --version 2>/dev/null || true)"
}

ensure_docker(){ install_docker_if_missing; }
docker_container_exists(){ docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; }

get_host_ip(){
  local _ip=""
  _ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/{print $7; exit}' || true)"
  if [[ -z "$_ip" ]]; then
    _ip="$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1 || true)"
  fi
  echo "${_ip:-}"
}

# ── Docker 部署逻辑 ────────────────────────────────────
get_dockerhub_tags(){
  local url="https://hub.docker.com/v2/repositories/gdy666/lucky/tags?page_size=50&ordering=last_updated"
  local raw="$(curl -fsSL -m 12 "$url" 2>/dev/null || true)"
  [[ -z "$raw" ]] && return 1
  if have jq; then echo "$raw" | jq -r '.results[].name' | grep -v '^latest$' | grep -E '^[0-9v]' | head -n 30
  else echo "$raw" | grep -o '"name":"[^"]*"' | cut -d'"' -f4 | grep -v '^latest$' | grep -E '^[0-9v]' | head -n 30; fi
}
choose_docker_tag(){
  DOCKER_TAG="latest"
  logi "获取 Docker Hub 版本（回车默认 latest）"
  local tags=() tlist="$(get_dockerhub_tags || true)"
  [[ -n "$tlist" ]] && mapfile -t tags < <(printf "%s\n" "$tlist")
  echo "  1) latest (默认)"
  local i=2; for t in "${tags[@]:0:12}"; do echo "  $i) $t"; ((i++)); done
  local manual_idx=$i; echo "  $i) 手动输入"
  local choice=""; read_default "编号" "1" choice
  if [[ "$choice" == "1" ]]; then DOCKER_TAG="latest"; return; fi
  if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 2 && "$choice" -lt "$manual_idx" ]]; then DOCKER_TAG="${tags[$((choice-2))]}"; return; fi
  if [[ "$choice" == "$manual_idx" ]]; then read_default "输入 tag" "latest" DOCKER_TAG; return; fi
  DOCKER_TAG="latest"
}
deploy_docker(){
  clear; echo -e "${GREEN}🚀 Docker 部署${RESET}"; ensure_docker
  if docker_container_exists; then
    warn "容器已存在：$CONTAINER_NAME"; local ow=false; read_yesno_default "覆盖重建？" "N" ow
    [[ "$ow" == "true" ]] || { warn "取消"; press_any; return; }
    docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true; docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
  mkdir -p "$DOCKER_CONFIG_DIR"; choose_docker_tag
  echo "  1) Bridge（默认）  2) Host"; local mode=""; read_default "选择" "1" mode; local host_port="$CONTAINER_PORT_DEFAULT"
  if [[ "$mode" != "2" ]]; then
    read_default "宿主机端口" "$CONTAINER_PORT_DEFAULT" host_port
    if ! [[ "$host_port" =~ ^[0-9]+$ ]] || (( host_port < 1 || host_port > 65535 )); then host_port="$CONTAINER_PORT_DEFAULT"; fi
  else
    local go=false; read_yesno_default "Host 模式继续？" "N" go
    [[ "$go" == "true" ]] || { warn "取消"; press_any; return; }
  fi
  docker pull "${IMAGE_NAME}:${DOCKER_TAG}" || die "拉取失败"
  if [[ "$mode" == "2" ]]; then docker run -d --name "$CONTAINER_NAME" --restart=always --net=host -v "${DOCKER_CONFIG_DIR}:/goodluck" "${IMAGE_NAME}:${DOCKER_TAG}"
  else docker run -d --name "$CONTAINER_NAME" --restart=always -p "${host_port}:${CONTAINER_PORT_DEFAULT}" -v "${DOCKER_CONFIG_DIR}:/goodluck" "${IMAGE_NAME}:${DOCKER_TAG}"; fi
  local ip="$(get_host_ip)"; ok "访问：http://${ip:-<IP>}:${host_port}"; press_any
}
upgrade_docker(){
  clear; echo -e "${CYAN}🔄 Docker 更新${RESET}"; ensure_docker
  docker_container_exists || { warn "未部署"; press_any; return; }
  choose_docker_tag; docker pull "${IMAGE_NAME}:${DOCKER_TAG}" || { warn "拉取失败"; press_any; return; }
  local net_mode="$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$CONTAINER_NAME" 2>/dev/null || echo bridge)"; local host_port="$CONTAINER_PORT_DEFAULT"
  if [[ "$net_mode" != "host" ]]; then
    if have jq; then host_port="$(docker inspect "$CONTAINER_NAME" | jq -r --arg p "${CONTAINER_PORT_DEFAULT}/tcp" '.[0].HostConfig.PortBindings[$p]?[0]?.HostPort // empty' 2>/dev/null || true)"
    elif have python3; then host_port="$(docker inspect "$CONTAINER_NAME" | python3 -c "import sys,json; d=json.load(sys.stdin)[0]; pb=d.get('HostConfig',{}).get('PortBindings',{}); key='${CONTAINER_PORT_DEFAULT}/tcp'; b=pb.get(key); print(b[0]['HostPort'] if b else '')" 2>/dev/null || true)"; fi
    host_port="${host_port:-$CONTAINER_PORT_DEFAULT}"
  fi
  docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true; docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true; mkdir -p "$DOCKER_CONFIG_DIR"
  if [[ "$net_mode" == "host" ]]; then docker run -d --name "$CONTAINER_NAME" --restart=always --net=host -v "${DOCKER_CONFIG_DIR}:/goodluck" "${IMAGE_NAME}:${DOCKER_TAG}"
  else docker run -d --name "$CONTAINER_NAME" --restart=always -p "${host_port}:${CONTAINER_PORT_DEFAULT}" -v "${DOCKER_CONFIG_DIR}:/goodluck" "${IMAGE_NAME}:${DOCKER_TAG}"; fi
  ok "更新完成"; press_any
}
uninstall_docker(){
  clear; echo -e "${YELLOW}🗑️ Docker 卸载${RESET}"
  if docker_container_exists; then
    local go=false; read_yesno_default "删除容器？" "N" go; [[ "$go" == "true" ]] || { warn "取消"; press_any; return; }
    docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true; docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true; ok "容器已删除"
  else warn "未发现容器"; fi
  local del=false; read_yesno_default "删除配置目录 ${DOCKER_CONFIG_DIR}？" "N" del; [[ "$del" == "true" ]] && { rm -rf "$DOCKER_CONFIG_DIR"; ok "配置已删"; } || true; press_any
}
manage_container(){
  clear; echo -e "${CYAN}⚙️ 容器管理${RESET}"; ensure_docker
  docker_container_exists || { warn "未部署"; press_any; return; }
  echo "1 启动  2 停止  3 重启  4 日志(80行)  5 返回"; local op=""; read_default "选择" "5" op
  case "$op" in
    1) docker start "$CONTAINER_NAME" && ok "已启动" || warn "启动失败" ;;
    2) docker stop "$CONTAINER_NAME" && ok "已停止" || warn "停止失败" ;;
    3) docker restart "$CONTAINER_NAME" && ok "已重启" || warn "重启失败" ;;
    4) docker logs --tail 80 "$CONTAINER_NAME" ;;
  esac; press_any
}

# ── 原生版 (Native) 逻辑 ────────────────────────────────
ensure_lucky_user(){
  id lucky >/dev/null 2>&1 && return 0
  useradd --system --no-create-home --shell /usr/sbin/nologin lucky >/dev/null 2>&1 \
    || { warn "创建用户 lucky 失败，后续将使用 root"; return 1; }
  ok "已创建系统用户 lucky"
}

selinux_enforcing(){
  have getenforce || return 1
  [[ "$(getenforce 2>/dev/null || echo Disabled)" == "Enforcing" ]]
}

restorecon_dir(){
  have restorecon || return 0
  restorecon -Rv "$1" >/dev/null 2>&1 || true
}

ensure_data_dir_ready(){
  need_root
  mkdir -p "$LUCKY_DATA_DIR"
  ensure_lucky_user || true
  chown -R lucky:lucky "$LUCKY_DATA_DIR" >/dev/null 2>&1 || true
  mkdir -p "$LUCKY_INSTALL_DIR"
  chown -R lucky:lucky "$LUCKY_INSTALL_DIR" >/dev/null 2>&1 || true
  chmod 755 "$LUCKY_DATA_DIR" "$LUCKY_INSTALL_DIR"
  selinux_enforcing && { restorecon_dir "$LUCKY_DATA_DIR"; restorecon_dir "$LUCKY_INSTALL_DIR"; }
  ok "目录权限就绪"
}

# 🛠️ 修复：增加了 ExecStartPre=-/bin/rm -f /tmp/lucky.control.sock 防止意外崩溃留下的 socket 文件导致下次启动 panic
create_native_service_lucky_caps(){
  cat > "$LUCKY_SERVICE" <<EOF
[Unit]
Description=Lucky (lucky + capabilities)
After=network.target

[Service]
Type=simple
User=lucky
Group=lucky
WorkingDirectory=${LUCKY_DATA_DIR}
ExecStartPre=-/bin/rm -f /tmp/lucky.control.sock
ExecStart=${LUCKY_INSTALL_DIR}/lucky -c ${LUCKY_DATA_DIR}/lucky.conf
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

NoNewPrivileges=false
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
}

create_native_service_lucky_minimal(){
  cat > "$LUCKY_SERVICE" <<EOF
[Unit]
Description=Lucky (lucky minimal)
After=network.target

[Service]
Type=simple
User=lucky
Group=lucky
WorkingDirectory=${LUCKY_DATA_DIR}
ExecStartPre=-/bin/rm -f /tmp/lucky.control.sock
ExecStart=${LUCKY_INSTALL_DIR}/lucky -c ${LUCKY_DATA_DIR}/lucky.conf
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

create_native_service_root_minimal(){
  cat > "$LUCKY_SERVICE" <<EOF
[Unit]
Description=Lucky (root fallback)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${LUCKY_DATA_DIR}
ExecStartPre=-/bin/rm -f /tmp/lucky.control.sock
ExecStart=${LUCKY_INSTALL_DIR}/lucky -c ${LUCKY_DATA_DIR}/lucky.conf
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

start_native_auto(){
  need_root
  systemctl stop lucky >/dev/null 2>&1 || true
  # 清理一下，双保险
  rm -f /tmp/lucky.control.sock 2>/dev/null || true

  create_native_service_lucky_caps
  systemctl daemon-reload
  systemctl enable lucky >/dev/null 2>&1 || true
  systemctl restart lucky || true
  sleep 3
  if systemctl is-active lucky &>/dev/null; then
    ok "启动成功：lucky + capabilities"; return 0
  fi

  warn "尝试 lucky minimal 模式..."
  create_native_service_lucky_minimal
  systemctl daemon-reload
  systemctl restart lucky || true
  sleep 3
  if systemctl is-active lucky &>/dev/null; then
    ok "启动成功：lucky minimal"; return 0
  fi

  warn "仍失败，启用 root 兜底（兼容模式）"
  create_native_service_root_minimal
  systemctl daemon-reload
  systemctl restart lucky || true
  sleep 3
  if systemctl is-active lucky &>/dev/null; then
    ok "启动成功：root 兜底"; return 0
  fi

  err "三种模式均启动失败，请查看日志：journalctl -u lucky -n 50"
  return 1
}

migrate_legacy_data_if_needed(){
  need_root
  if [[ -d "$LUCKY_DATA_DIR_LEGACY" ]] && [[ -n "$(ls -A "$LUCKY_DATA_DIR_LEGACY" 2>/dev/null || true)" ]]; then
    local go=false
    read_yesno_default "发现旧目录 ${LUCKY_DATA_DIR_LEGACY}，迁移到 ${LUCKY_DATA_DIR}？" "Y" go
    [[ "$go" == "true" ]] || return 0
    mkdir -p "$LUCKY_DATA_DIR"
    if have rsync; then rsync -a "$LUCKY_DATA_DIR_LEGACY"/ "$LUCKY_DATA_DIR"/ || true
    else cp -a "$LUCKY_DATA_DIR_LEGACY"/. "$LUCKY_DATA_DIR"/ 2>/dev/null || true; fi
    ensure_data_dir_ready
    mv "$LUCKY_DATA_DIR_LEGACY" "${LUCKY_DATA_DIR_LEGACY}.migrated.$(date +%Y%m%d)" 2>/dev/null || true
    ok "迁移完成（旧目录已重命名）"
  fi
}

cleanup_data_with_backup(){
  need_root
  local backup_dir="/root/lucky_backup_$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$backup_dir"
  warn "备份并清空数据目录：$LUCKY_DATA_DIR"
  tar -czf "$backup_dir/lucky_data.tgz" -C "$(dirname "$LUCKY_DATA_DIR")" "$(basename "$LUCKY_DATA_DIR")" 2>/dev/null || true
  find "${LUCKY_DATA_DIR}" -mindepth 1 -delete 2>/dev/null || true
  ensure_data_dir_ready
  ok "清理完成（备份：$backup_dir）"
}

detect_arch(){
  local arch; arch="$(uname -m)"
  case "$arch" in
    aarch64|arm64) LUCKY_ARCH="arm64" ;;
    x86_64)        LUCKY_ARCH="x86_64" ;;
    i386|i686)     LUCKY_ARCH="i386" ;;
    *)             LUCKY_ARCH="$arch" ;;
  esac
  LUCKY_OS="Linux"
  logi "架构：${arch} → ${LUCKY_ARCH}"
}

get_native_versions_list(){
  local raw=""
  for url in "${GH_API_MIRRORS[@]}"; do
    raw="$(curl -sL -m 15 --connect-timeout 8 "${url}?per_page=50" 2>/dev/null || true)"
    echo "$raw" | grep -q '"tag_name"' && break
    raw=""
  done
  [[ -z "$raw" ]] && return 1
  if have jq; then echo "$raw" | jq -r '.[].tag_name' | head -n 20
  else echo "$raw" | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' | sed -E 's/.*"([^"]+)".*/\1/' | head -n 20; fi
}

choose_native_version(){
  NATIVE_VERSION=""
  logi "获取 GitHub 版本列表..."
  local versions=() vlist="$(get_native_versions_list || true)"
  if [[ -n "$vlist" ]]; then mapfile -t versions < <(printf "%s\n" "$vlist"); fi
  if [[ "${#versions[@]}" -eq 0 ]]; then
    warn "获取版本列表失败，使用预置版本"
    versions=("v2.27.2" "v2.26.2" "v2.20.2" "v2.19.5" "v2.18.1")
  fi
  local default_ver="${versions[0]}"
  echo "选择版本（回车默认最新：${default_ver}）"
  local i; for i in "${!versions[@]}"; do echo "  $((i+1))) ${versions[$i]}"; done
  local manual_idx=$(( ${#versions[@]} + 1 )); echo "  ${manual_idx}) 手动输入"
  local c=""; read_default "编号" "1" c
  if [[ "$c" =~ ^[0-9]+$ ]] && [[ "$c" -ge 1 && "$c" -le "${#versions[@]}" ]]; then NATIVE_VERSION="${versions[$((c-1))]}"
  elif [[ "$c" == "$manual_idx" ]]; then
    read_default "输入版本号（如 v2.27.2）" "$default_ver" NATIVE_VERSION
    [[ "$NATIVE_VERSION" =~ ^v ]] || NATIVE_VERSION="v${NATIVE_VERSION}"
  else NATIVE_VERSION="$default_ver"; fi
  ok "选择版本：$NATIVE_VERSION"
}

safe_version_guard(){
  local ver="${1:-}"
  [[ -n "$ver" ]] || die "版本号为空"
  [[ "$ver" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "版本号格式不合法：${ver}"
}

build_download_urls(){
  local version="$1"; safe_version_guard "$version"
  local tag="$version"; local num="${version#v}"
  [[ "$tag" =~ ^v ]] || tag="v${tag}"
  LUCKY_FILENAME="lucky_${num}_${LUCKY_OS}_${LUCKY_ARCH}.tar.gz"
  local github_url="${LUCKY_GITHUB_RELEASE}/${tag}/${LUCKY_FILENAME}"
  DOWNLOAD_URLS=()
  for p in "${GH_DL_MIRRORS[@]}"; do
    [[ -z "$p" ]] && DOWNLOAD_URLS+=("$github_url") || DOWNLOAD_URLS+=("${p}${github_url}")
  done
}

download_file(){
  local dest="$1"; logi "下载目标：${LUCKY_FILENAME}"
  for url in "${DOWNLOAD_URLS[@]}"; do
    logi "尝试：${url}"
    if curl -L --progress-bar --connect-timeout 15 --max-time 600 --fail -o "$dest" "$url" 2>/dev/null; then
      local sz="$(stat -c%s "$dest" 2>/dev/null || echo 0)"
      if (( sz > 1024 )); then return 0; fi
      warn "文件大小异常，换源重试"; rm -f "$dest"
    fi
  done
  return 1
}

install_or_reinstall_native(){
  clear; echo -e "${GREEN}📦 原生安装/重装${RESET}"; need_root
  detect_arch; choose_native_version; safe_version_guard "${NATIVE_VERSION:-}"; build_download_urls "$NATIVE_VERSION"
  migrate_legacy_data_if_needed; ensure_data_dir_ready
  local tmp="$(mktemp -d)"
  trap "rm -rf '${tmp}'" RETURN
  if ! download_file "$tmp/$LUCKY_FILENAME"; then warn "下载失败"; press_any; return 0; fi
  if ! tar -xzf "$tmp/$LUCKY_FILENAME" -C "$tmp"; then warn "解压失败"; press_any; return 0; fi
  local bin="$(find "$tmp" -name lucky -type f | head -n1 || true)"
  if [[ -z "$bin" ]]; then warn "未找到 lucky"; press_any; return 0; fi

  mkdir -p "$LUCKY_INSTALL_DIR"
  cp -f "$bin" "$LUCKY_INSTALL_DIR/lucky"
  chmod +x "$LUCKY_INSTALL_DIR/lucky"
  chown -R lucky:lucky "$LUCKY_INSTALL_DIR" >/dev/null 2>&1 || true
  ln -sf "$LUCKY_INSTALL_DIR/lucky" "$LUCKY_BIN"
  ok "二进制就绪：$LUCKY_INSTALL_DIR/lucky"

  if start_native_auto; then
    local ip="$(get_host_ip)"; local run_user="$(systemctl show lucky -p User --value 2>/dev/null || echo unknown)"
    echo ""; ok "访问地址：http://${ip:-<服务器IP>}:${CONTAINER_PORT_DEFAULT}"
    ok "运行用户：${run_user}"; warn "提示：首次登录请立即修改默认账号/密码。"; echo ""
  else warn "启动失败，查看日志：journalctl -u lucky -n 200"; fi
  press_any; return 0
}

native_menu(){
  while true; do
    clear
    echo -e "${BLUE}=== 原生版管理（已修复启动文件残留冲突）===${RESET}"
    echo "  1) 安装/重装原生版（覆盖修复残留问题）"
    echo "  2) 启动服务"
    echo "  3) 停止服务"
    echo "  4) 重启服务"
    echo "  5) 查看日志（200行）"
    echo "  6) 修复：备份并清空数据目录后重启"
    echo "  7) 返回主菜单"
    echo ""
    local c=""; read_default "选择" "7" c
    case "$c" in
      1) install_or_reinstall_native ;;
      2) need_root; systemctl start lucky && ok "已启动" || { warn "启动失败，日志：journalctl -u lucky -n 30"; }; press_any ;;
      3) need_root; systemctl stop lucky && ok "已停止" || warn "停止失败"; press_any ;;
      4) need_root; systemctl restart lucky && ok "已重启" || { warn "重启失败，日志：journalctl -u lucky -n 30"; }; press_any ;;
      5) journalctl -u lucky --no-pager -n 200 2>/dev/null || warn "journalctl 不可用"; press_any ;;
      6) need_root; systemctl stop lucky >/dev/null 2>&1 || true; cleanup_data_with_backup; start_native_auto || true; press_any ;;
      7) return 0 ;;
      *) warn "无效选择"; sleep 1 ;;
    esac
  done
}

# ── 状态及全局维护 ──────────────────────────────────────
show_status(){
  clear; echo -e "${BLUE}🔍 状态${RESET}"
  echo -e "\n${BLUE}[Docker]${RESET}"
  if have docker && docker_container_exists; then docker ps -a --filter "name=^/${CONTAINER_NAME}$"; echo "配置目录：$DOCKER_CONFIG_DIR"
  else echo "未部署（或 Docker 不可用）"; fi
  echo -e "\n${BLUE}[Native]${RESET}"
  if [[ -f "$LUCKY_INSTALL_DIR/lucky" ]]; then
    echo "二进制：$LUCKY_INSTALL_DIR/lucky"
    local run_user="$(systemctl show lucky -p User --value 2>/dev/null || echo unknown)"
    systemctl is-active lucky &>/dev/null && echo "服务：运行中" || echo "服务：未运行"
    echo "运行用户：${run_user}"; echo "数据目录：$LUCKY_DATA_DIR"
  else echo "未安装"; fi
  press_any
}

purge_everything(){
  clear; echo -e "${RED}⚠️  PURGE 完全清理（回到未安装前）${RESET}"; need_root
  echo "将删除：容器/镜像/原生二进制/systemd/数据目录（新旧）"
  local go=false; read_yesno_default "确认立即执行 PURGE？" "Y" go; [[ "$go" == "true" ]] || { warn "取消"; press_any; return; }
  if have docker; then
    docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true; docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
    local ids="$(docker images --format '{{.Repository}} {{.ID}}' | awk -v img="$IMAGE_NAME" '$1==img{print $2}' | sort -u || true)"
    [[ -n "$ids" ]] && echo "$ids" | xargs -r docker rmi -f >/dev/null 2>&1 || true
  fi
  systemctl stop lucky >/dev/null 2>&1 || true; systemctl disable lucky >/dev/null 2>&1 || true
  rm -f "$LUCKY_SERVICE" "$LUCKY_BIN"; rm -rf "$LUCKY_INSTALL_DIR"; systemctl daemon-reload >/dev/null 2>&1 || true
  rm -rf "$LUCKY_DATA_DIR" "$LUCKY_DATA_DIR_LEGACY"
  local del_bk=false; read_yesno_default "是否删除备份 ${BACKUP_GLOB}？" "N" del_bk
  if [[ "$del_bk" == "true" ]]; then find /root -maxdepth 1 -name 'lucky_backup_*' -exec rm -rf {} + 2>/dev/null || true; fi
  local del_user=false; read_yesno_default "是否删除系统用户/组 lucky？" "N" del_user
  if [[ "$del_user" == "true" ]]; then userdel lucky >/dev/null 2>&1 || true; groupdel lucky >/dev/null 2>&1 || true; fi
  ok "PURGE 完成：已尽可能恢复到未安装前状态"; press_any
}

main_menu(){
  clear; echo -e "${BLUE}======================================${RESET}"
  echo -e "  ${GREEN}${SCRIPT_NAME} v${SCRIPT_VERSION}${RESET}"
  echo -e "${BLUE}======================================${RESET}"
  echo -e "  ── Docker 模式 ──\n  1) 部署容器\n  2) 更新容器\n  3) 卸载容器\n  4) 查看状态\n  5) 管理容器"
  echo -e "  ── 原生模式 ──\n  6) 原生版管理（含修复）"
  echo -e "  ── 维护 ──\n  7) PURGE 完全清理（回到未安装前）\n  0) 退出"
  echo -e "${BLUE}======================================${RESET}"
}

main(){
  ensure_pkg_tools
  while true; do
    main_menu; local c=""; read_default "选择" "0" c
    case "$c" in
      1) deploy_docker ;; 2) upgrade_docker ;; 3) uninstall_docker ;; 4) show_status ;; 5) manage_container ;;
      6) native_menu ;; 7) purge_everything ;; 0) ok "再见"; exit 0 ;; *) warn "无效选择"; sleep 1 ;;
    esac
  done
}

main
