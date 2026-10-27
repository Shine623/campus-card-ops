-- ============================================================
-- 慢查询 Top 20
--
-- 用法: mysql -u root -p < sql/top_slow.sql
-- ============================================================

-- 1. 慢查询总览
SELECT '=== 慢查询总览 ===' AS info;
SELECT
    COUNT(*) AS slow_count,
    ROUND(AVG(query_time), 3) AS avg_seconds,
    ROUND(MAX(query_time), 3) AS max_seconds,
    SUM(rows_examined) AS total_rows_examined
FROM mysql.slow_log
WHERE start_time > DATE_SUB(NOW(), INTERVAL 7 DAY);

-- 2. 按 SQL 模板聚合（把数字替换掉，便于归类）
SELECT '=== 慢查询 Top 20 ===' AS info;
SELECT
    LEFT(sql_text, 200) AS sql_preview,
    COUNT(*) AS exec_count,
    ROUND(AVG(query_time), 3) AS avg_seconds,
    ROUND(MAX(query_time), 3) AS max_seconds,
    SUM(rows_examined) AS rows_examined,
    SUM(rows_sent) AS rows_sent
FROM mysql.slow_log
WHERE start_time > DATE_SUB(NOW(), INTERVAL 7 DAY)
GROUP BY LEFT(sql_text, 200)
ORDER BY avg_seconds DESC
LIMIT 20;

-- 3. 当前正在执行的慢查询
SELECT '=== 当前执行中的慢查询 ===' AS info;
SELECT
    id,
    user,
    host,
    db,
    command,
    time AS seconds,
    state,
    LEFT(info, 200) AS sql_preview
FROM information_schema.processlist
WHERE command != 'Sleep'
  AND time > 5
ORDER BY time DESC;

-- 4. 缺少索引的表（全表扫描）
SELECT '=== 疑似缺索引（rows_examined 远大于 rows_sent） ===' AS info;
SELECT
    LEFT(sql_text, 150) AS sql_preview,
    COUNT(*) AS exec_count,
    ROUND(AVG(rows_examined), 0) AS avg_examined,
    ROUND(AVG(rows_sent), 0) AS avg_sent,
    ROUND(AVG(rows_examined) / GREATEST(AVG(rows_sent), 1), 1) AS scan_ratio
FROM mysql.slow_log
WHERE start_time > DATE_SUB(NOW(), INTERVAL 7 DAY)
GROUP BY LEFT(sql_text, 150)
HAVING scan_ratio > 100
ORDER BY scan_ratio DESC
LIMIT 10;
