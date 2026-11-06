/*
 *
    OBJETIVO: Análise avançada de deadlocks contendo ranking de procedures
              envolvidas nas pilhas de execução (contagem de deadlocks
              distintos versus total de frames) e detalhamento por processo
              e frame, com identificação de papel (vítima ou sobrevivente),
              para diagnóstico de causa raiz.
              O ranking de procedures é útil para responder "onde no código
              o deadlock nasce" — especialmente quando o deadlock acontece 
              dentro de uma procedure aninhada, onde o inputbuf 
              mostra só o comando externo. A pilha revela a cadeia completa.

    PROJETO: mssql-xe-observability

    AUTHOR: Robson Sestrem

    REFERÊNCIAS DE URL:
 *  Documentação oficial: XML nodes(), ROW_NUMBER, CROSS APPLY, sql:column
 */
-- ============================================================================
-- RANKING DE PROCEDURES ENVOLVIDAS EM DEADLOCKS
-- ----------------------------------------------------------------------------
-- Identifica quais procedures aparecem nas pilhas de execução dos deadlocks
-- e com que frequência, separando "quantos deadlocks" de "quantos frames".
-- ============================================================================
USE DBA_PerformanceHub
GO

DECLARE @DataInicial DATETIME2(3) = DATEADD(HOUR, -500, SYSDATETIME())
DECLARE @DataFinal   DATETIME2(3) = SYSDATETIME()
DECLARE @TopN        INT          = 50

-- ============================================================================
-- 1) Ranking por procedure: quantos deadlocks distintos e quantos frames
-- ============================================================================
;WITH frames AS
(
    SELECT
          x.xeTimeStamp
        , x.xeProcessID
        , p.value('(@id)[1]', 'varchar(100)') AS process_id
        , p.value('(@spid)[1]', 'int') AS spid
        , f.value('(@procname)[1]', 'nvarchar(256)') AS proc_name
        , f.value('(@line)[1]', 'int') AS linha
        , f.value('(@stmtstart)[1]', 'int') AS stmt_start
        , f.value('(@stmtend)[1]', 'int') AS stmt_end
        , ROW_NUMBER() OVER
        (
            PARTITION BY x.xeTimeStamp, p.value('(@id)[1]', 'varchar(100)')
            ORDER BY (SELECT NULL)
        ) AS ordem_frame
    FROM dbo.history_deadlock_xml_events AS x WITH (NOLOCK)
        CROSS APPLY x.xeXML.nodes('/event/data/value/deadlock/process-list/process') AS t (p)
        CROSS APPLY p.nodes('executionStack/frame') AS t2 (f)
    WHERE x.xeTimeStamp >= @DataInicial
        AND x.xeTimeStamp < @DataFinal
        AND x.xeXML.exist('/event[@name="xml_deadlock_report"]') = 1
)
SELECT TOP (@TopN)
      fr.proc_name AS procedure_name
    , COUNT(DISTINCT fr.xeTimeStamp) AS deadlocks_distintos
    , COUNT_BIG(*) AS total_frames
    , COUNT(DISTINCT fr.spid) AS spids_distintos
    , MIN(fr.linha) AS menor_linha
    , MAX(fr.linha) AS maior_linha
    , MIN(fr.xeTimeStamp) AS primeira_ocorrencia
    , MAX(fr.xeTimeStamp) AS ultima_ocorrencia
FROM frames AS fr
WHERE fr.proc_name IS NOT NULL
    AND fr.proc_name <> N''
GROUP BY fr.proc_name
ORDER BY deadlocks_distintos DESC, total_frames DESC
GO

-- ============================================================================
-- DETALHAMENTO POR PROCESSO E FRAME
-- ----------------------------------------------------------------------------
-- Lista cada frame de cada processo de cada deadlock, com a posição na pilha.
-- É o drill-down do ranking acima. Cada linha traz process_id, spid,
-- ordem_frame e papel (vítima ou sobrevivente), o que permite reconstruir
-- a cadeia.
-- ============================================================================
USE DBA_PerformanceHub
GO

DECLARE @DataInicial DATETIME2(3) = DATEADD(HOUR, -500, SYSDATETIME())
DECLARE @DataFinal   DATETIME2(3) = SYSDATETIME()
DECLARE @TopN        INT          = 200

;WITH frames AS
(
    SELECT
          x.xeTimeStamp
        , x.xeProcessID
        , p.value('(@id)[1]', 'varchar(100)') AS process_id
        , p.value('(@spid)[1]', 'int') AS spid
        , p.value('(@waittime)[1]', 'int') AS waittime_ms
        , p.value('(@waitresource)[1]', 'varchar(256)') AS wait_resource
        , p.value('(@lockMode)[1]', 'varchar(20)') AS lock_mode
        , p.value('(@clientapp)[1]', 'varchar(256)') AS client_app
        , p.value('(@hostname)[1]', 'varchar(256)') AS hostname
        , p.value('(@loginname)[1]', 'varchar(256)') AS login_name
        , p.value('(inputbuf)[1]', 'nvarchar(4000)') AS input_buf
        , f.value('(@procname)[1]', 'nvarchar(256)') AS proc_name
        , f.value('(@line)[1]', 'int') AS linha
        , f.value('(@stmtstart)[1]', 'int') AS stmt_start
        , f.value('(@stmtend)[1]', 'int') AS stmt_end
        , f.value('(@sqlhandle)[1]', 'varchar(130)') AS sql_handle
        , ROW_NUMBER() OVER
        (
            PARTITION BY x.xeTimeStamp, p.value('(@id)[1]', 'varchar(100)')
            ORDER BY (SELECT NULL)
        ) AS ordem_frame
        , v.is_victim
    FROM dbo.history_deadlock_xml_events AS x WITH (NOLOCK)
        CROSS APPLY x.xeXML.nodes('/event/data/value/deadlock/process-list/process') AS t (p)
        CROSS APPLY p.nodes('executionStack/frame') AS t2 (f)
        CROSS APPLY
        (
            SELECT
                CASE
                    WHEN x.xeXML.exist('/event/data/value/deadlock/victim-list/victimProcess[@id = sql:column("k.process_id")]') = 1
                        THEN 1
                    ELSE 0
                END AS is_victim
            FROM (SELECT p.value('(@id)[1]', 'varchar(100)') AS process_id) AS k
        ) AS v
    WHERE x.xeTimeStamp >= @DataInicial
        AND x.xeTimeStamp < @DataFinal
        AND x.xeXML.exist('/event[@name="xml_deadlock_report"]') = 1
)
SELECT TOP (@TopN)
      fr.xeTimeStamp
    , fr.process_id
    , fr.spid
    , CASE WHEN fr.is_victim = 1 THEN 'VITIMA' ELSE 'SOBREVIVENTE' END AS papel
    , fr.ordem_frame
    , fr.proc_name
    , fr.linha
    , fr.stmt_start
    , fr.stmt_end
    , fr.waittime_ms
    , fr.wait_resource
    , fr.lock_mode
    , fr.client_app
    , fr.hostname
    , fr.login_name
    , fr.sql_handle
    , LEFT(fr.input_buf, 300) AS comando_sql
FROM frames AS fr
ORDER BY fr.xeTimeStamp DESC, fr.spid, fr.ordem_frame
GO
