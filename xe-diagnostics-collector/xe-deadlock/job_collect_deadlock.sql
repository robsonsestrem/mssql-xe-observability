/*
 *
    OBJETIVO: Criação de Job no SQL Server Agent para coleta periódica de deadlocks
              via Extended Events, executando as procedures
              sp_gather_deadlock_events e sp_load_deadlocks a cada 1 hora.

    PROJETO: mssql-xe-observability

    AUTHOR: Robson Sestrem

    REFERÊNCIAS DE URL:
 *  Documentação oficial: sp_add_job, sp_add_jobstep, sp_add_jobschedule, sp_add_jobserver
 */
-- ============================================================
-- Job: DBA - Collect_Deadlocks
-- ============================================================
USE [msdb]
GO

BEGIN TRANSACTION

DECLARE @ReturnCode INT
SELECT @ReturnCode = 0

-- ============================================================
-- Criação da categoria do Job (Data Collector) se não existir
-- ============================================================
IF NOT EXISTS (SELECT name FROM msdb.dbo.syscategories WHERE name = N'Data Collector' AND category_class = 1)
BEGIN
    EXEC @ReturnCode = msdb.dbo.sp_add_category
        @class = N'JOB'
      , @type = N'LOCAL'
      , @name = N'Data Collector'

    IF (@@ERROR <> 0 OR @ReturnCode <> 0)
        GOTO QuitWithRollback
END

-- ============================================================
-- Criação do Job
-- ============================================================
DECLARE @jobId BINARY(16)

EXEC @ReturnCode = msdb.dbo.sp_add_job
    @job_name                = N'DBA - Collect_Deadlocks'
  , @enabled                 = 1
  , @notify_level_eventlog   = 2
  , @notify_level_email      = 0
  , @notify_level_netsend    = 0
  , @notify_level_page       = 0
  , @delete_level            = 0
  , @description             = N'Coleta para histórico detalhado de deadlocks incluindo gráfico xml armazenado separadamente.'
  , @category_name           = N'Data Collector'
  , @owner_login_name        = N'sa'
  , @job_id                  = @jobId OUTPUT

IF (@@ERROR <> 0 OR @ReturnCode <> 0)
    GOTO QuitWithRollback

-- ============================================================
-- Step 01: Executa a procedure sp_gather_deadlock_events
-- ============================================================
EXEC @ReturnCode = msdb.dbo.sp_add_jobstep
    @job_id                 = @jobId
  , @step_name              = N'Execute sp_gather_deadlock_events'
  , @step_id                = 1
  , @cmdexec_success_code   = 0
  , @on_success_action      = 3
  , @on_success_step_id     = 0
  , @on_fail_action         = 2
  , @on_fail_step_id        = 0
  , @retry_attempts         = 0
  , @retry_interval         = 0
  , @os_run_priority        = 0
  , @subsystem              = N'TSQL'
  , @command                = N'EXECUTE dbo.sp_gather_deadlock_events;'
  , @database_name          = N'DBA_PerformanceHub'
  , @flags                  = 0

IF (@@ERROR <> 0 OR @ReturnCode <> 0)
    GOTO QuitWithRollback

-- ============================================================
-- Step 02: Executa a procedure sp_load_deadlocks
-- ============================================================
EXEC @ReturnCode = msdb.dbo.sp_add_jobstep
    @job_id                 = @jobId
  , @step_name              = N'execute sp_load_deadlocks'
  , @step_id                = 2
  , @cmdexec_success_code   = 0
  , @on_success_action      = 1
  , @on_success_step_id     = 0
  , @on_fail_action         = 2
  , @on_fail_step_id        = 0
  , @retry_attempts         = 0
  , @retry_interval         = 0
  , @os_run_priority        = 0
  , @subsystem              = N'TSQL'
  , @command                = N'EXECUTE dbo.sp_load_deadlocks;'
  , @database_name          = N'DBA_PerformanceHub'
  , @flags                  = 0

IF (@@ERROR <> 0 OR @ReturnCode <> 0)
    GOTO QuitWithRollback

-- ============================================================
-- Define o step inicial do Job
-- ============================================================
EXEC @ReturnCode = msdb.dbo.sp_update_job
    @job_id         = @jobId
  , @start_step_id  = 1

IF (@@ERROR <> 0 OR @ReturnCode <> 0)
    GOTO QuitWithRollback

-- ============================================================
-- Agendamento: executa a cada 1 hora, todos os dias
-- ============================================================
EXEC @ReturnCode = msdb.dbo.sp_add_jobschedule
    @job_id                     = @jobId
  , @name                       = N'Occurs every day every 1 hour(s)'
  , @enabled                    = 1
  , @freq_type                  = 4
  , @freq_interval              = 1
  , @freq_subday_type           = 8
  , @freq_subday_interval       = 1
  , @freq_relative_interval     = 0
  , @freq_recurrence_factor     = 0
  , @active_start_date          = 20240301
  , @active_end_date            = 99991231
  , @active_start_time          = 0
  , @active_end_time            = 235959
  , @schedule_uid               = N'82b37963-de6d-4ddd-9774-d40fb2dca0eb'

IF (@@ERROR <> 0 OR @ReturnCode <> 0)
    GOTO QuitWithRollback

-- ============================================================
-- Vincula o Job ao servidor local
-- ============================================================
EXEC @ReturnCode = msdb.dbo.sp_add_jobserver
    @job_id       = @jobId
  , @server_name  = N'(local)'

IF (@@ERROR <> 0 OR @ReturnCode <> 0)
    GOTO QuitWithRollback

COMMIT TRANSACTION
GOTO EndSave

QuitWithRollback:
    IF (@@TRANCOUNT > 0)
        ROLLBACK TRANSACTION

EndSave:
GO
