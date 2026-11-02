/*
 *
    OBJETIVO: Análise detalhada de relatórios de processos bloqueados
              (blocked_process_report) coletados via Extended Events,
              incluindo extração de texto SQL, planos de execução (via
              dm_exec_requests e dm_exec_query_stats) tanto do processo
              bloqueado quanto do bloqueador.

    PROJETO: mssql-xe-observability

    AUTHOR: Robson Sestrem 

    REFERÊNCIAS DE URL:
 *  https://www.dataplatform.gr/en/pos-syllegoyme-blocking-queries-meso-extended-event-kai-pos-diav/
 *  https://www.brentozar.com/archive/2014/03/extended-events-doesnt-hard/
 *  https://www.sqlserverscience.com/troubleshooting/blocked-process-detection-and-analysis/
 */
SET XACT_ABORT, NOCOUNT ON
GO

SET DEADLOCK_PRIORITY 5
GO

SELECT
      hbp.EndTime
    , bpShredded.[Resource]
    , bpShredded.BlockedXactID
    , bpShredded.WaitTime_s
    , bpShredded.BlockedSPID
    , bpShredded.BlockedLoginName
    , bpShredded.BlockedClientAppName
    , bpShredded.BlockedClientHostName
    , bpShredded.BlockedLockMode
    , bpShredded.BlockedStatus
    , bpShredded.BlockedIsolationLevel
    , bpShredded.BlockedSQLHandle
    , bpShredded.BlockedStmtStart
    , bpShredded.BlockedStmtEnd

    -- Dados do processo bloqueador
    , bpShredded.BlockingSPID
    , bpShredded.BlockingLoginName
    , bpShredded.BlockingClientAppName
    , bpShredded.BlockingClientHostName
    , bpShredded.BlockingStatus
    , bpShredded.BlockingTranCount
    , bpShredded.BlockingSQLHandle
    , bpShredded.BlockingStmtStart
    , bpShredded.BlockingStmtEnd

    -- Texto da query bloqueada
    , SUBSTRING(
          BlockedSQLText.[Text]
        , (bpShredded.BlockedStmtStart / 2) + 1
        , ((
              CASE bpShredded.BlockedStmtEnd
                  WHEN -1 THEN DATALENGTH(BlockedSQLText.[text])
                  ELSE bpShredded.BlockedStmtEnd
              END - bpShredded.BlockedStmtStart) / 2) + 1
      ) AS BlockedSQL
    , bpShredded.BlockedInputBuf
    , COALESCE(blockedERPlan.query_plan, blockedQSPlan.query_plan) AS BlockedQueryPlan

    -- Texto da query bloqueadora
    , SUBSTRING(
          BlockingSQLText.[Text]
        , (bpShredded.BlockingStmtStart / 2) + 1
        , ((
              CASE bpShredded.BlockingStmtEnd
                  WHEN -1 THEN DATALENGTH(BlockingSQLText.[text])
                  ELSE bpShredded.BlockingStmtEnd
              END - bpShredded.BlockingStmtStart) / 2) + 1
      ) AS BlockingSQL
    , bpShredded.BlockingInputBuf
    , BlockingQSPlan.query_plan AS BlockingQueryPlan

FROM history_blocked_process AS hbp
    CROSS APPLY
    (
        SELECT CAST(hbp.TextData AS XML)
    ) AS bpReports (bpReportXml)
    CROSS APPLY
    (
        SELECT
              bpReportXml.value('/blocked-process-report[1]/blocked-process[1]/process[1]/@waitresource', 'varchar(64)') AS [Resource]

            -- Bloqueado
            , bpReportXml.value('/blocked-process-report[1]/blocked-process[1]/process[1]/@xactid', 'bigint') AS BlockedXactID
            , REPLACE((CAST(CAST(bpReportXml.value('/blocked-process-report[1]/blocked-process[1]/process[1]/@waittime', 'bigint') AS VARCHAR(60)) AS MONEY) / 1000), ',', '.') AS WaitTime_s
            , bpReportXml.value('/blocked-process-report[1]/blocked-process[1]/process[1]/@spid', 'smallint') AS BlockedSPID
            , bpReportXml.value('/blocked-process-report[1]/blocked-process[1]/process[1]/@loginname', 'nvarchar(128)') AS [BlockedLoginName]
            , bpReportXml.value('/blocked-process-report[1]/blocked-process[1]/process[1]/@clientapp', 'nvarchar(128)') AS [BlockedClientAppName]
            , bpReportXml.value('/blocked-process-report[1]/blocked-process[1]/process[1]/@hostname', 'nvarchar(128)') AS [BlockedClientHostName]
            , bpReportXml.value('/blocked-process-report[1]/blocked-process[1]/process[1]/@lockMode', 'varchar(16)') AS BlockedLockMode
            , bpReportXml.value('/blocked-process-report[1]/blocked-process[1]/process[1]/@status', 'varchar(16)') AS BlockedStatus
            , bpReportXml.value('/blocked-process-report[1]/blocked-process[1]/process[1]/@isolationlevel', 'varchar(32)') AS BlockedIsolationLevel
            , bpReportXml.value('xs:hexBinary(substring((/blocked-process-report[1]/blocked-process[1]/process[1]/executionStack[1]/frame[1]/@sqlhandle)[1],3))', 'varbinary(max)') AS BlockedSQLHandle
            , ISNULL(bpReportXml.value('/blocked-process-report[1]/blocked-process[1]/process[1]/executionStack[1]/frame[1]/@stmtstart', 'int'), 0) AS BlockedStmtStart
            , ISNULL(bpReportXml.value('/blocked-process-report[1]/blocked-process[1]/process[1]/executionStack[1]/frame[1]/@stmtend', 'int'), -1) AS BlockedStmtEnd
            , bpReportXml.value('/blocked-process-report[1]/blocked-process[1]/process[1]/inputbuf[1]', 'nvarchar(max)') AS BlockedInputBuf

            -- Bloqueador
            , bpReportXml.value('/blocked-process-report[1]/blocking-process[1]/process[1]/@spid', 'smallint') AS BlockingSPID
            , bpReportXml.value('/blocked-process-report[1]/blocking-process[1]/process[1]/@loginname', 'nvarchar(128)') AS [BlockingLoginName]
            , bpReportXml.value('/blocked-process-report[1]/blocking-process[1]/process[1]/@clientapp', 'nvarchar(128)') AS [BlockingClientAppName]
            , bpReportXml.value('/blocked-process-report[1]/blocking-process[1]/process[1]/@hostname', 'nvarchar(128)') AS [BlockingClientHostName]
            , bpReportXml.value('/blocked-process-report[1]/blocking-process[1]/process[1]/@status', 'varchar(16)') AS BlockingStatus
            , bpReportXml.value('/blocked-process-report[1]/blocking-process[1]/process[1]/@trancount', 'smallint') AS BlockingTranCount
            , bpReportXml.value('/blocked-process-report[1]/blocking-process[1]/process[1]/inputbuf[1]', 'nvarchar(max)') AS BlockingInputBuf
            , bpReportXml.value('xs:hexBinary(substring((/blocked-process-report[1]/blocking-process[1]/process[1]/executionStack[1]/frame[1]/@sqlhandle)[1],3))', 'varbinary(max)') AS BlockingSQLHandle
            , ISNULL(bpReportXml.value('/blocked-process-report[1]/blocking-process[1]/process[1]/executionStack[1]/frame[1]/@stmtstart', 'int'), 0) AS BlockingStmtStart
            , ISNULL(bpReportXml.value('/blocked-process-report[1]/blocking-process[1]/process[1]/executionStack[1]/frame[1]/@stmtend', 'int'), -1) AS BlockingStmtEnd
    ) AS bpShredded

    -- ============================================================
    -- Obtém o texto da query bloqueada a partir do SQL Handle
    -- ============================================================
    OUTER APPLY
    (
        SELECT
            CASE
                WHEN ISNULL(bpShredded.BlockedSQLHandle, 0x) = 0x THEN NULL
                ELSE (SELECT [text] FROM sys.dm_exec_sql_text(bpShredded.BlockedSQLHandle))
            END AS [Text]
    ) AS BlockedSQLText

    -- ============================================================
    -- Obtém o texto da query bloqueadora a partir do SQL Handle
    -- ============================================================
    OUTER APPLY
    (
        SELECT
            CASE
                WHEN ISNULL(bpShredded.BlockingSQLHandle, 0x) = 0x THEN NULL
                ELSE (SELECT [text] FROM sys.dm_exec_sql_text(bpShredded.BlockingSQLHandle))
            END AS [Text]
    ) AS BlockingSQLText

    -- ============================================================
    -- Verifica se a query ainda está bloqueada em dm_exec_requests
    -- ============================================================
    OUTER APPLY
    (
        SELECT qp.query_plan
        FROM sys.dm_exec_requests er
            CROSS APPLY sys.dm_exec_query_plan(er.plan_handle) qp
        WHERE er.session_id = bpShredded.BlockedSPID
            AND er.sql_handle = bpShredded.BlockedSQLHandle
            AND er.statement_start_offset = bpShredded.BlockedStmtStart
            AND er.statement_end_offset = bpShredded.BlockedStmtEnd
    ) blockedERPlan

    -- ============================================================
    -- Fallback: se não existe plan handle em dm_exec_requests,
    -- busca em dm_exec_query_stats
    -- ============================================================
    OUTER APPLY
    (
        SELECT
            CASE
                WHEN blockedERPlan.query_plan IS NULL THEN
                (
                    SELECT TOP 1 qp.query_plan
                    FROM sys.dm_exec_query_stats qs WITH (NOLOCK)
                        CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) qp
                    WHERE qs.sql_handle = bpShredded.BlockedSQLHandle
                        AND qs.statement_start_offset = bpShredded.BlockedStmtStart
                        AND qs.statement_end_offset = bpShredded.BlockedStmtEnd
                        AND CAST(hbp.EndTime AS DATETIME) BETWEEN qs.creation_time AND qs.last_execution_time
                    ORDER BY qs.last_execution_time DESC
                )
            END AS query_plan
    ) blockedQSPlan

    -- ============================================================
    -- Obtém o plano da query bloqueadora via dm_exec_query_stats
    -- ============================================================
    OUTER APPLY
    (
        SELECT TOP 1 qp.query_plan
        FROM sys.dm_exec_query_stats qs WITH (NOLOCK)
            CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) qp
        WHERE qs.sql_handle = bpShredded.BlockingSQLHandle
            AND qs.statement_start_offset = bpShredded.BlockingStmtStart
            AND qs.statement_end_offset = bpShredded.BlockingStmtEnd
        ORDER BY qs.last_execution_time DESC
    ) BlockingQSPlan
WHERE hbp.EndTime >= '2024-12-09 00:00:00'
    AND hbp.EndTime <= '2024-12-09 12:00:00'
GO
