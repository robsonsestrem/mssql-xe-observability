/*
 *
    OBJETIVO: Capturar, via Extended Events, os waits (sqlos.wait_info) e as estatísticas de execução
              (sp_statement_completed e sql_statement_completed) das queries de usuário, persistir os
              eventos em arquivos .xel e carregar o histórico nas tabelas history_wait_info_xevents,
              history_waits e history_query_stats por meio da procedure dbo.sp_load_query_performance_wait_info.

    PROJETO: mssql-xe-observability

    AUTHOR: Robson Sestrem

    REFERÊNCIAS DE URL:
    https://www.cnblogs.com/lyhabc/articles/4103206.html
 *
 */
-- ============================================================
-- Sessão de Extended Events: query_performance_wait_info
-- ============================================================
/*
 * Observação: se colocar muitos predicados acaba atingindo limite de caracteres:
 * Error (43,11): The predicate on event, "sqlos.wait_info", exceeds the maximum length of 3000 characters.
 */

-- Versão anterior da sessão (mantida comentada para referência)
/*
CREATE EVENT SESSION [query_performance_wait_info] ON SERVER
ADD EVENT sqlos.wait_info(
    ACTION(sqlserver.client_app_name,sqlserver.client_hostname,sqlserver.database_id,sqlserver.database_name,sqlserver.plan_handle,sqlserver.query_hash,sqlserver.query_plan_hash,sqlserver.session_id,sqlserver.sql_text)
    WHERE (
    --[package0].[greater_than_uint64]([sqlserver].[database_id],(4))
    [sqlserver].[database_id]>(4)
    AND [package0].[equal_boolean]([sqlserver].[is_system],(0))
    AND [package0].[greater_than_equal_uint64]([duration],(100))
    AND [sqlserver].[query_hash]>(0)
    AND [package0].[not_equal_i_unicode_string]([sqlserver].[database_name],N'DBA_PerformanceHub')
    AND [package0].[not_equal_uint64]([wait_type],'BROKER_EVENTHANDLER')
    AND [package0].[not_equal_uint64]([wait_type],'BROKER_RECEIVE_WAITFOR')
    AND [package0].[not_equal_uint64]([wait_type],'BROKER_TO_FLUSH')
    AND [package0].[not_equal_uint64]([wait_type],'CHECKPOINT_QUEUE')
    AND [package0].[not_equal_uint64]([wait_type],'CHKPT')
    AND [package0].[not_equal_uint64]([wait_type],'CXCONSUMER')
    AND [package0].[not_equal_uint64]([wait_type],'DIRTY_PAGE_POLL')
    AND [package0].[not_equal_uint64]([wait_type],'DISPATCHER_QUEUE_SEMAPHORE')
    AND [package0].[not_equal_uint64]([wait_type],'EXECSYNC')
    AND [package0].[not_equal_uint64]([wait_type],'FSAGENT')
    AND [package0].[not_equal_uint64]([wait_type],'FT_SCHEDULER_IDLE_WAIT')
    AND [package0].[not_equal_uint64]([wait_type],'FT_IFTSHC_MUTEX')
    AND [package0].[not_equal_uint64]([wait_type],'KSOURCE_WAKEUP')
    AND [package0].[not_equal_uint64]([wait_type],'LOGMGR_QUEUE')
    AND [package0].[not_equal_uint64]([wait_type],'MEMORY_ALLOCATION_EXT')
    AND [package0].[not_equal_uint64]([wait_type],'ONDEMAND_TASK_QUEUE')
    AND [package0].[not_equal_uint64]([wait_type],'PARALLEL_REDO_DRAIN_WORKER')
    AND [package0].[not_equal_uint64]([wait_type],'PARALLEL_REDO_WORKER_SYNC')
    AND [package0].[not_equal_uint64]([wait_type],'PARALLEL_REDO_WORKER_SYNC')
    AND [package0].[not_equal_uint64]([wait_type],'PARALLEL_REDO_WORKER_WAIT_WORK')
    AND [package0].[not_equal_uint64]([wait_type],'PREEMPTIVE_XE_GETTARGETSTATE')
    AND [package0].[not_equal_uint64]([wait_type],'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP')
    AND [package0].[not_equal_uint64]([wait_type],'QDS_ASYNC_QUEUE')
    AND [package0].[not_equal_uint64]([wait_type],'REQUEST_FOR_DEADLOCK_SEARCH')
    AND [package0].[not_equal_uint64]([wait_type],'RESOURCE_QUEUE')
    AND [package0].[not_equal_uint64]([wait_type],'SLEEP_BPOOL_FLUSH')
    AND [package0].[not_equal_uint64]([wait_type],'SLEEP_DBSTARTUP')
    AND [package0].[not_equal_uint64]([wait_type],'SLEEP_DCOMSTARTUP')
    AND [package0].[not_equal_uint64]([wait_type],'SLEEP_MASTERDBREADY')
    AND [package0].[not_equal_uint64]([wait_type],'SLEEP_MASTERMDREADY')
    AND [package0].[not_equal_uint64]([wait_type],'SLEEP_MASTERUPGRADED')
    AND [package0].[not_equal_uint64]([wait_type],'SLEEP_MSDBSTARTUP')
    AND [package0].[not_equal_uint64]([wait_type],'SLEEP_SYSTEMTASK')
    AND [package0].[not_equal_uint64]([wait_type],'SLEEP_TASK')
    AND [package0].[not_equal_uint64]([wait_type],'SLEEP_TEMPDBSTARTUP')
    AND [package0].[not_equal_uint64]([wait_type],'SP_SERVER_DIAGNOSTICS_SLEEP')
    AND [package0].[not_equal_uint64]([wait_type],'WAIT_FOR_RESULTS')
    AND [package0].[not_equal_uint64]([wait_type],'WAITFOR')
    AND [package0].[not_equal_uint64]([wait_type],'SOS_SCHEDULER_YIELD')
    )),
ADD EVENT sqlserver.sp_statement_completed(SET collect_object_name=(1),collect_statement=(1)
    ACTION(sqlserver.client_app_name,sqlserver.client_hostname,sqlserver.database_id,sqlserver.database_name,sqlserver.plan_handle,sqlserver.query_hash,sqlserver.query_plan_hash,sqlserver.session_id)
    WHERE ([package0].[greater_than_uint64]([sqlserver].[database_id],(4))
    AND [package0].[equal_boolean]([sqlserver].[is_system],(0))
    AND [package0].[greater_than_equal_int64]([duration],(5000000))
    AND [package0].[not_equal_i_unicode_string]([sqlserver].[database_name],N'DBA_PerformanceHub')
    AND [sqlserver].[query_hash]>(0)
    )),
ADD EVENT sqlserver.sql_statement_completed(
    ACTION(sqlserver.client_app_name,sqlserver.client_hostname,sqlserver.database_id,sqlserver.database_name,sqlserver.plan_handle,sqlserver.query_hash,sqlserver.query_plan_hash,sqlserver.session_id)
    WHERE ([package0].[greater_than_uint64]([sqlserver].[database_id],(4))
    AND [package0].[equal_boolean]([sqlserver].[is_system],(0))
    AND [package0].[greater_than_equal_int64]([duration],(5000000))
    AND [package0].[not_equal_i_unicode_string]([sqlserver].[database_name],N'DBA_PerformanceHub')
    AND [sqlserver].[query_hash]>(0)
    ))
ADD TARGET package0.asynchronous_file_target(
    SET filename=N'/var/opt/mssql/log_jobs/xe/query_performance_wait_info*.xel'
    ,max_file_size=(200)
    ,max_rollover_files=(5)
    ,metadatafile=N'/var/opt/mssql/log_jobs/xe/query_performance_wait_info*.xem')
WITH (MAX_MEMORY=4096 KB,EVENT_RETENTION_MODE=ALLOW_SINGLE_EVENT_LOSS,MAX_DISPATCH_LATENCY=5 SECONDS,MAX_EVENT_SIZE=0 KB,MEMORY_PARTITION_MODE=NONE,TRACK_CAUSALITY=OFF,STARTUP_STATE=ON)
GO

ALTER EVENT SESSION [query_performance_wait_info] ON SERVER STATE = START
GO
*/

-- Remove a sessão de eventos caso ela já exista
IF EXISTS (SELECT * FROM sys.server_event_sessions WHERE name = 'query_performance_wait_info')
    DROP EVENT SESSION query_performance_wait_info ON SERVER
GO


-- Criação da sessão de eventos: waits e statements de queries de usuário
CREATE EVENT SESSION [query_performance_wait_info] ON SERVER
-- Evento de wait: filtra por tipo de wait e duração mínima
ADD EVENT sqlos.wait_info
(
    ACTION
    (
        sqlserver.client_app_name
        , sqlserver.client_hostname
        , sqlserver.database_id
        , sqlserver.database_name
        , sqlserver.plan_handle
        , sqlserver.query_hash
        , sqlserver.query_plan_hash
        , sqlserver.session_id
        , sqlserver.sql_text
    )
    WHERE
    (
        [sqlserver].[database_id] > (4)
        AND [package0].[equal_boolean]([sqlserver].[is_system], (0)) -- non system queries - session_id > 50
        AND [sqlserver].[query_hash] > (0)
        AND [package0].[not_equal_i_unicode_string]([sqlserver].[database_name], N'DBA_PerformanceHub')
        AND [sqlserver].[not_equal_i_sql_unicode_string]([sqlserver].[client_hostname], N'OSIRIS-DATABASE')
        -- Apenas eventos de fim, por faixa de wait_type e duração mínima
        AND
        (
            opcode = 1 -- End Events Only
            AND
            (
                (wait_type > 0 AND wait_type <= 21 AND [package0].[greater_than_equal_uint64]([duration], (5000))) -- LCK_ waits
                OR (wait_type >= 32 AND wait_type <= 37 AND [package0].[greater_than_equal_uint64]([duration], (10000))) -- LATCH_ waits
                OR (wait_type >= 48 AND wait_type <= 53 AND [package0].[greater_than_equal_uint64]([duration], (10000))) -- PAGELATCH_ waits
                OR (wait_type >= 64 AND wait_type <= 69 AND [package0].[greater_than_equal_uint64]([duration], (10000))) -- PAGEIOLATCH_ waits
                OR (wait_type >= 97 AND wait_type <= 99 AND [package0].[greater_than_equal_uint64]([duration], (10000))) -- IO (Disk/Network) waits
                OR (wait_type = 110 AND [package0].[greater_than_equal_uint64]([duration], (800))) -- RESOURCE_SEMAPHORE waits
                OR (wait_type = 116 AND [package0].[greater_than_equal_uint64]([duration], (800))) -- SOS_WORKER waits
                OR (wait_type = 123 AND [package0].[greater_than_equal_uint64]([duration], (10000))) -- SOS_SCHEDULER_YIELD waits
                OR (wait_type = 181 AND [package0].[greater_than_equal_uint64]([duration], (10000))) -- WRITELOG waits
                OR (wait_type >= 178 AND wait_type <= 179 AND [package0].[greater_than_equal_uint64]([duration], (500))) -- FCB_REPLICA_ waits
                OR (wait_type = 189 AND [package0].[greater_than_equal_uint64]([duration], (800))) -- CMEMTHREAD waits
                OR (wait_type = 191 AND [package0].[greater_than_equal_uint64]([duration], (10000))) -- CXPACKET waits
                OR (wait_type = 222 AND [package0].[greater_than_equal_uint64]([duration], (800))) -- TRACEWRITE waits
                OR (wait_type = 285 AND [package0].[greater_than_equal_uint64]([duration], (800))) -- RESOURCE_SEMAPHORE_MUTEX waits
                OR (wait_type = 299 AND [package0].[greater_than_equal_uint64]([duration], (800))) -- RESOURCE_SEMAPHORE_QUERY_COMPILE waits
            )
        )
    )
),
-- Evento de statement de procedure concluído (duração mínima de 5 segundos)
ADD EVENT sqlserver.sp_statement_completed
(
    SET collect_object_name = (1)
    , collect_statement = (1)
    ACTION
    (
        sqlserver.client_app_name
        , sqlserver.client_hostname
        , sqlserver.database_id
        , sqlserver.database_name
        , sqlserver.plan_handle
        , sqlserver.query_hash
        , sqlserver.query_plan_hash
        , sqlserver.session_id
    )
    WHERE
    (
        [package0].[greater_than_uint64]([sqlserver].[database_id], (4))
        AND [package0].[equal_boolean]([sqlserver].[is_system], (0))
        AND [package0].[greater_than_equal_int64]([duration], (5000000))
        AND [package0].[not_equal_i_unicode_string]([sqlserver].[database_name], N'DBA_PerformanceHub')
        AND [sqlserver].[query_hash] > (0)
        AND [sqlserver].[not_equal_i_sql_unicode_string]([sqlserver].[client_hostname], N'OSIRIS-DATABASE')
    )
),
-- Evento de statement ad hoc concluído (duração mínima de 5 segundos)
ADD EVENT sqlserver.sql_statement_completed
(
    ACTION
    (
        sqlserver.client_app_name
        , sqlserver.client_hostname
        , sqlserver.database_id
        , sqlserver.database_name
        , sqlserver.plan_handle
        , sqlserver.query_hash
        , sqlserver.query_plan_hash
        , sqlserver.session_id
    )
    WHERE
    (
        [package0].[greater_than_uint64]([sqlserver].[database_id], (4))
        AND [package0].[equal_boolean]([sqlserver].[is_system], (0))
        AND [package0].[greater_than_equal_int64]([duration], (5000000))
        AND [package0].[not_equal_i_unicode_string]([sqlserver].[database_name], N'DBA_PerformanceHub')
        AND [sqlserver].[query_hash] > (0)
        AND [sqlserver].[not_equal_i_sql_unicode_string]([sqlserver].[client_hostname], N'OSIRIS-DATABASE')
    )
)
-- Destino dos eventos: arquivos .xel com até 3 rollovers de 200 MB
ADD TARGET package0.asynchronous_file_target
(
    SET filename = N'/var/opt/mssql/log_jobs/xe/query_performance_wait_info*.xel'
    , max_file_size = (200)
    , max_rollover_files = (3)
    , metadatafile = N'/var/opt/mssql/log_jobs/xe/query_performance_wait_info*.xem'
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


-- Ativando a sessão (por padrão, ela é criada desativada)
ALTER EVENT SESSION [query_performance_wait_info] ON SERVER STATE = START
GO


-- ============================================================
-- Tabelas para processamento intermediário
-- ============================================================
USE DBA_PerformanceHub
GO

-- Tabela history_wait_info_xevents: eventos brutos (XML) lidos dos arquivos .xel
IF OBJECT_ID('history_wait_info_xevents') IS NULL
    CREATE TABLE history_wait_info_xevents
    (
        event_time DATETIME2(3)
        , event_type NVARCHAR(128)
        , query_hash DECIMAL(38,0)
        , event_data XML
    ) WITH (DATA_COMPRESSION = PAGE)
GO

-- Índice clusterizado por data do evento
CREATE CLUSTERED INDEX SK01_history_wait_info_xevents
    ON dbo.history_wait_info_xevents (event_time)
    WITH (DATA_COMPRESSION = PAGE, FILLFACTOR = 90)
GO

-- Índice não clusterizado por tipo de evento e query_hash
CREATE NONCLUSTERED INDEX [IDX_PLAN_E651A9EC_history_wait_info_xevents_event_type_query_hash]
    ON [dbo].[history_wait_info_xevents]
(
    [event_type] ASC
    , [query_hash] ASC
) WITH (SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF) ON [PRIMARY]
GO

-- Estatísticas sobre tipo de evento e query_hash
CREATE STATISTICS [STAT_PLAN_C36591FE_history_wait_info_xevents_event_type_query_hash]
    ON [dbo].[history_wait_info_xevents]
(
    [event_type]
    , [query_hash]
)
GO

-- Tabela history_waits: waits extraídos dos eventos wait_info
IF OBJECT_ID('history_waits') IS NULL
    CREATE TABLE history_waits
    (
        event_time DATETIME2
        , event_interval DATETIME2
        , query_hash DECIMAL(38,0)
        , query_plan_hash DECIMAL(38,0)
        , session_id INT
        , client_hostname NVARCHAR(128)
        , database_name NVARCHAR(128)
        , statement NVARCHAR(MAX)
        , wait_type NVARCHAR(128)
        , duration_ms BIGINT
        , signal_duration_ms BIGINT
    ) WITH (DATA_COMPRESSION = PAGE)
GO

-- Índice clusterizado por data do evento
CREATE CLUSTERED INDEX SK01_history_waits
    ON dbo.history_waits (event_time)
    WITH (DATA_COMPRESSION = PAGE, FILLFACTOR = 90)
GO

-- Tabela history_query_stats: estatísticas de execução extraídas dos eventos de statement concluído
IF OBJECT_ID('history_query_stats') IS NULL
    CREATE TABLE history_query_stats
    (
        event_time DATETIME2(3)
        , event_interval DATETIME2(3)
        , query_hash DECIMAL(38,0)
        , query_plan_hash DECIMAL(38,0)
        , session_id INT
        , client_hostname NVARCHAR(128)
        , database_name NVARCHAR(128)
        , statement NVARCHAR(MAX)
        , duration_ms BIGINT
        , cpu_time_ms BIGINT
        , physical_reads BIGINT
        , logical_reads BIGINT
        , writes BIGINT
        , row_count BIGINT
    ) WITH (DATA_COMPRESSION = PAGE)
GO

-- Índice clusterizado por data do evento
CREATE CLUSTERED INDEX SK01_history_query_stats
    ON dbo.history_query_stats (event_time)
    WITH (DATA_COMPRESSION = PAGE, FILLFACTOR = 90)
GO


-- ============================================================
-- Procedure para carga periódica
-- ============================================================

-- Procedure que lê os arquivos .xel e carrega os novos eventos nas tabelas de histórico
CREATE OR ALTER PROCEDURE dbo.sp_load_query_performance_wait_info
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
            DECLARE @Ultimo_Log DATETIME2(3) = ISNULL((SELECT MAX(event_time) FROM dbo.history_wait_info_xevents WITH (NOLOCK)), '1900-01-01')

            -- Carga dos eventos brutos (XML) posteriores ao último registro já carregado
            INSERT INTO history_wait_info_xevents
            (
                event_time
                , event_type
                , query_hash
                , event_data
            )
            SELECT
                z.timestamp_utc
                , z.event_type
                , z.query_hash
                , z.event_data
            FROM
            (
                SELECT
                    CAST(DATEADD(HOUR, @TimeZone, CAST(timestamp_utc AS DATETIME2(3))) AS DATETIME2(3)) AS timestamp_utc
                    , x.event_data.value('(/event/@name)[1]', 'nvarchar(128)') AS event_type
                    , x.event_data.value('(event/action[@name="query_hash"])[1]', 'decimal(38,0)') AS query_hash
                    , x.event_data
                FROM sys.fn_xe_file_target_read_file (N'/var/opt/mssql/log_jobs/xe/query_performance_wait_info*.xel', N'/var/opt/mssql/log_jobs/xe/query_performance_wait_info*.xem', NULL, NULL)
                -- Converte o event_data para XML
                CROSS APPLY (
                    SELECT
                        CAST(event_data AS XML) AS event_data
                ) AS x
            ) AS z
            WHERE z.timestamp_utc > @Ultimo_Log


            -- Extração dos waits (eventos wait_info) para a tabela history_waits
            INSERT INTO history_waits
            (
                event_time
                , event_interval
                , query_hash
                , query_plan_hash
                , session_id
                , client_hostname
                , database_name
                , statement
                , wait_type
                , duration_ms
                , signal_duration_ms
            )
            SELECT
                z.event_time
                , z.event_interval
                , z.query_hash
                , z.query_plan_hash
                , z.session_id
                , z.client_hostname
                , z.database_name
                , z.statement
                , z.wait_type
                , z.duration_ms
                , z.signal_duration_ms
            FROM
            (
                SELECT
                    x.event_time
                    , DATEADD(MINUTE, DATEDIFF(MINUTE, 0, event_time), 0) AS event_interval
                    , x.event_data.value('(event/action[@name="query_hash"])[1]', 'decimal(38,0)') AS query_hash
                    , x.event_data.value('(event/action[@name="query_plan_hash"])[1]', 'decimal(38,0)') AS query_plan_hash
                    , x.event_data.value('(event/action[@name="session_id"])[1]', 'int') AS session_id
                    , x.event_data.value('(event/action[@name="client_hostname"])[1]', 'nvarchar(128)') AS client_hostname
                    , x.event_data.value('(event/action[@name="database_name"])[1]', 'nvarchar(128)') AS database_name
                    , x.event_data.value('(event/action[@name="sql_text"])[1]', 'nvarchar(max)') AS statement
                    , x.event_data.value('(event/data[@name="wait_type"]/text)[1]', 'nvarchar(128)') AS wait_type
                    , x.event_data.value('(event/data[@name="duration"])[1]', 'bigint') AS duration_ms
                    , x.event_data.value('(event/data[@name="signal_duration"])[1]', 'bigint') AS signal_duration_ms
                FROM history_wait_info_xevents AS x
                WHERE x.query_hash > 0
                AND x.event_type = 'wait_info'
            ) AS z
            WHERE z.event_time > @Ultimo_Log


            -- Extração das estatísticas de execução (sp_statement_completed e sql_statement_completed) para a tabela history_query_stats
            INSERT INTO history_query_stats
            (
                event_time
                , event_interval
                , query_hash
                , query_plan_hash
                , session_id
                , client_hostname
                , database_name
                , statement
                , duration_ms
                , cpu_time_ms
                , physical_reads
                , logical_reads
                , writes
                , row_count
            )
            SELECT
                z.event_time
                , z.event_interval
                , z.query_hash
                , z.query_plan_hash
                , z.session_id
                , z.client_hostname
                , z.database_name
                , z.statement
                , z.duration_ms
                , z.cpu_time_ms
                , z.physical_reads
                , z.logical_reads
                , z.writes
                , z.row_count
            FROM
            (
                SELECT
                    x.event_time
                    , DATEADD(MINUTE, DATEDIFF(MINUTE, 0, event_time), 0) AS event_interval
                    , x.event_data.value('(event/action[@name="query_hash"])[1]', 'decimal(38,0)') AS query_hash
                    , x.event_data.value('(event/action[@name="query_plan_hash"])[1]', 'decimal(38,0)') AS query_plan_hash
                    , x.event_data.value('(event/action[@name="session_id"])[1]', 'int') AS session_id
                    , x.event_data.value('(event/action[@name="client_hostname"])[1]', 'nvarchar(128)') AS client_hostname
                    , x.event_data.value('(event/action[@name="database_name"])[1]', 'nvarchar(128)') AS database_name
                    , x.event_data.value('(event/data[@name="statement"])[1]', 'nvarchar(max)') AS statement
                    , x.event_data.value('(event/data[@name="duration"])[1]', 'bigint') AS duration_ms
                    , x.event_data.value('(event/data[@name="cpu_time"])[1]', 'bigint') AS cpu_time_ms
                    , x.event_data.value('(event/data[@name="physical_reads"])[1]', 'bigint') AS physical_reads
                    , x.event_data.value('(event/data[@name="logical_reads"])[1]', 'bigint') AS logical_reads
                    , x.event_data.value('(event/data[@name="writes"])[1]', 'bigint') AS writes
                    , x.event_data.value('(event/data[@name="row_count"])[1]', 'bigint') AS row_count
                FROM history_wait_info_xevents AS x
                WHERE x.query_hash > 0
                AND (x.event_type = 'sp_statement_completed' OR x.event_type = 'sql_statement_completed')
            ) AS z
            WHERE z.event_time > @Ultimo_Log

        COMMIT TRANSACTION
    END TRY
    BEGIN CATCH
        -- Monta e dispara a mensagem de erro com o contexto da procedure
        DECLARE @ErrorMessage NVARCHAR(4000), @ErrorSeverity INT;
        SELECT
            @ErrorMessage = N'PROCEDURE: sp_load_query_performance_wait_info; - Erro na linha ' + CAST(ERROR_LINE() AS VARCHAR(10))
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


-----------------------------------------------------------------------------
-- A N T I G O ==> mudou valor das chaves
-----------------------------------------------------------------------------
--CREATE EVENT SESSION [TrackResourceWaits] ON SERVER
--ADD EVENT  sqlos.wait_info
--(    -- Capture the database_id, session_id, plan_handle, and sql_text
--    ACTION(sqlserver.database_id,sqlserver.session_id,sqlserver.sql_text,sqlserver.plan_handle)
--    WHERE
--        (opcode = 1 --End Events Only
--            AND duration > 100 -- had to accumulate 100ms of time
--            AND ((wait_type > 0 AND wait_type < 22) -- LCK_ waits
--                    OR (wait_type > 31 AND wait_type < 38) -- LATCH_ waits
--                    OR (wait_type > 47 AND wait_type < 54) -- PAGELATCH_ waits
--                    OR (wait_type > 63 AND wait_type < 70) -- PAGEIOLATCH_ waits
--                    OR (wait_type > 96 AND wait_type < 100) -- IO (Disk/Network) waits
--                    OR (wait_type = 107) -- RESOURCE_SEMAPHORE waits
--                    OR (wait_type = 113) -- SOS_WORKER waits
--                    OR (wait_type = 120) -- SOS_SCHEDULER_YIELD waits
--                    OR (wait_type = 178) -- WRITELOG waits
--                    OR (wait_type > 174 AND wait_type < 177) -- FCB_REPLICA_ waits
--                    OR (wait_type = 186) -- CMEMTHREAD waits
--                    OR (wait_type = 187) -- CXPACKET waits
--                    OR (wait_type = 207) -- TRACEWRITE waits
--                    OR (wait_type = 269) -- RESOURCE_SEMAPHORE_MUTEX waits
--                    OR (wait_type = 283) -- RESOURCE_SEMAPHORE_QUERY_COMPILE waits
--                    OR (wait_type = 284) -- RESOURCE_SEMAPHORE_SMALL_QUERY waits
--                )
--        )
--)
--ADD TARGET package0.ring_buffer(SET max_memory=4096)
--WITH (EVENT_RETENTION_MODE=ALLOW_SINGLE_EVENT_LOSS,
--      MAX_DISPATCH_LATENCY=5 SECONDS)
--GO

------------------------------------------------------
-- Query para validar chave e valores atuais
------------------------------------------------------
--    SELECT name, map_key, map_value
--    FROM sys.dm_xe_map_values
--    WHERE name = 'wait_types'

------------------------------------------------------
-- XE do autor atualizada
------------------------------------------------------
/*
CREATE EVENT SESSION [TrackResourceWaits] ON SERVER
ADD EVENT  sqlos.wait_info
(    -- Capture the database_id, session_id, plan_handle, and sql_text
    ACTION(sqlserver.database_id,sqlserver.session_id,sqlserver.sql_text,sqlserver.plan_handle)
    WHERE
        (opcode = 1 --End Events Only
            AND duration > 100 -- had to accumulate 100ms of time
            AND ((wait_type > 0 AND wait_type <= 21) -- LCK_ waits
                    OR (wait_type >= 32 AND wait_type <= 37) -- LATCH_ waits
                    OR (wait_type >= 48 AND wait_type <= 53) -- PAGELATCH_ waits
                    OR (wait_type >= 64 AND wait_type <= 69) -- PAGEIOLATCH_ waits
                    OR (wait_type >= 97 AND wait_type <= 99) -- IO (Disk/Network) waits
                    OR (wait_type = 110) -- RESOURCE_SEMAPHORE waits
                    OR (wait_type = 116) -- SOS_WORKER waits
                    OR (wait_type = 123) -- SOS_SCHEDULER_YIELD waits
                    OR (wait_type = 181) -- WRITELOG waits
                    OR (wait_type >= 178 AND wait_type <= 179) -- FCB_REPLICA_ waits
                    OR (wait_type = 189) -- CMEMTHREAD waits
                    OR (wait_type = 191) -- CXPACKET waits
                    OR (wait_type = 222) -- TRACEWRITE waits
                    OR (wait_type = 285) -- RESOURCE_SEMAPHORE_MUTEX waits
                    OR (wait_type = 299) -- RESOURCE_SEMAPHORE_QUERY_COMPILE waits
                    --OR (wait_type = 284) -- RESOURCE_SEMAPHORE_SMALL_QUERY waits
                )
        )
)
ADD TARGET package0.ring_buffer(SET max_memory=4096)
WITH (EVENT_RETENTION_MODE=ALLOW_SINGLE_EVENT_LOSS,
      MAX_DISPATCH_LATENCY=5 SECONDS)
GO
*/
