#!/bin/bash

# ===========================
# OpenWrt Docker 一键管理脚本
# 更新日期：2024年6月
# 支持架构：x86_64/ARM64/ARMv7
# ===========================

# 权限检查
if [ "$EUID" -ne 0 ]; then
    echo -e "\033[31m请使用 root 用户运行本脚本！\033[0m"
    exit 1
fi

# Docker 存在性检查
if ! command -v docker &> /dev/null; then
    echo -e "\033[31m检测到 Docker 未安装，请先执行以下命令安装：\033[0m"
    echo "curl -fsSL https://get.docker.com | bash -s docker --mirror Aliyun"
    exit 1
fi

# 架构识别与镜像配置
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)
        DOCKER_IMAGE="sulinggg/openwrt:x86_64"
        ARCH_DESC="Intel/AMD 64位设备"
        ;;
    aarch64 | arm64)
        DOCKER_IMAGE="unifreq/openwrt-aarch64:latest"
        ARCH_DESC="ARM64 设备（树莓派4B/N1等）"
        ;;
    armv7l)
        DOCKER_IMAGE="zzsrv/openwrt:latest"
        ARCH_DESC="ARMv7 设备（NanoPi R2S/R4S等）"
        ;;
    *)
        echo -e "\033[31m不支持的架构：$ARCH\033[0m"
        exit 1
        ;;
esac

# 网络配置参数
DEFAULT_SUBNET="192.168.1.0/24"
DEFAULT_GATEWAY="192.168.1.1"

# 输出系统信息
clear
echo -e "\033[34m====================================\033[0m"
echo -e "系统架构：\033[32m$ARCH_DESC\033[0m"
echo -e "使用镜像：\033[33m$DOCKER_IMAGE\033[0m"
echo -e "\033[34m====================================\033[0m"

# 主控制菜单
while true; do
    echo ""
    echo -e "\033[36m[ 主菜单 ]\033[0m"
    echo "1) 安装 OpenWrt 容器"
    echo "2) 完全卸载 OpenWrt"
    echo "3) 查看容器状态"
    echo "4) 查看实时日志"
    echo "5) 退出脚本"
    read -rp "请输入操作编号 (1-5): " ACTION

    case "$ACTION" in
        1)
            # 网络模式选择
            echo -e "\n\033[33m» 网络模式选择 «\033[0m"
            echo "1) Bridge 模式（默认Docker网络，适合测试）"
            echo "2) Macvlan 模式（独立IP，适合旁路由）"
            read -rp "请选择网络类型 [1/2]: " NET_MODE
            NET_MODE=${NET_MODE:-1}

            # 自动获取默认网卡
            DEFAULT_NIC=$(ip -o -4 route show to default | awk '{print $5}' | head -n1)
            
            # 网络配置
            if [ "$NET_MODE" -eq 2 ]; then
                echo -e "\n\033[33m» Macvlan 参数配置 «\033[0m"
                read -rp "输入子网地址 [默认: $DEFAULT_SUBNET]: " SUBNET
                SUBNET=${SUBNET:-$DEFAULT_SUBNET}
                read -rp "输入网关地址 [默认: $DEFAULT_GATEWAY]: " GATEWAY
                GATEWAY=${GATEWAY:-$DEFAULT_GATEWAY}
                read -rp "绑定物理网卡 [默认: $DEFAULT_NIC]: " TARGET_NIC
                TARGET_NIC=${TARGET_NIC:-$DEFAULT_NIC}

                # 创建Macvlan网络
                if ! docker network create -d macvlan \
                    --subnet="$SUBNET" \
                    --gateway="$GATEWAY" \
                    -o parent="$TARGET_NIC" \
                    openwrt_net >/dev/null 2>&1; then
                    echo -e "\033[31mMacvlan网络创建失败！\033[0m"
                    exit 1
                fi
                NET_NAME="openwrt_net"
            else
                if ! docker network create openwrt_bridge >/dev/null 2>&1; then
                    echo -e "\033[31mBridge网络创建失败！\033[0m"
                    exit 1
                fi
                NET_NAME="openwrt_bridge"
            fi

            # 端口映射配置
            echo -e "\n\033[33m» 端口映射配置 «\033[0m"
            read -rp "是否需要映射Web访问端口？[y/N]: " NEED_PORT
            if [[ "$NEED_PORT" =~ [Yy] ]]; then
                read -rp "输入Web管理端口（默认80→8080）: " WEB_PORT
                WEB_PORT=${WEB_PORT:-8080}
                read -rp "输入SSH管理端口（默认22→2222）: " SSH_PORT
                SSH_PORT=${SSH_PORT:-2222}
                PORT_MAP="-p $WEB_PORT:80 -p $SSH_PORT:22"
            else
                PORT_MAP=""
            fi

            # 持久化存储配置
            echo -e "\n\033[33m» 数据持久化配置 «\033[0m"
            read -rp "是否需要挂载配置文件？[y/N]: " NEED_VOLUME
            if [[ "$NEED_VOLUME" =~ [Yy] ]]; then
                read -rp "输入配置存储路径（默认/opt/openwrt/config）: " CONFIG_PATH
                CONFIG_PATH=${CONFIG_PATH:-/opt/openwrt/config}
                mkdir -p "$CONFIG_PATH"
                VOLUME_MAP="-v $CONFIG_PATH:/etc/config"
            else
                VOLUME_MAP=""
            fi

            # 容器部署
            echo -e "\n\033[36m正在拉取镜像，请稍候...\033[0m"
            if ! docker pull "$DOCKER_IMAGE"; then
                echo -e "\033[31m镜像拉取失败，请检查网络连接！\033[0m"
                exit 1
            fi

            echo -e "\n\033[36m正在启动 OpenWrt 容器...\033[0m"
            if docker run -d --name openwrt \
                --network "$NET_NAME" \
                --restart unless-stopped \
                --privileged \
                $PORT_MAP \
                $VOLUME_MAP \
                "$DOCKER_IMAGE" >/dev/null 2>&1; then
                echo -e "\033[32m容器启动成功！\033[0m"
                echo -e "管理命令：\ndocker exec -it openwrt /bin/sh"
                [ -n "$WEB_PORT" ] && echo -e "Web访问地址：http://<IP地址>:$WEB_PORT"
            else
                echo -e "\033[31m容器启动失败！\033[0m"
                exit 1
            fi
            ;;

        2)
            echo -e "\n\033[33m正在执行完全卸载...\033[0m"
            docker stop openwrt >/dev/null 2>&1
            docker rm openwrt >/dev/null 2>&1
            docker network rm openwrt_net >/dev/null 2>&1
            docker network rm openwrt_bridge >/dev/null 2>&1
            echo -e "\033[32m所有容器及网络配置已清除！\033[0m"
            ;;

        3)
            echo -e "\n\033[36m容器状态：\033[0m"
            docker ps -a --filter name=openwrt --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}"
            ;;

        4)
            echo -e "\n\033[36m实时日志查看（Ctrl+C退出）\033[0m"
            docker logs -f openwrt
            ;;

        5)
            echo -e "\n\033[33m感谢使用，再见！\033[0m"
            exit 0
            ;;

        *)
            echo -e "\n\033[31m无效的输入，请重新选择！\033[0m"
            ;;
    esac
done
 
