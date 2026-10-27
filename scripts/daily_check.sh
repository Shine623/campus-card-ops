#!/bin/bash
# ============================================================
# 一卡通系统日常巡检
#
# 每天 8:00 由 cron 执行
# 输出：控制台 + 日志 + （有问题时）邮件告警
#
# crontab: 0 8 * * * /opt/scripts/daily_check.sh >> /var/log/cardcheck.log 2>&1
# ============================================================

set -uo pipefail

DB_HOST="${DB_HOST:-127.0.0.1}"
DB_USER="${DB_USER:-card}"
DB_PASS="${DB_PASS:-card123}"
DB_NAME="${DB_NAME:-card}"

ALERT_MAIL="${ALERT_MAIL:-ops@example.edu}"
LOG_DIR="${LOG_DIR:-/var/log/cardcheck}"

mkdir -p "$LOG_DIR"
TS=$(date +%Y%m%d_%H%M%S)
REPORT="$LOG_DIR/report_${TS}.txt"

WARN=0
ERR=0

# ---------- 工具函数 ----------
log()  { echo "$*" | tee -a "$REPORT"; }
ok()   { log "  [OK]   $1"; }
warn() { log "  [WARN] $1"; WARN=$((WARN+1)); }
err()  { log "  [ERR]  $1"; ERR=$((ERR+1)); }

section() {
    log ""
    log "============================================================"
    log "  $*"
    log "============================================================"
}

log "一卡通系统巡检报告"
log "时间: $(date '+%Y-%m-%d %H:%M:%S')"
log "主机: $(hostname)"

# ---------- 1. 系统资源 ----------
section "1. 系统资源"

# CPU
cpu_idle=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | cut -d. -f1)
cpu_used=$((100 - ${cpu_idle:-0}))
if [ "$cpu_used" -ge 80 ]; then
    warn "CPU 使用率 ${cpu_used}%（阈值 80%）"
else
    ok "CPU 使用率 ${cpu_used}%"
fi

# 内存
mem_info=$(free | grep Mem)
mem_total=$(echo "$mem_info" | awk '{print $2}')
mem_used=$(echo "$mem_info" | awk '{print $3}')
mem_pct=$((mem_used * 100 / mem_total))
if [ "$mem_pct" -ge 85 ]; then
    warn "内存使用率 ${mem_pct}%（阈值 85%）"
else
    ok "内存使用率 ${mem_pct}%"
fi

# 磁盘
for mount in / /var /data; do
    [ -d "$mount" ] || continue
    usage=$(df -h "$mount" | awk 'NR==2 {print $5}' | tr -d '%')
    avail=$(df -h "$mount" | awk 'NR==2 {print $4}')

    if [ "$usage" -ge 85 ]; then
        err "磁盘 $mount 使用率 ${usage}%（剩余 $avail，阈值 85%）"
        # 预测何时满
        log "         建议：清理日志或扩容"
    elif [ "$usage" -ge 70 ]; then
        warn "磁盘 $mount 使用率 ${usage}%（剩余 $avail）"
    else
        ok "磁盘 $mount 使用率 ${usage}%（剩余 $avail）"
    fi
done

# 负载
load1=$(uptime | sed 's/.*load average: //' | cut -d, -f1 | tr -d ' ')
cpu_cores=$(nproc)
load_pct=$(echo "$load1 $cpu_cores" | awk '{printf "%d", $1/$2*100}')
if [ "$load_pct" -ge 100 ]; then
    warn "系统负载 ${load1}（${cpu_cores} 核，负载超过核数）"
else
    ok "系统负载 ${load1}（${cpu_cores} 核）"
fi

# ---------- 2. 数据库 ----------
section "2. 数据库"

if mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" -e "SELECT 1" >/dev/null 2>&1; then
    ok "数据库连接正常"

    # 主从延迟
    slave_status=$(mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" -e "SHOW SLAVE STATUS\G" 2>/dev/null)
    if [ -n "$slave_status" ]; then
        io_running=$(echo "$slave_status" | grep "Slave_IO_Running:" | awk '{print $2}')
        sql_running=$(echo "$slave_status" | grep "Slave_SQL_Running:" | awk '{print $2}')
        delay=$(echo "$slave_status" | grep "Seconds_Behind_Master:" | awk '{print $2}')

        if [ "$io_running" != "Yes" ] || [ "$sql_running" != "Yes" ]; then
            err "主从同步异常：IO=$io_running SQL=$sql_running"
        elif [ "${delay:-0}" -gt 10 ]; then
            warn "主从延迟 ${delay} 秒（阈值 10 秒）"
        else
            ok "主从同步正常，延迟 ${delay:-0} 秒"
        fi
    else
        log "  [INFO] 本机不是从库，跳过主从检查"
    fi

    # 连接数
    conn=$(mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" -N -e \
           "SELECT COUNT(*) FROM information_schema.processlist")
    max_conn=$(mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" -N -e \
               "SELECT @@max_connections")
    if [ "$conn" -gt 200 ]; then
        warn "数据库连接数 ${conn}（上限 ${max_conn}，阈值 200）"
    else
        ok "数据库连接数 ${conn}/${max_conn}"
    fi

    # 慢查询数
    slow=$(mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" -N -e \
           "SELECT COUNT(*) FROM mysql.slow_log" 2>/dev/null || echo "N/A")
    if [ "$slow" != "N/A" ] && [ "$slow" -gt 100 ]; then
        warn "慢查询 ${slow} 条，建议分析"
    else
        ok "慢查询 ${slow} 条"
    fi
else
    err "数据库连接失败"
fi

# ---------- 3. 应用 ----------
section "3. 应用服务"

for svc in tomcat card-app; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        ok "服务 $svc 运行中"
    elif pgrep -f "$svc" >/dev/null 2>&1; then
        ok "进程 $svc 存在（非 systemd 管理）"
    else
        err "服务 $svc 未运行"
    fi
done

# 端口
for port in 8080 3306 6379; do
    if ss -lnt 2>/dev/null | grep -q ":${port} " || netstat -lnt 2>/dev/null | grep -q ":${port} "; then
        ok "端口 $port 监听中"
    else
        warn "端口 $port 未监听"
    fi
done

# JVM 堆（如果跑 Java）
if pgrep -f tomcat >/dev/null 2>&1; then
    pid=$(pgrep -f tomcat | head -1)
    heap=$(jstat -gc "$pid" 2>/dev/null | awk 'NR==2 {printf "%.1f", ($3+$4+$6+$8)/1024}')
    if [ -n "$heap" ]; then
        ok "JVM 堆使用 ${heap} MB"
    fi
fi

# ---------- 4. 业务指标 ----------
section "4. 业务指标"

if mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "SELECT 1" >/dev/null 2>&1; then
    today=$(date +%Y-%m-%d)

    # 今日交易量
    tx_count=$(mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" -N -e \
               "SELECT COUNT(*) FROM transaction WHERE DATE(tx_time)='$today'" 2>/dev/null || echo 0)
    ok "今日交易笔数 ${tx_count}"

    # 失败率
    fail_count=$(mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" -N -e \
                 "SELECT COUNT(*) FROM transaction WHERE DATE(tx_time)='$today' AND status='FAILED'" 2>/dev/null || echo 0)
    if [ "$tx_count" -gt 0 ]; then
        fail_rate=$(echo "$fail_count $tx_count" | awk '{printf "%.2f", $1/$2*100}')
        if [ "$(echo "$fail_rate > 1" | bc -l 2>/dev/null || echo 0)" = "1" ]; then
            err "今日交易失败率 ${fail_rate}%（${fail_count}/${tx_count}，阈值 1%）"
        else
            ok "今日交易失败率 ${fail_rate}%（${fail_count}/${tx_count}）"
        fi
    fi

    # 待处理充值（PENDING 超过 10 分钟）
    pending=$(mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" -N -e \
              "SELECT COUNT(*) FROM transaction
               WHERE status='PENDING'
                 AND tx_time < DATE_SUB(NOW(), INTERVAL 10 MINUTE)" 2>/dev/null || echo 0)
    if [ "$pending" -gt 0 ]; then
        err "有 ${pending} 笔充值处于 PENDING 超过 10 分钟，需立即处理"
    else
        ok "无长时间 PENDING 的充值"
    fi
else
    warn "无法连接业务库，跳过业务指标检查"
fi

# ---------- 5. 对账 ----------
section "5. 对账"

if [ -f "scripts/check_balance.py" ]; then
    result=$(python3 scripts/check_balance.py --quick 2>&1 | tail -3)
    if echo "$result" | grep -q "差异: 0"; then
        ok "余额与流水一致"
    else
        err "发现余额差异，请运行完整对账"
        log "$result" | sed 's/^/         /'
    fi
else
    log "  [INFO] 未找到 check_balance.py，跳过"
fi

# ---------- 汇总 ----------
section "巡检汇总"
log "  警告: $WARN 项"
log "  错误: $ERR 项"
log ""

if [ "$ERR" -gt 0 ]; then
    log "  状态: ❌ 有严重问题，需要立即处理"
    EXIT_CODE=2
elif [ "$WARN" -gt 0 ]; then
    log "  状态: ⚠️  有警告，建议关注"
    EXIT_CODE=1
else
    log "  状态: ✅ 一切正常"
    EXIT_CODE=0
fi

log ""
log "报告已保存: $REPORT"

# 有问题时发邮件
if [ "$EXIT_CODE" -gt 0 ] && [ -n "$ALERT_MAIL" ]; then
    if command -v mail >/dev/null 2>&1; then
        subject="[一卡通巡检] $(if [ "$ERR" -gt 0 ]; then echo "错误"; else echo "警告"; fi) - $(hostname)"
        mail -s "$subject" "$ALERT_MAIL" < "$REPORT"
        log "告警邮件已发送至 $ALERT_MAIL"
    fi
fi

# 清理 7 天前的报告
find "$LOG_DIR" -name "report_*.txt" -mtime +7 -delete 2>/dev/null

exit $EXIT_CODE
