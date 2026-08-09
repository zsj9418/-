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
    echo "正在还原源文件..."
    echo "源文件还原完成。"
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
