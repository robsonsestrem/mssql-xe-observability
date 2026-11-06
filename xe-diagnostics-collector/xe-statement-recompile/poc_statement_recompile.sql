/*
 *
    OBJETIVO: Capturar, via Extended Events (sql_statement_recompile), os statements que sofrem
              recompilação (OPTION (RECOMPILE), ADHOC ou PREPARED), persistir os eventos em arquivos
              .xel e carregar o histórico na tabela dbo.history_dark_queries_recompile
              por meio da procedure dbo.sp_load_dark_queries_recompile.

    PROJETO: mssql-xe-observability

    AUTHOR: Robson Sestrem

    REFERÊNCIAS DE URL:
    https://michaeljswart.com/2017/04/finding-your-dark-queries/
 *
 */
-- ============================================================
-- Sessão de Extended Events: dark_queries_recompile
-- ============================================================
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

-- Remove a sessão de eventos caso ela já exista
IF EXISTS (SELECT * FROM sys.server_event_sessions WHERE name = 'dark_queries_recompile')
    DROP EVENT SESSION dark_queries_recompile ON SERVER
GO

-- Criação da sessão de eventos para capturar recompilações de statements
CREATE EVENT SESSION [dark_queries_recompile] ON SERVER
ADD EVENT sqlserver.sql_statement_recompile
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
    -- WHERE ([recompile_cause]=(11)
    -- OU
    -- Filtro: ignora o host OSIRIS-DATABASE e captura apenas recompilações por OPTION (RECOMPILE), ADHOC ou PREPARED
    WHERE
    (
        [sqlserver].[not_equal_i_sql_unicode_string]([sqlserver].[client_hostname], N'OSIRIS-DATABASE')
        AND
        (
            [package0].[equal_uint64]([recompile_cause], 'Option (recompile) requested')
            OR [object_type] = 'ADHOC'
            OR [object_type] = 'PREPARED'
        )
    )
)
-- Destino dos eventos: arquivos .xel com até 3 rollovers de 200 MB
ADD TARGET package0.event_file
(
    SET filename = N'/var/opt/mssql/log_jobs/xe/sql_statement_recompile*.xel'
    , max_file_size = (200)
    , max_rollover_files = (3)
    , metadatafile = N'/var/opt/mssql/log_jobs/xe/sql_statement_recompile*.xem'
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
ALTER EVENT SESSION [dark_queries_recompile] ON SERVER STATE = START
GO


-- ============================================================
-- Tabela de histórico e índice clusterizado
-- ============================================================
USE DBA_PerformanceHub
GO

-- Tabela que armazena o histórico dos eventos de recompilação
CREATE TABLE dbo.history_dark_queries_recompile
(
    [Dt_Evento] DATETIME
    , [session_id] INT
    , [database_name] VARCHAR(128)
    , [username] VARCHAR(128)
    , [session_server_principal_name] VARCHAR(128)
    , [client_hostname] VARCHAR(128)
    , [client_app_name] VARCHAR(128)
    , [object_type] VARCHAR(200)
    , [recompile_cause] VARCHAR(200)
    , [sql_text] VARCHAR(MAX)
    , [offset] BIGINT
    , [offset_end] BIGINT
) WITH (DATA_COMPRESSION = PAGE)
GO

-- Índice clusterizado por data do evento
CREATE CLUSTERED INDEX SK01_history_dark_queries_recompile
    ON dbo.history_dark_queries_recompile (Dt_Evento)
    WITH (DATA_COMPRESSION = PAGE, FILLFACTOR = 95)
GO

-- ============================================================
-- Procedure de carga dos eventos
-- ============================================================

-- Procedure que lê os arquivos .xel e carrega os novos eventos no histórico
CREATE OR ALTER PROCEDURE dbo.sp_load_dark_queries_recompile
WITH ENCRYPTION
AS
BEGIN
    SET NOCOUNT ON
    SET XACT_ABORT ON

    BEGIN TRY
        BEGIN TRANSACTION

            -- Ajuste de fuso horário (UTC -> horário local) e último registro já carregado
            DECLARE @TimeZone INT = DATEDIFF(HOUR, GETUTCDATE(), GETDATE())
                  , @Dt_Ultimo_Registro DATETIME = ISNULL((SELECT MAX(Dt_Evento) FROM dbo.history_dark_queries_recompile WITH (NOLOCK)), '1900-01-01')

            IF OBJECT_ID('tempdb..#events') IS NOT NULL
                DROP TABLE #events

            -- Leitura dos arquivos de eventos, filtrando apenas os eventos posteriores ao último registro
            SELECT
                *
            INTO
                #events
            FROM
            (
                SELECT
                    CAST(DATEADD(HOUR, @TimeZone, CAST(timestamp_utc AS DATETIME2(3))) AS DATETIME) AS timestamp_utc
                    , CAST(event_data AS XML) AS [event_data]
                FROM sys.fn_xe_file_target_read_file(N'/var/opt/mssql/log_jobs/xe/sql_statement_recompile*.xel', N'/var/opt/mssql/log_jobs/xe/sql_statement_recompile*.xem', NULL, NULL)
            ) AS [dados]
            WHERE timestamp_utc > @Dt_Ultimo_Registro


            -- Extração dos atributos do XML e inserção no histórico
            INSERT INTO dbo.history_dark_queries_recompile
            (
                Dt_Evento
                , [database_name]
                , object_type
                , sql_text
                , recompile_cause
                , [offset]
                , offset_end
                , session_id
                , username
                , session_server_principal_name
                , client_hostname
                , client_app_name
            )
            SELECT
                event_file_value.timestamp_utc
                , DarkQueryData.[database_name]
                , DarkQueryData.object_type
                , COALESCE(DarkQueryData.sql_text, OBJECT_NAME(DarkQueryData.object_id, DarkQueryData.database_id)) AS command
                , DarkQueryData.recompile_cause
                , DarkQueryData.[offset]
                , DarkQueryData.[offset_end]
                , DarkQueryData.session_id
                , DarkQueryData.username
                , DarkQueryData.session_server_principal_name
                , DarkQueryData.client_hostname
                , DarkQueryData.client_app_name
            FROM #events AS event_file_value
            -- Expõe o XML do evento como coluna para os CROSS APPLY seguintes
            CROSS APPLY (
                SELECT
                    event_file_value.[event_data]
            ) AS event_file_value_xml ([xml])
            -- Shredding do XML: um valor por atributo do evento
            CROSS APPLY (
                SELECT
                    event_file_value_xml.[xml].value('(event/action[@name="sql_text"]/value)[1]', 'nvarchar(max)') AS sql_text
                    , event_file_value_xml.[xml].value('(event/data[@name="object_type"]/text)[1]', 'nvarchar(100)') AS object_type
                    , event_file_value_xml.[xml].value('(event/data[@name="object_id"]/value)[1]', 'bigint') AS object_id
                    , event_file_value_xml.[xml].value('(event/data[@name="source_database_id"]/value)[1]', 'bigint') AS database_id
                    , event_file_value_xml.[xml].value('(event/action[@name="database_name"]/value)[1]', 'varchar(128)') AS [database_name]
                    , event_file_value_xml.[xml].value('(event/data[@name="recompile_cause"]/text)[1]', 'nvarchar(100)') AS recompile_cause
                    , event_file_value_xml.[xml].value('(event/data[@name="offset"]/value)[1]', 'bigint') AS [offset]
                    , event_file_value_xml.[xml].value('(event/data[@name="offset_end"]/value)[1]', 'bigint') AS [offset_end]
                    , event_file_value_xml.[xml].value('(event/action[@name="session_id"]/value)[1]', 'int') AS session_id
                    , event_file_value_xml.[xml].value('(event/action[@name="username"]/value)[1]', 'varchar(128)') AS username
                    , event_file_value_xml.[xml].value('(event/action[@name="session_server_principal_name"]/value)[1]', 'varchar(128)') AS session_server_principal_name
                    , event_file_value_xml.[xml].value('(event/action[@name="client_hostname"]/value)[1]', 'varchar(128)') AS [client_hostname]
                    , event_file_value_xml.[xml].value('(event/action[@name="client_app_name"]/value)[1]', 'varchar(128)') AS [client_app_name]
            ) AS DarkQueryData

        COMMIT TRANSACTION
    END TRY
    BEGIN CATCH
        -- Monta e dispara a mensagem de erro com o contexto da procedure
        DECLARE @ErrorMessage NVARCHAR(4000), @ErrorSeverity INT;
        SELECT
            @ErrorMessage = N'PROCEDURE: sp_load_dark_queries_recompile; - Erro na linha ' + CAST(ERROR_LINE() AS VARCHAR(10))
                + ' - ' + ERROR_PROCEDURE()
                + ' - ' + CAST(ERROR_STATE() AS VARCHAR(10))
                + ' - ' + ERROR_MESSAGE()
                + ' - ' + CAST(ERROR_NUMBER() AS VARCHAR(10))
            , @ErrorSeverity = ERROR_SEVERITY();
        RAISERROR(@ErrorMessage, @ErrorSeverity, 1);

        -- Transação em estado incompatível: efetua o rollback
        IF (XACT_STATE()) = -1
        BEGIN
            PRINT N'A transação está em um estado incompatível. Retrocedendo transação.'
            ROLLBACK TRANSACTION;
        END

        -- Transação em estado compatível: efetua o commit
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
