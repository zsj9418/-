#!/bin/bash

# ===========================
# OpenWrt Docker 一键管理脚本
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

# --- Helper Function to get Host IP ---
get_host_ip() {
    # Try various methods to get a non-loopback LAN IP
    local ip_addr
    ip_addr=$(ip -o -4 addr show | awk '!/^[0-9]*: ?lo|link\/ether/ {gsub("/", " "); print $4}' | grep -v '172.*' | head -n1) # Exclude docker bridges typically starting with 172
    if [[ -z "$ip_addr" ]]; then
       ip_addr=$(hostname -I | awk '{print $1}')
    fi
     if [[ -z "$ip_addr" ]]; then
       ip_addr="<无法自动获取宿主机IP>"
    fi
    echo "$ip_addr"
}


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
    echo "5) 查看登录地址" # 新增选项
    echo "6) 退出脚本"     # 原退出选项顺延
    read -rp "请输入操作编号 (1-6): " ACTION # 修改提示范围

    case "$ACTION" in
        1)
            # --- 安装逻辑 (保持不变) ---
            echo -e "\n\033[33m» 网络模式选择 «\033[0m"
            echo "1) Bridge 模式（默认Docker网络，适合测试）"
            echo "2) Macvlan 模式（独立IP，适合旁路由）"
            read -rp "请选择网络类型 [1/2, 默认1]: " NET_MODE
            NET_MODE=${NET_MODE:-1}

            DEFAULT_NIC=$(ip -o -4 route show to default | awk '{print $5}' | head -n1)

            if [ "$NET_MODE" -eq 2 ]; then
                echo -e "\n\033[33m» Macvlan 参数配置 «\033[0m"
                read -rp "输入子网地址 [默认: $DEFAULT_SUBNET]: " SUBNET
                SUBNET=${SUBNET:-$DEFAULT_SUBNET}
                read -rp "输入网关地址 [默认: $DEFAULT_GATEWAY]: " GATEWAY
                GATEWAY=${GATEWAY:-$DEFAULT_GATEWAY}
                read -rp "绑定物理网卡 [默认: $DEFAULT_NIC]: " TARGET_NIC
                TARGET_NIC=${TARGET_NIC:-$DEFAULT_NIC}

                # 检查并尝试创建Macvlan网络
                if ! docker network inspect openwrt_net >/dev/null 2>&1; then
                    echo "正在创建 Macvlan 网络 'openwrt_net'..."
                    if ! docker network create -d macvlan \
                        --subnet="$SUBNET" \
                        --gateway="$GATEWAY" \
                        -o parent="$TARGET_NIC" \
                        openwrt_net; then
                        echo -e "\033[31mMacvlan网络创建失败！请检查参数或网卡名称。\033[0m"
                        continue # 返回主菜单
                    fi
                else
                    echo "Macvlan 网络 'openwrt_net' 已存在。"
                fi
                NET_NAME="openwrt_net"
            else
                 # 检查并尝试创建Bridge网络
                if ! docker network inspect openwrt_bridge >/dev/null 2>&1; then
                    echo "正在创建 Bridge 网络 'openwrt_bridge'..."
                    if ! docker network create openwrt_bridge >/dev/null 2>&1; then
                       echo -e "\033[31mBridge网络创建失败！\033[0m"
                       continue # 返回主菜单
                    fi
                else
                     echo "Bridge 网络 'openwrt_bridge' 已存在。"
                fi
                NET_NAME="openwrt_bridge"
            fi

            echo -e "\n\033[33m» 端口映射配置 «\033[0m"
            read -rp "是否需要映射Web和SSH访问端口？[y/N]: " NEED_PORT
            if [[ "$NEED_PORT" =~ [Yy] ]]; then
                read -rp "输入映射到宿主机的 Web 管理端口 [默认: 8080 (对应容器80)]: " WEB_PORT
                WEB_PORT=${WEB_PORT:-8080}
                read -rp "输入映射到宿主机的 SSH 管理端口 [默认: 2222 (对应容器22)]: " SSH_PORT
                SSH_PORT=${SSH_PORT:-2222}
                PORT_MAP="-p $WEB_PORT:80 -p $SSH_PORT:22"
            else
                PORT_MAP=""
                WEB_PORT="" # 清空变量以便后续判断
                SSH_PORT="" # 清空变量以便后续判断
            fi

            echo -e "\n\033[33m» 数据持久化配置 «\033[0m"
            read -rp "是否需要挂载配置文件到宿主机？[y/N]: " NEED_VOLUME
            if [[ "$NEED_VOLUME" =~ [Yy] ]]; then
                read -rp "输入宿主机配置存储路径 [默认: /opt/openwrt/config]: " CONFIG_PATH
                CONFIG_PATH=${CONFIG_PATH:-/opt/openwrt/config}
                mkdir -p "$CONFIG_PATH"
                VOLUME_MAP="-v $CONFIG_PATH:/etc/config"
            else
                VOLUME_MAP=""
            fi

            # 检查容器是否已存在
            if docker ps -a --format '{{.Names}}' | grep -q "^openwrt$"; then
                echo -e "\n\033[33m警告：名为 'openwrt' 的容器已存在。\033[0m"
                read -rp "是否要先删除现有容器再继续？[y/N]: " REMOVE_EXISTING
                if [[ "$REMOVE_EXISTING" =~ [Yy] ]]; then
                    echo "正在停止并删除现有容器..."
                    docker stop openwrt >/dev/null 2>&1
                    docker rm openwrt >/dev/null 2>&1
                    echo "现有容器已删除。"
                else
                    echo "安装中止。"
                    continue # 返回主菜单
                fi
            fi

            echo -e "\n\033[36m正在拉取镜像 '$DOCKER_IMAGE'，请稍候...\033[0m"
            if ! docker pull "$DOCKER_IMAGE"; then
                echo -e "\033[31m镜像拉取失败，请检查网络连接或镜像名称！\033[0m"
                continue # 返回主菜单
            fi

            echo -e "\n\033[36m正在启动 OpenWrt 容器...\033[0m"
            # 使用 eval 来正确处理可能为空的 $PORT_MAP 和 $VOLUME_MAP
             if eval docker run -d --name openwrt \
                --network "$NET_NAME" \
                --restart unless-stopped \
                --privileged \
                $PORT_MAP \
                $VOLUME_MAP \
                "$DOCKER_IMAGE"; then
                echo -e "\033[32m容器启动成功！\033[0m"
                echo -e "管理命令：\ndocker exec -it openwrt /bin/sh"
                # 启动后立即尝试显示登录信息
                 echo -e "\n\033[36m正在尝试获取登录地址...\033[0m"
                 sleep 5 # 等待容器网络初始化
                 bash "$0" 5 # 调用自身脚本执行选项5
            else
                echo -e "\033[31m容器启动失败！请检查 Docker 日志。\033[0m"
                echo "尝试运行: docker logs openwrt"
            fi
            ;;

        2)
            echo -e "\n\033[33m警告：这将停止并删除 OpenWrt 容器及其相关的 Macvlan/Bridge 网络。\033[0m"
            read -rp "确定要完全卸载吗？[y/N]: " CONFIRM_UNINSTALL
            if [[ "$CONFIRM_UNINSTALL" =~ [Yy] ]]; then
                echo -e "\n\033[33m正在执行完全卸载...\033[0m"
                docker stop openwrt >/dev/null 2>&1
                docker rm openwrt >/dev/null 2>&1
                docker network rm openwrt_net >/dev/null 2>&1
                docker network rm openwrt_bridge >/dev/null 2>&1
                 # 可选：询问是否删除挂载的配置目录
                read -rp "是否同时删除挂载的配置目录（如果之前设置过）？[y/N]: " DELETE_VOLUME_DIR
                if [[ "$DELETE_VOLUME_DIR" =~ [Yy] ]]; then
                    # 需要找到之前设置的 CONFIG_PATH，脚本当前状态无法直接获取，提示用户手动删除
                    echo -e "\033[33m请手动删除您之前指定的配置目录 (例如: /opt/openwrt/config)\033[0m"
                    # 或者，如果每次都用默认值，可以尝试删除默认值
                    # rm -rf /opt/openwrt/config
                fi
                echo -e "\033[32mOpenWrt 容器及相关网络已清除！\033[0m"
            else
                echo "卸载操作已取消。"
            fi
            ;;

        3)
            echo -e "\n\033[36m容器状态：\033[0m"
            docker ps -a --filter name=openwrt --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}"
            ;;

        4)
            echo -e "\n\033[36m实时日志查看（Ctrl+C退出）\033[0m"
            if ! docker logs -f openwrt; then
                 echo -e "\033[31m无法获取日志，容器 'openwrt' 可能不存在或未运行。\033[0m"
            fi
            ;;

        5)
            # --- 新增：查看登录地址逻辑 ---
            echo -e "\n\033[36m正在查询 OpenWrt 容器登录信息...\033[0m"
            CONTAINER_ID=$(docker ps -q --filter name=openwrt)

            if [ -z "$CONTAINER_ID" ]; then
                echo -e "\033[31m错误：未找到正在运行的名为 'openwrt' 的容器。\033[0m"
                continue
            fi

            # 获取容器详细信息
            INSPECT_JSON=$(docker inspect "$CONTAINER_ID")

            # 检查 jq 是否安装，jq 更方便解析 JSON
            if command -v jq &> /dev/null; then
                # 使用 jq 解析
                NET_INFO=$(echo "$INSPECT_JSON" | jq -r '.[0].NetworkSettings.Networks | keys[] as $k | if .[$k].IPAddress and .[$k].IPAddress != "" then "\($k):\(.[$k].IPAddress)" else empty end' | head -n 1)
                WEB_HOST_PORT=$(echo "$INSPECT_JSON" | jq -r '.[0].HostConfig.PortBindings."80/tcp"[0].HostPort // empty')
                SSH_HOST_PORT=$(echo "$INSPECT_JSON" | jq -r '.[0].HostConfig.PortBindings."22/tcp"[0].HostPort // empty')
            else
                 echo -e "\033[33m提示：未安装 jq，将使用 grep/awk 尝试解析，结果可能不精确。建议安装 jq (例: apt install jq)。\033[0m"
                # 使用 grep/awk 尝试解析 (兼容性更好，但可能不够健壮)
                # 查找第一个非空的 IP 地址及其网络名
                 NET_INFO=$(echo "$INSPECT_JSON" | grep -E '"IPAddress":\s*"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' -B 5 | grep -Eo '"(openwrt_net|openwrt_bridge)":|"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' | sed 's/"//g' | tr '\n' ':' | sed 's/:$//' | head -n 1)
                # 解析端口 (这种方式比较脆弱)
                WEB_HOST_PORT=$(echo "$INSPECT_JSON" | grep -A 2 '"80/tcp"' | grep '"HostPort":' | sed -n 's/.*"HostPort": "\(.*\)".*/\1/p' | head -n 1)
                SSH_HOST_PORT=$(echo "$INSPECT_JSON" | grep -A 2 '"22/tcp"' | grep '"HostPort":' | sed -n 's/.*"HostPort": "\(.*\)".*/\1/p' | head -n 1)
            fi

            # 从 NET_INFO 中分离网络名和容器IP
            NETWORK_NAME=$(echo "$NET_INFO" | cut -d':' -f1)
            CONTAINER_IP=$(echo "$NET_INFO" | cut -d':' -f2)

            ACCESS_IP=""
            ACCESS_MODE=""

            if [ "$NETWORK_NAME" == "openwrt_net" ]; then
                ACCESS_IP="$CONTAINER_IP"
                ACCESS_MODE="Macvlan (独立IP)"
            elif [ "$NETWORK_NAME" == "openwrt_bridge" ]; then
                HOST_IP=$(get_host_ip)
                ACCESS_IP="$HOST_IP"
                ACCESS_MODE="Bridge (通过宿主机IP访问)"
            else
                echo -e "\033[31m错误：无法确定容器的网络模式或IP地址。\033[0m"
                continue
            fi

            echo -e "\n\033[34m--- OpenWrt 登录信息 ---\033[0m"
            echo -e "网络模式 : \033[33m$ACCESS_MODE\033[0m"
            if [ "$NETWORK_NAME" == "openwrt_bridge" ]; then
                 echo -e "宿主机 IP : \033[32m$HOST_IP\033[0m"
                 echo -e "容器桥接IP: \033[37m$CONTAINER_IP (通常仅用于容器间通信)\033[0m"
            else
                 echo -e "容器 IP  : \033[32m$ACCESS_IP\033[0m"
            fi

            if [ -n "$WEB_HOST_PORT" ]; then
                echo -e "Web 访问 : \033[32mhttp://$ACCESS_IP:$WEB_HOST_PORT\033[0m"
            else
                echo -e "Web 访问 : \033[37m未映射端口\033[0m"
            fi
            echo -e "Web 用户名: \033[32mroot\033[0m"
            echo -e "Web 密码  : \033[33m(通常为空，首次登录设置；或尝试 'password')\033[0m"

            if [ -n "$SSH_HOST_PORT" ]; then
                echo -e "SSH 连接 : \033[32mssh root@$ACCESS_IP -p $SSH_HOST_PORT\033[0m"
            else
                echo -e "SSH 连接 : \033[37m未映射端口\033[0m"
            fi
            echo -e "SSH 密码  : \033[33m(与Web密码相同)\033[0m"
            echo -e "\033[34m------------------------\033[0m"

            ;;

        6) # 原退出选项
            echo -e "\n\033[33m感谢使用，再见！\033[0m"
            exit 0
            ;;

        *)
            echo -e "\n\033[31m无效的输入，请重新选择！\033[0m"
            ;;
    esac
done
