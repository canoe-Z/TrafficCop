#!/bin/bash
WORK_DIR="/root/TrafficCop"
CONFIG_FILE="$WORK_DIR/traffic_monitor_config"
LOG_FILE="$WORK_DIR/traffic_monitor.log"
SCRIPT_PATH="$WORK_DIR/traffic_monitor.sh"
LOCK_FILE="$WORK_DIR/traffic_monitor.lock"

echo "-----------------------------------------------------" | tee -a "$LOG_FILE"
echo "$(date '+%Y-%m-%d %H:%M:%S') 当前版本：1.0.84" | tee -a "$LOG_FILE"

# 在脚本开始时杀死所有其他 traffic_monitor.sh 进程
kill_other_instances() {
    local current_pid=$$
    local script_name=$(basename "\$0")
    for pid in $(pgrep -f "$script_name"); do
        if [ "$pid" != "$current_pid" ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') 终止其他脚本实例 (PID: $pid)" | tee -a "$LOG_FILE"
            kill $pid
        fi
    done
}

check_and_install_packages() {
    local packages=("vnstat" "jq" "bc" "iproute2" "coreutils" "grep" "tzdata" "pidof")
    local need_install=false

    for package in "${packages[@]}"; do
        if ! apk info -e "$package" >/dev/null 2>&1; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') $package 未安装，将进行安装..." | tee -a "$LOG_FILE"
            need_install=true
            break
        fi
    done

    if $need_install; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 正在更新软件包列表..." | tee -a "$LOG_FILE"
        if ! apk update; then
            echo "$(date '+%Y-%m-%d %H:%M-%S') 更新软件包列表失败，请检查网络连接和系统状态。" | tee -a "$LOG_FILE"
            return 1
        fi

        for package in "${packages[@]}"; do
            if ! apk info -e "$package" >/dev/null 2>&1; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') 正在安装 $package..." | tee -a "$LOG_FILE"
                if apk add "$package"; then
                    echo "$(date '+%Y-%m-%d %H:%M:%S') $package 安装成功" | tee -a "$LOG_FILE"
                else
                    echo "$(date '+%Y-%m-%d %H:%M:%S') $package 未安装，请手动检查并安装。" | tee -a "$LOG_FILE"
                    return 1
                fi
            fi
        done
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') 所有必要的软件包已安装" | tee -a "$LOG_FILE"
    fi
    # 验证 tc 命令是否可用
    if ! command -v tc &>/dev/null; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 警告：'tc' 命令不可用，可能影响限速功能。" | tee -a "$LOG_FILE"
    fi

    # 获取 vnstat 版本
    local vnstat_version=$(vnstat --version 2>&1 | head -n 1)
    echo "$(date '+%Y-%m-%d %H:%M:%S') vnstat 版本: $vnstat_version" | tee -a "$LOG_FILE"

    # 获取主要网络接口
    local main_interface=$(ip route | grep default | sed -e 's/^.*dev \([^ ]*\).*$/\1/' | head -n 1)
    echo "$(date '+%Y-%m-%d %H:%M:%S') 主要网络接口: $main_interface" | tee -a "$LOG_FILE"

    # 配置vnstatd
    rc-update add vnstatd
    vnstatd -d
    echo "$(date '+%Y-%m-%d %H:%M:%S') vnstatd 服务启动成功" | tee -a "$LOG_FILE"

    # 配置 vnstat
    if [[ ! -f "/etc/vnstat.conf" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') vnstat 配置文件不存在" | tee -a "$LOG_FILE"
        exit 1
    fi
    sed -i \
        -e 's/;UpdateInterval 20/UpdateInterval 20/' \
        -e 's/;PollInterval 5/PollInterval 2/' \
        -e 's/;SaveInterval 5/SaveInterval 1/' \
        "/etc/vnstat.conf"
    echo "$(date '+%Y-%m-%d %H:%M:%S') 已更新 vnstat 配置文件" | tee -a "$LOG_FILE"

    # 获取 vnstat 统计开始时间
    if [ -n "$main_interface" ]; then
        local vnstat_json=$(vnstat -i "$main_interface" --json d)
        local vnstat_start_time=$(echo "$vnstat_json" | jq -r '.interfaces[0].created.date | "\(.year)-\(.month | tostring | if length == 1 then "0" + . else . end)-\(.day | tostring | if length == 1 then "0" + . else . end)"')

        if [ -n "$vnstat_start_time" ] && [ "$vnstat_start_time" != "null-null-null" ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') vnstat 统计开始日期: $vnstat_start_time，在此之前的流量不会被纳入统计！" | tee -a "$LOG_FILE"
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') 无法获取 vnstat 统计开始时间" | tee -a "$LOG_FILE"
            echo "vnstat JSON 输出: $vnstat_json" | tee -a "$LOG_FILE"
        fi
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') 无法获取主要网络接口" | tee -a "$LOG_FILE"
    fi
}

# 检查配置和定时任务
check_existing_setup() {
    if [ -s "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S') 配置已存在" | tee -a "$LOG_FILE"
        if crontab -l 2>/dev/null | grep -q "$SCRIPT_PATH --run"; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') 每分钟一次的定时任务已在执行。" | tee -a "$LOG_FILE"
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') 警告：定时任务未找到，可能需要重新设置。" | tee -a "$LOG_FILE"
        fi
        return 0
    else
        return 1
    fi
}

# 读取配置
read_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        return 0
    else
        return 1
    fi
}

# 写入配置
write_config() {
    cat >"$CONFIG_FILE" <<EOF
TRAFFIC_MODE=$TRAFFIC_MODE
TRAFFIC_PERIOD=$TRAFFIC_PERIOD
TRAFFIC_LIMIT=$TRAFFIC_LIMIT
TRAFFIC_TOLERANCE=$TRAFFIC_TOLERANCE
PERIOD_START_DAY=${PERIOD_START_DAY:-1}
LIMIT_SPEED=${LIMIT_SPEED:-20}
MAIN_INTERFACE=$MAIN_INTERFACE
LIMIT_MODE=$LIMIT_MODE
EOF
    echo "$(date '+%Y-%m-%d %H:%M:%S') 配置已更新" | tee -a "$LOG_FILE"
}

# 显示当前配置
show_current_config() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') 当前配置:" | tee -a "$LOG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') 流量统计模式: $TRAFFIC_MODE" | tee -a "$LOG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') 流量统计周期: $TRAFFIC_PERIOD" | tee -a "$LOG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') 周期起始日: ${PERIOD_START_DAY:-1}" | tee -a "$LOG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') 流量限制: $TRAFFIC_LIMIT GB" | tee -a "$LOG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') 容错范围: $TRAFFIC_TOLERANCE GB" | tee -a "$LOG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') 限速: ${LIMIT_SPEED:-20} kbit/s" | tee -a "$LOG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') 主要网络接口: $MAIN_INTERFACE" | tee -a "$LOG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') 限制模式: $LIMIT_MODE" | tee -a "$LOG_FILE"
}

# 检测主要网络接口
get_main_interface() {
    local main_interface=$(ip route | grep default | sed -n 's/^default via [0-9.]* dev \([^ ]*\).*/\1/p' | head -n1)
    if [ -z "$main_interface" ]; then
        main_interface=$(ip link | grep 'state UP' | sed -n 's/^[0-9]*: \([^:]*\):.*/\1/p' | head -n1)
    fi

    if [ -z "$main_interface" ]; then
        while true; do
            echo "$(date '+%Y-%m-%d %H:%M:%S') 无法自动检测主要网络接口。" | tee -a "$LOG_FILE"
            echo "$(date '+%Y-%m-%d %H:%M:%S') 可用的网络接口有：" | tee -a "$LOG_FILE"
            ip -o link show | sed -n 's/^[0-9]*: \([^:]*\):.*/\1/p'
            read -p "请从上面的列表中选择一个网络接口: " main_interface
            if [ -z "$main_interface" ]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') 请输入一个有效的接口名称。" | tee -a "$LOG_FILE"
            elif ip link show "$main_interface" >/dev/null 2>&1; then
                break
            else
                echo "$(date '+%Y-%m-%d %H:%M:%S') 无效的接口，请重新选择。" | tee -a "$LOG_FILE"
            fi
        done
    else
        read -p "检测到的主要网络接口是: $main_interface, 按Enter使用此接口，或输入新的接口名称: " new_interface
        if [ -n "$new_interface" ]; then
            if ip link show "$new_interface" >/dev/null 2>&1; then
                main_interface=$new_interface
            else
                echo "$(date '+%Y-%m-%d %H:%M:%S') 输入的接口无效，将使用检测到的接口: $main_interface" | tee -a "$LOG_FILE"
            fi
        fi
    fi

    echo $main_interface | tee -a "$LOG_FILE"
}

# 初始配置函数
echo "$(date '+%Y-%m-%d %H:%M:%S') 开始初始化配置" | tee -a "$LOG_FILE"
initial_config() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') 正在检测主要网络接口..." | tee -a "$LOG_FILE"
    MAIN_INTERFACE=$(get_main_interface)

    while true; do
        echo "$(date '+%Y-%m-%d %H:%M:%S') 请选择流量统计模式：" | tee -a "$LOG_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S') 1. 只计算出站流量" | tee -a "$LOG_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S') 2. 只计算进站流量" | tee -a "$LOG_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S') 3. 出进站流量都计算" | tee -a "$LOG_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S') 4. 出站和进站流量只取大" | tee -a "$LOG_FILE"
        read -p "请输入选择 (1-4): " mode_choice
        case $mode_choice in
        1)
            TRAFFIC_MODE="out"
            break
            ;;
        2)
            TRAFFIC_MODE="in"
            break
            ;;
        3)
            TRAFFIC_MODE="total"
            break
            ;;
        4)
            TRAFFIC_MODE="max"
            break
            ;;
        *) echo "无效输入，请重新选择。" ;;
        esac
    done

    read -p "请选择流量统计周期 (m/q/y，默认为m): " period_choice
    case $period_choice in
    q) TRAFFIC_PERIOD="quarterly" ;;
    y) TRAFFIC_PERIOD="yearly" ;;
    m | "") TRAFFIC_PERIOD="monthly" ;;
    *)
        echo "无效输入，使用默认值：monthly"
        TRAFFIC_PERIOD="monthly"
        ;;
    esac

    read -p "请输入周期起始日 (1-31，默认为1): " PERIOD_START_DAY
    if [[ -z "$PERIOD_START_DAY" ]]; then
        PERIOD_START_DAY=1
    elif ! [[ "$PERIOD_START_DAY" =~ ^[1-9]$|^[12][0-9]$|^3[01]$ ]]; then
        echo "无效输入，使用默认值：1"
        PERIOD_START_DAY=1
    fi

    while true; do
        read -p "请输入流量限制 (GB): " TRAFFIC_LIMIT
        if [[ "$TRAFFIC_LIMIT" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            break
        else
            echo "无效输入，请输入一个有效的数字。"
        fi
    done

    while true; do
        read -p "请输入容错范围 (GB): " TRAFFIC_TOLERANCE
        if [[ "$TRAFFIC_TOLERANCE" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            break
        else
            echo "无效输入，请输入一个有效的数字。"
        fi
    done

    while true; do
        echo "$(date '+%Y-%m-%d %H:%M:%S') 请选择限制模式：" | tee -a "$LOG_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S') 1. TC 模式（更灵活）" | tee -a "$LOG_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S') 2. 关机模式（更安全）" | tee -a "$LOG_FILE"
        read -p "请输入选择 (1-2): " limit_mode_choice
        case $limit_mode_choice in
        1)
            LIMIT_MODE="tc"
            read -p "请输入限速 (kbit/s，默认为20): " LIMIT_SPEED
            LIMIT_SPEED=${LIMIT_SPEED:-20}
            if ! [[ "$LIMIT_SPEED" =~ ^[0-9]+$ ]]; then
                echo "无效输入，使用默认值：20 kbit/s"
                LIMIT_SPEED=20
            fi
            break
            ;;
        2)
            LIMIT_MODE="shutdown"
            LIMIT_SPEED="" # 关机模式不需要限速
            break
            ;;
        *) echo "无效输入，请重新选择。" ;;
        esac
    done

    write_config
}

# 获取当前周期的起始日期
get_period_start_date() {
    local current_date=$(date +%Y-%m-%d)
    local current_month=$(date +%m)
    local current_year=$(date +%Y)

    case $TRAFFIC_PERIOD in
    monthly)
        if [ $(date +%d) -lt $PERIOD_START_DAY ]; then
            date -d "${current_year}-${current_month}-${PERIOD_START_DAY} -1 month" +'%Y-%m-%d'
        else
            date -d "${current_year}-${current_month}-${PERIOD_START_DAY}" +%Y-%m-%d 2>/dev/null || date -d "${current_year}-${current_month}-01" +%Y-%m-%d
        fi
        ;;
    quarterly)
        local quarter_month=$(((($(date +%m) - 1) / 3) * 3 + 1))
        if [ $(date +%d) -lt $PERIOD_START_DAY ] || [ $(date +%m) -eq $quarter_month ]; then
            date -d "${current_year}-${quarter_month}-${PERIOD_START_DAY} -3 month" +'%Y-%m-%d'
        else
            date -d "${current_year}-${quarter_month}-${PERIOD_START_DAY}" +'%Y-%m-%d' 2>/dev/null || date -d "${current_year}-${quarter_month}-01" +%Y-%m-%d
        fi
        ;;
    yearly)
        if [ $(date +%d) -lt $PERIOD_START_DAY ] || [ $(date +%m) -eq 01 ]; then
            date -d "${current_year}-01-${PERIOD_START_DAY} -1 year" +'%Y-%m-%d'
        else
            date -d "${current_year}-01-${PERIOD_START_DAY}" +'%Y-%m-%d' 2>/dev/null || date -d "${current_year}-01-01" +%Y-%m-%d
        fi
        ;;
    esac
}

# 获取周期结束日期
get_period_end_date() {
    local current_date=$(date +%Y-%m-%d)
    local current_month=$(date +%m)
    local current_year=$(date +%Y)

    case $TRAFFIC_PERIOD in
    monthly)
        if [ $(date +%d) -lt $PERIOD_START_DAY ]; then
            date -d "${current_year}-${current_month}-${PERIOD_START_DAY} -1 day" +'%Y-%m-%d'
        else
            date -d "${current_year}-${current_month}-${PERIOD_START_DAY} +1 month -1 day" +'%Y-%m-%d'
        fi
        ;;
    quarterly)
        local quarter_month=$(((($(date +%m) - 1) / 3) * 3 + 1))
        if [ $(date +%d) -lt $PERIOD_START_DAY ] || [ $(date +%m) -eq $quarter_month ]; then
            date -d "${current_year}-${quarter_month}-${PERIOD_START_DAY} +2 month -1 day" +'%Y-%m-%d'
        else
            date -d "${current_year}-${quarter_month}-${PERIOD_START_DAY} +5 month -1 day" +'%Y-%m-%d'
        fi
        ;;
    yearly)
        if [ $(date +%d) -lt $PERIOD_START_DAY ] || [ $(date +%m) -eq 01 ]; then
            date -d "${current_year}-12-31" +'%Y-%m-%d'
        else
            date -d "$((current_year + 1))-12-31" +'%Y-%m-%d'
        fi
        ;;
    esac
}

# 获取流量使用情况
get_traffic_usage() {
    local start_date=$(get_period_start_date)
    local end_date=$(get_period_end_date)

    echo "$(date '+%Y-%m-%d %H:%M:%S') 周期开始日期: $start_date, 周期结束日期: $end_date" >&2

    local vnstat_output=$(vnstat -i $MAIN_INTERFACE --begin "$start_date" --end "$end_date" --oneline b)
    # echo "vnstat输出: $vnstat_output" >&2

    local usage
    if echo "$vnstat_output" | grep -q "No data"; then
        usage=0
    else
        case $TRAFFIC_MODE in
        out)
            usage=$(echo "$vnstat_output" | cut -d';' -f10)
            ;;
        in)
            usage=$(echo "$vnstat_output" | cut -d';' -f9)
            ;;
        total)
            usage=$(echo "$vnstat_output" | cut -d';' -f11)
            ;;
        max)
            local rx=$(echo "$vnstat_output" | cut -d';' -f9)
            local tx=$(echo "$vnstat_output" | cut -d';' -f10)
            usage=$(echo "$rx $tx" | tr ' ' '\n' | sort -rn | head -n1)
            ;;
        esac
    fi

    # echo "用量字节数: $usage" >&2
    if [ -n "$usage" ]; then
        # 将字节转换为 GiB，并确保结果至少有一位小数
        usage=$(echo "scale=3; x=$usage/1024/1024/1024; if(x<1) print 0; x" | bc)
        # echo "将字节转换为 GiB: $usage" >&2
        echo $usage
    else
        # echo "无法获取用量字节数" >&2
        echo "0.000"
    fi
}

# 修改 check_and_limit_traffic 函数
check_and_limit_traffic() {
    local current_usage=$(get_traffic_usage)
    local limit_threshold=$(echo "$TRAFFIC_LIMIT - $TRAFFIC_TOLERANCE" | bc)

    echo "$(date '+%Y-%m-%d %H:%M:%S') 当前使用流量: $current_usage GB，限制流量: $limit_threshold GB" | tee -a "$LOG_FILE"

    if (($(echo "$current_usage > $limit_threshold" | bc -l))); then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 流量超出限制" | tee -a "$LOG_FILE"
        if [ "$LIMIT_MODE" = "tc" ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') 使用 TC 模式限速" | tee -a "$LOG_FILE"
            tc qdisc add dev $MAIN_INTERFACE root tbf rate ${LIMIT_SPEED}kbit burst 32kbit latency 400ms
        elif [ "$LIMIT_MODE" = "shutdown" ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') 流量超出限制，系统将在 1 分钟后关机" | tee -a "$LOG_FILE"
            shutdown -h +1 "流量超出限制，系统将在 1 分钟后关机"
        fi
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') 流量正常，清除所有限制" | tee -a "$LOG_FILE"
        tc qdisc del dev $MAIN_INTERFACE root 2>/dev/null
        shutdown -c 2>/dev/null # 取消可能存在的关机计划
    fi
}

# 检查是否需要重置限制
check_reset_limit() {
    local current_date=$(date +%Y-%m-%d)
    local period_start=$(get_period_start_date)

    if [[ "$current_date" == "$period_start" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 新的流量周期开始，重置限制" | tee -a "$LOG_FILE"
        tc qdisc del dev $MAIN_INTERFACE root 2>/dev/null
    fi
}

setup_crontab() {
    # 删除旧的脚本任务（如果存在）
    crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | crontab -

    # 添加新的脚本任务
    (
        crontab -l 2>/dev/null
        echo "* * * * * $SCRIPT_PATH --run"
    ) | crontab -

    echo "$(date '+%Y-%m-%d %H:%M:%S') Crontab 已设置，每分钟运行一次" | tee -a "$LOG_FILE"
}

set_timezone() {
    # 检查时区数据和链接是否存在
    if [ -f /usr/share/zoneinfo/Asia/Shanghai ]; then
        # 设置时区为 Asia/Shanghai
        ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
        echo "$(date '+%Y-%m-%d %H:%M:%S') 时区已成功设置为 Asia/Shanghai" | tee -a "$LOG_FILE"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') 找不到时区文件" | tee -a "$LOG_FILE"
        return 2
    fi
}

# 主函数
main() {
    # 调用函数来杀死其他实例
    kill_other_instances

    # 切换到工作目录
    cd "$WORK_DIR" || exit 1

    # 创建锁文件（如果不存在）
    touch "${LOCK_FILE}"

    # 尝试获取文件锁
    exec 9>"${LOCK_FILE}"
    if ! flock -n 9; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 另一个脚本实例正在运行，退出。" | tee -a "$LOG_FILE"
        exit 1
    fi

    # 检查是否以 --run 模式运行
    if [ $1 = "--run" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 正在以自动化模式运行" | tee -a "$LOG_FILE"
        if read_config; then
            check_reset_limit
            check_and_limit_traffic
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') 配置文件读取失败，请检查配置" | tee -a "$LOG_FILE"
        fi
        return
    fi

    # 非 --run 模式下的操作
    # 首先检查并安装必要的软件包
    check_and_install_packages
    set_timezone
    if check_existing_setup; then
        read_config
        show_current_config

        echo "$(date '+%Y-%m-%d %H:%M:%S') 是否需要修改配置？(y/n): 5秒内按任意键修改配置，否则保持现有配置" | tee -a "$LOG_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S') 开始等待用户输入..." | tee -a "$LOG_FILE"

        start_time=$(date +%s.%N)
        if read -t 5 -n 1 modify_config; then
            end_time=$(date +%s.%N)
            duration=$(echo "$end_time - $start_time" | bc)
            echo "" # 换行
            echo "$(date '+%Y-%m-%d %H:%M:%S') 收到用户输入: '${modify_config}' (ASCII: $(printf '%d' "'$modify_config" 2>/dev/null || echo "N/A"))" | tee -a "$LOG_FILE"
            echo "$(date '+%Y-%m-%d %H:%M:%S') 等待时间: $duration 秒" | tee -a "$LOG_FILE"
            if [[ $duration < 0.1 ]]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') 警告：输入时间过短，可能是自动输入" | tee -a "$LOG_FILE"
                echo "$(date '+%Y-%m-%d %H:%M:%S') 忽略此输入，保持现有配置。" | tee -a "$LOG_FILE"
            else
                echo "$(date '+%Y-%m-%d %H:%M:%S') 开始修改配置..." | tee -a "$LOG_FILE"
                initial_config
                setup_crontab
                echo "$(date '+%Y-%m-%d %H:%M:%S') 配置已更新，脚本将每分钟自动运行一次" | tee -a "$LOG_FILE"
            fi
        else
            end_time=$(date +%s.%N)
            duration=$(echo "$end_time - $start_time" | bc)
            echo "" # 换行
            echo "$(date '+%Y-%m-%d %H:%M:%S') 等待超时，无用户输入" | tee -a "$LOG_FILE"
            echo "$(date '+%Y-%m-%d %H:%M:%S') 等待时间: $duration 秒" | tee -a "$LOG_FILE"
            echo "$(date '+%Y-%m-%d %H:%M:%S') 保持现有配置。" | tee -a "$LOG_FILE"
        fi
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') 开始初始化配置..." | tee -a "$LOG_FILE"
        initial_config
        setup_crontab
        echo "$(date '+%Y-%m-%d %H:%M:%S') 初始配置完成，脚本将每分钟自动运行一次" | tee -a "$LOG_FILE"
    fi

    # 显示当前流量使用情况和限制状态
    if read_config; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 当前流量使用情况：" | tee -a "$LOG_FILE"
        local current_usage=$(get_traffic_usage)
        #echo "Debug: Current usage from get_traffic_usage: $current_usage" | tee -a "$LOG_FILE"
        if [ "$current_usage" != "0" ]; then
            local start_date=$(get_period_start_date)
            echo "$(date '+%Y-%m-%d %H:%M:%S') 当前统计周期: $TRAFFIC_PERIOD (从 $start_date 开始)" | tee -a "$LOG_FILE"
            echo "$(date '+%Y-%m-%d %H:%M:%S') 统计模式: $TRAFFIC_MODE" | tee -a "$LOG_FILE"
            echo "$(date '+%Y-%m-%d %H:%M:%S') 当前使用流量: $current_usage GB" | tee -a "$LOG_FILE"
            echo "$(date '+%Y-%m-%d %H:%M:%S') 检查并限制流量：" | tee -a "$LOG_FILE"
            check_and_limit_traffic
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') 无法获取流量数据，请检查 vnstat 配置" | tee -a "$LOG_FILE"
        fi
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') 配置文件读取失败，请检查配置" | tee -a "$LOG_FILE"
    fi

    # 确保脚本退出时释放锁
    trap 'flock -u 9; rm -f ${LOCK_FILE}' EXIT
}

# 执行主函数
main "$@"

echo "-----------------------------------------------------" | tee -a "$LOG_FILE"
