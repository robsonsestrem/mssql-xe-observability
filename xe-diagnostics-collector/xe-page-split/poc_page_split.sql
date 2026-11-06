/*
 *
    OBJETIVO: PoC de monitoramento de page splits via Extended Events, rastreando
              eventos de transaction_log com operação de divisão de página,
              armazenando em tabela histórica com identificação do índice,
              tabela, schema e fator de preenchimento atual.
    
    PROJETO: mssql-xe-observability

    AUTHOR: Robson Sestrem

    REFERÊNCIAS DE URL:
 *  Documentação oficial: CREATE EVENT SESSION, sys.fn_xe_file_target_read_file, sys.allocation_units
 */
-- ============================================================
-- Configuração do Fill Factor padrão
-- ============================================================
EXEC sys.sp_configure N'fill factor (%)', N'100'
GO

RECONFIGURE WITH OVERRIDE
GO

-- ============================================================================
-- Acompanhamento de divisões de páginas
-- ----------------------------------------------------------------------------
-- Usamos uma sessão de eventos estendida para rastrear divisões de páginas
-- em um buffer circular e ler esses dados em uma tabela uma vez por semana
-- para uso temporário. Em seguida, pegamos esses dados e traduzimos em qual
-- índice veio a divisão da página e armazenamos essas informações para
-- processamento posterior.
-- Primeiro, configuramos uma sessão de eventos estendida para rastrear
-- divisões de páginas.
-- ============================================================================
IF EXISTS (SELECT * FROM sys.server_event_sessions WHERE name LIKE '%monitor_page_splits_YOUR_DATABASE%')
    DROP EVENT SESSION monitor_page_splits_YOUR_DATABASE ON SERVER
GO

CREATE EVENT SESSION monitor_page_splits_YOUR_DATABASE ON SERVER
ADD EVENT sqlserver.transaction_log
(
    SET collect_database_name = (0)
    WHERE
    (
        [operation] = (11)
        AND [package0].[equal_i_unicode_string]([sqlserver].[database_name], N'YOUR_DATABASE')
        AND [sqlserver].[not_equal_i_sql_unicode_string]([sqlserver].[client_hostname], N'OSIRIS-DATABASE')
    )
)
ADD TARGET package0.event_file
(
    SET filename = N'/var/opt/mssql/log_jobs/xe/monitor_page_splits_YOUR_DATABASE*.xel'
      , max_file_size = (200)
      , max_rollover_files = (3)
      , metadatafile = N'/var/opt/mssql/log_jobs/xe/monitor_page_splits_YOUR_DATABASE*.xem'
)
WITH
(
      MAX_MEMORY = 4096 KB
    , EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS
    , MAX_DISPATCH_LATENCY = 5 SECONDS
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
    WHERE xs.name = N'monitor_page_splits_YOUR_DATABASE'
)
BEGIN
    ALTER EVENT SESSION monitor_page_splits_YOUR_DATABASE ON SERVER STATE = START
END
GO

-- ============================================================
-- Criação da tabela de armazenamento
-- ============================================================
USE DBA_PerformanceHub
GO

CREATE TABLE dbo.[index_defrag_page_splits_YOUR_DATABASE]
(
      [row_id]                        INT IDENTITY(1, 1) NOT NULL PRIMARY KEY
    , [timestamp_xe]                  DATETIME2(3) NOT NULL DEFAULT GETDATE()
    , [session_id]                    INT
    , [username]                      VARCHAR(128)
    , [session_server_principal_name] VARCHAR(128)
    , [client_hostname]               VARCHAR(128)
    , [client_app_name]               VARCHAR(128)
    , [sql_text]                      VARCHAR(MAX)
    , [alloc_unit_id]                 BIGINT NOT NULL
    , [database_id]                   TINYINT NOT NULL
    , [database_name]                 SYSNAME
    , [schema_name]                   SYSNAME NOT NULL
    , [table_name]                    SYSNAME NOT NULL
    , [index_name]                    SYSNAME NOT NULL
    , [index_id]                      INT NOT NULL
    , [fill_factor]                   TINYINT NOT NULL
    , [counted_splits]                BIGINT NOT NULL
)
WITH (DATA_COMPRESSION = PAGE)
GO

-- ============================================================================
-- Procedure de carga dos dados de page splits
-- ----------------------------------------------------------------------------
-- Configura um job que seja executado a cada hora para ler os dados da sessão
-- de eventos estendidos. O procedimento lê a unidade de alocação e o ID do
-- banco de dados para cada divisão de página na última hora e usa SQL Dinâmico
-- para descobrir qual índice e fator de preenchimento atual o índice possui,
-- armazenando essas informações na tabela [index_defrag_page_splits_YOUR_DATABASE].
-- ============================================================================
USE DBA_PerformanceHub
GO

CREATE OR ALTER PROCEDURE [dbo].[sp_load_index_defrag_insert_page_splits_YOUR_DATABASE]
WITH ENCRYPTION
AS
BEGIN
    SET NOCOUNT ON
    SET XACT_ABORT ON

    BEGIN TRY
        BEGIN TRANSACTION

        DECLARE @Ultimo_Log DATETIME2(3) = ISNULL((SELECT MAX([timestamp_xe]) FROM dbo.[index_defrag_page_splits_YOUR_DATABASE] WITH(NOLOCK)), '1900-01-01')
              , @TimeZone INT = DATEDIFF(HOUR, GETUTCDATE(), GETDATE())

        IF OBJECT_ID('tempdb..#events') IS NOT NULL
            DROP TABLE #events

        -- ============================================================
        -- Leitura dos arquivos XE e filtragem por timestamp
        -- ============================================================
        SELECT *
        INTO #events
        FROM
        (
            SELECT
                  CAST(DATEADD(HOUR, @TimeZone, CAST(timestamp_utc AS DATETIME2(3))) AS DATETIME2(3)) AS timestamp_utc
                , CAST(event_data AS XML) AS target_data
            FROM sys.fn_xe_file_target_read_file(N'/var/opt/mssql/log_jobs/xe/monitor_page_splits_YOUR_DATABASE*.xel', N'/var/opt/mssql/log_jobs/xe/monitor_page_splits_YOUR_DATABASE*.xem', NULL, NULL)
        ) AS [dados]
        WHERE timestamp_utc > @Ultimo_Log

        -- ============================================================
        -- Extração dos eventos e inserção na tabela histórica
        -- ============================================================
        ;WITH related_events AS
        (
            SELECT
                  ev.timestamp_utc
                , ev.target_data.value('(event/action[@name="session_id"]/value)[1]', 'int') AS session_id
                , ev.target_data.value('(event/action[@name="username"]/value)[1]', 'varchar(128)') AS username
                , ev.target_data.value('(event/action[@name="session_server_principal_name"]/value)[1]', 'varchar(128)') AS session_server_principal_name
                , ev.target_data.value('(event/action[@name="client_hostname"]/value)[1]', 'varchar(128)') AS [client_hostname]
                , ev.target_data.value('(event/action[@name="client_app_name"]/value)[1]', 'varchar(128)') AS [client_app_name]
                , ev.target_data.value('(event/action[@name="sql_text"]/value)[1]', 'nvarchar(max)') AS sql_text
                , ev.target_data.value('(event/data[@name="alloc_unit_id"]/value)[1]', 'bigint') AS alloc_unit_id
                , ev.target_data.value('(event/data[@name="database_id"]/value)[1]', 'int') AS database_id
            FROM #events AS ev
        )

        INSERT INTO [index_defrag_page_splits_YOUR_DATABASE]
        (
              timestamp_xe
            , session_id
            , username
            , session_server_principal_name
            , client_hostname
            , client_app_name
            , sql_text
            , alloc_unit_id
            , database_id
            , [database_name]
            , [schema_name]
            , table_name
            , index_name
            , index_id
            , fill_factor
            , counted_splits
        )
        SELECT
              re.timestamp_utc
            , re.session_id
            , re.username
            , re.session_server_principal_name
            , re.client_hostname
            , re.client_app_name
            , re.sql_text
            , re.alloc_unit_id
            , re.database_id
            , DB_NAME(re.database_id) AS database_name
            , s.name AS schema_name
            , o.name AS table_name
            , i.name AS index_name
            , i.index_id AS index_id
            , i.fill_factor
            , COUNT(*) OVER
            (
                PARTITION BY
                      s.name
                    , o.name
                    , i.name
                    , i.index_id
                    , i.fill_factor
                ORDER BY
                      s.name
                    , o.name
                    , i.name
                    , i.index_id
                    , i.fill_factor
            ) AS counted_splits
        FROM related_events AS re
            INNER JOIN YOUR_DATABASE.sys.allocation_units AS au
                ON au.allocation_unit_id = re.alloc_unit_id
            INNER JOIN YOUR_DATABASE.sys.partitions p
                ON au.container_id = p.partition_id
            INNER JOIN YOUR_DATABASE.sys.objects AS o
                ON p.object_id = o.object_id
            INNER JOIN YOUR_DATABASE.sys.schemas AS s
                ON s.schema_id = o.schema_id
            INNER JOIN YOUR_DATABASE.sys.indexes AS i
                ON o.object_id = i.object_id
                AND p.index_id = i.index_id

        COMMIT TRANSACTION

    END TRY

    BEGIN CATCH
        DECLARE @ErrorMessage NVARCHAR(4000)
              , @ErrorSeverity INT

        SELECT
              @ErrorMessage = N'PROCEDURE: [sp_load_index_defrag_insert_page_splits_YOUR_DATABASE]; - Erro na linha ' + CAST(ERROR_LINE() AS VARCHAR(10))
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
