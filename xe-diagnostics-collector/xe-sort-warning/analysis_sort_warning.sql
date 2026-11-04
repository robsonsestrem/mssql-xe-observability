/*
 *
   OBJETIVO: Investigar sort warnings capturados pela sessão XE
             sort_warning_performance (evento sqlserver.sort_warning) e
             carregados pela dbo.sp_load_sort_warning_performance.
    
   PROJETO: mssql-xe-observability

   AUTHOR: Robson Sestrem

   ----------------------------------------------------------------------------
   SUPOSIÇÕES E AVISOS:

   1. MULTIPLICIDADE DE LINHAS:
      A carga faz CROSS APPLY em tsql_frame/frame. Um único sort warning
      gera UMA LINHA POR NÍVEL DA PILHA de chamadas. Para contar eventos
      reais, use frame_level = 0. Sem esse filtro, o volume aparece inflado.

   2. sort_warning_type É UM ENUM:
      No evento sort_warning, o campo é numérico:
        1 = Single pass  (uma passada sobre os dados em tempdb)
        2 = Multiple pass (múltiplas passadas — muito pior)
      A carga extrai via /text, que pode retornar vazio ou o número
      dependendo do build. As seções abaixo tratam ambos os formatos.

   3. granted_memory_kb vs used_memory_kb É O DIAGNÓSTICO CENTRAL:
      - used_memory_kb próximo de granted_memory_kb + spill = grant insuficiente
        por estimativa de cardinalidade errada (problema de estatística/query).
      - used_memory_kb muito abaixo de granted_memory_kb + spill = possível
        contenção de memory grant no servidor (muitas queries concorrentes).
      A diferença entre os dois é o indicador que separa as duas causas.

   4. worktable_physical_writes MEDE O CUSTO REAL:
      Sort warning com 0 writes é ruído. Com milhões de writes, é degradação
      séria de tempdb. Priorize por writes, não por contagem de eventos.

   5. A sessão exige query_hash > 0 e is_system = 0. Sorts de sistema e
      queries sem hash não são capturados.

   6. sql_statement pode ser NULL quando o plano saiu do cache. Use sql_text
      como fallback.
 *
 */
USE DBA_PerformanceHub
GO

-- ============================================================================
-- SEÇÃO 0 — PARÂMETROS
-- ============================================================================
DECLARE @DataInicial DATETIME = DATEADD(DAY, -7, GETDATE());
DECLARE @DataFinal   DATETIME = GETDATE();
DECLARE @TopN        INT      = 50;

/* ============================================================================
   SEÇÃO 1 — PANORAMA GERAL POR DIA
   Volume de sort warnings, queries distintas e custo total em writes.
   Queda abrupta pode indicar sessão XE parada, não ausência de problema.
   ============================================================================ */
SELECT
    CONVERT(DATE, s.timestamp_xe)                                      AS dia
  , COUNT_BIG(*)                                                       AS sort_warnings
  , COUNT_BIG(DISTINCT s.query_hash)                                   AS queries_distintas
  , COUNT_BIG(DISTINCT s.session_id)                                   AS sessoes_distintas
  , COUNT_BIG(DISTINCT s.client_app_name)                              AS apps_distintas
  , SUM(s.worktable_physical_writes)                                   AS total_writes
  , SUM(s.worktable_physical_reads)                                    AS total_reads
  , MAX(s.worktable_physical_writes)                                   AS maior_write_individual
FROM dbo.history_sort_warning_performance AS s WITH (NOLOCK)
WHERE s.timestamp_xe >= @DataInicial
  AND s.timestamp_xe <  @DataFinal
  AND s.frame_level = 0
GROUP BY CONVERT(DATE, s.timestamp_xe)
ORDER BY dia DESC;

/* ============================================================================
   SEÇÃO 2 — DISTRIBUIÇÃO POR TIPO DE SORT WARNING
   Single pass vs Multiple pass. Multiple pass significa que o engine teve
   de reler os dados em tempdb mais de uma vez — custo muito maior.
   Trata tanto o formato numérico quanto o textual.
   ============================================================================ */
SELECT
    s.sort_warning_type                                                AS valor_original
  , CASE
        WHEN s.sort_warning_type = '1' OR s.sort_warning_type LIKE '%Single%'
            THEN 'Single pass (1)'
        WHEN s.sort_warning_type = '2' OR s.sort_warning_type LIKE '%Multiple%'
            THEN 'Multiple pass (2)'
        WHEN s.sort_warning_type IS NULL OR s.sort_warning_type = ''
            THEN 'Nao informado'
        ELSE s.sort_warning_type
    END                                                                AS tipo_traduzido
  , COUNT_BIG(*)                                                       AS ocorrencias
  , COUNT_BIG(DISTINCT s.query_hash)                                   AS queries_distintas
  , SUM(s.worktable_physical_writes)                                   AS total_writes
  , CAST(AVG(s.worktable_physical_writes * 1.0) AS DECIMAL(18,2))      AS media_writes
  , MIN(s.timestamp_xe)                                                AS primeira_ocorrencia
  , MAX(s.timestamp_xe)                                                AS ultima_ocorrencia
FROM dbo.history_sort_warning_performance AS s WITH (NOLOCK)
WHERE s.timestamp_xe >= @DataInicial
  AND s.timestamp_xe <  @DataFinal
  AND s.frame_level = 0
GROUP BY
    s.sort_warning_type
  , CASE
        WHEN s.sort_warning_type = '1' OR s.sort_warning_type LIKE '%Single%' THEN 'Single pass (1)'
        WHEN s.sort_warning_type = '2' OR s.sort_warning_type LIKE '%Multiple%' THEN 'Multiple pass (2)'
        WHEN s.sort_warning_type IS NULL OR s.sort_warning_type = '' THEN 'Nao informado'
        ELSE s.sort_warning_type
    END
ORDER BY ocorrencias DESC;

/* ============================================================================
   SEÇÃO 3 — RANKING DE QUERIES POR CUSTO DE SPILL
   O diagnóstico primário. Ordena por writes totais, não por contagem de
   eventos — uma query que gera 1 warning com 5 milhões de writes é pior
   que 500 warnings com 10 writes cada.
   ============================================================================ */
SELECT TOP (@TopN)
    s.query_hash
  , MAX(s.database_name)                                               AS banco
  , MAX(LEFT(COALESCE(s.sql_statement, s.sql_text), 1000))             AS comando_sql
  , COUNT_BIG(*)                                                       AS ocorrencias
  , SUM(s.worktable_physical_writes)                                   AS total_writes
  , SUM(s.worktable_physical_reads)                                    AS total_reads
  , MAX(s.worktable_physical_writes)                                   AS maior_write_individual
  , MAX(s.actual_row_count)                                            AS maior_row_count
  , MAX(s.granted_memory_kb)                                           AS maior_grant_kb
  , MAX(s.used_memory_kb)                                              AS maior_uso_kb
  , MIN(s.timestamp_xe)                                                AS primeira_ocorrencia
  , MAX(s.timestamp_xe)                                                AS ultima_ocorrencia
FROM dbo.history_sort_warning_performance AS s WITH (NOLOCK)
WHERE s.timestamp_xe >= @DataInicial
  AND s.timestamp_xe <  @DataFinal
  AND s.frame_level = 0
GROUP BY s.query_hash
ORDER BY total_writes DESC;

/* ============================================================================
   SEÇÃO 4 — DÉFICIT DE MEMORY GRANT (a causa raiz)
   Compara granted_memory_kb com used_memory_kb. A razão entre eles
   separa duas causas distintas:
     - uso próximo do grant (>= 90%) = grant insuficiente por estimativa
       de cardinalidade errada. Ação: atualizar estatísticas, revisar query.
     - uso muito abaixo do grant (< 50%) = contenção de memory grant no
       servidor. Ação: revisar concorrência, max server memory, Resource Governor.
   ============================================================================ */
;WITH deficit AS
(
    SELECT
        s.query_hash
      , s.granted_memory_kb
      , s.used_memory_kb
      , s.worktable_physical_writes
      , s.actual_row_count
      , s.timestamp_xe
      , CASE
            WHEN s.granted_memory_kb > 0
                THEN CAST(s.used_memory_kb * 100.0 / s.granted_memory_kb AS DECIMAL(6,2))
            ELSE NULL
        END                                                            AS pct_uso_grant
    FROM dbo.history_sort_warning_performance AS s WITH (NOLOCK)
    WHERE s.timestamp_xe >= @DataInicial
      AND s.timestamp_xe <  @DataFinal
      AND s.frame_level = 0
      AND s.granted_memory_kb IS NOT NULL
)
SELECT TOP (@TopN)
    d.query_hash
  , COUNT_BIG(*)                                                       AS ocorrencias
  , MAX(d.granted_memory_kb)                                           AS maior_grant_kb
  , MAX(d.used_memory_kb)                                              AS maior_uso_kb
  , MAX(d.pct_uso_grant)                                               AS maior_pct_uso
  , CAST(AVG(d.pct_uso_grant) AS DECIMAL(6,2))                         AS media_pct_uso
  , SUM(d.worktable_physical_writes)                                   AS total_writes
  , MAX(d.actual_row_count)                                            AS maior_row_count
  , CASE
        WHEN MAX(d.pct_uso_grant) >= 90
            THEN 'GRANT INSUFICIENTE: estimativa de cardinalidade errada'
        WHEN MAX(d.pct_uso_grant) < 50
            THEN 'CONTENCAO DE GRANT: uso baixo do grant alocado'
        ELSE 'Uso proximo ao limite: revisar estatisticas'
    END                                                                AS diagnostico
FROM deficit AS d
GROUP BY d.query_hash
ORDER BY total_writes DESC;

/* ============================================================================
   SEÇÃO 5 — RANKING POR APLICAÇÃO E ORIGEM
   Quem está provocando os spills. Uma aplicação concentrando o problema
   indica padrão de acesso inadequado (relatórios ad-hoc, ORDER BY sem índice).
   ============================================================================ */
SELECT TOP (@TopN)
    s.client_app_name                                                  AS aplicacao
  , s.client_hostname                                                  AS host
  , s.session_server_principal_name                                    AS login_name
  , s.database_name                                                    AS banco
  , COUNT_BIG(*)                                                       AS sort_warnings
  , COUNT_BIG(DISTINCT s.query_hash)                                   AS queries_distintas
  , SUM(s.worktable_physical_writes)                                   AS total_writes
  , MAX(s.worktable_physical_writes)                                   AS maior_write_individual
  , MIN(s.timestamp_xe)                                                AS primeira_ocorrencia
  , MAX(s.timestamp_xe)                                                AS ultima_ocorrencia
FROM dbo.history_sort_warning_performance AS s WITH (NOLOCK)
WHERE s.timestamp_xe >= @DataInicial
  AND s.timestamp_xe <  @DataFinal
  AND s.frame_level = 0
GROUP BY
    s.client_app_name
  , s.client_hostname
  , s.session_server_principal_name
  , s.database_name
ORDER BY total_writes DESC;

/* ============================================================================
   SEÇÃO 6 — PADRÕES DE COMANDO SQL
   Agrupa pelo texto do comando. Identifica o código culpado — e revela se
   o problema é ORDER BY, SELECT DISTINCT, GROUP BY ou UNION.
   LIMITAÇÃO: agrupamento por texto exato; variações de parâmetro geram
   linhas separadas.
   ============================================================================ */
SELECT TOP (@TopN)
    LEFT(COALESCE(s.sql_statement, s.sql_text), 1000)                  AS comando_sql
  , COUNT_BIG(*)                                                       AS ocorrencias
  , COUNT_BIG(DISTINCT s.query_hash)                                   AS hashes_distintos
  , SUM(s.worktable_physical_writes)                                   AS total_writes
  , MAX(s.actual_row_count)                                            AS maior_row_count
  , MAX(s.granted_memory_kb)                                           AS maior_grant_kb
  , MIN(s.timestamp_xe)                                                AS primeira_ocorrencia
  , MAX(s.timestamp_xe)                                                AS ultima_ocorrencia
FROM dbo.history_sort_warning_performance AS s WITH (NOLOCK)
WHERE s.timestamp_xe >= @DataInicial
  AND s.timestamp_xe <  @DataFinal
  AND s.frame_level = 0
  AND COALESCE(s.sql_statement, s.sql_text) IS NOT NULL
GROUP BY LEFT(COALESCE(s.sql_statement, s.sql_text), 1000)
ORDER BY total_writes DESC;

/* ============================================================================
   SEÇÃO 7 — CORRELAÇÃO ENTRE VOLUME DE LINHAS E SPILL
   Faixas de actual_row_count versus writes gerados. Mostra a escala do
   problema: quantas linhas a query processou para gerar aquele spill.
   Uma query com 100 linhas e 1 milhão de writes indica linha muito larga.
   ============================================================================ */
;WITH faixas AS
(
    SELECT
        s.actual_row_count
      , s.worktable_physical_writes
      , s.granted_memory_kb
      , s.query_hash
      , CASE
            WHEN s.actual_row_count IS NULL        THEN '00 - Nao informado'
            WHEN s.actual_row_count < 1000         THEN '01 - ate 1 mil linhas'
            WHEN s.actual_row_count < 100000       THEN '02 - 1 mil a 100 mil'
            WHEN s.actual_row_count < 1000000      THEN '03 - 100 mil a 1 milhao'
            WHEN s.actual_row_count < 10000000     THEN '04 - 1 milhao a 10 milhoes'
            ELSE                                        '05 - acima de 10 milhoes'
        END                                                        AS faixa_linhas
    FROM dbo.history_sort_warning_performance AS s WITH (NOLOCK)
    WHERE s.timestamp_xe >= @DataInicial
      AND s.timestamp_xe <  @DataFinal
      AND s.frame_level = 0
)
SELECT
    f.faixa_linhas
  , COUNT_BIG(*)                                                       AS ocorrencias
  , COUNT_BIG(DISTINCT f.query_hash)                                   AS queries_distintas
  , SUM(f.worktable_physical_writes)                                   AS total_writes
  , CAST(AVG(f.worktable_physical_writes * 1.0) AS DECIMAL(18,2))      AS media_writes
  , MAX(f.granted_memory_kb)                                           AS maior_grant_kb
FROM faixas AS f
GROUP BY f.faixa_linhas
ORDER BY f.faixa_linhas;

/* ============================================================================
   SEÇÃO 8 — TIMELINE POR HORA (detecção de janelas de carga)
   Concentração horária indica job de relatório ou ETL. Distribuição
   uniforme indica OLTP com sorts frequentes.
   ============================================================================ */
SELECT
    CONVERT(DATE, s.timestamp_xe)                                      AS dia
  , DATEPART(HOUR, s.timestamp_xe)                                     AS hora
  , COUNT_BIG(*)                                                       AS sort_warnings
  , COUNT_BIG(DISTINCT s.query_hash)                                   AS queries_distintas
  , SUM(s.worktable_physical_writes)                                   AS total_writes
FROM dbo.history_sort_warning_performance AS s WITH (NOLOCK)
WHERE s.timestamp_xe >= @DataInicial
  AND s.timestamp_xe <  @DataFinal
  AND s.frame_level = 0
GROUP BY
    CONVERT(DATE, s.timestamp_xe)
  , DATEPART(HOUR, s.timestamp_xe)
ORDER BY dia DESC, hora DESC;

/* ============================================================================
   SEÇÃO 9 — PILHA DE CHAMADAS (quem disparou o sort)
   Frames de nível > 0 são os chamadores: procedures, triggers, ORM.
   Revela se o sort nasce dentro de uma procedure aninhada — informação
   que o sql_text sozinho não dá.
   ============================================================================ */
SELECT TOP (@TopN)
    s.client_app_name                                                  AS aplicacao
  , s.frame_level
  , LEFT(s.sql_statement, 1000)                                        AS chamador
  , COUNT_BIG(*)                                                       AS ocorrencias
  , SUM(s.worktable_physical_writes)                                   AS total_writes
  , MIN(s.timestamp_xe)                                                AS primeira_ocorrencia
  , MAX(s.timestamp_xe)                                                AS ultima_ocorrencia
FROM dbo.history_sort_warning_performance AS s WITH (NOLOCK)
WHERE s.timestamp_xe >= @DataInicial
  AND s.timestamp_xe <  @DataFinal
  AND s.frame_level > 0
  AND s.sql_statement IS NOT NULL
GROUP BY
    s.client_app_name
  , s.frame_level
  , LEFT(s.sql_statement, 1000)
ORDER BY ocorrencias DESC;

/* ============================================================================
   SEÇÃO 10 — DRILL-DOWN DE UMA QUERY ESPECÍFICA
   Dado um query_hash, mostra a evolução temporal e o comportamento do
   memory grant ao longo do tempo. Permite ver se o problema piorou após
   uma mudança de dados ou de plano.
   ============================================================================ */
DECLARE @QueryHashAlvo DECIMAL(38,0) = NULL;   -- ex.: 1234567890123456789

SELECT
    s.timestamp_xe
  , s.sort_warning_type
  , s.granted_memory_kb
  , s.used_memory_kb
  , CASE
        WHEN s.granted_memory_kb > 0
            THEN CAST(s.used_memory_kb * 100.0 / s.granted_memory_kb AS DECIMAL(6,2))
        ELSE NULL
    END                                                                AS pct_uso_grant
  , s.actual_row_count
  , s.worktable_physical_reads
  , s.worktable_physical_writes
  , s.session_id
  , s.client_app_name
  , s.client_hostname
  , s.database_name
  , s.sql_statement
  , s.sql_text
FROM dbo.history_sort_warning_performance AS s WITH (NOLOCK)
WHERE s.timestamp_xe >= @DataInicial
  AND s.timestamp_xe <  @DataFinal
  AND s.frame_level = 0
  AND (@QueryHashAlvo IS NULL OR s.query_hash = @QueryHashAlvo)
ORDER BY s.timestamp_xe DESC;

/* ============================================================================
   SEÇÃO 11 — DETALHE CRONOLÓGICO (investigação manual)
   Últimos eventos com todas as colunas relevantes.
   ============================================================================ */
SELECT TOP (200)
    s.timestamp_xe
  , s.sort_warning_type
  , s.granted_memory_kb
  , s.used_memory_kb
  , s.worktable_physical_reads
  , s.worktable_physical_writes
  , s.actual_row_count
  , s.session_id
  , s.session_server_principal_name
  , s.username
  , s.client_hostname
  , s.client_app_name
  , s.database_name
  , s.query_hash
  , s.task_time
  , s.sql_statement
  , s.sql_text
FROM dbo.history_sort_warning_performance AS s WITH (NOLOCK)
WHERE s.timestamp_xe >= @DataInicial
  AND s.timestamp_xe <  @DataFinal
  AND s.frame_level = 0
ORDER BY s.timestamp_xe DESC;

/* ============================================================================
   SEÇÃO 12 — CRUZAMENTO COM O PLANO EM CACHE (diagnóstico atual)
   Verifica se a query que gerou sort warning ainda tem plano em cache e
   qual o memory grant atual. Se o plano mudou desde o evento, o grant
   registrado no histórico não reflete o comportamento de hoje.
   ATENÇÃO: sys.dm_exec_query_stats reflete apenas o cache atual — após
   restart ou limpeza de cache, retorna vazio.
   ============================================================================ */
;WITH hashes AS
(
    SELECT
        s.query_hash
      , MAX(s.timestamp_xe)                                            AS ultima_ocorrencia
      , COUNT_BIG(*)                                                   AS ocorrencias
      , SUM(s.worktable_physical_writes)                               AS total_writes
    FROM dbo.history_sort_warning_performance AS s WITH (NOLOCK)
    WHERE s.timestamp_xe >= @DataInicial
      AND s.timestamp_xe <  @DataFinal
      AND s.frame_level = 0
    GROUP BY s.query_hash
)
, cache AS
(
    SELECT
        CONVERT(DECIMAL(38,0), CONVERT(BIGINT, q.query_hash))          AS query_hash
      , MAX(q.sql_handle)                                              AS sql_handle
      , SUM(q.execution_count)                                         AS execution_count
      , SUM(q.total_grant_kb)                                          AS total_grant_kb
      , MAX(q.max_grant_kb)                                            AS max_grant_kb
      , MIN(q.min_grant_kb)                                            AS min_grant_kb
      , SUM(q.total_spills)                                            AS total_spills
      , MAX(q.max_spills)                                              AS max_spills
      , SUM(q.total_worker_time)                                       AS total_worker_time
      , SUM(q.total_elapsed_time)                                      AS total_elapsed_time
    FROM sys.dm_exec_query_stats AS q
    GROUP BY CONVERT(DECIMAL(38,0), CONVERT(BIGINT, q.query_hash))
)
SELECT TOP (@TopN)
    h.query_hash
  , h.ocorrencias
  , h.total_writes
  , h.ultima_ocorrencia
  , c.execution_count                                                 AS execucoes_em_cache
  , c.total_grant_kb                                                  AS grant_total_kb
  , c.max_grant_kb                                                    AS grant_maximo_kb
  , c.min_grant_kb                                                    AS grant_minimo_kb
  , c.total_spills                                                    AS spills_em_cache
  , c.max_spills                                                      AS maior_spill
  , c.total_worker_time / 1000                                        AS cpu_total_ms
  , c.total_elapsed_time / 1000                                       AS tempo_total_ms
  , CASE
        WHEN c.sql_handle IS NULL THEN 'PLANO NAO ESTA MAIS EM CACHE'
        WHEN c.total_spills > 0 THEN 'AINDA GERA SPILL'
        ELSE 'SEM SPILL NO CACHE ATUAL'
    END                                                               AS diagnostico
FROM hashes AS h
LEFT JOIN cache AS c
    ON c.query_hash = h.query_hash
ORDER BY h.total_writes DESC;
