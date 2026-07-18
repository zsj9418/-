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
FREELLMAPI_IMAGE_BASE="ghcr.io/tashfeenahmed/freellmapi"

FREELLMAPI_COMPOSE_DIR="$HOME/freellmapi"
COMPOSE_FALLBACK_VERSION="v2.39.1"

DOCKER_MIRRORS=(
  "https://docker.1ms.run"
  "https://dockerproxy.com"
  "https://hub.rat.dev"
  "https://mirror.baidubce.com"
)

function green()  { echo -e "\e[32m$1\e[0m"; }
function red()    { echo -e "\e[31m$1\e[0m"; }
function yellow() { echo -e "\e[33m$1\e[0m"; }
function cyan()   { echo -e "\e[36m$1\e[0m"; }
function bold()   { echo -e "\e[1m$1\e[0m"; }

function press_any_key() {
  echo ""
  read -rn 1 -s -p "按任意键继续..." </dev/tty
  echo ""
}

function setup_logging() {
  local tmp_id=""
  [[ -f /etc/os-release ]] && tmp_id=$(grep '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]')
  if [[ "$tmp_id" == "openwrt" || "$tmp_id" == "libwrt" ]]; then
    LOG_FILE="/tmp/deploy_script.log"
    yellow "提示：OpenWrt 日志写入 /tmp，重启后丢失。"
  else
    LOG_FILE="$HOME/.deploy_script.log"
  fi
  local LOG_MAX_SIZE=3145728
  local cur_size=0
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
    *)
      yellow "警告：未知架构 ($ARCH)，将不指定 Docker 平台。"
      PLATFORM=""
      ;;
  esac
  [[ -n "$PLATFORM" ]] && green "架构：$ARCH → 平台：$PLATFORM"
}

function detect_os() {
  if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    local id="${ID,,}"
    case "$id" in
      ubuntu|debian|raspbian)
        OS="debian"; PACKAGE_MANAGER="apt" ;;
      centos|rhel|rocky|almalinux)
        OS="$id"
        [[ -f /usr/bin/dnf ]] && PACKAGE_MANAGER="dnf" || PACKAGE_MANAGER="yum" ;;
      fedora)
        OS="fedora"; PACKAGE_MANAGER="dnf" ;;
      arch|manjaro)
        OS="arch"; PACKAGE_MANAGER="pacman" ;;
      openwrt|libwrt|nwrt|qwrt|hwrt|lede|immortalwrt|x-wrt|istoreos)
        OS="openwrt"; PACKAGE_MANAGER="opkg" ;;
      *)
        OS="$id"
        yellow "未明确支持的系统（$OS），尝试自动检测包管理器..."
        if   command -v apt    &>/dev/null; then PACKAGE_MANAGER="apt"
        elif command -v dnf    &>/dev/null; then PACKAGE_MANAGER="dnf"
        elif command -v yum    &>/dev/null; then PACKAGE_MANAGER="yum"
        elif command -v pacman &>/dev/null; then PACKAGE_MANAGER="pacman"
        elif command -v opkg   &>/dev/null; then PACKAGE_MANAGER="opkg"
        else red "无法找到已知包管理器，退出。"; exit 1
        fi
        ;;
    esac
  elif [[ "$(uname -s)" == "Linux" ]]; then
    yellow "未找到 /etc/os-release，尝试备用检测..."
    if   command -v apt    &>/dev/null; then OS="debian";  PACKAGE_MANAGER="apt"
    elif command -v dnf    &>/dev/null; then OS="fedora";  PACKAGE_MANAGER="dnf"
    elif command -v yum    &>/dev/null; then OS="centos";  PACKAGE_MANAGER="yum"
    elif command -v pacman &>/dev/null; then OS="arch";    PACKAGE_MANAGER="pacman"
    elif command -v opkg   &>/dev/null; then OS="openwrt"; PACKAGE_MANAGER="opkg"
    else red "无法识别操作系统，退出。"; exit 1
    fi
  else
    red "不支持的操作系统：$(uname -s)"; exit 1
  fi
  green "操作系统：$OS（包管理器：$PACKAGE_MANAGER）"
}

function install_dependency() {
  local cmd="$1"
  local pkg="$2"
  local update_cmd="" install_cmd=""
  command -v "$cmd" &>/dev/null && { green "$cmd 已安装。"; return 0; }
  yellow "准备安装 $pkg（提供 $cmd）..."
  case "$PACKAGE_MANAGER" in
    apt)    update_cmd="apt update"; install_cmd="apt install -y $pkg" ;;
    yum)    install_cmd="yum install -y $pkg" ;;
    dnf)    install_cmd="dnf install -y $pkg" ;;
    pacman) update_cmd="pacman -Syu --noconfirm"; install_cmd="pacman -S --noconfirm $pkg" ;;
    opkg)   update_cmd="opkg update"; install_cmd="opkg install $pkg" ;;
    *)      red "不支持的包管理器：$PACKAGE_MANAGER"; exit 1 ;;
  esac
  if [[ "$OS" != "openwrt" && "$EUID" -ne 0 ]]; then
    [[ -n "$update_cmd"  && "$update_cmd"  != sudo* ]] && update_cmd="sudo $update_cmd"
    [[ -n "$install_cmd" && "$install_cmd" != sudo* ]] && install_cmd="sudo $install_cmd"
  fi
  if [[ -n "$update_cmd" ]]; then
    yellow "执行：$update_cmd"
    eval "$update_cmd" || yellow "包列表更新失败，继续尝试安装..."
  fi
  yellow "执行：$install_cmd"
  if eval "$install_cmd"; then
    green "$pkg 安装成功。"
  else
    red "$pkg 安装失败，请手动安装后重试。"; return 1
  fi
}

function check_base_dependencies() {
  if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
    yellow "curl 和 wget 均未安装，尝试安装 curl..."
    install_dependency "curl" "curl" || true
  elif command -v curl &>/dev/null; then
    green "curl 已安装。"
  else
    green "wget 已安装。"
  fi
  if ! command -v ss &>/dev/null && ! command -v netstat &>/dev/null; then
    local ss_pkg="iproute2" netstat_pkg="net-tools"
    [[ "$PACKAGE_MANAGER" == "opkg" ]] && ss_pkg="ip-full" && netstat_pkg="netstat"
    [[ "$PACKAGE_MANAGER" == "yum" || "$PACKAGE_MANAGER" == "dnf" ]] && ss_pkg="iproute"
    install_dependency "netstat" "$netstat_pkg" || true
    if ! command -v netstat &>/dev/null; then
      install_dependency "ss" "$ss_pkg" || yellow "警告：端口检查工具安装失败。"
    fi
  elif command -v ss &>/dev/null; then
    green "端口检查工具 ss 已安装。"
  else
    green "端口检查工具 netstat 已安装。"
  fi
}

function check_docker_dependencies() {
  local docker_pkg="docker"
  local needs_repo=false
  case "$PACKAGE_MANAGER" in
    apt)    docker_pkg="docker.io" ;;
    yum|dnf)
      rpm -q docker-ce &>/dev/null || needs_repo=true
      docker_pkg="docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
      ;;
    pacman) docker_pkg="docker docker-compose" ;;
    opkg)   docker_pkg="docker dockerd docker-compose" ;;
  esac
  if [[ "$needs_repo" == true && "$OS" != "openwrt" ]]; then
    yellow "为 ${OS} 添加 Docker CE 官方仓库..."
    local repo_pkg="" repo_cmd=""
    if command -v dnf &>/dev/null; then
      repo_pkg="dnf-plugins-core"
      if [[ "$OS" == "fedora" ]]; then
        repo_cmd="dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo"
      else
        repo_cmd="dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo"
      fi
    elif command -v yum &>/dev/null; then
      repo_pkg="yum-utils"
      repo_cmd="yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo"
    fi
    if [[ -n "$repo_pkg" ]]; then
      install_dependency "config-manager" "$repo_pkg" || true
      local full_cmd="$repo_cmd"
      [[ "$EUID" -ne 0 && "$full_cmd" != sudo* ]] && full_cmd="sudo $full_cmd"
      eval "$full_cmd" || yellow "添加 Docker 仓库失败，继续尝试..."
    fi
  fi
  install_dependency "docker" "$docker_pkg" || true
  if [[ "$OS" == "openwrt" ]]; then
    /etc/init.d/dockerd status 2>/dev/null | grep -q "running" || {
      /etc/init.d/dockerd enable || true
      /etc/init.d/dockerd start  || yellow "请手动启动 Docker：/etc/init.d/dockerd start"
    }
  elif command -v systemctl &>/dev/null; then
    systemctl is-active --quiet docker || {
      local sc_cmd="systemctl enable --now docker"
      [[ "$EUID" -ne 0 ]] && sc_cmd="sudo $sc_cmd"
      eval "$sc_cmd" || yellow "请手动启动 Docker 服务。"
    }
    green "Docker 服务已运行（systemd）。"
  else
    yellow "未知服务管理器，请确保 Docker 已启动。"
  fi
  docker info &>/dev/null || { red "Docker 无法连接，请检查安装状态。"; exit 1; }
  if docker compose version &>/dev/null; then
    green "Docker Compose 插件：$(docker compose version | head -n1)"
  elif command -v docker-compose &>/dev/null; then
    green "Docker Compose 独立版：$(docker-compose --version)"
  else
    yellow "Docker Compose 未找到，尝试安装独立版..."
    local cv
    cv=$(curl -sSL --connect-timeout 10 \
      "https://api.github.com/repos/docker/compose/releases/latest" \
      | grep '"tag_name"' | head -n1 | cut -d'"' -f4 2>/dev/null \
      || echo "$COMPOSE_FALLBACK_VERSION")
    yellow "安装版本：$cv"
    local url="https://github.com/docker/compose/releases/download/${cv}/docker-compose-$(uname -s)-$(uname -m)"
    local dst="/usr/local/bin/docker-compose"
    [[ -w "/usr/local/bin" ]] || dst="/usr/bin/docker-compose"
    local dl_cmd=""
    command -v curl &>/dev/null \
      && dl_cmd="curl -sSL \"$url\" -o /tmp/docker-compose" \
      || dl_cmd="wget -q \"$url\" -O /tmp/docker-compose"
    eval "$dl_cmd" || { red "下载 docker-compose 失败。"; return 1; }
    local mv_cmd="mv /tmp/docker-compose \"$dst\""
    local cx_cmd="chmod +x \"$dst\""
    if [[ "$EUID" -ne 0 ]]; then mv_cmd="sudo $mv_cmd"; cx_cmd="sudo $cx_cmd"; fi
    eval "$mv_cmd" && eval "$cx_cmd" && green "docker-compose $cv 安装成功。" \
      || { red "安装 docker-compose 失败。"; rm -f /tmp/docker-compose; return 1; }
  fi
}

function check_user_permission() {
  [[ "$OS" == "openwrt" ]] && return 0
  [[ "$EUID" -eq 0 ]] && { green "当前为 root 用户。"; return 0; }
  if groups "$USER" | grep -q '\bdocker\b'; then
    green "用户 $USER 已在 docker 组中。"
  else
    yellow "用户 $USER 不在 docker 组中，尝试自动加入..."
    if command -v sudo &>/dev/null; then
      sudo usermod -aG docker "$USER" \
        && green "已加入 docker 组，请执行 'newgrp docker' 或重新登录生效。" \
        || red "自动加入失败，请手动执行：sudo usermod -aG docker $USER"
    else
      red "缺少 sudo，请手动执行：usermod -aG docker $USER"
    fi
  fi
}

function find_available_port() {
  local p=${1:-3000}
  local ck=""
  command -v ss      &>/dev/null && ck="ss -tuln"
  command -v netstat &>/dev/null && ck="${ck:-netstat -tuln}"
  [[ -z "$ck" ]] && { echo "$p"; return; }
  while $ck | grep -Eq "[:.\[]${p}[[:space:]]+"; do
    ((p++))
    [[ "$p" -gt 65535 ]] && { p=${1:-3000}; break; }
  done
  echo "$p"
}

function validate_port() {
  local hint=${1:-3000}
  local sug
  sug=$(find_available_port "$hint")
  green "建议端口：$sug"
  read -rp "请输入端口（留空使用 $sug）：" up </dev/tty
  PORT=${up:-$sug}
  if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [[ "$PORT" -lt 1 || "$PORT" -gt 65535 ]]; then
    red "无效端口，请重新输入。"; validate_port "$hint"; return
  fi
  local ck=""
  command -v ss      &>/dev/null && ck="ss -tuln"
  command -v netstat &>/dev/null && ck="${ck:-netstat -tuln}"
  if [[ -n "$ck" ]] && $ck | grep -Eq "[:.\[]${PORT}[[:space:]]+"; then
    red "端口 $PORT 已被占用。"; validate_port "$hint"; return
  fi
  green "使用端口：$PORT"
}

function choose_network_mode() {
  echo "请选择 Docker 网络模式："
  echo "  1. bridge（推荐，容器独立 IP，通过端口映射访问）"
  echo "  2. host  （共享主机网络，性能略好，端口冲突风险高）"
  read -rp "选项 (1-2，默认 1)：" mc </dev/tty
  case "${mc:-1}" in
    2) NETWORK_MODE="host";   green "网络模式：host" ;;
    *) NETWORK_MODE="bridge"; green "网络模式：bridge" ;;
  esac
}

function get_local_ip() {
  local ip="<服务器IP>"
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' \
    || ip -4 addr show scope global 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -n1 \
    || hostname -I 2>/dev/null | awk '{print $1}' \
    || echo "$ip")
  echo "$ip"
}

function ensure_dir_writable() {
  local d="$1"
  mkdir -p "$d"
  if ! touch "$d/.wtest" 2>/dev/null; then
    red "目录 $d 不可写，尝试修复权限..."
    local cc="chown $(id -u):$(id -g) \"$d\""
    local cm="chmod u+rwx \"$d\""
    [[ "$EUID" -ne 0 ]] && cc="sudo $cc" && cm="sudo $cm"
    eval "$cc" || true; eval "$cm" || true
    touch "$d/.wtest" 2>/dev/null || { red "修复失败，请手动检查 $d"; return 1; }
  fi
  rm -f "$d/.wtest"
  green "目录 $d 可写。"
}

function check_existing_container() {
  local n="$1"
  if docker ps -a --format '{{.Names}}' | grep -Eq "^${n}$"; then
    red "容器 '$n' 已存在，请先卸载后再部署。"
    return 1
  fi
  return 0
}

function pull_image_with_retry() {
  local img="$1"
  local pa=""
  [[ -n "${PLATFORM:-}" ]] && pa="--platform $PLATFORM"
  yellow "拉取镜像：$img（平台：${PLATFORM:-自动}）..."
  if ! docker pull $pa "$img"; then
    red "拉取失败：$img"
    read -rp "是否重试？(y/n，默认 n)：" rp </dev/tty
    [[ "${rp:-n}" =~ ^[Yy]$ ]] && pull_image_with_retry "$img" || { red "放弃拉取。"; return 1; }
  else
    green "镜像拉取成功：$img"
  fi
}

# ──────────────────────────────────────────────
# 打包工具检测
# ──────────────────────────────────────────────
function _check_pack_tools() {
  if   command -v tar &>/dev/null && command -v gzip  &>/dev/null; then echo "tar.gz"
  elif command -v tar &>/dev/null && command -v bzip2 &>/dev/null; then echo "tar.bz2"
  elif command -v tar &>/dev/null && command -v xz    &>/dev/null; then echo "tar.xz"
  elif command -v tar &>/dev/null;                                  then echo "tar"
  elif command -v zip &>/dev/null;                                  then echo "zip"
  else echo "none"
  fi
}

function _do_pack() {
  local src_dir="$1"
  local src_base="$2"
  local out_file="$3"
  local pack_type="$4"
  local err_file="/tmp/_pack_err_$$"

  case "$pack_type" in
    tar.gz)  tar -czf "$out_file" -C "$src_dir" "$src_base" 2>"$err_file" ;;
    tar.bz2) tar -cjf "$out_file" -C "$src_dir" "$src_base" 2>"$err_file" ;;
    tar.xz)  tar -cJf "$out_file" -C "$src_dir" "$src_base" 2>"$err_file" ;;
    tar)     tar -cf  "$out_file" -C "$src_dir" "$src_base" 2>"$err_file" ;;
    zip)     cd "$src_dir" && zip -qr "$out_file" "$src_base" 2>"$err_file"; cd - >/dev/null ;;
  esac

  local rc=$?
  if [[ $rc -ne 0 ]]; then
    local err_msg; err_msg=$(cat "$err_file" 2>/dev/null || true)
    rm -f "$err_file"
    [[ -n "$err_msg" ]] && red "  打包错误：$err_msg"
    return 1
  fi
  rm -f "$err_file"

  if [[ ! -f "$out_file" ]]; then
    red "  打包命令执行成功但文件未生成：$out_file"; return 1
  fi

  local fsize
  fsize=$(stat -c%s "$out_file" 2>/dev/null || stat -f%z "$out_file" 2>/dev/null || echo 0)
  if [[ "$fsize" -lt 10 ]]; then
    red "  打包文件大小异常（${fsize} 字节）。"
    rm -f "$out_file"; return 1
  fi
  return 0
}

function _do_unpack() {
  local archive="$1"
  local dest_dir="$2"
  local err_file="/tmp/_unpack_err_$$"

  case "$archive" in
    *.tar.gz|*.tgz) tar -xzf "$archive" -C "$dest_dir" 2>"$err_file" ;;
    *.tar.bz2)       tar -xjf "$archive" -C "$dest_dir" 2>"$err_file" ;;
    *.tar.xz)        tar -xJf "$archive" -C "$dest_dir" 2>"$err_file" ;;
    *.tar)           tar -xf  "$archive" -C "$dest_dir" 2>"$err_file" ;;
    *.zip)           unzip -q  "$archive" -d "$dest_dir" 2>"$err_file" ;;
    *) red "未知备份格式：$archive"; rm -f "$err_file"; return 1 ;;
  esac

  local rc=$?
  if [[ $rc -ne 0 ]]; then
    local err_msg; err_msg=$(cat "$err_file" 2>/dev/null || true)
    rm -f "$err_file"
    [[ -n "$err_msg" ]] && red "  解压错误：$err_msg"
    return 1
  fi
  rm -f "$err_file"
  return 0
}

# ──────────────────────────────────────────────
# 备份位置选择（核心修复：所有展示输出走 stderr）
# ──────────────────────────────────────────────
function _select_backup_root() {
  local default_dir="$HOME"
  echo ""                                                        >&2
  echo "请选择备份存储位置："                                     >&2
  echo "  1. 当前用户主目录     ($HOME)"                          >&2
  echo "  2. /tmp 目录          (重启后丢失，仅临时使用)"          >&2
  echo "  3. 手动输入目录路径"                                     >&2
  read -rp "选项 (1-3，默认 1)：" bc </dev/tty
  local backup_root=""
  case "${bc:-1}" in
    2) backup_root="/tmp" ;;
    3)
      read -rp "请输入目标目录（如 /mnt/usb / /data/backup）：" custom_dir </dev/tty
      backup_root="${custom_dir:-$default_dir}"
      ;;
    *) backup_root="$default_dir" ;;
  esac

  if ! mkdir -p "$backup_root" 2>/dev/null; then
    echo -e "\e[31m❌ 目录 $backup_root 无法创建，请检查权限。\e[0m" >&2
    return 1
  fi
  if ! touch "$backup_root/.wtest" 2>/dev/null; then
    echo -e "\e[31m❌ 目录 $backup_root 不可写，请检查权限。\e[0m" >&2
    return 1
  fi
  rm -f "$backup_root/.wtest"

  echo -e "\e[32m备份目录：$backup_root\e[0m" >&2
  echo "$backup_root"
}

function _check_disk_space() {
  local target_dir="$1"
  local min_kb="${2:-51200}"
  local avail_kb
  avail_kb=$(df -k "$target_dir" 2>/dev/null | awk 'NR==2{print $4}' || echo 999999)
  if [[ "$avail_kb" -lt "$min_kb" ]]; then
    yellow "⚠️  目标目录可用空间不足（当前：${avail_kb}KB，建议：${min_kb}KB）"
    read -rp "是否继续？(y/n，默认 n)：" sc </dev/tty
    [[ ! "${sc:-n}" =~ ^[Yy]$ ]] && return 1
  fi
  return 0
}

function _scan_backup_files() {
  local prefix="$1"
  local scan_dirs=("$HOME" "/tmp" "/mnt" "/data" "/backup")
  for d in "${scan_dirs[@]}"; do
    [[ -d "$d" ]] || continue
    find "$d" -maxdepth 3 \
      \( -name "${prefix}-*.tar.gz" \
      -o -name "${prefix}-*.tar.bz2" \
      -o -name "${prefix}-*.tar.xz" \
      -o -name "${prefix}-*.tar" \
      -o -name "${prefix}-*.zip" \) \
      2>/dev/null | sort -r
  done
}

# ──────────────────────────────────────────────
# Docker 镜像加速器管理
# ──────────────────────────────────────────────
function _get_daemon_json_path() { echo "/etc/docker/daemon.json"; }

function _read_current_mirrors() {
  local daemon_json; daemon_json=$(_get_daemon_json_path)
  [[ ! -f "$daemon_json" ]] && { echo ""; return; }
  grep -o '"registry-mirrors":\s*\[[^]]*\]' "$daemon_json" 2>/dev/null \
    | grep -o '"https://[^"]*"' | tr -d '"' || echo ""
}

function _write_mirrors_to_daemon() {
  local daemon_json; daemon_json=$(_get_daemon_json_path)
  local mirrors_json="$1"
  local write_cmd=""
  [[ "$EUID" -ne 0 ]] && command -v sudo &>/dev/null && write_cmd="sudo tee" || write_cmd="tee"
  local existing_content="{}"
  [[ -f "$daemon_json" ]] && existing_content=$(cat "$daemon_json" 2>/dev/null || echo "{}")
  if echo "$existing_content" | grep -q '"registry-mirrors"'; then
    echo "$existing_content" | \
      sed 's|"registry-mirrors":\s*\[[^]]*\]|"registry-mirrors": '"$mirrors_json"'|' \
      | $write_cmd "$daemon_json" >/dev/null
  else
    local stripped
    stripped=$(echo "$existing_content" | sed 's/^{//' | sed 's/}$//' | sed 's/^\s*//' | sed 's/\s*$//')
    if [[ -z "$stripped" || "$stripped" == $'\n' ]]; then
      printf '{\n  "registry-mirrors": %s\n}\n' "$mirrors_json" | $write_cmd "$daemon_json" >/dev/null
    else
      printf '{\n  "registry-mirrors": %s,\n%s}\n' "$mirrors_json" "$stripped" | $write_cmd "$daemon_json" >/dev/null
    fi
  fi
}

function _restart_docker_daemon() {
  yellow "重启 Docker 守护进程以应用加速器配置..."
  if command -v systemctl &>/dev/null; then
    local cmd="systemctl restart docker"
    [[ "$EUID" -ne 0 ]] && cmd="sudo $cmd"
    eval "$cmd" && green "✅ Docker 已重启。" || { red "❌ Docker 重启失败，请手动：sudo systemctl restart docker"; return 1; }
  elif [[ "$OS" == "openwrt" ]]; then
    /etc/init.d/dockerd restart && green "✅ Docker 已重启。" || red "❌ 请手动：/etc/init.d/dockerd restart"
  else
    yellow "请手动重启 Docker 服务以使配置生效。"
  fi
}

function _test_mirror_speed() {
  local mirror="$1"
  local timeout=8
  local start end elapsed
  start=$(date +%s%3N 2>/dev/null || date +%s)
  if command -v curl &>/dev/null; then
    curl -sSL --connect-timeout "$timeout" --max-time "$timeout" "${mirror}/v2/" -o /dev/null 2>/dev/null
    local rc=$?
  else
    wget -qO /dev/null --timeout="$timeout" "${mirror}/v2/" 2>/dev/null
    local rc=$?
  fi
  end=$(date +%s%3N 2>/dev/null || date +%s)
  elapsed=$(( end - start ))
  [[ $rc -eq 0 ]] && echo "${elapsed}ms" || echo "超时/不可达"
}

function configure_docker_mirror() {
  while true; do
    echo ""
    cyan "╔══════════════════════════════════════════════════════════╗"
    cyan "║  Docker 镜像加速器配置                                     ║"
    cyan "╚══════════════════════════════════════════════════════════╝"
    echo ""
    local current_mirrors; current_mirrors=$(_read_current_mirrors)
    if [[ -n "$current_mirrors" ]]; then
      green "── 当前已配置的加速器 ──────────────────────"
      echo "$current_mirrors" | while read -r m; do [[ -n "$m" ]] && echo "  ✅ $m"; done
      echo ""
    else
      yellow "── 当前未配置任何加速器 ────────────────────"
      echo ""
    fi
    echo "  1. 🚀 一键配置推荐加速器（自动测速选最快）"
    echo "  2. 📋 查看预设加速器列表并测速"
    echo "  3. ✏️  手动添加自定义加速器地址"
    echo "  4. 🗑️  清除所有加速器配置"
    echo "  5. 📄 查看当前 daemon.json 内容"
    echo "  0. 返回主菜单"
    echo ""
    read -rp "选项 (0-5)：" ch </dev/tty
    case "$ch" in
      1) _mirror_auto_setup;       press_any_key ;;
      2) _mirror_test_all;         press_any_key ;;
      3) _mirror_add_custom;       press_any_key ;;
      4) _mirror_clear_all;        press_any_key ;;
      5) _mirror_show_daemon_json; press_any_key ;;
      0) return 0 ;;
      *) red "无效选项，请输入 0-5。" ;;
    esac
  done
}

function _mirror_auto_setup() {
  echo ""
  yellow "正在测试各加速器连通性和速度，请稍候..."
  echo ""
  local best_mirror="" best_time=99999
  local mirror_results=()
  for mirror in "${DOCKER_MIRRORS[@]}"; do
    printf "  测试 %-40s ..." "$mirror"
    local result; result=$(_test_mirror_speed "$mirror")
    printf " %s\n" "$result"
    mirror_results+=("$result|$mirror")
    if [[ "$result" != "超时/不可达" ]]; then
      local ms; ms=$(echo "$result" | tr -d 'ms')
      if [[ "$ms" =~ ^[0-9]+$ ]] && [[ "$ms" -lt "$best_time" ]]; then
        best_time="$ms"; best_mirror="$mirror"
      fi
    fi
  done
  echo ""
  if [[ -z "$best_mirror" ]]; then
    red "❌ 所有预设加速器均不可达。"; return 1
  fi
  green "最快可用加速器：$best_mirror（${best_time}ms）"
  local selected_mirrors=()
  for entry in "${mirror_results[@]}"; do
    local rt="${entry%%|*}"; local url="${entry##*|}"
    [[ "$rt" != "超时/不可达" ]] && selected_mirrors+=("$url")
  done
  local mirrors_json="["; local first=true
  for m in "${selected_mirrors[@]}"; do
    [[ "$first" == true ]] && mirrors_json+="\"$m\"" || mirrors_json+=", \"$m\""
    first=false
  done
  mirrors_json+="]"
  yellow "将配置以下可用加速器："
  for m in "${selected_mirrors[@]}"; do echo "  ✅ $m"; done
  echo ""
  read -rp "确认写入并重启 Docker？(y/n，默认 y)：" cf </dev/tty
  [[ ! "${cf:-y}" =~ ^[Yy]$ ]] && { yellow "已取消。"; return 0; }
  _write_mirrors_to_daemon "$mirrors_json" || { red "❌ 写入配置失败。"; return 1; }
  green "✅ 加速器配置已写入"
  _restart_docker_daemon || return 1
  echo ""
  docker info 2>/dev/null | grep -A5 "Registry Mirrors" || true
}

function _mirror_test_all() {
  echo ""
  cyan "── 预设加速器测速结果 ──────────────────────────────"
  printf "  %-45s %s\n" "加速器地址" "延迟"
  printf "  %-45s %s\n" "─────────────────────────────────────────────" "──────────"
  for mirror in "${DOCKER_MIRRORS[@]}"; do
    printf "  %-45s" "$mirror"
    local result; result=$(_test_mirror_speed "$mirror")
    if [[ "$result" == "超时/不可达" ]]; then
      printf " \e[31m%s\e[0m\n" "$result"
    else
      printf " \e[32m%s\e[0m\n" "$result"
    fi
  done
  cyan "────────────────────────────────────────────────────"
}

function _mirror_add_custom() {
  echo ""
  yellow "请输入自定义加速器地址（多个用空格分隔，留空取消）："
  read -rp "加速器地址：" custom_input </dev/tty
  [[ -z "$custom_input" ]] && { yellow "已取消。"; return 0; }
  local new_mirrors=()
  for addr in $custom_input; do
    if [[ "$addr" =~ ^https?:// ]]; then
      new_mirrors+=("$addr"); green "  ✅ 添加：$addr"
    else
      yellow "  ⚠️  格式不正确，跳过：$addr"
    fi
  done
  [[ ${#new_mirrors[@]} -eq 0 ]] && { red "无有效地址，取消。"; return 1; }
  local existing=()
  while IFS= read -r m; do [[ -n "$m" ]] && existing+=("$m"); done < <(_read_current_mirrors)
  local all_mirrors=("${existing[@]}" "${new_mirrors[@]}")
  local seen=(); local unique_mirrors=()
  for m in "${all_mirrors[@]}"; do
    local dup=false
    for s in "${seen[@]:-}"; do [[ "$s" == "$m" ]] && dup=true && break; done
    [[ "$dup" == false ]] && unique_mirrors+=("$m") && seen+=("$m")
  done
  local mirrors_json="["; local first=true
  for m in "${unique_mirrors[@]}"; do
    [[ "$first" == true ]] && mirrors_json+="\"$m\"" || mirrors_json+=", \"$m\""
    first=false
  done
  mirrors_json+="]"
  _write_mirrors_to_daemon "$mirrors_json" || { red "❌ 写入配置失败。"; return 1; }
  green "✅ 自定义加速器已添加"
  _restart_docker_daemon || return 1
}

function _mirror_clear_all() {
  echo ""
  red "⚠️  将清除所有镜像加速器配置！"
  read -rp "确认清除？(y/n，默认 n)：" cf </dev/tty
  [[ ! "${cf:-n}" =~ ^[Yy]$ ]] && { yellow "已取消。"; return 0; }
  _write_mirrors_to_daemon "[]" || { red "❌ 写入配置失败。"; return 1; }
  green "✅ 加速器已清除"
  _restart_docker_daemon || return 1
}

function _mirror_show_daemon_json() {
  local daemon_json; daemon_json=$(_get_daemon_json_path)
  echo ""
  cyan "── /etc/docker/daemon.json 内容 ────────────────────"
  if [[ -f "$daemon_json" ]]; then cat "$daemon_json"; else yellow "文件不存在"; fi
  cyan "────────────────────────────────────────────────────"
}

# ──────────────────────────────────────────────
# FreeLLMAPI 数据卷操作（四级降级策略）
# ──────────────────────────────────────────────
function _copy_volume_to_dir() {
  local volume_name="$1"
  local dest_dir="$2"
  mkdir -p "$dest_dir"

  yellow "  [策略1] 直接读取卷挂载路径（无需网络/镜像）..."
  local vol_path
  vol_path=$(docker volume inspect "$volume_name" --format '{{.Mountpoint}}' 2>/dev/null || echo "")
  if [[ -n "$vol_path" && -d "$vol_path" ]]; then
    local copy_ok=false
    if [[ "$EUID" -eq 0 ]]; then
      cp -a "$vol_path/." "$dest_dir/" 2>/dev/null && copy_ok=true
    elif command -v sudo &>/dev/null; then
      sudo cp -a "$vol_path/." "$dest_dir/" 2>/dev/null && \
        sudo chown -R "$(id -u):$(id -g)" "$dest_dir" 2>/dev/null && copy_ok=true || true
    fi
    if [[ "$copy_ok" == true ]]; then
      local fc; fc=$(find "$dest_dir" -type f 2>/dev/null | wc -l || echo 0)
      green "  ✅ 策略1 成功（$fc 个文件）"; return 0
    fi
    yellow "  ⚠️  策略1 失败，尝试下一策略..."
  else
    yellow "  ⚠️  策略1 失败（路径不可访问），尝试下一策略..."
  fi

  yellow "  [策略2] 检测本地可用的轻量镜像..."
  local helper_img=""
  for candidate in "alpine:latest" "alpine" "busybox:latest" "busybox"; do
    docker image inspect "$candidate" &>/dev/null 2>&1 && { helper_img="$candidate"; break; }
  done
  if [[ -n "$helper_img" ]]; then
    if docker run --rm \
      -v "${volume_name}:/source:ro" \
      -v "${dest_dir}:/backup" \
      "$helper_img" sh -c "cp -a /source/. /backup/" 2>/dev/null; then
      local fc; fc=$(find "$dest_dir" -type f 2>/dev/null | wc -l || echo 0)
      [[ "$fc" -gt 0 ]] && { green "  ✅ 策略2 成功（$fc 个文件）"; return 0; }
    fi
    yellow "  ⚠️  策略2 失败，尝试下一策略..."
  fi

  yellow "  [策略3] tar 流式导出卷内容..."
  local tar_out="$dest_dir/_volume_export.tar"
  if docker run --rm -v "${volume_name}:/source:ro" busybox sh -c "tar cf - -C /source ." > "$tar_out" 2>/dev/null \
    || docker run --rm -v "${volume_name}:/source:ro" alpine sh -c "tar cf - -C /source ." > "$tar_out" 2>/dev/null; then
    local fsz; fsz=$(stat -c%s "$tar_out" 2>/dev/null || echo 0)
    if [[ -f "$tar_out" && "$fsz" -gt 10 ]]; then
      tar -xf "$tar_out" -C "$dest_dir" 2>/dev/null && rm -f "$tar_out"
      green "  ✅ 策略3 成功"; return 0
    fi
  fi
  rm -f "$tar_out" 2>/dev/null || true

  yellow "  [策略4] 尝试拉取 alpine 镜像（需要网络）..."
  yellow "  提示：若拉取缓慢，可按 Ctrl+C 中断后配置加速器再重试。"
  if docker pull alpine:latest 2>/dev/null; then
    if docker run --rm \
      -v "${volume_name}:/source:ro" \
      -v "${dest_dir}:/backup" \
      alpine sh -c "cp -a /source/. /backup/" 2>/dev/null; then
      green "  ✅ 策略4 成功"; return 0
    fi
  fi

  red "  ❌ 所有备份策略均失败！"
  red "  建议：通过主菜单选项10配置 Docker 加速器后重试。"
  return 1
}

function _copy_dir_to_volume() {
  local src_dir="$1"
  local volume_name="$2"

  yellow "  [策略1] 直接写入卷挂载路径..."
  local vol_path
  vol_path=$(docker volume inspect "$volume_name" --format '{{.Mountpoint}}' 2>/dev/null || echo "")
  if [[ -n "$vol_path" && -d "$vol_path" ]]; then
    local copy_ok=false
    if [[ "$EUID" -eq 0 ]]; then
      cp -a "$src_dir/." "$vol_path/" 2>/dev/null && copy_ok=true
    elif command -v sudo &>/dev/null; then
      sudo cp -a "$src_dir/." "$vol_path/" 2>/dev/null && copy_ok=true
    fi
    [[ "$copy_ok" == true ]] && { green "  ✅ 策略1 成功"; return 0; }
    yellow "  ⚠️  策略1 失败，尝试下一策略..."
  fi

  yellow "  [策略2] 检测本地可用的轻量镜像..."
  local helper_img=""
  for candidate in "alpine:latest" "alpine" "busybox:latest" "busybox"; do
    docker image inspect "$candidate" &>/dev/null 2>&1 && { helper_img="$candidate"; break; }
  done
  if [[ -n "$helper_img" ]]; then
    docker run --rm \
      -v "${volume_name}:/target" \
      -v "${src_dir}:/source:ro" \
      "$helper_img" sh -c "rm -rf /target/* && cp -a /source/. /target/" 2>/dev/null \
      && { green "  ✅ 策略2 成功"; return 0; }
    yellow "  ⚠️  策略2 失败，尝试下一策略..."
  fi

  yellow "  [策略3] 尝试拉取 alpine 镜像..."
  yellow "  提示：若拉取缓慢，按 Ctrl+C 后通过主菜单选项10配置加速器重试。"
  if docker pull alpine:latest 2>/dev/null; then
    docker run --rm \
      -v "${volume_name}:/target" \
      -v "${src_dir}:/source:ro" \
      alpine sh -c "rm -rf /target/* && cp -a /source/. /target/" 2>/dev/null \
      && { green "  ✅ 策略3 成功"; return 0; }
  fi

  red "  ❌ 所有恢复策略均失败！"; return 1
}

function _fetch_versions_github() {
  local repo="$1"; local limit="${2:-8}"
  local resp=""
  command -v curl &>/dev/null \
    && resp=$(curl -sSL --connect-timeout 10 "https://api.github.com/repos/${repo}/releases?per_page=20" 2>/dev/null || true) \
    || resp=$(wget -qO- --timeout=10 "https://api.github.com/repos/${repo}/releases?per_page=20" 2>/dev/null || true)
  [[ -z "$resp" ]] && return 1
  echo "$resp" | grep '"tag_name"' | cut -d'"' -f4 | head -n"$limit"
}

function _fetch_versions_dockerhub() {
  local repo="$1"; local limit="${2:-8}"
  local resp=""
  command -v curl &>/dev/null \
    && resp=$(curl -sSL --connect-timeout 10 "https://hub.docker.com/v2/repositories/${repo}/tags?page_size=50&ordering=last_updated" 2>/dev/null || true) \
    || resp=$(wget -qO- --timeout=10 "https://hub.docker.com/v2/repositories/${repo}/tags?page_size=50&ordering=last_updated" 2>/dev/null || true)
  [[ -z "$resp" ]] && return 1
  echo "$resp" | grep -o '"name":"[^"]*"' | cut -d'"' -f4 | grep -E '^v[0-9]' | head -n"$limit"
}

function select_image_version() {
  local svc_name="$1"; local img_base="$2"; local fetch_type="$3"
  local fetch_src="$4"; local limit="${5:-8}"
  SELECTED_IMAGE="${img_base}:latest"
  yellow "正在获取 ${svc_name} 最近 ${limit} 个版本，请稍候..."

  local versions=(); local fetch_ok=false
  if [[ "$fetch_type" == "github" ]]; then
    mapfile -t versions < <(_fetch_versions_github "$fetch_src" "$limit" 2>/dev/null) && fetch_ok=true
  elif [[ "$fetch_type" == "dockerhub" ]]; then
    mapfile -t versions < <(_fetch_versions_dockerhub "$fetch_src" "$limit" 2>/dev/null) && fetch_ok=true
  fi

  local clean_versions=()
  for v in "${versions[@]:-}"; do [[ -n "$v" ]] && clean_versions+=("$v"); done
  versions=("${clean_versions[@]:-}")

  echo ""
  cyan "┌──────────────────────────────────────────────────────────┐"
  cyan "│  请选择 ${svc_name} 版本                                    │"
  cyan "│  · latest = 始终拉取最新  · 指定版本 = 生产环境推荐         │"
  cyan "└──────────────────────────────────────────────────────────┘"
  echo "  1. latest（自动跟随最新）"
  local i=2
  if [[ ${#versions[@]} -gt 0 ]]; then
    for v in "${versions[@]}"; do
      local tag_label=""; [[ "$i" -eq 2 ]] && tag_label="  ← 当前最新 Release"
      printf "  %d. %-20s%s\n" "$i" "$v" "$tag_label"
      ((i++))
    done
  fi
  local manual_idx=$i
  printf "  %d. 手动输入版本号\n" "$manual_idx"
  echo ""
  [[ "$fetch_ok" == false || ${#versions[@]} -eq 0 ]] && yellow "（网络不可达，仅可选 latest 或手动输入）"

  read -rp "请输入版本编号（留空使用 latest）：" vc </dev/tty
  if [[ -z "$vc" || "$vc" == "1" ]]; then
    SELECTED_IMAGE="${img_base}:latest"
  elif [[ "$vc" =~ ^[0-9]+$ ]] && [[ "$vc" -ge 2 && "$vc" -lt "$manual_idx" ]]; then
    local idx=$(( vc - 2 ))
    SELECTED_IMAGE="${img_base}:${versions[$idx]}"
  elif [[ "$vc" == "$manual_idx" ]]; then
    read -rp "请输入版本号（如 v0.6.11）：" mv </dev/tty
    SELECTED_IMAGE="${img_base}:${mv:-latest}"
  else
    yellow "无效选项，使用 latest。"
    SELECTED_IMAGE="${img_base}:latest"
  fi
  green "已选择版本：$SELECTED_IMAGE"
}

function _prompt_backup_before_action() {
  local action_desc="${1:-此操作}"
  echo ""
  yellow "┌──────────────────────────────────────────────────────────┐"
  yellow "│  ⚠️  建议在${action_desc}前先完成备份                       │"
  yellow "│  备份入口：主菜单 → 选项9（备份/恢复）                      │"
  yellow "└──────────────────────────────────────────────────────────┘"
  read -rp "是否继续${action_desc}？(y/n，默认 y)：" pc </dev/tty
  [[ ! "${pc:-y}" =~ ^[Yy]$ ]] && { yellow "已取消，请先完成备份。"; return 1; }
  return 0
}

# ──────────────────────────────────────────────
# 通用绑定挂载服务备份/恢复（One-API / New-API）
# ──────────────────────────────────────────────
function _backup_bind_service() {
  local svc_label="$1"
  local container_name="$2"
  local data_dir="$3"
  local backup_prefix="$4"

  echo ""
  cyan "╔══════════════════════════════════════════════════════════╗"
  cyan "║  备份 ${svc_label}"
  cyan "╚══════════════════════════════════════════════════════════╝"
  echo ""

  if [[ ! -d "$data_dir" ]]; then
    red "❌ 数据目录不存在：$data_dir"
    red "   请确认 ${svc_label} 已正确部署并产生过数据。"
    return 1
  fi

  local file_count
  file_count=$(find "$data_dir" -type f 2>/dev/null | wc -l || echo 0)
  green "数据目录：$data_dir（共 $file_count 个文件）"

  local pack_type; pack_type=$(_check_pack_tools)
  if [[ "$pack_type" == "none" ]]; then
    red "❌ 未找到任何打包工具，无法生成备份文件！"; return 1
  fi
  green "打包格式：$pack_type"

  local backup_root
  backup_root=$(_select_backup_root) || return 1

  _check_disk_space "$backup_root" 51200 || return 1

  local stamp; stamp=$(date +%Y%m%d_%H%M%S)
  local backup_name="${backup_prefix}-${stamp}"
  local backup_tmp="${backup_root}/${backup_name}"
  local backup_archive="${backup_root}/${backup_name}.${pack_type}"

  mkdir -p "$backup_tmp"

  yellow "[1/3] 暂停容器以确保数据一致性..."
  local was_running=false
  if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
    was_running=true
    docker stop "$container_name" &>/dev/null || true
    green "  ✅ 容器已暂停"
  else
    yellow "  容器未运行，直接备份"
  fi

  yellow "[2/3] 复制数据目录..."
  mkdir -p "$backup_tmp/data"
  if cp -a "$data_dir/." "$backup_tmp/data/" 2>/dev/null; then
    local copied
    copied=$(find "$backup_tmp/data" -type f 2>/dev/null | wc -l || echo 0)
    green "  ✅ 数据复制完成（$copied 个文件）"
  else
    red "  ❌ 数据复制失败"
    [[ "$was_running" == true ]] && docker start "$container_name" &>/dev/null || true
    rm -rf "$backup_tmp"
    return 1
  fi

  local cur_image=""
  cur_image=$(docker inspect "$container_name" --format '{{.Config.Image}}' 2>/dev/null || echo "未知")
  cat > "$backup_tmp/backup_info.txt" << EOF
服务名称：${svc_label}
容器名称：${container_name}
备份时间：$(date '+%Y-%m-%d %H:%M:%S')
主机名：$(hostname)
系统：${OS} / ${ARCH}
镜像版本：${cur_image}
数据目录：${data_dir}
打包格式：${pack_type}
恢复工具：部署脚本 → 选项9 → 备份/恢复
EOF

  if [[ "$was_running" == true ]]; then
    yellow "  重新启动容器..."
    docker start "$container_name" &>/dev/null \
      && green "  ✅ 容器已恢复运行" \
      || yellow "  ⚠️  请手动启动：docker start $container_name"
  fi

  yellow "[3/3] 打包压缩（格式：$pack_type）..."
  yellow "  正在打包：$backup_archive"

  if _do_pack "$backup_root" "$backup_name" "$backup_archive" "$pack_type"; then
    rm -rf "$backup_tmp"
    local size; size=$(du -sh "$backup_archive" 2>/dev/null | cut -f1 || echo "未知")
    echo ""
    green "╔══════════════════════════════════════════════════════════╗"
    green "║  ✅  ${svc_label} 备份完成！"
    green "╠══════════════════════════════════════════════════════════╣"
    green "║  备份文件：${backup_archive}"
    green "║  文件大小：${size}"
    green "║  打包格式：${pack_type}"
    green "╠══════════════════════════════════════════════════════════╣"
    yellow "║  ⚠️  请将此文件复制到安全位置（U盘/NAS/云盘）              ║"
    green  "╚══════════════════════════════════════════════════════════╝"
  else
    red "❌ 打包失败！临时目录保留在：$backup_tmp"
    red "手动修复：tar -czf ${backup_archive} -C ${backup_root} ${backup_name}"
    return 1
  fi
}

function _restore_bind_service() {
  local svc_label="$1"
  local container_name="$2"
  local data_dir="$3"
  local backup_prefix="$4"

  echo ""
  cyan "╔══════════════════════════════════════════════════════════╗"
  cyan "║  恢复 ${svc_label}"
  cyan "╚══════════════════════════════════════════════════════════╝"
  echo ""

  echo "请选择备份文件来源："
  echo "  1. 手动输入备份文件完整路径"
  echo "  2. 扫描常用目录自动列出备份文件"
  read -rp "选项 (1-2，默认 2)：" sc </dev/tty

  local backup_archive=""
  case "${sc:-2}" in
    1)
      read -rp "请输入备份文件路径：" backup_archive </dev/tty
      ;;
    *)
      echo ""
      yellow "正在扫描备份文件..."
      local found_files=()
      while IFS= read -r f; do
        found_files+=("$f")
      done < <(_scan_backup_files "$backup_prefix")

      if [[ ${#found_files[@]} -eq 0 ]]; then
        yellow "未找到备份文件。"
        read -rp "请手动输入备份文件路径：" backup_archive </dev/tty
      else
        echo ""
        local i=1
        for f in "${found_files[@]}"; do
          local sz; sz=$(du -sh "$f" 2>/dev/null | cut -f1 || echo "?")
          local ts; ts=$(echo "$f" | grep -oE '[0-9]{8}_[0-9]{6}' | \
            sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)_\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3 \4:\5:\6/' || echo "")
          printf "  %d. %-55s  [%s]  %s\n" "$i" "$f" "$sz" "$ts"
          ((i++))
        done
        echo ""
        read -rp "请输入编号选择（留空手动输入路径）：" fc </dev/tty
        if [[ -z "$fc" ]]; then
          read -rp "请输入备份文件路径：" backup_archive </dev/tty
        elif [[ "$fc" =~ ^[0-9]+$ ]] && [[ "$fc" -ge 1 && "$fc" -le ${#found_files[@]} ]]; then
          backup_archive="${found_files[$((fc-1))]}"
        else
          red "无效选项。"; return 1
        fi
      fi
      ;;
  esac

  if [[ -z "$backup_archive" || ! -f "$backup_archive" ]]; then
    red "❌ 备份文件不存在：$backup_archive"; return 1
  fi
  green "使用备份文件：$backup_archive"

  local restore_tmp="/tmp/${backup_prefix}_restore_$$"
  mkdir -p "$restore_tmp"

  yellow "[1/4] 解压备份文件..."
  if ! _do_unpack "$backup_archive" "$restore_tmp"; then
    red "❌ 解压失败，文件可能已损坏。"; rm -rf "$restore_tmp"; return 1
  fi

  local restore_info
  restore_info=$(find "$restore_tmp" -maxdepth 3 -name "backup_info.txt" | head -n1)
  if [[ -z "$restore_info" ]]; then
    red "❌ 备份包格式不正确，未找到 backup_info.txt！"
    rm -rf "$restore_tmp"; return 1
  fi
  local restore_base; restore_base=$(dirname "$restore_info")

  if [[ -f "$restore_base/backup_info.txt" ]]; then
    echo ""
    cyan "── 备份信息 ────────────────────────────────"
    cat "$restore_base/backup_info.txt"
    cyan "────────────────────────────────────────────"
    echo ""
  fi

  if [[ ! -d "$restore_base/data" ]]; then
    red "❌ 备份包中无 data 目录，备份可能不完整！"
    rm -rf "$restore_tmp"; return 1
  fi

  yellow "[2/4] 停止现有容器..."
  if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
    docker stop "$container_name" &>/dev/null || true
    green "  ✅ 容器已停止"
  else
    yellow "  容器未运行，跳过"
  fi

  yellow "[3/4] 恢复数据目录..."
  if [[ -d "$data_dir" ]]; then
    local bak_old="${data_dir}_old_$(date +%Y%m%d_%H%M%S)"
    yellow "  当前数据目录已存在，备份为：$bak_old"
    mv "$data_dir" "$bak_old" 2>/dev/null || { red "  ❌ 无法移动旧数据目录"; rm -rf "$restore_tmp"; return 1; }
    green "  ✅ 旧数据目录已保留：$bak_old"
  fi

  mkdir -p "$data_dir"
  if cp -a "$restore_base/data/." "$data_dir/" 2>/dev/null; then
    local fc; fc=$(find "$data_dir" -type f 2>/dev/null | wc -l || echo 0)
    green "  ✅ 数据恢复完成（$fc 个文件）"
  else
    red "  ❌ 数据恢复失败"; rm -rf "$restore_tmp"; return 1
  fi

  rm -rf "$restore_tmp"

  yellow "[4/4] 启动容器..."
  if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
    docker start "$container_name" &>/dev/null \
      && green "  ✅ 容器已启动" \
      || red "  ❌ 请手动：docker start $container_name"
  else
    yellow "  容器不存在，请通过主菜单重新部署（数据目录已恢复）。"
  fi

  echo ""
  green "╔══════════════════════════════════════════════════════════╗"
  green "║  ✅  ${svc_label} 恢复完成！"
  green "╚══════════════════════════════════════════════════════════╝"
}

function _list_bind_service_backups() {
  local svc_label="$1"
  local backup_prefix="$2"
  echo ""
  cyan "── ${svc_label} 备份文件列表 ─────────────────────────────"
  local found=false
  while IFS= read -r f; do
    local sz; sz=$(du -sh "$f" 2>/dev/null | cut -f1 || echo "?")
    local ts; ts=$(echo "$f" | grep -oE '[0-9]{8}_[0-9]{6}' | \
      sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)_\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3 \4:\5:\6/' || echo "")
    printf "  📦 %-50s  [%s]  %s\n" "$f" "$sz" "$ts"
    found=true
  done < <(_scan_backup_files "$backup_prefix")
  [[ "$found" == false ]] && yellow "  未找到任何备份文件。"
  cyan "────────────────────────────────────────────────────"
}

function general_backup_menu() {
  while true; do
    echo ""
    cyan "╔══════════════════════════════════════════════════════════╗"
    cyan "║  One-API / New-API 备份 / 恢复                            ║"
    cyan "╠══════════════════════════════════════════════════════════╣"
    cyan "║  数据存储方式：绑定挂载目录（~/xxx-data）                   ║"
    cyan "║  MySQL 模式：数据库需另行使用 mysqldump 备份                ║"
    cyan "╚══════════════════════════════════════════════════════════╝"
    echo ""

    local oneapi_sqlite_status="未部署"
    local oneapi_mysql_status="未部署"
    local newapi_status="未部署"
    docker ps -a --format '{{.Names}}' | grep -q "^one-api$"       && oneapi_sqlite_status="已部署"
    docker ps -a --format '{{.Names}}' | grep -q "^one-api-mysql$" && oneapi_mysql_status="已部署"
    docker ps -a --format '{{.Names}}' | grep -q "^new-api$"       && newapi_status="已部署"
    [[ -d "$HOME/one-api-data" ]]       && oneapi_sqlite_status+=" [数据目录存在]"
    [[ -d "$HOME/one-api-mysql-logs" ]] && oneapi_mysql_status+=" [日志目录存在]"
    [[ -d "$HOME/new-api-data" ]]       && newapi_status+=" [数据目录存在]"

    echo "  ── One-API SQLite  [$oneapi_sqlite_status]"
    echo "  1. 📦 备份 One-API SQLite 数据"
    echo "  2. 📂 恢复 One-API SQLite 数据"
    echo "  3. 🔍 查看 One-API SQLite 备份列表"
    echo ""
    echo "  ── One-API MySQL   [$oneapi_mysql_status]"
    echo "  4. 📦 备份 One-API MySQL 日志目录"
    echo "  5. 📂 恢复 One-API MySQL 日志目录"
    echo "  6. 🔍 查看 One-API MySQL 备份列表"
    echo "  ℹ️  MySQL 数据库本身请使用：mysqldump -u用户 -p 数据库名 > backup.sql"
    echo ""
    echo "  ── New-API         [$newapi_status]"
    echo "  7. 📦 备份 New-API 数据"
    echo "  8. 📂 恢复 New-API 数据"
    echo "  9. 🔍 查看 New-API 备份列表"
    echo ""
    echo "  0. 返回主菜单"
    echo ""
    read -rp "选项 (0-9)：" ch </dev/tty

    case "$ch" in
      1) _backup_bind_service  "One-API SQLite"    "one-api"       "$HOME/one-api-data"       "oneapi-sqlite-backup" || true; press_any_key ;;
      2) _restore_bind_service "One-API SQLite"    "one-api"       "$HOME/one-api-data"       "oneapi-sqlite-backup" || true; press_any_key ;;
      3) _list_bind_service_backups "One-API SQLite" "oneapi-sqlite-backup"; press_any_key ;;
      4) _backup_bind_service  "One-API MySQL 日志" "one-api-mysql" "$HOME/one-api-mysql-logs" "oneapi-mysql-backup"  || true; press_any_key ;;
      5) _restore_bind_service "One-API MySQL 日志" "one-api-mysql" "$HOME/one-api-mysql-logs" "oneapi-mysql-backup"  || true; press_any_key ;;
      6) _list_bind_service_backups "One-API MySQL 日志" "oneapi-mysql-backup"; press_any_key ;;
      7) _backup_bind_service  "New-API"           "new-api"       "$HOME/new-api-data"       "newapi-backup"        || true; press_any_key ;;
      8) _restore_bind_service "New-API"           "new-api"       "$HOME/new-api-data"       "newapi-backup"        || true; press_any_key ;;
      9) _list_bind_service_backups "New-API" "newapi-backup"; press_any_key ;;
      0) return 0 ;;
      *) red "无效选项，请输入 0-9。" ;;
    esac
  done
}

# ──────────────────────────────────────────────
# FreeLLMAPI 备份/恢复
# ──────────────────────────────────────────────
function freellmapi_backup() {
  local key_file="$HOME/.freellmapi_encryption_key"
  local compose_dir="$FREELLMAPI_COMPOSE_DIR"

  echo ""
  cyan "╔══════════════════════════════════════════════════════════╗"
  cyan "║  FreeLLMAPI 数据备份                                       ║"
  cyan "╚══════════════════════════════════════════════════════════╝"
  echo ""

  if [[ ! -f "$key_file" ]]; then
    red "❌ 未找到 ENCRYPTION_KEY（$key_file），备份中止！"; return 1
  fi

  local pack_type; pack_type=$(_check_pack_tools)
  if [[ "$pack_type" == "none" ]]; then
    red "❌ 未找到任何打包工具，无法生成备份文件！"; return 1
  fi
  green "打包格式：$pack_type"

  local backup_root
  backup_root=$(_select_backup_root) || return 1
  _check_disk_space "$backup_root" 51200 || return 1

  local stamp; stamp=$(date +%Y%m%d_%H%M%S)
  local backup_name="freellmapi-backup-${stamp}"
  local backup_tmp="${backup_root}/${backup_name}"
  local backup_archive="${backup_root}/${backup_name}.${pack_type}"

  mkdir -p "$backup_tmp"

  yellow "[1/4] 备份 ENCRYPTION_KEY..."
  if ! cp "$key_file" "$backup_tmp/.freellmapi_encryption_key"; then
    red "  ❌ ENCRYPTION_KEY 复制失败"; rm -rf "$backup_tmp"; return 1
  fi
  chmod 600 "$backup_tmp/.freellmapi_encryption_key"
  green "  ✅ ENCRYPTION_KEY 已备份"

  yellow "[2/4] 备份配置文件..."
  local conf_ok=false
  if [[ -f "$compose_dir/.env" ]]; then
    cp "$compose_dir/.env" "$backup_tmp/env_config" && green "  ✅ .env 已备份（重命名为 env_config）" || true
    conf_ok=true
  fi
  if [[ -f "$compose_dir/docker-compose.yml" ]]; then
    cp "$compose_dir/docker-compose.yml" "$backup_tmp/docker-compose.yml" && green "  ✅ docker-compose.yml 已备份" || true
    conf_ok=true
  fi
  [[ "$conf_ok" == false ]] && yellow "  ⚠️  未找到配置文件，跳过"

  yellow "[3/4] 备份 SQLite 数据卷..."
  if ! docker volume inspect freellmapi-data &>/dev/null; then
    yellow "  ⚠️  未找到 freellmapi-data 数据卷，跳过。"
  else
    local was_running=false
    docker ps --format '{{.Names}}' | grep -q "^freellmapi$" && was_running=true
    if [[ "$was_running" == true ]]; then
      yellow "  暂停容器以确保数据一致性..."
      docker stop freellmapi &>/dev/null || true
    fi
    mkdir -p "$backup_tmp/data"
    if ! _copy_volume_to_dir "freellmapi-data" "$backup_tmp/data"; then
      red "  ❌ 数据卷备份失败"
      [[ "$was_running" == true ]] && docker start freellmapi &>/dev/null || true
      rm -rf "$backup_tmp"; return 1
    fi
    if [[ "$was_running" == true ]]; then
      yellow "  重新启动容器..."
      if [[ -f "$compose_dir/docker-compose.yml" ]]; then
        cd "$compose_dir" && docker compose up -d &>/dev/null && cd - >/dev/null || true
      else
        docker start freellmapi &>/dev/null || true
      fi
      green "  ✅ 容器已恢复运行"
    fi
  fi

  yellow "[4/4] 打包压缩（格式：$pack_type）..."
  local cur_image=""
  cur_image=$(docker inspect freellmapi --format '{{.Config.Image}}' 2>/dev/null || echo "未知")
  cat > "$backup_tmp/backup_info.txt" << EOF
服务名称：FreeLLMAPI
备份时间：$(date '+%Y-%m-%d %H:%M:%S')
主机名：$(hostname)
系统：${OS} / ${ARCH}
镜像版本：${cur_image}
打包格式：${pack_type}
Docker卷：freellmapi-data
KEY文件：.freellmapi_encryption_key
恢复工具：部署脚本 → 选项9 → 恢复备份
EOF

  yellow "  正在打包：$backup_archive"
  if _do_pack "$backup_root" "$backup_name" "$backup_archive" "$pack_type"; then
    rm -rf "$backup_tmp"
    local size; size=$(du -sh "$backup_archive" 2>/dev/null | cut -f1 || echo "未知")
    echo ""
    green "╔══════════════════════════════════════════════════════════╗"
    green "║  ✅  FreeLLMAPI 备份完成！                                  ║"
    green "╠══════════════════════════════════════════════════════════╣"
    green "║  备份文件：${backup_archive}"
    green "║  文件大小：${size}"
    green "║  打包格式：${pack_type}"
    green "╠══════════════════════════════════════════════════════════╣"
    yellow "║  ⚠️  请将此文件复制到安全位置（U盘/NAS/云盘）              ║"
    green  "╚══════════════════════════════════════════════════════════╝"
  else
    red "❌ 打包失败！临时目录保留在：$backup_tmp"
    red "手动修复：tar -czf ${backup_archive} -C ${backup_root} ${backup_name}"
    return 1
  fi
}

function freellmapi_restore() {
  local key_file="$HOME/.freellmapi_encryption_key"
  local compose_dir="$FREELLMAPI_COMPOSE_DIR"

  echo ""
  cyan "╔══════════════════════════════════════════════════════════╗"
  cyan "║  FreeLLMAPI 数据恢复                                       ║"
  cyan "╚══════════════════════════════════════════════════════════╝"
  echo ""

  if docker ps -a --format '{{.Names}}' | grep -q "^freellmapi$"; then
    yellow "⚠️  检测到 freellmapi 容器已存在，恢复将覆盖现有数据！"
    read -rp "确认继续？(y/n，默认 n)：" cc </dev/tty
    [[ ! "${cc:-n}" =~ ^[Yy]$ ]] && { yellow "已取消。"; return 0; }
    yellow "停止并移除现有容器..."
    if [[ -f "$compose_dir/docker-compose.yml" ]]; then
      cd "$compose_dir" && docker compose down 2>/dev/null || true && cd - >/dev/null
    fi
    docker stop freellmapi &>/dev/null || true
    docker rm   freellmapi &>/dev/null || true
    green "✅ 现有容器已清理"
  fi

  echo ""
  echo "请选择备份文件来源："
  echo "  1. 手动输入备份文件完整路径"
  echo "  2. 扫描常用目录自动列出备份文件"
  read -rp "选项 (1-2，默认 2)：" sc </dev/tty

  local backup_archive=""
  case "${sc:-2}" in
    1) read -rp "请输入备份文件路径：" backup_archive </dev/tty ;;
    *)
      echo ""
      yellow "正在扫描备份文件..."
      local found_files=()
      while IFS= read -r f; do found_files+=("$f"); done < <(_scan_backup_files "freellmapi-backup")
      if [[ ${#found_files[@]} -eq 0 ]]; then
        yellow "未找到备份文件。"
        read -rp "请手动输入备份文件路径：" backup_archive </dev/tty
      else
        echo ""
        local i=1
        for f in "${found_files[@]}"; do
          local sz; sz=$(du -sh "$f" 2>/dev/null | cut -f1 || echo "?")
          local ts; ts=$(echo "$f" | grep -oE '[0-9]{8}_[0-9]{6}' | \
            sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)_\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3 \4:\5:\6/' || echo "")
          printf "  %d. %-55s  [%s]  %s\n" "$i" "$f" "$sz" "$ts"
          ((i++))
        done
        echo ""
        read -rp "请输入编号选择（留空手动输入路径）：" fc </dev/tty
        if [[ -z "$fc" ]]; then
          read -rp "请输入备份文件路径：" backup_archive </dev/tty
        elif [[ "$fc" =~ ^[0-9]+$ ]] && [[ "$fc" -ge 1 && "$fc" -le ${#found_files[@]} ]]; then
          backup_archive="${found_files[$((fc-1))]}"
        else
          red "无效选项。"; return 1
        fi
      fi
      ;;
  esac

  if [[ -z "$backup_archive" || ! -f "$backup_archive" ]]; then
    red "❌ 备份文件不存在：$backup_archive"; return 1
  fi
  green "使用备份文件：$backup_archive"

  local restore_tmp="/tmp/freellmapi_restore_$$"
  mkdir -p "$restore_tmp"

  yellow "[1/5] 解压备份文件..."
  if ! _do_unpack "$backup_archive" "$restore_tmp"; then
    red "❌ 解压失败，文件可能已损坏。"; rm -rf "$restore_tmp"; return 1
  fi

  local restore_inner
  restore_inner=$(find "$restore_tmp" -maxdepth 2 -name ".freellmapi_encryption_key" | head -n1)
  if [[ -z "$restore_inner" ]]; then
    red "❌ 备份中未找到 ENCRYPTION_KEY，备份包不完整！"
    rm -rf "$restore_tmp"; return 1
  fi
  local restore_base; restore_base=$(dirname "$restore_inner")
  green "  ✅ 解压成功"

  local bak_image=""
  if [[ -f "$restore_base/backup_info.txt" ]]; then
    echo ""
    cyan "── 备份信息 ────────────────────────────────"
    cat "$restore_base/backup_info.txt"
    cyan "────────────────────────────────────────────"
    echo ""
    bak_image=$(grep "^镜像版本：" "$restore_base/backup_info.txt" | cut -d'：' -f2 || true)
    if [[ -n "$bak_image" ]]; then
      read -rp "恢复后是否使用备份版本启动？(y=使用备份版本 / n=重新选择)  [默认 y]：" use_bak_ver </dev/tty
      if [[ ! "${use_bak_ver:-y}" =~ ^[Yy]$ ]]; then
        select_image_version "FreeLLMAPI" "$FREELLMAPI_IMAGE_BASE" "github" "tashfeenahmed/freellmapi" 8
        bak_image="$SELECTED_IMAGE"
      fi
    fi
  fi

  yellow "[2/5] 恢复 ENCRYPTION_KEY..."
  if [[ -f "$key_file" ]]; then
    read -rp "  当前已有 KEY，确认覆盖？(y/n，默认 y)：" ok </dev/tty
    [[ ! "${ok:-y}" =~ ^[Yy]$ ]] && { yellow "已取消恢复。"; rm -rf "$restore_tmp"; return 0; }
  fi
  cp "$restore_base/.freellmapi_encryption_key" "$key_file"
  chmod 600 "$key_file"
  green "  ✅ ENCRYPTION_KEY 已恢复"

  yellow "[3/5] 恢复配置文件..."
  mkdir -p "$compose_dir"
  if [[ -f "$restore_base/env_config" ]]; then
    cp "$restore_base/env_config" "$compose_dir/.env"
    chmod 600 "$compose_dir/.env"
    green "  ✅ .env 已恢复"
  fi
  if [[ -f "$restore_base/docker-compose.yml" ]]; then
    cp "$restore_base/docker-compose.yml" "$compose_dir/docker-compose.yml"
    [[ -n "$bak_image" ]] && \
      sed -i "s|image:.*freellmapi.*|image: ${bak_image}|" "$compose_dir/docker-compose.yml" || true
    green "  ✅ docker-compose.yml 已恢复"
  fi

  yellow "[4/5] 恢复 SQLite 数据卷..."
  if [[ ! -d "$restore_base/data" ]]; then
    yellow "  ⚠️  备份中无数据卷内容，跳过"
  else
    docker volume inspect freellmapi-data &>/dev/null \
      && yellow "  发现已有数据卷，将覆盖..." \
      || docker volume create freellmapi-data &>/dev/null
    if ! _copy_dir_to_volume "$restore_base/data" "freellmapi-data"; then
      red "  ❌ 数据卷恢复失败"; rm -rf "$restore_tmp"; return 1
    fi
    green "  ✅ 数据卷已恢复"
  fi

  rm -rf "$restore_tmp"

  yellow "[5/5] 启动 FreeLLMAPI..."
  if [[ -f "$compose_dir/docker-compose.yml" ]]; then
    cd "$compose_dir"
    if docker compose up -d; then
      cd - >/dev/null
      yellow "等待服务启动（10 秒）..."
      sleep 10
      if docker ps --format '{{.Names}}' | grep -q "^freellmapi$"; then
        local ip; ip=$(get_local_ip)
        local port=""
        [[ -f "$compose_dir/.env" ]] && port=$(grep '^PORT=' "$compose_dir/.env" | cut -d= -f2 | tr -d ' ' || true)
        [[ -z "$port" ]] && port="3001"
        local actual_image
        actual_image=$(docker inspect freellmapi --format '{{.Config.Image}}' 2>/dev/null || echo "未知")
        echo ""
        green "╔══════════════════════════════════════════════════════════╗"
        green "║  ✅  FreeLLMAPI 恢复并启动成功！                            ║"
        green "╠══════════════════════════════════════════════════════════╣"
        green "║  Dashboard   : http://$ip:$port"
        green "║  /v1 端点    : http://$ip:$port/v1/chat/completions"
        green "║  运行版本    : $actual_image"
        green "╚══════════════════════════════════════════════════════════╝"
      else
        red "❌ 容器启动后异常退出："
        docker compose -f "$compose_dir/docker-compose.yml" logs --tail=30 2>/dev/null || true
      fi
    else
      cd - >/dev/null
      red "❌ docker compose up -d 失败，请通过主菜单选项4重新部署。"
    fi
  else
    yellow "⚠️  未找到 docker-compose.yml，请通过主菜单选项4重新部署。"
  fi
}

function freellmapi_list_backups() {
  echo ""
  cyan "── FreeLLMAPI 备份文件列表 ──────────────────────────────"
  local found=false
  while IFS= read -r f; do
    local sz; sz=$(du -sh "$f" 2>/dev/null | cut -f1 || echo "?")
    local ts; ts=$(echo "$f" | grep -oE '[0-9]{8}_[0-9]{6}' | \
      sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)_\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3 \4:\5:\6/' || echo "")
    printf "  📦 %-50s  [%s]  %s\n" "$f" "$sz" "$ts"
    found=true
  done < <(_scan_backup_files "freellmapi-backup")
  [[ "$found" == false ]] && yellow "  未找到任何备份文件。"
  cyan "────────────────────────────────────────────────────"
}

function freellmapi_backup_menu() {
  while true; do
    echo ""
    cyan "╔══════════════════════════════════════════════════════════╗"
    cyan "║  FreeLLMAPI 备份 / 恢复                                    ║"
    cyan "╠══════════════════════════════════════════════════════════╣"
    cyan "║  ⚠️  ENCRYPTION_KEY + 数据卷 缺一不可，必须同时迁移        ║"
    cyan "╚══════════════════════════════════════════════════════════╝"
    echo ""
    echo "  1. 📦 立即备份        (KEY + 数据卷 + 配置打包)"
    echo "  2. 📂 从备份恢复      (覆盖当前数据并自动启动)"
    echo "  3. 🔍 查看本机备份文件列表"
    echo "  0. 返回"
    echo ""
    read -rp "选项 (0-3)：" ch </dev/tty
    case "$ch" in
      1) freellmapi_backup  || true; press_any_key ;;
      2) freellmapi_restore || true; press_any_key ;;
      3) freellmapi_list_backups;    press_any_key ;;
      0) return 0 ;;
      *) red "无效选项，请输入 0-3。" ;;
    esac
  done
}

function backup_restore_menu() {
  while true; do
    echo ""
    cyan "╔══════════════════════════════════════════════════════════╗"
    cyan "║  备份 / 恢复 管理中心                                      ║"
    cyan "╠══════════════════════════════════════════════════════════╣"
    cyan "║  One-API/New-API：备份绑定挂载目录（tar 打包）              ║"
    cyan "║  FreeLLMAPI：备份 ENCRYPTION_KEY + Docker 命名卷           ║"
    cyan "╚══════════════════════════════════════════════════════════╝"
    echo ""
    echo "  1. 🗄️  One-API / New-API 备份与恢复"
    echo "  2. 🔐 FreeLLMAPI 备份与恢复"
    echo "  0. 返回主菜单"
    echo ""
    read -rp "选项 (0-2)：" ch </dev/tty
    case "$ch" in
      1) general_backup_menu    || true ;;
      2) freellmapi_backup_menu || true ;;
      0) return 0 ;;
      *) red "无效选项，请输入 0-2。" ;;
    esac
  done
}

function deploy_service_sqlite() {
  local cname="$1"; local image="$2"; local int_port="$3"
  local data_name="$4"; local data_dir="$HOME/$data_name"

  check_existing_container "$cname" || return 1
  validate_port "$int_port"
  choose_network_mode
  pull_image_with_retry "$image" || return 1

  [[ "$OS" == "openwrt" ]] && {
    yellow "OpenWrt 存储有限，数据存于 $data_dir，建议挂载外部存储。"
    read -rp "按 Enter 继续，Ctrl+C 退出..." </dev/tty
  }
  ensure_dir_writable "$data_dir" || return 1

  green "部署 $cname（SQLite）..."
  local cmd=()
  cmd+=(docker run -d --name "$cname" --restart unless-stopped)
  if [[ "$NETWORK_MODE" == "host" ]]; then
    cmd+=(--network host); yellow "host 模式，监听端口 $int_port。"
  else
    cmd+=(--network bridge -p "$PORT:$int_port")
  fi
  cmd+=(-v "$data_dir:/data" -e "TZ=$DEFAULT_TZ" "$image")

  yellow "执行：${cmd[*]}"
  if ! "${cmd[@]}"; then
    red "启动失败！"; docker rm "$cname" &>/dev/null || true; return 1
  fi

  local ip; ip=$(get_local_ip)
  local ap=$PORT; [[ "$NETWORK_MODE" == "host" ]] && ap=$int_port
  green "✅ $cname 部署成功！"
  green "   访问地址：http://$ip:$ap"
  green "   数据目录：$data_dir"
  green "   初始账号：root / 123456"
}

function deploy_one_api_sqlite() {
  local cname="one-api"
  echo ""
  bold "══════════════════════════════════════════"
  bold " 部署 One-API（SQLite）"
  bold " 仓库：https://github.com/songquanpeng/one-api"
  bold "══════════════════════════════════════════"
  check_existing_container "$cname" || return 1
  select_image_version "One-API" "$ONE_API_IMAGE_BASE" "github" "songquanpeng/one-api" 8
  deploy_service_sqlite "$cname" "$SELECTED_IMAGE" 3000 "one-api-data"
}

function deploy_one_api_mysql() {
  local cname="one-api-mysql"; local int_port="3000"
  local data_dir="$HOME/one-api-mysql-logs"

  echo ""
  bold "══════════════════════════════════════════"
  bold " 部署 One-API（MySQL）"
  bold " 仓库：https://github.com/songquanpeng/one-api"
  bold "══════════════════════════════════════════"
  check_existing_container "$cname" || return 1
  select_image_version "One-API" "$ONE_API_IMAGE_BASE" "github" "songquanpeng/one-api" 8
  local sel_image="$SELECTED_IMAGE"
  validate_port "$int_port"; choose_network_mode

  yellow "请输入 MySQL 连接信息："
  read -rp "  主机：" db_host </dev/tty
  read -rp "  端口（默认 3306）：" db_port </dev/tty; db_port=${db_port:-3306}
  read -rp "  用户名：" db_user </dev/tty
  read -rsp "  密码：" db_pass </dev/tty; echo
  read -rp "  数据库名：" db_name </dev/tty

  if [[ -z "$db_host" || -z "$db_user" || -z "$db_name" ]]; then
    red "主机/用户名/数据库名不能为空。"; return 1
  fi
  [[ ! "$db_port" =~ ^[0-9]+$ ]] && { red "端口必须为数字。"; return 1; }

  local dsn="${db_user}:${db_pass}@tcp(${db_host}:${db_port})/${db_name}"
  pull_image_with_retry "$sel_image" || return 1
  ensure_dir_writable "$data_dir" || return 1

  local cmd=()
  cmd+=(docker run -d --name "$cname" --restart unless-stopped)
  [[ "$NETWORK_MODE" == "host" ]] \
    && cmd+=(--network host) \
    || cmd+=(--network bridge -p "$PORT:$int_port")
  cmd+=(-v "$data_dir:/data" -e "TZ=$DEFAULT_TZ" -e "SQL_DSN=$dsn" "$sel_image")

  yellow "执行：${cmd[*]//SQL_DSN=*/SQL_DSN=***}"
  if ! "${cmd[@]}"; then
    red "启动失败！"; docker rm "$cname" &>/dev/null || true; return 1
  fi

  local ip; ip=$(get_local_ip)
  local ap=$PORT; [[ "$NETWORK_MODE" == "host" ]] && ap=$int_port
  green "✅ $cname 部署成功！（MySQL 模式）"
  green "   访问地址：http://$ip:$ap"
  green "   初始账号：root / 123456"
}

function deploy_new_api() {
  local cname="new-api"; local int_port="3000"; local data_name="new-api-data"

  echo ""
  bold "══════════════════════════════════════════"
  bold " 部署 New-API（calciumion/new-api）"
  bold " 文档：https://docs.newapi.pro"
  bold "══════════════════════════════════════════"
  check_existing_container "$cname" || return 1
  select_image_version "New-API" "$NEW_API_IMAGE_BASE" "dockerhub" "calciumion/new-api" 8
  local sel_image="$SELECTED_IMAGE"

  echo ""
  read -rp "数据库模式：(1) SQLite  (2) MySQL  [默认 1]：" db_mode </dev/tty
  db_mode=${db_mode:-1}

  if [[ "$db_mode" == "2" ]]; then
    validate_port "$int_port"; choose_network_mode
    pull_image_with_retry "$sel_image" || return 1

    yellow "请输入 MySQL 连接信息："
    read -rp "  主机：" db_host </dev/tty
    read -rp "  端口（默认 3306）：" db_port </dev/tty; db_port=${db_port:-3306}
    read -rp "  用户名：" db_user </dev/tty
    read -rsp "  密码：" db_pass </dev/tty; echo
    read -rp "  数据库名：" db_name </dev/tty

    [[ -z "$db_host" || -z "$db_user" || -z "$db_name" ]] && { red "字段不能为空。"; return 1; }
    [[ ! "$db_port" =~ ^[0-9]+$ ]] && { red "端口必须为数字。"; return 1; }

    local dsn="${db_user}:${db_pass}@tcp(${db_host}:${db_port})/${db_name}"
    local data_dir="$HOME/$data_name"
    ensure_dir_writable "$data_dir" || return 1

    local cmd=()
    cmd+=(docker run -d --name "$cname" --restart unless-stopped)
    [[ "$NETWORK_MODE" == "host" ]] \
      && cmd+=(--network host) \
      || cmd+=(--network bridge -p "$PORT:$int_port")
    cmd+=(-v "$data_dir:/data" -e "TZ=$DEFAULT_TZ" -e "SQL_DSN=$dsn" "$sel_image")

    yellow "执行：${cmd[*]//SQL_DSN=*/SQL_DSN=***}"
    if ! "${cmd[@]}"; then
      red "启动失败！"; docker rm "$cname" &>/dev/null || true; return 1
    fi

    local ip; ip=$(get_local_ip)
    local ap=$PORT; [[ "$NETWORK_MODE" == "host" ]] && ap=$int_port
    green "✅ $cname 部署成功！（MySQL 模式）"
    green "   访问地址：http://$ip:$ap"
    green "   初始账号：root / 123456"
  else
    deploy_service_sqlite "$cname" "$sel_image" "$int_port" "$data_name"
  fi
}

function deploy_freellmapi() {
  local cname="freellmapi"; local int_port="3001"
  local compose_dir="$FREELLMAPI_COMPOSE_DIR"

  echo ""
  red    "╔══════════════════════════════════════════════════════════════╗"
  red    "║  部署 FreeLLMAPI                                               ║"
  yellow "║  聚合多家 LLM 平台免费额度，OpenAI 兼容 /v1 端点              ║"
  yellow "║  仓库：https://github.com/tashfeenahmed/freellmapi             ║"
  red    "║  ⚠️  仅供个人实验，需出网访问各 LLM 平台，纯内网环境不可用     ║"
  red    "╚══════════════════════════════════════════════════════════════╝"
  echo ""

  check_existing_container "$cname" || return 1
  command -v openssl &>/dev/null || install_dependency "openssl" "openssl" || true
  select_image_version "FreeLLMAPI" "$FREELLMAPI_IMAGE_BASE" "github" "tashfeenahmed/freellmapi" 8
  local sel_image="$SELECTED_IMAGE"

  validate_port "$int_port"; local chosen_port="$PORT"

  local host_bind="127.0.0.1"
  echo ""
  echo "请选择网络访问范围："
  echo "  1. 仅本机访问       (HOST_BIND=127.0.0.1，安全）"
  echo "  2. 局域网所有设备   (HOST_BIND=0.0.0.0，局域网服务器选此项)"
  read -rp "选项 (1-2，默认 1)：" bc </dev/tty
  case "${bc:-1}" in
    2) host_bind="0.0.0.0"; yellow "⚠️  局域网模式，请在受信任网络中使用。" ;;
    *) host_bind="127.0.0.1" ;;
  esac
  green "访问绑定：$host_bind"

  local rpm="120"
  read -rp "每分钟最大请求数（默认 120，0=禁用）：" ri </dev/tty
  [[ "$ri" =~ ^[0-9]+$ ]] && rpm="$ri"

  local key_file="$HOME/.freellmapi_encryption_key"; local enc_key=""
  if [[ -f "$key_file" ]]; then
    enc_key=$(cat "$key_file"); green "复用已有 ENCRYPTION_KEY：$key_file"
  else
    enc_key=$(openssl rand -hex 32)
    echo "$enc_key" > "$key_file"; chmod 600 "$key_file"
    green "已生成新 ENCRYPTION_KEY：$key_file"
    red   "⚠️  请备份此文件，升级/迁移时必须保留！"
  fi

  if [[ -d "$compose_dir" ]]; then
    yellow "发现已有部署目录：$compose_dir"
    read -rp "是否覆盖重新部署（保留 ENCRYPTION_KEY）？(y/n，默认 n)：" ow </dev/tty
    [[ ! "${ow:-n}" =~ ^[Yy]$ ]] && { yellow "已取消。"; return 0; }
  fi
  mkdir -p "$compose_dir"

  cat > "$compose_dir/.env" << EOF
# FreeLLMAPI 配置 — $(date '+%Y-%m-%d %H:%M:%S')
ENCRYPTION_KEY=${enc_key}
PORT=${chosen_port}
HOST_BIND=${host_bind}
PROXY_RATE_LIMIT_RPM=${rpm}
REQUEST_ANALYTICS_RETENTION_DAYS=90
REQUEST_ANALYTICS_MAX_ROWS=100000
EOF
  chmod 600 "$compose_dir/.env"; green ".env 已写入：$compose_dir/.env"

  cat > "$compose_dir/docker-compose.yml" << EOF
# FreeLLMAPI docker-compose.yml — $(date '+%Y-%m-%d %H:%M:%S')
services:
  freellmapi:
    image: ${sel_image}
    container_name: freellmapi
    restart: unless-stopped
    ports:
      - "${host_bind}:${chosen_port}:${chosen_port}"
    volumes:
      - freellmapi-data:/app/server/data
    env_file:
      - .env
    environment:
      - TZ=${DEFAULT_TZ}
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:${chosen_port}/v1/models || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 20s

volumes:
  freellmapi-data:
    name: freellmapi-data
EOF
  green "docker-compose.yml 已写入：$compose_dir/docker-compose.yml"

  pull_image_with_retry "$sel_image" || return 1

  green "启动 FreeLLMAPI..."
  cd "$compose_dir"
  if ! docker compose up -d; then
    red "docker compose up -d 失败！"
    cd - >/dev/null; return 1
  fi
  cd - >/dev/null

  yellow "等待服务启动（10 秒）..."
  sleep 10

  if ! docker ps --format '{{.Names}}' | grep -q "^freellmapi$"; then
    red "容器已退出，查看日志："
    docker compose -f "$compose_dir/docker-compose.yml" logs --tail=30 2>/dev/null || true
    return 1
  fi

  local ip; ip=$(get_local_ip)
  local url
  [[ "$host_bind" == "0.0.0.0" ]] && url="http://$ip:$chosen_port" || url="http://localhost:$chosen_port"

  echo ""
  green "╔══════════════════════════════════════════════════════════╗"
  green "║  ✅  FreeLLMAPI 部署成功！                                  ║"
  green "╠══════════════════════════════════════════════════════════╣"
  green "║  Dashboard : $url"
  green "║  /v1 端点  : $url/v1/chat/completions"
  yellow "║  添加 Key 后建议立即备份：主菜单 → 选项9                   ║"
  green  "╚══════════════════════════════════════════════════════════╝"
  echo ""
  yellow "如从其他设备打开 Dashboard 提示需要 Setup Code："
  yellow "主菜单 → 选项5（管理）→ 选项8 查看。"
}

function _freellmapi_upgrade_version() {
  local compose_dir="$FREELLMAPI_COMPOSE_DIR"
  local compose_file="$compose_dir/docker-compose.yml"

  echo ""
  cyan "══════════════════════════════════════════"
  cyan " FreeLLMAPI 版本升级 / 切换"
  cyan "══════════════════════════════════════════"
  echo ""

  if ! docker ps -a --format '{{.Names}}' | grep -q "^freellmapi$"; then
    yellow "未发现 freellmapi 容器，请先部署。"; return 1
  fi

  local cur_image=""
  cur_image=$(docker inspect freellmapi --format '{{.Config.Image}}' 2>/dev/null || echo "未知")
  green "当前运行版本：$cur_image"
  echo ""

  _prompt_backup_before_action "版本切换" || return 0
  select_image_version "FreeLLMAPI" "$FREELLMAPI_IMAGE_BASE" "github" "tashfeenahmed/freellmapi" 8
  local new_image="$SELECTED_IMAGE"

  if [[ "$new_image" == "$cur_image" ]]; then
    yellow "所选版本与当前版本相同。"
    read -rp "是否强制重新拉取并重启？(y/n，默认 n)：" fr </dev/tty
    [[ ! "${fr:-n}" =~ ^[Yy]$ ]] && { yellow "已取消。"; return 0; }
  fi

  pull_image_with_retry "$new_image" || return 1

  if [[ -f "$compose_file" ]]; then
    sed -i "s|image:.*freellmapi.*|image: ${new_image}|" "$compose_file" || true
    green "  ✅ docker-compose.yml 已更新"
    cd "$compose_dir"; docker compose up -d --no-deps freellmapi || true; cd - >/dev/null
  else
    yellow "未找到 docker-compose.yml，请通过主菜单选项4重新部署。"; return 0
  fi

  sleep 8

  if docker ps --format '{{.Names}}' | grep -q "^freellmapi$"; then
    local actual_image
    actual_image=$(docker inspect freellmapi --format '{{.Config.Image}}' 2>/dev/null || echo "未知")
    green "✅ 版本切换成功！当前运行版本：$actual_image"
  else
    red "❌ 容器启动异常："
    docker compose -f "$compose_file" logs --tail=30 2>/dev/null || true
  fi
}

function _freellmapi_show_setup_code() {
  green "══════════════════════════════════════════"
  green " 远程初始化 Setup Code 查询"
  green "══════════════════════════════════════════"
  echo ""
  local result
  result=$(docker logs freellmapi 2>&1 | grep -iE "code|setup|one.time|one-time|pin" || true)
  if [[ -n "$result" ]]; then
    green "已找到相关日志："; echo "$result"
  else
    yellow "关键词未匹配，显示启动前 80 行日志："
    docker logs freellmapi 2>&1 | head -80 || true
  fi
  echo ""
  read -rp "是否同时显示完整前100行日志？(y/n，默认 n)：" sv </dev/tty
  if [[ "${sv:-n}" =~ ^[Yy]$ ]]; then
    docker logs freellmapi 2>&1 | head -100 || true
  fi
  echo ""
  yellow "提示：若未找到 code，可重启容器使其重新打印："
  yellow "  docker compose -f ~/freellmapi/docker-compose.yml restart"
}

function manage_freellmapi() {
  local compose_file="$FREELLMAPI_COMPOSE_DIR/docker-compose.yml"

  while true; do
    echo ""
    cyan "╔══════════════════════════════════════════╗"
    cyan "║       FreeLLMAPI 服务管理                  ║"
    cyan "╚══════════════════════════════════════════╝"

    if ! docker ps -a --format '{{.Names}}' | grep -q "^freellmapi$"; then
      yellow "未发现 freellmapi 容器，请先通过主菜单选项 4 部署。"
      press_any_key; return 0
    fi

    echo ""
    green "── 当前容器状态 ──────────────────────────────"
    docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" \
      | grep -E "NAMES|freellmapi" || true
    echo ""

    echo "请选择操作："
    echo "  1. 查看实时日志         (Ctrl+C 退出后返回此菜单)"
    echo "  2. 查看最近 100 行日志"
    echo "  3. 停止服务"
    echo "  4. 启动服务"
    echo "  5. 重启服务"
    echo "  6. 🔄 版本升级 / 切换   (可选最近8个版本)"
    echo "  7. 查看数据卷信息"
    echo "  8. 🔑 查看远程初始化 Setup Code"
    echo "  0. 返回主菜单"
    read -rp "选项 (0-8)：" mc </dev/tty; echo ""

    local use_compose=false
    [[ -f "$compose_file" ]] && use_compose=true

    _compose_or_docker() {
      if $use_compose; then
        docker compose -f "$compose_file" "$@"
      else
        local subcmd="$1"; shift
        case "$subcmd" in
          logs)    docker logs "$@" freellmapi ;;
          stop)    docker stop freellmapi ;;
          start)   docker start freellmapi ;;
          restart) docker restart freellmapi ;;
          *)       yellow "fallback 不支持：$subcmd" ;;
        esac
      fi
    }

    case "$mc" in
      1) green "实时日志（Ctrl+C 退出）..."; _compose_or_docker logs -f freellmapi || true ;;
      2) green "最近 100 行日志："; _compose_or_docker logs --tail=100 freellmapi || true; press_any_key ;;
      3) yellow "停止服务..."; _compose_or_docker stop freellmapi && green "✅ 已停止。" || red "停止失败。"; press_any_key ;;
      4) yellow "启动服务..."; _compose_or_docker start freellmapi && green "✅ 已启动。" || red "启动失败。"; press_any_key ;;
      5)
        yellow "重启服务..."; _compose_or_docker restart freellmapi || true; sleep 5
        green "重启后状态："
        docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "NAMES|freellmapi" || true
        press_any_key ;;
      6) _freellmapi_upgrade_version || true; press_any_key ;;
      7)
        green "── freellmapi-data 数据卷信息 ──"
        docker volume inspect freellmapi-data &>/dev/null \
          && docker volume inspect freellmapi-data \
          || yellow "未找到 freellmapi-data 卷。"
        press_any_key ;;
      8) _freellmapi_show_setup_code; press_any_key ;;
      0) return 0 ;;
      *) red "无效选项，请输入 0-8。" ;;
    esac
  done
}

function uninstall_freellmapi() {
  local compose_dir="$FREELLMAPI_COMPOSE_DIR"
  local compose_file="$compose_dir/docker-compose.yml"
  local key_file="$HOME/.freellmapi_encryption_key"

  echo ""
  red "╔══════════════════════════════════════════════════════════════╗"
  red "║  完全卸载 FreeLLMAPI                                           ║"
  red "╚══════════════════════════════════════════════════════════════╝"
  echo ""
  yellow "⚠️  强烈建议先通过主菜单选项9完成备份再执行卸载！"
  echo ""
  _prompt_backup_before_action "卸载" || return 0

  read -rp "再次确认完全卸载？(输入 yes 确认，其他取消)：" cf </dev/tty
  [[ "$cf" != "yes" ]] && { yellow "已取消。"; return 0; }

  echo ""
  yellow "[1/6] 停止并删除容器..."
  if docker ps -a --format '{{.Names}}' | grep -q "^freellmapi$"; then
    [[ -f "$compose_file" ]] && { cd "$compose_dir"; docker compose down freellmapi 2>/dev/null || true; cd - >/dev/null; }
    docker stop freellmapi &>/dev/null || true
    docker rm   freellmapi &>/dev/null || true
    green "  ✅ 容器已删除。"
  else
    yellow "  未发现容器，跳过。"
  fi

  echo ""
  yellow "[2/6] 删除 Docker 镜像..."
  local imgs
  imgs=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep "^ghcr.io/tashfeenahmed/freellmapi" || true)
  if [[ -n "$imgs" ]]; then
    echo "  发现镜像："; echo "$imgs" | while read -r i; do echo "    - $i"; done
    read -rp "  是否删除？(y/n，默认 y)：" di </dev/tty
    if [[ "${di:-y}" =~ ^[Yy]$ ]]; then
      echo "$imgs" | xargs docker rmi 2>/dev/null \
        && green "  ✅ 镜像已删除。" || yellow "  ⚠️  部分镜像删除失败。"
    fi
  else
    yellow "  未发现相关镜像，跳过。"
  fi

  echo ""
  yellow "[3/6] 删除数据卷 freellmapi-data..."
  if docker volume inspect freellmapi-data &>/dev/null; then
    red   "  ⚠️  删除后所有 provider keys 和分析数据将永久丢失！"
    read -rp "  确认删除数据卷？(y/n，默认 n)：" bv </dev/tty
    if [[ "${bv:-n}" =~ ^[Yy]$ ]]; then
      docker volume rm freellmapi-data \
        && green "  ✅ 数据卷已删除。" || yellow "  ⚠️  请手动：docker volume rm freellmapi-data"
    else
      yellow "  已保留数据卷 freellmapi-data。"
    fi
  else
    yellow "  未发现数据卷，跳过。"
  fi

  echo ""
  yellow "[4/6] 删除项目目录 $compose_dir ..."
  if [[ -d "$compose_dir" ]]; then
    read -rp "  是否删除？(y/n，默认 y)：" dd </dev/tty
    if [[ "${dd:-y}" =~ ^[Yy]$ ]]; then
      local rc="rm -rf \"$compose_dir\""
      [[ "$EUID" -ne 0 ]] && command -v sudo &>/dev/null && rc="sudo $rc"
      eval "$rc" && green "  ✅ 目录已删除。" || red "  ❌ 请手动：rm -rf $compose_dir"
    else
      yellow "  保留目录：$compose_dir"
    fi
  else
    yellow "  目录不存在，跳过。"
  fi

  echo ""
  yellow "[5/6] 处理 ENCRYPTION_KEY 文件..."
  if [[ -f "$key_file" ]]; then
    red   "  ⚠️  此文件是加密密钥唯一备份！"
    read -rp "  是否删除？(y/n，默认 n)：" dk </dev/tty
    if [[ "${dk:-n}" =~ ^[Yy]$ ]]; then
      rm -f "$key_file" && green "  ✅ ENCRYPTION_KEY 文件已删除。" || red "  请手动：rm $key_file"
    else
      yellow "  保留：$key_file"
    fi
  else
    yellow "  文件不存在，跳过。"
  fi

  echo ""
  yellow "[6/6] 检查悬空镜像..."
  local dangling
  dangling=$(docker images -f "dangling=true" -q 2>/dev/null || true)
  if [[ -n "$dangling" ]]; then
    local cnt; cnt=$(echo "$dangling" | wc -l)
    read -rp "  发现 ${cnt} 个悬空镜像，是否清理？(y/n，默认 n)：" cd2 </dev/tty
    [[ "${cd2:-n}" =~ ^[Yy]$ ]] \
      && docker image prune -f && green "  ✅ 已清理。" || yellow "  跳过清理。"
  else
    green "  ✅ 无悬空镜像。"
  fi

  echo ""
  green "╔══════════════════════════════════════════╗"
  green "║  ✅  FreeLLMAPI 已完全卸载！               ║"
  green "╚══════════════════════════════════════════╝"
}

function uninstall_general_service() {
  local cname="$1"; local data_name="$2"; local img_pat="$3"
  local data_dir="$HOME/$data_name"

  yellow "── 卸载 $cname ──"

  if docker ps -a --format '{{.Names}}' | grep -Eq "^${cname}$"; then
    yellow "停止并删除容器 $cname ..."
    docker stop "$cname" && docker rm "$cname" \
      && green "  ✅ 容器已删除。" || red "  ❌ 请手动：docker rm -f $cname"
  else
    yellow "  未发现容器 $cname，跳过。"
  fi

  local imgs
  imgs=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep "^${img_pat}" || true)
  if [[ -n "$imgs" ]]; then
    echo "  发现镜像："; echo "$imgs" | while read -r i; do echo "    - $i"; done
    read -rp "  是否删除镜像？(y/n，默认 n)：" di </dev/tty
    if [[ "${di:-n}" =~ ^[Yy]$ ]]; then
      echo "$imgs" | xargs docker rmi 2>/dev/null \
        && green "  ✅ 镜像已删除。" || yellow "  ⚠️  部分镜像删除失败。"
    fi
  else
    yellow "  未发现相关镜像，跳过。"
  fi

  if [[ -d "$data_dir" ]]; then
    yellow "  数据目录：$data_dir"
    read -rp "  是否删除（不可逆）？(y/n，默认 n)：" dd </dev/tty
    if [[ "${dd:-n}" =~ ^[Yy]$ ]]; then
      read -rp "  是否先备份？(y/n，默认 n)：" bk </dev/tty
      local do_del=true
      if [[ "${bk:-n}" =~ ^[Yy]$ ]]; then
        local bdir="${data_dir}-backup-$(date +%Y%m%d_%H%M%S)"
        cp -a "$data_dir" "$bdir" \
          && green "  ✅ 已备份：$bdir" \
          || { red "  ❌ 备份失败，取消删除。"; do_del=false; }
      fi
      if [[ "$do_del" == true ]]; then
        local rc="rm -rf \"$data_dir\""
        [[ "$EUID" -ne 0 ]] && command -v sudo &>/dev/null && rc="sudo $rc"
        eval "$rc" && green "  ✅ 数据目录已删除。" || red "  ❌ 请手动：rm -rf $data_dir"
      fi
    else
      yellow "  保留数据目录：$data_dir"
    fi
  else
    yellow "  数据目录不存在，跳过。"
  fi

  green "── $cname 卸载完成 ──"
}

function uninstall_menu() {
  while true; do
    echo ""
    cyan "╔══════════════════════════════════════════════════════════╗"
    cyan "║  卸载服务（One-API / New-API）                            ║"
    cyan "╚══════════════════════════════════════════════════════════╝"
    echo "  1. One-API SQLite   (容器：one-api，          数据：~/one-api-data)"
    echo "  2. One-API MySQL    (容器：one-api-mysql，    数据：~/one-api-mysql-logs)"
    echo "  3. New-API          (容器：new-api，          数据：~/new-api-data)"
    echo "  0. 返回主菜单"
    read -rp "选项 (0-3)：" ch </dev/tty
    case "$ch" in
      1) uninstall_general_service "one-api"       "one-api-data"       "ghcr.io/songquanpeng/one-api"; press_any_key ;;
      2) uninstall_general_service "one-api-mysql" "one-api-mysql-logs" "ghcr.io/songquanpeng/one-api"; press_any_key ;;
      3) uninstall_general_service "new-api"       "new-api-data"       "calciumion/new-api";           press_any_key ;;
      0) return 0 ;;
      *) red "无效选项，请输入 0-3。" ;;
    esac
  done
}

function view_container_status() {
  green "── 当前 Docker 容器状态 ──────────────────────"
  if [[ $(docker ps -a --format '{{.Names}}' | wc -l) -eq 0 ]]; then
    yellow "当前无任何 Docker 容器。"
  else
    docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"
  fi
  echo ""
  green "── Docker 磁盘占用 ───────────────────────────"
  docker system df 2>/dev/null || true
  echo "──────────────────────────────────────────────"
}

function main_menu() {
  detect_architecture
  detect_os
  setup_logging
  check_base_dependencies
  check_docker_dependencies
  check_user_permission

  if [[ "$OS" == "openwrt" ]]; then
    yellow "==== OpenWrt/LibWRT 环境提示 ===="
    yellow "  - Bash 未安装时请先：opkg install bash"
    yellow "  - 存储有限，数据目录在 \$HOME，建议挂载外部存储"
    yellow "  - Docker 服务：/etc/init.d/dockerd"
    yellow "================================="
    sleep 1
  fi

  while true; do
    local dv="未运行" cv="未安装"
    docker --version &>/dev/null && dv=$(docker --version)
    if docker compose version &>/dev/null; then
      cv=$(docker compose version | head -n1)
    elif command -v docker-compose &>/dev/null; then
      cv=$(docker-compose --version)
    fi

    local fllm_status="未部署"
    if docker ps --format '{{.Names}}' | grep -q "^freellmapi$"; then
      local fllm_ver
      fllm_ver=$(docker inspect freellmapi --format '{{.Config.Image}}' 2>/dev/null | grep -oE '[^:]+$' || echo "")
      fllm_status="运行中 [${fllm_ver}]"
    elif docker ps -a --format '{{.Names}}' | grep -q "^freellmapi$"; then
      fllm_status="已停止"
    fi

    local mirror_status="未配置"
    local cur_mirrors; cur_mirrors=$(_read_current_mirrors)
    [[ -n "$cur_mirrors" ]] && mirror_status="已配置 $(echo "$cur_mirrors" | grep -c 'https' || echo 0) 个"

    local pack_type; pack_type=$(_check_pack_tools)

    echo ""
    echo "================= Docker 服务管理 ================="
    printf "系统: %-15s 架构: %-10s\n" "$OS" "$ARCH"
    printf "Docker:  %s\n" "$dv"
    printf "Compose: %s\n" "$cv"
    printf "FreeLLMAPI: %-20s 加速器: %s\n" "$fllm_status" "$mirror_status"
    printf "备份工具: %s\n" "$pack_type"
    echo "---------------------------------------------------"
    echo " 1) 部署 One-API   (SQLite)         [版本可选]"
    echo " 2) 部署 One-API   (MySQL)           [版本可选]"
    echo " 3) 部署 New-API   (calciumion)      [版本可选]"
    echo " 4) 部署 FreeLLMAPI (聚合 /v1)       [版本可选]"
    echo "---------------------------------------------------"
    echo " 5) 管理 FreeLLMAPI   (日志/启停/版本升级/Setup Code)"
    echo " 6) 卸载 FreeLLMAPI   (含镜像/数据)"
    echo "---------------------------------------------------"
    echo " 7) 卸载 One-API / New-API"
    echo " 8) 查看所有容器状态"
    echo " 9) 💾 备份 / 恢复（One-API / New-API / FreeLLMAPI）"
    echo "10) 🚀 Docker 镜像加速器配置（解决国内拉取慢）"
    echo "---------------------------------------------------"
    echo " 0) 退出"
    echo "==================================================="
    read -rp "请输入选项 (0-10): " ch </dev/tty
    echo ""

    case "$ch" in
      1)  deploy_one_api_sqlite        || true; press_any_key ;;
      2)  deploy_one_api_mysql         || true; press_any_key ;;
      3)  deploy_new_api               || true; press_any_key ;;
      4)  deploy_freellmapi            || true; press_any_key ;;
      5)  manage_freellmapi            || true ;;
      6)  uninstall_freellmapi         || true; press_any_key ;;
      7)  uninstall_menu               || true ;;
      8)  view_container_status        || true; press_any_key ;;
      9)  backup_restore_menu          || true ;;
      10) configure_docker_mirror      || true ;;
      0)  green "感谢使用，脚本退出。"; exit 0 ;;
      *)  red "无效选项 '$ch'，请输入 0-10。" ;;
    esac
  done
}

main_menu
