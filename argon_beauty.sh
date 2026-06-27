#!/bin/sh

# ============ 颜色输出（兼容 busybox ash）============
ESC=$(printf '\033')
RED="${ESC}[0;31m"
GREEN="${ESC}[0;32m"
YELLOW="${ESC}[1;33m"
BLUE="${ESC}[0;34m"
CYAN="${ESC}[0;36m"
WHITE="${ESC}[1;37m"
NC="${ESC}[0m"

info()    { printf "${CYAN}  i  %s${NC}\n" "$1"; }
success() { printf "${GREEN}  v  %s${NC}\n" "$1"; }
warn()    { printf "${YELLOW}  !  %s${NC}\n" "$1"; }
error()   { printf "${RED}  x  %s${NC}\n" "$1"; }
title()   {
    printf "\n${WHITE}"
    printf '=%.0s' 1 2 3 4 5 6 7 8 9 10 \
                   11 12 13 14 15 16 17 18 19 20 \
                   21 22 23 24 25 26 27 28 29 30 \
                   31 32 33 34 35 36 37 38 39 40 \
                   41 42 43 44 45 46 47 48 49 50
    printf "\n  %s\n" "$1"
    printf '=%.0s' 1 2 3 4 5 6 7 8 9 10 \
                   11 12 13 14 15 16 17 18 19 20 \
                   21 22 23 24 25 26 27 28 29 30 \
                   31 32 33 34 35 36 37 38 39 40 \
                   41 42 43 44 45 46 47 48 49 50
    printf "${NC}\n"
}
ask() {
    printf "${YELLOW}  >  %s [y/N]: ${NC}" "$1"
    read _a
    echo "$_a" | grep -qi "^y"
}
askd() {
    printf "${YELLOW}  >  %s [默认:%s]: ${NC}" "$1" "$2"
    read _d
    [ -z "$_d" ] && _d="$2"
    echo "$_d"
}

# ============ 图片 API 库 ============
IMG_API_LIST="
yppp二次元|https://api.yppp.net/api.php|横竖自适应二次元(推荐)
yppp横屏|https://api.yppp.net/pc.php|横屏壁纸
yppp竖屏|https://api.yppp.net/pe.php|竖屏壁纸
樱花ACG|https://www.dmoe.cc/random.php|随机二次元
小歪二次元|https://api.ixiaowai.cn/api/api.php|二次元动漫
小歪高清壁纸|https://api.ixiaowai.cn/gqapi/gqapi.php|高清壁纸
搏天API|https://api.btstu.cn/sjbz/api.php|随机壁纸
必应每日|https://bing.img.run/1920x1080.php|必应每日壁纸
随机风景|https://picsum.photos/1920/1080|Lorem Picsum风景
自定义|custom|输入自己的图片API地址
"

# ============ 字体库 ============
FONT_LIST="
TypoGraphica(本地已有)|TypoGraphica|local|local
阿里妈妈数黑体|AlimamaShuHeiTi|https://at.alicdn.com/wf/webfont/kfq1sgJFWQ6g/cPCrTL8ewntCCMPMNgo40.woff2|https://at.alicdn.com/wf/webfont/kfq1sgJFWQ6g/fu9Q_dW8qzsGtfSSU60a3.woff
阿里妈妈东方大楷|AlimamaDFDaKai|https://at.alicdn.com/wf/webfont/kfq1sgJFWQ6g/Vilu-bh7P5eQjO8r8act3.woff2|https://at.alicdn.com/wf/webfont/kfq1sgJFWQ6g/IXc_dDK4CjiHaiUgrlZL5.woff
系统默认字体|system-ui|none|none
"

# ============ 渐变色方案库 ============
GRADIENT_LIST="
青蓝极光(默认)|#00e5ff,#2979ff,#aa00ff,#00e5ff
金橙日落|#ff6b35,#f7931e,#ffcd3c,#ff6b35
紫霞幻境|#a855f7,#6366f1,#ec4899,#a855f7
翠绿春意|#00b894,#00cec9,#55efc4,#00b894
玫红炫彩|#fd79a8,#e84393,#ff7675,#fd79a8
赛博朋克|#00fff7,#ff00ff,#ffff00,#00fff7
自定义|custom
"

# ============ 动画模式库 ============
# 格式: 名称|keyframe名|说明|适合场景
ANIM_MODE_LIST="
色相持续旋转(图片同款)|hue-rotate-flow|颜色本身不断变化青蓝紫循环|深色背景推荐
极光流动|aurora-flow|多色渐变横向丝滑流动|彩色背景推荐
彩虹脉冲发光|rainbow-pulse|颜色变化+发光呼吸感|动漫背景推荐
霓虹闪烁|neon-flicker|明暗交替+色相变化|赛博朋克风格
左右平移(旧版)|shine|渐变色块左右平移|所有场景通用
"

# ============ 路径变量 ============
ARGON_CSS="/www/luci-static/argon/css/cascade.css"
ARGON_FONTS="/www/luci-static/argon/fonts"
ARGON_IMG="/www/luci-static/argon/img"
ARGON_BG="${ARGON_IMG}/bg1.jpg"

# ============ 路径探测 ============
detect_paths() {
    title "🔍 自动探测系统环境"

    [ ! -f "$ARGON_CSS" ] && \
        error "未找到 cascade.css，请先安装 luci-theme-argon" && exit 1
    success "CSS: $ARGON_CSS"

    HEADER_HTM=$(find /usr/lib/lua /usr/share/ucode \
        -name "header.htm" 2>/dev/null | grep argon | head -1)
    SYSAUTH=$(find /usr/lib/lua /usr/share/ucode \
        -name "sysauth*" 2>/dev/null | grep argon | head -1)
    FOOTER=$(find /usr/lib/lua /usr/share/ucode \
        -name "footer*" 2>/dev/null | grep argon | head -1)

    [ -n "$HEADER_HTM" ] && success "Header : $HEADER_HTM" \
        || warn "header.htm 未找到"
    [ -n "$SYSAUTH"    ] && success "Sysauth: $SYSAUTH" \
        || warn "sysauth 未找到"
    [ -n "$FOOTER"     ] && success "Footer : $FOOTER" \
        || warn "footer 未找到"

    # 检测网络工具
    NET_TOOL=""
    if command -v curl >/dev/null 2>&1; then
        NET_TOOL="curl"; success "网络工具: curl"
    elif command -v wget >/dev/null 2>&1; then
        NET_TOOL="wget"; success "网络工具: wget"
    else
        warn "未找到 curl/wget，无法在线下载资源"
    fi

    ROUTER_IP=$(uci get network.lan.ipaddr 2>/dev/null || echo "192.168.1.1")
    info "路由器IP: $ROUTER_IP"
}

# ============ URL 联网校验 ============
# 返回 0=可用 1=不可用
check_url() {
    local url="$1" timeout="${2:-8}"
    [ -z "$NET_TOOL" ] && return 1
    if [ "$NET_TOOL" = "curl" ]; then
        curl -sSL --connect-timeout "$timeout" --max-time "$timeout" \
             -A "Mozilla/5.0" -o /dev/null -w "%{http_code}" "$url" \
             2>/dev/null | grep -qE "^[23]"
    else
        wget -q --timeout="$timeout" -U "Mozilla/5.0" \
             --spider "$url" 2>/dev/null
    fi
}

# 批量检测所有内置 API 和字体 URL 是否可用
step_check_urls() {
    title "🌐 联网检查所有内置 URL 可用性"
    [ -z "$NET_TOOL" ] && warn "无网络工具，跳过检查" && return

    echo ""
    echo "  ${WHITE}── 图片 API 检测 ──${NC}"
    echo "$IMG_API_LIST" | grep -v '^$' | while IFS='|' read name url desc; do
        [ "$url" = "custom" ] && continue
        printf "  %-20s " "$name"
        if check_url "$url" 8; then
            echo "${GREEN}✓ 可用${NC}"
        else
            echo "${RED}✗ 不可用${NC}"
        fi
    done

    echo ""
    echo "  ${WHITE}── 字体 CDN 检测 ──${NC}"
    echo "$FONT_LIST" | grep -v '^$' | while IFS='|' read name cssname w2 w1; do
        [ "$w2" = "local" ] || [ "$w2" = "none" ] && continue
        printf "  %-25s woff2: " "$name"
        if check_url "$w2" 10; then
            echo "${GREEN}✓ 可用${NC}"
        else
            echo "${RED}✗ 不可用${NC}"
        fi
    done

    echo ""
    success "检测完成，不可用的源请改用其他选项"
}

# ============ 带可用性标记的 API 列表展示 ============
show_api_list_with_status() {
    echo "  ${WHITE}可用图片 API 列表：${NC}"
    local i=1
    echo "$IMG_API_LIST" | grep -v '^$' | while IFS='|' read name url desc; do
        if [ "$url" = "custom" ]; then
            printf "  ${CYAN}%2d)${NC} %-18s ${YELLOW}[自定义]${NC}  %s\n" \
                "$i" "$name" "$desc"
        else
            # 快速检测（3秒超时）
            printf "  ${CYAN}%2d)${NC} %-18s " "$i" "$name"
            if check_url "$url" 3; then
                printf "${GREEN}[✓]${NC}  %s\n" "$desc"
            else
                printf "${RED}[✗]${NC}  %s\n" "$desc"
            fi
        fi
        i=$((i+1))
    done
}

# ============ 网络下载工具 ============
net_download() {
    local url="$1" dest="$2" desc="${3:-文件}"
    info "正在下载 $desc ..."
    info "来源: $url"

    if [ "$NET_TOOL" = "curl" ]; then
        curl -sSL --connect-timeout 15 --max-time 60 \
             -A "Mozilla/5.0" -L "$url" -o "$dest"
    elif [ "$NET_TOOL" = "wget" ]; then
        wget -q --timeout=60 -U "Mozilla/5.0" "$url" -O "$dest"
    else
        error "无网络工具，跳过下载"; return 1
    fi

    if [ -f "$dest" ] && [ -s "$dest" ]; then
        local size=$(du -sh "$dest" 2>/dev/null | cut -f1)
        success "$desc 下载成功（大小: $size）"
        chmod 644 "$dest"
        return 0
    else
        error "$desc 下载失败"
        rm -f "$dest" 2>/dev/null
        return 1
    fi
}

# ============ 图片格式验证 ============
verify_image() {
    local file="$1"
    [ ! -f "$file" ] && return 1
    local magic=$(dd if="$file" bs=1 count=4 2>/dev/null | \
                  od -A n -t x1 | tr -d ' \n')
    echo "$magic" | grep -qiE "^ffd8ff|^89504e47|^52494646|^webp" && return 0
    # 次级判断：文件大小 > 10KB 认为是有效图片
    local size=$(wc -c < "$file" 2>/dev/null || echo 0)
    [ "$size" -gt 10240 ] && return 0
    return 1
}

# ============ 智能色调分析 ============
analyze_bg_and_suggest() {
    title "🎨 智能色调分析"

    if [ ! -f "$ARGON_BG" ]; then
        warn "未找到背景图，使用默认深色方案"
        SUGGEST_TEXT_COLOR="#ffffff"; SUGGEST_SHADOW="rgba(0,0,0,0.80)"
        SUGGEST_GLASS_ALPHA="0.35";  SUGGEST_GLASS_DARK="0.50"
        SUGGEST_BLUR="8"; SUGGEST_BORDER="rgba(255,255,255,0.09)"
        SUGGEST_SCHEME="colorful"; return
    fi

    local size_kb=$(( $(wc -c < "$ARGON_BG" 2>/dev/null || echo 0) / 1024 ))
    info "背景图大小: ${size_kb}KB"
    echo ""
    echo "  请描述背景图整体色调（影响毛玻璃和文字配色）："
    echo "  ${CYAN}1)${NC} 🌙 深色/暗色调  深蓝、深紫、黑色系"
    echo "  ${CYAN}2)${NC} ☀️  浅色/亮色调  白色、米黄、浅蓝系"
    echo "  ${CYAN}3)${NC} 🌅 中等/彩色调  动漫插画、风景、人物 ${GREEN}[默认]${NC}"
    echo "  ${CYAN}4)${NC} 🌸 粉嫩/低饱和  粉色、渐变、梦幻系"
    printf "${YELLOW}  ➤  请选择 [1-4，默认3]: ${NC}"; read tone

    case "$tone" in
        1) SUGGEST_TEXT_COLOR="#ffffff"; SUGGEST_SHADOW="rgba(0,0,0,0.60)"
           SUGGEST_GLASS_ALPHA="0.25";  SUGGEST_GLASS_DARK="0.40"
           SUGGEST_BLUR="10"; SUGGEST_BORDER="rgba(255,255,255,0.12)"
           SUGGEST_SCHEME="dark"
           success "深色方案 → 白字 + 轻量毛玻璃" ;;
        2) SUGGEST_TEXT_COLOR="#1a1a2e"; SUGGEST_SHADOW="rgba(200,200,255,0.4)"
           SUGGEST_GLASS_ALPHA="0.55";  SUGGEST_GLASS_DARK="0.65"
           SUGGEST_BLUR="16"; SUGGEST_BORDER="rgba(0,0,0,0.10)"
           SUGGEST_SCHEME="light"
           success "浅色方案 → 深字 + 较深毛玻璃遮罩" ;;
        4) SUGGEST_TEXT_COLOR="#ffffff"; SUGGEST_SHADOW="rgba(120,0,80,0.50)"
           SUGGEST_GLASS_ALPHA="0.30";  SUGGEST_GLASS_DARK="0.45"
           SUGGEST_BLUR="14"; SUGGEST_BORDER="rgba(255,200,220,0.20)"
           SUGGEST_SCHEME="pink"
           success "粉嫩方案 → 白字 + 粉色边框毛玻璃" ;;
        *) SUGGEST_TEXT_COLOR="#ffffff"; SUGGEST_SHADOW="rgba(0,0,0,0.80)"
           SUGGEST_GLASS_ALPHA="0.35";  SUGGEST_GLASS_DARK="0.50"
           SUGGEST_BLUR="8"; SUGGEST_BORDER="rgba(255,255,255,0.09)"
           SUGGEST_SCHEME="colorful"
           success "彩色方案 → 白字 + 强阴影 + 半透明毛玻璃" ;;
    esac

    echo ""
    ask "是否手动微调毛玻璃透明度（推荐值: ${SUGGEST_GLASS_ALPHA}）" && {
        printf "${YELLOW}  ➤  卡片透明度 [0.10最透明 ~ 0.70最不透明]: ${NC}"
        read custom_alpha
        echo "$custom_alpha" | grep -qE '^0\.[0-9]+$' && \
            SUGGEST_GLASS_ALPHA="$custom_alpha" && \
            success "透明度已设为 $custom_alpha"
    }
}

# ============ 步骤1：背景图 ============
step_download_image() {
    title "🖼️  步骤1：背景图片获取"
    echo "  ${CYAN}1)${NC} 🌐 从内置API在线下载（自动检测可用性）"
    echo "  ${CYAN}2)${NC} 📁 已手动上传，直接使用"
    echo "  ${CYAN}3)${NC} 🔗 输入自定义图片直链"
    echo "  ${CYAN}4)${NC} ⏭  跳过"
    printf "${YELLOW}  ➤  请选择 [1-4]: ${NC}"; read img_choice

    case "$img_choice" in
        1)
            echo ""
            info "正在检测各API可用性，请稍候..."
            show_api_list_with_status
            echo ""
            printf "${YELLOW}  ➤  选择API编号 [默认1]: ${NC}"; read api_num
            [ -z "$api_num" ] && api_num=1

            sel_line=$(echo "$IMG_API_LIST" | grep -v '^$' | sed -n "${api_num}p")
            sel_name=$(echo "$sel_line" | cut -d'|' -f1)
            sel_url=$(echo "$sel_line"  | cut -d'|' -f2)

            [ "$sel_url" = "custom" ] && {
                printf "${YELLOW}  ➤  请输入自定义API地址: ${NC}"; read sel_url
            }
            info "使用: $sel_name → $sel_url"

            # 先验证URL是否可达
            if ! check_url "$sel_url" 10; then
                warn "该API当前不可达，是否仍然尝试下载？"
                ask "继续尝试" || return
            fi

            # 解析重定向后的真实图片地址
            local real_url="$sel_url"
            if [ "$NET_TOOL" = "curl" ]; then
                info "解析最终图片地址..."
                local resolved
                resolved=$(curl -sSL --connect-timeout 10 --max-time 20 \
                    -A "Mozilla/5.0" -w "%{url_effective}" \
                    -o /dev/null -L "$sel_url" 2>/dev/null)
                echo "$resolved" | grep -qiE "\.(jpg|jpeg|png|webp)(\?.*)?$" && \
                    real_url="$resolved" && info "真实地址: $real_url"
            fi

            net_download "$real_url" "$ARGON_BG" "背景图"

            if verify_image "$ARGON_BG"; then
                success "图片格式验证通过 ✓"
            else
                warn "图片格式验证未通过，但仍会尝试使用"
                warn "如显示异常请手动上传正确的 jpg/png 图片"
            fi
            ;;
        2)
            if [ -f "$ARGON_BG" ]; then
                success "已有背景图 ($(du -sh $ARGON_BG | cut -f1))"
                verify_image "$ARGON_BG" && success "格式验证通过" || \
                    warn "图片格式异常，建议重新上传"
            else
                warn "未找到 $ARGON_BG"
                info "Windows上传命令:"
                echo "    scp bg1.jpg root@${ROUTER_IP}:${ARGON_BG}"
            fi
            ;;
        3)
            printf "${YELLOW}  ➤  图片直链URL: ${NC}"; read direct_url
            [ -n "$direct_url" ] && {
                check_url "$direct_url" 8 || warn "URL不可达，仍尝试下载..."
                net_download "$direct_url" "$ARGON_BG" "自定义背景图"
                verify_image "$ARGON_BG" && success "格式验证通过"
            }
            ;;
        4) info "已跳过图片设置"; BG_SKIP=1 ;;
    esac
}

# ============ 步骤2：字体获取 ============
step_download_font() {
    title "🔤 步骤2：品牌字体获取"

    if [ -f "$ARGON_FONTS/TypoGraphica.woff2" ]; then
        success "检测到本地 TypoGraphica.woff2"
        ask "已有本地字体，是否更换" || {
            FONT_NAME="TypoGraphica"
            FONT_WOFF2_URL="/luci-static/argon/fonts/TypoGraphica.woff2"
            FONT_WOFF_URL="/luci-static/argon/fonts/TypoGraphica.woff"
            inject_font_css; return
        }
    fi

    echo ""
    echo "  字体选择（自动检测CDN可用性）："
    local i=1
    echo "$FONT_LIST" | grep -v '^$' | while IFS='|' read name cssname w2 w1; do
        printf "  ${CYAN}%2d)${NC} %-28s" "$i" "$name"
        if [ "$w2" = "local" ]; then
            printf "${GREEN}[本地]${NC}\n"
        elif [ "$w2" = "none" ]; then
            printf "${WHITE}[系统]${NC}\n"
        else
            check_url "$w2" 5 && \
                printf "${GREEN}[CDN✓]${NC}\n" || \
                printf "${RED}[CDN✗]${NC}\n"
        fi
        i=$((i+1))
    done

    echo ""
    printf "${YELLOW}  ➤  选择字体编号 [默认1]: ${NC}"; read font_num
    [ -z "$font_num" ] && font_num=1

    sel_line=$(echo "$FONT_LIST" | grep -v '^$' | sed -n "${font_num}p")
    FONT_DISP=$(echo "$sel_line"    | cut -d'|' -f1)
    FONT_NAME=$(echo "$sel_line"    | cut -d'|' -f2)
    FONT_WOFF2_URL=$(echo "$sel_line" | cut -d'|' -f3)
    FONT_WOFF_URL=$(echo "$sel_line"  | cut -d'|' -f4)

    info "已选: $FONT_DISP"

    if [ "$FONT_WOFF2_URL" != "local" ] && [ "$FONT_WOFF2_URL" != "none" ]; then
        ask "下载字体到路由器本地（推荐，加载更快）" && {
            # 下载前再次验证URL
            if check_url "$FONT_WOFF2_URL" 8; then
                net_download "$FONT_WOFF2_URL" \
                    "$ARGON_FONTS/${FONT_NAME}.woff2" "${FONT_NAME} woff2"
                net_download "$FONT_WOFF_URL" \
                    "$ARGON_FONTS/${FONT_NAME}.woff"  "${FONT_NAME} woff"
                FONT_WOFF2_URL="/luci-static/argon/fonts/${FONT_NAME}.woff2"
                FONT_WOFF_URL="/luci-static/argon/fonts/${FONT_NAME}.woff"
            else
                warn "CDN地址不可达，将使用在线CDN链接"
            fi
        } || info "将直接引用 CDN 地址"
    elif [ "$FONT_WOFF2_URL" = "local" ]; then
        FONT_WOFF2_URL="/luci-static/argon/fonts/TypoGraphica.woff2"
        FONT_WOFF_URL="/luci-static/argon/fonts/TypoGraphica.woff"
    fi

    inject_font_css
}

inject_font_css() {
    if ! grep -q "FONT_FACE_${FONT_NAME}" "$ARGON_CSS" 2>/dev/null; then
        [ "$FONT_WOFF2_URL" = "none" ] || [ -z "$FONT_WOFF2_URL" ] && \
            { info "系统字体，跳过 @font-face"; return; }
        cat >> "$ARGON_CSS" << EOF

/* === FONT_FACE_${FONT_NAME} === */
@font-face {
  font-family: "${FONT_NAME}";
  src: url('${FONT_WOFF2_URL}') format('woff2'),
       url('${FONT_WOFF_URL}')  format('woff');
  font-weight: normal;
  font-style: normal;
  font-display: swap;
}
/* === END FONT_FACE_${FONT_NAME} === */
EOF
        success "@font-face 已注入: $FONT_NAME"
    else
        info "字体声明已存在，跳过"
    fi
}

# ============ 步骤3：Brand 动画模式选择 ============
step_brand_animation() {
    title "✨ 步骤3：Brand 名称动画效果"
    ask "是否启用品牌名（路由器名称）动画效果" || return

    echo ""
    echo "  ${WHITE}动画模式选择：${NC}"
    echo "  ${CYAN}1)${NC} 🌈 色相持续旋转  颜色本身不断循环变化 ${GREEN}[图片同款 推荐]${NC}"
    echo "  ${CYAN}2)${NC} 🌌 极光流动      多色渐变横向丝滑流过"
    echo "  ${CYAN}3)${NC} 💫 彩虹脉冲发光  颜色变化+外发光呼吸感"
    echo "  ${CYAN}4)${NC} ⚡ 霓虹闪烁      明暗交替+色相变化 赛博朋克风"
    echo "  ${CYAN}5)${NC} ➡️  左右平移      渐变色块左右平移（旧版）"
    echo ""
    printf "${YELLOW}  ➤  选择动画模式 [1-5，默认1]: ${NC}"; read anim_mode
    [ -z "$anim_mode" ] && anim_mode=1

    # 渐变色选择
    echo ""
    echo "  ${WHITE}渐变色方案：${NC}"
    local i=1
    echo "$GRADIENT_LIST" | grep -v '^$' | while IFS='|' read name colors; do
        printf "  ${CYAN}%d)${NC} %-18s ${BLUE}%s${NC}\n" "$i" "$name" "$colors"
        i=$((i+1))
    done
    echo ""
    printf "${YELLOW}  ➤  选择渐变色 [默认1]: ${NC}"; read grad_num
    [ -z "$grad_num" ] && grad_num=1

    sel_line=$(echo "$GRADIENT_LIST" | grep -v '^$' | sed -n "${grad_num}p")
    GRAD_NAME=$(echo "$sel_line"   | cut -d'|' -f1)
    GRAD_COLORS=$(echo "$sel_line" | cut -d'|' -f2)

    [ "$GRAD_COLORS" = "custom" ] && {
        info "格式示例: #00fff7,#007cf0,#ff4ecd,#00fff7"
        printf "${YELLOW}  ➤  输入颜色(逗号分隔): ${NC}"; read GRAD_COLORS
    }

    printf "${YELLOW}  ➤  动画速度(秒，越小越快，默认4): ${NC}"; read anim_speed
    [ -z "$anim_speed" ] && anim_speed=4

    [ -z "$FONT_NAME" ] && FONT_NAME="TypoGraphica"

    info "模式: $anim_mode | 配色: $GRAD_NAME | 速度: ${anim_speed}s"

    # 注入所有关键帧（全部注入，按模式选择使用哪个）
    if ! grep -q "=== KEYFRAMES_ALL ===" "$ARGON_CSS"; then
        cat >> "$ARGON_CSS" << 'KEYEOF'

/* === KEYFRAMES_ALL === */

/* 色相旋转 */
@keyframes hue-rotate-flow {
  0%   { filter: hue-rotate(0deg)   brightness(1.2); }
  25%  { filter: hue-rotate(90deg)  brightness(1.3); }
  50%  { filter: hue-rotate(180deg) brightness(1.2); }
  75%  { filter: hue-rotate(270deg) brightness(1.3); }
  100% { filter: hue-rotate(360deg) brightness(1.2); }
}

/* 极光流动 */
@keyframes aurora-flow {
  0%   { background-position: 0%   50%; }
  50%  { background-position: 100% 50%; }
  100% { background-position: 0%   50%; }
}

/* 彩虹脉冲发光 */
@keyframes rainbow-pulse {
  0%   { filter: hue-rotate(0deg)   drop-shadow(0 0 6px  #00fff7); }
  20%  { filter: hue-rotate(72deg)  drop-shadow(0 0 14px #007cf0); }
  40%  { filter: hue-rotate(144deg) drop-shadow(0 0 6px  #ff4ecd); }
  60%  { filter: hue-rotate(216deg) drop-shadow(0 0 14px #a855f7); }
  80%  { filter: hue-rotate(288deg) drop-shadow(0 0 6px  #00fff7); }
  100% { filter: hue-rotate(360deg) drop-shadow(0 0 6px  #00fff7); }
}

/* 霓虹闪烁 */
@keyframes neon-flicker {
  0%,100%{ opacity:1;    filter: hue-rotate(0deg)   brightness(1.4)
                         drop-shadow(0 0 10px #00fff7); }
  15%    { opacity:0.82; filter: hue-rotate(30deg)  brightness(1.1); }
  30%    { opacity:1;    filter: hue-rotate(90deg)  brightness(1.5)
                         drop-shadow(0 0 20px #007cf0); }
  50%    { opacity:0.9;  filter: hue-rotate(180deg) brightness(1.3)
                         drop-shadow(0 0 15px #ff4ecd); }
  70%    { opacity:1;    filter: hue-rotate(270deg) brightness(1.4)
                         drop-shadow(0 0 20px #a855f7); }
  85%    { opacity:0.82; filter: hue-rotate(330deg) brightness(1.1); }
}

/* 左右平移 */
@keyframes shine {
  0%   { background-position: -200% center; }
  100% { background-position:  200% center; }
}

/* === END KEYFRAMES_ALL === */
KEYEOF
        success "所有动画关键帧已注入"
    else
        info "关键帧已存在，跳过"
    fi

    # 根据模式生成不同的 Brand CSS
    local brand_anim
    local login_anim
    local use_filter=0   # 是否用 filter 方式（色相旋转类）
    local bg_size="300% 300%"

    case "$anim_mode" in
        1)  # 色相旋转 —— filter 方式，颜色本身变化
            brand_anim="hue-rotate-flow ${anim_speed}s linear infinite"
            login_anim="hue-rotate-flow ${anim_speed}s linear infinite"
            use_filter=1
            bg_size="200% 200%"
            ;;
        2)  # 极光流动
            brand_anim="aurora-flow ${anim_speed}s ease infinite"
            login_anim="aurora-flow ${anim_speed}s ease infinite"
            bg_size="400% 400%"
            ;;
        3)  # 彩虹脉冲发光 —— filter 方式
            brand_anim="rainbow-pulse ${anim_speed}s linear infinite"
            login_anim="rainbow-pulse ${anim_speed}s linear infinite"
            use_filter=1
            bg_size="200% 200%"
            ;;
        4)  # 霓虹闪烁 —— filter 方式
            brand_anim="neon-flicker ${anim_speed}s ease-in-out infinite"
            login_anim="neon-flicker ${anim_speed}s ease-in-out infinite"
            use_filter=1
            bg_size="200% 200%"
            ;;
        5)  # 左右平移
            brand_anim="shine ${anim_speed}s linear infinite"
            login_anim="shine ${anim_speed}s linear infinite"
            bg_size="300% 300%"
            ;;
    esac

    # 删除旧的 Brand 动画块（如存在）避免重复
    if grep -q "=== BRAND_ANIMATION ===" "$ARGON_CSS"; then
        # 用 awk 删除旧块
        awk '/\/\* === BRAND_ANIMATION ===/,/\/\* === END BRAND_ANIMATION ===/{ next }1' \
            "$ARGON_CSS" > /tmp/argon_css_tmp && mv /tmp/argon_css_tmp "$ARGON_CSS"
        info "已移除旧动画块，重新写入"
    fi

    if [ "$use_filter" = "1" ]; then
        # filter 模式：用纯色 + filter hue-rotate 实现颜色变化
        cat >> "$ARGON_CSS" << EOF

/* === BRAND_ANIMATION === */

/* 侧边栏 Brand —— filter色相旋转模式 */
.main-left .sidenav-header .brand {
  display: block; margin: 0; font-size: 1.8rem;
  font-family: "${FONT_NAME}", sans-serif;
  text-decoration: none; text-align: center; cursor: default;
  background: linear-gradient(135deg, ${GRAD_COLORS});
  background-size: ${bg_size};
  -webkit-background-clip: text;
  background-clip: text;
  -webkit-text-fill-color: transparent;
  animation: ${brand_anim};
}

/* 登录页 Brand —— filter色相旋转模式 */
.login-page .login-container .login-form .brand .brand-text {
  font-size: 2.6rem; font-weight: 400; word-break: break-word;
  font-family: "${FONT_NAME}", sans-serif;
  background: linear-gradient(135deg, ${GRAD_COLORS});
  background-size: ${bg_size};
  -webkit-background-clip: text;
  background-clip: text;
  -webkit-text-fill-color: transparent;
  animation: ${login_anim};
}
/* === END BRAND_ANIMATION === */
EOF
    else
        # background-position 流动模式
        cat >> "$ARGON_CSS" << EOF

/* === BRAND_ANIMATION === */

/* 侧边栏 Brand —— 渐变流动模式 */
.main-left .sidenav-header .brand {
  display: block; margin: 0; font-size: 1.8rem;
  font-family: "${FONT_NAME}", sans-serif;
  text-decoration: none; text-align: center; cursor: default;
  background: linear-gradient(90deg, ${GRAD_COLORS},
    $(echo "$GRAD_COLORS" | cut -d',' -f1));
  background-size: ${bg_size};
  -webkit-background-clip: text;
  background-clip: text;
  -webkit-text-fill-color: transparent;
  animation: ${brand_anim};
}

/* 登录页 Brand —— 渐变流动模式 */
.login-page .login-container .login-form .brand .brand-text {
  font-size: 2.6rem; font-weight: 400; word-break: break-word;
  font-family: "${FONT_NAME}", sans-serif;
  background: linear-gradient(90deg, ${GRAD_COLORS},
    $(echo "$GRAD_COLORS" | cut -d',' -f1));
  background-size: ${bg_size};
  -webkit-background-clip: text;
  background-clip: text;
  -webkit-text-fill-color: transparent;
  animation: ${login_anim};
}
/* === END BRAND_ANIMATION === */
EOF
    fi

    success "Brand 动画注入完成 [模式${anim_mode}: $GRAD_NAME | ${anim_speed}s]"
}

# ============ 动画模式快速切换（独立菜单项） ============
step_switch_animation() {
    title "🔄 切换 Brand 动画模式"

    if ! grep -q "=== BRAND_ANIMATION ===" "$ARGON_CSS"; then
        warn "尚未启用 Brand 动画，请先通过步骤3设置"
        return
    fi

    echo "  ${CYAN}1)${NC} 🌈 色相持续旋转  ${GREEN}[图片同款]${NC}"
    echo "  ${CYAN}2)${NC} 🌌 极光流动"
    echo "  ${CYAN}3)${NC} 💫 彩虹脉冲发光"
    echo "  ${CYAN}4)${NC} ⚡ 霓虹闪烁"
    echo "  ${CYAN}5)${NC} ➡️  左右平移"
    echo ""
    printf "${YELLOW}  ➤  选择新模式 [1-5]: ${NC}"; read new_mode
    printf "${YELLOW}  ➤  动画速度(秒，默认4): ${NC}"; read new_speed
    [ -z "$new_speed" ] && new_speed=4

    local new_anim
    case "$new_mode" in
        1) new_anim="hue-rotate-flow ${new_speed}s linear infinite" ;;
        2) new_anim="aurora-flow ${new_speed}s ease infinite" ;;
        3) new_anim="rainbow-pulse ${new_speed}s linear infinite" ;;
        4) new_anim="neon-flicker ${new_speed}s ease-in-out infinite" ;;
        5) new_anim="shine ${new_speed}s linear infinite" ;;
        *) warn "无效选项"; return ;;
    esac

    # 替换现有 animation 行
    sed -i "s/animation: hue-rotate-flow [^;]*/animation: ${new_anim}/" "$ARGON_CSS"
    sed -i "s/animation: aurora-flow [^;]*/animation: ${new_anim}/"      "$ARGON_CSS"
    sed -i "s/animation: rainbow-pulse [^;]*/animation: ${new_anim}/"    "$ARGON_CSS"
    sed -i "s/animation: neon-flicker [^;]*/animation: ${new_anim}/"     "$ARGON_CSS"
    sed -i "s/animation: shine [^;]*/animation: ${new_anim}/"            "$ARGON_CSS"

    success "动画模式已切换 → $new_anim"
}

# ============ 步骤4：毛玻璃 ============
step_glassmorphism() {
    title "🪟 步骤4：全局毛玻璃效果"
    ask "是否启用全局毛玻璃效果" || return

    [ -z "$SUGGEST_GLASS_ALPHA" ] && SUGGEST_GLASS_ALPHA="0.35"
    [ -z "$SUGGEST_GLASS_DARK"  ] && SUGGEST_GLASS_DARK="0.50"
    [ -z "$SUGGEST_BLUR"        ] && SUGGEST_BLUR="8"
    [ -z "$SUGGEST_BORDER"      ] && SUGGEST_BORDER="rgba(255,255,255,0.09)"
    [ -z "$SUGGEST_SCHEME"      ] && SUGGEST_SCHEME="colorful"

    local A="$SUGGEST_GLASS_ALPHA" D="$SUGGEST_GLASS_DARK"
    local BL="$SUGGEST_BLUR" BR="$SUGGEST_BORDER"
    local BASE_R="8,12,20"
    [ "$SUGGEST_SCHEME" = "light" ] && BASE_R="240,245,255"

    info "方案: ${SUGGEST_SCHEME} | 透明度: ${A} | 模糊: ${BL}px"

    if ! grep -q "=== GLASSMORPHISM ===" "$ARGON_CSS"; then
        cat >> "$ARGON_CSS" << EOF

/* === GLASSMORPHISM === */

html, body {
  background: url('/luci-static/argon/img/bg1.jpg')
    center center / cover fixed no-repeat !important;
  background-color: #0a0f1a !important;
}
.main-right, #maincontent, .main {
  background: transparent !important;
  backdrop-filter: none !important;
  -webkit-backdrop-filter: none !important;
}
.main-left, #menu, [class*="sidenav"], [class*="sidebar"] {
  background: rgba(${BASE_R}, ${D}) !important;
  backdrop-filter: blur(${BL}px) saturate(180%) !important;
  -webkit-backdrop-filter: blur(${BL}px) saturate(180%) !important;
  border-right: 1px solid ${BR} !important;
}
header, header.bg-primary, .main-right > header,
.sidenav-header, .sidenav-header.bg-primary,
.bg-primary, [class*="header"], [class*="navbar"] {
  background: rgba(${BASE_R}, ${D}) !important;
  background-color: rgba(${BASE_R}, ${D}) !important;
  backdrop-filter: blur(20px) saturate(180%) !important;
  -webkit-backdrop-filter: blur(20px) saturate(180%) !important;
  border-bottom: 1px solid ${BR} !important;
  box-shadow: 0 2px 16px rgba(0,0,0,0.3) !important;
}
:root { --primary: rgba(${BASE_R}, ${D}) !important; }
.cbi-section, .cbi-section-node, .cbi-map,
fieldset, .panel, .card, .box,
[class*="cbi-section"], [class*="cbi-map"] {
  background: rgba(${BASE_R}, ${A}) !important;
  backdrop-filter: blur(${BL}px) saturate(150%) !important;
  -webkit-backdrop-filter: blur(${BL}px) saturate(150%) !important;
  border: 1px solid ${BR} !important;
  border-radius: 12px !important;
  box-shadow: 0 4px 24px rgba(0,0,0,0.2) !important;
}
div, section, aside, article { background-color: transparent !important; }
.network-status-table, .network-status-table div,
.network-status-table td, .ifacebox, .ifacebox-body {
  background: transparent !important;
  background-color: transparent !important;
  border-color: ${BR} !important;
}
table, .table, thead, tbody, tr, td, th {
  background: transparent !important;
  background-color: transparent !important;
}
td, th { border-color: ${BR} !important; }
tbody tr:hover td { background: rgba(255,255,255,0.05) !important; }
input[type="text"], input[type="password"],
input[type="number"], select, textarea, .form-control {
  background: rgba(255,255,255,0.08) !important;
  border: 1px solid rgba(255,255,255,0.18) !important;
  backdrop-filter: blur(4px) !important;
  border-radius: 8px !important;
}
input:focus, select:focus, textarea:focus {
  border-color: rgba(49,161,161,0.80) !important;
  box-shadow: 0 0 0 2px rgba(49,161,161,0.25) !important;
}
.sidenav-menu .nav-item.active > a, .nav-pills .nav-link.active {
  background: linear-gradient(90deg,
    rgba(0,180,180,0.40), rgba(0,100,200,0.30)) !important;
  border-left: 3px solid #00fff7 !important;
  border-radius: 0 8px 8px 0 !important;
}
.login-page .login-container .login-form {
  background: rgba(${BASE_R}, ${D}) !important;
  backdrop-filter: blur(22px) saturate(160%) !important;
  -webkit-backdrop-filter: blur(22px) saturate(160%) !important;
  border: 1px solid ${BR} !important;
  border-radius: 18px !important;
}
.login-page .login-container .login-form .cbi-button-apply {
  width: 100% !important; min-height: 45px;
  margin: 30px 0 60px; padding: 10px 0;
  font-size: 15px; font-weight: 600;
  letter-spacing: .35rem; text-align: center;
  background: rgba(0,0,0,0) !important;
  backdrop-filter: blur(8px);
  border: 1px solid rgba(255,255,255,0.30) !important;
  border-radius: 9999px !important;
  cursor: pointer; transition: all 0.25s ease;
}
.login-page .login-container .login-form .cbi-button-apply:hover {
  background: rgba(255,255,255,0.12) !important;
  box-shadow: 0 0 0 2px rgba(255,255,255,0.45) !important;
}
/* === END GLASSMORPHISM === */
EOF
        success "毛玻璃注入完成（方案: ${SUGGEST_SCHEME}）"
    else
        info "毛玻璃样式已存在，跳过"
    fi
}

# ============ 步骤5：文字颜色 ============
step_text() {
    title "🔠 步骤5：文字颜色优化"
    ask "是否优化文字颜色与可读性" || return

    [ -z "$SUGGEST_TEXT_COLOR" ] && SUGGEST_TEXT_COLOR="#ffffff"
    [ -z "$SUGGEST_SHADOW"     ] && SUGGEST_SHADOW="rgba(0,0,0,0.80)"

    if ! grep -q "=== TEXT_COLOR ===" "$ARGON_CSS"; then
        cat >> "$ARGON_CSS" << EOF

/* === TEXT_COLOR === */
body, p, li, span, label, div,
.cbi-value-title, .cbi-value-field, .td, td, th {
  color: ${SUGGEST_TEXT_COLOR} !important;
  text-shadow: 0 1px 4px ${SUGGEST_SHADOW} !important;
}
h1, h2, h3, h4, h5, h6, legend {
  color: ${SUGGEST_TEXT_COLOR} !important;
  text-shadow: 0 1px 6px ${SUGGEST_SHADOW} !important;
}
.text-muted, small {
  opacity: 0.80 !important;
  text-shadow: 0 1px 3px ${SUGGEST_SHADOW} !important;
}
.sidenav-menu a, .sidenav-menu span, #menu a, #menu span {
  color: ${SUGGEST_TEXT_COLOR} !important;
  text-shadow: 0 1px 4px ${SUGGEST_SHADOW} !important;
}
header *, .bg-primary *, .sidenav-header * {
  color: ${SUGGEST_TEXT_COLOR} !important;
  text-shadow: 0 1px 4px ${SUGGEST_SHADOW} !important;
}
a { color: #7ecfff !important; }
a:hover { color: #00fff7 !important; }
a:active { color: #dddddd !important; }
input, select, textarea { text-shadow: none !important; }
/* === END TEXT_COLOR === */
EOF
        success "文字颜色注入完成（主色: ${SUGGEST_TEXT_COLOR}）"
    else
        info "文字样式已存在，跳过"
    fi
}

# ============ 步骤6：登录框位置 ============
step_login_position() {
    title "📦 步骤6：登录框位置"
    echo "  ${CYAN}1)${NC} 居中（默认）"
    echo "  ${CYAN}2)${NC} 偏左  5%"
    echo "  ${CYAN}3)${NC} 偏左 10%（更靠左）"
    echo "  ${CYAN}4)${NC} 偏右  5%"
    echo "  ${CYAN}5)${NC} 自定义"
    printf "${YELLOW}  ➤  请选择 [1-5，默认1]: ${NC}"; read pos

    local justify="" padding=""
    case "$pos" in
        2) justify="flex-start"; padding="padding-left: 5vw" ;;
        3) justify="flex-start"; padding="padding-left: 10vw" ;;
        4) justify="flex-end";   padding="padding-right: 5vw" ;;
        5)
            printf "${YELLOW}  ➤  方向(left/right): ${NC}"; read dir
            printf "${YELLOW}  ➤  距离(如 8vw):     ${NC}"; read dist
            [ "$dir" = "right" ] && \
                justify="flex-end"   && padding="padding-right: $dist" || \
                justify="flex-start" && padding="padding-left: $dist"
            ;;
        *) info "保持默认居中，跳过"; return ;;
    esac

    # 删除旧配置
    if grep -q "=== LOGIN_POSITION ===" "$ARGON_CSS"; then
        awk '/\/\* === LOGIN_POSITION ===/,/\/\* === END LOGIN_POSITION ===/{ next }1' \
            "$ARGON_CSS" > /tmp/argon_css_tmp && mv /tmp/argon_css_tmp "$ARGON_CSS"
    fi

    cat >> "$ARGON_CSS" << EOF

/* === LOGIN_POSITION === */
.login-page {
  display: flex !important;
  justify-content: ${justify} !important;
  align-items: center !important;
  ${padding} !important;
}
.login-page .login-container {
  margin: 0 !important;
  transform: none !important;
  position: relative !important;
}
/* === END LOGIN_POSITION === */
EOF
    success "登录框位置已设置"
}

# ============ 步骤7：清理元素 ============
step_clean() {
    title "🧹 步骤7：清理页面元素"

    [ -n "$SYSAUTH" ] && ask "删除登录页 SVG 图标（保留纯文字品牌名）" && {
        sed -i 's#<img src="{{ media }}/img/argon.svg" class="icon">##g' \
            "$SYSAUTH" 2>/dev/null || \
        sed -i 's#<img[^>]*argon\.svg[^>]*>##g' "$SYSAUTH" 2>/dev/null
        success "SVG 图标已删除"
    }

    [ -n "$FOOTER" ] && ask "删除 Footer 底部跳转链接" && {
        sed -i '/<footer/,/<\/footer>/ { /<a class="luci-link"/d }' "$FOOTER"
        success "Footer 链接已删除"
    }

    [ -n "$HEADER_HTM" ] && ask "从模板彻底移除橙色导航栏（最干净）" && {
        [ ! -f "${HEADER_HTM}.bak" ] && cp "$HEADER_HTM" "${HEADER_HTM}.bak"
        sed -i 's/class="bg-primary"/class="bg-glass"/g' "$HEADER_HTM"
        sed -i 's/class="sidenav-header bg-primary"/class="sidenav-header"/g' \
            "$HEADER_HTM"
        success "header.htm 橙色 class 已移除"
    }
}

# ============ 备份 & 恢复 ============
do_backup() {
    [ ! -f "${ARGON_CSS}.bak" ] && \
        cp "$ARGON_CSS" "${ARGON_CSS}.bak" && success "CSS 已备份"
    [ -n "$HEADER_HTM" ] && [ ! -f "${HEADER_HTM}.bak" ] && \
        cp "$HEADER_HTM" "${HEADER_HTM}.bak" && success "header.htm 已备份"
    [ -n "$SYSAUTH" ] && [ ! -f "${SYSAUTH}.bak" ] && \
        cp "$SYSAUTH" "${SYSAUTH}.bak" && success "sysauth 已备份"
}

do_restore() {
    title "♻️  恢复所有备份"
    local restored=0
    [ -f "${ARGON_CSS}.bak" ] && \
        cp "${ARGON_CSS}.bak" "$ARGON_CSS" && \
        success "cascade.css 已恢复" && restored=1
    [ -n "$HEADER_HTM" ] && [ -f "${HEADER_HTM}.bak" ] && \
        cp "${HEADER_HTM}.bak" "$HEADER_HTM" && \
        success "header.htm 已恢复" && restored=1
    [ -n "$SYSAUTH" ] && [ -f "${SYSAUTH}.bak" ] && \
        cp "${SYSAUTH}.bak" "$SYSAUTH" && \
        success "sysauth 已恢复" && restored=1
    [ "$restored" -eq 0 ] && warn "未找到任何备份"
    rm -rf /tmp/luci-* && success "缓存已清除"
}

# ============ 状态查看 ============
show_status() {
    title "📊 当前美化状态"
    local css="$ARGON_CSS"

    grep -q "GLASSMORPHISM"       "$css" && \
        success "毛玻璃 (方案: ${SUGGEST_SCHEME:-已启用})" || \
        warn "毛玻璃未启用"

    grep -q "KEYFRAMES_ALL"       "$css" && \
        success "动画关键帧已注入" || warn "动画关键帧未注入"

    grep -q "BRAND_ANIMATION"     "$css" && {
        local cur_anim
        cur_anim=$(grep "animation:" "$css" | grep -v "^/\*" | head -1 | \
            sed 's/.*animation: //;s/;.*//' | xargs)
        success "Brand动画: $cur_anim"
    } || warn "Brand动画未启用"

    grep -q "FONT_FACE"           "$css" && {
        local fn
        fn=$(grep "FONT_FACE_" "$css" | head -1 | sed 's/.*FONT_FACE_//;s/ ==.*//')
        success "字体: $fn"
    } || warn "使用系统默认字体"

    grep -q "TEXT_COLOR"          "$css" && \
        success "文字优化已启用" || warn "文字优化未启用"
    grep -q "LOGIN_POSITION"      "$css" && \
        success "登录框已自定义位置" || warn "登录框默认居中"

    echo ""
    local bg_stat woff2_stat woff_stat
    [ -f "$ARGON_BG" ] && \
        bg_stat="✓ ($(du -sh $ARGON_BG | cut -f1))" || bg_stat="✗ 未找到"
    [ -f "$ARGON_FONTS/TypoGraphica.woff2" ] && woff2_stat="✓" || woff2_stat="✗"
    [ -f "$ARGON_FONTS/TypoGraphica.woff"  ] && woff_stat="✓"  || woff_stat="✗"
    info "背景图  : $bg_stat"
    info "woff2   : $woff2_stat"
    info "woff    : $woff_stat"
    info "CSS行数 : $(wc -l < $css)"
    info "CSS大小 : $(du -sh $css | cut -f1)"
}

do_flush() {
    rm -rf /tmp/luci-*
    success "LuCI 缓存已清除"
}

# ============ 主菜单 ============
main_menu() {
    while true; do
        echo ""
        echo "${CYAN}╔══════════════════════════════════════════════╗${NC}"
        echo "${CYAN}║      Argon 智能美化工具 v3.0                 ║${NC}"
        echo "${CYAN}╠══════════════════════════════════════════════╣${NC}"
        echo "${CYAN}║ ${WHITE}1${CYAN}) 🚀 一键智能全流程美化（推荐新手）      ║${NC}"
        echo "${CYAN}║ ${WHITE}2${CYAN}) 📊 查看当前美化状态                    ║${NC}"
        echo "${CYAN}║ ${WHITE}0${CYAN}) 🌐 联网检测所有内置URL可用性           ║${NC}"
        echo "${CYAN}╠══════════════════════════════════════════════╣${NC}"
        echo "${CYAN}║ ${WHITE}3${CYAN}) 🖼️  下载/更换背景图                    ║${NC}"
        echo "${CYAN}║ ${WHITE}4${CYAN}) 🔤 获取/更换字体                       ║${NC}"
        echo "${CYAN}║ ${WHITE}5${CYAN}) ✨ Brand 动画效果（含色相旋转）        ║${NC}"
        echo "${CYAN}║ ${WHITE}6${CYAN}) 🔄 切换动画模式（不重新设置颜色）      ║${NC}"
        echo "${CYAN}║ ${WHITE}7${CYAN}) 🪟 毛玻璃效果                          ║${NC}"
        echo "${CYAN}║ ${WHITE}8${CYAN}) 🔠 文字颜色优化                        ║${NC}"
        echo "${CYAN}║ ${WHITE}9${CYAN}) 📦 登录框位置                          ║${NC}"
        echo "${CYAN}║ ${WHITE}a${CYAN}) 🧹 清理页面元素                        ║${NC}"
        echo "${CYAN}╠══════════════════════════════════════════════╣${NC}"
        echo "${CYAN}║ ${WHITE}r${CYAN}) ♻️  一键恢复原版                         ║${NC}"
        echo "${CYAN}║ ${WHITE}f${CYAN}) 🔄 清除LuCI缓存                         ║${NC}"
        echo "${CYAN}║ ${WHITE}q${CYAN}) 👋 退出                                ║${NC}"
        echo "${CYAN}╚══════════════════════════════════════════════╝${NC}"
        printf "${YELLOW}请选择: ${NC}"; read choice

        case "$choice" in
            1)
                title "🚀 开始智能全流程美化"
                step_download_image
                step_download_font
                step_brand_animation
                analyze_bg_and_suggest
                step_glassmorphism
                step_text
                step_login_position
                step_clean
                do_flush
                echo ""
                echo "${GREEN}╔════════════════════════════════════════════╗${NC}"
                echo "${GREEN}║  ✅ 全部完成！                              ║${NC}"
                echo "${GREEN}║  浏览器按 Ctrl+Shift+R 强制刷新即可        ║${NC}"
                echo "${GREEN}╚════════════════════════════════════════════╝${NC}"
                ;;
            2) show_status ;;
            0) step_check_urls ;;
            3) step_download_image;    do_flush ;;
            4) step_download_font;     do_flush ;;
            5) step_brand_animation;   do_flush ;;
            6) step_switch_animation;  do_flush ;;
            7) analyze_bg_and_suggest; step_glassmorphism; do_flush ;;
            8) analyze_bg_and_suggest; step_text; do_flush ;;
            9) step_login_position;    do_flush ;;
            a) step_clean;             do_flush ;;
            r) do_restore ;;
            f) do_flush ;;
            q) echo "${GREEN}  再见！${NC}"; exit 0 ;;
            *) warn "无效选项，请重新选择" ;;
        esac
    done
}

# ============ 程序入口 ============
echo "${CYAN}"
echo "  ╔════════════════════════════════════════════════╗"
echo "  ║   Argon 主题智能美化工具 v3.0                  ║"
echo "  ║   色相旋转动画 / URL联网校验 / 智能色调适配    ║"
echo "  ╚════════════════════════════════════════════════╝"
echo "${NC}"

detect_paths
do_backup
main_menu
