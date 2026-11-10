/*
 *
    OBJETIVO: Criar o job do SQL Server Agent "DBA - Purge_Job_History", que aplica a retenção dos dados de execução
              dos jobs do SQL Server por meio da procedure sp_purge_jobhistory, removendo do msdb o histórico com mais
              de 7 dias. O job executa semanalmente, aos sábados às 04:00.

    PROJETO: mssql-xe-observability

    AUTHOR: Robson Sestrem
 *
 */
USE [msdb]
GO

/****** Object:  Job [DBA - Purge_Job_History] ******/
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
    @job_name = N'DBA - Purge_Job_History'
    , @enabled = 1
    , @notify_level_eventlog = 2
    , @notify_level_email = 0
    , @notify_level_netsend = 0
    , @notify_level_page = 0
    , @delete_level = 0
    , @description = N'Retenção dos dados de execução de jobs do Sql Server.'
    , @category_name = N'Database Maintenance'
    , @owner_login_name = N'sa'
    , @job_id = @jobId OUTPUT
IF (@@ERROR <> 0 OR @ReturnCode <> 0)
    GOTO QuitWithRollback

/****** Object:  Step [Execute sp_purge_jobhistory] ******/
-- Step 1: remove do msdb o histórico de execução dos jobs com mais de 7 dias
EXEC @ReturnCode = msdb.dbo.sp_add_jobstep
    @job_id = @jobId
    , @step_name = N'Execute sp_purge_jobhistory'
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
    , @command = N'DECLARE @CleanupDate DATETIME
                   SET @CleanupDate = DATEADD(DD, -7, GETDATE())
                   EXECUTE dbo.sp_purge_jobhistory @oldest_date = @CleanupDate'
    , @database_name = N'msdb'
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

-- Agendamento: toda semana, aos sábados, às 04:00
EXEC @ReturnCode = msdb.dbo.sp_add_jobschedule
    @job_id = @jobId
    , @name = N'weekly'
    , @enabled = 1
    , @freq_type = 8
    , @freq_interval = 64
    , @freq_subday_type = 1
    , @freq_subday_interval = 0
    , @freq_relative_interval = 0
    , @freq_recurrence_factor = 1
    , @active_start_date = 20230728
    , @active_end_date = 99991231
    , @active_start_time = 40000
    , @active_end_time = 235959
    , @schedule_uid = N'aee45272-6a68-4364-89ef-3a31e7870a71'
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
