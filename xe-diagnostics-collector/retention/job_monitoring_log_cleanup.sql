/*
 *
    OBJETIVO: Criar o job do SQL Server Agent "DBA - Monitoring_Log_Cleanup", que controla a retenção dos dados
              coletados com Extended Events no banco DBA_PerformanceHub. Cada step remove os registros antigos
              das tabelas de histórico, preservando uma quantidade mínima de registros. O job executa
              a cada 2 semanas, aos domingos às 07:00.

    PROJETO: mssql-xe-observability

    AUTHOR: Robson Sestrem
 *
 */
USE [msdb]
GO

/****** Object:  Job [DBA - Monitoring_Log_Cleanup] ******/
-- Transação única: qualquer falha na criação do job desfaz todo o processo (ver QuitWithRollback)
BEGIN TRANSACTION
DECLARE @ReturnCode INT
SELECT @ReturnCode = 0

/****** Object:  JobCategory [Database Maintenance] ******/
-- Cria a categoria de job "Database Maintenance" caso ainda não exista
IF NOT EXISTS (
    SELECT name
    FROM msdb.dbo.syscategories
    WHERE name = N'Database Maintenance'
    AND category_class = 1
)
BEGIN
    EXEC @ReturnCode = msdb.dbo.sp_add_category
        @class = N'JOB'
        , @type = N'LOCAL'
        , @name = N'Database Maintenance'
    IF (@@ERROR <> 0 OR @ReturnCode <> 0)
        GOTO QuitWithRollback

END

-- Criação do job
DECLARE @jobId BINARY(16)
EXEC @ReturnCode = msdb.dbo.sp_add_job
    @job_name = N'DBA - Monitoring_Log_Cleanup'
    , @enabled = 1
    , @notify_level_eventlog = 0
    , @notify_level_email = 0
    , @notify_level_netsend = 0
    , @notify_level_page = 0
    , @delete_level = 0
    , @description = N'Controle para retenção de dados sobre coletas com XE.'
    , @category_name = N'Database Maintenance'
    , @owner_login_name = N'sa'
    , @job_id = @jobId OUTPUT
IF (@@ERROR <> 0 OR @ReturnCode <> 0)
    GOTO QuitWithRollback

/****** Object:  Step [blocked process cleanup] ******/
-- Step 1: retenção de 15 dias (mínimo de 1.000 registros preservados) em dbo.history_blocked_process
EXEC @ReturnCode = msdb.dbo.sp_add_jobstep
    @job_id = @jobId
    , @step_name = N'blocked process cleanup'
    , @step_id = 1
    , @cmdexec_success_code = 0
    , @on_success_action = 3
    , @on_success_step_id = 0
    , @on_fail_action = 2
    , @on_fail_step_id = 0
    , @retry_attempts = 0
    , @retry_interval = 0
    , @os_run_priority = 0
    , @subsystem = N'TSQL'
    , @command = N' DELETE FROM [dbo].[history_blocked_process]
                    FROM (
                        SELECT
                            y.[EndTime]
                            , ROW_NUMBER() OVER (ORDER BY y.[EndTime] DESC) AS contador
                        FROM [history_blocked_process] AS y
                    ) AS x
                    WHERE x.[EndTime] = [history_blocked_process].[EndTime]
                    -- quantidade de dias de amostra
                    AND x.[EndTime] < DATEADD(DAY, -15, GETDATE())
                    -- quantidade mínima de dados de amostra
                    AND x.contador > 1000
                    GO'
    , @database_name = N'DBA_PerformanceHub'
    , @output_file_name = N'/var/opt/mssql/log_jobs/$(ESCAPE_SQUOTE(JOBNAME))_$(ESCAPE_SQUOTE(STEPID))_$(ESCAPE_SQUOTE(DATE))_$(ESCAPE_SQUOTE(TIME)).txt'
    , @flags = 0
IF (@@ERROR <> 0 OR @ReturnCode <> 0)
    GOTO QuitWithRollback

/****** Object:  Step [deadlocks xml cleanup] ******/
-- Step 2: retenção de 15 dias (mínimo de 1.000 registros preservados) em dbo.history_deadlock_xml_events
EXEC @ReturnCode = msdb.dbo.sp_add_jobstep
    @job_id = @jobId
    , @step_name = N'deadlocks xml cleanup'
    , @step_id = 2
    , @cmdexec_success_code = 0
    , @on_success_action = 3
    , @on_success_step_id = 0
    , @on_fail_action = 2
    , @on_fail_step_id = 0
    , @retry_attempts = 0
    , @retry_interval = 0
    , @os_run_priority = 0
    , @subsystem = N'TSQL'
    , @command = N' DELETE FROM [dbo].[history_deadlock_xml_events]
                    FROM (
                        SELECT
                            y.[xeTimeStamp]
                            , ROW_NUMBER() OVER (ORDER BY y.[xeTimeStamp] DESC) AS contador
                        FROM [history_deadlock_xml_events] AS y
                    ) AS x
                    WHERE x.[xeTimeStamp] = [history_deadlock_xml_events].[xeTimeStamp]
                    -- quantidade de dias de amostra
                    AND x.[xeTimeStamp] < DATEADD(DAY, -15, GETDATE())
                    -- quantidade mínima de dados de amostra
                    AND x.contador > 1000
                    GO'
    , @database_name = N'DBA_PerformanceHub'
    , @output_file_name = N'/var/opt/mssql/log_jobs/$(ESCAPE_SQUOTE(JOBNAME))_$(ESCAPE_SQUOTE(STEPID))_$(ESCAPE_SQUOTE(DATE))_$(ESCAPE_SQUOTE(TIME)).txt'
    , @flags = 0
IF (@@ERROR <> 0 OR @ReturnCode <> 0)
    GOTO QuitWithRollback

/****** Object:  Step [deadlocks details cleanup] ******/
-- Step 3: retenção de 15 dias (mínimo de 1.000 registros preservados) em dbo.history_deadlocks_details
EXEC @ReturnCode = msdb.dbo.sp_add_jobstep
    @job_id = @jobId
    , @step_name = N'deadlocks details cleanup'
    , @step_id = 3
    , @cmdexec_success_code = 0
    , @on_success_action = 3
    , @on_success_step_id = 0
    , @on_fail_action = 2
    , @on_fail_step_id = 0
    , @retry_attempts = 0
    , @retry_interval = 0
    , @os_run_priority = 0
    , @subsystem = N'TSQL'
    , @command = N' DELETE FROM [dbo].[history_deadlocks_details]
                    FROM (
                        SELECT
                            y.[dt_event]
                            , ROW_NUMBER() OVER (ORDER BY y.[dt_event] DESC) AS contador
                        FROM [history_deadlocks_details] AS y
                    ) AS x
                    WHERE x.[dt_event] = [history_deadlocks_details].[dt_event]
                    -- quantidade de dias de amostra
                    AND x.[dt_event] < DATEADD(DAY, -15, GETDATE())
                    -- quantidade mínima de dados de amostra
                    AND x.contador > 1000
                    GO'
    , @database_name = N'DBA_PerformanceHub'
    , @output_file_name = N'/var/opt/mssql/log_jobs/$(ESCAPE_SQUOTE(JOBNAME))_$(ESCAPE_SQUOTE(STEPID))_$(ESCAPE_SQUOTE(DATE))_$(ESCAPE_SQUOTE(TIME)).txt'
    , @flags = 0
IF (@@ERROR <> 0 OR @ReturnCode <> 0)
    GOTO QuitWithRollback

/****** Object:  Step [slow query statement cleanup] ******/
-- Step 4: retenção de 15 dias (mínimo de 1.000 registros preservados) em dbo.history_slow_query_statement e remove os registros do host OPTIMUS-PRIME
EXEC @ReturnCode = msdb.dbo.sp_add_jobstep
    @job_id = @jobId
    , @step_name = N'slow query statement cleanup'
    , @step_id = 4
    , @cmdexec_success_code = 0
    , @on_success_action = 3
    , @on_success_step_id = 0
    , @on_fail_action = 2
    , @on_fail_step_id = 0
    , @retry_attempts = 0
    , @retry_interval = 0
    , @os_run_priority = 0
    , @subsystem = N'TSQL'
    , @command = N' DELETE FROM [dbo].[history_slow_query_statement]
                    FROM (
                        SELECT
                            y.[Dt_Evento]
                            , ROW_NUMBER() OVER (ORDER BY y.[Dt_Evento] DESC) AS contador
                        FROM [history_slow_query_statement] AS y
                    ) AS x
                    WHERE x.[Dt_Evento] = [history_slow_query_statement].[Dt_Evento]
                    -- quantidade de dias de amostra
                    AND x.[Dt_Evento] < DATEADD(DAY, -15, GETDATE())
                    -- quantidade mínima de dados de amostra
                    AND x.contador > 1000
                    GO

                    DELETE FROM [dbo].[history_slow_query_statement]
                    WHERE [client_hostname] = ''OPTIMUS-PRIME''
                    GO'
    , @database_name = N'DBA_PerformanceHub'
    , @output_file_name = N'/var/opt/mssql/log_jobs/$(ESCAPE_SQUOTE(JOBNAME))_$(ESCAPE_SQUOTE(STEPID))_$(ESCAPE_SQUOTE(DATE))_$(ESCAPE_SQUOTE(TIME)).txt'
    , @flags = 0
IF (@@ERROR <> 0 OR @ReturnCode <> 0)
    GOTO QuitWithRollback

/****** Object:  Step [slow query batch rpc cleanup] ******/
-- Step 5: retenção de 15 dias (mínimo de 1.000 registros preservados) em dbo.history_slow_query_batch_rpc e remove os registros do host OPTIMUS-PRIME
EXEC @ReturnCode = msdb.dbo.sp_add_jobstep
    @job_id = @jobId
    , @step_name = N'slow query batch rpc cleanup'
    , @step_id = 5
    , @cmdexec_success_code = 0
    , @on_success_action = 3
    , @on_success_step_id = 0
    , @on_fail_action = 2
    , @on_fail_step_id = 0
    , @retry_attempts = 0
    , @retry_interval = 0
    , @os_run_priority = 0
    , @subsystem = N'TSQL'
    , @command = N' DELETE FROM [dbo].[history_slow_query_batch_rpc]
                    FROM (
                        SELECT
                            y.[Dt_Evento]
                            , ROW_NUMBER() OVER (ORDER BY y.[Dt_Evento] DESC) AS contador
                        FROM [history_slow_query_batch_rpc] AS y
                    ) AS x
                    WHERE x.[Dt_Evento] = [history_slow_query_batch_rpc].[Dt_Evento]
                    -- quantidade de dias de amostra
                    AND x.[Dt_Evento] < DATEADD(DAY, -15, GETDATE())
                    -- quantidade mínima de dados de amostra
                    AND x.contador > 1000
                    GO


                    DELETE FROM [dbo].[history_slow_query_batch_rpc]
                    WHERE [client_hostname] = ''OPTIMUS-PRIME''
                    GO'
    , @database_name = N'DBA_PerformanceHub'
    , @output_file_name = N'/var/opt/mssql/log_jobs/$(ESCAPE_SQUOTE(JOBNAME))_$(ESCAPE_SQUOTE(STEPID))_$(ESCAPE_SQUOTE(DATE))_$(ESCAPE_SQUOTE(TIME)).txt'
    , @flags = 0
IF (@@ERROR <> 0 OR @ReturnCode <> 0)
    GOTO QuitWithRollback

/****** Object:  Step [system error cleanup] ******/
-- Step 6: retenção de 15 dias (mínimo de 1.000 registros preservados) em dbo.history_database_error
EXEC @ReturnCode = msdb.dbo.sp_add_jobstep
    @job_id = @jobId
    , @step_name = N'system error cleanup'
    , @step_id = 6
    , @cmdexec_success_code = 0
    , @on_success_action = 3
    , @on_success_step_id = 0
    , @on_fail_action = 2
    , @on_fail_step_id = 0
    , @retry_attempts = 0
    , @retry_interval = 0
    , @os_run_priority = 0
    , @subsystem = N'TSQL'
    , @command = N' DELETE FROM [dbo].[history_database_error]
                    FROM (
                        SELECT
                            y.[Dt_Evento]
                            , ROW_NUMBER() OVER (ORDER BY y.[Dt_Evento] DESC) AS contador
                        FROM [history_database_error] AS y
                    ) AS x
                    WHERE x.[Dt_Evento] = [history_database_error].[Dt_Evento]
                    -- quantidade de dias de amostra
                    AND x.[Dt_Evento] < DATEADD(DAY, -15, GETDATE())
                    -- quantidade mínima de dados de amostra
                    AND x.contador > 1000
                    GO'
    , @database_name = N'DBA_PerformanceHub'
    , @output_file_name = N'/var/opt/mssql/log_jobs/$(ESCAPE_SQUOTE(JOBNAME))_$(ESCAPE_SQUOTE(STEPID))_$(ESCAPE_SQUOTE(DATE))_$(ESCAPE_SQUOTE(TIME)).txt'
    , @flags = 0
IF (@@ERROR <> 0 OR @ReturnCode <> 0)
    GOTO QuitWithRollback

/****** Object:  Step [dark queries recompile cleanup] ******/
-- Step 7: retenção de 15 dias (mínimo de 1.000 registros preservados) em dbo.history_dark_queries_recompile e remove os registros do host OPTIMUS-PRIME
EXEC @ReturnCode = msdb.dbo.sp_add_jobstep
    @job_id = @jobId
    , @step_name = N'dark queries recompile cleanup'
    , @step_id = 7
    , @cmdexec_success_code = 0
    , @on_success_action = 3
    , @on_success_step_id = 0
    , @on_fail_action = 2
    , @on_fail_step_id = 0
    , @retry_attempts = 0
    , @retry_interval = 0
    , @os_run_priority = 0
    , @subsystem = N'TSQL'
    , @command = N' DELETE FROM [dbo].[history_dark_queries_recompile]
                    FROM (
                        SELECT
                            y.[Dt_Evento]
                            , ROW_NUMBER() OVER (ORDER BY y.[Dt_Evento] DESC) AS contador
                        FROM [history_dark_queries_recompile] AS y
                    ) AS x
                    WHERE x.[Dt_Evento] = [history_dark_queries_recompile].[Dt_Evento]
                    -- quantidade de dias de amostra
                    AND x.[Dt_Evento] < DATEADD(DAY, -15, GETDATE())
                    -- quantidade mínima de dados de amostra
                    AND x.contador > 1000
                    GO

                    DELETE FROM [dbo].[history_dark_queries_recompile]
                    WHERE [client_hostname] = ''OPTIMUS-PRIME''
                    GO'
    , @database_name = N'DBA_PerformanceHub'
    , @output_file_name = N'/var/opt/mssql/log_jobs/$(ESCAPE_SQUOTE(JOBNAME))_$(ESCAPE_SQUOTE(STEPID))_$(ESCAPE_SQUOTE(DATE))_$(ESCAPE_SQUOTE(TIME)).txt'
    , @flags = 0
IF (@@ERROR <> 0 OR @ReturnCode <> 0)
    GOTO QuitWithRollback

/****** Object:  Step [sessions timeout cleanup] ******/
-- Step 8: retenção de 15 dias (mínimo de 1.000 registros preservados) em dbo.history_timeout
EXEC @ReturnCode = msdb.dbo.sp_add_jobstep
    @job_id = @jobId
    , @step_name = N'sessions timeout cleanup'
    , @step_id = 8
    , @cmdexec_success_code = 0
    , @on_success_action = 3
    , @on_success_step_id = 0
    , @on_fail_action = 2
    , @on_fail_step_id = 0
    , @retry_attempts = 0
    , @retry_interval = 0
    , @os_run_priority = 0
    , @subsystem = N'TSQL'
    , @command = N' DELETE FROM [dbo].[history_timeout]
                    FROM (
                        SELECT
                            y.[Dt_Evento]
                            , ROW_NUMBER() OVER (ORDER BY y.[Dt_Evento] DESC) AS contador
                        FROM [history_timeout] AS y
                    ) AS x
                    WHERE x.[Dt_Evento] = [history_timeout].[Dt_Evento]
                    -- quantidade de dias de amostra
                    AND x.[Dt_Evento] < DATEADD(DAY, -15, GETDATE())
                    -- quantidade mínima de dados de amostra
                    AND x.contador > 1000
                    GO'
    , @database_name = N'DBA_PerformanceHub'
    , @output_file_name = N'/var/opt/mssql/log_jobs/$(ESCAPE_SQUOTE(JOBNAME))_$(ESCAPE_SQUOTE(STEPID))_$(ESCAPE_SQUOTE(DATE))_$(ESCAPE_SQUOTE(TIME)).txt'
    , @flags = 0
IF (@@ERROR <> 0 OR @ReturnCode <> 0)
    GOTO QuitWithRollback

/****** Object:  Step [wait info cleanup] ******/
-- Step 9: retenção de 15 dias (mínimo de 1.000 registros preservados) em dbo.history_query_stats, dbo.history_wait_info_xevents, dbo.history_waits
EXEC @ReturnCode = msdb.dbo.sp_add_jobstep
    @job_id = @jobId
    , @step_name = N'wait info cleanup'
    , @step_id = 9
    , @cmdexec_success_code = 0
    , @on_success_action = 3
    , @on_success_step_id = 0
    , @on_fail_action = 2
    , @on_fail_step_id = 0
    , @retry_attempts = 0
    , @retry_interval = 0
    , @os_run_priority = 0
    , @subsystem = N'TSQL'
    , @command = N' DELETE FROM [dbo].[history_query_stats]
                    FROM (
                        SELECT
                            y.[event_time]
                            , ROW_NUMBER() OVER (ORDER BY y.[event_time] DESC) AS contador
                        FROM [history_query_stats] AS y
                    ) AS x
                    WHERE x.[event_time] = [history_query_stats].[event_time]
                    -- quantidade de dias de amostra
                    AND x.[event_time] < DATEADD(DAY, -15, GETDATE())
                    -- quantidade mínima de dados de amostra
                    AND x.contador > 1000
                    GO

                    DELETE FROM [dbo].[history_wait_info_xevents]
                    FROM (
                        SELECT
                            y.[event_time]
                            , ROW_NUMBER() OVER (ORDER BY y.[event_time] DESC) AS contador
                        FROM [history_wait_info_xevents] AS y
                    ) AS x
                    WHERE x.[event_time] = [history_wait_info_xevents].[event_time]
                    -- quantidade de dias de amostra
                    AND x.[event_time] < DATEADD(DAY, -15, GETDATE())
                    -- quantidade mínima de dados de amostra
                    AND x.contador > 1000
                    GO

                    DELETE FROM [dbo].[history_waits]
                    FROM (
                        SELECT
                            y.[event_time]
                            , ROW_NUMBER() OVER (ORDER BY y.[event_time] DESC) AS contador
                        FROM [history_waits] AS y
                    ) AS x
                    WHERE x.[event_time] = [history_waits].[event_time]
                    -- quantidade de dias de amostra
                    AND x.[event_time] < DATEADD(DAY, -15, GETDATE())
                    -- quantidade mínima de dados de amostra
                    AND x.contador > 1000
                    GO'
    , @database_name = N'DBA_PerformanceHub'
    , @output_file_name = N'/var/opt/mssql/log_jobs/$(ESCAPE_SQUOTE(JOBNAME))_$(ESCAPE_SQUOTE(STEPID))_$(ESCAPE_SQUOTE(DATE))_$(ESCAPE_SQUOTE(TIME)).txt'
    , @flags = 0
IF (@@ERROR <> 0 OR @ReturnCode <> 0)
    GOTO QuitWithRollback

/****** Object:  Step [page splits doc cleanup] ******/
-- Step 10: retenção de 15 dias (mínimo de 1.000 registros preservados) em dbo.index_defrag_page_splits_doc
EXEC @ReturnCode = msdb.dbo.sp_add_jobstep
    @job_id = @jobId
    , @step_name = N'page splits doc cleanup'
    , @step_id = 10
    , @cmdexec_success_code = 0
    , @on_success_action = 3
    , @on_success_step_id = 0
    , @on_fail_action = 2
    , @on_fail_step_id = 0
    , @retry_attempts = 0
    , @retry_interval = 0
    , @os_run_priority = 0
    , @subsystem = N'TSQL'
    , @command = N' DELETE FROM [dbo].[index_defrag_page_splits_doc]
                    FROM (
                        SELECT
                            y.[timestamp_xe]
                            , ROW_NUMBER() OVER (ORDER BY y.[timestamp_xe] DESC) AS contador
                        FROM [index_defrag_page_splits_doc] AS y
                    ) AS x
                    WHERE x.[timestamp_xe] = [index_defrag_page_splits_doc].[timestamp_xe]
                    -- quantidade de dias de amostra
                    AND x.[timestamp_xe] < DATEADD(DAY, -15, GETDATE())
                    -- quantidade mínima de dados de amostra
                    AND x.contador > 1000
                    GO'
    , @database_name = N'DBA_PerformanceHub'
    , @output_file_name = N'/var/opt/mssql/log_jobs/$(ESCAPE_SQUOTE(JOBNAME))_$(ESCAPE_SQUOTE(STEPID))_$(ESCAPE_SQUOTE(DATE))_$(ESCAPE_SQUOTE(TIME)).txt'
    , @flags = 0
IF (@@ERROR <> 0 OR @ReturnCode <> 0)
    GOTO QuitWithRollback

/****** Object:  Step [plan affecting convert] ******/
-- Step 11: retenção de 15 dias (mínimo de 1.000 registros preservados) em dbo.history_plan_affecting_convert
EXEC @ReturnCode = msdb.dbo.sp_add_jobstep
    @job_id = @jobId
    , @step_name = N'plan affecting convert'
    , @step_id = 11
    , @cmdexec_success_code = 0
    , @on_success_action = 3
    , @on_success_step_id = 0
    , @on_fail_action = 2
    , @on_fail_step_id = 0
    , @retry_attempts = 0
    , @retry_interval = 0
    , @os_run_priority = 0
    , @subsystem = N'TSQL'
    , @command = N' DELETE FROM [dbo].[history_plan_affecting_convert]
                    FROM (
                        SELECT
                            y.[timestamp_xe]
                            , ROW_NUMBER() OVER (ORDER BY y.[timestamp_xe] DESC) AS contador
                        FROM [history_plan_affecting_convert] AS y
                    ) AS x
                    WHERE x.[timestamp_xe] = [history_plan_affecting_convert].[timestamp_xe]
                    -- quantidade de dias de amostra
                    AND x.[timestamp_xe] < DATEADD(DAY, -15, GETDATE())
                    -- quantidade mínima de dados de amostra
                    AND x.contador > 1000
                    GO'
    , @database_name = N'DBA_PerformanceHub'
    , @output_file_name = N'/var/opt/mssql/log_jobs/$(ESCAPE_SQUOTE(JOBNAME))_$(ESCAPE_SQUOTE(STEPID))_$(ESCAPE_SQUOTE(DATE))_$(ESCAPE_SQUOTE(TIME)).txt'
    , @flags = 0
IF (@@ERROR <> 0 OR @ReturnCode <> 0)
    GOTO QuitWithRollback

/****** Object:  Step [sort warning] ******/
-- Step 12: retenção de 15 dias (mínimo de 1.000 registros preservados) em dbo.history_sort_warning_performance
EXEC @ReturnCode = msdb.dbo.sp_add_jobstep
    @job_id = @jobId
    , @step_name = N'sort warning'
    , @step_id = 12
    , @cmdexec_success_code = 0
    , @on_success_action = 3
    , @on_success_step_id = 0
    , @on_fail_action = 2
    , @on_fail_step_id = 0
    , @retry_attempts = 0
    , @retry_interval = 0
    , @os_run_priority = 0
    , @subsystem = N'TSQL'
    , @command = N' DELETE FROM [dbo].[history_sort_warning_performance]
                    FROM (
                        SELECT
                            y.[timestamp_xe]
                            , ROW_NUMBER() OVER (ORDER BY y.[timestamp_xe] DESC) AS contador
                        FROM [history_sort_warning_performance] AS y
                    ) AS x
                    WHERE x.[timestamp_xe] = [history_sort_warning_performance].[timestamp_xe]
                    -- quantidade de dias de amostra
                    AND x.[timestamp_xe] < DATEADD(DAY, -15, GETDATE())
                    -- quantidade mínima de dados de amostra
                    AND x.contador > 1000
                    GO'
    , @database_name = N'DBA_PerformanceHub'
    , @output_file_name = N'/var/opt/mssql/log_jobs/$(ESCAPE_SQUOTE(JOBNAME))_$(ESCAPE_SQUOTE(STEPID))_$(ESCAPE_SQUOTE(DATE))_$(ESCAPE_SQUOTE(TIME)).txt'
    , @flags = 0
IF (@@ERROR <> 0 OR @ReturnCode <> 0)
    GOTO QuitWithRollback

/****** Object:  Step [ddl statement] ******/
-- Step 13: retenção de 120 dias (mínimo de 1.000.000 registros preservados) em dbo.history_ddl_statement
EXEC @ReturnCode = msdb.dbo.sp_add_jobstep
    @job_id = @jobId
    , @step_name = N'ddl statement'
    , @step_id = 13
    , @cmdexec_success_code = 0
    , @on_success_action = 1
    , @on_success_step_id = 0
    , @on_fail_action = 2
    , @on_fail_step_id = 0
    , @retry_attempts = 0
    , @retry_interval = 0
    , @os_run_priority = 0
    , @subsystem = N'TSQL'
    , @command = N' DELETE FROM [dbo].[history_ddl_statement]
                    FROM (
                        SELECT
                            y.[timestamp_xe]
                            , ROW_NUMBER() OVER (ORDER BY y.[timestamp_xe] DESC) AS contador
                        FROM [history_ddl_statement] AS y
                    ) AS x
                    WHERE x.[timestamp_xe] = [history_ddl_statement].[timestamp_xe]
                    -- quantidade de dias de amostra
                    AND x.[timestamp_xe] < DATEADD(DAY, -120, GETDATE())
                    -- quantidade mínima de dados de amostra
                    AND x.contador > 1000000
                    GO'
    , @database_name = N'DBA_PerformanceHub'
    , @output_file_name = N'/var/opt/mssql/log_jobs/$(ESCAPE_SQUOTE(JOBNAME))_$(ESCAPE_SQUOTE(STEPID))_$(ESCAPE_SQUOTE(DATE))_$(ESCAPE_SQUOTE(TIME)).txt'
    , @flags = 0
IF (@@ERROR <> 0 OR @ReturnCode <> 0)
    GOTO QuitWithRollback

-- Define o step 1 como passo inicial do job
EXEC @ReturnCode = msdb.dbo.sp_update_job
    @job_id = @jobId
    , @start_step_id = 1
IF (@@ERROR <> 0 OR @ReturnCode <> 0)
    GOTO QuitWithRollback

-- Agendamento: a cada 2 semanas, aos domingos às 07:00
EXEC @ReturnCode = msdb.dbo.sp_add_jobschedule
    @job_id = @jobId
    , @name = N'Occurs every 2 week(s) on Sunday at 07:00:00'
    , @enabled = 1
    , @freq_type = 8
    , @freq_interval = 1
    , @freq_subday_type = 1
    , @freq_subday_interval = 0
    , @freq_relative_interval = 1
    , @freq_recurrence_factor = 2
    , @active_start_date = 20230823
    , @active_end_date = 99991231
    , @active_start_time = 70000
    , @active_end_time = 235959
    , @schedule_uid = N'4e0801ba-8f56-4ffa-b8f7-235d19c4da25'
IF (@@ERROR <> 0 OR @ReturnCode <> 0)
    GOTO QuitWithRollback

-- Associa o job ao servidor local
EXEC @ReturnCode = msdb.dbo.sp_add_jobserver
    @job_id = @jobId
    , @server_name = N'(local)'
IF (@@ERROR <> 0 OR @ReturnCode <> 0)
    GOTO QuitWithRollback

COMMIT TRANSACTION
GOTO EndSave

-- Tratamento de falha: desfaz a transação aberta
QuitWithRollback:
    IF (@@TRANCOUNT > 0)
        ROLLBACK TRANSACTION
EndSave:
GO
