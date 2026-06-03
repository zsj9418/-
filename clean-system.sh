#!/bin/bash
set -euo pipefail

# 标记是否为静默/定时任务模式
IS_CRON=0

# 带颜色输出
red() { echo -e "\033[31m$@\033[0m"; }
green() { echo -e "\033[32m$@\033[0m"; }
yellow() { echo -e "\033[33m$@\033[0m"; }
cyan() { echo -e "\033[36m$@\033[0m"; }

# 日志文件路径
LOG_FILE="/var/log/clean-system.log"

# 初始化日志
init_log() {
    if [[ ! -w "$(dirname "$LOG_FILE")" ]]; then
        LOG_FILE="/tmp/clean-system.log"
    fi
    touch "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
    [[ $IS_CRON -eq 0 ]] && green "日志文件: $LOG_FILE"
}

# 检测系统类型和架构
detect_system_and_architecture() {
    local os=""
    local arch=""
    if grep -qiE "ubuntu|debian" /etc/os-release; then
        os="debian"
    elif grep -qi "centos" /etc/os-release; then
        os="centos"
    else
        red "不支持的系统类型"
        exit 1
    fi

    case "$(uname -m)" in
        x86_64|amd64) arch="amd64" ;;
        aarch64) arch="arm64" ;;
        armv7l|armhf) arch="armv7" ;;
        *) red "不支持的系统架构: $(uname -m)"; exit 1 ;;
    esac

    echo "$os $arch"
}

# 检查并安装依赖
install_dependencies() {
    local system_info
    system_info=$(detect_system_and_architecture)
    local os_type=$(echo "$system_info" | awk '{print $1}')

    if ! command -v crontab &>/dev/null || ! command -v sudo &>/dev/null; then
        yellow "安装缺失的依赖软件..."
        case "$os_type" in
            debian)
                sudo apt update && sudo apt install -y cron sudo
                ;;
            centos)
                sudo yum install -y cronie sudo
                ;;
        esac
        green "依赖软件安装完成！"
    fi
}

# 智能交互式清理包管理器
smart_clean_managers() {
    local detected=()
    command -v apt &>/dev/null && detected+=("apt (系统包)")
    command -v yum &>/dev/null && detected+=("yum (系统包)")
    command -v npm &>/dev/null && detected+=("npm (Node.js环境)")
    command -v pip &>/dev/null && detected+=("pip (Python环境)")
    command -v uv &>/dev/null && detected+=("uv (Python高效环境)")
    command -v docker &>/dev/null && detected+=("docker (容器环境)")

    if [ ${#detected[@]} -eq 0 ]; then
        return
    fi

    local clean_all=1
    local do_apt=0 do_yum=0 do_npm=0 do_pip=0 do_uv=0 do_docker=0

    # 如果是定时任务，默认全部清理；如果是手动执行，则询问用户
    if [[ $IS_CRON -eq 0 ]]; then
        echo ""
        cyan "================ 环境与包管理器检测 ================"
        yellow "系统检测到以下管理器产生了缓存、旧镜像或无用残余依赖："
        for item in "${detected[@]}"; do
            echo "  - $item"
        done
        echo ""
        
        while true; do
            read -p "请选择操作 [1: 一键深度清理所有(推荐) | 2: 自定义选择清理 | 3: 跳过]: " mode
            case $mode in
                1) 
                    do_apt=1; do_yum=1; do_npm=1; do_pip=1; do_uv=1; do_docker=1
                    break ;;
                2)
                    clean_all=0
                    cyan "请依次确认是否清理（y/n，默认跳过）："
                    [[ "${detected[*]}" =~ "apt" ]] && { read -p " -> 清理 apt (无用依赖/缓存/旧配置)? [y/N]: " ans; [[ "$ans" =~ ^[Yy]$ ]] && do_apt=1; }
                    [[ "${detected[*]}" =~ "yum" ]] && { read -p " -> 清理 yum (无用依赖/缓存)? [y/N]: " ans; [[ "$ans" =~ ^[Yy]$ ]] && do_yum=1; }
                    [[ "${detected[*]}" =~ "npm" ]] && { read -p " -> 清理 npm (全局下载缓存)? [y/N]: " ans; [[ "$ans" =~ ^[Yy]$ ]] && do_npm=1; }
                    [[ "${detected[*]}" =~ "pip" ]] && { read -p " -> 清理 pip (下载缓存)? [y/N]: " ans; [[ "$ans" =~ ^[Yy]$ ]] && do_pip=1; }
                    [[ "${detected[*]}" =~ "uv" ]] && { read -p " -> 清理 uv (下载缓存)? [y/N]: " ans; [[ "$ans" =~ ^[Yy]$ ]] && do_uv=1; }
                    [[ "${detected[*]}" =~ "docker" ]] && { read -p " -> 清理 docker (未使用的镜像/悬挂容器)? [y/N]: " ans; [[ "$ans" =~ ^[Yy]$ ]] && do_docker=1; }
                    break ;;
                3)
                    yellow "已跳过包管理器清理。"
                    return ;;
                *) red "无效输入，请输入 1, 2 或 3。" ;;
            esac
        done
        cyan "===================================================="
    else
        # Cron静默模式下默认清理所有
        do_apt=1; do_yum=1; do_npm=1; do_pip=1; do_uv=1; do_docker=1
    fi

    # 开始执行用户选择的清理任务
    export DEBIAN_FRONTEND=noninteractive

    if [[ $do_apt -eq 1 && "${detected[*]}" =~ "apt" ]]; then
        yellow ">> 执行 APT 清理..."
        sudo apt-get clean || true
        sudo apt-get autoremove -y --purge || true
        dpkg -l | grep '^rc' | awk '{print $2}' | sudo xargs -r dpkg --purge || true
    fi

    if [[ $do_yum -eq 1 && "${detected[*]}" =~ "yum" ]]; then
        yellow ">> 执行 YUM 清理..."
        sudo yum clean all || true
        sudo yum autoremove -y || true
    fi

    if [[ $do_npm -eq 1 && "${detected[*]}" =~ "npm" ]]; then
        yellow ">> 执行 NPM 缓存清理..."
        sudo npm cache clean --force || true
        npm cache clean --force 2>/dev/null || true
    fi

    if [[ $do_pip -eq 1 && "${detected[*]}" =~ "pip" ]]; then
        yellow ">> 执行 PIP 缓存清理..."
        pip cache purge || true
    fi

    if [[ $do_uv -eq 1 && "${detected[*]}" =~ "uv" ]]; then
        yellow ">> 执行 UV 缓存清理..."
        uv cache clean || true
    fi

    if [[ $do_docker -eq 1 && "${detected[*]}" =~ "docker" ]]; then
        yellow ">> 执行 Docker 深度清理 (清理未使用的容器、网络、镜像)..."
        docker system prune -af --volumes || true
    fi
}

# 清理系统常规垃圾
clean_system() {
    local space_before
    space_before=$(df -h / | awk 'NR==2 {print $4}')
    
    yellow "开始清理系统常规垃圾..."

    # 清理临时文件
    yellow "清理 /tmp 和 /var/tmp..."
    find /tmp -type f -atime +1 -delete || true
    find /var/tmp -type f -atime +1 -delete || true

    # 清理旧日志
    if command -v journalctl &>/dev/null; then
        yellow "清理系统日志(journal)..."
        journalctl --vacuum-time=2d || true
    fi
    find /var/log -type f -name "*.log" -mtime +2 -delete || true
    find /var/log -type f -name "*.gz" -mtime +2 -delete || true 

    # 清理用户缓存
    yellow "清理普通用户及 root 用户的系统基础 .cache 目录..."
    find /home -type d -name ".cache" -exec rm -rf {} + || true
    find /root -type d -name ".cache" -exec rm -rf {} + || true

    # 调用智能包管理器清理
    smart_clean_managers

    # 统计磁盘空间使用情况
    local space_after
    space_after=$(df -h / | awk 'NR==2 {print $4}')
    
    echo ""
    green "==================== 清理完成 ===================="
    green "清理前根目录可用空间: $space_before"
    green "清理后根目录可用空间: $space_after"
    green "=================================================="
}

# 设置定时任务
setup_cron() {
    install_dependencies
    yellow "设置每两天自动运行一次..."

    local script_path
    script_path="$(realpath "$0")"
    local cron_job="0 0 */2 * * /bin/bash $script_path --cron >>/tmp/clean-cron.log 2>&1"

    if [[ $EUID -ne 0 ]]; then
        yellow "检测到非root用户，定时任务将写入root账户crontab。"
        tmpfile=$(mktemp)
        sudo crontab -l 2>/dev/null | grep -v "$script_path" > "$tmpfile" || true
        echo "$cron_job" >> "$tmpfile"
        sudo crontab "$tmpfile"
        rm -f "$tmpfile"
        green "定时任务已添加到 root 用户的 crontab："
        sudo crontab -l
    else
        tmpfile=$(mktemp)
        crontab -l 2>/dev/null | grep -v "$script_path" > "$tmpfile" || true
        echo "$cron_job" >> "$tmpfile"
        crontab "$tmpfile"
        rm -f "$tmpfile"
        green "定时任务已添加到 root 用户的 crontab："
        crontab -l
    fi
}

# 创建快捷方式
create_symlink() {
    while true; do
        yellow "请输入您希望的快捷键名称（例如：clean）："
        read -r shortcut

        if [[ ! "$shortcut" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            red "快捷键名称无效，仅允许字母、数字、下划线或连字符。"
            continue
        fi

        local target_path="/usr/local/bin/$shortcut"
        if [[ -e "$target_path" ]]; then
            yellow "快捷键 '$shortcut' 已存在。您想要取消还是更改它？"
            select action in "取消" "更改" "退出"; do
                case $action in
                    "取消")
                        red "快捷键 '$shortcut' 已保留。"
                        return 1
                        ;;
                    "更改")
                        sudo rm -f "$target_path"
                        break
                        ;;
                    "退出")
                        exit 0
                        ;;
                    *)
                        red "无效选项，请重试。"
                        ;;
                esac
            done
        else
            sudo ln -s "$(realpath "$0")" "$target_path"
            green "快捷键 '$shortcut' 已创建！现在可以直接在命令行输入 '$shortcut' 运行脚本。"
            break
        fi
    done
}

# 主流程
main() {
    # 检查是否为 cron 模式
    if [[ $# -gt 0 && "$1" == "--cron" ]]; then
        IS_CRON=1
        init_log
        clean_system
        exit 0
    fi

    init_log
    while true; do
        echo ""
        cyan "==== 系统深度清理工具 ===="
        echo "请选择要执行的操作："
        select option in "执行清理 (交互式)" "设置定时任务" "创建快捷键" "退出"; do
            case $option in
                "执行清理 (交互式)")
                    clean_system
                    break
                    ;;
                "设置定时任务")
                    setup_cron
                    break
                    ;;
                "创建快捷键")
                    create_symlink
                    break
                    ;;
                "退出")
                    echo "已退出。"
                    exit 0
                    ;;
                *)
                    red "无效选项，请重试。"
                    ;;
            esac
        done
    done
}

main "$@"
