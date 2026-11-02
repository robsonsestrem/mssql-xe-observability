/*
 *
    OBJETIVO: Script de análise de relatórios de processos bloqueados coletados via
              Extended Events (blocked_process_report), incluindo visualização
              via procedure dedicada, decodificação de sql_handle, contagem de
              eventos por dia e por hora, com filtros de manutenção.

    PROJETO: mssql-xe-observability

    AUTHOR: Robson Sestrem   

    REFERÊNCIAS DE URL:
 *  https://michaeljswart.com/2016/02/look-at-blocked-process-reports-collected-with-extended-events/
 */
-- ============================================================
-- Visualização dos relatórios de processos bloqueados
-- ============================================================
EXEC DBA_PerformanceHub.dbo.sp_blocked_process_report_viewer 'history_blocked_process', 'TABLE'
GO

-- ============================================================
-- Teste de conversão de sql_handle 
-- a partir de string hexadecimal
-- ============================================================
DECLARE @teste VARCHAR(100) = REPLACE('02 00 00 00 6C 0B E8 0C 9B 8C 49 77 80 48 5E 09 ED 84 77 8B 74 E0 D6 59 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00', ' ', '')

SELECT @teste

-- Substituir o valor abaixo pelo sql_handle real do evento analisado
SELECT *
FROM sys.dm_exec_sql_text(0x020000006C0BE80C9B8C497780485E09ED84778B74E0D6590000000000000000000000000000000000000000)

SELECT OBJECT_NAME('850102069')  -- 850102069; 549629051
GO

-- ============================================================
-- Contagem de eventos por dia
-- ============================================================
USE DBA_PerformanceHub
GO

SELECT
      CAST(hbp.EndTime AS DATE) AS data_evento
    , COUNT(1) AS qtd_evntos
FROM history_blocked_process hbp
GROUP BY CAST(hbp.EndTime AS DATE)
ORDER BY CAST(hbp.EndTime AS DATE)
GO

-- ============================================================
-- Contagem de eventos por dia com filtros de manutenção
-- (exclui eventos do próprio DBA_PerformanceHub)
-- ============================================================
SELECT
      CAST(EndTime AS DATE) AS data_evento
    , COUNT(1) AS qtd_evntos
FROM history_blocked_process
    CROSS APPLY
    (
        SELECT CAST(TextData AS XML)
    ) AS bpReports (bpReportXml)
    CROSS APPLY
    (
        SELECT
              monitorloop       = bpReportXml.value('(//@monitorLoop)[1]', 'nvarchar(100)')
            , blocked_spid      = bpReportXml.value('(/blocked-process-report/blocked-process/process/@spid)[1]', 'int')
            , blocking_spid     = bpReportXml.value('(/blocked-process-report/blocking-process/process/@spid)[1]', 'int')
            , [database_name]   = DB_NAME(bpReportXml.value('(/blocked-process-report/blocked-process/process/@currentdb)[1]', 'varchar(20)'))
            , blocked_waittime_s = REPLACE((CAST(CAST(bpReportXml.value('(/blocked-process-report/blocked-process/process/@waittime)[1]', 'bigint') AS VARCHAR(60)) AS MONEY) / 1000), ',', '.')
            , [blocked_sql_text]  = bpReportXml.value('(/blocked-process-report/blocked-process/process/inputbuf)[1]', 'nvarchar(max)')
            , [blocking_sql_text] = bpReportXml.value('(/blocked-process-report/blocking-process/process/inputbuf)[1]', 'nvarchar(max)')
    ) AS bpShredded
WHERE blocking_spid IS NOT NULL
    AND blocked_spid IS NOT NULL
    AND bpShredded.[database_name] NOT LIKE '%DBA_PerformanceHub%'
    -- AND EndTime >= '2024-08-08' AND EndTime < '2024-08-09'
GROUP BY CAST(EndTime AS DATE)
ORDER BY CAST(EndTime AS DATE)
GO

-- ============================================================
-- Contagem de eventos por hora (identifica horários de maior
-- incidência de bloqueios)
-- ============================================================
SELECT
      DATEPART(HOUR, hbp.EndTime) AS hora
    , COUNT(*) AS qtd_evntos
FROM history_blocked_process hbp
GROUP BY DATEPART(HOUR, hbp.EndTime)
ORDER BY DATEPART(HOUR, hbp.EndTime)
GO
