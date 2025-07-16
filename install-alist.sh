#!/bin/bash
set -euo pipefail

ALIST_IMAGE="xhofe/alist:latest"
ALIST_NAME="alist"
ALIST_CONFIG_DIR="/home/docker/alist/conf"
ALIST_DEFAULT_PORT=5244

OPENLIST_IMAGE="openlistteam/openlist:latest"
OPENLIST_NAME="openlist"
OPENLIST_CONFIG_DIR="/home/docker/openlist/conf"
OPENLIST_DEFAULT_PORT=5245

LOG_FILE="/var/log/alist-openlist-deploy.log"

red() { echo -e "\033[31m$@\033[0m"; }
green() { echo -e "\033[32m$@\033[0m"; }
yellow() { echo -e "\033[33m$@\033[0m"; }

init_log() {
    if [[ ! -w "$(dirname "$LOG_FILE")" ]]; then
        LOG_FILE="/tmp/alist-openlist-deploy.log"
    fi
    touch "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
    echo -e "\033[33m日志文件: $LOG_FILE\033[0m"
}

confirm_operation() {
    local prompt="$1 (y/n): "
    while true; do
        read -rp "$prompt" -n 1 -r answer
        echo
        case "$answer" in
            [Yy]) return 0 ;;
            [Nn]) return 1 ;;
            *) echo "请输入 y 或 n" ;;
        esac
    done
}

check_port() {
    local port=$1
    if lsof -i:"$port" &>/dev/null; then
        red "端口 $port 已被占用"
        exit 1
    fi
}

ask_mount_directories() {
    local mount_dirs=()
    while true; do
        read -rp "请输入需要挂载的目录（留空结束）: " dir
        if [[ -z "$dir" ]]; then
            break
        fi
        if [[ ! -d "$dir" ]]; then
            yellow "目录不存在，自动创建：$dir"
            mkdir -p "$dir" || { red "创建失败"; continue; }
        fi
        mount_dirs+=("-v $dir:$dir")
    done
    echo "${mount_dirs[@]}"
}

install_dependencies() {
    yellow "检查 docker 依赖..."
    if ! command -v docker &>/dev/null; then
        if grep -qiE "ubuntu|debian" /etc/os-release; then
            sudo apt update && sudo apt install -y docker.io curl jq
        elif grep -qi "centos" /etc/os-release; then
            sudo yum install -y yum-utils device-mapper-persistent-data lvm2
            sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            sudo yum install -y docker-ce docker-ce-cli containerd.io jq
        else
            red "不支持的操作系统类型"
            exit 1
        fi
        sudo systemctl enable --now docker
        sudo usermod -aG docker "$USER" || true
    fi
    green "依赖检测完毕。"
}

# ========== Alist ==========
alist_pull_image() {
    yellow "拉取 Alist 镜像..."
    docker pull "$ALIST_IMAGE" || { red "镜像拉取失败。"; exit 1; }
}

alist_start() {
    local port=$1
    local mount_dirs=$2
    mkdir -p "$ALIST_CONFIG_DIR"
    yellow "启动 Alist 容器..."
    docker run -d \
        --name "$ALIST_NAME" \
        --network host \
        -v "$ALIST_CONFIG_DIR:/opt/alist/data" \
        $mount_dirs \
        --restart unless-stopped \
        -p "$port:$port" \
        "$ALIST_IMAGE" || {
        red "容器启动失败，查看日志：docker logs $ALIST_NAME"
        exit 1
    }
    green "Alist 启动成功。访问：http://<你的服务器IP>:$port"
}

alist_status() {
    if docker ps -a --format '{{.Names}}' | grep -q "^$ALIST_NAME$"; then
        docker ps -a --filter "name=$ALIST_NAME"
        docker logs --tail 20 $ALIST_NAME 2>/dev/null || true
        echo "Alist 默认账号：admin"
        echo "Alist 默认密码获取：docker exec -it $ALIST_NAME ./alist admin random"
    else
        red "Alist 容器未部署/未运行。"
    fi
}

alist_uninstall() {
    yellow "卸载 Alist..."
    if docker ps -q -f name="$ALIST_NAME" > /dev/null 2>&1; then
        docker stop "$ALIST_NAME" || true
        docker rm "$ALIST_NAME" || true
    fi
    docker rmi "$ALIST_IMAGE" || true
    rm -rf "$ALIST_CONFIG_DIR"
    green "Alist 已卸载。"
}

alist_reset_pwd() {
    if ! docker ps -q -f name="$ALIST_NAME" > /dev/null 2>&1; then
        red "Alist 容器未运行，请先部署。"
        return 1
    fi
    read -rp "请输入新的 Alist 管理员密码: " new_pass
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
                    yellow "已有容器 $ALIST_NAME"
                    confirm_operation "是否卸载当前 Alist？" && alist_uninstall
                fi
                alist_pull_image
                read -p "输入 Alist 服务端口（默认 $ALIST_DEFAULT_PORT）: " port
                port=${port:-$ALIST_DEFAULT_PORT}
                check_port "$port"
                yellow "添加挂载目录（宿主机:容器，支持多次输入，空回车结束）"
                mount_dirs=$(ask_mount_directories)
                alist_start "$port" "$mount_dirs"
                ;;
            2) break ;;
            *) red "无效选项。" ;;
        esac
    done
}

# ========== OpenList ==========
openlist_pull_image() {
    yellow "拉取 OpenList 镜像..."
    docker pull "$OPENLIST_IMAGE" || { red "镜像拉取失败。"; exit 1; }
}

openlist_start() {
    local port=$1
    local mount_dirs=$2
    mkdir -p "$OPENLIST_CONFIG_DIR"
    yellow "启动 OpenList 容器..."
    docker run -d \
        --name "$OPENLIST_NAME" \
        --network host \
        -v "$OPENLIST_CONFIG_DIR:/opt/openlist/data" \
        $mount_dirs \
        --restart unless-stopped \
        -p "$port:$port" \
        "$OPENLIST_IMAGE" || {
        red "容器启动失败，查看日志：docker logs $OPENLIST_NAME"
        exit 1
    }
    green "OpenList 启动成功。访问：http://<你的服务器IP>:$port"
}

openlist_status() {
    if docker ps -a --format '{{.Names}}' | grep -q "^$OPENLIST_NAME$"; then
        docker ps -a --filter "name=$OPENLIST_NAME"
        docker logs --tail 20 $OPENLIST_NAME 2>/dev/null || true
        echo "OpenList 默认账号：admin"
        echo "OpenList 默认密码获取：docker exec -it $OPENLIST_NAME /opt/openlist/openlist admin random"
    else
        red "OpenList 容器未部署/未运行。"
    fi
}

openlist_uninstall() {
    yellow "卸载 OpenList..."
    if docker ps -q -f name="$OPENLIST_NAME" > /dev/null 2>&1; then
        docker stop "$OPENLIST_NAME" || true
        docker rm "$OPENLIST_NAME" || true
    fi
    docker rmi "$OPENLIST_IMAGE" || true
    rm -rf "$OPENLIST_CONFIG_DIR"
    green "OpenList 已卸载。"
}

openlist_reset_pwd() {
    if ! docker ps -q -f name="$OPENLIST_NAME" > /dev/null 2>&1; then
        red "OpenList 容器未运行，请先部署。"
        return 1
    fi
    read -rp "请输入新的 OpenList 管理员密码: " new_pass
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
                    yellow "已有容器 $OPENLIST_NAME"
                    confirm_operation "是否卸载当前 OpenList？" && openlist_uninstall
                fi
                openlist_pull_image
                read -p "输入 OpenList 服务端口（默认 $OPENLIST_DEFAULT_PORT）: " port
                port=${port:-$OPENLIST_DEFAULT_PORT}
                check_port "$port"
                yellow "添加挂载目录（宿主机:容器，支持多次输入，空回车结束）"
                mount_dirs=$(ask_mount_directories)
                openlist_start "$port" "$mount_dirs"
                ;;
            2) break ;;
            *) red "无效选项。" ;;
        esac
    done
}

# ========== 追加挂载 ===========
add_mount_to_container() {
    local cname="$1"
    local image="$2"
    local exec_path="$3"
    local desc="$4"
    if ! docker ps -a --format '{{.Names}}' | grep -q "^$cname$"; then
        red "$desc 未部署，不能追加挂载"
        return
    fi

    local orig_mounts
    orig_mounts=$(docker inspect "$cname" | jq -r '.[0].Mounts[] | "-v \(.Source):\(.Destination)"' | xargs)
    local orig_ports
    orig_ports=$(docker inspect "$cname" | jq -r 'if .[0].HostConfig.PortBindings then .[0].HostConfig.PortBindings | to_entries[] | "-p \(.value[0].HostPort):\(.key | split("/")[0])" else "" end' | xargs)

    yellow "请输入要追加的新挂载目录（可多次输入，空回车结束）"
    # “部署用法一致”，可用 ask_mount_directories 获取新输入
    local new_mount_dirs
    new_mount_dirs=$(ask_mount_directories)
    if [[ -z "$new_mount_dirs" ]]; then
        yellow "未输入新目录，取消。"
        return
    fi
    local mounts="$orig_mounts $new_mount_dirs"
    local ports="$orig_ports"

    yellow "正在停用并重建 $desc 容器以追加挂载..."
    docker stop $cname || true
    docker rm $cname || true
    docker run -d --name "$cname" --network host $mounts --restart unless-stopped $ports "$image"
    green "$desc 容器追加挂载并重启完成，挂载目录如下："
    docker inspect $cname | jq -r '.[0].Mounts[] | "\(.Source) => \(.Destination)"'
}

# ========== 主菜单 ==========
main_menu() {
    while true; do
        clear
        echo "========================================"
        echo "      Alist & OpenList 一键管理工具"
        echo "========================================"
        echo "  1. Alist 管理"
        echo "  2. OpenList 管理"
        echo "  3. 设置 OpenList/Alist 管理员密码"
        echo "  4. 查看 OpenList/Alist 容器状态"
        echo "  5. 卸载清理 OpenList/Alist"
        echo "  6. 追加挂载目录"
        echo "  7. 退出"
        echo "----------------------------------------"
        read -rp "请输入选项编号: " choice
        case "$choice" in
            1) alist_manage_menu ;;
            2) openlist_manage_menu ;;
            3)
                echo "1) 设置 Alist 密码"
                echo "2) 设置 OpenList 密码"
                read -p "请选择(1/2): " sel
                case $sel in
                    1) alist_reset_pwd ;;
                    2) openlist_reset_pwd ;;
                    *) red "无效选项。" ;;
                esac
                ;;
            4)
                echo "1) 查看 Alist 容器状态"
                echo "2) 查看 OpenList 容器状态"
                read -p "请选择(1/2): " sel
                case $sel in
                    1) alist_status ;;
                    2) openlist_status ;;
                    *) red "无效选项。" ;;
                esac
                ;;
            5)
                echo "1) 卸载 Alist"
                echo "2) 卸载 OpenList"
                echo "3) 卸载全部"
                read -p "请选择(1/2/3): " sel
                case $sel in
                    1) alist_uninstall ;;
                    2) openlist_uninstall ;;
                    3) alist_uninstall; openlist_uninstall ;;
                    *) red "无效选项。" ;;
                esac
                ;;
            6)
                echo "1) 追加 Alist 挂载"
                echo "2) 追加 OpenList 挂载"
                read -p "请选择(1/2): " sel
                case $sel in
                    1) add_mount_to_container "$ALIST_NAME" "$ALIST_IMAGE" "./alist" "Alist" ;;
                    2) add_mount_to_container "$OPENLIST_NAME" "$OPENLIST_IMAGE" "/opt/openlist/openlist" "OpenList" ;;
                    *) red "无效选项。" ;;
                esac
                ;;
            7)
                echo "退出。"; exit 0
                ;;
            *)
                red "无效选项，请重新输入。"; sleep 1
                ;;
        esac
        echo
        sleep 1
    done
}

init_log
install_dependencies
main_menu
