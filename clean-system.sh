#!/bin/bash
set -euo pipefail

# 带颜色输出
red() { echo -e "\033[31m$@\033[0m"; }
green() { echo -e "\033[32m$@\033[0m"; }
yellow() { echo -e "\033[33m$@\033[0m"; }

# 日志文件路径
LOG_FILE="$HOME/.clean-system.log"

# 初始化日志
init_log() {
    if [[ ! -w "$(dirname "$LOG_FILE")" ]]; then
        LOG_FILE="/tmp/clean-system.log"
    fi
    touch "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
    green "日志文件: $LOG_FILE"
}

# 检测系统类型和架构
detect_system_and_architecture() {
    local os=""
    local arch=""
    if grep -qiE "ubuntu|debian" /etc/os-release; then
        os="debian"
    elif grep -qi "centos" /etc/os-release; then
        os="centos"
    elif grep -qi "arch" /etc/os-release; then
        os="arch"
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
            arch)
                sudo pacman -S --noconfirm cronie sudo
                ;;
            *)
                red "不支持的包管理器"
                exit 1
                ;;
        esac
        green "依赖软件安装完成！"
    fi
}

# 清理系统垃圾
clean_system() {
    yellow "开始清理系统垃圾..."

    # 清理临时文件
    yellow "清理 /tmp 和 /var/tmp..."
    if ! find /tmp -type f -atime +1 -delete; then
        red "清理 /tmp 失败，请检查权限。"
    fi
    if ! find /var/tmp -type f -atime +1 -delete; then
        red "清理 /var/tmp 失败，请检查权限。"
    fi

    # 清理旧日志
    if command -v journalctl &>/dev/null; then
        yellow "清理旧日志..."
        if ! journalctl --vacuum-time=2d; then
            red "清理旧日志失败，请检查权限。"
        fi
    fi
    if ! find /var/log -type f -name "*.log" -mtime +2 -delete; then
        red "清理旧日志文件失败，请检查权限。"
    fi

    # 清理包管理器缓存
    yellow "清理包管理器缓存..."
    if command -v apt &>/dev/null; then
        if ! sudo apt clean; then
            red "清理 apt 缓存失败，请检查权限。"
        fi
    elif command -v yum &>/dev/null; then
        if ! sudo yum clean all; then
            red "清理 yum 缓存失败，请检查权限。"
        fi
    elif command -v dnf &>/dev/null; then
        if ! sudo dnf clean all; then
            red "清理 dnf 缓存失败，请检查权限。"
        fi
    elif command -v pacman &>/dev/null; then
        if ! sudo pacman -Sc --noconfirm; then
            red "清理 pacman 缓存失败，请检查权限。"
        fi
    fi

    # 清理用户缓存
    yellow "清理用户缓存..."
    if ! find /home -type d -name ".cache" -exec rm -rf {} +; then
        red "清理用户缓存失败，请检查权限。"
    fi
    if ! find /root -type d -name ".cache" -exec rm -rf {} +; then
        red "清理 root 缓存失败，请检查权限。"
    fi

    # 清理 Docker 无用数据
    if command -v docker &>/dev/null; then
        yellow "清理 Docker 无用数据..."
        if ! docker system prune -a -f; then
            red "清理 Docker 无用数据失败，请检查权限。"
        fi
    fi

    # 清理不必要的软件包
    yellow "清理不必要的软件包..."
    if command -v apt &>/dev/null; then
        if ! sudo apt autoremove -y; then
            red "清理不必要的 apt 软件包失败，请检查权限。"
        fi
    elif command -v yum &>/dev/null; then
        if ! sudo yum autoremove -y; then
            red "清理不必要的 yum 软件包失败，请检查权限。"
        fi
    elif command -v dnf &>/dev/null; then
        if ! sudo dnf autoremove -y; then
            red "清理不必要的 dnf 软件包失败，请检查权限。"
        fi
    elif command -v pacman &>/dev/null; then
        if ! sudo pacman -Qdtq | sudo pacman -Rns --noconfirm -; then
            red "清理不必要的 pacman 软件包失败，请检查权限。"
        fi
    fi

    # 统计磁盘空间使用情况
    local free_space
    free_space=$(df -h / | awk 'NR==2 {print $4}')
    green "系统垃圾清理完成！当前可用磁盘空间: $free_space"
}

# 设置定时任务
setup_cron() {
    install_dependencies
    yellow "设置定时任务..."

    echo "请选择定时任务的频率："
    echo "1. 每天"
    echo "2. 每两天"
    echo "3. 每周"
    echo "4. 每月"
    read -p "请输入选择（1-4）： " frequency
    case $frequency in
        1) cron_job="0 0 * * * /bin/bash $(realpath "$0") --cron" ;;
        2) cron_job="0 0 */2 * * /bin/bash $(realpath "$0") --cron" ;;
        3) cron_job="0 0 * * 0 /bin/bash $(realpath "$0") --cron" ;;
        4) cron_job="0 0 1 * * /bin/bash $(realpath "$0") --cron" ;;
        *) red "无效选项，请重新选择。" && setup_cron ;;
    esac

    (crontab -l 2>/dev/null | grep -v "$(realpath "$0")"; echo "$cron_job") | crontab -
    green "定时任务已设置！"
}

# 创建快捷方式
create_symlink() {
    yellow "请输入您希望的快捷键名称（例如：clean）："
    read -r shortcut

    # 验证快捷键名称
    if [[ ! "$shortcut" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        red "快捷键名称无效，仅允许字母、数字、下划线或连字符。"
        return 1
    fi

    local target_path="/usr/local/bin/$shortcut"
    if [[ -e "$target_path" ]]; then
        red "快捷键 '$shortcut' 已存在，请选择其他名称。"
        return 1
    fi

    if ! sudo ln -s "$(realpath "$0")" "$target_path"; then
        red "创建快捷键失败，请确保您有足够的权限。"
        return 1
    fi

    green "快捷键 '$shortcut' 已创建！现在可以直接在命令行输入 '$shortcut' 运行脚本。"
}

# 查看当前系统状态
view_system_status() {
    green "当前系统状态："
    echo "操作系统: $(grep -iE "PRETTY_NAME" /etc/os-release | cut -d'=' -f2 | tr -d '"')"
    echo "架构: $(uname -m)"
    echo "可用磁盘空间: $(df -h / | awk 'NR==2 {print $4}')"
    echo "Docker 版本: $(docker --version 2>/dev/null || echo "未安装")"
    echo "Cron 任务: $(crontab -l 2>/dev/null | grep "$(realpath "$0")" || echo "无定时任务")"
}

# 查看日志文件
view_log_file() {
    green "日志文件内容："
    cat "$LOG_FILE"
}

# 主流程
main() {
    init_log
    if [[ $# -gt 0 && $1 == "--cron" ]]; then
        clean_system
    else
        echo "请选择要执行的操作："
        select option in "执行清理" "设置定时任务" "创建快捷键" "查看系统状态" "查看日志文件" "退出"; do
            case $option in
                "执行清理")
                    yellow "执行清理操作将删除系统中的临时文件、旧日志、包管理器缓存、用户缓存等。"
                    clean_system
                    break
                    ;;
                "设置定时任务")
                    yellow "设置定时任务将使脚本定期自动运行清理操作。"
                    setup_cron
                    break
                    ;;
                "创建快捷键")
                    yellow "创建快捷键将允许您在命令行中直接输入快捷键来运行脚本。"
                    create_symlink
                    break
                    ;;
                "查看系统状态")
                    yellow "查看系统状态将显示当前操作系统的详细信息。"
                    view_system_status
                    break
                    ;;
                "查看日志文件")
                    yellow "查看日志文件将显示脚本运行的日志记录。"
                    view_log_file
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
    fi
}

main "$@"
