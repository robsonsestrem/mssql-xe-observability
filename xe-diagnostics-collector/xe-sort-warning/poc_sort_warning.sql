/*
 *
    OBJETIVO: PoC de monitoramento de sort warnings via Extended Events,
              capturando eventos de sort_warning para diagnóstico de
              problemas de memory grant, com armazenamento histórico
              e procedure de carga periódica.
    
    PROJETO: mssql-xe-observability

    AUTHOR: Robson Sestrem

    REFERÊNCIAS DE URL:
 *  https://amihalj.wordpress.com/2011/12/05/sql-server-2012-detecting-sort-warnings-with-extended-events-sort_warning-event/
 *  https://amihalj.wordpress.com/2011/12/07/sql-server-2012-detecting-sort-warnings-with-extended-events-sort_warning-event-part-2/
 *  https://www.sqlshack.com/sql-server-2017-sort-spill-memory-and-adaptive-memory-grant-feedback/
 *  https://lucient.com/en/blog/identifying-and-solving-sort-warnings-problems-in-sql-server/
 */
-- ============================================================
-- Criação da sessão de eventos estendidos de sort warning
-- ============================================================
IF EXISTS (SELECT * FROM sys.server_event_sessions WHERE name = 'sort_warning_performance')
    DROP EVENT SESSION sort_warning_performance ON SERVER
GO

CREATE EVENT SESSION sort_warning_performance
ON SERVER
ADD EVENT sqlserver.sort_warning
(
    ACTION
    (
          sqlos.task_time
        , sqlserver.client_app_name
        , sqlserver.client_hostname
        , sqlserver.query_hash
        , sqlserver.session_id
        , sqlserver.session_server_principal_name
        , sqlserver.sql_text
        , sqlserver.tsql_frame
        , sqlserver.username
        , sqlserver.database_id
        , sqlserver.database_name
    )
    WHERE
    (
        [package0].[equal_boolean]([sqlserver].[is_system], (0))
        AND [package0].[greater_than_uint64]([sqlserver].[query_hash], (0))
        AND [sqlserver].[not_equal_i_sql_unicode_string]([sqlserver].[client_hostname], N'OSIRIS-DATABASE')
        -- *** SEMPRE ATUALIZAR ***
        AND
        (
            [package0].[equal_i_unicode_string]([sqlserver].[database_name], N'YOUR_DATABASE')
            OR [package0].[equal_i_unicode_string]([sqlserver].[database_name], N'YOUR_DATABASE')
        )
    )
)
ADD TARGET package0.event_file
(
    SET filename = N'/var/opt/mssql/log_jobs/xe/sort_warning_performance*.xel'
      , max_file_size = (200)
      , max_rollover_files = (3)
      , metadatafile = N'/var/opt/mssql/log_jobs/xe/sort_warning_performance*.xem'
)
WITH
(
      MAX_MEMORY = 4096 KB
    , EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS
    , MAX_DISPATCH_LATENCY = 30 SECONDS
    , MAX_EVENT_SIZE = 0 KB
    , MEMORY_PARTITION_MODE = NONE
    , TRACK_CAUSALITY = OFF
    , STARTUP_STATE = ON
)
GO

-- ============================================================
-- Inicia a sessão caso ainda não esteja rodando
-- ============================================================
IF NOT EXISTS
(
    SELECT 1
    FROM sys.dm_xe_sessions xs
    WHERE xs.name = N'sort_warning_performance'
)
BEGIN
    ALTER EVENT SESSION sort_warning_performance ON SERVER STATE = START
END
GO

/*
 * TESTE PARA PROVOCAR O EVENTO
 *
    USE DBA_PerformanceHub
    GO

    CREATE TABLE dbo.TestTable (Col1 int IDENTITY(1,1), Col2 varchar(8000))
    GO

    INSERT INTO dbo.TestTable (Col2)
    SELECT REPLICATE('A','8000')
    GO 200

    CREATE PROCEDURE dbo.Test
    AS
    SET NOCOUNT ON

    DECLARE @T1 TABLE (Col1 int, Col2 varchar(8000))
    INSERT INTO @T1
    SELECT * FROM dbo.TestTable

    SELECT * FROM @T1
    ORDER BY Col2 ASC
    GO

    CREATE PROCEDURE dbo.Test1
    AS
    SET NOCOUNT ON

    DECLARE @T1 TABLE (Col1 int, Col2 varchar(8000))
    INSERT INTO @T1
    SELECT * FROM dbo.TestTable

    SELECT * FROM @T1
    ORDER BY Col2 ASC
    OPTION (RECOMPILE)

    SELECT DISTINCT Col2 FROM @T1

    SELECT Col2, COUNT(*) FROM @T1
    GROUP BY Col2

    EXEC dbo.Test
    GO

    EXEC dbo.Test1
    GO
 *
 */

-- ============================================================
-- Criação da tabela de histórico de sort warnings
-- ============================================================
USE DBA_PerformanceHub
GO

IF (OBJECT_ID('dbo.history_sort_warning_performance') IS NULL)
BEGIN
    CREATE TABLE dbo.history_sort_warning_performance
    (
          [timestamp_xe]                    DATETIME
        , [sort_warning_type]               NVARCHAR(128)
        , [granted_memory_kb]               BIGINT
        , [used_memory_kb]                  BIGINT
        , [worktable_physical_reads]        BIGINT
        , [worktable_physical_writes]       BIGINT
        , [actual_row_count]                BIGINT
        , [session_id]                      INT
        , [username]                        NVARCHAR(128)
        , [session_server_principal_name]   NVARCHAR(128)
        , [client_hostname]                 NVARCHAR(128)
        , [client_app_name]                 NVARCHAR(128)
        , [sql_text]                        VARCHAR(MAX)
        , [frame_level]                     SMALLINT
        , [sql_statement]                   NVARCHAR(MAX)
        , [query_hash]                      DECIMAL(38, 0)
        , [task_time]                       BIGINT
        , [database_id]                     SMALLINT
        , [database_name]                   NVARCHAR(128)
    )

    CREATE CLUSTERED INDEX idx_plan_sort_warning_performance
        ON dbo.history_sort_warning_performance ([timestamp_xe])
END
GO

-- ============================================================
-- Procedure de carga do histórico de sort warnings
-- ============================================================
USE DBA_PerformanceHub
GO

CREATE OR ALTER PROCEDURE [dbo].[sp_load_sort_warning_performance]
WITH ENCRYPTION
AS
BEGIN
    SET NOCOUNT ON
    SET XACT_ABORT ON

    BEGIN TRY
        BEGIN TRANSACTION

        DECLARE @TimeZone INT = DATEDIFF(HOUR, GETUTCDATE(), GETDATE())
              , @Dt_Ultimo_Registro DATETIME = ISNULL((SELECT MAX([timestamp_xe]) FROM dbo.history_sort_warning_performance WITH(NOLOCK)), '1900-01-01')

        IF (OBJECT_ID('tempdb..#Eventos') IS NOT NULL)
            DROP TABLE #Eventos

        -- ============================================================
        -- Leitura dos arquivos XE e filtragem por timestamp
        -- ============================================================
        SELECT *
        INTO #Eventos
        FROM
        (
            SELECT
                  CAST(DATEADD(HOUR, @TimeZone, CAST(timestamp_utc AS DATETIME2(3))) AS DATETIME) AS timestamp_utc
                , CONVERT(XML, event_data) AS event_data
            FROM sys.fn_xe_file_target_read_file(N'/var/opt/mssql/log_jobs/xe/sort_warning_performance*.xel', N'/var/opt/mssql/log_jobs/xe/sort_warning_performance*.xem', NULL, NULL)
        ) AS dados
        WHERE timestamp_utc > @Dt_Ultimo_Registro

        -- ============================================================
        -- Inserção dos eventos extraídos do XML na tabela de histórico
        -- ============================================================
        INSERT INTO history_sort_warning_performance
        (
              timestamp_xe
            , sort_warning_type
            , granted_memory_kb
            , used_memory_kb
            , worktable_physical_reads
            , worktable_physical_writes
            , actual_row_count
            , session_id
            , username
            , session_server_principal_name
            , client_hostname
            , client_app_name
            , sql_text
            , frame_level
            , sql_statement
            , query_hash
            , task_time
            , database_id
            , database_name
        )
        SELECT
              A.[timestamp_utc]
            , xed.event_data.value('(data[@name="sort_warning_type"]/text)[1]', 'sysname') AS [sort_warning_type]
            , xed.event_data.value('(data[@name="granted_memory_kb"]/value)[1]', 'bigint') AS [granted_memory_kb]
            , xed.event_data.value('(data[@name="used_memory_kb"]/value)[1]', 'bigint') AS [used_memory_kb]
            , xed.event_data.value('(data[@name="worktable_physical_reads"]/value)[1]', 'bigint') AS [worktable_physical_reads]
            , xed.event_data.value('(data[@name="worktable_physical_writes"]/value)[1]', 'bigint') AS [worktable_physical_writes]
            , xed.event_data.value('(data[@name="actual_row_count"]/value)[1]', 'bigint') AS [actual_row_count]
            , xed.event_data.value('(action[@name="session_id"]/value)[1]', 'int') AS [session_id]
            , xed.event_data.value('(action[@name="username"]/value)[1]', 'sysname') AS [username]
            , xed.event_data.value('(action[@name="session_server_principal_name"]/value)[1]', 'sysname') AS [session_server_principal_name]
            , xed.event_data.value('(action[@name="client_hostname"]/value)[1]', 'sysname') AS [client_hostname]
            , xed.event_data.value('(action[@name="client_app_name"]/value)[1]', 'sysname') AS [client_app_name]
            , xed.event_data.value('(action[@name="sql_text"]/value)[1]', 'varchar(max)') AS [sql_text]
            , frame_data.value('./@level', 'smallint') AS [frame_level]
            , SUBSTRING(st.text, (frame_data.value('./@offsetStart', 'int') / 2) + 1,
                ((CASE frame_data.value('./@offsetEnd', 'int')
                    WHEN -1 THEN DATALENGTH(st.text)
                    ELSE frame_data.value('./@offsetEnd', 'int')
                END - frame_data.value('./@offsetStart', 'int')) / 2) + 1) AS [sql_statement]
            , xed.event_data.value('(action[@name="query_hash"]/value)[1]', 'decimal(38,0)') AS [query_hash]
            , xed.event_data.value('(action[@name="task_time"]/value)[1]', 'bigint') AS [task_time]
            , xed.event_data.value('(action[@name="database_id"]/value)[1]', 'int') AS [database_id]
            , xed.event_data.value('(action[@name="database_name"]/value)[1]', 'sysname') AS [database_name]
        FROM #Eventos AS A
            CROSS APPLY A.event_data.nodes('//event') AS xed (event_data)
            CROSS APPLY A.event_data.nodes('event/action[@name="tsql_frame"]/value/frame') AS Frame (frame_data)
            OUTER APPLY sys.dm_exec_sql_text(CONVERT(VARBINARY(MAX), frame_data.value('./@handle', 'varchar(max)'), 1)) AS st

        COMMIT TRANSACTION

    END TRY

    BEGIN CATCH
        DECLARE @ErrorMessage NVARCHAR(4000)
              , @ErrorSeverity INT

        SELECT
              @ErrorMessage = N'PROCEDURE: [sp_load_sort_warning_performance]; - Erro na linha ' + CAST(ERROR_LINE() AS VARCHAR(10))
                            + ' - ' + ERROR_PROCEDURE()
                            + ' - ' + CAST(ERROR_STATE() AS VARCHAR(10))
                            + ' - ' + ERROR_MESSAGE()
                            + ' - ' + CAST(ERROR_NUMBER() AS VARCHAR(10))
            , @ErrorSeverity = ERROR_SEVERITY()

        RAISERROR(@ErrorMessage, @ErrorSeverity, 1)

        IF (XACT_STATE()) = -1
        BEGIN
            PRINT N'A transação está em um estado incompatível. Retrocedendo transação.'
            ROLLBACK TRANSACTION
        END

        IF (XACT_STATE()) = 1
        BEGIN
            PRINT N'A transação é compatível. Transação completada.'
            COMMIT TRANSACTION
        END
    END CATCH

    SET NOCOUNT OFF
    SET XACT_ABORT OFF
END
GO
