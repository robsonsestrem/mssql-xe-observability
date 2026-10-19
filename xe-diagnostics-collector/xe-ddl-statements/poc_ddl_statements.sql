/*
 *
    OBJETIVO: PoC de captura de DDL (Data Definition Language) via Extended Events,
              registrando eventos de object_altered, object_created e object_deleted
              em tabela histórica, com extração de pilha T-SQL e texto das instruções.
    PROJETO: mssql-xe-observability

    AUTHOR: Robson Sestrem

    REFERÊNCIAS DE URL:
 *  https://sqlsolutionsgroup.com/using-extended-event-session/
 *  https://dba.stackexchange.com/questions/309901/extended-events-capture-all-calls-by-login-user-and-sql-text-containing-a-value
 *  https://www.mssqltips.com/sqlservertip/6697/sql-server-extended-events-database-name-filtering/
 *  https://www.red-gate.com/hub/product-learning/redgate-monitor/checking-database-drift-using-extended-events-sql-monitor
 *  https://straightforwardsql.com/posts/investigating-errors-with-extended-events/
 *  https://dba.stackexchange.com/questions/327956/trace-what-is-calling-a-trigger-extended-events-question
 */
-- ============================================================
-- Criação da sessão de eventos estendidos para DDL
-- ============================================================
IF EXISTS (SELECT * FROM sys.server_event_sessions WHERE name = 'collect_ddl_statement')
    DROP EVENT SESSION collect_ddl_statement ON SERVER
GO

CREATE EVENT SESSION [collect_ddl_statement] ON SERVER

-- ============================================================
-- Evento: object_altered
-- ============================================================
ADD EVENT sqlserver.object_altered
(
    SET collect_database_name = (1)
    ACTION
    (
          sqlos.task_time
        , sqlserver.client_app_name
        , sqlserver.client_hostname
        , sqlserver.session_id
        , sqlserver.session_server_principal_name
        , sqlserver.sql_text
        , sqlserver.tsql_stack
        , sqlserver.username
    )
    WHERE
    (
        [package0].[equal_uint64]([ddl_phase], 'Commit')
        AND [sqlserver].[not_equal_i_sql_unicode_string]([database_name], N'tempdb')
        AND [sqlserver].[not_equal_i_sql_unicode_string]([database_name], N'master')
    )
),

-- ============================================================
-- Evento: object_created
-- ============================================================
ADD EVENT sqlserver.object_created
(
    SET collect_database_name = (1)
    ACTION
    (
          sqlos.task_time
        , sqlserver.client_app_name
        , sqlserver.client_hostname
        , sqlserver.session_id
        , sqlserver.session_server_principal_name
        , sqlserver.sql_text
        , sqlserver.tsql_stack
        , sqlserver.username
    )
    WHERE
    (
        [package0].[equal_uint64]([ddl_phase], 'Commit')
        AND [sqlserver].[not_equal_i_sql_unicode_string]([database_name], N'tempdb')
        AND [sqlserver].[not_equal_i_sql_unicode_string]([database_name], N'master')
    )
),

-- ============================================================
-- Evento: object_deleted
-- ============================================================
ADD EVENT sqlserver.object_deleted
(
    SET collect_database_name = (1)
    ACTION
    (
          sqlos.task_time
        , sqlserver.client_app_name
        , sqlserver.client_hostname
        , sqlserver.session_id
        , sqlserver.session_server_principal_name
        , sqlserver.sql_text
        , sqlserver.tsql_stack
        , sqlserver.username
    )
    WHERE
    (
        [package0].[equal_uint64]([ddl_phase], 'Commit')
        AND [sqlserver].[not_equal_i_sql_unicode_string]([database_name], N'tempdb')
        AND [sqlserver].[not_equal_i_sql_unicode_string]([database_name], N'master')
    )
)

-- ============================================================
-- Destino: arquivo de evento
-- ============================================================
ADD TARGET package0.event_file
(
    SET filename = N'/var/opt/mssql/log_jobs/xe/collect_ddl_statement*.xel'
      , max_file_size = (200)
      , max_rollover_files = (3)
      , metadatafile = N'/var/opt/mssql/log_jobs/xe/collect_ddl_statement*.xem'
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
    WHERE xs.name = N'collect_ddl_statement'
)
BEGIN
    ALTER EVENT SESSION [collect_ddl_statement] ON SERVER STATE = START
END
GO

-- ============================================================
-- Criação da tabela de histórico de eventos DDL
-- ============================================================
USE DBA_PerformanceHub
GO

-- DROP TABLE history_ddl_statement

CREATE TABLE dbo.history_ddl_statement
(
      [row_id]                          INT IDENTITY(1, 1) NOT NULL PRIMARY KEY
    , [timestamp_xe]                    DATETIME
    , [event_name]                      NVARCHAR(128)
    , [index_id]                        BIGINT
    , [object_type]                     NVARCHAR(128)
    , [object_id]                       BIGINT
    , [object_name]                     NVARCHAR(128)
    , [database_id]                     SMALLINT
    , [database_name]                   NVARCHAR(128)
    , [session_id]                      INT
    , [username]                        NVARCHAR(128)
    , [session_server_principal_name]   NVARCHAR(128)
    , [client_hostname]                 NVARCHAR(128)
    , [client_app_name]                 NVARCHAR(128)
    , [sql_text]                        VARCHAR(MAX)
    , [frame_level]                     SMALLINT
    , [sql_statement]                   NVARCHAR(MAX)
    , [tsql_stack]                      NVARCHAR(MAX)
    , [task_time]                       BIGINT
)
WITH (DATA_COMPRESSION = PAGE)
GO

-- ============================================================
-- Procedure de carga do histórico de eventos DDL
-- ============================================================
USE DBA_PerformanceHub
GO

CREATE OR ALTER PROCEDURE [dbo].[sp_load_ddl_statement]
WITH ENCRYPTION
AS
BEGIN
    SET NOCOUNT ON
    SET XACT_ABORT ON

    BEGIN TRY
        BEGIN TRANSACTION

        DECLARE @Dt_Ultimo_Registro DATETIME = ISNULL((SELECT MAX([timestamp_xe]) FROM dbo.history_ddl_statement WITH(NOLOCK)), '1900-01-01')
              , @TimeZone INT = DATEDIFF(HOUR, GETUTCDATE(), GETDATE())

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
            FROM sys.fn_xe_file_target_read_file(N'/var/opt/mssql/log_jobs/xe/collect_ddl_statement*.xel', N'/var/opt/mssql/log_jobs/xe/collect_ddl_statement*.xem', NULL, NULL)
        ) AS dados
        WHERE timestamp_utc > @Dt_Ultimo_Registro

        -- ============================================================
        -- Inserção dos eventos extraídos do XML na tabela de histórico
        -- ============================================================
        INSERT INTO history_ddl_statement
        (
              [timestamp_xe]
            , [event_name]
            , [index_id]
            , [object_type]
            , [object_id]
            , [object_name]
            , [database_id]
            , [database_name]
            , [session_id]
            , [username]
            , [session_server_principal_name]
            , [client_hostname]
            , [client_app_name]
            , [sql_text]
            , [frame_level]
            , [sql_statement]
            , [tsql_stack]
            , [task_time]
        )
        SELECT
              A.timestamp_utc
            , xed.event_data.value('(@name)[1]', 'sysname') AS [event_name]
            , xed.event_data.value('(data[@name="index_id"]/value)[1]', 'bigint') AS index_id
            , xed.event_data.value('(data[@name="object_type"]/text)[1]', 'sysname') AS object_type
            , xed.event_data.value('(data[@name="object_id"]/value)[1]', 'bigint') AS [object_id]
            , xed.event_data.value('(data[@name="object_name"]/value)[1]', 'sysname') AS [object_name]
            , xed.event_data.value('(data[@name="database_id"]/value)[1]', 'smallint') AS database_id
            , xed.event_data.value('(data[@name="database_name"]/value)[1]', 'sysname') AS [database_name]
            , xed.event_data.value('(action[@name="session_id"]/value)[1]', 'int') AS session_id
            , xed.event_data.value('(action[@name="username"]/value)[1]', 'sysname') AS username
            , xed.event_data.value('(action[@name="session_server_principal_name"]/value)[1]', 'sysname') AS session_server_principal_name
            , xed.event_data.value('(action[@name="client_hostname"]/value)[1]', 'sysname') AS [client_hostname]
            , xed.event_data.value('(action[@name="client_app_name"]/value)[1]', 'sysname') AS client_app_name
            , xed.event_data.value('(action[@name="sql_text"]/value)[1]', 'varchar(max)') AS sql_text
            , frame_data.value('./@level', 'smallint') AS frame_level
            , SUBSTRING(st.text, (frame_data.value('./@offsetStart', 'int') / 2) + 1,
                ((CASE frame_data.value('./@offsetEnd', 'int')
                    WHEN -1 THEN DATALENGTH(st.text)
                    ELSE frame_data.value('./@offsetEnd', 'int')
                END - frame_data.value('./@offsetStart', 'int')) / 2) + 1) AS sql_statement
            , TRY_CAST(xed.event_data.query('action[@name="tsql_stack"]/value/frames') AS NVARCHAR(MAX)) AS tsql_stack
            , xed.event_data.value('(action[@name="task_time"]/value)[1]', 'bigint') AS task_time
        FROM #Eventos AS A
            CROSS APPLY A.event_data.nodes('//event') AS xed (event_data)
            CROSS APPLY A.event_data.nodes('event/action[@name="tsql_stack"]/value/frames/frame') AS Frame (frame_data)
            OUTER APPLY sys.dm_exec_sql_text(CONVERT(VARBINARY(MAX), frame_data.value('./@handle', 'varchar(max)'), 1)) AS st

        COMMIT TRANSACTION

    END TRY

    BEGIN CATCH
        DECLARE @ErrorMessage NVARCHAR(4000)
              , @ErrorSeverity INT

        SELECT
              @ErrorMessage = N'PROCEDURE: [sp_load_ddl_statement]; - Erro na linha ' + CAST(ERROR_LINE() AS VARCHAR(10))
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
