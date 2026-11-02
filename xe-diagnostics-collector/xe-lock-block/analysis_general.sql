/*
 *
   OBJETIVO: Investigar eventos de bloqueio capturados pela sessão XE
             blocked_process (evento sqlserver.blocked_process_report) e
             carregados pela dbo.sp_gather_blocked_process_events.

   PROJETO: mssql-xe-observability

   AUTHOR: Robson Sestrem     
 * 
 */
USE DBA_PerformanceHub
GO

-- ============================================================================
-- Visão resumida antes das análises
-- ============================================================================
SELECT bpShredded.[database_name], blocked_spid, blocking_spid, EndTime, blocked_waittime_s, [blocked_sql_text], [blocking_sql_text]
FROM history_blocked_process
CROSS APPLY (
    SELECT CAST(TextData AS XML)
) AS bpReports(bpReportXml)
CROSS APPLY (
	SELECT 
	monitorloop = bpReportXml.value('(//@monitorLoop)[1]', 'nvarchar(100)'),
	blocked_spid = bpReportXml.value('(/blocked-process-report/blocked-process/process/@spid)[1]', 'int'),				
	blocking_spid = bpReportXml.value('(/blocked-process-report/blocking-process/process/@spid)[1]', 'int'),				
    [database_name] = DB_NAME(bpReportXml.value('(/blocked-process-report/blocked-process/process/@currentdb)[1]', 'varchar(20)')),	
	blocked_waittime_s = REPLACE((CAST(CAST(bpReportXml.value('(/blocked-process-report/blocked-process/process/@waittime)[1]', 'bigint') AS VARCHAR(60)) AS MONEY)/1000),',','.'),       
	[blocked_sql_text] =  bpReportXml.value('(/blocked-process-report/blocked-process/process/inputbuf)[1]', 'nvarchar(max)'),
	[blocking_sql_text] =  bpReportXml.value('(/blocked-process-report/blocking-process/process/inputbuf)[1]', 'nvarchar(max)')
) AS bpShredded
WHERE blocking_spid IS NOT NULL AND blocked_spid IS NOT NULL
AND EndTime >= '2026-09-27' AND EndTime < '2026-09-28'
--AND bpShredded.blocking_spid IN (1155, 988)
--AND bpShredded.[database_name] LIKE '%CLIENT_DATABASE%'


-- ============================================================================
-- SEÇÃO 0 — PARÂMETROS
-- ============================================================================
DECLARE @DataInicial DATETIME2(3) = DATEADD(DAY, -7, SYSDATETIME());  -- últimos 7 dias
DECLARE @DataFinal   DATETIME2(3) = SYSDATETIME();
DECLARE @TopN        INT          = 50;

/* ============================================================================
   SEÇÃO 1 — SANIDADE DO XML (rode primeiro)
   Confirma que o shredding funciona e que os atributos esperados existem.
   Se colunas vierem NULL, o atributo não existe no seu build — ajuste
   as seções seguintes antes de confiar nos números.
   ============================================================================ */
SELECT TOP (5)
    h.EndTime
  , h.xeProcessID
  , h.TextData.value('(/blocked-process-report/@monitorLoop)[1]', 'nvarchar(50)')                AS monitor_loop
  , h.TextData.value('count(/blocked-process-report/blocked-process)', 'int')                    AS qtd_vitimas
  , h.TextData.value('count(/blocked-process-report/blocking-process)', 'int')                   AS qtd_bloqueadores
  , h.TextData.value('(/blocked-process-report/blocked-process/process/@spid)[1]', 'int')        AS spid_vitima
  , h.TextData.value('(/blocked-process-report/blocked-process/process/@waittime)[1]', 'bigint') AS waittime_ms
  , h.TextData.value('(/blocked-process-report/blocked-process/process/@lockMode)[1]', 'nvarchar(20)') AS lock_mode
  , h.TextData.value('(/blocked-process-report/blocked-process/process/@waitresource)[1]', 'nvarchar(256)') AS wait_resource
  , h.TextData.value('(/blocked-process-report/blocking-process/process/@spid)[1]', 'int')      AS spid_bloqueador
  , h.TextData.value('(/blocked-process-report/blocking-process/process/@loginname)[1]', 'nvarchar(128)') AS login_bloqueador
  , h.TextData.value('(/blocked-process-report/blocking-process/process/inputbuf)[1]', 'nvarchar(4000)') AS query_bloqueadora
FROM dbo.history_blocked_process AS h WITH (NOLOCK)
WHERE h.EndTime >= @DataInicial
  AND h.EndTime <  @DataFinal
ORDER BY h.EndTime DESC;

/* ============================================================================
   SEÇÃO 2 — PANORAMA DIÁRIO
   Volume de eventos, vítimas distintas e bloqueadores distintos por dia.
   Picos concentrados indicam janelas de carga, ETL ou deploy.
   ============================================================================ */
SELECT
    CONVERT(DATE, h.EndTime)                                                          AS dia
  , COUNT_BIG(*)                                                                      AS eventos
  , SUM(h.TextData.value('count(/blocked-process-report/blocked-process)', 'int'))    AS total_vitimas
  , COUNT_BIG(DISTINCT h.TextData.value('(/blocked-process-report/blocking-process/process/@spid)[1]', 'int')) AS bloqueadores_distintos
  , MAX(h.TextData.value('(/blocked-process-report/blocked-process/process/@waittime)[1]', 'bigint'))          AS maior_espera_ms
  , CAST(AVG(h.TextData.value('(/blocked-process-report/blocked-process/process/@waittime)[1]', 'bigint') * 1.0) AS DECIMAL(18,2)) AS media_espera_ms
FROM dbo.history_blocked_process AS h WITH (NOLOCK)
WHERE h.EndTime >= @DataInicial
  AND h.EndTime <  @DataFinal
GROUP BY CONVERT(DATE, h.EndTime)
ORDER BY dia DESC;

/* ============================================================================
   SEÇÃO 3 — RANKING DE BLOQUEADORES (quem está travando o sistema)
   Agrupa por SPID + login + query do bloqueador. É o diagnóstico primário:
   poucos bloqueadores costumam concentrar a maior parte do impacto.
   LIMITAÇÃO: SPID é reciclado; o agrupamento por SPID só é válido dentro
   de uma janela curta. Para análise de longo prazo, use a Seção 5
   (agrupamento por texto da query).
   ============================================================================ */
;WITH bloqueadores AS
(
    SELECT
        h.EndTime
      , h.TextData.value('(/blocked-process-report/blocking-process/process/@spid)[1]', 'int')                AS spid_bloqueador
      , h.TextData.value('(/blocked-process-report/blocking-process/process/@loginname)[1]', 'nvarchar(128)') AS login_bloqueador
      , h.TextData.value('(/blocked-process-report/blocking-process/process/@status)[1]', 'nvarchar(50)')     AS status_bloqueador
      , h.TextData.value('(/blocked-process-report/blocking-process/process/@transactionname)[1]', 'nvarchar(128)') AS transacao_bloqueadora
      , LEFT(h.TextData.value('(/blocked-process-report/blocking-process/process/inputbuf)[1]', 'nvarchar(4000)'), 500) AS query_bloqueadora
      , h.TextData.value('count(/blocked-process-report/blocked-process)', 'int')                              AS qtd_vitimas
      , h.TextData.value('(/blocked-process-report/blocked-process/process/@waittime)[1]', 'bigint')           AS waittime_ms
    FROM dbo.history_blocked_process AS h WITH (NOLOCK)
    WHERE h.EndTime >= @DataInicial
      AND h.EndTime <  @DataFinal
)
SELECT TOP (@TopN)
    b.spid_bloqueador
  , b.login_bloqueador
  , b.status_bloqueador
  , b.transacao_bloqueadora
  , b.query_bloqueadora
  , COUNT_BIG(*)                    AS vezes_como_bloqueador
  , SUM(b.qtd_vitimas)              AS total_vitimas
  , MAX(b.waittime_ms)              AS maior_espera_ms
  , MIN(b.EndTime)                  AS primeira_ocorrencia
  , MAX(b.EndTime)                  AS ultima_ocorrencia
FROM bloqueadores AS b
GROUP BY
    b.spid_bloqueador
  , b.login_bloqueador
  , b.status_bloqueador
  , b.transacao_bloqueadora
  , b.query_bloqueadora
ORDER BY vezes_como_bloqueador DESC, maior_espera_ms DESC;

/* ============================================================================
   SEÇÃO 4 — RANKING DE RECURSOS CONTENDIDOS (waitresource)
   Identifica a que nível o bloqueio ocorre: KEY (linha), PAGE, RID, OBJECT,
   METADATA, etc. Bloqueios em KEY/PAGE são os mais comuns e os mais caros.
   O padrão do waitresource é: <TIPO>: <dbid>:<fileid>:<pageid>[:<slot>]
   ============================================================================ */
;WITH recursos AS
(
    SELECT
        h.TextData.value('(/blocked-process-report/blocked-process/process/@waitresource)[1]', 'nvarchar(256)') AS wait_resource
      , h.TextData.value('(/blocked-process-report/blocked-process/process/@lockMode)[1]', 'nvarchar(20)')      AS lock_mode_pedido
      , h.TextData.value('(/blocked-process-report/blocked-process/process/@waittime)[1]', 'bigint')            AS waittime_ms
    FROM dbo.history_blocked_process AS h WITH (NOLOCK)
    WHERE h.EndTime >= @DataInicial
      AND h.EndTime <  @DataFinal
)
, recursos_tipados AS
(
    SELECT
        r.wait_resource
      , r.lock_mode_pedido
      , r.waittime_ms
      , LEFT(r.wait_resource, CHARINDEX(':', r.wait_resource + ':') - 1) AS tipo_recurso
    FROM recursos AS r
)
SELECT TOP (@TopN)
    rt.tipo_recurso
  , rt.wait_resource
  , rt.lock_mode_pedido
  , COUNT_BIG(*)                                                       AS ocorrencias
  , MAX(rt.waittime_ms)                                                AS maior_espera_ms
  , CAST(AVG(rt.waittime_ms * 1.0) AS DECIMAL(18,2))                   AS media_espera_ms
FROM recursos_tipados AS rt
GROUP BY
    rt.tipo_recurso
  , rt.wait_resource
  , rt.lock_mode_pedido
ORDER BY ocorrencias DESC, maior_espera_ms DESC;

/* ============================================================================
   SEÇÃO 5 — PADRÕES DE QUERY BLOQUEADORA (análise de longo prazo)
   Agrupa pelo texto normalizado da query do bloqueador, ignorando SPID.
   É a visão que sobrevive à reciclagem de SPID e revela o código culpado.
   SUPOSIÇÃO: inputbuf vem truncado em ~4000 caracteres pelo próprio BPR.
   ============================================================================ */
;WITH padroes AS
(
    SELECT
        LEFT(h.TextData.value('(/blocked-process-report/blocking-process/process/inputbuf)[1]', 'nvarchar(4000)'), 1000) AS query_bloqueadora
      , h.TextData.value('(/blocked-process-report/blocking-process/process/@transactionname)[1]', 'nvarchar(128)')     AS transacao
      , h.TextData.value('count(/blocked-process-report/blocked-process)', 'int')                                        AS qtd_vitimas
      , h.TextData.value('(/blocked-process-report/blocked-process/process/@waittime)[1]', 'bigint')                     AS waittime_ms
      , h.EndTime
    FROM dbo.history_blocked_process AS h WITH (NOLOCK)
    WHERE h.EndTime >= @DataInicial
      AND h.EndTime <  @DataFinal
      AND h.TextData.exist('/blocked-process-report/blocking-process/process/inputbuf/text()') = 1
)
SELECT TOP (@TopN)
    p.query_bloqueadora
  , p.transacao
  , COUNT_BIG(*)                    AS eventos
  , SUM(p.qtd_vitimas)              AS total_vitimas
  , MAX(p.waittime_ms)              AS maior_espera_ms
  , MIN(p.EndTime)                  AS primeira_ocorrencia
  , MAX(p.EndTime)                  AS ultima_ocorrencia
FROM padroes AS p
GROUP BY
    p.query_bloqueadora
  , p.transacao
ORDER BY eventos DESC;

/* ============================================================================
   SEÇÃO 6 — CADEIA COMPLETA DE PARTICIPANTES (análise avançada do XML)
   Faz .nodes() em TODOS os <blocked-process> do relatório. Em bloqueios
   encadeados (A bloqueia B, B bloqueia C), cada vítima aparece como linha
   própria, com o mesmo bloqueador raiz. É a visão que revela o alcance
   real de um único bloqueador.
   ============================================================================ */
;WITH vitimas AS
(
    SELECT
        h.EndTime
      , h.xeProcessID
      , bp.value('(process/@spid)[1]', 'int')                                    AS spid_vitima
      , bp.value('(process/@ecid)[1]', 'int')                                    AS ecid_vitima
      , bp.value('(process/@waittime)[1]', 'bigint')                             AS waittime_ms
      , bp.value('(process/@lockMode)[1]', 'nvarchar(20)')                       AS lock_mode
      , bp.value('(process/@status)[1]', 'nvarchar(50)')                         AS status
      , bp.value('(process/@waitresource)[1]', 'nvarchar(256)')                  AS wait_resource
      , bp.value('(process/@transactionname)[1]', 'nvarchar(128)')               AS transacao
      , bp.value('(process/@lasttranstarted)[1]', 'nvarchar(50)')                AS transacao_iniciada
      , bp.value('(process/@loginname)[1]', 'nvarchar(128)')                     AS login_vitima
      , bp.value('(process/@currentdb)[1]', 'int')                               AS database_id
      , bp.value('(process/@isolationlevel)[1]', 'nvarchar(100)')                AS isolation_level
      , bp.value('(process/inputbuf)[1]', 'nvarchar(4000)')                      AS query_vitima
      , bp.value('(process/executionStack/frame/@procname)[1]', 'nvarchar(256)') AS proc_vitima
      , bp.value('(process/executionStack/frame/@line)[1]', 'int')               AS linha_vitima
      , h.TextData.value('(/blocked-process-report/blocking-process/process/@spid)[1]', 'int')             AS spid_bloqueador
      , h.TextData.value('(/blocked-process-report/blocking-process/process/@loginname)[1]', 'nvarchar(128)') AS login_bloqueador
      , h.TextData.value('(/blocked-process-report/blocking-process/process/@transactionname)[1]', 'nvarchar(128)') AS transacao_bloqueadora
      , h.TextData.value('(/blocked-process-report/blocking-process/process/@lasttranstarted)[1]', 'nvarchar(50)')  AS bloqueador_tran_iniciada
      , LEFT(h.TextData.value('(/blocked-process-report/blocking-process/process/inputbuf)[1]', 'nvarchar(4000)'), 1000) AS query_bloqueadora
      , h.TextData.value('(/blocked-process-report/blocking-process/process/executionStack/frame/@procname)[1]', 'nvarchar(256)') AS proc_bloqueador
      , h.TextData.value('(/blocked-process-report/blocking-process/process/executionStack/frame/@line)[1]', 'int') AS linha_bloqueador
    FROM dbo.history_blocked_process AS h WITH (NOLOCK)
    CROSS APPLY h.TextData.nodes('/blocked-process-report/blocked-process') AS t(bp)
    WHERE h.EndTime >= @DataInicial
      AND h.EndTime <  @DataFinal
)
SELECT TOP (@TopN)
    v.EndTime
  , v.xeProcessID
  , v.spid_bloqueador
  , v.login_bloqueador
  , v.transacao_bloqueadora
  , v.bloqueador_tran_iniciada
  , v.proc_bloqueador
  , v.linha_bloqueador
  , v.query_bloqueadora
  , v.spid_vitima
  , v.ecid_vitima
  , v.login_vitima
  , v.waittime_ms
  , v.lock_mode
  , v.status
  , v.wait_resource
  , v.transacao
  , v.transacao_iniciada
  , v.isolation_level
  , DB_NAME(v.database_id) AS database_name
  , v.proc_vitima
  , v.linha_vitima
  , v.query_vitima
FROM vitimas AS v
ORDER BY v.waittime_ms DESC;

/* ============================================================================
   SEÇÃO 7 — BLOQUEIO ENCADEADO: UM BLOQUEADOR, MUITAS VÍTIMAS
   Filtra apenas eventos em que o relatório traz 2+ vítimas. São os casos
   de maior impacto operacional — um único processo travando vários.
   ============================================================================ */
;WITH encadeados AS
(
    SELECT
        h.EndTime
      , h.xeProcessID
      , h.TextData.value('count(/blocked-process-report/blocked-process)', 'int')                        AS qtd_vitimas
      , h.TextData.value('(/blocked-process-report/blocking-process/process/@spid)[1]', 'int')           AS spid_bloqueador
      , h.TextData.value('(/blocked-process-report/blocking-process/process/@loginname)[1]', 'nvarchar(128)') AS login_bloqueador
      , LEFT(h.TextData.value('(/blocked-process-report/blocking-process/process/inputbuf)[1]', 'nvarchar(4000)'), 1000) AS query_bloqueadora
      , h.TextData.value('max(/blocked-process-report/blocked-process/process/@waittime)', 'bigint')     AS maior_espera_ms
      , h.TextData.value('sum(/blocked-process-report/blocked-process/process/@waittime)', 'bigint')     AS espera_total_ms
    FROM dbo.history_blocked_process AS h WITH (NOLOCK)
    WHERE h.EndTime >= @DataInicial
      AND h.EndTime <  @DataFinal
)
SELECT TOP (@TopN)
    e.EndTime
  , e.qtd_vitimas
  , e.spid_bloqueador
  , e.login_bloqueador
  , e.query_bloqueadora
  , e.maior_espera_ms
  , e.espera_total_ms
FROM encadeados AS e
WHERE e.qtd_vitimas > 1
ORDER BY e.qtd_vitimas DESC, e.espera_total_ms DESC;

/* ============================================================================
   SEÇÃO 8 — PERFIL DAS VÍTIMAS (quem mais sofre)
   Ranking de SPIDs/login/aplicação que mais aparecem como bloqueados.
   Cruza com a Seção 3: quando o mesmo SPID aparece nas duas, existe
   contenção cíclica ou fila em cascata.
   ============================================================================ */
;WITH vitimas AS
(
    SELECT
        h.EndTime
      , bp.value('(process/@spid)[1]', 'int')                    AS spid_vitima
      , bp.value('(process/@loginname)[1]', 'nvarchar(128)')     AS login_vitima
      , bp.value('(process/@waittime)[1]', 'bigint')             AS waittime_ms
      , bp.value('(process/@lockMode)[1]', 'nvarchar(20)')       AS lock_mode
      , bp.value('(process/@waitresource)[1]', 'nvarchar(256)')  AS wait_resource
      , bp.value('(process/inputbuf)[1]', 'nvarchar(4000)')      AS query_vitima
    FROM dbo.history_blocked_process AS h WITH (NOLOCK)
    CROSS APPLY h.TextData.nodes('/blocked-process-report/blocked-process') AS t(bp)
    WHERE h.EndTime >= @DataInicial
      AND h.EndTime <  @DataFinal
)
SELECT TOP (@TopN)
    v.spid_vitima
  , v.login_vitima
  , COUNT_BIG(*)                    AS vezes_bloqueado
  , SUM(v.waittime_ms)              AS espera_total_ms
  , MAX(v.waittime_ms)              AS maior_espera_ms
  , CAST(AVG(v.waittime_ms * 1.0) AS DECIMAL(18,2)) AS media_espera_ms
  , MIN(v.EndTime)                  AS primeira_ocorrencia
  , MAX(v.EndTime)                  AS ultima_ocorrencia
FROM vitimas AS v
GROUP BY v.spid_vitima, v.login_vitima
ORDER BY espera_total_ms DESC;

/* ============================================================================
   SEÇÃO 9 — ANÁLISE DE TEMPO DE ESPERA (distribuição)
   Faixas de espera para dimensionar a severidade real. Bloqueios de 5s
   (threshold) são ruído; acima de 60s já impactam usuário final.
   ============================================================================ */
;WITH vitimas AS
(
    SELECT
        bp.value('(process/@waittime)[1]', 'bigint') AS waittime_ms
    FROM dbo.history_blocked_process AS h WITH (NOLOCK)
    CROSS APPLY h.TextData.nodes('/blocked-process-report/blocked-process') AS t(bp)
    WHERE h.EndTime >= @DataInicial
      AND h.EndTime <  @DataFinal
)
SELECT
    CASE
        WHEN waittime_ms <  10000  THEN '01 - 5s a 10s'
        WHEN waittime_ms <  30000  THEN '02 - 10s a 30s'
        WHEN waittime_ms <  60000  THEN '03 - 30s a 60s'
        WHEN waittime_ms < 300000  THEN '04 - 1min a 5min'
        ELSE                            '05 - acima de 5min'
    END                                                              AS faixa_espera
  , COUNT_BIG(*)                                                     AS total_vitimas
  , SUM(waittime_ms)                                                 AS espera_acumulada_ms
  , CAST(COUNT_BIG(*) * 100.0 / SUM(COUNT_BIG(*)) OVER () AS DECIMAL(5,2)) AS percentual
FROM vitimas
GROUP BY
    CASE
        WHEN waittime_ms <  10000  THEN '01 - 5s a 10s'
        WHEN waittime_ms <  30000  THEN '02 - 10s a 30s'
        WHEN waittime_ms <  60000  THEN '03 - 30s a 60s'
        WHEN waittime_ms < 300000  THEN '04 - 1min a 5min'
        ELSE                            '05 - acima de 5min'
    END
ORDER BY faixa_espera;

/* ============================================================================
   SEÇÃO 10 — TIMELINE DE UM EVENTO ESPECÍFICO (drill-down)
   Dado um EndTime + xeProcessID, reconstrói o relatório completo em
   formato legível: bloqueador, cada vítima, pilha de execução e queries.
   Substitua os valores nas variáveis abaixo pelo evento investigado.
   ============================================================================ */
DECLARE @EndTimeAlvo     DATETIME2(3) = '2026-11-01 05:23:36.671';   -- ex.: '2026-10-30 14:22:11.123'
DECLARE @xeProcessIDAlvo VARCHAR(100) = 'process119ca244e8';         -- ex.: 'process119ca244e8'

SELECT
    h.EndTime
  , h.xeProcessID
  , 'BLOQUEADOR' AS papel
  , h.TextData.value('(/blocked-process-report/blocking-process/process/@spid)[1]', 'int')            AS spid
  , h.TextData.value('(/blocked-process-report/blocking-process/process/@loginname)[1]', 'nvarchar(128)') AS login
  , h.TextData.value('(/blocked-process-report/blocking-process/process/@status)[1]', 'nvarchar(50)')     AS status
  , h.TextData.value('(/blocked-process-report/blocking-process/process/@transactionname)[1]', 'nvarchar(128)') AS transacao
  , h.TextData.value('(/blocked-process-report/blocking-process/process/@lasttranstarted)[1]', 'nvarchar(50)')  AS tran_iniciada
  , h.TextData.value('(/blocked-process-report/blocking-process/process/@lockMode)[1]', 'nvarchar(20)')   AS lock_mode
  , h.TextData.value('(/blocked-process-report/blocking-process/process/@waitresource)[1]', 'nvarchar(256)') AS wait_resource
  , h.TextData.value('(/blocked-process-report/blocking-process/process/@waittime)[1]', 'bigint')         AS waittime_ms
  , h.TextData.value('(/blocked-process-report/blocking-process/process/executionStack/frame/@procname)[1]', 'nvarchar(256)') AS [proc]
  , h.TextData.value('(/blocked-process-report/blocking-process/process/executionStack/frame/@line)[1]', 'int') AS linha
  , h.TextData.value('(/blocked-process-report/blocking-process/process/inputbuf)[1]', 'nvarchar(4000)')  AS query
FROM dbo.history_blocked_process AS h WITH (NOLOCK)
WHERE (@EndTimeAlvo IS NULL OR h.EndTime = @EndTimeAlvo)
  AND (@xeProcessIDAlvo IS NULL OR h.xeProcessID = @xeProcessIDAlvo)

UNION ALL

SELECT
    h.EndTime
  , h.xeProcessID
  , 'VITIMA' AS papel
  , bp.value('(process/@spid)[1]', 'int')
  , bp.value('(process/@loginname)[1]', 'nvarchar(128)')
  , bp.value('(process/@status)[1]', 'nvarchar(50)')
  , bp.value('(process/@transactionname)[1]', 'nvarchar(128)')
  , bp.value('(process/@lasttranstarted)[1]', 'nvarchar(50)')
  , bp.value('(process/@lockMode)[1]', 'nvarchar(20)')
  , bp.value('(process/@waitresource)[1]', 'nvarchar(256)')
  , bp.value('(process/@waittime)[1]', 'bigint')
  , bp.value('(process/executionStack/frame/@procname)[1]', 'nvarchar(256)')
  , bp.value('(process/executionStack/frame/@line)[1]', 'int')
  , bp.value('(process/inputbuf)[1]', 'nvarchar(4000)')
FROM dbo.history_blocked_process AS h WITH (NOLOCK)
CROSS APPLY h.TextData.nodes('/blocked-process-report/blocked-process') AS t(bp)
WHERE (@EndTimeAlvo IS NULL OR h.EndTime = @EndTimeAlvo)
  AND (@xeProcessIDAlvo IS NULL OR h.xeProcessID = @xeProcessIDAlvo)
ORDER BY EndTime DESC, papel DESC;   -- BLOQUEADOR antes de VITIMA

/* ============================================================================
   SEÇÃO 11 — PILHA DE EXECUÇÃO COMPLETA (todos os frames)
   O BPR traz vários <frame> por processo. Aqui cada frame vira uma linha,
   revelando a cadeia de procedures até a instrução culpada.
   Útil quando o bloqueio nasce dentro de uma procedure aninhada.
   ============================================================================ */
;WITH frames AS
(
    SELECT
        h.EndTime
      , h.xeProcessID
      , 'BLOQUEADOR' AS papel
      , h.TextData.value('(/blocked-process-report/blocking-process/process/@spid)[1]', 'int') AS spid
      , f.value('(@procname)[1]', 'nvarchar(256)')  AS procname
      , f.value('(@line)[1]', 'int')                AS linha
      , f.value('(@stmtstart)[1]', 'int')           AS stmt_start
      , f.value('(@stmtend)[1]', 'int')             AS stmt_end
      , f.value('(@sqlhandle)[1]', 'varchar(130)')  AS sql_handle
    FROM dbo.history_blocked_process AS h WITH (NOLOCK)
    CROSS APPLY h.TextData.nodes('/blocked-process-report/blocking-process/process/executionStack/frame') AS t(f)
    WHERE h.EndTime >= @DataInicial
      AND h.EndTime <  @DataFinal

    UNION ALL

    SELECT
        h.EndTime
      , h.xeProcessID
      , 'VITIMA' AS papel
      , bp.value('(process/@spid)[1]', 'int')
      , f.value('(@procname)[1]', 'nvarchar(256)')
      , f.value('(@line)[1]', 'int')
      , f.value('(@stmtstart)[1]', 'int')
      , f.value('(@stmtend)[1]', 'int')
      , f.value('(@sqlhandle)[1]', 'varchar(130)')
    FROM dbo.history_blocked_process AS h WITH (NOLOCK)
    CROSS APPLY h.TextData.nodes('/blocked-process-report/blocked-process') AS t(bp)
    CROSS APPLY h.TextData.nodes('/blocked-process-report/blocked-process/process/executionStack/frame') AS t2(f)
    WHERE h.EndTime >= @DataInicial
      AND h.EndTime <  @DataFinal
)
SELECT TOP (@TopN)
    fr.EndTime
  , fr.xeProcessID
  , fr.papel
  , fr.spid
  , fr.procname
  , fr.linha
  , fr.stmt_start
  , fr.stmt_end
  , fr.sql_handle
FROM frames AS fr
WHERE fr.procname IS NOT NULL
ORDER BY fr.EndTime DESC;

