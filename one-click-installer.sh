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

# 声明全局变量
declare -A CUSTOM_SCRIPT_NAMES=()

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

    # 获取脚本文件名
    if [[ -v CUSTOM_SCRIPT_NAMES[$choice] ]]; then  # 检查 $choice 是否为 CUSTOM_SCRIPT_NAMES 的键 (自定义脚本)
        local script_name="${CUSTOM_SCRIPT_NAMES[$choice]}"
    else  # 默认脚本
        script_name=$(echo "${OPTIONS[$((choice - 1))]}" | awk -F '（' '{print $2}' | tr -d '（）()')
        [[ "$script_name" == *".sh" ]] || script_name="${script_name}.sh"  # 确保后缀
    fi

    local script_path="$SCRIPT_DIR/$script_name"

    # 检查脚本目录是否可写
    mkdir -p "$SCRIPT_DIR" || { echo "无法创建脚本存放目录：$SCRIPT_DIR"; exit 1; }
    if [[ ! -w "$SCRIPT_DIR" ]]; then
        echo "错误：脚本目录 $SCRIPT_DIR 不可写，无法下载脚本。" | tee -a "$LOG_FILE"
        return 1
    fi

    # 如果脚本已存在，避免文件名冲突
    if [[ -f "$script_path" ]]; then
        local counter=1
        while [[ -f "$script_path" ]]; do
            script_name="${script_name%.sh}_${counter}.sh"
            script_path="$SCRIPT_DIR/$script_name"
            counter=$((counter + 1))
        done
        echo "警告：脚本文件名冲突，已重命名为 $script_name。" | tee -a "$LOG_FILE"
    fi

    # 下载脚本（带重试机制）
    for ((i=1; i<=RETRY_COUNT; i++)); do
        if curl -fsSL "$url" -o "$script_path"; then
            if [[ -s "$script_path" ]]; then
                chmod +x "$script_path"
                echo "[$(date +'%Y-%m-%d %H:%M:%S')] 已下载脚本到 $script_path，并赋予执行权限。" >> "$LOG_FILE"
                echo -n "$script_path"
                return 0
            else
                echo "下载 $script_name 后文件为空，下载失败。" >&2
                rm -f "$script_path"
                return 1
            fi
        else
            echo "下载 $script_name 失败，重试中 ($i/$RETRY_COUNT)..." >&2
            # 如果是 GitHub 资源且未使用代理，切换到代理
            if [[ "$url" == https://raw.githubusercontent.com/* && "$url" != "${PROXY_PREFIX}"* ]]; then
                url="${PROXY_PREFIX}${url#https://raw.githubusercontent.com/}"
                echo "切换到代理 URL: $url" >&2
            fi
            sleep 2
        fi
    done

    echo "下载 $script_name 失败，请检查网络连接或 URL 是否正确。" >&2
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] 下载失败: URL=$url, 错误码=$?" >> "$LOG_FILE"
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
                next_id=$(get_next_custom_menu_id)
                echo "请输入新菜单项显示名称："
                read -r name
                echo "请输入脚本 URL 或本地路径："
                read -r url
                # 生成脚本文件名
                local script_name=$(echo "$name" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]').sh
                echo "$next_id|$name|$url|$script_name" >> "$CUSTOM_MENU_FILE"
                echo "菜单项已添加，编号为 $next_id，脚本文件将保存为 $script_name。"
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
# 获取下一个自定义菜单 ID
function get_next_custom_menu_id() {
    local max_default_id=0
    for option in "${DEFAULT_OPTIONS[@]}"; do
        local id_part=$(echo "$option" | awk -F '.' '{print $1}')
        if [[ "$id_part" =~ ^[0-9]+$ ]]; then
            if [[ "$id_part" -gt "$max_default_id" ]]; then
                max_default_id="$id_part"
            fi
        fi
    done

    local max_custom_id=$max_default_id
    while IFS= read -r line; do
        if [[ -n "$line" && "$line" != \#* ]]; then
            IFS='|' read -r id name url script_name <<< "$line"
            if [[ "$id" -gt "$max_custom_id" ]]; then
                max_custom_id="$id"
            fi
        fi
    done < "$CUSTOM_MENU_FILE"
    echo $((max_custom_id + 1))
}
# 加载菜单选项
function load_menu() {
    OPTIONS=() # Reset OPTIONS array to avoid duplicate entries
    OPTIONS=("${DEFAULT_OPTIONS[@]}")
    SCRIPTS=()
    CUSTOM_SCRIPT_NAMES=()  # 清空自定义脚本名缓存

    # 加载默认脚本
    for key in "${!DEFAULT_SCRIPTS[@]}"; do
        SCRIPTS["$key"]="${DEFAULT_SCRIPTS[$key]}"
    done

    # 加载自定义菜单并按编号排序
    local custom_options=()
    while IFS= read -r line; do
        if [[ -n "$line" && "$line" != \#* ]]; then
            IFS='|' read -r id name url script_name <<< "$line"
            custom_options+=("$id|$name|$url|$script_name")
        fi
    done < "$CUSTOM_MENU_FILE"
    # 按编号排序
    IFS=$'\n' sorted_custom_options=($(sort -n <<< "${custom_options[*]}"))
    unset IFS

    # 添加排序后的自定义菜单项
    for line in "${sorted_custom_options[@]}"; do
        IFS='|' read -r id name url script_name <<< "$line"
        OPTIONS+=("$id. $name")
        SCRIPTS["$id"]="$url"
        CUSTOM_SCRIPT_NAMES["$id"]="$script_name"  # 存储自定义脚本名
    done

    # 确保“管理自定义菜单”和“退出”选项在最后
    OPTIONS+=("99. 管理自定义菜单" "0. 退出")
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
            99) manage_custom_menu ;;
            [1-9]|1[0-9])
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
