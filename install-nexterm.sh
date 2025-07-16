#!/bin/bash
set -euo pipefail

# 定义颜色代码
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 配置常量
docker_name="nexterm"
# docker_img="germannewsmaker/nexterm:latest" # 将在部署时根据用户选择动态设定
default_port=6989
internal_port=6989  # 容器内部服务端口
CONFIG_DIR="/home/docker/nexterm"
LOG_FILE="/var/log/nexterm-deploy.log"
LOG_MAX_SIZE=1048576 # 1M

# 模拟 Docker Hub 上的可用标签（实际应通过API获取）
# 实际场景中，你需要通过 curl -s "https://registry.hub.docker.com/v2/germannewsmaker/nexterm/tags/list/" | jq -r '.tags[]' 获取
declare -a available_tags=("latest" "v1.0.0" "v1.0.1" "dev") # 假设的可用标签

# 初始化日志路径
setup_logging() {
    local log_dir=$(dirname "$LOG_FILE")
    [[ ! -d "$log_dir" ]] && mkdir -p "$log_dir"
    [[ ! -w "$log_dir" ]] && { echo -e "${RED}日志目录 $log_dir 无写权限，请检查权限设置。${NC}"; exit 1; }

    # 如果日志文件超过 1MB，则清空
    [[ -f "$LOG_FILE" && $(stat -c%s "$LOG_FILE") -ge $LOG_MAX_SIZE ]] && > "$LOG_FILE"
    touch "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
}

# 信号捕获
cleanup() {
    echo -e "\n${YELLOW}捕获中断信号，执行清理...${NC}"
    docker stop "$docker_name" >/dev/null 2>&1 || true # 尝试停止容器，忽略错误
    exit 1
}
trap cleanup SIGINT SIGTERM

# 封装用户输入询问
prompt_user_input() {
    local prompt=$1
    local default_value=$2
    local input
    read -rp "$prompt（默认值：$default_value）：" input
    echo "${input:-$default_value}"
}

# 封装确认操作
confirm_operation() {
    local prompt=$1
    while true; do
        read -rp "${YELLOW}${prompt}${NC} (y/n): " answer
        case "$answer" in
            [yY]|yes|YES) return 0 ;;
            [nN]|no|NO) return 1 ;;
            *) echo -e "${RED}无效输入，请输入 y 或 n。${NC}" ;;
        esac
    done
}

# 检查Docker是否安装
check_docker() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误：Docker 未安装！${NC}"
        echo -e "${YELLOW}请根据系统类型安装Docker，例如：${NC}"
        echo -e "${BLUE}  Debian/Ubuntu: sudo apt install docker.io${NC}"
        echo -e "${BLUE}  CentOS: sudo yum install docker${NC}"
        return 1
    fi
    echo -e "${GREEN}Docker 已安装。${NC}"
    return 0
}


# 检测端口是否可用 (改进版，兼容 ss 和 lsof)
check_port_available() {
    local port=$1
    if command -v ss &>/dev/null; then # 优先使用ss
        if ss -tuln | grep -q ":${port} "; then
            return 1 # 端口被占用
        fi
    elif command -v lsof &>/dev/null; then # 否则尝试lsof
        if lsof -i :"${port}" &> /dev/null; then
            return 1 # 端口被占用
        fi
    else
        echo -e "${RED}警告：未找到 'ss' 或 'lsof' 命令，无法精确检查端口可用性。请手动确认端口 ${port} 未被占用。${NC}"
        # 这里默认可用，因为无法检查，风险自负
        return 0
    fi
    return 0 # 端口可用
}

# 验证用户输入的端口
validate_and_set_port() {
    while true; do
        user_port=$(prompt_user_input "请输入希望使用的主机端口" "$default_port")
        if [[ "$user_port" =~ ^[0-9]+$ && "$user_port" -ge 1 && "$user_port" -le 65535 ]]; then
            if check_port_available "$user_port"; then
                export PORT=$user_port
                echo -e "${GREEN}端口 ${PORT} 可用。${NC}"
                break
            else
                echo -e "${RED}端口 ${user_port} 已被占用，请选择其他端口。${NC}"
            fi
        else
            echo -e "${RED}输入无效，端口号必须是 1-65535 范围内的数字。${NC}"
        fi
    done
}

# 提供网络模式选择并提示
choose_network_mode() {
    echo -e "\n${BLUE}请选择网络模式：${NC}"
    echo "1. bridge（推荐，适合大多数场景，容器有独立IP）"
    echo "2. host（直接使用主机网络，性能稍好，但可能与其他服务冲突）"
    while true; do
        read -rp "请输入选项（1 或 2）：" choice
        case $choice in
            1) NETWORK_MODE="bridge"; echo -e "${GREEN}选择的网络模式：bridge${NC}"; break ;;
            2) NETWORK_MODE="host"; echo -e "${GREEN}选择的网络模式：host${NC}"; break ;;
            *) echo -e "${RED}无效选项，请重新输入。${NC}" ;;
        esac
    done
}

# 选择 Docker 镜像版本
select_docker_image_tag() {
    echo -e "\n${BLUE}请选择 Nexterm 镜像版本：${NC}"
    echo "可用版本（假设）："
    for i in "${!available_tags[@]}"; do
        echo "$((i+1)). ${available_tags[$i]}"
    done
    echo "$(( ${#available_tags[@]} + 1 )). 手动输入其他版本标签"

    local selected_tag
    while true; do
        read -rp "请输入选项（1-${#available_tags[@]} 或手动输入选项）：" choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice > 0 && choice <= ${#available_tags[@]} )); then
            selected_tag="${available_tags[$((choice-1))]}"
            break
        elif [[ "$choice" -eq $(( ${#available_tags[@]} + 1 )) ]]; then
            read -rp "${YELLOW}请输入要拉取的完整版本标签 (例如: v1.0.2): ${NC}" selected_tag
            if [[ -n "$selected_tag" ]]; then
                break
            else
                echo -e "${RED}版本标签不能为空，请重新输入。${NC}"
            fi
        else
            echo -e "${RED}无效选项，请重新输入。${NC}"
        fi
    done
    export docker_img="germannewsmaker/nexterm:${selected_tag}"
    echo -e "${GREEN}已选择镜像：${docker_img}${NC}"
}


# 清理旧版本
clean_legacy() {
    echo -e "\n${GREEN}=== 清理旧版本 DDNS-GO ===${NC}"
    if docker inspect "$docker_name" &>/dev/null; then
        echo -e "${YELLOW}发现已存在容器 $docker_name${NC}"
        if confirm_operation "是否卸载当前版本（这将停止并删除容器和镜像）？"; then
            echo -e "${BLUE}停止并删除容器 $docker_name...${NC}"
            docker stop "$docker_name" >/dev/null 2>&1 || true
            docker rm -f "$docker_name" >/dev/null 2>&1 || true
            echo -e "${GREEN}容器已删除。${NC}"

            # 检查是否有相关镜像，并提示删除
            local current_img=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep "$IMAGE_NAME" | head -n 1) # 获取当前安装的镜像
            if [[ -n "$current_img" ]]; then
                if confirm_operation "是否删除镜像 ${current_img}？"; then
                    docker rmi "$current_img" >/dev/null 2>&1 || true
                    echo -e "${GREEN}镜像已删除。${NC}"
                else
                    echo -e "${YELLOW}镜像保留。${NC}"
                fi
            fi

            if [[ -d "$CONFIG_DIR" ]]; then
                if confirm_operation "是否删除持久化数据目录 ${CONFIG_DIR}？"; then
                    rm -rf "$CONFIG_DIR"
                    echo -e "${GREEN}持久化数据目录已删除。${NC}"
                else
                    echo -e "${YELLOW}持久化数据目录保留，方便下次部署加载。${NC}"
                fi
            fi

            echo -e "${BLUE}清理无用的网络和卷...${NC}"
            docker network prune -f >/dev/null 2>&1 || true
            docker volume prune -f >/dev/null 2>&1 || true
            echo -e "${GREEN}无用的网络和卷已清理。${NC}"
        else
            echo -e "${YELLOW}取消卸载操作。${NC}"
            return 1 # 返回非零，表示未执行清理
        fi
    else
        echo -e "${YELLOW}未发现需要清理的容器。${NC}"
    fi
    return 0 # 返回零，表示已完成清理或无需清理
}

# 镜像拉取
pull_image() {
    echo -e "\n${YELLOW}尝试拉取镜像 ${docker_img}...${NC}"
    if docker pull "$docker_img"; then
        echo -e "${GREEN}镜像拉取成功。${NC}"
    else
        echo -e "${RED}镜像拉取失败，请检查网络连接或镜像地址。${NC}"
        return 1
    fi
    return 0
}

# 容器启动
start_container() {
    echo -e "\n${YELLOW}启动容器 ${docker_name}...${NC}"
    local docker_run_cmd=""
    if [[ "$NETWORK_MODE" == "host" ]]; then
        docker_run_cmd="docker run -d \
            --name $docker_name \
            --network host \
            -v $CONFIG_DIR:/app/data \
            --restart unless-stopped \
            $docker_img"
    else
        docker_run_cmd="docker run -d \
            --name $docker_name \
            --network bridge \
            -v $CONFIG_DIR:/app/data \
            -p $PORT:$internal_port \
            --restart unless-stopped \
            $docker_img"
    fi

    echo -e "${BLUE}执行命令：${docker_run_cmd}${NC}"
    eval "$docker_run_cmd" || { echo -e "${RED}容器启动失败，请检查日志。${NC}"; return 1; }
    echo -e "${GREEN}容器启动成功。${NC}"
    return 0
}

# 部署验证
verify_deployment() {
    echo -e "\n${GREEN}验证部署状态...${NC}"
    if docker ps --format '{{.Names}}' | grep -q "^${docker_name}$"; then
        echo -e "容器状态: ${GREEN}运行中${NC}"

        local public_ip=$(curl -s --max-time 5 ifconfig.me || hostname -I | awk '{print $1}' | head -n1)
        # 如果是 host 模式，端口就是用户选择的 PORT
        # 如果是 bridge 模式，端口也是用户选择的 PORT
        local access_port=$PORT

        echo -e "\n${BLUE}访问地址:${NC}"
        if [[ -n "$public_ip" ]]; then
            echo -e "访问链接: ${GREEN}http://${public_ip}:${access_port}${NC}"
            echo -e "（请确保防火墙已开放端口 ${access_port}）"
        else
            echo -e "${YELLOW}未能获取到公网IP，请尝试使用内网IP访问。${NC}"
            echo -e "访问链接: ${GREEN}http://<您的服务器IP>:${access_port}${NC}"
        fi
        echo "数据目录：${YELLOW}$CONFIG_DIR${NC}"
        echo "使用以下命令检查容器日志：${BLUE}docker logs ${docker_name}${NC}"
        echo "使用以下命令停止容器：${BLUE}docker stop ${docker_name}${NC}"
    else
        echo -e "${RED}容器运行异常，请检查日志：${BLUE}docker logs ${docker_name}${NC}${NC}"
        return 1
    fi
    return 0
}

# 部署 Nexterm 主流程
deploy_nexterm() {
    echo -e "\n${GREEN}=== 部署 Nexterm ===${NC}"
    if ! check_docker; then
        echo -e "${RED}无法部署 Nexterm，请先安装 Docker。${NC}"
        return 1
    fi
    
    validate_and_set_port
    choose_network_mode
    select_docker_image_tag # 选择镜像版本

    # 在部署前询问是否清理旧版本
    if docker inspect "$docker_name" &>/dev/null; then
        if ! confirm_operation "检测到容器 $docker_name 存在，是否先卸载旧版本再部署新版本？"; then
            echo -e "${YELLOW}取消部署，请先手动处理旧版本或重新选择。${NC}"
            return 1
        fi
        # 如果用户同意卸载，则执行清理
        clean_legacy || { echo -e "${RED}旧版本清理失败，终止部署。${NC}"; return 1; }
    fi

    pull_image || { echo -e "${RED}镜像拉取失败，终止部署。${NC}"; return 1; }
    start_container || { echo -e "${RED}容器启动失败，终止部署。${NC}"; return 1; }
    verify_deployment || { echo -e "${RED}部署验证失败。${NC}"; return 1; }
    echo -e "${GREEN}Nexterm 部署流程完成。${NC}"
}


# 显示管理菜单
show_menu() {
    echo -e "\n${GREEN}=== Nexterm 管理菜单 ===${NC}"
    echo "1) 部署/重新配置 Nexterm"
    echo "2) 查看容器状态"
    echo "3) 查看访问地址"
    echo "4) 查看容器日志"
    echo "5) 停止容器"
    echo "6) 启动容器"
    echo "7) 卸载容器"
    echo "0) 退出"
}

# 主循环
main() {
    setup_logging
    # detect_system_and_architecture # 原始脚本有此功能，但与Docker部署非强相关，可按需保留或移除
    while true; do
        show_menu
        read -rp "请输入选项 [0-7]: " choice
        
        case $choice in
            1) deploy_nexterm ;;
            2) 
                echo -e "\n${BLUE}容器状态:${NC}"
                docker ps -a --filter "name=${docker_name}"
                ;;
            3)
                if docker ps --format '{{.Names}}' | grep -q "^${docker_name}$"; then
                    # 尝试从容器获取映射端口，如果是host网络，则直接用脚本保存的PORT
                    local current_host_port=$(docker inspect --format='{{(index (index .NetworkSettings.Ports "'${internal_port}/tcp'") 0).HostPort}}' "$docker_name" 2>/dev/null || echo "$PORT")
                    # Fallback to current script's PORT if inspect fails (e.g., host mode doesn't map a port in NetworkSettings.Ports explicitly)
                    current_host_port="${current_host_port:-$PORT}"

                    local public_ip=$(curl -s --max-time 5 ifconfig.me || hostname -I | awk '{print $1}' | head -n1)

                    echo -e "\n${GREEN}访问地址:${NC}"
                    if [[ -n "$public_ip" ]]; then
                        echo -e "公网访问: ${GREEN}http://${public_ip}:${current_host_port}${NC}"
                    else
                        echo -e "${YELLOW}未能获取到公网IP，请尝试使用内网IP访问。${NC}"
                    fi
                    echo -e "内网访问: ${GREEN}http://localhost:${current_host_port}${NC}"
                    echo -e "或使用服务器内网IP: ${GREEN}http://$(hostname -I | awk '{print $1}' | head -n1):${current_host_port}${NC}"
                else
                    echo -e "${RED}容器未运行或不存在！${NC}"
                fi
                ;;
            4)
                echo -e "\n${BLUE}容器日志:${NC}"
                docker logs "$docker_name"
                ;;
            5)
                echo -e "${YELLOW}尝试停止容器 ${docker_name}...${NC}"
                docker stop "$docker_name" >/dev/null 2>&1 && echo -e "${GREEN}容器已停止${NC}" || echo -e "${RED}停止失败或容器未运行${NC}"
                ;;
            6)
                echo -e "${YELLOW}尝试启动容器 ${docker_name}...${NC}"
                docker start "$docker_name" >/dev/null 2>&1 && echo -e "${GREEN}容器已启动${NC}" || echo -e "${RED}启动失败或容器不存在${NC}"
                ;;
            7)
                if confirm_operation "确定要卸载容器 ${docker_name} 及其相关数据吗？"; then
                    clean_legacy # 调用清理函数
                    echo -e "${GREEN}Nexterm 容器及相关数据已卸载清理完成。${NC}"
                else
                    echo -e "${YELLOW}取消卸载操作。${NC}"
                fi
                ;;
            0)
                echo -e "${BLUE}退出脚本。${NC}"; exit 0 ;;
            *)
                echo -e "${RED}无效选项，请重新选择。${NC}" ;;
        esac
        
        read -rp "${BLUE}按回车键继续...${NC}" dummy
    done
}

main
