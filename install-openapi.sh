#!/bin/bash

# 欢迎信息
echo "欢迎使用一键部署脚本！"
echo "本脚本将自动检测您的设备架构和操作系统版本，并安装所需的依赖。"
echo "请确保您已安装 sudo 和 curl。"

# 检测设备架构和操作系统版本
architecture=$(uname -m)
os_version=$(uname -s)

# 安装依赖
echo "正在检测并安装依赖..."

if [[ "$os_version" == "Linux" ]]; then
  if [[ "$architecture" == "x86_64" || "$architecture" == "aarch64" ]]; then
    # 对于 x86_64 和 aarch64 Linux 系统，安装 Docker 和 Docker Compose
    if ! command -v docker &> /dev/null; then
      echo "正在安装 Docker..."
      curl -fsSL https://get.docker.com -o get-docker.sh
      sudo sh get-docker.sh
      rm get-docker.sh
      sudo usermod -aG docker $USER
      newgrp docker
    else
      echo "Docker 已安装。"
    fi

    if ! command -v docker-compose &> /dev/null; then
      echo "正在安装 Docker Compose..."
      sudo curl -L "https://github.com/docker/compose/releases/download/v2.23.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
      sudo chmod +x /usr/local/bin/docker-compose
    else
      echo "Docker Compose 已安装。"
    fi
  else
    echo "不支持的设备架构：$architecture"
    exit 1
  fi
else
  echo "不支持的操作系统：$os_version"
  exit 1
fi

# 交互式选择项目
while true; do
  read -p "请选择要操作的项目（1：one-api，2：duck2api）：" project
  case "$project" in
    1|2)
      break
      ;;
    *)
      echo "无效的项目，请重新选择。"
      ;;
  esac
done

# 交互式选择操作
while true; do
  read -p "请选择操作（1：部署，2：卸载）：" operation
  case "$operation" in
    1|2)
      break
      ;;
    *)
      echo "无效的操作，请重新选择。"
      ;;
  esac
done

# 交互式选择部署方案
if [[ "$operation" == "1" ]]; then
  while true; do
    read -p "请选择部署方案（1：Docker，2：Docker Compose，3：手动部署）：" deployment_method
    case "$deployment_method" in
      1|2|3)
        break
        ;;
      *)
        echo "无效的部署方案，请重新选择。"
        ;;
    esac
  done
fi

# 部署 one-api
if [[ "$project" == "1" && "$operation" == "1" ]]; then
  if [[ "$deployment_method" == "1" ]]; then
    # 传统 Docker 部署 one-api
    echo "正在使用传统 Docker 部署 one-api..."

    # 交互式选择端口
    while true; do
      read -p "请输入您希望使用的端口（默认 3000）：" port
      if [[ -z "$port" ]]; then
        port="3000"
      fi
      if [[ "$port" =~ ^[0-9]+$ ]]; then
        break
      else
        echo "端口号必须为数字，请重新输入。"
      fi
    done

    # 拉取 one-api 镜像（支持 amd64 和 arm64）
    echo "正在拉取 one-api 镜像..."
    docker pull justsong/one-api:v0.6.11-preview.1

    # 启动 one-api 容器
    echo "正在启动 one-api 容器..."
    docker run -d --name one-api \
      -p $port:3000 \
      -v ./one-api-data:/data \
      -e PORT=3000 \
      --restart always \
      justsong/one-api:v0.6.11-preview.1

    # 部署完成提示
    echo "one-api 已成功部署！"
    echo "您可以通过 http://<您的服务器IP>:$port 访问 one-api。"
    echo "首次访问，请使用默认管理员账号 root 和密码 123456 登录。"
    echo "为了安全起见，请尽快修改默认密码。"
  elif [[ "$deployment_method" == "2" ]]; then
    # Docker Compose 部署 one-api
    echo "正在使用 Docker Compose 部署 one-api..."

    # 交互式选择端口
    while true; do
      read -p "请输入您希望使用的端口（默认 3000）：" port
      if [[ -z "$port" ]]; then
        port="3000"
      fi
      if [[ "$port" =~ ^[0-9]+$ ]]; then
        break
      else
        echo "端口号必须为数字，请重新输入。"
      fi
    done

    # Docker Compose 文件内容
    docker_compose_content="
version: '3'
services:
  one-api:
    image: justsong/one-api:v0.6.11-preview.1
    ports:
      - $port:3000
    environment:
      - PORT=3000
    volumes:
      - ./one-api-data:/data
    restart: always
"

    # 创建 docker-compose.yml 文件
    echo "$docker_compose_content" > docker-compose.yml

    # 创建数据目录
    mkdir -p one-api-data

    # 启动 one-api
    echo "正在启动 one-api，请稍候..."
    docker-compose up -d

    # 部署完成提示
    echo "one-api 已成功部署！"
    echo "您可以通过 http://<您的服务器IP>:$port 访问 one-api。"
  elif [[ "$deployment_method" == "3" ]]; then
    # 手动部署 one-api
    echo "正在使用手动部署 one-api..."
    echo "请参考官方文档手动部署 one-api。"
  fi
fi

# 部署 duck2api
if [[ "$project" == "2" && "$operation" == "1" ]]; then
  if [[ "$deployment_method" == "1" ]]; then
    # 传统 Docker 部署 duck2api
    echo "正在使用传统 Docker 部署 duck2api..."

    # 交互式选择端口
    while true; do
      read -p "请输入您希望使用的端口（默认 3000）：" port
      if [[ -z "$port" ]]; then
        port="3000"
      fi
      if [[ "$port" =~ ^[0-9]+$ ]]; then
        break
      else
        echo "端口号必须为数字，请重新输入。"
      fi
    done

    # 拉取 duck2api 镜像
    echo "正在拉取 duck2api 镜像..."
    docker pull ghcr.io/aurora-develop/duck2api:latest

    # 启动 duck2api 容器
    echo "正在启动 duck2api 容器..."
    docker run -d --name duck2api \
      -p $port:3000 \
      -v ./duck2api-data:/data \
      --restart always \
      ghcr.io/aurora-develop/duck2api:latest

    # 部署完成提示
    echo "duck2api 已成功部署！"
    echo "您可以通过 http://<您的服务器IP>:$port 访问 duck2api。"
  elif [[ "$deployment_method" == "2" ]]; then
    # Docker Compose 部署 duck2api
    echo "正在使用 Docker Compose 部署 duck2api..."

    # 交互式选择端口
    while true; do
      read -p "请输入您希望使用的端口（默认 3000）：" port
      if [[ -z "$port" ]]; then
        port="3000"
      fi
      if [[ "$port" =~ ^[0-9]+$ ]]; then
        break
      else
        echo "端口号必须为数字，请重新输入。"
      fi
    done

    # Docker Compose 文件内容
    docker_compose_content="
version: '3'
services:
  duck2api:
    image: ghcr.io/aurora-develop/duck2api:latest
    ports:
      - $port:3000
    volumes:
      - ./duck2api-data:/data
    restart: always
"

    # 创建 docker-compose.yml 文件
    echo "$docker_compose_content" > docker-compose.yml

    # 创建数据目录
    mkdir -p duck2api-data

    # 启动 duck2api
    echo "正在启动 duck2api，请稍候..."
    docker-compose up -d

    # 部署完成提示
    echo "duck2api 已成功部署！"
    echo "您可以通过 http://<您的服务器IP>:$port 访问 duck2api。"
  elif [[ "$deployment_method" == "3" ]]; then
    # 手动部署 duck2api
    echo "正在使用手动部署 duck2api..."
    echo "请参考官方文档手动部署 duck2api。"
  fi
fi

# 卸载功能
if [[ "$operation" == "2" ]]; then
  if [[ "$project" == "1" ]]; then
    # 卸载 one-api
    echo "正在卸载 one-api..."
    docker-compose down
    rm -rf one-api-data
    rm -f docker-compose.yml
    echo "one-api 已成功卸载！"
  elif [[ "$project" == "2" ]]; then
    # 卸载 duck2api
    echo "正在卸载 duck2api..."
    docker-compose down
    rm -rf duck2api-data
    rm -f docker-compose.yml
    echo "duck2api 已成功卸载！"
  fi
fi

# 结束脚本
echo "感谢您的使用！"
