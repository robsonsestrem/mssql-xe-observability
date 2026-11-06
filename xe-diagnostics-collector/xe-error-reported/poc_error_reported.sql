/*
 *
    OBJETIVO: Monitoramento de erros e exceções do SQL Server via Extended Events (error_reported),
              com tabela de histórico e procedure de carga dos eventos coletados.

    PROJETO: mssql-xe-observability

    AUTHOR: Robson Sestrem

    REFERÊNCIAS DE URL:
 *  https://dirceuresende.com/blog/sql-server-como-criar-um-monitoramento-de-erros-e-excecoes-no-seu-banco-de-dados-utilizando-extended-events-xe/
 */
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

-- ============================================================
-- Remoção da sessão de Extended Events existente
-- ============================================================
IF ((SELECT COUNT(*) FROM sys.server_event_sessions WHERE [name] = 'system_error_collection') > 0)
BEGIN
    DROP EVENT SESSION [system_error_collection] ON SERVER
END
GO

-- ============================================================
-- Criação da sessão de Extended Events system_error_collection
-- Evento: error_reported
-- ============================================================
CREATE EVENT SESSION [system_error_collection]
ON SERVER
ADD EVENT sqlserver.error_reported
(
    ACTION
    (
        sqlserver.client_app_name
      , sqlserver.client_hostname
      , sqlserver.database_name
      , sqlserver.session_id
      , sqlserver.sql_text
      , sqlserver.username
    )
    WHERE
    (
        [package0].[greater_than_equal_int64]([severity], (17))
        AND [sqlserver].[not_equal_i_sql_unicode_string]([sqlserver].[client_hostname], N'OSIRIS-DATABASE')
    )
)
ADD TARGET package0.event_file
(
    SET filename = N'/var/opt/mssql/log_jobs/xe/system_error_collection*.xel'
      , max_file_size = (200)
      , max_rollover_files = (3)
      , metadatafile = N'/var/opt/mssql/log_jobs/xe/system_error_collection*.xem'
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
-- Ativando a sessão (por padrão, ela é criada desativada)
-- ============================================================
ALTER EVENT SESSION [system_error_collection]
ON SERVER STATE = START
GO

-- ============================================================
-- Tabela de histórico de erros coletados
-- ============================================================
USE DBA_PerformanceHub
GO

CREATE TABLE dbo.history_database_error
(
    Dt_Evento DATETIME
  , session_id INT
  , [database_name] VARCHAR(100)
  , [username] VARCHAR(128)
  , client_hostname VARCHAR(100)
  , client_app_name VARCHAR(100)
  , [error_number] INT
  , severity INT
  , [state] INT
  , sql_text VARCHAR(MAX)
  , [message] VARCHAR(MAX)
) WITH(DATA_COMPRESSION = PAGE)
GO

CREATE CLUSTERED INDEX SK01_history_database_error
ON dbo.history_database_error(Dt_Evento)
WITH(DATA_COMPRESSION = PAGE, FILLFACTOR = 95)
GO

-- ============================================================
-- Procedure dbo.sp_load_database_error
-- Carrega eventos de erro do arquivo XE 
-- para a tabela de histórico.
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.sp_load_database_error
WITH ENCRYPTION
AS
BEGIN
    SET NOCOUNT ON
    SET XACT_ABORT ON

    BEGIN TRY
        BEGIN TRANSACTION

        DECLARE @TimeZone INT = DATEDIFF(HOUR, GETUTCDATE(), GETDATE())
              , @Dt_Ultimo_Evento DATETIME = ISNULL((SELECT MAX(Dt_Evento) FROM dbo.history_database_error WITH(NOLOCK)), '1990-01-01')

        IF OBJECT_ID('tempdb..#Eventos') IS NOT NULL
        BEGIN
            DROP TABLE #Eventos
        END

        -- Leitura dos arquivos de destino do Extended Events
        SELECT *
        INTO #Eventos
        FROM
        (
            SELECT
                CAST(DATEADD(HOUR, @TimeZone, CAST(timestamp_utc AS DATETIME2(3))) AS DATETIME) AS timestamp_utc
              , CAST(event_data AS XML) AS [event_data]
            FROM sys.fn_xe_file_target_read_file(N'/var/opt/mssql/log_jobs/xe/system_error_collection*.xel', N'/var/opt/mssql/log_jobs/xe/system_error_collection*.xem', NULL, NULL)
        ) AS [dados]
        WHERE timestamp_utc > @Dt_Ultimo_Evento

        SET QUOTED_IDENTIFIER ON

        -- Carga dos eventos para a tabela de histórico
        INSERT INTO dbo.history_database_error
        (
            Dt_Evento
          , session_id
          , [database_name]
          , username
          , client_hostname
          , client_app_name
          , [error_number]
          , severity
          , [state]
          , sql_text
          , [message]
        )
        SELECT
            A.timestamp_utc
          , xed.event_data.value('(action[@name="session_id"]/value)[1]', 'INT') AS [session_id]
          , xed.event_data.value('(action[@name="database_name"]/value)[1]', 'VARCHAR(100)') AS [database_name]
          , xed.event_data.value('(action[@name="username"]/value)[1]', 'VARCHAR(100)') AS [username]
          , xed.event_data.value('(action[@name="client_hostname"]/value)[1]', 'VARCHAR(100)') AS [client_hostname]
          , xed.event_data.value('(action[@name="client_app_name"]/value)[1]', 'VARCHAR(100)') AS [client_app_name]
          , xed.event_data.value('(data[@name="error_number"]/value)[1]', 'INT') AS [error_number]
          , xed.event_data.value('(data[@name="severity"]/value)[1]', 'INT') AS [severity]
          , xed.event_data.value('(data[@name="state"]/value)[1]', 'INT') AS [state]
          , xed.event_data.value('(action[@name="sql_text"]/value)[1]', 'VARCHAR(MAX)') AS [sql_text]
          , xed.event_data.value('(data[@name="message"]/value)[1]', 'VARCHAR(MAX)') AS [message]
        FROM #Eventos AS A
        CROSS APPLY A.event_data.nodes('//event') AS xed (event_data)

        COMMIT TRANSACTION
    END TRY
    BEGIN CATCH
        DECLARE @ErrorMessage NVARCHAR(4000)
              , @ErrorSeverity INT;

        SELECT
            @ErrorMessage = N'PROCEDURE: sp_load_database_error; - Erro na linha ' + CAST(ERROR_LINE() AS VARCHAR(10))
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
