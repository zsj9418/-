#!/bin/bash
set -uo pipefail
trap 'echo "[!] 已中断"; exit 1' INT

SCRIPT_VERSION="0.9"
SCRIPT_FIXED_NAME="wifi-auto-switch"
SCRIPT_INSTALL_PATH="/usr/local/bin/${SCRIPT_FIXED_NAME}"
DISPATCHER_SCRIPT="/etc/NetworkManager/dispatcher.d/${SCRIPT_FIXED_NAME}.sh"
CONFIG_DIR="/var/lib/wifi_auto_switch"
INTERFACE_NAME_FILE="$CONFIG_DIR/eth_iface"
LOG_FILE="/var/log/wifi_auto_switch.log"
MAX_LOG_SIZE=1048576
HOTSPOT_PREFIX="AutoHotspot-"
LOCK_FILE="/tmp/wifi_auto_switch.lock"

NMCLI_TIMEOUT=10
NMCLI_QUICK_TIMEOUT=5
NMCLI_CONNECT_TIMEOUT=30
NMCLI_RESCAN_TIMEOUT=15
NMCLI_KILL_AFTER=3

RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; RESET='\033[0m'

_ok()   { echo -e "${GREEN}[✓]${RESET} $*"; }
_warn() { echo -e "${YELLOW}[!]${RESET} $*"; }
_err()  { echo -e "${RED}[x]${RESET} $*" >&2; }
_info() { echo -e "[i] $*"; }

press_any_key() {
  echo ""
  read -rn1 -s -p "按任意键返回..." _junk </dev/tty || true
  echo ""
}

restrict_log_size() {
  if [[ -f "$LOG_FILE" ]]; then
    local log_size
    log_size=$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)
    if [[ "$log_size" -ge "$MAX_LOG_SIZE" ]]; then
      echo "$(date '+%Y-%m-%d %H:%M:%S') - 日志超过 1MB 已清空" > "$LOG_FILE"
    fi
  fi
}

log() {
  restrict_log_size
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE" 2>/dev/null || true
}

nm() {
  timeout -k "$NMCLI_KILL_AFTER" "$NMCLI_TIMEOUT" nmcli "$@"
}

nmq() {
  timeout -k "$NMCLI_KILL_AFTER" "$NMCLI_QUICK_TIMEOUT" nmcli "$@"
}

nml() {
  local t="$1"; shift
  timeout -k "$NMCLI_KILL_AFTER" "$t" nmcli "$@"
}

kill_stuck_nmcli() {
  local pids
  pids=$(pgrep -f "nmcli.*wifi" 2>/dev/null || true)
  if [[ -n "$pids" ]]; then
    log "发现残留 nmcli 进程: $pids，强制杀死"
    echo "$pids" | xargs -r kill -9 2>/dev/null || true
    sleep 1
  fi
}

acquire_lock() {
  local timeout="${1:-30}"
  local waited=0
  while ! mkdir "$LOCK_FILE" 2>/dev/null; do
    if [[ -f "$LOCK_FILE/pid" ]]; then
      local lock_pid
      lock_pid=$(cat "$LOCK_FILE/pid" 2>/dev/null || echo 0)
      if ! kill -0 "$lock_pid" 2>/dev/null; then
        log "检测到僵尸锁（pid=$lock_pid），清除"
        rm -rf "$LOCK_FILE"
        continue
      fi
    fi
    if [[ $waited -ge $timeout ]]; then
      log "获取锁超时"
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  echo $$ > "$LOCK_FILE/pid"
  return 0
}

release_lock() {
  rm -rf "$LOCK_FILE" 2>/dev/null || true
}

if [[ "${EUID}" -ne 0 ]]; then
  _err "请以 root 权限运行此脚本"
  exit 1
fi

mkdir -p "$CONFIG_DIR"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/wifi_auto_switch.log"
log "脚本启动，版本: $SCRIPT_VERSION"

detect_os() {
  OS_ID=""
  PKG_UPDATE=""
  PKG_INSTALL=""

  if [[ -f /etc/os-release ]]; then
    OS_ID=$(grep "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]')
  fi

  case "$OS_ID" in
    debian|ubuntu|raspbian|armbian)
      PKG_UPDATE="apt-get update -qq"; PKG_INSTALL="apt-get install -y -qq" ;;
    centos|rhel|rocky|almalinux)
      PKG_UPDATE="yum makecache -q"; PKG_INSTALL="yum install -y -q" ;;
    fedora)
      PKG_UPDATE="dnf makecache -q"; PKG_INSTALL="dnf install -y -q" ;;
    arch|manjaro)
      PKG_UPDATE="pacman -Sy --noconfirm -q"; PKG_INSTALL="pacman -S --noconfirm -q" ;;
    *)
      _warn "未完全识别的发行版: ${OS_ID:-unknown}"
      if command -v apt-get >/dev/null 2>&1; then
        PKG_UPDATE="apt-get update -qq"; PKG_INSTALL="apt-get install -y -qq"
      elif command -v dnf >/dev/null 2>&1; then
        PKG_UPDATE="dnf makecache -q"; PKG_INSTALL="dnf install -y -q"
      elif command -v yum >/dev/null 2>&1; then
        PKG_UPDATE="yum makecache -q"; PKG_INSTALL="yum install -y -q"
      elif command -v pacman >/dev/null 2>&1; then
        PKG_UPDATE="pacman -Sy --noconfirm -q"; PKG_INSTALL="pacman -S --noconfirm -q"
      else
        PKG_UPDATE=":"; PKG_INSTALL=":"
      fi
      ;;
  esac
  log "操作系统: ${OS_ID:-unknown}"
}

detect_os

ensure_nmcli() {
  if command -v nmcli >/dev/null 2>&1; then return 0; fi
  _warn "nmcli 未安装，正在安装 NetworkManager..."
  eval "$PKG_UPDATE" 2>/dev/null || true
  eval "$PKG_INSTALL network-manager" || eval "$PKG_INSTALL NetworkManager" || {
    _err "NetworkManager 安装失败"
    return 1
  }
  command -v nmcli >/dev/null 2>&1 || { _err "安装后仍找不到 nmcli"; return 1; }
  _ok "NetworkManager 安装成功"
}

ensure_iw() {
  if command -v iw >/dev/null 2>&1; then return 0; fi
  _warn "iw 未安装，正在安装..."
  eval "$PKG_UPDATE" 2>/dev/null || true
  eval "$PKG_INSTALL iw" >/dev/null 2>&1 || true
  command -v iw >/dev/null 2>&1
}

ensure_nm_running() {
  ensure_nmcli || return 1
  ensure_iw
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable NetworkManager >/dev/null 2>&1 || true
    systemctl start NetworkManager >/dev/null 2>&1 || true
  elif command -v service >/dev/null 2>&1; then
    service NetworkManager start >/dev/null 2>&1 || true
  fi
  sleep 1
  nmq general status >/dev/null 2>&1 || { _err "NetworkManager 未能正常启动"; return 1; }
}

_NM_DEV_CACHE=""
_NM_DEV_CACHE_TIME=0

_get_nm_dev_cache() {
  local now; now=$(date +%s)
  if [[ -z "$_NM_DEV_CACHE" ]] || [[ $((now - _NM_DEV_CACHE_TIME)) -gt 3 ]]; then
    _NM_DEV_CACHE=$(nmq -t -f DEVICE,TYPE dev 2>/dev/null || true)
    _NM_DEV_CACHE_TIME=$now
  fi
  echo "$_NM_DEV_CACHE"
}

detect_wifi_interface() {
  _get_nm_dev_cache | awk -F: '$2=="wifi"{print $1; exit}'
}

detect_ethernet_interface() {
  _get_nm_dev_cache | awk -F: '$2=="ethernet"{print $1; exit}'
}

_invalidate_dev_cache() {
  _NM_DEV_CACHE=""
  _NM_DEV_CACHE_TIME=0
}

_get_dev_state() {
  local iface="$1"
  nmq -t -f DEVICE,STATE dev 2>/dev/null | \
    awk -F: -v d="$iface" '$1==d{print $2; exit}' || echo "unknown"
}

_get_active_con_on() {
  local iface="$1"
  nmq -t -f NAME,DEVICE,STATE con show --active 2>/dev/null | \
    awk -F: -v d="$iface" '$2==d && $3=="activated"{print $1; exit}' || true
}

is_ethernet_connected() {
  local iface="$1"
  local retry="${2:-3}"
  local delay="${3:-2}"

  if [[ ! -e "/sys/class/net/${iface}" ]]; then
    log "接口 $iface 不存在"
    return 1
  fi

  local i operstate carrier
  for (( i=0; i<retry; i++ )); do
    operstate=$(cat "/sys/class/net/${iface}/operstate" 2>/dev/null || echo "unknown")
    carrier=$(cat "/sys/class/net/${iface}/carrier" 2>/dev/null || echo "0")
    log "网线检测[$i]: $iface operstate=$operstate carrier=$carrier"

    if [[ "$operstate" == "up" && "$carrier" == "1" ]]; then
      return 0
    fi

    if [[ "$operstate" == "down" && "$carrier" == "0" ]]; then
      return 1
    fi

    if [[ $i -lt $((retry - 1)) ]]; then
      sleep "$delay"
    fi
  done

  return 1
}

get_current_mode() {
  local wifi_iface; wifi_iface=$(detect_wifi_interface)
  if [[ -z "$wifi_iface" ]]; then echo "无线网卡未检测到"; return; fi

  local active_con
  active_con=$(_get_active_con_on "$wifi_iface")

  if [[ -z "$active_con" ]]; then
    echo "未连接"
  elif [[ "$active_con" == ${HOTSPOT_PREFIX}* ]]; then
    echo "热点模式  [${active_con}]"
  else
    local iw_mode
    iw_mode=$(_get_iw_mode "$wifi_iface")
    if [[ "$iw_mode" == "AP" ]]; then
      echo "热点模式(状态混乱)  [${active_con}]"
    else
      echo "客户端模式  [${active_con}]"
    fi
  fi
}

_get_iw_mode() {
  local iface="$1"
  if command -v iw >/dev/null 2>&1; then
    timeout -k 2 3 iw dev "$iface" info 2>/dev/null | awk '/^\s*type/{print $2}' || echo ""
  else
    echo ""
  fi
}

_is_in_ap_mode() {
  local iface="$1"
  local iw_mode; iw_mode=$(_get_iw_mode "$iface")
  if [[ -n "$iw_mode" ]]; then
    [[ "$iw_mode" == "AP" || "$iw_mode" == "__ap" ]]
    return $?
  fi
  local ap_active
  ap_active=$(nmq -t -f NAME,DEVICE,STATE con show --active 2>/dev/null | \
    awk -F: -v d="$iface" '$2==d && $3=="activated"{print $1}' | \
    grep "^${HOTSPOT_PREFIX}" || true)
  [[ -n "$ap_active" ]]
}

force_disconnect_wifi() {
  local iface="$1"
  log "强制断开 $iface 的所有连接"

  local active_con
  active_con=$(_get_active_con_on "$iface")
  if [[ -n "$active_con" ]]; then
    log "down 当前连接：$active_con"
    nm con down "$active_con" >/dev/null 2>&1 || true
  fi

  nm dev disconnect "$iface" >/dev/null 2>&1 || true
  sleep 2

  kill_stuck_nmcli

  local waited=0 state
  while [[ $waited -lt 10 ]]; do
    state=$(_get_dev_state "$iface")
    if [[ "$state" == "disconnected" ]]; then
      log "$iface 已进入 disconnected 状态"
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  log "$iface 状态未变为 disconnected（当前: $state）"
  return 0
}

_ensure_wifi_ready() {
  local iface="$1"

  if command -v rfkill >/dev/null 2>&1; then
    rfkill unblock wifi >/dev/null 2>&1 || true
  fi
  nmq radio wifi on >/dev/null 2>&1 || true
  nmq dev set "$iface" managed yes >/dev/null 2>&1 || true

  local nm_state waited=0
  while [[ $waited -lt 8 ]]; do
    nm_state=$(_get_dev_state "$iface")
    log "网卡状态[$waited]: $nm_state"
    case "$nm_state" in
      disconnected|connected|activated|connecting) return 0 ;;
    esac
    sleep 1
    waited=$((waited + 1))
  done
  return 0
}

wait_for_station_mode() {
  local iface="$1"
  local max_wait="${2:-25}"
  local waited=0

  if ! _is_in_ap_mode "$iface"; then
    return 0
  fi

  _info "等待网卡切换到 Station 模式..."
  while [[ $waited -lt $max_wait ]]; do
    sleep 1
    waited=$((waited + 1))
    if ! _is_in_ap_mode "$iface"; then
      sleep 2
      return 0
    fi
  done
  log "等待 Station 超时"
  return 0
}

_iw_scan() {
  local iface="$1"
  local hotspot_name="${2:-}"

  if ! command -v iw >/dev/null 2>&1; then
    return 1
  fi

  ip link set "$iface" up >/dev/null 2>&1 || true
  sleep 1

  local raw
  raw=$(timeout -k 3 15 iw dev "$iface" scan 2>/dev/null || true)
  [[ -z "$raw" ]] && return 1

  echo "$raw" | awk -v hp="$hotspot_name" -v pfx="$HOTSPOT_PREFIX" '
    /^BSS / { if (ssid != "" && ssid != "--" && ssid != hp && index(ssid, pfx) != 1) {
                sig_pct = int((sig + 100) * 2); if (sig_pct < 0) sig_pct=0; if (sig_pct>100) sig_pct=100
                printf "%s|%d|%s\n", ssid, sig_pct, sec
              }
              ssid=""; sig=-100; sec=""
            }
    /signal:/ { sig = $2 + 0 }
    /SSID:/ { $1=""; sub(/^ /, ""); ssid=$0 }
    /RSN:/ { sec="WPA2" }
    /WPA:/ { if (sec=="") sec="WPA" }
    /Privacy/ { if (sec=="") sec="WEP" }
    END { if (ssid != "" && ssid != "--" && ssid != hp && index(ssid, pfx) != 1) {
            sig_pct = int((sig + 100) * 2); if (sig_pct < 0) sig_pct=0; if (sig_pct>100) sig_pct=100
            printf "%s|%d|%s\n", ssid, sig_pct, sec
          }
        }
  '
  return 0
}

_parse_and_filter_wifi() {
  local raw="$1"
  local hotspot_name="${2:-}"

  [[ -z "$raw" ]] && return 0

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    local safe_line ssid signal security mode
    safe_line="${line//\\:/$'\x01'}"
    IFS=':' read -r ssid signal security mode <<< "$safe_line"

    ssid="${ssid//$'\x01'/:}"
    security="${security//$'\x01'/:}"

    [[ -z "$ssid" || "$ssid" == "--" ]] && continue
    [[ "$mode" == "Ap" || "$mode" == "AP" ]] && continue
    [[ "$ssid" == "$hotspot_name" ]] && continue
    case "$ssid" in
      ${HOTSPOT_PREFIX}*) continue ;;
    esac

    echo "${ssid}|${signal}|${security}"
  done <<< "$raw"

  return 0
}

scan_wifi_via_nmcli() {
  local iface="$1"
  local raw="" attempt=0 max_attempt=2 line_count=0

  while [[ $attempt -lt $max_attempt ]]; do
    attempt=$((attempt + 1))
    log "nmcli 扫描尝试 $attempt/$max_attempt"

    timeout -k 3 "$NMCLI_RESCAN_TIMEOUT" nmcli dev wifi rescan ifname "$iface" >/dev/null 2>&1
    log "rescan 返回码: $?"
    sleep 3

    raw=$(timeout -k 3 "$NMCLI_TIMEOUT" nmcli -t -f SSID,SIGNAL,SECURITY,MODE dev wifi list ifname "$iface" --rescan no 2>/dev/null || true)
    line_count=$(printf '%s\n' "$raw" | grep -c . 2>/dev/null || true)
    line_count=${line_count:-0}
    log "nmcli 扫描到 $line_count 条"

    if [[ $line_count -gt 1 ]]; then
      break
    fi
    sleep 2
  done

  echo "$raw"
}

scan_wifi_raw() {
  local iface="$1"
  local hotspot_name="${2:-}"
  local raw=""

  log "=== 开始扫描 $iface ==="

  force_disconnect_wifi "$iface"
  _ensure_wifi_ready "$iface"

  log "尝试 iw 扫描（不依赖 nmcli）"
  local iw_result
  iw_result=$(_iw_scan "$iface" "$hotspot_name")
  local iw_count
  iw_count=$(printf '%s\n' "$iw_result" | grep -c . 2>/dev/null || true)
  iw_count=${iw_count:-0}
  log "iw 扫描到 $iw_count 条"

  if [[ $iw_count -gt 0 ]]; then
    echo "$iw_result"
    return 0
  fi

  log "iw 扫描无结果，回退到 nmcli"
  raw=$(scan_wifi_via_nmcli "$iface")
  _parse_and_filter_wifi "$raw" "$hotspot_name"
}

scan_wifi() {
  local iface="$1"
  local hotspot_name="4G-WIFI"
  [[ -f "$CONFIG_DIR/hotspot_name" ]] && hotspot_name=$(cat "$CONFIG_DIR/hotspot_name")

  scan_wifi_raw "$iface" "$hotspot_name" | sort -t'|' -k2 -rn | awk -F'|' 'NF && !seen[$1]++'
}

clear_old_hotspots() {
  local old_hotspots=()
  mapfile -t old_hotspots < <(
    nmq -t -f NAME con show 2>/dev/null | grep "^${HOTSPOT_PREFIX}" || true
  )
  if [[ ${#old_hotspots[@]} -gt 0 ]]; then
    log "清理旧热点：${#old_hotspots[@]} 个"
    for hs in "${old_hotspots[@]}"; do
      nm con down "$hs" >/dev/null 2>&1 || true
      sleep 1
      nm con delete "$hs" >/dev/null 2>&1 || true
      log "已清理：$hs"
    done
    _invalidate_dev_cache
  fi
}

create_wifi_hotspot() {
  local iface="$1"
  local wifi_name="${2:-4G-WIFI}"
  local wifi_password="${3:-12345678}"
  local con_name="${HOTSPOT_PREFIX}${wifi_name}"

  clear_old_hotspots
  sleep 1

  force_disconnect_wifi "$iface"

  log "创建热点：SSID=$wifi_name"
  _info "正在创建热点：$wifi_name..."

  local phy_name
  phy_name=$(timeout -k 2 3 iw dev "$iface" info 2>/dev/null | awk '/wiphy/{print "phy"$2; exit}' || true)
  if [[ -n "$phy_name" ]]; then
    if ! timeout -k 2 3 iw phy "$phy_name" info 2>/dev/null | grep -q "AP"; then
      _warn "网卡可能不支持 AP 模式"
    fi
  fi

  if ! nm con add type wifi ifname "$iface" con-name "$con_name" \
    ssid "$wifi_name" 802-11-wireless.mode ap \
    802-11-wireless.band bg >/dev/null 2>&1; then
    log "热点创建失败"
    _err "热点创建失败"
    return 1
  fi

  nm con modify "$con_name" \
    802-11-wireless-security.key-mgmt wpa-psk \
    802-11-wireless-security.psk "$wifi_password" \
    ipv4.method shared \
    connection.autoconnect no >/dev/null 2>&1

  if timeout -k 3 25 nmcli con up "$con_name" >/dev/null 2>&1; then
    log "热点已启动：SSID=$wifi_name"
    _ok "热点已启动：SSID=$wifi_name，密码=$wifi_password"
    _invalidate_dev_cache
    return 0
  else
    log "热点启动失败"
    _err "热点启动失败"
    nm con delete "$con_name" >/dev/null 2>&1 || true
    return 1
  fi
}

_do_wifi_connect() {
  local iface="$1"
  local ssid="$2"
  local password="$3"
  local hidden="${4:-no}"

  local args=(dev wifi connect "$ssid" ifname "$iface")
  [[ -n "$password" ]] && args+=(password "$password")
  [[ "$hidden" == "yes" ]] && args+=(hidden yes)

  log "执行：nmcli ${args[*]}"
  timeout -k 3 "$NMCLI_CONNECT_TIMEOUT" nmcli "${args[@]}" >/dev/null 2>&1
  local ret=$?
  [[ $ret -eq 124 || $ret -eq 137 ]] && log "连接超时/被杀"
  return $ret
}

connect_wifi_network() {
  local iface="$1"
  local ssid="$2"
  local password="$3"
  local skip_clear="${4:-false}"

  log "手动连接：SSID=$ssid skip_clear=$skip_clear"

  if [[ "$skip_clear" != "true" ]]; then
    clear_old_hotspots
    sleep 1
  fi

  force_disconnect_wifi "$iface"

  if _is_in_ap_mode "$iface"; then
    _warn "网卡仍在 AP 模式，等待切换..."
    wait_for_station_mode "$iface" 20
  fi

  _ensure_wifi_ready "$iface"

  local old_con
  old_con=$(nmq -t -f NAME,TYPE con show 2>/dev/null | \
    awk -F: -v s="$ssid" '$1==s && $2=="802-11-wireless"{print $1}' || true)
  if [[ -n "$old_con" ]]; then
    log "删除旧连接配置：$old_con"
    nm con delete "$old_con" >/dev/null 2>&1 || true
  fi

  log "尝试连接（普通）：$ssid"
  if _do_wifi_connect "$iface" "$ssid" "$password" "no"; then
    log "连接成功：$ssid"
    _ok "已连接到：$ssid"
    _invalidate_dev_cache
    return 0
  fi

  log "尝试连接（隐藏SSID）：$ssid"
  if _do_wifi_connect "$iface" "$ssid" "$password" "yes"; then
    log "隐藏连接成功：$ssid"
    _ok "已连接（隐藏SSID）：$ssid"
    _invalidate_dev_cache
    return 0
  fi

  log "连接失败：$ssid"
  _err "连接 $ssid 失败"

  local final_iw; final_iw=$(_get_iw_mode "$iface")
  local final_nm; final_nm=$(_get_dev_state "$iface")
  _info "驱动模式：${final_iw:-未知}  NM 状态：$final_nm"
  return 1
}

smart_connect_wifi() {
  local iface="$1"
  local max_retries=2
  local wait_time=5

  log "开始智能连接（iface=$iface）"

  force_disconnect_wifi "$iface"
  _ensure_wifi_ready "$iface"

  local saved_cons=()
  mapfile -t saved_cons < <(
    nmq -t -f NAME,TYPE con show 2>/dev/null | \
    awk -F: '$2=="802-11-wireless"{print $1}' | \
    grep -v "^${HOTSPOT_PREFIX}" || true
  )

  local visible_ssids=""
  visible_ssids=$(scan_wifi "$iface" | awk -F'|' '{print $1}')
  local visible_count
  visible_count=$(printf '%s\n' "$visible_ssids" | grep -c . 2>/dev/null || true)
  visible_count=${visible_count:-0}
  log "扫描到可见 SSID 数：$visible_count"

  if [[ ${#saved_cons[@]} -gt 0 ]]; then
    log "已保存连接：${saved_cons[*]}"
    for con in "${saved_cons[@]}"; do
      local con_ssid
      con_ssid=$(nmq -t -f 802-11-wireless.ssid con show "$con" 2>/dev/null | cut -d: -f2)
      if [[ -n "$visible_ssids" && -n "$con_ssid" ]]; then
        if ! grep -Fxq "$con_ssid" <<< "$visible_ssids"; then
          log "跳过 $con（SSID=$con_ssid 不在扫描结果中）"
          continue
        fi
      fi

      local attempt=0
      while [[ $attempt -lt $max_retries ]]; do
        log "尝试：$con（$((attempt+1))/$max_retries）"
        if timeout -k 3 "$NMCLI_CONNECT_TIMEOUT" nmcli con up "$con" ifname "$iface" >/dev/null 2>&1; then
          log "已连接：$con"
          _invalidate_dev_cache
          return 0
        fi
        attempt=$((attempt + 1))
        [[ $attempt -lt $max_retries ]] && sleep "$wait_time"
      done
    done
  else
    log "无已保存连接"
  fi

  local available_ssids=()
  mapfile -t available_ssids < <(
    scan_wifi "$iface" | \
    awk -F'|' '$3=="" || $3=="--" {print $1}' | \
    head -n 5 || true
  )

  if [[ ${#available_ssids[@]} -gt 0 ]]; then
    log "开放网络：${available_ssids[*]}"
    for ssid in "${available_ssids[@]}"; do
      [[ -z "$ssid" ]] && continue
      log "尝试开放：$ssid"
      if timeout -k 3 "$NMCLI_CONNECT_TIMEOUT" nmcli dev wifi connect "$ssid" ifname "$iface" >/dev/null 2>&1; then
        log "成功：$ssid"
        _invalidate_dev_cache
        return 0
      fi
    done
  fi

  log "所有尝试均失败"
  return 1
}

auto_switch_wifi_mode() {
  local triggered_by="${1:-manual}"
  log "触发自动切换（来源: $triggered_by）"

  local wifi_iface; wifi_iface=$(detect_wifi_interface)
  local eth_iface; eth_iface=$(detect_ethernet_interface)

  if [[ -z "$wifi_iface" ]]; then
    _err "未检测到无线网卡"
    return 1
  fi

  if [[ -z "$eth_iface" ]]; then
    _err "未检测到有线网卡"
    return 1
  fi

  local hotspot_name="4G-WIFI"
  local hotspot_pass="12345678"
  [[ -f "$CONFIG_DIR/hotspot_name" ]] && hotspot_name=$(cat "$CONFIG_DIR/hotspot_name")
  [[ -f "$CONFIG_DIR/hotspot_pass" ]] && hotspot_pass=$(cat "$CONFIG_DIR/hotspot_pass")

  if [[ "$triggered_by" == "up" ]]; then
    sleep 3
  fi

  if is_ethernet_connected "$eth_iface" 3 2; then
    local cur_ap
    cur_ap=$(_get_active_con_on "$wifi_iface")
    local iw_mode; iw_mode=$(_get_iw_mode "$wifi_iface")
    if [[ "$cur_ap" == "${HOTSPOT_PREFIX}${hotspot_name}" && "$iw_mode" == "AP" ]]; then
      log "已在目标热点模式，无需切换"
      _ok "已在目标热点模式：$cur_ap"
      return 0
    fi
    log "有线已连接，切换热点模式"
    _info "有线已连接，创建 WiFi 热点..."
    create_wifi_hotspot "$wifi_iface" "$hotspot_name" "$hotspot_pass" || return 1
  else
    local iw_mode; iw_mode=$(_get_iw_mode "$wifi_iface")
    local cur_con; cur_con=$(_get_active_con_on "$wifi_iface")
    if [[ "$iw_mode" != "AP" && -n "$cur_con" && "$cur_con" != ${HOTSPOT_PREFIX}* ]]; then
      log "已在客户端模式（$cur_con）"
      _ok "已在客户端模式：$cur_con"
      return 0
    fi

    log "有线未连接，尝试连接 WiFi..."
    _info "有线未连接，尝试连接已知 WiFi..."

    clear_old_hotspots
    sleep 1
    force_disconnect_wifi "$wifi_iface"
    wait_for_station_mode "$wifi_iface" 20

    if smart_connect_wifi "$wifi_iface"; then
      _ok "已连接 WiFi"
    else
      _warn "未连接任何 WiFi，启动热点..."
      create_wifi_hotspot "$wifi_iface" "$hotspot_name" "$hotspot_pass" || return 1
    fi
  fi
}

install_dispatcher() {
  _info "安装 NetworkManager Dispatcher 服务..."

  local eth_iface; eth_iface=$(detect_ethernet_interface)
  if [[ -z "$eth_iface" ]]; then
    _err "未检测到有线网卡"
    return 1
  fi

  _info "检测到有线网卡：$eth_iface"
  echo "$eth_iface" > "$INTERFACE_NAME_FILE"

  cp -f "$0" "$SCRIPT_INSTALL_PATH" || {
    _err "无法复制脚本到 $SCRIPT_INSTALL_PATH"
    return 1
  }
  chmod +x "$SCRIPT_INSTALL_PATH"

  mkdir -p "$(dirname "$DISPATCHER_SCRIPT")"
  cat > "$DISPATCHER_SCRIPT" << 'DISPATCHER_EOF'
#!/bin/bash
INTERFACE="$1"
ACTION="$2"
SCRIPT_INSTALL_PATH="/usr/local/bin/wifi-auto-switch"
INTERFACE_NAME_FILE="/var/lib/wifi_auto_switch/eth_iface"
LOG_FILE="/var/log/wifi_auto_switch.log"

log_d() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - [Dispatcher] $*" >> "$LOG_FILE" 2>/dev/null || true
}

log_d "触发: iface=$INTERFACE action=$ACTION"

[[ -f "$SCRIPT_INSTALL_PATH" ]] || { log_d "主脚本不存在"; exit 0; }
[[ -f "$INTERFACE_NAME_FILE" ]] || { log_d "接口配置不存在"; exit 0; }

ETH_IFACE=$(cat "$INTERFACE_NAME_FILE" 2>/dev/null || true)
[[ -z "$ETH_IFACE" ]] && { log_d "接口配置为空"; exit 0; }

should_trigger=false
trigger_action="manual"

if [[ "$INTERFACE" == "$ETH_IFACE" ]]; then
  case "$ACTION" in
    up)
      should_trigger=true
      trigger_action="up"
      ;;
    down|post-down)
      should_trigger=true
      trigger_action="down"
      ;;
  esac
fi

if [[ "$should_trigger" == "true" ]]; then
  log_d "启动自动切换（action=$trigger_action）"
  setsid "$SCRIPT_INSTALL_PATH" auto-switch-dispatcher "$trigger_action" >> "$LOG_FILE" 2>&1 < /dev/null &
  disown
fi

exit 0
DISPATCHER_EOF

  chmod +x "$DISPATCHER_SCRIPT"
  _ok "Dispatcher 脚本已安装：$DISPATCHER_SCRIPT"
  _ok "主脚本已安装：$SCRIPT_INSTALL_PATH"

  _info "执行初始状态检测..."
  auto_switch_wifi_mode "init"

  log "Dispatcher 安装完成"
}

uninstall_dispatcher() {
  echo ""
  echo "将删除以下内容："
  echo "  - $DISPATCHER_SCRIPT"
  echo "  - $SCRIPT_INSTALL_PATH"
  echo "  - $CONFIG_DIR"
  echo ""
  read -rp "确认卸载？(y/N): " confirm </dev/tty
  [[ "${confirm,,}" == "y" ]] || { _warn "已取消"; return; }

  _info "清理热点连接..."
  clear_old_hotspots

  [[ -f "$DISPATCHER_SCRIPT" ]] && rm -f "$DISPATCHER_SCRIPT" && _ok "已删除 Dispatcher 脚本"
  [[ -f "$SCRIPT_INSTALL_PATH" ]] && rm -f "$SCRIPT_INSTALL_PATH" && _ok "已删除主脚本"
  [[ -d "$CONFIG_DIR" ]] && rm -rf "$CONFIG_DIR" && _ok "已删除配置目录"
  rm -rf "$LOCK_FILE" 2>/dev/null || true

  log "已卸载"
  _ok "卸载完成"
}

manage_saved_wifi() {
  echo ""
  echo "===== 已保存的 WiFi 网络 ====="
  nmq -t -f NAME,TYPE con show 2>/dev/null | \
    awk -F: '$2=="802-11-wireless"{print "  "$1}' | \
    grep -v "^  ${HOTSPOT_PREFIX}" || echo "  （无）"
  echo "==============================="
  echo ""
  read -rp "是否添加新的 WiFi 网络？(y/N): " add_choice </dev/tty
  if [[ "${add_choice,,}" != "y" ]]; then return; fi

  local wifi_iface; wifi_iface=$(detect_wifi_interface)
  if [[ -z "$wifi_iface" ]]; then
    _err "未检测到无线网卡"
    return 1
  fi

  read -rp "请输入 WiFi 名称（SSID）: " new_ssid </dev/tty
  read -rsp "请输入 WiFi 密码（无密码直接回车）: " new_pass </dev/tty
  echo ""

  if [[ -z "$new_ssid" ]]; then
    _err "SSID 不能为空"
    return 1
  fi

  connect_wifi_network "$wifi_iface" "$new_ssid" "$new_pass" "false"
}

configure_hotspot_params() {
  echo ""
  echo "===== 配置热点参数 ====="
  local cur_name="4G-WIFI"
  local cur_pass="12345678"
  [[ -f "$CONFIG_DIR/hotspot_name" ]] && cur_name=$(cat "$CONFIG_DIR/hotspot_name")
  [[ -f "$CONFIG_DIR/hotspot_pass" ]] && cur_pass=$(cat "$CONFIG_DIR/hotspot_pass")

  read -rp "热点名称（SSID） [当前: $cur_name]: " new_name </dev/tty
  new_name="${new_name:-$cur_name}"

  read -rsp "热点密码（8位以上） [当前: $cur_pass]: " new_pass </dev/tty
  echo ""
  new_pass="${new_pass:-$cur_pass}"

  if [[ "${#new_pass}" -lt 8 ]]; then
    _err "密码至少需要 8 位"
    return 1
  fi

  echo "$new_name" > "$CONFIG_DIR/hotspot_name"
  echo "$new_pass" > "$CONFIG_DIR/hotspot_pass"
  chmod 600 "$CONFIG_DIR/hotspot_pass"
  _ok "热点参数已保存：SSID=$new_name"
}

scan_and_display_wifi() {
  local iface="$1"

  _info "准备扫描环境..."
  clear_old_hotspots
  sleep 1

  _info "正在扫描周边 WiFi（使用 iw 直连内核，避开 nmcli 阻塞）..."

  local hotspot_name="4G-WIFI"
  [[ -f "$CONFIG_DIR/hotspot_name" ]] && hotspot_name=$(cat "$CONFIG_DIR/hotspot_name")

  local result
  result=$(scan_wifi_raw "$iface" "$hotspot_name")

  echo ""
  echo "周边可见的 WiFi："
  printf "  %-32s %-8s %s\n" "SSID" "信号" "安全"
  echo "  ────────────────────────────────────────────────"

  local found=false
  local sorted
  sorted=$(echo "$result" | sort -t'|' -k2 -rn | awk -F'|' 'NF && !seen[$1]++')

  if [[ -n "$sorted" ]]; then
    while IFS='|' read -r ssid signal security; do
      [[ -z "$ssid" ]] && continue
      printf "  %-32s %-8s %s\n" "$ssid" "${signal:--}%" "${security:---}"
      found=true
    done <<< "$sorted"
  fi

  if [[ "$found" == false ]]; then
    _warn "未扫描到可用 WiFi"
    local iw_mode; iw_mode=$(_get_iw_mode "$iface")
    local nm_state2; nm_state2=$(_get_dev_state "$iface")
    _info "网卡模式：${iw_mode:-未知}  NM 状态：$nm_state2"
    echo ""
    echo "  [调试] 扫描原始输出（前20行）："
    printf '%s\n' "$result" | head -20 | sed 's/^/  /'
  fi
  echo ""
}

show_status() {
  echo ""
  echo "===== 详细状态 ====="
  local wifi_iface; wifi_iface=$(detect_wifi_interface)
  local eth_iface; eth_iface=$(detect_ethernet_interface)

  echo "  无线网卡：${wifi_iface:-未检测到}"
  echo "  有线网卡：${eth_iface:-未检测到}"

  if [[ -n "$eth_iface" ]]; then
    local operstate carrier
    operstate=$(cat "/sys/class/net/${eth_iface}/operstate" 2>/dev/null || echo "unknown")
    carrier=$(cat "/sys/class/net/${eth_iface}/carrier" 2>/dev/null || echo "0")
    echo "  有线状态：operstate=$operstate, carrier=$carrier"
  fi

  if [[ -n "$wifi_iface" ]]; then
    local mode; mode=$(get_current_mode)
    echo "  WiFi 模式：$mode"
    local iw_mode; iw_mode=$(_get_iw_mode "$wifi_iface")
    [[ -n "$iw_mode" ]] && echo "  驱动模式：$iw_mode"
    local nm_state; nm_state=$(_get_dev_state "$wifi_iface")
    echo "  NM 状态 ：$nm_state"
  fi

  echo ""
  echo "  Dispatcher：$( [[ -f "$DISPATCHER_SCRIPT" ]] && echo "已安装" || echo "未安装" )"
  echo "  热点名称  ：$( [[ -f "$CONFIG_DIR/hotspot_name" ]] && cat "$CONFIG_DIR/hotspot_name" || echo "4G-WIFI（默认）" )"
  echo "  日志文件  ：$LOG_FILE"
  echo ""
  echo "-- 最近 20 条日志 --"
  tail -n 20 "$LOG_FILE" 2>/dev/null || echo "（日志为空）"
  echo "===================="
}

if [[ "${1:-}" == "auto-switch-dispatcher" ]]; then
  trigger_type="${2:-manual}"
  log "Dispatcher 调用，触发类型: $trigger_type"

  if ! acquire_lock 30; then
    log "无法获取锁"
    exit 0
  fi
  trap 'release_lock' EXIT

  ensure_nm_running >/dev/null 2>&1 || true
  auto_switch_wifi_mode "$trigger_type"
  exit 0
fi

ensure_nm_running || {
  _err "NetworkManager 启动失败"
  exit 1
}

while true; do
  _invalidate_dev_cache
  kill_stuck_nmcli

  wifi_iface=$(detect_wifi_interface)
  eth_iface=$(detect_ethernet_interface)
  current_mode=$(get_current_mode)

  eth_status="未连接"
  if [[ -n "$eth_iface" ]]; then
    local_operstate=$(cat "/sys/class/net/${eth_iface}/operstate" 2>/dev/null || echo "unknown")
    local_carrier=$(cat "/sys/class/net/${eth_iface}/carrier" 2>/dev/null || echo "0")
    [[ "$local_operstate" == "up" && "$local_carrier" == "1" ]] && eth_status="已连接"
  fi

  dispatcher_status="未安装"
  [[ -f "$DISPATCHER_SCRIPT" ]] && dispatcher_status="已安装"

  echo ""
  echo "========== WiFi 自动切换管理 v${SCRIPT_VERSION} =========="
  echo "  无线网卡：${wifi_iface:-未检测到}    有线网卡：${eth_iface:-未检测到}"
  echo "  有线状态：$eth_status    WiFi 模式：$current_mode"
  echo "  Dispatcher：$dispatcher_status"
  echo "---------------------------------------------------"
  echo "  1. 创建 WiFi 热点"
  echo "  2. 连接到指定 WiFi（切换客户端模式）"
  echo "  3. 手动触发自动切换"
  echo "  4. 安装 Dispatcher（开机自启动）"
  echo "  5. 卸载 Dispatcher"
  echo "  6. 配置热点参数（SSID/密码）"
  echo "  7. 管理已保存的 WiFi"
  echo "  8. 查看详细状态"
  echo "  0. 退出"
  echo "==================================================="
  read -rp "请输入选项: " choice </dev/tty

  case "$choice" in
    1)
      wifi_iface=$(detect_wifi_interface)
      if [[ -z "$wifi_iface" ]]; then _err "未检测到无线网卡"; press_any_key; continue; fi
      configure_hotspot_params || { press_any_key; continue; }
      hn=$(cat "$CONFIG_DIR/hotspot_name" 2>/dev/null || echo "4G-WIFI")
      hp=$(cat "$CONFIG_DIR/hotspot_pass" 2>/dev/null || echo "12345678")
      create_wifi_hotspot "$wifi_iface" "$hn" "$hp"
      press_any_key
      ;;
    2)
      wifi_iface=$(detect_wifi_interface)
      if [[ -z "$wifi_iface" ]]; then _err "未检测到无线网卡"; press_any_key; continue; fi
      scan_and_display_wifi "$wifi_iface"
      read -rp "请输入要连接的 WiFi 名称（SSID，留空取消）: " target_ssid </dev/tty
      if [[ -z "$target_ssid" ]]; then _warn "已取消"; press_any_key; continue; fi
      read -rsp "请输入密码（无密码直接回车）: " target_pass </dev/tty
      echo ""
      connect_wifi_network "$wifi_iface" "$target_ssid" "$target_pass" "true"
      press_any_key
      ;;
    3)
      _info "手动触发自动切换..."
      auto_switch_wifi_mode "manual"
      press_any_key
      ;;
    4)
      if [[ -f "$DISPATCHER_SCRIPT" ]]; then
        _warn "Dispatcher 已安装"
        read -rp "是否重新安装？(y/N): " reinstall </dev/tty
        [[ "${reinstall,,}" == "y" ]] || { press_any_key; continue; }
      fi
      install_dispatcher
      press_any_key
      ;;
    5) uninstall_dispatcher; press_any_key ;;
    6) configure_hotspot_params; press_any_key ;;
    7) manage_saved_wifi; press_any_key ;;
    8) show_status; press_any_key ;;
    0) _ok "退出脚本"; exit 0 ;;
    *) _warn "无效选项，请输入 0-8" ;;
  esac
done
