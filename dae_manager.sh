#!/bin/bash

# 脚本保存目录和文件路径
INSTALL_DIR="/usr/local/bin"
SCRIPT_NAME="dae_manager.sh"
CONFIG_FILE="/etc/dae/config.dae"
LOG_FILE="/var/log/dae.log"
LOG_SIZE_LIMIT=$((1 * 1024 * 1024)) # 1MB
ENV_FILE="$HOME/.dae_env"
DOCKER_CONFIG_DIR="/etc/dae"

# 全局变量
ARCH_TYPE=""

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

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
        echo -e "${YELLOW}请使用选项6在Docker中安装，或切换到非容器环境${NC}"
        return 1
    fi
    return 0
}

# 检查eBPF支持
check_ebpf_support() {
    if [ -f /sys/kernel/debug/tracing/events/bpf ] || command -v bpftool >/dev/null 2>&1; then
        return 0
    elif grep -q "CONFIG_BPF=y" /boot/config-$(uname -r) 2>/dev/null; then
        return 0
    else
        echo -e "${RED}主机内核不支持eBPF，dae可能无法运行！${NC}"
        echo -e "${YELLOW}请确保内核支持eBPF（CONFIG_BPF=y）${NC}"
        return 1
    fi
}

# 检查系统架构和依赖
check_system() {
    if [ -f "/etc/dae/.setup_done" ]; then
        return 0
    fi
    echo -e "${YELLOW}正在检查系统环境...${NC}"
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH_TYPE="amd64" ;;
        aarch64) ARCH_TYPE="arm64" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${NC}"; exit 1 ;;
    esac

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

    echo -e "${YELLOW}安装依赖...${NC}"
    if [ "$PKG_MANAGER" = "apt" ]; then
        apt update -y && apt install -y wget curl unzip nano iproute2 || {
            echo -e "${RED}依赖安装失败，请检查网络或包管理器${NC}"
            exit 1
        }
    elif [ "$PKG_MANAGER" = "yum" ]; then
        yum install -y wget curl unzip nano iproute2 || {
            echo -e "${RED}依赖安装失败，请检查网络或包管理器${NC}"
            exit 1
        }
    fi
    mkdir -p /etc/dae
    touch /etc/dae/.setup_done
}

# 检查Docker是否安装
check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${YELLOW}Docker未安装，正在安装...${NC}"
        if [ -f /etc/debian_version ]; then
            apt update -y && apt install -y docker.io || return 1
        elif [ -f /etc/redhat-release ]; then
            yum install -y docker || return 1
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
        LOG_SIZE=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
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
        chmod 0600 "$ENV_FILE"
    fi
    if grep -q "^$key=" "$ENV_FILE"; then
        sed -i "s|^$key=.*|$key=\"$value\"|" "$ENV_FILE"
    else
        echo "$key=\"$value\"" >> "$ENV_FILE"
    fi
}

# 清理网络资源
clean_network_resources() {
    echo -e "${YELLOW}清理现有网络资源以避免冲突...${NC}"
    sudo ip rule del fwmark 114514 2>/dev/null
    sudo ip route flush table 114514 2>/dev/null
    sudo ip link delete dae 2>/dev/null
    # 检查是否有其他dae相关进程
    if pgrep -f "/usr/bin/dae" >/dev/null; then
        echo -e "${YELLOW}检测到残留dae进程，正在终止...${NC}"
        sudo pkill -9 -f "/usr/bin/dae"
    fi
}

# 设置订阅地址
set_subscription() {
    load_env
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

    while [ -z "$SUB_URL" ]; do
        echo -e "${YELLOW}请输入你的代理订阅地址（URL）：${NC}"
        read -r SUB_URL
        if [ -z "$SUB_URL" ]; then
            echo -e "${RED}订阅地址不能为空，请重新输入${NC}"
        else
            save_env "SUB_URL" "$SUB_URL"
            break
        fi
    done

    # 更新配置文件
    if [ -f "$CONFIG_FILE" ]; then
        sed -i "s|subscription {.*|subscription {\n  \"$SUB_URL\"\n}|" "$CONFIG_FILE"
    else
        echo -e "${RED}配置文件 $CONFIG_FILE 不存在${NC}"
        return 1
    fi
    sudo chmod 0600 "$CONFIG_FILE"
}

# 安装dae（非Docker）
install_dae() {
    if ! check_container; then
        return 1
    fi
    if ! check_ebpf_support; then
        return 1
    fi
    echo -e "${YELLOW}正在清理旧文件并安装dae...${NC}"
    sudo rm -rf /usr/bin/dae /etc/dae /etc/systemd/system/dae.service /var/run/dae.pid /usr/local/bin/dae
    sudo systemctl daemon-reload

    ARCH=$(uname -m)
    case $ARCH in
        x86_64) DAE_URL="https://github.com/daeuniverse/dae/releases/download/v0.9.0/dae-linux-amd64.zip" ;;
        aarch64) DAE_URL="https://github.com/daeuniverse/dae/releases/download/v0.9.0/dae-linux-arm64.zip" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${NC}"; return 1 ;;
    esac

    echo -e "${YELLOW}下载并安装dae v0.9.0...${NC}"
    wget -O /tmp/dae.zip "$DAE_URL" || {
        echo -e "${RED}下载dae失败，请检查网络${NC}"
        return 1
    }
    unzip -o /tmp/dae.zip -d /tmp || {
        echo -e "${RED}解压dae失败，请检查unzip命令${NC}"
        return 1
    }

    echo -e "${YELLOW}解压后的文件：${NC}"
    ls -l /tmp/dae*

    if [ -f /tmp/dae-linux-"$ARCH_TYPE" ]; then
        echo -e "${YELLOW}移动 /tmp/dae-linux-$ARCH_TYPE 到 /usr/bin/dae...${NC}"
        sudo mv /tmp/dae-linux-"$ARCH_TYPE" /usr/bin/dae || {
            echo -e "${RED}移动 /tmp/dae-linux-$ARCH_TYPE 失败${NC}"
            return 1
        }
    elif [ -f /tmp/dae ]; then
        echo -e "${YELLOW}移动 /tmp/dae 到 /usr/bin/dae...${NC}"
        sudo mv /tmp/dae /usr/bin/dae || {
            echo -e "${RED}移动 /tmp/dae 失败${NC}"
            return 1
        }
    else
        echo -e "${RED}未找到dae二进制文件（预期为 /tmp/dae-linux-$ARCH_TYPE 或 /tmp/dae）${NC}"
        return 1
    fi

    sudo chmod +x /usr/bin/dae
    sudo mkdir -p /etc/dae
    sudo mv /tmp/geoip.dat /etc/dae/geoip.dat 2>/dev/null || wget -O /etc/dae/geoip.dat https://github.com/v2rayA/dist-v2ray-rules-dat/raw/master/geoip.dat || {
        echo -e "${RED}下载geoip.dat失败${NC}"
    }
    sudo mv /tmp/geosite.dat /etc/dae/geosite.dat 2>/dev/null || wget -O /etc/dae/geosite.dat https://github.com/v2rayA/dist-v2ray-rules-dat/raw/master/geosite.dat || {
        echo -e "${RED}下载geosite.dat失败${NC}"
    }
    sudo mv /tmp/dae.service /etc/systemd/system/dae.service 2>/dev/null || cat <<EOF | sudo tee /etc/systemd/system/dae.service
[Unit]
Description=dae Service
Documentation=https://github.com/daeuniverse/dae
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/dae run --config /etc/dae/config.dae
Restart=on-failure
PIDFile=/var/run/dae.pid

[Install]
WantedBy=multi-user.target
EOF

    # 生成初始配置文件
    echo -e "${YELLOW}生成初始配置文件...${NC}"
    cat <<EOF | sudo tee "$CONFIG_FILE"
global {
  lan_interface: ""
  wan_interface: auto
  log_level: info
  allow_insecure: false
  auto_config_kernel_parameter: true
}

subscription {
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
    sudo chmod 0600 "$CONFIG_FILE"

    # 设置订阅地址
    echo -e "${YELLOW}设置订阅地址...${NC}"
    set_subscription || {
        echo -e "${RED}订阅设置失败，请手动编辑 $CONFIG_FILE${NC}"
        return 1
    }

    # 清理网络资源
    clean_network_resources

    # 启动服务
    sudo systemctl daemon-reload
    sudo systemctl enable dae
    systemctl start dae || {
        echo -e "${RED}dae启动失败，请检查日志：journalctl -u dae${NC}"
        return 1
    }
    if systemctl is-active dae >/dev/null; then
        echo -e "${GREEN}dae安装并启动成功${NC}"
    else
        echo -e "${RED}dae启动失败，请检查日志：journalctl -u dae${NC}"
        return 1
    fi

    # 清理临时文件
    rm -f /tmp/dae* 2>/dev/null
}

# 在Docker中安装和配置dae
install_dae_docker() {
    if ! check_ebpf_support; then
        return 1
    fi
    if ! check_docker; then
        return 1
    fi
    echo -e "${YELLOW}正在准备在Docker中安装dae...${NC}"
    echo -e "${RED}警告：dae官方不支持容器环境，可能不稳定${NC}"
    echo -e "是否继续？(y/n，默认n)"
    read -r continue_docker
    if [ "$continue_docker" != "y" ] && [ "$continue_docker" != "Y" ]; then
        return 0
    fi

    KERNEL_VERSION=$(uname -r | cut -d. -f1-2)
    if [ "$(echo "$KERNEL_VERSION < 5.17" | bc -l)" -eq 1 ]; then
        echo -e "${RED}内核版本($KERNEL_VERSION)低于5.17，可能无法运行dae${NC}"
    fi

    echo -e "${YELLOW}请输入Docker镜像（默认ubuntu:22.04）：${NC}"
    read -r DOCKER_IMAGE
    DOCKER_IMAGE=${DOCKER_IMAGE:-ubuntu:22.04}

    if docker ps -a | grep -q dae; then
        echo -e "${YELLOW}清理旧dae容器...${NC}"
        docker rm -f dae
    fi

    echo -e "${YELLOW}拉取镜像 $DOCKER_IMAGE...${NC}"
    docker pull "$DOCKER_IMAGE" || {
        echo -e "${RED}拉取镜像失败，请检查网络${NC}"
        return 1
    }

    sudo mkdir -p "$DOCKER_CONFIG_DIR"
    docker run --rm --privileged --network=host -v /sys:/sys -v /dev:/dev -v "$DOCKER_CONFIG_DIR:/etc/dae" "$DOCKER_IMAGE" /bin/bash -c "
        apt update -y &&
        apt install -y wget unzip &&
        wget -O /tmp/dae.zip https://github.com/daeuniverse/dae/releases/download/v0.9.0/dae-linux-$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/').zip &&
        unzip -o /tmp/dae.zip -d /etc/dae &&
        mv /etc/dae/dae-linux-* /usr/bin/dae 2>/dev/null || mv /etc/dae/dae /usr/bin/dae &&
        chmod +x /usr/bin/dae &&
        wget -O /etc/dae/geoip.dat https://github.com/v2rayA/dist-v2ray-rules-dat/raw/master/geoip.dat &&
        wget -O /etc/dae/geosite.dat https://github.com/v2rayA/dist-v2ray-rules-dat/raw/master/geosite.dat &&
        echo 'dae installed in container'
    " || {
        echo -e "${RED}Docker安装dae失败，请检查日志${NC}"
        return 1
    }

    set_subscription_docker
    echo -e "${GREEN}Docker中dae安装和配置完成${NC}"
    echo -e "${YELLOW}运行dae：docker run -d --name dae --privileged --network=host --dns 8.8.8.8 -v /sys:/sys -v /dev:/dev -v $DOCKER_CONFIG_DIR:/etc/dae $DOCKER_IMAGE /usr/bin/dae run --config /etc/dae/config.dae${NC}"
}

# 设置订阅地址（Docker）
set_subscription_docker() {
    load_env
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

    while [ -z "$SUB_URL" ]; do
        echo -e "${YELLOW}请输入你的代理订阅地址（URL）：${NC}"
        read -r SUB_URL
        if [ -z "$SUB_URL" ]; then
            echo -e "${RED}订阅地址不能为空，请重新输入${NC}"
        else
            save_env "SUB_URL" "$SUB_URL"
            break
        fi
    done

    echo -e "${YELLOW}生成Docker配置文件...${NC}"
    cat <<EOF | sudo tee "$DOCKER_CONFIG_DIR/config.dae"
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
    sudo chmod 0600 "$DOCKER_CONFIG_DIR/config.dae"
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
                clean_network_resources
                systemctl start dae && echo -e "${GREEN}dae已启动${NC}" || echo -e "${RED}启动失败，请检查日志${NC}"
                ;;
            2) systemctl stop dae && echo -e "${GREEN}dae已停止${NC}" ;;
            3) systemctl status dae ;;
            4) break ;;
            *) echo -e "${RED}无效选项${NC}" ;;
        esac
    done
}

# 卸载dae（非Docker）
uninstall_dae() {
    echo -e "${YELLOW}正在卸载dae并清理文件...${NC}"
    systemctl stop dae 2>/dev/null
    systemctl disable dae 2>/dev/null
    clean_network_resources
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
            1) install_dae ;;
            2) set_subscription ;;
            3) manage_dae ;;
            4) uninstall_dae ;;
            5) echo -e "${GREEN}退出脚本${NC}"; exit 0 ;;
            6) install_dae_docker ;;
            *) echo -e "${RED}无效选项，请输入1-6${NC}" ;;
        esac
    done
}

# 保存脚本
save_script() {
    if [ ! -f "$INSTALL_DIR/$SCRIPT_NAME" ]; then
        echo -e "${YELLOW}保存脚本到 $INSTALL_DIR ...${NC}"
        cp "$0" "$INSTALL_DIR/$SCRIPT_NAME"
        chmod +x "$INSTALL_DIR/$SCRIPT_NAME"
        echo -e "${GREEN}脚本已保存，可运行 'dae_manager.sh' 调用${NC}"
    fi
}

# 主程序
check_root
check_system
save_script
main_menu
