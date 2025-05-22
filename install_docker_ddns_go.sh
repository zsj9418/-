#!/bin/bash

# 定义颜色代码
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 配置参数
DEFAULT_HOST_PORT=9876  # 默认主机端口
CONTAINER_PORT=9876     # 容器内部固定端口
CONFIG_DIR="/etc/ddns-go"
CONTAINER_NAME="ddns-go"
IMAGE_NAME="jeessy/ddns-go"

# 检查Docker是否安装
check_docker() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误：Docker 未安装！${NC}"
        return 1
    fi
    return 0
}

# 检查端口是否可用
check_port_available() {
    local port=$1
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        if ss -tuln | grep -q ":${port} "; then
            return 1
        fi
    else
        if lsof -i :"${port}" &> /dev/null; then
            return 1
        fi
    fi
    return 0
}

# 安装/配置DDNS-GO（修复端口映射）
install_ddns_go() {
    echo -e "\n${GREEN}=== 安装/配置 DDNS-GO ===${NC}"
    
    if ! check_docker; then
        echo -e "${RED}请先安装Docker后再运行此脚本${NC}"
        return 1
    fi
    
    # 获取用户指定的主机端口
    local host_port=$DEFAULT_HOST_PORT
    while true; do
        read -p "请输入主机映射端口 [默认: ${DEFAULT_HOST_PORT}]: " custom_port
        if [[ -z "$custom_port" ]]; then
            break
        elif [[ "$custom_port" =~ ^[0-9]+$ ]] && (( custom_port >= 1024 && custom_port <= 65535 )); then
            if check_port_available "$custom_port"; then
                host_port=$custom_port
                break
            else
                echo -e "${RED}端口 ${custom_port} 已被占用！${NC}"
            fi
        else
            echo -e "${RED}无效的端口号，请输入1024-65535之间的数字${NC}"
        fi
    done

    echo -e "\n${BLUE}端口映射配置:${NC}"
    echo -e "主机端口: ${YELLOW}${host_port}${NC} → 容器端口: ${YELLOW}${CONTAINER_PORT}${NC}"
    
    # 检查并删除现有容器
    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo -e "${YELLOW}发现已存在的容器，将先删除旧容器...${NC}"
        docker rm -f $CONTAINER_NAME >/dev/null 2>&1
    fi
    
    # 创建配置目录
    mkdir -p "$CONFIG_DIR"
    
    # 部署容器（固定容器内9876端口）
    echo -e "\n${GREEN}正在部署 DDNS-GO...${NC}"
    docker run -d \
        --name $CONTAINER_NAME \
        --restart=always \
        -p "${host_port}:${CONTAINER_PORT}" \
        -v "$CONFIG_DIR:/root" \
        $IMAGE_NAME

    # 等待容器启动
    sleep 3
    
    # 验证部署
    echo -e "\n${GREEN}验证部署状态...${NC}"
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo -e "容器状态: ${GREEN}运行中${NC}"
        echo -e "访问地址: ${YELLOW}http://<你的IP>:${host_port}${NC}"
        
        # 显示实际端口映射
        echo -e "\n${BLUE}实际端口映射:${NC}"
        docker port $CONTAINER_NAME
    else
        echo -e "${RED}容器启动失败！${NC}"
        echo -e "请检查日志: ${YELLOW}docker logs ${CONTAINER_NAME}${NC}"
    fi
}

# 显示管理菜单
show_menu() {
    echo -e "\n${GREEN}=== DDNS-GO 管理菜单 ===${NC}"
    echo "1) 安装/重新配置"
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
    while true; do
        show_menu
        read -p "请输入选项 [0-7]: " choice
        
        case $choice in
            1) install_ddns_go ;;
            2) 
                echo -e "\n${BLUE}容器状态:${NC}"
                docker ps -a --filter "name=${CONTAINER_NAME}"
                ;;
            3)
                if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
                    local port=$(docker inspect --format='{{(index (index .NetworkSettings.Ports "'${CONTAINER_PORT}/tcp'") 0).HostPort}}' $CONTAINER_NAME)
                    echo -e "\n${GREEN}访问地址:${NC}"
                    echo -e "http://localhost:${port}"
                    echo -e "或使用网络IP: http://$(hostname -I | awk '{print $1}'):${port}"
                else
                    echo -e "${RED}容器未运行！${NC}"
                fi
                ;;
            4)
                echo -e "\n${BLUE}容器日志:${NC}"
                docker logs $CONTAINER_NAME
                ;;
            5)
                docker stop $CONTAINER_NAME >/dev/null && echo -e "${YELLOW}容器已停止${NC}" || echo -e "${RED}停止失败${NC}"
                ;;
            6)
                docker start $CONTAINER_NAME >/dev/null && echo -e "${GREEN}容器已启动${NC}" || echo -e "${RED}启动失败${NC}"
                ;;
            7)
                read -p "确定要卸载吗？(y/n): " confirm
                if [[ "$confirm" == "y" ]]; then
                    docker rm -f $CONTAINER_NAME >/dev/null
                    echo -e "${GREEN}容器已卸载${NC}"
                fi
                ;;
            0)
                exit 0 ;;
            *)
                echo -e "${RED}无效选项${NC}" ;;
        esac
        
        read -p "按回车键继续..." dummy
    done
}

# 启动脚本
main