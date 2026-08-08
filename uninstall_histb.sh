#!/bin/bash
set -eo pipefail
R='\033[0;31m' G='\033[0;32m' Y='\033[0;33m' B='\033[0;34m' C='\033[0;36m' M='\033[0;35m' W='\033[1;37m' NC='\033[0m' DIM='\033[2m'
LOG="/var/log/histb-cleanup-$(date +%Y%m%d_%H%M%S).log"
DRY=false
declare -A CHECKED=()
declare -A META_DESC=()
declare -A META_SVCS=()
declare -A META_DIRS=()
declare -A META_PKGS=()
declare -A META_TYPE=()
declare -a SCAN_HISTB=()
declare -a SCAN_PRE=()
log(){
  local l="${1:-INFO}"; shift; local msg="${*:-}"
  echo "$(date '+%H:%M:%S') [$l] $msg" >> "$LOG"
  case $l in
    INFO) echo -e "${G}[✓]${NC} $msg" ;;
    WARN) echo -e "${Y}[!]${NC} $msg" ;;
    ERR)  echo -e "${R}[✗]${NC} $msg" ;;
    ACT)  echo -e "${B}[→]${NC} $msg" ;;
  esac
}
check_root(){
  [ "$(id -u)" -eq 0 ] || { echo -e "${R}需要 root 权限，请使用 sudo 运行${NC}"; exit 1; }
}
disk_free_kb(){
  df / 2>/dev/null | awk 'NR==2{print $4}'
}
fmt_kb(){
  local k="${1:-0}"
  if   (( k >= 1048576 )); then awk "BEGIN{printf \"%.2f GB\", $k/1048576}"
  elif (( k >= 1024 ));    then awk "BEGIN{printf \"%.1f MB\",  $k/1024}"
  else echo "${k} KB"
  fi
}
str_width(){
  local s="$1" w=0 c
  local raw; raw=$(echo -e "$s" | sed 's/\x1b\[[0-9;]*m//g')
  while IFS= read -r -n1 c; do
    [[ -z "$c" ]] && continue
    if printf '%s' "$c" | grep -qP '[\x{2E80}-\x{9FFF}\x{F900}-\x{FAFF}\x{FE30}-\x{FE4F}\x{FF00}-\x{FFEF}]' 2>/dev/null; then
      (( w += 2 ))
    else
      (( w += 1 ))
    fi
  done <<< "$raw"
  echo $w
}
pad_right(){
  local s="$1" total="$2"
  local sw; sw=$(str_width "$s")
  local pad=$(( total - sw ))
  (( pad < 0 )) && pad=0
  printf '%s%*s' "$s" "$pad" ''
}
SEP="──────────────────────────────────────────────────────────────"
HR="${B}${SEP}${NC}"
box_top(){ echo -e "${B}┌${SEP}┐${NC}"; }
box_bot(){ echo -e "${B}└${SEP}┘${NC}"; }
box_mid(){ echo -e "${B}├${SEP}┤${NC}"; }
box_row(){
  local content="$1"
  local sw; sw=$(str_width "$content")
  local pad=$(( 62 - sw ))
  (( pad < 0 )) && pad=0
  printf "${B}│${NC}%b%*s${B}│${NC}\n" "$content" "$pad" ""
}
def_meta(){
  local name="$1" desc="$2" type="$3" svcs="$4" dirs="$5" pkgs="$6"
  META_DESC["$name"]="${desc:-$name}"
  META_TYPE["$name"]="${type:-pre}"
  META_SVCS["$name"]="${svcs:-}"
  META_DIRS["$name"]="${dirs:-}"
  META_PKGS["$name"]="${pkgs:-}"
}
init_meta(){
  def_meta "gitweb"       "Git 代码托管"              "histb" "gitweb"                                           "/etc/gitweb /var/lib/gitweb /usr/share/bak/gitweb /bin/install-gitweb.sh"    "gitweb-histb"
  def_meta "tailscale"    "Tailscale 异地组网"         "histb" "tailscaled"                                       "/etc/tailscale /var/lib/tailscale /opt/tailscale /var/run/tailscale"         "tailscale-histb"
  def_meta "transmission" "Transmission PT下载"        "histb" "transmission-daemon"                              "/etc/transmission-daemon /var/lib/transmission-daemon /var/lib/transmission"  "transmission-histb"
  def_meta "ttyd"         "ttyd 网页终端"              "histb" "ttyd"                                             "/etc/ttyd /var/lib/ttyd"                                                      "ttyd-histb"
  def_meta "typecho"      "Typecho 轻量博客"           "histb" "typecho php-fpm php7.4-fpm"                       "/etc/typecho /var/lib/typecho /var/www/typecho"                              "typecho-histb"
  def_meta "cronweb"      "CronWeb 定时任务管理"        "histb" "cronweb"                                          "/etc/cronweb /var/lib/cronweb"                                               "cronweb-histb"
  def_meta "ddns"         "DDNS 动态域名解析"           "histb" "ddns com.linkease.ddnstoshell"                    "/etc/ddns /etc/ddnsto /var/lib/ddns"                                         "ddns-histb"
  def_meta "filebrowser"  "FileBrowser 文件管理"        "histb" "filebrowser"                                      "/etc/filebrowser /opt/filebrowser /var/lib/filebrowser"                      "filebrowser-histb"
  def_meta "frpc"         "FRP 内网穿透客户端"          "histb" "frpc frps"                                        "/etc/frp /etc/frpc /etc/frps /opt/frp /var/lib/frpc"                         "frpc-histb"
  def_meta "h5ai"         "H5ai 轻量网盘"              "histb" "h5ai nginx"                                       "/etc/h5ai /var/lib/h5ai /var/www/h5ai"                                       "h5ai-histb"
  def_meta "linkease"     "易有云 远程访问"             "histb" "com.linkease.linkeasedaemon linkease"              "/etc/linkease /opt/linkease /var/lib/linkease"                               "linkease-histb"
  def_meta "alist"        "Alist 多网盘聚合"            "pre"   "alist"                                            "/opt/alist /etc/alist /var/lib/alist"                                        "alist"
  def_meta "nginx"        "Nginx Web 服务器"            "pre"   "nginx"                                            "/etc/nginx /var/log/nginx /var/www /usr/share/nginx /var/lib/nginx"          "nginx"
  def_meta "aria2"        "Aria2 多协议下载器"          "pre"   "aria2 aria2c"                                     "/etc/aria2 /var/lib/aria2 /root/.aria2"                                      "aria2"
  def_meta "vlmcsd"       "vlmcsd KMS 激活服务"         "pre"   "vlmcsd"                                           "/etc/vlmcsd /opt/vlmcsd"                                                     "vlmcsd"
  def_meta "vsftpd"       "vsFTPd FTP 服务器"           "pre"   "vsftpd"                                           "/etc/vsftpd /etc/vsftpd.conf"                                                "vsftpd"
  def_meta "nfs"          "NFS 网络文件共享"             "pre"   "nfs-server nfs-kernel-server rpcbind"             "/var/lib/nfs"                                                                "nfs-kernel-server nfs-common rpcbind"
  def_meta "php"          "PHP 运行环境(多版本)"         "pre"   "php-fpm php7.4-fpm php8.0-fpm php8.1-fpm php8.2-fpm" "/etc/php /var/lib/php /var/run/php"                                  "php"
  def_meta "emby"         "Emby 媒体服务器"             "pre"   "emby-server"                                      "/etc/emby-server /var/lib/emby-server /opt/emby-server"                     "emby-server"
  def_meta "qbittorrent"  "qBittorrent BT下载器"        "pre"   "qbittorrent qbittorrent-nox"                      "/etc/qbittorrent /var/lib/qbittorrent /root/.config/qBittorrent"             "qbittorrent qbittorrent-nox"
  def_meta "minidlna"     "miniDLNA 局域网媒体推送"      "pre"   "minidlna"                                         "/etc/minidlna /var/lib/minidlna /var/cache/minidlna"                         "minidlna"
  def_meta "mrdoc"        "觅思文档 MrDoc"              "pre"   "mrdoc"                                            "/opt/mrdoc /etc/mrdoc /var/lib/mrdoc"                                        ""
  def_meta "casaos"       "CasaOS 可视化系统面板"        "pre"   "casaos casaos-gateway casaos-user-service casaos-message-bus casaos-app-management" "/etc/casaos /var/lib/casaos /opt/casaos" ""
  def_meta "portainer"    "Portainer Docker 管理面板"    "pre"   "portainer"                                        "/opt/portainer /var/lib/docker/volumes/portainer_data"                      ""
  def_meta "jellyfin"     "Jellyfin 媒体服务器"          "pre"   "jellyfin"                                         "/etc/jellyfin /var/lib/jellyfin /var/cache/jellyfin"                         "jellyfin"
  def_meta "mysql"        "MySQL 数据库"                "pre"   "mysql mysqld"                                     "/etc/mysql /var/lib/mysql /var/log/mysql"                                    "mysql-server mysql-common"
  def_meta "wordpress"    "WordPress 博客系统"           "pre"   "wordpress"                                        "/var/www/wordpress /opt/wordpress"                                           ""
  def_meta "v2ray"        "V2Ray / Xray 代理"           "pre"   "v2ray xray"                                       "/etc/v2ray /etc/xray /opt/v2ray /usr/local/etc/xray"                         ""
}
scan_histb_pkgs(){
  SCAN_HISTB=()
  local pkg name
  while read -r pkg; do
    [[ -z "$pkg" ]] && continue
    echo "$pkg" | grep -qiE "samba|smb|nmb" && continue
    SCAN_HISTB+=("$pkg")
    name="${pkg%-histb}"
    if [[ -z "${META_DESC[$name]:-}" ]]; then
      META_DESC["$name"]="$pkg"
      META_TYPE["$name"]="histb"
      META_SVCS["$name"]="$name"
      META_DIRS["$name"]="/etc/$name /var/lib/$name /opt/$name"
      META_PKGS["$name"]="$pkg"
      log WARN "动态发现未知仓库包: $pkg，已使用通用元数据"
    fi
  done < <(dpkg -l 2>/dev/null | awk '/^(ii|rc)/{print $2}' | grep -i "\-histb$")
}
scan_pre_pkgs(){
  SCAN_PRE=()
  local known_pre=(
    alist nginx aria2 vlmcsd vsftpd nfs php emby qbittorrent
    minidlna mrdoc casaos portainer jellyfin mysql wordpress v2ray
    transmission ttyd filebrowser tailscale
  )
  local name svc
  for name in "${known_pre[@]}"; do
    local pkgs="${META_PKGS[$name]:-$name}"
    local svcs="${META_SVCS[$name]:-$name}"
    local found=false
    for pk in $pkgs; do
      dpkg -l 2>/dev/null | awk '/^(ii|rc)/{print $2}' | grep -qi "^${pk}" && found=true && break
    done
    if ! $found; then
      for svc in $svcs; do
        systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qi "^${svc}" && found=true && break
      done
    fi
    $found && SCAN_PRE+=("$name")
  done
  local dpkg_extra
  while read -r dpkg_extra; do
    [[ -z "$dpkg_extra" ]] && continue
    echo "$dpkg_extra" | grep -qiE "histb|samba|smb|nmb|lib|linux|kernel|python|perl|dpkg|apt|base|util|core|bash|grep|sed|awk" && continue
    local already=false en
    for en in "${SCAN_PRE[@]}" "${SCAN_HISTB[@]}"; do
      [[ "$en" == "$dpkg_extra" || "${META_PKGS[$en]:-}" == *"$dpkg_extra"* ]] && already=true && break
    done
    $already && continue
    if [[ -z "${META_DESC[$dpkg_extra]:-}" ]]; then
      META_DESC["$dpkg_extra"]="$dpkg_extra"
      META_TYPE["$dpkg_extra"]="pre"
      META_SVCS["$dpkg_extra"]="$dpkg_extra"
      META_DIRS["$dpkg_extra"]="/etc/$dpkg_extra /var/lib/$dpkg_extra /opt/$dpkg_extra"
      META_PKGS["$dpkg_extra"]="$dpkg_extra"
    fi
  done < <(dpkg -l 2>/dev/null | awk '/^ii/{print $2}' | grep -v "^lib" | \
    xargs -I{} dpkg-query -W -f='${Package} ${Section}\n' {} 2>/dev/null | \
    awk '$2~/net|web|utils|misc/{print $1}' | sort -u | head -30)
}
get_pkg_size_kb(){
  local pkgs="${1:-}"; local total=0 pk s
  for pk in $pkgs; do
    s=$(dpkg-query -W -f='${Installed-Size}' "$pk" 2>/dev/null || echo 0)
    (( total += s ))
  done
  echo $total
}
get_run_status(){
  local name="${1:-}"
  local svcs="${META_SVCS[$name]:-$name}"
  local pkgs="${META_PKGS[$name]:-$name}"
  local svc pk
  for svc in $svcs; do
    systemctl is-active --quiet "$svc" 2>/dev/null && echo "run" && return
  done
  for pk in $pkgs; do
    dpkg -l 2>/dev/null | grep -qE "^ii\s+${pk}" && echo "inst" && return
  done
  for pk in $pkgs; do
    dpkg -l 2>/dev/null | grep -qE "^rc\s+${pk}" && echo "rc" && return
  done
  echo "det"
}
stop_svc(){
  local svc="${1:-}"; [[ -z "$svc" ]] && return
  systemctl is-active --quiet "$svc" 2>/dev/null && {
    $DRY && { log ACT "[DRY] 停止: $svc"; return; }
    systemctl stop "$svc" 2>/dev/null && log INFO "已停止: $svc" || log WARN "停止失败: $svc"
  }
  systemctl is-enabled --quiet "$svc" 2>/dev/null && {
    $DRY || systemctl disable "$svc" 2>/dev/null || true
  }
  local pids; pids=$(pgrep -f "^.*${svc}" 2>/dev/null || true)
  [[ -n "$pids" ]] && ! $DRY && {
    kill $pids 2>/dev/null || true; sleep 1
    pids=$(pgrep -f "^.*${svc}" 2>/dev/null || true)
    [[ -n "$pids" ]] && kill -9 $pids 2>/dev/null || true
  }
}
clean_systemd(){
  local name="${1:-}"; [[ -z "$name" ]] && return
  local found=() f uf un
  while IFS= read -r -d '' f; do
    echo "$f" | grep -qiE "samba|smb|nmb" || found+=("$f")
  done < <(find /etc/systemd/system/ /lib/systemd/system/ /usr/lib/systemd/system/ \
    -name "*${name}*" -print0 2>/dev/null)
  for uf in "${found[@]}"; do
    un=$(basename "$uf")
    $DRY && { log ACT "[DRY] 删除 unit: $uf"; continue; }
    systemctl stop "$un" 2>/dev/null || true
    systemctl disable "$un" 2>/dev/null || true
    rm -f "$uf"; log INFO "删除 unit: $uf"
  done
  [[ ${#found[@]} -gt 0 ]] && ! $DRY && systemctl daemon-reload
}
clean_cron(){
  local name="${1:-}"; [[ -z "$name" ]] && return; local cf cd ff
  for cf in /etc/cron.d/*; do
    [[ -f "$cf" ]] && grep -qi "$name" "$cf" 2>/dev/null && {
      $DRY && log ACT "[DRY] 删除 cron: $cf" || { rm -f "$cf"; log INFO "删除 cron: $cf"; }
    }
  done
  for cd in /etc/cron.daily /etc/cron.weekly /etc/cron.monthly /etc/cron.hourly; do
    [[ -d "$cd" ]] && find "$cd" -name "*${name}*" 2>/dev/null | while read -r ff; do
      $DRY && log ACT "[DRY] 删除: $ff" || { rm -f "$ff"; log INFO "删除: $ff"; }
    done
  done
  crontab -l 2>/dev/null | grep -qi "$name" && {
    $DRY && log ACT "[DRY] 清理 crontab 中 $name" || {
      crontab -l 2>/dev/null | grep -vi "$name" | crontab - 2>/dev/null
      log INFO "已清理 crontab 中 $name 条目"
    }
  }
}
do_purge(){
  local pkgs="${1:-}"; [[ -z "$pkgs" ]] && return; local pk
  for pk in $pkgs; do
    dpkg -l 2>/dev/null | grep -qE "^(ii|rc)\s+${pk}" || continue
    $DRY && { log ACT "[DRY] purge: $pk"; continue; }
    apt-get purge "$pk" -y 2>/dev/null || true
    dpkg --purge "$pk" 2>/dev/null || true
    log INFO "已 purge: $pk"
  done
}
clean_dirs(){
  local dirs="${1:-}"; [[ -z "$dirs" ]] && return; local d ed
  for d in $dirs; do
    for ed in $d; do
      [[ -e "$ed" ]] && {
        $DRY && log ACT "[DRY] 删除: $ed" || { rm -rf "$ed"; log INFO "已删除: $ed"; }
      }
    done
  done
}
uninstall_one(){
  local name="${1:-}"; [[ -z "$name" ]] && return
  local desc="${META_DESC[$name]:-$name}"
  local type="${META_TYPE[$name]:-pre}"
  local svcs="${META_SVCS[$name]:-}"
  local dirs="${META_DIRS[$name]:-}"
  local pkgs="${META_PKGS[$name]:-}"
  log INFO "┌── 开始卸载: ${desc} (${name})"
  local svc
  for svc in $svcs; do stop_svc "$svc"; done
  clean_cron "$name"
  [[ "$name" == "php" ]] && ! $DRY && { apt-get purge 'php*' -y 2>/dev/null || true; }
  do_purge "$pkgs"
  clean_systemd "$name"
  clean_dirs "$dirs"
  ! $DRY && {
    find /var/log -name "*${name}*" -delete 2>/dev/null || true
    find /home -maxdepth 2 -type d -name ".${name}" -exec rm -rf {} + 2>/dev/null || true
    rm -rf "$HOME/.${name}" 2>/dev/null || true
  }
  log INFO "└── 完成卸载: ${name}"
}
deep_clean(){
  echo -e "\n${W}  ▶ 执行深度清理...${NC}"
  $DRY && { log ACT "[DRY] 跳过实际清理操作"; return; }
  apt-get autoremove --purge -y 2>/dev/null || true
  local rc_pkgs
  rc_pkgs=$(dpkg -l 2>/dev/null | grep "^rc" | awk '{print $2}' | grep -viE "samba|smb|nmb" || true)
  [[ -n "$rc_pkgs" ]] && {
    log WARN "清理 dpkg rc 残留包..."
    echo "$rc_pkgs" | xargs dpkg --purge 2>/dev/null || true
  }
  dpkg --configure -a 2>/dev/null || true
  apt-get -f install -y 2>/dev/null || true
  apt-get clean; apt-get autoclean
  systemctl list-units --state=failed --no-pager --no-legend 2>/dev/null | awk '{print $1}' | while read -r u; do
    systemctl reset-failed "$u" 2>/dev/null || true
  done
  journalctl --vacuum-time=3d 2>/dev/null || true
  find /tmp -type f -atime +7 -delete 2>/dev/null || true
  find /var/log \( -name "*.gz" -o -name "*.old" -o -name "*.[0-9]" \) -delete 2>/dev/null || true
  rm -rf /var/www/html 2>/dev/null || true
  rm -f /etc/first_init.d/web.sh 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
  log INFO "深度清理完成"
}
verify_one(){
  local name="${1:-}"; [[ -z "$name" ]] && return
  local pkgs="${META_PKGS[$name]:-}" svcs="${META_SVCS[$name]:-}" issues=() pk svc
  for pk in $pkgs; do
    dpkg -l 2>/dev/null | grep -qE "^ii\s+${pk}" && issues+=("包仍存在")
  done
  for pk in $pkgs; do
    dpkg -l 2>/dev/null | grep -qE "^rc\s+${pk}" && issues+=("rc残留")
  done
  pgrep -f "$name" &>/dev/null && issues+=("进程运行中")
  for svc in $svcs; do
    systemctl is-active --quiet "$svc" 2>/dev/null && issues+=("服务未停") && break
  done
  local desc="${META_DESC[$name]:-$name}"
  if [[ ${#issues[@]} -eq 0 ]]; then
    printf "  ${G}✓${NC} %-14s %-20s ${G}彻底清除${NC}\n" "$name" "$desc"
  else
    printf "  ${R}✗${NC} %-14s %-20s ${R}%s${NC}\n" "$name" "$desc" "${issues[*]}"
  fi
}
show_freed(){
  local before="${1:-0}" after="${2:-0}"
  local freed=$(( after - before ))
  (( freed < 0 )) && freed=0
  echo ""
  box_top
  box_row "  💾 本次操作存储报告"
  box_mid
  box_row "  操作前可用  $(fmt_kb $before)"
  box_row "  操作后可用  $(fmt_kb $after)"
  box_row "  共释放空间  ${M}$(fmt_kb $freed) ✨${NC}"
  box_bot
}
render_select_screen(){
  local -n _cands=$1
  local mode_label="$2"
  clear
  box_top
  box_row "  ${W}海纳思系统清理  ·  ${mode_label}${NC}"
  box_row "  ${DIM}[输入编号] 切换保留/卸载  [a] 全选  [k] 全不选  [q] 确认${NC}"
  box_mid
  local counter=1 name idx desc pkgs sz sz_str st type_tag chk_icon chk_color
  local checked_count=0
  for name in "${_cands[@]}"; do
    desc="${META_DESC[$name]:-$name}"
    pkgs="${META_PKGS[$name]:-}"
    sz=$(get_pkg_size_kb "$pkgs")
    sz_str=$(fmt_kb "$sz")
    st=$(get_run_status "$name")
    local type_="${META_TYPE[$name]:-}"
    case "$type_" in
      histb) type_tag="${C}仓库${NC}" ;;
      pre)   type_tag="${M}预装${NC}" ;;
      *)     type_tag="${Y}其他${NC}" ;;
    esac
    local st_label=""
    case "$st" in
      run)  st_label="${G}运行中${NC}" ;;
      inst) st_label="${Y}已安装${NC}" ;;
      rc)   st_label="${R}残留${NC}"   ;;
      *)    st_label="${DIM}检测到${NC}" ;;
    esac
    if [[ "${CHECKED[$name]:-true}" == "true" ]]; then
      chk_icon="${R}✗${NC}" chk_color="$R"
      (( checked_count++ ))
    else
      chk_icon="${G}✓${NC}" chk_color="$G"
    fi
    local line_plain
    line_plain=$(printf "  [x] %2d. %-13s %-20s [xx] %-6s ~%s" \
      "$counter" "$name" "$desc" "" "$sz_str")
    local pad=$(( 62 - $(str_width "$line_plain") ))
    (( pad < 0 )) && pad=0
    printf "${B}│${NC}  [%b] %2d. ${chk_color}%-13s${NC} %-20s [%b] %-6s %s %*s${B}│${NC}\n" \
      "$chk_icon" "$counter" "$name" "$desc" "$type_tag" "$st_label" "~${sz_str}" "$pad" ""
    (( counter++ ))
  done
  box_mid
  box_row "  ${W}已标记卸载: ${checked_count} 个 / 共检测到: ${#_cands[@]} 个${NC}"
  box_bot
}
interactive_select(){
  local mode="${1:-all}"
  local -a candidates=()
  local name
  if [[ "$mode" == "histb" ]]; then
    for name in "${SCAN_HISTB[@]}"; do
      candidates+=("${name%-histb}")
    done
  elif [[ "$mode" == "pre" ]]; then
    for name in "${SCAN_PRE[@]}"; do candidates+=("$name"); done
  else
    for name in "${SCAN_HISTB[@]}"; do candidates+=("${name%-histb}"); done
    for name in "${SCAN_PRE[@]}"; do
      local already=false n2
      for n2 in "${candidates[@]}"; do [[ "$n2" == "$name" ]] && already=true && break; done
      $already || candidates+=("$name")
    done
  fi
  [[ ${#candidates[@]} -eq 0 ]] && { log WARN "未在系统中检测到任何可操作的软件"; return; }
  for name in "${candidates[@]}"; do CHECKED["$name"]="true"; done
  local mode_label
  case "$mode" in
    histb) mode_label="仓库包管理" ;;
    pre)   mode_label="预装软件管理" ;;
    *)     mode_label="全部软件总览" ;;
  esac
  local input num tidx tname
  while true; do
    render_select_screen candidates "$mode_label"
    echo ""
    read -rp "  请输入编号(多个空格分隔) / a=全选卸载 / k=全部保留 / q=确认: " input
    case "$input" in
      q|Q) break ;;
      a|A) for name in "${candidates[@]}"; do CHECKED["$name"]="true";  done ;;
      k|K) for name in "${candidates[@]}"; do CHECKED["$name"]="false"; done ;;
      *)
        for num in $input; do
          [[ "$num" =~ ^[0-9]+$ ]] || continue
          tidx=$(( num - 1 ))
          [[ $tidx -ge 0 && $tidx -lt ${#candidates[@]} ]] || { log WARN "编号 $num 超出范围"; continue; }
          tname="${candidates[$tidx]}"
          if [[ "${CHECKED[$tname]:-true}" == "true" ]]; then
            CHECKED["$tname"]="false"
          else
            CHECKED["$tname"]="true"
          fi
        done
        ;;
    esac
  done
  local to_do=() kept=()
  for name in "${candidates[@]}"; do
    if [[ "${CHECKED[$name]:-true}" == "true" ]]; then
      to_do+=("$name")
    else
      kept+=("$name")
    fi
  done
  [[ ${#to_do[@]} -eq 0 ]] && { log WARN "未选择任何软件，返回菜单"; return; }
  clear
  box_top
  box_row "  ${W}确认清单 · 请仔细核对后输入 YES 执行${NC}"
  box_mid
  box_row "  ${R}▼ 将要卸载 (${#to_do[@]} 个)${NC}"
  local idx j
  for name in "${to_do[@]}"; do
    printf "${B}│${NC}    ${R}✗${NC}  %-14s %s\n" "$name" "${META_DESC[$name]:-}"
  done
  [[ ${#kept[@]} -gt 0 ]] && {
    box_row "  ${G}▼ 将会保留 (${#kept[@]} 个)${NC}"
    for name in "${kept[@]}"; do
      printf "${B}│${NC}    ${G}✓${NC}  %-14s %s\n" "$name" "${META_DESC[$name]:-}"
    done
  }
  box_bot
  echo ""
  read -rp "  输入 YES 确认执行，其他键返回: " confirm
  [[ "$confirm" != "YES" && "$confirm" != "yes" ]] && { log INFO "已取消"; return; }
  local before; before=$(disk_free_kb)
  echo ""
  for name in "${to_do[@]}"; do uninstall_one "$name"; done
  deep_clean
  local after; after=$(disk_free_kb)
  echo ""
  box_top
  box_row "  ${W}卸载验证报告${NC}"
  box_mid
  for name in "${to_do[@]}"; do verify_one "$name"; done
  box_bot
  show_freed "$before" "$after"
  echo -e "\n  ${DIM}日志已保存: ${LOG}${NC}\n"
}
secure_ssh(){
  clear; box_top; box_row "  ${W}SSH 安全加固配置${NC}"; box_bot
  local cfg="/etc/ssh/sshd_config"
  [[ -f "$cfg" ]] || { log ERR "找不到 $cfg"; return; }
  local bak="${cfg}.bak.$(date +%Y%m%d_%H%M%S)"
  cp "$cfg" "$bak"; log INFO "原配置已备份: $bak"
  echo ""
  echo -e "  ${W}1${NC})  关闭 X11 转发          (关闭 6010 端口泄漏)"
  echo -e "  ${W}2${NC})  修改 SSH 监听端口       (降低暴力扫描风险)"
  echo -e "  ${W}3${NC})  禁用密码登录            (仅允许密钥认证)"
  echo -e "  ${W}4${NC})  限制 Root 远程登录      (prohibit-password模式)"
  echo -e "  ${W}5${NC})  强化登录超时与重试限制"
  echo -e "  ${W}6${NC})  一键应用全部推荐配置"
  echo -e "  ${W}q${NC})  返回"
  echo ""
  read -rp "  请选择: " sc
  case "$sc" in
    1) sed -i 's/^#*X11Forwarding.*/X11Forwarding no/' "$cfg"; log INFO "X11转发已关闭" ;;
    2) local cur; cur=$(grep -oP '^\s*Port\s+\K\d+' "$cfg" 2>/dev/null || echo 22)
       echo -e "  当前端口: ${Y}${cur}${NC}"
       while true; do
         read -rp "  输入新端口 (1024-65535): " np
         [[ "$np" =~ ^[0-9]+$ ]] && (( np>=1024 && np<=65535 )) || { log ERR "端口不合法"; continue; }
         ss -tuln | grep -q ":${np} " && { log ERR "端口 $np 已被占用"; continue; }
         sed -i "s/^#*\s*Port .*/Port ${np}/" "$cfg"
         command -v ufw &>/dev/null && {
           ufw allow "${np}/tcp" comment "SSH" 2>/dev/null || true
           ufw delete allow "${cur}/tcp" 2>/dev/null || true
         }
         log INFO "SSH 端口已修改为: $np"; break
       done ;;
    3) [[ -s "$HOME/.ssh/authorized_keys" ]] || { log ERR "未找到授权密钥，请先执行 ssh-copy-id"; return; }
       read -rp "  确认已有可用密钥？禁用密码登录？[y/N]: " c
       [[ "$c" =~ ^[yY]$ ]] && {
         sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' "$cfg"
         sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' "$cfg"
         log INFO "密码认证已禁用，仅允许密钥登录"
       } ;;
    4) sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' "$cfg"
       log INFO "Root 远程登录已限制为仅密钥" ;;
    5) sed -i 's/^#*LoginGraceTime.*/LoginGraceTime 30/' "$cfg"
       sed -i 's/^#*MaxAuthTries.*/MaxAuthTries 3/' "$cfg"
       sed -i 's/^#*MaxSessions.*/MaxSessions 5/' "$cfg"
       sed -i 's/^#*ClientAliveInterval.*/ClientAliveInterval 300/' "$cfg"
       sed -i 's/^#*ClientAliveCountMax.*/ClientAliveCountMax 2/' "$cfg"
       log INFO "已设置: 超时30s / 最大重试3次 / 心跳300s" ;;
    6) sed -i 's/^#*X11Forwarding.*/X11Forwarding no/' "$cfg"
       sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' "$cfg"
       sed -i 's/^#*LoginGraceTime.*/LoginGraceTime 30/' "$cfg"
       sed -i 's/^#*MaxAuthTries.*/MaxAuthTries 3/' "$cfg"
       sed -i 's/^#*MaxSessions.*/MaxSessions 5/' "$cfg"
       sed -i 's/^#*ClientAliveInterval.*/ClientAliveInterval 300/' "$cfg"
       sed -i 's/^#*ClientAliveCountMax.*/ClientAliveCountMax 2/' "$cfg"
       sed -i 's/^#*PermitEmptyPasswords.*/PermitEmptyPasswords no/' "$cfg"
       sed -i 's/^#*UseDNS.*/UseDNS no/' "$cfg"
       grep -q "^Protocol" "$cfg" || echo "Protocol 2" >> "$cfg"
       log INFO "全部推荐 SSH 配置已应用" ;;
    q|Q) return ;;
  esac
  [[ "$sc" == "q" || "$sc" == "Q" ]] && return
  if sshd -t 2>/dev/null; then
    systemctl restart sshd
    local fp; fp=$(grep -oP '^\s*Port\s+\K\d+' "$cfg" 2>/dev/null || echo 22)
    echo ""
    echo -e "  ${G}SSH 已重启成功${NC}"
    echo -e "  ${R}⚠  重要：请新开终端验证  ssh -p ${fp} root@<IP>  可连接后再关闭此窗口！${NC}"
  else
    log ERR "SSH 配置语法有误，正在自动还原备份..."
    cp "$bak" "$cfg"
  fi
}
health_check(){
  clear; box_top; box_row "  ${W}系统健康检查${NC}"; box_bot
  echo ""
  echo -e "  ${W}[ 动态扫描结果 ]${NC}"
  printf "  %-22s %s\n" "仓库包 (*-histb):" "${#SCAN_HISTB[@]} 个"
  printf "  %-22s %s\n" "预装/扩展软件:"   "${#SCAN_PRE[@]} 个"
  echo ""
  echo -e "  ${W}[ histb 仓库包列表 ]${NC}"
  local hp; hp=$(dpkg -l 2>/dev/null | grep -i "histb" | grep -viE "samba|smb|nmb" | \
    awk '{printf "  %-4s %-30s %s\n",$1,$2,$3}')
  [[ -n "$hp" ]] && echo "$hp" || echo -e "  ${G}无 histb 包${NC}"
  echo ""
  echo -e "  ${W}[ dpkg rc 残留配置 ]${NC}"
  local rcp; rcp=$(dpkg -l 2>/dev/null | grep "^rc" | grep -viE "samba|smb|nmb" | awk '{print $2}' || true)
  if [[ -n "$rcp" ]]; then
    echo -e "  ${Y}以下包已删除但配置残留:${NC}"
    echo "$rcp" | while read -r p; do printf "  ${Y}·${NC} %s\n" "$p"; done
    echo -e "  ${DIM}提示: 可运行菜单[4] 深度清理一键处理${NC}"
  else
    echo -e "  ${G}无残留配置${NC}"
  fi
  echo ""
  echo -e "  ${W}[ systemd 失败服务 ]${NC}"
  local fs; fs=$(systemctl list-units --state=failed --no-pager --no-legend 2>/dev/null | awk '{print $1}' || true)
  [[ -n "$fs" ]] && echo -e "  ${R}${fs}${NC}" || echo -e "  ${G}无失败服务${NC}"
  echo ""
  echo -e "  ${W}[ 磁盘使用 ]${NC}"
  df -h / | awk 'NR==2{printf "  根分区  总计:%-6s  已用:%-6s  可用:%-6s  使用率:%s\n",$2,$3,$4,$5}'
  echo ""
  echo -e "  ${W}[ 内存使用 ]${NC}"
  free -h | awk 'NR==2{printf "  总计:%-6s  已用:%-6s  空闲:%-6s\n",$2,$3,$4}'
  echo ""
  echo -e "  ${W}[ 当前监听端口 ]${NC}"
  ss -tlnp 2>/dev/null | awk 'NR>1{printf "  %-22s %s\n",$4,$6}' | head -20
}
main_menu(){
  while true; do
    scan_histb_pkgs
    scan_pre_pkgs
    local free_now; free_now=$(disk_free_kb)
    local histb_count="${#SCAN_HISTB[@]}"
    local pre_count="${#SCAN_PRE[@]}"
    local total_count=$(( histb_count + pre_count ))
    clear
    box_top
    box_row "  ${W}海纳思 (histb) 系统清理工具 v4.0${NC} "
    box_row "  ${DIM}日志: ${LOG}${NC}"
    box_mid
    box_row "  💾 当前可用存储  ${G}$(fmt_kb $free_now)${NC}"
    box_row "  🔍 动态扫描结果  仓库包 ${C}${histb_count}${NC} 个   预装/扩展 ${M}${pre_count}${NC} 个   共 ${W}${total_count}${NC} 个"
    $DRY && box_row "  ${Y}⚠  DRY-RUN 模式已启用，不会实际修改系统${NC}"
    box_mid
    printf "${B}│${NC}  ${W}%-4s${NC}  %-55s${B}│${NC}\n" "[1]" "卸载仓库包       自动扫描 dpkg 中所有 *-histb 包"
    printf "${B}│${NC}  ${W}%-4s${NC}  %-55s${B}│${NC}\n" "[2]" "卸载预装软件     扫描系统已安装的内置/扩展应用"
    printf "${B}│${NC}  ${W}%-4s${NC}  %-55s${B}│${NC}\n" "[3]" "全部软件总览     一屏显示全部，自由勾选保留或卸载"
    printf "${B}│${NC}  ${W}%-4s${NC}  %-55s${B}│${NC}\n" "[4]" "深度系统清理     孤立包 / rc残留 / APT缓存 / 旧日志"
    printf "${B}│${NC}  ${W}%-4s${NC}  %-55s${B}│${NC}\n" "[5]" "SSH 安全加固     端口 / 密钥 / 超时 / Root权限"
    printf "${B}│${NC}  ${W}%-4s${NC}  %-55s${B}│${NC}\n" "[6]" "系统健康检查     包状态 / 服务 / 端口 / 磁盘 / 内存"
    printf "${B}│${NC}  ${R}%-4s${NC}  %-55s${B}│${NC}\n" "[q]" "退出"
    box_bot
    echo ""
    read -rp "  请选择操作 [1-6/q]: " choice
    case "$choice" in
      1) interactive_select "histb" ;;
      2) interactive_select "pre"   ;;
      3) interactive_select "all"   ;;
      4)
        local b; b=$(disk_free_kb)
        deep_clean
        local a; a=$(disk_free_kb)
        show_freed "$b" "$a"
        ;;
      5) secure_ssh   ;;
      6) health_check ;;
      q|Q) echo -e "\n${G}  再见！${NC}\n"; exit 0 ;;
      *) log WARN "无效输入: $choice" ;;
    esac
    echo ""
    read -rp "  按 Enter 返回主菜单..." _
  done
}
parse_args(){
  for arg in "${@:-}"; do
    case "$arg" in
      --dry-run) DRY=true ;;
      --help|-h) echo "用法: sudo $0 [--dry-run]"; exit 0 ;;
    esac
  done
}
parse_args "$@"
check_root
mkdir -p "$(dirname "$LOG")"
init_meta
main_menu
