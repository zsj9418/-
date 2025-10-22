#!/bin/bash
# 确保由 bash 执行
if [ -z "$BASH_VERSION" ]; then
    echo -e "\033[31m错误：此脚本需要使用 bash 运行，请使用 'bash $0' 来执行。\033[0m"
    exit 1
fi

set -euo pipefail

# =================================================================
# 全局配置
# =================================================================
ALIST_IMAGE="xhofe/alist:latest"
ALIST_NAME="alist"
ALIST_CONFIG_DIR="$HOME/docker/alist/data"
ALIST_INTERNAL_PORT=5244
ALIST_UID_GID="1000:1000"

OPENLIST_IMAGE="openlistteam/openlist:latest"
OPENLIST_NAME="openlist"
OPENLIST_CONFIG_DIR="$HOME/docker/openlist/data"
OPENLIST_INTERNAL_PORT=5244
OPENLIST_UID_GID="1026:100"

LOG_FILE="/var/log/alist-openlist-deploy.log"

# =================================================================
# 辅助函数
# =================================================================
red() { echo -e "\033[31m$@\033[0m"; }
green() { echo -e "\033[32m$@\033[0m"; }
yellow() { echo -e "\033[33m$@\033[0m"; }

run_as_root() {
    if [[ $EUID -eq 0 ]]; then
        "$@"
    else
        if command -v sudo &> /dev/null; then
            sudo "$@"
        else
            red "错误: 检测到您是非root用户，但系统中未找到 'sudo' 命令。"
            red "请先安装 sudo 或以 root 用户身份运行此脚本。"
            return 1
        fi
    fi
}

init_log() {
    if ! run_as_root touch "$LOG_FILE" 2>/dev/null; then
        LOG_FILE="/tmp/$(basename "$0").log"
        yellow "无法写入 /var/log/，日志将记录到: $LOG_FILE"
    fi
    touch "$LOG_FILE" || { red "无法创建日志文件 $LOG_FILE"; exit 1; }
    exec > >(tee -a "$LOG_FILE") 2>&1
    green "日志文件: $LOG_FILE"
}

confirm_operation() {
    local prompt="$1 (y/n): "
    while true; do
        read -rp "$prompt" -n 1 -r answer
        echo
        case "$answer" in
            [Yy]) return 0 ;;
            [Nn]) return 1 ;;
            *) red "请输入 y 或 n." ;;
        esac
    done
}

check_port_is_free() {
    local port=$1
    if run_as_root lsof -i:"$port" &>/dev/null; then
        red "错误: 端口 $port 已被占用。"
        return 1
    fi
    return 0
}

# 【优化】对于 --user 0:0 方案，chown 不再是必须的，但保留作为最佳实践
prepare_and_set_perms() {
    local dir_path="$1"
    local owner_id="$2"
    
    if [[ ! -d "$dir_path" ]]; then
        yellow "目录不存在，将自动创建: $dir_path"
        mkdir -p "$dir_path" || { red "创建目录失败: $dir_path"; return 1; }
    fi
    
    yellow "尝试为目录 '$dir_path' 设置所有者为 '$owner_id' (如果文件系统支持)..."
    if ! run_as_root chown -R "$owner_id" "$dir_path"; then
        yellow "权限设置失败或文件系统不支持，将依赖 --user 0:0 启动。"
    fi
    green "目录 '$dir_path' 准备就绪。"
    return 0
}

ask_mount_directories() {
    local owner_id="$1"
    local -n mount_array_ref=$2

    yellow "现在可以添加额外的挂载目录（例如媒体库）。"
    yellow "输入宿主机的绝对路径，脚本会自动映射到容器内同名路径。"
    while true; do
        read -rp "请输入需要挂载的目录绝对路径 (留空结束): " dir
        if [[ -z "$dir" ]]; then
            break
        fi
        
        if [[ "$dir" != /* ]]; then
            red "错误：请输入绝对路径（以 / 开头）。"
            continue
        fi

        # 依然尝试设置权限，但在失败时不中断
        prepare_and_set_perms "$dir" "$owner_id"
        
        mount_array_ref+=("-v" "$dir:$dir")
        green "已添加挂载: $dir"
    done
}

install_dependencies() {
    yellow "检查并安装依赖 (docker, jq)..."
    local needs_install=""
    command -v docker &> /dev/null || needs_install+="docker "
    command -v jq &> /dev/null || needs_install+="jq "
    command -v curl &> /dev/null || needs_install+="curl "

    if [[ -n "$needs_install" ]]; then
        red "检测到以下依赖未安装: $needs_install，正在尝试自动安装..."
        if command -v apt-get &>/dev/null; then
            run_as_root apt-get update && run_as_root apt-get install -y docker.io curl jq
        elif command -v yum &>/dev/null; then
            run_as_root yum install -y yum-utils
            run_as_root yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            run_as_root yum install -y docker-ce docker-ce-cli containerd.io jq curl
        elif command -v opkg &>/dev/null; then
            run_as_root opkg update
            command -v docker &> /dev/null || run_as_root opkg install dockerd docker
            command -v jq &> /dev/null || run_as_root opkg install jq
            command -v curl &> /dev/null || run_as_root opkg install curl
        else
            red "不支持的操作系统。请手动安装: $needs_install"
            exit 1
        fi
        
        if command -v systemctl &>/dev/null; then
             run_as_root systemctl enable --now docker
        elif command -v /etc/init.d/dockerd &>/dev/null; then
             run_as_root /etc/init.d/dockerd enable
             run_as_root /etc/init.d/dockerd start
        fi
        
        if [[ $EUID -ne 0 ]] && ! groups "$USER" | grep -q '\bdocker\b'; then
            run_as_root usermod -aG docker "$USER" || true
            yellow "已将用户 '$USER' 添加到 'docker' 组。您需要重新登录或重启终端才能无sudo运行docker命令。"
        fi
    fi
    green "依赖检测完毕。"
}

# ========== Alist ==========
alist_pull_image() {
    yellow "拉取 Alist 镜像: $ALIST_IMAGE"
    docker pull "$ALIST_IMAGE" || { red "镜像拉取失败。"; exit 1; }
}

alist_start() {
    local port
    while true; do
        read -rp "请输入 Alist 的外部访问端口 (默认 $ALIST_INTERNAL_PORT): " port
        port=${port:-$ALIST_INTERNAL_PORT}
        check_port_is_free "$port" && break
    done

    prepare_and_set_perms "$ALIST_CONFIG_DIR" "$ALIST_UID_GID" || return 1
    
    local -a docker_args=()
    # 【终极修复】添加 --user 0:0，强制容器以root身份运行，解决一切文件系统权限问题
    docker_args+=("-d" "--name" "$ALIST_NAME" "--user" "0:0" "-p" "${port}:${ALIST_INTERNAL_PORT}" "-v" "$ALIST_CONFIG_DIR:/opt/alist/data" "--restart" "unless-stopped")
    
    ask_mount_directories "$ALIST_UID_GID" docker_args

    yellow "正在启动 Alist 容器..."
    docker run "${docker_args[@]}" "$ALIST_IMAGE"
    
    sleep 3
    if ! docker ps -q -f name="^${ALIST_NAME}$" > /dev/null || docker ps --filter "name=$ALIST_NAME" --format '{{.Status}}' | grep -q "Restarting"; then
        red "Alist 容器启动失败或正在无限重启！请检查以下日志："
        docker logs "$ALIST_NAME"
        exit 1
    fi
    
    green "Alist 启动成功！"
    green "访问地址: http://<你的服务器IP>:$port"
    alist_status
}

alist_status() {
    if docker ps -a --format '{{.Names}}' | grep -q "^$ALIST_NAME$"; then
        docker ps -a --filter "name=$ALIST_NAME"
        echo "Alist 默认密码获取命令：docker exec -it $ALIST_NAME ./alist admin"
        yellow "最近20条日志："
        docker logs --tail 20 $ALIST_NAME 2>/dev/null || true
    else
        red "Alist 容器未部署/未运行。"
    fi
}

alist_uninstall() {
    yellow "卸载 Alist..."
    if docker ps -a -q -f name="^$ALIST_NAME$" > /dev/null 2>&1; then
        docker stop "$ALIST_NAME" >/dev/null || true
        docker rm "$ALIST_NAME" >/dev/null || true
        green "Alist 容器已停止并移除。"
    fi
    if confirm_operation "是否删除 Alist 的镜像 ($ALIST_IMAGE)?"; then
        docker rmi "$ALIST_IMAGE" 2>/dev/null || yellow "镜像可能不存在或被其他容器使用。"
    fi
    if confirm_operation "是否删除 Alist 的配置文件 ($ALIST_CONFIG_DIR)?"; then
        run_as_root rm -rf "$ALIST_CONFIG_DIR"
        green "配置文件目录已删除。"
    fi
    green "Alist 已卸载完成。"
}

alist_reset_pwd() {
    if ! docker ps -q -f name="^$ALIST_NAME$" > /dev/null 2>&1; then
        red "Alist 容器未运行，请先部署。"
        return 1
    fi
    read -rp "请输入新的 Alist 管理员密码: " new_pass
    if [[ -z "$new_pass" ]]; then red "密码不能为空"; return 1; fi
    docker exec -it "$ALIST_NAME" ./alist admin set "$new_pass"
    if [[ $? -eq 0 ]]; then
        green "Alist 管理员密码已设置为：$new_pass"
    else
        red "设置失败，请检查日志。"
    fi
}

alist_manage_menu() {
    while true; do
        echo
        echo "-------- Alist 管理 --------"
        echo "  1. 部署/重装 Alist"
        echo "  2. 返回上级"
        echo "----------------------------"
        read -rp "请选择: " sel
        case $sel in
            1)
                if docker ps -a --format '{{.Names}}' | grep -q "^$ALIST_NAME$"; then
                    if confirm_operation "检测到已有的 Alist 容器，是否卸载并重装？"; then
                        alist_uninstall
                    else
                        continue
                    fi
                fi
                alist_pull_image
                alist_start
                ;;
            2) break ;;
            *) red "无效选项。" ;;
        esac
    done
}

# ========== OpenList ==========
openlist_pull_image() {
    yellow "拉取 OpenList 镜像: $OPENLIST_IMAGE"
    docker pull "$OPENLIST_IMAGE" || { red "镜像拉取失败。"; exit 1; }
}

openlist_start() {
    local port
    while true; do
        read -rp "请输入 OpenList 的外部访问端口 (默认 $OPENLIST_INTERNAL_PORT): " port
        port=${port:-$OPENLIST_INTERNAL_PORT}
        check_port_is_free "$port" && break
    done

    prepare_and_set_perms "$OPENLIST_CONFIG_DIR" "$OPENLIST_UID_GID" || return 1
    
    local -a docker_args=()
    # 【终极修复】添加 --user 0:0，强制容器以root身份运行，解决一切文件系统权限问题
    docker_args+=("-d" "--name" "$OPENLIST_NAME" "--user" "0:0" "-p" "${port}:${OPENLIST_INTERNAL_PORT}" "-v" "$OPENLIST_CONFIG_DIR:/opt/openlist/data" "--restart" "unless-stopped")

    ask_mount_directories "$OPENLIST_UID_GID" docker_args
    
    yellow "启动 OpenList 容器..."
    docker run "${docker_args[@]}" "$OPENLIST_IMAGE"

    sleep 3
    if ! docker ps -q -f name="^${OPENLIST_NAME}$" > /dev/null || docker ps --filter "name=$OPENLIST_NAME" --format '{{.Status}}' | grep -q "Restarting"; then
        red "OpenList 容器启动失败或正在无限重启！请检查以下日志："
        docker logs "$OPENLIST_NAME"
        exit 1
    fi

    green "OpenList 启动成功！"
    green "访问地址: http://<你的服务器IP>:$port"
    openlist_status
}

openlist_status() {
    if docker ps -a --format '{{.Names}}' | grep -q "^$OPENLIST_NAME$"; then
        docker ps -a --filter "name=$OPENLIST_NAME"
        echo "OpenList 默认密码获取命令：docker exec -it $OPENLIST_NAME /opt/openlist/openlist admin random"
        yellow "最近20条日志："
        docker logs --tail 20 $OPENLIST_NAME 2>/dev/null || true
    else
        red "OpenList 容器未部署/未运行。"
    fi
}

openlist_uninstall() {
    yellow "卸载 OpenList..."
    if docker ps -a -q -f name="^$OPENLIST_NAME$" > /dev/null 2>&1; then
        docker stop "$OPENLIST_NAME" >/dev/null || true
        docker rm "$OPENLIST_NAME" >/dev/null || true
        green "OpenList 容器已停止并移除。"
    fi
    if confirm_operation "是否删除 OpenList 的镜像 ($OPENLIST_IMAGE)?"; then
        docker rmi "$OPENLIST_IMAGE" 2>/dev/null || yellow "镜像可能不存在或被其他容器使用。"
    fi
    if confirm_operation "是否删除 OpenList 的配置文件 ($OPENLIST_CONFIG_DIR)?"; then
        run_as_root rm -rf "$OPENLIST_CONFIG_DIR"
        green "配置文件目录已删除。"
    fi
    green "OpenList 已卸载完成。"
}

openlist_reset_pwd() {
    if ! docker ps -q -f name="^$OPENLIST_NAME$" > /dev/null 2>&1; then
        red "OpenList 容器未运行，请先部署。"
        return 1
    fi
    read -rp "请输入新的 OpenList 管理员密码: " new_pass
    if [[ -z "$new_pass" ]]; then red "密码不能为空"; return 1; fi
    docker exec -it "$OPENLIST_NAME" /opt/openlist/openlist admin set "$new_pass"
    if [[ $? -eq 0 ]]; then
        green "OpenList 管理员密码已设置为：$new_pass"
    else
        red "设置失败，请检查日志。"
    fi
}

openlist_manage_menu() {
    while true; do
        echo
        echo "-------- OpenList 管理 --------"
        echo "  1. 部署/重装 OpenList"
        echo "  2. 返回上级"
        echo "-------------------------------"
        read -rp "请选择: " sel
        case $sel in
            1)
                if docker ps -a --format '{{.Names}}' | grep -q "^$OPENLIST_NAME$"; then
                    if confirm_operation "检测到已有的 OpenList 容器，是否卸载并重装？"; then
                       openlist_uninstall
                    else
                        continue
                    fi
                fi
                openlist_pull_image
                openlist_start
                ;;
            2) break ;;
            *) red "无效选项。" ;;
        esac
    done
}

# ========== 追加挂载 ===========
add_mount_to_container() {
    local cname="$1" image="$2" uid_gid="$3" desc="$4"
    
    if ! command -v jq &> /dev/null; then red "此功能需要 'jq' 命令，请先安装。"; return 1; fi
    if ! docker ps -a --format '{{.Names}}' | grep -q "^$cname$"; then red "$desc 未部署，不能追加挂载。"; return; fi

    local container_info
    container_info=$(docker inspect "$cname")

    local -a new_run_args=()
    # 【终极修复】重建时也强制使用root用户
    new_run_args+=("-d" "--name" "$cname" "--user" "0:0")

    local -a orig_ports
    mapfile -t orig_ports < <(echo "$container_info" | jq -r 'if .[0].HostConfig.PortBindings then .[0].HostConfig.PortBindings | to_entries[] | "-p", "\(.value[0].HostPort):\(.key | split("/")[0])" else "" end')
    if (( ${#orig_ports[@]} > 0 )); then new_run_args+=("${orig_ports[@]}"); fi

    local -a orig_mounts
    mapfile -t orig_mounts < <(echo "$container_info" | jq -r '.[0].Mounts[] | "-v", "\(.Source):\(.Destination)"')
    if (( ${#orig_mounts[@]} > 0 )); then new_run_args+=("${orig_mounts[@]}"); fi

    local restart_policy
    restart_policy=$(echo "$container_info" | jq -r '.[0].HostConfig.RestartPolicy.Name')
    if [[ -n "$restart_policy" && "$restart_policy" != "no" ]]; then new_run_args+=("--restart" "$restart_policy"); fi

    yellow "当前已有挂载："; docker inspect "$cname" | jq -r '.[0].Mounts[] | "  - \(.Source) => \(.Destination)"'
    yellow "请输入要追加的新挂载目录（可多次输入，空回车结束）"
    ask_mount_directories "$uid_gid" new_run_args

    yellow "正在停用并重建 $desc 容器以应用新的挂载..."
    docker stop "$cname" &>/dev/null || true
    docker rm "$cname" &>/dev/null || true
    
    docker run "${new_run_args[@]}" "$image"
    
    green "$desc 容器追加挂载并重启完成！"
    yellow "当前所有挂载目录如下："; docker inspect "$cname" | jq -r '.[0].Mounts[] | "  - \(.Source) => \(.Destination)"'
}

# ========== 主菜单 ==========
main_menu() {
    while true; do
        clear
        echo "========================================"
        echo "      Alist & OpenList 一键管理脚本"
        echo "========================================"
        echo "  1. Alist 管理"
        echo "  2. OpenList 管理"
        echo "  3. 设置 OpenList/Alist 管理员密码"
        echo "  4. 查看 OpenList/Alist 容器状态"
        echo "  5. 卸载清理 OpenList/Alist"
        echo "  6. 为已有容器追加挂载目录"
        echo "  7. 退出"
        echo "----------------------------------------"
        read -rp "请输入选项编号: " choice
        case "$choice" in
            1) alist_manage_menu ;;
            2) openlist_manage_menu ;;
            3)
                echo "1) 设置 Alist 密码"; echo "2) 设置 OpenList 密码"
                read -rp "请选择(1/2): " sel
                case $sel in 1) alist_reset_pwd ;; 2) openlist_reset_pwd ;; *) red "无效选项。" ;; esac ;;
            4)
                echo "1) 查看 Alist 容器状态"; echo "2) 查看 OpenList 容器状态"
                read -rp "请选择(1/2): " sel
                case $sel in 1) alist_status ;; 2) openlist_status ;; *) red "无效选项。" ;; esac ;;
            5)
                echo "1) 卸载 Alist"; echo "2) 卸载 OpenList"; echo "3) 卸载全部"
                read -rp "请选择(1/2/3): " sel
                case $sel in 1) alist_uninstall ;; 2) openlist_uninstall ;; 3) alist_uninstall; openlist_uninstall ;; *) red "无效选项。" ;; esac ;;
            6)
                echo "1) 追加 Alist 挂载"; echo "2) 追加 OpenList 挂载"
                read -rp "请选择(1/2): " sel
                case $sel in
                    1) add_mount_to_container "$ALIST_NAME" "$ALIST_IMAGE" "$ALIST_UID_GID" "Alist" ;;
                    2) add_mount_to_container "$OPENLIST_NAME" "$OPENLIST_IMAGE" "$OPENLIST_UID_GID" "OpenList" ;;
                    *) red "无效选项。" ;;
                esac ;;
            7) echo "感谢使用，再见！"; exit 0 ;;
            *) red "无效选项，请重新输入。"; sleep 1 ;;
        esac
        echo
        read -n 1 -s -r -p "按任意键返回主菜单..."
    done
}

# --- 脚本入口 ---
init_log
install_dependencies
main_menu
