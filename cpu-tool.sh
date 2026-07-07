#!/bin/bash

CPU0="/sys/devices/system/cpu/cpu0/cpufreq"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# 暂停等待按键
pause() {
    echo ""
    read -rp "按 Enter 键返回主菜单..."
}

# 获取系统信息
get_system_info() {
    # 操作系统
    if [ -f /etc/os-release ]; then
        OS_NAME=$(grep "^PRETTY_NAME=" /etc/os-release | cut -d'"' -f2)
    else
        OS_NAME=$(uname -o 2>/dev/null || echo "未知")
    fi

    # 内核版本
    KERNEL_VERSION=$(uname -r)

    # CPU 架构
    CPU_ARCH=$(uname -m)

    # CPU 型号
    if [ -f /proc/cpuinfo ]; then
        CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo | cut -d':' -f2 | xargs)
        if [ -z "${CPU_MODEL}" ]; then
            # ARM 处理器可能用 Hardware 或 Processor
            CPU_MODEL=$(grep -m1 "Hardware" /proc/cpuinfo | cut -d':' -f2 | xargs)
        fi
        if [ -z "${CPU_MODEL}" ]; then
            CPU_MODEL=$(grep -m1 "Processor" /proc/cpuinfo | cut -d':' -f2 | xargs)
        fi
        if [ -z "${CPU_MODEL}" ]; then
            CPU_MODEL="未知"
        fi
    else
        CPU_MODEL="未知"
    fi

    # CPU 核心数
    CPU_CORES=$(nproc 2>/dev/null || echo "未知")

    # 在线核心数
    ONLINE_CORES=$(ls -d /sys/devices/system/cpu/cpu[0-9]*/cpufreq 2>/dev/null | wc -l)
}

# 获取默认/基准频率 (自动检测最低非超频档位中的最高值)
get_base_freq() {
    if [ -f "${CPU0}/base_frequency" ]; then
        # 部分系统直接提供基准频率
        BASE_FREQ=$(cat "${CPU0}/base_frequency" 2>/dev/null)
    elif [ -f "${CPU0}/scaling_available_frequencies" ]; then
        # 取可用频率中的中间值作为参考基准
        AVAIL=$(cat "${CPU0}/scaling_available_frequencies" 2>/dev/null)
        FREQ_ARRAY=(${AVAIL})
        FREQ_COUNT=${#FREQ_ARRAY[@]}
        if [ "${FREQ_COUNT}" -gt 0 ]; then
            # 取第一个频率作为最低，最后一个作为最高
            MIN_AVAIL=${FREQ_ARRAY[0]}
            MAX_AVAIL=${FREQ_ARRAY[$((FREQ_COUNT-1))]}
            # 基准频率估算：取中间偏上的值
            MID_IDX=$(( (FREQ_COUNT * 2) / 3 ))
            BASE_FREQ=${FREQ_ARRAY[${MID_IDX}]}
        else
            BASE_FREQ=0
        fi
    else
        BASE_FREQ=0
    fi
}

# 检查 cpufreq 是否可用
check_cpufreq() {
    if [ ! -d "${CPU0}" ]; then
        echo -e "${RED}❌ 错误: cpufreq 目录不存在${NC}"
        echo ""
        echo "可能的原因:"
        echo "  1. 内核未启用 CONFIG_CPU_FREQ"
        echo "  2. cpufreq 驱动未加载"
        echo "  3. 虚拟机/容器环境不支持"
        return 1
    fi
    return 0
}

# 格式化频率显示
format_freq() {
    local freq=$1
    if [ -z "${freq}" ] || [ "${freq}" = "N/A" ] || [ "${freq}" -eq 0 ] 2>/dev/null; then
        echo "N/A"
    elif [ "${freq}" -ge 1000000 ]; then
        awk "BEGIN{printf \"%.2f GHz\", ${freq}/1000000}"
    else
        awk "BEGIN{printf \"%.0f MHz\", ${freq}/1000}"
    fi
}

# 显示系统和 CPU 详细信息
show_cpu_info() {
    clear
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗"
    echo -e "║           Linux CPU 频率信息检测工具                       ║"
    echo -e "╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # 获取系统信息
    get_system_info
    get_base_freq

    echo -e "${GREEN}【系统信息】${NC}"
    echo "  操作系统:   ${OS_NAME}"
    echo "  内核版本:   ${KERNEL_VERSION}"
    echo "  CPU 架构:   ${CPU_ARCH}"
    echo "  CPU 型号:   ${CPU_MODEL}"
    echo "  核心总数:   ${CPU_CORES}"
    echo "  在线核心:   ${ONLINE_CORES}"
    echo ""

    if ! check_cpufreq; then
        echo ""
        echo -e "${YELLOW}【内核配置检查】${NC}"
        if [ -f /proc/config.gz ]; then
            zcat /proc/config.gz 2>/dev/null | grep -i "CPU_FREQ" | head -n 10 || echo "  无法读取"
        else
            echo "  /proc/config.gz 不可用"
        fi
        echo ""
        echo -e "${YELLOW}【dmesg 相关信息】${NC}"
        dmesg 2>/dev/null | grep -i cpufreq | tail -n 10 || echo "  无法读取"
        pause
        return
    fi

    echo -e "${GREEN}【频率调节驱动】${NC}"
    DRIVER=$(cat ${CPU0}/scaling_driver 2>/dev/null || echo "未知")
    GOVERNOR=$(cat ${CPU0}/scaling_governor 2>/dev/null || echo "未知")
    echo "  驱动名称:   ${DRIVER}"
    echo "  调节策略:   ${GOVERNOR}"
    echo ""

    echo -e "${GREEN}【频率范围】${NC}"
    MIN_HW=$(cat ${CPU0}/cpuinfo_min_freq 2>/dev/null || echo 0)
    MAX_HW=$(cat ${CPU0}/cpuinfo_max_freq 2>/dev/null || echo 0)
    MIN_SW=$(cat ${CPU0}/scaling_min_freq 2>/dev/null || echo 0)
    MAX_SW=$(cat ${CPU0}/scaling_max_freq 2>/dev/null || echo 0)
    echo "  硬件最低频率:   $(format_freq ${MIN_HW})"
    echo "  硬件最高频率:   $(format_freq ${MAX_HW})"
    echo "  软件最低限制:   $(format_freq ${MIN_SW})"
    echo "  软件最高限制:   $(format_freq ${MAX_SW})"
    if [ "${BASE_FREQ}" -gt 0 ] 2>/dev/null; then
        echo "  参考基准频率:   $(format_freq ${BASE_FREQ})"
    fi
    echo ""

    echo -e "${GREEN}【可用频率档位】${NC}"
    AVAIL=$(cat ${CPU0}/scaling_available_frequencies 2>/dev/null || echo "")
    if [ -n "${AVAIL}" ]; then
        COUNT=0
        for f in ${AVAIL}; do
            COUNT=$((COUNT+1))
            FORMATTED=$(format_freq ${f})
            # 高于硬件最高频率80%标记为高频
            THRESHOLD=$(awk "BEGIN{printf \"%.0f\", ${MAX_HW}*0.8}")
            if [ "${f}" -ge "${THRESHOLD}" ] 2>/dev/null; then
                echo -e "  档位 ${COUNT}: ${f} kHz (${FORMATTED}) ${YELLOW}[高频]${NC}"
            else
                echo "  档位 ${COUNT}: ${f} kHz (${FORMATTED})"
            fi
        done
    else
        echo "  (系统未提供可用频率列表)"
    fi
    echo ""

    echo -e "${GREEN}【可用调节策略】${NC}"
    AVAIL_GOV=$(cat ${CPU0}/scaling_available_governors 2>/dev/null || echo "未知")
    echo "  ${AVAIL_GOV}"
    echo ""

    echo -e "${GREEN}【Boost/睿频 状态】${NC}"
    # 检查多种 boost 接口
    BOOST="不支持"
    BOOST_FILE=""

    if [ -f "${CPU0}/boost" ]; then
        BOOST_FILE="${CPU0}/boost"
        BOOST_VAL=$(cat "${BOOST_FILE}" 2>/dev/null)
    elif [ -f "/sys/devices/system/cpu/cpufreq/boost" ]; then
        BOOST_FILE="/sys/devices/system/cpu/cpufreq/boost"
        BOOST_VAL=$(cat "${BOOST_FILE}" 2>/dev/null)
    elif [ -f "/sys/devices/system/cpu/intel_pstate/no_turbo" ]; then
        # Intel pstate 驱动
        BOOST_FILE="/sys/devices/system/cpu/intel_pstate/no_turbo"
        NO_TURBO=$(cat "${BOOST_FILE}" 2>/dev/null)
        if [ "${NO_TURBO}" = "0" ]; then
            BOOST_VAL=1
        else
            BOOST_VAL=0
        fi
    fi

    if [ -n "${BOOST_VAL}" ]; then
        if [ "${BOOST_VAL}" = "1" ]; then
            echo -e "  睿频/Boost: ${GREEN}已开启${NC}"
        else
            echo -e "  睿频/Boost: ${YELLOW}已关闭${NC}"
        fi
    else
        echo "  睿频/Boost: 不支持或不可用"
    fi

    BOOST_FREQS=$(cat ${CPU0}/scaling_boost_frequencies 2>/dev/null || echo "")
    if [ -n "${BOOST_FREQS}" ]; then
        echo "  Boost 频率档位:"
        for f in ${BOOST_FREQS}; do
            echo "    ${f} kHz ($(format_freq ${f}))"
        done
    fi
    echo ""

    echo -e "${GREEN}【各核心当前频率】${NC}"
    for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
        if [ -d "${cpu}/cpufreq" ]; then
            name=$(basename "${cpu}")
            cur=$(cat "${cpu}/cpufreq/scaling_cur_freq" 2>/dev/null || echo "N/A")
            gov=$(cat "${cpu}/cpufreq/scaling_governor" 2>/dev/null || echo "N/A")
            if [ "${cur}" != "N/A" ]; then
                FORMATTED=$(format_freq ${cur})
                # 检查是否运行在高频
                if [ "${cur}" -ge "${MAX_SW}" ] 2>/dev/null; then
                    echo -e "  ${name}: ${FORMATTED} [${gov}] ${GREEN}● 最高频运行${NC}"
                elif [ "${cur}" -le "${MIN_SW}" ] 2>/dev/null; then
                    echo -e "  ${name}: ${FORMATTED} [${gov}] ${BLUE}○ 最低频运行${NC}"
                else
                    echo "  ${name}: ${FORMATTED} [${gov}]"
                fi
            else
                echo "  ${name}: 无法读取"
            fi
        fi
    done
    echo ""

    echo -e "${GREEN}【频率统计分析】${NC}"
    CUR=$(cat ${CPU0}/scaling_cur_freq 2>/dev/null || echo 0)
    MAX=$(cat ${CPU0}/cpuinfo_max_freq 2>/dev/null || echo 0)
    MIN=$(cat ${CPU0}/cpuinfo_min_freq 2>/dev/null || echo 0)

    if [ "${CUR}" -gt 0 ] && [ "${MAX}" -gt 0 ] && [ "${MIN}" -gt 0 ] 2>/dev/null; then
        RANGE=$((MAX - MIN))
        OFFSET=$((CUR - MIN))
        if [ "${RANGE}" -gt 0 ]; then
            PERCENT=$(awk "BEGIN{printf \"%.1f\", ${OFFSET}*100/${RANGE}}")
            echo "  当前频率位置: ${PERCENT}% (最低 0% ~ 最高 100%)"
        fi

        if [ "${BASE_FREQ}" -gt 0 ] && [ "${CUR}" -gt "${BASE_FREQ}" ] 2>/dev/null; then
            OVER=$((CUR - BASE_FREQ))
            OVER_PCT=$(awk "BEGIN{printf \"%.1f\", ${OVER}*100/${BASE_FREQ}}")
            echo -e "  相对基准频率: ${YELLOW}+$(format_freq ${OVER}) (+${OVER_PCT}%)${NC}"
        fi
    fi
    echo ""

    echo -e "${GREEN}【各频率停留时间 (Top 10)】${NC}"
    TIS="${CPU0}/stats/time_in_state"
    if [ -f "${TIS}" ]; then
        echo "  频率            停留时间      占比"
        echo "  ──────────────  ──────────    ────"

        # 计算总时间
        TOTAL_TICKS=$(awk '{sum+=$2} END{print sum}' "${TIS}" 2>/dev/null || echo 1)
        if [ "${TOTAL_TICKS}" -eq 0 ]; then
            TOTAL_TICKS=1
        fi

        sort -k2 -nr "${TIS}" | head -n 10 | while read -r freq ticks; do
            if [ "${ticks}" -gt 0 ] 2>/dev/null; then
                FORMATTED=$(format_freq ${freq})
                SECS=$(awk "BEGIN{printf \"%.1fs\", ${ticks}/100}")
                PCT=$(awk "BEGIN{printf \"%.1f%%\", ${ticks}*100/${TOTAL_TICKS}}")
                printf "  %-14s  %-12s  %s\n" "${FORMATTED}" "${SECS}" "${PCT}"
            fi
        done
    else
        echo "  (频率统计不可用)"
    fi
    echo ""

    echo -e "${GREEN}【温度信息】${NC}"
    TEMP_FOUND=0
    for tz in /sys/class/thermal/thermal_zone*; do
        if [ -d "${tz}" ]; then
            type=$(cat "${tz}/type" 2>/dev/null || echo "未知")
            temp=$(cat "${tz}/temp" 2>/dev/null || echo "0")
            if [ "${temp}" -gt 0 ] 2>/dev/null; then
                TEMP_FOUND=1
                celsius=$(awk "BEGIN{printf \"%.1f\", ${temp}/1000}")
                # 温度等级判断
                if [ "${temp}" -gt 80000 ] 2>/dev/null; then
                    echo -e "  $(basename ${tz}) (${type}): ${RED}${celsius}°C [危险!]${NC}"
                elif [ "${temp}" -gt 70000 ] 2>/dev/null; then
                    echo -e "  $(basename ${tz}) (${type}): ${RED}${celsius}°C [过热]${NC}"
                elif [ "${temp}" -gt 55000 ] 2>/dev/null; then
                    echo -e "  $(basename ${tz}) (${type}): ${YELLOW}${celsius}°C [偏高]${NC}"
                else
                    echo -e "  $(basename ${tz}) (${type}): ${GREEN}${celsius}°C [正常]${NC}"
                fi
            fi
        fi
    done
    if [ "${TEMP_FOUND}" -eq 0 ]; then
        echo "  (温度传感器不可用)"
    fi
    echo ""

    pause
}

# 修改运行模式菜单
change_mode_menu() {
    while true; do
        clear
        echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗"
        echo -e "║              修改 CPU 运行模式                             ║"
        echo -e "╚════════════════════════════════════════════════════════════╝${NC}"
        echo ""

        if ! check_cpufreq; then
            pause
            return
        fi

        CUR_GOV=$(cat ${CPU0}/scaling_governor 2>/dev/null || echo "未知")
        CUR_MAX=$(cat ${CPU0}/scaling_max_freq 2>/dev/null || echo 0)
        CUR_MIN=$(cat ${CPU0}/scaling_min_freq 2>/dev/null || echo 0)

        echo -e "${GREEN}【当前状态】${NC}"
        echo "  调节策略: ${CUR_GOV}"
        echo "  最大频率: $(format_freq ${CUR_MAX})"
        echo "  最小频率: $(format_freq ${CUR_MIN})"

        # Boost 状态
        if [ -f "${CPU0}/boost" ]; then
            BOOST_VAL=$(cat "${CPU0}/boost" 2>/dev/null)
            if [ "${BOOST_VAL}" = "1" ]; then
                echo -e "  睿频状态: ${GREEN}开启${NC}"
            else
                echo -e "  睿频状态: ${YELLOW}关闭${NC}"
            fi
        elif [ -f "/sys/devices/system/cpu/cpufreq/boost" ]; then
            BOOST_VAL=$(cat "/sys/devices/system/cpu/cpufreq/boost" 2>/dev/null)
            if [ "${BOOST_VAL}" = "1" ]; then
                echo -e "  睿频状态: ${GREEN}开启${NC}"
            else
                echo -e "  睿频状态: ${YELLOW}关闭${NC}"
            fi
        elif [ -f "/sys/devices/system/cpu/intel_pstate/no_turbo" ]; then
            NO_TURBO=$(cat "/sys/devices/system/cpu/intel_pstate/no_turbo" 2>/dev/null)
            if [ "${NO_TURBO}" = "0" ]; then
                echo -e "  睿频状态: ${GREEN}开启${NC}"
            else
                echo -e "  睿频状态: ${YELLOW}关闭${NC}"
            fi
        fi

        echo ""
        echo -e "${YELLOW}【请选择操作】${NC}"
        echo ""
        echo "  1. 切换调节策略 (Governor)"
        echo "  2. 设置最大频率"
        echo "  3. 设置最小频率"
        echo "  4. 开启/关闭 睿频(Boost)"
        echo ""
        echo -e "  ${CYAN}--- 快捷模式 ---${NC}"
        echo "  5. 🚀 性能模式 (最高频率运行)"
        echo "  6. 🔋 省电模式 (最低频率运行)"
        echo "  7. ⚖️  平衡模式 (自动调节)"
        echo ""
        echo "  0. 返回主菜单"
        echo ""
        read -rp "请输入选项 [0-7]: " choice

        case "${choice}" in
            1) change_governor ;;
            2) change_max_freq ;;
            3) change_min_freq ;;
            4) toggle_boost ;;
            5) set_performance_mode ;;
            6) set_powersave_mode ;;
            7) set_balanced_mode ;;
            0) return ;;
            *)
                echo -e "${RED}无效选项，请重新输入${NC}"
                sleep 1
                ;;
        esac
    done
}

# 切换调节策略
change_governor() {
    echo ""
    echo -e "${GREEN}【可用的调节策略】${NC}"
    AVAIL_GOV=$(cat ${CPU0}/scaling_available_governors 2>/dev/null || echo "")
    echo ""
    echo "  ${AVAIL_GOV}"
    echo ""
    echo "策略说明:"
    echo "  performance  - 始终最高频率运行"
    echo "  powersave    - 始终最低频率运行"
    echo "  ondemand     - 根据负载动态调节 (较激进)"
    echo "  conservative - 根据负载动态调节 (较保守)"
    echo "  schedutil    - 由调度器控制 (推荐)"
    echo "  userspace    - 用户手动控制"
    echo ""
    read -rp "请输入要切换的策略 (留空取消): " new_gov

    if [ -z "${new_gov}" ]; then
        echo -e "${YELLOW}已取消${NC}"
        sleep 1
        return
    fi

    SUCCESS=0
    FAILED=0
    for cpu in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
        if echo "${new_gov}" > "${cpu}" 2>/dev/null; then
            SUCCESS=$((SUCCESS+1))
        else
            FAILED=$((FAILED+1))
        fi
    done

    if [ "${SUCCESS}" -gt 0 ]; then
        echo -e "${GREEN}✅ 成功切换 ${SUCCESS} 个核心到: ${new_gov}${NC}"
    fi
    if [ "${FAILED}" -gt 0 ]; then
        echo -e "${YELLOW}⚠️ ${FAILED} 个核心切换失败 (可能需要 root 权限)${NC}"
    fi
    sleep 2
}

# 设置最大频率
change_max_freq() {
    echo ""
    echo -e "${GREEN}【可用频率档位】${NC}"
    AVAIL=$(cat ${CPU0}/scaling_available_frequencies 2>/dev/null || echo "")
    if [ -n "${AVAIL}" ]; then
        echo ""
        for f in ${AVAIL}; do
            echo "  ${f} kHz ($(format_freq ${f}))"
        done
        echo ""
    else
        MAX_HW=$(cat ${CPU0}/cpuinfo_max_freq 2>/dev/null || echo 0)
        MIN_HW=$(cat ${CPU0}/cpuinfo_min_freq 2>/dev/null || echo 0)
        echo ""
        echo "  范围: ${MIN_HW} ~ ${MAX_HW} kHz"
        echo ""
    fi

    read -rp "请输入最大频率 (kHz，留空取消): " new_max

    if [ -z "${new_max}" ]; then
        echo -e "${YELLOW}已取消${NC}"
        sleep 1
        return
    fi

    SUCCESS=0
    FAILED=0
    for cpu in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_max_freq; do
        if echo "${new_max}" > "${cpu}" 2>/dev/null; then
            SUCCESS=$((SUCCESS+1))
        else
            FAILED=$((FAILED+1))
        fi
    done

    if [ "${SUCCESS}" -gt 0 ]; then
        echo -e "${GREEN}✅ 成功设置 ${SUCCESS} 个核心最大频率: $(format_freq ${new_max})${NC}"
    fi
    if [ "${FAILED}" -gt 0 ]; then
        echo -e "${YELLOW}⚠️ ${FAILED} 个核心设置失败${NC}"
    fi
    sleep 2
}

# 设置最小频率
change_min_freq() {
    echo ""
    echo -e "${GREEN}【可用频率档位】${NC}"
    AVAIL=$(cat ${CPU0}/scaling_available_frequencies 2>/dev/null || echo "")
    if [ -n "${AVAIL}" ]; then
        echo ""
        for f in ${AVAIL}; do
            echo "  ${f} kHz ($(format_freq ${f}))"
        done
        echo ""
    else
        MAX_HW=$(cat ${CPU0}/cpuinfo_max_freq 2>/dev/null || echo 0)
        MIN_HW=$(cat ${CPU0}/cpuinfo_min_freq 2>/dev/null || echo 0)
        echo ""
        echo "  范围: ${MIN_HW} ~ ${MAX_HW} kHz"
        echo ""
    fi

    read -rp "请输入最小频率 (kHz，留空取消): " new_min

    if [ -z "${new_min}" ]; then
        echo -e "${YELLOW}已取消${NC}"
        sleep 1
        return
    fi

    SUCCESS=0
    FAILED=0
    for cpu in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_min_freq; do
        if echo "${new_min}" > "${cpu}" 2>/dev/null; then
            SUCCESS=$((SUCCESS+1))
        else
            FAILED=$((FAILED+1))
        fi
    done

    if [ "${SUCCESS}" -gt 0 ]; then
        echo -e "${GREEN}✅ 成功设置 ${SUCCESS} 个核心最小频率: $(format_freq ${new_min})${NC}"
    fi
    if [ "${FAILED}" -gt 0 ]; then
        echo -e "${YELLOW}⚠️ ${FAILED} 个核心设置失败${NC}"
    fi
    sleep 2
}

# 开关睿频/Boost
toggle_boost() {
    echo ""

    # 查找可用的 boost 接口
    BOOST_FILE=""
    BOOST_TYPE=""

    if [ -f "${CPU0}/boost" ]; then
        BOOST_FILE="${CPU0}/boost"
        BOOST_TYPE="generic"
    elif [ -f "/sys/devices/system/cpu/cpufreq/boost" ]; then
        BOOST_FILE="/sys/devices/system/cpu/cpufreq/boost"
        BOOST_TYPE="generic"
    elif [ -f "/sys/devices/system/cpu/intel_pstate/no_turbo" ]; then
        BOOST_FILE="/sys/devices/system/cpu/intel_pstate/no_turbo"
        BOOST_TYPE="intel"
    fi

    if [ -z "${BOOST_FILE}" ]; then
        echo -e "${YELLOW}⚠️ 此系统不支持睿频控制或接口不可用${NC}"
        sleep 2
        return
    fi

    if [ "${BOOST_TYPE}" = "intel" ]; then
        CUR_VAL=$(cat "${BOOST_FILE}" 2>/dev/null)
        if [ "${CUR_VAL}" = "0" ]; then
            # 当前开启，要关闭
            if echo 1 > "${BOOST_FILE}" 2>/dev/null; then
                echo -e "${YELLOW}🔋 睿频已关闭${NC}"
            else
                echo -e "${RED}❌ 操作失败 (需要 root 权限)${NC}"
            fi
        else
            # 当前关闭，要开启
            if echo 0 > "${BOOST_FILE}" 2>/dev/null; then
                echo -e "${GREEN}🚀 睿频已开启${NC}"
            else
                echo -e "${RED}❌ 操作失败 (需要 root 权限)${NC}"
            fi
        fi
    else
        CUR_VAL=$(cat "${BOOST_FILE}" 2>/dev/null)
        if [ "${CUR_VAL}" = "1" ]; then
            if echo 0 > "${BOOST_FILE}" 2>/dev/null; then
                echo -e "${YELLOW}🔋 睿频已关闭${NC}"
            else
                echo -e "${RED}❌ 操作失败 (需要 root 权限)${NC}"
            fi
        else
            if echo 1 > "${BOOST_FILE}" 2>/dev/null; then
                echo -e "${GREEN}🚀 睿频已开启${NC}"
            else
                echo -e "${RED}❌ 操作失败 (需要 root 权限)${NC}"
            fi
        fi
    fi
    sleep 2
}

# 一键性能模式
set_performance_mode() {
    echo ""
    echo -e "${CYAN}正在切换到性能模式...${NC}"

    MAX_FREQ=$(cat ${CPU0}/cpuinfo_max_freq 2>/dev/null || echo "")

    SUCCESS=0
    for cpu in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
        echo "performance" > "${cpu}/scaling_governor" 2>/dev/null && SUCCESS=$((SUCCESS+1))
        if [ -n "${MAX_FREQ}" ]; then
            echo "${MAX_FREQ}" > "${cpu}/scaling_min_freq" 2>/dev/null
            echo "${MAX_FREQ}" > "${cpu}/scaling_max_freq" 2>/dev/null
        fi
    done

    # 开启 boost
    if [ -f "${CPU0}/boost" ]; then
        echo 1 > "${CPU0}/boost" 2>/dev/null
    elif [ -f "/sys/devices/system/cpu/cpufreq/boost" ]; then
        echo 1 > "/sys/devices/system/cpu/cpufreq/boost" 2>/dev/null
    elif [ -f "/sys/devices/system/cpu/intel_pstate/no_turbo" ]; then
        echo 0 > "/sys/devices/system/cpu/intel_pstate/no_turbo" 2>/dev/null
    fi

    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════╗"
    echo -e "║  🚀 已切换到性能模式                   ║"
    echo -e "╚════════════════════════════════════════╝${NC}"
    echo ""
    echo "  调节策略: performance"
    echo "  频率锁定: $(format_freq ${MAX_FREQ})"
    echo "  睿频状态: 开启"
    echo ""
    echo -e "${YELLOW}提示: 此模式功耗较高，发热量增加${NC}"
    sleep 3
}

# 一键省电模式
set_powersave_mode() {
    echo ""
    echo -e "${CYAN}正在切换到省电模式...${NC}"

    MIN_FREQ=$(cat ${CPU0}/cpuinfo_min_freq 2>/dev/null || echo "")

    SUCCESS=0
    for cpu in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
        echo "powersave" > "${cpu}/scaling_governor" 2>/dev/null && SUCCESS=$((SUCCESS+1))
        if [ -n "${MIN_FREQ}" ]; then
            echo "${MIN_FREQ}" > "${cpu}/scaling_min_freq" 2>/dev/null
            echo "${MIN_FREQ}" > "${cpu}/scaling_max_freq" 2>/dev/null
        fi
    done

    # 关闭 boost
    if [ -f "${CPU0}/boost" ]; then
        echo 0 > "${CPU0}/boost" 2>/dev/null
    elif [ -f "/sys/devices/system/cpu/cpufreq/boost" ]; then
        echo 0 > "/sys/devices/system/cpu/cpufreq/boost" 2>/dev/null
    elif [ -f "/sys/devices/system/cpu/intel_pstate/no_turbo" ]; then
        echo 1 > "/sys/devices/system/cpu/intel_pstate/no_turbo" 2>/dev/null
    fi

    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════╗"
    echo -e "║  🔋 已切换到省电模式                   ║"
    echo -e "╚════════════════════════════════════════╝${NC}"
    echo ""
    echo "  调节策略: powersave"
    echo "  频率锁定: $(format_freq ${MIN_FREQ})"
    echo "  睿频状态: 关闭"
    echo ""
    echo -e "${YELLOW}提示: 此模式性能受限，适合低负载场景${NC}"
    sleep 3
}

# 一键平衡模式
set_balanced_mode() {
    echo ""
    echo -e "${CYAN}正在切换到平衡模式...${NC}"

    AVAIL_GOV=$(cat ${CPU0}/scaling_available_governors 2>/dev/null || echo "")
    MIN_FREQ=$(cat ${CPU0}/cpuinfo_min_freq 2>/dev/null || echo "")
    MAX_FREQ=$(cat ${CPU0}/cpuinfo_max_freq 2>/dev/null || echo "")

    # 优先选择 schedutil，其次 ondemand，再次 conservative
    if echo "${AVAIL_GOV}" | grep -qw "schedutil"; then
        GOV="schedutil"
    elif echo "${AVAIL_GOV}" | grep -qw "ondemand"; then
        GOV="ondemand"
    elif echo "${AVAIL_GOV}" | grep -qw "conservative"; then
        GOV="conservative"
    else
        GOV="performance"
    fi

    SUCCESS=0
    for cpu in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
        echo "${GOV}" > "${cpu}/scaling_governor" 2>/dev/null && SUCCESS=$((SUCCESS+1))
        if [ -n "${MIN_FREQ}" ]; then
            echo "${MIN_FREQ}" > "${cpu}/scaling_min_freq" 2>/dev/null
        fi
        if [ -n "${MAX_FREQ}" ]; then
            echo "${MAX_FREQ}" > "${cpu}/scaling_max_freq" 2>/dev/null
        fi
    done

    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════╗"
    echo -e "║  ⚖️  已切换到平衡模式                   ║"
    echo -e "╚════════════════════════════════════════╝${NC}"
    echo ""
    echo "  调节策略: ${GOV}"
    echo "  频率范围: $(format_freq ${MIN_FREQ}) ~ $(format_freq ${MAX_FREQ})"
    echo "  运行方式: 根据负载自动调节"
    echo ""
    echo -e "${YELLOW}提示: 推荐日常使用，兼顾性能与功耗${NC}"
    sleep 3
}

# 实时监控
realtime_monitor() {
    echo ""
    echo -e "${CYAN}实时监控模式 (按 Ctrl+C 返回主菜单)${NC}"
    echo ""
    sleep 1

    # 捕获 Ctrl+C 返回菜单而不是退出
    trap 'echo ""; echo "正在返回主菜单..."; sleep 1; return' INT

    while true; do
        clear
        echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗"
        echo -e "║        CPU 实时监控 (每秒刷新，Ctrl+C 返回)               ║"
        echo -e "╚════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo "  时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""

        # 表头
        printf "  %-8s  %-14s  %-12s  %s\n" "核心" "当前频率" "策略" "状态"
        echo "  ────────  ──────────────  ────────────  ──────"

        MAX_FREQ=$(cat ${CPU0}/cpuinfo_max_freq 2>/dev/null || echo 0)
        MIN_FREQ=$(cat ${CPU0}/cpuinfo_min_freq 2>/dev/null || echo 0)

        for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
            if [ -d "${cpu}/cpufreq" ]; then
                name=$(basename "${cpu}")
                cur=$(cat "${cpu}/cpufreq/scaling_cur_freq" 2>/dev/null || echo "0")
                gov=$(cat "${cpu}/cpufreq/scaling_governor" 2>/dev/null || echo "N/A")
                formatted=$(format_freq ${cur})

                if [ "${cur}" -ge "${MAX_FREQ}" ] 2>/dev/null; then
                    status="${GREEN}● 最高${NC}"
                elif [ "${cur}" -le "${MIN_FREQ}" ] 2>/dev/null; then
                    status="${BLUE}○ 最低${NC}"
                else
                    status="◐ 中等"
                fi

                printf "  %-8s  %-14s  %-12s  " "${name}" "${formatted}" "${gov}"
                echo -e "${status}"
            fi
        done

        echo ""
        echo "  【温度】"
        for tz in /sys/class/thermal/thermal_zone*; do
            if [ -d "${tz}" ]; then
                type=$(cat "${tz}/type" 2>/dev/null || echo "未知")
                temp=$(cat "${tz}/temp" 2>/dev/null || echo "0")
                if [ "${temp}" -gt 0 ] 2>/dev/null; then
                    celsius=$(awk "BEGIN{printf \"%.1f\", ${temp}/1000}")
                    if [ "${temp}" -gt 70000 ]; then
                        echo -e "    ${type}: ${RED}${celsius}°C${NC}"
                    elif [ "${temp}" -gt 55000 ]; then
                        echo -e "    ${type}: ${YELLOW}${celsius}°C${NC}"
                    else
                        echo -e "    ${type}: ${GREEN}${celsius}°C${NC}"
                    fi
                fi
            fi
        done

        echo ""
        echo -e "  ${YELLOW}按 Ctrl+C 返回主菜单${NC}"

        sleep 1
    done

    trap - INT
}

# 主菜单
main_menu() {
    while true; do
        clear

        # 获取基本信息用于显示
        get_system_info

        echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗"
        echo -e "║           Linux CPU 频率管理工具                           ║"
        echo -e "║                 (通用版 v1.0)                              ║"
        echo -e "╚════════════════════════════════════════════════════════════╝${NC}"
        echo ""

        # 快速显示当前状态
        if [ -d "${CPU0}" ]; then
            CUR=$(cat ${CPU0}/scaling_cur_freq 2>/dev/null || echo 0)
            MAX=$(cat ${CPU0}/cpuinfo_max_freq 2>/dev/null || echo 0)
            GOV=$(cat ${CPU0}/scaling_governor 2>/dev/null || echo "未知")

            echo -e "${GREEN}【系统概要】${NC}"
            echo "  CPU 型号:   ${CPU_MODEL}"
            echo "  CPU 架构:   ${CPU_ARCH}"
            echo "  核心数量:   ${CPU_CORES}"
            echo ""
            echo -e "${GREEN}【运行状态】${NC}"
            echo "  当前频率:   $(format_freq ${CUR})"
            echo "  最高频率:   $(format_freq ${MAX})"
            echo "  调节策略:   ${GOV}"
        else
            echo -e "${RED}【警告】cpufreq 不可用${NC}"
            echo ""
            echo "  CPU 型号: ${CPU_MODEL}"
            echo "  CPU 架构: ${CPU_ARCH}"
        fi

        echo ""
        echo -e "${YELLOW}【请选择操作】${NC}"
        echo ""
        echo "  1. 📊 查看详细 CPU 信息"
        echo "  2. ⚙️  修改 CPU 运行模式"
        echo "  3. 📈 实时监控 (每秒刷新)"
        echo ""
        echo "  0. 退出程序"
        echo ""
        read -rp "请输入选项 [0-3]: " choice

        case "${choice}" in
            1) show_cpu_info ;;
            2) change_mode_menu ;;
            3) realtime_monitor ;;
            0)
                clear
                echo -e "${GREEN}感谢使用，再见！${NC}"
                echo ""
                exit 0
                ;;
            *)
                echo -e "${RED}无效选项，请重新输入${NC}"
                sleep 1
                ;;
        esac
    done
}

# 检查 root 权限
if [ "$(id -u)" != "0" ]; then
    echo -e "${YELLOW}╔════════════════════════════════════════════════════════════╗"
    echo -e "║  提示: 部分功能需要 root 权限才能正常使用                 ║"
    echo -e "╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "建议使用: sudo $0"
    echo ""
    read -rp "是否继续运行? [y/N]: " confirm
    if [ "${confirm}" != "y" ] && [ "${confirm}" != "Y" ]; then
        exit 0
    fi
    echo ""
fi

# 启动主菜单
main_menu
