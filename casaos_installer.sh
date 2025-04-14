#!/bin/bash
# CasaOS 全架构部署脚本

# 定义颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# 全局变量
ARCH=""
CASAOS_INSTALL_TYPE="unknown" # 'standard', 'docker', 'unknown'
CASAOS_PORT=80
SCRIPT_LOG_FILE="/tmp/casaos_deploy_script.log"
DOCKER_CONFIG_FILE="/etc/docker/daemon.json"
APT_SOURCE_FILE="/etc/apt/sources.list"

# --- Utility Functions ---

# 日志记录
log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$SCRIPT_LOG_FILE"
}

# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 备份文件
backup_file() {
    local file_path="$1"
    if [ -f "$file_path" ]; then
        local backup_path="${file_path}.bak_$(date +%Y%m%d%H%M%S)"
        log "${YELLOW}[!] 备份文件: ${file_path} -> ${backup_path}${NC}"
        sudo cp "$file_path" "$backup_path" || log "${RED}[!] 备份文件 ${file_path} 失败!${NC}"
    fi
}

# 获取包管理器类型
get_package_manager() {
    if command_exists apt-get; then
        echo "apt"
    elif command_exists yum; then
        echo "yum"
    elif command_exists dnf; then
        echo "dnf"
    elif command_exists pacman; then
        echo "pacman"
    else
        echo "unknown"
    fi
}

# --- Core Logic Functions ---

# 检测 CasaOS 安装状态和类型
check_casaos_status() {
    CASAOS_INSTALL_TYPE="unknown"
    if command_exists casaos; then
        # 可能是标准安装
        if systemctl list-units --type=service | grep -q 'casaos.service\|casaos-gateway.service'; then
             log "${GREEN}[+] 检测到 CasaOS (标准安装或旧版)${NC}"
             CASAOS_INSTALL_TYPE="standard"
             # 尝试获取端口 (可能不准确，取决于版本和配置)
             CASAOS_PORT=$(sudo grep -Po 'Listen\s*:\s*\K[0-9]+' /etc/casaos/gateway.ini 2>/dev/null || echo 80)
             return 0
        fi
    fi
    # 检查 Docker 容器
    if command_exists docker && docker ps -a --format '{{.Names}}' | grep -q "^casaos$"; then
        log "${GREEN}[+] 检测到 CasaOS (Docker 部署)${NC}"
        CASAOS_INSTALL_TYPE="docker"
        # 尝试从 Docker 获取端口映射
        local port_mapping=$(docker port casaos 80/tcp | head -n 1)
        if [[ "$port_mapping" =~ :([0-9]+)$ ]]; then
            CASAOS_PORT="${BASH_REMATCH[1]}"
        else
             CASAOS_PORT=80 # Fallback
        fi
        return 0
    fi
    log "${YELLOW}[!] 未检测到有效的 CasaOS 安装${NC}"
    return 1
}

# 检测系统架构
detect_arch() {
    case "$(uname -m)" in
        x86_64)  ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        armv7l)  ARCH="armv7" ;;
        *)       log "${RED}[!] 不支持的架构: $(uname -m)${NC}"; exit 1 ;;
    esac
    log "${CYAN}[+] 检测到系统架构: ${YELLOW}${ARCH}${NC}"
}

# 安装必要依赖
install_dependencies() {
    log "${BLUE}[+] 检查并安装依赖...${NC}"
    local pkg_manager=$(get_package_manager)
    local packages_to_install=""

    if ! command_exists curl; then packages_to_install+=" curl"; fi
    if ! command_exists docker; then packages_to_install+=" docker-ce"; fi # Use docker-ce for official install script

    if [ -n "$packages_to_install" ]; then
        log "${YELLOW}  [-] 需要安装以下包: ${packages_to_install}${NC}"
        case "$pkg_manager" in
            apt)
                log "${BLUE}  [*] 使用 apt 安装...${NC}"
                sudo apt-get update
                # 安装 Docker 的先决条件
                sudo apt-get install -y ca-certificates curl gnupg lsb-release
                # 添加 Docker 官方 GPG 密钥
                sudo mkdir -p /etc/apt/keyrings
                curl -fsSL https://download.docker.com/linux/$(lsb_release -is | tr '[:upper:]' '[:lower:]')/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
                # 设置 Docker 仓库
                echo \
                  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(lsb_release -is | tr '[:upper:]' '[:lower:]') \
                  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
                sudo apt-get update
                sudo apt-get install -y $packages_to_install || { log "${RED}  [!] 依赖安装失败!${NC}"; return 1; }
                ;;
            yum|dnf)
                log "${BLUE}  [*] 使用 ${pkg_manager} 安装...${NC}"
                sudo ${pkg_manager} install -y yum-utils
                sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
                sudo ${pkg_manager} install -y $packages_to_install || { log "${RED}  [!] 依赖安装失败!${NC}"; return 1; }
                ;;
            pacman)
                log "${BLUE}  [*] 使用 pacman 安装...${NC}"
                sudo pacman -Sy --noconfirm $packages_to_install || { log "${RED}  [!] 依赖安装失败!${NC}"; return 1; }
                ;;
            *)
                log "${RED}  [!] 不支持的包管理器，请手动安装: ${packages_to_install}${NC}"
                return 1
                ;;
        esac
        log "${GREEN}  [+] 依赖安装完成${NC}"
    else
        log "${GREEN}  [+] 依赖已满足 (curl, docker)${NC}"
    fi

    # 确保 Docker 服务启动并启用
    if command_exists docker; then
        log "${BLUE}  [*] 启动并启用 Docker 服务...${NC}"
        sudo systemctl enable --now docker || { log "${YELLOW}  [!] 启动或启用 Docker 服务失败，请检查 Docker 安装。${NC}"; }
        if sudo systemctl is-active --quiet docker; then
             log "${GREEN}  [+] Docker 服务正在运行${NC}"
        else
             log "${RED}  [!] Docker 服务未能启动!${NC}"
             return 1
        fi
    fi
    return 0
}

# 配置 Docker 镜像源
config_docker_mirror() {
    read -p "${YELLOW}您希望配置 Docker 镜像加速源吗？ (y/N): ${NC}" configure_mirror
    if [[ "$configure_mirror" =~ ^[Yy]$ ]]; then
        log "${BLUE}[+] 配置 Docker 镜像加速源...${NC}"
        if [ -f "$DOCKER_CONFIG_FILE" ]; then
            backup_file "$DOCKER_CONFIG_FILE"
        else
            sudo mkdir -p /etc/docker
        fi

        # 国内常用镜像源列表
        local mirrors=(
            "https://dockerproxy.com"
            "https://hub-mirror.c.163.com"
            "https://mirror.baidubce.com"
            "https://docker.mirrors.ustc.edu.cn"
            "https://docker.nju.edu.cn"
        )
        # 构建 JSON 格式的镜像源
        local mirror_json="\"registry-mirrors\": ["
        for mirror in "${mirrors[@]}"; do
            mirror_json+="\"$mirror\", "
        done
        # 移除最后的逗号和空格
        mirror_json="${mirror_json%, }"
        mirror_json+="]"

        # 使用 jq 处理 JSON 会更健壮，但避免增加新依赖，这里用简单方式
        # 注意：这会覆盖已有的 daemon.json 内容，如果需要保留其他配置请手动合并
        cat << EOF | sudo tee "$DOCKER_CONFIG_FILE" > /dev/null
{
    $mirror_json,
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "20m",
        "max-file": "3"
    },
    "exec-opts": ["native.cgroupdriver=systemd"]
}
EOF

        if [ $? -ne 0 ]; then
            log "${RED}  [!] 写入 Docker 配置文件失败!${NC}"
            return 1
        fi

        log "${BLUE}  [*] 重启 Docker 服务以应用配置...${NC}"
        sudo systemctl daemon-reload
        sudo systemctl restart docker
        if [ $? -ne 0 ]; then
            log "${RED}  [!] 重启 Docker 服务失败! 请检查配置文件 ${DOCKER_CONFIG_FILE}${NC}"
            return 1
        fi
        log "${GREEN}  [+] Docker 镜像源配置完成并已重启${NC}"
    else
        log "${YELLOW}[!] 未配置 Docker 镜像加速源，跳过该步骤。${NC}"
    fi
}

# 架构特定预处理
arch_specific_setup() {
    log "${BLUE}[+] 执行架构特定设置...${NC}"
    case "$ARCH" in
        armv7)
            log "${YELLOW}  [-] ARMv7 设备优化...${NC}"
            # 玩客云等设备的特殊处理 (更换源+防火墙)
            if command_exists apt-get && [ -f "$APT_SOURCE_FILE" ]; then
                read -p "${CYAN}  [?] 是否尝试将 APT 源更换为国内镜像 (清华)? (y/N): ${NC}" change_source
                if [[ "$change_source" =~ ^[Yy]$ ]]; then
                    backup_file "$APT_SOURCE_FILE"
                    log "${YELLOW}    [*] 尝试将 APT 源 (${APT_SOURCE_FILE}) 更换为清华镜像...${NC}"
                    sudo sed -i 's/ports.ubuntu.com/mirrors.tuna.tsinghua.edu.cn/g' "$APT_SOURCE_FILE"
                    sudo sed -i 's/archive.ubuntu.com/mirrors.tuna.tsinghua.edu.cn/g' "$APT_SOURCE_FILE"
                    sudo sed -i 's/security.ubuntu.com/mirrors.tuna.tsinghua.edu.cn/g' "$APT_SOURCE_FILE"
                    # 可以添加对 Debian 源的替换逻辑
                    # sudo sed -i 's/deb.debian.org/mirrors.tuna.tsinghua.edu.cn/g' "$APT_SOURCE_FILE"
                    # sudo sed -i 's/security.debian.org/mirrors.tuna.tsinghua.edu.cn/g' "$APT_SOURCE_FILE"
                    sudo apt-get update
                    log "${GREEN}      [+] APT 源已尝试更换，请检查是否成功。${NC}"
                fi
            fi
             # 安装并配置防火墙
             if command_exists ufw; then
                 log "${GREEN}    [+] ufw 已安装${NC}"
             else
                 read -p "${CYAN}  [?] 是否安装 ufw 防火墙并允许 CasaOS 端口 (${CASAOS_PORT})? (y/N): ${NC}" install_ufw
                 if [[ "$install_ufw" =~ ^[Yy]$ ]]; then
                     if command_exists apt-get; then
                         sudo apt-get install -y ufw || log "${RED}    [!] ufw 安装失败${NC}"
                     elif command_exists yum; then
                          sudo yum install -y ufw || log "${RED}    [!] ufw 安装失败${NC}"
                     else
                          log "${YELLOW}    [!] 未知包管理器，无法自动安装 ufw${NC}"
                     fi
                 fi
             fi
             if command_exists ufw; then
                  sudo ufw allow ${CASAOS_PORT}/tcp comment 'CasaOS Web UI'
                  sudo ufw reload
                  log "${GREEN}    [+] 防火墙已配置允许端口 ${CASAOS_PORT}/tcp${NC}"
             fi
            ;;
        amd64|arm64)
            log "${YELLOW}  [-] ${ARCH} 设备优化...${NC}"
            # 加载 overlay 模块 (Docker 常用)
            if ! lsmod | grep -q overlay; then
                 log "${YELLOW}    [*] 尝试加载 overlay 内核模块...${NC}"
                 sudo modprobe overlay
                 if ! lsmod | grep -q overlay; then
                      log "${YELLOW}    [!] 加载 overlay 模块可能失败或已内置。${NC}"
                 else
                      log "${GREEN}    [+] overlay 模块已加载${NC}"
                 fi
            else
                log "${GREEN}    [+] overlay 模块已加载${NC}"
            fi
            ;;
        *)
            log "${YELLOW}  [!] 无特定架构优化${NC}"
            ;;
    esac
}

# 函数：安装 CasaOS (标准方式)
install_casaos_standard() {
    log "${GREEN}[+] 开始安装 CasaOS (标准方式)...${NC}"
    log "${YELLOW}  [*] 将使用官方脚本进行安装...${NC}"
    curl -fsSL https://get.casaos.io | sudo bash
    if [ $? -ne 0 ]; then
        log "${RED}❌ CasaOS 标准安装脚本执行失败，请检查网络或查看官方文档。${NC}"
        log "${RED}❌ 日志可能位于 /var/log/casaos/install.log${NC}"
        return 1
    fi

    # 验证安装
    check_casaos_status
    if [ "$CASAOS_INSTALL_TYPE" = "standard" ]; then
        local IP=$(hostname -I | awk '{print $1}')
        log "\n${GREEN}✅ CasaOS 标准安装成功！${NC}"
        log "${GREEN}✅ 访问地址：http://${IP}:${CASAOS_PORT}${NC}"
        # 记录安装类型
        sudo mkdir -p /etc/casaos && sudo touch /etc/casaos/.install_method_standard
    else
        log "${RED}❌ 安装后验证失败，请检查日志 /var/log/casaos/install.log${NC}"
        return 1
    fi
    return 0
}

# 函数：使用 Docker 部署 CasaOS 并指定端口
install_casaos_docker() {
    log "${GREEN}[+] 使用 Docker 部署 CasaOS...${NC}"

    # 检查 Docker 是否安装并运行
    if ! command_exists docker || ! sudo systemctl is-active --quiet docker; then
        log "${RED}[!] Docker 未安装或未运行，请先安装并启动 Docker。${NC}"
        return 1
    fi

    # 检查并创建 /DATA 目录
    if [ ! -d "/DATA" ]; then
        sudo mkdir -p /DATA
        log "${GREEN}[+] 创建目录 /DATA${NC}"
    fi

    # 检查同名容器
    if docker ps -a --format '{{.Names}}' | grep -q "^casaos$"; then
        log "${YELLOW}[!] 检测到已存在名为 'casaos' 的 Docker 容器。${NC}"
        read -p "${CYAN}  [?] 是否停止并移除现有容器以继续安装? (y/N): ${NC}" remove_existing
        if [[ "$remove_existing" =~ ^[Yy]$ ]]; then
            log "${YELLOW}  [*] 停止并移除现有 'casaos' 容器...${NC}"
            docker stop casaos >/dev/null 2>&1
            docker rm casaos >/dev/null 2>&1
            if [ $? -ne 0 ]; then
                 log "${RED}  [!] 移除现有容器失败，请手动处理!${NC}"
                 return 1
            fi
            log "${GREEN}  [+] 现有容器已移除${NC}"
        else
            log "${YELLOW}[-] 操作取消。${NC}"
            return 1
        fi
    fi

    # 询问端口
    read -p "${YELLOW}请输入您希望 CasaOS 映射的端口 (默认为 80): ${NC}" custom_port
    if [[ -n "$custom_port" ]] && [[ "$custom_port" =~ ^[0-9]+$ ]] && [ "$custom_port" -gt 0 ] && [ "$custom_port" -lt 65536 ]; then
        CASAOS_PORT="$custom_port"
        log "${CYAN}[+] 将 CasaOS 映射到端口: ${YELLOW}${CASAOS_PORT}${NC}"
    else
        CASAOS_PORT=80
        log "${CYAN}[+] 使用默认端口: ${YELLOW}${CASAOS_PORT}${NC}"
    fi

    # 询问版本
    read -p "${YELLOW}请输入要拉取的 CasaOS Docker 镜像标签 (默认为 latest): ${NC}" casaos_tag
    if [ -z "$casaos_tag" ]; then
        casaos_tag="latest"
    fi
    log "${CYAN}[+] 使用镜像标签: ${YELLOW}${casaos_tag}${NC}"

    log "${YELLOW}[-] 拉取 CasaOS Docker 镜像 (dockurr/casa:${casaos_tag})...${NC}"
    docker pull "dockurr/casa:${casaos_tag}"
    if [ $? -ne 0 ]; then
        log "${RED}❌ 拉取镜像失败! 请检查网络或镜像标签 (${casaos_tag}) 是否存在。${NC}"
        return 1
    fi

    log "${YELLOW}[-] 创建并运行 CasaOS Docker 容器...${NC}"
    # 定义数据卷路径
    CASAOS_DATA_DIR="/DATA" # 主数据目录
    CASAOS_CONF_DIR="/etc/casaos"     # 配置目录
    CASAOS_LOG_DIR="/var/log/casaos"  # 日志目录 (容器内)

    # 创建宿主机目录 (如果不存在)
    sudo mkdir -p "$CASAOS_DATA_DIR" "$CASAOS_CONF_DIR" # 不创建日志目录，让容器自己管理

    # 创建并运行 Docker 容器
    docker run -d \
      --name casaos \
      --restart=always \
      -p ${CASAOS_PORT}:80 \
      --privileged \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v "${CASAOS_CONF_DIR}:/etc/casaos" \
      -v "${CASAOS_DATA_DIR}:/DATA" \
      -v "${CASAOS_LOG_DIR}:/var/log/casaos" \
      "dockurr/casa:${casaos_tag}"

    if [ $? -ne 0 ]; then
         log "${RED}❌ 创建或运行 CasaOS Docker 容器失败! 请检查 Docker 日志 (docker logs casaos)。${NC}"
         return 1
    fi

    # 验证 Docker 容器是否运行
    sleep 5 # 等待容器启动
    if docker ps -a --format '{{.Names}} {{.Status}}' | grep -q "^casaos\s*Up"; then
        local IP=$(hostname -I | awk '{print $1}')
        log "\n${GREEN}✅ CasaOS Docker 部署成功！${NC}"
        log "${GREEN}✅ 访问地址：http://${IP}:${CASAOS_PORT}${NC}"
        log "${YELLOW}  [!] 数据将保存在宿主机的 ${CASAOS_DATA_DIR} 和 ${CASAOS_CONF_DIR} 目录${NC}"
        log "${YELLOW}  [!] 日志保存在宿主机的 ${CASAOS_LOG_DIR} 目录${NC}"
        # 记录安装类型
        sudo mkdir -p /etc/casaos && sudo touch /etc/casaos/.install_method_docker
    else
        log "${RED}❌ CasaOS Docker 部署后容器未能正常运行，请检查 Docker 日志 (docker logs casaos)${NC}"
        docker logs casaos 2>&1 | tee -a "$SCRIPT_LOG_FILE" # 输出日志方便排查
        return 1
    fi
    return 0
}

# 函数：安装 CasaOS Toolbox
install_casaos_toolbox() {
    log "${GREEN}[+] 安装 CasaOS Toolbox...${NC}"

    # 检查 Docker 是否安装并运行
    if ! command_exists docker || ! sudo systemctl is-active --quiet docker; then
        log "${RED}[!] Docker 未安装或未运行，请先安装并启动 Docker。${NC}"
        return 1
    fi

    # 检查同名容器
    if docker ps -a --format '{{.Names}}' | grep -q "^casaos-toolbox$"; then
        log "${YELLOW}[!] 检测到已存在名为 'casaos-toolbox' 的 Docker 容器。${NC}"
        read -p "${CYAN}  [?] 是否停止并移除现有容器以继续安装? (y/N): ${NC}" remove_existing
        if [[ "$remove_existing" =~ ^[Yy]$ ]]; then
            log "${YELLOW}  [*] 停止并移除现有 'casaos-toolbox' 容器...${NC}"
            docker stop casaos-toolbox >/dev/null 2>&1
            docker rm casaos-toolbox >/dev/null 2>&1
            if [ $? -ne 0 ]; then
                 log "${RED}  [!] 移除现有容器失败，请手动处理!${NC}"
                 return 1
            fi
            log "${GREEN}  [+] 现有容器已移除${NC}"
        else
            log "${YELLOW}[-] 操作取消。${NC}"
            return 1
        fi
    fi

    # 拉取 CasaOS Toolbox 镜像
    log "${YELLOW}[-] 拉取 CasaOS Toolbox Docker 镜像 (wisdomsky/casaos-toolbox:latest)...${NC}"
    docker pull wisdomsky/casaos-toolbox:latest
    if [ $? -ne 0 ]; then
        log "${RED}❌ 拉取 CasaOS Toolbox 镜像失败! 请检查网络或镜像标签。${NC}"
        return 1
    fi

    # 创建并运行 CasaOS Toolbox Docker 容器
    log "${YELLOW}[-] 创建并运行 CasaOS Toolbox Docker 容器...${NC}"
    docker run -d \
      --name casaos-toolbox \
      --restart=always \
      -p 8080:80 \
      --privileged \
      wisdomsky/casaos-toolbox:latest

    if [ $? -ne 0 ]; then
         log "${RED}❌ 创建或运行 CasaOS Toolbox Docker 容器失败! 请检查 Docker 日志 (docker logs casaos-toolbox)。${NC}"
         return 1
    fi

    # 验证 Docker 容器是否运行
    sleep 5 # 等待容器启动
    if docker ps -a --format '{{.Names}} {{.Status}}' | grep -q "^casaos-toolbox\s*Up"; then
        local IP=$(hostname -I | awk '{print $1}')
        log "\n${GREEN}✅ CasaOS Toolbox 部署成功！${NC}"
        log "${GREEN}✅ 访问地址：http://${IP}:8080${NC}"
    else
        log "${RED}❌ CasaOS Toolbox Docker 部署后容器未能正常运行，请检查 Docker 日志 (docker logs casaos-toolbox)${NC}"
        docker logs casaos-toolbox 2>&1 | tee -a "$SCRIPT_LOG_FILE" # 输出日志方便排查
        return 1
    fi
    return 0
}

# 函数：卸载 CasaOS
uninstall_casaos() {
    check_casaos_status
    if [ "$CASAOS_INSTALL_TYPE" = "unknown" ]; then
        log "${YELLOW}[!] 未检测到 CasaOS 安装，无法卸载${NC}"
        return 1
    fi

    read -p "${RED}⚠️  警告：卸载 CasaOS 将停止相关服务并可能移除相关文件。此操作不可逆！\n    您确定要卸载 CasaOS 吗？(y/N): ${NC}" confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        log "${RED}[-] 开始卸载 CasaOS (${CASAOS_INSTALL_TYPE} 安装)...${NC}"

        # 尝试使用官方卸载脚本 (优先)
        local official_uninstall_script="/usr/local/bin/casaos-uninstall.sh"
        if [ -f "$official_uninstall_script" ]; then
            log "${BLUE}  [*] 检测到官方卸载脚本，尝试使用...${NC}"
            sudo bash "$official_uninstall_script"
            # 检查卸载是否成功
            check_casaos_status
            if [ "$CASAOS_INSTALL_TYPE" = "unknown" ]; then
                log "${GREEN}✅ CasaOS 使用官方脚本卸载完成${NC}"
                sudo rm -f /etc/casaos/.install_method_* # 清理标记
            else
                log "${YELLOW}[!] 官方卸载脚本执行完毕，但似乎仍检测到残留。请手动检查。${NC}"
            fi
            return 0
        fi

        log "${YELLOW}[-] 未找到官方卸载脚本，尝试手动清理 (${CASAOS_INSTALL_TYPE} 方式)...${NC}"

        # 停止和移除 Docker 容器 (如果检测到是 Docker 安装)
        if [ "$CASAOS_INSTALL_TYPE" = "docker" ]; then
            log "${YELLOW}  [*] 停止并移除 'casaos' Docker 容器...${NC}"
            docker stop casaos >/dev/null 2>&1
            docker rm casaos >/dev/null 2>&1
            if [ $? -eq 0 ]; then
                 log "${GREEN}    [+] 'casaos' 容器已移除${NC}"
            else
                 log "${YELLOW}    [!] 未找到或移除 'casaos' 容器失败 (可能已移除)${NC}"
            fi
        fi

        # 停止和禁用 systemd 服务 (如果检测到是标准安装)
        if [ "$CASAOS_INSTALL_TYPE" = "standard" ]; then
             local services_to_stop=("casaos.service" "casaos-gateway.service" "casaos-user-service.service") # 可能的服务名
             for service in "${services_to_stop[@]}"; do
                if systemctl list-units --type=service --all | grep -q "$service"; then
                    log "${YELLOW}  [*] 停止并禁用 systemd 服务: ${service}...${NC}"
                    sudo systemctl stop "$service" >/dev/null 2>&1
                    sudo systemctl disable "$service" >/dev/null 2>&1
                    log "${GREEN}    [+] 服务 ${service} 已停止并禁用${NC}"
                fi
             done
             sudo systemctl daemon-reload
        fi

        # 清理文件和目录 (提供选项，默认不删除关键数据)
        log "${YELLOW}  [*] 文件清理选项:${NC}"
        local casaos_paths=(
             "/usr/local/bin/casaos"
             "/usr/local/bin/casaos-cli"
             "/etc/systemd/system/casaos*" # 服务文件
             "/var/log/casaos"            # 日志
             # "/etc/casaos"              # 配置文件 (危险!)
             # "/var/lib/casaos"          # 数据文件 (危险!)
             # "/DATA/AppData/casaos"     # 旧版或特定安装的数据? (极度危险!)
         )
         log "${YELLOW}    以下是 CasaOS 可能相关的文件/目录 (部分默认不删除):${NC}"
         for path in "${casaos_paths[@]}"; do echo "      - $path"; done
         read -p "${CYAN}  [?] 是否删除上述非危险性的 CasaOS 文件和目录 (如二进制文件, 服务文件, 日志)? (y/N): ${NC}" remove_files
         if [[ "$remove_files" =~ ^[Yy]$ ]]; then
             log "${RED}    [*] 执行文件删除...${NC}"
             for path in "${casaos_paths[@]}"; do
                 # 只删除非注释掉的路径
                 if [[ ! "$path" =~ ^# ]]; then
                     log "${RED}      [-] 删除: ${path}${NC}"
                     sudo rm -rf "$path"
                 fi
             done
             log "${GREEN}    [+] 非危险文件已尝试移除${NC}"
         else
             log "${YELLOW}    [*] 跳过文件删除${NC}"
         fi

        # 对危险目录给出强烈警告
        log "\n${RED}⚠️ 重要警告:${NC}"
        log "${RED}  以下目录可能包含您的 CasaOS 配置和应用数据，脚本默认 *不会* 删除它们以防数据丢失:${NC}"
        log "${RED}    - /etc/casaos (配置文件)${NC}"
        log "${RED}    - /var/lib/casaos (应用数据, Docker 卷映射的目标等)${NC}"
        log "${RED}    - /DATA/AppData/casaos (或其他可能的自定义数据位置)${NC}"
        log "${YELLOW}  如果您确认不再需要这些数据，请在卸载后手动删除它们。示例命令:${NC}"
        log "${YELLOW}    sudo rm -rf /etc/casaos${NC}"
        log "${YELLOW}    sudo rm -rf /var/lib/casaos${NC}"
        log "${YELLOW}    sudo rm -rf /DATA/AppData/casaos (如果存在且确认是CasaOS数据)${NC}"

        # 清理安装标记
        sudo rm -f /etc/casaos/.install_method_*

        # 最后检查
        check_casaos_status
        if [ "$CASAOS_INSTALL_TYPE" = "unknown" ]; then
            log "${GREEN}✅ CasaOS 手动清理过程基本完成。请根据上述提示检查并手动删除数据目录 (如果需要)。${NC}"
        else
            log "${YELLOW}[!] CasaOS 卸载后似乎仍有残留，请根据日志和提示手动检查。${NC}"
        fi

    else
        log "${YELLOW}[-] 取消卸载${NC}"
    fi
    return 0
}

# 函数：更新 CasaOS
update_casaos() {
    check_casaos_status
    if [ "$CASAOS_INSTALL_TYPE" = "unknown" ]; then
        log "${YELLOW}[!] 未检测到 CasaOS 安装，无法更新${NC}"
        return 1
    fi

    log "${BLUE}[+] 开始更新 CasaOS (${CASAOS_INSTALL_TYPE} 安装)...${NC}"

    if [ "$CASAOS_INSTALL_TYPE" = "standard" ]; then
        log "${YELLOW}  [*] 检测到标准安装，将重新运行官方安装脚本进行更新...${NC}"
        curl -fsSL https://get.casaos.io | sudo bash
        if [ $? -eq 0 ]; then
             log "${GREEN}✅ CasaOS 更新脚本执行完成。请访问 Web UI 查看是否更新成功。${NC}"
        else
             log "${RED}❌ CasaOS 更新脚本执行失败，请检查网络或官方文档。${NC}"
        fi
    elif [ "$CASAOS_INSTALL_TYPE" = "docker" ]; then
        log "${YELLOW}  [*] 检测到 Docker 安装，将尝试拉取最新镜像并重新创建容器...${NC}"
        local current_image=$(docker inspect --format='{{.Config.Image}}' casaos)
        local latest_tag="latest" # 或尝试解析当前tag + 1? 简单起见用latest
        log "${YELLOW}    [*] 当前镜像: ${current_image}${NC}"
        read -p "${CYAN}  [?] 输入要更新到的镜像标签 (默认为 ${latest_tag}): ${NC}" update_tag
        update_tag=${update_tag:-$latest_tag}

        log "${YELLOW}    [*] 拉取新镜像 (dockurr/casa:${update_tag})...${NC}"
        docker pull "dockurr/casa:${update_tag}"
        if [ $? -ne 0 ]; then
            log "${RED}    [!] 拉取新镜像失败! 请检查标签或网络。${NC}"
            return 1
        fi

        log "${YELLOW}    [*] 停止并移除旧的 'casaos' 容器 (配置和数据卷将保留)...${NC}"
        docker stop casaos >/dev/null 2>&1
        docker rm casaos >/dev/null 2>&1

        log "${YELLOW}    [*] 使用新镜像重新创建容器...${NC}"
        # 需要复用 install_casaos_docker 中的参数，特别是端口和卷映射
        # 注意：这里假设了卷映射路径与 install_casaos_docker 中一致
        local run_cmd="docker run -d \
          --name casaos \
          --restart=always \
          -p ${CASAOS_PORT}:80 \
          --privileged \
          -v /var/run/docker.sock:/var/run/docker.sock \
          -v /etc/casaos:/etc/casaos \
          -v /var/lib/casaos:/var/lib/casaos \
          -v /var/log/casaos:/var/log/casaos \
          dockurr/casa:${update_tag}"

        log "${CYAN}    执行命令: ${run_cmd}${NC}"
        eval "$run_cmd" # 使用 eval 执行命令

        if [ $? -ne 0 ]; then
             log "${RED}❌ 重新创建 CasaOS Docker 容器失败! 请检查 Docker 日志。${NC}"
             return 1
        fi
        sleep 5
        if docker ps -a --format '{{.Names}} {{.Status}}' | grep -q "^casaos\s*Up"; then
             log "${GREEN}✅ CasaOS Docker 更新完成！请访问 Web UI 确认。${NC}"
        else
             log "${RED}❌ CasaOS Docker 更新后容器未能正常运行，请检查 Docker 日志 (docker logs casaos)${NC}"
             docker logs casaos 2>&1 | tee -a "$SCRIPT_LOG_FILE"
             return 1
        fi
    else
        log "${RED}[!] 无法识别的安装类型，无法更新。${NC}"
    fi
}

# 函数：查看 CasaOS 状态和信息
view_casaos_info() {
    check_casaos_status
    if [ "$CASAOS_INSTALL_TYPE" = "unknown" ]; then
        log "${YELLOW}[!] CasaOS 未安装，无法查看信息${NC}"
        return 1
    fi

    log "${BLUE}[+] CasaOS (${CASAOS_INSTALL_TYPE} 安装) 信息...${NC}"

    echo -e "${YELLOW}  [-] 版本信息:${NC}"
    if [ "$CASAOS_INSTALL_TYPE" = "standard" ] && command_exists casaos; then
        casaos -v || log "${RED}    [!] 无法获取 CasaOS 版本${NC}"
    elif [ "$CASAOS_INSTALL_TYPE" = "docker" ]; then
        local image_version=$(docker inspect --format='{{.Config.Image}}' casaos)
        echo -e "${GREEN}    [+] Docker 镜像: ${image_version}${NC}"
    else
         log "${YELLOW}    [!] 未知版本信息${NC}"
    fi

    echo -e "${YELLOW}  [-] 运行状态:${NC}"
    if [ "$CASAOS_INSTALL_TYPE" = "standard" ]; then
        if systemctl is-active --quiet casaos-gateway.service; then
            echo -e "${GREEN}    [+] CasaOS Gateway 服务: 运行中${NC}"
        else
            echo -e "${RED}    [!] CasaOS Gateway 服务: 未运行${NC}"
        fi
         if systemctl is-active --quiet casaos.service; then
             echo -e "${GREEN}    [+] CasaOS 主服务: 运行中${NC}"
         else
             echo -e "${YELLOW}    [!] CasaOS 主服务: 未运行 (可能是旧版或未启动)${NC}"
         fi
    elif [ "$CASAOS_INSTALL_TYPE" = "docker" ]; then
        if docker ps --format '{{.Names}}' | grep -q "^casaos$"; then
            echo -e "${GREEN}    [+] CasaOS Docker 容器: 运行中${NC}"
        else
            echo -e "${RED}    [!] CasaOS Docker 容器: 未运行${NC}"
        fi
    fi
    # Docker 状态总是检查
    if command_exists docker && sudo systemctl is-active --quiet docker; then
        echo -e "${GREEN}    [+] Docker 服务: 运行中${NC}"
    else
        echo -e "${RED}    [!] Docker 服务: 未运行或未安装${NC}"
    fi

    local IP=$(hostname -I | awk '{print $1}')
    echo -e "${YELLOW}  [-] 访问地址: ${GREEN}http://${IP}:${CASAOS_PORT}${NC}"

    echo -e "${YELLOW}  [-] 相关目录:${NC}"
    echo -e "${CYAN}    - 配置目录: /etc/casaos${NC}"
    echo -e "${CYAN}    - 数据目录: /var/lib/casaos (或 Docker 卷映射位置)${NC}"
    echo -e "${CYAN}    - 日志目录: /var/log/casaos (或 Docker 卷映射位置)${NC}"
    echo -e "${YELLOW}  [-] 脚本日志: ${CYAN}${SCRIPT_LOG_FILE}${NC}"
}

# 函数：环境检查
pre_flight_check() {
    log "${BLUE}[+] 执行安装前环境检查...${NC}"
    local check_passed=true

    # 1. 操作系统检查 (简单示例)
    if [ -f /etc/os-release ]; then
        source /etc/os-release
        log "${GREEN}  [+] 检测到操作系统: ${PRETTY_NAME}${NC}"
        # 可根据 $ID (如 ubuntu, debian, centos) 进行更细致判断
    else
        log "${YELLOW}  [!] 未知操作系统${NC}"
    fi

    # 2. 架构检查
    detect_arch

    # 3. 内存检查 (示例: 显示内存大小)
    local total_mem=$(free -m | awk '/^Mem:/{print $2}')
    if [ -z "$total_mem" ]; then
        log "${RED}  [!] 无法获取系统内存信息${NC}"
    else
        log "${GREEN}  [+] 系统内存: ${total_mem}MB${NC}"
    fi

    # 5. 网络连接检查
    log "${YELLOW}  [*] 检查网络连接...${NC}"
    if curl -fsSL --connect-timeout 5 https://get.casaos.io > /dev/null; then
         log "${GREEN}    [+] 连接 get.casaos.io 成功${NC}"
    else
         log "${RED}    [!] 连接 get.casaos.io 失败! 请检查网络或防火墙设置。${NC}"
         check_passed=false
    fi
     if curl -fsSL --connect-timeout 5 https://get.docker.com > /dev/null; then
          log "${GREEN}    [+] 连接 get.docker.com 成功${NC}"
     else
          log "${YELLOW}    [!] 连接 get.docker.com 失败! 可能需要配置镜像或代理。${NC}"
          # 可以不视为致命错误，因为可能使用国内镜像安装
     fi

    # 6. 检查 sudo 权限
    if sudo -n true 2>/dev/null; then
        log "${GREEN}  [+] 当前用户具有免密 sudo 权限${NC}"
    elif sudo -v >/dev/null 2>&1; then
        log "${GREEN}  [+] 当前用户具有 sudo 权限 (可能需要输入密码)${NC}"
    else
        log "${RED}  [!] 错误: 当前用户没有 sudo 权限，脚本无法继续。${NC}"
        check_passed=false
    fi

    if ! $check_passed; then
        log "${RED}[!] 环境检查未通过，请解决上述错误后重试。${NC}"
        exit 1
    else
        log "${GREEN}[+] 环境检查通过!${NC}"
    fi
}

# 函数：主菜单
show_menu() {
    check_casaos_status # 每次显示菜单前更新状态
    local is_installed=false
    if [ "$CASAOS_INSTALL_TYPE" != "unknown" ]; then
        is_installed=true
    fi

    echo -e "\n${BLUE}============================================${NC}"
    echo -e "${GREEN}          CasaOS 部署与管理脚本 v2.7        ${NC}"
    echo -e "${CYAN}          当前状态: $(if $is_installed; then echo "已安装 (${CASAOS_INSTALL_TYPE})"; else echo "未安装"; fi)${NC}"
    echo -e "${BLUE}============================================${NC}"
    echo -e " ${YELLOW}安装选项:${NC}"
    echo -e "  1. 检查环境并安装 CasaOS (推荐: 标准方式)"
    echo -e "  2. 检查环境并使用 Docker 部署 CasaOS (可指定端口/版本)"
    echo -e "  3. 安装 CasaOS Toolbox" # 新增选项
    echo -e " ${YELLOW}管理选项:${NC}"
    if $is_installed; then
        echo -e "  4. ${GREEN}更新 CasaOS${NC}"
        echo -e "  5. ${CYAN}查看 CasaOS 状态和信息${NC}"
        echo -e "  6. ${RED}卸载 CasaOS${NC}"
    else
        echo -e "  4. (需要先安装)"
        echo -e "  5. (需要先安装)"
        echo -e "  6. (需要先安装)"
    fi
    echo -e " ${YELLOW}其他选项:${NC}"
    echo -e "  7. 配置 Docker 国内镜像加速"
    echo -e "  8. (TODO: 切换系统 APT/YUM 镜像源)" # 占位符
    echo -e "  9. (TODO: 备份/恢复 CasaOS 配置)" # 占位符
    echo -e "  10. 清理脚本日志 (${SCRIPT_LOG_FILE})"
    echo -e "  0. 退出脚本"
    echo -e "${BLUE}--------------------------------------------${NC}"

    # 计算有效选项范围
    local max_option=10
    local valid_options_msg="0, 1, 2, 3, 10" # Base options without TODOs
    if $is_installed; then
        valid_options_msg+=", 4, 5, 6"
    fi

    read -p "请输入操作选项 [${valid_options_msg}]: " choice

    case "$choice" in
        1)
            pre_flight_check
            install_dependencies
            config_docker_mirror # 推荐配置
            arch_specific_setup
            install_casaos_standard
            ;;
        2)
            pre_flight_check
            install_dependencies # Docker 是前提
            config_docker_mirror # 推荐配置
            install_casaos_docker
            ;;
        3)
            install_casaos_toolbox # 调用新选项
            ;;
        4)
            if $is_installed; then
                update_casaos
            else
                log "${YELLOW}[!] CasaOS 未安装，无法执行此操作${NC}"
            fi
            ;;
        5)
            if $is_installed; then
                view_casaos_info
            else
                log "${YELLOW}[!] CasaOS 未安装，无法执行此操作${NC}"
            fi
            ;;
        6)
            if $is_installed; then
                uninstall_casaos
            else
                log "${YELLOW}[!] CasaOS 未安装，无法执行此操作${NC}"
            fi
            ;;
        7)
            install_dependencies # 确保 docker 命令存在
            config_docker_mirror
            ;;
        8)
            log "${YELLOW}[!] 功能“切换系统镜像源”尚未实现。${NC}"
            ;;
        9)
            log "${YELLOW}[!] 功能“备份/恢复 CasaOS 配置”尚未实现。${NC}"
            ;;
        10)
            if [ -f "$SCRIPT_LOG_FILE" ]; then
                log "${YELLOW}[-] 清理脚本日志文件: ${SCRIPT_LOG_FILE}${NC}"
                sudo rm -f "$SCRIPT_LOG_FILE"
            else
                 log "${YELLOW}[!] 脚本日志文件不存在。${NC}"
            fi
            ;;

        0)
            log "${GREEN}感谢使用！脚本退出。${NC}"
            exit 0
            ;;
        *)
            log "${RED}无效的选项，请重新选择${NC}"
            ;;
    esac
    read -p "${CYAN}按 Enter键 返回主菜单...${NC}" # 暂停，等待用户确认
    show_menu # 循环显示菜单
}

# --- Main Execution ---
main() {
    # 清理旧日志或初始化日志文件
    echo "" > "$SCRIPT_LOG_FILE"
    log "${MAGENTA}### CasaOS 部署脚本 v2.7 开始执行 ###${NC}"
    # 确保有 sudo 权限
    if ! sudo -v; then
        log "${RED}[!] 无法获取 sudo 权限，脚本退出。${NC}"
        exit 1
    fi
    show_menu
}

# 启动主程序
main
