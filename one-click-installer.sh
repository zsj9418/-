#!/bin/bash

# 一键脚本存放目录
SCRIPT_DIR="$HOME/one-click-scripts"
LOG_FILE="$SCRIPT_DIR/installer.log"
mkdir -p "$SCRIPT_DIR"

# GitHub 加速代理前缀（国内推荐使用）
PROXY_PREFIX="https://ghproxy.com/"

# 脚本列表（按顺序定义）
OPTIONS=(
    "1. 清理系统（clean-system.sh）"
    "2. 部署容器（deploy_containers.sh）"
    "3. 获取设备信息（device_info.sh）"
    "4. 安装 AdGuard Home（install-adg.sh）"
    "5. 安装 Alist（install-alist.sh）"
    "6. 安装 NexTerm（install-nexterm.sh）"
    "7. 安装 OpenAPI（install-openapi.sh）"
    "8. 安装 Sing-box（install-sing-box.sh）"
    "9. 安装 Subconverter（install-subc.sh）"
    "10. 安装 Docker（install_docker.sh）"
    "11. 安装工具（install_tools.sh）"
    "12. 设置 DNS（set-dns.sh）"
    "13. 配置定时任务（setup_cronjob.sh）"
    "14. 部署 Sub-Store（sub-store-deploy.sh）"
    "15. 更新 Sing-box 配置（update_singbox.sh）"
    "0. 退出"
)

# 脚本对应的 URL
declare -A SCRIPTS=(
    ["1"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/clean-system.sh"
    ["2"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/deploy_containers.sh"
    ["3"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/device_info.sh"
    ["4"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install-adg.sh"
    ["5"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install-alist.sh"
    ["6"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install-nexterm.sh"
    ["7"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install-openapi.sh"
    ["8"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install-sing-box.sh"
    ["9"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install-subc.sh"
    ["10"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install_docker.sh"
    ["11"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install_tools.sh"
    ["12"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/set-dns.sh"
    ["13"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/setup_cronjob.sh"
    ["14"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/sub-store-deploy.sh"
    ["15"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/update_singbox.sh"
)

# 打印菜单
function print_menu() {
    echo "请选择要安装或运行的脚本："
    for option in "${OPTIONS[@]}"; do
        echo "$option"
    done
}

# 下载脚本（支持代理和重试）
function download_script() {
    local choice="$1"
    local url="${SCRIPTS[$choice]}"
    local proxy_url="${PROXY_PREFIX}${url}"
    local script_name=$(echo "${OPTIONS[$((choice - 1))]}" | awk -F '（' '{print $2}' | tr -d '（）()')
    local script_path="$SCRIPT_DIR/$script_name"

    # 如果脚本已存在，跳过下载
    if [[ -f "$script_path" ]]; then
        echo "$script_name 已存在，跳过下载。"
    else
        echo "正在下载 $script_name..."

        # 下载脚本（尝试使用代理）
        curl -fsSL --retry 5 --retry-delay 5 "$proxy_url" -o "$script_path"
        if [[ $? -ne 0 ]]; then
            echo "使用代理下载失败，尝试直接下载..."
            curl -fsSL --retry 5 --retry-delay 5 "$url" -o "$script_path"
            if [[ $? -ne 0 ]]; then
                echo "下载 $script_name 失败，请检查网络连接或 URL 是否正确。"
                exit 1
            fi
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

# 主函数
function main() {
    while true; do
        print_menu
        read -p "请输入选项编号: " choice

        if [[ "$choice" == "0" ]]; then
            echo "退出脚本。"
            exit 0
        fi

        if [[ -n "${SCRIPTS[$choice]}" ]]; then
            script_path=$(download_script "$choice")
            run_script "$script_path"
        else
            echo "无效选项，请重新输入。"
        fi
    done
}

# 执行主函数
main
