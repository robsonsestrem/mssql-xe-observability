/*
 *
    OBJETIVO: Ativação das sessões de Extended Events do monitoramento,
              iniciando apenas as sessões que ainda não estão em execução.
    
    PROJETO: mssql-xe-observability

    AUTHOR: Robson Sestrem

    REFERÊNCIAS DE URL:
 *  https://learn.microsoft.com/pt-br/sql/relational-databases/system-dynamic-management-views/sys-dm-xe-sessions-transact-sql
 */
-- ============================================================
-- Sessão query_performance_wait_info
-- ============================================================
IF NOT EXISTS
(
    SELECT 1
    FROM sys.dm_xe_sessions AS xs
    WHERE xs.name = N'query_performance_wait_info'
)
BEGIN
    ALTER EVENT SESSION [query_performance_wait_info] ON SERVER STATE = START
END
ELSE
BEGIN
    PRINT 'XE [query_performance_wait_info] está inicializada.'
END
GO

-- ============================================================
-- Sessão expensive_query_statement
-- ============================================================
IF NOT EXISTS
(
    SELECT 1
    FROM sys.dm_xe_sessions AS xs
    WHERE xs.name = N'expensive_query_statement'
)
BEGIN
    ALTER EVENT SESSION [expensive_query_statement] ON SERVER STATE = START
END
ELSE
BEGIN
    PRINT 'XE [expensive_query_statement] está inicializada.'
END
GO

-- ============================================================
-- Sessão expensive_query_batch_rpc
-- ============================================================
IF NOT EXISTS
(
    SELECT 1
    FROM sys.dm_xe_sessions AS xs
    WHERE xs.name = N'expensive_query_batch_rpc'
)
BEGIN
    ALTER EVENT SESSION [expensive_query_batch_rpc] ON SERVER STATE = START
END
ELSE
BEGIN
    PRINT 'XE [expensive_query_batch_rpc] está inicializada.'
END
GO

-- ============================================================
-- Sessão deadlocks
-- ============================================================
IF NOT EXISTS
(
    SELECT 1
    FROM sys.dm_xe_sessions AS xs
    WHERE xs.name = N'deadlocks'
)
BEGIN
    ALTER EVENT SESSION [deadlocks] ON SERVER STATE = START
END
ELSE
BEGIN
    PRINT 'XE [deadlocks] está inicializada.'
END
GO

-- ============================================================
-- Sessão system_error_collection
-- ============================================================
IF NOT EXISTS
(
    SELECT 1
    FROM sys.dm_xe_sessions AS xs
    WHERE xs.name = N'system_error_collection'
)
BEGIN
    ALTER EVENT SESSION [system_error_collection] ON SERVER STATE = START
END
ELSE
BEGIN
    PRINT 'XE [system_error_collection] está inicializada.'
END
GO

-- ============================================================
-- Sessão blocked_process
-- ============================================================
IF NOT EXISTS
(
    SELECT 1
    FROM sys.dm_xe_sessions AS xs
    WHERE xs.name = N'blocked_process'
)
BEGIN
    ALTER EVENT SESSION [blocked_process] ON SERVER STATE = START
END
ELSE
BEGIN
    PRINT 'XE [blocked_process] está inicializada.'
END
GO

-- ============================================================
-- Sessão dark_queries_recompile
-- ============================================================
IF NOT EXISTS
(
    SELECT 1
    FROM sys.dm_xe_sessions AS xs
    WHERE xs.name = N'dark_queries_recompile'
)
BEGIN
    ALTER EVENT SESSION [dark_queries_recompile] ON SERVER STATE = START
END
ELSE
BEGIN
    PRINT 'XE [dark_queries_recompile] está inicializada.'
END
GO

-- ============================================================
-- Sessão monitoring_timeouts
-- ============================================================
IF NOT EXISTS
(
    SELECT 1
    FROM sys.dm_xe_sessions AS xs
    WHERE xs.name = N'monitoring_timeouts'
)
BEGIN
    ALTER EVENT SESSION [monitoring_timeouts] ON SERVER STATE = START
END
ELSE
BEGIN
    PRINT 'XE [monitoring_timeouts] está inicializada.'
END
GO

-- ============================================================
-- Sessão monitor_page_splits_your_database
-- ============================================================
IF NOT EXISTS
(
    SELECT 1
    FROM sys.dm_xe_sessions AS xs
    WHERE xs.name = N'monitor_page_splits_your_database'
)
BEGIN
    ALTER EVENT SESSION [monitor_page_splits_your_database] ON SERVER STATE = START
END
ELSE
BEGIN
    PRINT 'XE [monitor_page_splits_your_database] está inicializada.'
END
GO

-- ============================================================
-- Sessão collect_ddl_statement
-- ============================================================
IF NOT EXISTS
(
    SELECT 1
    FROM sys.dm_xe_sessions AS xs
    WHERE xs.name = N'collect_ddl_statement'
)
BEGIN
    ALTER EVENT SESSION [collect_ddl_statement] ON SERVER STATE = START
END
ELSE
BEGIN
    PRINT 'XE [collect_ddl_statement] está inicializada.'
END
GO

-- ============================================================
-- Sessão plan_affecting_convert
-- ============================================================
IF NOT EXISTS
(
    SELECT 1
    FROM sys.dm_xe_sessions AS xs
    WHERE xs.name = N'plan_affecting_convert'
)
BEGIN
    ALTER EVENT SESSION [plan_affecting_convert] ON SERVER STATE = START
END
ELSE
BEGIN
    PRINT 'XE [plan_affecting_convert] está inicializada.'
END
GO

-- ============================================================
-- Sessão sort_warning_performance
-- ============================================================
IF NOT EXISTS
(
    SELECT 1
    FROM sys.dm_xe_sessions AS xs
    WHERE xs.name = N'sort_warning_performance'
)
BEGIN
    ALTER EVENT SESSION [sort_warning_performance] ON SERVER STATE = START
END
ELSE
BEGIN
    PRINT 'XE [sort_warning_performance] está inicializada.'
END
GO
