#!/bin/bash
set -euo pipefail  # 严格错误处理

# ------------------------- 配置区域 -------------------------
SCRIPT_DIR="$HOME/one-click-scripts"
LOG_FILE="$SCRIPT_DIR/installer.log"
LOG_MAX_LINES=1000  # 日志文件最大行数
PROXY_PREFIX="https://ghfast.top/"  # GitHub 代理地址
RETRY_COUNT=3  # 下载重试次数
CUSTOM_MENU_FILE="$SCRIPT_DIR/custom_menu.conf"  # 自定义菜单配置文件

# ------------------------- 初始化 -------------------------
mkdir -p "$SCRIPT_DIR" || { echo "无法创建脚本存放目录：$SCRIPT_DIR"; exit 1; }
touch "$LOG_FILE" || { echo "无法创建日志文件"; exit 1; }
touch "$CUSTOM_MENU_FILE" || { echo "无法创建自定义菜单文件"; exit 1; }

# ------------------------- 默认脚本列表 -------------------------
DEFAULT_OPTIONS=(
    "1. 安装 Docker（install_docker.sh）"
    "2. 部署容器（deploy_containers.sh）"
    "3. 安装工具（install_tools.sh）"
    "4. 清理系统（clean-system.sh）"
    "5. 获取设备信息（device_info.sh）"
    "6. 安装 AdGuard Home（install-adg.sh）"
    "7. 安装 Alist（install-alist.sh）"
    "8. 安装 NexTerm（install-nexterm.sh）"
    "9. 安装 OpenAPI（install-openapi.sh）"
    "10. 安装 Sing-box（install-sing-box.sh）"
    "11. 安装 Subconverter（install-subc.sh）"
    "12. 设置 DNS（set-dns.sh）"
    "13. 配置定时任务（setup_cronjob.sh）"
    "14. 部署 Sub-Store（sub-store-deploy.sh）"
    "15. 更新 Sing-box 配置（update_singbox.sh）"
    "16. 创建或清除快捷方式"
    "17. 管理自定义菜单"
    "0. 退出"
)

# 默认脚本对应的 URL
declare -A DEFAULT_SCRIPTS=(
    ["1"]="https://raw.githubusercontent.com/zsj9418/-/main/install_docker.sh"
    ["2"]="https://raw.githubusercontent.com/zsj9418/-/main/deploy_containers.sh"
    ["3"]="https://raw.githubusercontent.com/zsj9418/-/main/install_tools.sh"
    ["4"]="https://raw.githubusercontent.com/zsj9418/-/main/clean-system.sh"
    ["5"]="https://raw.githubusercontent.com/zsj9418/-/main/device_info.sh"
    ["6"]="https://raw.githubusercontent.com/zsj9418/-/main/install-adg.sh"
    ["7"]="https://raw.githubusercontent.com/zsj9418/-/main/install-alist.sh"
    ["8"]="https://raw.githubusercontent.com/zsj9418/-/main/install-nexterm.sh"
    ["9"]="https://raw.githubusercontent.com/zsj9418/-/main/install-openapi.sh"
    ["10"]="https://raw.githubusercontent.com/zsj9418/-/main/install-sing-box.sh"
    ["11"]="https://raw.githubusercontent.com/zsj9418/-/main/install-subc.sh"
    ["12"]="https://raw.githubusercontent.com/zsj9418/-/main/set-dns.sh"
    ["13"]="https://raw.githubusercontent.com/zsj9418/-/main/setup_cronjob.sh"
    ["14"]="https://raw.githubusercontent.com/zsj9418/-/main/sub-store-deploy.sh"
    ["15"]="https://raw.githubusercontent.com/zsj9418/-/main/update_singbox.sh"
)

# ------------------------- 核心函数 -------------------------

# 管理日志行数
function manage_logs() {
    if [[ -f "$LOG_FILE" ]]; then
        local log_lines=$(wc -l < "$LOG_FILE")
        if [[ $log_lines -ge $LOG_MAX_LINES ]]; then
            echo "[$(date +'%Y-%m-%d %H:%M:%S')] 日志文件超过 $LOG_MAX_LINES 行，正在清理..." | tee -a "$LOG_FILE"
            tail -n $LOG_MAX_LINES "$LOG_FILE" > "$LOG_FILE.tmp"
            mv "$LOG_FILE.tmp" "$LOG_FILE"
        fi
    fi
}

# 网络检测（检查直连是否可用）
function check_network() {
    local url="https://raw.githubusercontent.com"
    if curl -fsSL --max-time 5 "$url" >/dev/null 2>&1; then
        return 0  # 直连可用
    else
        return 1  # 直连不可用，需要使用代理
    fi
}

# 下载脚本（支持直连和代理下载）
function download_script() {
    local choice="$1"
    local url="${SCRIPTS[$choice]}"
    local script_name=$(echo "${OPTIONS[$((choice - 1))]}" | awk -F '（' '{print $2}' | tr -d '（）()')
    local script_path="$SCRIPT_DIR/$script_name"

    # 如果脚本已存在，直接返回路径
    if [[ -f "$script_path" ]]; then
        echo "脚本 $script_name 已存在，跳过下载。" >&2
        echo "DEBUG: download_script - 脚本已存在, script_path: $script_path" >> "$LOG_FILE"
        echo -n "$script_path"
        return 0
    fi

    # 网络检测：优先使用直连，失败后使用代理
    if check_network; then
        echo "正在使用直连下载 $script_name..." >&2
    else
        echo "直连不可用，正在使用代理下载 $script_name..." >&2
        url="${PROXY_PREFIX}${url#https://raw.githubusercontent.com/}"
    fi

    # 下载脚本（带重试机制）
    for ((i=1; i<=RETRY_COUNT; i++)); do
        if curl -fsSL "$url" -o "$script_path"; then
            if [[ -s "$script_path" ]]; then # 检查文件是否为空
                chmod +x "$script_path"
                echo "[$(date +'%Y-%m-%d %H:%M:%S')] 已下载脚本到 $script_path，并赋予执行权限。" >> "$LOG_FILE"
                echo "DEBUG: download_script - 下载成功, script_path: $script_path" >> "$LOG_FILE"
                echo -n "$script_path"
                return 0
            else
                echo "下载 $script_name 后文件为空，下载失败。" >&2
                rm -f "$script_path" # 删除空文件
                return 1
            fi
        else
            echo "下载 $script_name 失败，重试中 ($i/$RETRY_COUNT)..." >&2
            sleep 2
        fi
    done

    echo "下载 $script_name 失败，请检查网络连接或 URL 是否正确。" >&2
    echo "DEBUG: download_script - curl 下载失败, 返回失败" >> "$LOG_FILE"
    return 1
}

# 运行脚本
function run_script() {
    local script_path="$1"
    if [[ -f "$script_path" ]]; then
        echo "正在运行脚本 $script_path..." | tee -a "$LOG_FILE"
        bash "$script_path" 2>&1 | tee -a "$LOG_FILE"
        if [[ $? -eq 0 ]]; then
            echo "脚本 $script_path 运行成功。" | tee -a "$LOG_FILE"
        else
            echo "脚本 $script_path 运行失败，请检查日志。" | tee -a "$LOG_FILE"
        fi
    else
        echo "脚本文件不存在：$script_path" | tee -a "$LOG_FILE"
    fi
}

# 快捷键管理增强
function manage_symlink() {
    while true; do
        clear
        echo "========================================"
        echo "          快捷键管理"
        echo "========================================"
        echo "当前已创建的快捷键："
        ls -l /usr/local/bin | grep "$SCRIPT_DIR"
        echo "----------------------------------------"
        echo "1. 创建快捷键"
        echo "2. 删除快捷键"
        echo "0. 返回主菜单"
        echo "----------------------------------------"
        read -rp "请输入选项编号: " choice
        case "$choice" in
            1)
                echo "请输入快捷键（例如 q）："
                read -r shortcut
                local link="/usr/local/bin/$shortcut"
                if [[ -e "$link" ]]; then
                    echo "快捷键已存在，请使用其他名称。"
                else
                    ln -s "$(realpath "$0")" "$link"
                    echo "快捷键 $shortcut 已创建。"
                fi
                ;;
            2)
                echo "请输入要删除的快捷键（例如 q）："
                read -r shortcut
                local link="/usr/local/bin/$shortcut"
                if [[ -e "$link" ]]; then
                    rm -f "$link"
                    echo "快捷键 $shortcut 已删除。"
                else
                    echo "快捷键 $shortcut 不存在。"
                fi
                ;;
            0)
                break
                ;;
            *)
                echo "无效选项，请重新输入。"
                ;;
        esac
        read -rp "按回车键继续..."
    done
}

# 自定义菜单管理
function manage_custom_menu() {
    while true; do
        clear
        echo "========================================"
        echo "          自定义菜单管理"
        echo "========================================"
        echo "当前自定义菜单选项："
        cat "$CUSTOM_MENU_FILE"
        echo "----------------------------------------"
        echo "1. 添加菜单选项"
        echo "2. 删除菜单选项"
        echo "0. 返回主菜单"
        echo "----------------------------------------"
        read -rp "请输入选项编号: " choice
        case "$choice" in
            1)
                echo "请输入新菜单项（格式：编号|显示名称|脚本URL或本地路径）："
                read -r new_item
                echo "$new_item" >> "$CUSTOM_MENU_FILE"
                echo "菜单项已添加。"
                ;;
            2)
                echo "请输入要删除的菜单项编号："
                read -r id
                sed -i "/^$id|/d" "$CUSTOM_MENU_FILE"
                echo "菜单项已删除。"
                ;;
            0)
                break
                ;;
            *)
                echo "无效选项，请重新输入。"
                ;;
        esac
        read -rp "按回车键继续..."
    done
}

# 加载菜单选项
function load_menu() {
    OPTIONS=("${DEFAULT_OPTIONS[@]}")
    SCRIPTS=()
    for key in "${!DEFAULT_SCRIPTS[@]}"; do
        SCRIPTS["$key"]="${DEFAULT_SCRIPTS[$key]}"
    done

    # 加载自定义菜单
    while IFS= read -r line; do
        if [[ "$line" != \#* ]]; then
            IFS='|' read -r id name url <<< "$line"
            OPTIONS+=("$id. $name")
            SCRIPTS["$id"]="$url"
        fi
    done < "$CUSTOM_MENU_FILE"
}

# 打印菜单
function print_menu() {
    clear
    echo "========================================"
    echo "          一键脚本管理平台"
    echo "========================================"
    echo "请选择要安装或运行的脚本："
    for option in "${OPTIONS[@]}"; do
        echo "  $option"
    done
    echo "----------------------------------------"
}

# 主函数
function main() {
    while true; do
        load_menu
        print_menu
        read -rp "请输入选项编号: " choice
        case "$choice" in
            0) exit 0 ;;
            16) manage_symlink ;;
            17) manage_custom_menu ;;
            [1-9]|1[0-5])
                manage_logs
                script_path=$(download_script "$choice")
                echo "DEBUG: main - download_script 返回 script_path: $script_path, 返回码: $?" >> "$LOG_FILE"
                if [[ $? -eq 0 && -n "$script_path" && -f "$script_path" ]]; then
                    run_script "$script_path"
                else
                    echo "脚本下载失败或文件不存在，请检查日志。" | tee -a "$LOG_FILE"
                fi
                read -rp "按回车键返回主菜单..."
                ;;
            *)
                echo "无效选项，请重新输入。" | tee -a "$LOG_FILE"
                sleep 2
                ;;
        esac
    done
}

# ------------------------- 执行入口 -------------------------
main
