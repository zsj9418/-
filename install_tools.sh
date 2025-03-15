#!/bin/bash

# 检查用户是否为root
if [ "$EUID" -ne 0 ]; then
  echo "请以root用户运行此脚本，请使用sudo或root权限运行。"
  exit 1
fi

# 检测系统包管理器
if command -v apt &> /dev/null; then
  PKG_MANAGER="apt"
  SOURCES_LIST="/etc/apt/sources.list"
  SOURCES_BACKUP="/etc/apt/sources.list.backup"
elif command -v yum &> /dev/null; then
  PKG_MANAGER="yum"
  SOURCES_LIST="/etc/yum.repos.d/CentOS-Base.repo"
  SOURCES_BACKUP="/etc/yum.repos.d/CentOS-Base.repo.backup"
elif command -v dnf &> /dev/null; then
  PKG_MANAGER="dnf"
  SOURCES_LIST="/etc/yum.repos.d/fedora.repo"
  SOURCES_BACKUP="/etc/yum.repos.d/fedora.repo.backup"
else
  echo "未检测到支持的包管理器 (apt/yum/dnf)，脚本无法继续。"
  exit 1
fi

# 检测设备架构
ARCH=$(uname -m)
echo "检测到系统架构为：$ARCH"

# 备份源文件
backup_sources() {
  echo "正在备份源文件..."
  if [ -f "$SOURCES_LIST" ]; then
    cp "$SOURCES_LIST" "$SOURCES_BACKUP"
    echo "源文件已备份到 $SOURCES_BACKUP"
  else
    echo "未找到源文件，跳过备份。"
  fi
}

# 还原备份源
restore_sources() {
  echo "正在还原源文件..."
  if [ -f "$SOURCES_BACKUP" ]; then
    cp "$SOURCES_BACKUP" "$SOURCES_LIST"
    echo "源文件已从 $SOURCES_BACKUP 还原。"
  else
    echo "未找到备份文件，跳过还原。"
  fi
}

# 更换为阿里源
change_to_aliyun() {
  echo "正在更换为阿里云镜像源..."
  case $PKG_MANAGER in
    apt)
      sed -i 's|http://[^/]*|http://mirrors.aliyun.com|g' "$SOURCES_LIST"
      ;;
    yum|dnf)
      curl -o "$SOURCES_LIST" http://mirrors.aliyun.com/repo/Centos-7.repo
      ;;
  esac
  echo "已更换为阿里云镜像源。"
}

# 添加 Docker 官方源
add_docker_repo() {
  echo "正在添加 Docker 官方源..."
  case $PKG_MANAGER in
    apt)
      apt-get install -y apt-transport-https ca-certificates curl software-properties-common
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
      ;;
    yum|dnf)
      $PKG_MANAGER install -y yum-utils
      $PKG_MANAGER-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
      ;;
  esac
  echo "Docker 官方源已添加。"
}

# 更新系统包
update_system() {
  echo "正在更新系统包..."
  $PKG_MANAGER update -y
}

# 安装常用工具
install_common_tools() {
  echo "正在安装常用工具..."
  
  # 原有的常用工具
  COMMON_TOOLS="sudo git vim curl wget htop tmux tree zip unzip openssh-server dos2unix"

  # 从分析的脚本中提取的必要依赖项
  NECESSARY_TOOLS="jq lsof tar iptables ipset resolvconf util-linux cron net-tools fzf dnsutils psmisc yamllint"

  # 安装
  $PKG_MANAGER install -y $COMMON_TOOLS $NECESSARY_TOOLS
  echo "常用工具和必要依赖安装完成。"
}

# 安装开发工具
install_dev_tools() {
  echo "正在安装开发工具..."
  DEV_TOOLS="build-essential gcc g++ make cmake python3 python3-pip nodejs npm openjdk-17-jdk maven"
  $PKG_MANAGER install -y $DEV_TOOLS
}

# 清理缓存
clean_system() {
  echo "正在清理系统缓存..."
  $PKG_MANAGER autoremove -y
  $PKG_MANAGER clean
}

# 交互式菜单
while true; do
  echo "
请选择要执行的操作：
1. 更换为阿里云镜像源
2. 添加 Docker 官方源
3. 更新系统包
4. 安装常用工具
5. 安装开发工具
6. 还原备份源
7. 清理系统缓存
8. 退出脚本
"
  read -p "请输入选项编号：" CHOICE
  case $CHOICE in
    1)
      backup_sources
      change_to_aliyun
      ;;
    2)
      add_docker_repo
      ;;
    3)
      update_system
      ;;
    4)
      install_common_tools
      ;;
    5)
      install_dev_tools
      ;;
    6)
      restore_sources
      ;;
    7)
      clean_system
      ;;
    8)
      echo "退出脚本。"
      break
      ;;
    *)
      echo "无效选项，请重新输入。"
      ;;
  esac
done
