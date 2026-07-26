#!/usr/bin/env bash
set -uo pipefail
trap 'echo -e "\n[!] 已中断"; exit 1' INT

SCRIPT_NAME="Lucky 部署管理器"
SCRIPT_VERSION="1.3"

CONTAINER_NAME="lucky"
IMAGE_NAME="gdy666/lucky"
CONTAINER_PORT_DEFAULT=16601

LUCKY_INSTALL_DIR="/usr/local/lucky"
LUCKY_BIN="/usr/local/bin/lucky"
LUCKY_SERVICE="/etc/systemd/system/lucky.service"

LUCKY_DATA_DIR="/var/lib/lucky"
LUCKY_DATA_DIR_LEGACY="/root/luckyconf"
DOCKER_CONFIG_DIR="${LUCKY_DATA_DIR_LEGACY}"
BACKUP_GLOB="/root/lucky_backup_*"

LUCKY_GITHUB_REPO="gdy666/lucky"
LUCKY_GITHUB_RELEASE="https://github.com/${LUCKY_GITHUB_REPO}/releases/download"
GH_API_MIRRORS=(
  "https://api.github.com/repos/${LUCKY_GITHUB_REPO}/releases"
  "https://gh-proxy.com/https://api.github.com/repos/${LUCKY_GITHUB_REPO}/releases"
  "https://ghproxy.link/https://api.github.com/repos/${LUCKY_GITHUB_REPO}/releases"
)
GH_DL_MIRRORS=( "" "https://gh-proxy.com/" "https://ghproxy.link/" "https://ghfast.top/" "https://ghps.cc/" "https://mirror.ghproxy.com/" )

RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'
BLUE='\033[34m'; RESET='\033[0m'

logi(){ echo -e "[i] $*"; }
ok(){   echo -e "${GREEN}[✓]${RESET} $*"; }
warn(){ echo -e "${YELLOW}[!]${RESET} $*"; }
err(){  echo -e "${RED}[x]${RESET} $*" >&2; }

have(){ command -v "$1" >/dev/null 2>&1; }
need_root(){ [[ "${EUID}" -eq 0 ]] || { err "该操作需要 root 权限。"; return 1; }; }

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
  have curl || { err "缺少 curl，请先安装"; exit 1; }
  have tar  || { err "缺少 tar，请先安装"; exit 1; }
}

install_docker_if_missing(){
  if have docker; then return 0; fi
  warn "未检测到 Docker，准备自动安装。"
  need_root || return 1
  local tmp="/tmp/get-docker.sh"
  curl -fsSL https://get.docker.com -o "$tmp" || { err "下载 Docker 安装脚本失败"; return 1; }
  sh "$tmp" || { err "Docker 安装失败"; return 1; }
  rm -f "$tmp" || true
  have systemctl && systemctl enable --now docker >/dev/null 2>&1 || true
  have docker || { err "Docker 仍不可用"; return 1; }
  ok "Docker 安装完成：$(docker --version 2>/dev/null || true)"
}

ensure_docker(){ install_docker_if_missing; }
docker_container_exists(){ docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; }

get_host_ip(){
  local _ip=""
  _ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/{print $7; exit}' || true)"
  if [[ -z "$_ip" ]]; then
    _ip="$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1 || true)"
  fi
  echo "${_ip:-<服务器IP>}"
}

_get_docker_status(){
  if ! have docker; then echo "Docker未安装"; return; fi
  if docker_container_exists; then
    local s; s=$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "未知")
    local img; img=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null || echo "")
    echo "${s}  [${img}]"
  else
    echo "未部署"
  fi
}

_get_native_status(){
  if [[ ! -f "$LUCKY_INSTALL_DIR/lucky" ]]; then echo "未安装"; return; fi
  if have systemctl && systemctl is-active lucky &>/dev/null; then
    echo "运行中"
  else
    echo "已停止"
  fi
}

_get_docker_port(){
  if ! have docker || ! docker_container_exists; then echo ""; return; fi
  local net; net=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$CONTAINER_NAME" 2>/dev/null || echo "")
  if [[ "$net" == "host" ]]; then
    echo "host 模式"
  else
    local p=""
    if have jq; then
      p=$(docker inspect "$CONTAINER_NAME" | jq -r --arg k "${CONTAINER_PORT_DEFAULT}/tcp" '.[0].HostConfig.PortBindings[$k]?[0]?.HostPort // empty' 2>/dev/null || true)
    fi
    p="${p:-$CONTAINER_PORT_DEFAULT}"
    echo "端口 $p"
  fi
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
}

detect_default_iface(){
  local ifc=""
  ifc="$(ip -4 route show default 2>/dev/null | awk 'NR==1{print $5}' || true)"
  [[ -n "$ifc" ]] || ifc="$(ip -6 route show default 2>/dev/null | awk 'NR==1{print $5}' || true)"
  [[ -n "$ifc" ]] || ifc="$(ip -o link show up 2>/dev/null | awk -F': ' '$2!="lo"{print $2; exit}' || true)"
  echo "${ifc:-}"
}

ipv6_has_global_addr(){
  local ifc="$1"
  ip -6 addr show dev "$ifc" 2>/dev/null | grep -qE 'inet6 (2|3)[0-9a-fA-F:]+/.* scope global'
}

ipv6_has_default_route(){
  ip -6 route show default 2>/dev/null | grep -q '^default'
}

ipv6_dns_ok(){
  if have getent; then
    getent ahosts ipv6.google.com 2>/dev/null | grep -q ':' && return 0; return 1
  fi
  if have nslookup; then
    nslookup -type=AAAA ipv6.google.com 2>/dev/null | grep -qi 'Address:' && return 0; return 1
  fi
  if have dig; then
    dig +short AAAA ipv6.google.com 2>/dev/null | grep -q ':' && return 0; return 1
  fi
  return 2
}

apply_sysctl_ipv6_runtime(){
  local ifc="$1"
  sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 || true
  sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1 || true
  sysctl -w net.ipv6.conf.lo.disable_ipv6=0 >/dev/null 2>&1 || true
  sysctl -w net.ipv6.conf.all.accept_ra=2 >/dev/null 2>&1 || true
  sysctl -w net.ipv6.conf.default.accept_ra=2 >/dev/null 2>&1 || true
  [[ -n "$ifc" ]] && sysctl -w "net.ipv6.conf.${ifc}.accept_ra=2" >/dev/null 2>&1 || true
  sysctl -w net.ipv6.conf.all.autoconf=1 >/dev/null 2>&1 || true
  sysctl -w net.ipv6.conf.default.autoconf=1 >/dev/null 2>&1 || true
  [[ -n "$ifc" ]] && sysctl -w "net.ipv6.conf.${ifc}.autoconf=1" >/dev/null 2>&1 || true
}

persist_sysctl_ipv6(){
  local conf="/etc/sysctl.d/99-lucky-ipv6.conf"
  cat > "$conf" <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.lo.disable_ipv6 = 0
net.ipv6.conf.all.accept_ra = 2
net.ipv6.conf.default.accept_ra = 2
net.ipv6.conf.all.autoconf = 1
net.ipv6.conf.default.autoconf = 1
EOF
  sysctl --system >/dev/null 2>&1 || sysctl -p "$conf" >/dev/null 2>&1 || true
}

kick_network_stack(){
  local ifc="$1"
  if [[ -n "$ifc" ]]; then
    ip link set "$ifc" down >/dev/null 2>&1 || true
    sleep 1
    ip link set "$ifc" up >/dev/null 2>&1 || true
  fi
  if have nmcli && [[ -n "$ifc" ]]; then
    nmcli dev disconnect "$ifc" >/dev/null 2>&1 || true
    sleep 1
    nmcli dev connect "$ifc" >/dev/null 2>&1 || true
  fi
  if have networkctl; then
    networkctl reload >/dev/null 2>&1 || true
    [[ -n "$ifc" ]] && networkctl reconfigure "$ifc" >/dev/null 2>&1 || true
  fi
  if have ifdown && have ifup && [[ -n "$ifc" ]]; then
    ifdown "$ifc" >/dev/null 2>&1 || true
    sleep 1
    ifup "$ifc" >/dev/null 2>&1 || true
  fi
  if have ifup; then
    ifup wan >/dev/null 2>&1 || true
    ifup wan6 >/dev/null 2>&1 || true
  fi
}

enable_ipv6_auto(){
  need_root || return 1
  echo ""
  echo "===== IPv6 自动开启/修复 ====="
  local ifc; ifc="$(detect_default_iface)"
  logi "默认出网接口：${ifc:-<未知>}"
  logi "应用 sysctl（运行时）：disable_ipv6=0, accept_ra=2, autoconf=1"
  apply_sysctl_ipv6_runtime "$ifc"
  logi "写入持久化配置：/etc/sysctl.d/99-lucky-ipv6.conf"
  persist_sysctl_ipv6
  logi "触发网络重新获取 IPv6..."
  kick_network_stack "$ifc"
  sleep 2

  echo ""
  logi "当前 IPv6 地址："
  if [[ -n "$ifc" ]]; then
    ip -6 addr show dev "$ifc" 2>/dev/null || true
  else
    ip -6 addr show 2>/dev/null || true
  fi

  echo ""
  logi "当前 IPv6 路由："
  ip -6 route 2>/dev/null || true

  local ok_addr="false" ok_route="false"
  [[ -n "$ifc" ]] && ipv6_has_global_addr "$ifc" && ok_addr="true"
  ipv6_has_default_route && ok_route="true"

  echo ""
  if [[ "$ok_addr" == "true" && "$ok_route" == "true" ]]; then
    ok "IPv6 已工作：有全局地址 + 默认路由"
  else
    warn "IPv6 仍不完整："
    [[ "$ok_addr" != "true" ]] && warn " - 未在 ${ifc:-接口} 上看到全局 IPv6 地址"
    [[ "$ok_route" != "true" ]] && warn " - 未看到默认 IPv6 路由"
    warn "常见原因：上游未下发 RA/DHCPv6，或网络不透传 ICMPv6 RA。"
  fi

  local dns_rc=0
  ipv6_dns_ok || dns_rc=$?
  if [[ "$dns_rc" -eq 0 ]]; then
    ok "IPv6 DNS 解析正常"
  else
    warn "IPv6 DNS 解析可能不正常，请检查 /etc/resolv.conf 或上游 RA 是否下发 RDNSS。"
  fi

  echo ""
  press_any
}

get_dockerhub_tags(){
  local url="https://hub.docker.com/v2/repositories/gdy666/lucky/tags?page_size=50&ordering=last_updated"
  local raw; raw="$(curl -fsSL -m 12 "$url" 2>/dev/null || true)"
  [[ -z "$raw" ]] && return 1
  if have jq; then
    echo "$raw" | jq -r '.results[].name' | grep -v '^latest$' | grep -E '^[0-9v]' | head -n 20
  else
    echo "$raw" | grep -o '"name":"[^"]*"' | cut -d'"' -f4 | grep -v '^latest$' | grep -E '^[0-9v]' | head -n 20
  fi
}

choose_docker_tag(){
  DOCKER_TAG="latest"
  logi "获取 Docker Hub 版本列表..."
  local tags=() tlist; tlist="$(get_dockerhub_tags || true)"
  [[ -n "$tlist" ]] && mapfile -t tags < <(printf "%s\n" "$tlist")
  echo "  1) latest（默认）"
  local i=2
  for t in "${tags[@]:0:12}"; do
    echo "  $i) $t"
    i=$((i + 1))
  done
  local manual_idx=$i
  echo "  $i) 手动输入"
  local choice=""
  read_default "版本编号" "1" choice
  if [[ "$choice" == "1" || -z "$choice" ]]; then
    DOCKER_TAG="latest"
  elif [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 2 && "$choice" -lt "$manual_idx" ]]; then
    DOCKER_TAG="${tags[$((choice-2))]}"
  elif [[ "$choice" == "$manual_idx" ]]; then
    read_default "输入 tag" "latest" DOCKER_TAG
  else
    DOCKER_TAG="latest"
  fi
  ok "已选版本：$DOCKER_TAG"
}

deploy_docker(){
  echo ""
  echo "===== Docker 部署 ====="
  ensure_docker || return 1
  if docker_container_exists; then
    warn "容器已存在：$CONTAINER_NAME"
    local ow=false
    read_yesno_default "覆盖重建？" "N" ow
    [[ "$ow" == "true" ]] || { warn "已取消"; press_any; return; }
    docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
  mkdir -p "$DOCKER_CONFIG_DIR"
  choose_docker_tag

  echo ""
  echo "  1) Bridge（推荐，通过端口映射访问）"
  echo "  2) Host（共享主机网络）"
  local mode=""
  read_default "网络模式" "1" mode

  local host_port="$CONTAINER_PORT_DEFAULT"
  if [[ "$mode" != "2" ]]; then
    read_default "宿主机端口" "$CONTAINER_PORT_DEFAULT" host_port
    if ! [[ "$host_port" =~ ^[0-9]+$ ]] || (( host_port < 1 || host_port > 65535 )); then
      host_port="$CONTAINER_PORT_DEFAULT"
    fi
  else
    local go=false
    read_yesno_default "Host 模式将共享所有端口，确认继续？" "N" go
    [[ "$go" == "true" ]] || { warn "已取消"; press_any; return; }
  fi

  logi "拉取镜像：${IMAGE_NAME}:${DOCKER_TAG}"
  if ! docker pull "${IMAGE_NAME}:${DOCKER_TAG}"; then
    warn "拉取失败，请检查网络或 Docker Hub 连通性"
    press_any; return 1
  fi

  if [[ "$mode" == "2" ]]; then
    docker run -d --name "$CONTAINER_NAME" --restart=always \
      --net=host \
      -v "${DOCKER_CONFIG_DIR}:/goodluck" \
      "${IMAGE_NAME}:${DOCKER_TAG}"
  else
    docker run -d --name "$CONTAINER_NAME" --restart=always \
      -p "${host_port}:${CONTAINER_PORT_DEFAULT}" \
      -v "${DOCKER_CONFIG_DIR}:/goodluck" \
      "${IMAGE_NAME}:${DOCKER_TAG}"
  fi

  local ip; ip=$(get_host_ip)
  ok "部署成功！访问地址：http://${ip}:${host_port}"
  warn "首次登录请立即修改默认账号/密码。"
  press_any
}

upgrade_docker(){
  echo ""
  echo "===== Docker 更新 ====="
  ensure_docker || return 1
  if ! docker_container_exists; then
    warn "未部署，请先通过菜单部署"
    press_any; return
  fi

  local cur_image; cur_image=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null || echo "未知")
  logi "当前运行版本：$cur_image"

  choose_docker_tag

  logi "拉取镜像：${IMAGE_NAME}:${DOCKER_TAG}"
  if ! docker pull "${IMAGE_NAME}:${DOCKER_TAG}"; then
    warn "拉取失败"
    press_any; return 1
  fi

  local net_mode; net_mode="$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$CONTAINER_NAME" 2>/dev/null || echo bridge)"
  local host_port="$CONTAINER_PORT_DEFAULT"
  if [[ "$net_mode" != "host" ]]; then
    if have jq; then
      host_port="$(docker inspect "$CONTAINER_NAME" | jq -r --arg p "${CONTAINER_PORT_DEFAULT}/tcp" '.[0].HostConfig.PortBindings[$p]?[0]?.HostPort // empty' 2>/dev/null || true)"
    fi
    host_port="${host_port:-$CONTAINER_PORT_DEFAULT}"
  fi

  docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
  docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
  mkdir -p "$DOCKER_CONFIG_DIR"

  if [[ "$net_mode" == "host" ]]; then
    docker run -d --name "$CONTAINER_NAME" --restart=always \
      --net=host \
      -v "${DOCKER_CONFIG_DIR}:/goodluck" \
      "${IMAGE_NAME}:${DOCKER_TAG}"
  else
    docker run -d --name "$CONTAINER_NAME" --restart=always \
      -p "${host_port}:${CONTAINER_PORT_DEFAULT}" \
      -v "${DOCKER_CONFIG_DIR}:/goodluck" \
      "${IMAGE_NAME}:${DOCKER_TAG}"
  fi

  ok "更新完成"
  press_any
}

uninstall_docker(){
  echo ""
  echo "===== Docker 卸载 ====="
  if docker_container_exists; then
    local go=false
    read_yesno_default "确认删除容器 $CONTAINER_NAME？" "N" go
    [[ "$go" == "true" ]] || { warn "已取消"; press_any; return; }
    docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker rm "$CONTAINER_NAME" >/dev/null 2>&1 && ok "容器已删除" || warn "删除失败"
  else
    warn "未发现容器 $CONTAINER_NAME"
  fi
  local del=false
  read_yesno_default "删除配置目录 ${DOCKER_CONFIG_DIR}？" "N" del
  [[ "$del" == "true" ]] && { rm -rf "$DOCKER_CONFIG_DIR"; ok "配置目录已删除"; } || true
  press_any
}

manage_docker_container(){
  while true; do
    local status; status=$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "未知")
    echo ""
    echo "===== 容器管理 [$CONTAINER_NAME - $status] ====="
    echo "  1. 启动"
    echo "  2. 停止"
    echo "  3. 重启"
    echo "  4. 查看实时日志 (Ctrl+C 退出)"
    echo "  5. 查看最近 100 行日志"
    echo "  0. 返回"
    echo "==========================================="
    local op=""
    read_default "选择" "0" op
    case "$op" in
      1)
        docker start "$CONTAINER_NAME" \
          && ok "$CONTAINER_NAME 已启动" \
          || warn "$CONTAINER_NAME 启动失败"
        press_any
        ;;
      2)
        docker stop "$CONTAINER_NAME" \
          && ok "$CONTAINER_NAME 已停止" \
          || warn "$CONTAINER_NAME 停止失败"
        press_any
        ;;
      3)
        docker restart "$CONTAINER_NAME" \
          && ok "$CONTAINER_NAME 已重启" \
          || warn "$CONTAINER_NAME 重启失败"
        press_any
        ;;
      4)
        docker logs -f --tail=50 "$CONTAINER_NAME" || true
        ;;
      5)
        docker logs --tail=100 "$CONTAINER_NAME" || true
        press_any
        ;;
      0) return ;;
      *) warn "无效输入" ;;
    esac
  done
}

_select_backup_root(){
  echo "" >&2
  echo "请选择备份存储位置：" >&2
  echo "  1. 主目录 ($HOME)" >&2
  echo "  2. /tmp 目录（重启后丢失）" >&2
  echo "  3. 手动输入路径" >&2
  local bc=""
  read_default "选项" "1" bc
  local backup_root=""
  case "${bc:-1}" in
    2) backup_root="/tmp" ;;
    3)
      local custom_dir=""
      read_default "请输入目录路径" "$HOME" custom_dir
      backup_root="${custom_dir:-$HOME}"
      ;;
    *) backup_root="$HOME" ;;
  esac
  if ! mkdir -p "$backup_root" 2>/dev/null || ! touch "$backup_root/.wtest" 2>/dev/null; then
    err "目录 $backup_root 不可写" >&2
    return 1
  fi
  rm -f "$backup_root/.wtest"
  logi "备份目录：$backup_root" >&2
  echo "$backup_root"
}

_scan_backup_files(){
  local scan_dirs=("$HOME" "/tmp" "/root" "/mnt" "/data")
  for d in "${scan_dirs[@]}"; do
    [[ -d "$d" ]] || continue
    find "$d" -maxdepth 3 \
      -name "lucky-backup-*.tar.gz" \
      2>/dev/null
  done | sort -ru
}

backup_lucky(){
  echo ""
  echo "===== Lucky 数据备份 ====="

  local target_dir=""
  local mode_label=""

  if [[ -d "$DOCKER_CONFIG_DIR" && -n "$(ls -A "$DOCKER_CONFIG_DIR" 2>/dev/null)" ]]; then
    target_dir="$DOCKER_CONFIG_DIR"
    mode_label="Docker 配置目录"
  elif [[ -d "$LUCKY_DATA_DIR" && -n "$(ls -A "$LUCKY_DATA_DIR" 2>/dev/null)" ]]; then
    target_dir="$LUCKY_DATA_DIR"
    mode_label="原生数据目录"
  else
    warn "未找到可备份的数据目录（Docker: $DOCKER_CONFIG_DIR，原生: $LUCKY_DATA_DIR）"
    press_any; return
  fi

  local fc; fc=$(find "$target_dir" -type f 2>/dev/null | wc -l || echo 0)
  logi "备份源：$target_dir（$mode_label，共 $fc 个文件）"

  local avail_kb
  avail_kb=$(df -k "$HOME" 2>/dev/null | awk 'NR==2{print $4}' || echo 999999)
  if [[ "$avail_kb" -lt 51200 ]]; then
    warn "磁盘可用空间不足（${avail_kb}KB）"
    local go=false
    read_yesno_default "是否继续？" "N" go
    [[ "$go" == "true" ]] || return
  fi

  local backup_root
  backup_root=$(_select_backup_root) || return 1

  local stamp; stamp=$(date +%Y%m%d_%H%M%S)
  local backup_name="lucky-backup-${stamp}"
  local backup_tmp="${backup_root}/${backup_name}"
  local backup_file="${backup_root}/${backup_name}.tar.gz"

  mkdir -p "$backup_tmp"

  logi "暂停容器/服务以确保数据一致性..."
  local was_running_docker=false
  local was_running_native=false

  if have docker && docker_container_exists; then
    local cs; cs=$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "")
    if [[ "$cs" == "running" ]]; then
      was_running_docker=true
      docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi
  fi

  if have systemctl && systemctl is-active lucky &>/dev/null; then
    was_running_native=true
    systemctl stop lucky >/dev/null 2>&1 || true
  fi

  logi "复制数据..."
  mkdir -p "$backup_tmp/data"
  if ! cp -a "$target_dir/." "$backup_tmp/data/" 2>/dev/null; then
    err "数据复制失败"
    [[ "$was_running_docker" == true ]] && docker start "$CONTAINER_NAME" >/dev/null 2>&1 || true
    [[ "$was_running_native" == true ]] && systemctl start lucky >/dev/null 2>&1 || true
    rm -rf "$backup_tmp"
    return 1
  fi

  local cur_image="" docker_port="" native_ver=""
  if have docker && docker_container_exists; then
    cur_image=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null || echo "")
    docker_port=$(_get_docker_port)
  fi
  if [[ -f "$LUCKY_INSTALL_DIR/lucky" ]]; then
    native_ver=$("$LUCKY_INSTALL_DIR/lucky" -v 2>/dev/null | head -n1 || echo "未知")
  fi

  cat > "$backup_tmp/backup_info.txt" << EOF
备份时间：$(date '+%Y-%m-%d %H:%M:%S')
主机名：$(hostname)
系统架构：$(uname -m)
备份模式：${mode_label}
数据目录：${target_dir}
Docker镜像：${cur_image}
Docker端口：${docker_port}
原生版本：${native_ver}
EOF

  logi "恢复运行状态..."
  [[ "$was_running_docker" == true ]] && { docker start "$CONTAINER_NAME" >/dev/null 2>&1 && ok "容器已恢复" || warn "请手动启动容器"; }
  [[ "$was_running_native" == true ]] && { systemctl start lucky >/dev/null 2>&1 && ok "服务已恢复" || warn "请手动启动服务"; }

  logi "打包压缩中..."
  if tar -czf "$backup_file" -C "$backup_root" "$backup_name" 2>/dev/null; then
    rm -rf "$backup_tmp"
    local size; size=$(du -sh "$backup_file" 2>/dev/null | cut -f1 || echo "未知")
    ok "备份完成：$backup_file（$size）"
    echo ""
    echo "  备份文件：$backup_file"
    echo "  文件大小：$size"
    echo "  请将备份文件复制到安全位置（U盘/NAS/云盘）"
  else
    err "打包失败，临时目录保留在：$backup_tmp"
    return 1
  fi
  press_any
}

restore_lucky(){
  echo ""
  echo "===== Lucky 数据恢复 ====="
  echo "  1. 自动扫描列出备份文件"
  echo "  2. 手动输入备份文件路径"
  local sc=""
  read_default "选项" "1" sc

  local backup_file=""
  case "${sc:-1}" in
    2)
      read_default "备份文件路径" "" backup_file
      ;;
    *)
      echo ""
      logi "正在扫描备份文件..."
      local found_files=()
      while IFS= read -r f; do
        found_files+=("$f")
      done < <(_scan_backup_files)

      if [[ ${#found_files[@]} -eq 0 ]]; then
        warn "未找到备份文件"
        read_default "请手动输入备份文件路径" "" backup_file
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
        local fc=""
        read_default "输入编号（留空手动输入路径）" "" fc
        if [[ -z "$fc" ]]; then
          read_default "备份文件路径" "" backup_file
        elif [[ "$fc" =~ ^[0-9]+$ ]] && [[ "$fc" -ge 1 && "$fc" -le ${#found_files[@]} ]]; then
          backup_file="${found_files[$((fc-1))]}"
        else
          err "无效选项"; press_any; return 1
        fi
      fi
      ;;
  esac

  if [[ -z "$backup_file" || ! -f "$backup_file" ]]; then
    err "备份文件不存在：$backup_file"
    press_any; return 1
  fi
  logi "使用备份文件：$backup_file"

  local restore_tmp="/tmp/lucky_restore_$$"
  mkdir -p "$restore_tmp"

  logi "解压备份文件..."
  if ! tar -xzf "$backup_file" -C "$restore_tmp" 2>/dev/null; then
    err "解压失败，文件可能已损坏"
    rm -rf "$restore_tmp"; press_any; return 1
  fi

  local restore_info
  restore_info=$(find "$restore_tmp" -maxdepth 3 -name "backup_info.txt" | head -n1)
  if [[ -z "$restore_info" ]]; then
    err "备份包格式不正确，未找到 backup_info.txt"
    rm -rf "$restore_tmp"; press_any; return 1
  fi
  local restore_base; restore_base=$(dirname "$restore_info")

  echo ""
  echo "---- 备份信息 ----"
  cat "$restore_base/backup_info.txt"
  echo "------------------"
  echo ""

  local confirm=false
  read_yesno_default "确认恢复？（将覆盖现有数据）" "N" confirm
  [[ "$confirm" == "true" ]] || { logi "已取消"; rm -rf "$restore_tmp"; press_any; return 0; }

  if [[ ! -d "$restore_base/data" ]]; then
    err "备份包中无 data 目录，备份可能不完整"
    rm -rf "$restore_tmp"; press_any; return 1
  fi

  local backup_mode=""
  backup_mode=$(grep "^备份模式：" "$restore_base/backup_info.txt" | cut -d'：' -f2- || echo "")

  local target_dir="$DOCKER_CONFIG_DIR"
  if echo "$backup_mode" | grep -q "原生"; then
    target_dir="$LUCKY_DATA_DIR"
  fi

  logi "停止服务..."
  if have docker && docker_container_exists; then
    docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
  if have systemctl; then
    systemctl stop lucky >/dev/null 2>&1 || true
  fi

  if [[ -d "$target_dir" ]]; then
    local bak_old="${target_dir}_old_$(date +%Y%m%d_%H%M%S)"
    mv "$target_dir" "$bak_old" 2>/dev/null \
      && logi "旧数据目录已保留：$bak_old" \
      || { err "无法移动旧数据目录"; rm -rf "$restore_tmp"; press_any; return 1; }
  fi

  mkdir -p "$target_dir"
  if cp -a "$restore_base/data/." "$target_dir/" 2>/dev/null; then
    local rfc; rfc=$(find "$target_dir" -type f 2>/dev/null | wc -l || echo 0)
    ok "数据恢复完成（$rfc 个文件）"
  else
    err "数据恢复失败"
    rm -rf "$restore_tmp"; press_any; return 1
  fi

  rm -rf "$restore_tmp"

  logi "尝试重新启动..."
  if have docker && docker_container_exists; then
    docker start "$CONTAINER_NAME" >/dev/null 2>&1 \
      && ok "容器已启动" \
      || warn "请手动启动：docker start $CONTAINER_NAME"
  elif have systemctl && [[ -f "$LUCKY_SERVICE" ]]; then
    systemctl start lucky >/dev/null 2>&1 \
      && ok "服务已启动" \
      || warn "请手动启动：systemctl start lucky"
  else
    warn "请通过菜单重新部署（数据目录已恢复）"
  fi

  ok "恢复完成"
  press_any
}

list_backups(){
  echo ""
  echo "---- Lucky 备份文件列表 ----"
  local found=false
  while IFS= read -r f; do
    local sz; sz=$(du -sh "$f" 2>/dev/null | cut -f1 || echo "?")
    local ts; ts=$(echo "$f" | grep -oE '[0-9]{8}_[0-9]{6}' | \
      sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)_\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3 \4:\5:\6/' || echo "")
    printf "  %-52s [%s] %s\n" "$f" "$sz" "$ts"
    found=true
  done < <(_scan_backup_files)
  [[ "$found" == false ]] && warn "未找到任何备份文件"
  echo "---------------------------"
  press_any
}

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
  need_root || return 1
  mkdir -p "$LUCKY_DATA_DIR"
  ensure_lucky_user || true
  chown -R lucky:lucky "$LUCKY_DATA_DIR" >/dev/null 2>&1 || true
  mkdir -p "$LUCKY_INSTALL_DIR"
  chown -R lucky:lucky "$LUCKY_INSTALL_DIR" >/dev/null 2>&1 || true
  chmod 755 "$LUCKY_DATA_DIR" "$LUCKY_INSTALL_DIR"
  selinux_enforcing && { restorecon_dir "$LUCKY_DATA_DIR"; restorecon_dir "$LUCKY_INSTALL_DIR"; }
  ok "目录权限就绪"
}

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
  need_root || return 1
  systemctl stop lucky >/dev/null 2>&1 || true
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

  warn "仍失败，启用 root 兜底（兼容模式）..."
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
  need_root || return 1
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
  need_root || return 1
  local backup_dir="/root/lucky_backup_$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$backup_dir"
  warn "备份并清空数据目录：$LUCKY_DATA_DIR"
  tar -czf "$backup_dir/lucky_data.tgz" -C "$(dirname "$LUCKY_DATA_DIR")" "$(basename "$LUCKY_DATA_DIR")" 2>/dev/null || true
  find "${LUCKY_DATA_DIR}" -mindepth 1 -delete 2>/dev/null || true
  ensure_data_dir_ready
  ok "清理完成（备份：$backup_dir）"
}

get_native_versions_list(){
  local raw=""
  for url in "${GH_API_MIRRORS[@]}"; do
    raw="$(curl -sL -m 15 --connect-timeout 8 "${url}?per_page=50" 2>/dev/null || true)"
    echo "$raw" | grep -q '"tag_name"' && break
    raw=""
  done
  [[ -z "$raw" ]] && return 1
  if have jq; then
    echo "$raw" | jq -r '.[].tag_name' | head -n 20
  else
    echo "$raw" | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' | sed -E 's/.*"([^"]+)".*/\1/' | head -n 20
  fi
}

choose_native_version(){
  NATIVE_VERSION=""
  logi "获取 GitHub 版本列表..."
  local versions=() vlist; vlist="$(get_native_versions_list || true)"
  if [[ -n "$vlist" ]]; then
    mapfile -t versions < <(printf "%s\n" "$vlist")
  fi
  if [[ "${#versions[@]}" -eq 0 ]]; then
    warn "获取版本列表失败，使用预置版本"
    versions=("v2.27.2" "v2.26.2" "v2.20.2" "v2.19.5" "v2.18.1")
  fi
  local default_ver="${versions[0]}"
  echo "选择版本（回车默认最新：${default_ver}）"
  local i
  for i in "${!versions[@]}"; do
    echo "  $((i+1))) ${versions[$i]}"
  done
  local manual_idx=$(( ${#versions[@]} + 1 ))
  echo "  ${manual_idx}) 手动输入"
  local c=""
  read_default "编号" "1" c
  if [[ "$c" =~ ^[0-9]+$ ]] && [[ "$c" -ge 1 && "$c" -le "${#versions[@]}" ]]; then
    NATIVE_VERSION="${versions[$((c-1))]}"
  elif [[ "$c" == "$manual_idx" ]]; then
    read_default "输入版本号（如 v2.27.2）" "$default_ver" NATIVE_VERSION
    [[ "$NATIVE_VERSION" =~ ^v ]] || NATIVE_VERSION="v${NATIVE_VERSION}"
  else
    NATIVE_VERSION="$default_ver"
  fi
  ok "选择版本：$NATIVE_VERSION"
}

safe_version_guard(){
  local ver="${1:-}"
  [[ -n "$ver" ]] || { err "版本号为空"; return 1; }
  [[ "$ver" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { err "版本号格式不合法：${ver}"; return 1; }
}

build_download_urls(){
  local version="$1"
  safe_version_guard "$version" || return 1
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
  local dest="$1"
  logi "下载目标：${LUCKY_FILENAME}"
  for url in "${DOWNLOAD_URLS[@]}"; do
    logi "尝试：${url}"
    if curl -L --progress-bar --connect-timeout 15 --max-time 600 --fail -o "$dest" "$url" 2>/dev/null; then
      local sz; sz="$(stat -c%s "$dest" 2>/dev/null || echo 0)"
      if (( sz > 1024 )); then return 0; fi
      warn "文件大小异常，换源重试"
      rm -f "$dest"
    fi
  done
  return 1
}

install_or_reinstall_native(){
  echo ""
  echo "===== 原生版安装/重装 ====="
  need_root || return 1
  detect_arch
  choose_native_version
  safe_version_guard "${NATIVE_VERSION:-}" || { press_any; return 1; }
  build_download_urls "$NATIVE_VERSION" || { press_any; return 1; }
  migrate_legacy_data_if_needed
  ensure_data_dir_ready

  local tmp; tmp="$(mktemp -d)"
  if ! download_file "$tmp/$LUCKY_FILENAME"; then
    warn "下载失败，请检查网络或选择其他版本"
    rm -rf "$tmp"
    press_any; return 1
  fi
  if ! tar -xzf "$tmp/$LUCKY_FILENAME" -C "$tmp"; then
    warn "解压失败"
    rm -rf "$tmp"
    press_any; return 1
  fi

  local bin; bin="$(find "$tmp" -name lucky -type f | head -n1 || true)"
  if [[ -z "$bin" ]]; then
    warn "未找到 lucky 二进制"
    rm -rf "$tmp"
    press_any; return 1
  fi

  mkdir -p "$LUCKY_INSTALL_DIR"
  cp -f "$bin" "$LUCKY_INSTALL_DIR/lucky"
  chmod +x "$LUCKY_INSTALL_DIR/lucky"
  chown -R lucky:lucky "$LUCKY_INSTALL_DIR" >/dev/null 2>&1 || true
  ln -sf "$LUCKY_INSTALL_DIR/lucky" "$LUCKY_BIN"
  rm -rf "$tmp"
  ok "二进制就绪：$LUCKY_INSTALL_DIR/lucky"

  if start_native_auto; then
    local ip; ip="$(get_host_ip)"
    local run_user; run_user="$(systemctl show lucky -p User --value 2>/dev/null || echo unknown)"
    echo ""
    ok "访问地址：http://${ip}:${CONTAINER_PORT_DEFAULT}"
    ok "运行用户：${run_user}"
    warn "首次登录请立即修改默认账号/密码。"
  else
    warn "启动失败，请查看日志：journalctl -u lucky -n 200"
  fi
  press_any
}

native_menu(){
  while true; do
    local native_status; native_status=$(_get_native_status)
    echo ""
    echo "===== 原生版管理 [$native_status] ====="
    echo "  1. 安装/重装原生版"
    echo "  2. 启动服务"
    echo "  3. 停止服务"
    echo "  4. 重启服务"
    echo "  5. 查看实时日志 (Ctrl+C 退出)"
    echo "  6. 查看最近 200 行日志"
    echo "  7. 修复：备份并清空数据目录后重启"
    echo "  0. 返回主菜单"
    echo "======================================="
    local c=""
    read_default "选择" "0" c
    case "$c" in
      1) install_or_reinstall_native ;;
      2)
        need_root || { press_any; continue; }
        systemctl start lucky \
          && ok "已启动" \
          || { warn "启动失败，日志：journalctl -u lucky -n 30"; }
        press_any
        ;;
      3)
        need_root || { press_any; continue; }
        systemctl stop lucky \
          && ok "已停止" \
          || warn "停止失败"
        press_any
        ;;
      4)
        need_root || { press_any; continue; }
        systemctl restart lucky \
          && ok "已重启" \
          || { warn "重启失败，日志：journalctl -u lucky -n 30"; }
        press_any
        ;;
      5)
        journalctl -u lucky -f --no-pager 2>/dev/null || warn "journalctl 不可用"
        ;;
      6)
        journalctl -u lucky --no-pager -n 200 2>/dev/null || warn "journalctl 不可用"
        press_any
        ;;
      7)
        need_root || { press_any; continue; }
        systemctl stop lucky >/dev/null 2>&1 || true
        cleanup_data_with_backup
        start_native_auto || true
        press_any
        ;;
      0) return 0 ;;
      *) warn "无效选择" ;;
    esac
  done
}

show_status(){
  echo ""
  echo "===== 当前状态 ====="
  echo ""
  echo "-- Docker --"
  if have docker && docker_container_exists; then
    docker ps -a --filter "name=^/${CONTAINER_NAME}$" --format "  容器: {{.Names}}  状态: {{.Status}}  端口: {{.Ports}}"
    echo "  配置目录：$DOCKER_CONFIG_DIR"
  else
    echo "  未部署（或 Docker 不可用）"
  fi
  echo ""
  echo "-- 原生版 --"
  if [[ -f "$LUCKY_INSTALL_DIR/lucky" ]]; then
    echo "  二进制：$LUCKY_INSTALL_DIR/lucky"
    local run_user; run_user="$(systemctl show lucky -p User --value 2>/dev/null || echo unknown)"
    systemctl is-active lucky &>/dev/null && echo "  服务：运行中" || echo "  服务：未运行"
    echo "  运行用户：${run_user}"
    echo "  数据目录：$LUCKY_DATA_DIR"
  else
    echo "  未安装"
  fi
  echo "===================="
  press_any
}

purge_everything(){
  echo ""
  echo "===== PURGE 完全清理 ====="
  need_root || return 1
  echo "将删除：容器/镜像/原生二进制/systemd/数据目录（新旧）"
  local go=false
  read_yesno_default "确认立即执行 PURGE？" "N" go
  [[ "$go" == "true" ]] || { warn "已取消"; press_any; return; }

  if have docker; then
    docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
    local ids; ids="$(docker images --format '{{.Repository}} {{.ID}}' | awk -v img="$IMAGE_NAME" '$1==img{print $2}' | sort -u || true)"
    [[ -n "$ids" ]] && echo "$ids" | xargs -r docker rmi -f >/dev/null 2>&1 || true
  fi

  systemctl stop lucky >/dev/null 2>&1 || true
  systemctl disable lucky >/dev/null 2>&1 || true
  rm -f "$LUCKY_SERVICE" "$LUCKY_BIN"
  rm -rf "$LUCKY_INSTALL_DIR"
  systemctl daemon-reload >/dev/null 2>&1 || true

  rm -rf "$LUCKY_DATA_DIR" "$LUCKY_DATA_DIR_LEGACY"

  local del_bk=false
  read_yesno_default "是否删除历史备份文件？" "N" del_bk
  if [[ "$del_bk" == "true" ]]; then
    find /root -maxdepth 1 -name 'lucky_backup_*' -exec rm -rf {} + 2>/dev/null || true
    _scan_backup_files | while IFS= read -r f; do
      rm -f "$f" 2>/dev/null || true
    done
  fi

  local del_user=false
  read_yesno_default "是否删除系统用户/组 lucky？" "N" del_user
  if [[ "$del_user" == "true" ]]; then
    userdel lucky >/dev/null 2>&1 || true
    groupdel lucky >/dev/null 2>&1 || true
  fi

  ok "PURGE 完成"
  press_any
}

main_menu(){
  local docker_status; docker_status=$(_get_docker_status)
  local native_status; native_status=$(_get_native_status)
  local docker_port; docker_port=$(_get_docker_port)

  echo ""
  echo "========== $SCRIPT_NAME v$SCRIPT_VERSION =========="
  echo "  Docker  : $docker_status${docker_port:+  ($docker_port)}"
  echo "  原生版  : $native_status"
  echo "--------------------------------------------"
  echo "  [Docker 模式]"
  echo "  1. 部署容器"
  echo "  2. 更新容器"
  echo "  3. 管理容器（启动/停止/重启/日志）"
  echo "  4. 卸载容器"
  echo ""
  echo "  [原生模式]"
  echo "  5. 原生版管理"
  echo ""
  echo "  [备份/恢复]"
  echo "  6. 备份数据"
  echo "  7. 恢复数据"
  echo "  8. 查看备份列表"
  echo ""
  echo "  [维护]"
  echo "  9. 查看状态"
  echo " 10. 开启/修复 IPv6"
  echo " 11. PURGE 完全清理"
  echo "  0. 退出"
  echo "============================================"
}

main(){
  ensure_pkg_tools
  while true; do
    main_menu
    local c=""
    read_default "选择" "0" c
    case "$c" in
      1) deploy_docker ;;
      2) upgrade_docker ;;
      3)
        if have docker && docker_container_exists; then
          manage_docker_container
        else
          warn "未部署，请先部署容器"
          press_any
        fi
        ;;
      4) uninstall_docker ;;
      5) native_menu ;;
      6) backup_lucky ;;
      7) restore_lucky ;;
      8) list_backups ;;
      9) show_status ;;
      10) enable_ipv6_auto ;;
      11) purge_everything ;;
      0) ok "再见"; exit 0 ;;
      *) warn "无效选择" ;;
    esac
  done
}

main
