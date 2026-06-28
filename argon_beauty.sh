#!/bin/sh
# ============================================================
#  LuCI 主题智能美化工具 v1.1
#  核心升级：backdrop-filter brightness 自适应暗化
#           无论背景图深浅，卡片内文字始终可读
#           用户无需判断色调，全自动适配
# ============================================================

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
        0.*|1.0|1) printf '%s\n' "$_f_val" ;;
        *) printf "${YELLOW}  [!]  格式不合法，使用默认: %s${NC}\n" "$def" >&2
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
        [ -n "$line" ] && cnt=$((cnt+1))
    done < "$1"
    printf '%s\n' "$cnt"
}

# ============================================================
#  图片 API 库
# ============================================================
IMG_API_LIST="yppp自适应|https://api.yppp.net/api.php|横竖自适应二次元(推荐)
yppp横屏PC|https://api.yppp.net/pc.php|横屏壁纸
yppp竖屏手机|https://api.yppp.net/pe.php|竖屏壁纸
樱花ACG|https://www.dmoe.cc/random.php|随机二次元
小歪二次元|https://api.ixiaowai.cn/api/api.php|二次元动漫
小歪高清壁纸|https://api.ixiaowai.cn/gqapi/gqapi.php|高清壁纸
搏天动漫|https://api.btstu.cn/sjbz/api.php?lx=dongman|随机动漫壁纸
搏天随机|https://api.btstu.cn/sjbz/api.php|随机壁纸
UAPIs二次元|https://uapis.cn/api/img/acg|免费随机动漫(国内CDN)
南风自适应|https://api.sretna.cn/api/anime.php|自动横竖适配
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
自定义|custom"

# ============================================================
#  全局变量
# ============================================================
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
# 毛玻璃参数（现在只剩模糊度和边框，亮度由 backdrop-filter 自动处理）
GLASS_BLUR="12"
GLASS_BORDER="rgba(255,255,255,0.15)"
# 背景压暗强度（0.0=全黑 ~ 1.0=不压暗，默认0.35）
GLASS_DARKEN="0.35"

# ============================================================
#  加载主题变量
# ============================================================
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

# ============================================================
#  主题探测
# ============================================================
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
        rm -f "$tmplist"
        error "未发现任何 LuCI 主题"; exit 1
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
}

# ============================================================
#  路径探测
# ============================================================
detect_paths() {
    title "自动探测系统环境"
    HEADER_HTM=$(find /usr/lib/lua /usr/share/ucode \
        -name "header.htm" 2>/dev/null | grep "$ACTIVE_THEME" | head -1)
    SYSAUTH=$(find /usr/lib/lua /usr/share/ucode \
        -name "sysauth*" 2>/dev/null | grep "$ACTIVE_THEME" | head -1)
    FOOTER=$(find /usr/lib/lua /usr/share/ucode \
        -name "footer*" 2>/dev/null | grep "$ACTIVE_THEME" | head -1)
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
}

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

step_check_urls() {
    title "联网检查所有内置 URL 可用性"
    [ -z "$NET_TOOL" ] && warn "无网络工具，跳过" && return
    printf "\n  ${WHITE}%-24s %-10s %s${NC}\n" "图片 API" "状态" "说明"
    printf "  %s\n" "----------------------------------------------------"
    local tmpf="/tmp/_chk_api_$$"
    printf '%s\n' "$IMG_API_LIST" > "$tmpf"
    while IFS='|' read -r name url desc; do
        [ -z "$name" ] && continue
        [ "$url" = "custom" ] && continue
        printf "  %-24s " "$name"
        if check_url "$url" 8; then printf "${GREEN}[  OK  ]${NC}  %s\n" "$desc"
        else printf "${RED}[ FAIL ]${NC}  %s\n" "$desc"; fi
    done < "$tmpf"
    rm -f "$tmpf"
    printf "\n  ${WHITE}%-28s %s${NC}\n" "字体 CDN" "状态"
    printf "  %s\n" "------------------------------------------"
    local tmpf2="/tmp/_chk_fnt_$$"
    printf '%s\n' "$FONT_LIST" > "$tmpf2"
    while IFS='|' read -r name cssname w2 w1; do
        [ -z "$name" ] && continue
        [ "$w2" = "local" ] || [ "$w2" = "none" ] && continue
        printf "  %-28s " "$name"
        if check_url "$w2" 10; then printf "${GREEN}[  OK  ]${NC}\n"
        else printf "${RED}[ FAIL ]${NC}\n"; fi
    done < "$tmpf2"
    rm -f "$tmpf2"
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
    done < "$tmpf"
    rm -f "$tmpf"
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

# ============================================================
#  图片验证（hexdump优先，od次之，大小兜底）
# ============================================================
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

# ============================================================
#  CSS 块删除（纯 shell 逐行）
# ============================================================
_remove_css_block() {
    local tag="$1" css="$ACTIVE_CSS" tmpout="/tmp/_css_rm_$$"
    grep -q "=== ${tag}" "$css" 2>/dev/null || return 0
    local in_block=0
    while IFS= read -r line; do
        case "$line" in
            *"=== ${tag} "*|*"=== ${tag}="*) in_block=1 ;;
            *"=== END ${tag} ==="*)          in_block=0 ;;
            *) [ "$in_block" -eq 0 ] && printf '%s\n' "$line" ;;
        esac
    done < "$css" > "$tmpout"
    if [ -s "$tmpout" ]; then
        mv "$tmpout" "$css"; info "已移除旧 [${tag}] 块"
    else
        rm -f "$tmpout"; warn "移除 [${tag}] 块失败，已跳过"
    fi
}

# ============================================================
#  步骤1：背景图片获取（简化色调问题：改用亮度自适应，无需问色调）
# ============================================================
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
            local sel_line; sel_line=$(awk -v n="$api_num" 'NR==n{print;exit}' "$tmpf2")
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

# ============================================================
#  步骤2：字体
# ============================================================
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
    [ "$FONT_WOFF2_URL" = "none" ] || [ -z "$FONT_WOFF2_URL" ] && \
        { info "系统字体，跳过 @font-face"; return; }
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

# ============================================================
#  步骤3：Brand 动画
# ============================================================
step_brand_animation() {
    title "步骤3：Brand 名称动画效果 [$ACTIVE_THEME]"
    ask "是否启用品牌名动画效果" || return
    echo ""; echo "  ${WHITE}动画模式：${NC}"
    echo "  ${CYAN}1)${NC} 色相持续旋转  颜色本身循环变化 ${GREEN}[推荐]${NC}"
    echo "  ${CYAN}2)${NC} 极光流动      多色渐变横向流过"
    echo "  ${CYAN}3)${NC} 彩虹脉冲发光  颜色变化+外发光"
    echo "  ${CYAN}4)${NC} 霓虹闪烁      明暗交替赛博朋克"
    echo "  ${CYAN}5)${NC} 左右平移      渐变色块平移"
    local anim_mode; anim_mode=$(ask_num "选择动画模式" 1 1 5)
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
    printf '/* === END KEYFRAMES_ALL === */\n' >> "$css"
    success "所有动画关键帧已注入"
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
    esac
    local css="$ACTIVE_CSS"
    printf '\n/* === BRAND_ANIMATION mode=%s filter=%s === */\n' "$mode" "$use_filter" >> "$css"
    # 侧边栏
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
    printf '  animation: %s;\n}\n' "$brand_anim" >> "$css"
    # 登录页
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
    printf '  animation: %s;\n}\n' "$brand_anim" >> "$css"
    printf '/* === END BRAND_ANIMATION === */\n' >> "$css"
    success "Brand 动画注入完成 [模式${mode}: $GRAD_NAME | ${speed}s]"
}

step_switch_animation() {
    title "切换 Brand 动画模式"
    if ! grep -q "=== BRAND_ANIMATION" "$ACTIVE_CSS" 2>/dev/null; then
        warn "尚未启用 Brand 动画，请先通过步骤3设置"; return
    fi
    echo "  ${CYAN}1)${NC} 色相持续旋转 ${GREEN}[推荐]${NC}"; echo "  ${CYAN}2)${NC} 极光流动"
    echo "  ${CYAN}3)${NC} 彩虹脉冲发光"; echo "  ${CYAN}4)${NC} 霓虹闪烁"; echo "  ${CYAN}5)${NC} 左右平移"
    local new_mode; new_mode=$(ask_num "选择新模式" 1 1 5)
    local new_speed; new_speed=$(ask_num "动画速度(秒)" 4 1 30)
    local cur_colors
    cur_colors=$(grep "background: linear-gradient" "$ACTIVE_CSS" 2>/dev/null | \
        head -1 | sed 's/.*linear-gradient([^,]*,//;s/).*//' | tr -d ' ')
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

# ============================================================
#  步骤4：毛玻璃效果（v1.1核心：backdrop-filter brightness 自适应）
#
#  原理：
#    backdrop-filter: brightness(X) 对卡片背后的图像压暗
#    X=0.35 → 压暗到35%亮度，无论原图多亮，叠加后都是深色
#    白色文字在任意背景上始终清晰可读
#    用户不再需要手动选择"深色/浅色/彩色"方案
#
#  对比旧方案：
#    旧: background: rgba(8,12,20, 0.65) → 深色背景可以，浅色壁纸发灰
#    新: backdrop-filter: brightness(0.35) → 直接压暗背后图像，任意壁纸均适用
# ============================================================
step_glassmorphism() {
    title "步骤4：自适应毛玻璃效果 [$ACTIVE_THEME]"
    info "v1.1 智能模式：通过 backdrop-filter brightness 自动压暗背景"
    info "无论壁纸是浅色动漫还是深色星空，文字始终清晰可读"
    ask "是否启用毛玻璃效果" || return

    echo ""
    echo "  ${WHITE}压暗强度选择（影响卡片后方图像的暗化程度）：${NC}"
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
        else
            info "跳过"; return
        fi
    fi

    local css="$ACTIVE_CSS"
    local BL="$GLASS_BLUR"
    local DK="$GLASS_DARKEN"
    local BR="$GLASS_BORDER"
    local BGPATH="$THEME_BG_WEBPATH"

    printf '\n/* === GLASSMORPHISM theme=%s darken=%s blur=%s === */\n' \
        "$ACTIVE_THEME" "$DK" "$BL" >> "$css"

    # ---- 背景图 ----
    printf 'html, body {\n' >> "$css"
    printf "  background: url('%s') center center / cover fixed no-repeat !important;\n" \
        "$BGPATH" >> "$css"
    printf '  background-color: #0a0f1a !important;\n}\n' >> "$css"

    # ---- 内容主区域：给极淡的暗色打底，防止完全透明 ----
    printf '%s {\n' "$SEL_CONTENT" >> "$css"
    printf '  background: rgba(0,0,0,0.10) !important;\n' >> "$css"
    printf '  backdrop-filter: none !important;\n' >> "$css"
    printf '  -webkit-backdrop-filter: none !important;\n}\n' >> "$css"

    # ---- 侧边栏：backdrop-filter 自适应压暗 ----
    printf '%s {\n' "$SEL_SIDEBAR" >> "$css"
    printf '  background: rgba(0,0,0,0.20) !important;\n' >> "$css"
    printf '  backdrop-filter: brightness(%s) blur(%spx) saturate(160%%) !important;\n' \
        "$DK" "$BL" >> "$css"
    printf '  -webkit-backdrop-filter: brightness(%s) blur(%spx) saturate(160%%) !important;\n' \
        "$DK" "$BL" >> "$css"
    printf '  border-right: 1px solid %s !important;\n}\n' "$BR" >> "$css"

    # ---- 顶部导航栏 ----
    printf '%s {\n' "$SEL_HEADER" >> "$css"
    printf '  background: rgba(0,0,0,0.15) !important;\n' >> "$css"
    printf '  background-color: rgba(0,0,0,0.15) !important;\n' >> "$css"
    printf '  backdrop-filter: brightness(%s) blur(18px) saturate(180%%) !important;\n' \
        "$DK" >> "$css"
    printf '  -webkit-backdrop-filter: brightness(%s) blur(18px) saturate(180%%) !important;\n' \
        "$DK" >> "$css"
    printf '  border-bottom: 1px solid %s !important;\n' "$BR" >> "$css"
    printf '  box-shadow: 0 2px 16px rgba(0,0,0,0.40) !important;\n}\n' >> "$css"

    # ---- 内容卡片：核心 ----
    # backdrop-filter brightness 压暗背后图像 + 轻量黑色底色
    # 无论壁纸多亮，压暗后配白字始终清晰
    printf '%s {\n' "$SEL_CARD" >> "$css"
    printf '  background: rgba(0,0,0,0.15) !important;\n' >> "$css"
    printf '  backdrop-filter: brightness(%s) blur(%spx) saturate(140%%) !important;\n' \
        "$DK" "$BL" >> "$css"
    printf '  -webkit-backdrop-filter: brightness(%s) blur(%spx) saturate(140%%) !important;\n' \
        "$DK" "$BL" >> "$css"
    printf '  border: 1px solid %s !important;\n' "$BR" >> "$css"
    printf '  border-radius: 12px !important;\n' >> "$css"
    printf '  box-shadow: 0 4px 24px rgba(0,0,0,0.35) !important;\n}\n' >> "$css"

    # ---- 表格 ----
    printf 'table, .table { background: transparent !important; }\n' >> "$css"
    printf 'thead {\n' >> "$css"
    printf '  background: rgba(0,0,0,0.30) !important;\n' >> "$css"
    printf '  backdrop-filter: brightness(%s) !important;\n' "$DK" >> "$css"
    printf '  -webkit-backdrop-filter: brightness(%s) !important;\n}\n' "$DK" >> "$css"
    printf 'tbody tr { background: rgba(0,0,0,0.15) !important; }\n' >> "$css"
    printf 'tbody tr:hover td { background: rgba(255,255,255,0.08) !important; }\n' >> "$css"
    printf 'td, th { border-color: %s !important; background: transparent !important; }\n' \
        "$BR" >> "$css"
    printf '.network-status-table, .ifacebox, .ifacebox-body {\n' >> "$css"
    printf '  background: rgba(0,0,0,0.25) !important;\n' >> "$css"
    printf '  backdrop-filter: brightness(%s) !important;\n' "$DK" >> "$css"
    printf '  -webkit-backdrop-filter: brightness(%s) !important;\n' "$DK" >> "$css"
    printf '  border-color: %s !important;\n}\n' "$BR" >> "$css"

    # ---- 输入框 ----
    printf 'input[type="text"], input[type="password"],\n' >> "$css"
    printf 'input[type="number"], select, textarea, .form-control {\n' >> "$css"
    printf '  background: rgba(255,255,255,0.10) !important;\n' >> "$css"
    printf '  border: 1px solid rgba(255,255,255,0.25) !important;\n' >> "$css"
    printf '  backdrop-filter: blur(4px) !important;\n' >> "$css"
    printf '  border-radius: 8px !important; color: #ffffff !important;\n}\n' >> "$css"
    printf 'input:focus, select:focus, textarea:focus {\n' >> "$css"
    printf '  border-color: rgba(49,161,161,0.80) !important;\n' >> "$css"
    printf '  box-shadow: 0 0 0 2px rgba(49,161,161,0.25) !important;\n' >> "$css"
    printf '  outline: none !important;\n}\n' >> "$css"

    # ---- 菜单激活项 ----
    printf '.sidenav-menu .nav-item.active > a,\n' >> "$css"
    printf '.nav-pills .nav-link.active, #menu .active > a {\n' >> "$css"
    printf '  background: linear-gradient(90deg,\n' >> "$css"
    printf '    rgba(0,180,180,0.50), rgba(0,100,200,0.40)) !important;\n' >> "$css"
    printf '  border-left: 3px solid #00fff7 !important;\n' >> "$css"
    printf '  border-radius: 0 8px 8px 0 !important;\n}\n' >> "$css"

    # ---- 登录框 ----
    printf '%s {\n' "$SEL_LOGIN" >> "$css"
    printf '  background: rgba(0,0,0,0.20) !important;\n' >> "$css"
    printf '  backdrop-filter: brightness(%s) blur(22px) saturate(160%%) !important;\n' \
        "$DK" >> "$css"
    printf '  -webkit-backdrop-filter: brightness(%s) blur(22px) saturate(160%%) !important;\n' \
        "$DK" >> "$css"
    printf '  border: 1px solid %s !important;\n' "$BR" >> "$css"
    printf '  border-radius: 18px !important;\n' >> "$css"
    printf '  box-shadow: 0 8px 40px rgba(0,0,0,0.50) !important;\n}\n' >> "$css"

    # ---- 登录按钮 ----
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
    printf '  cursor: pointer; transition: all 0.25s ease;\n' >> "$css"
    printf '  color: #ffffff !important;\n}\n' >> "$css"
    printf '%s .cbi-button-apply:hover,\n' "$SEL_LOGIN" >> "$css"
    printf '%s input[type="submit"]:hover,\n' "$SEL_LOGIN" >> "$css"
    printf '%s button[type="submit"]:hover {\n' "$SEL_LOGIN" >> "$css"
    printf '  background: rgba(255,255,255,0.18) !important;\n' >> "$css"
    printf '  box-shadow: 0 0 0 2px rgba(255,255,255,0.50) !important;\n}\n' >> "$css"

    # ---- 弹窗/模态框：也用 backdrop-filter brightness 压暗 ----
    printf '.modal-content, .modal-dialog, .modal .card,\n' >> "$css"
    printf '[role="dialog"], [role="dialog"] .card,\n' >> "$css"
    printf '.dialog, .popup, .luci-popup, .cbi-modal, .cbi-popup {\n' >> "$css"
    printf '  background: rgba(0,0,0,0.15) !important;\n' >> "$css"
    printf '  backdrop-filter: brightness(%s) blur(20px) saturate(150%%) !important;\n' \
        "$DK" >> "$css"
    printf '  -webkit-backdrop-filter: brightness(%s) blur(20px) saturate(150%%) !important;\n' \
        "$DK" >> "$css"
    printf '  border: 1px solid %s !important;\n' "$BR" >> "$css"
    printf '  border-radius: 14px !important;\n' >> "$css"
    printf '  box-shadow: 0 12px 48px rgba(0,0,0,0.60) !important;\n}\n' >> "$css"
    # 弹窗内输入框
    printf '.modal-content input, .modal-content select, .modal-content textarea,\n' >> "$css"
    printf '[role="dialog"] input, [role="dialog"] select, [role="dialog"] textarea,\n' >> "$css"
    printf '.cbi-modal input, .cbi-modal select, .cbi-modal textarea {\n' >> "$css"
    printf '  background: rgba(255,255,255,0.12) !important;\n' >> "$css"
    printf '  border: 1px solid rgba(255,255,255,0.25) !important;\n' >> "$css"
    printf '  border-radius: 6px !important;\n}\n' >> "$css"
    # 遮罩层
    printf '.modal-backdrop { background: rgba(0,0,0,0.65) !important; }\n' >> "$css"

    # ---- 提示框 ----
    printf '.alert, .notice, .cbi-map-descr, .warning {\n' >> "$css"
    printf '  background: rgba(0,0,0,0.40) !important;\n' >> "$css"
    printf '  backdrop-filter: brightness(%s) !important;\n' "$DK" >> "$css"
    printf '  -webkit-backdrop-filter: brightness(%s) !important;\n' "$DK" >> "$css"
    printf '  border: 1px solid %s !important;\n' "$BR" >> "$css"
    printf '  border-radius: 8px !important;\n}\n' >> "$css"

    printf '/* === END GLASSMORPHISM === */\n' >> "$css"
    success "自适应毛玻璃注入完成（压暗: ${DK}，模糊: ${BL}px）"
    info "提示：浅色壁纸建议压暗0.20~0.35；深色壁纸建议0.40~0.50"
}

# ============================================================
#  步骤5：文字颜色（v1.1：白色文字+强阴影，配合 brightness 压暗）
# ============================================================
step_text() {
    title "步骤5：文字颜色优化 [$ACTIVE_THEME]"
    ask "是否优化文字颜色与可读性" || return
    if grep -q "=== TEXT_COLOR ===" "$ACTIVE_CSS" 2>/dev/null; then
        if ask "文字样式已存在，是否重新注入"; then
            _remove_css_block "TEXT_COLOR"
        else info "跳过"; return; fi
    fi
    local css="$ACTIVE_CSS"
    # v1.1：文字统一白色 + 强阴影，配合 backdrop brightness 压暗后背景始终深色
    printf '\n/* === TEXT_COLOR theme=%s === */\n' "$ACTIVE_THEME" >> "$css"
    printf 'body, p, li, span, label,\n' >> "$css"
    printf '.cbi-value-title, .cbi-value-field, td, th {\n' >> "$css"
    printf '  color: #ffffff !important;\n' >> "$css"
    printf '  text-shadow: 0 1px 4px rgba(0,0,0,0.90) !important;\n}\n' >> "$css"
    printf 'h1, h2, h3, h4, h5, h6, legend {\n' >> "$css"
    printf '  color: #ffffff !important;\n' >> "$css"
    printf '  text-shadow: 0 1px 6px rgba(0,0,0,0.90) !important;\n}\n' >> "$css"
    printf '.text-muted, small {\n' >> "$css"
    printf '  color: rgba(255,255,255,0.75) !important;\n' >> "$css"
    printf '  text-shadow: 0 1px 3px rgba(0,0,0,0.90) !important;\n}\n' >> "$css"
    printf '%s a, %s span {\n' "$SEL_SIDEBAR" "$SEL_SIDEBAR" >> "$css"
    printf '  color: #ffffff !important;\n' >> "$css"
    printf '  text-shadow: 0 1px 4px rgba(0,0,0,0.90) !important;\n}\n' >> "$css"
    printf '%s * {\n' "$SEL_HEADER" >> "$css"
    printf '  color: #ffffff !important;\n' >> "$css"
    printf '  text-shadow: 0 1px 4px rgba(0,0,0,0.90) !important;\n}\n' >> "$css"
    # 弹窗内文字也白色（backdrop-filter 已经压暗背景）
    printf '.modal-content *, [role="dialog"] *,\n' >> "$css"
    printf '.cbi-modal *, .cbi-popup *, .dialog *, .popup * {\n' >> "$css"
    printf '  color: #ffffff !important;\n' >> "$css"
    printf '  text-shadow: 0 1px 3px rgba(0,0,0,0.80) !important;\n}\n' >> "$css"
    printf 'a { color: #7ecfff !important; }\n' >> "$css"
    printf 'a:hover { color: #00fff7 !important; }\n' >> "$css"
    printf 'a:active { color: #dddddd !important; }\n' >> "$css"
    printf 'input, select, textarea, .form-control {\n' >> "$css"
    printf '  text-shadow: none !important; color: #ffffff !important;\n}\n' >> "$css"
    printf '/* === END TEXT_COLOR === */\n' >> "$css"
    success "文字颜色注入完成（白色 + 强阴影，配合亮度自适应）"
}

# ============================================================
#  步骤6：登录框位置
# ============================================================
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
    printf '%s { margin: 0 !important; transform: none !important;\n' "$SEL_LOGIN" >> "$css"
    printf '  position: relative !important;\n}\n' >> "$css"
    printf '/* === END LOGIN_POSITION === */\n' >> "$css"
    success "登录框位置已设置 (${justify})"
}

# ============================================================
#  步骤7：清理
# ============================================================
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

# ============================================================
#  备份
# ============================================================
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

# ============================================================
#  恢复
# ============================================================
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

show_status() {
    title "当前美化状态 [$ACTIVE_THEME]"
    local css="$ACTIVE_CSS"
    printf "  ${WHITE}%-28s %s${NC}\n" "功能" "状态"
    printf "  %s\n" "----------------------------------------------------"
    if grep -q "GLASSMORPHISM" "$css" 2>/dev/null; then
        local dk; dk=$(grep "GLASSMORPHISM theme=" "$css" 2>/dev/null | head -1 | \
            sed 's/.*darken=//;s/ .*//' | tr -d '*/')
        printf "  %-28s ${GREEN}%s${NC}\n" "自适应毛玻璃" "已启用 (压暗=${dk:-?})"
    else
        printf "  %-28s ${YELLOW}%s${NC}\n" "自适应毛玻璃" "未启用"
    fi
    grep -q "KEYFRAMES_ALL" "$css" 2>/dev/null && \
        printf "  %-28s ${GREEN}%s${NC}\n" "动画关键帧" "已注入" || \
        printf "  %-28s ${YELLOW}%s${NC}\n" "动画关键帧" "未注入"
    if grep -q "BRAND_ANIMATION" "$css" 2>/dev/null; then
        local md; md=$(grep "BRAND_ANIMATION mode=" "$css" 2>/dev/null | head -1 | \
            sed 's/.*mode=//;s/ .*//' | tr -d '*/')
        printf "  %-28s ${GREEN}%s${NC}\n" "Brand动画" "模式${md:-?}"
    else
        printf "  %-28s ${YELLOW}%s${NC}\n" "Brand动画" "未启用"
    fi
    if grep -q "FONT_FACE" "$css" 2>/dev/null; then
        local fn; fn=$(grep "FONT_FACE_" "$css" 2>/dev/null | head -1 | \
            sed 's/.*FONT_FACE_//;s/ ==.*//')
        printf "  %-28s ${GREEN}%s${NC}\n" "字体" "$fn"
    else
        printf "  %-28s ${WHITE}%s${NC}\n" "字体" "系统默认"
    fi
    grep -q "TEXT_COLOR" "$css" 2>/dev/null && \
        printf "  %-28s ${GREEN}%s${NC}\n" "文字优化" "已启用（白色+强阴影）" || \
        printf "  %-28s ${YELLOW}%s${NC}\n" "文字优化" "未启用"
    grep -q "LOGIN_POSITION" "$css" 2>/dev/null && \
        printf "  %-28s ${GREEN}%s${NC}\n" "登录框位置" "已自定义" || \
        printf "  %-28s ${WHITE}%s${NC}\n" "登录框位置" "默认居中"
    echo ""
    [ -f "$ACTIVE_BG" ] && info "背景图: 存在 ($(du -sh "$ACTIVE_BG" | cut -f1))" || \
        warn "背景图: 未找到 ($ACTIVE_BG)"
    [ -f "${ACTIVE_FONTS_DIR}/TypoGraphica.woff2" ] && \
        info "TypoGraphica.woff2: 存在" || info "TypoGraphica.woff2: 无"
    info "CSS: $(wc -l < "$css") 行 | $(du -sh "$css" | cut -f1)"
    echo ""; info "可用备份:"
    [ -f "${ACTIVE_CSS}.bak" ] && printf "    %s\n" "${ACTIVE_CSS}.bak"
    for f in "${ACTIVE_CSS}".20*; do [ -f "$f" ] && printf "    %s\n" "$f"; done
}

do_flush() { rm -rf /tmp/luci-* 2>/dev/null; success "LuCI 缓存已清除"; }

# ============================================================
#  主菜单
# ============================================================
main_menu() {
    while true; do
        echo ""
        echo "${CYAN}+------------------------------------------------+${NC}"
        printf "${CYAN}|${NC}  ${WHITE}LuCI Theme Beauty Tool v1.1  [%-14s]${NC}${CYAN}|${NC}\n" \
            "$ACTIVE_THEME"
        echo "${CYAN}+------------------------------------------------+${NC}"
        echo "${CYAN}|${NC} ${WHITE}1${NC}) [全程] 一键智能全流程美化 (推荐新手)       ${CYAN}|${NC}"
        echo "${CYAN}|${NC} ${WHITE}2${NC}) [状态] 查看当前美化状态                     ${CYAN}|${NC}"
        echo "${CYAN}|${NC} ${WHITE}0${NC}) [检测] 联网检测所有内置URL可用性            ${CYAN}|${NC}"
        echo "${CYAN}|${NC} ${WHITE}T${NC}) [主题] 切换目标主题                         ${CYAN}|${NC}"
        echo "${CYAN}+------------------------------------------------+${NC}"
        echo "${CYAN}|${NC} ${WHITE}3${NC}) [背景] 下载/更换背景图                      ${CYAN}|${NC}"
        echo "${CYAN}|${NC} ${WHITE}4${NC}) [字体] 获取/更换字体                        ${CYAN}|${NC}"
        echo "${CYAN}|${NC} ${WHITE}5${NC}) [动画] Brand 动画效果                       ${CYAN}|${NC}"
        echo "${CYAN}|${NC} ${WHITE}6${NC}) [切换] 切换动画模式(不重设颜色)             ${CYAN}|${NC}"
        echo "${CYAN}|${NC} ${WHITE}7${NC}) [玻璃] 自适应毛玻璃                         ${CYAN}|${NC}"
        echo "${CYAN}|${NC} ${WHITE}8${NC}) [文字] 文字颜色优化                         ${CYAN}|${NC}"
        echo "${CYAN}|${NC} ${WHITE}9${NC}) [位置] 登录框位置                           ${CYAN}|${NC}"
        echo "${CYAN}|${NC} ${WHITE}a${NC}) [清理] 清理页面元素                         ${CYAN}|${NC}"
        echo "${CYAN}+------------------------------------------------+${NC}"
        echo "${CYAN}|${NC} ${WHITE}r${NC}) [恢复] 恢复原版(含时间戳备份选择)           ${CYAN}|${NC}"
        echo "${CYAN}|${NC} ${WHITE}f${NC}) [缓存] 清除LuCI缓存                         ${CYAN}|${NC}"
        echo "${CYAN}|${NC} ${WHITE}q${NC}) [退出] 退出程序                             ${CYAN}|${NC}"
        echo "${CYAN}+------------------------------------------------+${NC}"
        printf "${YELLOW}  请选择: ${NC}"; read choice
        case "$choice" in
            1)
                title "开始智能全流程美化 [$ACTIVE_THEME]"
                step_download_image
                step_download_font
                step_brand_animation
                step_glassmorphism
                step_text
                step_login_position
                step_clean
                do_flush
                echo ""
                echo "${GREEN}+--------------------------------------------+${NC}"
                echo "${GREEN}|  [完成] 全部步骤执行完毕！                 |${NC}"
                echo "${GREEN}|  浏览器按 Ctrl+Shift+R 强制刷新即可       |${NC}"
                echo "${GREEN}+--------------------------------------------+${NC}"
                ;;
            2)  show_status ;;
            0)  step_check_urls ;;
            T|t) detect_themes; detect_paths; do_backup ;;
            3)  step_download_image;                    do_flush ;;
            4)  step_download_font;                     do_flush ;;
            5)  step_brand_animation;                   do_flush ;;
            6)  step_switch_animation;                  do_flush ;;
            7)  step_glassmorphism;                     do_flush ;;
            8)  step_text;                              do_flush ;;
            9)  step_login_position;                    do_flush ;;
            a)  step_clean;                             do_flush ;;
            r)  do_restore ;;
            f)  do_flush ;;
            q)  echo "${GREEN}  再见！${NC}"; exit 0 ;;
            *)  warn "无效选项，请重新选择" ;;
        esac
    done
}

# ============================================================
#  程序入口
# ============================================================
printf "${CYAN}"
printf '  +==================================================+\n'
printf '  |  LuCI Theme Beauty Tool v1.1                    |\n'
printf '  |  自适应亮度 / 任意壁纸可读 / Busybox兼容        |\n'
printf '  +==================================================+\n'
printf "${NC}\n"

detect_themes
detect_paths
do_backup
main_menu
