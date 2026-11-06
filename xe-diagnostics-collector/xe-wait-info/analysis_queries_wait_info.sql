/*
 *
   OBJETIVO: Investigar waits e estatísticas de execução capturados pela
             sessão XE query_performance_wait_info (eventos sqlos.wait_info,
             sp_statement_completed, sql_statement_completed) e carregados
             pela dbo.sp_load_query_performance_wait_info.

   PROJETO: mssql-xe-observability

   AUTHOR: Robson Sestrem
   ----------------------------------------------------------------------------
   SUPOSIÇÕES E AVISOS CRÍTICOS:

   1. AVISO CRÍTICO — UNIDADES DIFERENTES ENTRE AS TABELAS:
      - history_waits.duration_ms e signal_duration_ms estão em
        MILISSEGUNDOS (sqlos.wait_info usa ms).
      - history_query_stats.duration_ms e cpu_time_ms estão em
        MICROSSEGUNDOS, apesar do sufixo "_ms" no nome da coluna.
        A carga NÃO converte. Uma query de 5s aparece como 5000000.
      As seções abaixo convertem history_query_stats para segundos e
      history_waits para segundos, respeitando a unidade de cada uma.

   2. signal_duration É O INDICADOR DE PRESSÃO DE CPU:
      duration = tempo total de espera (recurso + fila de scheduler)
      signal_duration = apenas o tempo na fila de scheduler
      Razão signal/duration alta (> 25%) = pressão de CPU (mais threads
      que cores disponíveis). Razão baixa = o recurso esperado é o gargalo.
      A Seção 4 calcula essa razão — é o diagnóstico central.

   3. FILTRO DE wait_type USA CHAVES NUMÉRICAS:
      A sessão filtra por map_key de sys.dm_xe_map_values, que NÃO é
      estável entre versões/builds do SQL Server. A rotina já corrigiu
      os valores (ex.: CXPACKET de 187 para 191). Se o servidor for
      atualizado, os filtros podem capturar o wait errado silenciosamente.
      Valide com: SELECT name, map_key, map_value FROM sys.dm_xe_map_values
      WHERE name = 'wait_types'.

   4. history_wait_info_xevents É STAGING:
      Guarda o XML bruto de todos os eventos indefinidamente. As outras
      duas tabelas são derivadas dela. Sem limpeza, cresce rapidamente.

   5. THRESHOLDS DE CAPTURA:
      - Waits: 5ms (LCK), 10ms (LATCH, PAGELATCH, PAGEIOLATCH, IO,
        CXPACKET, WRITELOG, SOS_SCHEDULER_YIELD), 800ms (RESOURCE_SEMAPHORE,
        SOS_WORKER, CMEMTHREAD, TRACEWRITE).
      - Statements: 5.000.000 microssegundos = 5 segundos.
      Waits abaixo desses limites NÃO estão no histórico.

   6. event_interval é o event_time truncado ao minuto. Útil para
      agrupar, mas perde precisão de segundos.

   7. NÃO faça JOIN direto entre history_waits e history_query_stats por
      query_hash esperando correlação 1:1: um statement lento gera N
      waits e 1 evento de statement. A relação é 1:N.
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
   SEÇÃO 1 — PANORAMA GERAL DIÁRIO
   Volume de waits e de statements lentos por dia. A comparação entre os
   dois mostra se o problema é de espera (muitos waits) ou de execução
   (poucos statements muito lentos).
   ============================================================================ */
SELECT
    CONVERT(DATE, w.event_time)                                        AS dia
  , COUNT_BIG(*)                                                       AS total_waits
  , COUNT_BIG(DISTINCT w.wait_type)                                    AS tipos_wait
  , COUNT_BIG(DISTINCT w.query_hash)                                   AS queries_distintas
  , COUNT_BIG(DISTINCT w.session_id)                                   AS sessoes_distintas
  , CAST(SUM(w.duration_ms) / 1000.0 AS DECIMAL(18,2))                 AS espera_total_seg
  , CAST(SUM(w.signal_duration_ms) / 1000.0 AS DECIMAL(18,2))          AS fila_cpu_total_seg
  , CAST(MAX(w.duration_ms) / 1000.0 AS DECIMAL(18,2))                 AS maior_espera_seg
FROM dbo.history_waits AS w WITH (NOLOCK)
WHERE w.event_time >= @DataInicial
  AND w.event_time <  @DataFinal
GROUP BY CONVERT(DATE, w.event_time)
ORDER BY dia DESC;

/* ============================================================================
   SEÇÃO 2 — RANKING DE WAIT TYPES (o diagnóstico primário)
   Onde o tempo está sendo gasto. Ordena por tempo total acumulado, não por
   contagem — um wait raro de 60s pesa mais que mil waits de 10ms.
   ============================================================================ */
SELECT TOP (@TopN)
    w.wait_type
  , COUNT_BIG(*)                                                       AS ocorrencias
  , CAST(SUM(w.duration_ms) / 1000.0 AS DECIMAL(18,2))                 AS espera_total_seg
  , CAST(SUM(w.signal_duration_ms) / 1000.0 AS DECIMAL(18,2))          AS fila_cpu_total_seg
  , CAST(AVG(w.duration_ms * 1.0) / 1000.0 AS DECIMAL(18,3))           AS media_espera_seg
  , CAST(MAX(w.duration_ms) / 1000.0 AS DECIMAL(18,2))                 AS maior_espera_seg
  , COUNT_BIG(DISTINCT w.query_hash)                                   AS queries_distintas
  , COUNT_BIG(DISTINCT w.session_id)                                   AS sessoes_distintas
  , CAST(
        SUM(w.duration_ms) * 100.0
        / NULLIF(SUM(SUM(w.duration_ms)) OVER (), 0)
        AS DECIMAL(5,2)
    )                                                                  AS pct_do_tempo_total
FROM dbo.history_waits AS w WITH (NOLOCK)
WHERE w.event_time >= @DataInicial
  AND w.event_time <  @DataFinal
GROUP BY w.wait_type
ORDER BY espera_total_seg DESC;

/* ============================================================================
   SEÇÃO 3 — CLASSIFICAÇÃO POR CATEGORIA DE WAIT
   Agrupa os wait types em famílias para leitura macro. A categoria indica
   o subsistema culpado: lock (contenção), I/O (disco), CPU (fila),
   memória (grant), rede (linked server).
   ============================================================================ */
;WITH categorizado AS
(
    SELECT
        w.wait_type
      , w.duration_ms
      , w.signal_duration_ms
      , w.query_hash
      , CASE
            WHEN w.wait_type LIKE 'LCK_%'                       THEN '01 - Lock (contencao)'
            WHEN w.wait_type LIKE 'PAGEIOLATCH_%'               THEN '02 - IO de disco (leitura)'
            WHEN w.wait_type LIKE 'PAGELATCH_%'                 THEN '03 - Latch de pagina (memoria)'
            WHEN w.wait_type LIKE 'LATCH_%'                     THEN '04 - Latch interno'
            WHEN w.wait_type LIKE 'WRITELOG%'                   THEN '05 - Log de transacao'
            WHEN w.wait_type IN ('CXPACKET', 'CXCONSUMER')      THEN '06 - Paralelismo'
            WHEN w.wait_type LIKE 'RESOURCE_SEMAPHORE%'         THEN '07 - Memory grant'
            WHEN w.wait_type IN ('SOS_SCHEDULER_YIELD', 'SOS_WORKER') THEN '08 - CPU / scheduler'
            WHEN w.wait_type LIKE 'ASYNC_NETWORK_IO%'           THEN '09 - Rede / cliente lento'
            WHEN w.wait_type LIKE 'CMEMTHREAD%'                 THEN '10 - Alocacao de memoria'
            WHEN w.wait_type LIKE 'TRACEWRITE%'                 THEN '11 - Trace'
            WHEN w.wait_type LIKE 'FCB_REPLICA%'                THEN '12 - Replica'
            ELSE                                                     '99 - Outros'
        END                                                            AS categoria
    FROM dbo.history_waits AS w WITH (NOLOCK)
    WHERE w.event_time >= @DataInicial
      AND w.event_time <  @DataFinal
)
SELECT
    c.categoria
  , COUNT_BIG(*)                                                       AS ocorrencias
  , CAST(SUM(c.duration_ms) / 1000.0 AS DECIMAL(18,2))                 AS espera_total_seg
  , CAST(SUM(c.signal_duration_ms) / 1000.0 AS DECIMAL(18,2))          AS fila_cpu_total_seg
  , CAST(
        SUM(c.duration_ms) * 100.0
        / NULLIF(SUM(SUM(c.duration_ms)) OVER (), 0)
        AS DECIMAL(5,2)
    )                                                                  AS pct_do_tempo_total
  , COUNT_BIG(DISTINCT c.query_hash)                                   AS queries_distintas
FROM categorizado AS c
GROUP BY c.categoria
ORDER BY espera_total_seg DESC;

/* ============================================================================
   SEÇÃO 4 — PRESSÃO DE CPU: RAZÃO SIGNAL / DURATION
   O diagnóstico que separa "esperando recurso" de "esperando CPU".
   signal_duration é o tempo na fila do scheduler. Se a razão é alta,
   o servidor tem mais threads que cores — o gargalo é CPU, não o recurso.
   REGRA: razão > 25% indica pressão de CPU significativa.
   ============================================================================ */
SELECT TOP (@TopN)
    w.wait_type
  , COUNT_BIG(*)                                                       AS ocorrencias
  , CAST(SUM(w.duration_ms) / 1000.0 AS DECIMAL(18,2))                 AS espera_total_seg
  , CAST(SUM(w.signal_duration_ms) / 1000.0 AS DECIMAL(18,2))          AS fila_cpu_total_seg
  , CAST(
        SUM(w.signal_duration_ms) * 100.0
        / NULLIF(SUM(w.duration_ms), 0)
        AS DECIMAL(6,2)
    )                                                                  AS pct_signal_sobre_duration
  , CASE
        WHEN SUM(w.duration_ms) = 0 THEN 'Sem dados'
        WHEN SUM(w.signal_duration_ms) * 100.0 / SUM(w.duration_ms) >= 50
            THEN 'CRITICO: pressao de CPU dominante'
        WHEN SUM(w.signal_duration_ms) * 100.0 / SUM(w.duration_ms) >= 25
            THEN 'ATENCAO: pressao de CPU relevante'
        ELSE 'Normal: gargalo no recurso esperado'
    END                                                                AS diagnostico
FROM dbo.history_waits AS w WITH (NOLOCK)
WHERE w.event_time >= @DataInicial
  AND w.event_time <  @DataFinal
GROUP BY w.wait_type
HAVING SUM(w.duration_ms) > 0
ORDER BY espera_total_seg DESC;

/* ============================================================================
   SEÇÃO 5 — RANKING DE QUERIES POR TEMPO DE ESPERA
   Quais queries acumulam mais espera. Aqui o alvo é o código, não o
   subsistema. Uma query no topo com LCK_ é bloqueio; com PAGEIOLATCH_
   é falta de índice.
   ============================================================================ */
SELECT TOP (@TopN)
    w.query_hash
  , MAX(w.database_name)                                               AS banco
  , MAX(LEFT(w.statement, 1000))                                       AS comando_sql
  , COUNT_BIG(*)                                                       AS waits
  , CAST(SUM(w.duration_ms) / 1000.0 AS DECIMAL(18,2))                 AS espera_total_seg
  , CAST(SUM(w.signal_duration_ms) / 1000.0 AS DECIMAL(18,2))          AS fila_cpu_total_seg
  , CAST(MAX(w.duration_ms) / 1000.0 AS DECIMAL(18,2))                 AS maior_espera_seg
  , COUNT_BIG(DISTINCT w.wait_type)                                    AS tipos_wait_distintos
  , COUNT_BIG(DISTINCT w.session_id)                                   AS sessoes_distintas
  , MIN(w.event_time)                                                  AS primeira_ocorrencia
  , MAX(w.event_time)                                                  AS ultima_ocorrencia
FROM dbo.history_waits AS w WITH (NOLOCK)
WHERE w.event_time >= @DataInicial
  AND w.event_time <  @DataFinal
GROUP BY w.query_hash
ORDER BY espera_total_seg DESC;

/* ============================================================================
   SEÇÃO 6 — COMPOSIÇÃO DE WAITS POR QUERY (qual wait domina cada query)
   Para cada query do topo, mostra a quebra por wait_type. Revela se a
   query espera por um único recurso (correção direta) ou por vários
   (problema estrutural).
   ============================================================================ */
;WITH top_queries AS
(
    SELECT TOP (@TopN)
        w.query_hash
      , SUM(w.duration_ms)                                             AS espera_total_ms
    FROM dbo.history_waits AS w WITH (NOLOCK)
    WHERE w.event_time >= @DataInicial
      AND w.event_time <  @DataFinal
    GROUP BY w.query_hash
    ORDER BY SUM(w.duration_ms) DESC
)
SELECT
    w.query_hash
  , w.wait_type
  , COUNT_BIG(*)                                                       AS ocorrencias
  , CAST(SUM(w.duration_ms) / 1000.0 AS DECIMAL(18,2))                 AS espera_seg
  , CAST(
        SUM(w.duration_ms) * 100.0
        / NULLIF(tq.espera_total_ms, 0)
        AS DECIMAL(5,2)
    )                                                                  AS pct_da_query
  , CAST(AVG(w.duration_ms * 1.0) / 1000.0 AS DECIMAL(18,3))           AS media_espera_seg
  , MAX(LEFT(w.statement, 500))                                        AS comando_sql
FROM dbo.history_waits AS w WITH (NOLOCK)
INNER JOIN top_queries AS tq
    ON tq.query_hash = w.query_hash
WHERE w.event_time >= @DataInicial
  AND w.event_time <  @DataFinal
GROUP BY
    w.query_hash
  , w.wait_type
  , tq.espera_total_ms
ORDER BY w.query_hash, espera_seg DESC;

/* ============================================================================
   SEÇÃO 7 — RANKING DE STATEMENTS LENTOS (history_query_stats)
   ATENÇÃO: duration_ms e cpu_time_ms estão em MICROSSEGUNDOS nesta tabela.
   A conversão para segundos é feita aqui (divisão por 1.000.000).
   A razão cpu/duration separa CPU de espera, igual à rotina de slow query.
   ============================================================================ */
SELECT TOP (@TopN)
    s.query_hash
  , MAX(s.database_name)                                               AS banco
  , MAX(LEFT(s.statement, 1000))                                       AS comando_sql
  , COUNT_BIG(*)                                                       AS execucoes_capturadas
  , CAST(MAX(s.duration_ms) / 1000000.0 AS DECIMAL(18,3))              AS maior_duracao_seg
  , CAST(AVG(s.duration_ms * 1.0) / 1000000.0 AS DECIMAL(18,3))        AS media_duracao_seg
  , CAST(MAX(s.cpu_time_ms) / 1000000.0 AS DECIMAL(18,3))              AS maior_cpu_seg
  , CAST(
        SUM(s.cpu_time_ms) * 100.0
        / NULLIF(SUM(s.duration_ms), 0)
        AS DECIMAL(6,2)
    )                                                                  AS pct_cpu_sobre_duracao
  , SUM(s.logical_reads)                                               AS total_leituras_logicas
  , SUM(s.physical_reads)                                              AS total_leituras_fisicas
  , SUM(s.writes)                                                      AS total_escritas
  , MAX(s.row_count)                                                   AS maior_row_count
  , MIN(s.event_time)                                                  AS primeira_ocorrencia
  , MAX(s.event_time)                                                  AS ultima_ocorrencia
FROM dbo.history_query_stats AS s WITH (NOLOCK)
WHERE s.event_time >= @DataInicial
  AND s.event_time <  @DataFinal
GROUP BY s.query_hash
ORDER BY maior_duracao_seg DESC;

/* ============================================================================
   SEÇÃO 8 — CLASSIFICAÇÃO CPU-BOUND vs ESPERA (history_query_stats)
   Mesma lógica da rotina de slow query, aplicada aqui. Uma query que
   consome 90% do tempo em CPU precisa de reescrita; uma que consome 20%
   precisa de índice ou investigação de bloqueio.
   ============================================================================ */
;WITH classificacao AS
(
    SELECT
        s.query_hash
      , s.duration_ms
      , s.cpu_time_ms
      , s.logical_reads
      , s.row_count
      , CASE
            WHEN s.duration_ms > 0
                THEN s.cpu_time_ms * 100.0 / s.duration_ms
            ELSE NULL
        END                                                            AS pct_cpu
    FROM dbo.history_query_stats AS s WITH (NOLOCK)
    WHERE s.event_time >= @DataInicial
      AND s.event_time <  @DataFinal
)
SELECT
    CASE
        WHEN c.pct_cpu >= 80 THEN 'A - CPU-BOUND: processamento intenso'
        WHEN c.pct_cpu >= 50 THEN 'B - MISTO: CPU e espera'
        WHEN c.pct_cpu IS NOT NULL THEN 'C - ESPERA: bloqueio, IO ou rede'
        ELSE 'D - Nao classificado'
    END                                                                AS classificacao
  , COUNT_BIG(*)                                                       AS execucoes
  , COUNT_BIG(DISTINCT c.query_hash)                                   AS queries_distintas
  , CAST(SUM(c.duration_ms * 1.0) / 1000000.0 AS DECIMAL(18,2))        AS duracao_total_seg
  , CAST(SUM(c.cpu_time_ms * 1.0) / 1000000.0 AS DECIMAL(18,2))        AS cpu_total_seg
  , SUM(c.logical_reads)                                               AS total_leituras
  , CAST(COUNT_BIG(*) * 100.0 / SUM(COUNT_BIG(*)) OVER () AS DECIMAL(5,2)) AS percentual
FROM classificacao AS c
GROUP BY
    CASE
        WHEN c.pct_cpu >= 80 THEN 'A - CPU-BOUND: processamento intenso'
        WHEN c.pct_cpu >= 50 THEN 'B - MISTO: CPU e espera'
        WHEN c.pct_cpu IS NOT NULL THEN 'C - ESPERA: bloqueio, IO ou rede'
        ELSE 'D - Nao classificado'
    END
ORDER BY classificacao;

/* ============================================================================
   SEÇÃO 9 — CORRELAÇÃO WAITS x STATEMENTS (a análise mais valiosa)
   Para cada query que aparece nas duas tabelas, cruza o tempo de espera
   com a duração do statement. Se a espera é próxima da duração, o tempo
   foi quase todo em wait — o problema não é a query, é o ambiente.
   ATENÇÃO: relação 1:N (um statement gera N waits). Não some as duas
   tabelas — compare as médias.
   ============================================================================ */
;WITH waits_por_query AS
(
    SELECT
        w.query_hash
      , COUNT_BIG(*)                                                   AS qtd_waits
      , SUM(w.duration_ms)                                             AS espera_total_ms
      , SUM(w.signal_duration_ms)                                      AS fila_cpu_total_ms
      , MAX(w.wait_type)                                               AS wait_dominante
    FROM dbo.history_waits AS w WITH (NOLOCK)
    WHERE w.event_time >= @DataInicial
      AND w.event_time <  @DataFinal
    GROUP BY w.query_hash
)
, stats_por_query AS
(
    SELECT
        s.query_hash
      , COUNT_BIG(*)                                                   AS qtd_execucoes
      , SUM(s.duration_ms)                                             AS duracao_total_us
      , SUM(s.cpu_time_ms)                                             AS cpu_total_us
      , MAX(LEFT(s.statement, 500))                                    AS comando_sql
    FROM dbo.history_query_stats AS s WITH (NOLOCK)
    WHERE s.event_time >= @DataInicial
      AND s.event_time <  @DataFinal
    GROUP BY s.query_hash
)
SELECT TOP (@TopN)
    st.query_hash
  , st.comando_sql
  , st.qtd_execucoes
  , CAST(st.duracao_total_us / 1000000.0 AS DECIMAL(18,2))             AS duracao_total_seg
  , CAST(st.cpu_total_us / 1000000.0 AS DECIMAL(18,2))                 AS cpu_total_seg
  , wt.qtd_waits
  , CAST(wt.espera_total_ms / 1000.0 AS DECIMAL(18,2))                 AS espera_total_seg
  , CAST(wt.fila_cpu_total_ms / 1000.0 AS DECIMAL(18,2))               AS fila_cpu_total_seg
  , wt.wait_dominante
  , CAST(
        (wt.espera_total_ms / 1000.0) * 100.0
        / NULLIF(st.duracao_total_us / 1000000.0, 0)
        AS DECIMAL(6,2)
    )                                                                  AS pct_espera_sobre_duracao
  , CASE
        WHEN st.duracao_total_us = 0 THEN 'Sem dados'
        WHEN (wt.espera_total_ms / 1000.0) * 100.0 / (st.duracao_total_us / 1000000.0) >= 80
            THEN 'TEMPO QUASE TODO EM ESPERA: problema de ambiente'
        WHEN (wt.espera_total_ms / 1000.0) * 100.0 / (st.duracao_total_us / 1000000.0) >= 40
            THEN 'ESPERA RELEVANTE: investigar recurso'
        ELSE 'EXECUCAO DOMINANTE: problema de query'
    END                                                                AS diagnostico
FROM stats_por_query AS st
INNER JOIN waits_por_query AS wt
    ON wt.query_hash = st.query_hash
ORDER BY duracao_total_seg DESC;

/* ============================================================================
   SEÇÃO 10 — TIMELINE POR HORA
   Concentração horária indica job, ETL ou pico de acesso. Distribuição
   uniforme indica problema estrutural.
   ============================================================================ */
SELECT
    CONVERT(DATE, w.event_time)                                        AS dia
  , DATEPART(HOUR, w.event_time)                                       AS hora
  , COUNT_BIG(*)                                                       AS waits
  , COUNT_BIG(DISTINCT w.wait_type)                                    AS tipos_wait
  , COUNT_BIG(DISTINCT w.session_id)                                   AS sessoes_distintas
  , CAST(SUM(w.duration_ms) / 1000.0 AS DECIMAL(18,2))                 AS espera_total_seg
  , CAST(SUM(w.signal_duration_ms) / 1000.0 AS DECIMAL(18,2))          AS fila_cpu_total_seg
FROM dbo.history_waits AS w WITH (NOLOCK)
WHERE w.event_time >= @DataInicial
  AND w.event_time <  @DataFinal
GROUP BY
    CONVERT(DATE, w.event_time)
  , DATEPART(HOUR, w.event_time)
ORDER BY dia DESC, hora DESC;

/* ============================================================================
   SEÇÃO 11 — ORIGEM DOS WAITS (aplicação e host)
   Quem está gerando as esperas. Uma aplicação concentrando LCK_ indica
   transação longa; concentrando PAGEIOLATCH_ indica consulta sem índice.
   ============================================================================ */
SELECT TOP (@TopN)
    w.client_hostname                                                  AS host
  , w.database_name                                                    AS banco
  , w.wait_type
  , COUNT_BIG(*)                                                       AS ocorrencias
  , CAST(SUM(w.duration_ms) / 1000.0 AS DECIMAL(18,2))                 AS espera_total_seg
  , CAST(SUM(w.signal_duration_ms) / 1000.0 AS DECIMAL(18,2))          AS fila_cpu_total_seg
  , COUNT_BIG(DISTINCT w.session_id)                                   AS sessoes_distintas
  , COUNT_BIG(DISTINCT w.query_hash)                                   AS queries_distintas
  , MIN(w.event_time)                                                  AS primeira_ocorrencia
  , MAX(w.event_time)                                                  AS ultima_ocorrencia
FROM dbo.history_waits AS w WITH (NOLOCK)
WHERE w.event_time >= @DataInicial
  AND w.event_time <  @DataFinal
GROUP BY
    w.client_hostname
  , w.database_name
  , w.wait_type
ORDER BY espera_total_seg DESC;

/* ============================================================================
   SEÇÃO 12 — DETALHE CRONOLÓGICO DE WAITS
   Últimos waits com todas as colunas relevantes.
   ============================================================================ */
SELECT TOP (200)
    w.event_time
  , w.event_interval
  , w.wait_type
  , w.duration_ms
  , w.signal_duration_ms
  , CAST(w.duration_ms / 1000.0 AS DECIMAL(18,3))                      AS duration_seg
  , CAST(w.signal_duration_ms / 1000.0 AS DECIMAL(18,3))               AS signal_seg
  , w.session_id
  , w.database_name
  , w.client_hostname
  , w.query_hash
  , w.query_plan_hash
  , LEFT(w.statement, 1000)                                            AS comando_sql
FROM dbo.history_waits AS w WITH (NOLOCK)
WHERE w.event_time >= @DataInicial
  AND w.event_time <  @DataFinal
ORDER BY w.duration_ms DESC;

/* ============================================================================
   SEÇÃO 13 — DETALHE CRONOLÓGICO DE STATEMENTS LENTOS
   ATENÇÃO: duration_ms e cpu_time_ms em MICROSSEGUNDOS nesta tabela.
   ============================================================================ */
SELECT TOP (200)
    s.event_time
  , s.event_interval
  , s.query_hash
  , s.query_plan_hash
  , s.session_id
  , s.database_name
  , s.client_hostname
  , CAST(s.duration_ms / 1000000.0 AS DECIMAL(18,3))                   AS duracao_seg
  , CAST(s.cpu_time_ms / 1000000.0 AS DECIMAL(18,3))                   AS cpu_seg
  , s.logical_reads
  , s.physical_reads
  , s.writes
  , s.row_count
  , LEFT(s.statement, 1000)                                            AS comando_sql
FROM dbo.history_query_stats AS s WITH (NOLOCK)
WHERE s.event_time >= @DataInicial
  AND s.event_time <  @DataFinal
ORDER BY s.duration_ms DESC;

/* ============================================================================
   SEÇÃO 14 — VALIDAÇÃO DO MAPEAMENTO DE wait_type
   Confere se as chaves numéricas usadas no filtro da sessão XE ainda
   apontam para os wait types esperados no build atual. Se o servidor foi
   atualizado, os filtros podem estar capturando waits diferentes.
   ============================================================================ */
SELECT
    m.map_key
  , m.map_value
  , CASE
        WHEN m.map_key BETWEEN 1 AND 21     THEN 'LCK_ (lock)'
        WHEN m.map_key BETWEEN 32 AND 37    THEN 'LATCH_'
        WHEN m.map_key BETWEEN 48 AND 53    THEN 'PAGELATCH_'
        WHEN m.map_key BETWEEN 64 AND 69    THEN 'PAGEIOLATCH_'
        WHEN m.map_key BETWEEN 97 AND 99    THEN 'IO (disco/rede)'
        WHEN m.map_key = 110                THEN 'RESOURCE_SEMAPHORE'
        WHEN m.map_key = 116                THEN 'SOS_WORKER'
        WHEN m.map_key = 123                THEN 'SOS_SCHEDULER_YIELD'
        WHEN m.map_key = 181                THEN 'WRITELOG'
        WHEN m.map_key BETWEEN 178 AND 179  THEN 'FCB_REPLICA_'
        WHEN m.map_key = 189                THEN 'CMEMTHREAD'
        WHEN m.map_key = 191                THEN 'CXPACKET'
        WHEN m.map_key = 222                THEN 'TRACEWRITE'
        WHEN m.map_key = 285                THEN 'RESOURCE_SEMAPHORE_MUTEX'
        WHEN m.map_key = 299                THEN 'RESOURCE_SEMAPHORE_QUERY_COMPILE'
        ELSE 'Fora do filtro da sessao'
    END                                                                AS usado_no_filtro
FROM sys.dm_xe_map_values AS m
WHERE m.name = 'wait_types'
  AND m.map_key IN (
        1, 21, 32, 37, 48, 53, 64, 69, 97, 99,
        110, 116, 123, 181, 178, 179, 189, 191, 222, 285, 299
      )
ORDER BY m.map_key;

/* ============================================================================
   SEÇÃO 15 — VOLUME DE STAGING (controle de crescimento)
   history_wait_info_xevents guarda o XML bruto sem retenção. Esta seção
   mostra o volume acumulado por tipo de evento e por dia, para dimensionar
   a política de limpeza.
   ============================================================================ */
SELECT
    CONVERT(DATE, x.event_time)                                        AS dia
  , x.event_type
  , COUNT_BIG(*)                                                       AS eventos
  , CAST(SUM(DATALENGTH(x.event_data)) / 1048576.0 AS DECIMAL(18,2))   AS tamanho_mb
  , MIN(x.event_time)                                                  AS primeiro_evento
  , MAX(x.event_time)                                                  AS ultimo_evento
FROM dbo.history_wait_info_xevents AS x WITH (NOLOCK)
WHERE x.event_time >= @DataInicial
  AND x.event_time <  @DataFinal
GROUP BY
    CONVERT(DATE, x.event_time)
  , x.event_type
ORDER BY dia DESC, eventos DESC;
