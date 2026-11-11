/*
 *
    OBJETIVO: Parada das sessões de Extended Events do monitoramento,
              interrompendo apenas as sessões que estão em execução.
    
    PROJETO: mssql-xe-observability

    AUTHOR: Robson Sestrem

    REFERÊNCIAS DE URL:
 *  https://learn.microsoft.com/pt-br/sql/relational-databases/system-dynamic-management-views/sys-dm-xe-sessions-transact-sql
 */
-- ============================================================
-- Sessão query_performance_wait_info
-- ============================================================
IF EXISTS
(
    SELECT 1
    FROM sys.dm_xe_sessions AS xs
    WHERE xs.name = N'query_performance_wait_info'
)
BEGIN
    ALTER EVENT SESSION [query_performance_wait_info] ON SERVER STATE = STOP
END
ELSE
BEGIN
    PRINT 'XE [query_performance_wait_info] não existe.'
END
GO

-- ============================================================
-- Sessão expensive_query_statement
-- ============================================================
IF EXISTS
(
    SELECT 1
    FROM sys.dm_xe_sessions AS xs
    WHERE xs.name = N'expensive_query_statement'
)
BEGIN
    ALTER EVENT SESSION [expensive_query_statement] ON SERVER STATE = STOP
END
ELSE
BEGIN
    PRINT 'XE [expensive_query_statement] não existe.'
END
GO

-- ============================================================
-- Sessão expensive_query_batch_rpc
-- ============================================================
IF EXISTS
(
    SELECT 1
    FROM sys.dm_xe_sessions AS xs
    WHERE xs.name = N'expensive_query_batch_rpc'
)
BEGIN
    ALTER EVENT SESSION [expensive_query_batch_rpc] ON SERVER STATE = STOP
END
ELSE
BEGIN
    PRINT 'XE [expensive_query_batch_rpc] não existe.'
END
GO

-- ============================================================
-- Sessão deadlocks
-- ============================================================
IF EXISTS
(
    SELECT 1
    FROM sys.dm_xe_sessions AS xs
    WHERE xs.name = N'deadlocks'
)
BEGIN
    ALTER EVENT SESSION [deadlocks] ON SERVER STATE = STOP
END
ELSE
BEGIN
    PRINT 'XE [deadlocks] não existe.'
END
GO

-- ============================================================
-- Sessão system_error_collection
-- ============================================================
IF EXISTS
(
    SELECT 1
    FROM sys.dm_xe_sessions AS xs
    WHERE xs.name = N'system_error_collection'
)
BEGIN
    ALTER EVENT SESSION [system_error_collection] ON SERVER STATE = STOP
END
ELSE
BEGIN
    PRINT 'XE [system_error_collection] não existe.'
END
GO

-- ============================================================
-- Sessão blocked_process
-- ============================================================
IF EXISTS
(
    SELECT 1
    FROM sys.dm_xe_sessions AS xs
    WHERE xs.name = N'blocked_process'
)
BEGIN
    ALTER EVENT SESSION [blocked_process] ON SERVER STATE = STOP
END
ELSE
BEGIN
    PRINT 'XE [blocked_process] não existe.'
END
GO

-- ============================================================
-- Sessão dark_queries_recompile
-- ============================================================
IF EXISTS
(
    SELECT 1
    FROM sys.dm_xe_sessions AS xs
    WHERE xs.name = N'dark_queries_recompile'
)
BEGIN
    ALTER EVENT SESSION [dark_queries_recompile] ON SERVER STATE = STOP
END
ELSE
BEGIN
    PRINT 'XE [dark_queries_recompile] não existe.'
END
GO

-- ============================================================
-- Sessão monitoring_timeouts
-- ============================================================
IF EXISTS
(
    SELECT 1
    FROM sys.dm_xe_sessions AS xs
    WHERE xs.name = N'monitoring_timeouts'
)
BEGIN
    ALTER EVENT SESSION [monitoring_timeouts] ON SERVER STATE = STOP
END
ELSE
BEGIN
    PRINT 'XE [monitoring_timeouts] não existe.'
END
GO

-- ============================================================
-- Sessão monitor_page_splits_your_database
-- ============================================================
IF EXISTS
(
    SELECT 1
    FROM sys.dm_xe_sessions AS xs
    WHERE xs.name = N'monitor_page_splits_your_database'
)
BEGIN
    ALTER EVENT SESSION [monitor_page_splits_your_database] ON SERVER STATE = STOP
END
ELSE
BEGIN
    PRINT 'XE [monitor_page_splits_your_database] não existe.'
END
GO

-- ============================================================
-- Sessão collect_ddl_statement
-- ============================================================
IF EXISTS
(
    SELECT 1
    FROM sys.dm_xe_sessions AS xs
    WHERE xs.name = N'collect_ddl_statement'
)
BEGIN
    ALTER EVENT SESSION [collect_ddl_statement] ON SERVER STATE = STOP
END
ELSE
BEGIN
    PRINT 'XE [collect_ddl_statement] não existe.'
END
GO

-- ============================================================
-- Sessão plan_affecting_convert
-- ============================================================
IF EXISTS
(
    SELECT 1
    FROM sys.dm_xe_sessions AS xs
    WHERE xs.name = N'plan_affecting_convert'
)
BEGIN
    ALTER EVENT SESSION [plan_affecting_convert] ON SERVER STATE = STOP
END
ELSE
BEGIN
    PRINT 'XE [plan_affecting_convert] não existe.'
END
GO

-- ============================================================
-- Sessão sort_warning_performance
-- ============================================================
IF EXISTS
(
    SELECT 1
    FROM sys.dm_xe_sessions AS xs
    WHERE xs.name = N'sort_warning_performance'
)
BEGIN
    ALTER EVENT SESSION [sort_warning_performance] ON SERVER STATE = STOP
END
ELSE
BEGIN
    PRINT 'XE [sort_warning_performance] não existe.'
END
GO
