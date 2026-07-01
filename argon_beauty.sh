#!/bin/sh

# shellcheck shell=sh

ESC=$(printf '\033')
RED="${ESC}[0;31m"
GREEN="${ESC}[0;32m"
YELLOW="${ESC}[1;33m"
BLUE="${ESC}[0;34m"
CYAN="${ESC}[0;36m"
WHITE="${ESC}[1;37m"
NC="${ESC}[0m"

info()    { printf "${CYAN}  [i]  %s${NC}\n" "$1"; }
success() { printf "${GREEN}  [v]  %s${NC}\n" "$1"; }
warn()    { printf "${YELLOW}  [!]  %s${NC}\n" "$1"; }
error()   { printf "${RED}  [x]  %s${NC}\n" "$1"; }

title() {
    local line="=================================================="
    printf "\n${WHITE}%s\n  %s\n%s${NC}\n" "$line" "$1" "$line"
}

ask() {
    printf "${YELLOW}  [?]  %s [y/N]: ${NC}" "$1" >&2
    read _ask_val
    case "$_ask_val" in
        [Yy]|[Yy][Ee][Ss]) return 0 ;;
        *) return 1 ;;
    esac
}

ask_num() {
    local prompt="$1" def="$2" min="$3" max="$4"
    printf "${YELLOW}  [>]  %s [%s-%s, 默认%s]: ${NC}" \
        "$prompt" "$min" "$max" "$def" >&2
    read _n_val
    [ -z "$_n_val" ] && _n_val="$def"
    case "$_n_val" in *[!0-9]*|'') _n_val="$def" ;; esac
    if [ "$_n_val" -lt "$min" ] 2>/dev/null || \
       [ "$_n_val" -gt "$max" ] 2>/dev/null; then
        printf "${YELLOW}  [!]  超出范围，使用默认值: %s${NC}\n" "$def" >&2
        _n_val="$def"
    fi
    printf '%s\n' "$_n_val"
}

ask_float() {
    local prompt="$1" def="$2"
    printf "${YELLOW}  [>]  %s [默认 %s]: ${NC}" "$prompt" "$def" >&2
    read _f_val
    [ -z "$_f_val" ] && _f_val="$def"
    case "$_f_val" in
        0.[0-9]*|0.[0-9][0-9]*|1.0|1)
            printf '%s\n' "$_f_val" ;;
        *)
            printf "${YELLOW}  [!]  格式不合法，使用默认: %s${NC}\n" "$def" >&2
            printf '%s\n' "$def" ;;
    esac
}

ask_str() {
    local prompt="$1" def="$2"
    printf "${YELLOW}  [>]  %s [默认: %s]: ${NC}" "$prompt" "$def" >&2
    read _s_val
    [ -z "$_s_val" ] && _s_val="$def"
    printf '%s\n' "$_s_val"
}

_count_lines() {
    local cnt=0
    while IFS= read -r line; do
        # 跳过空行和注释行（Bug B1 修复）
        [ -z "$line" ] && continue
        case "$line" in \#*) continue ;; esac
        cnt=$((cnt+1))
    done < "$1"
    printf '%s\n' "$cnt"
}

# ================================================================
#  数据常量
# ================================================================

IMG_API_LIST="yppp自适应|https://api.yppp.net/api.php|横竖自适应二次元(推荐)
yppp横屏PC|https://api.yppp.net/pc.php|横屏壁纸
yppp竖屏手机|https://api.yppp.net/pe.php|竖屏壁纸
樱花ACG|https://www.dmoe.cc/random.php|随机二次元
随机图片|https://api.elaina.cat/random|二次元动漫
二次元|https://api.yppp.net/api.php|高清壁纸
游戏|https://wp.upx8.com/api.php?category=game|随机游戏壁纸
UAPIs|https://uapis.cn/api/v1/random/image|免费随机动漫(国内CDN)
南风自适应|https://api.sretna.cn/api/anime/auto|自动横竖适配
必应每日|https://bing.img.run/1920x1080.php|必应每日壁纸
自定义|custom|输入自己的图片API地址"

FONT_LIST="TypoGraphica(本地已有)|TypoGraphica|local|local
阿里妈妈数黑体|AlimamaShuHeiTi|https://at.alicdn.com/wf/webfont/kfq1sgJFWQ6g/cPCrTL8ewntCCMPMNgo40.woff2|https://at.alicdn.com/wf/webfont/kfq1sgJFWQ6g/fu9Q_dW8qzsGtfSSU60a3.woff
阿里妈妈东方大楷|AlimamaDFDaKai|https://at.alicdn.com/wf/webfont/kfq1sgJFWQ6g/Vilu-bh7P5eQjO8r8act3.woff2|https://at.alicdn.com/wf/webfont/kfq1sgJFWQ6g/IXc_dDK4CjiHaiUgrlZL5.woff
系统默认字体|system-ui|none|none"

GRADIENT_LIST="青蓝极光(默认)|#00e5ff,#2979ff,#aa00ff,#00e5ff
金橙日落|#ff6b35,#f7931e,#ffcd3c,#ff6b35
紫霞幻境|#a855f7,#6366f1,#ec4899,#a855f7
翠绿春意|#00b894,#00cec9,#55efc4,#00b894
玫红炫彩|#fd79a8,#e84393,#ff7675,#fd79a8
赛博朋克|#00fff7,#ff00ff,#ffff00,#00fff7
星空深蓝|#0f3460,#16213e,#0f3460,#533483
珊瑚暖阳|#f093fb,#f5576c,#fda085,#f093fb
自定义|custom"

# ================================================================
#  全局变量
# ================================================================
ACTIVE_THEME=""
ACTIVE_CSS=""
ACTIVE_FONTS_DIR=""
ACTIVE_IMG_DIR=""
ACTIVE_BG=""
THEME_BG_WEBPATH=""
SEL_SIDEBAR=""
SEL_HEADER=""
SEL_CARD=""
SEL_CONTENT=""
SEL_LOGIN=""
SEL_BRAND=""
SEL_BRAND_LOGIN=""
NET_TOOL=""
ROUTER_IP="192.168.1.1"
HEADER_HTM=""
SYSAUTH=""
FOOTER=""
FONT_NAME=""
FONT_WOFF2_URL=""
FONT_WOFF_URL=""
GRAD_COLORS="#00e5ff,#2979ff,#aa00ff,#00e5ff"
GRAD_NAME="青蓝极光"
GLASS_BLUR="12"
GLASS_BORDER="rgba(255,255,255,0.15)"
GLASS_DARKEN="0.35"
THEME_BASE_COLOR="dark"

# ================================================================
#  主题变量加载
# ================================================================
_load_theme_vars() {
    local t="$1"
    case "$t" in
        argon)
            ACTIVE_CSS="/www/luci-static/argon/css/cascade.css"
            ACTIVE_FONTS_DIR="/www/luci-static/argon/fonts"
            ACTIVE_IMG_DIR="/www/luci-static/argon/img"
            ACTIVE_BG="/www/luci-static/argon/img/bg1.jpg"
            THEME_BG_WEBPATH="/luci-static/argon/img/bg1.jpg"
            SEL_SIDEBAR=".main-left, #menu"
            SEL_HEADER="header, .sidenav-header, .bg-primary, .navbar"
            SEL_CARD=".cbi-section, .cbi-section-node, .cbi-map, fieldset, .panel, .card, .box"
            SEL_CONTENT=".main-right, #maincontent, .main"
            SEL_LOGIN=".login-page .login-container .login-form"
            SEL_BRAND=".main-left .sidenav-header .brand"
            SEL_BRAND_LOGIN=".login-page .login-container .login-form .brand .brand-text"
            ;;
        material)
            ACTIVE_CSS="/www/luci-static/material/css/cascade.css"
            ACTIVE_FONTS_DIR="/www/luci-static/material/fonts"
            ACTIVE_IMG_DIR="/www/luci-static/material/img"
            ACTIVE_BG="/www/luci-static/material/img/bg.jpg"
            THEME_BG_WEBPATH="/luci-static/material/img/bg.jpg"
            SEL_SIDEBAR="#mainmenu, .navigation"
            SEL_HEADER="#header, .header"
            SEL_CARD=".cbi-section, .card, .panel, fieldset"
            SEL_CONTENT="#maincontent, .main-content, #content"
            SEL_LOGIN=".login, #login, .login-form"
            SEL_BRAND="#header .brand, .brand-name"
            SEL_BRAND_LOGIN=".login .brand, .login-title"
            ;;
        bootstrap)
            ACTIVE_CSS="/www/luci-static/bootstrap/css/cascade.css"
            ACTIVE_FONTS_DIR="/www/luci-static/bootstrap/fonts"
            ACTIVE_IMG_DIR="/www/luci-static/bootstrap/img"
            ACTIVE_BG="/www/luci-static/bootstrap/img/bg.jpg"
            THEME_BG_WEBPATH="/luci-static/bootstrap/img/bg.jpg"
            SEL_SIDEBAR=".navbar-default, .sidebar, #sidebar"
            SEL_HEADER=".navbar, .navbar-header, .page-header"
            SEL_CARD=".cbi-section, .panel, .card, .well, fieldset"
            SEL_CONTENT="#maincontent, .container-fluid, .main"
            SEL_LOGIN=".container .row, .login-wrapper"
            SEL_BRAND=".navbar-brand, .brand"
            SEL_BRAND_LOGIN=".login h1, .login-title"
            ;;
        openwrt2020)
            ACTIVE_CSS="/www/luci-static/openwrt2020/css/cascade.css"
            ACTIVE_FONTS_DIR="/www/luci-static/openwrt2020/fonts"
            ACTIVE_IMG_DIR="/www/luci-static/openwrt2020/img"
            ACTIVE_BG="/www/luci-static/openwrt2020/img/bg.jpg"
            THEME_BG_WEBPATH="/luci-static/openwrt2020/img/bg.jpg"
            SEL_SIDEBAR="#menu, aside, .sidenav"
            SEL_HEADER="#header, header, .topbar"
            SEL_CARD=".cbi-section, .panel, fieldset, .box"
            SEL_CONTENT="#maincontent, main, .content"
            SEL_LOGIN=".login-container, .login"
            SEL_BRAND=".brand, .logo-text"
            SEL_BRAND_LOGIN=".login .brand, h1.brand"
            ;;
        edge)
            ACTIVE_CSS="/www/luci-static/edge/css/cascade.css"
            ACTIVE_FONTS_DIR="/www/luci-static/edge/fonts"
            ACTIVE_IMG_DIR="/www/luci-static/edge/img"
            ACTIVE_BG="/www/luci-static/edge/img/bg.jpg"
            THEME_BG_WEBPATH="/luci-static/edge/img/bg.jpg"
            SEL_SIDEBAR=".main-sidebar, .sidebar, #sidebar"
            SEL_HEADER=".main-header, header, .top-bar"
            SEL_CARD=".cbi-section, .box, .panel, fieldset"
            SEL_CONTENT=".content-wrapper, #content, main"
            SEL_LOGIN=".login-page .login-box"
            SEL_BRAND=".logo, .brand-link"
            SEL_BRAND_LOGIN=".login-logo, .login-page .brand"
            ;;
        *)
            ACTIVE_CSS="/www/luci-static/${t}/css/cascade.css"
            ACTIVE_FONTS_DIR="/www/luci-static/${t}/fonts"
            ACTIVE_IMG_DIR="/www/luci-static/${t}/img"
            ACTIVE_BG="/www/luci-static/${t}/img/bg.jpg"
            THEME_BG_WEBPATH="/luci-static/${t}/img/bg.jpg"
            SEL_SIDEBAR="aside, nav, #menu, .sidebar, .sidenav"
            SEL_HEADER="header, .navbar, #header, .topbar"
            SEL_CARD=".cbi-section, .panel, .card, fieldset, .box"
            SEL_CONTENT="#maincontent, main, .main, .content"
            SEL_LOGIN=".login, .login-container, #login"
            SEL_BRAND=".brand, .logo-text, .navbar-brand"
            SEL_BRAND_LOGIN=".login .brand, .login h1, .login-title"
            ;;
    esac
    mkdir -p "$ACTIVE_FONTS_DIR" "$ACTIVE_IMG_DIR" 2>/dev/null
    if [ ! -f "$ACTIVE_CSS" ]; then
        error "主题 CSS 不存在: $ACTIVE_CSS"; exit 1
    fi
    success "CSS    : $ACTIVE_CSS"
    success "背景图 : $ACTIVE_BG"
}

# ================================================================
#  智能检测主题底色（新增）
# ================================================================
_detect_theme_base_color() {
    local css="$ACTIVE_CSS"
    local detected="unknown"
    # 从现有 CSS 中提取 body/html 的 background-color
    if grep -qi 'background' "$css" 2>/dev/null; then
        local bg_val
        bg_val=$(grep -i 'body\|html' "$css" 2>/dev/null | \
            grep -i 'background' | head -1 | \
            sed 's/.*background[^:]*://;s/!important//;s/;//' | tr -d ' \t')
        case "$bg_val" in
            *"#fff"*|*"#ffffff"*|*"white"*|\
            *"rgb(255,255,255)"*|*"rgba(255,255,255,1"*)
                detected="light" ;;
            *"#0"*|*"#1"*|*"#2"*|*"rgba(0,"*|*"rgba(10,"*|\
            *"rgba(15,"*|*"rgba(20,"*|*"rgb(0,"*)
                detected="dark" ;;
        esac
    fi
    if [ "$detected" = "unknown" ]; then
        case "$ACTIVE_THEME" in
            argon|edge)        detected="dark" ;;
            material|bootstrap) detected="light" ;;
            openwrt2020)       detected="light" ;;
            *)                  detected="dark" ;;
        esac
        warn "底色推断（基于主题名）: $detected"
    else
        info "从 CSS 检测到底色风格: $detected"
    fi
    THEME_BASE_COLOR="$detected"
}

# ================================================================
#  主题探测
# ================================================================
detect_themes() {
    title "自动探测已安装 LuCI 主题"
    local tmplist="/tmp/_themes_$$"
    : > "$tmplist"
    local count=0
    for d in /www/luci-static/*/; do
        [ -d "$d" ] || continue
        local t; t=$(basename "$d")
        if [ -f "${d}css/cascade.css" ]; then
            count=$((count+1))
            printf '%s\n' "$t" >> "$tmplist"
            success "发现主题 [${count}]: $t"
        fi
    done
    if [ "$count" -eq 0 ]; then
        rm -f "$tmplist"; error "未发现任何 LuCI 主题"; exit 1
    fi
    if [ "$count" -eq 1 ]; then
        ACTIVE_THEME=$(head -1 "$tmplist")
        info "自动选择唯一主题: $ACTIVE_THEME"
    else
        echo ""
        info "检测到 $count 个主题，请选择："
        local i=1
        while IFS= read -r t; do
            [ -n "$t" ] && printf "  ${CYAN}%2d)${NC} %s\n" "$i" "$t"
            i=$((i+1))
        done < "$tmplist"
        printf "${YELLOW}  [>]  选择主题编号 [1-%s, 默认1]: ${NC}" "$count"
        read _sel
        [ -z "$_sel" ] && _sel=1
        case "$_sel" in *[!0-9]*) _sel=1 ;; esac
        [ "$_sel" -lt 1 ] 2>/dev/null && _sel=1
        [ "$_sel" -gt "$count" ] 2>/dev/null && _sel=1
        ACTIVE_THEME=$(awk -v n="$_sel" 'NR==n{print;exit}' "$tmplist")
    fi
    rm -f "$tmplist"
    [ -z "$ACTIVE_THEME" ] && { error "主题名为空"; exit 1; }
    success "目标主题: $ACTIVE_THEME"
    _load_theme_vars "$ACTIVE_THEME"
    _detect_theme_base_color
}

# ================================================================
#  路径探测
# ================================================================
detect_paths() {
    title "自动探测系统环境"
    # 用 -F 固定字符串匹配，避免主题名被当正则（Bug B3 修复）
    HEADER_HTM=$(find /usr/lib/lua /usr/share/ucode \
        -name "header.htm" 2>/dev/null | grep -F "$ACTIVE_THEME" | head -1)
    SYSAUTH=$(find /usr/lib/lua /usr/share/ucode \
        -name "sysauth*" 2>/dev/null | grep -F "$ACTIVE_THEME" | head -1)
    FOOTER=$(find /usr/lib/lua /usr/share/ucode \
        -name "footer*" 2>/dev/null | grep -F "$ACTIVE_THEME" | head -1)
    [ -n "$HEADER_HTM" ] && success "Header : $HEADER_HTM" || warn "header.htm 未找到"
    [ -n "$SYSAUTH"    ] && success "Sysauth: $SYSAUTH"    || warn "sysauth 未找到"
    [ -n "$FOOTER"     ] && success "Footer : $FOOTER"      || warn "footer 未找到"
    NET_TOOL=""
    if command -v curl >/dev/null 2>&1; then
        NET_TOOL="curl"; success "网络工具: curl"
    elif command -v wget >/dev/null 2>&1; then
        NET_TOOL="wget"; success "网络工具: wget"
    else
        warn "未找到 curl/wget，无法在线下载"
    fi
    ROUTER_IP=$(uci get network.lan.ipaddr 2>/dev/null || echo "192.168.1.1")
    info "路由器IP: $ROUTER_IP"
    info "主题底色: $THEME_BASE_COLOR"
}

# ================================================================
#  网络工具
# ================================================================
check_url() {
    local url="$1" timeout="${2:-8}"
    [ -z "$NET_TOOL" ] && return 1
    if [ "$NET_TOOL" = "curl" ]; then
        local code
        code=$(curl -sSL --connect-timeout "$timeout" --max-time "$timeout" \
             -A "Mozilla/5.0" -o /dev/null -w "%{http_code}" -L "$url" 2>/dev/null)
        case "$code" in 2*|3*) return 0 ;; *) return 1 ;; esac
    else
        wget -q --timeout="$timeout" -U "Mozilla/5.0" --spider "$url" 2>/dev/null
    fi
}

net_download() {
    local url="$1" dest="$2" desc="${3:-文件}"
    info "正在下载 $desc ..."; info "来源: $url"
    if [ "$NET_TOOL" = "curl" ]; then
        curl -sSL --connect-timeout 15 --max-time 60 \
             -A "Mozilla/5.0" -L "$url" -o "$dest" 2>/dev/null
    elif [ "$NET_TOOL" = "wget" ]; then
        wget -q --timeout=60 -U "Mozilla/5.0" "$url" -O "$dest" 2>/dev/null
    else
        error "无网络工具"; return 1
    fi
    if [ -f "$dest" ] && [ -s "$dest" ]; then
        local size; size=$(du -sh "$dest" 2>/dev/null | cut -f1)
        success "$desc 下载成功（$size）"; chmod 644 "$dest"; return 0
    else
        error "$desc 下载失败"; rm -f "$dest" 2>/dev/null; return 1
    fi
}

verify_image() {
    local file="$1"
    [ ! -f "$file" ] && return 1
    local magic=""
    if command -v hexdump >/dev/null 2>&1; then
        magic=$(hexdump -n 12 -e '"%02x"' "$file" 2>/dev/null)
    elif command -v od >/dev/null 2>&1; then
        magic=$(dd if="$file" bs=1 count=12 2>/dev/null | \
                od -A n -t x1 2>/dev/null | tr -d ' \n')
    fi
    if [ -n "$magic" ]; then
        case "$magic" in
            ffd8ff*)                   return 0 ;;
            89504e47*)                 return 0 ;;
            52494646????????57454250*) return 0 ;;
            474946*)                   return 0 ;;
            424d*)                     return 0 ;;
        esac
    fi
    local size; size=$(wc -c < "$file" 2>/dev/null || echo 0)
    [ "$size" -gt 10240 ] && return 0
    return 1
}

# ================================================================
#  URL 检测
# ================================================================
step_check_urls() {
    title "联网检查所有内置 URL 可用性"
    [ -z "$NET_TOOL" ] && warn "无网络工具，跳过" && return
    printf "\n  ${WHITE}%-24s %-10s %s${NC}\n" "图片 API" "状态" "说明"
    printf "  %s\n" "----------------------------------------------------"
    local tmpf="/tmp/_chk_api_$$"
    printf '%s\n' "$IMG_API_LIST" > "$tmpf"
    while IFS='|' read -r name url desc; do
        [ -z "$name" ] && continue
        case "$name" in \#*) continue ;; esac
        [ "$url" = "custom" ] && continue
        printf "  %-24s " "$name"
        if check_url "$url" 8; then printf "${GREEN}[  OK  ]${NC}  %s\n" "$desc"
        else printf "${RED}[ FAIL ]${NC}  %s\n" "$desc"; fi
    done < "$tmpf"; rm -f "$tmpf"
    printf "\n  ${WHITE}%-28s %s${NC}\n" "字体 CDN" "状态"
    printf "  %s\n" "------------------------------------------"
    local tmpf2="/tmp/_chk_fnt_$$"
    printf '%s\n' "$FONT_LIST" > "$tmpf2"
    while IFS='|' read -r name cssname w2 w1; do
        [ -z "$name" ] && continue
        case "$name" in \#*) continue ;; esac
        [ "$w2" = "local" ] || [ "$w2" = "none" ] && continue
        printf "  %-28s " "$name"
        if check_url "$w2" 10; then printf "${GREEN}[  OK  ]${NC}\n"
        else printf "${RED}[ FAIL ]${NC}\n"; fi
    done < "$tmpf2"; rm -f "$tmpf2"
    echo ""; success "检测完成"
}

show_api_list() {
    local do_check="${1:-0}"
    printf "  ${WHITE}图片 API 列表：${NC}\n"
    local i=1
    local tmpf="/tmp/_api_show_$$"
    printf '%s\n' "$IMG_API_LIST" > "$tmpf"
    while IFS='|' read -r name url desc; do
        [ -z "$name" ] && continue
        case "$name" in \#*) continue ;; esac   # Bug B1 修复
        if [ "$url" = "custom" ]; then
            printf "  ${CYAN}%2d)${NC} %-24s ${YELLOW}[自定义]${NC}  %s\n" "$i" "$name" "$desc"
        elif [ "$do_check" = "1" ] && [ -n "$NET_TOOL" ]; then
            printf "  ${CYAN}%2d)${NC} %-24s " "$i" "$name"
            if check_url "$url" 3; then printf "${GREEN}[OK]${NC}  %s\n" "$desc"
            else printf "${RED}[--]${NC}  %s\n" "$desc"; fi
        else
            printf "  ${CYAN}%2d)${NC} %-24s  %s\n" "$i" "$name" "$desc"
        fi
        i=$((i+1))
    done < "$tmpf"; rm -f "$tmpf"
}

# ================================================================
#  CSS 块管理
# ================================================================
_remove_css_block() {
    local tag="$1" css="$ACTIVE_CSS" tmpout="/tmp/_css_rm_$$"
    grep -q "=== ${tag}" "$css" 2>/dev/null || return 0
    local in_block=0
    while IFS= read -r line; do
        case "$line" in
            *"=== ${tag} "*|*"=== ${tag}="*) in_block=1 ;;
            *"=== END ${tag} ==="*)           in_block=0 ;;
            *) [ "$in_block" -eq 0 ] && printf '%s\n' "$line" ;;
        esac
    done < "$css" > "$tmpout"
    if [ -s "$tmpout" ]; then
        mv "$tmpout" "$css"; info "已移除旧 [${tag}] 块"
    else
        rm -f "$tmpout"; warn "移除 [${tag}] 块失败，已跳过"
    fi
}

# ================================================================
#  步骤1：背景图片
# ================================================================
step_download_image() {
    title "步骤1：背景图片获取 [$ACTIVE_THEME]"
    echo "  ${CYAN}1)${NC} [网] 从内置API在线下载（直接列出）"
    echo "  ${CYAN}2)${NC} [查] 从内置API下载（先检测可用性，约30s）"
    echo "  ${CYAN}3)${NC} [本] 已手动上传，直接使用"
    echo "  ${CYAN}4)${NC} [链] 输入自定义图片直链"
    echo "  ${CYAN}5)${NC} [跳] 跳过"
    local img_choice; img_choice=$(ask_num "请选择" 1 1 5)
    case "$img_choice" in
        1|2)
            echo ""
            [ "$img_choice" = "2" ] && [ -n "$NET_TOOL" ] && \
                { info "正在检测 API 可用性..."; show_api_list 1; } || show_api_list 0
            echo ""
            local tmpf="/tmp/_api_cnt_$$"
            printf '%s\n' "$IMG_API_LIST" > "$tmpf"
            local api_total; api_total=$(_count_lines "$tmpf"); rm -f "$tmpf"
            local api_num; api_num=$(ask_num "选择API编号" 1 1 "$api_total")
            local tmpf2="/tmp/_api_sel_$$"
            printf '%s\n' "$IMG_API_LIST" > "$tmpf2"
            # 跳过注释行取第 n 条有效行（Bug B1 修复）
            local sel_line sel_cnt=0
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                case "$line" in \#*) continue ;; esac
                sel_cnt=$((sel_cnt+1))
                [ "$sel_cnt" -eq "$api_num" ] && sel_line="$line" && break
            done < "$tmpf2"
            rm -f "$tmpf2"
            local sel_name sel_url
            sel_name=$(printf '%s' "$sel_line" | cut -d'|' -f1)
            sel_url=$(printf '%s' "$sel_line"  | cut -d'|' -f2)
            [ "$sel_url" = "custom" ] && sel_url=$(ask_str "请输入自定义API地址" "")
            [ -z "$NET_TOOL" ] && { warn "无网络工具，无法下载"; return; }
            info "使用: $sel_name -> $sel_url"
            local real_url="$sel_url"
            if [ "$NET_TOOL" = "curl" ]; then
                info "解析最终图片地址..."
                local resolved
                resolved=$(curl -sSL --connect-timeout 10 --max-time 20 \
                    -A "Mozilla/5.0" -w "%{url_effective}" \
                    -o /dev/null -L "$sel_url" 2>/dev/null)
                case "$resolved" in
                    *.jpg|*.jpeg|*.png|*.webp|*.gif|\
                    *.jpg\?*|*.jpeg\?*|*.png\?*|*.webp\?*|*.gif\?*)
                        real_url="$resolved"; info "真实地址: $real_url" ;;
                esac
            fi
            net_download "$real_url" "$ACTIVE_BG" "背景图"
            verify_image "$ACTIVE_BG" && success "图片格式验证通过" || \
                warn "格式验证未通过，仍会尝试使用"
            ;;
        3)
            if [ -f "$ACTIVE_BG" ]; then
                success "已有背景图 ($(du -sh "$ACTIVE_BG" | cut -f1))"
                verify_image "$ACTIVE_BG" && success "格式验证通过" || warn "格式异常"
            else
                warn "未找到 $ACTIVE_BG"
                info "上传: scp bg1.jpg root@${ROUTER_IP}:${ACTIVE_BG}"
            fi
            ;;
        4)
            local direct_url; direct_url=$(ask_str "图片直链URL" "")
            [ -n "$direct_url" ] && {
                net_download "$direct_url" "$ACTIVE_BG" "自定义背景图"
                verify_image "$ACTIVE_BG" && success "格式验证通过"
            } ;;
        5) info "已跳过图片设置" ;;
    esac
}

# ================================================================
#  步骤2：字体
# ================================================================
step_download_font() {
    title "步骤2：品牌字体获取 [$ACTIVE_THEME]"
    local typo_woff2="${ACTIVE_FONTS_DIR}/TypoGraphica.woff2"
    if [ -f "$typo_woff2" ]; then
        success "检测到本地 TypoGraphica.woff2"
        if ask "已有本地字体，是否更换"; then :
        else
            FONT_NAME="TypoGraphica"
            FONT_WOFF2_URL="/luci-static/${ACTIVE_THEME}/fonts/TypoGraphica.woff2"
            FONT_WOFF_URL="/luci-static/${ACTIVE_THEME}/fonts/TypoGraphica.woff"
            inject_font_css; return
        fi
    fi
    echo ""; echo "  字体选择："
    local tmpf="/tmp/_fnt_show_$$"
    printf '%s\n' "$FONT_LIST" > "$tmpf"
    local ftotal; ftotal=$(_count_lines "$tmpf")
    local i=1
    while IFS='|' read -r name cssname w2 w1; do
        [ -z "$name" ] && continue
        printf "  ${CYAN}%2d)${NC} %-30s" "$i" "$name"
        if [ "$w2" = "local" ]; then printf "${GREEN}[本地]${NC}\n"
        elif [ "$w2" = "none" ]; then printf "${WHITE}[系统]${NC}\n"
        elif [ -n "$NET_TOOL" ]; then
            check_url "$w2" 5 && printf "${GREEN}[CDN OK]${NC}\n" || \
                printf "${RED}[CDN FAIL]${NC}\n"
        else printf "${YELLOW}[未检测]${NC}\n"; fi
        i=$((i+1))
    done < "$tmpf"; rm -f "$tmpf"
    local font_num; font_num=$(ask_num "选择字体编号" 1 1 "$ftotal")
    local tmpf2="/tmp/_fnt_sel_$$"
    printf '%s\n' "$FONT_LIST" > "$tmpf2"
    local sel_line; sel_line=$(awk -v n="$font_num" 'NR==n{print;exit}' "$tmpf2")
    rm -f "$tmpf2"
    FONT_DISP=$(printf '%s' "$sel_line"      | cut -d'|' -f1)
    FONT_NAME=$(printf '%s' "$sel_line"      | cut -d'|' -f2)
    FONT_WOFF2_URL=$(printf '%s' "$sel_line" | cut -d'|' -f3)
    FONT_WOFF_URL=$(printf '%s' "$sel_line"  | cut -d'|' -f4)
    info "已选: $FONT_DISP ($FONT_NAME)"
    if [ "$FONT_WOFF2_URL" != "local" ] && [ "$FONT_WOFF2_URL" != "none" ]; then
        if ask "下载字体到本地（推荐，更快）"; then
            if check_url "$FONT_WOFF2_URL" 8; then
                net_download "$FONT_WOFF2_URL" \
                    "${ACTIVE_FONTS_DIR}/${FONT_NAME}.woff2" "${FONT_NAME} woff2"
                net_download "$FONT_WOFF_URL" \
                    "${ACTIVE_FONTS_DIR}/${FONT_NAME}.woff"  "${FONT_NAME} woff"
                FONT_WOFF2_URL="/luci-static/${ACTIVE_THEME}/fonts/${FONT_NAME}.woff2"
                FONT_WOFF_URL="/luci-static/${ACTIVE_THEME}/fonts/${FONT_NAME}.woff"
            else warn "CDN 不可达，将使用在线 CDN 链接"; fi
        else info "将直接引用 CDN 地址"; fi
    elif [ "$FONT_WOFF2_URL" = "local" ]; then
        FONT_WOFF2_URL="/luci-static/${ACTIVE_THEME}/fonts/TypoGraphica.woff2"
        FONT_WOFF_URL="/luci-static/${ACTIVE_THEME}/fonts/TypoGraphica.woff"
    fi
    inject_font_css
}

inject_font_css() {
    # Bug B4 修复：用 if 代替 && 避免运算符优先级问题
    if [ "$FONT_WOFF2_URL" = "none" ] || [ -z "$FONT_WOFF2_URL" ]; then
        info "系统字体，跳过 @font-face"; return
    fi
    grep -q "FONT_FACE_${FONT_NAME}" "$ACTIVE_CSS" 2>/dev/null && \
        { info "字体声明已存在，跳过"; return; }
    local css="$ACTIVE_CSS"
    printf '\n/* === FONT_FACE_%s === */\n' "$FONT_NAME" >> "$css"
    printf '@font-face {\n' >> "$css"
    printf '  font-family: "%s";\n' "$FONT_NAME" >> "$css"
    printf "  src: url('%s') format('woff2'),\n" "$FONT_WOFF2_URL" >> "$css"
    printf "       url('%s')  format('woff');\n" "$FONT_WOFF_URL" >> "$css"
    printf '  font-weight: normal; font-style: normal; font-display: swap;\n}\n' >> "$css"
    printf '/* === END FONT_FACE_%s === */\n' "$FONT_NAME" >> "$css"
    success "@font-face 已注入: $FONT_NAME"
}

# ================================================================
#  步骤3：Brand 动画  v2.0（8种模式）
# ================================================================
step_brand_animation() {
    title "步骤3：Brand 名称动画效果 v2.0 [$ACTIVE_THEME]"
    ask "是否启用品牌名动画效果" || return
    echo ""
    echo "  ${WHITE}动画模式（8种）：${NC}"
    echo "  ${CYAN}1)${NC} 色相持续旋转   颜色本身循环变化 ${GREEN}[推荐]${NC}"
    echo "  ${CYAN}2)${NC} 极光流动       多色渐变横向流过"
    echo "  ${CYAN}3)${NC} 彩虹脉冲发光   颜色变化+外发光"
    echo "  ${CYAN}4)${NC} 霓虹闪烁       明暗交替赛博朋克"
    echo "  ${CYAN}5)${NC} 左右平移       渐变色块平移"
    echo "  ${CYAN}6)${NC} ${YELLOW}[新]${NC} 打字机光标  文字逐字出现+光标闪烁"
    echo "  ${CYAN}7)${NC} ${YELLOW}[新]${NC} 深呼吸发光  柔和脉冲式外发光（仿 visionOS）"
    echo "  ${CYAN}8)${NC} ${YELLOW}[新]${NC} 故障波纹   RGB 位移+噪点故障艺术风"
    local anim_mode; anim_mode=$(ask_num "选择动画模式" 1 1 8)

    echo ""; echo "  ${WHITE}渐变色方案：${NC}"
    local tmpf="/tmp/_grd_show_$$"
    printf '%s\n' "$GRADIENT_LIST" > "$tmpf"
    local gtotal; gtotal=$(_count_lines "$tmpf")
    local i=1
    while IFS='|' read -r gname gcolors; do
        [ -z "$gname" ] && continue
        printf "  ${CYAN}%d)${NC} %-22s ${BLUE}%s${NC}\n" "$i" "$gname" "$gcolors"
        i=$((i+1))
    done < "$tmpf"; rm -f "$tmpf"
    local grad_num; grad_num=$(ask_num "选择渐变色" 1 1 "$gtotal")
    local tmpf2="/tmp/_grd_sel_$$"
    printf '%s\n' "$GRADIENT_LIST" > "$tmpf2"
    local sel_line; sel_line=$(awk -v n="$grad_num" 'NR==n{print;exit}' "$tmpf2")
    rm -f "$tmpf2"
    GRAD_NAME=$(printf '%s' "$sel_line"   | cut -d'|' -f1)
    GRAD_COLORS=$(printf '%s' "$sel_line" | cut -d'|' -f2)
    [ "$GRAD_COLORS" = "custom" ] && \
        GRAD_COLORS=$(ask_str "输入颜色(逗号分隔)" "#00e5ff,#2979ff,#aa00ff,#00e5ff")

    local anim_speed; anim_speed=$(ask_num "动画速度(秒，越小越快)" 4 1 30)
    [ -z "$FONT_NAME" ] && FONT_NAME="system-ui"
    info "模式: $anim_mode | 配色: $GRAD_NAME | 速度: ${anim_speed}s"
    _inject_keyframes
    _remove_css_block "BRAND_ANIMATION"
    _inject_brand_css "$anim_mode" "$anim_speed" "$GRAD_COLORS" "$FONT_NAME"
}

_inject_keyframes() {
    grep -q "=== KEYFRAMES_ALL ===" "$ACTIVE_CSS" 2>/dev/null && \
        { info "关键帧已存在，跳过"; return; }
    local css="$ACTIVE_CSS"
    printf '\n/* === KEYFRAMES_ALL === */\n' >> "$css"

    # ── 原有5种 ─────────────────────────────────────────────────
    printf '@keyframes hue-rotate-flow {\n' >> "$css"
    printf '  0%%   { filter: hue-rotate(0deg)   brightness(1.2); }\n' >> "$css"
    printf '  25%%  { filter: hue-rotate(90deg)  brightness(1.3); }\n' >> "$css"
    printf '  50%%  { filter: hue-rotate(180deg) brightness(1.2); }\n' >> "$css"
    printf '  75%%  { filter: hue-rotate(270deg) brightness(1.3); }\n' >> "$css"
    printf '  100%% { filter: hue-rotate(360deg) brightness(1.2); }\n' >> "$css"
    printf '}\n' >> "$css"

    printf '@keyframes aurora-flow {\n' >> "$css"
    printf '  0%%   { background-position: 0%%   50%%; }\n' >> "$css"
    printf '  50%%  { background-position: 100%% 50%%; }\n' >> "$css"
    printf '  100%% { background-position: 0%%   50%%; }\n' >> "$css"
    printf '}\n' >> "$css"

    printf '@keyframes rainbow-pulse {\n' >> "$css"
    printf '  0%%   { filter: hue-rotate(0deg)   drop-shadow(0 0 6px  #00fff7); }\n' >> "$css"
    printf '  20%%  { filter: hue-rotate(72deg)  drop-shadow(0 0 14px #007cf0); }\n' >> "$css"
    printf '  40%%  { filter: hue-rotate(144deg) drop-shadow(0 0 6px  #ff4ecd); }\n' >> "$css"
    printf '  60%%  { filter: hue-rotate(216deg) drop-shadow(0 0 14px #a855f7); }\n' >> "$css"
    printf '  80%%  { filter: hue-rotate(288deg) drop-shadow(0 0 6px  #00fff7); }\n' >> "$css"
    printf '  100%% { filter: hue-rotate(360deg) drop-shadow(0 0 6px  #00fff7); }\n' >> "$css"
    printf '}\n' >> "$css"

    printf '@keyframes neon-flicker {\n' >> "$css"
    printf '  0%%,100%% { opacity:1;    filter: hue-rotate(0deg)   brightness(1.4) drop-shadow(0 0 10px #00fff7); }\n' >> "$css"
    printf '  15%%     { opacity:0.82; filter: hue-rotate(30deg)  brightness(1.1); }\n' >> "$css"
    printf '  30%%     { opacity:1;    filter: hue-rotate(90deg)  brightness(1.5) drop-shadow(0 0 20px #007cf0); }\n' >> "$css"
    printf '  50%%     { opacity:0.9;  filter: hue-rotate(180deg) brightness(1.3) drop-shadow(0 0 15px #ff4ecd); }\n' >> "$css"
    printf '  70%%     { opacity:1;    filter: hue-rotate(270deg) brightness(1.4) drop-shadow(0 0 20px #a855f7); }\n' >> "$css"
    printf '  85%%     { opacity:0.82; filter: hue-rotate(330deg) brightness(1.1); }\n' >> "$css"
    printf '}\n' >> "$css"

    printf '@keyframes shine {\n' >> "$css"
    printf '  0%%   { background-position: -200%% center; }\n' >> "$css"
    printf '  100%% { background-position:  200%% center; }\n' >> "$css"
    printf '}\n' >> "$css"

    # ── 新增3种 ─────────────────────────────────────────────────
    # 模式6：打字机光标（CSS only，通过 border-right 模拟）
    printf '@keyframes cursor-blink {\n' >> "$css"
    printf '  0%%,100%% { border-right-color: rgba(255,255,255,0.9); }\n' >> "$css"
    printf '  50%%     { border-right-color: transparent; }\n' >> "$css"
    printf '}\n' >> "$css"
    printf '@keyframes typing-glow {\n' >> "$css"
    printf '  0%%   { filter: hue-rotate(0deg)   brightness(1.1); }\n' >> "$css"
    printf '  50%%  { filter: hue-rotate(180deg) brightness(1.4); }\n' >> "$css"
    printf '  100%% { filter: hue-rotate(360deg) brightness(1.1); }\n' >> "$css"
    printf '}\n' >> "$css"

    # 模式7：深呼吸发光（visionOS 风格柔和脉冲）
    # 参考：多层 text-shadow 叠加产生柔和光晕
    printf '@keyframes breath-glow {\n' >> "$css"
    printf '  0%%,100%% {\n' >> "$css"
    printf '    filter: brightness(1.0) drop-shadow(0 0  4px rgba(0,229,255,0.4));\n' >> "$css"
    printf '    opacity: 0.90;\n' >> "$css"
    printf '  }\n' >> "$css"
    printf '  50%% {\n' >> "$css"
    printf '    filter: brightness(1.35) drop-shadow(0 0 18px rgba(0,229,255,0.9))\n' >> "$css"
    printf '                             drop-shadow(0 0 32px rgba(41,121,255,0.6));\n' >> "$css"
    printf '    opacity: 1.0;\n' >> "$css"
    printf '  }\n' >> "$css"
    printf '}\n' >> "$css"

    # 模式8：故障波纹（RGB 位移艺术风，仅使用 filter + transform）
    printf '@keyframes glitch-shift {\n' >> "$css"
    printf '  0%%,100%% { filter: hue-rotate(0deg)   drop-shadow( 2px 0 0 #ff0040) drop-shadow(-2px 0 0 #00fff7); transform: skewX(0deg); }\n' >> "$css"
    printf '  10%%      { filter: hue-rotate(40deg)  drop-shadow( 3px 0 0 #ff0040) drop-shadow(-3px 0 0 #00fff7); transform: skewX(-1.5deg); }\n' >> "$css"
    printf '  20%%      { filter: hue-rotate(0deg)   drop-shadow( 2px 0 0 #ff0040) drop-shadow(-2px 0 0 #00fff7); transform: skewX(0deg); }\n' >> "$css"
    printf '  30%%      { filter: hue-rotate(200deg) drop-shadow( 4px 0 0 #ff0040) drop-shadow(-1px 0 0 #00fff7); transform: skewX(1deg); }\n' >> "$css"
    printf '  40%%      { filter: hue-rotate(0deg)   drop-shadow( 2px 0 0 #ff0040) drop-shadow(-2px 0 0 #00fff7); transform: skewX(0deg); }\n' >> "$css"
    printf '  60%%      { filter: hue-rotate(320deg) drop-shadow( 2px 0 0 #ff0040) drop-shadow(-3px 0 0 #00fff7); transform: skewX(0.5deg); }\n' >> "$css"
    printf '  80%%      { filter: hue-rotate(0deg)   drop-shadow( 3px 0 0 #ff0040) drop-shadow(-2px 0 0 #00fff7); transform: skewX(-0.5deg); }\n' >> "$css"
    printf '}\n' >> "$css"

    # 通用：页面加载淡入
    printf '@keyframes page-fade-in {\n' >> "$css"
    printf '  from { opacity: 0; transform: translateY(8px); }\n' >> "$css"
    printf '  to   { opacity: 1; transform: translateY(0); }\n' >> "$css"
    printf '}\n' >> "$css"

    # 通用：卡片悬停脉冲边框
    printf '@keyframes card-border-pulse {\n' >> "$css"
    printf '  0%%,100%% { box-shadow: 0 4px 24px rgba(0,0,0,0.35), 0 0  6px rgba(0,229,255,0.15); }\n' >> "$css"
    printf '  50%%      { box-shadow: 0 6px 32px rgba(0,0,0,0.45), 0 0 18px rgba(0,229,255,0.50); }\n' >> "$css"
    printf '}\n' >> "$css"

    printf '/* === END KEYFRAMES_ALL === */\n' >> "$css"
    success "所有动画关键帧已注入（8种模式）"
}

_inject_brand_css() {
    local mode="$1" speed="$2" colors="$3" font="$4"
    local brand_anim use_filter bg_size first_color
    first_color=$(printf '%s' "$colors" | cut -d',' -f1)
    use_filter=0
    case "$mode" in
        1) brand_anim="hue-rotate-flow ${speed}s linear infinite"; use_filter=1; bg_size="200% 200%" ;;
        2) brand_anim="aurora-flow ${speed}s ease infinite"; bg_size="400% 400%" ;;
        3) brand_anim="rainbow-pulse ${speed}s linear infinite"; use_filter=1; bg_size="200% 200%" ;;
        4) brand_anim="neon-flicker ${speed}s ease-in-out infinite"; use_filter=1; bg_size="200% 200%" ;;
        5) brand_anim="shine ${speed}s linear infinite"; bg_size="300% 300%" ;;
        6) brand_anim="typing-glow ${speed}s linear infinite, cursor-blink 1s step-end infinite"; use_filter=1; bg_size="200% 200%" ;;
        7) brand_anim="breath-glow ${speed}s ease-in-out infinite"; use_filter=1; bg_size="200% 200%" ;;
        8) brand_anim="glitch-shift ${speed}s steps(1) infinite"; use_filter=1; bg_size="200% 200%" ;;
    esac
    local css="$ACTIVE_CSS"
    printf '\n/* === BRAND_ANIMATION mode=%s filter=%s === */\n' "$mode" "$use_filter" >> "$css"

    # 侧边栏 Brand
    printf '%s {\n' "$SEL_BRAND" >> "$css"
    printf '  display: block; font-family: "%s", sans-serif;\n' "$font" >> "$css"
    printf '  text-decoration: none; text-align: center; cursor: default;\n' >> "$css"
    if [ "$use_filter" = "1" ]; then
        printf '  background: linear-gradient(135deg, %s);\n' "$colors" >> "$css"
    else
        printf '  background: linear-gradient(90deg, %s, %s);\n' "$colors" "$first_color" >> "$css"
    fi
    printf '  background-size: %s;\n' "$bg_size" >> "$css"
    printf '  -webkit-background-clip: text; background-clip: text;\n' >> "$css"
    printf '  -webkit-text-fill-color: transparent;\n' >> "$css"
    # 模式6 打字机光标
    if [ "$mode" = "6" ]; then
        printf '  border-right: 2px solid rgba(255,255,255,0.9);\n' >> "$css"
        printf '  padding-right: 4px;\n' >> "$css"
    fi
    printf '  animation: %s;\n}\n' "$brand_anim" >> "$css"

    # 登录页 Brand
    printf '%s {\n' "$SEL_BRAND_LOGIN" >> "$css"
    printf '  font-weight: 400; word-break: break-word;\n' >> "$css"
    printf '  font-family: "%s", sans-serif;\n' "$font" >> "$css"
    if [ "$use_filter" = "1" ]; then
        printf '  background: linear-gradient(135deg, %s);\n' "$colors" >> "$css"
    else
        printf '  background: linear-gradient(90deg, %s, %s);\n' "$colors" "$first_color" >> "$css"
    fi
    printf '  background-size: %s;\n' "$bg_size" >> "$css"
    printf '  -webkit-background-clip: text; background-clip: text;\n' >> "$css"
    printf '  -webkit-text-fill-color: transparent;\n' >> "$css"
    if [ "$mode" = "6" ]; then
        printf '  border-right: 2px solid rgba(255,255,255,0.9);\n' >> "$css"
        printf '  padding-right: 4px;\n' >> "$css"
    fi
    printf '  animation: %s;\n}\n' "$brand_anim" >> "$css"
    printf '/* === END BRAND_ANIMATION === */\n' >> "$css"
    success "Brand 动画注入完成 [模式${mode}: $GRAD_NAME | ${speed}s]"
}

# ================================================================
#  切换动画模式
# ================================================================
step_switch_animation() {
    title "切换 Brand 动画模式"
    if ! grep -q "=== BRAND_ANIMATION" "$ACTIVE_CSS" 2>/dev/null; then
        warn "尚未启用 Brand 动画，请先通过步骤3设置"; return
    fi
    echo "  ${CYAN}1)${NC} 色相持续旋转 ${GREEN}[推荐]${NC}"; echo "  ${CYAN}2)${NC} 极光流动"
    echo "  ${CYAN}3)${NC} 彩虹脉冲发光"; echo "  ${CYAN}4)${NC} 霓虹闪烁"; echo "  ${CYAN}5)${NC} 左右平移"
    echo "  ${CYAN}6)${NC} ${YELLOW}[新]${NC} 打字机光标"; echo "  ${CYAN}7)${NC} ${YELLOW}[新]${NC} 深呼吸发光"
    echo "  ${CYAN}8)${NC} ${YELLOW}[新]${NC} 故障波纹"
    local new_mode; new_mode=$(ask_num "选择新模式" 1 1 8)
    local new_speed; new_speed=$(ask_num "动画速度(秒)" 4 1 30)
    local cur_colors
    cur_colors=$(grep "background: linear-gradient" "$ACTIVE_CSS" 2>/dev/null | \
        head -1 | sed 's/.*linear-gradient([^,]*,\s*//;s/)\s*!important.*//' | tr -d ' ')
    [ -z "$cur_colors" ] && cur_colors="${GRAD_COLORS:-#00e5ff,#2979ff,#aa00ff,#00e5ff}"
    local cur_font
    cur_font=$(grep 'font-family:' "$ACTIVE_CSS" 2>/dev/null | \
        grep -v '@font-face' | head -1 | sed 's/.*font-family: "//;s/".*//')
    [ -z "$cur_font" ] && cur_font="${FONT_NAME:-system-ui}"
    GRAD_COLORS="$cur_colors"; FONT_NAME="$cur_font"; GRAD_NAME="(当前配色)"
    _remove_css_block "BRAND_ANIMATION"
    _inject_brand_css "$new_mode" "$new_speed" "$GRAD_COLORS" "$FONT_NAME"
    success "动画已切换为模式 ${new_mode}"
}

# ================================================================
#  步骤4：毛玻璃  v2.0（完整修复版）
# ================================================================
step_glassmorphism() {
    title "步骤4：自适应毛玻璃效果 v2.0 [$ACTIVE_THEME]"
    info "v2.0：中间层穿透 + checkbox修复 + 标题条 + 图表 + Tab标签 + 响应式"
    info "检测到主题底色: ${THEME_BASE_COLOR}"
    ask "是否启用毛玻璃效果" || return

    echo ""
    echo "  ${WHITE}压暗强度选择：${NC}"
    echo "  ${CYAN}1)${NC} 轻度 (0.50) → 背景图隐约可见，通透感强"
    echo "  ${CYAN}2)${NC} 中度 (0.35) → 背景图适度压暗 ${GREEN}[推荐]${NC}"
    echo "  ${CYAN}3)${NC} 重度 (0.20) → 背景图大幅压暗，文字最清晰"
    echo "  ${CYAN}4)${NC} 自定义"
    local dk_choice; dk_choice=$(ask_num "选择压暗强度" 2 1 4)
    case "$dk_choice" in
        1) GLASS_DARKEN="0.50" ;;
        2) GLASS_DARKEN="0.35" ;;
        3) GLASS_DARKEN="0.20" ;;
        4) GLASS_DARKEN=$(ask_float "压暗值 [0.10最暗 ~ 0.70最亮]" "0.35") ;;
    esac
    local blur_choice; blur_choice=$(ask_num "模糊强度 [1=轻 2=中 3=重, 默认2]" 2 1 3)
    case "$blur_choice" in
        1) GLASS_BLUR="6" ;;
        2) GLASS_BLUR="12" ;;
        3) GLASS_BLUR="20" ;;
    esac
    info "压暗强度: ${GLASS_DARKEN} | 模糊: ${GLASS_BLUR}px"

    if grep -q "=== GLASSMORPHISM ===" "$ACTIVE_CSS" 2>/dev/null; then
        if ask "毛玻璃样式已存在，是否重新注入"; then
            _remove_css_block "GLASSMORPHISM"
        else info "跳过"; return; fi
    fi

    local css="$ACTIVE_CSS"
    local BL="$GLASS_BLUR" DK="$GLASS_DARKEN"
    local BR="$GLASS_BORDER" BGPATH="$THEME_BG_WEBPATH"

    printf '\n/* === GLASSMORPHISM theme=%s darken=%s blur=%s === */\n' \
        "$ACTIVE_THEME" "$DK" "$BL" >> "$css"

    # ── 1. 壁纸根基层 ────────────────────────────────────────
    printf 'html, body {\n' >> "$css"
    printf "  background: url('%s') center center / cover fixed no-repeat !important;\n" \
        "$BGPATH" >> "$css"
    printf '  background-color: #0a0f1a !important;\n' >> "$css"
    printf '  min-height: 100vh !important;\n}\n' >> "$css"

    # ── 2. ★击穿所有中间白色容器（核心修复）────────────────
    printf '/* --- v2.0 击穿白色中间层 --- */\n' >> "$css"
    printf '#wrapper, #page-wrapper, .page-wrapper,\n' >> "$css"
    printf '#main, .main-wrapper, #main-wrapper,\n' >> "$css"
    printf '.container, .container-fluid, #content-wrapper,\n' >> "$css"
    printf '.luci-app, .luci-page, .view, .node,\n' >> "$css"
    printf '.row, [class*="col-"], .cbi-map {\n' >> "$css"
    printf '  background: transparent !important;\n' >> "$css"
    printf '  background-color: transparent !important;\n}\n' >> "$css"

    # ── 3. ★页面标题白条（截图1/2/3/5问题根源）────────────
    printf '/* --- v2.0 标题条修复 --- */\n' >> "$css"
    printf '.cbi-map-title, .cbi-section-legend,\n' >> "$css"
    printf 'legend, .panel-heading, .panel-title,\n' >> "$css"
    printf '.page-header, .node-title,\n' >> "$css"
    printf '.cbi-tabcontainer > .cbi-section-legend {\n' >> "$css"
    printf '  background: rgba(0,0,0,0.45) !important;\n' >> "$css"
    printf '  backdrop-filter: brightness(%s) blur(10px) !important;\n' "$DK" >> "$css"
    printf '  -webkit-backdrop-filter: brightness(%s) blur(10px) !important;\n' "$DK" >> "$css"
    printf '  border-bottom: 1px solid %s !important;\n' "$BR" >> "$css"
    printf '  border-radius: 10px 10px 0 0 !important;\n' >> "$css"
    printf '  color: #ffffff !important;\n' >> "$css"
    printf '  padding: 8px 16px !important;\n}\n' >> "$css"

    # ── 4. 内容主区透明 ──────────────────────────────────────
    printf '%s {\n' "$SEL_CONTENT" >> "$css"
    printf '  background: transparent !important;\n' >> "$css"
    printf '  background-color: transparent !important;\n}\n' >> "$css"

    # ── 5. 侧边栏 ────────────────────────────────────────────
    printf '%s {\n' "$SEL_SIDEBAR" >> "$css"
    printf '  background: rgba(0,0,0,0.22) !important;\n' >> "$css"
    printf '  backdrop-filter: brightness(%s) blur(%spx) saturate(160%%) !important;\n' \
        "$DK" "$BL" >> "$css"
    printf '  -webkit-backdrop-filter: brightness(%s) blur(%spx) saturate(160%%) !important;\n' \
        "$DK" "$BL" >> "$css"
    printf '  border-right: 1px solid %s !important;\n}\n' "$BR" >> "$css"

    # ── 6. 顶部导航 ──────────────────────────────────────────
    printf '%s {\n' "$SEL_HEADER" >> "$css"
    printf '  background: rgba(0,0,0,0.15) !important;\n' >> "$css"
    printf '  background-color: rgba(0,0,0,0.15) !important;\n' >> "$css"
    printf '  backdrop-filter: brightness(%s) blur(18px) saturate(180%%) !important;\n' \
        "$DK" >> "$css"
    printf '  -webkit-backdrop-filter: brightness(%s) blur(18px) saturate(180%%) !important;\n' \
        "$DK" >> "$css"
    printf '  border-bottom: 1px solid %s !important;\n' "$BR" >> "$css"
    printf '  box-shadow: 0 2px 16px rgba(0,0,0,0.40) !important;\n}\n' >> "$css"

    # ── 7. 内容卡片（带悬停动画）────────────────────────────
    printf '%s {\n' "$SEL_CARD" >> "$css"
    printf '  background: rgba(0,0,0,0.28) !important;\n' >> "$css"
    printf '  backdrop-filter: brightness(%s) blur(%spx) saturate(140%%) !important;\n' \
        "$DK" "$BL" >> "$css"
    printf '  -webkit-backdrop-filter: brightness(%s) blur(%spx) saturate(140%%) !important;\n' \
        "$DK" "$BL" >> "$css"
    printf '  border: 1px solid %s !important;\n' "$BR" >> "$css"
    printf '  border-radius: 12px !important;\n' >> "$css"
    printf '  box-shadow: 0 4px 24px rgba(0,0,0,0.35) !important;\n' >> "$css"
    # 加载淡入动画
    printf '  animation: page-fade-in 0.4s ease both !important;\n}\n' >> "$css"
    # 卡片悬停发光效果（社区主流做法：hover时增强 box-shadow）
    printf '%s:hover {\n' "$SEL_CARD" >> "$css"
    printf '  box-shadow: 0 6px 32px rgba(0,0,0,0.45),\n' >> "$css"
    printf '              0 0 18px rgba(0,229,255,0.30) !important;\n' >> "$css"
    printf '  border-color: rgba(0,229,255,0.35) !important;\n' >> "$css"
    printf '  transition: box-shadow 0.3s ease, border-color 0.3s ease !important;\n}\n' >> "$css"

    # ── 8. ★Tab 标签页（截图1/4的标签白底问题）────────────
    printf '/* --- v2.0 Tab标签修复 --- */\n' >> "$css"
    printf '.nav-tabs, .nav-tabs > li,\n' >> "$css"
    printf '.cbi-tabmenu, .cbi-tabmenu li {\n' >> "$css"
    printf '  background: transparent !important;\n' >> "$css"
    printf '  border-color: %s !important;\n' "$BR" >> "$css"
    printf '}\n' >> "$css"
    printf '.nav-tabs .nav-link, .nav-tabs > li > a,\n' >> "$css"
    printf '.cbi-tabmenu li a {\n' >> "$css"
    printf '  background: rgba(0,0,0,0.30) !important;\n' >> "$css"
    printf '  color: rgba(255,255,255,0.80) !important;\n' >> "$css"
    printf '  border: 1px solid %s !important;\n' "$BR" >> "$css"
    printf '  border-radius: 8px 8px 0 0 !important;\n' >> "$css"
    printf '  transition: all 0.25s ease !important;\n}\n' >> "$css"
    printf '.nav-tabs .nav-link:hover, .cbi-tabmenu li a:hover {\n' >> "$css"
    printf '  background: rgba(0,180,160,0.30) !important;\n' >> "$css"
    printf '  color: #ffffff !important;\n}\n' >> "$css"
    printf '.nav-tabs .nav-link.active, .nav-tabs > li.active > a,\n' >> "$css"
    printf '.cbi-tabmenu li.cbi-tab a {\n' >> "$css"
    printf '  background: rgba(0,180,160,0.45) !important;\n' >> "$css"
    printf '  color: #ffffff !important;\n' >> "$css"
    printf '  border-bottom-color: transparent !important;\n' >> "$css"
    printf '  box-shadow: 0 -2px 8px rgba(0,229,255,0.30) !important;\n}\n' >> "$css"

    # ── 9. ★checkbox / radio（截图1/4问题）────────────────
    printf '/* --- v2.0 checkbox/radio 完整修复 --- */\n' >> "$css"
    printf 'input[type="checkbox"],\n' >> "$css"
    printf 'input[type="radio"] {\n' >> "$css"
    # accent-color 是现代标准方式，无需 JS
    printf '  accent-color: #00d4aa !important;\n' >> "$css"
    printf '  width: 16px !important;\n' >> "$css"
    printf '  height: 16px !important;\n' >> "$css"
    printf '  cursor: pointer !important;\n' >> "$css"
    printf '  opacity: 1 !important;\n' >> "$css"
    printf '  filter: brightness(1.4) drop-shadow(0 0 2px rgba(0,212,170,0.6)) !important;\n' >> "$css"
    printf '  vertical-align: middle !important;\n}\n' >> "$css"
    # 未勾选状态：加白色轮廓确保在任何背景可见
    printf 'input[type="checkbox"]:not(:checked),\n' >> "$css"
    printf 'input[type="radio"]:not(:checked) {\n' >> "$css"
    printf '  outline: 1.5px solid rgba(255,255,255,0.75) !important;\n' >> "$css"
    printf '  outline-offset: 1px !important;\n' >> "$css"
    printf '  border-radius: 3px !important;\n}\n' >> "$css"
    # 已勾选：青色外发光
    printf 'input[type="checkbox"]:checked,\n' >> "$css"
    printf 'input[type="radio"]:checked {\n' >> "$css"
    printf '  outline: 1.5px solid rgba(0,212,170,0.80) !important;\n' >> "$css"
    printf '  filter: brightness(1.5) drop-shadow(0 0 4px rgba(0,212,170,0.8)) !important;\n}\n' >> "$css"

    # ── 10. 表格 ─────────────────────────────────────────────
    printf 'table, .table { background: transparent !important; }\n' >> "$css"
    printf 'thead {\n  background: rgba(0,0,0,0.42) !important;\n' >> "$css"
    printf '  backdrop-filter: brightness(%s) !important;\n' "$DK" >> "$css"
    printf '  -webkit-backdrop-filter: brightness(%s) !important;\n}\n' "$DK" >> "$css"
    printf 'tbody tr { background: rgba(0,0,0,0.18) !important;\n' >> "$css"
    printf '  transition: background 0.2s ease !important; }\n' >> "$css"
    printf 'tbody tr:hover { background: rgba(0,229,255,0.08) !important; }\n' >> "$css"
    printf 'tbody tr:hover td { background: transparent !important; }\n' >> "$css"
    printf 'td, th { border-color: %s !important;\n' "$BR" >> "$css"
    printf '  background: transparent !important; }\n' >> "$css"
    # 网络状态表格
    printf '.network-status-table, .ifacebox, .ifacebox-body {\n' >> "$css"
    printf '  background: rgba(0,0,0,0.28) !important;\n' >> "$css"
    printf '  backdrop-filter: brightness(%s) !important;\n' "$DK" >> "$css"
    printf '  -webkit-backdrop-filter: brightness(%s) !important;\n' "$DK" >> "$css"
    printf '  border-color: %s !important;\n}\n' "$BR" >> "$css"

    # ── 11. ★图表/canvas（截图3流量图白底）────────────────
    printf '/* --- v2.0 图表区域修复 --- */\n' >> "$css"
    printf '.chart-container, .chart-wrapper,\n' >> "$css"
    printf '[id*="chart"], [class*="chart"],\n' >> "$css"
    printf '[class*="traffic"], [id*="traffic"],\n' >> "$css"
    printf '.flot-base, .flot-overlay,\n' >> "$css"
    printf 'canvas {\n' >> "$css"
    printf '  background: rgba(0,0,0,0.28) !important;\n' >> "$css"
    printf '  border-radius: 8px !important;\n}\n' >> "$css"
    # 图表父容器
    printf '.netdata-chart-row, .netdata-chartblock-container,\n' >> "$css"
    printf '.cbi-value-widget, .widget {\n' >> "$css"
    printf '  background: rgba(0,0,0,0.20) !important;\n' >> "$css"
    printf '  border-radius: 8px !important;\n}\n' >> "$css"

    # ── 12. 输入框（v1.1 修复继承）──────────────────────────
    printf '/* --- v2.0 输入框：深色背景确保白字可见 --- */\n' >> "$css"
    printf 'input[type="text"], input[type="password"], input[type="number"],\n' >> "$css"
    printf 'input[type="email"], input[type="url"], input[type="search"],\n' >> "$css"
    printf 'input[type="tel"], input[type="date"], input[type="time"] {\n' >> "$css"
    printf '  background: rgba(0,0,0,0.55) !important;\n' >> "$css"
    printf '  border: 1px solid rgba(255,255,255,0.60) !important;\n' >> "$css"
    printf '  border-radius: 6px !important;\n' >> "$css"
    printf '  color: #ffffff !important;\n' >> "$css"
    printf '  backdrop-filter: blur(4px) !important;\n' >> "$css"
    printf '  box-shadow: inset 0 1px 3px rgba(0,0,0,0.40) !important;\n' >> "$css"
    printf '  transition: border-color 0.25s ease, box-shadow 0.25s ease !important;\n}\n' >> "$css"
    printf 'input[type="text"]:focus, input[type="password"]:focus,\n' >> "$css"
    printf 'input[type="number"]:focus, input[type="email"]:focus,\n' >> "$css"
    printf 'input[type="url"]:focus, input[type="search"]:focus {\n' >> "$css"
    printf '  border-color: rgba(0,220,220,0.90) !important;\n' >> "$css"
    printf '  box-shadow: 0 0 0 2px rgba(0,220,220,0.30),\n' >> "$css"
    printf '    inset 0 1px 3px rgba(0,0,0,0.40) !important;\n' >> "$css"
    printf '  outline: none !important;\n}\n' >> "$css"
    printf 'select {\n' >> "$css"
    printf '  background: rgba(0,0,0,0.60) !important;\n' >> "$css"
    printf '  border: 1px solid rgba(255,255,255,0.60) !important;\n' >> "$css"
    printf '  border-radius: 6px !important;\n' >> "$css"
    printf '  color: #ffffff !important;\n' >> "$css"
    printf '  backdrop-filter: blur(4px) !important;\n}\n' >> "$css"
    printf 'select:focus {\n' >> "$css"
    printf '  border-color: rgba(0,220,220,0.90) !important;\n' >> "$css"
    printf '  outline: none !important;\n}\n' >> "$css"
    printf 'textarea {\n' >> "$css"
    printf '  background: rgba(0,0,0,0.55) !important;\n' >> "$css"
    printf '  border: 1px solid rgba(255,255,255,0.60) !important;\n' >> "$css"
    printf '  border-radius: 6px !important;\n' >> "$css"
    printf '  color: #ffffff !important;\n' >> "$css"
    printf '  backdrop-filter: blur(4px) !important;\n}\n' >> "$css"
    printf 'textarea:focus {\n' >> "$css"
    printf '  border-color: rgba(0,220,220,0.90) !important;\n' >> "$css"
    printf '  outline: none !important;\n}\n' >> "$css"
    printf '.form-control {\n' >> "$css"
    printf '  background: rgba(0,0,0,0.55) !important;\n' >> "$css"
    printf '  border: 1px solid rgba(255,255,255,0.60) !important;\n' >> "$css"
    printf '  border-radius: 6px !important;\n' >> "$css"
    printf '  color: #ffffff !important;\n}\n' >> "$css"

    # ── 13. 菜单激活项 ───────────────────────────────────────
    printf '.sidenav-menu .nav-item.active > a,\n' >> "$css"
    printf '.nav-pills .nav-link.active, #menu .active > a {\n' >> "$css"
    printf '  background: linear-gradient(90deg,\n' >> "$css"
    printf '    rgba(0,180,180,0.50),rgba(0,100,200,0.40)) !important;\n' >> "$css"
    printf '  border-left: 3px solid #00fff7 !important;\n' >> "$css"
    printf '  border-radius: 0 8px 8px 0 !important;\n}\n' >> "$css"

    # ── 14. 登录框 ───────────────────────────────────────────
    printf '%s {\n' "$SEL_LOGIN" >> "$css"
    printf '  background: rgba(0,0,0,0.22) !important;\n' >> "$css"
    printf '  backdrop-filter: brightness(%s) blur(22px) saturate(160%%) !important;\n' \
        "$DK" >> "$css"
    printf '  -webkit-backdrop-filter: brightness(%s) blur(22px) saturate(160%%) !important;\n' \
        "$DK" >> "$css"
    printf '  border: 1px solid %s !important;\n' "$BR" >> "$css"
    printf '  border-radius: 18px !important;\n' >> "$css"
    printf '  box-shadow: 0 8px 40px rgba(0,0,0,0.50) !important;\n}\n' >> "$css"

    # ── 15. 登录按钮 ─────────────────────────────────────────
    printf '%s .cbi-button-apply,\n' "$SEL_LOGIN" >> "$css"
    printf '%s input[type="submit"],\n' "$SEL_LOGIN" >> "$css"
    printf '%s button[type="submit"] {\n' "$SEL_LOGIN" >> "$css"
    printf '  width: 100%% !important; min-height: 45px;\n' >> "$css"
    printf '  margin: 20px 0 40px; padding: 10px 0;\n' >> "$css"
    printf '  font-size: 15px; font-weight: 600;\n' >> "$css"
    printf '  letter-spacing: .30rem; text-align: center;\n' >> "$css"
    printf '  background: rgba(255,255,255,0.08) !important;\n' >> "$css"
    printf '  border: 1px solid rgba(255,255,255,0.35) !important;\n' >> "$css"
    printf '  border-radius: 9999px !important;\n' >> "$css"
    printf '  cursor: pointer;\n' >> "$css"
    printf '  transition: all 0.25s ease !important;\n' >> "$css"
    printf '  color: #ffffff !important;\n}\n' >> "$css"
    printf '%s .cbi-button-apply:hover,\n' "$SEL_LOGIN" >> "$css"
    printf '%s input[type="submit"]:hover,\n' "$SEL_LOGIN" >> "$css"
    printf '%s button[type="submit"]:hover {\n' "$SEL_LOGIN" >> "$css"
    printf '  background: rgba(0,180,160,0.35) !important;\n' >> "$css"
    printf '  border-color: rgba(0,229,255,0.70) !important;\n' >> "$css"
    printf '  box-shadow: 0 0 0 2px rgba(0,229,255,0.30),\n' >> "$css"
    printf '              0 4px 20px rgba(0,180,160,0.40) !important;\n}\n' >> "$css"

    # ── 16. 弹窗 ─────────────────────────────────────────────
    printf '.modal-content, .modal-dialog, .modal .card,\n' >> "$css"
    printf '[role="dialog"], [role="dialog"] .card,\n' >> "$css"
    printf '.dialog, .popup, .luci-popup, .cbi-modal, .cbi-popup {\n' >> "$css"
    printf '  background: rgba(0,0,0,0.18) !important;\n' >> "$css"
    printf '  backdrop-filter: brightness(%s) blur(20px) saturate(150%%) !important;\n' \
        "$DK" >> "$css"
    printf '  -webkit-backdrop-filter: brightness(%s) blur(20px) saturate(150%%) !important;\n' \
        "$DK" >> "$css"
    printf '  border: 1px solid %s !important;\n' "$BR" >> "$css"
    printf '  border-radius: 14px !important;\n' >> "$css"
    printf '  box-shadow: 0 12px 48px rgba(0,0,0,0.60) !important;\n}\n' >> "$css"
    printf '.modal-content input, .modal-content select, .modal-content textarea,\n' >> "$css"
    printf '[role="dialog"] input, [role="dialog"] select, [role="dialog"] textarea,\n' >> "$css"
    printf '.cbi-modal input, .cbi-modal select, .cbi-modal textarea {\n' >> "$css"
    printf '  background: rgba(0,0,0,0.55) !important;\n' >> "$css"
    printf '  border: 1px solid rgba(255,255,255,0.60) !important;\n' >> "$css"
    printf '  border-radius: 6px !important;\n}\n' >> "$css"
    printf '.modal-backdrop { background: rgba(0,0,0,0.65) !important; }\n' >> "$css"

    # ── 17. 提示框 ───────────────────────────────────────────
    printf '.alert, .notice, .cbi-map-descr, .warning {\n' >> "$css"
    printf '  background: rgba(0,0,0,0.42) !important;\n' >> "$css"
    printf '  backdrop-filter: brightness(%s) !important;\n' "$DK" >> "$css"
    printf '  -webkit-backdrop-filter: brightness(%s) !important;\n' "$DK" >> "$css"
    printf '  border: 1px solid %s !important;\n' "$BR" >> "$css"
    printf '  border-radius: 8px !important;\n}\n' >> "$css"

    # ── 18. 滚动条美化（社区常见做法）──────────────────────
    printf '/* --- v2.0 滚动条美化 --- */\n' >> "$css"
    printf '::-webkit-scrollbar { width: 6px; height: 6px; }\n' >> "$css"
    printf '::-webkit-scrollbar-track {\n' >> "$css"
    printf '  background: rgba(0,0,0,0.20);\n' >> "$css"
    printf '  border-radius: 3px;\n}\n' >> "$css"
    printf '::-webkit-scrollbar-thumb {\n' >> "$css"
    printf '  background: rgba(0,229,255,0.40);\n' >> "$css"
    printf '  border-radius: 3px;\n}\n' >> "$css"
    printf '::-webkit-scrollbar-thumb:hover {\n' >> "$css"
    printf '  background: rgba(0,229,255,0.70);\n}\n' >> "$css"

    # ── 19. ★响应式适配（移动端）────────────────────────────
    printf '/* --- v2.0 移动端响应式 --- */\n' >> "$css"
    printf '@media (max-width: 768px) {\n' >> "$css"
    printf '  html, body {\n' >> "$css"
    printf '    background-attachment: scroll !important;\n' >> "$css"
    printf '  }\n' >> "$css"
    printf '  %s {\n' "$SEL_SIDEBAR" >> "$css"
    printf '    backdrop-filter: brightness(%s) blur(8px) !important;\n' "$DK" >> "$css"
    printf '    -webkit-backdrop-filter: brightness(%s) blur(8px) !important;\n' "$DK" >> "$css"
    printf '  }\n' >> "$css"
    printf '  %s {\n' "$SEL_CARD" >> "$css"
    printf '    border-radius: 8px !important;\n' >> "$css"
    printf '    backdrop-filter: brightness(%s) blur(6px) !important;\n' "$DK" >> "$css"
    printf '    -webkit-backdrop-filter: brightness(%s) blur(6px) !important;\n' "$DK" >> "$css"
    printf '  }\n' >> "$css"
    printf '  %s {\n' "$SEL_LOGIN" >> "$css"
    printf '    margin: 16px !important;\n' >> "$css"
    printf '    border-radius: 14px !important;\n' >> "$css"
    printf '  }\n' >> "$css"
    printf '}\n' >> "$css"

    printf '/* === END GLASSMORPHISM === */\n' >> "$css"
    success "毛玻璃注入完成 v2.0（中间层穿透+checkbox+标题条+图表+Tab+响应式）"
}

# ================================================================
#  步骤5：文字颜色  v2.0（全覆盖修复版）
# ================================================================
step_text() {
    title "步骤5：文字颜色优化 v2.0 [$ACTIVE_THEME]"
    ask "是否优化文字颜色与可读性" || return
    if grep -q "=== TEXT_COLOR ===" "$ACTIVE_CSS" 2>/dev/null; then
        if ask "文字样式已存在，是否重新注入"; then
            _remove_css_block "TEXT_COLOR"
        else info "跳过"; return; fi
    fi
    local css="$ACTIVE_CSS"
    printf '\n/* === TEXT_COLOR theme=%s === */\n' "$ACTIVE_THEME" >> "$css"

    # 通用文字（双层阴影：近距离锐边 + 远距离光晕，任意背景可读）
    printf 'body, p, li, span, label,\n' >> "$css"
    printf '.cbi-value-title, .cbi-value-field {\n' >> "$css"
    printf '  color: #ffffff !important;\n' >> "$css"
    printf '  text-shadow: 0 1px 3px rgba(0,0,0,0.95),\n' >> "$css"
    printf '               0 0   8px rgba(0,0,0,0.70) !important;\n}\n' >> "$css"

    # 标题
    printf 'h1, h2, h3, h4, h5, h6, legend {\n' >> "$css"
    printf '  color: #ffffff !important;\n' >> "$css"
    printf '  text-shadow: 0 1px 5px rgba(0,0,0,0.95),\n' >> "$css"
    printf '               0 0  12px rgba(0,0,0,0.70) !important;\n}\n' >> "$css"

    # ★ 标题白条内文字（截图1/2/5）
    printf '.cbi-section-legend, .cbi-section-legend *,\n' >> "$css"
    printf '.cbi-map-title, .cbi-map-title *,\n' >> "$css"
    printf 'legend *, .panel-heading, .panel-heading *,\n' >> "$css"
    printf '.page-header, .page-header * {\n' >> "$css"
    printf '  color: #ffffff !important;\n' >> "$css"
    printf '  text-shadow: 0 1px 4px rgba(0,0,0,0.95) !important;\n}\n' >> "$css"

    # ★ 表格文字（截图5启动脚本淡灰文字）
    printf 'td, th, tr, tbody *, thead * {\n' >> "$css"
    printf '  color: #ffffff !important;\n' >> "$css"
    printf '  text-shadow: 0 1px 3px rgba(0,0,0,0.90) !important;\n}\n' >> "$css"
    printf '.table td, .table th,\n' >> "$css"
    printf '.cbi-section td, .cbi-section th {\n' >> "$css"
    printf '  color: #ffffff !important;\n' >> "$css"
    printf '  text-shadow: 0 1px 3px rgba(0,0,0,0.90) !important;\n}\n' >> "$css"

    # 次要文字
    printf '.text-muted, small, .help-block, .cbi-map-descr p {\n' >> "$css"
    printf '  color: rgba(255,255,255,0.82) !important;\n' >> "$css"
    printf '  text-shadow: 0 1px 3px rgba(0,0,0,0.90) !important;\n}\n' >> "$css"

    # 侧边栏
    printf '%s a, %s span, %s li, %s * {\n' \
        "$SEL_SIDEBAR" "$SEL_SIDEBAR" "$SEL_SIDEBAR" "$SEL_SIDEBAR" >> "$css"
    printf '  color: #ffffff !important;\n' >> "$css"
    printf '  text-shadow: 0 1px 4px rgba(0,0,0,0.90) !important;\n}\n' >> "$css"

    # 顶部导航
    printf '%s * {\n' "$SEL_HEADER" >> "$css"
    printf '  color: #ffffff !important;\n' >> "$css"
    printf '  text-shadow: 0 1px 4px rgba(0,0,0,0.90) !important;\n}\n' >> "$css"

    # 链接
    printf 'a { color: #7ecfff !important;\n' >> "$css"
    printf '  transition: color 0.2s ease !important; }\n' >> "$css"
    printf 'a:hover { color: #00fff7 !important;\n' >> "$css"
    printf '  text-shadow: 0 0 8px rgba(0,255,247,0.50) !important; }\n' >> "$css"
    printf 'a:active { color: #dddddd !important; }\n' >> "$css"

    # 输入框（深色背景已保证，无需阴影）
    printf 'input, select, textarea, .form-control {\n' >> "$css"
    printf '  text-shadow: none !important;\n' >> "$css"
    printf '  color: #ffffff !important;\n}\n' >> "$css"

    # placeholder（半透明白色，可识别不抢眼）
    printf 'input::placeholder, textarea::placeholder {\n' >> "$css"
    printf '  color: rgba(255,255,255,0.52) !important;\n' >> "$css"
    printf '  opacity: 1 !important;\n}\n' >> "$css"
    printf '::-webkit-input-placeholder { color: rgba(255,255,255,0.52) !important; }\n' >> "$css"
    printf '::-moz-placeholder           { color: rgba(255,255,255,0.52) !important; }\n' >> "$css"

    # 弹窗内文字
    printf '.modal-content *, [role="dialog"] *,\n' >> "$css"
    printf '.cbi-modal *, .cbi-popup *, .dialog *, .popup * {\n' >> "$css"
    printf '  color: #ffffff !important;\n' >> "$css"
    printf '  text-shadow: 0 1px 3px rgba(0,0,0,0.80) !important;\n}\n' >> "$css"

    # 按钮文字（不覆盖自定义彩色按钮）
    printf 'button:not([class*="btn-primary"]):not([class*="btn-danger"]):not([class*="btn-success"]),\n' >> "$css"
    printf '.cbi-button, .cbi-button-action {\n' >> "$css"
    printf '  text-shadow: 0 1px 2px rgba(0,0,0,0.50) !important;\n}\n' >> "$css"

    # ★ 状态/徽章文字（不反色）
    printf '.badge, .label, .tag {\n' >> "$css"
    printf '  text-shadow: none !important;\n}\n' >> "$css"

    printf '/* === END TEXT_COLOR === */\n' >> "$css"
    success "文字颜色注入完成 v2.0（全覆盖：标题条/表格/侧边栏/弹窗）"
}

# ================================================================
#  步骤6：登录框位置
# ================================================================
step_login_position() {
    title "步骤6：登录框位置 [$ACTIVE_THEME]"
    echo "  ${CYAN}1)${NC} 居中（默认，跳过）"; echo "  ${CYAN}2)${NC} 偏左  5%"
    echo "  ${CYAN}3)${NC} 偏左 10%";           echo "  ${CYAN}4)${NC} 偏右  5%"
    echo "  ${CYAN}5)${NC} 自定义"
    local pos; pos=$(ask_num "请选择" 1 1 5)
    local justify="" padding=""
    case "$pos" in
        1) info "保持默认居中，跳过"; return ;;
        2) justify="flex-start"; padding="padding-left: 5vw" ;;
        3) justify="flex-start"; padding="padding-left: 10vw" ;;
        4) justify="flex-end";   padding="padding-right: 5vw" ;;
        5)
            local dir dist
            dir=$(ask_str "方向(left/right)" "left")
            dist=$(ask_str "距离(如 8vw)" "8vw")
            if [ "$dir" = "right" ]; then
                justify="flex-end"; padding="padding-right: $dist"
            else
                justify="flex-start"; padding="padding-left: $dist"
            fi ;;
    esac
    _remove_css_block "LOGIN_POSITION"
    local css="$ACTIVE_CSS"
    printf '\n/* === LOGIN_POSITION theme=%s === */\n' "$ACTIVE_THEME" >> "$css"
    printf '.login-page, body.login {\n' >> "$css"
    printf '  display: flex !important;\n' >> "$css"
    printf '  justify-content: %s !important;\n' "$justify" >> "$css"
    printf '  align-items: center !important;\n' >> "$css"
    printf '  %s !important;\n}\n' "$padding" >> "$css"
    printf '%s {\n  margin: 0 !important; transform: none !important;\n' "$SEL_LOGIN" >> "$css"
    printf '  position: relative !important;\n}\n' >> "$css"
    printf '/* === END LOGIN_POSITION === */\n' >> "$css"
    success "登录框位置已设置 (${justify})"
}

# ================================================================
#  步骤7：清理页面元素
# ================================================================
step_clean() {
    title "步骤7：清理页面元素 [$ACTIVE_THEME]"
    [ -n "$SYSAUTH" ] && ask "删除登录页 SVG 图标" && {
        sed -i 's/<img[^>]*\.svg[^>]*>//g' "$SYSAUTH" 2>/dev/null
        success "SVG 图标已删除"
    }
    [ -n "$FOOTER" ] && ask "删除 Footer 底部跳转链接" && {
        sed -i '/<footer/,/<\/footer>/{ /<a class="luci-link"/d }' "$FOOTER" 2>/dev/null
        success "Footer 链接已删除"
    }
    [ -n "$HEADER_HTM" ] && ask "移除橙色导航栏 class" && {
        [ ! -f "${HEADER_HTM}.bak" ] && cp "$HEADER_HTM" "${HEADER_HTM}.bak"
        sed -i 's/class="bg-primary"/class="bg-glass"/g' "$HEADER_HTM"
        sed -i 's/class="sidenav-header bg-primary"/class="sidenav-header"/g' "$HEADER_HTM"
        success "header.htm 橙色 class 已移除"
    }
}

# ================================================================
#  步骤8（新增）：额外特效
# ================================================================
step_extra_effects() {
    title "步骤8（新增）：额外特效 [$ACTIVE_THEME]"
    echo ""
    echo "  ${WHITE}可选特效（可多选，逐一确认）：${NC}"

    # ── 特效A：扫描线覆盖层（赛博朋克感）────────────────────
    if ask "启用扫描线效果（细微横纹，赛博朋克感）"; then
        _remove_css_block "SCANLINE"
        local css="$ACTIVE_CSS"
        printf '\n/* === SCANLINE theme=%s === */\n' "$ACTIVE_THEME" >> "$css"
        printf 'body::after {\n' >> "$css"
        printf '  content: "";\n' >> "$css"
        printf '  position: fixed;\n' >> "$css"
        printf '  top: 0; left: 0;\n' >> "$css"
        printf '  width: 100%%; height: 100%%;\n' >> "$css"
        printf '  pointer-events: none;\n' >> "$css"
        printf '  z-index: 9999;\n' >> "$css"
        # 用 repeating-linear-gradient 实现纯 CSS 扫描线
        printf '  background: repeating-linear-gradient(\n' >> "$css"
        printf '    0deg,\n' >> "$css"
        printf '    rgba(0,0,0,0.03) 0px,\n' >> "$css"
        printf '    rgba(0,0,0,0.03) 1px,\n' >> "$css"
        printf '    transparent 1px,\n' >> "$css"
        printf '    transparent 3px\n' >> "$css"
        printf '  );\n}\n' >> "$css"
        printf '/* === END SCANLINE === */\n' >> "$css"
        success "扫描线效果已注入"
    fi

    # ── 特效B：粒子感发光边框（卡片）────────────────────────
    if ask "启用卡片粒子感发光边框（悬停时渐变边框动画）"; then
        _remove_css_block "GLOW_BORDER"
        local css="$ACTIVE_CSS"
        printf '\n/* === GLOW_BORDER theme=%s === */\n' "$ACTIVE_THEME" >> "$css"
        # 注入对应关键帧（如已有 KEYFRAMES_ALL 则独立注入）
        if ! grep -q "border-glow-rotate" "$css" 2>/dev/null; then
            printf '@keyframes border-glow-rotate {\n' >> "$css"
            printf '  0%%   { border-color: rgba(0,229,255,0.50); box-shadow: 0 0  8px rgba(0,229,255,0.20); }\n' >> "$css"
            printf '  25%%  { border-color: rgba(168,85,247,0.50); box-shadow: 0 0 14px rgba(168,85,247,0.30); }\n' >> "$css"
            printf '  50%%  { border-color: rgba(236,72,153,0.50); box-shadow: 0 0  8px rgba(236,72,153,0.20); }\n' >> "$css"
            printf '  75%%  { border-color: rgba(41,121,255,0.50); box-shadow: 0 0 14px rgba(41,121,255,0.30); }\n' >> "$css"
            printf '  100%% { border-color: rgba(0,229,255,0.50); box-shadow: 0 0  8px rgba(0,229,255,0.20); }\n' >> "$css"
            printf '}\n' >> "$css"
        fi
        printf '%s:hover {\n' "$SEL_CARD" >> "$css"
        printf '  animation: border-glow-rotate 3s linear infinite !important;\n}\n' >> "$css"
        printf '/* === END GLOW_BORDER === */\n' >> "$css"
        success "粒子发光边框已注入"
    fi

    # ── 特效C：毛玻璃按钮统一风格 ───────────────────────────
    if ask "启用毛玻璃按钮风格（全局按钮半透明化）"; then
        _remove_css_block "GLASS_BUTTON"
        local css="$ACTIVE_CSS"
        local DK="$GLASS_DARKEN"
        printf '\n/* === GLASS_BUTTON theme=%s === */\n' "$ACTIVE_THEME" >> "$css"
        # 通用按钮基础样式（不破坏彩色 primary/danger 按钮的背景色）
        printf 'button, .btn, .cbi-button,\n' >> "$css"
        printf 'input[type="button"], input[type="submit"],\n' >> "$css"
        printf 'input[type="reset"], .cbi-button-action {\n' >> "$css"
        printf '  backdrop-filter: blur(4px) brightness(%s) !important;\n' "$DK" >> "$css"
        printf '  -webkit-backdrop-filter: blur(4px) brightness(%s) !important;\n' "$DK" >> "$css"
        printf '  border-radius: 8px !important;\n' >> "$css"
        printf '  transition: all 0.25s ease !important;\n}\n' >> "$css"
        # 中性按钮（无彩色背景类）透明玻璃化
        printf 'button:not([class*="btn-"]):not([class*="btn btn-"]),\n' >> "$css"
        printf '.cbi-button-neutral, .cbi-button-reset {\n' >> "$css"
        printf '  background: rgba(255,255,255,0.10) !important;\n' >> "$css"
        printf '  border: 1px solid rgba(255,255,255,0.35) !important;\n' >> "$css"
        printf '  color: #ffffff !important;\n}\n' >> "$css"
        printf 'button:not([class*="btn-"]):hover {\n' >> "$css"
        printf '  background: rgba(255,255,255,0.20) !important;\n' >> "$css"
        printf '  box-shadow: 0 0 12px rgba(255,255,255,0.20) !important;\n}\n' >> "$css"
        printf '/* === END GLASS_BUTTON === */\n' >> "$css"
        success "毛玻璃按钮风格已注入"
    fi

    # ── 特效D：页面切换淡入动画 ─────────────────────────────
    if ask "启用页面元素淡入动画（每次加载时卡片从下方淡入）"; then
        _remove_css_block "FADE_IN"
        local css="$ACTIVE_CSS"
        printf '\n/* === FADE_IN theme=%s === */\n' "$ACTIVE_THEME" >> "$css"
        # 分组延迟，营造层叠效果
        printf '%s:nth-child(1)  { animation-delay: 0.00s !important; }\n' "$SEL_CARD" >> "$css"
        printf '%s:nth-child(2)  { animation-delay: 0.05s !important; }\n' "$SEL_CARD" >> "$css"
        printf '%s:nth-child(3)  { animation-delay: 0.10s !important; }\n' "$SEL_CARD" >> "$css"
        printf '%s:nth-child(4)  { animation-delay: 0.15s !important; }\n' "$SEL_CARD" >> "$css"
        printf '%s:nth-child(5)  { animation-delay: 0.20s !important; }\n' "$SEL_CARD" >> "$css"
        printf '%s:nth-child(n+6){ animation-delay: 0.25s !important; }\n' "$SEL_CARD" >> "$css"
        # 侧边菜单项淡入
        printf '%s li {\n' "$SEL_SIDEBAR" >> "$css"
        printf '  animation: page-fade-in 0.35s ease both;\n}\n' >> "$css"
        printf '%s li:nth-child(1)  { animation-delay: 0.00s; }\n' "$SEL_SIDEBAR" >> "$css"
        printf '%s li:nth-child(2)  { animation-delay: 0.04s; }\n' "$SEL_SIDEBAR" >> "$css"
        printf '%s li:nth-child(3)  { animation-delay: 0.08s; }\n' "$SEL_SIDEBAR" >> "$css"
        printf '%s li:nth-child(4)  { animation-delay: 0.12s; }\n' "$SEL_SIDEBAR" >> "$css"
        printf '%s li:nth-child(n+5){ animation-delay: 0.16s; }\n' "$SEL_SIDEBAR" >> "$css"
        printf '/* === END FADE_IN === */\n' >> "$css"
        success "淡入动画已注入"
    fi

    # ── 特效E：顶部进度条风格线 ─────────────────────────────
    if ask "启用顶部彩虹装饰线（header顶部细彩线）"; then
        _remove_css_block "TOP_LINE"
        local css="$ACTIVE_CSS"
        printf '\n/* === TOP_LINE theme=%s === */\n' "$ACTIVE_THEME" >> "$css"
        printf '%s {\n' "$SEL_HEADER" >> "$css"
        printf '  border-top: 2px solid transparent !important;\n' >> "$css"
        printf '  border-image: linear-gradient(\n' >> "$css"
        printf '    90deg,\n' >> "$css"
        printf '    #00e5ff, #2979ff, #aa00ff, #ec4899, #ff6b35, #00e5ff\n' >> "$css"
        printf '  ) 1 !important;\n}\n' >> "$css"
        printf '/* === END TOP_LINE === */\n' >> "$css"
        success "顶部彩虹装饰线已注入"
    fi

    success "额外特效配置完成"
}

# ================================================================
#  备份/恢复
# ================================================================
do_backup() {
    local ts; ts=$(date '+%Y%m%d_%H%M%S' 2>/dev/null || echo "bak")
    if [ ! -f "${ACTIVE_CSS}.bak" ]; then
        cp "$ACTIVE_CSS" "${ACTIVE_CSS}.bak"; success "原始备份: ${ACTIVE_CSS}.bak"
    fi
    cp "$ACTIVE_CSS" "${ACTIVE_CSS}.${ts}" 2>/dev/null && \
        success "时间戳备份: ${ACTIVE_CSS}.${ts}"
    [ -n "$HEADER_HTM" ] && [ ! -f "${HEADER_HTM}.bak" ] && \
        cp "$HEADER_HTM" "${HEADER_HTM}.bak" && success "header.htm 已备份"
    [ -n "$SYSAUTH" ] && [ ! -f "${SYSAUTH}.bak" ] && \
        cp "$SYSAUTH" "${SYSAUTH}.bak" && success "sysauth 已备份"
}

do_restore() {
    title "恢复备份 [$ACTIVE_THEME]"
    info "可用备份文件："
    local has_bak=0
    [ -f "${ACTIVE_CSS}.bak" ] && printf "    %s\n" "${ACTIVE_CSS}.bak" && has_bak=1
    local f
    for f in "${ACTIVE_CSS}".20*; do
        [ -f "$f" ] && printf "    %s\n" "$f" && has_bak=1
    done
    if [ "$has_bak" -eq 0 ]; then warn "未找到任何备份文件"; return; fi
    echo ""
    echo "  ${CYAN}1)${NC} 从 .bak 原始备份恢复"
    echo "  ${CYAN}2)${NC} 从指定时间戳备份恢复"
    echo "  ${CYAN}3)${NC} 取消"
    printf "${YELLOW}  [>]  选择恢复方式 [1-3, 默认1]: ${NC}"
    read _rc
    [ -z "$_rc" ] && _rc=1
    case "$_rc" in *[!0-9]*) _rc=1 ;; esac
    [ "$_rc" -lt 1 ] 2>/dev/null && _rc=1
    [ "$_rc" -gt 3 ] 2>/dev/null && _rc=1
    case "$_rc" in
        1) [ -f "${ACTIVE_CSS}.bak" ] && \
               { cp "${ACTIVE_CSS}.bak" "$ACTIVE_CSS"; success "已从 .bak 恢复 CSS"; } || \
               warn "未找到 .bak 备份" ;;
        2) printf "${YELLOW}  [>]  粘贴备份文件完整路径: ${NC}"; read _bak_path
           [ -f "$_bak_path" ] && \
               { cp "$_bak_path" "$ACTIVE_CSS"; success "已从 $_bak_path 恢复 CSS"; } || \
               warn "文件不存在: $_bak_path" ;;
        3) info "取消恢复"; return ;;
    esac
    [ -n "$HEADER_HTM" ] && [ -f "${HEADER_HTM}.bak" ] && \
        cp "${HEADER_HTM}.bak" "$HEADER_HTM" && success "header.htm 已恢复"
    [ -n "$SYSAUTH" ] && [ -f "${SYSAUTH}.bak" ] && \
        cp "${SYSAUTH}.bak" "$SYSAUTH" && success "sysauth 已恢复"
    rm -rf /tmp/luci-* 2>/dev/null && success "LuCI 缓存已清除"
    info "请在浏览器按 Ctrl+Shift+R 强制刷新"
}

# ================================================================
#  状态显示
# ================================================================
show_status() {
    title "当前美化状态 [$ACTIVE_THEME]"
    local css="$ACTIVE_CSS"
    printf "  ${WHITE}%-30s %s${NC}\n" "功能" "状态"
    printf "  %s\n" "------------------------------------------------------"

    _stat() {
        local label="$1" tag="$2" extra="$3"
        if grep -q "$tag" "$css" 2>/dev/null; then
            printf "  %-30s ${GREEN}%s${NC}\n" "$label" "已启用${extra}"
        else
            printf "  %-30s ${YELLOW}%s${NC}\n" "$label" "未启用"
        fi
    }

    if grep -q "GLASSMORPHISM" "$css" 2>/dev/null; then
        local dk; dk=$(grep "GLASSMORPHISM theme=" "$css" 2>/dev/null | head -1 | \
            sed 's/.*darken=//;s/ .*//' | tr -d '*/')
        printf "  %-30s ${GREEN}%s${NC}\n" "自适应毛玻璃 v2.0" "已启用 (压暗=${dk:-?})"
    else
        printf "  %-30s ${YELLOW}%s${NC}\n" "自适应毛玻璃 v2.0" "未启用"
    fi

    _stat "动画关键帧" "KEYFRAMES_ALL" ""

    if grep -q "BRAND_ANIMATION" "$css" 2>/dev/null; then
        local md; md=$(grep "BRAND_ANIMATION mode=" "$css" 2>/dev/null | head -1 | \
            sed 's/.*mode=//;s/ .*//' | tr -d '*/')
        printf "  %-30s ${GREEN}%s${NC}\n" "Brand动画" "模式${md:-?}/8"
    else
        printf "  %-30s ${YELLOW}%s${NC}\n" "Brand动画" "未启用"
    fi

    if grep -q "FONT_FACE" "$css" 2>/dev/null; then
        local fn; fn=$(grep "FONT_FACE_" "$css" 2>/dev/null | head -1 | \
            sed 's/.*FONT_FACE_//;s/ ==.*//')
        printf "  %-30s ${GREEN}%s${NC}\n" "字体" "$fn"
    else
        printf "  %-30s ${WHITE}%s${NC}\n" "字体" "系统默认"
    fi

    _stat "文字颜色优化 v2.0" "TEXT_COLOR" ""
    _stat "登录框位置" "LOGIN_POSITION" ""
    _stat "扫描线特效" "SCANLINE" ""
    _stat "粒子发光边框" "GLOW_BORDER" ""
    _stat "毛玻璃按钮" "GLASS_BUTTON" ""
    _stat "淡入动画" "FADE_IN" ""
    _stat "顶部彩虹线" "TOP_LINE" ""

    echo ""
    [ -f "$ACTIVE_BG" ] && info "背景图: 存在 ($(du -sh "$ACTIVE_BG" | cut -f1))" || \
        warn "背景图: 未找到 ($ACTIVE_BG)"
    info "CSS: $(wc -l < "$css" 2>/dev/null) 行 | $(du -sh "$css" 2>/dev/null | cut -f1)"
    info "主题底色识别: $THEME_BASE_COLOR"
    echo ""; info "可用备份:"
    [ -f "${ACTIVE_CSS}.bak" ] && printf "    %s\n" "${ACTIVE_CSS}.bak"
    for f in "${ACTIVE_CSS}".20*; do [ -f "$f" ] && printf "    %s\n" "$f"; done
}

do_flush() { rm -rf /tmp/luci-* 2>/dev/null; success "LuCI 缓存已清除"; }

# ================================================================
#  主菜单
# ================================================================
main_menu() {
    while true; do
        echo ""
        echo "${CYAN}+--------------------------------------------------+${NC}"
        printf "${CYAN}|${NC}  ${WHITE}LuCI Theme Beauty Tool v2.0 [%-14s]${NC}${CYAN}|${NC}\n" \
            "$ACTIVE_THEME"
        printf "${CYAN}|${NC}  ${YELLOW}底色: %-8s${NC}                               ${CYAN}|${NC}\n" \
            "$THEME_BASE_COLOR"
        echo "${CYAN}+--------------------------------------------------+${NC}"
        echo "${CYAN}|${NC} ${WHITE}1${NC}) [全程] 一键智能全流程美化 (推荐新手)         ${CYAN}|${NC}"
        echo "${CYAN}|${NC} ${WHITE}2${NC}) [状态] 查看当前美化状态                       ${CYAN}|${NC}"
        echo "${CYAN}|${NC} ${WHITE}0${NC}) [检测] 联网检测所有内置URL可用性              ${CYAN}|${NC}"
        echo "${CYAN}|${NC} ${WHITE}T${NC}) [主题] 切换目标主题                           ${CYAN}|${NC}"
        echo "${CYAN}+--------------------------------------------------+${NC}"
        echo "${CYAN}|${NC} ${WHITE}3${NC}) [背景] 下载/更换背景图                        ${CYAN}|${NC}"
        echo "${CYAN}|${NC} ${WHITE}4${NC}) [字体] 获取/更换字体                          ${CYAN}|${NC}"
        echo "${CYAN}|${NC} ${WHITE}5${NC}) [动画] Brand 动画效果 (8种)                   ${CYAN}|${NC}"
        echo "${CYAN}|${NC} ${WHITE}6${NC}) [切换] 切换动画模式(不重设颜色)               ${CYAN}|${NC}"
        echo "${CYAN}|${NC} ${WHITE}7${NC}) [玻璃] 自适应毛玻璃 v2.0                      ${CYAN}|${NC}"
        echo "${CYAN}|${NC} ${WHITE}8${NC}) [文字] 文字颜色优化 v2.0                      ${CYAN}|${NC}"
        echo "${CYAN}|${NC} ${WHITE}9${NC}) [位置] 登录框位置                             ${CYAN}|${NC}"
        echo "${CYAN}|${NC} ${WHITE}a${NC}) [清理] 清理页面元素                           ${CYAN}|${NC}"
        echo "${CYAN}|${NC} ${WHITE}e${NC}) [特效] 额外特效（扫描线/发光边框/淡入等）     ${CYAN}|${NC}"
        echo "${CYAN}+--------------------------------------------------+${NC}"
        echo "${CYAN}|${NC} ${WHITE}r${NC}) [恢复] 恢复原版(含时间戳备份选择)             ${CYAN}|${NC}"
        echo "${CYAN}|${NC} ${WHITE}f${NC}) [缓存] 清除LuCI缓存                           ${CYAN}|${NC}"
        echo "${CYAN}|${NC} ${WHITE}q${NC}) [退出] 退出程序                               ${CYAN}|${NC}"
        echo "${CYAN}+--------------------------------------------------+${NC}"
        printf "${YELLOW}  请选择: ${NC}"; read choice
        case "$choice" in
            1)
                title "开始智能全流程美化 v2.0 [$ACTIVE_THEME]"
                step_download_image
                step_download_font
                step_brand_animation
                step_glassmorphism
                step_text
                step_login_position
                step_clean
                step_extra_effects
                do_flush
                echo ""
                echo "${GREEN}+----------------------------------------------+${NC}"
                echo "${GREEN}|  [完成] 全部步骤执行完毕！                   |${NC}"
                echo "${GREEN}|  浏览器按 Ctrl+Shift+R 强制刷新即可         |${NC}"
                echo "${GREEN}+----------------------------------------------+${NC}"
                ;;
            2)  show_status ;;
            0)  step_check_urls ;;
            T|t) detect_themes; detect_paths; do_backup ;;
            3)  step_download_image;   do_flush ;;
            4)  step_download_font;    do_flush ;;
            5)  step_brand_animation;  do_flush ;;
            6)  step_switch_animation; do_flush ;;
            7)  step_glassmorphism;    do_flush ;;
            8)  step_text;             do_flush ;;
            9)  step_login_position;   do_flush ;;
            a)  step_clean;            do_flush ;;
            e)  step_extra_effects;    do_flush ;;
            r)  do_restore ;;
            f)  do_flush ;;
            q)  echo "${GREEN}  再见！${NC}"; exit 0 ;;
            *)  warn "无效选项，请重新选择" ;;
        esac
    done
}

# ================================================================
#  入口
# ================================================================
printf "${CYAN}"
printf '  +====================================================+\n'
printf '  |   LuCI Theme Beauty Tool  v2.0                   |\n'
printf '  |   新增：8种动画 / 智能底色检测 / 全面修复        |\n'
printf '  |   修复：checkbox / 中间层 / 标题条 / 图表        |\n'
printf '  |   新增：扫描线 / 发光边框 / 淡入 / 响应式        |\n'
printf '  +====================================================+\n'
printf "${NC}\n"

detect_themes
detect_paths
do_backup
main_menu
