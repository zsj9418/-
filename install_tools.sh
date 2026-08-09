#!/bin/bash
LOG_FILE="/var/log/install_tools.log"
MAX_LOG_SIZE=$((1*1024*1024))
BACKUP_RECORD="/var/lib/sources_backup_path"
THIRD_PARTY_KEYWORDS="docker|nvidia|kubernetes|k8s|raspi|raspberry|armbian|mysql|mongodb|elastic|nodesource|microsoft|vscode|google|chrome|steam|epel|remi|zabbix|influx|grafana|gitlab|mariadb|proxmox|pve|orangepi|bananapi|yarn|ius|webtatic|saltstack|puppetlabs|jenkins|hashicorp|nginx|clickhouse|taobao|tencentcloud|huaweicloud"
if [ "$EUID" -ne 0 ]; then
    echo "❌ 请使用 root 或 sudo 权限运行此脚本。"
    exit 1
fi
exec > >(tee -a "$LOG_FILE") 2>&1
echo "============================================"
echo "脚本启动 - $(date '+%Y-%m-%d %H:%M:%S')"
echo "日志文件: $LOG_FILE"
echo "============================================"
if command -v apt &>/dev/null; then
    PKG_MANAGER="apt"
    UPDATE_CMD="apt update -qq && apt upgrade -y"
    INSTALL_CMD="apt install -y"
elif command -v dnf &>/dev/null; then
    PKG_MANAGER="dnf"
    UPDATE_CMD="dnf update -y"
    INSTALL_CMD="dnf install -y"
elif command -v yum &>/dev/null; then
    PKG_MANAGER="yum"
    UPDATE_CMD="yum update -y"
    INSTALL_CMD="yum install -y"
elif command -v apk &>/dev/null; then
    PKG_MANAGER="apk"
    UPDATE_CMD="apk update && apk upgrade"
    INSTALL_CMD="apk add --no-cache"
elif command -v pacman &>/dev/null; then
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
    if ! command -v "${2:-$1}" &>/dev/null; then
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
get_distro_info() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO_ID="${ID,,}"
        DISTRO_VERSION="$VERSION_ID"
        DISTRO_CODENAME="${VERSION_CODENAME:-}"
        DISTRO_LIKE="${ID_LIKE,,}"
    else
        DISTRO_ID=""
        DISTRO_VERSION=""
        DISTRO_CODENAME=""
        DISTRO_LIKE=""
    fi
}
is_third_party_source() {
    local filename="$1"
    local content="$2"
    local base
    base=$(basename "$filename" | tr '[:upper:]' '[:lower:]')
    if echo "$base" | grep -qEi "$THIRD_PARTY_KEYWORDS"; then
        return 0
    fi
    if echo "$content" | grep -qEi "$THIRD_PARTY_KEYWORDS"; then
        return 0
    fi
    return 1
}
backup_sources() {
    get_distro_info
    local backup_dir="/var/lib/sources_backup/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    echo "📦 备份目录: $backup_dir"
    case $PKG_MANAGER in
        apt)
            [ -f /etc/apt/sources.list ] && cp -v /etc/apt/sources.list "$backup_dir/sources.list"
            if [ -d /etc/apt/sources.list.d ]; then
                mkdir -p "$backup_dir/sources.list.d"
                cp -v /etc/apt/sources.list.d/*.list "$backup_dir/sources.list.d/" 2>/dev/null
                cp -v /etc/apt/sources.list.d/*.sources "$backup_dir/sources.list.d/" 2>/dev/null
            fi
            ;;
        yum|dnf)
            if [ -d /etc/yum.repos.d ]; then
                mkdir -p "$backup_dir/yum.repos.d"
                cp -v /etc/yum.repos.d/*.repo "$backup_dir/yum.repos.d/" 2>/dev/null
            fi
            ;;
        apk)
            [ -f /etc/apk/repositories ] && cp -v /etc/apk/repositories "$backup_dir/repositories"
            ;;
        pacman)
            [ -f /etc/pacman.d/mirrorlist ] && cp -v /etc/pacman.d/mirrorlist "$backup_dir/mirrorlist"
            [ -f /etc/pacman.conf ] && cp -v /etc/pacman.conf "$backup_dir/pacman.conf"
            ;;
    esac
    echo "$backup_dir" > "$BACKUP_RECORD"
    echo "✅ 源文件备份完成 → $backup_dir"
}
change_to_aliyun() {
    get_distro_info
    echo "🔍 检测到发行版: ${DISTRO_ID} ${DISTRO_VERSION} ${DISTRO_CODENAME}"
    case $PKG_MANAGER in
        apt)
            _aliyun_apt
            ;;
        yum|dnf)
            _aliyun_rpm
            ;;
        apk)
            _aliyun_apk
            ;;
        pacman)
            _aliyun_pacman
            ;;
        *)
            echo "❌ 当前包管理器暂不支持自动换源"
            return 1
            ;;
    esac
    echo "✅ 阿里云镜像源替换完成"
}
_aliyun_apt() {
    local codename="$DISTRO_CODENAME"
    local distro="$DISTRO_ID"
    if [ -z "$codename" ]; then
        codename=$(lsb_release -cs 2>/dev/null || echo "")
    fi
    if [ -z "$codename" ]; then
        echo "❌ 无法识别系统代号，跳过换源"
        return 1
    fi
    echo "📋 发行版代号: $codename"
    if [ -d /etc/apt/sources.list.d ]; then
        for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
            [ -f "$f" ] || continue
            local content
            content=$(cat "$f")
            if is_third_party_source "$f" "$content"; then
                echo "⚠️  跳过第三方源: $f"
            else
                echo "🗑️  移除官方源文件: $f"
                rm -f "$f"
            fi
        done
    fi
    if [ "$distro" = "ubuntu" ]; then
        if dpkg --print-architecture 2>/dev/null | grep -q "amd64\|i386"; then
            cat > /etc/apt/sources.list << EOF
deb https://mirrors.aliyun.com/ubuntu/ ${codename} main restricted universe multiverse
deb https://mirrors.aliyun.com/ubuntu/ ${codename}-security main restricted universe multiverse
deb https://mirrors.aliyun.com/ubuntu/ ${codename}-updates main restricted universe multiverse
deb https://mirrors.aliyun.com/ubuntu/ ${codename}-backports main restricted universe multiverse
EOF
        else
            cat > /etc/apt/sources.list << EOF
deb https://mirrors.aliyun.com/ubuntu-ports/ ${codename} main restricted universe multiverse
deb https://mirrors.aliyun.com/ubuntu-ports/ ${codename}-security main restricted universe multiverse
deb https://mirrors.aliyun.com/ubuntu-ports/ ${codename}-updates main restricted universe multiverse
deb https://mirrors.aliyun.com/ubuntu-ports/ ${codename}-backports main restricted universe multiverse
EOF
        fi
    elif [ "$distro" = "debian" ]; then
        cat > /etc/apt/sources.list << EOF
deb https://mirrors.aliyun.com/debian/ ${codename} main contrib non-free non-free-firmware
deb https://mirrors.aliyun.com/debian/ ${codename}-updates main contrib non-free non-free-firmware
deb https://mirrors.aliyun.com/debian-security/ ${codename}-security main contrib non-free non-free-firmware
EOF
    elif [ "$distro" = "raspbian" ]; then
        cat > /etc/apt/sources.list << EOF
deb https://mirrors.aliyun.com/raspbian/raspbian/ ${codename} main contrib non-free rpi
EOF
        if [ -f /etc/apt/sources.list.d/raspi.list ]; then
            echo "⚠️  检测到 Raspberry Pi 专属源 raspi.list，保留不动"
        fi
    else
        echo "⚠️  未识别的 apt 发行版 ($distro)，尝试通用 debian 格式"
        cat > /etc/apt/sources.list << EOF
deb https://mirrors.aliyun.com/debian/ ${codename} main contrib non-free
deb https://mirrors.aliyun.com/debian/ ${codename}-updates main contrib non-free
deb https://mirrors.aliyun.com/debian-security/ ${codename}-security main contrib non-free
EOF
    fi
    apt update -qq
}
_aliyun_rpm() {
    local distro="$DISTRO_ID"
    local version_major
    version_major=$(echo "$DISTRO_VERSION" | cut -d. -f1)
    echo "🗑️  分析并处理 /etc/yum.repos.d/ 中的 repo 文件..."
    for f in /etc/yum.repos.d/*.repo; do
        [ -f "$f" ] || continue
        local content
        content=$(cat "$f")
        if is_third_party_source "$f" "$content"; then
            echo "⚠️  跳过第三方源: $f"
        else
            echo "🗑️  移除官方源文件: $f"
            rm -f "$f"
        fi
    done
    if echo "$distro $DISTRO_LIKE" | grep -qi "centos"; then
        if [ "$version_major" -ge 8 ] 2>/dev/null; then
            cat > /etc/yum.repos.d/CentOS-aliyun.repo << EOF
[BaseOS]
name=CentOS-\$releasever - Base - mirrors.aliyun.com
baseurl=https://mirrors.aliyun.com/centos/\$releasever/BaseOS/\$basearch/os/
gpgcheck=1
enabled=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial
[AppStream]
name=CentOS-\$releasever - AppStream - mirrors.aliyun.com
baseurl=https://mirrors.aliyun.com/centos/\$releasever/AppStream/\$basearch/os/
gpgcheck=1
enabled=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial
[Extras]
name=CentOS-\$releasever - Extras - mirrors.aliyun.com
baseurl=https://mirrors.aliyun.com/centos/\$releasever/extras/\$basearch/os/
gpgcheck=1
enabled=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial
EOF
        else
            cat > /etc/yum.repos.d/CentOS-aliyun.repo << EOF
[base]
name=CentOS-\$releasever - Base - mirrors.aliyun.com
baseurl=https://mirrors.aliyun.com/centos/\$releasever/os/\$basearch/
gpgcheck=1
enabled=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
[updates]
name=CentOS-\$releasever - Updates - mirrors.aliyun.com
baseurl=https://mirrors.aliyun.com/centos/\$releasever/updates/\$basearch/
gpgcheck=1
enabled=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
[extras]
name=CentOS-\$releasever - Extras - mirrors.aliyun.com
baseurl=https://mirrors.aliyun.com/centos/\$releasever/extras/\$basearch/
gpgcheck=1
enabled=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
EOF
        fi
    elif echo "$distro" | grep -qi "rocky"; then
        cat > /etc/yum.repos.d/Rocky-aliyun.repo << EOF
[BaseOS]
name=Rocky Linux \$releasever - BaseOS - mirrors.aliyun.com
baseurl=https://mirrors.aliyun.com/rockylinux/\$releasever/BaseOS/\$basearch/os/
gpgcheck=1
enabled=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-${version_major}
[AppStream]
name=Rocky Linux \$releasever - AppStream - mirrors.aliyun.com
baseurl=https://mirrors.aliyun.com/rockylinux/\$releasever/AppStream/\$basearch/os/
gpgcheck=1
enabled=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-${version_major}
[Extras]
name=Rocky Linux \$releasever - Extras - mirrors.aliyun.com
baseurl=https://mirrors.aliyun.com/rockylinux/\$releasever/extras/\$basearch/os/
gpgcheck=1
enabled=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-${version_major}
EOF
    elif echo "$distro" | grep -qi "alma"; then
        cat > /etc/yum.repos.d/AlmaLinux-aliyun.repo << EOF
[BaseOS]
name=AlmaLinux \$releasever - BaseOS - mirrors.aliyun.com
baseurl=https://mirrors.aliyun.com/almalinux/\$releasever/BaseOS/\$basearch/os/
gpgcheck=1
enabled=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-AlmaLinux
[AppStream]
name=AlmaLinux \$releasever - AppStream - mirrors.aliyun.com
baseurl=https://mirrors.aliyun.com/almalinux/\$releasever/AppStream/\$basearch/os/
gpgcheck=1
enabled=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-AlmaLinux
[Extras]
name=AlmaLinux \$releasever - Extras - mirrors.aliyun.com
baseurl=https://mirrors.aliyun.com/almalinux/\$releasever/extras/\$basearch/os/
gpgcheck=1
enabled=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-AlmaLinux
EOF
    elif echo "$distro" | grep -qi "fedora"; then
        cat > /etc/yum.repos.d/Fedora-aliyun.repo << EOF
[fedora]
name=Fedora \$releasever - \$basearch - mirrors.aliyun.com
baseurl=https://mirrors.aliyun.com/fedora/releases/\$releasever/Everything/\$basearch/os/
gpgcheck=1
enabled=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-\$releasever-\$basearch
[updates]
name=Fedora \$releasever - \$basearch - Updates - mirrors.aliyun.com
baseurl=https://mirrors.aliyun.com/fedora/updates/\$releasever/Everything/\$basearch/
gpgcheck=1
enabled=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-\$releasever-\$basearch
EOF
    else
        echo "❌ 未识别的 RPM 发行版: $distro，跳过换源"
        return 1
    fi
    $PKG_MANAGER makecache -q 2>/dev/null || true
}
_aliyun_apk() {
    local ver
    ver=$(cat /etc/alpine-release 2>/dev/null | cut -d. -f1-2)
    if [ -z "$ver" ]; then
        echo "❌ 无法获取 Alpine 版本"
        return 1
    fi
    local new_repo="/etc/apk/repositories"
    local preserved_lines=""
    if [ -f "$new_repo" ]; then
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            if echo "$line" | grep -qEi "$THIRD_PARTY_KEYWORDS"; then
                echo "⚠️  保留第三方源行: $line"
                preserved_lines="${preserved_lines}${line}\n"
            fi
        done < "$new_repo"
    fi
    cat > "$new_repo" << EOF
https://mirrors.aliyun.com/alpine/v${ver}/main
https://mirrors.aliyun.com/alpine/v${ver}/community
EOF
    if [ -n "$preserved_lines" ]; then
        printf "$preserved_lines" >> "$new_repo"
    fi
    apk update -q
}
_aliyun_pacman() {
    local mirrorlist="/etc/pacman.d/mirrorlist"
    local preserved_lines=""
    if [ -f "$mirrorlist" ]; then
        while IFS= read -r line; do
            if echo "$line" | grep -qEi "$THIRD_PARTY_KEYWORDS"; then
                echo "⚠️  保留第三方镜像行: $line"
                preserved_lines="${preserved_lines}${line}\n"
            fi
        done < "$mirrorlist"
    fi
    cat > "$mirrorlist" << 'EOF'
Server = https://mirrors.aliyun.com/archlinux/$repo/os/$arch
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinux/$repo/os/$arch
Server = https://mirrors.ustc.edu.cn/archlinux/$repo/os/$arch
EOF
    if [ -n "$preserved_lines" ]; then
        printf "$preserved_lines" >> "$mirrorlist"
    fi
    pacman -Syy --noconfirm
}
update_system() {
    echo "正在更新系统软件包..."
    eval "$UPDATE_CMD" || handle_error "系统更新失败"
    echo "✅ 系统更新完成"
}
install_common_tools() {
    echo "正在安装常用工具..."
    local tools="sudo nano git vim curl wget htop tmux unzip tar jq lsof net-tools psmisc"
    for tool in $tools; do
        install_if_not_exists "$tool" "${tool%%-*}"
    done
    echo "✅ 常用工具安装完成"
}
perform_cleanup() {
    echo "正在清理系统缓存..."
    case $PKG_MANAGER in
        apt)    apt autoremove -y && apt clean ;;
        yum)    yum autoremove -y && yum clean all ;;
        dnf)    dnf autoremove -y && dnf clean all ;;
        apk)    apk cache clean ;;
        pacman)
            local orphans
            orphans=$(pacman -Qdtq 2>/dev/null)
            if [ -n "$orphans" ]; then
                pacman -Rns --noconfirm $orphans 2>/dev/null || true
            fi
            pacman -Scc --noconfirm
            ;;
    esac
    manage_log_file
    echo "✅ 清理完成"
}
restore_sources() {
    if [ ! -f "$BACKUP_RECORD" ]; then
        echo "❌ 未找到备份记录，请先执行选项 1 进行备份"
        return 1
    fi
    local backup_dir
    backup_dir=$(cat "$BACKUP_RECORD")
    if [ ! -d "$backup_dir" ]; then
        echo "❌ 备份目录不存在: $backup_dir"
        return 1
    fi
    echo "📦 正在从备份还原: $backup_dir"
    case $PKG_MANAGER in
        apt)
            [ -f "$backup_dir/sources.list" ] && cp -v "$backup_dir/sources.list" /etc/apt/sources.list
            if [ -d "$backup_dir/sources.list.d" ]; then
                cp -v "$backup_dir/sources.list.d/"* /etc/apt/sources.list.d/ 2>/dev/null
            fi
            apt update -qq
            ;;
        yum|dnf)
            if [ -d "$backup_dir/yum.repos.d" ]; then
                cp -v "$backup_dir/yum.repos.d/"*.repo /etc/yum.repos.d/ 2>/dev/null
            fi
            $PKG_MANAGER makecache -q 2>/dev/null || true
            ;;
        apk)
            [ -f "$backup_dir/repositories" ] && cp -v "$backup_dir/repositories" /etc/apk/repositories
            apk update -q
            ;;
        pacman)
            [ -f "$backup_dir/mirrorlist" ] && cp -v "$backup_dir/mirrorlist" /etc/pacman.d/mirrorlist
            [ -f "$backup_dir/pacman.conf" ] && cp -v "$backup_dir/pacman.conf" /etc/pacman.conf
            pacman -Syy --noconfirm
            ;;
    esac
    echo "✅ 源文件还原完成"
}
workspace_ensure_tmux() {
    if ! command -v tmux &>/dev/null; then
        echo "⚠️  tmux 未安装，正在自动安装..."
        $INSTALL_CMD tmux || { echo "❌ tmux 安装失败"; sleep 2; return 1; }
        echo "✅ tmux 安装完成"
    fi
    return 0
}
enter_numbered_workspace() {
    local num=$1
    local session_name="workspace-${num}"
    if [ -n "$TMUX" ]; then
        tmux new-session -d -s "$session_name" 2>/dev/null
        tmux switch-client -t "$session_name"
    else
        tmux new-session -A -s "$session_name"
    fi
}
ssh_persistent_mode() {
    local session_name="ssh-persistent"
    echo ""
    echo "🌟 SSH常驻模式 —— 断开 SSH 后，该会话中的任务仍继续运行"
    echo "   提示: 使用 Ctrl+b 再按 d 可安全退出（不会终止任务）"
    sleep 1
    if [ -n "$TMUX" ]; then
        tmux new-session -d -s "$session_name" 2>/dev/null
        tmux switch-client -t "$session_name"
    else
        tmux new-session -A -s "$session_name"
    fi
}
create_or_enter_workspace() {
    echo ""
    echo "------------------------"
    echo "当前工作区列表:"
    echo "------------------------"
    tmux ls 2>/dev/null || echo "  暂无运行中的工作区"
    echo "------------------------"
    read -p "请输入工作区名称（数字 1-10 或自定义名称）: " ws_input
    if [ -z "$ws_input" ]; then
        echo "❌ 名称不能为空"
        sleep 1
        return
    fi
    local session_name display_name
    if [[ "$ws_input" =~ ^([1-9]|10)$ ]]; then
        session_name="workspace-${ws_input}"
        display_name="${ws_input}号工作区"
    else
        session_name="$ws_input"
        display_name="$ws_input"
    fi
    if tmux has-session -t "$session_name" 2>/dev/null; then
        echo "✅ 工作区已存在，正在进入: $display_name"
    else
        echo "✅ 正在创建新工作区: $display_name"
    fi
    sleep 1
    if [ -n "$TMUX" ]; then
        tmux new-session -d -s "$session_name" 2>/dev/null
        tmux switch-client -t "$session_name"
    else
        tmux new-session -A -s "$session_name"
    fi
}
inject_command_to_workspace() {
    echo ""
    echo "------------------------"
    echo "当前工作区列表:"
    echo "------------------------"
    tmux ls 2>/dev/null || echo "  暂无运行中的工作区"
    echo "------------------------"
    if ! tmux ls &>/dev/null; then
        echo "❌ 没有可用的工作区，请先创建"
        sleep 2
        return
    fi
    read -p "请输入目标工作区（数字 1-10 或工作区名称）: " ws_input
    if [ -z "$ws_input" ]; then
        echo "❌ 名称不能为空"
        sleep 1
        return
    fi
    local session_name display_name
    if [[ "$ws_input" =~ ^([1-9]|10)$ ]]; then
        session_name="workspace-${ws_input}"
        display_name="${ws_input}号工作区"
    else
        session_name="$ws_input"
        display_name="$ws_input"
    fi
    if ! tmux has-session -t "$session_name" 2>/dev/null; then
        echo "❌ 工作区「$display_name」不存在，请先创建"
        sleep 2
        return
    fi
    echo ""
    read -p "请输入要注入到后台的命令: " inject_cmd
    if [ -z "$inject_cmd" ]; then
        echo "❌ 命令不能为空"
        sleep 1
        return
    fi
    tmux send-keys -t "$session_name" "$inject_cmd" Enter
    echo ""
    echo "✅ 命令已注入到工作区「$display_name」"
    echo "   命令: $inject_cmd"
    echo "   可进入对应工作区查看执行状态"
    sleep 2
}
delete_workspace() {
    echo ""
    echo "------------------------"
    echo "当前工作区列表:"
    echo "------------------------"
    tmux ls 2>/dev/null || echo "  暂无运行中的工作区"
    echo "------------------------"
    if ! tmux ls &>/dev/null; then
        echo "❌ 没有可删除的工作区"
        sleep 2
        return
    fi
    read -p "请输入要删除的工作区（数字 1-10 或名称，输入 all 删除全部）: " ws_input
    if [ -z "$ws_input" ]; then
        echo "❌ 名称不能为空"
        sleep 1
        return
    fi
    if [ "$ws_input" = "all" ]; then
        read -p "⚠️  确认删除所有工作区？(y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            tmux kill-server 2>/dev/null
            echo "✅ 所有工作区已删除"
        else
            echo "操作已取消"
        fi
        sleep 1
        return
    fi
    local session_name display_name
    if [[ "$ws_input" =~ ^([1-9]|10)$ ]]; then
        session_name="workspace-${ws_input}"
        display_name="${ws_input}号工作区"
    else
        session_name="$ws_input"
        display_name="$ws_input"
    fi
    if tmux has-session -t "$session_name" 2>/dev/null; then
        read -p "⚠️  确认删除工作区「$display_name」？(y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            tmux kill-session -t "$session_name"
            echo "✅ 工作区「$display_name」已删除"
        else
            echo "操作已取消"
        fi
    else
        echo "❌ 工作区「$display_name」不存在"
    fi
    sleep 1
}
show_workspace_menu() {
    workspace_ensure_tmux || return 1
    while true; do
        clear
        echo "=============================================="
        echo "              后台工作区管理"
        echo "=============================================="
        echo "  系统将为你提供可以后台常驻运行的工作区，你可以用来执行长时间的任务"
        echo "  即使你断开SSH，工作区中的任务也不会中断，后台常驻任务。"
        echo "  提示: 进入工作区后使用 Ctrl+b 再单独按 d，退出工作区！"
        echo "------------------------"
        echo "当前已存在的工作区列表"
        echo "------------------------"
        local raw_sessions
        raw_sessions=$(tmux ls 2>/dev/null)
        if [ -z "$raw_sessions" ]; then
            echo "  no server running on /tmp/tmux-$(id -u)/default"
        else
            echo "$raw_sessions" | sed 's/^/  /'
        fi
        echo "------------------------"
        for i in $(seq 1 10); do
            local sname="workspace-${i}"
            if tmux has-session -t "$sname" 2>/dev/null; then
                printf "%-4s %s号工作区  \033[32m[运行中]\033[0m\n" "${i}." "$i"
            else
                printf "%-4s %s号工作区\n" "${i}." "$i"
            fi
        done
        echo "------------------------"
        if tmux has-session -t "ssh-persistent" 2>/dev/null; then
            printf "21.  SSH常驻模式 ★  \033[32m[运行中]\033[0m\n"
        else
            echo "21.  SSH常驻模式 ★"
        fi
        echo "22.  创建/进入工作区"
        echo "23.  注入命令到后台工作区"
        echo "24.  删除指定工作区"
        echo "------------------------"
        echo "0.   返回主菜单"
        echo "------------------------"
        read -p "请输入你的选择: " WS_CHOICE
        case $WS_CHOICE in
            1|2|3|4|5|6|7|8|9|10)
                enter_numbered_workspace "$WS_CHOICE"
                ;;
            21)
                ssh_persistent_mode
                ;;
            22)
                create_or_enter_workspace
                ;;
            23)
                inject_command_to_workspace
                ;;
            24)
                delete_workspace
                ;;
            0)
                return 0
                ;;
            *)
                echo "❌ 无效选项，请输入 0-10 或 21-24"
                sleep 1
                ;;
        esac
    done
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
    local ws_count ws_label
    ws_count=$(tmux ls 2>/dev/null | wc -l)
    if [ "$ws_count" -gt 0 ] 2>/dev/null; then
        ws_label="9.  后台工作区  [${ws_count} 个运行中]"
    else
        ws_label="9.  后台工作区"
    fi
    echo "1.  更换为阿里云镜像源"
    echo "2.  更新系统软件包"
    echo "3.  安装常用工具"
    echo "4.  配置自动时间同步（推荐）"
    echo "5.  一键初始化（推荐）"
    echo "6.  执行系统清理"
    echo "7.  还原源文件备份"
    echo "8.  查看当前时间状态"
    echo "$ws_label"
    echo "10. 退出脚本"
    echo "=============================================="
    read -p "请输入选项 [1-10]: " CHOICE
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
            backup_sources
            change_to_aliyun
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
            show_workspace_menu
            ;;
        10)
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
