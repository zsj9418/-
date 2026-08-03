#!/usr/bin/env bash
set -o pipefail
readonly SCRIPT_VERSION="1.2.8"
readonly SCRIPT_NAME="OpenClaw Manager"
readonly CONFIG_DIR="${OPENCLAW_CONFIG_DIR:-$HOME/.openclaw}"
readonly CONFIG_FILE="$CONFIG_DIR/openclaw.json"
readonly LOG_DIR="$CONFIG_DIR/logs"
readonly AGENTS_DIR="$CONFIG_DIR/agents"
readonly CACHE_FILE="$CONFIG_DIR/.manager_cache"
readonly SCRIPT_LOG="/tmp/openclaw_manager_$(date +%Y%m%d).log"
readonly DOCKER_IMAGE="${OPENCLAW_DOCKER_IMAGE:-ghcr.io/openclaw/openclaw}"
readonly DOCKER_IMAGE_MIRROR="openclaw/openclaw"
readonly DOCKER_CONTAINER="${OPENCLAW_CONTAINER:-openclaw-core}"
readonly DOCKER_DATA_DIR="${OPENCLAW_DATA_DIR:-$HOME/openclaw}"
readonly DOCKER_UID=1000
readonly DEFAULT_PORT="${OPENCLAW_PORT:-18789}"
readonly HEALTH_TIMEOUT=30
readonly SERVICE_CANDIDATES=("openclaw" "openclaw-gateway")
readonly NODE_MIN_VERSION=22
readonly NODE_RECOMMENDED_VERSION=24
readonly INSTALL_SCRIPT_URL="https://openclaw.ai/install.sh"
readonly NPM_MIRROR="https://registry.npmmirror.com"
readonly NODE_BINARY_MIRROR="https://npmmirror.com/mirrors/node"
readonly NVM_INSTALL_GITEE="https://gitee.com/mirrors/nvm/raw/master/install.sh"
readonly NVM_INSTALL_GITHUB="https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh"
readonly GHCR_MIRRORS=("ghcr.nju.edu.cn" "ghcr.1ms.run")
readonly DOCKER_MIRRORS_JSON='["https://docker.1ms.run","https://docker.m.daocloud.io","https://docker.xuanyuan.me"]'
CN_MODE=false
OS=""
PKG_MGR=""
SERVICE_MGR=""
ARCH=""
readonly C='\033[0m'
readonly CB='\033[1m'
readonly CD='\033[2m'
readonly CR='\033[31m'
readonly CG='\033[32m'
readonly CY='\033[33m'
readonly CB2='\033[34m'
readonly CC='\033[36m'
log() { echo "[$(date '+%H:%M:%S')] $*" >> "$SCRIPT_LOG" 2>/dev/null; }
out() { echo -e "$*"; }
ok() { out "${CG}✓${C} $*"; log "OK: $*"; }
err() { out "${CR}✗${C} $*" >&2; log "ERR: $*"; }
warn() { out "${CY}!${C} $*"; log "WARN: $*"; }
info() { out "${CB2}→${C} $*"; log "INFO: $*"; }
step() { out "\n${CB}$*${C}"; }
substep() { out "  ${CD}·${C} $*"; }
line() { out "${CD}$(printf '─%.0s' {1..50})${C}"; }
has_cmd() { command -v "$1" &>/dev/null; }
read_input() {
    local varname="$1" default="${2:-}" input=""
    read -r input </dev/tty 2>/dev/null || input=""
    if [[ -z "$input" ]]; then
        eval "$varname=\"\$default\""
    else
        eval "$varname=\"\$input\""
    fi
}
read_secret() {
    local varname="$1" default="${2:-}" input=""
    read -rs input </dev/tty 2>/dev/null || input=""
    echo ""
    if [[ -z "$input" ]]; then
        eval "$varname=\"\$default\""
    else
        eval "$varname=\"\$input\""
    fi
}
confirm() {
    local prompt="${1:-确认}" answer=""
    echo -ne "${CY}?${C} ${prompt} [y/N]: "
    read -r answer </dev/tty 2>/dev/null || answer="n"
    [[ "$answer" =~ ^[Yy]$ ]]
}
confirm_yes() {
    local prompt="${1:-确认}" answer=""
    echo -ne "${CY}?${C} ${prompt} [Y/n]: "
    read -r answer </dev/tty 2>/dev/null || answer="y"
    [[ -z "$answer" ]] && answer="y"
    [[ "$answer" =~ ^[Nn]$ ]] && return 1
    return 0
}
wait_key() {
    echo -ne "\n${CD}${1:-按回车继续...}${C}"
    read -r </dev/tty 2>/dev/null || true
}
get_local_ip() {
    hostname -I 2>/dev/null | awk '{print $1}' ||
    ipconfig getifaddr en0 2>/dev/null ||
    ipconfig getifaddr en1 2>/dev/null ||
    echo "127.0.0.1"
}
cache_get() {
    local key="$1"
    [[ -f "$CACHE_FILE" ]] || return 1
    local val=""
    val=$(grep "^${key}=" "$CACHE_FILE" 2>/dev/null | tail -1 | cut -d= -f2-)
    [[ -n "$val" ]] && echo "$val" && return 0
    return 1
}
cache_set() {
    local key="$1" val="$2"
    mkdir -p "$CONFIG_DIR"
    if [[ -f "$CACHE_FILE" ]]; then
        local tmp="${CACHE_FILE}.tmp"
        grep -v "^${key}=" "$CACHE_FILE" > "$tmp" 2>/dev/null || true
        echo "${key}=${val}" >> "$tmp"
        mv "$tmp" "$CACHE_FILE"
    else
        echo "${key}=${val}" > "$CACHE_FILE"
    fi
}
detect_china_network() {
    local cached=""
    cached=$(cache_get "cn" 2>/dev/null) || true
    if [[ "$cached" == "1" ]]; then CN_MODE=true; return 0; fi
    if [[ "$cached" == "0" ]]; then CN_MODE=false; return 0; fi
    local cn_score=0
    if curl -s --max-time 2 --connect-timeout 1 "https://registry.npmmirror.com/" &>/dev/null; then
        ((cn_score++)) || true
    fi
    if ! curl -s --max-time 2 --connect-timeout 1 "https://registry.npmjs.org/" &>/dev/null; then
        ((cn_score++)) || true
    fi
    if [[ "$(curl -s --max-time 2 --connect-timeout 1 https://ipinfo.io/country 2>/dev/null)" == "CN" ]]; then
        ((cn_score++)) || true
    fi
    if [[ $cn_score -ge 1 ]]; then
        CN_MODE=true
        cache_set "cn" "1"
    else
        CN_MODE=false
        cache_set "cn" "0"
    fi
}
detect_system() {
    ARCH=$(uname -m)
    if [[ "$OSTYPE" == "darwin"* ]]; then
        OS="macos"; PKG_MGR="brew"; SERVICE_MGR="launchd"
    elif [[ -f /etc/os-release ]]; then
        source /etc/os-release
        case "${ID:-}" in
            ubuntu|debian|linuxmint|pop|raspbian) OS="debian"; PKG_MGR="apt" ;;
            centos|rhel|rocky|almalinux) OS="rhel"; PKG_MGR="yum" ;;
            fedora) OS="fedora"; PKG_MGR="dnf" ;;
            arch|manjaro) OS="arch"; PKG_MGR="pacman" ;;
            alpine) OS="alpine"; PKG_MGR="apk" ;;
            *) OS="linux"; PKG_MGR="unknown" ;;
        esac
        SERVICE_MGR="systemd"
        [[ "$OS" == "alpine" ]] && SERVICE_MGR="openrc"
    else
        OS="unknown"; PKG_MGR="unknown"; SERVICE_MGR="unknown"
    fi
}
install_pkg() {
    local pkg="$1"
    case "$PKG_MGR" in
        apt) sudo apt-get install -y "$pkg" >> "$SCRIPT_LOG" 2>&1 ;;
        yum) sudo yum install -y "$pkg" >> "$SCRIPT_LOG" 2>&1 ;;
        dnf) sudo dnf install -y "$pkg" >> "$SCRIPT_LOG" 2>&1 ;;
        pacman) sudo pacman -S --noconfirm "$pkg" >> "$SCRIPT_LOG" 2>&1 ;;
        apk) sudo apk add "$pkg" >> "$SCRIPT_LOG" 2>&1 ;;
        brew) brew install "$pkg" >> "$SCRIPT_LOG" 2>&1 ;;
        *) return 1 ;;
    esac
}
update_pkg_index() {
    case "$PKG_MGR" in
        apt) sudo apt-get update -qq >> "$SCRIPT_LOG" 2>&1 ;;
        yum) sudo yum makecache -q >> "$SCRIPT_LOG" 2>&1 ;;
        dnf) sudo dnf makecache -q >> "$SCRIPT_LOG" 2>&1 ;;
        pacman) sudo pacman -Sy >> "$SCRIPT_LOG" 2>&1 ;;
        apk) sudo apk update >> "$SCRIPT_LOG" 2>&1 ;;
        brew) brew update >> "$SCRIPT_LOG" 2>&1 ;;
    esac
}
ensure_dependencies() {
    local cached_deps=""
    cached_deps=$(cache_get "deps_ts" 2>/dev/null) || true
    if [[ -n "$cached_deps" ]]; then
        local now
        now=$(date +%s)
        local age=$(( now - cached_deps ))
        if [[ $age -lt 86400 ]]; then
            return 0
        fi
    fi
    local need_install=false
    local all_cmds=("curl" "python3" "jq")
    local missing=()
    for cmd in "${all_cmds[@]}"; do
        if ! has_cmd "$cmd"; then
            missing+=("$cmd")
            need_install=true
        fi
    done
    if $need_install; then
        step "安装缺失依赖: ${missing[*]}"
        update_pkg_index
        for pkg in "${missing[@]}"; do
            substep "安装 $pkg..."
            if install_pkg "$pkg"; then
                ok "$pkg"
            else
                [[ "$pkg" == "curl" ]] && { err "$pkg 安装失败,无法继续"; return 1; }
                warn "$pkg 安装失败 (非关键)"
            fi
        done
    fi
    cache_set "deps_ts" "$(date +%s)"
    return 0
}
setup_npm_mirror() {
    if ! $CN_MODE; then return 0; fi
    has_cmd npm || return 0
    local current=""
    current=$(npm config get registry 2>/dev/null) || true
    if [[ "$current" == *"npmmirror"* ]] || [[ "$current" == *"tencent"* ]] || [[ "$current" == *"huawei"* ]]; then
        return 0
    fi
    info "配置 npm 国内镜像源..."
    npm config set registry "$NPM_MIRROR" >> "$SCRIPT_LOG" 2>&1
    ok "npm → npmmirror.com"
}
setup_npm_prefix() {
    has_cmd npm || return 0
    if [[ "$OSTYPE" == "darwin"* ]] || [[ $(id -u) -eq 0 ]]; then return 0; fi
    local prefix=""
    prefix=$(npm prefix -g 2>/dev/null) || true
    if [[ -n "$prefix" ]] && [[ -w "$prefix" ]]; then return 0; fi
    info "配置 npm 用户目录..."
    mkdir -p "$HOME/.npm-global"
    npm config set prefix "$HOME/.npm-global" >> "$SCRIPT_LOG" 2>&1
    export PATH="$HOME/.npm-global/bin:$PATH"
    if ! grep -q '.npm-global/bin' "$HOME/.bashrc" 2>/dev/null; then
        echo 'export PATH="$HOME/.npm-global/bin:$PATH"' >> "$HOME/.bashrc"
    fi
    if [[ -f "$HOME/.zshrc" ]] && ! grep -q '.npm-global/bin' "$HOME/.zshrc" 2>/dev/null; then
        echo 'export PATH="$HOME/.npm-global/bin:$PATH"' >> "$HOME/.zshrc"
    fi
}
npm_install_cmd() {
    if $CN_MODE; then
        npm install "$@" --registry="$NPM_MIRROR" 2>&1
    else
        npm install "$@" 2>&1
    fi
}
docker_pull_ghcr() {
    local image="$1" tag="${2:-latest}"
    local full="${image}:${tag}"
    info "拉取 ${full}..."
    if docker pull "$full" >> "$SCRIPT_LOG" 2>&1; then
        ok "拉取成功 (直连)"
        return 0
    fi
    if $CN_MODE; then
        local org_path="${image#ghcr.io/}"
        for mirror in "${GHCR_MIRRORS[@]}"; do
            local mirror_image="${mirror}/${org_path}:${tag}"
            info "尝试 ${mirror}..."
            if docker pull "$mirror_image" >> "$SCRIPT_LOG" 2>&1; then
                docker tag "$mirror_image" "$full" >> "$SCRIPT_LOG" 2>&1
                ok "拉取成功 (${mirror})"
                return 0
            fi
        done
    fi
    info "尝试 Docker Hub..."
    if docker pull "${DOCKER_IMAGE_MIRROR}:${tag}" >> "$SCRIPT_LOG" 2>&1; then
        docker tag "${DOCKER_IMAGE_MIRROR}:${tag}" "$full" >> "$SCRIPT_LOG" 2>&1
        ok "拉取成功 (Docker Hub)"
        return 0
    fi
    err "所有镜像源拉取失败"
    return 1
}
setup_docker_mirrors() {
    if ! $CN_MODE; then return 0; fi
    if ! has_cmd docker; then return 0; fi
    local daemon_json="/etc/docker/daemon.json"
    if [[ -f "$daemon_json" ]] && grep -q "registry-mirrors" "$daemon_json" 2>/dev/null; then
        return 0
    fi
    if confirm "配置 Docker 国内镜像加速器"; then
        sudo mkdir -p /etc/docker
        echo '{
  "registry-mirrors": [
    "https://docker.1ms.run",
    "https://docker.m.daocloud.io",
    "https://docker.xuanyuan.me"
  ]
}' | sudo tee "$daemon_json" > /dev/null
        sudo systemctl daemon-reload 2>/dev/null || true
        sudo systemctl restart docker 2>/dev/null || true
        ok "Docker 加速器已配置"
    fi
}
is_docker_mode() {
    if has_cmd openclaw; then return 1; fi
    docker ps -a 2>/dev/null | grep -q "$DOCKER_CONTAINER"
}
is_installed() {
    has_cmd openclaw || docker ps -a 2>/dev/null | grep -q "$DOCKER_CONTAINER"
}
get_config_path() {
    if is_docker_mode; then
        echo "${DOCKER_DATA_DIR}/.openclaw/openclaw.json"
    else
        echo "$CONFIG_FILE"
    fi
}
oc_cmd() {
    if has_cmd openclaw; then
        openclaw "$@"
    elif docker ps 2>/dev/null | grep -q "$DOCKER_CONTAINER"; then
        docker exec "$DOCKER_CONTAINER" openclaw "$@"
    else
        err "OpenClaw 未安装"
        return 1
    fi
}
json_valid() {
    local cfg="${1:-$(get_config_path)}"
    [[ ! -f "$cfg" ]] && return 1
    if has_cmd python3; then
        python3 -c "import json; json.load(open('$cfg'))" 2>/dev/null
    elif has_cmd jq; then
        jq empty "$cfg" 2>/dev/null
    else
        return 0
    fi
}
create_minimal_config() {
    local cfg="${1:-$(get_config_path)}"
    mkdir -p "$(dirname "$cfg")"
    printf '%s\n' '{
  "gateway": {
    "mode": "local",
    "bind": "loopback"
  },
  "models": {
    "mode": "merge",
    "providers": {}
  },
  "agents": {
    "defaults": {
      "workspace": "~/.openclaw/workspace"
    },
    "list": [
      {"id": "main", "default": true}
    ]
  }
}' > "$cfg"
    chmod 600 "$cfg"
}
ensure_config() {
    local cfg=""
    cfg=$(get_config_path)
    if [[ ! -f "$cfg" ]]; then
        info "创建默认配置..."
        create_minimal_config "$cfg"
        return 0
    fi
    if ! json_valid "$cfg"; then
        warn "配置损坏"
        if confirm "备份并重建"; then
            cp "$cfg" "${cfg}.bak.$(date +%s)"
            create_minimal_config "$cfg"
            ok "已重建"
        else
            return 1
        fi
    fi
    return 0
}
config_get() {
    local key="$1" cfg=""
    cfg=$(get_config_path)
    [[ ! -f "$cfg" ]] && return 1
    has_cmd python3 || return 1
    python3 -c "
import json
try:
    c = json.load(open('$cfg'))
    keys = '$key'.split('.')
    v = c
    for k in keys:
        v = v.get(k, {}) if isinstance(v, dict) else {}
    if isinstance(v, dict):
        print('')
    else:
        print(v)
except:
    print('')
" 2>/dev/null
}
config_set() {
    local key="$1" value="$2" cfg=""
    cfg=$(get_config_path)
    [[ ! -f "$cfg" ]] && create_minimal_config "$cfg"
    has_cmd python3 || return 1
    python3 - "$cfg" "$key" "$value" << 'PYEOF'
import json, sys, os
cfg_path, key, value = sys.argv[1:4]
try:
    with open(cfg_path) as f:
        c = json.load(f)
except:
    c = {}
keys = key.split('.')
target = c
for k in keys[:-1]:
    target = target.setdefault(k, {})
if value.lower() == 'true': value = True
elif value.lower() == 'false': value = False
elif value.isdigit(): value = int(value)
target[keys[-1]] = value
with open(cfg_path, 'w') as f:
    json.dump(c, f, indent=2, ensure_ascii=False)
PYEOF
    chmod 600 "$cfg"
}
sanitize_config() {
    local cfg="${1:-$(get_config_path)}"
    [[ ! -f "$cfg" ]] && return 1
    has_cmd python3 || return 0
    json_valid "$cfg" || return 1
    python3 - "$cfg" << 'PYEOF'
import json, sys, os
cfg_path = sys.argv[1]
VALID_BIND = ["auto", "lan", "loopback", "custom", "tailnet"]
BAD_ROOT = ["ui", "defaultProvider"]
try:
    with open(cfg_path, 'r') as f:
        cfg = json.load(f)
except:
    sys.exit(1)
changed = False
gw = cfg.setdefault("gateway", {})
if gw.get("bind") not in VALID_BIND:
    gw["bind"] = "loopback"
    changed = True
if not gw.get("mode"):
    gw["mode"] = "local"
    changed = True
for bad in BAD_ROOT:
    if bad in cfg:
        del cfg[bad]
        changed = True
if "agents" in cfg and isinstance(cfg["agents"], dict):
    for bad_key in list(cfg["agents"].keys()):
        if bad_key not in ["defaults", "list"]:
            del cfg["agents"][bad_key]
            changed = True
providers = cfg.get("models", {}).get("providers", {})
if isinstance(providers, dict):
    for name, p in providers.items():
        if isinstance(p, dict) and not p.get("api"):
            p["api"] = "openai-completions"
            changed = True
if changed:
    tmp = cfg_path + ".tmp"
    with open(tmp, 'w') as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
    os.replace(tmp, cfg_path)
PYEOF
    chmod 600 "$cfg" 2>/dev/null
}
check_gateway_health() {
    local port="${1:-$DEFAULT_PORT}"
    curl -s --max-time 2 --connect-timeout 1 "http://127.0.0.1:${port}" &>/dev/null && return 0
    curl -s --max-time 2 --connect-timeout 1 "http://127.0.0.1:${port}/health" &>/dev/null && return 0
    return 1
}
get_service_status() {
    if ! is_installed; then echo "未安装"; return 1; fi
    if check_gateway_health; then echo "运行中"; return 0; fi
    echo "已停止"; return 1
}
service_start() {
    step "启动服务..."
    if ! is_installed; then err "OpenClaw 未安装"; return 1; fi
    ensure_config || return 1
    sanitize_config
    if is_docker_mode; then
        info "启动 Docker 容器..."
        docker start "$DOCKER_CONTAINER" >/dev/null 2>&1
    else
        pkill -9 -f "openclaw.*gateway" 2>/dev/null || true
        sleep 1
        if has_cmd lsof; then
            local pid=""
            pid=$(lsof -ti :"$DEFAULT_PORT" 2>/dev/null | head -1) || true
            [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null || true
        fi
        oc_cmd doctor --fix >> "$SCRIPT_LOG" 2>&1 || true
        local started=false
        for svc in "${SERVICE_CANDIDATES[@]}"; do
            if systemctl --user start "$svc" 2>/dev/null || sudo systemctl start "$svc" 2>/dev/null; then
                started=true; break
            fi
        done
        if ! $started; then
            mkdir -p "$LOG_DIR"
            nohup openclaw gateway run > "$LOG_DIR/gateway.out" 2>&1 &
        fi
    fi
    info "等待服务就绪..."
    local i=0
    while (( i < HEALTH_TIMEOUT )); do
        sleep 1
        if check_gateway_health; then
            ok "服务已启动"
            show_access_info
            return 0
        fi
        i=$((i + 1))
    done
    err "启动超时"
    if is_docker_mode; then
        docker logs --tail 15 "$DOCKER_CONTAINER" 2>&1 | sed 's/^/  /'
    else
        tail -15 "$LOG_DIR/gateway.out" 2>/dev/null | sed 's/^/  /'
    fi
    return 1
}
service_stop() {
    step "停止服务..."
    if is_docker_mode; then
        docker stop "$DOCKER_CONTAINER" >/dev/null 2>&1 && ok "已停止"
    else
        for svc in "${SERVICE_CANDIDATES[@]}"; do
            systemctl --user stop "$svc" 2>/dev/null || sudo systemctl stop "$svc" 2>/dev/null || true
        done
        pkill -9 -f "openclaw.*gateway" 2>/dev/null || true
        ok "已停止"
    fi
}
service_restart() {
    service_stop
    sleep 2
    service_start
}
service_status() {
    step "服务状态"
    line
    local status="" mode=""
    status=$(get_service_status 2>/dev/null) || true
    if is_docker_mode; then mode="Docker"; elif has_cmd openclaw; then mode="本地"; else mode="-"; fi
    out "  状态: ${CB}${status}${C}"
    out "  模式: ${mode}"
    out "  端口: ${DEFAULT_PORT}"
    if is_docker_mode; then
        out "  容器: $(docker ps --filter name=$DOCKER_CONTAINER --format '{{.Status}}' 2>/dev/null)"
    fi
    if has_cmd openclaw; then
        out "  版本: $(openclaw --version 2>/dev/null)"
    fi
    line
    if [[ "$status" == "运行中" ]]; then show_access_info; fi
}
show_access_info() {
    local ip="" port="" bind="" token=""
    ip=$(get_local_ip)
    port="$DEFAULT_PORT"
    bind=$(config_get "gateway.bind" 2>/dev/null) || true
    token=$(config_get "gateway.auth.token" 2>/dev/null) || true
    out ""
    out "${CC}访问地址${C}"
    line
    out "  本机:   http://127.0.0.1:${port}"
    if [[ "$bind" == "lan" ]]; then
        local url="http://${ip}:${port}"
        [[ -n "$token" ]] && url="${url}?token=${token}"
        out "  局域网: ${CG}${url}${C}"
    else
        out "  局域网: ${CD}未启用${C}"
    fi
    [[ -n "$token" ]] && out "  令牌:   ${CY}${token}${C}"
    line
}
refresh_node_path() {
    local nd=""
    if [[ -d "$HOME/.nvm/versions/node" ]]; then
        nd=$(ls -d "$HOME/.nvm/versions/node/"v* 2>/dev/null | sort -V | tail -1) || true
    fi
    [[ -n "$nd" ]] && [[ -d "${nd}/bin" ]] && export PATH="${nd}/bin:$PATH"
    [[ -d "$HOME/.npm-global/bin" ]] && export PATH="$HOME/.npm-global/bin:$PATH"
    [[ -d "$HOME/.local/bin" ]] && export PATH="$HOME/.local/bin:$PATH"
    export NVM_DIR="$HOME/.nvm"
    [[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh" 2>/dev/null || true
}
install_nodejs() {
    step "安装 Node.js..."
    if has_cmd node; then
        local ver=""
        ver=$(node -v | sed 's/v//' | cut -d. -f1)
        if [[ "$ver" -ge "$NODE_MIN_VERSION" ]]; then
            ok "Node.js v${ver} 已满足要求"
            return 0
        fi
        info "Node.js v${ver} 过低,需要 >= v${NODE_MIN_VERSION}"
    fi
    local version="$NODE_RECOMMENDED_VERSION"
    out "安装方式:"
    out "  [1] NodeSource (推荐)"
    out "  [2] nvm"
    out "  [3] 系统包管理器"
    echo -ne "选择 [1]: "
    local choice=""
    read_input choice "1"
    case "$choice" in
        2)
            info "安装 nvm..."
            if $CN_MODE; then
                export NVM_NODEJS_ORG_MIRROR="$NODE_BINARY_MIRROR"
                curl -fsSL "$NVM_INSTALL_GITEE" 2>/dev/null | bash >> "$SCRIPT_LOG" 2>&1 ||
                curl -fsSL "$NVM_INSTALL_GITHUB" 2>/dev/null | bash >> "$SCRIPT_LOG" 2>&1
            else
                curl -fsSL "$NVM_INSTALL_GITHUB" 2>/dev/null | bash >> "$SCRIPT_LOG" 2>&1
            fi
            export NVM_DIR="$HOME/.nvm"
            source "$NVM_DIR/nvm.sh" 2>/dev/null || true
            if $CN_MODE; then
                export NVM_NODEJS_ORG_MIRROR="$NODE_BINARY_MIRROR"
                if ! grep -q 'NVM_NODEJS_ORG_MIRROR' "$HOME/.bashrc" 2>/dev/null; then
                    echo "export NVM_NODEJS_ORG_MIRROR=\"$NODE_BINARY_MIRROR\"" >> "$HOME/.bashrc"
                fi
            fi
            nvm install "$version" >> "$SCRIPT_LOG" 2>&1
            nvm use "$version" >> "$SCRIPT_LOG" 2>&1
            nvm alias default "$version" >> "$SCRIPT_LOG" 2>&1
            ;;
        3)
            info "使用系统包管理器..."
            install_pkg nodejs
            install_pkg npm
            ;;
        *)
            info "使用 NodeSource..."
            case "$OS" in
                debian)
                    if $CN_MODE; then
                        curl -fsSL "https://deb.nodesource.com/setup_${version}.x" 2>/dev/null | sudo -E bash - >> "$SCRIPT_LOG" 2>&1 ||
                        curl -fsSL "https://mirrors.tuna.tsinghua.edu.cn/nodesource/setup_${version}.x" 2>/dev/null | sudo -E bash - >> "$SCRIPT_LOG" 2>&1
                    else
                        curl -fsSL "https://deb.nodesource.com/setup_${version}.x" | sudo -E bash - >> "$SCRIPT_LOG" 2>&1
                    fi
                    sudo apt-get install -y nodejs >> "$SCRIPT_LOG" 2>&1
                    ;;
                rhel|fedora)
                    curl -fsSL "https://rpm.nodesource.com/setup_${version}.x" | sudo bash - >> "$SCRIPT_LOG" 2>&1
                    sudo "$PKG_MGR" install -y nodejs >> "$SCRIPT_LOG" 2>&1
                    ;;
                macos)
                    brew install "node@${version}" >> "$SCRIPT_LOG" 2>&1
                    brew link --force --overwrite "node@${version}" 2>/dev/null || true
                    ;;
                *)
                    curl -fsSL "https://deb.nodesource.com/setup_${version}.x" | sudo -E bash - >> "$SCRIPT_LOG" 2>&1 || true
                    sudo apt-get install -y nodejs >> "$SCRIPT_LOG" 2>&1 || install_pkg nodejs
                    ;;
            esac
            ;;
    esac
    refresh_node_path
    if has_cmd node; then
        local iv=""
        iv=$(node -v | sed 's/v//' | cut -d. -f1)
        if [[ "$iv" -ge "$NODE_MIN_VERSION" ]]; then
            ok "Node.js $(node -v) 已安装"
            return 0
        fi
    fi
    err "Node.js 安装失败"
    return 1
}
install_build_deps() {
    case "$OS" in
        debian) sudo apt-get install -y build-essential python3 git ca-certificates >> "$SCRIPT_LOG" 2>&1 ;;
        rhel) sudo yum install -y gcc gcc-c++ make python3 git >> "$SCRIPT_LOG" 2>&1 ;;
        fedora) sudo dnf install -y gcc gcc-c++ make python3 git >> "$SCRIPT_LOG" 2>&1 ;;
        arch) sudo pacman -S --noconfirm base-devel python git >> "$SCRIPT_LOG" 2>&1 ;;
        alpine) sudo apk add build-base python3 git >> "$SCRIPT_LOG" 2>&1 ;;
        macos) has_cmd git || brew install git >> "$SCRIPT_LOG" 2>&1 ;;
    esac
}
install_local() {
    local arg_lan="${1:-}" arg_token="${2:-}"
    step "本地安装 OpenClaw"
    if has_cmd openclaw; then
        warn "已安装: $(openclaw --version 2>/dev/null)"
        confirm "重新安装" || return 0
    fi
    $CN_MODE && info "中国网络,已启用加速"
    substep "编译依赖..."
    install_build_deps
    install_nodejs || return 1
    has_cmd npm || { err "npm 不可用"; return 1; }
    setup_npm_mirror
    setup_npm_prefix
    out ""
    out "安装方式:"
    out "  [1] 官方脚本 (推荐)"
    out "  [2] npm 安装"
    echo -ne "选择 [1]: "
    local choice=""
    read_input choice "1"
    info "正在安装..."
    case "$choice" in
        2)
            npm_install_cmd -g openclaw@latest >> "$SCRIPT_LOG" 2>&1
            ;;
        *)
            if $CN_MODE; then
                npm_install_cmd -g openclaw@latest >> "$SCRIPT_LOG" 2>&1 ||
                curl -fsSL "$INSTALL_SCRIPT_URL" 2>/dev/null | bash >> "$SCRIPT_LOG" 2>&1
            else
                curl -fsSL "$INSTALL_SCRIPT_URL" 2>/dev/null | bash >> "$SCRIPT_LOG" 2>&1 ||
                npm_install_cmd -g openclaw@latest >> "$SCRIPT_LOG" 2>&1
            fi
            ;;
    esac
    refresh_node_path
    if ! has_cmd openclaw; then
        err "安装失败,日志: $SCRIPT_LOG"
        $CN_MODE && out "  手动: npm install -g openclaw@latest --registry=$NPM_MIRROR"
        return 1
    fi
    ok "OpenClaw $(openclaw --version 2>/dev/null) 已安装"
    ensure_config
    if [[ "$arg_lan" == "true" ]]; then
        step "配置局域网访问..."
        local cfg=""
        cfg=$(get_config_path)
        if has_cmd python3; then
            python3 - "$cfg" "$arg_token" << 'PYEOF'
import json, sys, os
cfg_path, token = sys.argv[1], sys.argv[2]
os.makedirs(os.path.dirname(cfg_path), exist_ok=True)
try:
    with open(cfg_path) as f: c = json.load(f)
except: c = {}
gw = c.setdefault("gateway", {})
gw["mode"] = "local"
gw["bind"] = "lan"
if token:
    auth = gw.setdefault("auth", {})
    auth["mode"] = "token"
    auth["token"] = token
ui = gw.setdefault("controlUi", {})
ui["allowInsecureAuth"] = True
ui["dangerouslyAllowHostHeaderOriginFallback"] = True
ui["dangerouslyDisableDeviceAuth"] = True
with open(cfg_path, 'w') as f:
    json.dump(c, f, indent=2, ensure_ascii=False)
PYEOF
            chmod 600 "$cfg"
        fi
        ok "局域网已配置"
    fi
    oc_cmd doctor --fix >> "$SCRIPT_LOG" 2>&1 || true
    step "启动服务..."
    service_start
    return 0
}
install_docker() {
    local arg_lan="${1:-}" arg_token="${2:-}"
    step "Docker 部署 OpenClaw"
    if ! has_cmd docker; then
        warn "Docker 未安装"
        if confirm "自动安装"; then
            info "安装 Docker..."
            curl -fsSL https://get.docker.com | sh >> "$SCRIPT_LOG" 2>&1
            sudo systemctl enable --now docker 2>/dev/null || true
            sudo usermod -aG docker "$USER" 2>/dev/null || true
            if ! has_cmd docker; then err "Docker 安装失败"; return 1; fi
            ok "Docker 已安装"
        else
            return 1
        fi
    fi
    $CN_MODE && setup_docker_mirrors
    if docker ps -a 2>/dev/null | grep -q "$DOCKER_CONTAINER"; then
        local cs=""
        cs=$(docker inspect --format='{{.State.Status}}' "$DOCKER_CONTAINER" 2>/dev/null) || true
        warn "容器已存在 (${cs:-unknown})"
        out "  [1] 启动    [2] 停止    [3] 重启"
        out "  [4] 删除重建    [5] 日志"
        out "  [0] 返回"
        echo -ne "选择: "
        local choice=""
        read_input choice "0"
        case "$choice" in
            1) docker start "$DOCKER_CONTAINER" >/dev/null 2>&1 && ok "已启动" || err "启动失败" ;;
            2) docker stop "$DOCKER_CONTAINER" >/dev/null 2>&1 && ok "已停止" || err "停止失败" ;;
            3) docker restart "$DOCKER_CONTAINER" >/dev/null 2>&1 && ok "已重启" || err "重启失败" ;;
            4)
                if confirm "确认删除并重建"; then
                    docker rm -f "$DOCKER_CONTAINER" >/dev/null 2>&1
                    docker_deploy_new "$arg_lan" "$arg_token"
                fi
                ;;
            5) docker logs --tail 30 "$DOCKER_CONTAINER" 2>&1 ;;
            *) return 0 ;;
        esac
        return 0
    fi
    docker_deploy_new "$arg_lan" "$arg_token"
}
docker_deploy_new() {
    local arg_lan="${1:-}" arg_token="${2:-}"
    echo -ne "端口 [${DEFAULT_PORT}]: "
    local port=""
    read_input port "$DEFAULT_PORT"
    echo -ne "数据目录 [${DOCKER_DATA_DIR}]: "
    local data_dir=""
    read_input data_dir "$DOCKER_DATA_DIR"
    local enable_lan=false
    [[ "$arg_lan" == "true" ]] && enable_lan=true
    step "准备环境..."
    mkdir -p "${data_dir}/.openclaw" "${data_dir}/workspace"
    local bind_mode="loopback"
    $enable_lan && bind_mode="lan"
    local cfg="${data_dir}/.openclaw/openclaw.json"
    if [[ ! -f "$cfg" ]] || ! json_valid "$cfg"; then
        create_minimal_config "$cfg"
    fi
    local gw_token="$arg_token"
    if has_cmd python3; then
        python3 - "$cfg" "$bind_mode" "$gw_token" << 'PYEOF'
import json, sys
p, bm, token = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(p) as f: c = json.load(f)
except: c = {}
gw = c.setdefault("gateway", {})
gw["bind"] = bm
gw["mode"] = "local"
if bm == "lan":
    ui = gw.setdefault("controlUi", {})
    ui["allowInsecureAuth"] = True
    ui["dangerouslyAllowHostHeaderOriginFallback"] = True
    ui["dangerouslyDisableDeviceAuth"] = True
    auth = gw.setdefault("auth", {})
    auth["mode"] = "token"
    auth["token"] = token
c.setdefault("models", {"mode": "merge", "providers": {}})
c.setdefault("agents", {"defaults": {"workspace": "~/.openclaw/workspace"}, "list": [{"id": "main", "default": True}]})
with open(p, 'w') as f:
    json.dump(c, f, indent=2, ensure_ascii=False)
PYEOF
        chmod 600 "$cfg"
    fi
    chown -R "${DOCKER_UID}:${DOCKER_UID}" "${data_dir}" 2>/dev/null ||
    sudo chown -R "${DOCKER_UID}:${DOCKER_UID}" "${data_dir}" 2>/dev/null || true
    step "拉取镜像..."
    if ! docker_pull_ghcr "$DOCKER_IMAGE" "latest"; then
        err "无法拉取镜像"
        return 1
    fi
    local run_image="${DOCKER_IMAGE}:latest"
    if docker image inspect "$run_image" &>/dev/null; then
        true
    elif docker image inspect "${DOCKER_IMAGE_MIRROR}:latest" &>/dev/null; then
        run_image="${DOCKER_IMAGE_MIRROR}:latest"
    fi
    step "启动容器..."
    if ! docker run -d \
        --name "$DOCKER_CONTAINER" \
        --restart unless-stopped \
        -p "${port}:18789" \
        -v "${data_dir}/.openclaw:/home/node/.openclaw" \
        -v "${data_dir}/workspace:/home/node/workspace" \
        --add-host=host.docker.internal:host-gateway \
        "$run_image" >> "$SCRIPT_LOG" 2>&1; then
        err "容器创建失败"
        return 1
    fi
    sleep 3
    local st=""
    st=$(docker inspect --format='{{.State.Status}}' "$DOCKER_CONTAINER" 2>/dev/null) || true
    if [[ "$st" != "running" ]]; then
        err "容器异常退出 (${st:-unknown})"
        docker logs --tail 20 "$DOCKER_CONTAINER" 2>&1 | sed 's/^/  /'
        return 1
    fi
    step "等待服务就绪..."
    local i=0
    while (( i < HEALTH_TIMEOUT )); do
        sleep 1
        if check_gateway_health "$port"; then
            ok "部署成功"
            local ip=""
            ip=$(get_local_ip)
            out ""
            out "${CC}访问地址${C}"
            line
            out "  本机:   http://127.0.0.1:${port}"
            if $enable_lan; then
                local url="http://${ip}:${port}"
                [[ -n "$gw_token" ]] && url="${url}?token=${gw_token}"
                out "  局域网: ${CG}${url}${C}"
                out "  令牌:   ${CY}${gw_token}${C}"
            fi
            line
            return 0
        fi
        i=$((i + 1))
    done
    warn "服务未响应 (${HEALTH_TIMEOUT}s 超时)"
    docker logs --tail 20 "$DOCKER_CONTAINER" 2>&1 | sed 's/^/  /'
    return 1
}
configure_api() {
    step "配置 API"
    out "  [1] 自定义 API (OpenAI 兼容)"
    out "  [2] 官方 Provider"
    out "  [0] 返回"
    echo -ne "选择: "
    local choice=""
    read_input choice "1"
    case "$choice" in
        1) configure_custom_api ;;
        2) configure_builtin_api ;;
        0) return 0 ;;
    esac
}
configure_custom_api() {
    step "配置自定义 API"
    ensure_config || return 1
    echo -ne "Provider 名称 (建议: openai): "
    local name=""
    read_input name "openai"
    name=$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    echo -ne "API Base URL: "
    local url=""
    read_input url ""
    [[ -z "$url" ]] && { err "URL 不能为空"; return 1; }
    if is_docker_mode; then
        if [[ "$url" =~ ^https?://(127\.|localhost|192\.168\.|10\.) ]]; then
            local new_url=""
            new_url=$(echo "$url" | sed -E 's#(https?://)(127\.[0-9.]+|localhost|192\.168\.[0-9.]+|10\.[0-9.]+)#\1host.docker.internal#')
            info "Docker 模式: URL → $new_url"
            url="$new_url"
        fi
    fi
    echo -ne "API Key (本地服务输 'local'): "
    local key=""
    read_secret key "local"
    out "API 类型:"
    out "  [1] openai-completions    [2] openai-responses"
    out "  [3] ollama                [4] anthropic-messages"
    echo -ne "选择 [1]: "
    local api_choice=""
    read_input api_choice "1"
    local api_type="openai-completions"
    case "$api_choice" in
        2) api_type="openai-responses" ;;
        3) api_type="ollama" ;;
        4) api_type="anthropic-messages" ;;
    esac
    echo -ne "模型 ID (多个用逗号分隔): "
    local models=""
    read_input models ""
    [[ -z "$models" ]] && { err "模型不能为空"; return 1; }
    local default_model="${models%%,*}"
    default_model=$(echo "$default_model" | xargs)
    info "保存配置..."
    local cfg=""
    cfg=$(get_config_path)
    if has_cmd python3; then
        python3 - "$cfg" "$name" "$url" "$key" "$api_type" "$models" "$default_model" << 'PYEOF'
import json, sys, os
cfg_path, name, url, key, api_type, models_str, default_model = sys.argv[1:8]
os.makedirs(os.path.dirname(cfg_path), exist_ok=True)
try:
    with open(cfg_path) as f: c = json.load(f)
except: c = {}
c.setdefault("gateway", {"mode": "local", "bind": "loopback"})
if c["gateway"].get("bind") not in ["auto","lan","loopback","custom","tailnet"]:
    c["gateway"]["bind"] = "loopback"
c.setdefault("models", {"mode": "merge", "providers": {}})
c.setdefault("agents", {"defaults": {"workspace": "~/.openclaw/workspace"}, "list": [{"id": "main", "default": True}]})
model_list = []
for m in models_str.split(","):
    m = m.strip()
    if m:
        model_list.append({
            "id": m, "name": m, "reasoning": False,
            "input": ["text"], "contextWindow": 128000, "maxTokens": 8192,
            "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0}
        })
c["models"]["providers"][name] = {"baseUrl": url, "apiKey": key, "api": api_type, "models": model_list}
c["agents"]["defaults"]["model"] = {"primary": f"{name}/{default_model}"}
with open(cfg_path, 'w') as f:
    json.dump(c, f, indent=2, ensure_ascii=False)
PYEOF
        chmod 600 "$cfg"
    fi
    ok "配置已保存"
    if is_installed; then
        info "同步认证..."
        sync_agent_auth "$name" "$url" "$key" "$api_type"
        if [[ "$name" != "openai" ]]; then
            confirm "以 openai 别名注入 (推荐)" && sync_agent_auth "openai" "$url" "$key" "$api_type"
        fi
        oc_cmd doctor --fix >> "$SCRIPT_LOG" 2>&1 || true
        confirm "重启服务" && service_restart
    fi
    out ""
    ok "API 配置完成"
    line
    out "  Provider: ${CC}${name}${C}"
    out "  URL:      ${url}"
    out "  类型:     ${api_type}"
    out "  默认模型: ${CG}${name}/${default_model}${C}"
    line
}
configure_builtin_api() {
    step "官方 Provider"
    out "  [1] Anthropic    [2] OpenAI"
    out "  [3] Google       [4] DeepSeek"
    out "  [5] Groq         [6] Mistral"
    out "  [0] 返回"
    echo -ne "选择: "
    local choice=""
    read_input choice "0"
    local provider="" default_model="" base_url=""
    case "$choice" in
        1) provider="anthropic"; default_model="claude-sonnet-4-5"; base_url="https://api.anthropic.com" ;;
        2) provider="openai"; default_model="gpt-4o"; base_url="https://api.openai.com/v1" ;;
        3) provider="google"; default_model="gemini-2.5-flash"; base_url="https://generativelanguage.googleapis.com" ;;
        4) provider="deepseek"; default_model="deepseek-chat"; base_url="https://api.deepseek.com/v1" ;;
        5) provider="groq"; default_model="llama-3.3-70b-versatile"; base_url="https://api.groq.com/openai/v1" ;;
        6) provider="mistral"; default_model="mistral-large-latest"; base_url="https://api.mistral.ai/v1" ;;
        0) return 0 ;;
        *) err "无效"; return 1 ;;
    esac
    echo -ne "API Key: "
    local key=""
    read_secret key ""
    [[ -z "$key" ]] && { err "Key 不能为空"; return 1; }
    echo -ne "模型 [$default_model]: "
    local model=""
    read_input model "$default_model"
    ensure_config || return 1
    config_set "${provider}.apiKey" "$key"
    config_set "${provider}.model" "$model"
    ok "已配置 ${provider}"
    if is_installed; then
        sync_agent_auth "$provider" "$base_url" "$key" "openai-completions"
        oc_cmd doctor --fix >> "$SCRIPT_LOG" 2>&1 || true
        confirm "重启服务" && service_restart
    fi
}
sync_agent_auth() {
    local name="$1" url="$2" key="$3" api_type="$4"
    local base_dir=""
    if is_docker_mode; then
        base_dir="${DOCKER_DATA_DIR}/.openclaw/agents"
    else
        base_dir="$AGENTS_DIR"
    fi
    local auth_file="${base_dir}/main/agent/auth-profiles.json"
    mkdir -p "$(dirname "$auth_file")"
    has_cmd python3 || return 1
    python3 - "$auth_file" "$name" "$url" "$key" "$api_type" << 'PYEOF'
import json, sys
path, name, url, key, api_type = sys.argv[1:6]
try:
    with open(path) as f: data = json.load(f)
    if not isinstance(data, dict): data = {}
except: data = {}
entry = {"provider": name, "apiKey": key, "baseUrl": url, "api": api_type, "kind": "static", "portable": True}
if "profiles" in data and isinstance(data["profiles"], dict):
    data["profiles"][name] = entry
elif "providers" in data and isinstance(data["providers"], dict):
    data["providers"][name] = entry
else:
    data[name] = entry
with open(path, 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
PYEOF
    chmod 600 "$auth_file" 2>/dev/null
    if is_docker_mode; then
        chown -R "${DOCKER_UID}:${DOCKER_UID}" "${base_dir}" 2>/dev/null ||
        sudo chown -R "${DOCKER_UID}:${DOCKER_UID}" "${base_dir}" 2>/dev/null || true
    fi
    substep "已同步: $name"
}
configure_network() {
    step "网络设置"
    out "  [1] 启用局域网    [2] 管理令牌"
    out "  [3] 访问信息      [0] 返回"
    echo -ne "选择: "
    local choice=""
    read_input choice "0"
    case "$choice" in
        1) enable_lan_access ;;
        2) manage_token ;;
        3) show_access_info ;;
    esac
}
enable_lan_access() {
    step "启用局域网访问"
    ensure_config || return 1
    warn "将允许局域网设备访问,请勿暴露至公网!"
    confirm "继续" || return 0
    local existing_token=""
    existing_token=$(config_get "gateway.auth.token" 2>/dev/null) || true
    local token=""
    if [[ -n "$existing_token" ]]; then
        out "当前令牌: ${CY}${existing_token}${C}"
        if confirm "保留当前令牌"; then
            token="$existing_token"
        else
            token=$(openssl rand -hex 24 2>/dev/null || head -c 48 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 48) || true
        fi
    else
        token=$(openssl rand -hex 24 2>/dev/null || head -c 48 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 48) || true
    fi
    local cfg=""
    cfg=$(get_config_path)
    if has_cmd python3; then
        python3 - "$cfg" "$token" << 'PYEOF'
import json, sys, os
cfg_path, token = sys.argv[1], sys.argv[2]
os.makedirs(os.path.dirname(cfg_path), exist_ok=True)
try:
    with open(cfg_path) as f: c = json.load(f)
except: c = {}
gw = c.setdefault("gateway", {})
gw["mode"] = "local"
gw["bind"] = "lan"
auth = gw.setdefault("auth", {})
auth["mode"] = "token"
auth["token"] = token
ui = gw.setdefault("controlUi", {})
ui["allowInsecureAuth"] = True
ui["dangerouslyAllowHostHeaderOriginFallback"] = True
ui["dangerouslyDisableDeviceAuth"] = True
with open(cfg_path, 'w') as f:
    json.dump(c, f, indent=2, ensure_ascii=False)
PYEOF
        chmod 600 "$cfg"
    fi
    ok "局域网已启用"
    out "  令牌: ${CY}${token}${C}"
    local ip=""
    ip=$(get_local_ip)
    out "  地址: ${CG}http://${ip}:${DEFAULT_PORT}?token=${token}${C}"
    if is_docker_mode; then
        chown -R "${DOCKER_UID}:${DOCKER_UID}" "$(dirname "$cfg")" 2>/dev/null ||
        sudo chown -R "${DOCKER_UID}:${DOCKER_UID}" "$(dirname "$cfg")" 2>/dev/null || true
    fi
    if confirm "重启服务"; then
        service_restart
    fi
}
manage_token() {
    step "令牌管理"
    local token=""
    token=$(config_get "gateway.auth.token" 2>/dev/null) || true
    if [[ -n "$token" ]]; then out "当前: ${CY}${token}${C}"; else out "当前: ${CD}未设置${C}"; fi
    out "  [1] 生成新令牌    [2] 手动设置"
    out "  [3] 删除令牌      [0] 返回"
    echo -ne "选择: "
    local choice=""
    read_input choice "0"
    case "$choice" in
        1)
            token=$(openssl rand -hex 24 2>/dev/null || echo "$(date +%s%N)")
            config_set "gateway.auth.token" "$token"
            config_set "gateway.auth.mode" "token"
            ok "新令牌: ${token}"
            confirm "重启服务" && service_restart
            ;;
        2)
            echo -ne "输入令牌 (≥16字符): "
            local nt=""
            read_input nt ""
            if [[ ${#nt} -lt 16 ]]; then
                err "太短"
            else
                config_set "gateway.auth.token" "$nt"
                config_set "gateway.auth.mode" "token"
                ok "已设置"
                confirm "重启服务" && service_restart
            fi
            ;;
        3) confirm "确认删除" && { config_set "gateway.auth.token" ""; ok "已删除"; } ;;
    esac
}
diagnose() {
    step "系统诊断"
    line
    local issues=0
    substep "OpenClaw..."
    if is_installed; then
        ok "已安装 $(oc_cmd --version 2>/dev/null)"
    else
        err "未安装"
        issues=$((issues + 1))
    fi
    substep "配置文件..."
    local cfg=""
    cfg=$(get_config_path)
    if [[ -f "$cfg" ]]; then
        if json_valid "$cfg"; then ok "有效"; else err "损坏"; issues=$((issues + 1)); fi
    else
        warn "不存在"
        issues=$((issues + 1))
    fi
    substep "Schema 兼容..."
    if [[ -f "$cfg" ]] && json_valid "$cfg"; then sanitize_config "$cfg"; ok "已检查"; fi
    substep "服务状态..."
    if check_gateway_health; then ok "运行中"; else warn "未运行"; fi
    substep "端口 ${DEFAULT_PORT}..."
    if ss -lntp 2>/dev/null | grep -q ":${DEFAULT_PORT}\b"; then
        ok "已监听"
    elif has_cmd lsof && lsof -i ":${DEFAULT_PORT}" &>/dev/null; then
        ok "已监听"
    else
        warn "未监听"
    fi
    substep "Agent 认证..."
    local ab=""
    if is_docker_mode; then ab="${DOCKER_DATA_DIR}/.openclaw/agents"; else ab="$AGENTS_DIR"; fi
    if [[ -f "$ab/main/agent/auth-profiles.json" ]] || [[ -f "$ab/main/agent/openclaw-agent.sqlite" ]]; then
        ok "存在"
    else
        warn "缺失"
        issues=$((issues + 1))
    fi
    substep "网络模式..."
    if $CN_MODE; then
        ok "中国网络 (加速已启用)"
        out "    npm: $(npm config get registry 2>/dev/null)"
    else
        ok "国际网络"
    fi
    line
    out "问题数: $issues"
    if [[ $issues -gt 0 ]] && confirm "尝试自动修复"; then repair_all; fi
}
repair_all() {
    step "自动修复"
    local cfg=""
    cfg=$(get_config_path)
    if [[ ! -f "$cfg" ]] || ! json_valid "$cfg"; then
        substep "重建配置..."
        [[ -f "$cfg" ]] && cp "$cfg" "${cfg}.bak.$(date +%s)" 2>/dev/null || true
        create_minimal_config "$cfg"
        ok "配置已重建"
    fi
    substep "清理不兼容字段..."
    sanitize_config "$cfg"
    ok "已清理"
    if is_docker_mode && has_cmd python3; then
        substep "转换 Docker URL..."
        python3 - "$cfg" << 'PYEOF'
import json, sys, os, re
cfg_path = sys.argv[1]
try:
    with open(cfg_path) as f: c = json.load(f)
except: sys.exit(0)
pat = re.compile(r'^(https?://)(127\.[0-9.]+|localhost|192\.168\.\d+\.\d+|10\.\d+\.\d+\.\d+)')
changed = False
for n, p in c.get("models", {}).get("providers", {}).items():
    if not isinstance(p, dict): continue
    url = p.get("baseUrl", "")
    if pat.match(url):
        p["baseUrl"] = pat.sub(r'\1host.docker.internal', url)
        changed = True
if changed:
    with open(cfg_path, 'w') as f:
        json.dump(c, f, indent=2, ensure_ascii=False)
PYEOF
        ok "完成"
    fi
    if is_installed; then
        substep "运行 doctor..."
        oc_cmd doctor --fix >> "$SCRIPT_LOG" 2>&1 && ok "完成" || warn "doctor 异常"
    fi
    substep "重启服务..."
    service_restart
}
view_logs() {
    step "查看日志"
    out "  [1] 实时日志    [2] 最近 50 行"
    out "  [3] 脚本日志    [0] 返回"
    echo -ne "选择: "
    local choice=""
    read_input choice "2"
    case "$choice" in
        1)
            info "Ctrl+C 退出"
            trap 'out ""; info "已退出"' INT
            if is_docker_mode; then
                docker logs -f "$DOCKER_CONTAINER" 2>&1
            else
                tail -f "$LOG_DIR/gateway.out" 2>/dev/null ||
                oc_cmd logs --follow 2>/dev/null || err "无日志可用"
            fi
            trap - INT
            ;;
        2)
            if is_docker_mode; then
                docker logs --tail 50 "$DOCKER_CONTAINER" 2>&1
            else
                tail -50 "$LOG_DIR/gateway.out" 2>/dev/null ||
                oc_cmd logs 2>/dev/null | tail -50 || err "无日志"
            fi
            ;;
        3) [[ -f "$SCRIPT_LOG" ]] && tail -50 "$SCRIPT_LOG" || warn "不存在" ;;
    esac
}
show_system_info() {
    step "系统信息"
    line
    out "  系统:     ${OS} (${ARCH})"
    out "  Node.js:  $(node -v 2>/dev/null || echo '未安装')"
    out "  npm:      $(npm -v 2>/dev/null || echo '未安装')"
    out "  Docker:   $(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ',' || echo '未安装')"
    out "  OpenClaw: $(oc_cmd --version 2>/dev/null || echo '未安装')"
    local mode="-"
    if is_docker_mode; then mode="Docker"; elif has_cmd openclaw; then mode="本地"; fi
    out "  模式:     ${mode}"
    out "  配置:     $(get_config_path)"
    if $CN_MODE; then
        out "  网络:     中国 (加速)"
        out "  npm源:    $(npm config get registry 2>/dev/null || echo '-')"
    else
        out "  网络:     国际"
    fi
    line
}
check_update() {
    step "检查更新"
    if ! is_installed; then err "未安装"; return 1; fi
    local current="" latest=""
    current=$(oc_cmd --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) || true
    [[ -z "$current" ]] && current="0.0.0"
    local reg_url="https://registry.npmjs.org/openclaw/latest"
    $CN_MODE && reg_url="${NPM_MIRROR}/openclaw/latest"
    latest=$(curl -s --max-time 5 "$reg_url" 2>/dev/null | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4) || true
    out "当前: ${current}    最新: ${latest:-无法获取}"
    if [[ -n "$latest" && "$latest" != "$current" ]]; then
        if confirm "升级到 ${latest}"; then
            if is_docker_mode; then
                info "更新镜像..."
                docker_pull_ghcr "$DOCKER_IMAGE" "latest" || return 1
                docker rm -f "$DOCKER_CONTAINER" >/dev/null 2>&1
                docker_deploy_new
            else
                info "升级中..."
                npm_install_cmd -g openclaw@latest >> "$SCRIPT_LOG" 2>&1 && ok "完成" || err "失败"
            fi
        fi
    else
        ok "已是最新"
    fi
}
gen_token() {
    openssl rand -hex 24 2>/dev/null || head -c 48 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 48 || echo "$(date +%s%N)$(date +%s%N)"
}
plugin_install() {
    local pkg="$1" display="$2"
    if ! is_installed; then err "OpenClaw 未安装"; return 1; fi
    step "安装 ${display}..."
    if oc_cmd plugins install "$pkg" --force 2>&1 | tee -a "$SCRIPT_LOG"; then
        ok "${display} 安装成功"
        return 0
    else
        err "${display} 安装失败"
        return 1
    fi
}
plugin_enable() {
    local entry_name="$1"
    oc_cmd config set "plugins.entries.${entry_name}.enabled" true >> "$SCRIPT_LOG" 2>&1
}
plugin_setup_weixin() {
    step "微信 (个人) 接入"
    if ! is_installed; then err "OpenClaw 未安装"; return 1; fi
    info "包名: @tencent-weixin/openclaw-weixin"
    out "  安装后需用手机微信扫码绑定"
    out ""
    confirm "开始安装" || return 0
    plugin_install "@tencent-weixin/openclaw-weixin" "微信插件" || return 1
    step "启用插件..."
    plugin_enable "openclaw-weixin"
    ok "已启用"
    step "重启 Gateway..."
    service_restart 2>/dev/null
    sleep 3
    step "扫码登录..."
    info "终端将显示二维码,请用微信扫码"
    oc_cmd channels login --channel openclaw-weixin </dev/tty 2>&1 || warn "登录未完成,稍后可重试"
    out ""
    step "验证状态..."
    oc_cmd channels status 2>&1 | head -10 || true
    out ""
    ok "微信配置完成"
    out "  重新登录: openclaw channels login --channel openclaw-weixin"
    out "  查看状态: openclaw channels status"
}
plugin_setup_feishu() {
    step "飞书接入"
    if ! is_installed; then err "OpenClaw 未安装"; return 1; fi
    info "包名: @m1heng-clawd/feishu"
    out "  需准备: 飞书开放平台的 App ID 和 App Secret"
    out "  创建地址: https://open.feishu.cn/app"
    out ""
    confirm "开始安装" || return 0
    plugin_install "@m1heng-clawd/feishu" "飞书插件" || return 1
    step "配置飞书凭证..."
    echo -ne "飞书 App ID (cli_xxx): "
    local app_id=""
    read_input app_id ""
    [[ -z "$app_id" ]] && { warn "跳过配置,稍后手动设置"; return 0; }
    echo -ne "飞书 App Secret: "
    local app_secret=""
    read_secret app_secret ""
    [[ -z "$app_secret" ]] && { warn "跳过配置"; return 0; }
    oc_cmd config set channels.feishu.appId "$app_id" >> "$SCRIPT_LOG" 2>&1
    oc_cmd config set channels.feishu.appSecret "$app_secret" >> "$SCRIPT_LOG" 2>&1
    oc_cmd config set channels.feishu.enabled true >> "$SCRIPT_LOG" 2>&1
    ok "飞书凭证已配置"
    step "重启 Gateway..."
    service_restart 2>/dev/null
    out ""
    ok "飞书配置完成"
    out "  飞书后台需配置:"
    out "    事件订阅 → 请求地址: http://<服务器IP>:${DEFAULT_PORT}/webhook/feishu"
    out "    权限: im:message:receive, im:message:send 等"
}
plugin_setup_dingtalk() {
    step "钉钉接入"
    if ! is_installed; then err "OpenClaw 未安装"; return 1; fi
    info "包名: @openclaw-china/dingtalk"
    out "  需准备: 钉钉开放平台的 Client ID 和 Client Secret"
    out "  创建地址: https://open-dev.dingtalk.com"
    out ""
    confirm "开始安装" || return 0
    plugin_install "@openclaw-china/dingtalk" "钉钉插件" || return 1
    step "配置钉钉凭证..."
    echo -ne "钉钉 Client ID: "
    local client_id=""
    read_input client_id ""
    [[ -z "$client_id" ]] && { warn "跳过配置"; return 0; }
    echo -ne "钉钉 Client Secret: "
    local client_secret=""
    read_secret client_secret ""
    [[ -z "$client_secret" ]] && { warn "跳过配置"; return 0; }
    oc_cmd config set channels.dingtalk.clientid "$client_id" >> "$SCRIPT_LOG" 2>&1
    oc_cmd config set channels.dingtalk.clientsecret "$client_secret" >> "$SCRIPT_LOG" 2>&1
    oc_cmd config set channels.dingtalk.dmPolicy "open" >> "$SCRIPT_LOG" 2>&1
    oc_cmd config set channels.dingtalk.groupPolicy "open" >> "$SCRIPT_LOG" 2>&1
    ok "钉钉凭证已配置"
    step "重启 Gateway..."
    service_restart 2>/dev/null
    out ""
    ok "钉钉配置完成"
}
plugin_setup_wecom() {
    step "企业微信接入"
    if ! is_installed; then err "OpenClaw 未安装"; return 1; fi
    info "包名: @openclaw-china/wecom"
    out "  需准备: 企业微信的 Corp ID, Corp Secret, Agent ID"
    out ""
    confirm "开始安装" || return 0
    plugin_install "@openclaw-china/wecom" "企业微信插件" || return 1
    step "配置凭证..."
    echo -ne "Corp ID: "
    local corp_id=""
    read_input corp_id ""
    [[ -z "$corp_id" ]] && { warn "跳过配置"; return 0; }
    echo -ne "Corp Secret: "
    local corp_secret=""
    read_secret corp_secret ""
    echo -ne "Agent ID: "
    local agent_id=""
    read_input agent_id ""
    oc_cmd config set channels.wecom.corpId "$corp_id" >> "$SCRIPT_LOG" 2>&1
    [[ -n "$corp_secret" ]] && oc_cmd config set channels.wecom.corpSecret "$corp_secret" >> "$SCRIPT_LOG" 2>&1
    [[ -n "$agent_id" ]] && oc_cmd config set channels.wecom.agentId "$agent_id" >> "$SCRIPT_LOG" 2>&1
    oc_cmd config set channels.wecom.enabled true >> "$SCRIPT_LOG" 2>&1
    ok "企业微信已配置"
    service_restart 2>/dev/null
}
plugin_setup_qq() {
    step "QQ 接入"
    if ! is_installed; then err "OpenClaw 未安装"; return 1; fi
    info "包名: @openclaw-china/qqbot"
    out "  需先部署 NapCat 框架"
    out "  参考: https://github.com/NapNeko/NapCatQQ"
    out ""
    confirm "开始安装" || return 0
    plugin_install "@openclaw-china/qqbot" "QQ插件" || {
        info "尝试备选包..."
        plugin_install "@izhimu/qq" "QQ插件" || return 1
    }
    step "配置 QQ..."
    echo -ne "NapCat WebSocket 地址 (ws://127.0.0.1:3001): "
    local ws_url=""
    read_input ws_url "ws://127.0.0.1:3001"
    oc_cmd config set channels.qq.wsUrl "$ws_url" >> "$SCRIPT_LOG" 2>&1
    oc_cmd config set channels.qq.enabled true >> "$SCRIPT_LOG" 2>&1
    ok "QQ 已配置"
    service_restart 2>/dev/null
}
plugin_setup_discord() {
    step "Discord 接入"
    if ! is_installed; then err "OpenClaw 未安装"; return 1; fi
    info "包名: @openclaw/discord"
    out "  需准备: Discord Bot Token"
    out "  创建: https://discord.com/developers/applications"
    out ""
    confirm "开始安装" || return 0
    plugin_install "@openclaw/discord" "Discord插件" || return 1
    step "配置 Discord..."
    echo -ne "Bot Token: "
    local bot_token=""
    read_secret bot_token ""
    [[ -z "$bot_token" ]] && { warn "跳过配置"; return 0; }
    oc_cmd config set channels.discord.token "$bot_token" >> "$SCRIPT_LOG" 2>&1
    oc_cmd config set channels.discord.enabled true >> "$SCRIPT_LOG" 2>&1
    ok "Discord 已配置"
    service_restart 2>/dev/null
}
plugin_setup_slack() {
    step "Slack 接入"
    if ! is_installed; then err "OpenClaw 未安装"; return 1; fi
    info "包名: @openclaw/slack"
    out "  需准备: Slack Bot Token 和 App Token"
    out ""
    confirm "开始安装" || return 0
    plugin_install "@openclaw/slack" "Slack插件" || return 1
    step "配置 Slack..."
    echo -ne "Bot Token (xoxb-xxx): "
    local bot_token=""
    read_secret bot_token ""
    echo -ne "App Token (xapp-xxx): "
    local app_token=""
    read_secret app_token ""
    [[ -n "$bot_token" ]] && oc_cmd config set channels.slack.botToken "$bot_token" >> "$SCRIPT_LOG" 2>&1
    [[ -n "$app_token" ]] && oc_cmd config set channels.slack.appToken "$app_token" >> "$SCRIPT_LOG" 2>&1
    oc_cmd config set channels.slack.enabled true >> "$SCRIPT_LOG" 2>&1
    ok "Slack 已配置"
    service_restart 2>/dev/null
}
plugin_setup_china_all() {
    step "中国 IM 全家桶"
    if ! is_installed; then err "OpenClaw 未安装"; return 1; fi
    info "包名: @openclaw-china/channels"
    out "  包含: 飞书 + 钉钉 + QQ + 企业微信"
    out ""
    confirm "一键安装" || return 0
    plugin_install "@openclaw-china/channels" "中国IM全家桶" || return 1
    ok "安装完成,请到各平台菜单分别配置凭证"
}
plugin_setup_telegram() {
    step "Telegram 配置"
    if ! is_installed; then err "OpenClaw 未安装"; return 1; fi
    info "Telegram 通常内置,无需安装插件"
    out "  需准备: Telegram Bot Token (从 @BotFather 获取)"
    out ""
    echo -ne "Bot Token: "
    local bot_token=""
    read_secret bot_token ""
    [[ -z "$bot_token" ]] && { warn "跳过"; return 0; }
    local cfg=""
    cfg=$(get_config_path)
    config_set "channels.telegram.botToken" "$bot_token"
    config_set "channels.telegram.dmPolicy" "open"
    config_set "channels.telegram.groupPolicy" "open"
    ok "Telegram 已配置"
    confirm "重启服务" && service_restart
}
setup_external_access() {
    step "外网/手机访问"
    if ! is_installed; then err "OpenClaw 未安装"; return 1; fi
    local ip=""
    ip=$(get_local_ip)
    local token=""
    token=$(config_get "gateway.auth.token" 2>/dev/null) || true
    local bind=""
    bind=$(config_get "gateway.bind" 2>/dev/null) || true
    out "${CB}当前状态${C}"
    line
    out "  bind:  ${bind:-loopback}"
    out "  令牌:  ${token:-未设置}"
    out "  LAN:   http://${ip}:${DEFAULT_PORT}"
    line
    out ""
    out "${CB}Android/iOS 连接方式${C}"
    out ""
    out "  ${CC}方式1: 同一局域网 (推荐)${C}"
    out "    1. 确保 bind=lan 且有令牌"
    out "    2. 手机打开 OpenClaw App → Connect"
    out "    3. Manual 模式填入:"
    out "       Host: ${CG}${ip}${C}"
    out "       Port: ${CG}${DEFAULT_PORT}${C}"
    if [[ -n "$token" ]]; then
        out "       Token: ${CY}${token}${C}"
    fi
    out ""
    out "  ${CC}方式2: Tailscale (跨网络)${C}"
    out "    1. 服务器和手机都安装 Tailscale"
    out "    2. openclaw gateway --tailscale serve"
    out "    3. 手机用 wss:// 地址连接"
    out ""
    out "  ${CC}方式3: SSH 隧道${C}"
    local pub_ip=""
    pub_ip=$(curl -s --max-time 3 https://api.ipify.org 2>/dev/null) || true
    out "    ssh -L ${DEFAULT_PORT}:localhost:${DEFAULT_PORT} user@${pub_ip:-服务器IP}"
    out "    然后手机连 127.0.0.1:${DEFAULT_PORT}"
    out ""
    if [[ "$bind" != "lan" ]]; then
        if confirm "现在启用局域网访问"; then
            enable_lan_access
        fi
    fi
}
menu_plugins() {
    step "插件管理"
    if ! is_installed; then
        err "请先安装 OpenClaw (主菜单 [1])"
        return 1
    fi
    out "${CB}通道插件${C}"
    out "  [1] 微信 (个人)           @tencent-weixin/openclaw-weixin"
    out "  [2] 飞书                  @m1heng-clawd/feishu"
    out "  [3] 钉钉                  @openclaw-china/dingtalk"
    out "  [4] 企业微信              @openclaw-china/wecom"
    out "  [5] QQ                    @openclaw-china/qqbot"
    out "  [6] Telegram              内置"
    out "  [7] Discord               @openclaw/discord"
    out "  [8] Slack                 @openclaw/slack"
    out "  [9] 中国 IM 全家桶        @openclaw-china/channels"
    out ""
    out "${CB}工具${C}"
    out "  [L] 已安装插件    [S] 渠道状态"
    out "  [U] 卸载插件      [E] 外网/手机访问"
    out "  [0] 返回"
    out ""
    echo -ne "选择: "
    local choice=""
    read_input choice "0"
    case "$choice" in
        1) plugin_setup_weixin ;;
        2) plugin_setup_feishu ;;
        3) plugin_setup_dingtalk ;;
        4) plugin_setup_wecom ;;
        5) plugin_setup_qq ;;
        6) plugin_setup_telegram ;;
        7) plugin_setup_discord ;;
        8) plugin_setup_slack ;;
        9) plugin_setup_china_all ;;
        l|L) oc_cmd plugins list 2>&1 || err "无法列出" ;;
        s|S) oc_cmd channels status 2>&1 || err "无法查询" ;;
        u|U)
            echo -ne "包名: "
            local pkg=""
            read_input pkg ""
            [[ -n "$pkg" ]] && confirm "卸载 ${pkg}" && oc_cmd plugins uninstall "$pkg" 2>&1
            ;;
        e|E) setup_external_access ;;
        0) return 0 ;;
        *) warn "无效" ;;
    esac
}
uninstall() {
    step "卸载 OpenClaw"
    warn "将删除 OpenClaw 及相关配置!"
    confirm "确认卸载" || return 0
    service_stop 2>/dev/null || true
    if docker ps -a 2>/dev/null | grep -q "$DOCKER_CONTAINER"; then
        docker rm -f "$DOCKER_CONTAINER" >/dev/null 2>&1
        confirm "删除 Docker 镜像" && {
            docker rmi "${DOCKER_IMAGE}:latest" 2>/dev/null || true
            docker rmi "${DOCKER_IMAGE_MIRROR}:latest" 2>/dev/null || true
        }
        confirm "删除数据目录 (${DOCKER_DATA_DIR})" && rm -rf "$DOCKER_DATA_DIR"
    fi
    has_cmd openclaw && npm uninstall -g openclaw >> "$SCRIPT_LOG" 2>&1 || true
    confirm "删除配置 (${CONFIG_DIR})" && rm -rf "$CONFIG_DIR"
    ok "卸载完成"
}
show_header() {
    clear
    out "${CB}${SCRIPT_NAME}${C} ${CD}v${SCRIPT_VERSION}${C}"
    line
    local status="" mode="" bind="" net=""
    status=$(get_service_status 2>/dev/null) || true
    if is_docker_mode; then mode="Docker"; elif has_cmd openclaw; then mode="本地"; else mode="-"; fi
    bind=$(config_get "gateway.bind" 2>/dev/null) || true
    [[ -z "$bind" ]] && bind="-"
    $CN_MODE && net="CN" || net="INT"
    local sc="$CR"
    [[ "$status" == "运行中" ]] && sc="$CG"
    [[ "$status" == "已停止" ]] && sc="$CY"
    out "状态: ${sc}${status}${C}  |  模式: ${mode}  |  bind: ${bind}  |  端口: ${DEFAULT_PORT}  |  ${net}"
    line
    out ""
}
show_menu() {
    out "${CB}主菜单${C}"
    out ""
    out "  ${CG}[1]${C} 快速部署      ${CD}安装 OpenClaw${C}"
    out "  ${CC}[2]${C} 服务管理      ${CD}启动/停止/重启${C}"
    out "  ${CC}[3]${C} API 配置      ${CD}添加/修改 Provider${C}"
    out "  ${CC}[4]${C} 网络设置      ${CD}局域网/令牌${C}"
    out "  ${CY}[5]${C} 诊断工具      ${CD}检查/修复/日志${C}"
    out "  ${CD}[6]${C} 系统信息      ${CD}版本/升级/卸载${C}"
    out "  ${CC}[7]${C} 插件管理      ${CD}微信/飞书/钉钉/...${C}"
    out "  ${CD}[0]${C} 退出"
    out ""
}
menu_deploy() {
    step "快速部署"
    out "  [1] 本地安装 (npm)"
    out "  [2] Docker 部署"
    out "  [0] 返回"
    echo -ne "选择: "
    local deploy_mode=""
    read_input deploy_mode "0"
    [[ "$deploy_mode" == "0" ]] && return 0
    [[ "$deploy_mode" != "1" && "$deploy_mode" != "2" ]] && { warn "无效"; return 0; }
    menu_deploy_direct "$deploy_mode"
    wait_key
}
menu_deploy_direct() {
    local deploy_mode="$1"
    out ""
    line
    out "${CB}部署选项${C}"
    local opt_lan=true opt_api=false opt_custom_token=false opt_token=""
    confirm_yes "启用局域网访问" && opt_lan=true || opt_lan=false
    if $opt_lan; then
        if confirm "自定义访问令牌"; then
            opt_custom_token=true
            echo -ne "  输入令牌 (≥16字符): "
            read_input opt_token ""
            if [[ ${#opt_token} -lt 16 ]]; then
                warn "太短,将自动生成"
                opt_custom_token=false
                opt_token=""
            fi
        fi
        if ! $opt_custom_token; then
            opt_token=$(openssl rand -hex 24 2>/dev/null || head -c 48 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 48) || true
        fi
    fi
    confirm "部署完成后配置 API" && opt_api=true || opt_api=false
    out ""
    line
    local lan_label="关闭" token_label="-" api_label="跳过"
    $opt_lan && lan_label="${CG}开启${C}"
    $opt_lan && token_label="${CY}${opt_token:0:16}...${C}"
    $opt_api && api_label="部署后配置"
    out "  局域网: ${lan_label}  |  令牌: ${token_label}  |  API: ${api_label}"
    line
    case "$deploy_mode" in
        1) install_local "$opt_lan" "$opt_token" ;;
        2) install_docker "$opt_lan" "$opt_token" ;;
    esac
    local deploy_ok=$?
    if [[ $deploy_ok -eq 0 ]] && $opt_api && is_installed; then
        out ""
        configure_api
    fi
}
menu_service() {
    step "服务管理"
    out "  [1] 启动    [2] 停止"
    out "  [3] 重启    [4] 状态"
    out "  [0] 返回"
    echo -ne "选择: "
    local choice=""
    read_input choice "0"
    case "$choice" in
        1) service_start ;;
        2) confirm "确认停止" && service_stop ;;
        3) service_restart ;;
        4) service_status ;;
    esac
    wait_key
}
menu_diagnose() {
    step "诊断工具"
    out "  [1] 系统诊断    [2] 查看日志"
    out "  [3] 修复配置    [4] 运行 doctor"
    out "  [5] 清理字段    [0] 返回"
    echo -ne "选择: "
    local choice=""
    read_input choice "0"
    case "$choice" in
        1) diagnose ;;
        2) view_logs ;;
        3) ensure_config && ok "配置有效" ;;
        4) is_installed && oc_cmd doctor --fix || err "未安装" ;;
        5) sanitize_config && ok "已清理" || err "失败" ;;
    esac
    wait_key
}
menu_system() {
    step "系统信息"
    out "  [1] 查看信息    [2] 检查更新"
    out "  [3] 卸载        [0] 返回"
    echo -ne "选择: "
    local choice=""
    read_input choice "0"
    case "$choice" in
        1) show_system_info ;;
        2) check_update ;;
        3) uninstall ;;
    esac
    wait_key
}
main_menu() {
    while true; do
        show_header
        show_menu
        echo -ne "选择: "
        local choice=""
        read_input choice ""
        case "$choice" in
            1) menu_deploy ;;
            2) menu_service ;;
            3) configure_api; wait_key ;;
            4) configure_network; wait_key ;;
            7) menu_plugins; wait_key ;;
            5) menu_diagnose ;;
            6) menu_system ;;
            0|q|Q) out ""; out "再见!"; exit 0 ;;
            *) warn "无效"; sleep 1 ;;
        esac
    done
}
show_help() {
    out "${CB}${SCRIPT_NAME}${C} v${SCRIPT_VERSION}"
    out ""
    out "用法: $0 [命令]"
    out ""
    out "  install     本地安装"
    out "  docker      Docker 部署"
    out "  start       启动服务"
    out "  stop        停止服务"
    out "  restart     重启服务"
    out "  status      查看状态"
    out "  config      配置 API"
    out "  lan         启用局域网"
    out "  plugins     插件管理"
    out "  diagnose    诊断修复"
    out "  logs        查看日志"
    out "  update      检查更新"
    out "  uninstall   卸载"
    out "  help        帮助"
}
main() {
    detect_system
    mkdir -p "$CONFIG_DIR" "$LOG_DIR" 2>/dev/null || true
    detect_china_network
    ensure_dependencies || exit 1
    case "${1:-}" in
        install) menu_deploy_direct "1" ;;
        docker) menu_deploy_direct "2" ;;
        start) service_start ;;
        stop) service_stop ;;
        restart) service_restart ;;
        status) service_status ;;
        config) configure_api ;;
        lan) enable_lan_access ;;
        plugins) menu_plugins ;;
        diagnose) diagnose ;;
        logs) view_logs ;;
        update) check_update ;;
        uninstall) uninstall ;;
        help|-h|--help) show_help ;;
        "") main_menu ;;
        *) err "未知: $1"; show_help; exit 1 ;;
    esac
}
main "$@"
