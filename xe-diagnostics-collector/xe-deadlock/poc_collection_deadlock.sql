/*
 *
    OBJETIVO: PoC de monitoramento de deadlocks via Extended Events, incluindo
              configuração do blocked process threshold, criação da sessão
              de eventos, tabelas de armazenamento detalhado e de grafo XML,
              e procedures de carga dos dados históricos.

    PROJETO: mssql-xe-observability

    AUTHOR: Robson Sestrem
    
 *  Documentação oficial: CREATE EVENT SESSION, sys.fn_xe_file_target_read_file
 */
-- ============================================================
-- Configuração do blocked process threshold
-- ============================================================
EXEC sp_configure 'show advanced options', 1
GO

RECONFIGURE
GO

EXEC sp_configure 'blocked process threshold', '5'
RECONFIGURE
GO

-- ============================================================
-- Criação da sessão de eventos estendidos de deadlocks
-- ============================================================
/*
    O EVENT_RETENTION_MODE é um parâmetro configurável ao criar ou modificar
    uma sessão de eventos estendidos no SQL Server. Ele controla a retenção
    de eventos quando o tamanho máximo dos arquivos é atingido.

    Existem dois valores possíveis para o EVENT_RETENTION_MODE:

    *** ALLOW_SINGLE_EVENT_LOSS:
        O SQL Server sobrescreve os arquivos de eventos mais antigos assim
        que o tamanho máximo é atingido. Se a geração de eventos for alta
        o suficiente para preencher os arquivos rapidamente, eventos mais
        antigos serão perdidos.

    *** ALLOW_MULTIPLE_EVENT_LOSS:
        O SQL Server suspende a coleta de eventos quando o tamanho máximo
        dos arquivos for atingido, o que pode resultar na perda de eventos
        mais recentes se a coleta não puder ser retomada rapidamente.
*/
IF EXISTS (SELECT * FROM sys.server_event_sessions WHERE name = 'deadlocks')
    DROP EVENT SESSION deadlocks ON SERVER
GO

CREATE EVENT SESSION deadlocks ON SERVER
ADD EVENT sqlserver.xml_deadlock_report
(
    ACTION
    (
          sqlserver.client_app_name
        , sqlserver.client_hostname
        , sqlserver.database_name
        , sqlserver.plan_handle
        , sqlserver.session_id
        , sqlserver.session_server_principal_name
        , sqlserver.sql_text
    )
    WHERE ([sqlserver].[not_equal_i_sql_unicode_string]([sqlserver].[client_hostname], N'OSIRIS-DATABASE'))
)
ADD TARGET package0.event_file
(
    SET filename = N'/var/opt/mssql/log_jobs/xe/deadlocks_report*.xel'
      , max_file_size = (200)
      , max_rollover_files = (3)
      , metadatafile = N'/var/opt/mssql/log_jobs/xe/deadlocks_report*.xem'
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
    WHERE xs.name = N'deadlocks'
)
BEGIN
    ALTER EVENT SESSION deadlocks ON SERVER STATE = START
END
GO

-- ============================================================
-- ARMAZENAMENTO DETALHADO
-- Criação da tabela de armazenamento detalhado
-- ============================================================
USE DBA_PerformanceHub
GO

IF (OBJECT_ID('dbo.history_deadlocks_details') IS NULL)
BEGIN
    CREATE TABLE dbo.history_deadlocks_details
    (
          [dt_event]                    DATETIME2(3) NOT NULL
        , [processId]                   VARCHAR(100) NOT NULL
        , [xeSessionID]                 INT NOT NULL
        , [isVictim]                    INT
        , [processSqlCommand]           VARCHAR(MAX)
        , [processWaitResource]         VARCHAR(100)
        , [processWaitTime]             INT
        , [processTransactionName]      VARCHAR(60)
        , [processStatus]               VARCHAR(60)
        , [processSPID]                 INT
        , [processClientApp]            VARCHAR(256)
        , [processHostname]             VARCHAR(256)
        , [processLoginName]            VARCHAR(256)
        , [processIsolationLevel]       VARCHAR(256)
        , [processCurrentDb]            VARCHAR(256)
        , [processCurrentDbName]        NVARCHAR(128)
        , [processTranCount]            INT
        , [processLockMode]             VARCHAR(10)
        , [transaction_time]            DATETIME
        , [batch_started]               DATETIME
        , [batch_completed]             DATETIME
        , PRIMARY KEY CLUSTERED ([dt_event], [processId], [xeSessionID]) WITH (FILLFACTOR = 85)
    )
    WITH (DATA_COMPRESSION = PAGE)
END
-- DROP TABLE history_deadlocks_details
GO

-- ============================================================
-- Procedure de carga da tabela de detalhes de deadlocks
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.sp_load_deadlocks
WITH ENCRYPTION
AS
BEGIN
    SET NOCOUNT ON
    SET XACT_ABORT ON

    BEGIN TRY
        BEGIN TRANSACTION

        DECLARE @Ultimo_Log DATETIME2(3) = ISNULL((SELECT MAX([dt_event]) FROM dbo.history_deadlocks_details WITH(NOLOCK)), '1900-01-01')
              , @TimeZone INT = DATEDIFF(HOUR, GETUTCDATE(), GETDATE())

        IF OBJECT_ID('tempdb..#xml_deadlock') IS NOT NULL
            DROP TABLE #xml_deadlock

        -- ============================================================
        -- Leitura dos arquivos XE e filtragem por timestamp
        -- ============================================================
        SELECT *
        INTO #xml_deadlock
        FROM
        (
            SELECT
                  CAST(DATEADD(HOUR, @TimeZone, CAST(timestamp_utc AS DATETIME2(3))) AS DATETIME2(3)) AS dt_event
                , TRY_CAST(event_data AS XML) AS TargetData
            FROM sys.fn_xe_file_target_read_file(N'/var/opt/mssql/log_jobs/xe/deadlocks_report*.xel', N'/var/opt/mssql/log_jobs/xe/deadlocks_report*.xem', NULL, NULL)
        ) AS [dados]
        WHERE dt_event > @Ultimo_Log

        -- ============================================================
        -- Extração dos dados do grafo de deadlock
        -- ============================================================
        ;WITH dados_xe AS
        (
            SELECT DISTINCT
                  A.dt_event
                , processo.dados.value('@id', 'varchar(100)') AS [processId]
                , A.TargetData.value('(/event/action/value)[1]', 'int') AS xeSessionID
                , CASE
                      WHEN vitima.dados.value('@id', 'varchar(100)') = processo.dados.value('@id', 'varchar(100)')
                          THEN 1
                      ELSE 0
                  END AS isVictim
                , TRY_CAST(processo.dados.query('(inputbuf/text())') AS NVARCHAR(MAX)) AS [processSqlCommand]
                , processo.dados.value('@waitresource', 'varchar(100)') AS [processWaitResource]
                , processo.dados.value('@waittime', 'int') AS [processWaitTime]
                , processo.dados.value('@transactionname', 'varchar(60)') AS [processTransactionName]
                , processo.dados.value('@status', 'varchar(60)') AS [processStatus]
                , processo.dados.value('@spid', 'int') AS [processSPID]
                , processo.dados.value('@clientapp', 'varchar(256)') AS [processClientApp]
                , processo.dados.value('@hostname', 'varchar(256)') AS [processHostname]
                , processo.dados.value('@loginname', 'varchar(256)') AS [processLoginName]
                , processo.dados.value('@isolationlevel', 'varchar(256)') AS [processIsolationLevel]
                , processo.dados.value('@currentdb', 'varchar(256)') AS [processCurrentDb]
                , DB_NAME(processo.dados.value('@currentdb', 'varchar(256)')) AS [processCurrentDbName]
                , processo.dados.value('@trancount', 'int') AS [processTranCount]
                , processo.dados.value('@lockMode', 'varchar(10)') AS [processLockMode]
                , processo.dados.value('@lasttranstarted', 'datetime') AS [TransactionTime]
                , processo.dados.value('@lastbatchstarted', 'datetime') AS [BatchStarted]
                , processo.dados.value('@lastbatchcompleted', 'datetime') AS [BatchCompleted]
            FROM #xml_deadlock AS A
                CROSS APPLY A.TargetData.nodes('//event') AS dados (event_data)
                CROSS APPLY dados.event_data.nodes('data/value/deadlock/victim-list/victimProcess') AS vitima (dados)
                OUTER APPLY dados.event_data.nodes('data/value/deadlock/process-list/process') AS processo (dados)
            WHERE NOT EXISTS
            (
                SELECT 1
                FROM history_deadlocks_details hdd
                WHERE hdd.dt_event = A.dt_event
                    AND hdd.processId = processo.dados.value('@id', 'varchar(100)')
            )
        )
        , dados_unicos AS
        (
            SELECT
                  ROW_NUMBER() OVER (PARTITION BY dt_event, processId ORDER BY dt_event DESC) AS rn
                , *
            FROM dados_xe
        )

        -- ============================================================
        -- Inserção dos dados únicos na tabela de histórico
        -- ============================================================
        INSERT INTO history_deadlocks_details
        (
              dt_event
            , processId
            , xeSessionID
            , isVictim
            , processSqlCommand
            , processWaitResource
            , processWaitTime
            , processTransactionName
            , processStatus
            , processSPID
            , processClientApp
            , processHostname
            , processLoginName
            , processIsolationLevel
            , processCurrentDb
            , processCurrentDbName
            , processTranCount
            , processLockMode
            , transaction_time
            , batch_started
            , batch_completed
        )
        SELECT
              dt_event
            , processId
            , xeSessionID
            , isVictim
            , processSqlCommand
            , processWaitResource
            , processWaitTime
            , processTransactionName
            , processStatus
            , processSPID
            , processClientApp
            , processHostname
            , processLoginName
            , processIsolationLevel
            , processCurrentDb
            , processCurrentDbName
            , processTranCount
            , processLockMode
            , TransactionTime
            , BatchStarted
            , BatchCompleted
        FROM dados_unicos
        WHERE rn = 1
        ORDER BY dt_event DESC

        COMMIT TRANSACTION

    END TRY

    BEGIN CATCH
        DECLARE @ErrorMessage NVARCHAR(4000)
              , @ErrorSeverity INT

        SELECT
              @ErrorMessage = N'PROCEDURE: sp_load_deadlocks; - Erro na linha ' + CAST(ERROR_LINE() AS VARCHAR(10))
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

-- ============================================================
-- ARMAZENAMENTO GRÁFICO DEADLOCK
-- Criação da tabela de armazenamento do grafo XML
-- ============================================================
CREATE TABLE dbo.history_deadlock_xml_events
(
      xeTimeStamp     DATETIME2(3) NOT NULL
    , xeProcessID     VARCHAR(20) NOT NULL
    , xeSessionID     INT NOT NULL
    , module_guid     UNIQUEIDENTIFIER
    , package_guid    UNIQUEIDENTIFIER
    , [object_name]   NVARCHAR(50)
    , [file_name]     NVARCHAR(200)
    , [file_offset]   BIGINT
    , xeXML           XML NOT NULL
    , CONSTRAINT deadlock_xml_events_pk PRIMARY KEY CLUSTERED (xeTimeStamp, xeProcessID, xeSessionID) WITH (FILLFACTOR = 85)
)
WITH (DATA_COMPRESSION = PAGE)
-- DROP TABLE history_deadlock_xml_events
GO

-- ============================================================
-- Procedure de carga do grafo XML de deadlocks
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.sp_gather_deadlock_events
WITH ENCRYPTION
AS
BEGIN
    SET NOCOUNT ON
    SET XACT_ABORT ON

    BEGIN TRY
        BEGIN TRANSACTION

        IF OBJECT_ID('tempdb..#xmlResults') IS NOT NULL
            DROP TABLE #xmlResults

        CREATE TABLE #xmlResults
        (
              xeTimeStamp     DATETIME2(3) NOT NULL
            , xeProcessID     VARCHAR(100) NOT NULL
            , xeSessionID     INT NOT NULL
            , module_guid     UNIQUEIDENTIFIER
            , package_guid    UNIQUEIDENTIFIER
            , [object_name]   NVARCHAR(50)
            , [file_name]     NVARCHAR(200)
            , [file_offset]   BIGINT
            , xeXML           XML NOT NULL
            , PRIMARY KEY CLUSTERED (xeTimeStamp, xeProcessID, xeSessionID)
        )

        DECLARE @TimeZone INT = DATEDIFF(HOUR, GETUTCDATE(), GETDATE())
        DECLARE @Ultimo_Log DATETIME2(3) = ISNULL((SELECT MAX(xeTimeStamp) FROM dbo.history_deadlock_xml_events WITH(NOLOCK)), '1900-01-01')

        -- ============================================================
        -- Leitura dos arquivos XE e extração do grafo XML
        -- ============================================================
        ;WITH src AS
        (
            SELECT
                  module_guid
                , package_guid
                , [object_name]
                , [file_name]
                , [file_offset]
                , CAST(DATEADD(HOUR, @TimeZone, CAST(timestamp_utc AS DATETIME2(3))) AS DATETIME2(3)) AS timestamp_utc
                , CAST(event_data AS XML) AS xeXML
            FROM sys.fn_xe_file_target_read_file(N'/var/opt/mssql/log_jobs/xe/deadlocks_report*.xel', N'/var/opt/mssql/log_jobs/xe/deadlocks_report*.xem', NULL, NULL)
        )
        INSERT INTO #xmlResults
        (
              xeTimeStamp
            , xeProcessID
            , xeSessionID
            , module_guid
            , package_guid
            , [object_name]
            , [file_name]
            , [file_offset]
            , xeXML
        )
        SELECT
              timestamp_utc
            , xeProcessID = src.xeXML.value('(/event/data/value/deadlock/victim-list/victimProcess/@id)[1]', 'varchar(20)')
            , xeSessionID = src.xeXML.value('(/event/action/value)[1]', 'int')
            , module_guid
            , package_guid
            , [object_name]
            , [file_name]
            , [file_offset]
            , src.xeXML
        FROM src

        -- ============================================================
        -- Inserção na tabela de histórico (evitando duplicatas)
        -- ============================================================
        INSERT INTO dbo.history_deadlock_xml_events
        (
              xeTimeStamp
            , xeProcessID
            , xeSessionID
            , module_guid
            , package_guid
            , [object_name]
            , [file_name]
            , [file_offset]
            , xeXML
        )
        SELECT
              xr.xeTimeStamp
            , xr.xeProcessID
            , xr.xeSessionID
            , module_guid
            , package_guid
            , [object_name]
            , [file_name]
            , [file_offset]
            , xr.xeXML
        FROM #xmlResults xr
        WHERE NOT EXISTS
        (
            SELECT 1
            FROM dbo.history_deadlock_xml_events dxe
            WHERE dxe.xeTimeStamp = xr.xeTimeStamp
                AND dxe.xeProcessID = xr.xeProcessID
        )
        AND xr.xeTimeStamp > @Ultimo_Log

        COMMIT TRANSACTION

    END TRY

    BEGIN CATCH
        DECLARE @ErrorMessage NVARCHAR(4000)
              , @ErrorSeverity INT

        SELECT
              @ErrorMessage = N'PROCEDURE: sp_gather_deadlock_events; - Erro na linha ' + CAST(ERROR_LINE() AS VARCHAR(10))
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
