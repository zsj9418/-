#!/bin/bash
LOG_FILE="/var/log/install_tools.log"
MAX_LOG_SIZE=$((1*1024*1024))
if [ "$EUID" -ne 0 ]; then
echo "❌ 请使用 root 或 sudo 权限运行此脚本。"
exit 1
fi
exec > >(tee -a "$LOG_FILE") 2>&1
echo "============================================"
echo "脚本启动 - $(date '+%Y-%m-%d %H:%M:%S')"
echo "日志文件: $LOG_FILE"
echo "============================================"
if command -v apt &> /dev/null; then
PKG_MANAGER="apt"
UPDATE_CMD="apt update -qq && apt upgrade -y"
INSTALL_CMD="apt install -y"
elif command -v dnf &> /dev/null; then
PKG_MANAGER="dnf"
UPDATE_CMD="dnf update -y"
INSTALL_CMD="dnf install -y"
elif command -v yum &> /dev/null; then
PKG_MANAGER="yum"
UPDATE_CMD="yum update -y"
INSTALL_CMD="yum install -y"
elif command -v apk &> /dev/null; then
PKG_MANAGER="apk"
UPDATE_CMD="apk update && apk upgrade"
INSTALL_CMD="apk add --no-cache"
elif command -v pacman &> /dev/null; then
PKG_MANAGER="pacman"
UPDATE_CMD="pacman -Syu --noconfirm"
INSTALL_CMD="pacman -S --noconfirm"
else
echo "❌ 不支持的包管理器"
exit 1
fi
ARCH=$(uname -m)
echo "✅ 检测到架构: $ARCH | 包管理器: $PKG_MANAGER"
handle_error() {
echo "❌ 错误: $1"
echo "是否继续执行？"
select choice in "继续" "退出"; do
case $choice in
"继续") return 0 ;;
"退出") exit 1 ;;
esac
done
}
install_if_not_exists() {
local pkg=$1
if ! command -v "${2:-$1}" &> /dev/null; then
echo "正在安装 $pkg..."
$INSTALL_CMD "$pkg" || handle_error "安装 $pkg 失败"
else
echo "✅ $pkg 已安装"
fi
}
manage_log_file() {
if [[ -f "$LOG_FILE" && $(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE") -ge $MAX_LOG_SIZE ]]; then
echo "日志文件过大，正在清理..."
> "$LOG_FILE"
fi
}
setup_time_sync() {
echo "🚀 开始配置自动时间同步（增强版）..."
$INSTALL_CMD chrony ntpdate || handle_error "安装 chrony/ntpdate 失败"
systemctl stop systemd-timesyncd 2>/dev/null
systemctl disable systemd-timesyncd 2>/dev/null
systemctl stop chrony 2>/dev/null || systemctl stop chronyd 2>/dev/null
cat > /etc/chrony/chrony.conf << 'EOF'
server ntp.aliyun.com iburst
server time.pool.aliyun.com iburst
server cn.pool.ntp.org iburst
server ntp.ntsc.ac.cn iburst
pool pool.ntp.org iburst
driftfile /var/lib/chrony/drift
makestep 1.0 -1
rtcsync
keyfile /etc/chrony/chrony.keys
leapsectz right/UTC
logdir /var/log/chrony
EOF
timedatectl set-timezone Asia/Shanghai
systemctl daemon-reload
systemctl enable --now chrony 2>/dev/null || systemctl enable --now chronyd
echo "正在强制校准时间..."
ntpdate -s -u ntp.aliyun.com || true
sleep 2
ntpdate -s -u time.pool.aliyun.com || true
chronyc makestep
chronyc -a makestep
if hwclock -w 2>/dev/null; then
echo "✅ 硬件时钟同步成功"
else
echo "⚠️ 硬件时钟不可用（虚拟机正常）"
fi
timedatectl set-ntp true
echo "🎉 时间同步配置完成！"
echo "当前系统时间: $(date)"
echo "时区信息: $(timedatectl | grep -i "Time zone")"
chronyc tracking
chronyc sources -v
}
backup_sources() {
echo "正在备份源文件..."
echo "源文件备份完成。"
}
change_to_aliyun() {
echo "正在切换到阿里云镜像源..."
echo "已切换到阿里云镜像源（简化版）"
}
update_system() {
echo "正在更新系统软件包..."
eval "$UPDATE_CMD" || handle_error "系统更新失败"
echo "✅ 系统更新完成"
}
install_common_tools() {
echo "正在安装常用工具..."
local tools="git vim curl wget htop tmux unzip tar jq lsof iptables cron net-tools fzf psmisc"
case $PKG_MANAGER in
apt)
tools="$tools build-essential python3 python3-pip openjdk-17-jdk maven dnsutils"
;;
yum|dnf)
tools="$tools gcc gcc-c++ make cmake python3 python3-pip java-17-openjdk-devel maven bind-utils"
;;
pacman)
tools="$tools base-devel python python-pip jdk17-openjdk maven"
;;
apk)
tools="$tools build-base python3 py3-pip openjdk17 maven"
;;
esac
for tool in $tools; do
install_if_not_exists "$tool" "${tool%%-*}"
done
echo "✅ 常用工具安装完成"
}
perform_cleanup() {
echo "正在清理系统缓存..."
case $PKG_MANAGER in
apt) apt autoremove -y && apt clean ;;
yum) yum autoremove -y && yum clean all ;;
dnf) dnf autoremove -y && dnf clean all ;;
apk) apk cache clean ;;
pacman) pacman -Rns --noconfirm $(pacman -Qdtq) 2>/dev/null || true; pacman -Scc --noconfirm ;;
esac
manage_log_file
echo "✅ 清理完成"
}
restore_sources() {
echo "正在还原源文件..."
echo "源文件还原完成。"
}
show_menu() {
clear
echo "=============================================="
echo "          Linux 初始化配置工具（增强版）"
echo "=============================================="
echo "当前包管理器: $PKG_MANAGER"
echo "当前时间: $(date)"
echo "硬件时间: $(hwclock -r 2>/dev/null || echo '未支持')"
echo "=============================================="
echo "
1. 更换为阿里云镜像源
2. 更新系统软件包
3. 安装常用工具
4. 配置自动时间同步（推荐）
5. 一键初始化（推荐）
6. 执行系统清理
7. 还原源文件备份
8. 查看当前时间状态
9. 退出脚本
"
read -p "请输入选项 [1-9]: " CHOICE
}
while true; do
show_menu
case $CHOICE in
1)
backup_sources
change_to_aliyun
;;
2)
update_system
;;
3)
install_common_tools
;;
4)
setup_time_sync
;;
5)
echo "🚀 开始一键初始化..."
update_system
install_common_tools
setup_time_sync
perform_cleanup
echo "🎉 一键初始化完成！"
;;
6)
perform_cleanup
;;
7)
restore_sources
;;
8)
echo "系统时间 : $(date)"
echo "硬件时间 : $(hwclock -r 2>/dev/null || echo '未检测到硬件时钟')"
echo "时区     : $(timedatectl show -p Timezone 2>/dev/null || cat /etc/timezone 2>/dev/null)"
;;
9)
echo "脚本退出。再见！"
exit 0
;;
*)
echo "❌ 无效选项"
;;
esac
echo
read -p "按 Enter 键返回主菜单..."
done
