/*
 *
    OBJETIVO: Criar o job do SQL Server Agent "DBA - Collect_Queries_Recompile", que executa de hora em hora
              a procedure dbo.sp_load_dark_queries_recompile para carregar no histórico as queries
              capturadas com recompilação pela sessão de Extended Events dark_queries_recompile.

    PROJETO: mssql-xe-observability

    AUTHOR: Robson Sestrem

    REFERÊNCIAS DE URL:
    poc-statement-recompile.sql (sessão XE, tabela de histórico e procedure executada por este job)
    https://michaeljswart.com/2017/04/finding-your-dark-queries/
 *
 */
USE [msdb]
GO

/****** Object:  Job [DBA - Collect_Queries_Recompile] ******/
-- Transação única: qualquer falha na criação do job desfaz todo o processo (ver QuitWithRollback)
BEGIN TRANSACTION
DECLARE @ReturnCode INT
SELECT @ReturnCode = 0

/****** Object:  JobCategory [Data Collector] ******/
-- Cria a categoria de job "Data Collector" caso ainda não exista
IF NOT EXISTS (
    SELECT name
    FROM msdb.dbo.syscategories
    WHERE name = N'Data Collector'
    AND category_class = 1
)
BEGIN
    EXEC @ReturnCode = msdb.dbo.sp_add_category
        @class = N'JOB'
        , @type = N'LOCAL'
        , @name = N'Data Collector'
    IF (@@ERROR <> 0 OR @ReturnCode <> 0)
        GOTO QuitWithRollback

END

-- Criação do job
DECLARE @jobId BINARY(16)
EXEC @ReturnCode = msdb.dbo.sp_add_job
    @job_name = N'DBA - Collect_Queries_Recompile'
    , @enabled = 1
    , @notify_level_eventlog = 0
    , @notify_level_email = 0
    , @notify_level_netsend = 0
    , @notify_level_page = 0
    , @delete_level = 0
    , @description = N'Carga de queries com recompilação.'
    , @category_name = N'Data Collector'
    , @owner_login_name = N'sa'
    , @job_id = @jobId OUTPUT
IF (@@ERROR <> 0 OR @ReturnCode <> 0)
    GOTO QuitWithRollback

/****** Object:  Step [Execute sp_load_dark_queries_recompile] ******/
-- Step 1: executa a procedure de carga no banco DBA_PerformanceHub
EXEC @ReturnCode = msdb.dbo.sp_add_jobstep
    @job_id = @jobId
    , @step_name = N'Execute sp_load_dark_queries_recompile'
    , @step_id = 1
    , @cmdexec_success_code = 0
    , @on_success_action = 1
    , @on_success_step_id = 0
    , @on_fail_action = 2
    , @on_fail_step_id = 0
    , @retry_attempts = 0
    , @retry_interval = 0
    , @os_run_priority = 0
    , @subsystem = N'TSQL'
    , @command = N'EXECUTE dbo.sp_load_dark_queries_recompile;'
    , @database_name = N'DBA_PerformanceHub'
    , @flags = 0
IF (@@ERROR <> 0 OR @ReturnCode <> 0)
    GOTO QuitWithRollback

-- Define o step 1 como passo inicial do job
EXEC @ReturnCode = msdb.dbo.sp_update_job
    @job_id = @jobId
    , @start_step_id = 1
IF (@@ERROR <> 0 OR @ReturnCode <> 0)
    GOTO QuitWithRollback

-- Agendamento: todos os dias, a cada 1 hora, 24h por dia
EXEC @ReturnCode = msdb.dbo.sp_add_jobschedule
    @job_id = @jobId
    , @name = N'Occurs every day every 1 hour'
    , @enabled = 1
    , @freq_type = 4
    , @freq_interval = 1
    , @freq_subday_type = 8
    , @freq_subday_interval = 1
    , @freq_relative_interval = 0
    , @freq_recurrence_factor = 0
    , @active_start_date = 20240301
    , @active_end_date = 99991231
    , @active_start_time = 0
    , @active_end_time = 235959
    , @schedule_uid = N'c6672abe-a810-4845-b0b3-c8b59af93674'
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
