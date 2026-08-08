#!/bin/bash
set -o pipefail
REQ_DEPS=("curl" "jq")
OPT_DEPS=("wget")
DOCKER_BINARY_MIRRORS=(
"https://download.docker.com/linux/static/stable"
"https://mirrors.aliyun.com/docker-ce/linux/static/stable"
"https://mirrors.ustc.edu.cn/docker-ce/linux/static/stable"
"https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/static/stable"
)
COMPOSE_RELEASES_URL="https://api.github.com/repos/docker/compose/releases"
GITHUB_PROXY_PREFIXES=(
"https://ghproxy.net/"
"https://gh-proxy.com/"
"https://ghps.cc/"
"https://gh.idayer.com/"
)
REGISTRY_MIRRORS_DEFAULT=(
"https://docker.1ms.run"
"https://docker.m.daocloud.io"
"https://dockerproxy.net"
"https://docker.xuanyuan.me"
"https://hub.rat.dev"
"https://docker.m.ixdev.cn"
)
DOCKER_DIRECT_ENDPOINT="https://registry-1.docker.io/v2/"
DAEMON_BACKUP_DIR="/etc/docker/backups"
PROXY_MIRROR_URL=""
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'
DOCKER_URL=""
DOCKER_INSTALL_DIR=""
ARCH=""
OS=""
PKG_MANAGER=""
FORCE_LEGACY_DOCKER="false"
RECOMMENDED_LEGACY_DOCKER_VERSION="27.5.1"
IPV6_AVAILABLE="true"
IS_LXC="false"
IS_OPENVZ="false"
APPARMOR_RESTRICTED="false"
SPEED_TEST_RESULTS=()
BEST_DOCKER_MIRROR=""
PULL_TIMEOUT=60
LOG_DIR="/var/log/docker_manager"
LOG_FILE="${LOG_DIR}/docker_manager.log"
LOG_MAX_SIZE_MB=5
LOG_MAX_BACKUPS=3
DOCKER_VERSIONS_CACHE=""
COMPOSE_VERSIONS_CACHE=""
DEFAULT_DOCKER_DATA_ROOT="/var/lib/docker"
section() {
echo ""
echo -e "${BOLD}${CYAN}── $1${NC}"
echo -e "${CYAN}$(printf '%.s─' {1..50})${NC}"
}
hr() { echo -e "${CYAN}$(printf '%.s─' {1..50})${NC}"; }
rotate_log() {
[[ ! -f "$LOG_FILE" ]] && return 0
local size_bytes
size_bytes=$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)
local size_mb=$(( size_bytes / 1024 / 1024 ))
(( size_mb < LOG_MAX_SIZE_MB )) && return 0
[[ -f "${LOG_FILE}.${LOG_MAX_BACKUPS}.gz" ]] && rm -f "${LOG_FILE}.${LOG_MAX_BACKUPS}.gz"
for (( i = LOG_MAX_BACKUPS - 1; i >= 1; i-- )); do
[[ -f "${LOG_FILE}.${i}.gz" ]] && mv "${LOG_FILE}.${i}.gz" "${LOG_FILE}.$((i+1)).gz"
done
gzip -c "$LOG_FILE" > "${LOG_FILE}.1.gz" 2>/dev/null || true
: > "$LOG_FILE"
}
init_log() {
mkdir -p "$LOG_DIR" 2>/dev/null || true
rotate_log
echo "" >> "$LOG_FILE" 2>/dev/null || true
echo "  会话开始: $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE" 2>/dev/null || true
exec > >(tee -a "$LOG_FILE" 2>/dev/null) 2>&1
}
cleanup() {
echo -e "\n${YELLOW}检测到中断信号，正在清理...${NC}"
[[ -n "$DOCKER_INSTALL_DIR" && -d "$DOCKER_INSTALL_DIR" ]] && rm -rf "$DOCKER_INSTALL_DIR"
exit 130
}
trap cleanup INT TERM
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
echo -e "${RED}未检测到受支持的包管理器。${NC}"
exit 1
fi
}
install_dependencies() {
echo "正在检测并安装依赖..."
local missing=()
for dep in "${REQ_DEPS[@]}"; do
command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
done
[[ ${#missing[@]} -eq 0 ]] && { echo -e "${GREEN}依赖已就绪。${NC}"; return 0; }
echo "安装: ${missing[*]}"
case "$PKG_MANAGER" in
apt-get) apt-get update -qq && apt-get install -y "${missing[@]}" ;;
dnf|yum) "${PKG_MANAGER}" install -y "${missing[@]}" ;;
esac
}
get_architecture() {
local m=$(uname -m)
case "$m" in
x86_64) ARCH="x86_64" ;;
aarch64) ARCH="aarch64" ;;
armv7l) ARCH="armhf" ;;
armv6l) ARCH="armel" ;;
*) echo -e "${RED}不支持的架构: $m${NC}"; exit 1 ;;
esac
echo "$ARCH"
}
get_os_version() {
if [[ -f /etc/os-release ]]; then
local name=$(grep ^ID= /etc/os-release | cut -d= -f2 | tr -d '"')
local ver=$(grep ^VERSION_ID= /etc/os-release | cut -d= -f2 | tr -d '"')
echo "$name $ver"
else
echo "unknown"
fi
}
check_and_set_install_dir() {
local DIR="/tmp"
if [[ "$0" != "bash" && "$0" != "-bash" && "$0" != "sh" ]]; then
DIR=$(cd "$(dirname "$0")" && pwd)
fi
DOCKER_INSTALL_DIR="${DIR}/docker_install_$$"
mkdir -p "$DOCKER_INSTALL_DIR" || { echo -e "${RED}创建目录失败${NC}"; exit 1; }
echo -e "${GREEN}安装目录: $DOCKER_INSTALL_DIR${NC}"
}
_probe_url() {
local url="$1" timeout="${2:-6}"
local elapsed
elapsed=$(curl -o /dev/null -s -w "%{time_total}" --connect-timeout "$timeout" --max-time "$timeout" "$url" 2>/dev/null || echo "9.999")
awk "BEGIN{printf \"%.0f\", ${elapsed} * 1000}"
}
detect_best_docker_mirror() {
section "Docker 下载源测速"
echo "  正在探测..."
echo ""
BEST_DOCKER_MIRROR=""
local best_speed=0
local tmp_probe=$(mktemp)
for mirror in "${DOCKER_BINARY_MIRRORS[@]}"; do
local probe_url="${mirror}/${ARCH}/"
local result=$(curl -o "$tmp_probe" -s --connect-timeout 6 --max-time 10 -w "%{http_code} %{speed_download}" --range 0-51199 "$probe_url" 2>/dev/null || echo "000 0")
local http_code=$(echo "$result" | awk '{print $1}')
local dl_speed=$(echo "$result" | awk '{printf "%.0f", $2/1024}')
if [[ "$http_code" =~ ^(200|206)$ ]] && (( dl_speed > 0 )); then
printf "  ${GREEN}✓${NC}  %-55s %s KB/s\n" "$mirror" "$dl_speed"
(( dl_speed > best_speed )) && { best_speed=$dl_speed; BEST_DOCKER_MIRROR="$mirror"; }
else
printf "  ${RED}✗${NC}  %-55s 不可达\n" "$mirror"
fi
done
rm -f "$tmp_probe"
echo ""
if [[ -z "$BEST_DOCKER_MIRROR" ]]; then
echo -e "  ${YELLOW}警告：使用官方源${NC}"
BEST_DOCKER_MIRROR="https://download.docker.com/linux/static/stable"
else
echo -e "  ${GREEN}最快: ${BEST_DOCKER_MIRROR}${NC}"
fi
}
_do_curl_download() {
local url="$1" dest="$2"
echo -e "  ${CYAN}↓${NC} ${url}"
curl -fL --retry 2 --connect-timeout 15 --max-time 600 \
--progress-bar \
-o "$dest" "$url" 2>&1
local rc=$?
if [[ $rc -ne 0 ]]; then
echo -e "  ${RED}✗ 连接失败 (错误码: ${rc})${NC}"
rm -f "$dest"
return 1
fi
if [[ ! -s "$dest" ]]; then
echo -e "  ${RED}✗ 下载文件为空${NC}"
rm -f "$dest"
return 1
fi
if head -c 20 "$dest" 2>/dev/null | grep -qi '<!doctype\|<html'; then
echo -e "  ${RED}✗ 收到网页而非文件（代理可能不可用）${NC}"
rm -f "$dest"
return 1
fi
local filesize=$(du -h "$dest" 2>/dev/null | cut -f1)
echo -e "  ${GREEN}✓ 下载完成 (${filesize})${NC}"
return 0
}
download_with_fallback() {
local type="$1" url="$2" dest="$3"
rm -f "$dest" 2>/dev/null
local tried=0 total=0
case "$type" in
docker)
local suffix="$url"
local -a mirrors=()
[[ -n "$BEST_DOCKER_MIRROR" ]] && mirrors+=("$BEST_DOCKER_MIRROR")
for m in "${DOCKER_BINARY_MIRRORS[@]}"; do
[[ "$m" != "$BEST_DOCKER_MIRROR" ]] && mirrors+=("$m")
done
total=${#mirrors[@]}
for mirror in "${mirrors[@]}"; do
[[ -z "$mirror" ]] && continue
tried=$((tried+1))
echo ""
echo -e "  ${BOLD}[${tried}/${total}]${NC} ${mirror}"
if _do_curl_download "${mirror}${suffix}" "$dest"; then
return 0
fi
echo -e "  ${YELLOW}  → 切换下一个源...${NC}"
done
echo ""
echo -e "  ${RED}✗ 全部 ${total} 个源均失败${NC}"
return 1
;;
github)
local -a urls=("$url")
for prefix in "${GITHUB_PROXY_PREFIXES[@]}"; do
urls+=("${prefix}${url}")
done
total=${#urls[@]}
local labels=("GitHub 直连")
for prefix in "${GITHUB_PROXY_PREFIXES[@]}"; do
labels+=("代理 ${prefix}")
done
for i in "${!urls[@]}"; do
tried=$((tried+1))
echo ""
echo -e "  ${BOLD}[${tried}/${total}]${NC} ${labels[$i]}"
if _do_curl_download "${urls[$i]}" "$dest"; then
return 0
fi
(( tried < total )) && echo -e "  ${YELLOW}  → 切换下一个...${NC}"
done
echo ""
echo -e "  ${RED}✗ 全部 ${total} 种方式均失败${NC}"
return 1
;;
*)
_do_curl_download "$url" "$dest"
;;
esac
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
if [[ -x /usr/local/bin/docker-compose ]]; then
if head -c 4 /usr/local/bin/docker-compose 2>/dev/null | grep -q 'ELF\|#!'; then
local ver=$(docker-compose --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
if [[ -n "$ver" ]]; then
echo -e "${GREEN}docker-compose: ${ver}${NC}"
return 0
fi
else
echo -e "${YELLOW}docker-compose 文件损坏，将重新安装${NC}"
rm -f /usr/local/bin/docker-compose
fi
fi
if docker compose version >/dev/null 2>&1; then
local ver=$(docker compose version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
echo -e "${GREEN}Docker Compose 插件: ${ver}${NC}"
return 0
fi
echo -e "${YELLOW}Docker Compose 未安装${NC}"
return 1
}
_check_module() {
local mod="$1"
lsmod 2>/dev/null | grep -qw "${mod//-/_}" && return 0
modprobe "$mod" 2>/dev/null && return 0
return 1
}
_check_ipv6_available() {
[[ -f /proc/sys/net/ipv6/conf/all/disable_ipv6 ]] && \
[[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" == "0" ]] && return 0
ip -6 addr show 2>/dev/null | grep -q "inet6" && return 0
return 1
}
_detect_iptables_backend() {
command -v iptables >/dev/null 2>&1 || { echo "none"; return; }
local ver=$(iptables -V 2>/dev/null || true)
echo "$ver" | grep -qi 'nf_tables\|nft' && { echo "nft"; return; }
echo "$ver" | grep -qi 'legacy' && { echo "legacy"; return; }
local real=$(readlink -f "$(command -v iptables)" 2>/dev/null || true)
echo "$real" | grep -q 'nft' && echo "nft" || echo "legacy"
}
_detect_virt_env() {
IS_LXC="false"; IS_OPENVZ="false"
[[ -f /proc/user_beancounters ]] && { IS_OPENVZ="true"; echo -e "  ${YELLOW}⚠ OpenVZ${NC}"; return; }
grep -qa 'lxc' /proc/1/environ 2>/dev/null && { IS_LXC="true"; echo -e "  ${CYAN}LXC 容器${NC}"; return; }
[[ -f /.dockerenv ]] && { echo -e "  ${YELLOW}⚠ Docker-in-Docker${NC}"; return; }
echo -e "  ${GREEN}✓ KVM/裸金属${NC}"
}
_check_apparmor() {
APPARMOR_RESTRICTED="false"
[[ ! -r /sys/kernel/security/apparmor/profiles ]] && APPARMOR_RESTRICTED="true"
}
ensure_docker_prereqs() {
section "环境兼容性检测"
FORCE_LEGACY_DOCKER="false"
local compat_issues=()
echo -e "\n[1/5] 虚拟化环境"
_detect_virt_env
[[ "$IS_OPENVZ" == "true" ]] && { FORCE_LEGACY_DOCKER="true"; compat_issues+=("OpenVZ"); }
echo -e "\n[2/5] 内核模块"
for mod in overlay br_netfilter; do
_check_module "$mod" && echo -e "  ${GREEN}✓${NC} $mod" || echo -e "  ${YELLOW}⚠${NC} $mod"
done
echo -e "\n[3/5] iptables"
local backend=$(_detect_iptables_backend)
echo -e "  后端: ${CYAN}${backend}${NC}"
local iptables_ok="true"
if [[ "$backend" == "legacy" ]]; then
iptables -t raw -L >/dev/null 2>&1 && echo -e "  ${GREEN}✓${NC} raw表" || { echo -e "  ${RED}✗${NC} raw表"; iptables_ok="false"; compat_issues+=("raw表不可用"); }
fi
echo -e "\n[4/5] ipset"
local ipset_ok="false"
if command -v ipset >/dev/null 2>&1 && ipset list >/dev/null 2>&1; then
echo -e "  ${GREEN}✓${NC} ipset 可用"
ipset_ok="true"
else
echo -e "  ${YELLOW}尝试安装 ipset...${NC}"
case "$PKG_MANAGER" in
apt-get) apt-get install -y ipset 2>/dev/null ;;
dnf|yum) "${PKG_MANAGER}" install -y ipset 2>/dev/null ;;
esac
command -v ipset >/dev/null 2>&1 && ipset list >/dev/null 2>&1 && ipset_ok="true"
[[ "$ipset_ok" == "true" ]] && echo -e "  ${GREEN}✓${NC} 安装成功" || { echo -e "  ${RED}✗${NC} 不可用"; compat_issues+=("ipset不可用"); }
fi
echo -e "\n[5/5] IPv6 / AppArmor"
_check_ipv6_available && { IPV6_AVAILABLE="true"; echo -e "  ${GREEN}✓${NC} IPv6"; } || { IPV6_AVAILABLE="false"; echo -e "  ${YELLOW}⚠${NC} IPv6 不可用"; }
_check_apparmor
[[ "$APPARMOR_RESTRICTED" == "true" ]] && echo -e "  ${YELLOW}⚠${NC} AppArmor 受限"
local need_downgrade="false"
[[ "$ipset_ok" == "false" ]] && need_downgrade="true"
[[ "$backend" == "legacy" && "$iptables_ok" == "false" ]] && need_downgrade="true"
[[ "$FORCE_LEGACY_DOCKER" == "true" ]] && need_downgrade="true"
echo ""
if [[ "$need_downgrade" == "true" ]]; then
FORCE_LEGACY_DOCKER="true"
echo -e "  ${YELLOW}将安装兼容版本 Docker ${RECOMMENDED_LEGACY_DOCKER_VERSION}${NC}"
for issue in "${compat_issues[@]}"; do
echo -e "  ${YELLOW}•${NC} $issue"
done
else
echo -e "  ${GREEN}✓ 满足 Docker 28+ 要求${NC}"
fi
mkdir -p /etc/modules-load.d
echo -e "overlay\nbr_netfilter" > /etc/modules-load.d/docker.conf
cat > /etc/sysctl.d/99-docker.conf <<'EOF'
net.ipv4.ip_forward=1
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
EOF
sysctl --system >/dev/null 2>&1 || true
}
_get_current_data_root() {
local current=""
if [[ -f /etc/docker/daemon.json ]] && jq . /etc/docker/daemon.json >/dev/null 2>&1; then
current=$(jq -r '."data-root" // empty' /etc/docker/daemon.json 2>/dev/null)
fi
if [[ -n "$current" ]]; then
echo "$current"
else
echo "$DEFAULT_DOCKER_DATA_ROOT"
fi
}
_prepare_data_root_dir() {
local data_root="$1"
mkdir -p "$data_root" 2>/dev/null || return 1
chown root:root "$data_root" 2>/dev/null || true
chmod 711 "$data_root" 2>/dev/null || true
return 0
}
_check_data_root_fs_compat() {
local data_root="$1"
local fs_type mount_point
fs_type=$(df -T "$data_root" 2>/dev/null | awk 'END{print $2}')
mount_point=$(df -P "$data_root" 2>/dev/null | awk 'END{print $6}')
[[ -z "$fs_type" ]] && { echo -e "  ${RED}无法识别 ${data_root} 所在文件系统${NC}"; return 1; }
echo -e "  文件系统: ${CYAN}${fs_type}${NC}  挂载点: ${CYAN}${mount_point}${NC}"
case "$fs_type" in
ext4|ext3|ext2)
echo -e "  ${GREEN}✓ 该文件系统可用于 Docker data-root${NC}"
return 0
;;
xfs)
if command -v xfs_info >/dev/null 2>&1 && xfs_info "$mount_point" 2>/dev/null | grep -q 'ftype=1'; then
echo -e "  ${GREEN}✓ XFS 已启用 ftype=1，可用于 Docker data-root${NC}"
return 0
fi
echo -e "  ${RED}✗ XFS 未检测到 ftype=1，overlay2 可能无法工作${NC}"
return 1
;;
ntfs|ntfs3|exfat|vfat|fuseblk|msdos)
echo -e "  ${RED}✗ ${fs_type} 不适合作为 Docker data-root${NC}"
echo -e "  ${YELLOW}  原因: 不支持 Docker 需要的 overlay2/d_type/xattr 语义${NC}"
return 1
;;
*)
echo -e "  ${YELLOW}⚠ 未验证的文件系统: ${fs_type}${NC}"
echo -e "  ${YELLOW}  建议使用 ext4 或 xfs(ftype=1)${NC}"
return 1
;;
esac
}
_write_daemon_json() {
local mirrors_json="$1"
local data_root_input="$2"
local ip6t="true"
local data_root="${data_root_input:-$DEFAULT_DOCKER_DATA_ROOT}"
[[ "$IPV6_AVAILABLE" == "false" ]] && ip6t="false"
mkdir -p /etc/docker
_prepare_data_root_dir "$data_root" || { echo -e "  ${RED}无法准备 data-root 目录: ${data_root}${NC}"; return 1; }
local cfg=$(jq -n \
--argjson mirrors "$mirrors_json" \
--argjson ip6t "$ip6t" \
--arg data_root "$data_root" \
'{
"data-root": $data_root,
"iptables": true,
"ip6tables": $ip6t,
"exec-opts": ["native.cgroupdriver=systemd"],
"log-driver": "json-file",
"log-opts": {"max-size": "10m", "max-file": "3"},
"registry-mirrors": $mirrors
}')
echo "$cfg" > /etc/docker/daemon.json
echo -e "  ${GREEN}daemon.json 已写入${NC}"
echo -e "  ${CYAN}data-root: ${data_root}${NC}"
ls -ld "$data_root" 2>/dev/null | sed 's/^/  目录权限: /'
if [[ "$APPARMOR_RESTRICTED" == "true" ]]; then
echo -e "  ${YELLOW}提示: AppArmor 受限，运行容器时可添加 --security-opt apparmor=unconfined${NC}"
fi
}
_set_docker_data_root() {
section "设置 Docker 根目录路径"
local current_root
current_root=$(_get_current_data_root)
echo -e "  当前 data-root: ${CYAN}${current_root}${NC}"
echo -e "  默认 data-root: ${CYAN}${DEFAULT_DOCKER_DATA_ROOT}${NC}"
echo -n "  输入新的根目录路径（回车使用默认 ${DEFAULT_DOCKER_DATA_ROOT}）: "
local input_root
read input_root </dev/tty
local new_root="${input_root:-$DEFAULT_DOCKER_DATA_ROOT}"
if [[ "$new_root" != /* ]]; then
echo -e "  ${RED}路径必须是绝对路径，例如 /data/docker${NC}"
return 1
fi
if ! _prepare_data_root_dir "$new_root"; then
echo -e "  ${RED}无法创建或设置目录: ${new_root}${NC}"
return 1
fi
echo ""
if ! _check_data_root_fs_compat "$new_root"; then
echo ""
echo -e "  ${RED}不建议把 Docker 根目录放到这个挂载盘上${NC}"
echo -e "  ${YELLOW}建议: 把磁盘格式化为 ext4，或使用 xfs(ftype=1)${NC}"
echo -n "  仍然强制写入该路径？(y/n): "
local force_set
read force_set </dev/tty
[[ "$force_set" != "y" ]] && { echo -e "  ${YELLOW}已取消修改${NC}"; return 1; }
fi
backup_daemon_json
local mirrors_json
if [[ -f /etc/docker/daemon.json ]] && jq . /etc/docker/daemon.json >/dev/null 2>&1; then
local tmp
tmp=$(mktemp)
jq --arg dr "$new_root" '. + {"data-root": $dr}' /etc/docker/daemon.json > "$tmp" && mv "$tmp" /etc/docker/daemon.json
else
mirrors_json=$(printf '%s\n' "${REGISTRY_MIRRORS_DEFAULT[@]}" | jq -R . | jq -s .)
_write_daemon_json "$mirrors_json" "$new_root"
fi
echo -e "  ${GREEN}已设置 Docker 根目录为: ${new_root}${NC}"
echo -e "  ${YELLOW}如原目录已有数据，请先停止 Docker 后使用 rsync -aHAX 迁移数据${NC}"
echo -n "  是否立即重启 Docker？(y/n): "
local do_restart
read do_restart </dev/tty
[[ "$do_restart" == "y" ]] && _restart_docker
}
ensure_daemon_json() {
mkdir -p /etc/docker
if [[ -f /etc/docker/daemon.json ]]; then
if ! jq . /etc/docker/daemon.json >/dev/null 2>&1; then
echo -e "  ${YELLOW}daemon.json 格式错误，重新生成${NC}"
rm -f /etc/docker/daemon.json
elif jq -e '."default-security-opt"' /etc/docker/daemon.json >/dev/null 2>&1; then
echo -e "  ${YELLOW}修复无效配置项 default-security-opt${NC}"
local tmp
local current_root
current_root=$(_get_current_data_root)
tmp=$(mktemp)
jq 'del(."default-security-opt")' /etc/docker/daemon.json > "$tmp" && mv "$tmp" /etc/docker/daemon.json
[[ -z "$current_root" ]] && current_root="$DEFAULT_DOCKER_DATA_ROOT"
if ! jq -e '."data-root"' /etc/docker/daemon.json >/dev/null 2>&1; then
local tmp2
tmp2=$(mktemp)
jq --arg dr "$current_root" '. + {"data-root": $dr}' /etc/docker/daemon.json > "$tmp2" && mv "$tmp2" /etc/docker/daemon.json
fi
fi
fi
if [[ ! -s /etc/docker/daemon.json ]]; then
local mirrors_json
local current_root
current_root=$(_get_current_data_root)
mirrors_json=$(printf '%s\n' "${REGISTRY_MIRRORS_DEFAULT[@]}" | jq -R . | jq -s .)
_write_daemon_json "$mirrors_json" "$current_root"
elif ! jq -e '."data-root"' /etc/docker/daemon.json >/dev/null 2>&1; then
local tmp
local current_root
current_root=$(_get_current_data_root)
tmp=$(mktemp)
jq --arg dr "$current_root" '. + {"data-root": $dr}' /etc/docker/daemon.json > "$tmp" && mv "$tmp" /etc/docker/daemon.json
echo -e "  ${GREEN}已补充 data-root: ${current_root}${NC}"
fi
}
_write_docker_service() {
cat > /etc/systemd/system/docker.service <<'EOF'
[Unit]
Description=Docker Application Container Engine
After=network-online.target
Wants=network-online.target
[Service]
Type=notify
ExecStart=/usr/local/bin/dockerd
ExecReload=/bin/kill -s HUP $MAINPID
Restart=always
RestartSec=2
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
Delegate=yes
KillMode=process
[Install]
WantedBy=multi-user.target
EOF
}
_write_docker_socket() {
cat > /etc/systemd/system/docker.socket <<'EOF'
[Unit]
Description=Docker Socket for the API
PartOf=docker.service
[Socket]
ListenStream=/var/run/docker.sock
SocketMode=0660
SocketUser=root
SocketGroup=docker
[Install]
WantedBy=sockets.target
EOF
}
fetch_docker_versions() {
if [[ -n "$DOCKER_VERSIONS_CACHE" ]]; then
echo "$DOCKER_VERSIONS_CACHE"
return
fi
[[ -z "$ARCH" ]] && ARCH=$(get_architecture)
local versions=""
local sources=("$BEST_DOCKER_MIRROR" "${DOCKER_BINARY_MIRRORS[@]}")
for src in "${sources[@]}"; do
[[ -z "$src" ]] && continue
echo -e "  ${CYAN}从 ${src} 获取版本...${NC}" >/dev/tty
local html=$(curl -sS --connect-timeout 10 --max-time 30 "${src}/${ARCH}/" 2>/dev/null)
if [[ -n "$html" ]]; then
versions=$(echo "$html" | grep -oE 'docker-[0-9]+\.[0-9]+\.[0-9]+\.tgz' | sed 's/docker-//g; s/\.tgz//g' | sort -Vr | uniq | head -50)
[[ -n "$versions" ]] && { echo -e "  ${GREEN}成功获取版本列表${NC}" >/dev/tty; break; }
fi
done
if [[ -z "$versions" ]]; then
echo -e "  ${YELLOW}使用内置版本列表${NC}" >/dev/tty
versions="29.7.2
29.7.1
29.6.2
29.6.1
29.5.3
29.5.2
29.4.3
29.3.1
29.2.1
29.1.5
29.0.4
28.5.2
28.4.0
28.3.3
28.2.2
28.1.1
28.0.4
27.5.1
27.4.1
27.3.1
27.2.1
27.1.2
27.0.3
26.1.4
26.0.2
25.0.5
24.0.9"
fi
DOCKER_VERSIONS_CACHE="$versions"
echo "$versions"
}
fetch_compose_versions() {
if [[ -n "$COMPOSE_VERSIONS_CACHE" ]]; then
echo "$COMPOSE_VERSIONS_CACHE"
return
fi
echo -e "  ${CYAN}获取 Compose 版本...${NC}" >/dev/tty
local versions=$(curl -sS --connect-timeout 15 --max-time 30 "$COMPOSE_RELEASES_URL" 2>/dev/null | jq -r '.[].tag_name' 2>/dev/null | grep -E '^v[0-9]' | head -30)
if [[ -n "$versions" ]]; then
echo -e "  ${GREEN}成功获取版本列表${NC}" >/dev/tty
else
echo -e "  ${YELLOW}使用内置版本${NC}" >/dev/tty
versions="v2.32.4
v2.32.1
v2.31.0
v2.30.3
v2.29.7
v2.28.1
v2.27.3
v2.26.1
v2.25.0
v2.24.7"
fi
COMPOSE_VERSIONS_CACHE="$versions"
echo "$versions"
}
select_version() {
local versions_str="$1"
local prompt_name="$2"
if [[ -z "$versions_str" ]]; then
echo ""
return 1
fi
local versions_arr=()
while IFS= read -r line; do
line=$(echo "$line" | tr -d '[:space:]')
[[ -n "$line" ]] && versions_arr+=("$line")
done <<< "$versions_str"
local count=${#versions_arr[@]}
if [[ $count -eq 0 ]]; then
echo ""
return 1
fi
{
echo ""
echo -e "  ${BOLD}可用 ${prompt_name} 版本:${NC}"
echo ""
local show_count=15
(( count < show_count )) && show_count=$count
local i
for ((i=0; i<show_count; i++)); do
if [[ $i -eq 0 ]]; then
echo -e "  ${GREEN}  1) ${versions_arr[$i]}  [最新]${NC}"
else
echo "    $((i+1))) ${versions_arr[$i]}"
fi
done
(( count > show_count )) && echo "    ... 共 ${count} 个版本"
echo ""
} >/dev/tty
local reply
while true; do
echo -n "  请选择 [1-${count}] (回车=最新): " >/dev/tty
read reply </dev/tty
if [[ -z "$reply" ]]; then
echo "${versions_arr[0]}"
return 0
fi
if [[ "$reply" =~ ^[0-9]+$ ]] && (( reply >= 1 && reply <= count )); then
echo "${versions_arr[$((reply-1))]}"
return 0
fi
echo -e "  ${RED}无效输入，请输入 1-${count}${NC}" >/dev/tty
done
}
backup_daemon_json() {
[[ ! -f /etc/docker/daemon.json ]] && return 0
mkdir -p "$DAEMON_BACKUP_DIR"
local bak="${DAEMON_BACKUP_DIR}/daemon.json.$(date +%Y%m%d_%H%M%S)"
cp /etc/docker/daemon.json "$bak" && echo -e "  ${GREEN}已备份: $bak${NC}"
}
restore_daemon_json() {
local backups=$(find "$DAEMON_BACKUP_DIR" -name "daemon.json.*" 2>/dev/null | sort)
[[ -z "$backups" ]] && { echo -e "  ${YELLOW}无备份${NC}"; return; }
echo "$backups" | nl
echo -n "  选择编号: "
read idx </dev/tty
local selected=$(echo "$backups" | sed -n "${idx}p")
[[ -n "$selected" ]] && cp "$selected" /etc/docker/daemon.json && echo -e "  ${GREEN}已恢复${NC}"
}
_start_docker() {
echo -e "  ${CYAN}启动 Docker...${NC}"
systemctl start docker && echo -e "  ${GREEN}已启动${NC}" || journalctl -u docker -n 30 --no-pager
}
_stop_docker() {
systemctl stop docker && echo -e "  ${GREEN}已停止${NC}"
}
_restart_docker() {
echo -e "  ${CYAN}重启 Docker...${NC}"
systemctl restart docker && echo -e "  ${GREEN}已重启${NC}" || journalctl -u docker -n 30 --no-pager
}
manage_docker_service() {
command -v docker >/dev/null 2>&1 || { echo -e "  ${RED}Docker 未安装${NC}"; return; }
while true; do
local status
status=$(systemctl is-active docker 2>/dev/null || true)
[[ -z "$status" ]] && status="inactive"
section "Docker 服务管理"
if [[ "$status" == "active" ]]; then
echo -e "  状态: ${GREEN}运行中${NC}"
elif [[ "$status" == "activating" ]]; then
echo -e "  状态: ${YELLOW}启动中${NC}"
else
echo -e "  状态: ${RED}${status}${NC}"
fi
hr
echo "  1. 启动    2. 停止    3. 重启    0. 返回"
hr
echo -n "  选择: "
read choice </dev/tty
case "$choice" in
1) _start_docker ;;
2) _stop_docker ;;
3) _restart_docker ;;
0) break ;;
esac
done
}
show_docker_status() {
section "Docker 状态"
echo ""
if command -v docker >/dev/null 2>&1; then
echo -e "  Docker: ${GREEN}$(docker --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)${NC}"
else
echo -e "  Docker: ${RED}未安装${NC}"
fi
if command -v docker-compose >/dev/null 2>&1; then
echo -e "  Compose: ${GREEN}$(docker-compose --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)${NC}"
elif docker compose version >/dev/null 2>&1; then
echo -e "  Compose: ${GREEN}$(docker compose version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)${NC}"
else
echo -e "  Compose: ${YELLOW}未安装${NC}"
fi
local svc
svc=$(systemctl is-active docker 2>/dev/null || true)
[[ -z "$svc" ]] && svc="inactive"
if [[ "$svc" == "active" ]]; then
echo -e "  服务: ${GREEN}运行中${NC}"
elif [[ "$svc" == "activating" ]]; then
echo -e "  服务: ${YELLOW}启动中${NC}"
else
echo -e "  服务: ${RED}${svc}${NC}"
fi
if [[ "$svc" == "active" ]]; then
echo ""
echo -e "  容器: $(docker ps -q 2>/dev/null | wc -l) 运行 / $(docker ps -aq 2>/dev/null | wc -l) 总计"
echo -e "  镜像: $(docker images -q 2>/dev/null | wc -l) 个"
fi
}
run_mirror_speed_test() {
section "镜像仓库测速"
echo ""
local direct_ms=$(_probe_url "$DOCKER_DIRECT_ENDPOINT")
(( direct_ms < 5000 )) && echo -e "  ${GREEN}✓${NC} 直连 Docker Hub: ${direct_ms}ms" || echo -e "  ${RED}✗${NC} 直连不可达"
for mirror in "${REGISTRY_MIRRORS_DEFAULT[@]}"; do
local ms=$(_probe_url "${mirror}/v2/")
(( ms < 5000 )) && echo -e "  ${GREEN}✓${NC} ${mirror}: ${ms}ms" || echo -e "  ${RED}✗${NC} ${mirror}"
done
}
install_docker() {
check_docker_installed && {
echo -n "  已安装，重新安装？(y/n): "
read reply </dev/tty
[[ "$reply" != "y" ]] && return
}
section "安装 Docker"
echo ""
echo -e "  ${BOLD}[步骤 1/7]${NC} 检测系统环境"
ensure_docker_prereqs
ARCH=$(get_architecture)
echo ""
echo -e "  ${BOLD}[步骤 2/7]${NC} 准备安装目录"
check_and_set_install_dir
echo ""
echo -e "  ${BOLD}[步骤 3/7]${NC} 下载源测速"
detect_best_docker_mirror
local VERSION
if [[ "$FORCE_LEGACY_DOCKER" == "true" ]]; then
VERSION="$RECOMMENDED_LEGACY_DOCKER_VERSION"
echo -e "\n  ${YELLOW}环境限制，使用兼容版本: ${VERSION}${NC}"
else
echo ""
echo -e "  ${BOLD}[步骤 4/7]${NC} 选择版本"
local versions_str=$(fetch_docker_versions)
VERSION=$(select_version "$versions_str" "Docker")
[[ -z "$VERSION" ]] && { echo -e "  ${RED}未选择版本${NC}"; return 1; }
fi
echo ""
echo -e "  ${BOLD}[步骤 5/7]${NC} 下载 Docker ${VERSION}"
local suffix="/${ARCH}/docker-${VERSION}.tgz"
if ! download_with_fallback "docker" "$suffix" "$DOCKER_INSTALL_DIR/docker.tgz"; then
rm -rf "$DOCKER_INSTALL_DIR"
return 1
fi
echo ""
echo -e "  ${BOLD}[步骤 6/7]${NC} 解压并安装"
echo -n "  解压文件..."
if tar -zxf "$DOCKER_INSTALL_DIR/docker.tgz" -C "$DOCKER_INSTALL_DIR" 2>/dev/null; then
echo -e " ${GREEN}完成${NC}"
else
echo -e " ${RED}失败${NC}"
rm -rf "$DOCKER_INSTALL_DIR"
return 1
fi
echo -n "  安装到 /usr/local/bin..."
mv "$DOCKER_INSTALL_DIR/docker/"* /usr/local/bin/ && echo -e " ${GREEN}完成${NC}" || { echo -e " ${RED}失败${NC}"; return 1; }
groupadd -f docker 2>/dev/null
[[ -n "${SUDO_USER:-}" ]] && gpasswd -a "$SUDO_USER" docker >/dev/null 2>&1
echo -n "  配置 daemon.json..."
ensure_daemon_json
echo -n "  写入 systemd 服务..."
_write_docker_service
_write_docker_socket
echo -e " ${GREEN}完成${NC}"
systemctl daemon-reload
systemctl enable docker >/dev/null 2>&1
echo ""
echo -e "  ${BOLD}[步骤 7/7]${NC} 启动 Docker 服务"
echo -n "  启动中..."
if systemctl start docker 2>/dev/null; then
sleep 1
local ver_str=$(docker --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
echo -e " ${GREEN}成功${NC}"
echo ""
hr
echo -e "  ${GREEN}${BOLD}✓ Docker ${ver_str} 安装完成！${NC}"
echo -e "  ${YELLOW}  提示: 重新登录以使用无 sudo 的 docker 命令${NC}"
hr
else
echo -e " ${RED}失败${NC}"
echo ""
echo -e "  ${RED}Docker 启动失败，错误日志:${NC}"
hr
journalctl -u docker -n 20 --no-pager 2>/dev/null | head -20
hr
echo -e "  ${YELLOW}排查建议:${NC}"
echo -e "  1. 检查 daemon.json: cat /etc/docker/daemon.json"
echo -e "  2. 查看详细日志: journalctl -u docker -n 50"
echo -e "  3. 使用菜单选项 8 重新生成 daemon.json"
fi
rm -rf "$DOCKER_INSTALL_DIR"
}
install_docker_compose() {
check_docker_compose_installed && {
echo -n "  已安装，重新安装？(y/n): "
read reply </dev/tty
[[ "$reply" != "y" ]] && return
}
section "安装 Docker Compose"
rm -f /usr/local/bin/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose 2>/dev/null
echo ""
echo -e "  ${BOLD}[步骤 1/3]${NC} 选择版本"
local versions_str=$(fetch_compose_versions)
local VERSION=$(select_version "$versions_str" "Compose")
[[ -z "$VERSION" ]] && { echo -e "  ${RED}未选择版本${NC}"; return 1; }
echo ""
echo -e "  ${BOLD}[步骤 2/3]${NC} 下载 Docker Compose ${VERSION}"
local arch=$(uname -m)
local file=""
case "$arch" in
x86_64)  file="docker-compose-linux-x86_64" ;;
aarch64) file="docker-compose-linux-aarch64" ;;
armv7l)  file="docker-compose-linux-armv7" ;;
armv6l)  file="docker-compose-linux-armv6" ;;
*)       echo -e "  ${RED}不支持的架构: $arch${NC}"; return 1 ;;
esac
local url="https://github.com/docker/compose/releases/download/${VERSION}/${file}"
local tmp_file="/tmp/docker-compose-$$"
if ! download_with_fallback "github" "$url" "$tmp_file"; then
rm -f "$tmp_file"
return 1
fi
echo ""
echo -e "  ${BOLD}[步骤 3/3]${NC} 安装并验证"
echo -n "  验证文件格式..."
if ! head -c 4 "$tmp_file" 2>/dev/null | grep -q 'ELF'; then
echo -e " ${RED}失败（不是有效的二进制文件）${NC}"
rm -f "$tmp_file"
return 1
fi
echo -e " ${GREEN}有效${NC}"
echo -n "  安装到系统..."
mv "$tmp_file" /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose
mkdir -p /usr/local/lib/docker/cli-plugins
cp /usr/local/bin/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
echo -e " ${GREEN}完成${NC}"
echo -n "  运行验证..."
if docker-compose --version >/dev/null 2>&1; then
local installed_ver=$(docker-compose --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
echo -e " ${GREEN}通过${NC}"
echo ""
hr
echo -e "  ${GREEN}${BOLD}✓ Docker Compose ${installed_ver} 安装完成！${NC}"
hr
else
echo -e " ${RED}失败${NC}"
echo -e "  ${RED}文件已安装但无法执行，可能架构不匹配${NC}"
return 1
fi
}
uninstall_docker() {
echo "  卸载 Docker..."
systemctl stop docker docker.socket 2>/dev/null
systemctl disable docker docker.socket 2>/dev/null
rm -rf /var/lib/docker /etc/docker /usr/local/bin/docker* /usr/local/bin/containerd* /usr/local/bin/runc
rm -f /etc/systemd/system/docker.service /etc/systemd/system/docker.socket
systemctl daemon-reload
echo -e "  ${GREEN}已卸载${NC}"
}
uninstall_docker_compose() {
rm -f /usr/local/bin/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose
echo -e "  ${GREEN}已卸载${NC}"
}
generate_daemon_config() {
section "生成 daemon.json"
backup_daemon_json
local current_root
current_root=$(_get_current_data_root)
echo -e "  当前/默认 Docker 根目录: ${CYAN}${current_root}${NC}"
echo -n "  输入 Docker 根目录路径（回车使用默认 ${DEFAULT_DOCKER_DATA_ROOT}）: "
local input_root
read input_root </dev/tty
local data_root="${input_root:-$DEFAULT_DOCKER_DATA_ROOT}"
if [[ "$data_root" != /* ]]; then
echo -e "  ${RED}路径必须是绝对路径，例如 /data/docker${NC}"
return 1
fi
if ! _prepare_data_root_dir "$data_root"; then
 echo -e "  ${RED}无法创建或设置目录: ${data_root}${NC}"
 return 1
fi
echo ""
if ! _check_data_root_fs_compat "$data_root"; then
 echo -n "  仍然强制写入该路径？(y/n): "
 local force_set
 read force_set </dev/tty
 [[ "$force_set" != "y" ]] && { echo -e "  ${YELLOW}已取消生成${NC}"; return 1; }
fi
local mirrors_json
mirrors_json=$(printf '%s\n' "${REGISTRY_MIRRORS_DEFAULT[@]}" | jq -R . | jq -s .)
_write_daemon_json "$mirrors_json" "$data_root" || return 1
echo -n "  重启 Docker？(y/n): "
read reply </dev/tty
[[ "$reply" == "y" ]] && _restart_docker
}
check_iptables_mode() {
section "系统状态"
echo ""
local backend=$(_detect_iptables_backend)
echo -e "  iptables: ${CYAN}${backend}${NC}"
command -v ipset >/dev/null && ipset list >/dev/null 2>&1 && echo -e "  ipset: ${GREEN}✓${NC}" || echo -e "  ipset: ${RED}✗${NC}"
_check_ipv6_available && echo -e "  IPv6: ${GREEN}✓${NC}" || echo -e "  IPv6: ${YELLOW}✗${NC}"
echo ""
_detect_virt_env
}
manage_daemon_json() {
while true; do
section "daemon.json 管理"
local current_root
current_root=$(_get_current_data_root)
echo -e "  当前 data-root: ${CYAN}${current_root}${NC}"
echo "  1. 备份    2. 恢复    3. 查看    4. 设置 Docker 根目录    0. 返回"
hr
echo -n "  选择: "
read choice </dev/tty
case "$choice" in
1) backup_daemon_json ;;
2) restore_daemon_json ;;
3) [[ -f /etc/docker/daemon.json ]] && cat /etc/docker/daemon.json || echo "  不存在" ;;
4) _set_docker_data_root ;;
0) break ;;
esac
done
}
manage_logs() {
section "日志管理"
echo "  日志: $LOG_FILE"
[[ -f "$LOG_FILE" ]] && echo "  大小: $(du -h "$LOG_FILE" | cut -f1)"
echo ""
echo "  1. 查看最近50行    2. 清空    0. 返回"
hr
echo -n "  选择: "
read choice </dev/tty
case "$choice" in
1) tail -50 "$LOG_FILE" 2>/dev/null ;;
2) : > "$LOG_FILE" && echo -e "  ${GREEN}已清空${NC}" ;;
esac
}
configure_proxy_mirror() {
section "代理镜像源"
echo -e "  当前: ${PROXY_MIRROR_URL:-未配置}"
echo -n "  输入新地址 (留空清除): "
read url </dev/tty
PROXY_MIRROR_URL="${url%/}"
echo -e "  ${GREEN}已设置${NC}"
}
print_menu() {
echo ""
echo -e "${BOLD}${CYAN}  Docker 智能管理脚本 v2.8${NC}"
echo -e "  架构: ${ARCH}  系统: ${OS}  包管理: ${PKG_MANAGER}"
hr
echo -e "  ${GREEN}1.${NC} 安装 Docker          ${GREEN}2.${NC} 安装 Compose"
echo -e "  ${GREEN}3.${NC} 安装两者            ${RED}4.${NC} 卸载 Docker"
echo -e "  ${RED}5.${NC} 卸载 Compose         ${RED}6.${NC} 卸载两者"
echo -e "  ${YELLOW}7.${NC} 查询状态            ${YELLOW}8.${NC} 生成 daemon.json"
echo -e "  ${YELLOW}9.${NC} 系统状态            ${BLUE}10.${NC} 服务管理"
echo -e "  ${BLUE}11.${NC} 状态仪表盘          ${BLUE}12.${NC} daemon.json 管理"
echo -e "  ${BLUE}13.${NC} 日志管理            ${BLUE}14.${NC} 镜像源测速"
echo -e "  ${BLUE}15.${NC} 代理配置            ${RED}0.${NC} 退出"
hr
}
main() {
check_sudo
detect_package_manager
init_log
install_dependencies
ARCH=$(get_architecture)
OS=$(get_os_version)
while true; do
print_menu
echo -n "  请选择 [0-15]: "
read CHOICE </dev/tty
case "$CHOICE" in
1) install_docker ;;
2) install_docker_compose ;;
3) install_docker; install_docker_compose ;;
4) uninstall_docker ;;
5) uninstall_docker_compose ;;
6) uninstall_docker; uninstall_docker_compose ;;
7) check_docker_installed; check_docker_compose_installed ;;
8) generate_daemon_config ;;
9) check_iptables_mode ;;
10) manage_docker_service ;;
11) show_docker_status ;;
12) manage_daemon_json ;;
13) manage_logs ;;
14) run_mirror_speed_test ;;
15) configure_proxy_mirror ;;
0) echo -e "  ${GREEN}再见！${NC}"; break ;;
"") ;;
*) echo -e "  ${RED}无效选择${NC}" ;;
esac
[[ -n "$CHOICE" && "$CHOICE" != "0" ]] && { echo ""; echo -n "  按回车继续..."; read </dev/tty; }
done
}
main
