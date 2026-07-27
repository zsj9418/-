#!/bin/bash
set -uo pipefail
trap 'echo "[!] 已中断"; exit 1' INT

SCRIPT_VERSION="2.0"
ADG_IMAGE_BASE="adguard/adguardhome"
ADG_IMAGE_GHCR="ghcr.io/adguardteam/adguardhome"
DEFAULT_SAVE_PATH="/opt/docker"
save_path="$DEFAULT_SAVE_PATH"
CONTAINER_PREFIX="adguardhome"
RETRY_COUNT=3

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

_have() { command -v "$1" >/dev/null 2>&1; }

if [[ "${EUID}" -ne 0 ]]; then
  _err "请以 root 权限运行此脚本"
  exit 1
fi

ensure_docker_running() {
  if ! _have docker; then
    _err "Docker 未安装，请先安装 Docker"
    return 1
  fi
  if ! docker info >/dev/null 2>&1; then
    _warn "Docker 未运行，尝试启动..."
    if _have systemctl; then
      systemctl start docker >/dev/null 2>&1 || true
    fi
    sleep 3
    if ! docker info >/dev/null 2>&1; then
      _err "Docker 无法启动，请手动检查"
      return 1
    fi
  fi
  return 0
}

pull_image() {
  local image_name="$1"
  _info "拉取镜像：$image_name"

  for prefix in "${GH_MIRRORS[@]}"; do
    local pull_target
    if [[ -z "$prefix" ]]; then
      pull_target="$image_name"
      _info "尝试直连 Docker Hub..."
    else
      if [[ "$image_name" == ghcr.io/* ]]; then
        pull_target="$image_name"
      else
        pull_target="${prefix}${image_name}"
      fi
      _info "尝试加速源：$prefix"
    fi

    local attempt=1
    while [[ $attempt -le $RETRY_COUNT ]]; do
      if docker pull "$pull_target" >/dev/null 2>&1; then
        if [[ "$pull_target" != "$image_name" ]]; then
          docker tag "$pull_target" "$image_name" >/dev/null 2>&1 || true
        fi
        _ok "镜像拉取成功：$image_name"
        return 0
      fi
      _warn "第 $attempt/$RETRY_COUNT 次失败，重试..."
      sleep 2
      attempt=$((attempt + 1))
    done
  done

  _err "所有镜像源均拉取失败"
  return 1
}

validate_port() {
  local port="$1"
  if ! [[ "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 || "$port" -gt 65535 ]]; then
    return 1
  fi
  return 0
}

validate_abs_path() {
  local path="$1"
  [[ "$path" == /* ]]
}

_get_container_status() {
  local num="$1"
  local cname="${CONTAINER_PREFIX}${num}"
  if ! _have docker || ! docker info >/dev/null 2>&1; then
    echo "Docker未运行"
    return
  fi
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${cname}$"; then
    local port; port=$(docker port "$cname" 3000/tcp 2>/dev/null | head -n1 | grep -oE '[0-9]+$' || echo "")
    echo "运行中${port:+  [管理端口 $port]}"
  elif docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${cname}$"; then
    echo "已停止"
  else
    echo "未创建"
  fi
}

set_save_path() {
  while true; do
    echo ""
    echo "===== 设定容器存储路径 ====="
    _info "当前路径：$save_path"
    echo "  1. 使用当前路径（$save_path）"
    echo "  2. 查看磁盘并手动输入新路径"
    echo "  0. 返回"
    read -rp "请输入选项: " opt </dev/tty

    case "$opt" in
      1)
        _ok "已确认使用路径：$save_path"
        press_any_key; return
        ;;
      2)
        df -h
        echo ""
        while true; do
          read -rp "请输入绝对路径（以 / 开头）: " new_path </dev/tty
          if [[ -z "$new_path" ]]; then
            _warn "路径不能为空"; continue
          fi
          if ! validate_abs_path "$new_path"; then
            _warn "路径必须以 / 开头"; continue
          fi
          if ! mkdir -p "$new_path" 2>/dev/null; then
            _warn "无法创建路径：$new_path"; continue
          fi
          save_path="$new_path"
          _ok "路径已设定为：$save_path"
          break
        done
        press_any_key; return
        ;;
      0) return ;;
      *) _warn "无效选项" ;;
    esac
  done
}

workdir_menu() {
  local adg_idx="$1"
  while true; do
    echo ""
    echo "===== 工作目录管理 [ADG${adg_idx}] ====="
    local wd="${save_path}/adg/workdir${adg_idx}"
    local cd="${save_path}/adg/confdir${adg_idx}"
    echo "  workdir：$wd $([ -d "$wd" ] && echo '✓ 已存在' || echo '✗ 不存在')"
    echo "  confdir：$cd $([ -d "$cd" ] && echo '✓ 已存在' || echo '✗ 不存在')"
    echo ""
    echo "  1. 创建工作目录"
    echo "  2. 导出工作目录"
    echo "  3. 删除工作目录"
    echo "  0. 返回"
    read -rp "请输入选项: " opt </dev/tty

    case "$opt" in
      1)
        if [[ -d "$wd" || -d "$cd" ]]; then
          _warn "工作目录已存在，无需重复创建"
          press_any_key; continue
        fi
        mkdir -p "${save_path}/adg"
        if mkdir -p "$wd" && mkdir -p "$cd"; then
          _ok "工作目录创建成功"
          ls "${save_path}/adg/"
        else
          _err "工作目录创建失败"
        fi
        press_any_key
        ;;
      2)
        if [[ ! -d "$wd" ]]; then
          _warn "工作目录不存在，无法导出"; press_any_key; continue
        fi
        du -sh "${save_path}/adg/" 2>/dev/null || true
        df -h
        echo ""
        while true; do
          read -rp "请输入导出目标路径（绝对路径）: " export_path </dev/tty
          if ! validate_abs_path "$export_path"; then
            _warn "路径必须以 / 开头"; continue
          fi
          break
        done
        read -rp "确认导出到 $export_path？(y/N): " confirm </dev/tty
        if [[ "${confirm,,}" == "y" ]]; then
          mkdir -p "${export_path}/adg"
          if cp -r "$wd" "${export_path}/adg/" && cp -r "$cd" "${export_path}/adg/"; then
            _ok "导出完成"
            ls "${export_path}/adg/"
          else
            _err "导出失败"
          fi
        else
          _warn "已取消"
        fi
        press_any_key
        ;;
      3)
        if [[ ! -d "$wd" && ! -d "$cd" ]]; then
          _warn "工作目录不存在"; press_any_key; continue
        fi
        _warn "删除后 ADG${adg_idx} 配置将永久丢失！"
        read -rp "确认删除？(输入 yes 确认): " confirm </dev/tty
        if [[ "$confirm" == "yes" ]]; then
          rm -rf "$wd" "$cd" && _ok "已删除工作目录" || _err "删除失败"
        else
          _warn "已取消"
        fi
        press_any_key
        ;;
      0) return ;;
      *) _warn "无效选项" ;;
    esac
  done
}

build_adg() {
  local adg_idx="$1"
  local cname="${CONTAINER_PREFIX}${adg_idx}"
  local wd="${save_path}/adg/workdir${adg_idx}"
  local cd_path="${save_path}/adg/confdir${adg_idx}"

  if [[ ! -d "$wd" || ! -d "$cd_path" ]]; then
    _err "工作目录不存在，请先创建工作目录"
    return 1
  fi

  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${cname}$"; then
    _warn "容器 $cname 已存在，请先删除再创建"
    return 1
  fi

  echo ""
  echo "===== 创建 ADG${adg_idx} 容器 ====="

  echo "请选择镜像源："
  echo "  1. ghcr.io/adguardteam/adguardhome（GitHub，推荐）"
  echo "  2. adguard/adguardhome（Docker Hub）"
  read -rp "选项 [默认 1]: " src_choice </dev/tty
  local selected_image
  case "${src_choice:-1}" in
    2) selected_image="${ADG_IMAGE_BASE}:latest" ;;
    *) selected_image="${ADG_IMAGE_GHCR}:latest" ;;
  esac
  _info "使用镜像：$selected_image"

  local mgmt_port=3000
  local dns_port=53
  local http_port=80
  local https_port=443

  echo ""
  _info "配置端口映射（bridge 模式）"
  while true; do
    read -rp "管理页面端口 [默认 $mgmt_port]: " p </dev/tty
    p="${p:-$mgmt_port}"
    if validate_port "$p"; then mgmt_port="$p"; break
    else _warn "端口无效，请输入 1-65535 之间的数字"; fi
  done

  while true; do
    read -rp "DNS 监听端口 [默认 $dns_port]: " p </dev/tty
    p="${p:-$dns_port}"
    if validate_port "$p"; then dns_port="$p"; break
    else _warn "端口无效"; fi
  done

  while true; do
    read -rp "HTTP 端口 [默认 $http_port]: " p </dev/tty
    p="${p:-$http_port}"
    if validate_port "$p"; then http_port="$p"; break
    else _warn "端口无效"; fi
  done

  while true; do
    read -rp "HTTPS 端口 [默认 $https_port]: " p </dev/tty
    p="${p:-$https_port}"
    if validate_port "$p"; then https_port="$p"; break
    else _warn "端口无效"; fi
  done

  pull_image "$selected_image" || return 1

  _info "启动容器 $cname..."
  local run_result=0
  docker run --name "$cname" \
    -v "${wd}:/opt/adguardhome/work" \
    -v "${cd_path}:/opt/adguardhome/conf" \
    --restart=always \
    --network bridge \
    -p "${mgmt_port}:3000/tcp" \
    -p "${dns_port}:53/tcp" \
    -p "${dns_port}:53/udp" \
    -p "${http_port}:80/tcp" \
    -p "${https_port}:443/tcp" \
    -p "${https_port}:443/udp" \
    -d "$selected_image" || run_result=$?

  if [[ $run_result -ne 0 ]]; then
    _err "容器启动失败，请查看日志：docker logs $cname"
    return 1
  fi

  sleep 3
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${cname}$"; then
    _ok "容器 $cname 启动成功！"
    _info "首次使用请浏览器访问：http://<本机IP>:${mgmt_port}"
    _info "完成初始化设置后，DNS 服务将在端口 $dns_port 监听"
  else
    _err "容器启动后异常退出：docker logs $cname"
    return 1
  fi
}

del_adg() {
  local adg_idx="$1"
  local cname="${CONTAINER_PREFIX}${adg_idx}"

  if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${cname}$"; then
    _warn "容器 $cname 不存在，无需删除"
    return 0
  fi

  docker stop "$cname" >/dev/null 2>&1 && _ok "容器已停止" || _warn "停止失败（可能已停止）"
  docker rm "$cname" >/dev/null 2>&1 && _ok "容器已删除" || { _err "删除失败"; return 1; }
}

status_adg() {
  local adg_idx="$1"
  local cname="${CONTAINER_PREFIX}${adg_idx}"

  while true; do
    local svc_status; svc_status=$(_get_container_status "$adg_idx")
    echo ""
    echo "===== ADG${adg_idx} 容器操作 [${svc_status}] ====="
    echo "  1. 重启容器"
    echo "  2. 停止容器"
    echo "  3. 启动容器"
    echo "  4. 查看容器状态"
    echo "  5. 查看最近 100 行日志"
    echo "  6. 实时日志（Ctrl+C 退出）"
    echo "  0. 返回"
    read -rp "请输入选项: " opt </dev/tty

    case "$opt" in
      1)
        docker restart "$cname" >/dev/null 2>&1 \
          && _ok "容器已重启" || _err "重启失败"
        press_any_key
        ;;
      2)
        docker stop "$cname" >/dev/null 2>&1 \
          && _ok "容器已停止" || _err "停止失败"
        press_any_key
        ;;
      3)
        docker start "$cname" >/dev/null 2>&1 \
          && _ok "容器已启动" || _err "启动失败"
        press_any_key
        ;;
      4)
        echo ""
        docker ps -a --filter "name=^${cname}$" \
          --format "名称：{{.Names}}\n状态：{{.Status}}\n镜像：{{.Image}}\n端口：{{.Ports}}" \
          2>/dev/null || _warn "获取状态失败"
        press_any_key
        ;;
      5)
        echo ""
        docker logs --tail=100 "$cname" 2>&1 || _warn "获取日志失败"
        press_any_key
        ;;
      6)
        _info "实时日志（Ctrl+C 退出后返回菜单）..."
        docker logs -f --tail=50 "$cname" 2>&1 || true
        press_any_key
        ;;
      0) return ;;
      *) _warn "无效选项" ;;
    esac
  done
}

change_adg() {
  local adg_idx="$1"
  local cname="${CONTAINER_PREFIX}${adg_idx}"
  local conf_file="${save_path}/adg/confdir${adg_idx}/AdGuardHome.yaml"

  while true; do
    echo ""
    echo "===== ADG${adg_idx} 修改配置 ====="
    echo "  1. 修改管理端口"
    echo "  2. 修改 DNS 监听端口"
    echo "  3. 删除容器（保留数据）"
    echo "  4. 删除镜像"
    echo "  0. 返回"
    read -rp "请输入选项: " opt </dev/tty

    case "$opt" in
      1)
        if [[ ! -f "$conf_file" ]]; then
          _err "配置文件不存在：$conf_file"
          press_any_key; continue
        fi
        while true; do
          read -rp "请输入新管理端口（1-65535）: " port_num </dev/tty
          validate_port "$port_num" && break || _warn "端口无效"
        done
        if sed -i "s/^\(bind_port:\s*\).*/\1${port_num}/" "$conf_file"; then
          _ok "管理端口已修改为 $port_num，请重启容器生效"
        else
          _err "修改失败，请手动编辑：$conf_file"
        fi
        press_any_key
        ;;
      2)
        if [[ ! -f "$conf_file" ]]; then
          _err "配置文件不存在：$conf_file"
          press_any_key; continue
        fi
        while true; do
          read -rp "请输入新 DNS 监听端口（1-65535）: " port_num </dev/tty
          validate_port "$port_num" && break || _warn "端口无效"
        done
        if grep -q "^\s*port:" "$conf_file"; then
          sed -i "0,/^\(\s*port:\s*\).*/s//\1${port_num}/" "$conf_file"
          _ok "DNS 监听端口已修改为 $port_num，请重启容器生效"
        else
          _err "未在配置文件中找到 port 字段，请手动编辑：$conf_file"
        fi
        press_any_key
        ;;
      3)
        _warn "将删除容器 $cname（数据目录保留）"
        read -rp "确认删除？(y/N): " confirm </dev/tty
        if [[ "${confirm,,}" == "y" ]]; then
          del_adg "$adg_idx" || true
        else
          _warn "已取消"
        fi
        press_any_key
        ;;
      4)
        local images=()
        mapfile -t images < <(
          docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | \
          grep -E "^(adguard/adguardhome|ghcr\.io/adguardteam/adguardhome)" || true
        )
        if [[ ${#images[@]} -eq 0 ]]; then
          _warn "未找到 ADG 相关镜像"
          press_any_key; continue
        fi
        echo "检测到以下镜像："
        for img in "${images[@]}"; do echo "  $img"; done
        read -rp "确认删除？(y/N): " confirm </dev/tty
        if [[ "${confirm,,}" == "y" ]]; then
          for img in "${images[@]}"; do
            docker rmi "$img" >/dev/null 2>&1 && _ok "已删除：$img" || _warn "删除失败：$img"
          done
        else
          _warn "已取消"
        fi
        press_any_key
        ;;
      0) return ;;
      *) _warn "无效选项" ;;
    esac
  done
}

upgrade_adg() {
  local adg_idx="$1"
  local cname="${CONTAINER_PREFIX}${adg_idx}"

  echo ""
  echo "===== 更新 ADG${adg_idx} 容器 ====="

  if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${cname}$"; then
    _err "容器 $cname 不存在，请先创建"
    press_any_key; return 1
  fi

  _warn "更新将删除旧容器并用新镜像重建，数据目录保留"
  read -rp "建议先备份，确认继续更新？(y/N): " confirm </dev/tty
  [[ "${confirm,,}" == "y" ]] || { _warn "已取消"; press_any_key; return; }

  local cur_image
  cur_image=$(docker inspect --format='{{.Config.Image}}' "$cname" 2>/dev/null || echo "")
  _info "当前镜像：${cur_image:-未知}"

  local net_mode
  net_mode=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$cname" 2>/dev/null || echo "bridge")

  local old_binds=()
  mapfile -t old_binds < <(
    docker inspect "$cname" 2>/dev/null | \
    python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)[0]
    for b in d.get('HostConfig', {}).get('Binds', []):
        print(b)
except: pass
" 2>/dev/null || \
    docker inspect --format='{{range .HostConfig.Binds}}{{.}}{{println}}{{end}}' "$cname" 2>/dev/null || true
  )

  local old_ports=()
  mapfile -t old_ports < <(
    docker inspect "$cname" 2>/dev/null | \
    python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)[0]
    pb = d.get('HostConfig', {}).get('PortBindings', {})
    for cp, binds in pb.items():
        if binds:
            for b in binds:
                print(b.get('HostPort', '') + ':' + cp.split('/')[0] + '/' + cp.split('/')[1])
except: pass
" 2>/dev/null || true
  )

  local restart_policy
  restart_policy=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$cname" 2>/dev/null || echo "always")

  echo ""
  echo "请选择更新镜像源："
  echo "  1. ghcr.io/adguardteam/adguardhome（GitHub，推荐）"
  echo "  2. adguard/adguardhome（Docker Hub）"
  read -rp "选项 [默认 1]: " src_choice </dev/tty
  local new_image
  case "${src_choice:-1}" in
    2) new_image="${ADG_IMAGE_BASE}:latest" ;;
    *) new_image="${ADG_IMAGE_GHCR}:latest" ;;
  esac

  pull_image "$new_image" || { press_any_key; return 1; }

  _info "停止并删除旧容器..."
  del_adg "$adg_idx" || { press_any_key; return 1; }

  _info "使用新镜像重建容器..."
  local run_args=(
    docker run -d
    --name "$cname"
    --restart="${restart_policy:-always}"
    --network "${net_mode:-bridge}"
  )

  for bind in "${old_binds[@]}"; do
    [[ -n "$bind" ]] && run_args+=(-v "$bind")
  done

  for port in "${old_ports[@]}"; do
    [[ -n "$port" ]] && run_args+=(-p "$port")
  done

  run_args+=("$new_image")

  if "${run_args[@]}" >/dev/null 2>&1; then
    sleep 3
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${cname}$"; then
      _ok "ADG${adg_idx} 更新成功！"
    else
      _err "更新后容器异常退出：docker logs $cname"
    fi
  else
    _err "容器重建失败"
  fi

  press_any_key
}

backup_adg() {
  local adg_idx="$1"
  local cname="${CONTAINER_PREFIX}${adg_idx}"
  local src_dir="${save_path}/adg"

  echo ""
  echo "===== 备份 ADG${adg_idx} 数据 ====="

  if [[ ! -d "${src_dir}/workdir${adg_idx}" && ! -d "${src_dir}/confdir${adg_idx}" ]]; then
    _warn "工作目录不存在，无数据可备份"
    press_any_key; return
  fi

  echo ""
  echo "请选择备份保存位置："
  echo "  1. 主目录 ($HOME)"
  echo "  2. /tmp（重启后丢失）"
  echo "  3. 手动输入"
  read -rp "选项 [默认 1]: " bk_opt </dev/tty
  local bak_dir
  case "${bk_opt:-1}" in
    2) bak_dir="/tmp" ;;
    3)
      while true; do
        read -rp "请输入绝对路径: " bak_dir </dev/tty
        validate_abs_path "$bak_dir" && break || _warn "路径必须以 / 开头"
      done
      ;;
    *) bak_dir="$HOME" ;;
  esac

  if ! mkdir -p "$bak_dir" 2>/dev/null || ! touch "$bak_dir/.wtest" 2>/dev/null; then
    _err "目录不可写：$bak_dir"
    press_any_key; return 1
  fi
  rm -f "$bak_dir/.wtest"

  local stamp; stamp=$(date +%Y%m%d_%H%M%S)
  local bak_name="adg${adg_idx}-backup-${stamp}"
  local bak_tmp="${bak_dir}/${bak_name}"
  local bak_file="${bak_dir}/${bak_name}.tar.gz"

  mkdir -p "$bak_tmp"

  local was_running=false
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${cname}$"; then
    was_running=true
    _info "暂停容器以确保数据一致性..."
    docker stop "$cname" >/dev/null 2>&1 || true
  fi

  local backed=false
  for subdir in "workdir${adg_idx}" "confdir${adg_idx}"; do
    if [[ -d "${src_dir}/${subdir}" ]]; then
      if cp -a "${src_dir}/${subdir}" "$bak_tmp/"; then
        _ok "已备份：${subdir}"
        backed=true
      else
        _warn "备份失败：${subdir}"
      fi
    fi
  done

  local cur_image=""
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${cname}$"; then
    cur_image=$(docker inspect --format='{{.Config.Image}}' "$cname" 2>/dev/null || echo "未知")
  fi

  cat > "$bak_tmp/backup_info.txt" << EOF
备份时间：$(date '+%Y-%m-%d %H:%M:%S')
主机名：$(hostname)
ADG 编号：${adg_idx}
容器名：${cname}
镜像版本：${cur_image}
数据路径：${src_dir}
EOF

  if [[ "$was_running" == true ]]; then
    _info "恢复容器运行..."
    docker start "$cname" >/dev/null 2>&1 \
      && _ok "容器已恢复" || _warn "请手动启动：docker start $cname"
  fi

  if [[ "$backed" == false ]]; then
    rm -rf "$bak_tmp"
    _err "没有数据被备份"
    press_any_key; return 1
  fi

  _info "打包压缩中..."
  if tar -czf "$bak_file" -C "$bak_dir" "$bak_name" 2>/dev/null; then
    rm -rf "$bak_tmp"
    local size; size=$(du -sh "$bak_file" 2>/dev/null | cut -f1 || echo "未知")
    _ok "备份完成：$bak_file（$size）"
  else
    _err "打包失败，临时目录：$bak_tmp"
    press_any_key; return 1
  fi

  press_any_key
}

restore_adg() {
  local adg_idx="$1"
  local cname="${CONTAINER_PREFIX}${adg_idx}"
  local dst_dir="${save_path}/adg"

  echo ""
  echo "===== 恢复 ADG${adg_idx} 数据 ====="

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
          -name "adg${adg_idx}-backup-*.tar.gz" 2>/dev/null | sort -r || true
      )
      if [[ ${#found_files[@]} -eq 0 ]]; then
        _warn "未找到 ADG${adg_idx} 的备份文件"
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
    _err "解压失败"
    press_any_key; return 1
  fi

  local info_file; info_file=$(find "$restore_tmp" -name "backup_info.txt" | head -n1 || true)
  if [[ -n "$info_file" ]]; then
    echo ""
    echo "---- 备份信息 ----"
    cat "$info_file"
    echo "------------------"
  fi

  echo ""
  read -rp "确认恢复到 $dst_dir？(y/N): " confirm </dev/tty
  [[ "${confirm,,}" == "y" ]] || { _warn "已取消"; press_any_key; return; }

  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${cname}$"; then
    _info "停止容器..."
    docker stop "$cname" >/dev/null 2>&1 || true
  fi

  mkdir -p "$dst_dir"

  local restore_base; restore_base=$(dirname "${info_file:-$restore_tmp/x}")
  local restored=false

  for subdir in "workdir${adg_idx}" "confdir${adg_idx}"; do
    local src_subdir="${restore_base}/${subdir}"
    if [[ ! -d "$src_subdir" ]]; then
      _warn "备份中不含 $subdir，跳过"
      continue
    fi
    local dst_subdir="${dst_dir}/${subdir}"
    if [[ -d "$dst_subdir" ]]; then
      local bak_old="${dst_subdir}_old_$(date +%s)"
      mv "$dst_subdir" "$bak_old" 2>/dev/null && _info "旧目录保留：$bak_old"
    fi
    if cp -a "$src_subdir" "$dst_dir/"; then
      _ok "已恢复：$subdir"
      restored=true
    else
      _err "恢复失败：$subdir"
    fi
  done

  if [[ "$restored" == false ]]; then
    _err "没有数据被恢复"
    press_any_key; return 1
  fi

  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${cname}$"; then
    docker start "$cname" >/dev/null 2>&1 \
      && _ok "容器已启动" || _warn "请通过菜单手动启动容器"
  else
    _warn "容器不存在，请通过菜单重新创建（数据已恢复）"
  fi

  _ok "恢复完成"
  press_any_key
}

list_backups() {
  echo ""
  echo "---- ADG 备份文件列表 ----"
  local found=false
  while IFS= read -r f; do
    local sz; sz=$(du -sh "$f" 2>/dev/null | cut -f1 || echo "?")
    local ts; ts=$(echo "$f" | grep -oE '[0-9]{8}_[0-9]{6}' | \
      sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)_\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3 \4:\5:\6/' || echo "")
    printf "  %-52s [%s] %s\n" "$f" "$sz" "$ts"
    found=true
  done < <(
    find "$HOME" /tmp /root /mnt /data -maxdepth 3 \
      -name "adg*-backup-*.tar.gz" 2>/dev/null | sort -r || true
  )
  [[ "$found" == false ]] && _warn "未找到任何备份文件"
  echo "--------------------------"
  press_any_key
}

adg_container_menu() {
  local adg_idx="$1"
  local cname="${CONTAINER_PREFIX}${adg_idx}"

  while true; do
    local svc_status; svc_status=$(_get_container_status "$adg_idx")
    echo ""
    echo "===== ADG${adg_idx} 容器管理 [${svc_status}] ====="
    echo "  1. 创建容器"
    echo "  2. 更新容器"
    echo "  3. 查看/控制容器"
    echo "  4. 修改配置"
    echo "  5. 备份数据"
    echo "  6. 恢复数据"
    echo "  0. 返回"
    read -rp "请输入选项: " opt </dev/tty

    case "$opt" in
      1)
        ensure_docker_running || { press_any_key; continue; }
        build_adg "$adg_idx" || true
        press_any_key
        ;;
      2)
        ensure_docker_running || { press_any_key; continue; }
        upgrade_adg "$adg_idx"
        ;;
      3)
        ensure_docker_running || { press_any_key; continue; }
        status_adg "$adg_idx"
        ;;
      4)
        change_adg "$adg_idx"
        ;;
      5)
        backup_adg "$adg_idx"
        ;;
      6)
        restore_adg "$adg_idx"
        ;;
      0) return ;;
      *) _warn "无效选项" ;;
    esac
  done
}

adg_select_menu() {
  while true; do
    local s1; s1=$(_get_container_status 1)
    local s2; s2=$(_get_container_status 2)
    echo ""
    echo "===== 选择 ADG 实例 ====="
    echo "  1. AdGuardHome 1  [$s1]"
    echo "  2. AdGuardHome 2  [$s2]"
    echo "  0. 返回"
    read -rp "请输入选项: " opt </dev/tty

    case "$opt" in
      1) adg_container_menu 1 ;;
      2) adg_container_menu 2 ;;
      0) return ;;
      *) _warn "无效选项" ;;
    esac
  done
}

workdir_select_menu() {
  while true; do
    echo ""
    echo "===== 选择工作目录 ====="
    echo "  1. ADG 1 工作目录"
    echo "  2. ADG 2 工作目录"
    echo "  0. 返回"
    read -rp "请输入选项: " opt </dev/tty

    case "$opt" in
      1) workdir_menu 1 ;;
      2) workdir_menu 2 ;;
      0) return ;;
      *) _warn "无效选项" ;;
    esac
  done
}

_init_save_path() {
  while true; do
    echo ""
    _info "请设定容器数据存储路径"
    read -rp "路径 [默认: $DEFAULT_SAVE_PATH]: " input_path </dev/tty
    local candidate="${input_path:-$DEFAULT_SAVE_PATH}"

    if ! validate_abs_path "$candidate"; then
      _warn "路径必须以 / 开头"; continue
    fi

    if ! mkdir -p "$candidate" 2>/dev/null; then
      _warn "无法创建路径：$candidate"; continue
    fi

    save_path="$candidate"
    _ok "存储路径已设定：$save_path"
    break
  done
}

_init_save_path

while true; do
  local_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' | head -n1 || \
             hostname -I 2>/dev/null | awk '{print $1}' || echo "<本机IP>")
  s1=$(_get_container_status 1)
  s2=$(_get_container_status 2)

  echo ""
  echo "========== ADG 管理脚本 v${SCRIPT_VERSION} =========="
  echo "  存储路径：$save_path    本机IP：$local_ip"
  echo "  ADG 1：$s1"
  echo "  ADG 2：$s2"
  echo "  网络模式：bridge（端口映射）"
  echo "-------------------------------------------"
  echo "  1. 修改存储路径"
  echo "  2. 管理工作目录"
  echo "  3. 管理 ADG 容器"
  echo "  4. 查看备份列表"
  echo "  0. 退出"
  echo "==========================================="
  read -rp "请输入选项: " choice </dev/tty

  case "$choice" in
    1) set_save_path ;;
    2) workdir_select_menu ;;
    3) adg_select_menu ;;
    4) list_backups ;;
    0) _ok "退出脚本"; exit 0 ;;
    *) _warn "无效选项，请输入 0-4" ;;
  esac
done
