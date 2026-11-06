/*
 *
    OBJETIVO: Analisar a performance das queries e dos waits coletados pelas sessões de Extended Events,
              calculando estatísticas descritivas (total, média, desvio padrão, mínimo e máximo) e
              percentis (50, 75, 90, 95 e 99) por banco, plano e intervalo de tempo, a partir das tabelas
              history_query_stats e history_waits.

    PROJETO: mssql-xe-observability

    AUTHOR: Robson Sestrem

    REFERÊNCIAS DE URL:
    ESTATÍSTICA DESCRITIVA - PERCENTIL
    https://medium.com/@juliodelimas/percentis-e-sua-import%C3%A2ncia-nos-testes-de-performance-ea83e3bba462
 *
 */
-- ============================================================
-- result 01 - performance query
-- ============================================================

-- CTE 1: percentis de duração, CPU, leituras físicas, leituras lógicas e escritas por banco, plano e intervalo
;WITH statement_ntile_cte AS
(
    SELECT DISTINCT
        database_name
        , event_interval
        , query_hash
        , query_plan_hash
        , PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY duration_ms) OVER (PARTITION BY database_name, query_plan_hash, DATEADD(MINUTE, DATEDIFF(MINUTE, 0, event_time), 0)) AS duration_50th
        , PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY duration_ms) OVER (PARTITION BY database_name, query_plan_hash, DATEADD(MINUTE, DATEDIFF(MINUTE, 0, event_time), 0)) AS duration_75th
        , PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY duration_ms) OVER (PARTITION BY database_name, query_plan_hash, DATEADD(MINUTE, DATEDIFF(MINUTE, 0, event_time), 0)) AS duration_90th
        , PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY duration_ms) OVER (PARTITION BY database_name, query_plan_hash, DATEADD(MINUTE, DATEDIFF(MINUTE, 0, event_time), 0)) AS duration_95th
        , PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY duration_ms) OVER (PARTITION BY database_name, query_plan_hash, DATEADD(MINUTE, DATEDIFF(MINUTE, 0, event_time), 0)) AS duration_99th

        , PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY cpu_time_ms) OVER (PARTITION BY database_name, query_plan_hash, DATEADD(MINUTE, DATEDIFF(MINUTE, 0, event_time), 0)) AS cpu_time_50th
        , PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY cpu_time_ms) OVER (PARTITION BY database_name, query_plan_hash, DATEADD(MINUTE, DATEDIFF(MINUTE, 0, event_time), 0)) AS cpu_time_75th
        , PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY cpu_time_ms) OVER (PARTITION BY database_name, query_plan_hash, DATEADD(MINUTE, DATEDIFF(MINUTE, 0, event_time), 0)) AS cpu_time_90th
        , PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY cpu_time_ms) OVER (PARTITION BY database_name, query_plan_hash, DATEADD(MINUTE, DATEDIFF(MINUTE, 0, event_time), 0)) AS cpu_time_95th
        , PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY cpu_time_ms) OVER (PARTITION BY database_name, query_plan_hash, DATEADD(MINUTE, DATEDIFF(MINUTE, 0, event_time), 0)) AS cpu_time_99th

        , PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY physical_reads) OVER (PARTITION BY database_name, query_plan_hash, DATEADD(MINUTE, DATEDIFF(MINUTE, 0, event_time), 0)) AS physical_reads_50th
        , PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY physical_reads) OVER (PARTITION BY database_name, query_plan_hash, DATEADD(MINUTE, DATEDIFF(MINUTE, 0, event_time), 0)) AS physical_reads_75th
        , PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY physical_reads) OVER (PARTITION BY database_name, query_plan_hash, DATEADD(MINUTE, DATEDIFF(MINUTE, 0, event_time), 0)) AS physical_reads_90th
        , PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY physical_reads) OVER (PARTITION BY database_name, query_plan_hash, DATEADD(MINUTE, DATEDIFF(MINUTE, 0, event_time), 0)) AS physical_reads_95th
        , PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY physical_reads) OVER (PARTITION BY database_name, query_plan_hash, DATEADD(MINUTE, DATEDIFF(MINUTE, 0, event_time), 0)) AS physical_reads_99th

        , PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY logical_reads) OVER (PARTITION BY database_name, query_plan_hash, DATEADD(MINUTE, DATEDIFF(MINUTE, 0, event_time), 0)) AS logical_reads_50th
        , PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY logical_reads) OVER (PARTITION BY database_name, query_plan_hash, DATEADD(MINUTE, DATEDIFF(MINUTE, 0, event_time), 0)) AS logical_reads_75th
        , PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY logical_reads) OVER (PARTITION BY database_name, query_plan_hash, DATEADD(MINUTE, DATEDIFF(MINUTE, 0, event_time), 0)) AS logical_reads_90th
        , PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY logical_reads) OVER (PARTITION BY database_name, query_plan_hash, DATEADD(MINUTE, DATEDIFF(MINUTE, 0, event_time), 0)) AS logical_reads_95th
        , PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY logical_reads) OVER (PARTITION BY database_name, query_plan_hash, DATEADD(MINUTE, DATEDIFF(MINUTE, 0, event_time), 0)) AS logical_reads_99th

        , PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY writes) OVER (PARTITION BY database_name, query_plan_hash, DATEADD(MINUTE, DATEDIFF(MINUTE, 0, event_time), 0)) AS writes_50th
        , PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY writes) OVER (PARTITION BY database_name, query_plan_hash, DATEADD(MINUTE, DATEDIFF(MINUTE, 0, event_time), 0)) AS writes_75th
        , PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY writes) OVER (PARTITION BY database_name, query_plan_hash, DATEADD(MINUTE, DATEDIFF(MINUTE, 0, event_time), 0)) AS writes_90th
        , PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY writes) OVER (PARTITION BY database_name, query_plan_hash, DATEADD(MINUTE, DATEDIFF(MINUTE, 0, event_time), 0)) AS writes_95th
        , PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY writes) OVER (PARTITION BY database_name, query_plan_hash, DATEADD(MINUTE, DATEDIFF(MINUTE, 0, event_time), 0)) AS writes_99th
    FROM history_query_stats
)
-- CTE 2: estatísticas descritivas (soma, média, desvio padrão, mínimo e máximo) por statement e intervalo
, statement_analyzed_cte AS
(
    SELECT
        sc.database_name
        , sc.query_hash
        , sc.query_plan_hash
        , event_interval
        , sc.statement
        , SUM(duration_ms) AS total_duration_ms
        , AVG(duration_ms) AS average_duration_ms
        , COALESCE(STDEV(duration_ms), 0) AS stdev_duration_ms
        , MIN(duration_ms) AS min_duration_ms
        , MAX(duration_ms) AS max_duration_ms
        , SUM(cpu_time_ms) AS total_cpu_time_ms
        , AVG(cpu_time_ms) AS average_cpu_time_ms
        , COALESCE(STDEV(cpu_time_ms), 0) AS stdev_cpu_time_ms
        , MIN(cpu_time_ms) AS min_cpu_time_ms
        , MAX(cpu_time_ms) AS max_cpu_time_ms
        , SUM(physical_reads) AS total_physical_reads
        , AVG(physical_reads) AS average_physical_reads
        , COALESCE(STDEV(physical_reads), 0) AS stdev_physical_reads
        , MIN(physical_reads) AS min_physical_reads
        , MAX(physical_reads) AS max_physical_reads
        , SUM(logical_reads) AS total_logical_reads
        , AVG(logical_reads) AS average_logical_reads
        , COALESCE(STDEV(logical_reads), 0) AS stdev_logical_reads
        , MIN(logical_reads) AS min_logical_reads
        , MAX(logical_reads) AS max_logical_reads
        , SUM(writes) AS total_writes
        , AVG(writes) AS average_writes
        , COALESCE(STDEV(writes), 0) AS stdev_writes
        , MIN(writes) AS min_writes
        , MAX(writes) AS max_writes
    FROM history_query_stats AS sc
    GROUP BY sc.database_name, sc.query_hash, sc.query_plan_hash, sc.statement, event_interval
)
-- CTE 3: une as estatísticas descritivas aos percentis
, query_stats AS
(
    SELECT
        sac.database_name
        , sac.query_hash
        , sac.query_plan_hash
        , sac.statement
        , sac.event_interval

        , sac.total_duration_ms
        , sac.average_duration_ms
        , sac.stdev_duration_ms
        , sac.min_duration_ms
        , sac.max_duration_ms
        , snc.duration_50th
        , snc.duration_75th
        , snc.duration_90th
        , snc.duration_95th
        , snc.duration_99th

        , sac.total_cpu_time_ms
        , sac.average_cpu_time_ms
        , sac.stdev_cpu_time_ms
        , sac.min_cpu_time_ms
        , sac.max_cpu_time_ms
        , snc.cpu_time_50th
        , snc.cpu_time_75th
        , snc.cpu_time_90th
        , snc.cpu_time_95th
        , snc.cpu_time_99th

        , sac.total_physical_reads
        , sac.average_physical_reads
        , sac.stdev_physical_reads
        , sac.min_physical_reads
        , sac.max_physical_reads
        , snc.physical_reads_50th
        , snc.physical_reads_75th
        , snc.physical_reads_90th
        , snc.physical_reads_95th
        , snc.physical_reads_99th

        , sac.total_logical_reads
        , sac.average_logical_reads
        , sac.stdev_logical_reads
        , sac.min_logical_reads
        , sac.max_logical_reads
        , snc.logical_reads_50th
        , snc.logical_reads_75th
        , snc.logical_reads_90th
        , snc.logical_reads_95th
        , snc.logical_reads_99th

        , sac.total_writes
        , sac.average_writes
        , sac.stdev_writes
        , sac.min_writes
        , sac.max_writes
        , snc.writes_50th
        , snc.writes_75th
        , snc.writes_90th
        , snc.writes_95th
        , snc.writes_99th
    FROM statement_analyzed_cte AS sac
    JOIN statement_ntile_cte AS snc
        ON sac.query_plan_hash = snc.query_plan_hash
        AND sac.event_interval = snc.event_interval
        AND sac.database_name = snc.database_name
)
-- Resultado final: converte as unidades (microssegundos para segundos e páginas de 8 KB para MB)
SELECT
    qs.database_name
    --REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(LTRIM(RTRIM(qs.statement)), NCHAR(13), ' '), NCHAR(10), ' '), NCHAR(9), ' '), ' ','<>'),'><',''),'<>',' ') AS QueryText,
    , qs.statement
    , qs.event_interval

    -- sql_statement_completed, sp_statement_completed -> microsegungos
    , CAST(qs.total_duration_ms / 1000000.0 AS NUMERIC(18,2)) AS total_duration_s
    , CAST(qs.average_duration_ms / 1000000.0 AS NUMERIC(18,2)) AS average_duration_s
    , CAST(qs.stdev_duration_ms / 1000000.0 AS NUMERIC(18,2)) AS stdev_duration_s
    , CAST(qs.min_duration_ms / 1000000.0 AS NUMERIC(18,2)) AS min_duration_s
    , CAST(qs.max_duration_ms / 1000000.0 AS NUMERIC(18,2)) AS max_duration_s
    , CAST(qs.duration_50th / 1000000.0 AS NUMERIC(18,2)) AS duration_50th_s
    , CAST(qs.duration_75th / 1000000.0 AS NUMERIC(18,2)) AS duration_75th_s
    , CAST(qs.duration_90th / 1000000.0 AS NUMERIC(18,2)) AS duration_90th_s
    , CAST(qs.duration_95th / 1000000.0 AS NUMERIC(18,2)) AS duration_95th_s
    , CAST(qs.duration_99th / 1000000.0 AS NUMERIC(18,2)) AS duration_99th_s

    , CAST(qs.total_cpu_time_ms / 1000000.0 AS NUMERIC(18,2)) AS total_cpu_time_s
    , CAST(qs.average_cpu_time_ms / 1000000.0 AS NUMERIC(18,2)) AS average_cpu_time_s
    , CAST(qs.stdev_cpu_time_ms / 1000000.0 AS NUMERIC(18,2)) AS stdev_cpu_time_s
    , CAST(qs.min_cpu_time_ms / 1000000.0 AS NUMERIC(18,2)) AS min_cpu_time_s
    , CAST(qs.max_cpu_time_ms / 1000000.0 AS NUMERIC(18,2)) AS max_cpu_time_s
    , CAST(qs.cpu_time_50th / 1000000.0 AS NUMERIC(18,2)) AS cpu_time_50th_s
    , CAST(qs.cpu_time_75th / 1000000.0 AS NUMERIC(18,2)) AS cpu_time_75th_s
    , CAST(qs.cpu_time_90th / 1000000.0 AS NUMERIC(18,2)) AS cpu_time_90th_s
    , CAST(qs.cpu_time_95th / 1000000.0 AS NUMERIC(18,2)) AS cpu_time_95th_s
    , CAST(qs.cpu_time_99th / 1000000.0 AS NUMERIC(18,2)) AS cpu_time_99th_s

    , CAST(((qs.total_physical_reads * 8) / 1024) AS NUMERIC(18,4)) AS total_physical_reads_mb
    , CAST(((qs.average_physical_reads * 8) / 1024) AS NUMERIC(18,4)) AS average_physical_reads_mb
    , CAST(((qs.stdev_physical_reads * 8) / 1024) AS NUMERIC(18,4)) AS stdev_physical_reads_mb
    , CAST(((qs.min_physical_reads * 8) / 1024) AS NUMERIC(18,4)) AS min_physical_reads_mb
    , CAST(((qs.max_physical_reads * 8) / 1024) AS NUMERIC(18,4)) AS max_physical_reads_mb
    , CAST(((qs.physical_reads_50th * 8) / 1024) AS NUMERIC(18,4)) AS physical_reads_50th_mb
    , CAST(((qs.physical_reads_75th * 8) / 1024) AS NUMERIC(18,4)) AS physical_reads_75th_mb
    , CAST(((qs.physical_reads_90th * 8) / 1024) AS NUMERIC(18,4)) AS physical_reads_90th_mb
    , CAST(((qs.physical_reads_95th * 8) / 1024) AS NUMERIC(18,4)) AS physical_reads_95th_mb
    , CAST(((qs.physical_reads_99th * 8) / 1024) AS NUMERIC(18,4)) AS physical_reads_99th_mb

    -- Logical reads conta leituras repetidas na mesma página, por isso valores absurdos podem aparecer
    , CAST(((qs.total_logical_reads * 8) / 1024) AS NUMERIC(18,4)) AS total_logical_reads_mb
    , CAST(((qs.average_logical_reads * 8) / 1024) AS NUMERIC(18,4)) AS average_logical_reads_mb
    , CAST(((qs.stdev_logical_reads * 8) / 1024) AS NUMERIC(18,4)) AS stdev_logical_reads_mb
    , CAST(((qs.min_logical_reads * 8) / 1024) AS NUMERIC(18,4)) AS min_logical_reads_mb
    , CAST(((qs.max_logical_reads * 8) / 1024) AS NUMERIC(18,4)) AS max_logical_reads_mb
    , CAST(((qs.logical_reads_50th * 8) / 1024) AS NUMERIC(18,4)) AS logical_reads_50th_mb
    , CAST(((qs.logical_reads_75th * 8) / 1024) AS NUMERIC(18,4)) AS logical_reads_75th_mb
    , CAST(((qs.logical_reads_90th * 8) / 1024) AS NUMERIC(18,4)) AS logical_reads_90th_mb
    , CAST(((qs.logical_reads_95th * 8) / 1024) AS NUMERIC(18,4)) AS logical_reads_95th_mb
    , CAST(((qs.logical_reads_99th * 8) / 1024) AS NUMERIC(18,4)) AS logical_reads_99th_mb

    , CAST(((qs.total_writes * 8) / 1024) AS NUMERIC(18,4)) AS total_writes_mb
    , CAST(((qs.average_writes * 8) / 1024) AS NUMERIC(18,4)) AS average_writes_mb
    , CAST(((qs.stdev_writes * 8) / 1024) AS NUMERIC(18,4)) AS stdev_writes_mb
    , CAST(((qs.min_writes * 8) / 1024) AS NUMERIC(18,4)) AS min_writes_mb
    , CAST(((qs.max_writes * 8) / 1024) AS NUMERIC(18,4)) AS max_writes_mb
    , CAST(((qs.writes_50th * 8) / 1024) AS NUMERIC(18,4)) AS writes_50th_mb
    , CAST(((qs.writes_75th * 8) / 1024) AS NUMERIC(18,4)) AS writes_75th_mb
    , CAST(((qs.writes_90th * 8) / 1024) AS NUMERIC(18,4)) AS writes_90th_mb
    , CAST(((qs.writes_95th * 8) / 1024) AS NUMERIC(18,4)) AS writes_95th_mb
    , CAST(((qs.writes_99th * 8) / 1024) AS NUMERIC(18,4)) AS writes_99th_mb
FROM query_stats AS qs
WHERE qs.event_interval >= '2026-09-30 09:00:00' --AND qs.event_interval < '2025-10-18'
--AND qs.statement LIKE '%A-za-z$/%'

ORDER BY qs.event_interval ASC, qs.total_duration_ms DESC
OPTION (RECOMPILE);


-- ============================================================
-- result 02 - performance wait
-- ============================================================

-- CTE 1: estatísticas descritivas dos waits por query, intervalo e tipo de wait
;WITH waits_analyzed AS
(
    SELECT
        database_name
        , query_hash
        , query_plan_hash
        , event_interval
        , statement
        , wait_type
        , SUM(duration_ms) AS total_duration_ms
        , AVG(duration_ms) AS average_duration_ms
        , COALESCE(STDEVP(duration_ms), 0) AS stdev_duration_ms
        , MIN(duration_ms) AS min_duration_ms
        , MAX(duration_ms) AS max_duration_ms
        , SUM(signal_duration_ms) AS total_signal_duration_ms
        , AVG(signal_duration_ms) AS average_signal_duration_ms
        , COALESCE(STDEVP(signal_duration_ms), 0) AS stdev_signal_duration_ms
        , MIN(signal_duration_ms) AS min_signal_duration_ms
        , MAX(signal_duration_ms) AS max_signal_duration_ms
    FROM history_waits
    GROUP BY
        query_hash
        , query_plan_hash
        , event_interval
        , statement
        , wait_type
        , database_name
)
-- CTE 2: percentis de duração e de signal wait por query, intervalo e tipo de wait
, waits_ntile_cte AS
(
    SELECT DISTINCT
        database_name
        , query_hash
        , query_plan_hash
        , event_interval
        , statement
        , wait_type
        , PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY duration_ms) OVER (PARTITION BY database_name, query_hash, query_plan_hash, event_interval, statement, wait_type) AS duration_50th
        , PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY duration_ms) OVER (PARTITION BY database_name, query_hash, query_plan_hash, event_interval, statement, wait_type) AS duration_75th
        , PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY duration_ms) OVER (PARTITION BY database_name, query_hash, query_plan_hash, event_interval, statement, wait_type) AS duration_90th
        , PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY duration_ms) OVER (PARTITION BY database_name, query_hash, query_plan_hash, event_interval, statement, wait_type) AS duration_95th
        , PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY duration_ms) OVER (PARTITION BY database_name, query_hash, query_plan_hash, event_interval, statement, wait_type) AS duration_99th
        , PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY signal_duration_ms) OVER (PARTITION BY database_name, query_hash, query_plan_hash, event_interval, statement, wait_type) AS signal_duration_50th
        , PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY signal_duration_ms) OVER (PARTITION BY database_name, query_hash, query_plan_hash, event_interval, statement, wait_type) AS signal_duration_75th
        , PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY signal_duration_ms) OVER (PARTITION BY database_name, query_hash, query_plan_hash, event_interval, statement, wait_type) AS signal_duration_90th
        , PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY signal_duration_ms) OVER (PARTITION BY database_name, query_hash, query_plan_hash, event_interval, statement, wait_type) AS signal_duration_95th
        , PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY signal_duration_ms) OVER (PARTITION BY database_name, query_hash, query_plan_hash, event_interval, statement, wait_type) AS signal_duration_99th
    FROM history_waits
)
-- CTE 3: soma total dos waits por query e intervalo
, wait_rank AS
(
    SELECT
        database_name
        , query_hash
        , query_plan_hash
        , event_interval
        , statement
        , SUM(total_duration_ms) AS r
    FROM waits_analyzed
    GROUP BY database_name, query_hash, query_plan_hash, event_interval, statement
)
-- CTE 4: une as estatísticas descritivas, os percentis e o rank dos waits
, waits AS
(
    SELECT
        wc.database_name
        , wc.query_hash
        , wc.query_plan_hash
        , wc.event_interval
        , wc.statement
        , wc.wait_type

        , wc.total_duration_ms
        , wc.average_duration_ms
        , wc.stdev_duration_ms
        , wc.min_duration_ms
        , wc.max_duration_ms
        , wnc.duration_50th
        , wnc.duration_75th
        , wnc.duration_90th
        , wnc.duration_95th
        , wnc.duration_99th

        , wc.total_signal_duration_ms
        , wc.average_signal_duration_ms
        , wc.stdev_signal_duration_ms
        , wc.min_signal_duration_ms
        , wc.max_signal_duration_ms
        , wnc.signal_duration_50th
        , wnc.signal_duration_75th
        , wnc.signal_duration_90th
        , wnc.signal_duration_95th
        , wnc.signal_duration_99th
    FROM waits_analyzed AS wc
    JOIN waits_ntile_cte AS wnc
        ON wc.query_hash = wnc.query_hash
        AND wc.query_plan_hash = wnc.query_plan_hash
        AND wc.event_interval = wnc.event_interval
        AND wc.statement = wnc.statement
        AND wc.wait_type = wnc.wait_type
        AND wc.database_name = wnc.database_name
    JOIN wait_rank AS wr
        ON wc.query_hash = wr.query_hash
        AND wc.query_plan_hash = wr.query_plan_hash
        AND wc.event_interval = wr.event_interval
        AND wc.statement = wr.statement
        AND wc.database_name = wr.database_name
)
-- Resultado final: converte as durações dos waits (milissegundos para segundos)
SELECT
    w.database_name
    , REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(LTRIM(RTRIM(w.statement)), NCHAR(13), ' '), NCHAR(10), ' '), NCHAR(9), ' '), ' ','<>'),'><',''),'<>',' ') AS QueryText
    , w.event_interval
    , w.wait_type

    -- wait_info -> milisegundos
    , CAST(w.total_duration_ms / 1000.0 AS NUMERIC(18,2)) AS wait_total_duration_s
    , CAST(w.average_duration_ms / 1000.0 AS NUMERIC(18,2)) AS wait_average_duration_s
    , CAST(w.stdev_duration_ms / 1000.0 AS NUMERIC(18,2)) AS wait_stdev_duration_s
    , CAST(w.min_duration_ms / 1000.0 AS NUMERIC(18,2)) AS wait_min_duration_s
    , CAST(w.max_duration_ms / 1000.0 AS NUMERIC(18,2)) AS wait_max_duration_s
    , CAST(w.duration_50th / 1000.0 AS NUMERIC(18,2)) AS wait_duration_50th
    , CAST(w.duration_75th / 1000.0 AS NUMERIC(18,2)) AS wait_duration_75th
    , CAST(w.duration_90th / 1000.0 AS NUMERIC(18,2)) AS wait_duration_90th
    , CAST(w.duration_95th / 1000.0 AS NUMERIC(18,2)) AS wait_duration_95th
    , CAST(w.duration_99th / 1000.0 AS NUMERIC(18,2)) AS wait_duration_99th

    , w.total_signal_duration_ms AS signal_wait_total_duration_ms
    , w.average_signal_duration_ms AS signal_wait_average_duration_ms
    , w.stdev_signal_duration_ms AS signal_wait_stdev_duration_ms
    , w.min_signal_duration_ms AS signal_wait_min_duration_ms
    , w.max_signal_duration_ms AS signal_wait_max_duration_ms
    , w.signal_duration_50th AS signal_wait_duration_50th
    , w.signal_duration_75th AS signal_wait_duration_75th
    , w.signal_duration_90th AS signal_wait_duration_90th
    , w.signal_duration_95th AS signal_wait_duration_95th
    , w.signal_duration_99th AS signal_wait_duration_99th

    , w.query_hash
    , w.query_plan_hash
FROM waits AS w
WHERE w.event_interval >= '2026-09-30 09:00:00'

ORDER BY w.event_interval ASC, w.total_duration_ms DESC
OPTION (RECOMPILE);
