/*
 *
    OBJETIVO: Criação de SQL Agent Job para coleta das principais rotinas DDL da instância,
              executando a procedure sp_load_ddl_statement no banco DBA_PerformanceHub.
    PROJETO: mssql-xe-observability

    REFERÊNCIAS DE URL:
 *  https://learn.microsoft.com/pt-br/sql/relational-databases/system-stored-procedures/sp-add-job-transact-sql
 *  https://learn.microsoft.com/pt-br/sql/relational-databases/system-stored-procedures/sp-add-jobschedule-transact-sql
 */
USE [msdb]
GO

-- ============================================================
-- Início da transação de criação do job
-- ============================================================
BEGIN TRANSACTION

DECLARE @ReturnCode INT

SELECT @ReturnCode = 0

-- ============================================================
-- Categoria do job: Data Collector
-- ============================================================
IF NOT EXISTS
(
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

-- ============================================================
-- Criação do job DBA - Collect_DDL_Statement
-- ============================================================
DECLARE @jobId BINARY(16)

EXEC @ReturnCode = msdb.dbo.sp_add_job
    @job_name = N'DBA - Collect_DDL_Statement'
  , @enabled = 1
  , @notify_level_eventlog = 0
  , @notify_level_email = 0
  , @notify_level_netsend = 0
  , @notify_level_page = 0
  , @delete_level = 0
  , @description = N'Coleta principais rotinas de ddl da instância.'
  , @category_name = N'Data Collector'
  , @owner_login_name = N'sa'
  , @job_id = @jobId OUTPUT

IF (@@ERROR <> 0 OR @ReturnCode <> 0)
    GOTO QuitWithRollback

-- ============================================================
-- Step: execute sp_load_ddl_statement
-- ============================================================
EXEC @ReturnCode = msdb.dbo.sp_add_jobstep
    @job_id = @jobId
  , @step_name = N'execute sp_load_ddl_statement'
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
  , @command = N'EXECUTE [dbo].[sp_load_ddl_statement];'
  , @database_name = N'DBA_PerformanceHub'
  , @flags = 0

IF (@@ERROR <> 0 OR @ReturnCode <> 0)
    GOTO QuitWithRollback

-- ============================================================
-- Atualização do step inicial do job
-- ============================================================
EXEC @ReturnCode = msdb.dbo.sp_update_job
    @job_id = @jobId
  , @start_step_id = 1

IF (@@ERROR <> 0 OR @ReturnCode <> 0)
    GOTO QuitWithRollback

-- ============================================================
-- Agenda: ocorre todos os dias a cada 6 horas
-- ============================================================
EXEC @ReturnCode = msdb.dbo.sp_add_jobschedule
    @job_id = @jobId
  , @name = N'Occurs every day every 6 hour(s)'
  , @enabled = 1
  , @freq_type = 4
  , @freq_interval = 1
  , @freq_subday_type = 8
  , @freq_subday_interval = 6
  , @freq_relative_interval = 0
  , @freq_recurrence_factor = 0
  , @active_start_date = 20240715
  , @active_end_date = 99991231
  , @active_start_time = 0
  , @active_end_time = 235959
  , @schedule_uid = N'1ae9a8b7-abc8-4b45-94d4-fdf22b2ce812'

IF (@@ERROR <> 0 OR @ReturnCode <> 0)
    GOTO QuitWithRollback

-- ============================================================
-- Associação do job ao servidor local
-- ============================================================
EXEC @ReturnCode = msdb.dbo.sp_add_jobserver
    @job_id = @jobId
  , @server_name = N'(local)'

IF (@@ERROR <> 0 OR @ReturnCode <> 0)
    GOTO QuitWithRollback

COMMIT TRANSACTION

GOTO EndSave

QuitWithRollback:
IF (@@TRANCOUNT > 0)
    ROLLBACK TRANSACTION

EndSave:
GO
