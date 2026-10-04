/*
 *
    OBJETIVO: Consultas analíticas sobre as tabelas históricas de queries caras
              (history_slow_query_batch_rpc e history_slow_query_statement),
              incluindo top N por recência, top N por duração e agregações
              de performance por texto de query.
    PROJETO: mssql-xe-observability

    REFERÊNCIAS:
 *  Documentação oficial: ROW_NUMBER, CTE, GROUP BY, HAVING
 */
 USE DBA_PerformanceHub
 GO

-- ============================================================
-- TABELA DE REQUISIÇÕES: history_slow_query_batch_rpc
-- ============================================================

-- ============================================================
-- Bloco 01: Top 20 das lentas DISTINTAS mais recentes (batch/RPC)
-- ============================================================
;WITH querys_counted AS
(
    SELECT
          hsqbr.Dt_Evento
        , hsqbr.object_name
        , hsqbr.session_id
        , hsqbr.database_name
        , hsqbr.username
        , hsqbr.session_server_principal_name
        , hsqbr.client_hostname
        , hsqbr.client_app_name
        , hsqbr.duration
        , hsqbr.cpu_time
        , hsqbr.logical_reads
        , hsqbr.physical_reads
        , hsqbr.writes
        , hsqbr.row_count
        , hsqbr.sql_text
        , hsqbr.batch_text
        , hsqbr.result
        , ROW_NUMBER() OVER (PARTITION BY hsqbr.batch_text ORDER BY hsqbr.batch_text) AS row_number_text
    FROM history_slow_query_batch_rpc hsqbr
    WHERE hsqbr.client_hostname NOT LIKE '%OSIRIS%'
        AND hsqbr.client_app_name NOT LIKE '%SQLAgent%'
        AND hsqbr.client_app_name NOT LIKE '%DatabaseMail%'
        AND hsqbr.Dt_Evento >= '2026-09-29 16:10:00'
        AND hsqbr.Dt_Evento <= '2026-09-29 16:30:00'
)
SELECT TOP 100
      Dt_Evento
    , object_name
    , session_id
    , database_name
    , username
    , session_server_principal_name
    , client_hostname
    , client_app_name
    , duration
    , cpu_time
    , logical_reads
    , physical_reads
    , writes
    , row_count
    , sql_text
    , batch_text
    , result
FROM querys_counted
WHERE row_number_text = 1
ORDER BY Dt_Evento DESC
GO

-- ============================================================
-- Bloco 02: Top 20 das lentas por maior duração (batch/RPC)
-- ============================================================
;WITH querys_counted AS
(
    SELECT
          hsqbr.Dt_Evento
        , hsqbr.object_name
        , hsqbr.session_id
        , hsqbr.database_name
        , hsqbr.username
        , hsqbr.session_server_principal_name
        , hsqbr.client_hostname
        , hsqbr.client_app_name
        , hsqbr.duration
        , hsqbr.cpu_time
        , hsqbr.logical_reads
        , hsqbr.physical_reads
        , hsqbr.writes
        , hsqbr.row_count
        , hsqbr.sql_text
        , hsqbr.batch_text
        , hsqbr.result
        , ROW_NUMBER() OVER (PARTITION BY hsqbr.batch_text ORDER BY hsqbr.batch_text) AS row_number_text
    FROM history_slow_query_batch_rpc hsqbr
    WHERE hsqbr.client_hostname NOT LIKE '%OSIRIS%'
        AND hsqbr.client_app_name NOT LIKE '%SQLAgent%'
        AND hsqbr.client_app_name NOT LIKE '%DatabaseMail%'
        AND hsqbr.Dt_Evento >= '2026-09-29 16:10:00'
        AND hsqbr.Dt_Evento <= '2026-09-29 16:30:00'
)
SELECT TOP 100
      Dt_Evento
    , object_name
    , session_id
    , database_name
    , username
    , session_server_principal_name
    , client_hostname
    , client_app_name
    , duration
    , cpu_time
    , logical_reads
    , physical_reads
    , writes
    , row_count
    , sql_text
    , batch_text
    , result
FROM querys_counted
WHERE row_number_text = 1
ORDER BY duration DESC
GO

-- ============================================================
-- Bloco 03: Consultas pela maior quantidade de execução (batch/RPC)
-- ============================================================
SELECT
      COUNT(hsqbr.batch_text) AS total_count_for_query
    , MIN(hsqbr.Dt_Evento) AS first_Dt_Evento
    , MAX(hsqbr.Dt_Evento) AS last_Dt_Evento
    , AVG(hsqbr.duration) AS avg_duration
    , AVG(hsqbr.cpu_time) AS avg_cpu_time
    , AVG(hsqbr.logical_reads) AS avg_logical_reads
    , AVG(hsqbr.physical_reads) AS avg_physical_reads
    , AVG(hsqbr.writes) AS avg_writes
    , AVG(hsqbr.row_count) AS avg_row_count
    , hsqbr.client_hostname
    , hsqbr.batch_text
FROM history_slow_query_batch_rpc hsqbr
WHERE hsqbr.client_hostname NOT LIKE '%OSIRIS%'
    AND hsqbr.client_app_name NOT LIKE '%SQLAgent%'
    AND hsqbr.client_app_name NOT LIKE '%DatabaseMail%'
    AND hsqbr.Dt_Evento >= '2026-09-29'
GROUP BY
      hsqbr.batch_text
    , hsqbr.client_hostname
HAVING COUNT(hsqbr.batch_text) > 1
GO

-- ============================================================
-- TABELA DE REQUISIÇÕES: history_slow_query_statement
-- ============================================================

-- ============================================================
-- Bloco 04: Top 20 das lentas mais recentes (statement)
-- ============================================================
;WITH querys_counted AS
(
    SELECT
          hsqs.Dt_Evento
        , hsqs.session_id
        , hsqs.database_name
        , hsqs.username
        , hsqs.session_server_principal_name
        , hsqs.client_hostname
        , hsqs.client_app_name
        , hsqs.duration
        , hsqs.cpu_time
        , hsqs.logical_reads
        , hsqs.physical_reads
        , hsqs.writes
        , hsqs.row_count
        , hsqs.sql_text
        , ROW_NUMBER() OVER (PARTITION BY hsqs.sql_text ORDER BY hsqs.sql_text) AS row_number_text
    FROM history_slow_query_statement hsqs
    WHERE hsqs.client_hostname NOT LIKE '%OSIRIS%'
        AND hsqs.client_app_name NOT LIKE '%SQLAgent%'
        AND hsqs.client_app_name NOT LIKE '%DatabaseMail%'
        AND hsqs.Dt_Evento >= '2026-09-29'
)
SELECT TOP 20
      Dt_Evento
    , session_id
    , database_name
    , username
    , session_server_principal_name
    , client_hostname
    , client_app_name
    , duration
    , cpu_time
    , logical_reads
    , physical_reads
    , writes
    , row_count
    , sql_text
FROM querys_counted
WHERE row_number_text = 1
ORDER BY Dt_Evento DESC
GO

-- ============================================================
-- Bloco 05: Top 20 das lentas por maior duração (statement)
-- ============================================================
;WITH querys_counted AS
(
    SELECT
          hsqs.Dt_Evento
        , hsqs.session_id
        , hsqs.database_name
        , hsqs.username
        , hsqs.session_server_principal_name
        , hsqs.client_hostname
        , hsqs.client_app_name
        , hsqs.duration
        , hsqs.cpu_time
        , hsqs.logical_reads
        , hsqs.physical_reads
        , hsqs.writes
        , hsqs.row_count
        , hsqs.sql_text
        , ROW_NUMBER() OVER (PARTITION BY hsqs.sql_text ORDER BY hsqs.sql_text) AS row_number_text
    FROM history_slow_query_statement hsqs
    WHERE hsqs.client_hostname NOT LIKE '%OSIRIS%'
        AND hsqs.client_app_name NOT LIKE '%SQLAgent%'
        AND hsqs.client_app_name NOT LIKE '%DatabaseMail%'
        AND hsqs.Dt_Evento >= '2026-09-29'
)
SELECT TOP 100
      Dt_Evento
    , session_id
    , database_name
    , username
    , session_server_principal_name
    , client_hostname
    , client_app_name
    , duration
    , cpu_time
    , logical_reads
    , physical_reads
    , writes
    , row_count
    , sql_text
FROM querys_counted
WHERE row_number_text = 1
ORDER BY duration DESC
GO

-- ============================================================
-- Bloco 06: Consultas pela maior quantidade de execução (statement)
-- ============================================================
SELECT
      COUNT(hsqs.sql_text) AS total_count_for_query
    , MIN(hsqs.Dt_Evento) AS first_Dt_Evento
    , MAX(hsqs.Dt_Evento) AS last_Dt_Evento
    , AVG(hsqs.duration) AS avg_duration
    , AVG(hsqs.cpu_time) AS avg_cpu_time
    , AVG(hsqs.logical_reads) AS avg_logical_reads
    , AVG(hsqs.physical_reads) AS avg_physical_reads
    , AVG(hsqs.writes) AS avg_writes
    , AVG(hsqs.row_count) AS avg_row_count
    , hsqs.client_hostname
    , hsqs.sql_text
FROM history_slow_query_statement hsqs
WHERE hsqs.client_hostname NOT LIKE '%OSIRIS%'
    AND hsqs.client_app_name NOT LIKE '%SQLAgent%'
    AND hsqs.client_app_name NOT LIKE '%DatabaseMail%'
    AND hsqs.Dt_Evento >= '2026-09-29'
GROUP BY
      hsqs.sql_text
    , hsqs.client_hostname
HAVING COUNT(hsqs.sql_text) > 1
GO
