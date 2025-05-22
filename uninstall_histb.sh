#!/bin/bash

# 增强版系统清理脚本（排除Samba）
# 功能：1)卸载自建仓库软件包 2)卸载预装软件 3)安全配置SSH

# 定义颜色代码
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# 检查root权限
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}错误：此脚本需要root权限执行${NC}"
        exit 1
    fi
}

# 定义可能存在的自建仓库软件包列表（排除samba-histb）
ALL_PACKAGES=(
    gitweb-histb
    tailscale-histb
    transmission-histb
    ttyd-histb
    typecho-histb
    cronweb-histb
    ddns-histb
    filebrowser-histb
    frpc-histb
    h5ai-histb
)

# 定义可能残留的配置目录（排除samba相关目录）
CONFIG_DIRS=(
    /etc/gitweb /etc/tailscale /etc/transmission
    /etc/ttyd /etc/typecho /etc/cronweb /etc/ddns
    /etc/filebrowser /etc/frpc /etc/h5ai
    /var/lib/gitweb /var/lib/tailscale
    /var/lib/transmission /var/lib/ttyd /var/lib/typecho
    /var/lib/cronweb /var/lib/ddns /var/lib/filebrowser
    /var/lib/frpc /var/lib/h5ai
)

# 预装软件列表（排除samba）
PREINSTALLED_APPS=(
    alist php nginx aria2 transmission
    ttyd vlmcsd frp nfs vsftpd
    tailscale filebrowser linkease
)

# 检测已安装的软件包
detect_installed() {
    local installed=()
    for pkg in "${ALL_PACKAGES[@]}"; do
        if dpkg -l | grep -q "^ii  $pkg "; then
            installed+=("$pkg")
        fi
    done
    echo "${installed[@]}"
}

# 显示菜单让用户选择
show_menu() {
    local installed=("$@")
    echo -e "\n${GREEN}=== 自建仓库软件卸载（已排除Samba）===${NC}"
    echo "检测到以下可卸载的软件包:"
    for i in "${!installed[@]}"; do
        printf "%2d) %s\n" $((i+1)) "${installed[i]}"
    done
    echo "  a) 全部卸载"
    echo "  p) 进入预装软件卸载"
    echo "  s) 配置SSH安全"
    echo "  n) 退出脚本"
    echo ""
    read -p "请选择要卸载的软件包编号(多个用空格分隔)，或输入选项[a/p/s/n]: " selection
    
    case "$selection" in
        a) SELECTED=("${installed[@]}") ;;
        p) uninstall_preinstalled ;;
        s) secure_ssh_config ;;
        n) echo "退出卸载程序。"; exit 0 ;;
        *)
            SELECTED=()
            for num in $selection; do
                index=$((num-1))
                if [[ $index -ge 0 && $index -lt ${#installed[@]} ]]; then
                    SELECTED+=("${installed[index]}")
                else
                    echo "无效选项: $num 将被忽略"
                fi
            done
            ;;
    esac
}

# 主卸载函数
uninstall_packages() {
    local packages=("$@")
    if [[ ${#packages[@]} -eq 0 ]]; then
        echo "没有选择要卸载的软件包。"
        return
    fi

    echo -e "\n${YELLOW}即将卸载以下软件包: ${packages[*]}${NC}"
    read -p "确认卸载吗？[y/N]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "取消卸载操作。"
        return
    fi

    # 停止相关服务
    for pkg in "${packages[@]}"; do
        service="${pkg%-histb}"
        echo -e "\n${GREEN}停止 ${service} 服务...${NC}"
        systemctl stop "${service}"* 2>/dev/null
    done

    # 卸载软件包
    echo -e "\n${GREEN}卸载软件包...${NC}"
    for pkg in "${packages[@]}"; do
        echo "正在卸载 $pkg..."
        apt-get purge "$pkg" -y
    done

    # 清理残留
    cleanup_system
}

# 预装软件卸载（排除Samba）
uninstall_preinstalled() {
    echo -e "\n${GREEN}=== 预装软件卸载（已排除Samba）===${NC}"
    echo "以下预装软件将被卸载:"
    printf "  %s\n" "${PREINSTALLED_APPS[@]}"
    
    read -p "确认卸载所有预装软件吗？[y/N]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "取消卸载操作。"
        return
    fi

    # 停止并卸载所有预装软件
    for app in "${PREINSTALLED_APPS[@]}"; do
        echo -e "\n${YELLOW}处理 ${app}...${NC}"
        
        # 停止服务
        systemctl stop "${app}"* 2>/dev/null
        
        # 特殊处理易有云
        if [[ "$app" == "linkease" ]]; then
            systemctl stop com.linkease.linkeasedaemon.service 2>/dev/null
        fi

        # 卸载软件包
        apt-get purge "${app}"* -y 2>/dev/null
        
        # 特殊处理PHP多版本
        if [[ "$app" == "php" ]]; then
            apt-get purge php7* -y 2>/dev/null
        fi
    done

    # 清理特定目录
    echo -e "\n${GREEN}清理残留文件...${NC}"
    rm -rf /var/www /etc/first_init.d/web.sh /usr/share/bak/gitweb /bin/install-gitweb.sh
    
    # 执行通用清理
    cleanup_system
    
    echo -e "\n${GREEN}预装软件卸载完成！${NC}"
}

# 系统通用清理（排除Samba相关）
cleanup_system() {
    echo -e "\n${GREEN}=== 系统清理 ===${NC}"
    
    # 自动移除不再需要的依赖包
    echo "自动移除不再需要的依赖包..."
    apt-get autoremove -y
    
    # 清理残留配置文件和目录
    echo "清理残留配置文件和目录..."
    for dir in "${CONFIG_DIRS[@]}"; do
        if [ -d "$dir" ]; then
            echo "删除目录: $dir"
            rm -rf "$dir"
        fi
    done
    
    # 清理用户主目录可能存在的残留
    echo "清理用户主目录残留..."
    for pkg in "${ALL_PACKAGES[@]}" "${PREINSTALLED_APPS[@]}"; do
        local dir="${pkg%-histb}"  # 移除-histb后缀
        local home_dir="/home/*/.${dir} $HOME/.${dir}"
        find /home -maxdepth 1 -type d -name ".${dir}" -exec rm -rf {} + 2>/dev/null
        rm -rf "$HOME/.${dir}" 2>/dev/null
    done
    
    # 清理临时文件
    echo "清理临时文件..."
    apt-get clean
    apt-get autoclean
    
    # 查找并删除所有相关文件
    echo "查找并删除所有相关文件..."
    for pkg in "${ALL_PACKAGES[@]}" "${PREINSTALLED_APPS[@]}"; do
        local name="${pkg%-histb}"
        echo "清理 ${name} 残留文件..."
        find / -name "${name}*" -exec rm -rf {} + 2>/dev/null
    done
    
    # 特殊处理目录（排除Samba）
    rm -rf /opt/tailscale
}

# 安全配置SSH
secure_ssh_config() {
    echo -e "\n${GREEN}=== SSH安全配置 ===${NC}"
    
    SSH_CONFIG="/etc/ssh/sshd_config"
    if [ ! -f "$SSH_CONFIG" ]; then
        echo -e "${RED}错误：找不到SSH配置文件${NC}"
        return
    fi
    
    # 备份原配置文件
    cp "$SSH_CONFIG" "${SSH_CONFIG}.bak"
    echo "已创建配置文件备份: ${SSH_CONFIG}.bak"
    
    # 关闭X11转发
    echo -e "\n${YELLOW}关闭X11转发(6010端口)...${NC}"
    sed -i 's/^X11Forwarding yes/#X11Forwarding yes/' "$SSH_CONFIG"
    
    # 获取当前SSH端口
    CURRENT_PORT=$(grep -oP '^Port \K\d+' "$SSH_CONFIG" || echo "22")
    
    echo -e "\n当前SSH端口: ${CURRENT_PORT}"
    read -p "是否要更改SSH端口? [y/N]: " change_port
    if [[ "$change_port" == "y" || "$change_port" == "Y" ]]; then
        while true; do
            read -p "请输入新的SSH端口(1024-65535): " new_port
            if [[ "$new_port" =~ ^[0-9]+$ ]] && (( new_port >= 1024 && new_port <= 65535 )); then
                # 检查端口是否被占用
                if ! ss -tuln | grep -q ":${new_port} "; then
                    sed -i "s/^#*Port .*/Port ${new_port}/" "$SSH_CONFIG"
                    echo "SSH端口已更改为: ${new_port}"
                    CURRENT_PORT="$new_port"
                    break
                else
                    echo -e "${RED}错误：端口 ${new_port} 已被占用${NC}"
                fi
            else
                echo -e "${RED}错误：请输入有效的端口号(1024-65535)${NC}"
            fi
        done
    fi
    
    # 重启SSH服务
    echo -e "\n${YELLOW}重启SSH服务...${NC}"
    systemctl restart sshd
    
    # 显示当前监听端口
    echo -e "\n${GREEN}当前网络监听状态:${NC}"
    netstat -at | grep LISTEN
    
    echo -e "\n${GREEN}SSH配置完成！请确保您能通过新端口(${CURRENT_PORT})连接后再关闭当前会话。${NC}"
    echo -e "如需进一步安全配置，建议:"
    echo "1. 禁用root登录: PermitRootLogin no"
    echo "2. 启用密钥认证: PasswordAuthentication no"
    echo "3. 限制用户访问: AllowUsers your_username"
}

# 主程序
clear
echo -e "${GREEN}=== 系统清理与卸载工具（已排除Samba） ===${NC}"
check_root

# 检测自建仓库软件包
INSTALLED_PACKAGES=($(detect_installed))

if [[ ${#INSTALLED_PACKAGES[@]} -eq 0 ]]; then
    echo -e "${YELLOW}没有检测到可卸载的自建仓库软件包。${NC}"
    echo -e "1) 卸载预装软件"
    echo -e "2) 配置SSH安全"
    echo -e "3) 退出"
    read -p "请选择: " choice
    
    case "$choice" in
        1) uninstall_preinstalled ;;
        2) secure_ssh_config ;;
        3) exit 0 ;;
        *) echo "无效选择"; exit 1 ;;
    esac
else
    show_menu "${INSTALLED_PACKAGES[@]}"
    if [[ ${#SELECTED[@]} -gt 0 ]]; then
        uninstall_packages "${SELECTED[@]}"
    fi
fi

echo -e "\n${GREEN}操作完成！${NC}"
