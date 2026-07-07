#!/bin/bash

STOCK_FREQ=998400
MAX_OC_FREQ=2100000
CPU0="/sys/devices/system/cpu/cpu0/cpufreq"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 暂停等待按键
pause() {
    echo ""
    read -rp "按 Enter 键返回主菜单..."
}

# 检查 cpufreq 是否可用
check_cpufreq() {
    if [ ! -d "${CPU0}" ]; then
        echo -e "${RED}❌ cpufreq 目录不存在，内核可能未启用 CONFIG_CPU_FREQ${NC}"
        return 1
    fi
    return 0
}

# 显示 CPU 信息和超频状态
show_cpu_info() {
    clear
    echo -e "${CYAN}========================================"
    echo " CPU 频率/超频 检测"
    echo -e "========================================${NC}"
    echo ""

    if ! check_cpufreq; then
        echo ""
        echo -e "${YELLOW}=== 内核配置检查 ===${NC}"
        zcat /proc/config.gz 2>/dev/null | grep -i "CPU_FREQ" || echo "无法读取"
        echo ""
        echo -e "${YELLOW}=== dmesg 相关信息 ===${NC}"
        dmesg | grep -i cpufreq | tail -n 10 || true
        pause
        return
    fi

    echo -e "${GREEN}=== 基本信息 ===${NC}"
    echo "  驱动:     $(cat ${CPU0}/scaling_driver 2>/dev/null || echo N/A)"
    echo "  策略:     $(cat ${CPU0}/scaling_governor 2>/dev/null || echo N/A)"
    echo "  CPU 核数: $(ls -d /sys/devices/system/cpu/cpu[0-9]* 2>/dev/null | wc -l)"
    echo ""

    echo -e "${GREEN}=== 频率限制 ===${NC}"
    MIN_HW=$(cat ${CPU0}/cpuinfo_min_freq 2>/dev/null || echo 0)
    MAX_HW=$(cat ${CPU0}/cpuinfo_max_freq 2>/dev/null || echo 0)
    MIN_SW=$(cat ${CPU0}/scaling_min_freq 2>/dev/null || echo 0)
    MAX_SW=$(cat ${CPU0}/scaling_max_freq 2>/dev/null || echo 0)
    echo "  硬件最低: ${MIN_HW} kHz ($(awk "BEGIN{printf \"%.4f\", ${MIN_HW}/1000000}") GHz)"
    echo "  硬件最高: ${MAX_HW} kHz ($(awk "BEGIN{printf \"%.4f\", ${MAX_HW}/1000000}") GHz)"
    echo "  软件最低: ${MIN_SW} kHz ($(awk "BEGIN{printf \"%.4f\", ${MIN_SW}/1000000}") GHz)"
    echo "  软件最高: ${MAX_SW} kHz ($(awk "BEGIN{printf \"%.4f\", ${MAX_SW}/1000000}") GHz)"
    echo ""

    echo -e "${GREEN}=== 可用频率档位 ===${NC}"
    AVAIL=$(cat ${CPU0}/scaling_available_frequencies 2>/dev/null || echo "")
    if [ -n "${AVAIL}" ]; then
        COUNT=0
        for f in ${AVAIL}; do
            COUNT=$((COUNT+1))
            ghz=$(awk "BEGIN{printf \"%.4f\", ${f}/1000000}")
            if [ "${f}" -gt "${STOCK_FREQ}" ] 2>/dev/null; then
                echo -e "  档位 ${COUNT}: ${f} kHz (${ghz} GHz) ${RED}[超频]${NC}"
            else
                echo "  档位 ${COUNT}: ${f} kHz (${ghz} GHz)"
            fi
        done
    else
        echo "  (无法读取)"
    fi
    echo ""

    echo -e "${GREEN}=== Boost 状态 ===${NC}"
    BOOST=$(cat ${CPU0}/boost 2>/dev/null || echo "N/A")
    if [ "${BOOST}" = "1" ]; then
        echo -e "  boost 开关: ${GREEN}开启${NC}"
    elif [ "${BOOST}" = "0" ]; then
        echo -e "  boost 开关: ${YELLOW}关闭${NC}"
    else
        echo "  boost 开关: ${BOOST}"
    fi
    BOOST_FREQS=$(cat ${CPU0}/scaling_boost_frequencies 2>/dev/null || echo "")
    if [ -n "${BOOST_FREQS}" ]; then
        echo "  boost 频率:"
        for f in ${BOOST_FREQS}; do
            echo "    ${f} kHz ($(awk "BEGIN{printf \"%.4f\", ${f}/1000000}") GHz)"
        done
    fi
    echo ""

    echo -e "${GREEN}=== 各核心当前频率 ===${NC}"
    for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
        name=$(basename "${cpu}")
        cur=$(cat "${cpu}/cpufreq/scaling_cur_freq" 2>/dev/null || echo "N/A")
        if [ "${cur}" != "N/A" ]; then
            ghz=$(awk "BEGIN{printf \"%.4f\", ${cur}/1000000}")
            if [ "${cur}" -gt "${STOCK_FREQ}" ] 2>/dev/null; then
                echo -e "  ${name}: ${cur} kHz (${ghz} GHz) ${RED}[超频运行中]${NC}"
            else
                echo "  ${name}: ${cur} kHz (${ghz} GHz)"
            fi
        else
            echo "  ${name}: 无法读取"
        fi
    done
    echo ""

    echo -e "${GREEN}=== 超频幅度计算 ===${NC}"
    CUR=$(cat ${CPU0}/scaling_cur_freq 2>/dev/null || echo 0)
    MAX=$(cat ${CPU0}/cpuinfo_max_freq 2>/dev/null || echo 0)

    echo "   默认最高频: ${STOCK_FREQ} kHz ($(awk "BEGIN{printf \"%.4f\", ${STOCK_FREQ}/1000000}") GHz)"
    echo "  理论超频上限:       ${MAX_OC_FREQ} kHz ($(awk "BEGIN{printf \"%.4f\", ${MAX_OC_FREQ}/1000000}") GHz)"
    echo ""

    echo -e "  ${YELLOW}--- 当前频率 vs 默认 ---${NC}"
    if [ "${CUR}" -gt 0 ] 2>/dev/null; then
        awk -v c="${CUR}" -v s="${STOCK_FREQ}" 'BEGIN {
            printf "  当前频率:   %.4f GHz\n", c/1000000
            printf "  超出默认:   %.4f GHz\n", (c-s)/1000000
            printf "  增幅:       %.2f%%\n", (c-s)*100/s
        }'
    fi
    echo ""

    echo -e "  ${YELLOW}--- 硬件最高频 vs 默认 ---${NC}"
    if [ "${MAX}" -gt 0 ] 2>/dev/null; then
        awk -v m="${MAX}" -v s="${STOCK_FREQ}" -v t="${MAX_OC_FREQ}" 'BEGIN {
            printf "  最高频率:   %.4f GHz\n", m/1000000
            printf "  超出默认:   %.4f GHz\n", (m-s)/1000000
            printf "  增幅:       %.2f%%\n", (m-s)*100/s
            printf "  距离2.1GHz: %.4f GHz (%.2f%%)\n", (t-m)/1000000, (t-m)*100/t
        }'
    fi
    echo ""

    echo -e "${GREEN}=== 各频率停留时间 (Top 10) ===${NC}"
    TIS="${CPU0}/stats/time_in_state"
    if [ -f "${TIS}" ]; then
        echo "  频率(kHz)     时间        GHz"
        echo "  ───────────   ─────────   ────────"
        sort -k2 -nr "${TIS}" | head -n 10 | while read -r freq ticks; do
            if [ "${ticks}" -gt 0 ] 2>/dev/null; then
                secs=$(awk "BEGIN{printf \"%.1fs\", ${ticks}/100}")
                ghz=$(awk "BEGIN{printf \"%.4f\", ${freq}/1000000}")
                printf "  %-12s  %-10s  %s\n" "${freq}" "${secs}" "${ghz}"
            fi
        done
    else
        echo "  (不可用)"
    fi
    echo ""

    echo -e "${GREEN}=== 温度 ===${NC}"
    for tz in /sys/class/thermal/thermal_zone*; do
        type=$(cat "${tz}/type" 2>/dev/null || echo "unknown")
        temp=$(cat "${tz}/temp" 2>/dev/null || echo "N/A")
        if [ "${temp}" != "N/A" ] && [ "${temp}" -gt 0 ] 2>/dev/null; then
            celsius=$(awk "BEGIN{printf \"%.1f\", ${temp}/1000}")
            if [ "${temp}" -gt 70000 ] 2>/dev/null; then
                echo -e "  $(basename ${tz}) (${type}): ${RED}${celsius}°C [过热!]${NC}"
            elif [ "${temp}" -gt 55000 ] 2>/dev/null; then
                echo -e "  $(basename ${tz}) (${type}): ${YELLOW}${celsius}°C${NC}"
            else
                echo -e "  $(basename ${tz}) (${type}): ${GREEN}${celsius}°C${NC}"
            fi
        fi
    done
    echo ""

    pause
}

# 修改运行模式菜单
change_mode_menu() {
    while true; do
        clear
        echo -e "${CYAN}========================================"
        echo "  修改 CPU 运行模式"
        echo -e "========================================${NC}"
        echo ""

        if ! check_cpufreq; then
            pause
            return
        fi

        CUR_GOV=$(cat ${CPU0}/scaling_governor 2>/dev/null || echo "N/A")
        CUR_MAX=$(cat ${CPU0}/scaling_max_freq 2>/dev/null || echo "N/A")
        CUR_MIN=$(cat ${CPU0}/scaling_min_freq 2>/dev/null || echo "N/A")
        CUR_BOOST=$(cat ${CPU0}/boost 2>/dev/null || echo "N/A")

        echo -e "${GREEN}当前状态:${NC}"
        echo "  调频策略: ${CUR_GOV}"
        echo "  最大频率: ${CUR_MAX} kHz"
        echo "  最小频率: ${CUR_MIN} kHz"
        echo "  Boost:    ${CUR_BOOST}"
        echo ""

        echo -e "${YELLOW}请选择操作:${NC}"
        echo ""
        echo "  1. 切换调频策略 (Governor)"
        echo "  2. 设置最大频率"
        echo "  3. 设置最小频率"
        echo "  4. 开启/关闭 Boost"
        echo "  5. 一键性能模式 (锁最高频)"
        echo "  6. 一键省电模式 (锁最低频)"
        echo "  7. 一键平衡模式 (schedutil/ondemand)"
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
            *) echo -e "${RED}无效选项${NC}"; sleep 1 ;;
        esac
    done
}

# 切换调频策略
change_governor() {
    echo ""
    echo -e "${GREEN}可用的调频策略:${NC}"
    AVAIL_GOV=$(cat ${CPU0}/scaling_available_governors 2>/dev/null || echo "")
    echo "  ${AVAIL_GOV}"
    echo ""
    read -rp "请输入要切换的策略: " new_gov

    if [ -z "${new_gov}" ]; then
        echo -e "${YELLOW}已取消${NC}"
        sleep 1
        return
    fi

    for cpu in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
        echo "${new_gov}" > "${cpu}" 2>/dev/null
    done

    echo -e "${GREEN}已尝试切换到: ${new_gov}${NC}"
    sleep 1
}

# 设置最大频率
change_max_freq() {
    echo ""
    echo -e "${GREEN}可用频率:${NC}"
    AVAIL=$(cat ${CPU0}/scaling_available_frequencies 2>/dev/null || echo "")
    echo "  ${AVAIL}"
    echo ""
    read -rp "请输入最大频率 (kHz): " new_max

    if [ -z "${new_max}" ]; then
        echo -e "${YELLOW}已取消${NC}"
        sleep 1
        return
    fi

    for cpu in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_max_freq; do
        echo "${new_max}" > "${cpu}" 2>/dev/null
    done

    echo -e "${GREEN}已尝试设置最大频率: ${new_max} kHz${NC}"
    sleep 1
}

# 设置最小频率
change_min_freq() {
    echo ""
    echo -e "${GREEN}可用频率:${NC}"
    AVAIL=$(cat ${CPU0}/scaling_available_frequencies 2>/dev/null || echo "")
    echo "  ${AVAIL}"
    echo ""
    read -rp "请输入最小频率 (kHz): " new_min

    if [ -z "${new_min}" ]; then
        echo -e "${YELLOW}已取消${NC}"
        sleep 1
        return
    fi

    for cpu in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_min_freq; do
        echo "${new_min}" > "${cpu}" 2>/dev/null
    done

    echo -e "${GREEN}已尝试设置最小频率: ${new_min} kHz${NC}"
    sleep 1
}

# 开关 Boost
toggle_boost() {
    CUR_BOOST=$(cat ${CPU0}/boost 2>/dev/null || echo "N/A")

    if [ "${CUR_BOOST}" = "1" ]; then
        echo 0 > ${CPU0}/boost 2>/dev/null
        echo -e "${YELLOW}Boost 已关闭${NC}"
    elif [ "${CUR_BOOST}" = "0" ]; then
        echo 1 > ${CPU0}/boost 2>/dev/null
        echo -e "${GREEN}Boost 已开启${NC}"
    else
        echo -e "${RED}Boost 不可用${NC}"
    fi
    sleep 1
}

# 一键性能模式
set_performance_mode() {
    echo ""
    echo -e "${YELLOW}正在切换到性能模式...${NC}"

    MAX_FREQ=$(cat ${CPU0}/cpuinfo_max_freq 2>/dev/null || echo "")

    for cpu in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
        echo "performance" > "${cpu}/scaling_governor" 2>/dev/null
        if [ -n "${MAX_FREQ}" ]; then
            echo "${MAX_FREQ}" > "${cpu}/scaling_min_freq" 2>/dev/null
            echo "${MAX_FREQ}" > "${cpu}/scaling_max_freq" 2>/dev/null
        fi
    done

    # 开启 boost
    echo 1 > ${CPU0}/boost 2>/dev/null

    echo -e "${GREEN}✅ 已切换到性能模式${NC}"
    echo "   策略: performance"
    echo "   频率: 锁定最高 ${MAX_FREQ} kHz"
    echo "   Boost: 开启"
    sleep 2
}

# 一键省电模式
set_powersave_mode() {
    echo ""
    echo -e "${YELLOW}正在切换到省电模式...${NC}"

    MIN_FREQ=$(cat ${CPU0}/cpuinfo_min_freq 2>/dev/null || echo "")

    for cpu in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
        echo "powersave" > "${cpu}/scaling_governor" 2>/dev/null
        if [ -n "${MIN_FREQ}" ]; then
            echo "${MIN_FREQ}" > "${cpu}/scaling_min_freq" 2>/dev/null
            echo "${MIN_FREQ}" > "${cpu}/scaling_max_freq" 2>/dev/null
        fi
    done

    # 关闭 boost
    echo 0 > ${CPU0}/boost 2>/dev/null

    echo -e "${GREEN}✅ 已切换到省电模式${NC}"
    echo "   策略: powersave"
    echo "   频率: 锁定最低 ${MIN_FREQ} kHz"
    echo "   Boost: 关闭"
    sleep 2
}

# 一键平衡模式
set_balanced_mode() {
    echo ""
    echo -e "${YELLOW}正在切换到平衡模式...${NC}"

    AVAIL_GOV=$(cat ${CPU0}/scaling_available_governors 2>/dev/null || echo "")
    MIN_FREQ=$(cat ${CPU0}/cpuinfo_min_freq 2>/dev/null || echo "")
    MAX_FREQ=$(cat ${CPU0}/cpuinfo_max_freq 2>/dev/null || echo "")

    # 优先选择 schedutil，其次 ondemand
    if echo "${AVAIL_GOV}" | grep -q "schedutil"; then
        GOV="schedutil"
    elif echo "${AVAIL_GOV}" | grep -q "ondemand"; then
        GOV="ondemand"
    else
        GOV="performance"
    fi

    for cpu in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
        echo "${GOV}" > "${cpu}/scaling_governor" 2>/dev/null
        if [ -n "${MIN_FREQ}" ]; then
            echo "${MIN_FREQ}" > "${cpu}/scaling_min_freq" 2>/dev/null
        fi
        if [ -n "${MAX_FREQ}" ]; then
            echo "${MAX_FREQ}" > "${cpu}/scaling_max_freq" 2>/dev/null
        fi
    done

    echo -e "${GREEN}✅ 已切换到平衡模式${NC}"
    echo "   策略: ${GOV}"
    echo "   频率: ${MIN_FREQ} ~ ${MAX_FREQ} kHz (动态调节)"
    sleep 2
}

# 实时监控
realtime_monitor() {
    echo ""
    echo -e "${CYAN}实时监控模式 (按 Ctrl+C 退出)${NC}"
    echo ""
    sleep 1

    while true; do
        clear
        echo -e "${CYAN}=== CPU 实时监控 (每秒刷新) ===${NC}"
        echo ""
        echo "时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""

        echo "核心      频率(MHz)     策略"
        echo "────      ─────────     ────"
        for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
            name=$(basename "${cpu}")
            cur=$(cat "${cpu}/cpufreq/scaling_cur_freq" 2>/dev/null || echo "0")
            gov=$(cat "${cpu}/cpufreq/scaling_governor" 2>/dev/null || echo "N/A")
            mhz=$(awk "BEGIN{printf \"%.1f\", ${cur}/1000}")
            printf "%-8s  %-12s  %s\n" "${name}" "${mhz}" "${gov}"
        done

        echo ""
        echo "温度:"
        for tz in /sys/class/thermal/thermal_zone*; do
            type=$(cat "${tz}/type" 2>/dev/null || echo "unknown")
            temp=$(cat "${tz}/temp" 2>/dev/null || echo "0")
            celsius=$(awk "BEGIN{printf \"%.1f\", ${temp}/1000}")
            echo "  ${type}: ${celsius}°C"
        done

        echo ""
        echo -e "${YELLOW}按 Ctrl+C 返回主菜单${NC}"

        sleep 1
    done
}

# 主菜单
main_menu() {
    while true; do
        clear
        echo -e "${CYAN}========================================"
        echo "   CPU 频率管理工具"
        echo "   最高超频参考: 2.1 GHz"
        echo -e "========================================${NC}"
        echo ""

        # 快速显示当前状态
        if [ -d "${CPU0}" ]; then
            CUR=$(cat ${CPU0}/scaling_cur_freq 2>/dev/null || echo "N/A")
            MAX=$(cat ${CPU0}/cpuinfo_max_freq 2>/dev/null || echo "N/A")
            GOV=$(cat ${CPU0}/scaling_governor 2>/dev/null || echo "N/A")

            if [ "${CUR}" != "N/A" ]; then
                CUR_GHZ=$(awk "BEGIN{printf \"%.4f\", ${CUR}/1000000}")
            else
                CUR_GHZ="N/A"
            fi

            if [ "${MAX}" != "N/A" ]; then
                MAX_GHZ=$(awk "BEGIN{printf \"%.4f\", ${MAX}/1000000}")
            else
                MAX_GHZ="N/A"
            fi

            echo -e "${GREEN}当前状态:${NC}"
            echo "  当前频率: ${CUR_GHZ} GHz"
            echo "  最高频率: ${MAX_GHZ} GHz"
            echo "  调频策略: ${GOV}"
        else
            echo -e "${RED}cpufreq 不可用${NC}"
        fi

        echo ""
        echo -e "${YELLOW}请选择操作:${NC}"
        echo ""
        echo "  1. 查看详细 CPU 信息和超频状态"
        echo "  2. 修改 CPU 运行模式"
        echo "  3. 实时监控 (每秒刷新)"
        echo ""
        echo "  0. 退出"
        echo ""
        read -rp "请输入选项 [0-3]: " choice

        case "${choice}" in
            1) show_cpu_info ;;
            2) change_mode_menu ;;
            3) realtime_monitor ;;
            0)
                clear
                echo -e "${GREEN}再见！${NC}"
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
    echo -e "${YELLOW}提示: 部分功能需要 root 权限${NC}"
    echo "建议使用: sudo $0"
    echo ""
    read -rp "继续运行? [y/N]: " confirm
    if [ "${confirm}" != "y" ] && [ "${confirm}" != "Y" ]; then
        exit 0
    fi
fi

# 启动主菜单
main_menu
