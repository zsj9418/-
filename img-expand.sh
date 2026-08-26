#!/bin/bash
VERSION="2.6"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
WHITE='\033[1;37m'
NC='\033[0m'
SCAN_DIRS=("/var/lib/vz/template/iso" "/var/lib/vz/template" "/var/lib/vz/images" "/root" "/tmp")
IMG_PATTERNS=("*.img" "*.img.gz" "*.raw")
declare -a FOUND_IMAGES=()
declare -a FOUND_PATHS=()
declare -a FOUND_SIZES=()
declare -a FOUND_TYPES=()
LOG_FILE="/var/log/img_expand_$(date +%Y%m%d_%H%M%S).log"
IS_PVE=false
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }
print_header() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}  ${WHITE}固件镜像扩容管理工具 v${VERSION}${NC}                        ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
}
line() { echo -e "${CYAN}──────────────────────────────────────────────────────${NC}"; }
info() { echo -e "${BLUE}[信息]${NC} $*"; log "[INFO] $*"; }
ok() { echo -e "${GREEN}[成功]${NC} $*"; log "[OK] $*"; }
warn() { echo -e "${YELLOW}[警告]${NC} $*"; log "[WARN] $*"; }
err() { echo -e "${RED}[错误]${NC} $*"; log "[ERROR] $*"; }
step() { echo -e "${PURPLE}[步骤 $1]${NC} $2"; log "[STEP $1] $2"; }
pause() { echo ""; read -rp "$(echo -e ${CYAN}"按 Enter 返回..."${NC})"; }
confirm() {
    local a
    while true; do
        read -rp "$(echo -e ${YELLOW}"$1 (y/n): "${NC})" a
        case "$a" in
            [Yy]*) return 0 ;; [Nn]*) return 1 ;; *) echo -e "${RED}请输入 y 或 n${NC}" ;;
        esac
    done
}
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        err "需要 root 权限"; exit 1
    fi
}
check_pve() {
    if command -v pveversion &>/dev/null; then
        IS_PVE=true
    fi
}
check_deps() {
    print_header; echo ""; echo -e "  ${WHITE}检查依赖${NC}"; line; echo ""
    local need=() ok_flag=true
    declare -A MAP=(["qemu-img"]="qemu-utils" ["sgdisk"]="gdisk" ["parted"]="parted" ["losetup"]="mount" ["lsblk"]="util-linux" ["sfdisk"]="fdisk" ["bc"]="bc")
    for cmd in "${!MAP[@]}"; do
        if command -v "$cmd" &>/dev/null; then
            echo -e "  ${GREEN}✔${NC} $cmd (${MAP[$cmd]})"
        else
            echo -e "  ${RED}✘${NC} $cmd (${MAP[$cmd]})"
            need+=("${MAP[$cmd]}"); ok_flag=false
        fi
    done
    echo ""
    if $ok_flag; then
        ok "所有依赖已满足"
    else
        warn "缺失: ${need[*]}"
        if confirm "自动安装?"; then
            apt-get update -qq 2>/dev/null
            for p in "${need[@]}"; do
                if apt-get install -y -qq "$p" 2>/dev/null; then ok "$p 已安装"; else err "$p 安装失败"; fi
            done
        fi
    fi
    pause
}
detect_fw_type() {
    local f; f=$(basename "$1" | tr '[:upper:]' '[:lower:]')
    if echo "$f" | grep -qi "hwrt"; then echo "HWRT"
    elif echo "$f" | grep -qi "immortalwrt"; then echo "ImmortalWrt"
    elif echo "$f" | grep -qi "istoreos"; then echo "iStoreOS"
    elif echo "$f" | grep -qi "openwrt"; then echo "OpenWrt"
    elif echo "$f" | grep -qi "lede"; then echo "LEDE"
    elif echo "$f" | grep -qi "friendlywrt"; then echo "FriendlyWrt"
    else echo "未知"; fi
}
detect_pt_type() {
    local r; r=$(sfdisk -l "$1" 2>/dev/null | head -20)
    if echo "$r" | grep -qi "gpt"; then echo "GPT"
    elif echo "$r" | grep -qi "dos"; then echo "MBR"
    else echo "unknown"; fi
}
hr_size() {
    local b=$1
    if [ "$b" -ge 1073741824 ]; then printf "%.2fG" "$(echo "$b/1073741824" | bc -l)"
    elif [ "$b" -ge 1048576 ]; then printf "%dM" "$((b/1048576))"
    else printf "%dK" "$((b/1024))"; fi
}
parse_size() {
    local input; input=$(echo "$1" | tr '[:lower:]' '[:upper:]' | sed 's/ //g')
    local num; num=$(echo "$input" | grep -oE '[0-9]+\.?[0-9]*')
    local unit; unit=$(echo "$input" | grep -oE '[A-Z]+')
    [ -z "$num" ] && echo "0" && return 1
    case "$unit" in
        G|GB|GIB) echo "$(echo "$num * 1073741824 / 1" | bc)" ;;
        M|MB|MIB) echo "$(echo "$num * 1048576 / 1" | bc)" ;;
        T|TB|TIB) echo "$(echo "$num * 1099511627776 / 1" | bc)" ;;
        "") echo "$(echo "$num * 1073741824 / 1" | bc)" ;;
        *) echo "0"; return 1 ;;
    esac
}
scan_images() {
    FOUND_IMAGES=(); FOUND_PATHS=(); FOUND_SIZES=(); FOUND_TYPES=()
    local -A seen
    for dir in "${SCAN_DIRS[@]}"; do
        [ -d "$dir" ] || continue
        for pat in "${IMG_PATTERNS[@]}"; do
            while IFS= read -r -d '' fp; do
                [ -n "${seen[$fp]+_}" ] && continue
                seen["$fp"]=1
                FOUND_IMAGES+=("$(basename "$fp")")
                FOUND_PATHS+=("$fp")
                FOUND_SIZES+=("$(stat -c%s "$fp" 2>/dev/null || echo 0)")
                FOUND_TYPES+=("$(detect_fw_type "$fp")")
            done < <(find "$dir" -maxdepth 2 -type f -name "$pat" ! -name "*.bak" ! -name "*.backup" -print0 2>/dev/null)
        done
    done
}
show_list() {
    scan_images
    if [ ${#FOUND_IMAGES[@]} -eq 0 ]; then
        warn "未找到固件镜像"; return 1
    fi
    printf "  ${WHITE}%-4s %-44s %-8s %-12s${NC}\n" "序号" "文件名" "大小" "类型"
    line
    for i in "${!FOUND_IMAGES[@]}"; do
        local n="${FOUND_IMAGES[$i]}"
        [ ${#n} -gt 42 ] && n="${n:0:39}..."
        printf "  ${GREEN}%-4s${NC} %-44s %-8s ${CYAN}%-12s${NC}\n" \
            "[$((i+1))]" "$n" "$(hr_size "${FOUND_SIZES[$i]}")" "${FOUND_TYPES[$i]}"
    done
}
pick_image() {
    local c
    while true; do
        read -rp "$(echo -e ${WHITE}"请选择固件序号 [0=返回]: "${NC})" c
        [ "$c" = "0" ] && return 1
        if [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le ${#FOUND_IMAGES[@]} ]; then
            PICK_IDX=$((c-1)); return 0
        fi
        err "无效选择"
    done
}
do_expand() {
    print_header; echo ""; echo -e "  ${WHITE}扩容固件镜像${NC}"; line; echo ""
    show_list || { pause; return; }
    echo ""; echo -e "  ${YELLOW}[0]${NC}  返回"; echo ""
    pick_image || return
    local idx=$PICK_IDX
    local IMG="${FOUND_PATHS[$idx]}"
    local NAME="${FOUND_IMAGES[$idx]}"
    local CURSIZE="${FOUND_SIZES[$idx]}"
    local CURHR; CURHR=$(hr_size "$CURSIZE")
    echo ""; line
    echo -e "  文件: ${GREEN}${NAME}${NC}"
    echo -e "  路径: ${IMG}"
    echo -e "  大小: ${YELLOW}${CURHR}${NC}"
    echo -e "  类型: ${CYAN}${FOUND_TYPES[$idx]}${NC}"
    line; echo ""
    echo -e "  ${WHITE}参考: 1G=轻量 2G=日常 4G=插件多 (回车=仅修复现有未分配空间)${NC}"; echo ""
    local tinput tbytes
    while true; do
        read -rp "$(echo -e ${WHITE}"目标大小 (如 4G 512M / 回车直接修复): "${NC})" tinput
        if [ -z "$tinput" ]; then
            tbytes=$CURSIZE
            break
        fi
        tbytes=$(parse_size "$tinput")
        [ "$tbytes" = "0" ] && { err "格式错误"; continue; }
        [ "$tbytes" -lt "$CURSIZE" ] && { err "目标大小不能小于当前文件大小 ${CURHR}"; continue; }
        break
    done
    local thr; thr=$(hr_size "$tbytes")
    echo ""; line
    if [ "$tbytes" -gt "$CURSIZE" ]; then
        echo -e "  操作: 扩容 ${YELLOW}${CURHR}${NC} → ${GREEN}${thr}${NC}  增量: $(hr_size $((tbytes-CURSIZE)))"
    else
        echo -e "  操作: ${YELLOW}保持 ${CURHR} 不变，直接修复镜像内部未分配空间${NC}"
    fi
    line; echo ""
    confirm "确认执行?" || { pause; return; }
    echo ""
    local BAK="${IMG}.bak"
    step "1/5" "备份原始镜像..."
    if [ -f "$BAK" ]; then
        warn "备份已存在: ${BAK}"
        confirm "覆盖?" && cp "$IMG" "$BAK" && ok "已覆盖" || info "保留旧备份"
    else
        cp "$IMG" "$BAK"; ok "备份: ${BAK}"
    fi
    step "2/5" "检测镜像格式..."
    local fmt
    fmt=$(qemu-img info "$IMG" 2>/dev/null | grep "^file format:" | awk '{print $3}')
    [ -z "$fmt" ] && fmt="raw"
    ok "格式: ${fmt}"
    if [ "$tbytes" -gt "$CURSIZE" ]; then
        step "3/5" "扩容镜像文件外壳..."
        local qsize
        qsize=$(echo "$tinput" | tr '[:lower:]' '[:upper:]' | sed 's/[BI]//g')
        if qemu-img resize -f "$fmt" "$IMG" "$qsize" >/dev/null 2>&1; then
            ok "镜像外壳已扩容"
        else
            err "扩容失败"
            confirm "从备份恢复?" && cp "$BAK" "$IMG" && ok "已恢复"
            pause; return
        fi
    else
        step "3/5" "文件大小不变，跳过外壳扩容"
    fi
    step "4/5" "重构内部分区表并恢复 PARTUUID..."
    local pt; pt=$(detect_pt_type "$IMG")
    info "分区表类型: ${pt}"
    local lpart
    lpart=$(sgdisk -p "$IMG" 2>/dev/null | awk '/^\s*[0-9]+/{p=$1} END{print p}')
    [ -z "$lpart" ] && lpart=$(parted -s "$IMG" print 2>/dev/null | grep -E '^\s*[0-9]+' | awk '{print $1}' | sort -n | tail -1)
    if [ -z "$lpart" ]; then
        err "无法检测分区"; pause; return
    fi
    if [ "$pt" = "GPT" ] || [ "$pt" = "unknown" ]; then
        local pguid pstart pname
        pstart=$(sgdisk -i "$lpart" "$IMG" 2>/dev/null | grep -i "First sector" | awk '{print $3}')
        pguid=$(sgdisk -i "$lpart" "$IMG" 2>/dev/null | grep -i "Partition unique GUID" | awk '{print $4}')
        pname=$(sgdisk -i "$lpart" "$IMG" 2>/dev/null | grep -i "Partition name" | cut -d"'" -f2)
        sgdisk -e "$IMG" >/dev/null 2>&1
        if [ -n "$pstart" ]; then
            sgdisk -d "$lpart" "$IMG" >/dev/null 2>&1
            sgdisk -n "${lpart}:${pstart}:0" "$IMG" >/dev/null 2>&1
            if [ -n "$pguid" ]; then
                sgdisk -u "${lpart}:${pguid}" "$IMG" >/dev/null 2>&1
            fi
            if [ -n "$pname" ]; then
                sgdisk -c "${lpart}:${pname}" "$IMG" >/dev/null 2>&1
            fi
        fi
    elif [ "$pt" = "MBR" ]; then
        echo ", +" | sfdisk -N "$lpart" "$IMG" --no-reread --force >/dev/null 2>&1
    fi
    step "5/5" "校验扩展结果..."
    local check_bytes
    check_bytes=$(parted -s "$IMG" unit B print 2>/dev/null | awk -v p="$lpart" '$1==p {print $4}' | grep -oE '[0-9]+')
    if [ -z "$check_bytes" ] || [ "$check_bytes" -lt $((tbytes / 2)) ]; then
        err "校验失败：分区未能扩展至目标大小"
        cp "$BAK" "$IMG"
        info "已自动还原备份镜像"
        pause; return
    fi
    echo ""; echo -e "  ${WHITE}扩展后内部分区表:${NC}"
    parted -s "$IMG" print 2>/dev/null | grep -E '(^Model|^Disk|^Number|^\s+[0-9])' | sed 's/^/    /'
    echo ""
    local fsize; fsize=$(stat -c%s "$IMG" 2>/dev/null)
    local fhr; fhr=$(hr_size "$fsize")
    echo -e "  ${GREEN}╔════════════════════════════════════════════╗${NC}"
    echo -e "  ${GREEN}║         ✅ 执行成功                       ║${NC}"
    echo -e "  ${GREEN}╠════════════════════════════════════════════╣${NC}"
    echo -e "  ${GREEN}║${NC} 文件: ${WHITE}${NAME}${NC}"
    echo -e "  ${GREEN}║${NC} 大小: ${YELLOW}${CURHR}${NC} → ${GREEN}${fhr}${NC}"
    echo -e "  ${GREEN}║${NC} 备份: ${BAK}"
    if $IS_PVE; then
        echo -e "  ${GREEN}║${NC} 下一步: 主菜单 [2] 导入到虚拟机"
    fi
    echo -e "  ${GREEN}╚════════════════════════════════════════════╝${NC}"
    pause
}
do_import() {
    print_header; echo ""; echo -e "  ${WHITE}导入镜像到 PVE 虚拟机${NC}"; line; echo ""
    if ! $IS_PVE; then err "非 PVE 环境"; pause; return; fi
    show_list || { pause; return; }
    echo ""; echo -e "  ${YELLOW}[0]${NC}  返回"; echo ""
    pick_image || return
    local idx=$PICK_IDX
    local IMG="${FOUND_PATHS[$idx]}"
    local NAME="${FOUND_IMAGES[$idx]}"
    echo ""; info "已有虚拟机:"
    qm list 2>/dev/null | head -20
    echo ""
    local vmid
    while true; do
        read -rp "$(echo -e ${WHITE}"VMID (100-999999): "${NC})" vmid
        [[ "$vmid" =~ ^[0-9]+$ ]] && [ "$vmid" -ge 100 ] && break
        err "无效 VMID"
    done
    if ! qm status "$vmid" &>/dev/null; then
        warn "VM ${vmid} 不存在"
        if confirm "自动创建?"; then
            local bios="ovmf"
            echo "$NAME" | tr '[:upper:]' '[:lower:]' | grep -q "efi" || bios="seabios"
            info "BIOS: ${bios}"
            info "可用存储:"
            pvesm status 2>/dev/null | awk 'NR>1{printf "    %-20s %s\n",$1,$2}'
            echo ""
            local stor
            read -rp "$(echo -e ${WHITE}"存储 (默认 local-lvm): "${NC})" stor
            stor=${stor:-local-lvm}
            local cmd="qm create $vmid --name OpenWrt --machine q35 --cpu host --cores 2 --memory 1024 --ostype l26"
            [ "$bios" = "ovmf" ] && cmd="$cmd --bios ovmf"
            if eval "$cmd" 2>&1; then
                ok "VM ${vmid} 已创建"
                [ "$bios" = "ovmf" ] && qm set "$vmid" --efidisk0 "${stor}:1,format=raw,efitype=4m,pre-enrolled-keys=0" 2>/dev/null
                qm set "$vmid" --net0 "virtio,bridge=vmbr0" 2>/dev/null
            else
                err "创建失败"; pause; return
            fi
        else
            pause; return
        fi
    fi
    if [ -z "$stor" ]; then
        info "可用存储:"
        pvesm status 2>/dev/null | awk 'NR>1{printf "    %-20s %s\n",$1,$2}'
        echo ""
        read -rp "$(echo -e ${WHITE}"存储 (默认 local-lvm): "${NC})" stor
        stor=${stor:-local-lvm}
    fi
    echo ""; info "导入磁盘..."
    if qm importdisk "$vmid" "$IMG" "$stor" 2>&1; then
        echo ""; ok "导入成功"
        echo ""
        if confirm "自动挂载并设为启动盘?"; then
            local ukey; ukey=$(qm config "$vmid" 2>/dev/null | grep "^unused" | head -1 | cut -d: -f1)
            if [ -n "$ukey" ]; then
                local dref; dref=$(qm config "$vmid" 2>/dev/null | grep "^${ukey}" | awk '{print $2}')
                qm set "$vmid" --sata0 "$dref" 2>/dev/null
                qm set "$vmid" --delete "$ukey" 2>/dev/null
                qm set "$vmid" --boot order=sata0 2>/dev/null
                ok "已挂载到 sata0 并设为启动盘"
                echo ""
                confirm "立即启动 VM ${vmid}?" && qm start "$vmid" 2>&1 && ok "已启动"
            else
                warn "未找到未使用磁盘,请在 Web 界面手动挂载"
            fi
        else
            echo -e "  ${YELLOW}请在 Web 界面:${NC}"
            echo -e "  1. 硬件 → 未使用磁盘 → 双击 → 总线SATA → 添加"
            echo -e "  2. 选项 → 引导顺序 → 拖到第一位"
        fi
    else
        err "导入失败"
    fi
    pause
}
do_detail() {
    print_header; echo ""; echo -e "  ${WHITE}镜像详情${NC}"; line; echo ""
    show_list || { pause; return; }
    echo ""; echo -e "  ${YELLOW}[0]${NC}  返回"; echo ""
    pick_image || return
    local idx=$PICK_IDX
    local IMG="${FOUND_PATHS[$idx]}"
    echo ""; line
    echo -e "  文件: ${GREEN}${FOUND_IMAGES[$idx]}${NC}"
    echo -e "  路径: ${IMG}"
    echo -e "  大小: $(hr_size "${FOUND_SIZES[$idx]}")"
    echo -e "  类型: ${CYAN}${FOUND_TYPES[$idx]}${NC}"
    echo -e "  MD5:  $(md5sum "$IMG" 2>/dev/null | awk '{print $1}')"
    line; echo ""
    echo -e "  ${WHITE}qemu-img:${NC}"
    qemu-img info "$IMG" 2>/dev/null | sed 's/^/    /'
    echo ""
    echo -e "  ${WHITE}分区表:${NC}"
    parted -s "$IMG" print 2>/dev/null | sed 's/^/    /' || sfdisk -l "$IMG" 2>/dev/null | sed 's/^/    /'
    pause
}
do_restore() {
    print_header; echo ""; echo -e "  ${WHITE}恢复备份${NC}"; line; echo ""
    local -a bp=()
    for d in "${SCAN_DIRS[@]}"; do
        [ -d "$d" ] || continue
        while IFS= read -r -d '' f; do bp+=("$f"); done < <(find "$d" -maxdepth 2 -name "*.img.bak" -print0 2>/dev/null)
    done
    if [ ${#bp[@]} -eq 0 ]; then info "无备份文件"; pause; return; fi
    for i in "${!bp[@]}"; do
        printf "  ${GREEN}[%d]${NC} %-50s %s\n" "$((i+1))" "$(basename "${bp[$i]}")" "$(hr_size "$(stat -c%s "${bp[$i]}" 2>/dev/null)")"
    done
    echo ""; echo -e "  ${YELLOW}[0]${NC}  返回"; echo ""
    local c
    while true; do
        read -rp "$(echo -e ${WHITE}"选择: "${NC})" c
        [ "$c" = "0" ] && return
        [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le ${#bp[@]} ] && break
        err "无效"
    done
    local bak="${bp[$((c-1))]}" orig="${bp[$((c-1))]%.bak}"
    info "备份: ${bak}"; info "目标: ${orig}"
    if confirm "确认恢复?"; then
        cp "$bak" "$orig"; ok "已恢复"
        confirm "删除备份?" && rm -f "$bak" && ok "已删除"
    fi
    pause
}
do_clean() {
    print_header; echo ""; echo -e "  ${WHITE}清理备份${NC}"; line; echo ""
    local -a bp=(); local total=0
    for d in "${SCAN_DIRS[@]}"; do
        [ -d "$d" ] || continue
        while IFS= read -r -d '' f; do
            bp+=("$f"); total=$((total + $(stat -c%s "$f" 2>/dev/null || echo 0)))
        done < <(find "$d" -maxdepth 2 -name "*.img.bak" -print0 2>/dev/null)
    done
    if [ ${#bp[@]} -eq 0 ]; then info "无备份文件"; pause; return; fi
    info "${#bp[@]} 个备份, 共 $(hr_size $total):"
    for f in "${bp[@]}"; do echo -e "    ${YELLOW}$(hr_size "$(stat -c%s "$f" 2>/dev/null)")${NC}  $f"; done
    echo ""
    if confirm "全部删除?"; then
        for f in "${bp[@]}"; do rm -f "$f"; done
        ok "已清理, 释放 $(hr_size $total)"
    fi
    pause
}
do_scandirs() {
    print_header; echo ""; echo -e "  ${WHITE}扫描目录管理${NC}"; line; echo ""
    for i in "${!SCAN_DIRS[@]}"; do
        local e=""; [ -d "${SCAN_DIRS[$i]}" ] && e="${GREEN}✔${NC}" || e="${RED}✘${NC}"
        echo -e "  ${GREEN}[$((i+1))]${NC} ${SCAN_DIRS[$i]} $e"
    done
    echo ""; echo -e "  ${GREEN}[a]${NC} 添加  ${GREEN}[d]${NC} 删除  ${GREEN}[0]${NC} Return"; echo ""
    local a; read -rp "$(echo -e ${WHITE}"操作: "${NC})" a
    case "$a" in
        a|A) read -rp "$(echo -e ${WHITE}"目录路径: "${NC})" nd
            [ -d "$nd" ] && { SCAN_DIRS+=("$nd"); ok "已添加"; } || err "不存在" ;;
        d|D) read -rp "$(echo -e ${WHITE}"删除序号: "${NC})" di
            [[ "$di" =~ ^[0-9]+$ ]] && [ "$di" -ge 1 ] && [ "$di" -le ${#SCAN_DIRS[@]} ] && {
                unset 'SCAN_DIRS[$((di-1))]'; SCAN_DIRS=("${SCAN_DIRS[@]}"); ok "已删除"
            } || err "无效" ;;
    esac
    pause
}
main_menu() {
    while true; do
        print_header; echo ""
        echo -e "  ${WHITE}主菜单${NC}"; line; echo ""
        echo -e "    ${GREEN}[1]${NC}  扩容 / 修复镜像"
        echo -e "    ${GREEN}[2]${NC}  导入镜像到虚拟机"
        echo -e "    ${GREEN}[3]${NC}  查看镜像详情"
        echo -e "    ${GREEN}[4]${NC}  恢复备份"
        echo -e "    ${GREEN}[5]${NC}  清理备份文件"
        echo -e "    ${GREEN}[6]${NC}  扫描目录管理"
        echo -e "    ${GREEN}[7]${NC}  检查依赖"
        echo -e "    ${RED}[0]${NC}  退出"
        echo ""; line
        scan_images
        echo -e "  固件: ${GREEN}${#FOUND_IMAGES[@]}${NC} 个 | PVE: $(if $IS_PVE; then echo -e "${GREEN}是${NC}"; else echo -e "${RED}否${NC}"; fi)"
        echo ""
        local c; read -rp "$(echo -e ${WHITE}"选项 [0-7]: "${NC})" c
        case "$c" in
            1) do_expand ;; 2) do_import ;; 3) do_detail ;;
            4) do_restore ;; 5) do_clean ;; 6) do_scandirs ;; 7) check_deps ;;
            0) echo ""; info "再见!"; exit 0 ;;
            *) err "无效选项"; sleep 1 ;;
        esac
    done
}
main() {
    mkdir -p "$(dirname "$LOG_FILE")"
    log "启动"
    check_root
    check_pve
    main_menu
}
main "$@"
