#!/bin/bash
set -euo pipefail

# 带颜色输出
red() { echo -e "\033[31m$@\033[0m"; }
green() { echo -e "\033[32m$@\033[0m"; }
yellow() { echo -e "\033[33m$@\033[0m"; }

# 日志文件路径
LOG_FILE="/var/log/clean-system.log"

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

# 清理系统垃圾
clean_system() {
    yellow "开始清理系统垃圾..."

    # 清理临时文件
    yellow "清理 /tmp 和 /var/tmp..."
    find /tmp -type f -atime +1 -delete || true
    find /var/tmp -type f -atime +1 -delete || true

    # 清理旧日志
    if command -v journalctl &>/dev/null; then
        yellow "清理旧日志..."
        journalctl --vacuum-time=2d || true
    fi
    find /var/log -type f -name "*.log" -mtime +2 -delete || true

    # 清理包管理器缓存
    yellow "清理包管理器缓存..."
    if command -v apt &>/dev/null; then
        sudo apt clean || true
    elif command -v yum &>/dev/null; then
        sudo yum clean all || true
    elif command -v dnf &>/dev/null; then
        sudo dnf clean all || true
    fi

    # 清理用户缓存
    yellow "清理用户缓存..."
    find /home -type d -name ".cache" -exec rm -rf {} + || true
    find /root -type d -name ".cache" -exec rm -rf {} + || true

    # 清理 Docker 无用数据
    if command -v docker &>/dev/null; then
        yellow "清理 Docker 无用数据..."
        docker system prune -f || true
    fi

    # 统计磁盘空间使用情况
    local free_space
    free_space=$(df -h / | awk 'NR==2 {print $4}')
    green "系统垃圾清理完成！当前可用磁盘空间: $free_space"
}

# 设置定时任务
# 设置定时任务，只写入 root 的 crontab
setup_cron() {
    install_dependencies
    yellow "设置每两天自动运行一次..."

    local script_path
    script_path="$(realpath "$0")"
    local cron_job="0 0 */2 * * /bin/bash $script_path --cron >>/tmp/clean-cron.log 2>&1"

    # 检查自己是不是root用户。如果不是root，直接用sudo写入root crontab。
    if [[ $EUID -ne 0 ]]; then
        yellow "检测到非root用户，定时任务将写入root账户crontab。"
        # 获取root用户crontab内容，排除之前设置过的本脚本，追加新内容，再写回。
        tmpfile=$(mktemp)
        sudo crontab -l 2>/dev/null | grep -v "$script_path" > "$tmpfile" || true
        echo "$cron_job" >> "$tmpfile"
        sudo crontab "$tmpfile"
        rm -f "$tmpfile"
        green "定时任务已添加到 root 用户的 crontab："
        sudo crontab -l
    else
        # 已经是root，操作自己的crontab即可
        tmpfile=$(mktemp)
        crontab -l 2>/dev/null | grep -v "$script_path" > "$tmpfile" || true
        echo "$cron_job" >> "$tmpfile"
        crontab "$tmpfile"
        rm -f "$tmpfile"
        green "定时任务已添加到 root 用户的 crontab："
        crontab -l
    fi

    yellow "当前的 root 用户定时任务如下（请确保脚本路径与日志可访问/有权限）："
    if [[ $EUID -ne 0 ]]; then
        sudo crontab -l
    else
        crontab -l
    fi
}

# 创建快捷方式
create_symlink() {
    while true; do
        yellow "请输入您希望的快捷键名称（例如：clean）："
        read -r shortcut

        # 验证快捷键名称
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
            # 如果快捷键不存在，创建它
            sudo ln -s "$(realpath "$0")" "$target_path"
            green "快捷键 '$shortcut' 已创建！现在可以直接在命令行输入 '$shortcut' 运行脚本。"
            break
        fi
    done
}

# 主流程
main() {
    init_log
    while true; do
        if [[ $# -gt 0 && $1 == "--cron" ]]; then
            clean_system
            exit 0
        fi

        echo "请选择要执行的操作："
        select option in "执行清理" "设置定时任务" "创建快捷键" "退出"; do
            case $option in
                "执行清理")
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
