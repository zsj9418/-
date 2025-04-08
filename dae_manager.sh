#!/bin/bash

# 脚本保存目录
INSTALL_DIR="/usr/local/bin"
SCRIPT_NAME="dae_manager.sh"
CONFIG_FILE="/etc/dae/config.dae"
LOG_FILE="/var/log/dae.log"
LOG_SIZE_LIMIT=$((1 * 1024 * 1024)) # 1MB in bytes
ENV_FILE="$HOME/.dae_env" # 环境变量文件
DOCKER_CONFIG_DIR="/etc/dae" # Docker映射的配置目录

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# 检查是否为root用户
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}请以root权限运行此脚本（使用sudo）${NC}"
        exit 1
    fi
}

# 检查是否在容器环境中
check_container() {
    if [ -f /.dockerenv ] || grep -qE 'docker|lxc|kubepods' /proc/1/cgroup; then
        echo -e "${RED}检测到容器环境，dae不支持直接在容器中运行！${NC}"
        echo -e "${YELLOW}请使用选项6在Docker中安装，或切换到非容器环境（如KVM虚拟机）${NC}"
        return 1
    fi
    return 0
}

# 检查系统架构和依赖（只在首次运行时执行）
check_system() {
    if [ -f "/etc/dae/.setup_done" ]; then
        return 0 # 已安装依赖，跳过检查
    fi

    echo -e "${YELLOW}正在检查系统环境...${NC}"
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH_TYPE="amd64" ;;
        aarch64) ARCH_TYPE="arm64" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${NC}"; exit 1 ;;
    esac

    # 检测系统类型
    if [ -f /etc/debian_version ]; then
        OS="debian"
        PKG_MANAGER="apt"
    elif [ -f /etc/redhat-release ]; then
        OS="centos"
        PKG_MANAGER="yum"
    else
        echo -e "${RED}不支持的系统${NC}"
        exit 1
    fi

    # 安装必要依赖
    echo -e "${YELLOW}安装依赖...${NC}"
    if [ "$PKG_MANAGER" = "apt" ]; then
        apt update -y
        apt install -y wget curl nano iproute2
    elif [ "$PKG_MANAGER" = "yum" ]; then
        yum install -y wget curl nano iproute2
    fi

    # 标记依赖已安装
    mkdir -p /etc/dae
    touch /etc/dae/.setup_done
}

# 检查Docker是否安装
check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${YELLOW}Docker未安装，正在安装...${NC}"
        if [ -f /etc/debian_version ]; then
            apt update -y
            apt install -y docker.io
        elif [ -f /etc/redhat-release ]; then
            yum install -y docker
        fi
        systemctl start docker
        systemctl enable docker
    fi
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${RED}Docker安装失败，请手动安装后重试${NC}"
        return 1
    fi
    return 0
}

# 检查日志大小并清空
check_log_size() {
    if [ -f "$LOG_FILE" ]; then
        LOG_SIZE=$(stat -c%s "$LOG_FILE")
        if [ "$LOG_SIZE" -gt "$LOG_SIZE_LIMIT" ]; then
            echo -e "${YELLOW}日志文件超过1MB，正在清空...${NC}"
            > "$LOG_FILE"
        fi
    fi
}

# 加载环境变量
load_env() {
    if [ -f "$ENV_FILE" ]; then
        source "$ENV_FILE"
    fi
}

# 保存环境变量
save_env() {
    local key=$1
    local value=$2
    if [ ! -f "$ENV_FILE" ]; then
        touch "$ENV_FILE"
    fi
    if grep -q "^$key=" "$ENV_FILE"; then
        sed -i "s|^$key=.*|$key=\"$value\"|" "$ENV_FILE"
    else
        echo "$key=\"$value\"" >> "$ENV_FILE"
    fi
}

# 安装dae（非Docker）
install_dae() {
    if ! check_container; then
        return 1
    fi
    echo -e "${YELLOW}正在安装dae...${NC}"
    bash -c "$(wget -qO- https://raw.githubusercontent.com/daeuniverse/dae-installer/main/installer.sh)" || {
        echo -e "${RED}安装失败，请检查环境或稍后重试${NC}"
        return 1
    }
    echo -e "${GREEN}dae安装成功${NC}"
}

# 在Docker中安装和配置dae
install_dae_docker() {
    echo -e "${YELLOW}正在准备在Docker中安装dae...${NC}"
    echo -e "${RED}警告：dae官方不支持容器环境，安装可能不稳定，建议使用非容器环境！${NC}"
    echo -e "是否继续？(y/n，默认n)"
    read -r continue_docker
    if [ "$continue_docker" != "y" ] && [ "$continue_docker" != "Y" ]; then
        echo -e "${YELLOW}已取消Docker安装${NC}"
        return 0
    fi

    # 检查eBPF支持
    if ! check_ebpf_support; then
        return 1
    fi

    # 检查Docker
    if ! check_docker; then
        return 1
    fi

    # 检查内核版本
    KERNEL_VERSION=$(uname -r | cut -d. -f1-2)
    if [ "$(echo "$KERNEL_VERSION < 5.17" | bc -l)" -eq 1 ]; then
        echo -e "${RED}主机内核版本($KERNEL_VERSION)低于5.17，dae可能无法正常运行！${NC}"
        echo -e "${YELLOW}建议升级内核或更换服务器${NC}"
    fi

    # 自定义镜像
    echo -e "${YELLOW}请输入Docker镜像（默认ubuntu:22.04）：${NC}"
    read -r DOCKER_IMAGE
    DOCKER_IMAGE=${DOCKER_IMAGE:-ubuntu:22.04}

    # 清理旧容器
    if docker ps -a | grep -q dae; then
        echo -e "${YELLOW}检测到已有dae容器，正在清理...${NC}"
        docker rm -f dae
    fi

    # 拉取镜像
    echo -e "${YELLOW}拉取镜像 $DOCKER_IMAGE...${NC}"
    docker pull "$DOCKER_IMAGE" || {
        echo -e "${RED}拉取镜像失败，请检查网络${NC}"
        return 1
    }

    # 创建配置目录
    mkdir -p "$DOCKER_CONFIG_DIR"

    # 运行特权容器并安装dae
    echo -e "${YELLOW}在特权容器中安装dae...${NC}"
    docker run --rm --privileged --network=host -v /sys:/sys -v /dev:/dev -v "$DOCKER_CONFIG_DIR:/etc/dae" "$DOCKER_IMAGE" /bin/bash -c "
        apt update -y &&
        apt install -y wget &&
        bash -c \"\$(wget -qO- https://raw.githubusercontent.com/daeuniverse/dae-installer/main/installer.sh)\" &&
        echo 'dae installed in container'
    " || {
        echo -e "${RED}Docker中安装dae失败，请检查日志或环境${NC}"
        return 1
    }

    # 配置订阅地址
    set_subscription_docker

    echo -e "${GREEN}Docker中dae安装和配置完成${NC}"
    echo -e "${YELLOW}运行dae：docker run -d --name dae --privileged --network=host -v /sys:/sys -v /dev:/dev -v $DOCKER_CONFIG_DIR:/etc/dae $DOCKER_IMAGE /usr/bin/dae run --config /etc/dae/config.dae${NC}"
}

# 在Docker中设置订阅地址
set_subscription_docker() {
    load_env # 加载已有环境变量

    # 如果已有订阅地址，提示用户
    if [ -n "$SUB_URL" ]; then
        echo -e "${YELLOW}当前订阅地址: $SUB_URL${NC}"
        echo -e "是否使用已有地址？(y/n，默认y)"
        read -r use_existing
        if [ "$use_existing" != "n" ] && [ "$use_existing" != "N" ]; then
            echo -e "${GREEN}将使用现有订阅地址${NC}"
        else
            SUB_URL=""
        fi
    fi

    # 如果没有订阅地址，提示输入
    if [ -z "$SUB_URL" ]; then
        echo -e "${YELLOW}请输入你的代理订阅地址（URL）：${NC}"
        read -r SUB_URL
        if [ -z "$SUB_URL" ]; then
            echo -e "${RED}订阅地址不能为空${NC}"
            return 1
        fi
        save_env "SUB_URL" "$SUB_URL"
    fi

    # 创建或更新Docker映射的配置文件
    echo -e "${YELLOW}生成Docker配置文件...${NC}"
    cat <<EOF > "$DOCKER_CONFIG_DIR/config.dae"
global {
  lan_interface: ""
  wan_interface: auto
  log_level: info
  allow_insecure: false
  auto_config_kernel_parameter: true
}

subscription {
  "$SUB_URL"
}

group {
  proxy {
    policy: min_moving_avg
  }
}

routing {
  dip(geoip:private) -> direct
  dip(geoip:cn) -> direct
  domain(geosite:cn) -> direct
  fallback: proxy
}
EOF

    # 如果已有Webhook地址，提示用户
    if [ -n "$WEBHOOK_URL" ]; then
        echo -e "${YELLOW}当前企业微信Webhook地址: $WEBHOOK_URL${NC}"
        echo -e "是否使用已有地址？(y/n，默认y)"
        read -r use_existing_webhook
        if [ "$use_existing_webhook" = "n" ] || [ "$use_existing_webhook" = "N" ]; then
            WEBHOOK_URL=""
        fi
    fi

    # 如果没有Webhook地址，提示输入
    if [ -z "$WEBHOOK_URL" ]; then
        echo -e "${YELLOW}请输入企业微信机器人Webhook地址（留空跳过）：${NC}"
        read -r WEBHOOK_URL
        if [ -n "$WEBHOOK_URL" ]; then
            save_env "WEBHOOK_URL" "$WEBHOOK_URL"
        fi
    fi

    # 发送企业微信通知
    if [ -n "$WEBHOOK_URL" ]; then
        curl -s -X POST -H 'Content-Type: application/json' -d '{"msgtype": "text", "text": {"content": "Docker中dae已配置完成"}}' "$WEBHOOK_URL" >/dev/null
        echo -e "${GREEN}企业微信通知已发送${NC}"
    else
        echo -e "${YELLOW}未提供Webhook地址，跳过通知${NC}"
    fi
}

# 设置订阅地址并发送企业微信通知（非Docker）
set_subscription() {
    load_env # 加载已有环境变量

    # 如果已有订阅地址，提示用户
    if [ -n "$SUB_URL" ]; then
        echo -e "${YELLOW}当前订阅地址: $SUB_URL${NC}"
        echo -e "是否使用已有地址？(y/n，默认y)"
        read -r use_existing
        if [ "$use_existing" != "n" ] && [ "$use_existing" != "N" ]; then
            echo -e "${GREEN}将使用现有订阅地址${NC}"
        else
            SUB_URL=""
        fi
    fi

    # 如果没有订阅地址，提示输入
    if [ -z "$SUB_URL" ]; then
        echo -e "${YELLOW}请输入你的代理订阅地址（URL）：${NC}"
        read -r SUB_URL
        if [ -z "$SUB_URL" ]; then
            echo -e "${RED}订阅地址不能为空${NC}"
            return 1
        fi
        save_env "SUB_URL" "$SUB_URL"
    fi

    # 检查配置文件是否存在
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${YELLOW}创建默认配置文件...${NC}"
        cat <<EOF > "$CONFIG_FILE"
global {
  lan_interface: ""
  wan_interface: auto
  log_level: info
  allow_insecure: false
  auto_config_kernel_parameter: true
}

subscription {
  "$SUB_URL"
}

group {
  proxy {
    policy: min_moving_avg
  }
}

routing {
  dip(geoip:private) -> direct
  dip(geoip:cn) -> direct
  domain(geosite:cn) -> direct
  fallback: proxy
}
EOF
    else
        # 更新订阅地址
        sed -i "s|subscription {.*|subscription {\n  \"$SUB_URL\"\n}|" "$CONFIG_FILE"
    fi

    # 重载配置
    dae reload || {
        echo -e "${RED}配置重载失败${NC}"
        return 1
    }

    # 启动服务
    systemctl start dae
    systemctl enable dae

    # 检查是否运行
    if systemctl is-active dae >/dev/null; then
        echo -e "${GREEN}dae已成功更新并启动${NC}"

        # 如果已有Webhook地址，提示用户
        if [ -n "$WEBHOOK_URL" ]; then
            echo -e "${YELLOW}当前企业微信Webhook地址: $WEBHOOK_URL${NC}"
            echo -e "是否使用已有地址？(y/n，默认y)"
            read -r use_existing_webhook
            if [ "$use_existing_webhook" = "n" ] || [ "$use_existing_webhook" = "N" ]; then
                WEBHOOK_URL=""
            fi
        fi

        # 如果没有Webhook地址，提示输入
        if [ -z "$WEBHOOK_URL" ]; then
            echo -e "${YELLOW}请输入企业微信机器人Webhook地址（留空跳过）：${NC}"
            read -r WEBHOOK_URL
            if [ -n "$WEBHOOK_URL" ]; then
                save_env "WEBHOOK_URL" "$WEBHOOK_URL"
            fi
        fi

        # 发送企业微信通知
        if [ -n "$WEBHOOK_URL" ]; then
            curl -s -X POST -H 'Content-Type: application/json' -d '{"msgtype": "text", "text": {"content": "dae已成功更新并启动"}}' "$WEBHOOK_URL" >/dev/null
            echo -e "${GREEN}企业微信通知已发送${NC}"
        else
            echo -e "${YELLOW}未提供Webhook地址，跳过通知${NC}"
        fi
    else
        echo -e "${RED}dae启动失败，请检查日志${NC}"
    fi
}

# 管理dae运行状态（非Docker）
manage_dae() {
    while true; do
        echo -e "\n${YELLOW}请选择操作：${NC}"
        echo "1) 启动dae"
        echo "2) 停止dae"
        echo "3) 查看运行状态"
        echo "4) 返回主菜单"
        echo -e "${YELLOW}请输入选项 (1-4，无需回车)：${NC}"
        read -n 1 -r choice
        echo ""
        case $choice in
            1)
                systemctl start dae
                echo -e "${GREEN}dae已启动${NC}"
                ;;
            2)
                systemctl stop dae
                echo -e "${GREEN}dae已停止${NC}"
                ;;
            3)
                systemctl status dae
                ;;
            4)
                break
                ;;
            *)
                echo -e "${RED}无效选项${NC}"
                ;;
        esac
    done
}

# 卸载dae（非Docker）
uninstall_dae() {
    echo -e "${YELLOW}正在卸载dae并清理文件...${NC}"
    systemctl stop dae 2>/dev/null
    systemctl disable dae 2>/dev/null
    rm -rf /usr/bin/dae /etc/dae /var/log/dae.log /etc/systemd/system/dae.service
    systemctl daemon-reload
    echo -e "${GREEN}dae已卸载并清理完成${NC}"
}

# 主菜单
main_menu() {
    while true; do
        check_log_size
        echo -e "\n${GREEN}=== dae管理脚本 ===${NC}"
        echo "1) 安装dae（非Docker）"
        echo "2) 设置订阅地址并发送企业微信通知（非Docker）"
        echo "3) 启动/停止/查看dae运行状态（非Docker）"
        echo "4) 卸载dae并清理（非Docker）"
        echo "5) 退出"
        echo "6) 在Docker中安装和配置dae"
        echo -e "${YELLOW}请输入选项 (1-6，无需回车)：${NC}"
        read -n 1 -r choice
        echo ""
        case $choice in
            1)
                install_dae
                ;;
            2)
                set_subscription
                ;;
            3)
                manage_dae
                ;;
            4)
                uninstall_dae
                ;;
            5)
                echo -e "${GREEN}退出脚本${NC}"
                exit 0
                ;;
            6)
                install_dae_docker
                ;;
            *)
                echo -e "${RED}无效选项，请输入1-6${NC}"
                ;;
        esac
    done
}

# 保存脚本到指定目录并设置权限
save_script() {
    if [ ! -f "$INSTALL_DIR/$SCRIPT_NAME" ]; then
        echo -e "${YELLOW}正在将脚本保存到 $INSTALL_DIR ...${NC}"
        cp "$0" "$INSTALL_DIR/$SCRIPT_NAME"
        chmod +x "$INSTALL_DIR/$SCRIPT_NAME"
        echo -e "${GREEN}脚本已保存到 $INSTALL_DIR/$SCRIPT_NAME，可直接运行 'dae_manager.sh' 调用${NC}"
    fi
}

# 主程序
check_root
check_system
save_script
main_menu
