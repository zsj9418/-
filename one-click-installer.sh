#!/bin/bash

# 一键脚本存放目录
SCRIPT_DIR="$HOME/one-click-scripts"
LOG_FILE="$SCRIPT_DIR/installer.log"
mkdir -p "$SCRIPT_DIR"

# 脚本列表及对应的 URL
declare -A SCRIPTS=(
    ["1. 清理系统（clean-system.sh）"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/clean-system.sh"
    ["2. 部署容器（deploy_containers.sh）"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/deploy_containers.sh"
    ["3. 获取设备信息（device_info.sh）"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/device_info.sh"
    ["4. 安装 AdGuard Home（install-adg.sh）"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install-adg.sh"
    ["5. 安装 Alist（install-alist.sh）"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install-alist.sh"
    ["6. 安装 NexTerm（install-nexterm.sh）"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install-nexterm.sh"
    ["7. 安装 OpenAPI（install-openapi.sh）"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install-openapi.sh"
    ["8. 安装 Sing-box（install-sing-box.sh）"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install-sing-box.sh"
    ["9. 安装 Subconverter（install-subc.sh）"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install-subc.sh"
    ["10. 安装 Docker（install_docker.sh）"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install_docker.sh"
    ["11. 安装工具（install_tools.sh）"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install_tools.sh"
    ["12. 设置 DNS（set-dns.sh）"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/set-dns.sh"
    ["13. 配置定时任务（setup_cronjob.sh）"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/setup_cronjob.sh"
    ["14. 部署 Sub-Store（sub-store-deploy.sh）"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/sub-store-deploy.sh"
    ["15. 更新 Sing-box 配置（update_singbox.sh）"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/update_singbox.sh"
)

# 初始化日志记录
function init_logging() {
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
}

# 检查网络连接
function check_network() {
    if ! ping -c 1 -W 2 8.8.8.8 > /dev/null 2>&1; then
        echo "网络连接不可用，请检查网络后重试。"
        exit 1
    fi
}

# 打印菜单
function print_menu() {
    echo "请选择要安装或运行的脚本："
    for key in "${!SCRIPTS[@]}"; do
        echo "$key"
    done
    echo "0. 退出"
}

# 下载脚本
function download_script() {
    local script_name=$(echo "$1" | awk '{print $2}')
    local url="$2"
    local script_path="$SCRIPT_DIR/$script_name"

    if [[ -f "$script_path" ]]; then
        echo "$script_name 已存在，跳过下载。"
    else
        echo "正在下载 $script_name..."
        curl -fsSL --retry 3 --retry-delay 5 "$url" -o "$script_path"
        if [[ $? -ne 0 ]]; then
            echo "下载 $script_name 失败，请检查网络连接或 URL 是否正确。"
            exit 1
        fi
        chmod +x "$script_path"
        echo "已下载脚本到 $script_path，并赋予执行权限。"
    fi

    echo "$script_path"
}

# 运行脚本
function run_script() {
    local script_path="$1"
    echo "正在运行脚本 $script_path..."
    bash "$script_path"
    if [[ $? -ne 0 ]]; then
        echo "运行脚本时发生错误，请检查日志或脚本内容。"
        exit 1
    fi
}

# 检查管理员权限
function check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "某些脚本需要管理员权限，请使用 sudo 运行此脚本。"
        exit 1
    fi
}

# 主函数
function main() {
    init_logging
    check_network

    while true; do
        print_menu
        read -p "请输入选项编号: " choice

        if [[ "$choice" == "0" ]]; then
            echo "退出脚本。"
            exit 0
        fi

        if [[ -n "${SCRIPTS[$choice]}" ]]; then
            script_path=$(download_script "$choice" "${SCRIPTS[$choice]}")
            run_script "$script_path"
        else
            echo "无效选项，请重新输入。"
        fi
    done
}

# 检查管理员权限（某些脚本可能需要 root）
check_root

# 执行主函数
main
