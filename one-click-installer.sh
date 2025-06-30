#!/bin/bash
set -euo pipefail  # 严格错误处理

# ------------------------- 配置区域 -------------------------
SCRIPT_DIR="$HOME/one-click-scripts"
LOG_FILE="$SCRIPT_DIR/installer.log"
LOG_MAX_SIZE=1048576  # 日志文件最大大小，1MB = 1048576 字节
PROXY_PREFIXES=("https://un.ax18.ggff.net/")  # 可用的代理地址
RETRY_COUNT=3  # 下载重试次数
CUSTOM_MENU_FILE="$SCRIPT_DIR/custom_menu.conf"  # 自定义菜单配置文件

# ------------------------- 初始化 -------------------------
mkdir -p "$SCRIPT_DIR" || { echo "无法创建脚本存放目录：$SCRIPT_DIR"; exit 1; }
mkdir -p "$SCRIPT_DIR/core_scripts" || { echo "无法创建核心脚本目录：$SCRIPT_DIR/core_scripts"; exit 1; }
mkdir -p "$SCRIPT_DIR/user_scripts" || { echo "无法创建用户脚本目录：$SCRIPT_DIR/user_scripts"; exit 1; }
touch "$LOG_FILE" || { echo "无法创建日志文件"; exit 1; }
touch "$CUSTOM_MENU_FILE" || { echo "无法创建自定义菜单文件"; exit 1; }

# 检测是否为OpenWrt系统
function is_openwrt() {
    [[ -f /etc/openwrt_release ]] && return 0 || return 1
}

# 获取当前脚本的真实路径
function get_current_script_path() {
    # 尝试多种方法获取真实路径
    local path
    path="$(realpath "$0" 2>/dev/null)" || \
    path="$(readlink -f "$0" 2>/dev/null)" || \
    path="$0"
    echo "$path"
}

# ------------------------- 默认脚本列表  -------------------------
DEFAULT_OPTIONS=(
    "1.  安装 Docker"
    "2.  SSH 工具 & 测速容器"
    "3.  安装常用工具"
    "4.  清理系统垃圾"
    "5.  获取设备信息"
    "6.  安装 AdGuard Home"
    "7.  安装 Alist"
    "8.  安装 NexTerm"
    "9.  安装 OpenAPI"
    "10. 安装 Sing-box"
    "11. 安装 Subconverter"
    "12. 设置 DNS"
    "13. 安装 MosDNS"
    "14. 安装 cloudflared"
    "15. 部署 Sub-Store"
    "16. 安装 思源笔记"
    "17. 安装 Sun-Panel"
    "18. 安装 docker版OpenWrt"
    "19. 配置定时任务"
    "20. 设置 WiFi 热点"
    "21. 4G-UFI 切卡管理"
    "22. 设置 虚拟内存"
    "23. 开启 tun模式"
    "24. 硬盘格式化"
    "25. 自动挂载外置硬盘"
    "26. 安装dae(大鹅代理)"
    "27. openwrt网口配置"
    "28. casaos部署"
    "29. 硬盘测速"
    "30. 哪吒探针部署"
    "31. 在docker部署sing-box和mihomo"
    "32. 安装裸核sing-box和mihomo"
    "33. 安装docker版ddns-go"
    "34. 海纳思内置卸载"
    "35. 安装docker版lucky"
    "36. dae(大鹅代理)配置"
    "37. 开启caddy反代功能"
    "38. docker部署rustdesk远程控制"
    "39. openwrt固定MAC"
    "40. 安装docker版青龙面板"
    "98. 快捷键管理"
)

# 默认脚本对应的 URL (已排序并与 DEFAULT_OPTIONS 对应)
declare -A DEFAULT_SCRIPTS=(
    ["1"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install_docker.sh"
    ["2"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/deploy_containers.sh"
    ["3"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install_tools.sh"
    ["4"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/clean-system.sh"
    ["5"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/device_info.sh"
    ["6"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install-adg.sh"
    ["7"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install-alist.sh"
    ["8"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install-nexterm.sh"
    ["9"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install-openapi.sh"
    ["10"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/singbox-manager.sh"
    ["11"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install-subc.sh"
    ["12"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/set-dns.sh"
    ["13"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install_mosdns.sh"
    ["14"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/cloudflared-deploy.sh"
    ["15"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/sub-store-deploy.sh"
    ["16"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install_siyuan.sh"
    ["17"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/docker_sunpanel.sh"
    ["18"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/manage_openwrt.sh"
    ["19"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/setup_cronjob.sh"
    ["20"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/wifi-hotspot.sh"
    ["21"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/4G-UFI_sim.sh"
    ["22"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/pve-zfsswap.sh"
    ["23"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/setup_tun.sh"
    ["24"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/format_disk_script.sh"
    ["25"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/auto_disk_mounter.sh"
    ["26"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/dae_manager.sh"
    ["27"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/netconfig.sh"
    ["28"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/casaos_installer.sh"
    ["29"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/disk_speed_test.sh"
    ["30"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install-nezha.sh"
    ["31"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install_singbox_docker.sh"
    ["32"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install-sing-box-mihomo.sh"
    ["33"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install_docker_ddns_go.sh"
    ["34"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/uninstall_histb.sh"
    ["35"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install_docker_lucky.sh"
    ["36"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/setup-dae.sh"
    ["37"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install-caddy.sh"
    ["38"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/install-rustdesk.sh"
    ["39"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/openwrt_mac.sh"
    ["40"]="https://raw.githubusercontent.com/zsj9418/-/refs/heads/main/ql.sh"
)

# 声明全局变量
declare -A CUSTOM_SCRIPT_NAMES=()

# ------------------------- 核心函数 -------------------------

# 管理日志大小
function manage_logs() {
    if [[ -f "$LOG_FILE" ]]; then
        # 获取文件大小（字节）
        local log_size=$(stat -c%s "$LOG_FILE" 2>/dev/null || ls -l "$LOG_FILE" | awk '{print $5}')
        if [[ $log_size -ge $LOG_MAX_SIZE ]]; then
            echo "[$(date +'%Y-%m-%d %H:%M:%S')] 日志文件超过 1MB（当前大小: $log_size 字节），正在清理..." | tee -a "$LOG_FILE"
            # 计算需要保留的字节数（大约最后 50% 的内容，防止截断过少）
            local keep_size=$((LOG_MAX_SIZE / 2))
            # 使用 tail 处理字节而不是行数
            tail -c "$keep_size" "$LOG_FILE" > "$LOG_FILE.tmp"
            mv "$LOG_FILE.tmp" "$LOG_FILE"
            echo "[$(date +'%Y-%m-%d %H:%M:%S')] 日志清理完成，新大小: $(stat -c%s "$LOG_FILE" 2>/dev/null || ls -l "$LOG_FILE" | awk '{print $5}') 字节" >> "$LOG_FILE"
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

# 下载脚本（支持直连和多个代理下载）
function download_script() {
    local choice="$1"
    local url="${DEFAULT_SCRIPTS[$choice]}"
    local script_name=""
    local script_path=""

    # 从 URL 中提取脚本文件名
    script_name=$(basename "$url")
    # 构建新的文件名，例如 "4-clean-system.sh"
    script_name="${choice}-${script_name}"

    # 修改脚本保存路径为 core_scripts 目录
    script_path="$SCRIPT_DIR/core_scripts/$script_name"

    # 检查是否已存在，如果存在则直接返回路径
    if [[ -f "$script_path" ]]; then
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] 脚本已存在: $script_path" >> "$LOG_FILE"
        echo "$script_path"
        return 0
    fi

    # 下载脚本（带重试机制）
    for ((i=1; i<=RETRY_COUNT; i++)); do
        if curl -fsSL "$url" -o "$script_path"; then
            if [[ -s "$script_path" ]]; then
                chmod +x "$script_path"
                echo "[$(date +'%Y-%m-%d %H:%M:%S')] 已下载脚本到 $script_path，并赋予执行权限。" >> "$LOG_FILE"
                echo "$script_path"
                return 0
            else
                echo "下载 $script_name 后文件为空，下载失败。" >&2
                rm -f "$script_path"
                return 1
            fi
        else
            echo "下载 $script_name 失败，重试中 ($i/$RETRY_COUNT)..." >&2
            # 如果是 GitHub 资源且未使用代理，切换到代理
            if [[ "$url" == https://raw.githubusercontent.com/* ]]; then
                for proxy in "${PROXY_PREFIXES[@]}"; do
                    # 使用代理格式
                    proxy_url="${proxy}${url}"
                    echo "切换到代理 URL: $proxy_url" >&2
                    if curl -fsSL "$proxy_url" -o "$script_path"; then
                        if [[ -s "$script_path" ]]; then
                            chmod +x "$script_path"
                            echo "[$(date +'%Y-%m-%d %H:%M:%S')] 已通过代理下载脚本到 $script_path，并赋予执行权限。" >> "$LOG_FILE"
                            echo "$script_path"
                            return 0
                        else
                            echo "下载 $script_name 后文件为空，下载失败。" >&2
                            rm -f "$script_path"
                            return 1
                        fi
                    else
                        echo "代理下载失败: $proxy_url" >&2
                    fi
                done
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

# 快捷键管理（合并了脚本绑定功能）
function manage_symlink() {
    local current_script=$(realpath "$0")
    while true; do
        clear
        echo "========================================"
        echo "          快捷键管理"
        echo "========================================"
        echo "请选择操作："
        echo "1. 管理当前脚本快捷键"
        echo "2. 绑定指定脚本到快捷键"
        echo "0. 返回主菜单"
        echo "----------------------------------------"
        read -rp "请输入选项编号: " choice

        case "$choice" in
            1)
                manage_current_script_symlink "$current_script"
                ;;
            2)
                bind_script_to_shortcut
                ;;
            0)
                break
                ;;
            *)
                echo "无效选项，请重新输入。"
                read -rp "按回车键继续..."
                ;;
        esac
    done
}

# 管理当前脚本快捷键 (完全兼容版)
function manage_current_script_symlink() {
    local current_script=$(get_current_script_path)
    
    # 自动检测最佳目录
    local symlink_dirs=()
    if is_openwrt; then
        # OpenWrt优先尝试这些目录
        symlink_dirs=("/usr/bin" "/bin" "$HOME/.local/bin")
    else
        # 普通Linux系统优先尝试这些目录
        symlink_dirs=("/usr/local/bin" "/usr/bin" "/bin" "$HOME/.local/bin")
    fi
    
    # 查找第一个可写的目录
    local symlink_dir=""
    for dir in "${symlink_dirs[@]}"; do
        # 确保目录存在
        mkdir -p "$dir" 2>/dev/null || continue
        
        # 检查是否可写
        if [[ -w "$dir" ]]; then
            symlink_dir="$dir"
            break
        fi
    done
    
    if [[ -z "$symlink_dir" ]]; then
        echo "错误: 没有找到可写的目录来创建快捷方式"
        echo "尝试的目录: ${symlink_dirs[*]}"
        read -rp "按回车键返回..."
        return 1
    fi

    while true; do
        clear
        echo "========================================"
        echo "    管理当前脚本快捷键 (完全兼容版)"
        echo "========================================"
        echo "当前脚本路径: $current_script"
        echo "快捷键存储目录: $symlink_dir"
        echo "当前已创建的快捷键："

        # 查找所有指向当前脚本的链接
        local found_links=0
        if [[ -d "$symlink_dir" ]]; then
            while IFS= read -r -d $'\0' link; do
                local target
                target="$(readlink -f "$link" 2>/dev/null)" || continue
                if [[ "$target" == "$current_script" || "$target" == "$SCRIPT_DIR"/* ]]; then
                    echo "$(basename "$link") -> $target"
                    found_links=1
                fi
            done < <(find "$symlink_dir" -maxdepth 1 -type l -print0 2>/dev/null)
        fi

        if [[ $found_links -eq 0 ]]; then
            echo "暂无相关快捷键"
        fi

        echo "----------------------------------------"
        echo "请选择操作："
        echo "1. 创建新快捷键"
        echo "2. 删除快捷键"
        echo "0. 返回上一级菜单"
        echo "----------------------------------------"
        read -rp "请输入选项编号: " choice
        
        case "$choice" in
            1)
                echo "请输入快捷键名称（仅字母数字，不要带空格或特殊字符）："
                read -r shortcut
                
                # 验证输入
                if [[ ! "$shortcut" =~ ^[a-zA-Z0-9]+$ ]]; then
                    echo "错误: 快捷键只能包含字母和数字"
                    read -rp "按回车键继续..."
                    continue
                fi
                
                local link="$symlink_dir/$shortcut"

                # 检查是否已存在
                if [[ -e "$link" ]]; then
                    echo "错误: '$shortcut' 已存在，请使用其他名称"
                    read -rp "按回车键继续..."
                    continue
                fi

                # 创建链接 (使用绝对路径)
                if ln -s "$current_script" "$link" 2>/dev/null; then
                    echo "快捷键 '$shortcut' 已成功创建到:"
                    echo "$link -> $current_script"
                    echo "现在您可以直接在终端输入 '$shortcut' 来运行脚本"
                else
                    echo "创建失败，可能原因："
                    echo "1. 磁盘空间不足"
                    echo "2. 文件系统只读"
                    echo "3. 权限不足"
                    echo "请尝试其他目录或检查系统状态"
                fi
                
                read -rp "按回车键继续..."
                ;;
            2)
                echo "请输入要删除的快捷键名称："
                read -r shortcut
                local link="$symlink_dir/$shortcut"
                
                if [[ -L "$link" ]]; then
                    local target
                    target="$(readlink -f "$link" 2>/dev/null)" || target=""
                    if [[ "$target" == "$current_script" || "$target" == "$SCRIPT_DIR"/* ]]; then
                        if rm -f "$link"; then
                            echo "快捷键 '$shortcut' 已删除"
                        else
                            echo "删除失败，请尝试手动删除: rm -f '$link'"
                        fi
                    else
                        echo "安全提示: 该快捷键指向 '$target'"
                        echo "未绑定到当前脚本，不予删除"
                    fi
                else
                    echo "快捷键 '$shortcut' 不存在"
                fi
                
                read -rp "按回车键继续..."
                ;;
            0)
                break
                ;;
            *)
                echo "无效选项，请重新输入"
                read -rp "按回车键继续..."
                ;;
        esac
    done
}

# 指定脚本绑定快捷键 (完全兼容版)
function bind_script_to_shortcut() {
    while true; do
        clear
        echo "========================================"
        echo "    绑定指定脚本到快捷键 (完全兼容版)"
        echo "========================================"
        echo " "
        echo "----------------------------------------"
        echo "请输入脚本的完整路径: "
        read -r script_path

        # 获取绝对路径
        script_path="$(realpath "$script_path" 2>/dev/null || echo "$script_path")"
        
        # 路径验证
        if [[ ! -f "$script_path" ]]; then
            echo "错误: 脚本文件不存在: $script_path"
            read -rp "按回车键继续..."
            continue
        fi

        echo "请输入要绑定的快捷键 (仅字母数字): "
        read -r shortcut

        # 快捷键验证
        if [[ ! "$shortcut" =~ ^[a-zA-Z0-9]+$ ]]; then
            echo "错误: 快捷键只能包含字母和数字"
            read -rp "按回车键继续..."
            continue
        fi

        # 自动选择目录
        local symlink_dirs=()
        if is_openwrt; then
            symlink_dirs=("/usr/bin" "/bin" "$HOME/.local/bin")
        else
            symlink_dirs=("/usr/local/bin" "/usr/bin" "/bin" "$HOME/.local/bin")
        fi
        
        local symlink_dir=""
        for dir in "${symlink_dirs[@]}"; do
            mkdir -p "$dir" 2>/dev/null || continue
            if [[ -w "$dir" ]]; then
                symlink_dir="$dir"
                break
            fi
        done
        
        if [[ -z "$symlink_dir" ]]; then
            echo "错误: 没有可写的目录来创建快捷方式"
            read -rp "按回车键继续..."
            continue
        fi

        local link="$symlink_dir/$shortcut"
        if [[ -e "$link" ]]; then
            echo "错误: 快捷键已存在，请使用其他名称。"
            read -rp "按回车键继续..."
            continue
        fi

        # 创建链接
        if ln -s "$script_path" "$link"; then
            echo "成功创建快捷键:"
            echo "$link -> $script_path"
        else
            echo "创建失败，可能原因:"
            echo "1. 权限不足 (尝试: chmod +x '$script_path')"
            echo "2. 目标文件系统只读"
            echo "3. 磁盘空间不足"
        fi

        echo "----------------------------------------"
        echo "0. 返回上一级菜单"
        read -rp "按回车键继续..." choice
        case "$choice" in
            0)
                break
                ;;
            *)
                break
                ;;
        esac
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
    SCRIPTS=()
    CUSTOM_SCRIPT_NAMES=()  # 清空自定义脚本名缓存

    # 加载默认脚本
    for option_text in "${DEFAULT_OPTIONS[@]}"; do
        local option_number=$(echo "$option_text" | awk -F '.' '{print $1}') # 提取选项编号
        if [[ "$option_number" =~ ^[0-9]+$ ]]; then # 确保是数字编号的选项
            if [[ -v DEFAULT_SCRIPTS["$option_number"] ]]; then # 检查 DEFAULT_SCRIPTS 中是否存在该编号的 URL
                OPTIONS+=("$option_text") # 直接使用 DEFAULT_OPTIONS 中的文本
                SCRIPTS["$option_number"]="${DEFAULT_SCRIPTS[$option_number]}" # 使用选项编号作为 key
                CUSTOM_SCRIPT_NAMES["$option_number"]=$(basename "${DEFAULT_SCRIPTS[$option_number]}")
            else # 如果 DEFAULT_SCRIPTS 中没有该编号的 URL (例如，编号超出范围，或者 DEFAULT_SCRIPTS 定义不完整)
                OPTIONS+=("$option_text") # 仍然添加菜单项，但不关联脚本 URL
                SCRIPTS["$option_number"]="" # 不关联脚本URL，设置为空
            fi
        else # 非数字编号的选项 (例如 "98. 快捷键管理")
            OPTIONS+=("$option_text") # 添加非数字编号的选项
            if [[ "$option_text" == "98. 快捷键管理" ]]; then
                SCRIPTS["98"]="" # 快捷键管理等功能项不需要关联脚本URL
            elif [[ "$option_text" == "99. 管理自定义菜单" ]]; then
                SCRIPTS["99"]="" # 自定义菜单管理功能项不需要关联脚本URL
            elif [[ "$option_text" == "0. 退出" ]]; then
                SCRIPTS["0"]="" # 退出选项不需要关联脚本URL
            fi
        fi
    done

    # 加载自定义菜单项 (保持不变)
    local custom_options=()
    while IFS= read -r line; do
        if [[ -n "$line" && "$line" != \#* ]]; then
            IFS='|' read -r id name url script_name <<< "$line"
            OPTIONS+=("$id. $name")
            SCRIPTS["$id"]="$url"
            CUSTOM_SCRIPT_NAMES["$id"]="$script_name"
        fi
    done < "$CUSTOM_MENU_FILE"
    # 按编号排序 (确保包括自定义菜单项)
    IFS=$'\n' sorted_custom_options=($(sort -n <<< "${OPTIONS[*]}"))
    OPTIONS=("${sorted_custom_options[@]}")
    unset IFS

    # 确保“管理自定义菜单”和“退出”选项在最后 (固定编号 - 再次添加以确保在最后)
    OPTIONS+=("99. 管理自定义菜单" "0. 退出")
}

# 打印菜单
function print_menu() {
    clear
    echo "========================================"
    echo "          🚀 一键脚本管理平台 🚀"
    echo "========================================"
    echo "请选择要安装或运行的脚本："
    echo "请输入选项编号并按回车键执行："
    echo "----------------------------------------"
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
            0)
                exit 0
                ;;
            98)  # 快捷键管理
                manage_symlink
                ;;
            99)  # 自定义菜单管理
                manage_custom_menu
                ;;
            [1-9]|[1-9][0-9])  # 数字选项 (1-99)
                if [[ "$choice" -le 99 ]]; then # 限制选项为 1-99 (包括自定义菜单)
                    manage_logs
                    script_path=$(download_script "$choice")
                    if [[ $? -eq 0 ]]; then # 检查 download_script 是否成功
                        run_script "$script_path"
                    else
                        echo "脚本下载失败，请检查日志。" | tee -a "$LOG_FILE"
                        read -rp "按回车键返回主菜单..."
                    fi
                else
                    echo "无效选项，请重新输入。" | tee -a "$LOG_FILE"
                fi
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
