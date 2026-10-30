/*
 *
    OBJETIVO: Configuração de monitoramento de bloqueios (blocked process report) via Extended Events,
              com tabela de histórico e procedure de carga dos eventos coletados.
    PROJETO: mssql-xe-observability

    AUTHOR: Robson Sestrem

    REFERÊNCIAS DE URL:
 *  https://learn.microsoft.com/pt-br/sql/relational-databases/event-notifications/blocked-process-report-event
 *  https://learn.microsoft.com/pt-br/sql/database-engine/configure-windows/blocked-process-threshold-server-configuration-option
 */
-- ===============================================================================
-- Habilitação de opções avançadas e do blocked process threshold
-- ===============================================================================
EXEC sp_configure 'show advanced options', 1;
GO
RECONFIGURE;
GO

/* Enabled the blocked process report */
EXEC sp_configure 'blocked process threshold', '5';
RECONFIGURE
GO

/*
O EVENT_RETENTION_MODE é um parâmetro que você pode configurar ao criar ou modificar uma sessão de eventos estendidos no SQL Server.
Ele controla a retenção de eventos, determinando como o SQL Server lida com os eventos quando o tamanho máximo dos arquivos de eventos é atingido.
Existem dois valores possíveis para o EVENT_RETENTION_MODE:
*** ALLOW_SINGLE_EVENT_LOSS:
    Quando essa opção está configurada, o SQL Server começará a sobrescrever os arquivos de eventos mais antigos assim que o tamanho máximo for atingido.
    Isso significa que, se o número de eventos gerados for alto o suficiente para preencher os arquivos rapidamente, você pode perder eventos mais antigos.
*** ALLOW_MULTIPLE_EVENT_LOSS:
    Se esta opção estiver configurada, o SQL Server irá suspender a coleta de eventos quando o tamanho máximo dos arquivos for atingido.
    Isso pode resultar na perda de eventos mais recentes se a coleta não puder ser retomada rapidamente.
*/

-- ===============================================================================
-- Remoção da sessão de Extended Events existente
-- ===============================================================================
IF EXISTS
(
    SELECT *
    FROM sys.server_event_sessions
    WHERE name = 'blocked_process'
)
BEGIN
    DROP EVENT SESSION blocked_process ON SERVER
END
GO

-- ===============================================================================
-- Criação da sessão de Extended Events blocked_process
-- ===============================================================================
CREATE EVENT SESSION [blocked_process]
ON SERVER
ADD EVENT sqlserver.blocked_process_report
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
    WHERE
    (
        [sqlserver].[not_equal_i_sql_unicode_string]([sqlserver].[client_hostname], N'OSIRIS-DATABASE')
    )
)
ADD TARGET package0.event_file
(
    SET filename = N'/var/opt/mssql/log_jobs/xe/blocked_process*.xel'
      , max_file_size = (200)
      , max_rollover_files = (3)
      , metadatafile = N'/var/opt/mssql/log_jobs/xe/blocked_process*.xem'
)
-- STARTUP_STATE=ON -- Será iniciado automaticamente com a instância
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

-- ===============================================================================
-- Ativando a sessão (por padrão, ela é criada desativada)
-- ===============================================================================
ALTER EVENT SESSION [blocked_process]
ON SERVER STATE = START
GO

-- ===============================================================================
-- Tabela de histórico dos eventos de bloqueio
-- ===============================================================================
USE DBA_PerformanceHub
GO

CREATE TABLE history_blocked_process
(
    EndTime DATETIME2(3) NOT NULL
  , xeProcessID VARCHAR(100) NOT NULL
  , module_guid UNIQUEIDENTIFIER
  , package_guid UNIQUEIDENTIFIER
  , [object_name] NVARCHAR(50)
  , [file_name] NVARCHAR(200)
  , [file_offset] BIGINT
  , TextData XML
  , PRIMARY KEY CLUSTERED (EndTime, xeProcessID) WITH(FILLFACTOR = 90)
) WITH(DATA_COMPRESSION = PAGE)
GO

--DROP TABLE history_blocked_process

-- ===============================================================================
-- Procedure dbo.sp_gather_blocked_process_events
-- Carrega eventos de bloqueio do arquivo XE para a tabela de histórico.
-- ===============================================================================
CREATE OR ALTER PROCEDURE dbo.sp_gather_blocked_process_events
WITH ENCRYPTION
AS
BEGIN
    SET NOCOUNT ON
    SET XACT_ABORT ON

    BEGIN TRY
        BEGIN TRANSACTION

        DECLARE @TimeZone INT = DATEDIFF(HOUR, GETUTCDATE(), GETDATE())
              , @Ultimo_Log DATETIME2(3) = ISNULL((SELECT MAX(EndTime) FROM history_blocked_process WITH(NOLOCK)), '1900-01-01')

        ;WITH events_cte AS
        (
            SELECT
                CAST(DATEADD(HOUR, @TimeZone, CAST(timestamp_utc AS DATETIME2(3))) AS DATETIME2(3)) AS xeTimeStamp
              , xevents.event_data.value('(//blocked-process-report/blocked-process/process/@id)[1]', 'nvarchar(100)') AS xeProcessID
              , module_guid
              , package_guid
              , [object_name]
              , [file_name]
              , [file_offset]
              , xevents.event_data.query('(event[@name="blocked_process_report"]/data[@name="blocked_process"]/value/blocked-process-report)[1]') AS blocked_process_report
            FROM sys.fn_xe_file_target_read_file(N'/var/opt/mssql/log_jobs/xe/blocked_process*.xel', N'/var/opt/mssql/log_jobs/xe/blocked_process*.xem', NULL, NULL)
            CROSS APPLY
            (
                SELECT CAST(event_data AS XML) AS event_data
            ) AS xevents
        )
        INSERT INTO history_blocked_process
        (
            EndTime
          , xeProcessID
          , module_guid
          , package_guid
          , [object_name]
          , [file_name]
          , [file_offset]
          , TextData
        )
        SELECT
            xeTimeStamp
          , xeProcessID
          , module_guid
          , package_guid
          , [object_name]
          , [file_name]
          , [file_offset]
          , blocked_process_report
        FROM events_cte AS xr
        WHERE blocked_process_report.value('(blocked-process-report[@monitorLoop])[1]', 'nvarchar(max)') IS NOT NULL
        AND NOT EXISTS
        (
            SELECT 1
            FROM history_blocked_process AS hbp
            WHERE hbp.EndTime = xr.xeTimeStamp
            AND hbp.xeProcessID = xr.xeProcessID
        )
        AND xr.xeTimeStamp > @Ultimo_Log
        ORDER BY xr.xeTimeStamp DESC;

        COMMIT TRANSACTION
    END TRY
    BEGIN CATCH
        DECLARE @ErrorMessage NVARCHAR(4000)
              , @ErrorSeverity INT;

        SELECT
            @ErrorMessage = N'PROCEDURE: sp_gather_blocked_process_events; - Erro na linha ' + CAST(ERROR_LINE() AS VARCHAR(10))
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
