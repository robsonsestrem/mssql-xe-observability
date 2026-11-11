/*
 *
    OBJETIVO: Criação de Job no SQL Server Agent para coleta periódica de
              eventos de page splits via Extended Events, executando a
              procedure sp_load_index_defrag_insert_page_splits_YOUR_DATABASE
              a cada 2 horas para armazenamento de informações de índices
              fragmentados.
    
    PROJETO: mssql-xe-observability

    AUTHOR: Robson Sestrem

    REFERÊNCIAS DE URL:
 *  Documentação oficial: sp_add_job, sp_add_jobstep, sp_add_jobschedule, sp_add_jobserver
 */
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
    @job_name                = N'DBA - Collect_Page_Splits - YOUR_DATABASE'
  , @enabled                 = 1
  , @notify_level_eventlog   = 0
  , @notify_level_email      = 0
  , @notify_level_netsend    = 0
  , @notify_level_page       = 0
  , @delete_level            = 0
  , @description             = N'Coleta informações de índices fragmentados por eventos de page splits da base YOUR_DATABASE.'
  , @category_name           = N'Data Collector'
  , @owner_login_name        = N'sa'
  , @job_id                  = @jobId OUTPUT

IF (@@ERROR <> 0 OR @ReturnCode <> 0)
    GOTO QuitWithRollback

-- ============================================================
-- Step 01: Executa a procedure de carga dos page splits
-- ============================================================
EXEC @ReturnCode = msdb.dbo.sp_add_jobstep
    @job_id                 = @jobId
  , @step_name              = N'Execute sp_load_index_defrag_insert_page_splits_YOUR_DATABASE'
  , @step_id                = 1
  , @cmdexec_success_code   = 0
  , @on_success_action      = 1
  , @on_success_step_id     = 0
  , @on_fail_action         = 2
  , @on_fail_step_id        = 0
  , @retry_attempts         = 0
  , @retry_interval         = 0
  , @os_run_priority        = 0
  , @subsystem              = N'TSQL'
  , @command                = N'EXECUTE dbo.[sp_load_index_defrag_insert_page_splits_YOUR_DATABASE];'
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
-- Agendamento: executa a cada 2 horas, todos os dias
-- ============================================================
EXEC @ReturnCode = msdb.dbo.sp_add_jobschedule
    @job_id                     = @jobId
  , @name                       = N'Occurs every day - every 2 hours'
  , @enabled                    = 1
  , @freq_type                  = 4
  , @freq_interval              = 1
  , @freq_subday_type           = 8
  , @freq_subday_interval       = 2
  , @freq_relative_interval     = 0
  , @freq_recurrence_factor     = 0
  , @active_start_date          = 20240323
  , @active_end_date            = 99991231
  , @active_start_time          = 0
  , @active_end_time            = 235959
  , @schedule_uid               = N'834dd422-f713-4b29-8237-532c9a4e7400'

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
