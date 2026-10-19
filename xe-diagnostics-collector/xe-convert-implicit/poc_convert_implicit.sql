/*
 *
    OBJETIVO: Coleta e carga de eventos de conversão implícita (plan_affecting_convert)
              por Extended Events para histórico de diagnóstico de performance.
    PROJETO: mssql-xe-observability

    AUTHOR: Robson Sestrem

    REFERÊNCIAS DE URL:
 *  https://dirceuresende.com/blog/sql-server-dicas-de-performance-tuning-conversao-implicita-nunca-mais/
 */
-- ============================================================
-- Remoção da sessão de Extended Events existente
-- ============================================================
IF EXISTS
(
    SELECT *
    FROM sys.server_event_sessions
    WHERE name = 'plan_affecting_convert'
)
BEGIN
    DROP EVENT SESSION plan_affecting_convert ON SERVER
END
GO

-- ============================================================
-- Criação da sessão de Extended Events plan_affecting_convert
-- ============================================================
CREATE EVENT SESSION [plan_affecting_convert]
ON SERVER
ADD EVENT sqlserver.plan_affecting_convert
(
    ACTION
    (
        sqlserver.client_app_name
      , sqlserver.client_hostname
      , sqlserver.database_name
      , sqlserver.query_hash
      , sqlserver.query_plan_hash
      , sqlserver.session_id
      , sqlserver.session_server_principal_name
      , sqlserver.sql_text
      , sqlserver.transaction_id
      , sqlserver.tsql_frame
      , sqlserver.username
    )
    WHERE
    (
        [package0].[equal_uint64]([convert_issue], 'Seek Plan') -- 1 = Cardinality Estimate / 2 = Seek Plan
        AND [sqlserver].[like_i_sql_unicode_string]([sqlserver].[client_hostname], N'%WORKLOAD%') -- só pods da Huwaei
        AND [package0].[equal_i_unicode_string]([sqlserver].[database_name], N'HEALTHCARE_DEMO') -- *** SEMPRE ATUALIZAR ***
        AND [package0].[greater_than_uint64]([sqlserver].[session_id], (50))
        AND [package0].[equal_boolean]([sqlserver].[is_system], (0))
        AND [package0].[greater_than_uint64]([sqlserver].[query_hash], (0))
        -- Filtrar de acordo com conhecidas conversões do sistema
        AND [package0].[not_equal_i_unicode_string]([expression], N'CONVERT_IMPLICIT(int,[HEALTHCARE_DEMO].[dbo].[QUESTAO].[TIPO_QUESTAO],0)=(4)')
        AND [package0].[not_equal_i_unicode_string]([expression], N'CONVERT_IMPLICIT(int,[HEALTHCARE_DEMO].[dbo].[QUESTAO].[TIPO_QUESTAO],0)=(2)')
        AND [package0].[not_equal_i_unicode_string]([expression], N'CONVERT_IMPLICIT(int,[HEALTHCARE_DEMO].[dbo].[QUESTAO].[TIPO_QUESTAO],0)=(11)')
        AND [package0].[not_equal_i_unicode_string]([expression], N'CONVERT_IMPLICIT(int,[HEALTHCARE_DEMO].[dbo].[QUESTAO].[TIPO_QUESTAO],0)=(18)')
        AND [package0].[not_equal_i_unicode_string]([expression], N'CONVERT_IMPLICIT(int,[HEALTHCARE_DEMO].[dbo].[QUESTAO].[TIPO_QUESTAO],0)<(11)')
        AND [sqlserver].[not_equal_i_sql_unicode_string]([sqlserver].[client_hostname], N'OPTIMUS-PRIME')
    )
)
ADD TARGET package0.event_file
(
    SET filename = N'/var/opt/mssql/log_jobs/xe/plan_affecting_convert*.xel'
      , max_file_size = (200)
      , max_rollover_files = (3)
      , metadatafile = N'/var/opt/mssql/log_jobs/xe/plan_affecting_convert*.xem'
)
-- STARTUP_STATE=ON -- Será iniciado automaticamente com a instância
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
-- Início da sessão caso ainda não esteja em execução
-- ============================================================
IF NOT EXISTS
( -- XE sessions only show up in sys.dm_xe_sessions if they are running
    SELECT 1
    FROM sys.dm_xe_sessions AS xs
    WHERE xs.name = N'plan_affecting_convert'
)
BEGIN
    ALTER EVENT SESSION plan_affecting_convert ON SERVER STATE = START
END
GO

-- ============================================================
-- Tabela de histórico dos eventos coletados
-- ============================================================
USE DBA_PerformanceHub
GO

IF (OBJECT_ID('dbo.history_plan_affecting_convert') IS NULL)
BEGIN
    CREATE TABLE dbo.history_plan_affecting_convert
    (
        [timestamp_xe] DATETIME
      , [database_name] NVARCHAR(128)
      , [session_server_principal_name] NVARCHAR(128)
      , [username] NVARCHAR(128)
      , [client_hostname] NVARCHAR(128)
      , [client_app_name] NVARCHAR(128)
      , [convert_issue] VARCHAR(100)
      , [expression] VARCHAR(MAX)
      , [session_id] INT
      , [transaction_id] BIGINT
      , [sql_text] VARCHAR(MAX)
      , [sql_statement] NVARCHAR(MAX)
      , [tsql_frame] NVARCHAR(MAX)
      , [query_hash] DECIMAL(38,0)
      , [query_plan_hash] DECIMAL(38,0)
    )

    CREATE CLUSTERED INDEX SK01_history_plan_affecting_convert
    ON dbo.history_plan_affecting_convert([timestamp_xe])
END

-- ============================================================
-- Procedure dbo.sp_load_plan_affecting_convert
-- Carrega os eventos do arquivo XE para a tabela de histórico.
-- ============================================================
USE DBA_PerformanceHub
GO

CREATE OR ALTER PROCEDURE [dbo].[sp_load_plan_affecting_convert]
WITH ENCRYPTION
AS
BEGIN
    SET NOCOUNT ON
    SET XACT_ABORT ON

    BEGIN TRY
        BEGIN TRANSACTION

        DECLARE @TimeZone INT = DATEDIFF(HOUR, GETUTCDATE(), GETDATE())
              , @Dt_Ultimo_Evento DATETIME = ISNULL((SELECT MAX([timestamp_xe]) FROM dbo.history_plan_affecting_convert WITH(NOLOCK)), '1990-01-01')

        IF (OBJECT_ID('tempdb..#Eventos') IS NOT NULL)
        BEGIN
            DROP TABLE #Eventos
        END

        -- Leitura dos arquivos de destino do Extended Events
        SELECT *
        INTO #Eventos
        FROM
        (
            SELECT
                CONVERT(XML, event_data) AS event_data
              , [object_name]
              , CAST(DATEADD(HOUR, @TimeZone, CAST(timestamp_utc AS DATETIME2(3))) AS DATETIME) AS timestamp_utc
            FROM sys.fn_xe_file_target_read_file(N'/var/opt/mssql/log_jobs/xe/plan_affecting_convert*.xel', N'/var/opt/mssql/log_jobs/xe/plan_affecting_convert*.xem', NULL, NULL)
        ) AS dados
        WHERE timestamp_utc > @Dt_Ultimo_Evento

        SET QUOTED_IDENTIFIER ON

        ;WITH dados_xe AS
        (
            SELECT
                A.timestamp_utc
              , xed.event_data.value('(action[@name="database_name"]/value)[1]', 'sysname') AS [database_name]
              , xed.event_data.value('(action[@name="session_server_principal_name"]/value)[1]', 'sysname') AS [session_server_principal_name]
              , xed.event_data.value('(action[@name="username"]/value)[1]', 'sysname') AS [username]
              , xed.event_data.value('(action[@name="client_hostname"]/value)[1]', 'sysname') AS [client_hostname]
              , xed.event_data.value('(action[@name="client_app_name"]/value)[1]', 'sysname') AS [client_app_name]
              , xed.event_data.value('(data[@name="convert_issue"]/text)[1]', 'varchar(100)') AS [convert_issue]
              , xed.event_data.value('(data[@name="expression"]/value)[1]', 'varchar(max)') AS [expression]
              , xed.event_data.value('(action[@name="session_id"]/value)[1]', 'int') AS [session_id]
              , xed.event_data.value('(action[@name="transaction_id"]/value)[1]', 'bigint') AS [transaction_id]
              , xed.event_data.value('(action[@name="sql_text"]/value)[1]', 'varchar(max)') AS [sql_text]
              , SUBSTRING(st.text, (frame_data.value('./@offsetStart', 'int') / 2) + 1,
                    ((CASE frame_data.value('./@offsetEnd', 'int')
                        WHEN -1 THEN DATALENGTH(st.text)
                        ELSE frame_data.value('./@offsetEnd', 'int')
                    END - frame_data.value('./@offsetStart', 'int')) / 2) + 1) AS sql_statement
              , TRY_CAST(xed.event_data.query('action[@name="tsql_frame"]/value') AS NVARCHAR(MAX)) AS [tsql_frame]
              , xed.event_data.value('(action[@name="query_hash"]/value)[1]', 'decimal(38,0)') AS [query_hash]
              , xed.event_data.value('(action[@name="query_plan_hash"]/value)[1]', 'decimal(38,0)') AS [query_plan_hash]
            FROM #Eventos AS A
            CROSS APPLY A.event_data.nodes('//event') AS xed (event_data)
            CROSS APPLY A.event_data.nodes('event/action[@name="tsql_frame"]/value/frame') AS Frame (frame_data)
            OUTER APPLY sys.dm_exec_sql_text(CONVERT(VARBINARY(MAX), frame_data.value('./@handle', 'varchar(max)'), 1)) AS st
        )
        , dados_unicos AS
        (
            SELECT
                ROW_NUMBER() OVER (PARTITION BY xpart.timestamp_utc, xpart.session_id, xpart.query_hash, xpart.query_plan_hash ORDER BY xpart.timestamp_utc DESC) AS rn
              , xpart.timestamp_utc
              , xpart.database_name
              , xpart.session_server_principal_name
              , xpart.username
              , xpart.client_hostname
              , xpart.client_app_name
              , xpart.convert_issue
              , xpart.expression
              , xpart.session_id
              , xpart.transaction_id
              , xpart.sql_text
              , xpart.sql_statement
              , xpart.tsql_frame
              , xpart.query_hash
              , xpart.query_plan_hash
            FROM dados_xe AS xpart
        )
        INSERT INTO history_plan_affecting_convert
        (
            timestamp_xe
          , database_name
          , session_server_principal_name
          , username
          , client_hostname
          , client_app_name
          , convert_issue
          , expression
          , session_id
          , transaction_id
          , sql_text
          , sql_statement
          , tsql_frame
          , query_hash
          , query_plan_hash
        )
        SELECT
            du.timestamp_utc
          , du.database_name
          , du.session_server_principal_name
          , du.username
          , du.client_hostname
          , du.client_app_name
          , du.convert_issue
          , du.expression
          , du.session_id
          , du.transaction_id
          , du.sql_text
          , du.sql_statement
          , du.tsql_frame
          , du.query_hash
          , du.query_plan_hash
        FROM dados_unicos AS du
        WHERE du.rn = 1

        COMMIT TRANSACTION
    END TRY
    BEGIN CATCH
        DECLARE @ErrorMessage NVARCHAR(4000)
              , @ErrorSeverity INT;

        SELECT
            @ErrorMessage = N'PROCEDURE: [sp_load_plan_affecting_convert]; - Erro na linha ' + CAST(ERROR_LINE() AS VARCHAR(10))
                + ' - ' + ERROR_PROCEDURE()
                + ' - ' + CAST(ERROR_STATE() AS VARCHAR(10))
                + ' - ' + ERROR_MESSAGE()
                + ' - ' + CAST(ERROR_NUMBER() AS VARCHAR(10))
          , @ErrorSeverity = ERROR_SEVERITY();

        RAISERROR(@ErrorMessage, @ErrorSeverity, 1);

        IF (XACT_STATE()) = -1
        BEGIN
            PRINT N'A transação está em um estado incompatível. Retrocedendo transação.'
            ROLLBACK TRANSACTION;
        END

        IF (XACT_STATE()) = 1
        BEGIN
            PRINT N'A transação é compatível. Transação completada.'
            COMMIT TRANSACTION;
        END
    END CATCH

    SET NOCOUNT OFF
    SET XACT_ABORT OFF
END
GO
