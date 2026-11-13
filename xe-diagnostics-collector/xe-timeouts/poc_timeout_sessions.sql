/*
 *
    OBJETIVO: Capturar, via Extended Events (evento attention), os timeouts e conexões interrompidas
              das sessões, persistir os eventos em arquivos .xel e carregar o histórico na tabela
              dbo.history_timeout por meio da procedure dbo.sp_load_sessions_timeout.

    PROJETO: mssql-xe-observability

    AUTHOR: Robson Sestrem

    REFERÊNCIAS DE URL:
    https://dirceuresende.com/blog/sql-server-como-identificar-timeout-ou-conexoes-interrompidas-utilizando-extended-events-xe-ou-sql-profiler-trace/
 *
 */
-- ============================================================
-- Sessão de Extended Events: monitoring_timeouts
-- ============================================================
/*
 *  No SQL Server, temos vários tipos de timeout, onde eu gostaria de destacar:

 *  Remote Query Timeout (sp_configure), que define o tempo máximo que consultas remotas (utilizando linked server) podem ser executadas (tempo padrão: 600 segundos)

 *  lock_timeout (comando SET), que é o tempo que o client que está executando um comando SQL irá aguardar para que um lock seja liberado para continuar a execução desse comando (tempo padrão: -1 = infinito = vai aguardar indefinidamente)

 *  Command Timeout é uma propriedade de drivers de conexão a banco de dados, como ADO.NET, JDBC e outros, que permite definir um limite máximo de tempo que uma instrução SQL poderá executar no banco de dados.
 *  Esse valor pode ser alterado dinamicamente na aplicação, podendo ter tempos limites diferentes, dependendo do contexto. (tempo padrão: 30 segundos)

 *  Connection Timeout é uma propriedade da string de conexão que permite definir um limite de tempo máximo em que o driver de conexão irá aguardar para estabelecer uma conexão com o banco de dados (tempo padrão: 30 segundos)
 *
 */

-- Remove a sessão de eventos caso ela já exista
IF EXISTS (SELECT * FROM sys.server_event_sessions WHERE name = 'monitoring_timeouts')
    DROP EVENT SESSION monitoring_timeouts ON SERVER
GO

-- Criação da sessão de eventos para capturar o evento attention (timeouts e conexões interrompidas)
CREATE EVENT SESSION [monitoring_timeouts] ON SERVER
ADD EVENT sqlserver.attention
(
    ACTION
    (
        sqlserver.client_app_name
        , sqlserver.client_hostname
        , sqlserver.[database_name]
        , sqlserver.nt_username
        -- , sqlserver.num_response_rows
        , sqlserver.server_instance_name
        , sqlserver.server_principal_name
        , sqlserver.server_principal_sid
        , sqlserver.session_id
        , sqlserver.session_nt_username
        , sqlserver.session_server_principal_name
        , sqlserver.sql_text
        , sqlserver.username
    )
    -- Filtro: ignora os eventos originados do host OSIRIS-DATABASE
    WHERE
    (
        [sqlserver].[not_equal_i_sql_unicode_string]([sqlserver].[client_hostname], N'OSIRIS-DATABASE')
    )
)
-- Destino dos eventos: arquivos .xel com até 3 rollovers de 200 MB
ADD TARGET package0.event_file
(
    SET filename = N'/var/opt/mssql/log_jobs/xe/monitoring_timeouts*.xel'
    , max_file_size = (200)
    , max_rollover_files = (3)
    , metadatafile = N'/var/opt/mssql/log_jobs/xe/monitoring_timeouts*.xem'
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

-- Ativando a sessão (por padrão, ela é criada desativada)
ALTER EVENT SESSION [monitoring_timeouts] ON SERVER STATE = START
GO


-- ============================================================
-- Tabela para coleta armazenada dos eventos
-- ============================================================
USE DBA_PerformanceHub
GO

-- Tabela que armazena o histórico dos eventos de timeout
CREATE TABLE [dbo].[history_timeout]
(
      [Dt_Evento]                   DATETIME
    , [session_id]                  INT
    , [duration]                    BIGINT
    , [server_instance_name]        VARCHAR(128)
    , [database_name]               VARCHAR(128)
    , [session_nt_username]         VARCHAR(128)
    , [nt_username]                 VARCHAR(128)
    , server_principal_name         VARCHAR(128)
    , session_server_principal_name VARCHAR(128)
    , username                      VARCHAR(128)
    , [client_hostname]             VARCHAR(128)
    , [client_app_name]             VARCHAR(128)
    , [sql_text]                    NVARCHAR(MAX)
) WITH (DATA_COMPRESSION = PAGE)
GO

-- Índice clusterizado por data do evento
CREATE CLUSTERED INDEX SK01_history_timeout
    ON dbo.history_timeout (Dt_Evento)
    WITH (DATA_COMPRESSION = PAGE, FILLFACTOR = 95)
GO

-- ============================================================
-- Procedure de carga dos eventos
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.sp_load_sessions_timeout
WITH ENCRYPTION
AS
BEGIN
    SET NOCOUNT ON
    SET XACT_ABORT ON

    BEGIN TRY
        BEGIN TRANSACTION

            -- Ajuste de fuso horário (UTC -> horário local)
            DECLARE @TimeZone INT = DATEDIFF(HOUR, GETUTCDATE(), GETDATE())
            -- Último evento já carregado no histórico
            DECLARE @Dt_Ultimo_Evento DATETIME = ISNULL((SELECT MAX(Dt_Evento) FROM dbo.[History_Timeout] WITH (NOLOCK)), '1990-01-01')

            IF OBJECT_ID('tempdb..#Eventos') IS NOT NULL
                DROP TABLE #Eventos

            -- Leitura dos arquivos de eventos, filtrando apenas os eventos posteriores ao último registro
            SELECT
                *
            INTO
                #Eventos
            FROM
            (
                SELECT
                    CAST(DATEADD(HOUR, @TimeZone, CAST(timestamp_utc AS DATETIME2(3))) AS DATETIME) AS timestamp_utc
                    , CAST(event_data AS XML) AS [event_data]
                FROM sys.fn_xe_file_target_read_file(N'/var/opt/mssql/log_jobs/xe/monitoring_timeouts*.xel', N'/var/opt/mssql/log_jobs/xe/monitoring_timeouts*.xem', NULL, NULL)
            ) AS [dados]
            WHERE timestamp_utc > @Dt_Ultimo_Evento


            -- Extração dos atributos do XML e inserção no histórico
            INSERT INTO dbo.[history_timeout]
            SELECT
                A.timestamp_utc
                , xed.event_data.value('(action[@name="session_id"]/value)[1]', 'int') AS [session_id]
                , xed.event_data.value('(data[@name="duration"]/value)[1]', 'bigint') AS [duration]
                , xed.event_data.value('(action[@name="server_instance_name"]/value)[1]', 'varchar(100)') AS [server_instance_name]
                , xed.event_data.value('(action[@name="database_name"]/value)[1]', 'varchar(100)') AS [database_name]
                , xed.event_data.value('(action[@name="session_nt_username"]/value)[1]', 'varchar(100)') AS [session_nt_username]
                , xed.event_data.value('(action[@name="nt_username"]/value)[1]', 'varchar(100)') AS [nt_username]
                , xed.event_data.value('(action[@name="server_principal_name"]/value)[1]', 'nvarchar(128)') AS server_principal_name
                , xed.event_data.value('(action[@name="session_server_principal_name"]/value)[1]', 'nvarchar(128)') AS session_server_principal_name
                , xed.event_data.value('(action[@name="username"]/value)[1]', 'nvarchar(128)') AS username
                , xed.event_data.value('(action[@name="client_hostname"]/value)[1]', 'varchar(100)') AS [client_hostname]
                , xed.event_data.value('(action[@name="client_app_name"]/value)[1]', 'varchar(100)') AS [client_app_name]
                , xed.event_data.value('(action[@name="sql_text"]/value)[1]', 'varchar(max)') AS [sql_text]
            FROM #Eventos AS A
            -- Expande cada nó <event> do XML em uma linha
            CROSS APPLY A.event_data.nodes('//event') AS xed (event_data)

        COMMIT TRANSACTION
    END TRY
    BEGIN CATCH        
        DECLARE @ErrorMessage NVARCHAR(4000), @ErrorSeverity INT;
        SELECT
            @ErrorMessage = N'PROCEDURE: sp_load_sessions_timeout; - Erro na linha ' + CAST(ERROR_LINE() AS VARCHAR(10))
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
            PRINT N'A transação e compatível. Transação completada.'
            COMMIT TRANSACTION;
        END
    END CATCH

    SET NOCOUNT OFF
    SET XACT_ABORT OFF

END
GO
