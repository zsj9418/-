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
find_main_sshd_config() {
    local f
    for f in /etc/ssh/sshd_config /etc/openssh/sshd_config; do
        [ -f "$f" ] && { echo "$f"; return 0; }
    done
    return 1
}
find_sshd_binary() {
    if command -v sshd >/dev/null 2>&1; then
        command -v sshd
        return 0
    fi
    local f
    for f in /usr/sbin/sshd /usr/lib/ssh/sshd /usr/local/sbin/sshd; do
        [ -x "$f" ] && { echo "$f"; return 0; }
    done
    return 1
}
find_sshd_include_dir() {
    local main_conf="$1"
    local dir
    dir=$(awk '/^[[:space:]]*Include[[:space:]]+/ {for(i=2;i<=NF;i++){if($i ~ /sshd_config\.d\/\*\.conf$/){gsub(/\/\*\.conf$/,"",$i); print $i; exit}}}' "$main_conf")
    [ -n "$dir" ] || return 1
    case "$dir" in
        /*) echo "$dir" ;;
        *) echo "$(dirname "$main_conf")/$dir" ;;
    esac
}
build_sshd_block() {
    case "$1" in
        full)
            cat << 'EOF'
PasswordAuthentication yes
KbdInteractiveAuthentication yes
ChallengeResponseAuthentication yes
AuthenticationMethods any
PermitRootLogin yes
PubkeyAuthentication yes
PermitEmptyPasswords no
EOF
            ;;
        kbd)
            cat << 'EOF'
PasswordAuthentication yes
KbdInteractiveAuthentication yes
PermitRootLogin yes
PubkeyAuthentication yes
PermitEmptyPasswords no
EOF
            ;;
        challenge)
            cat << 'EOF'
PasswordAuthentication yes
ChallengeResponseAuthentication yes
PermitRootLogin yes
PubkeyAuthentication yes
PermitEmptyPasswords no
EOF
            ;;
        basic)
            cat << 'EOF'
PasswordAuthentication yes
PermitRootLogin yes
PubkeyAuthentication yes
PermitEmptyPasswords no
EOF
            ;;
    esac
}
write_sshd_main_config() {
    local main_conf="$1"
    local mode="$2"
    local tmp_file block_file
    tmp_file=$(mktemp) || return 1
    block_file=$(mktemp) || { rm -f "$tmp_file"; return 1; }
    build_sshd_block "$mode" > "$block_file"
    awk -v block="$block_file" '
BEGIN{added=0; n=0; while((getline line < block) > 0){lines[++n]=line} close(block)}
/^[[:space:]]*#/ {print; next}
/^[[:space:]]*(PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication|AuthenticationMethods|PermitRootLogin|PubkeyAuthentication|PermitEmptyPasswords)[[:space:]]+/ {next}
/^[[:space:]]*Match[[:space:]]/ && added==0 {for(i=1;i<=n;i++) print lines[i]; added=1}
{print}
END{if(added==0){for(i=1;i<=n;i++) print lines[i]}}' "$main_conf" > "$tmp_file" || { rm -f "$tmp_file" "$block_file"; return 1; }
    cat "$tmp_file" > "$main_conf"
    rm -f "$tmp_file" "$block_file"
    return 0
}
configure_openssh_password_login() {
    local main_conf="$1"
    local backup="${main_conf}.bak.$(date +%Y%m%d_%H%M%S)"
    local include_dir sshd_bin mode
    [ -f "$main_conf" ] || return 1
    cp -a "$main_conf" "$backup" || return 1
    sshd_bin=$(find_sshd_binary 2>/dev/null || true)
    for mode in full kbd challenge basic; do
        cp -a "$backup" "$main_conf"
        include_dir=$(find_sshd_include_dir "$main_conf" 2>/dev/null || true)
        [ -n "$include_dir" ] && rm -f "$include_dir/zzzz-password-login.conf" 2>/dev/null
        write_sshd_main_config "$main_conf" "$mode" || continue
        include_dir=$(find_sshd_include_dir "$main_conf" 2>/dev/null || true)
        if [ -n "$include_dir" ]; then
            mkdir -p "$include_dir"
            build_sshd_block "$mode" > "$include_dir/zzzz-password-login.conf"
        fi
        if [ -z "$sshd_bin" ] || "$sshd_bin" -t -f "$main_conf" >/dev/null 2>&1; then
            return 0
        fi
    done
    cp -a "$backup" "$main_conf"
    include_dir=$(find_sshd_include_dir "$main_conf" 2>/dev/null || true)
    [ -n "$include_dir" ] && rm -f "$include_dir/zzzz-password-login.conf" 2>/dev/null
    echo "❌ SSH配置校验失败，已恢复原配置"
    return 1
}
configure_dropbear_password_login() {
    local found=0
    local ts
    ts=$(date +%Y%m%d_%H%M%S)
    local f var current cleaned
    for f in /etc/default/dropbear /etc/conf.d/dropbear /etc/sysconfig/dropbear; do
        [ -f "$f" ] || continue
        found=1
        cp -a "$f" "$f.bak.$ts" 2>/dev/null || true
        sed -i -E 's/^[[:space:]]*NO_START[[:space:]]*=.*/NO_START=0/' "$f" 2>/dev/null || true
        for var in DROPBEAR_EXTRA_ARGS DROPBEAR_ARGS DROPBEAR_OPTS; do
            if grep -Eq "^[[:space:]]*$var[[:space:]]*=" "$f"; then
                current=$(awk -v v="$var" '$0 ~ "^[[:space:]]*"v"[[:space:]]*=" {line=$0; sub("^[[:space:]]*"v"[[:space:]]*=[[:space:]]*","",line); gsub(/^[\"\047]|[\"\047][[:space:]]*$/,"",line); print line; exit}' "$f")
                cleaned=$(printf '%s\n' "$current" | sed -E 's/(^|[[:space:]])-s([[:space:]]|$)/ /g;s/(^|[[:space:]])-w([[:space:]]|$)/ /g;s/[[:space:]]+/ /g;s/^ //;s/ $//')
                sed -i -E "s|^[[:space:]]*$var[[:space:]]*=.*|$var=\"$cleaned\"|" "$f"
            fi
        done
    done
    if [ "$found" -eq 0 ]; then
        mkdir -p /etc/default 2>/dev/null || true
        cat > /etc/default/dropbear << 'EOF'
NO_START=0
DROPBEAR_EXTRA_ARGS=""
EOF
        found=1
    fi
    [ "$found" -eq 1 ]
}
enable_and_restart_service() {
    local svc
    for svc in "$@"; do
        if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
            systemctl enable "$svc" >/dev/null 2>&1 || true
            if systemctl restart "$svc" >/dev/null 2>&1 || systemctl start "$svc" >/dev/null 2>&1; then
                return 0
            fi
        fi
        if command -v service >/dev/null 2>&1; then
            if service "$svc" restart >/dev/null 2>&1 || service "$svc" start >/dev/null 2>&1; then
                return 0
            fi
        fi
        if command -v rc-service >/dev/null 2>&1; then
            rc-update add "$svc" default >/dev/null 2>&1 || true
            if rc-service "$svc" restart >/dev/null 2>&1 || rc-service "$svc" start >/dev/null 2>&1; then
                return 0
            fi
        fi
        if [ -x "/etc/init.d/$svc" ]; then
            if "/etc/init.d/$svc" restart >/dev/null 2>&1 || "/etc/init.d/$svc" start >/dev/null 2>&1; then
                return 0
            fi
        fi
    done
    return 1
}
ensure_user_shell() {
    local user="$1"
    local current_shell shell_path
    current_shell=$(getent passwd "$user" 2>/dev/null | cut -d: -f7)
    [ -n "$current_shell" ] || current_shell=$(grep "^$user:" /etc/passwd 2>/dev/null | cut -d: -f7)
    case "$current_shell" in
        */nologin|*/false|"")
            for shell_path in /bin/bash /usr/bin/bash /bin/sh /usr/bin/sh /bin/ash /usr/bin/ash; do
                [ -x "$shell_path" ] || continue
                chsh -s "$shell_path" "$user" 2>/dev/null || usermod -s "$shell_path" "$user" 2>/dev/null || true
                break
            done
            ;;
    esac
}
unlock_user_account() {
    local user="$1"
    passwd -u "$user" 2>/dev/null || usermod -U "$user" 2>/dev/null || true
}
get_system_uid_min() {
    local uid_min=1000
    if [ -f /etc/login.defs ]; then
        local val
        val=$(awk '/^[[:space:]]*UID_MIN[[:space:]]/ {print $2}' /etc/login.defs 2>/dev/null)
        [ -n "$val" ] && uid_min="$val"
    fi
    echo "$uid_min"
}
is_human_user() {
    local uname="$1"
    local uid="$2"
    local ushell="$3"
    local homedir="$4"
    local uid_min="$5"
    [ "$uid" -eq 0 ] && return 1
    [ "$uid" -lt "$uid_min" ] 2>/dev/null && return 1
    [ "$uid" -ge 60000 ] 2>/dev/null && return 1
    case "$ushell" in
        */nologin|*/false|/bin/sync|/usr/bin/sync|"") return 1 ;;
    esac
    case "$homedir" in
        /home/*|/root) ;;
        *) return 1 ;;
    esac
    case "$uname" in
        nobody|nfsnobody) return 1 ;;
    esac
    local pw_field
    if [ -f /etc/shadow ]; then
        pw_field=$(awk -F: -v u="$uname" '$1==u{print $2;exit}' /etc/shadow 2>/dev/null)
        case "$pw_field" in
            "!"|"!!"|"*"|"!!"*) return 1 ;;
        esac
    fi
    return 0
}
get_real_users() {
    local uid_min
    uid_min=$(get_system_uid_min)
    local users=()
    local uname uid ushell homedir
    while IFS=: read -r uname _ uid _ _ homedir ushell; do
        [ -z "$uname" ] && continue
        [ "$uname" = "root" ] && continue
        is_human_user "$uname" "$uid" "$ushell" "$homedir" "$uid_min" || continue
        users+=("$uname")
    done < /etc/passwd
    printf '%s\n' "${users[@]}"
}
get_user_status() {
    local uname="$1"
    local ushell lock_status pw_status
    ushell=$(getent passwd "$uname" 2>/dev/null | cut -d: -f7)
    [ -z "$ushell" ] && ushell=$(awk -F: -v u="$uname" '$1==u{print $7;exit}' /etc/passwd 2>/dev/null)
    lock_status=""
    if [ -f /etc/shadow ]; then
        pw_status=$(awk -F: -v u="$uname" '$1==u{print $2;exit}' /etc/shadow 2>/dev/null)
        case "$pw_status" in
            ""|"!"|"!!"|"*"|"!!"*) lock_status="未设密码" ;;
        esac
    fi
    if [ -z "$lock_status" ] && command -v passwd >/dev/null 2>&1; then
        if passwd -S "$uname" 2>/dev/null | awk '{print $2}' | grep -qiE "^(L|LK|locked)$"; then
            lock_status="已锁定"
        fi
    fi
    case "$ushell" in
        */nologin|*/false) [ -z "$lock_status" ] && lock_status="Shell不可登录" ;;
    esac
    echo "${ushell:-未知}|${lock_status}"
}
select_user_for_password() {
    local real_users=()
    local line
    while IFS= read -r line; do
        [ -n "$line" ] && real_users+=("$line")
    done < <(get_real_users)
    while true; do
        echo ""
        echo "=============================================="
        echo "       设置密码登陆模式 - 选择用户"
        echo "=============================================="
        echo "可用于SSH登录的用户列表："
        echo "----------------------------------------------"
        local idx=1
        local u status_line display_shell display_status status_tag
        local root_info root_shell root_status
        root_info=$(get_user_status "root")
        root_shell=$(echo "$root_info" | cut -d'|' -f1)
        root_status=$(echo "$root_info" | cut -d'|' -f2)
        status_tag=""
        [ -n "$root_status" ] && status_tag=" [$root_status]"
        printf "  %-4s %-20s Shell: %-18s ★ 超级用户%s\n" "1." "root" "$root_shell" "$status_tag"
        idx=2
        for u in "${real_users[@]}"; do
            status_line=$(get_user_status "$u")
            display_shell=$(echo "$status_line" | cut -d'|' -f1)
            display_status=$(echo "$status_line" | cut -d'|' -f2)
            status_tag=""
            [ -n "$display_status" ] && status_tag=" [$display_status]"
            printf "  %-4s %-20s Shell: %-18s%s\n" "${idx}." "$u" "$display_shell" "$status_tag"
            idx=$((idx + 1))
        done
        local total_users=$((1 + ${#real_users[@]}))
        if [ "$total_users" -eq 1 ]; then
            echo "  （未检测到其他可登录用户）"
        fi
        echo "----------------------------------------------"
        echo "  0.   返回上一级菜单"
        echo "----------------------------------------------"
        read -p "请输入编号选择用户（默认1=root）: " user_choice
        [ -z "$user_choice" ] && user_choice=1
        if [ "$user_choice" = "0" ]; then
            return 1
        fi
        if [[ "$user_choice" =~ ^[0-9]+$ ]] && [ "$user_choice" -ge 1 ] && [ "$user_choice" -le "$total_users" ]; then
            if [ "$user_choice" -eq 1 ]; then
                SELECTED_USER="root"
            else
                SELECTED_USER="${real_users[$((user_choice - 2))]}"
            fi
            return 0
        fi
        if [ "$user_choice" = "root" ]; then
            SELECTED_USER="root"
            return 0
        fi
        local found=0
        for u in "${real_users[@]}"; do
            if [ "$user_choice" = "$u" ]; then
                SELECTED_USER="$u"
                found=1
                break
            fi
        done
        if [ "$found" -eq 1 ]; then
            return 0
        fi
        echo ""
        echo "❌ 输入无效，请输入列表中的编号或用户名"
        sleep 1
    done
}
setup_password_login_mode() {
    SELECTED_USER=""
    select_user_for_password || return 0
    local target_user="$SELECTED_USER"
    echo ""
    echo "✅ 已选择用户: $target_user"
    ensure_user_shell "$target_user"
    local ssh_conf sshd_bin mode
    ssh_conf=$(find_main_sshd_config 2>/dev/null || true)
    sshd_bin=$(find_sshd_binary 2>/dev/null || true)
    if [ -n "$ssh_conf" ] || [ -n "$sshd_bin" ]; then
        mode="openssh"
    elif command -v dropbear >/dev/null 2>&1 || [ -f /etc/default/dropbear ] || [ -f /etc/conf.d/dropbear ] || [ -f /etc/sysconfig/dropbear ] || [ -x /etc/init.d/dropbear ]; then
        mode="dropbear"
    else
        echo "未检测到SSH服务，正在安装OpenSSH..."
        case $PKG_MANAGER in
            apt) $INSTALL_CMD openssh-server ;;
            yum|dnf) $INSTALL_CMD openssh-server ;;
            apk) $INSTALL_CMD openssh ;;
            pacman) $INSTALL_CMD openssh ;;
        esac || handle_error "安装OpenSSH失败"
        ssh_conf=$(find_main_sshd_config 2>/dev/null || true)
        sshd_bin=$(find_sshd_binary 2>/dev/null || true)
        mode="openssh"
    fi
    if [ "$mode" = "openssh" ]; then
        [ -n "$ssh_conf" ] || ssh_conf=$(find_main_sshd_config 2>/dev/null || true)
        if [ -z "$ssh_conf" ]; then
            echo "❌ 未找到sshd配置文件"
            return 1
        fi
        configure_openssh_password_login "$ssh_conf" || return 1
        command -v ssh-keygen >/dev/null 2>&1 && ssh-keygen -A >/dev/null 2>&1 || true
        enable_and_restart_service sshd ssh || echo "⚠️ SSH服务重启失败，请手动检查"
    else
        configure_dropbear_password_login || { echo "❌ Dropbear配置失败"; return 1; }
        enable_and_restart_service dropbear || echo "⚠️ Dropbear服务重启失败，请手动检查"
    fi
    echo ""
    echo "请为用户 $target_user 设置新密码："
    passwd "$target_user" || { echo "❌ 密码设置失败"; return 1; }
    unlock_user_account "$target_user"
    ensure_user_shell "$target_user"
    echo ""
    echo "✅ 已启用密码登录模式"
    echo "✅ 用户 $target_user 密码已更新"
    echo "✅ 如使用SSH登录，请使用用户名 $target_user 进行密码登录"
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
    echo "10. 用户密码登录模式"
    echo "11. 退出脚本"
    echo "=============================================="
    read -p "请输入选项 [1-11]: " CHOICE
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
            setup_password_login_mode
            ;;
        11)
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
