#!/bin/bash
# ==============================================================================
# Docker 安装公共函数模块
#
# 本文件由 install_singbox_docker.sh 和 casaos_installer.sh 共同引用。
# 使用前请确保已定义: _have() / _ok() / _warn() / _err() / _info()
# 或红黄绿输出函数: red() / green() / yellow() / log()
# ==============================================================================

# 如果调用方尚未定义这些工具函数，提供兼容版本
_have()   { command -v "$1" >/dev/null 2>&1; }
log()     { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
_ok()     { echo -e "\033[32m[✓]\033[0m $*"; }
_warn()   { echo -e "\033[33m[!]\033[0m $*"; }
_err()    { echo -e "\033[31m[x]\033[0m $*" >&2; }
_info()   { echo "[i] $*"; }
red()     { echo -e "\033[31m$1\033[0m"; }
green()   { echo -e "\033[32m$1\033[0m"; }
yellow()  { echo -e "\033[33m$1\033[0m"; }

# 检测 init 系统
detect_init_system() {
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        echo "systemd"
    elif command -v rc-service >/dev/null 2>&1; then
        echo "openrc"
    elif [[ -f /etc/init.d/cron ]]; then
        echo "sysvinit"
    else
        echo "unknown"
    fi
}

# 检查并启动 Docker 服务
check_docker_service() {
    local init_sys
    init_sys=$(detect_init_system)

    case "$init_sys" in
        systemd)
            if ! systemctl is-active --quiet docker; then
                yellow "Docker 服务未运行，尝试启动..."
                systemctl start docker || { red "无法启动 Docker"; exit 1; }
            fi
            ;;
        openrc)
            if ! rc-service docker status >/dev/null 2>&1; then
                yellow "Docker 服务未运行，尝试启动..."
                rc-service docker start || { red "无法启动 Docker"; exit 1; }
            fi
            ;;
        *)
            if ! docker info >/dev/null 2>&1; then
                red "Docker 服务未运行且无法自动启动"
                exit 1
            fi
            ;;
    esac
    green "Docker 服务正常运行"
}

# 安装 Docker（优先 get.docker.com 官方脚本）
install_docker_deps() {
    if command -v docker >/dev/null 2>&1; then
        green "Docker 已安装"
        check_docker_service
        return 0
    fi

    log "安装 Docker..."

    # 优先使用官方安装脚本（最可靠、跨平台）
    if curl -fsSL https://get.docker.com -o /tmp/get-docker.sh; then
        sh /tmp/get-docker.sh || { red "Docker 安装失败"; exit 1; }
        rm -f /tmp/get-docker.sh
    else
        red "无法下载 Docker 安装脚本，请手动安装"
        exit 1
    fi

    local init_sys
    init_sys=$(detect_init_system)
    case "$init_sys" in
        systemd) systemctl enable docker && systemctl start docker ;;
        openrc)  rc-update add docker && rc-service docker start ;;
    esac

    green "Docker 安装完成"
    check_docker_service
}
