-- ============================================================
-- 主从同步状态检查
--
-- 用法: mysql -u root -p < sql/check_sync.sql
-- ============================================================

-- 1. 完整状态
SELECT '=== 主从状态 ===' AS info;
SHOW SLAVE STATUS\G

-- 2. 关键指标（便于快速判断）
SELECT '=== 关键指标 ===' AS info;
SELECT
    IF(Slave_IO_Running = 'Yes', 'OK', 'FAIL') AS io_thread,
    IF(Slave_SQL_Running = 'Yes', 'OK', 'FAIL') AS sql_thread,
    Seconds_Behind_Master AS delay_seconds,
    Last_Error AS last_error
FROM (
    SELECT 1
) t
LEFT JOIN (
    SHOW SLAVE STATUS
) s ON 1=1;

-- 3. 主库 binlog 位置
SELECT '=== 主库 binlog ===' AS info;
SHOW MASTER STATUS;

-- 4. 从库已应用位置
SELECT '=== 从库位置 ===' AS info;
SELECT
    Master_Log_File AS master_file,
    Read_Master_Log_Pos AS read_pos,
    Relay_Master_Log_File AS relay_file,
    Exec_Master_Log_Pos AS exec_pos
FROM (SHOW SLAVE STATUS) t;

-- 5. 检查是否有长事务
SELECT '=== 长事务（超过 60 秒） ===' AS info;
SELECT
    trx_id,
    trx_state,
    trx_started,
    TIMESTAMPDIFF(SECOND, trx_started, NOW()) AS duration_sec,
    trx_mysql_thread_id AS thread_id,
    trx_query
FROM information_schema.innodb_trx
WHERE TIMESTAMPDIFF(SECOND, trx_started, NOW()) > 60
ORDER BY duration_sec DESC;

-- 6. 连接数
SELECT '=== 连接数 ===' AS info;
SELECT
    COUNT(*) AS current_connections,
    @@max_connections AS max_connections,
    ROUND(COUNT(*) / @@max_connections * 100, 2) AS usage_pct
FROM information_schema.processlist;
