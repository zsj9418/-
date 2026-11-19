#!/bin/bash
set -o pipefail
REQ_DEPS=("curl" "jq" "tar")
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
DAEMON_JSON="/etc/docker/daemon.json"
DAEMON_BACKUP_DIR="/etc/docker/backups"
CONF_FILE="/etc/docker_manager.conf"
VERSION_CACHE_DIR="/var/tmp/docker_manager_cache"
PROXY_MIRROR_URL="${PROXY_MIRROR_URL:-}"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'
DOCKER_INSTALL_DIR=""
ARCH=""
COMPOSE_ARCH=""
OS=""
PKG_MANAGER=""
FORCE_LEGACY_DOCKER="false"
LEGACY_MAX_MAJOR=27
DOCKER_TARGET_VERSION=""
IPV6_AVAILABLE="true"
IS_LXC="false"
IS_OPENVZ="false"
APPARMOR_RESTRICTED="false"
BEST_DOCKER_MIRROR=""
STRIP_REMOVED=0
SELECTED_VERSION=""
DOCKER_VERSIONS=()
COMPOSE_VERSIONS=()
LOG_DIR="/var/log/docker_manager"
LOG_FILE="${LOG_DIR}/docker_manager.log"
LOG_MAX_SIZE_MB=5
LOG_MAX_BACKUPS=3
DEFAULT_DOCKER_DATA_ROOT="/var/lib/docker"
DOCKER_BINS=(docker dockerd docker-init docker-proxy containerd containerd-shim containerd-shim-runc-v1 containerd-shim-runc-v2 ctr runc)
DATA_SUBDIRS=(overlay2 containers image volumes network buildkit plugins swarm tmp runtimes trust builder fuse-overlayfs)
section() {
echo ""
echo -e "${BOLD}${CYAN}── $1${NC}"
echo -e "${CYAN}$(printf '%.s─' {1..50})${NC}"
}
hr() { echo -e "${CYAN}$(printf '%.s─' {1..50})${NC}"; }
ask_yn() {
local a
echo -n "  $1 (y/n): "
read -r a </dev/tty || return 1
[[ "$a" =~ ^[Yy]$ ]]
}
rotate_log() {
[[ ! -f "$LOG_FILE" ]] && return 0
local size_bytes size_mb i
size_bytes=$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)
size_mb=$(( size_bytes / 1024 / 1024 ))
(( size_mb < LOG_MAX_SIZE_MB )) && return 0
[[ -f "${LOG_FILE}.${LOG_MAX_BACKUPS}.gz" ]] && rm -f "${LOG_FILE}.${LOG_MAX_BACKUPS}.gz"
for (( i = LOG_MAX_BACKUPS - 1; i >= 1; i-- )); do
[[ -f "${LOG_FILE}.${i}.gz" ]] && mv "${LOG_FILE}.${i}.gz" "${LOG_FILE}.$((i+1)).gz"
done
gzip -c "$LOG_FILE" > "${LOG_FILE}.1.gz" 2>/dev/null || true
: > "$LOG_FILE"
}
init_log() {
mkdir -p "$LOG_DIR" "$VERSION_CACHE_DIR" 2>/dev/null || true
rotate_log
echo "" >> "$LOG_FILE" 2>/dev/null || true
echo "  会话开始: $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE" 2>/dev/null || true
exec > >(tee >(sed -u 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE" 2>/dev/null)) 2>&1
}
_cleanup_install_dir() {
[[ -n "$DOCKER_INSTALL_DIR" && -d "$DOCKER_INSTALL_DIR" ]] && rm -rf "$DOCKER_INSTALL_DIR"
DOCKER_INSTALL_DIR=""
}
cleanup() {
echo -e "\n${YELLOW}检测到中断信号，正在清理...${NC}"
_cleanup_install_dir
exit 130
}
trap cleanup INT TERM
load_conf() {
if [[ -z "$PROXY_MIRROR_URL" && -f "$CONF_FILE" ]]; then
. "$CONF_FILE" 2>/dev/null
fi
PROXY_MIRROR_URL="${PROXY_MIRROR_URL%/}"
return 0
}
save_conf() {
printf 'PROXY_MIRROR_URL=%q\n' "$PROXY_MIRROR_URL" > "$CONF_FILE"
}
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
local missing=() opt_missing=() dep
for dep in "${REQ_DEPS[@]}"; do
command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
done
for dep in "${OPT_DEPS[@]}"; do
command -v "$dep" >/dev/null 2>&1 || opt_missing+=("$dep")
done
if [[ ${#missing[@]} -eq 0 ]]; then
echo -e "${GREEN}依赖已就绪。${NC}"
else
echo "安装: ${missing[*]}"
case "$PKG_MANAGER" in
apt-get) apt-get update -qq && apt-get install -y "${missing[@]}" ;;
dnf|yum) "${PKG_MANAGER}" install -y "${missing[@]}" ;;
esac
for dep in "${missing[@]}"; do
command -v "$dep" >/dev/null 2>&1 || { echo -e "${RED}依赖安装失败: ${dep}${NC}"; return 1; }
done
fi
if [[ ${#opt_missing[@]} -gt 0 ]]; then
case "$PKG_MANAGER" in
apt-get) apt-get install -y "${opt_missing[@]}" >/dev/null 2>&1 ;;
dnf|yum) "${PKG_MANAGER}" install -y "${opt_missing[@]}" >/dev/null 2>&1 ;;
esac
fi
return 0
}
get_architecture() {
local m
m=$(uname -m)
case "$m" in
x86_64|amd64) ARCH="x86_64"; COMPOSE_ARCH="x86_64" ;;
aarch64|arm64) ARCH="aarch64"; COMPOSE_ARCH="aarch64" ;;
armv7l|armv7) ARCH="armhf"; COMPOSE_ARCH="armv7" ;;
armv6l) ARCH="armel"; COMPOSE_ARCH="armv6" ;;
*) echo -e "${RED}不支持的架构: $m${NC}" >&2; return 1 ;;
esac
return 0
}
get_os_version() {
if [[ -f /etc/os-release ]]; then
local name ver
name=$(grep ^ID= /etc/os-release | cut -d= -f2 | tr -d '"')
ver=$(grep ^VERSION_ID= /etc/os-release | cut -d= -f2 | tr -d '"')
echo "$name $ver"
else
echo "unknown"
fi
}
check_and_set_install_dir() {
DOCKER_INSTALL_DIR=$(mktemp -d /var/tmp/docker_install.XXXXXX) || { echo -e "${RED}创建目录失败${NC}"; DOCKER_INSTALL_DIR=""; return 1; }
echo -e "${GREEN}安装目录: $DOCKER_INSTALL_DIR${NC}"
}
_probe_url() {
local url="$1" timeout="${2:-6}" out code t
out=$(curl -o /dev/null -s -w '%{http_code} %{time_total}' --connect-timeout "$timeout" --max-time "$timeout" "$url" 2>/dev/null) || { echo 9999; return 0; }
code="${out%% *}"
t="${out##* }"
case "$code" in
200|301|302|401) awk -v t="$t" 'BEGIN{printf "%d\n", t*1000}' ;;
*) echo 9999 ;;
esac
}
detect_best_docker_mirror() {
section "Docker 下载源测速"
echo "  正在探测..."
echo ""
BEST_DOCKER_MIRROR=""
local best_ms=999999 mirror out http_code ms
for mirror in "${DOCKER_BINARY_MIRRORS[@]}"; do
out=$(curl -o /dev/null -s --connect-timeout 6 --max-time 10 -w '%{http_code} %{time_total}' "${mirror}/${ARCH}/" 2>/dev/null) || out="000 0"
http_code="${out%% *}"
ms=$(awk -v t="${out##* }" 'BEGIN{printf "%d", t*1000}')
if [[ "$http_code" == "200" ]]; then
printf "  ${GREEN}✓${NC}  %-55s %s ms\n" "$mirror" "$ms"
if (( ms < best_ms )); then best_ms=$ms; BEST_DOCKER_MIRROR="$mirror"; fi
else
printf "  ${RED}✗${NC}  %-55s 不可达\n" "$mirror"
fi
done
echo ""
if [[ -z "$BEST_DOCKER_MIRROR" ]]; then
echo -e "  ${YELLOW}警告：使用官方源${NC}"
BEST_DOCKER_MIRROR="https://download.docker.com/linux/static/stable"
else
echo -e "  ${GREEN}最快: ${BEST_DOCKER_MIRROR} (${best_ms} ms)${NC}"
fi
}
_do_curl_download() {
local url="$1" dest="$2" rc filesize
echo -e "  ${CYAN}↓${NC} ${url}"
curl -fL --retry 2 --connect-timeout 15 --max-time 900 --progress-bar -o "$dest" "$url" 2>&1
rc=$?
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
if head -c 20 "$dest" 2>/dev/null | grep -aqi '<!doctype\|<html'; then
echo -e "  ${RED}✗ 收到网页而非文件（代理可能不可用）${NC}"
rm -f "$dest"
return 1
fi
filesize=$(du -h "$dest" 2>/dev/null | cut -f1)
echo -e "  ${GREEN}✓ 下载完成 (${filesize})${NC}"
return 0
}
download_with_fallback() {
local type="$1" url="$2" dest="$3"
rm -f "$dest" 2>/dev/null
local tried=0 total=0 mirror m prefix i suffix
case "$type" in
docker)
suffix="$url"
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
if tar -tzf "$dest" >/dev/null 2>&1; then
return 0
fi
echo -e "  ${RED}✗ 压缩包校验失败${NC}"
rm -f "$dest"
fi
echo -e "  ${YELLOW}  → 切换下一个源...${NC}"
done
echo ""
echo -e "  ${RED}✗ 全部 ${total} 个源均失败（该版本可能不存在）${NC}"
return 1
;;
github)
local -a urls=("$url")
local -a labels=("GitHub 直连")
for prefix in "${GITHUB_PROXY_PREFIXES[@]}"; do
urls+=("${prefix}${url}")
labels+=("代理 ${prefix}")
done
total=${#urls[@]}
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
local ver
if [[ -x /usr/local/bin/docker-compose ]]; then
if head -c 4 /usr/local/bin/docker-compose 2>/dev/null | grep -aq 'ELF\|#!'; then
ver=$(docker-compose --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
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
ver=$(docker compose version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
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
local ver real
ver=$(iptables -V 2>/dev/null || true)
echo "$ver" | grep -qi 'nf_tables\|nft' && { echo "nft"; return; }
echo "$ver" | grep -qi 'legacy' && { echo "legacy"; return; }
real=$(readlink -f "$(command -v iptables)" 2>/dev/null || true)
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
local compat_issues=() mod backend iptables_ok ipset_ok need_downgrade issue
echo -e "\n[1/5] 虚拟化环境"
_detect_virt_env
[[ "$IS_OPENVZ" == "true" ]] && { FORCE_LEGACY_DOCKER="true"; compat_issues+=("OpenVZ"); }
echo -e "\n[2/5] 内核模块"
for mod in overlay br_netfilter; do
_check_module "$mod" && echo -e "  ${GREEN}✓${NC} $mod" || echo -e "  ${YELLOW}⚠${NC} $mod"
done
echo -e "\n[3/5] iptables"
backend=$(_detect_iptables_backend)
echo -e "  后端: ${CYAN}${backend}${NC}"
[[ "$backend" == "none" ]] && echo -e "  ${YELLOW}⚠ 未检测到 iptables，Docker 网络可能无法工作${NC}"
iptables_ok="true"
if [[ "$backend" == "legacy" ]]; then
iptables -t raw -L >/dev/null 2>&1 && echo -e "  ${GREEN}✓${NC} raw表" || { echo -e "  ${RED}✗${NC} raw表"; iptables_ok="false"; compat_issues+=("raw表不可用"); }
fi
echo -e "\n[4/5] ipset"
ipset_ok="false"
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
need_downgrade="false"
[[ "$ipset_ok" == "false" ]] && need_downgrade="true"
[[ "$backend" == "legacy" && "$iptables_ok" == "false" ]] && need_downgrade="true"
[[ "$FORCE_LEGACY_DOCKER" == "true" ]] && need_downgrade="true"
echo ""
if [[ "$need_downgrade" == "true" ]]; then
FORCE_LEGACY_DOCKER="true"
echo -e "  ${YELLOW}将限制为兼容版本（主版本 ≤ ${LEGACY_MAX_MAJOR}，从网络列表中选择）${NC}"
for issue in "${compat_issues[@]}"; do
echo -e "  ${YELLOW}•${NC} $issue"
done
else
echo -e "  ${GREEN}✓ 满足最新版 Docker 要求${NC}"
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
if [[ -f "$DAEMON_JSON" ]] && jq . "$DAEMON_JSON" >/dev/null 2>&1; then
current=$(jq -r '."data-root" // empty' "$DAEMON_JSON" 2>/dev/null)
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
local data_root="$1" fs_type mount_point
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
_target_docker_major() {
local v="${DOCKER_TARGET_VERSION:-}"
if [[ -z "$v" ]] && command -v dockerd >/dev/null 2>&1; then
v=$(dockerd --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
fi
v="${v#v}"
v="${v%%.*}"
[[ "$v" =~ ^[0-9]+$ ]] || v=0
echo "$v"
}
backup_daemon_json() {
[[ ! -f "$DAEMON_JSON" ]] && return 0
mkdir -p "$DAEMON_BACKUP_DIR"
local bak="${DAEMON_BACKUP_DIR}/daemon.json.$(date +%Y%m%d_%H%M%S)"
cp -p "$DAEMON_JSON" "$bak" && echo -e "  ${GREEN}已备份: $bak${NC}"
}
_commit_json() {
local tmp="$1"
if ! jq -e . "$tmp" >/dev/null 2>&1; then
rm -f "$tmp"
echo -e "  ${RED}生成的 JSON 不合法，已放弃写入${NC}"
return 1
fi
backup_daemon_json
mkdir -p /etc/docker
mv -f "$tmp" "$DAEMON_JSON"
chmod 644 "$DAEMON_JSON"
return 0
}
_build_mirrors_json() {
if [[ -n "$PROXY_MIRROR_URL" ]]; then
jq -cn --arg u "$PROXY_MIRROR_URL" '[$u]'
else
echo '[]'
fi
}
_write_daemon_json() {
local data_root="${1:-$DEFAULT_DOCKER_DATA_ROOT}" base mirrors major ip6t tmp
mkdir -p /etc/docker
_prepare_data_root_dir "$data_root" || { echo -e "  ${RED}无法准备 data-root 目录: ${data_root}${NC}"; return 1; }
if [[ -s "$DAEMON_JSON" ]] && jq -e . "$DAEMON_JSON" >/dev/null 2>&1; then
base=$(cat "$DAEMON_JSON")
else
base='{}'
fi
_check_ipv6_available && IPV6_AVAILABLE="true" || IPV6_AVAILABLE="false"
major=$(_target_docker_major)
ip6t="keep"
if (( major > 0 && major < 27 )) || [[ "$IPV6_AVAILABLE" == "false" ]]; then
ip6t="false"
elif (( major >= 27 )); then
ip6t="true"
fi
mirrors=$(_build_mirrors_json)
tmp=$(mktemp)
printf '%s' "$base" | jq --argjson m "$mirrors" --arg dr "$data_root" --arg ip6 "$ip6t" '
del(."default-security-opt")
| ."data-root"=$dr
| (if ($m|length)>0 then ."registry-mirrors"=$m else . end)
| (if has("iptables") then . else ."iptables"=true end)
| (if $ip6=="false" then ."ip6tables"=false elif ($ip6=="true" and (has("ip6tables")|not)) then ."ip6tables"=true else . end)
| (if has("exec-opts") then . else ."exec-opts"=["native.cgroupdriver=systemd"] end)
| (if has("log-driver") then . else ."log-driver"="json-file" end)
| (if has("log-opts") then . else ."log-opts"={"max-size":"10m","max-file":"3"} end)' > "$tmp" 2>/dev/null
_commit_json "$tmp" || return 1
echo -e "  ${GREEN}daemon.json 已写入${NC}"
echo -e "  ${CYAN}data-root: ${data_root}${NC}"
echo -e "  ${CYAN}registry-mirrors: $(jq -c '."registry-mirrors" // "未配置"' "$DAEMON_JSON" 2>/dev/null)${NC}"
ls -ld "$data_root" 2>/dev/null | sed 's/^/  目录权限: /'
if [[ "$APPARMOR_RESTRICTED" == "true" ]]; then
echo -e "  ${YELLOW}提示: AppArmor 受限，运行容器时可添加 --security-opt apparmor=unconfined${NC}"
fi
return 0
}
_strip_default_mirrors() {
STRIP_REMOVED=0
[[ -s "$DAEMON_JSON" ]] || return 0
if ! jq -e . "$DAEMON_JSON" >/dev/null 2>&1; then
echo -e "  ${YELLOW}daemon.json 不是合法 JSON，跳过默认镜像清理${NC}"
return 1
fi
local defs removed tmp m
defs=$(for m in "${REGISTRY_MIRRORS_DEFAULT[@]}"; do
if [[ -z "$PROXY_MIRROR_URL" || "${m%/}" != "${PROXY_MIRROR_URL%/}" ]]; then printf '%s\n' "${m%/}"; fi
done | jq -R . | jq -sc .)
removed=$(jq --argjson d "$defs" 'if (."registry-mirrors"|type)=="array" then [."registry-mirrors"[] | select((rtrimstr("/")) as $y | ($d|index($y)) != null)] | length else 0 end' "$DAEMON_JSON" 2>/dev/null)
[[ "${removed:-0}" -gt 0 ]] || return 0
tmp=$(mktemp)
jq --argjson d "$defs" 'if (."registry-mirrors"|type)=="array" then (."registry-mirrors" |= map(select((rtrimstr("/")) as $y | ($d|index($y)) == null))) | (if (."registry-mirrors"|length)==0 then del(."registry-mirrors") else . end) else . end' "$DAEMON_JSON" > "$tmp" 2>/dev/null
_commit_json "$tmp" || return 1
STRIP_REMOVED="$removed"
echo -e "  ${GREEN}已从 daemon.json 清除 ${removed} 个默认镜像源（备份位于 ${DAEMON_BACKUP_DIR}）${NC}"
return 0
}
_set_registry_mirror() {
local url="$1" tmp
mkdir -p /etc/docker
[[ -s "$DAEMON_JSON" ]] || echo '{}' > "$DAEMON_JSON"
if ! jq -e . "$DAEMON_JSON" >/dev/null 2>&1; then
echo -e "  ${RED}daemon.json 不是合法 JSON，请先在菜单 12 中恢复或用菜单 8 重新生成${NC}"
return 1
fi
tmp=$(mktemp)
if [[ -n "$url" ]]; then
jq --arg u "$url" '."registry-mirrors"=[$u]' "$DAEMON_JSON" > "$tmp" 2>/dev/null
else
jq 'del(."registry-mirrors")' "$DAEMON_JSON" > "$tmp" 2>/dev/null
fi
_commit_json "$tmp"
}
ensure_daemon_json() {
mkdir -p /etc/docker
local root
if [[ -s "$DAEMON_JSON" ]] && ! jq -e . "$DAEMON_JSON" >/dev/null 2>&1; then
echo -e "  ${YELLOW}daemon.json 格式错误，已备份并重新生成${NC}"
fi
_strip_default_mirrors
root=$(_get_current_data_root)
_write_daemon_json "$root"
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
_install_docker_binaries() {
local src="$1" f name
mkdir -p /usr/local/bin
for f in "$src"/*; do
[[ -f "$f" ]] || continue
name=$(basename "$f")
cp -f "$f" "/usr/local/bin/.${name}.new" || return 1
chmod 755 "/usr/local/bin/.${name}.new"
mv -f "/usr/local/bin/.${name}.new" "/usr/local/bin/${name}" || return 1
done
return 0
}
fetch_docker_versions() {
(( ${#DOCKER_VERSIONS[@]} > 0 )) && return 0
[[ -z "$ARCH" ]] && { get_architecture || return 1; }
local cache="${VERSION_CACHE_DIR}/docker-${ARCH}.list" src html list
local -a sources=()
mkdir -p "$VERSION_CACHE_DIR"
[[ -n "$BEST_DOCKER_MIRROR" ]] && sources+=("$BEST_DOCKER_MIRROR")
for src in "${DOCKER_BINARY_MIRRORS[@]}"; do
[[ "$src" != "$BEST_DOCKER_MIRROR" ]] && sources+=("$src")
done
for src in "${sources[@]}"; do
echo -e "  ${CYAN}从 ${src} 获取版本...${NC}"
html=$(curl -fsS --connect-timeout 10 --max-time 30 "${src}/${ARCH}/" 2>/dev/null) || continue
list=$(printf '%s\n' "$html" | grep -oE 'docker-[0-9]+\.[0-9]+\.[0-9]+\.tgz' | sed 's/^docker-//; s/\.tgz$//' | sort -Vr | uniq | head -50)
if [[ -n "$list" ]]; then
printf '%s\n' "$list" > "$cache"
mapfile -t DOCKER_VERSIONS <<< "$list"
echo -e "  ${GREEN}成功获取版本列表（共 ${#DOCKER_VERSIONS[@]} 个）${NC}"
return 0
fi
done
if [[ -s "$cache" ]]; then
echo -e "  ${YELLOW}网络获取失败，使用上次缓存的版本列表${NC}"
mapfile -t DOCKER_VERSIONS < "$cache"
return 0
fi
echo -e "  ${RED}无法获取 Docker 版本列表${NC}"
return 1
}
fetch_compose_versions() {
(( ${#COMPOSE_VERSIONS[@]} > 0 )) && return 0
local cache="${VERSION_CACHE_DIR}/compose.list" json list url prefix tag
local -a apis=("${COMPOSE_RELEASES_URL}?per_page=30")
mkdir -p "$VERSION_CACHE_DIR"
for prefix in "${GITHUB_PROXY_PREFIXES[@]}"; do
apis+=("${prefix}${COMPOSE_RELEASES_URL}?per_page=30")
done
for url in "${apis[@]}"; do
echo -e "  ${CYAN}获取 Compose 版本: ${url}${NC}"
json=$(curl -fsS --connect-timeout 10 --max-time 20 "$url" 2>/dev/null) || continue
list=$(printf '%s' "$json" | jq -r 'if type=="array" then .[] | select((.prerelease|not) and (.draft|not)) | .tag_name else empty end' 2>/dev/null | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -Vr | uniq | head -30)
if [[ -n "$list" ]]; then
printf '%s\n' "$list" > "$cache"
mapfile -t COMPOSE_VERSIONS <<< "$list"
echo -e "  ${GREEN}成功获取版本列表（共 ${#COMPOSE_VERSIONS[@]} 个）${NC}"
return 0
fi
done
for prefix in "" "${GITHUB_PROXY_PREFIXES[@]}"; do
tag=$(curl -fsSIL --connect-timeout 10 --max-time 20 -o /dev/null -w '%{url_effective}' "${prefix}https://github.com/docker/compose/releases/latest" 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+$')
if [[ -n "$tag" ]]; then
printf '%s\n' "$tag" > "$cache"
COMPOSE_VERSIONS=("$tag")
echo -e "  ${YELLOW}仅获取到最新版本: ${tag}${NC}"
return 0
fi
done
if [[ -s "$cache" ]]; then
echo -e "  ${YELLOW}网络获取失败，使用上次缓存的版本列表${NC}"
mapfile -t COMPOSE_VERSIONS < "$cache"
return 0
fi
echo -e "  ${RED}无法获取 Compose 版本列表${NC}"
return 1
}
select_version() {
local name="$1"; shift
local -a arr=("$@")
local count=${#arr[@]} show=15 i reply
SELECTED_VERSION=""
(( count == 0 )) && return 1
(( count < show )) && show=$count
echo ""
echo -e "  ${BOLD}可用 ${name} 版本:${NC}"
echo ""
for ((i=0; i<show; i++)); do
if (( i == 0 )); then
echo -e "  ${GREEN}  1) ${arr[$i]}  [最新]${NC}"
else
echo "    $((i+1))) ${arr[$i]}"
fi
done
(( count > show )) && echo "    ... 共 ${count} 个版本（可输入序号 1-${count}）"
echo ""
while true; do
echo -n "  请选择序号或直接输入版本号 (回车=最新): "
read -r reply </dev/tty || return 1
if [[ -z "$reply" ]]; then
SELECTED_VERSION="${arr[0]}"
return 0
fi
if [[ "$reply" =~ ^[0-9]+$ ]] && (( reply >= 1 && reply <= count )); then
SELECTED_VERSION="${arr[$((reply-1))]}"
return 0
fi
if [[ "$reply" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
SELECTED_VERSION="$reply"
return 0
fi
echo -e "  ${RED}无效输入${NC}"
done
}
prompt_manual_version() {
local v
SELECTED_VERSION=""
echo -n "  ${1} 版本列表获取失败，请手动输入版本号（如 x.y.z，留空取消）: "
read -r v </dev/tty || return 1
[[ "$v" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
SELECTED_VERSION="$v"
return 0
}
restore_daemon_json() {
local -a backups=()
local idx i
mapfile -t backups < <(find "$DAEMON_BACKUP_DIR" -name "daemon.json.*" 2>/dev/null | sort)
(( ${#backups[@]} == 0 )) && { echo -e "  ${YELLOW}无备份${NC}"; return 0; }
for i in "${!backups[@]}"; do
echo "  $((i+1))) ${backups[$i]}"
done
echo -n "  选择编号: "
read -r idx </dev/tty || return 0
if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#backups[@]} )); then
backup_daemon_json
cp "${backups[$((idx-1))]}" "$DAEMON_JSON" && echo -e "  ${GREEN}已恢复${NC}"
echo -e "  ${YELLOW}如恢复的配置含默认镜像源，可用菜单 16 清理${NC}"
ask_restart
else
echo -e "  ${RED}无效编号${NC}"
fi
}
_start_docker() {
echo -e "  ${CYAN}启动 Docker...${NC}"
systemctl daemon-reload
systemctl start docker && echo -e "  ${GREEN}已启动${NC}" || journalctl -u docker -n 30 --no-pager
}
_stop_docker() {
systemctl stop docker docker.socket && echo -e "  ${GREEN}已停止${NC}"
}
_restart_docker() {
echo -e "  ${CYAN}重启 Docker...${NC}"
systemctl daemon-reload
systemctl restart docker && echo -e "  ${GREEN}已重启${NC}" || journalctl -u docker -n 30 --no-pager
}
ask_restart() {
if command -v dockerd >/dev/null 2>&1 && ask_yn "配置已变更，是否立即重启 Docker 使其生效？"; then
_restart_docker
fi
}
_set_docker_data_root() {
section "设置 Docker 根目录路径"
local current_root input_root new_root force_set was_running=0
current_root=$(_get_current_data_root)
echo -e "  当前 data-root: ${CYAN}${current_root}${NC}"
echo -e "  默认 data-root: ${CYAN}${DEFAULT_DOCKER_DATA_ROOT}${NC}"
echo -n "  输入新的根目录路径（回车使用默认 ${DEFAULT_DOCKER_DATA_ROOT}）: "
read -r input_root </dev/tty || return 1
new_root="${input_root:-$DEFAULT_DOCKER_DATA_ROOT}"
new_root="${new_root%/}"
if [[ "$new_root" != /* || -z "$new_root" ]]; then
echo -e "  ${RED}路径必须是绝对路径，例如 /data/docker，且不能是 /${NC}"
return 1
fi
if [[ "$new_root" == "$current_root" ]]; then
echo -e "  ${YELLOW}与当前 data-root 相同，无需修改${NC}"
return 0
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
ask_yn "仍然强制写入该路径？" || { echo -e "  ${YELLOW}已取消修改${NC}"; return 1; }
fi
systemctl is-active --quiet docker 2>/dev/null && was_running=1
if [[ -d "$current_root" && -n "$(ls -A "$current_root" 2>/dev/null)" && -z "$(ls -A "$new_root" 2>/dev/null)" ]]; then
if ask_yn "是否把 ${current_root} 的现有数据迁移到 ${new_root}？"; then
[[ "$was_running" -eq 1 ]] && _stop_docker
echo -e "  ${CYAN}正在迁移数据，请耐心等待...${NC}"
if command -v rsync >/dev/null 2>&1; then
rsync -aHAX "${current_root}/" "${new_root}/" || { echo -e "  ${RED}迁移失败，配置未修改${NC}"; return 1; }
else
cp -a "${current_root}/." "${new_root}/" || { echo -e "  ${RED}迁移失败，配置未修改${NC}"; return 1; }
fi
echo -e "  ${GREEN}数据迁移完成（原目录保留，确认无误后可手动删除）${NC}"
else
echo -e "  ${YELLOW}未迁移数据，Docker 将以空目录启动${NC}"
fi
fi
_strip_default_mirrors
_write_daemon_json "$new_root" || return 1
echo -e "  ${GREEN}已设置 Docker 根目录为: ${new_root}${NC}"
if ask_yn "是否立即重启 Docker？"; then
_restart_docker
else
[[ "$was_running" -eq 1 ]] && echo -e "  ${YELLOW}Docker 当前可能处于停止状态，请稍后手动启动${NC}"
fi
}
manage_docker_service() {
command -v docker >/dev/null 2>&1 || { echo -e "  ${RED}Docker 未安装${NC}"; return; }
local status choice
while true; do
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
read -r choice </dev/tty || break
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
local svc
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
svc=$(systemctl is-active docker 2>/dev/null || true)
[[ -z "$svc" ]] && svc="inactive"
if [[ "$svc" == "active" ]]; then
echo -e "  服务: ${GREEN}运行中${NC}"
elif [[ "$svc" == "activating" ]]; then
echo -e "  服务: ${YELLOW}启动中${NC}"
else
echo -e "  服务: ${RED}${svc}${NC}"
fi
echo -e "  data-root: ${CYAN}$(_get_current_data_root)${NC}"
if [[ -s "$DAEMON_JSON" ]]; then
echo -e "  registry-mirrors: ${CYAN}$(jq -c '."registry-mirrors" // "未配置"' "$DAEMON_JSON" 2>/dev/null)${NC}"
else
echo -e "  registry-mirrors: ${CYAN}未配置${NC}"
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
local direct_ms ms mirror best="" best_ms=9999
direct_ms=$(_probe_url "$DOCKER_DIRECT_ENDPOINT")
(( direct_ms < 5000 )) && echo -e "  ${GREEN}✓${NC} 直连 Docker Hub: ${direct_ms}ms" || echo -e "  ${RED}✗${NC} 直连不可达"
for mirror in "${REGISTRY_MIRRORS_DEFAULT[@]}"; do
ms=$(_probe_url "${mirror}/v2/")
if (( ms < 5000 )); then
echo -e "  ${GREEN}✓${NC} ${mirror}: ${ms}ms"
if (( ms < best_ms )); then best_ms=$ms; best="$mirror"; fi
else
echo -e "  ${RED}✗${NC} ${mirror}"
fi
done
echo ""
echo -e "  ${YELLOW}测速仅供参考，不会自动写入任何配置${NC}"
if [[ -n "$best" ]] && ask_yn "是否将最快的 ${best} 设为镜像加速地址？"; then
PROXY_MIRROR_URL="$best"
save_conf
_set_registry_mirror "$PROXY_MIRROR_URL" && ask_restart
fi
}
install_docker() {
if check_docker_installed; then
ask_yn "已安装，重新安装？" || return 0
fi
section "安装 Docker"
local VERSION="" v
local -a LIST=()
echo ""
echo -e "  ${BOLD}[步骤 1/7]${NC} 检测系统环境"
ensure_docker_prereqs
get_architecture || return 1
echo ""
echo -e "  ${BOLD}[步骤 2/7]${NC} 准备安装目录"
check_and_set_install_dir || return 1
echo ""
echo -e "  ${BOLD}[步骤 3/7]${NC} 下载源测速"
detect_best_docker_mirror
echo ""
echo -e "  ${BOLD}[步骤 4/7]${NC} 选择版本"
fetch_docker_versions
if [[ "$FORCE_LEGACY_DOCKER" == "true" ]]; then
echo -e "  ${YELLOW}环境限制，仅列出主版本 ≤ ${LEGACY_MAX_MAJOR} 的兼容版本${NC}"
for v in "${DOCKER_VERSIONS[@]}"; do
(( ${v%%.*} <= LEGACY_MAX_MAJOR )) && LIST+=("$v")
done
else
LIST=("${DOCKER_VERSIONS[@]}")
fi
if (( ${#LIST[@]} > 0 )); then
select_version "Docker" "${LIST[@]}" || { echo -e "  ${RED}未选择版本${NC}"; _cleanup_install_dir; return 1; }
else
prompt_manual_version "Docker" || { echo -e "  ${RED}版本号无效或已取消${NC}"; _cleanup_install_dir; return 1; }
fi
VERSION="${SELECTED_VERSION#v}"
DOCKER_TARGET_VERSION="$VERSION"
echo ""
echo -e "  ${BOLD}[步骤 5/7]${NC} 下载 Docker ${VERSION}"
if ! download_with_fallback "docker" "/${ARCH}/docker-${VERSION}.tgz" "$DOCKER_INSTALL_DIR/docker.tgz"; then
_cleanup_install_dir
return 1
fi
echo ""
echo -e "  ${BOLD}[步骤 6/7]${NC} 解压并安装"
echo -n "  解压文件..."
if tar -zxf "$DOCKER_INSTALL_DIR/docker.tgz" -C "$DOCKER_INSTALL_DIR" 2>/dev/null; then
echo -e " ${GREEN}完成${NC}"
else
echo -e " ${RED}失败${NC}"
_cleanup_install_dir
return 1
fi
echo -n "  安装到 /usr/local/bin..."
if _install_docker_binaries "$DOCKER_INSTALL_DIR/docker"; then
echo -e " ${GREEN}完成${NC}"
else
echo -e " ${RED}失败${NC}"
_cleanup_install_dir
return 1
fi
groupadd -f docker 2>/dev/null
[[ -n "${SUDO_USER:-}" ]] && gpasswd -a "$SUDO_USER" docker >/dev/null 2>&1
echo "  配置 daemon.json..."
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
if systemctl restart docker 2>/dev/null; then
sleep 1
local ver_str
ver_str=$(docker --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
echo -e " ${GREEN}成功${NC}"
echo ""
hr
echo -e "  ${GREEN}${BOLD}✓ Docker ${ver_str} 安装完成！${NC}"
echo -e "  ${YELLOW}  提示: 重新登录以使用无 sudo 的 docker 命令${NC}"
echo -e "  ${YELLOW}  提示: 未写入任何镜像加速源，如需加速请使用菜单 15${NC}"
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
_cleanup_install_dir
}
install_docker_compose() {
if check_docker_compose_installed; then
ask_yn "已安装，重新安装？" || return 0
fi
section "安装 Docker Compose"
local VERSION file url tmp_file plugin_dir="/usr/local/lib/docker/cli-plugins" installed_ver
get_architecture || return 1
echo ""
echo -e "  ${BOLD}[步骤 1/3]${NC} 选择版本"
fetch_compose_versions
if (( ${#COMPOSE_VERSIONS[@]} > 0 )); then
select_version "Compose" "${COMPOSE_VERSIONS[@]}" || { echo -e "  ${RED}未选择版本${NC}"; return 1; }
else
prompt_manual_version "Compose" || { echo -e "  ${RED}版本号无效或已取消${NC}"; return 1; }
fi
VERSION="$SELECTED_VERSION"
[[ "$VERSION" == v* ]] || VERSION="v${VERSION}"
echo ""
echo -e "  ${BOLD}[步骤 2/3]${NC} 下载 Docker Compose ${VERSION}"
file="docker-compose-linux-${COMPOSE_ARCH}"
url="https://github.com/docker/compose/releases/download/${VERSION}/${file}"
mkdir -p /usr/local/bin "$plugin_dir"
tmp_file="/usr/local/bin/.docker-compose.dl.$$"
if ! download_with_fallback "github" "$url" "$tmp_file"; then
rm -f "$tmp_file"
echo -e "  ${YELLOW}原有 Compose（如有）未被改动${NC}"
return 1
fi
echo ""
echo -e "  ${BOLD}[步骤 3/3]${NC} 安装并验证"
echo -n "  验证文件格式..."
if ! head -c 4 "$tmp_file" 2>/dev/null | grep -aq 'ELF'; then
echo -e " ${RED}失败（不是有效的二进制文件）${NC}"
rm -f "$tmp_file"
return 1
fi
echo -e " ${GREEN}有效${NC}"
chmod 755 "$tmp_file"
echo -n "  运行验证..."
if ! "$tmp_file" --version >/dev/null 2>&1; then
echo -e " ${RED}失败${NC}"
echo -e "  ${RED}文件无法执行，可能架构不匹配；原有 Compose 未被改动${NC}"
rm -f "$tmp_file"
return 1
fi
echo -e " ${GREEN}通过${NC}"
echo -n "  安装到系统..."
cp -f "$tmp_file" "${plugin_dir}/.docker-compose.new" && chmod 755 "${plugin_dir}/.docker-compose.new" && mv -f "${plugin_dir}/.docker-compose.new" "${plugin_dir}/docker-compose"
mv -f "$tmp_file" /usr/local/bin/docker-compose
echo -e " ${GREEN}完成${NC}"
installed_ver=$(docker-compose --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
echo ""
hr
echo -e "  ${GREEN}${BOLD}✓ Docker Compose ${installed_ver} 安装完成！${NC}"
hr
}
uninstall_docker() {
local dr b s
ask_yn "确认卸载 Docker？" || { echo -e "  ${YELLOW}已取消${NC}"; return 0; }
echo "  卸载 Docker..."
dr=$(_get_current_data_root)
systemctl stop docker docker.socket 2>/dev/null
systemctl disable docker docker.socket 2>/dev/null
for b in "${DOCKER_BINS[@]}"; do
rm -f "/usr/local/bin/${b}"
done
rm -f /etc/systemd/system/docker.service /etc/systemd/system/docker.socket /var/run/docker.sock
systemctl daemon-reload
if [[ -n "$dr" && "$dr" != "/" ]] && ask_yn "是否同时删除 Docker 数据（镜像/容器/卷）？目录: ${dr}"; then
awk -v p="${dr}/" 'index($2,p)==1 {print $2}' /proc/mounts | sort -r | xargs -r umount 2>/dev/null
for s in "${DATA_SUBDIRS[@]}"; do
rm -rf "${dr:?}/${s}"
done
rmdir "$dr" 2>/dev/null
echo -e "  ${GREEN}已删除 Docker 数据子目录${NC}"
else
echo -e "  ${YELLOW}已保留数据目录 ${dr}${NC}"
fi
if ask_yn "是否删除配置目录 /etc/docker（含 daemon.json 备份）？"; then
rm -rf /etc/docker
echo -e "  ${GREEN}已删除 /etc/docker${NC}"
fi
echo -e "  ${GREEN}已卸载${NC}"
}
uninstall_docker_compose() {
ask_yn "确认卸载 Docker Compose？" || { echo -e "  ${YELLOW}已取消${NC}"; return 0; }
rm -f /usr/local/bin/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose
echo -e "  ${GREEN}已卸载${NC}"
}
generate_daemon_config() {
section "生成 daemon.json"
local current_root input_root data_root
current_root=$(_get_current_data_root)
echo -e "  当前/默认 Docker 根目录: ${CYAN}${current_root}${NC}"
echo -e "  ${YELLOW}将保留现有设置，仅补全缺失项，且不会写入默认镜像源${NC}"
echo -n "  输入 Docker 根目录路径（回车使用当前 ${current_root}）: "
read -r input_root </dev/tty || return 1
data_root="${input_root:-$current_root}"
data_root="${data_root%/}"
if [[ "$data_root" != /* || -z "$data_root" ]]; then
echo -e "  ${RED}路径必须是绝对路径，例如 /data/docker${NC}"
return 1
fi
if ! _prepare_data_root_dir "$data_root"; then
echo -e "  ${RED}无法创建或设置目录: ${data_root}${NC}"
return 1
fi
echo ""
if ! _check_data_root_fs_compat "$data_root"; then
ask_yn "仍然强制写入该路径？" || { echo -e "  ${YELLOW}已取消生成${NC}"; return 1; }
fi
_strip_default_mirrors
_write_daemon_json "$data_root" || return 1
ask_yn "重启 Docker？" && _restart_docker
return 0
}
clean_default_mirrors() {
section "清理 daemon.json 中的默认镜像源"
if [[ ! -s "$DAEMON_JSON" ]]; then
echo -e "  ${YELLOW}daemon.json 不存在或为空${NC}"
return 0
fi
_strip_default_mirrors
if [[ "$STRIP_REMOVED" -gt 0 ]]; then
echo -e "  ${CYAN}当前 registry-mirrors: $(jq -c '."registry-mirrors" // "未配置"' "$DAEMON_JSON" 2>/dev/null)${NC}"
ask_restart
else
echo -e "  ${GREEN}未发现需要清理的默认镜像源${NC}"
fi
}
check_iptables_mode() {
section "系统状态"
echo ""
local backend
backend=$(_detect_iptables_backend)
echo -e "  iptables: ${CYAN}${backend}${NC}"
command -v ipset >/dev/null && ipset list >/dev/null 2>&1 && echo -e "  ipset: ${GREEN}✓${NC}" || echo -e "  ipset: ${RED}✗${NC}"
_check_ipv6_available && echo -e "  IPv6: ${GREEN}✓${NC}" || echo -e "  IPv6: ${YELLOW}✗${NC}"
echo ""
_detect_virt_env
}
manage_daemon_json() {
local choice current_root
while true; do
section "daemon.json 管理"
current_root=$(_get_current_data_root)
echo -e "  当前 data-root: ${CYAN}${current_root}${NC}"
echo "  1. 备份    2. 恢复    3. 查看    4. 设置 Docker 根目录    0. 返回"
hr
echo -n "  选择: "
read -r choice </dev/tty || break
case "$choice" in
1) backup_daemon_json ;;
2) restore_daemon_json ;;
3) [[ -f "$DAEMON_JSON" ]] && { jq . "$DAEMON_JSON" 2>/dev/null || cat "$DAEMON_JSON"; } || echo "  不存在" ;;
4) _set_docker_data_root ;;
0) break ;;
esac
done
}
manage_logs() {
section "日志管理"
local choice
echo "  日志: $LOG_FILE"
[[ -f "$LOG_FILE" ]] && echo "  大小: $(du -h "$LOG_FILE" | cut -f1)"
echo ""
echo "  1. 查看最近50行    2. 清空    0. 返回"
hr
echo -n "  选择: "
read -r choice </dev/tty || return 0
case "$choice" in
1) tail -50 "$LOG_FILE" 2>/dev/null ;;
2) : > "$LOG_FILE" && echo -e "  ${GREEN}已清空${NC}" ;;
esac
}
configure_proxy_mirror() {
section "代理镜像源"
local url
echo -e "  当前: ${PROXY_MIRROR_URL:-未配置}"
echo -e "  ${YELLOW}该地址会写入 daemon.json 的 registry-mirrors；留空表示清除${NC}"
echo -n "  输入新地址 (留空清除): "
read -r url </dev/tty || return 0
url="${url%/}"
if [[ -n "$url" && ! "$url" =~ ^https?://[^[:space:]]+$ ]]; then
echo -e "  ${RED}地址格式不正确，需以 http:// 或 https:// 开头${NC}"
return 1
fi
PROXY_MIRROR_URL="$url"
save_conf
if _set_registry_mirror "$PROXY_MIRROR_URL"; then
if [[ -n "$url" ]]; then
echo -e "  ${GREEN}已设置并写入 daemon.json${NC}"
else
echo -e "  ${GREEN}已清除 registry-mirrors${NC}"
fi
ask_restart
fi
}
print_menu() {
echo ""
echo -e "${BOLD}${CYAN}  Docker 智能管理脚本 v3.0${NC}"
echo -e "  架构: ${ARCH}  系统: ${OS}  包管理: ${PKG_MANAGER}"
hr
echo -e "  ${GREEN}1.${NC} 安装 Docker          ${GREEN}2.${NC} 安装 Compose"
echo -e "  ${GREEN}3.${NC} 安装两者            ${RED}4.${NC} 卸载 Docker"
echo -e "  ${RED}5.${NC} 卸载 Compose         ${RED}6.${NC} 卸载两者"
echo -e "  ${YELLOW}7.${NC} 查询状态            ${YELLOW}8.${NC} 生成 daemon.json"
echo -e "  ${YELLOW}9.${NC} 系统状态            ${BLUE}10.${NC} 服务管理"
echo -e "  ${BLUE}11.${NC} 状态仪表盘          ${BLUE}12.${NC} daemon.json 管理"
echo -e "  ${BLUE}13.${NC} 日志管理            ${BLUE}14.${NC} 镜像源测速"
echo -e "  ${BLUE}15.${NC} 代理配置            ${YELLOW}16.${NC} 清理默认镜像源"
echo -e "  ${RED}0.${NC} 退出"
hr
}
main() {
check_sudo
detect_package_manager
init_log
load_conf
command -v systemctl >/dev/null 2>&1 || echo -e "${YELLOW}警告：未检测到 systemctl，服务管理相关功能可能不可用${NC}"
install_dependencies || { echo -e "${RED}依赖安装失败，脚本退出${NC}"; exit 1; }
get_architecture || exit 1
OS=$(get_os_version)
local CHOICE
while true; do
print_menu
echo -n "  请选择 [0-16]: "
read -r CHOICE </dev/tty || break
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
16) clean_default_mirrors ;;
0) echo -e "  ${GREEN}再见！${NC}"; break ;;
"") ;;
*) echo -e "  ${RED}无效选择${NC}" ;;
esac
[[ -n "$CHOICE" && "$CHOICE" != "0" ]] && { echo ""; echo -n "  按回车继续..."; read -r </dev/tty || break; }
done
}
main
