#!/bin/bash

# ==============================================
# Lucky Docker 终极部署管理器 v4.0
# 功能：IPv6智能检测 | 双网络模式 | 全生命周期管理
# ==============================================

# 配置区
SCRIPT_NAME="Lucky Docker 终极部署管理器"
SCRIPT_VERSION="4.0"
CONTAINER_NAME="lucky"
IMAGE_NAME="gdy666/lucky"
CONFIG_DIR="/root/luckyconf"
CONTAINER_PORT=16601  # 容器内部固定端口

# 颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
RESET='\033[0m'

# 获取宿主机IP（兼容IPv4/IPv6）
get_host_ip() {
    IPV4=$(ip -4 addr show 2>/dev/null | grep -oP 'inet \K[\d.]+' | grep -v '127.0.0.1' | head -1)
    IPV6=$(ip -6 addr show 2>/dev/null | grep -oP 'inet6 \K[\da-f:]+' | grep -v '::1' | head -1)
}

# 检测IPv6支持
check_ipv6_support() {
    if ping6 -c1 2606:4700:4700::1111 &>/dev/null; then
        IPV6_SUPPORT=true
        echo -e "${CYAN}ℹ️ 系统支持IPv6，容器将同时监听IPv6${RESET}"
    else
        IPV6_SUPPORT=false
        echo -e "${YELLOW}⚠️ 系统未启用IPv6，容器仅支持IPv4${RESET}"
    fi
}

# 检查Docker
check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${YELLOW}❌ 未检测到Docker，尝试自动安装...${RESET}"
        if curl -fsSL https://get.docker.com | sh; then
            systemctl enable --now docker 2>/dev/null
            echo -e "${GREEN}✅ Docker安装成功${RESET}"
        else
            echo -e "${RED}❌ Docker安装失败，请手动安装后重试${RESET}"
            exit 1
        fi
    fi
}

# 部署容器
deploy_lucky() {
    clear
    echo -e "${GREEN}🚀 Lucky容器部署${RESET}"
    echo "--------------------------------------"

    # 检查容器是否已存在
    if docker inspect $CONTAINER_NAME &>/dev/null; then
        echo -e "${RED}❌ 容器已存在，请先卸载${RESET}"
        read -n1 -p "按任意键返回主菜单..."
        return
    fi

    # 创建配置目录
    mkdir -p "$CONFIG_DIR" || {
        echo -e "${RED}❌ 无法创建配置目录 $CONFIG_DIR${RESET}"
        return 1
    }

    # 选择网络模式
    echo -e "${BLUE}请选择网络模式：${RESET}"
    echo "1. Host模式 (高性能，直接使用宿主机网络)"
    echo "2. Bridge模式 (安全隔离，需要端口映射)"
    read -p "请输入选择 [1-2]: " NET_MODE

    case $NET_MODE in
        1)
            # Host模式部署
            echo -e "${YELLOW}⚠️ 警告：Host模式将直接暴露容器到宿主机网络${RESET}"
            read -p "是否继续？[y/N]: " CONFIRM
            [[ ! $CONFIRM =~ [yY] ]] && return

            echo -e "${CYAN}🔧 正在拉取镜像...${RESET}"
            docker pull $IMAGE_NAME || {
                echo -e "${RED}❌ 镜像拉取失败${RESET}"
                return 1
            }

            docker run -d \
                --name $CONTAINER_NAME \
                --restart=always \
                --net=host \
                -v $CONFIG_DIR:/goodluck \
                $IMAGE_NAME || {
                echo -e "${RED}❌ 容器启动失败${RESET}"
                return 1
            }

            echo -e "\n${GREEN}✅ Host模式部署成功！${RESET}"
            get_host_ip
            echo -e "\n${BLUE}📢 访问信息：${RESET}"
            [ -n "$IPV4" ] && echo -e "IPv4地址: ${GREEN}http://$IPV4:$CONTAINER_PORT${RESET}"
            [ "$IPV6_SUPPORT" = true ] && [ -n "$IPV6" ] && \
                echo -e "IPv6地址: ${GREEN}http://[$IPV6]:$CONTAINER_PORT${RESET}"
            ;;
        2)
            # Bridge模式部署
            while true; do
                read -p "请输入主机映射端口 [默认: $CONTAINER_PORT]: " HOST_PORT
                HOST_PORT=${HOST_PORT:-$CONTAINER_PORT}

                if [[ "$HOST_PORT" =~ ^[0-9]+$ ]] && [ "$HOST_PORT" -ge 1 ] && [ "$HOST_PORT" -le 65535 ]; then
                    # 检查端口冲突
                    if ss -tuln | grep -q ":$HOST_PORT "; then
                        echo -e "${RED}❌ 端口 $HOST_PORT 已被占用${RESET}"
                        continue
                    fi
                    break
                else
                    echo -e "${RED}❌ 请输入1-65535的有效端口${RESET}"
                fi
            done

            echo -e "${CYAN}🔧 正在拉取镜像...${RESET}"
            docker pull $IMAGE_NAME || {
                echo -e "${RED}❌ 镜像拉取失败${RESET}"
                return 1
            }

            docker run -d \
                --name $CONTAINER_NAME \
                --restart=always \
                -p $HOST_PORT:$CONTAINER_PORT \
                -v $CONFIG_DIR:/goodluck \
                $IMAGE_NAME || {
                echo -e "${RED}❌ 容器启动失败${RESET}"
                return 1
            }

            echo -e "\n${GREEN}✅ Bridge模式部署成功！${RESET}"
            get_host_ip
            echo -e "\n${BLUE}📢 访问信息：${RESET}"
            echo -e "端口映射: ${YELLOW}$HOST_PORT → $CONTAINER_PORT${RESET}"
            [ -n "$IPV4" ] && echo -e "IPv4地址: ${GREEN}http://$IPV4:$HOST_PORT${RESET}"
            [ "$IPV6_SUPPORT" = true ] && [ -n "$IPV6" ] && \
                echo -e "IPv6地址: ${GREEN}http://[$IPV6]:$HOST_PORT${RESET}"
            ;;
        *)
            echo -e "${RED}❌ 无效选择${RESET}"
            ;;
    esac

    echo -e "\n配置目录: ${YELLOW}$CONFIG_DIR${RESET}"
    read -n1 -p "按任意键返回主菜单..."
}

# 卸载容器
uninstall_lucky() {
    clear
    echo -e "${YELLOW}🗑️ 卸载Lucky容器${RESET}"
    echo "--------------------------------------"

    if docker inspect $CONTAINER_NAME &>/dev/null; then
        docker stop $CONTAINER_NAME 2>/dev/null
        docker rm $CONTAINER_NAME 2>/dev/null
        echo -e "${GREEN}✅ 容器已移除${RESET}"
    else
        echo -e "${YELLOW}⚠️ 容器不存在${RESET}"
    fi

    if [ -d "$CONFIG_DIR" ]; then
        read -p "是否删除配置目录？[y/N]: " CHOICE
        if [[ "$CHOICE" =~ [yY] ]]; then
            rm -rf "$CONFIG_DIR"
            echo -e "${GREEN}✅ 配置目录已删除${RESET}"
        fi
    fi

    read -n1 -p "按任意键返回主菜单..."
}

# 查看状态
show_status() {
    clear
    echo -e "${BLUE}🔍 容器状态${RESET}"
    echo "--------------------------------------"

    if docker inspect $CONTAINER_NAME &>/dev/null; then
        echo -e "${GREEN}● 容器已安装${RESET}"
        NET_MODE=$(docker inspect -f '{{.HostConfig.NetworkMode}}' $CONTAINER_NAME)
        STATE=$(docker inspect -f '{{.State.Status}}' $CONTAINER_NAME)
        
        echo -e "运行状态: ${YELLOW}$STATE${RESET}"
        echo -e "网络模式: ${YELLOW}$NET_MODE${RESET}"

        if [ "$NET_MODE" == "host" ]; then
            get_host_ip
            echo -e "\n${BLUE}📢 访问信息：${RESET}"
            [ -n "$IPV4" ] && echo -e "IPv4地址: ${GREEN}http://$IPV4:$CONTAINER_PORT${RESET}"
            [ "$IPV6_SUPPORT" = true ] && [ -n "$IPV6" ] && \
                echo -e "IPv6地址: ${GREEN}http://[$IPV6]:$CONTAINER_PORT${RESET}"
        else
            PORT_MAP=$(docker port $CONTAINER_NAME $CONTAINER_PORT/tcp 2>/dev/null | cut -d':' -f2)
            if [ -n "$PORT_MAP" ]; then
                get_host_ip
                echo -e "\n${BLUE}📢 访问信息：${RESET}"
                echo -e "端口映射: ${YELLOW}$PORT_MAP → $CONTAINER_PORT${RESET}"
                [ -n "$IPV4" ] && echo -e "IPv4地址: ${GREEN}http://$IPV4:$PORT_MAP${RESET}"
                [ "$IPV6_SUPPORT" = true ] && [ -n "$IPV6" ] && \
                    echo -e "IPv6地址: ${GREEN}http://[$IPV6]:$PORT_MAP${RESET}"
            fi
        fi
    else
        echo -e "${YELLOW}⚠️ 容器未安装${RESET}"
    fi

    read -n1 -p "按任意键返回主菜单..."
}

# 容器管理
manage_container() {
    clear
    echo -e "${CYAN}⚙️ 容器管理${RESET}"
    echo "--------------------------------------"

    if docker inspect $CONTAINER_NAME &>/dev/null; then
        CURRENT_STATE=$(docker inspect -f '{{.State.Status}}' $CONTAINER_NAME)
        echo -e "当前状态: ${YELLOW}$CURRENT_STATE${RESET}"
        
        echo -e "\n1. 启动容器"
        echo "2. 停止容器"
        echo "3. 重启容器"
        echo "4. 查看日志"
        echo "5. 返回主菜单"
        
        read -p "请选择操作 [1-5]: " OP
        case $OP in
            1) 
                docker start $CONTAINER_NAME
                echo -e "${GREEN}✅ 容器已启动${RESET}"
                ;;
            2) 
                docker stop $CONTAINER_NAME
                echo -e "${GREEN}✅ 容器已停止${RESET}"
                ;;
            3) 
                docker restart $CONTAINER_NAME
                echo -e "${GREEN}✅ 容器已重启${RESET}"
                ;;
            4)
                echo -e "${BLUE}📜 显示最后50行日志：${RESET}"
                docker logs --tail 50 $CONTAINER_NAME
                ;;
            5) return ;;
            *) echo -e "${RED}❌ 无效输入${RESET}" ;;
        esac
    else
        echo -e "${YELLOW}⚠️ 容器未安装${RESET}"
    fi
    
    read -n1 -p "按任意键返回主菜单..."
}

# 主菜单
main_menu() {
    clear
    echo -e "${BLUE}======================================${RESET}"
    echo -e "  ${GREEN}$SCRIPT_NAME v$SCRIPT_VERSION${RESET}"
    echo -e "${BLUE}======================================${RESET}"
    echo -e "1. 部署容器"
    echo -e "2. 卸载容器"
    echo -e "3. 查看状态"
    echo -e "4. 管理容器"
    echo -e "5. 退出"
    echo -e "${BLUE}======================================${RESET}"
}

# 主逻辑
main() {
    check_docker
    check_ipv6_support
    
    while true; do
        main_menu
        read -p "请选择操作 [1-5]: " CHOICE

        case $CHOICE in
            1) deploy_lucky ;;
            2) uninstall_lucky ;;
            3) show_status ;;
            4) manage_container ;;
            5) echo -e "${GREEN}👋 感谢使用，再见！${RESET}"; exit 0 ;;
            *) echo -e "${RED}❌ 无效选择${RESET}"; sleep 1 ;;
        esac
    done
}

main
