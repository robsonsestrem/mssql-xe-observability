/*
 *
    OBJETIVO: PoC de monitoramento de queries caras via Extended Events (XE),
              capturando eventos de statement, batch e RPC com duração acima
              de 10 segundos, persistindo em tabelas históricas via procedures
              de carga.
    PROJETO: mssql-xe-observability

    AUTHOR: Robson Sestrem

    REFERÊNCIAS:
 *  Documentação oficial: CREATE EVENT SESSION, sys.fn_xe_file_target_read_file
 */
-- ============================================================
-- QUERY STATEMENT
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
IF EXISTS (SELECT * FROM sys.server_event_sessions WHERE name = 'expensive_query_statement')
    DROP EVENT SESSION expensive_query_statement ON SERVER
GO

-- ============================================================
-- Criação da sessão de eventos estendidos para statements caros
-- ============================================================
CREATE EVENT SESSION [expensive_query_statement] ON SERVER
ADD EVENT sqlserver.sp_statement_completed
(
    ACTION
    (
          sqlserver.client_app_name
        , sqlserver.client_hostname
        , sqlserver.database_name
        , sqlserver.session_id
        , sqlserver.session_server_principal_name
        , sqlserver.sql_text
        , sqlserver.username
    )
    WHERE
    (
        [package0].[greater_than_equal_int64]([duration], (10000000))
        AND [sqlserver].[not_equal_i_sql_unicode_string]([sqlserver].[client_hostname], N'OPTIMUS-PRIME')
    )
)
ADD TARGET package0.event_file
(
    SET filename = N'/var/opt/mssql/log_jobs/xe/expensive_query_statement*.xel'
      , max_file_size = (200)
      , max_rollover_files = (3)
      , metadatafile = N'/var/opt/mssql/log_jobs/xe/expensive_query_statement*.xem'
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
-- Inicia a sessão caso ainda não esteja rodando
-- ============================================================
IF NOT EXISTS
(
    SELECT 1
    FROM sys.dm_xe_sessions xs
    WHERE xs.name = N'expensive_query_statement'
)
BEGIN
    ALTER EVENT SESSION expensive_query_statement ON SERVER STATE = START
END
GO

-- ============================================================
-- Criação da tabela de histórico de statements caros
-- ============================================================
USE MAINTENANCE_DIX
GO

CREATE TABLE dbo.history_slow_query_statement
(
      [Dt_Evento]                       DATETIME
    , [session_id]                      INT
    , [database_name]                   VARCHAR(128)
    , [username]                        VARCHAR(128)
    , [session_server_principal_name]   VARCHAR(128)
    , [client_hostname]                 VARCHAR(128)
    , [client_app_name]                 VARCHAR(128)
    , [duration]                        DECIMAL(18, 2)
    , [cpu_time]                        DECIMAL(18, 2)
    , [logical_reads]                   BIGINT
    , [physical_reads]                  BIGINT
    , [writes]                          BIGINT
    , [row_count]                       BIGINT
    , [sql_text]                        VARCHAR(MAX)
)
WITH (DATA_COMPRESSION = PAGE)
GO

CREATE CLUSTERED INDEX SK01_history_slow_query_statement
    ON dbo.history_slow_query_statement (Dt_Evento)
    WITH (DATA_COMPRESSION = PAGE, FILLFACTOR = 95)
GO

-- DROP TABLE history_slow_query_statement

-- ============================================================
-- Procedure de carga do histórico de statements caros
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.sp_load_slow_query_statement
WITH ENCRYPTION
AS
BEGIN
    SET NOCOUNT ON
    SET XACT_ABORT ON

    BEGIN TRY
        BEGIN TRANSACTION

        DECLARE @TimeZone INT = DATEDIFF(HOUR, GETUTCDATE(), GETDATE())
              , @Dt_Ultimo_Registro DATETIME = ISNULL((SELECT MAX(Dt_Evento) FROM dbo.history_slow_query_statement WITH(NOLOCK)), '1900-01-01')

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
            FROM sys.fn_xe_file_target_read_file(N'/var/opt/mssql/log_jobs/xe/expensive_query_statement*.xel', N'/var/opt/mssql/log_jobs/xe/expensive_query_statement*.xem', NULL, NULL)
        ) AS dados
        WHERE timestamp_utc > @Dt_Ultimo_Registro

        -- ============================================================
        -- Inserção dos eventos extraídos do XML na tabela de histórico
        -- ============================================================
        INSERT INTO dbo.history_slow_query_statement
        (
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
        )
        SELECT
              A.timestamp_utc
            , xed.event_data.value('(action[@name="session_id"]/value)[1]', 'int') AS session_id
            , xed.event_data.value('(action[@name="database_name"]/value)[1]', 'varchar(128)') AS [database_name]
            , xed.event_data.value('(action[@name="username"]/value)[1]', 'varchar(128)') AS username
            , xed.event_data.value('(action[@name="session_server_principal_name"]/value)[1]', 'varchar(128)') AS session_server_principal_name
            , xed.event_data.value('(action[@name="client_hostname"]/value)[1]', 'varchar(128)') AS [client_hostname]
            , xed.event_data.value('(action[@name="client_app_name"]/value)[1]', 'varchar(128)') AS [client_app_name]
            , CAST(xed.event_data.value('(//data[@name="duration"]/value)[1]', 'bigint') / 1000000.0 AS NUMERIC(18, 2)) AS duration
            , CAST(xed.event_data.value('(//data[@name="cpu_time"]/value)[1]', 'bigint') / 1000000.0 AS NUMERIC(18, 2)) AS cpu_time
            , xed.event_data.value('(//data[@name="logical_reads"]/value)[1]', 'bigint') AS logical_reads
            , xed.event_data.value('(//data[@name="physical_reads"]/value)[1]', 'bigint') AS physical_reads
            , xed.event_data.value('(//data[@name="writes"]/value)[1]', 'bigint') AS writes
            , xed.event_data.value('(//data[@name="row_count"]/value)[1]', 'bigint') AS row_count
            , xed.event_data.value('(//action[@name="sql_text"]/value)[1]', 'varchar(max)') AS sql_text
        FROM #Eventos AS A
            CROSS APPLY A.event_data.nodes('//event') AS xed (event_data)

        COMMIT TRANSACTION

    END TRY

    BEGIN CATCH
        DECLARE @ErrorMessage NVARCHAR(4000)
              , @ErrorSeverity INT

        SELECT
              @ErrorMessage = N'PROCEDURE: sp_load_slow_query_statement; - Erro na linha ' + CAST(ERROR_LINE() AS VARCHAR(10))
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
-- QUERY BATCH, RPC
-- ============================================================
IF EXISTS (SELECT * FROM sys.server_event_sessions WHERE name = 'expensive_query_batch_rpc')
    DROP EVENT SESSION expensive_query_batch_rpc ON SERVER
GO

-- ============================================================
-- Criação da sessão de eventos estendidos para batch e RPC caros
-- ============================================================
CREATE EVENT SESSION [expensive_query_batch_rpc] ON SERVER
ADD EVENT sqlserver.rpc_completed
(
    ACTION
    (
          sqlserver.client_app_name
        , sqlserver.client_hostname
        , sqlserver.database_name
        , sqlserver.query_hash
        , sqlserver.session_id
        , sqlserver.session_server_principal_name
        , sqlserver.sql_text
        , sqlserver.username
    )
    WHERE
    (
        [package0].[greater_than_equal_uint64]([duration], (10000000))
        AND [sqlserver].[not_equal_i_sql_unicode_string]([sqlserver].[client_hostname], N'OPTIMUS-PRIME')
    )
)
ADD EVENT sqlserver.sql_batch_completed
(
    ACTION
    (
          sqlserver.client_app_name
        , sqlserver.client_hostname
        , sqlserver.database_name
        , sqlserver.query_hash
        , sqlserver.session_id
        , sqlserver.session_server_principal_name
        , sqlserver.sql_text
        , sqlserver.username
    )
    WHERE
    (
        [package0].[greater_than_equal_uint64]([duration], (10000000))
        AND [sqlserver].[not_equal_i_sql_unicode_string]([sqlserver].[client_hostname], N'OPTIMUS-PRIME')
    )
)
ADD TARGET package0.event_file
(
    SET filename = N'/var/opt/mssql/log_jobs/xe/expensive_query_batch_rpc*.xel'
      , max_file_size = (200)
      , max_rollover_files = (3)
      , metadatafile = N'/var/opt/mssql/log_jobs/xe/expensive_query_batch_rpc*.xem'
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
-- Inicia a sessão caso ainda não esteja rodando
-- ============================================================
IF NOT EXISTS
(
    SELECT 1
    FROM sys.dm_xe_sessions xs
    WHERE xs.name = N'expensive_query_batch_rpc'
)
BEGIN
    ALTER EVENT SESSION expensive_query_batch_rpc ON SERVER STATE = START
END
GO

-- ============================================================
-- Criação da tabela de histórico de batch/RPC caros
-- ============================================================
USE MAINTENANCE_DIX
GO

CREATE TABLE dbo.history_slow_query_batch_rpc
(
      [Dt_Evento]                       DATETIME
    , [object_name]                     NVARCHAR(60)
    , [session_id]                      INT
    , [database_name]                   VARCHAR(128)
    , [username]                        VARCHAR(128)
    , [session_server_principal_name]   VARCHAR(128)
    , [client_hostname]                 VARCHAR(128)
    , [client_app_name]                 VARCHAR(128)
    , [duration]                        DECIMAL(18, 2)
    , [cpu_time]                        DECIMAL(18, 2)
    , [logical_reads]                   BIGINT
    , [physical_reads]                  BIGINT
    , [writes]                          BIGINT
    , [row_count]                       BIGINT
    , [sql_text]                        VARCHAR(MAX)
    , [batch_text]                      VARCHAR(MAX)
    , [result]                          VARCHAR(100)
)
WITH (DATA_COMPRESSION = PAGE)
GO

CREATE CLUSTERED INDEX SK01_history_slow_query_batch
    ON dbo.history_slow_query_batch_rpc (Dt_Evento)
    WITH (DATA_COMPRESSION = PAGE, FILLFACTOR = 95)
GO

-- DROP TABLE history_slow_query_batch_rpc

-- ============================================================
-- Procedure de carga do histórico de batch/RPC caros
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.sp_load_slow_query_batch_rpc
WITH ENCRYPTION
AS
BEGIN
    SET NOCOUNT ON
    SET XACT_ABORT ON

    BEGIN TRY
        BEGIN TRANSACTION

        DECLARE @TimeZone INT = DATEDIFF(HOUR, GETUTCDATE(), GETDATE())
              , @Dt_Ultimo_Registro DATETIME = ISNULL((SELECT MAX(Dt_Evento) FROM dbo.history_slow_query_batch_rpc WITH(NOLOCK)), '1900-01-01')

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
                  CONVERT(XML, event_data) AS event_data
                , [object_name]
                , CAST(DATEADD(HOUR, @TimeZone, CAST(timestamp_utc AS DATETIME2(3))) AS DATETIME) AS timestamp_utc
            FROM sys.fn_xe_file_target_read_file(N'/var/opt/mssql/log_jobs/xe/expensive_query_batch_rpc*.xel', N'/var/opt/mssql/log_jobs/xe/expensive_query_batch_rpc*.xem', NULL, NULL)
        ) AS dados
        WHERE timestamp_utc > @Dt_Ultimo_Registro

        -- ============================================================
        -- Inserção dos eventos extraídos do XML na tabela de histórico
        -- ============================================================
        INSERT INTO dbo.history_slow_query_batch_rpc
        (
              Dt_Evento
            , [object_name]
            , session_id
            , [database_name]
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
            , [result]
        )
        SELECT
              A.timestamp_utc
            , [object_name]
            , xed.event_data.value('(action[@name="session_id"]/value)[1]', 'int') AS session_id
            , xed.event_data.value('(action[@name="database_name"]/value)[1]', 'varchar(128)') AS [database_name]
            , xed.event_data.value('(action[@name="username"]/value)[1]', 'varchar(128)') AS username
            , xed.event_data.value('(action[@name="session_server_principal_name"]/value)[1]', 'varchar(128)') AS session_server_principal_name
            , xed.event_data.value('(action[@name="client_hostname"]/value)[1]', 'varchar(128)') AS [client_hostname]
            , xed.event_data.value('(action[@name="client_app_name"]/value)[1]', 'varchar(128)') AS [client_app_name]
            , CAST(xed.event_data.value('(//data[@name="duration"]/value)[1]', 'bigint') / 1000000.0 AS NUMERIC(18, 2)) AS duration
            , CAST(xed.event_data.value('(//data[@name="cpu_time"]/value)[1]', 'bigint') / 1000000.0 AS NUMERIC(18, 2)) AS cpu_time
            , xed.event_data.value('(//data[@name="logical_reads"]/value)[1]', 'bigint') AS logical_reads
            , xed.event_data.value('(//data[@name="physical_reads"]/value)[1]', 'bigint') AS physical_reads
            , xed.event_data.value('(//data[@name="writes"]/value)[1]', 'bigint') AS writes
            , xed.event_data.value('(//data[@name="row_count"]/value)[1]', 'bigint') AS row_count
            , xed.event_data.value('(//action[@name="sql_text"]/value)[1]', 'varchar(max)') AS sql_text
            , xed.event_data.value('(//data[@name="batch_text"]/value)[1]', 'varchar(max)') AS batch_text
            , xed.event_data.value('(//data[@name="result"]/text)[1]', 'varchar(100)') AS [result]
        FROM #Eventos AS A
            CROSS APPLY A.event_data.nodes('//event') AS xed (event_data)

        COMMIT TRANSACTION

    END TRY

    BEGIN CATCH
        DECLARE @ErrorMessage NVARCHAR(4000)
              , @ErrorSeverity INT

        SELECT
              @ErrorMessage = N'PROCEDURE: sp_load_slow_query_batch_rpc; - Erro na linha ' + CAST(ERROR_LINE() AS VARCHAR(10))
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
