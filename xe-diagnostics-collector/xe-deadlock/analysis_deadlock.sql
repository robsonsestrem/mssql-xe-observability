/*
 *
    OBJETIVO: Investigar deadlocks capturados pela sessão XE 'deadlocks'
              (evento sqlserver.xml_deadlock_report) e carregados pelas
              procedures sp_load_deadlocks e sp_gather_deadlock_events.

    PROJETO: mssql-xe-observability

    AUTHOR: Robson Sestrem    
 *
 */
USE DBA_PerformanceHub
GO

-- ============================================================================
-- SEÇÃO 0 — PARÂMETROS
-- ============================================================================
DECLARE @DataInicial DATETIME2(3) = DATEADD(DAY, -7, SYSDATETIME());
DECLARE @DataFinal   DATETIME2(3) = SYSDATETIME();
DECLARE @TopN        INT          = 50;

/* ============================================================================
   SEÇÃO 1 — PANORAMA GERAL DE DEADLOCKS
   Um deadlock = um dt_event distinto. Conta eventos, processos envolvidos
   e vítimas por dia. É a linha de base: sem isso, os rankings abaixo
   não têm escala.
   ============================================================================ */
SELECT
    CONVERT(DATE, d.dt_event)                                          AS dia
  , COUNT_BIG(DISTINCT d.dt_event)                                     AS total_deadlocks
  , COUNT_BIG(*)                                                       AS total_processos
  , SUM(CASE WHEN d.isVictim = 1 THEN 1 ELSE 0 END)                    AS total_vitimas
  , COUNT_BIG(DISTINCT d.processClientApp)                             AS apps_distintas
  , COUNT_BIG(DISTINCT d.processHostname)                              AS hosts_distintos
  , MAX(d.processWaitTime)                                             AS maior_espera_ms
FROM dbo.history_deadlocks_details AS d WITH (NOLOCK)
WHERE d.dt_event >= @DataInicial
  AND d.dt_event <  @DataFinal
GROUP BY CONVERT(DATE, d.dt_event)
ORDER BY dia DESC;

/* ============================================================================
   SEÇÃO 2 — DEADLOCKS POR BANCO E POR APLICAÇÃO
   Onde o problema nasce. Agrupa por banco atual do processo + aplicação
   cliente. Um deadlock recorrente em uma única app é bug de código;
   distribuído entre apps aponta para contenção de dados.
   ============================================================================ */
SELECT TOP (@TopN)
    d.processCurrentDbName                                             AS banco
  , d.processClientApp                                                 AS aplicacao
  , d.processHostname                                                  AS host
  , COUNT_BIG(DISTINCT d.dt_event)                                     AS deadlocks
  , COUNT_BIG(*)                                                       AS processos_envolvidos
  , SUM(CASE WHEN d.isVictim = 1 THEN 1 ELSE 0 END)                    AS vezes_vitima
  , MAX(d.processWaitTime)                                             AS maior_espera_ms
  , MIN(d.dt_event)                                                    AS primeiro_evento
  , MAX(d.dt_event)                                                    AS ultimo_evento
FROM dbo.history_deadlocks_details AS d WITH (NOLOCK)
WHERE d.dt_event >= @DataInicial
  AND d.dt_event <  @DataFinal
GROUP BY
    d.processCurrentDbName
  , d.processClientApp
  , d.processHostname
ORDER BY deadlocks DESC;

/* ============================================================================
   SEÇÃO 3 — RANKING DE RECURSOS DISPUTADOS (waitresource)
   O recurso é a raiz do deadlock. O padrão do waitresource é:
     KEY: <dbid>:<fileid>:<pageid> (<hash>)   -> bloqueio de linha
     PAGE: <dbid>:<fileid>:<pageid>           -> bloqueio de página
     OBJECT: <dbid>:<objectid>:<indexid>      -> bloqueio de objeto
     RID: ...                                 -> heap
   Deadlocks em KEY são os mais comuns e os mais caros de corrigir.
   ============================================================================ */
;WITH recursos AS
(
    SELECT
        d.processWaitResource                                          AS wait_resource
      , d.processLockMode                                              AS lock_mode
      , d.processWaitTime                                              AS waittime_ms
      , d.dt_event
      , LEFT(d.processWaitResource, CHARINDEX(':', d.processWaitResource + ':') - 1) AS tipo_recurso
    FROM dbo.history_deadlocks_details AS d WITH (NOLOCK)
    WHERE d.dt_event >= @DataInicial
      AND d.dt_event <  @DataFinal
      AND d.processWaitResource IS NOT NULL
)
SELECT TOP (@TopN)
    r.tipo_recurso
  , r.wait_resource
  , r.lock_mode
  , COUNT_BIG(DISTINCT r.dt_event)                                     AS deadlocks
  , COUNT_BIG(*)                                                       AS ocorrencias
  , MAX(r.waittime_ms)                                                 AS maior_espera_ms
  , CAST(AVG(r.waittime_ms * 1.0) AS DECIMAL(18,2))                    AS media_espera_ms
FROM recursos AS r
GROUP BY
    r.tipo_recurso
  , r.wait_resource
  , r.lock_mode
ORDER BY deadlocks DESC, ocorrencias DESC;

/* ============================================================================
   SEÇÃO 4 — PADRÕES DE COMANDO SQL ENVOLVIDOS
   Agrupa pelo texto do comando do processo. É a visão que sobrevive à
   reciclagem de SPID e revela o código culpado. Um mesmo comando
   aparecendo em muitos deadlocks = candidato direto a correção
   (índice, ordem de acesso, transação mais curta).
   ============================================================================ */
SELECT TOP (@TopN)
    LEFT(d.processSqlCommand, 1000)                                    AS comando_sql
  , d.processTransactionName                                           AS transacao
  , d.processIsolationLevel                                            AS isolation_level
  , COUNT_BIG(DISTINCT d.dt_event)                                     AS deadlocks
  , COUNT_BIG(*)                                                       AS ocorrencias
  , SUM(CASE WHEN d.isVictim = 1 THEN 1 ELSE 0 END)                    AS vezes_vitima
  , MAX(d.processWaitTime)                                             AS maior_espera_ms
FROM dbo.history_deadlocks_details AS d WITH (NOLOCK)
WHERE d.dt_event >= @DataInicial
  AND d.dt_event <  @DataFinal
  AND d.processSqlCommand IS NOT NULL
GROUP BY
    LEFT(d.processSqlCommand, 1000)
  , d.processTransactionName
  , d.processIsolationLevel
ORDER BY deadlocks DESC;

/* ============================================================================
   SEÇÃO 5 — PERFIL DAS VÍTIMAS
   Quem o engine escolheu matar. A vítima é escolhida por custo de rollback
   (log usado), não por culpa. Uma app que aparece sempre como vítima pode
   ser a mais leve — e a mais prejudicada.
   ============================================================================ */
SELECT TOP (@TopN)
    d.processClientApp                                                 AS aplicacao
  , d.processLoginName                                                 AS login
  , d.processHostname                                                  AS host
  , COUNT_BIG(DISTINCT d.dt_event)                                     AS vezes_vitima
  , COUNT_BIG(*)                                                       AS total_linhas
  , MAX(d.processWaitTime)                                             AS maior_espera_ms
  , MIN(d.dt_event)                                                    AS primeira_ocorrencia
  , MAX(d.dt_event)                                                    AS ultima_ocorrencia
FROM dbo.history_deadlocks_details AS d WITH (NOLOCK)
WHERE d.dt_event >= @DataInicial
  AND d.dt_event <  @DataFinal
  AND d.isVictim = 1
GROUP BY
    d.processClientApp
  , d.processLoginName
  , d.processHostname
ORDER BY vezes_vitima DESC;

/* ============================================================================
   SEÇÃO 6 — CADEIA COMPLETA DE PARTICIPANTES POR DEADLOCK
   Reconstrói cada deadlock com TODOS os processos envolvidos, marcando
   quem foi vítima. Ordenado por evento e por ordem de espera, mostra
   o ciclo completo — não apenas a vítima.
   Usa ROW_NUMBER para numerar os participantes dentro do evento.
   ============================================================================ */
;WITH participantes AS
(
    SELECT
        d.dt_event
      , d.processId
      , d.processSPID
      , d.isVictim
      , d.processWaitResource
      , d.processLockMode
      , d.processWaitTime
      , d.processTransactionName
      , d.processStatus
      , d.processClientApp
      , d.processHostname
      , d.processLoginName
      , d.processIsolationLevel
      , d.processCurrentDbName
      , d.processTranCount
      , d.transaction_time
      , d.batch_started
      , d.batch_completed
      , LEFT(d.processSqlCommand, 500)                                 AS comando_sql
      , ROW_NUMBER() OVER (PARTITION BY d.dt_event ORDER BY d.isVictim DESC, d.processSPID) AS ordem_participante
      , COUNT(*) OVER (PARTITION BY d.dt_event)                        AS qtd_participantes
    FROM dbo.history_deadlocks_details AS d WITH (NOLOCK)
    WHERE d.dt_event >= @DataInicial
      AND d.dt_event <  @DataFinal
)
SELECT TOP (@TopN * 5)
    p.dt_event
  , p.qtd_participantes
  , p.ordem_participante
  , CASE WHEN p.isVictim = 1 THEN 'VITIMA' ELSE 'SOBREVIVENTE' END     AS papel
  , p.processSPID                                                      AS spid
  , p.processId                                                        AS process_id
  , p.processClientApp                                                 AS aplicacao
  , p.processHostname                                                  AS host
  , p.processLoginName                                                 AS login
  , p.processWaitResource                                              AS wait_resource
  , p.processLockMode                                                  AS lock_mode
  , p.processWaitTime                                                  AS waittime_ms
  , p.processTransactionName                                           AS transacao
  , p.processStatus                                                    AS status
  , p.processIsolationLevel                                            AS isolation_level
  , p.processCurrentDbName                                             AS banco
  , p.processTranCount                                                 AS tran_count
  , p.transaction_time
  , p.batch_started
  , p.batch_completed
  , p.comando_sql
FROM participantes AS p
ORDER BY p.dt_event DESC, p.ordem_participante;

/* ============================================================================
   SEÇÃO 7 — DEADLOCKS COM MÚLTIPLAS VÍTIMAS (casos graves)
   Quando o XML traz mais de um victimProcess, o evento é mais severo:
   o engine matou mais de uma sessão para resolver o ciclo. Filtra apenas
   esses casos a partir da tabela de XML.
   ============================================================================ */
;WITH multi_vitimas AS
(
    SELECT
        x.xeTimeStamp
      , x.xeProcessID
      , x.xeXML.value('count(/event/data/value/deadlock/victim-list/victimProcess)', 'int')   AS qtd_vitimas
      , x.xeXML.value('count(/event/data/value/deadlock/process-list/process)', 'int')        AS qtd_processos
      , x.xeXML.value('(/event/action[@name="session_id"]/value)[1]', 'int')                  AS session_id_real
      , x.xeXML.value('(/event/action[@name="client_app_name"]/value)[1]', 'nvarchar(256)')   AS client_app_name
      , x.xeXML.value('(/event/action[@name="client_hostname"]/value)[1]', 'nvarchar(256)')   AS client_hostname
      , x.xeXML.value('(/event/action[@name="database_name"]/value)[1]', 'nvarchar(128)')     AS database_name
      , x.xeXML.value('(/event/data/value/deadlock/@victimList)[1]', 'nvarchar(256)')         AS victim_list_attr
    FROM dbo.history_deadlock_xml_events AS x WITH (NOLOCK)
    WHERE x.xeTimeStamp >= @DataInicial
      AND x.xeTimeStamp <  @DataFinal
)
SELECT TOP (@TopN)
    mv.xeTimeStamp
  , mv.xeProcessID
  , mv.qtd_vitimas
  , mv.qtd_processos
  , mv.session_id_real
  , mv.client_app_name
  , mv.client_hostname
  , mv.database_name
FROM multi_vitimas AS mv
WHERE mv.qtd_vitimas > 1
ORDER BY mv.qtd_vitimas DESC, mv.xeTimeStamp DESC;

/* ============================================================================
   SEÇÃO 8 — SHREDDING COMPLETO DO XML: TODOS OS PROCESSOS DE TODOS OS EVENTOS
   Esta é a análise avançada do XML. Faz .nodes() em process-list/process
   e extrai todos os atributos relevantes diretamente do grafo, sem depender
   da tabela de detalhes (que tem os problemas de carga documentados).
   Também extrai a cadeia de execução (executionStack/frame) e o inputbuf.
   ============================================================================ */
;WITH processos AS
(
    SELECT
        x.xeTimeStamp
      , x.xeProcessID
      , x.xeXML.value('(/event/action[@name="session_id"]/value)[1]', 'int')                AS session_id_real
      , x.xeXML.value('(/event/action[@name="client_app_name"]/value)[1]', 'nvarchar(256)') AS client_app_name
      , x.xeXML.value('(/event/action[@name="client_hostname"]/value)[1]', 'nvarchar(256)') AS client_hostname
      , x.xeXML.value('(/event/action[@name="database_name"]/value)[1]', 'nvarchar(128)')   AS database_name
      , p.value('(@id)[1]', 'varchar(100)')                                                 AS process_id
      , p.value('(@spid)[1]', 'int')                                                        AS spid
      , p.value('(@ecid)[1]', 'int')                                                        AS ecid
      , p.value('(@waittime)[1]', 'int')                                                    AS waittime_ms
      , p.value('(@waitresource)[1]', 'varchar(256)')                                       AS wait_resource
      , p.value('(@lockMode)[1]', 'varchar(20)')                                            AS lock_mode
      , p.value('(@status)[1]', 'varchar(60)')                                              AS status
      , p.value('(@transactionname)[1]', 'varchar(128)')                                    AS transaction_name
      , p.value('(@lasttranstarted)[1]', 'datetime')                                        AS last_tran_started
      , p.value('(@lastbatchstarted)[1]', 'datetime')                                       AS last_batch_started
      , p.value('(@lastbatchcompleted)[1]', 'datetime')                                     AS last_batch_completed
      , p.value('(@logused)[1]', 'bigint')                                                  AS log_used
      , p.value('(@lockCount)[1]', 'int')                                                   AS lock_count
      , p.value('(@clientapp)[1]', 'varchar(256)')                                          AS client_app
      , p.value('(@hostname)[1]', 'varchar(256)')                                           AS hostname
      , p.value('(@loginname)[1]', 'varchar(256)')                                          AS login_name
      , p.value('(@isolationlevel)[1]', 'varchar(256)')                                     AS isolation_level
      , p.value('(@currentdb)[1]', 'varchar(256)')                                          AS current_db_id
      , p.value('(@trancount)[1]', 'int')                                                   AS tran_count
      , p.value('(@priority)[1]', 'int')                                                    AS priority
      , p.value('(inputbuf)[1]', 'nvarchar(4000)')                                          AS input_buf
      , p.value('(executionStack/frame/@procname)[1]', 'nvarchar(256)')                     AS proc_name
      , p.value('(executionStack/frame/@line)[1]', 'int')                                   AS proc_line
      , p.value('(executionStack/frame/@stmtstart)[1]', 'int')                              AS stmt_start
      , p.value('(executionStack/frame/@stmtend)[1]', 'int')                                AS stmt_end
      , p.value('(executionStack/frame/@sqlhandle)[1]', 'varchar(130)')                     AS sql_handle
      , v.is_victim
    FROM dbo.history_deadlock_xml_events AS x WITH (NOLOCK)
    CROSS APPLY x.xeXML.nodes('/event/data/value/deadlock/process-list/process') AS t(p)
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
      AND x.xeTimeStamp <  @DataFinal
)
SELECT TOP (@TopN * 5)
    pr.xeTimeStamp
  , pr.xeProcessID
  , pr.session_id_real
  , pr.client_app_name
  , pr.client_hostname
  , pr.database_name
  , pr.process_id
  , pr.spid
  , pr.ecid
  , CASE WHEN pr.is_victim = 1 THEN 'VITIMA' ELSE 'SOBREVIVENTE' END AS papel
  , pr.waittime_ms
  , pr.wait_resource
  , pr.lock_mode
  , pr.status
  , pr.transaction_name
  , pr.last_tran_started
  , pr.last_batch_started
  , pr.last_batch_completed
  , pr.log_used
  , pr.lock_count
  , pr.client_app
  , pr.hostname
  , pr.login_name
  , pr.isolation_level
  , pr.current_db_id
  , pr.tran_count
  , pr.priority
  , pr.proc_name
  , pr.proc_line
  , pr.stmt_start
  , pr.stmt_end
  , pr.sql_handle
  , pr.input_buf
FROM processos AS pr
ORDER BY pr.xeTimeStamp DESC, pr.is_victim DESC, pr.spid;

/* ============================================================================
   SEÇÃO 9 — CICLO DE ESPERA: QUEM ESPERA POR QUEM
   Reconstrói o grafo de espera a partir do XML: cada processo declara
   o waitresource que está aguardando. Cruzando com quem detém o lock
   (via lockMode e waitresource compartilhado), é possível identificar
   o ciclo. Aqui listamos os pares waitresource + lockMode por evento,
   que é a base para desenhar o grafo.
   ============================================================================ */
;WITH esperas AS
(
    SELECT
        x.xeTimeStamp
      , p.value('(@spid)[1]', 'int')                                    AS spid
      , p.value('(@id)[1]', 'varchar(100)')                             AS process_id
      , p.value('(@waitresource)[1]', 'varchar(256)')                   AS wait_resource
      , p.value('(@lockMode)[1]', 'varchar(20)')                        AS lock_mode
      , p.value('(@waittime)[1]', 'int')                                AS waittime_ms
      , p.value('(@status)[1]', 'varchar(60)')                          AS status
      , p.value('(@transactionname)[1]', 'varchar(128)')                AS transaction_name
      , p.value('(inputbuf)[1]', 'nvarchar(4000)')                      AS input_buf
      , v.is_victim
    FROM dbo.history_deadlock_xml_events AS x WITH (NOLOCK)
    CROSS APPLY x.xeXML.nodes('/event/data/value/deadlock/process-list/process') AS t(p)
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
      AND x.xeTimeStamp <  @DataFinal
)
SELECT TOP (@TopN * 5)
    e.xeTimeStamp
  , e.spid
  , e.process_id
  , CASE WHEN e.is_victim = 1 THEN 'VITIMA' ELSE 'SOBREVIVENTE' END    AS papel
  , e.wait_resource
  , e.lock_mode
  , e.waittime_ms
  , e.status
  , e.transaction_name
  , LEFT(e.input_buf, 500)                                             AS comando_sql
FROM esperas AS e
ORDER BY e.xeTimeStamp DESC, e.waittime_ms DESC;

/* ============================================================================
   SEÇÃO 10 — DEADLOCKS COM DETALHE COMPLETO (drill-down de um evento)
   Dado um timestamp, reconstrói o deadlock inteiro: todos os processos,
   a vítima, os recursos e os comandos. Substitua @xeTimeStampAlvo pelo
   evento investigado (obtido nas seções anteriores).
   ============================================================================ */
DECLARE @xeTimeStampAlvo DATETIME2(3) = NULL;   -- ex.: '2023-10-02 11:44:07.935'

;WITH processos AS
(
    SELECT
        x.xeTimeStamp
      , x.xeProcessID
      , p.value('(@id)[1]', 'varchar(100)')                             AS process_id
      , p.value('(@spid)[1]', 'int')                                    AS spid
      , p.value('(@waittime)[1]', 'int')                                AS waittime_ms
      , p.value('(@waitresource)[1]', 'varchar(256)')                   AS wait_resource
      , p.value('(@lockMode)[1]', 'varchar(20)')                        AS lock_mode
      , p.value('(@status)[1]', 'varchar(60)')                          AS status
      , p.value('(@transactionname)[1]', 'varchar(128)')                AS transaction_name
      , p.value('(@lasttranstarted)[1]', 'datetime')                    AS last_tran_started
      , p.value('(@logused)[1]', 'bigint')                              AS log_used
      , p.value('(@clientapp)[1]', 'varchar(256)')                      AS client_app
      , p.value('(@hostname)[1]', 'varchar(256)')                       AS hostname
      , p.value('(@loginname)[1]', 'varchar(256)')                      AS login_name
      , p.value('(@isolationlevel)[1]', 'varchar(256)')                 AS isolation_level
      , p.value('(inputbuf)[1]', 'nvarchar(4000)')                      AS input_buf
      , p.value('(executionStack/frame/@procname)[1]', 'nvarchar(256)') AS proc_name
      , p.value('(executionStack/frame/@line)[1]', 'int')               AS proc_line
      , v.is_victim
    FROM dbo.history_deadlock_xml_events AS x WITH (NOLOCK)
    CROSS APPLY x.xeXML.nodes('/event/data/value/deadlock/process-list/process') AS t(p)
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
    WHERE (@xeTimeStampAlvo IS NULL OR x.xeTimeStamp = @xeTimeStampAlvo)
)
SELECT
    pr.xeTimeStamp
  , pr.xeProcessID
  , pr.process_id
  , pr.spid
  , CASE WHEN pr.is_victim = 1 THEN 'VITIMA' ELSE 'SOBREVIVENTE' END   AS papel
  , pr.waittime_ms
  , pr.wait_resource
  , pr.lock_mode
  , pr.status
  , pr.transaction_name
  , pr.last_tran_started
  , pr.log_used
  , pr.client_app
  , pr.hostname
  , pr.login_name
  , pr.isolation_level
  , pr.proc_name
  , pr.proc_line
  , pr.input_buf
FROM processos AS pr
ORDER BY pr.xeTimeStamp DESC, pr.is_victim DESC, pr.spid;

/* ============================================================================
   SEÇÃO 11 — PILHA DE EXECUÇÃO COMPLETA (todos os frames)
   O XML traz vários <frame> por processo. Cada frame vira uma linha,
   revelando a cadeia de procedures até a instrução culpada. Indispensável
   quando o deadlock nasce dentro de uma procedure aninhada ou trigger.
   ============================================================================ */
;WITH frames AS
(
    SELECT
        x.xeTimeStamp
      , p.value('(@spid)[1]', 'int')                                    AS spid
      , p.value('(@id)[1]', 'varchar(100)')                             AS process_id
      , f.value('(@procname)[1]', 'nvarchar(256)')                      AS proc_name
      , f.value('(@line)[1]', 'int')                                    AS linha
      , f.value('(@stmtstart)[1]', 'int')                               AS stmt_start
      , f.value('(@stmtend)[1]', 'int')                                 AS stmt_end
      , f.value('(@sqlhandle)[1]', 'varchar(130)')                      AS sql_handle
      , v.is_victim
    FROM dbo.history_deadlock_xml_events AS x WITH (NOLOCK)
    CROSS APPLY x.xeXML.nodes('/event/data/value/deadlock/process-list/process') AS t(p)
    CROSS APPLY p.nodes('executionStack/frame') AS t2(f)
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
      AND x.xeTimeStamp <  @DataFinal
)
SELECT TOP (@TopN * 5)
    fr.xeTimeStamp
  , fr.spid
  , fr.process_id
  , CASE WHEN fr.is_victim = 1 THEN 'VITIMA' ELSE 'SOBREVIVENTE' END   AS papel
  , fr.proc_name
  , fr.linha
  , fr.stmt_start
  , fr.stmt_end
  , fr.sql_handle
FROM frames AS fr
WHERE fr.proc_name IS NOT NULL
ORDER BY fr.xeTimeStamp DESC, fr.spid;

