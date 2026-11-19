#!/bin/bash
if [ -z "${BASH_VERSION:-}" ]; then
echo -e "\033[31m错误：此脚本需要使用 bash 运行，请使用 'bash $0' 来执行。\033[0m"
exit 1
fi
set -uo pipefail
RUN_UID="${SUDO_UID:-$(id -u)}"
RUN_GID="${SUDO_GID:-$(id -g)}"
RUN_HOME="$HOME"
if [[ -n "${SUDO_USER:-}" ]]; then
RUN_HOME="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)"
[[ -z "$RUN_HOME" ]] && RUN_HOME="$HOME"
fi
JELLYFIN_REPO="jellyfin/jellyfin"
JELLYFIN_NAME="jellyfin"
JELLYFIN_CONFIG_DIR="$RUN_HOME/docker/jellyfin/config"
JELLYFIN_CACHE_DIR="$RUN_HOME/docker/jellyfin/cache"
JELLYFIN_INTERNAL_PORT=8096
NOWEN_REPO="cropflre/nowen-video"
NOWEN_NAME="nowen-video"
NOWEN_CONFIG_DIR="$RUN_HOME/docker/nowen-video/data"
NOWEN_CACHE_DIR="$RUN_HOME/docker/nowen-video/cache"
NOWEN_INTERNAL_PORT=8080
EMBY_REPO="emby/embyserver"
EMBY_NAME="embyserver"
EMBY_CONFIG_DIR="$RUN_HOME/docker/emby/config"
EMBY_INTERNAL_PORT=8096
LOG_FILE="/var/log/media-server-deploy.log"
MOUNT_BASE="/mnt/media-share"
CRED_DIR="/etc/media-server-deploy"
FSTAB_TAG="# media-server-deploy:"
NET_MOUNT_POINT=""
TARGET_VERSION="latest"
red() { echo -e "\033[31m$*\033[0m"; }
green() { echo -e "\033[32m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }
cyan() { echo -e "\033[36m$*\033[0m"; }
run_as_root() {
if [[ $EUID -eq 0 ]]; then
"$@"
elif command -v sudo >/dev/null 2>&1; then
sudo "$@"
else
red "错误: 需要 root 权限，但系统中未找到 sudo，请以 root 用户运行。"
return 1
fi
}
docker_cmd() {
if docker info >/dev/null 2>&1; then
docker "$@"
else
run_as_root docker "$@"
fi
}
init_log() {
if run_as_root touch "$LOG_FILE" 2>/dev/null; then
run_as_root chown "$RUN_UID:$RUN_GID" "$LOG_FILE" 2>/dev/null
else
LOG_FILE="/tmp/media-server-deploy.log"
yellow "无法写入 /var/log/，日志将记录到: $LOG_FILE"
fi
touch "$LOG_FILE" 2>/dev/null || { red "无法创建日志文件 $LOG_FILE"; exit 1; }
exec > >(tee -a "$LOG_FILE") 2>&1
green "日志文件: $LOG_FILE"
}
confirm_operation() {
local prompt="$1 (y/n): " answer
while true; do
read -rp "$prompt" -n 1 -r answer || return 1
echo
case "$answer" in
[Yy]) return 0 ;;
[Nn]) return 1 ;;
*) red "请输入 y 或 n." ;;
esac
done
}
container_exists() {
docker_cmd ps -a --format '{{.Names}}' | grep -qx "$1"
}
check_port_is_free() {
local port=$1 cname=${2:-}
if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
red "错误: 端口必须为 1-65535 之间的数字。"
return 1
fi
if [[ -n "$cname" ]] && container_exists "$cname"; then
local used
used=$(docker_cmd inspect "$cname" --format '{{range $p, $conf := .HostConfig.PortBindings}}{{range $conf}}{{.HostPort}} {{end}}{{end}}' 2>/dev/null) || used=""
if [[ " $used " == *" $port "* ]]; then
return 0
fi
fi
if command -v ss >/dev/null 2>&1; then
if ss -Htuln 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]${port}$"; then
red "错误: 端口 $port 已被占用。"
return 1
fi
elif command -v lsof >/dev/null 2>&1; then
if run_as_root lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 || run_as_root lsof -nP -iUDP:"$port" >/dev/null 2>&1; then
red "错误: 端口 $port 已被占用。"
return 1
fi
else
yellow "警告: 未找到 ss/lsof，无法检测端口占用，请自行确认端口 $port 可用。"
fi
return 0
}
prepare_dir() {
local dir_path="$1" owner_id="$2"
if [[ ! -d "$dir_path" ]]; then
yellow "目录不存在，将自动创建: $dir_path"
mkdir -p "$dir_path" 2>/dev/null || run_as_root mkdir -p "$dir_path" || { red "创建目录失败: $dir_path"; return 1; }
fi
if ! chown -R "$owner_id" "$dir_path" 2>/dev/null; then
run_as_root chown -R "$owner_id" "$dir_path" 2>/dev/null || yellow "警告: 设置 '$dir_path' 所有者失败，容器内可能出现权限问题。"
fi
green "目录 '$dir_path' 准备就绪。"
return 0
}
install_net_pkgs() {
local type=$1 pkg_apt pkg_rpm bin
if [[ "$type" == smb ]]; then
pkg_apt=cifs-utils; pkg_rpm=cifs-utils; bin=mount.cifs
else
pkg_apt=nfs-common; pkg_rpm=nfs-utils; bin=mount.nfs
fi
command -v "$bin" >/dev/null 2>&1 && return 0
[[ -x "/sbin/$bin" || -x "/usr/sbin/$bin" ]] && return 0
yellow "正在安装 $type 客户端工具..."
if command -v apt-get >/dev/null 2>&1; then
run_as_root apt-get update && run_as_root apt-get install -y "$pkg_apt"
elif command -v dnf >/dev/null 2>&1; then
run_as_root dnf install -y "$pkg_rpm"
elif command -v yum >/dev/null 2>&1; then
run_as_root yum install -y "$pkg_rpm"
else
red "无法自动安装，请手动安装 $pkg_apt / $pkg_rpm"
return 1
fi
if ! command -v "$bin" >/dev/null 2>&1 && [[ ! -x "/sbin/$bin" && ! -x "/usr/sbin/$bin" ]]; then
red "客户端工具安装失败"
return 1
fi
return 0
}
remove_fstab_entry() {
local name=$1 tmp
tmp=$(mktemp)
awk -v m="${FSTAB_TAG}${name}" 'skip{skip=0;next} $0==m{skip=1;next} {print}' /etc/fstab > "$tmp" && run_as_root cp "$tmp" /etc/fstab
rm -f "$tmp"
}
add_network_share() {
NET_MOUNT_POINT=""
local c type fstype host remote name mp src mode base opts v ok=0 cred="" user pass domain def
echo "1. SMB/CIFS (Windows / 群晖 / 威联通 / 路由器共享)"
echo "2. NFS"
read -rp "选择协议 [1-2]: " c || return 1
case $c in
1) type=smb; fstype=cifs ;;
2) type=nfs; fstype=nfs ;;
*) red "无效选择"; return 1 ;;
esac
install_net_pkgs "$type" || return 1
read -rp "设备 IP 或主机名: " host || return 1
[[ "$host" =~ ^[A-Za-z0-9._-]+$ ]] || { red "主机名/IP 不合法"; return 1; }
if [[ $type == smb ]]; then
read -rp "共享名(可含子目录，如 media/movies，不要带 //IP/): " remote || return 1
remote=${remote#/}
[[ -n "$remote" ]] || { red "共享名不能为空"; return 1; }
src="//$host/$remote"
else
read -rp "NFS 导出路径(如 /volume1/video): " remote || return 1
[[ "$remote" == /* ]] || { red "NFS 路径必须以 / 开头"; return 1; }
src="$host:$remote"
fi
case "$remote" in
*$'\t'*|*$'\n'*|*\\*|*\"*|*\'*) red "路径含非法字符"; return 1 ;;
esac
def="${host//./_}_${remote//[^A-Za-z0-9]/_}"
read -rp "本地挂载名 [默认 ${def:0:40}]: " name || return 1
name=${name:-${def:0:40}}
[[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || { red "名称只能含字母数字下划线连字符"; return 1; }
mp="$MOUNT_BASE/$name"
if grep -qxF "${FSTAB_TAG}${name}" /etc/fstab 2>/dev/null; then
yellow "共享 $name 已存在，直接使用 $mp"
mountpoint -q "$mp" || run_as_root mount "$mp" || { red "挂载失败"; return 1; }
NET_MOUNT_POINT="$mp"
return 0
fi
mode=rw
confirm_operation "宿主机以只读方式挂载（推荐，防止误删媒体）？" && mode=ro
base="$mode,nofail,_netdev,x-systemd.mount-timeout=30"
if [[ $type == smb ]]; then
read -rp "用户名 (留空=匿名 guest): " user || return 1
if [[ -n "$user" ]]; then
read -rsp "密码: " pass || return 1
echo
read -rp "域/工作组 (可留空): " domain || domain=""
cred="$CRED_DIR/$name.cred"
run_as_root install -d -m 700 "$CRED_DIR"
( umask 077
{ printf 'username=%s\npassword=%s\n' "$user" "$pass"
[[ -n "$domain" ]] && printf 'domain=%s\n' "$domain"; } | run_as_root tee "$cred" >/dev/null )
run_as_root chmod 600 "$cred"
base+=",credentials=$cred"
else
base+=",guest"
fi
base+=",uid=$RUN_UID,gid=$RUN_GID,file_mode=0664,dir_mode=0775,iocharset=utf8"
else
[[ $mode == ro ]] && base+=",soft,timeo=100,retrans=3"
fi
run_as_root mkdir -p "$mp" || return 1
local -a vers
if [[ $type == smb ]]; then
vers=("vers=3.0" "vers=2.1" "")
else
vers=("" "nfsvers=3,nolock")
fi
for v in "${vers[@]}"; do
opts="$base${v:+,$v}"
yellow "尝试挂载: $src -> $mp (${v:-自动协商})"
if run_as_root mount -t "$fstype" "$src" "$mp" -o "$opts"; then
ok=1
break
fi
done
if (( ! ok )); then
red "挂载失败。常见原因：账号/密码错误、共享名错误、NAS 未开启对应协议、防火墙、NFS 未授权本机 IP。"
[[ -n "$cred" ]] && run_as_root rm -f "$cred"
run_as_root rmdir "$mp" 2>/dev/null
return 1
fi
run_as_root cp -a /etc/fstab "/etc/fstab.bak.$(date +%s)"
[[ -n "$(tail -c1 /etc/fstab)" ]] && echo | run_as_root tee -a /etc/fstab >/dev/null
printf '%s%s\n%s %s %s %s 0 0\n' "$FSTAB_TAG" "$name" "${src// /\\040}" "$mp" "$fstype" "$opts" | run_as_root tee -a /etc/fstab >/dev/null
if command -v systemctl >/dev/null 2>&1; then
run_as_root systemctl daemon-reload
run_as_root install -d /etc/systemd/system/docker.service.d
printf '[Unit]\nAfter=remote-fs.target\n' | run_as_root tee /etc/systemd/system/docker.service.d/10-media-mounts.conf >/dev/null
run_as_root systemctl daemon-reload
fi
if run_as_root umount "$mp"; then
if ! run_as_root mount "$mp"; then
red "fstab 条目验证失败，已回滚。"
remove_fstab_entry "$name"
[[ -n "$cred" ]] && run_as_root rm -f "$cred"
command -v systemctl >/dev/null 2>&1 && run_as_root systemctl daemon-reload
return 1
fi
fi
green "共享已挂载并写入 /etc/fstab（开机自动挂载）: $mp"
ls -la "$mp" 2>/dev/null | head -n 8
NET_MOUNT_POINT="$mp"
return 0
}
list_network_shares() {
local out
out=$(awk -v t="$FSTAB_TAG" 'index($0,t)==1{n=substr($0,length(t)+1); getline; print n"\t"$1"\t"$2"\t"$3}' /etc/fstab 2>/dev/null)
if [[ -z "$out" ]]; then
yellow "尚未通过本脚本添加任何共享。"
return 1
fi
if command -v column >/dev/null 2>&1; then
printf '名称\t来源\t本地路径\t类型\n%s\n' "$out" | column -t -s $'\t'
else
printf '名称\t来源\t本地路径\t类型\n%s\n' "$out"
fi
echo
findmnt -t cifs,nfs,nfs4 2>/dev/null
return 0
}
remove_network_share() {
local name mp ids hit
list_network_shares || return 1
read -rp "输入要移除的共享名称: " name || return 1
if ! [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || ! grep -qxF "${FSTAB_TAG}${name}" /etc/fstab; then
red "未找到该共享"
return 1
fi
mp="$MOUNT_BASE/$name"
ids=$(docker_cmd ps -aq 2>/dev/null)
if [[ -n "$ids" ]]; then
hit=$(docker_cmd inspect --format '{{.Name}}: {{range .Mounts}}{{.Source}} {{end}}' $ids 2>/dev/null | grep -F "$mp")
if [[ -n "$hit" ]]; then
yellow "以下容器正在使用该共享:"
echo "$hit"
confirm_operation "仍要继续移除？" || return 1
fi
fi
if mountpoint -q "$mp"; then
run_as_root umount "$mp" || { red "卸载失败（设备忙），请先停止相关容器。"; return 1; }
fi
remove_fstab_entry "$name"
run_as_root rm -f "$CRED_DIR/$name.cred"
run_as_root rmdir "$mp" 2>/dev/null
command -v systemctl >/dev/null 2>&1 && run_as_root systemctl daemon-reload
green "已移除共享 $name"
return 0
}
network_share_menu() {
local c
while true; do
clear
cyan "========== 局域网共享挂载管理 =========="
green "1. 添加 SMB/NFS 共享"
green "2. 查看已添加的共享"
green "3. 移除共享"
yellow "0. 返回"
read -rp "请选择 [0-3]: " c || break
case $c in
1) add_network_share; read -rp "按回车键继续..." ;;
2) list_network_shares; read -rp "按回车键继续..." ;;
3) remove_network_share; read -rp "按回车键继续..." ;;
0) break ;;
*) red "无效选择"; sleep 1 ;;
esac
done
}
bind_opts_for() {
local dir=$1 mode=$2 fstype prop need=0
command -v findmnt >/dev/null 2>&1 || { echo "$mode"; return; }
fstype=$(findmnt -no FSTYPE -T "$dir" 2>/dev/null | head -n1)
case "$fstype" in
cifs|nfs|nfs4|fuse.*|9p) need=1 ;;
esac
[[ "$dir" == "$MOUNT_BASE"* ]] && need=1
if (( need )); then
prop=$(findmnt -no PROPAGATION -T "$dir" 2>/dev/null | head -n1)
if [[ "$prop" == *shared* || "$prop" == *slave* ]]; then
echo "$mode,rslave"
return
fi
yellow "警告: $dir 所在挂载点传播属性为 '${prop:-未知}'，无法使用 rslave；共享断线重连后容器内需重启。" >&2
fi
echo "$mode"
}
ask_mount_directories() {
local -n mount_ref=$1
local dir mode opts sub
yellow "添加媒体库挂载目录。输入宿主机绝对路径，会映射到容器内同名路径。"
yellow "输入 n 可先添加局域网 SMB/NFS 共享（会自动写入 fstab 并开机挂载）。"
while true; do
read -rp "目录绝对路径 (n=添加局域网共享, 留空结束): " dir || break
[[ -z "$dir" ]] && break
if [[ "$dir" == [nN] ]]; then
if add_network_share; then
dir="$NET_MOUNT_POINT"
else
continue
fi
read -rp "容器内要挂载的路径 [默认整个共享 $dir，可填其子目录]: " sub || sub=""
dir=${sub:-$dir}
fi
if [[ "$dir" != /* || "$dir" == *:* ]]; then
red "错误：请输入不含冒号的绝对路径（以 / 开头）。"
continue
fi
if [[ ! -d "$dir" ]]; then
red "错误：目录不存在: $dir"
continue
fi
mode="rw"
confirm_operation "是否以只读方式挂载该媒体目录（推荐）？" && mode="ro"
opts=$(bind_opts_for "$dir" "$mode")
mount_ref+=("-v" "$dir:$dir:$opts")
green "已添加挂载: $dir ($opts)"
done
}
ask_hardware_accel() {
local -n dev_ref=$1
local app=${2:-} g dev
if [[ -d /dev/dri ]]; then
if confirm_operation "检测到 /dev/dri，是否启用硬件加速（推荐）？"; then
dev_ref+=("--device" "/dev/dri:/dev/dri")
if [[ "$app" != emby ]]; then
for dev in /dev/dri/renderD128 /dev/dri/card0; do
g=$(stat -c '%g' "$dev" 2>/dev/null) && dev_ref+=("--group-add" "$g")
done
fi
green "已添加硬件加速设备 /dev/dri"
fi
else
yellow "未检测到 /dev/dri，跳过硬件加速配置。"
fi
}
install_dependencies() {
yellow "检查并安装依赖 (docker, curl, jq)..."
local needs_install="" cur_user
cur_user="$(id -un)"
command -v docker >/dev/null 2>&1 || needs_install+="docker "
command -v jq >/dev/null 2>&1 || needs_install+="jq "
command -v curl >/dev/null 2>&1 || needs_install+="curl "
if [[ -n "$needs_install" ]]; then
yellow "检测到以下依赖未安装: $needs_install，正在尝试自动安装..."
if command -v apt-get >/dev/null 2>&1; then
run_as_root apt-get update
run_as_root apt-get install -y docker.io curl jq
elif command -v dnf >/dev/null 2>&1; then
run_as_root dnf install -y docker jq curl
elif command -v yum >/dev/null 2>&1; then
run_as_root yum install -y yum-utils
run_as_root yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
run_as_root yum install -y docker-ce docker-ce-cli containerd.io jq curl
elif command -v opkg >/dev/null 2>&1; then
run_as_root opkg update
command -v docker >/dev/null 2>&1 || run_as_root opkg install dockerd docker
command -v jq >/dev/null 2>&1 || run_as_root opkg install jq
command -v curl >/dev/null 2>&1 || run_as_root opkg install curl
else
red "不支持的操作系统。请手动安装: $needs_install"
return 1
fi
fi
if ! command -v docker >/dev/null 2>&1; then
red "Docker 安装失败，请手动安装后重试。"
return 1
fi
if command -v systemctl >/dev/null 2>&1; then
run_as_root systemctl enable --now docker 2>/dev/null || true
elif [[ -x /etc/init.d/dockerd ]]; then
run_as_root /etc/init.d/dockerd enable 2>/dev/null || true
run_as_root /etc/init.d/dockerd start 2>/dev/null || true
elif command -v service >/dev/null 2>&1; then
run_as_root service docker start 2>/dev/null || true
fi
if ! docker_cmd info >/dev/null 2>&1; then
red "无法连接 Docker 守护进程，请确认 Docker 已启动。"
return 1
fi
if [[ $EUID -ne 0 ]] && ! id -nG "$cur_user" | tr ' ' '\n' | grep -qx docker; then
if getent group docker >/dev/null 2>&1; then
run_as_root usermod -aG docker "$cur_user" 2>/dev/null || true
yellow "已尝试将用户 '$cur_user' 加入 docker 组（docker 组等同于 root 权限），重新登录后生效；当前会话将通过 sudo 调用 docker。"
fi
fi
green "依赖检测完毕。"
return 0
}
get_docker_tags() {
local repo=$1 versions="" i
for i in 1 2 3; do
versions=$(curl -fsS -m 10 "https://hub.docker.com/v2/repositories/${repo}/tags/?page_size=100" 2>/dev/null | jq -r '.results[]?.name' 2>/dev/null | grep -E '^[vV]?[0-9]+(\.[0-9]+){1,3}$' | sort -Vur 2>/dev/null | head -n 15)
if [[ -n "$versions" ]]; then break; fi
sleep 2
done
echo "$versions"
}
prompt_for_version() {
local repo=$1 desc=$2
cyan "正在从 Docker Hub 获取 $desc 可用版本列表，请稍候..."
local versions_str
versions_str=$(get_docker_tags "$repo")
local -a versions=("latest")
if [[ -n "$versions_str" ]]; then
mapfile -t -O 1 versions <<< "$versions_str"
fi
local num_versions=${#versions[@]}
if [[ $num_versions -le 1 ]]; then
yellow "无法自动获取版本列表（可能由于网络问题）。"
local manual_version
read -rp "请输入您要使用的版本标签 [直接回车默认使用: latest]: " manual_version || manual_version=""
TARGET_VERSION=${manual_version:-latest}
green "已确认版本: $TARGET_VERSION"
return 0
fi
cyan "请选择 $desc 版本："
local i
for i in "${!versions[@]}"; do
echo "$((i + 1)). ${versions[$i]}"
done
local version_choice
while true; do
read -rp "请输入版本编号 [直接回车默认选择 1 (latest)]: " version_choice || version_choice=1
version_choice=${version_choice:-1}
if [[ "$version_choice" =~ ^[0-9]+$ ]] && (( version_choice >= 1 && version_choice <= num_versions )); then
TARGET_VERSION=${versions[$((version_choice - 1))]}
break
else
red "无效的选择，请输入 1 到 $num_versions 之间的数字。"
fi
done
green "已选择版本: $TARGET_VERSION"
return 0
}
verify_container_running() {
local cname=$1 i state
for i in 1 2 3 4 5 6; do
sleep 2
state=$(docker_cmd inspect -f '{{.State.Status}}' "$cname" 2>/dev/null) || state="missing"
if [[ "$state" == "running" ]]; then
return 0
fi
if [[ "$state" == "restarting" || "$state" == "exited" || "$state" == "dead" ]]; then
break
fi
done
red "容器 $cname 启动失败或异常退出！最近日志如下："
docker_cmd logs --tail 50 "$cname" 2>&1 || true
return 1
}
remove_existing_container() {
local cname=$1
if container_exists "$cname"; then
yellow "检测到同名容器 $cname，需要先停止并删除旧容器（数据目录保留）。"
if confirm_operation "是否停止并删除现有容器 $cname？"; then
docker_cmd stop "$cname" >/dev/null 2>&1 || true
docker_cmd rm "$cname" >/dev/null 2>&1 || { red "删除容器失败: $cname"; return 1; }
else
yellow "操作已取消。"
return 1
fi
fi
return 0
}
upgrade_container() {
local cname="$1" repo="$2" desc="$3"
if ! command -v jq >/dev/null 2>&1; then red "此功能需要 jq，请先安装。"; return 1; fi
if ! container_exists "$cname"; then
red "$desc 容器未部署，无法进行更新操作。"
return 1
fi
yellow "准备更新 $desc，现有的配置与挂载目录将被完整保留。"
TARGET_VERSION="latest"
prompt_for_version "$repo" "$desc" || return 1
local new_image="$repo:$TARGET_VERSION"
yellow "正在拉取镜像: $new_image"
docker_cmd pull "$new_image" || { red "镜像拉取失败，已取消更新，原容器保持不变。"; return 1; }
yellow "正在提取当前容器配置信息..."
local container_info
container_info=$(docker_cmd inspect "$cname") || { red "读取容器配置失败。"; return 1; }
local -a new_run_args=("-d" "--name" "$cname")
local orig_user
orig_user=$(echo "$container_info" | jq -r '.[0].Config.User // ""')
[[ -n "$orig_user" ]] && new_run_args+=("--user" "$orig_user")
local net_mode
net_mode=$(echo "$container_info" | jq -r '.[0].HostConfig.NetworkMode // "bridge"')
if [[ -n "$net_mode" && "$net_mode" != "default" ]]; then
new_run_args+=("--network" "$net_mode")
fi
local -a clean_ports=()
mapfile -t clean_ports < <(echo "$container_info" | jq -r '.[0].HostConfig.PortBindings // {} | to_entries[] | .key as $k | (.value // [])[] | (.HostIp // "") as $h | "-p", ((if ($h == "" or $h == "0.0.0.0") then "" elif ($h | contains(":")) then "[\($h)]:" else "\($h):" end) + "\(.HostPort):\($k)")')
if (( ${#clean_ports[@]} > 0 )); then new_run_args+=("${clean_ports[@]}"); fi
local -a orig_mounts=()
mapfile -t orig_mounts < <(echo "$container_info" | jq -r '.[0].Mounts[]? | select(.Type=="bind" or .Type=="volume") | (.Propagation // "") as $p | (if .Type=="volume" then .Name else .Source end) as $s | "-v", "\($s):\(.Destination):\([(if .RW then "rw" else "ro" end), (if ($p != "" and $p != "rprivate") then $p else empty end)] | join(","))"')
if (( ${#orig_mounts[@]} > 0 )); then new_run_args+=("${orig_mounts[@]}"); fi
local -a orig_devices=()
mapfile -t orig_devices < <(echo "$container_info" | jq -r '.[0].HostConfig.Devices[]? | "--device", "\(.PathOnHost):\(.PathInContainer)"')
if (( ${#orig_devices[@]} > 0 )); then new_run_args+=("${orig_devices[@]}"); fi
local -a orig_groups=()
mapfile -t orig_groups < <(echo "$container_info" | jq -r '.[0].HostConfig.GroupAdd[]? | "--group-add", .')
if (( ${#orig_groups[@]} > 0 )); then new_run_args+=("${orig_groups[@]}"); fi
local old_img_id base_env
local -a orig_env=()
old_img_id=$(echo "$container_info" | jq -r '.[0].Image')
base_env=$(docker_cmd image inspect "$old_img_id" 2>/dev/null | jq -c '.[0].Config.Env // []') || base_env='[]'
[[ -z "$base_env" ]] && base_env='[]'
mapfile -t orig_env < <(echo "$container_info" | jq -r --argjson base "$base_env" '.[0].Config.Env[]? | select(. as $e | $base | index($e) | not) | "-e", .')
if (( ${#orig_env[@]} > 0 )); then new_run_args+=("${orig_env[@]}"); fi
local restart_policy
restart_policy=$(echo "$container_info" | jq -r '.[0].HostConfig.RestartPolicy.Name // "no"')
if [[ -n "$restart_policy" && "$restart_policy" != "no" ]]; then
if [[ "$restart_policy" == "on-failure" ]]; then
local max_retry
max_retry=$(echo "$container_info" | jq -r '.[0].HostConfig.RestartPolicy.MaximumRetryCount // 0')
new_run_args+=("--restart" "on-failure:$max_retry")
else
new_run_args+=("--restart" "$restart_policy")
fi
fi
local old_name="${cname}_old_$$"
yellow "正在停止旧容器并重命名备份..."
docker_cmd stop "$cname" >/dev/null 2>&1 || true
docker_cmd rename "$cname" "$old_name" || { red "重命名旧容器失败，中止。"; docker_cmd start "$cname"; return 1; }
yellow "正在使用新镜像重建容器..."
if docker_cmd run "${new_run_args[@]}" "$new_image" && verify_container_running "$cname"; then
docker_cmd rm "$old_name" >/dev/null 2>&1
green "$desc 已成功更新至 $TARGET_VERSION 并启动！"
return 0
fi
red "更新失败，正在回滚到旧容器..."
docker_cmd rm -f "$cname" >/dev/null 2>&1
if docker_cmd rename "$old_name" "$cname" && docker_cmd start "$cname"; then
yellow "已回滚到旧版本。"
else
red "回滚失败，旧容器备份名称为: $old_name"
fi
return 1
}
deploy_media_server() {
local app="$1"
local name repo internal_port config_dir cache_dir data_target
case "$app" in
jellyfin) name="$JELLYFIN_NAME"; repo="$JELLYFIN_REPO"; internal_port="$JELLYFIN_INTERNAL_PORT"; config_dir="$JELLYFIN_CONFIG_DIR"; cache_dir="$JELLYFIN_CACHE_DIR"; data_target="/config" ;;
nowen) name="$NOWEN_NAME"; repo="$NOWEN_REPO"; internal_port="$NOWEN_INTERNAL_PORT"; config_dir="$NOWEN_CONFIG_DIR"; cache_dir="$NOWEN_CACHE_DIR"; data_target="/data" ;;
emby) name="$EMBY_NAME"; repo="$EMBY_REPO"; internal_port="$EMBY_INTERNAL_PORT"; config_dir="$EMBY_CONFIG_DIR"; cache_dir=""; data_target="/config" ;;
*) red "未知应用: $app"; return 1 ;;
esac
local port
while true; do
read -rp "请输入 $name 的外部访问端口 (默认 $internal_port): " port || return 1
port=${port:-$internal_port}
check_port_is_free "$port" "$name" && break
done
local -a extra_ports=()
if [[ "$app" == "jellyfin" ]] && confirm_operation "是否映射 DLNA/局域网自动发现端口 (1900/udp, 7359/udp)？"; then
if check_port_is_free 1900 "$name" && check_port_is_free 7359 "$name"; then
extra_ports=("-p" "1900:1900/udp" "-p" "7359:7359/udp")
else
yellow "自动发现端口被占用，已跳过。"
fi
fi
local -a kept_mounts=()
if container_exists "$name"; then
local old_info
old_info=$(docker_cmd inspect "$name" 2>/dev/null) || old_info=""
if [[ -n "$old_info" ]] && confirm_operation "是否沿用原容器的媒体目录挂载？"; then
mapfile -t kept_mounts < <(echo "$old_info" | jq -r --arg c "$config_dir" --arg k "$cache_dir" '.[0].Mounts[]? | select(.Type=="bind" and .Source != $c and .Source != $k) | (.Propagation // "") as $p | "-v", "\(.Source):\(.Destination):\([(if .RW then "rw" else "ro" end), (if ($p != "" and $p != "rprivate") then $p else empty end)] | join(","))"')
fi
fi
remove_existing_container "$name" || return 1
prepare_dir "$config_dir" "$RUN_UID:$RUN_GID" || return 1
if [[ -n "$cache_dir" ]]; then
prepare_dir "$cache_dir" "$RUN_UID:$RUN_GID" || return 1
fi
local -a docker_args=("-d" "--name" "$name" "-p" "${port}:${internal_port}" "-v" "$config_dir:$data_target" "--restart" "unless-stopped" "-e" "TZ=Asia/Shanghai")
if (( ${#extra_ports[@]} > 0 )); then docker_args+=("${extra_ports[@]}"); fi
if [[ -n "$cache_dir" ]]; then
docker_args+=("-v" "$cache_dir:/cache")
fi
case "$app" in
jellyfin) docker_args+=("--user" "$RUN_UID:$RUN_GID") ;;
nowen) docker_args+=("-e" "PUID=$RUN_UID" "-e" "PGID=$RUN_GID") ;;
emby)
docker_args+=("-e" "UID=$RUN_UID" "-e" "GID=$RUN_GID")
local render_gid video_gid gidlist=""
render_gid=$(stat -c '%g' /dev/dri/renderD128 2>/dev/null) || render_gid=""
video_gid=$(getent group video 2>/dev/null | cut -d: -f3) || video_gid=""
[[ -n "$render_gid" ]] && gidlist="$render_gid"
if [[ -n "$video_gid" && "$video_gid" != "$render_gid" ]]; then
gidlist="${gidlist:+$gidlist,}$video_gid"
fi
[[ -n "$gidlist" ]] && docker_args+=("-e" "GIDLIST=$gidlist")
;;
esac
ask_hardware_accel docker_args "$app"
if (( ${#kept_mounts[@]} > 0 )); then docker_args+=("${kept_mounts[@]}"); fi
ask_mount_directories docker_args
TARGET_VERSION="latest"
prompt_for_version "$repo" "$name" || return 1
local image="$repo:$TARGET_VERSION"
yellow "正在拉取镜像: $image"
docker_cmd pull "$image" || { red "镜像拉取失败。"; return 1; }
yellow "正在启动 $name 容器..."
docker_cmd run "${docker_args[@]}" "$image" || { red "容器创建失败。"; return 1; }
if verify_container_running "$name"; then
green "$name 启动成功！"
green "访问地址: http://<你的服务器IP>:$port"
if [[ "$app" == "nowen" ]]; then
green "首次打开页面注册的用户将自动成为管理员，请及时设置强密码，且不要直接暴露到公网。"
else
green "首次访问请通过向导创建管理员账号并添加媒体库。"
fi
return 0
fi
return 1
}
status_media_server() {
local name="$1" desc="$2"
if container_exists "$name"; then
docker_cmd ps -a --filter "name=^${name}$" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
yellow "最近20条日志："
docker_cmd logs --tail 20 "$name" 2>&1 || true
else
red "$desc 容器未部署。"
fi
}
uninstall_media_server() {
local name="$1" desc="$2"
shift 2
local -a data_dirs=("$@")
yellow "卸载 $desc..."
if ! container_exists "$name"; then
yellow "未发现 $desc 容器，无需卸载。"
return 0
fi
if ! confirm_operation "确定要卸载 $desc 吗？"; then
yellow "卸载操作已取消。"
return 0
fi
local image_ref
image_ref=$(docker_cmd inspect -f '{{.Config.Image}}' "$name" 2>/dev/null) || image_ref=""
docker_cmd stop "$name" >/dev/null 2>&1 || true
docker_cmd rm "$name" >/dev/null 2>&1 || true
green "$desc 容器已停止并移除。"
if [[ -n "$image_ref" ]] && confirm_operation "是否删除 $desc 的镜像 ($image_ref)？"; then
docker_cmd rmi "$image_ref" 2>/dev/null || yellow "镜像可能不存在或被其他容器使用。"
fi
if confirm_operation "【高危】是否删除 $desc 的所有配置与缓存目录？媒体文件不会被删除。"; then
local d
for d in "${data_dirs[@]}"; do
if [[ -n "$d" && "$d" == "$RUN_HOME/docker/"* && -d "$d" ]]; then
rm -rf "$d" 2>/dev/null || run_as_root rm -rf "$d"
green "已删除目录: $d"
fi
done
fi
green "$desc 已卸载完成。"
return 0
}
show_main_menu() {
clear
cyan "=================================================="
cyan "       Linux 影视媒体服务器一键部署脚本"
cyan "   支持 Jellyfin / nowen-video / Emby + 路径挂载"
cyan "=================================================="
echo
green "1. 部署 / 管理 Jellyfin（推荐，完全免费开源）"
green "2. 部署 / 管理 nowen-video（轻量中文友好）"
green "3. 部署 / 管理 Emby"
echo
yellow "4. 检查 Docker 与依赖状态"
yellow "5. 查看当前已部署的媒体服务器"
yellow "6. 局域网共享挂载管理 (SMB/NFS)"
echo
red "0. 退出脚本"
echo
}
app_menu() {
local app="$1" name="$2" repo="$3" desc="$4"
shift 4
local -a data_dirs=("$@")
local choice
while true; do
clear
cyan "========== $desc 管理菜单 =========="
echo
green "1. 安装 / 重新部署 $desc"
green "2. 查看状态与日志"
green "3. 更新 $desc（保留配置与挂载）"
green "4. 卸载 $desc"
echo
yellow "0. 返回主菜单"
echo
read -rp "请选择操作 [0-4]: " choice || break
case $choice in
1) deploy_media_server "$app"; read -rp "按回车键继续..." ;;
2) status_media_server "$name" "$desc"; read -rp "按回车键继续..." ;;
3) upgrade_container "$name" "$repo" "$desc"; read -rp "按回车键继续..." ;;
4) uninstall_media_server "$name" "$desc" "${data_dirs[@]}"; read -rp "按回车键继续..." ;;
0) break ;;
*) red "无效选择"; sleep 1 ;;
esac
done
}
check_status() {
echo
cyan "========== 当前已部署的媒体服务器 =========="
local entry name desc
for entry in "$JELLYFIN_NAME|Jellyfin" "$NOWEN_NAME|nowen-video" "$EMBY_NAME|Emby"; do
name=${entry%%|*}
desc=${entry##*|}
echo
if container_exists "$name"; then
green "[$desc] 已部署"
docker_cmd ps -a --filter "name=^${name}$" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
else
yellow "[$desc] 未部署"
fi
done
echo
}
main() {
init_log
if [[ "$RUN_UID" == "0" ]]; then
yellow "警告: 当前以 root 身份运行，容器将以 root 权限运行，建议使用普通用户执行本脚本。"
fi
install_dependencies || { red "依赖初始化失败，脚本退出。"; exit 1; }
local main_choice
while true; do
show_main_menu
read -rp "请选择操作 [0-6]: " main_choice || { green "感谢使用，再见！"; exit 0; }
case $main_choice in
1) app_menu jellyfin "$JELLYFIN_NAME" "$JELLYFIN_REPO" "Jellyfin" "$JELLYFIN_CONFIG_DIR" "$JELLYFIN_CACHE_DIR" ;;
2) app_menu nowen "$NOWEN_NAME" "$NOWEN_REPO" "nowen-video" "$NOWEN_CONFIG_DIR" "$NOWEN_CACHE_DIR" ;;
3) app_menu emby "$EMBY_NAME" "$EMBY_REPO" "Emby" "$EMBY_CONFIG_DIR" ;;
4) install_dependencies; read -rp "按回车键继续..." ;;
5) check_status; read -rp "按回车键继续..." ;;
6) network_share_menu ;;
0) green "感谢使用，再见！"; exit 0 ;;
*) red "无效选择，请重新输入。"; sleep 1 ;;
esac
done
}
main "$@"
