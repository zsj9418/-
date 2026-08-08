#!/bin/bash
set -eo pipefail
R='\033[0;31m' G='\033[0;32m' Y='\033[0;33m' B='\033[0;34m' C='\033[0;36m' M='\033[0;35m' W='\033[1;37m' D='\033[2m' NC='\033[0m'
LOG="/var/log/histb-cleanup-$(date +%Y%m%d_%H%M%S).log"
DRY=false
DPKG_CACHE=""
UNIT_CACHE=""
declare -A CHECKED=()
declare -A META_DESC=() META_SVCS=() META_DIRS=() META_PKGS=() META_TYPE=() META_SIZE=() META_STATUS=()
declare -a SCAN_HISTB=() SCAN_PRE=()
HR="────────────────────────────────────────────────────────"
log(){
  local l="${1:-INFO}"
  shift
  local m="${*:-}"
  echo "$(date '+%H:%M:%S') [$l] $m" >> "$LOG"
  case $l in
    INFO) echo -e "${G}[✓]${NC} $m" ;;
    WARN) echo -e "${Y}[!]${NC} $m" ;;
    ERR)  echo -e "${R}[✗]${NC} $m" ;;
    ACT)  echo -e "${B}[→]${NC} $m" ;;
  esac
}
check_root(){
  [ "$(id -u)" -eq 0 ] || { echo -e "${R}请使用 sudo 或 root 运行${NC}"; exit 1; }
}
disk_free_kb(){
  df / 2>/dev/null | awk 'NR==2{print $4}'
}
fmt_kb(){
  local k="${1:-0}"
  k=$(echo "$k" | tr -cd '0-9')
  k="${k:-0}"
  if (( k >= 1048576 )); then
    awk "BEGIN{printf \"%.2fGB\", $k/1048576}"
  elif (( k >= 1024 )); then
    awk "BEGIN{printf \"%.1fMB\", $k/1024}"
  else
    echo "${k}KB"
  fi
}
refresh_cache(){
  DPKG_CACHE=$(dpkg -l 2>/dev/null)
  UNIT_CACHE=$(systemctl list-unit-files 2>/dev/null)
}
def(){
  local n="$1" desc="$2" type="$3" svcs="$4" dirs="$5" pkgs="$6"
  META_DESC["$n"]="${desc:-$n}"
  META_TYPE["$n"]="${type:-pre}"
  META_SVCS["$n"]="${svcs:-}"
  META_DIRS["$n"]="${dirs:-}"
  META_PKGS["$n"]="${pkgs:-}"
}
init_meta(){
  def "gitweb"        "Git 代码托管"           histb "gitweb"                                               "/etc/gitweb /var/lib/gitweb /usr/share/bak/gitweb /bin/install-gitweb.sh"    "gitweb-histb"
  def "tailscale"     "Tailscale 异地组网"      histb "tailscaled"                                           "/etc/tailscale /var/lib/tailscale /opt/tailscale /var/run/tailscale"         "tailscale-histb"
  def "transmission"  "Transmission PT下载"     histb "transmission-daemon"                                  "/etc/transmission-daemon /var/lib/transmission-daemon /var/lib/transmission" "transmission-histb"
  def "ttyd"          "ttyd 网页终端"           histb "ttyd"                                                 "/etc/ttyd /var/lib/ttyd"                                                     "ttyd-histb"
  def "typecho"       "Typecho 轻量博客"        histb "typecho php-fpm php7.4-fpm"                           "/etc/typecho /var/lib/typecho /var/www/typecho"                              "typecho-histb"
  def "cronweb"       "CronWeb 定时任务"        histb "cronweb"                                              "/etc/cronweb /var/lib/cronweb"                                               "cronweb-histb"
  def "ddns"          "DDNS 动态域名解析"        histb "ddns com.linkease.ddnstoshell"                        "/etc/ddns /etc/ddnsto /var/lib/ddns"                                         "ddns-histb"
  def "filebrowser"   "FileBrowser 文件管理"     histb "filebrowser"                                          "/etc/filebrowser /opt/filebrowser /var/lib/filebrowser"                      "filebrowser-histb"
  def "frpc"          "FRP 内网穿透"            histb "frpc frps"                                            "/etc/frp /etc/frpc /etc/frps /opt/frp /var/lib/frpc"                         "frpc-histb"
  def "h5ai"          "H5ai 轻量网盘"           histb "h5ai nginx"                                           "/etc/h5ai /var/lib/h5ai /var/www/h5ai"                                       "h5ai-histb"
  def "linkease"      "易有云 远程访问"          histb "com.linkease.linkeasedaemon linkease"                 "/etc/linkease /opt/linkease /var/lib/linkease"                               "linkease-histb"
  def "aliyunpan"     "阿里云盘客户端"           histb "aliyunpan"                                            "/etc/aliyunpan /opt/aliyunpan /var/lib/aliyunpan /root/.aliyunpan"           "aliyunpan-histb"
  def "onedrive"      "OneDrive 网盘同步"        histb "onedrive"                                             "/etc/onedrive /opt/onedrive /var/lib/onedrive /root/.config/onedrive"        "onedrive-public-histb"
  def "wsdd"          "wsdd Windows网络发现"     histb "wsdd"                                                 "/etc/wsdd /var/lib/wsdd"                                                     "wsdd-histb"
  def "nasinfo"       "NasInfo 系统信息面板"      histb "nasinfo"                                              "/etc/nasinfo /opt/nasinfo /var/lib/nasinfo"                                  "nasinfo-histb"
  def "bootargs"      "bootargs 启动参数工具"     histb "bootargs"                                             "/etc/bootargs /opt/bootargs"                                                 "bootargs-histb"
  def "coremark"      "CoreMark CPU跑分"         histb "coremark"                                             "/etc/coremark /opt/coremark"                                                 "coremark-histb"
  def "cpuid"         "cpuid CPU信息工具"        histb "cpuid"                                                "/etc/cpuid"                                                                  "cpuid-histb"
  def "recoverbackup" "系统备份还原工具"          histb "recoverbackup"                                        "/etc/recoverbackup /opt/recoverbackup /var/lib/recoverbackup"                "recoverbackup-histb"
  def "alist"         "Alist 多网盘聚合"         pre   "alist"                                                "/opt/alist /etc/alist /var/lib/alist"                                        "alist"
  def "nginx"         "Nginx Web服务器"          pre   "nginx"                                                "/etc/nginx /var/log/nginx /var/www /usr/share/nginx /var/lib/nginx"          "nginx"
  def "aria2"         "Aria2 多协议下载"         pre   "aria2 aria2c"                                         "/etc/aria2 /var/lib/aria2 /root/.aria2"                                      "aria2"
  def "vlmcsd"        "vlmcsd KMS激活"           pre   "vlmcsd"                                               "/etc/vlmcsd /opt/vlmcsd"                                                     "vlmcsd"
  def "vsftpd"        "vsFTPd FTP服务器"         pre   "vsftpd"                                               "/etc/vsftpd /etc/vsftpd.conf"                                                "vsftpd"
  def "nfs"           "NFS 网络文件共享"          pre   "nfs-server nfs-kernel-server rpcbind"                 "/var/lib/nfs"                                                                "nfs-kernel-server nfs-common rpcbind"
  def "php"           "PHP 运行环境"             pre   "php-fpm php7.4-fpm php8.0-fpm php8.1-fpm php8.2-fpm" "/etc/php /var/lib/php /var/run/php"                                          "php"
  def "emby"          "Emby 媒体服务器"          pre   "emby-server"                                          "/etc/emby-server /var/lib/emby-server /opt/emby-server"                      "emby-server"
  def "qbittorrent"   "qBittorrent BT下载"       pre   "qbittorrent qbittorrent-nox"                          "/etc/qbittorrent /var/lib/qbittorrent /root/.config/qBittorrent"             "qbittorrent qbittorrent-nox"
  def "minidlna"      "miniDLNA 媒体推送"         pre   "minidlna"                                             "/etc/minidlna /var/lib/minidlna /var/cache/minidlna"                         "minidlna"
  def "mrdoc"         "觅思文档 MrDoc"           pre   "mrdoc"                                                "/opt/mrdoc /etc/mrdoc /var/lib/mrdoc"                                        ""
  def "casaos"        "CasaOS 系统面板"          pre   "casaos casaos-gateway casaos-user-service casaos-message-bus casaos-app-management" "/etc/casaos /var/lib/casaos /opt/casaos" ""
  def "portainer"     "Portainer Docker面板"     pre   "portainer"                                            "/opt/portainer /var/lib/docker/volumes/portainer_data"                      ""
  def "jellyfin"      "Jellyfin 媒体服务器"       pre   "jellyfin"                                             "/etc/jellyfin /var/lib/jellyfin /var/cache/jellyfin"                         "jellyfin"
  def "mysql"         "MySQL 数据库"             pre   "mysql mysqld"                                         "/etc/mysql /var/lib/mysql /var/log/mysql"                                    "mysql-server mysql-common"
  def "wordpress"     "WordPress 博客"           pre   "wordpress"                                            "/var/www/wordpress /opt/wordpress"                                           ""
  def "v2ray"         "V2Ray/Xray 代理"          pre   "v2ray xray"                                           "/etc/v2ray /etc/xray /opt/v2ray /usr/local/etc/xray"                         ""
}
calc_pkg_size(){
  local pkgs="${1:-}"
  local total=0
  local pk s
  for pk in $pkgs; do
    s=$(dpkg-query -W -f='${Installed-Size}' "$pk" 2>/dev/null || true)
    s=$(echo "${s:-0}" | tr -cd '0-9')
    total=$(( total + ${s:-0} ))
  done
  echo "$total"
}
scan_all(){
  refresh_cache
  SCAN_HISTB=()
  SCAN_PRE=()
  META_STATUS=()
  META_SIZE=()
  local pkg name svc pk st sz svc_running
  while read -r pkg; do
    [[ -z "$pkg" ]] && continue
    echo "$pkg" | grep -qiE "samba|smb|nmb" && continue
    name="${pkg%-histb}"
    SCAN_HISTB+=("$name")
    if [[ -z "${META_DESC[$name]:-}" ]]; then
      META_DESC["$name"]="$pkg"
      META_TYPE["$name"]="histb"
      META_SVCS["$name"]="$name"
      META_DIRS["$name"]="/etc/$name /var/lib/$name /opt/$name"
      META_PKGS["$name"]="$pkg"
    fi
    st="det"
    echo "$DPKG_CACHE" | grep -qE "^rc\s+${pkg}\s" && st="rc"
    echo "$DPKG_CACHE" | grep -qE "^ii\s+${pkg}\s" && st="inst"
    svc_running=false
    for svc in ${META_SVCS[$name]:-$name}; do
      systemctl is-active --quiet "$svc" 2>/dev/null && svc_running=true && break
    done
    [[ "$svc_running" == "true" ]] && st="run"
    META_STATUS["$name"]="$st"
    sz=$(calc_pkg_size "${META_PKGS[$name]:-}")
    META_SIZE["$name"]="$sz"
  done < <(echo "$DPKG_CACHE" | awk '/^(ii|rc)/{print $2}' | grep -i "\-histb$" || true)
  local known_pre=(
    alist nginx aria2 vlmcsd vsftpd nfs php emby qbittorrent
    minidlna mrdoc casaos portainer jellyfin mysql wordpress v2ray
    transmission ttyd filebrowser tailscale
  )
  local found already n2
  for name in "${known_pre[@]}"; do
    found=false
    for pk in ${META_PKGS[$name]:-$name}; do
      echo "$DPKG_CACHE" | grep -qE "^(ii|rc)\s+${pk}\s" && found=true && break
    done
    if [[ "$found" == "false" ]]; then
      for svc in ${META_SVCS[$name]:-$name}; do
        echo "$UNIT_CACHE" | grep -q "$svc" && found=true && break
      done
    fi
    [[ "$found" == "false" ]] && continue
    already=false
    for n2 in "${SCAN_HISTB[@]}"; do
      [[ "$n2" == "$name" ]] && already=true && break
    done
    [[ "$already" == "true" ]] && continue
    SCAN_PRE+=("$name")
    st="det"
    for pk in ${META_PKGS[$name]:-$name}; do
      echo "$DPKG_CACHE" | grep -qE "^rc\s+${pk}\s" && st="rc" && break
    done
    for pk in ${META_PKGS[$name]:-$name}; do
      echo "$DPKG_CACHE" | grep -qE "^ii\s+${pk}\s" && st="inst" && break
    done
    svc_running=false
    for svc in ${META_SVCS[$name]:-$name}; do
      systemctl is-active --quiet "$svc" 2>/dev/null && svc_running=true && break
    done
    [[ "$svc_running" == "true" ]] && st="run"
    META_STATUS["$name"]="$st"
    sz=$(calc_pkg_size "${META_PKGS[$name]:-}")
    META_SIZE["$name"]="$sz"
  done
}
fmt_status(){
  case "${1:-det}" in
    run)  echo -e "${G}运行中${NC}"  ;;
    inst) echo -e "${Y}已安装${NC}"  ;;
    rc)   echo -e "${R}残留配置${NC}" ;;
    *)    echo -e "${D}已检测${NC}"  ;;
  esac
}
fmt_type(){
  case "${1:-}" in
    histb) echo -e "${C}[仓库]${NC}" ;;
    pre)   echo -e "${M}[预装]${NC}" ;;
    *)     echo -e "${D}[其他]${NC}" ;;
  esac
}
stop_svc(){
  local svc="${1:-}"
  [[ -z "$svc" ]] && return 0
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    if [[ "$DRY" == "true" ]]; then
      log ACT "[DRY] 停止: $svc"
    else
      systemctl stop "$svc" 2>/dev/null && log INFO "已停止: $svc" || log WARN "停止失败: $svc"
    fi
  fi
  if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
    [[ "$DRY" == "true" ]] || systemctl disable "$svc" 2>/dev/null || true
  fi
  local pids
  pids=$(pgrep -f "$svc" 2>/dev/null || true)
  if [[ -n "$pids" ]] && [[ "$DRY" == "false" ]]; then
    kill $pids 2>/dev/null || true
    sleep 1
    pids=$(pgrep -f "$svc" 2>/dev/null || true)
    [[ -n "$pids" ]] && kill -9 $pids 2>/dev/null || true
  fi
  return 0
}
clean_systemd(){
  local name="${1:-}"
  [[ -z "$name" ]] && return 0
  local f uf un
  declare -a found=()
  while IFS= read -r -d '' f; do
    echo "$f" | grep -qiE "samba|smb|nmb" || found+=("$f")
  done < <(find /etc/systemd/system/ /lib/systemd/system/ /usr/lib/systemd/system/ \
    -name "*${name}*" -print0 2>/dev/null)
  for uf in "${found[@]}"; do
    un=$(basename "$uf")
    if [[ "$DRY" == "true" ]]; then
      log ACT "[DRY] 删除 unit: $uf"
    else
      systemctl stop "$un" 2>/dev/null || true
      systemctl disable "$un" 2>/dev/null || true
      rm -f "$uf"
      log INFO "删除 unit: $uf"
    fi
  done
  [[ ${#found[@]} -gt 0 ]] && [[ "$DRY" == "false" ]] && systemctl daemon-reload || true
  return 0
}
clean_cron(){
  local name="${1:-}"
  [[ -z "$name" ]] && return 0
  local cf cd ff
  for cf in /etc/cron.d/*; do
    [[ -f "$cf" ]] || continue
    grep -qi "$name" "$cf" 2>/dev/null || continue
    if [[ "$DRY" == "true" ]]; then
      log ACT "[DRY] 删除 cron: $cf"
    else
      rm -f "$cf" && log INFO "删除 cron: $cf"
    fi
  done
  for cd in /etc/cron.daily /etc/cron.weekly /etc/cron.monthly /etc/cron.hourly; do
    [[ -d "$cd" ]] || continue
    while read -r ff; do
      [[ -z "$ff" ]] && continue
      if [[ "$DRY" == "true" ]]; then
        log ACT "[DRY] 删除: $ff"
      else
        rm -f "$ff" && log INFO "删除: $ff"
      fi
    done < <(find "$cd" -name "*${name}*" 2>/dev/null || true)
  done
  if crontab -l 2>/dev/null | grep -qi "$name"; then
    if [[ "$DRY" == "true" ]]; then
      log ACT "[DRY] 清理 crontab: $name"
    else
      crontab -l 2>/dev/null | grep -vi "$name" | crontab - 2>/dev/null || true
      log INFO "已清 crontab 中 $name 条目"
    fi
  fi
  return 0
}
do_purge(){
  local pkgs="${1:-}"
  [[ -z "$pkgs" ]] && return 0
  local pk
  for pk in $pkgs; do
    echo "$DPKG_CACHE" | grep -qE "^(ii|rc)\s+${pk}\s" || continue
    if [[ "$DRY" == "true" ]]; then
      log ACT "[DRY] purge: $pk"
    else
      apt-get purge "$pk" -y 2>/dev/null || true
      dpkg --purge "$pk" 2>/dev/null || true
      log INFO "已 purge: $pk"
    fi
  done
  return 0
}
clean_dirs(){
  local dirs="${1:-}"
  [[ -z "$dirs" ]] && return 0
  local d ed
  for d in $dirs; do
    for ed in $d; do
      [[ -e "$ed" ]] || continue
      if [[ "$DRY" == "true" ]]; then
        log ACT "[DRY] 删除: $ed"
      else
        rm -rf "$ed" && log INFO "已删除: $ed"
      fi
    done
  done
  return 0
}
uninstall_one(){
  local name="${1:-}"
  [[ -z "$name" ]] && return 0
  local desc="${META_DESC[$name]:-$name}"
  local svcs="${META_SVCS[$name]:-}"
  local dirs="${META_DIRS[$name]:-}"
  local pkgs="${META_PKGS[$name]:-}"
  log INFO "── 开始卸载: $desc ($name)"
  local svc
  for svc in $svcs; do stop_svc "$svc"; done
  clean_cron "$name"
  if [[ "$name" == "php" ]] && [[ "$DRY" == "false" ]]; then
    apt-get purge 'php*' -y 2>/dev/null || true
  fi
  do_purge "$pkgs"
  clean_systemd "$name"
  clean_dirs "$dirs"
  if [[ "$DRY" == "false" ]]; then
    find /var/log -name "*${name}*" -delete 2>/dev/null || true
    find /home -maxdepth 2 -type d -name ".${name}" -exec rm -rf {} + 2>/dev/null || true
    rm -rf "$HOME/.${name}" 2>/dev/null || true
  fi
  log INFO "── 完成卸载: $name"
  return 0
}
deep_clean(){
  echo -e "\n${W}正在深度清理...${NC}"
  if [[ "$DRY" == "true" ]]; then
    log ACT "[DRY] 跳过深度清理"
    return 0
  fi
  apt-get autoremove --purge -y 2>/dev/null || true
  local rc_pkgs
  rc_pkgs=$(echo "$DPKG_CACHE" | grep "^rc" | awk '{print $2}' | grep -viE "samba|smb|nmb" || true)
  if [[ -n "$rc_pkgs" ]]; then
    log WARN "清理 dpkg rc 残留包..."
    echo "$rc_pkgs" | xargs dpkg --purge 2>/dev/null || true
  fi
  dpkg --configure -a 2>/dev/null || true
  apt-get -f install -y 2>/dev/null || true
  apt-get clean
  apt-get autoclean
  systemctl list-units --state=failed --no-pager --no-legend 2>/dev/null | \
    awk '{print $1}' | while read -r u; do
      [[ -z "$u" ]] && continue
      systemctl reset-failed "$u" 2>/dev/null || true
    done
  journalctl --vacuum-time=3d 2>/dev/null || true
  find /tmp -type f -atime +7 -delete 2>/dev/null || true
  find /var/log \( -name "*.gz" -o -name "*.old" -o -name "*.[0-9]" \) -delete 2>/dev/null || true
  rm -f /etc/first_init.d/web.sh 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
  log INFO "深度清理完成"
  return 0
}
verify_one(){
  local name="${1:-}"
  [[ -z "$name" ]] && return 0
  refresh_cache
  local pkgs="${META_PKGS[$name]:-}"
  local svcs="${META_SVCS[$name]:-}"
  local pk svc
  declare -a issues=()
  for pk in $pkgs; do
    echo "$DPKG_CACHE" | grep -qE "^ii\s+${pk}\s" && issues+=("包仍存在") && break
  done
  for pk in $pkgs; do
    echo "$DPKG_CACHE" | grep -qE "^rc\s+${pk}\s" && issues+=("rc残留") && break
  done
  if pgrep -f "$name" &>/dev/null; then
    issues+=("进程仍运行")
  fi
  for svc in $svcs; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      issues+=("服务未停")
      break
    fi
  done
  if [[ ${#issues[@]} -eq 0 ]]; then
    printf "  ${G}✓${NC}  %-18s ${G}彻底清除${NC}\n" "$name"
  else
    printf "  ${R}✗${NC}  %-18s ${R}%s${NC}\n" "$name" "${issues[*]}"
  fi
  return 0
}
show_freed(){
  local before="${1:-0}" after="${2:-0}"
  local freed
  freed=$(( after - before ))
  (( freed < 0 )) && freed=0 || true
  echo ""
  echo -e "${W}$HR${NC}"
  printf "  操作前可用   ${C}%s${NC}\n" "$(fmt_kb "$before")"
  printf "  操作后可用   ${G}%s${NC}\n" "$(fmt_kb "$after")"
  printf "  共释放空间   ${M}%s ✨${NC}\n" "$(fmt_kb "$freed")"
  echo -e "${W}$HR${NC}"
  return 0
}
build_candidates(){
  local mode="$1"
  local name n2 already
  CANDIDATES=()
  case "$mode" in
    histb)
      for name in "${SCAN_HISTB[@]}"; do
        CANDIDATES+=("$name")
      done
      ;;
    pre)
      for name in "${SCAN_PRE[@]}"; do
        CANDIDATES+=("$name")
      done
      ;;
    *)
      for name in "${SCAN_HISTB[@]}"; do
        CANDIDATES+=("$name")
      done
      for name in "${SCAN_PRE[@]}"; do
        already=false
        for n2 in "${CANDIDATES[@]}"; do
          [[ "$n2" == "$name" ]] && already=true && break
        done
        [[ "$already" == "false" ]] && CANDIDATES+=("$name")
      done
      ;;
  esac
}
declare -a CANDIDATES=()
print_list(){
  local counter=1
  local name desc type_tag st_tag sz_str chk
  for name in "${CANDIDATES[@]}"; do
    desc="${META_DESC[$name]:-$name}"
    type_tag=$(fmt_type "${META_TYPE[$name]:-}")
    st_tag=$(fmt_status "${META_STATUS[$name]:-det}")
    sz_str=$(fmt_kb "${META_SIZE[$name]:-0}")
    if [[ "${CHECKED[$name]:-true}" == "true" ]]; then
      chk="${R}[卸]${NC}"
    else
      chk="${G}[留]${NC}"
    fi
    printf "  %b %2d.  %-16s  %-16s  %b  %b  ${D}~%s${NC}\n" \
      "$chk" "$counter" "$name" "$desc" "$type_tag" "$st_tag" "$sz_str"
    counter=$(( counter + 1 ))
  done
}
interactive_select(){
  local mode="${1:-all}"
  build_candidates "$mode"
  local total="${#CANDIDATES[@]}"
  if [[ $total -eq 0 ]]; then
    log WARN "未检测到任何可操作的软件"
    return 0
  fi
  local name
  for name in "${CANDIDATES[@]}"; do
    CHECKED["$name"]="true"
  done
  local input num tidx tname checked_count unchecked_count mode_label
  case "$mode" in
    histb) mode_label="仓库包管理  (*-histb 动态扫描)" ;;
    pre)   mode_label="预装软件管理  (已安装应用)" ;;
    *)     mode_label="全部软件总览" ;;
  esac
  while true; do
    clear
    echo -e "${W}$HR${NC}"
    printf "  %s  共 %d 个\n" "$mode_label" "$total"
    echo -e "  ${D}[卸]=将卸载  [留]=保留不动  输入编号切换  a=全卸  k=全留  q=确认${NC}"
    echo -e "${W}$HR${NC}"
    printf "  ${D}%-4s  %-16s  %-16s  %-6s  %-8s  %s${NC}\n" "状态" "包名" "描述" "分类" "运行状态" "大小"
    echo -e "${D}$HR${NC}"
    print_list
    echo -e "${W}$HR${NC}"
    checked_count=0
    for name in "${CANDIDATES[@]}"; do
      [[ "${CHECKED[$name]:-true}" == "true" ]] && checked_count=$(( checked_count + 1 ))
    done
    unchecked_count=$(( total - checked_count ))
    printf "  标记卸载: ${R}%d${NC} 个    标记保留: ${G}%d${NC} 个    共 %d 个\n" \
      "$checked_count" "$unchecked_count" "$total"
    echo ""
    read -rp "  请输入 > " input || true
    [[ -z "$input" ]] && continue
    case "$input" in
      q|Q) break ;;
      a|A)
        for name in "${CANDIDATES[@]}"; do CHECKED["$name"]="true";  done
        ;;
      k|K)
        for name in "${CANDIDATES[@]}"; do CHECKED["$name"]="false"; done
        ;;
      *)
        for num in $input; do
          case "$num" in
            ''|*[!0-9]*) log WARN "请输入有效编号"; sleep 1; continue ;;
          esac
          tidx=$(( num - 1 ))
          if [[ $tidx -lt 0 ]] || [[ $tidx -ge $total ]]; then
            log WARN "编号 $num 超出范围 (1-${total})"
            sleep 1
            continue
          fi
          tname="${CANDIDATES[$tidx]}"
          if [[ "${CHECKED[$tname]:-true}" == "true" ]]; then
            CHECKED["$tname"]="false"
          else
            CHECKED["$tname"]="true"
          fi
        done
        ;;
    esac
  done
  declare -a to_do=() kept=()
  for name in "${CANDIDATES[@]}"; do
    if [[ "${CHECKED[$name]:-true}" == "true" ]]; then
      to_do+=("$name")
    else
      kept+=("$name")
    fi
  done
  if [[ ${#to_do[@]} -eq 0 ]]; then
    log WARN "未选择任何软件，返回菜单"
    return 0
  fi
  clear
  echo -e "${W}$HR${NC}"
  echo -e "  确认操作清单"
  echo -e "${W}$HR${NC}"
  echo -e "  ${R}将卸载 (${#to_do[@]} 个):${NC}"
  for name in "${to_do[@]}"; do
    printf "    ${R}✗${NC}  %-18s %s\n" "$name" "${META_DESC[$name]:-}"
  done
  if [[ ${#kept[@]} -gt 0 ]]; then
    echo ""
    echo -e "  ${G}将保留 (${#kept[@]} 个):${NC}"
    for name in "${kept[@]}"; do
      printf "    ${G}✓${NC}  %-18s %s\n" "$name" "${META_DESC[$name]:-}"
    done
  fi
  echo -e "${W}$HR${NC}"
  echo ""
  read -rp "  输入 YES 确认执行，其他键返回: " confirm || true
  if [[ "$confirm" != "YES" && "$confirm" != "yes" ]]; then
    log INFO "已取消"
    return 0
  fi
  local before
  before=$(disk_free_kb)
  echo ""
  for name in "${to_do[@]}"; do
    uninstall_one "$name"
  done
  deep_clean
  local after
  after=$(disk_free_kb)
  echo ""
  echo -e "${W}$HR${NC}"
  echo -e "  卸载验证"
  echo -e "${W}$HR${NC}"
  for name in "${to_do[@]}"; do
    verify_one "$name"
  done
  show_freed "$before" "$after"
  echo -e "\n  ${D}日志: ${LOG}${NC}"
  return 0
}
secure_ssh(){
  clear
  local cfg="/etc/ssh/sshd_config"
  echo -e "${W}$HR${NC}"
  echo -e "  SSH 安全加固"
  echo -e "${W}$HR${NC}"
  if [[ ! -f "$cfg" ]]; then
    log ERR "找不到 $cfg"
    return 0
  fi
  local bak="${cfg}.bak.$(date +%Y%m%d_%H%M%S)"
  cp "$cfg" "$bak"
  log INFO "原配置已备份: $bak"
  echo ""
  echo -e "  1.  关闭 X11 转发          关闭 6010 端口防侧信道"
  echo -e "  2.  修改 SSH 监听端口      降低扫描攻击暴露面"
  echo -e "  3.  禁用密码登录           仅允许密钥认证"
  echo -e "  4.  限制 Root 远程登录     prohibit-password 模式"
  echo -e "  5.  强化超时与重试限制"
  echo -e "  6.  一键应用全部推荐配置"
  echo -e "  q.  返回"
  echo ""
  read -rp "  请选择: " sc || true
  case "$sc" in
    1)
      sed -i 's/^#*X11Forwarding.*/X11Forwarding no/' "$cfg"
      log INFO "X11 转发已关闭"
      ;;
    2)
      local cur
      cur=$(grep -oP '^\s*Port\s+\K\d+' "$cfg" 2>/dev/null || echo 22)
      echo -e "  当前端口: ${Y}${cur}${NC}"
      while true; do
        read -rp "  新端口 (1024-65535): " np || true
        case "$np" in
          ''|*[!0-9]*) log ERR "请输入纯数字端口"; continue ;;
        esac
        if (( np < 1024 || np > 65535 )); then
          log ERR "端口超出范围 1024-65535"
          continue
        fi
        if ss -tuln 2>/dev/null | grep -q ":${np} "; then
          log ERR "端口 $np 已被占用"
          continue
        fi
        sed -i "s/^#*\s*Port .*/Port ${np}/" "$cfg"
        command -v ufw &>/dev/null && {
          ufw allow "${np}/tcp" comment "SSH" 2>/dev/null || true
          ufw delete allow "${cur}/tcp" 2>/dev/null || true
        }
        log INFO "SSH 端口已改为: $np"
        break
      done
      ;;
    3)
      if [[ ! -s "$HOME/.ssh/authorized_keys" ]]; then
        log ERR "未找到 authorized_keys，请先执行 ssh-copy-id"
        return 0
      fi
      read -rp "  确认已有可用密钥，禁用密码登录? [y/N]: " c || true
      if [[ "$c" =~ ^[yY]$ ]]; then
        sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' "$cfg"
        sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' "$cfg"
        log INFO "密码认证已禁用"
      fi
      ;;
    4)
      sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' "$cfg"
      log INFO "Root 登录已限制为仅密钥"
      ;;
    5)
      sed -i 's/^#*LoginGraceTime.*/LoginGraceTime 30/'         "$cfg"
      sed -i 's/^#*MaxAuthTries.*/MaxAuthTries 3/'               "$cfg"
      sed -i 's/^#*MaxSessions.*/MaxSessions 5/'                 "$cfg"
      sed -i 's/^#*ClientAliveInterval.*/ClientAliveInterval 300/' "$cfg"
      sed -i 's/^#*ClientAliveCountMax.*/ClientAliveCountMax 2/' "$cfg"
      log INFO "超时30s / 最大重试3次 / 心跳300s 已设置"
      ;;
    6)
      sed -i 's/^#*X11Forwarding.*/X11Forwarding no/'                    "$cfg"
      sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' "$cfg"
      sed -i 's/^#*LoginGraceTime.*/LoginGraceTime 30/'                  "$cfg"
      sed -i 's/^#*MaxAuthTries.*/MaxAuthTries 3/'                       "$cfg"
      sed -i 's/^#*MaxSessions.*/MaxSessions 5/'                         "$cfg"
      sed -i 's/^#*ClientAliveInterval.*/ClientAliveInterval 300/'       "$cfg"
      sed -i 's/^#*ClientAliveCountMax.*/ClientAliveCountMax 2/'         "$cfg"
      sed -i 's/^#*PermitEmptyPasswords.*/PermitEmptyPasswords no/'      "$cfg"
      sed -i 's/^#*UseDNS.*/UseDNS no/'                                  "$cfg"
      grep -q "^Protocol" "$cfg" || echo "Protocol 2" >> "$cfg"
      log INFO "全部推荐 SSH 配置已应用"
      ;;
    q|Q) return 0 ;;
    *)   log WARN "无效选择" ; return 0 ;;
  esac
  if sshd -t 2>/dev/null; then
    systemctl restart sshd
    local fp
    fp=$(grep -oP '^\s*Port\s+\K\d+' "$cfg" 2>/dev/null || echo 22)
    log INFO "SSH 已重启，当前端口: $fp"
    echo ""
    echo -e "  ${R}⚠  请先开新终端验证  ssh -p ${fp} root@<IP>  可连通后再关闭此窗口！${NC}"
  else
    log ERR "配置语法有误，正在还原备份..."
    cp "$bak" "$cfg"
  fi
  return 0
}
health_check(){
  clear
  refresh_cache
  echo -e "${W}$HR${NC}"
  echo -e "  系统健康检查"
  echo -e "${W}$HR${NC}"
  echo ""
  echo -e "  ${W}[ 扫描汇总 ]${NC}"
  printf "  仓库包 (*-histb)   %d 个\n" "${#SCAN_HISTB[@]}"
  printf "  预装/扩展应用      %d 个\n" "${#SCAN_PRE[@]}"
  echo ""
  echo -e "  ${W}[ histb 仓库包列表 ]${NC}"
  local hp
  hp=$(echo "$DPKG_CACHE" | grep -i "histb" | grep -viE "samba|smb|nmb" | \
    awk '{printf "  %-4s  %-32s  %s\n",$1,$2,$3}' || true)
  if [[ -n "$hp" ]]; then
    echo "$hp"
  else
    echo -e "  ${G}无${NC}"
  fi
  echo ""
  echo -e "  ${W}[ dpkg rc 残留配置 ]${NC}"
  local rcp
  rcp=$(echo "$DPKG_CACHE" | grep "^rc" | grep -viE "samba|smb|nmb" | awk '{print $2}' || true)
  if [[ -n "$rcp" ]]; then
    echo -e "  ${Y}以下包已删除但配置未清理:${NC}"
    while read -r p; do
      [[ -z "$p" ]] && continue
      printf "  ${Y}·${NC} %s\n" "$p"
    done <<< "$rcp"
    echo -e "  ${D}→ 可用菜单 [4] 深度清理一键处理${NC}"
  else
    echo -e "  ${G}无残留${NC}"
  fi
  echo ""
  echo -e "  ${W}[ 失败的 systemd 服务 ]${NC}"
  local fs
  fs=$(systemctl list-units --state=failed --no-pager --no-legend 2>/dev/null | awk '{print $1}' || true)
  if [[ -n "$fs" ]]; then
    echo -e "  ${R}${fs}${NC}"
  else
    echo -e "  ${G}无失败服务${NC}"
  fi
  echo ""
  echo -e "  ${W}[ 磁盘 ]${NC}"
  df -h / | awk 'NR==2{printf "  根分区  总计:%-6s  已用:%-6s  可用:%-6s  使用率:%s\n",$2,$3,$4,$5}'
  echo ""
  echo -e "  ${W}[ 内存 ]${NC}"
  free -h | awk 'NR==2{printf "  总计:%-6s  已用:%-6s  空闲:%-6s\n",$2,$3,$4}'
  echo ""
  echo -e "  ${W}[ 监听端口 ]${NC}"
  ss -tlnp 2>/dev/null | awk 'NR>1{printf "  %-22s %s\n",$4,$6}' | head -20
  return 0
}
main_menu(){
  while true; do
    scan_all
    local free_now
    free_now=$(disk_free_kb)
    clear
    echo -e "${W}$HR${NC}"
    echo -e "  海纳思 (histb) 系统清理工具 v1.2 "
    echo -e "${W}$HR${NC}"
    printf "  当前可用存储   ${G}%s${NC}\n" "$(fmt_kb "$free_now")"
    printf "  扫描结果       仓库包 ${C}%d${NC} 个   预装/扩展 ${M}%d${NC} 个\n" \
      "${#SCAN_HISTB[@]}" "${#SCAN_PRE[@]}"
    if [[ "$DRY" == "true" ]]; then
      echo -e "  ${Y}⚠  DRY-RUN 模式：不会实际修改系统${NC}"
    fi
    echo -e "${W}$HR${NC}"
    echo -e "  ${W}1${NC}  卸载仓库包     自动扫描 dpkg 中全部 *-histb 包，自选保留"
    echo -e "  ${W}2${NC}  卸载预装软件   扫描系统已安装的内置应用，自选保留"
    echo -e "  ${W}3${NC}  全部软件总览   一屏显示全部，逐个勾选保留或卸载"
    echo -e "  ${W}4${NC}  深度系统清理   孤立包 / rc残留 / APT缓存 / 旧日志"
    echo -e "  ${W}5${NC}  SSH 安全加固   端口 / 密钥认证 / 超时 / Root权限"
    echo -e "  ${W}6${NC}  系统健康检查   包状态 / 失败服务 / 端口 / 磁盘 / 内存"
    echo -e "  ${R}q${NC}  退出"
    echo -e "${W}$HR${NC}"
    read -rp "  请选择 [1-6/q]: " choice || true
    case "$choice" in
      1) interactive_select "histb" ;;
      2) interactive_select "pre"   ;;
      3) interactive_select "all"   ;;
      4)
        local b a
        b=$(disk_free_kb)
        deep_clean
        a=$(disk_free_kb)
        show_freed "$b" "$a"
        ;;
      5) secure_ssh   ;;
      6) health_check ;;
      q|Q) echo -e "\n${G}再见！${NC}\n"; exit 0 ;;
      *) log WARN "无效输入: $choice" ;;
    esac
    echo ""
    read -rp "  按 Enter 返回主菜单..." _ || true
  done
}
parse_args(){
  local arg
  for arg in "$@"; do
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
